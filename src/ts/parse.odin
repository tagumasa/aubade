// Parse pipeline and S-expression projection over the registry. The parse
// result borrows the caller's source string; the tree is released with
// parse_release (nodes and query matches must not outlive it).
package ts

import "core:strings"
import "core:unicode/utf8"

Parse_Result :: struct {
	tree:   Tree,
	lang:   Language,
	source: string, // borrowed from the caller
}

parse :: proc(code: string, lang_name: string) -> (res: Parse_Result, err: string) {
	return parse_with_old(code, lang_name, nil)
}

// parse_with_old parses with a reuse base: old_tree must already carry
// the ts_tree_edit describing how its source changed (tree_edit alone
// only shifts existing node ranges — the re-parse materializes nodes
// for inserted text while reusing every unchanged subtree).
parse_with_old :: proc(code: string, lang_name: string, old_tree: Tree) -> (res: Parse_Result, err: string) {
	idx, ok := registry_lookup(lang_name)
	if !ok {
		return {}, strings.concatenate({"unsupported language: ", lang_name}, context.temp_allocator)
	}

	lang, available := registry_language(idx)
	if !available {
		return {}, strings.concatenate({"language unavailable on this platform: ", lang_name}, context.temp_allocator)
	}
	parser := parser_new()
	if parser == nil {
		return {}, strings.concatenate({"failed to load language: ", lang_name}, context.temp_allocator)
	}
	defer parser_delete(parser)
	if !parser_set_language(parser, lang) {
		return {}, strings.concatenate({"failed to load language: ", lang_name}, context.temp_allocator)
	}

	// The source passes by pointer: tree-sitter's string-input read
	// callback (ts_string_input_read, v0.26.9) clamps every read to the
	// explicit length and signals end-of-input by that same bound — a NUL
	// terminator is never consulted — so the clone_to_cstring whole-file
	// copy every parse paid is gone. A zero-length source hands a nil
	// pointer, which the callback's `byte >= length` guard makes harmless.
	buf := cast(cstring)raw_data(transmute([]u8)code)
	tree := parser_parse_string_encoding(parser, old_tree, buf, u32(len(code)), .UTF8)
	if tree == nil {
		return {}, strings.concatenate({"parser returned nil tree for language: ", lang_name}, context.temp_allocator)
	}
	return {tree = tree, lang = lang, source = code}, ""
}

// parse_release frees the tree exactly once; the result is unusable after.
parse_release :: proc(res: ^Parse_Result) {
	if res.tree != nil {
		tree_delete(res.tree)
		res.tree = nil
	}
}

parse_root :: proc(res: ^Parse_Result) -> Node {
	if res.tree == nil {
		// A released (or never-parsed) result has no tree to root at.
		return {}
	}
	return tree_root_node(res.tree)
}

// ---------------------------------------------------------------------------
// S-expression projection
// ---------------------------------------------------------------------------

MAX_LEAF_TEXT_LEN :: 100
MAX_SEXPR_DEPTH :: 5000
MAX_SEXPR_BYTES :: 4 << 20 // 4 MiB

to_s_expr :: proc(root: Node, source: string, max_bytes_param: int) -> string {
	max_bytes := max_bytes_param
	if node_is_null(root) {
		return ""
	}
	if max_bytes <= 0 {
		max_bytes = MAX_SEXPR_BYTES
	}
	b := strings.builder_make(context.temp_allocator)
	node_s_expr(root, source, &b, 0, max_bytes)
	return strings.to_string(b)
}

node_s_expr :: proc(node: Node, source: string, b: ^strings.Builder, depth: int, max_bytes: int) -> bool {
	if node_is_null(node) {
		return true
	}
	if depth > MAX_SEXPR_DEPTH {
		strings.write_string(b, "(...)")
		return false
	}
	if strings.builder_len(b^) > max_bytes {
		return false
	}

	node_kind := cstring_to_string(node_type(node))

	if node_is_error(node) {
		strings.write_string(b, "(ERROR \"Syntax error detected\")")
		return true
	}

	child_count := int(node_named_child_count(node))
	if child_count == 0 {
		text := node_text(node, source)
		strings.write_byte(b, '(')
		strings.write_string(b, node_kind)
		strings.write_string(b, " \"")
		if len(text) >= MAX_LEAF_TEXT_LEN {
			strings.write_string(b, "<too long>")
		} else if len(text) > 0 {
			strings.write_string(b, clean_string_for_display(text, context.temp_allocator))
		}
		strings.write_byte(b, '"')
		strings.write_byte(b, ')')
		return true
	}

	strings.write_byte(b, '(')
	strings.write_string(b, node_kind)
	for i in 0..<child_count {
		child := node_named_child(node, u32(i))
		if !node_is_null(child) {
			strings.write_byte(b, ' ')
			if !node_s_expr(child, source, b, depth + 1, max_bytes) {
				strings.write_byte(b, ')')
				return false
			}
		}
	}
	strings.write_byte(b, ')')
	return true
}

// node_text returns the node's byte span from the source, bounds-checked
// (invalid spans yield "").
node_text :: proc(node: Node, source: string) -> string {
	if node_is_null(node) || len(source) == 0 {
		return ""
	}
	start := int(node_start_byte(node))
	end := int(node_end_byte(node))
	if start < 0 || end > len(source) || start > end {
		return ""
	}
	return source[start:end]
}

// clean_string_for_display escapes backslashes and quotes and replaces
// invalid runes and C0 controls with spaces.
clean_string_for_display :: proc(s: string, a := context.allocator) -> string {
	buf := make([dynamic]u8, 0, len(s), a)
	i := 0
	for i < len(s) {
		r, size := rune_decode(s[i:])
		if r == RUNE_ERROR && size == 1 {
			append(&buf, ' ')
			i += 1
			continue
		}
		switch r {
		case '\\':
			append(&buf, "\\\\")
		case '"':
			append(&buf, "\\\"")
		case:
			if r < 0x20 {
				append(&buf, ' ')
			} else {
				append_rune(&buf, r)
			}
		}
		i += size
	}
	return string(buf[:])
}

RUNE_ERROR :: 0xFFFD

rune_decode :: proc(s: string) -> (rune, int) {
	return utf8.decode_rune_in_string(s)
}

append_rune :: proc(buf: ^[dynamic]u8, r: rune) {
	// UTF-8 encode (r is a valid non-control rune here).
	if r < 0x80 {
		append(buf, u8(r))
		return
	}
	if r < 0x800 {
		append(buf, u8(0xC0 | (r >> 6)))
		append(buf, u8(0x80 | (r & 0x3F)))
		return
	}
	if r < 0x10000 {
		append(buf, u8(0xE0 | (r >> 12)))
		append(buf, u8(0x80 | ((r >> 6) & 0x3F)))
		append(buf, u8(0x80 | (r & 0x3F)))
		return
	}
	append(buf, u8(0xF0 | (r >> 18)))
	append(buf, u8(0x80 | ((r >> 12) & 0x3F)))
	append(buf, u8(0x80 | ((r >> 6) & 0x3F)))
	append(buf, u8(0x80 | (r & 0x3F)))
}

cstring_to_string :: proc(c: cstring) -> string {
	if c == nil {
		return ""
	}
	return string(c)
}
