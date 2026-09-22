// Loopback TCP smoke test for the daemon transport: ephemeral bind, accept
// with an echo thread, framed round trips, reconnect after close, and
// close-wakes-reader (shutdown before close on both sides). Replaces the
// former UDS echo verification. Prints "TCP ECHO OK".
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:thread"
import "src:jsonrpc"
import "src:rpc"

main :: proc() {
	if !run() {
		os.exit(1)
	}
	fmt.println("TCP ECHO OK")
}

run :: proc() -> bool {
	listener, ok := rpc.tcp_listen(0)
	if !ok || listener.port <= 0 {
		return false
	}
	echo_thread := thread.create_and_start_with_data(&listener, echo_entry, self_cleanup = false)
	defer {
		rpc.tcp_listener_close(&listener) // shutdown wakes a blocked accept
		thread.join(echo_thread)
		free(echo_thread, context.allocator)
	}

	// Two rounds: round 0's close exercises reconnect on round 1. Each round
	// frames a payload up, echoes it down, and frames the echoed bytes back
	// once more so both directions carry data.
	for round in 0..<2 {
		stream, dok := rpc.tcp_dial(listener.port)
		if !dok {
			return false
		}
		reader := rpc.to_reader(stream, jsonrpc.RPC_MAX_FRAME)
		writer := rpc.to_writer(stream)
		payload := encode_round(round)
		for _ in 0..<2 {
			if jsonrpc.write_frame(&writer, payload) != .None {
				stream.close(stream)
				return false
			}
			got, rerr := jsonrpc.read_frame(&reader, context.temp_allocator)
			if rerr != .None || string(got) != string(payload) {
				stream.close(stream)
				rpc.stream_free(stream)
				return false
			}
		}
		// Teardown from the client side must wake the echo thread's blocked
		// read (shutdown inside tcp_close) rather than leaving it parked.
		stream.close(stream)
		rpc.stream_free(stream)
	}
	return true
}

// encode_round builds a small distinguishable payload per round.
encode_round :: proc(round: int) -> []u8 {
	body := make([]u8, 24, context.temp_allocator)
	for i in 0..<len(body) {
		body[i] = u8('a' + (i + round) % 26)
	}
	return body
}

echo_entry :: proc(data: rawptr) {
	listener := cast(^rpc.TCP_Listener)data
	for {
		stream, ok := rpc.tcp_accept(listener)
		if !ok {
			return // listener closed
		}
		echo_connection(stream)
	}
}

echo_connection :: proc(stream: ^rpc.Stream) {
	reader := rpc.to_reader(stream, jsonrpc.RPC_MAX_FRAME)
	writer := rpc.to_writer(stream)
	a: mem.Dynamic_Arena
	mem.dynamic_arena_init(&a, context.allocator)
	for {
		body, err := jsonrpc.read_frame(&reader, mem.dynamic_arena_allocator(&a))
		if err != .None {
			break // peer closed (shutdown) or errored
		}
		if jsonrpc.write_frame(&writer, body) != .None {
			break
		}
	}
	mem.dynamic_arena_destroy(&a)
	stream.close(stream)
}
