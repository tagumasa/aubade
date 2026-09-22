// svc.tracker/* — the incident/sprint tracker's RPC surface. The
// implementation is the tracker domain's Manager (owned by the daemon);
// this file carries only the method names and the two wide request
// structs the child-side proxies serialize (the flat calls stay plain
// arguments). The render-style reads return pre-rendered markdown in a
// "text" field; the writes return the structured bits the tool layer
// composes its one-line acknowledgements from.
package svc

METHOD_TRACKER_LIST_INCIDENTS :: "svc.tracker/list_incidents" // IncidentFilter fields -> {text}
METHOD_TRACKER_GET_INCIDENT :: "svc.tracker/get_incident" // {id, max_answer_chars?} -> {text}
METHOD_TRACKER_CREATE :: "svc.tracker/create" // Tracker_Create_Req -> {id, title, priority, sprint}
METHOD_TRACKER_VERIFY :: "svc.tracker/verify" // {id, verdict, fp_pattern?, reason, evidence} -> {id, status, verdict}
METHOD_TRACKER_UPDATE :: "svc.tracker/update" // Tracker_Update_Req -> {id, before_status}
METHOD_TRACKER_RESOLVE :: "svc.tracker/resolve" // {id, resolution, evidence, note?} -> {id}
METHOD_TRACKER_DELETE :: "svc.tracker/delete" // {id, reason, duplicate_of?} -> {id}
METHOD_TRACKER_START_SPRINT :: "svc.tracker/start_sprint" // {name, goal?, follows?, must?} -> {id, name}
METHOD_TRACKER_CLOSE_SPRINT :: "svc.tracker/close_sprint" // {outcome?} -> {id, name, stats_text}
METHOD_TRACKER_LIST_SPRINTS :: "svc.tracker/list_sprints" // {include_closed?, limit?} -> {text}
METHOD_TRACKER_GET_SPRINT :: "svc.tracker/get_sprint" // {id, max_answer_chars?} -> {text}
METHOD_TRACKER_UPDATE_SPRINT :: "svc.tracker/update_sprint" // Tracker_Sprint_Update_Req -> {id}
METHOD_TRACKER_EXPORT :: "svc.tracker/export" // {sprint?} -> {text}
METHOD_TRACKER_OPEN_SUMMARY :: "svc.tracker/open_summary" // {} -> {text} (the system prompt's resume summary)
METHOD_TRACKER_RECORD_VERIFICATION :: "svc.tracker/record_verification" // {task, definition, outcome, output, session?} -> {sprint_id, task, outcome}

// Tracker_Create_Req is the filing payload: every field maps one tool
// parameter; sprint arrives already resolved ("" = backlog, a concrete
// SPR id otherwise — "current" never reaches the manager).
Tracker_Create_Req :: struct {
	title:       string,
	description: string,
	priority:    string,
	assignee:    string,
	created_by:  string,
	sprint:      string,
	labels:      []string,
	aliases:     []string,
	blocked_by:  []string,
}

// Tracker_Update_Req is the composite update payload: each _set flag
// marks a present parameter (JSON null/absent both mean untouched). The
// fixed application order lives in the domain validator; status arrives
// pre-gated ("resolved" never reaches the wire — resolve goes through
// its own method).
Tracker_Update_Req :: struct {
	id: string,

	title:          string,
	title_set:      bool,
	root_cause:     string,
	root_cause_set: bool,
	note:           string,
	note_set:       bool,
	status:         string,
	status_set:     bool,

	priority:       string,
	priority_set:   bool,
	sprint:         string,
	sprint_set:     bool,
	assignee:       string,
	assignee_set:   bool,
	labels:         []string,
	labels_set:     bool,
	aliases:        []string,
	aliases_set:    bool,
	blocked_by:     []string,
	blocked_by_set: bool,
}

// Tracker_Sprint_Update_Req is the composite sprint update: goal/note need
// an active sprint, outcome a closed one. A note may carry a typed defer
// record (defer_type with its per-type fields) or resolve an open question
// (resolves); must replaces the structured must-task list.
Tracker_Sprint_Update_Req :: struct {
	id: string,

	goal:        string,
	goal_set:    bool,
	note:        string,
	note_set:    bool,
	outcome:     string,
	outcome_set: bool,

	defer_type:  string,
	defer_task:  string,
	defer_ref:   string,
	resolves:    string,

	must:        []string,
	must_set:    bool,
}
