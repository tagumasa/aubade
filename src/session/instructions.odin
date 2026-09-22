// The initialize-time instructions: the session renders the real system
// prompt (exposed tools, context/mode prompts, global memories, tracker
// summary) through the shared engine. The static manual on
// Config.instructions stays only as the render-failure fallback.
package session

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:sync"

import "src:config"
import "src:jsonrpc"
import "src:jsonutil"
import "src:memory"
import "src:platform"
import "src:prompt"
import "src:svc"
import "src:tools"
import "src:util"

// Best-effort budget for the two one-shot RPCs feeding the prompt: a
// parent that cannot answer inside this window simply drops its section.
INSTRUCTIONS_RPC_DEADLINE_MS :: i64(3000)

// compose_instructions renders the system prompt served in the
// initialize response. Called once after the parent link settles and
// before the reader/heartbeat threads start. The whole render runs on a
// local arena; every path hands back exactly one string owned by
// a.allocator — the render-failure fallback included (a clone of the
// static manual, never the borrowed Config spelling) — so the shutdown
// path frees the result unconditionally.
compose_instructions :: proc(a: ^App) -> string {
	sync.mutex_lock(&a.parent_mu)
	vis := a.visible
	caps := a.available_caps
	conn := a.parent
	sync.mutex_unlock(&a.parent_mu)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, a.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	ra := mem.dynamic_arena_allocator(&arena)

	available_tools, marker_names := tools.visible_names(vis, ra)

	inputs: prompt.Render_Inputs
	inputs.available_tools = available_tools
	inputs.available_markers = marker_names

	if a.stack != nil {
		// Context/mode prompts re-render through the engine with the tool
		// lists — user prompts may carry tool conditionals, including the
		// marker set (the exposed markers, same as the tool names).
		vars: prompt.Template_Vars
		prompt.template_vars_init(&vars, context.temp_allocator)
		defer prompt.template_vars_destroy(&vars)
		prompt.template_set_list(&vars, "available_tools", available_tools)
		prompt.template_set_list(&vars, "available_markers", marker_names)

		inputs.context_prompt = prompt.render_prompt_text(a.stack.ctx.prompt, &vars, ra)
		mode_prompts := make([dynamic]string, 0, len(a.stack.modes), ra)
		for mi in 0..<len(a.stack.modes) {
			body := prompt.render_prompt_text(a.stack.modes[mi].prompt, &vars, ra)
			if body != "" {
				append(&mode_prompts, body)
			}
		}
		inputs.mode_prompts = mode_prompts[:]
	}

	if conn != nil && .Memories in caps {
		inputs.global_memories = fetch_global_memories(conn, ra)
	}
	if conn != nil && .Tracker in caps {
		inputs.tracker_summary = fetch_tracker_summary(conn, ra)
	}

	rendered, ok := prompt.render_system_prompt(a.home, &inputs, ra)
	if !ok {
		util.log_warning("system prompt render failed; serving the static instructions fallback")
		return strings.clone(a.cfg.instructions, a.allocator)
	}
	// The project's initial_prompt rides along as a trailing section —
	// the documented "given to the model on every project activation"
	// behavior.
	if section := initial_prompt_section(a.stack, ra); section != "" {
		rendered = strings.concatenate({rendered, section}, ra)
	}
	return strings.clone(rendered, a.allocator)
}

// initial_prompt_section renders the project's configured initial prompt
// as a trailing system-prompt section (leading separator included). Blank
// prompts — or no stack/project — yield "".
initial_prompt_section :: proc(stack: ^config.Config_Stack, a: mem.Allocator) -> string {
	if stack == nil || stack.project == nil {
		return ""
	}
	prompt_text := strings.trim_space(stack.project.initial_prompt)
	if prompt_text == "" {
		return ""
	}
	return strings.concatenate({"\n\n# Project initial prompt\n\n", prompt_text}, a)
}

// fetch_global_memories lists the global bucket over the svc link and
// renders its memory dict; any failure yields "" (the prompt omits
// the line).
fetch_global_memories :: proc(conn: ^jsonrpc.Conn, a: mem.Allocator) -> string {
	deadline := platform.mono_ms() + INSTRUCTIONS_RPC_DEADLINE_MS
	call := svc.client_memory_list(conn, memory.GLOBAL_TOPIC, context.temp_allocator, deadline)
	if call.call_err != .None || call.err_code != .None || call.result == nil {
		return ""
	}
	memories := json_string_bucket(call.result, "memories")
	read_only := json_string_bucket(call.result, "read_only_memories")
	return prompt.global_memories_json(memories, read_only, a)
}

// fetch_tracker_summary pulls the one-line open summary; any failure or
// an all-closed tracker yields "" (the prompt omits the line).
fetch_tracker_summary :: proc(conn: ^jsonrpc.Conn, a: mem.Allocator) -> string {
	deadline := platform.mono_ms() + INSTRUCTIONS_RPC_DEADLINE_MS
	call := svc.client_tracker_open_summary(conn, context.temp_allocator, deadline)
	if call.call_err != .None || call.err_code != .None || call.result == nil {
		return ""
	}
	if v, ok := jsonutil.obj_get(call.result, "text"); ok {
		if s, sok := v.(string); sok && s != "" {
			return strings.clone(s, a)
		}
	}
	return ""
}

// json_string_bucket reads a string-array member off a wire result
// (scratch-owned; absent or non-array yields nil).
json_string_bucket :: proc(v: json.Value, key: string) -> []string {
	if v == nil {
		return nil
	}
	member, ok := jsonutil.obj_get(v, key)
	if !ok {
		return nil
	}
	arr, aok := jsonutil.as_array(member)
	if !aok {
		return nil
	}
	out := make([]string, len(arr), context.temp_allocator)
	for i := 0; i < len(arr); i += 1 {
		if s, sok := arr[i].(string); sok {
			out[i] = s
		}
	}
	return out
}
