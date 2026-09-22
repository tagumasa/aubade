// tools: the Tool_Desc single declaration point. One tool = one constant
// entry; Tool_ID is the array index; onboarding_check is the one
// fixed-response entry.
package tools

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "src:jsonrpc"
import "src:jsonutil"
import "src:platform"
import "src:safety"
import "src:svc"

Param_Kind :: enum {
	Str,
	Int,
	Float,
	Bool,
	Str_Array,
	Int_Array,
}

Param_Desc :: struct {
	name:        string,
	kind:        Param_Kind,
	description: string,
	required:    bool,
	enum_vals:   []string, // optional
}

Cap :: enum {
	Project,
	Svc,
	Editor,
	Tracker,
	Memories,
	Shadow,
	Web,
	Shell,
}

// cap_all is every capability bit. The startup warning pass folds with it
// so its notices are unknown-name only: capability-dependent visibility is
// the runtime folds' decision, and a pre-connect pass cannot know the live
// set — folding a thinner set false-warns "not available" for tools the
// session will in fact serve.
cap_all :: proc() -> (all: bit_set[Cap]) {
	for c in Cap {
		all |= {c}
	}
	return
}

Category :: enum {
	Symbol,
	File,
	Tracker,
	Memory,
	Shell,
	Config,
	Project,
	Onboarding,
	Langserver,
	Ast,
	Incident,
	Sprint,
	Shadow,
	Web,
	Marker,
}

Content_Kind :: enum {
	Text,
	Image, // v1 frame only; no tool produces it yet
}

Content :: struct {
	kind: Content_Kind,
	text:  string,
}

text_content :: proc(text: string) -> Content {
	return {kind = .Text, text = text}
}

Tool_Result :: struct {
	contents: [dynamic]Content,
	is_error: bool, // always present; input-validation failures land here too
	// The failure kind for svc-backed errors, typed at the wire boundary
	// (the retry stage reads it; the constructors default it to .Internal
	// and non-error results leave it there).
	err_kind: platform.Err_Kind,
}

// result_init gives the contents array an explicit home on the request
// arena: apply procs append through it, never through context.allocator.
result_init :: proc(result: ^Tool_Result, ctx: ^Tool_Ctx, expected: int = 2) {
	result.contents = make([dynamic]Content, 0, expected, ctx.allocator)
}

Args :: struct {
	raw:    string,               // original arguments JSON (for error quoting)
	values: map[string]json.Value, // validated, defaults applied
}

Session_Info :: struct {
	// Effective logging setup (config_get's overview rows).
	log_level: string,
	trace_lsp: bool,
}

Caps :: struct {
	available: bit_set[Cap],
}

Tool_Ctx :: struct {
	call_id:     jsonrpc.Id,
	id_set:      bool,
	allocator:   mem.Allocator,
	cancel:      ^platform.Cancel_Token,
	deadline_ms: i64,
	caps:        ^Caps,
	session:     ^Session_Info,
	// Session identity for the config overview: the active context and
	// modes (empty = none selected) and the host's current folded tool
	// set ({} = hostless consumer; config_get then reports no actives).
	context_name: string,
	mode_names:   []string,
	visible:      Visibility,
	safety:       ^safety.Safety_Checker, // nil = no safety gating (tests)
	project_root: string,                // containment root for shell_run
	default_max_chars: int,              // 0 = limit_length default off
	svc_conn:    ^jsonrpc.Conn,          // parent link; nil = svc tools refuse
}

Tool_Apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result

Tool_Desc :: struct {
	name:        string,
	title:       string, // human-facing display name (MCP 2025-11)
	description: string,
	can_edit:    bool,
	// destructive marks the can_edit tools that can overwrite or destroy
	// existing content (destructiveHint = can_edit AND destructive
	// category — insert-only editors stay non-destructive).
	destructive: bool,
	optional:    bool,
	category:    Category,
	params:      []Param_Desc,
	needs:       bit_set[Cap],
	apply:       Tool_Apply,
}

// ---------------------------------------------------------------------------
// The tool table. Tool_ID = array index; never reordered once assigned.
// ---------------------------------------------------------------------------

TOOL_COUNT :: 78

Tool_ID :: enum {
	Onboarding_Check,
	Shell_Run,
	Onboarding_Read_Instructions,
	Onboarding_Run,
	File_Read,
	File_Write,
	File_List_Dir,
	File_Find,
	File_Search,
	File_Replace,
	File_Insert_Lines,
	File_Replace_Lines,
	File_Delete_Lines,
	File_Delete,
	File_Move,
	Symbol_List,
	Symbol_Find,
	Symbol_Replace_Body,
	Symbol_Insert_Before,
	Symbol_Insert_After,
	Symbol_Move,
	Symbol_Insert_Docstring,
	Symbol_Delete_Docstring,
	Symbol_Replace_Docstring,
	Ast_Parse,
	Ast_Query,
	Langserver_Start,
	Langserver_Stop,
	Langserver_Restart,
	Langserver_List,
	Langserver_Get_Diagnostics,
	Langserver_Get_Code_Actions,
	Langserver_Format,
	Langserver_Get_Inlay_Hints,
	Langserver_Find_Calls,
	Langserver_Reload,
	Memory_List,
	Memory_Read,
	Memory_Write,
	Memory_Replace,
	Memory_Rename,
	Memory_Delete,
	Incident_Create,
	Incident_List,
	Incident_Get,
	Incident_Verify,
	Incident_Update,
	Incident_Resolve,
	Incident_Delete,
	Sprint_Start,
	Sprint_Close,
	Sprint_List,
	Sprint_Get,
	Sprint_Update,
	Tracker_Export,
	Config_Get,
	Config_Set,
	Config_Delete,
	Shadow_Snapshot,
	Shadow_Log,
	Shadow_Diff,
	Shadow_Restore,
	Shadow_Revert_File,
	Shadow_Patch,
	Web_Fetch,
	Web_Search,
	Symbol_Find_References,
	Symbol_Find_Implementations,
	Symbol_Find_Declaration,
	Symbol_Rename,
	Symbol_Delete,
	Marker_Symbolic_Read,
	Marker_Can_Edit,
	Marker_Symbolic_Edit,
	Sprint_Record_Verification,
	File_Read_Outline,
	Symbol_Find_Dead_Code,
	Ast_Find_Duplicates,
}

onboarding_check :: Tool_Desc{
	name        = "onboarding_check",
	title       = "Check onboarding",
	description = "Check whether project onboarding has been performed.",
	can_edit    = false,
	optional    = false,
	category    = .Onboarding,
	params      = nil,
	needs       = {}, // no capability: always visible
	apply       = onboarding_check_apply,
}

TOOLS :: [TOOL_COUNT]Tool_Desc{
	onboarding_check,
	shell_run,
	onboarding_read_instructions,
	onboarding_run,
	file_read,
	file_write,
	file_list_dir,
	file_find,
	file_search,
	file_replace,
	file_insert_lines,
	file_replace_lines,
	file_delete_lines,
	file_delete,
	file_move,
	symbol_list,
	symbol_find,
	symbol_replace_body,
	symbol_insert_before,
	symbol_insert_after,
	symbol_move,
	symbol_insert_docstring,
	symbol_delete_docstring,
	symbol_replace_docstring,
	ast_parse,
	ast_query,
	langserver_start,
	langserver_stop,
	langserver_restart,
	langserver_list,
	langserver_get_diagnostics,
	langserver_get_code_actions,
	langserver_format,
	langserver_get_inlay_hints,
	langserver_find_calls,
	langserver_reload,
	memory_list,
	memory_read,
	memory_write,
	memory_replace,
	memory_rename,
	memory_delete,
	incident_create,
	incident_list,
	incident_get,
	incident_verify,
	incident_update,
	incident_resolve,
	incident_delete,
	sprint_start,
	sprint_close,
	sprint_list,
	sprint_get,
	sprint_update,
	tracker_export,
	config_get,
	config_set,
	config_delete,
	shadow_snapshot,
	shadow_log,
	shadow_diff,
	shadow_restore,
	shadow_revert_file,
	shadow_patch,
	web_fetch,
	web_search,
	symbol_find_references,
	symbol_find_implementations,
	symbol_find_declaration,
	symbol_rename,
	symbol_delete,
	marker_symbolic_read,
	marker_can_edit,
	marker_symbolic_edit,
	sprint_record_verification,
	file_read_outline,
	symbol_find_dead_code,
	ast_find_duplicates,
}

find_by_name :: proc(name: string) -> (Tool_ID, bool) {
	// Materialize the constant table before indexing: the compiler
	// rejects variable indexing straight into constant data.
	table := TOOLS
	for i in 0..<len(table) {
		if table[i].name == name {
			return cast(Tool_ID)i, true
		}
	}
	return Tool_ID.Onboarding_Check, false
}

// tool_name is the ID-based reference for a tool's wire name: callers cite
// tools through their Tool_ID, never a scattered string literal, so the
// table and its consumers cannot drift apart (the same materialize-
// before-index discipline as find_by_name).
tool_name :: proc(tid: Tool_ID) -> string {
	table := TOOLS
	return table[int(tid)].name
}

// The hook classifiers' working-tool set (symbolic credit in the remind
// hook, acceptEdits auto-approve): every registered tool except the
// read/search/trivial families — the bookkeeping categories are excluded
// wholesale, and the read-only File and Langserver members by id.
SYMBOLIC_HOOK_EXCLUDED_CATEGORIES :: []Category{
	.Onboarding,
	.Memory,
	.Shell,
	.Config,
}

SYMBOLIC_HOOK_EXCLUDED_IDS :: []Tool_ID{
	.File_Read,
	.File_List_Dir,
	.File_Find,
	.File_Search,
	.File_Read_Outline,
	.Langserver_Restart,
	.Langserver_Get_Diagnostics,
}

// symbolic_hook_names renders the wire names of the working-tool set the
// hooks package consumes by injection (it sits below this layer). The
// caller owns the returned slice.
symbolic_hook_names :: proc(a := context.allocator) -> []string {
	table := TOOLS
	names := make([dynamic]string, 0, TOOL_COUNT, a)
	for tid in Tool_ID {
		if slice.contains(SYMBOLIC_HOOK_EXCLUDED_CATEGORIES, table[int(tid)].category) {
			continue
		}
		if slice.contains(SYMBOLIC_HOOK_EXCLUDED_IDS, tid) {
			continue
		}
		append(&names, table[int(tid)].name)
	}
	return names[:]
}

// The capability-only core of the visibility rule: a tool is visible
// when its declared needs are satisfied by the available capabilities.
// fold_visibility (fold.odin) folds the config stack around this
// predicate as the single visibility engine.
visible :: proc(id: Tool_ID, available: bit_set[Cap]) -> bool {
	table := TOOLS
	return table[int(id)].needs & ~available == {}
}

Visibility :: bit_set[Tool_ID]

// visibility_set is the config-less host view: the single fold engine
// (fold_visibility) with no inclusion layers. Hosts with a config stack
// call fold_visibility directly — this stays the one definition of
// visibility, never a second fold.
visibility_set :: proc(available: bit_set[Cap], read_only: bool = false) -> Visibility {
	return fold_visibility(available, read_only, nil, nil)
}

// ---------------------------------------------------------------------------
// onboarding_check: the memory-backed onboarding gate. Onboarding counts
// as performed once project-scoped memories exist; the message tells a
// fresh session to run onboarding_run and read the manual either way.
// ---------------------------------------------------------------------------

onboarding_check_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) || ctx.caps == nil || !(.Memories in ctx.caps.available) {
		return text_result(ctx, "Memory reading tool not activated, skipping onboarding check.")
	}
	call := svc.client_memory_list(ctx.svc_conn, "", ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	count := memory_project_count(call.result)
	if count == 0 {
		return text_result(
			ctx,
			onboarding_verdict_text(
				ctx,
				strings.concatenate({
					"Onboarding not performed yet (no memories available). ",
					"You should perform onboarding by calling the `",
					tool_name(.Onboarding_Run),
					"` tool before proceeding with the task. ",
					"If you have not read the 'Aubade Instructions Manual', do so now.",
				}, ctx.allocator),
			),
		)
	}
	return text_result(
		ctx,
		onboarding_verdict_text(
			ctx,
			fmt.aprintf(
				"Onboarding was already performed: %d project memories are available. " +
				"Consider reading memories if they appear relevant to the task at hand. " +
				"If you have not read the 'Aubade Instructions Manual', do so now.",
				count,
				allocator = ctx.allocator,
			),
		),
	)
}

// onboarding_verdict_text appends the one-line language-server state to
// the onboarding verdict — the proactive surface for the unconfigured
// state, since the list tool's setup hint renders only when called. The
// line is omitted when the state cannot be read: onboarding must not
// fail on it.
onboarding_verdict_text :: proc(ctx: ^Tool_Ctx, verdict: string) -> string {
	line := onboarding_ls_line(ctx)
	if line == "" {
		return verdict
	}
	return strings.concatenate({verdict, "\n", line}, ctx.allocator)
}

// onboarding_ls_line summarizes svc.langserver/list in one line: the
// setup pointer when nothing is configured or running, otherwise the
// per-language running states.
onboarding_ls_line :: proc(ctx: ^Tool_Ctx) -> string {
	call := svc.client_langserver_list(ctx.svc_conn, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return ""
	}
	if _, ok := jsonutil.obj_get(call.result, "message"); ok {
		return "Language servers: none configured or running — call langserver_list for the setup guidance."
	}
	items_v, ok := jsonutil.obj_get(call.result, "items")
	if !ok {
		return ""
	}
	items, aok := jsonutil.as_array(items_v)
	if !aok || len(items) == 0 {
		return ""
	}
	parts := make([dynamic]string, 0, len(items), ctx.allocator)
	for item in items {
		lang_v, lok := jsonutil.obj_get(item, "language")
		if !lok {
			continue
		}
		state := "not running"
		if run_v, rok := jsonutil.obj_get(item, "running"); rok {
			#partial switch b in run_v {
			case json.Boolean:
				if bool(b) {
					state = "running"
				}
			case:
			}
		}
		append(&parts, strings.concatenate({jsonutil.value_str(lang_v), " (", state, ")"}, ctx.allocator))
	}
	if len(parts) == 0 {
		delete(parts)
		return ""
	}
	joined, _ := strings.join(parts[:], ", ", ctx.allocator)
	delete(parts)
	return strings.concatenate({"Language servers: ", joined, "."}, ctx.allocator)
}

// shell_run: execute a shell command under the safety gates (see
// shell_tool.odin).
shell_run :: Tool_Desc{
	name        = "shell_run",
	title       = "Run shell command",
	description = "Execute a shell command in the project directory and return its output. " +
		"Dangerous commands and sensitive file writes are blocked by the safety layer; " +
		"the environment is scrubbed of secrets. Per-stream output is capped at the shell tool's fixed limit.",
	can_edit    = true,
	destructive = true, // a shell command can do anything, including destroy
	optional    = false,
	category    = .Shell,
	params      = SHELL_RUN_PARAMS,
	needs       = {Cap.Shell},
	apply       = shell_run_apply,
}
