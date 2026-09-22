// Session hooks for MCP clients (activate / cleanup / remind /
// auto-approve): each reads a JSON payload from stdin, consults per-session
// state under $AUBADE_HOME/hook_data/<session_id>, and returns the JSON to
// print on stdout (empty = print nothing). Byte-compatible with the
// reference implementation's output — key order follows its sorted-map
// marshalling, codex omits additionalContext, and every payload ends with
// a single newline. Timestamps are wall-clock seconds persisted across
// processes (injected as now_unix so tests stay deterministic).
package hooks

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "src:config"
import "src:jsonutil"
import "src:platform"
import "src:safety"
import "src:util"

Hook_Client :: enum {
	Claude_Code,
	VSCode,
	Codex,
}

Hook_Outcome :: struct {
	stdout: string, // "" = print nothing; includes the trailing newline
	err:    string, // "" = success; otherwise printed to stderr, exit 1
}

// HOOK_CLIENT_NAMES is the one spelling table for Hook_Client: the
// parser and the usage text derive from it.
HOOK_CLIENT_NAMES :: []string{"claudecode", "vscode", "codex"}

// parse_hook_client validates a client string against the table.
parse_hook_client :: proc(s: string) -> (Hook_Client, bool) {
	trimmed := strings.trim_space(s)
	names := HOOK_CLIENT_NAMES
	for c in Hook_Client {
		if util.ascii_equal_ci(trimmed, names[cast(int)c]) {
			return c, true
		}
	}
	return .Claude_Code, false
}

// hook_client_string renders one client spelling from the same table.
hook_client_string :: proc(c: Hook_Client) -> string {
	names := HOOK_CLIENT_NAMES
	return names[cast(int)c]
}

// --- input parsing -----------------------------------------------------------

Hook_Input :: struct {
	client:          Hook_Client,
	value:           json.Value,
	session_id:      string,
	persistence_dir: string,
	tool_name:       string, // as the client reports it (MCP names stay mangled)
	tool_name_plain: string, // demangled MCP name (== tool_name when not mangled)
	permission_mode: string,
	tool_input:      json.Value,
	file_path:       string,
}

// parse_hook reads the shared payload: session id (validated) and the
// persistence directory. The pre-tool-use fields are filled separately by
// parse_pre_tool_use.
parse_hook :: proc(client: Hook_Client, raw: []u8, a := context.allocator) -> (input: Hook_Input, err: string) {
	// Depth/encoding guard: the payload comes from the MCP client host
	// over stdin; deep nesting must read as a parse error, not a crash.
	if !util.json_sanity_ok(raw) {
		return input, "parsing hook input JSON"
	}
	value, perr := json.parse_bytes(raw, spec = .JSON, parse_integers = true, allocator = a)
	if perr != nil || value == nil {
		// The parser reports a typed failure vocabulary (json.Error), no
		// offset: name the kind so the operator can tell a truncated
		// payload from a structural one; the None kind means the value
		// itself came back empty.
		if perr != .None {
			return input, fmt.aprintf("parsing hook input JSON: %v", perr, allocator = context.temp_allocator)
		}
		return input, "parsing hook input JSON"
	}
	input.client = client
	input.value = value

	session_id := coalesce_string(value, {"session_id", "sessionId"})
	if session_id == "" {
		return input, "session ID is required in the hook input data"
	}
	if ok, reason := safety.pathguard_validate_session_id(session_id); !ok {
		return input, strings.concatenate(
			{"invalid session ID: ", reason},
			context.temp_allocator,
		)
	}
	input.session_id = session_id

	home := platform.aubade_home(a)
	dir, _ := filepath.join([]string{home, "hook_data", session_id}, a)
	input.persistence_dir = dir
	return input, ""
}

// parse_pre_tool_use fills tool_name / permission_mode / tool_input /
// file_path.
parse_pre_tool_use :: proc(input: ^Hook_Input) -> (err: string) {
	tool_name := coalesce_string(input.value, {"tool_name", "toolName"})
	input.tool_name = strings.to_lower(
		strings.trim_space(tool_name),
		context.temp_allocator,
	)
	if input.tool_name == "" {
		return "tool name is required in the hook input data"
	}
	input.tool_name_plain = demangle_mcp_name(input.tool_name)
	input.permission_mode = strings.trim_space(
		coalesce_string(input.value, {"permission_mode", "permissionMode"}),
	)

	input.tool_input = nil
	if v1, ok1 := json_obj_get(input.value, "tool_input"); ok1 {
		input.tool_input = v1
	} else if v2, ok2 := json_obj_get(input.value, "toolInput"); ok2 {
		input.tool_input = v2
	}
	input.file_path = coalesce_string(input.tool_input, {"file_path", "filePath"})
	return ""
}

// json_obj_get returns the member only when it is an object —
// jsonutil.obj_get plus the object guard.
json_obj_get :: proc(v: json.Value, key: string) -> (json.Value, bool) {
	member, ok := jsonutil.obj_get(v, key)
	if !ok {
		return nil, false
	}
	if _, is_object := jsonutil.as_object(member); !is_object {
		return nil, false
	}
	return member, true
}

// coalesce_string returns the first non-empty string member among keys
// (non-zero numbers render decimally — integral values never render as
// floats).
coalesce_string :: proc(v: json.Value, keys: []string) -> string {
	if v == nil {
		return ""
	}
	obj: json.Object
	#partial switch m in v {
	case json.Object:
		obj = m
	case:
		return ""
	}
	for k in keys {
		member, ok := obj[k]
		if !ok {
			continue
		}
		#partial switch s in member {
		case json.String:
			if string(s) != "" {
				return string(s)
			}
		case json.Integer:
			if i64(s) != 0 {
				return fmt.aprintf("%d", i64(s), allocator = context.temp_allocator)
			}
		case:
		}
	}
	return ""
}

// --- tool classification -----------------------------------------------------

// demangle_mcp_name strips a leading "mcp__<server>__" prefix, yielding
// the bare tool name ("mcp__aubade__file_search" -> "file_search").
// Claude Code and ZCode report MCP tools in that mangled form while their
// own built-ins arrive bare, so the equality classifiers compare against
// the demangled name; names that are not MCP-mangled (including a bare
// "mcp__x" with no server separator) return unchanged. The input is
// already normalized (lowercased, trimmed).
demangle_mcp_name :: proc(name: string) -> string {
	if !strings.has_prefix(name, "mcp__") {
		return name
	}
	rest := name[len("mcp__"):]
	sep := strings.index(rest, "__")
	if sep < 0 {
		return name
	}
	return rest[sep + 2:]
}

// is_aubade_symbolic_tool reports whether the (client-mangled) tool name
// is one of aubade's working tools: the name mentions aubade (the
// client's MCP server spelling; a foreign server's same-named tool must
// not match), and the demangled name is one of the injected symbolic
// names — the tools registry owns the classification, injected here
// because this package sits below the tools layer.
is_aubade_symbolic_tool :: proc(tool_name: string, names: Aubade_Tool_Names) -> bool {
	if !strings.contains(tool_name, "aubade") {
		return false
	}
	plain := demangle_mcp_name(tool_name)
	for name in names.symbolic {
		if plain == name {
			return true
		}
	}
	return false
}

// shell_command extracts the normalized command name from a shell-style
// tool_input ("git log -1" -> "git log", "rg x" -> "rg").
shell_command :: proc(tool_input: json.Value) -> string {
	if tool_input == nil {
		return ""
	}
	cmd := coalesce_string(tool_input, {"command", "cmd"})
	parts := strings.fields(cmd, context.temp_allocator)
	if len(parts) == 0 {
		return ""
	}
	base := filepath.base(parts[0])
	if base == "git" && len(parts) >= 2 {
		return strings.concatenate({"git ", parts[1]}, context.temp_allocator)
	}
	return base
}

is_grep_shell_command :: proc(cmd: string) -> bool {
	switch cmd {
	case "grep", "rg", "ack", "ag", "pt", "git grep":
		return true
	case:
		return false
	}
}

is_read_shell_command :: proc(cmd: string) -> bool {
	switch cmd {
	case "cat", "less", "more", "head", "tail", "bat", "batcat":
		return true
	case:
		return false
	}
}

READ_FILE_VERB_SUBSTRINGS :: []string{"read", "view", "open", "show"}

// Aubade_Tool_Names carries the canonical aubade tool names the Claude
// Code classifiers compare by equality, plus the registry-derived
// working-tool set is_aubade_symbolic_tool classifies against. The host
// layer owns the tools registry and injects the names (tools.tool_name,
// tools.symbolic_hook_names), keeping this package below the tools
// layer. "grep"/"read" in the branches below stay as literals: they are
// the client's own built-in names, not aubade's.
Aubade_Tool_Names :: struct {
	file_search: string,
	file_read:   string,
	symbolic:    []string, // owned by the injector
}

// is_grep_tool classifies a search-ish tool use. tool_name is the plain
// (demangled) name — see demangle_mcp_name: the .Claude_Code branch
// compares bare names, which both Claude Code's built-ins and demangled
// MCP tools present.
is_grep_tool :: proc(client: Hook_Client, tool_name: string, tool_input: json.Value, names: Aubade_Tool_Names) -> bool {
	#partial switch client {
	case .Claude_Code:
		return tool_name == "grep" || tool_name == names.file_search
	case .Codex:
		cmd := shell_command(tool_input)
		return cmd != "" && is_grep_shell_command(cmd)
	case:
		return strings.contains(tool_name, "grep")
	}
}

// is_read_file_tool classifies a file-read tool use; tool_name is the
// plain (demangled) name, as in is_grep_tool.
is_read_file_tool :: proc(client: Hook_Client, tool_name: string, tool_input: json.Value, names: Aubade_Tool_Names) -> bool {
	#partial switch client {
	case .Claude_Code:
		return tool_name == "read" || tool_name == names.file_read
	case .Codex:
		cmd := shell_command(tool_input)
		return cmd != "" && is_read_shell_command(cmd)
	case:
		if !strings.contains(tool_name, "file") {
			return false
		}
		for verb in READ_FILE_VERB_SUBSTRINGS {
			if strings.contains(tool_name, verb) {
				return true
			}
		}
		return false
	}
}

// is_code_file_extension ports the code-extension allowlist; files without
// an extension count as code.
is_code_file_extension :: proc(ext: string) -> bool {
	switch ext {
	case ".go", ".rs", ".py", ".js", ".ts", ".tsx", ".jsx", ".java", ".kt",
		".scala", ".c", ".cpp", ".cc", ".cxx", ".h", ".hpp", ".hxx", ".cs",
		".rb", ".php", ".swift", ".m", ".mm", ".dart", ".lua", ".r", ".R",
		".jl", ".ex", ".exs", ".erl", ".hs", ".ml", ".fs", ".fsx", ".clj",
		".cljs", ".cljc", ".elm", ".vim", ".zig", ".nim", ".v", ".sv", ".vh",
		".pl", ".pm", ".tcl", ".sql", ".sh", ".bash", ".zsh", ".fish", ".ps1",
		".gradle", ".groovy", ".proto", ".thrift", ".sol", ".move", ".cairo":
		return true
	case:
		return false
	}
}

is_read_code_file :: proc(file_path: string) -> bool {
	if file_path == "" {
		return false
	}
	ext := filepath.ext(file_path)
	return ext == "" || is_code_file_extension(ext)
}

// --- tool-use counter --------------------------------------------------------

COUNTER_FILE_NAME           :: "tool_use_counter.json"
READ_USES_THRESHOLD         :: 3
GREP_USES_THRESHOLD         :: 3
NON_SYMBOLIC_USES_THRESHOLD :: 4
READ_RESET_PERIOD_S         :: 1000
GREP_RESET_PERIOD_S         :: 1000
NON_SYMBOLIC_RESET_PERIOD_S :: 2000
MIN_DENY_INTERVAL_S         :: 120

Counter :: struct {
	n_read:    int,
	n_grep:    int,
	n_non_sym: int,

	last_grep:      i64,
	has_grep_ts:    bool,
	last_read:      i64,
	has_read_ts:    bool,
	last_non_sym:   i64,
	has_non_sym_ts: bool,
	last_deny:      i64,
	has_deny_ts:    bool,

	is_dirty: bool,
}

counter_path :: proc(dir: string, a := context.allocator) -> string {
	joined, _ := filepath.join([]string{dir, COUNTER_FILE_NAME}, a)
	return joined
}

counter_read_int :: proc(v: json.Value, key: string, out: ^i64) -> bool {
	if v == nil {
		return false
	}
	#partial switch m in v {
	case json.Object:
		if member, ok := m[key]; ok {
			#partial switch x in member {
			case json.Integer:
				out^ = i64(x)
				return true
			case:
			}
		}
	case:
	}
	return false
}

// load_counter reads the persisted counter; any error yields a fresh one.
load_counter :: proc(dir: string) -> Counter {
	c: Counter
	path := counter_path(dir, context.temp_allocator)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return c
	}
	value, perr := json.parse_bytes(data, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	if perr != nil || value == nil {
		return c
	}
	v := i64(0)
	if counter_read_int(value, "n_recent_read_file_uses", &v) {
		c.n_read = int(v)
	}
	if counter_read_int(value, "n_recent_grep_uses", &v) {
		c.n_grep = int(v)
	}
	if counter_read_int(value, "n_recent_non_symbolic_uses", &v) {
		c.n_non_sym = int(v)
	}
	if counter_read_int(value, "last_grep_use_timestamp", &v) {
		c.last_grep = v
		c.has_grep_ts = true
	}
	if counter_read_int(value, "last_read_file_use_timestamp", &v) {
		c.last_read = v
		c.has_read_ts = true
	}
	if counter_read_int(value, "last_non_symbolic_use_timestamp", &v) {
		c.last_non_sym = v
		c.has_non_sym_ts = true
	}
	if counter_read_int(value, "last_deny_timestamp", &v) {
		c.last_deny = v
		c.has_deny_ts = true
	}
	if c.n_read < 0 {
		c.n_read = 0
	}
	if c.n_grep < 0 {
		c.n_grep = 0
	}
	if c.n_non_sym < 0 {
		c.n_non_sym = 0
	}
	return c
}

// save_counter persists the counter atomically (write to <path>.tmp, then
// rename). Field order and omitempty are pinned so counter files written
// by earlier builds keep parsing.
save_counter :: proc(dir: string, c: ^Counter, a := context.allocator) {
	if err := os.make_directory_all(dir); err != nil && !os.is_directory(dir) {
		util.log_error("hook: failed to save tool use counter")
		return
	}
	// Every allocation honors the declared `a` (nothing here escapes the
	// proc, so the caller's lifetime governs all of it).
	buf := make([dynamic]u8, 0, 256, a)
	defer delete(buf)
	append(&buf, "{\"n_recent_read_file_uses\":")
	append(&buf, util.int_to_dec(c.n_read, a))
	append(&buf, ",\"n_recent_grep_uses\":")
	append(&buf, util.int_to_dec(c.n_grep, a))
	append(&buf, ",\"n_recent_non_symbolic_uses\":")
	append(&buf, util.int_to_dec(c.n_non_sym, a))
	if c.has_grep_ts {
		append(&buf, ",\"last_grep_use_timestamp\":")
		append(&buf, counter_i64_to_string(c.last_grep, a))
	}
	if c.has_read_ts {
		append(&buf, ",\"last_read_file_use_timestamp\":")
		append(&buf, counter_i64_to_string(c.last_read, a))
	}
	if c.has_non_sym_ts {
		append(&buf, ",\"last_non_symbolic_use_timestamp\":")
		append(&buf, counter_i64_to_string(c.last_non_sym, a))
	}
	if c.has_deny_ts {
		append(&buf, ",\"last_deny_timestamp\":")
		append(&buf, counter_i64_to_string(c.last_deny, a))
	}
	append(&buf, '}')

	path := counter_path(dir, a)
	tmp := strings.concatenate({path, ".tmp"}, a)
	f, err := os.open(tmp, {.Write, .Create, .Trunc}, os.Permissions{.Read_User, .Write_User})
	if err != nil {
		return
	}
	werr := platform.write_all(f, buf[:])
	os.close(f)
	if werr != nil || os.rename(tmp, path) != nil {
		os.remove(tmp)
	}
}

counter_i64_to_string :: proc(v: i64, a := context.temp_allocator) -> string {
	return fmt.aprintf("%d", v, allocator = a)
}

counter_too_many_reads :: proc(c: ^Counter) -> bool { return c.n_read >= READ_USES_THRESHOLD }
counter_too_many_greps :: proc(c: ^Counter) -> bool { return c.n_grep >= GREP_USES_THRESHOLD }
counter_too_many_non_symbolic :: proc(c: ^Counter) -> bool {
	return c.n_non_sym >= NON_SYMBOLIC_USES_THRESHOLD
}

// counter_hook_active reports whether the deny nudge may fire again
// (MIN_DENY_INTERVAL_S after the previous deny).
counter_hook_active :: proc(c: ^Counter, now_unix: i64) -> bool {
	if !c.has_deny_ts {
		return true
	}
	return now_unix - c.last_deny >= MIN_DENY_INTERVAL_S
}

counter_reset :: proc(c: ^Counter) {
	c.n_read = 0
	c.n_grep = 0
	c.n_non_sym = 0
	c.has_grep_ts = false
	c.has_read_ts = false
	c.has_non_sym_ts = false
	c.is_dirty = true
}

// counter_update folds the current tool use into the counters.
counter_update :: proc(c: ^Counter, input: ^Hook_Input, now_unix: i64, names: Aubade_Tool_Names) {
	if is_aubade_symbolic_tool(input.tool_name, names) {
		counter_reset(c)
		return
	}

	is_grep := is_grep_tool(input.client, input.tool_name_plain, input.tool_input, names)
	is_read := is_read_file_tool(input.client, input.tool_name_plain, input.tool_input, names) &&
		is_read_code_file(input.file_path)

	if is_grep {
		if c.has_grep_ts && now_unix - c.last_grep <= GREP_RESET_PERIOD_S {
			c.n_grep += 1
		} else {
			c.n_grep = 1
		}
		c.last_grep = now_unix
		c.has_grep_ts = true
		c.is_dirty = true
	}

	if is_read {
		if c.has_read_ts && now_unix - c.last_read <= READ_RESET_PERIOD_S {
			c.n_read += 1
		} else {
			c.n_read = 1
		}
		c.last_read = now_unix
		c.has_read_ts = true
		c.is_dirty = true
	}

	if is_grep || is_read {
		if c.has_non_sym_ts && now_unix - c.last_non_sym <= NON_SYMBOLIC_RESET_PERIOD_S {
			c.n_non_sym += 1
		} else {
			c.n_non_sym = 1
		}
		c.last_non_sym = now_unix
		c.has_non_sym_ts = true
	}
}

// --- output rendering --------------------------------------------------------

// Message texts are fixed strings — byte-frozen (golden-compared in
// tests). That byte-freeze includes
// the lowercase "mcp" in the deny contexts below: every other
// user-facing string spells "MCP", but these bytes are frozen and
// changing them diverges every golden comparison.
ACTIVATE_CONTEXT :: "**IMPORTANT**: Activate the current working directory as project using Aubade's tools if not already done. " +
	"If you haven't read Aubade Instructions Manual yet, do so. " +
	"Follow this instruction before doing anything else."

AUTO_APPROVE_REASON :: "Auto-approved: Aubade tool call while client is in acceptEdits mode."

GREP_DENY_REASON :: "Too many consecutive grep calls without using symbolic tools. " +
	"You can continue using grep now if needed, the counter was reset."
GREP_DENY_CONTEXT :: "You were using many grep calls recently. Consider using Aubade's symbolic " +
	"mcp tools instead for more code-centric search. You can continue using grep now if needed, the counter was reset."

READ_DENY_REASON :: "Too many consecutive read calls without using symbolic tools. " +
	"You can continue using read now if needed, the counter was reset."
READ_DENY_CONTEXT :: "You were using many read file calls recently. Consider using Aubade's symbolic " +
	"mcp tools instead for more targeted reads. You can continue using read now if needed, the counter was reset."

NON_SYMBOLIC_DENY_REASON :: "Too many consecutive non-symbolic tool calls (mixed grep and read). " +
	"You can continue using these tools now if needed, the counter was reset."
NON_SYMBOLIC_DENY_CONTEXT :: "You were alternating between grep and read file calls recently without using " +
	"Aubade's symbolic mcp tools. Consider using symbolic search and targeted symbol " +
	"reads instead for more code-centric exploration. You can continue using these tools " +
	"now if needed, the counter was reset."

// render_hook_specific wraps member fragments (already rendered
// "key":value strings, sorted by key) in {"hookSpecificOutput":{...}}
// plus a trailing newline.
render_hook_specific :: proc(fragments: []string, a := context.allocator) -> string {
	joined := config.join_strings(fragments, ",", context.temp_allocator)
	return strings.concatenate({
		"{\"hookSpecificOutput\":{", joined, "}}\n",
	}, a)
}

// render_pre_tool_output emits the PreToolUse response. additionalContext
// is always present for non-codex clients (empty string included).
render_pre_tool_output :: proc(
	client:            Hook_Client,
	decision:          string,
	reason:            string,
	additional_context: string,
	a:                 mem.Allocator,
) -> string {
	fragments := make([dynamic]string, 0, 4, context.temp_allocator)
	if client != .Codex {
		append(
			&fragments,
			strings.concatenate({
				"\"additionalContext\":", config.json_quote(additional_context, context.temp_allocator),
			}, context.temp_allocator),
		)
	}
	append(&fragments, "\"hookEventName\":\"PreToolUse\"")
	append(
		&fragments,
		strings.concatenate({"\"permissionDecision\":\"", decision, "\""}, context.temp_allocator),
	)
	append(
		&fragments,
		strings.concatenate({
			"\"permissionDecisionReason\":", config.json_quote(reason, context.temp_allocator),
		}, context.temp_allocator),
	)
	return render_hook_specific(fragments[:], a)
}

// --- entry points ------------------------------------------------------------

// run_activate handles the session-start hook: it nudges the agent to
// activate the project.
run_activate :: proc(client_name: string, raw: []u8, now_unix: i64, a := context.allocator) -> Hook_Outcome {
	client, ok := parse_hook_client(client_name)
	if !ok {
		return {err = fmt.aprintf("unknown hook client: %q", client_name, allocator = context.temp_allocator)}
	}
	_, err := parse_hook(client, raw, a)
	if err != "" {
		return {err = err}
	}

	fragments := make([dynamic]string, 0, 2, context.temp_allocator)
	if client != .Codex {
		append(
			&fragments,
			strings.concatenate({
				"\"additionalContext\":", config.json_quote(ACTIVATE_CONTEXT, context.temp_allocator),
			}, context.temp_allocator),
		)
	}
	append(&fragments, "\"hookEventName\":\"SessionStart\"")
	return {stdout = render_hook_specific(fragments[:], a)}
}

// run_cleanup handles the session-end hook: it removes the session's hook
// data directory.
run_cleanup :: proc(client_name: string, raw: []u8, now_unix: i64, a := context.allocator) -> Hook_Outcome {
	client, ok := parse_hook_client(client_name)
	if !ok {
		return {err = fmt.aprintf("unknown hook client: %q", client_name, allocator = context.temp_allocator)}
	}
	input, err := parse_hook(client, raw, a)
	if err != "" {
		return {err = err}
	}
	if rm_err := os.remove_all(input.persistence_dir); rm_err != nil {
		fmt.eprintf(
			"aubade hook: failed to clean up session hook data: dir=%s\n",
			input.persistence_dir,
		)
	}
	return {}
}

// run_auto_approve handles the pre-tool-use auto-approve hook: aubade
// symbolic tools in acceptEdits mode are allowed without prompting.
// The caller injects the canonical aubade tool names (Aubade_Tool_Names).
run_auto_approve :: proc(client_name: string, raw: []u8, now_unix: i64, names: Aubade_Tool_Names, a := context.allocator) -> Hook_Outcome {
	client, ok := parse_hook_client(client_name)
	if !ok {
		return {err = fmt.aprintf("unknown hook client: %q", client_name, allocator = context.temp_allocator)}
	}
	input, err := parse_hook(client, raw, a)
	if err != "" {
		return {err = err}
	}
	if perr := parse_pre_tool_use(&input); perr != "" {
		return {err = perr}
	}

	if !is_aubade_symbolic_tool(input.tool_name, names) || input.permission_mode != "acceptEdits" {
		return {}
	}
	out := render_pre_tool_output(client, "allow", AUTO_APPROVE_REASON, "", a)
	return {stdout = out}
}

// run_remind handles the pre-tool-use remind hook: consecutive grep/read
// usage without symbolic tools is denied (with a reset allowance). The
// caller injects the canonical aubade tool names (Aubade_Tool_Names).
run_remind :: proc(client_name: string, raw: []u8, now_unix: i64, names: Aubade_Tool_Names, a := context.allocator) -> Hook_Outcome {
	client, ok := parse_hook_client(client_name)
	if !ok {
		return {err = fmt.aprintf("unknown hook client: %q", client_name, allocator = context.temp_allocator)}
	}
	input, err := parse_hook(client, raw, a)
	if err != "" {
		return {err = err}
	}
	if perr := parse_pre_tool_use(&input); perr != "" {
		return {err = perr}
	}
	return remind_execute(&input, now_unix, names, a)
}

// remind_execute runs the counter update under the session's counter lock.
// On lock failure it proceeds unlocked (the nudge is advisory, never a
// hard dependency).
remind_execute :: proc(input: ^Hook_Input, now_unix: i64, names: Aubade_Tool_Names, a: mem.Allocator) -> Hook_Outcome {
	lock_path, _ := filepath.join([]string{input.persistence_dir, ".counter.lock"}, context.temp_allocator)
	// Try-acquire, never wait: the nudge is advisory, so a concurrent holder
	// means this run proceeds unlocked. The defer is deliberately scoped to
	// the whole procedure — a block-scoped `if lok { defer ... }` would
	// release at the closing brace, leaving the counter update unlocked.
	lock, lok := platform.file_lock_try_acquire(lock_path)
	defer if lok {
		platform.file_lock_release(&lock)
	}

	output := ""

	c := load_counter(input.persistence_dir)
	if !counter_hook_active(&c, now_unix) {
		return {}
	}

	counter_update(&c, input, now_unix, names)

	is_grep := is_grep_tool(input.client, input.tool_name_plain, input.tool_input, names)
	is_read := is_read_file_tool(input.client, input.tool_name_plain, input.tool_input, names)

	deny_kind := Deny_Kind.None
	if is_grep && counter_too_many_greps(&c) {
		deny_kind = .Grep
	} else if is_read && counter_too_many_reads(&c) {
		deny_kind = .Read
	} else if counter_too_many_greps(&c) || counter_too_many_reads(&c) || counter_too_many_non_symbolic(&c) {
		deny_kind = .Non_Symbolic
	}

	if deny_kind != .None {
		counter_reset(&c)
		c.last_deny = now_unix
		c.has_deny_ts = true
		c.is_dirty = true
	}

	if c.is_dirty {
		save_counter(input.persistence_dir, &c, context.temp_allocator)
	}

	switch deny_kind {
	case .Grep:
		output = render_pre_tool_output(input.client, "deny", GREP_DENY_REASON, GREP_DENY_CONTEXT, a)
	case .Read:
		output = render_pre_tool_output(input.client, "deny", READ_DENY_REASON, READ_DENY_CONTEXT, a)
	case .Non_Symbolic:
		output = render_pre_tool_output(
			input.client, "deny", NON_SYMBOLIC_DENY_REASON, NON_SYMBOLIC_DENY_CONTEXT, a,
		)
	case .None:
	}
	return {stdout = output}
}

Deny_Kind :: enum {
	None,
	Grep,
	Read,
	Non_Symbolic,
}
