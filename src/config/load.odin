// File loaders: global config, project config with the local overlay, and
// user context/mode files (user directory first, then the builtins). Load
// rules: aubade never writes these files; a missing file is
// defaults plus a warning, an unknown key is a warning, a type mismatch is
// a typed error. All allocation goes to `a` — the Config_Stack's arena in
// production — so callers release everything with one free_all.
package config

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:os"
import "core:path/filepath"
import "core:sort"
import "core:strings"
import "src:jsonutil"
import "src:platform"
import "src:util"

// --- known keys (everything else warns and is skipped) ---

SHARED_KEYS :: []string{
	"excluded_tools", "included_optional_tools", "fixed_tools",
	"symbol_info_budget", "line_ending",
	"read_only_memory_patterns", "ignored_memory_patterns",
	"default_modes",
	"blocked_shell_commands", "allowed_shell_commands",
	"blocked_url_patterns",
}

GLOBAL_KEYS :: []string{
	"base_modes", "tool_timeout", "default_max_tool_answer_chars",
	"log_level", "eager_language_servers", "trace_lsp_communication",
	"ignored_paths", "project_aubade_folder_location", "web",
}

PROJECT_KEYS :: []string{
	"project_name", "language_servers", "language_server_commands",
	"language_server_options",
	"ignored_paths", "read_only",
	"ignore_all_files_in_gitignore", "initial_prompt", "encoding",
	"added_modes", "additional_workspace_folders",
}

CONTEXT_KEYS :: []string{
	"description", "prompt", "single_project",
}

MODE_KEYS :: []string{
	"description", "prompt",
}

WEB_PROVIDER_KEYS          :: []string{"api_keys", "max_results", "enabled"}
WEB_PROVIDER_BASE_URL_KEYS :: []string{"api_keys", "base_url", "max_results", "enabled"}
WEB_COUNT_KEYS             :: []string{"max_results", "enabled"}

// --- loader state ---

Loader :: struct {
	label:     string, // file label for diagnostics (borrowed)
	allocator: mem.Allocator,
	warnings:  [dynamic]string,
	err:       platform.Err,
	is_failed: bool,
}

loader_init :: proc(l: ^Loader, label: string, a: mem.Allocator) {
	l^ = {label = label, allocator = a}
	l.warnings = make([dynamic]string, 0, 8, a)
}

load_fail :: proc(l: ^Loader, key: string, expected: string) {
	if l.is_failed {
		return
	}
	l.is_failed = true
	l.err = platform.Wrapped{
		kind = .Invalid,
		msg  = fmt.aprintf("%s: key \"%s\" expects %s", l.label, key, expected, allocator = l.allocator),
	}
}

load_fail_msg :: proc(l: ^Loader, msg: string) {
	if l.is_failed {
		return
	}
	l.is_failed = true
	l.err = platform.Wrapped{kind = .Invalid, msg = strings.clone(msg, l.allocator)}
}

warn :: proc(l: ^Loader, msg: string) {
	append(&l.warnings, strings.clone(msg, l.allocator))
}

warn_unknown :: proc(l: ^Loader, key: string) {
	warn(l, fmt.aprintf("unknown key \"%s\" in %s (skipped)", key, l.label, allocator = l.allocator))
}

// --- field decoders (a JSON null counts as unset) ---

// json_is_null reports the JSON null value: the generated templates
// document "a key set to null (or removed) means unset", so the decoders
// treat a null member as absent.
json_is_null :: proc(v: json.Value) -> bool {
	if v == nil {
		return false
	}
	#partial switch x in v {
	case json.Null:
		return true
	case:
	}
	return false
}

// dec_scalar is the one decoder behind the dec_string/dec_bool/dec_int/
// dec_i64/dec_f64 family: absent or null keys leave the target alone,
// a JSON value of the target's type assigns (strings clone), anything
// else fails the load with the type's expected-shape prose. The
// optional set flag marks an actual assignment.
dec_scalar :: proc(l: ^Loader, obj: json.Value, key: string, out: ^$T, set: ^bool = nil) {
	v, found := jsonutil.obj_get(obj, key)
	if !found || v == nil || json_is_null(v) {
		return
	}
	ok := false
	#partial switch x in v {
	case json.String:
		when T == string {
			out^ = strings.clone(string(x), l.allocator)
			ok = true
		}
	case json.Boolean:
		when T == bool {
			out^ = x
			ok = true
		}
	case json.Integer:
		when T == i64 {
			out^ = x
			ok = true
		} else when T == int {
			out^ = int(x)
			ok = true
		} else when T == f64 {
			out^ = f64(x)
			ok = true
		}
	case json.Float:
		when T == f64 {
			out^ = x
			ok = true
		}
	case:
	}
	if !ok {
		when T == string {
			load_fail(l, key, "a string")
		} else when T == bool {
			load_fail(l, key, "a boolean")
		} else when T == f64 {
			load_fail(l, key, "a number")
		} else {
			load_fail(l, key, "an integer")
		}
		return
	}
	if set != nil {
		set^ = true
	}
}

dec_string :: proc(l: ^Loader, obj: json.Value, key: string, out: ^string) { dec_scalar(l, obj, key, out) }
dec_bool :: proc(l: ^Loader, obj: json.Value, key: string, out: ^bool) { dec_scalar(l, obj, key, out) }
dec_bool_set :: proc(l: ^Loader, obj: json.Value, key: string, out: ^bool, set: ^bool) { dec_scalar(l, obj, key, out, set) }
dec_f64 :: proc(l: ^Loader, obj: json.Value, key: string, out: ^f64) { dec_scalar(l, obj, key, out) }
dec_f64_set :: proc(l: ^Loader, obj: json.Value, key: string, out: ^f64, set: ^bool) { dec_scalar(l, obj, key, out, set) }
dec_int :: proc(l: ^Loader, obj: json.Value, key: string, out: ^int) { dec_scalar(l, obj, key, out) }
dec_i64 :: proc(l: ^Loader, obj: json.Value, key: string, out: ^i64) { dec_scalar(l, obj, key, out) }

dec_strings :: proc(l: ^Loader, obj: json.Value, key: string, out: ^[]string) {
	v, found := jsonutil.obj_get(obj, key)
	if !found || v == nil || json_is_null(v) {
		return
	}
	arr, is_arr := jsonutil.as_array(v)
	if !is_arr {
		load_fail(l, key, "an array of strings")
		return
	}
	list := make([]string, len(arr), l.allocator)
	for ev, i in arr {
		#partial switch x in ev {
		case json.String:
			list[i] = strings.clone(string(x), l.allocator)
		case:
			load_fail(l, key, "an array of strings")
			return
		}
	}
	out^ = list
}

// dec_language_servers decodes the language_servers allowlist. Every
// element is an object {"name": <language id>, "path": <server binary
// path>} — the one unified pattern; a bare string element is refused with a
// steering error. path may be omitted or empty (then the entry's own
// command resolution applies). Unknown object fields are refused; language
// ids are not validated here (unknown ids warn and are skipped at the apply
// site, same as the command map). Duplicate names are kept in order — the
// apply site folds them into a map, where the later entry wins.
dec_language_servers :: proc(l: ^Loader, obj: json.Value, key: string, out: ^[]Language_Server_Entry) {
	v, found := jsonutil.obj_get(obj, key)
	if !found || v == nil || json_is_null(v) {
		return
	}
	arr, is_arr := jsonutil.as_array(v)
	if !is_arr {
		load_fail(l, key, "an array of {name, path} objects")
		return
	}
	entries := make([]Language_Server_Entry, len(arr), l.allocator)
	for ev, i in arr {
		entry := Language_Server_Entry{}
		#partial switch x in ev {
		case json.Object:
			inner := json.Object(x)
			name_v, has_name := inner["name"]
			path_v, has_path := inner["path"]
			fields := 0
			if has_name {
				fields += 1
			}
			if has_path {
				fields += 1
			}
			if !has_name || fields != len(inner) {
				load_fail(l, key, "objects with exactly the fields name (required) and path (optional)")
				return
			}
			#partial switch nv in name_v {
			case json.String:
				entry.name = strings.clone(string(nv), l.allocator)
			case:
				load_fail(l, key, "a string name (the language id)")
				return
			}
			if has_path {
				#partial switch pv in path_v {
				case json.String:
					entry.path = strings.clone(string(pv), l.allocator)
				case:
					load_fail(l, key, "a string path (the server binary's location)")
					return
				}
			}
		case json.String:
			load_fail(
				l,
				key,
				"objects naming the server and its binary (path optional) — bare language ids are not the form",
			)
			return
		case:
			load_fail(l, key, "an array of {name, path} objects")
			return
		}
		if entry.name == "" {
			load_fail(l, key, "a non-empty language id per entry")
			return
		}
		entries[i] = entry
	}
	out^ = entries
}

// dec_string_array_map decodes a {language id → argv array} object. The
// first element is the command, so it must be a non-empty string; language
// ids are not validated here (the config layer cannot see the language
// registry — unknown ids warn and are skipped at the apply site).
dec_string_array_map :: proc(
	l: ^Loader,
	obj: json.Value,
	key: string,
	out: ^map[string][]string,
) {
	v, found := jsonutil.obj_get(obj, key)
	if !found || v == nil || json_is_null(v) {
		return
	}
	m, is_obj := jsonutil.as_object(v)
	if !is_obj {
		load_fail(l, key, "an object mapping language ids to arrays of strings")
		return
	}
	commands := make(map[string][]string, len(m), l.allocator)
	for k, sv in m {
		arr, is_arr := jsonutil.as_array(sv)
		if !is_arr || len(arr) == 0 {
			load_fail(l, key, "an object mapping language ids to non-empty arrays of strings")
			return
		}
		argv := make([]string, len(arr), l.allocator)
		for ev, i in arr {
			#partial switch x in ev {
			case json.String:
				argv[i] = strings.clone(string(x), l.allocator)
			case:
				load_fail(l, key, "an object mapping language ids to arrays of strings")
				return
			}
		}
		if argv[0] == "" {
			load_fail(l, key, "a non-empty command as the first array element")
			return
		}
		commands[strings.clone(k, l.allocator)] = argv
	}
	out^ = commands
}

// dec_json_object_map decodes a {language id → JSON object} map, storing
// each value as serialized object text (the registry's init-options
// convention — parsed maps never sit in the config struct). A non-object
// value is refused; language ids are not validated here (unknown ids
// warn and are skipped at the apply site, same as the command map).
dec_json_object_map :: proc(
	l: ^Loader,
	obj: json.Value,
	key: string,
	out: ^map[string]string,
) {
	v, found := jsonutil.obj_get(obj, key)
	if !found || v == nil || json_is_null(v) {
		return
	}
	m, is_obj := jsonutil.as_object(v)
	if !is_obj {
		load_fail(l, key, "an object mapping language ids to JSON objects")
		return
	}
	options := make(map[string]string, len(m), l.allocator)
	for k, ov in m {
		if _, is_ov_obj := jsonutil.as_object(ov); !is_ov_obj {
			load_fail(l, key, "an object mapping language ids to JSON objects")
			return
		}
		options[strings.clone(k, l.allocator)] = jsonutil.marshal_value(ov, l.allocator)
	}
	out^ = options
}

check_unknown :: proc(l: ^Loader, obj: json.Value, extra: []string) {
	m, is_obj := jsonutil.as_object(obj)
	if !is_obj {
		return
	}
	for k, _ in m {
		if slice.contains(SHARED_KEYS, k) || slice.contains(extra, k) {
			continue
		}
		warn_unknown(l, k)
	}
}

// clone_json_value deep-copies a parsed JSON value into `a`. The parsed tree
// belongs to the load scope; anything stored on a config struct is copied
// so it survives independently of the parse tree.

// --- file reading ---

// read_config_file reads one config file through the read gate. Missing
// is its own outcome (callers apply their absent-file policy); a gate
// refusal (oversized, not a regular file) or a failed read is a typed
// error — folding either into "missing" loaded defaults behind a false
// not-found warning.
read_config_file :: proc(path: string, a := context.allocator) -> (data: []u8, missing: bool, err: platform.Err) {
	gate := util.read_gate(path, MAX_CONFIG_BYTES)
	if gate == .Missing {
		return nil, true, nil
	}
	if gate != .Ok {
		reason := "exceeds the config size cap"
		if gate == .Not_Regular {
			reason = "is not a regular file"
		}
		return nil, false, platform.Wrapped{
			kind = .Invalid,
			msg  = fmt.aprintf("%s %s", path, reason, allocator = a),
		}
	}
	raw, rerr := os.read_entire_file_from_path(path, a)
	if rerr != nil {
		return nil, false, platform.Wrapped{
			kind = .Invalid,
			msg  = fmt.aprintf("%s could not be read", path, allocator = a),
		}
	}
	if len(raw) == 0 {
		// An existing but empty file carries no configuration; the
		// caller's absent-file policy (defaults) is the honest answer.
		delete(raw, a)
		return nil, true, nil
	}
	return raw, false, nil
}

// parse_object_file reads and parses a JSONC file expected to hold a top
// level object. missing is reported separately so callers can apply their
// own missing-file policy (defaults, skip, …).
parse_object_file :: proc(
	path: string,
	a := context.allocator,
) -> (value: json.Value, missing: bool, err: platform.Err) {
	data, miss, rerr := read_config_file(path, a)
	if rerr != nil {
		return nil, false, rerr
	}
	if miss {
		return nil, true, nil
	}
	parsed, jerr := jsonc_parse(data, a)
	if jerr != nil {
		return nil, false, jerr
	}
	if _, is_obj := jsonutil.as_object(parsed); !is_obj {
		return nil, false, platform.Wrapped{
			kind = .Invalid,
			msg  = strings.clone("top level must be an object", a),
		}
	}
	return parsed, false, nil
}

// --- conversion ---

convert_shared :: proc(l: ^Loader, obj: json.Value, s: ^Shared_Config) {
	dec_strings(l, obj, "excluded_tools", &s.inclusion.excluded_tools)
	dec_strings(l, obj, "included_optional_tools", &s.inclusion.included_optional_tools)
	dec_strings(l, obj, "fixed_tools", &s.inclusion.fixed_tools)
	if l.is_failed {
		return
	}
	if _, ok := is_fixed_tool_set(&s.inclusion); !ok {
		load_fail_msg(
			l,
			"fixed_tools cannot be combined with excluded_tools/included_optional_tools",
		)
		return
	}
	dec_f64_set(l, obj, "symbol_info_budget", &s.symbol_info_budget_s, &s.symbol_info_budget_set)
	if v, found := jsonutil.obj_get(obj, "line_ending"); found && v != nil && !json_is_null(v) {
		#partial switch x in v {
		case json.String:
			le, ok := parse_line_ending(string(x))
			if !ok {
				load_fail(l, "line_ending", strings.concatenate({"one of ", util.quoted_join(LINE_ENDING_NAMES, ", ", "\"", l.allocator)}, l.allocator))
			} else {
				s.line_ending = le
				s.line_ending_set = true
			}
		case:
			load_fail(l, "line_ending", "a string")
		}
	}
	dec_strings(l, obj, "read_only_memory_patterns", &s.read_only_memory_patterns)
	dec_strings(l, obj, "ignored_memory_patterns", &s.ignored_memory_patterns)
	dec_strings(l, obj, "blocked_shell_commands", &s.blocked_shell_commands)
	dec_strings(l, obj, "allowed_shell_commands", &s.allowed_shell_commands)
	dec_strings(l, obj, "blocked_url_patterns", &s.blocked_url_patterns)
	dec_strings(l, obj, "default_modes", &s.default_modes)
	if len(s.default_modes) > 0 {
		s.default_modes_set = true
	}
}

// obj_member returns the nested object stored at `key`; a present,
// non-null value of any other shape is a typed load failure — the same
// rule every scalar follows, so a wrong-typed subtree cannot silently
// no-op while its key is listed as known.
obj_member :: proc(l: ^Loader, obj: json.Value, key: string) -> (json.Value, bool) {
	v, found := jsonutil.obj_get(obj, key)
	if !found || v == nil || json_is_null(v) {
		return {}, false
	}
	#partial switch x in v {
	case json.Object:
		return v, true
	case:
		load_fail(l, key, "an object")
		return {}, false
	}
}

convert_global :: proc(l: ^Loader, obj: json.Value, g: ^Global_Config) {
	convert_shared(l, obj, &g.shared)
	dec_strings(l, obj, "base_modes", &g.base_modes)
	dec_f64(l, obj, "tool_timeout", &g.tool_timeout_s)
	dec_int(l, obj, "default_max_tool_answer_chars", &g.default_max_tool_answer_chars)
	dec_string(l, obj, "log_level", &g.log_level)
	if l.is_failed {
		return
	}
	g.log_level = ascii_lower(g.log_level, l.allocator)
	if _, ok := util.log_parse_level(g.log_level); !ok {
		load_fail(l, "log_level", strings.concatenate({"one of ", util.log_levels_quoted(l.allocator)}, l.allocator))
		return
	}
	dec_bool(l, obj, "eager_language_servers", &g.eager_language_servers)
	dec_bool(l, obj, "trace_lsp_communication", &g.trace_lsp)
	dec_strings(l, obj, "ignored_paths", &g.ignored_paths)
	dec_string(l, obj, "project_aubade_folder_location", &g.project_aubade_folder_location)
	if v, ok := obj_member(l, obj, "web"); ok {
		convert_web(l, v, &g.web)
	}
}

convert_web :: proc(l: ^Loader, obj: json.Value, w: ^Web_Config) {
	dec_string(l, obj, "fetch_proxy", &w.fetch_proxy)
	if l.is_failed {
		return
	}
	if w.fetch_proxy != "" && !valid_proxy_scheme(w.fetch_proxy) {
		load_fail(l, "web.fetch_proxy", strings.concatenate(
			{"a ", util.quoted_join(PROXY_SCHEMES, " or ", "", l.allocator), " URL"},
			l.allocator,
		))
		return
	}
	dec_i64(l, obj, "fetch_limit_bytes", &w.fetch_limit_bytes)
	if w.fetch_limit_bytes < 0 || w.fetch_limit_bytes > MAX_FETCH_LIMIT_B {
		load_fail_msg(l, strings.concatenate(
			{"web.fetch_limit_bytes is outside 0..", util.int_to_dec(MAX_FETCH_LIMIT_B, l.allocator)},
			l.allocator,
		))
		return
	}
	dec_string(l, obj, "search_provider", &w.search_provider)
	if l.is_failed {
		return
	}
	w.search_provider = ascii_lower(w.search_provider, l.allocator)
	if !slice.contains(VALID_SEARCH_PROVIDERS, w.search_provider) {
		named := make([dynamic]string, 0, len(VALID_SEARCH_PROVIDERS), context.temp_allocator)
		defer delete(named)
		for p in VALID_SEARCH_PROVIDERS {
			if p != "" {
				append(&named, p)
			}
		}
		load_fail(
			l,
			"web.search_provider",
			strings.concatenate({"one of ", util.quoted_join(named[:], ", ", "\"", l.allocator)}, l.allocator),
		)
		return
	}
	dec_bool(l, obj, "allow_private_hosts", &w.allow_private_hosts)
	dec_strings(l, obj, "whitelist_hosts", &w.whitelist_hosts)
	if v, ok := obj_member(l, obj, "brave"); ok {
		convert_keys_provider(l, v, "web.brave", &w.brave)
	}
	if v, ok := obj_member(l, obj, "tavily"); ok {
		convert_base_url_provider(l, v, "web.tavily", &w.tavily)
	}
	if v, ok := obj_member(l, obj, "perplexity"); ok {
		convert_keys_provider(l, v, "web.perplexity", &w.perplexity)
	}
	if v, ok := obj_member(l, obj, "duckduckgo"); ok {
		convert_count_provider(l, v, "web.duckduckgo", &w.duckduckgo)
	}
	if v, ok := obj_member(l, obj, "searxng"); ok {
		convert_base_url_provider(l, v, "web.searxng", &w.searxng)
	}
}

convert_keys_provider :: proc(l: ^Loader, obj: json.Value, label: string, p: ^Web_Keys_Provider) {
	dec_strings(l, obj, "api_keys", &p.api_keys)
	dec_int(l, obj, "max_results", &p.max_results)
	dec_bool(l, obj, "enabled", &p.enabled)
	check_unknown_prefixed(l, obj, label, WEB_PROVIDER_KEYS)
}

convert_base_url_provider :: proc(
	l: ^Loader,
	obj: json.Value,
	label: string,
	p: ^Web_Keys_Base_Url_Provider,
) {
	dec_strings(l, obj, "api_keys", &p.api_keys)
	dec_string(l, obj, "base_url", &p.base_url)
	dec_int(l, obj, "max_results", &p.max_results)
	dec_bool(l, obj, "enabled", &p.enabled)
	check_unknown_prefixed(l, obj, label, WEB_PROVIDER_BASE_URL_KEYS)
}

convert_count_provider :: proc(l: ^Loader, obj: json.Value, label: string, p: ^Web_Count_Provider) {
	dec_int(l, obj, "max_results", &p.max_results)
	dec_bool(l, obj, "enabled", &p.enabled)
	check_unknown_prefixed(l, obj, label, WEB_COUNT_KEYS)
}

check_unknown_prefixed :: proc(l: ^Loader, obj: json.Value, label: string, allowed: []string) {
	m, is_obj := jsonutil.as_object(obj)
	if !is_obj {
		return
	}
	for k, _ in m {
		if slice.contains(allowed, k) {
			continue
		}
		warn(l, fmt.aprintf("unknown key \"%s.%s\" (skipped)", label, k, allocator = l.allocator))
	}
}

// PROXY_SCHEMES is the one declaration of the accepted fetch_proxy
// schemes: the prefix check and the load-failure hint derive from it.
PROXY_SCHEMES :: []string{"http://", "https://", "socks5://", "socks5h://"}

valid_proxy_scheme :: proc(proxy: string) -> bool {
	schemes := PROXY_SCHEMES
	for s in schemes {
		if strings.has_prefix(proxy, s) {
			return true
		}
	}
	return false
}

convert_project :: proc(l: ^Loader, obj: json.Value, p: ^Project_Config) {
	convert_shared(l, obj, &p.shared)
	dec_string(l, obj, "project_name", &p.project_name)
	dec_language_servers(l, obj, "language_servers", &p.language_servers)
	dec_string_array_map(l, obj, "language_server_commands", &p.language_server_commands)
	dec_json_object_map(l, obj, "language_server_options", &p.language_server_options)
	dec_strings(l, obj, "ignored_paths", &p.ignored_paths)
	dec_bool(l, obj, "read_only", &p.read_only)
	p.ignore_all_files_in_gitignore = true
	dec_bool_set(
		l,
		obj,
		"ignore_all_files_in_gitignore",
		&p.ignore_all_files_in_gitignore,
		&p.ignore_gitignore_set,
	)
	dec_string(l, obj, "initial_prompt", &p.initial_prompt)
	dec_string(l, obj, "encoding", &p.encoding)
	dec_strings(l, obj, "added_modes", &p.added_modes)
	dec_strings(l, obj, "additional_workspace_folders", &p.additional_workspace_folders)
}

// --- public loaders ---

// load_global loads ~/.aubade/config.jsonc (defaults + one warning when the
// file is missing). Warnings are allocated from `a` and read-only for the
// caller.
load_global :: proc(
	home: string,
	a := context.allocator,
) -> (cfg: ^Global_Config, warnings: []string, err: platform.Err) {
	cfg = default_global(a)
	path := platform.config_path(home, a)
	value, missing, perr := parse_object_file(path, a)
	if perr != nil {
		return nil, nil, platform.Wrapped{
			kind = .Invalid,
			msg  = fmt.aprintf("%s: %s", path, platform.err_message(perr, context.temp_allocator), allocator = a),
		}
	}
	l: Loader
	loader_init(&l, path, a)
	if missing {
		warn(&l, fmt.aprintf("%s not found; using defaults", path, allocator = a))
		return cfg, l.warnings[:], nil
	}
	convert_global(&l, value, cfg)
	check_unknown(&l, value, GLOBAL_KEYS)
	if l.is_failed {
		return nil, nil, l.err
	}
	return cfg, l.warnings[:], nil
}

// overlay_local_keys merges the local file's keys over the project object
// (local wins) — except null keys, which are dropped with a warning so
// the project.jsonc value survives: null-means-unset is the layered
// files' convention (a layer removing an inherited value), while the
// local file is an override-only mechanism — letting its nulls revert a
// project key to the global default silently re-enabled things the
// project had turned off. Object maps are references, so the merge
// mutates `value` in place; a non-object on either side leaves the base
// untouched.
overlay_local_keys :: proc(l: ^Loader, value, local_value: json.Value) {
	base, ok := jsonutil.as_object(value)
	if !ok {
		return
	}
	over, lok := jsonutil.as_object(local_value)
	if !lok {
		return
	}
	for k, v in over {
		if v == nil || json_is_null(v) {
			warn(l, fmt.aprintf(
				"ignoring null override key in project.local.jsonc: %s", k, allocator = l.allocator,
			))
			continue
		}
		base[k] = v
	}
}

// load_project loads <managed>/{project.jsonc,project.local.jsonc}. Keys in
// the local file override the same keys in project.jsonc; the merged object
// is converted once. A missing project.jsonc is defaults plus a warning —
// project.local.jsonc still applies over those defaults.
load_project :: proc(
	managed_dir: string,
	a := context.allocator,
) -> (cfg: ^Project_Config, warnings: []string, err: platform.Err) {
	cfg = default_project(a)
	path := platform.project_config_path(managed_dir, a)
	value, missing, perr := parse_object_file(path, a)
	if perr != nil {
		return nil, nil, platform.Wrapped{
			kind = .Invalid,
			msg  = fmt.aprintf("%s: %s", path, platform.err_message(perr, context.temp_allocator), allocator = a),
		}
	}
	local_path := platform.project_local_path(managed_dir, a)
	l: Loader
	loader_init(&l, path, a)
	local_value, local_missing, local_err := parse_object_file(local_path, a)
	if local_err != nil {
		return nil, nil, platform.Wrapped{
			kind = .Invalid,
			msg = fmt.aprintf(
				"%s: %s",
				local_path,
				platform.err_message(local_err, context.temp_allocator),
				allocator = a,
			),
		}
	}
	if missing {
		warn(&l, fmt.aprintf("%s not found; using defaults", path, allocator = a))
		// An absent project.jsonc still honors project.local.jsonc: without
		// a base the local object converts directly over the defaults.
		if !local_missing {
			value = local_value
		}
	} else if !local_missing {
		overlay_local_keys(&l, value, local_value)
	}
	convert_project(&l, value, cfg)
	check_unknown(&l, value, PROJECT_KEYS)
	if l.is_failed {
		return nil, nil, l.err
	}
	return cfg, l.warnings[:], nil
}

// validate_project_data runs the same conversion and unknown-key checks
// load_project applies, against candidate project.jsonc bytes in memory —
// the write path (the config_set/config_delete tools) refuses an edit
// whose result would not load: a parse failure or a wrong value shape
// returns the loader's typed error before the file is touched (the key
// NAME is refused up front via project_key_known; unknown keys already in
// the file keep their loader treatment — warned and skipped). Runs on the
// caller's allocator (a request arena in the write path); nothing
// outlives the call.
validate_project_data :: proc(data: []u8, a := context.allocator) -> platform.Err {
	parsed, jerr := jsonc_parse(data, a)
	if jerr != nil {
		return jerr
	}
	if _, is_obj := jsonutil.as_object(parsed); !is_obj {
		return platform.Wrapped{
			kind = .Invalid,
			msg  = strings.clone("top level must be an object", a),
		}
	}
	cfg := default_project(a)
	l: Loader
	loader_init(&l, "project.jsonc candidate", a)
	convert_project(&l, parsed, cfg)
	check_unknown(&l, parsed, PROJECT_KEYS)
	if l.is_failed {
		return l.err
	}
	return nil
}

// project_key_known reports whether a key may appear at the top level of
// project.jsonc — the acceptance set check_unknown applies (project keys
// plus shared keys). Write surfaces refuse unknown keys up front instead
// of skipping them with a warning like the read path does.
project_key_known :: proc(key: string) -> bool {
	return slice.contains(PROJECT_KEYS, key) || slice.contains(SHARED_KEYS, key)
}

// load_project_for_root resolves the project's managed directory (honoring
// the global folder-location template; an unreadable global falls back to
// the default location) and loads its project config. The single resolver
// for every consumer that starts from a bare project root.
load_project_for_root :: proc(
	project_root: string,
	home: string,
	a := context.allocator,
	// global_location carries an already-loaded global config's
	// project_aubade_folder_location (the caller that loaded the global
	// passes it through — re-parsing the global per call doubled the
	// reads and parses on every config-composing path).
	global_location: ^string = nil,
) -> (cfg: ^Project_Config, warnings: []string, err: platform.Err) {
	managed_dir_location := ""
	if global_location != nil {
		managed_dir_location = global_location^
	} else {
		global, _, gerr := load_global(home, a)
		if gerr == nil {
			managed_dir_location = global.project_aubade_folder_location
		}
	}
	managed := managed_dir_for(project_root, managed_dir_location, a)
	return load_project(managed, a)
}

// entity_name_safe accepts plain names only — anything that could travel a
// path (separators, dot-dot) is rejected before it reaches the filesystem.
entity_name_safe :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 128 || name == "." || name == ".." {
		return false
	}
	for c in name {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.'
		if !ok {
			return false
		}
	}
	return true
}

// load_context resolves a context by name: the user's
// $AUBADE_HOME/contexts/<name>.jsonc first, then the builtins. The body
// is load_resource (shared with the mode family).
load_context :: proc(home: string, name: string, a := context.allocator) -> (Context_Def, platform.Err) {
	builtins := BUILTIN_CONTEXTS
	return load_resource(name, platform.contexts_dir(home, a), CONTEXT_KEYS, builtins, "context", clone_context, a)
}

// load_mode resolves a mode by name: the user's
// $AUBADE_HOME/modes/<name>.jsonc first, then the builtins. The body
// is load_resource (shared with the context family).
load_mode :: proc(home: string, name: string, a := context.allocator) -> (Mode_Def, platform.Err) {
	builtins := BUILTIN_MODES
	return load_resource(name, platform.modes_dir(home, a), MODE_KEYS, builtins, "mode", clone_mode, a)
}

// load_resource is the shared resolver behind load_context/load_mode
// (the $T device list_resource_names already uses): user file first,
// builtins second, with the fixed-set legality check and unknown-key
// sweep over the family's key list. Contexts additionally decode
// single_project — the only field the two Def structs do not share.
load_resource :: proc(
	name:     string,
	dir:      string,
	keys:     []string,
	builtins: []$T,
	entity:   string,
	clone:    proc(src: ^T, a: mem.Allocator) -> T,
	a := context.allocator,
) -> (def: T, err: platform.Err) {
	if !entity_name_safe(name) {
		return {}, platform.Wrapped{
			kind = .Invalid,
			msg  = fmt.aprintf("invalid %s name", entity, allocator = a),
		}
	}
	path, _ := filepath.join([]string{dir, strings.concatenate({name, ".jsonc"}, a)}, a)
	value, missing, perr := parse_object_file(path, a)
	if perr != nil {
		return {}, platform.Wrapped{
			kind = .Invalid,
			msg  = fmt.aprintf("%s: %s", path, platform.err_message(perr, context.temp_allocator), allocator = a),
		}
	}
	if !missing {
		l: Loader
		loader_init(&l, path, a)
		def.name = strings.clone(name, a)
		dec_string(&l, value, "description", &def.description)
		dec_string(&l, value, "prompt", &def.prompt)
		when T == Context_Def {
			// The set flag is not consulted for this key; a stack flag
			// keeps the decoder's signature without the arena allocation.
			single_project_set: bool
			dec_bool_set(&l, value, "single_project", &def.single_project, &single_project_set)
		}
		dec_strings(&l, value, "excluded_tools", &def.inclusion.excluded_tools)
		dec_strings(&l, value, "included_optional_tools", &def.inclusion.included_optional_tools)
		dec_strings(&l, value, "fixed_tools", &def.inclusion.fixed_tools)
		if !l.is_failed {
			if _, ok := is_fixed_tool_set(&def.inclusion); !ok {
				load_fail_msg(
					&l,
					"fixed_tools cannot be combined with excluded_tools/included_optional_tools",
				)
			}
		}
		check_unknown(&l, value, keys)
		if l.is_failed {
			return {}, l.err
		}
		return def, nil
	}
	for i in 0..<len(builtins) {
		if builtins[i].name == name {
			src := builtins[i]
			return clone(&src, a), nil
		}
	}
	return {}, platform.Wrapped{
		kind = .NotFound,
		msg  = fmt.aprintf("%s \"%s\" not found (looked in %s, then builtins)", entity, name, dir, allocator = a),
	}
}

// list_mode_names enumerates the selectable modes: the user's
// $AUBADE_HOME/modes/*.jsonc plus the builtins (user files shadow
// same-named builtins). Sorted, deduplicated, arena-owned.
list_mode_names :: proc(home: string, a := context.allocator) -> []string {
	builtins := BUILTIN_MODES
	return list_resource_names(platform.modes_dir(home, a), builtins, a)
}

// list_context_names enumerates the selectable contexts the same way
// (the context family's listing twin).
list_context_names :: proc(home: string, a := context.allocator) -> []string {
	builtins := BUILTIN_CONTEXTS
	return list_resource_names(platform.contexts_dir(home, a), builtins, a)
}

// list_resource_names merges a user resource directory's *.jsonc names
// with the built-in definitions' names (user files shadow same-named
// builtins). Sorted, deduplicated, arena-owned.
list_resource_names :: proc(dir: string, builtins: $T, a := context.allocator) -> []string {
	out := make([dynamic]string, 0, 16, a)
	if entries, derr := os.read_directory_by_path(dir, -1, a); derr == nil {
		for e in entries {
			if strings.has_suffix(e.name, ".jsonc") && len(e.name) > 5 {
				append(&out, strings.clone(e.name[:len(e.name) - 5], a))
			}
		}
		os.file_info_slice_delete(entries, a)
	}
	for i in 0..<len(builtins) {
		append(&out, builtins[i].name)
	}
	sort.quick_sort(out[:])
	// Dedup in place (user shadows builtin; sort put them adjacent).
	w := 0
	for r in 0..<len(out) {
		if w == 0 || out[w - 1] != out[r] {
			out[w] = out[r]
			w += 1
		}
	}
	owned := make([]string, w, a)
	copy(owned, out[:w])
	delete(out)
	return owned
}

// managed_dir_for resolves the per-project managed directory from the
// global template ($projectDir / $projectFolderName placeholders). A
// relative result is anchored under the project root. The placeholder
// passes and the clean are intra-procedure scratch — their intermediates
// die with the temp frame, and only the resolved directory is cloned
// into `a` (callers hand this daemon- and CLI-lifetime allocators, not
// arenas).
managed_dir_for :: proc(project_root: string, template: string, a := context.allocator) -> string {
	t := template
	if t == "" {
		t = DEFAULT_MANAGED_DIR_TEMPLATE
	}
	ta := context.temp_allocator
	res := subst_placeholder(t, "$projectDir", project_root, ta)
	res = subst_placeholder(res, "$projectFolderName", filepath.base(project_root), ta)
	res, _ = filepath.clean(res, ta)
	if !filepath.is_abs(res) {
		res, _ = filepath.join([]string{project_root, res}, ta)
	}
	return strings.clone(res, a)
}

// managed_rel_for returns the managed directory's project-relative
// spelling — the location identity every project-surface exclusion of
// aubade's own state compares against (the file walks, the workspace-root
// scan, the mutating file faces), so those checks follow the folder
// template instead of the default directory name. "" when the template
// places the directory outside the project root or resolves to the root
// itself: no project path is state then. The result is owned by `a`; the
// derivation scratch stays on the temp allocator.
managed_rel_for :: proc(project_root, template: string, a := context.allocator) -> string {
	managed := managed_dir_for(project_root, template, context.temp_allocator)
	if !strings.has_prefix(managed, project_root) {
		return ""
	}
	rest := managed[len(project_root):]
	if rest == "" {
		return "" // the template resolved to the project root itself
	}
	if rest[0] == '/' || rest[0] == '\\' {
		rest = rest[1:]
	} else if project_root[len(project_root) - 1] == '/' || project_root[len(project_root) - 1] == '\\' {
		// A drive-root spelling ("C:\") already ends in the separator.
	} else {
		return "" // the prefix is not a whole path segment
	}
	rel, _ := strings.replace_all(rest, "\\", "/", context.temp_allocator)
	return strings.clone(rel, a)
}

// subst_placeholder replaces every occurrence of `old` with `repl`; the
// result is always freshly allocated (even when nothing matched).
subst_placeholder :: proc(s: string, old: string, repl: string, a := context.allocator) -> string {
	out, allocated := strings.replace_all(s, old, repl, a)
	if !allocated {
		return strings.clone(s, a) // keep the always-fresh contract
	}
	return out
}

// global_managed_template reads the configured per-project folder
// template best effort ("" = the default template): an absent or
// unreadable global config degrades to the default instead of failing
// the caller — discovery and the state resolvers share this tolerance.
global_managed_template :: proc(home: string) -> string {
	if global, _, gerr := load_global(home, context.temp_allocator); gerr == nil {
		return global.project_aubade_folder_location
	}
	return ""
}

// managed_dir_for_root resolves one project's managed directory (config
// files, index DB, memories, generated state) from the global folder
// template. THE resolver for per-project state locations — every
// consumer goes through it; none re-derives or pins a directory name.
managed_dir_for_root :: proc(project_root, home: string, a := context.allocator) -> string {
	return managed_dir_for(project_root, global_managed_template(home), a)
}

// find_project_root searches upwards from `start` for a project root: a
// directory holding the managed project config (the managed directory
// resolved from the global template, so a relocated folder is still the
// marker), falling back to a `.git` directory (two passes). "" when
// neither marker is found. The result is allocated from `allocator`.
find_project_root :: proc(start, home: string, allocator := context.allocator) -> string {
	template := global_managed_template(home)
	dirs := make([dynamic]string, 0, 8, context.temp_allocator)
	defer delete(dirs)
	cur := start
	for {
		append(&dirs, cur)
		parent := filepath.dir(cur)
		if parent == cur || parent == "" || parent == "." {
			break
		}
		cur = parent
	}

	for d in dirs {
		managed := managed_dir_for(d, template, context.temp_allocator)
		cfg, _ := filepath.join([]string{managed, platform.PROJECT_CONFIG_NAME}, context.temp_allocator)
		if os.is_file(cfg) {
			return strings.clone(d, allocator)
		}
	}
	for d in dirs {
		git, _ := filepath.join([]string{d, ".git"}, context.temp_allocator)
		if os.is_directory(git) {
			return strings.clone(d, allocator)
		}
	}
	return ""
}
