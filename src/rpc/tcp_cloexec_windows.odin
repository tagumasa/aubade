#+build windows

// tcp_set_cloexec (Windows): sockets are inheritable handles by default
// (core:net creates them through plain socket()), and core's spawn passes
// bInheritHandles=true with no handle list — every socket open at spawn
// time (the daemon's loopback listener, accepted and dialed connections)
// would ride into each child, holding peers open past the daemon's own
// close and accumulating handles in long-lived language servers. Clearing
// HANDLE_FLAG_INHERIT is the close-on-exec analog: the socket ends with
// this process alone. Best effort, matching the fcntl twins — a refused
// call leaves the flag set, never closes a live socket.
package rpc

import "core:net"
import "core:sys/windows"

tcp_set_cloexec :: proc(sock: net.TCP_Socket) {
	_ = windows.SetHandleInformation(
		cast(windows.HANDLE)(cast(uintptr)sock),
		windows.HANDLE_FLAG_INHERIT,
		0,
	)
}
