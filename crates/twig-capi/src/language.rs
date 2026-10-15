//! Runtime languages: a host's table of C functions registered as a format,
//! the answering end of the helper wire over such a table, and registration
//! over a host's transport. Port of the runtime half of `src/c_abi.zig`.

use std::ffi::{c_char, c_int, c_void};
use std::sync::Arc;

use twig::json::Stringify;
use twig::runtime::{self, Call, Description, Language, RegisterError, Render};
use twig::wire;

use crate::*;

pub const TWIG_LANGUAGE_VTABLE_VERSION: u32 = 2;
pub const TWIG_TRANSPORT_VERSION: u32 = 1;

/// What one call into a language is about.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TwigLanguageCall {
    pub row: *const u8,
    pub row_len: usize,
    pub features: u32,
    pub input: *const u8,
    pub input_len: usize,
}

pub type TwigLanguageCallFn =
    unsafe extern "C" fn(user_data: *mut c_void, call: *const TwigLanguageCall, out: *mut *mut u8, out_len: *mut usize) -> c_int;

pub type TwigLanguageFn = unsafe extern "C" fn(
    user_data: *mut c_void,
    row: *const u8,
    row_len: usize,
    input: *const u8,
    input_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int;

pub type TwigFreeFn = unsafe extern "C" fn(user_data: *mut c_void, ptr: *mut u8, len: usize);

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TwigLanguageVTable {
    pub version: u32,
    pub user_data: *mut c_void,
    pub description: *const u8,
    pub description_len: usize,
    pub parse: Option<TwigLanguageCallFn>,
    pub print: Option<TwigLanguageCallFn>,
    pub render: Option<TwigLanguageCallFn>,
    pub free: Option<TwigFreeFn>,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TwigLanguageVTableV1 {
    pub version: u32,
    pub user_data: *mut c_void,
    pub description: *const u8,
    pub description_len: usize,
    pub parse: Option<TwigLanguageFn>,
    pub print: Option<TwigLanguageFn>,
    pub free: Option<TwigFreeFn>,
}

pub type TwigExchangeFn = unsafe extern "C" fn(
    user_data: *mut c_void,
    request: *const u8,
    request_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TwigTransport {
    pub version: u32,
    pub user_data: *mut c_void,
    pub exchange: Option<TwigExchangeFn>,
    pub free: Option<TwigFreeFn>,
}

#[cfg(target_pointer_width = "64")]
const _: () = {
    use std::mem::{offset_of, size_of};
    assert!(size_of::<TwigLanguageVTable>() == 64);
    assert!(offset_of!(TwigLanguageVTable, user_data) == 8);
    assert!(offset_of!(TwigLanguageVTable, parse) == 32);
    assert!(offset_of!(TwigLanguageVTable, render) == 48);
    assert!(offset_of!(TwigLanguageVTable, free) == 56);
    assert!(size_of::<TwigLanguageVTableV1>() == 56);
    assert!(offset_of!(TwigLanguageVTableV1, free) == 48);
    assert!(size_of::<TwigLanguageCall>() == 40);
    assert!(offset_of!(TwigLanguageCall, features) == 16);
    assert!(offset_of!(TwigLanguageCall, input) == 24);
    assert!(size_of::<TwigTransport>() == 32);
    assert!(offset_of!(TwigTransport, exchange) == 16);
};

// ── the host's table, kept ──────────────────────────────────────────────────

#[derive(Clone, Copy)]
enum Functions {
    V1 { parse: TwigLanguageFn, print: Option<TwigLanguageFn> },
    V2 { parse: TwigLanguageCallFn, print: Option<TwigLanguageCallFn>, render: Option<TwigLanguageCallFn> },
}

/// A host's table: version 2's functions, or version 1's.
#[derive(Clone, Copy)]
struct HostLanguage {
    user_data: *mut c_void,
    free: TwigFreeFn,
    functions: Functions,
}

// SAFETY: the header makes `user_data` the host's to keep alive for the
// process, and the host's functions are the host's to make thread-safe; the
// engine requires `Send + Sync` of a language because it may be called from
// any thread, which is the contract a C host signs up to.
unsafe impl Send for HostLanguage {}
unsafe impl Sync for HostLanguage {}

#[derive(Clone, Copy)]
enum Which {
    Parse,
    Print,
    Render,
}

impl HostLanguage {
    /// Read whichever table `version` says `raw` is; the reason it cannot be
    /// one otherwise.
    unsafe fn read(raw: *const TwigLanguageVTable) -> Result<HostLanguage, &'static str> {
        // Every table starts with its version, so it is safe to read first.
        let version = unsafe { *(raw as *const u32) };
        match version {
            1 => {
                let v1 = unsafe { &*(raw as *const TwigLanguageVTableV1) };
                match (v1.parse, v1.free) {
                    (Some(parse), Some(free)) => Ok(HostLanguage {
                        user_data: v1.user_data,
                        free,
                        functions: Functions::V1 { parse, print: v1.print },
                    }),
                    _ => Err("the table needs parse and free"),
                }
            }
            TWIG_LANGUAGE_VTABLE_VERSION => {
                let v2 = unsafe { &*raw };
                match (v2.parse, v2.free) {
                    (Some(parse), Some(free)) => Ok(HostLanguage {
                        user_data: v2.user_data,
                        free,
                        functions: Functions::V2 { parse, print: v2.print, render: v2.render },
                    }),
                    _ => Err("the table needs parse and free"),
                }
            }
            _ => Err("the table's version is neither 1 nor TWIG_LANGUAGE_VTABLE_VERSION"),
        }
    }

    /// The description bytes of the table `raw` is.
    unsafe fn description<'a>(raw: *const TwigLanguageVTable) -> Option<&'a [u8]> {
        // `description`/`description_len` sit at the same offsets in both
        // versions.
        let t = unsafe { &*raw };
        unsafe { slice_of(t.description, t.description_len) }
    }

    fn is_v1(&self) -> bool {
        matches!(self.functions, Functions::V1 { .. })
    }

    /// Call one of the host's functions and copy its answer out, releasing
    /// the host's buffer either way.
    fn invoke(&self, which: Which, c: &Call, input: &[u8]) -> Result<Vec<u8>, String> {
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut len: usize = 0;
        let row = c.row.as_bytes();
        // SAFETY: the host's functions take exactly these arguments; every
        // pointer handed in lives for the call.
        let rc = unsafe {
            match self.functions {
                Functions::V1 { parse, print } => {
                    let f = match which {
                        Which::Parse => parse,
                        _ => print.expect("only installed when present"),
                    };
                    f(self.user_data, row.as_ptr(), row.len(), input.as_ptr(), input.len(), &mut out, &mut len)
                }
                Functions::V2 { parse, print, render } => {
                    let record = TwigLanguageCall {
                        row: row.as_ptr(),
                        row_len: row.len(),
                        features: c.features,
                        input: input.as_ptr(),
                        input_len: input.len(),
                    };
                    let f = match which {
                        Which::Parse => parse,
                        Which::Print => print.expect("only installed when present"),
                        Which::Render => render.expect("only installed when present"),
                    };
                    f(self.user_data, &record, &mut out, &mut len)
                }
            }
        };
        let bytes = if out.is_null() { Vec::new() } else { unsafe { std::slice::from_raw_parts(out, len) }.to_vec() };
        if !out.is_null() {
            unsafe { (self.free)(self.user_data, out, len) };
        }
        if rc != 0 {
            return Err(if bytes.is_empty() {
                "the host's function returned a failure".to_string()
            } else {
                String::from_utf8_lossy(&bytes).into_owned()
            });
        }
        Ok(bytes)
    }

    /// The request as the vtable takes it: the wire's `render` without the
    /// members the call record carries.
    fn render(&self, c: &Call, request: &Render) -> Result<Vec<u8>, String> {
        let mut json = Vec::new();
        match request {
            Render::RenderText { text, position } => {
                let mut w = Stringify::compact(&mut json);
                w.begin_object();
                w.field("which");
                w.str(b"render_text");
                w.field("text");
                w.str(text);
                w.field("position");
                w.str(runtime::position_name(*position).as_bytes());
                w.end_object();
            }
            Render::RenderBlock(table) => {
                json.extend_from_slice(b"{\"which\":\"render_block\",\"table\":");
                json.extend_from_slice(table);
                json.push(b'}');
            }
            Render::SpellsAutolink(angled) => {
                let mut w = Stringify::compact(&mut json);
                w.begin_object();
                w.field("which");
                w.str(b"spells_autolink");
                w.field("text");
                w.str(angled);
                w.end_object();
            }
        }
        self.invoke(Which::Render, c, &json)
    }

    /// The engine language over this table.
    fn language(self) -> Language {
        let host = Arc::new(self);
        let parse_host = host.clone();
        let mut lang = Language::new(move |c, source| parse_host.invoke(Which::Parse, c, source));
        let (has_print, has_render) = match host.functions {
            Functions::V1 { print, .. } => (print.is_some(), false),
            Functions::V2 { print, render, .. } => (print.is_some(), render.is_some()),
        };
        if has_print {
            let h = host.clone();
            lang = lang.with_print(move |c, table| h.invoke(Which::Print, c, table));
        }
        if has_render {
            let h = host.clone();
            lang = lang.with_render(move |c, request| h.render(c, request));
        }
        lang
    }
}

/// Copy `message` into a caller's buffer, NUL-terminated and truncated.
unsafe fn write_message(buf: *mut c_char, cap: usize, message: &str) {
    if buf.is_null() || cap == 0 {
        return;
    }
    let n = message.len().min(cap - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(message.as_ptr(), buf as *mut u8, n);
        *buf.add(n) = 0;
    }
}

fn status_of_register(e: RegisterError) -> TwigStatus {
    match e {
        RegisterError::InvalidLanguage | RegisterError::RegistryFull => TWIG_STATUS_INVALID_LANGUAGE,
    }
}

/// Register a language and run the load check over it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_language_register(
    vtable: *const TwigLanguageVTable,
    out_format: *mut c_int,
    err_buf: *mut c_char,
    err_cap: usize,
) -> TwigStatus {
    guard(|| {
        if vtable.is_null() || out_format.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        unsafe { write_message(err_buf, err_cap, "") };
        let host = match unsafe { HostLanguage::read(vtable) } {
            Ok(h) => h,
            Err(why) => {
                unsafe { write_message(err_buf, err_cap, why) };
                return TWIG_STATUS_INVALID_LANGUAGE;
            }
        };
        let Some(text) = (unsafe { HostLanguage::description(vtable) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let mut diag = String::new();
        let description = match Description::parse(text, &mut diag) {
            Ok(d) => d,
            Err(_) => {
                unsafe { write_message(err_buf, err_cap, &diag) };
                return TWIG_STATUS_INVALID_LANGUAGE;
            }
        };
        if host.is_v1() && (description.author || !description.features.is_empty() || !description.sets.is_empty()) {
            unsafe {
                write_message(
                    err_buf,
                    err_cap,
                    "a version 1 table reads and writes; features, sets and caps.author need TWIG_LANGUAGE_VTABLE_VERSION",
                )
            };
            return TWIG_STATUS_INVALID_LANGUAGE;
        }
        match runtime::register(host.language(), description, &mut diag) {
            Ok(fmt) => {
                unsafe { put(out_format, format_to_int(fmt)) };
                TWIG_STATUS_OK
            }
            Err(e) => {
                unsafe { write_message(err_buf, err_cap, &diag) };
                status_of_register(e)
            }
        }
    })
}

// ── the answering end of the wire ───────────────────────────────────────────

/// The opaque C handle.
pub enum TwigServer {}

struct ServerHandle {
    server: wire::Server,
    /// The last answer, valid until the next call or destroy.
    response: Vec<u8>,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_server_create(
    vtable: *const TwigLanguageVTable,
    out_server: *mut *mut TwigServer,
    err_buf: *mut c_char,
    err_cap: usize,
) -> TwigStatus {
    guard(|| {
        if vtable.is_null() || out_server.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        unsafe {
            put(out_server, std::ptr::null_mut());
            write_message(err_buf, err_cap, "");
        }
        let host = match unsafe { HostLanguage::read(vtable) } {
            Ok(h) => h,
            Err(why) => {
                unsafe { write_message(err_buf, err_cap, why) };
                return TWIG_STATUS_INVALID_LANGUAGE;
            }
        };
        let Some(text) = (unsafe { HostLanguage::description(vtable) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let mut diag = String::new();
        match wire::Server::new(host.language(), text, &mut diag) {
            Ok(server) => {
                let handle = Box::new(ServerHandle { server, response: Vec::new() });
                unsafe { put(out_server, Box::into_raw(handle) as *mut TwigServer) };
                TWIG_STATUS_OK
            }
            Err(_) => {
                unsafe { write_message(err_buf, err_cap, &diag) };
                TWIG_STATUS_INVALID_LANGUAGE
            }
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_server_handle(
    server: *mut TwigServer,
    request_ptr: *const u8,
    request_len: usize,
    out_ptr: *mut *const u8,
    out_len: *mut usize,
) -> TwigStatus {
    guard(|| {
        // SAFETY: every `TwigServer` is a boxed `ServerHandle`.
        let Some(h) = (unsafe { (server as *mut ServerHandle).as_mut() }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let Some(request) = (unsafe { slice_of(request_ptr, request_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_ptr.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        h.response = h.server.handle(request);
        unsafe {
            put(out_ptr, h.response.as_ptr());
            put(out_len, h.response.len());
        }
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_server_destroy(server: *mut TwigServer) {
    if !server.is_null() {
        // SAFETY: the handle came from `Box::into_raw` in create.
        drop(unsafe { Box::from_raw(server as *mut ServerHandle) });
    }
}

// ── registration over a transport ───────────────────────────────────────────

/// A host's transport table, kept.
struct HostTransport {
    user_data: *mut c_void,
    exchange: TwigExchangeFn,
    free: TwigFreeFn,
}

// SAFETY: as for `HostLanguage` — the host keeps `user_data` alive for the
// process and its functions callable from any thread.
unsafe impl Send for HostTransport {}
unsafe impl Sync for HostTransport {}

impl wire::Transport for HostTransport {
    fn exchange(&self, request: &[u8], diag: &mut String) -> Result<Vec<u8>, String> {
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut len: usize = 0;
        // SAFETY: the host's exchange takes exactly these arguments.
        let rc = unsafe { (self.exchange)(self.user_data, request.as_ptr(), request.len(), &mut out, &mut len) };
        let bytes = if out.is_null() { Vec::new() } else { unsafe { std::slice::from_raw_parts(out, len) }.to_vec() };
        if !out.is_null() {
            unsafe { (self.free)(self.user_data, out, len) };
        }
        if rc != 0 {
            diag.push_str(&if bytes.is_empty() {
                "the transport failed".to_string()
            } else {
                String::from_utf8_lossy(&bytes).into_owned()
            });
            return Err("TransportFailed".to_string());
        }
        Ok(bytes)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_language_register_transport(
    transport: *const TwigTransport,
    out_format: *mut c_int,
    err_buf: *mut c_char,
    err_cap: usize,
) -> TwigStatus {
    guard(|| {
        if transport.is_null() || out_format.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        unsafe { write_message(err_buf, err_cap, "") };
        let table = unsafe { &*transport };
        if table.version != TWIG_TRANSPORT_VERSION {
            unsafe { write_message(err_buf, err_cap, "the transport's version is not TWIG_TRANSPORT_VERSION") };
            return TWIG_STATUS_INVALID_LANGUAGE;
        }
        let (Some(exchange), Some(free)) = (table.exchange, table.free) else {
            unsafe { write_message(err_buf, err_cap, "the transport needs exchange and free") };
            return TWIG_STATUS_INVALID_LANGUAGE;
        };
        let host = Arc::new(HostTransport { user_data: table.user_data, exchange, free });
        let mut diag = String::new();
        match wire::register(host, &mut diag) {
            Ok(fmt) => {
                unsafe { put(out_format, format_to_int(fmt)) };
                TWIG_STATUS_OK
            }
            Err(e) => {
                unsafe { write_message(err_buf, err_cap, &diag) };
                status_of_register(e)
            }
        }
    })
}
