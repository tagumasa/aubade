// File outline projection onto the C tree-sitter API. One tags query per
// language is
// compiled into an Outliner; outline_tree projects an already-parsed tree
// into a containment forest of normalized symbols plus a receipt that
// accounts for every dropped candidate.
//
// Candidate handling: the LAST "@name"
// capture in a match wins, matches without a "@definition.X" capture are
// not candidates, and a match carrying more than one definition capture is
// dropped whole. Kinds come from the capture suffix through fixed tables (an identity table plus an enum/record refinement on the
// node type), never from the language name. Ambiguity rules drop candidates
// that are nameless, whose name span escapes the definition span, whose
// span carries conflicting kinds or names, and exact repeats keep the first
// emission. The forest nests by byte containment; partial overlaps drop the
// later start.
//
// The reference caches one Outliner per language in a package global; this
// port has no process-global state — callers own the Outliner lifetime
// (build_outliner / outliner_destroy), and the daemon layer caches per
// language once the svc face lands.
package ts

import "base:runtime"
import "core:strings"

OUTLINE_DEFINITION_PREFIX :: "definition."
OUTLINE_NAME_CAPTURE :: "name"

Span :: struct {
	start_byte: u32,
	end_byte:   u32,
	start_point: Point,
	end_point:   Point,
}

Outline_Symbol :: struct {
	// kind is the normalized definition kind ("function", "method",
	// "class", ... — the capture suffix after the fixed tables).
	kind: string,
	// name is the trimmed "@name" capture text.
	name: string,
	// node_type is the grammar node type of the captured definition node.
	node_type: string,
	span:      Span, // full span of the definition node
	name_span: Span, // span of the "@name" capture node (inside span)
	// owner is the non-lexical owner name (a Go method's receiver type);
	// set only when an owner rule resolves it, "" otherwise.
	owner: string,
	// children are the definitions lexically nested inside this one, in
	// source order.
	children: []Outline_Symbol,
}

// All strings and nested slices of an outline forest are clones in the
// allocator passed to outline_tree; outline_results_destroy frees them.
// Request arenas skip the destroy — free_all covers it.

Outline_Decline :: enum {
	None, // the outliner ran the query (an empty reason with zero symbols
	// means the query matched nothing)
	Query_Empty, // the language resolves to no tags query
	Nil_Tree,
	Nil_Root_Node,
	Language_Mismatch, // caller misuse: tree from another language
}

Outline_Report :: struct {
	symbols:                      int,
	omitted_no_name:              int,
	omitted_duplicate:            int,
	omitted_name_conflict:        int,
	omitted_conflict:             int,
	omitted_overlap:              int,
	omitted_invalid_name_range:   int,
	omitted_multiple_definitions: int,
	owner_rule_misses:            int, // not an omission: the symbol stays
	decline_reason:               Outline_Decline,
	truncated:                    bool,
	tree_has_error:               bool,
}

report_declined :: proc(r: ^Outline_Report) -> bool {
	return r.decline_reason != .None
}

report_omitted :: proc(r: ^Outline_Report) -> int {
	return r.omitted_no_name +
		r.omitted_duplicate +
		r.omitted_name_conflict +
		r.omitted_conflict +
		r.omitted_overlap +
		r.omitted_invalid_name_range +
		r.omitted_multiple_definitions
}

report_candidates :: proc(r: ^Outline_Report) -> int {
	return r.symbols + report_omitted(r)
}

// Owner_Rule resolves the non-lexical owner of one definition shape: read
// the named field, descend only through the unwrap node types, and accept
// exactly one terminal name-types node. Rules are data; the per-language
// table lives at OUTLINE_OWNER_RULE_TABLE below.
Owner_Rule :: struct {
	node_type:   string,
	owner_field: string,
	unwrap:      []string,
	name_types:  []string,
}

Outliner :: struct {
	lang:        Language,
	query:       Query, // nil when query_empty
	query_empty: bool,
	preds:       Query_Predicates, // capture names + compiled predicates
	owner_rules: [dynamic]Owner_Rule,
	match_limit: u32, // 0 keeps the engine default
	allocator:   runtime.Allocator,
}

Outline_Result :: struct {
	symbols: []Outline_Symbol,
	report:  Outline_Report,
}

// ---------------------------------------------------------------------------
// Per-language query overrides and owner rules (data)
// ---------------------------------------------------------------------------

// goOutlineQuery extends the shipped Go tags query: the grammar's tags only
// capture functions and methods; these patterns add type, constant, and
// variable definitions so a Go outline carries the same symbol families
// gopls reports. Field constraints ("name:") keep value expressions inside
// a declaration from binding "@name" twice on one span (the outliner drops
// such groups as name conflicts).
GO_OUTLINE_QUERY :: `
(function_declaration name: (identifier) @name) @definition.function
(method_declaration name: (field_identifier) @name) @definition.method
	(method_elem name: (field_identifier) @name) @definition.method
(field_declaration name: (field_identifier) @name) @definition.field
(type_declaration (type_spec name: (type_identifier) @name)) @definition.type
(const_spec name: (identifier) @name) @definition.constant
(var_spec name: (identifier) @name) @definition.variable
`

// outline_query_override returns the replacement tags query for languages
// whose shipped/inferred query misses symbol families aubade needs, ""
// when the registry entry's tags_query should be used as-is. The odin row
// takes effect once the odin grammar is pinned; the grammar ships no tags
// query of its own.
outline_query_override :: proc(lang_name: string) -> string {
	switch lang_name {
	case "go":
		return GO_OUTLINE_QUERY
	case "odin":
		return `
(procedure_declaration . (identifier) @name) @definition.function
(struct_declaration . (identifier) @name) @definition.type
(enum_declaration . (identifier) @name) @definition.type
(union_declaration . (identifier) @name) @definition.type
(bit_field_declaration . (identifier) @name) @definition.type
(const_declaration . (identifier) @name) @definition.constant
(variable_declaration . (identifier) @name) @definition.variable
`
	case "typescript":
		return `
(function_declaration name: (identifier) @name) @definition.function
(method_definition name: (property_identifier) @name) @definition.method
(class_declaration name: (type_identifier) @name) @definition.class
(public_field_definition name: (property_identifier) @name) @definition.field
(interface_declaration name: (type_identifier) @name) @definition.interface
(type_alias_declaration name: (type_identifier) @name) @definition.type
(enum_declaration name: (identifier) @name) @definition.type
(lexical_declaration (variable_declarator name: (identifier) @name)) @definition.variable
(variable_declaration (variable_declarator name: (identifier) @name)) @definition.variable
`
	case:
		return ""
	}
}

// The per-language owner-rule table. Every row is gated against the
// language's own symbol and field tables at build time (a regenerated
// grammar that renames or drops a node type narrows coverage instead of
// feeding the resolver a shape it cannot resolve).
outline_owner_rule_rows :: proc(lang_name: string, a := context.allocator) -> []Owner_Rule {
	// Go: a method's receiver is the sole child of the "receiver" field's
	// parameter_list, unwrapped through the parameter declaration, an
	// optional pointer and/or generic wrapper, down to the bare type name.
	// A generic receiver's type argument sits inside "type_arguments",
	// which the unwrap chain does not name, so the walk resolves the base
	// type name alone.
	if lang_name != "go" {
		return nil
	}
	unwrap := make([]string, 4, a)
	unwrap[0] = "parameter_list"
	unwrap[1] = "parameter_declaration"
	unwrap[2] = "pointer_type"
	unwrap[3] = "generic_type"
	name_types := make([]string, 1, a)
	name_types[0] = "type_identifier"
	rules := make([]Owner_Rule, 1, a)
	rules[0] = {
		node_type = "method_declaration",
		owner_field = "receiver",
		unwrap = unwrap,
		name_types = name_types,
	}
	return rules
}

owner_rules_destroy :: proc(rules: []Owner_Rule, a := context.allocator) {
	for i in 0..<len(rules) {
		// Plain slices carry no allocator: free through `a` (the allocator
		// that built them), not the destroying thread's context.
		delete(rules[i].unwrap, a)
		delete(rules[i].name_types, a)
	}
	delete(rules, a)
}

// gate_owner_rules keeps only the rows the language's own grammar can
// resolve: the node type, the field, and every unwrap/name-types entry must
// exist in the compiled grammar.
gate_owner_rules :: proc(lang: Language, rules: []Owner_Rule, a := context.allocator) -> []Owner_Rule {
	if len(rules) == 0 || lang == nil {
		return nil
	}
	kept := make([dynamic]Owner_Rule, 0, len(rules), a)
	for i in 0..<len(rules) {
		rule := &rules[i]
		if !language_has_symbol(lang, rule.node_type) || !language_has_field(lang, rule.owner_field) {
			continue
		}
		ok := true
		for j in 0..<len(rule.unwrap) {
			if !language_has_symbol(lang, rule.unwrap[j]) {
				ok = false
				break
			}
		}
		if ok {
			for j in 0..<len(rule.name_types) {
				if !language_has_symbol(lang, rule.name_types[j]) {
					ok = false
					break
				}
			}
		}
		if !ok {
			continue
		}
		append(&kept, rules[i])
	}
	return kept[:]
}

language_has_symbol :: proc(lang: Language, name: string) -> bool {
	c, aerr := strings.clone_to_cstring(name, context.temp_allocator)
	if aerr != nil {
		// Fail closed: a name we cannot even hand to the grammar counts as
		// unresolvable, so gate_owner_rules drops the rule.
		return false
	}
	return language_symbol_for_name(lang, c, u32(len(name)), true) != 0
}

language_has_field :: proc(lang: Language, name: string) -> bool {
	// Field ids are 1-based (0 means "no field"); the C API returns a bare
	// NUL-terminated name with no length out-param.
	count := language_field_count(lang)
	for id in u32(1)..=count {
		c := language_field_name_for_id(lang, id)
		if c == nil {
			continue
		}
		if string(c) == name {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Outliner lifecycle
// ---------------------------------------------------------------------------

// build_outliner compiles the language's tags query together with its
// predicate table and gated owner rules. The query resolves as: the
// handwritten per-language override, then the grammar's shipped
// tags.scm, then the inferred query (see tags_infer.odin) — a shipped
// query the C core rejects (ts_query_new refuses the whole multi-
// pattern query on one impossible pattern) also falls through to
// inference. The caller owns the result and releases it with
// outliner_destroy. A language resolving no query at all builds
// successfully but declines at outline_tree time (Query_Empty) —
// observably uncovered rather than silently empty.
build_outliner :: proc(lang_name: string, a := context.allocator) -> (o: ^Outliner, err: string) {
	idx, ok := registry_lookup(lang_name)
	if !ok {
		return nil, strings.concatenate({"unsupported language: ", lang_name}, context.temp_allocator)
	}
	// Materialize the registry locally before indexing (the compiler
	// rejects variable indexing straight into constant data).
	table := GRAMMARS
	lang, available := registry_language(idx)
	if !available {
		return nil, strings.concatenate({"language unavailable on this platform: ", lang_name}, context.temp_allocator)
	}

	query_src := table[idx].tags_query
	if override := outline_query_override(table[idx].name); override != "" {
		query_src = override
	}

	o = new(Outliner, a)
	o^ = {lang = lang, allocator = a}

	if strings.trim_space(query_src) != "" {
		o.query = compile_query(lang, query_src)
	}
	if o.query == nil {
		inferred := tags_query_infer(table[idx].name, lang)
		if strings.trim_space(inferred) != "" {
			o.query = compile_query(lang, inferred)
		}
	}
	if o.query == nil {
		if strings.trim_space(query_src) != "" {
			outliner_destroy(o)
			return nil, strings.concatenate({
				"outline query failed to compile for ", table[idx].name,
			}, context.temp_allocator)
		}
		o.query_empty = true
		return o, ""
	}
	preds, perr := compile_predicates(o.query, a)
	if perr != "" {
		outliner_destroy(o)
		return nil, perr
	}
	o.preds = preds
	o.match_limit = u32(MAX_QUERY_MATCHES)

	raw_rules := outline_owner_rule_rows(table[idx].name, a)
	o.owner_rules = make([dynamic]Owner_Rule, 0, len(raw_rules), a)
	for rule in gate_owner_rules(lang, raw_rules, context.temp_allocator) {
		// The gated rows borrow the temp-allocated table; copy the rows
		// (and their lists) into the outliner's allocator so the outliner
		// outlives the call.
		unwrap := make([]string, len(rule.unwrap), a)
		for i in 0..<len(rule.unwrap) {
			unwrap[i] = strings.clone(rule.unwrap[i], a)
		}
		name_types := make([]string, len(rule.name_types), a)
		for i in 0..<len(rule.name_types) {
			name_types[i] = strings.clone(rule.name_types[i], a)
		}
		append(&o.owner_rules, Owner_Rule{
			node_type = strings.clone(rule.node_type, a),
			owner_field = strings.clone(rule.owner_field, a),
			unwrap = unwrap,
			name_types = name_types,
		})
	}
	owner_rules_destroy(raw_rules, a)
	return o, ""
}

outliner_destroy :: proc(o: ^Outliner) {
	if o == nil {
		return
	}
	a := o.allocator
	for i in 0..<len(o.owner_rules) {
		for u in 0..<len(o.owner_rules[i].unwrap) {
			delete(o.owner_rules[i].unwrap[u], a)
		}
		for n in 0..<len(o.owner_rules[i].name_types) {
			delete(o.owner_rules[i].name_types[n], a)
		}
		delete(o.owner_rules[i].unwrap, a)
		delete(o.owner_rules[i].name_types, a)
		if o.owner_rules[i].node_type != "" {
			delete(o.owner_rules[i].node_type, a)
		}
		if o.owner_rules[i].owner_field != "" {
			delete(o.owner_rules[i].owner_field, a)
		}
	}
	// [dynamic] fields carry their own allocator — delete needs no argument.
	delete(o.owner_rules)
	predicates_destroy(&o.preds, a)
	if o.query != nil {
		query_delete(o.query)
	}
	free(o, a)
}

// outliner_definition_kinds returns the normalized kinds the compiled query
// can emit, sorted. It is an upper bound on the Kind values the outline
// will produce, not a promise that each appears.
outliner_definition_kinds :: proc(o: ^Outliner, a := context.allocator) -> (kinds: []string) {
	if o == nil || o.query == nil {
		return nil
	}
	prefix_len := len(OUTLINE_DEFINITION_PREFIX)
	seen := make([dynamic]string, 0, 8, context.temp_allocator)
	count := query_capture_count(o.query)
	for i in u32(0)..<count {
		name := query_capture_name_borrowed(o.query, i)
		if len(name) <= prefix_len || !strings.has_prefix(name, OUTLINE_DEFINITION_PREFIX) {
			continue
		}
		kind := normalize_outline_kind(name, "")
		if !string_in_list(kind, seen[:]) {
			append(&seen, kind)
		}
	}
	kinds = make([]string, len(seen), a)
	for i in 0..<len(seen) {
		kinds[i] = strings.clone(seen[i], a)
	}
	// Insertion sort: the kind set is tiny and near-sorted.
	for i in 1..<len(kinds) {
		k := kinds[i]
		j := i - 1
		for j >= 0 && kinds[j] > k {
			kinds[j + 1] = kinds[j]
			j -= 1
		}
		kinds[j + 1] = k
	}
	return kinds
}

// outline_source_supported reports whether a language can serve symbol data
// from tree-sitter: a bundled grammar, a non-empty tags query, and at least
// one emittable definition kind.
outline_source_supported :: proc(lang_name: string, a := context.allocator) -> bool {
	o, err := build_outliner(lang_name, a)
	if err != "" {
		return false
	}
	defer outliner_destroy(o)
	if o.query_empty || o.query == nil {
		return false
	}
	count := query_capture_count(o.query)
	prefix_len := len(OUTLINE_DEFINITION_PREFIX)
	for i in u32(0)..<count {
		name := query_capture_name_borrowed(o.query, i)
		if len(name) > prefix_len && strings.has_prefix(name, OUTLINE_DEFINITION_PREFIX) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Outline projection
// ---------------------------------------------------------------------------

// outline_file parses the source and projects its outline. The parse tree
// and the outliner are released before returning; the returned forest is
// detached (every string cloned into `a`) and freed with
// outline_results_destroy by non-arena callers.
outline_file :: proc(code: string, lang_name: string, a := context.allocator) -> (res: Outline_Result, err: string) {
	o, oerr := build_outliner(lang_name, a)
	if oerr != "" {
		return {}, oerr
	}
	defer outliner_destroy(o)

	pr, perr := parse(code, lang_name)
	if perr != "" {
		return {}, perr
	}
	defer parse_release(&pr)

	res.symbols, res.report = outline_tree(o, pr.tree, pr.source, a)
	return res, ""
}

outline_tree :: proc(
	o: ^Outliner,
	tree: Tree,
	source: string,
	a := context.allocator,
) -> (symbols: []Outline_Symbol, report: Outline_Report) {
	if o == nil {
		return nil, {}
	}
	if o.query_empty || o.query == nil {
		report.decline_reason = .Query_Empty
		return nil, report
	}
	if tree == nil {
		report.decline_reason = .Nil_Tree
		return nil, report
	}
	root := tree_root_node(tree)
	if node_is_null(root) {
		report.decline_reason = .Nil_Root_Node
		return nil, report
	}
	if tree_language(tree) != o.lang {
		report.decline_reason = .Language_Mismatch
		return nil, report
	}

	report.tree_has_error = node_has_error(root)

	candidates, truncated := collect_outline_candidates(o, root, source, &report)
	report.truncated = truncated

	kept := filter_outline_candidates(candidates, &report)
	symbols = build_outline_forest(o, kept, source, &report, a)
	report.symbols = count_outline_symbols(symbols)
	return symbols, report
}

Outline_Candidate :: struct {
	order:     int, // emission index; deterministic tie-break
	kind:      string,
	name:      string,
	node_type: string,
	span:      Span,
	name_span: Span,
	// node is the captured definition node, kept so a surviving candidate
	// can resolve its Owner. Candidates are procedure-scope scratch
	// (temp allocator); the node borrows the tree, valid through the call.
	node: Node,
}

// collect_outline_candidates runs the tags query and reduces each match to
// at most one candidate. The LAST "@name" capture in a match wins; matches
// without a definition capture are discarded without a counter; a match
// with more than one definition capture is dropped and counted.
collect_outline_candidates :: proc(
	o: ^Outliner,
	root: Node,
	source: string,
	report: ^Outline_Report,
) -> (candidates: []Outline_Candidate, truncated: bool) {
	cursor := query_cursor_new()
	if cursor == nil {
		return nil, false
	}
	defer query_cursor_delete(cursor)
	if o.match_limit > 0 {
		query_cursor_set_match_limit(cursor, o.match_limit)
	}
	query_cursor_exec(cursor, o.query, root)

	dyn := make([dynamic]Outline_Candidate, 0, 32, context.temp_allocator)
	prefix_len := len(OUTLINE_DEFINITION_PREFIX)

	match: Query_Match
	for query_cursor_next_match(cursor, &match) {
		if !predicates_match(&o.preds, &match, source) {
			continue
		}

		def_capture := ""
		def_node: Node
		def_count := 0
		has_name := false
		name_text := ""
		name_span: Span
		for i in u32(0)..<u32(match.capture_count) {
			cap := match.captures[i]
			if int(cap.index) >= len(o.preds.capture_names) {
				continue
			}
			cap_name := o.preds.capture_names[cap.index]
			if cap_name == OUTLINE_NAME_CAPTURE {
				has_name = true
				name_text = node_text(cap.node, source)
				name_span = node_span(cap.node)
			} else if len(cap_name) > prefix_len && strings.has_prefix(cap_name, OUTLINE_DEFINITION_PREFIX) {
				def_capture = cap_name
				def_node = cap.node
				def_count += 1
			}
		}
		if def_count == 0 {
			continue
		}
		if def_count > 1 {
			report.omitted_multiple_definitions += 1
			continue
		}

		node_type := cstring_to_string(node_type(def_node))
		candidate := Outline_Candidate{
			order = len(dyn),
			kind = normalize_outline_kind(def_capture, node_type),
			node_type = node_type,
			span = node_span(def_node),
			node = def_node,
		}
		if has_name {
			candidate.name = name_text
			candidate.name_span = name_span
		}
		append(&dyn, candidate)
	}

	return dyn[:], query_cursor_did_exceed_match_limit(cursor)
}

// normalize_outline_kind maps a "@definition.X" capture name to a
// normalized kind. The reference maps the suffix through a fixed identity
// table (unlisted suffixes pass through unchanged), so the only observable
// mapping is the node-type refinement: type/class captures on enumeration
// or record declarations refine to "enum" / "record". A refinement can
// never overrule a more specific capture — it applies to "type" and
// "class" only.
normalize_outline_kind :: proc(capture_name: string, node_type: string) -> string {
	kind := capture_name[len(OUTLINE_DEFINITION_PREFIX):]
	if kind != "type" && kind != "class" {
		return kind
	}
	switch node_type {
	case "enum_declaration", "enum_item":
		return "enum"
	case "record_declaration":
		return "record"
	case:
		return kind
	}
}

// filter_outline_candidates applies the ambiguity rules and returns the
// survivors in emission order. Every dropped candidate lands in exactly one
// counter: nameless (1), name span outside the definition span (2), one
// span with two kinds (3), one span+kind with two names (4); exact repeats
// of an accepted tuple keep the first emission (5).
filter_outline_candidates :: proc(candidates: []Outline_Candidate, report: ^Outline_Report) -> []Outline_Candidate {
	if len(candidates) == 0 {
		return nil
	}

	// Rules 1 and 2: per-candidate validity.
	valid := make([dynamic]Outline_Candidate, 0, len(candidates), context.temp_allocator)
	for i in 0..<len(candidates) {
		candidate := candidates[i]
		candidate.name = strings.trim_space(candidate.name)
		if candidate.name == "" {
			report.omitted_no_name += 1
			continue
		}
		if !outline_span_contains(candidate.span, candidate.name_span) {
			report.omitted_invalid_name_range += 1
			continue
		}
		append(&valid, candidate)
	}
	if len(valid) == 0 {
		return nil
	}

	// Rules 3, 4, and 5: group by exact span. Equal-span candidates may be
	// separated in emission order, so groups are span-keyed with insertion
	// order recorded separately.
	Group_Key :: struct {
		start: u32,
		end:   u32,
	}
	groups := make(map[Group_Key][dynamic]int, len(valid), context.temp_allocator)
	span_order := make([dynamic]Group_Key, 0, len(valid), context.temp_allocator)
	for i in 0..<len(valid) {
		key := Group_Key{start = valid[i].span.start_byte, end = valid[i].span.end_byte}
		if _, seen := groups[key]; !seen {
			append(&span_order, key)
		}
		// Map values are not addressable: grow through a local header and
		// store it back (append may reallocate the backing). A nil dynamic
		// must be made first — appending to the zero value would grow it
		// through context.allocator instead of the temp scratch.
		row, have := groups[key]
		if !have || row == nil {
			row = make([dynamic]int, 0, 2, context.temp_allocator)
		}
		append(&row, i)
		groups[key] = row
	}

	kept := make([dynamic]Outline_Candidate, 0, len(valid), context.temp_allocator)
	for gi in 0..<len(span_order) {
		members := groups[span_order[gi]]
		first := &valid[members[0]]

		kind_conflict := false
		name_conflict := false
		for k in 1..<len(members) {
			m := &valid[members[k]]
			if m.kind != first.kind {
				kind_conflict = true
				break
			}
			if !outline_same_name(m, first) {
				name_conflict = true
			}
		}

		if kind_conflict {
			// The span means two things at once: drop the whole group.
			report.omitted_conflict += len(members)
			continue
		}
		if name_conflict {
			// The span agrees on the kind and disagrees on the name;
			// picking by capture order would publish whichever binding the
			// grammar reached first. Drop the group.
			report.omitted_name_conflict += len(members)
			continue
		}
		// Indistinguishable members: keep the first emission.
		best := 0
		for k in 1..<len(members) {
			if valid[members[k]].order < valid[members[best]].order {
				best = k
			}
		}
		report.omitted_duplicate += len(members) - 1
		append(&kept, valid[members[best]])
	}
	return kept[:]
}

// build_outline_forest assembles the containment forest. Candidates sort by
// start byte ascending then end byte descending (a container precedes
// everything it contains); a stack walk assigns parents, and a span that
// starts inside the top but ends after it overlaps without containing, so
// it is dropped and counted. Materialization runs in reverse index order —
// every child has a higher sorted index than its parent — and is where
// Owner resolves and every string is cloned into `a`.
build_outline_forest :: proc(
	o: ^Outliner,
	candidates: []Outline_Candidate,
	source: string,
	report: ^Outline_Report,
	a := context.allocator,
) -> []Outline_Symbol {
	if len(candidates) == 0 {
		return nil
	}

	sorted := make([]Outline_Candidate, len(candidates), context.temp_allocator)
	for i in 0..<len(candidates) {
		sorted[i] = candidates[i]
	}
	outline_sort_candidates(sorted)

	accepted := make([dynamic]Outline_Candidate, 0, len(sorted), context.temp_allocator)
	parent_of := make([dynamic]int, 0, len(sorted), context.temp_allocator)
	children_of := make([dynamic][dynamic]int, 0, len(sorted), context.temp_allocator)
	stack := make([dynamic]int, 0, 16, context.temp_allocator)

	for i in 0..<len(sorted) {
		candidate := sorted[i]
		for len(stack) > 0 {
			top := &accepted[stack[len(stack) - 1]]
			if candidate.span.start_byte < top.span.end_byte {
				break
			}
			pop(&stack)
		}

		parent := -1
		if len(stack) > 0 {
			top := &accepted[stack[len(stack) - 1]]
			if candidate.span.end_byte > top.span.end_byte {
				// Partial overlap: the forest has no well-defined shape
				// here, so drop the later start.
				report.omitted_overlap += 1
				continue
			}
			parent = stack[len(stack) - 1]
		}

		idx := len(accepted)
		append(&accepted, candidate)
		append(&parent_of, parent)
		append(&children_of, make([dynamic]int, 0, 2, context.temp_allocator))
		if parent >= 0 {
			append(&children_of[parent], idx)
		}
		append(&stack, idx)
	}

	// Materialize in reverse: children are built before their parents. The
	// built array is procedure-scope scratch (temp allocator); every string
	// and child slice inside it is allocated in `a` and owned by the
	// returned forest.
	built := make([]Outline_Symbol, len(accepted), context.temp_allocator)
	for idx := len(accepted) - 1; idx >= 0; idx -= 1 {
		candidate := &accepted[idx]
		symbol := Outline_Symbol{
			kind = strings.clone(candidate.kind, a),
			name = strings.clone(candidate.name, a),
			node_type = strings.clone(candidate.node_type, a),
			span = candidate.span,
			name_span = candidate.name_span,
			owner = strings.clone(
				resolve_outline_owner(o, candidate.node, candidate.node_type, source, report),
				a,
			),
		}
		if len(children_of[idx]) > 0 {
			kids := make([]Outline_Symbol, len(children_of[idx]), a)
			for k in 0..<len(children_of[idx]) {
				kids[k] = built[children_of[idx][k]]
			}
			symbol.children = kids
		}
		built[idx] = symbol
	}

	roots := make([dynamic]Outline_Symbol, 0, len(accepted), a)
	for idx in 0..<len(accepted) {
		if parent_of[idx] == -1 {
			append(&roots, built[idx])
		}
	}
	return roots[:]
}

// outline_sort_candidates orders by start byte ascending, end byte
// descending, emission order last — a total order, so stability does not
// matter. Insertion sort: outline candidate lists arrive almost sorted
// (query emission follows document order).
outline_sort_candidates :: proc(sorted: []Outline_Candidate) {
	for i in 1..<len(sorted) {
		c := sorted[i]
		j := i - 1
		for j >= 0 && outline_candidate_less(&c, &sorted[j]) {
			sorted[j + 1] = sorted[j]
			j -= 1
		}
		sorted[j + 1] = c
	}
}

outline_candidate_less :: proc(a, b: ^Outline_Candidate) -> bool {
	if a.span.start_byte != b.span.start_byte {
		return a.span.start_byte < b.span.start_byte
	}
	if a.span.end_byte != b.span.end_byte {
		return a.span.end_byte > b.span.end_byte
	}
	return a.order < b.order
}

// resolve_outline_owner resolves the non-lexical Owner of one definition
// node against the rules registered for its node type. A node type with no
// rule never touches Owner or the miss counter; a node type with rules that
// all fail (field absent, unwrap chain exhausted, or not exactly one
// accepted terminal) counts one miss and leaves Owner empty.
resolve_outline_owner :: proc(
	o: ^Outliner,
	node: Node,
	node_type: string,
	source: string,
	report: ^Outline_Report,
) -> string {
	if len(o.owner_rules) == 0 {
		return ""
	}
	matched := false
	for i in 0..<len(o.owner_rules) {
		rule := &o.owner_rules[i]
		if rule.node_type != node_type {
			continue
		}
		matched = true
		if owner, resolved := resolve_outline_owner_rule(rule, node, source); resolved {
			return owner
		}
	}
	if matched {
		report.owner_rule_misses += 1
	}
	return ""
}

resolve_outline_owner_rule :: proc(rule: ^Owner_Rule, node: Node, source: string) -> (owner: string, resolved: bool) {
	c_field, aerr := strings.clone_to_cstring(rule.owner_field, context.temp_allocator)
	if aerr != nil {
		// Decline (the owner stays unresolved) rather than hand NULL to
		// node_child_by_field_name with a non-zero length.
		return "", false
	}
	field := node_child_by_field_name(node, c_field, u32(len(rule.owner_field)))
	if node_is_null(field) {
		return "", false
	}
	matches := collect_outline_owner_name_nodes(field, rule)
	if len(matches) != 1 {
		return "", false
	}
	text := node_text(matches[0], source)
	if text == "" {
		return "", false
	}
	return text, true
}

// collect_outline_owner_name_nodes walks from start and returns every node
// whose type is in name_types. The walk descends only through unwrap types
// and never past a name-types match, so a terminal nested inside a type the
// rule does not list (a generic receiver's type argument) is never reached.
collect_outline_owner_name_nodes :: proc(start: Node, rule: ^Owner_Rule) -> []Node {
	matches := make([dynamic]Node, 0, 4, context.temp_allocator)
	outline_owner_walk(&matches, start, rule)
	return matches[:]
}

outline_owner_walk :: proc(matches: ^[dynamic]Node, node: Node, rule: ^Owner_Rule) {
	// Iterative like count_outline_symbols: pathological sources nest
	// unwrap chains deep enough to overflow the stack under recursion.
	stack := make([dynamic]Node, 0, 8, context.temp_allocator)
	append(&stack, node)
	for len(stack) > 0 {
		cur := stack[len(stack) - 1]
		pop(&stack)
		if node_is_null(cur) {
			continue
		}
		t := cstring_to_string(node_type(cur))
		if string_in_list(t, rule.name_types) {
			append(matches, cur)
			continue
		}
		if !string_in_list(t, rule.unwrap) {
			continue
		}
		count := node_named_child_count(cur)
		// Push children in reverse so pops visit them in ascending order.
		for i := int(count) - 1; i >= 0; i -= 1 {
			append(&stack, node_named_child(cur, u32(i)))
		}
	}
}

count_outline_symbols :: proc(symbols: []Outline_Symbol) -> int {
	total := 0
	stack := make([dynamic][]Outline_Symbol, 0, 8, context.temp_allocator)
	append(&stack, symbols)
	for len(stack) > 0 {
		level := stack[len(stack) - 1]
		pop(&stack)
		total += len(level)
		for i in 0..<len(level) {
			if len(level[i].children) > 0 {
				append(&stack, level[i].children)
			}
		}
	}
	return total
}

// outline_results_destroy frees an outline forest built for a non-arena
// allocator; request arenas free_all instead. Strings and child slices are
// owned by the forest — this is the single release path; pass the allocator
// that produced the forest (the default matches outline_tree's own default).
outline_results_destroy :: proc(symbols: []Outline_Symbol, a := context.allocator) {
	// Iterative like count_outline_symbols: pathological sources nest
	// deeply enough that per-level recursion overflows the stack.
	stack := make([dynamic][]Outline_Symbol, 0, 8, context.temp_allocator)
	defer delete(stack)
	if symbols != nil {
		append(&stack, symbols)
	}
	for len(stack) > 0 {
		level := stack[len(stack) - 1]
		pop(&stack)
		for i in 0..<len(level) {
			if len(level[i].children) > 0 {
				append(&stack, level[i].children)
			}
			if level[i].kind != "" {
				delete(level[i].kind, a)
			}
			if level[i].name != "" {
				delete(level[i].name, a)
			}
			if level[i].node_type != "" {
				delete(level[i].node_type, a)
			}
			if level[i].owner != "" {
				delete(level[i].owner, a)
			}
		}
		delete(level, a)
	}
}

outline_same_name :: proc(a, b: ^Outline_Candidate) -> bool {
	return a.name == b.name &&
		a.name_span.start_byte == b.name_span.start_byte &&
		a.name_span.end_byte == b.name_span.end_byte
}

// outline_span_contains reports whether inner sits inside outer, by bytes.
// A span equal to outer counts as contained; an inverted span contains
// nothing.
outline_span_contains :: proc(outer, inner: Span) -> bool {
	if outer.end_byte < outer.start_byte || inner.end_byte < inner.start_byte {
		return false
	}
	return inner.start_byte >= outer.start_byte && inner.end_byte <= outer.end_byte
}

node_span :: proc(node: Node) -> Span {
	return {
		start_byte = node_start_byte(node),
		end_byte = node_end_byte(node),
		start_point = node_start_point(node),
		end_point = node_end_point(node),
	}
}
