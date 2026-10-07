// run_session: child startup and lifecycle — parent connection (with
// spawn), hello, MCP stdio serving, heartbeats, shutdown drain.
package session

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"
import "src:daemon"
import "src:config"
import "src:jsonrpc"
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
	a.stdio_frames = stdio_frames
	a.stdio_reader = thread.create_and_start_with_poly_data2(a, stdio_frames, stdio_reader_entry, self_cleanup = false, name = "aubade-stdio-reader")
	a.hb_thread = thread.create_and_start_with_poly_data(a, heartbeat_entry, self_cleanup = false, name = "aubade-hb-client")
	ticker := platform.Clock_Ticker{clock = clock, token = root, tick_ms = 10}
	a.ticker_thread = thread.create_and_start_with_poly_data(ticker, platform.clock_ticker_entry, self_cleanup = false, name = "aubade-clock-ticker")

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

// ---------------------------------------------------------------------------
// stdio reader + dispatch
// ---------------------------------------------------------------------------

stdio_reader_entry :: proc(app: ^App, frames: Frames_Chan) {
	send := chan.as_send(frames)
	for {
		body, err := jsonrpc.read_frame(&app.mcp_conn.reader, app.allocator)
		if err != .None {
			break
		}
		if !chan.send(send, body) {
			delete(body, app.allocator)
			break
		}
	}
	chan.close(send)
	// Mark the reader exited before firing: shutdown observes the flag and
	// only then joins and frees this thread's resources.
	sync.mutex_lock(&app.stdio_mu)
	app.is_stdio_reader_exited = true
	sync.mutex_unlock(&app.stdio_mu)
	// stdin EOF = the MCP client went away: session shutdown.
	platform.token_fire(app.root, .Shutdown)
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
		chan.destroy(a.stdio_frames)
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
