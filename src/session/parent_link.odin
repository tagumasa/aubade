// The shared child→daemon link: dialing the published endpoint (spawning
// the daemon as needed), the svc hello, the reader thread, the heartbeat
// with its reconnect/backoff ladder, and the in-process channel transport
// the tests swap in. Both child hosts (the MCP stdio session and the LSP
// stdio session) drive this machinery through the same App; the host-
// specific faces live beside it (run.odin, lsp_run.odin).
package session

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "src:daemon"
import "jsonrpc:jsonrpc"
import "jsonutil:jsonutil"
import "src:platform"
import "src:rpc"
import "src:svc"
import "src:tools"
import "src:util"

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
				reader := rpc.to_reader(stream, rpc.RPC_MAX_FRAME)
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
			// The wire hook runs at EVERY establishment (here and in the
			// in-process daemon): the link the heartbeat ladder rebuilt
			// carries none of the previous conn's registrations. Between
			// the reader start above and this hook a push could arrive and
			// find no handler — the daemon pushes only on state changes
			// and the next one re-drives everything, so the window costs
			// nothing.
			if a.parent_conn_wire != nil {
				a.parent_conn_wire(a, conn)
			}
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
	// The daemon routes its push family (diagnostics relay, langserver
	// state) only to children that announced the mode; an absent member
	// keeps the MCP child's hello byte-identical to its old form.
	if a.parent_mode != "" {
		jsonutil.obj_set(&params, "mode", jsonutil.json_string(a.parent_mode))
	}

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

// start_parent_reader spawns the link reader holding its own conn
// reference (never read back from a.parent): teardown swaps a.parent under
// parent_mu concurrently, and the thread must hold its own reference.
start_parent_reader :: proc(a: ^App, conn: ^jsonrpc.Conn) -> ^thread.Thread {
	return thread.create_and_start_with_poly_data2(a, conn, parent_reader_entry, self_cleanup = false, name = "aubade-parent-reader")
}

parent_reader_entry :: proc(a: ^App, conn: ^jsonrpc.Conn) {
	// Only responses arrive from the parent; EOF marks the link
	// down (the heartbeat thread handles reconnection). The conn reference
	// comes with this thread's arguments: teardown frees the conn only
	// after joining this thread, so the pointer stays valid for the whole
	// loop.
	jsonrpc.conn_read_loop(conn)
	sync.mutex_lock(&a.parent_mu)
	if a.parent_state == .Live {
		a.parent_state = .Disconnected
	}
	sync.mutex_unlock(&a.parent_mu)
}

// Heartbeat waits park in short slices, not one ping-interval sleep: a
// fired root (Ctrl-C, shutdown) must be observed by the next checkpoint,
// and this thread's join is on the shutdown path.
heartbeat_entry :: proc(a: ^App) {
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
	a.daemon_thread = thread.create_and_start_with_poly_data(d, in_process_daemon_entry, self_cleanup = false, name = "aubade-daemon")

	child := daemon.daemon_in_process_accept(d, eb)
	if child == nil {
		stop_in_process_daemon(a)
		return false
	}

	parent := new(jsonrpc.Conn, a.allocator)
	reader := rpc.to_reader(&ea.stream, rpc.RPC_MAX_FRAME)
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
	if a.parent_conn_wire != nil {
		a.parent_conn_wire(a, parent)
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

in_process_daemon_entry :: proc(d: ^daemon.Daemon) {
	daemon.daemon_run(d)
}
