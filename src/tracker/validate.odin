package tracker

// Write-path preconditions and gate checks. Everything here runs under
// the manager's write lock against the fold state. Error messages are
// cloned into the caller's error allocator (the request arena at the
// daemon boundary) — a returned platform.Err must outlive the builder.
// The builder payloads borrow the caller's input strings; the manager
// serializes them into the per-event arena at mint time.

import "core:mem"
import "core:strings"
import "src:platform"
import "src:util"

// Long-form fields cannot exceed the serialized event budget.
EVENT_BODY_CAP :: 1 << 20

Fields_Update :: struct {
	priority:       string,
	priority_set:   bool,
	labels:         []string,
	labels_set:     bool,
	sprint:         string, // "" = backlog; the tool layer resolves "current" first
	sprint_set:     bool,
	blocked_by:     []string,
	blocked_by_set: bool,
	assignee:       string,
	assignee_set:   bool,
	aliases:        []string,
	aliases_set:    bool,
}

Create_Input :: struct {
	title:      string,
	priority:   string,
	labels:     []string,
	sprint:     string,
	blocked_by: []string,
	assignee:   string,
	aliases:    []string,
	created_by: string,
	body_md:    string,
}

Status_Change :: struct {
	to:          string,
	resolution:  string,
	evidence_md: string,
}

// Update_Input is the composite payload: each set field becomes one
// event, validated in order against the projected state the previous
// steps produce. Fixed order: title, root cause, fields, status, note.
Update_Input :: struct {
	title:         string,
	title_set:     bool,
	root_cause:    string,
	root_cause_set: bool,
	fields:        Fields_Update,
	fields_set:    bool,
	status:        Status_Change,
	status_set:    bool,
	note:          string,
	note_set:      bool,
}

// Sprint_Update is the composite sprint payload: each set field becomes one
// event. A note may carry a typed defer record (defer_type + per-type
// fields) or resolve an open question (resolves); must replaces the
// structured must-task list alongside the goal.
Sprint_Update :: struct {
	goal:        string,
	goal_set:    bool,
	note:        string,
	note_set:    bool,
	outcome:     string,
	outcome_set: bool,
	defer_type:  string, // blocked|question|descope when the note is a defer
	defer_task:  string,
	defer_ref:   string,
	resolves:    string, // DEF-NNN of the open question this answers/descopes
	must:        []string,
	must_set:    bool,
}

@(private)
inv :: proc(a: mem.Allocator, msg: string) -> platform.Err {
	return platform.Wrapped{kind = .Invalid, msg = strings.clone(msg, a)}
}

@(private)
inv_cat :: proc(a: mem.Allocator, parts: []string) -> platform.Err {
	return platform.Wrapped{kind = .Invalid, msg = strings.concatenate(parts, a)}
}

@(private)
err_incident_not_found :: proc(a: mem.Allocator, id: string) -> platform.Err {
	return inv_cat(a, {"incident ", id, " not found"})
}

@(private)
err_sprint_not_found :: proc(a: mem.Allocator, id: string) -> platform.Err {
	return inv_cat(a, {"sprint ", id, " not found"})
}

must_incident :: proc(s: ^Fold_State, id: string, a: mem.Allocator) -> (^Incident_Header, platform.Err) {
	h := incident_by_id(s, id)
	if h == nil {
		return nil, err_incident_not_found(a, id)
	}
	return h, nil
}

mutable_incident :: proc(s: ^Fold_State, id: string, a: mem.Allocator) -> (^Incident_Header, platform.Err) {
	h, err := must_incident(s, id, a)
	if err != nil {
		return nil, err
	}
	if h.is_deleted {
		return nil, inv_cat(a, {"incident ", h.id, " is deleted"})
	}
	return h, nil
}

// validate_sprint_ref accepts "" (backlog) or the active sprint.
validate_sprint_ref :: proc(s: ^Fold_State, sprint_id: string, a: mem.Allocator) -> platform.Err {
	if sprint_id == "" {
		return nil
	}
	spr := sprint_by_id(s, sprint_id)
	if spr == nil {
		return inv_cat(a, {"sprint ", sprint_id, " not found"})
	}
	if spr.status != .Active {
		return inv_cat(a, {"sprint ", sprint_id, " is closed"})
	}
	return nil
}

// Sprint_Op names the sprint operations gated by the sprint's state;
// SPRINT_OP_STATUS is the gate table, one required state per operation.
Sprint_Op :: enum {
	Goal_Edit, // goal or must-task list revision
	Note,      // note append (typed defers included)
	Outcome,   // outcome revision on a closed sprint
}

SPRINT_OP_STATUS :: [Sprint_Op]Sprint_Status{
	.Goal_Edit = .Active,
	.Note      = .Active,
	.Outcome   = .Closed,
}

// sprint_state_gate rejects an operation whose required sprint state
// (SPRINT_OP_STATUS) disagrees with the sprint's current state.
sprint_state_gate :: proc(spr: ^Sprint_Header, op: Sprint_Op, a: mem.Allocator) -> platform.Err {
	table := SPRINT_OP_STATUS
	if spr.status == table[op] {
		return nil
	}
	if table[op] == .Active {
		return inv_cat(a, {"sprint ", spr.id, " is closed"})
	}
	return inv_cat(a, {"sprint ", spr.id, " is still active"})
}

// validate_aliases enforces global uniqueness, excluding the owner's own
// registrations (owner == nil during create: nothing is owned yet).
validate_aliases :: proc(s: ^Fold_State, aliases: []string, owner: ^Incident_Header, a: mem.Allocator) -> platform.Err {
	for alias in aliases {
		if alias == "" {
			return inv(a, "alias must not be empty")
		}
		if strings.contains_any(alias, "\n\r") {
			return inv_cat(a, {"alias ", alias, " must be a single line"})
		}
		if rune_len(alias) > 64 {
			return inv_cat(a, {"alias ", alias, " exceeds 64 characters"})
		}
		holder, taken := s.aliases[alias]
		if taken && holder != owner {
			other_id := "?"
			if holder != nil {
				other_id = holder.id
			}
			return inv_cat(a, {"alias ", alias, " already used by ", other_id})
		}
	}
	return nil
}

// validate_blocked_targets checks target existence, aliveness, and
// cycle-freedom for the would-be edges of self ("" during create — no
// cycles possible, the incident does not exist yet).
validate_blocked_targets :: proc(s: ^Fold_State, self: string, targets: []string, a: mem.Allocator) -> platform.Err {
	for t in targets {
		target, err := must_incident(s, t, a)
		if err != nil {
			return err
		}
		if target.is_deleted {
			return inv_cat(a, {"cannot block on ", target.id, ": it is deleted"})
		}
		if self != "" && target.id == self {
			return inv_cat(a, {self, " cannot block itself"})
		}
		if self != "" && dag_would_create_cycle(&s.dag, self, target.id) {
			return inv_cat(a, {"blocked_by ", target.id, " would create a cycle"})
		}
	}
	return nil
}

validate_title :: proc(title: string, a: mem.Allocator) -> (string, platform.Err) {
	trimmed := strings.trim_space(title)
	if trimmed == "" {
		return "", inv(a, "title must not be empty")
	}
	if strings.contains_any(trimmed, "\n\r") {
		return "", inv(a, "title must be a single line")
	}
	if rune_len(trimmed) > 120 {
		return "", inv(a, "title must be at most 120 characters")
	}
	return trimmed, nil
}

validate_short :: proc(s: string, field: string, a: mem.Allocator) -> platform.Err {
	if strings.contains_any(s, "\n\r") {
		return inv_cat(a, {field, " must be a single line"})
	}
	if rune_len(s) > 64 {
		return inv_cat(a, {field, " must be at most 64 characters"})
	}
	return nil
}

// validate_body rejects long-form fields that can never fit a single
// serialized event; without it the mint succeeds and the failure surfaces
// at chunk write time as a storage error instead of a field-specific one.
validate_body :: proc(s: string, field: string, a: mem.Allocator) -> platform.Err {
	if len(s) > EVENT_BODY_CAP {
		return inv_cat(a, {field, " is too large (", util.int_to_dec(len(s), a), " bytes); maximum is ", util.int_to_dec(EVENT_BODY_CAP, a), " bytes)"})
	}
	return nil
}

validate_priority :: proc(p: string, a: mem.Allocator) -> platform.Err {
	for pl in Priority {
		if p == priority_string(pl) {
			return nil
		}
	}
	return inv_cat(a, {"priority must be one of ", util.wire_names(Priority, priority_string, "|", "'", a), ", got: ", p, " (map Critical/Blocker to urgent)"})
}

// The statuses change_status accepts — a deliberate subset of
// Incident_Status. The tool layer refuses resolved before the manager
// (resolve owns it); change_status accepting it is resolve's
// implementation surface. Rejected is verify's alone.
SETTABLE_STATUSES :: []Incident_Status{.Reported, .Confirmed, .Root_Caused, .Resolved}

validate_status_value :: proc(s: string, a: mem.Allocator) -> platform.Err {
	for st in SETTABLE_STATUSES {
		if s == incident_status_string(st) {
			return nil
		}
	}
	names := make([dynamic]string, 0, len(SETTABLE_STATUSES), context.temp_allocator)
	defer delete(names)
	for st in SETTABLE_STATUSES {
		append(&names, incident_status_string(st))
	}
	return inv_cat(a, {"status must be one of ", util.quoted_join(names[:], "|", "'", a), ", got: ", s})
}

// set_by renders the competing-writer attribution suffix.
set_by :: proc(h: ^Incident_Header, a: mem.Allocator) -> string {
	if h.last_status.origin == "" && h.last_status.ts_ms == 0 {
		return ""
	}
	ts := ts_iso_utc(h.last_status.ts_ms, context.temp_allocator)
	buf: [8]string
	buf[0] = " (set by "
	buf[1] = event_kind_string(h.last_status.kind)
	buf[2] = " at "
	buf[3] = ts
	buf[4] = ", origin "
	buf[5] = h.last_status.origin
	buf[6] = ")"
	return strings.concatenate(buf[:7], a)
}

// check_g1 rejects work transitions from unverified states.
check_g1 :: proc(h: ^Incident_Header, to: string, a: mem.Allocator) -> platform.Err {
	if verified_state(h.status) {
		return nil
	}
	if status_is_terminal(h.status) {
		return inv_cat(a, {"cannot move ", h.id, " to ", to, ": status is ", h.status, set_by(h, a), " — reopen first"})
	}
	return inv_cat(a, {"cannot move ", h.id, " to ", to, ": status is ", h.status, set_by(h, a), " — use incident_verify first"})
}

// check_transition validates a status change against the transition
// table, attributing rejections to the writer of the current status.
check_transition :: proc(h: ^Incident_Header, to: string, a: mem.Allocator) -> platform.Err {
	if h.status == to {
		return inv_cat(a, {h.id, " is already in status ", h.status, set_by(h, a)})
	}
	if transition_legal(h.status, to) {
		return nil
	}
	if to == incident_status_string(.Resolved) && !verified_state(h.status) {
		return check_g1(h, to, a)
	}
	if to == incident_status_string(.Resolved) {
		return inv_cat(a, {"cannot resolve ", h.id, " in status ", h.status, set_by(h, a), ": record the root cause first (root_cause), then resolve"})
	}
	if to == incident_status_string(.Root_Caused) && !verified_state(h.status) {
		return check_g1(h, to, a)
	}
	if to == incident_status_string(.Root_Caused) {
		return inv_cat(a, {"cannot move ", h.id, " to root_caused: record the root cause with root_cause (incident_update)"})
	}
	return inv_cat(a, {"illegal transition ", h.status, " → ", to})
}

// dedup_sorted returns the deduplicated, sorted copy owned by `a`.
dedup_sorted :: proc(list: []string, a: mem.Allocator) -> []string {
	dyn := make([dynamic]string, 0, len(list), a)
	for s in list {
		dup := false
		for existing in dyn {
			if existing == s {
				dup = true
				break
			}
		}
		if !dup {
			append(&dyn, strings.clone(s, a))
		}
	}
	for i in 1..<len(dyn) {
		j := i
		for j > 0 && dyn[j-1] > dyn[j] {
			dyn[j-1], dyn[j] = dyn[j], dyn[j-1]
			j -= 1
		}
	}
	out := make([]string, len(dyn), a)
	for v, i in dyn {
		out[i] = v
	}
	delete(dyn)
	return out
}

rune_len :: proc(s: string) -> int {
	n := 0
	for i in 0..<len(s) {
		if s[i] & 0xC0 != 0x80 {
			n += 1
		}
	}
	return n
}

// --- event builders -------------------------------------------------------
// Shared by the single-op write APIs and the composite update: each
// validates against the header it is given — the live one for single
// ops, the projected one inside a composite — and shapes the payload.
// The two paths must never diverge. Payload strings borrow the inputs;
// the manager serializes them before returning.

build_title_data :: proc(h: ^Incident_Header, title: string, a: mem.Allocator) -> (Incident_Title_Changed_Data, platform.Err) {
	trimmed, err := validate_title(title, a)
	if err != nil {
		return {}, err
	}
	return {target = h.id, title = trimmed}, nil
}

build_root_cause_data :: proc(h: ^Incident_Header, cause_md: string, a: mem.Allocator) -> (Incident_Root_Caused_Data, platform.Err) {
	if strings.trim_space(cause_md) == "" {
		return {}, inv(a, "root_cause requires cause_md")
	}
	if err := validate_body(cause_md, "cause_md", a); err != nil {
		return {}, err
	}
	if err := check_g1(h, incident_status_string(.Root_Caused), a); err != nil {
		return {}, err
	}
	return {target = h.id, cause_md = cause_md}, nil
}

build_status_change_data :: proc(
	s: ^Fold_State,
	h: ^Incident_Header,
	sc: Status_Change,
	a: mem.Allocator,
) -> (Incident_Status_Changed_Data, platform.Err) {
	to := sc.to
	if to == incident_status_string(.Rejected) {
		return {}, inv(a, "cannot set status to rejected: use incident_verify with verdict=rejected")
	}
	if err := validate_status_value(to, a); err != nil {
		return {}, err
	}
	if err := check_transition(h, to, a); err != nil {
		return {}, err
	}
	if to == incident_status_string(.Resolved) {
		if sc.resolution == "" {
			return {}, inv_cat(a, {"resolving requires a resolution: ", util.wire_names(Resolution, resolution_string, "|", "'", a)})
		}
		known := false
		for r in Resolution {
			if sc.resolution == resolution_string(r) {
				known = true
				break
			}
		}
		if !known {
			return {}, inv_cat(a, {"resolution must be one of ", util.wire_names(Resolution, resolution_string, "|", "'", a), ", got: ", sc.resolution})
		}
		if strings.trim_space(sc.evidence_md) == "" {
			return {}, inv(a, "resolving requires evidence_md (commit hash + tests)")
		}
		if err := validate_body(sc.evidence_md, "evidence_md", a); err != nil {
			return {}, err
		}
	}
	return {
		target      = h.id,
		from        = h.status,
		to          = to,
		resolution  = sc.resolution,
		evidence_md = sc.evidence_md,
	}, nil
}

build_fields_data :: proc(
	s: ^Fold_State,
	h: ^Incident_Header,
	up: Fields_Update,
	a: mem.Allocator,
) -> (Incident_Fields_Changed_Data, platform.Err) {
	data: Incident_Fields_Changed_Data
	data.target = h.id
	if up.priority_set {
		if err := validate_priority(up.priority, a); err != nil {
			return {}, err
		}
		data.priority = up.priority
		data.priority_set = true
	}
	if up.labels_set {
		labels, ok := normalize_labels(up.labels, a)
		if !ok {
			return {}, inv(a, "invalid label: must match [a-z0-9][a-z0-9_-]{0,31}")
		}
		data.labels = labels
		data.labels_set = true
	}
	if up.sprint_set {
		if err := validate_sprint_ref(s, up.sprint, a); err != nil {
			return {}, err
		}
		data.sprint = up.sprint
		data.sprint_set = true
	}
	if up.blocked_by_set {
		if err := validate_blocked_targets(s, h.id, up.blocked_by, a); err != nil {
			return {}, err
		}
		sorted := dedup_sorted(up.blocked_by, a)
		data.blocked_by = sorted
		data.blocked_by_set = true
	}
	if up.assignee_set {
		if err := validate_short(up.assignee, "assignee", a); err != nil {
			return {}, err
		}
		data.assignee = up.assignee
		data.assignee_set = true
	}
	if up.aliases_set {
		if err := validate_aliases(s, up.aliases, h, a); err != nil {
			return {}, err
		}
		data.aliases = dedup_sorted(up.aliases, a)
		data.aliases_set = true
	}
	return data, nil
}

build_note_data :: proc(h: ^Incident_Header, body_md: string, a: mem.Allocator) -> (Incident_Note_Appended_Data, platform.Err) {
	if strings.trim_space(body_md) == "" {
		return {}, inv(a, "note requires body_md")
	}
	if err := validate_body(body_md, "note body_md", a); err != nil {
		return {}, err
	}
	return {target = h.id, body_md = body_md}, nil
}

// --- sprint builders --------------------------------------------------------

// validate_must_tasks checks the structured must list: stable single-line
// task IDs, no duplicates, bounded. Order mirrors the goal's task table and
// is preserved (never sorted).
validate_must_tasks :: proc(tasks: []string, a: mem.Allocator) -> platform.Err {
	if len(tasks) > 64 {
		return inv_cat(a, {"must list exceeds 64 tasks, got: ", util.int_to_dec(len(tasks), a)})
	}
	for task, i in tasks {
		if task == "" {
			return inv(a, "must list contains an empty task ID")
		}
		if strings.contains_any(task, "\n\r") {
			return inv(a, "must task IDs must be single-line")
		}
		if rune_len(task) > 64 {
			return inv_cat(a, {"must task ID ", task, " exceeds 64 characters"})
		}
		for j in 0..<i {
			if tasks[j] == task {
				return inv_cat(a, {"must task ID ", task, " is listed twice"})
			}
		}
	}
	return nil
}

// build_sprint_note_data shapes a decision note, which may be plain, a typed
// defer record, or the answer to an open question. Refusal-style: a blocked
// defer requires ref, a defer covering a must task carries its task ID, and
// resolves only lands on an open question defer.
build_sprint_note_data :: proc(
	s: ^Fold_State,
	spr: ^Sprint_Header,
	up: ^Sprint_Update,
	defer_id: string,
	a: mem.Allocator,
) -> (Sprint_Note_Appended_Data, platform.Err) {
	if strings.trim_space(up.note) == "" {
		return {}, inv(a, "note requires body_md")
	}
	if err := validate_body(up.note, "note body_md", a); err != nil {
		return {}, err
	}
	data := Sprint_Note_Appended_Data{target = spr.id, body_md = up.note}
	if up.defer_type != "" {
		kind, known := defer_kind_from_string(up.defer_type)
		if !known {
			return {}, inv_cat(a, {"defer_type must be one of ", util.wire_names(Defer_Kind, defer_kind_string, "|", "'", a), ", got: ", up.defer_type})
		}
		data.defer_type = defer_kind_string(kind)
		data.defer_id = defer_id
		if kind == .Blocked {
			if up.defer_ref == "" {
				return {}, inv(a, "a blocked defer requires ref (the blocking problem or dependency)")
			}
			if err := validate_short(up.defer_ref, "ref", a); err != nil {
				return {}, err
			}
			data.ref = up.defer_ref
		} else if up.defer_ref != "" {
			return {}, inv(a, "ref applies only to blocked defers")
		}
		if up.defer_task != "" {
			if err := validate_short(up.defer_task, "task", a); err != nil {
				return {}, err
			}
			data.task = up.defer_task
		}
		if kind == .Question && up.resolves != "" {
			return {}, inv(a, "a question defer cannot resolve another question")
		}
		if kind == .Blocked && up.resolves != "" {
			return {}, inv(a, "a blocked defer cannot resolve a question")
		}
	} else {
		if up.defer_task != "" {
			return {}, inv(a, "task applies only to typed defers")
		}
		if up.defer_ref != "" {
			return {}, inv(a, "ref applies only to blocked defers")
		}
	}
	if up.resolves != "" {
		target := defer_by_id(s, up.resolves)
		if target == nil || target.kind != defer_kind_string(.Question) || target.resolved_ms != 0 {
			return {}, inv_cat(a, {"resolves ", up.resolves, " is not an open question defer"})
		}
		data.resolves = up.resolves
	}
	return data, nil
}

// build_task_verified_data shapes a verification record — refusal-style: the
// executed definition and its output are required fields, so a record
// without evidence of the run cannot be written.
build_task_verified_data :: proc(
	spr: ^Sprint_Header,
	task: string,
	definition: string,
	outcome: string,
	output: string,
	session: string,
	a: mem.Allocator,
) -> (Sprint_Task_Verified_Data, platform.Err) {
	if task == "" {
		return {}, inv(a, "a verification record requires task (the task-table row ID)")
	}
	if err := validate_short(task, "task", a); err != nil {
		return {}, err
	}
	if definition == "" {
		return {}, inv(a, "a verification record requires definition (the versioned verification asset that was executed)")
	}
	if err := validate_short(definition, "definition", a); err != nil {
		return {}, err
	}
	o, known := verif_outcome_from_string(outcome)
	if !known {
		return {}, inv_cat(a, {"outcome must be 'passed'|'failed', got: ", outcome})
	}
	if strings.trim_space(output) == "" {
		return {}, inv(a, "a verification record requires output — attach the executed definition's output")
	}
	if err := validate_body(output, "output", a); err != nil {
		return {}, err
	}
	if session != "" {
		if err := validate_short(session, "session", a); err != nil {
			return {}, err
		}
	}
	return {
		target     = spr.id,
		task       = task,
		definition = definition,
		outcome    = verif_outcome_string(o),
		output     = output,
		session    = session,
	}, nil
}

// --- projections for the composite update ---------------------------------
// Advance a composite's projected header past each step so later gates
// see the composite's own changes. The projections mirror the fold's
// status halves; tests force them to agree with the fold handlers.

project_root_cause :: proc(proj: ^Incident_Header) {
	proj.status = incident_status_string(.Root_Caused)
}

project_status :: proc(proj: ^Incident_Header, to: string) {
	proj.status = to
}

project_fields :: proc(proj: ^Incident_Header, data: ^Incident_Fields_Changed_Data) {
	if data.priority_set {
		proj.priority = data.priority
	}
	if data.labels_set {
		proj.labels = data.labels
	}
	if data.sprint_set {
		proj.sprint = data.sprint
	}
	if data.blocked_by_set {
		proj.blocked_by = data.blocked_by
	}
	if data.assignee_set {
		proj.assignee = data.assignee
	}
	if data.aliases_set {
		proj.aliases = data.aliases
	}
}

// clone_header_shallow copies a header for composite projection. Strings
// are borrowed (the projection only reassigns fields; the manager
// serializes payloads before the borrows go away).
clone_header_shallow :: proc(h: ^Incident_Header, a: mem.Allocator) -> ^Incident_Header {
	proj := new(Incident_Header, a)
	proj^ = h^
	return proj
}
