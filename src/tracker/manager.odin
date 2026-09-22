package tracker

// The manager owns the fold state and is the tracker's only concurrency
// boundary: writes validate, mint, append, and re-fold under one mutex;
// reads render under the same mutex so no header pointer ever escapes.
// Persistence is one store transaction per event (the SQLite redesign —
// the original's chunk batches, ownership rotation, and freshness scans
// do not exist here: the daemon is the single writer, and a crashed
// composite batch leaves a consistent prefix the fold absorbs).
//
// Every public operation takes the request arena: payloads, errors, and
// result strings live there and die with the request. The wall clock is
// injected (Now_Ns_Proc) so tests run deterministically.

import "core:fmt"
import "core:mem"
import "core:sort"
import "core:strings"
import "core:sync"
import "src:platform"
import "src:util"
import "src:store"

Now_Ns_Proc :: proc() -> i64

Manager :: struct {
	mu:                sync.Mutex,
	state:             Fold_State,
	db:                ^store.DB, // borrowed; the daemon owns the connection
	origin:            string,    // owned 8-hex process identifier
	last_ns:           i64,       // uid watermark; strictly increasing
	rng:               u64,       // xorshift state for uid randomness
	now_ns:            Now_Ns_Proc,
	allocator:         mem.Allocator,
	// Snapshot policy: restore is always attempted (a read-only kv load),
	// but WRITES happen only when the daemon owns the manager — the CLI
	// families stay read-only by design.
	snapshots:         bool,
	is_snapshot_restored: bool, // test/telemetry visibility: init took the restore path
	snapshot_dirty:    int,  // events folded since the last successful write
	last_seen_uid:     string, // owned; consumed watermark (skipped rows included)
}

manager_init :: proc(
	m: ^Manager,
	db: ^store.DB,
	now: Now_Ns_Proc,
	origin_seed: u32,
	rng_seed: u64,
	snapshots: bool,
	a: mem.Allocator,
) -> platform.Err {
	m^ = {
		db = db, now_ns = now, rng = rng_seed | 1, allocator = a,
		snapshots = snapshots,
	}
	fold_state_init(&m.state, a)
	m.origin = origin_string(origin_seed, a)

	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, a)
	defer mem.dynamic_arena_destroy(&scratch)
	sa := mem.dynamic_arena_allocator(&scratch)

	// Restore path: a snapshot from a previous manager generation turns
	// startup into restore + tail replay instead of a full refold. A
	// snapshot that is absent, stale, or structurally surprising falls
	// back to the full stream with one anomaly line — the events table
	// stays the source of truth either way.
	restored := false
	if blob, found, kv_err := store.kv_get(db, SNAPSHOT_KEY, sa); kv_err == nil && found {
		max_uid, has_events, lu_err := store.events_last_uid(db, sa)
		if lu_err != nil {
			manager_destroy(m)
			return lu_err
		}
		last_seen, ok, reason := snapshot_restore(&m.state, blob, max_uid, has_events, sa)
		if ok {
			m.last_seen_uid = strings.clone(last_seen, a)
			if ns, ns_ok := uid_ts_ns(last_seen); ns_ok {
				m.last_ns = ns
			}
			tail, terr := store.events_read_after(db, last_seen, a)
			if terr != nil {
				manager_destroy(m)
				return terr
			}
			defer store.events_rows_destroy(tail, a)
			if ferr := manager_fold_rows(m, tail, &scratch); ferr != nil {
				manager_destroy(m)
				return ferr
			}
			restored = true
		} else if reason != "" {
			// snapshot_restore left the state empty and clean; record the
			// fallback where the fold keeps its own operational notes.
			append(&m.state.anomalies, strings.clone(reason, a))
		}
	}

	if !restored {
		rows, err := store.events_read_all(db, a)
		if err != nil {
			manager_destroy(m)
			return err
		}
		defer store.events_rows_destroy(rows, a)
		if ferr := manager_fold_rows(m, rows, &scratch); ferr != nil {
			manager_destroy(m)
			return ferr
		}
		// A fresh full fold is the most valuable snapshot: the next start
		// (daemon or CLI) replays only what was appended since.
		if m.snapshots {
			_ = manager_write_snapshot(m)
		}
	}
	m.is_snapshot_restored = restored
	return nil
}

// manager_fold_rows decodes and folds stored rows in stream order. The
// consumed watermark and m.last_ns advance past the LAST row whether or
// not it applied: envelope-invalid rows order the stream too, and the
// next mint must still land strictly after them.
@(private)
manager_fold_rows :: proc(m: ^Manager, rows: []store.Event_Row, scratch: ^mem.Dynamic_Arena) -> platform.Err {
	sa := mem.dynamic_arena_allocator(scratch)
	for i in 0..<len(rows) {
		mem.dynamic_arena_free_all(scratch)
		ev, reason := decode_event(&rows[i], sa)
		if reason != "" {
			continue
		}
		if !fold_apply(&m.state, &ev, sa) {
			return platform.Wrapped{
				kind = .Internal,
				msg  = "tracker: event stream is not in uid order",
			}
		}
	}
	if len(rows) > 0 {
		if ns, ok := uid_ts_ns(rows[len(rows) - 1].uid); ok {
			m.last_ns = ns
			str_set(&m.last_seen_uid, rows[len(rows) - 1].uid, m.allocator)
		}
	}
	return nil
}

// manager_write_snapshot persists the current fold state under
// SNAPSHOT_KEY. Best effort by design: a failed write leaves the dirty
// count alone so the next threshold (or teardown) retries, and startup
// correctness never depends on the write landing. An empty stream is
// never checkpointed: a snapshot must carry a real watermark — restore
// reads the watermark as a stream position — and an empty fold is free
// to rebuild, so an empty-watermark blob buys nothing.
@(private)
manager_write_snapshot :: proc(m: ^Manager) -> bool {
	if m.last_seen_uid == "" {
		return false
	}
	blob, ok := snapshot_serialize(&m.state, m.last_seen_uid, m.allocator)
	if !ok {
		return false
	}
	err := store.kv_put(m.db, SNAPSHOT_KEY, blob)
	delete(blob, m.allocator)
	return err == nil
}

manager_destroy :: proc(m: ^Manager) {
	// Best-effort final snapshot on clean teardown: a missed write only
	// costs the next start a longer tail (or, at worst, a full refold).
	if m.snapshots && m.snapshot_dirty > 0 {
		_ = manager_write_snapshot(m)
	}
	fold_state_destroy(&m.state)
	if m.origin != "" {
		delete(m.origin, m.allocator)
	}
	if m.last_seen_uid != "" {
		delete(m.last_seen_uid, m.allocator)
	}
	m^ = {}
}

@(private)
mrand64 :: proc(m: ^Manager) -> u64 {
	x := m.rng
	x = x ~ (x << 13)
	x = x ~ (x >> 7)
	x = x ~ (x << 17)
	m.rng = x
	return x
}

// mint_and_append writes one event and folds it in. The uid is minted
// strictly after the watermark; a duplicate uid (an impossibly unlikely
// cross-writer collision) bumps the watermark and retries.
@(private)
mint_and_append :: proc(m: ^Manager, kind: Event_Kind, payload: string, a: mem.Allocator) -> platform.Err {
	for attempt in 0..<3 {
		_ = attempt
		ns := m.now_ns()
		if ns <= m.last_ns {
			ns = m.last_ns + 1
		}
		uid := uid_mint(ns, mrand64(m), context.temp_allocator)
		row: store.Event_Row
		row.uid = strings.clone(uid, context.temp_allocator)
		row.ts = ns / 1_000_000
		row.origin = m.origin
		row.kind = event_kind_string(kind)
		row.version = EVENT_SCHEMA_VERSION
		row.payload = payload
		err := store.events_append(m.db, &row)
		if err != nil {
			if platform.err_kind(err) == .Invalid {
				m.last_ns = ns + 1
				continue
			}
			return err
		}
		m.last_ns = ns
		ev, reason := decode_event(&row, context.temp_allocator)
		if reason != "" {
			return platform.Wrapped{
				kind = .Internal,
				msg  = "tracker: minted event failed its own envelope decode",
			}
		}
		if !fold_apply(&m.state, &ev, context.temp_allocator) {
			return platform.Wrapped{
				kind = .Internal,
				msg  = "tracker: event stream went out of order; refold required",
			}
		}
		str_set(&m.last_seen_uid, uid, m.allocator)
		if m.snapshots {
			m.snapshot_dirty += 1
			if m.snapshot_dirty >= SNAPSHOT_EVERY {
				if manager_write_snapshot(m) {
					m.snapshot_dirty = 0
				}
			}
		}
		return nil
	}
	return platform.Wrapped{kind = .Internal, msg = "tracker: uid collision persisted after retries"}
}

// fetch_payload is the detail layer's Payload_Fetch over the store: the
// batched loader (one statement per chunk of uids). A store error
// degrades to whatever loaded — unreadable references are skipped.
manager_fetch_payload :: proc(user: rawptr, uids: []string, a: mem.Allocator) -> map[string]string {
	m := cast(^Manager)user
	payloads, err := store.events_payloads_by_uids(m.db, uids, a)
	_ = err
	return payloads
}

// --- writes ----------------------------------------------------------------

Create_Result :: struct {
	id:       string, // request-arena owned
	title:    string,
	priority: string,
}

// manager_create files a new incident in the reported state.
manager_create :: proc(m: ^Manager, input: ^Create_Input, a: mem.Allocator) -> (Create_Result, platform.Err) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)

	title, err := validate_title(input.title, a)
	if err != nil {
		return {}, err
	}
	if strings.trim_space(input.body_md) == "" {
		// A title-only filing carries no verifiable claim — every later
		// state change demands prose (verify reason+evidence, resolve
		// evidence), so creation must too.
		return {}, inv(a, "description requires body_md (file:line + quote for code findings)")
	}
	if verr := validate_body(input.body_md, "body_md", a); verr != nil {
		return {}, verr
	}
	priority := input.priority
	if priority == "" {
		priority = priority_string(.Medium)
	}
	if verr := validate_priority(priority, a); verr != nil {
		return {}, verr
	}
	labels, ok := normalize_labels(input.labels, a)
	if !ok {
		return {}, inv(a, "invalid label: must match [a-z0-9][a-z0-9_-]{0,31}")
	}
	if verr := validate_sprint_ref(&m.state, input.sprint, a); verr != nil {
		return {}, verr
	}
	if verr := validate_short(input.assignee, "assignee", a); verr != nil {
		return {}, verr
	}
	if verr := validate_short(input.created_by, "created_by", a); verr != nil {
		return {}, verr
	}
	if verr := validate_aliases(&m.state, input.aliases, nil, a); verr != nil {
		return {}, verr
	}
	if verr := validate_blocked_targets(&m.state, "", input.blocked_by, a); verr != nil {
		return {}, verr
	}

	data := Incident_Created_Data{
		title      = title,
		priority   = priority,
		labels     = labels,
		sprint     = input.sprint,
		blocked_by = dedup_sorted(input.blocked_by, a),
		assignee   = input.assignee,
		aliases    = dedup_sorted(input.aliases, a),
		created_by = input.created_by,
		body_md    = input.body_md,
	}
	if aerr := mint_and_append(m, .Incident_Created, encode_incident_created(&data, a), a); aerr != nil {
		return {}, aerr
	}
	// The created header is the newest incident in creation order.
	h := m.state.incidents[m.state.incident_order[len(m.state.incident_order) - 1]]
	return Create_Result{
		id       = strings.clone(h.id, a),
		title    = strings.clone(h.title, a),
		priority = strings.clone(h.priority, a),
	}, nil
}

Verify_Result :: struct {
	id:      string,
	status:  string,
	verdict: string,
}

// manager_verify records a verdict on a reported incident (rejection's
// only path).
manager_verify :: proc(
	m: ^Manager,
	target, verdict, fp_pattern, reason_md, evidence_md: string,
	a: mem.Allocator,
) -> (Verify_Result, platform.Err) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)

	h, err := mutable_incident(&m.state, target, a)
	if err != nil {
		return {}, err
	}
	known_verdict := false
	for v in Verdict {
		if verdict == verdict_string(v) {
			known_verdict = true
			break
		}
	}
	if !known_verdict {
		return {}, inv_cat(a, {"verdict must be one of ", util.wire_names(Verdict, verdict_string, " or ", "'", a), ", got: ", verdict})
	}
	if strings.trim_space(reason_md) == "" || strings.trim_space(evidence_md) == "" {
		return {}, inv(a, "verify requires reason_md and evidence_md (file:line + quote for code findings)")
	}
	if verr := validate_body(reason_md, "reason_md", a); verr != nil {
		return {}, verr
	}
	if verr := validate_body(evidence_md, "evidence_md", a); verr != nil {
		return {}, verr
	}
	if fp_pattern != "" {
		if verdict != verdict_string(.Rejected) {
			return {}, inv(a, "fp_pattern is only valid with verdict=rejected")
		}
		if _, valid := fp_pattern_from_string(fp_pattern); !valid {
			return {}, inv_cat(a, {"fp_pattern must be one of ", util.wire_names(FP_Pattern, fp_pattern_string, "|", "'", a), ", got: ", fp_pattern})
		}
	}
	if h.status != incident_status_string(.Reported) {
		return {}, inv_cat(a, {
			"cannot verify ", h.id, " in status ", h.status, set_by(h, a),
			": re-verify via reopen first",
		})
	}
	data := Incident_Verified_Data{
		target      = h.id,
		verdict     = verdict,
		fp_pattern  = fp_pattern,
		reason_md   = reason_md,
		evidence_md = evidence_md,
	}
	if aerr := mint_and_append(m, .Incident_Verified, encode_incident_verified(&data, a), a); aerr != nil {
		return {}, aerr
	}
	return Verify_Result{
		id      = strings.clone(h.id, a),
		status  = strings.clone(h.status, a),
		verdict = strings.clone(h.verdict, a),
	}, nil
}

// manager_update_incident applies several changes to one incident in one
// call, in two phases: every set section is first validated against a
// projected header (each step sees the effects of the steps before it),
// and any rejection aborts with nothing committed — only after ALL
// sections validated are the events minted and appended, in the fixed
// order title, root cause, fields, status, note. An I/O failure mid-way
// through the append phase still persists the events already written:
// per the SQLite write path each event is its own transaction.
manager_update_incident :: proc(
	m: ^Manager,
	target: string,
	up: ^Update_Input,
	a: mem.Allocator,
) -> (changed: []string, id: string, err: platform.Err) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)

	h, herr := mutable_incident(&m.state, target, a)
	if herr != nil {
		return nil, "", herr
	}
	proj := clone_header_shallow(h, a)
	changed_dyn := make([dynamic]string, 0, 5, a)
	record :: proc(list: ^[dynamic]string, part: string, a: mem.Allocator) {
		append(list, strings.clone(part, a))
	}

	// Phase 1 — validate and encode; the projections feed the next
	// section's validation exactly as they will feed the fold.
	title_data: Incident_Title_Changed_Data
	root_data: Incident_Root_Caused_Data
	fields_data: Incident_Fields_Changed_Data
	status_data: Incident_Status_Changed_Data
	note_data: Incident_Note_Appended_Data
	if up.title_set {
		data, derr := build_title_data(proj, up.title, a)
		if derr != nil {
			return nil, "", derr
		}
		title_data = data
		proj.title = data.title
	}
	if up.root_cause_set {
		data, derr := build_root_cause_data(proj, up.root_cause, a)
		if derr != nil {
			return nil, "", derr
		}
		root_data = data
		project_root_cause(proj)
	}
	if up.fields_set {
		data, derr := build_fields_data(&m.state, proj, up.fields, a)
		if derr != nil {
			return nil, "", derr
		}
		fields_data = data
		project_fields(proj, &data)
	}
	if up.status_set {
		data, derr := build_status_change_data(&m.state, proj, up.status, a)
		if derr != nil {
			return nil, "", derr
		}
		status_data = data
		project_status(proj, up.status.to)
	}
	if up.note_set {
		data, derr := build_note_data(proj, up.note, a)
		if derr != nil {
			return nil, "", derr
		}
		note_data = data
	}

	// Phase 2 — everything validated; commit in the fixed order.
	if up.title_set {
		if aerr := mint_and_append(m, .Incident_Title_Changed, encode_incident_title_changed(&title_data, a), a); aerr != nil {
			return nil, "", aerr
		}
		record(&changed_dyn, "title", a)
	}
	if up.root_cause_set {
		if aerr := mint_and_append(m, .Incident_Root_Caused, encode_incident_root_caused(&root_data, a), a); aerr != nil {
			return nil, "", aerr
		}
		record(&changed_dyn, "root cause", a)
	}
	if up.fields_set {
		if aerr := mint_and_append(m, .Incident_Fields_Changed, encode_incident_fields_changed(&fields_data, a), a); aerr != nil {
			return nil, "", aerr
		}
		record(&changed_dyn, "fields", a)
	}
	if up.status_set {
		if aerr := mint_and_append(m, .Incident_Status_Changed, encode_incident_status_changed(&status_data, a), a); aerr != nil {
			return nil, "", aerr
		}
		record(&changed_dyn, "status", a)
	}
	if up.note_set {
		if aerr := mint_and_append(m, .Incident_Note_Appended, encode_incident_note_appended(&note_data, a), a); aerr != nil {
			return nil, "", aerr
		}
		record(&changed_dyn, "note", a)
	}
	owned := make([]string, len(changed_dyn), a)
	for c, i in changed_dyn {
		owned[i] = c
	}
	delete(changed_dyn)
	return owned, strings.clone(h.id, a), nil
}

// manager_delete tombstones an incident; duplicate_of links the canonical.
manager_delete :: proc(m: ^Manager, target, reason, duplicate_of: string, a: mem.Allocator) -> (id: string, err: platform.Err) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)

	h, herr := mutable_incident(&m.state, target, a)
	if herr != nil {
		return "", herr
	}
	if strings.trim_space(reason) == "" {
		return "", inv(a, "delete requires a reason")
	}
	if duplicate_of != "" {
		dup, derr := must_incident(&m.state, duplicate_of, a)
		if derr != nil {
			return "", inv_cat(a, {"cannot mark ", h.id, " duplicate of ", duplicate_of, ": not found"})
		}
		if dup.is_deleted {
			return "", inv_cat(a, {"cannot mark ", h.id, " duplicate of ", duplicate_of, ": it is deleted"})
		}
		if dup.id == h.id {
			return "", inv_cat(a, {"cannot mark ", h.id, " duplicate of itself"})
		}
	}
	data := Incident_Deleted_Data{target = h.id, reason = reason, duplicate_of = duplicate_of}
	if aerr := mint_and_append(m, .Incident_Deleted, encode_incident_deleted(&data, a), a); aerr != nil {
		return "", aerr
	}
	return strings.clone(h.id, a), nil
}

Sprint_Result :: struct {
	id:   string,
	name: string,
}

// manager_start_sprint opens a new sprint (at most one active).
manager_start_sprint :: proc(
	m: ^Manager,
	name, goal_md, follows: string,
	must: []string,
	a: mem.Allocator,
) -> (Sprint_Result, platform.Err) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)

	if active := active_sprint(&m.state); active != nil {
		return {}, inv_cat(a, {"an active sprint already exists: ", active.id, " (close it first)"})
	}
	valid_name, terr := validate_title(name, a)
	if terr != nil {
		return {}, terr
	}
	if verr := validate_body(goal_md, "goal", a); verr != nil {
		return {}, verr
	}
	if follows != "" {
		if sprint_by_id(&m.state, follows) == nil {
			return {}, inv_cat(a, {"follows sprint ", follows, " not found"})
		}
	}
	if verr := validate_must_tasks(must, a); verr != nil {
		return {}, verr
	}
	data := Sprint_Started_Data{name = valid_name, goal_md = goal_md, follows = follows, must = must, must_set = true}
	if aerr := mint_and_append(m, .Sprint_Started, encode_sprint_started(&data, a), a); aerr != nil {
		return {}, aerr
	}
	spr := sprint_by_id(&m.state, m.state.sprint_order[len(m.state.sprint_order) - 1])
	return Sprint_Result{id = strings.clone(spr.id, a), name = strings.clone(spr.name, a)}, nil
}

Close_Result :: struct {
	id:         string,
	name:       string,
	stats_text: string, // filed-cohort verdict/resolution profile for the ack
}

// close_stats_text renders the close ack's statistics block: the cohort
// line (findings filed inside the sprint window — the same population the
// report lists; confirmed/rejected with the FP rate inside the same
// conditional, unjudged and resolved only when non-zero), then the
// explicitly-scoped cross-cohort line (verdicts and resolutions recorded
// this window on findings filed earlier), then the FP-pattern and wave
// lines. Own proc so the builder's destroy defer is procedure-scoped — a
// defer inside the caller's if-block would fire at block exit, before
// the string is read.
@(private)
close_stats_text :: proc(st: ^Sprint_Stats, a: mem.Allocator) -> string {
	b, berr := strings.builder_make_len_cap(0, 96, a)
	if berr != nil {
		return "" // close already succeeded; the ack degrades to the id
	}
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "filed ")
	strings.write_string(&b, dec(st.total))
	if st.confirmed > 0 || st.rejected > 0 || st.unjudged > 0 {
		strings.write_string(&b, " — ")
		wrote := false
		if st.confirmed > 0 {
			strings.write_string(&b, "confirmed ")
			strings.write_string(&b, dec(st.confirmed))
			wrote = true
		}
		if st.rejected > 0 {
			if wrote {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, "rejected ")
			strings.write_string(&b, dec(st.rejected))
			strings.write_string(&b, " (FP rate ")
			// Truncation, the rule detail/export render with: one rounding
			// rule for every surface of the statistic.
			strings.write_string(&b, dec(int(st.fp_rate * 100)))
			strings.write_string(&b, "%)")
			wrote = true
		}
		if st.unjudged > 0 {
			if wrote {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, "unjudged ")
			strings.write_string(&b, dec(st.unjudged))
		}
	}
	if st.resolved > 0 {
		strings.write_string(&b, ", resolved ")
		strings.write_string(&b, dec(st.resolved))
	}
	if st.judged_earlier > 0 || st.resolved_earlier > 0 {
		strings.write_string(&b, "; this window, on findings filed earlier: ")
		wrote := false
		if st.judged_earlier > 0 {
			strings.write_string(&b, "judged ")
			strings.write_string(&b, dec(st.judged_earlier))
			wrote = true
		}
		if st.resolved_earlier > 0 {
			if wrote {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, "resolved ")
			strings.write_string(&b, dec(st.resolved_earlier))
		}
	}
	if len(st.by_pattern) > 0 {
		patterns := make([dynamic]string, 0, len(st.by_pattern), context.temp_allocator)
		defer delete(patterns)
		for p, n in st.by_pattern {
			append(&patterns, strings.concatenate({p, " ", dec(n)}, context.temp_allocator))
		}
		// Sorted for determinism — the item set is the contract.
		sort.quick_sort(patterns[:])
		strings.write_string(&b, "\nFP patterns: ")
		strings.write_string(&b, short_list(patterns[:], context.temp_allocator))
	}
	waves := make([dynamic]string, 0, 4, context.temp_allocator)
	defer delete(waves)
	for label, ls in st.by_label {
		if strings.has_prefix(label, "wave-") {
			append(&waves, strings.concatenate({label, " (", dec(ls.total), ")"}, context.temp_allocator))
		}
	}
	if len(waves) > 0 {
		sort.quick_sort(waves[:])
		joined, _ := strings.join(waves[:], ", ", context.temp_allocator)
		strings.write_string(&b, "\nwaves: ")
		strings.write_string(&b, joined)
	}
	return strings.clone(strings.to_string(b), a)
}

// manager_close_sprint closes the active sprint (members keep their
// sprint assignment) and renders the audit report for the daemon to write
// best-effort — close already succeeded, a rendering failure never
// surfaces. Close is the enforcement choke point: every must task needs a
// passing verification record or a covering defer record, else the close
// is refused.
manager_close_sprint :: proc(m: ^Manager, outcome_md: string, a: mem.Allocator) -> (Close_Result, platform.Err) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)

	active := active_sprint(&m.state)
	if active == nil {
		return {}, inv(a, "no active sprint to close")
	}
	uncovered := unverified_must_tasks(&m.state, active, a)
	if len(uncovered) > 0 {
		names, _ := strings.join(uncovered[:], ", ", a)
		err := inv_cat(a, {
			"cannot close ", active.id, ": must task(s) ", names,
			" have neither a passing verification record nor a defer record",
			" — record a verification (sprint_record_verification) or a typed defer",
			" (sprint_update note with defer_type)",
		})
		for task in uncovered {
			delete(task, a)
		}
		delete(uncovered)
		return {}, err
	}
	delete(uncovered)
	// The outcome is a long-form field like every other: the cap refusal
	// belongs here, before the mint, not as a chunk-write storage error
	// afterwards. Empty stays legal — revision comes via sprint_update.
	if outcome_md != "" && strings.trim_space(outcome_md) == "" {
		return {}, inv(a, "outcome is whitespace-only (pass empty to clear it)")
	}
	if verr := validate_body(outcome_md, "outcome", a); verr != nil {
		return {}, verr
	}
	data := Sprint_Closed_Data{outcome_md = outcome_md}
	if aerr := mint_and_append(m, .Sprint_Closed, encode_sprint_closed(&data, a), a); aerr != nil {
		return {}, aerr
	}

	// The close event has folded: the window is [started, closed_ms] and
	// the cohort statistics below are the final filing-time view.
	st := sprint_stats(&m.state, active, a)
	stats := close_stats_text(st, a)
	sprint_stats_destroy(st, a)
	free(st, a)
	passed, must_total := must_verif_summary(active)
	if must_total > 0 {
		stats = strings.concatenate({
			stats, "\nmust: ", dec(passed), "/", dec(must_total), " verified",
		}, a)
	}
	def_total, open_q := sprint_defer_stats(&m.state, active)
	if def_total > 0 {
		stats = strings.concatenate({
			stats, "\ndefers: ", dec(def_total), " filed (", dec(open_q), " open questions)",
		}, a)
	}
	// The stored report row is a derived cache refreshed best-effort: the
	// close is already committed, a store failure never surfaces, and
	// tracker_export regenerates the row on demand.
	report := sprint_report(&m.state, active, manager_fetch_payload, m, a)
	_ = store.sprint_report_put(m.db, active.id, report, platform.wall_ms())
	return Close_Result{
		id         = strings.clone(active.id, a),
		name       = strings.clone(active.name, a),
		stats_text = stats,
	}, nil
}

// manager_update_sprint validates every requested change against the
// sprint and commits them in one call: goal/note need an active sprint,
// outcome needs a closed one.
manager_update_sprint :: proc(m: ^Manager, target: string, su: ^Sprint_Update, a: mem.Allocator) -> (changed: []string, id: string, err: platform.Err) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)

	spr := sprint_by_id(&m.state, target)
	if spr == nil {
		return nil, "", err_sprint_not_found(a, target)
	}
	// Validate every requested section BEFORE any mint: the tool contract
	// is atomically-or-none, and a rejection after an earlier section's
	// event landed would leave a committed half of the call behind (the
	// two-phase order manager_update_incident documents).
	if su.goal_set || su.must_set {
		if gerr := sprint_state_gate(spr, .Goal_Edit, a); gerr != nil {
			return nil, "", gerr
		}
		if su.goal_set {
			if su.goal != "" && strings.trim_space(su.goal) == "" {
				return nil, "", inv(a, "goal is whitespace-only (pass empty to clear it)")
			}
			if verr := validate_body(su.goal, "goal", a); verr != nil {
				return nil, "", verr
			}
		}
		if su.must_set {
			if verr := validate_must_tasks(su.must, a); verr != nil {
				return nil, "", verr
			}
		}
	}
	defer_id := ""
	note_data: Sprint_Note_Appended_Data
	if su.note_set {
		if gerr := sprint_state_gate(spr, .Note, a); gerr != nil {
			return nil, "", gerr
		}
		if su.defer_type != "" {
			defer_id = fmt.aprintf("DEF-%03d", m.state.defer_count + 1, allocator = a)
		}
		nd, nerr := build_sprint_note_data(&m.state, spr, su, defer_id, a)
		if nerr != nil {
			return nil, "", nerr
		}
		note_data = nd
	}
	if su.outcome_set {
		if gerr := sprint_state_gate(spr, .Outcome, a); gerr != nil {
			return nil, "", gerr
		}
		if su.outcome != "" && strings.trim_space(su.outcome) == "" {
			return nil, "", inv(a, "outcome is whitespace-only (pass empty to clear it)")
		}
		if verr := validate_body(su.outcome, "outcome", a); verr != nil {
			return nil, "", verr
		}
	}

	changed_dyn := make([dynamic]string, 0, 3, a)
	record :: proc(list: ^[dynamic]string, part: string, a: mem.Allocator) {
		append(list, strings.clone(part, a))
	}
	// Mints run only after every present section validated; the mutex is
	// held throughout, so the pre-computed defer_id cannot drift.
	if su.goal_set || su.must_set {
		data := Sprint_Goal_Updated_Data{target = spr.id}
		if su.goal_set {
			data.goal_md = su.goal
			data.goal_set = true
		}
		if su.must_set {
			data.must = su.must
			data.must_set = true
		}
		if aerr := mint_and_append(m, .Sprint_Goal_Updated, encode_sprint_goal_updated(&data, a), a); aerr != nil {
			return nil, "", aerr
		}
		if su.goal_set {
			record(&changed_dyn, "goal", a)
		}
		if su.must_set {
			record(&changed_dyn, "must", a)
		}
	}
	if su.note_set {
		if aerr := mint_and_append(m, .Sprint_Note_Appended, encode_sprint_note_appended(&note_data, a), a); aerr != nil {
			return nil, "", aerr
		}
		if su.defer_type != "" {
			record(&changed_dyn, strings.concatenate({"defer ", defer_id, " (", su.defer_type, ")"}, a), a)
		} else if su.resolves != "" {
			record(&changed_dyn, strings.concatenate({"answered ", su.resolves}, a), a)
		} else {
			record(&changed_dyn, "note", a)
		}
	}
	if su.outcome_set {
		data := Sprint_Outcome_Updated_Data{target = spr.id, outcome_md = su.outcome}
		if aerr := mint_and_append(m, .Sprint_Outcome_Updated, encode_sprint_outcome_updated(&data, a), a); aerr != nil {
			return nil, "", aerr
		}
		record(&changed_dyn, "outcome", a)
	}
	owned := make([]string, len(changed_dyn), a)
	for c, i in changed_dyn {
		owned[i] = c
	}
	delete(changed_dyn)
	return owned, strings.clone(spr.id, a), nil
}

Verif_Result :: struct {
	sprint_id: string,
	task:      string,
	outcome:   string,
}

// manager_record_verification files one verification record on the active
// sprint — the server-held evidence behind a task's derived "verified"
// state. The output field is required (refusal-style): a record without the
// executed definition's output is refused at the gate below.
manager_record_verification :: proc(
	m: ^Manager,
	task, definition, outcome, output, session: string,
	a: mem.Allocator,
) -> (Verif_Result, platform.Err) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)

	active := active_sprint(&m.state)
	if active == nil {
		return {}, inv(a, "no active sprint to record a verification on")
	}
	data, verr := build_task_verified_data(active, task, definition, outcome, output, session, a)
	if verr != nil {
		return {}, verr
	}
	if aerr := mint_and_append(m, .Sprint_Task_Verified, encode_sprint_task_verified(&data, a), a); aerr != nil {
		return {}, aerr
	}
	return Verif_Result{
		sprint_id = strings.clone(active.id, a),
		task      = strings.clone(data.task, a),
		outcome   = strings.clone(data.outcome, a),
	}, nil
}

// --- reads (rendered under the lock; nothing borrowed escapes) -------------

manager_list_incidents :: proc(m: ^Manager, f: ^Incident_Filter, now_ms: i64, a: mem.Allocator) -> (string, platform.Err) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	return render_incident_list(&m.state, f, now_ms, a)
}

manager_get_incident :: proc(m: ^Manager, id: string, max_chars: int, a: mem.Allocator) -> (string, platform.Err) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	h := incident_by_id(&m.state, id)
	if h == nil {
		return "", err_incident_not_found(a, id)
	}
	return detail_incident(&m.state, h, manager_fetch_payload, m, max_chars, a), nil
}

manager_list_sprints :: proc(m: ^Manager, include_closed: bool, limit: int, now_ms: i64, a: mem.Allocator) -> (string, platform.Err) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	return sprint_list(&m.state, manager_fetch_payload, m, include_closed, limit, now_ms, a), nil
}

manager_get_sprint :: proc(m: ^Manager, id: string, max_chars: int, a: mem.Allocator) -> (string, platform.Err) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	spr, err := resolve_sprint(&m.state, id, a)
	if err != nil {
		return "", err
	}
	return detail_sprint(&m.state, spr, manager_fetch_payload, m, max_chars, a), nil
}

// manager_incident_status is the cheap pre-read the update ack uses to
// render the status transition (before → after) without a detail render.
manager_incident_status :: proc(m: ^Manager, id: string, a: mem.Allocator) -> (string, platform.Err) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	h := incident_by_id(&m.state, id)
	if h == nil {
		return "", err_incident_not_found(a, id)
	}
	return strings.clone(h.status, a), nil
}

// manager_active_sprint_id resolves the "current" reference the tool
// layer hands through: false means no active sprint (the caller turns
// that into the no-active-sprint refusal).
manager_active_sprint_id :: proc(m: ^Manager, a: mem.Allocator) -> (string, bool) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	spr := active_sprint(&m.state)
	if spr == nil {
		return "", false
	}
	return strings.clone(spr.id, a), true
}

manager_open_summary :: proc(m: ^Manager, now_ms: i64, a: mem.Allocator) -> string {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	return render_open_summary(&m.state, now_ms, a)
}

manager_counts :: proc(m: ^Manager) -> Counts {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	c: Census
	for uid in m.state.incident_order {
		h := m.state.incidents[uid]
		if h != nil && !h.is_deleted {
			census_add(&c, h)
		}
	}
	return c.counts
}

// resolve_sprint maps an ID (or "current") to its header; borrowed,
// valid while the manager lock is held.
resolve_sprint :: proc(s: ^Fold_State, id: string, a: mem.Allocator) -> (^Sprint_Header, platform.Err) {
	if id == "current" {
		active := active_sprint(s)
		if active == nil {
			return nil, inv(a, "no active sprint")
		}
		return active, nil
	}
	spr := sprint_by_id(s, id)
	if spr == nil {
		return nil, err_sprint_not_found(a, id)
	}
	return spr, nil
}

// manager_export renders the derived sprint reports into the tracker
// store: one sprint's report, or every sprint's. Storing reports as
// sprint_reports rows keeps the project tree free of per-sprint
// artifacts; the event log stays the source of truth and re-export
// overwrites the rows.
manager_export :: proc(m: ^Manager, sprint_id: string, a: mem.Allocator) -> (ack: string, err: platform.Err) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)

	if sprint_id != "" {
		spr, rerr := resolve_sprint(&m.state, sprint_id, a)
		if rerr != nil {
			return "", rerr
		}
		report := sprint_report(&m.state, spr, manager_fetch_payload, m, a)
		if perr := store.sprint_report_put(m.db, spr.id, report, platform.wall_ms()); perr != nil {
			return "", perr
		}
		st := sprint_stats(&m.state, spr, a)
		ack = strings.concatenate({
			"Exported ", spr.id, " report to the tracker store (",
			dec(st.total), " filed)",
		}, a)
		// The stats are always computed live into `a`; drop the deep parts.
		sprint_stats_destroy(st, a)
		free(st, a)
		return ack, nil
	}

	exported := 0
	for id in m.state.sprint_order {
		spr := sprint_by_id(&m.state, id)
		if spr == nil {
			continue
		}
		report := sprint_report(&m.state, spr, manager_fetch_payload, m, a)
		if perr := store.sprint_report_put(m.db, spr.id, report, platform.wall_ms()); perr != nil {
			return "", perr
		}
		exported += 1
	}
	ack = strings.concatenate({
		"Exported ", dec(exported), " sprint reports to the tracker store",
	}, a)
	return ack, nil
}

// manager_render_incident_report renders matched headers as TSV or JSON
// (the structured report behind the CLI; reports are consumed whole, so
// the filter's limit is ignored).
manager_render_incident_report :: proc(
	m: ^Manager,
	f: ^Incident_Filter,
	format: Report_Format,
	a: mem.Allocator,
) -> (string, platform.Err) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	f.limit = -1
	live := live_incidents(&m.state, a)
	defer delete(live, a)
	matched, err := matched_incidents(&m.state, f, live[:], a)
	if err != nil {
		return "", err
	}
	defer delete(matched, a)
	return report_incidents(format, matched[:], a), nil
}
