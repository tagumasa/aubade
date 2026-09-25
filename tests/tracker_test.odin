// Tests for src/tracker: event vocabulary round trips, envelope decoding
// (schema version, unknown kinds, payload JSON), payload decoders (missing
// keys = zero values, wrong shapes = reasons), label validation, and event
// UID handling.

package tests

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"
import "src:store"
import "src:jsonutil"
import "src:tracker"

@(private)
parse_json :: proc(payload: string, a: mem.Allocator) -> json.Value {
	v, perr := json.parse_string(payload, spec = .JSON, parse_integers = true, allocator = a)
	if perr != nil {
		return nil
	}
	return v
}

@(private)
fresh_arena :: proc(arena: ^mem.Dynamic_Arena) -> mem.Allocator {
	mem.dynamic_arena_init(arena, context.allocator)
	return mem.dynamic_arena_allocator(arena)
}

@(test)
tracker_event_kind_roundtrip :: proc(t: ^testing.T) {
	// Every kind string decodes back to the same kind.
	kinds := []tracker.Event_Kind{
		.Incident_Created, .Incident_Title_Changed, .Incident_Verified,
		.Incident_Root_Caused, .Incident_Status_Changed, .Incident_Fields_Changed,
		.Incident_Note_Appended, .Incident_Deleted, .Sprint_Started,
		.Sprint_Closed, .Sprint_Goal_Updated, .Sprint_Note_Appended,
		.Sprint_Outcome_Updated, .Sprint_Task_Verified,
	}
	testing.expect_value(t, len(kinds), 14)
	for kind in kinds {
		s := tracker.event_kind_string(kind)
		back, ok := tracker.event_kind_from_string(s)
		testing.expectf(t, ok && back == kind, "kind round trip failed")
	}
	_, ok := tracker.event_kind_from_string("incident.exploded")
	testing.expect(t, !ok)

	// Meta: incident/sprint target flags and the narrative set.
	im := tracker.kind_meta(.Incident_Verified)
	testing.expect(t, im.incident_target && im.narrative && !im.sprint_target)
	cm := tracker.kind_meta(.Incident_Created)
	testing.expect(t, cm.incident_target && !cm.narrative)
	sm := tracker.kind_meta(.Sprint_Note_Appended)
	testing.expect(t, sm.sprint_target && !sm.incident_target)
	vm := tracker.kind_meta(.Sprint_Task_Verified)
	testing.expect(t, vm.sprint_target && !vm.narrative)
}

@(test)
tracker_vocabularies :: proc(t: ^testing.T) {
	// The wire vocabulary renders in its documented spelling. The
	// status/verdict/resolution/priority string→enum decoders that once
	// mirrored these were dead API (intake validates the canonical strings
	// directly and stores them as strings), so only the encode side is
	// asserted here.
	testing.expect_value(t, tracker.incident_status_string(.Reported), "reported")
	testing.expect_value(t, tracker.incident_status_string(.Confirmed), "confirmed")
	testing.expect_value(t, tracker.incident_status_string(.Root_Caused), "root_caused")
	testing.expect_value(t, tracker.incident_status_string(.Resolved), "resolved")
	testing.expect_value(t, tracker.incident_status_string(.Rejected), "rejected")
	testing.expect_value(t, tracker.priority_string(.Urgent), "urgent")
	testing.expect_value(t, tracker.priority_string(.Low), "low")

	// The execution predicates are gone from the vocabulary: intake's
	// validator rejects them, foreign streams fold them as anomalies.
	testing.expect(t, tracker.validate_status_value("fixing", context.temp_allocator) != nil)
	testing.expect(t, tracker.validate_status_value("verifying", context.temp_allocator) != nil)
	testing.expect(t, tracker.validate_status_value("blocked", context.temp_allocator) != nil)
	testing.expect(t, tracker.validate_status_value("deleted", context.temp_allocator) != nil)

	for k in tracker.Defer_Kind {
		back, kok := tracker.defer_kind_from_string(tracker.defer_kind_string(k))
		testing.expectf(t, kok && back == k, "defer kind round trip failed")
	}
	for o in tracker.Verif_Outcome {
		back, ook := tracker.verif_outcome_from_string(tracker.verif_outcome_string(o))
		testing.expectf(t, ook && back == o, "verif outcome round trip failed")
	}

	_, ok := tracker.fp_pattern_from_string("noise")
	testing.expect(t, !ok)
}

@(test)
tracker_decode_event_envelope :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	a := fresh_arena(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	// Future schema versions are refused at the door.
	row := store.Event_Row{
		uid = "0000000000000001-0000000000000002", ts = 10, origin = "aabbcc01",
		kind = "incident.created", version = 2, payload = "{}",
	}
	ev, reason := tracker.decode_event(&row, a)
	testing.expect(t, ev.uid == "" && reason == "event schema version 2 exceeds supported (schema 1)", reason)

	// Unknown kinds decode with kind_ok=false (the fold records the anomaly).
	row.version = 1
	row.kind = "incident.exploded"
	ev, reason = tracker.decode_event(&row, a)
	testing.expectf(t, reason == "", "unknown kind reason: %s", reason)
	testing.expect(t, !ev.kind_ok)
	testing.expect(t, ev.raw_kind == "incident.exploded")

	// Broken payload JSON is a reason, not a panic.
	row.kind = "incident.created"
	row.payload = "{\"title\": "
	ev, reason = tracker.decode_event(&row, a)
	testing.expect(t, reason == "payload is not valid JSON", reason)

	// A well-formed envelope decodes with borrowed header fields.
	row.payload = "{\"title\":\"disk full\"}"
	ev, reason = tracker.decode_event(&row, a)
	testing.expectf(t, reason == "", "valid reason: %s", reason)
	testing.expect(t, ev.kind_ok && ev.kind == .Incident_Created)
	testing.expect(t, ev.uid == row.uid && ev.origin == row.origin)
	testing.expect_value(t, ev.ts_ms, 10)
}

@(test)
tracker_decode_payloads :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	a := fresh_arena(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	created, reason := tracker.decode_incident_created(parse_json(
		"{\"title\":\"disk full\",\"priority\":\"urgent\",\"labels\":[\"storage\",\"ops\"],\"sprint\":\"SPR-01\",\"blocked_by\":[\"INC-02\"],\"assignee\":\"kim\",\"aliases\":[\"R4-SG-01\"],\"created_by\":\"lee\",\"body_md\":\"startup race\"}",
		a,
	), a)
	testing.expectf(t, reason == "", "created reason: %s", reason)
	testing.expect(t, created.title == "disk full")
	testing.expect(t, created.priority == "urgent")
	testing.expect_value(t, len(created.labels), 2)
	testing.expect(t, created.labels[0] == "storage" && created.labels[1] == "ops")
	testing.expect(t, created.sprint == "SPR-01")
	testing.expect_value(t, len(created.blocked_by), 1)
	testing.expect(t, created.blocked_by[0] == "INC-02")
	testing.expect(t, created.assignee == "kim")
	testing.expect(t, created.aliases[0] == "R4-SG-01")
	testing.expect(t, created.created_by == "lee")
	testing.expect(t, created.body_md == "startup race")

	// Missing keys decode to zero values (fold territory), wrong shapes fail.
	minimal: tracker.Incident_Created_Data
	minimal, reason = tracker.decode_incident_created(parse_json("{\"priority\":\"low\"}", a), a)
	testing.expectf(t, reason == "", "minimal reason: %s", reason)
	testing.expect(t, minimal.title == "")
	testing.expect(t, minimal.priority == "low")
	testing.expect(t, minimal.labels == nil)

	_, reason = tracker.decode_incident_created(parse_json("{\"labels\":\"nope\"}", a), a)
	testing.expect(t, reason == "labels: expected an array of strings", reason)

	_, reason = tracker.decode_incident_created(parse_json("{\"title\":42}", a), a)
	testing.expect(t, reason == "title: expected a string", reason)

	verified: tracker.Incident_Verified_Data
	verified, reason = tracker.decode_incident_verified(parse_json(
		"{\"target\":\"INC-01\",\"verdict\":\"rejected\",\"fp_pattern\":\"spec\",\"reason_md\":\"r\",\"evidence_md\":\"e\"}",
		a,
	), a)
	testing.expectf(t, reason == "", "verified reason: %s", reason)
	testing.expect(t, verified.target == "INC-01" && verified.verdict == "rejected")

	deleted: tracker.Incident_Deleted_Data
	deleted, reason = tracker.decode_incident_deleted(parse_json("{\"target\":\"INC-01\",\"reason\":\"dup\"}", a), a)
	testing.expectf(t, reason == "", "deleted reason: %s", reason)
	testing.expect(t, deleted.duplicate_of == "")
}

@(test)
tracker_fields_changed_presence :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	a := fresh_arena(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	d, reason := tracker.decode_incident_fields_changed(parse_json(
		"{\"target\":\"INC-01\",\"priority\":\"high\",\"labels\":[\"perf\"],\"assignee\":\"\"}", a,
	), a)
	testing.expectf(t, reason == "", "fields reason: %s", reason)
	testing.expect(t, d.target == "INC-01")
	testing.expect(t, d.priority_set && d.priority == "high")
	testing.expect(t, d.labels_set && len(d.labels) == 1)
	testing.expect(t, d.assignee_set && d.assignee == "")
	testing.expect(t, !d.sprint_set && !d.blocked_by_set && !d.aliases_set)
	testing.expect(t, d.sprint == "" && d.blocked_by == nil && d.aliases == nil)

	_, reason = tracker.decode_incident_fields_changed(parse_json(
		"{\"target\":\"INC-01\",\"sprint\":[\"SPR-9\"]}", a,
	), a)
	testing.expect(t, reason == "sprint: expected a string", reason)
}

@(test)
tracker_labels :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	a := fresh_arena(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	testing.expect(t, tracker.label_valid("a"))
	testing.expect(t, tracker.label_valid("wave-2"))
	testing.expect(t, tracker.label_valid("0x_9"))
	testing.expect(t, !tracker.label_valid(""))
	testing.expect(t, !tracker.label_valid("Wave"))  // uppercase rejected
	testing.expect(t, !tracker.label_valid("-lead")) // lead char charset
	testing.expect(t, !tracker.label_valid("a b"))   // space
	// 33 chars
	testing.expect(t, !tracker.label_valid("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))

	normalized, ok := tracker.normalize_labels([]string{"ops", "storage", "ops", "alpha"}, a)
	testing.expect(t, ok)
	testing.expect_value(t, len(normalized), 3)
	testing.expect(t, normalized[0] == "alpha" && normalized[1] == "ops" && normalized[2] == "storage")

	_, ok = tracker.normalize_labels([]string{"ok", "BAD"}, a)
	testing.expect(t, !ok)

	empty: []string
	empty, ok = tracker.normalize_labels(nil, a)
	testing.expect(t, ok && empty == nil)
}

@(test)
tracker_uid :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	a := fresh_arena(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	uid := tracker.uid_mint(1000, 0xdeadbeef, a)
	testing.expect_value(t, len(uid), 33) // 16 + '-' + 16
	testing.expect(t, strings.has_prefix(uid, "00000000000003e8-"), uid)
	testing.expect(t, strings.has_suffix(uid, "00000000deadbeef"), uid)

	ns, ok := tracker.uid_ts_ns(uid)
	testing.expect(t, ok)
	testing.expect_value(t, ns, 1000)

	// Negative ns still round trips (two's complement hex).
	uid2 := tracker.uid_mint(-2, 1, a)
	ns2: i64
	ns2, ok = tracker.uid_ts_ns(uid2)
	testing.expect(t, ok)
	testing.expect_value(t, ns2, -2)

	_, ok = tracker.uid_ts_ns("zzzz")
	testing.expect(t, !ok)
	_, ok = tracker.uid_ts_ns("00000000000000ZZ-0")
	testing.expect(t, !ok)

	testing.expect(t, tracker.origin_string(0xdeadbeef, a) == "deadbeef")
}

@(private)
a_of :: proc(h: ^Fold_Harness) -> mem.Allocator {
	// Validation errors clone into the fold's scratch arena (the request
	// arena at the daemon boundary).
	return mem.dynamic_arena_allocator(&h.scratch)
}

@(private)
Fold_Harness :: struct {
	state:   tracker.Fold_State,
	scratch: mem.Dynamic_Arena,
	rows:    [dynamic]store.Event_Row,
}

@(private)
harness_init :: proc(h: ^Fold_Harness) {
	tracker.fold_state_init(&h.state, context.allocator)
	mem.dynamic_arena_init(&h.scratch, context.allocator)
	h.rows = make([dynamic]store.Event_Row, 0, 32, context.allocator)
}

@(private)
harness_destroy :: proc(h: ^Fold_Harness) {
	a := mem.dynamic_arena_allocator(&h.scratch)
	_ = a
	for i in 0..<len(h.rows) {
		row := h.rows[i]
		delete(row.uid)
		delete(row.origin)
		delete(row.kind)
		delete(row.payload)
	}
	delete(h.rows)
	mem.dynamic_arena_destroy(&h.scratch)
	tracker.fold_state_destroy(&h.state)
}

// apply folds one synthetic event; ns orders it (uid minted from ns).
@(private)
harness_apply :: proc(t: ^testing.T, h: ^Fold_Harness, ns: i64, kind: string, payload: string) -> bool {
	sa := mem.dynamic_arena_allocator(&h.scratch)
	row := store.Event_Row{
		uid     = tracker.uid_mint(ns, 0, context.allocator),
		ts      = ns / 1_000_000,
		origin  = tracker.origin_string(0xaabbcc01, context.allocator),
		kind    = strings.clone(kind, context.allocator),
		version = 1,
		payload = strings.clone(payload, context.allocator),
	}
	append(&h.rows, row)
	ev, reason := tracker.decode_event(&h.rows[len(h.rows)-1], sa)
	testing.expectf(t, reason == "", "decode %s: %s", kind, reason)
	return tracker.fold_apply(&h.state, &ev, sa)
}

@(private)
hdr_field :: proc(h: ^Fold_Harness, id: string) -> ^tracker.Incident_Header {
	return tracker.incident_by_id(&h.state, id)
}

@(test)
tracker_fold_lifecycle :: proc(t: ^testing.T) {
	h: Fold_Harness
	harness_init(&h)
	defer harness_destroy(&h)

	created := harness_apply(t, &h, 1_000_000_000, "incident.created",
		"{\"title\":\"disk full\",\"priority\":\"low\",\"labels\":[\"ops\"],\"aliases\":[\"AL-1\"],\"created_by\":\"lee\",\"body_md\":\"race at boot\"}")
	testing.expect(t, created)
	created = harness_apply(t, &h, 2_000_000_000, "incident.created",
		"{\"title\":\"hang\",\"priority\":\"urgent\",\"blocked_by\":[\"INC-001\"],\"aliases\":[\"AL-2\"]}")
	testing.expect(t, created)
	created = harness_apply(t, &h, 3_000_000_000, "incident.created",
		"{\"title\":\"typo\",\"priority\":\"low\"}")
	testing.expect(t, created)

	inc1 := hdr_field(&h, "INC-001")
	inc2 := hdr_field(&h, "INC-002")
	inc3 := hdr_field(&h, "INC-003")
	if inc1 == nil || inc2 == nil || inc3 == nil {
		testing.expectf(t, false, "all three incidents must exist")
		return
	}
	testing.expect_value(t, len(inc1.events), 1) // created ref on the timeline

	// Verify rejected flips to terminal rejected with verdict and pattern.
	verified := harness_apply(t, &h, 4_000_000_000, "incident.verified",
		"{\"target\":\"INC-001\",\"verdict\":\"rejected\",\"fp_pattern\":\"spec\",\"reason_md\":\"not a bug\",\"evidence_md\":\"spec line\"}")
	testing.expect(t, verified)
	testing.expect(t, inc1.status == "rejected")
	testing.expect(t, inc1.verdict == "rejected" && inc1.fp_pattern == "spec")
	testing.expect(t, inc1.verified_ms > 0)

	// The legal path for the second incident: verify confirmed →
	// root_cause → resolved.
	testing.expect(t, harness_apply(t, &h, 5_000_000_000, "incident.verified",
		"{\"target\":\"INC-002\",\"verdict\":\"confirmed\",\"reason_md\":\"real\",\"evidence_md\":\"logs\"}"))
	testing.expect(t, harness_apply(t, &h, 5_100_000_000, "incident.root_caused",
		"{\"target\":\"INC-002\",\"cause_md\":\"unbounded retry loop\"}"))
	testing.expect(t, inc2.status == "root_caused")
	testing.expect(t, harness_apply(t, &h, 5_300_000_000, "incident.status_changed",
		"{\"target\":\"INC-002\",\"from\":\"root_caused\",\"to\":\"resolved\",\"resolution\":\"fixed\",\"evidence_md\":\"commit\"}"))
	testing.expect(t, inc2.status == "resolved")
	testing.expect(t, inc2.resolution == "fixed")
	testing.expect(t, inc2.resolved_ms > 0)

	// DAG: the second incident is blocked by the first.
	deps := tracker.dag_dependents(&h.state.dag, "INC-001", context.temp_allocator)
	defer if deps != nil { delete(deps, context.temp_allocator) }
	testing.expect_value(t, len(deps), 1)
	testing.expect(t, deps[0] == "INC-002")

	// Fields replacement, notes, title.
	testing.expect(t, harness_apply(t, &h, 6_000_000_000, "incident.fields_changed",
		"{\"target\":\"INC-003\",\"priority\":\"urgent\",\"labels\":[\"wave-1\",\"perf\"]}"))
	testing.expect(t, inc3.priority == "urgent")
	testing.expect_value(t, len(inc3.labels), 2)
	testing.expect(t, harness_apply(t, &h, 7_000_000_000, "incident.note_appended",
		"{\"target\":\"INC-003\",\"body_md\":\"watch it\"}"))
	testing.expect_value(t, inc3.note_count, 1)
	testing.expect(t, harness_apply(t, &h, 8_000_000_000, "incident.title_changed",
		"{\"target\":\"INC-003\",\"title\":\"typo in banner\"}"))
	testing.expect(t, inc3.title == "typo in banner")

	// Duplicate uid is a no-op; an older uid demands a refold.
	testing.expect(t, harness_apply(t, &h, 8_000_000_000, "incident.title_changed",
		"{\"target\":\"INC-003\",\"title\":\"dupe uid\"}"))
	testing.expect(t, inc3.title == "typo in banner")
	stale := tracker.Decoded_Event{uid = "0000000000000000-0000000000000001"}
	testing.expect(t, !tracker.fold_apply(&h.state, &stale, mem.dynamic_arena_allocator(&h.scratch)))

	// Reopen clears the verdict and resolution record.
	testing.expect(t, harness_apply(t, &h, 9_000_000_000, "incident.status_changed",
		"{\"target\":\"INC-002\",\"from\":\"resolved\",\"to\":\"reported\"}"))
	testing.expect(t, inc2.status == "reported")
	testing.expect(t, inc2.verdict == "" && inc2.resolution == "")
	testing.expect_value(t, inc2.verified_ms, 0)
}

@(test)
tracker_fold_anomaly_absorption :: proc(t: ^testing.T) {
	h: Fold_Harness
	harness_init(&h)
	defer harness_destroy(&h)

	testing.expect(t, harness_apply(t, &h, 1_000_000_000, "incident.created",
		"{\"title\":\"one\",\"priority\":\"low\",\"aliases\":[\"AL-1\"]}"))
	inc1 := hdr_field(&h, "INC-001")
	testing.expect(t, inc1 != nil)

	// Orphan target: state-level anomaly, fold stays alive.
	testing.expect(t, harness_apply(t, &h, 2_000_000_000, "incident.title_changed",
		"{\"target\":\"INC-099\",\"title\":\"ghost\"}"))
	testing.expect_value(t, len(h.state.anomalies), 1)

	// Verify from a non-reported status: applied but flagged.
	testing.expect(t, harness_apply(t, &h, 3_000_000_000, "incident.created",
		"{\"title\":\"two\"}"))
	inc2 := hdr_field(&h, "INC-002")
	testing.expect(t, harness_apply(t, &h, 4_000_000_000, "incident.verified",
		"{\"target\":\"INC-002\",\"verdict\":\"confirmed\",\"reason_md\":\"r\",\"evidence_md\":\"e\"}"))
	testing.expect(t, harness_apply(t, &h, 6_000_000_000, "incident.verified",
		"{\"target\":\"INC-002\",\"verdict\":\"confirmed\",\"reason_md\":\"again\",\"evidence_md\":\"e\"}"))
	testing.expect(t, inc2.status == "confirmed")
	testing.expect(t, inc2.is_anomaly)
	testing.expect_value(t, len(inc2.anomaly_detail), 1)
	if len(inc2.anomaly_detail) > 0 {
		testing.expect(t, strings.contains(inc2.anomaly_detail[0], "verified on status confirmed"))
	}

	// A clean later event clears the anomaly.
	testing.expect(t, harness_apply(t, &h, 7_000_000_000, "incident.note_appended",
		"{\"target\":\"INC-002\",\"body_md\":\"note\"}"))
	testing.expect(t, !inc2.is_anomaly)

	// A foreign (pre-rewrite) execution status is applied but flagged —
	// no migration, the fold absorbs old-vocabulary events.
	testing.expect(t, harness_apply(t, &h, 8_000_000_000, "incident.status_changed",
		"{\"target\":\"INC-002\",\"from\":\"confirmed\",\"to\":\"fixing\"}"))
	testing.expect(t, inc2.status == "fixing")
	testing.expect(t, inc2.is_anomaly)

	// Alias collision: flagged, registration refused.
	testing.expect(t, harness_apply(t, &h, 9_000_000_000, "incident.created",
		"{\"title\":\"three\",\"aliases\":[\"AL-1\"]}"))
	inc3 := hdr_field(&h, "INC-003")
	testing.expect(t, inc3.is_anomaly)
	owner := h.state.aliases["AL-1"]
	testing.expect(t, owner == inc1)

	// Malformed payload and unknown kinds are absorbed, not fatal. The
	// anomaly line carries the decoder's field-level reason, so a foreign
	// row says which field broke shape.
	testing.expect(t, harness_apply(t, &h, 10_000_000_000, "incident.title_changed",
		"{\"target\":\"INC-001\",\"title\":42}"))
	if n := len(h.state.anomalies); n > 0 {
		testing.expect(t, strings.contains(h.state.anomalies[n-1], "title"), h.state.anomalies[n-1])
	}
	testing.expect(t, harness_apply(t, &h, 11_000_000_000, "incident.exploded", "{}"))
	testing.expect(t, len(h.state.anomalies) >= 2)

	// Tombstones refuse further events and release their aliases.
	testing.expect(t, harness_apply(t, &h, 12_000_000_000, "incident.deleted",
		"{\"target\":\"INC-001\",\"reason\":\"dup\"}"))
	testing.expect(t, inc1.is_deleted)
	_, still_taken := h.state.aliases["AL-1"]
	testing.expect(t, !still_taken)
	testing.expect(t, harness_apply(t, &h, 13_000_000_000, "incident.title_changed",
		"{\"target\":\"INC-001\",\"title\":\"zombie\"}"))
	testing.expect(t, inc1.title == "one")
	if len(inc1.anomaly_detail) == 0 {
		testing.expectf(t, false, "event on deleted incident must record an anomaly")
		return
	}
	testing.expect(t, strings.contains(inc1.anomaly_detail[len(inc1.anomaly_detail)-1], "event on deleted incident"))
}

@(test)
tracker_fold_blocked_cycles :: proc(t: ^testing.T) {
	h: Fold_Harness
	harness_init(&h)
	defer harness_destroy(&h)

	testing.expect(t, harness_apply(t, &h, 1_000_000_000, "incident.created", "{\"title\":\"A\"}"))
	testing.expect(t, harness_apply(t, &h, 2_000_000_000, "incident.created", "{\"title\":\"B\"}"))
	inc_a := hdr_field(&h, "INC-001")
	inc_b := hdr_field(&h, "INC-002")

	// Rebuilding a node's edges detaches every incident edge in both
	// directions, so a reverse edge added afterwards is legal — the
	// fold-side cycle flag stays vestigial and the write path is the real
	// guard.
	testing.expect(t, harness_apply(t, &h, 3_000_000_000, "incident.fields_changed",
		"{\"target\":\"INC-002\",\"blocked_by\":[\"INC-001\"]}"))
	testing.expect(t, harness_apply(t, &h, 4_000_000_000, "incident.fields_changed",
		"{\"target\":\"INC-001\",\"blocked_by\":[\"INC-002\"]}"))
	testing.expect_value(t, len(inc_a.blocked_by), 1)
	testing.expect(t, !inc_a.is_anomaly)

	// The cycle primitive itself: only A→B survived the rebuild, so
	// re-adding B→A would close a cycle and re-adding A→B would not.
	testing.expect(t, tracker.dag_would_create_cycle(&h.state.dag, "INC-002", "INC-001"))
	testing.expect(t, !tracker.dag_would_create_cycle(&h.state.dag, "INC-001", "INC-002"))
	testing.expect(t, tracker.dag_would_create_cycle(&h.state.dag, "INC-001", "INC-001"))

	_ = inc_b

	// Deleting a node severs its edges on both sides.
	testing.expect(t, harness_apply(t, &h, 5_000_000_000, "incident.deleted",
		"{\"target\":\"INC-001\",\"reason\":\"done\"}"))
	deps2 := tracker.dag_dependents(&h.state.dag, "INC-001", context.temp_allocator)
	defer if deps2 != nil { delete(deps2, context.temp_allocator) }
	testing.expect_value(t, len(deps2), 0)
}

@(test)
tracker_fold_sprint_close :: proc(t: ^testing.T) {
	h: Fold_Harness
	harness_init(&h)
	defer harness_destroy(&h)

	// A finding filed BEFORE the sprint starts (the "early" one): outside
	// the cohort forever, whatever its membership later becomes — but the
	// verdict and resolution recorded on it during the window count as
	// cross-cohort activity.
	testing.expect(t, harness_apply(t, &h, 500_000_000, "incident.created",
		"{\"title\":\"early\"}"))

	// The sprint with three in-window members: one to verify+resolve, one
	// to reject with an FP pattern, one left open.
	testing.expect(t, harness_apply(t, &h, 1_000_000_000, "sprint.started",
		"{\"name\":\"round 1\",\"goal_md\":\"ship\"}"))
	spr := tracker.sprint_by_id(&h.state, "SPR-001")
	testing.expect(t, spr != nil && spr.status == .Active)

	titles := []string{"m1", "m2", "m3"}
	for title, i in titles {
		buf: [4]string
		buf[0] = "{\"title\":\""
		buf[1] = title
		buf[2] = "\",\"sprint\":\"SPR-001\",\"labels\":[\"wave-1\"]}"
		testing.expect(t, harness_apply(t, &h, 2_000_000_000 + i64(i) * 10_000_000, "incident.created", strings.concatenate(buf[:], context.temp_allocator)))
	}
	// An in-window BACKLOG filing (no sprint assignment): inside the
	// cohort — statistics follow filing time, never membership.
	testing.expect(t, harness_apply(t, &h, 2_500_000_000, "incident.created",
		"{\"title\":\"bg\"}"))
	m1 := hdr_field(&h, "INC-002")
	m2 := hdr_field(&h, "INC-003")
	m3 := hdr_field(&h, "INC-004")
	bg := hdr_field(&h, "INC-005")
	if m1 == nil || m2 == nil || m3 == nil || bg == nil {
		testing.expectf(t, false, "headers missing: %v %v %v %v", m1, m2, m3, bg)
		return
	}
	testing.expect(t, m1.sprint == "SPR-001")
	testing.expect(t, bg.sprint == "")

	// The early finding is judged, pulled INTO the sprint (membership
	// only), and resolved — all inside the window.
	testing.expect(t, harness_apply(t, &h, 3_000_000_000, "incident.verified",
		"{\"target\":\"INC-001\",\"verdict\":\"confirmed\",\"reason_md\":\"r\",\"evidence_md\":\"e\"}"))
	testing.expect(t, harness_apply(t, &h, 3_500_000_000, "incident.fields_changed",
		"{\"target\":\"INC-001\",\"sprint\":\"SPR-001\"}"))
	testing.expect(t, hdr_field(&h, "INC-001").sprint == "SPR-001")
	testing.expect(t, harness_apply(t, &h, 3_600_000_000, "incident.root_caused",
		"{\"target\":\"INC-001\",\"cause_md\":\"race at boot\"}"))
	testing.expect(t, harness_apply(t, &h, 3_800_000_000, "incident.status_changed",
		"{\"target\":\"INC-001\",\"from\":\"root_caused\",\"to\":\"resolved\",\"resolution\":\"fixed\"}"))

	// m1 walks to resolved; m2 is rejected with a pattern.
	testing.expect(t, harness_apply(t, &h, 4_000_000_000, "incident.verified",
		"{\"target\":\"INC-002\",\"verdict\":\"confirmed\",\"reason_md\":\"r\",\"evidence_md\":\"e\"}"))
	testing.expect(t, harness_apply(t, &h, 5_000_000_000, "incident.root_caused",
		"{\"target\":\"INC-002\",\"cause_md\":\"overflow\"}"))
	testing.expect(t, harness_apply(t, &h, 7_000_000_000, "incident.status_changed",
		"{\"target\":\"INC-002\",\"from\":\"root_caused\",\"to\":\"resolved\",\"resolution\":\"fixed\"}"))
	testing.expect(t, harness_apply(t, &h, 7_500_000_000, "incident.verified",
		"{\"target\":\"INC-003\",\"verdict\":\"rejected\",\"fp_pattern\":\"hallucinated\",\"reason_md\":\"r\",\"evidence_md\":\"e\"}"))

	// Goal update mid-sprint, then close with an outcome.
	testing.expect(t, harness_apply(t, &h, 8_000_000_000, "sprint.goal_updated",
		"{\"target\":\"SPR-001\",\"goal_md\":\"ship harder\"}"))
	testing.expect(t, harness_apply(t, &h, 9_000_000_000, "sprint.closed",
		"{\"outcome_md\":\"done\"}"))

	testing.expect(t, spr.status == .Closed)
	testing.expect(t, spr.closed_ms > 0)

	// The filed cohort: the three in-window filings plus the backlog
	// filing; the pulled-in early finding stays out. Outcomes read the
	// headers' current verdict/status. No snapshot — re-derived live.
	st := tracker.compute_sprint_stats(&h.state, spr, context.allocator)
	testing.expect_value(t, st.total, 4)
	testing.expect_value(t, st.confirmed, 1)
	testing.expect_value(t, st.rejected, 1)
	testing.expect_value(t, st.unjudged, 2) // m3 + bg
	testing.expect_value(t, st.resolved, 1) // m1; the early finding is out-of-cohort
	testing.expect(t, st.fp_rate == 0.5)
	testing.expect_value(t, st.by_pattern["hallucinated"], 1)
	testing.expect_value(t, len(st.cohort), 4)
	testing.expect(t, st.cohort[0] == "INC-002" && st.cohort[3] == "INC-005")
	testing.expect_value(t, st.judged_earlier, 1)   // the early finding, verified in-window
	testing.expect_value(t, st.resolved_earlier, 1) // the early finding, resolved in-window
	ls := st.by_label["wave-1"]
	testing.expect(t, ls != nil)
	if ls != nil {
		testing.expect_value(t, ls.total, 3)
		testing.expect_value(t, ls.by_priority["medium"], 3)
		testing.expect_value(t, ls.rejected, 1)
		testing.expect(t, ls.fp_rate == 0.5)
	}
	testing.expect_value(t, st.by_priority["medium"], 4)
	tracker.sprint_stats_destroy(st, context.allocator)
	free(st, context.allocator)

	// No sweep: close owns no data — every member keeps its assignment.
	testing.expect(t, m3.sprint == "SPR-001")
	testing.expect(t, m2.sprint == "SPR-001")
	testing.expect(t, m1.sprint == "SPR-001")
	testing.expect(t, hdr_field(&h, "INC-001").sprint == "SPR-001")

	// Attribution: a verdict landing in the NEXT round's window on THIS
	// round's filing updates this round's re-derived stats (an FP belongs
	// to the round that detected it) and shows as cross-cohort activity
	// in the next round's stats.
	testing.expect(t, harness_apply(t, &h, 10_000_000_000, "sprint.started",
		"{\"name\":\"round 2\",\"goal_md\":\"verify\"}"))
	spr2 := tracker.sprint_by_id(&h.state, "SPR-002")
	testing.expect(t, spr2 != nil)
	if spr2 == nil {
		return
	}
	testing.expect(t, harness_apply(t, &h, 11_000_000_000, "incident.verified",
		"{\"target\":\"INC-005\",\"verdict\":\"confirmed\",\"reason_md\":\"r\",\"evidence_md\":\"e\"}"))

	st2 := tracker.compute_sprint_stats(&h.state, spr, context.allocator)
	testing.expect_value(t, st2.total, 4)
	testing.expect_value(t, st2.confirmed, 2) // bg judged later — live outcome
	testing.expect_value(t, st2.unjudged, 1)  // m3 only now
	testing.expect(t, st2.fp_rate > 0.33 && st2.fp_rate < 0.34) // 1 rejected / 3 judged
	tracker.sprint_stats_destroy(st2, context.allocator)
	free(st2, context.allocator)

	st3 := tracker.compute_sprint_stats(&h.state, spr2, context.allocator)
	testing.expect_value(t, st3.total, 0)
	testing.expect_value(t, st3.judged_earlier, 1) // bg, filed in round 1's window
	testing.expect_value(t, st3.resolved_earlier, 0)
	tracker.sprint_stats_destroy(st3, context.allocator)
	free(st3, context.allocator)

	// A late assignment to the closed sprint is flagged stale; body
	// events on it are state anomalies; outcome updates are legal.
	testing.expect(t, harness_apply(t, &h, 12_000_000_000, "incident.created",
		"{\"title\":\"late\",\"sprint\":\"SPR-001\"}"))
	late := hdr_field(&h, "INC-006")
	testing.expect(t, late != nil && late.is_anomaly)
	if late != nil && len(late.anomaly_detail) > 0 {
		testing.expect(t, strings.contains(late.anomaly_detail[0], "is closed (stale assignment)"))
	}
	testing.expect(t, harness_apply(t, &h, 13_000_000_000, "sprint.note_appended",
		"{\"target\":\"SPR-001\",\"body_md\":\"retro\"}"))
	testing.expect(t, len(h.state.anomalies) > 0)
	testing.expect(t, harness_apply(t, &h, 14_000_000_000, "sprint.outcome_updated",
		"{\"target\":\"SPR-001\",\"outcome_md\":\"done and dusted\"}"))
}

@(test)
tracker_validate_fields :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	a := fresh_arena(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	trimmed, err := tracker.validate_title("  disk full \n", a)
	testing.expectf(t, err == nil, "title err: %v", err)
	testing.expect(t, trimmed == "disk full")

	_, err = tracker.validate_title("   ", a)
	testing.expect(t, err != nil)
	_, err = tracker.validate_title("a\nb", a)
	testing.expect(t, err != nil)
	long := strings.clone(strings.repeat("x", 121, context.temp_allocator), context.temp_allocator)
	_, err = tracker.validate_title(long, a)
	testing.expect(t, err != nil)
	delete(long, context.temp_allocator)

	dedup := tracker.dedup_sorted([]string{"b", "a", "b", "c"}, a)
	testing.expect_value(t, len(dedup), 3)
	testing.expect(t, dedup[0] == "a" && dedup[1] == "b" && dedup[2] == "c")

	testing.expect(t, tracker.validate_priority("urgent", a) == nil)
	testing.expect(t, tracker.validate_priority("whenever", a) != nil)
	testing.expect(t, tracker.validate_status_value("root_caused", a) == nil)
	testing.expect(t, tracker.validate_status_value("rejected", a) != nil)
	// The execution predicates left the vocabulary with the rewrite.
	testing.expect(t, tracker.validate_status_value("fixing", a) != nil)
	testing.expect(t, tracker.validate_status_value("verifying", a) != nil)
	testing.expect(t, tracker.validate_status_value("blocked", a) != nil)
	// The must list: stable single-line IDs, order preserved, no dups.
	testing.expect(t, tracker.validate_must_tasks([]string{"T1", "T2"}, a) == nil)
	testing.expect(t, tracker.validate_must_tasks([]string{"T1", "T1"}, a) != nil)
	testing.expect(t, tracker.validate_must_tasks([]string{"", "T2"}, a) != nil)
	testing.expect(t, tracker.validate_must_tasks([]string{"T\n1"}, a) != nil)
}

@(test)
tracker_validate_gates :: proc(t: ^testing.T) {
	h: Fold_Harness
	harness_init(&h)
	defer harness_destroy(&h)

	testing.expect(t, harness_apply(t, &h, 1_000_000_000, "incident.created",
		"{\"title\":\"one\",\"body_md\":\"claim\"}"))
	inc1 := hdr_field(&h, "INC-001")
	testing.expect(t, inc1 != nil)

	// Resolving demands a resolution and evidence; from reported the gate
	// says verify first.
	_, err := tracker.build_status_change_data(&h.state, inc1, {to = "resolved"}, a_of(&h))
	testing.expect(t, err != nil)
	_, err = tracker.build_status_change_data(&h.state, inc1, {to = "resolved", resolution = "fixed"}, a_of(&h))
	testing.expect(t, err != nil)
	// From reported, root_caused is a G1 rejection (verify first).
	_, err = tracker.build_status_change_data(&h.state, inc1, {to = "root_caused"}, a_of(&h))
	testing.expect(t, err != nil)
	// The execution predicates are no longer statuses at all.
	_, err = tracker.build_status_change_data(&h.state, inc1, {to = "blocked"}, a_of(&h))
	testing.expect(t, err != nil)

	// After verify: root_cause records through its own field, and resolve
	// is legal only from root_caused.
	testing.expect(t, harness_apply(t, &h, 2_000_000_000, "incident.verified",
		"{\"target\":\"INC-001\",\"verdict\":\"confirmed\",\"reason_md\":\"r\",\"evidence_md\":\"e\"}"))
	_, err = tracker.build_root_cause_data(inc1, "", a_of(&h))
	testing.expect(t, err != nil)
	_, err = tracker.build_root_cause_data(inc1, "retry storm", a_of(&h))
	testing.expectf(t, err == nil, "legal root_cause: %v", err)
	_, err = tracker.build_status_change_data(&h.state, inc1, {to = "resolved", resolution = "fixed", evidence_md = "commit"}, a_of(&h))
	testing.expect(t, err != nil) // still confirmed — record the root cause first
	testing.expect(t, harness_apply(t, &h, 2_500_000_000, "incident.root_caused",
		"{\"target\":\"INC-001\",\"cause_md\":\"retry storm\"}"))
	_, err = tracker.build_status_change_data(&h.state, inc1, {to = "resolved", resolution = "fixed", evidence_md = "commit"}, a_of(&h))
	testing.expectf(t, err == nil, "legal resolve: %v", err)

	// Alias collisions and self-blocks are refused.
	testing.expect(t, harness_apply(t, &h, 3_000_000_000, "incident.created",
		"{\"title\":\"two\",\"aliases\":[\"AL-1\"]}"))
	inc2 := hdr_field(&h, "INC-002")
	// AL-1 is registered to the alias creator ("two"); "one" is a stranger.
	testing.expect(t, tracker.validate_aliases(&h.state, []string{"AL-1"}, inc2, a_of(&h)) == nil)
	testing.expect(t, tracker.validate_aliases(&h.state, []string{"AL-1"}, inc1, a_of(&h)) != nil)
	testing.expect(t, tracker.validate_blocked_targets(&h.state, "INC-001", []string{"INC-001"}, a_of(&h)) != nil)
	testing.expect(t, tracker.validate_blocked_targets(&h.state, "", []string{"INC-099"}, a_of(&h)) != nil)
}

@(test)
tracker_payload_roundtrip :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	a := fresh_arena(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	created := tracker.Incident_Created_Data{
		title = "disk full", priority = "urgent",
		labels = []string{"ops"}, sprint = "SPR-01",
		blocked_by = []string{"INC-02"}, assignee = "kim",
		aliases = []string{"AL-1"}, created_by = "lee", body_md = "race",
	}
	encoded := tracker.encode_incident_created(&created, a)
	back, reason := tracker.decode_incident_created(parse_json(encoded, a), a)
	testing.expectf(t, reason == "", "decode: %s", reason)
	testing.expect(t, back.title == "disk full" && back.priority == "urgent")
	testing.expect_value(t, len(back.labels), 1)
	testing.expect_value(t, len(back.blocked_by), 1)
	testing.expect(t, back.sprint == "SPR-01" && back.assignee == "kim")

	// A whole-value clear of labels round-trips as present-and-empty.
	fields := tracker.Incident_Fields_Changed_Data{
		target = "INC-01", labels_set = true, labels = nil,
	}
	encoded = tracker.encode_incident_fields_changed(&fields, a)
	back_f, reason2 := tracker.decode_incident_fields_changed(parse_json(encoded, a), a)
	testing.expectf(t, reason2 == "", "fields decode: %s", reason2)
	testing.expect(t, back_f.labels_set && len(back_f.labels) == 0)

	// Empty omitempty fields drop out of the created payload entirely.
	bare := tracker.Incident_Created_Data{title = "t", priority = "low"}
	encoded = tracker.encode_incident_created(&bare, a)
	testing.expect(t, encoded == "{\"priority\":\"low\",\"title\":\"t\"}", encoded)

	// The must list rides started/goal_updated as a whole-value presence
	// pair (empty array survives as an explicit clear).
	started := tracker.Sprint_Started_Data{name = "r1", goal_md = "ship", must = []string{"T1", "T2"}}
	encoded = tracker.encode_sprint_started(&started, a)
	back_s, reason3 := tracker.decode_sprint_started(parse_json(encoded, a), a)
	testing.expectf(t, reason3 == "", "started decode: %s", reason3)
	testing.expect(t, back_s.must_set && len(back_s.must) == 2 && back_s.must[0] == "T1")

	goal := tracker.Sprint_Goal_Updated_Data{target = "SPR-001", must_set = true, must = nil}
	encoded = tracker.encode_sprint_goal_updated(&goal, a)
	back_g, reason4 := tracker.decode_sprint_goal_updated(parse_json(encoded, a), a)
	testing.expectf(t, reason4 == "", "goal decode: %s", reason4)
	testing.expect(t, back_g.must_set && len(back_g.must) == 0)
	testing.expect(t, !back_g.goal_set && back_g.goal_md == "") // goal untouched

	// A typed defer note and a verification record round trip.
	note := tracker.Sprint_Note_Appended_Data{
		target = "SPR-001", body_md = "keep or drop the cache?",
		defer_id = "DEF-001", defer_type = "question", task = "T2",
	}
	encoded = tracker.encode_sprint_note_appended(&note, a)
	back_n, reason5 := tracker.decode_sprint_note_appended(parse_json(encoded, a), a)
	testing.expectf(t, reason5 == "", "note decode: %s", reason5)
	testing.expect(t, back_n.defer_id == "DEF-001" && back_n.defer_type == "question" && back_n.task == "T2")

	verif := tracker.Sprint_Task_Verified_Data{
		target = "SPR-001", task = "T1", definition = "just test",
		outcome = "passed", output = "603 green", session = "s1",
	}
	encoded = tracker.encode_sprint_task_verified(&verif, a)
	back_v, reason6 := tracker.decode_sprint_task_verified(parse_json(encoded, a), a)
	testing.expectf(t, reason6 == "", "verif decode: %s", reason6)
	testing.expect(t, back_v.task == "T1" && back_v.definition == "just test")
	testing.expect(t, back_v.outcome == "passed" && back_v.output == "603 green" && back_v.session == "s1")
}

@(private)
test_fetch :: proc(user: rawptr, uids: []string, a: mem.Allocator) -> map[string]string {
	rows := cast(^[dynamic]store.Event_Row)(user)
	out := make(map[string]string, len(uids), a)
	for row in rows {
		for uid in uids {
			if row.uid == uid {
				out[row.uid] = strings.clone(row.payload, a)
			}
		}
	}
	return out
}

@(private)
NOW_MS_FOR_TEST :: i64(60_000_000) // 60s after epoch; events use ns 1..13 × 1e6

@(test)
tracker_render_list_and_summary :: proc(t: ^testing.T) {
	h: Fold_Harness
	harness_init(&h)
	defer harness_destroy(&h)

	// Empty state renders the empty contract line, citing the tool by its
	// real name in this binary.
	out, err := tracker.render_incident_list(&h.state, &tracker.Incident_Filter{}, NOW_MS_FOR_TEST, context.temp_allocator)
	testing.expectf(t, err == nil, "empty list err: %v", err)
	testing.expect(t, out == "0 incidents\nno incidents yet — incident_create to file one", out)

	// The sprint list's empty line names sprint_start.
	suser := cast(rawptr)(&h.rows)
	slist := tracker.sprint_list(&h.state, test_fetch, suser, true, 0, NOW_MS_FOR_TEST, context.temp_allocator)
	testing.expectf(t, strings.contains(slist, "no active sprint — sprint_start to start one"), "empty sprint list: %s", slist)

	testing.expect(t, harness_apply(t, &h, 1_000_000_000, "incident.created",
		"{\"title\":\"disk full\",\"priority\":\"urgent\",\"labels\":[\"ops\"],\"body_md\":\"claim\"}"))
	testing.expect(t, harness_apply(t, &h, 2_000_000_000, "incident.created",
		"{\"title\":\"hang\",\"priority\":\"low\",\"body_md\":\"claim\"}"))
	testing.expect(t, harness_apply(t, &h, 3_000_000_000, "incident.verified",
		"{\"target\":\"INC-001\",\"verdict\":\"confirmed\",\"reason_md\":\"r\",\"evidence_md\":\"e\"}"))

	// Default list: counts header, newest first ("disk full" was updated
	// last by the verify event, so it renders above "hang").
	f := tracker.Incident_Filter{}
	out, err = tracker.render_incident_list(&h.state, &f, NOW_MS_FOR_TEST, context.temp_allocator)
	testing.expectf(t, err == nil, "list err: %v", err)
	if err != nil {
		return
	}
	testing.expect(t, strings.has_prefix(out, "2 incidents: "), out)
	testing.expect(t, strings.contains(out, "1 urgent; "), out)
	testing.expect(t, strings.contains(out, "1 confirmed"), out)
	header_nl := strings.index_byte(out, '\n')
	if header_nl < 0 {
		testing.expectf(t, false, "list output must be multi-line: %s", out)
		return
	}
	header := out[:header_nl]
	testing.expect(t, strings.contains(header, "2 incidents"), header)
	first_incident := out[header_nl + 1:]
	first_nl := strings.index_byte(first_incident, '\n')
	if first_nl < 0 {
		testing.expectf(t, false, "list output must carry per-incident lines: %s", first_incident)
		return
	}
	first_incident = first_incident[:first_nl]
	testing.expect(t, strings.contains(first_incident, "INC-001"), first_incident)

	// The "open" filter expands to non-terminal statuses; the matched
	// header echoes the filter.
	f = tracker.Incident_Filter{status = []string{"open"}}
	out, _ = tracker.render_incident_list(&h.state, &f, NOW_MS_FOR_TEST, context.temp_allocator)
	testing.expect(t, strings.has_prefix(out, "matched 2/2 (status=open)"), out)

	// Priority sort puts urgent first regardless of recency.
	f = tracker.Incident_Filter{sort = "priority"}
	out, _ = tracker.render_incident_list(&h.state, &f, NOW_MS_FOR_TEST, context.temp_allocator)
	prio_line := out[strings.index_byte(out, '\n') + 1:]
	prio_line = prio_line[:strings.index_byte(prio_line, '\n')]
	testing.expect(t, strings.contains(prio_line, "INC-001"), prio_line)

	// Created sort is oldest first.
	f = tracker.Incident_Filter{sort = "created"}
	out, _ = tracker.render_incident_list(&h.state, &f, NOW_MS_FOR_TEST, context.temp_allocator)
	created_line := out[strings.index_byte(out, '\n') + 1:]
	created_line = created_line[:strings.index_byte(created_line, '\n')]
	testing.expect(t, strings.contains(created_line, "INC-001"), created_line)

	// Limit truncation tail.
	f = tracker.Incident_Filter{limit = 1}
	out, _ = tracker.render_incident_list(&h.state, &f, NOW_MS_FOR_TEST, context.temp_allocator)
	testing.expect(t, strings.has_suffix(out, "\n…and 1 more (raise limit or filter)"), out)

	// Summary: one unverified open incident ("hang", created 2s in).
	summary := tracker.render_open_summary(&h.state, NOW_MS_FOR_TEST, context.temp_allocator)
	testing.expect(t, strings.contains(summary, "Tracker: 2 open ("), summary)
	testing.expect(t, strings.contains(summary, "1 urgent"), summary)
	testing.expect(t, strings.contains(summary, "1 unverified"), summary)

	// An illegal transition flags the incident header; the list's anomaly
	// footnote cites the detail tool by its real name.
	testing.expect(t, harness_apply(t, &h, 4_000_000_000, "incident.status_changed",
		"{\"target\":\"INC-002\",\"from\":\"reported\",\"to\":\"fixing\",\"resolution\":\"\",\"evidence_md\":\"\"}"))
	out, _ = tracker.render_incident_list(&h.state, &tracker.Incident_Filter{}, NOW_MS_FOR_TEST, context.temp_allocator)
	testing.expect(t, strings.contains(out, "1 anomaly (run incident_get for details)"), out)
}

@(private)
count_byte :: proc(s: string, b: u8) -> int {
	n := 0
	for i in 0..<len(s) {
		if s[i] == b {
			n += 1
		}
	}
	return n
}

@(test)
tracker_render_list_hard_caps :: proc(t: ^testing.T) {
	h: Fold_Harness
	harness_init(&h)
	defer harness_destroy(&h)

	// 501 live incidents: an unlimited request must stop at the hard row
	// ceiling and say so, not render every row.
	payload := "{\"title\":\"bulk fill\",\"priority\":\"low\"}"
	for i in 0..<501 {
		ns := i64(i + 1) * 1_000_000
		testing.expectf(t, harness_apply(t, &h, ns, "incident.created", payload),
			"bulk create %d failed", i)
	}
	now := i64(2_000_000_000)

	f := tracker.Incident_Filter{limit = -1}
	out, err := tracker.render_incident_list(&h.state, &f, now, context.temp_allocator)
	testing.expectf(t, err == nil, "list err: %v", err)
	testing.expect(t, strings.has_prefix(out, "501 incidents: "), out[:min(40, len(out))])
	testing.expect(t, strings.contains(out, "501 reported"), out[:60])
	// Header line + 500 rows + cap tail = 501 newlines.
	testing.expectf(t, count_byte(out, '\n') == 501, "newline count %d", count_byte(out, '\n'))
	testing.expect(t, strings.contains(out, "…and 1 more (list cap of 500 rows reached"), out[len(out)-120:])
	testing.expect(t, strings.contains(out, "full export: aubade tracker report)"), out[len(out)-80:])

	// A caller limit below the ceiling keeps the old contract tail.
	f = tracker.Incident_Filter{limit = 10}
	out, _ = tracker.render_incident_list(&h.state, &f, now, context.temp_allocator)
	testing.expectf(t, count_byte(out, '\n') == 11, "limit newline count %d", count_byte(out, '\n'))
	testing.expect(t, strings.has_suffix(out, "\n…and 491 more (raise limit or filter)"), out[len(out)-60:])

	// Wide (multi-byte) titles trip the byte budget before either the row
	// ceiling or the full count: 400 incidents, 80-rune titles ≈ 270 bytes
	// a row — the size cap fires first and names itself.
	wide, werr := strings.repeat("監査テスト", 16, context.allocator) // 5 runes × 16 = 80
	testing.expectf(t, werr == nil, "repeat err: %v", werr)
	defer delete(wide)
	wide_payload := strings.concatenate(
		{"{\"title\":\"", wide, "\",\"priority\":\"low\"}"},
		context.allocator,
	)
	defer delete(wide_payload)
	h2: Fold_Harness
	harness_init(&h2)
	defer harness_destroy(&h2)
	for i in 0..<400 {
		ns := i64(i + 1) * 1_000_000
		testing.expectf(t, harness_apply(t, &h2, ns, "incident.created", wide_payload),
			"wide create %d failed", i)
	}
	f = tracker.Incident_Filter{limit = -1}
	out, err = tracker.render_incident_list(&h2.state, &f, now, context.temp_allocator)
	testing.expectf(t, err == nil, "wide list err: %v", err)
	rows := count_byte(out, '\n') - 1 // minus the tail line
	testing.expectf(t, rows > 0 && rows < 400, "wide rows %d", rows)
	testing.expect(t, strings.contains(out, "(list size cap reached"), out[len(out)-120:])
	testing.expect(t, !strings.contains(out, "list cap of 500 rows"), out[len(out)-120:])
}

@(test)
tracker_detail_views :: proc(t: ^testing.T) {
	h: Fold_Harness
	harness_init(&h)
	defer harness_destroy(&h)

	// Sprint with a full incident lifecycle: low → urgent drift, verify,
	// root cause, resolve with evidence, notes; goal replaced mid-sprint.
	testing.expect(t, harness_apply(t, &h, 1_000_000_000, "sprint.started",
		"{\"name\":\"round 1\",\"goal_md\":\"ship it\",\"must\":[\"T1\"]}"))
	testing.expect(t, harness_apply(t, &h, 2_000_000_000, "incident.created",
		"{\"title\":\"disk full\",\"priority\":\"low\",\"labels\":[\"ops\"],\"sprint\":\"SPR-001\",\"created_by\":\"lee\",\"body_md\":\"startup race\"}"))
	testing.expect(t, harness_apply(t, &h, 3_000_000_000, "incident.fields_changed",
		"{\"target\":\"INC-001\",\"priority\":\"urgent\"}"))
	testing.expect(t, harness_apply(t, &h, 4_000_000_000, "incident.verified",
		"{\"target\":\"INC-001\",\"verdict\":\"confirmed\",\"reason_md\":\"real race\",\"evidence_md\":\"logs:12\"}"))
	testing.expect(t, harness_apply(t, &h, 5_000_000_000, "incident.root_caused",
		"{\"target\":\"INC-001\",\"cause_md\":\"unbounded retry\"}"))
	testing.expect(t, harness_apply(t, &h, 7_000_000_000, "incident.note_appended",
		"{\"target\":\"INC-001\",\"body_md\":\"re-ran the suite\"}"))
	testing.expect(t, harness_apply(t, &h, 8_000_000_000, "incident.status_changed",
		"{\"target\":\"INC-001\",\"from\":\"root_caused\",\"to\":\"resolved\",\"resolution\":\"fixed\",\"evidence_md\":\"commit abc123 + suite\"}"))
	testing.expect(t, harness_apply(t, &h, 8_500_000_000, "sprint.task_verified",
		"{\"target\":\"SPR-001\",\"task\":\"T1\",\"definition\":\"just test\",\"outcome\":\"passed\",\"output\":\"603 tests green\",\"session\":\"sess-1\"}"))
	testing.expect(t, harness_apply(t, &h, 9_000_000_000, "sprint.goal_updated",
		"{\"target\":\"SPR-001\",\"goal_md\":\"ship it harder\"}"))
	testing.expect(t, harness_apply(t, &h, 10_000_000_000, "sprint.note_appended",
		"{\"target\":\"SPR-001\",\"body_md\":\"wave 2 lands next\",\"defer_id\":\"DEF-001\",\"defer_type\":\"question\",\"task\":\"T1\"}"))
	testing.expect(t, harness_apply(t, &h, 10_500_000_000, "sprint.note_appended",
		"{\"target\":\"SPR-001\",\"body_md\":\"keep the daemon\",\"resolves\":\"DEF-001\"}"))
	testing.expect(t, harness_apply(t, &h, 11_000_000_000, "sprint.closed",
		"{\"outcome_md\":\"1/1 resolved\"}"))

	inc := hdr_field(&h, "INC-001")
	testing.expect(t, inc != nil)
	user := cast(rawptr)(&h.rows)
	det := tracker.detail_incident(&h.state, inc, test_fetch, user, 0, context.temp_allocator)
	testing.expect(t, strings.contains(det, "INC-001 [urgent] RESOLVED (fixed) — disk full"), det)
	testing.expect(t, strings.contains(det, "verified: confirmed 1970-01-01"), det)
	testing.expect(t, strings.contains(det, "priority: low (1970-01-01) → urgent (1970-01-01)"), det)
	testing.expect(t, strings.contains(det, "startup race"), det)
	testing.expect(t, strings.contains(det, "verified: confirmed"), det)
	testing.expect(t, strings.contains(det, "resolved: fixed\nevidence: commit abc123 + suite"), det)
	testing.expect(t, strings.contains(det, "re-ran the suite"), det)

	spr := tracker.sprint_by_id(&h.state, "SPR-001")
	testing.expect(t, spr != nil)
	sdet := tracker.detail_sprint(&h.state, spr, test_fetch, user, 0, context.temp_allocator)
	testing.expect(t, strings.contains(sdet, "SPR-001 'round 1' closed"), sdet)
	testing.expect(t, strings.contains(sdet, "1 resolved"), sdet)
	testing.expect(t, strings.contains(sdet, "goal:\nship it harder"), sdet)
	// The must-task block carries the derived verification state with the
	// definition and the output digest.
	testing.expect(t, strings.contains(sdet, "must tasks:\n- T1: passed (just test, 1970-01-01)"), sdet)
	testing.expect(t, strings.contains(sdet, "output: 603 tests green"), sdet)
	testing.expect(t, strings.contains(sdet, "wave 2 lands next"), sdet)
	// Typed notes render with their defer identity; the roll-up carries
	// the answered state.
	testing.expect(t, strings.contains(sdet, "— defer question DEF-001 (task T1)"), sdet)
	testing.expect(t, strings.contains(sdet, "— answers DEF-001"), sdet)
	testing.expect(t, strings.contains(sdet, "defers:\n- DEF-001 question (task T1): wave 2 lands next [answered 1970-01-01 by note]"), sdet)
	testing.expect(t, strings.contains(sdet, "outcome:\n1/1 resolved"), sdet)

	// max_chars caps the detail view.
	short := tracker.detail_incident(&h.state, inc, test_fetch, user, 10, context.temp_allocator)
	testing.expect(t, len(short) > 0)
	testing.expect(t, strings.contains(short, "…truncated ("), short)

	// The sprint list shows the closed sprint with its filed-cohort stats.
	list := tracker.sprint_list(&h.state, test_fetch, user, true, 0, NOW_MS_FOR_TEST, context.temp_allocator)
	testing.expect(t, strings.contains(list, "SPR-001 'round 1' closed 1970-01-01: filed 1, 1 resolved"), list)
}

@(test)
tracker_defers_and_verifications :: proc(t: ^testing.T) {
	h: Fold_Harness
	harness_init(&h)
	defer harness_destroy(&h)

	// A round with three must tasks; T1 verifies, T2 fails its latest
	// re-run (latest-wins un-verifies), T3 stays untouched.
	testing.expect(t, harness_apply(t, &h, 1_000_000_000, "sprint.started",
		"{\"name\":\"round 1\",\"goal_md\":\"ship\",\"must\":[\"T1\",\"T2\",\"T3\"]}"))
	spr := tracker.sprint_by_id(&h.state, "SPR-001")
	testing.expect(t, spr != nil)
	if spr == nil {
		return
	}
	testing.expect_value(t, len(spr.must), 3)
	testing.expect(t, harness_apply(t, &h, 2_000_000_000, "sprint.task_verified",
		"{\"target\":\"SPR-001\",\"task\":\"T1\",\"definition\":\"just test\",\"outcome\":\"passed\",\"output\":\"603 green\",\"session\":\"s1\"}"))
	testing.expect(t, harness_apply(t, &h, 3_000_000_000, "sprint.task_verified",
		"{\"target\":\"SPR-001\",\"task\":\"T2\",\"definition\":\"just check\",\"outcome\":\"passed\",\"output\":\"ok\"}"))
	testing.expect(t, harness_apply(t, &h, 4_000_000_000, "sprint.task_verified",
		"{\"target\":\"SPR-001\",\"task\":\"T2\",\"definition\":\"just check\",\"outcome\":\"failed\",\"output\":\"1 flake\"}"))
	v2 := tracker.task_latest_verif(spr, "T2")
	testing.expect(t, v2 != nil)
	if v2 != nil {
		testing.expect(t, v2.outcome == "failed")
	}
	passed, total := tracker.must_verif_summary(spr)
	testing.expect_value(t, passed, 1)
	testing.expect_value(t, total, 3)

	// Foreign violations are absorbed: unknown outcome vocabulary and a
	// record missing its output still land (flagged), a blocked defer
	// without ref registers but flags.
	testing.expect(t, harness_apply(t, &h, 5_000_000_000, "sprint.task_verified",
		"{\"target\":\"SPR-001\",\"task\":\"T1\",\"definition\":\"just test\",\"outcome\":\"meh\",\"output\":\"x\"}"))
	testing.expect(t, harness_apply(t, &h, 6_000_000_000, "sprint.task_verified",
		"{\"target\":\"SPR-001\",\"task\":\"T1\",\"definition\":\"just test\",\"outcome\":\"passed\"}"))
	testing.expect(t, harness_apply(t, &h, 7_000_000_000, "sprint.note_appended",
		"{\"target\":\"SPR-001\",\"body_md\":\"infra down\",\"defer_id\":\"DEF-001\",\"defer_type\":\"blocked\",\"task\":\"T3\"}"))
	testing.expect(t, len(h.state.anomalies) >= 3)
	blocked := tracker.defer_by_id(&h.state, "DEF-001")
	testing.expect(t, blocked != nil)

	// Coverage: T1 latest is the output-less record (flagged, still the
	// latest — outcome passed), T2 failed, T3 blocked-deferred.
	unc := tracker.unverified_must_tasks(&h.state, spr, context.temp_allocator)
	testing.expect_value(t, len(unc), 1)
	if len(unc) == 1 {
		testing.expect(t, unc[0] == "T2")
	}
	for task in unc {
		delete(task, context.temp_allocator)
	}
	delete(unc)

	// A question defer covers T2 while open; answering it un-covers
	// (the answer demands a verification or a fresh defer).
	testing.expect(t, harness_apply(t, &h, 8_000_000_000, "sprint.note_appended",
		"{\"target\":\"SPR-001\",\"body_md\":\"flake or real failure?\",\"defer_id\":\"DEF-002\",\"defer_type\":\"question\",\"task\":\"T2\"}"))
	testing.expect(t, tracker.sprint_task_defer(&h.state, spr, "T2") == "DEF-002")
	unc = tracker.unverified_must_tasks(&h.state, spr, context.temp_allocator)
	testing.expect_value(t, len(unc), 0)
	for task in unc {
		delete(task, context.temp_allocator)
	}
	delete(unc)
	testing.expect(t, harness_apply(t, &h, 9_000_000_000, "sprint.note_appended",
		"{\"target\":\"SPR-001\",\"body_md\":\"real failure: rerun\",\"resolves\":\"DEF-002\"}"))
	testing.expect(t, tracker.sprint_task_defer(&h.state, spr, "T2") == "")
	unc = tracker.unverified_must_tasks(&h.state, spr, context.temp_allocator)
	testing.expect_value(t, len(unc), 1)
	for task in unc {
		delete(task, context.temp_allocator)
	}
	delete(unc)

	// Resolving a non-question or already-resolved defer is an anomaly.
	testing.expect(t, harness_apply(t, &h, 9_500_000_000, "sprint.note_appended",
		"{\"target\":\"SPR-001\",\"body_md\":\"again\",\"resolves\":\"DEF-001\"}"))
	pre := len(h.state.anomalies)
	testing.expect(t, pre > 0)

	// The must list is a whole-value replacement.
	testing.expect(t, harness_apply(t, &h, 10_000_000_000, "sprint.goal_updated",
		"{\"target\":\"SPR-001\",\"must\":[\"T1\"]}"))
	testing.expect_value(t, len(spr.must), 1)
	unc = tracker.unverified_must_tasks(&h.state, spr, context.temp_allocator)
	testing.expect_value(t, len(unc), 0)
	delete(unc)

	// An orphan question outlives its round: closed here, still open, and
	// answerable from the next round.
	testing.expect(t, harness_apply(t, &h, 11_000_000_000, "sprint.note_appended",
		"{\"target\":\"SPR-001\",\"body_md\":\"what about Windows?\",\"defer_id\":\"DEF-003\",\"defer_type\":\"question\"}"))
	testing.expect(t, harness_apply(t, &h, 12_000_000_000, "sprint.closed", "{\"outcome_md\":\"done\"}"))
	qs := tracker.open_questions(&h.state, context.temp_allocator)
	testing.expect_value(t, len(qs), 1)
	if len(qs) == 1 {
		testing.expect(t, qs[0].id == "DEF-003" && qs[0].sprint == "SPR-001")
	}
	delete(qs, context.temp_allocator)
	dt, dq := tracker.sprint_defer_stats(&h.state, spr)
	testing.expect_value(t, dt, 3)
	testing.expect_value(t, dq, 1)

	testing.expect(t, harness_apply(t, &h, 13_000_000_000, "sprint.started",
		"{\"name\":\"round 2\"}"))
	spr2 := tracker.sprint_by_id(&h.state, "SPR-002")
	testing.expect(t, spr2 != nil)
	// A verification on the closed round is an anomaly; on the active
	// round it lands.
	testing.expect(t, harness_apply(t, &h, 14_000_000_000, "sprint.task_verified",
		"{\"target\":\"SPR-001\",\"task\":\"T1\",\"definition\":\"just test\",\"outcome\":\"passed\",\"output\":\"x\"}"))
	testing.expect(t, harness_apply(t, &h, 15_000_000_000, "sprint.task_verified",
		"{\"target\":\"SPR-002\",\"task\":\"T9\",\"definition\":\"just check\",\"outcome\":\"passed\",\"output\":\"y\"}"))
	testing.expect(t, tracker.task_latest_verif(spr2, "T9") != nil)
	// The cross-round answer closes the still-open question.
	testing.expect(t, harness_apply(t, &h, 16_000_000_000, "sprint.note_appended",
		"{\"target\":\"SPR-002\",\"body_md\":\"MSVC runners cover it\",\"resolves\":\"DEF-003\"}"))
	qs = tracker.open_questions(&h.state, context.temp_allocator)
	testing.expect_value(t, len(qs), 0)
	delete(qs, context.temp_allocator)
	answered := tracker.defer_by_id(&h.state, "DEF-003")
	testing.expect(t, answered != nil && answered.resolved_ms != 0)
}

@(test)
tracker_resume_summary :: proc(t: ^testing.T) {
	h: Fold_Harness
	harness_init(&h)
	defer harness_destroy(&h)

	// Nothing open, no round activity: the summary stays empty.
	testing.expect(t, tracker.render_open_summary(&h.state, NOW_MS_FOR_TEST, context.temp_allocator) == "")

	testing.expect(t, harness_apply(t, &h, 1_000_000_000, "sprint.started",
		"{\"name\":\"auth round\",\"goal_md\":\"fix auth\",\"must\":[\"T1\",\"T2\",\"T3\",\"T4\"]}"))
	testing.expect(t, harness_apply(t, &h, 2_000_000_000, "sprint.task_verified",
		"{\"target\":\"SPR-001\",\"task\":\"T1\",\"definition\":\"just test\",\"outcome\":\"passed\",\"output\":\"green\"}"))
	testing.expect(t, harness_apply(t, &h, 3_000_000_000, "sprint.task_verified",
		"{\"target\":\"SPR-001\",\"task\":\"T2\",\"definition\":\"just check\",\"outcome\":\"failed\",\"output\":\"flake\"}"))
	testing.expect(t, harness_apply(t, &h, 4_000_000_000, "sprint.note_appended",
		"{\"target\":\"SPR-001\",\"body_md\":\"drop the cache layer?\",\"defer_id\":\"DEF-001\",\"defer_type\":\"question\",\"task\":\"T3\"}"))
	testing.expect(t, harness_apply(t, &h, 5_000_000_000, "incident.created",
		"{\"title\":\"disk full\",\"priority\":\"urgent\",\"body_md\":\"claim\"}"))
	testing.expect(t, harness_apply(t, &h, 6_000_000_000, "incident.created",
		"{\"title\":\"hang\",\"priority\":\"low\",\"body_md\":\"claim\"}"))

	summary := tracker.render_open_summary(&h.state, NOW_MS_FOR_TEST, context.temp_allocator)
	// The pending question leads — the human intervention point.
	testing.expect(t, strings.has_prefix(summary, "Pending questions ("), summary)
	testing.expect(t, strings.contains(summary, "- DEF-001 [SPR-001] drop the cache layer?"), summary)
	// The round line: derived must-task states with definitions available
	// where a record exists.
	testing.expect(t, strings.contains(summary, "Round SPR-001 'auth round' — must: 1/4 verified"), summary)
	testing.expect(t, strings.contains(summary, "unverified: T4"), summary)
	testing.expect(t, strings.contains(summary, "deferred: T3"), summary)
	testing.expect(t, strings.contains(summary, "failed: T2"), summary)
	testing.expect(t, strings.contains(summary, "defers: 1 filed (1 open questions)"), summary)
	// The open-problem line closes the summary.
	testing.expect(t, strings.contains(summary, "Tracker: 2 open (1 urgent, 2 unverified"), summary)
	testing.expect(t, strings.has_suffix(summary, " — see incident_list / sprint_list"), summary)

	// A round without must tasks or defers renders the plain tracker line.
	testing.expect(t, harness_apply(t, &h, 7_000_000_000, "sprint.note_appended",
		"{\"target\":\"SPR-001\",\"body_md\":\"answered: keep it\",\"resolves\":\"DEF-001\"}"))
	testing.expect(t, harness_apply(t, &h, 8_000_000_000, "sprint.goal_updated",
		"{\"target\":\"SPR-001\",\"must\":[\"T1\"]}"))
	summary = tracker.render_open_summary(&h.state, NOW_MS_FOR_TEST, context.temp_allocator)
	testing.expect(t, !strings.contains(summary, "Pending questions"), summary)
	testing.expect(t, strings.contains(summary, "must: 1/1 verified"), summary)
	testing.expect(t, strings.contains(summary, "Tracker: 2 open ("), summary)
}

@(test)
tracker_report_json_quote_encodes_control_bytes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// The export renders string fields through jsonutil.json_quote — the
	// one JSON string escaper — which also carries the quotes.
	testing.expect_value(t, jsonutil.json_quote("plain title", a), "\"plain title\"")

	// Mandatory escapes survive.
	testing.expect_value(t, jsonutil.json_quote("a\"b\\c", a), "\"a\\\"b\\\\c\"")

	// C0 controls (which validate_title admits — it rejects only \n\r)
	// must not pass through raw: a raw control byte makes the exported
	// report invalid JSON. Named controls keep their short forms.
	testing.expect_value(t, jsonutil.json_quote("fix\x1b[0m", a), "\"fix\\u001b[0m\"")
	testing.expect_value(t, jsonutil.json_quote("nl\nnl", a), "\"nl\\nnl\"")
	testing.expect_value(t, jsonutil.json_quote("x\x00y", a), "\"x\\u0000y\"")

	// DEL (0x7f) is outside JSON's mandatory escape set and passes raw.
	testing.expect_value(t, jsonutil.json_quote("del\x7f", a), "\"del\x7f\"")
}
