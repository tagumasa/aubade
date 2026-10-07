// The two-writer round trip's daemon leg: the Edit_Apply_Port the svc
// routing face calls. It finds the owner child by its connection id, gates
// on the editor's declared applyEdit capability (no capable editor, no
// request, no direct write), pins the child against reaping for the
// call (the push face's discipline), and carries the editor's verdict back
// as the port's outcome. A failed call is Unavailable — the router turns
// that into an explicit edit failure; it is never a license to write the
// buffer directly.
package daemon

import "core:mem"
import "core:sync"

import "src:jsonutil"
import "src:platform"
import "src:svc"

daemon_edit_apply_port :: proc(
	user: rawptr,
	owner_conn: int,
	changes: []svc.Edit_Doc_Changes,
	label: string,
	token: ^platform.Cancel_Token,
	deadline_ms: i64,
	a: mem.Allocator,
) -> (svc.Edit_Apply_Outcome, string) {
	d := cast(^Daemon)user
	if d.doc_sync == nil {
		return .Unavailable, "the document-sync face is unavailable"
	}

	// Lookup, gate, and pin under children_mu (the allowed lock order;
	// children_mu stays quick — never held over a send). The pin keeps the
	// reaper's close_child off the conn while the call is in flight. The
	// port runs only on the daemon's worker pool (the routing faces calling
	// it — the svc edit, rename, and whole-file write handlers — are pool
	// tasks; the doc-sync apply worker never routes through it), and the
	// pool stops before the teardown pass closes the children — so no new
	// pin starts during that pass, and its drain waits out (or deliberately
	// leaks around) any pin still held.
	sync.mutex_lock(&d.children_mu)
	child := find_child_locked(d, owner_conn)
	if child == nil || child.state != .Live || !child.is_lsp || !child.is_hello_seen {
		sync.mutex_unlock(&d.children_mu)
		return .Unavailable, "the owning editor child is not connected"
	}
	sync.mutex_lock(&child.mu)
	capable := child.has_apply_edit && child.has_document_changes
	sync.mutex_unlock(&child.mu)
	if !capable {
		sync.mutex_unlock(&d.children_mu)
		return .Unavailable, "the editor did not declare workspace.applyEdit with documentChanges support"
	}
	child_push_pin(child)
	sync.mutex_unlock(&d.children_mu)
	defer child_push_release(d, child)

	changes_json := svc.two_writer_changes_json(changes, d.cfg.project_root, a)
	cc := svc.client_edit_apply(child.conn, changes_json, label, a, deadline_ms, token)
	if cc.call_err != .None {
		return .Unavailable, cc.err_message
	}
	applied := jsonutil.obj_get_bool(cc.result, "applied")
	reason := ""
	if v, ok := jsonutil.obj_get(cc.result, "reason"); ok {
		reason = jsonutil.value_str(v)
	}
	if applied {
		return .Applied, reason
	}
	return .Rejected, reason
}
