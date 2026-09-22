// Web layer tests: the SSRF range table and whitelist semantics, the
// lexbor-backed HTML→markdown converter's golden shapes, and the fetcher's
// pre-request refusals (scheme, private host) that need no network.
package tests

import "core:mem"
import "core:strings"
import "core:sync/chan"
import "core:testing"

import "src:platform"
import "src:safety"
import "src:version"
import "src:web"

@(test)
web_ssrf_ranges :: proc(t: ^testing.T) {
	blocked_v4 := []string{
		"10.0.0.1", "127.0.0.1", "0.1.2.3", "172.16.0.1", "172.31.255.255",
		"192.168.1.1", "169.254.1.1", "100.64.0.1", "100.127.255.255",
		"224.0.0.1", "255.255.255.255",
	}
	for s in blocked_v4 {
		addr, ok := web.parse_ip(s)
		testing.expectf(t, ok, "parse %s", s)
		testing.expectf(t, web.is_private_or_restricted(addr), "blocked %s", s)
	}
	allowed_v4 := []string{"1.1.1.1", "8.8.8.8", "172.32.0.1", "100.128.0.1", "172.15.255.255"}
	for s in allowed_v4 {
		addr, ok := web.parse_ip(s)
		testing.expectf(t, ok, "parse %s", s)
		testing.expectf(t, !web.is_private_or_restricted(addr), "allowed %s", s)
	}

	blocked_v6 := []string{"::1", "::", "fe80::1", "ff02::1", "fc00::1", "fd12:3456::1"}
	for s in blocked_v6 {
		addr, ok := web.parse_ip(s)
		testing.expectf(t, ok, "parse %s", s)
		testing.expectf(t, web.is_private_or_restricted(addr), "blocked %s", s)
	}
	allowed_v6 := []string{"2606:4700::1111", "2001:db8::1"}
	for s in allowed_v6 {
		addr, ok := web.parse_ip(s)
		testing.expectf(t, ok, "parse %s", s)
		testing.expectf(t, !web.is_private_or_restricted(addr), "allowed %s", s)
	}

	// Translation ranges: the embedded IPv4 decides.
	nat64, ok1 := web.parse_ip("64:ff9b::192.168.1.1")
	testing.expect(t, ok1 && web.is_private_or_restricted(nat64), "NAT64 private")
	sixto4, ok2 := web.parse_ip("2002:0a00:0001::1")
	testing.expect(t, ok2 && web.is_private_or_restricted(sixto4), "6to4 private")
	teredo, ok3 := web.parse_ip("2001:0000:1234:5678:0000:0000:95d5:a7fe") // client 10.0.0.1 ^ ff? (obfuscated)
	testing.expect(t, ok3, "teredo parse")
	_ = teredo
}

@(test)
web_ssrf_whitelist :: proc(t: ^testing.T) {
	w: web.Private_Whitelist
	web.whitelist_init(&w, context.allocator)
	defer web.whitelist_destroy(&w)

	ok, bad := web.whitelist_parse(&w, []string{" 10.0.0.5 ", "192.168.0.0/24", "not-an-ip"})
	testing.expectf(t, !ok && bad == "not-an-ip", "bad entry rejected: %s", bad)

	ok2, _ := web.whitelist_parse(&w, []string{"10.0.0.5", "192.168.0.0/24", ""})
	testing.expect(t, ok2, "good entries accepted")

	in_net, _ := web.parse_ip("192.168.0.77")
	exact, _ := web.parse_ip("10.0.0.5")
	outside, _ := web.parse_ip("10.0.0.99")
	testing.expect(t, !web.should_block(in_net, &w), "whitelisted CIDR")
	testing.expect(t, !web.should_block(exact, &w), "whitelisted exact")
	testing.expect(t, web.should_block(outside, &w), "non-whitelisted stays blocked")

	testing.expect(t, web.obvious_private_host("localhost", &w, false), "localhost")
	testing.expect(t, web.obvious_private_host("a.localhost.", &w, false), "dotted localhost")
	testing.expect(t, web.obvious_private_host("127.0.0.1", &w, false), "literal loopback")
	testing.expect(t, !web.obvious_private_host("example.com", &w, false), "public host")
	testing.expect(t, !web.obvious_private_host("localhost", &w, true), "allow override")
}

@(test)
web_ssrf_prefix_mask :: proc(t: ^testing.T) {
	// Regression: the leftover-bit mask keeps the TOP `remaining` bits of
	// the final byte. The old two-step form kept only the low end of that
	// range, so for remainders 5..7 an address differing in the high
	// prefix bits still matched — 10.0.0.128 passed a 10.0.0.0/29 entry.
	w: web.Private_Whitelist
	web.whitelist_init(&w, context.allocator)
	defer web.whitelist_destroy(&w)
	ok, _ := web.whitelist_parse(&w, []string{"10.0.0.0/29"})
	testing.expect(t, ok, "whitelist parse")

	net, _ := web.parse_ip("10.0.0.0")
	in_low, _ := web.parse_ip("10.0.0.5")
	in_top, _ := web.parse_ip("10.0.0.7")
	out_hi, _ := web.parse_ip("10.0.0.128")
	out_lo, _ := web.parse_ip("10.0.0.8")
	testing.expect(t, web.prefix_match(net, in_low, 29), "inside /29")
	testing.expect(t, web.prefix_match(net, in_top, 29), "top of /29")
	testing.expect(t, !web.prefix_match(net, out_hi, 29), "high-bit difference outside /29 (the over-match)")
	testing.expect(t, !web.prefix_match(net, out_lo, 29), "adjacent /29 block")

	// Every remainder 1..7: the last byte's top bit is a prefix bit, so an
	// address that sets it must never match a .0 network of that length.
	// For prefix 24+r the inside address sets every host bit: 0xFF >> r.
	cases := []struct {
		bits:   int,
		inside: string,
	}{
		{25, "10.0.0.127"},
		{26, "10.0.0.63"},
		{27, "10.0.0.31"},
		{28, "10.0.0.15"},
		{29, "10.0.0.7"},
		{30, "10.0.0.3"},
		{31, "10.0.0.1"},
	}
	for i in 0..<len(cases) {
		in_a, _ := web.parse_ip(cases[i].inside)
		testing.expectf(t, web.prefix_match(net, in_a, cases[i].bits), "inside /%d", cases[i].bits)
		testing.expectf(t, !web.prefix_match(net, out_hi, cases[i].bits), "outside /%d", cases[i].bits)
	}
}

@(test)
web_empty_html_and_deep_json :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// An empty HTML body converts to empty markdown — it must not reach
	// the parser (whose writable-copy step would index an empty slice).
	md, ok := web.html_to_markdown("", a)
	testing.expect(t, ok && md == "", "empty html -> empty markdown")

	// A deeper-than-allowed JSON body falls back to raw instead of
	// recursing the core parser to stack exhaustion.
	deep := strings.repeat("[", 200, a)
	text, extractor := web.json_pretty(deep, a)
	testing.expect(t, extractor == "raw", "deep json falls back to raw")
	testing.expect(t, text == deep, "raw fallback returns the body")

	shallow, ext := web.json_pretty("{\"a\": 1}", a)
	testing.expect(t, ext == "json", "shallow json still prettifies")
	testing.expect(t, len(shallow) > 0, "prettified body is non-empty")
}

@(test)
web_html_to_markdown :: proc(t: ^testing.T) {
	// Every conversion result lands on one arena freed at test end — the
	// converter's owned outputs are the caller's responsibility.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Heading + paragraph + emphasis.
	md, ok := web.html_to_markdown(
		"<html><body><h1>Title</h1><p>Hello <b>bold</b> and <i>it</i>.</p></body></html>",
		a,
	)
	testing.expect(t, ok, "parse ok")
	testing.expect(t, strings.contains(md, "# Title"), md)
	testing.expect(t, strings.contains(md, "**bold**"), md)
	testing.expect(t, strings.contains(md, "*it*"), md)

	// Links and images with safe filtering.
	md2, ok2 := web.html_to_markdown(
		"<body><a href=\"https://example.com/page\">a page</a> <img src=\"https://example.com/i.png\" alt=\"pic [x]\"></body>",
		a,
	)
	testing.expect(t, ok2, "parse ok 2")
	testing.expect(t, strings.contains(md2, "[a page](https://example.com/page)"), md2)
	testing.expect(t, strings.contains(md2, "![pic \\[x\\]](https://example.com/i.png)"), md2)

	// javascript: hrefs are neutralized.
	md3, ok3 := web.html_to_markdown(
		"<body><a href=\"javascript:alert(1)\">bad</a></body>",
		a,
	)
	testing.expect(t, ok3, "parse ok 3")
	testing.expect(t, !strings.contains(md3, "javascript:"), md3)

	// Lists: ordered numbering and nesting indent.
	md4, ok4 := web.html_to_markdown(
		"<body><ol><li>one</li><li>two</li></ol><ul><li>bullet</li></ul></body>",
		a,
	)
	testing.expect(t, ok4, "parse ok 4")
	testing.expect(t, strings.contains(md4, "1. one"), md4)
	testing.expect(t, strings.contains(md4, "2. two"), md4)
	testing.expect(t, strings.contains(md4, "- bullet"), md4)

	// Code blocks stay verbatim; inline code is wrapped.
	md5, ok5 := web.html_to_markdown(
		"<body><pre>line1\n  line2</pre><p>use <code>x()</code> now</p></body>",
		a,
	)
	testing.expect(t, ok5, "parse ok 5")
	testing.expect(t, strings.contains(md5, "```\nline1\n  line2\n```"), md5)
	testing.expect(t, strings.contains(md5, "`x()`"), md5)

	// Blockquotes prefix each line.
	md6, ok6 := web.html_to_markdown(
		"<body><blockquote><p>quoted</p></blockquote></body>",
		a,
	)
	testing.expect(t, ok6, "parse ok 6")
	testing.expect(t, strings.contains(md6, "> quoted"), md6)

	// Nav/footer/script content is dropped; article content stays.
	md7, ok7 := web.html_to_markdown(
		"<body><nav>menu item</nav><script>var x = 1;</script><article>real content</article><footer>copyright</footer></body>",
		a,
	)
	testing.expect(t, ok7, "parse ok 7")
	testing.expect(t, strings.contains(md7, "real content"), md7)
	testing.expect(t, !strings.contains(md7, "menu item"), md7)
	testing.expect(t, !strings.contains(md7, "var x"), md7)
	testing.expect(t, !strings.contains(md7, "copyright"), md7)

	// Chrome-classed subtrees are dropped via the unlikely-node rule.
	md8, ok8 := web.html_to_markdown(
		"<body><div class=\"cookie-banner\">accept cookies</div><div class=\"article-content\">body text</div></body>",
		a,
	)
	testing.expect(t, ok8, "parse ok 8")
	testing.expect(t, strings.contains(md8, "body text"), md8)
	testing.expect(t, !strings.contains(md8, "accept cookies"), md8)
}

@(test)
web_html_link_multiline_utf8 :: proc(t: ^testing.T) {
	// Multi-line anchors link only the first non-empty line; both copy
	// loops must move bytes, not runes — rune iteration truncated every
	// multi-byte UTF-8 character to a single byte.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	md, ok := web.html_to_markdown(
		"<body><a href=\"https://example.com/ja\">日本語 😀 リンク<br>second ライン</a></body>",
		a,
	)
	testing.expect(t, ok, "parse ok")
	testing.expect(t, strings.contains(md, "[日本語 😀 リンク](https://example.com/ja)"), md)
	testing.expect(t, strings.contains(md, "second ライン"), md)
}

@(test)
web_fetch_refusals :: proc(t: ^testing.T) {
	// The pre-request gates: non-http(s) schemes and missing hosts never
	// reach curl; private hostnames are refused without allow_private.
	cases := []struct {
		url:   string,
		block: string,
	}{
		{url = "ftp://example.com/file", block = "only http/https URLs are allowed"},
		{url = "http://localhost:8080/x", block = "fetching private or local network hosts is not allowed"},
		{url = "http://127.0.0.1/x", block = "fetching private or local network hosts is not allowed"},
		{url = "http:///nohost", block = "missing domain in URL"},
	}
	for c in cases {
		_, err := web.fetch_check_url(c.url, nil, false)
		testing.expectf(t, err == c.block, "url %s: got %q", c.url, err)
	}
	// The same localhost URL passes its gates with allow_private.
	_, err2 := web.fetch_check_url("http://localhost:8080/x", nil, true)
	testing.expect(t, err2 == "", "allow_private passes the gate")
}

@(test)
web_tool_family_apply :: proc(t: ^testing.T) {
	// The web family routes through a dead loopback proxy (port 9,
	// discard — nothing listens): the requests stay on-machine while the
	// full child→daemon→curl path still runs.
	global_jsonc := "{\"web\": {\"fetch_proxy\": \"http://127.0.0.1:9\"}}"
	pair := test_daemon_with_configs(t, false, "", global_jsonc)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// The pre-request gates ride the whole svc path: a non-http scheme is
	// refused with the fixed wording through the daemon round-trip.
	out, is_err := tool_run(t, pair, "web_fetch", "{\"url\": \"ftp://example.com/f\"}", a)
	testing.expect(t, is_err, out)
	testing.expect(t, strings.contains(out, "only http/https URLs are allowed"), out)

	// The search rides the same dead proxy: the transfer fails on the
	// proxy connection, never touching the network.
	out2, is_err2 := tool_run(t, pair, "web_search", "{\"query\": \"anything\"}", a)
	testing.expect(t, is_err2, out2)
	testing.expect(t, strings.contains(out2, "request failed"), out2)
}

@(test)
web_redirect_gate :: proc(t: ^testing.T) {
	// The per-redirect gate re-runs the initial URL bundle: a hop to a
	// private target outside the whitelist is refused, a whitelisted one
	// passes, and the allow_private override keeps both shapes honest.
	w: web.Private_Whitelist
	web.whitelist_init(&w, context.allocator)
	defer web.whitelist_destroy(&w)
	ok, _ := web.whitelist_parse(&w, []string{"127.0.0.1"})
	testing.expect(t, ok)

	f: web.Fetcher
	f.allow_private = false
	f.guard.whitelist = w

	err := web.fetch_redirect_check(&f, "http://10.0.0.1/secret", context.allocator)
	testing.expect(t, err != "", "private hop outside the whitelist refused")
	err = web.fetch_redirect_check(&f, "http://127.0.0.1:8080/ok", context.allocator)
	testing.expect_value(t, err, "")
	f.allow_private = true
	err = web.fetch_redirect_check(&f, "http://10.0.0.1/x", context.allocator)
	testing.expect_value(t, err, "")
}

// A fired cancel token refuses the fetch before any request is built:
// the boundary surfaces the cancellation as a typed Web_Err instead of
// running to curl's own timeout.
@(test)
web_cancel_refuses :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	f: web.Fetcher
	ok, _ := web.fetcher_init(&f, "", "markdown", 65536, nil, nil, false, a)
	testing.expect(t, ok, "fetcher init")
	defer web.fetcher_destroy(&f)

	root := new(platform.Cancel_Token, a)
	platform.token_init_root(root)
	platform.token_fire(root, .Cancelled)

	_, kind, msg := web.fetcher_fetch(&f, "https://example.com/", 0, root, a)
	testing.expect(t, kind == .Cancelled, "cancelled kind")
	testing.expect(t, msg != "", "cancelled message")

	testing.expect(t, web.web_err_platform_kind(.Timeout) == .Retryable, "timeout maps retryable")
	testing.expect(t, web.web_err_platform_kind(.Denied) == .Denied, "denied maps denied")
	testing.expect(t, web.web_err_platform_kind(.Cancelled) == .Cancelled, "cancelled maps cancelled")
}

// searcher_init must own the option strings: the daemon builds them on a
// scratch arena that dies when its proc returns. Poison the caller's copies
// after init and the searcher must still read its own bytes; destroy frees
// them (zero leak lines under the test allocator).
@(test)
web_searcher_owns_options :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	opts: web.Search_Options
	opts.provider = strings.clone("auto", a)
	opts.providers[.DuckDuckGo].enabled = true
	opts.providers[.Tavily].base_url = strings.clone("https://api.tavily.example", a)
	opts.proxy = strings.clone("http://127.0.0.1:9", a)
	keys := make([]string, 1, a)
	keys[0] = strings.clone("k-1", a)
	opts.providers[.Brave].keys = keys

	s: web.Searcher
	ok, bad := web.searcher_init(&s, opts, context.allocator)
	testing.expectf(t, ok, "init: %s", bad)
	defer web.searcher_destroy(&s)

	// Poison the caller's copies in place: the searcher must read its own.
	provider_poison := transmute([]byte)opts.provider
	for i in 0..<len(provider_poison) {
		provider_poison[i] = 0x78
	}
	base_poison := transmute([]byte)opts.providers[.Tavily].base_url
	for i in 0..<len(base_poison) {
		base_poison[i] = 0x78
	}
	keys[0] = "poisoned"

	testing.expect_value(t, s.opts.provider, "auto")
	testing.expect_value(t, s.opts.providers[.Tavily].base_url, "https://api.tavily.example")
	testing.expect_value(t, s.opts.providers[.Brave].keys[0], "k-1")
	testing.expect_value(t, s.opts.proxy, "http://127.0.0.1:9")
}

// fetcher_init keeps the validated proxy for the transport: fetch requests
// carry it instead of a hard-coded empty string.
@(test)
web_fetcher_keeps_proxy :: proc(t: ^testing.T) {
	f: web.Fetcher
	ok, _ := web.fetcher_init(&f, "socks5h://127.0.0.1:1080", "markdown", 65536, nil, nil, false, context.allocator)
	testing.expect(t, ok, "fetcher init with proxy")
	defer web.fetcher_destroy(&f)
	testing.expect_value(t, f.proxy, "socks5h://127.0.0.1:1080")
}

// A failed init leaves a partially-built fetcher whose teardown belongs to
// fetcher_destroy alone: the destroy after a failed init must free every
// allocation exactly once (a double destroy of the guard segfaults — delete
// does not reset a [dynamic] header). The daemon's startup wiring runs this
// exact pair on a malformed whitelist or proxy config.
@(test)
web_fetcher_failed_init_destroy_is_safe :: proc(t: ^testing.T) {
	f: web.Fetcher
	ok, bad := web.fetcher_init(&f, "", "markdown", 65536, []string{"not-an-ip"}, nil, false, context.allocator)
	testing.expect(t, !ok, "init must fail on a bad whitelist entry")
	testing.expect_value(t, bad, "not-an-ip")
	web.fetcher_destroy(&f)

	f2: web.Fetcher
	ok2, _ := web.fetcher_init(&f2, "gopher://proxy:1080", "markdown", 65536, nil, nil, false, context.allocator)
	testing.expect(t, !ok2, "init must fail on an unsupported proxy scheme")
	web.fetcher_destroy(&f2)
}

// The searcher's init failures take the same contract: searcher_destroy
// frees the partially-built state (cloned options included) exactly once.
@(test)
web_searcher_failed_init_destroy_is_safe :: proc(t: ^testing.T) {
	s: web.Searcher
	opts: web.Search_Options
	opts.whitelist = []string{"not-an-ip"}
	ok, bad := web.searcher_init(&s, opts, context.allocator)
	testing.expect(t, !ok, "searcher init must fail on a bad whitelist entry")
	testing.expect_value(t, bad, "not-an-ip")
	web.searcher_destroy(&s)
}


@(test)
web_ssrf_v4_mapped :: proc(t: ^testing.T) {
	// Mapped spellings collapse to the v4 table at every decision point
	// (both classification and the dial gate).
	blocked := []string{"::ffff:10.0.0.2", "::ffff:127.0.0.1", "::ffff:192.168.1.1", "::ffff:169.254.1.1"}
	for s in blocked {
		addr, ok := web.parse_ip(s)
		testing.expectf(t, ok, "parse %s", s)
		testing.expectf(t, web.is_private_or_restricted(addr), "blocked %s", s)
		testing.expectf(t, web.should_block(addr, nil), "dial gate %s", s)
	}
	allowed := []string{"::ffff:8.8.8.8", "::ffff:1.1.1.1", "::ffff:8.8.8.1"}
	for s in allowed {
		addr, ok := web.parse_ip(s)
		testing.expectf(t, ok, "parse %s", s)
		testing.expectf(t, !web.is_private_or_restricted(addr), "allowed %s", s)
	}

	// A v4 whitelist entry permits the mapped spelling of the same host.
	w: web.Private_Whitelist
	web.whitelist_init(&w, context.allocator)
	defer web.whitelist_destroy(&w)
	ok2, _ := web.whitelist_parse(&w, []string{"10.0.0.0/8"})
	testing.expect(t, ok2, "whitelist parse")
	mapped, _ := web.parse_ip("::ffff:10.1.2.3")
	testing.expect(t, !web.should_block(mapped, &w), "mapped hits the v4 whitelist entry")
	plain, _ := web.parse_ip("10.1.2.3")
	testing.expect(t, !web.should_block(plain, &w), "plain whitelisted")
}

@(test)
web_ddg_snippets :: proc(t: ^testing.T) {
	body := strings.concatenate({
		"<h2>Results</h2>",
		"<a class=\"result__a\" href=\"//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa\">First</a>",
		"<a class=\"result__snippet\" href=\"#\">  The <b>first</b> result </a>",
		"<a class=\"result__a\" href=\"https://example.com/b\">Second</a>",
		// The redirect wrapper always appends its own params after the
		// uddg target — the extracted URL must stop at the separator.
		"<a class=\"result__a\" href=\"//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fc%3Fx%3D1&rut=12345\">Third</a>",
	}, context.temp_allocator)
	out := web.extract_ddg_results(body, 5, "q", context.temp_allocator)
	testing.expect(t, strings.contains(out, "1. First"), out)
	testing.expect(t, strings.contains(out, "The first result"), out)
	testing.expect(t, strings.contains(out, "2. Second"), out)
	testing.expect(t, strings.contains(out, "https://example.com/c?x=1"), out)
	testing.expect(t, !strings.contains(out, "rut="), out)
	testing.expect(t, !strings.contains(out, "<b>"), out)
}

// Admission control: a full slot set fails fast with .Busy, an already
// cancelled request never consumes a slot, and freeing a slot admits the
// next fetch (which then proceeds to the transport — here the dead
// loopback proxy, so the test stays offline).
@(test)
web_fetch_admission_cap :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	f: web.Fetcher
	ok, bad := web.fetcher_init(&f, "http://127.0.0.1:9", "markdown", 65536, nil, nil, false, a)
	testing.expectf(t, ok, "fetcher init: %s", bad)
	if !ok {
		return
	}
	defer web.fetcher_destroy(&f)
	testing.expect(t, f.has_slots, "slots exist")

	// Fill every slot: the next fetch must answer .Busy immediately.
	for i := 0; i < web.FETCH_ADMISSION_CAP; i += 1 {
		testing.expect(t, chan.try_send(f.slots, 0), "fill slot")
	}
	_, kind, msg := web.fetcher_fetch(&f, "https://example.com/", 0, nil, a)
	testing.expect(t, kind == .Busy, "full slots answer busy")
	testing.expect(t, strings.contains(msg, "busy"), msg)
	testing.expect(t, web.web_err_platform_kind(.Busy) == .Retryable, "busy maps retryable")

	// The cancellation pre-flight wins even with a full slot set.
	root := new(platform.Cancel_Token, a)
	platform.token_init_root(root)
	platform.token_fire(root, .Cancelled)
	_, ckind, _ := web.fetcher_fetch(&f, "https://example.com/", 0, root, a)
	testing.expect(t, ckind == .Cancelled, "cancelled beats busy")

	// Freeing one slot admits the next fetch; it runs to the transport
	// and fails at the dead proxy instead of at admission.
	_, _ = chan.recv(f.slots)
	_, nkind, _ := web.fetcher_fetch(&f, "https://example.com/", 0, nil, a)
	testing.expectf(t, nkind != .Busy, "freed slot admits the fetch (kind %v)", nkind)
}

// --- round 4: proxy/origin parsing, family folding, redaction order ----------

@(test)
web_split_host_port :: proc(t: ^testing.T) {
	// The single authority parser behind validate_proxy, proxy_host, and
	// the origin-pinning check: bracketed IPv6 literals carry their port,
	// and an unbracketed multi-colon form is malformed.
	cases := []struct {
		input: string,
		host: string,
		port: string,
		ok:   bool,
	}{
		{input = "example.com", host = "example.com", port = "", ok = true},
		{input = "example.com:8080", host = "example.com", port = "8080", ok = true},
		{input = "example.com:", host = "example.com", port = "", ok = true},
		{input = "[::1]:8080", host = "::1", port = "8080", ok = true},
		{input = "[::1]", host = "::1", port = "", ok = true},
		{input = "[::1]:", host = "", port = "", ok = false},
		{input = "[::1]x", host = "", port = "", ok = false},
		{input = "[::1", host = "", port = "", ok = false},
		{input = "host:80:90", host = "", port = "", ok = false},
		{input = "::1", host = "", port = "", ok = false},
	}
	for c in cases {
		h, p, ok := web.split_host_port(c.input)
		testing.expectf(t, ok == c.ok && h == c.host && p == c.port, "split %q: got (%q, %q, %v)", c.input, h, p, ok)
	}
}

@(test)
web_proxy_url_validation :: proc(t: ^testing.T) {
	// The bracketed IPv6 literal takes the same port validation as the
	// bare host:port form (it used to skip the port entirely), and control
	// characters are refused like urlguard_validate_url refuses them.
	good := []string{
		"http://proxy.example:8080",
		"http://proxy.example",
		"http://[::1]:8080",
		"http://[::1]",
		"socks5h://user:pass@127.0.0.1:1080",
	}
	for p in good {
		testing.expectf(t, web.validate_proxy(p, context.allocator) == "", "proxy %s", p)
	}
	bad := []struct {
		proxy: string,
		want:  string,
	}{
		{proxy = "http://[::1]:abc", want = "invalid proxy port"},
		{proxy = "http://[::1]:99999", want = "invalid proxy port"},
		{proxy = "http://[::1]:0", want = "invalid proxy port"},
		{proxy = "http://[::1]:", want = "invalid proxy URL: malformed host or port"},
		{proxy = "http://::1:8080", want = "invalid proxy URL: malformed host or port"},
		{proxy = "http://host:80:90", want = "invalid proxy URL: malformed host or port"},
		{proxy = "socks5://\n127.0.0.1:1080", want = "invalid proxy URL: control characters are not allowed"},
	}
	for c in bad {
		got := web.validate_proxy(c.proxy, context.allocator)
		testing.expectf(t, got == c.want, "proxy %q: got %q", c.proxy, got)
	}
	// proxy_host and validate_proxy share the one parser now: both forms
	// resolve to the same host string.
	testing.expect_value(t, web.proxy_host("http://[2001:db8::1]:8080"), "2001:db8::1")
	testing.expect_value(t, web.proxy_host("http://proxy.example:8080"), "proxy.example")
}

@(test)
web_origin_pinning :: proc(t: ^testing.T) {
	// url_origin strips userinfo/port/path/query and lowercases; the
	// origin_allows predicate keeps search-provider credentials on the
	// configured scheme+host (case folds, port and userinfo are not
	// pinned, a host change or scheme downgrade is refused).
	s, h, ok := web.url_origin("https://User@API.Search.Brave.com:443/res?q=1")
	testing.expect(t, ok, "origin parse")
	testing.expect_value(t, s, "https")
	testing.expect_value(t, h, "api.search.brave.com")

	testing.expect(t, web.origin_allows("https", "api.search.brave.com", "https://api.search.brave.com/v2/hop"), "same origin")
	testing.expect(t, web.origin_allows("https", "api.search.brave.com", "HTTPS://API.SEARCH.BRAVE.COM:8443/x"), "case+port fold")
	testing.expect(t, web.origin_allows("https", "api.search.brave.com", "https://token@api.search.brave.com/y"), "userinfo stripped")
	testing.expect(t, !web.origin_allows("https", "api.search.brave.com", "https://evil.example.com/hop"), "host change refused")
	testing.expect(t, !web.origin_allows("https", "api.search.brave.com", "http://api.search.brave.com/hop"), "scheme downgrade refused")
	testing.expect(t, !web.origin_allows("https", "api.search.brave.com", "notaurl"), "unparseable refused")
}

@(test)
web_addr_equal_family_fold :: proc(t: ^testing.T) {
	// The comparison length no longer depends on operand order: a mapped
	// v6 spelling equals its v4 form in BOTH directions, and a native v6
	// never equals a v4.
	v4, ok1 := web.parse_ip("10.0.0.1")
	mapped, ok2 := web.parse_ip("::ffff:10.0.0.1")
	native, ok3 := web.parse_ip("2606:4700::1111")
	testing.expect(t, ok1 && ok2 && ok3, "parse")
	testing.expect(t, web.addr_equal(v4, mapped), "v4 vs mapped")
	testing.expect(t, web.addr_equal(mapped, v4), "mapped vs v4")
	testing.expect(t, !web.addr_equal(v4, native), "v4 vs native v6")
	testing.expect(t, !web.addr_equal(native, v4), "native v6 vs v4")

	// The proxy-hop bypass therefore matches across family spellings: a
	// resolved-v4 proxy dialed through a mapped v6 form stays reachable.
	g: web.Socket_Guard
	append(&g.proxy_hops, v4)
	defer delete(g.proxy_hops)
	testing.expect(t, web.proxy_hop(&g, mapped), "proxy hop matches mapped spelling")
	testing.expect(t, !web.proxy_hop(&g, native), "unrelated v6 no match")
}

@(test)
web_fetch_url_control_chars :: proc(t: ^testing.T) {
	// The pre-request gate refuses control bytes before anything parses
	// the URL — the same refusal urlguard_validate_url applies.
	_, msg := web.fetch_check_url("http://example.com/\n.evil.com/", nil, true)
	testing.expect_value(t, msg, "URL contains control characters")
	_, msg2 := web.fetch_check_url("http://example.com/ok", nil, true)
	testing.expect_value(t, msg2, "")
}

@(test)
web_redact_before_truncate :: proc(t: ^testing.T) {
	// Why fetch redacts BEFORE truncating: a token straddling the size
	// limit keeps its full shape only in the untruncated text — the
	// redactor matches (and removes) it there, while the truncated half
	// no longer matches the pattern and would survive redaction. The
	// scratch lives on an arena: redact returns the input view unchanged
	// when nothing matches, so per-string deletes are not well-defined.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	r: safety.Redactor
	safety.redactor_init(&r, context.allocator)
	defer safety.redactor_destroy(&r)

	body := strings.clone("prefix-prefix-prefix-prefix-prefix-ghp_AAAA10BBBB20CCCC30DDDD40EEEE50", a)

	full, ferr := safety.redact(&r, body, a)
	testing.expectf(t, ferr == nil, "redact full: %s", platform.err_message(ferr, context.temp_allocator))
	testing.expect(t, !strings.contains(full, "ghp_"), "full text redacted")

	// Cut mid-token (35 bytes of prefix + 10 bytes of token): the pattern
	// needs 10+ token bytes AFTER the ghp_ prefix, so the half no longer
	// matches — truncating first would leak exactly this fragment.
	half, herr := safety.redact(&r, body[:45], a)
	testing.expectf(t, herr == nil, "redact half: %s", platform.err_message(herr, context.temp_allocator))
	testing.expect(t, strings.contains(half, "ghp_AAAA10"), "truncated half survives — hence redact first")
}

@(test)
web_html_post_process_nil_post :: proc(t: ^testing.T) {
	// The fallback (nil post) procs live for the whole call: the five
	// regex passes actually run — the block-scoped destroy used to zero
	// them at the `if` exit and every pass silently no-opped, so excess
	// blank lines survived the nil-post path. The scratch runs on an
	// arena like every production caller (each replace pass allocates;
	// only the final string escapes).
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	out := web.html_post_process("a\n\n\n\nb\n\n\n\n\nc  \n", mem.dynamic_arena_allocator(&arena), nil)
	testing.expect_value(t, out, "a\n\nb\n\nc")
}

// The honest user agent identifies the tool by name, version, and this
// repository's URL — the contact address site operators use to judge the
// bot. It once carried an unrelated hard-coded GitHub handle instead of
// the project's remote; this pins the single-source composition and the
// actual repository.
@(test)
web_honest_user_agent_cites_the_project :: proc(t: ^testing.T) {
	expect := "aubade/" + version.AUBADE_VERSION + " (+" + version.AUBADE_REPO_URL + "; AI coding assistant)"
	testing.expect_value(t, web.USER_AGENT_HONEST, expect)
	testing.expect(
		t,
		strings.contains(web.USER_AGENT_HONEST, "github.com/tagumasa/aubade"),
		"the honest user agent must cite this repository's remote",
	)
}
