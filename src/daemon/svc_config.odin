// The svc.config/* family: the session-side write surface for
// .aubade/project.jsonc. Both methods are mutating (read-only sessions
// are refused at the boundary) and share one discipline: build the
// candidate bytes with the format-preserving JSONC editor, refuse
// anything the loader would reject (unknown key, wrong value shape,
// unparseable result) with the file untouched, write, then live-apply
// the language-server keys through the same swap langserver/reload
// performs. Every other key takes effect at the next session by design
// (visibility layers, read_only, editor settings are start-fixed) — the
// result's effect line names which is which.
package daemon

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"

import "src:config"
import "src:jsonutil"
import "src:platform"
import "src:svc"
import "src:util"

register_config_methods :: proc(t: ^svc.Table) {
	svc.table_register_mutating(t, svc.METHOD_CONFIG_SET, handle_config_set)
	svc.table_register_mutating(t, svc.METHOD_CONFIG_DELETE, handle_config_delete)
}

// Keys whose edits the daemon can apply to the live manager without a
// reconnect — exactly the set resolve_language_settings re-reads.
CONFIG_LIVE_KEYS :: []string{
	"language_servers",
	"language_server_commands",
	"language_server_options",
	"additional_workspace_folders",
}

// Map-valued keys where a member-scoped write (one language's entry)
// makes sense; every other key is written whole.
CONFIG_MEMBER_KEYS :: []string{
	"language_server_commands",
	"language_server_options",
}

handle_config_set :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	key, err := file_require_str(ctx, params, "key")
	if err != nil {
		return nil, err
	}
	value, vpresent, verr := file_opt_str(ctx, params, "value")
	if verr != nil {
		return nil, verr
	}
	if !vpresent || value == "" {
		return nil, svc.wrapped_err(
			.Invalid,
			"value is required (JSON text: an object, array, string, number, boolean, or null)",
			ctx.allocator,
		)
	}
	member, mpresent, merr := file_opt_str(ctx, params, "member")
	if merr != nil {
		return nil, merr
	}
	if !mpresent {
		member = ""
	}
	return config_write(ctx, key, member, value)
}

handle_config_delete :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	key, err := file_require_str(ctx, params, "key")
	if err != nil {
		return nil, err
	}
	member, mpresent, merr := file_opt_str(ctx, params, "member")
	if merr != nil {
		return nil, merr
	}
	if !mpresent {
		member = ""
	}
	return config_write(ctx, key, member, "")
}

// config_write performs the validated edit of .aubade/project.jsonc.
// value == "" means removal. The daemon-side config_mu serializes the
// read-modify-write across concurrent children; a refusal at any point
// (unknown key, bad member usage, editor failure, loader validation,
// write failure) leaves the file untouched.
config_write :: proc(
	ctx:    ^svc.Svc_Ctx,
	key:    string,
	member: string,
	value:  string,
) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user

	if !config.project_key_known(key) {
		return nil, svc.wrapped_err(
			.Invalid,
			strings.concatenate(
				{
					"unknown project configuration key: ",
					key,
					" — config_get with include_schema documents every key",
				},
				ctx.allocator,
			),
			ctx.allocator,
		)
	}
	if member != "" && !slice.contains(CONFIG_MEMBER_KEYS, key) {
		return nil, svc.wrapped_err(
			.Invalid,
			strings.concatenate(
				{"member is only valid for the map-valued keys ", util.quoted_join(CONFIG_MEMBER_KEYS, " and ", "", ctx.allocator)},
				ctx.allocator,
			),
			ctx.allocator,
		)
	}

	sync.mutex_lock(&d.config_mu)
	defer sync.mutex_unlock(&d.config_mu)

	global, _, gerr := config.load_global(d.cfg.home, ctx.allocator)
	managed_location := ""
	if gerr == nil {
		managed_location = global.project_aubade_folder_location
	}
	managed := config.managed_dir_for(d.cfg.project_root, managed_location, ctx.allocator)
	cfg_path := platform.project_config_path(managed, ctx.allocator)

	created := false
	data: []u8
	switch util.read_gate(cfg_path, config.MAX_CONFIG_BYTES) {
	case .Missing:
		if value == "" {
			// Nothing to remove from a file that does not exist.
			return config_write_result(ctx, key, member, .Absent, false, false, 0, "", false), nil
		}
		created = true
		bootstrap := "{\n}"
		data = transmute([]u8)bootstrap
	case .Not_Regular:
		return nil, svc.wrapped_err(
			.Invalid,
			strings.concatenate({"cannot edit ", cfg_path, ": not a regular file"}, ctx.allocator),
			ctx.allocator,
		)
	case .Too_Large:
		return nil, svc.wrapped_err(
			.Invalid,
			strings.concatenate(
				{"cannot edit ", cfg_path, ": the file exceeds the config size limit (", util.int_to_dec(config.MAX_CONFIG_BYTES, ctx.allocator), " bytes)"},
				ctx.allocator,
			),
			ctx.allocator,
		)
	case .Ok:
		read, rerr := os.read_entire_file_from_path(cfg_path, ctx.allocator)
		if rerr != nil {
			return nil, svc.wrapped_err(
				.Internal,
				strings.concatenate({"cannot read ", cfg_path}, ctx.allocator),
				ctx.allocator,
			)
		}
		data = read
	}

	path := []string{}
	name := key
	if member != "" {
		path = []string{key}
		name = member
	}

	edited: []u8
	action := Config_Write_Action.Absent
	changed := false
	if value != "" {
		upserted, edit_action, ok := config.edit_upsert_member(data, path, name, value, ctx.allocator)
		if !ok {
			return nil, svc.wrapped_err(
				.Invalid,
				strings.concatenate(
					{
						"cannot edit ",
						cfg_path,
						": the file does not parse as a JSONC object — fix it by hand first",
					},
					ctx.allocator,
				),
				ctx.allocator,
			)
		}
		edited = upserted
		changed = edit_action != .Unchanged
		switch edit_action {
		case .Inserted:
			action = .Inserted
		case .Replaced:
			action = .Replaced
		case .Unchanged:
			action = .Unchanged
		}
	} else {
		removed_bytes, removed, ok := config.edit_remove_member(data, path, name, ctx.allocator)
		if !ok {
			return nil, svc.wrapped_err(
				.Invalid,
				strings.concatenate(
					{
						"cannot edit ",
						cfg_path,
						": the file does not parse as a JSONC object — fix it by hand first",
					},
					ctx.allocator,
				),
				ctx.allocator,
			)
		}
		edited = removed_bytes
		changed = removed
		action = .Removed
		if !removed {
			action = .Absent
		}
	}

	if !changed {
		// Nothing was written; nothing needs applying or reporting beyond
		// the no-op itself (the local-override check below still runs so
		// the caller learns why the current value may not be effective).
		return config_write_result(
			ctx, key, member, action, false, false, 0, "",
			project_local_overrides_key(d, managed, key, ctx.allocator),
		), nil
	}

	if verr := config.validate_project_data(edited, ctx.allocator); verr != nil {
		return nil, svc.wrapped_err(
			.Invalid,
			strings.concatenate(
				{
					"rejected, the file was not changed — the edited config would not load: ",
					platform.err_message(verr, ctx.allocator),
				},
				ctx.allocator,
			),
			ctx.allocator,
		)
	}

	if created {
		// make_directory_all reports an error for a directory that already
		// exists (the daemon may have materialized .aubade earlier) — that
		// case is success here (daemon_init's tolerance).
		if mkerr := os.make_directory_all(managed, {.Read_User, .Write_User, .Execute_User}); mkerr != nil &&
		   !os.exists(managed) {
			return nil, svc.wrapped_err(
				.Internal,
				strings.concatenate({"cannot create ", managed}, ctx.allocator),
				ctx.allocator,
			)
		}
	}
	// Atomic publish (tmp + fsync + rename) under the config_mu held for
	// the whole read-modify-write: a crash or disk-full mid-write leaves the
	// previous project.jsonc intact instead of a truncated or empty one.
	// The mode matches what `project create` publishes the same file with.
	if werr := platform.atomic_write(
		cfg_path,
		edited,
		{.Read_User, .Write_User, .Read_Group, .Read_Other},
	); werr != nil {
		return nil, svc.wrapped_err(
			.Internal,
			strings.concatenate({"cannot write ", cfg_path}, ctx.allocator),
			ctx.allocator,
		)
	}

	live := slice.contains(CONFIG_LIVE_KEYS, key)
	live_applied := false
	stopped := 0
	apply_error := ""
	if live {
		_, apply_stopped, aerr := apply_language_settings(d, ctx.token, ctx.allocator)
		if aerr != nil {
			apply_error = platform.err_message(aerr, ctx.allocator)
		} else {
			live_applied = true
			stopped = apply_stopped
		}
	}

	return config_write_result(
		ctx, key, member, action, created, live_applied, stopped, apply_error,
		project_local_overrides_key(d, managed, key, ctx.allocator),
	), nil
}

// Config_Write_Action is the config-write family's outcome vocabulary; the
// wire renders it through CONFIG_WRITE_ACTION_NAMES, its one spelling table.
Config_Write_Action :: enum {
	Inserted,  // an upsert added the member
	Replaced,  // an upsert replaced a same-named member's value
	Unchanged, // the value was already in effect; the file stayed as-is
	Removed,   // a removal deleted the member
	Absent,    // a removal found nothing to delete
}

CONFIG_WRITE_ACTION_NAMES :: []string{"inserted", "replaced", "unchanged", "removed", "absent"}

config_write_action_string :: proc(action: Config_Write_Action) -> string {
	names := CONFIG_WRITE_ACTION_NAMES
	return names[cast(int)action]
}

// config_write_result assembles the family's wire envelope. effect is the
// single-sourced classification of what the write changed: applied live,
// next-session-only, or a live-apply failure after a successful write
// (live keys always apply — a live key without live_applied and without
// apply_error cannot occur, the absent/unchanged actions answer first).
config_write_result :: proc(
	ctx:            ^svc.Svc_Ctx,
	key:            string,
	member:         string,
	action:         Config_Write_Action,
	created:        bool,
	live_applied:   bool,
	stopped:        int,
	apply_error:    string,
	local_override: bool,
) -> json.Value {
	display := key
	if member != "" {
		display = strings.concatenate({key, ".", member}, ctx.allocator)
	}
	effect := ""
	switch action {
	case .Absent:
		effect = "nothing to remove — the config has no such member"
	case .Unchanged:
		effect = "the value was already in effect"
	case .Inserted, .Replaced, .Removed:
		// All three changed the file; the effect now depends only on
		// how the live apply landed.
		if apply_error != "" {
			effect = strings.concatenate(
				{
					"written, but the live apply failed: ",
					apply_error,
					" — the daemon keeps its current settings; call langserver_reload after fixing, or start a new session",
				},
				ctx.allocator,
			)
		} else if live_applied {
			effect = fmt.aprintf(
				"applied live (language servers were reset; %d stopped, they restart on demand with the new settings)",
				stopped,
				allocator = ctx.allocator,
			)
		} else {
			effect = "takes effect at the next session (the daemon reads this key only at startup)"
		}
	}
	obj := jsonutil.json_object(6, ctx.allocator)
	jsonutil.obj_set(&obj, "key", jsonutil.json_string(display))
	jsonutil.obj_set(&obj, "action", jsonutil.json_string(config_write_action_string(action)))
	jsonutil.obj_set(&obj, "created", jsonutil.json_bool(created))
	jsonutil.obj_set(&obj, "effect", jsonutil.json_string(effect))
	jsonutil.obj_set(&obj, "local_override", jsonutil.json_bool(local_override))
	jsonutil.obj_set(&obj, "stopped", jsonutil.json_int(i64(stopped)))
	return json.Value(json.Object(obj))
}

// project_local_overrides_key reports whether project.local.jsonc carries
// the key — the local file replaces a key whole, so a write to
// project.jsonc has no visible effect until the local copy drops it.
project_local_overrides_key :: proc(d: ^Daemon, managed: string, key: string, a: mem.Allocator) -> bool {
	local_path := platform.project_local_path(managed, a)
	if util.read_gate(local_path, config.MAX_CONFIG_BYTES) != .Ok {
		// Missing, non-regular, or oversized: the loader treats the local
		// file as absent in every one of those states, so no override.
		return false
	}
	data, rerr := os.read_entire_file_from_path(local_path, context.temp_allocator)
	if rerr != nil {
		return false
	}
	value, perr := config.jsonc_parse(data, context.temp_allocator)
	if perr != nil {
		return false
	}
	obj, is_obj := jsonutil.as_object(value)
	if !is_obj {
		return false
	}
	_, has := obj[key]
	return has
}
