// Raw SQLite bindings (vendored amalgamation, built by tools/build into
// lib/<os>_<arch>/sqlite3.a). Only the surface the store wrapper needs is
// declared; handles are rawptr and must never be dereferenced here. The
// SQLITE_TRANSIENT destructor constant tells SQLite to copy bound data
// before returning, so callers may free their buffers immediately.
package store

when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
	foreign import sqlite { "../../lib/windows_amd64/sqlite3.lib" }
} else when ODIN_OS == .Windows && ODIN_ARCH == .arm64 {
	foreign import sqlite { "../../lib/windows_arm64/sqlite3.lib" }
} else when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 {
	foreign import sqlite { "../../lib/darwin_amd64/sqlite3.a" }
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import sqlite { "../../lib/darwin_arm64/sqlite3.a" }
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import sqlite { "../../lib/linux_amd64/sqlite3.a" }
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
	foreign import sqlite { "../../lib/linux_arm64/sqlite3.a" }
} else {
	// The vendored C libraries exist for windows, darwin, and linux on
	// amd64 and arm64 only (lib/<os>_<arch>, tools/build's naming); any
	// other combination fails here instead of at the link line.
	#assert(false)
}

@(default_calling_convention = "c")
foreign sqlite {
	sqlite3_open_v2 :: proc(
		filename: cstring,
		db:        ^rawptr,
		flags:     i32,
		z_vfs:     cstring,
	) -> i32 ---
	sqlite3_close_v2 :: proc(db: rawptr) -> i32 ---
	sqlite3_exec :: proc(
		db:          rawptr,
		sql:         cstring,
		callback:    rawptr,
		callback_arg: rawptr,
		errmsg:      ^cstring,
	) -> i32 ---
	sqlite3_prepare_v2 :: proc(
		db:        rawptr,
		z_sql:     cstring,
		n_byte:    i32,
		stmt:      ^rawptr,
		tail:      ^cstring,
	) -> i32 ---
	sqlite3_bind_text :: proc(stmt: rawptr, idx: i32, text: cstring, n: i32, destructor: rawptr) -> i32 ---
	sqlite3_bind_int64 :: proc(stmt: rawptr, idx: i32, value: i64) -> i32 ---
	sqlite3_bind_blob :: proc(stmt: rawptr, idx: i32, data: rawptr, n: i32, destructor: rawptr) -> i32 ---
	sqlite3_bind_zeroblob :: proc(stmt: rawptr, idx: i32, n: i32) -> i32 ---
	sqlite3_bind_null :: proc(stmt: rawptr, idx: i32) -> i32 ---
	sqlite3_step :: proc(stmt: rawptr) -> i32 ---
	sqlite3_reset :: proc(stmt: rawptr) -> i32 ---
	sqlite3_clear_bindings :: proc(stmt: rawptr) -> i32 ---
	sqlite3_finalize :: proc(stmt: rawptr) -> i32 ---
	sqlite3_column_text :: proc(stmt: rawptr, column: i32) -> cstring ---
	sqlite3_column_blob :: proc(stmt: rawptr, column: i32) -> rawptr ---
	sqlite3_column_bytes :: proc(stmt: rawptr, column: i32) -> i32 ---
	sqlite3_column_int64 :: proc(stmt: rawptr, column: i32) -> i64 ---
	sqlite3_column_count :: proc(stmt: rawptr) -> i32 ---
	sqlite3_column_type :: proc(stmt: rawptr, column: i32) -> i32 ---
	sqlite3_errmsg :: proc(db: rawptr) -> cstring ---
	sqlite3_busy_timeout :: proc(db: rawptr, ms: i32) -> i32 ---
	sqlite3_changes :: proc(db: rawptr) -> i32 ---
}

SQLITE_OK :: i32(0)
SQLITE_ROW :: i32(100)
SQLITE_DONE :: i32(101)

SQLITE_INTEGER :: i32(1)
SQLITE_FLOAT :: i32(2)
SQLITE_TEXT :: i32(3)
SQLITE_BLOB :: i32(4)
SQLITE_NULL :: i32(5)

SQLITE_OPEN_READWRITE :: i32(0x00000002)
SQLITE_OPEN_CREATE :: i32(0x00000004)
SQLITE_OPEN_FULLMUTEX :: i32(0x00010000)

// The special destructor argument that makes SQLite copy bound values:
// (sqlite3_destructor_type)-1 in the C header, bit-cast to a pointer.
SQLITE_TRANSIENT :: cast(rawptr)uintptr(0xFFFFFFFFFFFFFFFF)
