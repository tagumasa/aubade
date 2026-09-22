#+build linux

// tcp_set_cloexec (Linux): the raw fcntl from core:sys/unix marks the
// socket close-on-exec so a spawned parent never inherits the child's live
// connection fds.
package rpc

import "core:net"
import "core:sys/unix"

F_GETFD_CMD     :: 1
F_SETFD_CMD     :: 2
FD_CLOEXEC_FLAG :: 1

tcp_set_cloexec :: proc(sock: net.TCP_Socket) {
	fd := cast(int)sock
	flags := unix.sys_fcntl(fd, F_GETFD_CMD, 0)
	if flags >= 0 {
		unix.sys_fcntl(fd, F_SETFD_CMD, flags | FD_CLOEXEC_FLAG)
	}
}
