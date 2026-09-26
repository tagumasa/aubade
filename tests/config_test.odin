// Config package tests: JSONC stripping, load rules (missing → defaults +
// warning, unknown key → warning, type mismatch → typed error), the local
// overlay, builtin resolution with the new tool names, stack mode
// resolution and precedence, templates, and the projects registry. All
// loaders receive explicit temp homes — no AUBADE_HOME environment access.
package tests

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "src:config"
import "src:jsonutil"
import "src:platform"
import "src:ts"
import "src:web"

temp_home :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "aubade-cfg-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	return dir
}

@(test)
config_managed_dir_for_root_follows_template :: proc(t: ^testing.T) {
	// A configured template places the managed directory; a config-less
	// home falls back to the default name (whose one spelling lives in
	// platform.MANAGED_DIR_NAME).
	home := temp_home(t)
	defer {
		_ = os.remove_all(home)
		delete(home)
	}
	cfg, _ := filepath.join([]string{home, "config.jsonc"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(
		cfg,
		"{\"project_aubade_folder_location\": \"$projectDir/.state\"}\n",
		os.Permissions{.Read_User, .Write_User},
	)
	root := temp_home(t)
	defer {
		_ = os.remove_all(root)
		delete(root)
	}

	moved := config.managed_dir_for_root(root, home, context.allocator)
	want, _ := filepath.join([]string{root, ".state"}, context.temp_allocator)
	testing.expect(t, moved == want)
	delete(moved, context.allocator)

	plain := temp_home(t)
	defer {
		_ = os.remove_all(plain)
		delete(plain)
	}
	def := config.managed_dir_for_root(root, plain, context.allocator)
	dwant, _ := filepath.join([]string{root, platform.MANAGED_DIR_NAME}, context.temp_allocator)
	testing.expect(t, def == dwant)
	delete(def, context.allocator)

	// The rel-spelling derivation every state-exclusion consumer compares
	// against: the template's placement in project-relative terms, ""
	// when it sits outside the project.
	rel := config.managed_rel_for(root, "$projectDir/.state", context.allocator)
	testing.expect(t, rel == ".state")
	delete(rel, context.allocator)

	nested := config.managed_rel_for(root, "$projectDir/.meta/state", context.allocator)
	testing.expect(t, nested == ".meta/state")
	delete(nested, context.allocator)

	// A real absolute path outside the project (the second temp home) —
	// a drive-less rooted spelling like "/elsewhere" would carry
	// platform-dependent absolute-ness instead.
	outside := config.managed_rel_for(root, plain, context.allocator)
	testing.expect(t, outside == "")

	dflt := config.managed_rel_for(root, "", context.allocator)
	testing.expect(t, dflt == platform.MANAGED_DIR_NAME)
	delete(dflt, context.allocator)
}

// The configuration docs hand-copy the config defaults for the reference
// table and the licence catalogue totals the grammar registry; this is
// the binding that fails when a constant moves without its documented
// figure (the same detection the cross-layer tables get — the docs are
// repo files the test can read).
@(test)
docs_configuration_defaults_match_constants :: proc(t: ^testing.T) {
	raw, rerr := os.read_entire_file("docs/configuration.md", context.temp_allocator)
	if rerr != nil {
		testing.expectf(t, false, "docs/configuration.md unreadable: %v", rerr)
		return
	}
	doc := string(raw)

	// int_cell extracts the default cell of a `key` | `<digits>` row.
	int_cell :: proc(doc: string, key: string) -> (value: int, ok: bool) {
		needle := strings.concatenate({"`", key, "` | `"}, context.temp_allocator)
		i := strings.index(doc, needle)
		if i < 0 {
			return 0, false
		}
		rest := doc[i + len(needle):]
		end := 0
		for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' {
			end += 1
		}
		if end == 0 {
			return 0, false
		}
		v := 0
		for c in rest[:end] {
			v = v * 10 + int(c - '0')
		}
		return v, true
	}
	// str_cell reports the `key` | `"<want>"` row's presence.
	str_cell :: proc(doc, key, want: string) -> bool {
		needle := strings.concatenate({"`", key, "` | `\"", want, "\"`"}, context.temp_allocator)
		return strings.contains(doc, needle)
	}

	got, ok := int_cell(doc, "tool_timeout")
	testing.expectf(t, ok && got == int(config.DEFAULT_TOOL_TIMEOUT_S), "tool_timeout doc default must track DEFAULT_TOOL_TIMEOUT_S")
	got, ok = int_cell(doc, "default_max_tool_answer_chars")
	testing.expectf(t, ok && got == config.DEFAULT_MAX_TOOL_ANSWER_CHARS, "default_max_tool_answer_chars doc default must track the constant")
	got, ok = int_cell(doc, "symbol_info_budget")
	testing.expectf(t, ok && got == int(config.DEFAULT_SYMBOL_INFO_BUDGET_S), "symbol_info_budget doc default must track the constant")

	// The size cap reads "capped at <n> MiB".
	cap_i := strings.index(doc, "capped at ")
	testing.expectf(t, cap_i >= 0, "the config-size cap sentence must stay")
	if cap_i >= 0 {
		rest := doc[cap_i + len("capped at "):]
		end := 0
		for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' {
			end += 1
		}
		mib := 0
		for c in rest[:end] {
			mib = mib * 10 + int(c - '0')
		}
		testing.expectf(t, mib == config.MAX_CONFIG_BYTES >> 20, "the documented MiB cap must track MAX_CONFIG_BYTES")
	}

	testing.expectf(t, str_cell(doc, "log_level", config.DEFAULT_LOG_LEVEL), "log_level doc default must track DEFAULT_LOG_LEVEL")
	testing.expectf(t, str_cell(doc, "encoding", config.DEFAULT_ENCODING), "encoding doc default must track DEFAULT_ENCODING")

	// default_modes renders the DEFAULT_MODE_LIST as the quoted array.
	modes := strings.concatenate({"`default_modes` | `["}, context.temp_allocator)
	for m, i in config.DEFAULT_MODE_LIST {
		if i > 0 {
			modes = strings.concatenate({modes, ", "}, context.temp_allocator)
		}
		modes = strings.concatenate({modes, "\"", m, "\""}, context.temp_allocator)
	}
	modes = strings.concatenate({modes, "]`"}, context.temp_allocator)
	testing.expectf(t, strings.contains(doc, modes), "default_modes doc default must track DEFAULT_MODE_LIST")

	// The licence catalogue's grammar total matches the registry table.
	lic_raw, lerr := os.read_entire_file("docs/licenses.md", context.temp_allocator)
	if lerr != nil {
		testing.expectf(t, false, "docs/licenses.md unreadable: %v", lerr)
		return
	}
	lic := string(lic_raw)
	total_at := strings.index(lic, " grammars in total")
	testing.expectf(t, total_at > 0, "the grammar total sentence must stay")
	if total_at > 0 {
		start := total_at
		for start > 0 && lic[start - 1] >= '0' && lic[start - 1] <= '9' {
			start -= 1
		}
		n := 0
		for c in lic[start:total_at] {
			n = n * 10 + int(c - '0')
		}
		testing.expectf(t, n == len(ts.GRAMMARS), "licenses.md grammar total %d must track the registry (%d)", n, len(ts.GRAMMARS))
	}
}

// The configuration docs hand-copy the builtin mode and context rosters
// into two catalogue tables; this binds both directions — every builtin
// row must appear, and every documented row must name a builtin — so a
// rename or addition fails the suite instead of staling the catalogue.
@(test)
docs_catalogue_rosters_match_builtins :: proc(t: ^testing.T) {
	raw, rerr := os.read_entire_file("docs/configuration.md", context.temp_allocator)
	if rerr != nil {
		testing.expectf(t, false, "docs/configuration.md unreadable: %v", rerr)
		return
	}
	doc := string(raw)

	// section_rows collects the backticked first cell of every table row
	// under the named "## <title>" heading, up to the next section.
	section_rows :: proc(doc, title: string) -> []string {
		heading := strings.concatenate({"## ", title}, context.temp_allocator)
		h := strings.index(doc, heading)
		if h < 0 {
			return nil
		}
		rest := doc[h + len(heading):]
		if end := strings.index(rest, "\n## "); end >= 0 {
			rest = rest[:end]
		}
		out := make([dynamic]string, 0, 8, context.temp_allocator)
		for rest != "" {
			line := rest
			if nl := strings.index(rest, "\n"); nl >= 0 {
				line = rest[:nl]
				rest = rest[nl + 1:]
			} else {
				rest = ""
			}
			if len(line) >= 4 && line[:3] == "| `" {
				if close := strings.index(line[3:], "`"); close > 0 {
					append(&out, line[3:3 + close])
				}
			}
		}
		return out[:]
	}

	mode_rows    := section_rows(doc, "Modes")
	context_rows := section_rows(doc, "Contexts")

	for m in config.BUILTIN_MODES {
		listed := false
		for n in mode_rows {
			if n == m.name {
				listed = true
				break
			}
		}
		testing.expectf(t, listed, "docs mode catalogue must list builtin mode %q", m.name)
	}
	for n in mode_rows {
		known := false
		for m in config.BUILTIN_MODES {
			if m.name == n {
				known = true
				break
			}
		}
		testing.expectf(t, known, "docs mode catalogue lists unknown mode %q", n)
	}

	for c in config.BUILTIN_CONTEXTS {
		listed := false
		for n in context_rows {
			if n == c.name {
				listed = true
				break
			}
		}
		testing.expectf(t, listed, "docs context catalogue must list builtin context %q", c.name)
	}
	for n in context_rows {
		known := false
		for c in config.BUILTIN_CONTEXTS {
			if c.name == n {
				known = true
				break
			}
		}
		testing.expectf(t, known, "docs context catalogue lists unknown context %q", n)
	}
}

// write_config_file is the shared fixture writer. Its failure paths report
// and return instead of failing the test: callers run with live daemon
// pairs whose teardown is defer-protected, and fail_now fires past that
// defer stack — a missing file then surfaces through the caller's own
// load-time expects.
write_config_file :: proc(t: ^testing.T, path: string, content: string) {
	os.make_directory_all(filepath.dir(path), os.Permissions{.Read_User, .Write_User, .Execute_User})
	f, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions{.Read_User, .Write_User})
	if err != nil {
		testing.expectf(t, false, "failed to open config file for writing: %s", path)
		return
	}
	if _, werr := os.write(f, transmute([]u8)content); werr != nil {
		os.close(f)
		testing.expectf(t, false, "failed to write config file: %s", path)
		return
	}
	os.close(f)
}

warnings_contain :: proc(warnings: []string, needle: string) -> bool {
	for w in warnings {
		if strings.contains(w, needle) {
			return true
		}
	}
	return false
}

// Deep nesting must be a typed parse error, not a stack-exhaustion crash
// in the core parser (a crash here kills the whole runner, so the pass
// itself is the regression signal).
@(test) jsonc_deep_nesting_rejected :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	buf := make([]u8, 100_000, a)
	for i in 0..<len(buf) {
		buf[i] = '['
	}
	value, err := config.jsonc_parse(buf, a)
	testing.expect(t, err != nil, "deep nesting must be a typed error")
	testing.expect(t, value == nil)
}

@(test) jsonc_comments_and_trailing_commas :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	src := `{
	// a line comment with "quotes"
	"weird": "http://example.com//not-a-comment",
	/* a block
	   comment */ "n": 1,
	"list": [1, 2, 3,],
	"obj": {"k": "v",},
}`

	value, err := config.jsonc_parse(transmute([]u8)src, a)
	testing.expect(t, err == nil, "jsonc must parse")

	weird, ok := jsonutil.obj_get(value, "weird")
	testing.expect(t, ok, "weird key present")
	#partial switch x in weird {
	case json.String:
		testing.expect_value(t, string(x), "http://example.com//not-a-comment")
	case:
		testing.expect(t, false, "weird must be a string")
	}

	n, ok2 := jsonutil.obj_get(value, "n")
	testing.expect(t, ok2, "n key present")
	#partial switch x in n {
	case json.Integer:
		testing.expect_value(t, i64(x), 1)
	case:
		testing.expect(t, false, "n must stay an integer (parse_integers)")
	}

	list, ok3 := jsonutil.obj_get(value, "list")
	testing.expect(t, ok3, "list key present")
	if arr, is_arr := jsonutil.as_array(list); is_arr {
		testing.expect_value(t, len(arr), 3)
	} else {
		testing.expect(t, false, "list must be an array")
	}
}

@(test) jsonc_unterminated_block_comment :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	bad_src := `{"a": 1 /* never closed`
	_, err := config.jsonc_parse(transmute([]u8)bad_src, a)
	testing.expect(t, err != nil, "unterminated block comment must fail")
	testing.expect_value(t, platform.err_kind(err), platform.Err_Kind.Invalid)
}

@(test) jsonc_parse_reports_error_position :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// A typo'd value must surface as a positioned message (parser kind
	// plus the tokenizer's line/column/offset — at or just past the
	// offending token), not the one-size generic text.
	bad_src := `{"ok": 1, "bad": trXe}`
	_, err := config.jsonc_parse(transmute([]u8)bad_src, a)
	testing.expect(t, err != nil, "malformed value must fail")
	if err == nil {
		return
	}
	msg := platform.err_message(err, context.temp_allocator)
	testing.expect(t, strings.contains(msg, "line 1"), msg)
	testing.expect(t, strings.contains(msg, "column"), msg)
	testing.expect(t, strings.contains(msg, "offset"), msg)
}

@(test)
jsonc_parse_leaves_the_caller_context_alone :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&scratch)
	a := mem.dynamic_arena_allocator(&scratch)

	saved := context.allocator
	bad_src := `{"ok": 1, "bad": trXe}`
	_, err := config.jsonc_parse(transmute([]u8)bad_src, a)
	testing.expect(t, err != nil, "malformed input must fail")
	if err == nil {
		return
	}
	testing.expect(t, context.allocator == saved, "the caller's context allocator must survive the parse")

	// The error text rides the parse allocator like every other config
	// error: it must survive the caller's scratch reset — a temp-built
	// message reads freed bytes once the reset lands, and the scribble
	// makes that visible.
	mem.free_all(context.temp_allocator)
	noise := make([]u8, 1 << 20, context.temp_allocator)
	for i in 0..<len(noise) {
		noise[i] = 0xAA
	}
	msg := platform.err_message(err, context.temp_allocator)
	testing.expect(t, strings.contains(msg, "malformed JSON"), msg)
	delete(noise, context.temp_allocator)
}

@(test) global_defaults_then_load :: proc(t: ^testing.T) {
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Missing file: defaults plus one warning, nothing written.
	g, warnings, err := config.load_global(home, a)
	testing.expect(t, err == nil, "missing config must load defaults")
	testing.expect_value(t, g.tool_timeout_s, config.DEFAULT_TOOL_TIMEOUT_S)
	testing.expect_value(t, g.log_level, config.DEFAULT_LOG_LEVEL)
	testing.expect_value(t, len(g.shared.default_modes), 2)
	testing.expect(t, warnings_contain(warnings, "not found"), "missing file must warn")
	testing.expect(t, !os.exists(platform.config_path(home, context.temp_allocator)), "no file may be created on read")

	path := platform.config_path(home, context.temp_allocator)
	write_config_file(
		t,
		path,
		`{
	// small override set
	"tool_timeout": 45,
	"log_level": "Info",
	"line_ending": "lf",
		"base_modes": ["no-onboarding"],
		"default_modes": ["interactive"],
		"blocked_url_patterns": ["(?i)^https://evil\\."],
		"web": {"search_provider": "brave", "brave": {"enabled": true, "api_keys": ["k1"]}},
		"legacy_dashboard_key": true,
}`,
	)

	g, warnings, err = config.load_global(home, a)
	testing.expect(t, err == nil, "load must succeed")
	testing.expect_value(t, g.tool_timeout_s, 45.0)
	testing.expect_value(t, g.log_level, "info") // case-normalized
	testing.expect_value(t, g.shared.line_ending, config.Line_Ending.Lf)
	testing.expect(t, warnings_contain(warnings, "legacy_dashboard_key"), "unknown key must warn")
	testing.expect_value(t, g.web.search_provider, "brave")
	testing.expect_value(t, len(g.web.brave.api_keys), 1)
	testing.expect(t, g.web.brave.enabled)
	testing.expect_value(t, len(g.shared.blocked_url_patterns), 1)
}

@(test) global_type_mismatch_is_typed_error :: proc(t: ^testing.T) {
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	write_config_file(t, platform.config_path(home, context.temp_allocator), `{"tool_timeout": "soon"}`)
	_, _, err := config.load_global(home, a)
	testing.expect(t, err != nil, "type mismatch must fail")
	testing.expect_value(t, platform.err_kind(err), platform.Err_Kind.Invalid)
	testing.expect(t, strings.contains(platform.err_message(err), "tool_timeout"), "error must name the key")
}

@(test) fixed_tools_exclusivity_rejected :: proc(t: ^testing.T) {
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	write_config_file(
		t,
		platform.config_path(home, context.temp_allocator),
		`{"fixed_tools": ["symbol_find"], "excluded_tools": ["shell_run"]}`,
	)
	_, _, err := config.load_global(home, a)
	testing.expect(t, err != nil, "fixed + excluded must fail")
	testing.expect_value(t, platform.err_kind(err), platform.Err_Kind.Invalid)
}

@(test) project_local_overlay :: proc(t: ^testing.T) {
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	managed_dir := strings.concatenate({home, "/proj/.aubade"}, context.temp_allocator)
	write_config_file(
		t,
		platform.project_config_path(managed_dir, context.temp_allocator),
		`{
	"project_name": "demo",
	"language_servers": [{"name": "go"}],
	"read_only": false,
	"encoding": "utf-8",
}`,
	)
	write_config_file(
		t,
		platform.project_local_path(managed_dir, context.temp_allocator),
		`{
	// local overrides only
	"read_only": true,
	"stale_key": 1,
}`,
	)

	p, warnings, err := config.load_project(managed_dir, a)
	testing.expect(t, err == nil, "project load must succeed")
	testing.expect_value(t, p.project_name, "demo")
	testing.expect(t, p.read_only, "local overlay must win")
	testing.expect_value(t, p.encoding, "utf-8")
	testing.expect(t, warnings_contain(warnings, "stale_key"), "local unknown key must warn")
}

// A null key in project.local.jsonc is a no-op with a warning: the local
// file is an override-only mechanism, so a null cannot unset a project
// value back to the global default (null-means-unset belongs to the
// layered files).
@(test) project_local_null_key_keeps_project_value :: proc(t: ^testing.T) {
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	managed_dir := strings.concatenate({home, "/proj/.aubade"}, context.temp_allocator)
	write_config_file(
		t,
		platform.project_config_path(managed_dir, context.temp_allocator),
		`{
	"language_servers": [{"name": "go"}],
	"read_only": true,
}`,
	)
	write_config_file(
		t,
		platform.project_local_path(managed_dir, context.temp_allocator),
		`{
	"read_only": null,
}`,
	)

	p, warnings, err := config.load_project(managed_dir, a)
	testing.expect(t, err == nil, "project load must succeed")
	testing.expect(t, p.read_only, "the project's value must survive a local null")
	testing.expect(
		t,
		warnings_contain(warnings, "ignoring null override key"),
		"the dropped null must warn",
	)
}

@(test) project_language_server_commands :: proc(t: ^testing.T) {
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	managed_dir := strings.concatenate({home, "/proj/.aubade"}, context.temp_allocator)
	write_config_file(
		t,
		platform.project_config_path(managed_dir, context.temp_allocator),
		`{
	"language_servers": [{"name": "go"}],
	"language_server_commands": {
		"go": ["/opt/custom/gopls", "-logfile=auto"],
		// unknown ids are not the config layer's business
		"nosuchlang": ["whatever"]
	}
}`,
	)

	p, _, err := config.load_project(managed_dir, a)
	testing.expect(t, err == nil, "project load must succeed")
	testing.expect_value(t, len(p.language_server_commands), 2)
	go_argv, has_go := p.language_server_commands["go"]
	testing.expect(t, has_go, "go override must parse")
	if has_go && len(go_argv) == 2 {
		testing.expect_value(t, go_argv[0], "/opt/custom/gopls")
		testing.expect_value(t, go_argv[1], "-logfile=auto")
	} else if has_go {
		testing.expectf(t, false, "go argv must keep both elements")
	}
	_, has_unknown := p.language_server_commands["nosuchlang"]
	testing.expect(t, has_unknown, "unknown language ids parse unvalidated")

	// The local file replaces the key whole (object-key overlay semantics).
	write_config_file(
		t,
		platform.project_local_path(managed_dir, context.temp_allocator),
		`{"language_server_commands": {"zig": ["zls"]}}`,
	)
	p, _, err = config.load_project(managed_dir, a)
	testing.expect(t, err == nil, "local overlay must succeed")
	testing.expect_value(t, len(p.language_server_commands), 1)
	_, go_gone := p.language_server_commands["go"]
	testing.expect(t, !go_gone, "local replaces the whole key")
	zig_argv, has_zig := p.language_server_commands["zig"]
	testing.expect(t, has_zig, "local entry must apply")
	if has_zig && len(zig_argv) == 1 {
		testing.expect_value(t, zig_argv[0], "zls")
	}

	// Shape failures are typed errors.
	os.remove(platform.project_local_path(managed_dir, context.temp_allocator))
	bad_shapes := []string{
		`{"language_server_commands": ["/opt/gopls"]}`,
		`{"language_server_commands": {"go": "/opt/gopls"}}`,
		`{"language_server_commands": {"go": []}}`,
		`{"language_server_commands": {"go": ["", "-x"]}}`,
		`{"language_server_commands": {"go": [42]}}`,
	}
	for raw, i in bad_shapes {
		write_config_file(
			t,
			platform.project_config_path(managed_dir, context.temp_allocator),
			raw,
		)
		_, _, err = config.load_project(managed_dir, a)
		testing.expectf(t, err != nil, "shape %d must fail", i)
		if err != nil {
			testing.expect_value(
				t,
				platform.err_kind(err),
				platform.Err_Kind.Invalid,
			)
		}
	}
}

@(test)
project_language_server_options :: proc(t: ^testing.T) {
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	managed_dir := strings.concatenate({home, "/proj/.aubade"}, context.temp_allocator)
	write_config_file(
		t,
		platform.project_config_path(managed_dir, context.temp_allocator),
		`{
	"language_servers": [{"name": "odin"}],
	"language_server_options": {
		"odin": {"collections": [{"name": "src", "path": "src"}]},
		// unknown ids are not the config layer's business
		"nosuchlang": {"anything": true}
	}
}`,
	)

	p, _, err := config.load_project(managed_dir, a)
	testing.expect(t, err == nil, "project load must succeed")
	testing.expect_value(t, len(p.language_server_options), 2)
	odin, has_odin := p.language_server_options["odin"]
	testing.expect(t, has_odin, "odin options must parse")
	if has_odin {
		testing.expect(t, strings.contains(odin, "collections"), "odin text keeps the collections key")
		testing.expect(t, strings.contains(odin, `"src"`), "odin text keeps the collection name")
	}

	// The local file replaces the key whole (object-key overlay semantics).
	write_config_file(
		t,
		platform.project_local_path(managed_dir, context.temp_allocator),
		`{"language_server_options": {"zig": {"enable_inlay_hints_params": false}}}`,
	)
	p, _, err = config.load_project(managed_dir, a)
	testing.expect(t, err == nil, "local overlay must succeed")
	testing.expect_value(t, len(p.language_server_options), 1)
	_, odin_gone := p.language_server_options["odin"]
	testing.expect(t, !odin_gone, "local replaces the whole key")

	// A non-object value is a typed shape failure.
	os.remove(platform.project_local_path(managed_dir, context.temp_allocator))
	write_config_file(
		t,
		platform.project_config_path(managed_dir, context.temp_allocator),
		`{"language_server_options": {"odin": [1, 2]}}`,
	)
	_, _, err = config.load_project(managed_dir, a)
	testing.expect(t, err != nil, "array value must fail")
	if err != nil {
		testing.expect_value(t, platform.err_kind(err), platform.Err_Kind.Invalid)
	}
}

@(test) context_user_overrides_builtin :: proc(t: ^testing.T) {
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// The user's file wins over the builtin of the same name.
	ctx_dir := platform.contexts_dir(home, context.temp_allocator)
	write_config_file(
		t,
		strings.concatenate({ctx_dir, "/zcode.jsonc"}, context.temp_allocator),
		`{"description": "custom zcode", "single_project": true}`,
	)
	def, err := config.load_context(home, "zcode", a)
	testing.expect(t, err == nil, "user context must load")
	testing.expect_value(t, def.description, "custom zcode")

	// Builtins resolve without any file, with the new tool names.
	def, err = config.load_context(home, "claudecode", a)
	testing.expect(t, err == nil, "builtin claudecode must resolve")
	testing.expect(t, def.single_project)
	testing.expect(t, len(def.inclusion.excluded_tools) > 0)
	excludes_shell_run := false
	excludes_old_name := false
	for name in def.inclusion.excluded_tools {
		if name == "shell_run" {
			excludes_shell_run = true
		}
		if name == "execute_shell_command" {
			excludes_old_name = true
		}
	}
	testing.expect(t, excludes_shell_run, "builtin exclusions must use the new names")
	testing.expect(t, !excludes_old_name, "old names must not survive in builtins")

	// The search tools stay exposed in every agent context so content and
	// name lookups run through aubade's token-capped, ignore-aware search
	// instead of the client's own grep/glob.
	expect_not_excluded :: proc(t: ^testing.T, context_name: string, home: string, a: mem.Allocator) {
		def, lerr := config.load_context(home, context_name, a)
		if !testing.expectf(t, lerr == nil, "builtin %s must resolve", context_name) {
			return
		}
		for name in def.inclusion.excluded_tools {
			testing.expectf(t, name != "file_search", "%s must not exclude file_search", context_name)
			testing.expectf(t, name != "file_find", "%s must not exclude file_find", context_name)
		}
	}
	for ctx in config.BUILTIN_CONTEXTS {
		expect_not_excluded(t, ctx.name, home, a)
	}

	// chatgpt resolves like every other builtin (it no longer carries
	// description overrides — that config path never had a consumer).
	gpt, gerr := config.load_context(home, "chatgpt", a)
	testing.expect(t, gerr == nil, "builtin chatgpt must resolve")
	testing.expect(t, len(gpt.prompt) > 0, "chatgpt prompt must survive the clone")

	// Unknown context is a typed NotFound.
	_, err = config.load_context(home, "does-not-exist", a)
	testing.expect(t, err != nil)
	testing.expect_value(t, platform.err_kind(err), platform.Err_Kind.NotFound)

	// Path-ish names are rejected before touching the filesystem.
	_, err = config.load_context(home, "../../etc/passwd", a)
	testing.expect(t, err != nil, "unsafe names must be rejected")
}

@(test) builtin_modes_use_new_names :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	def, err := config.load_mode("", "no-memories", a)
	testing.expect(t, err == nil, "builtin no-memories must resolve")
	expect_in :: proc(list: []string, want: string, t: ^testing.T) {
		found := false
		for name in list {
			if name == want {
				found = true
			}
		}
		msg := strings.concatenate({"expected exclusion list to contain ", want}, context.temp_allocator)
		testing.expect(t, found, msg)
	}
	expect_in(def.inclusion.excluded_tools, "memory_write", t)
	expect_in(def.inclusion.excluded_tools, "memory_replace", t)
	expect_in(def.inclusion.excluded_tools, "onboarding_run", t)
	expect_in(def.inclusion.excluded_tools, "onboarding_check", t)

	// The query-projects builtin mode is gone: its tools belong to a
	// later phase and unknown names would warn at fold time.
	_, err2 := config.load_mode("", "query-projects", a)
	testing.expect(t, err2 != nil, "builtin query-projects must not resolve")
}

@(test) stack_mode_resolution_and_precedence :: proc(t: ^testing.T) {
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}

	write_config_file(
		t,
		platform.config_path(home, context.temp_allocator),
		`{
	"base_modes": ["no-onboarding"],
	"default_modes": ["interactive"],
	"line_ending": "lf",
}`,
	)
	project_root := strings.concatenate({home, "/repo"}, context.temp_allocator)
	os.make_directory_all(project_root, os.Permissions{.Read_User, .Write_User, .Execute_User})
	managed := strings.concatenate({project_root, "/.aubade"}, context.temp_allocator)
	write_config_file(
		t,
		platform.project_config_path(managed, context.temp_allocator),
		`{
	"project_name": "repo",
	"default_modes": ["editing"],
	"added_modes": ["planning"],
	"line_ending": "crlf",
}`,
	)

	mode_names_of :: proc(s: ^config.Config_Stack, tmp: mem.Allocator) -> string {
		out := ""
		for m in s.modes {
			out = strings.concatenate({out, m.name, ","}, tmp)
		}
		return out
	}

	// Config defaults: base + project default (replaces global) + added.
	s, err := config.stack_build({project_root = project_root}, home, context.allocator)
	testing.expect(t, err == nil, "stack must build")
	defer config.stack_destroy(s)
	testing.expect_value(t, mode_names_of(s, context.temp_allocator), "no-onboarding,editing,planning,")
	testing.expect_value(t, config.stack_effective_line_ending(s), config.Line_Ending.Crlf)
	testing.expect_value(t, s.ctx.name, config.DEFAULT_CONTEXT)

	// An explicit CLI list replaces the default selection (base + added stay).
	s2, err2 := config.stack_build(
		{project_root = project_root, mode_names = {"one-shot"}},
		home,
		context.allocator,
	)
	testing.expect(t, err2 == nil, "stack with CLI modes must build")
	defer config.stack_destroy(s2)
	testing.expect_value(t, mode_names_of(s2, context.temp_allocator), "no-onboarding,one-shot,planning,")
}

// A project's explicit empty default_modes is a selection (base_modes
// only), not an unset key: null or absence is the unset spelling, so []
// must not fall back to the global list.
@(test) project_empty_default_modes_is_explicit :: proc(t: ^testing.T) {
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}

	write_config_file(
		t,
		platform.config_path(home, context.temp_allocator),
		`{
	"base_modes": ["no-onboarding"],
	"default_modes": ["interactive"],
}`,
	)
	project_root := strings.concatenate({home, "/repo-empty-modes"}, context.temp_allocator)
	os.make_directory_all(project_root, os.Permissions{.Read_User, .Write_User, .Execute_User})
	managed := strings.concatenate({project_root, "/.aubade"}, context.temp_allocator)
	write_config_file(
		t,
		platform.project_config_path(managed, context.temp_allocator),
		`{
	"project_name": "repo",
	"default_modes": [],
}`,
	)

	s, err := config.stack_build({project_root = project_root}, home, context.allocator)
	testing.expect(t, err == nil, "stack must build")
	defer config.stack_destroy(s)
	testing.expect(t, s.project.shared.default_modes_set, "an explicit [] must set default_modes_set")
	testing.expect_value(t, len(s.modes), 1)
	if len(s.modes) == 1 {
		testing.expect_value(t, s.modes[0].name, "no-onboarding")
	}
}

@(test) stack_line_ending_falls_back_to_global :: proc(t: ^testing.T) {
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}

	write_config_file(
		t,
		platform.config_path(home, context.temp_allocator),
		`{"line_ending": "lf"}`,
	)
	project_root := strings.concatenate({home, "/repo2"}, context.temp_allocator)
	os.make_directory_all(project_root, os.Permissions{.Read_User, .Write_User, .Execute_User})

	s, err := config.stack_build({project_root = project_root}, home, context.allocator)
	testing.expect(t, err == nil, "stack must build")
	defer config.stack_destroy(s)
	testing.expect_value(t, config.stack_effective_line_ending(s), config.Line_Ending.Lf)
	testing.expect(t, config.stack_effective_symbol_info_budget_s(s) > 0, "budget default must apply")
}

@(test) templates_generate_valid_jsonc :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	global := config.template_global(a)
	testing.expect(t, strings.contains(global, "//"), "global template must carry comments")
	value, err := config.jsonc_parse(transmute([]u8)global, a)
	testing.expect(t, err == nil, "global template must parse as JSONC")
	testing.expect(t, value != nil)

	project := config.generate_project_config("au\"bade", {"go", "odin"}, a)
	testing.expect(t, strings.contains(project, "\"project_name\": \"au\\\"bade\""), "name must be substituted and escaped")
	testing.expect(t, strings.contains(project, "\"language_servers\": [{\"name\": \"go\"}, {\"name\": \"odin\"}]"), "languages must be substituted")
	value, err = config.jsonc_parse(transmute([]u8)project, a)
	testing.expect(t, err == nil, "generated project config must parse as JSONC")

	value, err = config.jsonc_parse(transmute([]u8)config.template_context(a), a)
	testing.expect(t, err == nil, "context template must parse as JSONC")
	value, err = config.jsonc_parse(transmute([]u8)config.template_mode(a), a)
	testing.expect(t, err == nil, "mode template must parse as JSONC")
	_ = value
}

@(test) registry_round_trip :: proc(t: ^testing.T) {
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	entry_x := strings.concatenate({home, "/x"}, context.temp_allocator)
	entry_x_slash := strings.concatenate({home, "/x/"}, context.temp_allocator)
	entry_y := strings.concatenate({home, "/y"}, context.temp_allocator)
	err := config.registry_save(home, {entry_x, entry_x_slash, entry_y})
	testing.expect(t, err == nil, "registry save must succeed")

	r, lerr := config.registry_load(home, a)
	testing.expect(t, lerr == nil, "registry load must succeed")
	defer config.registry_destroy(r, a)
	testing.expect_value(t, len(r.projects), 2)
	if len(r.projects) == 2 {
		clean_x, ok_x := platform.normalize_project_root(entry_x, context.temp_allocator)
		testing.expect(t, ok_x, "normalization must succeed")
		testing.expect_value(t, r.projects[0], clean_x)
	}

	// No temp file residue from the atomic write.
	residue := strings.concatenate({platform.projects_registry_path(home, context.temp_allocator), ".tmp"}, context.temp_allocator)
	testing.expect(t, !os.exists(residue), "no tmp residue may remain")

	// A corrupt registry is a typed error (machine-owned file: surface it).
	write_config_file(t, platform.projects_registry_path(home, context.temp_allocator), "{not json")
	_, err = config.registry_load(home, a)
	testing.expect(t, err != nil, "corrupt registry must fail")
	// The parse failure is kept as the cause: err_message surfaces the
	// detail instead of a bare "malformed".
	msg := platform.err_message(err, context.temp_allocator)
	testing.expect(t, strings.has_prefix(msg, "projects.json is malformed: json parse error: "), msg)
	testing.expect(t, platform.err_cause(err) != nil, "cause chain must be present")
}

@(test) mode_and_context_fixed_tools_exclusivity :: proc(t: ^testing.T) {
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	bad := `{"fixed_tools": ["symbol_find"], "excluded_tools": ["shell_run"]}`
	write_config_file(
		t,
		strings.concatenate({platform.modes_dir(home, context.temp_allocator), "/broken.jsonc"}, context.temp_allocator),
		bad,
	)
	_, err := config.load_mode(home, "broken", a)
	testing.expect(t, err != nil, "mode fixed + excluded must fail")
	testing.expect_value(t, platform.err_kind(err), platform.Err_Kind.Invalid)

	write_config_file(
		t,
		strings.concatenate({platform.contexts_dir(home, context.temp_allocator), "/broken.jsonc"}, context.temp_allocator),
		bad,
	)
	_, err = config.load_context(home, "broken", a)
	testing.expect(t, err != nil, "context fixed + excluded must fail")
	testing.expect_value(t, platform.err_kind(err), platform.Err_Kind.Invalid)
}

@(test) project_local_without_project_file :: proc(t: ^testing.T) {
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	managed_dir := strings.concatenate({home, "/proj/.aubade"}, context.temp_allocator)
	write_config_file(
		t,
		platform.project_local_path(managed_dir, context.temp_allocator),
		`{
	// no project.jsonc at all — local keys must still apply over defaults
	"read_only": true,
	"stale_local_key": 1,
}`,
	)

	p, warnings, err := config.load_project(managed_dir, a)
	testing.expect(t, err == nil, "project load must succeed")
	testing.expect(t, p.read_only, "local keys must apply without project.jsonc")
	testing.expect(t, warnings_contain(warnings, "not found"), "missing project.jsonc must warn")
	testing.expect(t, warnings_contain(warnings, "stale_local_key"), "local unknown key must warn")
}

@(test) stack_dedupes_repeated_mode_names :: proc(t: ^testing.T) {
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}

	write_config_file(
		t,
		platform.config_path(home, context.temp_allocator),
		`{
	"base_modes": ["no-memories"],
	"default_modes": ["no-memories"],
}`,
	)
	project_root := strings.concatenate({home, "/repo3"}, context.temp_allocator)
	os.make_directory_all(project_root, os.Permissions{.Read_User, .Write_User, .Execute_User})
	managed := strings.concatenate({project_root, "/.aubade"}, context.temp_allocator)
	write_config_file(
		t,
		platform.project_config_path(managed, context.temp_allocator),
		`{"project_name": "repo3", "added_modes": ["no-memories"]}`,
	)

	s, err := config.stack_build({project_root = project_root}, home, context.allocator)
	testing.expect(t, err == nil, "stack must build")
	defer config.stack_destroy(s)
	testing.expect_value(t, len(s.modes), 1)
	testing.expect_value(t, s.modes[0].name, "no-memories")
}

@(test)
jsonc_parse_accepts_utf8_bom :: proc(t: ^testing.T) {
	// The core json tokenizer skips a leading BOM; pin that so a toolchain
	// change cannot silently reject BOM-prefixed config files.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	src := "\uFEFF{\"k\": \"v\"}"
	value, err := config.jsonc_parse(transmute([]u8)src, a)
	testing.expect(t, err == nil, "BOM-prefixed jsonc must parse")
	v, ok := jsonutil.obj_get(value, "k")
	testing.expect(t, ok, "k present")
	#partial switch x in v {
	case json.String:
		testing.expect_value(t, string(x), "v")
	case:
		testing.expect(t, false, "k is not a string")
	}
}

@(test)
builtin_context_prose_cites_no_removed_tools :: proc(t: ^testing.T) {
	// Ported prose must not dangle: the rename/deprecation sweeps walk
	// identifiers, and prompt text is easy to miss — a project_activate
	// reference survived two builtin contexts exactly this way.
	// Materialize the constant table before indexing (the compiler
	// rejects variable indexing straight into constant data).
	contexts := config.BUILTIN_CONTEXTS
	for i in 0..<len(contexts) {
		testing.expectf(
			t, !strings.contains(contexts[i].prompt, "project_activate"),
			"context %s prompt cites the removed project_activate tool", contexts[i].name,
		)
		testing.expectf(
			t, !strings.contains(contexts[i].description, "project_activate"),
			"context %s description cites the removed project_activate tool", contexts[i].name,
		)
	}
	modes := config.BUILTIN_MODES
	for i in 0..<len(modes) {
		testing.expectf(
			t, !strings.contains(modes[i].prompt, "project_activate"),
			"mode %s prompt cites the removed project_activate tool", modes[i].name,
		)
	}
}

@(test)
generated_templates_load_end_to_end :: proc(t: ^testing.T) {
	// The null-unset convention: the generated templates ship keys set to
	// JSON null (line_ending, default_modes, symbol_info_budget); loading
	// them through the decoders must treat null as absent, not "expects a
	// number". A parse-only check never caught this.
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	gpath := platform.config_path(home, a)
	_ = os.write_entire_file_from_string(gpath, config.template_global(a))
	gcfg, gwarn, gerr := config.load_global(home, a)
	testing.expectf(t, gerr == nil, "global template must load: %s", platform.err_message(gerr, a) if gerr != nil else "-")
	// The template documents every global key; a warning would mean the
	// template and the loader's key lists drifted apart.
	testing.expect(t, len(gwarn) == 0, "global template must load warning-free")
	if gerr == nil {
		testing.expect(t, gcfg.shared.symbol_info_budget_s > 0, "global default must survive")
		// The generated template interpolates the DEFAULT_* constants —
		// loading it must land exactly on them (guards the rendering
		// against placeholder drift).
		testing.expect_value(t, gcfg.tool_timeout_s, config.DEFAULT_TOOL_TIMEOUT_S)
		testing.expect_value(t, gcfg.default_max_tool_answer_chars, config.DEFAULT_MAX_TOOL_ANSWER_CHARS)
		testing.expect_value(t, gcfg.log_level, config.DEFAULT_LOG_LEVEL)
		testing.expect_value(t, gcfg.shared.symbol_info_budget_s, config.DEFAULT_SYMBOL_INFO_BUDGET_S)
		testing.expect_value(t, gcfg.project_aubade_folder_location, config.DEFAULT_MANAGED_DIR_TEMPLATE)
		testing.expect_value(t, gcfg.web.search_provider, config.DEFAULT_SEARCH_PROVIDER)
	}

	managed, _ := filepath.join({home, "proj", ".aubade"}, a)
	os.make_directory_all(managed)
	ppath := platform.project_config_path(managed, a)
	_ = os.write_entire_file_from_string(ppath, config.generate_project_config("demo", {"go"}, a))
	pcfg, pwarn, perr := config.load_project(managed, a)
	testing.expectf(t, perr == nil, "generated project config must load: %s", platform.err_message(perr, a) if perr != nil else "-")
	// The template documents every project key; a warning would mean the
	// template and the loader's key lists drifted apart.
	testing.expect(t, len(pwarn) == 0, "generated project config must load warning-free")
	if perr == nil {
		testing.expect_value(t, pcfg.project_name, "demo")
	}
}

@(test)
config_validate_project_data :: proc(t: ^testing.T) {
	a := context.temp_allocator

	// A loadable candidate passes — comments and every known shape intact.
	good_src :=
		"{\n" +
		"  // languages\n" +
		"  \"language_servers\": [{\"name\": \"odin\"}],\n" +
		"  \"language_server_commands\": {\"odin\": [\"ols\"]},\n" +
		"  \"language_server_options\": {\"odin\": {\"collections\": []}},\n" +
		"  \"read_only\": false,\n" +
		"  \"line_ending\": \"lf\",\n" +
		"}\n"
	good := transmute([]u8)good_src
	testing.expect(t, config.validate_project_data(good, a) == nil, "a loadable candidate must pass")

	// Broken JSON is refused with the parser's error.
	broken_src := "{\"language_servers\": ["
	broken := transmute([]u8)broken_src
	testing.expect(t, config.validate_project_data(broken, a) != nil, "broken JSON must be refused")

	// A non-object top level is refused.
	not_obj_src := "[1, 2]"
	not_obj := transmute([]u8)not_obj_src
	testing.expect(t, config.validate_project_data(not_obj, a) != nil, "a non-object must be refused")

	// Wrong value shapes are refused with the loader's typed error — the
	// exact failures the write path must catch before touching the file.
	bad_langs_src := "{\"language_servers\": \"odin\"}"
	bad_langs := transmute([]u8)bad_langs_src
	testing.expect(t, config.validate_project_data(bad_langs, a) != nil, "a scalar language_servers must be refused")
	bad_entry_src := "{\"language_servers\": [\"odin\"]}"
	bad_entry := transmute([]u8)bad_entry_src
	testing.expect(t, config.validate_project_data(bad_entry, a) != nil, "a bare-string element must be refused")
	bad_opts_src := "{\"language_server_options\": {\"odin\": []}}"
	bad_opts := transmute([]u8)bad_opts_src
	testing.expect(t, config.validate_project_data(bad_opts, a) != nil, "a non-object options value must be refused")
	bad_argv_src := "{\"language_server_commands\": {\"odin\": \"ols\"}}"
	bad_argv := transmute([]u8)bad_argv_src
	testing.expect(t, config.validate_project_data(bad_argv, a) != nil, "a scalar argv must be refused")
}

@(test)
config_project_key_known :: proc(t: ^testing.T) {
	// Project keys and shared keys are both legal at project.jsonc's top
	// level (the acceptance set check_unknown applies); anything else is
	// unknown — refused by the write surfaces.
	testing.expect(t, config.project_key_known("language_servers"))
	testing.expect(t, config.project_key_known("language_server_options"))
	testing.expect(t, config.project_key_known("read_only"))
	testing.expect(t, config.project_key_known("line_ending"))
	testing.expect(t, config.project_key_known("excluded_tools"))
	testing.expect(t, !config.project_key_known("nonsense_key"))
	testing.expect(t, !config.project_key_known("ols_json"))
}

@(test) project_language_server_entries :: proc(t: ^testing.T) {
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	managed_dir := strings.concatenate({home, "/proj/.aubade"}, context.temp_allocator)
	write_config_file(
		t,
		platform.project_config_path(managed_dir, context.temp_allocator),
		`{
	"language_servers": [
		{"name": "go"},
		{"name": "odin", "path": "/abs/ols"},
		{"name": "zig", "path": "~/bin/zls"},
		{"name": "python"},
		{"name": "python", "path": ""}
	]
}`,
	)

	p, _, err := config.load_project(managed_dir, a)
	testing.expect(t, err == nil, "entry objects must parse")
	if err != nil {
		return
	}
	testing.expect_value(t, len(p.language_servers), 5)
	if len(p.language_servers) == 5 {
		testing.expect_value(t, p.language_servers[0].name, "go")
		testing.expect_value(t, p.language_servers[0].path, "")
		testing.expect_value(t, p.language_servers[1].name, "odin")
		testing.expect_value(t, p.language_servers[1].path, "/abs/ols")
		testing.expect_value(t, p.language_servers[2].path, "~/bin/zls")
		testing.expect_value(t, p.language_servers[3].name, "python")
		testing.expect_value(t, p.language_servers[3].path, "")
		testing.expect_value(t, p.language_servers[4].path, "")
	}

	// Shape failures are typed load errors, and the write path refuses the
	// same bytes through validate_project_data.
	bad_shapes := []string{
		`{"language_servers": ["go"]}`,
		`{"language_servers": [{"path": "/abs/ols"}]}`,
		`{"language_servers": [{"name": "", "path": "/abs/ols"}]}`,
		`{"language_servers": [{"name": "go", "path": "/abs/ols", "args": []}]}`,
		`{"language_servers": [{"name": "go", "path": 42}]}`,
		`{"language_servers": [{"name": 42}]}`,
		`{"language_servers": [42]}`,
	}
	for raw, i in bad_shapes {
		write_config_file(t, platform.project_config_path(managed_dir, context.temp_allocator), raw)
		_, _, lerr := config.load_project(managed_dir, a)
		testing.expectf(t, lerr != nil, "shape %d must refuse the load", i)
		testing.expectf(
			t,
			config.validate_project_data(transmute([]u8)raw, context.temp_allocator) != nil,
			"shape %d must refuse on the write path too",
			i,
		)
	}
}

@(test)
stack_build_error_message_outlives_destroy :: proc(t: ^testing.T) {
	// The loaders build error messages on the stack's own arena; the error
	// must still render after stack_build destroyed that arena on its way
	// out — the pre-fix return read freed arena memory.
	dir, derr := os.make_directory_temp("", "aubade-stackerr-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp home failed")
		return
	}
	defer {
		_ = os.remove_all(dir)
		// make_directory_temp returns an owned clone
		delete(dir, context.allocator)
	}

	cfg_path, _ := filepath.join([]string{dir, "config.jsonc"}, context.temp_allocator)
	if werr := os.write_entire_file_from_string(cfg_path, "{ not jsonc at all"); werr != nil {
		testing.expectf(t, false, "seed corrupt config failed")
		return
	}

	_, err := config.stack_build({project_root = ""}, dir, context.allocator)
	testing.expectf(t, err != nil, "corrupt config.jsonc must fail the stack build")
	if err == nil {
		return
	}
	msg := platform.err_message(err, context.temp_allocator)
	testing.expect(t, strings.contains(msg, "config.jsonc"), msg)
}

@(test)
oversized_config_is_refused_not_reported_missing :: proc(t: ^testing.T) {
	// An oversized config must surface as a typed refusal naming the
	// file, not fold into "missing" — the pre-fix path loaded defaults
	// behind a false not-found warning.
	dir, derr := os.make_directory_temp("", "aubade-bigcfg-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp home failed")
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir, context.allocator)
	}

	cfg_path, _ := filepath.join([]string{dir, "config.jsonc"}, context.temp_allocator)
	big := make([]u8, int(config.MAX_CONFIG_BYTES) + 1, context.allocator)
	defer delete(big, context.allocator)
	for i := 0; i < len(big); i += 1 {
		big[i] = '{'
	}
	if werr := os.write_entire_file_from_string(cfg_path, string(big)); werr != nil {
		testing.expectf(t, false, "seed oversized config failed")
		return
	}
	// The loaders are arena-oriented (their error paths return without
	// destroying the partially built config), so the test rides one too.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	_, _, err := config.load_global(dir, mem.dynamic_arena_allocator(&arena))
	testing.expectf(t, err != nil, "oversized config.jsonc must be refused, not treated as missing")
	if err == nil {
		return
	}
	testing.expect_value(t, platform.err_kind(err), platform.Err_Kind.Invalid)
	msg := platform.err_message(err, context.temp_allocator)
	testing.expect(t, strings.contains(msg, "config.jsonc"), msg)
	testing.expect(t, strings.contains(msg, "size cap"), msg)
}

@(test)
config_key_lists_match_parsed_keys :: proc(t: ^testing.T) {
	// Every key the loader lists as known must be read by some dec_*
	// call: a listed-but-never-read key would silently no-op (no unknown
	// warning, no parsed field). Each key is probed with an integer and a
	// string value — no dec accepts both shapes, so at least one probe
	// must fail for a genuinely parsed key.
	a := context.temp_allocator
	shared_and_project := [][]string{config.SHARED_KEYS, config.PROJECT_KEYS}
	for list in shared_and_project {
		for key in list {
			int_probe := strings.concatenate({"{\"", key, "\": 1}"}, a)
			str_probe := strings.concatenate({"{\"", key, "\": \"x\"}"}, a)
			int_fails := config.validate_project_data(transmute([]u8)int_probe, a) != nil
			str_fails := config.validate_project_data(transmute([]u8)str_probe, a) != nil
			testing.expectf(t, int_fails || str_fails, "listed key %q accepted both probes — nothing parses it", key)
		}
	}

	// Global-only keys go through the file loader (there is no in-memory
	// global validator).
	home := temp_home(t)
	defer {
		os.remove_all(home)
		delete(home, context.allocator)
	}
	gpath := platform.config_path(home, context.temp_allocator)
	defer os.remove(gpath)
	probes := []string{"1", "\"x\""}
	for key in config.GLOBAL_KEYS {
		failed := false
		for value in probes {
			body := strings.concatenate({"{\"", key, "\": ", value, "}"}, context.temp_allocator)
			os.remove(gpath)
			_ = os.write_entire_file_from_string(gpath, body)
			if _, _, gerr := config.load_global(home, context.temp_allocator); gerr != nil {
				failed = true
			}
		}
		testing.expectf(t, failed, "global key %q accepted both probes — nothing parses it", key)
	}
}

@(test)
default_context_names_a_builtin :: proc(t: ^testing.T) {
	// DEFAULT_CONTEXT must resolve against the built-in table — the two
	// spellings live in different declarations, and this is the bind.
	found := false
	for def in config.BUILTIN_CONTEXTS {
		if def.name == config.DEFAULT_CONTEXT {
			found = true
		}
	}
	testing.expect(t, found, "DEFAULT_CONTEXT must name a built-in context")
}

@(test)
search_provider_vocabulary_pinned :: proc(t: ^testing.T) {
	// config's validator list and web's Provider_Kind enum are two
	// declarations of one vocabulary (config cannot import web to derive
	// its side, so a cross-pin test holds them together): every web name
	// must clear the validator, every validator entry must be a web name
	// or one of the two sentinels ("auto" = pick by key availability, ""
	// = unset), and the default must be an accepted value.
	for k in web.Provider_Kind {
		name := web.provider_name(k)
		found := false
		for v in config.VALID_SEARCH_PROVIDERS {
			if v == name {
				found = true
				break
			}
		}
		testing.expectf(t, found, "web provider %q is not in config.VALID_SEARCH_PROVIDERS", name)
	}
	for v in config.VALID_SEARCH_PROVIDERS {
		if v == "auto" || v == "" {
			continue
		}
		found := false
		for k in web.Provider_Kind {
			if web.provider_name(k) == v {
				found = true
				break
			}
		}
		testing.expectf(t, found, "config validator entry %q names no web provider", v)
	}
	default_ok := false
	for v in config.VALID_SEARCH_PROVIDERS {
		if v == config.DEFAULT_SEARCH_PROVIDER {
			default_ok = true
		}
	}
	testing.expect(t, default_ok, "DEFAULT_SEARCH_PROVIDER must be an accepted provider value")

	// The rendered template spells the same vocabulary — the placeholder
	// is derived from the validator table, so the generated comment must
	// name every non-sentinel entry.
	rendered := config.template_global(context.temp_allocator)
	for v in config.VALID_SEARCH_PROVIDERS {
		if v == "" {
			continue
		}
		quoted := strings.concatenate({"\"", v, "\""}, context.temp_allocator)
		testing.expectf(t, strings.contains(rendered, quoted), "template names provider %q", v)
	}
}
