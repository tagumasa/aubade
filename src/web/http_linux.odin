// The platform side of the curl socket guard (mirrored for each
// non-Windows OS — Odin has no _posix suffix): socket creation and the
// getaddrinfo-based proxy host resolution.
package web

import c "core:c/libc"
import "core:strings"

import curl "vendor:curl"

import posix "core:sys/posix"

// AF_INET6 as Linux's C library spells it (see http.odin's AF note).
AF_INET6_VAL :: 10

create_stream_socket :: proc(family: c.int, socktype: c.int, protocol: c.int) -> curl.socket_t {
	return curl.socket_t(posix.socket(transmute(posix.AF)family, transmute(posix.Sock)socktype, transmute(posix.Protocol)protocol))
}

// resolve_host turns a hostname into its addresses through the platform
// resolver (used only for the proxy first-hop allowance). The result is
// an owned [dynamic] array carrying `a`; the caller deletes it.
resolve_host :: proc(host: string, a := context.allocator) -> [dynamic]IP_Addr {
	out := make([dynamic]IP_Addr, 0, 4, a)
	hints: posix.addrinfo
	hints.ai_family = posix.AF.UNSPEC // both families
	hints.ai_socktype = posix.Sock.STREAM
	info: ^posix.addrinfo = nil
	host_c := strings.clone_to_cstring(host, context.temp_allocator)
	rc := posix.getaddrinfo(host_c, nil, &hints, &info)
	if rc != posix.Info_Errno(0) || info == nil {
		return out
	}
	defer posix.freeaddrinfo(info)
	for it := info; it != nil; it = it.ai_next {
		if it.ai_addr == nil {
			continue
		}
		family := int(it.ai_family)
		if family != AF_INET_VAL && family != AF_INET6_VAL {
			continue
		}
		base := cast([^]u8)(it.ai_addr)
		addr: IP_Addr
		if family == AF_INET_VAL {
			addr.family = .V4
			for i := 0; i < 4; i += 1 {
				addr.bytes[i] = base[4 + i]
			}
		} else {
			addr.family = .V6
			for i := 0; i < 16; i += 1 {
				addr.bytes[i] = base[8 + i]
			}
		}
		append(&out, addr)
	}
	return out
}
