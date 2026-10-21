// The library's version, and the format registry: names to codes and back.
import { Frame, readCString, readI32, readPair, readText, twig } from "./ffi.ts";
import { check, type Format, type FormatLike, Status, TwigError } from "./types.ts";

/** The C ABI layout version this binding reads structs at (`TWIG_ABI_VERSION`). */
export const ABI_VERSION = 6;

/** A `major.minor.patch` version. */
export interface Version {
  major: number;
  minor: number;
  patch: number;
}

/** The twig core's version. */
export function version(): Version {
  const packed = twig.twig_version();
  return { major: (packed >>> 16) & 0xff, minor: (packed >>> 8) & 0xff, patch: packed & 0xff };
}

/** The twig core's version as `"major.minor.patch"`. */
export function versionString(): string {
  return readCString(twig.twig_version_string());
}

/** The C ABI layout version the module was built with. */
export function abiVersion(): number {
  return twig.twig_abi_version();
}

/** The format a name or alias resolves to (`"md"`, `"commonmark"`, `"gfm"`,
 *  `"svg"`), or `null` when twig knows none by it. */
export function formatByName(name: string): Format | null {
  const frame = new Frame();
  try {
    const { ptr, len } = frame.str(name);
    const out = frame.alloc(4);
    const status = twig.twig_format_by_name(ptr, len, out);
    if (status === Status.UnsupportedFormat) return null;
    check(status, "twig_format_by_name");
    return readI32(out);
  } finally {
    frame.dispose();
  }
}

/** The name a format answers to. */
export function formatName(format: FormatLike): string {
  const code = resolveFormat(format);
  const frame = new Frame();
  try {
    const out = frame.alloc(8);
    check(twig.twig_format_name(code, out, out + 4), "twig_format_name", `format ${code}`);
    const [ptr, len] = readPair(out);
    return readText(ptr, len);
  } finally {
    frame.dispose();
  }
}

/** The language a format is a dialect of — Markdown for GFM and
 *  CommonMark, XML for SVG — or `null` for a language's own row. */
export function dialectOf(format: FormatLike): Format | null {
  const code = resolveFormat(format);
  const frame = new Frame();
  try {
    const out = frame.alloc(4);
    const status = twig.twig_format_dialect_of(code, out);
    if (status === Status.NotFound) return null;
    check(status, "twig_format_dialect_of", `format ${code}`);
    return readI32(out);
  } finally {
    frame.dispose();
  }
}

/** A format's code, looking a name up. Throws `UnsupportedFormat` for a name
 *  twig does not know. */
export function resolveFormat(format: FormatLike): Format {
  if (typeof format === "number") return format;
  const code = formatByName(format);
  if (code === null) throw new TwigError(Status.UnsupportedFormat, "twig_format_by_name", `no format named "${format}"`);
  return code;
}
