// Forest search by name path: resolves a name-path pattern against an
// in-memory symbol forest (one file's fresh outline), the editing-side
// counterpart of the index-backed find. Matching reuses the shared
// Name_Path_Matcher so pattern semantics stay identical.
package symbol

import "core:strings"
import "base:runtime"

// symbol_full_name_path renders the outermost-first name path
// ("Outer/inner") of `s`, walking parent pointers. Allocates in `a`.
symbol_full_name_path :: proc(s: ^Symbol, a: runtime.Allocator) -> string {
	parts := make([dynamic]string, 0, 8, a)
	cur := s
	for cur != nil {
		if cur.name != "" {
			append(&parts, cur.name)
		}
		cur = cur.parent
	}
	if len(parts) == 0 {
		return ""
	}
	// The walk collected innermost-first; the wire form is outermost-first.
	for i := 0; i < len(parts)/2; i += 1 {
		tmp := parts[i]
		parts[i] = parts[len(parts)-1-i]
		parts[len(parts)-1-i] = tmp
	}
	out, _ := strings.join(parts[:], "/", a)
	delete(parts)
	return out
}

// symbol_find_unique resolves `pattern` against the forest. Zero matches
// and ambiguous patterns are errors; ambiguity first tries the exact full
// name path (so "Foo/method" beats a suffix match), then reports the
// candidates' full paths. The error strings and all internal scratch ride
// the temp allocator; the returned symbol borrows the forest.
// Find_Err closes the unique-match failure vocabulary: a pattern that
// cannot parse, zero matches, or several equally-valid matches.
Find_Err :: enum {
	None,
	Bad_Pattern,
	No_Match,
	Ambiguous,
}

symbol_find_unique :: proc(roots: []^Symbol, pattern: string) -> (match: ^Symbol, err: Find_Err, msg: string) {
	m, merr := name_path_matcher_new(pattern, false, context.temp_allocator)
	if merr != "" {
		return nil, .Bad_Pattern, merr
	}
	defer name_path_matcher_destroy(m)

	matches := symbol_forest_collect_matches(roots, m, context.temp_allocator)

	if len(matches) == 0 {
		return nil, .No_Match, strings.concatenate({"no symbol matching '", pattern, "' found"}, context.temp_allocator)
	}
	if len(matches) == 1 {
		return matches[0], .None, ""
	}
	for i in 0..<len(matches) {
		full := symbol_full_name_path(matches[i], context.temp_allocator)
		if full == pattern || strings.concatenate({"/", full}, context.temp_allocator) == pattern {
			return matches[i], .None, ""
		}
	}
	detail := strings.builder_make(context.temp_allocator)
	for i in 0..<len(matches) {
		if i > 0 {
			strings.write_string(&detail, ", ")
		}
		strings.write_string(&detail, symbol_full_name_path(matches[i], context.temp_allocator))
	}
	return nil, .Ambiguous, strings.concatenate({
		"multiple symbols match '", pattern, "': ", strings.to_string(detail),
	}, context.temp_allocator)
}

// symbol_forest_collect_matches walks the forest depth-first and returns
// every symbol whose (innermost-first) name-path components match `m`.
// The list borrows `a` (the temp allocator — it dies by free_all, never
// by individual deletes).
symbol_forest_collect_matches :: proc(roots: []^Symbol, m: ^Name_Path_Matcher, a := context.temp_allocator) -> []^Symbol {
	out := make([dynamic]^Symbol, 0, 4, a)
	stack := make([dynamic]^Symbol, 0, 8, a)
	// Depth-first with the roots pushed in reverse so matches come out in
	// document order.
	for i := len(roots) - 1; i >= 0; i -= 1 {
		append(&stack, roots[i])
	}
	for len(stack) > 0 {
		node := stack[len(stack)-1]
		pop(&stack)
		comps := symbol_name_path_components(node, a)
		if matcher_matches_reversed(m, comps) {
			append(&out, node)
		}
		for i := len(node.children) - 1; i >= 0; i -= 1 {
			append(&stack, node.children[i])
		}
	}
	return out[:]
}

// symbol_name_path_components builds the innermost-first component chain
// (symbol, then each ancestor) used by matcher_matches_reversed. The
// component names borrow the symbol tree.
symbol_name_path_components :: proc(s: ^Symbol, a := context.temp_allocator) -> []Name_Path_Component {
	n := 0
	cur := s
	for cur != nil {
		n += 1
		cur = cur.parent
	}
	comps := make([]Name_Path_Component, n, a)
	i := 0
	cur = s
	for cur != nil {
		comps[i] = {name = cur.name, overload_idx = cur.overload_idx}
		i += 1
		cur = cur.parent
	}
	return comps
}
