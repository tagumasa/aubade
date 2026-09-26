// mcp: the MCP server layer over jsonrpc (self-made implementation; protocol
// baseline 2025-11-25). Transport-agnostic: the host injects a jsonrpc.Conn.
// v1 scope: initialize/instructions, ping, tools/list, tools/call,
// notifications/tools/list_changed, notifications/cancelled. No
// elicitation, structured output values, resource links, icons values, or
// tasks. Input-validation violations return isError tool results, never
// JSON-RPC -32602; -32602 stays for unknown tools, malformed tools/call
// request params, and framing-level violations (the split the 2025-11-25
// revision's error-handling section draws between tool execution errors
// and CallToolRequest schema failures).
package mcp

import "base:intrinsics"
import "core:encoding/json"
import "core:mem"
import "core:strings"
import "src:jsonrpc"
import "src:jsonutil"
import "src:platform"
import "src:util"

// The latest supported revision — must stay the LAST entry of
// PROTOCOL_SUPPORTED below (the compiler rejects indexing constant data,
// so a test pins the identity instead of a derivation).
PROTOCOL_LATEST :: "2025-11-25"

// A recognized requested version is echoed verbatim; anything else answers
// PROTOCOL_LATEST. The tool-listing shape is fixed across versions — the
// title, icons, and _meta members postdate some revisions, but those
// revisions' schemas admit additional properties, so older clients tolerate
// them.
PROTOCOL_SUPPORTED :: []string{"2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"}

// Tool_Entry is the wire-facing projection of a tool. The host (session)
// builds these from the tools table; mcp never imports the tools package
// (dependency direction: tools sits above mcp).
Tool_Entry :: struct {
	name:             string,
	title:            string,
	description:      string,
	input_schema:     json.Value,
	read_only_hint:   bool,
	destructive_hint: bool,
	// icons: [] and _meta: {} are always emitted (fixed wire shape).
}

Call_Info :: struct {
	name:   string,
	args:   json.Value, // object value or nil
	id:     jsonrpc.Id,
	id_set: bool,
}

// Call_Outcome is the immediate answer, or deferred=true when the tool is
// running on a worker pool; the host then finishes with
// send_tool_response / send_tool_error (e.g. -32800 when cancelled).
// is_protocol_error=true answers with a JSON-RPC error (e.g. -32602 for an
// unknown tool name) instead of a tool result.
Call_Outcome :: struct {
	deferred:          bool,
	is_protocol_error: bool,
	err_code:          jsonrpc.Err_Code,
	err_message:       string,
	is_error:          bool,
	text:              string,
}

List_Host   :: proc(host: rawptr, arena: mem.Allocator) -> []Tool_Entry
Call_Host   :: proc(host: rawptr, call: ^Call_Info) -> Call_Outcome
Cancel_Host :: proc(host: rawptr, id: jsonrpc.Id)

Server :: struct {
	conn:        ^jsonrpc.Conn,
	host:        rawptr,
	name:        string,
	version:     string,
	description: string,
	instructions: string, // per-session system prompt; one clone owned by the session allocator — the host assigns compose_instructions' result (or ""), never a borrowed literal, so shutdown frees it unconditionally
	list_tools:  List_Host,
	call_tool:   Call_Host,
	on_cancel:   Cancel_Host,
	// Set by the dispatch thread (notifications/initialized) and read by
	// the heartbeat thread (announce_visibility) — atomic intrinsics only.
	initialized: u32,
}

server_init :: proc(s: ^Server, conn: ^jsonrpc.Conn) {
	// The handlers cast conn.host back to ^Server, so the binding ships
	// with the registration — a host cannot forget it. (A host that wants
	// its own raw handlers may rebind conn.host afterwards.)
	conn.host = s
	s.conn = conn
	jsonrpc.conn_register(conn, "initialize", handle_initialize)
	jsonrpc.conn_register_notification(conn, "notifications/initialized", handle_initialized)
	jsonrpc.conn_register(conn, "ping", handle_ping)
	jsonrpc.conn_register(conn, "tools/list", handle_tools_list)
	jsonrpc.conn_register(conn, "tools/call", handle_tools_call)
	jsonrpc.conn_register_notification(conn, "notifications/cancelled", handle_cancelled)
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

handle_initialize :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	s := server_from_conn(conn)

	requested := PROTOCOL_LATEST
	if v, ok := jsonutil.obj_get(env.params, "protocolVersion"); ok {
		#partial switch x in v {
		case json.String:
			requested = string(x)
		case:
		}
	}
	// Walk the constant version table through a local slice (the
	// compiler rejects variable indexing straight into constant data).
	version := PROTOCOL_LATEST
	supported_versions := PROTOCOL_SUPPORTED
	for i in 0..<len(supported_versions) {
		if requested == supported_versions[i] {
			version = requested
			break
		}
	}

	result := jsonutil.json_object(4, arena)
	jsonutil.obj_set(&result, "protocolVersion", jsonutil.json_string(version))

	tools_cap := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&tools_cap, "listChanged", jsonutil.json_bool(true))
	caps := jsonutil.json_object(1, arena)
	jsonutil.obj_set_object(&caps, "tools", tools_cap)
	jsonutil.obj_set_object(&result, "capabilities", caps)

	server_info := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&server_info, "name", jsonutil.json_string(s.name))
	jsonutil.obj_set(&server_info, "version", jsonutil.json_string(s.version))
	jsonutil.obj_set(&server_info, "description", jsonutil.json_string(s.description))
	jsonutil.obj_set_object(&result, "serverInfo", server_info)

	jsonutil.obj_set(&result, "instructions", jsonutil.json_string(s.instructions))

	reply: jsonrpc.Reply = {result = json.Value(json.Object(result))}
	return reply, .Respond
}

handle_initialized :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) {
	s := server_from_conn(conn)
	intrinsics.atomic_store(&s.initialized, 1)
}

server_is_initialized :: proc(s: ^Server) -> bool {
	return intrinsics.atomic_load(&s.initialized) != 0
}

// handle_ping implements the MCP liveness probe: the receiver must answer
// promptly with an empty result (2025-11-25 utilities/ping).
handle_ping :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	reply: jsonrpc.Reply = {result = json.Value(json.Object(jsonutil.json_object(0, arena)))}
	return reply, .Respond
}

handle_tools_list :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	s := server_from_conn(conn)
	entries := s.list_tools(s.host, arena)

	items := make([]json.Value, len(entries), arena)
	for e, i in entries { // slice for-in binds (value, index)
		t := jsonutil.json_object(7, arena)
		jsonutil.obj_set(&t, "name", jsonutil.json_string(e.name))
		jsonutil.obj_set(&t, "title", jsonutil.json_string(e.title))
		jsonutil.obj_set(&t, "description", jsonutil.json_string(e.description))
		jsonutil.obj_set(&t, "inputSchema", e.input_schema)
		annotations := jsonutil.json_object(2, arena)
		jsonutil.obj_set(&annotations, "readOnlyHint", jsonutil.json_bool(e.read_only_hint))
		jsonutil.obj_set(&annotations, "destructiveHint", jsonutil.json_bool(e.destructive_hint))
		jsonutil.obj_set_object(&t, "annotations", annotations)
		jsonutil.obj_set(&t, "icons", jsonutil.json_array(nil, arena)) // shape fixed: always []
		jsonutil.obj_set_object(&t, "_meta", jsonutil.json_object(0, arena)) // shape fixed: always {}
		items[i] = json.Value(json.Object(t))
	}

	result := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&result, "tools", jsonutil.json_array(items, arena))

	reply: jsonrpc.Reply = {result = json.Value(json.Object(result))}
	return reply, .Respond
}

handle_tools_call :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	s := server_from_conn(conn)

	name := ""
	if v, ok := jsonutil.obj_get(env.params, "name"); ok {
		#partial switch x in v {
		case json.String:
			name = string(x)
		case:
		}
	}
	if name == "" {
		reply: jsonrpc.Reply = {is_error = true, err_code = .Invalid_Params, err_message = "tool name is required"}
		return reply, .Respond
	}

	args: json.Value = nil
	if v, ok := jsonutil.obj_get(env.params, "arguments"); ok && v != nil {
		// MCP: arguments, when present, is an object — anything else is a
		// protocol-level Invalid_Params, not a tool-level validation error.
		#partial switch x in v {
		case json.Object:
			args = v
		case:
			reply: jsonrpc.Reply = {
				is_error    = true,
				err_code    = .Invalid_Params,
				err_message = "arguments must be an object",
			}
			return reply, .Respond
		}
	}

	call: Call_Info = {
		name   = name,
		args   = args,
		id     = env.id,
		id_set = env.id_set,
	}
	outcome := s.call_tool(s.host, &call)
	if outcome.deferred {
		reply: jsonrpc.Reply = {}
		return reply, .Defer
	}
	if outcome.is_protocol_error {
		reply: jsonrpc.Reply = {
			is_error    = true,
			err_code    = outcome.err_code,
			err_message = outcome.err_message,
		}
		return reply, .Respond
	}
	body := tool_result_body(env.id, env.id_set, outcome.is_error, outcome.text, arena)
	// A request response waits for outbound queue space like every other
	// reply (conn_send_reply's deadline) — the drop-fast default is for
	// notifications only, and dropping a tools/call result parks the
	// client forever. A drop past that deadline is surfaced, not passed
	// silently: the peer stopped reading protocol frames.
	if !jsonrpc.conn_send_body(conn, body, platform.mono_ms() + jsonrpc.OUTBOUND_REPLY_TIMEOUT_MS) {
		log_dropped_reply(conn, env.id, env.id_set, "tools/call result", arena)
	}
	reply: jsonrpc.Reply = {}
	return reply, .Defer // already sent above; Defer stops jsonrpc from sending
}

handle_cancelled :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) {
	s := server_from_conn(conn)
	if v, ok := jsonutil.obj_get(env.params, "requestId"); ok && v != nil {
		if id, valid := jsonrpc.normalize_id(v); valid {
			s.on_cancel(s.host, id)
		}
	}
}

server_from_conn :: proc(conn: ^jsonrpc.Conn) -> ^Server {
	return cast(^Server)conn.host
}

// ---------------------------------------------------------------------------
// Server-initiated sends (host entry points)
// ---------------------------------------------------------------------------

// send_list_changed announces the tools/list_changed notification. The
// body's lifetime rule is send_tool_response's: `a` must be
// request/temp-scoped (the outbound queue clones what it queues, the
// synchronous writer consumes the bytes inside the call).
send_list_changed :: proc(s: ^Server, a := context.temp_allocator) -> bool {
	return jsonrpc.conn_notify(s.conn, "notifications/tools/list_changed", nil, a)
}

// send_tool_response finishes a deferred tools/call with a text content
// result; the body comes from the same builder the immediate path uses.
// The serialized body is transient — the outbound path queues a clone and
// the synchronous writer consumes the bytes before the send returns — so
// `arena` must be request/temp-scoped (whose enclosing scope resets it):
// nothing downstream frees the original, and a long-lived allocator would
// collect one body per reply.
send_tool_response :: proc(s: ^Server, id: jsonrpc.Id, id_set: bool, is_error: bool, text: string, arena: mem.Allocator) {
	// Same reply deadline as the immediate path above: a deferred
	// tools/call result must never take the notification drop-fast policy.
	if !jsonrpc.conn_send_body(s.conn, tool_result_body(id, id_set, is_error, text, arena), platform.mono_ms() + jsonrpc.OUTBOUND_REPLY_TIMEOUT_MS) {
		log_dropped_reply(s.conn, id, id_set, "tools/call result", arena)
	}
}

// send_tool_error finishes a deferred tools/call with a JSON-RPC error
// (e.g. -32800 RequestCancelled when the call was cut short). The body
// ownership rule of send_tool_response applies verbatim: request/temp-
// scoped arena only.
send_tool_error :: proc(s: ^Server, id: jsonrpc.Id, id_set: bool, code: jsonrpc.Err_Code, message: string, arena: mem.Allocator) {
	if !jsonrpc.conn_send_error(s.conn, id, id_set, code, message, arena) {
		log_dropped_reply(s.conn, id, id_set, "tools/call error", arena)
	}
}

// log_dropped_reply surfaces a reply the outbound deadline gave up on: a
// client that stopped reading protocol frames parks its tools/call
// forever, and the loss must at least be visible on our side. The
// diagnostic rides the reply's own arena — it dies with the request
// scope, never on a thread's unbounded temp.
log_dropped_reply :: proc(c: ^jsonrpc.Conn, id: jsonrpc.Id, id_set: bool, what: string, a: mem.Allocator) {
	id_text := jsonrpc.id_json(id, id_set, a)
	util.log_error(strings.concatenate(
		{"mcp: dropped ", what, " for request id ", id_text, " — the outbound deadline expired; the client is not reading"},
		a,
	))
}

tool_result_body :: proc(id: jsonrpc.Id, id_set: bool, is_error: bool, text: string, arena: mem.Allocator) -> string {
	// Every sub-part rides the caller's request-scoped arena together
	// with the final body (the builders' rule): a deferred reply sent
	// from a host worker thread must not depend on that thread's temp
	// being reset.
	return strings.concatenate(
		{
			`{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":`,
			jsonutil.json_quote(text, arena),
			`}],"isError":`,
			is_error ? "true" : "false",
			`},"id":`,
			jsonrpc.id_json(id, id_set, arena),
			"}",
		},
		arena,
	)
}
