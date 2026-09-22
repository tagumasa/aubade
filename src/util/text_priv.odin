// Private helpers for src/util/text.odin. Kept in a separate file so the
// public surface in text.odin reads as the LSP-free text utilities only.
package util

// utf16_len returns the number of UTF-16 code units occupied by r: BMP
// runes (≤ U+FFFF) take one unit, anything above takes a surrogate pair
// (two units). Replacements and invalid runes are treated as one unit.
@(private)
utf16_len :: proc(r: rune) -> int {
	if r > 0xFFFF {
		return 2
	}
	return 1
}
