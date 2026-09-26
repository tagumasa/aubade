// The svc.langserver/* family: method names, the document-open seam the
// request methods share, and the wire renderers for their results. The
// lifecycle methods (start/stop/restart) spawn or stop daemon-owned
// processes and register as mutating; list and the request methods are
// reads (the request methods may still start a server on demand — the
// same ensure semantics every LSP read uses).
package svc

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:strings"

import "src:editor"
import "src:jsonutil"
import "src:lsp"
import "src:platform"
import "src:safety"
import "src:symbol"

METHOD_LANGSERVER_START :: "svc.langserver/start"        // {language} -> {}
METHOD_LANGSERVER_STOP :: "svc.langserver/stop"          // {language} -> {}
METHOD_LANGSERVER_RESTART :: "svc.langserver/restart"    // {language?} -> {}
METHOD_LANGSERVER_RELOAD :: "svc.langserver/reload"      // {} -> {overrides, stopped}
METHOD_LANGSERVER_LIST :: "svc.langserver/list"          // {} -> {items}|{message}
METHOD_LANGSERVER_DIAGNOSTICS :: "svc.langserver/diagnostics" // {relative_path} -> {items}
METHOD_LANGSERVER_CODE_ACTIONS :: "svc.langserver/code_actions" // {relative_path, start_line, start_col, end_line, end_col} -> {items}
METHOD_LANGSERVER_FORMAT :: "svc.langserver/format"      // {relative_path, tab_size?, insert_spaces?} -> {items}
METHOD_LANGSERVER_INLAY_HINTS :: "svc.langserver/inlay_hints" // {relative_path, start_line, start_col, end_line, end_col} -> {items}
METHOD_LANGSERVER_CALL_HIERARCHY :: "svc.langserver/call_hierarchy" // {relative_path, line, col, direction} -> {items}

// LANGSERVER_EMPTY_HINT is the list method's payload when no language
// server is configured or running — answered with a configuration hint
// instead of an empty array. Every
// route it names must work in a default session (where the management
// tools are inactive), so the primary route is config_set (always
// visible, applies live) and the optional tools are named as such.
LANGSERVER_EMPTY_HINT :: "No language servers are configured or running for this project. Set them up with config_set — it writes .aubade/project.jsonc, validates the value, and applies the settings live: name servers in language_servers (one {\"name\": <language id>, \"path\": <server binary>} object per server — path is the binary's OS location, absolute, \"~/\"-anchored, or project-root-relative; omitted or empty means normal PATH resolution), give servers needing arguments a full argv in language_server_commands (member = the language id), pass initialization options through language_server_options (member = the language id, value = the options object). config_get with include_schema documents every key. Editing the file by hand is the fallback; apply that with langserver_reload or a new session. A server can also be started directly with langserver_start, an optional tool — enable it via included_optional_tools when it is not active."

// langserver_result is the family's empty success envelope (start,
// stop, restart): the child composes the human text.
langserver_result :: proc(a: mem.Allocator) -> json.Value {
	return json.Value(json.Object(jsonutil.json_object(0, a)))
}

// ---------------------------------------------------------------------------
// Document-open seam
// ---------------------------------------------------------------------------

// Langserver_Doc is the resolved request context for one file: the
// serving client, the language that resolved it, and the document URI.
// release carries the port's server pin — call langserver_doc_release
// when the last request on client has completed.
Langserver_Doc :: struct {
	client:       ^lsp.Client,
	language_id:  string,
	uri:          string,
	release:      Client_Release_Proc,
	release_user: rawptr,
}

// langserver_doc_release pairs the open's didClose (the refcounted
// mirror keeps entries other openers still hold) and drops the server
// pin the open took.
langserver_doc_release :: proc(doc: Langserver_Doc) {
	if doc.client != nil && doc.uri != "" {
		_ = lsp.doc_close(doc.client, doc.uri)
	}
	if doc.release != nil && doc.client != nil {
		doc.release(doc.release_user, doc.client)
	}
}

// langserver_open_document resolves the language server for rel_path
// (starting one when none runs), reads the contents through the editor
// when a live buffer
// hides the disk, and makes sure the server sees the document (doc_open
// is refcounted per URI; langserver_doc_release pairs this open's
// didClose).
langserver_open_document :: proc(
	port: Client_For_File_Proc,
	user: rawptr,
	ed: ^editor.Editor,
	project_root: string,
	rel_path: string,
	arena: mem.Allocator,
	token: ^platform.Cancel_Token,
	release: Client_Release_Proc = nil,
) -> (Langserver_Doc, platform.Err) {
	rel := normalize_rel(rel_path, arena)
	if rel == "" {
		return {}, wrapped_err(.Invalid, "relative_path is required", arena)
	}
	abs, perr := safety.pathguard_validate_contained(project_root, rel, arena)
	if perr.reason != "" {
		return {}, wrapped_err(.Invalid, strings.concatenate({"invalid path: ", perr.reason}, arena), arena)
	}
	info, serr := os.stat(abs, arena)
	if serr != nil {
		return {}, wrapped_err(.NotFound, strings.concatenate({"path not found: ", rel}, arena), arena)
	}
	// The stat info's fullpath clone is owned by `arena`; take what is
	// needed and free it before the op continues.
	is_dir := info.type == .Directory
	os.file_info_delete(info, arena)
	if is_dir {
		return {}, wrapped_err(.Invalid, "path is a directory", arena)
	}

	client, language_id, _, cerr := port(user, rel, true, arena, token)
	if cerr != nil {
		return {}, cerr
	}

	// The shared editor-or-disk read: from_editor IS the ownership of
	// `contents` (editor allocator vs the request arena) — free through
	// the same flag, never through "was it empty".
	contents, from_editor, crerr := read_source_contents(ed, rel, abs, arena)
	if crerr != "" {
		// The port pinned the serving server for this document; the failed
		// read never returns a Langserver_Doc, so the pin drops here (the
		// same release langserver_doc_release performs on completion).
		if release != nil {
			release(user, client)
		}
		return {}, wrapped_err(
			.Internal,
			strings.concatenate({"read failed: ", crerr, ": ", rel}, arena),
			arena,
		)
	}
	defer if from_editor {
		delete(contents, ed.allocator)
	}

	uri := symbol.file_uri(abs, arena)
	_ = lsp.doc_open(client, uri, language_id, contents)
	return {client = client, language_id = language_id, uri = uri, release = release, release_user = user}, nil
}

// ---------------------------------------------------------------------------
// Result renderers (the wire DTO shapes)
// ---------------------------------------------------------------------------

// langserver_json_int reads an integer member; anything else reads 0.
langserver_json_int :: proc(v: json.Value, key: string) -> i64 {
	if f, ok := jsonutil.obj_get(v, key); ok {
		#partial switch x in f {
		case json.Integer:
			return i64(x)
		case:
		}
	}
	return 0
}

// SEVERITY_NAMES is indexed by the wire DiagnosticSeverity (1..4).
SEVERITY_NAMES :: [4]string{"error", "warning", "information", "hint"}

// langserver_severity_name maps the wire DiagnosticSeverity
// (1..4) to the diagnostics DTO's severity names.
langserver_severity_name :: proc(sev: json.Value) -> string {
	if n := jsonutil.value_int(sev); n >= 1 && n <= 4 {
		names := SEVERITY_NAMES
		return names[n - 1]
	}
	return ""
}

// langserver_diagnostics_json renders a raw wire diagnostics array into
// the flat DTO shape (severity by name, absolute positions). A nil or
// non-array input renders as an empty array.
langserver_diagnostics_json :: proc(items: json.Value, a: mem.Allocator) -> json.Value {
	arr, ok := jsonutil.as_array(items)
	if !ok {
		return jsonutil.json_array(nil, a)
	}
	out := make([]json.Value, len(arr), a)
	for i in 0..<len(arr) {
		item := arr[i]
		rng, _ := jsonutil.obj_get(item, "range")
		start, _ := jsonutil.obj_get(rng, "start")
		end, _ := jsonutil.obj_get(rng, "end")
		severity := jsonutil.json_string("")
		if sev_v, sok := jsonutil.obj_get(item, "severity"); sok {
			severity = jsonutil.json_string(langserver_severity_name(sev_v))
		}
		message := ""
		if msg_v, mok := jsonutil.obj_get(item, "message"); mok {
			message = jsonutil.value_str(msg_v)
		}
		dto := jsonutil.json_object(7, a)
		jsonutil.obj_set(&dto, "severity", severity)
		jsonutil.obj_set(&dto, "message", jsonutil.json_string(message))
		jsonutil.obj_set(&dto, "start_line", jsonutil.json_int(langserver_json_int(start, "line")))
		jsonutil.obj_set(&dto, "start_col", jsonutil.json_int(langserver_json_int(start, "character")))
		jsonutil.obj_set(&dto, "end_line", jsonutil.json_int(langserver_json_int(end, "line")))
		jsonutil.obj_set(&dto, "end_col", jsonutil.json_int(langserver_json_int(end, "character")))
		if src_v, sok := jsonutil.obj_get(item, "source"); sok {
			jsonutil.obj_set(&dto, "source", jsonutil.json_string(jsonutil.value_str(src_v)))
		}
		if code_v, cok := jsonutil.obj_get(item, "code"); cok {
			jsonutil.obj_set(&dto, "code", code_v)
		}
		out[i] = json.Value(json.Object(dto))
	}
	return jsonutil.json_array(out, a)
}

// langserver_text_edits_json renders formatting edits as the edits DTO
// array; the tool returns edits and never applies them.
langserver_text_edits_json :: proc(edits: []lsp.Text_Edit, a: mem.Allocator) -> json.Value {
	out := make([]json.Value, len(edits), a)
	for i in 0..<len(edits) {
		e := edits[i]
		dto := jsonutil.json_object(5, a)
		jsonutil.obj_set(&dto, "new_text", jsonutil.json_string(e.new_text))
		jsonutil.obj_set(&dto, "start_line", jsonutil.json_int(i64(e.range.start.line)))
		jsonutil.obj_set(&dto, "start_col", jsonutil.json_int(i64(e.range.start.character)))
		jsonutil.obj_set(&dto, "end_line", jsonutil.json_int(i64(e.range.end.line)))
		jsonutil.obj_set(&dto, "end_col", jsonutil.json_int(i64(e.range.end.character)))
		out[i] = json.Value(json.Object(dto))
	}
	return jsonutil.json_array(out, a)
}

// langserver_inlay_hints_json renders hints with the position flattened
// (line/column) and the full DTO field set: kind as its name, the
// padding flags, the flattened tooltip.
langserver_inlay_hints_json :: proc(hints: []lsp.Inlay_Hint, a: mem.Allocator) -> json.Value {
	out := make([]json.Value, len(hints), a)
	for i in 0..<len(hints) {
		h := hints[i]
		pos := jsonutil.json_object(2, a)
		jsonutil.obj_set(&pos, "line", jsonutil.json_int(i64(h.pos.line)))
		jsonutil.obj_set(&pos, "column", jsonutil.json_int(i64(h.pos.character)))
		dto := jsonutil.json_object(6, a)
		jsonutil.obj_set(&dto, "position", json.Value(json.Object(pos)))
		jsonutil.obj_set(&dto, "label", jsonutil.json_string(h.label))
		if kind := lsp.inlay_hint_kind_name(h.kind); kind != "" {
			jsonutil.obj_set(&dto, "kind", jsonutil.json_string(kind))
		}
		if h.tooltip != "" {
			jsonutil.obj_set(&dto, "tooltip", jsonutil.json_string(h.tooltip))
		}
		if h.padding_left {
			jsonutil.obj_set(&dto, "padding_left", jsonutil.json_bool(true))
		}
		if h.padding_right {
			jsonutil.obj_set(&dto, "padding_right", jsonutil.json_bool(true))
		}
		out[i] = json.Value(json.Object(dto))
	}
	return jsonutil.json_array(out, a)
}

// langserver_code_actions_json parses the heterogeneous raw codeAction
// reply into the DTO shape: title/kind/is_preferred/command and an edit
// whose URIs are relativized to the project root (an edit whose entries
// all escape the root is dropped; a missing title renders empty rather
// than dropping the action). Disabled and unparseable entries are
// skipped individually. The changes map AND the documentChanges array
// fold into one map — reading only the former would drop the edits of
// servers that answer with the latter.
langserver_code_actions_json :: proc(raw: json.Value, project_root: string, a: mem.Allocator) -> json.Value {
	items, ok := jsonutil.as_array(raw)
	if !ok {
		return jsonutil.json_array({}, a)
	}
	out := make([dynamic]json.Value, 0, len(items), a)
	for item in items {
		obj, ook := jsonutil.as_object(item)
		if !ook {
			continue
		}
		title := ""
		if title_v, has_title := obj["title"]; has_title {
			title = jsonutil.value_str(title_v)
		}
		if _, disabled := obj["disabled"]; disabled {
			continue
		}
		dto := jsonutil.json_object(5, a)
		jsonutil.obj_set(&dto, "title", jsonutil.json_string(title))
		if kind_v, kok := obj["kind"]; kok {
			if k := jsonutil.value_str(kind_v); k != "" {
				jsonutil.obj_set(&dto, "kind", jsonutil.json_string(k))
			}
		}
		if pref_v, pok := obj["isPreferred"]; pok {
			#partial switch x in pref_v {
			case json.Boolean:
				if x {
					jsonutil.obj_set(&dto, "is_preferred", jsonutil.json_bool(true))
				}
			case:
			}
		}
		if cmd_v, cok := obj["command"]; cok {
			if cmd, built := code_action_command_json(cmd_v, a); built {
				jsonutil.obj_set(&dto, "command", cmd)
			}
		}
		if edit_v, eok := obj["edit"]; eok {
			if edit, built := code_action_edit_json(edit_v, project_root, a); built {
				jsonutil.obj_set(&dto, "edit", edit)
			}
		}
		append(&out, json.Value(json.Object(dto)))
	}
	return jsonutil.json_array(out[:], a)
}

// code_action_command_json renders the command DTO (arguments passed
// through raw).
code_action_command_json :: proc(v: json.Value, a: mem.Allocator) -> (json.Value, bool) {
	obj, ok := jsonutil.as_object(v)
	if !ok {
		return nil, false
	}
	title_v, has_title := obj["title"]
	cmd_v, has_cmd := obj["command"]
	if !has_title || !has_cmd {
		return nil, false
	}
	dto := jsonutil.json_object(3, a)
	jsonutil.obj_set(&dto, "title", jsonutil.json_string(jsonutil.value_str(title_v)))
	jsonutil.obj_set(&dto, "command", jsonutil.json_string(jsonutil.value_str(cmd_v)))
	if args_v, aok := obj["arguments"]; aok {
		jsonutil.obj_set(&dto, "arguments", args_v)
	}
	return json.Value(json.Object(dto)), true
}

// code_action_edit_json folds the changes map and the documentChanges
// array into one {relative_path: [text edits]} map, relativizing every
// URI against the project root (unresolvable or escaping URIs drop
// their entries; an empty fold leaves the edit out).
code_action_edit_json :: proc(v: json.Value, project_root: string, a: mem.Allocator) -> (json.Value, bool) {
	obj, ok := jsonutil.as_object(v)
	if !ok {
		return nil, false
	}
	changes := jsonutil.json_object(4, a)
	added := 0
	if changes_v, cok := obj["changes"]; cok {
		if changes_obj, ook := jsonutil.as_object(changes_v); ook {
			for uri, edits_v in changes_obj {
				if code_action_add_file_edits(&changes, uri, edits_v, project_root, a) {
					added += 1
				}
			}
		}
	}
	if dc_v, dok := obj["documentChanges"]; dok {
		if dc_items, aok := jsonutil.as_array(dc_v); aok {
			for entry in dc_items {
				entry_obj, eok := jsonutil.as_object(entry)
				if !eok {
					continue
				}
				td_v, tok := entry_obj["textDocument"]
				if !tok {
					continue
				}
				uri_v, uok := jsonutil.obj_get(td_v, "uri")
				if !uok {
					continue
				}
				edits_v, gok := entry_obj["edits"]
				if !gok {
					continue
				}
				if code_action_add_file_edits(&changes, jsonutil.value_str(uri_v), edits_v, project_root, a) {
					added += 1
				}
			}
		}
	}
	if added == 0 {
		return nil, false
	}
	dto := jsonutil.json_object(1, a)
	jsonutil.obj_set(&dto, "changes", json.Value(json.Object(changes)))
	return json.Value(json.Object(dto)), true
}

// code_action_add_file_edits relativizes one URI's edit list into the
// shared changes map; false only when the URI is unresolvable or escapes
// the root. A file whose edits parse to nothing keeps an empty entry —
// the converted list is inserted whatever its length.
code_action_add_file_edits :: proc(changes: ^map[string]json.Value, uri: string, edits_v: json.Value, project_root: string, a: mem.Allocator) -> bool {
	path, pok := lsp.uri_to_path(uri, context.temp_allocator)
	if !pok {
		return false
	}
	rel := lsp.rel_path_for_root(project_root, path)
	if rel == "" {
		return false
	}
	out := make([dynamic]json.Value, 0, 4, a)
	if items, iok := jsonutil.as_array(edits_v); iok {
		for e in items {
			if dto, built := code_action_text_edit_json(e, a); built {
				append(&out, dto)
			}
		}
	}
	jsonutil.obj_set(changes, strings.clone(rel, a), jsonutil.json_array(out[:], a))
	delete(out)
	return true
}

// code_action_text_edit_json renders one edit in the shared text-edit
// DTO shape (new_text + the flattened range).
code_action_text_edit_json :: proc(v: json.Value, a: mem.Allocator) -> (json.Value, bool) {
	rng_v, rok := jsonutil.obj_get(v, "range")
	if !rok {
		return nil, false
	}
	new_text_v, nok := jsonutil.obj_get(v, "newText")
	if !nok {
		return nil, false
	}
	rng, _ := lsp.range_from_json(rng_v)
	dto := jsonutil.json_object(5, a)
	jsonutil.obj_set(&dto, "new_text", jsonutil.json_string(jsonutil.value_str(new_text_v)))
	jsonutil.obj_set(&dto, "start_line", jsonutil.json_int(i64(rng.start.line)))
	jsonutil.obj_set(&dto, "start_col", jsonutil.json_int(i64(rng.start.character)))
	jsonutil.obj_set(&dto, "end_line", jsonutil.json_int(i64(rng.end.line)))
	jsonutil.obj_set(&dto, "end_col", jsonutil.json_int(i64(rng.end.character)))
	return json.Value(json.Object(dto)), true
}

// langserver_call_edges_json renders incoming/outgoing edges with the
// endpoint named and the call-site ranges attached (the call-hierarchy
// DTO shape). Edges whose endpoint resolves outside the
// project root — no project-relative path, e.g. a stdlib callee returned
// by the language server — are dropped: every rendered entry must carry
// a followable relative_path.
langserver_call_edges_json :: proc(edges: []lsp.Call_Edge, a: mem.Allocator) -> json.Value {
	out := make([]json.Value, len(edges), a)
	n := 0
	for i in 0..<len(edges) {
		e := edges[i]
		if e.item.rel_path == "" {
			continue
		}
		dto := jsonutil.json_object(6, a)
		jsonutil.obj_set(&dto, "name", jsonutil.json_string(e.item.name))
		jsonutil.obj_set(&dto, "kind", jsonutil.json_string(symbol.kind_name(e.item.kind)))
		jsonutil.obj_set(&dto, "relative_path", jsonutil.json_string(e.item.rel_path))
		jsonutil.obj_set(&dto, "line", jsonutil.json_int(i64(e.item.range.start.line)))
		jsonutil.obj_set(&dto, "col", jsonutil.json_int(i64(e.item.range.start.character)))
		jsonutil.obj_set(&dto, "selection_line", jsonutil.json_int(i64(e.item.selection_range.start.line)))
		jsonutil.obj_set(&dto, "selection_col", jsonutil.json_int(i64(e.item.selection_range.start.character)))
		if len(e.from_ranges) > 0 {
			ranges := make([]json.Value, len(e.from_ranges), a)
			for j in 0..<len(e.from_ranges) {
				r := e.from_ranges[j]
				rng := jsonutil.json_object(4, a)
				jsonutil.obj_set(&rng, "start_line", jsonutil.json_int(i64(r.start.line)))
				jsonutil.obj_set(&rng, "start_col", jsonutil.json_int(i64(r.start.character)))
				jsonutil.obj_set(&rng, "end_line", jsonutil.json_int(i64(r.end.line)))
				jsonutil.obj_set(&rng, "end_col", jsonutil.json_int(i64(r.end.character)))
				ranges[j] = json.Value(json.Object(rng))
			}
			jsonutil.obj_set(&dto, "from_ranges", jsonutil.json_array(ranges, a))
		}
		out[n] = json.Value(json.Object(dto))
		n += 1
	}
	return jsonutil.json_array(out[:n], a)
}
