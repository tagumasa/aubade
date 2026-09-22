// The file tool family: thin applies over the svc.file/* proxies. The
// daemon does the work (editor discipline, path guarding, gitignore
// walks); these procs shape the answers — fixed success strings, JSON
// renderings, and the max-answer-chars gate.
package tools

import "src:util"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "src:jsonutil"
import "src:regex"
import "src:svc"

// --- param tables --------------------------------------------------------------

FILE_READ_PARAMS :: []Param_Desc{
	{name = "relative_path", kind = .Str, description = "Project-relative file path.", required = true},
	{name = "start_line", kind = .Int, description = "First line to read (0-based; default 0).", required = false},
	{name = "end_line", kind = .Int, description = "Last line to read (0-based, inclusive).", required = false},
	{name = "max_answer_chars", kind = .Int, description = "Answer length cap (-1 = session default).", required = false},
}

FILE_WRITE_PARAMS :: []Param_Desc{
	{name = "relative_path", kind = .Str, description = "Project-relative file path.", required = true},
	{name = "content", kind = .Str, description = "Full file content.", required = true},
}

FILE_LIST_DIR_PARAMS :: []Param_Desc{
	{name = "relative_path", kind = .Str, description = "Project-relative directory path.", required = true},
	{name = "recursive", kind = .Bool, description = "List recursively.", required = true},
	{name = "skip_ignored_files", kind = .Bool, description = "Skip gitignored paths.", required = false},
	{name = "include_line_counts", kind = .Bool, description = "Include per-file line counts.", required = false},
	{name = "max_answer_chars", kind = .Int, description = "Answer length cap (-1 = session default).", required = false},
}

FILE_FIND_PARAMS :: []Param_Desc{
	{name = "file_mask", kind = .Str, description = "File name mask; a slash makes it match full relative paths.", required = true},
	{name = "relative_path", kind = .Str, description = "Directory scope (default: project root).", required = true},
}

FILE_READ_OUTLINE_PARAMS :: []Param_Desc{
	{name = "relative_path", kind = .Str, description = "Project-relative file path (.json/.jsonc/.json5/.yaml/.yml).", required = true},
	{name = "path", kind = .Str, description = "jq-style path into the document (.a.b[0].c; keys with special characters via .\"odd key\" or [\"odd key\"]; [] iterates an array; a trailing | keys lists an object's keys). Empty returns the full outline.", required = false},
	{name = "max_answer_chars", kind = .Int, description = "Answer length cap (-1 = session default).", required = false},
}

FILE_SEARCH_PARAMS :: []Param_Desc{
	{name = "substring_pattern", kind = .Str, description = "Regex pattern (DOTALL by default).", required = true},
	{name = "context_lines_before", kind = .Int, description = "Context lines before a match.", required = false},
	{name = "context_lines_after", kind = .Int, description = "Context lines after a match.", required = false},
	{name = "paths_include_glob", kind = .Str, description = "Only search paths matching this glob.", required = false},
	{name = "paths_exclude_glob", kind = .Str, description = "Skip paths matching this glob.", required = false},
	{name = "relative_path", kind = .Str, description = "Single file or directory scope.", required = false},
	{name = "multiline", kind = .Bool, description = "^ and $ match line boundaries.", required = false},
	{name = "offset", kind = .Int, description = "Skip the first N matches (0-based; match order is by path, then line). Pass the previous answer's end index to resume a truncated answer.", required = false},
	{name = "limit", kind = .Int, description = "Maximum matches to return per answer (the scan itself is unaffected). 0 or absent = all remaining.", required = false},
	{name = "max_answer_chars", kind = .Int, description = "Answer length cap (-1 = session default).", required = false},
}

FILE_REPLACE_MODES :: regex.REPLACE_MODE_NAMES

FILE_REPLACE_PARAMS :: []Param_Desc{
	{name = "relative_path", kind = .Str, description = "Project-relative file path.", required = true},
	{name = "needle", kind = .Str, description = "Pattern to replace.", required = true},
	{name = "repl", kind = .Str, description = "Replacement text.", required = true},
	{name = "mode", kind = .Str, description = "Match mode.", required = true, enum_vals = FILE_REPLACE_MODES},
	{name = "allow_multiple_occurrences", kind = .Bool, description = "Replace every occurrence.", required = false},
}

FILE_INSERT_LINES_PARAMS :: []Param_Desc{
	{name = "relative_path", kind = .Str, description = "Project-relative file path.", required = true},
	{name = "line", kind = .Int, description = "Line index to insert at (0-based).", required = true},
	{name = "content", kind = .Str, description = "Content to insert.", required = true},
}

FILE_REPLACE_LINES_PARAMS :: []Param_Desc{
	{name = "relative_path", kind = .Str, description = "Project-relative file path.", required = true},
	{name = "start_line", kind = .Int, description = "First line to replace (0-based).", required = true},
	{name = "end_line", kind = .Int, description = "Last line to replace (0-based, inclusive).", required = true},
	{name = "content", kind = .Str, description = "Replacement content.", required = true},
}

FILE_DELETE_LINES_PARAMS :: []Param_Desc{
	{name = "relative_path", kind = .Str, description = "Project-relative file path.", required = true},
	{name = "start_line", kind = .Int, description = "First line to delete (0-based).", required = true},
	{name = "end_line", kind = .Int, description = "Last line to delete (0-based, inclusive).", required = true},
}

FILE_PATH_PARAMS :: []Param_Desc{
	{name = "relative_path", kind = .Str, description = "Project-relative file path.", required = true},
}

FILE_MOVE_PARAMS :: []Param_Desc{
	{name = "source_relative_path", kind = .Str, description = "Existing file path.", required = true},
	{name = "target_relative_path", kind = .Str, description = "Destination path (must not exist).", required = true},
}

// --- tool descriptors --------------------------------------------------------

file_read :: Tool_Desc{
	name        = "file_read",
	title       = "Read file",
	description = "Read a file within the project directory. Content is capped by max_answer_chars; a read-ask warning prefixes files whose names look sensitive.",
	can_edit    = false,
	optional    = false,
	category    = .File,
	params      = FILE_READ_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = file_read_apply,
}

file_write :: Tool_Desc{
	name        = "file_write",
	title       = "Write file",
	description = "Create or overwrite a file in the project directory. Missing parent directories are created.",
	can_edit    = true,
	destructive = true,
	optional    = false,
	category    = .File,
	params      = FILE_WRITE_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = file_write_apply,
}

file_list_dir :: Tool_Desc{
	name        = "file_list_dir",
	title       = "List directory",
	description = "List a project directory (optionally recursive, gitignore-aware, with per-file line counts).",
	can_edit    = false,
	optional    = false,
	category    = .File,
	params      = FILE_LIST_DIR_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = file_list_dir_apply,
}

file_find :: Tool_Desc{
	name        = "file_find",
	title       = "Find files",
	description = "Find files by name mask; without a slash the mask matches basenames, with one the full relative path.",
	can_edit    = false,
	optional    = false,
	category    = .File,
	params      = FILE_FIND_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = file_find_apply,
}

file_read_outline :: Tool_Desc{
	name        = "file_read_outline",
	title       = "Outline structured file",
	description = "Read a JSON/JSONC/JSON5/YAML file structurally instead of grepping it: without path, an indented key tree with 0-based line numbers and value previews; with a jq-style path, the exact value(s) at that path with their line range. Line numbers feed file_read/file_replace ranges.",
	can_edit    = false,
	optional    = false,
	category    = .File,
	params      = FILE_READ_OUTLINE_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = file_read_outline_apply,
}

file_search :: Tool_Desc{
	name        = "file_search",
	title       = "Search for pattern",
	description = "Search the project for a regex pattern with per-match context lines and include/exclude path globs. Matches page in (path, line) order — resume or size a long answer with offset and limit.",
	can_edit    = false,
	optional    = false,
	category    = .File,
	params      = FILE_SEARCH_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = file_search_apply,
}

file_replace :: Tool_Desc{
	name        = "file_replace",
	title       = "Replace content",
	description = "Replace content in a file: literal or regex mode, single occurrence by default.",
	can_edit    = true,
	destructive = true,
	optional    = false,
	category    = .File,
	params      = FILE_REPLACE_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = file_replace_apply,
}

file_insert_lines :: Tool_Desc{
	name        = "file_insert_lines",
	title       = "Insert lines",
	description = "Insert content at a line index (0-based).",
	can_edit    = true,
	optional    = true,
	category    = .File,
	params      = FILE_INSERT_LINES_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = file_insert_lines_apply,
}

file_replace_lines :: Tool_Desc{
	name        = "file_replace_lines",
	title       = "Replace lines",
	description = "Replace an inclusive 0-based line range with new content.",
	can_edit    = true,
	destructive = true,
	optional    = true,
	category    = .File,
	params      = FILE_REPLACE_LINES_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = file_replace_lines_apply,
}

file_delete_lines :: Tool_Desc{
	name        = "file_delete_lines",
	title       = "Delete lines",
	description = "Delete an inclusive 0-based line range.",
	can_edit    = true,
	destructive = true,
	optional    = true,
	category    = .File,
	params      = FILE_DELETE_LINES_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = file_delete_lines_apply,
}

file_delete :: Tool_Desc{
	name        = "file_delete",
	title       = "Delete file",
	description = "Delete a file from the project directory.",
	can_edit    = true,
	destructive = true,
	optional    = false,
	category    = .File,
	params      = FILE_PATH_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = file_delete_apply,
}

file_move :: Tool_Desc{
	name        = "file_move",
	title       = "Move file",
	description = "Move or rename a file inside the project; the target must not exist.",
	can_edit    = true,
	destructive = true,
	optional    = false,
	category    = .File,
	params      = FILE_MOVE_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = file_move_apply,
}

// --- applies -----------------------------------------------------------------

file_read_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	rel := arg_str(args, "relative_path")
	start := arg_int(args, "start_line")
	end := arg_int(args, "end_line")
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	call := svc.client_file_read(ctx.svc_conn, rel, start, end, arg_has(args, "end_line"), max_chars, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	content, _ := json_str(call.result, "content")
	read_ask, _ := json_bool(call.result, "read_ask")
	truncated, _ := json_bool(call.result, "truncated")
	if truncated {
		// The daemon withheld the content at the gate; the notice carries
		// the full length it measured.
		total, _ := json_int(call.result, "total_chars")
		notice := fmt.aprintf(
			"The answer is too long (%d characters). You can adjust your query or raise the max_answer_chars parameter.",
			int(total),
			allocator = ctx.allocator,
		)
		if read_ask {
			notice = strings.concatenate({read_ask_prefix(rel, ctx.allocator), notice}, ctx.allocator)
		}
		return text_result(ctx, notice)
	}
	if read_ask {
		return text_result(ctx, strings.concatenate({read_ask_prefix(rel, ctx.allocator), content}, ctx.allocator))
	}
	return text_result(ctx, content)
}

read_ask_prefix :: proc(rel: string, a := context.allocator) -> string {
	return fmt.aprintf(
		"[WARNING: %s may contain sensitive information. Ask the user for confirmation before sharing its contents.]\n\n",
		rel,
		allocator = a,
	)
}

file_write_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_file_write(ctx.svc_conn, arg_str(args, "relative_path"), arg_str(args, "content"), ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	rel := arg_str(args, "relative_path")
	overwrote, _ := json_bool(call.result, "overwrote")
	if overwrote {
		return text_result(ctx, fmt.aprintf("File created: %s. Overwrote existing file.", rel, allocator = ctx.allocator))
	}
	return text_result(ctx, fmt.aprintf("File created: %s.", rel, allocator = ctx.allocator))
}

file_list_dir_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	call := svc.client_file_list_dir(
		ctx.svc_conn,
		arg_str(args, "relative_path"),
		arg_bool(args, "recursive"),
		arg_bool(args, "skip_ignored_files"),
		arg_bool(args, "include_line_counts"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	out := util.limit_length(to_json(call.result, ctx), max_chars, nil, ctx.allocator)
	return text_result(ctx, out)
}

file_find_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_file_find(ctx.svc_conn, arg_str(args, "file_mask"), arg_str(args, "relative_path"), ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	return text_result(ctx, to_json(call.result, ctx))
}

file_read_outline_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	rel := arg_str(args, "relative_path")
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	call := svc.client_file_outline(ctx.svc_conn, rel, arg_str(args, "path"), max_chars, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}

	content, _ := json_str(call.result, "content")
	read_ask, _ := json_bool(call.result, "read_ask")
	truncated, _ := json_bool(call.result, "truncated")

	// Extraction modes lead with the reached line range so the follow-up
	// read or edit cites it directly; the outline is its own header.
	text := content
	mode, _ := json_str(call.result, "mode")
	if mode == svc.file_outline_mode_string(.Value) {
		start, _ := json_int(call.result, "start_line")
		end, _ := json_int(call.result, "end_line")
		text = fmt.aprintf("(L%d-L%d)\n%s", start, end, content, allocator = ctx.allocator)
	}
	if truncated {
		text = strings.concatenate({
			text,
			"\n[truncated at max_answer_chars — raise the cap for the rest]",
		}, ctx.allocator)
	}
	if read_ask {
		text = strings.concatenate({read_ask_prefix(rel, ctx.allocator), text}, ctx.allocator)
	}
	return text_result(ctx, text)
}

file_search_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	// Range validation here mirrors the daemon's wire check so a bad value
	// fails fast at the call site instead of after a project walk.
	offset := arg_int(args, "offset")
	if offset < 0 {
		return err_result(ctx, "offset must be non-negative")
	}
	limit := arg_int(args, "limit")
	if limit < 0 {
		return err_result(ctx, "limit must be non-negative")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	req: svc.File_Search_Req
	req.pattern = arg_str(args, "substring_pattern")
	req.multiline = arg_bool(args, "multiline")
	req.context_before = arg_int(args, "context_lines_before")
	req.context_after = arg_int(args, "context_lines_after")
	req.include_glob = arg_str(args, "paths_include_glob")
	req.exclude_glob = arg_str(args, "paths_exclude_glob")
	req.scope_rel = arg_str(args, "relative_path")
	req.offset = offset
	req.limit = limit
	call := svc.client_file_search(ctx.svc_conn, req, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}

	returned := 0
	if matches_v, ok := jsonutil.obj_get(call.result, "matches"); ok {
		if arr, aok := jsonutil.as_array(matches_v); aok {
			returned = len(arr)
		}
	}
	walk_truncated, _ := json_bool(call.result, "truncated")
	total64, _ := json_int(call.result, "total_matches")
	footer := search_footer(offset, returned, int(total64), walk_truncated, ctx.allocator)

	// Reference rendering: a JSON object mapping each file to its match
	// display blocks; the shortened forms rank matches down to counts.
	grouped := search_group_json(call.result, ctx)
	full := to_json(grouped, ctx)
	if max_chars <= 0 || len(full) <= max_chars {
		if footer != "" {
			full = strings.concatenate({full, "\n", footer}, ctx.allocator)
		}
		return text_result(ctx, full)
	}
	shortened := []string{
		strings.concatenate({"Match counts per file:\n", to_json(counts_by_path_json(call.result, "matches", "path", ctx), ctx)}, ctx.allocator),
	}
	capped := util.limit_length(full, max_chars, shortened, ctx.allocator)
	if footer != "" {
		capped = strings.concatenate({capped, "\n", footer}, ctx.allocator)
	}
	return text_result(ctx, capped)
}

// search_footer renders the notes appended under the match JSON: the
// resume line names the next offset whenever more matches remain past
// this page, and the walk-cap warning says the scan itself stopped early
// (its results are incomplete, not merely unpaged). Empty when the
// answer carries neither caveat.
search_footer :: proc(offset, returned, total: int, walk_truncated: bool, a := context.allocator) -> string {
	out := ""
	if walk_truncated {
		out = "[walk caps hit — the scan stopped early; results are incomplete]"
	}
	if offset+returned < total {
		line := strings.concatenate({
			"[showing matches ",
			util.int_to_dec(offset+1, a), "-", util.int_to_dec(offset+returned, a),
			" of ", util.int_to_dec(total, a),
			" — pass offset=", util.int_to_dec(offset+returned, a),
			" for the next page]",
		}, a)
		if out != "" {
			out = strings.concatenate({out, "\n", line}, a)
		} else {
			out = line
		}
	}
	if returned == 0 && total > 0 && offset >= total {
		line := strings.concatenate({
			"[no matches at or past offset ",
			util.int_to_dec(offset, a), " (total ", util.int_to_dec(total, a), ")]",
		}, a)
		if out != "" {
			out = strings.concatenate({out, "\n", line}, a)
		} else {
			out = line
		}
	}
	return out
}

// search_group_json groups the wire matches by path (the to_json render
// sorts the file keys; each file's match order is the walk's).
search_group_json :: proc(result: json.Value, ctx: ^Tool_Ctx) -> json.Value {
	out := jsonutil.json_object(0, ctx.allocator)
	matches_v, ok := jsonutil.obj_get(result, "matches")
	if !ok {
		return json.Value(json.Object(out))
	}
	matches, _ := jsonutil.as_array(matches_v)

	paths := make([dynamic]string, 0, 8, ctx.allocator)
	displays := make(map[string][dynamic]json.Value, 8, ctx.allocator)
	for m in matches {
		path, _ := json_str(m, "path")
		display, _ := json_str(m, "display")
		if _, seen := displays[path]; !seen {
			append(&paths, path)
			displays[path] = make([dynamic]json.Value, 0, 4, ctx.allocator)
		}
		append(&displays[path], jsonutil.json_string(display))
	}
	for p in paths {
		jsonutil.obj_set(&out, p, jsonutil.json_array(displays[p][:], ctx.allocator))
	}
	return json.Value(json.Object(out))
}

file_replace_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_file_replace(
		ctx.svc_conn,
		arg_str(args, "relative_path"),
		arg_str(args, "needle"),
		arg_str(args, "repl"),
		arg_str(args, "mode"),
		arg_bool(args, "allow_multiple_occurrences"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_ok_or_err(ctx, call)
}

file_insert_lines_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_file_insert_lines(
		ctx.svc_conn,
		arg_str(args, "relative_path"),
		arg_int(args, "line"),
		arg_str(args, "content"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_ok_or_err(ctx, call)
}

file_replace_lines_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_file_replace_lines(
		ctx.svc_conn,
		arg_str(args, "relative_path"),
		arg_int(args, "start_line"),
		arg_int(args, "end_line"),
		arg_str(args, "content"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_ok_or_err(ctx, call)
}

file_delete_lines_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_file_delete_lines(
		ctx.svc_conn,
		arg_str(args, "relative_path"),
		arg_int(args, "start_line"),
		arg_int(args, "end_line"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_ok_or_err(ctx, call)
}

file_delete_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_file_delete(ctx.svc_conn, arg_str(args, "relative_path"), ctx.allocator, svc_deadline(ctx), ctx.cancel)
	return call_ok_or_err(ctx, call)
}

file_move_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_file_move(
		ctx.svc_conn,
		arg_str(args, "source_relative_path"),
		arg_str(args, "target_relative_path"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_ok_or_err(ctx, call)
}

// call_ok_or_err answers mutating ops: an empty-object reply is the
// reference's "OK".
call_ok_or_err :: proc(ctx: ^Tool_Ctx, call: svc.Client_Call) -> Tool_Result {
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	return ok_result(ctx)
}

// json_str / json_bool / json_int read typed members off a wire result.
json_str :: proc(v: json.Value, key: string) -> (string, bool) {
	if f, ok := jsonutil.obj_get(v, key); ok {
		return jsonutil.value_str(f), true
	}
	return "", false
}

json_bool :: proc(v: json.Value, key: string) -> (bool, bool) {
	if f, ok := jsonutil.obj_get(v, key); ok {
		#partial switch x in f {
		case json.Boolean:
			return bool(x), true
		case:
		}
	}
	return false, false
}

json_int :: proc(v: json.Value, key: string) -> (i64, bool) {
	if f, ok := jsonutil.obj_get(v, key); ok {
		#partial switch x in f {
		case json.Integer:
			return i64(x), true
		case:
		}
	}
	return 0, false
}
