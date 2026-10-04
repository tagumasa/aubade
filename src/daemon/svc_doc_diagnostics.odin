// The svc.doc/diagnostics handler: the daemon-side syntax-diagnostics
// computation face. Read-only — the response is a computed view over the
// document's current bytes plus its version, and nothing mutates — so it
// registers through the plain table, not the mutating mark. The
// diagnostics are SYNTAX ONLY (ERROR and MISSING nodes from the
// tree-sitter walk): they claim what a parse can prove, never semantics.
// Debounce/publish and the live-language-server merge are later phases
// that consume this face's answer.
//
// Version contract: when the path is a synced document (opened through
// svc.doc/open and not yet closed) whose buffer is still held, `version`
// is the version home's last applied version and `has_version` is true;
// when no synced document is open — or the synced document's buffer was
// LRU-evicted, so the bytes are disk truth the version does not
// describe — `has_version` is false (version 0). Either way the version
// and the bytes are read
// under one file-lock hold, so the answer never pairs one document's
// version with another document's bytes — and the response's version is
// THE VERSION THE COMPUTATION USED, carried as data: a didChange that
// lands between the apply and this walk cannot invalidate the answer,
// because the child stamps the publisher with what this face reports
// rather than guessing from apply ordering.
package daemon

import "core:encoding/json"
import "src:jsonutil"
import "src:platform"
import "src:svc"
import "src:ts"

register_doc_diagnostics_methods :: proc(t: ^svc.Table) {
	svc.table_register(t, svc.METHOD_DOC_DIAGNOSTICS, handle_doc_diagnostics)
}

// handle_doc_diagnostics answers {version, has_version, decline,
// truncated, diagnostics} for one project file. The version contract is
// the one in this file's header: the version and the bytes leave the same
// file-lock hold. `diagnostics` entries are {kind, start_byte, end_byte,
// message} with byte ranges against the answered bytes — the UTF-16/point
// conversion for relay to editors happens at the relay layer, not here.
// The ranges ride the walk's ascending order, and a list past
// ts.DIAGNOSTICS_MAX is cut to it with `truncated` set — observable, never
// silent.
handle_doc_diagnostics :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	rel_raw, err := file_require_str(ctx, params, "relative_path")
	if err != nil {
		return nil, err
	}
	rel, perr := svc.doc_sync_check_path(d.doc_sync, rel_raw, ctx.allocator)
	if perr != nil {
		return nil, perr
	}

	text, version, has_version, rerr := doc_current_view(d, rel, "doc/diagnostics", ctx.allocator)
	if rerr != nil {
		return nil, rerr
	}

	decline := ""
	diags: []ts.Diagnostic = nil
	lang := svc.lang_for_file(d.ts, rel)
	if lang == "" {
		decline = "no_grammar"
	} else if len(text) > ts.HIGHLIGHTS_MAX_SOURCE_BYTES {
		// The same magnitude the highlights face gates on: this face
		// parses the same class of source (one fresh whole-file parse of
		// a document the child synced), so it inherits the one bound
		// instead of minting a second number for the same rule.
		decline = "source_too_large"
	} else {
		pr, parse_err := ts.parse(text, lang)
		if parse_err != "" {
			// parse's only failure mode is language resolution. This face
			// holds no per-language holder to rule it out beforehand, so a
			// registry row whose grammar is unavailable on this platform
			// surfaces here — an internal defect, not a ladder rung.
			return nil, svc.wrapped_err(.Internal, parse_err, ctx.allocator)
		}
		// Block-scope defer, on purpose: the walk below consumes the tree
		// within this block, so releasing here is exactly the tree's
		// lifetime — a procedure-scope defer would only delay it. The
		// walked diagnostics are value records over constant messages, so
		// they survive the release and live in the request arena.
		defer ts.parse_release(&pr)
		diags = ts.diagnostics_tree(pr.tree, ctx.allocator)
	}

	// The walk result stays arena-owned (freed by the request's free_all,
	// like the highlights face's captures); only the wire view is cut.
	truncated := len(diags) > ts.DIAGNOSTICS_MAX
	count := len(diags)
	if truncated {
		count = ts.DIAGNOSTICS_MAX
	}
	arr := make([dynamic]json.Value, 0, count, ctx.allocator)
	for i in 0..<count {
		dg := &diags[i]
		m := jsonutil.json_object(4, ctx.allocator)
		jsonutil.obj_set(&m, "kind", jsonutil.json_string(diag_kind_str(dg.kind)))
		jsonutil.obj_set(&m, "start_byte", jsonutil.json_int(i64(dg.start_byte)))
		jsonutil.obj_set(&m, "end_byte", jsonutil.json_int(i64(dg.end_byte)))
		jsonutil.obj_set(&m, "message", jsonutil.json_string(dg.message))
		append(&arr, json.Value(json.Object(m)))
	}
	out := jsonutil.json_object(5, ctx.allocator)
	jsonutil.obj_set(&out, "version", jsonutil.json_int(i64(version)))
	jsonutil.obj_set(&out, "has_version", jsonutil.json_bool(has_version))
	jsonutil.obj_set(&out, "decline", jsonutil.json_string(decline))
	jsonutil.obj_set(&out, "truncated", jsonutil.json_bool(truncated))
	jsonutil.obj_set(&out, "diagnostics", json.Value(json.Array(arr)))
	return json.Value(json.Object(out)), nil
}

// diag_kind_str names the wire kinds: the walk's two-member damage
// vocabulary as the lowercase strings a client branches on.
diag_kind_str :: proc(k: ts.Diagnostic_Kind) -> string {
	switch k {
	case .Error:
		return "error"
	case .Missing:
		return "missing"
	}
	return ""
}
