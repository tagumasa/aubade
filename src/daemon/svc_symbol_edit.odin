// The svc.symbol/* edit handlers: parse the wire params (the tool
// argument names) and forward to the ops layer, which re-parses the
// file and drives the editor.
package daemon

import "core:encoding/json"
import "core:mem"

import "src:editor"
import "src:jsonutil"
import "src:platform"
import "src:svc"

register_symbol_edit_methods :: proc(t: ^svc.Table) {
	svc.table_register_mutating(t, svc.METHOD_SYMBOL_REPLACE_BODY, handle_symbol_replace_body)
	svc.table_register_mutating(t, svc.METHOD_SYMBOL_INSERT_BEFORE, handle_symbol_insert_before)
	svc.table_register_mutating(t, svc.METHOD_SYMBOL_INSERT_AFTER, handle_symbol_insert_after)
	svc.table_register_mutating(t, svc.METHOD_SYMBOL_MOVE, handle_symbol_move)
	svc.table_register_mutating(t, svc.METHOD_SYMBOL_INSERT_DOCSTRING, handle_symbol_insert_docstring)
	svc.table_register_mutating(t, svc.METHOD_SYMBOL_DELETE_DOCSTRING, handle_symbol_delete_docstring)
	svc.table_register_mutating(t, svc.METHOD_SYMBOL_REPLACE_DOCSTRING, handle_symbol_replace_docstring)
}

// symbol_edit_target parses the shared {name_path, relative_path} pair.
symbol_edit_target :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (string, string, platform.Err) {
	path, nerr := file_require_str(ctx, params, "name_path")
	if nerr != nil {
		return "", "", nerr
	}
	rel, rerr := file_require_str(ctx, params, "relative_path")
	if rerr != nil {
		return "", "", rerr
	}
	return path, rel, nil
}

// Symbol_String_Op is the svc face behind the five one-string-payload
// symbol edits (body inserts, docstring writes).
Symbol_String_Op :: proc(
	src: ^svc.TS_Source,
	ed: ^editor.Editor,
	name_path: string,
	rel: string,
	value: string,
	lsp_src: ^svc.LSP_Source,
	a: mem.Allocator,
	token: ^platform.Cancel_Token,
) -> platform.Err

// handle_symbol_string_op parses the shared target plus the one required
// string member `key` names, then forwards to `op`.
handle_symbol_string_op :: proc(ctx: ^svc.Svc_Ctx, params: json.Value, key: string, op: Symbol_String_Op) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	name_path, rel, err := symbol_edit_target(ctx, params)
	if err != nil {
		return nil, err
	}
	value, verr := file_present_str(ctx, params, key)
	if verr != nil {
		return nil, verr
	}
	if aerr := op(d.ts, d.ed, name_path, rel, value, d.lsp_src, ctx.allocator, ctx.token); aerr != nil {
		return nil, aerr
	}
	return empty_ok(ctx), nil
}

handle_symbol_replace_body :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	return handle_symbol_string_op(ctx, params, "body", svc.symbol_edit_replace_body)
}

handle_symbol_insert_before :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	return handle_symbol_string_op(ctx, params, "body", svc.symbol_edit_insert_before)
}

handle_symbol_insert_after :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	return handle_symbol_string_op(ctx, params, "body", svc.symbol_edit_insert_after)
}

handle_symbol_move :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	name_path, nerr := file_require_str(ctx, params, "name_path")
	if nerr != nil {
		return nil, nerr
	}
	source_rel, serr := file_require_str(ctx, params, "source_relative_path")
	if serr != nil {
		return nil, serr
	}
	target_rel, terr := file_require_str(ctx, params, "target_relative_path")
	if terr != nil {
		return nil, terr
	}
	position, _, perr := file_opt_str(ctx, params, "target_position")
	if perr != nil {
		return nil, perr
	}
	if position == "" {
		position = "end"
	}
	mode_param, _, merr := file_opt_str(ctx, params, "mode")
	if merr != nil {
		return nil, merr
	}
	// The wire spelling dies here; everything past the boundary carries
	// the typed mode.
	mode, parse_err, parse_msg := editor.move_mode_parse(mode_param)
	if parse_err != .None {
		return nil, svc.wrapped_err(.Invalid, parse_msg, ctx.allocator)
	}

	summary, aerr := svc.symbol_edit_move(d.ts, d.ed, name_path, source_rel, target_rel, position, mode, ctx.allocator, ctx.token)
	if aerr != nil {
		return nil, aerr
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "summary", jsonutil.json_string(summary))
	return json.Value(json.Object(out)), nil
}

handle_symbol_insert_docstring :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	return handle_symbol_string_op(ctx, params, "comment", svc.symbol_edit_insert_docstring)
}

handle_symbol_delete_docstring :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	name_path, rel, err := symbol_edit_target(ctx, params)
	if err != nil {
		return nil, err
	}
	if aerr := svc.symbol_edit_delete_docstring(d.ts, d.ed, name_path, rel, d.lsp_src, ctx.allocator, ctx.token); aerr != nil {
		return nil, aerr
	}
	return empty_ok(ctx), nil
}

handle_symbol_replace_docstring :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	return handle_symbol_string_op(ctx, params, "comment", svc.symbol_edit_replace_docstring)
}
