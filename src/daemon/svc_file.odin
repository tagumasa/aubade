// The svc.file/* handlers: parse the wire params (the tool argument
// names), run the corresponding file op against the daemon's editor, and
// shape the structured response. Text shaping (too-long notices, JSON
// rendering) stays in the tool layer.
package daemon

import "core:encoding/json"
import "core:strings"
import "src:jsonutil"
import "src:platform"
import "src:store"
import "src:svc"

register_file_methods :: proc(t: ^svc.Table) {
	svc.table_register(t, svc.METHOD_FILE_READ, handle_file_read)
	svc.table_register_mutating(t, svc.METHOD_FILE_WRITE, handle_file_write)
	svc.table_register(t, svc.METHOD_FILE_LIST_DIR, handle_file_list_dir)
	svc.table_register(t, svc.METHOD_FILE_FIND, handle_file_find)
	svc.table_register(t, svc.METHOD_FILE_SEARCH, handle_file_search)
	svc.table_register(t, svc.METHOD_FILE_OUTLINE, handle_file_outline)
	svc.table_register_mutating(t, svc.METHOD_FILE_REPLACE, handle_file_replace)
	svc.table_register_mutating(t, svc.METHOD_FILE_INSERT_LINES, handle_file_insert_lines)
	svc.table_register_mutating(t, svc.METHOD_FILE_REPLACE_LINES, handle_file_replace_lines)
	svc.table_register_mutating(t, svc.METHOD_FILE_DELETE_LINES, handle_file_delete_lines)
	svc.table_register_mutating(t, svc.METHOD_FILE_DELETE, handle_file_delete)
	svc.table_register_mutating(t, svc.METHOD_FILE_MOVE, handle_file_move)
}

// --- param parsing --------------------------------------------------------

file_opt_str :: proc(ctx: ^svc.Svc_Ctx, params: json.Value, key: string) -> (val: string, present: bool, err: platform.Err) {
	if v, ok := jsonutil.obj_get(params, key); ok {
		#partial switch x in v {
		case json.String:
			return string(x), true, nil
		case:
			return "", false, param_type_err(ctx, key, "a string")
		}
	}
	return "", false, nil
}

file_opt_int :: proc(ctx: ^svc.Svc_Ctx, params: json.Value, key: string) -> (val: int, present: bool, err: platform.Err) {
	if v, ok := jsonutil.obj_get(params, key); ok {
		#partial switch x in v {
		case json.Integer:
			return int(x), true, nil
		case:
			return 0, false, param_type_err(ctx, key, "an integer")
		}
	}
	return 0, false, nil
}

file_opt_bool :: proc(ctx: ^svc.Svc_Ctx, params: json.Value, key: string) -> (val: bool, present: bool, err: platform.Err) {
	if v, ok := jsonutil.obj_get(params, key); ok {
		#partial switch x in v {
		case json.Boolean:
			return bool(x), true, nil
		case:
			return false, false, param_type_err(ctx, key, "a boolean")
		}
	}
	return false, false, nil
}

// file_opt_str_array extracts an optional array-of-strings parameter onto
// the request arena (the caller never frees it piecemeal).
file_opt_str_array :: proc(ctx: ^svc.Svc_Ctx, params: json.Value, key: string) -> (vals: []string, present: bool, err: platform.Err) {
	if v, ok := jsonutil.obj_get(params, key); ok {
		arr, aok := jsonutil.as_array(v)
		if !aok {
			return nil, false, param_type_err(ctx, key, "an array of strings")
		}
		out := make([dynamic]string, 0, len(arr), ctx.allocator)
		for it in arr {
			#partial switch x in it {
			case json.String:
				append(&out, string(x))
			case:
				return nil, false, param_type_err(ctx, key, "an array of strings")
			}
		}
		return out[:], true, nil
	}
	return nil, false, nil
}

param_type_err :: proc(ctx: ^svc.Svc_Ctx, key: string, expected: string) -> platform.Err {
	return svc.wrapped_err(
		.Invalid,
		strings.concatenate({key, " must be ", expected}, ctx.allocator),
		ctx.allocator,
	)
}

// file_require_str fetches a required string parameter: absent or empty
// fails with "<key> is required".
file_require_str :: proc(ctx: ^svc.Svc_Ctx, params: json.Value, key: string) -> (string, platform.Err) {
	val, present, err := file_opt_str(ctx, params, key)
	if err != nil {
		return "", err
	}
	if !present || val == "" {
		return "", svc.wrapped_err(
			.Invalid,
			strings.concatenate({key, " is required"}, ctx.allocator),
			ctx.allocator,
		)
	}
	return val, nil
}

// file_present_str fetches a string parameter that must be present but
// may be empty — an empty replacement deletes, an empty write truncates.
file_present_str :: proc(ctx: ^svc.Svc_Ctx, params: json.Value, key: string) -> (string, platform.Err) {
	val, present, err := file_opt_str(ctx, params, key)
	if err != nil {
		return "", err
	}
	if !present {
		return "", svc.wrapped_err(
			.Invalid,
			strings.concatenate({key, " is required"}, ctx.allocator),
			ctx.allocator,
		)
	}
	return val, nil
}

// --- handlers -------------------------------------------------------------

handle_file_read :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	rel, err := file_require_str(ctx, params, "relative_path")
	if err != nil {
		return nil, err
	}
	start_line := 0
	if v, p, e := file_opt_int(ctx, params, "start_line"); e != nil {
		return nil, e
	} else if p {
		start_line = v
	}
	end_line := 0
	end_set := false
	if v, p, e := file_opt_int(ctx, params, "end_line"); e != nil {
		return nil, e
	} else if p {
		end_line = v
		end_set = true
	}
	max_chars := 0
	if v, p, e := file_opt_int(ctx, params, "max_answer_chars"); e != nil {
		return nil, e
	} else if p {
		max_chars = v
	}

	res, rerr := svc.file_read(d.ed, &d.file_safety.deny_list, rel, start_line, end_line, end_set, max_chars, ctx.allocator)
	if rerr != nil {
		return nil, rerr
	}
	out := jsonutil.json_object(4, ctx.allocator)
	jsonutil.obj_set(&out, "content", jsonutil.json_string(res.content))
	jsonutil.obj_set(&out, "read_ask", jsonutil.json_bool(res.read_ask))
	jsonutil.obj_set(&out, "truncated", jsonutil.json_bool(res.truncated))
	jsonutil.obj_set(&out, "total_chars", jsonutil.json_int(i64(res.total_chars)))
	return json.Value(json.Object(out)), nil
}

handle_file_outline :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	rel, err := file_require_str(ctx, params, "relative_path")
	if err != nil {
		return nil, err
	}
	path := ""
	if v, p, e := file_opt_str(ctx, params, "path"); e != nil {
		return nil, e
	} else if p {
		path = v
	}
	max_chars := 0
	if v, p, e := file_opt_int(ctx, params, "max_answer_chars"); e != nil {
		return nil, e
	} else if p {
		max_chars = v
	}

	res, oerr := svc.file_outline(d.ed, &d.file_safety.deny_list, rel, path, max_chars, ctx.allocator)
	if oerr != nil {
		return nil, oerr
	}
	out := jsonutil.json_object(6, ctx.allocator)
	jsonutil.obj_set(&out, "content", jsonutil.json_string(res.content))
	jsonutil.obj_set(&out, "mode", jsonutil.json_string(svc.file_outline_mode_string(res.mode)))
	jsonutil.obj_set(&out, "start_line", jsonutil.json_int(i64(res.start_line)))
	jsonutil.obj_set(&out, "end_line", jsonutil.json_int(i64(res.end_line)))
	jsonutil.obj_set(&out, "truncated", jsonutil.json_bool(res.truncated))
	jsonutil.obj_set(&out, "read_ask", jsonutil.json_bool(res.read_ask))
	return json.Value(json.Object(out)), nil
}

handle_file_write :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	rel, err := file_require_str(ctx, params, "relative_path")
	if err != nil {
		return nil, err
	}
	content, cerr := file_present_str(ctx, params, "content")
	if cerr != nil {
		return nil, cerr
	}

	overwrote, werr := svc.file_write(d.ed, rel, content, ctx.allocator)
	if werr != nil {
		return nil, werr
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "overwrote", jsonutil.json_bool(overwrote))
	return json.Value(json.Object(out)), nil
}

handle_file_list_dir :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	rel, _, err := file_opt_str(ctx, params, "relative_path")
	if err != nil {
		return nil, err
	}
	recursive := false
	if v, p, e := file_opt_bool(ctx, params, "recursive"); e != nil {
		return nil, e
	} else if p {
		recursive = v
	}
	skip_ignored := false
	if v, p, e := file_opt_bool(ctx, params, "skip_ignored_files"); e != nil {
		return nil, e
	} else if p {
		skip_ignored = v
	}
	include_line_counts := false
	if v, p, e := file_opt_bool(ctx, params, "include_line_counts"); e != nil {
		return nil, e
	} else if p {
		include_line_counts = v
	}

	ignore := svc.ignore_config_load(d.cfg.project_root, d.cfg.home, ctx.allocator)
	defer svc.spec_release_c_side(ignore.extra)
	res, lerr := svc.file_list_dir(d.ed, rel, recursive, skip_ignored, include_line_counts, ignore, &d.file_safety.deny_list, ctx.allocator, ctx.token)
	if lerr != nil {
		return nil, lerr
	}

	files := make([]json.Value, len(res.files), ctx.allocator)
	for i in 0..<len(res.files) {
		f := res.files[i]
		if !f.has_lines {
			files[i] = jsonutil.json_string(f.name)
			continue
		}
		obj := jsonutil.json_object(2, ctx.allocator)
		jsonutil.obj_set(&obj, "name", jsonutil.json_string(f.name))
		if f.binary {
			jsonutil.obj_set(&obj, "lines", jsonutil.json_string("binary"))
		} else {
			jsonutil.obj_set(&obj, "lines", jsonutil.json_int(i64(f.lines)))
		}
		files[i] = json.Value(json.Object(obj))
	}

	out := jsonutil.json_object(3, ctx.allocator)
	jsonutil.obj_set(&out, "dirs", jsonutil.json_string_array(res.dirs, ctx.allocator))
	jsonutil.obj_set(&out, "files", jsonutil.json_array(files, ctx.allocator))
	jsonutil.obj_set(&out, "truncated", jsonutil.json_bool(res.truncated))
	return json.Value(json.Object(out)), nil
}

handle_file_find :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	mask, err := file_require_str(ctx, params, "file_mask")
	if err != nil {
		return nil, err
	}
	within, _, werr := file_opt_str(ctx, params, "relative_path")
	if werr != nil {
		return nil, werr
	}

	ignore := svc.ignore_config_load(d.cfg.project_root, d.cfg.home, ctx.allocator)
	defer svc.spec_release_c_side(ignore.extra)
	files, truncated, ferr := svc.file_find(d.ed, mask, within, ignore, &d.file_safety.deny_list, ctx.allocator, ctx.token)
	if ferr != nil {
		return nil, ferr
	}
	out := jsonutil.json_object(2, ctx.allocator)
	jsonutil.obj_set(&out, "files", jsonutil.json_string_array(files, ctx.allocator))
	jsonutil.obj_set(&out, "truncated", jsonutil.json_bool(truncated))
	return json.Value(json.Object(out)), nil
}

handle_file_search :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	pattern, err := file_require_str(ctx, params, "substring_pattern")
	if err != nil {
		return nil, err
	}
	req: svc.File_Search_Req
	req.pattern = pattern
	if v, p, e := file_opt_bool(ctx, params, "multiline"); e != nil {
		return nil, e
	} else if p {
		req.multiline = v
	}
	if v, p, e := file_opt_int(ctx, params, "context_lines_before"); e != nil {
		return nil, e
	} else if p {
		req.context_before = v
	}
	if v, p, e := file_opt_int(ctx, params, "context_lines_after"); e != nil {
		return nil, e
	} else if p {
		req.context_after = v
	}
	if v, _, e := file_opt_str(ctx, params, "paths_include_glob"); e != nil {
		return nil, e
	} else {
		req.include_glob = v
	}
	if v, _, e := file_opt_str(ctx, params, "paths_exclude_glob"); e != nil {
		return nil, e
	} else {
		req.exclude_glob = v
	}
	if v, _, e := file_opt_str(ctx, params, "relative_path"); e != nil {
		return nil, e
	} else {
		req.scope_rel = v
	}
	if v, p, e := file_opt_int(ctx, params, "offset"); e != nil {
		return nil, e
	} else if p {
		if v < 0 {
			return nil, svc.wrapped_err(.Invalid, "offset must be non-negative", ctx.allocator)
		}
		req.offset = v
	}
	if v, p, e := file_opt_int(ctx, params, "limit"); e != nil {
		return nil, e
	} else if p {
		if v < 0 {
			return nil, svc.wrapped_err(.Invalid, "limit must be non-negative", ctx.allocator)
		}
		req.limit = v
	}

	ignore := svc.ignore_config_load(d.cfg.project_root, d.cfg.home, ctx.allocator)
	defer svc.spec_release_c_side(ignore.extra)
	matches, total, truncated, serr := svc.file_search(d.ed, req, ignore, &d.file_safety.deny_list, ctx.allocator, ctx.token)
	if serr != nil {
		return nil, serr
	}
	items := make([]json.Value, len(matches), ctx.allocator)
	for i in 0..<len(matches) {
		m := matches[i]
		obj := jsonutil.json_object(3, ctx.allocator)
		jsonutil.obj_set(&obj, "path", jsonutil.json_string(m.path))
		jsonutil.obj_set(&obj, "line", jsonutil.json_int(i64(m.line)))
		jsonutil.obj_set(&obj, "display", jsonutil.json_string(m.display))
		items[i] = json.Value(json.Object(obj))
	}
	out := jsonutil.json_object(3, ctx.allocator)
	jsonutil.obj_set(&out, "matches", jsonutil.json_array(items, ctx.allocator))
	jsonutil.obj_set(&out, "total_matches", jsonutil.json_int(i64(total)))
	jsonutil.obj_set(&out, "truncated", jsonutil.json_bool(truncated))
	return json.Value(json.Object(out)), nil
}

handle_file_replace :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	rel, err := file_require_str(ctx, params, "relative_path")
	if err != nil {
		return nil, err
	}
	needle, nerr := file_present_str(ctx, params, "needle")
	if nerr != nil {
		return nil, nerr
	}
	repl, rerr := file_present_str(ctx, params, "repl")
	if rerr != nil {
		return nil, rerr
	}
	mode, merr := file_require_str(ctx, params, "mode")
	if merr != nil {
		return nil, merr
	}
	allow_multiple := false
	if v, p, e := file_opt_bool(ctx, params, "allow_multiple_occurrences"); e != nil {
		return nil, e
	} else if p {
		allow_multiple = v
	}

	if aerr := svc.file_replace(d.ed, rel, needle, repl, mode, allow_multiple, ctx.allocator); aerr != nil {
		return nil, aerr
	}
	return empty_ok(ctx), nil
}

handle_file_insert_lines :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	rel, err := file_require_str(ctx, params, "relative_path")
	if err != nil {
		return nil, err
	}
	line := 0
	if v, p, e := file_opt_int(ctx, params, "line"); e != nil {
		return nil, e
	} else if p {
		line = v
	}
	content, cerr := file_present_str(ctx, params, "content")
	if cerr != nil {
		return nil, cerr
	}

	if aerr := svc.file_insert_lines(d.ed, rel, line, content, ctx.allocator); aerr != nil {
		return nil, aerr
	}
	return empty_ok(ctx), nil
}

handle_file_replace_lines :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	rel, err := file_require_str(ctx, params, "relative_path")
	if err != nil {
		return nil, err
	}
	start_line := 0
	if v, p, e := file_opt_int(ctx, params, "start_line"); e != nil {
		return nil, e
	} else if p {
		start_line = v
	}
	end_line := 0
	if v, p, e := file_opt_int(ctx, params, "end_line"); e != nil {
		return nil, e
	} else if p {
		end_line = v
	}
	content, cerr := file_present_str(ctx, params, "content")
	if cerr != nil {
		return nil, cerr
	}

	if aerr := svc.file_replace_lines(d.ed, rel, start_line, end_line, content, ctx.allocator); aerr != nil {
		return nil, aerr
	}
	return empty_ok(ctx), nil
}

handle_file_delete_lines :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	rel, err := file_require_str(ctx, params, "relative_path")
	if err != nil {
		return nil, err
	}
	start_line := 0
	if v, p, e := file_opt_int(ctx, params, "start_line"); e != nil {
		return nil, e
	} else if p {
		start_line = v
	}
	end_line := 0
	if v, p, e := file_opt_int(ctx, params, "end_line"); e != nil {
		return nil, e
	} else if p {
		end_line = v
	}

	if aerr := svc.file_delete_lines(d.ed, rel, start_line, end_line, ctx.allocator); aerr != nil {
		return nil, aerr
	}
	return empty_ok(ctx), nil
}

handle_file_delete :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	rel, err := file_require_str(ctx, params, "relative_path")
	if err != nil {
		return nil, err
	}

	if derr := svc.file_delete(d.ed, rel, ctx.allocator); derr != nil {
		return nil, derr
	}
	// The file is gone: drop its index rows now (the normalized key form
	// matches what the indexer stores) instead of waiting out the TTL
	// sweep — symbol_find would keep serving the deleted path.
	if perr := store.delete_symbol_path(d.db, svc.normalize_rel(rel, ctx.allocator)); perr != nil {
		return nil, perr
	}
	return empty_ok(ctx), nil
}

handle_file_move :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	src, serr := file_require_str(ctx, params, "source_relative_path")
	if serr != nil {
		return nil, serr
	}
	dst, derr := file_require_str(ctx, params, "target_relative_path")
	if derr != nil {
		return nil, derr
	}

	if merr := svc.file_move(d.ed, src, dst, ctx.allocator); merr != nil {
		return nil, merr
	}
	// The source path stopped existing: purge its index rows (the target
	// is indexed lazily on its first access, like any other fresh file).
	if perr := store.delete_symbol_path(d.db, svc.normalize_rel(src, ctx.allocator)); perr != nil {
		return nil, perr
	}
	return empty_ok(ctx), nil
}

// empty_ok is the success payload for the mutating ops whose reference
// counterparts answer with a fixed success string (the tool renders it).
empty_ok :: proc(ctx: ^svc.Svc_Ctx) -> json.Value {
	out := jsonutil.json_object(0, ctx.allocator)
	return json.Value(json.Object(out))
}
