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
import "core:slice"
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

// CODE_FILE_EXTENSIONS is the code-extension allowlist; files without an
// extension count as code.
CODE_FILE_EXTENSIONS :: []string{
	".go", ".rs", ".py", ".js", ".ts", ".tsx", ".jsx", ".java", ".kt",
	".scala", ".c", ".cpp", ".cc", ".cxx", ".h", ".hpp", ".hxx", ".cs",
	".rb", ".php", ".swift", ".m", ".mm", ".dart", ".lua", ".r", ".R",
	".jl", ".ex", ".exs", ".erl", ".hs", ".ml", ".fs", ".fsx", ".clj",
	".cljs", ".cljc", ".elm", ".vim", ".zig", ".nim", ".v", ".sv", ".vh",
	".pl", ".pm", ".tcl", ".sql", ".sh", ".bash", ".zsh", ".fish", ".ps1",
	".gradle", ".groovy", ".proto", ".thrift", ".sol", ".move", ".cairo",
}
is_code_file_extension :: proc(ext: string) -> bool {
	return slice.contains(CODE_FILE_EXTENSIONS, ext)
}

is_read_code_file :: proc(file_path: string) -> bool {
	if file_path == "" {
		return false
	}
	ext := filepath.ext(file_path)
	return ext == "" || is_code_file_extension(ext)
}

// --- tool-use counter --------------------------------------------------------

COUNTER_FILE_NAME   :: "tool_use_counter.json"
MIN_DENY_INTERVAL_S :: 120

Counter_Kind :: enum {
	Grep,
	Read,
	Non_Symbolic,
}

// One kind's live state: consecutive uses within the reset period plus the
// period's last stamp.
Kind_State :: struct {
	n:      int,
	last:   i64,
	has_ts: bool,
}

// Per-kind thresholds and reset periods.
READ_USES_THRESHOLD         :: 3
GREP_USES_THRESHOLD         :: 3
NON_SYMBOLIC_USES_THRESHOLD :: 4
READ_RESET_PERIOD_S         :: 1000
GREP_RESET_PERIOD_S         :: 1000
NON_SYMBOLIC_RESET_PERIOD_S :: 2000

COUNTER_THRESHOLDS :: [Counter_Kind]int{
	.Grep         = GREP_USES_THRESHOLD,
	.Read         = READ_USES_THRESHOLD,
	.Non_Symbolic = NON_SYMBOLIC_USES_THRESHOLD,
}

COUNTER_RESET_PERIODS :: [Counter_Kind]i64{
	.Grep         = GREP_RESET_PERIOD_S,
	.Read         = READ_RESET_PERIOD_S,
	.Non_Symbolic = NON_SYMBOLIC_RESET_PERIOD_S,
}

Counter_Wire_Field :: struct {
	kind: Counter_Kind,
	key:  string,
}

// The persisted counter's member order, pinned by earlier builds: the
// counts and the timestamps each carry their own fixed order (and the two
// orders differ).
COUNTER_COUNT_FIELDS :: []Counter_Wire_Field{
	{kind = .Read,         key = "n_recent_read_file_uses"},
	{kind = .Grep,         key = "n_recent_grep_uses"},
	{kind = .Non_Symbolic, key = "n_recent_non_symbolic_uses"},
}

COUNTER_TS_FIELDS :: []Counter_Wire_Field{
	{kind = .Grep,         key = "last_grep_use_timestamp"},
	{kind = .Read,         key = "last_read_file_use_timestamp"},
	{kind = .Non_Symbolic, key = "last_non_symbolic_use_timestamp"},
}

DENY_TS_KEY :: "last_deny_timestamp"

Counter :: struct {
	kinds:       [Counter_Kind]Kind_State,
	last_deny:   i64,
	has_deny_ts: bool,

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
	for row in COUNTER_COUNT_FIELDS {
		if counter_read_int(value, row.key, &v) {
			c.kinds[row.kind].n = int(v)
		}
	}
	for row in COUNTER_TS_FIELDS {
		if counter_read_int(value, row.key, &v) {
			c.kinds[row.kind].last = v
			c.kinds[row.kind].has_ts = true
		}
	}
	if counter_read_int(value, DENY_TS_KEY, &v) {
		c.last_deny = v
		c.has_deny_ts = true
	}
	for kind in Counter_Kind {
		if c.kinds[kind].n < 0 {
			c.kinds[kind].n = 0
		}
	}
	return c
}

// save_counter persists the counter atomically (write to <path>.tmp, then
// rename). The member order and omitempty come from the wire tables, so
// counter files written by earlier builds keep parsing byte-for-byte.
save_counter :: proc(dir: string, c: ^Counter, a := context.allocator) {
	if err := os.make_directory_all(dir); err != nil && !os.is_directory(dir) {
		util.log_error("hook: failed to save tool use counter")
		return
	}
	// Every allocation honors the declared `a` (nothing here escapes the
	// proc, so the caller's lifetime governs all of it).
	buf := make([dynamic]u8, 0, 256, a)
	defer delete(buf)
	append(&buf, "{\"")
	first := true
	for row in COUNTER_COUNT_FIELDS {
		if !first {
			append(&buf, ",\"")
		}
		first = false
		append(&buf, row.key)
		append(&buf, "\":")
		append(&buf, util.int_to_dec(c.kinds[row.kind].n, a))
	}
	for row in COUNTER_TS_FIELDS {
		if c.kinds[row.kind].has_ts {
			append(&buf, ",\"")
			append(&buf, row.key)
			append(&buf, "\":")
			append(&buf, counter_i64_to_string(c.kinds[row.kind].last, a))
		}
	}
	if c.has_deny_ts {
		append(&buf, ",\"")
		append(&buf, DENY_TS_KEY)
		append(&buf, "\":")
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

counter_over :: proc(c: ^Counter, kind: Counter_Kind) -> bool {
	thresholds := COUNTER_THRESHOLDS
	return c.kinds[kind].n >= thresholds[kind]
}

counter_too_many_reads :: proc(c: ^Counter) -> bool { return counter_over(c, .Read) }
counter_too_many_greps :: proc(c: ^Counter) -> bool { return counter_over(c, .Grep) }
counter_too_many_non_symbolic :: proc(c: ^Counter) -> bool {
	return counter_over(c, .Non_Symbolic)
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
	for kind in Counter_Kind {
		c.kinds[kind] = {}
	}
	c.is_dirty = true
}

// counter_bump folds one use of a kind into its state. It never marks the
// counter dirty: the non-symbolic counter only advances alongside a grep
// or read bump (which already did), so the caller states dirtiness.
counter_bump :: proc(c: ^Counter, kind: Counter_Kind, now_unix: i64) {
	periods := COUNTER_RESET_PERIODS
	st := &c.kinds[kind]
	if st.has_ts && now_unix - st.last <= periods[kind] {
		st.n += 1
	} else {
		st.n = 1
	}
	st.last = now_unix
	st.has_ts = true
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
		counter_bump(c, .Grep, now_unix)
		c.is_dirty = true
	}
	if is_read {
		counter_bump(c, .Read, now_unix)
		c.is_dirty = true
	}
	if is_grep || is_read {
		counter_bump(c, .Non_Symbolic, now_unix)
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
				"\"additionalContext\":", jsonutil.json_quote_bytes(additional_context, context.temp_allocator),
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
			"\"permissionDecisionReason\":", jsonutil.json_quote_bytes(reason, context.temp_allocator),
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
				"\"additionalContext\":", jsonutil.json_quote_bytes(ACTIVATE_CONTEXT, context.temp_allocator),
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

	msgs := DENY_MESSAGES
	if msgs[deny_kind].reason != "" {
		output = render_pre_tool_output(input.client, "deny", msgs[deny_kind].reason, msgs[deny_kind].detail, a)
	}
	return {stdout = output}
}

Deny_Kind :: enum {
	None,
	Grep,
	Read,
	Non_Symbolic,
}

Deny_Msg :: struct {
	reason: string,
	// `context` is a keyword in Odin; the field carries the deny output's
	// additionalContext member.
	detail: string,
}

// Deny output per kind; .None carries no message and renders nothing.
DENY_MESSAGES :: [Deny_Kind]Deny_Msg{
	.None         = {},
	.Grep         = {reason = GREP_DENY_REASON, detail = GREP_DENY_CONTEXT},
	.Read         = {reason = READ_DENY_REASON, detail = READ_DENY_CONTEXT},
	.Non_Symbolic = {reason = NON_SYMBOLIC_DENY_REASON, detail = NON_SYMBOLIC_DENY_CONTEXT},
}
