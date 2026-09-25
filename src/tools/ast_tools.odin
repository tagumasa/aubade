// The tree-sitter tool family over svc.ast/*: syntactic parse and query
// on raw code strings with no project state.
package tools

import "src:util"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "src:jsonutil"
import "src:svc"

AST_PARSE_PARAMS :: []Param_Desc{
	{name = "lang", kind = .Str, description = "Language id — any grammar in the bundled registry (odin, go, python, lua, c_sharp, bash, rust, ...).", required = true},
	{name = "code", kind = .Str, description = "Source code to parse.", required = true},
	{name = "max_answer_chars", kind = .Int, description = "Answer length cap (-1 = session default).", required = false},
}

AST_QUERY_PARAMS :: []Param_Desc{
	{name = "lang", kind = .Str, description = "Language id.", required = true},
	{name = "code", kind = .Str, description = "Source code to query.", required = true},
	{name = "query", kind = .Str, description = "Tree-sitter .scm query.", required = true},
	{name = "max_answer_chars", kind = .Int, description = "Answer length cap (-1 = session default).", required = false},
}

AST_FIND_DUPLICATES_PARAMS :: []Param_Desc{
	{name = "path_prefix", kind = .Str, description = "Report only occurrences under this project-relative directory (the scan itself always covers the whole project).", required = false},
	{name = "min_nodes", kind = .Int, description = "Minimum named-node count of a reported fragment (default 50, range 10-100000).", required = false},
	{name = "limit", kind = .Int, description = "Maximum reported groups (default 50, range 1-500).", required = false},
	{name = "max_answer_chars", kind = .Int, description = "Answer length cap (-1 = session default).", required = false},
}

ast_parse :: Tool_Desc{
	name        = "ast_parse",
	title       = "Parse AST",
	description = "Parse source code into an AST rendered as an S-expression; inspect it to learn node and field names before ast_query.",
	can_edit    = false,
	optional    = false,
	category    = .Ast,
	params      = AST_PARSE_PARAMS,
	needs       = {Cap.Svc},
	apply       = ast_parse_apply,
}

ast_query :: Tool_Desc{
	name        = "ast_query",
	title       = "Query AST",
	description = "Run a tree-sitter .scm query against source code and return the matching captures.",
	can_edit    = false,
	optional    = false,
	category    = .Ast,
	params      = AST_QUERY_PARAMS,
	needs       = {Cap.Svc},
	apply       = ast_query_apply,
}

ast_find_duplicates :: Tool_Desc{
	name        = "ast_find_duplicates",
	title       = "Find duplicate code",
	description = "Report duplicated code fragments deterministically from tree-sitter structure: named subtrees of at least min_nodes (default 50) nodes that repeat across the project. kind \"exact\" covers identical structure (comments and formatting ignored, operators distinguished); kind \"renamed\" covers copy-paste with consistently renamed identifiers and any literal values. Groups report maximal clones only — fragments nested inside a reported duplicate do not re-report. Occurrences are 0-based inclusive line spans, and answers are sorted deterministically. path_prefix filters the report; the scan always covers the project.",
	can_edit    = false,
	optional    = false,
	category    = .Ast,
	params      = AST_FIND_DUPLICATES_PARAMS,
	needs       = {Cap.Project, Cap.Svc},
	apply       = ast_find_duplicates_apply,
}

ast_parse_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	call := svc.client_ast_parse(
		ctx.svc_conn, arg_str(args, "lang"), arg_str(args, "code"), max_chars,
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	sexpr, _ := json_str(call.result, "sexpr")
	return text_result(ctx, sexpr)
}

ast_query_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_ast_query(
		ctx.svc_conn, arg_str(args, "lang"), arg_str(args, "code"), arg_str(args, "query"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	matches_v, ok := jsonutil.obj_get(call.result, "matches")
	n := 0
	if ok {
		if matches, aok := jsonutil.as_array(matches_v); aok {
			n = len(matches)
		}
	}
	if n == 0 {
		return text_result(ctx, "No matches found.")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	return text_result(ctx, format_ast_matches(call.result, ctx, max_chars))
}

// format_ast_matches renders the structured matches in the display
// form: "Match N (pattern P):" headers followed by indented
// capture lines, honoring the max-answer-chars gate with the truncation
// marker.
format_ast_matches :: proc(result: json.Value, ctx: ^Tool_Ctx, max_chars: int) -> string {
	matches_v, _ := jsonutil.obj_get(result, "matches")
	matches, _ := jsonutil.as_array(matches_v)

	b := strings.builder_make(ctx.allocator)
	truncated := false
	for i in 0..<len(matches) {
		if max_chars > 0 && strings.builder_len(b) >= max_chars {
			truncated = true
			break
		}
		if i > 0 {
			strings.write_string(&b, "\n")
		}
		pattern, _ := json_int(matches[i], "pattern")
		strings.write_string(&b, fmt.aprintf("Match %d (pattern %d):\n", i+1, int(pattern), allocator = ctx.allocator))
		caps_v, _ := jsonutil.obj_get(matches[i], "captures")
		caps, _ := jsonutil.as_array(caps_v)
		for c in caps {
			name, _ := json_str(c, "name")
			text, _ := json_str(c, "text")
			start, _ := json_int(c, "start_byte")
			end, _ := json_int(c, "end_byte")
			line := fmt.aprintf("  @%s: \"%s\" [%d:%d]\n", name, clean_for_display(text, ctx.allocator), int(start), int(end), allocator = ctx.allocator)
			if max_chars > 0 {
				remaining := max_chars - strings.builder_len(b)
				if remaining <= 0 {
					truncated = true
					break
				}
				if len(line) > remaining {
					// Back up to a rune boundary: a raw byte cut can split
					// a multi-byte capture into invalid UTF-8.
					cut := remaining
					for cut > 0 && line[cut] & 0xC0 == 0x80 {
						cut -= 1
					}
					line = line[:cut]
				}
			}
			strings.write_string(&b, line)
		}
	}
	if truncated {
		strings.write_string(&b, "... (truncated)")
	}
	return strings.to_string(b)
}

ast_find_duplicates_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	// Range validation here mirrors the daemon's wire check so a bad value
	// fails fast at the call site instead of after a project walk.
	min_nodes := 0
	if arg_has(args, "min_nodes") {
		min_nodes = arg_int(args, "min_nodes")
		if min_nodes < svc.CLONE_SCAN_MIN_NODES_FLOOR || min_nodes > svc.CLONE_SCAN_MAX_MIN_NODES {
			return err_result(ctx, fmt.aprintf(
				"min_nodes must be between %v and %v",
				svc.CLONE_SCAN_MIN_NODES_FLOOR, svc.CLONE_SCAN_MAX_MIN_NODES,
				allocator = ctx.allocator,
			))
		}
	}
	limit := 0
	if arg_has(args, "limit") {
		limit = arg_int(args, "limit")
		if limit <= 0 || limit > svc.CLONE_SCAN_MAX_LIMIT {
			return err_result(ctx, fmt.aprintf(
				"limit must be between 1 and %v", svc.CLONE_SCAN_MAX_LIMIT,
				allocator = ctx.allocator,
			))
		}
	}
	call := svc.client_ast_find_duplicates(ctx.svc_conn, arg_str(args, "path_prefix"), min_nodes, limit, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	shortened := []string{
		strings.concatenate({"Shortened result:\n", to_json(ast_duplicates_short_json(call.result, ctx), ctx)}, ctx.allocator),
	}
	return call_text_result(ctx, call, max_chars, shortened)
}

// ast_duplicates_short_json renders the shortened answer: kind, node
// count, and the first occurrence path per group, so a capped answer
// still names what was found where.
ast_duplicates_short_json :: proc(result: json.Value, ctx: ^Tool_Ctx) -> json.Value {
	out := jsonutil.json_object(1, ctx.allocator)
	groups_v, ok := jsonutil.obj_get(result, "groups")
	items := make([dynamic]json.Value, 0, 8, ctx.allocator)
	if ok {
		if groups, aok := jsonutil.as_array(groups_v); aok {
			for g in groups {
				kind, _ := json_str(g, "kind")
				nodes, _ := json_int(g, "nodes")
				path := "unknown"
				occ_v, ook := jsonutil.obj_get(g, "occurrences")
				if ook {
					if occ, eok := jsonutil.as_array(occ_v); eok && len(occ) > 0 {
						p, _ := json_str(occ[0], "path")
						if p != "" {
							path = p
						}
					}
				}
				line := strings.concatenate({kind, " ", util.int_to_dec(int(nodes), ctx.allocator), " nodes @ ", path}, ctx.allocator)
				append(&items, jsonutil.json_string(line))
			}
		}
	}
	jsonutil.obj_set(&out, "groups", jsonutil.json_array(items[:], ctx.allocator))
	return json.Value(json.Object(out))
}

// clean_for_display escapes backslashes and quotes and replaces control
// bytes with spaces.
clean_for_display :: proc(s: string, a := context.allocator) -> string {
	b := strings.builder_make(a)
	for r in s {
		switch r {
		case '\\':
			strings.write_string(&b, "\\\\")
		case '"':
			strings.write_string(&b, "\\\"")
		case:
			if r < 0x20 {
				strings.write_byte(&b, ' ')
			} else {
				strings.write_rune(&b, r)
			}
		}
	}
	return strings.to_string(b)
}
