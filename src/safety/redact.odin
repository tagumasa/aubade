// Content redaction: regex rules scrub API keys, bearer tokens, private
// keys, environment-variable secrets, JSON secrets, database connection
// strings, JWTs, and URL credentials/query parameters from tool output.
// Input is capped at MAX_REDACT_INPUT_BYTES, which mirrors the web
// fetcher's hard body limit.
package safety

import "core:mem"
import "core:strings"
import "core:sync"
import "src:platform"
import "src:regex"
import "src:util"

// The size cap mirrors the web fetcher's hard body limit: redaction runs
// on the extracted text of a fetched page, and the fetcher truncates only
// AFTER redaction, so every legitimate input fits. An oversize input
// fails closed — a byte-truncating cap here would let a secret
// straddling the cut survive unredacted in the returned prefix.
MAX_REDACT_INPUT_BYTES :: 50 << 20

VENDOR_PREFIX_PATTERNS :: []string{
	`sk-[A-Za-z0-9_-]{10,}`,
	`ghp_[A-Za-z0-9]{10,}`,
	`github_pat_[A-Za-z0-9_]{10,}`,
	`gho_[A-Za-z0-9]{10,}`,
	`ghs_[A-Za-z0-9]{10,}`,
	`ghr_[A-Za-z0-9]{10,}`,
	`xox[baprs]-[A-Za-z0-9-]{10,}`,
	`AIza[A-Za-z0-9_-]{30,}`,
	`AKIA[A-Z0-9]{16}`,
	`sk_live_[A-Za-z0-9]{10,}`,
	`sk_test_[A-Za-z0-9]{10,}`,
	`SG\.[A-Za-z0-9_-]{10,}`,
	`hf_[A-Za-z0-9]{10,}`,
	`npm_[A-Za-z0-9]{10,}`,
	`gsk_[A-Za-z0-9]{10,}`,
	`pplx-[A-Za-z0-9]{10,}`,
}

SENSITIVE_QUERY_PARAMS :: []string{
	"access_token",
	"refresh_token",
	"id_token",
	"token",
	"api_key",
	"apikey",
	"client_secret",
	"password",
	"auth",
	"jwt",
	"secret",
	"key",
	"code",
	"signature",
	"x-amz-signature",
}

Redact_Rule :: struct {
	name:    string,
	re:      regex.Regex,
	replace: proc(subs: []string, a: mem.Allocator) -> string,
}

Redactor :: struct {
	mu:        sync.Mutex,
	rules:     [dynamic]Redact_Rule,
	allocator: mem.Allocator,
}

redactor_init :: proc(r: ^Redactor, a := context.allocator) {
	r.rules = make([dynamic]Redact_Rule, 0, 9, a)
	r.allocator = a
	redactor_load_defaults(r)
}

redactor_destroy :: proc(r: ^Redactor) {
	for rule in r.rules {
		re := rule.re
		regex.regex_destroy(&re)
	}
	delete(r.rules)
	r.rules = nil
}

// redact applies every rule in order; oversize input is refused outright.
// Fails closed: a rule that exhausts its regex match budget stops the pass
// mid-text, and the half-redacted result is never returned — the error
// tells the caller to refuse the output instead of leaking whatever the
// stopped pass left unscrubbed (scratch from the failed pass dies with the
// caller's request arena). The whole pass holds the mutex: each rule's
// compiled Regex matches through its shared PCRE2 match_data (one thread
// at a time), and the daemon's web pool redacts concurrently through one
// checker.
redact :: proc(r: ^Redactor, input: string, a := context.allocator) -> (out: string, err: platform.Err) {
	if input == "" {
		return input, nil
	}
	// Oversize fails closed (same stance as the rule-budget path below):
	// truncating here would hand back a prefix whose straddling secrets
	// never met a rule.
	if len(input) > MAX_REDACT_INPUT_BYTES {
		return "", platform.Wrapped{
			kind = .Internal,
			msg  = "redaction incomplete: input exceeds the redactor's size cap",
		}
	}
	text := input
	sync.mutex_lock(&r.mu)
	for _, i in r.rules {
		re := r.rules[i].re
		text = replace_all_submatch(&re, text, r.rules[i].replace, a)
		if re.limit_hit {
			sync.mutex_unlock(&r.mu)
			return "", platform.Wrapped{
				kind = .Internal,
				msg = strings.concatenate({
					"redaction incomplete: rule ", r.rules[i].name,
					" ran out of regex budget; refusing to emit partially redacted content",
				}, context.temp_allocator),
			}
		}
	}
	sync.mutex_unlock(&r.mu)
	return text, nil
}

// redactor_add_pattern registers a user pattern; matches become
// "[REDACTED]".
redactor_add_pattern :: proc(r: ^Redactor, pattern: string) -> platform.Err {
	// The rule outlives the call: the compiled regex rides the
	// redactor's allocator, never the ambient temp.
	re, err := regex.compile_regex(pattern, r.allocator)
	if err != nil {
		return err
	}
	sync.mutex_lock(&r.mu)
	append(&r.rules, Redact_Rule{name = "user", re = re, replace = replace_redacted})
	sync.mutex_unlock(&r.mu)
	return nil
}

// --- submatch replacement engine ----------------------------------------------

// replace_all_submatch rewrites every match of re through fn, which sees
// the capture groups of its own match (subs[0] is the whole match).
replace_all_submatch :: proc(
	re:      ^regex.Regex,
	text:    string,
	fn:      proc(subs: []string, a: mem.Allocator) -> string,
	a:       mem.Allocator,
) -> string {
	ranges := regex.regex_find_all(re, text, context.temp_allocator)
	if len(ranges) == 0 {
		return text
	}
	buf := make([dynamic]u8, 0, len(text), a)
	last_end := 0
	for m in ranges {
		append(&buf, text[last_end:m.start])
		capture_ranges := regex.regex_captures_at(re, text, m.start, context.temp_allocator)
		subs := subs_slice(text, capture_ranges, context.temp_allocator)
		append(&buf, fn(subs, context.temp_allocator))
		last_end = m.end
	}
	append(&buf, text[last_end:])
	return string(buf[:])
}

// subs_slice renders capture ranges as submatch strings; unset groups
// come out as "".
subs_slice :: proc(text: string, ranges: []regex.Match_Range, a: mem.Allocator) -> []string {
	out := make([]string, len(ranges), a)
	for r, i in ranges {
		if r.start >= 0 && r.end >= r.start {
			out[i] = text[r.start:r.end]
		} else {
			out[i] = ""
		}
	}
	return out
}

replace_redacted :: proc(subs: []string, a: mem.Allocator) -> string {
	return "[REDACTED]"
}

replace_bearer :: proc(subs: []string, a: mem.Allocator) -> string {
	if len(subs) >= 2 {
		return strings.concatenate({subs[1], "[REDACTED]"}, a)
	}
	return "[REDACTED]"
}

replace_private_key :: proc(subs: []string, a: mem.Allocator) -> string {
	return "[REDACTED PRIVATE KEY]"
}

replace_env_secret :: proc(subs: []string, a: mem.Allocator) -> string {
	// regex_captures_at materializes groups only up to the highest
	// participating one, so the branch is read length-first: a bare
	// value fills subs[4] (len 5), a single-quoted value ends at
	// subs[3], a double-quoted value at subs[2]. All-empty captures are
	// explicitly empty quoted values, whose quotes carry no information.
	if len(subs) >= 5 && subs[4] != "" {
		return strings.concatenate({subs[1], "=[REDACTED]"}, a)
	}
	if len(subs) >= 4 && subs[3] != "" {
		return strings.concatenate({subs[1], "='[REDACTED]'"}, a)
	}
	if len(subs) >= 3 {
		return strings.concatenate({subs[1], "=\"[REDACTED]\""}, a)
	}
	return "[REDACTED]"
}

replace_json_secret :: proc(subs: []string, a: mem.Allocator) -> string {
	if len(subs) >= 2 {
		return strings.concatenate({subs[1], ": \"[REDACTED]\""}, a)
	}
	return "[REDACTED]"
}

replace_db_connection :: proc(subs: []string, a: mem.Allocator) -> string {
	if len(subs) >= 4 {
		return strings.concatenate({subs[1], "[REDACTED]", subs[3]}, a)
	}
	return "[REDACTED]"
}

replace_jwt :: proc(subs: []string, a: mem.Allocator) -> string {
	return "[REDACTED]"
}

replace_url_userinfo :: proc(subs: []string, a: mem.Allocator) -> string {
	if len(subs) >= 3 {
		return strings.concatenate({subs[1], "://", subs[2], ":[REDACTED]@"}, a)
	}
	return "[REDACTED]"
}

replace_url_query :: proc(subs: []string, a: mem.Allocator) -> string {
	if len(subs) < 5 {
		// Fail closed like the sibling replacements: a malformed group
		// set must not hand back the raw, credential-bearing match.
		return "[REDACTED]"
	}
	fragment := ""
	if len(subs) >= 6 {
		fragment = subs[5]
	}
	return strings.concatenate({
		subs[1], "://", subs[2], subs[3], "?", redact_query_string(subs[4], a), fragment,
	}, a)
}

// --- query-string redaction -----------------------------------------------------

// redact_query_string swaps sensitive values for [REDACTED] in place. The
// reference round-trips through net/url and re-encodes the whole query
// (sorted keys); this manual pass keeps the caller's original order and
// encoding — same keys redacted, same [REDACTED] values, less reformatting.
redact_query_string :: proc(query: string, a: mem.Allocator) -> string {
	normalized, _ := strings.replace_all(query, ";", "&", context.temp_allocator)
	parts := strings.split(normalized, "&", context.temp_allocator)
	changed := false
	for p, i in parts {
		idx := strings.index(p, "=")
		if idx < 0 {
			continue
		}
		key := p[:idx]
		decoded := util.percent_decode(key, context.temp_allocator)
		lower := strings.to_lower(decoded, context.temp_allocator)
		for sensitive in SENSITIVE_QUERY_PARAMS {
			if lower == sensitive {
				parts[i] = strings.concatenate({key, "=[REDACTED]"}, context.temp_allocator)
				changed = true
				break
			}
		}
	}
	if !changed {
		return query
	}
	joined, _ := strings.join(parts, "&", a)
	return joined
}

// --- default rules ----------------------------------------------------------------

// compile_default_rule loads one hardcoded rule. A default pattern that
// fails to compile is a build regression, never something to skip
// quietly: the failure logs loudly, and the default-rule-count test turns
// it into a CI failure before it can ship.
compile_default_rule :: proc(
	r:       ^Redactor,
	name:    string,
	pattern: string,
	flags:   string,
	replace: proc(subs: []string, a: mem.Allocator) -> string,
) {
	// The rule outlives the call: the compiled regex rides the
	// redactor's allocator, never the ambient temp (a temp-backed rule
	// dangles after the next scratch reset, and the pcre2 free path
	// follows the compile-time allocator).
	re, err := regex.compile_regex_with_flags(pattern, flags, r.allocator)
	if err != nil {
		util.log_warning(strings.concatenate({
			"redactor: default rule ", name, " failed to compile and is INACTIVE: ",
			platform.err_message(err, context.temp_allocator),
		}, context.temp_allocator))
		return
	}
	append(&r.rules, Redact_Rule{name = name, re = re, replace = replace})
}

redactor_load_defaults :: proc(r: ^Redactor) {
	// vendor prefixes (one combined alternation)
	joined, _ := strings.join(VENDOR_PREFIX_PATTERNS, "|", context.temp_allocator)
	combined := strings.concatenate({"(", joined, ")"}, context.temp_allocator)
	compile_default_rule(r, "vendor_prefix", combined, "", replace_redacted)

	compile_default_rule(r, "bearer_token", `(Authorization:\s*Bearer\s+)(\S+)`, "i", replace_bearer)

	compile_default_rule(
		r, "private_key",
		`-----BEGIN[A-Z ]*PRIVATE KEY-----[\s\S]*?-----END[A-Z ]*PRIVATE KEY-----`,
		"", replace_private_key,
	)

	compile_default_rule(
		r, "env_secret",
		// The value is captured in exactly one of three branches —
		// double-quoted, single-quoted, or bare. The quoted classes span
		// whitespace (a multi-word secret must redact whole; a class that
		// stops at \s redacted only the first word and leaked the tail)
		// and the closing quote is optional so an unterminated value
		// still redacts to end of line.
		`([A-Z0-9_]{0,50}(?:API_?KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTH)[A-Z0-9_]{0,50})\s*=\s*(?:"([^"]*)["]?|'([^']*)['"]?|([^'"\s&]+))`,
		"i", replace_env_secret,
	)

	compile_default_rule(
		r, "json_secret",
		`("(?:api_?key|token|secret|password|access_token|refresh_token|bearer|secret_value|key_material)")\s*:\s*"([^"]+)"`,
		"i", replace_json_secret,
	)

	compile_default_rule(
		r, "db_connection_string",
		`((?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp)://[^:]+:)([^@]+)(@)`,
		"i", replace_db_connection,
	)

	compile_default_rule(r, "jwt", `eyJ[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_=-]{4,}){0,2}`, "", replace_jwt)

	compile_default_rule(
		r, "url_userinfo", `(https?|wss?|ftp)://([^/\s:@]+):([^/\s@]+)@`, "i", replace_url_userinfo,
	)

	compile_default_rule(
		r, "url_query_params",
		`(https?|wss?|ftp)://([^\s/?#]+)([^\s?#]*)\?([^\s#]+)(#[\S]*)?`,
		"i", replace_url_query,
	)
}

