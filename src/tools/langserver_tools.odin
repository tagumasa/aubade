// The langserver tool family over svc.langserver/*: management
// (start/stop/restart/reload) and the read-only queries (list,
// diagnostics, code actions, formatting, inlay hints, call hierarchy).
// Only the management half is optional by default — a config layer
// includes it explicitly; the queries stay visible so an unconfigured
// project still surfaces the family's setup guidance. The family never
// edits files: formatting returns edits without applying them.
package tools

import "src:util"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "src:jsonrpc"
import "src:jsonutil"
import "src:lsp"
import "src:platform"
import "src:svc"

// Param lists are per-tool inline literals (the pattern the rest of the
// table uses); enum_vals ride along as named constants.

LANGSERVER_DIRECTIONS :: lsp.CALL_DIRECTION_NAMES

LANGSERVER_START_PARAMS :: []Param_Desc{
	{name = "language", kind = .Str, description = "Language id the registry knows (e.g. go, python, odin, typescript).", required = true},
}

LANGSERVER_STOP_PARAMS :: []Param_Desc{
	{name = "language", kind = .Str, description = "Language id the registry knows (e.g. go, python, odin, typescript).", required = true},
}

LANGSERVER_RESTART_PARAMS :: []Param_Desc{
	{name = "language", kind = .Str, description = "Language id to restart (omit to reset every server).", required = false},
}

LANGSERVER_GET_DIAGNOSTICS_PARAMS :: []Param_Desc{
	{name = "relative_path", kind = .Str, description = "File path relative to the project root.", required = true},
	{name = "max_answer_chars", kind = .Int, description = "Answer length cap (-1 = session default).", required = false},
}

// LANGSERVER_RANGE_PARAMS is the shared parameter table of the two
// range-scoped tools (code actions, inlay hints): one file plus the
// 0-based inclusive range.
LANGSERVER_RANGE_PARAMS :: []Param_Desc{
	{name = "relative_path", kind = .Str, description = "File path relative to the project root.", required = true},
	{name = "start_line", kind = .Int, description = "Range start line (0-based).", required = true},
	{name = "start_col", kind = .Int, description = "Range start column (0-based).", required = true},
	{name = "end_line", kind = .Int, description = "Range end line (0-based).", required = true},
	{name = "end_col", kind = .Int, description = "Range end column (0-based).", required = true},
	{name = "max_answer_chars", kind = .Int, description = "Answer length cap (-1 = session default).", required = false},
}

LANGSERVER_GET_CODE_ACTIONS_PARAMS :: LANGSERVER_RANGE_PARAMS

LANGSERVER_FORMAT_PARAMS :: []Param_Desc{
	{name = "relative_path", kind = .Str, description = "File path relative to the project root.", required = true},
	{name = "tab_size", kind = .Int, description = "Tab width (default 4).", required = false},
	{name = "insert_spaces", kind = .Bool, description = "Insert spaces instead of tabs (default true).", required = false},
	{name = "max_answer_chars", kind = .Int, description = "Answer length cap (-1 = session default).", required = false},
}

LANGSERVER_GET_INLAY_HINTS_PARAMS :: LANGSERVER_RANGE_PARAMS

LANGSERVER_FIND_CALLS_PARAMS :: []Param_Desc{
	{name = "relative_path", kind = .Str, description = "File path relative to the project root.", required = true},
	{name = "line", kind = .Int, description = "Symbol position line (0-based).", required = true},
	{name = "col", kind = .Int, description = "Symbol position column (0-based).", required = true},
	{name = "direction", kind = .Str, description = "Call direction.", required = true, enum_vals = LANGSERVER_DIRECTIONS},
	{name = "max_answer_chars", kind = .Int, description = "Answer length cap (-1 = session default).", required = false},
}

langserver_start :: Tool_Desc{
	name        = "langserver_start",
	title       = "Start language server",
	description = "Start the language server for one language. The server keeps running until stopped or idle for 10 minutes. " +
		"When the server is not installed the refusal carries install guidance: installing is your job, but ask the user for consent first, then start again. " +
		"A server at a custom path is pinned through the language_server_commands key of .aubade/project.jsonc, applied with langserver_reload.",
	can_edit    = true, // mutates daemon state (server processes) — read_only sessions strip it, matching the daemon's own guard
	optional    = true,
	category    = .Langserver,
	params      = LANGSERVER_START_PARAMS,
	needs       = {Cap.Project, Cap.Svc},
	apply       = langserver_start_apply,
}

langserver_stop :: Tool_Desc{
	name        = "langserver_stop",
	title       = "Stop language server",
	description = "Stop the running language server for one language.",
	can_edit    = true, // mutates daemon state (kills a shared server)
	optional    = true,
	category    = .Langserver,
	params      = LANGSERVER_STOP_PARAMS,
	needs       = {Cap.Project, Cap.Svc},
	apply       = langserver_stop_apply,
}

langserver_restart :: Tool_Desc{
	name        = "langserver_restart",
	title       = "Restart language server",
	description = "Restart language servers. Use this tool only on explicit user request or after confirmation. " +
		"It may be necessary to restart a language server if it hangs. " +
		"With a language, that server is replaced atomically; without one, every server stops and restarts on demand.",
	can_edit    = true, // mutates daemon state (replaces server processes)
	optional    = true,
	category    = .Langserver,
	params      = LANGSERVER_RESTART_PARAMS,
	needs       = {Cap.Project, Cap.Svc},
	apply       = langserver_restart_apply,
}

langserver_reload :: Tool_Desc{
	name        = "langserver_reload",
	title       = "Reload language server settings",
	description = "Re-read the language server settings (language_servers, language_server_commands, language_server_options) from .aubade/project.jsonc, " +
		"stop the running language servers, and apply the new settings to future starts. " +
		"Use this after editing the config file — the daemon reads it once at startup, so edits need this call (or a new session) to take effect.",
	can_edit    = true, // mutates daemon state (stops servers, swaps settings)
	optional    = true,
	category    = .Langserver,
	params      = nil,
	needs       = {Cap.Project, Cap.Svc},
	apply       = langserver_reload_apply,
}

langserver_list :: Tool_Desc{
	name        = "langserver_list",
	title       = "List language servers",
	description = "List the project's configured or running language servers with their running state.",
	can_edit    = false,
	category    = .Langserver,
	params      = nil,
	needs       = {Cap.Project, Cap.Svc},
	apply       = langserver_list_apply,
}

langserver_get_diagnostics :: Tool_Desc{
	name        = "langserver_get_diagnostics",
	title       = "Get diagnostics",
	description = "Return the diagnostics for one file (errors, warnings, hints) from its language server.",
	can_edit    = false,
	category    = .Langserver,
	params      = LANGSERVER_GET_DIAGNOSTICS_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = langserver_get_diagnostics_apply,
}

langserver_get_code_actions :: Tool_Desc{
	name        = "langserver_get_code_actions",
	title       = "Get code actions",
	description = "Return the code actions (quick fixes, refactors) available for a range in one file.",
	can_edit    = false,
	category    = .Langserver,
	params      = LANGSERVER_GET_CODE_ACTIONS_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = langserver_get_code_actions_apply,
}

langserver_format :: Tool_Desc{
	name        = "langserver_format",
	title       = "Format file",
	description = "Return the formatting edits for one file. Returns text edits, does not apply them.",
	can_edit    = false,
	category    = .Langserver,
	params      = LANGSERVER_FORMAT_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = langserver_format_apply,
}

langserver_get_inlay_hints :: Tool_Desc{
	name        = "langserver_get_inlay_hints",
	title       = "Get inlay hints",
	description = "Return the inlay hints (inferred types, parameter names) inside a range of one file.",
	can_edit    = false,
	category    = .Langserver,
	params      = LANGSERVER_GET_INLAY_HINTS_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = langserver_get_inlay_hints_apply,
}

langserver_find_calls :: Tool_Desc{
	name        = "langserver_find_calls",
	title       = "Get call hierarchy",
	description = "Return the incoming or outgoing calls for the symbol at a position in one file.",
	can_edit    = false,
	category    = .Langserver,
	params      = LANGSERVER_FIND_CALLS_PARAMS,
	needs       = {Cap.Project, Cap.Svc, Cap.Editor},
	apply       = langserver_find_calls_apply,
}

// --- applies ------------------------------------------------------------------

langserver_start_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	lang := arg_str(args, "language")
	call := svc.client_langserver_start(ctx.svc_conn, lang, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	return text_result(ctx, strings.concatenate({"language server for \"", lang, "\" started"}, ctx.allocator))
}

langserver_stop_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	lang := arg_str(args, "language")
	call := svc.client_langserver_stop(ctx.svc_conn, lang, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	return text_result(ctx, strings.concatenate({"language server for \"", lang, "\" stopped"}, ctx.allocator))
}

langserver_restart_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	lang := arg_str(args, "language")
	call := svc.client_langserver_restart(ctx.svc_conn, lang, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	if lang != "" {
		return text_result(ctx, strings.concatenate({"language server for \"", lang, "\" restarted"}, ctx.allocator))
	}
	return text_result(ctx, "language servers stopped; they restart on demand")
}

langserver_reload_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_langserver_reload(ctx.svc_conn, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	overrides, _ := json_int(call.result, "overrides")
	stopped, _ := json_int(call.result, "stopped")
	return text_result(
		ctx,
		fmt.aprintf(
			"language server settings reloaded (%d command overrides, %d servers stopped)",
			int(overrides),
			int(stopped),
			allocator = ctx.allocator,
		),
	)
}

langserver_list_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	call := svc.client_langserver_list(ctx.svc_conn, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	if message, ok := json_str(call.result, "message"); ok {
		return text_result(ctx, message)
	}
	return langserver_items_result(ctx, call.result, max_chars)
}

langserver_get_diagnostics_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	call := svc.client_langserver_diagnostics(ctx.svc_conn, arg_str(args, "relative_path"), ctx.allocator, svc_deadline(ctx), ctx.cancel)
	return call_items_result(ctx, call, max_chars)
}

// langserver_range_apply drives the two range-scoped queries (code
// actions, inlay hints): the same file-plus-range wire args and the same
// items-list answer; `call` is the per-tool svc client proc.
langserver_range_apply :: proc(
	ctx: ^Tool_Ctx,
	args: ^Args,
	call: proc(conn: ^jsonrpc.Conn, rel: string, start_line, start_col, end_line, end_col: int, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token) -> svc.Client_Call,
) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	c := call(
		ctx.svc_conn, arg_str(args, "relative_path"),
		arg_int(args, "start_line"), arg_int(args, "start_col"),
		arg_int(args, "end_line"), arg_int(args, "end_col"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_items_result(ctx, c, max_chars)
}

langserver_get_code_actions_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	return langserver_range_apply(ctx, args, svc.client_langserver_code_actions)
}

langserver_format_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	tab_size := arg_int(args, "tab_size")
	insert_spaces := true
	if arg_has(args, "insert_spaces") {
		insert_spaces = arg_bool(args, "insert_spaces")
	}
	call := svc.client_langserver_format(
		ctx.svc_conn, arg_str(args, "relative_path"), tab_size, insert_spaces,
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_items_result(ctx, call, max_chars)
}

langserver_get_inlay_hints_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	return langserver_range_apply(ctx, args, svc.client_langserver_inlay_hints)
}

langserver_find_calls_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	call := svc.client_langserver_call_hierarchy(
		ctx.svc_conn, arg_str(args, "relative_path"),
		arg_int(args, "line"), arg_int(args, "col"), arg_str(args, "direction"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_items_result(ctx, call, max_chars)
}

// langserver_items_result renders the family's {items: [...]} envelope as
// JSON text under the max-answer-chars gate.
langserver_items_result :: proc(ctx: ^Tool_Ctx, result: json.Value, max_chars: int) -> Tool_Result {
	items, _ := jsonutil.obj_get(result, "items")
	return text_result(ctx, util.limit_length(to_json(items, ctx), max_chars, nil, ctx.allocator))
}

// call_items_result maps a svc call onto the family's items answer: a
// failed call answers with the wire code and message.
call_items_result :: proc(ctx: ^Tool_Ctx, call: svc.Client_Call, max_chars: int) -> Tool_Result {
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	return langserver_items_result(ctx, call.result, max_chars)
}
