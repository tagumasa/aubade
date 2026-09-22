// Query execution limits: at most 10000 matches, 100 captures per
// match, and 1 MiB of combined capture text — exceeding the byte budget
// truncates and stops. Text predicates (#eq?, #match?, #any-of?, ...)
// are compiled per query and filter matches; unknown predicate names
// fail the query (the
// error string is temp-allocator scratch, consumed immediately).
package ts

import "core:strings"
import "src:util"

MAX_QUERY_MATCHES :: 10000
MAX_CAPTURES_PER_MATCH :: 100
MAX_TOTAL_CAPTURE_BYTES :: 1 << 20 // 1 MiB

Capture_Result :: struct {
	name:       string,
	text:       string,
	start_byte: int,
	end_byte:   int,
}

Match_Result :: struct {
	pattern_index: int,
	captures:      [dynamic]Capture_Result, // carries its allocator (a)
}

// Query_Call_Err closes the query failure vocabulary: language resolution and
// query authoring are caller mistakes; the rest are internal.
Query_Call_Err :: enum {
	None,
	Unsupported_Language,
	Syntax,
	Internal,
}

query :: proc(code: string, lang_name: string, query_str: string, a := context.allocator) -> (results: []Match_Result, qerr: Query_Call_Err, msg: string) {
	res, perr := parse(code, lang_name)
	if perr != "" {
		// parse's only failure mode is language resolution.
		return nil, .Unsupported_Language, perr
	}
	defer parse_release(&res)

	return query_tree(res.tree, res.lang, res.source, query_str, a)
}

// query_tree runs a compiled-at-call query over the tree. The results
// (and every capture list) are allocated in `a` and owned by the caller:
// request arenas free_all them, other allocators use query_results_destroy.
// Nodes are read before returning, so the results never borrow the tree.
query_tree :: proc(tree: Tree, lang: Language, source: string, query_str: string, a := context.allocator) -> (results: []Match_Result, qerr: Query_Call_Err, msg: string) {
	if tree == nil {
		return nil, .Internal, "tree is nil"
	}
	if lang == nil {
		return nil, .Internal, "language is nil"
	}

	q := compile_query(lang, query_str)
	if q == nil {
		return nil, .Syntax, "query syntax error"
	}
	defer query_delete(q)

	preds, perr := compile_predicates(q, a)
	if perr != "" {
		return nil, .Syntax, perr
	}
	defer predicates_destroy(&preds, a)

	cursor := query_cursor_new()
	if cursor == nil {
		return nil, .Internal, "query cursor allocation failed"
	}
	defer query_cursor_delete(cursor)
	query_cursor_set_match_limit(cursor, u32(MAX_QUERY_MATCHES))
	query_cursor_exec(cursor, q, tree_root_node(tree))

	dyn := make([dynamic]Match_Result, 0, 16, a)

	total_capture_bytes := 0
	match: Query_Match
	for query_cursor_next_match(cursor, &match) {
		if !predicates_match(&preds, &match, source) {
			continue
		}
		if len(dyn) >= MAX_QUERY_MATCHES {
			break
		}
		caps := make([dynamic]Capture_Result, 0, min(int(match.capture_count), MAX_CAPTURES_PER_MATCH), a)
		for i in u32(0)..<u32(match.capture_count) {
			if len(caps) >= MAX_CAPTURES_PER_MATCH {
				break
			}
			cap := match.captures[i]
			text := node_text(cap.node, source)
			if total_capture_bytes + len(text) > MAX_TOTAL_CAPTURE_BYTES {
				remaining := MAX_TOTAL_CAPTURE_BYTES - total_capture_bytes
				if remaining > 0 {
					append(&caps, Capture_Result{
						name = capture_name(q, cap.index, a),
						text = text[:remaining],
						start_byte = int(node_start_byte(cap.node)),
						end_byte = int(node_end_byte(cap.node)),
					})
				}
				append(&dyn, Match_Result{pattern_index = int(match.pattern_index), captures = caps})
				return dyn[:], .None, ""
			}
			total_capture_bytes += len(text)
			append(&caps, Capture_Result{
				name = capture_name(q, cap.index, a),
				text = text,
				start_byte = int(node_start_byte(cap.node)),
				end_byte = int(node_end_byte(cap.node)),
			})
		}
		append(&dyn, Match_Result{pattern_index = int(match.pattern_index), captures = caps})
	}
	return dyn[:], .None, ""
}

// query_results_destroy frees results built by query_tree for allocators
// that need explicit deletes (request arenas skip this — free_all covers
// it). The capture name strings are clones owned by each capture list, so
// they are freed here too; pass the allocator that produced the results
// (the default matches query_tree's own default).
query_results_destroy :: proc(results: []Match_Result, a := context.allocator) {
	for i in 0..<len(results) {
		for j in 0..<len(results[i].captures) {
			delete(results[i].captures[j].name, a)
		}
		// [dynamic] captures carry their own allocator — no argument needed.
		delete(results[i].captures)
	}
	delete(results, a)
}

// compile_query returns nil when the source fails to compile.
compile_query :: proc(lang: Language, query_str: string) -> Query {
	src, aerr := strings.clone_to_cstring(query_str, context.temp_allocator)
	if aerr != nil {
		// nil with a non-zero length would make query_new dereference NULL.
		return nil
	}
	error_offset: u32
	error_type: Query_Err
	return query_new(lang, src, u32(len(query_str)), &error_offset, &error_type)
}

capture_name :: proc(q: Query, index: u32, a := context.allocator) -> string {
	name_len: u32
	c := query_capture_name_for_id(q, index, &name_len)
	if c == nil {
		return ""
	}
	s := string(c)
	if len(s) > int(name_len) {
		s = s[:int(name_len)]
	}
	return strings.clone(s, a)
}

format_query_results :: proc(results: []Match_Result, max_chars: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	// One truncation marker for the whole render: several loop levels can
	// hit the cap (per result, per header, per capture), and writing the
	// marker at each would print it once per level.
	truncated := false
	for i in 0..<len(results) {
		if max_chars > 0 && strings.builder_len(b) >= max_chars {
			truncated = true
			break
		}
		if i > 0 {
			strings.write_string(&b, "\n")
		}
		header := strings.concatenate({
			"Match ", util.int_to_dec(i + 1, context.temp_allocator),
			" (pattern ", util.int_to_dec(results[i].pattern_index, context.temp_allocator), "):\n",
		}, context.temp_allocator)
		if max_chars > 0 && strings.builder_len(b) + len(header) > max_chars {
			truncated = true
			break
		}
		strings.write_string(&b, header)
		captures := results[i].captures
		for j in 0..<len(captures) {
			capture_text := captures[j].text
			if max_chars > 0 {
				remaining := max_chars - strings.builder_len(b)
				if remaining <= 0 {
					truncated = true
					break
				}
				if len(capture_text) > remaining {
					capture_text = capture_text[:remaining]
				}
			}
			line := strings.concatenate({
				"  @", captures[j].name, ": \"",
				clean_string_for_display(capture_text, context.temp_allocator),
				"\" [", util.int_to_dec(captures[j].start_byte, context.temp_allocator),
				":", util.int_to_dec(captures[j].end_byte, context.temp_allocator), "]\n",
			}, context.temp_allocator)
			strings.write_string(&b, line)
		}
		if truncated {
			break
		}
	}
	if truncated {
		rendered := strings.to_string(b)
		if len(rendered) > 0 && rendered[len(rendered) - 1] != '\n' {
			strings.write_string(&b, "\n")
		}
		strings.write_string(&b, "... (truncated)")
	}
	return strings.to_string(b)
}
