// Contract tests for the core chan behaviors the daemon's teardown wake
// relies on (close_child closes the frames queue before joining a reader
// that may be blocked on a full queue). If core semantics ever change so
// these fail, the daemon teardown wedge R3-20 fixed comes back — the
// blocked-sender test would hang rather than fail, which the suite
// timeout surfaces.
package tests

import "core:sync/chan"
import "core:thread"
import "core:testing"

// Send_Job is the thread payload: proc literals do not capture, so the
// endpoints travel through the struct.
Send_Job :: struct {
	frames: chan.Chan([]u8),
	done:   chan.Chan(bool),
}

send_blocked_until_closed :: proc(data: rawptr) {
	job := cast(^Send_Job)data
	// Blocks while the queue is full; must return false once closed.
	_ = chan.send(chan.as_send(job.frames), []u8{3})
	chan.send(chan.as_send(job.done), true)
}

@(test)
chan_close_wakes_blocked_sender :: proc(t: ^testing.T) {
	frames, ferr := chan.create_buffered(chan.Chan([]u8), 2, context.allocator)
	testing.expectf(t, ferr == nil, "chan create failed")
	defer chan.destroy(frames)

	send := chan.as_send(frames)
	testing.expect(t, chan.send(send, []u8{1}))
	testing.expect(t, chan.send(send, []u8{2})) // full now

	done, derr := chan.create_buffered(chan.Chan(bool), 1, context.allocator)
	testing.expectf(t, derr == nil, "done chan create failed")
	defer chan.destroy(done)

	job := new(Send_Job, context.allocator)
	defer free(job, context.allocator)
	job^ = {frames = frames, done = done}

	th := thread.create_and_start_with_data(job, send_blocked_until_closed, self_cleanup = false)
	chan.close(send) // the wake under test
	got, ok := chan.recv(chan.as_recv(done))
	testing.expect(t, ok && got, "blocked sender must wake on close")
	thread.join(th)
	free(th, context.allocator)
}

@(test)
chan_recv_drains_buffered_after_close :: proc(t: ^testing.T) {
	frames, ferr := chan.create_buffered(chan.Chan(int), 2, context.allocator)
	testing.expectf(t, ferr == nil, "chan create failed")
	defer chan.destroy(frames)

	send := chan.as_send(frames)
	testing.expect(t, chan.send(send, 11))
	testing.expect(t, chan.send(send, 22))
	chan.close(send)

	recv := chan.as_recv(frames)
	v1, ok1 := chan.recv(recv)
	v2, ok2 := chan.recv(recv)
	_, ok3 := chan.recv(recv)
	testing.expect(t, ok1, "buffered item 1 must survive close")
	testing.expect_value(t, v1, 11)
	testing.expect(t, ok2, "buffered item 2 must survive close")
	testing.expect_value(t, v2, 22)
	testing.expect(t, !ok3, "empty closed chan must report closed")
}
