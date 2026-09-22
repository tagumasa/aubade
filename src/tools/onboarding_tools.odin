// The onboarding tool family: the instructions manual, the onboarding
// run prompt, and the memory-backed onboarding check. Prose references
// the namespaced tool names.
package tools

import "core:fmt"
import "core:strings"
import "src:jsonutil"
import "src:platform"
import "src:prompt"
import "src:svc"

ONBOARDING_READ_INSTRUCTIONS_PARAMS :: []Param_Desc{
	{name = "session_id", kind = .Str, description = "Optional session id.", required = false},
}

onboarding_read_instructions :: Tool_Desc{
	name        = "onboarding_read_instructions",
	title       = "Read instructions manual",
	description = "Return the Aubade Instructions Manual for this session.",
	can_edit    = false,
	optional    = false,
	category    = .Onboarding,
	params      = ONBOARDING_READ_INSTRUCTIONS_PARAMS,
	needs       = {}, // no capability: always visible
	apply       = onboarding_read_instructions_apply,
}

onboarding_run :: Tool_Desc{
	name        = "onboarding_run",
	title       = "Run onboarding",
	description = "Return the first-time onboarding prompt: collect project facts and save them as memories.",
	can_edit    = false,
	optional    = false,
	category    = .Onboarding,
	params      = nil,
	needs       = {}, // no capability: always visible
	apply       = onboarding_run_apply,
}

onboarding_read_instructions_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	return text_result(ctx, onboarding_manual_text(ctx))
}

onboarding_run_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	rendered, ok := onboarding_prompt_text(host_os_name(), ctx.allocator)
	if !ok {
		return err_result(ctx, "onboarding prompt template render failed")
	}
	return text_result(ctx, rendered)
}

// host_os_name spells the host OS with the conventional lowercase
// names ("windows"/"darwin"/"linux") — the prompt text names the host
// system.
host_os_name :: proc() -> string {
	when ODIN_OS == .Windows {
		return "windows"
	} else when ODIN_OS == .Darwin {
		return "darwin"
	} else when ODIN_OS == .Linux {
		return "linux"
	} else {
		return "unknown"
	}
}

// ONBOARDING_DIRECTIVE prefixes the MCP server's instructions so that
// whichever channel a client surfaces still prompts the model to
// onboard before starting work.
ONBOARDING_DIRECTIVE :: "IMPORTANT: Before performing any task, call `onboarding_check` to verify project onboarding status. " +
	"If onboarding has not been performed, call the `onboarding_run` tool first. " +
	"Then call `onboarding_read_instructions` to read the Aubade Instructions Manual."

// STANDALONE_INSTRUCTIONS_MANUAL is the manual's static core: the
// tool-first working guidance. The read_instructions tool serves it with
// the session's project facts appended (see onboarding_manual_text), and
// the child's start-up path keeps it as the render-failure fallback for
// the served instructions.
STANDALONE_INSTRUCTIONS_MANUAL :: "Aubade Instructions Manual\n\n" +
	"Aubade gives you symbol-aware code intelligence over this project. Prefer\n" +
	"its tools over grep-style text search and whole-file reads: they resolve\n" +
	"real symbols, cost fewer tokens, and almost none of them need a language\n" +
	"server.\n\n" +
	"- symbol_list shows a file's symbol tree; symbol_find locates symbols\n" +
	"  project-wide by name path (exact match by default, case-insensitive;\n" +
	"  a '*' in a segment is a glob, e.g. \"mono_*\").\n" +
	"- file_search / file_find are the raw-text and file-name fallbacks; pass\n" +
	"  relative_path to keep them scoped. Their answers are token-capped and\n" +
	"  skip ignored files.\n" +
	"- file_read_outline queries JSON/JSONC/JSON5/YAML structurally — jq-style\n" +
	"  paths, no jq needed: the key tree with 0-based line numbers without a\n" +
	"  path, the exact value(s) with their line range with one.\n" +
	"- The reference-edge queries need a language server:\n" +
	"  symbol_find_references, symbol_find_implementations,\n" +
	"  symbol_find_declaration, symbol_rename, symbol_delete,\n" +
	"  langserver_find_calls, langserver_get_diagnostics — and so do the\n" +
	"  other langserver_* tools (formatting, code actions, inlay hints).\n" +
	"  Everything else, including the edit tools, runs on the tree-sitter\n" +
	"  index alone.\n\n" +
	"Line numbers are 0-based and ranges are inclusive.\n\n" +
	"You have hereby read the 'Aubade Instructions Manual' and do not need to read it again."

// onboarding_manual_text assembles the manual: the static guidance plus
// the session's project facts (memory names, tracker open summary,
// language-server state) when the parent link can serve them. A section
// whose svc round trip fails or has nothing to say drops quietly — the
// manual must not fail on its optional parts.
onboarding_manual_text :: proc(ctx: ^Tool_Ctx) -> string {
	if !need_svc(ctx) || ctx.caps == nil {
		return STANDALONE_INSTRUCTIONS_MANUAL
	}
	facts := make([dynamic]string, 0, 3, ctx.allocator)

	if .Memories in ctx.caps.available {
		call := svc.client_memory_list(ctx.svc_conn, "", ctx.allocator, svc_deadline(ctx), ctx.cancel)
		if call.call_err == .None && call.err_code == .None && call.result != nil {
			names := memory_project_names(call.result, ctx.allocator)
			if len(names) == 0 {
				append(&facts, "No project memories yet — call onboarding_run before starting work.")
			} else {
				joined, _ := strings.join(names, ", ", ctx.allocator)
				append(&facts, fmt.aprintf("Project memories (%d): %s", len(names), joined, allocator = ctx.allocator))
			}
		}
	}

	if .Tracker in ctx.caps.available {
		call := svc.client_tracker_open_summary(ctx.svc_conn, ctx.allocator, svc_deadline(ctx), ctx.cancel)
		if call.call_err == .None && call.err_code == .None && call.result != nil {
			if v, ok := jsonutil.obj_get(call.result, "text"); ok {
				if s, sok := v.(string); sok && s != "" {
					append(&facts, s)
				}
			}
		}
	}

	if line := onboarding_ls_line(ctx); line != "" {
		append(&facts, line)
	}

	if len(facts) == 0 {
		return STANDALONE_INSTRUCTIONS_MANUAL
	}
	joined, _ := strings.join(facts[:], "\n", ctx.allocator)
	return strings.concatenate(
		{STANDALONE_INSTRUCTIONS_MANUAL, "\n", "Project facts (this session):", "\n", joined},
		ctx.allocator,
	)
}

// onboarding_prompt_text renders the first-time onboarding task
// description through the template factory: the embedded default lives
// in the prompt package (an ordinary named template), so a user file at
// $AUBADE_HOME/prompt_templates/onboarding_prompt.tmpl overrides it.
onboarding_prompt_text :: proc(system: string, a := context.allocator) -> (string, bool) {
	home := platform.aubade_home(context.temp_allocator)
	body, ok := prompt.template_by_name(home, "onboarding_prompt", a)
	if !ok {
		return "", false
	}
	vars: prompt.Template_Vars
	prompt.template_vars_init(&vars, context.temp_allocator)
	defer prompt.template_vars_destroy(&vars)
	prompt.template_set_str(&vars, "system", system)
	return prompt.template_render(body, &vars, a)
}

