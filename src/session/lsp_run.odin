// The LSP child host: `aubade lsp` — an LSP 3.17 server over stdio for
// editors, wired onto the shared child→daemon parent link. It mirrors the
// MCP child's threading model (stdio reader thread → bounded frames chan →
// dispatch loop, heartbeat, stop-signal bridge) with two face differences:
// the wire framing is Content-Length headers (LSP), and the project root
// resolves at initialize (rootUri, or workspaceFolders[0]; an explicit
// --project binds at startup) — so the parent link comes up inside the
// initialize callback rather than before serving.
package session

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:sync/chan"

import "src:config"
import "src:jsonrpc"
import "src:jsonutil"
import "src:lsp"
import "src:lspserver"
import "src:platform"
import "src:safety"
import "src:symbol"
import "src:svc"
import "src:tools"
import "src:util"

// Client-call deadlines. Both sit above the daemon document face's own
// apply budget (svc.DOC_SYNC_APPLY_DEADLINE_MS), so a slow apply surfaces
// as the daemon's typed retryable timeout instead of a transport timeout.
LSP_DOC_CALL_DEADLINE_MS        :: i64(15_000)
LSP_HIGHLIGHTS_CALL_DEADLINE_MS :: i64(10_000)

// The publish-side svc reads (doc/diagnostics + langserver/list): daemon
// computations over open buffers, in the highlights face's class.
LSP_DIAGNOSTICS_CALL_DEADLINE_MS :: i64(10_000)

// The relay starter's budgets. langserver/start bounds the daemon-side
// handshake (fork/exec + initialize can take up to ~45s there), so its
// deadline sits above that handover; the registration round trip and the
// relay reads are editor-facing calls in the highlights face's class.
LSP_START_CALL_DEADLINE_MS    :: i64(50_000)
LSP_REGISTER_CALL_DEADLINE_MS :: i64(10_000)
LSP_RELAY_CALL_DEADLINE_MS    :: i64(10_000)

// The svc.edit/apply leg: the face's workspace/applyEdit response wait
// (the daemon's routing deadline bounds the whole round trip).
LSP_APPLY_CALL_DEADLINE_MS :: i64(8_000)

// The apply job queue's bound. A full queue refuses the request at the
// source (an error response the daemon's router maps to an explicit
// failure) — load sheds instead of buffering.
LSP_APPLY_QUEUE_CAP :: 4

// The relay starter's cadence while no record is dirty: how often it may
// wake to notice fresh relay bookkeeping (the dirty latch lives under
// h.mu). Only the notice lag is bounded here; nothing polls hot.
LSP_RELAY_IDLE_POLL_MS :: i64(100)

// The dynamic registration id namespace the editor unregisters by:
// aubade.relay.<language>.<method-basename>.
RELAY_REGISTRATION_PREFIX :: "aubade.relay."

// The publish shell's cadence while no document is due: how often it may
// wake to notice a fresh mark. The window itself is the face's
// PUBLISH_DEBOUNCE_MS; this only bounds the notice lag on a real clock.
LSP_PUBLISH_IDLE_POLL_MS :: i64(100)

Lsp_Host :: struct {
	app:    ^App,
	conn:   ^jsonrpc.Conn,
	server: ^lspserver.Server,
	frames: Frames_Chan,

	// Root binding: false until the project root is resolved (an explicit
	// --project at startup, or the initialize callback). Before it the
	// child has no daemon dir, no config stack, and no heartbeat.
	is_root_bound: bool,
	next_call_id:  i64, // synthetic registry keys; guarded by mu (dispatch + publish shell)

	// The debounce shell: fires the face's publish pass when a document's
	// window ends. Created from the session root token; joined on teardown
	// before the face is destroyed.
	pub_thread: ^thread.Thread,

	// The relay starter: drives svc.langserver/start for pending languages
	// and the dynamic capability registrations on the editor connection.
	// Created alongside the publish shell; joined beside it before the
	// face teardown.
	relay_thread: ^thread.Thread,

	// The apply worker: svc.edit/apply requests (the daemon's two-writer
	// round trip) queue here — bounded, a full queue refuses at the
	// source — and run OFF the parent reader thread, because the face's
	// workspace/applyEdit waits for the editor. The bounded guard in each
	// job pins the link against teardown until the answer is sent.
	apply_jobs:   chan.Chan(^Apply_Job),
	apply_thread: ^thread.Thread,

	// Per-language relay bookkeeping, keyed by the didOpen language id.
	// h.mu guards it (dispatch thread writes on open, the push handlers
	// write on the parent reader thread, the starter reads and writes);
	// keys are clones on a.allocator — a caller-owned key would rot once
	// its message arena dies (the long-lived map rule).
	relay:       map[string]Relay_Lang,
	relay_dirty: bool, // a record changed: the starter's next pass re-drives

	// stdio reader ownership: the reader cannot be unblocked from a
	// blocked os.read(stdin) portably, so teardown joins and frees it only
	// when it already exited; otherwise those resources are abandoned to
	// process exit (the process ends when run_lsp_session returns).
	reader:           ^thread.Thread,
	is_reader_exited: bool, // guarded by mu
	mu:               sync.Mutex,
}

run_lsp_session :: proc(cfg_in: Config) -> int {
	// The project root is owned only after lsp_bind_root resolves it;
	// until then the config's spelling stays with the caller. An explicit
	// --project binds right after the root-free startup; the rootUri path
	// binds inside initialize.
	explicit_root := cfg_in.project_root
	cfg := cfg_in
	cfg.project_root = ""

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

	// Daemon spawn tracking and the (empty) call registry: the registry
	// brackets every out-going svc call so link teardown waits for them
	// (see lsp_call_begin); the shared shutdown releases both.
	a.parent_spawns = make([dynamic]os.Process, 0, 2, a.allocator)
	a.calls = make(map[string]^Call_Entry, 8, a.allocator)

	a.home = a.cfg.home
	if a.home == "" {
		a.home = platform.aubade_home(a.allocator)
	}

	// Log level: the global config key sets the default and the
	// --log-level flag overrides it (one default for every command).
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
		util.log_init(level)
		mem.dynamic_arena_destroy(&scratch)
	}

	h := new(Lsp_Host, a.allocator)
	h^ = {app = a}
	h.relay = make(map[string]Relay_Lang, 4, a.allocator)

	// The LSP child announces its mode and its per-link wire hook before
	// the link can come up (either establishment path below): the daemon
	// routes its push family to mode=="lsp" children, and the hook
	// registers the push handlers at EVERY link establishment so
	// heartbeat reconnects never leave them behind.
	a.parent_mode = "lsp"
	a.parent_conn_wire = lsp_wire_parent_conn
	a.host_face = h

	// An explicit --project is authoritative over initialize's rootUri (the
	// CLI flag wins): bind it now so the link is up before the client even
	// connects.
	if explicit_root != "" {
		if msg := lsp_bind_root(h, explicit_root); msg != "" {
			fmt.eprintln(strings.concatenate({"aubade lsp: ", msg}, context.temp_allocator))
			lsp_release_early(h)
			shutdown(a)
			return 1
		}
		if msg := lsp_start_background(h); msg != "" {
			fmt.eprintln(strings.concatenate({"aubade lsp: ", msg}, context.temp_allocator))
			lsp_release_early(h)
			shutdown(a)
			return 1
		}
	}

	// LSP server over stdio. The wire framing is Content-Length headers —
	// the same mode as the internal RPC, unlike the MCP child's
	// newline-delimited JSON.
	h.conn = new(jsonrpc.Conn, a.allocator)
	reader: jsonrpc.Reader
	jsonrpc.reader_init(&reader, stdio_read, nil, jsonrpc.DEFAULT_MAX_FRAME)
	writer: jsonrpc.Writer
	jsonrpc.writer_init(&writer, stdio_write, nil)
	jsonrpc.conn_init(h.conn, reader, writer, a.allocator)
	// Dedicated writer, same reasoning as the MCP child: an editor that
	// stops draining stdout must not park the dispatch loop in a blocking
	// os.write. Replies wait briefly for queue space; notifications drop.
	if !jsonrpc.conn_start_outbound(h.conn, jsonrpc.OUTBOUND_FRAMES_CAP, jsonrpc.OUTBOUND_BYTES_CAP) {
		jsonrpc.conn_destroy(h.conn)
		free(h.conn, a.allocator)
		free(h, a.allocator)
		shutdown(a)
		return 1
	}

	h.server = new(lspserver.Server, a.allocator)
	h.server^ = {
		host            = h,
		name            = "aubade",
		version         = VERSION_STRING,
		initialize_host = host_lsp_initialize,
		doc_open        = host_lsp_doc_open,
		doc_change      = host_lsp_doc_change,
		doc_close       = host_lsp_doc_close,
		highlights      = host_lsp_highlights,
		diagnostics     = host_lsp_diagnostics,
		readiness       = host_lsp_readiness,
		relay           = host_lsp_relay,
		text_for_uri    = host_lsp_text_for_uri,
		outline         = host_lsp_outline,
		ops             = host_lsp_ops,
		log             = host_lsp_log,
		allocator       = a.allocator,
	}
	lspserver.server_init(h.server, h.conn)

	// Threads: stdio reader -> bounded queue -> this thread dispatches;
	// the heartbeat keeps the parent link warm once the root is bound.
	stdio_frames, ferr := chan.create_buffered(Frames_Chan, 16, a.allocator)
	if ferr != nil {
		lsp_release_early(h)
		shutdown(a)
		return 1
	}
	h.frames = stdio_frames
	// Ctrl-C lands on the session root: stdin EOF is the normal child
	// stop; a signal is the operator's. The wake hook pries the blocked
	// dispatch loop open, which a fired token alone cannot.
	if cfg_in.install_signals {
		if platform.install_stop_signals(root, a.allocator, stdio_wake, &h.frames, &a.signal_watch_exited) {
			a.is_signal_watch_installed = true
		} else {
			util.log_warning("could not install stop signal handlers; Ctrl-C falls back to default termination")
		}
	}
	h.reader = thread.create_and_start_with_poly_data2(h, h.frames, lsp_stdio_reader_entry, self_cleanup = false, name = "aubade-lsp-stdio-reader")

	// The publish shell: fires the face's debounced diagnostics pass. It
	// waits on the session root (fires with the dispatch loop's shutdown)
	// and is joined below before the face teardown destroys the server
	// and conn it touches.
	h.pub_thread = thread.create_and_start_with_poly_data(h, lsp_publish_entry, self_cleanup = false, name = "aubade-lsp-publish")

	// The relay starter: same lifetime shape as the publish shell — root
	// token liveness, joined before the face teardown.
	h.relay_thread = thread.create_and_start_with_poly_data(h, lsp_relay_entry, self_cleanup = false, name = "aubade-lsp-relay")

	// The apply worker: same lifetime shape again. Created before the
	// dispatch loop serves, so an svc.edit/apply can never meet a nil
	// queue (the parent link is up at most this early only for an explicit
	// --project, and no document can be open before initialize served).
	apply_jobs, ajerr := chan.create_buffered(chan.Chan(^Apply_Job), LSP_APPLY_QUEUE_CAP, a.allocator)
	if ajerr != nil {
		fmt.eprintln("aubade lsp: cannot create the apply queue")
		// The stdio reader, the publish shell, and the relay shell are
		// already running. Fire the session root first — the dispatch loop
		// is not serving yet, so firing early changes no serving behavior —
		// then join the shells, which exit their root waits at once, before
		// the face release frees the server they touch. The face release
		// applies its own reader rule: a reader still blocked in
		// os.read(stdin) cannot be joined portably, so what it touches is
		// abandoned to process exit instead of freed under it.
		platform.token_fire(a.root, .Shutdown)
		thread.join(h.pub_thread)
		free(h.pub_thread, a.allocator)
		h.pub_thread = nil
		thread.join(h.relay_thread)
		free(h.relay_thread, a.allocator)
		h.relay_thread = nil
		lsp_stop_parent_link(a)
		lsp_release_face(h)
		shutdown(a)
		return 1
	}
	h.apply_jobs = apply_jobs
	h.apply_thread = thread.create_and_start_with_poly_data(h, lsp_apply_entry, self_cleanup = false, name = "aubade-lsp-apply")

	// Main dispatch loop (owns the face lifetime until stdin EOF, the
	// exit notification, or the root token).
	exit_code := lsp_dispatch_loop(h)

	// The dispatch loop fired the session root; the shells observe it at
	// their next checkpoint. Join them before the face teardown so no fire
	// or registration pass can touch the server or conn while they are
	// destroyed — the same order the face's own threads obey.
	thread.join(h.pub_thread)
	free(h.pub_thread, a.allocator)
	h.pub_thread = nil
	thread.join(h.relay_thread)
	free(h.relay_thread, a.allocator)
	h.relay_thread = nil
	// The apply queue closes to its worker first: the drain answers every
	// queued job over the still-live parent conn (a fired root makes each
	// refuse at once), so the worker is gone and the queue empty before
	// the link retires underneath it.
	chan.close(chan.as_send(h.apply_jobs))
	thread.join(h.apply_thread)
	free(h.apply_thread, a.allocator)
	h.apply_thread = nil
	// The parent link retires BEFORE the face teardown: its reader thread
	// runs the push handlers (svc.push/* and svc.edit/apply) against the
	// server, the relay records, and the apply queue this teardown frees,
	// and that reader joins only inside retire_link. The heartbeat joins
	// first — a ping still inside conn_call must not outlive the conn
	// destroy (the close-then-join-then-destroy order shutdown itself
	// uses) — and the explicit retire nils the field so shutdown skips it.
	// After the reader's join no push handler can run, which is what makes
	// the chan destroy below and the face teardown race-free; shutdown
	// then finds an already-retired link and no-ops through it.
	lsp_stop_parent_link(a)
	chan.destroy(h.apply_jobs)

	// Face teardown (it joins the stdio reader when it can), then the
	// shared link/config teardown — the link is already retired, so
	// shutdown's own pass swaps nils and finds nothing to release.
	lsp_release_face(h)
	shutdown(a)
	return exit_code
}

// lsp_release_early unwinds the face before the reader thread exists: the
// conn is destroyed directly (nothing can be inside it) and the host shell
// is freed. Used by the startup failure paths.
lsp_release_early :: proc(h: ^Lsp_Host) {
	a := h.app
	lsp_relay_map_destroy(h)
	if h.conn != nil {
		jsonrpc.conn_destroy(h.conn)
		free(h.conn, a.allocator)
		h.conn = nil
	}
	if h.server != nil {
		lspserver.server_destroy(h.server)
		free(h.server, a.allocator)
		h.server = nil
	}
	free(h, a.allocator)
}

// lsp_relay_map_destroy frees the relay records' owned keys and the map
// itself. Long-lived-map keys are clones on a.allocator — deleting the map
// alone would strand them.
lsp_relay_map_destroy :: proc(h: ^Lsp_Host) {
	if h.relay == nil {
		return
	}
	for k in h.relay {
		delete(k, h.app.allocator)
	}
	delete(h.relay)
	h.relay = nil
}

// lsp_release_face unwinds the face once nothing serves it — after the
// dispatch loop ended, or on a startup failure whose face threads were
// already running. The stdio reader cannot be unblocked from a blocked
// os.read portably: when it already exited, everything it owns is joined
// and freed; otherwise the face's resources are abandoned to process exit
// (the same rule as the MCP child's shutdown).
lsp_release_face :: proc(h: ^Lsp_Host) {
	a := h.app
	sync.mutex_lock(&h.mu)
	reader_exited := h.is_reader_exited
	sync.mutex_unlock(&h.mu)
	if !reader_exited {
		return
	}
	thread.join(h.reader)
	free(h.reader, a.allocator)
	chan.destroy(h.frames)
	jsonrpc.conn_destroy(h.conn)
	free(h.conn, a.allocator)
	lspserver.server_destroy(h.server)
	free(h.server, a.allocator)
	lsp_relay_map_destroy(h)
	free(h, a.allocator)
}

// lsp_stop_parent_link retires the parent link ahead of a face teardown.
// The heartbeat joins first: its ping rides conn_call outside the call
// registry, so retire_link's drain cannot wait for it — the conn must not
// be destroyed under a live caller (shutdown's own order joins the
// heartbeat between conn_close and conn_destroy for the same reason). The
// graceful-leave bye rides the link while it is still whole, then the
// shared idempotent teardown joins the link reader and frees the conn.
// Every step is a no-op when the link never came up, and a second pass
// (shutdown's own) swaps nils and finds nothing to release.
lsp_stop_parent_link :: proc(a: ^App) {
	if a.hb_thread != nil {
		thread.join(a.hb_thread)
		free(a.hb_thread, a.allocator)
		a.hb_thread = nil
	}
	sync.mutex_lock(&a.parent_mu)
	conn := a.parent
	sync.mutex_unlock(&a.parent_mu)
	if conn != nil {
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena, a.allocator)
		jsonrpc.conn_notify(conn, svc.METHOD_BYE, nil, mem.dynamic_arena_allocator(&arena))
		mem.dynamic_arena_destroy(&arena)
	}
	teardown_parent_link(a)
}

// ---------------------------------------------------------------------------
// stdio reader + dispatch
// ---------------------------------------------------------------------------

lsp_stdio_reader_entry :: proc(h: ^Lsp_Host, frames: Frames_Chan) {
	send := chan.as_send(frames)
	for {
		body, err := jsonrpc.read_frame(&h.conn.reader, h.app.allocator)
		if err != .None {
			break
		}
		if !chan.send(send, body) {
			delete(body, h.app.allocator)
			break
		}
	}
	chan.close(send)
	sync.mutex_lock(&h.mu)
	h.is_reader_exited = true
	sync.mutex_unlock(&h.mu)
	// stdin EOF = the LSP client went away: session shutdown.
	platform.token_fire(h.app.root, .Shutdown)
}

// lsp_dispatch_frame runs one already-received frame to completion on a
// per-frame arena, then resets the thread's temp (host callback scratch —
// svc param marshaling, log formatting — must not accumulate across
// frames; same discipline as the MCP dispatch).
lsp_dispatch_frame :: proc(h: ^Lsp_Host, body: []u8) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, h.app.allocator)
	jsonrpc.conn_handle_body(h.conn, body, mem.dynamic_arena_allocator(&arena))
	mem.dynamic_arena_destroy(&arena)
	free_all(context.temp_allocator)
	delete(body, h.app.allocator)
}

lsp_dispatch_loop :: proc(h: ^Lsp_Host) -> int {
	recv := chan.as_recv(h.frames)
	for {
		if platform.token_is_fired(h.app.root) {
			// The reader closes the frames chan before firing the root on
			// EOF; finish the frames already buffered so a fast client's
			// last messages are not abandoned undispatched.
			for {
				body, ok := chan.try_recv(recv)
				if !ok {
					break
				}
				lsp_dispatch_frame(h, body)
			}
			break
		}
		body, ok := chan.recv(recv)
		if !ok {
			break
		}
		lsp_dispatch_frame(h, body)
		if lspserver.server_exit_status(h.server) != .Running {
			// The exit notification terminates the session. Buffered
			// frames are dropped unread (exit means exit), but their
			// bodies are released so the teardown strands nothing.
			for {
				rest, have := chan.try_recv(recv)
				if !have {
					break
				}
				delete(rest, h.app.allocator)
			}
			break
		}
	}
	platform.token_fire(h.app.root, .Shutdown)
	return lspserver.server_exit_code(h.server)
}

// ---------------------------------------------------------------------------
// Project binding and background threads
// ---------------------------------------------------------------------------

// lsp_bind_root resolves the session's project root and installs the
// root-dependent startup state (daemon dir, config stack, safety gate) —
// the same sequence the MCP child runs before serving, moved here because
// the LSP child's root only exists at initialize time. Called once; the
// caller guards with is_root_bound. A non-empty result is the
// initialize-facing error message.
lsp_bind_root :: proc(h: ^Lsp_Host, root_raw: string) -> string {
	a := h.app
	// Canonical spelling (symlink ancestors resolved) BEFORE the daemon
	// dir id is derived: the daemon resolves its root the same way, and
	// the two spellings of one root (macOS /var vs /private/var) must
	// hash to the same endpoint or the child cannot find its daemon.
	root_dir, ok := platform.normalize_project_root(root_raw, context.temp_allocator)
	if !ok {
		return "cannot normalize the project root"
	}
	resolved := safety.pathguard_resolve_root(root_dir, a.allocator)
	a.cfg.project_root = resolved

	id := platform.project_id(a.cfg.project_root, a.allocator)
	a.daemon_dir = platform.daemon_dir(a.home, id, a.allocator)
	delete(id, a.allocator)
	a.endpoint_path = platform.daemon_endpoint_path(a.daemon_dir, a.allocator)

	// Config stack: the fold's inclusion layers, read-only mode, and the
	// answer-size default resolve from one build. A stack that fails to
	// load leaves every consumer at its default.
	sel := config.Stack_Selection{
		project_root = a.cfg.project_root,
		mode_names   = a.cfg.modes,
	}
	if len(a.cfg.contexts) > 0 {
		sel.context_name = a.cfg.contexts[len(a.cfg.contexts) - 1]
	}
	a.active_context = sel.context_name
	stack, serr := config.stack_build(sel, a.home, a.allocator)
	if serr != nil {
		// Log-only scratch: format on the temp allocator and free it.
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

	// One warning pass at startup (the same discipline as the MCP child:
	// the fold's unknown-name notices would otherwise repeat on every
	// later fold).
	if a.stack != nil {
		warnings := make([dynamic]string, 0, 16, a.allocator)
		_ = tools.fold_visibility(tools.cap_all(), a.read_only, a.layers, &warnings, a.allocator)
		for w in warnings {
			util.log_warning(w)
			delete(w, a.allocator)
		}
		delete(warnings)
	}

	// Safety gate: the project's resolved state directory joins the
	// write-denied prefixes, and the merged config lists extend the
	// built-in shell rules.
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

	h.is_root_bound = true
	return ""
}

// lsp_start_background brings the parent link up and starts the heartbeat.
// The MCP child runs this before serving; the LSP child's root only exists
// at initialize, so the link comes up inside the initialize callback,
// bounded by the connect budget. A non-empty result is the
// initialize-facing error message.
lsp_start_background :: proc(h: ^Lsp_Host) -> string {
	a := h.app
	if a.cfg.is_in_process {
		if !start_in_process_daemon(a) {
			return "cannot start the in-process daemon"
		}
	} else {
		if !connect_parent(a, SPAWN_ATTEMPTS) {
			return "cannot reach or spawn the project daemon"
		}
	}
	a.hb_thread = thread.create_and_start_with_poly_data(a, heartbeat_entry, self_cleanup = false, name = "aubade-lsp-hb-client")
	return ""
}

// ---------------------------------------------------------------------------
// lspserver host callbacks
// ---------------------------------------------------------------------------

host_lsp_initialize :: proc(host: rawptr, root_uri: string, workspace_folders: []string, arena: mem.Allocator) -> string {
	_ = arena
	h := cast(^Lsp_Host)host
	if h.is_root_bound {
		return "" // an explicit --project was bound at startup
	}
	root := ""
	if root_uri != "" {
		p, ok := lsp.uri_to_path(root_uri, context.temp_allocator)
		if !ok {
			return strings.concatenate({"initialize rootUri is not a file URI: ", root_uri}, context.temp_allocator)
		}
		root = p
	} else if len(workspace_folders) > 0 && workspace_folders[0] != "" {
		p, ok := lsp.uri_to_path(workspace_folders[0], context.temp_allocator)
		if !ok {
			return strings.concatenate({"initialize workspace folder is not a file URI: ", workspace_folders[0]}, context.temp_allocator)
		}
		root = p
	} else {
		return "no project root: initialize carried neither rootUri nor workspace folders, and no --project was given"
	}
	if msg := lsp_bind_root(h, root); msg != "" {
		return msg
	}
	return lsp_start_background(h)
}

host_lsp_doc_open :: proc(host: rawptr, uri: string, language_id: string, version: i32, text: string) {
	h := cast(^Lsp_Host)host
	rel := lsp_rel_path(h, uri)
	if rel == "" {
		return
	}
	conn := lsp_parent_conn(h)
	if conn == nil {
		// Link down: dropped, not queued. Full sync carries state, so
		// the next change after the heartbeat reconnects recovers the
		// document.
		return
	}
	// The editor's applyEdit capability bits ride the open: the
	// face negotiated them at initialize, which strictly precedes any
	// didOpen, so they are settled by the time the daemon can route
	// anything here.
	apply_caps, doc_changes_caps := lspserver.server_apply_caps(h.server)
	guard := lsp_call_begin(h)
	cc := svc.client_doc_open(conn, rel, language_id, version, text, context.temp_allocator, platform.mono_ms() + LSP_DOC_CALL_DEADLINE_MS, guard.token, apply_caps, doc_changes_caps)
	lsp_call_end(h, guard)
	if cc.call_err != .None {
		lsp_log(fmt.aprintf("svc.doc/open failed for %s: %s", rel, cc.err_message, allocator = context.temp_allocator))
		return
	}
	// The applied document joins the publish debounce window: the mark
	// follows the accepted state, so a fire's fetch reads what the client
	// last sent. Time rides the injected clock (the window's source).
	lspserver.publish_mark(h.server, uri, platform.clock_now(h.app.clock))

	// The document's language joins the relay bookkeeping — only after the
	// daemon accepted the open, so a failed sync never starts a server for
	// a document the daemon does not hold. A record seen first time arms
	// Pending (the starter will start the language's server); Failed
	// re-arms Pending (a later didOpen retries a transient spawn failure);
	// NoServer stays latched (the daemon knows no server for the language).
	if language_id != "" {
		sync.mutex_lock(&h.mu)
		if e, ok := h.relay[language_id]; ok {
			if e.state == .Failed {
				e.state = .Pending
				h.relay[language_id] = e
				h.relay_dirty = true
			}
		} else {
			key := strings.clone(language_id, h.app.allocator)
			h.relay[key] = Relay_Lang{state = .Pending}
			h.relay_dirty = true
		}
		sync.mutex_unlock(&h.mu)
	}
}

host_lsp_doc_change :: proc(host: rawptr, uri: string, version: i32, text: string) {
	h := cast(^Lsp_Host)host
	rel := lsp_rel_path(h, uri)
	if rel == "" {
		return
	}
	conn := lsp_parent_conn(h)
	if conn == nil {
		return // recovered by the next full text after reconnect (see above)
	}
	guard := lsp_call_begin(h)
	cc := svc.client_doc_change(conn, rel, version, text, context.temp_allocator, platform.mono_ms() + LSP_DOC_CALL_DEADLINE_MS, guard.token)
	lsp_call_end(h, guard)
	if cc.call_err != .None {
		lsp_log(fmt.aprintf("svc.doc/change failed for %s: %s", rel, cc.err_message, allocator = context.temp_allocator))
		return
	}
	// Same mark rule as the open path: into the window only after the
	// daemon accepted the change, so the window's fire computes over
	// applied state and stamps its version truthfully.
	lspserver.publish_mark(h.server, uri, platform.clock_now(h.app.clock))
}

host_lsp_doc_close :: proc(host: rawptr, uri: string) {
	h := cast(^Lsp_Host)host
	rel := lsp_rel_path(h, uri)
	if rel == "" {
		return
	}
	conn := lsp_parent_conn(h)
	if conn == nil {
		return // the document stays open daemon-side; a re-open recovers
	}
	guard := lsp_call_begin(h)
	cc := svc.client_doc_close(conn, rel, context.temp_allocator, platform.mono_ms() + LSP_DOC_CALL_DEADLINE_MS, guard.token)
	lsp_call_end(h, guard)
	if cc.call_err != .None {
		lsp_log(fmt.aprintf("svc.doc/close failed for %s: %s", rel, cc.err_message, allocator = context.temp_allocator))
	}
}

host_lsp_highlights :: proc(host: rawptr, uri: string, arena: mem.Allocator) -> lspserver.Highlights_Result {
	hr: lspserver.Highlights_Result
	h := cast(^Lsp_Host)host
	rel := lsp_rel_path(h, uri)
	if rel == "" {
		hr.failed = true
		hr.err_message = "document is outside the project root"
		return hr
	}
	conn := lsp_parent_conn(h)
	if conn == nil {
		hr.failed = true
		hr.err_message = "the daemon link is down"
		return hr
	}
	guard := lsp_call_begin(h)
	cc := svc.client_doc_highlights(conn, rel, arena, platform.mono_ms() + LSP_HIGHLIGHTS_CALL_DEADLINE_MS, guard.token)
	lsp_call_end(h, guard)
	if cc.call_err != .None {
		hr.failed = true
		hr.err_message = cc.err_message
		return hr
	}

	if v, ok := jsonutil.obj_get(cc.result, "has_version"); ok {
		hr.has_version = jsonutil.value_bool(v)
	}
	if v, ok := jsonutil.obj_get(cc.result, "decline"); ok {
		hr.decline = jsonutil.value_str(v)
	}
	if v, ok := jsonutil.obj_get(cc.result, "captures"); ok {
		if items, is_arr := jsonutil.as_array(v); is_arr {
			dyn := make([dynamic]lspserver.Capture_Hit, 0, len(items), arena)
			for item in items {
				m, is_obj := jsonutil.as_object(item)
				if !is_obj {
					continue
				}
				hit: lspserver.Capture_Hit
				if nv, found := m["name"]; found {
					hit.capture = jsonutil.value_str(nv)
				}
				if sv, found := m["start_byte"]; found {
					hit.start_byte = int(jsonutil.value_int(sv))
				}
				if ev, found := m["end_byte"]; found {
					hit.end_byte = int(jsonutil.value_int(ev))
				}
				append(&dyn, hit)
			}
			hr.captures = dyn[:]
		}
	}
	return hr
}

host_lsp_log :: proc(host: rawptr, message: string) {
	_ = host
	lsp_log(message)
}

// host_lsp_diagnostics implements the face's Diagnostics_Host over
// svc.doc/diagnostics. The parsed answer keeps the response's version as
// data — the version the daemon's computation used, which the publish
// stamps instead of inferring from apply order.
host_lsp_diagnostics :: proc(host: rawptr, uri: string, arena: mem.Allocator) -> lspserver.Diagnostics_Result {
	dr: lspserver.Diagnostics_Result
	h := cast(^Lsp_Host)host
	rel := lsp_rel_path(h, uri)
	if rel == "" {
		dr.failed = true
		dr.err_message = "document is outside the project root"
		return dr
	}
	conn := lsp_parent_conn(h)
	if conn == nil {
		dr.failed = true
		dr.err_message = "the daemon link is down"
		return dr
	}
	guard := lsp_call_begin(h)
	cc := svc.client_doc_diagnostics(conn, rel, arena, platform.mono_ms() + LSP_DIAGNOSTICS_CALL_DEADLINE_MS, guard.token)
	lsp_call_end(h, guard)
	if cc.call_err != .None {
		dr.failed = true
		dr.err_message = cc.err_message
		return dr
	}

	if v, ok := jsonutil.obj_get(cc.result, "version"); ok {
		dr.version = i32(jsonutil.value_int(v))
	}
	if v, ok := jsonutil.obj_get(cc.result, "has_version"); ok {
		dr.has_version = jsonutil.value_bool(v)
	}
	if v, ok := jsonutil.obj_get(cc.result, "decline"); ok {
		dr.decline = jsonutil.value_str(v)
	}
	if v, ok := jsonutil.obj_get(cc.result, "truncated"); ok {
		dr.truncated = jsonutil.value_bool(v)
	}
	if v, ok := jsonutil.obj_get(cc.result, "diagnostics"); ok {
		if items, is_arr := jsonutil.as_array(v); is_arr {
			dyn := make([dynamic]lspserver.Diag_Hit, 0, len(items), arena)
			for item in items {
				m, is_obj := jsonutil.as_object(item)
				if !is_obj {
					continue
				}
				hit: lspserver.Diag_Hit
				if sv, found := m["start_byte"]; found {
					hit.start_byte = int(jsonutil.value_int(sv))
				}
				if ev, found := m["end_byte"]; found {
					hit.end_byte = int(jsonutil.value_int(ev))
				}
				if mv, found := m["message"]; found {
					hit.message = jsonutil.value_str(mv)
				}
				append(&dyn, hit)
			}
			dr.diagnostics = dyn[:]
		}
	}
	return dr
}

// host_lsp_readiness implements the face's Readiness_Host over the
// existing svc.langserver/list read: a language is live when a row names
// it with running=true. No row, no {items} member (the empty-hint
// message shape), or a failed call all read as not-live — the
// tree-sitter answer is the safe default, and a failed call's cause
// surfaces through the diagnostics fetch that follows.
host_lsp_readiness :: proc(host: rawptr, language_id: string, arena: mem.Allocator) -> lspserver.Readiness_Result {
	rr: lspserver.Readiness_Result
	h := cast(^Lsp_Host)host
	conn := lsp_parent_conn(h)
	if conn == nil {
		rr.failed = true
		rr.err_message = "the daemon link is down"
		return rr
	}
	guard := lsp_call_begin(h)
	cc := svc.client_langserver_list(conn, arena, platform.mono_ms() + LSP_DIAGNOSTICS_CALL_DEADLINE_MS, guard.token)
	lsp_call_end(h, guard)
	if cc.call_err != .None {
		rr.failed = true
		rr.err_message = cc.err_message
		return rr
	}
	if v, ok := jsonutil.obj_get(cc.result, "items"); ok {
		if items, is_arr := jsonutil.as_array(v); is_arr {
			for item in items {
				m, is_obj := jsonutil.as_object(item)
				if !is_obj {
					continue
				}
				lang := ""
				if lv, found := m["language"]; found {
					lang = jsonutil.value_str(lv)
				}
				if lang != language_id {
					continue
				}
				if rv, found := m["running"]; found && jsonutil.value_bool(rv) {
					rr.live = true
					return rr
				}
			}
		}
	}
	return rr
}

// ---------------------------------------------------------------------------
// The publish shell
// ---------------------------------------------------------------------------

// lsp_publish_entry is the debounce shell: it sleeps on the injected clock
// until the earliest due document (or the idle cadence, whichever comes
// first) and fires the face's pass. The pass itself is pure against a now
// value; this thread only decides when now has come. The session root
// token ends the loop — the dispatch loop fires it on every shutdown path,
// and the teardown joins this thread before the face is destroyed.
lsp_publish_entry :: proc(h: ^Lsp_Host) {
	for !platform.token_is_fired(h.app.root) {
		now := platform.clock_now(h.app.clock)
		target := now + LSP_PUBLISH_IDLE_POLL_MS
		if next, has := lspserver.publish_next_due(h.server); has && next < target {
			target = next
		}
		if !platform.clock_wait_sliced_until(h.app.clock, h.app.root, target) {
			return // the root fired mid-wait
		}
		lsp_publish_pass(h)
	}
}

// lsp_publish_pass runs one fire pass on its own arena: the drained URIs,
// the snapshots, and the notification bodies all die with it, and the
// long-lived thread's temp resets between passes (the host callbacks
// scratch on it).
lsp_publish_pass :: proc(h: ^Lsp_Host) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, h.app.allocator)
	lspserver.publish_due(h.server, platform.clock_now(h.app.clock), mem.dynamic_arena_allocator(&arena))
	mem.dynamic_arena_destroy(&arena)
	free_all(context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Host helpers
// ---------------------------------------------------------------------------

// lsp_rel_path decodes a client document URI into its project-relative
// path. The root compare uses the canonical (symlink-resolved) root
// spelling; "" means "not a project document" — non-file schemes and
// external paths included — and the caller drops the message. The result
// borrows the temp allocator and is consumed within the callback.
lsp_rel_path :: proc(h: ^Lsp_Host, uri: string) -> string {
	path, ok := lsp.uri_to_path(uri, context.temp_allocator)
	if !ok {
		lsp_log(fmt.aprintf("document URI is not a file URI: %s", uri, allocator = context.temp_allocator))
		return ""
	}
	rel := lsp.rel_path_for_root(h.app.cfg.project_root, path)
	if rel == "" {
		lsp_log(fmt.aprintf("document %s is outside the project root; dropped", uri, allocator = context.temp_allocator))
		return ""
	}
	return rel
}

// lsp_parent_conn snapshots the current parent link under its mutex.
// Returning nil means the link is down; callers decide between dropping
// (notifications) and failing the request (highlights).
lsp_parent_conn :: proc(h: ^Lsp_Host) -> ^jsonrpc.Conn {
	sync.mutex_lock(&h.app.parent_mu)
	conn := h.app.parent
	sync.mutex_unlock(&h.app.parent_mu)
	return conn
}

// The out-going svc call bracket: a cancel token derived from the session
// root and registered in the shared call registry, so a concurrent link
// teardown fires it and the abort/drain ladder in retire_link waits for
// the call to leave the conn before destroying it — the same bracket the
// MCP dispatch builds around tool calls.
Lsp_Call_Guard :: struct {
	id:    jsonrpc.Id,
	token: ^platform.Cancel_Token,
}

lsp_call_begin :: proc(h: ^Lsp_Host) -> Lsp_Call_Guard {
	// Both the dispatch thread and the publish shell bracket svc calls
	// here, so the synthetic id moves under h.mu (the registry map itself
	// locks inside host_register). It keys the registry only — the svc
	// conn numbers its own requests.
	sync.mutex_lock(&h.mu)
	h.next_call_id += 1
	id: jsonrpc.Id
	id = h.next_call_id
	sync.mutex_unlock(&h.mu)
	token := platform.token_derive(h.app.root, 0, h.app.cancel_alloc)
	host_register(h.app, id, token)
	return Lsp_Call_Guard{id = id, token = token}
}

lsp_call_end :: proc(h: ^Lsp_Host, guard: Lsp_Call_Guard) {
	host_deregister(h.app, guard.id, guard.token)
	platform.token_destroy(guard.token, h.app.cancel_alloc)
}

lsp_log :: proc(message: string) {
	util.log_warning(message)
}

// ---------------------------------------------------------------------------
// The aggregation relay: push handlers, per-language state, the starter
// thread, and the Relay_Host implementations
// ---------------------------------------------------------------------------

// Relay_State is one language's real-server lifecycle as this child sees
// it. The daemon owns the truth; these records drive when THIS child starts
// servers and registers capabilities.
Relay_State :: enum {
	Pending,  // a document of the language is open here; start not yet attempted
	Starting, // a start call is in flight on the starter thread
	Ready,    // the daemon reports the server running; the caps bits are meaningful
	NoServer, // the daemon knows no server for the language; latched (config, not luck)
	Failed,   // a start failed, or a running=false transition landed; a later didOpen re-arms
}

Relay_Lang :: struct {
	state:         Relay_State,
	references:    bool, // the running server's capability bits (meaningful while Ready)
	declaration:   bool,
	is_registered: bool,
}

// lsp_wire_parent_conn is the App's parent_conn_wire hook: it runs at EVERY
// parent-link establishment (connect_parent's success path and the
// in-process daemon), because the heartbeat ladder retires and rebuilds the
// link — handlers registered only on the first conn would go deaf after
// the first reconnect. The LSP host rides across type-erased in
// App.host_face and becomes the new conn's dispatch host (the same
// rawptr+cast pattern as the face's conn.host). The handlers run on the
// parent reader thread; conn_read_loop already gives each message its own
// arena and resets the thread's temp per frame.
lsp_wire_parent_conn :: proc(a: ^App, conn: ^jsonrpc.Conn) {
	h := cast(^Lsp_Host)a.host_face
	if h == nil {
		return
	}
	conn.host = h
	jsonrpc.conn_register_notification(conn, svc.METHOD_PUSH_DIAGNOSTICS, handle_push_diagnostics)
	jsonrpc.conn_register_notification(conn, svc.METHOD_PUSH_LANGSERVER_STATE, handle_push_langserver_state)
	// The two-writer round trip's request leg. Unlike the pushes it
	// is a REQUEST: the handler only queues the job — the reply is sent
	// from the apply worker, after the editor answered the face's
	// workspace/applyEdit.
	jsonrpc.conn_register(conn, svc.METHOD_EDIT_APPLY, handle_edit_apply)
}

// ---------------------------------------------------------------------------
// The apply worker (svc.edit/apply -> workspace/applyEdit)
// ---------------------------------------------------------------------------

// Apply_Job is one queued svc.edit/apply. Its params are deep-cloned into
// the job's own arena — the request's frame arena dies with the reader
// dispatch — and the call guard pins the parent link against teardown
// until the worker has answered.
Apply_Job :: struct {
	conn:   ^jsonrpc.Conn, // the parent conn the request rode in on
	id:     jsonrpc.Id,
	id_set: bool,
	params: json.Value,
	arena:  ^mem.Dynamic_Arena,
	guard:  Lsp_Call_Guard,
}

// handle_edit_apply validates the request shape, clones it into a job, and
// enqueues. Runs on the parent reader thread; nothing here waits on the
// editor. Malformed params answer in place (Invalid_Params); a full queue
// answers Request_Failed — the daemon's router maps a failed call to an
// explicit, retryable edit failure, never to a direct write.
handle_edit_apply :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	_ = arena
	h := cast(^Lsp_Host)conn.host
	if h == nil {
		reply: jsonrpc.Reply = {is_error = true, err_code = .Internal_Error, err_message = "the apply worker is not running"}
		return reply, .Respond
	}
	if _, ok := jsonutil.obj_get(env.params, "document_changes"); !ok {
		reply: jsonrpc.Reply = {is_error = true, err_code = .Invalid_Params, err_message = "document_changes is required"}
		return reply, .Respond
	}

	job_arena := new(mem.Dynamic_Arena, h.app.allocator)
	mem.dynamic_arena_init(job_arena, h.app.allocator)
	ja := mem.dynamic_arena_allocator(job_arena)
	id: jsonrpc.Id
	switch v in env.id {
	case i64:
		id = v
	case string:
		id = strings.clone(v, ja)
	}
	job := new(Apply_Job, h.app.allocator)
	job^ = {
		conn   = conn,
		id     = id,
		id_set = env.id_set,
		params = jsonutil.clone_value(env.params, ja),
		arena  = job_arena,
		guard  = lsp_call_begin(h),
	}
	if !chan.try_send(chan.as_send(h.apply_jobs), job) {
		lsp_call_end(h, job.guard)
		mem.dynamic_arena_destroy(job_arena)
		free(job_arena, h.app.allocator)
		free(job, h.app.allocator)
		free_all(context.temp_allocator)
		reply: jsonrpc.Reply = {is_error = true, err_code = .Request_Failed, err_message = "the apply queue is full"}
		return reply, .Respond
	}
	reply: jsonrpc.Reply
	return reply, .Defer
}

// lsp_apply_entry drains the queue: one editor round trip at a time, the
// job arena dying with the job. Long-lived-thread scratch resets between
// jobs.
lsp_apply_entry :: proc(h: ^Lsp_Host) {
	recv := chan.as_recv(h.apply_jobs)
	for {
		job, ok := chan.recv(recv)
		if !ok {
			break
		}
		lsp_apply_run(h, job)
	}
}

// lsp_apply_run forwards one job through the face and sends the answer
// over the request's own conn. The guard is released after the reply:
// teardown (retire_link) waits on it, so the conn outlives the send.
lsp_apply_run :: proc(h: ^Lsp_Host, job: ^Apply_Job) {
	ja := mem.dynamic_arena_allocator(job.arena)
	// A fired session root means the dispatch loop is gone: no editor reply
	// can arrive anymore, so the workspace/applyEdit leg would wait out its
	// whole budget per queued job for an answer that never comes. Refuse at
	// once instead — still through conn_send_reply, so the daemon's waiting
	// router unblocks, with the guard and the arena released in the same
	// order as a served job.
	applied, reason := false, "shutting down"
	if !platform.token_is_fired(h.app.root) {
		applied, reason = lspserver.server_apply_edits(h.server, job.params, ja, LSP_APPLY_CALL_DEADLINE_MS)
	}
	result := jsonutil.json_object(2, ja)
	jsonutil.obj_set(&result, "applied", jsonutil.json_bool(applied))
	if reason != "" {
		jsonutil.obj_set(&result, "reason", jsonutil.json_string(reason))
	}
	reply: jsonrpc.Reply = {result = json.Value(json.Object(result))}
	jsonrpc.conn_send_reply(job.conn, job.id, job.id_set, reply, ja)
	lsp_call_end(h, job.guard)
	mem.dynamic_arena_destroy(job.arena)
	free(job.arena, h.app.allocator)
	free(job, h.app.allocator)
	free_all(context.temp_allocator)
}

// handle_push_diagnostics republishes the daemon's stored real-LS
// diagnostic set for one URI onto the editor pipe. Foreign URIs (non-file
// schemes, paths outside the project root) and documents this child does
// not hold open drop silently — the daemon may serve other children.
handle_push_diagnostics :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) {
	h := cast(^Lsp_Host)conn.host
	if h == nil {
		return
	}
	uri := ""
	items := ""
	if v, ok := jsonutil.obj_get(env.params, "uri"); ok {
		uri = jsonutil.value_str(v)
	}
	if v, ok := jsonutil.obj_get(env.params, "items"); ok {
		items = jsonutil.value_str(v)
	}
	if uri == "" || items == "" {
		lsp_log("svc.push/diagnostics carried malformed params; dropped")
		return
	}
	path, ok := lsp.uri_to_path(uri, arena)
	if !ok {
		return
	}
	rel := lsp.rel_path_for_root(h.app.cfg.project_root, path)
	if rel == "" {
		return
	}
	// The face republishes under the view's own spelling and version: the
	// editor's number space, never the daemon mirror's.
	view_uri := lsp_view_uri_for_rel(h, rel, arena)
	if view_uri == "" {
		return
	}
	lspserver.publish_relay_diagnostics(h.server, view_uri, items, arena)
}

// handle_push_langserver_state upserts one language's running transition.
// running=true lands as Ready with the server's capability bits;
// running=false lands as Failed (down until a later didOpen re-arms it or
// a running=true push arrives — the daemon's own document re-sync recovers
// restarted servers, so this child does not race it with auto-restarts).
handle_push_langserver_state :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) {
	_ = arena
	h := cast(^Lsp_Host)conn.host
	if h == nil {
		return
	}
	language := ""
	if v, ok := jsonutil.obj_get(env.params, "language"); ok {
		language = jsonutil.value_str(v)
	}
	if language == "" {
		lsp_log("svc.push/langserver_state carried no language; dropped")
		return
	}
	running := jsonutil.obj_get_bool(env.params, "running")
	references := jsonutil.obj_get_bool(env.params, "references")
	declaration := jsonutil.obj_get_bool(env.params, "declaration")
	running_state: Relay_State = .Failed
	if running {
		running_state = .Ready
	}

	sync.mutex_lock(&h.mu)
	if e, ok := h.relay[language]; ok {
		if running {
			e.state = .Ready
			e.references = references
			e.declaration = declaration
		} else {
			e.state = .Failed
		}
		h.relay[language] = e
		h.relay_dirty = true
	} else {
		// A transition for a language this child never opened: record it,
		// so a later didOpen starts from the live state instead of a guess.
		key := strings.clone(language, h.app.allocator)
		h.relay[key] = Relay_Lang{state = running_state, references = references, declaration = declaration}
		h.relay_dirty = true
	}
	sync.mutex_unlock(&h.mu)
}

// lsp_view_uri_for_rel finds the open view whose document is `rel` and
// returns its client-facing uri ("" when this child holds no such view).
// The view set is the one place the editor's spelling lives. Single-shot
// callers (one document per push notification) resolve directly; per-item
// answer paths go through Relay_Uri_Table instead, so the set decodes once
// per request rather than once per location.
lsp_view_uri_for_rel :: proc(h: ^Lsp_Host, rel: string, arena: mem.Allocator) -> string {
	uris := lspserver.server_view_uris(h.server, arena)
	for u in uris {
		p, ok := lsp.uri_to_path(u, arena)
		if !ok {
			continue
		}
		if lsp.rel_path_for_root(h.app.cfg.project_root, p) == rel {
			return u
		}
	}
	return ""
}

// Relay_Uri_Table is one request's snapshot of the open-view set: each
// view uri decoded and matched to its project-relative path once, so an
// answer with many locations resolves every item against the prebuilt
// pairs instead of re-decoding the whole set per item. The strings borrow
// the request's arena.
Relay_Uri_Table :: struct {
	uris: []string, // the open views' client-facing spellings
	rels: []string, // parallel to uris; "" marks a uri outside the root
}

// relay_uri_table_build snapshots the open-view set once per request or
// operation.
relay_uri_table_build :: proc(h: ^Lsp_Host, arena: mem.Allocator) -> Relay_Uri_Table {
	uris := lspserver.server_view_uris(h.server, arena)
	rels := make([]string, len(uris), arena)
	for u, i in uris {
		if p, ok := lsp.uri_to_path(u, arena); ok {
			rels[i] = lsp.rel_path_for_root(h.app.cfg.project_root, p)
		}
	}
	return Relay_Uri_Table{uris = uris, rels = rels}
}

// relay_uri_table_find returns the open view whose document is rel
// ("" when the snapshot holds no such view).
relay_uri_table_find :: proc(t: Relay_Uri_Table, rel: string) -> string {
	for r, i in t.rels {
		if r == rel {
			return t.uris[i]
		}
	}
	return ""
}

// lsp_relay_client_uri spells one answer document the way the editor sees
// it: the open view's own uri when this child holds the document (matched
// through the request's view table), the canonical root-relative file URI
// otherwise (the project root's symlink-resolved spelling — guard outputs
// and URI renders must agree). "" when the rel escapes the root: the
// caller drops the location rather than emit an unresolvable one.
lsp_relay_client_uri :: proc(h: ^Lsp_Host, views: Relay_Uri_Table, rel: string, arena: mem.Allocator) -> string {
	if rel == "" {
		return ""
	}
	if u := relay_uri_table_find(views, rel); u != "" {
		return u
	}
	abs, perr := safety.pathguard_validate_contained(h.app.cfg.project_root, rel, arena)
	if perr.reason != "" {
		return ""
	}
	return symbol.file_uri(abs, arena)
}

// lsp_relay_entry is the starter shell: it wakes on the session root's
// cadence (the same sliced-wait shape as the publish shell) and runs one
// pass per wake. The teardown joins it before the face is destroyed.
lsp_relay_entry :: proc(h: ^Lsp_Host) {
	for !platform.token_is_fired(h.app.root) {
		target := platform.clock_now(h.app.clock) + LSP_RELAY_IDLE_POLL_MS
		if !platform.clock_wait_sliced_until(h.app.clock, h.app.root, target) {
			return // the root fired mid-wait
		}
		lsp_relay_pass(h)
		// Pass scratch (svc params, registration ids) must not accumulate
		// across passes on this long-lived thread.
		free_all(context.temp_allocator)
	}
}

// lsp_relay_pass is one starter pass: Pendings move to Starting and their
// start calls run outside the lock; then the registration sweep reads the
// fresh states — Ready-but-unregistered languages register (one batch call
// each), registered-but-down languages unregister. A failed registration
// stays unregistered without re-marking dirty: only a state change
// re-drives it (no spin). Registration activity stops once the face is
// shutdown. The pass arena holds the cloned language names and the
// registration ids; the long-lived thread's temp resets after.
lsp_relay_pass :: proc(h: ^Lsp_Host) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, h.app.allocator)
	a := mem.dynamic_arena_allocator(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	sync.mutex_lock(&h.mu)
	if !h.relay_dirty {
		sync.mutex_unlock(&h.mu)
		return
	}
	h.relay_dirty = false
	pending := make([dynamic]string, 0, 4, a)
	for lang, rec in h.relay {
		if rec.state == .Pending {
			append(&pending, strings.clone(lang, a))
			starting := rec
			starting.state = .Starting
			h.relay[lang] = starting
		}
	}
	sync.mutex_unlock(&h.mu)

	for lang in pending {
		lsp_relay_start(h, lang, a)
	}

	if lspserver.server_is_shutdown(h.server) {
		return
	}
	reg_wanted := make([dynamic]string, 0, 4, a)
	reg_drop := make([dynamic]string, 0, 4, a)
	sync.mutex_lock(&h.mu)
	for lang, e in h.relay {
		if e.state == .Ready && !e.is_registered {
			append(&reg_wanted, strings.clone(lang, a))
		} else if e.is_registered && e.state != .Ready {
			append(&reg_drop, strings.clone(lang, a))
		}
	}
	sync.mutex_unlock(&h.mu)
	for lang in reg_drop {
		lsp_relay_unregister(h, lang, a)
	}
	for lang in reg_wanted {
		lsp_relay_register(h, lang, a)
	}
}

// lsp_relay_start moves one Starting language through svc.langserver/start.
// A NotFound-shaped refusal (the daemon maps its NotFound kind onto
// Method_Not_Found on the wire) latches NoServer — the daemon knows no
// server for the language, and retrying would only grind; any other
// failure lands as Failed with one log line.
lsp_relay_start :: proc(h: ^Lsp_Host, language: string, a: mem.Allocator) {
	conn := lsp_parent_conn(h)
	if conn == nil {
		// Link down: back to Pending so the next pass retries once the
		// heartbeat re-establishes the link.
		sync.mutex_lock(&h.mu)
		if e, ok := h.relay[language]; ok && e.state == .Starting {
			e.state = .Pending
			h.relay[language] = e
			h.relay_dirty = true
		}
		sync.mutex_unlock(&h.mu)
		return
	}
	guard := lsp_call_begin(h)
	cc := svc.client_langserver_start(conn, language, a, platform.mono_ms() + LSP_START_CALL_DEADLINE_MS, guard.token)
	lsp_call_end(h, guard)
	if cc.call_err != .None {
		state: Relay_State = .Failed
		if cc.call_err == .Error_Response && cc.err_code == .Method_Not_Found {
			state = .NoServer
		}
		sync.mutex_lock(&h.mu)
		if e, ok := h.relay[language]; ok && e.state == .Starting {
			e.state = state
			h.relay[language] = e
		}
		sync.mutex_unlock(&h.mu)
		lsp_log(fmt.aprintf("relay start for %s failed: %s", language, cc.err_message, allocator = context.temp_allocator))
		return
	}
	references := jsonutil.obj_get_bool(cc.result, "references")
	declaration := jsonutil.obj_get_bool(cc.result, "declaration")
	sync.mutex_lock(&h.mu)
	if e, ok := h.relay[language]; ok && e.state == .Starting {
		e.state = .Ready
		e.references = references
		e.declaration = declaration
		h.relay[language] = e
		h.relay_dirty = true
	}
	sync.mutex_unlock(&h.mu)
}

// lsp_relay_register issues ONE client/registerCapability for a Ready
// language: the batch lsp_relay_batch lists. Re-reads the record under mu
// first — a state push may have landed while the starts above ran.
lsp_relay_register :: proc(h: ^Lsp_Host, language: string, a: mem.Allocator) {
	sync.mutex_lock(&h.mu)
	e := h.relay[language]
	sync.mutex_unlock(&h.mu)
	if e.state != .Ready || e.is_registered {
		return
	}
	regs := lsp_relay_batch(e, language, a)
	if !lspserver.server_register_capabilities(h.server, regs, a, LSP_REGISTER_CALL_DEADLINE_MS) {
		lsp_log(fmt.aprintf("capability registration for %s failed; left unregistered until its state changes", language, allocator = context.temp_allocator))
		return
	}
	sync.mutex_lock(&h.mu)
	// The latch is unconditional on call success: a running=false push may
	// have landed inside the registration round trip, and a record left
	// unregistered here would be invisible to the sweep's drop criterion
	// (registered but not Ready) — the editor would keep the registrations
	// with no withdrawal ever issued. The sweep withdrawing by that
	// criterion is what retires them.
	if cur, ok := h.relay[language]; ok {
		cur.is_registered = true
		h.relay[language] = cur
	}
	sync.mutex_unlock(&h.mu)
}

// lsp_relay_unregister withdraws a registered language's registrations when
// its server went down (the running=false push moved it out of Ready). The
// batch mirrors what the registration covered. The record leaves
// is_registered either way — a failed call is logged, not retried; the
// language's next Ready transition re-registers from scratch.
lsp_relay_unregister :: proc(h: ^Lsp_Host, language: string, a: mem.Allocator) {
	sync.mutex_lock(&h.mu)
	e := h.relay[language]
	sync.mutex_unlock(&h.mu)
	if !e.is_registered {
		return
	}
	regs := lsp_relay_batch(e, language, a)
	if !lspserver.server_unregister_capabilities(h.server, regs, a, LSP_REGISTER_CALL_DEADLINE_MS) {
		lsp_log(fmt.aprintf("capability unregistration for %s failed; the editor keeps the stale registration until its next state change", language, allocator = context.temp_allocator))
	}
	sync.mutex_lock(&h.mu)
	if cur, ok := h.relay[language]; ok {
		cur.is_registered = false
		h.relay[language] = cur
	}
	sync.mutex_unlock(&h.mu)
}

// lsp_relay_batch lists one language's full registration set — the batch
// the register and unregister sweeps share, so a withdrawal always mirrors
// what was registered: definition always, references/declaration behind
// the server's capability bits, and the four langserver faces
// (formatting, code actions, inlay hints, call hierarchy) unconditionally
// — the handshake's capability view carries no bits for them, so an
// unsupported face fails at call time into an empty answer.
lsp_relay_batch :: proc(e: Relay_Lang, language: string, a: mem.Allocator) -> []lspserver.Capability_Registration {
	regs := make([dynamic]lspserver.Capability_Registration, 0, 7, a)
	append(&regs, lsp_relay_registration(language, .Definition, a))
	if e.references {
		append(&regs, lsp_relay_registration(language, .References, a))
	}
	if e.declaration {
		append(&regs, lsp_relay_registration(language, .Declaration, a))
	}
	append(&regs, lsp_ops_registration(language, lsp.METHOD_FORMATTING, "formatting", a))
	append(&regs, lsp_ops_registration(language, lsp.METHOD_CODE_ACTION, "codeAction", a))
	append(&regs, lsp_ops_registration(language, lsp.METHOD_INLAY_HINT, "inlayHint", a))
	append(&regs, lsp_ops_registration(language, lsp.METHOD_PREPARE_CALL_HIERARCHY, "prepareCallHierarchy", a))
	return regs[:]
}

// lsp_relay_registration builds one registration/unregistration record:
// id aubade.relay.<language>.<base>.
lsp_relay_registration :: proc(language: string, kind: lspserver.Relay_Kind, a: mem.Allocator) -> lspserver.Capability_Registration {
	method, base := "", ""
	switch kind {
	case .Definition:
		method, base = lsp.METHOD_DEFINITION, "definition"
	case .References:
		method, base = lsp.METHOD_REFERENCES, "references"
	case .Declaration:
		method, base = lsp.METHOD_DECLARATION, "declaration"
	}
	return lsp_ops_registration(language, method, base, a)
}

// lsp_ops_registration builds one registration record from its method and
// id basename — the shape lsp_relay_registration maps the position-relay
// kinds onto, shared so the id namespace stays one spelling.
lsp_ops_registration :: proc(language: string, method, base: string, a: mem.Allocator) -> lspserver.Capability_Registration {
	return lspserver.Capability_Registration{
		id       = strings.concatenate({RELAY_REGISTRATION_PREFIX, language, ".", base}, a),
		method   = method,
		language = language,
	}
}

// ---------------------------------------------------------------------------
// The Relay_Host implementations
// ---------------------------------------------------------------------------

// host_lsp_relay resolves one position into the daemon's symbol inventory:
// svc.symbol/list for the document (one round trip), the position walked
// down the outline JSON tree to a symbol, then the per-kind face on top.
// Misses and failures answer empty locations — the editor's request is
// never answered with an error response; failures log once per request
// through Relay_Result.failed.
host_lsp_relay :: proc(host: rawptr, uri: string, line: int, col_utf16: int, include_declaration: bool, kind: lspserver.Relay_Kind, arena: mem.Allocator) -> lspserver.Relay_Result {
	r: lspserver.Relay_Result
	h := cast(^Lsp_Host)host
	rel := lsp_rel_path(h, uri)
	if rel == "" {
		return r // outside the project root; lsp_rel_path logged
	}
	conn := lsp_parent_conn(h)
	if conn == nil {
		r.failed = true
		r.err_message = "the daemon link is down"
		return r
	}
	// One guard brackets the whole request, not just the first call: the
	// conn snapshot above is re-used by the References/Declaration legs
	// after the unbounded outline walk, and the guard's registry entry is
	// what keeps that conn provably alive across the walk — retire_link
	// drains the registry (waiting for this entry's deregister) before it
	// may destroy the conn, so a teardown landing mid-request cannot free
	// it. The legs take this guard and begin none of their own.
	guard := lsp_call_begin(h)
	defer lsp_call_end(h, guard)
	cc := svc.client_symbol_list(conn, rel, arena, platform.mono_ms() + LSP_RELAY_CALL_DEADLINE_MS, guard.token)
	if cc.call_err != .None {
		r.failed = true
		r.err_message = cc.err_message
		return r
	}
	symbols_v, ok := jsonutil.obj_get(cc.result, "symbols")
	if !ok {
		return r
	}
	roots, is_arr := jsonutil.as_array(symbols_v)
	if !is_arr {
		return r
	}

	// The position ladder, mirroring the daemon's symbol_at_position
	// semantics exactly: the deepest selectionRange containing the
	// position wins, then the deepest full range containing it, then the
	// first symbol whose range starts exactly at it (selection starts
	// before full-range starts). Deepest = the candidate whose range
	// starts latest — a child's range never starts before its parent's.
	// The name path builds during the descent ("/"-joined,
	// outermost-first, empty names skipped — the spelling
	// symbol_full_name_path renders daemon-side), so the hit resolves
	// through the existing symbol faces without a second walk.
	walk := Relay_Walk{arena = arena, line = line, col = col_utf16}
	relay_walk(roots, "", &walk)

	hit, hit_path := relay_pick_hit(&walk)
	if hit == nil {
		return r // no symbol at the position: an ordinary empty answer
	}

	// The answer spellings resolve against one snapshot of the open-view
	// set, however many locations the legs below produce.
	views := relay_uri_table_build(h, arena)

	switch kind {
	case .Definition:
		// The hit symbol's own location: its selection range (the
		// identifier) when the outline carries one, its full range
		// otherwise — has_end carries a real range here.
		node_rel := rel
		if lv, have_loc := jsonutil.obj_get(hit, "location"); have_loc {
			if rp, found := jsonutil.obj_get(lv, "rel_path"); found {
				if s := jsonutil.value_str(rp); s != "" {
					node_rel = s
				}
			}
		}
		answer_rng := relay_hit_range(hit)
		if answer_rng == nil {
			return r
		}
		loc: lspserver.Relay_Location
		loc.line, loc.col, loc.end_line, loc.end_col = relay_range_bounds(answer_rng)
		loc.has_end = true
		loc.uri = lsp_relay_client_uri(h, views, node_rel, arena)
		if loc.uri == "" {
			return r
		}
		locs := make([dynamic]lspserver.Relay_Location, 0, 1, arena)
		append(&locs, loc)
		r.locations = locs[:]
	case .References:
		r.locations = relay_locations_for_references(h, conn, guard, views, hit_path, rel, include_declaration, arena, &r)
	case .Declaration:
		r.locations = relay_locations_for_declaration(h, conn, guard, views, hit_path, rel, arena, &r)
	}
	return r
}

// relay_locations_for_references runs svc.symbol/find_references and maps
// the items onto point locations. include_declaration is the request's
// context.includeDeclaration — the same switch the daemon's include_self
// applies to the symbol's own declaration site. The guard is the request's
// own bracket (host_lsp_relay): this leg rides its registry entry, so the
// conn cannot be retired under the call. A failed call marks `r` failed
// and answers nil.
relay_locations_for_references :: proc(
	h: ^Lsp_Host,
	conn: ^jsonrpc.Conn,
	guard: Lsp_Call_Guard,
	views: Relay_Uri_Table,
	name_path, rel: string,
	include_declaration: bool,
	arena: mem.Allocator,
	r: ^lspserver.Relay_Result,
) -> []lspserver.Relay_Location {
	locs := make([dynamic]lspserver.Relay_Location, 0, 4, arena)
	cc := svc.client_symbol_find_references(
		conn, name_path, rel,
		false, include_declaration, false,
		nil, nil,
		arena, platform.mono_ms() + LSP_RELAY_CALL_DEADLINE_MS, guard.token,
	)
	if cc.call_err != .None {
		r.failed = true
		r.err_message = cc.err_message
		return nil
	}
	items_v, ok := jsonutil.obj_get(cc.result, "items")
	if !ok {
		return locs[:]
	}
	items, is_arr := jsonutil.as_array(items_v)
	if !is_arr {
		return locs[:]
	}
	for item in items {
		// The svc inventory carries the site as reference_line +
		// reference_col (both UTF-16); an answer without the column (an
		// older daemon) reads 0 through obj_get_int's absent default.
		rel_of := ""
		if v, found := jsonutil.obj_get(item, "relative_path"); found {
			rel_of = jsonutil.value_str(v)
		}
		line := int(jsonutil.obj_get_int(item, "reference_line"))
		col := int(jsonutil.obj_get_int(item, "reference_col"))
		uri := lsp_relay_client_uri(h, views, rel_of, arena)
		if uri == "" {
			continue
		}
		append(&locs, lspserver.Relay_Location{uri = uri, line = line, col = col, has_end = false, end_line = line, end_col = col})
	}
	return locs[:]
}

// relay_locations_for_declaration runs svc.symbol/find_declaration (its
// items carry line and col) and maps the entries onto point locations. The
// guard is the request's own bracket (see relay_locations_for_references).
relay_locations_for_declaration :: proc(
	h: ^Lsp_Host,
	conn: ^jsonrpc.Conn,
	guard: Lsp_Call_Guard,
	views: Relay_Uri_Table,
	name_path, rel: string,
	arena: mem.Allocator,
	r: ^lspserver.Relay_Result,
) -> []lspserver.Relay_Location {
	locs := make([dynamic]lspserver.Relay_Location, 0, 4, arena)
	cc := svc.client_symbol_find_declaration(conn, name_path, rel, arena, platform.mono_ms() + LSP_RELAY_CALL_DEADLINE_MS, guard.token)
	if cc.call_err != .None {
		r.failed = true
		r.err_message = cc.err_message
		return nil
	}
	items_v, ok := jsonutil.obj_get(cc.result, "items")
	if !ok {
		return locs[:]
	}
	items, is_arr := jsonutil.as_array(items_v)
	if !is_arr {
		return locs[:]
	}
	for item in items {
		rel_of := ""
		if v, found := jsonutil.obj_get(item, "relative_path"); found {
			rel_of = jsonutil.value_str(v)
		}
		line := int(jsonutil.obj_get_int(item, "line"))
		col := int(jsonutil.obj_get_int(item, "col"))
		uri := lsp_relay_client_uri(h, views, rel_of, arena)
		if uri == "" {
			continue
		}
		append(&locs, lspserver.Relay_Location{uri = uri, line = line, col = col, has_end = false, end_line = line, end_col = col})
	}
	return locs[:]
}

// relay_pick_hit applies the position ladder to a finished walk: the
// deepest selectionRange containing the position, then the deepest full
// range, then the first symbol whose range starts exactly at it — nil when
// no symbol sits at the position. The name path comes back with the hit.
// host_lsp_relay and ops_host_prepare share it, so both consumers rank
// candidates by one rule.
relay_pick_hit :: proc(w: ^Relay_Walk) -> (hit: json.Value, hit_path: string) {
	hit, hit_path = w.best_sel, w.best_sel_path
	if hit == nil {
		hit, hit_path = w.best_rng, w.best_rng_path
	}
	if hit == nil {
		hit, hit_path = w.first_sel, w.first_sel_path
	}
	if hit == nil {
		hit, hit_path = w.first_start, w.first_start_path
	}
	return
}

// The walk's carried state: the four ladder candidates with their name
// paths and the ranking keys (the winning range's start position). All
// strings are clones in the request arena.
Relay_Walk :: struct {
	arena: mem.Allocator,
	line:  int,
	col:   int,

	best_sel:  json.Value,
	best_sel_path:  string,
	best_sel_line:  int,
	best_sel_col:   int,
	best_rng:  json.Value,
	best_rng_path:  string,
	best_rng_line:  int,
	best_rng_col:   int,
	first_sel: json.Value,
	first_sel_path: string,
	first_start: json.Value,
	first_start_path: string,
}

// relay_walk descends the outline tree pre-order, running the ladder
// checks per node and extending the name path for the children.
relay_walk :: proc(nodes: []json.Value, prefix: string, w: ^Relay_Walk) {
	for node in nodes {
		m, is_obj := jsonutil.as_object(node)
		if !is_obj {
			continue
		}
		name := ""
		if nv, found := m["name"]; found {
			name = jsonutil.value_str(nv)
		}
		path := relay_step_path(prefix, name, w.arena)

		if sel, found := m["selection_range"]; found {
			sl, sc, el, ec := relay_range_bounds(sel)
			if sl >= 0 {
				end := symbol.Position{line = u32(max(el, 0)), character = u32(max(ec, 0))}
				if relay_range_contains(sl, sc, end, w.line, w.col) {
					if w.best_sel == nil || relay_pos_later(sl, sc, w.best_sel_line, w.best_sel_col) {
						w.best_sel = node
						w.best_sel_path = path
						w.best_sel_line = sl
						w.best_sel_col = sc
					}
				} else if w.first_sel == nil && sl == w.line && sc == w.col {
					w.first_sel = node
					w.first_sel_path = path
				}
			}
		}
		if rng, found := m["range"]; found {
			sl, sc, el, ec := relay_range_bounds(rng)
			if sl >= 0 {
				end := symbol.Position{line = u32(max(el, 0)), character = u32(max(ec, 0))}
				if relay_range_contains(sl, sc, end, w.line, w.col) {
					if w.best_rng == nil || relay_pos_later(sl, sc, w.best_rng_line, w.best_rng_col) {
						w.best_rng = node
						w.best_rng_path = path
						w.best_rng_line = sl
						w.best_rng_col = sc
					}
				} else if w.first_start == nil && sl == w.line && sc == w.col {
					w.first_start = node
					w.first_start_path = path
				}
			}
		}
		if kids_v, found := m["children"]; found {
			if kids, is_arr := jsonutil.as_array(kids_v); is_arr {
				relay_walk(kids, path, w)
			}
		}
	}
}

// relay_step_path appends one node's name to the descent's path (empty
// names contribute nothing — the daemon's full-name-path rule).
relay_step_path :: proc(prefix, name: string, a: mem.Allocator) -> string {
	if name == "" {
		return prefix
	}
	if prefix == "" {
		return strings.clone(name, a)
	}
	return strings.concatenate({prefix, "/", name}, a)
}

relay_pos_later :: proc(a_line, a_col, b_line, b_col: int) -> bool {
	if a_line != b_line {
		return a_line > b_line
	}
	return a_col > b_col
}

// relay_range_contains mirrors the daemon's rng_contains: the start is
// inclusive, the exact end position is not.
relay_range_contains :: proc(sl, sc: int, end: symbol.Position, line, col: int) -> bool {
	if relay_pos_later(sl, sc, line, col) {
		return false
	}
	if relay_pos_later(line, col, int(end.line), int(end.character)) {
		return false
	}
	return !(line == int(end.line) && col == int(end.character))
}

// relay_hit_range picks the definition answer's range: the selection range
// when present, the full range otherwise.
relay_hit_range :: proc(node: json.Value) -> json.Value {
	if rng, ok := jsonutil.obj_get(node, "selection_range"); ok {
		if _, is_obj := jsonutil.as_object(rng); is_obj {
			return rng
		}
	}
	if rng, ok := jsonutil.obj_get(node, "range"); ok {
		if _, is_obj := jsonutil.as_object(rng); is_obj {
			return rng
		}
	}
	return nil
}

// relay_range_bounds reads a range value's start/end line/column (-1 line
// when the value is not the expected shape).
relay_range_bounds :: proc(rng: json.Value) -> (sl, sc, el, ec: int) {
	start, ok := jsonutil.obj_get(rng, "start")
	if !ok {
		sl = -1
		return
	}
	end, end_ok := jsonutil.obj_get(rng, "end")
	if !end_ok {
		sl = -1
		return
	}
	sl = int(jsonutil.obj_get_int(start, "line"))
	sc = int(jsonutil.obj_get_int(start, "character"))
	el = int(jsonutil.obj_get_int(end, "line"))
	ec = int(jsonutil.obj_get_int(end, "character"))
	return
}

// host_lsp_text_for_uri serves one document's text for the relay answer
// conversion: the view's current text when open (the conversion truth for
// that document), one svc.file/read fetch otherwise. The per-request cache
// lives on the face side, so a multi-location answer reads each file once.
host_lsp_text_for_uri :: proc(host: rawptr, uri: string, arena: mem.Allocator) -> (text: string, ok: bool) {
	h := cast(^Lsp_Host)host
	if snap, have := lspserver.server_snapshot_doc(h.server, uri, arena); have {
		return snap.text, true
	}
	rel := lsp_rel_path(h, uri)
	if rel == "" {
		return "", false
	}
	conn := lsp_parent_conn(h)
	if conn == nil {
		return "", false
	}
	guard := lsp_call_begin(h)
	cc := svc.client_file_read(conn, rel, 0, 0, false, 0, arena, platform.mono_ms() + LSP_RELAY_CALL_DEADLINE_MS, guard.token)
	lsp_call_end(h, guard)
	if cc.call_err != .None {
		return "", false
	}
	if v, found := jsonutil.obj_get(cc.result, "content"); found {
		return jsonutil.value_str(v), true
	}
	return "", false
}
