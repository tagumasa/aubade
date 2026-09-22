// Tests for src/tracker/manager: the SQLite-backed write/read surface.
// One temp DB, one fixed wall-ns source (uids deterministic, 10ms apart),
// and explicit frees of everything the manager returns — the results must
// be owned by the request allocator, nothing borrowed may escape. The
// re-init half verifies persistence: the fold rebuilds from the events
// table, INC numbering continues, and the uid watermark orders new events
// strictly after the stored stream even when the clock reads earlier.
package tests

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "src:jsonutil"
import "src:platform"
import "src:store"
import "src:tracker"

@(private)
manager_now_ns_val: i64

@(private)
manager_now_ns :: proc() -> i64 {
	manager_now_ns_val += 10_000_000
	return manager_now_ns_val
}

@(test)
tracker_manager_lifecycle :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-tracker-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp dir: %v", derr)
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir, context.allocator)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path, context.allocator)
	db, oerr := store.db_open(db_path, context.allocator)
	if oerr != nil {
		testing.expectf(t, false, "open: %v", oerr)
		return
	}
	defer store.db_close(db)

	// The per-call allocator mirrors the daemon's request arena: results
	// and intermediate encodings ride it and are freed wholesale; anything
	// escaping to the ambient allocator surfaces as a leak here.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	ra := mem.dynamic_arena_allocator(&arena)

	manager_now_ns_val = 1_000_000_000
	m := new(tracker.Manager, context.allocator)
	ierr := tracker.manager_init(m, db, manager_now_ns, 0xaabbccdd, 0x1234_5678_9abc_def0, true, context.allocator)
	if ierr != nil {
		testing.expectf(t, false, "init: %v", ierr)
		return
	}
	// Destroy before the struct free (defers run LIFO, so destroy is
	// registered last): the manager owns events, maps, and header
	// clones, and the many expectf early returns below must not leak
	// them under the tracking allocator.
	defer free(m, context.allocator)
	defer tracker.manager_destroy(m)

	// Create: title trims, defaults fill in.
	input := tracker.Create_Input{
		title   = "  disk full ",
		body_md = "claim text",
		priority = "urgent",
		labels  = []string{"storage"},
	}
	cr, cerr := tracker.manager_create(m, &input, ra)
	if cerr != nil {
		testing.expectf(t, false, "create: %v", cerr)
		return
	}
	testing.expect(t, cr.id == "INC-001")
	testing.expect(t, cr.title == "disk full")
	testing.expect(t, cr.priority == "urgent")

	// Verify confirmed.
	vr, verr := tracker.manager_verify(m, "INC-001", "confirmed", "", "why", "evidence", ra)
	if verr != nil {
		testing.expectf(t, false, "verify: %v", verr)
		return
	}
	testing.expect(t, vr.id == "INC-001")
	testing.expect(t, vr.verdict == "confirmed")
	testing.expect(t, vr.status == "confirmed")

	// Composite update in the fixed order: fields, root cause, note.
	fu := tracker.Fields_Update{
		priority      = "high",
		priority_set  = true,
		assignee      = "alice",
		assignee_set  = true,
	}
	up := tracker.Update_Input{
		fields        = fu,
		fields_set    = true,
		root_cause    = "retry storm",
		root_cause_set = true,
		note          = "note one",
		note_set      = true,
	}
	changed, _, uerr := tracker.manager_update_incident(m, "INC-001", &up, ra)
	if uerr != nil {
		testing.expectf(t, false, "update: %v", uerr)
		return
	}
	testing.expect_value(t, len(changed), 3)
	testing.expect(t, changed[0] == "root cause" && changed[1] == "fields" && changed[2] == "note")

	// Resolving from root_caused; the old detour through execution states
	// is gone — a direct resolve from confirmed would be refused.
	sc3 := tracker.Status_Change{to = "resolved", resolution = "fixed", evidence_md = "commit deadbee"}
	up3 := tracker.Update_Input{status = sc3, status_set = true}
	changed3, _, e3 := tracker.manager_update_incident(m, "INC-001", &up3, ra)
	testing.expectf(t, e3 == nil, "resolved: %v", e3)
	testing.expect_value(t, len(changed3), 1)

	// Sprint: start with must tasks, file a member, verify one task, close
	// is refused while T2 is uncovered, a defer covers it, close passes.
	spr, serr := tracker.manager_start_sprint(m, "round 1", "ship the tracker", "", []string{"T1", "T2"}, ra)
	if serr != nil {
		testing.expectf(t, false, "start sprint: %v", serr)
		return
	}
	testing.expect(t, spr.id == "SPR-001")

	// A rejected multi-section sprint_update commits nothing: the goal
	// replacement must not survive a note section that fails validation
	// (atomically-or-none).
	su_bad := tracker.Sprint_Update{goal = "REPLACED GOAL", goal_set = true, note_set = true}
	if _, _, bad_err := tracker.manager_update_sprint(m, "SPR-001", &su_bad, ra); bad_err == nil {
		testing.expectf(t, false, "empty note must be refused")
		return
	}
	gtext, ggerr := tracker.manager_get_sprint(m, "SPR-001", 0, ra)
	testing.expectf(t, ggerr == nil, "get sprint: %v", ggerr)
	testing.expect(t, !strings.contains(gtext, "REPLACED GOAL"), "goal must not commit on a rejected update")
	input2 := tracker.Create_Input{title = "hang", body_md = "claim two", sprint = "SPR-001"}
	cr2, cerr2 := tracker.manager_create(m, &input2, ra)
	if cerr2 != nil {
		testing.expectf(t, false, "create2: %v", cerr2)
		return
	}
	testing.expect(t, cr2.id == "INC-002")

	// Status-transition refusals cite the tools by the names this binary
	// actually serves.
	sc_res := tracker.Status_Change{to = "resolved"}
	up_res := tracker.Update_Input{status = sc_res, status_set = true}
	if _, _, rerr := tracker.manager_update_incident(m, "INC-002", &up_res, ra); rerr != nil {
		msg := platform.err_message(rerr, ra)
		testing.expectf(t, strings.contains(msg, "use incident_verify first"), "unverified resolve cites incident_verify: %s", msg)
	} else {
		testing.expectf(t, false, "reported→resolved must refuse")
	}
	sc_rej := tracker.Status_Change{to = "rejected"}
	up_rej := tracker.Update_Input{status = sc_rej, status_set = true}
	if _, _, rerr2 := tracker.manager_update_incident(m, "INC-002", &up_rej, ra); rerr2 != nil {
		msg2 := platform.err_message(rerr2, ra)
		testing.expectf(t, strings.contains(msg2, "use incident_verify with verdict=rejected"), "direct rejected cites incident_verify: %s", msg2)
	} else {
		testing.expectf(t, false, "direct rejected must refuse")
	}

	vr2, vr2err := tracker.manager_record_verification(m, "T1", "just test", "passed", "603 green", "sess-1", ra)
	testing.expectf(t, vr2err == nil, "record verif: %v", vr2err)
	if vr2err == nil {
		testing.expect(t, vr2.sprint_id == "SPR-001" && vr2.task == "T1" && vr2.outcome == "passed")
	}
	// Refusal-style gates: no output, no definition, bad outcome.
	_, gerr := tracker.manager_record_verification(m, "T2", "just test", "passed", "", "", ra)
	testing.expect(t, gerr != nil)
	_, gerr = tracker.manager_record_verification(m, "T2", "", "passed", "out", "", ra)
	testing.expect(t, gerr != nil)
	_, gerr = tracker.manager_record_verification(m, "T2", "just test", "meh", "out", "", ra)
	testing.expect(t, gerr != nil)

	// Close refuses on the uncovered must task.
	_, cl_ref := tracker.manager_close_sprint(m, "shipped", ra)
	testing.expect(t, cl_ref != nil)
	if cl_ref != nil {
		msg := platform.err_message(cl_ref, ra)
		testing.expectf(t, strings.contains(msg, "T2"), "close refusal names the task: %s", msg)
		testing.expectf(t, strings.contains(msg, "sprint_record_verification"), "close refusal points at the tools: %s", msg)
	}

	// A typed defer covers T2 — blocked demands its ref.
	su := tracker.Sprint_Update{
		note       = "blocked on the upstream API",
		note_set   = true,
		defer_type = "blocked",
		defer_task = "T2",
	}
	_, _, suerr := tracker.manager_update_sprint(m, "SPR-001", &su, ra)
	testing.expect(t, suerr != nil) // blocked requires ref
	su.defer_ref = "INC-002"
	_, _, suerr = tracker.manager_update_sprint(m, "SPR-001", &su, ra)
	testing.expectf(t, suerr == nil, "defer note: %v", suerr)
	def := tracker.defer_by_id(&m.state, "DEF-001")
	testing.expect(t, def != nil && def.kind == "blocked" && def.task == "T2" && def.ref == "INC-002")

	cl, clerr := tracker.manager_close_sprint(m, "shipped", ra)
	if clerr != nil {
		testing.expectf(t, false, "close sprint: %v", clerr)
		return
	}
	testing.expect(t, cl.id == "SPR-001")
	// The close-ack shape: the cohort line counts the findings filed
	// inside the sprint window — the in-window one only; the first
	// finding predates the sprint. No membership sweep, no moved line;
	// rejected is gated on non-zero. The must and defer lines carry the
	// round's work state.
	testing.expectf(t, strings.contains(cl.stats_text, "filed 1"), "stats_text: %s", cl.stats_text)
	testing.expectf(t, strings.contains(cl.stats_text, "unjudged 1"), "stats_text: %s", cl.stats_text)
	testing.expectf(t, !strings.contains(cl.stats_text, "moved"), "no sweep, no moved line: %s", cl.stats_text)
	testing.expectf(t, !strings.contains(cl.stats_text, "rejected"), "rejected gated on non-zero: %s", cl.stats_text)
	testing.expectf(t, strings.contains(cl.stats_text, "must: 1/2 verified"), "stats_text: %s", cl.stats_text)
	testing.expectf(t, strings.contains(cl.stats_text, "defers: 1 filed (0 open questions)"), "stats_text: %s", cl.stats_text)
	// The close stores the rendered report row best-effort.
	stored, sfound, _ := store.sprint_report_get(db, "SPR-001", ra)
	testing.expect(t, sfound, "close must store the sprint report row")
	if sfound {
		testing.expect(t, strings.contains(stored, "SPR-001"))
		testing.expect(t, strings.contains(stored, "must tasks:"))
		testing.expect(t, strings.contains(stored, "defers:"))
	}

	// Counts across the whole tracker.
	counts := tracker.manager_counts(m)
	testing.expect_value(t, counts.total, 2)
	testing.expect_value(t, counts.resolved, 1)
	testing.expect_value(t, counts.reported, 1)

	cnt, _ := store.events_count(db)
	testing.expect(t, cnt >= 11) // created+verified+3+resolved+sprint+created+verif+defer+closed (refusals write nothing)

	// Detail view carries the timeline.
	det, gterr := tracker.manager_get_incident(m, "INC-001", 0, ra)
	testing.expectf(t, gterr == nil, "get: %v", gterr)
	testing.expect(t, strings.contains(det, "INC-001"), det[:min(80, len(det))])
	testing.expect(t, strings.contains(det, "resolved: fixed"))

	// Export refreshes every stored report row (upsert — one row per
	// sprint id); the single-sprint form rewrites the same row.
	ack, xerr := tracker.manager_export(m, "", ra)
	if xerr != nil {
		testing.expectf(t, false, "export: %v", xerr)
		return
	}
	testing.expect(t, strings.contains(ack, "1 sprint reports to the tracker store"), ack)
	refreshed, rfound, _ := store.sprint_report_get(db, "SPR-001", ra)
	testing.expect(t, rfound && strings.contains(refreshed, "SPR-001"))
	ack1, xerr1 := tracker.manager_export(m, "SPR-001", ra)
	if xerr1 != nil {
		testing.expectf(t, false, "export single: %v", xerr1)
		return
	}
	testing.expect(t, strings.contains(ack1, "Exported SPR-001 report to the tracker store"), ack1)
	again, afound, _ := store.sprint_report_get(db, "SPR-001", ra)
	testing.expect(t, afound, "re-export must keep the row present (upsert)")
	testing.expect(t, strings.contains(again, "SPR-001"))

	// Persistence: destroy (writes the fold snapshot), rewind the clock
	// below the stream, re-init — the restore + tail-replay path.
	tracker.manager_destroy(m)
	manager_now_ns_val = 0
	ierr2 := tracker.manager_init(m, db, manager_now_ns, 0xaabbccdd, 1, true, context.allocator)
	if ierr2 != nil {
		testing.expectf(t, false, "re-init: %v", ierr2)
		return
	}
	testing.expect(t, m.is_snapshot_restored, "re-init should restore the fold snapshot")
	counts2 := tracker.manager_counts(m)
	testing.expect_value(t, counts2.total, 2)
	input3 := tracker.Create_Input{title = "third issue", body_md = "claim three"}
	cr3, cerr3 := tracker.manager_create(m, &input3, ra)
	if cerr3 != nil {
		testing.expectf(t, false, "create3: %v", cerr3)
		return
	}
	testing.expect(t, cr3.id == "INC-003") // numbering continues across restarts
	cnt2, _ := store.events_count(db)
	testing.expect_value(t, cnt2, cnt+1)

	tracker.manager_destroy(m)
}

@(test)
tracker_report_line_ending_folds_pairs :: proc(t: ^testing.T) {
	// The write boundary must treat an embedded \r\n pair as ONE logical
	// newline: user-authored note/goal/outcome bodies reach the composed
	// report verbatim through the detail views, and under a CRLF
	// convention a pair stays a single \r\n — never \r\r\n. A lone \r is
	// content and survives.
	composed := "header\npair\r\nlone-cr\rfinis\n"
	out := tracker.report_apply_line_ending(composed, "\r\n", context.temp_allocator)
	testing.expect(t, out == "header\r\npair\r\nlone-cr\rfinis\r\n", out)

	// LF and empty conventions are a no-op.
	testing.expect(t, tracker.report_apply_line_ending(composed, "\n", context.temp_allocator) == composed)
	testing.expect(t, tracker.report_apply_line_ending(composed, "", context.temp_allocator) == composed)
}


// ---------------------------------------------------------------------------
// Fold snapshots: destroy persists the checkpoint; re-init restores it and
// replays only the tail. Every test asserts the restore path against a
// full refold of the same stream — the two must render byte-identically.

@(private)
snapshot_renders :: proc(m: ^tracker.Manager, a: mem.Allocator) -> (string, string, platform.Err) {
	now: i64 = 1_700_000_000_000
	f: tracker.Incident_Filter
	tsv, terr := tracker.manager_render_incident_report(m, &f, .TSV, a)
	if terr != nil {
		return "", "", terr
	}
	return tsv, tracker.manager_open_summary(m, now, a), nil
}

@(private)
snapshot_seed_events :: proc(t: ^testing.T, m: ^tracker.Manager, ra: mem.Allocator) -> bool {
	input := tracker.Create_Input{
		title    = "disk full",
		body_md  = "claim text",
		priority = "urgent",
		labels   = []string{"storage"},
	}
	cr, cerr := tracker.manager_create(m, &input, ra)
	if cerr != nil {
		testing.expectf(t, false, "create: %v", cerr)
		return false
	}
	testing.expect(t, cr.id == "INC-001")
	if _, verr := tracker.manager_verify(m, "INC-001", "confirmed", "", "why", "evidence", ra); verr != nil {
		testing.expectf(t, false, "verify: %v", verr)
		return false
	}
	fu := tracker.Fields_Update{priority = "high", priority_set = true, assignee = "alice", assignee_set = true}
	up := tracker.Update_Input{fields = fu, fields_set = true, root_cause = "retry storm", root_cause_set = true, note = "note one", note_set = true}
	if _, _, uerr := tracker.manager_update_incident(m, "INC-001", &up, ra); uerr != nil {
		testing.expectf(t, false, "update: %v", uerr)
		return false
	}
	sc := tracker.Status_Change{to = "resolved", resolution = "fixed", evidence_md = "commit deadbee"}
	up3 := tracker.Update_Input{status = sc, status_set = true}
	if _, _, e3 := tracker.manager_update_incident(m, "INC-001", &up3, ra); e3 != nil {
		testing.expectf(t, false, "resolved: %v", e3)
		return false
	}
	spr, serr := tracker.manager_start_sprint(m, "round 1", "ship the tracker", "", []string{"T1", "T2"}, ra)
	if serr != nil {
		testing.expectf(t, false, "start sprint: %v", serr)
		return false
	}
	testing.expect(t, spr.id == "SPR-001")
	input2 := tracker.Create_Input{title = "hang", body_md = "claim two", sprint = "SPR-001"}
	cr2, cerr2 := tracker.manager_create(m, &input2, ra)
	if cerr2 != nil {
		testing.expectf(t, false, "create2: %v", cerr2)
		return false
	}
	testing.expect(t, cr2.id == "INC-002")
	if _, verr2 := tracker.manager_record_verification(m, "T1", "just test", "passed", "603 green", "sess-1", ra); verr2 != nil {
		testing.expectf(t, false, "record verif: %v", verr2)
		return false
	}
	su := tracker.Sprint_Update{
		note       = "blocked on the upstream API",
		note_set   = true,
		defer_type = "blocked",
		defer_task = "T2",
		defer_ref  = "INC-002",
	}
	if _, _, suerr := tracker.manager_update_sprint(m, "SPR-001", &su, ra); suerr != nil {
		testing.expectf(t, false, "defer note: %v", suerr)
		return false
	}
	if _, clerr := tracker.manager_close_sprint(m, "shipped", ra); clerr != nil {
		testing.expectf(t, false, "close sprint: %v", clerr)
		return false
	}
	return true
}

@(test)
tracker_snapshot_restore_equivalence :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-snap-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp dir: %v", derr)
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir, context.allocator)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path, context.allocator)
	db, oerr := store.db_open(db_path, context.allocator)
	if oerr != nil {
		testing.expectf(t, false, "open: %v", oerr)
		return
	}
	defer store.db_close(db)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	ra := mem.dynamic_arena_allocator(&arena)

	manager_now_ns_val = 1_000_000_000
	m1 := new(tracker.Manager, context.allocator)
	defer free(m1, context.allocator)
	if ierr := tracker.manager_init(m1, db, manager_now_ns, 0xaabbccdd, 0x1234_5678_9abc_def0, true, context.allocator); ierr != nil {
		testing.expectf(t, false, "init: %v", ierr)
		return
	}
	if !snapshot_seed_events(t, m1, ra) {
		return
	}

	// Two rows the running manager never folded: an unknown-kind row
	// (absorbed as a fold anomaly) and a not-even-JSON row (skipped, but
	// it still orders the stream). The snapshot's watermark predates
	// both, so re-init must replay them from the tail.
	big_ns := manager_now_ns_val + 1_000_000_000
	row1 := store.Event_Row{
		uid     = tracker.uid_mint(big_ns, 0xdead_beef, ra),
		ts      = big_ns / 1_000_000,
		origin  = "foreign",
		kind    = "incident/nonsense",
		version = tracker.EVENT_SCHEMA_VERSION,
		payload = `{"x":1}`,
	}
	if aerr := store.events_append(db, &row1); aerr != nil {
		testing.expectf(t, false, "append foreign: %v", aerr)
		return
	}
	row2 := store.Event_Row{
		uid     = tracker.uid_mint(big_ns + 1, 0xfeed_face, ra),
		ts      = (big_ns + 1) / 1_000_000,
		origin  = "foreign",
		kind    = "incident/created",
		version = tracker.EVENT_SCHEMA_VERSION,
		payload = "not json at all",
	}
	if aerr := store.events_append(db, &row2); aerr != nil {
		testing.expectf(t, false, "append junk: %v", aerr)
		return
	}

	tracker.manager_destroy(m1) // dirty > 0: teardown writes the snapshot

	m2 := new(tracker.Manager, context.allocator)
	defer free(m2, context.allocator)
	if ierr := tracker.manager_init(m2, db, manager_now_ns, 11, 22, true, context.allocator); ierr != nil {
		testing.expectf(t, false, "re-init: %v", ierr)
		return
	}
	testing.expect(t, m2.is_snapshot_restored, "re-init must take the restore path")
	testing.expectf(t, len(m2.state.anomalies) >= 1, "the unknown-kind tail row lands as a fold anomaly")

	tsv_a, sum_a, rerr := snapshot_renders(m2, ra)
	if rerr != nil {
		testing.expectf(t, false, "render: %v", rerr)
		return
	}

	// Codec idempotence: serialize → restore → serialize is a fixed point.
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&scratch)
	sa := mem.dynamic_arena_allocator(&scratch)
	blob1, ok1 := tracker.snapshot_serialize(&m2.state, m2.last_seen_uid, context.allocator)
	testing.expect(t, ok1)
	s2: tracker.Fold_State
	tracker.fold_state_init(&s2, context.allocator)
	max_uid, has_events, _ := store.events_last_uid(db, sa)
	lsu, rok, rreason := tracker.snapshot_restore(&s2, blob1, max_uid, has_events, sa)
	testing.expectf(t, rok, "restore own blob: %s", rreason)
	if rok {
		blob2, ok2 := tracker.snapshot_serialize(&s2, lsu, context.allocator)
		testing.expect(t, ok2)
		testing.expect(t, blob1 == blob2)
		delete(blob2, context.allocator)
	}
	tracker.fold_state_destroy(&s2)
	delete(blob1, context.allocator)

	// Detail view: event refs survived the restore (payloads fetch by uid).
	det, gterr := tracker.manager_get_incident(m2, "INC-001", 0, ra)
	testing.expectf(t, gterr == nil, "get: %v", gterr)
	testing.expect(t, strings.contains(det, "resolved: fixed"))

	// The full refold of the same stream must agree byte for byte.
	if derr := store.kv_delete(db, tracker.SNAPSHOT_KEY); derr != nil {
		testing.expectf(t, false, "kv_delete: %v", derr)
		return
	}
	m3 := new(tracker.Manager, context.allocator)
	defer free(m3, context.allocator)
	if ierr := tracker.manager_init(m3, db, manager_now_ns, 33, 44, false, context.allocator); ierr != nil {
		testing.expectf(t, false, "full-refold init: %v", ierr)
		return
	}
	testing.expect(t, !m3.is_snapshot_restored)
	tsv_b, sum_b, rerr3 := snapshot_renders(m3, ra)
	if rerr3 != nil {
		testing.expectf(t, false, "render full: %v", rerr3)
		return
	}
	testing.expectf(t, tsv_a == tsv_b, "TSV diverged between restore and full refold")
	testing.expectf(t, sum_a == sum_b, "open summary diverged between restore and full refold")
	testing.expect(t, len(m3.state.anomalies) == len(m2.state.anomalies))

	tracker.manager_destroy(m2)
	tracker.manager_destroy(m3)
}

@(test)
tracker_snapshot_tail_replay :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-snap-tail-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp dir: %v", derr)
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir, context.allocator)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path, context.allocator)
	db, oerr := store.db_open(db_path, context.allocator)
	if oerr != nil {
		testing.expectf(t, false, "open: %v", oerr)
		return
	}
	defer store.db_close(db)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	ra := mem.dynamic_arena_allocator(&arena)

	manager_now_ns_val = 5_000_000_000
	m1 := new(tracker.Manager, context.allocator)
	defer free(m1, context.allocator)
	if ierr := tracker.manager_init(m1, db, manager_now_ns, 1, 2, true, context.allocator); ierr != nil {
		testing.expectf(t, false, "init: %v", ierr)
		return
	}
	in1 := tracker.Create_Input{title = "first", body_md = "one"}
	if _, cerr := tracker.manager_create(m1, &in1, ra); cerr != nil {
		testing.expectf(t, false, "create: %v", cerr)
		return
	}
	in2 := tracker.Create_Input{title = "second", body_md = "two"}
	if _, cerr := tracker.manager_create(m1, &in2, ra); cerr != nil {
		testing.expectf(t, false, "create2: %v", cerr)
		return
	}
	tracker.manager_destroy(m1) // writes the snapshot

	// Restore, rewind the clock below the stream, and append: minting must
	// order strictly after the watermark the snapshot carried.
	m2 := new(tracker.Manager, context.allocator)
	defer free(m2, context.allocator)
	if ierr := tracker.manager_init(m2, db, manager_now_ns, 3, 4, true, context.allocator); ierr != nil {
		testing.expectf(t, false, "re-init: %v", ierr)
		return
	}
	testing.expect(t, m2.is_snapshot_restored)
	manager_now_ns_val = 0
	in3 := tracker.Create_Input{title = "third", body_md = "three"}
	cr3, cerr3 := tracker.manager_create(m2, &in3, ra)
	if cerr3 != nil {
		testing.expectf(t, false, "create3: %v", cerr3)
		return
	}
	testing.expect(t, cr3.id == "INC-003")
	nu := tracker.Update_Input{note = "post-restore note", note_set = true}
	if _, _, uerr := tracker.manager_update_incident(m2, "INC-002", &nu, ra); uerr != nil {
		testing.expectf(t, false, "note: %v", uerr)
		return
	}
	tracker.manager_destroy(m2) // dirty > 0: rewrites the snapshot past the tail

	m3 := new(tracker.Manager, context.allocator)
	defer free(m3, context.allocator)
	if ierr := tracker.manager_init(m3, db, manager_now_ns, 5, 6, false, context.allocator); ierr != nil {
		testing.expectf(t, false, "re-init 2: %v", ierr)
		return
	}
	testing.expect(t, m3.is_snapshot_restored)
	tsv_a, sum_a, rerr := snapshot_renders(m3, ra)
	if rerr != nil {
		testing.expectf(t, false, "render: %v", rerr)
		return
	}

	if derr := store.kv_delete(db, tracker.SNAPSHOT_KEY); derr != nil {
		testing.expectf(t, false, "kv_delete: %v", derr)
		return
	}
	m4 := new(tracker.Manager, context.allocator)
	defer free(m4, context.allocator)
	if ierr := tracker.manager_init(m4, db, manager_now_ns, 7, 8, false, context.allocator); ierr != nil {
		testing.expectf(t, false, "full-refold init: %v", ierr)
		return
	}
	testing.expect(t, !m4.is_snapshot_restored)
	tsv_b, sum_b, rerr4 := snapshot_renders(m4, ra)
	if rerr4 != nil {
		testing.expectf(t, false, "render full: %v", rerr4)
		return
	}
	testing.expectf(t, tsv_a == tsv_b, "TSV diverged between restore and full refold")
	testing.expectf(t, sum_a == sum_b, "open summary diverged between restore and full refold")

	tracker.manager_destroy(m3)
	tracker.manager_destroy(m4)
}

@(test)
tracker_snapshot_fallback_paths :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-snap-fb-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp dir: %v", derr)
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir, context.allocator)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path, context.allocator)
	db, oerr := store.db_open(db_path, context.allocator)
	if oerr != nil {
		testing.expectf(t, false, "open: %v", oerr)
		return
	}
	defer store.db_close(db)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	ra := mem.dynamic_arena_allocator(&arena)

	manager_now_ns_val = 9_000_000_000
	m1 := new(tracker.Manager, context.allocator)
	defer free(m1, context.allocator)
	if ierr := tracker.manager_init(m1, db, manager_now_ns, 1, 2, true, context.allocator); ierr != nil {
		testing.expectf(t, false, "init: %v", ierr)
		return
	}
	in1 := tracker.Create_Input{title = "seed", body_md = "body"}
	if _, cerr := tracker.manager_create(m1, &in1, ra); cerr != nil {
		testing.expectf(t, false, "create: %v", cerr)
		return
	}
	tracker.manager_destroy(m1)

	// Corrupt blob: init must fall back to the full refold and say so in
	// the fold's own anomaly ledger.
	if perr := store.kv_put(db, tracker.SNAPSHOT_KEY, "{not json"); perr != nil {
		testing.expectf(t, false, "kv_put: %v", perr)
		return
	}
	m2 := new(tracker.Manager, context.allocator)
	defer free(m2, context.allocator)
	if ierr := tracker.manager_init(m2, db, manager_now_ns, 3, 4, false, context.allocator); ierr != nil {
		testing.expectf(t, false, "init corrupt: %v", ierr)
		return
	}
	testing.expect(t, !m2.is_snapshot_restored)
	testing.expectf(t, len(m2.state.anomalies) == 1, "corrupt snapshot leaves exactly one anomaly line")
	if len(m2.state.anomalies) == 1 {
		testing.expect(t, strings.contains(m2.state.anomalies[0], "fold snapshot"), m2.state.anomalies[0])
	}
	tsv_corrupt, _, rerr := snapshot_renders(m2, ra)
	if rerr != nil {
		testing.expectf(t, false, "render: %v", rerr)
		return
	}
	tracker.manager_destroy(m2)

	// Watermark ahead of the stream: refused before any state is touched.
	if perr := store.kv_put(db, tracker.SNAPSHOT_KEY, `{"version":1,"last_seen_uid":"7fffffffffffffff-0000000000000000"}`); perr != nil {
		testing.expectf(t, false, "kv_put stale: %v", perr)
		return
	}
	m3 := new(tracker.Manager, context.allocator)
	defer free(m3, context.allocator)
	if ierr := tracker.manager_init(m3, db, manager_now_ns, 5, 6, false, context.allocator); ierr != nil {
		testing.expectf(t, false, "init stale: %v", ierr)
		return
	}
	testing.expect(t, !m3.is_snapshot_restored)
	testing.expectf(t, len(m3.state.anomalies) == 1, "stale snapshot leaves exactly one anomaly line")
	if len(m3.state.anomalies) == 1 {
		testing.expect(t, strings.contains(m3.state.anomalies[0], "ahead of the event stream"), m3.state.anomalies[0])
	}
	tsv_stale, _, rerr3 := snapshot_renders(m3, ra)
	if rerr3 != nil {
		testing.expectf(t, false, "render stale: %v", rerr3)
		return
	}

	// Both fallbacks fold the same stream as a clean full refold would.
	if derr := store.kv_delete(db, tracker.SNAPSHOT_KEY); derr != nil {
		testing.expectf(t, false, "kv_delete: %v", derr)
		return
	}
	m4 := new(tracker.Manager, context.allocator)
	defer free(m4, context.allocator)
	if ierr := tracker.manager_init(m4, db, manager_now_ns, 7, 8, false, context.allocator); ierr != nil {
		testing.expectf(t, false, "init clean: %v", ierr)
		return
	}
	tsv_clean, _, rerr4 := snapshot_renders(m4, ra)
	if rerr4 != nil {
		testing.expectf(t, false, "render clean: %v", rerr4)
		return
	}
	testing.expectf(t, tsv_corrupt == tsv_clean, "corrupt-snapshot fallback diverged from the full refold")
	testing.expectf(t, tsv_stale == tsv_clean, "stale-snapshot fallback diverged from the full refold")

	tracker.manager_destroy(m3)
	tracker.manager_destroy(m4)
}

// The restore contract refuses ANY structural surprise. These shapes are
// not producible by the writer (it emits bijective sections), but a
// hand-edited kv row must fall back to the full refold — not silently
// keep the last duplicate (leaking the overwritten header), not free the
// same header twice at teardown, and not leak the entities an earlier
// section already restored when a later one refuses. Every case runs on
// the tracking allocator: a leak or double free here fails the suite's
// zero-leak discipline even where the assertion only checks the reason.
@(test)
tracker_snapshot_refuses_non_bijective_sections :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-snap-tamper-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp dir: %v", derr)
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir, context.allocator)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path, context.allocator)
	db, oerr := store.db_open(db_path, context.allocator)
	if oerr != nil {
		testing.expectf(t, false, "open: %v", oerr)
		return
	}
	defer store.db_close(db)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	ra := mem.dynamic_arena_allocator(&arena)

	manager_now_ns_val = 5_000_000_000
	m1 := new(tracker.Manager, context.allocator)
	defer free(m1, context.allocator)
	if ierr := tracker.manager_init(m1, db, manager_now_ns, 1, 2, true, context.allocator); ierr != nil {
		testing.expectf(t, false, "init: %v", ierr)
		return
	}
	if !snapshot_seed_events(t, m1, ra) {
		return
	}
	tracker.manager_destroy(m1) // teardown writes the snapshot

	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&scratch)
	sa := mem.dynamic_arena_allocator(&scratch)
	blob, found, kverr := store.kv_get(db, tracker.SNAPSHOT_KEY, sa)
	if kverr != nil || !found {
		testing.expectf(t, false, "kv_get snapshot: found=%v err=%v", found, kverr)
		return
	}
	max_uid, has_events, _ := store.events_last_uid(db, sa)

	refuse_check :: proc(t: ^testing.T, tampered: string, want: string, max_uid: string, has_events: bool, scratch: mem.Allocator) {
		s: tracker.Fold_State
		tracker.fold_state_init(&s, context.allocator)
		_, ok, reason := tracker.snapshot_restore(&s, tampered, max_uid, has_events, scratch)
		testing.expectf(t, !ok, "tampered blob must be refused, got: %s", reason)
		if !ok {
			testing.expectf(t, strings.contains(reason, want), "reason %q must mention %q", reason, want)
		}
		// The refusal leaves the caller's (empty) state destroyable.
		tracker.fold_state_destroy(&s)
	}

	// 1. A duplicated incident entity: the section array outgrows its order.
	parsed, perr := json.parse_string(blob, spec = .JSON, parse_integers = true, allocator = sa)
	if perr != nil {
		testing.expectf(t, false, "parse: %v", perr)
		return
	}
	root, is_obj := jsonutil.as_object(parsed)
	testing.expect(t, is_obj)
	incs, iok := jsonutil.as_array(root["incidents"])
	testing.expectf(t, iok && len(incs) == 2, "seed must carry two incidents")
	dup_arr := make([]json.Value, len(incs) + 1, sa)
	for v, i in incs {
		dup_arr[i] = v
	}
	dup_arr[len(incs)] = incs[0]
	saved := root["incidents"]
	root["incidents"] = jsonutil.json_array(dup_arr, sa)
	refuse_check(t, jsonutil.marshal_value(parsed, sa), "disagree with the incident order", max_uid, has_events, sa)
	root["incidents"] = saved

	// 2. A repeated order entry: the same uid listed twice would have the
	// teardown's order walk free one header twice.
	order, ook := jsonutil.as_array(root["incident_order"])
	testing.expectf(t, ook && len(order) == 2, "seed must carry a two-entry order")
	rep_arr := make([]json.Value, len(order), sa)
	for v, i in order {
		rep_arr[i] = v
	}
	rep_arr[1] = order[0]
	saved_order := root["incident_order"]
	root["incident_order"] = jsonutil.json_array(rep_arr, sa)
	refuse_check(t, jsonutil.marshal_value(parsed, sa), "repeats an incident", max_uid, has_events, sa)
	root["incident_order"] = saved_order

	// 3. A malformed event ref mid-array: the refs build must release its
	// partial clones when the second element refuses.
	inc0, cok := jsonutil.as_object(incs[0])
	testing.expect(t, cok)
	events, eok := jsonutil.as_array(inc0["events"])
	testing.expectf(t, eok && len(events) > 0, "seeded incident must carry event refs")
	bad_refs := make([]json.Value, len(events) + 1, sa)
	for v, i in events {
		bad_refs[i] = v
	}
	bad_refs[len(events)] = json.Value(json.Integer(42))
	saved_events := inc0["events"]
	inc0["events"] = jsonutil.json_array(bad_refs, sa)
	refuse_check(t, jsonutil.marshal_value(parsed, sa), "event ref is not an object", max_uid, has_events, sa)
	inc0["events"] = saved_events

	// 4. A shape failure in a LATER incident: the abort must free the
	// entities the earlier section already restored.
	inc1, i1ok := jsonutil.as_object(incs[1])
	testing.expect(t, i1ok)
	saved_title := inc1["title"]
	inc1["title"] = json.Value(json.Integer(42))
	refuse_check(t, jsonutil.marshal_value(parsed, sa), "field title is not a string", max_uid, has_events, sa)
	inc1["title"] = saved_title

	// The untouched blob still restores (the tampering above was all
	// undone after each case).
	s2: tracker.Fold_State
	tracker.fold_state_init(&s2, context.allocator)
	_, ok2, reason2 := tracker.snapshot_restore(&s2, blob, max_uid, has_events, sa)
	testing.expectf(t, ok2, "untouched blob must restore: %s", reason2)
	tracker.fold_state_destroy(&s2)
}

// An eventless project must never grow a fold snapshot, and a legacy
// empty-watermark snapshot — persisted by builds without that guard —
// must restore as benign emptiness instead of poisoning every start
// with a watermark anomaly, then give way to a real checkpoint once
// events are minted on top of it.
@(test)
tracker_snapshot_empty_stream_benign :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-snap-empty-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp dir: %v", derr)
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir, context.allocator)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path, context.allocator)
	db, oerr := store.db_open(db_path, context.allocator)
	if oerr != nil {
		testing.expectf(t, false, "open: %v", oerr)
		return
	}
	defer store.db_close(db)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	ra := mem.dynamic_arena_allocator(&arena)

	manager_now_ns_val = 11_000_000_000

	// Phase 1 — write side: a daemon-shaped init over an empty stream
	// checkpoints nothing, neither at init nor at teardown.
	m1 := new(tracker.Manager, context.allocator)
	defer free(m1, context.allocator)
	if ierr := tracker.manager_init(m1, db, manager_now_ns, 1, 2, true, context.allocator); ierr != nil {
		testing.expectf(t, false, "init: %v", ierr)
		return
	}
	testing.expect(t, !m1.is_snapshot_restored)
	_, found, gerr := store.kv_get(db, tracker.SNAPSHOT_KEY, ra)
	testing.expectf(t, gerr == nil && !found, "an empty fold must not persist a snapshot (found=%v err=%v)", found, gerr)
	tracker.manager_destroy(m1)
	_, found_teardown, _ := store.kv_get(db, tracker.SNAPSHOT_KEY, ra)
	testing.expect(t, !found_teardown, "eventless teardown must not persist a snapshot either")

	// Phase 2 — read side: the exact blob the unguarded build persisted
	// (an empty fold serialized with an empty watermark) restores as
	// benign emptiness on a CLI-shaped start.
	empty: tracker.Fold_State
	tracker.fold_state_init(&empty, context.allocator)
	blob, bok := tracker.snapshot_serialize(&empty, "", context.allocator)
	tracker.fold_state_destroy(&empty)
	if !bok {
		testing.expectf(t, false, "serialize of the empty fold failed")
		return
	}
	defer delete(blob, context.allocator)
	if perr := store.kv_put(db, tracker.SNAPSHOT_KEY, blob); perr != nil {
		testing.expectf(t, false, "kv_put: %v", perr)
		return
	}
	m2 := new(tracker.Manager, context.allocator)
	defer free(m2, context.allocator)
	if ierr := tracker.manager_init(m2, db, manager_now_ns, 3, 4, false, context.allocator); ierr != nil {
		testing.expectf(t, false, "init poisoned: %v", ierr)
		return
	}
	testing.expect(t, m2.is_snapshot_restored, "an empty-watermark snapshot must restore as benign")
	testing.expectf(t, len(m2.state.anomalies) == 0, "benign empty snapshot must not alarm: %v", m2.state.anomalies)
	tracker.manager_destroy(m2)

	// Phase 3 — the poisoned checkpoint heals: a daemon-shaped start
	// restores it benignly, an event minted on top makes teardown write
	// a real checkpoint, and the next start restores from THAT — the
	// empty watermark is gone for good.
	m3 := new(tracker.Manager, context.allocator)
	defer free(m3, context.allocator)
	if ierr := tracker.manager_init(m3, db, manager_now_ns, 5, 6, true, context.allocator); ierr != nil {
		testing.expectf(t, false, "init daemon poisoned: %v", ierr)
		return
	}
	testing.expect(t, m3.is_snapshot_restored)
	testing.expectf(t, len(m3.state.anomalies) == 0, "daemon-shaped benign restore must not alarm: %v", m3.state.anomalies)
	ci := tracker.Create_Input{title = "heal", body_md = "claim"}
	if _, cerr := tracker.manager_create(m3, &ci, ra); cerr != nil {
		testing.expectf(t, false, "create: %v", cerr)
		return
	}
	tracker.manager_destroy(m3) // dirty > 0: teardown replaces the blob
	m4 := new(tracker.Manager, context.allocator)
	defer free(m4, context.allocator)
	if ierr := tracker.manager_init(m4, db, manager_now_ns, 7, 8, false, context.allocator); ierr != nil {
		testing.expectf(t, false, "init healed: %v", ierr)
		return
	}
	testing.expect(t, m4.is_snapshot_restored)
	testing.expectf(t, len(m4.state.anomalies) == 0, "healed snapshot must restore without anomalies: %v", m4.state.anomalies)
	counts := tracker.manager_counts(m4)
	testing.expect_value(t, counts.total, 1)
	replacement, rfound, _ := store.kv_get(db, tracker.SNAPSHOT_KEY, ra)
	testing.expectf(t, rfound && !strings.contains(replacement, `"last_seen_uid":""`), "the healed checkpoint must carry a real watermark")
	tracker.manager_destroy(m4)

	// Phase 4 — the refusal survives: a NON-empty garbage watermark is
	// still a corrupt snapshot, not a benign empty one.
	if perr := store.kv_put(db, tracker.SNAPSHOT_KEY, `{"version":1,"last_seen_uid":"zzz"}`); perr != nil {
		testing.expectf(t, false, "kv_put garbage: %v", perr)
		return
	}
	m5 := new(tracker.Manager, context.allocator)
	defer free(m5, context.allocator)
	if ierr := tracker.manager_init(m5, db, manager_now_ns, 9, 10, false, context.allocator); ierr != nil {
		testing.expectf(t, false, "init garbage: %v", ierr)
		return
	}
	testing.expect(t, !m5.is_snapshot_restored)
	testing.expectf(t, len(m5.state.anomalies) == 1, "garbage watermark leaves exactly one anomaly line")
	if len(m5.state.anomalies) == 1 {
		testing.expect(t, strings.contains(m5.state.anomalies[0], "not a uid"), m5.state.anomalies[0])
	}
	counts5 := tracker.manager_counts(m5)
	testing.expect_value(t, counts5.total, 1) // the fallback refold still sees the event
	tracker.manager_destroy(m5)
}

// Alias ownership across delete/reassign (the map owns the stored key
// clones — delete_key must hand them back before they are freed) and the
// presence gates that whitespace-only prose must not slip through.
@(test)
tracker_alias_release_and_validator_gates :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-tracker-alias-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp dir: %v", derr)
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir, context.allocator)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path, context.allocator)
	db, oerr := store.db_open(db_path, context.allocator)
	if oerr != nil {
		testing.expectf(t, false, "open: %v", oerr)
		return
	}
	defer store.db_close(db)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	ra := mem.dynamic_arena_allocator(&arena)

	manager_now_ns_val = 5_000_000_000
	m := new(tracker.Manager, context.allocator)
	defer free(m, context.allocator)
	ierr := tracker.manager_init(m, db, manager_now_ns, 0xaabbccdd, 0x1234_5678_9abc_def0, true, context.allocator)
	if ierr != nil {
		testing.expectf(t, false, "init: %v", ierr)
		return
	}
	defer tracker.manager_destroy(m)

	// Empty aliases are rejected up front.
	bad := tracker.Create_Input{title = "x", body_md = "b", aliases = []string{""}}
	if _, berr := tracker.manager_create(m, &bad, ra); berr == nil {
		testing.expect(t, false, "empty alias must be rejected")
		return
	}

	// Create with an alias; a second incident cannot take it while owned.
	in1 := tracker.Create_Input{title = "one", body_md = "b", aliases = []string{"R2-SG-01"}}
	cr1, cerr := tracker.manager_create(m, &in1, ra)
	if cerr != nil {
		testing.expectf(t, false, "create1: %v", cerr)
		return
	}
	in2 := tracker.Create_Input{title = "two", body_md = "b", aliases = []string{"R2-SG-01"}}
	if _, terr := tracker.manager_create(m, &in2, ra); terr == nil {
		testing.expect(t, false, "taken alias must be rejected")
		return
	}

	// Whitespace-only verify inputs are rejected like empty ones.
	if _, werr := tracker.manager_verify(m, cr1.id, "confirmed", "", " \n\t ", "evidence", ra); werr == nil {
		testing.expect(t, false, "whitespace-only reason_md must be rejected")
		return
	}
	if _, werr2 := tracker.manager_verify(m, cr1.id, "confirmed", "", "why", " ", ra); werr2 == nil {
		testing.expect(t, false, "whitespace-only evidence_md must be rejected")
		return
	}

	// Deleting the owner releases the alias: a new incident may claim it.
	if _, del_err := tracker.manager_delete(m, cr1.id, "cleanup", "", ra); del_err != nil {
		testing.expectf(t, false, "delete: %v", del_err)
		return
	}
	cr3, cerr3 := tracker.manager_create(m, &in2, ra)
	if cerr3 != nil {
		testing.expectf(t, false, "recreate with released alias: %v", cerr3)
		return
	}
	testing.expect(t, cr3.id != cr1.id)

	if _, verr := tracker.manager_verify(m, cr3.id, "confirmed", "", "why", "evidence", ra); verr != nil {
		testing.expectf(t, false, "verify: %v", verr)
		return
	}

	// Reassigning the alias set releases the old spelling the same way.
	fu := tracker.Fields_Update{aliases = []string{"R2-SG-02"}, aliases_set = true}
	upf := tracker.Update_Input{fields = fu, fields_set = true}
	if _, _, ferr := tracker.manager_update_incident(m, cr3.id, &upf, ra); ferr != nil {
		testing.expectf(t, false, "alias reassign: %v", ferr)
		return
	}
	cr4, cerr4 := tracker.manager_create(m, &in2, ra)
	if cerr4 != nil {
		testing.expectf(t, false, "claim alias freed by reassign: %v", cerr4)
		return
	}
	testing.expect(t, cr4.id != cr3.id)

	// Whitespace-only resolve evidence is rejected on the resolved path.
	if _, verr4 := tracker.manager_verify(m, cr4.id, "confirmed", "", "why", "evidence", ra); verr4 != nil {
		testing.expectf(t, false, "verify cr4: %v", verr4)
		return
	}
	rc := tracker.Update_Input{root_cause = "rc", root_cause_set = true}
	if _, _, uerr := tracker.manager_update_incident(m, cr4.id, &rc, ra); uerr != nil {
		testing.expectf(t, false, "root cause: %v", uerr)
		return
	}
	sc := tracker.Status_Change{to = "resolved", resolution = "fixed", evidence_md = " \t "}
	up := tracker.Update_Input{status = sc, status_set = true}
	if _, _, rerr := tracker.manager_update_incident(m, cr4.id, &up, ra); rerr == nil {
		testing.expect(t, false, "whitespace-only resolve evidence must be rejected")
		return
	}
}

// A snapshot whose dag edge is not a string must fail the restore AND
// leave nothing behind: the partially built node (and any nodes already
// stored) are freed on the bail path — the suite's leak discipline is the
// assertion that the partial-free defers actually run.
@(test)
tracker_snapshot_restore_frees_partial_dag_node :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-snap-leak-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp dir: %v", derr)
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir, context.allocator)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path, context.allocator)
	db, oerr := store.db_open(db_path, context.allocator)
	if oerr != nil {
		testing.expectf(t, false, "open: %v", oerr)
		return
	}
	defer store.db_close(db)

	manager_now_ns_val = 7_000_000_000
	m := new(tracker.Manager, context.allocator)
	defer free(m, context.allocator)
	if ierr := tracker.manager_init(m, db, manager_now_ns, 0xaabbccdd, 0x1234_5678_9abc_def0, true, context.allocator); ierr != nil {
		testing.expectf(t, false, "init: %v", ierr)
		return
	}

	// Two incidents with a blocked_by edge: the dag carries one node with
	// a populated edge list and one with an empty one.
	in1 := tracker.Create_Input{title = "blocker", body_md = "claim"}
	if _, cerr := tracker.manager_create(m, &in1, context.temp_allocator); cerr != nil {
		testing.expectf(t, false, "create1: %v", cerr)
		return
	}
	in2 := tracker.Create_Input{title = "blocked", body_md = "claim", blocked_by = []string{"INC-001"}}
	if _, cerr2 := tracker.manager_create(m, &in2, context.temp_allocator); cerr2 != nil {
		testing.expectf(t, false, "create2: %v", cerr2)
		return
	}

	blob, ok := tracker.snapshot_serialize(&m.state, m.last_seen_uid, context.allocator)
	testing.expect(t, ok)
	corrupted, _ := strings.replace_all(blob, `"edges":[]`, `"edges":[1]`, context.allocator)
	testing.expectf(t, strings.contains(corrupted, `"edges":[1]`), "fixture must corrupt an edge list")
	delete(blob, context.allocator)

	s: tracker.Fold_State
	tracker.fold_state_init(&s, context.allocator)
	max_uid, has_events, _ := store.events_last_uid(db, context.temp_allocator)
	_, rok, reason := tracker.snapshot_restore(&s, corrupted, max_uid, has_events, context.temp_allocator)
	testing.expectf(t, !rok, "corrupt edge must fail the restore (reason=%s)", reason)
	if !rok {
		testing.expect(t, strings.contains(reason, "edge"), reason)
	}
	tracker.fold_state_destroy(&s)
	delete(corrupted, context.allocator)
	tracker.manager_destroy(m)
}

@(test)
tracker_close_outcome_cap_refused :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-tracker-cap-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp dir: %v", derr)
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir, context.allocator)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path, context.allocator)
	db, oerr := store.db_open(db_path, context.allocator)
	if oerr != nil {
		testing.expectf(t, false, "open: %v", oerr)
		return
	}
	defer store.db_close(db)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	ra := mem.dynamic_arena_allocator(&arena)

	manager_now_ns_val = 1_000_000_000
	m := new(tracker.Manager, context.allocator)
	// Declared in this order so the LIFO defer run destroys the manager
	// before the struct free (manager_destroy does not free m itself).
	defer free(m, context.allocator)
	defer tracker.manager_destroy(m)
	if ierr := tracker.manager_init(m, db, manager_now_ns, 0xaabbccdd, 0x1234_5678_9abc_def0, true, context.allocator); ierr != nil {
		testing.expectf(t, false, "init: %v", ierr)
		return
	}
	_, serr := tracker.manager_start_sprint(m, "cap round", "g", "", nil, ra)
	if serr != nil {
		testing.expectf(t, false, "start sprint: %v", serr)
		return
	}

	// The close outcome is a long-form field like every other: the cap
	// refusal must come from validate_body, not a chunk-write storage
	// error after the mint.
	buf := make([dynamic]u8, 0, tracker.EVENT_BODY_CAP + 16, ra)
	for len(buf) <= tracker.EVENT_BODY_CAP {
		append(&buf, u8('x'))
	}
	if _, cerr := tracker.manager_close_sprint(m, string(buf[:]), ra); cerr == nil {
		testing.expectf(t, false, "oversized outcome must be refused")
		return
	} else {
		msg := platform.err_message(cerr, ra)
		testing.expect(t, strings.contains(msg, "outcome"), "refusal names the field: %s", msg)
	}
}
