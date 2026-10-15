//! The helper wire: a runtime language served as newline-delimited JSON, one
//! request line to one response line, with twig's node table in it. Port of
//! `src/wire.zig`; `docs/proposals/runtime-languages.md` is the argument and
//! `runtime.rs` is what a language becomes once registered.
//!
//! ── The wire ───────────────────────────────────────────────────────────────
//! Requests:
//!
//! ```text
//! {"op":"describe"}
//! {"op":"parse","dialect":"org","features":["math"],"input":"…"}
//! {"op":"print","dialect":"org","features":[],"table":{…}}
//! {"op":"render","which":"render_text","dialect":"org","features":[],
//!  "text":"…","position":"inline_text"}
//! {"op":"render","which":"render_block",…,"table":{…}}
//! {"op":"render","which":"spells_autolink",…,"text":"<…>"}
//! ```
//!
//! Responses:
//!
//! ```text
//! {"ok":true,"description":{…}}
//! {"ok":true,"table":{…}}
//! {"ok":true,"output":"…"}           print, render_text, render_block
//! {"ok":true,"output":true}          spells_autolink
//! {"ok":false,"message":"…"}
//! ```
//!
//! `dialect` is the row the call is through and `features` the features in
//! force, by name. Every string is UTF-8: a document to parse crosses as a
//! JSON string, so one that is not UTF-8 is refused before it is sent.
//!
//! ── Both ends ──────────────────────────────────────────────────────────────
//! [`language`] is the CALLING end: a `runtime::Language` whose functions are
//! requests over a [`Transport`], which is any way of trading one line for
//! another — a child process's pipes (`cli/languages.rs`, `helper.rs`). The
//! codec lives here, so no transport re-implements it. [`Server`] is the
//! ANSWERING end: one request line to one response line over a
//! `runtime::Language`.

use std::sync::Arc;

use crate::format::Format;
use crate::json::{self, Stringify, Value};
use crate::runtime::{self, Call, Description, InvalidLanguage, Language, RegisterError, Render};

/// A way of trading one request line for one response line. Neither carries
/// its newline.
pub trait Transport: Send + Sync {
    /// Send `request`; return the response line. An error is a transport that
    /// failed — a helper that exited, a pipe that broke — named as Zig names
    /// its error (`HelperExited`, `BrokenPipe`); `diag` may say more.
    fn exchange(&self, request: &[u8], diag: &mut String) -> Result<Vec<u8>, String>;
}

fn lossy(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

fn refuse(diag: &mut String, msg: impl AsRef<str>) -> InvalidLanguage {
    diag.push_str(msg.as_ref());
    InvalidLanguage
}

/// Ask the other end to describe itself.
pub fn describe(transport: &dyn Transport, diag: &mut String) -> Result<Description, InvalidLanguage> {
    let response = match transport.exchange(b"{\"op\":\"describe\"}", diag) {
        Ok(r) => r,
        Err(err) => return Err(refuse(diag, format!("describe: the helper did not answer: {err}"))),
    };
    let obj = answer(&response, diag, "describe")?;
    let Some(value) = obj.get("description") else {
        return Err(refuse(diag, "describe: the response has no \"description\""));
    };
    Description::from_value(value, diag)
}

/// A `runtime::Language` whose calls are requests over `transport`.
pub fn language(transport: Arc<dyn Transport>) -> Language {
    let (t1, t2, t3) = (transport.clone(), transport.clone(), transport);
    Language {
        parse: Box::new(move |c, source| parse(&*t1, c, source)),
        print: Some(Box::new(move |c, table| print(&*t2, c, table))),
        render: Some(Box::new(move |c, req| render(&*t3, c, req))),
    }
}

/// `describe`, then register what it describes over the same transport — the
/// one call a runner makes.
pub fn register(transport: Arc<dyn Transport>, diag: &mut String) -> Result<Format, RegisterError> {
    let description = describe(&*transport, diag)?;
    runtime::register(language(transport), description, diag)
}

/// A response line's object, when it says `"ok": true`; its message in
/// `diag` when it says otherwise.
fn answer(line: &[u8], diag: &mut String, op: &str) -> Result<Value, InvalidLanguage> {
    let Ok(value) = json::parse(line) else {
        return Err(refuse(diag, format!("{op}: the helper's answer is not a JSON line")));
    };
    if value.as_object().is_none() {
        return Err(refuse(diag, format!("{op}: the helper's answer is not a JSON object")));
    }
    let Some(ok) = value.get("ok").and_then(Value::as_bool) else {
        return Err(refuse(diag, format!("{op}: the helper's answer has no \"ok\"")));
    };
    if !ok {
        match value.get("message").and_then(Value::as_str) {
            Some(m) => diag.push_str(&lossy(m)),
            None => diag.push_str("the helper refused, and said nothing"),
        }
        return Err(InvalidLanguage);
    }
    Ok(value)
}

fn call(transport: &dyn Transport, request: &[u8], diag: &mut String, op: &str) -> Result<Value, ()> {
    let line = match transport.exchange(request, diag) {
        Ok(l) => l,
        Err(err) => {
            if diag.is_empty() {
                diag.push_str(&format!("the helper did not answer: {err}"));
            }
            return Err(());
        }
    };
    answer(&line, diag, op).map_err(|_| ())
}

/// `{"op":…,"dialect":…,"features":…` — the members every request through a
/// row carries — then `extra`'s, a `table` member written as the JSON text it
/// already is.
fn build_request(op: &str, c: &Call, extra: &[(&str, Extra)]) -> Vec<u8> {
    let mut out = b"{\"op\":".to_vec();
    json::write_string(&mut out, op.as_bytes());
    out.extend_from_slice(b",\"dialect\":");
    json::write_string(&mut out, c.row.as_bytes());
    out.extend_from_slice(b",\"features\":[");
    for (i, n) in c.feature_names.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        json::write_string(&mut out, n.as_bytes());
    }
    out.push(b']');
    for (name, value) in extra {
        out.push(b',');
        json::write_string(&mut out, name.as_bytes());
        out.push(b':');
        match value {
            Extra::Str(s) => json::write_string(&mut out, s),
            Extra::Raw(r) => out.extend_from_slice(r),
        }
    }
    out.push(b'}');
    out
}

enum Extra<'a> {
    Str(&'a [u8]),
    Raw(&'a [u8]),
}

fn parse(t: &dyn Transport, c: &Call, source: &[u8]) -> Result<Vec<u8>, String> {
    let mut diag = String::new();
    if std::str::from_utf8(source).is_err() {
        return Err("a helper reads text, and this input is not UTF-8".into());
    }
    let request = build_request("parse", c, &[("input", Extra::Str(source))]);
    let obj = call(t, &request, &mut diag, "parse").map_err(|_| diag.clone())?;
    match obj.get("table") {
        Some(table) => Ok(table.to_compact()),
        None => Err("parse: the answer has no \"table\"".into()),
    }
}

fn print(t: &dyn Transport, c: &Call, table: &[u8]) -> Result<Vec<u8>, String> {
    let mut diag = String::new();
    // The table is already JSON, and goes in as it is.
    let request = build_request("print", c, &[("table", Extra::Raw(table))]);
    let obj = call(t, &request, &mut diag, "print").map_err(|_| diag.clone())?;
    output(&obj, "print")
}

fn render(t: &dyn Transport, c: &Call, req: &Render) -> Result<Vec<u8>, String> {
    let mut diag = String::new();
    let request = match req {
        Render::RenderText { text, position } => build_request(
            "render",
            c,
            &[
                ("which", Extra::Str(b"render_text")),
                ("text", Extra::Str(text)),
                ("position", Extra::Str(runtime::position_name(*position).as_bytes())),
            ],
        ),
        Render::RenderBlock(table) => {
            build_request("render", c, &[("which", Extra::Str(b"render_block")), ("table", Extra::Raw(table))])
        }
        Render::SpellsAutolink(angled) => {
            build_request("render", c, &[("which", Extra::Str(b"spells_autolink")), ("text", Extra::Str(angled))])
        }
    };
    let obj = call(t, &request, &mut diag, "render").map_err(|_| diag.clone())?;
    if let Render::SpellsAutolink(_) = req {
        if let Some(Value::Bool(b)) = obj.get("output") {
            return Ok(if *b { b"true".to_vec() } else { b"false".to_vec() });
        }
    }
    output(&obj, "render")
}

fn output(obj: &Value, op: &str) -> Result<Vec<u8>, String> {
    match obj.get("output") {
        Some(Value::String(o)) => Ok(o.clone()),
        _ => Err(format!("{op}: the answer has no \"output\" string")),
    }
}

// ── the answering end ───────────────────────────────────────────────────────

/// A language served over the wire: the loop body of a helper, which reads a
/// line, hands it to [`Server::handle`], and writes what comes back.
pub struct Server {
    lang: Language,
    /// The description, compact and on one line, as `describe` answers it.
    description: Vec<u8>,
    /// Its features' names, in the order a mask counts them.
    features: Vec<String>,
}

/// Why the server answers `"ok": false`; the reason is in its diag.
struct Refused;

impl Server {
    /// Serve `lang` as `description` — a `describe` document, read here so a
    /// request's features can be counted against it. A description that does
    /// not read is refused with why.
    pub fn new(lang: Language, description: &[u8], diag: &mut String) -> Result<Server, InvalidLanguage> {
        let Ok(value) = json::parse(description) else {
            return Err(refuse(diag, "the description is not a JSON document"));
        };
        let d = Description::from_value(&value, diag)?;
        Ok(Server {
            lang,
            description: value.to_compact(),
            features: d.features.into_iter().map(|f| f.name).collect(),
        })
    }

    /// One request line to one response line. Never fails for want of a
    /// well-formed request: a request it cannot read is answered with
    /// `"ok": false`, as a language's own refusal is. The response carries no
    /// newline.
    pub fn handle(&self, request: &[u8]) -> Vec<u8> {
        let mut diag = String::new();
        match self.respond(request, &mut diag) {
            Ok(r) => r,
            Err(Refused) => {
                let mut out = Vec::new();
                let mut w = Stringify::compact(&mut out);
                w.begin_object();
                w.field("ok");
                w.bool(false);
                w.field("message");
                w.str(diag.as_bytes());
                w.end_object();
                out
            }
        }
    }

    fn respond(&self, request: &[u8], diag: &mut String) -> Result<Vec<u8>, Refused> {
        let lang = &self.lang;
        let Ok(value) = json::parse(request) else { return Err(deny(diag, "the request is not a JSON line")) };
        if value.as_object().is_none() {
            return Err(deny(diag, "the request is not a JSON object"));
        }
        let str_of = |key: &str| value.get(key).and_then(Value::as_str);
        let Some(op) = str_of("op") else { return Err(deny(diag, "the request has no \"op\"")) };
        if op == b"describe" {
            let mut out = b"{\"ok\":true,\"description\":".to_vec();
            out.extend_from_slice(&self.description);
            out.push(b'}');
            return Ok(out);
        }

        let row = lossy(str_of("dialect").unwrap_or_default());
        let mut mask = 0u32;
        let mut names: Vec<String> = Vec::new();
        if let Some(list) = value.get("features") {
            let Some(items) = list.as_array() else { return Err(deny(diag, "\"features\" is an array of names")) };
            for item in items {
                let Some(n) = item.as_str() else { return Err(deny(diag, "\"features\" is an array of names")) };
                let n = lossy(n);
                match self.features.iter().position(|d| *d == n) {
                    Some(i) => mask |= 1u32 << i,
                    None => {
                        diag.push_str(&format!("\"{n}\" is not a feature this language declares"));
                        return Err(Refused);
                    }
                }
                names.push(n);
            }
        }
        let name_refs: Vec<&str> = names.iter().map(String::as_str).collect();
        let c = Call { row: &row, features: mask, feature_names: &name_refs };

        let ok_output = |out: &[u8]| {
            let mut o = Vec::new();
            let mut w = Stringify::compact(&mut o);
            w.begin_object();
            w.field("ok");
            w.bool(true);
            w.field("output");
            w.str(out);
            w.end_object();
            o
        };

        if op == b"parse" {
            let Some(input) = str_of("input") else { return Err(deny(diag, "parse: the request has no \"input\" string")) };
            let table = (lang.parse)(&c, input).map_err(|why| refused(diag, why))?;
            let mut out = b"{\"ok\":true,\"table\":".to_vec();
            out.extend_from_slice(&table);
            out.push(b'}');
            return Ok(out);
        }
        if op == b"print" {
            let Some(f) = &lang.print else { return Err(deny(diag, "print: this language does not print")) };
            let Some(table) = value.get("table") else { return Err(deny(diag, "print: the request has no \"table\"")) };
            let out = f(&c, &table.to_compact()).map_err(|why| refused(diag, why))?;
            return Ok(ok_output(&out));
        }
        if op == b"render" {
            let Some(which) = str_of("which") else { return Err(deny(diag, "render: the request has no \"which\"")) };
            // A language with no `render` answers `render_block` with its
            // print, as the in-process carrier does.
            if lang.render.is_none() && which == b"render_block" {
                let Some(p) = &lang.print else { return Err(deny(diag, "render: this language neither renders nor prints")) };
                let Some(table) = value.get("table") else { return Err(deny(diag, "render: render_block needs a \"table\"")) };
                let out = p(&c, &table.to_compact()).map_err(|why| refused(diag, why))?;
                return Ok(ok_output(&out));
            }
            let Some(f) = &lang.render else { return Err(deny(diag, "render: this language names no renderers")) };
            let table_text;
            let req = if which == b"render_text" {
                let Some(text) = str_of("text") else { return Err(deny(diag, "render: render_text needs a \"text\" string")) };
                let Some(position) = runtime::position_from_name(str_of("position").unwrap_or_default()) else {
                    return Err(deny(diag, "render: \"position\" is inline_text, block_start or verbatim"));
                };
                Render::RenderText { text, position }
            } else if which == b"render_block" {
                let Some(table) = value.get("table") else { return Err(deny(diag, "render: render_block needs a \"table\"")) };
                table_text = table.to_compact();
                Render::RenderBlock(&table_text)
            } else if which == b"spells_autolink" {
                let Some(text) = str_of("text") else { return Err(deny(diag, "render: spells_autolink needs a \"text\" string")) };
                Render::SpellsAutolink(text)
            } else {
                diag.push_str(&format!("render: \"{}\" is not a renderer", lossy(which)));
                return Err(Refused);
            };
            let out = f(&c, &req).map_err(|why| refused(diag, why))?;
            if let Render::SpellsAutolink(_) = req {
                let yes = out.trim_ascii() == b"true";
                return Ok(format!("{{\"ok\":true,\"output\":{yes}}}").into_bytes());
            }
            return Ok(ok_output(&out));
        }
        diag.push_str(&format!("\"{}\" is not an op this wire has", lossy(op)));
        Err(Refused)
    }
}

fn refused(diag: &mut String, why: String) -> Refused {
    diag.push_str(&why);
    Refused
}

fn deny(diag: &mut String, message: &str) -> Refused {
    diag.push_str(message);
    Refused
}

// ── tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::table as node_table;
    use crate::format::{self, ParseConfig};
    use crate::languages::markdown;
    use std::sync::Mutex;

    /// A transport that answers in-process through a `Server` — both ends of
    /// the wire in one test. `log` keeps every request line.
    struct Loopback {
        server: Server,
        log: Mutex<Vec<u8>>,
    }

    impl Transport for Loopback {
        fn exchange(&self, request: &[u8], _diag: &mut String) -> Result<Vec<u8>, String> {
            // What a helper would see: the request must be one line.
            assert!(!request.contains(&b'\n'));
            let mut log = self.log.lock().unwrap();
            log.extend_from_slice(request);
            log.push(b'\n');
            let response = self.server.handle(request);
            assert!(!response.contains(&b'\n'));
            Ok(response)
        }
    }

    fn md_parse(c: &Call, source: &[u8]) -> Result<Vec<u8>, String> {
        let options = markdown::ParseOptions { math: c.feature_names.contains(&"math"), ..Default::default() };
        let doc = markdown::parse(source, options);
        Ok(node_table::encode(&doc, node_table::Options { pretty: false, positions: true }))
    }

    fn md_print(_: &Call, text: &[u8]) -> Result<Vec<u8>, String> {
        let doc = node_table::decode_bare(text).map_err(|_| "the table did not decode".to_string())?;
        Ok(markdown::serializer::serialize(&doc))
    }

    fn md_render(_: &Call, request: &Render) -> Result<Vec<u8>, String> {
        match request {
            Render::RenderText { .. } => Err(String::new()),
            Render::RenderBlock(text) => {
                let doc = node_table::decode_bare(text).map_err(|_| String::new())?;
                Ok(markdown::serializer::serialize_ast(&doc.ast))
            }
            Render::SpellsAutolink(angled) => {
                Ok(if markdown::spells_autolink(angled) { b"true".to_vec() } else { b"false".to_vec() })
            }
        }
    }

    fn loopback(lang: Language, description: &str) -> Arc<Loopback> {
        let mut diag = String::new();
        let server = Server::new(lang, description.as_bytes(), &mut diag).unwrap_or_else(|_| panic!("server refused: {diag}"));
        Arc::new(Loopback { server, log: Mutex::new(Vec::new()) })
    }

    #[test]
    fn a_language_across_the_wire_is_registered_and_used_like_one_in_process() {
        let lp = loopback(
            Language::new(md_parse).with_print(md_print),
            r##"{"name": "md-over-wire", "extensions": ["mdw"], "caps": {"write": true},
 "samples": ["# A\n\n- *b*\n- \"c\" \\\\ d\n", "x\n"]}"##,
        );
        let mut diag = String::new();
        let fmt = register(lp, &mut diag).unwrap_or_else(|e| panic!("refused {e:?}: {diag}"));
        assert_eq!(fmt.name(), "md-over-wire");
        assert_eq!(format::detect_from_extension("a.mdw"), Some(fmt));

        let src = b"Some *text* with a \"quote\" and a tab\there.\n";
        let cfg = ParseConfig::default();
        let doc = format::parse(fmt, &cfg, src).unwrap();
        let direct = markdown::parse(src, Default::default());
        assert!(direct.ast.eql(&doc.doc.ast));
        assert_eq!(format::serialize_canonical(&doc).unwrap(), src);
    }

    #[test]
    fn a_language_that_authors_with_a_feature_crosses_the_wire() {
        let md = crate::syntax::markdown::table();
        let esc = |a: &[u8]| {
            let mut v = Vec::new();
            json::write_string(&mut v, &[a, b"$"].concat());
            String::from_utf8(v).unwrap()
        };
        let description = format!(
            r##"{{"name": "md-author-wire", "caps": {{"write": true, "author": true}},
 "syntax": {},
 "features": [{{"name": "math", "syntax": {{
   "text_leaf_delims": {{"inline_math": {{"open": "$", "close": "$"}}, "display_math": {{"open": "$$", "close": "$$"}}}},
   "text_escapes": {}, "link_text_escapes": {}}}}}],
 "sets": [{{"name": "md-author-wire-math", "features": ["math"]}}],
 "samples": ["# A\n\nSome *b*.\n", {{"text": "A $x$ formula.\n", "features": ["math"]}}]}}"##,
            String::from_utf8(crate::syntax_json::encode_alloc(md, crate::syntax_json::Options { pretty: false })).unwrap(),
            esc(md.text_escapes.unwrap()),
            esc(md.link_text_escapes.unwrap()),
        );
        let lp = loopback(Language::new(md_parse).with_print(md_print).with_render(md_render), &description);
        let mut diag = String::new();
        let fmt = register(lp.clone(), &mut diag).unwrap_or_else(|e| panic!("refused {e:?}: {diag}"));
        let set = format::parse_format_name("md-author-wire-math").unwrap();

        // Through the set's row, math is on: a fragment prints across the
        // wire, and the request names the row and its features.
        lp.log.lock().unwrap().clear();
        let table = format::syntax_for(set);
        let mut b = crate::ast::Builder::new();
        let s = b.add_leaf(crate::ast::Kind::TextLeaf { kind: crate::ast::TextLeafKind::InlineMath, text: b"x^2".to_vec() });
        let p = b.add_container(crate::ast::Kind::Para, &[s]);
        let ast = b.finish(p);
        let mut out = Vec::new();
        (table.render_block.unwrap())(table, &ast, p, &mut out).unwrap();
        assert_eq!(out, b"$x^2$\n");
        assert!((table.spells_autolink.unwrap())(table, b"<https://x.dev>"));
        format::parse(set, &ParseConfig::default(), b"Cost.\n").unwrap();
        let log = String::from_utf8(lp.log.lock().unwrap().clone()).unwrap();
        assert!(log.contains(r#"{"op":"render","dialect":"md-author-wire-math","features":["math"],"which":"render_block","table":{"#), "{log}");
        assert!(log.contains(r#""which":"spells_autolink","text":"<https://x.dev>""#), "{log}");
        assert!(log.contains(r#"{"op":"parse","dialect":"md-author-wire-math","features":["math"],"input":"#), "{log}");

        // Through the language's own row, with nothing laid over it, a
        // literal dollar stays bare: the base table's alphabet.
        assert_eq!(format::syntax_for(fmt).text_escapes, md.text_escapes);
        assert!(format::syntax_for(set).text_escapes.unwrap().contains(&b'$'));
        // TODO(port): the Editor half of this test waits for crate::ast::editor.
    }

    #[test]
    fn the_answering_end_refuses_what_it_cannot_read_on_one_line() {
        let mut diag = String::new();
        let server = Server::new(
            Language::new(md_parse),
            b"{\"name\": \"x\",\n \"features\": [{\"name\": \"math\"}],\n \"samples\": [\"x\"]}",
            &mut diag,
        )
        .unwrap();
        for (request, want) in [
            ("not json", "not a JSON line"),
            ("{\"op\":\"dance\"}", "dance\\\" is not an op"),
            ("{\"op\":\"parse\"}", "no \\\"input\\\""),
            ("{\"op\":\"parse\",\"features\":[\"tables\"],\"input\":\"x\"}", "\\\"tables\\\" is not a feature"),
            ("{\"op\":\"print\",\"table\":{}}", "does not print"),
            ("{\"op\":\"render\",\"which\":\"render_text\"}", "names no renderers"),
        ] {
            let response = String::from_utf8(server.handle(request.as_bytes())).unwrap();
            assert!(response.starts_with("{\"ok\":false"), "{response}");
            assert!(response.contains(want), "wanted {want} in {response}");
        }
        // The description goes back as it was given, on one line.
        assert_eq!(
            server.handle(b"{\"op\":\"describe\"}"),
            b"{\"ok\":true,\"description\":{\"name\":\"x\",\"features\":[{\"name\":\"math\"}],\"samples\":[\"x\"]}}"
        );
        // A description that does not read is refused when the server is made.
        assert!(Server::new(Language::new(md_parse), b"{\"name\":1}", &mut diag).is_err());
    }

    #[test]
    fn a_helpers_refusal_and_a_helpers_silence_both_reach_the_caller_as_reasons() {
        struct Mute;
        impl Transport for Mute {
            fn exchange(&self, _: &[u8], _: &mut String) -> Result<Vec<u8>, String> {
                Err("BrokenPipe".into())
            }
        }
        let mut diag = String::new();
        assert_eq!(register(Arc::new(Mute), &mut diag), Err(RegisterError::InvalidLanguage));
        assert!(diag.contains("did not answer: BrokenPipe"), "{diag}");

        struct Refuser;
        impl Transport for Refuser {
            fn exchange(&self, _: &[u8], _: &mut String) -> Result<Vec<u8>, String> {
                Ok(b"{\"ok\":false,\"message\":\"no, thank you\"}".to_vec())
            }
        }
        diag.clear();
        assert_eq!(register(Arc::new(Refuser), &mut diag), Err(RegisterError::InvalidLanguage));
        assert_eq!(diag, "no, thank you");
    }
}
