package tracker

// Full-detail views. Unlike the list layer these read event payloads
// back through the Payload_Fetch port (the manager supplies a
// store-backed batched lookup by uid; the fold's per-header event
// references drive the timeline). Everything transient lives in the temp
// allocator; the returned string is owned by the caller's allocator.

import "core:encoding/json"
import "core:mem"
import "core:strings"

import "src:util"

// Payload_Fetch loads the payloads behind a header's event references in
// batch (one store round trip per chunk — the export path walks every
// sprint × incident, so a per-uid fetch multiplies into thousands of
// single-row SELECTs). The map is allocated on `a`; a uid missing from
// the stream is missing from the map.
Payload_Fetch :: proc(user: rawptr, uids: []string, a: mem.Allocator) -> (payloads: map[string]string)

Fetched_Event :: struct {
	kind:    Event_Kind,
	ts_ms:   i64,
	payload: json.Value,
}

// fetch_events loads and parses the payloads behind one header's event
// references, in total order, through one batched port call. Unreadable
// references are skipped (a foreign writer's vanished row) — the timeline
// shows what survived.
fetch_events :: proc(refs: []Event_Ref, fetch: Payload_Fetch, user: rawptr) -> []Fetched_Event {
	uids := make([]string, len(refs), context.temp_allocator)
	for r, i in refs {
		uids[i] = r.uid
	}
	payloads := fetch(user, uids, context.temp_allocator)

	out := make([dynamic]Fetched_Event, 0, len(refs), context.temp_allocator)
	for ref in refs {
		payload, found := payloads[ref.uid]
		if !found {
			continue
		}
		// Depth/encoding guard: a tampered payload is skipped, not
		// crashed on (the timeline shows what survived).
		if !util.json_sanity_ok(transmute([]u8)payload) {
			continue
		}
		parsed, perr := json.parse_string(payload, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
		if perr != nil {
			continue
		}
		append(&out, Fetched_Event{kind = ref.kind, ts_ms = ref.ts_ms, payload = parsed})
	}
	events := make([]Fetched_Event, len(out), context.temp_allocator)
	for e, i in out {
		events[i] = e
	}
	delete(out)
	return events
}

Priority_Step :: struct {
	priority: string,
	date:     string,
}

// priority_chain walks the creation priority and every priority
// replacement — severity-drift review material.
priority_chain :: proc(events: []Fetched_Event) -> []Priority_Step {
	out := make([dynamic]Priority_Step, 0, 4, context.temp_allocator)
	for ev in events {
		#partial switch ev.kind {
		case .Incident_Created:
			d, reason := decode_incident_created(ev.payload, context.temp_allocator)
			if reason != "" {
				continue
			}
			p := d.priority
			if p == "" {
				p = priority_string(.Medium)
			}
			append(&out, Priority_Step{priority = p, date = date_of(ev.ts_ms, context.temp_allocator)})
		case .Incident_Fields_Changed:
			d, reason := decode_incident_fields_changed(ev.payload, context.temp_allocator)
			if reason != "" || !d.priority_set {
				continue
			}
			append(&out, Priority_Step{priority = d.priority, date = date_of(ev.ts_ms, context.temp_allocator)})
		case:
		}
	}
	steps := make([]Priority_Step, len(out), context.temp_allocator)
	for st, i in out {
		steps[i] = st
	}
	delete(out)
	return steps
}

deletion_reason :: proc(events: []Fetched_Event) -> string {
	for ev in events {
		if ev.kind != .Incident_Deleted {
			continue
		}
		d, reason := decode_incident_deleted(ev.payload, context.temp_allocator)
		if reason == "" {
			return d.reason
		}
	}
	return ""
}

created_body :: proc(events: []Fetched_Event) -> string {
	for ev in events {
		if ev.kind != .Incident_Created {
			continue
		}
		d, reason := decode_incident_created(ev.payload, context.temp_allocator)
		if reason == "" {
			return d.body_md
		}
	}
	return ""
}

// timeline_section renders one history entry. Events that carry no
// narrative (field swaps, plain status moves, renames) return "" — the
// header already reflects them.
timeline_section :: proc(ev: Fetched_Event) -> string {
	if !kind_meta(ev.kind).narrative {
		return ""
	}
	#partial switch ev.kind {
	case .Incident_Verified:
		d, reason := decode_incident_verified(ev.payload, context.temp_allocator)
		if reason != "" {
			return ""
		}
		return strings.concatenate({
			"### ", date_of(ev.ts_ms, context.temp_allocator), " verified: ", d.verdict,
			"\n", d.reason_md, "\nevidence: ", d.evidence_md,
		}, context.temp_allocator)
	case .Incident_Root_Caused:
		d, reason := decode_incident_root_caused(ev.payload, context.temp_allocator)
		if reason != "" {
			return ""
		}
		return strings.concatenate({
			"### ", date_of(ev.ts_ms, context.temp_allocator), " root cause\n", d.cause_md,
		}, context.temp_allocator)
	case .Incident_Status_Changed:
		d, reason := decode_incident_status_changed(ev.payload, context.temp_allocator)
		if reason != "" || d.to != incident_status_string(.Resolved) {
			return ""
		}
		return strings.concatenate({
			"### ", date_of(ev.ts_ms, context.temp_allocator), " resolved: ", d.resolution,
			"\nevidence: ", d.evidence_md,
		}, context.temp_allocator)
	case .Incident_Note_Appended:
		d, reason := decode_incident_note_appended(ev.payload, context.temp_allocator)
		if reason != "" {
			return ""
		}
		return strings.concatenate({
			"### ", date_of(ev.ts_ms, context.temp_allocator), "\n", d.body_md,
		}, context.temp_allocator)
	case:
		return ""
	}
}

duplicated_by :: proc(s: ^Fold_State, id: string) -> []string {
	out := make([dynamic]string, 0, 2, context.temp_allocator)
	for uid in s.incident_order {
		dep := s.incidents[uid]
		if dep != nil && dep.is_deleted && dep.duplicate_of == id {
			append(&out, dep.id)
		}
	}
	for i in 1..<len(out) {
		j := i
		for j > 0 && out[j-1] > out[j] {
			out[j-1], out[j] = out[j], out[j-1]
			j -= 1
		}
	}
	dups := make([]string, len(out), context.temp_allocator)
	for v, i in out {
		dups[i] = v
	}
	delete(out)
	return dups
}

// detail_incident renders one incident in full: header block, segments
// line, the verification / root-cause / resolution / note timeline, and
// the priority-transition chain. max_chars <= 0 leaves it unlimited.
detail_incident :: proc(
	s: ^Fold_State,
	h: ^Incident_Header,
	fetch: Payload_Fetch,
	fetch_user: rawptr,
	max_chars: int,
	a: mem.Allocator,
) -> string {
	events := fetch_events(h.events[:], fetch, fetch_user)

	b, berr := strings.builder_make_len_cap(0, 256, a)
	if berr != nil {
		return ""
	}
	defer strings.builder_destroy(&b)

	title := flat_line(h.title, context.temp_allocator)
	strings.write_string(&b, h.id)
	strings.write_string(&b, " [")
	strings.write_string(&b, h.priority)
	strings.write_string(&b, "] ")
	switch {
	case h.is_deleted:
		strings.write_string(&b, "DELETED — ")
		strings.write_string(&b, title)
	case h.status == incident_status_string(.Rejected):
		strings.write_string(&b, "REJECTED")
		strings.write_string(&b, paren_suffix(h.fp_pattern, context.temp_allocator))
		strings.write_string(&b, " — ")
		strings.write_string(&b, title)
	case h.status == incident_status_string(.Resolved):
		strings.write_string(&b, "RESOLVED")
		strings.write_string(&b, paren_suffix(h.resolution, context.temp_allocator))
		strings.write_string(&b, " — ")
		strings.write_string(&b, title)
	case:
		strings.write_string(&b, h.status)
		strings.write_string(&b, " — ")
		strings.write_string(&b, title)
	}
	if h.is_anomaly {
		strings.write_string(&b, " !")
	}
	strings.write_string(&b, "\n")

	segs := make([dynamic]string, 0, 8, context.temp_allocator)
	if h.verdict != "" {
		append(&segs, strings.concatenate({
			"verified: ", h.verdict, " ", date_of(h.verified_ms, context.temp_allocator),
		}, context.temp_allocator))
	} else {
		append(&segs, "verified: — (not yet verified)")
	}
	if h.sprint != "" {
		append(&segs, strings.concatenate({"sprint ", h.sprint}, context.temp_allocator))
	}
	if len(h.labels) > 0 {
		append(&segs, strings.concatenate({"labels ", join_strings(h.labels, ", ")}, context.temp_allocator))
	}
	if len(h.blocked_by) > 0 {
		append(&segs, strings.concatenate({"blocked by ", short_list(h.blocked_by, context.temp_allocator)}, context.temp_allocator))
	}
	blocks := dag_dependents(&s.dag, h.id, context.temp_allocator)
	if len(blocks) > 0 {
		append(&segs, strings.concatenate({"blocks ", short_list(blocks, context.temp_allocator)}, context.temp_allocator))
	}
	delete(blocks, context.temp_allocator)
	if h.assignee != "" {
		append(&segs, strings.concatenate({"assignee ", h.assignee}, context.temp_allocator))
	}
	if len(h.aliases) > 0 {
		append(&segs, strings.concatenate({"aliases ", join_strings(h.aliases, ", ")}, context.temp_allocator))
	}
	if h.is_deleted && h.duplicate_of != "" {
		append(&segs, strings.concatenate({"duplicate → ", h.duplicate_of}, context.temp_allocator))
	}
	dup := duplicated_by(s, h.id)
	if len(dup) > 0 {
		append(&segs, strings.concatenate({"duplicated by ", short_list(dup, context.temp_allocator)}, context.temp_allocator))
	}
	for seg, i in segs {
		if i > 0 {
			strings.write_string(&b, " · ")
		}
		strings.write_string(&b, seg)
	}
	strings.write_string(&b, "\n")

	strings.write_string(&b, "created ")
	strings.write_string(&b, date_of(h.created_ms, context.temp_allocator))
	if h.created_by != "" {
		strings.write_string(&b, " by ")
		strings.write_string(&b, h.created_by)
	}
	strings.write_string(&b, " · updated ")
	strings.write_string(&b, date_of(h.updated_ms, context.temp_allocator))
	strings.write_string(&b, " · notes ")
	strings.write_string(&b, dec(h.note_count))
	strings.write_string(&b, "\n")

	chain := priority_chain(events)
	if len(chain) > 1 {
		strings.write_string(&b, "priority: ")
		for step, i in chain {
			if i > 0 {
				strings.write_string(&b, " → ")
			}
			strings.write_string(&b, step.priority)
			strings.write_string(&b, " (")
			strings.write_string(&b, step.date)
			strings.write_string(&b, ")")
		}
		strings.write_string(&b, "\n")
	}
	if h.is_deleted {
		if reason := deletion_reason(events); reason != "" {
			strings.write_string(&b, "deleted: ")
			strings.write_string(&b, reason)
			strings.write_string(&b, "\n")
		}
	}
	if h.is_anomaly {
		strings.write_string(&b, "anomaly: fold inconsistency — data may be stale, operate after refresh\n")
		for i in 0..<len(h.anomaly_detail) {
			if i >= 3 {
				strings.write_string(&b, "…and ")
				strings.write_string(&b, dec(len(h.anomaly_detail) - 3))
				strings.write_string(&b, " more\n")
				break
			}
			strings.write_string(&b, h.anomaly_detail[i])
			strings.write_string(&b, "\n")
		}
	}
	strings.write_string(&b, "\n")
	if body := created_body(events); body != "" {
		strings.write_string(&b, body)
		strings.write_string(&b, "\n\n")
	}
	for ev in events {
		if section := timeline_section(ev); section != "" {
			strings.write_string(&b, section)
			strings.write_string(&b, "\n\n")
		}
	}
	out := strings.clone(strings.to_string(b), a)
	trimmed := strings.trim_space(out)
	return limit_detail(trimmed, max_chars, a)
}

// latest_sprint_body returns the newest body of one sprint field: the
// latest replacement event for it, else the initial value carried by
// the fallback kind. An explicit empty replacement clears the field;
// a replacement event that does not carry the field at all (a must-only
// goal update) leaves it untouched.
latest_sprint_body :: proc(events: []Fetched_Event, replace_kind, initial_kind: Event_Kind) -> string {
	body := ""
	for ev in events { // events arrive in total order
		#partial switch ev.kind {
		case replace_kind:
			if text, present := sprint_body_field(ev); present {
				body = text
			}
		case initial_kind:
			if body == "" {
				if text, present := sprint_body_field(ev); present {
					body = text
				}
			}
		case:
		}
	}
	return body
}

sprint_body_field :: proc(ev: Fetched_Event) -> (body: string, present: bool) {
	#partial switch ev.kind {
	case .Sprint_Goal_Updated:
		d, reason := decode_sprint_goal_updated(ev.payload, context.temp_allocator)
		if reason == "" && d.goal_set {
			return d.goal_md, true
		}
	case .Sprint_Note_Appended:
		d, reason := decode_sprint_note_appended(ev.payload, context.temp_allocator)
		if reason == "" {
			return d.body_md, true
		}
	case .Sprint_Outcome_Updated:
		d, reason := decode_sprint_outcome_updated(ev.payload, context.temp_allocator)
		if reason == "" {
			return d.outcome_md, true
		}
	case .Sprint_Started:
		d, reason := decode_sprint_started(ev.payload, context.temp_allocator)
		if reason == "" {
			return d.goal_md, true
		}
	case .Sprint_Closed:
		d, reason := decode_sprint_closed(ev.payload, context.temp_allocator)
		if reason == "" {
			return d.outcome_md, true
		}
	case:
	}
	return "", false
}

// detail_sprint renders one sprint in full: header, scoped counts, the
// current goal, the decision-note timeline, and — once closed — the
// outcome with the FP statistics.
detail_sprint :: proc(
	s: ^Fold_State,
	spr: ^Sprint_Header,
	fetch: Payload_Fetch,
	fetch_user: rawptr,
	max_chars: int,
	a: mem.Allocator,
) -> string {
	events := fetch_events(spr.events[:], fetch, fetch_user)

	b, berr := strings.builder_make_len_cap(0, 192, a)
	if berr != nil {
		return ""
	}
	defer strings.builder_destroy(&b)

	strings.write_string(&b, spr.id)
	strings.write_string(&b, " '")
	strings.write_string(&b, spr.name)
	strings.write_byte(&b, '\'')
	strings.write_byte(&b, ' ')
	strings.write_string(&b, sprint_status_string(spr.status))
	strings.write_string(&b, " — started ")
	strings.write_string(&b, date_of(spr.started_ms, context.temp_allocator))
	if spr.status == .Closed {
		strings.write_string(&b, ", closed ")
		strings.write_string(&b, date_of(spr.closed_ms, context.temp_allocator))
	}
	if spr.follows != "" {
		strings.write_string(&b, " — follows ")
		strings.write_string(&b, spr.follows)
	}
	strings.write_string(&b, "\n")

	// The census covers the filed cohort — the same population the report
	// statistics and incident list count — for active and closed sprints
	// alike. The FP rate comes off the cohort's current verdicts.
	cohort := sprint_cohort(s, spr, context.temp_allocator)
	cen := census_of(cohort)
	rejected := 0
	judged := 0
	for h in cohort {
		if h.verdict != "" {
			judged += 1
			if h.verdict == verdict_string(.Rejected) {
				rejected += 1
			}
		}
	}
	delete(cohort, context.temp_allocator)
	strings.write_string(&b, counts_header_line(&cen, context.temp_allocator))
	if rejected > 0 && judged > 0 {
		rate := int(f64(rejected) / f64(judged) * 100)
		strings.write_string(&b, strings.concatenate({
			" (FP rate ", dec(rate), "%)",
		}, context.temp_allocator))
	}
	strings.write_string(&b, "\n\n")

	if goal := latest_sprint_body(events, .Sprint_Goal_Updated, .Sprint_Started); goal != "" {
		strings.write_string(&b, "goal:\n")
		strings.write_string(&b, goal)
		strings.write_string(&b, "\n\n")
	}
	// The must-task block is the round's derived work state: each task's
	// latest verification record (definition + output digest) or its defer.
	if len(spr.must) > 0 {
		strings.write_string(&b, "must tasks:\n")
		for task in spr.must {
			strings.write_string(&b, "- ")
			strings.write_string(&b, task)
			strings.write_string(&b, ": ")
			v := task_latest_verif(spr, task)
			defer_id := sprint_task_defer(s, spr, task)
			if v != nil {
				strings.write_string(&b, v.outcome)
				strings.write_string(&b, " (")
				strings.write_string(&b, v.definition)
				strings.write_string(&b, ", ")
				strings.write_string(&b, date_of(v.ts_ms, context.temp_allocator))
				strings.write_string(&b, ")\n  output: ")
				strings.write_string(&b, first_line_capped(v.output))
				if defer_id != "" {
					strings.write_string(&b, "\n  deferred (")
					strings.write_string(&b, defer_id)
					strings.write_string(&b, ")")
				}
			} else if defer_id != "" {
				strings.write_string(&b, "deferred (")
				strings.write_string(&b, defer_id)
				strings.write_string(&b, ")")
			} else {
				strings.write_string(&b, "unverified")
			}
			strings.write_string(&b, "\n")
		}
		strings.write_string(&b, "\n")
	}
	for ev in events {
		if ev.kind != .Sprint_Note_Appended {
			continue
		}
		d, reason := decode_sprint_note_appended(ev.payload, context.temp_allocator)
		if reason != "" {
			continue
		}
		strings.write_string(&b, "### ")
		strings.write_string(&b, date_of(ev.ts_ms, context.temp_allocator))
		if d.defer_type != "" {
			strings.write_string(&b, " — defer ")
			strings.write_string(&b, d.defer_type)
			strings.write_string(&b, " ")
			strings.write_string(&b, d.defer_id)
			if d.task != "" {
				strings.write_string(&b, " (task ")
				strings.write_string(&b, d.task)
				strings.write_string(&b, ")")
			}
			if d.ref != "" {
				strings.write_string(&b, " ref ")
				strings.write_string(&b, d.ref)
			}
		} else if d.resolves != "" {
			strings.write_string(&b, " — answers ")
			strings.write_string(&b, d.resolves)
		}
		strings.write_string(&b, "\n")
		strings.write_string(&b, d.body_md)
		strings.write_string(&b, "\n\n")
	}
	// The typed-defer roll-up of this round's decision log (the notes above
	// carry the bodies; this block carries the states).
	if dt, _ := sprint_defer_stats(s, spr); dt > 0 {
		strings.write_string(&b, "defers:\n")
		for id in s.defer_order {
			d := defer_by_id(s, id)
			if d == nil || d.sprint != spr.id {
				continue
			}
			strings.write_string(&b, "- ")
			strings.write_string(&b, d.id)
			strings.write_string(&b, " ")
			strings.write_string(&b, d.kind)
			if d.task != "" {
				strings.write_string(&b, " (task ")
				strings.write_string(&b, d.task)
				strings.write_string(&b, ")")
			}
			if d.ref != "" {
				strings.write_string(&b, " ref ")
				strings.write_string(&b, d.ref)
			}
			strings.write_string(&b, ": ")
			strings.write_string(&b, first_line_capped(d.body_md))
			if d.resolved_ms != 0 {
				strings.write_string(&b, " [answered ")
				strings.write_string(&b, date_of(d.resolved_ms, context.temp_allocator))
				strings.write_string(&b, " by ")
				strings.write_string(&b, d.resolved_by)
				strings.write_string(&b, "]")
			}
			strings.write_string(&b, "\n")
		}
		strings.write_string(&b, "\n")
	}
	if spr.status == .Closed {
		if outcome := latest_sprint_body(events, .Sprint_Outcome_Updated, .Sprint_Closed); outcome != "" {
			strings.write_string(&b, "outcome:\n")
			strings.write_string(&b, outcome)
			strings.write_string(&b, "\n\n")
		}
	}
	out := strings.clone(strings.to_string(b), a)
	trimmed := strings.trim_space(out)
	return limit_detail(trimmed, max_chars, a)
}

// sprint_list assembles the sprint list output: the active line first
// (live progress and goal headline), closed lines newest-first when
// included.
sprint_list :: proc(
	s: ^Fold_State,
	fetch: Payload_Fetch,
	fetch_user: rawptr,
	include_closed: bool,
	limit_in: int,
	now_ms: i64,
	a: mem.Allocator,
) -> string {
	b, berr := strings.builder_make_len_cap(0, 96, a)
	if berr != nil {
		return ""
	}
	defer strings.builder_destroy(&b)
	wrote := false

	closed := make([dynamic]^Sprint_Header, 0, 4, context.temp_allocator)
	for id in s.sprint_order {
		spr := s.sprints[id]
		if spr != nil && spr.status == .Closed {
			append(&closed, spr)
		}
	}
	// newest-first by close time
	for i in 1..<len(closed) {
		j := i
		for j > 0 && closed[j].closed_ms > closed[j-1].closed_ms {
			closed[j], closed[j-1] = closed[j-1], closed[j]
			j -= 1
		}
	}

	active := active_sprint(s)
	if active != nil {
		// The active line summarizes the filed cohort (the round's
		// detection), not the assignment set — same population as the
		// report. Live-work views (open summary) keep membership.
		cohort := sprint_cohort(s, active, context.temp_allocator)
		cen := census_of(cohort)
		strings.write_string(&b, active.id)
		strings.write_string(&b, " '")
		strings.write_string(&b, active.name)
		strings.write_string(&b, "' active: ")
		strings.write_string(&b, dec(cen.counts.resolved))
		strings.write_string(&b, "/")
		strings.write_string(&b, dec(cen.total))
		strings.write_string(&b, " resolved")
		if _, open_q := sprint_defer_stats(s, active); open_q > 0 {
			strings.write_string(&b, ", ")
			strings.write_string(&b, dec(open_q))
			strings.write_string(&b, " open question")
			if open_q > 1 {
				strings.write_byte(&b, 's')
			}
		}
		if oldest := oldest_open(cohort); oldest != nil {
			strings.write_string(&b, ", oldest open ")
			strings.write_string(&b, oldest.id)
			strings.write_string(&b, " (")
			strings.write_string(&b, rel_time(oldest.created_ms, now_ms))
			strings.write_string(&b, ")")
		}
		delete(cohort, context.temp_allocator)
		wrote = true
		events := fetch_events(active.events[:], fetch, fetch_user)
		if goal := latest_sprint_body(events, .Sprint_Goal_Updated, .Sprint_Started); goal != "" {
			first := strings.trim_space(goal)
			if i := strings.index_byte(first, '\n'); i >= 0 {
				first = first[:i]
			}
			strings.write_string(&b, "\n  goal: ")
			strings.write_string(&b, truncate_runes(first, 120, context.temp_allocator))
		}
	} else if !(include_closed && len(closed) > 0) {
		strings.write_string(&b, "no active sprint — sprint_start to start one")
		wrote = true
	}
	if include_closed {
		limit := limit_in
		if limit == 0 {
			limit = DEFAULT_LIST_LIMIT
		}
		hidden := 0
		shown := closed[:]
		if limit >= 0 && len(closed) > limit {
			shown = closed[:limit]
			hidden = len(closed) - limit
		}
		for spr in shown {
			// Closed lines carry the filed cohort's outcomes — the same
			// numbers the report's statistics section shows.
			st := sprint_stats(s, spr, context.temp_allocator)
			if wrote {
				strings.write_string(&b, "\n")
			}
			strings.write_string(&b, spr.id)
			strings.write_string(&b, " '")
			strings.write_string(&b, spr.name)
			strings.write_string(&b, "' closed ")
			strings.write_string(&b, date_of(spr.closed_ms, context.temp_allocator))
			strings.write_string(&b, ": filed ")
			strings.write_string(&b, dec(st.total))
			if st.resolved > 0 {
				strings.write_string(&b, ", ")
				strings.write_string(&b, dec(st.resolved))
				strings.write_string(&b, " resolved")
			}
			if st.rejected > 0 {
				strings.write_string(&b, ", ")
				strings.write_string(&b, dec(st.rejected))
				strings.write_string(&b, " rejected (FP rate ")
				strings.write_string(&b, dec(int(st.fp_rate * 100)))
				strings.write_string(&b, "%)")
			}
			sprint_stats_destroy(st, context.temp_allocator)
			free(st, context.temp_allocator)
			wrote = true
		}
		if hidden > 0 {
			if wrote {
				strings.write_string(&b, "\n")
			}
			strings.write_string(&b, "…and ")
			strings.write_string(&b, dec(hidden))
			strings.write_string(&b, " more")
		}
	}
	delete(closed)
	return strings.clone(strings.to_string(b), a)
}
