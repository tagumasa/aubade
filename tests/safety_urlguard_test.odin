// Tests for src/safety/urlguard: blocked IPs and their alternate encodings
// (integer/hex/octal/mixed-notation/IPv4-mapped IPv6), link-local ranges,
// host and URL-level patterns, validate errors, user patterns, and secret
// detection through the facade.
package tests

import "core:strings"
import "core:testing"
import "src:safety"

urlguard_setup :: proc(t: ^testing.T) -> ^safety.URL_Guard {
	ug := new(safety.URL_Guard, context.allocator)
	safety.urlguard_init(ug, context.allocator)
	return ug
}

// Every hardcoded table must load in full: a failing regex would silently
// un-block its host/URL class or disable secret detection (the loader
// logs; these counts turn a pattern regression into a CI failure).
@(test)
urlguard_default_rules_all_load :: proc(t: ^testing.T) {
	ug := urlguard_setup(t)
	defer free(ug, context.allocator)
	defer safety.urlguard_destroy(ug)

	testing.expect_value(t, len(ug.host_patterns), 8)
	testing.expect_value(t, len(ug.url_patterns), 1)
	testing.expect_value(t, len(ug.blocked_ips), 3)
	testing.expect(t, ug.is_vendor_ready, "vendor token pattern must compile")
}

@(test)
urlguard_blocks_defaults :: proc(t: ^testing.T) {
	ug := urlguard_setup(t)
	defer free(ug, context.allocator)
	defer safety.urlguard_destroy(ug)

	cases := [12]struct{url: string, blocked: bool}{
		{url = "http://169.254.169.254/latest/meta-data/", blocked = true},
		{url = "http://169.254.170.2/task", blocked = true},
		{url = "http://100.100.100.200/", blocked = true},
		{url = "http://metadata.google.internal/", blocked = true},
		{url = "http://metadata.goog/", blocked = true},
		{url = "https://webhook.site/test", blocked = true},
		{url = "https://requestbin.com/test", blocked = true},
		{url = "https://pipedream.net/test", blocked = true},
		{url = "https://pastebin.com/raw/abc", blocked = true},
		{url = "data:text/html;base64,PHNjcmlwdD4=", blocked = true},
		{url = "https://example.com/api", blocked = false},
		{url = "https://github.com/user/repo", blocked = false},
	}
	for i in 0..<len(cases) {
		blocked, _ := safety.urlguard_is_blocked(ug, cases[i].url)
		testing.expectf(t, blocked == cases[i].blocked, "is_blocked(%s) = %v, want %v", cases[i].url, blocked, cases[i].blocked)
	}
}

@(test)
urlguard_blocks_alternate_ip_encodings :: proc(t: ^testing.T) {
	ug := urlguard_setup(t)
	defer free(ug, context.allocator)
	defer safety.urlguard_destroy(ug)

	// 169.254.169.254 = 2852039166 = 0xa9fea9fe = 0o25177524776 (leading-zero octal)
	encodings := [11]string{
		"http://2852039166/latest/meta-data/",
		"http://0xa9fea9fe/latest/meta-data/",
		"http://0XA9FEA9FE/latest/meta-data/",
		"http://025177524776/latest/meta-data/",
		"http://0xA9.0xFE.169.254/latest/meta-data/",
		"http://0251.0376.0251.0376/latest/meta-data/",
		"http://[::ffff:169.254.169.254]/latest/meta-data/",
		"http://metadata.google.internal:80/",
		"http://user:pass@metadata.google.internal/",
		"http://METADATA.GOOGLE.INTERNAL/",
		"http://sub.pastebin.com/raw",
	}
	for i in 0..<len(encodings) {
		blocked, reason := safety.urlguard_is_blocked(ug, encodings[i])
		testing.expectf(t, blocked, "encoding bypass not blocked: %s", encodings[i])
		_ = reason
	}

	// Non-blocked plain hosts and private-but-not-link-local addresses stay
	// reachable; the v4-compatible IPv6 form is not link-local.
	allowed := [5]string{
		"http://192.168.1.1/",
		"http://10.0.0.1/",
		"http://[::1]/",
		"http://[fe00::1]/",
		"http://example.com/",
	}
	for i in 0..<len(allowed) {
		blocked, _ := safety.urlguard_is_blocked(ug, allowed[i])
		testing.expectf(t, !blocked, "wrongly blocked: %s", allowed[i])
	}

	// Link-local unicast and multicast are blocked wholesale.
	link_local := [5]string{
		"http://169.254.0.1/",
		"http://169.254.255.254/",
		"http://224.0.0.1/",
		"http://[fe80::1]/",
		"http://[ff12::1]/",
	}
	for i in 0..<len(link_local) {
		blocked, reason := safety.urlguard_is_blocked(ug, link_local[i])
		testing.expectf(t, blocked && strings.contains(reason, "link-local"), "link-local not blocked: %s", link_local[i])
	}
}

// Decimal components over 255 are outside the dotted-quad grammar, not
// alternate encodings: u8-wrap would read "425.510.0.1" back as the
// link-local 169.254.0.1 and refuse an unresolvable host with the cloud
// metadata message.
@(test)
urlguard_out_of_range_decimal_components_not_addresses :: proc(t: ^testing.T) {
	ug := urlguard_setup(t)
	defer free(ug, context.allocator)
	defer safety.urlguard_destroy(ug)

	cases := [4]string{
		"http://425.510.0.1/",
		"http://999.254.169.254/",
		"http://169.999.169.254/",
		"http://169.254.425.510/",
	}
	for c in cases {
		blocked, reason := safety.urlguard_is_blocked(ug, c)
		testing.expectf(t, !blocked, "out-of-range component misparsed into a block: %s (%s)", c, reason)
	}
}

@(test)
urlguard_malformed_and_hostless :: proc(t: ^testing.T) {
	ug := urlguard_setup(t)
	defer free(ug, context.allocator)
	defer safety.urlguard_destroy(ug)

	// IsBlocked stays silent (not-blocked) for malformed/hostless URLs.
	silent := [4]string{
		"not a url at all",
		"/relative/path",
		"example.com/path",
		"ftp://",
	}
	for i in 0..<len(silent) {
		blocked, _ := safety.urlguard_is_blocked(ug, silent[i])
		testing.expectf(t, !blocked, "malformed URL must not be blocked: %s", silent[i])
	}

	// ValidateURL rejects them deterministically.
	ok, msg := safety.urlguard_validate_url(ug, "not a url at all")
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(msg, "has no host component"))

	ok, msg = safety.urlguard_validate_url(ug, "http://example.com/\x01")
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(msg, "invalid control character"))

	ok, msg = safety.urlguard_validate_url(ug, "data:text/plain,hello")
	testing.expectf(t, ok && msg == "", "data URL must validate: %s", msg)

	// Schemes compare case-insensitively (url_scheme returns a view of
	// the input, so the comparison must fold case itself).
	ok, msg = safety.urlguard_validate_url(ug, "DATA:text/plain,hello")
	testing.expectf(t, ok && msg == "", "uppercase data URL must validate: %s", msg)

	ok, msg = safety.urlguard_validate_url(ug, "HTTP://example.com/\x01")
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(msg, "invalid control character"))

	ok, msg = safety.urlguard_validate_url(ug, "http://169.254.169.254/")
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(msg, "safety: URL blocked"))
}

@(test)
urlguard_add_blocked_pattern :: proc(t: ^testing.T) {
	ug := urlguard_setup(t)
	defer free(ug, context.allocator)
	defer safety.urlguard_destroy(ug)

	ok, err := safety.urlguard_add_blocked_pattern(ug, "evil\\.corp", "test pattern")
	testing.expectf(t, ok && err == "", "add pattern: %s", err)
	blocked, reason := safety.urlguard_is_blocked(ug, "https://evil.corp/steal")
	testing.expect(t, blocked)
	testing.expect(t, strings.contains(reason, "test pattern"))

	ok, err = safety.urlguard_add_blocked_pattern(ug, "[invalid", "invalid regex")
	testing.expect(t, !ok)
	testing.expect(t, err != "")
}

@(test)
urlguard_check_for_secrets :: proc(t: ^testing.T) {
	ug := urlguard_setup(t)
	defer free(ug, context.allocator)
	defer safety.urlguard_destroy(ug)

	flagged, _ := safety.urlguard_check_for_secrets(ug, "https://api?token=sk-ABCDEFGHIJKLMNOP1234")
	testing.expect(t, flagged)
	flagged, _ = safety.urlguard_check_for_secrets(ug, "https://example.com?token=ghp_ABCDEFGHIJKLMNOPQR")
	testing.expect(t, flagged)
	flagged, _ = safety.urlguard_check_for_secrets(ug, "https://example.com/api")
	testing.expect(t, !flagged)

	// Percent-encoded tokens are caught after unescaping.
	flagged, _ = safety.urlguard_check_for_secrets(ug, "https://example.com/?t=%73%6b-ABCDEFGHIJKLMNOP1234")
	testing.expect(t, flagged)

	// Invalid escapes keep the raw form (still checked once, no error).
	flagged, _ = safety.urlguard_check_for_secrets(ug, "https://example.com/%zz")
	testing.expect(t, !flagged)
}

@(test)
urlguard_facade_wiring :: proc(t: ^testing.T) {
	sc := new(safety.Safety_Checker, context.allocator)
	defer free(sc, context.allocator)
	defer safety.safety_checker_destroy(sc)
	safety.safety_checker_init(sc, context.allocator)

	blocked, msg := safety.check_url(sc, "http://169.254.169.254/")
	testing.expect(t, blocked)
	testing.expect(t, strings.has_prefix(msg, "safety: URL blocked: "))

	blocked, _ = safety.check_url(sc, "http://example.com/")
	testing.expect(t, !blocked)

	flagged, secret_msg := safety.check_url_for_secrets(sc, "https://api?token=sk-ABCDEFGHIJKLMNOP1234")
	testing.expect(t, flagged)
	testing.expect(t, strings.contains(secret_msg, "API key"))
}

@(test)
urlguard_refuses_unparseable_address_like_hosts :: proc(t: ^testing.T) {
	// Trailing-dot and zone-id spellings fail both address parsers; before
	// the fail-closed rule they skipped the blocked-IP and link-local
	// tables entirely.
	ug := urlguard_setup(t)
	defer free(ug, context.allocator)
	defer safety.urlguard_destroy(ug)

	// The unbracketed "fe80::1%eth0" spelling is not a valid URI authority
	// (no fetch layer accepts it), so the reachable zone-id form is the
	// bracketed percent-encoded one.
	cases := [3]string{
		"http://169.254.169.254./latest/meta-data/",
		"http://169.254.170.2./task",
		"http://[fe80::1%25eth0]/",
	}
	for c in cases {
		blocked, reason := safety.urlguard_is_blocked(ug, c)
		testing.expectf(t, blocked, "%s must be refused: %s", c, reason)
	}
}
