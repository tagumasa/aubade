// jsonrpc component tests: framing (defects, split delivery, oversize,
// huge messages), ID normalization, batch rejection, and full Conn
// roundtrips over an in-memory loopback pipe (server dispatch + client
// pending table, timeout, and close semantics).
package tests

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:testing"
import "core:thread"
import "core:time"
import "src:jsonrpc"
import "src:jsonutil"
import "src:platform"

// --- in-memory loopback pipe (writes feed the same pipe's reads) ---------

Pipe :: struct {
	buf:              [dynamic]u8,
	mu:               sync.Mutex,
	cond:             sync.Cond,
	closed:           bool,
	allocator:        mem.Allocator,
	// Optional per-read deadline in ms (0 = wait forever). A read that
	// would block longer returns .Eof instead of parking the reading
	// thread — for harnesses whose producer thread may die before writing
	// its frame, so the suite fails in bounded time instead of hanging.
	read_deadline_ms: i64,
}

pipe_init :: proc(p: ^Pipe, a := context.allocator) {
	p^ = {allocator = a}
}

// The pipe procs run on several threads (test, caller, reader); each pins
// the buffer to the pipe's own allocator so growth and free always match,
// whatever context the calling thread carries.
pipe_write :: proc(data: rawptr, buf: []u8) -> (int, jsonrpc.Read_Err) {
	p := cast(^Pipe)data
	context.allocator = p.allocator
	sync.mutex_lock(&p.mu)
	if p.closed {
		sync.mutex_unlock(&p.mu)
		return 0, .Eof
	}
	append(&p.buf, ..buf)
	sync.cond_broadcast(&p.cond)
	sync.mutex_unlock(&p.mu)
	return len(buf), .None
}

pipe_read :: proc(data: rawptr, buf: []u8) -> (int, jsonrpc.Read_Err) {
	p := cast(^Pipe)data
	context.allocator = p.allocator
	sync.mutex_lock(&p.mu)
	if p.read_deadline_ms > 0 {
		// Timed wait: cond_wait_with_timeout returns on the deadline even
		// without a signal, and the loop re-checks the buffer each wake.
		deadline := platform.mono_ms() + p.read_deadline_ms
		for len(p.buf) == 0 && !p.closed {
			remaining := deadline - platform.mono_ms()
			if remaining <= 0 {
				break
			}
			sync.cond_wait_with_timeout(&p.cond, &p.mu, time.Duration(remaining * 1_000_000))
		}
	} else {
		for len(p.buf) == 0 && !p.closed {
			sync.cond_wait(&p.cond, &p.mu)
		}
	}
	if len(p.buf) == 0 {
		sync.mutex_unlock(&p.mu)
		return 0, .Eof
	}
	n := min(len(p.buf), len(buf))
	for i := 0; i < n; i += 1 {
		buf[i] = p.buf[i]
	}
	rest := len(p.buf) - n
	for i := 0; i < rest; i += 1 {
		p.buf[i] = p.buf[i + n]
	}
	resize(&p.buf, rest)
	sync.mutex_unlock(&p.mu)
	return n, .None
}

pipe_close :: proc(p: ^Pipe) {
	context.allocator = p.allocator
	sync.mutex_lock(&p.mu)
	p.closed = true
	// Always delete: a fully drained buffer (len 0) still owns its backing.
	delete(p.buf)
	sync.cond_broadcast(&p.cond)
	sync.mutex_unlock(&p.mu)
}

// json_bytes copies a JSON literal into test scratch (backtick literals
// are untyped and cannot be transmuted directly).
json_bytes :: proc(s: string) -> []u8 {
	b := make([]u8, len(s), context.temp_allocator)
	for i in 0..<len(s) {
		b[i] = s[i]
	}
	return b
}

// --- framing --------------------------------------------------------------

@(test)
frame_roundtrip :: proc(t: ^testing.T) {
	p: Pipe
	pipe_init(&p)
	defer pipe_close(&p)
	w: jsonrpc.Writer
	jsonrpc.writer_init(&w, pipe_write, &p)
	body := "hello framing world"
	testing.expect(t, jsonrpc.write_frame(&w, transmute([]u8)body) == .None)

	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, pipe_read, &p, 1024)
	defer jsonrpc.reader_destroy(&r)
	got, rerr := jsonrpc.read_frame(&r, context.temp_allocator)
	testing.expect(t, rerr == .None)
	testing.expect_value(t, string(got), body)
}

// Source serves a fixed byte slice; max_per_call limits each read so the
// frame assembler must accumulate across many reads (max_per_call=1 turns
// it into a byte-dribble).
Source :: struct {
	src:          []u8,
	pos:          int,
	max_per_call: int,
}

source_read :: proc(data: rawptr, buf: []u8) -> (int, jsonrpc.Read_Err) {
	s := cast(^Source)data
	if s.pos >= len(s.src) {
		return 0, .Eof
	}
	take := min(len(buf), len(s.src) - s.pos)
	if s.max_per_call > 0 {
		take = min(take, s.max_per_call)
	}
	for i := 0; i < take; i += 1 {
		buf[i] = s.src[s.pos + i]
	}
	s.pos += take
	return take, .None
}

@(test)
frame_split_delivery :: proc(t: ^testing.T) {
	frame := "Content-Length: 5\r\n\r\nabcde"
	d := Source{src = transmute([]u8)frame, max_per_call = 1}
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, source_read, &d, 1024)
	defer jsonrpc.reader_destroy(&r)
	got, err := jsonrpc.read_frame(&r, context.temp_allocator)
	testing.expect(t, err == .None)
	testing.expect_value(t, string(got), "abcde")
}

@(test)
frame_missing_content_length :: proc(t: ^testing.T) {
	bogus := "X-Bogus: 1\r\n\r\nbody"
	src := Source{src = transmute([]u8)bogus}
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, source_read, &src, 1024)
	defer jsonrpc.reader_destroy(&r)
	_, err := jsonrpc.read_frame(&r, context.temp_allocator)
	testing.expect_value(t, err, jsonrpc.Read_Err.Framing)
}

@(test)
frame_oversize_rejected :: proc(t: ^testing.T) {
	huge := "Content-Length: 999999999\r\n\r\n"
	src := Source{src = transmute([]u8)huge}
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, source_read, &src, 1024)
	defer jsonrpc.reader_destroy(&r)
	_, err := jsonrpc.read_frame(&r, context.temp_allocator)
	testing.expect_value(t, err, jsonrpc.Read_Err.Too_Large)
}

@(test)
frame_header_without_separator_capped :: proc(t: ^testing.T) {
	// A peer streaming header bytes without ever sending the blank-line
	// separator must hit the header-block bound (which never exceeds the
	// frame cap, so a small-cap reader keeps its tighter meaning), and the
	// overrun is malformed framing, not an over-long body.
	junk := "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	src := Source{src = transmute([]u8)junk, max_per_call = 1}
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, source_read, &src, 16)
	defer jsonrpc.reader_destroy(&r)
	_, err := jsonrpc.read_frame(&r, context.temp_allocator)
	testing.expect_value(t, err, jsonrpc.Read_Err.Framing)
}

@(test)
frame_header_block_cap_bounded_below_frame_cap :: proc(t: ^testing.T) {
	// The header wait is bounded by the header-block cap, not the frame
	// cap: on a full-size reader (64 MiB class) a separator-less stream is
	// cut after a few KiB — the 16 KiB source ends in .Framing rather than
	// .Eof, and the buffer never grows toward the frame cap.
	junk := make([dynamic]u8, 16 * 1024, context.allocator)
	for i := 0; i < len(junk); i += 1 {
		junk[i] = 'A'
	}
	defer delete(junk)
	src := Source{src = junk[:], max_per_call = 512}
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, source_read, &src, jsonrpc.DEFAULT_MAX_FRAME)
	defer jsonrpc.reader_destroy(&r)
	_, err := jsonrpc.read_frame(&r, context.temp_allocator)
	testing.expect_value(t, err, jsonrpc.Read_Err.Framing)
	testing.expect(t, len(r.buf.data) <= 2 * jsonrpc.HEADER_MAX_BYTES, "buffer stays header-sized")
}

// A read_fn that returns zero bytes with no error is a contract violation
// (every real source answers "0 bytes => error"); the frame read folds it
// into .Io instead of spinning forever.
zero_progress_read :: proc(data: rawptr, buf: []u8) -> (int, jsonrpc.Read_Err) {
	_ = data
	_ = buf
	return 0, .None
}

@(test)
frame_read_rejects_progress_less_source :: proc(t: ^testing.T) {
	r: jsonrpc.Reader
	jsonrpc.reader_init_ndjson(&r, zero_progress_read, nil, 1024)
	defer jsonrpc.reader_destroy(&r)
	_, err := jsonrpc.read_frame(&r, context.temp_allocator)
	testing.expect_value(t, err, jsonrpc.Read_Err.Io)
}

// Same guard, second site: a source that serves a complete Content-Length
// header and then makes no progress forever must end the body loop, not
// spin it.
stuck_after_header_read :: proc(data: rawptr, buf: []u8) -> (int, jsonrpc.Read_Err) {
	s := cast(^Source)data
	if s.pos >= len(s.src) {
		return 0, .None
	}
	take := min(len(buf), len(s.src) - s.pos)
	for i := 0; i < take; i += 1 {
		buf[i] = s.src[s.pos + i]
	}
	s.pos += take
	return take, .None
}

@(test)
frame_read_body_loop_rejects_progress_less_source :: proc(t: ^testing.T) {
	header := "Content-Length: 5\r\n\r\n"
	d := Source{src = transmute([]u8)header}
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, stuck_after_header_read, &d, 1024)
	defer jsonrpc.reader_destroy(&r)
	_, err := jsonrpc.read_frame(&r, context.temp_allocator)
	testing.expect_value(t, err, jsonrpc.Read_Err.Io)
}

@(test)
frame_huge_message_roundtrip :: proc(t: ^testing.T) {
	p: Pipe
	pipe_init(&p)
	defer pipe_close(&p)
	w: jsonrpc.Writer
	jsonrpc.writer_init(&w, pipe_write, &p)
	payload := make([]u8, 1024 * 1024, context.temp_allocator)
	for i in 0..<len(payload) {
		payload[i] = u8(i % 251)
	}
	testing.expect(t, jsonrpc.write_frame(&w, payload) == .None)

	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, pipe_read, &p, 2 * 1024 * 1024)
	defer jsonrpc.reader_destroy(&r)
	got, err := jsonrpc.read_frame(&r, context.temp_allocator)
	testing.expect(t, err == .None)
	testing.expect_value(t, len(got), len(payload))
	match := true
	for i in 0..<len(payload) {
		if got[i] != payload[i] {
			match = false
			break
		}
	}
	testing.expect(t, match, "1 MiB payload corrupted")
}

// --- envelope / ID normalization ------------------------------------------

@(test)
id_normalization :: proc(t: ^testing.T) {
	env, _ := jsonrpc.decode_envelope(json_bytes(`{"jsonrpc":"2.0","id":42,"method":"m"}`), context.temp_allocator)
	testing.expect(t, env != nil)
	testing.expect(t, env.id_set)
#partial switch v in env.id {
	case i64:
		testing.expect_value(t, v, i64(42))
	case:
		testing.expectf(t, false, "numeric id not normalized to i64")
	}

	env, _ = jsonrpc.decode_envelope(json_bytes(`{"jsonrpc":"2.0","id":"42","method":"m"}`), context.temp_allocator)
#partial switch v in env.id {
	case string:
		testing.expect_value(t, v, "42") // the JSON type is preserved: the reply must echo the same value
	case:
		testing.expectf(t, false, "numeric string id collapsed into a number")
	}

	env, _ = jsonrpc.decode_envelope(json_bytes(`{"jsonrpc":"2.0","id":"abc-42","method":"m"}`), context.temp_allocator)
#partial switch v in env.id {
	case string:
		testing.expect_value(t, v, "abc-42")
	case:
		testing.expectf(t, false, "non-numeric string id must stay a string")
	}

	env, _ = jsonrpc.decode_envelope(json_bytes(`{"jsonrpc":"2.0","method":"n"}`), context.temp_allocator)
	testing.expect_value(t, env.kind, jsonrpc.Msg_Kind.Notification)
	testing.expect(t, !env.id_set)
}

@(test)
batch_rejected :: proc(t: ^testing.T) {
	env, code := jsonrpc.decode_envelope(json_bytes(`[{"jsonrpc":"2.0","id":1,"method":"m"}]`), context.temp_allocator)
	testing.expect(t, env == nil)
	testing.expect_value(t, code, jsonrpc.Err_Code.Invalid_Request)
}

@(test)
envelope_requires_jsonrpc_member :: proc(t: ^testing.T) {
	// JSON-RPC 2.0 demands the member on every message; foreign input that
	// merely looks request-shaped is rejected at the boundary.
	env, code := jsonrpc.decode_envelope(json_bytes(`{"id":1,"method":"m"}`), context.temp_allocator)
	testing.expect(t, env == nil)
	testing.expect_value(t, code, jsonrpc.Err_Code.Invalid_Request)

	env, code = jsonrpc.decode_envelope(json_bytes(`{"jsonrpc":"1.0","id":1,"method":"m"}`), context.temp_allocator)
	testing.expect(t, env == nil)
	testing.expect_value(t, code, jsonrpc.Err_Code.Invalid_Request)

	env, code = jsonrpc.decode_envelope(json_bytes(`{"jsonrpc":2.0,"id":1,"method":"m"}`), context.temp_allocator)
	testing.expect(t, env == nil)
	testing.expect_value(t, code, jsonrpc.Err_Code.Invalid_Request)

	env, _ = jsonrpc.decode_envelope(json_bytes(`{"jsonrpc":"2.0","id":1,"method":"m"}`), context.temp_allocator)
	testing.expect(t, env != nil)
}

@(test)
notification_body_omits_null_params :: proc(t: ^testing.T) {
	// Notification params are optional-object on the wire, never null —
	// a literal "params":null frame is rejected by strict client
	// validators, so the member disappears when there is no payload.
	empty := jsonrpc.build_notification_body("notifications/tools/list_changed", nil, context.temp_allocator)
	testing.expect_value(t, empty, `{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}`)

	params := jsonutil.json_object(1, context.temp_allocator)
	jsonutil.obj_set(&params, "n", jsonutil.json_int(7))
	loaded := jsonrpc.build_notification_body("n", json.Value(json.Object(params)), context.temp_allocator)
	testing.expect_value(t, loaded, `{"jsonrpc":"2.0","method":"n","params":{"n":7}}`)
}

@(test)
request_body_omits_null_params :: proc(t: ^testing.T) {
	// Requests keep the same contract: a nil params means the member is
	// absent, not null — strict peers reject a literal "params":null for
	// methods whose params are optional (LSP shutdown carries none).
	empty := jsonrpc.build_request_body(7, "shutdown", nil, context.temp_allocator)
	testing.expect_value(t, empty, `{"jsonrpc":"2.0","id":7,"method":"shutdown"}`)

	params := jsonutil.json_object(1, context.temp_allocator)
	jsonutil.obj_set(&params, "n", jsonutil.json_int(7))
	loaded := jsonrpc.build_request_body(3, "m", json.Value(json.Object(params)), context.temp_allocator)
	testing.expect_value(t, loaded, `{"jsonrpc":"2.0","id":3,"method":"m","params":{"n":7}}`)
}

// --- Conn roundtrips --------------------------------------------------------

echo_handler :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	out := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&out, "echo", jsonutil.json_string(env.method))
	reply: jsonrpc.Reply = {result = json.Value(json.Object(out))}
	return reply, .Respond
}

Loopback :: struct {
	conn: ^jsonrpc.Conn,
	pipe: ^Pipe,
}

loopback_serve :: proc(data: rawptr) {
	lb := cast(^Loopback)data
	jsonrpc.conn_read_loop(lb.conn)
}

@(test)
conn_request_response_roundtrip :: proc(t: ^testing.T) {
	p: Pipe
	pipe_init(&p)

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
	jsonrpc.conn_register(c, "svc.test/echo", echo_handler)

	lb := new(Loopback, context.allocator)
	lb^ = {conn = c, pipe = &p}
	thr := thread.create_and_start_with_data(lb, loopback_serve, self_cleanup = false)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	result, _, _, cerr := jsonrpc.conn_call(c, "svc.test/echo", nil, mem.dynamic_arena_allocator(&arena), platform.mono_ms() + 2000)
	testing.expect_value(t, cerr, jsonrpc.Call_Err.None)
	echoed := ""
	if v, ok := jsonutil.obj_get(result, "echo"); ok {
		#partial switch x in v {
		case json.String:
			echoed = string(x)
		case:
		}
	}
	testing.expect_value(t, echoed, "svc.test/echo")

	// Unknown method surfaces as a typed JSON-RPC error.
	_, nf_code, _, nf_cerr := jsonrpc.conn_call(c, "svc.nowhere", nil, mem.dynamic_arena_allocator(&arena), platform.mono_ms() + 2000)
	testing.expect_value(t, nf_cerr, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, nf_code, jsonrpc.Err_Code.Method_Not_Found)

	// Shutdown order: stop the conn, wake the loopback reader through the
	// pipe, join it, then let the defers free the rest.
	jsonrpc.conn_close(c)
	pipe_close(&p)
	thread.join(thr)
	free(thr, context.allocator)
	free(lb, context.allocator)
	jsonrpc.conn_destroy(c)
}

@(test)
conn_call_timeout_and_close :: proc(t: ^testing.T) {
	p: Pipe
	pipe_init(&p)

	// The blocked caller below drives conn_call from a second thread —
	// the conn's allocations ride a mutex allocator over the tracking
	// allocator.
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
	// No handler, no reader: nobody will ever reply.

	deadline := platform.mono_ms() + 120
	_, _, _, cerr := jsonrpc.conn_call(c, "svc.slow", nil, context.temp_allocator, deadline)
	testing.expect_value(t, cerr, jsonrpc.Call_Err.Timeout)

	// A blocked call must be released with .Closed when the conn closes.
	Blocked :: struct {
		conn:   ^jsonrpc.Conn,
		result: jsonrpc.Call_Err,
		done:   bool,
		mu:     sync.Mutex,
		cond:   sync.Cond,
	}
	blocked := new(Blocked, context.allocator)
	defer free(blocked, context.allocator)
	blocked^ = {conn = c}

	blocked_caller :: proc(data: rawptr) {
		b := cast(^Blocked)data
		_, _, _, err := jsonrpc.conn_call(b.conn, "svc.blocked", nil, context.temp_allocator, 0)
		sync.mutex_lock(&b.mu)
		b.result = err
		b.done = true
		sync.cond_broadcast(&b.cond)
		sync.mutex_unlock(&b.mu)
	}
	bthr := thread.create_and_start_with_data(blocked, blocked_caller, self_cleanup = false)

	// Give the caller a moment to post the request, then cut the conn.
	deadline2 := platform.mono_ms() + 500
	for {
		sync.mutex_lock(&p.mu)
		pending := len(p.buf)
		sync.mutex_unlock(&p.mu)
		if pending > 0 || platform.mono_ms() >= deadline2 {
			break
		}
	}
	jsonrpc.conn_close(c)
	pipe_close(&p)

	sync.mutex_lock(&blocked.mu)
	for !blocked.done {
		sync.cond_wait(&blocked.cond, &blocked.mu)
	}
	got := blocked.result
	sync.mutex_unlock(&blocked.mu)
	thread.join(bthr)
	free(bthr, context.allocator)
	jsonrpc.conn_destroy(c)
	testing.expect_value(t, got, jsonrpc.Call_Err.Closed)
}

// A reader-stream EOF must release pending waiters immediately: the peer
// process is gone, no reply can ever arrive, so calls report .Closed long
// before their deadlines — and later calls fail fast at the pending gate.
// Two one-way pipes model a silent server (requests pile up unread; the
// reply stream simply ends).
@(test)
conn_reader_eof_fails_pending :: proc(t: ^testing.T) {
	up := new(Pipe, context.allocator) // client -> server (nobody reads)
	pipe_init(up)
	down := new(Pipe, context.allocator) // server -> client (never answered)
	pipe_init(down)

	// The reader thread and the eof caller both touch the conn — wrap the
	// tracking allocator.
	ma: mem.Mutex_Allocator
	mem.mutex_allocator_init(&ma, context.allocator)
	ca := mem.mutex_allocator(&ma)
	c := new(jsonrpc.Conn, ca)
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, pipe_read, down, 1024, ca)
	w: jsonrpc.Writer
	jsonrpc.writer_init(&w, pipe_write, up)
	jsonrpc.conn_init(c, r, w, ca)
	thr := thread.create_and_start_with_data(c, lsp_reader_entry, self_cleanup = false, name = "jsonrpc-eof-reader")

	Eof_Result :: struct {
		conn: ^jsonrpc.Conn,
		err:  jsonrpc.Call_Err,
		done: bool,
		mu:   sync.Mutex,
		cond: sync.Cond,
	}
	res := new(Eof_Result, context.allocator)
	res^ = {conn = c}
	eof_caller :: proc(data: rawptr) {
		e := cast(^Eof_Result)data
		_, _, _, err := jsonrpc.conn_call(e.conn, "svc.hang", nil, context.temp_allocator, platform.mono_ms() + 5000)
		sync.mutex_lock(&e.mu)
		e.err = err
		e.done = true
		sync.cond_broadcast(&e.cond)
		sync.mutex_unlock(&e.mu)
	}
	caller := thread.create_and_start_with_data(res, eof_caller, self_cleanup = false)

	// Wait until the request is parked (it crossed into the up pipe).
	gate := platform.mono_ms() + 500
	for {
		sync.mutex_lock(&up.mu)
		pending := len(up.buf)
		sync.mutex_unlock(&up.mu)
		if pending > 0 || platform.mono_ms() >= gate {
			break
		}
	}

	before := platform.mono_ms()
	pipe_close(down) // the server's reply stream ends: EOF
	sync.mutex_lock(&res.mu)
	for !res.done {
		sync.cond_wait(&res.cond, &res.mu)
	}
	got := res.err
	sync.mutex_unlock(&res.mu)
	elapsed := platform.mono_ms() - before
	testing.expect_value(t, got, jsonrpc.Call_Err.Closed)
	testing.expect(t, elapsed < 2500, "EOF must release the waiter long before the deadline")

	// The latched pending table refuses new calls outright.
	_, _, _, cerr2 := jsonrpc.conn_call(c, "svc.next", nil, context.temp_allocator, platform.mono_ms() + 100)
	testing.expect_value(t, cerr2, jsonrpc.Call_Err.Closed)

	thread.join(caller)
	free(caller, context.allocator)
	free(res, context.allocator)
	thread.join(thr)
	free(thr, context.allocator)
	jsonrpc.conn_destroy(c)
	free(c, ca)
	pipe_close(up)
	free(up, context.allocator)
	free(down, context.allocator)
}

// conn_call with a cancel token: a fired token must end the wait with
// .Cancelled, forward the cancel through the conn's notify port with the
// request id, and free the slot (no reply will ever be matched).
cancel_notify_id: i64 // single-threaded recording (this test runs on the
// calling thread; see the slow_arrived note in svc_test for the pattern)

recording_cancel_notify :: proc(c: ^jsonrpc.Conn, id: i64) {
	cancel_notify_id = id
}

@(test)
conn_call_returns_early_on_cancel :: proc(t: ^testing.T) {
	p: Pipe
	pipe_init(&p)

	c := new(jsonrpc.Conn, context.allocator)
	defer free(c, context.allocator)
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, pipe_read, &p, 1024)
	w: jsonrpc.Writer
	jsonrpc.writer_init(&w, pipe_write, &p)
	jsonrpc.conn_init(c, r, w, context.allocator)
	c.cancel_notify = recording_cancel_notify
	// No handler, no reader: nobody will ever reply.

	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)
	defer platform.token_destroy(root, context.allocator)
	task := platform.token_derive(root, 0, context.allocator)
	defer platform.token_destroy(task, context.allocator)
	platform.token_fire(root, .Cancelled)

	cancel_notify_id = 0
	_, _, _, cerr := jsonrpc.conn_call(c, "svc.slow", nil, context.temp_allocator, 0, task)
	testing.expect_value(t, cerr, jsonrpc.Call_Err.Cancelled)
	testing.expect_value(t, cancel_notify_id, 1)

	jsonrpc.conn_close(c)
	pipe_close(&p)
	jsonrpc.conn_destroy(c)
}

@(test)
jsonrpc_parse_decimal_bounds :: proc(t: ^testing.T) {
	n, ok := jsonrpc.parse_decimal("0")
	testing.expect(t, ok && n == 0)

	// The cap itself is accepted, one past it is not.
	n, ok = jsonrpc.parse_decimal("1099511627776") // 1 << 40
	testing.expect(t, ok)
	testing.expect_value(t, n, 1 << 40)
	_, ok = jsonrpc.parse_decimal("1099511627777")
	testing.expect(t, !ok)

	// 19+ digits would overflow i64 and wrap negative past a post-multiply
	// check; the bound must reject them before the multiply.
	_, ok = jsonrpc.parse_decimal("9999999999999999999")
	testing.expect(t, !ok)
	_, ok = jsonrpc.parse_decimal("99999999999999999999")
	testing.expect(t, !ok)

	_, ok = jsonrpc.parse_decimal("12x4")
	testing.expect(t, !ok)
	_, ok = jsonrpc.parse_decimal("")
	testing.expect(t, !ok)
}

// --- newline-delimited framing (MCP stdio) -------------------------------------

@(test)
ndjson_frame_roundtrip :: proc(t: ^testing.T) {
	p: Pipe
	pipe_init(&p)
	defer pipe_close(&p)
	w: jsonrpc.Writer
	jsonrpc.writer_init_ndjson(&w, pipe_write, &p)
	body := `{"jsonrpc":"2.0","id":1,"result":{}}`
	testing.expect(t, jsonrpc.write_frame(&w, json_bytes(body)) == .None)

	r: jsonrpc.Reader
	jsonrpc.reader_init_ndjson(&r, pipe_read, &p, 1024)
	defer jsonrpc.reader_destroy(&r)
	got, rerr := jsonrpc.read_frame(&r, context.temp_allocator)
	testing.expect(t, rerr == .None)
	testing.expect_value(t, string(got), body)

	// The second message on the same line stream arrives whole: two
	// frames written back-to-back read as two bodies, terminator eaten.
	testing.expect(t, jsonrpc.write_frame(&w, json_bytes(`{"jsonrpc":"2.0","id":2}`)) == .None)
	got2, rerr2 := jsonrpc.read_frame(&r, context.temp_allocator)
	testing.expect(t, rerr2 == .None)
	testing.expect(t, string(got2) == `{"jsonrpc":"2.0","id":2}`)
}

@(test)
ndjson_frame_split_delivery_and_crlf :: proc(t: ^testing.T) {
	// Byte-dribbled delivery with a CRLF terminator: the CR is stripped.
	frame := "{\"a\":1}\r\n{\"b\":2}\n"
	d := Source{src = json_bytes(frame), max_per_call = 1}
	r: jsonrpc.Reader
	jsonrpc.reader_init_ndjson(&r, source_read, &d, 1024)
	defer jsonrpc.reader_destroy(&r)
	got, err := jsonrpc.read_frame(&r, context.temp_allocator)
	testing.expect(t, err == .None)
	testing.expect(t, string(got) == `{"a":1}`)
	got2, err2 := jsonrpc.read_frame(&r, context.temp_allocator)
	testing.expect(t, err2 == .None)
	testing.expect(t, string(got2) == `{"b":2}`)

	// A trailing partial line at EOF is not a message.
	d2 := Source{src = json_bytes("{\"c\":3"), max_per_call = 1}
	r2: jsonrpc.Reader
	jsonrpc.reader_init_ndjson(&r2, source_read, &d2, 1024)
	defer jsonrpc.reader_destroy(&r2)
	_, err3 := jsonrpc.read_frame(&r2, context.temp_allocator)
	testing.expect_value(t, err3, jsonrpc.Read_Err.Eof)
}

@(test)
ndjson_frame_oversize_rejected :: proc(t: ^testing.T) {
	xs := make([dynamic]u8, 0, 40, context.temp_allocator)
	for i := 0; i < 40; i += 1 {
		append(&xs, 'x')
	}
	long := strings.concatenate({`{"a":"`, string(xs[:]), `"}`}, context.temp_allocator)
	d := Source{src = json_bytes(strings.concatenate({long, "\n"}, context.temp_allocator))}
	r: jsonrpc.Reader
	jsonrpc.reader_init_ndjson(&r, source_read, &d, 16)
	defer jsonrpc.reader_destroy(&r)
	_, err := jsonrpc.read_frame(&r, context.temp_allocator)
	testing.expect_value(t, err, jsonrpc.Read_Err.Too_Large)
}

@(test)
jsonrpc_envelope_clone_string_id :: proc(t: ^testing.T) {
	// A request queued onto the request queue must survive the reader's
	// per-message arena being torn down right after the post — including a
	// string id (numeric ids copy with the struct, strings did not).
	src: mem.Dynamic_Arena
	mem.dynamic_arena_init(&src, context.allocator)
	sa := mem.dynamic_arena_allocator(&src)

	env := new(jsonrpc.Envelope, sa)
	env^ = {
		kind    = .Request,
		id      = strings.clone("server-side-7", sa),
		id_set  = true,
		method  = strings.clone("workspace/configuration", sa),
	}
	clone := jsonrpc.envelope_clone(env, context.allocator)
	mem.dynamic_arena_destroy(&src)

	testing.expect(t, clone.id_set)
	switch v in clone.id {
	case string:
		testing.expect_value(t, v, "server-side-7")
	case i64:
		testing.expectf(t, false, "id must stay the string variant")
	}
	testing.expect(t, clone.method == "workspace/configuration", clone.method)

	delete(clone.method, context.allocator)
	#partial switch v in clone.id {
	case string:
		delete(v, context.allocator)
	}
	free(clone, context.allocator)
}

@(test)
jsonrpc_build_error_body_rides_destination_scope :: proc(t: ^testing.T) {
	// The wire builders serialize every sub-part on the destination
	// allocator together with the final body: a caller on a long-lived
	// thread must not depend on temp resets, so the send's whole
	// footprint must die with the caller's scope. The arena over the
	// tracking allocator is the oracle — the destroy empties the map.
	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	track := mem.tracking_allocator(&ta)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, track)
	body := jsonrpc.build_error_body(7, true, .Internal_Error, "boom \x1b", mem.dynamic_arena_allocator(&arena))
	testing.expect(t, strings.contains(body, `"boom \u001b"`), body)
	testing.expect(t, strings.contains(body, "-32603"), body)
	testing.expect(t, len(ta.allocation_map) > 0, "the builder allocated on the destination")

	mem.dynamic_arena_destroy(&arena)
	testing.expect_value(t, len(ta.allocation_map), 0)
	mem.tracking_allocator_destroy(&ta)
}

@(test)
jsonrpc_request_queue_stop_then_post :: proc(t: ^testing.T) {
	// The queue-stop contract: after queue_stop, a poster reading
	// c.request_queue must observe nil and fail its post cleanly — never
	// touch the freed queue or its chan. The detach is idempotent.
	p: Pipe
	pipe_init(&p)
	defer delete(p.buf)

	c := new(jsonrpc.Conn, context.allocator)
	defer free(c, context.allocator)
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, pipe_read, &p, 1024)
	w: jsonrpc.Writer
	jsonrpc.writer_init(&w, pipe_write, &p)
	jsonrpc.conn_init(c, r, w, context.allocator)

	testing.expect(t, jsonrpc.conn_start_request_queue(c), "queue starts")
	env: jsonrpc.Envelope
	env.kind = .Request
	env.method = "svc.test/nothing"
	testing.expect(t, jsonrpc.queue_try_post(c, &env), "post reaches the live queue")
	jsonrpc.queue_stop(c)
	testing.expect(t, !jsonrpc.queue_try_post(c, &env), "post after stop refuses")
	jsonrpc.queue_stop(c) // the second stop is a no-op, not a double free
}

@(test)
jsonrpc_request_queue_stop_drains_buffered_entries :: proc(t: ^testing.T) {
	// The queue_stop drain contract: every entry still
	// buffered at close is destroyed, not abandoned. The worker's recv
	// drains a closed buffered chan to empty before reporting closed
	// (core:sync/chan semantics), destroying each entry's arena on the
	// way; the tracking allocator is the oracle — were the entries
	// abandoned, every posted arena would surface as a leak WARN.
	p: Pipe
	pipe_init(&p)
	defer delete(p.buf)

	c := new(jsonrpc.Conn, context.allocator)
	defer free(c, context.allocator)
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, pipe_read, &p, 1024)
	w: jsonrpc.Writer
	jsonrpc.writer_init(&w, pipe_write, &p)
	jsonrpc.conn_init(c, r, w, context.allocator)

	testing.expect(t, jsonrpc.conn_start_request_queue(c), "queue starts")
	env: jsonrpc.Envelope
	env.kind = .Request
	env.method = "svc.test/nothing"
	for _ in 0..<6 {
		testing.expect(t, jsonrpc.queue_try_post(c, &env), "post while the queue is live")
	}
	// Whether the worker consumes these before or after the close, every
	// entry's arena is freed on its path out — join covers both orders.
	jsonrpc.queue_stop(c)
	testing.expect(t, !jsonrpc.queue_try_post(c, &env), "post after stop refuses")
}

// The full-queue harness: one handler parked on the gate holds the worker
// mid-dispatch, so the posts behind it exercise the chan's capacity
// deterministically. `entered` (buffered 1) signals handler entry without
// blocking; `release` (unbuffered) parks each handler until the test
// hands it a token.
Queue_Full_Gate :: struct {
	entered: chan.Chan(bool),
	release: chan.Chan(bool),
}

queue_full_block_handler :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	g := cast(^Queue_Full_Gate)conn.host
	_ = chan.try_send(g.entered, true)
	_, _ = chan.recv(g.release)
	// Defer, not Respond: the test never reads replies, so nothing is
	// written to the pipe.
	return {}, .Defer
}

@(test)
jsonrpc_request_queue_full_rejects_without_cloning :: proc(t: ^testing.T) {
	// The full-queue refusal is the flood path, and it must cost O(1): no
	// arena build, no envelope clone. One parked handler holds the first
	// entry mid-dispatch; the next posts fill the chan to capacity; the
	// overflow post must refuse while the queue is provably full.
	entered_raw, eerr := chan.create_buffered(chan.Chan(bool), 1, context.allocator)
	release_raw, rerr := chan.create_unbuffered(chan.Chan(bool), context.allocator)
	if eerr != nil || rerr != nil {
		return
	}
	gate := new(Queue_Full_Gate, context.allocator)
	gate^ = {entered = entered_raw, release = release_raw}
	defer free(gate, context.allocator)
	defer chan.destroy(entered_raw)
	defer chan.destroy(release_raw)

	p: Pipe
	pipe_init(&p)
	defer delete(p.buf)

	c := new(jsonrpc.Conn, context.allocator)
	defer free(c, context.allocator)
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, pipe_read, &p, 1024)
	w: jsonrpc.Writer
	jsonrpc.writer_init(&w, pipe_write, &p)
	jsonrpc.conn_init(c, r, w, context.allocator)
	c.host = gate
	jsonrpc.conn_register(c, "svc.test/block", queue_full_block_handler)

	testing.expect(t, jsonrpc.conn_start_request_queue(c, 2), "queue starts")

	env: jsonrpc.Envelope
	env.kind = .Request
	env.method = "svc.test/block"
	env.id = 1
	env.id_set = true

	testing.expect(t, jsonrpc.queue_try_post(c, &env), "first post reaches the worker")
	_, entered := chan.recv(gate.entered)
	testing.expect(t, entered, "worker took the first entry")
	// The worker holds one entry mid-dispatch; the chan fits exactly two
	// more before the overflow post must refuse.
	testing.expect(t, jsonrpc.queue_try_post(c, &env), "second post fills the chan")
	testing.expect(t, jsonrpc.queue_try_post(c, &env), "third post fills the chan")
	testing.expect(t, !jsonrpc.queue_try_post(c, &env), "overflow post refuses without cloning")

	// Release every parked handler (three entries crossed to the worker
	// side), then join through the normal stop path. conn_destroy releases
	// the handler-table key clones conn_register made.
	for _ in 0..<3 {
		chan.send(gate.release, true)
	}
	jsonrpc.queue_stop(c)
	jsonrpc.conn_destroy(c)
}

@(test)
jsonrpc_request_queue_thread_handle_rides_owner_allocator :: proc(t: ^testing.T) {
	// The worker's ^Thread handle must be allocated from the queue's own
	// allocator — queue_stop frees it through that side — whatever the
	// installing thread's ambient allocator happens to be. The tracking
	// allocator as the owner is the oracle: everything the queue allocated
	// (chan, struct, entry arenas, thread handle) is gone after the stop,
	// so the allocation map must be empty; a handle taken from the ambient
	// would instead be freed cross-allocator.
	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	track := mem.tracking_allocator(&ta)

	p: Pipe
	pipe_init(&p)
	defer delete(p.buf)

	c := new(jsonrpc.Conn, track)
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, pipe_read, &p, 1024, track)
	w: jsonrpc.Writer
	jsonrpc.writer_init(&w, pipe_write, &p)
	jsonrpc.conn_init(c, r, w, track)

	testing.expect(t, jsonrpc.conn_start_request_queue(c, 4, track), "queue starts")
	env: jsonrpc.Envelope
	env.kind = .Request
	env.method = "svc.test/nothing"
	testing.expect(t, jsonrpc.queue_try_post(c, &env), "post reaches the live queue")
	jsonrpc.queue_stop(c)
	jsonrpc.conn_destroy(c)
	free(c, track)

	testing.expect_value(t, len(ta.allocation_map), 0)
	mem.tracking_allocator_destroy(&ta)
}

@(test)
jsonrpc_outbound_thread_handle_rides_owner_allocator :: proc(t: ^testing.T) {
	// Same contract as the request queue's worker: the writer's ^Thread
	// handle must come from the conn's allocator (outbound_join frees it
	// through that side), whatever the installing ambient is. The tracking
	// allocator as the owner is the oracle — an empty allocation map after
	// the destroy.
	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	track := mem.tracking_allocator(&ta)

	p: Pipe
	pipe_init(&p)
	defer delete(p.buf)

	c := new(jsonrpc.Conn, track)
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, pipe_read, &p, 1024, track)
	w: jsonrpc.Writer
	jsonrpc.writer_init(&w, pipe_write, &p)
	jsonrpc.conn_init(c, r, w, track)

	testing.expect(t, jsonrpc.conn_start_outbound(c, 4, 4096), "writer starts")
	jsonrpc.conn_close(c)
	jsonrpc.conn_destroy(c) // joins the writer, frees queue+outbound+handle through `track`
	free(c, track)

	testing.expect_value(t, len(ta.allocation_map), 0)
	mem.tracking_allocator_destroy(&ta)
}

@(test)
conn_call_nil_conn_refused :: proc(t: ^testing.T) {
	// The dispatch host re-reads its svc_conn per task and the teardown
	// withdrawal publishes nil — conn_call must answer that with a typed
	// refusal, not deref the conn.
	_, _, msg, cerr := jsonrpc.conn_call(
		nil, "svc.test/echo", nil, context.temp_allocator, platform.mono_ms() + 50,
	)
	testing.expect_value(t, cerr, jsonrpc.Call_Err.Closed)
	testing.expect(t, msg == "no parent link", msg)
}
