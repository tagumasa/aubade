#+build darwin

// tcp_set_cloexec (darwin): libSystem fcntl marks the socket
// close-on-exec (the syscall wrappers under core:sys/unix expose no
// fcntl on darwin, but core:sys/posix does), so a spawned parent never
// inherits the child's live connection fds. Binding a second foreign
// declaration to the same libSystem symbol would collide with
// core:sys/posix's own, so use that one directly.
package rpc

import "core:net"
import "core:sys/posix"

tcp_set_cloexec :: proc(sock: net.TCP_Socket) {
	fd := cast(posix.FD)(sock)
	flags := posix.fcntl(fd, .GETFD)
	if flags >= 0 {
		posix.fcntl(fd, .SETFD, flags | posix.FD_CLOEXEC)
	}
}
