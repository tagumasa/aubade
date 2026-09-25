// The HTTP transport over vendor:curl: one easy handle per request, a
// bounded body capture, and the SSRF open-socket guard that refuses
// private or restricted destinations at connect time (redirects included
// — the guard sees every address curl dials). The guard replaces curl's
// socket creation, so it owns creating allowed sockets too.
package web

import curl "vendor:curl"
import c "core:c/libc"
import "base:runtime"
import "core:strings"
import "core:sync"

import "src:platform"
import "src:safety"
import "src:util"

HTTP_FETCH_TIMEOUT_MS :: 60_000
HTTP_CONNECT_TIMEOUT_MS :: 15_000
MAX_REDIRECTS :: 5
// The response-sink floor for requests that carry no explicit byte cap
// (fetch and search each own their own named limit; this bounds the rest).
HTTP_SINK_DEFAULT_CAP_BYTES :: 10 * 1024 * 1024

// Address-family numbers as each platform's C library spells them: the
// socket-open callback and the resolver paths compare them as raw ints,
// and AF_INET6 differs per OS (Linux 10, Windows 23, darwin 30 — the
// per-OS value lives in http_linux/http_darwin/http_windows.odin). AF_INET
// is 2 everywhere. Shared code MUST branch on these, never on the Linux
// literals — a hardcoded 10 refuses every IPv6 dial on Windows and darwin.
AF_INET_VAL :: 2

USER_AGENT_DEFAULT :: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

HTTP_Header :: struct {
	name:  string,
	value: string,
}

HTTP_Request :: struct {
	method:     string, // "GET" or "POST"; "" = GET
	url:        string,
	body:       []u8, // POST payload
	headers:    []HTTP_Header,
	user_agent: string,
	timeout_ms: i64,
	proxy:      string, // http/https/socks5/socks5h URL (validated)
	max_bytes:  int, // response body cap; <= 0 = 10 MiB
	// Per-redirect re-verification: redirects are followed manually (never
	// by libcurl), and every hop's target passes this gate first — "" lets
	// the hop through, anything else aborts the transfer with that prose.
	// nil disables the gate (the open-socket guard still sees every dial).
	redirect_check:      proc(data: rawptr, url: string, a: runtime.Allocator) -> string,
	redirect_check_data: rawptr,
	// Origin pinning for credentialed callers: when set, every redirect hop
	// must keep the ORIGINAL URL's scheme and host (case-insensitive; the
	// port is not pinned) or the transfer aborts with .Denied. Headers and
	// a POST body stay attached to the handle across hops, so without this
	// a 302 can forward API keys to any public host the dial guard happily
	// connects to.
	pin_origin: bool,
	// Optional cancel token: an xferinfo callback polls it during the
	// transfer and aborts (CURLE_ABORTED_BY_CALLBACK → .Cancelled) the
	// moment it fires — curl's own timeout stops being the only stop path.
	token: ^platform.Cancel_Token,
}

HTTP_Response :: struct {
	status:       int,
	content_type: string, // owned by the response allocator
	body:         []u8, // owned by the response allocator
	// True when the final response carried `Cf-Mitigated: challenge` —
	// the Cloudflare signal the fetch layer retries under an honest UA.
	cf_challenge: bool,
}

// HTTP_Client is the process-global curl initializer owner: curl_global_init
// must run before any easy handle and is not thread-safe around calls, so
// the client serializes init and every request runs on its own handle.
HTTP_Client :: struct {
	mu:            sync.Mutex,
	is_initialized: bool,
}

http_client_init :: proc(c: ^HTTP_Client) {
	c^ = {}
}

http_client_destroy :: proc(c: ^HTTP_Client) {
	if c.is_initialized {
		curl.global_cleanup()
	}
	c^ = {}
}

// http_do performs one request. The failure vocabulary is the closed
// Web_Err set with caller-facing prose; the response memory is allocated
// from `a`.
http_do :: proc(
	client: ^HTTP_Client,
	req: HTTP_Request,
	guard: ^Socket_Guard,
	a := context.allocator,
) -> (HTTP_Response, Web_Err, string) {
	res: HTTP_Response

	sync.mutex_lock(&client.mu)
	if !client.is_initialized {
		if code := curl.global_init(c.long(0)); code != .E_OK {
			sync.mutex_unlock(&client.mu)
			return res, .Internal, strings.concatenate({
				"curl global init failed: ", cstring_to_string(curl.easy_strerror(code)),
			}, a)
		}
		client.is_initialized = true
	}
	sync.mutex_unlock(&client.mu)

	if err := validate_proxy(req.proxy, a); err != "" {
		return res, .Invalid_Url, err
	}

	// The refusal flag is per transfer and lives per transfer: the guard
	// struct itself is shared by every concurrent http_do on the client,
	// so a shared flag would race (one transfer's block misattributed to
	// another, or reset mid-flight). The view below is stack-local to
	// this call and only touched while easy_perform runs inside it.
	tg := Transfer_Guard{guard = guard}

	handle := curl.easy_init()
	if handle == nil {
		return res, .Internal, "curl init failed"
	}
	defer curl.easy_cleanup(handle)

	protocols_c := strings.clone_to_cstring("http,https", a)
	empty_c := strings.clone_to_cstring("", a)
	// Redirects are followed manually (never by libcurl): every hop's
	// target passes redirect_check first, so URL policy (deny patterns,
	// secrets, private hosts) applies mid-chain and not only to the
	// initial URL. The scheme allowlist covers the hop targets the same
	// way; the open-socket guard remains the connect-time backstop.
	curl.easy_setopt(handle, .PROTOCOLS_STR, protocols_c)
	curl.easy_setopt(handle, .REDIR_PROTOCOLS_STR, protocols_c)
	// NOPROGRESS would silence the xferinfo callback: with a token the
	// callback IS the progress handler (it aborts the transfer on a fired
	// token); without one progress stays off as before.
	if req.token != nil {
		curl.easy_setopt(handle, .XFERINFOFUNCTION, http_progress_callback)
		curl.easy_setopt(handle, .XFERINFODATA, req.token)
	} else {
		curl.easy_setopt(handle, .NOPROGRESS, c.long(1))
	}
	curl.easy_setopt(handle, .ACCEPT_ENCODING, empty_c) // send Accept-Encoding, let curl decode
	curl.easy_setopt(handle, .TIMEOUT_MS, c.long(req.timeout_ms > 0 ? req.timeout_ms : HTTP_FETCH_TIMEOUT_MS))
	curl.easy_setopt(handle, .CONNECTTIMEOUT_MS, c.long(HTTP_CONNECT_TIMEOUT_MS))

	ua := req.user_agent
	if ua == "" {
		ua = USER_AGENT_DEFAULT
	}
	ua_c := strings.clone_to_cstring(ua, a)
	curl.easy_setopt(handle, .USERAGENT, ua_c)

	if req.proxy != "" {
		proxy_c := strings.clone_to_cstring(req.proxy, a)
		curl.easy_setopt(handle, .PROXY, proxy_c)
	}

	list: ^curl.slist = nil
	defer {
		if list != nil {
			curl.slist_free_all(list)
		}
	}
	for h in req.headers {
		line := strings.concatenate({h.name, ": ", h.value}, a)
		line_c := strings.clone_to_cstring(line, a)
		list = curl.slist_append(list, line_c)
	}
	if list != nil {
		curl.easy_setopt(handle, .HTTPHEADER, list)
	}

	sink := HTTP_Sink{cap_bytes = req.max_bytes}
	if sink.cap_bytes <= 0 {
		// The unnamed default callers ride when the request carries no
		// explicit cap — fetch and search each own a named limit constant
		// for their own paths; this one is the transport floor.
		sink.cap_bytes = HTTP_SINK_DEFAULT_CAP_BYTES
	}
	// Pre-made on `a`: a zero-value dynamic would grow through the C
	// callback's default context instead of the request allocator.
	sink.buf = make([dynamic]u8, 0, 4096, a)
	// Registered before the redirect loop: every error return inside it
	// (too large, guard refusal, transport failure, redirect cap) must
	// free the buffer too, not just the loop's tail exits.
	defer delete(sink.buf)
	curl.easy_setopt(handle, .WRITEFUNCTION, http_write_callback)
	curl.easy_setopt(handle, .WRITEDATA, &sink)

	header_sink: HTTP_Header_Sink
	curl.easy_setopt(handle, .HEADERFUNCTION, http_header_callback)
	curl.easy_setopt(handle, .HEADERDATA, &header_sink)

	if guard != nil {
		curl.easy_setopt(handle, .OPENSOCKETFUNCTION, http_open_socket)
		curl.easy_setopt(handle, .OPENSOCKETDATA, &tg)
	}

	// The manual redirect loop. CURLINFO_REDIRECT_URL carries the
	// resolved target (relative Locations included) even though
	// FOLLOWLOCATION is off. Method downgrades mirror libcurl's default
	// POSTREDIR behavior: 303 always switches to GET, 301/302 switch a
	// POST to GET, 307/308 replay the method and body verbatim.
	url := req.url
	is_post := req.method == "POST"
	// The POST body is cloned ONCE: a 307/308 chain re-sends it on every
	// hop, and a per-hop clone would pile up to MAX_REDIRECTS+1 copies of a
	// possibly multi-megabyte payload on the request arena. After a method
	// downgrade the HTTPGET branch in the loop overrides the method and
	// curl ignores the stale POSTFIELDS.
	if is_post {
		curl.easy_setopt(handle, .POSTFIELDS, strings.clone_to_cstring(string(req.body), a))
		curl.easy_setopt(handle, .POSTFIELDSIZE, c.long(len(req.body)))
	}
	// Origin pinning (see HTTP_Request.pin_origin): captured before the
	// loop so every hop compares against the FIRST url, not the previous
	// one — a chain A→B→A stays refused when B differs from the origin.
	origin_scheme := ""
	origin_host := ""
	if req.pin_origin {
		s, h, kok := url_origin(req.url)
		if !kok {
			return res, .Invalid_Url, "origin pinning set on a URL without a parseable origin"
		}
		origin_scheme, origin_host = s, h
	}
	redirects := 0
	status := 0
	for {
		// Per-hop URL cstring: bounded by MAX_REDIRECTS on the request
		// arena (the previous hop's clone is left to the arena teardown).
		url_c := strings.clone_to_cstring(url, a)
		curl.easy_setopt(handle, .URL, url_c)
		if !is_post {
			curl.easy_setopt(handle, .HTTPGET, c.long(1))
		}
		resize(&sink.buf, 0)
		sink.overflow = false
		sink.truncated = false
		header_sink.cf_challenge = false // headers belong to the final hop

		code := curl.easy_perform(handle)
		if code != .E_OK {
			if sink.truncated {
				return res, .Too_Large, strings.concatenate({
					"failed to read response: size exceeded ", util.int_to_dec(sink.cap_bytes, a),
					" bytes limit",
				}, a)
			}
			if guard != nil && tg.refused {
				return res, .Denied, "blocked private or local target"
			}
			kind := Web_Err.Internal
			#partial switch code {
			case .E_OPERATION_TIMEDOUT:
				kind = .Timeout
			case .E_ABORTED_BY_CALLBACK:
				// The xferinfo callback aborted on a fired token (the
				// write-callback overflow aborts with sink.truncated
				// above, so a plain refusal flag it is not).
				kind = req.token != nil ? .Cancelled : .Internal
			case .E_COULDNT_RESOLVE_HOST:
				kind = .Dns
			case .E_COULDNT_CONNECT:
				kind = .Connect
			case:
			}
			return res, kind, strings.concatenate({
				"request failed: ", cstring_to_string(curl.easy_strerror(code)),
			}, a)
		}

		status_long: c.long
		curl.easy_getinfo(handle, .RESPONSE_CODE, &status_long)
		status = int(status_long)

		is_redirect := status == 300 || status == 301 || status == 302 ||
			status == 303 || status == 307 || status == 308
		if !is_redirect {
			break
		}
		redir_c: cstring
		curl.easy_getinfo(handle, .REDIRECT_URL, &redir_c)
		if redir_c == nil || len(cstring_to_string(redir_c)) == 0 {
			break // no Location to follow: the response is final
		}
		if redirects >= MAX_REDIRECTS {
			return res, .Invalid_Url, "too many redirects"
		}
		redir := strings.clone(cstring_to_string(redir_c), a)
		if req.redirect_check != nil {
			if msg := req.redirect_check(req.redirect_check_data, redir, a); msg != "" {
				return res, .Denied, msg
			}
		}
		if req.pin_origin && !origin_allows(origin_scheme, origin_host, redir) {
			return res, .Denied, strings.concatenate({
				"redirect refused: credentials never leave the origin host (",
				origin_host, ")",
			}, a)
		}
		if status == 303 || ((status == 301 || status == 302) && is_post) {
			is_post = false
		}
		url = redir
		redirects += 1
	}

	res.status = status
	res.cf_challenge = header_sink.cf_challenge

	ct: cstring
	curl.easy_getinfo(handle, .CONTENT_TYPE, &ct)
	if ct != nil {
		res.content_type = strings.clone(cstring_to_string(ct), a)
	}

	if sink.overflow {
		return res, .Too_Large, strings.concatenate({
			"failed to read response: size exceeded ", util.int_to_dec(sink.cap_bytes, a),
			" bytes limit",
		}, a)
	}
	res.body = make([]u8, len(sink.buf), a)
	for i := 0; i < len(sink.buf); i += 1 {
		res.body[i] = sink.buf[i]
	}
	return res, .None, ""
}

// http_progress_callback is the xferinfo hook that turns a fired cancel
// token into an aborted transfer (any non-zero return stops the request
// with CURLE_ABORTED_BY_CALLBACK). It only reads the token's atomic
// state — no allocation, no user context needed.
http_progress_callback :: proc "c" (
	clientp: rawptr,
	dltotal, dlnow, ultotal, ulnow: curl.off_t,
) -> c.int {
	context = runtime.default_context()
	token := cast(^platform.Cancel_Token)clientp
	if _, fired := platform.token_check(token); fired {
		return 1
	}
	return 0
}

HTTP_Sink :: struct {
	buf:       [dynamic]u8,
	cap_bytes: int,
	overflow:  bool, // more bytes arrived than the cap
	truncated: bool, // the overflow aborted the transfer
}

http_write_callback :: proc "c" (ptr: [^]byte, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
	context = runtime.default_context()
	sink := cast(^HTTP_Sink)userdata
	total := int(size * nmemb)
	if len(sink.buf) + total > sink.cap_bytes {
		sink.overflow = true
		sink.truncated = true
		return 0 // nonzero-abort: curl stops with a write error
	}
	append(&sink.buf, ..ptr[:total])
	return size * nmemb
}

// HTTP_Header_Sink accumulates the one header signal the fetch layer
// needs: Cloudflare's Cf-Mitigated marker. A bool, not a string — the
// header callback runs under the C context and must not allocate.
HTTP_Header_Sink :: struct {
	cf_challenge: bool,
}

http_header_callback :: proc "c" (ptr: [^]byte, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
	context = runtime.default_context()
	sink := cast(^HTTP_Header_Sink)userdata
	if sink == nil {
		return 0
	}
	if header_is_cf_challenge(ptr[:int(size * nmemb)]) {
		sink.cf_challenge = true
	}
	return size * nmemb
}

// header_is_cf_challenge matches "Cf-Mitigated: challenge" with an ASCII
// case fold — pure byte comparison, no allocation.
header_is_cf_challenge :: proc(line: []u8) -> bool {
	name := "cf-mitigated"
	if len(line) < len(name) + 2 {
		return false
	}
	for i in 0..<len(name) {
		b := line[i]
		if b >= 'A' && b <= 'Z' {
			b += 32
		}
		if b != name[i] {
			return false
		}
	}
	if line[len(name)] != ':' {
		return false
	}
	v := line[len(name) + 1:]
	i := 0
	for i < len(v) && (v[i] == ' ' || v[i] == '\t') {
		i += 1
	}
	val := "challenge"
	if len(v) - i < len(val) {
		return false
	}
	for j in 0..<len(val) {
		b := v[i + j]
		if b >= 'A' && b <= 'Z' {
			b += 32
		}
		if b != val[j] {
			return false
		}
	}
	return true
}

// http_open_socket is the SSRF gate: every address curl is about to
// connect to passes through here. Allowed addresses get their socket
// created; blocked ones return CURL_SOCKET_BAD, which fails the transfer
// with the blocked message above.
http_open_socket :: proc "c" (clientp: rawptr, purpose: curl.socktype, address: ^curl.sockaddr) -> curl.socket_t {
	context = runtime.default_context()
	tg := cast(^Transfer_Guard)clientp
	if tg == nil || tg.guard == nil {
		return curl.SOCKET_BAD
	}
	guard := tg.guard
	if guard.allow_all {
		return create_stream_socket(address.family, address.socktype, address.protocol)
	}
	if purpose != .IPCXN {
		return create_stream_socket(address.family, address.socktype, address.protocol)
	}
	family := int(address.family)
	if family != AF_INET_VAL && family != AF_INET6_VAL {
		return curl.SOCKET_BAD // AF_INET / AF_INET6 only
	}
	addr, ok := sock_addr_to_ip(family, address)
	if !ok {
		return curl.SOCKET_BAD
	}
	if should_block(addr, &guard.whitelist) && !proxy_hop(guard, addr) {
		tg.refused = true
		return curl.SOCKET_BAD
	}
	return create_stream_socket(address.family, address.socktype, address.protocol)
}

// Socket_Guard carries the dial policy for one HTTP_Client: the parsed
// whitelist, the allow-all switch (allow_private_hosts), and the resolved
// proxy addresses that stay reachable even when private. It holds no
// per-transfer state — concurrent transfers share the guard read-only.
Socket_Guard :: struct {
	whitelist: Private_Whitelist,
	allow_all: bool,
	proxy_hops: [dynamic]IP_Addr,
}

// Transfer_Guard is one http_do's view of the shared guard plus its own
// refusal flag. It is stack-local to the call and passed as the
// open-socket callback data: the callback only runs while easy_perform
// executes inside that frame, so the pointer stays valid and the flag
// never crosses transfers.
Transfer_Guard :: struct {
	guard:   ^Socket_Guard,
	refused: bool,
}

socket_guard_init :: proc(g: ^Socket_Guard, whitelist_entries: []string, allow_private: bool, a := context.allocator) -> (ok: bool, bad_entry: string) {
	g^ = {}
	whitelist_init(&g.whitelist, a)
	g.allow_all = allow_private
	parsed, bad := whitelist_parse(&g.whitelist, whitelist_entries)
	g.proxy_hops = make([dynamic]IP_Addr, 0, 2, a)
	return parsed, bad
}

socket_guard_destroy :: proc(g: ^Socket_Guard) {
	whitelist_destroy(&g.whitelist)
	delete(g.proxy_hops)
}

// socket_guard_allow_proxy resolves the proxy host once and marks its
// addresses as permitted first hops (every proxied connection dials the
// proxy, never the target).
socket_guard_allow_proxy :: proc(g: ^Socket_Guard, proxy_url: string, a := context.allocator) {
	host := proxy_host(proxy_url)
	if host == "" {
		return
	}
	addrs := resolve_host(host, a)
	defer delete(addrs)
	for addr in addrs {
		append(&g.proxy_hops, addr)
	}
}

proxy_hop :: proc(g: ^Socket_Guard, addr: IP_Addr) -> bool {
	for hop in g.proxy_hops {
		if addr_equal(hop, addr) {
			return true
		}
	}
	return false
}

// --- small helpers ------------------------------------------------------------

// split_host_port splits a bare authority into host and port. Bracketed
// IPv6 literals ("[::1]:8080") keep the port; a bare authority may carry at
// most one colon (an unbracketed IPv6 literal is malformed here). ok=false
// on anything malformed. The ONE parser for proxy URLs and origin checks —
// duplicated host:port parsing is how the IPv6 port-validation gap shipped.
split_host_port :: proc(s: string) -> (host, port: string, ok: bool) {
	if strings.has_prefix(s, "[") {
		end := strings.index_byte(s, ']')
		if end < 0 {
			return "", "", false
		}
		host = s[1:end]
		rest := s[end + 1:]
		if rest == "" {
			return host, "", true
		}
		if len(rest) < 2 || rest[0] != ':' {
			return "", "", false
		}
		return host, rest[1:], true
	}
	colon := strings.index_byte(s, ':')
	if colon < 0 {
		return s, "", true
	}
	if strings.index_byte(s[colon + 1:], ':') >= 0 {
		return "", "", false
	}
	return s[:colon], s[colon + 1:], true
}

// url_origin extracts a URL's lowercase scheme and host (userinfo, port,
// path, query, fragment stripped). The lowered copies live on
// context.temp_allocator — compare, do not store past the request.
url_origin :: proc(url: string) -> (scheme, host: string, ok: bool) {
	scheme_end := strings.index(url, "://")
	if scheme_end < 0 {
		return "", "", false
	}
	scheme = strings.to_lower(url[:scheme_end], context.temp_allocator)
	rest := url[scheme_end + 3:]
	if slash := strings.index_byte(rest, '/'); slash >= 0 {
		rest = rest[:slash]
	}
	if q := strings.index_byte(rest, '?'); q >= 0 {
		rest = rest[:q]
	}
	if hash := strings.index_byte(rest, '#'); hash >= 0 {
		rest = rest[:hash]
	}
	if at := strings.last_index_byte(rest, '@'); at >= 0 {
		rest = rest[at + 1:]
	}
	h, _, kok := split_host_port(rest)
	if !kok || h == "" {
		return "", "", false
	}
	return scheme, strings.to_lower(h, context.temp_allocator), true
}

// origin_allows reports whether a redirect target keeps the pinned origin's
// scheme and host (case-insensitive). Scheme pinning is deliberate: an
// https→http hop would put the credentials on the wire in the clear.
origin_allows :: proc(scheme, host, url: string) -> bool {
	us, uh, ok := url_origin(url)
	if !ok {
		return false
	}
	return strings.equal_fold(us, scheme) && strings.equal_fold(uh, host)
}

validate_proxy :: proc(proxy: string, a := context.allocator) -> string {
	if proxy == "" {
		return ""
	}
	scheme_end := strings.index(proxy, "://")
	if scheme_end < 0 {
		return "invalid proxy URL: missing scheme"
	}
	scheme := strings.to_lower(proxy[:scheme_end], context.temp_allocator)
	if scheme != "http" && scheme != "https" && scheme != "socks5" && scheme != "socks5h" {
		return strings.concatenate({
			"unsupported proxy scheme \"", proxy[:scheme_end],
			"\" (supported: http, https, socks5, socks5h)",
		}, a)
	}
	rest := proxy[scheme_end + 3:]
	if strings.contains(rest, "/") || strings.contains(rest, "?") || strings.contains(rest, "#") {
		return "proxy URL must not contain path, query, or fragment"
	}
	if safety.url_has_control_char(proxy) {
		return "invalid proxy URL: control characters are not allowed"
	}
	host_port := rest
	if at := strings.index(rest, "@"); at >= 0 {
		host_port = rest[at + 1:]
	}
	if host_port == "" {
		return "invalid proxy URL: missing host"
	}
	// One parser for both forms: the bracketed IPv6 literal takes the same
	// port validation as the bare host:port form (it used to skip it —
	// the two parsers had drifted apart).
	host, port, kok := split_host_port(host_port)
	if !kok {
		return "invalid proxy URL: malformed host or port"
	}
	if host == "" {
		return "invalid proxy URL: missing host"
	}
	if port != "" {
		v := 0
		if len(port) > 5 {
			return "invalid proxy port"
		}
		for i := 0; i < len(port); i += 1 {
			if port[i] < '0' || port[i] > '9' {
				return "invalid proxy port"
			}
			v = v * 10 + int(port[i] - '0')
		}
		if v < 1 || v > 65535 {
			return "invalid proxy port"
		}
	}
	return ""
}

// proxy_host extracts the host portion of a proxy URL for resolution.
proxy_host :: proc(proxy: string) -> string {
	scheme_end := strings.index(proxy, "://")
	if scheme_end < 0 {
		return ""
	}
	rest := proxy[scheme_end + 3:]
	if at := strings.index(rest, "@"); at >= 0 {
		rest = rest[at + 1:]
	}
	host, _, kok := split_host_port(rest)
	if !kok || host == "" {
		return ""
	}
	return host
}

string_view :: proc(cs: cstring, n: int) -> string {
	return transmute(string)(cast([^]u8)cs)[:n]
}

cstring_to_string :: proc(cs: cstring) -> string {
	if cs == nil {
		return ""
	}
	n := int(c.strlen(cs))
	bytes_view := transmute([]u8)(string_view(cs, n))
	return transmute(string)bytes_view
}

// sock_addr_to_ip reads the address bytes out of a curl sockaddr using
// the universal offsets (family/port/flowinfo header, address at 4 for
// IPv4 and 8 for IPv6 — identical across the platforms we target).
sock_addr_to_ip :: proc(family: int, address: ^curl.sockaddr) -> (IP_Addr, bool) {
	addr: IP_Addr
	base := cast([^]u8)(&address.addr)
	if family == AF_INET_VAL {
		addr.family = .V4
		for i := 0; i < 4; i += 1 {
			addr.bytes[i] = base[4 + i]
		}
		return addr, true
	}
	if family == AF_INET6_VAL {
		addr.family = .V6
		for i := 0; i < 16; i += 1 {
			addr.bytes[i] = base[8 + i]
		}
		return addr, true
	}
	return addr, false
}
