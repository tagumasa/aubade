// tree-sitter core bindings for the subset aubade uses: parser lifecycle,
// parse trees, node access, and query execution. Adapted from
// laytan/odin-tree-sitter (MIT) — project name and license only, trimmed
// to the surface this codebase consumes.
//
// Memory rules (they mirror the C API): a Parser belongs to its using
// thread; a Tree is freed exactly once with tree_delete; Node and
// Query_Match values BORROW their tree and must never outlive it.
package ts

when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
	foreign import ts "../../lib/windows_amd64/libtree-sitter.lib"
} else when ODIN_OS == .Windows && ODIN_ARCH == .arm64 {
	foreign import ts "../../lib/windows_arm64/libtree-sitter.lib"
} else when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 {
	foreign import ts "../../lib/darwin_amd64/libtree-sitter.a"
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import ts "../../lib/darwin_arm64/libtree-sitter.a"
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import ts "../../lib/linux_amd64/libtree-sitter.a"
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
	foreign import ts "../../lib/linux_arm64/libtree-sitter.a"
} else {
	// The vendored C libraries exist for windows, darwin, and linux on
	// amd64 and arm64 only (lib/<os>_<arch>, tools/build's naming); any
	// other combination fails here instead of at the link line.
	#assert(false)
}

// The latest ABI version supported by this copy of the library.
LANGUAGE_VERSION :: 15

Point :: struct {
	row: u32,
	col: u32,
}

// Opaque handles; distinct so nil-ness stays checkable.
Language     :: distinct rawptr
Parser       :: distinct rawptr
Tree         :: distinct rawptr
Query        :: distinct rawptr
Query_Cursor :: distinct rawptr

Node :: struct {
	ctx:  [4]u32,
	id:   rawptr,
	tree: Tree,
}

Query_Capture :: struct {
	node:  Node,
	index: u32,
}

Query_Match :: struct {
	id:            u32,
	pattern_index: u16,
	capture_count: u16,
	captures:      [^]Query_Capture,
}

Query_Err :: enum i32 {
	None = 0,
	Syntax,
	InvalidNodeType,
	InvalidField,
	InvalidCapture,
	InvalidStructure,
	InvalidLanguage,
}

// One token of a pattern's predicate list. A group of Capture/String steps
// terminated by a Done step spells one predicate: the first String is the
// predicate name, the rest are its arguments.
Query_Predicate_Step_Kind :: enum i32 {
	Done    = 0,
	Capture = 1,
	String  = 2,
}

Query_Predicate_Step :: struct {
	kind:     Query_Predicate_Step_Kind,
	value_id: u32,
}

Input_Encoding :: enum i32 {
	UTF8 = 0,
	UTF16 = 1,
}

// One incremental edit: the byte range [start_byte, old_end_byte) of the
// tree's source became [start_byte, new_end_byte) in the new source.
// Points carry byte columns (tree-sitter counts UTF-8 columns in bytes).
Input_Edit :: struct {
	start_byte:    u32,
	old_end_byte:  u32,
	new_end_byte:  u32,
	start_point:   Point,
	old_end_point: Point,
	new_end_point: Point,
}

@(default_calling_convention = "c")
@(link_prefix="ts_")
foreign ts {
	parser_new :: proc() -> Parser ---
	parser_delete :: proc(self: Parser) ---
	parser_set_language :: proc(self: Parser, language: Language) -> bool ---

	@(link_name="ts_parser_parse_string_encoding")
	parser_parse_string_encoding :: proc(
		self: Parser,
		old_tree: Tree,
		string: cstring,
		length: u32,
		encoding: Input_Encoding,
	) -> Tree ---

	tree_delete :: proc(self: Tree) ---
	tree_root_node :: proc(self: Tree) -> Node ---

	@(link_name="ts_tree_edit")
	tree_edit :: proc(self: Tree, edit: ^Input_Edit) ---

	node_type :: proc(self: Node) -> cstring ---
	node_start_byte :: proc(self: Node) -> u32 ---
	node_end_byte :: proc(self: Node) -> u32 ---
	node_start_point :: proc(self: Node) -> Point ---
	node_end_point :: proc(self: Node) -> Point ---
	node_is_named :: proc(self: Node) -> bool ---
	node_is_error :: proc(self: Node) -> bool ---
	node_is_null :: proc(self: Node) -> bool ---
	node_named_child :: proc(self: Node, child_index: u32) -> Node ---
	node_named_child_count :: proc(self: Node) -> u32 ---
	node_child :: proc(self: Node, child_index: u32) -> Node ---
	node_child_count :: proc(self: Node) -> u32 ---
	@(link_name="ts_node_descendant_count")
	node_descendant_count :: proc(self: Node) -> u32 ---

	@(link_name="ts_node_child_by_field_name")
	node_child_by_field_name :: proc(self: Node, name: cstring, name_length: u32) -> Node ---
	@(link_name="ts_node_has_error")
	node_has_error :: proc(self: Node) -> bool ---

	@(link_name="ts_tree_language")
	tree_language :: proc(self: Tree) -> Language ---

	@(link_name="ts_language_symbol_for_name")
	language_symbol_for_name :: proc(self: Language, name: cstring, name_length: u32, is_named: bool) -> u16 ---
	@(link_name="ts_language_field_count")
	language_field_count :: proc(self: Language) -> u32 ---
	@(link_name="ts_language_field_name_for_id")
	language_field_name_for_id :: proc(self: Language, field_id: u32) -> cstring ---

	@(link_name="ts_query_new")
	query_new :: proc(
		language: Language,
		source: cstring,
		source_len: u32,
		error_offset: ^u32,
		error_type: ^Query_Err,
	) -> Query ---
	query_delete :: proc(self: Query) ---
	query_pattern_count :: proc(self: Query) -> u32 ---
	query_capture_count :: proc(self: Query) -> u32 ---

	@(link_name="ts_query_capture_name_for_id")
	query_capture_name_for_id :: proc(self: Query, index: u32, length: ^u32) -> cstring ---
	@(link_name="ts_query_string_value_for_id")
	query_string_value_for_id :: proc(self: Query, index: u32, length: ^u32) -> cstring ---

	@(link_name="ts_query_predicates_for_pattern")
	query_predicates_for_pattern :: proc(
		self: Query,
		pattern_index: u32,
		length: ^u32,
	) -> [^]Query_Predicate_Step ---

	query_cursor_new :: proc() -> Query_Cursor ---
	query_cursor_delete :: proc(self: Query_Cursor) ---
	query_cursor_exec :: proc(self: Query_Cursor, query: Query, node: Node) ---
	query_cursor_set_match_limit :: proc(self: Query_Cursor, limit: u32) ---

	@(link_name="ts_query_cursor_did_exceed_match_limit")
	query_cursor_did_exceed_match_limit :: proc(self: Query_Cursor) -> bool ---

	@(link_name="ts_query_cursor_next_match")
	query_cursor_next_match :: proc(self: Query_Cursor, match: ^Query_Match) -> bool ---
}
