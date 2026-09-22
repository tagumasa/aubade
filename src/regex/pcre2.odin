// Raw PCRE2 8-bit bindings (vendored 10.47, built by tools/build with JIT).
// Only the surface the wrapper needs is declared; handles are rawptr and
// must never be dereferenced here. PCRE2_SIZE is size_t (uint on the
// supported 64-bit targets).
package regex

when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
	foreign import pcre2 { "../../lib/windows_amd64/pcre2-8.lib" }
} else when ODIN_OS == .Windows && ODIN_ARCH == .arm64 {
	foreign import pcre2 { "../../lib/windows_arm64/pcre2-8.lib" }
} else when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 {
	foreign import pcre2 { "../../lib/darwin_amd64/pcre2-8.a" }
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import pcre2 { "../../lib/darwin_arm64/pcre2-8.a" }
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import pcre2 { "../../lib/linux_amd64/pcre2-8.a" }
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
	foreign import pcre2 { "../../lib/linux_arm64/pcre2-8.a" }
} else {
	// The vendored C libraries exist for windows, darwin, and linux on
	// amd64 and arm64 only (lib/<os>_<arch>, tools/build's naming); any
	// other combination fails here instead of at the link line.
	#assert(false)
}

@(default_calling_convention = "c")
foreign pcre2 {
	pcre2_compile_8 :: proc(
		pattern:        ^u8,
		pattern_length: uint,
		options:        u32,
		errorcode:      ^i32,
		erroroffset:    ^uint,
		ccontext:       rawptr,
	) -> rawptr ---
	pcre2_code_free_8 :: proc(code: rawptr) ---
	pcre2_match_data_create_from_pattern_8 :: proc(code: rawptr, gcontext: rawptr) -> rawptr ---
	pcre2_match_data_free_8 :: proc(match_data: rawptr) ---
	pcre2_match_context_create_8 :: proc(gcontext: rawptr) -> rawptr ---
	pcre2_match_context_free_8 :: proc(mcontext: rawptr) ---
	pcre2_set_match_limit_8 :: proc(mcontext: rawptr, value: u32) -> i32 ---
	pcre2_set_depth_limit_8 :: proc(mcontext: rawptr, value: u32) -> i32 ---
	pcre2_match_8 :: proc(
		code:        rawptr,
		subject:     ^u8,
		length:      uint,
		startoffset: uint,
		options:     u32,
		match_data:  rawptr,
		mcontext:    rawptr,
	) -> i32 ---
	pcre2_get_ovector_pointer_8 :: proc(match_data: rawptr) -> [^]uint ---
	pcre2_get_ovector_count_8 :: proc(match_data: rawptr) -> u32 ---
	pcre2_jit_compile_8 :: proc(code: rawptr, options: u32) -> i32 ---
}

// Compile options (subset; values from the vendored pcre2.h).
PCRE2_CASELESS :: u32(0x00000008)
PCRE2_MULTILINE :: u32(0x00000400)
PCRE2_DOTALL :: u32(0x00000020)
PCRE2_JIT_COMPLETE :: u32(0x00000001)
// UTF compile mode: character (rune) semantics for ., bracket classes,
// and quantifiers. MATCH_INVALID_UTF keeps matching safe on subjects with
// non-UTF-8 byte sequences — they simply never match (added in PCRE2
// 10.34; the vendored 10.47 has it).
PCRE2_COMPILE_UTF :: u32(0x00080000)
PCRE2_COMPILE_MATCH_INVALID_UTF :: u32(0x04000000)

// Match results.
PCRE2_ERROR_NOMATCH :: i32(-1)
PCRE2_UNSET :: uint(0xFFFFFFFFFFFFFFFF) // ~PCRE2_SIZE (64-bit targets)

// Match-budget exhaustion (values from the vendored pcre2.h): the
// interpreter reports MATCHLIMIT/DEPTHLIMIT, JIT reports MATCHLIMIT or a
// JIT stack limit — all four shapes mean "the pattern's backtracking ran
// out of budget for this subject", never a hang.
PCRE2_ERROR_JIT_STACKLIMIT :: i32(-46)
PCRE2_ERROR_MATCHLIMIT :: i32(-47)
PCRE2_ERROR_DEPTHLIMIT :: i32(-53)
