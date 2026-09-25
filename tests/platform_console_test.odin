// Console output decode seam: valid UTF-8 passes through with its content
// intact on every platform (the Windows twin's OEM re-encode only touches
// input that is NOT valid UTF-8, and that path runs on the CI matrix).
package tests

import "core:testing"

import "src:platform"

@(test)
console_output_decode_keeps_utf8 :: proc(t: ^testing.T) {
	out := platform.console_output_to_utf8("café — 日本語 OK", context.allocator)
	defer delete(out)
	testing.expect_value(t, out, "café — 日本語 OK")

	empty := platform.console_output_to_utf8("", context.allocator)
	testing.expect_value(t, empty, "")
}
