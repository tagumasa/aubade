// The Config_Stack: global → context → modes → project(+local), the
// foldable input to fold_visibility (which lands with the tools layer).
// Each stack owns a dedicated Dynamic_Arena — every load allocates from it,
// reload means "build a new stack, swap the pointer, free the old one
// wholesale", and stack_destroy is a single free_all. Precedence: CLI flag > config file > built-in default; CLI
// --context/--mode replace the configured selection, never add to it.
package config

import "core:mem"
import "src:platform"

Config_Stack :: struct {
	arena:    mem.Dynamic_Arena,
	owner:    mem.Allocator, // frees the stack struct itself
	global:   ^Global_Config,
	ctx:      Context_Def,
	modes:    []Mode_Def,
	project:  ^Project_Config,
	warnings: []string, // owned by the arena; valid until stack_destroy
}

Stack_Selection :: struct {
	project_root: string, // normalized absolute root ("" → project defaults)
	context_name: string, // "" → DEFAULT_CONTEXT
	mode_names:   []string, // nil → the configured defaults (CLI flags replace)
}

// stack_build loads and resolves the whole stack from `home`.
stack_build :: proc(
	sel: Stack_Selection,
	home: string,
	backing := context.allocator,
) -> (s: ^Config_Stack, err: platform.Err) {
	s = new(Config_Stack, backing)
	s^ = {owner = backing}
	mem.dynamic_arena_init(&s.arena, backing)
	a := mem.dynamic_arena_allocator(&s.arena)

	warnings: [dynamic]string
	warnings = make([dynamic]string, 0, 8, a)
	extend_warnings :: proc(dst: ^[dynamic]string, src: []string) {
		for w in src {
			append(dst, w)
		}
	}

	global, gwarn, gerr := load_global(home, a)
	if gerr != nil {
		kept := stack_err_reowned(gerr)
		stack_destroy(s)
		return nil, kept
	}
	s.global = global
	extend_warnings(&warnings, gwarn)

	context_name := sel.context_name
	if context_name == "" {
		context_name = DEFAULT_CONTEXT
	}
	ctx, cerr := load_context(home, context_name, a)
	if cerr != nil {
		kept := stack_err_reowned(cerr)
		stack_destroy(s)
		return nil, kept
	}
	s.ctx = ctx

	if sel.project_root == "" {
		s.project = default_project(a)
	} else {
		managed := managed_dir_for(sel.project_root, global.project_aubade_folder_location, a)
		project, pwarn, perr := load_project(managed, a)
		if perr != nil {
			kept := stack_err_reowned(perr)
			stack_destroy(s)
			return nil, kept
		}
		s.project = project
		extend_warnings(&warnings, pwarn)
	}

	// Mode resolution: base_modes always apply; the default selection comes
	// from the project (when it sets default_modes) or the global config;
	// an explicit CLI list replaces that selection; added_modes always
	// append on top.
	names: [dynamic]string
	names = make([dynamic]string, 0, 8, a)
	for m in global.base_modes {
		append(&names, m)
	}
	if sel.mode_names != nil {
		for m in sel.mode_names {
			append(&names, m)
		}
	} else if s.project.shared.default_modes_set {
		for m in s.project.shared.default_modes {
			append(&names, m)
		}
	} else {
		for m in global.shared.default_modes {
			append(&names, m)
		}
	}
	for m in s.project.added_modes {
		append(&names, m)
	}

	// A name repeated across base/selection/added would load and fold the
	// same mode twice; keep the first occurrence only.
	dedup := make(map[string]bool, len(names), a)
	unique := make([dynamic]string, 0, len(names), a)
	for m in names {
		if dedup[m] {
			continue
		}
		dedup[m] = true
		append(&unique, m)
	}

	modes := make([dynamic]Mode_Def, 0, len(unique), a)
	for name in unique {
		mode, merr := load_mode(home, name, a)
		if merr != nil {
			kept := stack_err_reowned(merr)
			stack_destroy(s)
			return nil, kept
		}
		append(&modes, mode)
	}
	s.modes = modes[:]
	s.warnings = warnings[:]
	return s, nil
}

// stack_err_reowned re-renders a loader error onto the calling thread's
// temp scratch: the loaders build their messages on the stack's own arena,
// which stack_destroy frees before the caller renders the error, and a
// message owned by a dead arena is a use-after-free read. The re-owned
// message is log-and-drop scratch — callers consume it in their own frame
// (both current callers log it immediately), never park it.
@(private)
stack_err_reowned :: proc(err: platform.Err) -> platform.Err {
	if err == nil {
		return nil
	}
	return platform.Wrapped{
		kind = platform.err_kind(err),
		msg  = platform.err_message(err, context.temp_allocator),
	}
}

stack_destroy :: proc(s: ^Config_Stack) {
	owner := s.owner
	mem.dynamic_arena_destroy(&s.arena)
	free(s, owner)
}

// --- effective-value helpers (the merge rules are fixed here) ---

// stack_effective_line_ending resolves project → global → native through
// the shared resolve_line_ending (the one precedence implementation every
// consumer calls).
stack_effective_line_ending :: proc(s: ^Config_Stack) -> Line_Ending {
	return resolve_line_ending(&s.project.shared, &s.global.shared)
}

// stack_effective_symbol_info_budget_s resolves project → global → default
// through the shared resolve_symbol_info_budget_s.
stack_effective_symbol_info_budget_s :: proc(s: ^Config_Stack) -> f64 {
	return resolve_symbol_info_budget_s(&s.project.shared, &s.global.shared)
}

// stack_merged_strings concatenates global and project lists — the rule
// behind blocked/allowed shell commands, memory patterns, and ignored paths.
stack_merged_strings :: proc(global_list, project_list: []string, a := context.allocator) -> []string {
	out := make([]string, len(global_list) + len(project_list), a)
	i := 0
	for x in global_list {
		out[i] = x
		i += 1
	}
	for x in project_list {
		out[i] = x
		i += 1
	}
	return out
}
