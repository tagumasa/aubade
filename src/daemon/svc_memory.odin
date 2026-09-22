// The svc.memory/* handlers: the memory family's parent side. list/read
// are reads; write/replace/rename/delete mutate the project's memory
// files and register as mutating, so read-only projects refuse them at
// the boundary. The Memory_Files state is built once per project from
// the merged config patterns (project lists append to the global ones,
// the shell-command merge rule) and never refuses a daemon start — a
// config load failure means no patterns, not no memories.
package daemon

import "core:encoding/json"
import "core:mem"
import "core:strings"

import "src:config"
import "src:jsonutil"
import "src:platform"
import "src:regex"
import "src:svc"
import "src:util"

register_memory_methods :: proc(t: ^svc.Table) {
	svc.table_register(t, svc.METHOD_MEMORY_LIST, handle_memory_list)
	svc.table_register(t, svc.METHOD_MEMORY_READ, handle_memory_read)
	svc.table_register_mutating(t, svc.METHOD_MEMORY_WRITE, handle_memory_write)
	svc.table_register_mutating(t, svc.METHOD_MEMORY_REPLACE, handle_memory_replace)
	svc.table_register_mutating(t, svc.METHOD_MEMORY_RENAME, handle_memory_rename)
	svc.table_register_mutating(t, svc.METHOD_MEMORY_DELETE, handle_memory_delete)
}

// memory_files_for_project builds the daemon-owned memory state: the
// project and global roots plus the merged read-only/ignored pattern
// lists (global first, project appended). Load failures fall back to
// the empty lists — the daemon starts with or without readable config.
memory_files_for_project :: proc(d: ^Daemon) -> ^svc.Memory_Files {
	mf := new(svc.Memory_Files, d.allocator)
	{
		// Block scope: the arena dies at the closing brace, after
		// memory_files_init has cloned everything it needs.
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena, d.allocator)
		// A defer inside a block fires at block exit — exactly the scope
		// this arena must die in (after memory_files_init's clones).
		defer mem.dynamic_arena_destroy(&arena)
		a := mem.dynamic_arena_allocator(&arena)

		global, _, gerr := config.load_global(d.cfg.home, a)
		project, _, perr := config.load_project_for_root(d.cfg.project_root, d.cfg.home, a)

		g_ro, g_ig: []string
		if gerr == nil {
			g_ro = global.shared.read_only_memory_patterns
			g_ig = global.shared.ignored_memory_patterns
		}
		p_ro, p_ig: []string
		if perr == nil {
			p_ro = project.shared.read_only_memory_patterns
			p_ig = project.shared.ignored_memory_patterns
		}
		ro := config.stack_merged_strings(g_ro, p_ro, a)
		ig := config.stack_merged_strings(g_ig, p_ig, a)
		svc.memory_files_init(mf, d.cfg.project_root, d.cfg.home, ro, ig, d.allocator)
	}
	return mf
}

handle_memory_list :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	topic, present, err := file_opt_str(ctx, params, "topic")
	if err != nil {
		return nil, err
	}
	if !present {
		topic = ""
	}

	// The list's strings live on the request arena; the glue frees it
	// with the request (no piecemeal destroy). Path-shaped topics are
	// refused by memory_list itself.
	list, lerr := svc.memory_list(d.mem_files, topic, ctx.allocator)
	if lerr != nil {
		return nil, lerr
	}
	out := jsonutil.json_object(2, ctx.allocator)
	if len(list.memories) > 0 {
		jsonutil.obj_set(&out, "memories", string_array_value(list.memories[:], ctx.allocator))
	}
	if len(list.read_only_memories) > 0 {
		jsonutil.obj_set(
			&out,
			"read_only_memories",
			string_array_value(list.read_only_memories[:], ctx.allocator),
		)
	}
	return json.Value(json.Object(out)), nil
}

// string_array_value renders an owned-string list as a JSON array.
string_array_value :: proc(list: []string, a: mem.Allocator) -> json.Value {
	return jsonutil.json_string_array(list, a)
}

handle_memory_read :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	name, err := file_require_str(ctx, params, "memory_name")
	if err != nil {
		return nil, err
	}
	content, found, lerr := svc.memory_load(d.mem_files, name, ctx.allocator)
	if lerr != nil {
		return nil, lerr
	}
	out := jsonutil.json_object(2, ctx.allocator)
	jsonutil.obj_set(&out, "content", jsonutil.json_string(content))
	jsonutil.obj_set(&out, "found", jsonutil.json_bool(found))
	return json.Value(json.Object(out)), nil
}

handle_memory_write :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	name, err := file_require_str(ctx, params, "memory_name")
	if err != nil {
		return nil, err
	}
	content, cerr := file_present_str(ctx, params, "content")
	if cerr != nil {
		return nil, cerr
	}
	if werr := svc.memory_save(d.mem_files, name, content, ctx.allocator); werr != nil {
		return nil, werr
	}
	return json.Value(json.Object(jsonutil.json_object(0, ctx.allocator))), nil
}

handle_memory_replace :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	name, err := file_require_str(ctx, params, "memory_name")
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
	mode_str, merr := file_present_str(ctx, params, "mode")
	if merr != nil {
		return nil, merr
	}
	mode, mok := regex.replace_mode_from_string(mode_str)
	if !mok {
		return nil, svc.wrapped_err(
			.Invalid,
			strings.concatenate(
				{"mode must be ", util.quoted_join(regex.REPLACE_MODE_NAMES, " or ", "\"", ctx.allocator), ", got: ", mode_str},
				ctx.allocator,
			),
			ctx.allocator,
		)
	}
	allow_multiple := false
	if v, p, berr := file_opt_bool(ctx, params, "allow_multiple_occurrences"); berr != nil {
		return nil, berr
	} else if p {
		allow_multiple = v
	}

	if eerr := svc.memory_edit(d.mem_files, name, needle, repl, mode, allow_multiple, ctx.allocator); eerr != nil {
		return nil, eerr
	}
	return json.Value(json.Object(jsonutil.json_object(0, ctx.allocator))), nil
}

handle_memory_rename :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	old_name, oerr := file_require_str(ctx, params, "old_name")
	if oerr != nil {
		return nil, oerr
	}
	new_name, nerr := file_require_str(ctx, params, "new_name")
	if nerr != nil {
		return nil, nerr
	}
	found, propagated, rerr := svc.memory_rename(d.mem_files, old_name, new_name, ctx.allocator)
	if rerr != nil {
		return nil, rerr
	}
	if !found {
		return nil, svc.wrapped_err(
			.NotFound,
			strings.concatenate({"memory ", old_name, " not found"}, ctx.allocator),
			ctx.allocator,
		)
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "propagated", jsonutil.json_int(i64(propagated)))
	return json.Value(json.Object(out)), nil
}

handle_memory_delete :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	name, err := file_require_str(ctx, params, "memory_name")
	if err != nil {
		return nil, err
	}
	found, derr := svc.memory_delete(d.mem_files, name, ctx.allocator)
	if derr != nil {
		return nil, derr
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "found", jsonutil.json_bool(found))
	return json.Value(json.Object(out)), nil
}
