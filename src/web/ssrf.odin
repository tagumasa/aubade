// The SSRF vocabulary for the web layer: private/restricted IP ranges,
// the IP/CIDR whitelist that exempts entries from private-network
// blocking, and the hostname pre-check. The socket-level enforcement
// lives in http.odin's open-socket guard; this file is pure logic so the
// range and whitelist semantics stay table-testable.
package web

import "core:strings"

import "src:util"

Addr_Family :: enum {
	Invalid,
	V4,
	V6,
}

// IP_Addr is a parsed IP address: 4 meaningful bytes for V4, 16 for V6.
IP_Addr :: struct {
	family: Addr_Family,
	bytes:  [16]u8,
}

// Whitelist_Entry is one exempt address (prefix == full length) or CIDR.
Whitelist_Entry :: struct {
	addr:   IP_Addr,
	prefix: int, // bits; -1 marks an exact address entry
}

// Private_Whitelist holds parsed IP and CIDR entries.
Private_Whitelist :: struct {
	entries: [dynamic]Whitelist_Entry,
}

whitelist_init :: proc(w: ^Private_Whitelist, a := context.allocator) {
	w.entries = make([dynamic]Whitelist_Entry, 0, 4, a)
}

whitelist_destroy :: proc(w: ^Private_Whitelist) {
	delete(w.entries)
}

// whitelist_parse builds a whitelist from "IP" and "IP/prefix" entries.
// Empty and whitespace-only entries are skipped; anything unparsable is
// rejected (fail closed).
whitelist_parse :: proc(w: ^Private_Whitelist, list: []string) -> (ok: bool, bad: string) {
	for entry in list {
		trimmed := strings.trim_space(entry)
		if trimmed == "" {
			continue
		}
		addr_part := trimmed
		if idx := strings.last_index_byte(trimmed, '/'); idx >= 0 {
			addr_part = trimmed[:idx]
			plen, pok := parse_prefix(trimmed[idx + 1:])
			if !pok || plen < 0 {
				return false, entry
			}
			addr, aok := parse_ip(addr_part)
			if !aok {
				return false, entry
			}
			// Mapped spellings store collapsed so they compare against
			// plain v4 probes.
			if collapsed, cok := to_v4(addr); cok {
				addr = collapsed
			}
			max_bits := 32
			if addr.family == .V6 {
				max_bits = 128
			}
			if plen > max_bits {
				return false, entry
			}
			e: Whitelist_Entry
			e.addr = addr
			e.prefix = plen
			append(&w.entries, e)
			continue
		}
		addr, aok := parse_ip(addr_part)
		if !aok {
			return false, entry
		}
		if collapsed, cok := to_v4(addr); cok {
			addr = collapsed
		}
		e: Whitelist_Entry
		e.addr = addr
		e.prefix = -1
		append(&w.entries, e)
	}
	return true, ""
}

parse_prefix :: proc(s: string) -> (int, bool) {
	if len(s) == 0 || len(s) > 3 {
		return 0, false
	}
	v := 0
	for i := 0; i < len(s); i += 1 {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		v = v * 10 + int(s[i] - '0')
	}
	return v, true
}

// parse_ip accepts dotted-quad IPv4 and hex-colon IPv6 (with one "::"
// compression and an optional embedded IPv4 tail).
parse_ip :: proc(s: string) -> (IP_Addr, bool) {
	addr: IP_Addr
	if strings.contains(s, ":") {
		ok := parse_v6(s, &addr.bytes)
		if ok {
			addr.family = .V6
			return addr, true
		}
		return addr, false
	}
	if parse_v4(s, &addr.bytes) {
		addr.family = .V4
		return addr, true
	}
	return addr, false
}

parse_v4 :: proc(s: string, out: ^[16]u8) -> bool {
	if s == "" {
		return false
	}
	part := 0
	value := 0
	digits := 0
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == '.' {
			if digits == 0 || digits > 3 || value > 255 || part >= 4 {
				return false
			}
			out[part] = u8(value)
			part += 1
			value = 0
			digits = 0
			continue
		}
		if c < '0' || c > '9' {
			return false
		}
		value = value * 10 + int(c - '0')
		digits += 1
	}
	if digits == 0 || digits > 3 || value > 255 || part != 3 {
		return false
	}
	out[3] = u8(value)
	return true
}

// flush_v6_group stores one parsed hex group or embedded IPv4 tail into
// its run buffer. A plain helper (not nested) because nested procedures
// cannot capture the caller's locals.
flush_v6_group :: proc(grp: string, bytes: ^[16]u8, len_ptr: ^int) -> bool {
	if strings.contains(grp, ".") {
		v4: [16]u8
		if !parse_v4(grp, &v4) {
			return false
		}
		if len_ptr^ + 4 > 16 {
			return false
		}
		bytes[len_ptr^] = v4[0]
		bytes[len_ptr^ + 1] = v4[1]
		bytes[len_ptr^ + 2] = v4[2]
		bytes[len_ptr^ + 3] = v4[3]
		len_ptr^ += 4
		return true
	}
	if len(grp) == 0 || len(grp) > 4 {
		return false
	}
	v := 0
	for i := 0; i < len(grp); i += 1 {
		d := util.hex_digit_value(grp[i])
		if d < 0 {
			return false
		}
		v = v * 16 + d
	}
	if len_ptr^ + 2 > 16 {
		return false
	}
	bytes[len_ptr^] = u8(v >> 8)
	bytes[len_ptr^ + 1] = u8(v & 0xFF)
	len_ptr^ += 2
	return true
}

parse_v6 :: proc(s: string, out: ^[16]u8) -> bool {
	for i := 0; i < 16; i += 1 {
		out[i] = 0
	}
	head: [16]u8
	tail: [16]u8
	head_len := 0
	tail_len := 0
	in_tail := false
	saw_compression := false
	gs := 0
	ge := 0
	has_group := false
	ok := true

	i := 0
	for i < len(s) && ok {
		c := s[i]
		if c == ':' {
			if i + 1 < len(s) && s[i + 1] == ':' {
				if saw_compression {
					return false
				}
				if has_group {
					if in_tail {
						if !flush_v6_group(s[gs:ge], &tail, &tail_len) {
							return false
						}
					} else if !flush_v6_group(s[gs:ge], &head, &head_len) {
						return false
					}
					has_group = false
				}
				saw_compression = true
				in_tail = true
				i += 2
				continue
			}
			if has_group {
				if in_tail {
					if !flush_v6_group(s[gs:i], &tail, &tail_len) {
						return false
					}
				} else if !flush_v6_group(s[gs:i], &head, &head_len) {
					return false
				}
				has_group = false
			} else if i != 0 && i != len(s) - 1 {
				return false // stray colon
			}
			i += 1
			continue
		}
		if !has_group {
			gs = i
			has_group = true
		}
		ge = i + 1
		i += 1
	}
	if has_group {
		if in_tail {
			if !flush_v6_group(s[gs:ge], &tail, &tail_len) {
				return false
			}
		} else if !flush_v6_group(s[gs:ge], &head, &head_len) {
			return false
		}
	}
	if !saw_compression {
		return head_len == 16
	}
	if head_len + tail_len > 14 {
		return false
	}
	for j := 0; j < head_len; j += 1 {
		out[j] = head[j]
	}
	for j := 0; j < tail_len; j += 1 {
		out[16 - tail_len + j] = tail[j]
	}
	return true
}

// whitelisted reports whether the address matches an exact entry or a
// CIDR prefix.
whitelisted :: proc(w: ^Private_Whitelist, addr: IP_Addr) -> bool {
	if w == nil {
		return false
	}
	for e in w.entries {
		if e.addr.family != addr.family {
			continue
		}
		if e.prefix < 0 {
			if addr_equal(e.addr, addr) {
				return true
			}
			continue
		}
		if prefix_match(e.addr, addr, e.prefix) {
			return true
		}
	}
	return false
}

// addr_equal compares two addresses with v4-mapped v6 forms collapsed
// first (to_v4), so the comparison length never depends on which operand
// carries which family — proxy_hop compares dialed addresses against
// configured ones and cannot assume a shared spelling. Native families
// still never equal each other.
addr_equal :: proc(x_param, y_param: IP_Addr) -> bool {
	// Parameters are immutable — collapse the copies (same idiom as
	// should_block).
	x := x_param
	y := y_param
	if collapsed, ok := to_v4(x); ok {
		x = collapsed
	}
	if collapsed, ok := to_v4(y); ok {
		y = collapsed
	}
	if x.family != y.family {
		return false
	}
	n := 4
	if x.family == .V6 {
		n = 16
	}
	for i := 0; i < n; i += 1 {
		if x.bytes[i] != y.bytes[i] {
			return false
		}
	}
	return true
}

prefix_match :: proc(net, addr: IP_Addr, bits: int) -> bool {
	byte_i := 0
	remaining := bits
	for remaining >= 8 {
		if net.bytes[byte_i] != addr.bytes[byte_i] {
			return false
		}
		byte_i += 1
		remaining -= 8
	}
	if remaining > 0 {
		// Keep the top `remaining` bits: the mask is 0xFF shifted LEFT by the
		// number of trailing host bits. The earlier two-step form (shift
		// right by the complement, then left) produced subset masks for
		// remainders 5..7, letting differing addresses pass the whitelist.
		mask := u8(0xFF << u8(8 - remaining))
		if net.bytes[byte_i] & mask != addr.bytes[byte_i] & mask {
			return false
		}
	}
	return true
}

// to_v4 collapses an IPv4-mapped IPv6 address (80 zero bits, then ffff,
// then the v4 bytes) to its V4 form. The reference's net.IP.To4 does this
// at every decision point, so a ::ffff:<v4> spelling is judged by the v4
// range table — both for blocking and for whitelist matching.
to_v4 :: proc(addr: IP_Addr) -> (IP_Addr, bool) {
	if addr.family != .V6 {
		return addr, addr.family == .V4
	}
	b := addr.bytes
	mapped := b[10] == 0xFF && b[11] == 0xFF
	for i := 0; i < 10 && mapped; i += 1 {
		if b[i] != 0 {
			mapped = false
		}
	}
	if !mapped {
		return addr, false
	}
	out := IP_Addr{family = .V4}
	for i := 0; i < 4; i += 1 {
		out.bytes[i] = b[12 + i]
	}
	return out, true
}

// should_block reports whether the address is private/restricted and not
// whitelisted — the dial-time decision. The address is collapsed to v4
// first so mapped spellings meet the same table and whitelist entries
// (also stored collapsed) as their plain v4 forms.
should_block :: proc(addr_param: IP_Addr, w: ^Private_Whitelist) -> bool {
	addr := addr_param // parameters are immutable; collapse the copy
	if collapsed, ok := to_v4(addr); ok {
		addr = collapsed
	}
	return is_private_or_restricted(addr) && !whitelisted(w, addr) // whitelisted(nil) is false
}

// is_private_or_restricted decides reachability by range: loopback,
// link-local, multicast, unspecified, RFC1918, CGNAT, reserved, and the
// v6 translation ranges (NAT64, ULA, 6to4, Teredo).
is_private_or_restricted :: proc(addr: IP_Addr) -> bool {
	#partial switch addr.family {
	case .V4:
		b := addr.bytes
		if b[0] == 10 || b[0] == 127 || b[0] == 0 {
			return true
		}
		if b[0] == 172 && b[1] >= 16 && b[1] <= 31 {
			return true
		}
		if b[0] == 192 && b[1] == 168 {
			return true
		}
		if b[0] == 169 && b[1] == 254 {
			return true
		}
		if b[0] == 100 && b[1] >= 64 && b[1] <= 127 {
			return true
		}
		if b[0] >= 224 {
			return true // multicast (224-239) and reserved (240-255)
		}
		return false
	case .V6:
		// IPv4-mapped addresses collapse to their embedded v4 form —
		// the v4 range table judges them.
		if collapsed, ok := to_v4(addr); ok {
			return is_private_or_restricted(collapsed)
		}
		b := addr.bytes
		all_zero := true
		for i := 0; i < 16; i += 1 {
			if b[i] != 0 {
				all_zero = false
				break
			}
		}
		if all_zero {
			return true // unspecified
		}
		loopback := b[15] == 1
		for i := 0; i < 15 && loopback; i += 1 {
			if b[i] != 0 {
				loopback = false
			}
		}
		if loopback {
			return true // ::1 loopback
		}
		if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 {
			return true // fe80::/10 link-local
		}
		if b[0] == 0xFF {
			return true // ff00::/8 multicast
		}
		if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xFF && b[3] == 0x9B {
			// NAT64: the embedded v4 address decides.
			embedded := IP_Addr{family = .V4}
			embedded.bytes[0] = b[12]
			embedded.bytes[1] = b[13]
			embedded.bytes[2] = b[14]
			embedded.bytes[3] = b[15]
			return is_private_or_restricted(embedded)
		}
		if (b[0] & 0xFE) == 0xFC {
			return true // fc00::/7 ULA
		}
		if b[0] == 0x20 && b[1] == 0x02 {
			// 6to4: the embedded v4 address decides.
			embedded := IP_Addr{family = .V4}
			embedded.bytes[0] = b[2]
			embedded.bytes[1] = b[3]
			embedded.bytes[2] = b[4]
			embedded.bytes[3] = b[5]
			return is_private_or_restricted(embedded)
		}
		if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00 {
			// Teredo: the obfuscated client IPv4 (XOR ff) decides.
			embedded := IP_Addr{family = .V4}
			embedded.bytes[0] = b[12] ~ 0xFF
			embedded.bytes[1] = b[13] ~ 0xFF
			embedded.bytes[2] = b[14] ~ 0xFF
			embedded.bytes[3] = b[15] ~ 0xFF
			return is_private_or_restricted(embedded)
		}
		return false
	case:
		return true
	}
}

// obvious_private_host reports hostnames that point at private or local
// network addresses without any DNS lookup ("localhost" and literal IPs).
obvious_private_host :: proc(host: string, w: ^Private_Whitelist, allow_private: bool) -> bool {
	if allow_private {
		return false
	}
	h := strings.to_lower(strings.trim_space(host), context.temp_allocator)
	h = strings.trim_suffix(h, ".")
	if h == "" {
		return true
	}
	if h == "localhost" || strings.has_suffix(h, ".localhost") {
		return true
	}
	if addr, ok := parse_ip(h); ok {
		return should_block(addr, w)
	}
	return false
}
