// The LSP client: request wrapper with per-client timeout, $/cancelRequest
// propagation for cancelled calls, and the builtin answers every language
// server expects. Handlers recover the Client through conn.host.
package lsp

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:sync"

import "src:jsonrpc"
import "src:jsonutil"
import "src:platform"
import "src:util"

DEFAULT_REQUEST_TIMEOUT_MS :: i64(15_000)

// Config_Provider answers workspace/configuration. It receives the
// request params (the items array with section/scopeUri entries) and
// returns the matching configuration array. Runs on the request queue
// worker; nil answers an empty configuration array.
Config_Provider :: proc(user: rawptr, params: json.Value, arena: mem.Allocator) -> json.Value

Client :: struct {
	conn:               ^jsonrpc.Conn,
	clock:              ^platform.Clock, // deadlines come from the injected clock
	allocator:          mem.Allocator,
	request_timeout_ms: i64, // > 0; the per-call deadline is now + this
	language_id:        string,
	// Workspace root as an absolute path (owned clone; ""), set by the
	// production factory. Location enrichment in the request helpers
	// resolves server-reported URIs into absolute/relative paths against
	// it; without it the helpers leave those fields empty.
	root_abs:           string,

	config_provider: Config_Provider, // optional workspace/configuration source
	config_host:     rawptr,

	diagnostics: Diagnostics_Store,

	// state_mu guards handshake state (is_initialized, caps) and the
	// open-document mirror. The readiness gate carries its own mutex
	// because it is cond-coupled.
	state_mu: sync.Mutex,
	// The document-sync serializer: each doc op holds it across BOTH the
	// mirror change and its did* notification, so the wire order can never
	// invert against the map state (an unpaired didOpen would leave the
	// server holding a phantom document). Lock order is doc_mu →
	// state_mu; no path takes them the other way around.
	doc_mu:                 sync.Mutex,
	is_initialized:         bool,
	caps:                   Server_Caps,
	docs:                   map[string]^Doc_State,
	readiness:              Readiness,
	crossref_event_timeout_ms: i64, // 0 disables the event window
	crossref_fallback_ms:      i64, // 0 disables the fallback settle wait
}

// client_init wires an already-connected Conn: it installs the cancel
// notification, registers the builtin server->client answers, starts the
// bounded request queue, and claims conn.host. The caller runs the read
// loop (conn_read_loop) on its own thread.
client_init :: proc(cl: ^Client, conn: ^jsonrpc.Conn, clock: ^platform.Clock, language_id: string, a := context.allocator) {
	cl^ = {
		conn               = conn,
		clock              = clock,
		allocator              = a,
		request_timeout_ms = DEFAULT_REQUEST_TIMEOUT_MS,
		language_id        = language_id,
	}
	diagnostics_store_init(&cl.diagnostics, a)
	cl.docs = make(map[string]^Doc_State, 8, a)
	cl.crossref_event_timeout_ms = CROSSREF_EVENT_TIMEOUT_MS
	cl.crossref_fallback_ms = CROSSREF_FALLBACK_MS
	conn.host = cl
	conn.cancel_notify = client_cancel_notify
	client_register_builtins(cl)
	jsonrpc.conn_start_request_queue(conn, jsonrpc.REQUEST_QUEUE_CAP, a)
}

client_destroy :: proc(cl: ^Client) {
	docs_destroy(cl)
	diagnostics_store_destroy(&cl.diagnostics)
	if cl.root_abs != "" {
		delete(cl.root_abs, cl.allocator)
	}
}

// client_call sends a request and blocks for the reply under the client's
// timeout (injected clock) and the optional cancel token. timeout_ms
// overrides the per-client default for this one call (0 = the default);
// the handshake uses it for its longer initialize deadline. The outcome
// contract is jsonrpc.Call_Err; err_code/err_message are authoritative
// only for .Error_Response.
client_call :: proc(
	cl: ^Client,
	method: string,
	params: json.Value,
	arena: mem.Allocator,
	token: ^platform.Cancel_Token = nil,
	timeout_ms: i64 = 0,
) -> (result: json.Value, err_code: jsonrpc.Err_Code, err_message: string, call_err: jsonrpc.Call_Err) {
	timeout := cl.request_timeout_ms
	if timeout_ms > 0 {
		timeout = timeout_ms
	}
	deadline := platform.clock_now(cl.clock) + timeout
	return jsonrpc.conn_call(cl.conn, method, params, arena, deadline, token)
}

// client_notify sends a fire-and-forget notification (didOpen & co).
client_notify :: proc(cl: ^Client, method: string, params: json.Value) -> bool {
	return jsonrpc.conn_notify(cl.conn, method, params, context.temp_allocator)
}

// client_cancel_notify tells the server to stop the matched request.
// conn_call invokes it on its cancelled path, so the notification goes out
// whichever wait stage the cancel fired in. Best effort: the local abandon
// happens regardless.
client_cancel_notify :: proc(c: ^jsonrpc.Conn, id: i64) {
	// Built by concatenation: fmt treats '{' in any formatted string as a
	// parameter brace, and the id is an i64 so no escaping is needed. The
	// method name rides the one constant like every other method string.
	id_dec := util.int_to_dec(cast(int)id, context.temp_allocator)
	body := strings.concatenate(
		{
			`{"jsonrpc":"2.0","method":"`,
			METHOD_CANCEL_REQUEST,
			`","params":{"id":`,
			id_dec,
			"}}",
		},
		context.temp_allocator,
	)
	_ = jsonrpc.conn_send_body(c, body)
}

// --- builtin server->client answers ----------------------------------------

// on_configuration answers workspace/configuration from the installed
// provider (an array of configuration items, one per requested section).
on_configuration :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	cl := cast(^Client)conn.host
	if cl.config_provider != nil {
		return {result = cl.config_provider(cl.config_host, env.params, arena)}, .Respond
	}
	arr := make(json.Array, 0, 1, arena)
	return {result = json.Value(json.Array(arr))}, .Respond
}

// on_null_result acknowledges capability (un)registration and progress
// creation — the results are void, and servers only need the ack.
on_null_result :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	return {}, .Respond
}

// on_publish_diagnostics stores the latest diagnostics set per URI. An
// empty set clears the entry; a publication carrying a document version
// older than the last applied one for the URI is a stale snapshot and is
// dropped (the versionSupport declaration promises exactly that).
on_publish_diagnostics :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) {
	cl := cast(^Client)conn.host
	uri_value, u_ok := jsonutil.obj_get(env.params, "uri")
	diag_value, d_ok := jsonutil.obj_get(env.params, "diagnostics")
	if !u_ok || !d_ok {
		return
	}
	uri := jsonutil.value_str(uri_value)
	if uri == "" {
		return
	}
	version := i64(-1)
	if v, v_ok := jsonutil.obj_get(env.params, "version"); v_ok {
		#partial switch x in v {
		case json.Integer:
			version = x
		case:
		}
	}
	raw := jsonutil.marshal_value(diag_value, arena)
	diagnostics_store_set(&cl.diagnostics, uri, raw, version)
	readiness_signal_diagnostics(&cl.readiness)
}

client_register_builtins :: proc(cl: ^Client) {
	c := cl.conn
	jsonrpc.conn_register(c, METHOD_WORKSPACE_CONFIGURATION, on_configuration)
	jsonrpc.conn_register(c, METHOD_REGISTER_CAPABILITY, on_null_result)
	jsonrpc.conn_register(c, METHOD_UNREGISTER_CAPABILITY, on_null_result)
	jsonrpc.conn_register(c, METHOD_WORK_DONE_PROGRESS_CREATE, on_null_result)
	jsonrpc.conn_register_notification(c, METHOD_PUBLISH_DIAGNOSTICS, on_publish_diagnostics)
	jsonrpc.conn_register_notification(c, METHOD_PROGRESS, on_progress)
}
