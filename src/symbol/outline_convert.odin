// Conversion from the tree-sitter outline projection into the unified
// symbol model, with byte-offset→LSP-position translation. This is the
// tree-sitter half of the symbol pipeline; the walking/caching source that
// feeds files into it lives in the services layer.
package symbol

import "base:runtime"
import "core:strings"
import "src:ts"
import "src:util"

// convert_outline_forest converts outline symbols into unified symbol
// trees. Methods carry their resolved Owner in container_name; the shared
// pipeline re-nests them under the matching type symbol. Everything is
// cloned into `a`.
convert_outline_forest :: proc(
	symbols: []ts.Outline_Symbol,
	conv: ^Position_Converter,
	source: string,
	lang: string,
	a := context.allocator,
) -> []^Symbol {
	return convert_outline_children(symbols, conv, source, lang, a)[:]
}

convert_outline_children :: proc(
	children: []ts.Outline_Symbol,
	conv: ^Position_Converter,
	source: string,
	lang: string,
	a: runtime.Allocator,
	depth := 0,
) -> [dynamic]^Symbol {
	out := make([dynamic]^Symbol, 0, len(children), a)
	for i in 0..<len(children) {
		sym := &children[i]
		node := symbol_new(a)
		node.name = clone_string(sym.name, a)
		def_text := outline_def_text(sym, source)
		node.kind = outline_kind_to_lsp(sym.kind, def_text, lang)
		rng := new(Range, a)
		rng^ = conv_range(conv, sym.span)
		node.range = rng
		sel := new(Range, a)
		sel^ = conv_range(conv, sym.name_span)
		node.selection_range = sel
		if sym.owner != "" {
			node.container_name = clone_string(sym.owner, a)
		}
		if len(sym.children) > 0 && depth < MAX_TREE_DEPTH {
			node.children = convert_outline_children(sym.children, conv, source, lang, a, depth + 1)
		}
		append(&out, node)
	}
	return out
}

outline_def_text :: proc(sym: ^ts.Outline_Symbol, source: string) -> string {
	start := int(sym.span.start_byte)
	end := int(sym.span.end_byte)
	if start < 0 || end > len(source) || start > end {
		return ""
	}
	return source[start:end]
}

// outline_kind_to_lsp maps the outliner's normalized kind strings to LSP
// symbol kinds. The outliner passes unknown "@definition.X" suffixes
// through unchanged, so this switch must cover every suffix that appears
// in the shipped tags queries; anything else falls back to Function. Go
// type declarations are refined to Struct or Interface by inspecting the
// declaration text.
outline_kind_to_lsp :: proc(kind: string, def_text: string, lang: string) -> Symbol_Kind {
	switch kind {
	case "function", "macro":
		return .Function
	case "method":
		return .Method
	case "field":
		return .Field
	case "class":
		return .Class
	case "interface", "trait":
		return .Interface
	case "constructor":
		return .Constructor
	case "constant":
		return .Constant
	case "variable":
		return .Variable
	case "module":
		return .Module
	case "enum":
		return .Enum
	case "enum_member":
		return .Enum_Member
	case "object":
		return .Object
	case "type", "record", "struct", "union":
		if lang == "go" && is_go_interface_decl(def_text) {
			return .Interface
		}
		return .Struct
	case:
		return .Function
	}
}

// is_go_interface_decl reports whether a Go type declaration text defines
// an interface rather than a struct or a plain alias.
is_go_interface_decl :: proc(def_text: string) -> bool {
	i_idx := strings.index(def_text, "interface")
	s_idx := strings.index(def_text, "struct")
	return i_idx >= 0 && (s_idx < 0 || i_idx < s_idx)
}

// ---------------------------------------------------------------------------
// Position conversion
// ---------------------------------------------------------------------------

// Position_Converter translates file-relative byte offsets into LSP
// line/UTF-16-column positions using a precomputed line index.
Position_Converter :: struct {
	source:    string,
	offsets:   []int,
	allocator: runtime.Allocator,
}

position_converter_new :: proc(source: string, a := context.allocator) -> ^Position_Converter {
	conv := new(Position_Converter, a)
	conv^ = {
		source = source,
		offsets = util.line_start_offsets(source, a),
		allocator = a,
	}
	return conv
}

position_converter_destroy :: proc(conv: ^Position_Converter) {
	if conv == nil {
		return
	}
	if conv.offsets != nil {
		delete(conv.offsets)
	}
	a := conv.allocator
	free(conv, a)
}

conv_position :: proc(conv: ^Position_Converter, byte_offset: u32) -> Position {
	off := int(byte_offset)
	if off < 0 {
		off = 0
	}
	if off > len(conv.source) {
		off = len(conv.source)
	}
	lo, hi, line := 0, len(conv.offsets) - 1, 0
	for lo <= hi {
		mid := (lo + hi) / 2
		if conv.offsets[mid] <= off {
			line = mid
			lo = mid + 1
		} else {
			hi = mid - 1
		}
	}
	line_start := conv.offsets[line]
	line_end := len(conv.source)
	if line + 1 < len(conv.offsets) {
		line_end = conv.offsets[line + 1] - 1
	}
	if line_end < line_start {
		line_end = line_start
	}
	col := util.byte_offset_to_utf16_col(conv.source[line_start:line_end], off - line_start)
	return {line = u32(line), character = u32(col)}
}

conv_range :: proc(conv: ^Position_Converter, span: ts.Span) -> Range {
	return {
		start = conv_position(conv, span.start_byte),
		end = conv_position(conv, span.end_byte),
	}
}
