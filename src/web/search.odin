// The web_search pipeline: provider resolution from the web config,
// round-robin API key pools, the five provider requests (Brave, Tavily,
// Perplexity, SearXNG, DuckDuckGo HTML), and the range-code mapping.
// Every provider goes through the same curl transport with the same SSRF
// guard, so the search path cannot reach private networks either.
package web

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:sync"

import "src:config"
import "src:jsonutil"
import "src:platform"
import "src:util"

SEARCH_TIMEOUT_MS :: 10_000
PERPLEXITY_TIMEOUT_MS :: 30_000
MAX_JSON_DECODE_BYTES :: 10 * 1024 * 1024

Provider_Kind :: enum {
	DuckDuckGo,
	Brave,
	Tavily,
	Perplexity,
	SearXNG,
}

provider_name :: proc(k: Provider_Kind) -> string {
	switch k {
	case .DuckDuckGo: return "duckduckgo"
	case .Brave:      return "brave"
	case .Tavily:     return "tavily"
	case .Perplexity: return "perplexity"
	case .SearXNG:    return "searxng"
	}
	return ""
}

// Provider_Settings is one provider's slice of the search options —
// the array-of-settings shape replaces a flat per-provider field
// fan-out (no five-arm switches to keep in sync; DuckDuckGo simply
// carries no keys and no base_url).
Provider_Settings :: struct {
	keys:     []string, // owned by the options' allocator when cloned
	base_url: string, // tavily/searxng only
	max:      int,
	enabled:  bool,
}

// Search_Options is the provider-facing projection of Web_Config.
Search_Options :: struct {
	provider:      string,
	providers:     [Provider_Kind]Provider_Settings,
	proxy:         string,
	allow_private: bool,
	whitelist:     []string,
}

AUTO_PRIMARY :: []Provider_Kind{.Perplexity, .Brave, .SearXNG, .Tavily}

search_provider_ready :: proc(opts: ^Search_Options, k: Provider_Kind) -> bool {
	switch k {
	case .DuckDuckGo:
		return opts.providers[.DuckDuckGo].enabled
	case .Brave:
		return opts.providers[.Brave].enabled && len(opts.providers[.Brave].keys) > 0
	case .Tavily:
		return opts.providers[.Tavily].enabled && len(opts.providers[.Tavily].keys) > 0
	case .Perplexity:
		return opts.providers[.Perplexity].enabled && len(opts.providers[.Perplexity].keys) > 0
	case .SearXNG:
		return opts.providers[.SearXNG].enabled && strings.trim_space(opts.providers[.SearXNG].base_url) != ""
	}
	return false
}

search_known_provider :: proc(name: string) -> bool {
	for k in Provider_Kind {
		if provider_name(k) == name {
			return true
		}
	}
	return false
}

// search_resolve picks the configured provider when it is ready, then
// the auto order, then DuckDuckGo. ok=false means no provider is
// configured at all.
search_resolve :: proc(opts: ^Search_Options) -> (Provider_Kind, bool) {
	name := strings.to_lower(strings.trim_space(opts.provider), context.temp_allocator)
	if name != "" && name != "auto" && search_known_provider(name) {
		for k in Provider_Kind {
			if provider_name(k) != name {
				continue
			}
			if search_provider_ready(opts, k) {
				return k, true
			}
		}
	}
	for k in AUTO_PRIMARY {
		if search_provider_ready(opts, k) {
			return k, true
		}
	}
	if search_provider_ready(opts, .DuckDuckGo) {
		return .DuckDuckGo, true
	}
	return .DuckDuckGo, false
}

// Searcher owns the resolved provider and its key pool state.
Searcher :: struct {
	client:      HTTP_Client,
	guard:       Socket_Guard,
	mu:          sync.Mutex,
	kind:        Provider_Kind,
	key_cursor:  int,
	max_results: int,
	opts:        Search_Options, // owned copies of the config strings
	allocator:   mem.Allocator,
	is_ready:    bool,
}

// search_options_clone deep-copies every string (and string slice) in the
// options into `a` — the counterpart free is search_options_free. The
// daemon builds the input on a scratch arena that dies when its proc
// returns, while the Searcher lives for the project's lifetime.
search_options_clone :: proc(opts: Search_Options, a := context.allocator) -> Search_Options {
	out := opts
	out.provider = strings.clone(opts.provider, a)
	for k in Provider_Kind {
		out.providers[k].keys = clone_strs(opts.providers[k].keys, a)
		if opts.providers[k].base_url != "" {
			out.providers[k].base_url = strings.clone(opts.providers[k].base_url, a)
		}
	}
	out.proxy = strings.clone(opts.proxy, a)
	out.whitelist = clone_strs(opts.whitelist, a)
	return out
}

// search_options_free releases a cloned options struct; it is a no-op on a
// zero-value Search_Options (nil slices, empty strings).
search_options_free :: proc(opts: Search_Options, a: mem.Allocator) {
	for k in Provider_Kind {
		free_strs(opts.providers[k].keys, a)
		if opts.providers[k].base_url != "" {
			delete(opts.providers[k].base_url, a)
		}
	}
	free_strs(opts.whitelist, a)
	if opts.provider != "" {
		delete(opts.provider, a)
	}
	if opts.proxy != "" {
		delete(opts.proxy, a)
	}
}

free_strs :: proc(list: []string, a: mem.Allocator) {
	for s in list {
		if s != "" {
			delete(s, a)
		}
	}
	if len(list) > 0 {
		delete(list, a)
	}
}

searcher_init :: proc(s: ^Searcher, opts: Search_Options, a := context.allocator) -> (ok: bool, bad_entry: string) {
	s^ = {}
	s.allocator = a
	// Own the option strings up front: the caller's copies (built on a
	// scratch arena in the daemon's web_for_project) die at its return.
	s.opts = search_options_clone(opts, a)
	http_client_init(&s.client)
	w_ok, bad := socket_guard_init(&s.guard, s.opts.whitelist, s.opts.allow_private, a)
	if !w_ok {
		return false, bad
	}
	if s.opts.proxy != "" {
		if err := validate_proxy(s.opts.proxy, context.temp_allocator); err != "" {
			return false, ""
		}
		socket_guard_allow_proxy(&s.guard, s.opts.proxy, a)
	}
	kind, resolved := search_resolve(&s.opts)
	if !resolved {
		return false, ""
	}
	s.kind = kind
	s.max_results = 10
	// Only lowered, never raised: 10 is the ceiling every provider caps
	// beneath.
	if m := s.opts.providers[kind].max; m > 0 && m < s.max_results {
		s.max_results = m
	}
	s.is_ready = true
	return true, ""
}

// searcher_destroy owns ALL teardown, including a partially-built searcher
// (the init failure paths only report — a second destroy of the same guard
// or options strings would double-free). http_client_destroy self-guards
// on is_initialized; search_options_free is a no-op on zero values.
searcher_destroy :: proc(s: ^Searcher) {
	http_client_destroy(&s.client)
	socket_guard_destroy(&s.guard)
	search_options_free(s.opts, s.allocator)
	s^ = {}
}

// next_key rotates through the pool: the counter advances per call so
// consecutive searches start at different keys.
next_key :: proc(s: ^Searcher, keys: []string) -> (string, bool) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if len(keys) == 0 {
		return "", false
	}
	s.key_cursor += 1
	idx := (s.key_cursor - 1) % len(keys)
	return keys[idx], true
}

// searcher_search runs one query through the resolved provider. The
// optional token is polled before the query, between key retries, and
// mid-transfer through the transport's xferinfo callback.
searcher_search :: proc(s: ^Searcher, query: string, count: int, range_code: string, token: ^platform.Cancel_Token = nil, a := context.allocator) -> (string, Web_Err, string) {
	if !s.is_ready {
		return "", .Not_Configured, "search provider is not configured"
	}
	q := strings.trim_space(query)
	if q == "" {
		return "", .Invalid_Url, "query is required"
	}
	code := range_code
	if err := normalise_range(&code, a); err != "" {
		return "", .Invalid_Url, err
	}
	if token != nil {
		if _, fired := platform.token_check(token); fired {
			return "", .Cancelled, "web search cancelled before request"
		}
	}
	effective := s.max_results
	if count > 0 && count <= 10 && count < effective {
		effective = count
	}
	switch s.kind {
	case .Brave:
		return brave_search(s, q, effective, code, token, a)
	case .Tavily:
		return tavily_search(s, q, effective, code, token, a)
	case .Perplexity:
		return perplexity_search(s, q, effective, code, token, a)
	case .SearXNG:
		return searxng_search(s, q, effective, code, token, a)
	case .DuckDuckGo:
		return duckduckgo_search(s, q, effective, code, token, a)
	}
	return "", .Not_Configured, "search provider is not configured"
}

normalise_range :: proc(code: ^string, a := context.allocator) -> string {
	// The lowered range is written back through `code^` and must outlive
	// this call: it comes from the caller's allocator. Acceptance and the
	// message both read RANGE_CODES — there is no second d/w/m/y spelling.
	c := strings.to_lower(strings.trim_space(code^), a)
	if _, ok := range_terms(c); ok || c == "" {
		code^ = c
		return ""
	}
	codes := make([dynamic]string, 0, 4, context.temp_allocator)
	defer delete(codes)
	for r in RANGE_CODES {
		append(&codes, r.code)
	}
	return strings.concatenate({"range must be one of: ", util.quoted_join(codes[:], ", ", "", a)}, a)
}

// The d/w/m/y freshness code each provider speaks, one row per code —
// the three lookups below read the same declaration instead of three
// parallel switches that must be edited in lockstep.
Range_Terms :: struct {
	brave: string,
	word:  string,
	ddg:   string,
}

RANGE_CODES :: []struct{code: string, terms: Range_Terms}{
	{code = "d", terms = {brave = "pd", word = "day",   ddg = "d"}},
	{code = "w", terms = {brave = "pw", word = "week",  ddg = "w"}},
	{code = "m", terms = {brave = "pm", word = "month", ddg = "m"}},
	{code = "y", terms = {brave = "py", word = "year",  ddg = "t"}},
}

range_terms :: proc(code: string) -> (Range_Terms, bool) {
	for r in RANGE_CODES {
		if r.code == code {
			return r.terms, true
		}
	}
	return {}, false
}

brave_freshness :: proc(code: string) -> string {
	terms, ok := range_terms(code)
	return terms.brave if ok else ""
}

range_word :: proc(code: string) -> string {
	terms, ok := range_terms(code)
	return terms.word if ok else ""
}

duckduckgo_date_filter :: proc(code: string) -> string {
	terms, ok := range_terms(code)
	return terms.ddg if ok else ""
}

// put_bytes appends a string's bytes onto a byte builder (the literal
// spread form does not parse on this compiler).
put_bytes :: proc(out: ^[dynamic]u8, s: string) {
	for i := 0; i < len(s); i += 1 {
		append(out, s[i])
	}
}

query_escape :: proc(s: string, a := context.allocator) -> string {
	hex := "0123456789ABCDEF"
	buf := make([dynamic]u8, 0, len(s) + 8, a)
	defer delete(buf)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		unreserved := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~'
		if unreserved {
			append(&buf, c)
			continue
		}
		if c == ' ' {
			append(&buf, '+')
			continue
		}
		append(&buf, '%')
		append(&buf, hex[c >> 4])
		append(&buf, hex[c & 0xF])
	}
	return strings.clone(transmute(string)(buf[:]), a)
}

query_unescape :: proc(s: string, a := context.allocator) -> string {
	buf := make([dynamic]u8, 0, len(s), a)
	defer delete(buf)
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '%' && i + 2 < len(s) {
			hi := util.hex_digit_value(s[i + 1])
			lo := util.hex_digit_value(s[i + 2])
			if hi >= 0 && lo >= 0 {
				append(&buf, u8(hi * 16 + lo))
				i += 3
				continue
			}
		}
		if c == '+' {
			append(&buf, ' ')
			i += 1
			continue
		}
		append(&buf, c)
		i += 1
	}
	return strings.clone(transmute(string)(buf[:]), a)
}

// retryable_status reports whether the next key should be tried for this
// HTTP status (rate limit, auth, forbidden, server errors).
retryable_status :: proc(status: int) -> bool {
	return status == 429 || status == 401 || status == 403 || status >= 500
}

truncate_for_error :: proc(s: string, a := context.allocator) -> string {
	if len(s) > 200 {
		return strings.concatenate({s[:200], "...(truncated)"}, a)
	}
	return strings.clone(s, a)
}

// --- providers ----------------------------------------------------------------

search_http :: proc(s: ^Searcher, req_in: HTTP_Request, token: ^platform.Cancel_Token, a := context.allocator) -> (HTTP_Response, Web_Err, string) {
	req := req_in
	req.token = token
	// Provider credentials (auth headers, API keys in the POST body) must
	// never be forwarded to a redirect target: every hop stays pinned to
	// the original scheme+host, and an off-origin 302 aborts the transfer.
	// A provider legitimately needing an off-origin hop would be a provider
	// misconfiguration — fail closed instead of leaking the keys.
	req.pin_origin = true
	return http_do(&s.client, req, &s.guard, a)
}

parse_json_body :: proc(body: string, a := context.allocator) -> (json.Value, bool) {
	if len(body) > MAX_JSON_DECODE_BYTES {
		return nil, false
	}
	// Depth sanity before the parser (same contract as every other
	// untrusted-JSON consumer): a deep provider response is a decode
	// failure, never a stack-exhaustion crash.
	if !util.json_sanity_ok(transmute([]u8)body) {
		return nil, false
	}
	v, err := json.parse_string(body, allocator = context.temp_allocator)
	if err != .None {
		return nil, false
	}
	return v, true
}

// render_results shapes one provider's JSON results into the shared
// listing: "Results for: <query><suffix>" then "N. title\n   link"
// lines, each with the optional third desc_key line, joined by
// newlines. count caps the lines (pass len(results) to keep all).
render_results :: proc(
	results: []json.Value,
	count:    int,
	query:    string,
	suffix:   string,
	desc_key: string,
	a := context.allocator,
) -> string {
	out := make([dynamic]string, 0, count + 1, a)
	defer delete(out)
	append(&out, strings.concatenate({"Results for: ", query, suffix}, a))
	n := len(results)
	if n > count {
		n = count
	}
	for i := 0; i < n; i += 1 {
		title, _ := obj_str(results[i], "title")
		link, _ := obj_str(results[i], "url")
		desc, _ := obj_str(results[i], desc_key)
		append(&out, strings.concatenate({
			util.int_to_dec(i + 1, a), ". ", title, "\n   ", link,
		}, a))
		if desc != "" {
			append(&out, strings.concatenate({"   ", desc}, a))
		}
	}
	joined, _ := strings.join(out[:], "\n", a)
	return joined
}

// Attempt_Outcome classifies one keyed attempt for keys_retry_search.
Attempt_Outcome :: enum {
	Answered,  // the attempt produced the final answer (success or terminal failure)
	Retryable, // this key failed; try the next one
}

// Key_Attempt is one provider's per-key attempt: build the request around
// `key`, run it, and classify the outcome. Odin has no closures, so the
// per-provider context rides `user`.
Key_Attempt :: proc(
	s:      ^Searcher,
	key:    string,
	user:   rawptr,
	token:  ^platform.Cancel_Token,
	a := context.allocator,
) -> (out: string, kind: Web_Err, msg: string, outcome: Attempt_Outcome)

// keys_retry_search drives the round-robin key retry loop shared by the
// keyed providers (Brave, Tavily, Perplexity): each attempt re-checks
// the token, takes the next key, and hands it to the provider's attempt
// proc. An answered attempt ends the loop as-is; a retryable failure
// moves to the next key; exhausting the pool reports the last error.
keys_retry_search :: proc(
	s:       ^Searcher,
	keys:    []string,
	attempt: Key_Attempt,
	user:    rawptr,
	token:   ^platform.Cancel_Token,
	a := context.allocator,
) -> (string, Web_Err, string) {
	last_err := ""
	last_kind := Web_Err.Provider_Error
	for i := 0; i < len(keys); i += 1 {
		if token != nil {
			if _, fired := platform.token_check(token); fired {
				return "", .Cancelled, "web search cancelled"
			}
		}
		key, ok := next_key(s, keys)
		if !ok {
			break
		}
		out, kind, msg, outcome := attempt(s, key, user, token, a)
		switch outcome {
		case .Answered:
			return out, kind, msg
		case .Retryable:
			last_err = msg
			last_kind = kind
		}
	}
	if last_err == "" {
		last_err = "no API key provided"
	}
	return "", last_kind, strings.concatenate({"all api keys failed, last error: ", last_err}, a)
}

brave_search :: proc(s: ^Searcher, query: string, count: int, range_code: string, token: ^platform.Cancel_Token, a := context.allocator) -> (string, Web_Err, string) {
	esc := query_escape(query, context.temp_allocator)
	url := strings.concatenate({
		"https://api.search.brave.com/res/v1/web/search?q=", esc,
		"&count=", util.int_to_dec(count, context.temp_allocator),
	}, context.temp_allocator)
	if freshness := brave_freshness(range_code); freshness != "" {
		url = strings.concatenate({url, "&freshness=", query_escape(freshness, context.temp_allocator)}, context.temp_allocator)
	}
	ctx := Brave_Ctx{url = url, query = query, count = count}
	return keys_retry_search(s, s.opts.providers[.Brave].keys, brave_attempt, &ctx, token, a)
}

Brave_Ctx :: struct {
	url:   string,
	query: string,
	count: int,
}

brave_attempt :: proc(s: ^Searcher, key: string, user: rawptr, token: ^platform.Cancel_Token, a := context.allocator) -> (out: string, kind: Web_Err, msg: string, outcome: Attempt_Outcome) {
	c := cast(^Brave_Ctx)user
	accept_h: HTTP_Header
	accept_h.name = "Accept"
	accept_h.value = "application/json"
	token_h: HTTP_Header
	token_h.name = "X-Subscription-Token"
	token_h.value = key
	headers := make([dynamic]HTTP_Header, 0, 2, context.temp_allocator)
	append(&headers, accept_h)
	append(&headers, token_h)
	req := HTTP_Request{
		url = c.url,
		headers = headers[:],
		timeout_ms = SEARCH_TIMEOUT_MS,
		proxy = s.opts.proxy,
		max_bytes = MAX_JSON_DECODE_BYTES,
	}
	res, err_kind, err := search_http(s, req, token, a)
	if err_kind != .None {
		if err_kind == .Cancelled {
			return "", .Cancelled, err, .Answered
		}
		return "", err_kind, err, .Retryable
	}
	if res.status != 200 {
		status_err := strings.concatenate({
			"API error (status ", util.int_to_dec(res.status, a), "): ",
			truncate_for_error(transmute(string)res.body, a),
		}, a)
		if retryable_status(res.status) {
			return "", .Provider_Error, status_err, .Retryable
		}
		return "", .Provider_Error, status_err, .Answered
	}
	v, ok2 := parse_json_body(transmute(string)res.body)
	if !ok2 {
		return "", .Provider_Error, "failed to parse response", .Answered
	}
	web_val, found := jsonutil.obj_get(v, "web")
	results, rok := array_field(web_val, "results")
	if !found || !rok || len(results) == 0 {
		return strings.concatenate({"No results for: ", c.query}, a), .None, "", .Answered
	}
	return render_results(results, c.count, c.query, "", "description", a), .None, "", .Answered
}

obj_str :: proc(v: json.Value, key: string) -> (string, bool) {
	if v == nil {
		return "", false
	}
	if val, ok := jsonutil.obj_get(v, key); ok {
		if s, sok := val.(string); sok {
			return s, true
		}
	}
	return "", false
}

tavily_search :: proc(s: ^Searcher, query: string, count: int, range_code: string, token: ^platform.Cancel_Token, a := context.allocator) -> (string, Web_Err, string) {
	base := s.opts.providers[.Tavily].base_url
	if base == "" {
		base = "https://api.tavily.com/search"
	}
	ctx := Tavily_Ctx{base = base, query = query, count = count, range_code = range_code}
	return keys_retry_search(s, s.opts.providers[.Tavily].keys, tavily_attempt, &ctx, token, a)
}

Tavily_Ctx :: struct {
	base:       string,
	query:      string,
	count:      int,
	range_code: string,
}

tavily_attempt :: proc(s: ^Searcher, key: string, user: rawptr, token: ^platform.Cancel_Token, a := context.allocator) -> (out: string, kind: Web_Err, msg: string, outcome: Attempt_Outcome) {
	c := cast(^Tavily_Ctx)user
	payload := make([dynamic]u8, 0, 256, context.temp_allocator)
	defer delete(payload)
	put_bytes(&payload, "{\"api_key\": ")
	put_bytes(&payload, jsonutil.json_quote(key, context.temp_allocator))
	put_bytes(&payload, ", \"query\": ")
	put_bytes(&payload, jsonutil.json_quote(c.query, context.temp_allocator))
	put_bytes(&payload, ", \"search_depth\": \"advanced\", \"include_answer\": false, \"include_images\": false, \"include_raw_content\": false, \"max_results\": ")
	put_bytes(&payload, util.int_to_dec(c.count, context.temp_allocator))
	put_bytes(&payload, "}")
	if word := range_word(c.range_code); word != "" {
		_ = pop(&payload)
		put_bytes(&payload, ", \"time_range\": ")
		put_bytes(&payload, jsonutil.json_quote(word, context.temp_allocator))
		put_bytes(&payload, "}")
	}

	ct_h: HTTP_Header
	ct_h.name = "Content-Type"
	ct_h.value = "application/json"
	ua_h: HTTP_Header
	ua_h.name = "User-Agent"
	ua_h.value = USER_AGENT_DEFAULT
	headers := make([dynamic]HTTP_Header, 0, 2, context.temp_allocator)
	append(&headers, ct_h)
	append(&headers, ua_h)
	req := HTTP_Request{
		method = "POST",
		url = c.base,
		body = payload[:],
		headers = headers[:],
		timeout_ms = SEARCH_TIMEOUT_MS,
		proxy = s.opts.proxy,
		max_bytes = MAX_JSON_DECODE_BYTES,
	}
	res, err_kind, err := search_http(s, req, token, a)
	if err_kind != .None {
		if err_kind == .Cancelled {
			return "", .Cancelled, err, .Answered
		}
		return "", err_kind, err, .Retryable
	}
	if res.status != 200 {
		status_err := strings.concatenate({
			"tavily api error (status ", util.int_to_dec(res.status, a), "): ",
			truncate_for_error(transmute(string)res.body, a),
		}, a)
		if retryable_status(res.status) {
			return "", .Provider_Error, status_err, .Retryable
		}
		return "", .Provider_Error, status_err, .Answered
	}
	v, ok2 := parse_json_body(transmute(string)res.body)
	if !ok2 {
		return "", .Provider_Error, "failed to parse response", .Answered
	}
	results, rok := array_field(v, "results")
	if !rok || len(results) == 0 {
		return strings.concatenate({"No results for: ", c.query}, a), .None, "", .Answered
	}
	return render_results(results, c.count, c.query, " (via Tavily)", "content", a), .None, "", .Answered
}

array_field :: proc(v: json.Value, key: string) -> ([]json.Value, bool) {
	if v == nil {
		return nil, false
	}
	if val, ok := jsonutil.obj_get(v, key); ok {
		return jsonutil.as_array(val)
	}
	return nil, false
}

perplexity_search :: proc(s: ^Searcher, query: string, count: int, range_code: string, token: ^platform.Cancel_Token, a := context.allocator) -> (string, Web_Err, string) {
	ctx := Perplexity_Ctx{query = query, count = count, range_code = range_code}
	return keys_retry_search(s, s.opts.providers[.Perplexity].keys, perplexity_attempt, &ctx, token, a)
}

Perplexity_Ctx :: struct {
	query:      string,
	count:      int,
	range_code: string,
}

perplexity_attempt :: proc(s: ^Searcher, key: string, user: rawptr, token: ^platform.Cancel_Token, a := context.allocator) -> (out: string, kind: Web_Err, msg: string, outcome: Attempt_Outcome) {
	c := cast(^Perplexity_Ctx)user
	system_prompt := "You are a search assistant. Provide concise search results with titles, URLs, and brief descriptions in the following format:\n1. Title\n   URL\n   Description\n\nDo not add extra commentary."
	user_prompt := strings.concatenate({
		"Search for: ", c.query, ". Provide up to ", util.int_to_dec(c.count, context.temp_allocator), " relevant results.",
	}, context.temp_allocator)
	payload := make([dynamic]u8, 0, 512, context.temp_allocator)
	defer delete(payload)
	put_bytes(&payload, "{\"model\": \"sonar\", \"messages\": [{\"role\": \"system\", \"content\": ")
	put_bytes(&payload, jsonutil.json_quote(system_prompt, context.temp_allocator))
	put_bytes(&payload, "}, {\"role\": \"user\", \"content\": ")
	put_bytes(&payload, jsonutil.json_quote(user_prompt, context.temp_allocator))
	put_bytes(&payload, "}], \"max_tokens\": 1000")
	if word := range_word(c.range_code); word != "" {
		put_bytes(&payload, ", \"search_recency_filter\": ")
		put_bytes(&payload, jsonutil.json_quote(word, context.temp_allocator))
	}
	put_bytes(&payload, "}")

	auth := strings.concatenate({"Bearer ", key}, context.temp_allocator)
	ct_h: HTTP_Header
	ct_h.name = "Content-Type"
	ct_h.value = "application/json"
	auth_h: HTTP_Header
	auth_h.name = "Authorization"
	auth_h.value = auth
	ua_h: HTTP_Header
	ua_h.name = "User-Agent"
	ua_h.value = USER_AGENT_DEFAULT
	headers := make([dynamic]HTTP_Header, 0, 3, context.temp_allocator)
	append(&headers, ct_h)
	append(&headers, auth_h)
	append(&headers, ua_h)
	req := HTTP_Request{
		method = "POST",
		url = "https://api.perplexity.ai/chat/completions",
		body = payload[:],
		headers = headers[:],
		timeout_ms = PERPLEXITY_TIMEOUT_MS,
		proxy = s.opts.proxy,
		max_bytes = MAX_JSON_DECODE_BYTES,
	}
	res, err_kind, err := search_http(s, req, token, a)
	if err_kind != .None {
		if err_kind == .Cancelled {
			return "", .Cancelled, err, .Answered
		}
		return "", err_kind, err, .Retryable
	}
	if res.status != 200 {
		status_err := strings.concatenate({
			"perplexity API error: ",
			truncate_for_error(transmute(string)res.body, a),
		}, a)
		if retryable_status(res.status) {
			return "", .Provider_Error, status_err, .Retryable
		}
		return "", .Provider_Error, status_err, .Answered
	}
	v, ok2 := parse_json_body(transmute(string)res.body)
	if !ok2 {
		return "", .Provider_Error, "failed to parse response", .Answered
	}
	choices, cok := array_field(v, "choices")
	if !cok || len(choices) == 0 {
		return strings.concatenate({"No results for: ", c.query}, a), .None, "", .Answered
	}
	content := ""
	if v2, ok3 := jsonutil.obj_get(choices[0], "message"); ok3 {
		content, _ = obj_str(v2, "content")
	}
	return strings.concatenate({
		"Results for: ", c.query, " (via Perplexity)\n", content,
	}, a), .None, "", .Answered
}

searxng_search :: proc(s: ^Searcher, query: string, count: int, range_code: string, token: ^platform.Cancel_Token, a := context.allocator) -> (string, Web_Err, string) {
	base := strings.trim_suffix(s.opts.providers[.SearXNG].base_url, "/")
	esc := query_escape(query, context.temp_allocator)
	url := strings.concatenate({base, "/search?q=", esc, "&format=json&categories=general"}, context.temp_allocator)
	if word := range_word(range_code); word != "" {
		url = strings.concatenate({url, "&time_range=", query_escape(word, context.temp_allocator)}, context.temp_allocator)
	}
	req := HTTP_Request{
		url = url,
		timeout_ms = SEARCH_TIMEOUT_MS,
		proxy = s.opts.proxy,
		max_bytes = MAX_JSON_DECODE_BYTES,
	}
	res, err_kind, err := search_http(s, req, token, a)
	if err_kind != .None {
		return "", err_kind, err
	}
	if res.status != 200 {
		return "", .Provider_Error, strings.concatenate({
			"SearXNG returned status ", util.int_to_dec(res.status, a),
		}, a)
	}
	v, ok := parse_json_body(transmute(string)res.body)
	if !ok {
		return "", .Provider_Error, "failed to parse response"
	}
	results, rok := array_field(v, "results")
	if !rok || len(results) == 0 {
		return strings.concatenate({"No results for: ", query}, a), .None, ""
	}
	if len(results) > count {
		results = results[:count]
	}
	return render_results(results, len(results), query, " (via SearXNG)", "content", a), .None, ""
}

duckduckgo_search :: proc(s: ^Searcher, query: string, count: int, range_code: string, token: ^platform.Cancel_Token, a := context.allocator) -> (string, Web_Err, string) {
	esc := query_escape(query, context.temp_allocator)
	url := strings.concatenate({"https://html.duckduckgo.com/html/?q=", esc}, context.temp_allocator)
	if df := duckduckgo_date_filter(range_code); df != "" {
		url = strings.concatenate({url, "&df=", query_escape(df, context.temp_allocator)}, context.temp_allocator)
	}
	req := HTTP_Request{
		url = url,
		user_agent = USER_AGENT_DEFAULT,
		timeout_ms = SEARCH_TIMEOUT_MS,
		proxy = s.opts.proxy,
		max_bytes = MAX_JSON_DECODE_BYTES,
	}
	res, err_kind, err := search_http(s, req, token, a)
	if err_kind != .None {
		return "", err_kind, err
	}
	return extract_ddg_results(transmute(string)res.body, count, query, a), .None, ""
}

// extract_ddg_results scrapes the result anchors and snippets out of the
// DuckDuckGo HTML endpoint.
extract_ddg_results :: proc(body: string, count: int, query: string, a := context.allocator) -> string {
	links := ddg_result_links(body, count + 5, a)
	if len(links) == 0 {
		return strings.concatenate({
			"No results found or extraction failed. Query: ", query,
		}, a)
	}
	snippets := ddg_snippets(body, count + 5, a)
	out := make([dynamic]string, 0, count + 1, a)
	defer delete(out)
	append(&out, strings.concatenate({"Results for: ", query, " (via DuckDuckGo)"}, a))
	max_items := len(links)
	if max_items > count {
		max_items = count
	}
	for i := 0; i < max_items; i += 1 {
		url_str := links[i].url
		if idx := strings.index(url_str, "uddg="); idx >= 0 {
			target := url_str[idx + 5:]
			// The redirect wrapper appends its own params after the target
			// (&rut=...): cut at the first raw separator, then unescape
			// only the target — unescaping the whole URL first would fuse
			// the wrapper's separators into the target.
			if amp := strings.index_byte(target, '&'); amp >= 0 {
				target = target[:amp]
			}
			url_str = query_unescape(target, context.temp_allocator)
		}
		append(&out, strings.concatenate({
			util.int_to_dec(i + 1, a), ". ", links[i].title, "\n   ", url_str,
		}, a))
		// Snippet anchors align with result anchors by document order;
		// an empty snippet adds no line.
		if i < len(snippets) && snippets[i] != "" {
			append(&out, strings.concatenate({"   ", snippets[i]}, a))
		}
	}
	joined, _ := strings.join(out[:], "\n", a)
	return joined
}

// ddg_snippets collects the result__snippet anchor texts in document
// order — index-aligned with ddg_result_links' output, as the
// reference's two scans are.
ddg_snippets :: proc(body: string, limit: int, a := context.allocator) -> []string {
	out := make([dynamic]string, 0, limit, a)
	i := 0
	for i < len(body) && len(out) < limit {
		idx := strings.index(body[i:], "<a class=\"result__snippet")
		if idx < 0 {
			break
		}
		tag_start := i + idx
		tag_end := strings.index(body[tag_start:], "</a>")
		if tag_end < 0 {
			break
		}
		tag_end += tag_start
		text := ddg_inner_text(body[tag_start:tag_end], a)
		append(&out, strings.trim_space(text))
		i = tag_end + 4
	}
	return out[:]
}

DDG_Link :: struct {
	url:   string,
	title: string,
}

// ddg_result_links finds result anchors: <a class="result__a" href="...">.
ddg_result_links :: proc(body: string, limit: int, a := context.allocator) -> []DDG_Link {
	out := make([dynamic]DDG_Link, 0, limit, a)
	i := 0
	for i < len(body) && len(out) < limit {
		idx := strings.index(body[i:], "<a ")
		if idx < 0 {
			break
		}
		tag_start := i + idx
		tag_end := strings.index(body[tag_start:], "</a>")
		if tag_end < 0 {
			break
		}
		tag_end += tag_start
		tag := body[tag_start:tag_end]
		if strings.contains(tag, "result__a") {
			href := ddg_attr(tag, "href", a)
			if href != "" {
				title := ddg_inner_text(tag, a)
				link: DDG_Link
				link.url = href
				link.title = title
				append(&out, link)
			}
		}
		i = tag_end + 4
	}
	return out[:]
}

ddg_attr :: proc(tag: string, key: string, a := context.allocator) -> string {
	needle := strings.concatenate({key, "=\""}, context.temp_allocator)
	idx := strings.index(tag, needle)
	if idx < 0 {
		return ""
	}
	start := idx + len(needle)
	end := strings.index_byte(tag[start:], '"')
	if end < 0 {
		return ""
	}
	return strings.clone(tag[start:start + end], a)
}

ddg_inner_text :: proc(tag: string, a := context.allocator) -> string {
	close := strings.index(tag, ">")
	if close < 0 {
		return ""
	}
	inner := tag[close + 1:]
	stripped := make([dynamic]u8, 0, len(inner), a)
	defer delete(stripped)
	in_tag := false
	for i := 0; i < len(inner); i += 1 {
		c := inner[i]
		if c == '<' {
			in_tag = true
			continue
		}
		if c == '>' {
			in_tag = false
			continue
		}
		if !in_tag {
			append(&stripped, c)
		}
	}
	return strings.clone(strings.trim_space(transmute(string)(stripped[:])), a)
}

// project_web_config fills the provider-facing options from the parsed
// Web_Config — the ONE projection behind both the owning (searcher) and
// borrowing (visibility-check) reads. clone = true deep-copies every
// string; clone = false borrows the config's own storage (the borrower
// never outlives the config). DuckDuckGo stays enabled regardless — it
// is the only provider without keys.
project_web_config :: proc(opts: ^Search_Options, wc: ^config.Web_Config, clone: bool, a := context.allocator) {
	opts.provider = wc.search_provider
	opts.providers[.Brave].max = wc.brave.max_results
	opts.providers[.Brave].enabled = wc.brave.enabled
	opts.providers[.Tavily].max = wc.tavily.max_results
	opts.providers[.Tavily].enabled = wc.tavily.enabled
	opts.providers[.DuckDuckGo].max = wc.duckduckgo.max_results
	opts.providers[.Perplexity].max = wc.perplexity.max_results
	opts.providers[.Perplexity].enabled = wc.perplexity.enabled
	opts.providers[.SearXNG].max = wc.searxng.max_results
	opts.providers[.SearXNG].enabled = wc.searxng.enabled
	opts.allow_private = wc.allow_private_hosts
	if clone {
		opts.providers[.Brave].keys = clone_strs(wc.brave.api_keys, a)
		opts.providers[.Tavily].keys = clone_strs(wc.tavily.api_keys, a)
		opts.providers[.Tavily].base_url = strings.clone(wc.tavily.base_url, a)
		opts.providers[.Perplexity].keys = clone_strs(wc.perplexity.api_keys, a)
		opts.providers[.SearXNG].base_url = strings.clone(wc.searxng.base_url, a)
		opts.proxy = strings.clone(wc.fetch_proxy, a)
		opts.whitelist = clone_strs(wc.whitelist_hosts, a)
	} else {
		opts.providers[.Brave].keys = wc.brave.api_keys
		opts.providers[.Tavily].keys = wc.tavily.api_keys
		opts.providers[.Tavily].base_url = wc.tavily.base_url
		opts.providers[.Perplexity].keys = wc.perplexity.api_keys
		opts.providers[.SearXNG].base_url = wc.searxng.base_url
		opts.proxy = wc.fetch_proxy
		opts.whitelist = wc.whitelist_hosts
	}
	opts.providers[.DuckDuckGo].enabled = true
}

search_options_from_config :: proc(wc: ^config.Web_Config, a := context.allocator) -> Search_Options {
	opts: Search_Options
	project_web_config(&opts, wc, true, a)
	return opts
}

clone_strs :: proc(list: []string, a := context.allocator) -> []string {
	if len(list) == 0 {
		return nil
	}
	out := make([]string, len(list), a)
	for i := 0; i < len(list); i += 1 {
		out[i] = strings.clone(list[i], a)
	}
	return out
}

// search_provider_configured reports whether any provider is ready from
// the raw config — the session-side visibility check for web_search.
// Borrows the config's storage (clone = false): the answer is immediate.
search_provider_configured :: proc(wc: ^config.Web_Config) -> bool {
	opts: Search_Options
	project_web_config(&opts, wc, false)
	_, ok := search_resolve(&opts)
	return ok
}
