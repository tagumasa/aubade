// `aubade tool` — the hostless visibility consumer: lists what the
// single fold engine would serve for a project (config context/modes
// applied), or shows one tool's declaration and schema. It folds through
// the same engine the MCP child uses — never a second implementation.
package cli

import "core:fmt"
import "core:mem"
import "core:strings"

import "src:config"
import "src:jsonutil"
import "src:platform"
import "src:session"
import "src:tools"
import "src:util"

// Hostless consumers assume the full capability set (tools.cap_all()):
// there is no parent to ask, and the point of the listing is the config
// effect on the table.

// Tool_Flags carries what the shared `aubade tool` flag loop parsed —
// the config-view selectors plus the list-only switches.
Tool_Flags :: struct {
	contexts:      []string,
	modes:         []string,
	all:           bool,
	only_optional: bool,
	quiet:         bool,
}

// Tool_Subcmd is one row of the tool verb table: the usage hint names
// the verb's argument shape, and the refusal message renders from the
// same rows the dispatch walks.
Tool_Subcmd :: struct {
	name: string,
	hint: string,
	run:  proc(g: ^Globals, pos: []string, f: Tool_Flags) -> int,
}

tool_list_sub :: proc(g: ^Globals, pos: []string, f: Tool_Flags) -> int {
	if len(pos) > 0 {
		return usage_error("tool list", "takes no arguments")
	}
	report, code := tool_list_report(g, f.contexts, f.modes, f.all, f.only_optional, f.quiet, context.temp_allocator)
	fmt.println(report)
	return code
}

tool_show_sub :: proc(g: ^Globals, pos: []string, f: Tool_Flags) -> int {
	if len(pos) != 1 {
		return usage_error("tool show", "requires exactly one tool name")
	}
	report, code := tool_show_report(g, pos[0], f.contexts, f.modes, context.temp_allocator)
	fmt.println(report)
	return code
}

TOOL_SUBCMDS :: []Tool_Subcmd{
	{name = "list", hint = "list",         run = tool_list_sub},
	{name = "show", hint = "show <name>",  run = tool_show_sub},
}

// run_tool_cmd dispatches `aubade tool list|show`. Beyond the global
// flags it accepts the same --context/--mode selectors the mcp child
// takes, so a listing can reproduce any session's view; list adds
// --all (ignore the config layers), --only-optional, and --quiet
// (names only).
run_tool_cmd :: proc(args: []string, g: ^Globals, version: string) -> int {
	rest := make([dynamic]string, 0, len(args), context.temp_allocator)
	if !strip_globals(args, g, &rest) {
		return usage_error("tool", "invalid global flag value")
	}

	contexts := make([dynamic]string, 0, 2, context.allocator)
	defer delete(contexts)
	modes := make([dynamic]string, 0, 4, context.allocator)
	defer delete(modes)
	flags: Tool_Flags

	verb := ""
	pos := make([dynamic]string, 0, 2, context.temp_allocator)
	i := 0
	for i < len(rest) {
		handled, ferr := parse_context_mode_flag(rest[:], &i, &contexts, &modes)
		if handled {
			if ferr != "" {
				return usage_error("tool", ferr)
			}
			i += 1
			continue
		}
		switch rest[i] {
		case "--all":
			flags.all = true
		case "--only-optional":
			flags.only_optional = true
		case "--quiet":
			flags.quiet = true
		case:
			if verb == "" {
				verb = rest[i]
			} else {
				append(&pos, rest[i])
			}
		}
		i += 1
	}

	flags.contexts = contexts[:]
	flags.modes = modes[:]
	for e in TOOL_SUBCMDS {
		if e.name == verb {
			return e.run(g, pos[:], flags)
		}
	}
	hints := make([dynamic]string, 0, len(TOOL_SUBCMDS), context.temp_allocator)
	defer delete(hints)
	for e in TOOL_SUBCMDS {
		append(&hints, e.hint)
	}
	return usage_error("tool", strings.concatenate(
		{"expected ", util.quoted_join(hints[:], " or ", "`", context.temp_allocator)},
		context.temp_allocator,
	))
}

// tool_list_report folds the project's config stack over the tool table
// and renders one line per visible tool plus a summary (--all ignores
// the layers, --only-optional keeps only optional tools, --quiet prints
// names only). Lines are built with plain concatenation: tool
// descriptions carry braces, which fmt would treat as parameter
// markers.
tool_list_report :: proc(g: ^Globals, contexts, modes: []string, all, only_optional, quiet: bool, a: mem.Allocator) -> (string, int) {
	root, code := resolve_project_root("tool list", g)
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
			{"aubade tool list: config stack failed: ", platform.err_message(serr, context.temp_allocator)},
			context.temp_allocator,
		))
		return "", 1
	}
	defer config.stack_destroy(stack)

	layers := session.visibility_layers(stack, context.allocator)
	defer delete(layers, context.allocator)
	// --all bypasses the fold outright: the whole table, no layer says
	// anything (optionals included — they normally wait for a layer's
	// included_optional_tools). The hostless listing assumes every
	// capability.
	vis := tools.fold_visibility(tools.cap_all(), stack.project.read_only, layers, nil)
	if all {
		vis = {}
		caps := tools.cap_all()
		table_all := tools.TOOLS
		for _, idx in table_all {
			if tools.visible(cast(tools.Tool_ID)idx, caps) {
				vis |= {cast(tools.Tool_ID)idx}
			}
		}
	}

	table := tools.TOOLS
	visible_count := 0
	lines := make([dynamic]string, 0, len(table) + 1, a)
	for t, idx in table {
		if cast(tools.Tool_ID)idx not_in vis {
			continue
		}
		if only_optional && !t.optional {
			continue
		}
		visible_count += 1
		if quiet {
			append(&lines, t.name)
			continue
		}
		line := strings.concatenate({t.name, " — ", t.title}, a)
		if t.can_edit {
			line = strings.concatenate({line, " [can-edit]"}, a)
		}
		if t.optional {
			line = strings.concatenate({line, " [optional]"}, a)
		}
		append(&lines, line)
	}
	if !quiet {
		summary := ""
		if all {
			summary = fmt.aprintf("%d of %d tools listed (all, context %s, read-only %v)",
				visible_count, len(table), sel.context_name, stack.project.read_only, allocator = a)
		} else {
			summary = fmt.aprintf("%d of %d tools visible (context %s, read-only %v)",
				visible_count, len(table), sel.context_name, stack.project.read_only, allocator = a)
		}
		append(&lines, summary)
	}
	joined, _ := strings.join(lines[:], "\n", a)
	return joined, 0
}

// tool_show_report renders one tool's declaration and generated schema.
// With --context/--mode it also reports the tool's folded visibility
// under that selection (config description overrides are abolished by
// design — the selectors answer visibility, not wording).
tool_show_report :: proc(g: ^Globals, name: string, contexts, modes: []string, a: mem.Allocator) -> (string, int) {
	tid, ok := tools.find_by_name(name)
	if !ok {
		fmt.eprintf("aubade tool show: unknown tool %q\n", name)
		return "", 1
	}
	// Take the descriptor by pointer into the materialized table;
	// schema_for_tool reads the params slice.
	table := tools.TOOLS
	desc := &table[int(tid)]

	needs := make([dynamic]string, 0, 3, a)
	for i in 0..<int(tools.Cap.Shell) + 1 {
		c := cast(tools.Cap)i
		if c in desc.needs {
			append(&needs, cap_name(c))
		}
	}
	needs_str, _ := strings.join(needs[:], ", ", a)
	header := strings.concatenate(
		{
			desc.name,
			" — ",
			desc.title,
			"\n",
			desc.description,
			"\ncaps: ",
			needs_str,
			", can-edit: ",
			desc.can_edit ? "yes" : "no",
			", optional: ",
			desc.optional ? "yes" : "no",
			"\nparams schema:\n",
		},
		a,
	)
	schema := tools.schema_for_tool(desc, a)
	body := jsonutil.marshal_value(schema, a)
	out := strings.concatenate({header, body, "\n"}, a)

	if len(contexts) > 0 || len(modes) > 0 {
		root, code := resolve_project_root("tool show", g)
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
				{"aubade tool show: config stack failed: ", platform.err_message(serr, context.temp_allocator)},
				context.temp_allocator,
			))
			return "", 1
		}
		defer config.stack_destroy(stack)
		layers := session.visibility_layers(stack, context.allocator)
		defer delete(layers, context.allocator)
		vis := tools.fold_visibility(tools.cap_all(), stack.project.read_only, layers, nil)
		state := "hidden"
		if tid in vis {
			state = "visible"
		}
		out = strings.concatenate({out, "visibility: ", state, " (context ", sel.context_name, ", read-only "}, a)
		out = strings.concatenate({out, stack.project.read_only ? "true" : "false", ")\n"}, a)
	}
	return out, 0
}

cap_name :: proc(c: tools.Cap) -> string {
	switch c {
	case .Project:
		return "project"
	case .Svc:
		return "svc"
	case .Editor:
		return "editor"
	case .Tracker:
		return "tracker"
	case .Memories:
		return "memories"
	case .Shadow:
		return "shadow"
	case .Web:
		return "web"
	case .Shell:
		return "shell"
	}
	return "?"
}
