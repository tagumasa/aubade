// The template engine for prompt rendering: {{ var }} substitution,
// {% if %}/{% else %}/{% endif %} conditionals (truthiness of a string,
// bool, or list, and `'literal' in list` membership), and
// {% for x in list %}/{% endfor %} loops, with Jinja-style whitespace
// control ({%- strips the whitespace before the tag, -%} after it).
package prompt

import "core:strings"

// Nesting cap for template blocks: parse_nodes recurses per opening
// {% if %}/{% for %} tag, so the depth must be bounded — a runaway
// template is a clean render failure, not a stack exhaustion.
MAX_TEMPLATE_DEPTH :: 64

Template_Vars :: struct {
	strs:  map[string]string,
	lists: map[string][]string,
	bools: map[string]bool,
}

template_vars_init :: proc(v: ^Template_Vars, a := context.allocator) {
	v.strs = make(map[string]string, 16, a)
	v.lists = make(map[string][]string, 8, a)
	v.bools = make(map[string]bool, 8, a)
}

template_vars_destroy :: proc(v: ^Template_Vars) {
	delete(v.strs)
	delete(v.lists)
	delete(v.bools)
}

template_set_str :: proc(v: ^Template_Vars, key, val: string) {
	v.strs[key] = val
}

template_set_list :: proc(v: ^Template_Vars, key: string, val: []string) {
	v.lists[key] = val
}

template_set_bool :: proc(v: ^Template_Vars, key: string, val: bool) {
	v.bools[key] = val
}

template_render :: proc(template_src: string, vars: ^Template_Vars, a := context.allocator) -> (string, bool) {
	// Parse nodes on scratch: they die with the render (the cloned output
	// is the only thing that crosses back to `a`).
	nodes, _, _, ok := parse_nodes(template_src, 0, .None, 0, context.temp_allocator)
	if !ok {
		return "", false
	}

	out := make([dynamic]u8, 0, len(template_src), a)
	defer delete(out)
	render_nodes(nodes, vars, &out, nil, a)
	// Exactly one trailing newline — the render finalization: a template
	// ending inside a chomped tag block would otherwise render with zero
	// or many.
	body := transmute(string)(out[:])
	end := len(body)
	for end > 0 && body[end - 1] == '\n' {
		end -= 1
	}
	return strings.concatenate({body[:end], "\n"}, a), true
}

// --- parse ---------------------------------------------------------------------

Node_Kind :: enum {
	Text,
	Var,
	If,
	For,
}

Stop_Kind :: enum {
	None,
	Endif,
	Else,
	Endfor,
}

Block_Kind :: enum {
	None,
	If,
	For,
}

Template_Node :: struct {
	kind:  Node_Kind,
	text:  string, // .Text literal / .Var name
	lit:   string, // if: membership literal; for: loop variable
	name:  string, // if/for: variable or list name
	children: [dynamic]Template_Node,
	else_children: [dynamic]Template_Node,
}

parse_nodes :: proc(
	src: string,
	pos: int,
	open: Block_Kind,
	depth: int,
	a := context.allocator,
) -> (nodes: [dynamic]Template_Node, next: int, stop: Stop_Kind, ok: bool) {
	if depth > MAX_TEMPLATE_DEPTH {
		return nodes, pos, .None, false
	}
	nodes = make([dynamic]Template_Node, 0, 16, a)
	i := pos
	for i < len(src) {
		var_at := strings.index(src[i:], "{{")
		tag_at := strings.index(src[i:], "{%")
		if var_at < 0 && tag_at < 0 {
			append_text(&nodes, src[i:], a)
			i = len(src)
			break
		}
		if tag_at >= 0 && (var_at < 0 || tag_at < var_at) {
			start := i + tag_at
			append_text(&nodes, src[i:start], a)
			end := strings.index(src[start:], "%}")
			if end < 0 {
				return nodes, i, .None, false
			}
			raw_tag := src[start + 2:start + end]
			strip_before := strings.has_prefix(raw_tag, "-")
			if strip_before {
				raw_tag = raw_tag[1:]
			}
			strip_after := strings.has_suffix(raw_tag, "-")
			if strip_after {
				raw_tag = raw_tag[:len(raw_tag) - 1]
			}
			after := start + end + 2
			if strip_before {
				chomp_trailing(&nodes)
			}
			if strip_after {
				after = skip_ws(src, after)
			}

			tag := strings.trim_space(raw_tag)
			if tag == "endif" {
				if open != .If {
					return nodes, after, .Endif, false
				}
				return nodes, after, .Endif, true
			}
			if tag == "endfor" {
				if open != .For {
					return nodes, after, .Endfor, false
				}
				return nodes, after, .Endfor, true
			}
			if tag == "else" {
				if open != .If {
					return nodes, after, .Else, false
				}
				return nodes, after, .Else, true
			}
			if strings.has_prefix(tag, "if ") {
				lit, name, eok := parse_expr(tag[len("if "):], a)
				if !eok {
					return nodes, after, .None, false
				}
				children, after2, stop1, ok1 := parse_nodes(src, after, .If, depth + 1, a)
				if !ok1 {
					return nodes, after, .None, false
				}
				node: Template_Node
				node.kind = .If
				node.lit = lit
				node.name = name
				node.children = children
				node.else_children = make([dynamic]Template_Node, 0, 0, a)
				after = after2
				if stop1 == .Else {
					else_nodes, after3, _, ok2 := parse_nodes(src, after, .If, depth + 1, a)
					if !ok2 {
						return nodes, after, .None, false
					}
					node.else_children = else_nodes
					after = after3
				}
				append(&nodes, node)
				i = after
				continue
			}
			if strings.has_prefix(tag, "for ") {
				rest := strings.trim_space(tag[len("for "):])
				in_idx := strings.index(rest, " in ")
				if in_idx < 0 {
					return nodes, after, .None, false
				}
				children, after2, stop1, ok1 := parse_nodes(src, after, .For, depth + 1, a)
				if !ok1 || stop1 != .Endfor {
					return nodes, after, .None, false
				}
				node: Template_Node
				node.kind = .For
				node.lit = strings.clone(strings.trim_space(rest[:in_idx]), a)
				node.name = strings.clone(strings.trim_space(rest[in_idx + 4:]), a)
				node.children = children
				node.else_children = make([dynamic]Template_Node, 0, 0, a)
				append(&nodes, node)
				i = after2
				continue
			}
			return nodes, after, .None, false // unknown tag
		}
		// A {{ var }} substitution.
		start := i + var_at
		append_text(&nodes, src[i:start], a)
		end := strings.index(src[start:], "}}")
		if end < 0 {
			return nodes, i, .None, false
		}
		node: Template_Node
		node.kind = .Var
		node.text = strings.clone(strings.trim_space(src[start + 2:start + end]), a)
		append(&nodes, node)
		i = start + end + 2
	}
	if open != .None {
		// Reached the end with the block still open.
		return nodes, i, .None, false
	}
	return nodes, i, .None, true
}

append_text :: proc(list: ^[dynamic]Template_Node, text: string, a := context.allocator) {
	if text == "" {
		return
	}
	if len(list) > 0 && list[len(list) - 1].kind == .Text {
		last := &list[len(list) - 1]
		last.text = strings.concatenate({last.text, text}, a)
		return
	}
	node: Template_Node
	node.kind = .Text
	node.text = strings.clone(text, a)
	node.children = make([dynamic]Template_Node, 0, 0, a)
	node.else_children = make([dynamic]Template_Node, 0, 0, a)
	append(list, node)
}

chomp_trailing :: proc(list: ^[dynamic]Template_Node) {
	if len(list) == 0 {
		return
	}
	last := &list[len(list) - 1]
	if last.kind != .Text {
		return
	}
	trimmed := strings.trim_right_space(last.text)
	last.text = trimmed
}

skip_ws :: proc(src: string, from: int) -> int {
	i := from
	for i < len(src) {
		c := src[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			i += 1
			continue
		}
		break
	}
	return i
}

// parse_expr splits an if expression: either `'lit' in name` (membership)
// or a bare variable name (truthiness). lit "" = truthiness form.
parse_expr :: proc(expr: string, a := context.allocator) -> (lit: string, name: string, ok: bool) {
	trimmed := strings.trim_space(expr)
	in_idx := strings.index(trimmed, " in ")
	if in_idx < 0 {
		if trimmed == "" {
			return "", "", false
		}
		return "", strings.clone(trimmed, a), true
	}
	left := strings.trim_space(trimmed[:in_idx])
	right := strings.trim_space(trimmed[in_idx + 4:])
	if len(left) < 2 || left[0] != '\'' || left[len(left) - 1] != '\'' {
		return "", "", false
	}
	return strings.clone(left[1:len(left) - 1], a), strings.clone(right, a), true
}

// --- render --------------------------------------------------------------------

// render_nodes renders the node list into `out`. `overlay` (nil = none)
// carries loop-variable bindings that take precedence over the shared
// vars — one renderer serves the top level and loop bodies alike. Each
// .For binds its OWN loop variable, saving and restoring whatever the
// key held, so nested loops see both their item and the outer one.
render_nodes :: proc(
	nodes: [dynamic]Template_Node,
	vars: ^Template_Vars,
	out: ^[dynamic]u8,
	overlay: ^map[string]string,
	a := context.allocator,
) {
	for i := 0; i < len(nodes); i += 1 {
		n := &nodes[i]
		switch n.kind {
		case .Text:
			append(out, n.text)
		case .Var:
			if overlay != nil {
				if v, ok := overlay^[n.text]; ok {
					append(out, v)
					continue
				}
			}
			val, found := lookup_str(vars, n.text)
			if !found {
				// Unknown variables render empty — a missing key never
				// errors a prompt.
				continue
			}
			append(out, val)
		case .If:
			ov: map[string]string
			if overlay != nil {
				ov = overlay^
			}
			if eval_truth_overlay(vars, ov, n.lit, n.name) {
				render_nodes(n.children, vars, out, overlay, a)
			} else {
				render_nodes(n.else_children, vars, out, overlay, a)
			}
		case .For:
			list, present := vars.lists[n.name]
			if !present {
				continue
			}
			// Top-level loops create the overlay; nested loops reuse it.
			own_overlay: map[string]string
			if overlay != nil {
				own_overlay = overlay^
			} else {
				own_overlay = make(map[string]string, 1, context.temp_allocator)
			}
			for item in list {
				prev, had_prev := own_overlay[n.lit]
				own_overlay[n.lit] = item
				render_nodes(n.children, vars, out, &own_overlay, a)
				if had_prev {
					own_overlay[n.lit] = prev
				} else {
					delete_key(&own_overlay, n.lit)
				}
			}
			if overlay == nil {
				delete(own_overlay)
			}
		}
	}
}

lookup_str :: proc(vars: ^Template_Vars, name: string) -> (string, bool) {
	if v, ok := vars.strs[name]; ok {
		return v, true
	}
	if b, ok := vars.bools[name]; ok {
		if b {
			return "true", true
		}
		return "false", true
	}
	return "", false
}

eval_truth_overlay :: proc(vars: ^Template_Vars, overlay: map[string]string, lit, name: string) -> bool {
	if lit != "" {
		if list, ok := vars.lists[name]; ok {
			for item in list {
				if item == lit {
					return true
				}
			}
			return false
		}
		if overlay != nil {
			if v, ok := overlay[name]; ok {
				return v == lit
			}
		}
		if b, ok := vars.bools[name]; ok {
			return b
		}
		return false
	}
	if overlay != nil {
		if v, ok := overlay[name]; ok {
			return v != ""
		}
	}
	if s, ok := vars.strs[name]; ok {
		return s != ""
	}
	if b, ok := vars.bools[name]; ok {
		return b
	}
	if l, ok := vars.lists[name]; ok {
		return len(l) > 0
	}
	return false
}

