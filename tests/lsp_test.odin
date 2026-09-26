// LSP client component tests against an in-memory fake language server
// (a second jsonrpc Conn cross-wired through two Pipes): concurrent
// request/response correlation, $/cancelRequest propagation on a cancelled
// call, bounded server->client dispatch (overflow answered with
// RequestFailed instead of blocking or growing), waiter release on close,
// and the bounded diagnostics store. No sleeps: every arrival/release
// handshake is a mutex+cond state machine (the suite's proven idiom for
// cross-thread test gates) with monotonic deadline guards where a test
// thread must yield.
package tests

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "src:jsonrpc"
import "src:jsonutil"
import "src:lsp"
import "src:platform"
import "src:symbol"
import "src:util"

// --- the fake language server ----------------------------------------------

// Fake_Gate is the slow-arrival/release handshake: slow handlers take a
// ticket on arrival and wait until the test releases that many tickets.
// Cond-based (not chan-based): this suite's cross-thread gates are all
// mutex+cond and they behave deterministically under the test allocator.
Fake_Gate :: struct {
	mu:       sync.Mutex,
	cond:     sync.Cond,
	arrived:  int, // tickets taken by handlers
	released: int, // tickets handed out by the test
}

fake_gate_arrive :: proc(g: ^Fake_Gate) -> int {
	sync.mutex_lock(&g.mu)
	g.arrived += 1
	ticket := g.arrived
	sync.cond_broadcast(&g.cond)
	sync.mutex_unlock(&g.mu)
	return ticket
}

fake_gate_wait :: proc(g: ^Fake_Gate, ticket: int) {
	sync.mutex_lock(&g.mu)
	for g.released < ticket {
		sync.cond_wait(&g.cond, &g.mu)
	}
	sync.mutex_unlock(&g.mu)
}

fake_gate_wait_arrival :: proc(g: ^Fake_Gate) {
	sync.mutex_lock(&g.mu)
	for g.arrived == 0 {
		sync.cond_wait(&g.cond, &g.mu)
	}
	sync.mutex_unlock(&g.mu)
}

fake_gate_release :: proc(g: ^Fake_Gate) {
	sync.mutex_lock(&g.mu)
	g.released += 1
	sync.cond_broadcast(&g.cond)
	sync.mutex_unlock(&g.mu)
}

Lsp_Fake :: struct {
	conn:           ^jsonrpc.Conn,
	thread:         ^thread.Thread,
	allocator:      mem.Allocator,

	received_mu:    sync.Mutex,
	received_cond:  sync.Cond,
	received:       [dynamic]string, // request/notification method names, owned
	cancel_ids:     [dynamic]string, // $/cancelRequest ids as decimals, owned
	cancel_count:   int,             // cancel notifications recorded (under received_mu)
	notes:          [dynamic]Fake_Note, // captured notifications: method + params JSON, owned
	// Params JSON of the most recent initialize request (owned); captured
	// by the initialize handler so tests can assert the workspace shape
	// the client announced.
	init_params:    string,

	// Capabilities mode for the initialize handler: the default declares
	// every location provider; the bare mode mirrors servers like ols
	// (definition and references only) so the capability-gate declines
	// are exercisable against a realistic server shape.
	bare_locations: bool,

	slow:           Fake_Gate, // arrival/release handshake for test/slow
}

Fake_Note :: struct {
	method: string,
	params: string,
}

fake_record :: proc(f: ^Lsp_Fake, method: string) {
	sync.mutex_lock(&f.received_mu)
	append(&f.received, strings.clone(method, f.allocator))
	sync.mutex_unlock(&f.received_mu)
}

fake_received_count :: proc(f: ^Lsp_Fake, method: string) -> int {
	n := 0
	sync.mutex_lock(&f.received_mu)
	for m in f.received {
		if m == method {
			n += 1
		}
	}
	sync.mutex_unlock(&f.received_mu)
	return n
}

fake_cancel_ids_snapshot :: proc(f: ^Lsp_Fake) -> []string {
	sync.mutex_lock(&f.received_mu)
	out := make([]string, len(f.cancel_ids), context.temp_allocator)
	for id, i in f.cancel_ids {
		out[i] = id
	}
	sync.mutex_unlock(&f.received_mu)
	return out
}

// fake_wait_cancel blocks until the fake's reader has recorded at least
// `want` $/cancelRequest notifications (the reader processes frames in
// order, so this is also a barrier for everything sent before them).
fake_wait_cancel :: proc(f: ^Lsp_Fake, want: int) {
	sync.mutex_lock(&f.received_mu)
	for f.cancel_count < want {
		sync.cond_wait(&f.received_cond, &f.received_mu)
	}
	sync.mutex_unlock(&f.received_mu)
}

// fake_note captures a notification (method + marshaled params). Params
// are marshaled on the reader thread's temp allocator and cloned out.
fake_note :: proc(f: ^Lsp_Fake, env: ^jsonrpc.Envelope) {
	raw := "null"
	if env.params != nil {
		raw = jsonutil.marshal_value(env.params, context.temp_allocator)
	}
	sync.mutex_lock(&f.received_mu)
	append(
		&f.notes,
		Fake_Note{
			method = strings.clone(env.method, f.allocator),
			params = strings.clone(raw, f.allocator),
		},
	)
	sync.cond_broadcast(&f.received_cond)
	sync.mutex_unlock(&f.received_mu)
}

fake_note_count :: proc(f: ^Lsp_Fake, method: string) -> int {
	n := 0
	sync.mutex_lock(&f.received_mu)
	for note in f.notes {
		if note.method == method {
			n += 1
		}
	}
	sync.mutex_unlock(&f.received_mu)
	return n
}

// fake_note_wait blocks until at least `want` notifications of `method`
// were captured (arrival barrier for didOpen & co). The wait is bounded:
// on expiry it returns early and the caller's subsequent shape asserts
// fail — a missed notification must fail the test, not hang the runner
// until the external suite timeout.
FAKE_NOTE_WAIT_MS :: 5_000

fake_note_wait :: proc(f: ^Lsp_Fake, method: string, want: int) {
	sync.mutex_lock(&f.received_mu)
	deadline := platform.mono_ms() + FAKE_NOTE_WAIT_MS
	for fake_note_count_locked(f, method) < want {
		remaining := deadline - platform.mono_ms()
		if remaining <= 0 {
			break
		}
		sync.cond_wait_with_timeout(&f.received_cond, &f.received_mu, time.Duration(remaining * 1_000_000))
	}
	sync.mutex_unlock(&f.received_mu)
}

fake_note_count_locked :: proc(f: ^Lsp_Fake, method: string) -> int {
	n := 0
	for note in f.notes {
		if note.method == method {
			n += 1
		}
	}
	return n
}

// fake_note_get returns the params JSON of the index-th captured
// notification of `method` ("" when absent — callers expect on shape).
fake_note_get :: proc(f: ^Lsp_Fake, method: string, index: int) -> string {
	sync.mutex_lock(&f.received_mu)
	out := ""
	seen := 0
	for note in f.notes {
		if note.method == method {
			if seen == index {
				out = note.params
			}
			seen += 1
		}
	}
	sync.mutex_unlock(&f.received_mu)
	return out
}

fake_echo_handler :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	f := cast(^Lsp_Fake)conn.host
	fake_record(f, env.method)
	return {result = env.params}, .Respond
}

// The protocol-side fake answers: initialize reports Incremental sync with
// definition + documentSymbol provided (the object form of a provider
// capability — truthy) and references explicitly true; declaration and
// implementation ride along unless the bare-locations mode is set (the
// ols-like server shape the capability gates decline); shutdown replies null.
fake_initialize_handler :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	f := cast(^Lsp_Fake)conn.host
	fake_record(f, env.method)
	raw := "null"
	if env.params != nil {
		raw = jsonutil.marshal_value(env.params, context.temp_allocator)
	}
	sync.mutex_lock(&f.received_mu)
	if f.init_params != "" {
		delete(f.init_params, f.allocator)
	}
	f.init_params = strings.clone(raw, f.allocator)
	sync.mutex_unlock(&f.received_mu)
	caps := jsonutil.json_object(7, arena)
	jsonutil.obj_set(&caps, "textDocumentSync", jsonutil.json_int(2))
	jsonutil.obj_set(&caps, "definitionProvider", json.Boolean(true))
	jsonutil.obj_set(&caps, "referencesProvider", json.Boolean(true))
	jsonutil.obj_set(&caps, "diagnosticProvider", json.Boolean(true))
	if !f.bare_locations {
		jsonutil.obj_set(&caps, "declarationProvider", json.Boolean(true))
		jsonutil.obj_set(&caps, "implementationProvider", json.Boolean(true))
	}
	doc_symbol := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&caps, "documentSymbolProvider", json.Value(json.Object(doc_symbol)))
	result := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&result, "capabilities", json.Value(json.Object(caps)))
	return {result = json.Value(json.Object(result))}, .Respond
}

fake_shutdown_handler :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	f := cast(^Lsp_Fake)conn.host
	fake_record(f, env.method)
	return {}, .Respond
}

fake_note_handler :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) {
	f := cast(^Lsp_Fake)conn.host
	fake_note(f, env)
}

fake_slow_handler :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	f := cast(^Lsp_Fake)conn.host
	fake_record(f, env.method)
	ticket := fake_gate_arrive(&f.slow)
	fake_gate_wait(&f.slow, ticket) // hold the reply until the test releases it
	return {}, .Respond
}

fake_cancel_notifier :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) {
	f := cast(^Lsp_Fake)conn.host
	fake_record(f, env.method)
	id_text := ""
	if v, ok := jsonutil.obj_get(env.params, "id"); ok {
		#partial switch x in v {
		case json.Integer:
			id_text = util.int_to_dec(cast(int)x, context.temp_allocator)
		case:
		}
	}
	sync.mutex_lock(&f.received_mu)
	append(&f.cancel_ids, strings.clone(id_text, f.allocator))
	f.cancel_count += 1
	sync.cond_broadcast(&f.received_cond)
	sync.mutex_unlock(&f.received_mu)
}

// --- the pair harness: client conn + fake conn cross-wired ------------------

Lsp_Pair :: struct {
	client:    ^lsp.Client,
	conn:      ^jsonrpc.Conn, // the client's conn
	creader:   ^thread.Thread,

	fake:      ^Lsp_Fake,
	freader:   ^thread.Thread,

	up:        Pipe, // client -> fake
	down:      Pipe, // fake -> client

	clock:     ^platform.Clock,

	// The pair runs three threads (two readers + the request-queue worker)
	// against the per-test tracking allocator, which is NOT thread-safe:
	// cross-thread allocations must serialize through this mutex wrapper
	// (leak tracking is preserved — the wrapper delegates to it).
	mu:        mem.Mutex_Allocator,
	allocator: mem.Allocator,
}

lsp_reader_entry :: proc(data: rawptr) {
	c := cast(^jsonrpc.Conn)data
	jsonrpc.conn_read_loop(c)
}

// lsp_pair_init builds the pair. virtual_clock selects the clock mode:
// real-clock pairs may run client_call (deadlines share slot_wait's
// monotonic base); a virtual-clock pair is for the injected-clock waits
// (client_call on it would pin deadlines at a virtual absolute against the
// real base slot_wait polls).
lsp_pair_init :: proc(t: ^testing.T, virtual_clock := false) -> ^Lsp_Pair {
	p := new(Lsp_Pair, context.allocator)
	mem.mutex_allocator_init(&p.mu, context.allocator)
	p.allocator = mem.mutex_allocator(&p.mu)
	pipe_init(&p.up, p.allocator)
	pipe_init(&p.down, p.allocator)

	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, virtual_clock, context.allocator)
	p.clock = clock

	p.conn = new(jsonrpc.Conn, context.allocator)
	cr: jsonrpc.Reader
	jsonrpc.reader_init(&cr, pipe_read, &p.down, 64 * 1024, p.allocator)
	cw: jsonrpc.Writer
	jsonrpc.writer_init(&cw, pipe_write, &p.up)
	jsonrpc.conn_init(p.conn, cr, cw, p.allocator)

	fake := new(Lsp_Fake, context.allocator)
	fake^ = {
		conn       = new(jsonrpc.Conn, context.allocator),
		allocator      = p.allocator,
		received   = make([dynamic]string, 0, 16, p.allocator),
		cancel_ids = make([dynamic]string, 0, 4, p.allocator),
		notes      = make([dynamic]Fake_Note, 0, 8, p.allocator),
	}
	p.fake = fake

	fr: jsonrpc.Reader
	jsonrpc.reader_init(&fr, pipe_read, &p.up, 64 * 1024, p.allocator)
	fw: jsonrpc.Writer
	jsonrpc.writer_init(&fw, pipe_write, &p.down)
	jsonrpc.conn_init(fake.conn, fr, fw, p.allocator)
	fake.conn.host = fake
	jsonrpc.conn_register(fake.conn, "test/echo", fake_echo_handler)
	jsonrpc.conn_register(fake.conn, "test/slow", fake_slow_handler)
	jsonrpc.conn_register_notification(fake.conn, lsp.METHOD_CANCEL_REQUEST, fake_cancel_notifier)
	jsonrpc.conn_register(fake.conn, lsp.METHOD_INITIALIZE, fake_initialize_handler)
	jsonrpc.conn_register(fake.conn, lsp.METHOD_SHUTDOWN, fake_shutdown_handler)
	jsonrpc.conn_register_notification(fake.conn, lsp.METHOD_INITIALIZED, fake_note_handler)
	jsonrpc.conn_register_notification(fake.conn, lsp.METHOD_EXIT, fake_note_handler)
	jsonrpc.conn_register_notification(fake.conn, lsp.METHOD_DID_OPEN, fake_note_handler)
	jsonrpc.conn_register_notification(fake.conn, lsp.METHOD_DID_CHANGE, fake_note_handler)
	jsonrpc.conn_register_notification(fake.conn, lsp.METHOD_DID_CLOSE, fake_note_handler)

	p.client = new(lsp.Client, context.allocator)
	lsp.client_init(p.client, p.conn, clock, "go", p.allocator)

	p.freader = thread.create_and_start_with_data(fake.conn, lsp_reader_entry, self_cleanup = false, name = "lsp-fake-reader")
	if p.freader == nil {
		return nil
	}
	p.creader = thread.create_and_start_with_data(p.conn, lsp_reader_entry, self_cleanup = false, name = "lsp-client-reader")
	if p.creader == nil {
		// The fake reader is already draining: unwind the pair exactly
		// the way lsp_pair_shutdown does, or the leaked reader thread
		// corrupts the per-test tracking allocator.
		lsp_pair_shutdown(p)
		return nil
	}
	return p
}

// lsp_pair_shutdown tears the pair down. Tests must have released every
// gated handler before calling this. Order: close both conns (the client
// close joins the request-queue worker), wake the readers through the
// pipes, join the threads, then free the memory each side owns.
lsp_pair_shutdown :: proc(p: ^Lsp_Pair) {
	jsonrpc.conn_close(p.conn)
	jsonrpc.conn_close(p.fake.conn)
	pipe_close(&p.up)
	pipe_close(&p.down)
	if p.creader != nil {
		thread.join(p.creader)
		free(p.creader, context.allocator)
	}
	if p.freader != nil {
		thread.join(p.freader)
		free(p.freader, context.allocator)
	}

	lsp.client_destroy(p.client)
	free(p.client, context.allocator)
	jsonrpc.conn_destroy(p.conn)
	free(p.conn, context.allocator)

	jsonrpc.conn_destroy(p.fake.conn)
	free(p.fake.conn, context.allocator)
	for m in p.fake.received {
		delete(m, p.fake.allocator)
	}
	delete(p.fake.received)
	for id in p.fake.cancel_ids {
		delete(id, p.fake.allocator)
	}
	delete(p.fake.cancel_ids)
	for note in p.fake.notes {
		delete(note.method, p.fake.allocator)
		delete(note.params, p.fake.allocator)
	}
	delete(p.fake.notes)
	if p.fake.init_params != "" {
		delete(p.fake.init_params, p.fake.allocator)
	}
	free(p.fake, context.allocator)

	platform.clock_destroy(p.clock)
	free(p.clock, context.allocator)
	free(p, context.allocator)
}

// --- scenarios --------------------------------------------------------------

// Concurrent calls from several threads must each receive their own reply
// (the pending-table correlation), and publishDiagnostics over the wire
// must reach the store (empty sets clear their URI).
@(test)
lsp_concurrent_calls_correlate :: proc(t: ^testing.T) {
	p := lsp_pair_init(t)
	if p == nil {
		testing.expectf(t, false, "pair init failed")
		return
	}
	defer lsp_pair_shutdown(p)

	Results :: struct {
		mu:   sync.Mutex,
		cond: sync.Cond,
		ok:   bool,
		done: int,
	}
	results := new(Results, context.allocator)
	defer free(results, context.allocator)
	results^ = {ok = true}

	Call_Args :: struct {
		client:  ^lsp.Client,
		index:   int,
		results: ^Results,
	}

	lsp_call_worker :: proc(data: rawptr) {
		args := cast(^Call_Args)data
		params := jsonutil.json_object(1, context.temp_allocator)
		jsonutil.obj_set(&params, "n", jsonutil.json_int(cast(i64)args.index))
		result, _, _, cerr := lsp.client_call(args.client, "test/echo", json.Value(json.Object(params)), context.temp_allocator)
		ok := false
		if cerr == .None {
			if v, found := jsonutil.obj_get(result, "n"); found {
				#partial switch x in v {
				case json.Integer:
					ok = x == cast(i64)args.index
				case:
				}
			}
		}
		sync.mutex_lock(&args.results.mu)
		args.results.ok = args.results.ok && ok // any mismatch sticks
		args.results.done += 1
		sync.cond_broadcast(&args.results.cond)
		sync.mutex_unlock(&args.results.mu)
	}

	N := 8
	args := make([]Call_Args, N, context.allocator)
	threads := make([dynamic]^thread.Thread, 0, N, context.allocator)
	for i in 0..<N {
		args[i] = {client = p.client, index = i, results = results}
		thr := thread.create_and_start_with_data(&args[i], lsp_call_worker, self_cleanup = false)
		if thr == nil {
			continue
		}
		append(&threads, thr)
	}

	deadline := platform.mono_ms() + 5000
	sync.mutex_lock(&results.mu)
	for results.done < N && platform.mono_ms() < deadline {
		sync.cond_wait_with_timeout(&results.cond, &results.mu, 50 * 1_000_000)
	}
	sync.mutex_unlock(&results.mu)

	testing.expect_value(t, len(threads), N)
	for thr in threads {
		thread.join(thr)
		free(thr, context.allocator)
	}
	delete(threads)
	delete(args)
	testing.expect(t, results.ok)
	testing.expect_value(t, results.done, N)
	testing.expect_value(t, fake_received_count(p.fake, "test/echo"), N)

	// publishDiagnostics over the wire: the echo roundtrip after it proves
	// the notification was processed first (single fake reader, FIFO pipe).
	// The versioned sequence also pins the versionSupport drop rule end to
	// end: the stale v3 set and the stale v3 empty clear both lose to the
	// v4 watermark, and the untagged empty still clears.
	pub_params := jsonutil.json_object(3, context.temp_allocator)
	jsonutil.obj_set(&pub_params, "uri", jsonutil.json_string("file:///a.go"))
	jsonutil.obj_set(&pub_params, "version", jsonutil.json_int(4))
	one := jsonutil.json_object(1, context.temp_allocator)
	jsonutil.obj_set(&one, "message", jsonutil.json_string("v4"))
	jsonutil.obj_set(
		&pub_params, "diagnostics", jsonutil.json_array({json.Value(json.Object(one))}, context.temp_allocator),
	)
	_ = jsonrpc.conn_notify(p.fake.conn, lsp.METHOD_PUBLISH_DIAGNOSTICS, json.Value(json.Object(pub_params)), context.temp_allocator)

	stale_params := jsonutil.json_object(3, context.temp_allocator)
	jsonutil.obj_set(&stale_params, "uri", jsonutil.json_string("file:///a.go"))
	jsonutil.obj_set(&stale_params, "version", jsonutil.json_int(3))
	two := jsonutil.json_object(1, context.temp_allocator)
	jsonutil.obj_set(&two, "message", jsonutil.json_string("stale"))
	jsonutil.obj_set(
		&stale_params, "diagnostics", jsonutil.json_array({json.Value(json.Object(two))}, context.temp_allocator),
	)
	_ = jsonrpc.conn_notify(p.fake.conn, lsp.METHOD_PUBLISH_DIAGNOSTICS, json.Value(json.Object(stale_params)), context.temp_allocator)

	_, _, _, echo_err := lsp.client_call(p.client, "test/echo", nil, context.temp_allocator)
	testing.expect_value(t, echo_err, jsonrpc.Call_Err.None)
	testing.expect_value(t, lsp.diagnostics_store_count(&p.client.diagnostics), 1)
	held, held_ok := lsp.diagnostics_store_get(&p.client.diagnostics, "file:///a.go", context.temp_allocator)
	testing.expect(t, held_ok)
	if held_ok {
		testing.expect(t, strings.contains(held, "v4"))
		delete(held, context.temp_allocator)
	}

	// A stale empty set must not clear the fresh entry.
	stale_clear := jsonutil.json_object(3, context.temp_allocator)
	jsonutil.obj_set(&stale_clear, "uri", jsonutil.json_string("file:///a.go"))
	jsonutil.obj_set(&stale_clear, "version", jsonutil.json_int(3))
	jsonutil.obj_set(&stale_clear, "diagnostics", jsonutil.json_array(nil, context.temp_allocator))
	_ = jsonrpc.conn_notify(p.fake.conn, lsp.METHOD_PUBLISH_DIAGNOSTICS, json.Value(json.Object(stale_clear)), context.temp_allocator)
	_, _, _, echo2 := lsp.client_call(p.client, "test/echo", nil, context.temp_allocator)
	testing.expect_value(t, echo2, jsonrpc.Call_Err.None)
	testing.expect_value(t, lsp.diagnostics_store_count(&p.client.diagnostics), 1)

	// The untagged empty set clears.
	diag_params := jsonutil.json_object(2, context.temp_allocator)
	jsonutil.obj_set(&diag_params, "uri", jsonutil.json_string("file:///a.go"))
	jsonutil.obj_set(&diag_params, "diagnostics", jsonutil.json_array(nil, context.temp_allocator))
	_ = jsonrpc.conn_notify(p.fake.conn, lsp.METHOD_PUBLISH_DIAGNOSTICS, json.Value(json.Object(diag_params)), context.temp_allocator)
	_, _, _, echo_err3 := lsp.client_call(p.client, "test/echo", nil, context.temp_allocator)
	testing.expect_value(t, echo_err3, jsonrpc.Call_Err.None)
	testing.expect_value(t, lsp.diagnostics_store_count(&p.client.diagnostics), 0) // empty set clears
}

// A cancelled in-flight call returns .Cancelled, the conn-level cancel port
// sends $/cancelRequest with the request id, and the late reply from the
// fake is discarded safely (the slot was abandoned).
@(test)
lsp_cancel_propagates_to_server :: proc(t: ^testing.T) {
	p := lsp_pair_init(t)
	if p == nil {
		testing.expectf(t, false, "pair init failed")
		return
	}
	defer lsp_pair_shutdown(p)

	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)
	defer platform.token_destroy(root, context.allocator)
	task := platform.token_derive(root, 0, context.allocator)
	defer platform.token_destroy(task, context.allocator)

	Blocked :: struct {
		client: ^lsp.Client,
		token:  ^platform.Cancel_Token,
		result: jsonrpc.Call_Err,
		mu:     sync.Mutex,
		cond:   sync.Cond,
		done:   bool,
	}
	blocked := new(Blocked, context.allocator)
	defer free(blocked, context.allocator)
	blocked^ = {client = p.client, token = task}

	blocked_caller :: proc(data: rawptr) {
		b := cast(^Blocked)data
		_, _, _, cerr := lsp.client_call(b.client, "test/slow", nil, context.temp_allocator, b.token)
		sync.mutex_lock(&b.mu)
		b.result = cerr
		b.done = true
		sync.cond_broadcast(&b.cond)
		sync.mutex_unlock(&b.mu)
	}
	thr := thread.create_and_start_with_data(blocked, blocked_caller, self_cleanup = false)

	// Deterministic arrival sync: the fake's handler takes its ticket
	// before holding the reply.
	fake_gate_wait_arrival(&p.fake.slow)

	platform.token_fire(root, .Cancelled)
	sync.mutex_lock(&blocked.mu)
	for !blocked.done {
		sync.cond_wait(&blocked.cond, &blocked.mu)
	}
	got := blocked.result
	sync.mutex_unlock(&blocked.mu)
	thread.join(thr)
	free(thr, context.allocator)
	testing.expect_value(t, got, jsonrpc.Call_Err.Cancelled)

	// The $/cancelRequest notification was written before .Cancelled
	// returned, but the fake's reader is parked inside the slow handler —
	// the frame sits unread in the up pipe. Let the slow reply go so the
	// reader reaches the cancel notification, then wait for its record.
	fake_gate_release(&p.fake.slow)
	fake_wait_cancel(p.fake, 1)
	ids := fake_cancel_ids_snapshot(p.fake)
	if len(ids) != 1 {
		// Bounds-panic guard: index below only runs on the expected shape.
		testing.expectf(t, false, "expected 1 cancel id, got %d", len(ids))
		return
	}
	testing.expect_value(t, ids[0], "1") // first request on this conn
}

// The bounded server->client queue: with the client's configuration
// handler gated inside the worker, exactly REQUEST_QUEUE_CAP entries are
// accepted (one held in the worker + a full chan) and the rest are
// answered immediately with RequestFailed — the caller learns the
// outcome, the reader never blocks.
@(test)
lsp_server_request_queue_overflow_replies_failed :: proc(t: ^testing.T) {
	p := lsp_pair_init(t)
	if p == nil {
		testing.expectf(t, false, "pair init failed")
		return
	}
	defer lsp_pair_shutdown(p)

	gate := new(Provider_Gate, context.allocator)
	defer free(gate, context.allocator)
	gate^ = {}
	p.client.config_provider = gated_config_provider
	p.client.config_host = gate

	// Stage 1 runs on its own thread: its reply only arrives after the
	// release, so the fan thread must not wait on it.
	First_Call :: struct {
		conn: ^jsonrpc.Conn,
		mu:   sync.Mutex,
		cond: sync.Cond,
		done: bool,
		ok:   bool,
	}
	first := new(First_Call, context.allocator)
	defer free(first, context.allocator)
	first^ = {conn = p.fake.conn}

	first_caller :: proc(data: rawptr) {
		fc := cast(^First_Call)data
		_, _, _, cerr := jsonrpc.conn_call(
			fc.conn, lsp.METHOD_WORKSPACE_CONFIGURATION, nil,
			context.temp_allocator, platform.mono_ms() + 10_000,
		)
		sync.mutex_lock(&fc.mu)
		fc.ok = cerr == .None
		fc.done = true
		sync.cond_broadcast(&fc.cond)
		sync.mutex_unlock(&fc.mu)
	}
	thr1 := thread.create_and_start_with_data(first, first_caller, self_cleanup = false)

	// Park point: the provider entered (worker occupied, chan empty).
	provider_gate_wait_entered(gate)

	// The defining property under test: a parked server->client handler
	// must NOT park the reader — client requests still roundtrip while
	// the worker holds the provider.
	probe_params := jsonutil.json_object(1, context.temp_allocator)
	jsonutil.obj_set(&probe_params, "n", jsonutil.json_int(99))
	_, _, _, probe_err := lsp.client_call(p.client, "test/echo", json.Value(json.Object(probe_params)), context.temp_allocator)
	if probe_err != .None {
		testing.expectf(t, false, "reader parked while the worker held the handler: %v", probe_err)
		provider_gate_release(gate)
		return
	}

	// Fan_Call is one concurrent configuration request. The chan only
	// fills if the requests are in flight TOGETHER: a sequential caller
	// would hold one request at a time and never overflow anything.
	Fan_Call :: struct {
		conn: ^jsonrpc.Conn,
		fan:  ^Fan_State,
	}
	Fan_State :: struct {
		conn:        ^jsonrpc.Conn,
		ok:          int,
		failed:      int,
		failed_code: jsonrpc.Err_Code,
		mu:          sync.Mutex,
		cond:        sync.Cond,
	}
	fan := new(Fan_State, context.allocator)
	defer free(fan, context.allocator)
	fan^ = {conn = p.fake.conn, failed_code = .None}

	fan_caller :: proc(data: rawptr) {
		fc := cast(^Fan_Call)data
		_, code, _, cerr := jsonrpc.conn_call(
			fc.conn, lsp.METHOD_WORKSPACE_CONFIGURATION, nil,
			context.temp_allocator, platform.mono_ms() + 10_000,
		)
		sync.mutex_lock(&fc.fan.mu)
		if cerr == .None {
			fc.fan.ok += 1
		} else if cerr == .Error_Response {
			fc.fan.failed += 1
			fc.fan.failed_code = code
		}
		sync.cond_broadcast(&fc.fan.cond)
		sync.mutex_unlock(&fc.fan.mu)
	}

	// The worker is held in the gated provider: of 19 concurrent calls,
	// 16 fill the chan and 3 overflow.
	FAN_CALLS := 19
	fan_calls := make([]Fan_Call, FAN_CALLS, context.allocator)
	fan_threads := make([dynamic]^thread.Thread, 0, FAN_CALLS, context.allocator)
	for i in 0..<FAN_CALLS {
		fan_calls[i] = {conn = p.fake.conn, fan = fan}
		thr := thread.create_and_start_with_data(&fan_calls[i], fan_caller, self_cleanup = false)
		if thr == nil {
			continue
		}
		append(&fan_threads, thr)
	}

	// Wait until the three rejections came back (queue full: 17 accepted —
	// one held in the worker plus a full chan of 16).
	deadline := platform.mono_ms() + 5000
	sync.mutex_lock(&fan.mu)
	for fan.failed < 3 && platform.mono_ms() < deadline {
		sync.cond_wait_with_timeout(&fan.cond, &fan.mu, 50 * 1_000_000)
	}
	sync.mutex_unlock(&fan.mu)

	// Release the provider: the held call and the queued 16 drain through.
	provider_gate_release(gate)

	for thr in fan_threads {
		thread.join(thr)
		free(thr, context.allocator)
	}
	delete(fan_threads)
	delete(fan_calls)
	sync.mutex_lock(&first.mu)
	for !first.done {
		sync.cond_wait(&first.cond, &first.mu)
	}
	first_ok := first.ok
	sync.mutex_unlock(&first.mu)
	thread.join(thr1)
	free(thr1, context.allocator)

	sync.mutex_lock(&fan.mu)
	ok_count := fan.ok
	failed_count := fan.failed
	failed_code := fan.failed_code
	sync.mutex_unlock(&fan.mu)
	testing.expect(t, first_ok)
	testing.expect_value(t, failed_count, 3)
	testing.expect_value(t, failed_code, jsonrpc.Err_Code.Request_Failed)
	testing.expect_value(t, ok_count, 16)
}

// Provider_Gate parks the FIRST configuration-provider entry until the
// test releases it (the single queue worker runs the provider, so the
// first-entry flag needs no lock — the cond/mutex pair below is only for
// the enter/release handshake).
Provider_Gate :: struct {
	mu:       sync.Mutex,
	cond:     sync.Cond,
	entered:  bool,
	released: bool,
}

provider_gate_wait_entered :: proc(g: ^Provider_Gate) {
	sync.mutex_lock(&g.mu)
	for !g.entered {
		sync.cond_wait(&g.cond, &g.mu)
	}
	sync.mutex_unlock(&g.mu)
}

provider_gate_release :: proc(g: ^Provider_Gate) {
	sync.mutex_lock(&g.mu)
	g.released = true
	sync.cond_broadcast(&g.cond)
	sync.mutex_unlock(&g.mu)
}

gated_config_provider :: proc(user: rawptr, params: json.Value, arena: mem.Allocator) -> json.Value {
	gate := cast(^Provider_Gate)user
	sync.mutex_lock(&gate.mu)
	first := !gate.entered
	if first {
		gate.entered = true
		sync.cond_broadcast(&gate.cond)
		for !gate.released {
			sync.cond_wait(&gate.cond, &gate.mu)
		}
	}
	sync.mutex_unlock(&gate.mu)
	arr := make(json.Array, 0, 1, arena)
	return json.Value(json.Array(arr))
}

// A blocked call is released with .Closed when the client's conn closes
// (pending_fail_all), and the request-queue worker is joined by the same
// close — teardown afterwards is clean.
@(test)
lsp_close_releases_pending_waiters :: proc(t: ^testing.T) {
	p := lsp_pair_init(t)
	if p == nil {
		testing.expectf(t, false, "pair init failed")
		return
	}
	defer lsp_pair_shutdown(p)

	Blocked :: struct {
		client: ^lsp.Client,
		result: jsonrpc.Call_Err,
		mu:     sync.Mutex,
		cond:   sync.Cond,
		done:   bool,
	}
	blocked := new(Blocked, context.allocator)
	defer free(blocked, context.allocator)
	blocked^ = {client = p.client}

	blocked_caller :: proc(data: rawptr) {
		b := cast(^Blocked)data
		_, _, _, cerr := lsp.client_call(b.client, "test/slow", nil, context.temp_allocator)
		sync.mutex_lock(&b.mu)
		b.result = cerr
		b.done = true
		sync.cond_broadcast(&b.cond)
		sync.mutex_unlock(&b.mu)
	}
	thr := thread.create_and_start_with_data(blocked, blocked_caller, self_cleanup = false)

	fake_gate_wait_arrival(&p.fake.slow) // the request is in the fake's hands

	jsonrpc.conn_close(p.conn)

	sync.mutex_lock(&blocked.mu)
	for !blocked.done {
		sync.cond_wait(&blocked.cond, &blocked.mu)
	}
	got := blocked.result
	sync.mutex_unlock(&blocked.mu)
	thread.join(thr)
	free(thr, context.allocator)
	testing.expect_value(t, got, jsonrpc.Call_Err.Closed)

	fake_gate_release(&p.fake.slow)
}

// The diagnostics store: latest wins, an empty set clears, an empty set on
// an unknown URI is a no-op, and the cap holds at DIAGNOSTICS_MAX_FILES.
// Pure store test — no wire.
@(test)
lsp_diagnostics_store_bounds :: proc(t: ^testing.T) {
	s: lsp.Diagnostics_Store
	lsp.diagnostics_store_init(&s, context.allocator)
	defer lsp.diagnostics_store_destroy(&s)

	lsp.diagnostics_store_set(&s, "file:///a.go", `[{"message":"x"}]`)
	lsp.diagnostics_store_set(&s, "file:///a.go", `[{"message":"y"}]`)
	lsp.diagnostics_store_set(&s, "file:///b.go", `[{"message":"z"}]`)
	testing.expect_value(t, lsp.diagnostics_store_count(&s), 2)
	lsp.diagnostics_store_set(&s, "file:///b.go", "[]")
	testing.expect_value(t, lsp.diagnostics_store_count(&s), 1)
	lsp.diagnostics_store_set(&s, "file:///c.go", "[]")
	testing.expect_value(t, lsp.diagnostics_store_count(&s), 1)

	for i in 0..<lsp.DIAGNOSTICS_MAX_FILES + 8 {
		uri := strings.concatenate({"file:///f/", util.int_to_dec(i, context.temp_allocator), ".go"}, context.temp_allocator)
		lsp.diagnostics_store_set(&s, uri, `[{"message":"m"}]`)
	}
	testing.expect_value(t, lsp.diagnostics_store_count(&s), lsp.DIAGNOSTICS_MAX_FILES)
}

// The version watermark behind publishDiagnostics.versionSupport: a
// publication tagged with a document version strictly older than the last
// applied one for the URI is a stale snapshot and is dropped — sets and
// clears alike — while an untagged publication always applies and leaves
// the watermark alone. Pure store test — no wire.
@(test)
lsp_diagnostics_store_version_watermark :: proc(t: ^testing.T) {
	s: lsp.Diagnostics_Store
	lsp.diagnostics_store_init(&s, context.allocator)
	defer lsp.diagnostics_store_destroy(&s)

	uri := "file:///v.go"
	lsp.diagnostics_store_set(&s, uri, `[{"message":"v5"}]`, 5)
	lsp.diagnostics_store_set(&s, uri, `[{"message":"stale"}]`, 3) // stale: dropped
	raw, ok := lsp.diagnostics_store_get(&s, uri, context.temp_allocator)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, raw, `[{"message":"v5"}]`)
		delete(raw, context.temp_allocator)
	}

	// Untagged publications apply unconditionally without resetting the
	// watermark — a later stale tagged set still loses to v5.
	lsp.diagnostics_store_set(&s, uri, `[{"message":"untagged"}]`)
	raw2, ok2 := lsp.diagnostics_store_get(&s, uri, context.temp_allocator)
	testing.expect(t, ok2)
	if ok2 {
		testing.expect_value(t, raw2, `[{"message":"untagged"}]`)
		delete(raw2, context.temp_allocator)
	}
	lsp.diagnostics_store_set(&s, uri, `[{"message":"stale"}]`, 4)
	testing.expect_value(t, lsp.diagnostics_store_count(&s), 1)
	raw3, ok3 := lsp.diagnostics_store_get(&s, uri, context.temp_allocator)
	testing.expect(t, ok3)
	if ok3 {
		testing.expect_value(t, raw3, `[{"message":"untagged"}]`)
		delete(raw3, context.temp_allocator)
	}

	// A fresh version applies again; a stale empty set does not clear.
	lsp.diagnostics_store_set(&s, uri, `[{"message":"v6"}]`, 6)
	lsp.diagnostics_store_set(&s, uri, "[]", 4) // stale clear: dropped
	testing.expect_value(t, lsp.diagnostics_store_count(&s), 1)
	raw4, ok4 := lsp.diagnostics_store_get(&s, uri, context.temp_allocator)
	testing.expect(t, ok4)
	if ok4 {
		testing.expect_value(t, raw4, `[{"message":"v6"}]`)
		delete(raw4, context.temp_allocator)
	}

	// A fresh empty set clears.
	lsp.diagnostics_store_set(&s, uri, "[]", 7)
	testing.expect_value(t, lsp.diagnostics_store_count(&s), 0)

	// The watermark survives the empty clear as a bare marker: a late
	// publication tagged below the cleared version stays dropped, while an
	// untagged late publication applies again (and still leaves the
	// watermark alone — a later stale set keeps losing to it).
	lsp.diagnostics_store_set(&s, uri, `[{"message":"late-stale"}]`, 5)
	testing.expect_value(t, lsp.diagnostics_store_count(&s), 0)
	lsp.diagnostics_store_set(&s, uri, `[{"message":"late-untagged"}]`)
	testing.expect_value(t, lsp.diagnostics_store_count(&s), 1)
	raw5, ok5 := lsp.diagnostics_store_get(&s, uri, context.temp_allocator)
	testing.expect(t, ok5)
	if ok5 {
		testing.expect_value(t, raw5, `[{"message":"late-untagged"}]`)
		delete(raw5, context.temp_allocator)
	}
	lsp.diagnostics_store_set(&s, uri, `[{"message":"late-stale-2"}]`, 6)
	testing.expect_value(t, lsp.diagnostics_store_count(&s), 1)
	raw6, ok6 := lsp.diagnostics_store_get(&s, uri, context.temp_allocator)
	testing.expect(t, ok6)
	if ok6 {
		testing.expect_value(t, raw6, `[{"message":"late-untagged"}]`)
		delete(raw6, context.temp_allocator)
	}
}

// The store must own its map keys: the producer passes a view into the
// notification's per-message arena, which dies right after dispatch. Poison
// the caller's bytes and the store must keep matching, overwriting, and
// clearing by its own clones.
@(test)
lsp_diagnostics_store_keys_survive_caller_memory :: proc(t: ^testing.T) {
	s: lsp.Diagnostics_Store
	lsp.diagnostics_store_init(&s, context.allocator)
	defer lsp.diagnostics_store_destroy(&s)

	uri := strings.clone("file:///own.go", context.temp_allocator)
	lsp.diagnostics_store_set(&s, uri, `[{"message":"a"}]`)
	poison := transmute([]byte)uri
	for i in 0..<len(poison) {
		poison[i] = 0x78
	}

	// Re-publish under a fresh, equal URI: the overwrite path must find the
	// stored entry (latest wins), not append a second one.
	again := strings.clone("file:///own.go", context.temp_allocator)
	lsp.diagnostics_store_set(&s, again, `[{"message":"b"}]`)
	testing.expect_value(t, lsp.diagnostics_store_count(&s), 1)
	raw, ok := lsp.diagnostics_store_get(&s, again, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, raw, `[{"message":"b"}]`)
	delete(raw, context.temp_allocator)

	// The clear path must remove the entry, not silently miss the key.
	lsp.diagnostics_store_set(&s, again, "[]")
	testing.expect_value(t, lsp.diagnostics_store_count(&s), 0)
}

// The store canonicalizes server URI spellings onto the local encoder's
// form, so readers looking up with file_uri find entries no matter how
// the server encoded the URI.
@(test)
lsp_diagnostics_store_canonicalizes_server_uris :: proc(t: ^testing.T) {
	s: lsp.Diagnostics_Store
	lsp.diagnostics_store_init(&s, context.allocator)
	defer lsp.diagnostics_store_destroy(&s)

	// The server percent-encoded the 日; the store must key by our form.
	lsp.diagnostics_store_set(&s, "file:///proj/%E6%97%A5.go", `[{"message":"a"}]`)
	local := symbol.file_uri("/proj/日.go", context.allocator)
	defer delete(local)
	testing.expect_value(t, lsp.diagnostics_store_count(&s), 1)

	raw, ok := lsp.diagnostics_store_get(&s, local, context.temp_allocator)
	testing.expectf(t, ok, "local form %s missed the server-spelled entry", local)
	if ok {
		testing.expect_value(t, raw, `[{"message":"a"}]`)
	}

	// A different server spelling of the same file overwrites the entry
	// instead of appending (percent hex is case-insensitive).
	lsp.diagnostics_store_set(&s, "file:///proj/%e6%97%a5.go", `[{"message":"b"}]`)
	testing.expect_value(t, lsp.diagnostics_store_count(&s), 1)
	raw2, ok2 := lsp.diagnostics_store_get(&s, local, context.temp_allocator)
	testing.expect(t, ok2)
	if ok2 {
		testing.expect_value(t, raw2, `[{"message":"b"}]`)
	}
}

// Closing a document drops its stored diagnostics: a server that never
// publishes an empty set on didClose would otherwise leave the last set
// riding into the diagnostics fallback and code-action context, and a
// later reopen of the same file would resurface it.
@(test)
lsp_doc_close_clears_stored_diagnostics :: proc(t: ^testing.T) {
	p := lsp_pair_init(t)
	if p == nil {
		testing.expectf(t, false, "pair init failed")
		return
	}
	defer lsp_pair_shutdown(p)

	uri := "file:///close.go"
	testing.expect(t, lsp.doc_open(p.client, uri, "go", "package main\n"))

	diag := jsonutil.json_object(1, context.temp_allocator)
	jsonutil.obj_set(&diag, "message", jsonutil.json_string("x"))
	diag_params := jsonutil.json_object(2, context.temp_allocator)
	jsonutil.obj_set(&diag_params, "uri", jsonutil.json_string(uri))
	jsonutil.obj_set(&diag_params, "diagnostics", jsonutil.json_array({json.Value(json.Object(diag))}, context.temp_allocator))
	_ = jsonrpc.conn_notify(p.fake.conn, lsp.METHOD_PUBLISH_DIAGNOSTICS, json.Value(json.Object(diag_params)), context.temp_allocator)
	_, _, _, echo_err := lsp.client_call(p.client, "test/echo", nil, context.temp_allocator)
	testing.expect_value(t, echo_err, jsonrpc.Call_Err.None)
	testing.expect_value(t, lsp.diagnostics_store_count(&p.client.diagnostics), 1)

	testing.expect(t, lsp.doc_close(p.client, uri))
	testing.expect_value(t, lsp.diagnostics_store_count(&p.client.diagnostics), 0)
	_, ok := lsp.diagnostics_store_get(&p.client.diagnostics, uri, context.temp_allocator)
	testing.expect(t, !ok, "the closed document's set must be gone")

	// Reopening does not resurface the old set.
	testing.expect(t, lsp.doc_open(p.client, uri, "go", "package main\n"))
	testing.expect_value(t, lsp.diagnostics_store_count(&p.client.diagnostics), 0)
}

// lsp_publish_one pushes one single-diagnostic publishDiagnostics for
// `uri` through the fake's conn (the diagnostic's message field carries
// `message`, so stored-set asserts can tell sets apart).
lsp_publish_one :: proc(conn: ^jsonrpc.Conn, uri, message: string) {
	diag := jsonutil.json_object(1, context.temp_allocator)
	jsonutil.obj_set(&diag, "message", jsonutil.json_string(message))
	params := jsonutil.json_object(2, context.temp_allocator)
	jsonutil.obj_set(&params, "uri", jsonutil.json_string(uri))
	jsonutil.obj_set(
		&params,
		"diagnostics",
		jsonutil.json_array({json.Value(json.Object(diag))}, context.temp_allocator),
	)
	_ = jsonrpc.conn_notify(conn, lsp.METHOD_PUBLISH_DIAGNOSTICS, json.Value(json.Object(params)), context.temp_allocator)
}

// A document's open epoch starts clean: a late publication that re-landed
// for the closed document (the store cannot know it closed and reopened)
// must not ride into the new epoch's diagnostics reads. Only the
// epoch-creating open clears — a shared open keeps the epoch's live set.
@(test)
lsp_doc_open_starts_clean_diagnostics_epoch :: proc(t: ^testing.T) {
	p := lsp_pair_init(t)
	if p == nil {
		testing.expectf(t, false, "pair init failed")
		return
	}
	defer lsp_pair_shutdown(p)

	uri := "file:///epoch.go"

	lsp_publish_one(p.fake.conn, uri, "stale-from-last-epoch")
	_, _, _, echo_err := lsp.client_call(p.client, "test/echo", nil, context.temp_allocator)
	testing.expect_value(t, echo_err, jsonrpc.Call_Err.None)
	testing.expect_value(t, lsp.diagnostics_store_count(&p.client.diagnostics), 1)

	testing.expect(t, lsp.doc_open(p.client, uri, "go", "package main\n"))
	testing.expectf(
		t,
		lsp.diagnostics_store_count(&p.client.diagnostics) == 0,
		"the new epoch must not inherit the old set",
	)

	// The shared open keeps the epoch's live set: only the epoch-creating
	// open clears.
	lsp_publish_one(p.fake.conn, uri, "fresh")
	_, _, _, echo2 := lsp.client_call(p.client, "test/echo", nil, context.temp_allocator)
	testing.expect_value(t, echo2, jsonrpc.Call_Err.None)
	testing.expect(t, lsp.doc_open(p.client, uri, "go", "shared"))
	testing.expect_value(t, lsp.diagnostics_store_count(&p.client.diagnostics), 1)
}

// The lifecycle handshake: initialize parses the server capabilities into
// the closed view (numeric sync kind, bool provider, object-form provider
// truthy, explicit false), initialized reaches the server, and shutdown
// speaks shutdown + exit. Before the handshake, shutdown is a no-op.
@(test)
lsp_initialize_handshake_and_shutdown :: proc(t: ^testing.T) {
	p := lsp_pair_init(t)
	if p == nil {
		testing.expectf(t, false, "pair init failed")
		return
	}
	defer lsp_pair_shutdown(p)

	// Pre-handshake: nothing to tear down on the wire.
	_, _, pre_err := lsp.client_shutdown(p.client, context.temp_allocator)
	testing.expect_value(t, pre_err, jsonrpc.Call_Err.None)
	testing.expect_value(t, fake_received_count(p.fake, lsp.METHOD_SHUTDOWN), 0)

	single := []lsp.Folder{{uri = "file:///w", name = "w"}}
	ok, _, _, init_err := lsp.client_initialize(p.client, single, context.temp_allocator)
	testing.expect_value(t, init_err, jsonrpc.Call_Err.None)
	testing.expect(t, ok)
	testing.expect(t, lsp.client_is_initialized(p.client))

	// Single-folder wire shape (the pre-multi-root form): rootUri carries
	// the primary folder and the folder array has exactly that one entry.
	init_v, iperr := json.parse_string(p.fake.init_params, allocator = context.temp_allocator)
	testing.expect(t, iperr == nil)
	if root_v, rok := jsonutil.obj_get(init_v, "rootUri"); rok {
		testing.expect(t, jsonutil.value_str(root_v) == "file:///w")
	} else {
		testing.expectf(t, false, "initialize params lack rootUri")
	}
	if folders_v, fok := jsonutil.obj_get(init_v, "workspaceFolders"); fok {
		#partial switch fa in folders_v {
		case json.Array:
			testing.expect(t, len(fa) == 1)
			if len(fa) == 1 {
				if uri_v, uok := jsonutil.obj_get(fa[0], "uri"); uok {
					testing.expect(t, jsonutil.value_str(uri_v) == "file:///w")
				}
				if name_v, nok := jsonutil.obj_get(fa[0], "name"); nok {
					testing.expect(t, jsonutil.value_str(name_v) == "w")
				}
			}
		case:
			testing.expectf(t, false, "workspaceFolders is not an array")
		}
	} else {
		testing.expectf(t, false, "initialize params lack workspaceFolders")
	}

	caps := lsp.client_caps(p.client)
	testing.expect_value(t, caps.sync_kind, lsp.Sync_Kind.Incremental)
	testing.expect(t, caps.definition)
	testing.expect(t, caps.declaration)
	testing.expect(t, caps.implementation)
	testing.expect(t, caps.references)
	testing.expect(t, caps.document_symbol) // {} provider object is truthy
	testing.expect(t, caps.document_diagnostic)
	testing.expect(t, !caps.type_definition) // an absent provider stays off

	fake_note_wait(p.fake, lsp.METHOD_INITIALIZED, 1)

	_, _, shut_err := lsp.client_shutdown(p.client, context.temp_allocator)
	testing.expect_value(t, shut_err, jsonrpc.Call_Err.None)
	fake_note_wait(p.fake, lsp.METHOD_EXIT, 1)
	testing.expect_value(t, fake_received_count(p.fake, lsp.METHOD_SHUTDOWN), 1)
}

// Document sync: didOpen carries version 1 and the full text, a repeated
// open is refused (didOpen/didClose must pair on the server side), a full
// change bumps the version and carries no range, close drops the mirror,
// and re-open starts a fresh version line.
@(test)
lsp_document_sync_full_events :: proc(t: ^testing.T) {
	p := lsp_pair_init(t)
	if p == nil {
		testing.expectf(t, false, "pair init failed")
		return
	}
	defer lsp_pair_shutdown(p)

	single := []lsp.Folder{{uri = "file:///w", name = "w"}}
	_, _, _, init_err := lsp.client_initialize(p.client, single, context.temp_allocator)
	testing.expect_value(t, init_err, jsonrpc.Call_Err.None)

	testing.expect(t, lsp.doc_open(p.client, "file:///a.go", "go", "package main\n"))
	fake_note_wait(p.fake, lsp.METHOD_DID_OPEN, 1)
	open_params := fake_note_get(p.fake, lsp.METHOD_DID_OPEN, 0)
	testing.expect(t, strings.contains(open_params, "\"version\":1"))
	testing.expect(t, strings.contains(open_params, "\"text\":\"package main\\n\""))
	testing.expect(t, strings.contains(open_params, "file:///a.go"))

	// A shared open succeeds without a second wire didOpen and keeps the
	// epoch's text: one didOpen reaches the server per open epoch.
	testing.expect(t, lsp.doc_open(p.client, "file:///a.go", "go", "dup"))
	testing.expect_value(t, fake_note_count(p.fake, lsp.METHOD_DID_OPEN), 1)

	testing.expect(t, lsp.doc_change_full(p.client, "file:///a.go", "package main\n// x\n"))
	fake_note_wait(p.fake, lsp.METHOD_DID_CHANGE, 1)
	change_params := fake_note_get(p.fake, lsp.METHOD_DID_CHANGE, 0)
	testing.expect(t, strings.contains(change_params, "\"version\":2"))
	testing.expect(t, !strings.contains(change_params, "\"range\"")) // full replacement carries no range
	testing.expect(t, strings.contains(change_params, "// x"))
	testing.expect_value(t, lsp.doc_version(p.client, "file:///a.go"), 2)
	testing.expect_value(t, lsp.doc_version(p.client, "file:///none.go"), 0)

	testing.expect(t, !lsp.doc_change_full(p.client, "file:///none.go", "x"))

	// Two openers, two closes: the first close drops a count without a
	// wire didClose; the last one sends it and the entry dies.
	testing.expect(t, lsp.doc_close(p.client, "file:///a.go"))
	testing.expect_value(t, fake_note_count(p.fake, lsp.METHOD_DID_CLOSE), 0)
	testing.expect_value(t, lsp.doc_version(p.client, "file:///a.go"), 2)
	testing.expect(t, lsp.doc_close(p.client, "file:///a.go"))
	fake_note_wait(p.fake, lsp.METHOD_DID_CLOSE, 1)
	testing.expect_value(t, lsp.doc_version(p.client, "file:///a.go"), 0)
	testing.expect(t, !lsp.doc_close(p.client, "file:///a.go"))

	testing.expect(t, lsp.doc_open(p.client, "file:///a.go", "go", "z"))
	fake_note_wait(p.fake, lsp.METHOD_DID_OPEN, 2)
	testing.expect_value(t, lsp.doc_version(p.client, "file:///a.go"), 1)
}

// The cross-file-reference readiness wait: the first publishDiagnostics —
// even an empty set (the server processed the file) — latches Diagnostics,
// and the once-latch serves every later call from the cache.
@(test)
lsp_crossref_wait_first_diagnostics :: proc(t: ^testing.T) {
	p := lsp_pair_init(t)
	if p == nil {
		testing.expectf(t, false, "pair init failed")
		return
	}
	defer lsp_pair_shutdown(p)

	diag_params := jsonutil.json_object(2, context.temp_allocator)
	jsonutil.obj_set(&diag_params, "uri", jsonutil.json_string("file:///a.go"))
	jsonutil.obj_set(&diag_params, "diagnostics", jsonutil.json_array(nil, context.temp_allocator))
	_ = jsonrpc.conn_notify(
		p.fake.conn, lsp.METHOD_PUBLISH_DIAGNOSTICS,
		json.Value(json.Object(diag_params)), context.temp_allocator,
	)

	testing.expect_value(
		t, lsp.client_wait_cross_file_refs(p.client), lsp.Wait_Outcome.Diagnostics,
	)
	// The once-latch: the second call returns the cached outcome.
	testing.expect_value(
		t, lsp.client_wait_cross_file_refs(p.client), lsp.Wait_Outcome.Diagnostics,
	)
	// The empty set still cleared the diagnostics store entry.
	testing.expect_value(t, lsp.diagnostics_store_count(&p.client.diagnostics), 0)
}

// A $/progress WorkDone end is the other readiness signal — and only the
// end: pair 1 shows a bare 'begin' does not latch (window expires, no
// fallback), pair 2 shows the end does.
@(test)
lsp_crossref_wait_progress_end :: proc(t: ^testing.T) {
	p := lsp_pair_init(t)
	if p == nil {
		testing.expectf(t, false, "pair init failed")
		return
	}
	defer lsp_pair_shutdown(p)

	begin_params := jsonutil.json_object(2, context.temp_allocator)
	jsonutil.obj_set(&begin_params, "token", jsonutil.json_int(1))
	begin_value := jsonutil.json_object(1, context.temp_allocator)
	jsonutil.obj_set(&begin_value, "kind", jsonutil.json_string("begin"))
	jsonutil.obj_set(&begin_params, "value", json.Value(json.Object(begin_value)))
	_ = jsonrpc.conn_notify(
		p.fake.conn, lsp.METHOD_PROGRESS, json.Value(json.Object(begin_params)),
		context.temp_allocator,
	)

	// A begin alone never latches: shrink the event window and disable the
	// fallback so the ignored signal turns into a Timeout.
	p.client.crossref_event_timeout_ms = 60
	p.client.crossref_fallback_ms = 0
	testing.expect_value(
		t, lsp.client_wait_cross_file_refs(p.client), lsp.Wait_Outcome.Timeout,
	)

	// The latch now holds Timeout on this client; the end signal needs a
	// fresh pair.
	p2 := lsp_pair_init(t)
	if p2 == nil {
		testing.expectf(t, false, "pair init failed")
		return
	}
	defer lsp_pair_shutdown(p2)

	end_params := jsonutil.json_object(2, context.temp_allocator)
	jsonutil.obj_set(&end_params, "token", jsonutil.json_int(2))
	end_value := jsonutil.json_object(1, context.temp_allocator)
	jsonutil.obj_set(&end_value, "kind", jsonutil.json_string("end"))
	jsonutil.obj_set(&end_params, "value", json.Value(json.Object(end_value)))
	_ = jsonrpc.conn_notify(
		p2.fake.conn, lsp.METHOD_PROGRESS, json.Value(json.Object(end_params)),
		context.temp_allocator,
	)
	testing.expect_value(
		t, lsp.client_wait_cross_file_refs(p2.client), lsp.Wait_Outcome.Progress,
	)
}

// A fired token returns Cancelled without latching (a retry re-enters the
// wait); with no signal and no fallback the retry then times out and
// latches.
@(test)
lsp_crossref_wait_cancel_then_timeout :: proc(t: ^testing.T) {
	p := lsp_pair_init(t)
	if p == nil {
		testing.expectf(t, false, "pair init failed")
		return
	}
	defer lsp_pair_shutdown(p)

	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)
	defer platform.token_destroy(root, context.allocator)
	task := platform.token_derive(root, 0, context.allocator)
	defer platform.token_destroy(task, context.allocator)

	p.client.crossref_event_timeout_ms = 60
	p.client.crossref_fallback_ms = 0

	platform.token_fire(root, .Cancelled)
	testing.expect_value(
		t, lsp.client_wait_cross_file_refs(p.client, task), lsp.Wait_Outcome.Cancelled,
	)
	// Not latched: a caller without the dead token re-enters and, with
	// nothing arriving, times out for real.
	testing.expect_value(
		t, lsp.client_wait_cross_file_refs(p.client), lsp.Wait_Outcome.Timeout,
	)
}

// The fallback settle wait on a virtual clock: no signal arrives, the
// event window expires and the fallback clock_wait releases only when the
// test advances time past it — the whole path is deterministic, zero real
// sleeps. (No client_call on this pair: its deadlines would mismatch the
// virtual base.)
@(test)
lsp_crossref_wait_fallback_virtual_clock :: proc(t: ^testing.T) {
	p := lsp_pair_init(t, virtual_clock = true)
	if p == nil {
		testing.expectf(t, false, "pair init failed")
		return
	}
	defer lsp_pair_shutdown(p)

	Wait_Job :: struct {
		client:  ^lsp.Client,
		outcome: lsp.Wait_Outcome,
		mu:      sync.Mutex,
		cond:    sync.Cond,
		done:    bool,
	}
	w := new(Wait_Job, context.allocator)
	defer free(w, context.allocator)
	w^ = {client = p.client}

	wait_worker :: proc(data: rawptr) {
		wj := cast(^Wait_Job)data
		outcome := lsp.client_wait_cross_file_refs(wj.client)
		sync.mutex_lock(&wj.mu)
		wj.outcome = outcome
		wj.done = true
		sync.cond_broadcast(&wj.cond)
		sync.mutex_unlock(&wj.mu)
	}
	thr := thread.create_and_start_with_data(w, wait_worker, self_cleanup = false)

	// Pump virtual time until the waiter reports: the 5 s event window
	// needs enough advances to pass, then the 1 s fallback clock_wait
	// releases on the next one. Bounded by a real-time guard.
	deadline := platform.mono_ms() + 5000
	sync.mutex_lock(&w.mu)
	for !w.done && platform.mono_ms() < deadline {
		sync.mutex_unlock(&w.mu)
		platform.clock_advance(p.clock, 1000)
		sync.mutex_lock(&w.mu)
		if w.done {
			break
		}
		sync.cond_wait_with_timeout(&w.cond, &w.mu, 20 * 1_000_000)
	}
	done := w.done
	outcome := w.outcome
	sync.mutex_unlock(&w.mu)
	thread.join(thr)
	free(thr, context.allocator)

	testing.expect(t, done)
	testing.expect_value(t, outcome, lsp.Wait_Outcome.Fallback)
	// Latched: the immediate second call serves the cached outcome.
	testing.expect_value(
		t, lsp.client_wait_cross_file_refs(p.client), lsp.Wait_Outcome.Fallback,
	)
}

// Cancelling during the fallback settle wait: the token fires after the
// event window expired but before the fallback span elapses — the sliced
// fallback wait observes it at the next checkpoint and the wait returns
// Cancelled without latching (the retry then times out with the fallback
// disabled). Deterministic on the virtual clock.
@(test)
lsp_crossref_wait_cancel_during_fallback :: proc(t: ^testing.T) {
	p := lsp_pair_init(t, virtual_clock = true)
	if p == nil {
		testing.expectf(t, false, "pair init failed")
		return
	}
	defer lsp_pair_shutdown(p)

	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)
	defer platform.token_destroy(root, context.allocator)
	task := platform.token_derive(root, 0, context.allocator)
	defer platform.token_destroy(task, context.allocator)

	p.client.crossref_event_timeout_ms = 5000
	p.client.crossref_fallback_ms = 1000

	Wait_Job :: struct {
		client:  ^lsp.Client,
		token:   ^platform.Cancel_Token,
		outcome: lsp.Wait_Outcome,
		mu:      sync.Mutex,
		cond:    sync.Cond,
		done:    bool,
	}
	w := new(Wait_Job, context.allocator)
	defer free(w, context.allocator)
	w^ = {client = p.client, token = task}

	wait_worker :: proc(data: rawptr) {
		wj := cast(^Wait_Job)data
		outcome := lsp.client_wait_cross_file_refs(wj.client, wj.token)
		sync.mutex_lock(&wj.mu)
		wj.outcome = outcome
		wj.done = true
		sync.cond_broadcast(&wj.cond)
		sync.mutex_unlock(&wj.mu)
	}
	thr := thread.create_and_start_with_data(w, wait_worker, self_cleanup = false)

	// Pass the event window so the waiter falls into the settle wait, then
	// fire the token and keep pumping so the sliced fallback wait reaches
	// its next checkpoint. Bounded by a real-time guard.
	platform.clock_advance(p.clock, 6000)
	platform.token_fire(root, .Cancelled)
	deadline := platform.mono_ms() + 5000
	sync.mutex_lock(&w.mu)
	for !w.done && platform.mono_ms() < deadline {
		sync.mutex_unlock(&w.mu)
		platform.clock_advance(p.clock, 300)
		sync.mutex_lock(&w.mu)
		if w.done {
			break
		}
		sync.cond_wait_with_timeout(&w.cond, &w.mu, 20 * 1_000_000)
	}
	done := w.done
	outcome := w.outcome
	sync.mutex_unlock(&w.mu)
	thread.join(thr)
	free(thr, context.allocator)

	testing.expect(t, done)
	testing.expect_value(t, outcome, lsp.Wait_Outcome.Cancelled)
	// Not latched: with both windows disabled the retry times out at once
	// (the virtual clock no longer advances past a fresh event window).
	p.client.crossref_event_timeout_ms = 0
	p.client.crossref_fallback_ms = 0
	testing.expect_value(
		t, lsp.client_wait_cross_file_refs(p.client), lsp.Wait_Outcome.Timeout,
	)
}

// Multi-folder initialize: every workspace folder is announced and
// folders[0] is also the rootUri — the wire shape multi-root servers
// (a view per folder) consume.
@(test)
lsp_initialize_multi_folder_params :: proc(t: ^testing.T) {
	p := lsp_pair_init(t)
	if p == nil {
		testing.expectf(t, false, "pair init failed")
		return
	}
	defer lsp_pair_shutdown(p)

	folders := []lsp.Folder{
		{uri = "file:///proj/modA", name = "modA"},
		{uri = "file:///proj/modB", name = "modB"},
	}
	ok, _, _, init_err := lsp.client_initialize(p.client, folders, context.temp_allocator)
	testing.expect_value(t, init_err, jsonrpc.Call_Err.None)
	testing.expect(t, ok)

	init_v, perr := json.parse_string(p.fake.init_params, allocator = context.temp_allocator)
	testing.expect(t, perr == nil)
	if root_v, rok := jsonutil.obj_get(init_v, "rootUri"); rok {
		testing.expect(t, jsonutil.value_str(root_v) == "file:///proj/modA")
	} else {
		testing.expectf(t, false, "initialize params lack rootUri")
	}
	if folders_v, fok := jsonutil.obj_get(init_v, "workspaceFolders"); fok {
		#partial switch fa in folders_v {
		case json.Array:
			testing.expect(t, len(fa) == 2)
			if len(fa) == 2 {
				if uri_v, uok := jsonutil.obj_get(fa[0], "uri"); uok {
					testing.expect(t, jsonutil.value_str(uri_v) == "file:///proj/modA")
				}
				if name_v, nok := jsonutil.obj_get(fa[0], "name"); nok {
					testing.expect(t, jsonutil.value_str(name_v) == "modA")
				}
				if uri_v, uok := jsonutil.obj_get(fa[1], "uri"); uok {
					testing.expect(t, jsonutil.value_str(uri_v) == "file:///proj/modB")
				}
			}
		case:
			testing.expectf(t, false, "workspaceFolders is not an array")
		}
	} else {
		testing.expectf(t, false, "initialize params lack workspaceFolders")
	}

	// An empty folder list is refused before anything reaches the wire.
	empty := []lsp.Folder{}
	_, code, _, cerr := lsp.client_initialize(p.client, empty, context.temp_allocator)
	testing.expect_value(t, cerr, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, code, jsonrpc.Err_Code.Invalid_Params)
}

// The declared capability set must match exercised behavior: UTF-16
// positions (the computation convention), no didSave (never sent), no
// dynamic registration (registrations are acked, not modeled), and
// workDoneProgress declared because create requests are answered.
@(test)
lsp_client_caps_wire_shape :: proc(t: ^testing.T) {
	p := lsp_pair_init(t)
	if p == nil {
		testing.expectf(t, false, "pair init failed")
		return
	}
	defer lsp_pair_shutdown(p)

	single := []lsp.Folder{{uri = "file:///w", name = "w"}}
	ok, _, _, init_err := lsp.client_initialize(p.client, single, context.temp_allocator)
	testing.expect_value(t, init_err, jsonrpc.Call_Err.None)
	testing.expect(t, ok)

	init_v, perr := json.parse_string(p.fake.init_params, allocator = context.temp_allocator)
	testing.expect(t, perr == nil)
	caps_v, cok := jsonutil.obj_get(init_v, "capabilities")
	testing.expect(t, cok, "initialize params lack capabilities")

	// UTF-16 only: positions are computed as UTF-16 code units everywhere.
	if gen_v, gok := jsonutil.obj_get(caps_v, "general"); gok {
		if enc_v, eok := jsonutil.obj_get(gen_v, "positionEncodings"); eok {
			#partial switch ea in enc_v {
			case json.Array:
				testing.expect(t, len(ea) == 1)
				if len(ea) == 1 {
					testing.expect(t, jsonutil.value_str(ea[0]) == "utf-16")
				}
			case:
				testing.expectf(t, false, "positionEncodings is not an array")
			}
		} else {
			testing.expectf(t, false, "capabilities lack positionEncodings")
		}
	} else {
		testing.expectf(t, false, "capabilities lack general")
	}

	// No synchronization object at all: didOpen/didChange(full)/didClose
	// are the required core and didSave is never sent.
	if td_v, tok := jsonutil.obj_get(caps_v, "textDocument"); tok {
		_, sync_present := jsonutil.obj_get(td_v, "synchronization")
		testing.expect(t, !sync_present, "synchronization must not be declared: didSave is never sent")
	} else {
		testing.expectf(t, false, "capabilities lack textDocument")
	}

	// didChangeWatchedFiles says dynamicRegistration:false — no watcher
	// exists behind it, so servers must keep their own watching.
	if ws_v, wok := jsonutil.obj_get(caps_v, "workspace"); wok {
		if wv, dok := jsonutil.obj_get(ws_v, "didChangeWatchedFiles"); dok {
			testing.expect_value(t, jsonutil.obj_get_bool(wv, "dynamicRegistration"), false)
		} else {
			testing.expectf(t, false, "capabilities lack didChangeWatchedFiles")
		}
		_, sym := jsonutil.obj_get(ws_v, "symbol")
		testing.expect(t, !sym, "workspace.symbol must not invite registrations")
	} else {
		testing.expectf(t, false, "capabilities lack workspace")
	}

	// workDoneProgress is declared: create requests are answered and
	// $/progress consumed.
	if win_v, wpr := jsonutil.obj_get(caps_v, "window"); wpr {
		testing.expect_value(t, jsonutil.obj_get_bool(win_v, "workDoneProgress"), true)
	} else {
		testing.expectf(t, false, "capabilities lack window")
	}
}

// build_deep_document_symbol_chain returns the root of a nested
// documentSymbol JSON hierarchy MAX_TREE_DEPTH + 500 levels deep (the
// jsonrpc depth guard would cap the wire form at 128, but the converter
// must not depend on that coupling). Shared by the staged depth tests
// below so a platform-specific hard fault names its stage in the log.
build_deep_document_symbol_chain :: proc(a: mem.Allocator) -> json.Value {
	node := jsonutil.json_object(3, a)
	jsonutil.obj_set(&node, "name", jsonutil.json_string("s"))
	pos := jsonutil.json_object(2, a)
	jsonutil.obj_set(&pos, "line", jsonutil.json_int(0))
	jsonutil.obj_set(&pos, "character", jsonutil.json_int(0))
	rng := jsonutil.json_object(2, a)
	jsonutil.obj_set_object(&rng, "start", pos)
	jsonutil.obj_set_object(&rng, "end", pos)
	for _ in 0..<symbol.MAX_TREE_DEPTH + 500 {
		parent := jsonutil.json_object(4, a)
		jsonutil.obj_set(&parent, "name", jsonutil.json_string("s"))
		jsonutil.obj_set_object(&parent, "range", rng)
		kids := jsonutil.json_array({json.Value(json.Object(node))}, a)
		jsonutil.obj_set(&parent, "children", kids)
		node = parent
	}
	return json.Value(json.Object(node))
}

// The inbound documentSymbol conversion is staged: chain construction,
// converter recursion, then the depth cap count. The stages share one
// builder so each exercises the same input; a fault on a given platform
// shows up under its own test name instead of one aggregate.
@(test)
lsp_document_symbols_depth_chain_builds :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	root_v := build_deep_document_symbol_chain(a)
	obj, ok := jsonutil.as_object(root_v)
	testing.expect(t, ok, "chain root must be an object")
	if ok {
		_, has_children := obj["children"]
		testing.expect(t, has_children, "chain root must carry children")
	}
	// The json values die with the arena.
}

@(test)
lsp_document_symbols_depth_converts :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	root := lsp.document_symbol_node(build_deep_document_symbol_chain(a), "", a)
	testing.expect(t, root != nil, "depth-capped conversion must still return a root")
	// The json values and the symbol tree both die with the arena.
}

@(test)
lsp_document_symbols_depth_capped :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	root := lsp.document_symbol_node(build_deep_document_symbol_chain(a), "", a)
	testing.expect(t, root != nil)
	walk := root
	counted := 0
	for walk != nil {
		counted += 1
		if len(walk.children) == 0 {
			break
		}
		walk = walk.children[0]
	}
	testing.expect_value(t, counted, symbol.MAX_TREE_DEPTH + 1)
	// The json values and the symbol tree both die with the arena.
}

// A flat SymbolInformation element must not gain children from a stray
// "children" key: the member exists only on the hierarchical
// DocumentSymbol form, so the key is out-of-shape and ignored like any
// other unknown field.
@(test)
lsp_document_symbols_flat_children_ignored :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	pos := jsonutil.json_object(2, a)
	jsonutil.obj_set(&pos, "line", jsonutil.json_int(0))
	jsonutil.obj_set(&pos, "character", jsonutil.json_int(0))
	rng := jsonutil.json_object(2, a)
	jsonutil.obj_set_object(&rng, "start", pos)
	jsonutil.obj_set_object(&rng, "end", pos)

	stray := jsonutil.json_object(3, a)
	jsonutil.obj_set(&stray, "name", jsonutil.json_string("stray"))
	stray_loc := jsonutil.json_object(2, a)
	jsonutil.obj_set(&stray_loc, "uri", jsonutil.json_string("file:///stray.odin"))
	jsonutil.obj_set_object(&stray_loc, "range", rng)
	jsonutil.obj_set_object(&stray, "location", stray_loc)

	flat := jsonutil.json_object(4, a)
	jsonutil.obj_set(&flat, "name", jsonutil.json_string("flat"))
	flat_loc := jsonutil.json_object(2, a)
	jsonutil.obj_set(&flat_loc, "uri", jsonutil.json_string("file:///flat.odin"))
	jsonutil.obj_set_object(&flat_loc, "range", rng)
	jsonutil.obj_set_object(&flat, "location", flat_loc)
	kids := jsonutil.json_array({json.Value(json.Object(stray))}, a)
	jsonutil.obj_set(&flat, "children", kids)

	root := lsp.document_symbol_node(json.Value(json.Object(flat)), "", a)
	testing.expect(t, root != nil, "flat element must convert")
	testing.expect(t, len(root.children) == 0,
		"flat SymbolInformation has no children member; a stray children key must be ignored")
	// The json values and the symbol tree both die with the arena.
}

// A readiness signal arriving while one waiter is inside the unlocked
// fallback settle wait must upgrade its latched outcome: the
// old path forced .Fallback on re-lock and clobbered whatever the
// re-evaluation should have seen. The waiter parks in the fallback on the
// virtual clock, diagnostics land mid-sleep, and the outcome must come
// back Diagnostics, with the once-latch serving it afterwards.
@(test)
lsp_crossref_wait_diag_during_fallback_upgrades_outcome :: proc(t: ^testing.T) {
	p := lsp_pair_init(t, virtual_clock = true)
	if p == nil {
		testing.expectf(t, false, "pair init failed")
		return
	}
	defer lsp_pair_shutdown(p)

	p.client.crossref_event_timeout_ms = 5000
	p.client.crossref_fallback_ms = 1000

	Wait_Job :: struct {
		client:  ^lsp.Client,
		outcome: lsp.Wait_Outcome,
		mu:      sync.Mutex,
		cond:    sync.Cond,
		done:    bool,
	}
	w := new(Wait_Job, context.allocator)
	defer free(w, context.allocator)
	w^ = {client = p.client}

	wait_worker :: proc(data: rawptr) {
		wj := cast(^Wait_Job)data
		outcome := lsp.client_wait_cross_file_refs(wj.client)
		sync.mutex_lock(&wj.mu)
		wj.outcome = outcome
		wj.done = true
		sync.cond_broadcast(&wj.cond)
		sync.mutex_unlock(&wj.mu)
	}
	thr := thread.create_and_start_with_data(w, wait_worker, self_cleanup = false)

	// Pass the event window, then give the waiter a few real cond slices
	// (25 ms each) to park inside the fallback settle wait before the
	// signal lands — that unlocked sleep is exactly the window the fix
	// re-evaluates on wake.
	platform.clock_advance(p.clock, 6000)
	time.sleep(150 * time.Millisecond)

	diag_params := jsonutil.json_object(2, context.temp_allocator)
	jsonutil.obj_set(&diag_params, "uri", jsonutil.json_string("file:///a.go"))
	jsonutil.obj_set(&diag_params, "diagnostics", jsonutil.json_array(nil, context.temp_allocator))
	_ = jsonrpc.conn_notify(
		p.fake.conn, lsp.METHOD_PUBLISH_DIAGNOSTICS,
		json.Value(json.Object(diag_params)), context.temp_allocator,
	)

	deadline := platform.mono_ms() + 5000
	sync.mutex_lock(&w.mu)
	for !w.done && platform.mono_ms() < deadline {
		sync.mutex_unlock(&w.mu)
		platform.clock_advance(p.clock, 300)
		sync.mutex_lock(&w.mu)
		if w.done {
			break
		}
		sync.cond_wait_with_timeout(&w.cond, &w.mu, 20 * 1_000_000)
	}
	done := w.done
	outcome := w.outcome
	sync.mutex_unlock(&w.mu)
	thread.join(thr)
	free(thr, context.allocator)

	testing.expect(t, done)
	testing.expect_value(t, outcome, lsp.Wait_Outcome.Diagnostics)
	// The once-latch serves the upgraded outcome, never the degraded one.
	testing.expect_value(
		t, lsp.client_wait_cross_file_refs(p.client), lsp.Wait_Outcome.Diagnostics,
	)
}
