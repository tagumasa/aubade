// daemon: the per-project parent process. Owns the svc RPC listener, the
// child registry with heartbeat liveness, the service worker pool, and the
// singleton spawn guarantee (spawn.lock held until the endpoint is
// published). Exits when no live children remain (grace window), or on root
// shutdown.
package daemon

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "src:config"
import "src:editor"
import "src:langserver"
import "src:jsonrpc"
import "src:platform"
import "src:rpc"
import "src:shadow"
import "src:store"
import "src:tracker"
import "src:safety"
import "src:svc"
import "src:web"

DEFAULT_PING_MS    :: i64(5000)
DEFAULT_TIMEOUT_MS :: i64(15000)
DEFAULT_MISSES     :: 3
DEFAULT_GRACE_MS   :: i64(30000)
DEFAULT_DRAIN_MS   :: i64(30000)
DEFAULT_WORKERS    :: 8

Config :: struct {
	project_root:  string, // normalized absolute path
	home:          string, // aubade home
	hb_ping_ms:    i64,    // heartbeat interval
	hb_timeout_ms: i64,    // silence window that counts as one miss
	hb_misses:     int,    // consecutive misses -> child declared dead
	grace_ms:      i64,    // zero live children -> exit after this window
	drain_ms:      i64,    // forced drain deadline at shutdown
	workers:       int,    // service worker pool size
	read_only:     bool,   // project config: refuse mutating svc methods
	clock:         ^platform.Clock,
}

default_config :: proc(project_root, home: string, clock: ^platform.Clock) -> Config {
	return {
		project_root  = project_root,
		home          = home,
		hb_ping_ms    = DEFAULT_PING_MS,
		hb_timeout_ms = DEFAULT_TIMEOUT_MS,
		hb_misses     = DEFAULT_MISSES,
		grace_ms      = DEFAULT_GRACE_MS,
		drain_ms      = DEFAULT_DRAIN_MS,
		workers       = DEFAULT_WORKERS,
		clock         = clock,
	}
}

Child_State :: enum {
	Live,
	Draining, // bye received or stream EOF; outstanding requests finishing
	Closed,   // reaped
}

// Inflight_Entry carries one token slot per registration under a call id:
// a protocol-violating peer can run two concurrent requests under one id,
// and each request's release must retire only its own token or the other
// task's token is destroyed under it (use-after-free) — the same class the
// child side fixed with Call_Entry.tokens.
Inflight_Entry :: struct {
	tokens: [dynamic]^platform.Cancel_Token,
}

Child :: struct {
	id:            int,
	conn:          ^jsonrpc.Conn,
	stream:        ^rpc.Stream,
	owned_stream:  bool, // stream is heap-allocated by accept (freed at close); channel endpoints are not
	token:         ^platform.Cancel_Token, // .Session_Gone on dead child
	state:         Child_State,            // guarded by Daemon.children_mu
	is_hello_seen: bool,                   // svc.hello with the auth token completed (children_mu)
	last_seen_ms:  i64,
	misses:        int,
	inflight:      map[i64]^Inflight_Entry, // call_id -> one token slot per registered request
	mu:            sync.Mutex, // also guards `active` and `is_pump_done` (leaf lock)
	active:        int,          // outstanding pool requests (0 = drained)
	is_pump_done:  bool,         // pump exited: no further pool tasks can be enqueued
	client_pid:    int,
	frames:        chan.Chan([]u8), // reader -> pump (backpressure)
	pump_thread:   ^thread.Thread,
	reader_thread: ^thread.Thread,
}

Daemon :: struct {
	cfg:                    Config,
	dir:                    string,
	lock_path:              string,
	endpoint_path:          string,
	root:                   ^platform.Cancel_Token,
	tcp_listener:           rpc.TCP_Listener,
	is_tcp_listener_open:   bool,
	auth_token:             string, // generated at listen; svc.hello checks it
	hb_thread:              ^thread.Thread,
	sweep_thread:           ^thread.Thread,
	is_sweep_armed:         bool, // set once the sweeper anchored its first deadline (test observability)
	index_warm_thread:      ^thread.Thread,
	index_refresh_thread:   ^thread.Thread,
	is_index_refresh_armed: bool, // set once the refresh loop anchored its first deadline (test observability)
	// One incremental discovery walk at a time: the refresh loop and
	// symbol_find's on-miss hook both claim it through an atomic
	// exchange; index_refresh_last_ms (monotonic clock) backs the on-miss
	// min-gap window.
	index_refresh_in_flight: bool,
	index_refresh_last_ms:   i64,
	accept_thread:          ^thread.Thread,
	children:               [dynamic]^Child,
	children_mu:            sync.Mutex, // children list + states; lock order: children_mu -> child locks, never reverse
	next_child_id:          int,
	svc_table:              svc.Table,
	db:                     ^store.DB, // project symbol index (opened in daemon_init)
	db_path:                string,
	tracker:                ^tracker.Manager, // incident/sprint fold over the events table
	shadow:                 ^shadow.Shadow_Git, // workspace snapshots under <home>/snapshot/<projectID> (nil when init failed)
	fetcher:                ^web.Fetcher, // web_fetch transport (nil when construction failed)
	searcher:               ^web.Searcher, // web_search providers (nil when none is configured)
	web_safety:             ^safety.Safety_Checker, // URL guard + redaction for the web family
	file_safety:            safety.Safety_Checker, // value member (in-place lifecycle): deny-list gate for file reads, walks, and crawls
	mem_files:              ^svc.Memory_Files, // project+global memory roots and pattern lists
	ts:                     ^svc.TS_Source,
	ed:                     ^editor.Editor, // project editor: buffers + file ops discipline
	ls_reg:                 ^langserver.Registry, // language-server launch definitions
	ls:                     ^langserver.Manager, // running servers (lazy; eager only when configured)
	lsp_port:               ^LSP_Port, // registry+manager adapter behind the svc producer ports
	lsp_src:                ^svc.LSP_Source, // LSP symbol producer (writes through write_symbol_index)
	ls_sync:                ^svc.Editor_Sync, // editor buffer → didOpen/didChange/didClose bridge
	pool:                   thread.Pool,
	is_pool_started:        bool,
	lock:                   platform.File_Lock,
	is_lock_held:           bool,
	grace_deadline_ms:      i64, // 0 = not pending
	is_endpoint_published:  bool, // endpoint.json was written by this daemon (only then may cleanup remove it)
	is_in_process:          bool, // channel transport (tests, --in-process): no listener, no process exit
	config_mu:              sync.Mutex, // serializes config writes' read-modify-write of project.jsonc
	// Stop-signal watcher ownership: the watcher polls the root token in
	// slices, so daemon_run destroys the token only after the latch says
	// the watcher left (otherwise it is abandoned to process exit).
	is_signal_watch_installed: bool,
	signal_watch_exited:       u32, // atomic latch set by the watcher
	allocator:              mem.Allocator,
	cancel_alloc:           mem.Allocator,
	started_at_ms:          i64, // wall-clock epoch ms — display only (endpoint.json parity)
	pid:                    int,
}

// daemon_init prepares state up to (but not including) listening.
daemon_init :: proc(d: ^Daemon, cfg_in: Config, a := context.allocator) -> bool {
	// The root enters here once — canonicalize its spelling (symlink
	// ancestors resolved) so every consumer (daemon dir id, editor,
	// doc-sync URIs, code-action relativization, LSP root_abs) shares
	// one spelling. Paths handed out by the path guard are resolved; a
	// raw-spelled root (macOS /var vs /private/var temp trees) would
	// fail every prefix compare against them. pathguard_resolve_root returns a
	// fresh d-allocator-owned string (never an alias of cfg_in's), so
	// daemon_cleanup frees it alongside the other owned strings.
	cfg := cfg_in
	cfg.project_root = safety.pathguard_resolve_root(cfg.project_root, a)
	id := platform.project_id(cfg.project_root, a)
	dir, _ := filepath.join([]string{cfg.home, "daemon", id}, a)
	delete(id, a)
	// An existing directory is fine: a rival or restart (and every test that
	// builds a second daemon over the same project) reuses the runtime dir.
	if err := os.make_directory_all(dir, os.Permissions{.Read_User, .Write_User, .Execute_User}); err != nil && !os.exists(dir) {
		delete(dir, a)
		// Nothing has been assigned into d yet; the resolved root copy is
		// the only allocation this path still owns.
		delete(cfg.project_root, a)
		return false
	}

	root := new(platform.Cancel_Token, a)
	platform.token_init_root(root)

	d^ = {
		cfg            = cfg,
		dir            = dir,
		lock_path      = platform.daemon_lock_path(dir, a),
		endpoint_path  = platform.daemon_endpoint_path(dir, a),
		root           = root,
		allocator      = a,
		cancel_alloc   = a,
		started_at_ms  = platform.wall_ms(),
	}
	d.pid = own_pid()
	// Made on the daemon's allocator here rather than left to grow through
	// context.allocator on the first child registration (the init-owns-
	// collections rule).
	d.children = make([dynamic]^Child, 0, 4, a)
	// Value member per the guard-lifecycle rule (init/destroy in place): a
	// heap-constructed checker would free through the tearing-down
	// thread's ambient allocator.
	safety.safety_checker_init(&d.file_safety, a)
	// The project's resolved state directory joins the write-denied
	// prefixes: the shadow restore gate must refuse the managed tree by
	// location, whatever the folder template named it (the name-built
	// entries cover only the default spelling). The resolution is frame
	// scratch — the rule copies what it keeps — and the tables live until
	// daemon_cleanup destroys them with the checker.
	safety.write_denied_add_dir_prefix(
		&d.file_safety.write_denied,
		config.managed_dir_for_root(d.cfg.project_root, d.cfg.home, context.temp_allocator),
	)
	d.cfg.read_only = resolve_read_only(cfg, a)
	if !project_state_init(d) {
		// Init unwinds its own partial state: cleanup is partial-state safe
		// (nil/flag-guarded destroys), and no thread or watcher exists yet,
		// so the root token — which cleanup deliberately never destroys
		// (running owners keep it) — is released here. Callers keep their
		// bare free(d) on the failure path.
		daemon_cleanup(d)
		platform.token_destroy(d.root, d.cancel_alloc)
		return false
	}
	return true
}

own_pid :: proc() -> int {
	info, err := os.current_process_info({.Command_Line}, context.temp_allocator)
	if err != nil {
		return 0
	}
	return info.pid
}

Listen_Result :: enum {
	Listening,
	AlreadyRunning, // another daemon owns the endpoint; exit quietly
	LockFailed,
	ListenFailed,
}

// daemon_listen takes the spawn lock (blocking), probes for an already
// running daemon, binds loopback TCP on an ephemeral port, publishes
// endpoint.json, and only then releases the lock — the singleton guarantee.
// Losers of the race exit via AlreadyRunning.
daemon_listen :: proc(d: ^Daemon) -> Listen_Result {
	// Bounded by the drain window a successor is willing to tolerate (same
	// budget probe_running uses): an unbounded block here would let a
	// wedged-but-alive parent wedge every future spawn.
	lock, ok := platform.file_lock_acquire(
		d.lock_path,
		d.cfg.drain_ms + max(200, d.cfg.drain_ms / 10),
	)
	if !ok {
		return .LockFailed
	}
	d.lock = lock
	d.is_lock_held = true

	// Failure unwind at procedure exit: each piece is released only while
	// the failure path still owns it — the owned_* flags clear as
	// ownership transfers to the running daemon, so the success return
	// runs the defer as a no-op.
	owned_lock := true
	owned_listener := false
	owned_token := false
	defer {
		if owned_listener {
			rpc.tcp_listener_close(&d.tcp_listener)
			d.is_tcp_listener_open = false
		}
		if owned_token {
			delete(d.auth_token, d.allocator)
			d.auth_token = ""
		}
		if owned_lock {
			platform.file_lock_release(&d.lock)
			d.is_lock_held = false
		}
	}

	if probe_running(d) {
		return .AlreadyRunning
	}

	listener, listen_ok := rpc.tcp_listen(0) // ephemeral; the port is published in endpoint.json
	if !listen_ok {
		return .ListenFailed
	}
	d.tcp_listener = listener
	d.is_tcp_listener_open = true
	owned_listener = true

	token, token_ok := gen_token(d.allocator)
	if !token_ok {
		return .ListenFailed
	}
	d.auth_token = token
	owned_token = true

	// Published while still under the spawn lock: a racing parent either
	// probes this endpoint (AlreadyRunning) or blocks on the lock until the
	// file is complete.
	info := Endpoint_Info{
		pid           = d.pid,
		port          = listener.port,
		started_at_ms = platform.wall_ms(),
		token         = token,
	}
	if !write_endpoint(d.endpoint_path, info) {
		return .ListenFailed
	}
	d.is_endpoint_published = true

	// The transport is listening and published: a concurrent spawn attempt
	// now succeeds by dialing, so the lock is no longer needed — and the
	// listener/token/endpoint belong to the running daemon from here on.
	platform.file_lock_release(&d.lock)
	d.is_lock_held = false
	owned_lock = false
	owned_listener = false
	owned_token = false
	return .Listening
}

// probe_running reports whether a live daemon owns the endpoint. The TCP
// connect is the truth; the endpoint pid is only a hint to wait out the
// owner's drain window, so a successor never binds while the old parent
// still holds project resources (SQLite, shadow git).
probe_running :: proc(d: ^Daemon) -> bool {
	info, ok := read_endpoint(d.endpoint_path, context.temp_allocator)
	defer if ok {
		delete(info.token, context.temp_allocator)
	}
	if !ok {
		return false
	}
	if stream, dial_ok := rpc.tcp_dial(info.port); dial_ok {
		stream.close(stream)
		rpc.stream_free(stream)
		return true
	}
	if info.pid > 0 && platform.pid_alive(info.pid) {
		// Port closed, pid alive: the owner is draining. Wait for its exit,
		// bounded by drain_ms plus a cleanup margin; past the deadline claim
		// anyway so a wedged parent cannot wedge every future spawn.
		margin := max(200, d.cfg.drain_ms / 10)
		deadline := platform.clock_now(d.cfg.clock) + d.cfg.drain_ms + margin
		for platform.clock_now(d.cfg.clock) < deadline {
			if !platform.pid_alive(info.pid) {
				break
			}
			platform.clock_wait(d.cfg.clock, 50)
		}
	}
	return false
}

// daemon_run starts the svc table, worker pool, and monitor threads, then
// blocks until the root token fires (grace expiry or forced stop) and
// drains. Returns the process exit code.
daemon_run :: proc(d: ^Daemon) -> int {
	svc_table_init(&d.svc_table, d)
	// The in-process path pre-starts the pool on the caller's thread (same
	// reason as the table pre-registration): its accept and hello race this
	// thread's startup, and a pump thread reaching pool_add_task first would
	// queue into a zero-value pool whose init then discards the task — the
	// hello never dispatches and the reconnect round fails.
	if !d.is_pool_started {
		thread.pool_init(&d.pool, d.allocator, max(d.cfg.workers, 1))
		thread.pool_start(&d.pool)
		d.is_pool_started = true
	}

	// Thread handles come from d.allocator: cleanup frees them through it
	// regardless of which thread's context runs here.
	thread_alloc := context.allocator
	context.allocator = d.allocator
	d.hb_thread = thread.create_and_start_with_data(d, hb_thread_entry, self_cleanup = false, name = "aubade-hb")
	d.sweep_thread = thread.create_and_start_with_data(d, sweep_thread_entry, self_cleanup = false, name = "aubade-sweep")
	d.index_warm_thread = thread.create_and_start_with_data(d, index_warm_thread_entry, self_cleanup = false, name = "aubade-index-warm")
	d.index_refresh_thread = thread.create_and_start_with_data(d, index_refresh_thread_entry, self_cleanup = false, name = "aubade-index-refresh")
	if !d.is_in_process {
		d.accept_thread = thread.create_and_start_with_data(d, accept_thread_entry, self_cleanup = false, name = "aubade-accept")
	}
	context.allocator = thread_alloc

	platform.token_wait(d.root)

	// Drain: give outstanding requests up to drain_ms before forcing.
	if !wait_children_drained(d, d.cfg.drain_ms) {
		// Forced: fire every child token, then hard-stop the workers. A
		// wedged task's arena and defers are abandoned on purpose — the
		// daemon is exiting — while never-started queued tasks are still
		// released by the queue drain in daemon_cleanup.
		fire_all_children(d, .Shutdown)
		thread.pool_shutdown(&d.pool, 0)
	} else {
		// Graceful: pool_join lets started tasks finish and the workers
		// exit; it skips queued-but-unstarted tasks (core frees the queue
		// but never the task data), which the drain in daemon_cleanup
		// releases. pool_shutdown here would hard-terminate threads and
		// skip every task's defers even on this clean path.
		thread.pool_join(&d.pool)
	}
	daemon_cleanup(d)
	// The root token outlives every child token (close_child destroys those
	// inside cleanup), so it is released here, after cleanup — not inside
	// it, because listen-only callers (endpoint tests, listen-failure
	// paths) call daemon_cleanup directly and keep owning their token.
	// The signal watcher (when the CLI installed one) still polls the
	// fired root in slices: destroy only after it left, else leak the one
	// token into process exit rather than race its poll.
	if !d.is_signal_watch_installed || platform.stop_signals_wait_exited(&d.signal_watch_exited, 250) {
		platform.token_destroy(d.root, d.cancel_alloc)
	}
	return 0
}

daemon_cleanup :: proc(d: ^Daemon) {
	// The listener wakes a thread blocked in accept; only then is joining
	// the accept thread bounded. The root token is fired in every shutdown
	// path before cleanup, so both monitor threads exit promptly.
	if d.is_tcp_listener_open {
		rpc.tcp_listener_close(&d.tcp_listener)
		d.is_tcp_listener_open = false
	}
	// Join the monitors BEFORE touching children: the hb thread reaps
	// drained children (close_child) on its own, and racing it here would
	// double-join/double-free the same child.
	if d.accept_thread != nil {
		thread.join(d.accept_thread)
		free(d.accept_thread, d.allocator)
		d.accept_thread = nil
	}
	if d.hb_thread != nil {
		thread.join(d.hb_thread)
		free(d.hb_thread, d.allocator)
		d.hb_thread = nil
	}
	if d.sweep_thread != nil {
		thread.join(d.sweep_thread)
		free(d.sweep_thread, d.allocator)
		d.sweep_thread = nil
	}
	if d.index_warm_thread != nil {
		thread.join(d.index_warm_thread)
		free(d.index_warm_thread, d.allocator)
		d.index_warm_thread = nil
	}
	if d.index_refresh_thread != nil {
		thread.join(d.index_refresh_thread)
		free(d.index_refresh_thread, d.allocator)
		d.index_refresh_thread = nil
	}

	sync.mutex_lock(&d.children_mu)
	children := d.children
	d.children = nil
	sync.mutex_unlock(&d.children_mu)

	for child in children {
		close_child(d, child)
	}
	delete(children)

	// Every producer (pump thread) is gone with the children; release the
	// tasks still waiting in the pool queue — core's pool_destroy frees
	// the queue but never the task data.
	drain_pool_queue(d)

	if d.is_pool_started {
		thread.pool_destroy(&d.pool)
		d.is_pool_started = false
	}
	svc.table_destroy(&d.svc_table)
	// The daemon root token is still alive here (destroyed only after
	// daemon_cleanup returns). On the operating exits — the stop command,
	// the OS-signal watcher, and the heartbeat's all-children-gone
	// liveness — it is already fired, so the teardown ladder below
	// observes a fired token and skips its graceful waits; the
	// init-failure unwind reaches here unfired and keeps the graceful
	// teardown.
	project_state_destroy(d, d.root)
	safety.safety_checker_destroy(&d.file_safety)
	if d.is_lock_held {
		platform.file_lock_release(&d.lock)
		d.is_lock_held = false
	}
	if !d.is_in_process && d.is_endpoint_published {
		// Removed last — after children, pool, listeners, and threads are
		// gone — so a successor that reads the endpoint before this point
		// finds a closed port plus our (dying) pid and waits out the drain
		// window instead of double-owning project resources. Only the
		// writer removes the file: on a listen-failure path the endpoint on
		// disk belongs to the daemon that won the race.
		os.remove(d.endpoint_path)
	}
	if d.is_endpoint_published {
		delete(d.auth_token, d.allocator)
		d.auth_token = ""
	}
	// Owned strings (the other cfg strings are borrowed from the
	// caller; project_root is the exception — daemon_init replaced it
	// with the canonicalized fresh copy). Freed through d.allocator:
	// cleanup may run on a non-initializing thread.
	delete(d.dir, d.allocator)
	delete(d.lock_path, d.allocator)
	delete(d.endpoint_path, d.allocator)
	delete(d.cfg.project_root, d.allocator)
	d.dir = ""
	d.lock_path = ""
	d.endpoint_path = ""
	d.cfg.project_root = ""
}

// drain_pool_queue frees Frame_Tasks still waiting in the pool queue. Run
// only after the workers are stopped and every producer thread is joined:
// popping takes the pool mutex, and nothing may enqueue behind this drain.
drain_pool_queue :: proc(d: ^Daemon) {
	for {
		task, ok := thread.pool_pop_waiting(&d.pool)
		if !ok {
			break
		}
		ft := cast(^Frame_Task)task.data
		a := task.allocator
		mem.dynamic_arena_destroy(ft.arena)
		free(ft.arena, a)
		free(ft, a)
	}
}

wait_children_drained :: proc(d: ^Daemon, timeout_ms: i64) -> bool {
	deadline := platform.clock_now(d.cfg.clock) + timeout_ms
	for {
		sync.mutex_lock(&d.children_mu)
		pending := 0
		for child in d.children {
			if child.state != .Closed {
				pending += 1
			}
		}
		sync.mutex_unlock(&d.children_mu)
		if pending == 0 {
			return true
		}
		if platform.clock_now(d.cfg.clock) >= deadline {
			return false
		}
		platform.clock_wait(d.cfg.clock, 10)
	}
}

// ---------------------------------------------------------------------------
// Accept + per-connection threads
// ---------------------------------------------------------------------------

hb_thread_entry :: proc(data: rawptr) {
	hb_loop(cast(^Daemon)data)
}

sweep_thread_entry :: proc(data: rawptr) {
	sweep_loop(cast(^Daemon)data)
}

accept_thread_entry :: proc(data: rawptr) {
	accept_loop(cast(^Daemon)data)
}

reader_thread_entry :: proc(data: rawptr) {
	reader_loop(cast(^Child)data)
}

pump_thread_entry :: proc(data: rawptr) {
	pump_loop(cast(^Child)data)
}

accept_loop :: proc(d: ^Daemon) {
	for !platform.token_is_fired(d.root) {
		stream, ok := accept_one(d)
		if !ok {
			if platform.token_is_fired(d.root) {
				break
			}
			platform.clock_wait(d.cfg.clock, 10)
			continue
		}
		start_child(d, stream, true)
	}
}

accept_one :: proc(d: ^Daemon) -> (^rpc.Stream, bool) {
	return rpc.tcp_accept(&d.tcp_listener)
}

// daemon_in_process_accept wires a channel endpoint (tests, --in-process)
// as if it were an accepted connection. The endpoint owns its stream, so
// the child must not free it at close.
daemon_in_process_accept :: proc(d: ^Daemon, endpoint: ^rpc.Chan_Endpoint) -> ^Child {
	return start_child(d, &endpoint.stream, false)
}

// start_child wires a stream into a Child with reader and pump threads.
// owned_stream says whether the Child owns the stream allocation (accepted
// TCP connections do; channel endpoints do not).
start_child :: proc(d: ^Daemon, stream: ^rpc.Stream, owned_stream: bool) -> ^Child {
	frames, ferr := chan.create_buffered(chan.Chan([]u8), 16, d.allocator)
	if ferr != nil {
		stream.close(stream)
		// No threads exist on this path, so close-then-free is the full
		// unwind of an accepted wrapper (channel endpoints keep their owner).
		if owned_stream {
			rpc.stream_free(stream, d.allocator)
		}
		return nil
	}

	conn := new(jsonrpc.Conn, d.allocator)
	reader := rpc.to_reader(stream, jsonrpc.RPC_MAX_FRAME)
	writer := rpc.to_writer(stream)
	jsonrpc.conn_init(conn, reader, writer, d.allocator)
	// Dedicated writer: a pool worker must never hold write_mu across a
	// socket write — forced drain hard-cancels workers (pthread_cancel), and
	// one cancelled mid-write would strand the mutex and hang every later
	// conn_close, wedging daemon_cleanup forever. With the writer, workers
	// only post to the bounded queue (deadline-bounded replies, drop-fast
	// notifications); a stalled peer breaks the conn instead. Teardown's
	// stream.close shuts the socket down, turning a wedged writer's send
	// into an error so conn_destroy's join completes.
	if !jsonrpc.conn_start_outbound(conn, jsonrpc.OUTBOUND_FRAMES_CAP, jsonrpc.OUTBOUND_BYTES_CAP) {
		// Fail closed: without the writer the strand-mutex deadlock class
		// returns; the peer sees a dropped connection and retries.
		stream.close(stream)
		if owned_stream {
			rpc.stream_free(stream, d.allocator)
		}
		chan.destroy(frames)
		free(conn, d.allocator)
		return nil
	}

	child := new(Child, d.allocator)
	token := platform.token_derive(d.root, 0, d.cancel_alloc)
	child^ = {
		conn          = conn,
		stream        = stream,
		owned_stream  = owned_stream,
		token         = token,
		state         = .Live,
		last_seen_ms  = platform.clock_now(d.cfg.clock),
		client_pid    = 0,
		frames        = frames,
	}

	// Publish only a fully initialized child: the heartbeat thread iterates
	// d.children under this mutex and must never observe a zero-value Child.
	// id is assigned under the same lock, immediately before the append.
	sync.mutex_lock(&d.children_mu)
	d.next_child_id += 1
	child.id = d.next_child_id
	append(&d.children, child)
	sync.mutex_unlock(&d.children_mu)

	svc.attach(conn, &d.svc_table, d, child.id)
	svc.attach_tokens(conn, daemon_token_hook)
	svc.release_tokens(conn, daemon_token_release)
	svc.attach_read_only(conn, daemon_read_only)
	if d.auth_token != "" {
		// Loopback TCP accepts any local process: only a completed hello
		// (proof of the token) opens the rest of the svc surface. The
		// in-process channel daemon generates no token and skips the gate.
		svc.attach_hello_gate(conn, daemon_hello_gate)
	}

	// Handles come from d.allocator so close_child can free them through
	// it (this proc may run on the accept thread, not the initializer).
	thread_alloc := context.allocator
	context.allocator = d.allocator
	child.reader_thread = thread.create_and_start_with_data(child, reader_thread_entry, self_cleanup = false, name = "aubade-rpc-reader")
	child.pump_thread = thread.create_and_start_with_data(child, pump_thread_entry, self_cleanup = false, name = "aubade-rpc-pump")
	context.allocator = thread_alloc
	return child
}

// daemon_read_only is the glue's port: mutating methods refuse when the
// project config declared the project read-only.
daemon_read_only :: proc(user: rawptr) -> bool {
	d := cast(^Daemon)user
	return d.cfg.read_only
}

// daemon_hello_gate is the glue's authentication port: true once the
// connection completed svc.hello with the published token.
daemon_hello_gate :: proc(user: rawptr, conn_id: int) -> bool {
	d := cast(^Daemon)user
	sync.mutex_lock(&d.children_mu)
	seen := false
	if child := find_child_locked(d, conn_id); child != nil {
		seen = child.is_hello_seen
	}
	sync.mutex_unlock(&d.children_mu)
	return seen
}

// daemon_token_hook derives the per-request token for an incoming svc
// request and registers it so svc.cancel can fire it.
daemon_token_hook :: proc(user: rawptr, conn_id: int, call_id: i64) -> ^platform.Cancel_Token {
	d := cast(^Daemon)user
	child := find_child(d, conn_id)
	if child == nil {
		return nil
	}
	token := platform.token_derive(child.token, 0, d.cancel_alloc)
	sync.mutex_lock(&child.mu)
	if child.inflight == nil {
		child.inflight = make(map[i64]^Inflight_Entry, 8, d.cancel_alloc)
	}
	entry := child.inflight[call_id]
	if entry == nil {
		entry = new(Inflight_Entry, d.cancel_alloc)
		entry^ = {tokens = make([dynamic]^platform.Cancel_Token, 0, 2, d.cancel_alloc)}
		child.inflight[call_id] = entry
	}
	append(&entry.tokens, token)
	sync.mutex_unlock(&child.mu)
	return token
}

// daemon_token_release is the hook's counterpart: the request finished, so
// its own registration (this token's slot; the entry dies with its last
// slot) goes away. cancel_call fires under the same mutex, so a fire either
// happens-before the destroy or finds nothing.
daemon_token_release :: proc(user: rawptr, conn_id: int, call_id: i64, token: ^platform.Cancel_Token) {
	d := cast(^Daemon)user
	child := find_child(d, conn_id)
	if child == nil {
		return
	}
	sync.mutex_lock(&child.mu)
	if entry, found := child.inflight[call_id]; found && entry != nil {
		for t, i in entry.tokens {
			if t == token {
				last := len(entry.tokens) - 1
				entry.tokens[i] = entry.tokens[last]
				_ = pop(&entry.tokens)
				break
			}
		}
		if len(entry.tokens) == 0 {
			delete_key(&child.inflight, call_id)
			delete(entry.tokens)
			free(entry, d.cancel_alloc)
		}
	}
	sync.mutex_unlock(&child.mu)
	if token != nil {
		platform.token_destroy(token, d.cancel_alloc)
	}
}

find_child :: proc(d: ^Daemon, conn_id: int) -> ^Child {
	sync.mutex_lock(&d.children_mu)
	child := find_child_locked(d, conn_id)
	sync.mutex_unlock(&d.children_mu)
	return child
}

// find_child_locked requires children_mu held; for callers that need the
// lookup and a guarded field write inside one critical section.
find_child_locked :: proc(d: ^Daemon, conn_id: int) -> ^Child {
	for child in d.children {
		if child.id == conn_id {
			return child
		}
	}
	return nil
}

// reader_loop reads frames into the bounded queue. A full queue stops the
// reads and the socket buffer slows the peer (backpressure). The send
// blocking on a full queue is that designed backpressure: cancel latency
// is bounded by the workers draining the queue, and teardown always wakes
// a blocked sender because close_child closes the frames chan before
// joining the reader.
reader_loop :: proc(child: ^Child) {
	send := chan.as_send(child.frames)
	for {
		body, err := jsonrpc.read_frame(&child.conn.reader, child.conn.allocator)
		if err != .None {
			break
		}
		if !chan.send(send, body) {
			delete(body, child.conn.allocator)
			break
		}
	}
	// Stream end: same drain path as bye, but the connection token also
	// fires so in-flight work notices the session is gone. The gone
	// transition runs BEFORE the chan close so the pump's exit evaluation
	// (below) always observes Draining. The reader does NOT evaluate the
	// Draining -> Closed transition itself: only the pump knows when the
	// last queued frame has been dispatched, and a reader-side check raced
	// the pump's active increment for a frame it had already received.
	d := d_of_child(child)
	child_gone(d, child)
	chan.close(send)
}

// pump_loop dispatches queued frames: notifications inline (svc.cancel
// must never wait behind a running request), requests onto the pool. Each
// frame is decoded exactly once — here — and the decoded envelope plus its
// arena cross into the pool task, which dispatches and destroys them.
pump_loop :: proc(child: ^Child) {
	recv := chan.as_recv(child.frames)
	for {
		body, ok := chan.recv(recv)
		if !ok {
			break
		}
		// Heap arena: for the request path it must outlive this loop
		// iteration (the pool task destroys it); a Dynamic_Arena is
		// self-referential, so it is initialized in place at its final
		// location, never copied.
		a := new(mem.Dynamic_Arena, child.conn.allocator)
		mem.dynamic_arena_init(a, child.conn.allocator)
		env, bad_code := jsonrpc.decode_envelope(body, mem.dynamic_arena_allocator(a))
		delete(body, child.conn.allocator)
		if env == nil {
			jsonrpc.conn_send_error(child.conn, 0, false, bad_code, jsonrpc.code_message(bad_code), mem.dynamic_arena_allocator(a))
			mem.dynamic_arena_destroy(a)
			free(a, child.conn.allocator)
			// The reply's whole footprint rides the frame arena above (the
			// header uses a stack buffer); the reset only keeps this
			// thread's temp bounded, same as the notification branch below.
			free_all(context.temp_allocator)
			continue
		}
		if env.kind == .Notification {
			jsonrpc.conn_dispatch(child.conn, env, mem.dynamic_arena_allocator(a))
			mem.dynamic_arena_destroy(a)
			free(a, child.conn.allocator)
			// Notifications run inline on this thread — their scratch must
			// not accumulate across frames for the daemon's lifetime.
			free_all(context.temp_allocator)
		} else {
			task := new(Frame_Task, child.conn.allocator)
			task^ = {child = child, env = env, arena = a}
			sync.mutex_lock(&child.mu)
			child.active += 1
			sync.mutex_unlock(&child.mu)
			thread.pool_add_task(&d_of_child(child).pool, child.conn.allocator, frame_task_proc, task)
		}
	}

	// The queue is closed and fully drained — this loop will enqueue
	// nothing more. Declare the pump done under the inflight lock (the
	// same lock the increments took) and, when no requests are
	// outstanding, finish the Draining -> Closed transition here; with
	// tasks still running, the last task_done does it. `active` belongs
	// to mu, `state` to children_mu — never nested.
	sync.mutex_lock(&child.mu)
	child.is_pump_done = true
	drained := child.active == 0
	sync.mutex_unlock(&child.mu)
	if drained {
		d := d_of_child(child)
		sync.mutex_lock(&d.children_mu)
		if child.state == .Draining {
			child.state = .Closed
		}
		sync.mutex_unlock(&d.children_mu)
	}
}

Frame_Task :: struct {
	child: ^Child,
	env:   ^jsonrpc.Envelope,
	arena: ^mem.Dynamic_Arena,
}

// task_done decrements the outstanding count; the last finishing task
// closes a Draining child — but only once the pump has exited: a .Closed
// child guarantees no pool task is still to be enqueued or running, which
// is what makes the reaper's close_child (it joins the threads but never
// waits on `active`) safe. `active`/`is_pump_done` are guarded by
// mu, `state` by children_mu — taken sequentially, never
// nested.
task_done :: proc(child: ^Child) {
	d := d_of_child(child)
	sync.mutex_lock(&child.mu)
	if child.active > 0 {
		child.active -= 1
	}
	drained := child.active == 0 && child.is_pump_done
	sync.mutex_unlock(&child.mu)
	if drained {
		sync.mutex_lock(&d.children_mu)
		if child.state == .Draining {
			child.state = .Closed
		}
		sync.mutex_unlock(&d.children_mu)
	}
}

frame_task_proc :: proc(task: thread.Task) {
	ft := cast(^Frame_Task)task.data
	child := ft.child
	defer task_done(child)
	// LIFO: the Frame_Task struct is freed last — after the arena it points
	// at has been destroyed and released, while the struct is intact.
	defer free(ft, child.conn.allocator)
	defer {
		mem.dynamic_arena_destroy(ft.arena)
		free(ft.arena, child.conn.allocator)
	}
	jsonrpc.conn_dispatch(child.conn, ft.env, mem.dynamic_arena_allocator(ft.arena))
	// Frame-loop temp reset for this worker thread: handler scratch must
	// not accumulate across requests for the daemon's lifetime.
	free_all(context.temp_allocator)
}

// d_of_child recovers the Daemon from a Child through the svc attach state.
d_of_child :: proc(child: ^Child) -> ^Daemon {
	state := cast(^svc.Attach_State)child.conn.host
	return cast(^Daemon)state.user
}

// child_gone marks the connection dead: the token fires (.Session_Gone
// propagates to every derived request token), the stream closes so the
// peer's writes fail, and outstanding pool tasks finish before reaping.
// Under children_mu only the Live->Draining claim happens — it decides
// which concurrent caller (this, or hb's declare-dead) fires the token.
// The fire and the stream/conn teardown run after the unlock: conn_close
// waits on write_mu, which a worker blocked writing to a dead peer can
// hold for as long as the kernel send buffer stays full, and holding
// children_mu across that would stall every svc handler on the daemon
// (find_child/touch_child all take it).
child_gone :: proc(d: ^Daemon, child: ^Child) {
	sync.mutex_lock(&d.children_mu)
	fire := child.state == .Live
	if fire {
		child.state = .Draining
	}
	sync.mutex_unlock(&d.children_mu)
	if fire {
		platform.token_fire(child.token, .Session_Gone)
	}
	child.stream.close(child.stream)
	jsonrpc.conn_close(child.conn)
}

// close_child releases a reaped child: join the reader (exits with the
// stream) and the pump (exits when the frames chan closes), then free the
// connection with its attach state, the frames chan, any tokens still
// registered, and the child itself.
close_child :: proc(d: ^Daemon, child: ^Child) {
	child.stream.close(child.stream)
	// Closing the frames chan before joining the reader is the teardown
	// wake for a sender blocked on a full queue: the close broadcasts to
	// blocked senders (chan.send then returns false and the reader
	// exits), while a buffered chan still yields its remaining frames to
	// the pump — the normal drain path is unchanged, and the reader's own
	// close is idempotent with this one.
	chan.close(chan.as_send(child.frames))
	if child.reader_thread != nil {
		thread.join(child.reader_thread)
		free(child.reader_thread, d.allocator)
	}
	if child.pump_thread != nil {
		thread.join(child.pump_thread)
		free(child.pump_thread, d.allocator)
	}
	svc.detach(child.conn)
	jsonrpc.conn_destroy(child.conn)
	// The stream allocation outlives every thread that uses it: the
	// reader re-reads the TCP state on EINTR retries and the outbound
	// writer (joined inside conn_destroy) writes through the same state —
	// freeing before the joins leaves them touching freed memory. The
	// session's shutdown path frees in this same join-before-free order.
	if child.owned_stream {
		rpc.stream_free(child.stream, d.allocator)
	}
	chan.destroy(child.frames)
	sync.mutex_lock(&child.mu)
	entries := child.inflight
	child.inflight = nil
	sync.mutex_unlock(&child.mu)
	if entries != nil {
		for _, entry in entries {
			if entry == nil {
				continue
			}
			for token in entry.tokens {
				platform.token_destroy(token, d.cancel_alloc)
			}
			delete(entry.tokens)
			free(entry, d.cancel_alloc)
		}
		delete(entries)
	}
	platform.token_destroy(child.token, d.cancel_alloc)
	free(child.conn, d.allocator)
	free(child, d.allocator)
}

fire_all_children :: proc(d: ^Daemon, reason: platform.Cancel_Reason) {
	// Fires run under the mutex: reaping (remove + close_child) needs the
	// same lock, so the iterated list cannot shift or free mid-loop.
	// children_mu -> child token mutex is the allowed lock direction.
	sync.mutex_lock(&d.children_mu)
	for child in d.children {
		platform.token_fire(child.token, reason)
	}
	sync.mutex_unlock(&d.children_mu)
}
