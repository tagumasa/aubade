// The tracker tool family: incident filing, verification, workflow,
// sprints, and report export over svc.tracker/*. The multi-line list and
// detail renders come back pre-rendered from the parent; these applies
// add the one-line acknowledgements and the parameter mapping. Tool
// names are the namespaced forms — the descriptions cite them so no
// removed-name reference survives the rename.
package tools

import "src:util"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

import "src:jsonutil"
import "src:svc"
import "src:tracker"

// --- param tables ------------------------------------------------------------

INCIDENT_CREATE_PARAMS :: []Param_Desc{
	{name = "title", kind = .Str, description = "One-line title (max 120 characters).", required = true},
	{name = "description", kind = .Str, description = "Body markdown. For code findings, include file:line and a quote in it.", required = true},
	{name = "priority", kind = .Str, description = "urgent|high|medium|low (default medium).", required = false, enum_vals = INCIDENT_PRIORITY_MODES},
	{name = "labels", kind = .Str_Array, description = "Labels, each matching [a-z0-9][a-z0-9_-]{0,31}.", required = false},
	{name = "assignee", kind = .Str, description = "Assignee (max 64 characters) — informational, not a work lock.", required = false},
	{name = "aliases", kind = .Str_Array, description = "External IDs (e.g. R4-SG-01), globally unique.", required = false},
	{name = "created_by", kind = .Str, description = "Reporter name (max 64 characters); settable only at creation.", required = false},
	{name = "sprint", kind = .Str, description = "Sprint assignment: omit for backlog, \"current\" for the active sprint, or a SPR-NNN ID.", required = false},
	{name = "blocked_by", kind = .Str_Array, description = "Display IDs (INC-NNN) this incident is blocked by.", required = false},
}

INCIDENT_LIST_PARAMS :: []Param_Desc{
	{name = "status", kind = .Str_Array, description = "Statuses to match (OR); \"open\" expands to the non-terminal three (reported, confirmed, root_caused).", required = false},
	{name = "verdict", kind = .Str, description = "Filter by verification verdict.", required = false, enum_vals = INCIDENT_VERDICT_MODES},
	{name = "sprint", kind = .Str, description = "\"-\" for the backlog, \"current\" for the active sprint, or a SPR-NNN ID.", required = false},
	{name = "label", kind = .Str, description = "Exact label match.", required = false},
	{name = "priority", kind = .Str_Array, description = "Priorities to match (OR).", required = false},
	{name = "assignee", kind = .Str, description = "Exact assignee match.", required = false},
	{name = "created_by", kind = .Str, description = "Exact reporter match.", required = false},
	{name = "query", kind = .Str, description = "Case-insensitive substring on title and aliases.", required = false},
	{name = "blocked_by", kind = .Str, description = "INC-NNN: incidents blocked by this ID, directly or transitively.", required = false},
	{name = "limit", kind = .Int, description = "Max rows (default 20, negative = unlimited). All output is bounded by a hard ceiling (500 rows and an answer-size budget); the tail line says when it fired.", required = false},
	{name = "sort", kind = .Str, description = "updated (default), priority, or created.", required = false},
}

INCIDENT_GET_PARAMS :: []Param_Desc{
	{name = "id", kind = .Str, description = "Display ID (INC-NNN).", required = true},
	{name = "max_answer_chars", kind = .Int, description = "Truncation cap; -1 = session default.", required = false},
}

INCIDENT_VERIFY_PARAMS :: []Param_Desc{
	{name = "id", kind = .Str, description = "Display ID (INC-NNN); must be in the reported state.", required = true},
	{name = "verdict", kind = .Str, description = "confirmed or rejected.", required = true, enum_vals = INCIDENT_VERDICT_MODES},
	{name = "reason", kind = .Str, description = "Why this verdict — the reasoning summary.", required = true},
	{name = "evidence", kind = .Str, description = "file:line + quote for code findings.", required = true},
	{name = "fp_pattern", kind = .Str, description = "Only with verdict=rejected.", required = false, enum_vals = INCIDENT_FP_MODES},
}

INCIDENT_UPDATE_PARAMS :: []Param_Desc{
	{name = "id", kind = .Str, description = "Display ID (INC-NNN).", required = true},
	{name = "title", kind = .Str, description = "New one-line title.", required = false},
	{name = "priority", kind = .Str, description = "New priority.", required = false, enum_vals = INCIDENT_PRIORITY_MODES},
	{name = "labels", kind = .Str_Array, description = "Replacement label set.", required = false},
	{name = "assignee", kind = .Str, description = "New assignee.", required = false},
	{name = "aliases", kind = .Str_Array, description = "Replacement alias set.", required = false},
	{name = "sprint", kind = .Str, description = "New sprint: \"\" for backlog, \"current\", or a SPR-NNN ID.", required = false},
	{name = "status", kind = .Str, description = "Reopen transition (reported); resolve and verification have their own tools.", required = false},
	{name = "blocked_by", kind = .Str_Array, description = "Replacement blocked-by set.", required = false},
	{name = "root_cause", kind = .Str, description = "Record the root cause (verified incidents only).", required = false},
	{name = "note", kind = .Str, description = "Append a timestamped note.", required = false},
}

INCIDENT_RESOLVE_PARAMS :: []Param_Desc{
	{name = "id", kind = .Str, description = "Display ID (INC-NNN); must be in the root_caused state.", required = true},
	{name = "resolution", kind = .Str, description = "fixed, mitigated, or documented.", required = true, enum_vals = INCIDENT_RESOLUTION_MODES},
	{name = "evidence", kind = .Str, description = "Commit hash, test names, verification steps.", required = true},
	{name = "note", kind = .Str, description = "Optional closing note.", required = false},
}

INCIDENT_DELETE_PARAMS :: []Param_Desc{
	{name = "id", kind = .Str, description = "Display ID (INC-NNN).", required = true},
	{name = "reason", kind = .Str, description = "Why this incident is removed.", required = true},
	{name = "duplicate_of", kind = .Str, description = "Canonical INC-NNN when deleting a duplicate.", required = false},
}

SPRINT_START_PARAMS :: []Param_Desc{
	{name = "name", kind = .Str, description = "Sprint name (one line, max 120 characters).", required = true},
	{name = "goal", kind = .Str, description = "Goal markdown — strongly recommended; state the scope and the task table (stable task IDs + MoSCoW + verification definition per row).", required = false},
	{name = "follows", kind = .Str, description = "Previous sprint's SPR-NNN, chaining re-audit rounds.", required = false},
	{name = "must", kind = .Str_Array, description = "Stable task-table IDs of the goal's must rows — close requires each to be verified (sprint_record_verification) or deferred (sprint_update defer_type).", required = false},
}

SPRINT_CLOSE_PARAMS :: []Param_Desc{
	{name = "outcome", kind = .Str, description = "Outcome markdown; revisions can be made later with sprint_update.", required = false},
}

SPRINT_LIST_PARAMS :: []Param_Desc{
	{name = "include_closed", kind = .Bool, description = "Include closed sprints (newest first).", required = false},
	{name = "limit", kind = .Int, description = "Max closed rows (default 20).", required = false},
}

SPRINT_GET_PARAMS :: []Param_Desc{
	{name = "id", kind = .Str, description = "SPR-NNN or \"current\" for the active sprint.", required = true},
	{name = "max_answer_chars", kind = .Int, description = "Truncation cap; -1 = session default.", required = false},
}

SPRINT_UPDATE_PARAMS :: []Param_Desc{
	{name = "id", kind = .Str, description = "SPR-NNN or \"current\" for the active sprint.", required = true},
	{name = "goal", kind = .Str, description = "Replace the active sprint's goal (pass empty to clear).", required = false},
	{name = "must", kind = .Str_Array, description = "Replacement must-task ID list (whole-value; empty array clears).", required = false},
	{name = "note", kind = .Str, description = "Append a decision note to the active sprint. With defer_type it becomes a typed defer: the note body is the question text (question) or the rationale (descope).", required = false},
	{name = "defer_type", kind = .Str, description = "Type the note as a defer record.", required = false, enum_vals = SPRINT_DEFER_MODES},
	{name = "task", kind = .Str, description = "Task-table row ID this defer covers (typed defers only).", required = false},
	{name = "ref", kind = .Str, description = "Obstacle reference for defer_type=blocked (problem ID, dependency).", required = false},
	{name = "resolves", kind = .Str, description = "DEF-NNN of an open question this note answers (or descopes, with defer_type=descope).", required = false},
	{name = "outcome", kind = .Str, description = "Revise a closed sprint's outcome.", required = false},
}

SPRINT_RECORD_VERIFICATION_PARAMS :: []Param_Desc{
	{name = "task", kind = .Str, description = "Task-table row ID the run verified.", required = true},
	{name = "definition", kind = .Str, description = "The versioned verification asset that was executed (just recipe, script, CI job).", required = true},
	{name = "outcome", kind = .Str, description = "passed or failed — a failed re-run un-verifies the task.", required = true, enum_vals = SPRINT_VERIF_OUTCOME_MODES},
	{name = "output", kind = .Str, description = "The executed definition's output digest — required; a record without it is refused.", required = true},
	{name = "session", kind = .Str, description = "Originating session label.", required = false},
}

TRACKER_EXPORT_PARAMS :: []Param_Desc{
	{name = "sprint", kind = .Str, description = "One sprint's report by SPR-NNN or \"current\"; omit for every sprint plus the index.", required = false},
}

INCIDENT_PRIORITY_MODES :: []string{"urgent", "high", "medium", "low"}
INCIDENT_VERDICT_MODES :: []string{"confirmed", "rejected"}
INCIDENT_FP_MODES :: []string{"untraced-guard", "hallucinated", "spec", "threat-model", "design-intent"}
INCIDENT_RESOLUTION_MODES :: []string{"fixed", "mitigated", "documented"}
SPRINT_DEFER_MODES :: []string{"blocked", "question", "descope"}
SPRINT_VERIF_OUTCOME_MODES :: []string{"passed", "failed"}

// --- tool descriptors ----------------------------------------------------------

incident_create :: Tool_Desc{
	name        = "incident_create",
	title       = "Create incident",
	description = "File an incident (bug or finding) — use this instead of writing a bugs/ memory. " +
		"Set priority (urgent|high|medium|low, default medium): reserve urgent for active outages, data loss, " +
		"or hot-fix situations; use high for security or data-corruption risks, low for cosmetic or test-coverage " +
		"issues; map external \"Critical\"/\"Blocker\" wording to urgent. New incidents start as \"reported\" " +
		"(unverified): do not work on them before incident_verify confirms them. The description is required — " +
		"for code findings, include file:line and a quote in it.",
	can_edit    = true,
	optional    = false,
	category    = .Tracker,
	params      = INCIDENT_CREATE_PARAMS,
	needs       = {Cap.Project, Cap.Tracker},
	apply       = incident_create_apply,
}

incident_list :: Tool_Desc{
	name        = "incident_list",
	title       = "List incidents",
	description = "List incidents. The output starts with a counts header (no need to count yourself). " +
		"Filter by status (use \"open\" for all non-terminal incidents), sprint, label, priority, assignee, " +
		"created_by, query (substring match on title and aliases), verdict, or blocked_by (incidents blocked " +
		"by a given ID, directly or transitively). Row output is bounded by a hard ceiling (500 rows and an " +
		"answer-size budget) whatever limit you pass; `aubade tracker report` exports the complete set. " +
		"Use incident_get for full context.",
	optional    = false,
	category    = .Tracker,
	params      = INCIDENT_LIST_PARAMS,
	needs       = {Cap.Project, Cap.Tracker},
	apply       = incident_list_apply,
}

incident_get :: Tool_Desc{
	name        = "incident_get",
	title       = "Get incident",
	description = "Show one incident in full: header, verification verdict with evidence, root cause, " +
		"resolution, and the note timeline. Also shows \"blocks\" — which incidents this one blocks, directly " +
		"or transitively (impact scope before resolving). Output is bounded by max_answer_chars.",
	optional    = false,
	category    = .Tracker,
	params      = INCIDENT_GET_PARAMS,
	needs       = {Cap.Project, Cap.Tracker},
	apply       = incident_get_apply,
}

incident_verify :: Tool_Desc{
	name        = "incident_verify",
	title       = "Verify incident",
	description = "Judge whether a reported incident is real (verdict=confirmed) or a false positive " +
		"(verdict=rejected). Evidence is required — file:line + quote for code findings. Only valid on " +
		"reported incidents; reopen first to re-judge. Rejected incidents are kept as data for FP statistics, " +
		"not deleted.",
	can_edit    = true,
	optional    = false,
	category    = .Tracker,
	params      = INCIDENT_VERIFY_PARAMS,
	needs       = {Cap.Project, Cap.Tracker},
	apply       = incident_verify_apply,
}

incident_update :: Tool_Desc{
	name        = "incident_update",
	title       = "Update incident",
	description = "Update fields, append a note, or record the root cause (root_cause — moves a verified " +
		"incident to root_caused, the state incident_resolve resolves from). The status parameter only " +
		"reopens: status=reported clears a terminal incident's verdict and resolution. Cannot set status " +
		"to rejected (use incident_verify) or resolved (use incident_resolve). Unverified (reported) " +
		"incidents cannot enter workflow states. All requested changes apply atomically or none do.",
	can_edit    = true,
	optional    = false,
	category    = .Tracker,
	params      = INCIDENT_UPDATE_PARAMS,
	needs       = {Cap.Project, Cap.Tracker},
	apply       = incident_update_apply,
}

incident_resolve :: Tool_Desc{
	name        = "incident_resolve",
	title       = "Resolve incident",
	description = "Mark an incident resolved — only from status=root_caused, after re-checking the fix. " +
		"Requires resolution (fixed|mitigated|documented) and evidence (commit hash, tests). Record the " +
		"root cause first (incident_update root_cause).",
	can_edit    = true,
	optional    = false,
	category    = .Tracker,
	params      = INCIDENT_RESOLVE_PARAMS,
	needs       = {Cap.Project, Cap.Tracker},
	apply       = incident_resolve_apply,
}

incident_delete :: Tool_Desc{
	name        = "incident_delete",
	title       = "Delete incident",
	description = "Remove an incident from lists and stats (tombstone — event history stays in the log). " +
		"Use sparingly: false positives go to incident_verify (verdict=rejected); delete is for duplicates and " +
		"misfiles. When deleting a duplicate, pass duplicate_of with the canonical incident ID so the audit " +
		"trail keeps the link.",
	can_edit    = true,
	destructive = true,
	optional    = false,
	category    = .Tracker,
	params      = INCIDENT_DELETE_PARAMS,
	needs       = {Cap.Project, Cap.Tracker},
	apply       = incident_delete_apply,
}

sprint_start :: Tool_Desc{
	name        = "sprint_start",
	title       = "Start sprint",
	description = "Start a sprint (a work period; one audit round). Only one sprint can be active at a " +
		"time — sprint_close first. Put the scope and the task table in the goal, and declare the must " +
		"rows' stable task IDs in must — close requires every must task to be verified or deferred.",
	can_edit    = true,
	optional    = false,
	category    = .Tracker,
	params      = SPRINT_START_PARAMS,
	needs       = {Cap.Project, Cap.Tracker},
	apply       = sprint_start_apply,
}

sprint_close :: Tool_Desc{
	name        = "sprint_close",
	title       = "Close sprint",
	description = "Close the active sprint. Refused while any must task has neither a passing " +
		"verification record nor a typed defer — record a verification (sprint_record_verification) or " +
		"a defer (sprint_update with defer_type) for each. The output reports the findings FILED during " +
		"the sprint window — confirmed/rejected counts, the FP rate, resolutions — plus the must-task " +
		"verification totals, the defers, and verdicts/resolutions recorded this window on findings " +
		"filed earlier, for judging detection quality.",
	can_edit    = true,
	optional    = false,
	category    = .Tracker,
	params      = SPRINT_CLOSE_PARAMS,
	needs       = {Cap.Project, Cap.Tracker},
	apply       = sprint_close_apply,
}

sprint_list :: Tool_Desc{
	name        = "sprint_list",
	title       = "List sprints",
	description = "List sprints — the active one by default, closed ones with include_closed. Closed lines " +
		"show their FP rate.",
	optional    = false,
	category    = .Tracker,
	params      = SPRINT_LIST_PARAMS,
	needs       = {Cap.Project, Cap.Tracker},
	apply       = sprint_list_apply,
}

sprint_get :: Tool_Desc{
	name        = "sprint_get",
	title       = "Get sprint",
	description = "Show one sprint in full: status and progress counts, the current goal in full, decision " +
		"notes, and — once closed — the outcome and FP statistics. Read the previous round's goal and outcome " +
		"here before planning the next round; they are the design input.",
	optional    = false,
	category    = .Tracker,
	params      = SPRINT_GET_PARAMS,
	needs       = {Cap.Project, Cap.Tracker},
	apply       = sprint_get_apply,
}

sprint_update :: Tool_Desc{
	name        = "sprint_update",
	title       = "Update sprint",
	description = "Update a sprint: replace the active sprint's goal or must-task list, append a decision " +
		"note, or revise a closed sprint's outcome. A note becomes a typed defer with defer_type: " +
		"blocked (requires ref — the blocking problem or dependency), question (the note body IS the " +
		"question; unanswered questions stay at the top of the tracker summary until answered or " +
		"descoped), or descope (an explicit not-doing with its rationale in the note body). Answer or " +
		"descope an open question with a later note carrying resolves=DEF-NNN. Goal, must, and notes " +
		"need an active sprint; outcome revision needs a closed one. All requested changes apply " +
		"atomically or none do.",
	can_edit    = true,
	optional    = false,
	category    = .Tracker,
	params      = SPRINT_UPDATE_PARAMS,
	needs       = {Cap.Project, Cap.Tracker},
	apply       = sprint_update_apply,
}

sprint_record_verification :: Tool_Desc{
	name        = "sprint_record_verification",
	title       = "Record task verification",
	description = "Record one executed verification run for an active sprint's task — the server-held " +
		"evidence behind the task's derived verified state. Run the task's verification definition " +
		"(the versioned asset named in the goal's task table — just recipe, script, CI job) and attach " +
		"its output: the record is refused without output. The task's state is the LATEST record's " +
		"outcome — a failed re-run un-verifies. sprint_close requires every must task to be verified " +
		"or deferred.",
	can_edit    = true,
	optional    = false,
	category    = .Tracker,
	params      = SPRINT_RECORD_VERIFICATION_PARAMS,
	needs       = {Cap.Project, Cap.Tracker},
	apply       = sprint_record_verification_apply,
}

tracker_export :: Tool_Desc{
	name        = "tracker_export",
	title       = "Export tracker",
	description = "Render sprint reports (goal, outcome, FP statistics, and the findings filed " +
		"that round — one population: the statistics count exactly the listed findings) into the " +
		"tracker store: rows of the sprint_reports table in the project's SQLite database. No files " +
		"are added to the project tree. sprint_close stores the report automatically; re-export to " +
		"refresh it after outcome revisions or later verdicts.",
	can_edit    = true,
	destructive = true, // overwrites the stored sprint_reports row on re-export
	optional    = false,
	category    = .Tracker,
	params      = TRACKER_EXPORT_PARAMS,
	needs       = {Cap.Project, Cap.Tracker},
	apply       = tracker_export_apply,
}

// --- shared helpers ----------------------------------------------------------

// tracker_arg_str_array pulls a string-array argument onto the arena; the
// parameter kind was already validated by the generated validator.
tracker_arg_str_array :: proc(args: ^Args, key: string, a: mem.Allocator) -> []string {
	v, ok := args.values[key]
	if !ok {
		return nil
	}
	arr, aok := jsonutil.as_array(v)
	if !aok {
		return nil
	}
	out := make([dynamic]string, 0, len(arr), a)
	for it in arr {
		#partial switch x in it {
		case json.String:
			append(&out, string(x))
		case:
		}
	}
	return out[:]
}

// first_line trims a markdown body to its opening line for the acks.
first_line :: proc(s: string) -> string {
	cut := s
	if i := strings.index_byte(s, '\n'); i >= 0 {
		cut = s[:i]
	}
	return strings.trim_space(cut)
}

// call_text extracts the parent's rendered markdown payload.
call_text :: proc(result: json.Value) -> string {
	text, _ := json_str(result, "text")
	return text
}

// call_answer_result maps a svc call onto the tracker answer text: a
// failed call answers with the wire code and message.
call_answer_result :: proc(ctx: ^Tool_Ctx, call: svc.Client_Call) -> Tool_Result {
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	return text_result(ctx, call_text(call.result))
}

// --- applies -----------------------------------------------------------------

incident_create_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	req: svc.Tracker_Create_Req
	req.title = arg_str(args, "title")
	req.description = arg_str(args, "description")
	req.priority = arg_str(args, "priority")
	req.assignee = arg_str(args, "assignee")
	req.created_by = arg_str(args, "created_by")
	req.sprint = arg_str(args, "sprint")
	req.labels = tracker_arg_str_array(args, "labels", ctx.allocator)
	req.aliases = tracker_arg_str_array(args, "aliases", ctx.allocator)
	req.blocked_by = tracker_arg_str_array(args, "blocked_by", ctx.allocator)

	call := svc.client_tracker_create(ctx.svc_conn, &req, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	id, _ := json_str(call.result, "id")
	title, _ := json_str(call.result, "title")
	priority, _ := json_str(call.result, "priority")
	sprint, _ := json_str(call.result, "sprint")
	sprint_where := sprint
	if sprint_where == "" {
		sprint_where = "backlog"
	}
	return text_result(ctx, fmt.aprintf(
		"Created %s [%s] \"%s\" (reported, %s)",
		id, priority, title, sprint_where,
		allocator = ctx.allocator,
	))
}

incident_list_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_tracker_list_incidents(
		ctx.svc_conn,
		tracker_arg_str_array(args, "status", ctx.allocator),
		arg_str(args, "verdict"),
		arg_str(args, "sprint"),
		arg_str(args, "label"),
		tracker_arg_str_array(args, "priority", ctx.allocator),
		arg_str(args, "assignee"),
		arg_str(args, "created_by"),
		arg_str(args, "query"),
		arg_str(args, "blocked_by"),
		arg_str(args, "sort"),
		arg_int(args, "limit"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_answer_result(ctx, call)
}

incident_get_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	call := svc.client_tracker_get(
		ctx.svc_conn, svc.METHOD_TRACKER_GET_INCIDENT, arg_str(args, "id"), max_chars,
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_answer_result(ctx, call)
}

incident_verify_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	id := arg_str(args, "id")
	verdict := arg_str(args, "verdict")
	reason := arg_str(args, "reason")
	fp_pattern := arg_str(args, "fp_pattern")
	call := svc.client_tracker_verify(
		ctx.svc_conn, id, verdict, fp_pattern, reason, arg_str(args, "evidence"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	if verdict == tracker.verdict_string(.Rejected) {
		pattern := ""
		if fp_pattern != "" {
			pattern = fmt.aprintf(" (%s)", fp_pattern, allocator = ctx.allocator)
		}
		return text_result(ctx, fmt.aprintf(
			"Rejected %s%s: %s", id, pattern, first_line(reason),
			allocator = ctx.allocator,
		))
	}
	out_id, _ := json_str(call.result, "id")
	out_verdict, _ := json_str(call.result, "verdict")
	return text_result(ctx, fmt.aprintf(
		"Verified %s: %s — %s", out_id, out_verdict, first_line(reason),
		allocator = ctx.allocator,
	))
}

incident_update_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	id := arg_str(args, "id")
	status := arg_str(args, "status")
	if arg_has(args, "status") && status == tracker.incident_status_string(.Resolved) {
		return err_result(ctx, "cannot set status to resolved: use incident_resolve")
	}

	req: svc.Tracker_Update_Req
	req.id = id
	req.title = arg_str(args, "title")
	req.title_set = arg_has(args, "title")
	req.root_cause = arg_str(args, "root_cause")
	req.root_cause_set = arg_has(args, "root_cause")
	req.note = arg_str(args, "note")
	req.note_set = arg_has(args, "note")
	req.status = status
	req.status_set = arg_has(args, "status")
	req.priority = arg_str(args, "priority")
	req.priority_set = arg_has(args, "priority")
	req.sprint = arg_str(args, "sprint")
	req.sprint_set = arg_has(args, "sprint")
	req.assignee = arg_str(args, "assignee")
	req.assignee_set = arg_has(args, "assignee")
	req.labels = tracker_arg_str_array(args, "labels", ctx.allocator)
	req.labels_set = arg_has(args, "labels")
	req.aliases = tracker_arg_str_array(args, "aliases", ctx.allocator)
	req.aliases_set = arg_has(args, "aliases")
	req.blocked_by = tracker_arg_str_array(args, "blocked_by", ctx.allocator)
	req.blocked_by_set = arg_has(args, "blocked_by")

	call := svc.client_tracker_update(ctx.svc_conn, &req, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	before, _ := json_str(call.result, "before_status")

	// The ack lists what the call changed, in the manager's fixed order.
	parts := make([dynamic]string, 0, 10, ctx.allocator)
	if req.title_set {
		append(&parts, "title")
	}
	if req.root_cause_set {
		append(&parts, "root cause recorded")
	}
	if req.priority_set {
		append(&parts, fmt.aprintf("priority → %s", req.priority, allocator = ctx.allocator))
	}
	if req.labels_set {
		append(&parts, "labels")
	}
	if req.assignee_set {
		append(&parts, "assignee")
	}
	if req.aliases_set {
		append(&parts, "aliases")
	}
	if req.sprint_set {
		append(&parts, "sprint")
	}
	if req.blocked_by_set {
		append(&parts, "blocked_by")
	}
	if req.status_set {
		append(&parts, fmt.aprintf("status: %s→%s", before, req.status, allocator = ctx.allocator))
	}
	if req.note_set {
		append(&parts, "note appended")
	}
	if len(parts) == 0 {
		return text_result(ctx, fmt.aprintf("No changes for %s", id, allocator = ctx.allocator))
	}
	joined, _ := strings.join(parts[:], "; ", ctx.allocator)
	return text_result(ctx, fmt.aprintf(
		"Updated %s (%s)", id, joined,
		allocator = ctx.allocator,
	))
}

incident_resolve_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	id := arg_str(args, "id")
	resolution := arg_str(args, "resolution")
	evidence := arg_str(args, "evidence")
	note := arg_str(args, "note")
	call := svc.client_tracker_resolve(
		ctx.svc_conn, id, resolution, evidence, note, arg_has(args, "note"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	return text_result(ctx, fmt.aprintf(
		"Resolved %s as %s: %s", id, resolution, first_line(evidence),
		allocator = ctx.allocator,
	))
}

incident_delete_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	id := arg_str(args, "id")
	duplicate_of := arg_str(args, "duplicate_of")
	call := svc.client_tracker_delete(
		ctx.svc_conn, id, arg_str(args, "reason"), duplicate_of,
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	link := ""
	if duplicate_of != "" {
		link = fmt.aprintf(" (duplicate → %s)", duplicate_of, allocator = ctx.allocator)
	}
	return text_result(ctx, fmt.aprintf(
		"Deleted %s%s — hidden from lists and stats, history kept", id, link,
		allocator = ctx.allocator,
	))
}

sprint_start_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	goal := arg_str(args, "goal")
	goal_set := arg_has(args, "goal")
	must := tracker_arg_str_array(args, "must", ctx.allocator)
	call := svc.client_tracker_start_sprint(
		ctx.svc_conn, arg_str(args, "name"), goal, arg_str(args, "follows"), goal_set, must,
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	id, _ := json_str(call.result, "id")
	name, _ := json_str(call.result, "name")
	must_bit := ""
	if len(must) > 0 {
		must_bit = fmt.aprintf(", must: %d tasks", len(must), allocator = ctx.allocator)
	}
	if goal_set && goal != "" {
		return text_result(ctx, fmt.aprintf(
			"Started %s \"%s\" (goal: %s)%s", id, name, first_line(goal), must_bit,
			allocator = ctx.allocator,
		))
	}
	return text_result(ctx, fmt.aprintf(
		"Started %s \"%s\"%s", id, name, must_bit,
		allocator = ctx.allocator,
	))
}

sprint_close_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	outcome := arg_str(args, "outcome")
	call := svc.client_tracker_close_sprint(
		ctx.svc_conn, outcome, arg_has(args, "outcome"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	id, _ := json_str(call.result, "id")
	name, _ := json_str(call.result, "name")
	stats, _ := json_str(call.result, "stats_text")
	return text_result(ctx, fmt.aprintf(
		"Closed %s \"%s\": %s", id, name, stats,
		allocator = ctx.allocator,
	))
}

sprint_list_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_tracker_list_sprints(
		ctx.svc_conn, arg_bool(args, "include_closed"), arg_int(args, "limit"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_answer_result(ctx, call)
}

sprint_get_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	call := svc.client_tracker_get(
		ctx.svc_conn, svc.METHOD_TRACKER_GET_SPRINT, arg_str(args, "id"), max_chars,
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	return call_answer_result(ctx, call)
}

sprint_update_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	req: svc.Tracker_Sprint_Update_Req
	req.id = arg_str(args, "id")
	req.goal = arg_str(args, "goal")
	req.goal_set = arg_has(args, "goal")
	req.note = arg_str(args, "note")
	req.note_set = arg_has(args, "note")
	req.outcome = arg_str(args, "outcome")
	req.outcome_set = arg_has(args, "outcome")
	req.defer_type = arg_str(args, "defer_type")
	req.defer_task = arg_str(args, "task")
	req.defer_ref = arg_str(args, "ref")
	req.resolves = arg_str(args, "resolves")
	req.must = tracker_arg_str_array(args, "must", ctx.allocator)
	req.must_set = arg_has(args, "must")
	call := svc.client_tracker_update_sprint(ctx.svc_conn, &req, ctx.allocator, svc_deadline(ctx), ctx.cancel)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	out_id, _ := json_str(call.result, "id")
	changed, _ := json_str(call.result, "changed")
	if changed == "" {
		return text_result(ctx, fmt.aprintf("No changes for %s", out_id, allocator = ctx.allocator))
	}
	return text_result(ctx, fmt.aprintf(
		"Updated %s (%s)", out_id, changed,
		allocator = ctx.allocator,
	))
}

sprint_record_verification_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	task := arg_str(args, "task")
	definition := arg_str(args, "definition")
	outcome := arg_str(args, "outcome")
	call := svc.client_tracker_record_verification(
		ctx.svc_conn, task, definition, outcome, arg_str(args, "output"), arg_str(args, "session"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	sprint_id, _ := json_str(call.result, "sprint_id")
	return text_result(ctx, fmt.aprintf(
		"Recorded %s verification for %s: %s (%s)", sprint_id, task, outcome, definition,
		allocator = ctx.allocator,
	))
}

tracker_export_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	call := svc.client_tracker_export(
		ctx.svc_conn, arg_str(args, "sprint"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	return text_result(ctx, call_text(call.result))
}
