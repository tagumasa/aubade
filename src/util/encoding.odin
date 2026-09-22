// Text encoding helpers: latin-1 (ISO-8859-1) and UTF-16 byte conversion,
// BOM handling, trailing-newline normalisation. All pure functions: no
// I/O, no regex, no project state.
//
// Symmetry contract: for every supported encoding, decode(encode(x)) == x
// for any buffer x whose runes the encoding can represent (and
// decode(encode(x)) stays a fixed point even for the rest). The editor's
// external-change probe compares decoded disk bytes against the buffer, so
// an asymmetric pair would either reload forever or silently converge the
// buffer onto a degraded disk copy.
package util

import "core:mem"
import "core:strings"
import "core:unicode/utf16"
import "core:unicode/utf8"

UTF8_BOM_BYTE0 :: 0xEF
UTF8_BOM_BYTE1 :: 0xBB
UTF8_BOM_BYTE2 :: 0xBF

// strip_utf8_bom removes a leading UTF-8 BOM (U+FEFF, 0xEF 0xBB 0xBF) from
// `data` if present. Returns the (possibly shortened) slice. The caller
// still owns the original buffer; this is a view, not a copy.
strip_utf8_bom :: proc(data: []byte) -> []byte {
	if has_utf8_bom(data) {
		return data[3:]
	}
	return data
}

// has_utf8_bom reports whether `data` begins with a UTF-8 BOM.
has_utf8_bom :: proc(data: []byte) -> bool {
	return len(data) >= 3 &&
		data[0] == UTF8_BOM_BYTE0 &&
		data[1] == UTF8_BOM_BYTE1 &&
		data[2] == UTF8_BOM_BYTE2
}

// encode_latin1 encodes a UTF-8 string into ISO-8859-1 bytes. Runes > 255
// are unrepresentable and become '?' (a one-time, visible degradation);
// every representable rune maps to exactly its byte, with no BOM
// special-casing — the decoder below never produces a leading U+FEFF from
// latin-1 input, and stripping here would delete the three real
// characters a BOM-looking prefix decodes to. The output is allocated
// from `a`.
encode_latin1 :: proc(s: string, a: mem.Allocator) -> []byte {
	out := make([dynamic]u8, 0, len(s), a)
	for r in s {
		if r > 255 {
			append(&out, '?')
		} else {
			append(&out, u8(r))
		}
	}
	return out[:]
}

// decode_latin1_bytes decodes each byte as a Latin-1 code point. Latin-1
// is a single-byte encoding: every byte is a character, so guessing UTF-8
// (passing valid sequences through) would silently reinterpret genuine
// latin-1 text AND break the encode symmetry for anything above 0x7F.
// The output is allocated from `a`.
decode_latin1_bytes :: proc(data: []byte, a: mem.Allocator) -> string {
	buf := make([]rune, len(data), a)
	defer delete(buf, a)
	for b, i in data {
		buf[i] = rune(b)
	}
	return utf8.runes_to_string(buf, a)
}

// utf16_encoding reports whether `encoding` names UTF-16 and, if so, the
// byte order to write. "utf-16"/"utf16"/"utf-16le"/"utf16le" are
// little-endian (the Windows convention for the bare name); the explicit
// -be spellings are big-endian. Case-insensitive.
utf16_encoding :: proc(encoding: string) -> (is_utf16: bool, big_endian: bool) {
	if strings.equal_fold(encoding, "utf-16") ||
	   strings.equal_fold(encoding, "utf16") ||
	   strings.equal_fold(encoding, "utf-16le") ||
	   strings.equal_fold(encoding, "utf16le") {
		return true, false
	}
	if strings.equal_fold(encoding, "utf-16be") || strings.equal_fold(encoding, "utf16be") {
		return true, true
	}
	return false, false
}

// decode_utf16_bytes decodes UTF-16 file bytes into a UTF-8 string. The
// BOM selects the byte order (FF FE = LE, FE FF = BE); a file without one
// decodes as little-endian. Unpaired surrogates become U+FFFD and an odd
// trailing byte is dropped — the result is always a valid UTF-8 string.
// The output is allocated from `a`.
decode_utf16_bytes :: proc(data: []byte, a: mem.Allocator) -> string {
	le := true
	body := data
	if len(data) >= 2 {
		if data[0] == 0xFF && data[1] == 0xFE {
			body = data[2:]
		} else if data[0] == 0xFE && data[1] == 0xFF {
			le = false
			body = data[2:]
		}
	}
	units := make([]u16, len(body) / 2, a)
	defer delete(units, a)
	for i := 0; i < len(units); i += 1 {
		lo := body[i * 2]
		hi := body[i * 2 + 1]
		if le {
			units[i] = u16(lo) | (u16(hi) << 8)
		} else {
			units[i] = u16(hi) | (u16(lo) << 8)
		}
	}
	runes := make([]rune, len(units), a)
	defer delete(runes, a)
	n := utf16.decode(runes, units)
	return utf8.runes_to_string(runes[:n], a)
}

// encode_utf16_bytes encodes a UTF-8 string as UTF-16 in the requested
// byte order, always with a BOM (self-describing files; the decoder
// accepts either order, so the round trip is stable whichever side wrote
// the file). The output is allocated from `a`.
encode_utf16_bytes :: proc(s: string, big_endian: bool, a: mem.Allocator) -> []byte {
	// len(s) bytes cannot hold more than len(s) runes, and each rune is
	// at most one unit pair member: len(s) + 1 units always suffice.
	units := make([]u16, len(s) + 1, a)
	defer delete(units, a)
	units[0] = 0xFEFF
	n := utf16.encode_string(units[1:], s)
	out := make([]u8, (n + 1) * 2, a)
	w := 0
	for u in units[:n + 1] {
		lo := u8(u & 0xFF)
		hi := u8((u >> 8) & 0xFF)
		if big_endian {
			out[w] = hi
			out[w + 1] = lo
		} else {
			out[w] = lo
			out[w + 1] = hi
		}
		w += 2
	}
	return out
}

// hex_digit_value maps one ASCII hex digit to 0..15, -1 when the byte is
// not a hex digit — the shared leaf of the URI percent-decoder and the
// search-layer query codec (core:encoding/hex keeps its digit helper
// private).
hex_digit_value :: proc(c: u8) -> int {
	if c >= '0' && c <= '9' {
		return int(c - '0')
	}
	if c >= 'a' && c <= 'f' {
		return int(c - 'a') + 10
	}
	if c >= 'A' && c <= 'F' {
		return int(c - 'A') + 10
	}
	return -1
}

// ensure_trailing_newline returns s with a single '\n' appended if it did
// not already end with one. The empty string is left empty. The returned
// string is allocated from `a` when an append is needed.
ensure_trailing_newline :: proc(s: string, a: mem.Allocator) -> string {
	if len(s) == 0 {
		return s
	}
	if s[len(s) - 1] == '\n' {
		return strings.clone(s, a)
	}
	return strings.concatenate({s, "\n"}, a)
}

// is_latin1_encoding reports whether `encoding` names the latin-1 codec
// (either accepted spelling) — the one predicate behind every codec
// dispatch.
is_latin1_encoding :: proc(encoding: string) -> bool {
	return strings.equal_fold(encoding, "latin-1") || strings.equal_fold(encoding, "iso-8859-1")
}

// encode_content picks the byte encoding for `content` based on
// `encoding`:
//   "utf-8" / "utf8" / ""                → raw bytes (a view, not owned)
//   "latin-1" / "iso-8859-1"             → encode_latin1 (owned)
//   "utf-16" / "utf-16le" / "utf-16be"   → encode_utf16_bytes (owned)
//   anything else                        → raw bytes (a view, not owned)
//
// The second return says whether the output is owned (the caller must
// delete(bytes, a)); the view paths must not be freed.
encode_content :: proc(encoding: string, content: string, a: mem.Allocator) -> (bytes: []byte, owned: bool) {
	if strings.equal_fold(encoding, "utf-8") || strings.equal_fold(encoding, "utf8") {
		return transmute([]byte)content, false
	}
	if is_latin1_encoding(encoding) {
		return encode_latin1(content, a), true
	}
	if is16, be := utf16_encoding(encoding); is16 {
		return encode_utf16_bytes(content, be, a), true
	}
	return transmute([]byte)content, false
}

// decode_content is encode_content's inverse: it picks the decode for
// `data` based on `encoding`:
//   "latin-1" / "iso-8859-1"              → decode_latin1_bytes (fresh copy)
//   "utf-16" / "utf-16le" / "utf-16be"    → decode_utf16_bytes (fresh copy)
//   anything else (the UTF-8 class)       → BOM strip or a view
//
// Returns the decoded text, whether the bytes carried a UTF-8 BOM
// (stripped from the text; UTF-16 consumes its BOM as the byte-order
// marker, latin-1 keeps those bytes as content, so both report false),
// and whether `data`'s backing was handed over as the result — the
// caller must not free `data` then. Every other path allocates in `a`
// and leaves `data` caller-owned. The view is only taken when the text
// needs no further transformation (no BOM, no CRLF): the latin-1 and
// UTF-16 classes would re-encode, and a CRLF fold must be able to free
// its input, which a handed-over view is not.
decode_content :: proc(encoding: string, data: []byte, a: mem.Allocator) -> (text: string, had_utf8_bom: bool, transferred: bool) {
	if is_latin1_encoding(encoding) {
		return decode_latin1_bytes(data, a), false, false
	}
	if is16, _ := utf16_encoding(encoding); is16 {
		return decode_utf16_bytes(data, a), false, false
	}
	if has_utf8_bom(data) {
		return strings.clone(string(strip_utf8_bom(data)), a), true, false
	}
	if !strings.contains(string(data), "\r\n") {
		// The common file shape: the caller's buffer already holds the
		// answer — hand it over instead of paying a full-file clone per
		// read.
		return string(data), false, true
	}
	return strings.clone(string(data), a), false, false
}
