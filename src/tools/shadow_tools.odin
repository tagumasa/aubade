// The shadow git tools: workspace snapshots through the isolated shadow
// repository owned by the parent daemon. snapshot/log/diff/patch are
// read-only views; restore and revert_file rewrite workspace content
// (can_edit, destructive) and revert_file runs the same containment and
// write-denial gates as the file editing tools.
package tools

import "core:path/filepath"
import "core:strings"

import "src:safety"
import "src:svc"

SHADOW_SNAPSHOT_PARAMS :: []Param_Desc{
	{name = "message", kind = .Str, description = "Optional commit message for the snapshot."},
}

SHADOW_LOG_PARAMS :: []Param_Desc{
	{name = "count", kind = .Int, description = "Number of snapshots to list (1-50, default 10)."},
}

SHADOW_DIFF_PARAMS :: []Param_Desc{
	{name = "from", kind = .Str, description = "The starting snapshot hash.", required = true},
	{name = "to", kind = .Str, description = "The ending snapshot hash.", required = true},
}

SHADOW_RESTORE_PARAMS :: []Param_Desc{
	{name = "hash", kind = .Str, description = "The snapshot hash to restore.", required = true},
}

SHADOW_REVERT_FILE_PARAMS :: []Param_Desc{
	{name = "hash", kind = .Str, description = "The snapshot hash holding the file state to restore.", required = true},
	{name = "file_path", kind = .Str, description = "The workspace-relative path of the file to revert.", required = true},
}

SHADOW_PATCH_PARAMS :: []Param_Desc{
	{name = "from", kind = .Str, description = "The starting snapshot hash.", required = true},
	{name = "to", kind = .Str, description = "The ending snapshot hash.", required = true},
}

shadow_snapshot :: Tool_Desc{
	name        = "shadow_snapshot",
	title       = "Create shadow snapshot",
	description = "Create a snapshot of the current workspace state. Returns a commit hash for later reference.",
	can_edit    = false,
	optional    = true,
	category    = .Shadow,
	params      = SHADOW_SNAPSHOT_PARAMS,
	needs       = {Cap.Project, Cap.Shadow},
	apply       = shadow_snapshot_apply,
}

shadow_log :: Tool_Desc{
	name        = "shadow_log",
	title       = "List shadow snapshots",
	description = "List recent shadow git snapshots. Returns commit hashes (newest first).",
	can_edit    = false,
	optional    = true,
	category    = .Shadow,
	params      = SHADOW_LOG_PARAMS,
	needs       = {Cap.Project, Cap.Shadow},
	apply       = shadow_log_apply,
}

shadow_diff :: Tool_Desc{
	name        = "shadow_diff",
	title       = "Diff shadow snapshots",
	description = "Show the unified diff between two shadow git snapshots.",
	can_edit    = false,
	optional    = true,
	category    = .Shadow,
	params      = SHADOW_DIFF_PARAMS,
	needs       = {Cap.Project, Cap.Shadow},
	apply       = shadow_diff_apply,
}

shadow_restore :: Tool_Desc{
	name        = "shadow_restore",
	title       = "Restore shadow snapshot",
	description = "Restore the workspace to a previous shadow git snapshot. This will overwrite current files; every tracked path passes the same containment and write-denial gate as file writes, and the restore refuses (naming the paths) when any check fails.",
	can_edit    = true,
	destructive = true,
	optional    = true,
	category    = .Shadow,
	params      = SHADOW_RESTORE_PARAMS,
	needs       = {Cap.Project, Cap.Shadow},
	apply       = shadow_restore_apply,
}

shadow_revert_file :: Tool_Desc{
	name        = "shadow_revert_file",
	title       = "Revert file to snapshot",
	description = "Revert a single file to its state in a previous shadow git snapshot.",
	can_edit    = true,
	destructive = true,
	optional    = true,
	category    = .Shadow,
	params      = SHADOW_REVERT_FILE_PARAMS,
	needs       = {Cap.Project, Cap.Shadow},
	apply       = shadow_revert_file_apply,
}

shadow_patch :: Tool_Desc{
	name        = "shadow_patch",
	title       = "List files changed between snapshots",
	description = "List files changed between two shadow git snapshots.",
	can_edit    = false,
	optional    = true,
	category    = .Shadow,
	params      = SHADOW_PATCH_PARAMS,
	needs       = {Cap.Project, Cap.Shadow},
	apply       = shadow_patch_apply,
}

// --- applies -----------------------------------------------------------------

shadow_snapshot_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_shadow_snapshot(
		ctx.svc_conn, arg_str(args, "message"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	hash, _ := json_str(call.result, "hash")
	return text_result(ctx, strings.concatenate({"Snapshot created: ", hash}, ctx.allocator))
}

shadow_log_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	count := 10
	if v := arg_int(args, "count"); v > 0 && v <= 50 {
		count = v
	}
	call := svc.client_shadow_log(
		ctx.svc_conn, count,
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	text := call_text(call.result)
	if text == "" {
		return text_result(ctx, "No snapshots found.")
	}
	return text_result(ctx, text)
}

shadow_diff_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	from := arg_str(args, "from")
	to := arg_str(args, "to")
	if from == "" || to == "" {
		return err_result(ctx, "both from and to hash are required")
	}
	call := svc.client_shadow_diff(
		ctx.svc_conn, from, to,
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	return text_result(ctx, call_text(call.result))
}

shadow_restore_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	hash := arg_str(args, "hash")
	if hash == "" {
		return err_result(ctx, "hash is required")
	}
	call := svc.client_shadow_restore(
		ctx.svc_conn, hash,
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	return text_result(ctx, strings.concatenate({"Workspace restored to snapshot ", hash}, ctx.allocator))
}

shadow_revert_file_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	hash := arg_str(args, "hash")
	if hash == "" {
		return err_result(ctx, "hash is required")
	}
	file_path := arg_str(args, "file_path")
	if file_path == "" {
		return err_result(ctx, "file_path is required")
	}
	if esc := validate_workspace_write(ctx, file_path); esc != "" {
		return err_result(ctx, esc)
	}
	call := svc.client_shadow_revert_file(
		ctx.svc_conn, hash, file_path,
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	return text_result(ctx, strings.concatenate(
		{"File ", file_path, " reverted to snapshot ", hash}, ctx.allocator,
	))
}

shadow_patch_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	from := arg_str(args, "from")
	to := arg_str(args, "to")
	if from == "" || to == "" {
		return err_result(ctx, "both from and to hash are required")
	}
	call := svc.client_shadow_patch(
		ctx.svc_conn, from, to,
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	text := call_text(call.result)
	if text == "" {
		return text_result(ctx, "No files changed between the two snapshots.")
	}
	return text_result(ctx, text)
}

// validate_workspace_write is revert_file's write gate: workspace
// containment plus the sensitive-path write denial, the same pair the file
// editing tools enforce.
validate_workspace_write :: proc(ctx: ^Tool_Ctx, file_path: string) -> string {
	_, esc := safety.pathguard_validate_contained(ctx.project_root, file_path, ctx.allocator)
	if esc.reason != "" {
		return strings.concatenate({"path escapes project root: ", file_path}, ctx.allocator)
	}
	if ctx.safety != nil {
		parts := []string{ctx.project_root, file_path}
		abs, jerr := filepath.join(parts, ctx.allocator)
		// The deny decision must not ride on a side effect of the empty
		// result: check the join and deny explicitly (the pathguard step
		// above fails closed the same way).
		if jerr != .None || len(abs) == 0 {
			return strings.concatenate(
				{"cannot resolve write path: ", file_path}, ctx.allocator,
			)
		}
		if safety.is_write_denied(&ctx.safety.write_denied, abs) {
			return strings.concatenate(
				{"write access denied for sensitive path: ", file_path}, ctx.allocator,
			)
		}
	}
	return ""
}
