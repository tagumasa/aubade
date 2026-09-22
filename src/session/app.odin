// session: the child (MCP server) assembly. Owns the stdio MCP
// connection, the parent RPC client with heartbeat and respawn, the tool
// worker pool, and --in-process mode (channel transport to an in-process
// daemon). All state lives on App; no process globals.
package session

import "core:io"
import "core:mem"
import "core:strings"
import "core:os"
import "core:sync"
import "core:thread"
import "src:config"
import "src:daemon"
import "src:jsonrpc"
import "src:mcp"
import "src:platform"
import "src:rpc"
import "src:safety"
import "src:tools"

DEFAULT_TOOL_TIMEOUT_MS :: i64(config.DEFAULT_TOOL_TIMEOUT_S * 1000)
TOOL_WORKERS            :: 4
SPAWN_ATTEMPTS          :: 3
CONNECT_TIMEOUT_MS      :: i64(10000)
// After a failed reconnect round the heartbeat waits this long (monotonic)
// before trying again: GivenUp is a backoff state, not a terminal one — the
// daemon the child lost may come back at any time.
PARENT_RETRY_BACKOFF_MS :: i64(30_000)

Config :: struct {
	project_root:            string, // raw user value; normalized at startup
	home:                    string, // aubade home override ("" = resolve)
	contexts:                []string,
	modes:                   []string,
	is_in_process:           bool,
	tool_timeout_ms:         i64,
	hb_ping_ms:              i64,
	hb_timeout_ms:           i64,
	hb_grace_ms:             i64,
	hb_drain_ms:             i64,
	instructions:            string, // render-failure fallback (the served prompt is composed at startup)
	exe_path:                string, // self executable (daemon spawn); "" = resolve
	log_level:               string, // --log-level override; "" = the config key
	trace_lsp:               bool, // --trace-lsp-communication: LSP frames at debug level
	install_signals:         bool, // CLI entry only: latch SIGINT/SIGTERM onto the root token
}

default_config :: proc() -> Config {
	return {
		tool_timeout_ms = DEFAULT_TOOL_TIMEOUT_MS,
		hb_ping_ms      = daemon.DEFAULT_PING_MS,
		hb_timeout_ms   = daemon.DEFAULT_TIMEOUT_MS,
		hb_grace_ms     = daemon.DEFAULT_GRACE_MS,
		hb_drain_ms     = daemon.DEFAULT_DRAIN_MS,
		// The static manual is only the fallback for a failed startup
		// render; the served instructions come from the shared prompt
		// engine (the same one `prompt render` exercises hostlessly).
		instructions    = tools.ONBOARDING_DIRECTIVE + "\n\n" + tools.STANDALONE_INSTRUCTIONS_MANUAL,
	}
}

Parent_State :: enum {
	Disconnected,
	Live,
	GivenUp, // reconnect round failed; retrying after parent_retry_at; svc-dependent tools withdrawn
}

App :: struct {
	cfg:                    Config,
	root:                   ^platform.Cancel_Token,
	clock:                  ^platform.Clock,
	allocator:              mem.Allocator,
	cancel_alloc:           mem.Allocator,

	// Config-stack consumers, set once at startup before any thread that
	// reads them exists. stack == nil means the stack failed to load and
	// every consumer runs at its default.
	stack:                  ^config.Config_Stack,
	layers:                 []tools.Visibility_Layer, // views into the stack arena
	default_max_chars:      int,                      // config default_max_tool_answer_chars (0 = off)
	active_context:         string,                   // resolved context name ("" = none)
	safety:                 ^safety.Safety_Checker,   // dispatch safety gate (never nil)

	mcp_conn:               ^jsonrpc.Conn, // stdio to the MCP client
	mcp_ready:              sync.One_Shot_Event,
	server:                 ^mcp.Server,

	parent:                 ^jsonrpc.Conn, // svc RPC to the daemon
	parent_stream:          ^rpc.Stream,
	parent_state:           Parent_State,   // guarded by parent_mu
	parent_mu:              sync.Mutex,
	respawns:               int,
	parent_retry_at:        i64, // monotonic ms; next reconnect attempt once GivenUp (guarded by parent_mu)
	// Daemon spawn handles awaiting reap (flock-race losers exit early;
	// daemon.spawn_reap_pending collects them). Owned by whichever thread
	// runs the parent connection — main during startup, the heartbeat
	// thread on reconnects, shutdown after the join — the same rule as
	// endpoint_path/parent_token below.
	parent_spawns:          [dynamic]os.Process,
	daemon:                 ^daemon.Daemon, // --in-process only
	daemon_thread:          ^thread.Thread,
	// in-process channel endpoints (destroyed at shutdown); production mode
	// leaves both nil and uses parent_stream/parent instead.
	parent_endpoint:        ^rpc.Chan_Endpoint,
	daemon_endpoint:        ^rpc.Chan_Endpoint,

	// The daemon's published endpoint (pid/port/token) is read at every
	// dial; parent_token is the auth material of the current link. Both are
	// owned by the connection-setup thread (main or heartbeat), never
	// touched concurrently.
	endpoint_path:          string,
	parent_token:           string,
	daemon_dir:             string,
	home:                   string,

	hb_thread:              ^thread.Thread,      // joined at shutdown
	parent_reader_thread:   ^thread.Thread,  // joined at shutdown
	ticker_thread:          ^thread.Thread,      // production clock timer pump
	ticker_box:             ^platform.Clock_Ticker,

	// stdio reader ownership: the reader cannot be unblocked from a
	// blocked os.read(stdin) portably, so shutdown joins and frees it only
	// when it already exited; otherwise those resources are abandoned to
	// process exit (see shutdown).
	stdio_reader:           ^thread.Thread,
	stdio_pair:             ^Frames_Pair,
	is_stdio_reader_exited: bool, // guarded by stdio_mu
	stdio_mu:               sync.Mutex,

	// Stop-signal watcher ownership: the watcher polls the root token in
	// slices, so shutdown destroys the token only after the latch says the
	// watcher left (otherwise the token is abandoned to process exit —
	// destroying it under the watcher's poll would be a use-after-free).
	is_signal_watch_installed: bool,
	signal_watch_exited:       u32, // atomic latch set by the watcher

	available_caps:         bit_set[tools.Cap], // guarded by parent_mu
	visible:                tools.Visibility,   // last announced set (guarded)
	read_only:              bool,               // project config; fixed at startup

	pool:                   thread.Pool,
	is_pool_started:        bool,

	calls:                  map[string]^Call_Entry, // tools/call id -> registry entry
	// calls_mu guards the registry; calls_cond pairs with it and is
	// broadcast on every registry change — retire_link waits on it to
	// drain in-flight tool calls before destroying the parent link their
	// svc_conn view points at (register/deregister bracket a task's whole
	// lifetime, queued ones included).
	calls_mu:               sync.Mutex,
	calls_cond:             sync.Cond,

	session_info:           tools.Session_Info,
	dispatch:               tools.Dispatch_Host,
	// The onboarding-banner gate (evaluated once per session on the
	// calling thread; lives here so the dispatch host can point at it).
	banner:                 tools.Banner_State,
}

// ---------------------------------------------------------------------------
// stdio transport adapters
// ---------------------------------------------------------------------------

// core:os maps every failed stdio read (EINTR included) onto the same
// error and drops the errno, so a retry loop is not expressible through
// this API; what matters here is not reporting a hard read error as EOF.
stdio_read :: proc(data: rawptr, buf: []u8) -> (int, jsonrpc.Read_Err) {
	_ = data
	n, err := os.read(os.stdin, buf)
	if err == nil {
		if n == 0 {
			return 0, .Eof
		}
		return n, .None
	}
	if err == io.Error.EOF {
		return 0, .Eof
	}
	return 0, .Io
}

stdio_write :: proc(data: rawptr, buf: []u8) -> (int, jsonrpc.Read_Err) {
	_ = data
	n, err := os.write(os.stdout, buf)
	if err == nil {
		return n, .None
	}
	return 0, .Io
}

// id_key_alloc builds the cancel-registry key from a normalized jsonrpc id
// ("n<num>" for numeric ids, "s<text>" for string ids). String ids are
// cloned in full: truncating them could alias two live calls and make a
// cancel release the wrong one.
id_key_alloc :: proc(id: jsonrpc.Id, a: mem.Allocator) -> string {
	switch v in id {
	case i64:
		buf: [32]u8
		buf[0] = 'n'
		n := i64_to_buf(v, buf[1:])
		return strings.clone(string(buf[:1 + n]), a)
	case string:
		out := make([]u8, len(v) + 1, a)
		out[0] = 's'
		for i := 0; i < len(v); i += 1 {
			out[1 + i] = v[i]
		}
		return string(out)
	}
	return "?"
}

i64_to_buf :: proc(v: i64, buf: []u8) -> int {
	neg := v < 0
	uv := u64(v) if !neg else -u64(v)
	digits: [24]u8
	n := 0
	if uv == 0 {
		digits[0] = '0'
		n = 1
	}
	for uv > 0 {
		digits[n] = u8('0' + uv % 10)
		uv /= 10
		n += 1
	}
	out := 0
	if neg && out < len(buf) {
		buf[out] = '-'
		out += 1
	}
	for j := n - 1; j >= 0 && out < len(buf); j -= 1 {
		buf[out] = digits[j]
		out += 1
	}
	return out
}
