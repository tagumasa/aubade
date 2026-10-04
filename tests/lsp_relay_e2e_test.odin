// lsp relay E2E: the full aggregation-relay sequence with every piece
// real at once. One harness joins three production shapes: the in-process
// daemon pair (test_daemon_with_project, the fake LS swapped in through
// the LSPPush_Factory decorator before any start), a child session App
// wired the way run_lsp_session does it (parent_mode "lsp", the
// lsp_wire_parent_conn hook, an Lsp_Host face over editor pipes), and the
// daemon pair's OWN child conn published as that App's parent link — the
// route that reuses the svc_test pair machinery (conn, reader thread,
// config seeding) instead of standing up a second in-process daemon via
// start_in_process_daemon, which would need its own heartbeat teardown
// and home isolation without adding a wire this test does not already
// drive. The root binding is real: lsp_bind_root loads the config stack
// and the safety gate from the pair's project/home dirs, so initialize
// takes the explicit-project path (host_lsp_initialize short-circuits on
// is_root_bound, exactly as run_lsp_session's --project flow behaves).
//
// Driven over the editor pipes in wire order: initialize (the static
// capability faces), didOpen (the doc sync lands in the daemon's editor
// buffers), one starter pass on a helper thread (svc.langserver/start
// against the swapped-in fake, then the client/registerCapability round
// trip answered from the test thread), textDocument/definition resolved
// through svc.symbol/list — crystal's bundled grammar ships an empty tags
// query, so the daemon's source order falls through the tree-sitter
// producer to the LSP producer and the fake peer must answer
// documentSymbol (a pump thread serves the preset; the shared fake's only
// change is the recorded client conn) — and the diagnostics relay: a
// publishDiagnostics dispatched into the fake server's client arrives on
// the editor pipe under the view's uri spelling and version.
package tests

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:testing"
import "core:thread"
import "core:time"

import "src:config"
import "src:daemon"
import "src:jsonrpc"
import "src:jsonutil"
import "src:langserver"
import "src:lsp"
import "src:lspserver"
import "src:platform"
import "src:safety"
import "src:session"
import "src:svc"

// The fixture document (crystal) and the hierarchical DocumentSymbol
// preset the fake peer answers documentSymbol with. The selectionRange
// rows name the symbols the definition relay must resolve: the request at
// (2,4) sits inside `greet`'s full range, the walk picks the deepest
// containing symbol, and the answer is `greet`'s selectionRange
// (1,6)-(1,11) — utf-16 columns that pass through the utf-16 connection
// unchanged.
LSPE2E_DOC_TEXT :: "class Greeter\n  def greet\n    \"hello\"\n  end\nend\n\nGreeter.new.greet\n"

LSPE2E_DOC_SYMBOL_PRESET :: `[{"name":"Greeter","kind":5,` +
	`"range":{"start":{"line":0,"character":0},"end":{"line":4,"character":3}},` +
	`"selectionRange":{"start":{"line":0,"character":6},"end":{"line":0,"character":13}},` +
	`"children":[{"name":"greet","kind":6,` +
	`"range":{"start":{"line":1,"character":2},"end":{"line":3,"character":5}},` +
	`"selectionRange":{"start":{"line":1,"character":6},"end":{"line":1,"character":11}},` +
	`"children":[]}]}]`

// --- the rig ------------------------------------------------------------------

Lspe2e_Rig :: struct {
	pair:  ^Daemon_Pair,     // the real daemon, its channel pair, and the child conn
	app:   ^session.App,     // the LSP child's application state
	root:  ^platform.Cancel_Token,
	clock: ^platform.Clock,
	host:  ^session.Lsp_Host,

	up:     Pipe,
	down:   Pipe,
	send:   jsonrpc.Writer, // test writes here (into up)
	recv:   jsonrpc.Reader, // test reads replies here (from down)
	conn:   jsonrpc.Conn,   // the editor conn (the face's)
	server: lspserver.Server,

	// The fake factory and its decorator, heap-allocated: the daemon's
	// manager runs the factory from its own threads until pair_shutdown.
	// ff.allocator points into ma — the rig outlives both.
	ff: ^Fake_Factory,
	pf: ^LSPPush_Factory,
	ma: mem.Mutex_Allocator,
}

lspe2e_rig_init :: proc(t: ^testing.T) -> ^Lspe2e_Rig {
	// crystal's argv override pins an existing binary: the manager's
	// override path skips the entry's runtime probe (the fake answers the
	// handshake without a process, so the command itself never runs).
	config_jsonc := strings.concatenate(
		{`{"language_server_commands": {"crystal": ["`, SH_NAME, `"]}}`},
		context.temp_allocator,
	)
	pair := test_daemon_with_project(t, false, config_jsonc)
	if pair == nil {
		return nil
	}

	r := new(Lspe2e_Rig, context.allocator)
	r.pair = pair

	// Swap the daemon manager's production factory for the fake before any
	// start: nothing starts servers in this window (the warm-up crawl and
	// the idle reaper never spawn one, and no request has arrived).
	mem.mutex_allocator_init(&r.ma, context.allocator)
	r.ff = new(Fake_Factory, context.allocator)
	r.ff^ = {allocator = mem.mutex_allocator(&r.ma)}
	r.ff.peers = make([dynamic]^Fake_Peer, 0, 4, r.ff.allocator)
	r.pf = new(LSPPush_Factory, context.allocator)
	r.pf^ = {
		ff               = r.ff,
		push_diagnostics = daemon.push_diagnostics_to_lsp_children,
		push_host        = pair.daemon,
	}
	pair.daemon.ls.factory = langserver.Factory{user = r.pf, create = lsppush_fake_create}

	r.root = new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(r.root)
	r.clock = new(platform.Clock, context.allocator)
	platform.clock_init(r.clock, false)

	// home rides the pair's daemon home: the child's config stack reads the
	// same (empty) global config and its daemon dir stays inside the tree
	// pair_shutdown removes.
	r.app = new(session.App, context.allocator)
	r.app^ = {
		root         = r.root,
		clock        = r.clock,
		home         = strings.clone(pair.home, context.allocator),
		allocator    = context.allocator,
		cancel_alloc = context.allocator,
	}
	r.app.calls = make(map[string]^session.Call_Entry, 8, context.allocator)

	// The LSP host and its face over the editor pipes — the relayhost
	// construction with the REAL session host callbacks.
	r.host = new(session.Lsp_Host, context.allocator)
	r.host^ = {app = r.app}
	r.host.relay = make(map[string]session.Relay_Lang, 4, context.allocator)

	pipe_init(&r.up, context.allocator)
	pipe_init(&r.down, context.allocator)
	jsonrpc.writer_init(&r.send, pipe_write, &r.up)
	jsonrpc.reader_init(&r.recv, pipe_read, &r.down, 64 * 1024, context.allocator)
	jsonrpc.reader_init(&r.conn.reader, pipe_read, &r.up, 64 * 1024, context.allocator)
	jsonrpc.writer_init(&r.conn.writer, pipe_write, &r.down)
	jsonrpc.conn_init(&r.conn, r.conn.reader, r.conn.writer, context.allocator)

	r.server = {
		host            = r.host,
		name            = "aubade",
		version         = "test",
		initialize_host = session.host_lsp_initialize,
		doc_open        = session.host_lsp_doc_open,
		doc_change      = session.host_lsp_doc_change,
		doc_close       = session.host_lsp_doc_close,
		highlights      = session.host_lsp_highlights,
		diagnostics     = session.host_lsp_diagnostics,
		readiness       = session.host_lsp_readiness,
		relay           = session.host_lsp_relay,
		text_for_uri    = session.host_lsp_text_for_uri,
		log             = nil,
		allocator       = context.allocator,
	}
	lspserver.server_init(&r.server, &r.conn)
	r.host.server = &r.server

	// The link wiring in the real session's order: the host (and its
	// type-erased App.host_face) exists before the wire hook runs, and the
	// hook lands the push handlers + host on the pair's child conn — the
	// conn the daemon addresses its push family and svc replies through.
	r.app.host_face = r.host
	r.app.parent_mode = "lsp"
	sync.mutex_lock(&r.app.parent_mu)
	r.app.parent = pair.conn
	r.app.parent_state = .Live
	sync.mutex_unlock(&r.app.parent_mu)
	session.lsp_wire_parent_conn(r.app, pair.conn)
	return r
}

// lspe2e_rig_destroy unwinds in join-before-free order. The pair goes
// first: its shutdown joins the harness reader thread (any in-flight push
// handler completes before the face is destroyed) and stops the daemon
// (the manager frees the fake clients that reference the fake pipes — the
// peers themselves go last). The face outlives every push only because
// the reader that could run one is joined inside pair_shutdown.
lspe2e_rig_destroy :: proc(r: ^Lspe2e_Rig) {
	pair_shutdown(r.pair)

	lspserver.server_destroy(&r.server)
	jsonrpc.conn_destroy(&r.conn)
	jsonrpc.reader_destroy(&r.recv)
	pipe_close(&r.up)
	pipe_close(&r.down)

	session.lsp_relay_map_destroy(r.host)
	free(r.host, context.allocator)

	delete(r.app.calls)
	if r.app.cfg.project_root != "" {
		delete(r.app.cfg.project_root, context.allocator)
	}
	if r.app.home != "" {
		delete(r.app.home, context.allocator)
	}
	if r.app.daemon_dir != "" {
		delete(r.app.daemon_dir, context.allocator)
	}
	if r.app.endpoint_path != "" {
		delete(r.app.endpoint_path, context.allocator)
	}
	if r.app.safety != nil {
		safety.safety_checker_destroy(r.app.safety)
		free(r.app.safety, context.allocator)
	}
	if r.app.stack != nil {
		config.stack_destroy(r.app.stack)
	}
	if r.app.layers != nil {
		delete(r.app.layers, context.allocator)
	}
	free(r.app, context.allocator)
	// token_destroy frees the token itself — no second free after it.
	platform.token_destroy(r.root, context.allocator)
	free(r.clock, context.allocator)

	// The fake's pipes die after the daemon (and with it the manager and
	// its clients) is down — the lsppush harness's own ordering.
	lsppush_fake_peers_cleanup(r.ff)
	free(r.pf, context.allocator)
	free(r, context.allocator)
}

// --- editor-pipe drivers -------------------------------------------------------

// lspe2e_request writes one request frame, dispatches it through the face
// conn on the calling thread, and returns the raw reply body ("" when the
// dispatch produced none).
lspe2e_request :: proc(t: ^testing.T, r: ^Lspe2e_Rig, id_text: string, method: string, params_inner: string) -> string {
	params := ""
	if params_inner != "" {
		params = strings.concatenate({`,"params":{`, params_inner, "}"}, context.temp_allocator)
	}
	body := strings.concatenate(
		{`{"jsonrpc":"2.0","id":`, id_text, `,"method":"`, method, `"`, params, "}"},
		context.temp_allocator,
	)
	err := jsonrpc.write_frame(&r.send, json_bytes(body))
	testing.expectf(t, err == .None, "write_frame failed: %v", err)
	if err != .None {
		return ""
	}
	got, rerr := jsonrpc.read_frame(&r.conn.reader, context.temp_allocator)
	testing.expectf(t, rerr == .None, "read_frame from the up pipe failed: %v", rerr)
	if rerr != .None {
		return ""
	}
	keep := jsonrpc.conn_handle_body(&r.conn, got, context.temp_allocator)
	testing.expect(t, keep, "the face answered a framing-level rejection")
	if len(r.down.buf) == 0 {
		return ""
	}
	reply, derr := jsonrpc.read_frame(&r.recv, context.temp_allocator)
	testing.expectf(t, derr == .None, "read_frame from the down pipe failed: %v", derr)
	if derr != .None {
		return ""
	}
	return string(reply)
}

// lspe2e_notify writes one notification frame and dispatches it; any
// server-initiated frames stay in the down pipe for the test to read.
lspe2e_notify :: proc(t: ^testing.T, r: ^Lspe2e_Rig, method: string, params_inner: string) {
	params := ""
	if params_inner != "" {
		params = strings.concatenate({`,"params":{`, params_inner, "}"}, context.temp_allocator)
	}
	body := strings.concatenate(
		{`{"jsonrpc":"2.0","method":"`, method, `"`, params, "}"},
		context.temp_allocator,
	)
	err := jsonrpc.write_frame(&r.send, json_bytes(body))
	testing.expectf(t, err == .None, "write_frame failed: %v", err)
	if err != .None {
		return
	}
	got, rerr := jsonrpc.read_frame(&r.conn.reader, context.temp_allocator)
	testing.expectf(t, rerr == .None, "read_frame from the up pipe failed: %v", rerr)
	if rerr != .None {
		return
	}
	keep := jsonrpc.conn_handle_body(&r.conn, got, context.temp_allocator)
	testing.expect(t, keep, "the face answered a framing-level rejection")
}

// lspe2e_wait_down_frame polls until the down pipe holds a frame or the
// deadline passes (2 ms slices — the bounded-arrival idiom; the frame is
// produced on the daemon pair's reader thread).
lspe2e_wait_down_frame :: proc(r: ^Lspe2e_Rig, timeout_ms: i64) -> bool {
	deadline := platform.mono_ms() + timeout_ms
	for {
		if len(r.down.buf) > 0 {
			return true
		}
		if platform.mono_ms() >= deadline {
			return false
		}
		time.sleep(2 * time.Millisecond)
	}
}

lspe2e_relay_record :: proc(r: ^Lspe2e_Rig, language: string) -> (rec: session.Relay_Lang, ok: bool) {
	sync.mutex_lock(&r.host.mu)
	rec, ok = r.host.relay[language]
	sync.mutex_unlock(&r.host.mu)
	return
}

// --- the starter pass ----------------------------------------------------------

Lspe2e_Pass_Args :: struct {
	h:    ^session.Lsp_Host,
	done: chan.Chan(bool),
}

// The registration round trip parks its caller on the editor conn's reply
// slot, so the pass runs on a helper thread and the test pumps.
lspe2e_pass_entry :: proc(args: ^Lspe2e_Pass_Args) {
	session.lsp_relay_pass(args.h)
	chan.send(chan.as_send(args.done), true)
}

// lspe2e_answer_editor_frame asserts one request frame via `check`, then
// answers it with a null result so the pending slot delivers.
lspe2e_answer_editor_frame :: proc(t: ^testing.T, r: ^Lspe2e_Rig, body: string, check: proc(t: ^testing.T, body: string)) {
	check(t, body)
	id := lsprelay_frame_id(t, body)
	reply := strings.concatenate({`{"jsonrpc":"2.0","id":`, id, `,"result":null}`}, context.temp_allocator)
	werr := jsonrpc.write_frame(&r.send, json_bytes(reply))
	testing.expectf(t, werr == .None, "writing the reply frame failed: %v", werr)
	got, gerr := jsonrpc.read_frame(&r.conn.reader, context.temp_allocator)
	testing.expectf(t, gerr == .None, "reading the reply frame back failed: %v", gerr)
	if gerr == .None {
		jsonrpc.conn_handle_body(&r.conn, got, context.temp_allocator)
	}
}

// lspe2e_run_pass drives one helper thread through the starter pass,
// pumping and answering every request frame the pass produces (chan
// handoff, no sleeps).
lspe2e_run_pass :: proc(
	t: ^testing.T,
	r: ^Lspe2e_Rig,
	args: ^Lspe2e_Pass_Args,
	th: ^thread.Thread,
	check: proc(t: ^testing.T, body: string),
) -> bool {
	ok_seen := false
	pump: for i := 0; i < 2_000_000; i += 1 {
		if ok, has := chan.try_recv(chan.as_recv(args.done)); has {
			ok_seen = ok
			break pump
		}
		if len(r.down.buf) > 0 {
			frame, rerr := jsonrpc.read_frame(&r.recv, context.temp_allocator)
			testing.expectf(t, rerr == .None, "the registration frame read failed: %v", rerr)
			if rerr != .None {
				break pump
			}
			lspe2e_answer_editor_frame(t, r, string(frame), check)
		}
	}
	chan.destroy(args.done)
	thread.join(th)
	free(th, context.allocator)
	return ok_seen
}

// --- the fake peer pump --------------------------------------------------------

// Lspe2e_Pump completes the fake LS's server->client round trips while a
// daemon-side producer waits on one: the daemon's documentSymbol request
// lands on the fake peer's up pipe, the pump answers with the preset and
// dispatches the reply into the fake client's conn (the pending slot's
// waiter — a daemon pool worker — wakes). The pump owns its readers
// exclusively; peer.up's read deadline bounds every idle wake so the stop
// flag is observed without a close.
Lspe2e_Pump :: struct {
	req_reader:   jsonrpc.Reader, // over peer.up (the fake client's outbound frames)
	reply_writer: jsonrpc.Writer, // into peer.down (the fake client's inbound)
	client:       ^lsp.Client,
	stop:         bool, // atomic flag (sync.atomic_*)
}

lspe2e_frame_id_text :: proc(v: json.Value) -> string {
	id, ok := jsonutil.obj_get(v, "id")
	if !ok {
		return "null"
	}
	#partial switch x in id {
	case i64:
		return fmt.aprintf("%d", x, allocator = context.temp_allocator)
	case string:
		return jsonutil.json_quote(x, context.temp_allocator)
	case:
	}
	return "null"
}

lspe2e_pump_entry :: proc(p: ^Lspe2e_Pump) {
	for !sync.atomic_load(&p.stop) {
		frame, rerr := jsonrpc.read_frame(&p.req_reader, context.temp_allocator)
		if rerr == .None {
			v, perr := json.parse_bytes(frame, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
			if perr == nil {
				method := ""
				if mv, ok := jsonutil.obj_get(v, "method"); ok {
					method = jsonutil.value_str(mv)
				}
				// Notifications (the producer's didOpen/didClose pair) are
				// dropped; only requests need the preset answer.
				if method == lsp.METHOD_DOCUMENT_SYMBOL {
					reply := strings.concatenate(
						{
							`{"jsonrpc":"2.0","id":`,
							lspe2e_frame_id_text(v),
							`,"result":`,
							LSPE2E_DOC_SYMBOL_PRESET,
							"}",
						},
						context.temp_allocator,
					)
					werr := jsonrpc.write_frame(&p.reply_writer, json_bytes(reply))
					if werr == .None {
						got, gerr := jsonrpc.read_frame(&p.client.conn.reader, context.temp_allocator)
						if gerr == .None {
							jsonrpc.conn_handle_body(p.client.conn, got, context.temp_allocator)
						}
					}
				}
			}
		}
		// Per-iteration scratch (frames, the parsed view, the reply) must
		// not accumulate on this long-lived thread.
		free_all(context.temp_allocator)
	}
}

// --- the test ------------------------------------------------------------------

@(test)
lspe2e_aggregation_relay_end_to_end :: proc(t: ^testing.T) {
	r := lspe2e_rig_init(t)
	if r == nil {
		return
	}
	defer lspe2e_rig_destroy(r)

	// The real root binding: config stack + safety gate from the pair's
	// project/home dirs (is_root_bound latches, so initialize takes the
	// explicit-project path).
	bind_msg := session.lsp_bind_root(r.host, r.pair.tmp)
	testing.expectf(t, bind_msg == "", "lsp_bind_root failed: %s", bind_msg)
	if bind_msg != "" {
		return
	}
	root := r.app.cfg.project_root

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 15_000

	// The subscribing hello over the real parent link: the daemon routes
	// its push family and opens its svc surface to this conn.
	hello := jsonutil.json_object(2, alloc)
	jsonutil.obj_set(&hello, "client_pid", jsonutil.json_int(i64(os.get_pid())))
	jsonutil.obj_set(&hello, "mode", jsonutil.json_string("lsp"))
	_, _, _, hcerr := jsonrpc.conn_call(
		r.pair.conn, svc.METHOD_HELLO, json.Value(json.Object(hello)), alloc, deadline,
	)
	testing.expect_value(t, hcerr, jsonrpc.Call_Err.None)

	// (a) initialize with the real project root; the reply must carry the
	// static faces and the negotiated encoding.
	root_uri := strings.concatenate({"file://", root}, context.temp_allocator)
	init_params := strings.concatenate(
		{
			`"rootUri":`,
			jsonutil.json_quote(root_uri, context.temp_allocator),
			`,"capabilities":{"general":{"positionEncodings":["utf-16"]}}`,
		},
		context.temp_allocator,
	)
	body := lspe2e_request(t, r, "1", lsp.METHOD_INITIALIZE, init_params)
	testing.expect(t, body != "", "initialize produced no reply")
	testing.expectf(t, lspface_reply_code(t, body) == 0, "initialize answered an error: %s", body)
	if body == "" || lspface_reply_code(t, body) != 0 {
		return
	}
	enc_v := lspface_caps_member(t, body, "positionEncoding")
	testing.expectf(
		t,
		enc_v != nil && jsonutil.value_str(enc_v) == "utf-16",
		"the utf-16 offer must be answered, got %v",
		enc_v,
	)
	caps_v := lspface_result_member(t, body, "capabilities")
	testing.expect(t, caps_v != nil, "capabilities missing from the initialize result")
	if caps_v == nil {
		return
	}
	_, has_sync := jsonutil.obj_get(caps_v, "textDocumentSync")
	_, has_tokens := jsonutil.obj_get(caps_v, "semanticTokensProvider")
	ds_v, has_ds := jsonutil.obj_get(caps_v, "documentSymbolProvider")
	testing.expectf(
		t,
		has_sync && has_tokens && has_ds && jsonutil.value_bool(ds_v),
		"the static faces must always ride the initialize reply",
	)

	// (b) the acknowledgment, then the project file and its didOpen: the
	// doc sync must reach the daemon's editor buffers (the accepted open
	// is what arms the language's relay record).
	lspe2e_notify(t, r, lsp.METHOD_INITIALIZED, "")

	svc_symbol_write_file(t, root, "main.cr", LSPE2E_DOC_TEXT)
	doc_uri := strings.concatenate({"file://", root, "/main.cr"}, context.temp_allocator)
	open_params := strings.concatenate(
		{
			`"textDocument":{"uri":`,
			jsonutil.json_quote(doc_uri, context.temp_allocator),
			`,"languageId":"crystal","version":7,"text":`,
			jsonutil.json_quote(LSPE2E_DOC_TEXT, context.temp_allocator),
			"}",
		},
		context.temp_allocator,
	)
	lspe2e_notify(t, r, lsp.METHOD_DID_OPEN, open_params)

	rec, rec_ok := lspe2e_relay_record(r, "crystal")
	testing.expectf(
		t,
		rec_ok && rec.state == .Pending,
		"the accepted didOpen must arm crystal Pending (ok=%v)",
		rec_ok,
	)
	if !rec_ok {
		return
	}

	// (c) one starter pass: svc.langserver/start against the running fake
	// (refs+declaration caps), then the caps-gated registration batch.
	args := new(Lspe2e_Pass_Args, context.allocator)
	args.h = r.host
	done, derr := chan.create_buffered(chan.Chan(bool), 1, context.allocator)
	testing.expect(t, derr == nil, "chan create failed")
	if derr != nil {
		free(args, context.allocator)
		return
	}
	args.done = done
	th := thread.create_and_start_with_poly_data(args, lspe2e_pass_entry, self_cleanup = false)
	check := proc(t: ^testing.T, body: string) {
		v, perr := json.parse_bytes(json_bytes(body), spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
		testing.expectf(t, perr == nil, "frame did not parse: %s", body)
		if perr != nil {
			return
		}
		testing.expectf(t, lsprelay_member_str(v, "method") == lsp.METHOD_REGISTER_CAPABILITY, "expected registerCapability, got %s", body)
		if params, ok := jsonutil.obj_get(v, "params"); ok {
			regs_v, regs_ok := jsonutil.obj_get(params, "registrations")
			if regs_ok {
				regs, _ := jsonutil.as_array(regs_v)
				testing.expectf(t, len(regs) == 7, "one batch of seven (three relays + the four langserver faces), got %d", len(regs))
			}
			lsprelay_assert_registration(t, params, 0, "aubade.relay.crystal.definition", lsp.METHOD_DEFINITION, "crystal")
			lsprelay_assert_registration(t, params, 1, "aubade.relay.crystal.references", lsp.METHOD_REFERENCES, "crystal")
			lsprelay_assert_registration(t, params, 2, "aubade.relay.crystal.declaration", lsp.METHOD_DECLARATION, "crystal")
			lsprelay_assert_registration(t, params, 3, "aubade.relay.crystal.formatting", lsp.METHOD_FORMATTING, "crystal")
			lsprelay_assert_registration(t, params, 4, "aubade.relay.crystal.codeAction", lsp.METHOD_CODE_ACTION, "crystal")
			lsprelay_assert_registration(t, params, 5, "aubade.relay.crystal.inlayHint", lsp.METHOD_INLAY_HINT, "crystal")
			lsprelay_assert_registration(t, params, 6, "aubade.relay.crystal.prepareCallHierarchy", lsp.METHOD_PREPARE_CALL_HIERARCHY, "crystal")
		}
	}
	completed := lspe2e_run_pass(t, r, args, th, check)
	testing.expect(t, completed, "the starter pass must complete")
	free(args, context.allocator)

	rec, rec_ok = lspe2e_relay_record(r, "crystal")
	testing.expectf(
		t,
		rec_ok && rec.state == .Ready && rec.is_registered && rec.references && rec.declaration,
		"the pass must leave crystal Ready and registered with both caps (ok=%v state=%v reg=%v)",
		rec_ok, rec.state, rec.is_registered,
	)
	if !rec_ok || !rec.is_registered {
		return
	}

	// The running fake server's client (lsppush's snapshot discipline: the
	// pin is released after the pointer is kept; the server stays in the
	// table until teardown and only this test's threads touch the manager
	// in between).
	client: ^lsp.Client = nil
	running := langserver.manager_running_clients(r.pair.daemon.ls, context.temp_allocator)
	for rc in running {
		if rc.language_id == "crystal" {
			client = rc.client
		}
		langserver.manager_release(r.pair.daemon.ls, rc.client)
	}
	delete(running)
	testing.expectf(t, client != nil, "crystal client missing after the pass")
	if client == nil {
		return
	}

	// (d) the definition relay. crystal carries an empty tags query, so
	// the daemon's symbol source order falls through tree-sitter to the
	// LSP producer, which asks the running fake for documentSymbol: arm
	// the pump that answers it, then send the request over the editor
	// pipe.
	sync.mutex_lock(&r.ff.mu)
	peer: ^Fake_Peer = nil
	if len(r.ff.peers) > 0 {
		peer = r.ff.peers[0]
	}
	sync.mutex_unlock(&r.ff.mu)
	testing.expectf(t, peer != nil && peer.conn != nil, "the fake peer (with its client conn) is missing")
	if peer == nil || peer.conn == nil {
		return
	}
	peer.up.read_deadline_ms = 30

	pump := new(Lspe2e_Pump, context.allocator)
	jsonrpc.reader_init(&pump.req_reader, pipe_read, &peer.up, 64 * 1024, context.allocator)
	jsonrpc.writer_init(&pump.reply_writer, pipe_write, &peer.down)
	pump.client = client
	pump_th := thread.create_and_start_with_poly_data(pump, lspe2e_pump_entry, self_cleanup = false)

	def_params := strings.concatenate(
		{
			`"textDocument":{"uri":`,
			jsonutil.json_quote(doc_uri, context.temp_allocator),
			`},"position":{"line":2,"character":4}`,
		},
		context.temp_allocator,
	)
	def_body := lspe2e_request(t, r, "2", lsp.METHOD_DEFINITION, def_params)
	items := lsprelay_result_locations(t, def_body)

	// The pump's work is done once the reply is in hand (the documentSymbol
	// answer happens-before the svc reply): stop it before the teardown.
	sync.atomic_store(&pump.stop, true)
	thread.join(pump_th)
	free(pump_th, context.allocator)
	jsonrpc.reader_destroy(&pump.req_reader)
	free(pump, context.allocator)

	testing.expectf(t, len(items) == 1, "definition must answer one location, got %d", len(items))
	if len(items) == 1 {
		uri, sl, sc, el, ec := lsprelay_location_at(t, items, 0)
		testing.expectf(t, uri == doc_uri, "the answer must use the view's uri, got %s", uri)
		testing.expectf(
			t,
			sl == 1 && sc == 6 && el == 1 && ec == 11,
			"the answer must be greet's selectionRange (1,6)-(1,11) in utf-16 columns, got (%d,%d)-(%d,%d)",
			sl, sc, el, ec,
		)
	}

	// (e) the diagnostics relay: a publishDiagnostics into the fake
	// server's client is stored, pushed to this lsp-mode child over the
	// real link, and republished on the editor pipe under the view's uri
	// spelling and version (the dispatched envelope carries the LS's own
	// version 3 — above the mirror's epoch watermark of 1 — while the view
	// stamps 7).
	diag_body := strings.concatenate(
		{
			`{"jsonrpc":"2.0","method":"`,
			lsp.METHOD_PUBLISH_DIAGNOSTICS,
			`","params":{"uri":`,
			jsonutil.json_quote(doc_uri, context.temp_allocator),
			`,"version":3,"diagnostics":[{"range":{"start":{"line":2,"character":4},"end":{"line":2,"character":9}},"severity":1,"message":"aubade e2e boom"}]}}`,
		},
		context.temp_allocator,
	)
	env, dec_err := jsonrpc.decode_envelope(transmute([]u8)diag_body, context.temp_allocator)
	testing.expectf(t, env != nil && dec_err == .None, "publish envelope did not decode")
	if env == nil || dec_err != .None {
		return
	}
	jsonrpc.conn_dispatch(client.conn, env, context.temp_allocator)

	if !lspe2e_wait_down_frame(r, 2000) {
		testing.expectf(t, false, "no publishDiagnostics relayed to the editor pipe")
		return
	}
	frame, ferr := jsonrpc.read_frame(&r.recv, context.temp_allocator)
	testing.expectf(t, ferr == .None, "the publish frame read failed: %v", ferr)
	if ferr != .None {
		return
	}
	pv, perr := json.parse_bytes(frame, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	testing.expectf(t, perr == nil, "the publish frame did not parse: %s", string(frame))
	if perr != nil {
		return
	}
	testing.expectf(
		t,
		lsprelay_member_str(pv, "method") == lsp.METHOD_PUBLISH_DIAGNOSTICS,
		"expected a publishDiagnostics notification, got: %s",
		string(frame),
	)
	params, has_params := jsonutil.obj_get(pv, "params")
	testing.expect(t, has_params, "the publish notification carries no params")
	if !has_params {
		return
	}
	pub_uri := lsprelay_member_str(params, "uri")
	testing.expectf(t, pub_uri == doc_uri, "the republish must use the view's uri spelling, got %s", pub_uri)
	version_v, has_version := jsonutil.obj_get(params, "version")
	testing.expectf(
		t,
		has_version && jsonutil.value_int(version_v) == 7,
		"the republish must stamp the view's version 7",
	)
	diags_v, has_diags := jsonutil.obj_get(params, "diagnostics")
	diags, is_arr := jsonutil.as_array(diags_v)
	testing.expectf(t, has_diags && is_arr && len(diags) == 1, "the pushed set must forward as one diagnostic")
	if has_diags && is_arr && len(diags) == 1 {
		msg, mok := json_str_field(diags[0], "message")
		testing.expectf(t, mok && msg == "aubade e2e boom", "the pushed diagnostic message mismatch: %s", msg)
	}
}
