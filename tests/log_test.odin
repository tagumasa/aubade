// Tests for the leveled logger (parse and the enabled matrix) and the
// pieces wired through it: the jsonrpc frame-trace hook (both directions,
// borrowed-body contract) and the svc.hello trace_lsp flag reaching the
// daemon's language-server manager.
package tests

import "core:encoding/json"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:thread"

import "src:jsonrpc"
import "src:jsonutil"
import "src:langserver"
import "src:platform"
import "src:svc"
import "src:util"

@(test)
log_parse_and_levels :: proc(t: ^testing.T) {
	l, ok := util.log_parse_level("debug")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, l, util.Log_Level.Debug)

	// The flag keeps the user's casing; the loader stores lowercase.
	l, ok = util.log_parse_level("ERROR")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, l, util.Log_Level.Error)

	_, ok = util.log_parse_level("verbose")
	testing.expect_value(t, ok, false)

	// Default (pre-init or config default) is Warning: debug and info are
	// suppressed, warning and error pass.
	util.log_init(.Warning)
	testing.expect_value(t, util.log_enabled(.Debug), false)
	testing.expect_value(t, util.log_enabled(.Info), false)
	testing.expect_value(t, util.log_enabled(.Warning), true)
	testing.expect_value(t, util.log_enabled(.Error), true)

	util.log_set_level(.Debug)
	testing.expect_value(t, util.log_level(), util.Log_Level.Debug)
	testing.expect_value(t, util.log_enabled(.Info), true)

	// Restore the suite default: the logger is process-global state.
	util.log_set_level(.Warning)
}

// --- jsonrpc frame tracing ---------------------------------------------------

Trace_Rec :: struct {
	mu:   sync.Mutex,
	n:    int,
	out:  [4]bool,
	body: [4][256]u8,
	lens: [4]int,
}

trace_rec_hook :: proc(user: rawptr, outbound: bool, body: string) {
	rec := cast(^Trace_Rec)user
	sync.mutex_lock(&rec.mu)
	if rec.n < 4 {
		rec.out[rec.n] = outbound
		take := len(body)
		if take > 256 {
			take = 256
		}
		for i := 0; i < take; i += 1 {
			rec.body[rec.n][i] = body[i]
		}
		rec.lens[rec.n] = take
		rec.n += 1
	}
	sync.mutex_unlock(&rec.mu)
}

trace_contains :: proc(rec: ^Trace_Rec, i: int, needle: string) -> bool {
	hay := rec.body[i][:rec.lens[i]]
	for j := 0; j + len(needle) <= len(hay); j += 1 {
		match := true
		for k := 0; k < len(needle); k += 1 {
			if hay[j + k] != needle[k] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

@(test)
conn_trace_hook_sees_both_directions :: proc(t: ^testing.T) {
	p: Pipe
	pipe_init(&p)

	rec := new(Trace_Rec, context.allocator)
	defer free(rec, context.allocator)
	rec^ = {}

	// The loopback serve thread reads frames through the same allocator as
	// the test thread's calls — wrap the tracking allocator (the lsp and
	// outbound harnesses do the same).
	ma: mem.Mutex_Allocator
	mem.mutex_allocator_init(&ma, context.allocator)
	ca := mem.mutex_allocator(&ma)
	c := new(jsonrpc.Conn, ca)
	defer free(c, ca)
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, pipe_read, &p, 1024, ca)
	w: jsonrpc.Writer
	jsonrpc.writer_init(&w, pipe_write, &p)
	jsonrpc.conn_init(c, r, w, ca)
	c.trace = trace_rec_hook
	c.trace_user = rec
	jsonrpc.conn_register(c, "svc.test/echo", echo_handler)

	lb := new(Loopback, context.allocator)
	lb^ = {conn = c, pipe = &p}
	thr := thread.create_and_start_with_data(lb, loopback_serve, self_cleanup = false)
	// Teardown is defer-protected from the moment the thread exists: the
	// early return below (and any failure path) must still unblock and
	// reap the loopback, or the leaked runner thread corrupts the
	// per-test tracking allocator. LIFO runs conn_close (unblocks the
	// loopback read) → pipe_close → join → frees → conn_destroy.
	defer jsonrpc.conn_destroy(c)
	defer free(lb, context.allocator)
	defer free(thr, context.allocator)
	defer thread.join(thr)
	defer pipe_close(&p)
	defer jsonrpc.conn_close(c)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	result, _, _, cerr := jsonrpc.conn_call(
		c, "svc.test/echo", nil, mem.dynamic_arena_allocator(&arena), platform.mono_ms() + 2000,
	)
	testing.expect_value(t, cerr, jsonrpc.Call_Err.None)
	testing.expect(t, result != nil, "echo must answer")

	// Same-conn loopback: every frame crosses the hook twice — the
	// request leaves (out) and arrives (in), then the reply leaves (out)
	// and arrives (in). The call returns only after the reply's inbound
	// trace fired, so all four are recorded.
	sync.mutex_lock(&rec.mu)
	n := rec.n
	sync.mutex_unlock(&rec.mu)
	testing.expect_value(t, n, 4)
	if n < 4 {
		return
	}
	testing.expect_value(t, rec.out[0], true)
	testing.expect(t, trace_contains(rec, 0, `"method":"svc.test/echo"`), "outbound request body")
	testing.expect_value(t, rec.out[1], false)
	testing.expect(t, trace_contains(rec, 1, `"method":"svc.test/echo"`), "inbound request body")
	testing.expect_value(t, rec.out[2], true)
	testing.expect(t, trace_contains(rec, 2, `"echo"`), "outbound reply body")
	testing.expect_value(t, rec.out[3], false)
	testing.expect(t, trace_contains(rec, 3, `"echo"`), "inbound reply body")
}

// --- svc.hello trace flag ----------------------------------------------------

@(test)
svc_hello_trace_flag_reaches_manager :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	params := jsonutil.json_object(2, alloc)
	jsonutil.obj_set(&params, "client_pid", jsonutil.json_int(222))
	jsonutil.obj_set(&params, "trace_lsp", jsonutil.json_bool(true))
	_, _, _, cerr := jsonrpc.conn_call(
		pair.conn, svc.METHOD_HELLO, json.Value(json.Object(params)), alloc, platform.mono_ms() + 2000,
	)
	testing.expect_value(t, cerr, jsonrpc.Call_Err.None)
	testing.expect(t, pair.daemon.ls != nil, "daemon must own a language-server manager")
	if pair.daemon.ls != nil {
		testing.expectf(
			t, langserver.manager_trace_enabled(pair.daemon.ls),
			"hello trace_lsp must turn manager tracing on",
		)
	}
}
