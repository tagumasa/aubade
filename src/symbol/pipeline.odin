// The shared symbol-tree post-processing pipeline: method re-nesting,
// parent assignment, overload indices, location enrichment, and body
// extraction. The tree-sitter source (outline conversion) and the LSP
// documentSymbol source both run their trees through
// finalize_symbol_tree so name paths, parents, and bodies behave
// identically regardless of producer.
package symbol

import "base:runtime"
import "core:strings"

import "src:util"

// Normalize_Name_Proc rewrites a document symbol name for language-specific
// conventions: it returns the normalized name and, for receiver-qualified
// methods, the receiver type name the symbol should nest under.
Normalize_Name_Proc :: proc(kind: Symbol_Kind, name: string, rel_path: string) -> (normalized: string, receiver: string)

Pipeline_Options :: struct {
	// alloc owns every string the pipeline allocates (the forest's
	// allocator).
	allocator:    runtime.Allocator,
	// normalize is the optional per-language rename hook (nil = none).
	normalize:    Normalize_Name_Proc,
	// abs_path and rel_path identify the file the symbols belong to.
	abs_path:     string,
	rel_path:     string,
	// body_factory extracts symbol bodies; nil skips body extraction.
	body_factory: ^Body_Factory,
}

// finalize_symbol_tree runs the full pipeline over a freshly produced
// forest and returns the possibly shortened list of top-level symbols (in
// `a`, the forest's allocator).
finalize_symbol_tree :: proc(roots_in: []^Symbol, opts: Pipeline_Options) -> []^Symbol {
	roots := roots_in
	roots = normalize_and_nest_methods(roots, opts.normalize, opts.rel_path, opts.allocator)
	assign_symbol_parents(roots, nil)
	assign_overload_indices(roots)
	ensure_symbol_locations(roots, opts.abs_path, opts.rel_path, opts.allocator)
	if opts.body_factory != nil {
		populate_symbol_bodies(roots, opts.body_factory, 0, opts.allocator)
	}
	return roots
}

// normalize_and_nest_methods renames receiver-qualified method symbols
// (e.g. Go's "(*Type).Method" reported as top-level symbols by gopls) to
// their bare method names and nests them under the sibling type symbol
// matching the receiver, so name paths take the "Type/Method" form.
// Methods whose receiver type is not declared in the same file stay at the
// top level with their bare name. Returns the possibly shortened slice.
normalize_and_nest_methods :: proc(
	roots: []^Symbol,
	hook: Normalize_Name_Proc,
	rel_path: string,
	a: runtime.Allocator,
) -> []^Symbol {
	if len(roots) == 0 {
		return roots
	}

	// Collect the method bindings (symbol pointer + receiver name).
	methods := make([dynamic]^Symbol, 0, 4, context.temp_allocator)
	receivers := make([dynamic]string, 0, 4, context.temp_allocator)
	for sym in roots {
		if sym == nil {
			continue
		}
		recv := ""
		if hook != nil {
			name, recv_hook := hook(sym.kind, sym.name, rel_path)
			// The hook's returns may alias sym.name (substrings of it — the
			// borrow does not survive the old string's release): clone everything
			// that must survive the old string's release, then swap.
			new_name := clone_string(name, a)
			if recv_hook != "" {
				recv = clone_string(recv_hook, context.temp_allocator)
			}
			if sym.name != "" {
				delete(sym.name, a) // the node owns its name clone
			}
			sym.name = new_name
		}
		if recv == "" && sym.container_name != "" && sym.kind == .Method {
			// Flat SymbolInformation responses carry the owning type in
			// containerName instead of qualifying the method name.
			recv = sym.container_name
		}
		if recv != "" {
			append(&methods, sym)
			append(&receivers, recv)
		}
	}
	if len(methods) == 0 {
		return roots
	}

	by_name := make(map[string]^Symbol, len(roots), context.temp_allocator)
	for sym in roots {
		if sym == nil || sym.name == "" {
			continue
		}
		if _, exists := by_name[sym.name]; !exists {
			by_name[sym.name] = sym
		}
	}

	moved := make(map[^Symbol]bool, len(methods), context.temp_allocator)
	for i in 0..<len(methods) {
		target, ok := by_name[receivers[i]]
		if !ok || target == methods[i] || moved[target] {
			continue
		}
		// A leaf's children list starts nil (the outline only pre-creates
		// lists for nested captures); appending to nil would grow through
		// context.allocator — the wrong owner once the forest rides an
		// arena. Materialize the list on the forest's allocator first.
		if target.children == nil {
			target.children = make([dynamic]^Symbol, 0, 2, a)
		}
		append(&target.children, methods[i])
		moved[methods[i]] = true
	}
	if len(moved) == 0 {
		return roots
	}

	// `a`, not temp: the returned slice IS the forest's root list and the
	// caller destroys it through `a`.
	remaining := make([dynamic]^Symbol, 0, len(roots), a)
	for sym in roots {
		if sym == nil || moved[sym] {
			continue
		}
		append(&remaining, sym)
	}
	// Ownership transfer: `remaining` replaces the freshly produced input
	// root list (contract: allocated from `a`), so free its backing instead
	// of stranding it.
	delete(roots, a)
	return remaining[:]
}

// assign_symbol_parents links every symbol to its parent so name paths can
// walk upward.
assign_symbol_parents :: proc(symbols: []^Symbol, parent: ^Symbol, depth := 0) {
	for sym in symbols {
		sym.parent = parent
		if len(sym.children) > 0 && depth < MAX_TREE_DEPTH {
			assign_symbol_parents(sym.children[:], sym, depth + 1)
		}
	}
}

// assign_overload_indices numbers same-named sibling symbols (e.g. method
// overloads) so name paths can disambiguate them.
assign_overload_indices :: proc(symbols: []^Symbol, depth := 0) {
	name_counts := make(map[string]int, len(symbols), context.temp_allocator)
	for sym in symbols {
		name_counts[sym.name] += 1
	}
	overload_counter := make(map[string]int, len(symbols), context.temp_allocator)
	for sym in symbols {
		if name_counts[sym.name] > 1 {
			idx := overload_counter[sym.name]
			overload_counter[sym.name] = idx + 1
			sym.overload_idx = idx
		}
		if len(sym.children) > 0 && depth < MAX_TREE_DEPTH {
			assign_overload_indices(sym.children[:], depth + 1)
		}
	}
}

// ensure_symbol_locations fills the Location and SelectionRange fields that
// hierarchical or synthesized trees may leave empty, anchoring every symbol
// to the given file. Strings are cloned in `a`.
ensure_symbol_locations :: proc(symbols: []^Symbol, abs_path: string, rel_path: string, a: runtime.Allocator, depth := 0) {
	for sym in symbols {
		if sym == nil {
			continue
		}
		if sym.location == nil {
			loc := new(Location, a)
			if sym.range != nil {
				loc.range = sym.range^
			}
			loc.uri = file_uri(abs_path, a)
			loc.abs_path = clone_string(abs_path, a)
			loc.rel_path = clone_string(rel_path, a)
			sym.location = loc
		} else {
			if sym.location.abs_path == "" {
				sym.location.abs_path = clone_string(abs_path, a)
			}
			if sym.location.rel_path == "" {
				sym.location.rel_path = clone_string(rel_path, a)
			}
		}
		if sym.selection_range == nil {
			if sym.range != nil {
				// Alias of the node's own range: symbol_node_free skips it
				// via its `!= s.range` guard.
				sym.selection_range = sym.range
			} else if sym.location != nil {
				// Owning copy — never &sym.location.range: that interior
				// pointer would be freed as if it were an allocation.
				sel := new(Range, a)
				sel^ = sym.location.range
				sym.selection_range = sel
			}
		}
		if depth < MAX_TREE_DEPTH {
			ensure_symbol_locations(sym.children[:], abs_path, rel_path, a, depth + 1)
		}
	}
}

// file_uri renders an absolute path as a file:// URI: forward slashes, a
// leading '/' after the authority (three slashes for POSIX paths and
// Windows drive letters alike), and percent-encoding for every byte
// outside the unreserved set — so `%`, `#`, `?`, spaces, and non-ASCII
// survive the round trip (a raw `%` would decode into a different path)
// and servers open the document we meant. The single encoder for every
// LSP URI this codebase sends.
file_uri :: proc(abs_path: string, a: runtime.Allocator) -> string {
	out := make([dynamic]u8, 0, len(abs_path) + 16, a)
	prefix := "file://"
	for i := 0; i < len(prefix); i += 1 {
		append(&out, prefix[i])
	}
	unc := false
	when ODIN_OS == .Windows {
		// A UNC path (\\server\share\x) puts the server in the URI's
		// authority: file://server/share/x. The two leading separators
		// already are the authority delimiters, so no extra slash is
		// added — a fourth slash would empty the authority and no server
		// resolves the share back.
		unc = len(abs_path) >= 2 &&
			(abs_path[0] == '/' || abs_path[0] == '\\') &&
			(abs_path[1] == '/' || abs_path[1] == '\\')
	}
	if !unc && (len(abs_path) == 0 || abs_path[0] != '/') {
		// A path without the leading slash (a Windows drive form) still
		// needs the authority-terminating slash: file:///C:/x.
		append(&out, '/')
	}
	// Under `unc` the two leading separators already ARE the authority
	// delimiters the prefix wrote; encoding them again would yield
	// file:////server/... — an empty authority no server resolves.
	start := 0
	when ODIN_OS == .Windows {
		if unc {
			start = 2
		}
	}
	for i := start; i < len(abs_path); i += 1 {
		c := abs_path[i]
		if c == '\\' {
			c = '/'
		}
		if c == '/' || uri_unreserved(c) {
			append(&out, c)
		} else {
			append(&out, '%')
			append(&out, uri_hex_digit(c >> 4))
			append(&out, uri_hex_digit(c & 0x0F))
		}
	}
	return string(out[:])
}

uri_unreserved :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') ||
		(c >= 'A' && c <= 'Z') ||
		(c >= '0' && c <= '9') ||
		c == '-' || c == '.' || c == '_' || c == '~'
}

uri_hex_digit :: proc(nibble: u8) -> u8 {
	if nibble < 10 {
		return '0' + nibble
	}
	return 'A' + nibble - 10
}

// populate_symbol_bodies extracts each symbol's body text from the factory
// contents, respecting a recursion depth limit. The limit is MAX_TREE_DEPTH —
// the same cap the builders place on the forest — so no symbol inside a
// buildable tree silently loses its body.
populate_symbol_bodies :: proc(symbols: []^Symbol, factory: ^Body_Factory, depth: int, a: runtime.Allocator) {
	if depth > MAX_TREE_DEPTH {
		return
	}
	for sym in symbols {
		if sym == nil {
			continue
		}
		if !sym.has_body && sym.range != nil {
			text := body_factory_text(factory, sym)
			if text != "" {
				sym.body = clone_string(text, a)
				sym.has_body = true
			}
		}
		if len(sym.children) > 0 {
			populate_symbol_bodies(sym.children[:], factory, depth + 1, a)
		}
	}
}

// ---------------------------------------------------------------------------
// Body factory
// ---------------------------------------------------------------------------

// Body_Factory extracts symbol body text from the file contents it was
// built from. Its line table is a set of views into those contents — no
// per-line copies — so the factory (and every body slice read through
// body_factory_text before populate clones it) must not outlive them.
// Every caller builds factory and contents in the same scratch arena;
// keep that shape.
Body_Factory :: struct {
	lines:      [dynamic]string,
	owns_lines: bool, // reserved for a cloning constructor; views never own
	allocator:  runtime.Allocator,
}

// body_factory_from_contents slices `contents` into the line table as
// views — a per-line clone of the whole body-extraction pass buys nothing
// under the lifetime contract above.
body_factory_from_contents :: proc(contents: string, a := context.allocator) -> ^Body_Factory {
	f := new(Body_Factory, a)
	f^ = {allocator = a}
	f.lines = make([dynamic]string, 0, 64, a)
	line_start := 0
	for i := 0; i <= len(contents); i += 1 {
		if i < len(contents) && contents[i] != '\n' {
			continue
		}
		line := contents[line_start:i]
		// Mirror a "\n" split: drop the \r of a \r\n ending.
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		append(&f.lines, line)
		line_start = i + 1
	}
	return f
}

body_factory_destroy :: proc(f: ^Body_Factory) {
	if f == nil {
		return
	}
	if f.owns_lines {
		for i in 0..<len(f.lines) {
			delete(f.lines[i], f.allocator)
		}
	}
	delete(f.lines) // dynamic arrays free through their carried allocator
	a := f.allocator
	free(f, a)
}

// body_factory_text extracts the body for a symbol's full extent range:
// the tail of the start line from the range start, any middle lines
// verbatim, then the head of the end line up to the range end. The result
// is scratch (temp allocator).
body_factory_text :: proc(f: ^Body_Factory, sym: ^Symbol) -> string {
	if sym == nil || sym.range == nil {
		return ""
	}
	return body_text(
		f.lines[:],
		int(sym.range.start.line),
		int(sym.range.start.character),
		int(sym.range.end.line),
		int(sym.range.end.character),
	)
}

// body_text extracts the body for a symbol's full extent range: the tail
// of the start line from the range start, any middle lines verbatim, then
// the head of the end line up to the range end. Columns arrive as UTF-16
// code units (the position convention end to end) and are converted to
// byte offsets per line before slicing — lines with non-ASCII content
// would otherwise shift or truncate the body. The result is scratch (temp
// allocator).
body_text :: proc(lines: []string, start_line, start_col, end_line, end_col: int) -> string {
	if start_line > end_line || end_line >= len(lines) {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	if start_line == end_line {
		line := lines[start_line]
		start_byte := util.utf16_col_to_byte_offset(line, start_col)
		if start_byte >= len(line) {
			return ""
		}
		end_byte := util.utf16_col_to_byte_offset(line, end_col)
		if end_byte < start_byte {
			end_byte = start_byte
		}
		if end_byte > len(line) {
			strings.write_string(&b, line[start_byte:])
		} else {
			strings.write_string(&b, line[start_byte:end_byte])
		}
		return strings.to_string(b)
	}

	first := lines[start_line]
	start_byte := util.utf16_col_to_byte_offset(first, start_col)
	if start_byte < len(first) {
		strings.write_string(&b, first[start_byte:])
	}
	for i in start_line + 1..<end_line {
		strings.write_byte(&b, '\n')
		strings.write_string(&b, lines[i])
	}
	strings.write_byte(&b, '\n')
	last := lines[end_line]
	end_byte := util.utf16_col_to_byte_offset(last, end_col)
	if end_byte > len(last) {
		strings.write_string(&b, last)
	} else {
		strings.write_string(&b, last[:end_byte])
	}
	return strings.to_string(b)
}
