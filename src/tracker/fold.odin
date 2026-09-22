package tracker

// The pure fold: applying events in uid total order derives the incident
// and sprint headers, the display-ID numbering, and the blocked_by DAG.
// No I/O — the manager feeds decoded events in and consumes state. The
// fold never dies: every violation (malformed payload, orphan target,
// illegal transition) is absorbed as an anomaly line on the header or the
// state-level list; a clean later event clears the header's anomaly.
//
// Ownership: every string backing kept by the state is a clone in the
// state allocator (copy-in). Map keys, order arrays, and the DAG's own
// key clones follow the same rule; headers own their IDs/UIDs and the
// seen_uids/aliases maps own theirs. Payload decoding happens in the
// caller's scratch arena, freed after the apply.
//
// A touched-headers drain is deliberately absent: the SQLite design has
// no derived index to feed — the fold state is the index.

import "core:fmt"
import "core:mem"
import "core:strings"

Counts :: struct {
	total:       int,
	open:        int,
	reported:    int,
	confirmed:   int,
	root_caused: int,
	resolved:    int,
	rejected:    int,
}

Label_Stats :: struct {
	total:       int,
	confirmed:   int,
	rejected:    int,
	unjudged:    int,
	resolved:    int,
	fp_rate:     f64,
	by_priority: map[string]int, // owned keys
}

// Sprint_Stats covers exactly one population: the findings filed (created)
// inside the sprint's window, deleted excluded — the same set the sprint
// report lists. Membership (the sprint field) is work grouping and never
// enters these numbers; outcomes are the cohort's CURRENT verdict/status,
// so later verdicts and resolutions keep updating the filing round's
// statistics. judged_earlier/resolved_earlier count window activity on
// findings filed before the window (fix and verify rounds) — they are
// explicitly out-of-cohort and never mix into the counts above.
Sprint_Stats :: struct {
	sprint_id:        string, // owned
	total:            int,
	confirmed:        int,
	rejected:         int,
	unjudged:         int,
	resolved:         int,
	judged_earlier:   int,
	resolved_earlier: int,
	fp_rate:          f64, // rejected / (confirmed + rejected); unjudged stays out of the denominator
	by_label:         map[string]^Label_Stats, // owned keys and values
	by_priority:      map[string]int,          // owned keys
	by_pattern:       map[string]int,          // owned keys
	cohort:           [dynamic]string, // owned clones — the filed-in-window incident ids
	anomalies:        int,
}

Status_Event_Ref :: struct {
	kind:   Event_Kind,
	ts_ms:  i64,
	origin: string, // owned
}

// Event_Ref identifies one applied event on a header's timeline; the uid
// is owned. Detail rendering fetches the payload from the store by uid.
Event_Ref :: struct {
	uid:   string,
	kind:  Event_Kind,
	ts_ms: i64,
}

Incident_Header :: struct {
	uid:            string, // owned
	id:             string, // owned (INC-%03d)
	title:          string,
	status:         string, // wire vocabulary; foreign events may carry unknowns
	priority:       string,
	labels:         []string, // owned elements
	sprint:         string,
	blocked_by:     []string, // owned elements
	assignee:       string,
	aliases:        []string, // owned elements
	created_by:     string,
	verdict:        string,
	fp_pattern:     string,
	created_ms:     i64,
	updated_ms:     i64,
	verified_ms:    i64,
	resolved_ms:    i64,
	resolution:     string,
	is_deleted:     bool,
	duplicate_of:   string,
	is_anomaly:     bool,
	anomaly_detail: [dynamic]string, // owned elements
	last_status:    Status_Event_Ref,
	note_count:     int,
	events:         [dynamic]Event_Ref, // owned uids
}

Sprint_Status :: enum {
	Active,
	Closed,
}

sprint_status_string :: proc(st: Sprint_Status) -> string {
	switch st {
	case .Active: return "active"
	case .Closed: return "closed"
	}
	return "<invalid-sprint-status>"
}

sprint_status_from_string :: proc(s: string) -> (Sprint_Status, bool) {
	for st in Sprint_Status {
		if sprint_status_string(st) == s {
			return st, true
		}
	}
	return .Active, false
}

// Task_Verif is one verification record materialized on the sprint header:
// the server-held evidence behind a task's derived "verified" state. The
// task's state is the LATEST record's outcome — a failed re-run un-verifies.
Task_Verif :: struct {
	task:       string, // owned
	definition: string, // owned — the versioned verification asset executed
	outcome:    string, // owned (Verif_Outcome vocabulary)
	output:     string, // owned — the execution output digest
	session:    string, // owned — originating session label (optional)
	ts_ms:      i64,
}

Sprint_Header :: struct {
	id:            string, // owned (SPR-%03d)
	name:          string,
	status:        Sprint_Status,
	started_ms:    i64,
	closed_ms:     i64,
	follows:       string,
	must:          []string, // owned elements — the structured must-task list
	verifications: [dynamic]Task_Verif, // owned
	events:        [dynamic]Event_Ref,
}

// Defer_Record is one typed deferral on a round's decision log (filed through
// a sprint note). Records live in the fold state, not the sprint header:
// open questions outlive their round — they stay visible until answered or
// descoped, whichever round does it.
Defer_Record :: struct {
	id:          string, // owned (DEF-%03d), minted by the writer
	sprint:      string, // owned (SPR-%03d) — the round it was filed in
	kind:        string, // owned (Defer_Kind vocabulary)
	body_md:     string, // owned — the question text / rationale / blocked note
	task:        string, // owned — the task-table row it covers (optional)
	ref:         string, // owned — the blocked defer's obstacle reference
	ts_ms:       i64,
	resolved_ms: i64, // 0 = open
	resolved_by: string, // owned — the answering record's defer id, or "note"
}

Fold_State :: struct {
	allocator:      mem.Allocator,
	incidents:      map[string]^Incident_Header, // uid key owned by the header
	incident_order: [dynamic]string, // borrowed uids, creation order
	inc_count:      int,
	// Incident indices: alias and display-id lookups (borrowed headers)
	// and the replay seen-set.
	aliases:        map[string]^Incident_Header, // owned alias keys, borrowed headers
	id_to_uid:      map[string]^Incident_Header, // borrowed id keys, borrowed headers
	seen_uids:      map[string]bool, // owned keys
	sprints:        map[string]^Sprint_Header, // id key owned by the header
	sprint_order:   [dynamic]string, // borrowed ids
	spr_count:      int,
	defers:         map[string]^Defer_Record, // id key owned by the record
	defer_order:    [dynamic]string, // borrowed ids
	defer_count:    int,
	dag:            DAG,
	anomalies:      [dynamic]string, // owned elements
	last_uid:       string, // owned
}

fold_state_init :: proc(s: ^Fold_State, a: mem.Allocator) {
	// Every map and dynamic is made here on purpose: a zero-value map or
	// dynamic auto-grows through context.allocator at the first insert,
	// which is the caller's allocator, not the state's — ownership would
	// silently leave the fold. Made collections carry their allocator.
	s^ = {
		allocator              = a,
		incidents      = make(map[string]^Incident_Header, 16, a),
		incident_order = make([dynamic]string, 0, 64, a),
		sprints        = make(map[string]^Sprint_Header, 4, a),
		sprint_order   = make([dynamic]string, 0, 8, a),
		defers         = make(map[string]^Defer_Record, 4, a),
		defer_order    = make([dynamic]string, 0, 4, a),
		seen_uids      = make(map[string]bool, 64, a),
		aliases        = make(map[string]^Incident_Header, 8, a),
		id_to_uid      = make(map[string]^Incident_Header, 16, a),
		anomalies      = make([dynamic]string, 0, 4, a),
	}
	dag_init(&s.dag, a)
}

fold_state_destroy :: proc(s: ^Fold_State) {
	for uid in s.incident_order {
		h := s.incidents[uid]
		if h != nil {
			incident_header_destroy(h, s.allocator)
			free(h, s.allocator)
		}
	}
	delete(s.incidents)
	delete(s.incident_order)
	for id in s.sprint_order {
		spr := s.sprints[id]
		if spr != nil {
			sprint_header_destroy(spr, s.allocator)
			free(spr, s.allocator)
		}
	}
	delete(s.sprints)
	delete(s.sprint_order)
	for id in s.defer_order {
		d := s.defers[id]
		if d != nil {
			defer_record_destroy(d, s.allocator)
			free(d, s.allocator)
		}
	}
	delete(s.defers)
	delete(s.defer_order)
	for uid in s.seen_uids {
		delete(uid, s.allocator)
	}
	delete(s.seen_uids)
	for alias in s.aliases {
		delete(alias, s.allocator)
	}
	delete(s.aliases)
	delete(s.id_to_uid)
	for line in s.anomalies {
		delete(line, s.allocator)
	}
	delete(s.anomalies)
	if s.last_uid != "" {
		delete(s.last_uid, s.allocator)
	}
	dag_destroy(&s.dag)
	s^ = {}
}

incident_header_destroy :: proc(h: ^Incident_Header, a: mem.Allocator) {
	fields := []^string{
		&h.uid, &h.id, &h.title, &h.status, &h.priority, &h.sprint,
		&h.assignee, &h.created_by, &h.verdict, &h.fp_pattern,
		&h.resolution, &h.duplicate_of,
	}
	for f in fields {
		if f^ != "" {
			delete(f^, a)
		}
	}
	free_str_slice(h.labels, a)
	free_str_slice(h.blocked_by, a)
	free_str_slice(h.aliases, a)
	for line in h.anomaly_detail {
		delete(line, a)
	}
	delete(h.anomaly_detail)
	if h.last_status.origin != "" {
		delete(h.last_status.origin, a)
	}
	for ref in h.events {
		if ref.uid != "" {
			delete(ref.uid, a)
		}
	}
	delete(h.events)
}

sprint_header_destroy :: proc(h: ^Sprint_Header, a: mem.Allocator) {
	fields := []^string{&h.id, &h.name, &h.follows}
	for f in fields {
		if f^ != "" {
			delete(f^, a)
		}
	}
	free_str_slice(h.must, a)
	for i in 0..<len(h.verifications) {
		vfields := []^string{
			&h.verifications[i].task,
			&h.verifications[i].definition,
			&h.verifications[i].outcome,
			&h.verifications[i].output,
			&h.verifications[i].session,
		}
		for f in vfields {
			if f^ != "" {
				delete(f^, a)
			}
		}
	}
	delete(h.verifications)
	for ref in h.events {
		if ref.uid != "" {
			delete(ref.uid, a)
		}
	}
	delete(h.events)
}

defer_record_destroy :: proc(d: ^Defer_Record, a: mem.Allocator) {
	fields := []^string{&d.id, &d.sprint, &d.kind, &d.body_md, &d.task, &d.ref, &d.resolved_by}
	for f in fields {
		if f^ != "" {
			delete(f^, a)
		}
	}
}

sprint_stats_destroy :: proc(st: ^Sprint_Stats, a: mem.Allocator) {
	if st.sprint_id != "" {
		delete(st.sprint_id, a)
	}
	for label, ls in st.by_label {
		delete(label, a)
		for p in ls.by_priority {
			delete(p, a)
		}
		delete(ls.by_priority)
		free(ls, a)
	}
	delete(st.by_label)
	for p in st.by_priority {
		delete(p, a)
	}
	delete(st.by_priority)
	for p in st.by_pattern {
		delete(p, a)
	}
	delete(st.by_pattern)
	for id in st.cohort {
		delete(id, a)
	}
	delete(st.cohort)
}

// ---------------------------------------------------------------------------
// Application

// fold_apply folds one event. Duplicate uids are no-ops (idempotency);
// an event older than the last applied one returns false without applying
// — the caller must refold from the full stream.
fold_apply :: proc(s: ^Fold_State, ev: ^Decoded_Event, scratch: mem.Allocator) -> bool {
	if s.seen_uids[ev.uid] {
		return true
	}
	if s.last_uid != "" && ev.uid < s.last_uid {
		return false
	}
	s.seen_uids[strings.clone(ev.uid, s.allocator)] = true
	str_set(&s.last_uid, ev.uid, s.allocator)

	if !ev.kind_ok {
		state_anomaly(s, ev, "unknown event type")
		return true
	}
	switch ev.kind {
	case .Incident_Created:
		apply_created(s, ev, scratch)
	case .Incident_Title_Changed:
		apply_title_changed(s, ev, scratch)
	case .Incident_Verified:
		apply_verified(s, ev, scratch)
	case .Incident_Root_Caused:
		apply_root_caused(s, ev, scratch)
	case .Incident_Status_Changed:
		apply_status_changed(s, ev, scratch)
	case .Incident_Fields_Changed:
		apply_fields_changed(s, ev, scratch)
	case .Incident_Note_Appended:
		apply_note_appended(s, ev, scratch)
	case .Incident_Deleted:
		apply_deleted(s, ev, scratch)
	case .Sprint_Started:
		apply_sprint_started(s, ev, scratch)
	case .Sprint_Closed:
		apply_sprint_closed(s, ev)
	case .Sprint_Goal_Updated, .Sprint_Note_Appended, .Sprint_Outcome_Updated:
		apply_sprint_body_event(s, ev, scratch)
	case .Sprint_Task_Verified:
		apply_sprint_task_verified(s, ev, scratch)
	}
	return true
}

// --- incident events ------------------------------------------------------

apply_created :: proc(s: ^Fold_State, ev: ^Decoded_Event, scratch: mem.Allocator) {
	d, reason := decode_incident_created(ev.payload, scratch)
	if reason != "" {
		state_anomaly(s, ev, cat({"malformed payload: ", reason}, scratch))
		return
	}
	s.inc_count += 1
	id := fmt.aprintf("INC-%03d", s.inc_count, allocator = s.allocator)
	h := new(Incident_Header, s.allocator)
	h^ = {
		uid         = strings.clone(ev.uid, s.allocator),
		id          = id,
		title       = strings.clone(d.title, s.allocator),
		// Wire-vocabulary literals are constant data — clone them like any
		// other store; destroy and str_set free header fields unconditionally.
		status      = strings.clone(incident_status_string(.Reported), s.allocator),
		priority    = "",
		labels      = clone_str_slice(d.labels, s.allocator),
		sprint      = strings.clone(d.sprint, s.allocator),
		blocked_by  = clone_str_slice(d.blocked_by, s.allocator),
		assignee    = strings.clone(d.assignee, s.allocator),
		aliases     = clone_str_slice(d.aliases, s.allocator),
		created_by  = strings.clone(d.created_by, s.allocator),
		created_ms  = ev.ts_ms,
		updated_ms  = ev.ts_ms,
		last_status = {
			kind   = .Incident_Created,
			ts_ms  = ev.ts_ms,
			origin = strings.clone(ev.origin, s.allocator),
		},
	}
	if d.priority != "" {
		h.priority = strings.clone(d.priority, s.allocator)
	} else {
		h.priority = strings.clone(priority_string(.Medium), s.allocator)
	}
	s.incidents[h.uid] = h
	append(&s.incident_order, h.uid)
	s.id_to_uid[id] = h
	append_event_ref(s, &h.events, ev)

	reassign_aliases(s, ev, h, d.aliases, scratch)
	apply_sprint_assignment(s, ev, h, d.sprint, scratch)
	rebuild_blocked_edges(s, ev, h, scratch)
}

apply_title_changed :: proc(s: ^Fold_State, ev: ^Decoded_Event, scratch: mem.Allocator) {
	d, reason := decode_incident_title_changed(ev.payload, scratch)
	if reason != "" {
		state_anomaly(s, ev, cat({"malformed payload: ", reason}, scratch))
		return
	}
	h := resolve_target(s, ev, d.target, scratch)
	if h == nil {
		return
	}
	append_event_ref(s, &h.events, ev)
	if !is_mutable(s, ev, h) {
		return
	}
	clear_anomaly(s, h)
	str_set(&h.title, d.title, s.allocator)
	h.updated_ms = ev.ts_ms
}

apply_verified :: proc(s: ^Fold_State, ev: ^Decoded_Event, scratch: mem.Allocator) {
	d, reason := decode_incident_verified(ev.payload, scratch)
	if reason != "" {
		state_anomaly(s, ev, cat({"malformed payload: ", reason}, scratch))
		return
	}
	h := resolve_target(s, ev, d.target, scratch)
	if h == nil {
		return
	}
	append_event_ref(s, &h.events, ev)
	if !is_mutable(s, ev, h) {
		return
	}
	if h.status != incident_status_string(.Reported) {
		buf: [3]string
		buf[0] = "verified on status "
		buf[1] = h.status
		buf[2] = " (only reported is legal)"
		flag(s, ev, h, cat(buf[:], scratch))
	} else if d.verdict != verdict_string(.Confirmed) && d.verdict != verdict_string(.Rejected) {
		buf: [2]string
		buf[0] = "verified with unknown verdict "
		buf[1] = d.verdict
		flag(s, ev, h, cat(buf[:], scratch))
	} else {
		clear_anomaly(s, h)
	}
	str_set(&h.verdict, d.verdict, s.allocator)
	str_set(&h.fp_pattern, d.fp_pattern, s.allocator)
	h.verified_ms = ev.ts_ms
	if d.verdict == verdict_string(.Rejected) {
		str_set(&h.status, incident_status_string(.Rejected), s.allocator)
	} else {
		str_set(&h.status, incident_status_string(.Confirmed), s.allocator)
	}
	set_last_status(s, h, ev, .Incident_Verified)
	h.updated_ms = ev.ts_ms
}

apply_root_caused :: proc(s: ^Fold_State, ev: ^Decoded_Event, scratch: mem.Allocator) {
	d, reason := decode_incident_root_caused(ev.payload, scratch)
	if reason != "" {
		state_anomaly(s, ev, cat({"malformed payload: ", reason}, scratch))
		return
	}
	h := resolve_target(s, ev, d.target, scratch)
	if h == nil {
		return
	}
	append_event_ref(s, &h.events, ev)
	if !is_mutable(s, ev, h) {
		return
	}
	if verified_state(h.status) {
		clear_anomaly(s, h)
	} else {
		buf: [3]string
		buf[0] = "root_caused from status "
		buf[1] = h.status
		buf[2] = " (requires a verified state)"
		flag(s, ev, h, cat(buf[:], scratch))
	}
	str_set(&h.status, incident_status_string(.Root_Caused), s.allocator)
	set_last_status(s, h, ev, .Incident_Root_Caused)
	h.updated_ms = ev.ts_ms
}

apply_status_changed :: proc(s: ^Fold_State, ev: ^Decoded_Event, scratch: mem.Allocator) {
	d, reason := decode_incident_status_changed(ev.payload, scratch)
	if reason != "" {
		state_anomaly(s, ev, cat({"malformed payload: ", reason}, scratch))
		return
	}
	h := resolve_target(s, ev, d.target, scratch)
	if h == nil {
		return
	}
	append_event_ref(s, &h.events, ev)
	if !is_mutable(s, ev, h) {
		return
	}
	legal := transition_legal(h.status, d.to)
	if legal {
		clear_anomaly(s, h)
	} else {
		buf: [5]string
		buf[0] = "status_changed "
		buf[1] = h.status
		buf[2] = "→"
		buf[3] = d.to
		buf[4] = " is not a legal transition"
		flag(s, ev, h, cat(buf[:], scratch))
	}
	if d.to == incident_status_string(.Reported) && status_is_terminal(h.status) {
		// Reopen clears the verdict and the resolution record.
		str_set(&h.verdict, "", s.allocator)
		str_set(&h.fp_pattern, "", s.allocator)
		h.verified_ms = 0
		h.resolved_ms = 0
		str_set(&h.resolution, "", s.allocator)
	}
	str_set(&h.status, d.to, s.allocator)
	set_last_status(s, h, ev, .Incident_Status_Changed)
	h.updated_ms = ev.ts_ms
	if d.to == incident_status_string(.Resolved) {
		h.resolved_ms = ev.ts_ms
		str_set(&h.resolution, d.resolution, s.allocator)
	}
}

apply_fields_changed :: proc(s: ^Fold_State, ev: ^Decoded_Event, scratch: mem.Allocator) {
	d, reason := decode_incident_fields_changed(ev.payload, scratch)
	if reason != "" {
		state_anomaly(s, ev, cat({"malformed payload: ", reason}, scratch))
		return
	}
	h := resolve_target(s, ev, d.target, scratch)
	if h == nil {
		return
	}
	append_event_ref(s, &h.events, ev)
	if !is_mutable(s, ev, h) {
		return
	}
	clear_anomaly(s, h)
	if d.priority_set {
		str_set(&h.priority, d.priority, s.allocator)
	}
	if d.labels_set {
		str_slice_set(&h.labels, d.labels, s.allocator)
	}
	if d.assignee_set {
		str_set(&h.assignee, d.assignee, s.allocator)
	}
	if d.aliases_set {
		str_slice_set(&h.aliases, d.aliases, s.allocator)
		reassign_aliases(s, ev, h, d.aliases, scratch)
	}
	if d.sprint_set {
		str_set(&h.sprint, d.sprint, s.allocator)
		apply_sprint_assignment(s, ev, h, d.sprint, scratch)
	}
	if d.blocked_by_set {
		str_slice_set(&h.blocked_by, d.blocked_by, s.allocator)
		rebuild_blocked_edges(s, ev, h, scratch)
	}
	h.updated_ms = ev.ts_ms
}

apply_note_appended :: proc(s: ^Fold_State, ev: ^Decoded_Event, scratch: mem.Allocator) {
	d, reason := decode_incident_note_appended(ev.payload, scratch)
	if reason != "" {
		state_anomaly(s, ev, cat({"malformed payload: ", reason}, scratch))
		return
	}
	h := resolve_target(s, ev, d.target, scratch)
	if h == nil {
		return
	}
	append_event_ref(s, &h.events, ev)
	if !is_mutable(s, ev, h) {
		return
	}
	clear_anomaly(s, h)
	h.note_count += 1
	h.updated_ms = ev.ts_ms
}

apply_deleted :: proc(s: ^Fold_State, ev: ^Decoded_Event, scratch: mem.Allocator) {
	d, reason := decode_incident_deleted(ev.payload, scratch)
	if reason != "" {
		state_anomaly(s, ev, cat({"malformed payload: ", reason}, scratch))
		return
	}
	h := resolve_target(s, ev, d.target, scratch)
	if h == nil {
		return
	}
	append_event_ref(s, &h.events, ev)
	if h.is_deleted {
		flag(s, ev, h, "deleted on an already-deleted incident")
		return
	}
	clear_anomaly(s, h)
	h.is_deleted = true
	str_set(&h.duplicate_of, d.duplicate_of, s.allocator)
	// Release the tombstone's aliases so other incidents can claim them.
	drop := make([dynamic]string, 0, 4, scratch)
	for alias, owner in s.aliases {
		if owner == h {
			append(&drop, alias)
		}
	}
	for alias in drop {
		// The map owns the stored key clone; delete_key hands it back and
		// only then is it freed — freeing first would have the lookup hash
		// freed bytes (dag_remove_node is the worked example).
		stored, _ := delete_key(&s.aliases, alias)
		delete(stored, s.allocator)
	}
	if d.duplicate_of != "" {
		target := incident_by_id(s, d.duplicate_of)
		if target == nil || target.is_deleted || target.id == h.id {
			buf: [3]string
			buf[0] = "duplicate_of "
			buf[1] = d.duplicate_of
			buf[2] = " is missing, deleted, or self"
			flag(s, ev, h, cat(buf[:], scratch))
		}
	}
	dag_remove_node(&s.dag, h.id)
	// Deleting this incident severs every tombstone that still points at it
	// through duplicate_of — flag those links at the moment the target dies.
	for uid in s.incident_order {
		dep := s.incidents[uid]
		if dep == nil || dep == h || !dep.is_deleted || dep.duplicate_of != h.id {
			continue
		}
		buf: [3]string
		buf[0] = "duplicate_of "
		buf[1] = h.id
		buf[2] = " was deleted after the duplicate"
		flag(s, ev, dep, cat(buf[:], scratch))
	}
	h.updated_ms = ev.ts_ms
}

// --- sprint events --------------------------------------------------------

apply_sprint_started :: proc(s: ^Fold_State, ev: ^Decoded_Event, scratch: mem.Allocator) {
	d, reason := decode_sprint_started(ev.payload, scratch)
	if reason != "" {
		state_anomaly(s, ev, cat({"malformed payload: ", reason}, scratch))
		return
	}
	if active := active_sprint(s); active != nil {
		buf: [3]string
		buf[0] = "sprint.started while "
		buf[1] = active.id
		buf[2] = " is active"
		state_anomaly(s, ev, cat(buf[:], scratch))
	}
	s.spr_count += 1
	id := fmt.aprintf("SPR-%03d", s.spr_count, allocator = s.allocator)
	h := new(Sprint_Header, s.allocator)
	h^ = {
		id         = id,
		name       = strings.clone(d.name, s.allocator),
		status     = .Active,
		started_ms = ev.ts_ms,
		follows    = strings.clone(d.follows, s.allocator),
	}
	if d.must_set {
		h.must = clone_str_slice(d.must, s.allocator)
	}
	if d.follows != "" {
		prev, ok := s.sprints[d.follows]
		if !ok || prev.id == id {
			buf: [3]string
			buf[0] = "follows "
			buf[1] = d.follows
			buf[2] = " does not exist"
			state_anomaly(s, ev, cat(buf[:], scratch))
		}
	}
	s.sprints[id] = h
	append(&s.sprint_order, id)
	append_event_ref(s, &h.events, ev)
}

apply_sprint_closed :: proc(s: ^Fold_State, ev: ^Decoded_Event) {
	// The outcome body lives in the event; the header only flips state.
	// Members keep their sprint assignment: membership is work grouping
	// and statistics follow filing time, so close has nothing to sweep
	// and nothing to snapshot — the cohort is re-derivable from headers
	// at any time.
	active := active_sprint(s)
	if active == nil {
		state_anomaly(s, ev, "sprint.closed with no active sprint")
		return
	}
	append_event_ref(s, &active.events, ev)
	active.status = .Closed
	active.closed_ms = ev.ts_ms
}

// apply_sprint_body_event covers goal_updated / note_appended /
// outcome_updated. Goal updates may replace the must-task list; a note may
// carry a typed defer record or resolve an open question (both live in the
// fold state, not the header — open questions outlive their round). The
// bodies themselves render from the event references. Legality violations
// surface as state anomalies; effects still apply (absorb-and-flag).
apply_sprint_body_event :: proc(s: ^Fold_State, ev: ^Decoded_Event, scratch: mem.Allocator) {
	target, reason := field_str(ev.payload, "target", scratch)
	if reason != "" {
		state_anomaly(s, ev, cat({"malformed payload: ", reason}, scratch))
		return
	}
	spr, ok := s.sprints[target]
	if !ok || spr == nil {
		buf: [3]string
		buf[0] = "sprint "
		buf[1] = target
		buf[2] = " does not exist"
		state_anomaly(s, ev, cat(buf[:], scratch))
		return
	}
	append_event_ref(s, &spr.events, ev)
	#partial switch ev.kind {
	case .Sprint_Outcome_Updated:
		if spr.status != .Closed {
			buf: [2]string
			buf[0] = "outcome_updated on active sprint "
			buf[1] = spr.id
			state_anomaly(s, ev, cat(buf[:], scratch))
		}
	case .Sprint_Goal_Updated:
		flag_if_closed(s, ev, spr, scratch)
		d, dreason := decode_sprint_goal_updated(ev.payload, scratch)
		if dreason != "" {
			state_anomaly(s, ev, cat({"malformed payload: ", dreason}, scratch))
			return
		}
		if d.must_set {
			str_slice_set(&spr.must, d.must, s.allocator)
		}
	case .Sprint_Note_Appended:
		flag_if_closed(s, ev, spr, scratch)
		d, dreason := decode_sprint_note_appended(ev.payload, scratch)
		if dreason != "" {
			state_anomaly(s, ev, cat({"malformed payload: ", dreason}, scratch))
			return
		}
		apply_defer_note(s, ev, spr, &d, scratch)
	}
}

// flag_if_closed records the state-level anomaly for a body event that
// landed on a closed sprint. The fold still absorbs the effect — the write
// path is what rejects closed-sprint mutations — so this is a plain
// flagger, not a gate.
@(private)
flag_if_closed :: proc(s: ^Fold_State, ev: ^Decoded_Event, spr: ^Sprint_Header, scratch: mem.Allocator) {
	if spr.status != .Active {
		buf: [3]string
		buf[0] = event_kind_string(ev.kind)
		buf[1] = " on closed sprint "
		buf[2] = spr.id
		state_anomaly(s, ev, cat(buf[:], scratch))
	}
}

// apply_defer_note registers the typed-deferral half of a sprint note: the
// defer record itself (when defer_type is present) and the question
// resolution (when resolves names an open question defer). Plain notes do
// neither.
@(private)
apply_defer_note :: proc(s: ^Fold_State, ev: ^Decoded_Event, spr: ^Sprint_Header, d: ^Sprint_Note_Appended_Data, scratch: mem.Allocator) {
	if d.defer_type != "" {
		kind, known := defer_kind_from_string(d.defer_type)
		if !known {
			buf: [3]string
			buf[0] = "note with unknown defer_type "
			buf[1] = d.defer_type
			buf[2] = " (blocked|question|descope)"
			state_anomaly(s, ev, cat(buf[:], scratch))
			return
		}
		if d.defer_id == "" {
			state_anomaly(s, ev, "typed defer without defer_id")
			return
		}
		if _, exists := s.defers[d.defer_id]; exists {
			buf: [3]string
			buf[0] = "defer id "
			buf[1] = d.defer_id
			buf[2] = " already used"
			state_anomaly(s, ev, cat(buf[:], scratch))
			return
		}
		rec := new(Defer_Record, s.allocator)
		rec^ = {
			id       = strings.clone(d.defer_id, s.allocator),
			sprint   = strings.clone(spr.id, s.allocator),
			kind     = strings.clone(defer_kind_string(kind), s.allocator),
			body_md  = strings.clone(d.body_md, s.allocator),
			task     = strings.clone(d.task, s.allocator),
			ref      = strings.clone(d.ref, s.allocator),
			ts_ms    = ev.ts_ms,
		}
		s.defers[rec.id] = rec
		append(&s.defer_order, rec.id)
		s.defer_count += 1
		if kind == .Blocked && d.ref == "" {
			buf: [3]string
			buf[0] = "blocked defer "
			buf[1] = d.defer_id
			buf[2] = " has no ref"
			state_anomaly(s, ev, cat(buf[:], scratch))
		}
	}
	if d.resolves != "" {
		target, ok := s.defers[d.resolves]
		if !ok || target == nil ||
			target.kind != defer_kind_string(.Question) || target.resolved_ms != 0 {
			buf: [3]string
			buf[0] = "resolves "
			buf[1] = d.resolves
			buf[2] = " is not an open question defer"
			state_anomaly(s, ev, cat(buf[:], scratch))
			return
		}
		target.resolved_ms = ev.ts_ms
		if d.defer_id != "" {
			str_set(&target.resolved_by, d.defer_id, s.allocator)
		} else {
			str_set(&target.resolved_by, "note", s.allocator)
		}
	}
}

// apply_sprint_task_verified materializes one verification record on the
// sprint header — the server-held evidence behind the task's derived
// "verified" state. The write path enforces the required fields and the
// outcome vocabulary; the fold absorbs foreign violations as anomalies and
// still records (the derivation reads the outcome verbatim).
apply_sprint_task_verified :: proc(s: ^Fold_State, ev: ^Decoded_Event, scratch: mem.Allocator) {
	d, reason := decode_sprint_task_verified(ev.payload, scratch)
	if reason != "" {
		state_anomaly(s, ev, cat({"malformed payload: ", reason}, scratch))
		return
	}
	spr, ok := s.sprints[d.target]
	if !ok || spr == nil {
		buf: [3]string
		buf[0] = "sprint "
		buf[1] = d.target
		buf[2] = " does not exist"
		state_anomaly(s, ev, cat(buf[:], scratch))
		return
	}
	append_event_ref(s, &spr.events, ev)
	flag_if_closed(s, ev, spr, scratch)
	if _, known := verif_outcome_from_string(d.outcome); !known {
		buf: [3]string
		buf[0] = "task_verified with unknown outcome "
		buf[1] = d.outcome
		buf[2] = " (passed|failed)"
		state_anomaly(s, ev, cat(buf[:], scratch))
	}
	if d.task == "" || d.definition == "" || d.output == "" {
		state_anomaly(s, ev, "task_verified requires task, definition, and output")
	}
	if cap(spr.verifications) == 0 {
		spr.verifications = make([dynamic]Task_Verif, 0, 4, s.allocator)
	}
	append(&spr.verifications, Task_Verif{
		task       = strings.clone(d.task, s.allocator),
		definition = strings.clone(d.definition, s.allocator),
		outcome    = strings.clone(d.outcome, s.allocator),
		output     = strings.clone(d.output, s.allocator),
		session    = strings.clone(d.session, s.allocator),
		ts_ms      = ev.ts_ms,
	})
}

// --- shared helpers -------------------------------------------------------

// INCIDENT_TRANSITIONS is the write-time transition table, one row per
// legal direct (from, to) pair. The fold reuses it to decide anomaly
// flags, the write path reuses it to reject writes. The Problem
// lifecycle carries no execution predicates: verified/root_caused
// events are the only exits from reported (their own gates decide them,
// not this table), resolve lands only from root_caused, and reopen is
// the only path back to reported.
INCIDENT_TRANSITIONS :: []struct{from, to: Incident_Status}{
	{.Root_Caused, .Resolved},
	{.Resolved, .Reported},
	{.Rejected, .Reported},
}

transition_legal :: proc(from, to: string) -> bool {
	from_s, fok := incident_status_from_string(from)
	to_s, tok := incident_status_from_string(to)
	if !fok || !tok {
		return false // foreign spellings never transition
	}
	for tr in INCIDENT_TRANSITIONS {
		if tr.from == from_s && tr.to == to_s {
			return true
		}
	}
	return false
}

// verified_state reports whether the status is only reachable through a
// verdict (or from one). The write path and the root_cause gating agree on
// this set.
verified_state :: proc(status: string) -> bool {
	switch status {
	case incident_status_string(.Confirmed),
	     incident_status_string(.Root_Caused):
		return true
	}
	return false
}

status_is_terminal :: proc(status: string) -> bool {
	return status == incident_status_string(.Resolved) || status == incident_status_string(.Rejected)
}

resolve_target :: proc(s: ^Fold_State, ev: ^Decoded_Event, id: string, scratch: mem.Allocator) -> ^Incident_Header {
	h := incident_by_id(s, id)
	if h == nil {
		buf: [3]string
		buf[0] = "target "
		buf[1] = id
		buf[2] = " does not exist"
		state_anomaly(s, ev, cat(buf[:], scratch))
		return nil
	}
	return h
}

is_mutable :: proc(s: ^Fold_State, ev: ^Decoded_Event, h: ^Incident_Header) -> bool {
	if h.is_deleted {
		flag(s, ev, h, "event on deleted incident")
		return false
	}
	return true
}

// apply_sprint_assignment validates a sprint value on created/fields_changed:
// the backlog is always fine; a sprint must exist and be active. The header
// keeps the raw value regardless.
apply_sprint_assignment :: proc(s: ^Fold_State, ev: ^Decoded_Event, h: ^Incident_Header, sprint_id: string, scratch: mem.Allocator) {
	if sprint_id == "" {
		return
	}
	spr, ok := s.sprints[sprint_id]
	if !ok || spr == nil {
		buf: [3]string
		buf[0] = "sprint "
		buf[1] = sprint_id
		buf[2] = " does not exist"
		flag(s, ev, h, cat(buf[:], scratch))
	} else if spr.status != .Active {
		buf: [3]string
		buf[0] = "sprint "
		buf[1] = sprint_id
		buf[2] = " is closed (stale assignment)"
		flag(s, ev, h, cat(buf[:], scratch))
	}
}

reassign_aliases :: proc(s: ^Fold_State, ev: ^Decoded_Event, h: ^Incident_Header, new_aliases: []string, scratch: mem.Allocator) {
	// Drop the aliases currently owned by h, then register the new set.
	drop := make([dynamic]string, 0, 4, scratch)
	for alias, owner in s.aliases {
		if owner == h {
			append(&drop, alias)
		}
	}
	for alias in drop {
		// Map-owned keys: delete_key first, free the handed-back clone
		// after — the reverse order hashes freed bytes.
		stored, _ := delete_key(&s.aliases, alias)
		delete(stored, s.allocator)
	}
	for alias in new_aliases {
		owner, taken := s.aliases[alias]
		if taken && owner != h {
			other_id := "?"
			if owner != nil {
				other_id = owner.id
			}
			buf: [4]string
			buf[0] = "alias "
			buf[1] = alias
			buf[2] = " already used by "
			buf[3] = other_id
			flag(s, ev, h, cat(buf[:], scratch))
			continue
		}
		s.aliases[strings.clone(alias, s.allocator)] = h
	}
}

// rebuild_blocked_edges resets h's DAG edges from its blocked_by list.
// Targets that are missing or deleted are excluded from the DAG but keep
// the header entry; cyclic edges are refused and flagged.
rebuild_blocked_edges :: proc(s: ^Fold_State, ev: ^Decoded_Event, h: ^Incident_Header, scratch: mem.Allocator) {
	dag_remove_node(&s.dag, h.id)
	for target in h.blocked_by {
		t := incident_by_id(s, target)
		if t == nil || t.is_deleted {
			continue // legitimate lifecycle: excluded, not an anomaly
		}
		if dag_would_create_cycle(&s.dag, h.id, t.id) {
			buf: [3]string
			buf[0] = "blocked_by "
			buf[1] = t.id
			buf[2] = " would create a cycle"
			flag(s, ev, h, cat(buf[:], scratch))
			continue
		}
		_ = dag_add_edge(&s.dag, h.id, t.id)
	}
}

incident_by_id :: proc(s: ^Fold_State, id: string) -> ^Incident_Header {
	h, ok := s.id_to_uid[id]
	if !ok {
		return nil
	}
	return h
}

active_sprint :: proc(s: ^Fold_State) -> ^Sprint_Header {
	for i := len(s.sprint_order) - 1; i >= 0; i -= 1 {
		spr, ok := s.sprints[s.sprint_order[i]]
		if ok && spr.status == .Active {
			return spr
		}
	}
	return nil
}

sprint_by_id :: proc(s: ^Fold_State, id: string) -> ^Sprint_Header {
	spr, ok := s.sprints[id]
	if !ok {
		return nil
	}
	return spr
}

clear_anomaly :: proc(s: ^Fold_State, h: ^Incident_Header) {
	h.is_anomaly = false
	for line in h.anomaly_detail {
		delete(line, s.allocator)
	}
	delete(h.anomaly_detail)
	// delete leaves the stale header behind — drop it or a later destroy
	// iterates and frees the same lines a second time.
	h.anomaly_detail = nil
}

flag :: proc(s: ^Fold_State, ev: ^Decoded_Event, h: ^Incident_Header, reason: string) {
	h.is_anomaly = true
	if cap(h.anomaly_detail) == 0 {
		h.anomaly_detail = make([dynamic]string, 0, 2, s.allocator)
	}
	append(&h.anomaly_detail, anomaly_line(s, ev, reason))
}

state_anomaly :: proc(s: ^Fold_State, ev: ^Decoded_Event, reason: string) {
	append(&s.anomalies, anomaly_line(s, ev, reason))
}

anomaly_line :: proc(s: ^Fold_State, ev: ^Decoded_Event, reason: string) -> string {
	kind_str := event_kind_string(ev.kind)
	if !ev.kind_ok {
		kind_str = ev.raw_kind
	}
	ts := ts_iso_utc(ev.ts_ms, context.temp_allocator)
	buf: [7]string
	buf[0] = kind_str
	buf[1] = " at "
	buf[2] = ts
	buf[3] = " ("
	buf[4] = ev.origin
	buf[5] = "): "
	buf[6] = reason
	return strings.concatenate(buf[:], s.allocator)
}

set_last_status :: proc(s: ^Fold_State, h: ^Incident_Header, ev: ^Decoded_Event, kind: Event_Kind) {
	if h.last_status.origin != "" {
		delete(h.last_status.origin, s.allocator)
	}
	h.last_status = {
		kind   = kind,
		ts_ms  = ev.ts_ms,
		origin = strings.clone(ev.origin, s.allocator),
	}
}

append_event_ref :: proc(s: ^Fold_State, list: ^[dynamic]Event_Ref, ev: ^Decoded_Event) {
	// A header's dynamics start zero-value; grow them on the state's
	// allocator, never the ambient context.
	if cap(list^) == 0 {
		list^ = make([dynamic]Event_Ref, 0, 8, s.allocator)
	}
	append(list, Event_Ref{uid = strings.clone(ev.uid, s.allocator), kind = ev.kind, ts_ms = ev.ts_ms})
}

// zero_by_priority builds a zeroed per-priority map from the canonical
// order — a new label never depends on a hand-restated value list.
zero_by_priority :: proc(a: mem.Allocator) -> map[string]int {
	m := make(map[string]int, 4, a)
	// The enum names are constant data; the map owns its keys, so clone.
	m[strings.clone(priority_string(.Urgent), a)] = 0
	m[strings.clone(priority_string(.High), a)] = 0
	m[strings.clone(priority_string(.Medium), a)] = 0
	m[strings.clone(priority_string(.Low), a)] = 0
	return m
}

// compute_sprint_stats derives the sprint statistics over the filed cohort
// — findings created inside the sprint's window (sprint_cohort below shares
// the exact selection), outcomes read from the headers' current verdict and
// status. The result is caller-owned: destroy with sprint_stats_destroy.
compute_sprint_stats :: proc(s: ^Fold_State, spr: ^Sprint_Header, a: mem.Allocator) -> ^Sprint_Stats {
	st := new(Sprint_Stats, a)
	st^ = {
		sprint_id   = strings.clone(spr.id, a),
		by_label    = make(map[string]^Label_Stats, 8, a),
		by_priority = zero_by_priority(a),
		by_pattern  = make(map[string]int, 4, a),
		cohort      = make([dynamic]string, 0, 16, a),
	}
	by_label_judged := make(map[string]int, 8, context.temp_allocator)
	defer delete(by_label_judged)
	cohort := sprint_cohort(s, spr, context.temp_allocator)
	defer delete(cohort, context.temp_allocator)
	rejected_v := verdict_string(.Rejected)
	resolved_s := incident_status_string(.Resolved)
	for h in cohort {
		st.total += 1
		append(&st.cohort, strings.clone(h.id, a))
		judged := h.verdict != ""
		if judged {
			if h.verdict == rejected_v {
				st.rejected += 1
			} else {
				st.confirmed += 1
			}
		} else {
			st.unjudged += 1
		}
		if h.status == resolved_s {
			st.resolved += 1
		}
		if h.is_anomaly {
			st.anomalies += 1
		}
		bump(&st.by_priority, h.priority, a)
		if judged && h.verdict == rejected_v && h.fp_pattern != "" {
			bump(&st.by_pattern, h.fp_pattern, a)
		}
		for label in h.labels {
			ls, ok := st.by_label[label]
			if !ok {
				ls = new(Label_Stats, a)
				ls.by_priority = zero_by_priority(a)
				st.by_label[strings.clone(label, a)] = ls
			}
			ls.total += 1
			if judged {
				if h.verdict == rejected_v {
					ls.rejected += 1
				} else {
					ls.confirmed += 1
				}
			} else {
				ls.unjudged += 1
			}
			if h.status == resolved_s {
				ls.resolved += 1
			}
			if judged {
				by_label_judged[label] += 1
			}
			bump(&ls.by_priority, h.priority, a)
		}
	}
	total_judged := st.confirmed + st.rejected
	if total_judged > 0 {
		st.fp_rate = f64(st.rejected) / f64(total_judged)
	}
	for label, ls in st.by_label {
		if n, ok := by_label_judged[label]; ok && n > 0 {
			ls.fp_rate = f64(ls.rejected) / f64(n)
		}
	}
	// Cross-cohort window activity: verdicts and resolutions recorded
	// inside the window on findings filed before it (fix and verify
	// rounds work older findings). Scoped apart — these never enter the
	// cohort numbers above.
	for uid in s.incident_order {
		h := s.incidents[uid]
		if h == nil || h.is_deleted || h.created_ms >= spr.started_ms {
			continue
		}
		if h.verdict != "" && sprint_window_has(spr, h.verified_ms) {
			st.judged_earlier += 1
		}
		if h.status == resolved_s && sprint_window_has(spr, h.resolved_ms) {
			st.resolved_earlier += 1
		}
	}
	return st
}

// sprint_window_has reports whether ts falls inside the sprint's window
// [started_ms, closed_ms] — open-ended while the sprint is active.
sprint_window_has :: proc(spr: ^Sprint_Header, ts_ms: i64) -> bool {
	if ts_ms < spr.started_ms {
		return false
	}
	if spr.closed_ms != 0 && ts_ms > spr.closed_ms {
		return false
	}
	return true
}

// bump increments an owned counter, cloning the key on first sight (the
// clone-on-every-miss pattern would leak one string per hit).
@(private)
bump :: proc(m: ^map[string]int, key: string, a: mem.Allocator) {
	if _, ok := m[key]; !ok {
		m[strings.clone(key, a)] = 0
	}
	m[key] += 1
}

counts_add :: proc(c: ^Counts, h: ^Incident_Header) {
	c.total += 1
	switch h.status {
	case incident_status_string(.Reported):
		c.reported += 1
	case incident_status_string(.Confirmed):
		c.confirmed += 1
	case incident_status_string(.Root_Caused):
		c.root_caused += 1
	case incident_status_string(.Resolved):
		c.resolved += 1
	case incident_status_string(.Rejected):
		c.rejected += 1
	}
	// Foreign statuses (pre-rewrite streams) fall through uncounted here but
	// still count toward total and open.
	if !status_is_terminal(h.status) {
		c.open += 1
	}
}

// --- defer / verification accessors ---------------------------------------

defer_by_id :: proc(s: ^Fold_State, id: string) -> ^Defer_Record {
	d, ok := s.defers[id]
	if !ok {
		return nil
	}
	return d
}

// task_latest_verif returns the task's latest verification record on the
// sprint (nil when none). The derived "verified" state is latest == passed.
task_latest_verif :: proc(spr: ^Sprint_Header, task: string) -> ^Task_Verif {
	latest: ^Task_Verif
	for i in 0..<len(spr.verifications) {
		if spr.verifications[i].task == task {
			latest = &spr.verifications[i]
		}
	}
	return latest
}

// sprint_task_defer returns the id of the defer covering the task on this
// sprint ("" when none). Coverage rule: an ANSWERED question no longer
// covers — the answer either led to a verification or the question is
// re-asked; descope and blocked defers keep covering.
sprint_task_defer :: proc(s: ^Fold_State, spr: ^Sprint_Header, task: string) -> string {
	question_s := defer_kind_string(.Question)
	for id in s.defer_order {
		d := s.defers[id]
		if d == nil || d.sprint != spr.id || d.task != task {
			continue
		}
		if d.kind == question_s && d.resolved_ms != 0 {
			continue
		}
		return d.id
	}
	return ""
}

// task_deferred_by reports whether a defer filed on this sprint covers the
// task.
task_deferred_by :: proc(s: ^Fold_State, spr: ^Sprint_Header, task: string) -> bool {
	return sprint_task_defer(s, spr, task) != ""
}

// unverified_must_tasks lists the sprint's must tasks that neither have a
// passing (latest) verification record nor a covering defer — the set close
// enforcement refuses on. The result is a made dynamic carrying a; free the
// cloned elements then the dynamic itself.
unverified_must_tasks :: proc(s: ^Fold_State, spr: ^Sprint_Header, a: mem.Allocator) -> [dynamic]string {
	out := make([dynamic]string, 0, 4, a)
	for task in spr.must {
		v := task_latest_verif(spr, task)
		if v != nil && v.outcome == verif_outcome_string(.Passed) {
			continue
		}
		if task_deferred_by(s, spr, task) {
			continue
		}
		append(&out, strings.clone(task, a))
	}
	return out
}

// open_questions lists the unresolved question defers in filing order — the
// human intervention points, visible across rounds. Borrowed pointers; the
// slice is caller-owned (free with delete(xs, a)).
open_questions :: proc(s: ^Fold_State, a: mem.Allocator) -> []^Defer_Record {
	dyn := make([dynamic]^Defer_Record, 0, 4, a)
	for id in s.defer_order {
		d := s.defers[id]
		if d != nil && d.kind == defer_kind_string(.Question) && d.resolved_ms == 0 {
			append(&dyn, d)
		}
	}
	out := make([]^Defer_Record, len(dyn), a)
	for v, i in dyn {
		out[i] = v
	}
	delete(dyn)
	return out
}

// sprint_defer_stats counts the defers filed on one sprint and how many of
// its questions remain open.
sprint_defer_stats :: proc(s: ^Fold_State, spr: ^Sprint_Header) -> (total: int, open_questions: int) {
	question_s := defer_kind_string(.Question)
	for id in s.defer_order {
		d := s.defers[id]
		if d == nil || d.sprint != spr.id {
			continue
		}
		total += 1
		if d.kind == question_s && d.resolved_ms == 0 {
			open_questions += 1
		}
	}
	return
}

// must_verif_summary counts the sprint's must tasks and how many carry a
// passing (latest) verification record.
must_verif_summary :: proc(spr: ^Sprint_Header) -> (passed: int, total: int) {
	for task in spr.must {
		total += 1
		v := task_latest_verif(spr, task)
		if v != nil && v.outcome == verif_outcome_string(.Passed) {
			passed += 1
		}
	}
	return
}

// ---------------------------------------------------------------------------
// String ownership helpers

@(private)
str_set :: proc(dst: ^string, src: string, a: mem.Allocator) {
	if src == "" {
		if dst^ != "" {
			delete(dst^, a)
		}
		dst^ = ""
		return
	}
	if dst^ == src {
		return
	}
	if dst^ != "" {
		delete(dst^, a)
	}
	dst^ = strings.clone(src, a)
}

@(private)
str_slice_set :: proc(dst: ^[]string, src: []string, a: mem.Allocator) {
	free_str_slice(dst^, a)
	dst^ = clone_str_slice(src, a)
}

free_str_slice :: proc(xs: []string, a: mem.Allocator) {
	for x in xs {
		if x != "" {
			delete(x, a)
		}
	}
	if xs != nil {
		delete(xs, a)
	}
}

clone_str_slice :: proc(src: []string, a: mem.Allocator) -> []string {
	if len(src) == 0 {
		return nil // empty results are nil by convention
	}
	dyn := make([dynamic]string, 0, len(src), a)
	for s in src {
		append(&dyn, strings.clone(s, a))
	}
	out := make([]string, len(dyn), a)
	for v, i in dyn {
		out[i] = v
	}
	delete(dyn)
	return out
}

@(private)
cat :: proc(parts: []string, a: mem.Allocator) -> string {
	return strings.concatenate(parts, a)
}
