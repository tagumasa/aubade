// aubade setup <client>: register the MCP server with a client. The file
// editors (zcode config.json, opencode opencode.json) splice into the
// existing JSONC through the format-preserving editor — comments and layout
// survive; claudecode, codex, and qwen shell out to their own `mcp add`
// commands.
package cli

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "src:config"
import "src:platform"
import "src:util"

// Client config files are tiny; anything past 1 MiB is not a config file.
MAX_CLIENT_CONFIG_BYTES :: 1 << 20

Capture_Result :: struct {
	stdout: string,
	stderr: string,
	code:   int,
}

// Client_Cmds pairs each supported client's name with its applicability
// probe and setup/uninstall entry points; the roster, the detection
// walk, and the usage lines all dispatch through CLIENT_CMDS so the
// client list exists in one place.
Client_Cmds :: struct {
	name:       string,
	applicable: proc() -> bool,
	setup:      proc() -> int,
	uninstall:  proc() -> int,
}

CLIENT_CMDS :: []Client_Cmds{
	{name = "claudecode", applicable = claude_code_applicable, setup = setup_claude_code, uninstall = uninstall_claude_code},
	{name = "codex",      applicable = codex_applicable,      setup = setup_codex,      uninstall = uninstall_codex},
	{name = "opencode",   applicable = opencode_applicable,   setup = setup_opencode,   uninstall = uninstall_opencode},
	{name = "qwen",       applicable = qwen_applicable,       setup = setup_qwen,       uninstall = uninstall_qwen},
	{name = "zcode",      applicable = zcode_applicable,      setup = setup_zcode,      uninstall = uninstall_zcode},
}

// client_names_csv renders the supported client roster comma-joined for
// the usage lines — derived from CLIENT_CMDS.
client_names_csv :: proc(a := context.allocator) -> string {
	names := make([dynamic]string, 0, len(CLIENT_CMDS), context.temp_allocator)
	defer delete(names)
	for &c in CLIENT_CMDS {
		append(&names, c.name)
	}
	return util.quoted_join(names[:], ", ", "", a)
}

// run_client_cmd drives `aubade <cmd> <client>`: strip globals, require
// exactly one client name, and run the client's entry point selected by
// `op`; an unknown name exits 2.
run_client_cmd :: proc(cmd: string, args: []string, g: ^Globals, op: proc(c: ^Client_Cmds) -> int) -> int {
	rest := make([dynamic]string, 0, len(args), context.temp_allocator)
	if !strip_globals(args, g, &rest) {
		return usage_error(cmd, "invalid global flag value")
	}
	if len(rest) != 1 {
		return usage_error(
			cmd,
			strings.concatenate({"usage: aubade ", cmd, " <client> (", client_names_csv(context.temp_allocator), ")"}, context.temp_allocator),
		)
	}
	client := rest[0]
	entries := CLIENT_CMDS
	for &c in entries {
		if c.name == client {
			return op(&c)
		}
	}
	fmt.eprintf("aubade %s: unknown client %q; available clients: %s\n", cmd, client, client_names_csv(context.temp_allocator))
	return 2
}

client_setup_op :: proc(c: ^Client_Cmds) -> int {
	return c.setup()
}

client_uninstall_op :: proc(c: ^Client_Cmds) -> int {
	return c.uninstall()
}

run_setup :: proc(args: []string, g: ^Globals, version: string) -> int {
	return run_client_cmd("setup", args, g, client_setup_op)
}

// --- shared helpers ----------------------------------------------------------

// run_capture executes `command` and waits for it, capturing both streams.
run_capture :: proc(command: []string) -> (Capture_Result, bool) {
	desc: os.Process_Desc
	desc.command = command
	state, stdout, stderr, err := os.process_exec(desc, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	return {string(stdout), string(stderr), state.exit_code}, true
}

// resolve_aubade_binary prefers the running executable over a PATH lookup:
// setup registers the binary that is performing the setup, which is what
// the user just installed or built.
resolve_aubade_binary :: proc() -> string {
	path, err := os.get_executable_path(context.temp_allocator)
	if err == nil && path != "" {
		return path
	}
	return "aubade"
}

// read_client_config reads a client config with a size bound.
read_client_config :: proc(path: string) -> ([]u8, bool) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return nil, false
	}
	if len(data) > MAX_CLIENT_CONFIG_BYTES {
		return nil, false
	}
	return data, true
}

// write_client_config publishes bytes to a user config path atomically
// (tmp + rename): a kill between truncate and write can never leave the
// user's client config or AGENTS.md empty.
write_client_config :: proc(path: string, body: []u8) -> bool {
	return platform.atomic_write(path, body, os.Permissions{.Read_User, .Write_User, .Read_Other}) == nil
}

// edited_client_config_parses gates every write of editor-spliced bytes: the
// format-preserving editor's removal can leave invalid syntax behind on
// pathological layouts (its contract says the caller validates before
// writing), and a client config that no longer parses breaks the client.
// Comments stay tolerated (these clients read JSONC), but commas are judged
// by a strict JSON parse — the JSONC reader's trailing-comma tolerance would
// accept exactly the residue this gate exists to refuse.
edited_client_config_parses :: proc(body: []u8) -> bool {
	stripped, sok := config.strip_jsonc(body, true, context.temp_allocator)
	if !sok {
		return false
	}
	if !util.json_sanity_ok(stripped) {
		return false
	}
	_, err := json.parse_bytes(stripped, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	return err == nil
}

// --- zcode -------------------------------------------------------------------

ZCODE_AGENTS_BEGIN :: "<!-- aubade:zcode:begin -->"
ZCODE_AGENTS_END :: "<!-- aubade:zcode:end -->"

// The snippet maintained in ~/.zcode/AGENTS.md. ZCode does not surface the
// MCP instructions field to the model, so the session-start trigger must
// live in the client's instruction file: a minimal directive to read the
// aubade manual, which then carries the full zcode context rules.
ZCODE_AGENTS_INSTRUCTION :: "When the aubade MCP server is connected: at the start of every session, and\n" +
	"again immediately after any context compaction (/compact), call the aubade\n" +
	"tools `onboarding_read_instructions` and `onboarding_check` before starting\n" +
	"work. If onboarding has not been performed, run the `onboarding_run` tool\n" +
	"first. For content and file-name searches, prefer the aubade tools\n" +
	"`file_search` and `file_find` over built-in grep/glob: their answers are\n" +
	"token-capped and they skip ignored files."

zcode_applicable :: proc() -> bool {
	home := user_home_dir()
	if home != "" {
		dir, _ := filepath.join([]string{home, ".zcode", "cli"}, context.temp_allocator)
		if os.is_directory(dir) {
			return true
		}
	}
	res, ok := run_capture({"zcode", "--version"})
	return ok && res.code == 0
}

setup_zcode :: proc() -> int {
	home := user_home_dir()
	if home == "" {
		fmt.eprintln("aubade setup: could not determine home directory for zcode config")
		return 1
	}
	return setup_zcode_into(home)
}

// setup_zcode_into is the file-level half of the zcode setup, parameterized
// by the home directory so tests can drive it against a temp directory.
setup_zcode_into :: proc(home_dir: string) -> int {
	config_dir, _ := filepath.join([]string{home_dir, ".zcode", "cli"}, context.temp_allocator)
	if err := os.make_directory_all(config_dir); err != nil && !os.is_directory(config_dir) {
		fmt.eprintf("aubade setup: cannot create zcode config dir: %s\n", config_dir)
		return 1
	}

	config_path, _ := filepath.join([]string{config_dir, "config.json"}, context.temp_allocator)
	binary := resolve_aubade_binary()
	args := aubade_child_tail("zcode", context.temp_allocator)

	code := apply_zcode_config(config_path, binary, args)
	if code != 0 {
		return code
	}

	agents_path, _ := filepath.join([]string{home_dir, ".zcode", "AGENTS.md"}, context.temp_allocator)
	return ensure_zcode_agents(agents_path)
}

apply_zcode_config :: proc(path: string, binary: string, args: []string) -> int {
	if !os.exists(path) {
		rendered := render_fresh_zcode_config(binary, args, context.temp_allocator)
		if !write_client_config(path, transmute([]u8)rendered) {
			fmt.eprintf("aubade setup: cannot write zcode config: %s\n", path)
			return 1
		}
		fmt.printf("Created %s\n", path)
		return 0
	}

	data, ok := read_client_config(path)
	if !ok {
		fmt.eprintf("aubade setup: cannot read zcode config: %s\n", path)
		return 1
	}
	unit := config.detect_indent(data)
	nl := config.detect_newline(data)
	entry := render_zcode_entry(binary, args, unit, nl, context.temp_allocator)
	out, action, eok := config.edit_upsert_member(data, {"mcp", "servers"}, "aubade", entry, context.temp_allocator)
	if !eok {
		fmt.eprintf("aubade setup: cannot parse zcode config: %s\n", path)
		return 1
	}
	if action == .Unchanged {
		fmt.println("Aubade is already configured in zcode.")
		return 0
	}
	if !edited_client_config_parses(out) {
		fmt.eprintf("aubade setup: refusing to write %s: the edit would leave invalid JSON — fix the file by hand first\n", path)
		return 1
	}
	if !write_client_config(path, out) {
		fmt.eprintf("aubade setup: cannot write zcode config: %s\n", path)
		return 1
	}
	if action == .Inserted {
		fmt.printf("Added aubade MCP server to %s\n", path)
	} else {
		fmt.printf("Updated aubade MCP server in %s\n", path)
	}
	return 0
}

// render_zcode_entry renders the aubade server object as it is spliced into
// an existing config: members at four indent units, closing at three
// (mcp=1, servers=2, aubade=3), the args array inline. `nl` is the file's
// line separator, so the block matches a CRLF config's convention.
render_zcode_entry :: proc(binary: string, args: []string, unit, nl: string, a := context.allocator) -> string {
	quoted_binary := config.json_quote(binary, context.temp_allocator)
	command := config.render_inline_array(args, context.temp_allocator)
	fragments := make([]string, 3, context.temp_allocator)
	fragments[0] = "\"type\": \"stdio\""
	fragments[1] = strings.concatenate({"\"command\": ", quoted_binary}, context.temp_allocator)
	fragments[2] = strings.concatenate({"\"args\": ", command}, context.temp_allocator)
	return config.render_multiline_object(
		fragments,
		config.indent_repeat(unit, 4, a),
		config.indent_repeat(unit, 3, a),
		nl,
		a,
	)
}

// render_fresh_zcode_config renders a complete config.json the way the
// fresh-file writer does: four-space indentation, the args array one
// element per line, trailing newline.
render_fresh_zcode_config :: proc(binary: string, args: []string, a := context.allocator) -> string {
	quoted_binary := config.json_quote(binary, context.temp_allocator)
	arg_lines := make([dynamic]string, 0, len(args), context.temp_allocator)
	for arg in args {
		append(&arg_lines, strings.concatenate({"        ", config.json_quote(arg, context.temp_allocator)}, context.temp_allocator))
	}
	args_joined := config.join_strings(arg_lines[:], ",\n", context.temp_allocator)
	return strings.concatenate({
		"{\n    \"mcp\": {\n        \"servers\": {\n            \"aubade\": {\n                \"type\": \"stdio\",\n                \"command\": ",
		quoted_binary,
		",\n                \"args\": [\n",
		args_joined,
		"\n                ]\n            }\n        }\n    }\n}\n",
	}, a)
}

// ensure_zcode_agents maintains the aubade instruction block in the ZCode
// user instruction file. Returns an exit code and prints its own messages.
ensure_zcode_agents :: proc(path: string) -> int {
	existing := ""
	action := ""
	if !os.exists(path) {
		action = "created"
	} else {
		// A read failure on an existing file refuses rather than falling
		// back to the created path: the atomic write needs only directory
		// permission and would replace the unreadable file's content.
		data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
		if rerr != nil {
			fmt.eprintf("aubade setup: cannot read zcode AGENTS.md: %s\n", path)
			return 1
		}
		if len(data) > MAX_CLIENT_CONFIG_BYTES {
			fmt.eprintf("aubade setup: zcode AGENTS.md is implausibly large: %s\n", path)
			return 1
		}
		existing = string(data)
	}

	merged, changed := merge_agent_instructions(existing)
	if changed {
		if !write_client_config(path, transmute([]u8)merged) {
			fmt.eprintf("aubade setup: cannot write zcode AGENTS.md: %s\n", path)
			return 1
		}
		if action == "" {
			action = "updated"
		}
	}
	switch action {
	case "created":
		fmt.printf("Added aubade instructions to %s\n", path)
	case "updated":
		fmt.printf("Updated aubade instructions in %s\n", path)
	case:
	}
	return 0
}

// merge_agent_instructions returns the content with the aubade block in its
// current form: an existing block is replaced in place (snippet updates
// propagate on re-run), content outside the markers is preserved, and
// without markers the block is appended. changed reports a difference.
merge_agent_instructions :: proc(existing: string) -> (string, bool) {
	block := strings.concatenate(
		{ZCODE_AGENTS_BEGIN, "\n", ZCODE_AGENTS_INSTRUCTION, "\n", ZCODE_AGENTS_END, "\n"},
		context.temp_allocator,
	)

	begin := strings.index(existing, ZCODE_AGENTS_BEGIN)
	if begin < 0 {
		base := existing
		if base != "" {
			if !strings.has_suffix(base, "\n") {
				base = strings.concatenate({base, "\n"}, context.temp_allocator)
			}
			base = strings.concatenate({base, "\n"}, context.temp_allocator)
		}
		merged := strings.concatenate({base, block}, context.temp_allocator)
		return merged, merged != existing
	}

	after_begin := begin + len(ZCODE_AGENTS_BEGIN)
	if end_rel := strings.index(existing[after_begin:], ZCODE_AGENTS_END); end_rel >= 0 {
		end := after_begin + end_rel + len(ZCODE_AGENTS_END)
		// The block carries its own trailing newline; swallow the one that
		// belonged to the replaced block.
		if end < len(existing) && existing[end] == '\n' {
			end += 1
		}
		merged := strings.concatenate({existing[:begin], block, existing[end:]}, context.temp_allocator)
		return merged, merged != existing
	}

	// Begin marker without an end marker (hand-edited away): rebuild the
	// block from its start position.
	merged := strings.concatenate({existing[:begin], block}, context.temp_allocator)
	return merged, merged != existing
}

// --- claudecode / codex ------------------------------------------------------

claude_code_applicable :: proc() -> bool {
	res, ok := run_capture({"claude", "--version"})
	return ok && res.code == 0 && strings.contains(res.stdout, "Claude")
}

// aubade_child_tail is the registered child command's argv after the
// binary — the `mcp` subcommand, the client's context flag when it has
// one, and the cwd project selection. Every registration spells the
// child through this one proc.
aubade_child_tail :: proc(context_name: string, a := context.allocator) -> []string {
	tail := make([dynamic]string, 0, 4, a)
	append(&tail, "mcp")
	if context_name != "" {
		append(&tail, "--context", context_name)
	}
	append(&tail, "--project-from-cwd")
	return tail[:]
}

// `claude mcp add` stores everything after "--" verbatim as the server
// command: the resolved aubade binary leads it and "mcp" is its subcommand —
// a bare "mcp" there registers a nonexistent command. The context flag is
// two elements, the space-separated spelling the MCP ecosystem's configs
// standardize on and the CLI parses.
claude_mcp_add_args :: proc(binary: string, a: mem.Allocator) -> []string {
	args: [dynamic]string = make([dynamic]string, 0, 12, a)
	append(&args, "claude", "mcp", "add", "--scope", "user", "aubade", "--", binary)
	for v in aubade_child_tail("claudecode", a) {
		append(&args, v)
	}
	return args[:]
}

setup_claude_code :: proc() -> int {
	if !claude_code_applicable() {
		fmt.eprintln("aubade setup: client \"claudecode\" is not applicable (not found or not functional)")
		return 1
	}
	binary := resolve_aubade_binary()
	res, ok := run_capture(claude_mcp_add_args(binary, context.temp_allocator))
	if !ok || res.code != 0 {
		print_capture_failure("setup", "mcp add", "claude", res, ok)
		return 1
	}
	fmt.println("\nIMPORTANT: We additionally recommend setting up hooks for Claude Code to ensure the best experience.")
	fmt.println("   Run 'aubade hook --help' for available hook commands and add them to your Claude Code MCP configuration.")
	return 0
}

codex_applicable :: proc() -> bool {
	res, ok := run_capture({"codex", "--version"})
	return ok && res.code == 0 && strings.contains(res.stdout, "codex-cli")
}

// `codex mcp add` stores everything after "--" verbatim as the server
// command: the resolved aubade binary leads it and "mcp" is its subcommand —
// a bare "mcp" there registers a nonexistent command. The context flag is
// two elements, the space-separated spelling the MCP ecosystem's configs
// standardize on and the CLI parses.
codex_mcp_add_args :: proc(binary: string, a: mem.Allocator) -> []string {
	args: [dynamic]string = make([dynamic]string, 0, 10, a)
	append(&args, "codex", "mcp", "add", "aubade", "--", binary)
	for v in aubade_child_tail("codex", a) {
		append(&args, v)
	}
	return args[:]
}

setup_codex :: proc() -> int {
	if !codex_applicable() {
		fmt.eprintln("aubade setup: client \"codex\" is not applicable (not found or not functional)")
		return 1
	}
	binary := resolve_aubade_binary()
	res, ok := run_capture(codex_mcp_add_args(binary, context.temp_allocator))
	if !ok || res.code != 0 {
		print_capture_failure("setup", "mcp add", "codex", res, ok)
		return 1
	}
	return 0
}

// --- qwen ----------------------------------------------------------------------

qwen_applicable :: proc() -> bool {
	res, ok := run_capture({"qwen", "--version"})
	return ok && res.code == 0
}

// `qwen mcp add` stores everything after "--" verbatim as the server
// command (user scope by default, ~/.qwen/settings.json): the resolved
// aubade binary leads it and "mcp" is its subcommand. Qwen Code ships
// its own file/shell tools (read_file/write_file/edit/run_shell_command),
// so the `qwen` context strips the duplicated aubade tools.
qwen_mcp_add_args :: proc(binary: string, a: mem.Allocator) -> []string {
	args: [dynamic]string = make([dynamic]string, 0, 10, a)
	append(&args, "qwen", "mcp", "add", "aubade", "--", binary)
	for v in aubade_child_tail("qwen", a) {
		append(&args, v)
	}
	return args[:]
}

setup_qwen :: proc() -> int {
	if !qwen_applicable() {
		fmt.eprintln("aubade setup: client \"qwen\" is not applicable (not found or not functional)")
		return 1
	}
	binary := resolve_aubade_binary()
	res, ok := run_capture(qwen_mcp_add_args(binary, context.temp_allocator))
	if !ok || res.code != 0 {
		print_capture_failure("setup", "mcp add", "qwen", res, ok)
		return 1
	}
	return 0
}

// print_capture_failure reports a failed capture run against a client's
// mcp command: `cmd` is the aubade command name, `op` the operation phrase
// ("mcp add" at setup, "mcp command" at uninstall), `client` the binary
// name the command ran as.
print_capture_failure :: proc(cmd: string, op: string, client: string, res: Capture_Result, ok: bool) {
	if !ok {
		fmt.eprintf("aubade %s: %s %s failed to run\n", cmd, client, op)
		return
	}
	if res.stderr != "" {
		fmt.eprintf("aubade %s: %s %s failed (exit %d): %s\n", cmd, client, op, res.code, res.stderr)
	} else if res.stdout != "" {
		fmt.eprintf("aubade %s: %s %s failed (exit %d): %s\n", cmd, client, op, res.code, res.stdout)
	} else {
		fmt.eprintf("aubade %s: %s %s failed with exit code %d\n", cmd, client, op, res.code)
	}
}

// --- opencode -----------------------------------------------------------------

opencode_applicable :: proc() -> bool {
	res, ok := run_capture({"opencode", "--version"})
	return ok && res.code == 0
}

setup_opencode :: proc() -> int {
	if !opencode_applicable() {
		fmt.eprintln("aubade setup: client \"opencode\" is not applicable (not found or not functional)")
		return 1
	}
	home := user_home_dir()
	if home == "" {
		fmt.eprintln("aubade setup: could not determine home directory for opencode config")
		return 1
	}
	return setup_opencode_into(home)
}

// setup_opencode_into writes the aubade entry into ~/.config/opencode/
// opencode.json (type=local, command as array), preserving an existing
// file's formatting.
setup_opencode_into :: proc(home_dir: string) -> int {
	config_dir, _ := filepath.join([]string{home_dir, ".config", "opencode"}, context.temp_allocator)
	if err := os.make_directory_all(config_dir); err != nil && !os.is_directory(config_dir) {
		fmt.eprintf("aubade setup: cannot create opencode config dir: %s\n", config_dir)
		return 1
	}

	path, _ := filepath.join([]string{config_dir, "opencode.json"}, context.temp_allocator)
	binary := resolve_aubade_binary()

	if !os.exists(path) {
		rendered := render_fresh_opencode_config(binary, context.temp_allocator)
		if !write_client_config(path, transmute([]u8)rendered) {
			fmt.eprintf("aubade setup: cannot write opencode config: %s\n", path)
			return 1
		}
		fmt.printf("Created %s\n", path)
		return 0
	}

	data, ok := read_client_config(path)
	if !ok {
		fmt.eprintf("aubade setup: cannot read opencode config: %s\n", path)
		return 1
	}
	unit := config.detect_indent(data)
	nl := config.detect_newline(data)
	argv := make([dynamic]string, 0, 5, context.temp_allocator)
	append(&argv, binary)
	for v in aubade_child_tail("", context.temp_allocator) {
		append(&argv, v)
	}
	command := config.render_inline_array(argv[:], context.temp_allocator)
	entry := render_opencode_entry(command, unit, nl, context.temp_allocator)
	out, action, eok := config.edit_upsert_member(data, {"mcp"}, "aubade", entry, context.temp_allocator)
	if !eok {
		fmt.eprintf("aubade setup: cannot parse opencode config: %s\n", path)
		return 1
	}
	if action == .Unchanged {
		fmt.println("Aubade is already configured in opencode.")
		return 0
	}
	if !edited_client_config_parses(out) {
		fmt.eprintf("aubade setup: refusing to write %s: the edit would leave invalid JSON — fix the file by hand first\n", path)
		return 1
	}
	if !write_client_config(path, out) {
		fmt.eprintf("aubade setup: cannot write opencode config: %s\n", path)
		return 1
	}
	if action == .Inserted {
		fmt.printf("Added aubade MCP server to %s\n", path)
	} else {
		fmt.printf("Updated aubade MCP server in %s\n", path)
	}
	return 0
}

// render_opencode_entry renders the aubade server object as it is spliced
// into an existing config: members at three indent units, closing at two
// (mcp=1, aubade=2), the command array inline. `nl` is the file's line
// separator, so the block matches a CRLF config's convention.
render_opencode_entry :: proc(command_array: string, unit, nl: string, a := context.allocator) -> string {
	fragments := make([]string, 2, context.temp_allocator)
	fragments[0] = "\"type\": \"local\""
	fragments[1] = strings.concatenate({"\"command\": ", command_array}, context.temp_allocator)
	return config.render_multiline_object(
		fragments,
		config.indent_repeat(unit, 3, a),
		config.indent_repeat(unit, 2, a),
		nl,
		a,
	)
}

render_fresh_opencode_config :: proc(binary: string, a := context.allocator) -> string {
	return strings.concatenate({
		"{\n    \"$schema\": \"https://opencode.ai/config.json\",\n    \"mcp\": {\n        \"aubade\": {\n            \"type\": \"local\",\n            \"command\": [\n                ",
		config.json_quote(binary, context.temp_allocator),
		",\n                \"mcp\",\n                \"--project-from-cwd\"\n            ]\n        }\n    }\n}\n",
	}, a)
}
