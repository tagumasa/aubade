// The svc.shadow/* handlers: the shadow git family's parent side. Reads
// (log/diff/patch) render the git output as text; the writes (snapshot/
// restore/revert_file) serialize through the service mutex so no two git
// conversations interleave. A daemon whose shadow failed to initialize
// refuses every method with one fixed message.
package daemon

import "core:encoding/json"
import "core:path/filepath"
import "core:strings"

import "src:jsonutil"
import "src:platform"
import "src:safety"
import "src:svc"
import "src:shadow"
import "src:util"

// shadow_for_project builds the workspace-snapshot repository under
// <home>/snapshot/<projectID>. A failed init (no git, unusable home)
// degrades to nil — the daemon stays up and every svc.shadow/* call
// refuses with the not-initialised message.
shadow_for_project :: proc(d: ^Daemon) -> ^shadow.Shadow_Git {
	sg := new(shadow.Shadow_Git, d.allocator)
	ierr := shadow.shadow_init(sg, d.cfg.home, d.cfg.project_root, d.allocator)
	if ierr == nil {
		ierr = shadow.shadow_repo_init(sg)
	}
	if ierr != nil {
		util.log_warning(strings.concatenate({
			"shadow git init failed: ", platform.err_message(ierr),
		}, context.temp_allocator))
		shadow.shadow_destroy(sg, d.allocator)
		free(sg, d.allocator)
		return nil
	}
	return sg
}

register_shadow_methods :: proc(t: ^svc.Table) {
	svc.table_register(t, svc.METHOD_SHADOW_SNAPSHOT, handle_shadow_snapshot)
	svc.table_register(t, svc.METHOD_SHADOW_LOG, handle_shadow_log)
	svc.table_register(t, svc.METHOD_SHADOW_DIFF, handle_shadow_diff)
	svc.table_register(t, svc.METHOD_SHADOW_PATCH, handle_shadow_patch)
	svc.table_register_mutating(t, svc.METHOD_SHADOW_RESTORE, handle_shadow_restore)
	svc.table_register_mutating(t, svc.METHOD_SHADOW_REVERT_FILE, handle_shadow_revert_file)
}

// shadow_ref returns the project's shadow git or the refusal every handler
// relays when it never initialized.
shadow_ref :: proc(d: ^Daemon) -> (^shadow.Shadow_Git, platform.Err) {
	if d.shadow == nil {
		return nil, platform.Wrapped{
			kind = .Terminated,
			msg  = "shadow git is not initialised for this project",
		}
	}
	return d.shadow, nil
}

handle_shadow_snapshot :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	sg, err := shadow_ref(d)
	if err != nil {
		return nil, err
	}
	message, present, perr := file_opt_str(ctx, params, "message")
	if perr != nil {
		return nil, perr
	}
	if !present {
		message = ""
	}
	hash, serr := shadow.shadow_snapshot(sg, message, ctx.token, ctx.allocator)
	if serr != nil {
		return nil, serr
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "hash", jsonutil.json_string(hash))
	return json.Value(json.Object(out)), nil
}

handle_shadow_log :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	sg, err := shadow_ref(d)
	if err != nil {
		return nil, err
	}
	count, present, perr := file_opt_int(ctx, params, "count")
	if perr != nil {
		return nil, perr
	}
	if !present {
		count = 10
	}
	hashes, lerr := shadow.shadow_log(sg, count, ctx.token, ctx.allocator)
	if lerr != nil {
		return nil, lerr
	}
	text := ""
	if len(hashes) > 0 {
		text, _ = strings.join(hashes, "\n", ctx.allocator)
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "text", jsonutil.json_string(text))
	return json.Value(json.Object(out)), nil
}

handle_shadow_diff :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	sg, err := shadow_ref(d)
	if err != nil {
		return nil, err
	}
	from, ferr := file_require_str(ctx, params, "from")
	if ferr != nil {
		return nil, ferr
	}
	to, terr := file_require_str(ctx, params, "to")
	if terr != nil {
		return nil, terr
	}
	text, derr := shadow.shadow_diff(sg, from, to, ctx.token, ctx.allocator)
	if derr != nil {
		return nil, derr
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "text", jsonutil.json_string(text))
	return json.Value(json.Object(out)), nil
}

handle_shadow_patch :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	sg, err := shadow_ref(d)
	if err != nil {
		return nil, err
	}
	from, ferr := file_require_str(ctx, params, "from")
	if ferr != nil {
		return nil, ferr
	}
	to, terr := file_require_str(ctx, params, "to")
	if terr != nil {
		return nil, terr
	}
	files, perr := shadow.shadow_patch(sg, from, to, ctx.token, ctx.allocator)
	if perr != nil {
		return nil, perr
	}
	text := ""
	if len(files) > 0 {
		text, _ = strings.join(files, "\n", ctx.allocator)
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "text", jsonutil.json_string(text))
	return json.Value(json.Object(out)), nil
}

handle_shadow_restore :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	sg, err := shadow_ref(d)
	if err != nil {
		return nil, err
	}
	hash, herr := file_require_str(ctx, params, "hash")
	if herr != nil {
		return nil, herr
	}
	// Write-denial gate over the whole tracked set before the rewrite
	// runs: the same sensitive-path table every file write consults. The
	// shadow layer refuses escapes and symlinks inside shadow_restore
	// itself; this half catches paths whose absolute spelling the write
	// tables deny.
	files, ferr := shadow.shadow_files_at(sg, hash, ctx.token, ctx.allocator)
	if ferr != nil {
		return nil, ferr
	}
	for f in files {
		parts := []string{sg.workspace_dir, f}
		abs, jerr := filepath.join(parts, context.temp_allocator)
		// The deny decision must not ride on a side effect of the empty
		// result: check the join and refuse explicitly (the file family's
		// gate fails closed the same way).
		if jerr != .None || len(abs) == 0 {
			return nil, platform.Wrapped{
				kind = .Invalid,
				msg  = strings.concatenate({"cannot resolve restore path: ", f}, ctx.allocator),
			}
		}
		if safety.is_write_denied(&d.file_safety.write_denied, abs) {
			return nil, platform.Wrapped{
				kind = .Denied,
				msg = strings.concatenate({
					"restore refused: write access denied for sensitive path: ", f,
				}, ctx.allocator),
			}
		}
	}
	if rerr := shadow.shadow_restore(sg, hash, ctx.token); rerr != nil {
		return nil, rerr
	}
	return json.Value(json.Object(jsonutil.json_object(0, ctx.allocator))), nil
}

handle_shadow_revert_file :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	sg, err := shadow_ref(d)
	if err != nil {
		return nil, err
	}
	hash, herr := file_require_str(ctx, params, "hash")
	if herr != nil {
		return nil, herr
	}
	file_path, fperr := file_require_str(ctx, params, "file_path")
	if fperr != nil {
		return nil, fperr
	}
	if rerr := shadow.shadow_revert_file(sg, hash, file_path, ctx.token); rerr != nil {
		return nil, rerr
	}
	return json.Value(json.Object(jsonutil.json_object(0, ctx.allocator))), nil
}
