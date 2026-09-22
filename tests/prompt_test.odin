// Prompt template engine tests: substitution, conditionals (truthiness
// and membership), loops, whitespace control, and the system-prompt
// rendering over the embedded template.
package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "src:prompt"
import "src:tools"

@(test)
prompt_template_engine :: proc(t: ^testing.T) {
	vars: prompt.Template_Vars
	prompt.template_vars_init(&vars, context.allocator)
	defer prompt.template_vars_destroy(&vars)
	prompt.template_set_str(&vars, "name", "world")
	prompt.template_set_list(&vars, "items", []string{"a", "b"})
	prompt.template_set_bool(&vars, "flag", true)

	// Substitution and unknown-variable tolerance (every render ends
	// with exactly one trailing newline — the render finalization).
	out, ok := prompt.template_render("hi {{ name }}! {{ missing }}", &vars, context.allocator)
	testing.expect(t, ok)
	testing.expect(t, out == "hi world! \n", out)
	delete(out, context.allocator)

	// Truthiness of a non-empty string, emptiness of the missing one.
	out2, ok2 := prompt.template_render("{% if name %}Y{% else %}N{% endif %}|{% if missing %}Y{% else %}N{% endif %}", &vars, context.allocator)
	testing.expect(t, ok2)
	testing.expect(t, out2 == "Y|N\n", out2)
	delete(out2, context.allocator)

	// List membership and a bool.
	out3, ok3 := prompt.template_render("{% if 'a' in items %}Y{% endif %}{% if 'z' in items %}Z{% endif %}{% if flag %}T{% endif %}", &vars, context.allocator)
	testing.expect(t, ok3)
	testing.expect(t, out3 == "YT\n", out3)
	delete(out3, context.allocator)

	// Loop bodies with the loop variable.
	out4, ok4 := prompt.template_render("{% for x in items %}[{{ x }}]{% endfor %}", &vars, context.allocator)
	testing.expect(t, ok4)
	testing.expect(t, out4 == "[a][b]\n", out4)
	delete(out4, context.allocator)

	// Chomping: {%- strips before the tag, -%} after it.
	out5, ok5 := prompt.template_render("a   {%- if flag %} b {%- endif %}", &vars, context.allocator)
	testing.expect(t, ok5)
	testing.expect(t, out5 == "a b\n", out5)
	delete(out5, context.allocator)

	// A render that would end on zero or many newlines (a chomped tail
	// block, a template ending in blank lines) still finalizes to
	// exactly one.
	out6, ok6 := prompt.template_render("x{%- if flag %}{%- endif %}", &vars, context.allocator)
	testing.expect(t, ok6)
	testing.expect(t, out6 == "x\n", out6)
	delete(out6, context.allocator)
	out7, ok7 := prompt.template_render("y\n\n\n", &vars, context.allocator)
	testing.expect(t, ok7)
	testing.expect(t, out7 == "y\n", out7)
	delete(out7, context.allocator)
}

@(test)
prompt_system_prompt_render :: proc(t: ^testing.T) {
	inputs: prompt.Render_Inputs
	inputs.context_prompt = "You are running in an agent context."
	inputs.mode_prompts = make([]string, 1, context.allocator)
	inputs.mode_prompts[0] = "Use symbolic tools."
	inputs.available_tools = make([]string, 3, context.allocator)
	inputs.available_tools[0] = "symbol_find"
	inputs.available_tools[1] = "memory_read"
	inputs.available_tools[2] = "incident_list"
	inputs.available_markers = make([]string, 1, context.allocator)
	inputs.available_markers[0] = "ToolMarkerSymbolicRead"
	inputs.tracker_summary = "Pending questions (answer or descope via a sprint_update note with resolves=):\n- DEF-001 [SPR-001] keep the cache layer?\nTracker: 1 open (1 unverified)"
	defer delete(inputs.mode_prompts, context.allocator)
	defer delete(inputs.available_tools, context.allocator)
	defer delete(inputs.available_markers, context.allocator)

	rendered, ok := prompt.render_system_prompt("/nonexistent-home", &inputs, context.allocator)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(rendered, "You are running in an agent context."), rendered)
	testing.expect(t, strings.contains(rendered, "Use symbolic tools."), rendered)
	// file_search is not exposed: its conditional paragraph stays out.
	testing.expect(t, !strings.contains(rendered, "skip ignored files"), rendered)
	// The marker paragraph names the renamed reference tool.
	testing.expect(t, strings.contains(rendered, "symbol_find_references"), rendered)
	// memory_read is exposed: the memories paragraph and the manual line appear.
	testing.expect(t, strings.contains(rendered, "memory_list"), rendered)
	testing.expect(t, strings.contains(rendered, "Aubade Instructions Manual"), rendered)
	// The resume summary rides through — multi-line, question first.
	// incident_create is not in the exposed set, so the tracker paragraph
	// takes its browse-only else branch.
	testing.expect(t, strings.contains(rendered, "- DEF-001 [SPR-001] keep the cache layer?"), rendered)
	testing.expect(t, strings.contains(rendered, "Tracker: 1 open"), rendered)
	testing.expect(t, strings.contains(rendered, "Browse open findings with incident_list and incident_get."), rendered)
	// No global memories list was provided: the names line stays out.
	testing.expect(t, !strings.contains(rendered, "global (not project-specific) memories"), rendered)
	delete(rendered, context.allocator)
}

// Rendering copies BYTES, not runes: a rune loop truncates every
// non-ASCII codepoint to one byte (em-dashes and CJK text in prompts).
@(test)
prompt_template_preserves_non_ascii :: proc(t: ^testing.T) {
	vars: prompt.Template_Vars
	prompt.template_vars_init(&vars, context.allocator)
	defer prompt.template_vars_destroy(&vars)
	prompt.template_set_str(&vars, "name", "プロジェクト — 設定")
	prompt.template_set_list(&vars, "items", []string{" — ✓"})

	out, ok := prompt.template_render("context: {{ name }} — ok", &vars, context.allocator)
	testing.expect(t, ok)
	testing.expect(t, out == "context: プロジェクト — 設定 — ok\n", out)
	delete(out, context.allocator)

	out2, ok2 := prompt.template_render("{% for x in items %}[{{ x }}]{% endfor %}", &vars, context.allocator)
	testing.expect(t, ok2)
	testing.expect(t, out2 == "[ — ✓]\n", out2)
	delete(out2, context.allocator)
}

@(test)
prompt_onboarding_template :: proc(t: ^testing.T) {
	// The onboarding prompt rides the factory like every template: the
	// embedded default resolves by name, fills the system variable, and
	// lists in template_list_names.
	names := prompt.template_list_names("", context.allocator)
	defer {
		for n in names {
			delete(n)
		}
		delete(names)
	}
	listed := false
	for n in names {
		if n == "onboarding_prompt" {
			listed = true
		}
	}
	testing.expect(t, listed)

	body, ok := prompt.template_by_name("", "onboarding_prompt", context.allocator)
	testing.expect(t, ok)
	defer delete(body)

	vars: prompt.Template_Vars
	prompt.template_vars_init(&vars, context.allocator)
	defer prompt.template_vars_destroy(&vars)
	prompt.template_set_str(&vars, "system", "linux")
	rendered, rok := prompt.template_render(body, &vars, context.allocator)
	testing.expect(t, rok)
	defer delete(rendered)
	testing.expect(t, strings.contains(rendered, "The project is being developed on the system: linux."))
	testing.expect(t, strings.contains(rendered, "Keep in mind that the system is linux,"))
	testing.expect(t, strings.contains(rendered, "`memory_write`"))
	// No unfilled markers survive.
	testing.expect(t, !strings.contains(rendered, "{{"))
}

@(test)
prompt_render_prompt_text :: proc(t: ^testing.T) {
	vars: prompt.Template_Vars
	prompt.template_vars_init(&vars, context.allocator)
	defer prompt.template_vars_destroy(&vars)
	prompt.template_set_str(&vars, "name", "world")

	out := prompt.render_prompt_text("hi {{ name }}!", &vars, context.allocator)
	testing.expect(t, out == "hi world!\n", out)
	delete(out, context.allocator)

	// Unparseable markup falls back to the raw text (cloned).
	fallback := prompt.render_prompt_text("raw {{ oops", &vars, context.allocator)
	testing.expect(t, fallback == "raw {{ oops", fallback)
	delete(fallback, context.allocator)

	empty := prompt.render_prompt_text("", &vars, context.allocator)
	testing.expect(t, empty == "", empty)
}

@(test)
prompt_global_memories_json_shape :: proc(t: ^testing.T) {
	testing.expect(t, prompt.global_memories_json(nil, nil, context.allocator) == "")

	one := prompt.global_memories_json({"a", "b"}, nil, context.allocator)
	defer delete(one, context.allocator)
	testing.expect(t, strings.contains(one, "\"memories\""), one)
	testing.expect(t, strings.contains(one, "\"a\""), one)
	testing.expect(t, !strings.contains(one, "read_only"), one)

	both := prompt.global_memories_json({"a"}, {"ro"}, context.allocator)
	defer delete(both, context.allocator)
	testing.expect(t, strings.contains(both, "\"memories\""), both)
	testing.expect(t, strings.contains(both, "\"read_only_memories\""), both)
}


@(test)
template_nested_for_binds_own_var :: proc(t: ^testing.T) {
	// Each {% for %} binds its OWN loop variable with save/restore, so a
	// nested loop sees both its item and the enclosing one (the unified
	// overlay renderer's contract).
	vars: prompt.Template_Vars
	prompt.template_vars_init(&vars, context.temp_allocator)
	defer prompt.template_vars_destroy(&vars)
	outer := []string{"a", "b"}
	inner := []string{"1", "2"}
	prompt.template_set_list(&vars, "outer", outer)
	prompt.template_set_list(&vars, "inner", inner)

	out, ok := prompt.template_render(
		"{% for x in outer %}{% for y in inner %}[{{x}}:{{y}}]{% endfor %}{% endfor %}",
		&vars, context.allocator,
	)
	testing.expect(t, ok)
	testing.expect(t, out == "[a:1][a:2][b:1][b:2]\n", out)
	delete(out, context.allocator)

	// The overlay restores the outer binding after the nested loop.
	out2, ok2 := prompt.template_render(
		"{% for x in outer %}{{x}}{% for y in inner %}{{y}}{% endfor %}={{x}}{% endfor %}",
		&vars, context.allocator,
	)
	testing.expect(t, ok2)
	testing.expect(t, out2 == "a12=ab12=b\n", out2)
	delete(out2, context.allocator)
}

// Nesting past MAX_TEMPLATE_DEPTH must fail the render cleanly — the
// parser recurses per opening tag, so the depth has to be bounded (a
// crash here kills the whole runner).
@(test) prompt_template_deep_nesting_rejected :: proc(t: ^testing.T) {
	vars: prompt.Template_Vars
	prompt.template_vars_init(&vars, context.allocator)
	defer prompt.template_vars_destroy(&vars)
	prompt.template_set_bool(&vars, "flag", true)

	tag := "{% if flag %}"
	buf := make([dynamic]u8, 0, (prompt.MAX_TEMPLATE_DEPTH + 4) * len(tag), context.allocator)
	defer delete(buf)
	for _ in 0..<prompt.MAX_TEMPLATE_DEPTH + 4 {
		append(&buf, ..transmute([]u8)tag)
	}
	out, ok := prompt.template_render(string(buf[:]), &vars, context.allocator)
	testing.expect(t, !ok, "deep template nesting must fail the render")
	_ = out
}

// A template file past the size cap falls back to the embedded default
// (or "not found" for names without one) — a runaway file must not load.
@(test) prompt_template_oversize_falls_back :: proc(t: ^testing.T) {
	home, err := os.make_directory_temp("", "aubade-tmpl-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(home)
		delete(home)
	}

	parts := []string{home, "prompt_templates"}
	dir, _ := filepath.join(parts, context.allocator)
	defer delete(dir)
	os.make_directory_all(dir, os.Permissions{.Read_User, .Write_User, .Execute_User})
	big_parts := []string{dir, "big.tmpl"}
	big_path, _ := filepath.join(big_parts, context.allocator)
	defer delete(big_path)
	big := make([]u8, prompt.MAX_TEMPLATE_BYTES + 16, context.allocator)
	defer delete(big)
	f, oerr := os.open(big_path, {.Write, .Create, .Trunc}, os.Permissions{.Read_User, .Write_User})
	if oerr != nil {
		testing.fail_now(t, "failed to open oversize template for writing")
	}
	os.write(f, big)
	os.close(f)

	body, ok := prompt.template_by_name(home, "big", context.allocator)
	testing.expect(t, !ok, "oversize template must not load")
	_ = body
}

// --- built-in template condition keys vs the tool registry ---------------
//
// The built-in templates test tool availability with literals
// ({% if 'file_search' in available_tools %}). The prompt package sits
// below the tools layer, so the bodies cannot reference the registry —
// this test is the binding instead: every condition key must name a real
// tool (or, for available_markers, a marker name the registry produces).
// A renamed tool fails here instead of silently disabling its prompt
// section.

collect_condition_keys :: proc(body: string, set_name: string, out: ^[dynamic]string) {
	marker := "{% if '"
	set_word := strings.concatenate({" in ", set_name}, context.temp_allocator)
	i := 0
	for i + len(marker) <= len(body) {
		if !strings.has_prefix(body[i:], marker) {
			i += 1
			continue
		}
		rest := body[i + len(marker):]
		end := -1
		for j in 0..<len(rest) {
			if rest[j] == '\'' {
				end = j
				break
			}
		}
		if end > 0 && strings.has_prefix(rest[end + 1:], set_word) {
			append(out, rest[:end])
		}
		i += len(marker)
	}
}

@(test)
prompt_condition_keys_name_registry_entries :: proc(t: ^testing.T) {
	tool_keys: [dynamic]string = make([dynamic]string, 0, 8, context.temp_allocator)
	marker_keys: [dynamic]string = make([dynamic]string, 0, 4, context.temp_allocator)
	defer delete(tool_keys)
	defer delete(marker_keys)

	bodies := []string{prompt.SYSTEM_PROMPT_TEMPLATE, prompt.CC_SYSTEM_PROMPT_OVERRIDE, prompt.ONBOARDING_PROMPT_TEMPLATE}
	for body in bodies {
		collect_condition_keys(body, "available_tools", &tool_keys)
		collect_condition_keys(body, "available_markers", &marker_keys)
	}
	// Zero extractions means the parser above rotted, not that the
	// templates are clean.
	testing.expect(t, len(tool_keys) > 0, "no available_tools conditions found — extraction rotted")
	testing.expect(t, len(marker_keys) > 0, "no available_markers conditions found — extraction rotted")

	table := tools.TOOLS
	for key in tool_keys {
		known := false
		for desc in table {
			if desc.name == key {
				known = true
				break
			}
		}
		testing.expectf(t, known, "template condition %q is not a tool name — a rename left a dead condition", key)
	}
	for key in marker_keys {
		known := false
		for desc in table {
			if tools.marker_name_for(desc.name) == key {
				known = true
				break
			}
		}
		testing.expectf(t, known, "template marker condition %q is not a marker the registry produces", key)
	}
}
