// The system-prompt renderer: assembles the template variables the
// reference's CreateSystemPrompt builds — the exposed (folded) tool
// names, the context and mode prompts, the global memories JSON list,
// and the tracker's one-line open summary — and renders the
// system_prompt template (user overrides honored by name).
package prompt

import "core:encoding/json"
import "core:mem"
import "core:strings"

import "src:jsonutil"

Render_Inputs :: struct {
	context_prompt:     string,
	mode_prompts:       []string,
	available_tools:    []string,
	available_markers:  []string,
	global_memories:    string, // pre-rendered JSON list ("" = none)
	tracker_summary:    string, // one-line open summary ("" = none)
}

// render_system_prompt renders the session's system prompt. The
// reference prefixes nothing here: the MCP `instructions` field and the
// print-system-prompt CLI wrap the result as they need.
render_system_prompt :: proc(home: string, inputs: ^Render_Inputs, a := context.allocator) -> (string, bool) {
	return render_named(home, "system_prompt", inputs, a)
}

// render_named renders any named template with the same variable shape
// (the system prompt and the cc override both use the tool/marker
// conditionals and the tracker block).
render_named :: proc(home, name: string, inputs: ^Render_Inputs, a := context.allocator) -> (string, bool) {
	vars: Template_Vars
	template_vars_init(&vars, context.temp_allocator)
	defer template_vars_destroy(&vars)

	template_set_list(&vars, "available_tools", inputs.available_tools)
	template_set_list(&vars, "available_markers", inputs.available_markers)
	template_set_str(&vars, "context_system_prompt", inputs.context_prompt)
	template_set_list(&vars, "mode_system_prompts", inputs.mode_prompts)
	template_set_str(&vars, "global_memories_list", inputs.global_memories)
	template_set_str(&vars, "tracker_summary", inputs.tracker_summary)

	body, ok := template_by_name(home, name, context.temp_allocator)
	if !ok {
		return "", false
	}
	rendered, rok := template_render(body, &vars, a)
	if !rok {
		return "", false
	}
	return rendered, true
}

// render_prompt_text renders one context/mode prompt body with the tool
// lists (user prompts may carry tool conditionals); unparseable markup
// falls back to the raw text, cloned into `a` — the source may live on a
// stack arena that dies with its caller.
render_prompt_text :: proc(src: string, vars: ^Template_Vars, a: mem.Allocator) -> string {
	if src == "" {
		return ""
	}
	out, ok := template_render(src, vars, a)
	if !ok {
		return strings.clone(src, a)
	}
	return out
}

// global_memories_json renders the global-memories dict
// ({"memories": [...], "read_only_memories": [...]}); both buckets empty
// yields "" (the template omits the line entirely). The intermediate
// JSON tree is scratch: the array buffers and the map are freed before
// returning — the strings and keys are caller/literal-owned views.
global_memories_json :: proc(memories, read_only: []string, a := context.allocator) -> string {
	if len(memories) == 0 && len(read_only) == 0 {
		return ""
	}
	m := jsonutil.json_object(2, a)
	if len(memories) > 0 {
		jsonutil.obj_set(&m, "memories", jsonutil.json_string_array(memories, a))
	}
	if len(read_only) > 0 {
		jsonutil.obj_set(&m, "read_only_memories", jsonutil.json_string_array(read_only, a))
	}
	out := jsonutil.marshal_value(json.Value(json.Object(m)), a)
	free_bucket(m, "memories")
	free_bucket(m, "read_only_memories")
	delete(m)
	return out
}

// free_bucket releases one array bucket of the scratch dict built above
// (the strings inside are caller-owned views; the buffer carries its own
// allocator).
free_bucket :: proc(m: map[string]json.Value, key: string) {
	v, ok := m[key]
	if !ok {
		return
	}
	#partial switch av in v {
	case json.Array:
		delete(cast([dynamic]json.Value)av)
	}
}
