#+build !windows

// Captured console output decoding (non-Windows twin): POSIX shells emit
// UTF-8 by contract, so the decode is the identity — a clone owned by
// `a`, keeping one ownership shape for every caller across the seam.
package platform

import "core:strings"

console_output_to_utf8 :: proc(s: string, a := context.allocator) -> string {
	return strings.clone(s, a)
}
