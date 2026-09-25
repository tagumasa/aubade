// urlguard: blocks dangerous URLs — cloud metadata endpoints and known
// exfiltration services. The hostname is extracted and canonicalised
// (single-integer/hex/octal IPv4, mixed-notation dotted forms, IPv4-mapped
// IPv6) so blocked-IP lookups cannot be bypassed by alternate encodings,
// and the link-local unicast/multicast ranges are blocked entirely because
// the major cloud metadata services live in 169.254.0.0/16.
package safety

import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "src:platform"
import "src:util"
import "src:regex"

URL_Guard :: struct {
	mu:             sync.Mutex,
	host_patterns:  [dynamic]Blocked_Pattern, // matched against canonicalised hostname
	url_patterns:   [dynamic]Blocked_Pattern, // matched against the raw URL string
	blocked_ips:    map[string]string,        // dotted IPv4 → reason
	vendor_re:      regex.Regex,              // combined vendor token prefixes
	is_vendor_ready: bool,
	allocator:      mem.Allocator,
}

urlguard_init :: proc(ug: ^URL_Guard, a := context.allocator) {
	ug.host_patterns = make([dynamic]Blocked_Pattern, 0, 8, a)
	ug.url_patterns = make([dynamic]Blocked_Pattern, 0, 2, a)
	ug.blocked_ips = make(map[string]string, 4, a)
	ug.allocator = a
	urlguard_load_defaults(ug)
}

urlguard_destroy :: proc(ug: ^URL_Guard) {
	for i in 0..<len(ug.host_patterns) {
		re := ug.host_patterns[i].re
		regex.regex_destroy(&re)
	}
	for i in 0..<len(ug.url_patterns) {
		re := ug.url_patterns[i].re
		regex.regex_destroy(&re)
		// url_patterns carries cloned strings (defaults and user patterns
		// alike); the host table's constant-backed strings stay undeleted.
		delete(ug.url_patterns[i].pattern, ug.allocator)
		delete(ug.url_patterns[i].reason, ug.allocator)
	}
	if ug.is_vendor_ready {
		regex.regex_destroy(&ug.vendor_re)
	}
	delete(ug.host_patterns)
	delete(ug.url_patterns)
	delete(ug.blocked_ips)
	ug.host_patterns = nil
	ug.url_patterns = nil
	ug.blocked_ips = nil
	ug.is_vendor_ready = false
}

// urlguard_is_blocked reports whether the URL matches a blocked pattern:
// URL-level patterns against the raw string first, then the canonicalised
// host against the blocked IPs, link-local ranges, and host patterns. The
// whole check holds the mutex — the tables and each pattern's PCRE2
// match_data serve one thread at a time.
urlguard_is_blocked :: proc(ug: ^URL_Guard, raw_url: string) -> (bool, string) {
	sync.mutex_lock(&ug.mu)
	defer sync.mutex_unlock(&ug.mu)
	for i in 0..<len(ug.url_patterns) {
		re := ug.url_patterns[i].re
		if regex.regex_match(&re, raw_url) {
			return true, ug.url_patterns[i].reason
		}
	}

	host, has_host := url_hostname(raw_url)
	if !has_host || host == "" {
		return false, ""
	}

	canon := canonicalize_host(host)
	if addr, ok := parse_host_addr(canon); ok {
		if addr.is_v4 {
			key := v4_to_string(addr.b4, context.temp_allocator)
			if reason, found := ug.blocked_ips[key]; found {
				return true, reason
			}
		}
		if host_addr_is_link_local(addr) {
			return true, "link-local address (potential cloud metadata endpoint)"
		}
	} else if host_is_address_like(canon) {
		// Address-only syntax both parsers reject — a trailing dot (the
		// resolver-absolute spelling numeric resolvers still accept) or a
		// %zone scope. Refusing here is fail-closed: these shapes would
		// otherwise skip the blocked-IP and link-local tables above.
		return true, "address-like host the guard cannot parse (trailing dot or zone id)"
	}

	for i in 0..<len(ug.host_patterns) {
		re := ug.host_patterns[i].re
		if regex.regex_match(&re, canon) {
			return true, ug.host_patterns[i].reason
		}
	}
	return false, ""
}

// urlguard_validate_url parses and validates a URL: deterministic feedback
// for malformed URLs and missing hosts, then the block check. Error
// strings keep a stable shape (user-visible tool surface).
urlguard_validate_url :: proc(ug: ^URL_Guard, raw_url: string, a := context.temp_allocator) -> (ok: bool, err_msg: string) {
	if url_has_control_char(raw_url) {
		return false, strings.concatenate({
			"urlguard: malformed URL ", url_quote(raw_url, a),
			": net/url: invalid control character in URL",
		}, a)
	}
	scheme, has_scheme := url_scheme(raw_url)
	_, has_host := url_hostname(raw_url)
	if (!has_scheme || !strings.equal_fold(scheme, "data")) && !has_host {
		return false, strings.concatenate({
			"urlguard: URL ", url_quote(raw_url, a), " has no host component",
		}, a)
	}
	if blocked, reason := urlguard_is_blocked(ug, raw_url); blocked {
		return false, strings.concatenate({"safety: URL blocked: ", reason}, a)
	}
	return true, ""
}

// urlguard_add_blocked_pattern appends a user pattern; user patterns are
// matched against the full raw URL string (regex-on-URL semantics). The
// pattern and reason are cloned into the guard's allocator — callers hand
// in config-stack or arena views whose backing dies with their scope.
urlguard_add_blocked_pattern :: proc(ug: ^URL_Guard, pattern: string, reason: string) -> (bool, string) {
	re, err := regex.compile_regex(pattern, ug.allocator)
	if err != nil {
		return false, strings.concatenate({
			"invalid blocked-URL pattern ", url_quote(pattern, context.temp_allocator),
			": ", platform.err_message(err, context.temp_allocator),
		}, context.temp_allocator)
	}
	sync.mutex_lock(&ug.mu)
	defer sync.mutex_unlock(&ug.mu)
	append(&ug.url_patterns, Blocked_Pattern{
		pattern = strings.clone(pattern, ug.allocator),
		re      = re,
		reason  = strings.clone(reason, ug.allocator),
	})
	return true, ""
}

// urlguard_check_for_secrets reports whether the URL embeds an API key or
// token, checking both the raw and the query-unescaped forms.
urlguard_check_for_secrets :: proc(ug: ^URL_Guard, raw_url: string) -> (bool, string) {
	sync.mutex_lock(&ug.mu)
	defer sync.mutex_unlock(&ug.mu)
	if !ug.is_vendor_ready {
		return false, ""
	}
	if regex.regex_match(&ug.vendor_re, raw_url) {
		return true, "blocked: URL contains what appears to be an API key or token"
	}
	decoded := util.percent_decode(raw_url, context.temp_allocator, plus_to_space = true, malformed = .Return_Input)
	if regex.regex_match(&ug.vendor_re, decoded) {
		return true, "blocked: URL contains what appears to be an API key or token"
	}
	return false, ""
}

// urlguard_load_defaults populates the default tables. Runs from
// urlguard_init before the guard is published to other threads — no lock.
urlguard_load_defaults :: proc(ug: ^URL_Guard) {
	for d in URLGUARD_IP_DEFAULTS {
		ug.blocked_ips[d.pattern] = d.reason
	}
	for d in URLGUARD_HOST_DEFAULTS {
		compile_default_pattern(&ug.host_patterns, d.pattern, d.reason, "urlguard: default host pattern", false, ug.allocator)
	}
	for d in URLGUARD_URL_DEFAULTS {
		compile_default_pattern(&ug.url_patterns, d.pattern, d.reason, "urlguard: default URL pattern", true, ug.allocator)
	}

	joined, _ := strings.join(VENDOR_PREFIX_PATTERNS, "|", context.temp_allocator)
	combined := strings.concatenate({"(", joined, ")"}, context.temp_allocator)
	re, verr := regex.compile_regex(combined, ug.allocator)
	if verr != nil {
		util.log_warning(strings.concatenate({
			"urlguard: vendor token pattern failed to compile; URL secret checks are INACTIVE: ",
			platform.err_message(verr, context.temp_allocator),
		}, context.temp_allocator))
		return
	}
	ug.vendor_re = re
	ug.is_vendor_ready = true
}

// Default tables: one row per rule, pattern and reason in the same
// declaration — an index-coupled pair of slices cannot keep the two sides
// aligned under edit.
URLGUARD_IP_DEFAULTS :: []Guard_Default{
	{pattern = "169.254.169.254",  reason = "cloud instance metadata endpoint (AWS/GCP/Azure)"},
	{pattern = "169.254.170.2",   reason = "AWS ECS task metadata endpoint"},
	{pattern = "100.100.100.200", reason = "Alibaba Cloud metadata endpoint"},
}

URLGUARD_HOST_DEFAULTS :: []Guard_Default{
	{pattern = `(?i)^metadata\.google\.internal$`, reason = "Google Cloud metadata hostname"},
	{pattern = `(?i)^metadata\.goog$`,             reason = "Google Cloud metadata hostname"},
	{pattern = `(?i)(^|\.)webhook\.site$`,         reason = "known data exfiltration service"},
	{pattern = `(?i)(^|\.)requestbin\.com$`,       reason = "known data exfiltration service"},
	{pattern = `(?i)(^|\.)pipedream\.net$`,        reason = "known data exfiltration service"},
	{pattern = `(?i)(^|\.)hookbin\.com$`,          reason = "known data exfiltration service"},
	{pattern = `(?i)(^|\.)pastebin\.com$`,         reason = "known paste service (potential data staging)"},
	{pattern = `(?i)(^|\.)hastebin\.com$`,         reason = "known paste service (potential data staging)"},
}

URLGUARD_URL_DEFAULTS :: []Guard_Default{
	{pattern = `(?i)^data:.*;base64,`, reason = "data URL with base64 encoding (potential exfiltration)"},
}

// ---------------------------------------------------------------------------
// URL splitting (the slice net/url needs for authority extraction)
// ---------------------------------------------------------------------------

// url_scheme returns the scheme as a view into the input (no allocation —
// the scheme is ASCII by construction, and callers compare fold-wise
// because schemes are case-insensitive); "" with has_scheme=false for
// scheme-less URLs. Opaque schemes (data:, mailto:) carry no authority.
url_scheme :: proc(raw_url: string) -> (scheme: string, has_scheme: bool) {
	s := raw_url
	if len(s) == 0 || !is_ascii_alpha(s[0]) {
		return "", false
	}
	i := 0
	for i < len(s) && (is_ascii_alnum(s[i]) || s[i] == '+' || s[i] == '-' || s[i] == '.') {
		i += 1
	}
	if i == 0 || i >= len(s) || s[i] != ':' {
		return "", false
	}
	return s[:i], true
}

// url_hostname extracts the host component (port and userinfo stripped,
// IPv6 brackets removed); has_host is false when no authority is present.
// Malformed inputs simply report no host — callers treat them as
// unblockable.
url_hostname :: proc(raw_url: string) -> (host: string, has_host: bool) {
	s := raw_url
	scheme, has_scheme := url_scheme(s)
	if has_scheme {
		s = s[len(scheme):] // scheme delimiters are ASCII; the prefix is ASCII by construction
		s = s[1:]           // ':'
		if !strings.has_prefix(s, "//") {
			return "", false // opaque (data:, mailto:) or malformed
		}
		s = s[2:]
	} else if !strings.has_prefix(s, "//") {
		return "", false // relative reference
	}
	return authority_host(s)
}

authority_host :: proc(authority: string) -> (host: string, has_host: bool) {
	end := len(authority)
	for c, i in authority {
		if c == '/' || c == '?' || c == '#' {
			end = i
			break
		}
	}
	auth := authority[:end]

	// userinfo is everything before the last '@' (hosts cannot contain it)
	at := -1
	for i := len(auth) - 1; i >= 0; i -= 1 {
		if auth[i] == '@' {
			at = i
			break
		}
	}
	if at >= 0 {
		auth = auth[at+1:]
	}
	if len(auth) == 0 {
		return "", false
	}
	if auth[0] == '[' {
		close := strings.index_byte(auth, ']')
		if close < 0 {
			return "", false
		}
		host = auth[1:close]
		return host, host != ""
	}
	colon := strings.index_byte(auth, ':')
	if colon >= 0 {
		auth = auth[:colon]
	}
	return auth, auth != ""
}

url_has_control_char :: proc(s: string) -> bool {
	for c in s {
		if c < 0x20 || c == 0x7F {
			return true
		}
	}
	return false
}

url_quote :: proc(s: string, a := context.allocator) -> string {
	buf := make([dynamic]u8, 0, len(s) + 2, a)
	append(&buf, '"')
	for i in 0..<len(s) {
		c := s[i]
		switch c {
		case '"':
			append(&buf, "\\\"")
		case '\\':
			append(&buf, "\\\\")
		case '\n':
			append(&buf, "\\n")
		case '\r':
			append(&buf, "\\r")
		case '\t':
			append(&buf, "\\t")
		case:
			if c < 0x20 || c == 0x7F {
				hex_digits := URLGUARD_HEX
				append(&buf, "\\x")
				append(&buf, hex_digits[(c >> 4) & 0xF])
				append(&buf, hex_digits[c & 0xF])
			} else {
				append(&buf, c)
			}
		}
	}
	append(&buf, '"')
	return string(buf[:])
}

URLGUARD_HEX :: "0123456789abcdef"

is_ascii_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

is_ascii_alnum :: proc(c: u8) -> bool {
	return is_ascii_alpha(c) || (c >= '0' && c <= '9')
}

// ---------------------------------------------------------------------------
// Host canonicalisation
// ---------------------------------------------------------------------------

Host_Addr :: struct {
	bytes: [16]u8, // wire (big-endian) order
	is_v4: bool,
	b4:    [4]u8,  // valid when is_v4 (also carries IPv4-mapped IPv6)
}

// parse_host_addr recognizes the strict address forms net.ParseIP accepts:
// all IPv6 spellings (with IPv4-mapped collapsing to v4) and plain decimal
// dotted-quad IPv4. Lenient encodings are canonicalised separately below.
parse_host_addr :: proc(host: string) -> (addr: Host_Addr, ok: bool) {
	if addr6, ok6 := net.parse_ip6_address(host); ok6 {
		pieces := cast([8]u16be)addr6
		for i in 0..<8 {
			v := u16(pieces[i])
			addr.bytes[i*2] = u8(v >> 8)
			addr.bytes[i*2+1] = u8(v)
		}
		mapped := true
		for i in 0..<10 {
			if addr.bytes[i] != 0 {
				mapped = false
			}
		}
		if mapped && addr.bytes[10] == 0xFF && addr.bytes[11] == 0xFF {
			addr.is_v4 = true
			for i in 0..<4 {
				addr.b4[i] = addr.bytes[12+i]
			}
		}
		return addr, true
	}
	if b4, ok4 := parse_ipv4_dotted(host); ok4 {
		addr.is_v4 = true
		addr.b4 = b4
		return addr, true
	}
	return {}, false
}

// canonicalize_host converts alternate numeric IP representations to their
// canonical dotted form so blocked lookups cannot be bypassed by encoding.
// Non-IP hostnames pass through unchanged.
canonicalize_host :: proc(host: string) -> string {
	if addr, ok := parse_host_addr(host); ok {
		if addr.is_v4 {
			return v4_to_string(addr.b4, context.temp_allocator)
		}
		return host
	}
	if canon := canonicalize_integer_ip(host); canon != "" {
		return canon
	}
	if canon := canonicalize_dotted_ip(host); canon != "" {
		return canon
	}
	return host
}

// host_is_address_like reports hosts carrying address-only syntax that
// both address parsers still reject: a trailing dot (the FQDN-absolute
// spelling getaddrinfo/Winsock accept for numeric literals) or a %zone
// scope (link-local interface routing). The guard refuses these instead
// of letting them fall past the blocked-IP tables.
host_is_address_like :: proc(host: string) -> bool {
	if strings.contains(host, "%") {
		return true
	}
	return strings.has_suffix(host, ".")
}

// parse_ipv4_dotted accepts only four decimal components without leading
// zeros (the strict dotted-quad grammar).
parse_ipv4_dotted :: proc(host: string) -> (addr: [4]u8, ok: bool) {
	start := 0
	part := 0
	for i := 0; i <= len(host); i += 1 {
		if i == len(host) || host[i] == '.' {
			if part >= 4 {
				return {}, false
			}
			seg := host[start:i]
			if !valid_decimal_component(seg) {
				return {}, false
			}
			addr[part] = parse_small_decimal(seg)
			part += 1
			start = i + 1
		}
	}
	return addr, part == 4
}

valid_decimal_component :: proc(seg: string) -> bool {
	if len(seg) == 0 || len(seg) > 3 {
		return false
	}
	if len(seg) > 1 && seg[0] == '0' {
		return false
	}
	v := 0
	for c in seg {
		if c < '0' || c > '9' {
			return false
		}
		v = v * 10 + int(c - '0')
	}
	// The byte range is part of the dotted-quad grammar: a component over
	// 255 would wrap through u8 at the parse site and stand in for a
	// different address (425 reads back as 169 — link-local).
	return v <= 255
}

parse_small_decimal :: proc(seg: string) -> u8 {
	v := 0
	for c in seg {
		v = v*10 + int(c - '0')
	}
	return u8(v)
}

// canonicalize_integer_ip resolves the single-integer IPv4 encodings:
// hexadecimal (0xa9fea9fe), octal (leading zero), and plain decimal.
canonicalize_integer_ip :: proc(host: string) -> string {
	n: u64
	ok := false
	if len(host) > 2 && (host[:2] == "0x" || host[:2] == "0X") {
		n, ok = parse_uint_base(host[2:], 16)
	} else if len(host) > 1 && host[0] == '0' && all_octal_digits(host) {
		n, ok = parse_uint_base(host, 8)
	} else if all_decimal_digits(host) {
		n, ok = parse_uint_base(host, 10)
	} else {
		return ""
	}
	if !ok || n > 0xFFFFFFFF {
		return ""
	}
	b := [4]u8{u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)}
	return v4_to_string(b, context.temp_allocator)
}

// canonicalize_dotted_ip resolves four-component forms where individual
// components may use hex (0xA9) or octal (0251) notation.
canonicalize_dotted_ip :: proc(host: string) -> string {
	parts: [4]string
	start := 0
	part := 0
	for i := 0; i <= len(host); i += 1 {
		if i == len(host) || host[i] == '.' {
			if part >= 4 {
				return ""
			}
			parts[part] = host[start:i]
			part += 1
			start = i + 1
		}
	}
	if part != 4 {
		return ""
	}
	b: [4]u8
	for i in 0..<4 {
		val, ok := parse_ip_component(parts[i])
		if !ok || val > 255 {
			return ""
		}
		b[i] = u8(val)
	}
	return v4_to_string(b, context.temp_allocator)
}

parse_ip_component :: proc(s: string) -> (u64, bool) {
	if len(s) > 2 && (s[:2] == "0x" || s[:2] == "0X") {
		return parse_uint_base(s[2:], 16)
	}
	if len(s) > 1 && s[0] == '0' && all_octal_digits(s) {
		return parse_uint_base(s, 8)
	}
	if all_decimal_digits(s) {
		return parse_uint_base(s, 10)
	}
	return 0, false
}

parse_uint_base :: proc(s: string, base: u64) -> (u64, bool) {
	if len(s) == 0 {
		return 0, false
	}
	n: u64 = 0
	max := u64(0xFFFFFFFFFFFFFFFF)
	for c in s {
		d: u64
		switch {
		case c >= '0' && c <= '9':
			d = u64(c - '0')
		case c >= 'a' && c <= 'f':
			d = u64(c - 'a') + 10
		case c >= 'A' && c <= 'F':
			d = u64(c - 'A') + 10
		case:
			return 0, false
		}
		if d >= base {
			return 0, false
		}
		if n > (max - d) / base {
			return 0, false
		}
		n = n*base + d
	}
	return n, true
}

all_decimal_digits :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for c in s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

all_octal_digits :: proc(s: string) -> bool {
	if len(s) < 2 || s[0] != '0' {
		return false
	}
	for c in s {
		if c < '0' || c > '7' {
			return false
		}
	}
	return true
}

host_addr_is_link_local :: proc(addr: Host_Addr) -> bool {
	if addr.is_v4 {
		b := addr.b4
		return (b[0] == 169 && b[1] == 254) ||
			(b[0] == 224 && b[1] == 0 && b[2] == 0)
	}
	b := addr.bytes
	return (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) ||
		(b[0] == 0xFF && (b[1] & 0x0F) == 0x02)
}

v4_to_string :: proc(b: [4]u8, a := context.allocator) -> string {
	return strings.concatenate({
		u8_dec(b[0], a), ".", u8_dec(b[1], a), ".", u8_dec(b[2], a), ".", u8_dec(b[3], a),
	}, a)
}

u8_dec :: proc(v: u8, a := context.allocator) -> string {
	digits := URLGUARD_HEX
	buf := make([dynamic]u8, 0, 3, a)
	if v >= 100 {
		append(&buf, digits[v / 100])
	}
	if v >= 10 {
		append(&buf, digits[(v / 10) % 10])
	}
	append(&buf, digits[v % 10])
	return string(buf[:])
}

// ---------------------------------------------------------------------------
// Percent decoding
// ---------------------------------------------------------------------------
// The decoder itself lives in util (percent_decode): this package reads
// URLs with the query policy — '+' becomes a space, and one malformed
// escape returns the whole input unchanged rather than a partial decode.
