// The symbol tool family: outline listing, index search, and the seven
// symbol-level edit operations, all over the svc.symbol/* proxies. Edit
// answers are fixed strings; reads render JSON grouped by kind (flat,
// kind-sorted).
package tools

import "core:encoding/json"
import "core:fmt"
import "core:sort"
import "core:strings"
import "src:editor"
import "src:jsonutil"
import "src:svc"
import "src:util"

SYMBOL_LIST_PARAMS :: []Param_Desc{
	{name = "relative_path", kind = .Str, description = "Project-relative source file.", required = true},
	{name = "max_answer_chars", kind = .Int, description = "Answer length cap (-1 = session default).", required = false},
}

SYMBOL_FIND_PARAMS :: []Param_Desc{
	{name = "name_path_pattern", kind = .Str, description = "Name path: \"foo\", \"Foo/bar\", or \"/Foo/bar\" (deeper chains allowed). Exact match (case-insensitive) unless a segment contains '*' (glob: mono_*, *_cache). Leading '/' anchors at the root.", required = true},
	{name = "offset", kind = .Int, description = "Skip the first N matches (0-based; match order is by path, then line). Pass the previous answer's end index to resume a truncated answer.", required = false},
	{name = "limit", kind = .Int, description = "Maximum matches to return per answer. 0 or absent = all.", required = false},
	{name = "max_answer_chars", kind = .Int, description = "Answer length cap (-1 = session default).", required = false},
}

SYMBOL_FIND_DEAD_CODE_PARAMS :: []Param_Desc{
	{name = "path_prefix", kind = .Str, description = "Report only candidates under this project-relative directory. Definitions and uses are always scanned project-wide.", required = false},
	{name = "entry_prefixes", kind = .Str_Array, description = "Name prefixes treated as entry points invoked by convention (case-sensitive), e.g. [\"test_\", \"Test\"]; replaces the scan's default entry-prefix set.", required = false},
	{name = "limit", kind = .Int, description = "Maximum candidates to report; omitted uses the scan's default limit and the value is capped by its hard maximum. Stats stay whole-population.", required = false},
	{name = "max_answer_chars", kind = .Int, description = "Answer length cap (-1 = session default).", required = false},
}

SYMBOL_EDIT_PARAMS :: []Param_Desc{
	{name = "name_path", kind = .Str, description = "Symbol name path.", required = true},
	{name = "relative_path", kind = .Str, description = "Project-relative source file.", required = true},
	{name = "body", kind = .Str, description = "Replacement definition text.", required = true},
}

SYMBOL_MOVE_MODES :: editor.MOVE_MODE_NAMES

SYMBOL_MOVE_PARAMS :: []Param_Desc{
	{name = "name_path", kind = .Str, description = "Symbol name path.", required = true},
	{name = "source_relative_path", kind = .Str, description = "File the symbol lives in.", required = true},
	{name = "target_relative_path", kind = .Str, description = "File to move it to.", required = true},
	{name = "target_position", kind = .Str, description = "\"end\" or a name path in the target file.", required = true},
	{name = "mode", kind = .Str, description = "move (default) or copy.", required = false, enum_vals = SYMBOL_MOVE_MODES},
}

SYMBOL_DOCSTRING_PARAMS :: []Param_Desc{
	{name = "name_path", kind = .Str, description = "Symbol name path.", required = true},
	{name = "relative_path", kind = .Str, description = "Project-relative source file.", required = true},
	{name = "comment", kind = .Str, description = "Comment block text (empty in replace = delete only).", required = true},
}

SYMBOL_DOCSTRING_ONLY_PARAMS :: []Param_Desc{
	{name = "name_path", kind = .Str, description = "Symbol name path.", required = true},
	{name = "relative_path", kind = .Str, description = "Project-relative source file.", required = true},
}

SYMBOL_FIND_REFERENCES_PARAMS :: []Param_Desc{
	{name = "name_path", kind = .Str, description = "Symbol name path.", required = true},
	{name = "relative_path", kind = .Str, description = "Project-relative source file.", required = true},
	{name = "include_imports", kind = .Bool, description = "Include import statements referencing the symbol.", required = false},
	{name = "include_self", kind = .Bool, description = "Include the symbol's own declaration sites.", required = false},
	{name = "include_file_symbols", kind = .Bool, description = "Include references no symbol contains (as file entries).", required = false},
	{name = "include_kinds", kind = .Int_Array, description = "Only include these symbol kinds (LSP SymbolKind numbers).", required = false},
	{name = "exclude_kinds", kind = .Int_Array, description = "Exclude these symbol kinds (LSP SymbolKind numbers).", required = false},
	{name = "max_answer_chars", kind = .Int, description = "Answer length cap (-1 = session default).", required = false},
}

SYMBOL_FIND_IMPLEMENTATIONS_PARAMS :: []Param_Desc{
	{name = "name_path", kind = .Str, description = "Symbol name path.", required = true},
	{name = "relative_path", kind = .Str, description = "Project-relative source file.", required = true},
	{name = "include_body", kind = .Bool, description = "Include each implementation's body text.", required = false},
	{name = "include_info", kind = .Bool, description = "Include hover/docstring info per implementation.", required = false},
	{name = "include_kinds", kind = .Int_Array, description = "Only include these symbol kinds (LSP SymbolKind numbers).", required = false},
	{name = "exclude_kinds", kind = .Int_Array, description = "Exclude these symbol kinds (LSP SymbolKind numbers).", required = false},
	{name = "max_answer_chars", kind = .Int, description = "Answer length cap (-1 = session default).", required = false},
}

SYMBOL_FIND_DECLARATION_PARAMS :: []Param_Desc{
	{name = "name_path", kind = .Str, description = "Symbol name path.", required = true},
	{name = "relative_path", kind = .Str, description = "Project-relative source file.", required = true},
	{name = "max_answer_chars", kind = .Int, description = "Answer length cap (-1 = session default).", required = false},
}

SYMBOL_RENAME_PARAMS :: []Param_Desc{
	{name = "name_path", kind = .Str, description = "Symbol name path.", required = true},
	{name = "relative_path", kind = .Str, description = "Project-relative source file.", required = true},
	{name = "new_name", kind = .Str, description = "New name for the symbol.", required = true},
}

SYMBOL_DELETE_PARAMS :: []Param_Desc{
	{name = "name_path_pattern", kind = .Str, description = "Symbol name path.", required = true},
	{name = "relative_path", kind = .Str, description = "Project-relative source file.", required = true},
	{name = "include_comments", kind = .Bool, description = "Also delete the preceding docstring/comment block.", required = false},
}

symbol_list :: Tool_Desc{
	name        = "symbol_list",
	title       = "List symbols",
	description = "List the symbol tree of one source file (kinds, nesting, locations).",
	can_edit    = false,
	optional    = false,
	category    = .Symbol,
	params      = SYMBOL_LIST_PARAMS,
	needs       = {Cap.Project, Cap.Svc},
	apply       = symbol_list_apply,
}

symbol_find :: Tool_Desc{
	name        = "symbol_find",
	title       = "Find symbol",
	description = "Find symbols across the project index by name: exact match by default (case-insensitive); a '*' in the name path turns it into a glob (mono_*, *_cache) for discovery. \"Foo/bar\" matches child segments at any depth, a leading '/' anchors at the root. Answers are grouped and sorted by kind; long ones page in (path, line) order via offset and limit.",
	can_edit    = false,
	optional    = false,
	category    = .Symbol,
	params      = SYMBOL_FIND_PARAMS,
	needs       = {Cap.Project, Cap.Svc},
	apply       = symbol_find_apply,
}

symbol_find_dead_code :: Tool_Desc{
	name        = "symbol_find_dead_code",
	title       = "Find dead code candidates",
	description = "Report definitions that are almost surely dead: a whole-project scan counts every textual occurrence of each definition name (comments, strings, prose included), and a candidate is a name that never occurs outside its own declaration spans. Convention-invoked names are excluded (attributes/decorators directly above a definition, and configurable entry prefixes, default [\"test_\", \"Test\", \"main\"]). Candidates are reports for review, not verdicts — \"dead\" means unused inside this project; external consumers are invisible. Misses are possible (same-name definitions keep each other alive), false positives are limited to convention calls the exclusions do not cover.",
	can_edit    = false,
	optional    = false,
	category    = .Symbol,
	params      = SYMBOL_FIND_DEAD_CODE_PARAMS,
	needs       = {Cap.Project, Cap.Svc},
	apply       = symbol_find_dead_code_apply,
}

symbol_replace_body :: Tool_Desc{
	name        = "symbol_replace_body",
	title       = "Replace symbol body",
	description = "Replace the full definition of a symbol with new text, re-indenting under the definition's indent.",
	can_edit    = true,
	destructive = true,
	optional    = false,
	category    = .Symbol,
	params      = SYMBOL_EDIT_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = symbol_replace_body_apply,
}

symbol_insert_before :: Tool_Desc{
	name        = "symbol_insert_before",
	title       = "Insert before symbol",
	description = "Insert content directly above a symbol definition, keeping neighbour separation.",
	can_edit    = true,
	optional    = false,
	category    = .Symbol,
	params      = SYMBOL_EDIT_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = symbol_insert_before_apply,
}

symbol_insert_after :: Tool_Desc{
	name        = "symbol_insert_after",
	title       = "Insert after symbol",
	description = "Insert content directly below a symbol definition, keeping neighbour separation.",
	can_edit    = true,
	optional    = false,
	category    = .Symbol,
	params      = SYMBOL_EDIT_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = symbol_insert_after_apply,
}

symbol_move :: Tool_Desc{
	name        = "symbol_move",
	title       = "Move symbol",
	description = "Move or copy a leaf symbol (with its docstring) between files or within one file.",
	can_edit    = true,
	destructive = true,
	optional    = false,
	category    = .Symbol,
	params      = SYMBOL_MOVE_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = symbol_move_apply,
}

symbol_insert_docstring :: Tool_Desc{
	name        = "symbol_insert_docstring",
	title       = "Insert docstring",
	description = "Insert a docstring or comment block immediately above a symbol definition.",
	can_edit    = true,
	optional    = false,
	category    = .Symbol,
	params      = SYMBOL_DOCSTRING_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = symbol_insert_docstring_apply,
}

symbol_delete_docstring :: Tool_Desc{
	name        = "symbol_delete_docstring",
	title       = "Delete docstring",
	description = "Remove the docstring or comment block immediately preceding a symbol definition.",
	can_edit    = true,
	destructive = true,
	optional    = false,
	category    = .Symbol,
	params      = SYMBOL_DOCSTRING_ONLY_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = symbol_delete_docstring_apply,
}

symbol_replace_docstring :: Tool_Desc{
	name        = "symbol_replace_docstring",
	title       = "Replace docstring",
	description = "Replace the docstring preceding a symbol; an empty comment deletes without replacement.",
	can_edit    = true,
	destructive = true,
	optional    = false,
	category    = .Symbol,
	params      = SYMBOL_DOCSTRING_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = symbol_replace_docstring_apply,
}

symbol_find_references :: Tool_Desc{
	name        = "symbol_find_references",
	title       = "Find referencing symbols",
	description = "Find the symbols that reference the given symbol, using the file's language server.",
	can_edit    = false,
	optional    = false,
	category    = .Symbol,
	params      = SYMBOL_FIND_REFERENCES_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = symbol_find_references_apply,
}

symbol_find_implementations :: Tool_Desc{
	name        = "symbol_find_implementations",
	title       = "Find implementations",
	description = "Find implementations of the symbol at the given name path (interface implementations, method overrides).",
	can_edit    = false,
	optional    = false,
	category    = .Symbol,
	params      = SYMBOL_FIND_IMPLEMENTATIONS_PARAMS,
	needs       = {Cap.Project, Cap.Svc},
	apply       = symbol_find_implementations_apply,
}

symbol_find_declaration :: Tool_Desc{
	name        = "symbol_find_declaration",
	title       = "Find declaration",
	description = "Find the declaration or definition of a symbol. A name path is a path in the symbol tree within a source file; e.g. the method my_method defined in class MyClass has the name path MyClass/my_method.",
	can_edit    = false,
	optional    = false,
	category    = .Symbol,
	params      = SYMBOL_FIND_DECLARATION_PARAMS,
	needs       = {Cap.Project, Cap.Svc},
	apply       = symbol_find_declaration_apply,
}

symbol_rename :: Tool_Desc{
	name        = "symbol_rename",
	title       = "Rename symbol",
	description = "Rename a symbol throughout the codebase using language server refactoring capabilities.",
	can_edit    = true,
	destructive = true, // rewrites existing content across many files
	optional    = false,
	category    = .Symbol,
	params      = SYMBOL_RENAME_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = symbol_rename_apply,
}

symbol_delete :: Tool_Desc{
	name        = "symbol_delete",
	title       = "Delete symbol (references-checked)",
	description = "Delete the symbol when nothing references it, or answer with the reference sites that block the deletion. Set include_comments to also delete the preceding docstring and comment block.",
	can_edit    = true,
	destructive = true,
	optional    = false,
	category    = .Symbol,
	params      = SYMBOL_DELETE_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = symbol_delete_apply,
}

// --- applies -----------------------------------------------------------------

symbol_list_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	call := svc.client_symbol_list(ctx.svc_conn, arg_str(args, "relative_path"), ctx.allocator, svc_deadline(ctx), ctx.cancel)
	shortened := []string{
		strings.concatenate({"Symbol counts by kind:\n", to_json(symbol_kind_counts(call.result, ctx), ctx)}, ctx.allocator),
	}
	return call_text_result(ctx, call, max_chars, shortened)
}

// symbol_kind_counts aggregates the wire symbol tree by kind for the
// shortened answer (kind "unknown" when the tree is empty).
symbol_kind_counts :: proc(result: json.Value, ctx: ^Tool_Ctx) -> json.Value {
	out := jsonutil.json_object(0, ctx.allocator)
	symbols_v, ok := jsonutil.obj_get(result, "symbols")
	if !ok {
		jsonutil.obj_set(&out, "unknown", jsonutil.json_int(0))
		return json.Value(json.Object(out))
	}
	symbols, _ := jsonutil.as_array(symbols_v)
	counts := make(map[string]int, 8, ctx.allocator)
	kinds := make([dynamic]string, 0, 8, ctx.allocator)
	count_symbol_kinds(symbols, &counts, &kinds)
	if len(kinds) == 0 {
		jsonutil.obj_set(&out, "unknown", jsonutil.json_int(0))
		return json.Value(json.Object(out))
	}
	for k in kinds {
		jsonutil.obj_set(&out, k, jsonutil.json_int(i64(counts[k])))
	}
	return json.Value(json.Object(out))
}

count_symbol_kinds :: proc(symbols: []json.Value, counts: ^map[string]int, kinds: ^[dynamic]string) {
	for s in symbols {
		kind, _ := json_str(s, "kind")
		if kind == "" {
			kind = "unknown"
		}
		if _, seen := counts^[kind]; !seen {
			append(kinds, kind)
		}
		counts^[kind] = counts^[kind] + 1
		if children_v, ok := jsonutil.obj_get(s, "children"); ok {
			if children, aok := jsonutil.as_array(children_v); aok {
				count_symbol_kinds(children, counts, kinds)
			}
		}
	}
}

symbol_find_dead_code_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	// Range validation here mirrors the daemon's wire check so a bad limit
	// fails fast at the call site instead of after a project walk.
	limit := 0
	if arg_has(args, "limit") {
		limit = arg_int(args, "limit")
		if limit <= 0 || limit > svc.DEAD_SCAN_MAX_LIMIT {
			return err_result(ctx, fmt.aprintf(
				"limit must be between 1 and %v", svc.DEAD_SCAN_MAX_LIMIT,
				allocator = ctx.allocator,
			))
		}
	}
	call := svc.client_symbol_find_dead_code(ctx.svc_conn, arg_str(args, "path_prefix"), tracker_arg_str_array(args, "entry_prefixes", ctx.allocator), limit, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	shortened := []string{
		strings.concatenate({"Shortened result:\n", to_json(names_by_path_json(call.result, "candidates", "path", []string{"name_path", "name"}, ctx), ctx)}, ctx.allocator),
	}
	return call_text_result(ctx, call, max_chars, shortened)
}

// names_by_path_json groups an answer's entries by file for the shortened
// answer: {relative path: name paths}. list_key picks the entries array,
// path_key the entry's file field, and name_keys are tried in order — the
// first non-empty one wins (dead-scan candidates carry name_path with a
// bare-name fallback, find matches just name).
names_by_path_json :: proc(result: json.Value, list_key: string, path_key: string, name_keys: []string, ctx: ^Tool_Ctx) -> json.Value {
	out := jsonutil.json_object(0, ctx.allocator)
	list_v, ok := jsonutil.obj_get(result, list_key)
	if !ok {
		return json.Value(json.Object(out))
	}
	entries, _ := jsonutil.as_array(list_v)
	paths := make([dynamic]string, 0, 8, ctx.allocator)
	names := make(map[string][dynamic]string, 8, ctx.allocator)
	for m in entries {
		path, _ := json_str(m, path_key)
		if path == "" {
			path = "unknown"
		}
		name := ""
		for key in name_keys {
			cand, _ := json_str(m, key)
			if cand != "" {
				name = cand
				break
			}
		}
		if _, seen := names[path]; !seen {
			append(&paths, path)
			names[path] = make([dynamic]string, 0, 4, ctx.allocator)
		}
		append(&names[path], name)
	}
	for p in paths {
		items := make([]json.Value, len(names[p]), ctx.allocator)
		for i in 0..<len(names[p]) {
			items[i] = jsonutil.json_string(names[p][i])
		}
		jsonutil.obj_set(&out, p, jsonutil.json_array(items, ctx.allocator))
	}
	return json.Value(json.Object(out))
}

symbol_find_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	// Range validation here mirrors the daemon-side wire checks elsewhere
	// so a bad value fails fast at the call site.
	offset := arg_int(args, "offset")
	if offset < 0 {
		return err_result(ctx, "offset must be non-negative")
	}
	limit := arg_int(args, "limit")
	if limit < 0 {
		return err_result(ctx, "limit must be non-negative")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	call := svc.client_symbol_find(ctx.svc_conn, arg_str(args, "name_path_pattern"), ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}

	// Paging is presentation-side: the index read is cheap and the wire
	// unchanged, so the page is cut here. The slice runs over a
	// (path, line) sorted copy — the same pattern with the same offset
	// always pages the same sequence — and without either param the raw
	// wire order renders unchanged.
	total := 0
	page: []json.Value
	if matches_v, ok := jsonutil.obj_get(call.result, "matches"); ok {
		if arr, aok := jsonutil.as_array(matches_v); aok {
			total = len(arr)
			page = symbol_page_slice(arr, offset, limit, ctx)
		}
	}
	paged := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&paged, "matches", jsonutil.json_array(page, ctx.allocator))
	paged_value := json.Value(json.Object(paged))

	shortened := []string{
		strings.concatenate({"Shortened result:\n", to_json(names_by_path_json(paged_value, "matches", "path", []string{"name"}, ctx), ctx)}, ctx.allocator),
	}
	body := util.limit_length(to_json(paged_value, ctx), max_chars, shortened, ctx.allocator)
	if offset+len(page) < total {
		footer := strings.concatenate({
			"[showing symbols ",
			util.int_to_dec(offset+1, ctx.allocator), "-", util.int_to_dec(offset+len(page), ctx.allocator),
			" of ", util.int_to_dec(total, ctx.allocator),
			" — pass offset=", util.int_to_dec(offset+len(page), ctx.allocator),
			" for the next page]",
		}, ctx.allocator)
		body = strings.concatenate({body, "\n", footer}, ctx.allocator)
	}
	return text_result(ctx, body)
}

// Symbol_Page_Entry pairs one wire match with its sort key; the page
// slice is cut over the (path, line) order so paging stays deterministic
// across calls.
Symbol_Page_Entry :: struct {
	path: string,
	line: i64,
	v:    json.Value,
}

Sorted_Symbol_Page :: struct {
	items: [dynamic]Symbol_Page_Entry,
}

sp_len :: proc(it: sort.Interface) -> int {
	sp := cast(^Sorted_Symbol_Page)it.collection
	return len(sp.items)
}

sp_less :: proc(it: sort.Interface, i, j: int) -> bool {
	sp := cast(^Sorted_Symbol_Page)it.collection
	a, b := sp.items[i], sp.items[j]
	if a.path != b.path {
		return a.path < b.path
	}
	return a.line < b.line
}

sp_swap :: proc(it: sort.Interface, i, j: int) {
	sp := cast(^Sorted_Symbol_Page)it.collection
	sp.items[i], sp.items[j] = sp.items[j], sp.items[i]
}

// symbol_page_slice returns matches[offset:offset+limit] over the
// (path, line) sorted copy; the returned entries borrow the wire values
// (no clones). Without either paging param the input renders unchanged.
symbol_page_slice :: proc(matches: []json.Value, offset, limit: int, ctx: ^Tool_Ctx) -> []json.Value {
	if offset == 0 && limit <= 0 {
		return matches
	}
	entries := make([dynamic]Symbol_Page_Entry, 0, len(matches), ctx.allocator)
	for m in matches {
		e: Symbol_Page_Entry
		e.path, _ = json_str(m, "path")
		e.line, _ = json_int(m, "line")
		e.v = m
		append(&entries, e)
	}
	sc := Sorted_Symbol_Page{items = entries}
	if len(entries) > 1 {
		sort.sort({len = sp_len, less = sp_less, swap = sp_swap, collection = &sc})
	}
	from := offset
	if from > len(matches) {
		from = len(matches)
	}
	to := len(matches)
	if limit > 0 && from+limit < to {
		to = from + limit
	}
	page := make([]json.Value, to-from, ctx.allocator)
	for i := from; i < to; i += 1 {
		page[i-from] = entries[i].v
	}
	return page
}

symbol_replace_body_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_symbol_replace_body(
		ctx.svc_conn, arg_str(args, "name_path"), arg_str(args, "relative_path"), arg_str(args, "body"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_ok_or_err(ctx, call)
}

symbol_insert_before_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_symbol_insert_before(
		ctx.svc_conn, arg_str(args, "name_path"), arg_str(args, "relative_path"), arg_str(args, "body"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_ok_or_err(ctx, call)
}

symbol_insert_after_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_symbol_insert_after(
		ctx.svc_conn, arg_str(args, "name_path"), arg_str(args, "relative_path"), arg_str(args, "body"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_ok_or_err(ctx, call)
}

symbol_move_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	position := arg_str(args, "target_position")
	if position == "" {
		return err_result(ctx, "target_position is required: use \"end\" to append at EOF or a symbol name_path to insert after")
	}
	call := svc.client_symbol_move(
		ctx.svc_conn,
		arg_str(args, "name_path"),
		arg_str(args, "source_relative_path"),
		arg_str(args, "target_relative_path"),
		position,
		arg_str(args, "mode"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	summary, _ := json_str(call.result, "summary")
	return text_result(ctx, summary)
}

symbol_insert_docstring_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_symbol_insert_docstring(
		ctx.svc_conn, arg_str(args, "name_path"), arg_str(args, "relative_path"), arg_str(args, "comment"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_ok_or_err(ctx, call)
}

symbol_delete_docstring_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_symbol_delete_docstring(
		ctx.svc_conn, arg_str(args, "name_path"), arg_str(args, "relative_path"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_ok_or_err(ctx, call)
}

symbol_replace_docstring_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_symbol_replace_docstring(
		ctx.svc_conn, arg_str(args, "name_path"), arg_str(args, "relative_path"), arg_str(args, "comment"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_ok_or_err(ctx, call)
}

symbol_find_references_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	call := svc.client_symbol_find_references(
		ctx.svc_conn, arg_str(args, "name_path"), arg_str(args, "relative_path"),
		arg_bool(args, "include_imports"), arg_bool(args, "include_self"), arg_bool(args, "include_file_symbols"),
		arg_u32_array(args, "include_kinds", ctx.allocator), arg_u32_array(args, "exclude_kinds", ctx.allocator),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	shortened := []string{
		strings.concatenate({"References without surrounding lines:\n", to_json(refs_without_context(call.result, ctx), ctx)}, ctx.allocator),
		strings.concatenate({"Reference counts per file:\n", to_json(counts_by_path_json(call.result, "items", "relative_path", ctx), ctx)}, ctx.allocator),
		strings.concatenate({"Found ", util.int_to_dec(items_count(call.result), context.temp_allocator), " references."}, ctx.allocator),
	}
	return call_text_result(ctx, call, max_chars, shortened)
}

// items_count is the items array length of an svc answer (0 when absent).
items_count :: proc(result: json.Value) -> int {
	items_v, ok := jsonutil.obj_get(result, "items")
	if !ok {
		return 0
	}
	items, _ := jsonutil.as_array(items_v)
	return len(items)
}

// refs_without_context keeps the locating fields of every reference entry
// for the shortened answer.
refs_without_context :: proc(result: json.Value, ctx: ^Tool_Ctx) -> json.Value {
	out := jsonutil.json_array(nil, ctx.allocator)
	items_v, ok := jsonutil.obj_get(result, "items")
	if !ok {
		return out
	}
	items, _ := jsonutil.as_array(items_v)
	kept := make([dynamic]json.Value, 0, len(items), ctx.allocator)
	keep_keys := []string{"name_path", "kind", "relative_path", "reference_line"}
	for m in items {
		entry := jsonutil.json_object(4, ctx.allocator)
		for key in keep_keys {
			if v, kok := jsonutil.obj_get(m, key); kok {
				jsonutil.obj_set(&entry, key, v)
			}
		}
		append(&kept, json.Value(json.Object(entry)))
	}
	return jsonutil.json_array(kept[:], ctx.allocator)
}

symbol_find_implementations_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	call := svc.client_symbol_find_implementations(
		ctx.svc_conn, arg_str(args, "name_path"), arg_str(args, "relative_path"),
		arg_bool(args, "include_body"), arg_bool(args, "include_info"),
		arg_u32_array(args, "include_kinds", ctx.allocator), arg_u32_array(args, "exclude_kinds", ctx.allocator),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	shortened := []string{
		strings.concatenate({"Shortened result:\n", to_json(names_by_path_json(call.result, "items", "relative_path", []string{"name_path"}, ctx), ctx)}, ctx.allocator),
	}
	return call_text_result(ctx, call, max_chars, shortened)
}

symbol_find_declaration_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	call := svc.client_symbol_find_declaration(
		ctx.svc_conn, arg_str(args, "name_path"), arg_str(args, "relative_path"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_text_result(ctx, call, max_chars, nil)
}

symbol_rename_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_symbol_rename(
		ctx.svc_conn, arg_str(args, "name_path"), arg_str(args, "relative_path"), arg_str(args, "new_name"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	summary, _ := json_str(call.result, "summary")
	return text_result(ctx, summary)
}

symbol_delete_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_symbol_delete(
		ctx.svc_conn, arg_str(args, "name_path_pattern"), arg_str(args, "relative_path"),
		arg_bool(args, "include_comments"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	if refusal, ok := json_str(call.result, "refusal"); ok && refusal != "" {
		return text_result(ctx, refusal)
	}
	return ok_result(ctx)
}
