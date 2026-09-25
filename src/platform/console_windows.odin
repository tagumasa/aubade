#+build windows

// Captured console output decoding (Windows twin). cmd.exe emits captured
// stdout/stderr in the OEM code page of the install locale (cp437/cp850/
// cp932/...) unless the session switched the console to UTF-8, while every
// consumer downstream of a capture treats the bytes as UTF-8 — a straight
// passthrough turns each non-ASCII byte of a dir listing into U+FFFD at
// the JSON quoting layer. The decode validates strictly first (a session
// that DID switch to UTF-8 must pass through untouched) and re-encodes
// only invalid input, OEM page → UTF-16 → UTF-8. core:sys/windows ships
// both conversion procs and the code-page constants, so this seam carries
// no foreign block of its own.
package platform

import "core:strings"
import "core:sys/windows"

// console_output_to_utf8 returns `s` as a UTF-8 string owned by `a`:
// valid UTF-8 is cloned through unchanged, anything else is read as OEM
// code-page text and re-encoded. A conversion failure falls back to the
// raw bytes cloned — the caller's JSON quoting still renders something
// rather than empty output.
console_output_to_utf8 :: proc(s: string, a := context.allocator) -> string {
	if len(s) == 0 {
		return ""
	}
	bytes := transmute([]u8)s
	raw := strings.clone(s, a)
	src := &bytes[0]
	src_len := cast(i32)len(s)

	// Strict validation: a positive wide-count means every byte sequence
	// is already valid UTF-8.
	if windows.MultiByteToWideChar(windows.CP_UTF8, windows.MB_ERR_INVALID_CHARS, src, src_len, nil, 0) > 0 {
		return raw
	}

	wide_len := windows.MultiByteToWideChar(windows.CP_OEMCP, 0, src, src_len, nil, 0)
	if wide_len <= 0 {
		return raw
	}
	wide := make([]u16, wide_len, a)
	defer delete(wide, a)
	if windows.MultiByteToWideChar(windows.CP_OEMCP, 0, src, src_len, &wide[0], wide_len) <= 0 {
		return raw
	}

	utf8_len := windows.WideCharToMultiByte(
		windows.CP_UTF8, windows.WC_ERR_INVALID_CHARS,
		cast(cstring16)&wide[0], wide_len,
		nil, 0, nil, nil,
	)
	if utf8_len <= 0 {
		return raw
	}
	out := make([]u8, utf8_len, a)
	if windows.WideCharToMultiByte(
		windows.CP_UTF8, windows.WC_ERR_INVALID_CHARS,
		cast(cstring16)&wide[0], wide_len,
		&out[0], utf8_len,
		nil, nil,
	) <= 0 {
		delete(out, a)
		return raw
	}
	delete(raw, a)
	return string(out[:])
}
