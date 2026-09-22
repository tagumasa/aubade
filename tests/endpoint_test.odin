// Daemon endpoint publication + discovery tests: the write/read round trip
// with atomic replacement, listen publishing endpoint.json (and a second
// daemon probing it as AlreadyRunning), the drain-wait claim against a live
// pid on a closed port, and svc.hello token rejection over the channel
// transport.
package tests

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "src:daemon"
import "src:jsonrpc"
import "src:jsonutil"
import "src:platform"

temp_daemon_dir :: proc(t: ^testing.T) -> string {
	tmp, terr := os.make_directory_temp("", "aubade-endpoint-", context.allocator)
	if terr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	return tmp
}

// new_listen_daemon builds a daemon over a fresh temp project (real clock:
// the drain wait sleeps for real) with the given drain window.
new_listen_daemon :: proc(t: ^testing.T, drain_ms: i64) -> (d: ^daemon.Daemon, tmp: string) {
	tmp = temp_daemon_dir(t)
	return new_listen_daemon_in(t, tmp, drain_ms), tmp
}

// new_listen_daemon_in builds a daemon whose project root is `root` — two
// daemons over the same root share the runtime directory (project_id).
new_listen_daemon_in :: proc(t: ^testing.T, root: string, drain_ms: i64) -> ^daemon.Daemon {
	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, false)
	d := new(daemon.Daemon, context.allocator)
	cfg := daemon.default_config(root, root, clock)
	cfg.drain_ms = drain_ms
	if !daemon.daemon_init(d, cfg, context.allocator) {
		testing.fail_now(t, "daemon_init failed")
	}
	return d
}

// release_listen_daemon tears down a daemon that only listened (never ran):
// after daemon_cleanup already ran, free the token, clock, struct, and the
// temp project dir (when owned).
release_listen_daemon :: proc(d: ^daemon.Daemon, tmp: string) {
	platform.token_destroy(d.root, context.allocator)
	platform.clock_destroy(d.cfg.clock)
	free(d.cfg.clock, context.allocator)
	free(d, context.allocator)
	if tmp != "" {
		_ = os.remove_all(tmp)
		delete(tmp, context.allocator)
	}
}

write_text_file :: proc(path: string, body: string) -> bool {
	f, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions{.Read_User, .Write_User})
	if err != nil {
		return false
	}
	_, werr := os.write(f, transmute([]u8)body)
	os.close(f)
	return werr == nil
}

@(test)
endpoint_round_trip_replaces_atomically :: proc(t: ^testing.T) {
	tmp := temp_daemon_dir(t)
	defer {
		_ = os.remove_all(tmp)
		delete(tmp, context.allocator)
	}
	path, _ := filepath.join([]string{tmp, "endpoint.json"}, context.allocator)
	defer delete(path, context.allocator)

	first := daemon.Endpoint_Info{pid = 111, port = 22222, started_at_ms = 1000, token = "aa"}
	testing.expect(t, daemon.write_endpoint(path, first), "first write must succeed")
	info, ok := daemon.read_endpoint(path, context.allocator)
	testing.expect(t, ok, "read must succeed")
	testing.expect_value(t, info.pid, 111)
	testing.expect_value(t, info.port, 22222)
	testing.expect_value(t, info.started_at_ms, 1000)
	testing.expect_value(t, info.token, "aa")

	// Replacement is atomic: the second publication wins whole.
	second := daemon.Endpoint_Info{pid = 333, port = 44444, started_at_ms = 2000, token = "bb"}
	testing.expect(t, daemon.write_endpoint(path, second), "second write must succeed")
	delete(info.token, context.allocator)
	info, ok = daemon.read_endpoint(path, context.allocator)
	testing.expect(t, ok, "re-read must succeed")
	testing.expect_value(t, info.pid, 333)
	testing.expect_value(t, info.port, 44444)
	testing.expect_value(t, info.token, "bb")
	delete(info.token, context.allocator)

	// Garbage reads as "not up", never as a crash.
	garbage_path, _ := filepath.join([]string{tmp, "garbage.json"}, context.allocator)
	defer delete(garbage_path, context.allocator)
	testing.expect(t, write_text_file(garbage_path, "{truncated"), "garbage write must succeed")
	_, gok := daemon.read_endpoint(garbage_path, context.allocator)
	testing.expect(t, !gok, "garbage must read as not-ok")
}

@(test)
daemon_listen_publishes_and_probe_wins :: proc(t: ^testing.T) {
	d, tmp := new_listen_daemon(t, daemon.DEFAULT_DRAIN_MS)
	defer release_listen_daemon(d, tmp)

	testing.expect_value(t, daemon.daemon_listen(d), daemon.Listen_Result.Listening)

	// The publication carries the bound port, our pid, and a 32-hex token.
	info, ok := daemon.read_endpoint(d.endpoint_path, context.allocator)
	testing.expect(t, ok, "endpoint must be published after listen")
	testing.expect_value(t, info.pid, d.pid)
	testing.expect_value(t, info.port, d.tcp_listener.port)
	testing.expect_value(t, len(info.token), 32)
	testing.expect_value(t, info.token, d.auth_token)
	for c in info.token {
		testing.expect(t, (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'), "token must be hex")
	}
	delete(info.token, context.allocator)

	// Guarantee 1 — a second parent probing a live port exits AlreadyRunning.
	rival := new_listen_daemon_in(t, tmp, daemon.DEFAULT_DRAIN_MS)
	testing.expect_value(t, daemon.daemon_listen(rival), daemon.Listen_Result.AlreadyRunning)
	daemon.daemon_cleanup(rival)
	release_listen_daemon(rival, "")

	// Cleanup removes the publication, so a fresh parent can claim again.
	daemon.daemon_cleanup(d)
	fresh := new_listen_daemon_in(t, tmp, daemon.DEFAULT_DRAIN_MS)
	testing.expect_value(t, daemon.daemon_listen(fresh), daemon.Listen_Result.Listening)
	daemon.daemon_cleanup(fresh)
	release_listen_daemon(fresh, "")
}

@(test)
daemon_probe_waits_out_drain_window :: proc(t: ^testing.T) {
	// A publication whose port is closed but whose pid is alive (ours) is a
	// draining owner: the probe waits it out (bounded) and then claims.
	d, tmp := new_listen_daemon(t, 20) // drain 20ms + margin max(200, 2) = 200ms
	defer release_listen_daemon(d, tmp)

	info := daemon.Endpoint_Info{
		pid           = d.pid, // alive: this very test process
		port          = 1,     // discard port: nothing listens there
		started_at_ms = 0,
		token         = "x",
	}
	testing.expect(t, daemon.write_endpoint(d.endpoint_path, info), "fake drain endpoint must be written")

	before := platform.mono_ms()
	testing.expect_value(t, daemon.daemon_listen(d), daemon.Listen_Result.Listening)
	elapsed := platform.mono_ms() - before
	// The wait is bounded by drain_ms + max(200, drain/10) — with drain 20ms
	// that is 220ms. Assert it waited at least the drain window and stayed
	// within a generous upper bound.
	testing.expect(t, elapsed >= 20, "probe must wait out the drain window")
	testing.expect(t, elapsed < 5000, "probe wait must stay bounded")
	daemon.daemon_cleanup(d)
}

@(test)
svc_hello_rejects_wrong_token :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	// The in-process daemon has no token of its own; inject one to exercise
	// the check (freed by the test, not by cleanup, which only frees tokens
	// generated at listen).
	tok := strings.clone("expected-token", context.allocator)
	pair.daemon.auth_token = tok
	// Teardown is defer-protected from here: the token outlives the pair
	// (the daemon's cleanup frees only listen-generated tokens), so its
	// delete registers first and runs last.
	defer delete(tok, context.allocator)
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	deadline := platform.mono_ms() + 2000

	bad := jsonutil.json_object(2, mem.dynamic_arena_allocator(&arena))
	jsonutil.obj_set(&bad, "client_pid", jsonutil.json_int(12345))
	jsonutil.obj_set(&bad, "token", jsonutil.json_string("wrong"))
	_, code, _, cerr := jsonrpc.conn_call(pair.conn, "svc.hello", obj_value(bad), mem.dynamic_arena_allocator(&arena), deadline)
	testing.expect_value(t, cerr, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, code, jsonrpc.Err_Code.Invalid_Params)

	good := jsonutil.json_object(2, mem.dynamic_arena_allocator(&arena))
	jsonutil.obj_set(&good, "client_pid", jsonutil.json_int(12345))
	jsonutil.obj_set(&good, "token", jsonutil.json_string("expected-token"))
	result, _, _, gerr := jsonrpc.conn_call(pair.conn, "svc.hello", obj_value(good), mem.dynamic_arena_allocator(&arena), deadline)
	testing.expect_value(t, gerr, jsonrpc.Call_Err.None)
	testing.expect(t, result != nil, "hello with the right token must succeed")

	// svc.status answers the registry counts (this connection is registered).
	status, _, _, serr := jsonrpc.conn_call(pair.conn, "svc.status", nil, mem.dynamic_arena_allocator(&arena), deadline)
	testing.expect_value(t, serr, jsonrpc.Call_Err.None)
	found := false
	if v, ok := jsonutil.obj_get(status, "children_total"); ok {
		#partial switch x in v {
		case json.Integer:
			found = x >= 1
		case:
		}
	}
	testing.expect(t, found, "status must report at least this connection")
}

// daemon_init owns its failure unwind: both failure paths (the runtime-dir
// mkdir failing before anything is assigned, and the project store failing
// after the struct is fully populated) must leave nothing behind — the
// per-test tracking allocator flags a stranded token, string, or checker.
@(test)
daemon_init_failure_unwinds_partial_state :: proc(t: ^testing.T) {
	tmp := temp_daemon_dir(t)
	defer {
		_ = os.remove_all(tmp)
		delete(tmp, context.allocator)
	}

	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, false)
	defer {
		platform.clock_destroy(clock)
		free(clock, context.allocator)
	}

	// Late failure: the state path exists as a FILE, so the project store
	// cannot open under it. init has already assigned the resolved root,
	// owned strings, cancel token, children backing, and the safety
	// checker — all of which the unwind must release.
	state_dir, _ := filepath.join([]string{tmp, ".aubade"}, context.allocator)
	defer delete(state_dir, context.allocator)
	_ = os.write_entire_file_from_string(state_dir, "", os.Permissions{.Read_User, .Write_User})
	testing.expect(t, os.exists(state_dir), "blocker file must be created")

	d := new(daemon.Daemon, context.allocator)
	cfg := daemon.default_config(tmp, tmp, clock)
	testing.expect(t, !daemon.daemon_init(d, cfg, context.allocator), "init must fail when the state path is a file")
	free(d, context.allocator)

	// Early failure: home is a FILE, so the daemon runtime directory
	// cannot be created; nothing was assigned into d, and the resolved
	// root copy must still be released.
	home_file, _ := filepath.join([]string{tmp, "home-is-a-file"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(home_file, "", os.Permissions{.Read_User, .Write_User})
	testing.expect(t, os.exists(home_file), "home blocker must be created")
	d2 := new(daemon.Daemon, context.allocator)
	cfg2 := daemon.default_config(tmp, home_file, clock)
	testing.expect(t, !daemon.daemon_init(d2, cfg2, context.allocator), "init must fail when home is a file")
	free(d2, context.allocator)
}
