// The Windows side of the curl socket guard: socket creation through
// winsock and the proxy-host resolver through GetAddrInfoW's ANSI entry
// (the same resolver the non-Windows mirrors use — the proxy first-hop
// allowance resolves the configured proxy host and tests its addresses
// against the private ranges like any other target).
package web

import c "core:c/libc"
import "core:strings"

import curl "vendor:curl"

import win32 "core:sys/windows"

// AF_INET6 as Winsock spells it (see http.odin's AF note).
AF_INET6_VAL :: 23

create_stream_socket :: proc(family: c.int, socktype: c.int, protocol: c.int) -> curl.socket_t {
	s := win32.socket(i32(family), i32(socktype), i32(protocol))
	if s == win32.INVALID_SOCKET {
		return curl.SOCKET_BAD
	}
	if u64(s) > 0xFFFFFFFF {
		return curl.SOCKET_BAD
	}
	return curl.socket_t(u32(u64(s)))
}

// resolve_host turns a hostname into its addresses through the platform
// resolver (used only for the proxy first-hop allowance). The result is
// an owned [dynamic] array carrying `a`; the caller deletes it.
resolve_host :: proc(host: string, a := context.allocator) -> [dynamic]IP_Addr {
	out := make([dynamic]IP_Addr, 0, 4, a)
	hints: win32.ADDRINFOA
	hints.ai_family = 0 // AF_UNSPEC: both families
	hints.ai_socktype = win32.SOCK_STREAM
	host_c := strings.clone_to_cstring(host, context.temp_allocator)
	res: ^win32.ADDRINFOA = nil
	if win32.getaddrinfo(host_c, nil, &hints, &res) != 0 || res == nil {
		return out
	}
	defer win32.freeaddrinfo(res)
	for it := res; it != nil; it = it.ai_next {
		if it.ai_addr == nil {
			continue
		}
		family := int(it.ai_family)
		if family != AF_INET_VAL && family != AF_INET6_VAL { // AF_INET, AF_INET6
			continue
		}
		addr: IP_Addr
		if family == 2 {
			in4 := cast(^win32.sockaddr_in)(it.ai_addr)
			addr.family = .V4
			be := in4.sin_addr.s_addr // little-endian load of network-order bytes
			for i := 0; i < 4; i += 1 {
				addr.bytes[i] = u8((be >> cast(u32)(8 * i)) & 0xFF)
			}
		} else {
			in6 := cast(^win32.sockaddr_in6)(it.ai_addr)
			addr.family = .V6
			for i := 0; i < 16; i += 1 {
				addr.bytes[i] = in6.sin6_addr.s6_addr[i]
			}
		}
		append(&out, addr)
	}
	return out
}
