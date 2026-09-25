package tracker

// The presentation layer. Every output format that acts as a contract
// (list headers, incident lines, the one-line summary) lives here so the
// tool layer and the CLI render identically. Everything in this file is
// pure over the fold state; strings the caller keeps are cloned into the
// caller's allocator, interior temporaries use the temp allocator.
// `now_ms` is injected so relative times are deterministic in tests.
// Detail views that read event payloads live in detail.odin.

import "core:mem"
import "core:slice"
import "core:strings"
import "src:platform"

DEFAULT_LIST_LIMIT :: 20
TITLE_LIST_WIDTH :: 80

// Hard render ceilings, independent of the caller's limit: a tracker grown
// to thousands of incidents must never render thousands of lines into one
// answer. Rows stop at MAX_LIST_ROWS, or earlier when wide (multi-byte)
// titles push the rendered size past MAX_LIST_BYTES (the real budget is
// the consumer's context window, not the session answer cap — one list
// answer must stay a modest slice of it); the truncation tail names which
// ceiling fired. Complete unbounded output stays the TSV/JSON export's
// contract (`aubade tracker report`).
MAX_LIST_ROWS :: 500
MAX_LIST_BYTES :: 60_000

// Census is one scan's worth of header statistics: status counts,
// priority splits over all live incidents and over open ones only, and
// the anomaly count. Priority buckets are the canonical four (unknown
// priorities from foreign events never appear in the header line).
Census :: struct {
	counts:        Counts,
	priority:      [4]int,
	open_priority: [4]int,
	anomalies:     int,
	total:         int,
}

priority_index :: proc(p: string) -> int {
	switch p {
	case priority_string(.Urgent): return 0
	case priority_string(.High):   return 1
	case priority_string(.Medium): return 2
	case priority_string(.Low):    return 3
	}
	return -1
}

census_add :: proc(c: ^Census, h: ^Incident_Header) {
	counts_add(&c.counts, h)
	c.total += 1
	if i := priority_index(h.priority); i >= 0 {
		c.priority[i] += 1
		if !status_is_terminal(h.status) {
			c.open_priority[i] += 1
		}
	}
	if h.is_anomaly {
		c.anomalies += 1
	}
}

census_of :: proc(headers: []^Incident_Header) -> Census {
	c: Census
	for h in headers {
		census_add(&c, h)
	}
	return c
}

// sprint_cohort collects the sprint's report population: findings filed
// (created) inside the sprint's window, deleted excluded. The statistics
// section and the incident list of a sprint report both count exactly
// this set — membership is never consulted. Callers delete the slice with
// the allocator they pass.
sprint_cohort :: proc(s: ^Fold_State, spr: ^Sprint_Header, a: mem.Allocator) -> []^Incident_Header {
	out := make([dynamic]^Incident_Header, 0, 8, a)
	for uid in s.incident_order {
		h := s.incidents[uid]
		if h == nil || h.is_deleted {
			continue
		}
		if !sprint_window_has(spr, h.created_ms) {
			continue
		}
		append(&out, h)
	}
	return owned_header_slice(out, a)
}

live_incidents :: proc(s: ^Fold_State, a: mem.Allocator) -> []^Incident_Header {
	out := make([dynamic]^Incident_Header, 0, len(s.incident_order), a)
	for uid in s.incident_order {
		h := s.incidents[uid]
		if h != nil && !h.is_deleted {
			append(&out, h)
		}
	}
	return owned_header_slice(out, a)
}

sprint_members :: proc(s: ^Fold_State, sprint_id: string, a: mem.Allocator) -> []^Incident_Header {
	out := make([dynamic]^Incident_Header, 0, 8, a)
	for uid in s.incident_order {
		h := s.incidents[uid]
		if h != nil && !h.is_deleted && h.sprint == sprint_id {
			append(&out, h)
		}
	}
	return owned_header_slice(out, a)
}

// owned_header_slice materializes a build-up dynamic as a plain owned
// slice (delete-able by the caller); a returned dynamic view is not.
@(private)
owned_header_slice :: proc(dyn: [dynamic]^Incident_Header, a: mem.Allocator) -> []^Incident_Header {
	out := make([]^Incident_Header, len(dyn), a)
	for h, i in dyn {
		out[i] = h
	}
	delete(dyn)
	return out
}

oldest_open :: proc(headers: []^Incident_Header) -> ^Incident_Header {
	best: ^Incident_Header
	for h in headers {
		if status_is_terminal(h.status) {
			continue
		}
		if best == nil || h.created_ms < best.created_ms {
			best = h
		}
	}
	return best
}

status_count :: proc(c: ^Counts, status: string) -> int {
	switch status {
	case incident_status_string(.Reported):    return c.reported
	case incident_status_string(.Confirmed):   return c.confirmed
	case incident_status_string(.Root_Caused): return c.root_caused
	case incident_status_string(.Resolved):    return c.resolved
	case incident_status_string(.Rejected):    return c.rejected
	}
	return 0
}

// dec formats a small integer in the temp allocator (render-only).
dec :: proc(n: int) -> string {
	if n == 0 {
		return "0"
	}
	buf: [20]u8
	i := len(buf)
	v := n
	if v < 0 {
		v = -v
	}
	for v > 0 {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
	}
	if n < 0 {
		i -= 1
		buf[i] = '-'
	}
	return strings.clone(string(buf[i:]), context.temp_allocator)
}

counts_header_line :: proc(c: ^Census, a: mem.Allocator) -> string {
	if c.total == 0 {
		return "0 incidents"
	}
	b, berr := strings.builder_make_len_cap(0, 64, a)
	if berr != nil {
		return ""
	}
	defer strings.builder_destroy(&b)
	strings.write_string(&b, dec(c.total))
	strings.write_string(&b, " incidents")
	if c.anomalies > 0 {
		strings.write_string(&b, " (")
		strings.write_string(&b, dec(c.anomalies))
		strings.write_string(&b, " anomal")
		if c.anomalies == 1 {
			strings.write_string(&b, "y")
		} else {
			strings.write_string(&b, "ies")
		}
		strings.write_string(&b, ")")
	}
	strings.write_string(&b, ": ")
	wrote := false
	for i in 0..<4 {
		if c.priority[i] == 0 {
			continue
		}
		if wrote {
			strings.write_string(&b, "; ")
		} else {
			wrote = true
		}
		write_tally(&b, c.priority[i], priority_string(Priority(i)))
	}
	write_status_tally(&b, &c.counts, true, &wrote)
	write_status_tally(&b, &c.counts, false, &wrote)
	return strings.clone(strings.to_string(b), a)
}

write_tally :: proc(b: ^strings.Builder, n: int, name: string) {
	strings.write_string(b, dec(n))
	strings.write_byte(b, ' ')
	strings.write_string(b, name)
}

write_status_tally :: proc(b: ^strings.Builder, c: ^Counts, open_set: bool, wrote: ^bool) {
	open_order := []Incident_Status{.Reported, .Confirmed, .Root_Caused}
	terminal_order := []Incident_Status{.Resolved, .Rejected}
	pick := terminal_order
	if open_set {
		pick = open_order
	}
	for st in pick {
		if n := status_count(c, incident_status_string(st)); n > 0 {
			if wrote^ {
				strings.write_string(b, "; ")
			} else {
				wrote^ = true
			}
			write_tally(b, n, incident_status_string(st))
		}
	}
}

// rel_time renders elapsed time the way list lines do: 45m, 2h, 3d, 2w —
// never calendar dates. Clock-skewed future stamps render "future".
rel_time :: proc(ms: i64, now_ms: i64) -> string {
	if ms == 0 {
		return "?"
	}
	d := now_ms - ms
	if d < 0 {
		return "future"
	}
	minutes := (d + 59_999) / 60_000 // "45m" — never 0m
	hours := d / 3_600_000
	switch {
	case d < 3_600_000:
		return strings.concatenate({dec(int(minutes)), "m"}, context.temp_allocator)
	case d < 86_400_000:
		return strings.concatenate({dec(int(hours)), "h"}, context.temp_allocator)
	case d < 7 * 86_400_000:
		return strings.concatenate({dec(int(hours / 24)), "d"}, context.temp_allocator)
	case:
		return strings.concatenate({dec(int(hours / 24 / 7)), "w"}, context.temp_allocator)
	}
}

// date_of renders the YYYY-MM-DD prefix of a UTC timestamp.
date_of :: proc(ms: i64, a: mem.Allocator) -> string {
	if ms == 0 {
		return "?"
	}
	return ts_iso_utc(ms, a)[:10]
}

// truncate_runes caps a string at max_runes characters, ellipsis-ended.
truncate_runes :: proc(s: string, max_runes: int, a: mem.Allocator) -> string {
	if rune_len(s) <= max_runes {
		return s
	}
	cut := rune_cut(s, max_runes)
	parts := [2]string{s[:cut], "…"}
	return strings.concatenate(parts[:], a)
}

rune_cut :: proc(s: string, max_runes: int) -> int {
	count := 0
	for i in 0..<len(s) {
		if s[i] & 0xC0 != 0x80 {
			if count == max_runes {
				return i
			}
			count += 1
		}
	}
	return len(s)
}

// short_list joins up to three items, then "+N" — the shared truncation
// rule for enumerations inside one line.
short_list :: proc(items: []string, a: mem.Allocator) -> string {
	if len(items) == 0 {
		return ""
	}
	b, berr := strings.builder_make_len_cap(0, 32, a)
	if berr != nil {
		return ""
	}
	defer strings.builder_destroy(&b)
	n := len(items)
	if n > 3 {
		n = 3
	}
	for i in 0..<n {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, items[i])
	}
	if len(items) > 3 {
		strings.write_string(&b, " +")
		strings.write_string(&b, dec(len(items) - 3))
	}
	return strings.clone(strings.to_string(b), a)
}

paren_suffix :: proc(s: string, a: mem.Allocator) -> string {
	if s == "" {
		return ""
	}
	parts := [3]string{" (", s, ")"}
	return strings.concatenate(parts[:], a)
}

// flat_line collapses line breaks so caller-supplied filter values and
// (possibly foreign) titles cannot break the one-line-per-row contract.
flat_line :: proc(s: string, a: mem.Allocator) -> string {
	if !strings.contains_any(s, "\n\r") {
		return s
	}
	b, berr := strings.builder_make_len_cap(0, len(s), a)
	if berr != nil {
		return s
	}
	defer strings.builder_destroy(&b)
	for i in 0..<len(s) {
		c := s[i]
		if c == '\n' || c == '\r' {
			c = ' '
		}
		strings.write_byte(&b, c)
	}
	return strings.clone(strings.to_string(b), a)
}

contains_substring_fold :: proc(list: []string, q: string) -> bool {
	for s in list {
		if strings.contains(strings.to_lower(s, context.temp_allocator), q) {
			return true
		}
	}
	return false
}

// render_incident_line renders one list line. show_label surfaces the
// label segment only when the caller filters by label (context makes the
// rest self-evident).
render_incident_line :: proc(h: ^Incident_Header, show_label: bool, now_ms: i64, a: mem.Allocator) -> string {
	b, berr := strings.builder_make_len_cap(0, 96, a)
	if berr != nil {
		return ""
	}
	defer strings.builder_destroy(&b)

	status := h.status
	if h.status == incident_status_string(.Rejected) && h.fp_pattern != "" {
		status = strings.concatenate({incident_status_string(.Rejected), ": ", h.fp_pattern}, context.temp_allocator)
	} else if h.status == incident_status_string(.Resolved) && h.resolution != "" {
		status = strings.concatenate({incident_status_string(.Resolved), ": ", h.resolution}, context.temp_allocator)
	}
	strings.write_string(&b, h.id)
	strings.write_string(&b, " [")
	strings.write_string(&b, h.priority)
	strings.write_string(&b, "] (")
	strings.write_string(&b, status)
	if h.sprint != "" {
		strings.write_string(&b, ", ")
		strings.write_string(&b, h.sprint)
	}
	if len(h.blocked_by) > 0 {
		strings.write_string(&b, ", blocked by ")
		strings.write_string(&b, short_list(h.blocked_by, context.temp_allocator))
	}
	if show_label && len(h.labels) > 0 {
		strings.write_string(&b, ", label:")
		for label in h.labels {
			strings.write_string(&b, label)
			strings.write_byte(&b, ' ')
		}
	}
	strings.write_string(&b, ") ")
	strings.write_string(&b, truncate_runes(flat_line(h.title, context.temp_allocator), TITLE_LIST_WIDTH, context.temp_allocator))
	strings.write_string(&b, " — ")
	strings.write_string(&b, rel_time(h.updated_ms, now_ms))
	if h.is_anomaly {
		strings.write_string(&b, " !")
	}
	return strings.clone(strings.to_string(b), a)
}

// append_capped_rows appends list lines until the caller's wanted count,
// the hard row ceiling, or the rendered-size budget stops it — the
// ceilings are checked before the wanted count so a ceiling firing below
// it is reported (raising the limit cannot recover past a ceiling).
// Returns the rows written and which ceiling (if any) cut the output.
append_capped_rows :: proc(
	b: ^strings.Builder,
	matched: []^Incident_Header,
	wanted: int,
	show_label: bool,
	now_ms: i64,
) -> (written: int, hit_rows: bool, hit_bytes: bool) {
	for h in matched {
		if written >= MAX_LIST_ROWS {
			hit_rows = true
			break
		}
		if written >= wanted {
			break
		}
		if strings.builder_len(b^) >= MAX_LIST_BYTES {
			hit_bytes = true
			break
		}
		strings.write_string(b, "\n")
		strings.write_string(b, render_incident_line(h, show_label, now_ms, context.temp_allocator))
		written += 1
	}
	return written, hit_rows, hit_bytes
}

// write_cap_tail appends the hard-ceiling truncation notice; the wording
// names the recovery paths (narrower facet filters, or the complete
// TSV/JSON export whose contract is full fidelity).
write_cap_tail :: proc(b: ^strings.Builder, hidden: int, hit_rows: bool, hit_bytes: bool) {
	if hidden <= 0 || (!hit_rows && !hit_bytes) {
		return
	}
	strings.write_string(b, "\n…and ")
	strings.write_string(b, dec(hidden))
	if hit_rows {
		strings.write_string(b, " more (list cap of ")
		strings.write_string(b, dec(MAX_LIST_ROWS))
		strings.write_string(b, " rows reached — narrow with status/priority/sprint/query; full export: aubade tracker report)")
	} else {
		strings.write_string(b, " more (list size cap reached — narrow with status/priority/sprint/query; full export: aubade tracker report)")
	}
}

// --- incident list assembly ---------------------------------------------

Incident_Filter :: struct {
	status:     []string, // OR; "open" expands to the three non-terminal states
	sprint:     string,   // "-" backlog, "current", or a sprint ID
	label:      string,
	priority:   []string, // OR
	verdict:    string,
	blocked_by: string,
	assignee:   string,
	created_by: string,
	query:      string, // substring on title + aliases, case-folded
	limit:      int,    // 0 = default 20, negative = unlimited
	sort:       string, // "updated" (default) | "priority" | "created"
}

Filter_Ctx :: struct {
	sprint:      string,
	blocked_set: map[string]bool, // temp-owned
}

any_filter_set :: proc(f: ^Incident_Filter) -> bool {
	return len(f.status) > 0 || f.sprint != "" || f.label != "" || len(f.priority) > 0 ||
		f.verdict != "" || f.blocked_by != "" || f.assignee != "" || f.created_by != "" ||
		f.query != ""
}

filter_desc :: proc(f: ^Incident_Filter, a: mem.Allocator) -> string {
	b, berr := strings.builder_make_len_cap(0, 32, a)
	if berr != nil {
		return ""
	}
	defer strings.builder_destroy(&b)
	wrote := false
	write_dim :: proc(b: ^strings.Builder, name: string, value: string, wrote: ^bool) {
		if value == "" {
			return
		}
		if wrote^ {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, name)
		strings.write_string(b, "=")
		strings.write_string(b, flat_line(value, context.temp_allocator))
		wrote^ = true
	}
	if len(f.status) > 0 {
		write_dim(&b, "status", join_strings(f.status, "|"), &wrote)
	}
	write_dim(&b, "sprint", f.sprint, &wrote)
	write_dim(&b, "label", f.label, &wrote)
	if len(f.priority) > 0 {
		write_dim(&b, "priority", join_strings(f.priority, "|"), &wrote)
	}
	write_dim(&b, "verdict", f.verdict, &wrote)
	write_dim(&b, "blocked_by", f.blocked_by, &wrote)
	write_dim(&b, "assignee", f.assignee, &wrote)
	write_dim(&b, "created_by", f.created_by, &wrote)
	write_dim(&b, "query", f.query, &wrote)
	return strings.clone(strings.to_string(b), a)
}

join_strings :: proc(parts: []string, sep: string) -> string {
	out, _ := strings.join(parts, sep, context.temp_allocator)
	return out
}

incident_matches :: proc(h: ^Incident_Header, f: ^Incident_Filter, ctx: ^Filter_Ctx) -> bool {
	if len(f.status) > 0 {
		ok := false
		for st in f.status {
			if st == h.status || (st == "open" && !status_is_terminal(h.status)) {
				ok = true
				break
			}
		}
		if !ok {
			return false
		}
	}
	if f.sprint != "" {
		mine := h.sprint
		if mine == "" {
			mine = "-"
		}
		if mine != ctx.sprint {
			return false
		}
	}
	if f.label != "" && !slice.contains(h.labels, f.label) {
		return false
	}
	if len(f.priority) > 0 && !slice.contains(f.priority, h.priority) {
		return false
	}
	if f.verdict != "" && h.verdict != f.verdict {
		return false
	}
	if f.blocked_by != "" && !ctx.blocked_set[h.id] {
		return false
	}
	if f.assignee != "" && h.assignee != f.assignee {
		return false
	}
	if f.created_by != "" && h.created_by != f.created_by {
		return false
	}
	if f.query != "" {
		q := strings.to_lower(f.query, context.temp_allocator)
		if !strings.contains(strings.to_lower(h.title, context.temp_allocator), q) &&
		   !contains_substring_fold(h.aliases, q) {
			return false
		}
	}
	return true
}

sort_incidents :: proc(list: []^Incident_Header, sort_key: string) {
	less_updated :: proc(list: []^Incident_Header, i: int, j: int) -> bool {
		return list[i].updated_ms > list[j].updated_ms
	}
	less_created :: proc(list: []^Incident_Header, i: int, j: int) -> bool {
		return list[i].created_ms < list[j].created_ms
	}
	less_priority :: proc(list: []^Incident_Header, i: int, j: int) -> bool {
		ri := priority_index(list[i].priority)
		rj := priority_index(list[j].priority)
		if ri < 0 {
			ri = 4 // unrecognized (foreign) sorts last, never most urgent
		}
		if rj < 0 {
			rj = 4
		}
		if ri != rj {
			return ri < rj
		}
		return list[i].updated_ms > list[j].updated_ms
	}
	less := less_updated
	switch sort_key {
	case "created":
		less = less_created
	case "priority":
		less = less_priority
	}
	// insertion sort — lists are small and ownership stays trivial
	for i in 1..<len(list) {
		j := i
		for j > 0 && less(list, j, j-1) {
			list[j], list[j-1] = list[j-1], list[j]
			j -= 1
		}
	}
}

// matched_incidents resolves the filter context (sprint aliases, the
// transitive blocked-by set) against s and returns the live headers
// matching f, sorted per f.sort. Shared by the rendered list and the
// structured report so the two surfaces cannot drift apart.
matched_incidents :: proc(
	s: ^Fold_State,
	f: ^Incident_Filter,
	live: []^Incident_Header,
	a: mem.Allocator,
) -> (matched: []^Incident_Header, err: platform.Err) {
	ctx: Filter_Ctx
	if f.blocked_by != "" {
		target := incident_by_id(s, f.blocked_by)
		if target == nil {
			return nil, err_incident_not_found(a, f.blocked_by)
		}
		ctx.blocked_set = make(map[string]bool, 4, context.temp_allocator)
		deps := dag_dependents(&s.dag, target.id, context.temp_allocator)
		for id in deps {
			ctx.blocked_set[id] = true
		}
		delete(deps, context.temp_allocator)
	}
	ctx.sprint = f.sprint
	if ctx.sprint == SPRINT_CURRENT_ALIAS {
		active := active_sprint(s)
		if active == nil {
			return nil, inv(a, "no active sprint (sprint=current)")
		}
		ctx.sprint = active.id
	}
	out := make([dynamic]^Incident_Header, 0, len(live), a)
	for h in live {
		if incident_matches(h, f, &ctx) {
			append(&out, h)
		}
	}
	if ctx.blocked_set != nil {
		delete(ctx.blocked_set)
	}
	sort_incidents(out[:], f.sort)
	return owned_header_slice(out, a), nil
}

// render_incident_list assembles the full list output: counts header (or
// the matched header when any filter is set), one line per incident, the
// anomaly notice, and the truncation tail. The format is a contract —
// callers surface it verbatim.
render_incident_list :: proc(s: ^Fold_State, f: ^Incident_Filter, now_ms: i64, a: mem.Allocator) -> (string, platform.Err) {
	live := live_incidents(s, a)
	defer delete(live, a)
	cen := census_of(live[:])

	matched, err := matched_incidents(s, f, live[:], a)
	if err != nil {
		return "", err
	}
	defer delete(matched, a)

	limit := f.limit
	if limit == 0 {
		limit = DEFAULT_LIST_LIMIT
	}
	wanted := len(matched)
	if limit >= 0 && limit < wanted {
		wanted = limit
	}

	anomalies := 0
	for h in matched {
		if h.is_anomaly {
			anomalies += 1
		}
	}

	b, berr := strings.builder_make_len_cap(0, 128, a)
	if berr != nil {
		return "", inv(a, "tracker: list allocation failed")
	}
	defer strings.builder_destroy(&b)
	switch {
	case any_filter_set(f):
		strings.write_string(&b, "matched ")
		strings.write_string(&b, dec(len(matched)))
		strings.write_string(&b, "/")
		strings.write_string(&b, dec(cen.total))
		strings.write_string(&b, " (")
		strings.write_string(&b, filter_desc(f, context.temp_allocator))
		strings.write_string(&b, ")")
	case cen.total == 0:
		return "0 incidents\nno incidents yet — incident_create to file one", nil
	case:
		strings.write_string(&b, counts_header_line(&cen, a))
	}
	if anomalies > 0 {
		noun := " anomaly"
		if anomalies > 1 {
			noun = " anomalies"
		}
		strings.write_string(&b, "\n")
		strings.write_string(&b, dec(anomalies))
		strings.write_string(&b, noun)
		strings.write_string(&b, " (run incident_get for details)")
	}
	written, hit_rows, hit_bytes := append_capped_rows(&b, matched, wanted, f.label != "", now_ms)
	hidden := len(matched) - written
	if hidden > 0 && !hit_rows && !hit_bytes {
		strings.write_string(&b, "\n…and ")
		strings.write_string(&b, dec(hidden))
		strings.write_string(&b, " more (raise limit or filter)")
	} else {
		write_cap_tail(&b, hidden, hit_rows, hit_bytes)
	}
	return strings.clone(strings.to_string(b), a), nil
}

// render_open_summary renders the resume summary for session prompts — the
// generalized open summary. Unanswered questions lead (they are the human
// intervention points and only disappear answered or descoped), then the
// active round's must tasks with their derived verification state, then the
// open-problem line. Empty when nothing is open — the caller omits the line
// entirely.
render_open_summary :: proc(s: ^Fold_State, now_ms: i64, a: mem.Allocator) -> string {
	live := live_incidents(s, a)
	defer delete(live, a)
	cen := census_of(live[:])
	state_anoms := s.anomalies
	questions := open_questions(s, a)
	defer if questions != nil {
		delete(questions, a)
	}
	active := active_sprint(s)
	round_relevant := false
	must_line := ""
	if active != nil {
		must_line = must_task_line(s, active, a)
		// The first return is the defer count: a round that recorded any
		// defer (resolved or not) stays resume-relevant — the answers on
		// resolved questions are exactly what a resuming session needs.
		defer_total, _ := sprint_defer_stats(s, active)
		if len(active.must) > 0 || defer_total > 0 {
			round_relevant = true
		}
	}
	if cen.counts.open == 0 && len(state_anoms) == 0 && len(questions) == 0 && !round_relevant {
		return ""
	}
	b, berr := strings.builder_make_len_cap(0, 160, a)
	if berr != nil {
		return ""
	}
	defer strings.builder_destroy(&b)
	if len(questions) > 0 {
		strings.write_string(&b, "Pending questions (answer or descope via a sprint_update note with resolves=):\n")
		shown := len(questions)
		if shown > 8 {
			shown = 8
		}
		for q, i in questions[:shown] {
			strings.write_string(&b, "- ")
			strings.write_string(&b, q.id)
			strings.write_string(&b, " [")
			strings.write_string(&b, q.sprint)
			strings.write_string(&b, "] ")
			strings.write_string(&b, first_line_capped(q.body_md))
			if i < shown - 1 {
				strings.write_byte(&b, '\n')
			}
		}
		if len(questions) > shown {
			strings.write_string(&b, "\n…")
			strings.write_string(&b, dec(len(questions) - shown))
			strings.write_string(&b, " more pending questions")
		}
		strings.write_byte(&b, '\n')
	}
	if round_relevant {
		strings.write_string(&b, "Round ")
		strings.write_string(&b, active.id)
		strings.write_string(&b, " '")
		strings.write_string(&b, active.name)
		strings.write_string(&b, "'")
		if must_line != "" {
			strings.write_string(&b, " — ")
			strings.write_string(&b, must_line)
		}
		def_total, open_q := sprint_defer_stats(s, active)
		if def_total > 0 {
			strings.write_string(&b, "; defers: ")
			strings.write_string(&b, dec(def_total))
			strings.write_string(&b, " filed (")
			strings.write_string(&b, dec(open_q))
			strings.write_string(&b, " open questions)")
		}
		strings.write_byte(&b, '\n')
	}
	if cen.counts.open > 0 {
		strings.write_string(&b, "Tracker: ")
		strings.write_string(&b, dec(cen.counts.open))
		strings.write_string(&b, " open (")
		wrote := false
		if n := cen.open_priority[0]; n > 0 {
			strings.write_string(&b, dec(n))
			strings.write_string(&b, " urgent")
			wrote = true
		}
		if cen.counts.reported > 0 {
			if wrote {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, dec(cen.counts.reported))
			strings.write_string(&b, " unverified")
			wrote = true
		}
		if oldest := oldest_open(live[:]); oldest != nil {
			if wrote {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, "oldest ")
			strings.write_string(&b, oldest.id)
			strings.write_byte(&b, ' ')
			strings.write_string(&b, rel_time(oldest.created_ms, now_ms))
		}
		strings.write_string(&b, ")")
		if active != nil {
			members := sprint_members(s, active.id, a)
			mc := census_of(members)
			delete(members, a)
			strings.write_string(&b, ", sprint ")
			strings.write_string(&b, active.id)
			strings.write_string(&b, ": ")
			strings.write_string(&b, dec(mc.counts.open))
			strings.write_string(&b, " open (")
			wrote2 := false
			if n := mc.open_priority[0]; n > 0 {
				strings.write_string(&b, dec(n))
				strings.write_string(&b, " urgent")
				wrote2 = true
			}
			if n := mc.open_priority[1]; n > 0 {
				if wrote2 {
					strings.write_string(&b, ", ")
				}
				strings.write_string(&b, dec(n))
				strings.write_string(&b, " high")
			}
			strings.write_string(&b, ")")
		}
	}
	// State-level fold anomalies have no incident header to carry them —
	// the summary line is the only producer-facing surface they get.
	if len(state_anoms) > 0 {
		if cen.counts.open > 0 {
			strings.write_string(&b, "; ")
		} else {
			strings.write_string(&b, "Tracker: ")
		}
		strings.write_string(&b, dec(len(state_anoms)))
		strings.write_string(&b, " state anomalies (earliest: ")
		strings.write_string(&b, state_anoms[0])
		strings.write_string(&b, ")")
	}
	strings.write_string(&b, " — see incident_list / sprint_list")
	return strings.clone(strings.to_string(b), a)
}

// must_task_line renders the round's must-task verification profile:
// "must: P/N verified" plus the non-passing tasks grouped by derived state
// (unverified / deferred / failed — latest record wins). "" when the round
// declares no must tasks.
must_task_line :: proc(s: ^Fold_State, spr: ^Sprint_Header, a: mem.Allocator) -> string {
	if len(spr.must) == 0 {
		return ""
	}
	passed_s := verif_outcome_string(.Passed)
	failed_s := verif_outcome_string(.Failed)
	unverified := make([dynamic]string, 0, 4, context.temp_allocator)
	defer delete(unverified)
	deferred := make([dynamic]string, 0, 4, context.temp_allocator)
	defer delete(deferred)
	failed := make([dynamic]string, 0, 4, context.temp_allocator)
	defer delete(failed)
	passed := 0
	for task in spr.must {
		v := task_latest_verif(spr, task)
		if v != nil && v.outcome == passed_s {
			passed += 1
		} else if v != nil && v.outcome == failed_s {
			append(&failed, task)
		} else if task_deferred_by(s, spr, task) {
			append(&deferred, task)
		} else {
			append(&unverified, task)
		}
	}
	b, berr := strings.builder_make_len_cap(0, 64, a)
	if berr != nil {
		return ""
	}
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "must: ")
	strings.write_string(&b, dec(passed))
	strings.write_byte(&b, '/')
	strings.write_string(&b, dec(len(spr.must)))
	strings.write_string(&b, " verified")
	groups := 0
	if len(unverified) > 0 {
		write_task_group(&b, "unverified", unverified[:], &groups)
	}
	if len(deferred) > 0 {
		write_task_group(&b, "deferred", deferred[:], &groups)
	}
	if len(failed) > 0 {
		write_task_group(&b, "failed", failed[:], &groups)
	}
	if groups > 0 {
		strings.write_string(&b, ")")
	}
	return strings.clone(strings.to_string(b), a)
}

@(private)
write_task_group :: proc(b: ^strings.Builder, name: string, tasks: []string, groups: ^int) {
	if groups^ == 0 {
		strings.write_string(b, " (")
	} else {
		strings.write_string(b, "; ")
	}
	groups^ += 1
	strings.write_string(b, name)
	strings.write_string(b, ": ")
	shown := len(tasks)
	if shown > 6 {
		shown = 6
	}
	for i in 0..<shown {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, tasks[i])
	}
	if len(tasks) > shown {
		strings.write_string(b, ", +")
		strings.write_string(b, dec(len(tasks) - shown))
	}
}

// first_line_capped renders a body's first line, capped for one-line
// summaries (the full text lives in sprint_get).
first_line_capped :: proc(body: string) -> string {
	line := body
	for i in 0..<len(line) {
		if line[i] == '\n' {
			line = line[:i]
			break
		}
	}
	if rune_len(line) <= 100 {
		return line
	}
	runes := 0
	for i in 0..<len(line) {
		if line[i] & 0xC0 != 0x80 {
			runes += 1
			if runes > 100 {
				return strings.concatenate({line[:i], "…"}, context.temp_allocator)
			}
		}
	}
	return line
}

// limit_detail caps a rendered detail view; max_chars <= 0 leaves it
// unlimited.
limit_detail :: proc(s: string, max_chars: int, a: mem.Allocator) -> string {
	if max_chars <= 0 || rune_len(s) <= max_chars {
		return s
	}
	cut := rune_cut(s, max_chars)
	parts := [4]string{s[:cut], "\n…truncated (", dec(rune_len(s)), " chars total)"}
	return strings.concatenate(parts[:], a)
}
