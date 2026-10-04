// The svc.doc/highlights handler: the daemon-side semantic-token capture
// face. Read-only — the response is a computed view over the document's
// current bytes plus its version, and nothing mutates — so it registers
// through the plain table, not the mutating mark.
//
// Version contract: when the path is a synced document (opened through
// svc.doc/open and not yet closed), `version` is the version home's last
// applied version and `has_version` is true; when no synced document is
// open, `has_version` is false (version 0) and the content is disk truth
// via the editor read. Either way the version and the bytes are read
// under one file-lock hold, so the answer never pairs one document's
// version with another document's bytes.
package daemon

import "core:encoding/json"
import "src:jsonutil"
import "src:platform"
import "src:svc"
import "src:ts"

register_doc_highlights_methods :: proc(t: ^svc.Table) {
	svc.table_register(t, svc.METHOD_DOC_HIGHLIGHTS, handle_doc_highlights)
}

// handle_doc_highlights answers {version, has_version, decline, captures}
// for one project file. Version contract: when the path is a synced
// document (opened through svc.doc/open, not yet closed) whose buffer is
// still held, `version` is the version home's last applied version and
// `has_version` is true; when none is open — or the synced document's
// buffer was LRU-evicted, so the bytes are disk truth the version does
// not describe — `has_version` is false (version 0). Either way the
// version and the bytes leave the same file-lock hold, so the answer
// never pairs one document's version with another document's bytes.
handle_doc_highlights :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	rel_raw, err := file_require_str(ctx, params, "relative_path")
	if err != nil {
		return nil, err
	}
	rel, perr := svc.doc_sync_check_path(d.doc_sync, rel_raw, ctx.allocator)
	if perr != nil {
		return nil, perr
	}

	text, version, has_version, rerr := doc_current_view(d, rel, "doc/highlights", ctx.allocator)
	if rerr != nil {
		return nil, rerr
	}

	decline := ""
	captures: []ts.Highlight_Capture = nil
	lang := svc.lang_for_file(d.ts, rel)
	if lang == "" {
		decline = "no_grammar"
	} else if hl := svc.highlighter_for(d.ts, lang); hl == nil {
		// A nil holder caches a negative verdict: query-empty grammars
		// decline observably; anything else cached nil is a compile
		// refusal — an internal failure, not a ladder rung.
		if svc.highlights_query_empty(lang) {
			decline = "no_query"
		} else {
			return nil, svc.wrapped_err(.Internal, "highlights query failed to compile", ctx.allocator)
		}
	} else if len(text) > ts.HIGHLIGHTS_MAX_SOURCE_BYTES {
		decline = "source_too_large"
	} else {
		pr, parse_err := ts.parse(text, lang)
		if parse_err != "" {
			// parse's only failure mode is language resolution, which the
			// holder's existence already ruled out — anything here is
			// internal.
			return nil, svc.wrapped_err(.Internal, parse_err, ctx.allocator)
		}
		// Block-scope defer, on purpose: the run below consumes the tree
		// within this block, so releasing here is exactly the tree's
		// lifetime — a procedure-scope defer would only delay it.
		defer ts.parse_release(&pr)
		run := ts.highlights_run(hl, pr.tree, text, ctx.allocator)
		switch run.decline {
		case .None, .Query_Empty, .Source_Too_Large, .Capture_Bound:
		case .Nil_Tree, .Nil_Holder, .Internal:
			return nil, svc.wrapped_err(.Internal, "highlights run failed", ctx.allocator)
		}
		decline = hl_decline_str(run.decline)
		captures = run.captures
	}

	arr := make([dynamic]json.Value, 0, len(captures), ctx.allocator)
	for c in captures {
		m := jsonutil.json_object(3, ctx.allocator)
		jsonutil.obj_set(&m, "name", jsonutil.json_string(c.name))
		jsonutil.obj_set(&m, "start_byte", jsonutil.json_int(i64(c.start_byte)))
		jsonutil.obj_set(&m, "end_byte", jsonutil.json_int(i64(c.end_byte)))
		append(&arr, json.Value(json.Object(m)))
	}
	out := jsonutil.json_object(4, ctx.allocator)
	jsonutil.obj_set(&out, "version", jsonutil.json_int(i64(version)))
	jsonutil.obj_set(&out, "has_version", jsonutil.json_bool(has_version))
	jsonutil.obj_set(&out, "decline", jsonutil.json_string(decline))
	jsonutil.obj_set(&out, "captures", json.Value(json.Array(arr)))
	return json.Value(json.Object(out)), nil
}

// hl_decline_str names the ladder rungs the face reports: an empty string
// is success, the rest are the typed declines a caller can branch on.
// Engine faults (Nil_Tree and kin) never reach here — the handler turns
// them into internal errors before mapping.
hl_decline_str :: proc(d: ts.Highlight_Decline) -> string {
	switch d {
	case .None:
		return ""
	case .Query_Empty:
		return "no_query"
	case .Source_Too_Large:
		return "source_too_large"
	case .Capture_Bound:
		return "capture_bound"
	case .Nil_Tree, .Nil_Holder, .Internal:
		return ""
	}
	return ""
}
