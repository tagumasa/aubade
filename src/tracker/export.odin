package tracker

// The derived report renders: per-sprint audit reports (stored as
// sprint_reports rows by the manager) and the structured TSV/JSON
// incident report. This layer renders only — the returned strings are
// regenerable views of the event log; storage belongs to the manager
// and its store. Reports compose with \n; a caller that persists them
// as files translates the bytes to the project's line-ending convention
// in one pass (report_apply_line_ending), which also folds any \r\n
// pair embedded by user-authored note/goal/outcome bodies into that one
// newline.

import "core:mem"
import "core:strings"

import "src:jsonutil"

Report_Format :: enum {
	TSV,
	JSON,
}

// REPORT_FORMAT_NAMES is the one spelling table for Report_Format: the
// CLI's --format parsing derives from it.
REPORT_FORMAT_NAMES :: []string{"tsv", "json"}

// report_format_from_string parses one format spelling by traversing the
// names table (the from_string half of the single declaration).
report_format_from_string :: proc(s: string) -> (format: Report_Format, ok: bool) {
	names := REPORT_FORMAT_NAMES
	for candidate in Report_Format {
		if names[cast(int)candidate] == s {
			return candidate, true
		}
	}
	return .TSV, false
}

// report_format_string renders one format spelling from the same table.
report_format_string :: proc(format: Report_Format) -> string {
	names := REPORT_FORMAT_NAMES
	return names[cast(int)format]
}

// sprint_report renders one sprint's audit report: the sprint detail
// view, the statistics matrix, and every finding filed during the sprint
// window. ONE population: the statistics and the incident list count
// exactly the same set — findings created inside the window
// [started_ms, closed_ms], deleted excluded — so every number can be
// re-counted from the list below. Outcomes are current: verdicts and
// resolutions landing after close keep updating these numbers (re-export
// refreshes). Membership (the sprint field) is work grouping and never
// enters the report's counts.
sprint_report :: proc(
	s: ^Fold_State,
	spr: ^Sprint_Header,
	fetch: Payload_Fetch,
	fetch_user: rawptr,
	a: mem.Allocator,
) -> string {
	b, berr := strings.builder_make_len_cap(0, 512, a)
	if berr != nil {
		return ""
	}
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "# ")
	strings.write_string(&b, spr.id)
	strings.write_string(&b, " '")
	strings.write_string(&b, spr.name)
	strings.write_string(&b, "' — sprint report\n\n")
	strings.write_string(&b, detail_sprint(s, spr, fetch, fetch_user, 0, a))
	strings.write_string(&b, "\n\n## Statistics — findings filed during the sprint window\n\n")
	st := sprint_stats(s, spr, a)
	write_stats_matrix(&b, st, a)
	sprint_stats_destroy(st, a)
	free(st, a)

	strings.write_string(&b, "\n## Findings filed during the sprint window (the population of the statistics above)\n")
	filed := sprint_cohort(s, spr, a)
	defer delete(filed, a)
	for i in 1..<len(filed) {
		j := i
		for j > 0 && filed[j].created_ms < filed[j-1].created_ms {
			filed[j], filed[j-1] = filed[j-1], filed[j]
			j -= 1
		}
	}
	if len(filed) == 0 {
		strings.write_string(&b, "\n(none)\n")
	}
	for h in filed {
		strings.write_string(&b, "\n")
		strings.write_string(&b, detail_incident(s, h, fetch, fetch_user, 0, a))
		strings.write_string(&b, "\n")
	}
	trimmed := strings.trim_right_space(strings.to_string(b))
	return strings.concatenate({trimmed, "\n"}, a)
}

// sprint_stats computes the sprint's statistics live from the headers
// over the filed cohort — active and closed sprints alike. The result is
// caller-owned: destroy with sprint_stats_destroy.
sprint_stats :: proc(s: ^Fold_State, spr: ^Sprint_Header, a: mem.Allocator) -> ^Sprint_Stats {
	return compute_sprint_stats(s, spr, a)
}

// write_stats_matrix renders the sprint statistics as markdown: one row
// per label with the priority split, then the FP-pattern tally, then the
// explicitly-scoped cross-cohort window activity.
write_stats_matrix :: proc(b: ^strings.Builder, st: ^Sprint_Stats, a: mem.Allocator) {
	labels := make([dynamic]string, 0, len(st.by_label), a)
	defer delete(labels)
	for label in st.by_label {
		append(&labels, label)
	}
	for i in 1..<len(labels) {
		j := i
		for j > 0 && labels[j-1] > labels[j] {
			labels[j-1], labels[j] = labels[j], labels[j-1]
			j -= 1
		}
	}
	if len(labels) == 0 {
		strings.write_string(b, "(no labeled findings)\n")
	} else {
		strings.write_string(b, "| label | urgent | high | medium | low | total | confirmed | rejected | unjudged | resolved | FP rate |\n")
		strings.write_string(b, "|---|---|---|---|---|---|---|---|---|---|---|\n")
		for label in labels {
			ls := st.by_label[label]
			strings.write_string(b, "| ")
			strings.write_string(b, label)
			for i in 0..<4 {
				strings.write_string(b, " | ")
				strings.write_string(b, dec(ls.by_priority[priority_string(Priority(i))]))
			}
			strings.write_string(b, " | ")
			strings.write_string(b, dec(ls.total))
			strings.write_string(b, " | ")
			strings.write_string(b, dec(ls.confirmed))
			strings.write_string(b, " | ")
			strings.write_string(b, dec(ls.rejected))
			strings.write_string(b, " | ")
			strings.write_string(b, dec(ls.unjudged))
			strings.write_string(b, " | ")
			strings.write_string(b, dec(ls.resolved))
			strings.write_string(b, " | ")
			strings.write_string(b, dec(int(ls.fp_rate * 100)))
			strings.write_string(b, "% |\n")
		}
	}
	// The FP tally is independent of the label matrix — a sprint whose
	// findings are unlabeled still reports its rejected patterns.
	patterns := make([dynamic]string, 0, len(st.by_pattern), a)
	defer delete(patterns)
	for p in st.by_pattern {
		append(&patterns, p)
	}
	for i in 1..<len(patterns) {
		j := i
		for j > 0 && patterns[j-1] > patterns[j] {
			patterns[j-1], patterns[j] = patterns[j], patterns[j-1]
			j -= 1
		}
	}
	if len(patterns) > 0 {
		strings.write_string(b, "\nFP patterns: ")
		for p, i in patterns {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, p)
			strings.write_byte(b, ' ')
			strings.write_string(b, dec(st.by_pattern[p]))
		}
		strings.write_string(b, "\n")
	}
	// Cross-cohort window activity, scoped explicitly apart: verdicts and
	// resolutions recorded inside the window on findings filed before it.
	// They never enter the matrix above.
	if st.judged_earlier > 0 || st.resolved_earlier > 0 {
		strings.write_string(b, "\nthis window, on findings filed earlier: ")
		wrote := false
		if st.judged_earlier > 0 {
			strings.write_string(b, "judged ")
			strings.write_string(b, dec(st.judged_earlier))
			wrote = true
		}
		if st.resolved_earlier > 0 {
			if wrote {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, "resolved ")
			strings.write_string(b, dec(st.resolved_earlier))
		}
		strings.write_string(b, "\n")
	}
}

// report_apply_line_ending translates composed-\n report text to the
// project's write convention in one pass ("" or "lf" is a no-op).
// Composition normally emits \n only, but user-authored bodies (notes,
// goals, outcomes) are embedded verbatim and may carry \r\n — a pair is
// one logical newline and folds to a single target newline, so a CRLF
// convention cannot inflate it to \r\r\n. A lone \r is content and
// passes through.
report_apply_line_ending :: proc(content: string, newline: string, a: mem.Allocator) -> string {
	if newline == "" || newline == "\n" {
		return content
	}
	b, berr := strings.builder_make_len_cap(0, len(content), a)
	if berr != nil {
		return content
	}
	defer strings.builder_destroy(&b)
	i := 0
	for i < len(content) {
		c := content[i]
		if c == '\r' && i + 1 < len(content) && content[i + 1] == '\n' {
			strings.write_string(&b, newline)
			i += 2
		} else if c == '\n' {
			strings.write_string(&b, newline)
			i += 1
		} else {
			strings.write_byte(&b, c)
			i += 1
		}
	}
	return strings.clone(strings.to_string(b), a)
}

// ---------------------------------------------------------------------------
// Structured incident report (TSV / JSON)

report_incidents :: proc(format: Report_Format, headers: []^Incident_Header, a: mem.Allocator) -> string {
	switch format {
	case .TSV:
		return render_incidents_tsv(headers, a)
	case .JSON:
		return render_incidents_json(headers, a)
	}
	return ""
}

// Field_Kind is how one incident field renders in the two export
// formats: the cell text is shared wherever possible, and the kind owns
// the JSON-specific quoting.
Field_Kind :: enum {
	String, // quoted JSON member, null when empty
	Array,  // JSON array; TSV joins the values with ';'
	Raw,    // JSON takes the cell verbatim (numbers, booleans); TSV same
	Date,   // JSON always quotes the cell (an empty date is "", not null)
}

// Incident_Field is one exported column. INCIDENT_FIELDS is the single
// declaration of the column set and order: the TSV header, the TSV row
// cells, and the JSON members all walk it, so the two formats cannot
// drift apart.
Incident_Field :: struct {
	key:    string,
	kind:   Field_Kind,
	text:   proc(h: ^Incident_Header, a: mem.Allocator) -> string, // .String/.Raw/.Date cell
	values: proc(h: ^Incident_Header) -> []string,                // .Array source (borrowed from the header)
}

field_id :: proc(h: ^Incident_Header, a: mem.Allocator) -> string {
	return h.id
}

field_title :: proc(h: ^Incident_Header, a: mem.Allocator) -> string {
	return h.title
}

field_status :: proc(h: ^Incident_Header, a: mem.Allocator) -> string {
	return h.status
}

field_priority :: proc(h: ^Incident_Header, a: mem.Allocator) -> string {
	return h.priority
}

field_labels :: proc(h: ^Incident_Header) -> []string {
	return h.labels
}

field_sprint :: proc(h: ^Incident_Header, a: mem.Allocator) -> string {
	return h.sprint
}

field_assignee :: proc(h: ^Incident_Header, a: mem.Allocator) -> string {
	return h.assignee
}

field_created_by :: proc(h: ^Incident_Header, a: mem.Allocator) -> string {
	return h.created_by
}

field_verdict :: proc(h: ^Incident_Header, a: mem.Allocator) -> string {
	return h.verdict
}

field_fp_pattern :: proc(h: ^Incident_Header, a: mem.Allocator) -> string {
	return h.fp_pattern
}

field_resolution :: proc(h: ^Incident_Header, a: mem.Allocator) -> string {
	return h.resolution
}

field_blocked_by :: proc(h: ^Incident_Header) -> []string {
	return h.blocked_by
}

field_aliases :: proc(h: ^Incident_Header) -> []string {
	return h.aliases
}

field_note_count :: proc(h: ^Incident_Header, a: mem.Allocator) -> string {
	return dec(h.note_count)
}

field_anomaly :: proc(h: ^Incident_Header, a: mem.Allocator) -> string {
	if h.is_anomaly {
		return "true"
	}
	return "false"
}

field_created :: proc(h: ^Incident_Header, a: mem.Allocator) -> string {
	return date_of(h.created_ms, a)
}

field_updated :: proc(h: ^Incident_Header, a: mem.Allocator) -> string {
	return date_of(h.updated_ms, a)
}

field_verified :: proc(h: ^Incident_Header, a: mem.Allocator) -> string {
	return date_of(h.verified_ms, a)
}

field_resolved :: proc(h: ^Incident_Header, a: mem.Allocator) -> string {
	return date_of(h.resolved_ms, a)
}

INCIDENT_FIELDS :: []Incident_Field{
	{key = "id",          kind = .String, text = field_id},
	{key = "title",       kind = .String, text = field_title},
	{key = "status",      kind = .String, text = field_status},
	{key = "priority",    kind = .String, text = field_priority},
	{key = "labels",      kind = .Array,  values = field_labels},
	{key = "sprint",      kind = .String, text = field_sprint},
	{key = "assignee",    kind = .String, text = field_assignee},
	{key = "created_by",  kind = .String, text = field_created_by},
	{key = "verdict",     kind = .String, text = field_verdict},
	{key = "fp_pattern",  kind = .String, text = field_fp_pattern},
	{key = "resolution",  kind = .String, text = field_resolution},
	{key = "blocked_by",  kind = .Array,  values = field_blocked_by},
	{key = "aliases",     kind = .Array,  values = field_aliases},
	{key = "notes",       kind = .Raw,    text = field_note_count},
	{key = "anomaly",     kind = .Raw,    text = field_anomaly},
	{key = "created",     kind = .Date,   text = field_created},
	{key = "updated",     kind = .Date,   text = field_updated},
	{key = "verified",    kind = .Date,   text = field_verified},
	{key = "resolved",    kind = .Date,   text = field_resolved},
}

render_incidents_tsv :: proc(headers: []^Incident_Header, a: mem.Allocator) -> string {
	b, berr := strings.builder_make_len_cap(0, 256, a)
	if berr != nil {
		return ""
	}
	defer strings.builder_destroy(&b)
	fields := INCIDENT_FIELDS
	for f, i in fields {
		if i > 0 {
			strings.write_byte(&b, '\t')
		}
		strings.write_string(&b, f.key)
	}
	strings.write_string(&b, "\n")
	for h in headers {
		cells := incident_tsv_row(h, context.temp_allocator)
		for cell, i in cells {
			if i > 0 {
				strings.write_byte(&b, '\t')
			}
			strings.write_string(&b, tsv_escape(cell, context.temp_allocator))
		}
		strings.write_string(&b, "\n")
	}
	return strings.clone(strings.to_string(b), a)
}

incident_tsv_row :: proc(h: ^Incident_Header, a: mem.Allocator) -> []string {
	fields := INCIDENT_FIELDS
	cells := make([]string, len(fields), a)
	for f, i in fields {
		if f.kind == .Array {
			cells[i] = join_strings(f.values(h), ";")
		} else {
			cells[i] = f.text(h, a)
		}
	}
	return cells
}

// tsv_escape keeps a field on one line and in one column: TSV has no
// quoting convention, so backslash, tab, CR, and LF become visible
// escapes instead.
tsv_escape :: proc(s: string, a: mem.Allocator) -> string {
	needs := false
	for i in 0..<len(s) {
		c := s[i]
		if c == '\\' || c == '\t' || c == '\r' || c == '\n' {
			needs = true
			break
		}
	}
	if !needs {
		return s
	}
	b, berr := strings.builder_make_len_cap(0, len(s) + 8, a)
	if berr != nil {
		return s
	}
	defer strings.builder_destroy(&b)
	for i in 0..<len(s) {
		switch s[i] {
		case '\\':
			strings.write_string(&b, "\\\\")
		case '\t':
			strings.write_string(&b, "\\t")
		case '\r':
			strings.write_string(&b, "\\r")
		case '\n':
			strings.write_string(&b, "\\n")
		case:
			strings.write_byte(&b, s[i])
		}
	}
	return strings.clone(strings.to_string(b), a)
}

render_incidents_json :: proc(headers: []^Incident_Header, a: mem.Allocator) -> string {
	b, berr := strings.builder_make_len_cap(0, 256, a)
	if berr != nil {
		return ""
	}
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "[")
	fields := INCIDENT_FIELDS
	for h, idx in headers {
		if idx > 0 {
			strings.write_string(&b, ",")
		}
		strings.write_string(&b, "\n  {")
		for f, i in fields {
			comma := i < len(fields) - 1
			switch f.kind {
			case .Array:
				write_json_array_field(&b, f.key, f.values(h), comma)
			case .String:
				write_json_field(&b, f.key, f.text(h, context.temp_allocator), comma)
			case .Raw:
				write_json_raw_field(&b, f.key, f.text(h, context.temp_allocator), comma)
			case .Date:
				write_json_date_field(&b, f.key, f.text(h, context.temp_allocator), comma)
			}
		}
		strings.write_string(&b, "\n  }")
	}
	if len(headers) > 0 {
		strings.write_string(&b, "\n")
	}
	strings.write_string(&b, "]\n")
	return strings.clone(strings.to_string(b), a)
}

@(private)
write_json_raw_field :: proc(b: ^strings.Builder, key: string, value: string, comma: bool) {
	strings.write_string(b, "\n    \"")
	strings.write_string(b, key)
	strings.write_string(b, "\": ")
	strings.write_string(b, value)
	if comma {
		strings.write_string(b, ",")
	}
}

@(private)
write_json_date_field :: proc(b: ^strings.Builder, key: string, value: string, comma: bool) {
	strings.write_string(b, "\n    \"")
	strings.write_string(b, key)
	strings.write_string(b, "\": ")
	strings.write_string(b, jsonutil.json_quote(value, context.temp_allocator))
	if comma {
		strings.write_string(b, ",")
	}
}

@(private)
write_json_field :: proc(b: ^strings.Builder, key: string, value: string, comma: bool) {
	strings.write_string(b, "\n    \"")
	strings.write_string(b, key)
	strings.write_string(b, "\": ")
	if value == "" {
		strings.write_string(b, "null")
	} else {
		strings.write_string(b, jsonutil.json_quote(value, context.temp_allocator))
	}
	if comma {
		strings.write_string(b, ",")
	}
}

@(private)
write_json_array_field :: proc(b: ^strings.Builder, key: string, values: []string, comma: bool) {
	strings.write_string(b, "\n    \"")
	strings.write_string(b, key)
	strings.write_string(b, "\": [")
	for v, i in values {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, jsonutil.json_quote(v, context.temp_allocator))
	}
	strings.write_string(b, "]")
	if comma {
		strings.write_string(b, ",")
	}
}

