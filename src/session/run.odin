// run_session: child startup and lifecycle — parent connection (with
// spawn), hello, MCP stdio serving, heartbeats, shutdown drain.
package session

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "src:daemon"
import "src:config"
import "src:jsonrpc"
import "src:jsonutil"
import "src:mcp"
import "src:platform"
import "src:rpc"
import "src:safety"
import "src:svc"
import "src:util"
import "src:version"
import "core:sync/chan"
import "src:tools"

run_session :: proc(cfg_in: Config) -> int {
	// Root validation before anything is owned: the exit below must own
	// no allocation. Once the root token and the parent-spawns backing
	// exist, no cleanup path can run on this failure — shutdown needs the
	// canonicalized cfg.project_root to free safely, and here it is still
	// the caller's borrowed spelling.
	root_dir, ok := platform.normalize_project_root(cfg_in.project_root, context.allocator)
	if !ok {
		fmt.eprintln("aubade: cannot normalize project root")
		return 1
	}
	// Canonical spelling (symlink ancestors resolved) BEFORE the daemon
	// dir id is derived: the daemon resolves its root the same way, and
	// the two spellings of one root (macOS /var vs /private/var) must
	// hash to the same endpoint or the child cannot find its daemon.
	// resolve_root returns a fresh clone; the session adopts it as
	// a.cfg.project_root (shutdown frees it) and the normalize result is
	// freed here.
	resolved := safety.pathguard_resolve_root(root_dir, context.allocator)
	delete(root_dir, context.allocator)
	cfg := cfg_in
	cfg.project_root = resolved

	a := new(App, context.allocator)
	defer free(a, context.allocator)

	clock := new(platform.Clock, context.allocator)
	defer free(clock, context.allocator)
	platform.clock_init(clock, false)

	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)

	a^ = {
		cfg          = cfg,
		root         = root,
		clock        = clock,
		allocator    = context.allocator,
		cancel_alloc = context.allocator,
	}

	// Daemon spawn tracking (App.parent_spawns): made here so every append
	// grows through the session allocator.
	a.parent_spawns = make([dynamic]os.Process, 0, 2, a.allocator)

	a.home = a.cfg.home
	if a.home == "" {
		a.home = platform.aubade_home(a.allocator)
	}
	id := platform.project_id(a.cfg.project_root, a.allocator)
	dir := platform.daemon_dir(a.home, id, a.allocator)
	delete(id, a.allocator)
	a.daemon_dir = dir
	a.endpoint_path = platform.daemon_endpoint_path(dir, a.allocator)

	// Config stack: the fold's inclusion layers, read-only mode, the
	// answer-size default, and the shell-safety lists all resolve from
	// one build. A stack that fails to load leaves every consumer at its
	// default — the session runs on, as an unreadable config always has.
	sel := config.Stack_Selection{
		project_root = a.cfg.project_root,
		mode_names   = cfg_in.modes,
	}
	if len(cfg_in.contexts) > 0 {
		// One --context; a repeated flag takes the last.
		sel.context_name = cfg_in.contexts[len(cfg_in.contexts) - 1]
	}
	a.active_context = sel.context_name
	stack, serr := config.stack_build(sel, a.home, a.allocator)
	if serr != nil {
		// Log-only scratch: format on the temp allocator and free it —
		// log_write just eprints, so an ambient-allocator aprintf leaks.
		log_msg := fmt.aprintf("config stack failed to load: %s", platform.err_message(serr), allocator = context.temp_allocator)
		util.log_warning(log_msg)
		delete(log_msg, context.temp_allocator)
	} else {
		a.stack = stack
		a.layers = visibility_layers(stack, a.allocator)
		a.read_only = stack.project.read_only
		a.default_max_chars = stack.global.default_max_tool_answer_chars
		if stack.global.trace_lsp {
			a.cfg.trace_lsp = true
		}
	}

	// One warning pass at startup: the fold's unknown-name notices (the
	// built-in exclusion lists name tools that do not exist yet) would
	// otherwise repeat on every capability change; runtime folds drop
	// them. The pass folds with every capability (cap_all): capability
	// visibility is the runtime folds' decision, and a pre-connect pass
	// cannot know the live set — a thinner base false-warns served tools
	// as unavailable (the file tools need Cap.Editor, which no static set
	// can promise).
	if a.stack != nil {
		warnings: [dynamic]string
		warnings = make([dynamic]string, 0, 16, a.allocator)
		// Elements allocated through the same owner as the list (the fold's
		// `a`), so the element frees below match.
		_ = tools.fold_visibility(tools.cap_all(), a.read_only, a.layers, &warnings, a.allocator)
		for w in warnings {
			util.log_warning(w)
			delete(w, a.allocator)
		}
		delete(warnings)
	}

	// Safety gate: always present — shell_run refuses on a nil checker —
	// with the built-in rules; the merged config lists extend it when a
	// stack loaded. The project's resolved state directory joins the
	// write-denied prefixes (the same location rule the daemon adds): the
	// hostless shadow faces — restore — read these tables.
	sc := new(safety.Safety_Checker, a.allocator)
	safety.safety_checker_init(sc, a.allocator)
	safety.write_denied_add_dir_prefix(
		&sc.write_denied,
		config.managed_dir_for_root(a.cfg.project_root, a.home, context.temp_allocator),
	)
	if a.stack != nil {
		feed_shell_config(sc, a.stack)
	}
	a.safety = sc

	// Log level: the global config key sets the default and the
	// --log-level flag overrides it (one default for every command). No
	// threads exist yet, so the write races nothing.
	session_level := util.Log_Level.Warning
	{
		scratch: mem.Dynamic_Arena
		mem.dynamic_arena_init(&scratch, a.allocator)
		level := util.Log_Level.Warning
		gcfg, _, gerr := config.load_global(
			a.home, mem.dynamic_arena_allocator(&scratch),
		)
		if gerr == nil && gcfg.log_level != "" {
			if l, lok := util.log_parse_level(gcfg.log_level); lok {
				level = l
			}
		}
		if cfg_in.log_level != "" {
			if l, lok := util.log_parse_level(cfg_in.log_level); lok {
				level = l
			}
		}
		session_level = level
		util.log_init(level)
		mem.dynamic_arena_destroy(&scratch)
	}

	a.session_info = {
		log_level = util.log_level_string(session_level),
		trace_lsp = a.cfg.trace_lsp,
	}

	// Tool worker pool.
	thread.pool_init(&a.pool, a.allocator, TOOL_WORKERS)
	thread.pool_start(&a.pool)
	a.is_pool_started = true

	// MCP server over stdio.
	a.mcp_conn = new(jsonrpc.Conn, a.allocator)
	stdio_reader: jsonrpc.Reader
	// MCP stdio is newline-delimited JSON (the specification delimits
	// messages by newlines); the header framing stays on the internal
	// RPC and LSP faces.
	jsonrpc.reader_init_ndjson(&stdio_reader, stdio_read, nil, jsonrpc.DEFAULT_MAX_FRAME)
	stdio_writer: jsonrpc.Writer
	jsonrpc.writer_init_ndjson(&stdio_writer, stdio_write, nil)
	jsonrpc.conn_init(a.mcp_conn, stdio_reader, stdio_writer, a.allocator)
	// Dedicated writer, same pattern as the LSP factory: the driver's
	// stdout pipe is mortal, and a client that stops draining it must not
	// park the dispatch thread in a blocking os.write under write_mu —
	// the child would never reach shutdown. Replies wait briefly for queue
	// space (a failed post breaks the conn and releases the waiters);
	// notifications drop fast.
	if !jsonrpc.conn_start_outbound(a.mcp_conn, jsonrpc.OUTBOUND_FRAMES_CAP, jsonrpc.OUTBOUND_BYTES_CAP) {
		// stdio is the session's lifeline; without the writer the wedge
		// class returns. Fail the startup.
		shutdown(a)
		return 1
	}

	a.server = new(mcp.Server, a.allocator)
	a.server^ = {
		host         = a,
		name         = "aubade",
		version      = VERSION_STRING,
		description  = "Aubade code intelligence (Odin rewrite)",
		// Filled below by compose_instructions before the reader threads
		// start serving: an owned clone, so shutdown frees it without
		// path knowledge (never a borrowed Config spelling here).
		instructions = "",
		list_tools   = host_list_tools,
		call_tool    = host_call_tool,
		on_cancel    = host_on_cancel,
	}
	mcp.server_init(a.server, a.mcp_conn)

	setup_dispatch(a)
	// Seed the announced visibility so the first parent connection (caps
	// {} -> {.Project, .Svc}) does not look like a change before
	// initialization.
	a.visible = fold_visible(a, {}, a.read_only)

	// Parent link: in-process channel pair or a real daemon connection.
	if a.cfg.is_in_process {
		if !start_in_process_daemon(a) {
			fmt.eprintln("aubade: cannot start in-process daemon")
			// The pool and the checker are already up: run the shared
			// teardown instead of returning past it.
			shutdown(a)
			return 1
		}
	} else {
		if !connect_parent(a, SPAWN_ATTEMPTS) {
			// Service-backed tools stay withdrawn; the MCP session runs on
			// and the heartbeat retries after the backoff.
			mark_given_up(a)
		}
	}

	// The initialize instructions carry the rendered system prompt (the
	// static manual on Config stays as the render-failure fallback).
	a.server.instructions = compose_instructions(a)

	// Threads: stdio reader -> bounded queue -> this thread dispatches;
	// heartbeat keeps the parent link warm. The production clock also gets
	// its timer pump (deadlines fire from there).
	// Ctrl-C lands on the session root: stdin EOF is the normal
	// child stop; a signal is the operator's. Installed once the frames
	// channel exists — the wake hook pries the blocked dispatch loop open,
	// which a fired token alone cannot. The CLI entry sets the flag —
	// in-process tests construct Config directly and stay on the default
	// disposition.
	stdio_frames, ferr := chan.create_buffered(Frames_Chan, 16, a.allocator)
	if ferr != nil {
		shutdown(a)
		return 1
	}
	if cfg_in.install_signals {
		if platform.install_stop_signals(root, a.allocator, stdio_wake, &stdio_frames, &a.signal_watch_exited) {
			a.is_signal_watch_installed = true
		} else {
			util.log_warning("could not install stop signal handlers; Ctrl-C falls back to default termination")
		}
	}
	pair := new(Frames_Pair, a.allocator)
	pair^ = {app = a, frames = stdio_frames}
	a.stdio_pair = pair
	a.stdio_reader = thread.create_and_start_with_data(pair, stdio_reader_entry, self_cleanup = false, name = "aubade-stdio-reader")
	a.hb_thread = thread.create_and_start_with_data(a, heartbeat_entry, self_cleanup = false, name = "aubade-hb-client")
	a.ticker_box = new(platform.Clock_Ticker, a.allocator)
	a.ticker_box^ = {clock = clock, token = root, tick_ms = 10}
	a.ticker_thread = thread.create_and_start_with_data(a.ticker_box, platform.clock_ticker_entry, self_cleanup = false, name = "aubade-clock-ticker")

	// Main dispatch loop (owns the App lifetime until stdin EOF or root).
	exit_code := mcp_dispatch_loop(a, stdio_frames)

	// Shutdown: drain tools, tell the parent, stop the pool.
	shutdown(a)
	return exit_code
}

VERSION_STRING :: version.AUBADE_VERSION

Frames_Chan :: chan.Chan([]u8)

// stdio_wake is the signal bridge's unblock hook: closing the frames
// channel wakes the dispatch loop's blocking receive (the reader's EOF
// close is idempotent with this one).
stdio_wake :: proc(user: rawptr) {
	frames := cast(^Frames_Chan)user
	chan.close(chan.as_send(frames^))
}

Frames_Pair :: struct {
	app:    ^App,
	frames: Frames_Chan,
}

// ---------------------------------------------------------------------------
// stdio reader + dispatch
// ---------------------------------------------------------------------------

stdio_reader_entry :: proc(data: rawptr) {
	pair := cast(^Frames_Pair)data
	send := chan.as_send(pair.frames)
	for {
		body, err := jsonrpc.read_frame(&pair.app.mcp_conn.reader, pair.app.allocator)
		if err != .None {
			break
		}
		if !chan.send(send, body) {
			delete(body, pair.app.allocator)
			break
		}
	}
	chan.close(send)
	// Mark the reader exited before firing: shutdown observes the flag and
	// only then joins and frees this thread's resources.
	sync.mutex_lock(&pair.app.stdio_mu)
	pair.app.is_stdio_reader_exited = true
	sync.mutex_unlock(&pair.app.stdio_mu)
	// stdin EOF = the MCP client went away: session shutdown.
	platform.token_fire(pair.app.root, .Shutdown)
}

// mcp_dispatch_frame runs one already-received frame to completion: decode
// and dispatch on a per-frame arena, then the thread's temp reset (handler
// scratch — args marshaling, response quoting, frame headers — must not
// accumulate across calls for the session's lifetime; same discipline as
// the daemon's frame workers).
mcp_dispatch_frame :: proc(a: ^App, body: []u8) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, a.allocator)
	jsonrpc.conn_handle_body(a.mcp_conn, body, mem.dynamic_arena_allocator(&arena))
	mem.dynamic_arena_destroy(&arena)
	free_all(context.temp_allocator)
	delete(body, a.allocator)
}

mcp_dispatch_loop :: proc(a: ^App, frames: Frames_Chan) -> int {
	recv := chan.as_recv(frames)
	for {
		if platform.token_is_fired(a.root) {
			// The reader closes the frames chan BEFORE firing the root on
			// EOF, so frames already buffered at that instant would
			// otherwise be abandoned undispatched (an immediate-close driver
			// lost its initialize response this way). Finish them: a closed
			// buffered chan still yields its contents, try_recv never
			// blocks, and a token fired by signal on an open, empty chan
			// drains nothing and falls straight through.
			for {
				body, ok := chan.try_recv(recv)
				if !ok {
					break
				}
				mcp_dispatch_frame(a, body)
			}
			break
		}
		body, ok := chan.recv(recv)
		if !ok {
			break
		}
		mcp_dispatch_frame(a, body)
	}
	platform.token_fire(a.root, .Shutdown)
	return 0
}

// ---------------------------------------------------------------------------
// Parent connection, heartbeat, respawn
// ---------------------------------------------------------------------------

// connect_parent dials the daemon link (transport-aware), spawning the
// parent as needed; the parent serializes itself through the spawn lock.
connect_parent :: proc(a: ^App, attempts: int) -> bool {
	deadline := platform.clock_now(a.clock) + CONNECT_TIMEOUT_MS
	spawns_left := attempts
	for {
		// Dial (spawning as needed) until a stream appears, the deadline
		// passes, or shutdown fires.
		conn: ^jsonrpc.Conn
		stream: ^rpc.Stream
		dialed := false
		for !dialed {
			if platform.token_is_fired(a.root) {
				return false
			}
			s, ok := dial_parent(a)
			if ok {
				stream = s
				conn = new(jsonrpc.Conn, a.allocator)
				reader := rpc.to_reader(stream, jsonrpc.RPC_MAX_FRAME)
				writer := rpc.to_writer(stream)
				jsonrpc.conn_init(conn, reader, writer, a.allocator)
				conn.cancel_notify = parent_cancel_notify
				dialed = true
				break
			}
			if platform.clock_now(a.clock) >= deadline {
				return false
			}
			// Respawn on every failed round: a daemon that exits by grace
			// before this child dials (tiny grace windows) self-heals here.
			if spawns_left > 0 {
				exe := a.cfg.exe_path
				owned_exe := false
				if exe == "" {
					// get_executable_path returns an owned clone — one
					// leak per retry round if dropped.
					exe, _ = os.get_executable_path(a.allocator)
					owned_exe = true
				}
				dcfg := daemon.default_config(a.cfg.project_root, a.home, a.clock)
				spawned, handle := daemon.spawn_parent(exe, dcfg, a.cfg.hb_ping_ms, a.cfg.hb_timeout_ms, a.cfg.hb_grace_ms, a.cfg.hb_drain_ms)
				if spawned {
					append(&a.parent_spawns, handle)
				}
				if owned_exe {
					delete(exe, a.allocator)
				}
				spawns_left -= 1
			}
			// A just-spawned flock loser can exit within milliseconds; reap
			// before the retry sleep so the pending list clears fast.
			daemon.spawn_reap_pending(&a.parent_spawns)
			platform.clock_wait(a.clock, 50)
		}

		// Spawn the reader first, then publish stream + conn + reader as one
		// unit under parent_mu: shutdown swaps the same three fields under
		// the same mutex, and a half-published link (conn visible, reader
		// handle not yet stored) would let it free the link under the live
		// reader.
		link_reader := start_parent_reader(a, conn)
		sync.mutex_lock(&a.parent_mu)
		if platform.token_is_fired(a.root) {
			sync.mutex_unlock(&a.parent_mu)
			// Shutdown began mid-connect: keep the link unpublished and retire
			// it locally. Shutdown's own teardown finds nils, and with the root
			// fired the heartbeat loop is on its way out, so nothing races us.
			retire_link(a, stream, link_reader, conn)
			return false
		}
		a.parent_stream = stream
		a.parent = conn
		a.parent_reader_thread = link_reader
		sync.mutex_unlock(&a.parent_mu)

		if send_hello(a, conn) {
			set_parent_state(a, .Live)
			return true
		}
		// The link exists but the handshake failed — typically the daemon
		// died between the dial and the hello. Tear it fully down and retry
		// within the remaining budget (respawn included, exactly like a
		// failed dial) instead of returning failure on the first miss.
		teardown_parent_link(a)
		if platform.token_is_fired(a.root) || platform.clock_now(a.clock) >= deadline {
			return false
		}
		platform.clock_wait(a.clock, 50)
	}
	return false
}

// dial_parent connects to the daemon published in endpoint.json. A missing
// or unreadable publication means "not up yet"; the caller spawns. The
// published token is kept for svc.hello.
dial_parent :: proc(a: ^App) -> (^rpc.Stream, bool) {
	info, ok := daemon.read_endpoint(a.endpoint_path, context.temp_allocator)
	if !ok {
		return nil, false
	}
	stream, dial_ok := rpc.tcp_dial(info.port)
	if !dial_ok {
		delete(info.token, context.temp_allocator)
		return nil, false
	}
	if a.parent_token != "" {
		delete(a.parent_token, a.allocator)
	}
	a.parent_token = strings.clone(info.token, a.allocator)
	delete(info.token, context.temp_allocator)
	return stream, true
}

// teardown_parent_link fully releases the parent connection. Everything is
// swapped to locals under parent_mu first, making the proc idempotent —
// concurrent callers (shutdown racing a heartbeat reconnect) each destroy
// exactly what they swapped out.
teardown_parent_link :: proc(a: ^App) {
	sync.mutex_lock(&a.parent_mu)
	stream := a.parent_stream
	rthr := a.parent_reader_thread
	conn := a.parent
	a.parent_stream = nil
	a.parent_reader_thread = nil
	a.parent = nil
	sync.mutex_unlock(&a.parent_mu)
	if conn != nil {
		// Withdraw the dispatch host's copy of the link before retiring it.
		// The registry drain in retire_link only covers *registered* calls;
		// a dispatch_call in its svc_conn-copy→register window registers
		// after the drain concludes, and its worker re-reads svc_conn at
		// task start — a nil here turns that task into a "no parent link"
		// answer instead of a use-after-free on the destroyed conn. Only
		// the retiring conn is withdrawn: a racing reconnect may already
		// have published a newer link, which stays.
		sync.mutex_lock(&a.dispatch.mu)
		if a.dispatch.svc_conn == conn {
			a.dispatch.svc_conn = nil
		}
		sync.mutex_unlock(&a.dispatch.mu)
	}
	retire_link(a, stream, rthr, conn)
}

// retire_link releases a link held only in locals (either swapped out of
// the App or never published): the stream closes first (unblocking the
// reader thread; in-process the peer daemon reaps its side and closes the
// channel, waking this reader), then the reader joins, then the conn is
// closed — and NOT destroyed until every in-flight tool call has left it:
// a pool worker runs svc-backed applies through this conn (Tool_Ctx's
// svc_conn), and the call registry brackets each task's whole lifetime
// (register at dispatch, deregister in the worker's and the abandon
// path's defers). Firing the registered tokens aborts the applies at
// their checkpoints, conn_close wakes the slot waiters, and the drain
// waits for the last deregister before the destroy. The stream
// allocation is freed last — the reader re-reads the TCP state on EINTR
// retries and the writer (joined inside conn_destroy) writes through the
// same state, so freeing earlier is a use-after-free window. The
// reader's exit path takes parent_mu, so none of this may happen under
// it.
retire_link :: proc(a: ^App, stream: ^rpc.Stream, rthr: ^thread.Thread, conn: ^jsonrpc.Conn) {
	if stream != nil {
		stream.close(stream)
	}
	if rthr != nil {
		thread.join(rthr)
		free(rthr, a.allocator)
	}
	if conn != nil {
		abort_inflight_calls(a)
		jsonrpc.conn_close(conn)
		wait_calls_drained(a)
		jsonrpc.conn_destroy(conn)
		free(conn, a.allocator)
	}
	if stream != nil && !a.cfg.is_in_process {
		// Channel endpoints embed the Stream inside the endpoint allocation
		// and are freed by channel_endpoint_destroy; only dialed TCP
		// streams are individually heap-allocated here.
		rpc.stream_free(stream, a.allocator)
	}
}

// abort_inflight_calls fires every registered call token: retiring the
// link means the conn those applies are running through is going away,
// and the aborts move each worker to its exit at the next checkpoint.
// The fires run under calls_mu like host_on_cancel's — the entry stays
// in place for the task's own deregister.
abort_inflight_calls :: proc(a: ^App) {
	sync.mutex_lock(&a.calls_mu)
	for _, entry in a.calls {
		if entry != nil {
			for t in entry.tokens {
				if t != nil {
					platform.token_fire(t, .Cancelled)
				}
			}
		}
	}
	sync.mutex_unlock(&a.calls_mu)
}

// wait_calls_drained blocks until the registry is empty: the last
// deregister (a worker's or an abandon path's defer) broadcasts on
// calls_cond. Every task's token has been fired (or carries its own
// deadline), and the stream/conn are closed, so the wait is bounded by
// the workers' checkpoint cadence, not by any live RPC.
wait_calls_drained :: proc(a: ^App) {
	sync.mutex_lock(&a.calls_mu)
	for len(a.calls) > 0 {
		sync.cond_wait(&a.calls_cond, &a.calls_mu)
	}
	sync.mutex_unlock(&a.calls_mu)
}

// parent_cancel_notify is the parent link's cancel port: when a tool
// call's token fires mid-wait, conn_call forwards svc.cancel for the
// matched request so the daemon aborts in-flight work instead of running
// it to completion nobody will read.
parent_cancel_notify :: proc(c: ^jsonrpc.Conn, id: i64) {
	params := jsonutil.json_object(1, context.temp_allocator)
	jsonutil.obj_set(&params, "call_id", jsonutil.json_int(id))
	_ = jsonrpc.conn_notify(c, svc.METHOD_CANCEL, json.Value(json.Object(params)), context.temp_allocator)
}

send_hello :: proc(a: ^App, conn: ^jsonrpc.Conn) -> bool {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, a.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	params := jsonutil.json_object(5, alloc)
	jsonutil.obj_set(&params, "client_pid", jsonutil.json_int(i64(daemon.own_pid())))
	jsonutil.obj_set(&params, "token", jsonutil.json_string(a.parent_token))
	jsonutil.obj_set(&params, "trace_lsp", jsonutil.json_bool(a.cfg.trace_lsp))
	jsonutil.obj_set(&params, "contexts", jsonutil.json_string_array(a.cfg.contexts, alloc))
	jsonutil.obj_set(&params, "modes", jsonutil.json_string_array(a.cfg.modes, alloc))

	result, code, msg, cerr := jsonrpc.conn_call(
		conn,
		svc.METHOD_HELLO,
		json.Value(json.Object(params)),
		alloc,
		platform.clock_now(a.clock) + svc.CONTROL_CALL_DEADLINE_MS,
	)
	if cerr != .None {
		// Log-only scratch: format on the temp allocator and free it —
		// log_write just eprints, so an ambient-allocator aprintf leaks.
		log_msg := fmt.aprintf(
			"svc.hello failed: %v code=%d msg=%q",
			cerr, i32(code), msg,
			allocator = context.temp_allocator,
		)
		util.log_error(log_msg)
		delete(log_msg, context.temp_allocator)
		return false
	}
	return result != nil
}

Parent_Reader_Box :: struct {
	app:  ^App,
	conn: ^jsonrpc.Conn,
}

// start_parent_reader spawns the link reader with the conn captured in the
// box (never read back from a.parent): teardown swaps a.parent under
// parent_mu concurrently, and the thread must hold its own reference.
start_parent_reader :: proc(a: ^App, conn: ^jsonrpc.Conn) -> ^thread.Thread {
	box := new(Parent_Reader_Box, a.allocator)
	box^ = {app = a, conn = conn}
	return thread.create_and_start_with_data(box, parent_reader_entry, self_cleanup = false, name = "aubade-parent-reader")
}

parent_reader_entry :: proc(data: rawptr) {
	box := cast(^Parent_Reader_Box)data
	a := box.app
	// Only responses arrive from the parent; EOF marks the link
	// down (the heartbeat thread handles reconnection). The conn reference
	// comes from the box: teardown frees the conn only after joining this
	// thread, so the pointer stays valid for the whole loop.
	jsonrpc.conn_read_loop(box.conn)
	free(box, a.allocator)
	sync.mutex_lock(&a.parent_mu)
	if a.parent_state == .Live {
		a.parent_state = .Disconnected
	}
	sync.mutex_unlock(&a.parent_mu)
}

// Heartbeat waits park in short slices, not one ping-interval sleep: a
// fired root (Ctrl-C, shutdown) must be observed by the next checkpoint,
// and this thread's join is on the shutdown path.
heartbeat_entry :: proc(data: rawptr) {
	a := cast(^App)data
	// Same clamp as the daemon's hb_loop: a non-positive ping interval
	// would otherwise make every sliced wait return immediately and the
	// heartbeat thread spin hot.
	interval := a.cfg.hb_ping_ms
	if interval <= 0 {
		interval = daemon.DEFAULT_PING_MS
	}
	for !platform.token_is_fired(a.root) {
		platform.clock_wait_sliced_until(
			a.clock, a.root, platform.clock_now(a.clock) + interval,
		)
		if platform.token_is_fired(a.root) {
			break
		}
		beat_once(a)
		// Ping requests and reconnect scratch must not accumulate across
		// beats on this long-lived thread.
		free_all(context.temp_allocator)
	}
}

beat_once :: proc(a: ^App) {
	// Daemons spawned by an earlier round (startup or a reconnect) that
	// lost the flock race have exited by now: collect them on every beat.
	// This thread is the list's owner between startup and shutdown.
	daemon.spawn_reap_pending(&a.parent_spawns)
	sync.mutex_lock(&a.parent_mu)
	state := a.parent_state
	conn := a.parent
	retry_wait := a.parent_retry_at - platform.clock_now(a.clock)
	sync.mutex_unlock(&a.parent_mu)
	if state == .GivenUp && retry_wait > 0 {
		return
	}

	if state == .Live && conn != nil {
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena, a.allocator)
		params := jsonutil.json_object(0, mem.dynamic_arena_allocator(&arena))
		_, _, _, cerr := jsonrpc.conn_call(
			conn,
			svc.METHOD_PING,
			json.Value(json.Object(params)),
			mem.dynamic_arena_allocator(&arena),
			platform.clock_now(a.clock) + a.cfg.hb_timeout_ms,
		)
		mem.dynamic_arena_destroy(&arena)
		if cerr == .None {
			return
		}
		// Pong miss: the parent is frozen or gone. Fall through to
		// reconnect (respawn budget shared with connect_parent).
		if platform.token_is_fired(a.root) {
			return
		}
	}

	// Take the old link out of service under the mutex, then join and
	// destroy it via the shared idempotent teardown — the reader thread's
	// exit path takes the same mutex, so joining while holding it would
	// deadlock. The token check inside the claim matters: past it, this
	// thread owns the reconnect, and a shutdown that fired the root in the
	// meantime must be the one to retire the link instead.
	sync.mutex_lock(&a.parent_mu)
	if platform.token_is_fired(a.root) {
		sync.mutex_unlock(&a.parent_mu)
		return
	}
	switch a.parent_state {
	case .Live, .Disconnected:
	case .GivenUp:
		// The backoff window was already checked above; re-verify under
		// the mutex so a concurrent state change cannot slip a premature
		// retry through.
		if platform.clock_now(a.clock) < a.parent_retry_at {
			sync.mutex_unlock(&a.parent_mu)
			return
		}
	}
	a.parent_state = .Disconnected
	// The backoff elapsed: the world the last round failed against is gone,
	// so restore the full spawn budget for the fresh attempt.
	a.respawns = 0
	sync.mutex_unlock(&a.parent_mu)

	teardown_parent_link(a)

	if platform.token_is_fired(a.root) {
		return
	}
	if a.cfg.is_in_process {
		// In-process never dials or spawns a real daemon: rebuild the
		// in-memory one synchronously (connect_parent here would spawn a
		// TCP daemon and orphan the old in-memory one). Same respawn budget
		// as the TCP path.
		if a.respawns >= SPAWN_ATTEMPTS {
			mark_given_up(a)
			return
		}
		stop_in_process_daemon(a)
		if start_in_process_daemon(a) {
			a.respawns += 1
		} else {
			mark_given_up(a)
		}
		return
	}
	if connect_parent(a, SPAWN_ATTEMPTS - a.respawns) {
		a.respawns += 1
	} else {
		mark_given_up(a)
	}
}

// mark_given_up enters the backoff state: svc-dependent tools stay withdrawn
// and the heartbeat retries the reconnect once the backoff elapses.
mark_given_up :: proc(a: ^App) {
	sync.mutex_lock(&a.parent_mu)
	a.parent_retry_at = platform.clock_now(a.clock) + PARENT_RETRY_BACKOFF_MS
	sync.mutex_unlock(&a.parent_mu)
	set_parent_state(a, .GivenUp)
}

set_parent_state :: proc(a: ^App, state: Parent_State) {
	sync.mutex_lock(&a.parent_mu)
	a.parent_state = state
	caps := parent_caps_for(state)
	if a.available_caps != caps {
		a.available_caps = caps
	}
	sync.mutex_unlock(&a.parent_mu)
	announce_visibility(a)
}

parent_caps_for :: proc(state: Parent_State) -> bit_set[tools.Cap] {
	// Shell runs in the child under the safety checker: the capability is
	// static, with or without a parent.
	base := bit_set[tools.Cap]{.Shell}
	if state == .Live {
		// A live parent is the project's daemon: it carries the file,
		// symbol, index, language-server, editor, memory, tracker,
		// shadow-git, and web services, so the link grants those
		// capabilities alongside the transport one.
		return base | {.Project, .Svc, .Editor, .Memories, .Tracker, .Shadow, .Web}
	}
	return base
}

// ---------------------------------------------------------------------------
// in-process daemon (channel transport, same jsonrpc path)
// ---------------------------------------------------------------------------

start_in_process_daemon :: proc(a: ^App) -> bool {
	d := new(daemon.Daemon, a.allocator)
	dcfg := daemon.default_config(a.cfg.project_root, a.home, a.clock)
	dcfg.hb_ping_ms = a.cfg.hb_ping_ms
	dcfg.hb_timeout_ms = a.cfg.hb_timeout_ms
	dcfg.grace_ms = a.cfg.hb_grace_ms
	dcfg.drain_ms = a.cfg.hb_drain_ms
	if !daemon.daemon_init(d, dcfg, a.allocator) {
		free(d, a.allocator)
		return false
	}
	d.is_in_process = true
	a.daemon = d
	// Register the svc handlers BEFORE the run thread and the accept below:
	// start_child attaches this table into the connection, and racing the
	// run thread's own init would attach an empty table ("method not
	// found"). daemon_run's later svc_table_init call sees handlers != nil
	// and keeps these.
	daemon.svc_table_init(&d.svc_table, d)
	// The worker pool is pre-started for the same reason as the table above:
	// accept and send_hello run on this thread while the daemon thread is
	// still warming up, and a pump thread that beats daemon_run's pool_init
	// would queue the hello into a zero-value pool and lose the task (the
	// reconnect round then times out). daemon_run sees is_pool_started and
	// skips its own init.
	thread.pool_init(&d.pool, d.allocator, max(d.cfg.workers, 1))
	thread.pool_start(&d.pool)
	d.is_pool_started = true

	ea, eb := rpc.channel_pair(a.allocator)
	if ea == nil {
		// Daemon fully initialized but never ran. daemon_run owns the
		// cleanup on the normal path and never started, so release the
		// same state here: fire the root first (the graceful teardown
		// ladder skips its waits), then run the full cleanup — the svc
		// table, the STARTED worker pool, and every piece of project
		// state from daemon_init are alive and owned by d. A bare free
		// would leak the project state and leave pool threads running on
		// freed memory.
		platform.token_fire(d.root, .Shutdown)
		daemon.daemon_cleanup(d)
		platform.token_destroy(d.root, a.cancel_alloc)
		free(d, a.allocator)
		a.daemon = nil
		return false
	}
	a.parent_endpoint = ea
	a.daemon_endpoint = eb

	// Daemon lifetime in-process: run until its root fires; the session
	// fires it at shutdown.
	a.daemon_thread = thread.create_and_start_with_data(d, in_process_daemon_entry, self_cleanup = false, name = "aubade-daemon")

	child := daemon.daemon_in_process_accept(d, eb)
	if child == nil {
		stop_in_process_daemon(a)
		return false
	}

	parent := new(jsonrpc.Conn, a.allocator)
	reader := rpc.to_reader(&ea.stream, jsonrpc.RPC_MAX_FRAME)
	writer := rpc.to_writer(&ea.stream)
	jsonrpc.conn_init(parent, reader, writer, a.allocator)
	parent.cancel_notify = parent_cancel_notify
	// Same atomic publication as connect_parent: the reader spawns first,
	// then all three link fields land under parent_mu in one piece —
	// shutdown's swap must never observe the conn without the reader.
	link_reader := start_parent_reader(a, parent)
	sync.mutex_lock(&a.parent_mu)
	if platform.token_is_fired(a.root) {
		sync.mutex_unlock(&a.parent_mu)
		retire_link(a, &ea.stream, link_reader, parent)
		stop_in_process_daemon(a)
		return false
	}
	a.parent_stream = &ea.stream
	a.parent = parent
	a.parent_reader_thread = link_reader
	sync.mutex_unlock(&a.parent_mu)

	if !send_hello(a, parent) {
		teardown_parent_link(a)
		stop_in_process_daemon(a)
		return false
	}
	set_parent_state(a, .Live)
	return true
}

// stop_in_process_daemon winds the in-process daemon down on every failure
// path and at shutdown: fire its root, join its run thread (daemon_run does
// its own cleanup and destroys its root token on the way out — destroying
// it here too would double-free), then release the channel endpoints and
// the daemon struct.
stop_in_process_daemon :: proc(a: ^App) {
	if a.daemon != nil {
		platform.token_fire(a.daemon.root, .Shutdown)
	}
	if a.daemon_thread != nil {
		thread.join(a.daemon_thread)
		free(a.daemon_thread, a.allocator)
		a.daemon_thread = nil
	}
	if a.daemon != nil {
		free(a.daemon, a.allocator)
		a.daemon = nil
	}
	if a.daemon_endpoint != nil {
		rpc.channel_endpoint_destroy(a.daemon_endpoint, a.allocator)
		a.daemon_endpoint = nil
	}
	if a.parent_endpoint != nil {
		rpc.channel_endpoint_destroy(a.parent_endpoint, a.allocator)
		a.parent_endpoint = nil
	}
}

in_process_daemon_entry :: proc(data: rawptr) {
	d := cast(^daemon.Daemon)data
	daemon.daemon_run(d)
}

// ---------------------------------------------------------------------------
// shutdown
// ---------------------------------------------------------------------------

// shutdown releases everything the session owns, in join-before-free
// order: root fires first so the heartbeat and ticker loops observe the
// stop, the parent link is taken over exclusively (the bye lets the parent
// drain at once and failing the pending-call slots wakes an in-flight ping
// immediately — closing only the stream would leave it waiting out its
// full deadline), the heartbeat thread joins before anything it may still
// be using is freed, the pool drains, the in-process daemon (if any) runs
// its own cleanup, and the root token and clock are destroyed last.
shutdown :: proc(a: ^App) {
	platform.token_fire(a.root, .Shutdown)

	// Take the link over exclusively: the swap under parent_mu makes a
	// concurrent heartbeat teardown own a disjoint half of the fields.
	sync.mutex_lock(&a.parent_mu)
	parent := a.parent
	stream := a.parent_stream
	link_reader := a.parent_reader_thread
	a.parent = nil
	a.parent_stream = nil
	a.parent_reader_thread = nil
	sync.mutex_unlock(&a.parent_mu)

	if parent != nil {
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena, a.allocator)
		jsonrpc.conn_notify(parent, svc.METHOD_BYE, nil, mem.dynamic_arena_allocator(&arena))
		mem.dynamic_arena_destroy(&arena)
		// conn_close only fails the pending-call slots (an in-flight ping
		// wakes at once); destruction waits until after the pool join below
		// — the heartbeat thread AND any in-flight tool worker may still be
		// inside conn_call on this conn.
		jsonrpc.conn_close(parent)
	}
	if stream != nil {
		stream.close(stream)
	}

	if a.hb_thread != nil {
		thread.join(a.hb_thread)
		free(a.hb_thread, a.allocator)
		a.hb_thread = nil
	}

	// The heartbeat thread was the spawn list's last possible owner:
	// collect what exited, then release the list. Handles of daemons still
	// running carry no allocation — the kernel closes them at exit.
	daemon.spawn_reap_pending(&a.parent_spawns)
	delete(a.parent_spawns)

	if link_reader != nil {
		thread.join(link_reader)
		free(link_reader, a.allocator)
	}

	// The pool drains BEFORE the swapped link is destroyed: a tools/call
	// dispatched before shutdown runs its apply on a pool worker through
	// this conn (Tool_Ctx's svc_conn), and the root token fired at entry
	// moves every worker to its exit at the next checkpoint — the join is
	// bounded by the checkpoint cadence, not by live RPCs.
	if a.is_pool_started {
		thread.pool_join(&a.pool)
		drain_tool_queue(a)
		thread.pool_destroy(&a.pool)
		a.is_pool_started = false
	}

	// Safe to release the swapped link now: its users (the heartbeat
	// thread, the link reader, the tool workers above) are all gone.
	if stream != nil && !a.cfg.is_in_process {
		rpc.stream_free(stream, a.allocator)
	}
	if parent != nil {
		jsonrpc.conn_destroy(parent)
		free(parent, a.allocator)
	}
	// A link published by a reconnect that lost the race above (root fired
	// mid-connect) is retired here; the common case finds nothing.
	teardown_parent_link(a)

	if a.daemon != nil {
		stop_in_process_daemon(a)
	}

	// Config-side state: the checker first (nothing runs tools past the
	// drained pool), then the stack its layers and the shell patterns
	// view into.
	if a.safety != nil {
		safety.safety_checker_destroy(a.safety)
		free(a.safety, a.allocator)
		a.safety = nil
	}
	if a.stack != nil {
		config.stack_destroy(a.stack)
		a.stack = nil
	}
	if a.layers != nil {
		delete(a.layers, a.allocator)
		a.layers = nil
	}

	if a.ticker_thread != nil {
		thread.join(a.ticker_thread)
		free(a.ticker_thread, a.allocator)
		a.ticker_thread = nil
	}
	if a.ticker_box != nil {
		free(a.ticker_box, a.allocator)
		a.ticker_box = nil
	}

	// The stdio reader blocks in os.read(stdin) and cannot be unblocked
	// portably (close does not wake a blocked read). Free its resources
	// only when it already exited; otherwise they are abandoned to process
	// exit — the process ends immediately after this proc returns.
	sync.mutex_lock(&a.stdio_mu)
	reader_exited := a.is_stdio_reader_exited
	sync.mutex_unlock(&a.stdio_mu)
	if reader_exited && a.stdio_reader != nil {
		thread.join(a.stdio_reader)
		free(a.stdio_reader, a.allocator)
		a.stdio_reader = nil
		chan.destroy(a.stdio_pair.frames)
		free(a.stdio_pair, a.allocator)
		a.stdio_pair = nil
		jsonrpc.conn_destroy(a.mcp_conn)
		free(a.mcp_conn, a.allocator)
		// The server struct outlived the conn it served; with the conn
		// gone nothing references it. instructions is the owned clone
		// compose_instructions produced ("" when the session exited
		// before that step), so the delete needs no path knowledge.
		if a.server != nil {
			if len(a.server.instructions) > 0 {
				delete(a.server.instructions, a.allocator)
			}
			free(a.server, a.allocator)
			a.server = nil
		}
	}

	delete(a.calls)

	if a.parent_token != "" {
		delete(a.parent_token, a.allocator)
		a.parent_token = ""
	}
	delete(a.endpoint_path, a.allocator)
	delete(a.daemon_dir, a.allocator)
	// a.home is the aubade_home clone only when the config carried no
	// home (the borrowed spelling stays the caller's).
	if a.home != a.cfg.home {
		delete(a.home, a.allocator)
	}
	a.home = ""
	// project_root is the canonicalized fresh copy from pathguard_resolve_root
	// (never cfg_in's alias); the session owns and frees it. The rest of
	// a.cfg's strings stay borrowed from the caller.
	delete(a.cfg.project_root, a.allocator)
	a.cfg.project_root = ""
	a.endpoint_path = ""
	a.daemon_dir = ""

	// The signal watcher (when installed) still polls the fired root every
	// 50 ms slice: destroy the token only after it has left, else leak the
	// one token into process exit rather than race its poll.
	if !a.is_signal_watch_installed || platform.stop_signals_wait_exited(&a.signal_watch_exited, 250) {
		platform.token_destroy(a.root, a.cancel_alloc)
	}
	platform.clock_destroy(a.clock)
}

// drain_tool_queue releases Call_Tasks still waiting in the pool queue:
// pool_join runs started tasks only, and core's pool_destroy frees the
// queue but never the task data. Run after the workers are joined so
// nothing races the pop. Each drained task goes through abandon_task —
// its token, armed timer, and call registration were never released by
// run_task's defers, which never fired for it.
drain_tool_queue :: proc(a: ^App) {
	for {
		task, ok := thread.pool_pop_waiting(&a.pool)
		if !ok {
			break
		}
		tools.abandon_task(cast(^tools.Call_Task)task.data)
	}
}
