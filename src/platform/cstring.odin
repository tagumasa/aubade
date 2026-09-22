// Small shared helpers used across platform files.
package platform

// to_cstring copies into the temp allocator; callers use it within one
// procedure and never free it (temp scratch rule).
to_cstring :: proc(s: string) -> cstring {
	buf := make([]u8, len(s) + 1, context.temp_allocator)
	for i in 0..<len(s) {
		buf[i] = s[i]
	}
	buf[len(s)] = 0
	return cstring(&buf[0])
}
