package tracker

// Event vocabulary of the incident/sprint tracker: the 14 event kinds, the
// closed status/verdict/resolution/fp-pattern/priority/defer/outcome
// vocabularies, the
// wire-shaped payload structs with their decoders, and event-UID handling.
// Decoding follows the original unmarshal semantics: a missing key decodes
// to the zero value (the fold treats the result as an anomaly), while a
// value of the wrong JSON shape fails the decode with a reason. Decode
// failures are anomaly reasons, never panics — the fold never dies.

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "src:jsonutil"
import "src:store"
import "src:util"

EVENT_SCHEMA_VERSION :: int(1)

// ---------------------------------------------------------------------------
// Event kinds

Event_Kind :: enum {
	Incident_Created,
	Incident_Title_Changed,
	Incident_Verified,
	Incident_Root_Caused,
	Incident_Status_Changed,
	Incident_Fields_Changed,
	Incident_Note_Appended,
	Incident_Deleted,
	Sprint_Started,
	Sprint_Closed,
	Sprint_Goal_Updated,
	Sprint_Note_Appended,
	Sprint_Outcome_Updated,
	Sprint_Task_Verified,
}

event_kind_string :: proc(kind: Event_Kind) -> string {
	switch kind {
	case .Incident_Created:       return "incident.created"
	case .Incident_Title_Changed: return "incident.title_changed"
	case .Incident_Verified:      return "incident.verified"
	case .Incident_Root_Caused:   return "incident.root_caused"
	case .Incident_Status_Changed: return "incident.status_changed"
	case .Incident_Fields_Changed: return "incident.fields_changed"
	case .Incident_Note_Appended: return "incident.note_appended"
	case .Incident_Deleted:       return "incident.deleted"
	case .Sprint_Started:         return "sprint.started"
	case .Sprint_Closed:          return "sprint.closed"
	case .Sprint_Goal_Updated:    return "sprint.goal_updated"
	case .Sprint_Note_Appended:   return "sprint.note_appended"
	case .Sprint_Outcome_Updated: return "sprint.outcome_updated"
	case .Sprint_Task_Verified:  return "sprint.task_verified"
	}
	return "<invalid-kind>"
}

// The wire name is derived from event_kind_string — there is no second
// vocabulary to drift against it (the to_string switch is exhaustive, so
// the compiler forces every new kind to carry a wire name).
event_kind_from_string :: proc(s: string) -> (Event_Kind, bool) {
	for k in Event_Kind {
		if event_kind_string(k) == s {
			return k, true
		}
	}
	return .Incident_Created, false
}

// Kind_Meta drives every non-fold consumer: the fold's pre-apply snapshot
// (does the payload's target name an incident or a sprint), and the detail
// renderer's timeline (narrative kinds get sections). An unknown kind has
// zero meta — the fold flags it as an anomaly.
Kind_Meta :: struct {
	incident_target: bool,
	sprint_target:   bool,
	narrative:       bool,
}

kind_meta :: proc(kind: Event_Kind) -> Kind_Meta {
	switch kind {
	case .Incident_Verified, .Incident_Root_Caused, .Incident_Status_Changed, .Incident_Note_Appended:
		return {incident_target = true, narrative = true}
	case .Incident_Created, .Incident_Title_Changed, .Incident_Fields_Changed, .Incident_Deleted:
		return {incident_target = true}
	case .Sprint_Started, .Sprint_Closed, .Sprint_Goal_Updated, .Sprint_Note_Appended, .Sprint_Outcome_Updated,
	     .Sprint_Task_Verified:
		return {sprint_target = true}
	}
	return {}
}

// ---------------------------------------------------------------------------
// Closed vocabularies

// The Problem lifecycle is epistemics + disposition only — reported →
// confirmed|rejected (verify) → root_caused (root-cause record) → resolved
// (resolve with evidence), with reopen from the terminal states. Execution
// predicates never lived here: work state is derived from round artifacts
// (task tables, verification records, defers), not carried by problems.
Incident_Status :: enum {
	Reported,
	Confirmed,
	Root_Caused,
	Resolved,
	Rejected,
}

incident_status_string :: proc(s: Incident_Status) -> string {
	switch s {
	case .Reported:   return "reported"
	case .Confirmed:  return "confirmed"
	case .Root_Caused: return "root_caused"
	case .Resolved:   return "resolved"
	case .Rejected:   return "rejected"
	}
	return "<invalid-status>"
}

// Derived from incident_status_string — no second spelling table (the
// Event_Kind from_string pattern).
incident_status_from_string :: proc(s: string) -> (Incident_Status, bool) {
	for st in Incident_Status {
		if incident_status_string(st) == s {
			return st, true
		}
	}
	return .Reported, false
}

Verdict :: enum {
	Confirmed,
	Rejected,
}

verdict_string :: proc(v: Verdict) -> string {
	switch v {
	case .Confirmed: return "confirmed"
	case .Rejected:  return "rejected"
	}
	return "<invalid-verdict>"
}

Resolution :: enum {
	Fixed,
	Mitigated,
	Documented,
}

resolution_string :: proc(r: Resolution) -> string {
	switch r {
	case .Fixed:      return "fixed"
	case .Mitigated:  return "mitigated"
	case .Documented: return "documented"
	}
	return "<invalid-resolution>"
}

FP_Pattern :: enum {
	Untraced_Guard,
	Hallucinated,
	Spec,
	Threat_Model,
	Design_Intent,
}

fp_pattern_string :: proc(p: FP_Pattern) -> string {
	switch p {
	case .Untraced_Guard: return "untraced-guard"
	case .Hallucinated:   return "hallucinated"
	case .Spec:           return "spec"
	case .Threat_Model:   return "threat-model"
	case .Design_Intent:  return "design-intent"
	}
	return "<invalid-fp-pattern>"
}

// Like event_kind_from_string: the wire name is derived from
// fp_pattern_string — no second vocabulary to drift against it (the
// to_string switch is exhaustive, so the compiler forces every new
// pattern to carry a wire name).
fp_pattern_from_string :: proc(s: string) -> (FP_Pattern, bool) {
	for p in FP_Pattern {
		if fp_pattern_string(p) == s {
			return p, true
		}
	}
	return .Hallucinated, false
}

Priority :: enum {
	Urgent,
	High,
	Medium,
	Low,
}

priority_string :: proc(p: Priority) -> string {
	switch p {
	case .Urgent: return "urgent"
	case .High:   return "high"
	case .Medium: return "medium"
	case .Low:    return "low"
	}
	return "<invalid-priority>"
}

// A defer record types the reason work left the round: blocked (by a
// referenced obstacle), question (an unanswered question — the human
// intervention point), or descope (an explicit not-doing with a rationale).
Defer_Kind :: enum {
	Blocked,
	Question,
	Descope,
}

defer_kind_string :: proc(k: Defer_Kind) -> string {
	switch k {
	case .Blocked:  return "blocked"
	case .Question: return "question"
	case .Descope:  return "descope"
	}
	return "<invalid-defer-kind>"
}

defer_kind_from_string :: proc(s: string) -> (Defer_Kind, bool) {
	for k in Defer_Kind {
		if defer_kind_string(k) == s {
			return k, true
		}
	}
	return .Question, false
}

// The outcome of one executed verification definition. The task's derived
// state is the latest record's outcome — a failed re-run un-verifies.
Verif_Outcome :: enum {
	Passed,
	Failed,
}

verif_outcome_string :: proc(o: Verif_Outcome) -> string {
	switch o {
	case .Passed: return "passed"
	case .Failed: return "failed"
	}
	return "<invalid-outcome>"
}

verif_outcome_from_string :: proc(s: string) -> (Verif_Outcome, bool) {
	for o in Verif_Outcome {
		if verif_outcome_string(o) == s {
			return o, true
		}
	}
	return .Failed, false
}

// ---------------------------------------------------------------------------
// Envelope decoding

// Decoded_Event is one stored row validated at the envelope level. uid /
// origin / raw_kind are borrowed from the row (the caller owns the rows and
// they outlive the apply); payload allocations live in the caller's arena.
Decoded_Event :: struct {
	uid:      string,
	ts_ms:    i64,
	origin:   string,
	kind:     Event_Kind,
	kind_ok:  bool,
	raw_kind: string,
	payload:  json.Value,
}

// decode_event validates the envelope around one stored row: schema
// version, kind vocabulary, payload JSON. Failures are anomaly reasons
// ("" = ok), not errors — a foreign or future row must not kill the fold.
decode_event :: proc(row: ^store.Event_Row, a: mem.Allocator) -> (ev: Decoded_Event, reason: string) {
	if row.version > EVENT_SCHEMA_VERSION {
		return {}, fmt.aprintf(
			"event schema version %d exceeds supported (schema %d)",
			row.version, EVENT_SCHEMA_VERSION, allocator = a,
		)
	}
	kind, known := event_kind_from_string(row.kind)
	// Depth/encoding guard before the parser: a tampered payload row
	// must surface as an anomaly reason, not a crash.
	if !util.json_sanity_ok(transmute([]u8)row.payload) {
		return {}, "payload is not valid JSON"
	}
	parsed, perr := json.parse_string(row.payload, spec = .JSON, parse_integers = true, allocator = a)
	if perr != nil {
		return {}, "payload is not valid JSON"
	}
	return {
		uid      = row.uid,
		ts_ms    = row.ts,
		origin   = row.origin,
		kind     = kind,
		kind_ok  = known,
		raw_kind = row.kind,
		payload  = parsed,
	}, ""
}

// ---------------------------------------------------------------------------
// Payloads (wire-shaped; decode allocates in the caller's arena)

Incident_Created_Data :: struct {
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

Incident_Title_Changed_Data :: struct {
	target: string,
	title:  string,
}

Incident_Verified_Data :: struct {
	target:      string,
	verdict:     string,
	fp_pattern:  string,
	reason_md:   string,
	evidence_md: string,
}

Incident_Root_Caused_Data :: struct {
	target:   string,
	cause_md: string,
}

Incident_Status_Changed_Data :: struct {
	target:      string,
	from:        string,
	to:          string,
	resolution:  string,
	evidence_md: string,
}

// Full replacement of each present field (not a diff). created_by is not
// editable here. An empty sprint string means the backlog. Presence is the
// paired _set flag (the optional ?T type does not exist in this compiler).
Incident_Fields_Changed_Data :: struct {
	target:         string,
	priority:       string,
	priority_set:   bool,
	labels:         []string,
	labels_set:     bool,
	sprint:         string,
	sprint_set:     bool,
	blocked_by:     []string,
	blocked_by_set: bool,
	assignee:       string,
	assignee_set:   bool,
	aliases:        []string,
	aliases_set:    bool,
}

Incident_Note_Appended_Data :: struct {
	target:  string,
	body_md: string,
}

Incident_Deleted_Data :: struct {
	target:       string,
	reason:       string,
	duplicate_of: string,
}

// must is the round's structured must-task list (stable task-table row IDs
// mirrored from the goal document; presence is the paired _set flag). Close
// enforcement requires each of them to be verified or deferred.
Sprint_Started_Data :: struct {
	name:     string,
	goal_md:  string,
	follows:  string,
	must:     []string,
	must_set: bool,
}

Sprint_Closed_Data :: struct {
	outcome_md: string,
}

// Goal updates are partial: goal_md replaces the goal only when its key is
// present (empty string = explicit clear), must replaces the must-task list
// only when present. Presence is the paired _set flag.
Sprint_Goal_Updated_Data :: struct {
	target:   string,
	goal_md:  string,
	goal_set: bool,
	must:     []string,
	must_set: bool,
}

// A sprint note is either a plain decision note or a typed defer record /
// question answer. The defer fields are optional strings (empty = absent):
// defer_type carries the Defer_Kind vocabulary, task points at the
// task-table row the defer covers, ref is the blocked defer's obstacle
// reference (problem ID, dependency), and resolves names the open question
// defer (DEF-NNN) this record answers or descopes.
Sprint_Note_Appended_Data :: struct {
	target:     string,
	body_md:    string,
	defer_id:   string,
	defer_type: string,
	task:       string,
	ref:        string,
	resolves:   string,
}

Sprint_Outcome_Updated_Data :: struct {
	target:    string,
	outcome_md: string,
}

// One executed verification run of a round task: task (stable task-table row
// ID), definition (reference to the versioned verification asset — just
// recipe / script / CI job — that was executed), outcome, output (the
// required execution output digest — the write is refused without it), and
// the optional originating session label.
Sprint_Task_Verified_Data :: struct {
	target:     string,
	task:       string,
	definition: string,
	outcome:    string,
	output:     string,
	session:    string,
}

// ---------------------------------------------------------------------------
// Field decoders (missing key = zero value, wrong shape = reason)

@(private)
field_str :: proc(payload: json.Value, key: string, a: mem.Allocator) -> (out: string, reason: string) {
	v, found := jsonutil.obj_get(payload, key)
	if !found || v == nil {
		return "", ""
	}
	#partial switch x in v {
	case json.String:
		return strings.clone(string(x), a), ""
	case:
		return "", strings.concatenate({key, ": expected a string"}, context.temp_allocator)
	}
}

@(private)
field_str_array :: proc(payload: json.Value, key: string, a: mem.Allocator) -> (out: []string, reason: string) {
	v, found := jsonutil.obj_get(payload, key)
	if !found || v == nil {
		return nil, ""
	}
	#partial switch x in v {
	case json.Array:
		items, ok := jsonutil.as_array(v)
		if !ok {
			return nil, strings.concatenate({key, ": expected an array of strings"}, context.temp_allocator)
		}
		dyn := make([dynamic]string, 0, len(items), a)
		for item in items {
			#partial switch e in item {
			case json.String:
				append(&dyn, strings.clone(string(e), a))
			case:
				delete(dyn)
				return nil, strings.concatenate({key, ": expected an array of strings"}, context.temp_allocator)
			}
		}
		return dyn[:], ""
	case:
		return nil, strings.concatenate({key, ": expected an array of strings"}, context.temp_allocator)
	}
}

@(private)
field_opt_str :: proc(payload: json.Value, key: string, a: mem.Allocator) -> (out: string, set: bool, reason: string) {
	v, found := jsonutil.obj_get(payload, key)
	if !found || v == nil {
		return "", false, ""
	}
	s, r := field_str(payload, key, a)
	if r != "" {
		return "", false, r
	}
	return s, true, ""
}

@(private)
field_opt_str_array :: proc(payload: json.Value, key: string, a: mem.Allocator) -> (out: []string, set: bool, reason: string) {
	v, found := jsonutil.obj_get(payload, key)
	if !found || v == nil {
		return nil, false, ""
	}
	xs, r := field_str_array(payload, key, a)
	if r != "" {
		return nil, false, r
	}
	return xs, true, ""
}

decode_incident_created :: proc(payload: json.Value, a: mem.Allocator) -> (d: Incident_Created_Data, reason: string) {
	d.title, reason = field_str(payload, "title", a)
	if reason != "" do return
	d.priority, reason = field_str(payload, "priority", a)
	if reason != "" do return
	d.labels, reason = field_str_array(payload, "labels", a)
	if reason != "" do return
	d.sprint, reason = field_str(payload, "sprint", a)
	if reason != "" do return
	d.blocked_by, reason = field_str_array(payload, "blocked_by", a)
	if reason != "" do return
	d.assignee, reason = field_str(payload, "assignee", a)
	if reason != "" do return
	d.aliases, reason = field_str_array(payload, "aliases", a)
	if reason != "" do return
	d.created_by, reason = field_str(payload, "created_by", a)
	if reason != "" do return
	d.body_md, reason = field_str(payload, "body_md", a)
	return
}

decode_incident_title_changed :: proc(payload: json.Value, a: mem.Allocator) -> (d: Incident_Title_Changed_Data, reason: string) {
	d.target, reason = field_str(payload, "target", a)
	if reason != "" do return
	d.title, reason = field_str(payload, "title", a)
	return
}

decode_incident_verified :: proc(payload: json.Value, a: mem.Allocator) -> (d: Incident_Verified_Data, reason: string) {
	d.target, reason = field_str(payload, "target", a)
	if reason != "" do return
	d.verdict, reason = field_str(payload, "verdict", a)
	if reason != "" do return
	d.fp_pattern, reason = field_str(payload, "fp_pattern", a)
	if reason != "" do return
	d.reason_md, reason = field_str(payload, "reason_md", a)
	if reason != "" do return
	d.evidence_md, reason = field_str(payload, "evidence_md", a)
	return
}

decode_incident_root_caused :: proc(payload: json.Value, a: mem.Allocator) -> (d: Incident_Root_Caused_Data, reason: string) {
	d.target, reason = field_str(payload, "target", a)
	if reason != "" do return
	d.cause_md, reason = field_str(payload, "cause_md", a)
	return
}

decode_incident_status_changed :: proc(payload: json.Value, a: mem.Allocator) -> (d: Incident_Status_Changed_Data, reason: string) {
	d.target, reason = field_str(payload, "target", a)
	if reason != "" do return
	d.from, reason = field_str(payload, "from", a)
	if reason != "" do return
	d.to, reason = field_str(payload, "to", a)
	if reason != "" do return
	d.resolution, reason = field_str(payload, "resolution", a)
	if reason != "" do return
	d.evidence_md, reason = field_str(payload, "evidence_md", a)
	return
}

decode_incident_fields_changed :: proc(payload: json.Value, a: mem.Allocator) -> (d: Incident_Fields_Changed_Data, reason: string) {
	d.target, reason = field_str(payload, "target", a)
	if reason != "" do return
	d.priority, d.priority_set, reason = field_opt_str(payload, "priority", a)
	if reason != "" do return
	d.labels, d.labels_set, reason = field_opt_str_array(payload, "labels", a)
	if reason != "" do return
	d.sprint, d.sprint_set, reason = field_opt_str(payload, "sprint", a)
	if reason != "" do return
	d.blocked_by, d.blocked_by_set, reason = field_opt_str_array(payload, "blocked_by", a)
	if reason != "" do return
	d.assignee, d.assignee_set, reason = field_opt_str(payload, "assignee", a)
	if reason != "" do return
	d.aliases, d.aliases_set, reason = field_opt_str_array(payload, "aliases", a)
	return
}

decode_incident_note_appended :: proc(payload: json.Value, a: mem.Allocator) -> (d: Incident_Note_Appended_Data, reason: string) {
	d.target, reason = field_str(payload, "target", a)
	if reason != "" do return
	d.body_md, reason = field_str(payload, "body_md", a)
	return
}

decode_incident_deleted :: proc(payload: json.Value, a: mem.Allocator) -> (d: Incident_Deleted_Data, reason: string) {
	d.target, reason = field_str(payload, "target", a)
	if reason != "" do return
	d.reason, reason = field_str(payload, "reason", a)
	if reason != "" do return
	d.duplicate_of, reason = field_str(payload, "duplicate_of", a)
	return
}

decode_sprint_started :: proc(payload: json.Value, a: mem.Allocator) -> (d: Sprint_Started_Data, reason: string) {
	d.name, reason = field_str(payload, "name", a)
	if reason != "" do return
	d.goal_md, reason = field_str(payload, "goal_md", a)
	if reason != "" do return
	d.follows, reason = field_str(payload, "follows", a)
	if reason != "" do return
	d.must, d.must_set, reason = field_opt_str_array(payload, "must", a)
	return
}

decode_sprint_closed :: proc(payload: json.Value, a: mem.Allocator) -> (d: Sprint_Closed_Data, reason: string) {
	d.outcome_md, reason = field_str(payload, "outcome_md", a)
	return
}

decode_sprint_goal_updated :: proc(payload: json.Value, a: mem.Allocator) -> (d: Sprint_Goal_Updated_Data, reason: string) {
	d.target, reason = field_str(payload, "target", a)
	if reason != "" do return
	d.goal_md, d.goal_set, reason = field_opt_str(payload, "goal_md", a)
	if reason != "" do return
	d.must, d.must_set, reason = field_opt_str_array(payload, "must", a)
	return
}

decode_sprint_note_appended :: proc(payload: json.Value, a: mem.Allocator) -> (d: Sprint_Note_Appended_Data, reason: string) {
	d.target, reason = field_str(payload, "target", a)
	if reason != "" do return
	d.body_md, reason = field_str(payload, "body_md", a)
	if reason != "" do return
	d.defer_id, reason = field_str(payload, "defer_id", a)
	if reason != "" do return
	d.defer_type, reason = field_str(payload, "defer_type", a)
	if reason != "" do return
	d.task, reason = field_str(payload, "task", a)
	if reason != "" do return
	d.ref, reason = field_str(payload, "ref", a)
	if reason != "" do return
	d.resolves, reason = field_str(payload, "resolves", a)
	return
}

decode_sprint_task_verified :: proc(payload: json.Value, a: mem.Allocator) -> (d: Sprint_Task_Verified_Data, reason: string) {
	d.target, reason = field_str(payload, "target", a)
	if reason != "" do return
	d.task, reason = field_str(payload, "task", a)
	if reason != "" do return
	d.definition, reason = field_str(payload, "definition", a)
	if reason != "" do return
	d.outcome, reason = field_str(payload, "outcome", a)
	if reason != "" do return
	d.output, reason = field_str(payload, "output", a)
	if reason != "" do return
	d.session, reason = field_str(payload, "session", a)
	return
}

decode_sprint_outcome_updated :: proc(payload: json.Value, a: mem.Allocator) -> (d: Sprint_Outcome_Updated_Data, reason: string) {
	d.target, reason = field_str(payload, "target", a)
	if reason != "" do return
	d.outcome_md, reason = field_str(payload, "outcome_md", a)
	return
}

// ---------------------------------------------------------------------------
// Labels

// label_valid enforces [a-z0-9][a-z0-9_-]{0,31} — violations are rejected,
// never normalized.
label_valid :: proc(label: string) -> bool {
	if len(label) == 0 || len(label) > 32 {
		return false
	}
	c := label[0]
	if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
		return false
	}
	for i in 1..<len(label) {
		e := label[i]
		if !((e >= 'a' && e <= 'z') || (e >= '0' && e <= '9') || e == '_' || e == '-') {
			return false
		}
	}
	return true
}

// normalize_labels validates every element and returns the deduplicated,
// sorted set (cloned into a). Label sets are small, so the duplicate scan
// is quadratic by design.
normalize_labels :: proc(labels: []string, a: mem.Allocator) -> (out: []string, ok: bool) {
	if len(labels) == 0 {
		return nil, true
	}
	dyn := make([dynamic]string, 0, len(labels), a)
	for label in labels {
		if !label_valid(label) {
			delete(dyn)
			return nil, false
		}
		dup := false
		for existing in dyn {
			if existing == label {
				dup = true
				break
			}
		}
		if !dup {
			append(&dyn, strings.clone(label, a))
		}
	}
	for i in 1..<len(dyn) {
		j := i
		for j > 0 && dyn[j-1] > dyn[j] {
			dyn[j-1], dyn[j] = dyn[j], dyn[j-1]
			j -= 1
		}
	}
	return dyn[:], true
}

// ---------------------------------------------------------------------------
// Event UIDs

// uid_mint formats "<ts_ns:016x>-<rand64:016x>". The fixed-width hex prefix
// makes lexicographic uid order the event stream's total order. The
// timestamp formats through u64 so negative nanoseconds (pre-1970) print as
// two's-complement hex instead of a signed decimal.
uid_mint :: proc(ns: i64, rand: u64, a: mem.Allocator) -> string {
	return fmt.aprintf("%016x-%016x", cast(u64) ns, rand, allocator = a)
}

// uid_ts_ns extracts the nanosecond timestamp from a uid's first 16 hex
// digits; false when the prefix is not 16 lowercase hex digits.
uid_ts_ns :: proc(uid: string) -> (i64, bool) {
	if len(uid) < 16 {
		return 0, false
	}
	ts: i64 = 0
	for i in 0..<16 {
		c := uid[i]
		d := -1
		switch {
		case c >= '0' && c <= '9': d = int(c) - int('0')
		case c >= 'a' && c <= 'f': d = int(c) - int('a') + 10
		}
		if d < 0 {
			return 0, false
		}
		ts = (ts << 4) | i64(d)
	}
	return ts, true
}

// origin_string formats the 8-hex-digit process identifier carried by every
// envelope this daemon writes.
origin_string :: proc(seed: u32, a: mem.Allocator) -> string {
	return fmt.aprintf("%08x", seed, allocator = a)
}

// ts_iso_utc renders wall-clock milliseconds as "YYYY-MM-DDTHH:MM:SSZ"
// (UTC, no sub-second digits — display only, ordering is by uid). Days are
// recovered with the inverse of the days-from-civil algorithm so negative
// (pre-1970) stamps format correctly.
ts_iso_utc :: proc(ms: i64, a: mem.Allocator) -> string {
	days := ms / 86_400_000
	rem := ms % 86_400_000
	if rem < 0 {
		rem += 86_400_000
		days -= 1
	}
	z := days + 719_468
	era := z / 146_097
	if z < 0 && z % 146_097 != 0 {
		era -= 1
	}
	doe := z - era * 146_097
	yoe := (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
	y := yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d := doy - (153 * mp + 2) / 5 + 1
	m := mp + 3
	if mp >= 10 {
		m = mp - 9
	}
	if m <= 2 {
		y += 1
	}
	secs := rem / 1000
	hh := secs / 3600
	mi := (secs / 60) % 60
	ss := secs % 60
	return fmt.aprintf(
		"%04d-%02d-%02dT%02d:%02d:%02dZ",
		y, m, d, hh, mi, ss,
		allocator = a,
	)
}

// ---------------------------------------------------------------------------
// Payload encoders (wire shapes; omit rules mirror the original tags —
// omitempty fields drop when empty, but a fields_changed whole-value
// replacement emits [] so an explicit clear survives the round trip)

@(private)
obj_str :: proc(m: ^map[string]json.Value, key: string, v: string) {
	jsonutil.obj_set(m, key, jsonutil.json_string(v))
}

@(private)
obj_str_array :: proc(m: ^map[string]json.Value, key: string, xs: []string, a: mem.Allocator) {
	jsonutil.obj_set(m, key, jsonutil.json_string_array(xs, a))
}

encode_incident_created :: proc(d: ^Incident_Created_Data, a: mem.Allocator) -> string {
	m := jsonutil.json_object(9, a)
	obj_str(&m, "title", d.title)
	obj_str(&m, "priority", d.priority)
	if len(d.labels) > 0 {
		obj_str_array(&m, "labels", d.labels, a)
	}
	if d.sprint != "" {
		obj_str(&m, "sprint", d.sprint)
	}
	if len(d.blocked_by) > 0 {
		obj_str_array(&m, "blocked_by", d.blocked_by, a)
	}
	if d.assignee != "" {
		obj_str(&m, "assignee", d.assignee)
	}
	if len(d.aliases) > 0 {
		obj_str_array(&m, "aliases", d.aliases, a)
	}
	if d.created_by != "" {
		obj_str(&m, "created_by", d.created_by)
	}
	if d.body_md != "" {
		obj_str(&m, "body_md", d.body_md)
	}
	return jsonutil.marshal_value(json.Value(json.Object(m)), a)
}

encode_incident_title_changed :: proc(d: ^Incident_Title_Changed_Data, a: mem.Allocator) -> string {
	m := jsonutil.json_object(2, a)
	obj_str(&m, "target", d.target)
	obj_str(&m, "title", d.title)
	return jsonutil.marshal_value(json.Value(json.Object(m)), a)
}

encode_incident_verified :: proc(d: ^Incident_Verified_Data, a: mem.Allocator) -> string {
	m := jsonutil.json_object(5, a)
	obj_str(&m, "target", d.target)
	obj_str(&m, "verdict", d.verdict)
	if d.fp_pattern != "" {
		obj_str(&m, "fp_pattern", d.fp_pattern)
	}
	obj_str(&m, "reason_md", d.reason_md)
	obj_str(&m, "evidence_md", d.evidence_md)
	return jsonutil.marshal_value(json.Value(json.Object(m)), a)
}

encode_incident_root_caused :: proc(d: ^Incident_Root_Caused_Data, a: mem.Allocator) -> string {
	m := jsonutil.json_object(2, a)
	obj_str(&m, "target", d.target)
	obj_str(&m, "cause_md", d.cause_md)
	return jsonutil.marshal_value(json.Value(json.Object(m)), a)
}

encode_incident_status_changed :: proc(d: ^Incident_Status_Changed_Data, a: mem.Allocator) -> string {
	m := jsonutil.json_object(5, a)
	obj_str(&m, "target", d.target)
	obj_str(&m, "from", d.from)
	obj_str(&m, "to", d.to)
	if d.resolution != "" {
		obj_str(&m, "resolution", d.resolution)
	}
	if d.evidence_md != "" {
		obj_str(&m, "evidence_md", d.evidence_md)
	}
	return jsonutil.marshal_value(json.Value(json.Object(m)), a)
}

encode_incident_fields_changed :: proc(d: ^Incident_Fields_Changed_Data, a: mem.Allocator) -> string {
	m := jsonutil.json_object(7, a)
	obj_str(&m, "target", d.target)
	if d.priority_set {
		obj_str(&m, "priority", d.priority)
	}
	if d.labels_set {
		obj_str_array(&m, "labels", d.labels, a) // [] survives: whole-value clear
	}
	if d.sprint_set {
		obj_str(&m, "sprint", d.sprint)
	}
	if d.blocked_by_set {
		obj_str_array(&m, "blocked_by", d.blocked_by, a)
	}
	if d.assignee_set {
		obj_str(&m, "assignee", d.assignee)
	}
	if d.aliases_set {
		obj_str_array(&m, "aliases", d.aliases, a)
	}
	return jsonutil.marshal_value(json.Value(json.Object(m)), a)
}

encode_incident_note_appended :: proc(d: ^Incident_Note_Appended_Data, a: mem.Allocator) -> string {
	m := jsonutil.json_object(2, a)
	obj_str(&m, "target", d.target)
	obj_str(&m, "body_md", d.body_md)
	return jsonutil.marshal_value(json.Value(json.Object(m)), a)
}

encode_incident_deleted :: proc(d: ^Incident_Deleted_Data, a: mem.Allocator) -> string {
	m := jsonutil.json_object(3, a)
	obj_str(&m, "target", d.target)
	obj_str(&m, "reason", d.reason)
	if d.duplicate_of != "" {
		obj_str(&m, "duplicate_of", d.duplicate_of)
	}
	return jsonutil.marshal_value(json.Value(json.Object(m)), a)
}

encode_sprint_started :: proc(d: ^Sprint_Started_Data, a: mem.Allocator) -> string {
	m := jsonutil.json_object(4, a)
	obj_str(&m, "name", d.name)
	if d.goal_md != "" {
		obj_str(&m, "goal_md", d.goal_md)
	}
	if d.follows != "" {
		obj_str(&m, "follows", d.follows)
	}
	if len(d.must) > 0 {
		obj_str_array(&m, "must", d.must, a)
	}
	return jsonutil.marshal_value(json.Value(json.Object(m)), a)
}

encode_sprint_closed :: proc(d: ^Sprint_Closed_Data, a: mem.Allocator) -> string {
	m := jsonutil.json_object(1, a)
	if d.outcome_md != "" {
		obj_str(&m, "outcome_md", d.outcome_md)
	}
	return jsonutil.marshal_value(json.Value(json.Object(m)), a)
}

encode_sprint_goal_updated :: proc(d: ^Sprint_Goal_Updated_Data, a: mem.Allocator) -> string {
	m := jsonutil.json_object(3, a)
	obj_str(&m, "target", d.target)
	if d.goal_set {
		obj_str(&m, "goal_md", d.goal_md) // "": explicit clear survives
	}
	if d.must_set {
		obj_str_array(&m, "must", d.must, a) // [] survives: whole-value clear
	}
	return jsonutil.marshal_value(json.Value(json.Object(m)), a)
}

encode_sprint_note_appended :: proc(d: ^Sprint_Note_Appended_Data, a: mem.Allocator) -> string {
	m := jsonutil.json_object(7, a)
	obj_str(&m, "target", d.target)
	obj_str(&m, "body_md", d.body_md)
	if d.defer_id != "" {
		obj_str(&m, "defer_id", d.defer_id)
	}
	if d.defer_type != "" {
		obj_str(&m, "defer_type", d.defer_type)
	}
	if d.task != "" {
		obj_str(&m, "task", d.task)
	}
	if d.ref != "" {
		obj_str(&m, "ref", d.ref)
	}
	if d.resolves != "" {
		obj_str(&m, "resolves", d.resolves)
	}
	return jsonutil.marshal_value(json.Value(json.Object(m)), a)
}

encode_sprint_task_verified :: proc(d: ^Sprint_Task_Verified_Data, a: mem.Allocator) -> string {
	m := jsonutil.json_object(6, a)
	obj_str(&m, "target", d.target)
	obj_str(&m, "task", d.task)
	obj_str(&m, "definition", d.definition)
	obj_str(&m, "outcome", d.outcome)
	obj_str(&m, "output", d.output)
	if d.session != "" {
		obj_str(&m, "session", d.session)
	}
	return jsonutil.marshal_value(json.Value(json.Object(m)), a)
}

encode_sprint_outcome_updated :: proc(d: ^Sprint_Outcome_Updated_Data, a: mem.Allocator) -> string {
	m := jsonutil.json_object(2, a)
	obj_str(&m, "target", d.target)
	obj_str(&m, "outcome_md", d.outcome_md)
	return jsonutil.marshal_value(json.Value(json.Object(m)), a)
}
