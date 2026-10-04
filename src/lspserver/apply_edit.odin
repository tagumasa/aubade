// The applyEdit forward: the child side of the two-writer round trip.
// The daemon's svc.edit/apply carries version-pinned UTF-16 edits in the
// daemon's canonical spelling; this face re-spells every document into the
// open view's own uri, converts the columns into the connection's
// negotiated encoding through the view's text (the relay.odin discipline),
// and forwards ONE workspace/applyEdit whose edit.documentChanges carries
// the version-pinned TextDocumentEdits — never the version-less `changes`
// form, whose unconditional apply is exactly the corruption the pin
// exists to prevent. The editor's own {applied, reason?} verdict passes
// through verbatim.
//
// Concurrency: like the registration wrappers, this runs OFF the dispatch
// thread (the child host's apply worker) — it must not park the dispatch
// loop behind a slow editor. View state is touched only through the
// mu-guarded helpers; the capability bits read under mu are written at
// initialize, and no apply can arrive before a document opened (which
// orders the write), the same edge the publish pass rides.
package lspserver

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"

import "src:jsonrpc"
import "src:jsonutil"
import "src:lsp"
import "src:platform"
import "src:util"

// server_apply_edits parses the svc.edit/apply params, gates on the
// negotiated capability bits, and forwards one workspace/applyEdit.
// applied=false always carries a reason.
server_apply_edits :: proc(s: ^Server, params: json.Value, arena: mem.Allocator, deadline_ms: i64) -> (applied: bool, reason: string) {
	if server_is_shutdown(s) {
		return false, "the lsp session is shutting down"
	}
	// An editor that did not declare both bits cannot take the pinned
	// documentChanges form — refuse without sending anything.
	apply_edit, document_changes := server_apply_caps(s)
	if !apply_edit || !document_changes {
		return false, "the editor did not declare workspace.applyEdit with documentChanges support"
	}

	changes_v, ok := jsonutil.obj_get(params, "document_changes")
	if !ok {
		return false, "svc.edit/apply carried no document_changes"
	}
	changes, is_arr := jsonutil.as_array(changes_v)
	if !is_arr || len(changes) == 0 {
		return false, "svc.edit/apply carried an empty document_changes"
	}

	docs := make([dynamic]json.Value, 0, len(changes), arena)
	for change in changes {
		uri := ""
		if uv, found := jsonutil.obj_get(change, "uri"); found {
			uri = jsonutil.value_str(uv)
		}
		if uri == "" {
			return false, "a document change carried no uri"
		}
		vv, has_v := jsonutil.obj_get(change, "version")
		if !has_v {
			return false, fmt.aprintf("a document change for %s carried no version", uri, allocator = arena)
		}
		version := jsonutil.value_int(vv)
		if version < DOC_VERSION_MIN || version > DOC_VERSION_MAX {
			return false, "a document version is outside the 32-bit range"
		}
		edits_v, has_e := jsonutil.obj_get(change, "edits")
		if !has_e {
			return false, fmt.aprintf("a document change for %s carried no edits", uri, allocator = arena)
		}
		edits, edits_arr := jsonutil.as_array(edits_v)
		if !edits_arr {
			return false, "document change edits is not an array"
		}

		// The daemon's canonical uri re-spells into the open view's own
		// spelling; the version and text come from the same snapshot, so
		// the column conversion and the pin describe one document state.
		snap, view_ok := server_snapshot_for_path(s, uri, arena)
		if !view_ok {
			return false, fmt.aprintf("document is not open here: %s", uri, allocator = arena)
		}

		// The change's line index is built once, not per endpoint: under a
		// utf-8 connection every edit's columns convert through the same
		// scan of the view's text.
		starts: []int
		if snap.encoding == .Utf8 {
			starts = util.line_start_offsets(snap.text, arena)
		}

		wire_edits := make([dynamic]json.Value, 0, len(edits), arena)
		for edit in edits {
			rng_v, rok := jsonutil.obj_get(edit, "range")
			if !rok {
				return false, "an edit carried no range"
			}
			start_v, sok := jsonutil.obj_get(rng_v, "start")
			end_v, eok := jsonutil.obj_get(rng_v, "end")
			text_v, tok := jsonutil.obj_get(edit, "new_text")
			if !sok || !eok || !tok {
				return false, "an edit is missing range start, end, or new_text"
			}
			sl := int(jsonutil.obj_get_int(start_v, "line"))
			sc := int(jsonutil.obj_get_int(start_v, "character"))
			el := int(jsonutil.obj_get_int(end_v, "line"))
			ec := int(jsonutil.obj_get_int(end_v, "character"))
			// The svc face is UTF-16 end to end; a utf-8 connection
			// converts every endpoint through the view's own bytes. Lines
			// and columns clamp inside the converter — never a UTF-16
			// number in a byte column.
			if snap.encoding == .Utf8 {
				sc = relay_target_byte_col(snap.text, starts, sl, sc)
				ec = relay_target_byte_col(snap.text, starts, el, ec)
			}
			start := jsonutil.json_object(2, arena)
			jsonutil.obj_set(&start, "line", jsonutil.json_int(i64(sl)))
			jsonutil.obj_set(&start, "character", jsonutil.json_int(i64(sc)))
			end := jsonutil.json_object(2, arena)
			jsonutil.obj_set(&end, "line", jsonutil.json_int(i64(el)))
			jsonutil.obj_set(&end, "character", jsonutil.json_int(i64(ec)))
			rng := jsonutil.json_object(2, arena)
			jsonutil.obj_set_object(&rng, "start", start)
			jsonutil.obj_set_object(&rng, "end", end)
			wire_edit := jsonutil.json_object(2, arena)
			jsonutil.obj_set_object(&wire_edit, "range", rng)
			jsonutil.obj_set(&wire_edit, "newText", jsonutil.json_string(jsonutil.value_str(text_v)))
			append(&wire_edits, json.Value(json.Object(wire_edit)))
		}

		td := jsonutil.json_object(2, arena)
		jsonutil.obj_set(&td, "uri", jsonutil.json_string(snap.uri))
		jsonutil.obj_set(&td, "version", jsonutil.json_int(i64(version)))
		doc := jsonutil.json_object(2, arena)
		jsonutil.obj_set_object(&doc, "textDocument", td)
		jsonutil.obj_set(&doc, "edits", jsonutil.json_array(wire_edits[:], arena))
		append(&docs, json.Value(json.Object(doc)))
	}

	edit := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&edit, "documentChanges", jsonutil.json_array(docs[:], arena))
	params_out := jsonutil.json_object(1, arena)
	jsonutil.obj_set_object(&params_out, "edit", edit)

	result, _, err_message, cerr := jsonrpc.conn_call(
		s.conn,
		lsp.METHOD_APPLY_EDIT,
		json.Value(json.Object(params_out)),
		arena,
		platform.mono_ms() + deadline_ms,
	)
	if cerr != .None {
		return false, fmt.aprintf("workspace/applyEdit failed: %s", err_message, allocator = arena)
	}
	// A null result is the pre-3.17 ack: the editor accepted the edit.
	if result == nil {
		return true, ""
	}
	if av, found := jsonutil.obj_get(result, "applied"); found {
		applied = jsonutil.value_bool(av)
	} else {
		applied = true
	}
	// ApplyWorkspaceEditResult spells the failure text "failureReason"
	// (LSP 3.17); the {applied, reason} shape is the svc leg's own, spelled
	// at the port that answers it, never by the editor.
	if rv, found := jsonutil.obj_get(result, "failureReason"); found {
		reason = jsonutil.value_str(rv)
	}
	return applied, reason
}

// server_snapshot_for_path finds the open view whose document path equals
// the daemon-canonical path behind `doc_uri` and snapshots it (uri in the
// client's spelling, text, version, negotiated encoding) under one mu
// hold. ok=false when no view matches — the document is closed here or
// another child owns it.
server_snapshot_for_path :: proc(s: ^Server, doc_uri: string, a: mem.Allocator) -> (snap: Doc_Snapshot, ok: bool) {
	path, path_ok := lsp.uri_to_path(doc_uri, a)
	if !path_ok {
		return
	}
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	for uri, v in s.docs {
		view_path, vok := lsp.uri_to_path(uri, a)
		if !vok {
			continue
		}
		if !platform.path_equal(view_path, path) {
			continue
		}
		snap.uri = strings.clone(v.uri, a)
		snap.text = strings.clone(v.text, a)
		snap.version = v.version
		snap.encoding = s.encoding
		ok = true
		return
	}
	return
}
