// The config overview tool: a read-only snapshot of the session's
// effective configuration — version, project, context and modes, the
// folded tool set grouped by category, and the language-server states.
// Everything comes from the Tool_Ctx identity fields (filled by the
// dispatch host from the session's startup state) plus one parent
// round-trip for the language servers; nothing here re-folds or
// re-parses config, so the overview cannot drift from the fold the
// tools/list gate already uses.
package tools

import "core:mem"
import "core:strings"

import "src:config"
import "src:jsonutil"
import "src:platform"
import "src:svc"
import "src:version"

CONFIG_GET_PARAMS :: []Param_Desc{
	{name = "include_schema", kind = .Bool, description = "Append the annotated project.jsonc template — the reference documenting every project configuration key.", required = false},
}

CONFIG_SET_PARAMS :: []Param_Desc{
	{name = "key", kind = .Str, description = "The project.jsonc member to set — a known key (config_get with include_schema documents every key).", required = true},
	{name = "value", kind = .Str, description = "JSON text for the value: an object, array, string, number, boolean, or null.", required = true},
	{name = "member", kind = .Str, description = "Set one entry inside a map-valued key (language_server_commands or language_server_options) instead of replacing the whole key — the language id for both.", required = false},
}

CONFIG_DELETE_PARAMS :: []Param_Desc{
	{name = "key", kind = .Str, description = "The project.jsonc member to remove.", required = true},
	{name = "member", kind = .Str, description = "Remove one entry inside a map-valued key (language_server_commands or language_server_options) instead of the whole key.", required = false},
}

config_get :: Tool_Desc{
	name        = "config_get",
	title       = "Get current config",
	description = "Print the current configuration of the agent, including the active " +
		"and available projects, tools, contexts, and modes. " +
		"Pass include_schema to also get the annotated project.jsonc template documenting every project configuration key.",
	optional    = false,
	category    = .Config,
	params      = CONFIG_GET_PARAMS,
	needs       = {Cap.Project},
	apply       = config_get_apply,
}

// The config write pair: a validated, format-preserving edit of
// .aubade/project.jsonc — the safe route the guidance texts name first
// (raw file editing is the fallback). Writes refuse unknown keys and any
// value the loader would reject, leaving the file untouched on refusal;
// language-server keys apply live, everything else takes effect at the
// next session (the answer says which).
config_set :: Tool_Desc{
	name        = "config_set",
	title       = "Set a project config key",
	description = "Set one key of .aubade/project.jsonc (or one entry of a map-valued " +
		"key via member). The write is validated — unknown keys and values the " +
		"loader would reject are refused with the file untouched — and preserves " +
		"comments and formatting. Language-server keys " +
		"(language_servers, language_server_commands, language_server_options, " +
		"additional_workspace_folders) apply live to the running daemon; other keys " +
		"take effect at the next session. The answer reports which. " +
		"config_get with include_schema documents every key.",
	can_edit    = true,
	destructive = true,
	optional    = false,
	category    = .Config,
	params      = CONFIG_SET_PARAMS,
	needs       = {Cap.Project, Cap.Svc},
	apply       = config_set_apply,
}

config_delete :: Tool_Desc{
	name        = "config_delete",
	title       = "Remove a project config key",
	description = "Remove one key from .aubade/project.jsonc (or one entry of a " +
		"map-valued key via member), preserving comments and formatting. Removing " +
		"an absent member is a no-op. Language-server keys apply live; other keys " +
		"take effect at the next session. The answer reports which.",
	can_edit    = true,
	destructive = true,
	optional    = false,
	category    = .Config,
	params      = CONFIG_DELETE_PARAMS,
	needs       = {Cap.Project, Cap.Svc},
	apply       = config_delete_apply,
}

// The grouping order of the tool listing is the Category enum's
// declaration order (symbol, file, tracker, memory, ...) — the for-in
// walks it directly, so a new category cannot fall out of the overview.

category_name :: proc(c: Category) -> string {
	switch c {
	case .Symbol:     return "symbol"
	case .File:       return "file"
	case .Tracker:    return "tracker"
	case .Memory:     return "memory"
	case .Shell:      return "shell"
	case .Config:     return "config"
	case .Project:    return "project"
	case .Onboarding: return "onboarding"
	case .Langserver: return "langserver"
	case .Ast:        return "ast"
	case .Incident:   return "incident"
	case .Sprint:     return "sprint"
	case .Shadow:     return "shadow"
	case .Web:        return "web"
	case .Marker:     return "marker"
	}
	return "other"
}

// append_tool_group renders one category's tool names (active or
// inactive) as a "  <category>: a, b, c" block, skipping empty groups.
append_tool_group :: proc(sb: ^strings.Builder, active: Visibility, want_active: bool) {
	table := TOOLS
	for c in Category {
		names := make([dynamic]string, 0, 8, context.temp_allocator)
		for i in 0..<len(table) {
			tid := cast(Tool_ID)i
			in_set := tid in active
			if in_set != want_active {
				continue
			}
			if table[i].category == c {
				append(&names, table[i].name)
			}
		}
		if len(names) == 0 {
			continue
		}
		strings.write_string(sb, "  ")
		strings.write_string(sb, category_name(c))
		strings.write_string(sb, ": ")
		for n, i in names {
			if i > 0 {
				strings.write_string(sb, ", ")
			}
			strings.write_string(sb, n)
		}
		strings.write_string(sb, "\n")
		delete(names)
	}
}

// append_mode_diff lists the selectable modes minus the active ones.
append_mode_diff :: proc(sb: ^strings.Builder, home: string, active: []string, a: mem.Allocator) {
	all := config.list_mode_names(home, a)
	defer delete(all, a)
	inactive := make([dynamic]string, 0, len(all), a)
	for m in all {
		is_active := false
		for act in active {
			if act == m {
				is_active = true
				break
			}
		}
		if !is_active {
			append(&inactive, m)
		}
	}
	if len(inactive) > 0 {
		strings.write_string(sb, "Available but not active modes: ")
		for m, i in inactive {
			if i > 0 {
				strings.write_string(sb, ", ")
			}
			strings.write_string(sb, m)
		}
		strings.write_string(sb, "\n\n")
	}
	delete(inactive)
}

// append_langservers adds the parent's language-server states when the
// link is live (hostless callers simply skip the section).
append_langservers :: proc(ctx: ^Tool_Ctx, sb: ^strings.Builder) {
	if !need_svc(ctx) {
		return
	}
	call := svc.client_langserver_list(ctx.svc_conn, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return
	}
	items_v, ok := jsonutil.obj_get(call.result, "items")
	if !ok {
		return
	}
	items, aok := jsonutil.as_array(items_v)
	if !aok || len(items) == 0 {
		return
	}
	strings.write_string(sb, "Language servers:\n")
	for it in items {
		lang, _ := json_str(it, "language")
		state := "stopped"
		if jsonutil.obj_get_bool(it, "running") {
			state = "running"
		}
		strings.write_string(sb, "  ")
		strings.write_string(sb, lang)
		strings.write_string(sb, ": ")
		strings.write_string(sb, state)
		strings.write_string(sb, "\n")
	}
}

config_get_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	home := platform.aubade_home(ctx.allocator)

	b, berr := strings.builder_make_len_cap(0, 512, ctx.allocator)
	if berr != nil {
		return err_result(ctx, "overview render failed")
	}
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "Current configuration:\n")
	strings.write_string(&b, "Aubade version: ")
	strings.write_string(&b, version.AUBADE_VERSION)
	strings.write_string(&b, "\n")
	if ctx.session != nil {
		strings.write_string(&b, "Log level: ")
		strings.write_string(&b, ctx.session.log_level)
		strings.write_string(&b, "\n")
		if ctx.session.trace_lsp {
			strings.write_string(&b, "Trace LSP communication: on\n")
		}
	}

	strings.write_string(&b, "Active project: ")
	strings.write_string(&b, ctx.project_root)
	strings.write_string(&b, "\n")

	strings.write_string(&b, "Available projects:\n")
	if reg, rerr := config.registry_load(home, ctx.allocator); rerr == nil {
		for p in reg.projects {
			strings.write_string(&b, p)
			strings.write_string(&b, "\n")
		}
		config.registry_destroy(reg, ctx.allocator)
	}

	strings.write_string(&b, "Active context: ")
	if ctx.context_name != "" {
		strings.write_string(&b, ctx.context_name)
	} else {
		strings.write_string(&b, "(none)")
	}
	strings.write_string(&b, "\n")

	strings.write_string(&b, "Active modes: ")
	if len(ctx.mode_names) > 0 {
		for m, i in ctx.mode_names {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, m)
		}
	} else {
		strings.write_string(&b, "(none)")
	}
	strings.write_string(&b, "\n\n")

	append_mode_diff(&b, home, ctx.mode_names, ctx.allocator)

	strings.write_string(
		&b,
		"Active tools (after all exclusions from the project, context, and modes):\n",
	)
	append_tool_group(&b, ctx.visible, true)
	strings.write_string(&b, "Available but not active tools:\n")
	append_tool_group(&b, ctx.visible, false)
	strings.write_string(&b, "\n")

	append_langservers(ctx, &b)

	// The on-demand schema reference: the same annotated template the
	// scaffold writes (single source — the documented keys cannot drift
	// from what `aubade project index` generates).
	if arg_bool(args, "include_schema") {
		strings.write_string(
			&b,
			"\nProject configuration reference — .aubade/project.jsonc " +
			"(local overrides go in project.local.jsonc, which replaces a key whole):\n\n",
		)
		strings.write_string(&b, config.project_template_reference(ctx.allocator))
		strings.write_string(&b, "\n")
	}

	// Clone out of the builder: to_string is a view that dies with it.
	return text_result(ctx, strings.clone(strings.to_string(b), ctx.allocator))
}

// The write pair's shared answer: the daemon's envelope (key, action,
// effect, local_override) rendered as one honest sentence block — what
// changed, whether it is live or next-session, and whether
// project.local.jsonc currently hides the key.
config_write_apply :: proc(
	ctx:    ^Tool_Ctx,
	call:   svc.Client_Call,
) -> Tool_Result {
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	b, berr := strings.builder_make_len_cap(0, 256, ctx.allocator)
	if berr != nil {
		return err_result(ctx, "config write render failed")
	}
	defer strings.builder_destroy(&b)

	key, _ := json_str(call.result, "key")
	action, _ := json_str(call.result, "action")
	effect, _ := json_str(call.result, "effect")

	strings.write_string(&b, "config ")
	strings.write_string(&b, key)
	strings.write_string(&b, ": ")
	strings.write_string(&b, action)
	strings.write_string(&b, ". ")
	strings.write_string(&b, effect)
	strings.write_string(&b, ".")
	if jsonutil.obj_get_bool(call.result, "local_override") {
		strings.write_string(
			&b,
			" NOTE: project.local.jsonc also sets this key and replaces it whole — remove it there for this write to take effect.",
		)
	}
	return text_result(ctx, strings.clone(strings.to_string(b), ctx.allocator))
}

config_set_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_config_set(
		ctx.svc_conn,
		arg_str(args, "key"),
		arg_str(args, "member"),
		arg_str(args, "value"),
		ctx.allocator,
		svc_deadline(ctx),
		ctx.cancel,
	)
	return config_write_apply(ctx, call)
}

config_delete_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_config_delete(
		ctx.svc_conn,
		arg_str(args, "key"),
		arg_str(args, "member"),
		ctx.allocator,
		svc_deadline(ctx),
		ctx.cancel,
	)
	return config_write_apply(ctx, call)
}
