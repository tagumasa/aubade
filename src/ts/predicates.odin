// Text-predicate evaluation for tree-sitter queries. The C API hands
// predicates to the caller as per-pattern token lists; this file compiles
// those token lists into predicates and filters matches against them:
//
//	(#eq? @a "literal")  (#eq? @a @b)     (#not-eq? ... same shapes)
//	(#match? @a "regex")                  (#not-match? @a "regex")
//	(#any-eq? ...) (#any-not-eq? ...)     (#any-match? ...) (#any-not-match? ...)
//	(#any-of? @a "v1" "v2")               (#not-any-of? @a "v1" "v2")
//	(#lua-match? @a "regex")              — nvim's regex predicate, PCRE2
//	(#has-parent? @a "t1" "t2")           (#not-has-parent? ... same shape)
//	(#has-ancestor? @a "t1" "t2")         (#not-has-ancestor? ... same shape)
//	(#is? ...) (#is-not? ...)             — metadata, never filters
//	(#set! ...) (#offset! ...)            — metadata, never filters
//
// Semantics notes: #match? searches anywhere in the capture text
// (unanchored). #lua-match? is nvim's Lua string.match; the shipped
// queries' patterns are plain anchored regexes, so it evaluates through
// the same PCRE2 engine — Lua pattern classes like %d are not supported
// and fail the regex compile loudly rather than silently mismatching.
// The structural pair follows nvim's split: #has-parent? checks the
// capture's immediate parent only, #has-ancestor? walks the whole
// ancestor chain; both match the node type name against the literal
// list. A predicate whose capture is absent from the match fails
// that match — an optional-branch "allow missing" refinement is not
// observable through the C API and is not implemented. Unknown predicate
// names fail compilation (compile-time rejection). Error strings follow
// the package convention: temp-allocator scratch the caller consumes
// immediately.
package ts

import "core:strings"
import "src:regex"

Predicate_Kind :: enum {
	Eq,
	Not_Eq,
	Match,
	Not_Match,
	Any_Eq,
	Any_Not_Eq,
	Any_Match,
	Any_Not_Match,
	Any_Of,
	Not_Any_Of,
	Has_Parent,
	Not_Has_Parent,
	Has_Ancestor,
	Not_Has_Ancestor,
	Inert, // #is? / #is-not? / #set! / #offset!: metadata only
}

Predicate :: struct {
	kind:          Predicate_Kind,
	left_capture:  string,     // borrowed from the Query — never outlive it
	right_capture: string,     // "" when the right side is a literal
	literal:       string,     // borrowed literal text or regex source
	values:        []string,   // borrowed literals (#any-of? family)
	regex:         ^regex.Regex, // nil unless a regex-family kind
}

// Query_Predicates is the compiled predicate table for one Query. All
// strings borrow the Query; the regexes own PCRE2 state released by
// predicates_destroy. Destroy before query_delete frees the Query.
Query_Predicates :: struct {
	patterns:      [dynamic][dynamic]Predicate,
	capture_names: []string, // capture id -> borrowed name
}

Pred_Token :: struct {
	is_capture: bool,
	text:       string,
}

compile_predicates :: proc(q: Query, a := context.allocator) -> (ps: Query_Predicates, err: string) {
	cap_count := query_capture_count(q)
	names := make([]string, cap_count, a)
	for i in u32(0)..<cap_count {
		names[i] = query_capture_name_borrowed(q, i)
	}
	ps = {
		patterns      = make([dynamic][dynamic]Predicate, 0, 8, a),
		capture_names = names,
	}

	pattern_count := query_pattern_count(q)
	for pi in u32(0)..<pattern_count {
		row := make([dynamic]Predicate, 0, 4, a)
		failed := false

		step_len: u32
		steps_ptr := query_predicates_for_pattern(q, pi, &step_len)
		steps: []Query_Predicate_Step
		if step_len > 0 {
			steps = steps_ptr[:step_len]
		}
		i := 0
		for i < int(step_len) {
			// A predicate group starts with its name (a string token).
			if steps[i].kind != .String {
				err = "query: malformed predicate list"
				failed = true
				break
			}
			name := query_string_borrowed(q, steps[i].value_id)
			i += 1

			tokens := make([dynamic]Pred_Token, 0, 4, a)
			for i < int(step_len) && steps[i].kind != .Done {
				if steps[i].kind == .Capture {
					id := steps[i].value_id
					if id >= cap_count {
						delete(tokens)
						err = "query: malformed predicate list"
						failed = true
						break
					}
					append(&tokens, Pred_Token{is_capture = true, text = names[id]})
				} else {
					append(&tokens, Pred_Token{text = query_string_borrowed(q, steps[i].value_id)})
				}
				i += 1
			}
			if failed {
				break
			}
			i += 1 // consume the Done terminator

			p, build_err := build_predicate(name, tokens[:], a)
			delete(tokens)
			if build_err != "" {
				err = build_err
				failed = true
				break
			}
			append(&row, p)
		}

		// The row joins ps before any failure exit so a single
		// predicates_destroy covers every allocation made so far.
		append(&ps.patterns, row)
		if failed {
			predicates_destroy(&ps, a)
			return {}, err
		}
	}
	return ps, ""
}

predicates_destroy :: proc(ps: ^Query_Predicates, a := context.allocator) {
	for i in 0..<len(ps.patterns) {
		row := &ps.patterns[i]
		for j in 0..<len(row^) {
			if row[j].regex != nil {
				regex.regex_destroy(row[j].regex)
				free(row[j].regex, a)
				row[j].regex = nil
			}
			// The value strings borrow the query; only the backing dies.
			if row[j].values != nil {
				delete(row[j].values, a)
				row[j].values = nil
			}
		}
		// [dynamic] rows carry their own allocator — delete needs no argument.
		delete(row^)
	}
	if ps.patterns != nil {
		delete(ps.patterns)
	}
	if ps.capture_names != nil {
		delete(ps.capture_names, a)
	}
	ps^ = {}
}

// predicates_match reports whether every predicate of the match's pattern
// holds. Patterns without predicates match unconditionally.
predicates_match :: proc(ps: ^Query_Predicates, match: ^Query_Match, source: string) -> bool {
	pi := int(match.pattern_index)
	if pi < 0 || pi >= len(ps.patterns) {
		return true
	}
	for i in 0..<len(ps.patterns[pi]) {
		if !predicate_holds(&ps.patterns[pi][i], ps, match, source) {
			return false
		}
	}
	return true
}

predicate_holds :: proc(p: ^Predicate, ps: ^Query_Predicates, match: ^Query_Match, source: string) -> bool {
	switch p.kind {
	case .Eq, .Not_Eq:
		left, lok := first_capture_text(p.left_capture, ps, match, source)
		if !lok {
			return false
		}
		right, rok := p.literal, true
		if p.right_capture != "" {
			right, rok = first_capture_text(p.right_capture, ps, match, source)
		}
		if !rok {
			return false
		}
		return (left == right) == (p.kind == .Eq)
	case .Match, .Not_Match:
		left, lok := first_capture_text(p.left_capture, ps, match, source)
		if !lok {
			return false
		}
		// regex_match_local: outliner regexes are shared across request
		// threads, and a Regex's own match_data serves one thread at a
		// time — predicates match through a call-local buffer.
		matched := p.regex != nil && regex.regex_match_local(p.regex, left)
		return matched == (p.kind == .Match)
	case .Any_Eq, .Any_Not_Eq:
		right, rok := p.literal, true
		if p.right_capture != "" {
			right, rok = first_capture_text(p.right_capture, ps, match, source)
		}
		want_equal := p.kind == .Any_Eq
		for i in u32(0)..<u32(match.capture_count) {
			cap := match.captures[i]
			if int(cap.index) >= len(ps.capture_names) || ps.capture_names[cap.index] != p.left_capture {
				continue
			}
			if rok && ((node_text(cap.node, source) == right) == want_equal) {
				return true
			}
		}
		return false
	case .Any_Match, .Any_Not_Match:
		want_matched := p.kind == .Any_Match
		for i in u32(0)..<u32(match.capture_count) {
			cap := match.captures[i]
			if int(cap.index) >= len(ps.capture_names) || ps.capture_names[cap.index] != p.left_capture {
				continue
			}
			if p.regex != nil && (regex.regex_match_local(p.regex, node_text(cap.node, source)) == want_matched) {
				return true
			}
		}
		return false
	case .Any_Of, .Not_Any_Of:
		left, lok := first_capture_text(p.left_capture, ps, match, source)
		if !lok {
			return false
		}
		return string_in_list(left, p.values) == (p.kind == .Any_Of)
	case .Has_Parent, .Not_Has_Parent:
		node, ok := first_capture_node(p.left_capture, ps, match)
		if !ok || node_is_null(node) {
			return false
		}
		// nvim's split: has-parent? looks at the immediate parent alone —
		// a grandparent of a listed type does not match.
		has := false
		parent := node_parent(node)
		if !node_is_null(parent) {
			has = node_type_in(parent, p.values)
		}
		return has == (p.kind == .Has_Parent)
	case .Has_Ancestor, .Not_Has_Ancestor:
		node, ok := first_capture_node(p.left_capture, ps, match)
		if !ok || node_is_null(node) {
			return false
		}
		has := false
		ancestor := node_parent(node)
		for !node_is_null(ancestor) {
			if node_type_in(ancestor, p.values) {
				has = true
				break
			}
			ancestor = node_parent(ancestor)
		}
		return has == (p.kind == .Has_Ancestor)
	case .Inert:
		return true
	}
	return false
}

build_predicate :: proc(name: string, tokens: []Pred_Token, a := context.allocator) -> (p: Predicate, err: string) {
	switch name {
	case "eq?":
		return build_equality(tokens, .Eq, name)
	case "not-eq?":
		return build_equality(tokens, .Not_Eq, name)
	case "any-eq?":
		return build_equality(tokens, .Any_Eq, name)
	case "any-not-eq?":
		return build_equality(tokens, .Any_Not_Eq, name)
	case "match?":
		return build_regex_predicate(tokens, .Match, name, a)
	case "not-match?":
		return build_regex_predicate(tokens, .Not_Match, name, a)
	case "any-match?":
		return build_regex_predicate(tokens, .Any_Match, name, a)
	case "any-not-match?":
		return build_regex_predicate(tokens, .Any_Not_Match, name, a)
	case "any-of?":
		return build_list_predicate(tokens, .Any_Of, name, a)
	case "not-any-of?":
		return build_list_predicate(tokens, .Not_Any_Of, name, a)
	case "lua-match?":
		// nvim's lua-match? is Lua string.match; the corpus's patterns are
		// plain anchored regexes, so the PCRE2 #match? engine reproduces
		// them. A Lua pattern class (%d, %s, ...) is not a PCRE2 pattern:
		// the regex compile fails and names the query, rather than
		// silently mismatching every capture.
		return build_regex_predicate(tokens, .Match, name, a)
	case "has-parent?":
		return build_list_predicate(tokens, .Has_Parent, name, a)
	case "not-has-parent?":
		return build_list_predicate(tokens, .Not_Has_Parent, name, a)
	case "has-ancestor?":
		return build_list_predicate(tokens, .Has_Ancestor, name, a)
	case "not-has-ancestor?":
		return build_list_predicate(tokens, .Not_Has_Ancestor, name, a)
	case "is?", "is-not?", "set!", "offset!":
		// Metadata directives for host tooling; they never filter matches.
		return {kind = .Inert}, ""
	case "strip!", "downcase!", "upcase!", "gsub!", "collapse-space!":
		// Text-transform directives. Across the registry's shipped tags
		// queries they only ever decorate @doc captures (go, javascript,
		// ocaml, ruby); the outline consumes @name and definition
		// captures only, so the transforms are accepted as no-ops rather
		// than rejecting the whole query.
		return {kind = .Inert}, ""
	case "select-adjacent!", "set-adjacent!":
		// Pair a preceding comment capture with a definition for doc
		// extraction (javascript and ruby spell it select-adjacent!, go's
		// shipped tags query set-adjacent!). The definition capture comes
		// from the pattern itself, so ignoring the pairing does not move
		// any outline symbol.
		return {kind = .Inert}, ""
	case:
		return {}, strings.concatenate({"query: unsupported predicate #", name}, context.temp_allocator)
	}
}

build_equality :: proc(tokens: []Pred_Token, kind: Predicate_Kind, name: string) -> (p: Predicate, err: string) {
	bad := strings.concatenate({"query: ", name, " requires a capture and a literal or capture"}, context.temp_allocator)
	if len(tokens) != 2 || !tokens[0].is_capture {
		return {}, bad
	}
	p = {kind = kind, left_capture = tokens[0].text}
	if tokens[1].is_capture {
		p.right_capture = tokens[1].text
	} else {
		p.literal = tokens[1].text
	}
	return p, ""
}

build_regex_predicate :: proc(tokens: []Pred_Token, kind: Predicate_Kind, name: string, a := context.allocator) -> (p: Predicate, err: string) {
	bad := strings.concatenate({"query: ", name, " requires a capture and a regex literal"}, context.temp_allocator)
	if len(tokens) != 2 || !tokens[0].is_capture || tokens[1].is_capture {
		return {}, bad
	}
	// The predicate owns the compiled regex for its lifetime: the
	// compilation must ride `a`, the same allocator as the boxed Regex —
	// outliners are cached for the daemon's life while the building
	// thread's scratch resets after the request.
	compiled, rerr := regex.compile_regex(tokens[1].text, a)
	if rerr != nil {
		return {}, strings.concatenate({"query: invalid regex in ", name}, context.temp_allocator)
	}
	re := new(regex.Regex, a)
	re^ = compiled
	return {kind = kind, left_capture = tokens[0].text, literal = tokens[1].text, regex = re}, ""
}

build_list_predicate :: proc(tokens: []Pred_Token, kind: Predicate_Kind, name: string, a := context.allocator) -> (p: Predicate, err: string) {
	bad := strings.concatenate({"query: ", name, " requires a capture and at least one literal"}, context.temp_allocator)
	if len(tokens) < 2 || !tokens[0].is_capture {
		return {}, bad
	}
	for i in 1..<len(tokens) {
		if tokens[i].is_capture {
			return {}, bad
		}
	}
	values := make([]string, len(tokens) - 1, a)
	for i in 1..<len(tokens) {
		values[i - 1] = tokens[i].text
	}
	return {kind = kind, left_capture = tokens[0].text, values = values}, ""
}

// first_capture_node returns the first captured node with the given name in
// the match: an absent name yields ok=false (the convention first_capture_text
// applies to the node's text).
first_capture_node :: proc(name: string, ps: ^Query_Predicates, match: ^Query_Match) -> (node: Node, ok: bool) {
	for i in u32(0)..<u32(match.capture_count) {
		cap := match.captures[i]
		if int(cap.index) >= len(ps.capture_names) || ps.capture_names[cap.index] != name {
			continue
		}
		return cap.node, true
	}
	return
}

// first_capture_text returns the text of the first capture with the given
// name in the match: an absent name or a nil node yields ok=false.
first_capture_text :: proc(name: string, ps: ^Query_Predicates, match: ^Query_Match, source: string) -> (text: string, ok: bool) {
	node, found := first_capture_node(name, ps, match)
	if !found || node_is_null(node) {
		return "", false
	}
	return node_text(node, source), true
}

string_in_list :: proc(value: string, values: []string) -> bool {
	for v in values {
		if v == value {
			return true
		}
	}
	return false
}

// node_type_in reports whether the node's type name is in the list; the
// C string borrows the language's static type-name data.
node_type_in :: proc(node: Node, types: []string) -> bool {
	name := node_type(node)
	if name == nil {
		return false
	}
	return string_in_list(string(name), types)
}

// Borrowed query strings — valid only while the Query is alive.
query_string_borrowed :: proc(q: Query, id: u32) -> string {
	n: u32
	c := query_string_value_for_id(q, id, &n)
	if c == nil {
		return ""
	}
	s := string(c)
	if len(s) > int(n) {
		s = s[:int(n)]
	}
	return s
}

query_capture_name_borrowed :: proc(q: Query, id: u32) -> string {
	n: u32
	c := query_capture_name_for_id(q, id, &n)
	if c == nil {
		return ""
	}
	s := string(c)
	if len(s) > int(n) {
		s = s[:int(n)]
	}
	return s
}
