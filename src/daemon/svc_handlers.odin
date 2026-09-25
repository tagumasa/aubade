// The daemon's svc method implementations (hello/ping/status/bye/cancel)
// plus the shared echo registration. Handlers receive the daemon through
// Svc_Ctx.user.
package daemon

import "core:encoding/json"
import "core:fmt"
import "core:sync"
import "src:jsonutil"
import "src:langserver"
import "src:platform"
import "src:svc"

svc_table_init :: proc(t: ^svc.Table, d: ^Daemon) {
	if t.handlers != nil {
		// Already initialized — the in-process path (tests, --in-process)
		// initializes and pre-registers extra handlers before the run
		// thread starts; re-initializing would wipe them.
		return
	}
	svc.table_init(t, d.allocator)
	svc.table_register(t, svc.METHOD_HELLO, handle_hello)
	svc.table_register(t, svc.METHOD_PING, handle_ping)
	svc.table_register(t, svc.METHOD_STATUS, handle_status)
	svc.table_register(t, svc.METHOD_SHUTDOWN, handle_shutdown)
	svc.table_register_notification(t, svc.METHOD_BYE, handle_bye)
	svc.table_register_notification(t, svc.METHOD_CANCEL, handle_cancel)
	svc.table_register(t, svc.METHOD_ECHO, svc.echo)
	svc.table_register(t, svc.METHOD_SYMBOL_LIST, handle_symbol_list)
	svc.table_register(t, svc.METHOD_SYMBOL_FIND, handle_symbol_find)
	svc.table_register(t, svc.METHOD_SYMBOL_FIND_DEAD_CODE, handle_symbol_find_dead_code)
	svc.table_register(t, svc.METHOD_AST_FIND_DUPLICATES, handle_ast_find_duplicates)
	svc.table_register(t, svc.METHOD_INDEX_CRAWL, handle_index_crawl)
	register_file_methods(t)
	register_ast_methods(t)
	register_symbol_edit_methods(t)
	register_symbol_lsp_methods(t)
	register_langserver_methods(t)
	register_memory_methods(t)
	register_tracker_methods(t)
	register_shadow_methods(t)
	register_web_methods(t)
	register_config_methods(t)
}

// require_rpc_token enforces the loopback endpoint's possession proof on
// the token-bearing methods (hello, shutdown). The token is the one
// published in endpoint.json (0600, inside the 0700 daemon dir): loopback
// TCP accepts connections from any local process, so possession of the
// token is what proves the caller read our publication. The in-process
// channel daemon never generates one and its empty token skips the check.
// `kind` is the rejection class the endpoint's contract assigns — hello
// reports .Invalid, shutdown .Denied.
require_rpc_token :: proc(d: ^Daemon, params: json.Value, kind: platform.Err_Kind) -> platform.Err {
	if d.auth_token == "" {
		return nil
	}
	token := ""
	if v, ok := jsonutil.obj_get(params, "token"); ok {
		#partial switch x in v {
		case json.String:
			token = string(x)
		case:
		}
	}
	if token != d.auth_token {
		return platform.Wrapped{kind = kind, msg = "bad or missing rpc token"}
	}
	return nil
}

// handle_hello authenticates the child and registers the session.
handle_hello :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user

	if terr := require_rpc_token(d, params, .Invalid); terr != nil {
		return nil, terr
	}

	client_pid := 0
	if v, ok := jsonutil.obj_get(params, "client_pid"); ok {
		#partial switch x in v {
		case json.Integer:
			client_pid = int(x)
		case:
		}
	}

	// client_pid is shared Child state; write it under the owning mutex so
	// the heartbeat thread's iteration never races the store. is_hello_seen
	// opens the svc surface for this connection (the glue's hello gate).
	sync.mutex_lock(&d.children_mu)
	child := find_child_locked(d, ctx.conn_id)
	if child != nil {
		child.client_pid = client_pid
		child.is_hello_seen = true
	}
	sync.mutex_unlock(&d.children_mu)
	if child == nil {
		return nil, platform.Wrapped{kind = .Internal, msg = "connection not registered"}
	}

	// Frame tracing is daemon-wide: any session asking for it turns the
	// flag on for servers started from here on (running servers pick it
	// up on their next restart).
	trace_lsp := false
	if v, ok := jsonutil.obj_get(params, "trace_lsp"); ok {
		#partial switch x in v {
		case json.Boolean:
			trace_lsp = bool(x)
		case:
		}
	}
	if trace_lsp && d.ls != nil {
		langserver.manager_set_trace(d.ls, true)
	}

	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "daemon_pid", jsonutil.json_int(i64(d.pid)))
	return json.Value(json.Object(out)), nil
}

// handle_ping is the heartbeat round trip; RTT is measured by the caller.
handle_ping :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	if !touch_child(d, ctx.conn_id, platform.clock_now(d.cfg.clock)) {
		// A late ping was never cancelled; -32800 is reserved for confirmed
		// cancellations, so this answers as an invalid request instead.
		return nil, platform.Wrapped{kind = .Invalid, msg = "session not live"}
	}
	out := jsonutil.json_object(0, ctx.allocator)
	return json.Value(json.Object(out)), nil
}

// handle_status answers the daemon status query for the CLI (live/total
// children, published port, uptime bookkeeping).
handle_status :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user

	live := 0
	total := 0
	sync.mutex_lock(&d.children_mu)
	for child in d.children {
		total += 1
		if child.state == .Live {
			live += 1
		}
	}
	sync.mutex_unlock(&d.children_mu)

	out := jsonutil.json_object(5, ctx.allocator)
	jsonutil.obj_set(&out, "pid", jsonutil.json_int(i64(d.pid)))
	jsonutil.obj_set(&out, "port", jsonutil.json_int(i64(d.tcp_listener.port)))
	jsonutil.obj_set(&out, "started_at_ms", jsonutil.json_int(d.started_at_ms))
	jsonutil.obj_set(&out, "children_live", jsonutil.json_int(i64(live)))
	jsonutil.obj_set(&out, "children_total", jsonutil.json_int(i64(total)))
	return json.Value(json.Object(out)), nil
}

// handle_bye starts graceful drain; outstanding requests finish first.
handle_bye :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) {
	d := cast(^Daemon)ctx.user
	begin_drain(d, ctx.conn_id)
}

// handle_shutdown stops the daemon from the control plane (`aubade daemon
// stop`). It needs the root token from endpoint.json — the per-connection
// child token cannot stop the shared daemon. The caller's own connection
// does not block the stop; other live child sessions do (stop the clients
// or let the heartbeat reap them first).
handle_shutdown :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user

	if terr := require_rpc_token(d, params, .Denied); terr != nil {
		return nil, terr
	}

	others := 0
	sync.mutex_lock(&d.children_mu)
	for child in d.children {
		if child.id != ctx.conn_id && child.state == .Live {
			others += 1
		}
	}
	sync.mutex_unlock(&d.children_mu)
	if others > 0 {
		return nil, platform.Wrapped{
			kind = .Denied,
			// The message dies with the request arena like the success
			// path's reply object — a bare aprintf would leak it on the
			// worker thread's allocator.
			msg = fmt.aprintf("refusing: %d child session(s) still connected", others, allocator = ctx.allocator),
		}
	}

	platform.token_fire(d.root, .Shutdown)
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "stopping", jsonutil.json_bool(true))
	return json.Value(json.Object(out)), nil
}

// handle_cancel fires the parent-side tokens for a child-cancelled call.
// The notify glue reads a missing or non-integer call_id as 0; firing that
// would cancel an unrelated live request keyed 0, so a cancel without an
// integer call_id is ignored.
handle_cancel :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) {
	d := cast(^Daemon)ctx.user
	if v, ok := jsonutil.obj_get(params, "call_id"); ok {
		#partial switch x in v {
		case json.Integer:
			cancel_call(d, ctx.conn_id, ctx.call_id)
		case:
		}
	}
}
