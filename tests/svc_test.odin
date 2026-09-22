// svc boundary component tests over the channel transport: a real
// in-process Daemon serves a channel endpoint; the child side drives
// hello -> echo -> bye, and svc.cancel fires the parent-side request token
// (observed through a slow test handler that answers -32800).
package tests

import "base:intrinsics"
import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "src:daemon"
import "src:jsonrpc"
import "src:jsonutil"
import "src:platform"
import "src:rpc"
import "src:store"
import "src:svc"

// one_shot_event_wait_bounded bounds an arrival wait: an event that never
// signals must fail the test, not hang the runner forever (the suite's
// no-unbounded-waits rule — every failure path terminates).
one_shot_event_wait_bounded :: proc(e: ^sync.One_Shot_Event, timeout_ms: i64) -> bool {
	deadline := platform.mono_ms() + timeout_ms
	for intrinsics.atomic_load_explicit(&e.state, .Acquire) == 0 {
		if platform.mono_ms() >= deadline {
			return false
		}
		time.sleep(2 * time.Millisecond)
	}
	return true
}

Conn_Box :: struct {
	conn: ^jsonrpc.Conn,
}

conn_reader_entry :: proc(data: rawptr) {
	b := cast(^Conn_Box)data
	jsonrpc.conn_read_loop(b.conn)
}

// The chan transport must retain the unread remainder of a chunk larger
// than the reader's window instead of dropping it — the framing layer is
// free to read with any window size, and a dropped tail would corrupt
// every message bigger than the window.
@(test)
rpc_chan_stream_read_keeps_remainder :: proc(t: ^testing.T) {
	ea, eb := rpc.channel_pair(context.allocator)
	if ea == nil || eb == nil {
		testing.expect(t, false, "channel_pair failed")
		if ea != nil {
			rpc.channel_endpoint_destroy(ea)
		}
		if eb != nil {
			rpc.channel_endpoint_destroy(eb)
		}
		return
	}
	defer {
		rpc.channel_endpoint_destroy(eb)
		rpc.channel_endpoint_destroy(ea)
	}

	payload_len := 4096
	sent := make([]u8, payload_len)
	defer delete(sent)
	for i in 0..<payload_len {
		sent[i] = u8(i % 251)
	}
	n, werr := ea.stream.write(&ea.stream, sent)
	testing.expect(t, werr == .None && n == payload_len, "write must deliver the whole chunk")

	got := make([]u8, payload_len)
	defer delete(got)
	filled := 0
	buf: [7]u8 // a window far smaller than the chunk
	for filled < payload_len {
		rn, rerr := eb.stream.read(&eb.stream, buf[:])
		if rerr != .None || rn <= 0 {
			testing.expectf(t, false, "read stalled at %d of %d", filled, payload_len)
			return
		}
		if filled + rn > payload_len {
			testing.expect(t, false, "read overran the payload")
			return
		}
		for i := 0; i < rn; i += 1 {
			got[filled + i] = buf[i]
		}
		filled += rn
	}
	testing.expect(t, string(got) == string(sent), "payload must survive small-window reads")

	ea.stream.close(&ea.stream)
	eb.stream.close(&eb.stream)
}

Daemon_Pair :: struct {
	daemon:          ^daemon.Daemon,
	daemon_endpoint: ^rpc.Chan_Endpoint,
	endpoint:        ^rpc.Chan_Endpoint,
	conn:            ^jsonrpc.Conn,
	box:             ^Conn_Box,
	reader:          ^thread.Thread,
	run_thread:      ^thread.Thread,
	clock:           ^platform.Clock,
	tmp:             string,
	home:            string, // separate from the project dir: the shadow repo and daemon state must not live inside the workspace
}

test_daemon :: proc(t: ^testing.T, extra_slow: bool) -> ^Daemon_Pair {
	return test_daemon_with_configs(t, extra_slow, "", "")
}

// test_daemon_with_project seeds <root>/.aubade/project.jsonc with
// `config_jsonc` before the daemon initializes (empty string = none), so
// init-time config consumption (e.g. language_server_commands) is covered.
test_daemon_with_project :: proc(
	t: ^testing.T,
	extra_slow: bool,
	config_jsonc: string,
) -> ^Daemon_Pair {
	return test_daemon_with_configs(t, extra_slow, config_jsonc, "")
}

// test_daemon_with_configs seeds both the project config and the global
// config.jsonc under the daemon home before initialization.
test_daemon_with_configs :: proc(
	t: ^testing.T,
	extra_slow: bool,
	config_jsonc: string,
	global_jsonc: string,
) -> ^Daemon_Pair {
	tmp, terr := os.make_directory_temp("", "aubade-svc-", context.allocator)
	if terr != nil {
		testing.expectf(t, false, "temp dir failed: %v", terr)
		return nil
	}
	// The daemon home is its own temp tree: the shadow snapshot repository
	// must sit outside the tracked workspace, exactly like production
	// ($AUBADE_HOME vs the project root).
	home, herr := os.make_directory_temp("", "aubade-home-", context.allocator)
	if herr != nil {
		_ = os.remove_all(tmp)
		delete(tmp, context.allocator)
		testing.expectf(t, false, "home temp dir failed: %v", herr)
		return nil
	}
	if config_jsonc != "" {
		write_config_file(
			t,
			platform.project_config_path(
				strings.concatenate({tmp, "/.aubade"}, context.temp_allocator),
				context.temp_allocator,
			),
			config_jsonc,
		)
	}
	if global_jsonc != "" {
		global_path := strings.concatenate({home, "/config.jsonc"}, context.temp_allocator)
		os.remove(global_path)
		write_config_file(t, global_path, global_jsonc)
	}

	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, false)

	d := new(daemon.Daemon, context.allocator)
	cfg := daemon.default_config(tmp, home, clock)
	cfg.hb_ping_ms = 10_000 // heartbeat monitor stays quiet during the test
	cfg.grace_ms = 60_000
	if !daemon.daemon_init(d, cfg, context.allocator) {
		free(d, context.allocator)
		free(clock, context.allocator)
		_ = os.remove_all(tmp)
		delete(tmp, context.allocator)
		_ = os.remove_all(home)
		delete(home, context.allocator)
		testing.expect(t, false, "daemon_init failed")
		return nil
	}
	d.is_in_process = true
	daemon.svc_table_init(&d.svc_table, d)
	if extra_slow {
		svc.table_register(&d.svc_table, "svc.test/slow", slow_wait_cancel)
	}
	svc.table_register(&d.svc_table, "svc.test/slow2", slow2_wait_cancel)

	// The remaining failure paths release everything they created: fail_now
	// skips defers, so live daemon state (store, tracker) or a live run
	// thread left behind would corrupt the tracking allocator for every
	// later test.
	e_child, e_daemon := rpc.channel_pair(context.allocator)
	if e_child == nil {
		platform.token_fire(d.root, .Shutdown)
		daemon.daemon_cleanup(d)
		platform.token_destroy(d.root, context.allocator)
		free(d, context.allocator)
		free(clock, context.allocator)
		_ = os.remove_all(tmp)
		delete(tmp, context.allocator)
		_ = os.remove_all(home)
		delete(home, context.allocator)
		testing.expect(t, false, "channel_pair failed")
		return nil
	}
	run_thread := thread.create_and_start_with_data(d, daemon_run_entry, self_cleanup = false)
	if daemon.daemon_in_process_accept(d, e_daemon) == nil {
		// The run thread owns the daemon's cleanup from here (its exit
		// path runs daemon_cleanup): wake it, join it, release the rest.
		platform.token_fire(d.root, .Shutdown)
		thread.join(run_thread)
		free(run_thread, context.allocator)
		rpc.channel_endpoint_destroy(e_daemon)
		rpc.channel_endpoint_destroy(e_child)
		free(clock, context.allocator)
		_ = os.remove_all(tmp)
		delete(tmp, context.allocator)
		_ = os.remove_all(home)
		delete(home, context.allocator)
		testing.expect(t, false, "in-process accept failed")
		return nil
	}

	c := new(jsonrpc.Conn, context.allocator)
	r := rpc.to_reader(&e_child.stream, jsonrpc.RPC_MAX_FRAME)
	w := rpc.to_writer(&e_child.stream)
	jsonrpc.conn_init(c, r, w, context.allocator)

	box := new(Conn_Box, context.allocator)
	box^ = {conn = c}
	reader := thread.create_and_start_with_data(box, conn_reader_entry, self_cleanup = false)

	pair := new(Daemon_Pair, context.allocator)
	pair^ = {
		daemon          = d,
		daemon_endpoint = e_daemon,
		endpoint        = e_child,
		conn            = c,
		box             = box,
		reader          = reader,
		run_thread      = run_thread,
		clock           = clock,
		tmp             = tmp,
		home            = home,
	}
	return pair
}

daemon_run_entry :: proc(data: rawptr) {
	d := cast(^daemon.Daemon)data
	daemon.daemon_run(d)
}

// pair_shutdown tears the whole in-process pair down: the child conn and
// stream first (waking the reader thread), then the daemon (its run thread
// exits through the root token and runs its own cleanup), then the
// transports and every allocation test_daemon made. Frees `p` itself.
pair_shutdown :: proc(p: ^Daemon_Pair) {
	jsonrpc.conn_close(p.conn)
	p.endpoint.stream.close(&p.endpoint.stream)
	if p.reader != nil {
		thread.join(p.reader)
		free(p.reader, context.allocator)
	}
	free(p.box, context.allocator)

	platform.token_fire(p.daemon.root, .Shutdown)
	if p.run_thread != nil {
		thread.join(p.run_thread)
		free(p.run_thread, context.allocator)
	}
	// daemon_run (joined above) already destroyed the root token after
	// its cleanup, along with the rest of the daemon state.
	free(p.daemon, context.allocator)

	// Both streams are closed now; each endpoint destroys its receiving chan.
	rpc.channel_endpoint_destroy(p.daemon_endpoint)
	rpc.channel_endpoint_destroy(p.endpoint)
	jsonrpc.conn_destroy(p.conn)
	free(p.conn, context.allocator)
	free(p.clock, context.allocator)
	_ = os.remove_all(p.tmp)
	delete(p.tmp)
	_ = os.remove_all(p.home)
	delete(p.home)
	free(p)
}

// wait_index_warm blocks until the pair's daemon finished its one-shot
// startup index warm-up (bounded by timeout_ms; false on timeout). Crawl-stat
// assertions must run after this: daemon_run spawns the warm-up thread for
// every pair, and when its crawl commits a fixture's fingerprint first, the
// test's own crawl reports the file unchanged ("0 files") — whoever indexes
// second sees a fully warm index. The unlocked store.kv_get is sound as a
// completion probe: the marker is stamped only after ts_source_crawl
// returned, so observing it — committed or mid-commit — implies the crawl's
// row transactions already ran, and a read that misses it simply retries.
wait_index_warm :: proc(pair: ^Daemon_Pair, timeout_ms: i64) -> bool {
	deadline := platform.mono_ms() + timeout_ms
	for {
		value, found, err := store.kv_get(pair.daemon.db, daemon.INDEX_WARM_KEY, context.temp_allocator)
		if err == nil && found {
			delete(value, context.temp_allocator)
			return true
		}
		if platform.mono_ms() >= deadline {
			return false
		}
		time.sleep(2 * time.Millisecond)
	}
}

@(test)
svc_hello_echo_bye :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 2000

	params := jsonutil.json_object(1, alloc)
	jsonutil.obj_set(&params, "client_pid", jsonutil.json_int(12345))
	result, _, _, cerr := jsonrpc.conn_call(pair.conn, svc.METHOD_HELLO, obj_value(params), alloc, deadline)
	testing.expect_value(t, cerr, jsonrpc.Call_Err.None)
	daemon_pid := i64(0)
	if v, ok := jsonutil.obj_get(result, "daemon_pid"); ok {
		#partial switch x in v {
		case json.Integer:
			daemon_pid = i64(x)
		case:
		}
	}
	testing.expect(t, daemon_pid > 0, "hello must answer with the daemon pid")

	echo_params := jsonutil.json_object(1, alloc)
	jsonutil.obj_set(&echo_params, "message", jsonutil.json_string("round trip"))
	result, _, _, cerr = jsonrpc.conn_call(pair.conn, svc.METHOD_ECHO, obj_value(echo_params), alloc, deadline)
	testing.expect_value(t, cerr, jsonrpc.Call_Err.None)
	got := ""
	if v, ok := jsonutil.obj_get(result, "message"); ok {
		#partial switch x in v {
		case json.String:
			got = string(x)
		case:
		}
	}
	testing.expect_value(t, got, "round trip")

	// Schema violations return the typed -32602, never a crash.
	bad := jsonutil.json_object(1, alloc)
	jsonutil.obj_set(&bad, "message", jsonutil.json_int(7))
	_, bad_code, _, bad_cerr := jsonrpc.conn_call(pair.conn, svc.METHOD_ECHO, obj_value(bad), alloc, deadline)
	testing.expect_value(t, bad_cerr, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, bad_code, jsonrpc.Err_Code.Invalid_Params)

	testing.expect(t, jsonrpc.conn_notify(pair.conn, svc.METHOD_BYE, nil, alloc))
}

// --- svc.cancel -------------------------------------------------------------

// Arrival signal for the slow handler: the test waits on it instead of
// sleeping a guessed interval before sending svc.cancel (test-scope only;
// src keeps its no-globals rule).
slow_arrived: sync.One_Shot_Event

slow_wait_cancel :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	sync.one_shot_event_signal(&slow_arrived)
	// A checkpoint-bound worker: block until svc.cancel fires the request
	// token, then surface the cancellation the way the boundary maps it.
	platform.token_wait(ctx.token)
	e, fired := platform.token_check(ctx.token)
	if fired {
		return nil, e
	}
	return nil, platform.Wrapped{kind = .Internal, msg = "slow handler token never fired"}
}

// slow2 is the same checkpoint-bound worker under its own one-shot event
// so two cancel tests can coexist under random test order.
slow2_arrived: sync.One_Shot_Event

slow2_wait_cancel :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	sync.one_shot_event_signal(&slow2_arrived)
	platform.token_wait(ctx.token)
	e, fired := platform.token_check(ctx.token)
	if fired {
		return nil, e
	}
	return nil, platform.Wrapped{kind = .Internal, msg = "slow2 handler token never fired"}
}

Slow_Result :: struct {
	err_code: jsonrpc.Err_Code,
	call_err: jsonrpc.Call_Err,
	done:     bool,
	mu:       sync.Mutex,
	cond:     sync.Cond,
}

slow_caller_entry :: proc(data: rawptr) {
	box := cast(^struct {pair: ^Daemon_Pair, res: ^Slow_Result})data
	_, code, _, cerr := jsonrpc.conn_call(
		box.pair.conn,
		"svc.test/slow",
		nil,
		context.temp_allocator,
		platform.mono_ms() + 5000,
	)
	sync.mutex_lock(&box.res.mu)
	box.res.err_code = code
	box.res.call_err = cerr
	box.res.done = true
	sync.cond_broadcast(&box.res.cond)
	sync.mutex_unlock(&box.res.mu)
}

Slow_Call_Box :: struct {
	pair: ^Daemon_Pair,
	res:  ^Slow_Result,
}

@(test)
svc_cancel_fires_parent_token :: proc(t: ^testing.T) {
	pair := test_daemon(t, true)
	if pair == nil {
		return
	}

	res := new(Slow_Result, context.allocator)
	res^ = {}
	box := new(Slow_Call_Box, context.allocator)
	box^ = {pair = pair, res = res}
	sthr := thread.create_and_start_with_data(box, slow_caller_entry, self_cleanup = false)

	// Wait until the slow handler is actually running on the daemon (its
	// request token is registered by then), then cancel — the arrival event
	// replaces the old sleep-based guess. Bounded: a handler that never
	// arrives fails the test instead of hanging it.
	testing.expect(t, one_shot_event_wait_bounded(&slow_arrived, 10_000), "slow handler never arrived")
	cancel_params := jsonutil.json_object(1, context.temp_allocator)
	jsonutil.obj_set(&cancel_params, "call_id", jsonutil.json_int(1))
	testing.expect(t, jsonrpc.conn_notify(pair.conn, svc.METHOD_CANCEL, obj_value(cancel_params), context.temp_allocator))

	// Bounded: the caller thread's own 5 s call deadline guarantees the
	// join below terminates even when the cancellation is lost — the
	// outcome asserts then fail loudly instead of hanging the runner.
	sync.mutex_lock(&res.mu)
	deadline := platform.mono_ms() + 10_000
	for !res.done && platform.mono_ms() < deadline {
		sync.cond_wait_with_timeout(&res.cond, &res.mu, 20 * 1_000_000)
	}
	sync.mutex_unlock(&res.mu)
	thread.join(sthr)
	free(sthr, context.allocator)
	free(box, context.allocator)
	testing.expect_value(t, res.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, res.err_code, jsonrpc.Err_Code.Request_Cancelled)
	free(res, context.allocator)

	pair_shutdown(pair)
}

// --- cancellation through the child's conn_call token -------------------------
//
// A blocked svc call must stop waiting when its token fires, forward
// svc.cancel to the daemon (which aborts the in-flight handler), and free
// the slot either way.

pair_cancel_notify :: proc(c: ^jsonrpc.Conn, id: i64) {
	params := jsonutil.json_object(1, context.temp_allocator)
	jsonutil.obj_set(&params, "call_id", jsonutil.json_int(id))
	_ = jsonrpc.conn_notify(c, svc.METHOD_CANCEL, json.Value(json.Object(params)), context.temp_allocator)
}

Cancel_Call_Box :: struct {
	pair:  ^Daemon_Pair,
	token: ^platform.Cancel_Token,
	res:   ^Slow_Result,
}

cancel_caller_entry :: proc(data: rawptr) {
	box := cast(^Cancel_Call_Box)data
	_, code, _, cerr := jsonrpc.conn_call(
		box.pair.conn,
		"svc.test/slow2",
		nil,
		context.temp_allocator,
		platform.mono_ms() + 5000,
		box.token,
	)
	sync.mutex_lock(&box.res.mu)
	box.res.err_code = code
	box.res.call_err = cerr
	box.res.done = true
	sync.cond_broadcast(&box.res.cond)
	sync.mutex_unlock(&box.res.mu)
}

@(test)
svc_cancel_propagates_from_a_blocked_child_call :: proc(t: ^testing.T) {
	pair := test_daemon(t, true)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)
	pair.conn.cancel_notify = pair_cancel_notify

	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)
	defer platform.token_destroy(root, context.allocator)
	task := platform.token_derive(root, 0, context.allocator)
	defer platform.token_destroy(task, context.allocator)

	res := new(Slow_Result, context.allocator)
	box := new(Cancel_Call_Box, context.allocator)
	box^ = {pair = pair, token = task, res = res}
	sthr := thread.create_and_start_with_data(box, cancel_caller_entry, self_cleanup = false)

	// Once the daemon is inside the handler, firing the caller's token
	// must both unblock the child and abort the daemon side. Bounded the
	// same way as the arrival wait above.
	testing.expect(t, one_shot_event_wait_bounded(&slow2_arrived, 10_000), "slow2 handler never arrived")
	platform.token_fire(root, .Cancelled)

	// Bounded: the caller thread's own 5 s call deadline guarantees the
	// join below terminates even when the cancellation is lost — the
	// outcome asserts then fail loudly instead of hanging the runner.
	sync.mutex_lock(&res.mu)
	deadline := platform.mono_ms() + 10_000
	for !res.done && platform.mono_ms() < deadline {
		sync.cond_wait_with_timeout(&res.cond, &res.mu, 20 * 1_000_000)
	}
	sync.mutex_unlock(&res.mu)
	thread.join(sthr)
	free(sthr, context.allocator)
	free(box, context.allocator)

	// Which side wins the race is timing: either the child abandons first
	// (.Cancelled) or the daemon's cancelled reply lands first — but the
	// call must end cancelled, never completed or timed out.
	if res.call_err == jsonrpc.Call_Err.Error_Response {
		testing.expect_value(t, res.err_code, jsonrpc.Err_Code.Request_Cancelled)
	} else {
		testing.expect_value(t, res.call_err, jsonrpc.Call_Err.Cancelled)
	}
	free(res, context.allocator)
}

// --- svc.shutdown -------------------------------------------------------------

// pair_shutdown_stopped tears down a pair whose daemon already exited via
// svc.shutdown: same order as pair_shutdown minus the root-token fire (the
// run thread is already gone).
pair_shutdown_stopped :: proc(p: ^Daemon_Pair) {
	jsonrpc.conn_close(p.conn)
	p.endpoint.stream.close(&p.endpoint.stream)
	if p.reader != nil {
		thread.join(p.reader)
		free(p.reader, context.allocator)
	}
	free(p.box, context.allocator)

	if p.run_thread != nil {
		thread.join(p.run_thread)
		free(p.run_thread, context.allocator)
	}
	// The daemon exited through svc.shutdown: daemon_run already destroyed
	// the root token after its cleanup.
	free(p.daemon, context.allocator)

	rpc.channel_endpoint_destroy(p.daemon_endpoint)
	rpc.channel_endpoint_destroy(p.endpoint)
	jsonrpc.conn_destroy(p.conn)
	free(p.conn, context.allocator)
	free(p.clock, context.allocator)
	_ = os.remove_all(p.tmp)
	delete(p.tmp)
	_ = os.remove_all(p.home)
	delete(p.home)
	free(p, context.allocator)
}

@(test)
svc_shutdown_stops_daemon :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	params := jsonutil.json_object(1, alloc)
	jsonutil.obj_set(&params, "token", jsonutil.json_string(pair.daemon.auth_token))
	result, _, _, cerr := jsonrpc.conn_call(
		pair.conn, svc.METHOD_SHUTDOWN, obj_value(params), alloc,
		platform.mono_ms() + 5000,
	)
	testing.expect_value(t, cerr, jsonrpc.Call_Err.None)
	stopping := false
	if v, ok := jsonutil.obj_get(result, "stopping"); ok {
		#partial switch x in v {
		case json.Boolean:
			stopping = x
		case:
		}
	}
	testing.expect(t, stopping, "shutdown must answer {stopping: true}")

	pair_shutdown_stopped(pair)
}

@(test)
svc_shutdown_rejects_bad_token :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	// In-process daemons skip listen (no endpoint), so auth_token is empty
	// and the hello/shutdown auth guard would pass anything. Give the daemon
	// a root token so the check is exercised; cleanup frees it with the
	// daemon's allocator.
	pair.daemon.auth_token = strings.clone("root-token-xyz", pair.daemon.allocator)

	params := jsonutil.json_object(1, alloc)
	jsonutil.obj_set(&params, "token", jsonutil.json_string("not-the-root-token"))
	_, code, msg, cerr := jsonrpc.conn_call(
		pair.conn, svc.METHOD_SHUTDOWN, obj_value(params), alloc,
		platform.mono_ms() + 5000,
	)
	testing.expect_value(t, cerr, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, code, jsonrpc.Err_Code.Invalid_Request)
	testing.expect(t, strings.contains(msg, "token"), "refusal must name the token problem")

	// The token was injected by the test (in-process daemons never publish
	// an endpoint, so cleanup's endpoint-gated free would skip it).
	delete(pair.daemon.auth_token, pair.daemon.allocator)
	pair.daemon.auth_token = ""
}

// --- glue cancellation checkpoint ---------------------------------------------
//
// A request whose derived token is born fired (its session root already
// fired) must be refused before the handler runs. The check lives in the
// glue so no handler can miss it.

spy_ran: bool // test-scope only; read after joining the conn thread (the
// join is the happens-before edge, matching the slow_arrived exemption)

svc_glue_spy :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	spy_ran = true
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "ok", jsonutil.json_bool(true))
	return json.Value(json.Object(out)), nil
}

Fired_Hook_State :: struct {
	root:      ^platform.Cancel_Token,
	allocator: mem.Allocator,
	slot:      ^platform.Cancel_Token, // token of the one in-flight call
}

fired_token_derive :: proc(user: rawptr, conn_id: int, call_id: i64) -> ^platform.Cancel_Token {
	s := cast(^Fired_Hook_State)user
	s.slot = platform.token_derive(s.root, 0, s.allocator)
	return s.slot
}

fired_token_release :: proc(user: rawptr, conn_id: int, call_id: i64, token: ^platform.Cancel_Token) {
	s := cast(^Fired_Hook_State)user
	// The glue hands back the token its derive hook returned: destroying
	// exactly that one is the per-registration pairing the daemon's
	// registry relies on.
	if token != nil {
		platform.token_destroy(token, s.allocator)
	}
	s.slot = nil
}

@(test)
svc_glue_rejects_fired_token_at_entry :: proc(t: ^testing.T) {
	spy_ran = false // shared spy flag: reset per test (random test order)
	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)
	platform.token_fire(root, .Cancelled)
	defer platform.token_destroy(root, context.allocator)

	hs := new(Fired_Hook_State, context.allocator)
	defer free(hs, context.allocator)
	hs^ = {root = root, allocator = context.allocator}

	table := new(svc.Table, context.allocator)
	svc.table_init(table, context.allocator)
	svc.table_register(table, "svc.test/spy", svc_glue_spy)

	p: Pipe
	pipe_init(&p)
	c := new(jsonrpc.Conn, context.allocator)
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, pipe_read, &p, 1024)
	w: jsonrpc.Writer
	jsonrpc.writer_init(&w, pipe_write, &p)
	jsonrpc.conn_init(c, r, w, context.allocator)
	svc.attach(c, table, hs, 1)
	svc.attach_tokens(c, fired_token_derive)
	svc.release_tokens(c, fired_token_release)

	lb := new(Loopback, context.allocator)
	lb^ = {conn = c, pipe = &p}
	thr := thread.create_and_start_with_data(lb, loopback_serve, self_cleanup = false)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	_, code, _, cerr := jsonrpc.conn_call(
		c, "svc.test/spy", nil, mem.dynamic_arena_allocator(&arena),
		platform.mono_ms() + 2000,
	)
	testing.expect_value(t, cerr, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, code, jsonrpc.Err_Code.Request_Cancelled)

	jsonrpc.conn_close(c)
	pipe_close(&p)
	thread.join(thr)
	free(thr, context.allocator)
	free(lb, context.allocator)
	svc.detach(c)
	jsonrpc.conn_destroy(c)
	free(c, context.allocator)

	testing.expect_value(t, spy_ran, false)

	delete(table.handlers)
	delete(table.notifiers)
	free(table, context.allocator)
}

always_read_only :: proc(user: rawptr) -> bool {
	return true
}

@(test)
svc_glue_refuses_mutating_methods_when_read_only :: proc(t: ^testing.T) {
	spy_ran = false // shared spy flag: reset per test (random test order)
	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)
	defer platform.token_destroy(root, context.allocator)

	hs := new(Fired_Hook_State, context.allocator)
	defer free(hs, context.allocator)
	hs^ = {root = root, allocator = context.allocator}

	table := new(svc.Table, context.allocator)
	svc.table_init(table, context.allocator)
	svc.table_register_mutating(table, "svc.test/mutate", svc_glue_spy)
	svc.table_register(table, "svc.test/read", svc_glue_spy)

	p: Pipe
	pipe_init(&p)
	c := new(jsonrpc.Conn, context.allocator)
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, pipe_read, &p, 1024)
	w: jsonrpc.Writer
	jsonrpc.writer_init(&w, pipe_write, &p)
	jsonrpc.conn_init(c, r, w, context.allocator)
	svc.attach(c, table, hs, 1)
	svc.attach_read_only(c, always_read_only)
	svc.attach_tokens(c, fired_token_derive)
	svc.release_tokens(c, fired_token_release)

	lb := new(Loopback, context.allocator)
	lb^ = {conn = c, pipe = &p}
	thr := thread.create_and_start_with_data(lb, loopback_serve, self_cleanup = false)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	// The mutating method is refused at the boundary — its handler must
	// not run (spy_ran stays false until the read call below).
	_, mcode, _, merr := jsonrpc.conn_call(c, "svc.test/mutate", nil, alloc, platform.mono_ms() + 2000)
	testing.expect_value(t, merr, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, mcode, jsonrpc.Err_Code.Invalid_Request)
	testing.expect_value(t, spy_ran, false)

	// Non-mutating methods still serve.
	_, _, _, rerr := jsonrpc.conn_call(c, "svc.test/read", nil, alloc, platform.mono_ms() + 2000)
	testing.expect_value(t, rerr, jsonrpc.Call_Err.None)
	testing.expect_value(t, spy_ran, true)

	jsonrpc.conn_close(c)
	pipe_close(&p)
	thread.join(thr)
	free(thr, context.allocator)
	free(lb, context.allocator)
	svc.detach(c)
	jsonrpc.conn_destroy(c)
	free(c, context.allocator)

	delete(table.handlers)
	delete(table.notifiers)
	delete(table.mutating)
	free(table, context.allocator)
}

// --- hello gate -----------------------------------------------------------------

Hello_State :: struct {
	authed: bool,
}

hello_gate_fixture :: proc(user: rawptr, conn_id: int) -> bool {
	hs := cast(^Hello_State)user
	return hs.authed
}

hello_gate_mark :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	hs := cast(^Hello_State)ctx.user
	hs.authed = true
	out := jsonutil.json_object(0, ctx.allocator)
	return json.Value(json.Object(out)), nil
}

// notify-spy counter for the gate test (test-scope only; src keeps its
// no-globals rule).
note_count: int
note_mu:   sync.Mutex

note_spy :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) {
	sync.mutex_lock(&note_mu)
	note_count += 1
	sync.mutex_unlock(&note_mu)
}

@(test)
svc_glue_gates_requests_until_hello :: proc(t: ^testing.T) {
	spy_ran = false // shared spy flag: reset per test (random test order)
	auth := new(Hello_State, context.allocator)
	defer free(auth, context.allocator)

	table := new(svc.Table, context.allocator)
	svc.table_init(table, context.allocator)
	svc.table_register(table, svc.METHOD_HELLO, hello_gate_mark)
	svc.table_register(table, "svc.test/read", svc_glue_spy)
	svc.table_register_notification(table, "svc.test/note", note_spy)

	p: Pipe
	pipe_init(&p)
	c := new(jsonrpc.Conn, context.allocator)
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, pipe_read, &p, 1024)
	w: jsonrpc.Writer
	jsonrpc.writer_init(&w, pipe_write, &p)
	jsonrpc.conn_init(c, r, w, context.allocator)
	svc.attach(c, table, auth, 1)
	svc.attach_hello_gate(c, hello_gate_fixture)

	lb := new(Loopback, context.allocator)
	lb^ = {conn = c, pipe = &p}
	thr := thread.create_and_start_with_data(lb, loopback_serve, self_cleanup = false)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	// Before hello: every request method is refused at the boundary — the
	// handler must not run (an unauthenticated connection must not reach
	// the svc surface even though it can reach the socket).
	_, gcode, _, gerr := jsonrpc.conn_call(c, "svc.test/read", nil, alloc, platform.mono_ms() + 2000)
	testing.expect_value(t, gerr, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, gcode, jsonrpc.Err_Code.Invalid_Request)
	testing.expect_value(t, spy_ran, false)

	// The gate covers notifications too: one sent before hello is dropped
	// at the boundary (bye/cancel-shaped lifecycle control included). The
	// hello reply below orders it — the read loop serves frames in
	// arrival order, so once hello's reply exists the gated notification
	// was already (not) served.
	sync.mutex_lock(&note_mu)
	note_count = 0
	sync.mutex_unlock(&note_mu)
	testing.expect(t, jsonrpc.conn_notify(c, "svc.test/note", nil, alloc))

	// hello itself is exempt from the gate and opens the surface.
	_, _, _, herr := jsonrpc.conn_call(c, svc.METHOD_HELLO, nil, alloc, platform.mono_ms() + 2000)
	testing.expect_value(t, herr, jsonrpc.Call_Err.None)
	testing.expect_value(t, auth.authed, true)
	sync.mutex_lock(&note_mu)
	testing.expect_value(t, note_count, 0)
	sync.mutex_unlock(&note_mu)

	_, _, _, rerr := jsonrpc.conn_call(c, "svc.test/read", nil, alloc, platform.mono_ms() + 2000)
	testing.expect_value(t, rerr, jsonrpc.Call_Err.None)
	testing.expect_value(t, spy_ran, true)

	// After hello the same notification runs; the read call's reply
	// orders it, so the count is deterministic.
	testing.expect(t, jsonrpc.conn_notify(c, "svc.test/note", nil, alloc))
	_, _, _, rerr2 := jsonrpc.conn_call(c, "svc.test/read", nil, alloc, platform.mono_ms() + 2000)
	testing.expect_value(t, rerr2, jsonrpc.Call_Err.None)
	sync.mutex_lock(&note_mu)
	testing.expect_value(t, note_count, 1)
	sync.mutex_unlock(&note_mu)

	jsonrpc.conn_close(c)
	pipe_close(&p)
	thread.join(thr)
	free(thr, context.allocator)
	free(lb, context.allocator)
	svc.detach(c)
	jsonrpc.conn_destroy(c)
	free(c, context.allocator)

	delete(table.handlers)
	delete(table.notifiers)
	delete(table.mutating)
	free(table, context.allocator)
}
