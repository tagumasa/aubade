// documentSymbol response conversion: hierarchical DocumentSymbol[] and
// flat SymbolInformation[] both become unified symbol forests. The format
// is probed per element (a "location" key means the flat form, a "range"
// key the hierarchical one — both variants parse silently into the other's
// shape, so the probe must be explicit). The caller runs the produced
// forest through symbol.finalize_symbol_tree, exactly as the tree-sitter
// source does, so re-nesting, parents, overload indices, and locations
// behave identically regardless of producer.
package lsp

import "base:runtime"
import "core:encoding/json"
import "core:strings"

import "src:jsonutil"
import "src:symbol"
import "src:util"

// symbols_from_document_symbol converts a documentSymbol reply into a
// unified forest allocated in `a`. Null, non-array, and unrecognised
// element shapes yield nil (an out-of-shape reply is a "no symbols"
// answer, not a failure — servers legitimately return null). `contents`
// ("" when unavailable) lets the flat SymbolInformation form recover its
// selection range from the source text.
symbols_from_document_symbol :: proc(value: json.Value, contents: string, a := context.allocator) -> []^symbol.Symbol {
	items, ok := jsonutil.as_array(value)
	if !ok {
		return nil
	}
	out := make([dynamic]^symbol.Symbol, 0, len(items), a)
	for item in items {
		node := document_symbol_node(item, contents, a)
		if node != nil {
			append(&out, node)
		}
	}
	if len(out) == 0 {
		delete(out)
		return nil
	}
	return out[:]
}

// document_symbol_node converts one array element. Hierarchical elements
// carry name/kind/range/selectionRange/children; flat ones carry
// name/kind/location/containerName. The flat form carries no selection
// range — with contents available it is recovered from the source text
// (identifier_range_on_line); without them the pipeline anchors the
// selection to the location range.
//
// The child walk is iterative (explicit stack) to avoid a 500-deep
// call stack that overflows the 1 MB Windows default.
document_symbol_node :: proc(v: json.Value, contents: string, a: runtime.Allocator) -> ^symbol.Symbol {
	root := make_symbol_node(v, contents, a)
	if root == nil {
		return nil
	}

	// Iteratively process children when the root is hierarchical.
	obj, ok := jsonutil.as_object(v)
	if !ok || !hierarchical_element(obj) {
		return root
	}
	children_v, cok := obj["children"]
	if !cok {
		return root
	}
	children, aok := jsonutil.as_array(children_v)
	if !aok || len(children) == 0 {
		return root
	}
	root.children = make([dynamic]^symbol.Symbol, 0, len(children), a)

	// Work stack: parent node + its remaining children to process.
	Scope :: struct {
		parent:  ^symbol.Symbol,
		pending: []json.Value,
		depth:   int,
	}
	stack: [dynamic]Scope
	defer delete(stack)
	append(&stack, Scope{root, children, 1})

	for len(stack) > 0 {
		idx := len(stack) - 1
		top := &stack[idx]
		for len(top.pending) > 0 {
			child_v := top.pending[0]
			top.pending = top.pending[1:]

			cn := make_symbol_node(child_v, contents, a)
			if cn == nil {
				continue
			}
			append(&top.parent.children, cn)

			// Push the child's own scope if it has children.
			if child_obj, ch_ok := jsonutil.as_object(child_v); ch_ok && hierarchical_element(child_obj) {
				if cv, ccok := child_obj["children"]; ccok {
					if ca, caok := jsonutil.as_array(cv); caok && len(ca) > 0 && top.depth < symbol.MAX_TREE_DEPTH {
						cn.children = make([dynamic]^symbol.Symbol, 0, len(ca), a)
						append(&stack, Scope{cn, ca, top.depth + 1})
						break // inner loop resumes at the new top
					}
				}
			}
		}
		// Pop only if the stack didn't grow (no break → scope exhausted).
		if idx == len(stack) - 1 {
			resize(&stack, len(stack) - 1)
		}
	}

	return root
}

// hierarchical_element is the explicit form probe for one reply element:
// "range" without "location" means the hierarchical DocumentSymbol form,
// anything else that converts is the flat SymbolInformation form.
// "children" is a DocumentSymbol member only — SymbolInformation has no
// such field — so a children key on a flat element is out-of-shape and
// ignored like any other unknown field.
hierarchical_element :: proc(obj: map[string]json.Value) -> bool {
	_, has_location := obj["location"]
	_, has_range := obj["range"]
	return has_range && !has_location
}

// make_symbol_node creates one symbol from a JSON element without
// processing children (that is the caller's responsibility).
make_symbol_node :: proc(v: json.Value, contents: string, a: runtime.Allocator) -> ^symbol.Symbol {
	obj, ok := jsonutil.as_object(v)
	if !ok {
		return nil
	}
	name_v, has_name := obj["name"]
	if !has_name {
		return nil
	}
	hierarchical := hierarchical_element(obj)
	if !hierarchical {
		if _, has_location := obj["location"]; !has_location {
			return nil
		}
	}

	node := symbol.symbol_new(a)
	node.name = symbol.clone_string(jsonutil.value_str(name_v), a)
	if kind_v, kok := obj["kind"]; kok {
		node.kind = kind_from_json(kind_v)
	}
	if detail_v, dok := obj["detail"]; dok {
		node.detail = symbol.clone_string(jsonutil.value_str(detail_v), a)
	}

	if hierarchical {
		if r, rok := range_from_json(obj["range"]); rok {
			rng := new(symbol.Range, a)
			rng^ = r
			node.range = rng
		}
		if sel_v, sok := obj["selectionRange"]; sok {
			if r, rok := range_from_json(sel_v); rok {
				sel := new(symbol.Range, a)
				sel^ = r
				node.selection_range = sel
			}
		}
	} else {
		loc := new(symbol.Location, a)
		loc_v := obj["location"]
		if uri_v, uok := jsonutil.obj_get(loc_v, "uri"); uok {
			loc.uri = symbol.clone_string(jsonutil.value_str(uri_v), a)
		}
		if rng_v, gok := jsonutil.obj_get(loc_v, "range"); gok {
			if r, rok := range_from_json(rng_v); rok {
				loc.range = r
				// The flat form's location range is the symbol's full range —
				// what rng means for the hierarchical form. Mirror it so rng
				// consumers (the editor's symbol-edit transactions) work on
				// flat replies; ensure_symbol_locations only fills location
				// from rng when location is nil, so the reported location
				// stays authoritative.
				rng := new(symbol.Range, a)
				rng^ = r
				node.range = rng
			}
		}
		node.location = loc
		if container_v, kok := obj["containerName"]; kok {
			node.container_name = symbol.clone_string(jsonutil.value_str(container_v), a)
		}
		// Recover the selection range the flat form never carries: the
		// first occurrence of the name on the symbol's start line, UTF-16
		// columns (the position convention end to end), line-0 BOM
		// stripped. No contents — leave nil.
		if contents != "" && node.name != "" {
			sel := new(symbol.Range, a)
			sel^ = identifier_range_on_line(contents, node.name, loc.range.start.line)
			node.selection_range = sel
		}
	}
	return node
}

// identifier_range_on_line returns a range covering the first occurrence
// of `name` on the given 0-based line of `contents` (UTF-16 code-unit
// columns, the line-0 BOM stripped, falling back to the line start) — flat
// SymbolInformation entries only carry the whole-body location range.
identifier_range_on_line :: proc(contents, name: string, line: u32) -> symbol.Range {
	col := 0
	if line_text, found := line_slice(contents, int(line)); found {
		if line == 0 && strings.has_prefix(line_text, "\uFEFF") {
			line_text = line_text[len("\uFEFF"):]
		}
		if idx := strings.index(line_text, name); idx >= 0 {
			col = util.byte_offset_to_utf16_col(line_text, idx)
		}
	}
	return {
		start = {line = line, character = u32(col)},
		end   = {line = line, character = u32(col + util.byte_offset_to_utf16_col(name, len(name)))},
	}
}

// line_slice returns the newline-delimited line `n` of `contents`.
line_slice :: proc(contents: string, n: int) -> (string, bool) {
	if n < 0 {
		return "", false
	}
	start := 0
	line := 0
	for i := 0; i <= len(contents); i += 1 {
		if i == len(contents) || contents[i] == '\n' {
			if line == n {
				text := contents[start:i]
				if len(text) > 0 && text[len(text) - 1] == '\r' {
					text = text[:len(text) - 1]
				}
				return text, true
			}
			line += 1
			start = i + 1
		}
	}
	return "", false
}

// kind_from_json maps the wire SymbolKind number onto the closed enum;
// out-of-range values (servers invent future kinds) become Unknown.
kind_from_json :: proc(v: json.Value) -> symbol.Symbol_Kind {
	#partial switch x in v {
	case json.Integer:
		if x >= 1 && x <= 26 {
			return cast(symbol.Symbol_Kind)x
		}
	case:
	}
	return .Unknown
}

// position_from_json reads an LSP position (line/character, non-negative
// clamped into u32).
position_from_json :: proc(v: json.Value) -> symbol.Position {
	pos := symbol.Position{}
	if line_v, ok := jsonutil.obj_get(v, "line"); ok {
		#partial switch x in line_v {
		case json.Integer:
			pos.line = json_u32(x)
		case:
		}
	}
	if char_v, ok := jsonutil.obj_get(v, "character"); ok {
		#partial switch x in char_v {
		case json.Integer:
			pos.character = json_u32(x)
		case:
		}
	}
	return pos
}

range_from_json :: proc(v: json.Value) -> (r: symbol.Range, ok: bool) {
	start_v, sok := jsonutil.obj_get(v, "start")
	end_v, eok := jsonutil.obj_get(v, "end")
	if !sok || !eok {
		return r, false
	}
	return {
		start = position_from_json(start_v),
		end   = position_from_json(end_v),
	}, true
}

// json_u32 clamps a JSON integer into u32 position coordinates.
json_u32 :: proc(v: json.Integer) -> u32 {
	if v < 0 {
		return 0
	}
	max_u32 :: cast(json.Integer)(0xFFFFFFFF)
	if v > max_u32 {
		return 0xFFFFFFFF
	}
	return cast(u32)v
}
