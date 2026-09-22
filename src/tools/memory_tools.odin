// The memory tool family over svc.memory/*: markdown memories under
// the project's .aubade/memories and the global memories root (the
// "global/" name prefix). Reads stay non-destructive; the four
// mutators carry can_edit and the destructive category (they can
// overwrite or drop memory content). All six gate on the parent link
// and the Memories capability it grants.
package tools

import "src:util"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "src:jsonutil"
import "src:memory"
import "src:regex"
import "src:svc"

MEMORY_REPLACE_MODES :: regex.REPLACE_MODE_NAMES

MEMORY_WRITE_PARAMS :: []Param_Desc{
	{name = "memory_name", kind = .Str, description = "Memory name; \"/\" organizes into topics (e.g. \"auth/login/logic\").", required = true},
	{name = "content", kind = .Str, description = "Memory content (utf-8 markdown).", required = true},
	{name = "max_chars", kind = .Int, description = "Content length cap (-1 = session default).", required = false},
}

MEMORY_READ_PARAMS :: []Param_Desc{
	{name = "memory_name", kind = .Str, description = "Memory name (topic path, \".md\" implicit).", required = true},
}

MEMORY_LIST_PARAMS :: []Param_Desc{
	{name = "topic", kind = .Str, description = "Topic filter; \"global\" or \"global/<subtopic>\" addresses the cross-project memories.", required = false},
}

MEMORY_DELETE_PARAMS :: []Param_Desc{
	{name = "memory_name", kind = .Str, description = "Memory name to delete.", required = true},
}

MEMORY_RENAME_PARAMS :: []Param_Desc{
	{name = "old_name", kind = .Str, description = "Current memory name.", required = true},
	{name = "new_name", kind = .Str, description = "New name; \"/\" organizes, \"global/\" moves to the cross-project scope.", required = true},
}

MEMORY_REPLACE_PARAMS :: []Param_Desc{
	{name = "memory_name", kind = .Str, description = "Memory name.", required = true},
	{name = "needle", kind = .Str, description = "Search text or pattern.", required = true},
	{name = "repl", kind = .Str, description = "Replacement text.", required = true},
	{name = "mode", kind = .Str, description = "Match mode.", required = true, enum_vals = MEMORY_REPLACE_MODES},
	{name = "allow_multiple_occurrences", kind = .Bool, description = "Replace every match instead of refusing ambiguity.", required = false},
}

memory_write :: Tool_Desc{
	name        = "memory_write",
	title       = "Write memory",
	description = "Write information (utf-8-encoded) about this project that can be useful for future tasks to a memory in md format. " +
		"The memory name should be meaningful and can include \"/\" to organize into topics (e.g., \"auth/login/logic\"). " +
		"If explicitly instructed, use the \"global/\" prefix for writing a memory that is shared across projects " +
		"(e.g., \"global/java/style_guide\").",
	can_edit    = true,
	destructive = true,
	optional    = false,
	category    = .Memory,
	params      = MEMORY_WRITE_PARAMS,
	needs       = {Cap.Project, Cap.Memories},
	apply       = memory_write_apply,
}

memory_read :: Tool_Desc{
	name        = "memory_read",
	title       = "Read memory",
	description = "Read the content of a memory file. This tool should only be used if the information " +
		"is relevant to the current task. You can infer whether the information is relevant from the memory file name. " +
		"You should not read the same memory file multiple times in the same conversation.",
	can_edit    = false,
	optional    = false,
	category    = .Memory,
	params      = MEMORY_READ_PARAMS,
	needs       = {Cap.Project, Cap.Memories},
	apply       = memory_read_apply,
}

memory_list :: Tool_Desc{
	name        = "memory_list",
	title       = "List memories",
	description = "List available memories, optionally filtered by topic. Any memory can be read using the `memory_read` tool.",
	can_edit    = false,
	optional    = false,
	category    = .Memory,
	params      = MEMORY_LIST_PARAMS,
	needs       = {Cap.Project, Cap.Memories},
	apply       = memory_list_apply,
}

memory_delete :: Tool_Desc{
	name        = "memory_delete",
	title       = "Delete memory",
	description = "Delete a memory file. Should only happen if a user asks for it explicitly, " +
		"for example by saying that the information retrieved from a memory file is no longer correct " +
		"or no longer relevant for the project.",
	can_edit    = true,
	destructive = true,
	optional    = false,
	category    = .Memory,
	params      = MEMORY_DELETE_PARAMS,
	needs       = {Cap.Project, Cap.Memories},
	apply       = memory_delete_apply,
}

memory_rename :: Tool_Desc{
	name        = "memory_rename",
	title       = "Rename memory",
	description = "Renames or moves a memory, use \"/\" in the name to organize into topics. " +
		"Moving between project and global scope is supported " +
		"(e.g., renaming \"global/foo\" to \"bar\" moves it from global to project scope). " +
		"The \"global\" topic should only be used if explicitly instructed. " +
		"References in other memories (`mem:<name>`) follow the rename.",
	can_edit    = true,
	destructive = true,
	optional    = false,
	category    = .Memory,
	params      = MEMORY_RENAME_PARAMS,
	needs       = {Cap.Project, Cap.Memories},
	apply       = memory_rename_apply,
}

memory_replace :: Tool_Desc{
	name        = "memory_replace",
	title       = "Replace in memory",
	description = "Replaces content matching a pattern in a memory. " +
		"Use mode=\"literal\" for exact string matching or mode=\"regex\" for regular expression matching " +
		"(PCRE2 syntax with DOTALL and MULTILINE flags enabled). " +
		"In regex mode, backreferences in the replacement string use the syntax $!1, $!2, etc. " +
		"By default, only a single match is allowed; set allow_multiple_occurrences=true to replace all matches.",
	can_edit    = true,
	destructive = true,
	optional    = false,
	category    = .Memory,
	params      = MEMORY_REPLACE_PARAMS,
	needs       = {Cap.Project, Cap.Memories},
	apply       = memory_replace_apply,
}

// --- applies -----------------------------------------------------------------

memory_write_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	name := arg_str(args, "memory_name")
	// The length gate follows the session convention: a resolved max of
	// zero means limiting is off (the session host defaults to no cap).
	max_chars := util.resolve_max_chars(arg_int(args, "max_chars"), ctx.default_max_chars)
	if max_chars > 0 && len(arg_str(args, "content")) > max_chars {
		return err_result(
			ctx,
			fmt.aprintf(
				"content for %s is too long (max %d characters), please make the content shorter",
				name,
				max_chars,
				allocator = ctx.allocator,
			),
		)
	}
	call := svc.client_memory_write(ctx.svc_conn, name, arg_str(args, "content"), ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	return text_result(ctx, strings.concatenate({"Memory ", name, " written."}, ctx.allocator))
}

memory_read_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	name := arg_str(args, "memory_name")
	call := svc.client_memory_read(ctx.svc_conn, name, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	if !jsonutil.obj_get_bool(call.result, "found") {
		return text_result(
			ctx,
			strings.concatenate(
				{"Memory file ", name, " not found, consider creating it with the `memory_write` tool if you need it."},
				ctx.allocator,
			),
		)
	}
	content, _ := json_str(call.result, "content")
	return text_result(ctx, content)
}

memory_list_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_memory_list(ctx.svc_conn, arg_str(args, "topic"), ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	// The face omits empty buckets; {} renders when no memory exists.
	return text_result(ctx, to_json(call.result, ctx))
}

memory_delete_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	name := arg_str(args, "memory_name")
	call := svc.client_memory_delete(ctx.svc_conn, name, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	if !jsonutil.obj_get_bool(call.result, "found") {
		return text_result(ctx, strings.concatenate({"Memory ", name, " not found."}, ctx.allocator))
	}
	return text_result(ctx, strings.concatenate({"Memory ", name, " deleted."}, ctx.allocator))
}

memory_rename_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	old_name := arg_str(args, "old_name")
	new_name := arg_str(args, "new_name")
	call := svc.client_memory_rename(ctx.svc_conn, old_name, new_name, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	msg := strings.concatenate({"Memory renamed from ", old_name, " to ", new_name, "."}, ctx.allocator)
	propagated, _ := json_int(call.result, "propagated")
	if propagated > 0 {
		msg = fmt.aprintf(
			"%s Updated %d cross-reference(s) in other memories.",
			msg,
			int(propagated),
			allocator = ctx.allocator,
		)
	}
	return text_result(ctx, msg)
}

memory_replace_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	name := arg_str(args, "memory_name")
	allow_multiple := false
	if arg_has(args, "allow_multiple_occurrences") {
		allow_multiple = arg_bool(args, "allow_multiple_occurrences")
	}
	call := svc.client_memory_replace(
		ctx.svc_conn,
		name,
		arg_str(args, "needle"),
		arg_str(args, "repl"),
		arg_str(args, "mode"),
		allow_multiple,
		ctx.allocator,
		svc_deadline(ctx),
		ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	return text_result(ctx, strings.concatenate({"Memory ", name, " edited successfully."}, ctx.allocator))
}

// memory_project_count counts the project-scoped memories in a face
// listing (the onboarding check's input) — the length of the same
// project-scope walk memory_project_names performs.
memory_project_count :: proc(result: json.Value) -> int {
	return len(memory_project_names(result, context.temp_allocator))
}

// memory_project_names lists the project-scoped memory names in a face
// listing (the instructions manual's project-facts line): every name
// without the "global/" prefix, across both buckets, in wire order. The
// strings are views into `result` — they live exactly as long as the
// wire value, which for the manual is the request scope.
memory_project_names :: proc(result: json.Value, a: mem.Allocator) -> []string {
	names := make([dynamic]string, 0, 16, a)
	buckets := []string{"memories", "read_only_memories"}
	for key in buckets {
		if bucket, ok := jsonutil.obj_get(result, key); ok {
			#partial switch x in bucket {
			case json.Array:
				for entry in x {
					#partial switch e in entry {
					case json.String:
						if !memory.is_global_name(string(e)) {
							append(&names, string(e))
						}
					case:
					}
				}
			case:
			}
		}
	}
	return names[:]
}
