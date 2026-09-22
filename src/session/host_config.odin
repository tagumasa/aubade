// Host config wiring: the consumer-side adapters between the config
// stack and what the session host consumes — the visibility layers fed
// into the single fold engine, and the shell-safety patterns fed into
// the safety checker. Both live here (not in config or tools) so the
// fold stays free of the config package and config stays free of tools.
package session

import "core:mem"
import "core:strings"

import "src:config"
import "src:safety"
import "src:tools"
import "src:util"

// The single-project strip hides the project-management tools when the
// active context fixes the project: a single-project session (e.g. an
// IDE launching with --project-from-cwd) never switches projects, so
// the overview/config surface stays out of the way. The exclusion rides
// the same fold as every other layer — no second visibility path. The
// hidden name is taken from config_get's Tool_Desc (see
// visibility_layers), so a rename cannot leave the strip behind.

// visibility_layers projects the stack's inclusion declarations into the
// fold order (global → context → modes → [single-project strip] →
// project; the read-only strip runs inside fold_visibility). The strings
// stay owned by the stack's arena, so the layers are valid for the
// stack's (the App's) lifetime — set once at startup, before any thread
// that folds exists.
visibility_layers :: proc(s: ^config.Config_Stack, a := context.allocator) -> []tools.Visibility_Layer {
	extra := 0
	if s.ctx.single_project {
		extra = 1
	}
	out := make([]tools.Visibility_Layer, 3 + len(s.modes) + extra, a)
	i := 0
	out[i] = inclusion_layer(&s.global.shared.inclusion)
	i += 1
	out[i] = inclusion_layer(&s.ctx.inclusion)
	i += 1
	for j in 0..<len(s.modes) {
		out[i] = inclusion_layer(&s.modes[j].inclusion)
		i += 1
	}
	if extra == 1 {
		// Build the exclusion from the Tool_Desc's own name and clone it
		// onto the stack's arena — the same home every other layer string
		// has (valid until stack_destroy, freed wholesale).
		desc := tools.config_get
		arena := mem.dynamic_arena_allocator(&s.arena)
		names := make([]string, 1, arena)
		names[0] = strings.clone(desc.name, arena)
		out[i] = {excluded = names}
		i += 1
	}
	out[i] = inclusion_layer(&s.project.shared.inclusion)
	return out
}

inclusion_layer :: proc(t: ^config.Tool_Inclusion) -> tools.Visibility_Layer {
	return {
		excluded          = t.excluded_tools,
		included_optional = t.included_optional_tools,
		fixed             = t.fixed_tools,
	}
}

// feed_shell_config merges the stack's blocked/allowed shell-command
// lists (global + project concatenated) into the checker's shell guard.
// A pattern that fails to compile warns and is skipped: one bad regex
// must not take the whole guard down.
feed_shell_config :: proc(sc: ^safety.Safety_Checker, s: ^config.Config_Stack) {
	blocked := config.stack_merged_strings(
		s.global.shared.blocked_shell_commands,
		s.project.shared.blocked_shell_commands,
		context.temp_allocator,
	)
	for pat in blocked {
		if perr := safety.shellguard_add_blocked_pattern(&sc.shell_guard, pat, "blocked by config"); perr != nil {
			util.log_warning(strings.concatenate(
				{"invalid blocked_shell_commands pattern: ", pat},
				context.temp_allocator,
			))
		}
	}
	allowed := config.stack_merged_strings(
		s.global.shared.allowed_shell_commands,
		s.project.shared.allowed_shell_commands,
		context.temp_allocator,
	)
	for pat in allowed {
		if perr := safety.shellguard_add_allowed(&sc.shell_guard, pat); perr != nil {
			util.log_warning(strings.concatenate(
				{"invalid allowed_shell_commands pattern: ", pat},
				context.temp_allocator,
			))
		}
	}
}
