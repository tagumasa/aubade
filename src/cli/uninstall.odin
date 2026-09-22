// aubade uninstall <client>: the inverse of setup — remove Aubade's MCP
// registration from a client. The file editors (zcode config.json +
// AGENTS.md, opencode opencode.json) splice the entry out through the
// format-preserving editor; claudecode and codex shell out to their own
// `mcp remove` commands, the same channels setup registers through.
package cli

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "src:config"

run_uninstall :: proc(args: []string, g: ^Globals, version: string) -> int {
	return run_client_cmd("uninstall", args, g, client_uninstall_op)
}

// --- zcode ---------------------------------------------------------------------

uninstall_zcode :: proc() -> int {
	home := user_home_dir()
	if home == "" {
		fmt.eprintln("aubade uninstall: could not determine home directory for zcode config")
		return 1
	}
	return uninstall_zcode_into(home)
}

// uninstall_zcode_into removes both halves of the zcode setup, parameterized
// by the home directory so tests can drive it against a temp directory: the
// mcp.servers.aubade member from config.json and the managed instruction
// block from AGENTS.md (the file itself goes away when the block was its
// only content). Hollow parent objects ("servers": {}) stay in place — the
// editor's removal contract is one member, and empty braces are harmless.
uninstall_zcode_into :: proc(home_dir: string) -> int {
	config_dir, _ := filepath.join([]string{home_dir, ".zcode", "cli"}, context.temp_allocator)
	config_path, _ := filepath.join([]string{config_dir, "config.json"}, context.temp_allocator)

	removed_server := false
	if os.exists(config_path) {
		data, ok := read_client_config(config_path)
		if !ok {
			fmt.eprintf("aubade uninstall: cannot read zcode config: %s\n", config_path)
			return 1
		}
		out, removed, eok := config.edit_remove_member(data, {"mcp", "servers"}, "aubade", context.temp_allocator)
		if !eok {
			fmt.eprintf("aubade uninstall: cannot parse zcode config: %s\n", config_path)
			return 1
		}
		if removed {
			if !edited_client_config_parses(out) {
				fmt.eprintf("aubade uninstall: refusing to write %s: removing the aubade entry would leave invalid JSON — remove it by hand\n", config_path)
				return 1
			}
			if !write_client_config(config_path, out) {
				fmt.eprintf("aubade uninstall: cannot write zcode config: %s\n", config_path)
				return 1
			}
			removed_server = true
		}
	}

	agents_path, _ := filepath.join([]string{home_dir, ".zcode", "AGENTS.md"}, context.temp_allocator)
	removed_agents := false
	if os.exists(agents_path) {
		data, ok := read_client_config(agents_path)
		if !ok {
			fmt.eprintf("aubade uninstall: cannot read zcode AGENTS.md: %s\n", agents_path)
			return 1
		}
		removed, wrote_ok := remove_agent_instructions(agents_path, string(data))
		if !wrote_ok {
			return 1
		}
		removed_agents = removed
	}

	if removed_server {
		fmt.println("Removed aubade MCP server from zcode.")
	}
	if removed_agents {
		fmt.printf("Removed aubade instructions from %s\n", agents_path)
	}
	if !removed_server && !removed_agents {
		fmt.println("Aubade is not configured in zcode.")
	}
	return 0
}

// remove_agent_instructions cuts the managed block (begin..end markers,
// trailing newline, and the blank line setup parked in front of it) out of
// the AGENTS.md content and persists the result: the file is deleted when
// nothing but the block was there, rewritten otherwise. `removed` reports
// whether a block was found; `wrote_ok` reports whether the persistence
// (write or delete) succeeded — a removed-but-failed removal is an error.
remove_agent_instructions :: proc(path: string, content: string) -> (removed: bool, wrote_ok: bool) {
	begin := strings.index(content, ZCODE_AGENTS_BEGIN)
	if begin < 0 {
		return false, true
	}
	end := len(content)
	if rel := strings.index(content[begin:], ZCODE_AGENTS_END); rel >= 0 {
		end = begin + rel + len(ZCODE_AGENTS_END)
	}
	// The block carries its own trailing newline; swallow the one that
	// belonged to it.
	if end < len(content) && content[end] == '\n' {
		end += 1
	}
	// merge_agent_instructions parked the block after a blank line when it
	// appended to existing content; take that line back so the remaining
	// text does not gain a stray gap.
	cut := begin
	if cut >= 2 && content[cut-1] == '\n' && content[cut-2] == '\n' {
		cut -= 1
	}
	out := strings.concatenate({content[:cut], content[end:]}, context.temp_allocator)

	if strings.trim_space(out) == "" {
		if err := os.remove(path); err != nil {
			fmt.eprintf("aubade uninstall: cannot remove %s\n", path)
			return true, false
		}
	} else if !write_client_config(path, transmute([]u8)out) {
		fmt.eprintf("aubade uninstall: cannot write zcode AGENTS.md: %s\n", path)
		return true, false
	}
	return true, true
}

// --- opencode ------------------------------------------------------------------

uninstall_opencode :: proc() -> int {
	home := user_home_dir()
	if home == "" {
		fmt.eprintln("aubade uninstall: could not determine home directory for opencode config")
		return 1
	}
	return uninstall_opencode_into(home)
}

// uninstall_opencode_into removes the mcp.aubade member from
// ~/.config/opencode/opencode.json, parameterized by home for tests. An
// absent file or absent member is "not configured"; a file that cannot be
// read or parsed fails the command.
uninstall_opencode_into :: proc(home_dir: string) -> int {
	path, _ := filepath.join([]string{home_dir, ".config", "opencode", "opencode.json"}, context.temp_allocator)
	if !os.exists(path) {
		fmt.println("Aubade is not configured in opencode.")
		return 0
	}
	data, ok := read_client_config(path)
	if !ok {
		fmt.eprintf("aubade uninstall: cannot read opencode config: %s\n", path)
		return 1
	}
	out, removed, eok := config.edit_remove_member(data, {"mcp"}, "aubade", context.temp_allocator)
	if !eok {
		fmt.eprintf("aubade uninstall: cannot parse opencode config: %s\n", path)
		return 1
	}
	if !removed {
		fmt.println("Aubade is not configured in opencode.")
		return 0
	}
	if !edited_client_config_parses(out) {
		fmt.eprintf("aubade uninstall: refusing to write %s: removing the aubade entry would leave invalid JSON — remove it by hand\n", path)
		return 1
	}
	if !write_client_config(path, out) {
		fmt.eprintf("aubade uninstall: cannot write opencode config: %s\n", path)
		return 1
	}
	fmt.println("Removed aubade MCP server from opencode.")
	return 0
}

// --- claudecode / codex ----------------------------------------------------------

// mcp_list_has_aubade reports whether a client's `mcp list` output names the
// aubade server. The listing format differs per client (and per version), so
// the check scans for the registered name as a delimited token — preceded by
// line start or whitespace/colon, followed by whitespace/colon or end of
// input — so a similarly-named server ("aubade-foo") cannot trigger a
// removal that would only fail.
mcp_list_has_aubade :: proc(list_stdout: string) -> bool {
	needle := "aubade"
	from := 0
	for from + len(needle) <= len(list_stdout) {
		rel := strings.index(list_stdout[from:], needle)
		if rel < 0 {
			return false
		}
		at := from + rel
		before := at == 0 ||
			list_stdout[at - 1] == ' ' || list_stdout[at - 1] == '\t' ||
			list_stdout[at - 1] == ':' || list_stdout[at - 1] == '\n' || list_stdout[at - 1] == '\r'
		end := at + len(needle)
		after := end == len(list_stdout) ||
			list_stdout[end] == ' ' || list_stdout[end] == '\t' ||
			list_stdout[end] == ':' || list_stdout[end] == '\n' || list_stdout[end] == '\r'
		if before && after {
			return true
		}
		from = at + 1
	}
	return false
}

claude_mcp_remove_args :: proc(a: mem.Allocator) -> []string {
	args: [dynamic]string = make([dynamic]string, 0, 6, a)
	append(&args, "claude", "mcp", "remove", "--scope", "user", "aubade")
	return args[:]
}

codex_mcp_remove_args :: proc(a: mem.Allocator) -> []string {
	args: [dynamic]string = make([dynamic]string, 0, 4, a)
	append(&args, "codex", "mcp", "remove", "aubade")
	return args[:]
}

// uninstall_mcp_client drives the shell-based removal shared by
// claudecode, codex, and qwen: verify the client is functional, confirm
// aubade is registered through its `mcp list`, then run its `mcp remove`.
// `client` names the client in messages; `bin` is the command it runs as
// (claudecode registers through the `claude` binary).
uninstall_mcp_client :: proc(
	client:     string,
	bin:        string,
	applicable: proc() -> bool,
	remove_args: proc(a: mem.Allocator) -> []string,
) -> int {
	if !applicable() {
		fmt.eprintf("aubade uninstall: client %q is not applicable (not found or not functional)\n", client)
		return 1
	}
	list, lok := run_capture({bin, "mcp", "list"})
	if !lok || list.code != 0 {
		print_capture_failure("uninstall", "mcp command", bin, list, lok)
		return 1
	}
	if !mcp_list_has_aubade(list.stdout) {
		fmt.printf("Aubade is not configured in %s.\n", client)
		return 0
	}
	res, ok := run_capture(remove_args(context.temp_allocator))
	if !ok || res.code != 0 {
		print_capture_failure("uninstall", "mcp command", bin, res, ok)
		return 1
	}
	fmt.printf("Removed aubade MCP server from %s.\n", client)
	return 0
}

uninstall_claude_code :: proc() -> int {
	return uninstall_mcp_client("claudecode", "claude", claude_code_applicable, claude_mcp_remove_args)
}

uninstall_codex :: proc() -> int {
	return uninstall_mcp_client("codex", "codex", codex_applicable, codex_mcp_remove_args)
}

qwen_mcp_remove_args :: proc(a: mem.Allocator) -> []string {
	args: [dynamic]string = make([dynamic]string, 0, 4, a)
	append(&args, "qwen", "mcp", "remove", "aubade")
	return args[:]
}

uninstall_qwen :: proc() -> int {
	return uninstall_mcp_client("qwen", "qwen", qwen_applicable, qwen_mcp_remove_args)
}
