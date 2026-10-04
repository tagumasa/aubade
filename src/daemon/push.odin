// The daemon→child push face: relays real-LS diagnostics and language
// server running transitions to the children that declared themselves LSP
// frontends at hello (mode=="lsp"). Notifications only, fire-and-forget —
// conn_notify posts to the child's bounded outbound queue and drops on a
// full or closed one (the notification policy: load sheds at the source),
// so the LS reader thread and the manager transitions that feed this
// face never block on a slow child.
package daemon

import "core:encoding/json"
import "core:sync"

import "src:jsonrpc"
import "src:jsonutil"
import "src:svc"

// push_diagnostics_to_lsp_children relays one stored diagnostics set —
// the marshaled LSP Diagnostic[] the daemon's client store holds — to
// every live lsp-mode child. Runs on the language-server reader thread.
push_diagnostics_to_lsp_children :: proc(user: rawptr, uri: string, items_json: string) {
	d := cast(^Daemon)user
	params := jsonutil.json_object(2, context.temp_allocator)
	jsonutil.obj_set(&params, "uri", jsonutil.json_string(uri))
	jsonutil.obj_set(&params, "items", jsonutil.json_string(items_json))
	push_lsp_children(d, svc.METHOD_PUSH_DIAGNOSTICS, json.Value(json.Object(params)))
}

// push_langserver_state_to_lsp_children relays one real-LS running
// transition; the capability bits ride along and are meaningful only
// while running is true.
push_langserver_state_to_lsp_children :: proc(
	user: rawptr,
	language: string,
	running, references, declaration: bool,
) {
	d := cast(^Daemon)user
	params := jsonutil.json_object(4, context.temp_allocator)
	jsonutil.obj_set(&params, "language", jsonutil.json_string(language))
	jsonutil.obj_set(&params, "running", jsonutil.json_bool(running))
	jsonutil.obj_set(&params, "references", jsonutil.json_bool(references))
	jsonutil.obj_set(&params, "declaration", jsonutil.json_bool(declaration))
	push_lsp_children(d, svc.METHOD_PUSH_LANGSERVER_STATE, json.Value(json.Object(params)))
}

// push_lsp_children collects the live lsp-mode children under children_mu
// and notifies each OUTSIDE the lock (children_mu must stay quick — every
// svc handler takes it; it is never held over a send). Each snapshot
// entry pins the child through its outstanding-work counter before the
// unlock: the reaper frees a Closed child's conn, and a child can drain
// while these notifies run, so the pin is what keeps the conn alive under
// the notify (child_push_release completes the Closed transition when the
// pin was the last outstanding work, exactly like task_done).
push_lsp_children :: proc(d: ^Daemon, method: string, params: json.Value) {
	targets := make([dynamic]^Child, 0, 4, context.temp_allocator)
	defer delete(targets)
	sync.mutex_lock(&d.children_mu)
	// Teardown quiesce: daemon_cleanup sets the flag in the same critical
	// section that takes its children snapshot, and the language-server
	// threads feeding this face stop only later — a caller landing here
	// past the flag snapshots and pins nothing.
	if d.is_push_quiesced {
		sync.mutex_unlock(&d.children_mu)
		return
	}
	for child in d.children {
		if child.is_lsp && child.state == .Live {
			child_push_pin(child)
			append(&targets, child)
		}
	}
	sync.mutex_unlock(&d.children_mu)
	for child in targets {
		_ = jsonrpc.conn_notify(child.conn, method, params, context.temp_allocator)
		child_push_release(d, child)
	}
}

// child_push_pin takes one unit of outstanding work on the child — the
// same counter the pump and task_done gate the Closed transition on, so
// the child cannot be reaped (and its conn freed) while a push still
// references it. The caller holds children_mu (the allowed lock order).
child_push_pin :: proc(child: ^Child) {
	sync.mutex_lock(&child.mu)
	child.active += 1
	sync.mutex_unlock(&child.mu)
}

// child_push_release drops the push's pin and, when it was the last
// outstanding work on a drained child, completes the Draining -> Closed
// transition the pump would otherwise have completed.
child_push_release :: proc(d: ^Daemon, child: ^Child) {
	sync.mutex_lock(&child.mu)
	if child.active > 0 {
		child.active -= 1
	}
	drained := child.active == 0 && child.is_pump_done
	sync.mutex_unlock(&child.mu)
	if drained {
		child_mark_closed(d, child)
	}
}
