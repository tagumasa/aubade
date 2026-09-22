// Loopback TCP: the daemon link transport on every platform. The port is
// always ephemeral (bind(0)) and published through the daemon's endpoint
// file, so there is no port configuration surface. Authentication is the
// startup token published with the port and checked at svc.hello; the
// endpoint file lives in a 0700 directory, so only the owning user can read
// it.
package rpc

import "base:intrinsics"
import "core:net"
import "src:jsonrpc"

TCP_State :: struct {
	socket: net.TCP_Socket,
	// 0 = closed, 1 = open. Touched only through atomic intrinsics:
	// close is called from up to three threads (reader teardown, heartbeat
	// declare-dead, reap), and a check-then-act on a plain bool could let
	// two of them shutdown+close the same socket (the second close could
	// hit a recycled descriptor).
	open: u32,
}

// TCP_Wrapper keeps the Stream and its TCP_State in ONE allocation: the
// generic stream_free then releases both with a single free. Splitting them
// (two news) leaked the state block on every close+free.
TCP_Wrapper :: struct {
	stream: Stream,
	state:  TCP_State,
}

tcp_stream :: proc(sock: net.TCP_Socket, a := context.allocator) -> ^Stream {
	tcp_set_cloexec(sock)
	w := new(TCP_Wrapper, a)
	w^ = {
		stream = {
			read  = tcp_read,
			write = tcp_write,
			close = tcp_close,
			data  = &w.state,
		},
		state = {socket = sock, open = 1},
	}
	return &w.stream
}

tcp_read :: proc(s: ^Stream, buf: []u8) -> (int, jsonrpc.Read_Err) {
	st := cast(^TCP_State)s.data
	if intrinsics.atomic_load(&st.open) == 0 {
		return 0, .Closed
	}
	for {
		n, err := net.recv_tcp(st.socket, buf)
		if err == .Interrupted {
			continue // a signal is neither EOF nor failure; retry the read
		}
		if err == .None && n >= 0 {
			if n == 0 {
				return 0, .Eof
			}
			return n, .None
		}
		return 0, .Io
	}
}

tcp_write :: proc(s: ^Stream, buf: []u8) -> (int, jsonrpc.Read_Err) {
	st := cast(^TCP_State)s.data
	if intrinsics.atomic_load(&st.open) == 0 {
		return 0, .Closed
	}
	for {
		n, err := net.send_tcp(st.socket, buf)
		if err == .Interrupted {
			continue // retry: returning 0/.None would read as a hard error
		}
		if err == .None {
			return n, .None
		}
		return 0, .Io
	}
}

// tcp_close shuts down both directions before closing: a plain close from
// another thread does not reliably wake a reader blocked in recv on POSIX,
// while shutdown(2) does — this is what unblocks the reader threads at
// teardown. The exchange makes the close idempotent under concurrency:
// exactly one caller observes the old value 1 and performs the syscalls.
tcp_close :: proc(s: ^Stream) {
	st := cast(^TCP_State)s.data
	if intrinsics.atomic_exchange(&st.open, 0) != 0 {
		net.shutdown(st.socket, .Both)
		net.close(st.socket)
	}
}

TCP_Listener :: struct {
	socket: net.TCP_Socket,
	port:   int,
}

// tcp_listen binds 127.0.0.1:<port> (port 0 = pick one, returned).
tcp_listen :: proc(port: int) -> (TCP_Listener, bool) {
	ep := net.Endpoint{
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	sock, err := net.listen_tcp(ep, 16)
	if err != nil {
		return {}, false
	}
	tcp_set_cloexec(sock)
	bound, berr := net.bound_endpoint(sock)
	if berr != nil {
		net.close(sock)
		return {}, false
	}
	return {socket = sock, port = bound.port}, true
}

tcp_accept :: proc(l: ^TCP_Listener) -> (conn: ^Stream, ok: bool) {
	client, _, err := net.accept_tcp(l.socket)
	if err != nil {
		return nil, false
	}
	return tcp_stream(client), true
}

// tcp_listener_close shuts down before closing so a thread blocked in accept
// wakes instead of lingering (POSIX accept fails with EINVAL once the
// listening socket is shut down).
tcp_listener_close :: proc(l: ^TCP_Listener) {
	net.shutdown(l.socket, .Both)
	net.close(l.socket)
}

// tcp_dial connects to 127.0.0.1:<port>.
tcp_dial :: proc(port: int) -> (stream: ^Stream, ok: bool) {
	ep := net.Endpoint{
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	sock, err := net.dial_tcp_from_endpoint(ep)
	if err != nil {
		return nil, false
	}
	return tcp_stream(sock), true
}
