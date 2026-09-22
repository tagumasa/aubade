// svc: the service API the parent daemon provides at the RPC boundary.
// Session open (hello), heartbeat (ping), graceful leave (bye), a
// request/response exemplar (echo — the shape every tool-forwarding
// method follows), and cancellation. The daemon implements
// hello/ping/bye/cancel against its child registry; echo lives here
// because it needs no daemon state.
package svc

import "core:encoding/json"
import "core:mem"
import "src:jsonrpc"
import "src:jsonutil"
import "src:platform"

METHOD_HELLO   :: "svc.hello"   // request: {token, client_pid, contexts[], modes[], trace_lsp} -> {daemon_pid}
METHOD_PING    :: "svc.ping"    // request: {} -> {} (RTT measured by the caller)
METHOD_STATUS  :: "svc.status"  // request: {} -> {pid, port, started_at_ms, children_live, children_total}
METHOD_SHUTDOWN :: "svc.shutdown" // request: {token} -> {stopping} (control-plane stop; root token)
METHOD_BYE     :: "svc.bye"     // notification: {}
METHOD_ECHO    :: "svc.echo"    // request: {message} -> {message}
METHOD_CANCEL  :: "svc.cancel"  // notification: {call_id}

// Svc_Ctx is the per-request context handed to handlers. call_id is the
// numeric jsonrpc request id (child-originated svc calls always use
// numeric ids), usable with METHOD_CANCEL.
Svc_Ctx :: struct {
	allocator: mem.Allocator,           // request arena
	token:     ^platform.Cancel_Token, // derived from the child connection token
	call_id:   i64,
	conn_id:   int,                    // daemon-side connection handle
	user:      rawptr,                 // daemon state (child registry etc.)
}

Handler  :: proc(ctx: ^Svc_Ctx, params: json.Value) -> (json.Value, platform.Err)
Notifier :: proc(ctx: ^Svc_Ctx, params: json.Value)

Table :: struct {
	handlers:  map[string]Handler,
	notifiers: map[string]Notifier,
	// mutating marks the methods that change project state; the glue
	// refuses them when the attached host reports read-only.
	mutating:  map[string]bool,
	allocator: mem.Allocator,
}

table_init :: proc(t: ^Table, a := context.allocator) {
	t^ = {allocator = a}
}

table_destroy :: proc(t: ^Table) {
	delete(t.handlers)
	delete(t.notifiers)
	delete(t.mutating)
	t^ = {}
}

table_register :: proc(t: ^Table, method: string, h: Handler) {
	if t.handlers == nil {
		t.handlers = make(map[string]Handler, 16, t.allocator)
	}
	t.handlers[method] = h
}

// table_register_mutating registers a state-changing handler: same as
// table_register, plus the mutating mark the read-only guard keys on.
table_register_mutating :: proc(t: ^Table, method: string, h: Handler) {
	table_register(t, method, h)
	if t.mutating == nil {
		t.mutating = make(map[string]bool, 16, t.allocator)
	}
	t.mutating[method] = true
}

table_register_notification :: proc(t: ^Table, method: string, n: Notifier) {
	if t.notifiers == nil {
		t.notifiers = make(map[string]Notifier, 8, t.allocator)
	}
	t.notifiers[method] = n
}

// Token_Hook derives (or finds) the cancel token for an incoming svc
// request so svc.cancel and heartbeat death propagate into in-flight work.
// Token_Release is its counterpart: called when the request finishes with
// the token the hook derived, it unregisters and destroys exactly that
// registration (a peer reusing one id runs several requests under it).
Token_Hook    :: proc(user: rawptr, conn_id: int, call_id: i64) -> ^platform.Cancel_Token
Token_Release :: proc(user: rawptr, conn_id: int, call_id: i64, token: ^platform.Cancel_Token)

Attach_State :: struct {
	table:         ^Table,
	user:          rawptr,
	conn_id:       int,
	derive_token:  Token_Hook,
	release_token: Token_Release,
	read_only:     Read_Only_Port,
	hello_gate:    Hello_Gate,
}

// attach bridges the svc table into a jsonrpc connection. Unknown svc.*
// methods fall through to jsonrpc's Method_Not_Found.
attach :: proc(conn: ^jsonrpc.Conn, t: ^Table, user: rawptr, conn_id: int) {
	state := new(Attach_State, conn.allocator)
	state^ = {table = t, user = user, conn_id = conn_id}
	conn.host = state
	for method, _ in t.handlers {
		jsonrpc.conn_register(conn, method, svc_request_glue)
	}
	for method, _ in t.notifiers {
		jsonrpc.conn_register_notification(conn, method, svc_notify_glue)
	}
}

attach_tokens :: proc(conn: ^jsonrpc.Conn, hook: Token_Hook) {
	state := cast(^Attach_State)conn.host
	if state != nil {
		state.derive_token = hook
	}
}

release_tokens :: proc(conn: ^jsonrpc.Conn, rel: Token_Release) {
	state := cast(^Attach_State)conn.host
	if state != nil {
		state.release_token = rel
	}
}

// Read_Only_Port reports whether the attached host serves a read-only
// project; the glue consults it before running a mutating method.
Read_Only_Port :: proc(user: rawptr) -> bool

// attach_read_only installs the read-only port (nil = never read-only).
attach_read_only :: proc(conn: ^jsonrpc.Conn, port: Read_Only_Port) {
	state := cast(^Attach_State)conn.host
	if state != nil {
		state.read_only = port
	}
}

// Hello_Gate reports whether the connection completed the session
// handshake (svc.hello with the auth token). The glue refuses every
// request method except hello until it has: loopback TCP accepts any
// local process, so proof of the token at hello is what authorizes the
// rest of the surface. nil = no gate (the in-process channel transport).
Hello_Gate :: proc(user: rawptr, conn_id: int) -> bool

attach_hello_gate :: proc(conn: ^jsonrpc.Conn, gate: Hello_Gate) {
	state := cast(^Attach_State)conn.host
	if state != nil {
		state.hello_gate = gate
	}
}

// detach frees the attach state of a connection being destroyed. Only call
// it on connections that went through attach.
detach :: proc(conn: ^jsonrpc.Conn) {
	if conn.host != nil {
		free(cast(^Attach_State)conn.host, conn.allocator)
		conn.host = nil
	}
}

svc_request_glue :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	state := cast(^Attach_State)conn.host
	if state == nil {
		reply: jsonrpc.Reply = {is_error = true, err_code = .Internal_Error, err_message = "svc state missing"}
		return reply, .Respond
	}
	h, found := state.table.handlers[env.method]
	if !found {
		reply: jsonrpc.Reply = {is_error = true, err_code = .Method_Not_Found, err_message = "unknown svc method"}
		return reply, .Respond
	}

	// The session handshake gates every request method except hello: an
	// unauthenticated connection must not reach the svc surface even
	// though it can reach the socket.
	if state.hello_gate != nil && env.method != METHOD_HELLO && !state.hello_gate(state.user, state.conn_id) {
		reply: jsonrpc.Reply = {is_error = true, err_code = .Invalid_Request, err_message = "session not authenticated"}
		return reply, .Respond
	}

	// This RPC keys requests by integer id: svc.cancel addresses a call by
	// the same integer, and the daemon's per-call token registry is keyed
	// by it. An id-less request or a non-integer id would silently alias
	// every such peer onto call_id 0 — two concurrent ones would then
	// destroy each other's cancel tokens — so both are typed errors
	// instead of a quiet collapse.
	call_id := i64(0)
	if !env.id_set {
		reply: jsonrpc.Reply = {is_error = true, err_code = .Invalid_Request, err_message = "svc request without an id"}
		return reply, .Respond
	}
	#partial switch v in env.id {
	case i64:
		call_id = v
	case:
		reply: jsonrpc.Reply = {is_error = true, err_code = .Invalid_Request, err_message = "svc request id must be an integer"}
		return reply, .Respond
	}

	ctx: Svc_Ctx = {
		allocator = arena,
		token     = nil,
		call_id   = call_id,
		conn_id   = state.conn_id,
		user      = state.user,
	}
	derived := false
	if state.derive_token != nil {
		if state.release_token == nil {
			// Wiring invariant, complete before the first request is served:
			// a derive hook without its release counterpart leaks a cancel
			// token on every request. Fail loud instead of leaking.
			panic("svc: derive_token is set without release_token")
		}
		ctx.token = state.derive_token(state.user, state.conn_id, call_id)
		derived = ctx.token != nil
	}
	if state.derive_token != nil && !derived {
		// The session vanished between decode and here (its registry entry
		// is gone): running the handler anyway would be uncancellable work
		// against a dead session.
		reply: jsonrpc.Reply = {is_error = true, err_code = .Invalid_Request, err_message = "session gone"}
		return reply, .Respond
	}
	// The defer must sit at procedure scope: nested inside the `if` above
	// it would fire when that block ends — before the handler even runs —
	// unregistering and destroying the token the handler still holds.
	should_release := derived && state.release_token != nil
	defer if should_release {
		state.release_token(state.user, state.conn_id, call_id, ctx.token)
	}

	// Cancellation checkpoint for every method: a request whose token
	// already fired (session death, cancel) must not start handler work.
	if ctx.token != nil {
		if e, fired := platform.token_check(ctx.token); fired {
			code, msg := err_to_jsonrpc(e)
			reply: jsonrpc.Reply = {is_error = true, err_code = code, err_message = msg}
			return reply, .Respond
		}
	}

	// Read-only projects refuse state-changing methods at the boundary:
	// the RPC surface must not mutate even if a client never saw the
	// stripped tools/list.
	if state.read_only != nil && state.table.mutating[env.method] && state.read_only(state.user) {
		reply: jsonrpc.Reply = {is_error = true, err_code = .Invalid_Request, err_message = "project is read-only"}
		return reply, .Respond
	}

	params: json.Value = nil
	if env.params_set {
		params = env.params
	}
	result, serr := h(&ctx, params)
	if serr != nil {
		code, msg := err_to_jsonrpc(serr)
		reply: jsonrpc.Reply = {is_error = true, err_code = code, err_message = msg}
		return reply, .Respond
	}
	reply: jsonrpc.Reply = {result = result}
	return reply, .Respond
}

svc_notify_glue :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) {
	state := cast(^Attach_State)conn.host
	if state == nil {
		return
	}
	// The handshake gate covers notifications too: bye and cancel are
	// connection-lifecycle controls, and an unauthenticated local peer
	// must not drive them any more than it may call requests.
	if state.hello_gate != nil && !state.hello_gate(state.user, state.conn_id) {
		return
	}
	n, found := state.table.notifiers[env.method]
	if !found {
		return
	}
	call_id := i64(0)
	if env.params_set {
		if v, ok := jsonutil.obj_get(env.params, "call_id"); ok {
			#partial switch x in v {
			case json.Integer:
				call_id = i64(x)
			case:
			}
		}
	}
	ctx: Svc_Ctx = {
		allocator = arena,
		token     = nil,
		call_id   = call_id,
		conn_id   = state.conn_id,
		user      = state.user,
	}
	params: json.Value = nil
	if env.params_set {
		params = env.params
	}
	n(&ctx, params)
}

err_to_jsonrpc :: proc(e: platform.Err) -> (jsonrpc.Err_Code, string) {
	kind := platform.err_kind(e)
	msg := platform.err_message(e)
	switch kind {
	case .Invalid:
		return .Invalid_Params, msg
	case .Denied:
		return .Invalid_Request, msg
	case .NotFound:
		return .Method_Not_Found, msg
	case .Cancelled, .Timeout:
		return .Request_Cancelled, msg
	case .Retryable:
		// The typed transient channel: the child's dispatch retry stage
		// maps this one code back to the kind and re-applies read-only
		// calls (string-matching the message is forbidden).
		return .Server_Retryable, msg
	case .Terminated, .Internal:
		return .Internal_Error, msg
	}
	return .Internal_Error, msg
}

// ---------------------------------------------------------------------------
// echo: the forwarding exemplar. Params in, result out, arena-aware — the
// exact shape future tool-forwarding methods follow. (Cancellation is the
// glue's job: it checks every request's token before the handler runs.)
// ---------------------------------------------------------------------------

echo :: proc(ctx: ^Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	message := ""
	if v, ok := jsonutil.obj_get(params, "message"); ok {
		#partial switch x in v {
		case json.String:
			message = string(x)
		case:
			return nil, platform.Wrapped{kind = .Invalid, msg = "message must be a string"}
		}
	} else {
		return nil, platform.Wrapped{kind = .Invalid, msg = "message is required"}
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "message", jsonutil.json_string(message))
	return json.Value(json.Object(out)), nil
}
