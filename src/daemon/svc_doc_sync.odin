// The svc.doc/* handlers: parse the wire params (relative_path, version,
// content, and the open's language_id), drive the daemon's document-sync
// face, and shape the answer. All three are mutating: a read-only project
// refuses them at the boundary (the glue's mutating mark), and the editor
// surface degrades to serving disk state there — never a silent no-op.
package daemon

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:sync"
import "src:editor"
import "jsonutil:jsonutil"
import "src:platform"
import "src:svc"

register_doc_sync_methods :: proc(t: ^svc.Table) {
	svc.table_register_mutating(t, svc.METHOD_DOC_OPEN, handle_doc_open)
	svc.table_register_mutating(t, svc.METHOD_DOC_CHANGE, handle_doc_change)
	svc.table_register_mutating(t, svc.METHOD_DOC_CLOSE, handle_doc_close)
}

// doc_sync_version_param reads the client document version: required, an
// integer, and within the i32 range both LSP sides assign the field.
doc_sync_version_param :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (i32, platform.Err) {
	if v, ok := jsonutil.obj_get(params, "version"); ok {
		#partial switch x in v {
		case json.Integer:
			return svc.doc_sync_check_version(i64(x), ctx.allocator)
		case:
			return 0, param_type_err(ctx, "version", "an integer")
		}
	}
	return 0, svc.wrapped_err(.Invalid, "version is required", ctx.allocator)
}

// doc_sync_outcome_json renders an open/change answer: the document's last
// applied version at answer time plus the supersede marker.
doc_sync_outcome_json :: proc(o: svc.Doc_Sync_Outcome, a: mem.Allocator) -> json.Value {
	out := jsonutil.json_object(2, a)
	jsonutil.obj_set(&out, "version", jsonutil.json_int(i64(o.version)))
	jsonutil.obj_set(&out, "superseded", jsonutil.json_bool(o.superseded))
	return json.Value(json.Object(out))
}

// doc_current_view reads one document's current bytes together with its
// last applied version under a single file-lock hold, so an answer never
// pairs one document's version with another document's bytes. Pairing
// rule: bytes and version travel together only when the version's buffer
// is the bytes' source. The version record survives an editor-buffer
// eviction, but the read's miss arm would then serve disk bytes — so a
// versioned document whose buffer is gone answers in the
// no-synced-document shape (has_version=false, version 0) rather than
// stamping disk bytes as the applied version. Lock order
// is the documented one: the editor's per-file lock (h.mu held between
// file_lock and file_release) -> Doc_Sync.mu; the read half locks e.mu,
// never h.mu itself, so the same hold cannot self-deadlock. Both values
// clone out before the lock releases, and parsing runs strictly after.
// `op` names the calling face in the read error; the returned text is the
// caller's clone (allocated in `a`), and the editor's copy dies here.
doc_current_view :: proc(d: ^Daemon, rel, op: string, a: mem.Allocator) -> (text: string, version: i32, has_version: bool, err: platform.Err) {
	h := editor.file_lock(d.ed, rel)
	sync.mutex_lock(&h.mu)
	version, has_version = svc.doc_sync_last_applied_version(d.doc_sync, rel)
	if has_version {
		// Presence is stable under this hold: a buffer drop takes the
		// same per-file lock (editor_drop_buffer holds file_lock/h.mu).
		// The buffers map itself is e.mu-guarded (the editor's leaf
		// lock; order file-lock -> e.mu), so the lookup takes e.mu too.
		// Absent here means the applied version's bytes are gone and the
		// read below would serve disk — drop the stamp, keep the pair
		// consistent.
		sync.mutex_lock(&d.ed.mu)
		_, present := d.ed.buffers[platform.path_fold(rel, context.temp_allocator)]
		sync.mutex_unlock(&d.ed.mu)
		if !present {
			version, has_version = 0, false
		}
	}
	contents, rerr, rmsg := editor.editor_read_file_locked(d.ed, rel)
	sync.mutex_unlock(&h.mu)
	editor.file_release(d.ed, rel)
	if rerr != .None {
		return "", 0, false, svc.editor_err_map(op, rerr, rmsg, a)
	}
	// The editor-owned bytes move into the request arena; the editor's
	// copy dies here (its allocator outlives the request).
	text = strings.clone(contents, a)
	delete(contents, d.ed.allocator)
	return text, version, has_version, nil
}

handle_doc_open :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	rel, err := file_require_str(ctx, params, "relative_path")
	if err != nil {
		return nil, err
	}
	// The client's language id travels with the open as the document's
	// declared language (consumed by the later language-keyed faces); an
	// opener that sends none falls back to extension-based detection.
	language_id, _, lerr := file_opt_str(ctx, params, "language_id")
	if lerr != nil {
		return nil, lerr
	}
	version, verr := doc_sync_version_param(ctx, params)
	if verr != nil {
		return nil, verr
	}
	content, cerr := file_present_str(ctx, params, "content")
	if cerr != nil {
		return nil, cerr
	}

	// The two-writer ownership claim: an lsp-mode child's open makes
	// it the document's owner — last didOpen wins — and carries the
	// editor's applyEdit capability bits the routing gate refuses on. A
	// non-lsp sync (the MCP child never opens documents this way) stays
	// unowned: direct writes and synchronous saves apply to it.
	owner := 0
	if child := find_child(d, ctx.conn_id); child != nil {
		// is_lsp is children_mu-guarded (svc.hello rewrites it under the
		// same mutex) and find_child has already dropped that mutex, so
		// the flag reads in its own critical section. The capability bits
		// stay under child.mu, the lock that guards them.
		sync.mutex_lock(&d.children_mu)
		is_lsp := child.is_lsp
		sync.mutex_unlock(&d.children_mu)
		if is_lsp {
			owner = ctx.conn_id
			sync.mutex_lock(&child.mu)
			child.has_apply_edit = jsonutil.obj_get_bool(params, "apply_edit")
			child.has_document_changes = jsonutil.obj_get_bool(params, "document_changes")
			sync.mutex_unlock(&child.mu)
		}
	}

	outcome, serr := svc.doc_sync_open(
		d.doc_sync, rel, language_id, version, content,
		ctx.token, platform.mono_ms() + svc.DOC_SYNC_APPLY_DEADLINE_MS, ctx.allocator, owner,
	)
	if serr != nil {
		return nil, serr
	}
	return doc_sync_outcome_json(outcome, ctx.allocator), nil
}

handle_doc_change :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	rel, err := file_require_str(ctx, params, "relative_path")
	if err != nil {
		return nil, err
	}
	version, verr := doc_sync_version_param(ctx, params)
	if verr != nil {
		return nil, verr
	}
	content, cerr := file_present_str(ctx, params, "content")
	if cerr != nil {
		return nil, cerr
	}

	outcome, serr := svc.doc_sync_change(
		d.doc_sync, rel, version, content,
		ctx.token, platform.mono_ms() + svc.DOC_SYNC_APPLY_DEADLINE_MS, ctx.allocator,
	)
	if serr != nil {
		return nil, serr
	}
	return doc_sync_outcome_json(outcome, ctx.allocator), nil
}

handle_doc_close :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	rel, err := file_require_str(ctx, params, "relative_path")
	if err != nil {
		return nil, err
	}

	// The closer's identity scopes the close: a non-owner child's
	// didClose leaves the document open for its owner.
	if cerr := svc.doc_sync_close(d.doc_sync, rel, ctx.allocator, ctx.conn_id); cerr != nil {
		return nil, cerr
	}
	return empty_ok(ctx), nil
}
