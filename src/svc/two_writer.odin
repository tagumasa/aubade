// The two-writer routing face: when an lsp child owns a document
// (last didOpen), every tool edit to it crosses the owner child's
// workspace/applyEdit instead of writing the daemon buffer directly — the
// editor applies, the user sees it, and the didChange echo flows back
// through the document-sync face as the ordinary keystroke path. The face
// is the round trip's referee: it pins the observed version V into every
// apply (documentChanges, never the version-less `changes` form), answers
// the tool only after `applied=true` AND the echo advanced the applied
// version past V, retries version-mismatch rejections against the fresh
// text within one bounded monotonic deadline, and turns every unrouteable
// shape (stuck editor, capability-less editor, deadline) into an explicit
// failure — never a silent fallback to the direct write (that fallback is
// reserved for the owner going away, which returns the document to the
// non-open state). No file lock is held across the wait: the echo's
// apply takes the same lock (doc_sync_apply_under_file_lock), and holding
// it would self-deadlock the round trip.
package svc

import "core:encoding/json"
import "core:mem"
import "core:path/filepath"
import "core:strings"

import "src:editor"
import "jsonutil:jsonutil"
import "src:platform"
import "src:symbol"
import "src:util"

// The round trip's budget: one bounded monotonic deadline across every
// attempt (retries included — the count is bounded by the deadline, not by
// a separate counter). The apply wait inside the child and the echo's own
// apply path both sit well under it.
TWO_WRITER_DEADLINE_MS :: 10_000

// Edit_Range is one UTF-16 range (zero-based line, UTF-16 column) — the
// svc face's column convention end to end.
Edit_Range :: struct {
	sl, sc, el, ec: int,
}

// Edit_Item is one range edit. new_text borrows its bytes (the compute's
// arena outlives the apply call).
Edit_Item :: struct {
	rng:     Edit_Range,
	new_text: string,
}

// Edit_Doc_Changes is one document's edit list — the wire's
// TextDocumentEdit. pinned carries the observed version V the edits were
// computed against (the pre-apply check the editor runs); an unpinned
// change is one for a document no child owns, which the editor applies to
// disk.
Edit_Doc_Changes :: struct {
	rel_path: string,
	version:  i32,
	pinned:   bool,
	edits:    []Edit_Item,
}

// Edit_Apply_Outcome is one apply attempt's verdict. Applied means the
// editor accepted the version-pinned edit (so its document was exactly V
// at apply time); Rejected means the editor refused — for a
// vscode-languageclient the version check — and the echo still has to
// catch up; Unavailable means no capable owner child carried the request.
Edit_Apply_Outcome :: enum {
	Applied,
	Rejected,
	Unavailable,
}

// Edit_Apply_Port sends one svc.edit/apply to the owner child and waits
// out its bounded round trip. The daemon implements it (child lookup and
// pinning by connection id, conn_call); the face knows only the id.
Edit_Apply_Port :: proc(
	user: rawptr,
	owner_conn: int,
	changes: []Edit_Doc_Changes,
	label: string,
	token: ^platform.Cancel_Token,
	deadline_ms: i64,
	a: mem.Allocator,
) -> (Edit_Apply_Outcome, string)

// Two_Writer_Compute produces one attempt's edits against the document's
// CURRENT state (it re-reads whatever it resolves against). `basis`
// returns the exact bytes the ranges were derived from — the router
// verifies them against the freshly read document text and recomputes on a
// race. An empty basis (edits from another source, e.g. a language
// server's rename reply) skips the check; there the version pin alone
// guards the apply.
Two_Writer_Compute :: proc(user: rawptr, a: mem.Allocator) -> (changes: []Edit_Doc_Changes, basis: string, err: platform.Err)

// Two_Writer is the face state. The daemon holds one over its doc-sync
// face and editor; tests build it over the same pair.
Two_Writer :: struct {
	ds:          ^Doc_Sync,
	ed:          ^editor.Editor,
	apply:       Edit_Apply_Port,
	apply_user:  rawptr,
	deadline_ms: i64,
}

two_writer_init :: proc(tw: ^Two_Writer, ds: ^Doc_Sync, ed: ^editor.Editor, apply: Edit_Apply_Port, apply_user: rawptr) {
	tw^ = {
		ds          = ds,
		ed          = ed,
		apply       = apply,
		apply_user  = apply_user,
		deadline_ms = TWO_WRITER_DEADLINE_MS,
	}
}

// two_writer_owned reports whether an lsp child currently owns rel.
two_writer_owned :: proc(tw: ^Two_Writer, rel: string) -> bool {
	if tw == nil || tw.ds == nil {
		return false
	}
	owner, has := doc_sync_owner_of(tw.ds, rel)
	return has && owner != 0
}

// two_writer_route runs the round trip for one tool edit. routed=false
// says the document is not editor-owned — the caller takes its ordinary
// direct path. routed=true says the round trip owned the outcome: err=nil
// on a confirmed apply (or a compute that had nothing to change), otherwise
// the explicit failure — never a direct-write fallback for an owned
// document.
two_writer_route :: proc(
	tw: ^Two_Writer,
	rel: string,
	label: string,
	compute: Two_Writer_Compute,
	compute_user: rawptr,
	token: ^platform.Cancel_Token,
	a: mem.Allocator,
) -> (routed: bool, err: platform.Err) {
	if !two_writer_owned(tw, rel) {
		return false, nil
	}
	deadline := platform.mono_ms() + tw.deadline_ms
	for {
		if terr := two_writer_gate(token, deadline, a); terr != nil {
			return true, terr
		}
		// One consistent read of the state the edit is admitted against:
		// the version pinned into the apply and the text the compute is
		// checked against are the same read.
		text, version, has_version, owner, ok := doc_sync_edit_view(tw.ds, tw.ed, rel, a)
		if !ok || owner == 0 {
			// The document returned to the non-open state while this edit
			// waited (owner close or disconnect): the direct path resumes,
			// and the caller's next attempt re-resolves against it.
			return false, nil
		}
		changes, basis, cerr := compute(compute_user, a)
		if cerr != nil {
			return true, cerr
		}
		if len(changes) == 0 {
			return true, nil // the compute found nothing to change
		}
		// The router owns the version stamping: the compute never guesses
		// the version its ranges are pinned to.
		for i in 0..<len(changes) {
			changes[i].version = version
			changes[i].pinned = true
		}
		if !has_version {
			return true, wrapped_err(.Internal, "owned document carries no applied version to pin", a)
		}
		// A compute that raced a didChange derived its ranges from bytes
		// version V no longer describes: sending them pinned to V would
		// misapply at exactly the wrong offsets. Recompute instead.
		if basis != "" && basis != text {
			continue
		}
		settled, retry, serr := two_writer_settle(tw, rel, owner, version, changes, label, token, deadline, a)
		if settled || serr != nil {
			return true, serr
		}
		if !retry {
			return true, wrapped_err(.Retryable, "the applyEdit round trip did not settle within its deadline", a)
		}
	}
}

// two_writer_write_file routes one whole-file overwrite through the owner
// child: the disk commit stays the editor's save, and the daemon buffer is
// fed by the echo. routed=false leaves the ordinary disk write to the
// caller. The edit is one version-pinned replace of the document's full
// range, computed from the same critical-section read that supplies the
// version, so no separate basis check is needed.
two_writer_write_file :: proc(tw: ^Two_Writer, rel: string, content: string, token: ^platform.Cancel_Token, a: mem.Allocator) -> (routed: bool, err: platform.Err) {
	if !two_writer_owned(tw, rel) {
		return false, nil
	}
	deadline := platform.mono_ms() + tw.deadline_ms
	for {
		if terr := two_writer_gate(token, deadline, a); terr != nil {
			return true, terr
		}
		text, version, has_version, owner, ok := doc_sync_edit_view(tw.ds, tw.ed, rel, a)
		if !ok || owner == 0 {
			return false, nil // non-open again: the direct write resumes
		}
		if !has_version {
			return true, wrapped_err(.Internal, "owned document carries no applied version to pin", a)
		}
		rng, mid, has_diff := edit_range_of_diff(text, content, a)
		if !has_diff {
			return true, nil // the content already matches the document
		}
		edits := make([]Edit_Item, 1, a)
		edits[0] = Edit_Item{rng = rng, new_text = strings.clone(mid, a)}
		changes := make([]Edit_Doc_Changes, 1, a)
		changes[0] = Edit_Doc_Changes{rel_path = rel, version = version, pinned = true, edits = edits}
		settled, retry, serr := two_writer_settle(tw, rel, owner, version, changes, "file write", token, deadline, a)
		if settled || serr != nil {
			return true, serr
		}
		if !retry {
			return true, wrapped_err(.Retryable, "the applyEdit round trip did not settle within its deadline", a)
		}
	}
}

// two_writer_settle drives one apply attempt to its verdict. settled means
// the round trip concluded (err carries its outcome, nil = applied and
// confirmed); retry says another attempt — recompute included — still fits
// the deadline.
two_writer_settle :: proc(
	tw: ^Two_Writer,
	rel: string,
	owner: int,
	version: i32,
	changes: []Edit_Doc_Changes,
	label: string,
	token: ^platform.Cancel_Token,
	deadline: i64,
	a: mem.Allocator,
) -> (settled: bool, retry: bool, err: platform.Err) {
	outcome, reason := tw.apply(tw.apply_user, owner, changes, label, token, deadline, a)
	switch outcome {
	case .Applied:
		// The tool answers only when the echo moved the applied version
		// past V. A keystroke landing before this read is exactly
		// the advance looked for (the pinned apply plus the keystroke both
		// push the version) — the confirmation cannot false-fail.
		if doc_sync_wait_version_past(tw.ds, rel, version, deadline) {
			return true, false, nil
		}
		return true, false, wrapped_err(.Retryable, "the editor applied the edit but its echo did not confirm within the deadline", a)
	case .Rejected:
		// The editor's document moved off V (keystrokes landed
		// mid-round-trip). Wait for the echo to catch up; the retry
		// recomputes against the fresh text. The deadline bounds it all.
		if doc_sync_wait_version_past(tw.ds, rel, version, deadline) {
			return false, true, nil
		}
		return false, false, wrapped_err(.Retryable, "the document did not catch up within the deadline", a)
	case .Unavailable:
		// No capable owner child carried the request (dead child, missing
		// handler, editor without workspace.applyEdit): an explicit
		// failure — never a silent direct write to an open document.
		// Ownership clearing separately is the one path back to the direct
		// write.
		return true, false, wrapped_err(.Retryable, reason, a)
	}
	return true, false, wrapped_err(.Internal, "unreachable apply outcome", a)
}

// two_writer_gate is the loop's shared deadline and cancellation check.
two_writer_gate :: proc(token: ^platform.Cancel_Token, deadline: i64, a: mem.Allocator) -> platform.Err {
	if token != nil {
		if terr, fired := platform.token_check(token); fired {
			return terr
		}
	}
	if platform.mono_ms() >= deadline {
		return wrapped_err(.Retryable, "the applyEdit round trip did not settle within its deadline", a)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Diff reduction
// ---------------------------------------------------------------------------

// edit_range_of_diff reduces one whole-text transform to the single range
// edit that carries it: the longest common prefix and suffix trim leaves
// the replaced span in `old` (the edit's UTF-16 range) and the surviving
// middle of `new` (the edit's new_text). Either scan can stop mid-rune —
// its bytes matched but the rune did not — so both trim points back off to
// a rune boundary before the range is cut. ok=false when the texts are
// equal — there is nothing to send.
edit_range_of_diff :: proc(old, new: string, a: mem.Allocator) -> (rng: Edit_Range, mid: string, ok: bool) {
	p := 0
	max_p := min(len(old), len(new))
	for p < max_p && old[p] == new[p] {
		p += 1
	}
	// Back off to a rune boundary. The crossed bytes are byte-equal on both
	// sides, so one text's rune boundary is the other's, and re-including
	// them in the range and in the replacement leaves the transform's
	// meaning unchanged. `p < len(old)` guards the pure append, where the
	// scan consumed all of `old` and the end-of-text offset is already a
	// boundary.
	for p > 0 && p < len(old) && (old[p] & 0xC0) == 0x80 {
		p -= 1
	}
	if p == len(old) && len(new) == len(old) {
		return rng, "", false
	}
	s := 0
	max_s := max_p - p
	for s < max_s && old[len(old)-1-s] == new[len(new)-1-s] {
		s += 1
	}
	// Same boundary back-off for the tail scan (see the prefix loop).
	for s > 0 && (old[len(old)-s] & 0xC0) == 0x80 {
		s -= 1
	}
	starts := util.line_start_offsets(old, a)
	rng.sl, rng.sc = utf16_pos_of_offset(old, starts, p)
	rng.el, rng.ec = utf16_pos_of_offset(old, starts, len(old)-s)
	mid = new[p : len(new)-s]
	return rng, mid, true
}

// utf16_pos_of_offset maps a byte offset in `text` onto its zero-based
// line and UTF-16 column, through the line-start index (the relay
// discipline: one index per computation, no per-position rescans). An
// offset at a line start belongs to that line; an offset past the last
// line's content (the phantom line of a trailing newline) is that line's
// column 0 — the document end a whole-file replace spans.
utf16_pos_of_offset :: proc(text: string, starts: []int, off: int) -> (line, col: int) {
	if len(starts) == 0 {
		return 0, 0
	}
	line = 0
	for line+1 < len(starts) && starts[line+1] <= off {
		line += 1
	}
	line_end := len(text)
	if line+1 < len(starts) {
		line_end = starts[line+1]
	}
	line_text_end := line_end
	if line_text_end > starts[line] && line_text_end <= len(text) && text[line_text_end-1] == '\n' {
		line_text_end -= 1
	}
	byte_col := off - starts[line]
	if byte_col < 0 {
		byte_col = 0
	}
	if byte_col > line_text_end-starts[line] {
		byte_col = line_text_end - starts[line]
	}
	col = util.byte_offset_to_utf16_col(text[starts[line]:line_text_end], byte_col)
	return
}

// ---------------------------------------------------------------------------
// Wire rendering (the daemon port's params half)
// ---------------------------------------------------------------------------

// two_writer_changes_json renders one change list into the svc.edit/apply
// params' document_changes array: daemon-canonical absolute file URIs and
// the UTF-16 columns the wire pins. The port implementations (daemon,
// tests) share it.
two_writer_changes_json :: proc(changes: []Edit_Doc_Changes, abs_root: string, a: mem.Allocator) -> json.Value {
	items := make([dynamic]json.Value, 0, len(changes), a)
	for ch in changes {
		uri := ""
		if abs, jerr := filepath.join([]string{abs_root, ch.rel_path}, a); jerr == nil {
			uri = symbol.file_uri(abs, a)
		}
		// The pinned svc.edit/apply shape is flat per change: {uri, version,
		// edits} — the child face re-spells it into the LSP TextDocumentEdit
		// (textDocument + pinned version) for the editor.
		doc := jsonutil.json_object(3, a)
		jsonutil.obj_set(&doc, "uri", jsonutil.json_string(uri))
		if ch.pinned {
			jsonutil.obj_set(&doc, "version", jsonutil.json_int(i64(ch.version)))
		}
		edits := make([dynamic]json.Value, 0, len(ch.edits), a)
		for e in ch.edits {
			start := jsonutil.json_object(2, a)
			jsonutil.obj_set(&start, "line", jsonutil.json_int(i64(e.rng.sl)))
			jsonutil.obj_set(&start, "character", jsonutil.json_int(i64(e.rng.sc)))
			end := jsonutil.json_object(2, a)
			jsonutil.obj_set(&end, "line", jsonutil.json_int(i64(e.rng.el)))
			jsonutil.obj_set(&end, "character", jsonutil.json_int(i64(e.rng.ec)))
			rng := jsonutil.json_object(2, a)
			jsonutil.obj_set_object(&rng, "start", start)
			jsonutil.obj_set_object(&rng, "end", end)
			item := jsonutil.json_object(2, a)
			jsonutil.obj_set_object(&item, "range", rng)
			jsonutil.obj_set(&item, "new_text", jsonutil.json_string(e.new_text))
			append(&edits, json.Value(json.Object(item)))
		}
		jsonutil.obj_set(&doc, "edits", jsonutil.json_array(edits[:], a))
		append(&items, json.Value(json.Object(doc)))
	}
	return jsonutil.json_array(items[:], a)
}

// ---------------------------------------------------------------------------
// Multi-document round trip (rename: one WorkspaceEdit across files)
// ---------------------------------------------------------------------------

// two_writer_owned_any reports whether any of the rels is editor-owned.
two_writer_owned_any :: proc(tw: ^Two_Writer, rels: []string) -> bool {
	for rel in rels {
		if two_writer_owned(tw, rel) {
			return true
		}
	}
	return false
}

// two_writer_route_multi runs the round trip for a compute spanning
// several documents (the rename WorkspaceEdit). The gate is "any changed
// document is owned": when none is, routed=false sends the caller down its
// ordinary per-file direct path. When some are, ONLY the owned subset
// crosses the owner child's applyEdit (each entry pinned to its file's
// observed version at admission); the caller lands the unowned remainder
// through its direct path after the round trip confirms. On a confirmed
// settle, `landed` names the documents the round trip applied — the
// caller's decision input for what to skip: a landed file must not be
// re-applied directly even when its ownership vanished after the apply,
// and live ownership at loop time is not evidence that an edit landed.
// The confirmation waits on every owned file's echo together, inside the
// one bounded deadline.
two_writer_route_multi :: proc(
	tw: ^Two_Writer,
	label: string,
	compute: Two_Writer_Compute,
	compute_user: rawptr,
	token: ^platform.Cancel_Token,
	a: mem.Allocator,
) -> (routed: bool, landed: []string, err: platform.Err) {
	if tw == nil || tw.ds == nil {
		return false, nil, nil
	}
	deadline := platform.mono_ms() + tw.deadline_ms
	for {
		if terr := two_writer_gate(token, deadline, a); terr != nil {
			return true, nil, terr
		}
		changes, _, cerr := compute(compute_user, a)
		if cerr != nil {
			return true, nil, cerr
		}
		if len(changes) == 0 {
			return true, nil, nil
		}
		// Per-file admission: version pins for the owned files, and the
		// loop's exit when ownership has gone entirely (back to the direct
		// path). An owned file without an applied version has nothing to
		// pin against (its first apply is still in flight) — an explicit
		// failure, like the single-document gate, unless the owner vanished
		// between the two reads below: then the change stays unpinned and
		// the caller's direct path lands it.
		any_owned := false
		batch_owner := 0
		for i in 0..<len(changes) {
			changes[i].version = 0
			changes[i].pinned = false
			if owner, has := doc_sync_owner_of(tw.ds, changes[i].rel_path); has && owner != 0 {
				v, hv := doc_sync_last_applied_version(tw.ds, changes[i].rel_path)
				if !hv {
					// The ownership read and the version read are two
					// critical sections: a close landing between them is
					// the owner-vanished race, not a broken document.
					// Re-check, and only a file still owned with nothing
					// to pin fails explicitly.
					if o, still := doc_sync_owner_of(tw.ds, changes[i].rel_path); still && o != 0 {
						return true, nil, wrapped_err(.Internal, "owned document carries no applied version to pin", a)
					}
					continue
				}
				changes[i].version = v
				changes[i].pinned = true
				any_owned = true
				if batch_owner == 0 {
					batch_owner = owner
				} else if batch_owner != owner {
					// One batch rides one owner's applyEdit. A batch
					// spanning two owners would carry the other owner's
					// open document as an unpinned change, and the
					// receiving editor would write that file to disk under
					// its owner's live buffer — silently losing the owner's
					// unsaved state on its next save. Explicit failure only.
					return true, nil, wrapped_err(
						.Invalid,
						"the edit spans documents owned by different editor sessions; apply it from one session at a time",
						a,
					)
				}
			}
		}
		if !any_owned {
			return false, nil, nil
		}
		// Only the owned files cross the applyEdit. The owner child's face
		// answers for documents it has open, version pinned — an unowned
		// file has no such view, and sending it as an unpinned change would
		// land through the editor's disk write, stranding the daemon state
		// the direct apply re-truths. The caller learns the round trip
		// covered the owned subset and lands the remainder through its own
		// direct path.
		pinned := make([dynamic]Edit_Doc_Changes, 0, len(changes), a)
		for ch in changes {
			if ch.pinned {
				append(&pinned, ch)
			}
		}
		settled, retry, serr := two_writer_settle_multi(tw, pinned[:], label, token, deadline, a)
		if settled || serr != nil {
			if serr == nil {
				// Confirmed settle: the pinned entries are the documents
				// this round trip landed. Their spellings live in `a` (the
				// compute's allocator) and outlive the call, so the set
				// borrows them.
				landed = make([]string, len(pinned), a)
				for i in 0..<len(pinned) {
					landed[i] = pinned[i].rel_path
				}
			}
			return true, landed, serr
		}
		if !retry {
			return true, nil, wrapped_err(.Retryable, "the applyEdit round trip did not settle within its deadline", a)
		}
	}
}

// two_writer_settle_multi is the multi-document attempt verdict: Applied
// confirms every owned file's echo before the tool answers; Rejected waits
// out the catch-up of every owned file before the retry.
two_writer_settle_multi :: proc(
	tw: ^Two_Writer,
	changes: []Edit_Doc_Changes,
	label: string,
	token: ^platform.Cancel_Token,
	deadline: i64,
	a: mem.Allocator,
) -> (settled: bool, retry: bool, err: platform.Err) {
	owner := 0
	for ch in changes {
		if ch.pinned {
			if o, has := doc_sync_owner_of(tw.ds, ch.rel_path); has && o != 0 {
				owner = o
				break
			}
		}
	}
	outcome, reason := tw.apply(tw.apply_user, owner, changes, label, token, deadline, a)
	switch outcome {
	case .Applied:
		for ch in changes {
			if !ch.pinned {
				continue // unowned file: the editor applied it to disk
			}
			if !doc_sync_wait_version_past(tw.ds, ch.rel_path, ch.version, deadline) {
				if _, is_open := doc_sync_owner_of(tw.ds, ch.rel_path); !is_open {
					continue // the file closed mid-confirm: nothing more to wait for
				}
				return true, false, wrapped_err(.Retryable, "the editor applied the edit but its echo did not confirm within the deadline", a)
			}
		}
		return true, false, nil
	case .Rejected:
		// The single-document settle's rule, mirrored: the catch-up wait
		// decides retry versus the terminal timeout. A pinned file whose
		// version never moves past its pin can never confirm a retry either
		// — waiting the deadline out once and failing beats re-running the
		// whole compute until the gate deadline.
		for ch in changes {
			if ch.pinned && !doc_sync_wait_version_past(tw.ds, ch.rel_path, ch.version, deadline) {
				return true, false, wrapped_err(.Retryable, "the document did not catch up within the deadline", a)
			}
		}
		return false, true, nil
	case .Unavailable:
		return true, false, wrapped_err(.Retryable, reason, a)
	}
	return true, false, wrapped_err(.Internal, "unreachable apply outcome", a)
}
