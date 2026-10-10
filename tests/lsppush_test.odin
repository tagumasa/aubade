// lsppush tests: the daemon→lsp-child push family. The manager-level
// test records the running-state hook through the shared fake-factory
// harness (langserver_test.odin); the daemon-level tests run the full
// relay over the channel transport (svc_test.odin's daemon pair) — a
// hello carrying mode=="lsp" subscribes the child, the fake LS's
// publishDiagnostics and the manager's start/stop transitions arrive as
// svc.push/* notifications on the child conn. Arrivals are observed
// through bounded count polls (2 ms slices, hard deadline — the suite's
// no-unbounded-waits rule); the mode gate's absence half is a bounded
// quiet window.
package tests

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "src:daemon"
import "jsonrpc:jsonrpc"
import "jsonutil:jsonutil"
import "src:langserver"
import "src:lsp"
import "src:platform"
import "src:svc"

// --- the child-side sink ----------------------------------------------------

Push_Diag :: struct {
	uri:   string, // cloned onto context.allocator
	items: string,
}

Push_State :: struct {
	language:   string,
	running:    bool,
	references: bool,
}

// Push_Sink records the svc.push/* notifications one child conn receives.
// The notifiers run on the pair's reader thread, whose context.allocator is
// NOT the test thread's — every clone goes through the sink's own
// allocator so the destroy frees through the same owner that allocated.
Push_Sink :: struct {
	allocator: mem.Allocator,
	mu:        sync.Mutex,
	diags:     [dynamic]Push_Diag,
	states:    [dynamic]Push_State,
}

push_sink_init :: proc(s: ^Push_Sink) {
	s^ = {allocator = context.allocator}
	s.diags = make([dynamic]Push_Diag, 0, 4, s.allocator)
	s.states = make([dynamic]Push_State, 0, 4, s.allocator)
}

push_sink_destroy :: proc(s: ^Push_Sink) {
	if s.diags != nil {
		for d in s.diags {
			delete(d.uri, s.allocator)
			delete(d.items, s.allocator)
		}
		delete(s.diags)
	}
	if s.states != nil {
		for st in s.states {
			delete(st.language, s.allocator)
		}
		delete(s.states)
	}
}

lsppush_sink_diagnostics :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) {
	_ = arena
	sink := cast(^Push_Sink)conn.host
	if sink == nil {
		return
	}
	uri_v, uok := jsonutil.obj_get(env.params, "uri")
	items_v, iok := jsonutil.obj_get(env.params, "items")
	if !uok || !iok {
		return
	}
	sync.mutex_lock(&sink.mu)
	append(&sink.diags, Push_Diag{
		uri   = strings.clone(jsonutil.value_str(uri_v), sink.allocator),
		items = strings.clone(jsonutil.value_str(items_v), sink.allocator),
	})
	sync.mutex_unlock(&sink.mu)
}

lsppush_sink_state :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) {
	_ = arena
	sink := cast(^Push_Sink)conn.host
	if sink == nil {
		return
	}
	lang_v, lok := jsonutil.obj_get(env.params, "language")
	if !lok {
		return
	}
	sync.mutex_lock(&sink.mu)
	append(&sink.states, Push_State{
		language   = strings.clone(jsonutil.value_str(lang_v), sink.allocator),
		running    = jsonutil.obj_get_bool(env.params, "running"),
		references = jsonutil.obj_get_bool(env.params, "references"),
	})
	sync.mutex_unlock(&sink.mu)
}

// lsppush_wait_diags polls until the sink holds n diagnostics records or
// the deadline passes (2 ms slices — the bounded-arrival idiom).
lsppush_wait_diags :: proc(s: ^Push_Sink, n: int, timeout_ms: i64) -> bool {
	deadline := platform.mono_ms() + timeout_ms
	for {
		sync.mutex_lock(&s.mu)
		got := len(s.diags)
		sync.mutex_unlock(&s.mu)
		if got >= n {
			return true
		}
		if platform.mono_ms() >= deadline {
			return false
		}
		time.sleep(2 * time.Millisecond)
	}
}

lsppush_wait_states :: proc(s: ^Push_Sink, n: int, timeout_ms: i64) -> bool {
	deadline := platform.mono_ms() + timeout_ms
	for {
		sync.mutex_lock(&s.mu)
		got := len(s.states)
		sync.mutex_unlock(&s.mu)
		if got >= n {
			return true
		}
		if platform.mono_ms() >= deadline {
			return false
		}
		time.sleep(2 * time.Millisecond)
	}
}

// lsppush_quiet waits out a fixed window and reports whether the sink
// stayed empty — a push's absence can only be observed as a bounded quiet
// period (the wait_* helpers above are the positive direction).
lsppush_quiet :: proc(s: ^Push_Sink, window_ms: i64) -> bool {
	deadline := platform.mono_ms() + window_ms
	for {
		sync.mutex_lock(&s.mu)
		got := len(s.diags) + len(s.states)
		sync.mutex_unlock(&s.mu)
		if got != 0 {
			return false
		}
		if platform.mono_ms() >= deadline {
			return true
		}
		time.sleep(2 * time.Millisecond)
	}
}

// --- the manager-level hook test ----------------------------------------------

// LS_State_Recorder records Manager_State_Proc firings. The hook runs on
// the manager-transitioning thread, whose context.allocator is NOT the
// test thread's — the language clone and the events growth go through the
// recorder's own allocator, the same owner lsppush_record_destroy frees
// through (the callback contract grants synchronous read only).
LS_State_Recorder :: struct {
	allocator: mem.Allocator,
	mu:        sync.Mutex,
	events:    [dynamic]Push_State,
}

lsppush_record_state :: proc(user: rawptr, language: string, running, references: bool) {
	r := cast(^LS_State_Recorder)user
	sync.mutex_lock(&r.mu)
	append(&r.events, Push_State{
		language   = strings.clone(language, r.allocator),
		running    = running,
		references = references,
	})
	sync.mutex_unlock(&r.mu)
}

lsppush_record_destroy :: proc(r: ^LS_State_Recorder) {
	if r.events != nil {
		for e in r.events {
			delete(e.language, r.allocator)
		}
		delete(r.events)
	}
}

// The hook fires once per running transition the manager owns: start
// success (running=true), the retire unlink paths (running=false), and
// restart's down-then-up pair. A start that finds a live server fires
// nothing.
@(test)
lsppush_manager_state_hook :: proc(t: ^testing.T) {
	// The recorder outlives the manager: ls_test_destroy's teardown fires
	// the hook's final running=false events (the reset victims), so the
	// recorder's defer registers FIRST and runs LAST — every event,
	// teardown ones included, is freed by lsppush_record_destroy.
	rec := LS_State_Recorder{}
	rec.allocator = context.allocator
	rec.events = make([dynamic]Push_State, 0, 8, rec.allocator)
	defer lsppush_record_destroy(&rec)

	lt := ls_test_init(t, false, {"tst"}, false)
	defer ls_test_destroy(lt)

	lt.m.on_state = lsppush_record_state
	lt.m.on_state_host = &rec

	testing.expect(t, langserver.manager_start(lt.m, "tst", context.temp_allocator) == nil)
	sync.mutex_lock(&rec.mu)
	n := len(rec.events)
	start_ok := n == 1 && rec.events[0].language == "tst" && rec.events[0].running &&
		!rec.events[0].references
	sync.mutex_unlock(&rec.mu)
	testing.expectf(t, start_ok, "start must fire exactly one running=true event, got %d", n)
	if !start_ok {
		return
	}

	testing.expect(t, langserver.manager_stop(lt.m, "tst") == nil)
	sync.mutex_lock(&rec.mu)
	n = len(rec.events)
	stop_ok := n == 2 && rec.events[1].language == "tst" && !rec.events[1].running &&
		!rec.events[1].references
	sync.mutex_unlock(&rec.mu)
	testing.expectf(t, stop_ok, "stop must fire exactly one running=false event, got %d", n)
	if !stop_ok {
		return
	}

	// A restart with no old server fires only the replacement's up event.
	testing.expect(t, langserver.manager_restart(lt.m, "tst", context.temp_allocator) == nil)
	// A start over the live replacement fires nothing (ensure finds it
	// alive; no transition, no event).
	testing.expect(t, langserver.manager_start(lt.m, "tst", context.temp_allocator) == nil)
	// A restart over a live server fires the old server's down, then the
	// replacement's up.
	testing.expect(t, langserver.manager_restart(lt.m, "tst", context.temp_allocator) == nil)

	sync.mutex_lock(&rec.mu)
	n = len(rec.events)
	seq_ok := n == 5 &&
		rec.events[2].running && !rec.events[2].references &&
		!rec.events[3].running && !rec.events[3].references &&
		rec.events[4].running && !rec.events[4].references
	sync.mutex_unlock(&rec.mu)
	testing.expectf(t, seq_ok, "restart+start+restart must fire up, down, up exactly, got %d", n)
}

// --- the daemon-level relay ---------------------------------------------------

// LSPPush_Factory wraps the shared fake LS factory for daemon-level
// tests: the fabricated client carries the references cap (so the pushed
// bit is distinguishable from its default) and the daemon's diagnostics
// push port — the two wires the relay below observes. The
// caps write follows fake_ls_create's own discipline: it lands before
// the manager shares the server.
LSPPush_Factory :: struct {
	ff:               ^Fake_Factory,
	push_diagnostics: lsp.Diagnostics_Push_Proc,
	push_host:        rawptr,
}

lsppush_fake_create :: proc(
	user:            rawptr,
	entry:           ^langserver.Entry,
	argv:            []string,
	env:             []string,
	folders:         []langserver.Workspace_Folder,
	memory_limit_mb: int,
	clock:           ^platform.Clock,
	a:               mem.Allocator,
	token:           ^platform.Cancel_Token,
) -> (s: ^langserver.Server, err: platform.Err) {
	f := cast(^LSPPush_Factory)user
	s, err = fake_ls_create(f.ff, entry, argv, env, folders, memory_limit_mb, clock, a, token)
	if err == nil && s != nil && s.client != nil {
		s.client.caps.references = true
		s.client.push_diagnostics = f.push_diagnostics
		s.client.push_host = f.push_host
	}
	return
}

// lsppush_fake_peers_cleanup frees the fake pipes after the daemon (and
// with it the manager and its clients) is down. Nil-tolerant: a test that
// returns before building the factory still runs its defers. The fake's
// recorded argv/folders ride its allocator — the same two frees the
// langserver harness's own teardown performs.
lsppush_fake_peers_cleanup :: proc(ff: ^Fake_Factory) {
	if ff == nil {
		return
	}
	for peer in ff.peers {
		fake_peer_cleanup(peer)
	}
	delete(ff.peers)
	langserver.free_strings(ff.last_argv, ff.allocator)
	langserver.free_strings(ff.last_folders, ff.allocator)
	free(ff, context.allocator)
}

// The full relay: hello mode=="lsp" subscribes the child, the start
// answer carries the started server's caps, the manager's transitions
// arrive as svc.push/langserver_state, and a publishDiagnostics into the
// running fake server's client lands as svc.push/diagnostics carrying
// the stored items string.
@(test)
lsppush_daemon_relay_to_lsp_child :: proc(t: ^testing.T) {
	sink := Push_Sink{}
	push_sink_init(&sink)
	// Registered before anything can return early: the sink's arrays are
	// live from init on, and the destroy must run after the reader that
	// dispatches into it is joined (LIFO puts it last of the three defers).
	defer push_sink_destroy(&sink)
	ff: ^Fake_Factory = nil

	// crystal's argv override pins an existing binary: the manager's
	// override path skips the entry's runtime probe (the fake answers the
	// handshake without a process, so the command itself never runs).
	config_jsonc := strings.concatenate(
		{`{"language_server_commands": {"crystal": ["`, SH_NAME, `"]}}`},
		context.temp_allocator,
	)
	pair := test_daemon_with_project(t, false, config_jsonc)
	if pair == nil {
		return
	}

	// Swap the daemon manager's production factory for the fake before
	// any start. Nothing else starts servers in this window: the warm-up
	// crawl and the idle reaper never spawn one, and no request has
	// arrived yet.
	ma: mem.Mutex_Allocator
	mem.mutex_allocator_init(&ma, context.allocator)
	ff = new(Fake_Factory, context.allocator)
	ff^ = {allocator = mem.mutex_allocator(&ma)}
	ff.peers = make([dynamic]^Fake_Peer, 0, 4, ff.allocator)
	pf := LSPPush_Factory{
		ff               = ff,
		push_diagnostics = daemon.push_diagnostics_to_lsp_children,
		push_host        = pair.daemon,
	}
	pair.daemon.ls.factory = langserver.Factory{user = &pf, create = lsppush_fake_create}

	// LIFO: peers go after the pair (the manager frees the clients that
	// reference the fake pipes). Registered after ff reached its final
	// value; the sink's defer already sits at its init site above.
	defer lsppush_fake_peers_cleanup(ff)
	defer pair_shutdown(pair)

	jsonrpc.conn_register_notification(pair.conn, svc.METHOD_PUSH_DIAGNOSTICS, lsppush_sink_diagnostics)
	jsonrpc.conn_register_notification(pair.conn, svc.METHOD_PUSH_LANGSERVER_STATE, lsppush_sink_state)
	pair.conn.host = &sink

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	// The subscribing hello.
	hello := jsonutil.json_object(2, alloc)
	jsonutil.obj_set(&hello, "client_pid", jsonutil.json_int(i64(os.get_pid())))
	jsonutil.obj_set(&hello, "mode", jsonutil.json_string("lsp"))
	_, _, _, hcerr := jsonrpc.conn_call(
		pair.conn, svc.METHOD_HELLO, json.Value(json.Object(hello)), alloc, deadline,
	)
	testing.expect_value(t, hcerr, jsonrpc.Call_Err.None)

	// The child-triggered start answers the started server's caps
	// synchronously (manager_start returns after the handshake).
	res := svc.client_langserver_start(pair.conn, "crystal", alloc, deadline)
	testing.expect_value(t, res.call_err, jsonrpc.Call_Err.None)
	if res.call_err != .None {
		return
	}
	refs, rok := json_bool_field(res.result, "references")
	testing.expectf(t, rok && refs, "start answer cap: rok=%v refs=%v", rok, refs)

	// The start's running transition reached the lsp child, with the fake
	// server's capability bits (the response's arrival orders it after
	// the push: same conn, same outbound queue).
	if !lsppush_wait_states(&sink, 1, 2000) {
		testing.expectf(t, false, "no svc.push/langserver_state after start")
		return
	}
	sync.mutex_lock(&sink.mu)
	up := sink.states[0]
	up_ok := up.language == "crystal" && up.running && up.references
	sync.mutex_unlock(&sink.mu)
	testing.expectf(t, up_ok, "start push must carry crystal running=true with caps")

	// The running fake server's client, fetched through the manager
	// snapshot (pins released after the pointer is kept: the server stays
	// in the table until the stop below, and only this thread touches the
	// manager in between).
	client: ^lsp.Client = nil
	running := langserver.manager_running_clients(pair.daemon.ls, context.temp_allocator)
	for rc in running {
		if rc.language_id == "crystal" {
			client = rc.client
		}
		langserver.manager_release(pair.daemon.ls, rc.client)
	}
	delete(running)
	testing.expectf(t, client != nil, "crystal client missing after start")
	if client == nil {
		return
	}

	// A publishDiagnostics into the fake server's client: the store
	// takes the set, the push port relays it, and the child receives the
	// stored items string. (Dispatched directly — the fake has no reader
	// thread; this is exactly the dispatch the reader would run.)
	diag_body := strings.concatenate(
		{
			`{"jsonrpc":"2.0","method":"`,
			lsp.METHOD_PUBLISH_DIAGNOSTICS,
			`","params":{"uri":"file:///proj/aubade-push.go","version":1,"diagnostics":[{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":2}},"severity":1,"message":"aubade push boom"}]}}`,
		},
		context.temp_allocator,
	)
	env, derr := jsonrpc.decode_envelope(transmute([]u8)diag_body, context.temp_allocator)
	testing.expectf(t, env != nil && derr == .None, "publish envelope did not decode")
	if env == nil || derr != .None {
		return
	}
	jsonrpc.conn_dispatch(client.conn, env, context.temp_allocator)

	if !lsppush_wait_diags(&sink, 1, 2000) {
		testing.expectf(t, false, "no svc.push/diagnostics after publish")
		return
	}
	sync.mutex_lock(&sink.mu)
	d := sink.diags[0]
	diag_ok := d.uri == "file:///proj/aubade-push.go"
	items := strings.clone(d.items, context.temp_allocator)
	sync.mutex_unlock(&sink.mu)
	testing.expectf(t, diag_ok, "diagnostics push uri mismatch")
	if !diag_ok {
		return
	}
	items_v, perr := json.parse_string(items, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	testing.expectf(t, perr == nil, "pushed items did not parse: %s", items)
	if perr == nil {
		arr, is_arr := jsonutil.as_array(items_v)
		testing.expectf(t, is_arr && len(arr) == 1, "pushed items must be the one stored diagnostic")
		if is_arr && len(arr) == 1 {
			msg, mok := json_str_field(arr[0], "message")
			testing.expectf(t, mok && msg == "aubade push boom", "pushed diagnostic message mismatch: %s", msg)
		}
	}

	// The stop's transition arrives as running=false with cleared bits.
	stop := svc.client_langserver_stop(pair.conn, "crystal", alloc, deadline)
	testing.expect_value(t, stop.call_err, jsonrpc.Call_Err.None)
	if !lsppush_wait_states(&sink, 2, 2000) {
		testing.expectf(t, false, "no svc.push/langserver_state after stop")
		return
	}
	sync.mutex_lock(&sink.mu)
	down := sink.states[1]
	down_ok := down.language == "crystal" && !down.running && !down.references
	sync.mutex_unlock(&sink.mu)
	testing.expectf(t, down_ok, "stop push must carry crystal running=false with cleared bits")
}

// The gate's negative half: a child whose hello carried no mode receives
// neither push family member, even when the daemon relays one.
@(test)
lsppush_child_without_mode_receives_nothing :: proc(t: ^testing.T) {
	sink := Push_Sink{}
	push_sink_init(&sink)
	defer push_sink_destroy(&sink)
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	jsonrpc.conn_register_notification(pair.conn, svc.METHOD_PUSH_DIAGNOSTICS, lsppush_sink_diagnostics)
	jsonrpc.conn_register_notification(pair.conn, svc.METHOD_PUSH_LANGSERVER_STATE, lsppush_sink_state)
	pair.conn.host = &sink

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	// Hello without mode: no push subscription.
	hello := jsonutil.json_object(1, alloc)
	jsonutil.obj_set(&hello, "client_pid", jsonutil.json_int(i64(os.get_pid())))
	_, _, _, hcerr := jsonrpc.conn_call(
		pair.conn, svc.METHOD_HELLO, json.Value(json.Object(hello)), alloc, deadline,
	)
	testing.expect_value(t, hcerr, jsonrpc.Call_Err.None)

	daemon.push_diagnostics_to_lsp_children(pair.daemon, "file:///proj/x.go", `[{"message":"unsubscribed"}]`)
	daemon.push_langserver_state_to_lsp_children(pair.daemon, "crystal", true, true)

	testing.expectf(
		t,
		lsppush_quiet(&sink, 300),
		"a child without hello mode must not receive pushes",
	)
}

// The teardown gate: once the daemon's push face is quiesced (the flag
// daemon_cleanup sets in the same critical section that takes its children
// snapshot), a subscribed child receives nothing — the face snapshots and
// pins no one, so the children pass can drain and free without racing an
// in-flight push.
@(test)
lsppush_quiesced_daemon_pushes_nothing :: proc(t: ^testing.T) {
	sink := Push_Sink{}
	push_sink_init(&sink)
	defer push_sink_destroy(&sink)
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	jsonrpc.conn_register_notification(pair.conn, svc.METHOD_PUSH_DIAGNOSTICS, lsppush_sink_diagnostics)
	jsonrpc.conn_register_notification(pair.conn, svc.METHOD_PUSH_LANGSERVER_STATE, lsppush_sink_state)
	pair.conn.host = &sink

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	// A subscribed (mode=="lsp") child: without the flag both pushes land.
	hello := jsonutil.json_object(2, alloc)
	jsonutil.obj_set(&hello, "client_pid", jsonutil.json_int(i64(os.get_pid())))
	jsonutil.obj_set(&hello, "mode", jsonutil.json_string("lsp"))
	_, _, _, hcerr := jsonrpc.conn_call(
		pair.conn, svc.METHOD_HELLO, json.Value(json.Object(hello)), alloc, deadline,
	)
	testing.expect_value(t, hcerr, jsonrpc.Call_Err.None)

	// Quiesce the push face the way teardown does — under children_mu, the
	// flag's guard — then push: the subscribed child must stay silent.
	sync.mutex_lock(&pair.daemon.children_mu)
	pair.daemon.is_push_quiesced = true
	sync.mutex_unlock(&pair.daemon.children_mu)
	daemon.push_diagnostics_to_lsp_children(pair.daemon, "file:///proj/x.go", `[{"message":"quiesced"}]`)
	daemon.push_langserver_state_to_lsp_children(pair.daemon, "crystal", true, true)

	testing.expectf(
		t,
		lsppush_quiet(&sink, 300),
		"a quiesced push face must deliver nothing",
	)
}
