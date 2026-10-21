import { test } from "node:test";
import assert from "node:assert/strict";
import {
  ABI_VERSION,
  abiVersion,
  convert,
  dialectOf,
  Document,
  Editor,
  Fidelity,
  Format,
  formatByName,
  formatName,
  init,
  isReady,
  MarkdownFlags,
  metadataValue,
  readMetadata,
  renderHtml,
  setMetadata,
  Status,
  TwigError,
  version,
  versionString,
} from "@diaryx/twig";
import pkg from "../package.json" with { type: "json" };

test("init resolves and the module reports its version", async () => {
  await init();
  assert.equal(isReady(), true);
  assert.equal(versionString(), pkg.version);
  const v = version();
  assert.equal(`${v.major}.${v.minor}.${v.patch}`, pkg.version);
  assert.equal(abiVersion(), ABI_VERSION);
});

test("formats resolve by name and back", () => {
  assert.equal(formatByName("md"), Format.Markdown);
  assert.equal(formatByName("gfm"), Format.Gfm);
  assert.equal(formatByName("no-such-format"), null);
  assert.equal(formatName(Format.Djot), "djot");
  assert.equal(formatName("svg"), "svg");
  assert.equal(dialectOf(Format.Gfm), Format.Markdown);
  assert.equal(dialectOf(Format.Svg), Format.Xml);
  assert.equal(dialectOf(Format.Html), null);
});

test("render, convert and the AST", () => {
  assert.equal(renderHtml("# Hi *there*\n", "md"), "<h1>Hi <em>there</em></h1>\n");
  assert.equal(convert("Some *emphasis*.\n", Format.Markdown, Format.Djot), "Some _emphasis_.\n");
  using doc = Document.parse("# Title\n\nText.\n", "markdown");
  const ast = doc.ast() as { type?: string; children?: unknown[] };
  assert.equal(typeof ast, "object");
  assert.match(doc.astJson(), /heading/);
  assert.equal(doc.serialize("md"), "# Title\n\nText.\n");
});

test("an unknown format and a bad selector throw TwigError", () => {
  assert.throws(() => Document.parse("x", "no-such-format"), (e: unknown) => e instanceof TwigError && e.status === Status.UnsupportedFormat);
  assert.throws(() => Document.parse("x", 999), (e: unknown) => e instanceof TwigError && e.status === Status.UnsupportedFormat);
  using doc = Document.parse("x\n", "md");
  assert.throws(() => doc.query("heading[["), (e: unknown) => e instanceof TwigError && e.status === Status.InvalidArgument);
});

test("query, spans and text are UTF-8 byte offsets", () => {
  const src = "# Café ☕\n\n## Two\n\nA [link](https://example.com).\n";
  using doc = Document.parse(src, "md");
  const headings = doc.query("heading");
  assert.equal(headings.length, 2);
  assert.equal(headings[0]!.kind, "heading");
  assert.equal(doc.text(headings[0]!.span), "# Café ☕");
  assert.equal(doc.text(doc.query("heading[level=2]")[0]!.span), "## Two");
  const link = doc.query('link[dest^="https"]');
  assert.equal(link.length, 1);
  assert.equal(doc.text(link[0]!.span), "[link](https://example.com)");
});

test("the flat tree links up and carries payloads", () => {
  using doc = Document.parse("# One\n\n- [x] done\n- [ ] todo\n\n[a](/b)\n", "gfm");
  const nodes = doc.nodes();
  nodes.forEach((n, i) => assert.equal(n.id, i));
  const heading = nodes.find((n) => n.kind === "heading")!;
  assert.equal(heading.level, 1);
  assert.ok(heading.markerSpan);
  const tasks = nodes.filter((n) => n.kind === "task_list_item");
  assert.deepEqual(tasks.map((t) => t.checked), [true, false]);
  const link = nodes.find((n) => n.kind === "link")!;
  assert.equal(link.destination, "/b");
  assert.equal(nodes[heading.parent!]!.kind, "doc");
  const top = doc.children();
  assert.deepEqual(top.map((m) => m.kind), ["heading", "task_list", "para"]);
  assert.equal(doc.nodeAt(2)!.kind, "str");
  assert.deepEqual(doc.nodesAt(2).map((m) => m.kind), ["doc", "heading", "str"]);
});

test("element names and attributes reach the flat tree", () => {
  using doc = Document.parse('<p class="x" hidden>Hi</p>\n', "html");
  const p = doc.nodes().find((n) => n.attributes.length > 0)!;
  assert.deepEqual(p.attributes, [
    { key: "class", value: "x" },
    { key: "hidden", value: null },
  ]);
});

test("diagnostics say what a conversion loses", () => {
  using doc = Document.parse("Some {=marked=} text.\n", "djot");
  const warnings = doc.diagnostics("md");
  assert.ok(warnings.length > 0);
  assert.ok(warnings.every((w) => w.fidelity === Fidelity.Degraded || w.fidelity === Fidelity.Dropped));
  using plain = Document.parse("Plain.\n", "djot");
  assert.deepEqual(plain.diagnostics("md"), []);
});

test("markdown flags turn extensions on", () => {
  const src = "Some ==marked== text.\n";
  assert.doesNotMatch(renderHtml(src, "md"), /<mark>/);
  assert.match(renderHtml(src, "md", { flags: MarkdownFlags.Highlight }), /<mark>marked<\/mark>/);
});

test("frontmatter is located, read as data, and replaced", () => {
  const src = "---\ntitle: Hi # kept\ntags: [a, b]\n---\n# Body\n";
  const block = readMetadata(src, "md")!;
  assert.equal(block.lang, "yaml");
  assert.equal(block.body, "title: Hi # kept\ntags: [a, b]\n");
  assert.deepEqual(block.span, { start: 0, end: 37 });
  assert.equal(readMetadata(src, "md", "end"), null);
  assert.deepEqual(metadataValue(src, "md"), { title: "Hi", tags: ["a", "b"] });
  assert.equal(metadataValue("# No metadata\n", "md"), null);

  assert.equal(
    setMetadata(src, "md", "title: Hello # kept\ntags: [a, b]\n"),
    "---\ntitle: Hello # kept\ntags: [a, b]\n---\n# Body\n",
  );
  assert.equal(setMetadata("# Body\n", "md", 'title = "Hi"', { lang: "toml" }), '+++\ntitle = "Hi"\n+++\n# Body\n');
});

test("endmatter and TOML frontmatter", () => {
  const src = "+++\ndate = 2026-10-21T09:00:00Z\n+++\nBody.\n\n---toml\nend = true\n---\n";
  assert.equal(readMetadata(src, "md")!.lang, "toml");
  const front = metadataValue<Record<string, unknown>>(src, "md")!;
  assert.ok("date" in front);
  assert.deepEqual(metadataValue(src, "md", "end"), { end: true });
  // Untagged, a trailing `---` block is a thematic break and a paragraph.
  assert.equal(readMetadata("Body.\n\n---\nend: true\n---\n", "md", "end"), null);
  assert.equal(setMetadata(src, "md", "end = false\n", { at: "end" }).endsWith("---toml\nend = false\n---\n"), true);
});

test("an HTML page's <script> data island is its front block", () => {
  const page = '<!doctype html>\n<html><head>\n<script type="application/json">\n{"title": "Hi"}\n</script>\n</head><body><p>x</p></body></html>\n';
  const block = readMetadata(page, "html")!;
  assert.equal(block.lang, "json");
  assert.equal(block.body, '{"title": "Hi"}\n');
  assert.deepEqual(metadataValue(page, "html"), { title: "Hi" });

  const edited = setMetadata(page, "html", '{"title": "Hello"}\n');
  assert.match(edited, /<script type="application\/json">\n\{"title": "Hello"\}\n<\/script>/);

  const bare = "<!doctype html>\n<html><head>\n<title>x</title>\n</head><body></body></html>\n";
  const added = setMetadata(bare, "html", "title: Hi\n");
  assert.match(added, /<script type="application\/yaml">\ntitle: Hi\n<\/script>/);
  assert.ok(added.startsWith("<!doctype html>\n"));

  assert.throws(
    () => setMetadata(page, "html", '{"a": "</script>"}\n'),
    (e: unknown) => e instanceof TwigError && e.status === Status.UnsafeMetadata,
  );
});

test("a metadata body that does not parse changes nothing", () => {
  using ed = Editor.create("---\na: 1\n---\nx\n", "md");
  assert.throws(() => ed.setMetadata("a: [\n"), (e: unknown) => e instanceof TwigError && e.status === Status.ParseError);
  assert.equal(ed.source, "---\na: 1\n---\nx\n");
  assert.throws(() => ed.setMetadata("a: 2\n", { at: "end" }), (e: unknown) => e instanceof TwigError && e.status === Status.NotFound);
});

test("the editor splices, reports changes, and undoes", () => {
  using ed = Editor.create("# Title\n\nFirst.\n\nSecond.\n", "md");
  const r0 = ed.revision;
  const change = ed.replace('heading("Title")', "# New title");
  assert.equal(ed.source, "# New title\n\nFirst.\n\nSecond.\n");
  assert.deepEqual(change.oldSpan.start, 0);
  assert.ok(ed.revision > r0);

  ed.insertAfter("1", "\n\nInserted.");
  assert.equal(ed.source, "# New title\n\nFirst.\n\nInserted.\n\nSecond.\n");
  ed.delete("2");
  assert.equal(ed.source, "# New title\n\nFirst.\n\nSecond.\n");
  ed.editRange(0, 1, "##");
  assert.equal(ed.source, "## New title\n\nFirst.\n\nSecond.\n");

  assert.ok(ed.undo());
  assert.ok(ed.undo());
  assert.ok(ed.undo());
  assert.ok(ed.undo());
  assert.equal(ed.source, "# Title\n\nFirst.\n\nSecond.\n");
  assert.equal(ed.undo(), null);
  assert.ok(ed.redo());
  assert.equal(ed.source, "# New title\n\nFirst.\n\nSecond.\n");

  assert.throws(() => ed.replace('heading("Nope")', "x"), (e: unknown) => e instanceof TwigError && e.status === Status.NotFound);
  assert.throws(() => ed.replace("para", "x"), (e: unknown) => e instanceof TwigError && e.status === Status.Ambiguous);
});

test("the editor's document view stays current", () => {
  using ed = Editor.create("# A\n", "md");
  const view = ed.document();
  assert.equal(view.query("heading").length, 1);
  ed.insertAfter("0", "\n\n# B");
  assert.equal(view.query("heading").length, 2);
  assert.equal(view.text(view.query("heading")[1]!.span), "# B");
  assert.equal(ed.query("heading").length, 2);
  assert.throws(() => view.renderHtml(), (e: unknown) => e instanceof TwigError && e.status === Status.UnsupportedFormat);
});

test("filter prunes and moves reorder", () => {
  using ed = Editor.create("# A\n\nkeep\n\n# B\n\ndrop\n", "md");
  ed.filter("heading");
  assert.equal(ed.source.includes("#"), false);
  using mv = Editor.create("- one\n- two\n- three\n", "md");
  mv.moveBefore("0.2", "0.0");
  assert.equal(mv.source, "- three\n- one\n- two\n");
});

test("a disposed handle refuses further use", () => {
  const doc = Document.parse("x\n", "md");
  doc.dispose();
  doc.dispose();
  assert.throws(() => doc.query("para"), /disposed/);
  const ed = Editor.create("x\n", "md");
  ed.dispose();
  assert.throws(() => ed.source, /disposed/);
});

test("byte input is accepted as it stands", () => {
  const bytes = new TextEncoder().encode("*hi*\n");
  assert.equal(renderHtml(bytes, Format.Djot), "<p><strong>hi</strong></p>\n");
});

test("a metadata body edited with @diaryx/fig keeps its comments", async () => {
  const { Editor: FigEditor, registerLanguage } = await import("@diaryx/fig");
  const { default: yaml } = await import("@diaryx/fig-yaml");
  const Yaml = registerLanguage(yaml);
  const src = "---\ntitle: Hi # kept\ntags: [a, b]\n---\n# Body\n";
  const block = readMetadata(src, "md")!;
  using fig = FigEditor.open(block.body, Yaml);
  fig.setValue(["title"], "Hello");
  assert.equal(setMetadata(src, "md", fig.source()), "---\ntitle: Hello # kept\ntags: [a, b]\n---\n# Body\n");
});

test("a body that closes its fence early is refused, and nothing changes", () => {
  const src = "+++\na = 1\n+++\n# Body\n";
  using ed = Editor.create(src, "md");
  assert.throws(
    () => ed.setMetadata('a = """\n+++\nhello\n"""\n'),
    (e: unknown) => e instanceof TwigError && e.status === Status.UnsafeMetadata,
  );
  assert.equal(ed.source, src);
});

test("a whole-body replacement repairs metadata that does not parse", () => {
  using ed = Editor.create("---\na: [\n---\n# Body\n", "md");
  ed.setMetadata("a: 2\n");
  assert.equal(ed.source, "---\na: 2\n---\n# Body\n");
  assert.deepEqual(ed.metadataValue(), { a: 2 });
});
