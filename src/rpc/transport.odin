// rpc: transport abstraction over byte streams. The svc boundary and the
// jsonrpc framing sit on Stream; implementations are the in-memory channel
// pair (tests, --in-process) and loopback TCP (the production daemon link,
// ephemeral port published through the daemon's endpoint file). Hosts stay
// transport-agnostic.
package rpc

import "core:mem"
import "src:jsonrpc"

Stream :: struct {
	read:  proc(s: ^Stream, buf: []u8) -> (int, jsonrpc.Read_Err),
	write: proc(s: ^Stream, buf: []u8) -> (int, jsonrpc.Read_Err),
	close: proc(s: ^Stream),
	data:  rawptr,
}

stream_read_adapter :: proc(data: rawptr, buf: []u8) -> (int, jsonrpc.Read_Err) {
	s := cast(^Stream)data
	return s.read(s, buf)
}

stream_write_adapter :: proc(data: rawptr, buf: []u8) -> (int, jsonrpc.Read_Err) {
	s := cast(^Stream)data
	return s.write(s, buf)
}

to_reader :: proc(s: ^Stream, max_frame_bytes: int) -> jsonrpc.Reader {
	r: jsonrpc.Reader
	jsonrpc.reader_init(&r, stream_read_adapter, s, max_frame_bytes)
	return r
}

to_writer :: proc(s: ^Stream) -> jsonrpc.Writer {
	w: jsonrpc.Writer
	jsonrpc.writer_init(&w, stream_write_adapter, s)
	return w
}

// stream_free releases a heap-allocated Stream together with its state
// (implementations that need a state block allocate it and the Stream in
// one wrapper allocation).
stream_free :: proc(s: ^Stream, a := context.allocator) {
	free(s, a)
}

_ :: mem.Allocator
