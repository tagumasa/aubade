// Commented JSONC templates, written exactly once by the explicit
// generation commands (init / project create / context create / mode
// create). aubade never rewrites these files afterwards —
// the comments live only here and in the generated file. Placeholders
// {{PROJECT_NAME}}, {{LANGUAGE_SERVERS}}, and {{DEFAULT_ENCODING}} are
// substituted textually; the global template's {{DEFAULT_*}} and
// {{MAX_FETCH_LIMIT_B}} placeholders are substituted from
// the constants in this package (defaults live there and only
// there — never as literals in the template).
package config

import "core:fmt"
import "core:strings"

GLOBAL_TEMPLATE :: `
// Aubade global configuration (~/.aubade/config.jsonc).
// Generated once by "aubade init"; edit freely — aubade never rewrites this
// file. This is JSON with // comments and tolerated trailing commas.
// A key set to null (or removed) means "unset": the built-in default applies.
{
	// line ending convention when writing source files: "lf" | "crlf" | "native".
	// Overridable per project in project.jsonc.
	"line_ending": "native",

	// minimum log level: "debug" | "info" | "warning" | "error".
	"log_level": "{{LOG_LEVEL}}",

	// whether to trace the communication between Aubade and language servers.
	"trace_lsp_communication": false,

	// whether to start all language servers eagerly at startup instead of lazily.
	"eager_language_servers": false,

	// paths to ignore across all projects (gitignore syntax: * and ** allowed).
	"ignored_paths": [],

	// regex patterns that mark matching memory entries read-only.
	"read_only_memory_patterns": [],

	// regex patterns for memories to ignore completely.
	"ignored_memory_patterns": [],

	// timeout in seconds after which tool executions are terminated.
	"tool_timeout": {{TOOL_TIMEOUT}},

	// default character cap for tool answers.
	"default_max_tool_answer_chars": {{MAX_TOOL_ANSWER_CHARS}},

	// tool names (namespaced, e.g. "symbol_find") to exclude globally.
	"excluded_tools": [],

	// optional tools (disabled by default) to include.
	"included_optional_tools": [],

	// exact base tool set, replacing the default set. Cannot be combined with
	// excluded_tools / included_optional_tools.
	"fixed_tools": [],

	// mode names that are always active. The active set is
	// base_modes + default_modes (+ a project's added_modes).
	"base_modes": [],

	// mode names activated by default. A project's default_modes replaces
	// this list.
	"default_modes": {{DEFAULT_MODES}},

	// time budget (seconds) per tool call for retrieving extra symbol
	// information. 0 disables the budget. Overridable per project.
	"symbol_info_budget": {{SYMBOL_INFO_BUDGET}},

	// template for the per-project .aubade data folder location.
	// Placeholders: $projectDir, $projectFolderName.
	"project_aubade_folder_location": "{{MANAGED_DIR_TEMPLATE}}",

	// regex patterns blocking shell commands (matched against the normalized
	// full command line). A project's list extends this one.
	"blocked_shell_commands": [],

	// regex patterns allowing shell commands; when non-empty, only matching
	// commands are permitted. A project's list extends this one.
	"allowed_shell_commands": [],

	// regex patterns blocking URLs (matched against the raw URL string
	// before any request, including every redirect hop). A project's list
	// extends this one.
	"blocked_url_patterns": [],

	// web fetch/search configuration.
	"web": {
		// proxy for fetches: an http://, https://, socks5://, or socks5h:// URL.
		"fetch_proxy": "",
		// cap for fetched bytes, 0..{{MAX_FETCH_LIMIT_B}}.
		"fetch_limit_bytes": 0,
		// search provider: {{SEARCH_PROVIDERS}} ("auto" picks by key
		// availability).
		"search_provider": "{{SEARCH_PROVIDER}}",
		// whether fetching private-network hosts is allowed (rarely wise).
		"allow_private_hosts": false,
		// bare hostnames exempt from the private-host guard.
		"whitelist_hosts": [],
		"brave":      { "api_keys": [], "max_results": 0, "enabled": false },
		"tavily":     { "api_keys": [], "base_url": "", "max_results": 0, "enabled": false },
		"perplexity": { "api_keys": [], "max_results": 0, "enabled": false },
		"duckduckgo": { "max_results": 0, "enabled": false },
		"searxng":    { "base_url": "", "max_results": 0, "enabled": false },
	},
}
`

PROJECT_TEMPLATE :: `
// Aubade project configuration (project.jsonc).
// Generated once by "aubade project create"; edit freely — aubade never
// rewrites this file. Local overrides belong in project.local.jsonc.
// A key set to null (or removed) means "unset": the global value applies.
{
	// the name by which the project is referenced within Aubade.
	"project_name": {{PROJECT_NAME}},

	// language servers to start, one object per server:
	// {"name": <language id>, "path": <server binary>}. name is the language
	// id ("go"; for C use "cpp"; for JavaScript use "typescript"). path is
	// an OS path to the server's binary — absolute (keeps working with no
	// useful PATH, e.g. when the client spawns aubade with a scrubbed
	// environment), "~/"-anchored, or relative to the project root;
	// omitted/empty path means normal PATH resolution.
	// Example: [{"name": "odin", "path": "~/.local/bin/ols"}, {"name": "go"}]
	"language_servers": {{LANGUAGE_SERVERS}},

	// explicit language server commands: language id → argv, where argv[0]
	// is an executable path or a name found in PATH. An entry wins over a
	// language_servers path and over the built-in command and its runtime
	// checks (only argv[0] is verified); use it when the server needs extra
	// arguments. Applied when the daemon starts or via the langserver_reload
	// tool; project.local.jsonc replaces this key whole.
	"language_server_commands": {},

	// language server initialization options: language id → JSON object,
	// passed through to the server at the initialize handshake and merged
	// over its built-in options (your top-level keys win). These are the
	// server's own options — the server binary is designated by
	// language_servers' path, not here. Example — ols collection imports
	// (import "src:..."):
	//   "language_server_options": {"odin": {"collections": [{"name": "src", "path": "src"}]}}
	// (both fields belong to ols: "name" is the prefix before the colon;
	// "path" is the directory holding that collection's packages, relative
	// to the first workspace folder.)
	"language_server_options": {},

	// the encoding used by text files in the project.
	"encoding": "{{DEFAULT_ENCODING}}",

	// line ending convention: null (use the global setting) | "lf" | "crlf" |
	// "native".
	"line_ending": null,

	// whether the project's .gitignore files are used to ignore files.
	"ignore_all_files_in_gitignore": true,

	// additional paths to ignore in this project (extends the global list).
	"ignored_paths": [],

	// whether the project is in read-only mode.
	"read_only": false,

	// tool names to exclude for this project.
	"excluded_tools": [],

	// optional tools to include for this project.
	"included_optional_tools": [],

	// exact base tool set for this project (if non-empty).
	"fixed_tools": [],

	// mode names activated by default — replaces the global default_modes.
	"default_modes": null,

	// extra modes activated in addition to the default set.
	"added_modes": [],

	// initial prompt, given to the model on every project activation.
	"initial_prompt": "",

	// time budget (seconds) for extra symbol info; null uses the global value.
	"symbol_info_budget": null,

	// regex patterns marking memory entries read-only (extends the global list).
	"read_only_memory_patterns": [],

	// regex patterns for memories to ignore (extends the global list).
	"ignored_memory_patterns": [],

	// regex patterns blocking shell commands (extends the global list).
	"blocked_shell_commands": [],

	// regex patterns allowing shell commands; when non-empty, only matching
	// commands are permitted (extends the global list).
	"allowed_shell_commands": [],

	// regex patterns blocking URLs, matched against the raw URL string
	// (extends the global list).
	"blocked_url_patterns": [],

	// extra workspace folders for cross-package reference support in monorepos.
	"additional_workspace_folders": [],
}
`

CONTEXT_TEMPLATE :: `
// Aubade agent context definition (contexts/<name>.jsonc).
// Generated once by "aubade context create"; edit freely.
{
	// description of the context (meta-information only).
	"description": "Description of the context, not used in the code.",

	// prompt that becomes part of the system prompt / initial instructions
	// for agents started in this context.
	"prompt": "Prompt that will form part of the system prompt for agents in this context.",

	// tool names (namespaced, e.g. "symbol_find") to exclude in this context.
	"excluded_tools": [],

	// optional tools (disabled by default) to include in this context.
	"included_optional_tools": [],

	// exact base tool set for this context (if non-empty).
	"fixed_tools": [],

	// whether Aubade works on a single project in this context.
	"single_project": false,
}
`

MODE_TEMPLATE :: `
// Aubade agent mode definition (modes/<name>.jsonc).
// Generated once by "aubade mode create"; edit freely.
{
	// description of the mode (meta-information only).
	"description": "Description of the mode (meta-information only).",

	// prompt that becomes part of the instructions sent to the model when
	// this mode is activated.
	"prompt": "Provide a prompt that will form part of the instructions sent to the model when this mode is activated.",

	// tool names to exclude in this mode.
	"excluded_tools": [],

	// optional tools (disabled by default) to include in this mode.
	"included_optional_tools": [],

	// exact base tool set for this mode (if non-empty).
	"fixed_tools": [],
}
`

// template_global renders the global template with every default value
// interpolated from the DEFAULT_* constants — the raw template carries
// placeholders, so the generated file can never hold a stale default.
// Intermediates stay on the temp scratch; the result is cloned once
// into `a`.
template_global :: proc(a := context.allocator) -> string {
	body := clone_template(GLOBAL_TEMPLATE, context.temp_allocator)
	body = subst_placeholder(body, "{{LOG_LEVEL}}", DEFAULT_LOG_LEVEL, context.temp_allocator)
	body = subst_placeholder(body, "{{TOOL_TIMEOUT}}", fmt.aprintf("%v", DEFAULT_TOOL_TIMEOUT_S, allocator = context.temp_allocator), context.temp_allocator)
	body = subst_placeholder(body, "{{MAX_TOOL_ANSWER_CHARS}}", fmt.aprintf("%v", DEFAULT_MAX_TOOL_ANSWER_CHARS, allocator = context.temp_allocator), context.temp_allocator)
	body = subst_placeholder(body, "{{DEFAULT_MODES}}", render_string_array(DEFAULT_MODE_LIST, context.temp_allocator), context.temp_allocator)
	body = subst_placeholder(body, "{{SYMBOL_INFO_BUDGET}}", fmt.aprintf("%v", DEFAULT_SYMBOL_INFO_BUDGET_S, allocator = context.temp_allocator), context.temp_allocator)
	body = subst_placeholder(body, "{{MANAGED_DIR_TEMPLATE}}", DEFAULT_MANAGED_DIR_TEMPLATE, context.temp_allocator)
	body = subst_placeholder(body, "{{SEARCH_PROVIDER}}", DEFAULT_SEARCH_PROVIDER, context.temp_allocator)
	body = subst_placeholder(body, "{{SEARCH_PROVIDERS}}", render_provider_list(context.temp_allocator), context.temp_allocator)
	body = subst_placeholder(body, "{{MAX_FETCH_LIMIT_B}}", fmt.aprintf("%v", MAX_FETCH_LIMIT_B, allocator = context.temp_allocator), context.temp_allocator)
	return strings.clone(body, a)
}

// render_provider_list spells the accepted search-provider names as a
// quoted, barred list ("auto" | "brave" | ...) derived from the one
// validator table — the template never carries a hand-copy that can go
// stale when a provider is added.
render_provider_list :: proc(a := context.allocator) -> string {
	names := make([dynamic]string, 0, len(VALID_SEARCH_PROVIDERS), a)
	for p in VALID_SEARCH_PROVIDERS {
		if p != "" {
			append(&names, fmt.aprintf("\"%v\"", p, allocator = a))
		}
	}
	joined, _ := strings.join(names[:], " | ", a)
	for n in names {
		delete(n, a)
	}
	delete(names)
	return joined
}

template_context :: proc(a := context.allocator) -> string {
	return clone_template(CONTEXT_TEMPLATE, a)
}

template_mode :: proc(a := context.allocator) -> string {
	return clone_template(MODE_TEMPLATE, a)
}

// clone_template copies a template body, dropping the single leading
// newline that keeps the raw literals readable in source.
clone_template :: proc(body: string, a := context.allocator) -> string {
	s := body
	if strings.has_prefix(s, "\n") {
		s = s[1:]
	}
	return strings.clone(s, a)
}

// context_def_jsonc serialises a built-in context definition into the
// commented JSONC shape "context create --from-internal" writes; the
// file re-loads through load_context unchanged. Key order mirrors the
// context template.
context_def_jsonc :: proc(def: ^Context_Def, a := context.allocator) -> string {
	buf := make([dynamic]u8, 0, 512, a)
	append(&buf, "// Aubade agent context definition (contexts/")
	append(&buf, def.name)
	append(&buf, ".jsonc).\n// Copied from the built-in context by \"aubade context create --from-internal\"; edit freely.\n{\n")
	append_def_jsonc(&buf, def.description, def.prompt, &def.inclusion, a)
	append(&buf, ",\n\n\t// whether Aubade works on a single project in this context.\n\t\"single_project\": ")
	append(&buf, def.single_project ? "true" : "false")
	append(&buf, "\n}\n")
	return string(buf[:])
}

// mode_def_jsonc is mode definitions' twin of context_def_jsonc.
mode_def_jsonc :: proc(def: ^Mode_Def, a := context.allocator) -> string {
	buf := make([dynamic]u8, 0, 512, a)
	append(&buf, "// Aubade agent mode definition (modes/")
	append(&buf, def.name)
	append(&buf, ".jsonc).\n// Copied from the built-in mode by \"aubade mode create --from-internal\"; edit freely.\n{\n")
	append_def_jsonc(&buf, def.description, def.prompt, &def.inclusion, a)
	append(&buf, "\n}\n")
	return string(buf[:])
}

// append_def_jsonc writes the shared description/prompt/inclusion block
// (everything but the context-only single_project key). The block ends
// without a trailing comma.
append_def_jsonc :: proc(buf: ^[dynamic]u8, description, prompt: string, inc: ^Tool_Inclusion, a := context.allocator) {
	append(buf, "\t// description of the context or mode (meta-information only).\n\t\"description\": ")
	dq := json_quote(description, a)
	append(buf, dq)
	delete(dq, a)

	append(buf, ",\n\n\t// prompt that becomes part of the system prompt / instructions for this definition.\n\t\"prompt\": ")
	pq := json_quote(prompt, a)
	append(buf, pq)
	delete(pq, a)

	append(buf, ",\n\n\t// tool names (namespaced, e.g. \"symbol_find\") to exclude.\n\t\"excluded_tools\": ")
	ex := render_string_array(inc.excluded_tools, a)
	append(buf, ex)
	delete(ex, a)

	append(buf, ",\n\n\t// optional tools (disabled by default) to include.\n\t\"included_optional_tools\": ")
	ins := render_string_array(inc.included_optional_tools, a)
	append(buf, ins)
	delete(ins, a)

	append(buf, ",\n\n\t// exact base tool set (if non-empty).\n\t\"fixed_tools\": ")
	fs := render_string_array(inc.fixed_tools, a)
	append(buf, fs)
	delete(fs, a)
}

// project_template_reference returns the raw annotated project template
// (placeholders unsubstituted): the reference rendering every project
// configuration key with its semantics. The scaffold and this reference
// share PROJECT_TEMPLATE, so the documented keys cannot drift.
project_template_reference :: proc(a := context.allocator) -> string {
	return clone_template(PROJECT_TEMPLATE, a)
}

// generate_project_config fills the project template with the project name
// and the detected language list (rendered in the unified {name, path}
// entry form, path left to normal resolution).
generate_project_config :: proc(
	name: string,
	language_servers: []string,
	a := context.allocator,
) -> string {
	body := project_template_reference(a)
	langs := render_language_server_entries(language_servers, a)
	out := subst_placeholder(body, "{{LANGUAGE_SERVERS}}", langs, a)
	out = subst_placeholder(out, "{{PROJECT_NAME}}", json_quote(name, a), a)
	out = subst_placeholder(out, "{{DEFAULT_ENCODING}}", DEFAULT_ENCODING, a)
	return out
}

// render_language_server_entries renders language ids as the unified
// language_servers element form: [{"name": "go"}, {"name": "odin"}].
render_language_server_entries :: proc(ids: []string, a := context.allocator) -> string {
	buf := make([dynamic]u8, 0, 24, a)
	append(&buf, '[')
	for s, i in ids {
		if i > 0 {
			append(&buf, ", ")
		}
		append(&buf, `{"name": `)
		quoted := json_quote(s, a)
		append(&buf, quoted)
		delete(quoted, a)
		append(&buf, '}')
	}
	append(&buf, ']')
	return string(buf[:])
}

render_string_array :: proc(items: []string, a := context.allocator) -> string {
	buf := make([dynamic]u8, 0, 16, a)
	append(&buf, '[')
	for s, i in items {
		if i > 0 {
			append(&buf, ", ")
		}
		quoted := json_quote(s, a)
		append(&buf, quoted)
		delete(quoted, a)
	}
	append(&buf, ']')
	return string(buf[:])
}

// json_quote renders a JSON string literal (escaping quotes, backslashes,
// and control characters — the values are identifiers or paths, but be
// correct anyway). UTF-8 content passes through byte-wise.
json_quote :: proc(s: string, a := context.allocator) -> string {
	buf := make([dynamic]u8, 0, len(s) + 2, a)
	append(&buf, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"':
			append(&buf, "\\\"")
		case '\\':
			append(&buf, "\\\\")
		case '\n':
			append(&buf, "\\n")
		case '\r':
			append(&buf, "\\r")
		case '\t':
			append(&buf, "\\t")
		case:
			if c < 0x20 {
				append(&buf, fmt.aprintf("\\u%04x", c, allocator = a))
				// The aprintf buffer is reclaimed with `a` (arena in
				// practice); nothing to delete per byte.
			} else {
				append(&buf, c)
			}
		}
	}
	append(&buf, '"')
	return string(buf[:])
}
