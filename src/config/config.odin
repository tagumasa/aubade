// Typed configuration model. Defaults live here and only here (the schema
// contract lives in this package; format decision: JSONC,
// one format for every aubade-owned config file). Every string, slice, and
// map reachable from these structs is owned by the allocator the loader ran
// with — in practice the Config_Stack's dedicated arena, so stack_destroy
// releases a whole stack with one free_all.
package config

import "core:strings"

import "src:platform"
import "src:util"

// --- defaults (single source of truth) ---

DEFAULT_TOOL_TIMEOUT_S        :: 30.0
DEFAULT_MAX_TOOL_ANSWER_CHARS :: 150_000
DEFAULT_SYMBOL_INFO_BUDGET_S  :: 10.0
DEFAULT_ENCODING              :: "utf-8"
DEFAULT_LOG_LEVEL             :: "warning"
DEFAULT_MANAGED_DIR_TEMPLATE  :: "$projectDir/" + platform.MANAGED_DIR_NAME
DEFAULT_SEARCH_PROVIDER       :: "auto"
DEFAULT_CONTEXT               :: "desktop-app"
DEFAULT_MODE_LIST             :: []string{"interactive", "editing"}

MAX_CONFIG_BYTES  :: 1 << 20 // 1 MiB cap per config file
MAX_FETCH_LIMIT_B :: 50 * 1024 * 1024

Line_Ending :: enum {
	Lf,
	Crlf,
	Native,
}

// LINE_ENDING_NAMES is the one spelling table for Line_Ending: the
// parser and the load-failure hint derive from it.
LINE_ENDING_NAMES :: []string{"lf", "crlf", "native"}

parse_line_ending :: proc(s: string) -> (Line_Ending, bool) {
	names := LINE_ENDING_NAMES
	for le in Line_Ending {
		if util.ascii_equal_ci(s, names[cast(int)le]) {
			return le, true
		}
	}
	return .Native, false
}

// ascii_lower lowercases ASCII letters, returning a string owned by `a`.
ascii_lower :: proc(s: string, a := context.allocator) -> string {
	out := make([]u8, len(s), a)
	for i in 0..<len(s) {
		c := s[i]
		if c >= 'A' && c <= 'Z' {
			c = c + ('a' - 'A')
		}
		out[i] = c
	}
	return string(out)
}

line_ending_newline :: proc(le: Line_Ending) -> string {
	switch le {
	case .Lf:
		return "\n"
	case .Crlf:
		return "\r\n"
	case .Native:
		return "\r\n" when ODIN_OS == .Windows else "\n"
	}
	return "\n"
}

VALID_SEARCH_PROVIDERS :: []string{"auto", "brave", "tavily", "perplexity", "duckduckgo", "searxng", ""}

// Tool_Inclusion is either incremental mode (excluded/included) or
// fixed mode (an exact set) — never both.
Tool_Inclusion :: struct {
	excluded_tools:          []string,
	included_optional_tools: []string,
	fixed_tools:             []string,
}

// is_fixed_tool_set reports fixed mode. ok == false means fixed_tools was
// combined with an incremental selector (a load error).
is_fixed_tool_set :: proc(t: ^Tool_Inclusion) -> (fixed: bool, ok: bool) {
	if len(t.fixed_tools) > 0 && (len(t.excluded_tools) > 0 || len(t.included_optional_tools) > 0) {
		return false, false
	}
	return len(t.fixed_tools) > 0, true
}

// Shared_Config holds the keys valid in both the global config and a
// project config. The *_set flags preserve "key present" so fallback chains
// (project → global → default) survive loading.
Shared_Config :: struct {
	inclusion:                 Tool_Inclusion,
	symbol_info_budget_s:      f64,
	symbol_info_budget_set:    bool,
	line_ending:               Line_Ending,
	line_ending_set:           bool,
	read_only_memory_patterns: []string,
	ignored_memory_patterns:   []string,
	blocked_shell_commands:    []string,
	allowed_shell_commands:    []string,
	blocked_url_patterns:      []string,
	default_modes:             []string,
	default_modes_set:         bool, // a project's list replaces the global one
}

// default_shared fills the shared defaults.
default_shared :: proc() -> Shared_Config {
	s: Shared_Config
	s.symbol_info_budget_s = DEFAULT_SYMBOL_INFO_BUDGET_S
	return s
}

// resolve_line_ending applies the project → global → native precedence
// every line-ending consumer shares (the stack resolver, the daemon's
// editor settings, the CLI's report writes). Pass a zero-value
// Shared_Config for a layer that failed to load — its *_set flag is
// false, so the chain falls through exactly like a missing key.
resolve_line_ending :: proc(project, global: ^Shared_Config) -> Line_Ending {
	if project.line_ending_set {
		return project.line_ending
	}
	if global.line_ending_set {
		return global.line_ending
	}
	return .Native
}

// resolve_symbol_info_budget_s applies the project → global → default
// precedence for the batch hover-info budget (seconds) that bounds
// symbol_find_implementations' per-result hover pass.
resolve_symbol_info_budget_s :: proc(project, global: ^Shared_Config) -> f64 {
	if project.symbol_info_budget_set {
		return project.symbol_info_budget_s
	}
	if global.symbol_info_budget_set {
		return global.symbol_info_budget_s
	}
	return DEFAULT_SYMBOL_INFO_BUDGET_S
}

Web_Keys_Provider :: struct {
	api_keys:    []string,
	max_results: int,
	enabled:     bool,
}

Web_Keys_Base_Url_Provider :: struct {
	api_keys:    []string,
	base_url:    string,
	max_results: int,
	enabled:     bool,
}

Web_Count_Provider :: struct {
	max_results: int,
	enabled:     bool,
}

Web_Config :: struct {
	fetch_proxy:         string,
	fetch_limit_bytes:   i64,
	search_provider:     string, // "" and "auto" both mean automatic
	allow_private_hosts: bool,
	whitelist_hosts:     []string,
	brave:               Web_Keys_Provider,
	tavily:              Web_Keys_Base_Url_Provider,
	perplexity:          Web_Keys_Provider,
	duckduckgo:          Web_Count_Provider,
	searxng:             Web_Keys_Base_Url_Provider,
}

Global_Config :: struct {
	shared:                         Shared_Config,
	base_modes:                     []string,
	tool_timeout_s:                 f64,
	default_max_tool_answer_chars:  int,
	log_level:                      string,
	eager_language_servers:         bool,
	trace_lsp:                      bool,
	ignored_paths:                  []string,
	project_aubade_folder_location: string,
	web:                            Web_Config,
}

// default_global fills the global defaults; every owned value is allocated
// from `a` so a loaded config and a defaulted one free the same way.
default_global :: proc(a := context.allocator) -> ^Global_Config {
	g := new(Global_Config, a)
	g^ = {}
	g.shared = default_shared()
	g.tool_timeout_s = DEFAULT_TOOL_TIMEOUT_S
	g.default_max_tool_answer_chars = DEFAULT_MAX_TOOL_ANSWER_CHARS
	g.log_level = strings.clone(DEFAULT_LOG_LEVEL, a)
	g.project_aubade_folder_location = strings.clone(DEFAULT_MANAGED_DIR_TEMPLATE, a)
	g.shared.default_modes = clone_string_list(DEFAULT_MODE_LIST, a)
	g.shared.default_modes_set = true // the template ships with this default
	return g
}

// One language_servers entry: name is the language id (the same designation
// the bare-string form and every language_server_* map key use); path, when
// non-empty, is an OS path to the server binary — absolute, "~/"-anchored,
// or relative to the project root (resolved at the daemon's apply site;
// empty means the entry's own command resolution applies as usual).
Language_Server_Entry :: struct {
	name: string,
	path: string,
}

Project_Config :: struct {
	shared:                       Shared_Config,
	project_name:                 string,
	language_servers:             []Language_Server_Entry,
	// language id → explicit argv (argv[0] is the command). An explicit argv
	// wins over an entry path in language_servers and over the built-in
	// registry command and its runtime checks.
	language_server_commands:     map[string][]string,
	// language id → serialized JSON object text merged over the registry
	// entry's static initialization options at the initialize handshake
	// (user top-level keys win). Values are stored as text, not parsed
	// maps, matching the registry's init-options convention.
	language_server_options:      map[string]string,
	ignored_paths:                []string,
	read_only:                    bool,
	ignore_all_files_in_gitignore: bool,
	ignore_gitignore_set:         bool,
	initial_prompt:               string,
	encoding:                     string, // "" → DEFAULT_ENCODING at use sites
	added_modes:                  []string,
	additional_workspace_folders: []string,
}

default_project :: proc(a := context.allocator) -> ^Project_Config {
	p := new(Project_Config, a)
	p^ = {}
	p.shared = default_shared()
	p.encoding = strings.clone(DEFAULT_ENCODING, a)
	return p
}

Context_Def :: struct {
	name:           string,
	description:    string,
	prompt:         string,
	inclusion:      Tool_Inclusion,
	single_project: bool,
}

Mode_Def :: struct {
	name:        string,
	description: string,
	prompt:      string,
	inclusion:   Tool_Inclusion,
}

clone_string_list :: proc(src: []string, a := context.allocator) -> []string {
	out := make([]string, len(src), a)
	for s, i in src {
		out[i] = strings.clone(s, a)
	}
	return out
}

clone_inclusion :: proc(src: ^Tool_Inclusion, a := context.allocator) -> Tool_Inclusion {
	out: Tool_Inclusion
	out.excluded_tools = clone_string_list(src.excluded_tools, a)
	out.included_optional_tools = clone_string_list(src.included_optional_tools, a)
	out.fixed_tools = clone_string_list(src.fixed_tools, a)
	return out
}

clone_context :: proc(src: ^Context_Def, a := context.allocator) -> Context_Def {
	return {
		name           = strings.clone(src.name, a),
		description    = strings.clone(src.description, a),
		prompt         = strings.clone(src.prompt, a),
		inclusion      = clone_inclusion(&src.inclusion, a),
		single_project = src.single_project,
	}
}

clone_mode :: proc(src: ^Mode_Def, a := context.allocator) -> Mode_Def {
	return {
		name        = strings.clone(src.name, a),
		description = strings.clone(src.description, a),
		prompt      = strings.clone(src.prompt, a),
		inclusion   = clone_inclusion(&src.inclusion, a),
	}
}
