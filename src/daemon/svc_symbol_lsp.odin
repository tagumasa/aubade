// The svc.symbol/* LSP retrieval handlers: the five language-server-bound
// symbol tools' daemon side. The read trio (find_references /
// find_implementations / find_declaration) is registered plain; rename and
// delete mutate project files, so they sit behind the mutating boundary
// (read-only sessions are refused at the table). All five answer with the
// item list / summary / refusal the child renders.
package daemon

import "core:encoding/json"
import "core:strings"

import "src:jsonutil"
import "src:platform"
import "src:svc"
import "src:symbol"

register_symbol_lsp_methods :: proc(t: ^svc.Table) {
	svc.table_register(t, svc.METHOD_SYMBOL_FIND_REFERENCES, handle_symbol_find_references)
	svc.table_register(t, svc.METHOD_SYMBOL_FIND_IMPLEMENTATIONS, handle_symbol_find_implementations)
	svc.table_register(t, svc.METHOD_SYMBOL_FIND_DECLARATION, handle_symbol_find_declaration)
	svc.table_register_mutating(t, svc.METHOD_SYMBOL_RENAME, handle_symbol_rename)
	svc.table_register_mutating(t, svc.METHOD_SYMBOL_DELETE, handle_symbol_delete)
}

// opt_u32_array reads an optional integer-array param (the kind filters);
// a non-array or non-integer element is refused.
opt_u32_array :: proc(ctx: ^svc.Svc_Ctx, params: json.Value, key: string) -> ([]u32, platform.Err) {
	v, ok := jsonutil.obj_get(params, key)
	if !ok || v == nil {
		return nil, nil
	}
	items, aok := jsonutil.as_array(v)
	if !aok {
		return nil, svc.wrapped_err(.Invalid, strings.concatenate({key, " must be an integer array"}, ctx.allocator), ctx.allocator)
	}
	out := make([]u32, len(items), ctx.allocator)
	for i in 0..<len(items) {
		#partial switch x in items[i] {
		case json.Integer:
			out[i] = u32(x)
		case:
			return nil, svc.wrapped_err(.Invalid, strings.concatenate({key, " must be an integer array"}, ctx.allocator), ctx.allocator)
		}
	}
	return out, nil
}

// symbol_lsp_ready guards the daemon's LSP producer: the five handlers
// refuse with one typed error when the source is unavailable.
symbol_lsp_ready :: proc(ctx: ^svc.Svc_Ctx) -> (^Daemon, platform.Err) {
	d := cast(^Daemon)ctx.user
	if d.lsp_src == nil {
		return nil, svc.wrapped_err(.Internal, "language server source unavailable", ctx.allocator)
	}
	return d, nil
}

handle_symbol_find_references :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d, derr := symbol_lsp_ready(ctx)
	if derr != nil {
		return nil, derr
	}
	name_path, rel, err := symbol_edit_target(ctx, params)
	if err != nil {
		return nil, err
	}
	include_imports := false
	if v, p, e := file_opt_bool(ctx, params, "include_imports"); e != nil {
		return nil, e
	} else if p {
		include_imports = v
	}
	include_self := false
	if v, p, e := file_opt_bool(ctx, params, "include_self"); e != nil {
		return nil, e
	} else if p {
		include_self = v
	}
	include_file_symbols := false
	if v, p, e := file_opt_bool(ctx, params, "include_file_symbols"); e != nil {
		return nil, e
	} else if p {
		include_file_symbols = v
	}
	include_kinds, kerr := opt_u32_array(ctx, params, "include_kinds")
	if kerr != nil {
		return nil, kerr
	}
	exclude_kinds, xerr := opt_u32_array(ctx, params, "exclude_kinds")
	if xerr != nil {
		return nil, xerr
	}

	refs, rerr := svc.symbol_lsp_find_references(
		d.lsp_src, d.ed, name_path, rel,
		include_imports, include_self, include_file_symbols,
		include_kinds, exclude_kinds,
		ctx.allocator, ctx.token,
	)
	if rerr != nil {
		return nil, rerr
	}

	items := make([]json.Value, len(refs), ctx.allocator)
	for i in 0..<len(refs) {
		ref := refs[i]
		entry := jsonutil.json_object(6, ctx.allocator)
		jsonutil.obj_set(&entry, "name_path", jsonutil.json_string(symbol.symbol_full_name_path(ref.sym, ctx.allocator)))
		jsonutil.obj_set(&entry, "name", jsonutil.json_string(ref.sym.name))
		jsonutil.obj_set(&entry, "kind", jsonutil.json_string(symbol.kind_name(ref.sym.kind)))
		rel_of := ref.sym.location != nil ? ref.sym.location.rel_path : ""
		jsonutil.obj_set(&entry, "relative_path", jsonutil.json_string(rel_of))
		jsonutil.obj_set(&entry, "reference_line", jsonutil.json_int(i64(ref.line)))
		if ref.content_around != "" {
			jsonutil.obj_set(&entry, "content_around_reference", jsonutil.json_string(ref.content_around))
		}
		if ref.sym.range != nil {
			loc := jsonutil.json_object(2, ctx.allocator)
			jsonutil.obj_set(&loc, "start_line", jsonutil.json_int(i64(ref.sym.range.start.line)))
			jsonutil.obj_set(&loc, "end_line", jsonutil.json_int(i64(ref.sym.range.end.line)))
			jsonutil.obj_set(&entry, "body_location", json.Value(json.Object(loc)))
		}
		items[i] = json.Value(json.Object(entry))
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "items", jsonutil.json_array(items, ctx.allocator))
	return json.Value(json.Object(out)), nil
}

handle_symbol_find_implementations :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d, derr := symbol_lsp_ready(ctx)
	if derr != nil {
		return nil, derr
	}
	name_path, rel, err := symbol_edit_target(ctx, params)
	if err != nil {
		return nil, err
	}
	include_body := false
	if v, p, e := file_opt_bool(ctx, params, "include_body"); e != nil {
		return nil, e
	} else if p {
		include_body = v
	}
	include_info := false
	if v, p, e := file_opt_bool(ctx, params, "include_info"); e != nil {
		return nil, e
	} else if p {
		include_info = v
	}
	include_kinds, kerr := opt_u32_array(ctx, params, "include_kinds")
	if kerr != nil {
		return nil, kerr
	}
	exclude_kinds, xerr := opt_u32_array(ctx, params, "exclude_kinds")
	if xerr != nil {
		return nil, xerr
	}

	entries, rerr := svc.symbol_lsp_find_implementations(
		d.lsp_src, name_path, rel, include_info, include_kinds, exclude_kinds, ctx.allocator, ctx.token,
	)
	if rerr != nil {
		return nil, rerr
	}

	items := make([]json.Value, len(entries), ctx.allocator)
	for i in 0..<len(entries) {
		e := entries[i]
		sym := e.sym
		entry := jsonutil.json_object(6, ctx.allocator)
		jsonutil.obj_set(&entry, "name", jsonutil.json_string(sym.name))
		jsonutil.obj_set(&entry, "name_path", jsonutil.json_string(symbol.symbol_full_name_path(sym, ctx.allocator)))
		jsonutil.obj_set(&entry, "kind", jsonutil.json_string(symbol.kind_name(sym.kind)))
		rel_of := sym.location != nil ? sym.location.rel_path : ""
		jsonutil.obj_set(&entry, "relative_path", jsonutil.json_string(rel_of))
		if sym.range != nil {
			jsonutil.obj_set(&entry, "line", jsonutil.json_int(i64(sym.range.start.line)))
		}
		if include_body && sym.has_body {
			jsonutil.obj_set(&entry, "body", jsonutil.json_string(sym.body))
		}
		if include_info && e.info != "" {
			jsonutil.obj_set(&entry, "info", jsonutil.json_string(e.info))
		}
		items[i] = json.Value(json.Object(entry))
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "items", jsonutil.json_array(items, ctx.allocator))
	return json.Value(json.Object(out)), nil
}

handle_symbol_find_declaration :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d, derr := symbol_lsp_ready(ctx)
	if derr != nil {
		return nil, derr
	}
	name_path, rel, err := symbol_edit_target(ctx, params)
	if err != nil {
		return nil, err
	}

	entries, rerr := svc.symbol_lsp_find_declaration(d.lsp_src, name_path, rel, ctx.allocator, ctx.token)
	if rerr != nil {
		return nil, rerr
	}

	items := make([]json.Value, len(entries), ctx.allocator)
	for i in 0..<len(entries) {
		e := entries[i]
		entry := jsonutil.json_object(5, ctx.allocator)
		jsonutil.obj_set(&entry, "name", jsonutil.json_string(e.name))
		jsonutil.obj_set(&entry, "kind", jsonutil.json_string(symbol.kind_name(e.kind)))
		jsonutil.obj_set(&entry, "relative_path", jsonutil.json_string(e.rel_path))
		jsonutil.obj_set(&entry, "line", jsonutil.json_int(i64(e.line)))
		jsonutil.obj_set(&entry, "col", jsonutil.json_int(i64(e.col)))
		items[i] = json.Value(json.Object(entry))
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "items", jsonutil.json_array(items, ctx.allocator))
	return json.Value(json.Object(out)), nil
}

handle_symbol_rename :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d, derr := symbol_lsp_ready(ctx)
	if derr != nil {
		return nil, derr
	}
	name_path, rel, err := symbol_edit_target(ctx, params)
	if err != nil {
		return nil, err
	}
	new_name, nerr := file_require_str(ctx, params, "new_name")
	if nerr != nil {
		return nil, nerr
	}

	summary, rerr := svc.symbol_lsp_rename(d.lsp_src, d.ed, name_path, rel, new_name, ctx.allocator, ctx.token)
	if rerr != nil {
		return nil, rerr
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "summary", jsonutil.json_string(summary))
	return json.Value(json.Object(out)), nil
}

handle_symbol_delete :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d, derr := symbol_lsp_ready(ctx)
	if derr != nil {
		return nil, derr
	}
	name_path, nerr := file_require_str(ctx, params, "name_path_pattern")
	if nerr != nil {
		return nil, nerr
	}
	rel, rerr2 := file_require_str(ctx, params, "relative_path")
	if rerr2 != nil {
		return nil, rerr2
	}
	include_comments := false
	if v, p, e := file_opt_bool(ctx, params, "include_comments"); e != nil {
		return nil, e
	} else if p {
		include_comments = v
	}

	refusal, delerr := svc.symbol_lsp_delete(d.lsp_src, d.ed, name_path, rel, include_comments, ctx.allocator, ctx.token)
	if delerr != nil {
		return nil, delerr
	}
	if refusal != "" {
		out := jsonutil.json_object(1, ctx.allocator)
		jsonutil.obj_set(&out, "refusal", jsonutil.json_string(refusal))
		return json.Value(json.Object(out)), nil
	}
	return empty_ok(ctx), nil
}
