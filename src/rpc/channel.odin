// Channel transport: two endpoints wired directly through bounded chans of
// byte slices. Used by tests and the --in-process mode so both sides run
// the exact same jsonrpc path as the socket transports. Frame buffers are
// allocated by the sender and freed by the receiver — both through the
// endpoint's pinned allocator, never the thread contexts (the two sides
// run on different threads with different contexts).
package rpc

import "core:mem"
import "core:sync/chan"
import "src:jsonrpc"

CHAN_CAPACITY :: 16 // bounded queue: backpressure propagates to the reader

Chan_Endpoint :: struct {
	incoming:  chan.Chan([]u8, .Recv),
	outgoing:  chan.Chan([]u8, .Send),
	allocator: mem.Allocator,
	stream:    Stream,
	// One received chunk larger than the reader's window: the unconsumed
	// remainder stays here (whole-chunk allocation + consumed offset —
	// freeing a sub-view would be a bad free) until the following reads
	// drain it. The read path is single-reader by construction, so no
	// lock guards these fields.
	pending:     []u8,
	pending_off: int,
}

// channel_pair creates both endpoints (a writes to b, b writes to a).
channel_pair :: proc(a := context.allocator) -> (ea: ^Chan_Endpoint, eb: ^Chan_Endpoint) {
	ab, e1 := chan.create_buffered(chan.Chan([]u8), CHAN_CAPACITY, a)
	if e1 != nil {
		return nil, nil
	}
	ba, e2 := chan.create_buffered(chan.Chan([]u8), CHAN_CAPACITY, a)
	if e2 != nil {
		chan.destroy(ab)
		return nil, nil
	}

	ea = new(Chan_Endpoint, a)
	ea^ = {
		incoming = chan.as_recv(ba),
		outgoing = chan.as_send(ab),
		allocator    = a,
	}
	ea.stream = {
		read  = chan_stream_read,
		write = chan_stream_write,
		close = chan_stream_close,
		data  = ea,
	}

	eb = new(Chan_Endpoint, a)
	eb^ = {
		incoming = chan.as_recv(ab),
		outgoing = chan.as_send(ba),
		allocator    = a,
	}
	eb.stream = {
		read  = chan_stream_read,
		write = chan_stream_write,
		close = chan_stream_close,
		data  = eb,
	}
	return ea, eb
}

// channel_endpoint_destroy tears one endpoint down: its receiving chan is
// destroyed here (each chan has exactly one receiving endpoint, so every
// chan of the pair is destroyed exactly once). Both streams must already
// be closed.
channel_endpoint_destroy :: proc(e: ^Chan_Endpoint, a := context.allocator) {
	chan.destroy(e.incoming)
	if e.pending != nil {
		delete(e.pending, e.allocator)
	}
	free(e, a)
}

chan_stream_read :: proc(s: ^Stream, buf: []u8) -> (int, jsonrpc.Read_Err) {
	e := cast(^Chan_Endpoint)s.data
	if e.pending != nil {
		n := min(len(e.pending) - e.pending_off, len(buf))
		if n > 0 {
			for i := 0; i < n; i += 1 {
				buf[i] = e.pending[e.pending_off + i]
			}
		}
		e.pending_off += n
		if e.pending_off == len(e.pending) {
			delete(e.pending, e.allocator) // receiver frees through the pinned allocator
			e.pending = nil
			e.pending_off = 0
		}
		return n, .None
	}
	data, ok := chan.recv(e.incoming)
	if !ok {
		return 0, .Eof
	}
	if len(data) <= len(buf) {
		for i := 0; i < len(data); i += 1 {
			buf[i] = data[i]
		}
		delete(data, e.allocator)
		return len(data), .None
	}
	// The chunk exceeds the reader's window: hand over the prefix and keep
	// the allocation as the pending remainder.
	for i := 0; i < len(buf); i += 1 {
		buf[i] = data[i]
	}
	e.pending = data
	e.pending_off = len(buf)
	return len(buf), .None
}

chan_stream_write :: proc(s: ^Stream, buf: []u8) -> (int, jsonrpc.Read_Err) {
	e := cast(^Chan_Endpoint)s.data
	data := make([]u8, len(buf), e.allocator)
	for i := 0; i < len(buf); i += 1 {
		data[i] = buf[i]
	}
	if !chan.send(e.outgoing, data) {
		delete(data, e.allocator)
		return 0, .Closed
	}
	return len(buf), .None
}

chan_stream_close :: proc(s: ^Stream) {
	e := cast(^Chan_Endpoint)s.data
	chan.close(e.outgoing)
}
