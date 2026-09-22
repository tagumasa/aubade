// The unified symbol model shared by the tree-sitter source and
// the LSP sources: LSP-shaped positions and ranges (UTF-16
// columns), a unified symbol tree with parent links and overload indices,
// name-path components, and the name-path matcher that symbol lookup
// consumes. Everything here is pure data and logic; file walking, caching,
// and concurrency live in the services layer.
//
// Memory: symbol trees are allocated in a caller-provided allocator
// (request arenas free_all them; other allocators use
// symbol_forest_destroy). Every string is cloned into that allocator.
package symbol

import "base:runtime"
import "core:strings"

NAME_PATH_SEP :: "/"

// Recursion guard for tree walks over user-shaped symbol trees.
MAX_RECURSION_DEPTH :: 100

// Depth cap for symbol-tree walkers and builders: source nesting is the
// depth driver, and generated or adversarial files nest arbitrarily deep.
// Beyond the cap the walk truncates (degrade, never crash) — the same
// philosophy the payload decoder applies.
MAX_TREE_DEPTH :: 500

Position :: struct {
	line:      u32,
	character: u32, // UTF-16 code units
}

Range :: struct {
	start: Position,
	end:   Position,
}

// Location anchors a symbol to a file; abs_path/rel_path are filled by the
// pipeline's EnsureSymbolLocations when the producer left them empty.
Location :: struct {
	uri:      string,
	range:    Range,
	abs_path: string,
	rel_path: string,
}

// Symbol_Kind carries the LSP SymbolKind numbering so both sources — and
// the wire format the LSP source speaks — agree on values.
Symbol_Kind :: enum u32 {
	Unknown       = 0,
	File          = 1,
	Module        = 2,
	Namespace     = 3,
	Package       = 4,
	Class         = 5,
	Method        = 6,
	Property      = 7,
	Field         = 8,
	Constructor   = 9,
	Enum          = 10,
	Interface     = 11,
	Function      = 12,
	Variable      = 13,
	Constant      = 14,
	String        = 15,
	Number        = 16,
	Boolean       = 17,
	Array         = 18,
	Object        = 19,
	Key           = 20,
	Null          = 21,
	Enum_Member   = 22,
	Struct        = 23,
	Event         = 24,
	Operator      = 25,
	Type_Parameter = 26,
}

kind_name :: proc(k: Symbol_Kind) -> string {
	#partial switch k {
	case .File:          return "File"
	case .Module:        return "Module"
	case .Namespace:     return "Namespace"
	case .Package:       return "Package"
	case .Class:         return "Class"
	case .Method:        return "Method"
	case .Property:      return "Property"
	case .Field:         return "Field"
	case .Constructor:   return "Constructor"
	case .Enum:          return "Enum"
	case .Interface:     return "Interface"
	case .Function:      return "Function"
	case .Variable:      return "Variable"
	case .Constant:      return "Constant"
	case .String:        return "String"
	case .Number:        return "Number"
	case .Boolean:       return "Boolean"
	case .Array:         return "Array"
	case .Object:        return "Object"
	case .Key:           return "Key"
	case .Null:          return "Null"
	case .Enum_Member:   return "EnumMember"
	case .Struct:        return "Struct"
	case .Event:         return "Event"
	case .Operator:      return "Operator"
	case .Type_Parameter: return "TypeParameter"
	case:                return "Unknown"
	}
}

// Symbol is one node of the unified symbol tree. Optional fields are
// nil-able pointers (range/selection_range/location) or a sentinel
// (overload_idx = -1 means "no index", has_body gates body).
Symbol :: struct {
	name:            string,
	kind:            Symbol_Kind,
	container_name:  string, // receiver/owner type for flat symbol forms
	detail:          string,
	range:           ^Range, // full extent; nil until a producer sets it
	selection_range: ^Range, // name identifier extent
	body:            string, // raw body text
	has_body:        bool,
	overload_idx:    int, // -1 = none; numbers same-named siblings
	location:        ^Location,
	children:        [dynamic]^Symbol,
	parent:          ^Symbol,
}

symbol_new :: proc(a: runtime.Allocator) -> ^Symbol {
	s := new(Symbol, a)
	s^ = {overload_idx = -1}
	return s
}

// count_symbols counts the forest, nested symbols included.
count_symbols :: proc(roots: []^Symbol) -> int {
	total := 0
	stack := make([dynamic][]^Symbol, 0, 8, context.temp_allocator)
	append(&stack, roots)
	for len(stack) > 0 {
		level := stack[len(stack) - 1]
		pop(&stack)
		total += len(level)
		for i in 0..<len(level) {
			if len(level[i].children) > 0 {
				append(&stack, level[i].children[:])
			}
		}
	}
	return total
}

// symbol_forest_destroy frees a forest built for a non-arena allocator
// (request arenas free_all instead). Children are owned by their parent's
// list; parent pointers are not separately freed.
symbol_forest_destroy :: proc(roots: []^Symbol, a := context.allocator) {
	for i in 0..<len(roots) {
		symbol_node_destroy(roots[i], a)
	}
	if roots != nil {
		delete(roots, a)
	}
}

// symbol_node_free releases a single node's own allocations. Strings are
// freed through `a` (plain strings carry no allocator — a bare delete would
// route through the destroying thread's context); the children array is a
// dynamic array and releases through its own stored allocator.
symbol_node_free :: proc(s: ^Symbol, a: runtime.Allocator) {
	delete(s.children)
	if s.name != "" {
		delete(s.name, a)
	}
	if s.container_name != "" {
		delete(s.container_name, a)
	}
	if s.detail != "" {
		delete(s.detail, a)
	}
	if s.body != "" {
		delete(s.body, a)
	}
	if s.range != nil {
		free(s.range, a)
	}
	// selection_range is always an owning pointer: producers either allocate
	// it or alias the node's own rng, which this guard skips.
	if s.selection_range != nil && s.selection_range != s.range {
		free(s.selection_range, a)
	}
	if s.location != nil {
		if s.location.uri != "" {
			delete(s.location.uri, a)
		}
		if s.location.abs_path != "" {
			delete(s.location.abs_path, a)
		}
		if s.location.rel_path != "" {
			delete(s.location.rel_path, a)
		}
		free(s.location, a)
	}
	free(s, a)
}

symbol_node_destroy :: proc(s: ^Symbol, a: runtime.Allocator) {
	if s == nil {
		return
	}
	// Iterative (work stack, like the ts outline walks): symbol trees
	// carry user-shaped nesting and unbounded recursion overflows.
	stack := make([dynamic]^Symbol, 0, 8, context.temp_allocator)
	defer delete(stack)
	append(&stack, s)
	for len(stack) > 0 {
		cur := stack[len(stack) - 1]
		pop(&stack)
		for c in cur.children {
			if c != nil {
				append(&stack, c)
			}
		}
		symbol_node_free(cur, a)
	}
}

// clone_string is the package's clone-into-allocator helper.
clone_string :: proc(s: string, a: runtime.Allocator) -> string {
	return strings.clone(s, a)
}

// ---------------------------------------------------------------------------
// Name-path components and matching
// ---------------------------------------------------------------------------

// Name_Path_Component is one segment of a symbol's name path, with an
// optional overload index for disambiguation (overload_idx = -1 = none).
Name_Path_Component :: struct {
	name:         string,
	overload_idx: int,
}

Name_Path_Matcher :: struct {
	expr:               string, // borrowed from the caller's pattern
	substring_matching: bool,
	is_absolute:        bool,
	components:         [dynamic]Pattern_Component,
	allocator:          runtime.Allocator,
}

Pattern_Component :: struct {
	name:         string,
	overload_idx: int, // -1 = none
}

// name_path_matcher_new builds a matcher from a name path expression:
//   - a simple name ("method") matches any symbol with that name
//   - a relative path ("class/method") matches any suffix of a name path
//   - an absolute path ("/class/method") requires an exact full match
//   - an overload index ("MyClass/my_method[1]") disambiguates overloads
//
// The empty pattern is an error. Component strings are cloned into `a`;
// name_path_matcher_destroy releases them.
name_path_matcher_new :: proc(pattern: string, substring_matching: bool, a := context.allocator) -> (m: ^Name_Path_Matcher, err: string) {
	if pattern == "" {
		return nil, "name_path must not be empty"
	}
	expr := strings.trim_left(pattern, NAME_PATH_SEP)
	expr = strings.trim_right(expr, NAME_PATH_SEP)
	is_absolute := strings.has_prefix(pattern, NAME_PATH_SEP)

	m = new(Name_Path_Matcher, a)
	m^ = {
		expr = pattern,
		substring_matching = substring_matching,
		is_absolute = is_absolute,
		components = make([dynamic]Pattern_Component, 0, 4, a),
		allocator = a,
	}

	// Split on the separator, tolerating the leading empty segment of an
	// absolute pattern.
	seg_start := 0
	for i := 0; i <= len(expr); i += 1 {
		if i < len(expr) && expr[i] != NAME_PATH_SEP[0] {
			continue
		}
		part := expr[seg_start:i]
		seg_start = i + 1
		if part == "" {
			if i == 0 && is_absolute {
				continue
			}
			name_path_matcher_destroy(m)
			return nil, strings.concatenate({"name_path contains empty segment: ", pattern}, context.temp_allocator)
		}
		append(&m.components, parse_pattern_component(part, a))
	}
	if len(m.components) == 0 {
		name_path_matcher_destroy(m)
		return nil, "name_path must not be empty after normalisation"
	}
	return m, ""
}

name_path_matcher_destroy :: proc(m: ^Name_Path_Matcher) {
	if m == nil {
		return
	}
	// Free through the matcher's own allocator: a bare delete(string)
	// would route through the destroying thread's context.allocator,
	// which is a different allocator whenever the matcher outlives the
	// thread it was built on (daemon handler threads).
	for i in 0..<len(m.components) {
		delete(m.components[i].name, m.allocator)
	}
	delete(m.components)
	a := m.allocator
	free(m, a)
}

parse_pattern_component :: proc(s: string, a: runtime.Allocator) -> Pattern_Component {
	if strings.has_suffix(s, "]") {
		if bracket := strings.last_index(s, "["); bracket >= 0 {
			index_part := s[bracket + 1 : len(s) - 1]
			if idx, ok := parse_index(index_part); ok && idx >= 0 {
				return {
					name = strings.clone(s[:bracket], a),
					overload_idx = idx,
				}
			}
		}
	}
	return {name = strings.clone(s, a), overload_idx = -1}
}

parse_index :: proc(s: string) -> (idx: int, ok: bool) {
	if len(s) == 0 {
		return 0, false
	}
	// Nine digits (999,999,999) is far beyond any real overload count; a
	// longer digit string could only be wraparound noise from the
	// accumulation below, and a wrapped positive value would alias a real
	// index and resolve the wrong symbol. Fail the parse instead: the
	// component falls back to its literal-name reading and the pattern
	// matches nothing — the honest answer for an absurd index.
	if len(s) > 9 {
		return 0, false
	}
	n := 0
	for i in 0..<len(s) {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n * 10 + int(c - '0')
	}
	return n, true
}

pattern_component_matches :: proc(pc: ^Pattern_Component, sym: Name_Path_Component, substring: bool) -> bool {
	if substring {
		if !strings.contains(sym.name, pc.name) {
			return false
		}
	} else if sym.name != pc.name {
		return false
	}
	if pc.overload_idx >= 0 {
		if sym.overload_idx < 0 || pc.overload_idx != sym.overload_idx {
			return false
		}
	}
	return true
}

// matcher_matches_reversed matches a symbol's name-path components
// (innermost first) against the pattern. Substring matching applies to the
// innermost pattern component only.
matcher_matches_reversed :: proc(m: ^Name_Path_Matcher, components: []Name_Path_Component) -> bool {
	comp_idx := len(m.components) - 1
	sym_idx := 0
	for comp_idx >= 0 && sym_idx < len(components) {
		use_substring := m.substring_matching && comp_idx == len(m.components) - 1
		if !pattern_component_matches(&m.components[comp_idx], components[sym_idx], use_substring) {
			return false
		}
		comp_idx -= 1
		sym_idx += 1
	}
	if comp_idx >= 0 {
		return false
	}
	if m.is_absolute {
		return sym_idx == len(components)
	}
	return true
}
