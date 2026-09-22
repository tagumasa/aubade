// `aubade prompt` — the hostless prompt consumers: `render` builds the
// system prompt an MCP child would serve for a project (config
// context/modes applied, the folded tool set, global memories, tracker
// summary; --cc-override renders the Claude Code system-prompt override
// instead), `list`/`show` present the templates, and the `override`
// family (list/create/edit/delete) manages the user's template files
// under $AUBADE_HOME/prompt_templates.
package cli

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "src:config"
import "src:daemon"
import "src:memory"
import "src:platform"
import "src:prompt"
import "src:session"
import "src:store"
import "src:tools"
import "src:svc"
import "src:tracker"

PROMPT_SUBCMDS :: []Sub_Cmd_Entry{
	{name = "render",   run = prompt_render_cmd},
	{name = "list",     run = prompt_list_cmd},
	{name = "show",     run = prompt_show_cmd},
	{name = "override", run = prompt_override_cmd},
}

run_prompt_cmd :: proc(args: []string, g: ^Globals, version: string) -> int {
	return run_subcommands("prompt", PROMPT_SUBCMDS, args, g)
}

// --- render --------------------------------------------------------------------

prompt_render_cmd :: proc(args: []string, g: ^Globals) -> int {
	contexts := make([dynamic]string, 0, 2, context.allocator)
	defer delete(contexts)
	modes := make([dynamic]string, 0, 4, context.allocator)
	defer delete(modes)
	only_instructions := false
	cc_override := false
	pos := make([dynamic]string, 0, 1, context.temp_allocator)

	i := 0
	for i < len(args) {
		handled, ferr := parse_context_mode_flag(args[:], &i, &contexts, &modes)
		if handled {
			if ferr != "" {
				return usage_error("prompt render", ferr)
			}
			i += 1
			continue
		}
		switch args[i] {
		case "--only-instructions":
			only_instructions = true
		case "--cc-override":
			cc_override = true
		case:
			if strings.has_prefix(args[i], "-") {
				return usage_error("prompt render", strings.concatenate({"unknown flag \"", args[i], "\""}, context.temp_allocator))
			}
			append(&pos, args[i])
		}
		i += 1
	}
	if cc_override {
		// The CC override template targets agents outside this project's
		// session: no project, context, or mode applies.
		if len(pos) > 0 || len(contexts) > 0 || len(modes) > 0 {
			return usage_error("prompt render", "--cc-override takes no project, context, or mode")
		}
		return prompt_cc_override_render()
	}
	if len(pos) > 1 {
		return usage_error("prompt render", "at most one project path is allowed")
	}
	if len(pos) == 1 {
		g.project = pos[0]
	}

	report, code := prompt_render_report(g, contexts[:], modes[:], only_instructions, context.temp_allocator)
	if code != 0 {
		return code
	}
	fmt.println(report)
	return 0
}

// prompt_render_report assembles the template inputs the way the
// reference's CreateSystemPrompt does — the folded (exposed) tool names,
// the context and mode prompts (rendered through the template engine
// with the tool lists, so user prompts may carry tool conditionals), the
// global memories JSON, and the tracker's one-line summary — then
// renders the system_prompt template. The result is wrapped in the
// prefix/postfix lines unless only_instructions is set.
prompt_render_report :: proc(
	g: ^Globals,
	contexts, modes: []string,
	only_instructions: bool,
	a: mem.Allocator,
) -> (string, int) {
	root, code := resolve_project_root("prompt render", g)
	if code != 0 {
		return "", code
	}
	home := platform.aubade_home(context.temp_allocator)

	sel := config.Stack_Selection{project_root = root, mode_names = modes}
	if len(contexts) > 0 {
		sel.context_name = contexts[len(contexts) - 1]
	}
	stack, serr := config.stack_build(sel, home, context.allocator)
	if serr != nil {
		fmt.eprintln(strings.concatenate(
			{"aubade prompt render: config stack failed: ", platform.err_message(serr, context.temp_allocator)},
			context.temp_allocator,
		))
		return "", 1
	}
	defer config.stack_destroy(stack)

	layers := session.visibility_layers(stack, context.allocator)
	defer delete(layers, context.allocator)
	vis := tools.fold_visibility(tools.cap_all(), stack.project.read_only, layers, nil)

	// Visible tool names, sorted (the exposed-set shape); markers among
	// them additionally surface their MARKER names — the templates test
	// 'ToolMarkerSymbolicRead' &c., never the tool names themselves.
	available_tools, marker_names := tools.visible_names(vis, a)

	// Context and mode prompts go through the engine with the tool lists
	// (FormatPrompt parity; the built-ins carry no markup, user files may).
	vars: prompt.Template_Vars
	prompt.template_vars_init(&vars, context.temp_allocator)
	defer prompt.template_vars_destroy(&vars)
	prompt.template_set_list(&vars, "available_tools", available_tools)
	prompt.template_set_list(&vars, "available_markers", marker_names[:])

	inputs: prompt.Render_Inputs
	inputs.available_tools = available_tools
	inputs.available_markers = marker_names[:]
	inputs.context_prompt = prompt.render_prompt_text(stack.ctx.prompt, &vars, a)
	mode_prompts := make([dynamic]string, 0, len(stack.modes), a)
	for mi in 0..<len(stack.modes) {
		body := prompt.render_prompt_text(stack.modes[mi].prompt, &vars, a)
		if body != "" {
			append(&mode_prompts, body)
		}
	}
	inputs.mode_prompts = mode_prompts[:]

	// Global memories: the same two-bucket listing the memories CLI
	// serves, marshalled as the {"memories": [...],
	// "read_only_memories": [...]} dict (keys omitted when empty).
	if mf, mcode := memories_open("prompt render", g); mcode == 0 {
		inputs.global_memories = prompt_global_memories_json(mf, a)
		memories_close(mf)
	}

	// Tracker summary: quiet — a project without a tracker store simply
	// renders without the line.
	inputs.tracker_summary = prompt_tracker_summary(root, a)

	rendered, ok := prompt.render_system_prompt(home, &inputs, a)
	if !ok {
		fmt.eprintln("aubade prompt render: template render failed")
		return "", 1
	}

	if only_instructions {
		return rendered, 0
	}
	return strings.concatenate(
		{
			"You will receive access to Aubade's symbolic tools. Below are instructions for using them, take them into account.\n",
			rendered,
			"\nYou begin by acknowledging that you understood the above instructions and are ready to receive tasks.\n",
		},
		a,
	), 0
}

// prompt_global_memories_json renders the global memories dict from the
// hostless memory files; both buckets empty yields "" (the template
// omits the line entirely).
prompt_global_memories_json :: proc(mf: ^svc.Memory_Files, a: mem.Allocator) -> string {
	list, _ := svc.memory_list(mf, memory.GLOBAL_TOPIC, context.temp_allocator) // the constant topic cannot fail validation
	defer memory.memories_list_destroy(&list)
	return prompt.global_memories_json(list.memories[:], list.read_only_memories[:], a)
}

// prompt_tracker_summary opens the project's event store directly (the
// tracker CLI's read-only path) and renders the one-line open summary;
// any missing store or fold failure yields "".
prompt_tracker_summary :: proc(root: string, a: mem.Allocator) -> string {
	db_path := daemon.project_db_path(root, platform.aubade_home(context.temp_allocator), context.temp_allocator)
	if !os.exists(db_path) {
		return ""
	}
	db, err := store.db_open(db_path, context.allocator)
	if err != nil {
		return ""
	}
	m := new(tracker.Manager, context.allocator)
	// snapshots=false: read-only CLI use — restore when a daemon-written
	// snapshot exists, never write one.
	if terr := tracker.manager_init(m, db, cli_wall_ns, 0, 1, false, context.allocator); terr != nil {
		free(m)
		store.db_close(db)
		return ""
	}
	summary := tracker.manager_open_summary(m, platform.wall_ms(), a)
	tracker.manager_destroy(m)
	free(m)
	store.db_close(db)
	return summary
}

// --- cc-override ----------------------------------------------------------------

// prompt_override_cmd dispatches the override family.
prompt_override_cmd :: proc(args: []string, g: ^Globals) -> int {
	return run_subcommands("prompt override", PROMPT_OVERRIDE_SUBCOMMANDS, args, g)
}

PROMPT_OVERRIDE_SUBCOMMANDS :: []Sub_Cmd_Entry{
	{name = "list",   run = prompt_override_list_cmd},
	{name = "create", run = prompt_create_override_cmd},
	{name = "edit",   run = prompt_edit_override_cmd},
	{name = "delete", run = prompt_delete_override_cmd},
}

// prompt_override_list_cmd lists the user's template overrides.
prompt_override_list_cmd :: proc(args: []string, g: ^Globals) -> int {
	if len(args) > 0 {
		return usage_error("prompt override list", "takes no arguments")
	}
	home := platform.aubade_home(context.temp_allocator)
	dir := prompt_template_dir(home, context.temp_allocator)
	found := false
	entries, derr := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if derr == nil {
		for e in entries {
			if strings.has_suffix(e.name, ".tmpl") {
				if !found {
					fmt.println("Prompt overrides:")
					found = true
				}
				eparts := []string{dir, e.name}
				path, _ := filepath.join(eparts, context.temp_allocator)
				fmt.println(strings.concatenate({"  ", path}, context.temp_allocator))
			}
		}
		os.file_info_slice_delete(entries, context.temp_allocator)
	}
	if !found {
		fmt.println("No prompt overrides.")
	}
	return 0
}

// prompt_cc_override_render renders the Claude Code system-prompt override
// with the fixed marker/tool pair (the override targets agents that
// always get the symbolic read tools).
prompt_cc_override_render :: proc() -> int {
	home := platform.aubade_home(context.temp_allocator)

	inputs: prompt.Render_Inputs
	inputs.available_tools = make([]string, 2, context.temp_allocator)
	// Tool names go through the table's ID accessor — the table and the
	// rendered override cannot drift apart.
	inputs.available_tools[0] = tools.tool_name(.File_Search)
	inputs.available_tools[1] = tools.tool_name(.Symbol_Find)
	inputs.available_markers = make([]string, 1, context.temp_allocator)
	inputs.available_markers[0] = "ToolMarkerSymbolicRead"

	rendered, ok := prompt.render_named(home, "cc_system_prompt_override", &inputs, context.temp_allocator)
	if !ok {
		fmt.eprintln("aubade prompt render: cc override template render failed")
		return 1
	}
	fmt.println(rendered)
	return 0
}

// --- template listing / overrides ----------------------------------------------

prompt_list_cmd :: proc(args: []string, g: ^Globals) -> int {
	if len(args) > 0 {
		return usage_error("prompt list", "takes no arguments")
	}
	home := platform.aubade_home(context.temp_allocator)

	lines := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&lines, "Prompts:")
	names := prompt.template_list_names(home, context.temp_allocator)
	for n in names {
		append(&lines, strings.concatenate({" * '", n, "'"}, context.temp_allocator))
	}
	delete(names, context.temp_allocator)

	out, _ := strings.join(lines[:], "\n", context.temp_allocator)
	fmt.println(out)
	return 0
}

prompt_show_cmd :: proc(args: []string, g: ^Globals) -> int {
	if len(args) != 1 {
		return usage_error("prompt show", "requires exactly one template name")
	}
	home := platform.aubade_home(context.temp_allocator)
	body, ok := prompt.template_by_name(home, args[0], context.temp_allocator)
	if !ok {
		fmt.eprintf("aubade prompt show: unknown template %q\n", args[0])
		return 1
	}
	fmt.print(body)
	if !strings.has_suffix(body, "\n") {
		fmt.println()
	}
	return 0
}

prompt_create_override_cmd :: proc(args: []string, g: ^Globals) -> int {
	if len(args) != 1 {
		return usage_error("prompt override create", "requires exactly one template name")
	}
	name := prompt_override_name(args[0])
	if name == "" {
		return usage_error("prompt override create", "invalid template name")
	}
	home := platform.aubade_home(context.temp_allocator)
	dir := prompt_template_dir(home, context.temp_allocator)
	pparts := []string{dir, strings.concatenate({name, ".tmpl"}, context.temp_allocator)}
	path, _ := filepath.join(pparts, context.temp_allocator)
	if os.exists(path) {
		fmt.eprintf("aubade prompt override create: %s already exists\n", path)
		return 1
	}
	if err := os.make_directory_all(dir); err != nil && !os.is_directory(dir) {
		fmt.eprintf("aubade prompt override create: cannot create %s\n", dir)
		return 1
	}
	// A fresh override starts from the built-in body when one exists (the
	// user edits a working copy); an unknown name gets an empty file.
	body := ""
	if builtin, bok := prompt.template_builtin(name); bok {
		body = builtin
	}
	if !write_text_file("prompt override create", path, body) {
		return 1
	}
	fmt.printf("Created override at %s\n", path)
	return open_in_editor("prompt override create", path) ? 0 : 1
}

prompt_edit_override_cmd :: proc(args: []string, g: ^Globals) -> int {
	if len(args) != 1 {
		return usage_error("prompt override edit", "requires exactly one template name")
	}
	name := prompt_override_name(args[0])
	if name == "" {
		return usage_error("prompt override edit", "invalid template name")
	}
	home := platform.aubade_home(context.temp_allocator)
	dir := prompt_template_dir(home, context.temp_allocator)
	pparts := []string{dir, strings.concatenate({name, ".tmpl"}, context.temp_allocator)}
	path, _ := filepath.join(pparts, context.temp_allocator)
	if !os.exists(path) {
		fmt.eprintf(
			"aubade prompt override edit: override file %q not found. Create it with: aubade prompt override create %s\n",
			name, name,
		)
		return 1
	}
	return open_in_editor("prompt override edit", path) ? 0 : 1
}

prompt_delete_override_cmd :: proc(args: []string, g: ^Globals) -> int {
	if len(args) != 1 {
		return usage_error("prompt override delete", "requires exactly one template name")
	}
	name := prompt_override_name(args[0])
	if name == "" {
		return usage_error("prompt override delete", "invalid template name")
	}
	home := platform.aubade_home(context.temp_allocator)
	dir := prompt_template_dir(home, context.temp_allocator)
	pparts := []string{dir, strings.concatenate({name, ".tmpl"}, context.temp_allocator)}
	path, _ := filepath.join(pparts, context.temp_allocator)
	if !os.exists(path) {
		fmt.eprintf("aubade prompt override delete: override file %q not found\n", name)
		return 1
	}
	if rerr := os.remove(path); rerr != nil {
		fmt.eprintf("aubade prompt override delete: cannot remove %s\n", path)
		return 1
	}
	fmt.printf("Deleted override file %q.\n", name)
	return 0
}

// prompt_override_name validates an override name, tolerating an
// explicit ".tmpl" suffix.
prompt_override_name :: proc(raw: string) -> string {
	name := raw
	if strings.has_suffix(name, ".tmpl") {
		name = name[:len(name) - 5]
	}
	if !resource_name_safe(name) {
		return ""
	}
	return name
}

prompt_template_dir :: proc(home: string, a: mem.Allocator) -> string {
	parts := []string{home, prompt.PROMPT_TEMPLATES_DIR}
	dir, _ := filepath.join(parts, a)
	return dir
}
