// Tests for the cli table (exit codes, global flag placement) and the
// init/setup file logic against isolated temp homes.
package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "src:cli"
import "src:config"
import "src:memory"
import "src:platform"
import "src:store"
import "src:svc"
import "src:tracker"

@(test)
cli_table_exit_codes :: proc(t: ^testing.T) {
	testing.expect_value(t, cli.run({"--version"}, "test"), 0)
	testing.expect_value(t, cli.run({"version"}, "test"), 0)
	testing.expect_value(t, cli.run({"--help"}, "test"), 0)
	testing.expect_value(t, cli.run({"help"}, "test"), 0)
	testing.expect_value(t, cli.run({"bogus-subcommand"}, "test"), 2)
	testing.expect_value(t, cli.run({"--nonsense", "init"}, "test"), 2)
	testing.expect_value(t, cli.run({"--log-level", "bogus", "init"}, "test"), 2)
	// Globals are accepted after the subcommand; a bad value is a usage
	// error before anything runs.
	testing.expect_value(t, cli.run({"daemon", "status", "--log-level", "bogus"}, "test"), 2)
	// daemon status without a project selection is a usage error, not a
	// daemon interaction.
	testing.expect_value(t, cli.run({"daemon", "status"}, "test"), 2)
	testing.expect_value(t, cli.run({"daemon", "explode"}, "test"), 2)
	testing.expect_value(t, cli.run({"setup", "nosuch-client"}, "test"), 2)
	testing.expect_value(t, cli.run({"setup"}, "test"), 2)
	// The old hyphenated claude spelling is not an alias.
	testing.expect_value(t, cli.run({"setup", "claude-code"}, "test"), 2)
	testing.expect_value(t, cli.run({"uninstall", "nosuch-client"}, "test"), 2)
	testing.expect_value(t, cli.run({"uninstall"}, "test"), 2)
	testing.expect_value(t, cli.run({"uninstall", "zcode", "extra"}, "test"), 2)
	testing.expect_value(t, cli.run({"init", "extra-arg"}, "test"), 2)
	// The hook verb answers --help itself, before draining stdin (setup's
	// follow-up hint names this command).
	testing.expect_value(t, cli.run({"hook", "--help"}, "test"), 0)
	testing.expect_value(t, cli.run({"hook", "-h"}, "test"), 0)
}

@(test)
cli_init_writes_template_once :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-cli-init-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	old, had := os.lookup_env_alloc("AUBADE_HOME", context.temp_allocator)
	os.set_env("AUBADE_HOME", tmp)
	defer if had {
		os.set_env("AUBADE_HOME", old)
	} else {
		os.unset_env("AUBADE_HOME")
	}

	code := cli.run({"init"}, "test-version")
	testing.expect_value(t, code, 0)

	path := platform.config_path(tmp, context.temp_allocator)
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		testing.expectf(t, false, "config.jsonc was not created")
		return
	}
	testing.expect_value(t, string(data), config.template_global(context.temp_allocator))

	// Write-once: the second init refuses to touch the file.
	data_clone := strings.clone(string(data), context.temp_allocator)
	code2 := cli.run({"init"}, "test-version")
	testing.expect_value(t, code2, 1)
	again, _ := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect_value(t, string(again), data_clone)
	delete(data_clone, context.temp_allocator)
}

@(test)
cli_setup_zcode_into_temp_home :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-cli-zcode-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	testing.expect_value(t, cli.setup_zcode_into(tmp), 0)

	config_path, _ := filepath.join([]string{tmp, ".zcode", "cli", "config.json"}, context.temp_allocator)
	data, rerr := os.read_entire_file_from_path(config_path, context.temp_allocator)
	if rerr != nil {
		testing.expectf(t, false, "config.json was not created")
		return
	}
	value, perr := config.jsonc_parse(data, context.temp_allocator)
	if perr != nil || value == nil {
		testing.expectf(t, false, "fresh config.json is not valid JSON")
		return
	}

	// The AGENTS.md block carries the Odin tool names.
	agents_path, _ := filepath.join([]string{tmp, ".zcode", "AGENTS.md"}, context.temp_allocator)
	agents, aerr := os.read_entire_file_from_path(agents_path, context.temp_allocator)
	if aerr != nil {
		testing.expectf(t, false, "AGENTS.md was not created")
		return
	}
	testing.expect(t, strings.contains(string(agents), "<!-- aubade:zcode:begin -->"))
	testing.expect(t, strings.contains(string(agents), "`onboarding_read_instructions`"))
	testing.expect(t, strings.contains(string(agents), "`onboarding_run`"))

	// Idempotent: a second run changes neither file.
	first_config := strings.clone(string(data), context.temp_allocator)
	first_agents := strings.clone(string(agents), context.temp_allocator)
	testing.expect_value(t, cli.setup_zcode_into(tmp), 0)
	data2, _ := os.read_entire_file_from_path(config_path, context.temp_allocator)
	agents2, _ := os.read_entire_file_from_path(agents_path, context.temp_allocator)
	testing.expect_value(t, string(data2), first_config)
	testing.expect_value(t, string(agents2), first_agents)
}

// `claude mcp add` and `codex mcp add` store everything after "--"
// verbatim as the server command: the resolved aubade binary must lead it,
// with "mcp" as its subcommand — a bare "mcp" in that slot registers a
// nonexistent command. The context flag rides as separate "--context" and
// value elements, the spelling the MCP ecosystem's configs standardize on.
@(test)
cli_setup_claude_add_args_carry_binary :: proc(t: ^testing.T) {
	args := cli.claude_mcp_add_args("/opt/aubade-test/aubade", context.temp_allocator)
	testing.expect_value(t, len(args), 12)
	if len(args) == 12 {
		testing.expect_value(t, args[6], "--")
		testing.expect_value(t, args[7], "/opt/aubade-test/aubade")
		testing.expect_value(t, args[8], "mcp")
		testing.expect_value(t, args[9], "--context")
		testing.expect_value(t, args[10], "claudecode")
		testing.expect_value(t, args[11], "--project-from-cwd")
	}
}

@(test)
cli_setup_codex_add_args_carry_binary :: proc(t: ^testing.T) {
	args := cli.codex_mcp_add_args("/opt/aubade-test/aubade", context.temp_allocator)
	testing.expect_value(t, len(args), 10)
	if len(args) == 10 {
		testing.expect_value(t, args[4], "--")
		testing.expect_value(t, args[5], "/opt/aubade-test/aubade")
		testing.expect_value(t, args[6], "mcp")
		testing.expect_value(t, args[7], "--context")
		testing.expect_value(t, args[8], "codex")
		testing.expect_value(t, args[9], "--project-from-cwd")
	}
}

@(test)
cli_setup_qwen_add_args_carry_binary :: proc(t: ^testing.T) {
	args := cli.qwen_mcp_add_args("/opt/aubade-test/aubade", context.temp_allocator)
	testing.expect_value(t, len(args), 10)
	if len(args) == 10 {
		testing.expect_value(t, args[0], "qwen")
		testing.expect_value(t, args[4], "--")
		testing.expect_value(t, args[5], "/opt/aubade-test/aubade")
		testing.expect_value(t, args[6], "mcp")
		testing.expect_value(t, args[7], "--context")
		testing.expect_value(t, args[8], "qwen")
		testing.expect_value(t, args[9], "--project-from-cwd")
	}
}

@(test)
cli_setup_zcode_preserves_existing_config :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-cli-zcode2-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	config_dir, _ := filepath.join([]string{tmp, ".zcode", "cli"}, context.temp_allocator)
	_ = os.make_directory_all(config_dir)
	config_path, _ := filepath.join([]string{config_dir, "config.json"}, context.temp_allocator)
	existing :=
		"{\n" +
		"  // zcode settings\n" +
		"  \"theme\": \"dark\",\n" +
		"  \"mcp\": {\n" +
		"    \"servers\": {\n" +
		"      \"other\": {\"type\": \"stdio\", \"command\": \"/bin/other\"}\n" +
		"    }\n" +
		"  }\n" +
		"}\n"
	_ = os.write_entire_file_from_string(config_path, existing, os.Permissions{.Read_User, .Write_User})

	testing.expect_value(t, cli.setup_zcode_into(tmp), 0)

	data, rerr := os.read_entire_file_from_path(config_path, context.temp_allocator)
	if rerr != nil {
		testing.expectf(t, false, "config.json vanished")
		return
	}
	out := string(data)
	// The existing comment and members survive byte-for-byte.
	testing.expect(t, strings.contains(out, "// zcode settings"))
	testing.expect(t, strings.contains(out, "\"theme\": \"dark\""))
	testing.expect(t, strings.contains(out, "\"other\": {\"type\": \"stdio\", \"command\": \"/bin/other\"}"))
	// The aubade entry landed inside mcp.servers, at the file's own indent
	// (2-space file: entry members at four units).
	testing.expect(t, strings.contains(out, "\"aubade\": {\n        \"type\": \"stdio\""))

	// The edited file still parses.
	value, perr := config.jsonc_parse(data, context.temp_allocator)
	if perr != nil || value == nil {
		testing.expectf(t, false, "edited config.json is not valid JSONC")
		return
	}
}

@(test)
cli_setup_opencode_into_temp_home :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-cli-opencode-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	testing.expect_value(t, cli.setup_opencode_into(tmp), 0)

	path, _ := filepath.join([]string{tmp, ".config", "opencode", "opencode.json"}, context.temp_allocator)
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		testing.fail_now(t, "opencode.json was not created")
	}
	value, perr := config.jsonc_parse(data, context.temp_allocator)
	if perr != nil || value == nil {
		testing.fail_now(t, "fresh opencode.json is not valid JSON")
	}
	testing.expect(t, strings.contains(string(data), "\"$schema\": \"https://opencode.ai/config.json\""))
	testing.expect(t, strings.contains(string(data), "\"mcp\""))
	testing.expect(t, strings.contains(string(data), "\"--project-from-cwd\""))

	// Idempotent.
	first := strings.clone(string(data), context.temp_allocator)
	testing.expect_value(t, cli.setup_opencode_into(tmp), 0)
	again, _ := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect_value(t, string(again), first)
	delete(first, context.temp_allocator)
}

@(test)
cli_setup_opencode_replaces_stale_entry :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-cli-opencode-stale-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	cfg_dir, _ := filepath.join([]string{tmp, ".config", "opencode"}, context.temp_allocator)
	_ = os.make_directory_all(cfg_dir)
	path, _ := filepath.join([]string{cfg_dir, "opencode.json"}, context.temp_allocator)
	stale :=
		"{\n" +
		"  \"$schema\": \"https://opencode.ai/config.json\",\n" +
		"  \"theme\": \"dark\",\n" +
		"  \"mcp\": {\n" +
		"    \"aubade\": {\n" +
		"      \"type\": \"local\",\n" +
		"      \"command\": [\"/nowhere/aubade\", \"mcp\"]\n" +
		"    }\n" +
		"  }\n" +
		"}\n"
	_ = os.write_entire_file_from_string(path, stale, os.Permissions{.Read_User, .Write_User})

	testing.expect_value(t, cli.setup_opencode_into(tmp), 0)

	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		testing.fail_now(t, "opencode.json is missing after setup")
	}
	testing.expect(t, strings.contains(string(data), "\"--project-from-cwd\""), "stale entry must be repaired")
	testing.expect(t, strings.contains(string(data), "\"theme\": \"dark\""), "sibling members survive the repair")
	value, perr := config.jsonc_parse(data, context.temp_allocator)
	testing.expect(t, perr == nil && value != nil, "repaired config must stay valid JSON")
}

@(test)
cli_uninstall_zcode_roundtrip :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-cli-un-zcode-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	testing.expect_value(t, cli.setup_zcode_into(tmp), 0)
	testing.expect_value(t, cli.uninstall_zcode_into(tmp), 0)

	// The config entry is gone and the file still parses.
	config_path, _ := filepath.join([]string{tmp, ".zcode", "cli", "config.json"}, context.temp_allocator)
	data, rerr := os.read_entire_file_from_path(config_path, context.temp_allocator)
	if rerr != nil {
		testing.fail_now(t, "config.json vanished after uninstall")
	}
	testing.expect(t, !strings.contains(string(data), "aubade"), "aubade entry must be gone")
	value, perr := config.jsonc_parse(data, context.temp_allocator)
	testing.expect(t, perr == nil && value != nil, "uninstalled config.json must stay valid JSON")

	// AGENTS.md held nothing but the managed block: the file itself goes.
	agents_path, _ := filepath.join([]string{tmp, ".zcode", "AGENTS.md"}, context.temp_allocator)
	testing.expect_value(t, os.exists(agents_path), false)

	// Idempotent: a second uninstall reports "not configured" cleanly.
	testing.expect_value(t, cli.uninstall_zcode_into(tmp), 0)
}

@(test)
cli_uninstall_zcode_preserves_existing :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-cli-un-zcode2-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	config_dir, _ := filepath.join([]string{tmp, ".zcode", "cli"}, context.temp_allocator)
	_ = os.make_directory_all(config_dir)
	config_path, _ := filepath.join([]string{config_dir, "config.json"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(
		config_path,
		"{\n  // zcode settings\n  \"theme\": \"dark\",\n  \"mcp\": {\n    \"servers\": {\n      \"other\": {\"type\": \"stdio\", \"command\": \"/bin/other\"}\n    }\n  }\n}\n",
		os.Permissions{.Read_User, .Write_User},
	)
	zcode_dir, _ := filepath.join([]string{tmp, ".zcode"}, context.temp_allocator)
	agents_path, _ := filepath.join([]string{zcode_dir, "AGENTS.md"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(
		agents_path,
		"# My notes\n\nUser content that must survive.\n",
		os.Permissions{.Read_User, .Write_User},
	)

	testing.expect_value(t, cli.setup_zcode_into(tmp), 0)
	testing.expect_value(t, cli.uninstall_zcode_into(tmp), 0)

	data, rerr := os.read_entire_file_from_path(config_path, context.temp_allocator)
	if rerr != nil {
		testing.fail_now(t, "config.json vanished after uninstall")
	}
	out := string(data)
	testing.expect(t, strings.contains(out, "// zcode settings"), "user comment survives")
	testing.expect(t, strings.contains(out, "\"theme\": \"dark\""), "user member survives")
	testing.expect(t, strings.contains(out, "\"other\": {\"type\": \"stdio\", \"command\": \"/bin/other\"}"), "sibling server survives")
	testing.expect(t, !strings.contains(out, "aubade"), "aubade entry must be gone")
	value, perr := config.jsonc_parse(data, context.temp_allocator)
	testing.expect(t, perr == nil && value != nil, "uninstalled config.json must stay valid JSON")

	// AGENTS.md keeps the user content, loses the managed block, and does
	// not gain a stray blank line where the block sat.
	agents, aerr := os.read_entire_file_from_path(agents_path, context.temp_allocator)
	if aerr != nil {
		testing.fail_now(t, "AGENTS.md vanished after uninstall")
	}
	agents_out := string(agents)
	testing.expect(t, strings.contains(agents_out, "User content that must survive."), "user content survives")
	testing.expect(t, !strings.contains(agents_out, "aubade:zcode:begin"), "managed block must be gone")
	testing.expect_value(t, agents_out, "# My notes\n\nUser content that must survive.\n")
}

@(test)
cli_uninstall_opencode_roundtrip :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-cli-un-oc-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	testing.expect_value(t, cli.setup_opencode_into(tmp), 0)
	testing.expect_value(t, cli.uninstall_opencode_into(tmp), 0)

	path, _ := filepath.join([]string{tmp, ".config", "opencode", "opencode.json"}, context.temp_allocator)
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		testing.fail_now(t, "opencode.json vanished after uninstall")
	}
	testing.expect(t, strings.contains(string(data), "\"$schema\""), "schema member survives")
	testing.expect(t, !strings.contains(string(data), "aubade"), "aubade entry must be gone")
	value, perr := config.jsonc_parse(data, context.temp_allocator)
	testing.expect(t, perr == nil && value != nil, "uninstalled opencode.json must stay valid JSON")

	// Idempotent: the member is gone, the second run is a clean no-op.
	testing.expect_value(t, cli.uninstall_opencode_into(tmp), 0)
}

// A separating comma parked on the line after the aubade member (legal JSON)
// defeats the removal's same-line comma pickup: the edit would leave a stray
// comma behind, so the write is refused and the file on disk stays untouched.
@(test)
cli_uninstall_refuses_pathological_comma :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-cli-un-comma-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	config_dir, _ := filepath.join([]string{tmp, ".config", "opencode"}, context.temp_allocator)
	_ = os.make_directory_all(config_dir)
	path, _ := filepath.join([]string{config_dir, "opencode.json"}, context.temp_allocator)
	existing := "{\n\t\"theme\": \"dark\",\n\t\"mcp\": {\n\t\t\"aubade\": {\"type\": \"local\", \"command\": [\"/bin/true\", \"mcp\"]}\n\t\t,\n\t}\n}\n"
	_ = os.write_entire_file_from_string(path, existing, os.Permissions{.Read_User, .Write_User})

	testing.expect_value(t, cli.uninstall_opencode_into(tmp), 1)

	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		testing.fail_now(t, "opencode.json vanished after the refused uninstall")
	}
	testing.expect_value(t, string(data), existing)
	value, perr := config.jsonc_parse(data, context.temp_allocator)
	testing.expect(t, perr == nil && value != nil, "the refused write must leave a parseable file")
}

// run_capture resolves a bare command head through PATH before spawning
// (the platform's executable-suffix rules — npm's .cmd launchers on
// Windows resolve here, not at the spawn) and reports not-ok for a name
// absent from PATH without attempting a spawn.
@(test)
cli_run_capture_resolves_bare_name :: proc(t: ^testing.T) {
	shell := "sh"
	flag := "-c"
	when ODIN_OS == .Windows {
		shell, flag = "cmd", "/C"
	}
	res, ok := cli.run_capture({shell, flag, "echo hi"})
	testing.expect(t, ok)
	testing.expect_value(t, res.code, 0)
	testing.expect(t, strings.contains(res.stdout, "hi"))

	_, missing := cli.run_capture({"aubade-definitely-missing-xyz", "--version"})
	testing.expect(t, !missing)
}

// The delegated removals must target the same server name and scope setup
// registered: claude's add used `--scope user`, so the remove names it too.
@(test)
cli_uninstall_remove_args :: proc(t: ^testing.T) {
	claude_args := cli.claude_mcp_remove_args(context.temp_allocator)
	testing.expect_value(t, len(claude_args), 6)
	if len(claude_args) == 6 {
		testing.expect_value(t, claude_args[0], "claude")
		testing.expect_value(t, claude_args[1], "mcp")
		testing.expect_value(t, claude_args[2], "remove")
		testing.expect_value(t, claude_args[3], "--scope")
		testing.expect_value(t, claude_args[4], "user")
		testing.expect_value(t, claude_args[5], "aubade")
	}

	codex_args := cli.codex_mcp_remove_args(context.temp_allocator)
	testing.expect_value(t, len(codex_args), 4)
	if len(codex_args) == 4 {
		testing.expect_value(t, codex_args[0], "codex")
		testing.expect_value(t, codex_args[1], "mcp")
		testing.expect_value(t, codex_args[2], "remove")
		testing.expect_value(t, codex_args[3], "aubade")
	}

	qwen_args := cli.qwen_mcp_remove_args(context.temp_allocator)
	testing.expect_value(t, len(qwen_args), 4)
	if len(qwen_args) == 4 {
		testing.expect_value(t, qwen_args[0], "qwen")
		testing.expect_value(t, qwen_args[1], "mcp")
		testing.expect_value(t, qwen_args[2], "remove")
		testing.expect_value(t, qwen_args[3], "aubade")
	}
}

@(test)
cli_mcp_list_has_aubade_detection :: proc(t: ^testing.T) {
	testing.expect_value(t, cli.mcp_list_has_aubade("aubade: /usr/local/bin/aubade mcp --project-from-cwd\n"), true)
	testing.expect_value(t, cli.mcp_list_has_aubade("other: /bin/foo\nnothing: /bin/else\n"), false)
	testing.expect_value(t, cli.mcp_list_has_aubade(""), false)
	// Token boundaries only: a similarly-named server must not count as a
	// registration, indented table rows must.
	testing.expect_value(t, cli.mcp_list_has_aubade("aubade-foo: /bin/other\n"), false)
	testing.expect_value(t, cli.mcp_list_has_aubade("my-aubade: /bin/other\n"), false)
	testing.expect_value(t, cli.mcp_list_has_aubade("xaubade\n"), false)
	testing.expect_value(t, cli.mcp_list_has_aubade("  aubade  /usr/local/bin/aubade mcp\n"), true)
	testing.expect_value(t, cli.mcp_list_has_aubade("other: /bin/foo\naubade: /bin/aubade\n"), true)
	// A path segment alone is not a server name; the name token decides.
	testing.expect_value(t, cli.mcp_list_has_aubade("other: /usr/local/bin/aubade mcp\n"), false)
}

@(test)
cli_write_text_file_is_write_once :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-cli-wtf-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	path, _ := filepath.join([]string{tmp, "res.jsonc"}, context.temp_allocator)
	testing.expect(t, cli.write_text_file("test create", path, "first body"), "fresh write must succeed")
	// A second write of the same path refuses instead of truncating, and
	// the existing content survives.
	testing.expect(t, !cli.write_text_file("test create", path, "second body"), "existing path must refuse")
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		testing.fail_now(t, "re-read failed")
	}
	testing.expect_value(t, string(data), "first body")
}

@(test)
cli_write_client_config_replaces_atomically :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-cli-wcc-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	path, _ := filepath.join([]string{tmp, "config.json"}, context.temp_allocator)
	first_body := "{\"first\":true}"
	second_body := "{\"second\":true}"
	testing.expect(t, cli.write_client_config(path, transmute([]u8)first_body), "fresh write must succeed")
	testing.expect(t, cli.write_client_config(path, transmute([]u8)second_body), "replace must succeed")
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		testing.fail_now(t, "re-read failed")
	}
	testing.expect_value(t, string(data), second_body)
	// The publish leaves no temp file behind.
	tmpname, _ := filepath.join([]string{tmp, "config.json.tmp"}, context.temp_allocator)
	testing.expect(t, !os.exists(tmpname), "atomic publish must not leave a temp file")
}

@(test)
cli_memory_file_body_bounds :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-cli-mfb-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	small, _ := filepath.join([]string{tmp, "small.md"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(small, "hello", os.Permissions{.Read_User, .Write_User})
	body, merr := cli.memory_file_body(small, context.temp_allocator)
	testing.expect_value(t, merr, "")
	testing.expect_value(t, body, "hello")

	// A directory is not a regular file: refused before any read.
	_, derr := cli.memory_file_body(tmp, context.temp_allocator)
	testing.expect(t, strings.contains(derr, "not a regular file"), "directory must be refused as non-regular")

	// Past the memory read cap: refused with the limit in the message. The
	// cap is 10 MiB; write one byte more.
	big, _ := filepath.join([]string{tmp, "big.md"}, context.temp_allocator)
	f, oerr := os.open(big, {.Write, .Create}, os.Permissions{.Read_User, .Write_User})
	if oerr != nil {
		testing.fail_now(t, "open big failed")
	}
	block: [8192]u8
	written := 0
	for written <= memory.MAX_MEMORY_READ_BYTES {
		_, _ = os.write(f, block[:])
		written += len(block)
	}
	os.close(f)
	_, berr := cli.memory_file_body(big, context.temp_allocator)
	testing.expect(t, strings.contains(berr, "too large"), "oversized file must be refused")
}

@(test)
cli_find_project_root_upward_search :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-cli-root-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}
	home, herr := os.make_directory_temp("", "aubade-cli-home-", context.allocator)
	if herr != nil {
		testing.fail_now(t, "temp home failed")
	}
	defer {
		_ = os.remove_all(home)
		delete(home)
	}

	// .git marker: a nested directory resolves to the repo root.
	git_root, _ := filepath.join([]string{tmp, "repo"}, context.temp_allocator)
	nested, _ := filepath.join([]string{tmp, "repo", "a", "b"}, context.temp_allocator)
	_ = os.make_directory_all(git_root)
	_ = os.make_directory_all(nested)
	git_dir, _ := filepath.join([]string{git_root, ".git"}, context.temp_allocator)
	_ = os.make_directory(git_dir)
	found := config.find_project_root(nested, home, context.temp_allocator)
	testing.expect_value(t, found, git_root)

	// The managed config wins over .git when it is closer.
	inner, _ := filepath.join([]string{tmp, "repo", "inner"}, context.temp_allocator)
	_ = os.make_directory(inner)
	managed, _ := filepath.join([]string{inner, ".aubade"}, context.temp_allocator)
	_ = os.make_directory(managed)
	cfg, _ := filepath.join([]string{managed, "project.jsonc"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(cfg, "{}", os.Permissions{.Read_User, .Write_User})
	found2 := config.find_project_root(inner, home, context.temp_allocator)
	testing.expect_value(t, found2, inner)

	// No markers anywhere above: empty result.
	lonely, _ := filepath.join([]string{tmp, "plain"}, context.temp_allocator)
	_ = os.make_directory(lonely)
	testing.expect_value(t, config.find_project_root(lonely, home, context.temp_allocator), "")

	// A relocated managed folder is the marker too: the global template
	// places the directory, and discovery resolves the same spelling.
	tpl_home, therr := os.make_directory_temp("", "aubade-cli-thome-", context.allocator)
	if therr != nil {
		testing.fail_now(t, "temp template home failed")
	}
	defer {
		_ = os.remove_all(tpl_home)
		delete(tpl_home)
	}
	global_cfg, _ := filepath.join([]string{tpl_home, "config.jsonc"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(
		global_cfg,
		"{\"project_aubade_folder_location\": \"$projectDir/.state\"}\n",
		os.Permissions{.Read_User, .Write_User},
	)
	moved_root, _ := filepath.join([]string{tmp, "moved"}, context.temp_allocator)
	moved_deep, _ := filepath.join([]string{tmp, "moved", "deep"}, context.temp_allocator)
	_ = os.make_directory_all(moved_deep)
	state_dir, _ := filepath.join([]string{moved_root, ".state"}, context.temp_allocator)
	_ = os.make_directory(state_dir)
	moved_cfg, _ := filepath.join([]string{state_dir, "project.jsonc"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(moved_cfg, "{}", os.Permissions{.Read_User, .Write_User})
	found3 := config.find_project_root(moved_deep, tpl_home, context.temp_allocator)
	testing.expect_value(t, found3, moved_root)
}

@(test)
cli_tool_list_and_show :: proc(t: ^testing.T) {
	testing.expect_value(t, cli.run({"tool"}, "test"), 2)
	testing.expect_value(t, cli.run({"tool", "explode"}, "test"), 2)

	tmp, err := os.make_directory_temp("", "aubade-cli-tool-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	old, had := os.lookup_env_alloc("AUBADE_HOME", context.temp_allocator)
	os.set_env("AUBADE_HOME", tmp)
	defer if had {
		os.set_env("AUBADE_HOME", old)
	} else {
		os.unset_env("AUBADE_HOME")
	}

	ctx_dir, _ := filepath.join([]string{tmp, "contexts"}, context.temp_allocator)
	os.make_directory(ctx_dir)
	ctx_path, _ := filepath.join([]string{tmp, "contexts", "narrow.jsonc"}, context.temp_allocator)
	fp, ferr := os.open(ctx_path, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if ferr != nil {
		testing.expectf(t, false, "context file open failed")
		return
	}
	narrow := `{"excluded_tools": ["file_read"]}`
	os.write(fp, transmute([]u8)narrow)
	os.close(fp)

	proj, _ := filepath.join([]string{tmp, "proj"}, context.temp_allocator)
	os.make_directory(proj)

	g := cli.Globals{project = proj}
	report, code := cli.tool_list_report(&g, {"narrow"}, nil, false, false, false, context.temp_allocator)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings_contains(report, "file_write — Write file"), "file_write must be listed")
	testing.expect(t, !strings_contains(report, "file_read — "), "context exclusion must hide file_read")
	testing.expect(t, strings_contains(report, "tools visible"), "summary line")

	show, show_code := cli.tool_show_report(&g, "file_write", nil, nil, context.temp_allocator)
	testing.expect_value(t, show_code, 0)
	testing.expect(t, strings_contains(show, "file_write — Write file"), "show header")
	testing.expect(t, strings_contains(show, "params schema:"), "show schema section")
	testing.expect(t, strings_contains(show, "properties"), "schema body")

	_, err_code := cli.tool_show_report(&g, "no_such_tool", nil, nil, context.temp_allocator)
	testing.expect_value(t, err_code, 1)
}

@(test)
cli_tracker_family :: proc(t: ^testing.T) {
	proj, perr := os.make_directory_temp("", "aubade-cli-trk-", context.allocator)
	if perr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(proj)
		delete(proj)
	}

	old, had := os.lookup_env_alloc("AUBADE_HOME", context.temp_allocator)
	os.set_env("AUBADE_HOME", proj)
	defer if had {
		os.set_env("AUBADE_HOME", old)
	} else {
		os.unset_env("AUBADE_HOME")
	}

	// Seed one incident through the domain manager (the write path the
	// CLI deliberately does not expose). expectf + return, never
	// fail_now: a daemonless early return must still run the defers
	// (fail_now fires past them and leaks the temp dir).
	state_dir, _ := filepath.join([]string{proj, ".aubade"}, context.temp_allocator)
	os.make_directory(state_dir, {.Read_User, .Write_User, .Execute_User})
	db_path, _ := filepath.join([]string{proj, ".aubade", "aubade.db"}, context.temp_allocator)
	db, oerr := store.db_open(db_path, context.allocator)
	testing.expectf(t, oerr == nil, "store open failed: %s", platform.err_message(oerr, context.temp_allocator))
	if oerr != nil {
		return
	}
	defer store.db_close(db)
	m := new(tracker.Manager, context.allocator)
	terr := tracker.manager_init(m, db, tracker_test_wall_ns, 1, 7, true, context.allocator)
	testing.expectf(t, terr == nil, "manager init failed")
	if terr != nil {
		free(m)
		return
	}
	input := tracker.Create_Input{
		title     = "cli family check",
		priority  = "low",
		body_md   = "seeded from the CLI test",
		created_by = "cli-test",
	}
	res, cerr := tracker.manager_create(m, &input, context.temp_allocator)
	testing.expect(t, cerr == nil, "seed create failed")
	testing.expect_value(t, res.id, "INC-001")
	tracker.manager_destroy(m)
	free(m)

	g := cli.Globals{project = proj}
	testing.expect_value(t, cli.run({"tracker", "list", "--project", proj}, "test"), 0)
	testing.expect_value(t, cli.run({"tracker", "show", "INC-001", "--project", proj}, "test"), 0)

	// --limit takes an integer in both spellings and rejects a non-integer
	// (the parse ok bool was once read upside down: every valid value was
	// refused and every invalid one passed as unlimited).
	testing.expect_value(t, cli.run({"tracker", "list", "--project", proj, "--limit", "1"}, "test"), 0)
	testing.expect_value(t, cli.run({"tracker", "list", "--project", proj, "--limit=1"}, "test"), 0)
	testing.expect_value(t, cli.run({"tracker", "list", "--project", proj, "--limit", "abc"}, "test"), 2)
	testing.expect_value(t, cli.run({"tracker", "report", "--format", "json", "--project", proj}, "test"), 0)
	testing.expect_value(t, cli.run({"tracker", "export", "--project", proj}, "test"), 0)

	// Reports live as store rows now: the export path must not add a
	// sprints tree to the project.
	sprints, _ := filepath.join([]string{proj, ".aubade", "tracker", "sprints"}, context.temp_allocator)
	if os.exists(sprints) {
		testing.expect(t, false, "tracker export must not write a sprints tree")
	}

	// Usage errors stay exit 2.
	testing.expect_value(t, cli.run({"tracker", "explode"}, "test"), 2)
	testing.expect_value(t, cli.run({"tracker", "show", "--nope"}, "test"), 2)
	_ = g
}

tracker_test_wall_ns :: proc() -> i64 {
	return platform.wall_ms() * 1_000_000
}

@(test)
cli_memories_family :: proc(t: ^testing.T) {
	proj, perr := os.make_directory_temp("", "aubade-cli-mem-", context.allocator)
	if perr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(proj)
		delete(proj)
	}

	old, had := os.lookup_env_alloc("AUBADE_HOME", context.temp_allocator)
	os.set_env("AUBADE_HOME", proj)
	defer if had {
		os.set_env("AUBADE_HOME", old)
	} else {
		os.unset_env("AUBADE_HOME")
	}

	testing.expect_value(t, cli.run({"memory", "write", "auth/login", "--content", "the login notes", "--project", proj}, "test"), 0)
	testing.expect_value(t, cli.run({"memory", "write", "reader", "--content", "see also auth/login", "--project", proj}, "test"), 0)
	testing.expect_value(t, cli.run({"memory", "list", "--project", proj}, "test"), 0)
	testing.expect_value(t, cli.run({"memory", "show", "auth/login", "--project", proj}, "test"), 0)
	// Resolvable references pass; a dangling one exits 1.
	testing.expect_value(t, cli.run({"memory", "check", "--project", proj}, "test"), 0)
	testing.expect_value(t, cli.run({"memory", "write", "dangling", "--content", "see mem:nope/void", "--project", proj}, "test"), 0)
	testing.expect_value(t, cli.run({"memory", "check", "--project", proj}, "test"), 1)

	// Write a memory with a bare name occurrence, then auto-prefix it.
	testing.expect_value(t, cli.run({"memory", "write", "bare", "--content", "points at auth/login plainly", "--project", proj}, "test"), 0)
	testing.expect_value(t, cli.run({"memory", "fix-references", "--project", proj}, "test"), 0)
	mem_dir, _ := filepath.join([]string{proj, ".aubade", "memories", "bare.md"}, context.temp_allocator)
	data, rerr := os.read_entire_file_from_path(mem_dir, context.temp_allocator)
	testing.expect(t, rerr == nil, "bare memory missing")
	testing.expect_value(t, string(data), "points at mem:auth/login plainly")

	testing.expect_value(t, cli.run({"memory", "explode"}, "test"), 2)
}

@(test)
cli_project_create_scans_languages :: proc(t: ^testing.T) {
	proj, perr := os.make_directory_temp("", "aubade-cli-proj-", context.allocator)
	if perr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(proj)
		delete(proj)
	}

	old, had := os.lookup_env_alloc("AUBADE_HOME", context.temp_allocator)
	os.set_env("AUBADE_HOME", proj)
	defer if had {
		os.set_env("AUBADE_HOME", old)
	} else {
		os.unset_env("AUBADE_HOME")
	}

	src_dir, _ := filepath.join([]string{proj, "src"}, context.temp_allocator)
	os.make_directory(src_dir)
	go_path, _ := filepath.join([]string{proj, "src", "main.go"}, context.temp_allocator)
	fp, ferr := os.open(go_path, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if ferr != nil {
		testing.fail_now(t, "seed file failed")
	}
	seed := "package main\n"
	os.write(fp, transmute([]u8)seed)
	os.close(fp)

	testing.expect_value(t, cli.run({"project", "create", proj}, "test"), 0)
	cfg_path, _ := filepath.join([]string{proj, ".aubade", "project.jsonc"}, context.temp_allocator)
	data, rerr := os.read_entire_file_from_path(cfg_path, context.temp_allocator)
	testing.expect(t, rerr == nil, "project.jsonc was not written")
	body := string(data)
	testing.expect(t, strings.contains(body, "\"go\""), "the scan must detect go")

	// Write-once: the second create refuses.
	testing.expect_value(t, cli.run({"project", "create", proj}, "test"), 2)

	// The root joined the registry.
	reg, lerr := config.registry_load(proj, context.temp_allocator)
	testing.expect(t, lerr == nil, "registry load failed")
	if lerr == nil {
		found := false
		for p in reg.projects {
			if strings.equal_fold(p, proj) {
				found = true
			}
		}
		testing.expect(t, found, "project root not registered")
		config.registry_destroy(reg, context.temp_allocator)
	}
}

@(test)
cli_prompt_render :: proc(t: ^testing.T) {
	proj, perr := os.make_directory_temp("", "aubade-cli-pp-", context.allocator)
	if perr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(proj)
		delete(proj)
	}

	old, had := os.lookup_env_alloc("AUBADE_HOME", context.temp_allocator)
	os.set_env("AUBADE_HOME", proj)
	defer if had {
		os.set_env("AUBADE_HOME", old)
	} else {
		os.unset_env("AUBADE_HOME")
	}

	// A global memory and one seeded incident: both must ride into the
	// rendered prompt.
	gdir, _ := filepath.join([]string{proj, "memories", "global"}, context.temp_allocator)
	os.make_directory_all(gdir)
	gpath, _ := filepath.join([]string{gdir, "guide.md"}, context.temp_allocator)
	gf, gerr := os.open(gpath, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if gerr != nil {
		testing.fail_now(t, "global memory seed failed")
	}
	guide := "the global guide"
	os.write(gf, transmute([]u8)guide)
	os.close(gf)

	state_dir, _ := filepath.join([]string{proj, ".aubade"}, context.temp_allocator)
	os.make_directory(state_dir, {.Read_User, .Write_User, .Execute_User})
	db_path, _ := filepath.join([]string{proj, ".aubade", "aubade.db"}, context.temp_allocator)
	db, oerr := store.db_open(db_path, context.allocator)
	testing.expectf(t, oerr == nil, "store open failed: %s", platform.err_message(oerr, context.temp_allocator))
	if oerr != nil {
		return
	}
	m := new(tracker.Manager, context.allocator)
	terr := tracker.manager_init(m, db, tracker_test_wall_ns, 1, 7, true, context.allocator)
	testing.expectf(t, terr == nil, "manager init failed")
	if terr != nil {
		store.db_close(db)
		free(m)
		return
	}
	input := tracker.Create_Input{title = "prompt render check", body_md = "seeded", created_by = "cli-test"}
	res, cerr := tracker.manager_create(m, &input, context.temp_allocator)
	testing.expect(t, cerr == nil, "seed create failed")
	testing.expect_value(t, res.id, "INC-001")
	tracker.manager_destroy(m)
	free(m)
	store.db_close(db)

	g := cli.Globals{project = proj}
	report, code := cli.prompt_render_report(&g, nil, nil, false, context.temp_allocator)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings_contains(report, "You will receive access to Aubade's symbolic tools"), "prefix line")
	testing.expect(t, strings_contains(report, "You begin by acknowledging"), "postfix line")
	testing.expect(t, strings_contains(report, "Context description:"), "context section")
	// The default context (desktop-app) prompt rides through.
	testing.expect(t, strings_contains(report, "desktop application context"), "default context prompt")
	// The folded tool set carries the namespaced names the template keys on.
	testing.expect(t, strings_contains(report, "incident_create"), "tracker verbs for the full fold")
	// Global memories appear as the dict; the tracker summary line too.
	testing.expect(t, strings_contains(report, "global/guide"), "global memory name")
	testing.expect(t, strings_contains(report, "Tracker: 1 open"), "tracker summary")

	bare, bcode := cli.prompt_render_report(&g, nil, nil, true, context.temp_allocator)
	testing.expect_value(t, bcode, 0)
	testing.expect(t, !strings_contains(bare, "You will receive access"), "--only-instructions drops the prefix")
	testing.expect(t, strings_contains(bare, "Tracker: 1 open"), "bare render keeps the body")

	testing.expect_value(t, cli.run({"prompt"}, "test"), 2)
	testing.expect_value(t, cli.run({"prompt", "explode"}, "test"), 2)
	testing.expect_value(t, cli.run({"prompt", "render", "--project", proj}, "test"), 0)
	testing.expect_value(t, cli.run({"prompt", "render", "--cc-override"}, "test"), 0)
	testing.expect_value(t, cli.run({"prompt", "render", "--cc-override", "extra-arg"}, "test"), 2)
}

@(test)
cli_prompt_template_family :: proc(t: ^testing.T) {
	home, perr := os.make_directory_temp("", "aubade-cli-pt-", context.allocator)
	if perr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(home)
		delete(home)
	}

	old, had := os.lookup_env_alloc("AUBADE_HOME", context.temp_allocator)
	os.set_env("AUBADE_HOME", home)
	defer if had {
		os.set_env("AUBADE_HOME", old)
	} else {
		os.unset_env("AUBADE_HOME")
	}

	testing.expect_value(t, cli.run({"prompt", "list"}, "test"), 0)
	testing.expect_value(t, cli.run({"prompt", "show", "system_prompt"}, "test"), 0)
	testing.expect_value(t, cli.run({"prompt", "show", "no_such_template"}, "test"), 1)
	testing.expect_value(t, cli.run({"prompt", "show"}, "test"), 2)
	testing.expect_value(t, cli.run({"prompt", "override", "delete", "missing"}, "test"), 1)
	testing.expect_value(t, cli.run({"prompt", "override", "edit", "missing"}, "test"), 1)

	when ODIN_OS != .Windows {
		// "true" exists everywhere POSIX; the editor must exit 0.
		eold, ehad := os.lookup_env_alloc("EDITOR", context.temp_allocator)
		os.set_env("EDITOR", "true")
		defer if ehad {
			os.set_env("EDITOR", eold)
		} else {
			os.unset_env("EDITOR")
		}

		testing.expect_value(t, cli.run({"prompt", "override", "create", "system_prompt"}, "test"), 0)
		opath, _ := filepath.join([]string{home, "prompt_templates", "system_prompt.tmpl"}, context.temp_allocator)
		data, rerr := os.read_entire_file_from_path(opath, context.temp_allocator)
		testing.expect(t, rerr == nil, "override file was not written")
		// A fresh override starts from the built-in body.
		testing.expect(t, strings_contains(string(data), "incident_create"), "override copies the built-in body")
		testing.expect_value(t, cli.run({"prompt", "override", "create", "system_prompt"}, "test"), 1)
		testing.expect_value(t, cli.run({"prompt", "override", "edit", "system_prompt"}, "test"), 0)
		testing.expect_value(t, cli.run({"prompt", "override", "delete", "system_prompt"}, "test"), 0)
		testing.expect(t, !os.exists(opath), "override file still present after delete")
	}
}

@(test)
cli_context_mode_config_family :: proc(t: ^testing.T) {
	home, perr := os.make_directory_temp("", "aubade-cli-res-", context.allocator)
	if perr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(home)
		delete(home)
	}

	old, had := os.lookup_env_alloc("AUBADE_HOME", context.temp_allocator)
	os.set_env("AUBADE_HOME", home)
	defer if had {
		os.set_env("AUBADE_HOME", old)
	} else {
		os.unset_env("AUBADE_HOME")
	}

	// Usage errors stay exit 2; listings include the builtins.
	testing.expect_value(t, cli.run({"context"}, "test"), 2)
	testing.expect_value(t, cli.run({"context", "explode"}, "test"), 2)
	testing.expect_value(t, cli.run({"mode", "explode"}, "test"), 2)
	testing.expect_value(t, cli.run({"config", "explode"}, "test"), 2)
	testing.expect_value(t, cli.run({"context", "list"}, "test"), 0)
	testing.expect_value(t, cli.run({"mode", "list"}, "test"), 0)

	ctx_names := config.list_context_names(home, context.temp_allocator)
	testing.expect(t, len(ctx_names) > 0, "context listing is empty")
	found_desktop := false
	for n in ctx_names {
		if n == "desktop-app" {
			found_desktop = true
		}
	}
	testing.expect(t, found_desktop, "built-in contexts missing from the listing")
	delete(ctx_names, context.temp_allocator)

	// config edit without a config file refuses with the init hint.
	testing.expect_value(t, cli.run({"config", "edit"}, "test"), 1)

	when ODIN_OS != .Windows {
		eold, ehad := os.lookup_env_alloc("EDITOR", context.temp_allocator)
		os.set_env("EDITOR", "true")
		defer if ehad {
			os.set_env("EDITOR", eold)
		} else {
			os.unset_env("EDITOR")
		}

		// Create from the template, then refuse to overwrite.
		testing.expect_value(t, cli.run({"context", "create", "myctx"}, "test"), 0)
		cpath, _ := filepath.join([]string{home, "contexts", "myctx.jsonc"}, context.temp_allocator)
		tdata, terr := os.read_entire_file_from_path(cpath, context.temp_allocator)
		testing.expect(t, terr == nil, "context file was not written")
		testing.expect(t, strings_contains(string(tdata), "Aubade agent context definition"), "template body")
		testing.expect_value(t, cli.run({"context", "create", "myctx"}, "test"), 1)
		testing.expect_value(t, cli.run({"context", "edit", "myctx"}, "test"), 0)

		// Editing a built-in name without a user file prints the hint and
		// exits 0; an unknown name is an error.
		testing.expect_value(t, cli.run({"context", "edit", "desktop-app"}, "test"), 0)
		testing.expect_value(t, cli.run({"context", "edit", "no-such-thing"}, "test"), 1)
		testing.expect_value(t, cli.run({"context", "create", "bad name"}, "test"), 2)

		// --from-internal serialises the built-in definition and reloads.
		testing.expect_value(t, cli.run({"context", "create", "--from-internal", "agent"}, "test"), 0)
		agent_path, _ := filepath.join([]string{home, "contexts", "agent.jsonc"}, context.temp_allocator)
		adata, aerr := os.read_entire_file_from_path(agent_path, context.temp_allocator)
		testing.expect(t, aerr == nil, "agent copy was not written")
		testing.expect(t, strings_contains(string(adata), "agent context"), "serialised builtin prompt")
		def, lerr := config.load_context(home, "agent", context.temp_allocator)
		testing.expect(t, lerr == nil, "the copied file must reload as a context")
		if lerr == nil {
			testing.expect(t, strings.contains(def.prompt, "agent context"), "reloaded prompt")
		}
		testing.expect_value(t, cli.run({"context", "create", "--from-internal", "no-such"}, "test"), 1)

		// Delete round-trips.
		testing.expect_value(t, cli.run({"context", "delete", "myctx"}, "test"), 0)
		testing.expect_value(t, cli.run({"context", "delete", "myctx"}, "test"), 1)
		testing.expect_value(t, cli.run({"context", "delete", "desktop-app"}, "test"), 1)

		// Modes share the machinery.
		testing.expect_value(t, cli.run({"mode", "create", "mymode"}, "test"), 0)
		mpath, _ := filepath.join([]string{home, "modes", "mymode.jsonc"}, context.temp_allocator)
		testing.expect(t, os.exists(mpath), "mode file was not written")
		testing.expect_value(t, cli.run({"mode", "delete", "mymode"}, "test"), 0)

		// config edit opens the existing config.
		gpath := platform.config_path(home, context.temp_allocator)
		gdir := filepath.dir(gpath)
		os.make_directory_all(gdir)
		gf, gferr := os.open(gpath, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
		if gferr != nil {
			testing.fail_now(t, "config seed failed")
		}
		empty_cfg := "{}"
		os.write(gf, transmute([]u8)empty_cfg)
		os.close(gf)
		testing.expect_value(t, cli.run({"config", "edit"}, "test"), 0)
	}
}

@(test)
cli_project_registry_family :: proc(t: ^testing.T) {
	home, herr := os.make_directory_temp("", "aubade-cli-proj-", context.allocator)
	if herr != nil {
		testing.fail_now(t, "home temp failed")
	}
	defer {
		_ = os.remove_all(home)
		delete(home)
	}
	proj, perr := os.make_directory_temp("", "aubade-cli-target-", context.allocator)
	if perr != nil {
		testing.fail_now(t, "project temp failed")
	}
	defer {
		_ = os.remove_all(proj)
		delete(proj)
	}
	main_path, _ := filepath.join({proj, "main.go"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(main_path, "package main\n")

	old, had := os.lookup_env_alloc("AUBADE_HOME", context.temp_allocator)
	os.set_env("AUBADE_HOME", home)
	defer if had {
		os.set_env("AUBADE_HOME", old)
	} else {
		os.unset_env("AUBADE_HOME")
	}

	// create registers the root; list stays quiet with one entry (the
	// exit code and the registry file carry the assertion).
	testing.expect_value(t, cli.run({"project", "create", proj, "--language", "go"}, "test"), 0)
	testing.expect_value(t, cli.run({"project", "list"}, "test"), 0)
	reg, rerr := config.registry_load(home, context.temp_allocator)
	testing.expectf(t, rerr == nil, "registry_load failed")
	if rerr == nil {
		defer config.registry_destroy(reg, context.temp_allocator)
		found := false
		for p in reg.projects {
			if p == proj {
				found = true
			}
		}
		testing.expect_value(t, found, true)
	}

	// A registered name resolves through --project (the base name the
	// list shows).
	resolved, lok := cli.registry_name_lookup(filepath.base(proj))
	testing.expect_value(t, lok, true)
	testing.expect_value(t, resolved, proj)

	// check-ignore answers through the walk's predicate.
	gi_path, _ := filepath.join({proj, ".gitignore"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(gi_path, "gen/\n")
	testing.expect_value(t, cli.run({"project", "check-ignore", "gen/x.go", "--project", proj}, "test"), 0)
	testing.expect_value(t, cli.run({"project", "check-ignore", "main.go", "--project", proj}, "test"), 0)

	// remove accepts the name; a second remove fails.
	name := filepath.base(proj)
	testing.expect_value(t, cli.run({"project", "delete", name}, "test"), 0)
	testing.expect_value(t, cli.run({"project", "delete", name}, "test"), 1)
}

@(test)
cli_project_index_and_doctor_cores :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	// daemon_run spawns the one-shot startup index warm-up for every pair,
	// and its crawl races the fixture below: whichever indexer commits
	// main.go's fingerprint second reports "0 files". Wait the warm-up out
	// before writing the fixture — afterwards no background indexer runs
	// again in this test (the warm-up is one-shot per daemon life, the
	// refresh loop's first tick is a full interval away, and the on-miss
	// walk only fires from symbol_find) — so the crawl's stats below are
	// deterministic.
	testing.expectf(t, wait_index_warm(pair, 30_000), "startup index warm-up did not complete")

	svc_symbol_write_file(t, pair.tmp, "src/main.go", "package main\n\nfunc Main() {}\n")

	// The index and doctor bodies against the channel-transport daemon:
	// the crawl fills L0 and answers with stats; doctor layers the config
	// and language-server registry over it.
	summary, code := cli.index_summary(pair.conn, "", context.temp_allocator)
	testing.expectf(t, code == 0, "index failed: %s", summary)
	testing.expectf(t, strings.contains(summary, "Indexed"), summary)
	testing.expectf(t, strings.contains(summary, "1 files"), summary)

	// The single-file re-run is incremental: the whole-project index just
	// committed main.go's fingerprint, so re-indexing the unchanged file
	// skips the parse and reports zero.
	one, ocode := cli.index_summary(pair.conn, "src/main.go", context.temp_allocator)
	testing.expectf(t, ocode == 0, "single-file index failed: %s", one)
	testing.expectf(t, strings.contains(one, "0 files"), one)

	old, had := os.lookup_env_alloc("AUBADE_HOME", context.temp_allocator)
	os.set_env("AUBADE_HOME", pair.home)
	defer if had {
		os.set_env("AUBADE_HOME", old)
	} else {
		os.unset_env("AUBADE_HOME")
	}
	report, dcode := cli.doctor_report(pair.conn, pair.tmp, context.temp_allocator)
	testing.expectf(t, dcode == 0, "doctor failed: %s", report)
	testing.expectf(t, strings.contains(report, "config:"), report)
	testing.expectf(t, strings.contains(report, "language servers:"), report)
}

@(test)
cli_tool_list_flags_and_show_visibility :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-cli-flags-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	old, had := os.lookup_env_alloc("AUBADE_HOME", context.temp_allocator)
	os.set_env("AUBADE_HOME", tmp)
	defer if had {
		os.set_env("AUBADE_HOME", old)
	} else {
		os.unset_env("AUBADE_HOME")
	}

	cdir := platform.config_path(tmp, context.temp_allocator)
	cdir = filepath.dir(cdir)
	os.make_directory_all(cdir)
	cpath, _ := filepath.join({cdir, "contexts", "narrow.jsonc"}, context.temp_allocator)
	os.make_directory_all(filepath.dir(cpath))
	fp, ferr := os.open(cpath, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if ferr != nil {
		testing.fail_now(t, "context write failed")
	}
	narrow_ctx := `{"excluded_tools": ["file_read"]}`
	os.write(fp, transmute([]u8)narrow_ctx)
	os.close(fp)

	proj, _ := filepath.join({tmp, "proj"}, context.temp_allocator)
	os.make_directory(proj)
	g := cli.Globals{project = proj}

	// --all ignores the layers: the excluded tool returns.
	all_report, acode := cli.tool_list_report(&g, {"narrow"}, nil, true, false, false, context.temp_allocator)
	testing.expect_value(t, acode, 0)
	testing.expect(t, strings_contains(all_report, "file_read — "), "--all must ignore the context exclusion")

	// --only-optional keeps only optional tools.
	opt_report, ocode := cli.tool_list_report(&g, nil, nil, true, true, false, context.temp_allocator)
	testing.expect_value(t, ocode, 0)
	testing.expect(t, strings_contains(opt_report, "langserver_reload — "), "an optional tool must be listed")
	testing.expect(t, !strings_contains(opt_report, "file_read — "), "a non-optional tool must be dropped")

	// --quiet prints names only.
	quiet_report, qcode := cli.tool_list_report(&g, nil, nil, false, false, true, context.temp_allocator)
	testing.expect_value(t, qcode, 0)
	testing.expect(t, !strings_contains(quiet_report, " — "), "quiet lines carry names only")
	testing.expect(t, strings_contains(quiet_report, "\nfile_write\n") || strings.has_prefix(quiet_report, "file_write\n") || strings.has_suffix(quiet_report, "\nfile_write") || quiet_report == "file_write", "a bare name line")

	// show --context answers the folded visibility (wording overrides
	// are abolished by design — this is what the selector reports).
	show, scode := cli.tool_show_report(&g, "file_read", {"narrow"}, nil, context.temp_allocator)
	testing.expect_value(t, scode, 0)
	testing.expect(t, strings_contains(show, "visibility: hidden"), show)
	show2, scode2 := cli.tool_show_report(&g, "file_write", {"narrow"}, nil, context.temp_allocator)
	testing.expect_value(t, scode2, 0)
	testing.expect(t, strings_contains(show2, "visibility: visible"), show2)
}

@(test)
cli_tracker_sanitize_keeps_utf8 :: proc(t: ^testing.T) {
	// Well-formed multibyte runes pass through byte-for-byte (the byte-
	// space C1 filter once shredded these: the em-dash lost 0x80 0x94).
	em := cli.tracker_sanitize("no incidents yet — file one")
	testing.expect(t, strings_contains(em, "yet — file"), em)
	kana := cli.tracker_sanitize("見出し あいう")
	testing.expect(t, strings_contains(kana, "見出し あいう"), kana)

	// C1 control runes (U+0080-U+009F) encode as c2 80..c2 9f and are
	// stripped — the rune-space meaning of the filter.
	raw_c1 := []u8{'a', 0xc2, 0x85, 'b'}
	c1 := cli.tracker_sanitize(string(raw_c1))
	testing.expect_value(t, len(c1), 2)

	// C0 controls and DEL drop; newlines and tabs stay.
	raw_c0 := []u8{'a', 0x01, 0x7f, 'b'}
	testing.expect_value(t, len(cli.tracker_sanitize(string(raw_c0))), 2)
	nt := cli.tracker_sanitize("a\nb\tc")
	testing.expect_value(t, len(nt), 5)

	// Whole ANSI sequences vanish; stray continuation bytes drop.
	csi := cli.tracker_sanitize("x\e[31mred\e[0my")
	testing.expect_value(t, len(csi), 5) // "xredy"
	raw_stray := []u8{'a', 0x80, 0x94, 'b'}
	stray := cli.tracker_sanitize(string(raw_stray))
	testing.expect_value(t, len(stray), 2)
	raw_trunc := []u8{'a', 0xe2, 0x80}
	truncated := cli.tracker_sanitize(string(raw_trunc))
	testing.expect_value(t, len(truncated), 1)
}

@(test)
cli_daemon_ctl_globals_before_verb :: proc(t: ^testing.T) {
	// A global flag sitting between `daemon` and the verb must be
	// consumed as a global, not misparsed as the verb (strip_globals'
	// anywhere-contract). The call still exits 2 (usage_error: no
	// --project is set, and resolve_project_root fails before any
	// dialing) — but the parse reached the verb and recorded the level.
	g := cli.Globals{}
	code := cli.run_daemon_ctl({"--log-level", "debug", "status"}, &g, "test")
	testing.expect_value(t, code, 2)
	testing.expect_value(t, g.log_level, "debug")
}

// The check and auto-prefix cores own their listing: svc.memory_list hands
// back a Memories_List whose names the destroy deletes, so the results
// must not alias it — and the listing must not leak (the tracking
// allocator reports any missing destroy as a leak block).
@(test)
cli_memory_check_and_autoprefix_cores :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-cli-mem-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	mf: svc.Memory_Files
	svc.memory_files_init(&mf, tmp, tmp, nil, nil, context.allocator)
	defer svc.memory_files_destroy(&mf)

	if serr := svc.memory_save(&mf, "alpha", "notes for the first memory\n", context.temp_allocator); serr != nil {
		testing.expectf(t, false, "memory_save alpha failed")
		return
	}
	if serr := svc.memory_save(&mf, "beta", "see mem:missing and bare alpha\n", context.temp_allocator); serr != nil {
		testing.expectf(t, false, "memory_save beta failed")
		return
	}

	refs := cli.memories_check_refs(&mf, context.temp_allocator)
	testing.expect_value(t, len(refs), 1)
	if len(refs) == 1 {
		testing.expect_value(t, refs[0].from, "beta")
		testing.expect_value(t, refs[0].to, "missing")
		testing.expect_value(t, refs[0].line, 1)
	}

	modified := cli.memories_autoprefix(&mf, false, context.temp_allocator)
	testing.expect_value(t, modified, 1)
	body, found, lerr := svc.memory_load(&mf, "beta", context.temp_allocator)
	testing.expectf(t, lerr == nil && found, "beta must reload after the rewrite")
	testing.expect_value(t, body, "see mem:missing and bare mem:alpha\n")
}

when ODIN_OS != .Windows {
@(test)
cli_setup_zcode_refuses_unreadable_agents :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-cli-agents-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}
	zdir, _ := filepath.join({tmp, ".zcode"}, context.temp_allocator)
	os.make_directory_all(zdir)
	agents, _ := filepath.join({zdir, "AGENTS.md"}, context.temp_allocator)
	if werr := os.write_entire_file_from_string(agents, "user content\n"); werr != nil {
		testing.fail_now(t, "agents write failed")
	}
	// chmod is advisory on Windows — the unreadable-file refusal is
	// verified on the POSIX platforms only.
	os.chmod(agents, os.Permissions{})
	defer if os.exists(agents) {
		os.chmod(agents, os.Permissions{.Read_User, .Write_User})
	}

	// The unreadable file is refused, not treated as absent and replaced.
	testing.expect_value(t, cli.setup_zcode_into(tmp), 1)
	os.chmod(agents, os.Permissions{.Read_User, .Write_User})
	data, rerr := os.read_entire_file_from_path(agents, context.temp_allocator)
	testing.expectf(t, rerr == nil, "AGENTS.md must still be readable")
	testing.expect_value(t, string(data), "user content\n")
}
}
