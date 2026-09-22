// The web_fetch pipeline: URL gating (scheme, host shape, safety guards,
// private-host refusal), the curl transfer with the Cloudflare-challenge
// retry under an honest user agent, content-type dispatch (JSON pretty
// print, HTML→markdown, raw), truncation, and secret redaction. The
// result renders as a JSON envelope.
package web

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync/chan"

import "src:jsonutil"
import "src:platform"
import "src:safety"
import "src:util"
import "src:version"

FETCH_MAX_CHARS_DEFAULT :: 50_000
FETCH_MAX_CHARS_CEILING :: 1 << 20 // 1 MiB
FETCH_DEFAULT_LIMIT_BYTES :: 10 * 1024 * 1024
FETCH_HARD_LIMIT_BYTES :: 50 * 1024 * 1024

// Admission cap: at most this many fetcher_fetch calls run at once. One
// fetch pins a daemon worker for up to the 60 s transfer timeout plus
// the Cloudflare retry, and the worker pool is shared by every svc
// operation — without a fetch-level cap, enough concurrent fetches
// would starve tracker/LSP/file traffic entirely. Half the default pool
// size, so the other half always stays available to non-web work. A
// full slot set fails fast (the jsonrpc request-queue idiom) instead of
// queueing: waiting fetches would occupy workers again and defeat the
// cap's purpose.
FETCH_ADMISSION_CAP :: 4

USER_AGENT_HONEST :: "aubade/" + version.AUBADE_VERSION + " (+" + version.AUBADE_REPO_URL + "; AI coding assistant)"

Fetcher :: struct {
	client:            HTTP_Client,
	guard:             Socket_Guard,
	max_chars:         int,
	format:            string, // "markdown" or "text"
	fetch_limit_bytes: int,
	safety:            ^safety.Safety_Checker,
	allow_private:     bool,
	// The configured proxy URL, owned by the fetcher's allocator and applied
	// to every fetch request (validated below; the guard pre-allows its hop).
	proxy:             string,
	allocator:         mem.Allocator,
	// Conversion post-processing patterns, compiled once for the fetcher's
	// lifetime (a per-call compile + JIT was pure setup cost on every
	// web_fetch); has_post=false falls back to the per-call path.
	post:              Html_Post_Procs,
	has_post:         bool,
	// Admission slots: a buffered chan used as a counting semaphore, one
	// token per in-flight fetch (see FETCH_ADMISSION_CAP).
	slots:             chan.Chan(u8),
	has_slots:        bool,
	is_ready:          bool,
}

// fetcher_init builds the fetcher from the web config. A bad proxy or an
// unparsable whitelist leaves it not-ready: the daemon then refuses
// svc.web/fetch with the construction error's shape (the tool family
// disappears exactly when its transport cannot exist).
fetcher_init :: proc(
	f: ^Fetcher,
	proxy: string,
	format: string,
	fetch_limit_bytes: i64,
	whitelist_entries: []string,
	checker: ^safety.Safety_Checker,
	allow_private: bool,
	a := context.allocator,
) -> (ok: bool, bad_entry: string) {
	f^ = {}
	f.allocator = a
	slots, serr := chan.create_buffered(chan.Chan(u8), FETCH_ADMISSION_CAP, a)
	if serr != nil {
		return false, ""
	}
	f.slots = slots
	f.has_slots = true
	http_client_init(&f.client)
	w_ok, bad := socket_guard_init(&f.guard, whitelist_entries, allow_private, a)
	if !w_ok {
		return false, bad
	}
	if proxy != "" {
		if err := validate_proxy(proxy, context.temp_allocator); err != "" {
			return false, ""
		}
		socket_guard_allow_proxy(&f.guard, proxy, a)
		f.proxy = strings.clone(proxy, a)
	}
	f.max_chars = FETCH_MAX_CHARS_DEFAULT
	f.format = format
	f.fetch_limit_bytes = int(fetch_limit_bytes)
	if f.fetch_limit_bytes <= 0 {
		f.fetch_limit_bytes = FETCH_DEFAULT_LIMIT_BYTES
	}
	if f.fetch_limit_bytes > FETCH_HARD_LIMIT_BYTES {
		f.fetch_limit_bytes = FETCH_HARD_LIMIT_BYTES
	}
	f.safety = checker
	f.allow_private = allow_private
	f.has_post = html_post_procs_init(&f.post, a)
	f.is_ready = true
	return true, ""
}

// fetcher_destroy owns ALL teardown, including a partially-built fetcher:
// the init failure paths only report (a second destroy of the same guard
// would double-free — delete does not reset a [dynamic] header), so every
// cleanup runs here exactly once. http_client_destroy self-guards on
// is_initialized; socket_guard_destroy's deletes no-op on zero values.
fetcher_destroy :: proc(f: ^Fetcher) {
	if f.has_post {
		html_post_procs_destroy(&f.post)
	}
	http_client_destroy(&f.client)
	socket_guard_destroy(&f.guard)
	if f.proxy != "" {
		delete(f.proxy, f.allocator)
	}
	if f.has_slots {
		chan.destroy(f.slots)
	}
	f^ = {}
}

// fetch_check_url runs every pre-request gate; .None with "" means the
// request may proceed. Split out so the tests exercise the refusals
// without network.
fetch_check_url :: proc(
	raw_url: string,
	w: ^Private_Whitelist,
	allow_private: bool,
) -> (Web_Err, string) {
	// Same control-character refusal as urlguard_validate_url: a raw byte
	// under 0x20 (or DEL) in the URL can only be an attempt to smuggle
	// structure past the gates — reject it before anything parses the URL.
	if safety.url_has_control_char(raw_url) {
		return .Invalid_Url, "URL contains control characters"
	}
	scheme_end := strings.index(raw_url, "://")
	scheme := ""
	if scheme_end >= 0 {
		scheme = strings.to_lower(raw_url[:scheme_end], context.temp_allocator)
	}
	if scheme != "http" && scheme != "https" {
		return .Invalid_Url, "only http/https URLs are allowed"
	}
	rest := raw_url[scheme_end + 3:]
	host := rest
	if slash := strings.index_byte(rest, '/'); slash >= 0 {
		host = rest[:slash]
	}
	if at := strings.last_index_byte(host, '@'); at >= 0 {
		host = host[at + 1:]
	}
	if bracket := strings.index_byte(host, ']'); bracket >= 0 {
		host = strings.trim_prefix(strings.trim_prefix(host[:bracket + 1], "["), "]")
	} else if colon := strings.index_byte(host, ':'); colon >= 0 {
		host = host[:colon]
	}
	if host == "" {
		return .Invalid_Url, "missing domain in URL"
	}
	if obvious_private_host(host, w, allow_private) {
		return .Denied, "fetching private or local network hosts is not allowed"
	}
	return .None, ""
}

// fetch_redirect_check re-runs the full pre-request gate bundle on every
// redirect target — the initial URL's checks must not lapse mid-chain
// (a redirect from an allowed page to a deny-listed host or a
// secret-bearing URL is refused here, before the hop is dialed). The
// allocator parameter is mandated by the redirect_check proc type; the
// refusal strings are literals and allocate nothing.
fetch_redirect_check :: proc(data: rawptr, url: string, a: mem.Allocator) -> string {
	f := cast(^Fetcher)data
	if _, err := fetch_check_url(url, &f.guard.whitelist, f.allow_private); err != "" {
		return err
	}
	if f.safety != nil {
		if blocked, reason := safety.check_url(f.safety, url); blocked {
			return reason
		}
		if found, what := safety.check_url_for_secrets(f.safety, url); found {
			return what
		}
	}
	return ""
}

// fetcher_fetch retrieves the URL and renders the JSON result envelope.
// The optional token is polled before the request and through an xferinfo
// callback mid-transfer (a fired token aborts the transfer).
fetcher_fetch :: proc(
	f: ^Fetcher,
	raw_url: string,
	max_chars_override: int,
	token: ^platform.Cancel_Token = nil,
	a := context.allocator,
) -> (string, Web_Err, string) {
	if !f.is_ready {
		return "", .Not_Configured, "web fetch is not configured"
	}
	if kind, err := fetch_check_url(raw_url, &f.guard.whitelist, f.allow_private); err != "" {
		return "", kind, err
	}
	if f.safety != nil {
		if blocked, reason := safety.check_url(f.safety, raw_url); blocked {
			return "", .Denied, reason
		}
		if found, what := safety.check_url_for_secrets(f.safety, raw_url); found {
			return "", .Denied, what
		}
	}
	if token != nil {
		if _, fired := platform.token_check(token); fired {
			return "", .Cancelled, "web fetch cancelled before request"
		}
	}
	// Admission sits after the cancellation pre-flight (an already
	// cancelled request never consumes a slot) and fails fast: a full
	// slot set is an immediate busy answer, not a queue — waiting
	// fetches would pin workers again and defeat the cap's purpose.
	if !chan.try_send(f.slots, 0) {
		return "", .Busy, fmt.aprintf(
			"web fetch busy: at most %d concurrent fetches; retry when a slot frees",
			FETCH_ADMISSION_CAP, allocator = a,
		)
	}
	defer {
		// Release never blocks: this call holds one token.
		_, _ = chan.recv(f.slots)
	}

	max_chars := f.max_chars
	if max_chars_override > 100 {
		max_chars = max_chars_override
	}
	if max_chars > FETCH_MAX_CHARS_CEILING {
		max_chars = FETCH_MAX_CHARS_CEILING
	}

	req := HTTP_Request{
		url = raw_url,
		user_agent = USER_AGENT_DEFAULT,
		timeout_ms = HTTP_FETCH_TIMEOUT_MS,
		proxy = f.proxy,
		max_bytes = f.fetch_limit_bytes,
		redirect_check = fetch_redirect_check,
		redirect_check_data = f,
		token = token,
	}
	res, err_kind, err := http_do(&f.client, req, &f.guard, a)
	if err_kind != .None {
		return "", err_kind, err
	}
	// A Cloudflare challenge under the browser UA retries once with the
	// honest one: a SUCCESSFUL 403 carrying the Cf-Mitigated marker (a
	// plain 403 is a real answer, not a challenge page). The retry's own
	// http_do honors the token, so a cancellation surfaces as .Cancelled.
	if res.status == 403 && res.cf_challenge {
		req2 := req
		req2.user_agent = USER_AGENT_HONEST
		res2, err2_kind, err2 := http_do(&f.client, req2, &f.guard, a)
		if err2_kind != .None {
			return "", err2_kind, err2
		}
		res = res2
	}

	body_str := transmute(string)res.body
	media_type := media_type_of(res.content_type, a)

	text := ""
	extractor := ""
	switch media_type {
	case "application/json":
		text, extractor = json_pretty(body_str, a)
	case "text/html":
		t, ex, hok := html_extract(body_str, f.format, f.has_post ? &f.post : nil, a)
		if !hok {
			return "", .Internal, "failed to convert HTML to markdown"
		}
		text = t
		extractor = ex
	case:
		if media_type == "" && looks_like_html(body_str) {
			t, ex, hok := html_extract(body_str, f.format, f.has_post ? &f.post : nil, a)
			if !hok {
				return "", .Internal, "failed to convert HTML to markdown"
			}
			text = t
			extractor = ex
		} else {
			text = body_str
			extractor = "raw"
		}
	}

	// Redact BEFORE truncating: a secret straddling the size limit would be
	// cut mid-token first, and the redactor can no longer match (or remove)
	// the surviving half. Fail closed: content whose redaction could not
	// complete is never handed back, even partially.
	if f.safety != nil {
		redacted, rerr := safety.redact_content(f.safety, text, a)
		if rerr != nil {
			return "", .Internal, platform.err_message(rerr, context.temp_allocator)
		}
		text = redacted
	}
	truncated := len(text) > max_chars
	if truncated {
		text = strings.concatenate({
			text[:max_chars], "\n[Content truncated due to size limit]",
		}, a)
	}

	return fetch_result_json(raw_url, res.status, extractor, truncated, len(text), text, a), .None, ""
}

// html_extract renders an HTML body per the requested format: markdown
// when the caller asked for markdown, plain text otherwise. ok=false
// means the markdown conversion failed (the caller answers Internal).
html_extract :: proc(body: string, format: string, post: ^Html_Post_Procs, a: mem.Allocator) -> (text: string, extractor: string, ok: bool) {
	if strings.to_lower(format, context.temp_allocator) == "markdown" {
		md, mok := html_to_markdown(body, a, post)
		if !mok {
			return "", "", false
		}
		return md, "markdown", true
	}
	return extract_plain_text(body, a), "text", true
}

// fetch_result_json renders the result envelope; built with plain
// concatenation because the formatter treats '{' in JSON text as a
// parameter brace.
fetch_result_json :: proc(
	url: string,
	status: int,
	extractor: string,
	truncated: bool,
	length: int,
	text: string,
	a := context.allocator,
) -> string {
	parts: [13]string
	parts[0] = "{\n  \"url\": "
	parts[1] = jsonutil.json_quote(url, a)
	parts[2] = ",\n  \"status\": "
	parts[3] = util.int_to_dec(status, a)
	parts[4] = ",\n  \"extractor\": "
	parts[5] = jsonutil.json_quote(extractor, a)
	parts[6] = ",\n  \"truncated\": "
	parts[7] = "false"
	if truncated {
		parts[7] = "true"
	}
	parts[8] = ",\n  \"length\": "
	parts[9] = util.int_to_dec(length, a)
	parts[10] = ",\n  \"text\": "
	parts[11] = jsonutil.json_quote(text, a)
	parts[12] = "\n}"
	return strings.concatenate(parts[:], a)
}

media_type_of :: proc(content_type: string, a := context.temp_allocator) -> string {
	trimmed := strings.trim_space(content_type)
	if trimmed == "" {
		return ""
	}
	if semi := strings.index_byte(trimmed, ';'); semi >= 0 {
		trimmed = trimmed[:semi]
	}
	return strings.to_lower(strings.trim_space(trimmed), a)
}

json_pretty :: proc(body: string, a := context.allocator) -> (string, string) {
	// Remote bodies pass the structural sanity scan before the parser: the
	// core parser recurses per nesting level with no depth cap, and a deep
	// body must fall back to raw, not crash the daemon.
	if !util.json_sanity_ok(transmute([]u8)body) {
		return body, "raw"
	}
	value, jerr := json.parse_string(body, allocator = context.temp_allocator)
	if jerr != json.Error.None {
		return body, "raw"
	}
	out, uerr := json.unparse(
		value,
		{pretty = true, use_spaces = true, spaces = 2, sort_maps_by_key = true},
		allocator = a,
	)
	if uerr != nil {
		return body, "raw"
	}
	return out, "json"
}

looks_like_html :: proc(body: string) -> bool {
	if body == "" {
		return false
	}
	prefix := body
	if len(prefix) > 512 {
		prefix = prefix[:512]
	}
	lower := strings.to_lower(prefix, context.temp_allocator)
	return strings.has_prefix(lower, "<!doctype") || strings.has_prefix(lower, "<html")
}

// extract_plain_text strips scripts, styles, and tags, then collapses
// whitespace (the fallback format's converter). Like html_to_markdown,
// the conversion runs on a scratch arena; the caller receives the single
// result string owned by `a`.
extract_plain_text :: proc(body: string, a := context.allocator) -> string {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, a)
	scratch := mem.dynamic_arena_allocator(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	out := make([dynamic]u8, 0, len(body), scratch)
	i := 0
	in_tag := false
	for i < len(body) {
		c := body[i]
		if !in_tag && c == '<' {
			lower_next := strings.to_lower(body[i:i + 9 < len(body) ? i + 9 : len(body)], scratch)
			if strings.has_prefix(lower_next, "<script") || strings.has_prefix(lower_next, "<style") {
				end := find_close_tag(body, i)
				if end < 0 {
					break
				}
				i = end
				continue
			}
			in_tag = true
			i += 1
			continue
		}
		if in_tag {
			if c == '>' {
				in_tag = false
			}
			i += 1
			continue
		}
		append(&out, c)
		i += 1
	}
	text := strings.trim_space(transmute(string)(out[:]))
	// Collapse runs of spaces/tabs and 3+ newlines.
	collapsed := make([dynamic]u8, 0, len(text), scratch)
	prev_space := false
	for j := 0; j < len(text); j += 1 {
		c := text[j]
		if c == ' ' || c == '\t' {
			if prev_space {
				continue
			}
			prev_space = true
			append(&collapsed, ' ')
			continue
		}
		prev_space = false
		append(&collapsed, c)
	}
	lines := strings.split(transmute(string)(collapsed[:]), "\n", scratch)
	cleaned := make([dynamic]string, 0, len(lines), scratch)
	for j := 0; j < len(lines); j += 1 {
		line := strings.trim_space(lines[j])
		if line != "" {
			append(&cleaned, strings.clone(line, scratch))
		}
	}
	joined, _ := strings.join(cleaned[:], "\n", scratch)
	return strings.clone(joined, a)
}

// find_close_tag scans for the closing tag case-insensitively from
// `from`, returning the offset just past it (-1 when absent). The scan
// compares in place — the previous implementation lowercased a copy of
// the ENTIRE body per script/style block, so a page with N blocks cost
// N full-body allocations. HTML tag names are ASCII, so an ASCII fold is
// the exact comparison.
find_close_tag :: proc(body: string, from: int) -> int {
	needle := "</script>"
	if tag_prefix_fold_eq(body[from:], "<style") {
		needle = "</style>"
	}
	n := len(needle)
	i := from
	for i >= 0 && i < len(body) {
		next_lt := strings.index_byte(body[i:], '<')
		if next_lt < 0 {
			return -1
		}
		at := i + next_lt
		if at+n <= len(body) && util.ascii_equal_ci(body[at:at+n], needle) {
			return at + n
		}
		i = at + 1
	}
	return -1
}

// tag_prefix_fold_eq reports whether `s` starts with the (lowercase)
// ASCII prefix, case-insensitively.
tag_prefix_fold_eq :: proc(s: string, prefix: string) -> bool {
	if len(s) < len(prefix) {
		return false
	}
	return util.ascii_equal_ci(s[:len(prefix)], prefix)
}
