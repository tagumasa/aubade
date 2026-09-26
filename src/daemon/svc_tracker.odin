// The svc.tracker/* handlers: the tracker family's parent side. The
// reads render markdown through the domain renderers; the writes go
// through the manager's locked event path (one event per transaction,
// the fold applies in memory). Export and sprint close also store the
// rendered sprint report rows — export surfaces store failures, close
// treats the report as best-effort (the close already committed).
package daemon

import "core:encoding/json"
import "core:mem"
import "core:strings"

import "src:jsonutil"
import "src:platform"
import "src:svc"
import "src:tracker"

register_tracker_methods :: proc(t: ^svc.Table) {
	svc.table_register(t, svc.METHOD_TRACKER_LIST_INCIDENTS, handle_tracker_list_incidents)
	svc.table_register(t, svc.METHOD_TRACKER_GET_INCIDENT, handle_tracker_get_incident)
	svc.table_register_mutating(t, svc.METHOD_TRACKER_CREATE, handle_tracker_create)
	svc.table_register_mutating(t, svc.METHOD_TRACKER_VERIFY, handle_tracker_verify)
	svc.table_register_mutating(t, svc.METHOD_TRACKER_UPDATE, handle_tracker_update)
	svc.table_register_mutating(t, svc.METHOD_TRACKER_RESOLVE, handle_tracker_resolve)
	svc.table_register_mutating(t, svc.METHOD_TRACKER_DELETE, handle_tracker_delete)
	svc.table_register_mutating(t, svc.METHOD_TRACKER_START_SPRINT, handle_tracker_start_sprint)
	svc.table_register_mutating(t, svc.METHOD_TRACKER_CLOSE_SPRINT, handle_tracker_close_sprint)
	svc.table_register(t, svc.METHOD_TRACKER_LIST_SPRINTS, handle_tracker_list_sprints)
	svc.table_register(t, svc.METHOD_TRACKER_GET_SPRINT, handle_tracker_get_sprint)
	svc.table_register_mutating(t, svc.METHOD_TRACKER_UPDATE_SPRINT, handle_tracker_update_sprint)
	svc.table_register_mutating(t, svc.METHOD_TRACKER_RECORD_VERIFICATION, handle_tracker_record_verification)
	svc.table_register_mutating(t, svc.METHOD_TRACKER_EXPORT, handle_tracker_export)
	svc.table_register(t, svc.METHOD_TRACKER_OPEN_SUMMARY, handle_tracker_open_summary)
}

// --- param helpers ----------------------------------------------------------
// (the optional string-array reader is file_opt_str_array in svc_file.odin,
// the one param family for the daemon's svc handlers)

// tracker_expand_sprint resolves the "current" reference into the active
// sprint's concrete id; the empty string and concrete ids pass through.
tracker_expand_sprint :: proc(d: ^Daemon, sprint: string, a: mem.Allocator) -> (string, platform.Err) {
	if sprint != tracker.SPRINT_CURRENT_ALIAS {
		return sprint, nil
	}
	active, ok := tracker.manager_active_sprint_id(d.tracker, a)
	if !ok {
		return "", svc.wrapped_err(.Invalid, "no active sprint", a)
	}
	return active, nil
}

// --- reads ------------------------------------------------------------------

handle_tracker_list_incidents :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	f: tracker.Incident_Filter
	status, _, err := file_opt_str_array(ctx, params, "status")
	if err != nil {
		return nil, err
	}
	f.status = status
	priority, _, perr := file_opt_str_array(ctx, params, "priority")
	if perr != nil {
		return nil, perr
	}
	f.priority = priority
	if val, present, verr := file_opt_str(ctx, params, "sprint"); verr != nil {
		return nil, verr
	} else if present {
		f.sprint = val
	}
	if val, present, verr := file_opt_str(ctx, params, "label"); verr != nil {
		return nil, verr
	} else if present {
		f.label = val
	}
	if val, present, verr := file_opt_str(ctx, params, "verdict"); verr != nil {
		return nil, verr
	} else if present {
		f.verdict = val
	}
	if val, present, verr := file_opt_str(ctx, params, "blocked_by"); verr != nil {
		return nil, verr
	} else if present {
		f.blocked_by = val
	}
	if val, present, verr := file_opt_str(ctx, params, "assignee"); verr != nil {
		return nil, verr
	} else if present {
		f.assignee = val
	}
	if val, present, verr := file_opt_str(ctx, params, "created_by"); verr != nil {
		return nil, verr
	} else if present {
		f.created_by = val
	}
	if val, present, verr := file_opt_str(ctx, params, "query"); verr != nil {
		return nil, verr
	} else if present {
		f.query = val
	}
	if val, present, verr := file_opt_str(ctx, params, "sort"); verr != nil {
		return nil, verr
	} else if present {
		f.sort = val
	}
	limit, lpresent, lerr := file_opt_int(ctx, params, "limit")
	if lerr != nil {
		return nil, lerr
	}
	if lpresent {
		f.limit = limit
	}

	text, rerr := tracker.manager_list_incidents(d.tracker, &f, platform.wall_ms(), ctx.allocator)
	if rerr != nil {
		return nil, rerr
	}
	return tracker_text_value(ctx, text), nil
}

// tracker_text_value wraps the manager's rendered markdown text as the
// {text: ...} wire value the CLI-side consumers print.
tracker_text_value :: proc(ctx: ^svc.Svc_Ctx, text: string) -> json.Value {
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "text", jsonutil.json_string(text))
	return json.Value(json.Object(out))
}

handle_tracker_get_incident :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	return handle_tracker_get(ctx, params, tracker.manager_get_incident)
}

handle_tracker_get_sprint :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	return handle_tracker_get(ctx, params, tracker.manager_get_sprint)
}

// handle_tracker_get answers the two get-one handlers: require the id,
// take the optional max-answer-chars, and wrap the manager's rendered
// text (incident and sprint detail share the whole read shape).
handle_tracker_get :: proc(
	ctx: ^svc.Svc_Ctx,
	params: json.Value,
	get: proc(m: ^tracker.Manager, id: string, max_chars: int, a: mem.Allocator) -> (string, platform.Err),
) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	id, err := file_require_str(ctx, params, "id")
	if err != nil {
		return nil, err
	}
	max_chars, _, merr := file_opt_int(ctx, params, "max_answer_chars")
	if merr != nil {
		return nil, merr
	}
	text, rerr := get(d.tracker, id, max_chars, ctx.allocator)
	if rerr != nil {
		return nil, rerr
	}
	return tracker_text_value(ctx, text), nil
}

handle_tracker_list_sprints :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	include_closed, _, cerr := file_opt_bool(ctx, params, "include_closed")
	if cerr != nil {
		return nil, cerr
	}
	limit, _, lerr := file_opt_int(ctx, params, "limit")
	if lerr != nil {
		return nil, lerr
	}
	text, rerr := tracker.manager_list_sprints(d.tracker, include_closed, limit, platform.wall_ms(), ctx.allocator)
	if rerr != nil {
		return nil, rerr
	}
	return tracker_text_value(ctx, text), nil
}

// handle_tracker_open_summary answers the one-line open summary the
// session's system prompt embeds. An all-closed tracker answers an empty
// text — the render omits the line entirely.
handle_tracker_open_summary :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	text := tracker.manager_open_summary(d.tracker, platform.wall_ms(), ctx.allocator)
	return tracker_text_value(ctx, text), nil
}

// --- writes -----------------------------------------------------------------

handle_tracker_create :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	title, terr := file_require_str(ctx, params, "title")
	if terr != nil {
		return nil, terr
	}
	description, derr := file_require_str(ctx, params, "description")
	if derr != nil {
		return nil, derr
	}
	input: tracker.Create_Input
	input.title = title
	input.body_md = description
	if val, present, verr := file_opt_str(ctx, params, "priority"); verr != nil {
		return nil, verr
	} else if present {
		input.priority = val
	}
	if val, present, verr := file_opt_str(ctx, params, "assignee"); verr != nil {
		return nil, verr
	} else if present {
		input.assignee = val
	}
	if val, present, verr := file_opt_str(ctx, params, "created_by"); verr != nil {
		return nil, verr
	} else if present {
		input.created_by = val
	}
	sprint, spresent, serr := file_opt_str(ctx, params, "sprint")
	if serr != nil {
		return nil, serr
	}
	if spresent && sprint != "" {
		expanded, eerr := tracker_expand_sprint(d, sprint, ctx.allocator)
		if eerr != nil {
			return nil, eerr
		}
		input.sprint = expanded
	}
	labels, _, lerr := file_opt_str_array(ctx, params, "labels")
	if lerr != nil {
		return nil, lerr
	}
	input.labels = labels
	aliases, _, aerr := file_opt_str_array(ctx, params, "aliases")
	if aerr != nil {
		return nil, aerr
	}
	input.aliases = aliases
	blocked, _, blerr := file_opt_str_array(ctx, params, "blocked_by")
	if blerr != nil {
		return nil, blerr
	}
	input.blocked_by = blocked

	res, cerr := tracker.manager_create(d.tracker, &input, ctx.allocator)
	if cerr != nil {
		return nil, cerr
	}
	out := jsonutil.json_object(4, ctx.allocator)
	jsonutil.obj_set(&out, "id", jsonutil.json_string(res.id))
	jsonutil.obj_set(&out, "title", jsonutil.json_string(res.title))
	jsonutil.obj_set(&out, "priority", jsonutil.json_string(res.priority))
	jsonutil.obj_set(&out, "sprint", jsonutil.json_string(input.sprint))
	return json.Value(json.Object(out)), nil
}

handle_tracker_verify :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	id, err := file_require_str(ctx, params, "id")
	if err != nil {
		return nil, err
	}
	verdict, verr := file_require_str(ctx, params, "verdict")
	if verr != nil {
		return nil, verr
	}
	reason, rerr := file_require_str(ctx, params, "reason")
	if rerr != nil {
		return nil, rerr
	}
	evidence, eerr := file_require_str(ctx, params, "evidence")
	if eerr != nil {
		return nil, eerr
	}
	fp_pattern, fpresent, fperr := file_opt_str(ctx, params, "fp_pattern")
	if fperr != nil {
		return nil, fperr
	}
	if !fpresent {
		fp_pattern = ""
	}

	res, cerr := tracker.manager_verify(d.tracker, id, verdict, fp_pattern, reason, evidence, ctx.allocator)
	if cerr != nil {
		return nil, cerr
	}
	out := jsonutil.json_object(3, ctx.allocator)
	jsonutil.obj_set(&out, "id", jsonutil.json_string(res.id))
	jsonutil.obj_set(&out, "status", jsonutil.json_string(res.status))
	jsonutil.obj_set(&out, "verdict", jsonutil.json_string(res.verdict))
	return json.Value(json.Object(out)), nil
}

handle_tracker_update :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	id, err := file_require_str(ctx, params, "id")
	if err != nil {
		return nil, err
	}

	// The pre-read doubles as the not-found check and the ack's
	// before-status; a race between the two calls can only stutter the
	// rendered transition, never the applied one.
	before, berr := tracker.manager_incident_status(d.tracker, id, ctx.allocator)
	if berr != nil {
		return nil, berr
	}

	up: tracker.Update_Input
	if val, present, verr := file_opt_str(ctx, params, "title"); verr != nil {
		return nil, verr
	} else if present {
		up.title = val
		up.title_set = true
	}
	if val, present, verr := file_opt_str(ctx, params, "root_cause"); verr != nil {
		return nil, verr
	} else if present {
		up.root_cause = val
		up.root_cause_set = true
	}
	if val, present, verr := file_opt_str(ctx, params, "note"); verr != nil {
		return nil, verr
	} else if present {
		up.note = val
		up.note_set = true
	}
	if val, present, verr := file_opt_str(ctx, params, "status"); verr != nil {
		return nil, verr
	} else if present {
		// Resolved never reaches the manager through this method — the
		// tool layer refuses it first; resolve has its own path.
		if val == tracker.incident_status_string(.Resolved) {
			return nil, svc.wrapped_err(.Invalid, "cannot set status to resolved: use the resolve tool", ctx.allocator)
		}
		up.status = {to = val}
		up.status_set = true
	}

	fields: tracker.Fields_Update
	any_field := false
	if val, present, verr := file_opt_str(ctx, params, "priority"); verr != nil {
		return nil, verr
	} else if present {
		fields.priority = val
		fields.priority_set = true
		any_field = true
	}
	if val, present, verr := file_opt_str(ctx, params, "sprint"); verr != nil {
		return nil, verr
	} else if present {
		expanded, eerr := tracker_expand_sprint(d, val, ctx.allocator)
		if eerr != nil {
			return nil, eerr
		}
		fields.sprint = expanded
		fields.sprint_set = true
		any_field = true
	}
	if val, present, verr := file_opt_str(ctx, params, "assignee"); verr != nil {
		return nil, verr
	} else if present {
		fields.assignee = val
		fields.assignee_set = true
		any_field = true
	}
	if vals, present, verr := file_opt_str_array(ctx, params, "labels"); verr != nil {
		return nil, verr
	} else if present {
		fields.labels = vals
		fields.labels_set = true
		any_field = true
	}
	if vals, present, verr := file_opt_str_array(ctx, params, "aliases"); verr != nil {
		return nil, verr
	} else if present {
		fields.aliases = vals
		fields.aliases_set = true
		any_field = true
	}
	if vals, present, verr := file_opt_str_array(ctx, params, "blocked_by"); verr != nil {
		return nil, verr
	} else if present {
		fields.blocked_by = vals
		fields.blocked_by_set = true
		any_field = true
	}
	if any_field {
		up.fields = fields
		up.fields_set = true
	}

	_, out_id, uerr := tracker.manager_update_incident(d.tracker, id, &up, ctx.allocator)
	if uerr != nil {
		return nil, uerr
	}
	out := jsonutil.json_object(2, ctx.allocator)
	jsonutil.obj_set(&out, "id", jsonutil.json_string(out_id))
	jsonutil.obj_set(&out, "before_status", jsonutil.json_string(before))
	return json.Value(json.Object(out)), nil
}

handle_tracker_resolve :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	id, err := file_require_str(ctx, params, "id")
	if err != nil {
		return nil, err
	}
	resolution, rerr := file_require_str(ctx, params, "resolution")
	if rerr != nil {
		return nil, rerr
	}
	evidence, eerr := file_require_str(ctx, params, "evidence")
	if eerr != nil {
		return nil, eerr
	}
	note, npresent, nerr := file_opt_str(ctx, params, "note")
	if nerr != nil {
		return nil, nerr
	}
	if !npresent {
		note = ""
	}

	up: tracker.Update_Input
	up.status = {to = tracker.incident_status_string(.Resolved), resolution = resolution, evidence_md = evidence}
	up.status_set = true
	if npresent {
		up.note = note
		up.note_set = true
	}
	_, out_id, uerr := tracker.manager_update_incident(d.tracker, id, &up, ctx.allocator)
	if uerr != nil {
		return nil, uerr
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "id", jsonutil.json_string(out_id))
	return json.Value(json.Object(out)), nil
}

handle_tracker_delete :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	id, err := file_require_str(ctx, params, "id")
	if err != nil {
		return nil, err
	}
	reason, rerr := file_require_str(ctx, params, "reason")
	if rerr != nil {
		return nil, rerr
	}
	duplicate_of, dpresent, derr := file_opt_str(ctx, params, "duplicate_of")
	if derr != nil {
		return nil, derr
	}
	if !dpresent {
		duplicate_of = ""
	}

	out_id, uerr := tracker.manager_delete(d.tracker, id, reason, duplicate_of, ctx.allocator)
	if uerr != nil {
		return nil, uerr
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "id", jsonutil.json_string(out_id))
	return json.Value(json.Object(out)), nil
}

// --- sprints ----------------------------------------------------------------

handle_tracker_start_sprint :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	name, nerr := file_require_str(ctx, params, "name")
	if nerr != nil {
		return nil, nerr
	}
	goal, gpresent, gerr := file_opt_str(ctx, params, "goal")
	if gerr != nil {
		return nil, gerr
	}
	if !gpresent {
		goal = ""
	}
	follows, fpresent, ferr := file_opt_str(ctx, params, "follows")
	if ferr != nil {
		return nil, ferr
	}
	if !fpresent {
		follows = ""
	}
	must, _, merr := file_opt_str_array(ctx, params, "must")
	if merr != nil {
		return nil, merr
	}

	res, serr := tracker.manager_start_sprint(d.tracker, name, goal, follows, must, ctx.allocator)
	if serr != nil {
		return nil, serr
	}
	out := jsonutil.json_object(2, ctx.allocator)
	jsonutil.obj_set(&out, "id", jsonutil.json_string(res.id))
	jsonutil.obj_set(&out, "name", jsonutil.json_string(res.name))
	return json.Value(json.Object(out)), nil
}

handle_tracker_close_sprint :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	outcome, opresent, oerr := file_opt_str(ctx, params, "outcome")
	if oerr != nil {
		return nil, oerr
	}
	if !opresent {
		outcome = ""
	}

	res, cerr := tracker.manager_close_sprint(d.tracker, outcome, ctx.allocator)
	if cerr != nil {
		return nil, cerr
	}

	out := jsonutil.json_object(3, ctx.allocator)
	jsonutil.obj_set(&out, "id", jsonutil.json_string(res.id))
	jsonutil.obj_set(&out, "name", jsonutil.json_string(res.name))
	jsonutil.obj_set(&out, "stats_text", jsonutil.json_string(res.stats_text))
	return json.Value(json.Object(out)), nil
}

handle_tracker_update_sprint :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	id, err := file_require_str(ctx, params, "id")
	if err != nil {
		return nil, err
	}
	expanded, eerr := tracker_expand_sprint(d, id, ctx.allocator)
	if eerr != nil {
		return nil, eerr
	}

	su: tracker.Sprint_Update
	if val, present, verr := file_opt_str(ctx, params, "goal"); verr != nil {
		return nil, verr
	} else if present {
		su.goal = val
		su.goal_set = true
	}
	if val, present, verr := file_opt_str(ctx, params, "note"); verr != nil {
		return nil, verr
	} else if present {
		su.note = val
		su.note_set = true
	}
	if val, present, verr := file_opt_str(ctx, params, "outcome"); verr != nil {
		return nil, verr
	} else if present {
		su.outcome = val
		su.outcome_set = true
	}
	if val, present, verr := file_opt_str(ctx, params, "defer_type"); verr != nil {
		return nil, verr
	} else if present {
		su.defer_type = val
	}
	if val, present, verr := file_opt_str(ctx, params, "task"); verr != nil {
		return nil, verr
	} else if present {
		su.defer_task = val
	}
	if val, present, verr := file_opt_str(ctx, params, "ref"); verr != nil {
		return nil, verr
	} else if present {
		su.defer_ref = val
	}
	if val, present, verr := file_opt_str(ctx, params, "resolves"); verr != nil {
		return nil, verr
	} else if present {
		su.resolves = val
	}
	if vals, present, verr := file_opt_str_array(ctx, params, "must"); verr != nil {
		return nil, verr
	} else if present {
		su.must = vals
		su.must_set = true
	}

	changed, out_id, uerr := tracker.manager_update_sprint(d.tracker, expanded, &su, ctx.allocator)
	if uerr != nil {
		return nil, uerr
	}
	out := jsonutil.json_object(2, ctx.allocator)
	jsonutil.obj_set(&out, "id", jsonutil.json_string(out_id))
	if len(changed) > 0 {
		joined, _ := strings.join(changed[:], ", ", ctx.allocator)
		jsonutil.obj_set(&out, "changed", jsonutil.json_string(joined))
	}
	return json.Value(json.Object(out)), nil
}

// handle_tracker_record_verification files one verification record on the
// active sprint — the evidence behind a task's derived "verified" state.
// The required fields (task/definition/outcome/output) are enforced by the
// manager gate; this layer only forwards them.
handle_tracker_record_verification :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	task, terr := file_require_str(ctx, params, "task")
	if terr != nil {
		return nil, terr
	}
	definition, derr := file_require_str(ctx, params, "definition")
	if derr != nil {
		return nil, derr
	}
	outcome, oerr := file_require_str(ctx, params, "outcome")
	if oerr != nil {
		return nil, oerr
	}
	output, perr := file_require_str(ctx, params, "output")
	if perr != nil {
		return nil, perr
	}
	session, spresent, serr := file_opt_str(ctx, params, "session")
	if serr != nil {
		return nil, serr
	}
	if !spresent {
		session = ""
	}

	res, verr := tracker.manager_record_verification(d.tracker, task, definition, outcome, output, session, ctx.allocator)
	if verr != nil {
		return nil, verr
	}
	out := jsonutil.json_object(3, ctx.allocator)
	jsonutil.obj_set(&out, "sprint_id", jsonutil.json_string(res.sprint_id))
	jsonutil.obj_set(&out, "task", jsonutil.json_string(res.task))
	jsonutil.obj_set(&out, "outcome", jsonutil.json_string(res.outcome))
	return json.Value(json.Object(out)), nil
}

handle_tracker_export :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	sprint, spresent, serr := file_opt_str(ctx, params, "sprint")
	if serr != nil {
		return nil, serr
	}
	if !spresent {
		sprint = ""
	}

	ack, eerr := tracker.manager_export(d.tracker, sprint, ctx.allocator)
	if eerr != nil {
		return nil, eerr
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "text", jsonutil.json_string(ack))
	return json.Value(json.Object(out)), nil
}
