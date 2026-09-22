// The initialize/initialized handshake and the shutdown/exit teardown on
// the protocol side. The process lifecycle around them (spawn, kill-tree,
// terminate deadlines) belongs to the lsproc layer; these procs only speak
// the wire sequence.
package lsp

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:sync"

import "src:jsonrpc"
import "src:jsonutil"
import "src:platform"
import "src:version"

INITIALIZE_TIMEOUT_MS :: i64(45_000)
SHUTDOWN_TIMEOUT_MS :: i64(5_000)

CLIENT_NAME :: "aubade"

// TextDocumentSyncKind values a server reports. Full-replacement change
// events (no range) are valid under every kind, so the client always sends
// full events; the kind is recorded for a future incremental path.
Sync_Kind :: enum u8 {
	None,
	Full,
	Incremental,
}

// The server capabilities the client acts on (a closed view of
// InitializeResult.capabilities — everything else is ignored by design).
Server_Caps :: struct {
	sync_kind:          Sync_Kind,
	definition:         bool,
	declaration:        bool,
	type_definition:    bool,
	implementation:     bool,
	references:         bool,
	document_symbol:    bool,
	workspace_symbol:   bool,
	document_diagnostic: bool,
}

// Folder is one workspaceFolders entry the client announces at
// initialize: the folder's URI and its display name.
Folder :: struct {
	uri:  string,
	name: string,
}

// client_initialize runs the handshake: the initialize request (with the
// client capabilities, the workspace folders — folders[0] is also sent
// as rootUri, so servers that ignore folders still receive the primary
// root while multi-root servers read the whole array — and the process
// id so servers can tie their lifetime to ours), then the initialized
// notification. On success the parsed server capabilities are cached on
// the client. Fails closed: any failure leaves initialized unset, so
// client_shutdown becomes a no-op.
client_initialize :: proc(
	cl:       ^Client,
	folders:  []Folder, // at least one entry
	arena:    mem.Allocator,
	token:    ^platform.Cancel_Token = nil,
	init_options_json: string = "",
) -> (ok: bool, err_code: jsonrpc.Err_Code, err_message: string, call_err: jsonrpc.Call_Err) {
	if len(folders) == 0 {
		return false, .Invalid_Params, "no workspace folders to announce", .Error_Response
	}
	params := jsonutil.json_object(5, arena)
	jsonutil.obj_set(&params, "processId", jsonutil.json_int(cast(i64)os.get_pid()))
	client_info := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&client_info, "name", jsonutil.json_string(CLIENT_NAME))
	jsonutil.obj_set(&client_info, "version", jsonutil.json_string(version.AUBADE_VERSION))
	jsonutil.obj_set(&params, "clientInfo", json.Value(json.Object(client_info)))
	jsonutil.obj_set(&params, "rootUri", jsonutil.json_string(folders[0].uri))
	folder_values := make([]json.Value, len(folders), arena)
	for i in 0..<len(folders) {
		fo := jsonutil.json_object(2, arena)
		jsonutil.obj_set(&fo, "uri", jsonutil.json_string(folders[i].uri))
		jsonutil.obj_set(&fo, "name", jsonutil.json_string(folders[i].name))
		folder_values[i] = json.Value(json.Object(fo))
	}
	jsonutil.obj_set(
		&params,
		"workspaceFolders",
		jsonutil.json_array(folder_values, arena),
	)
	jsonutil.obj_set(&params, "capabilities", client_capabilities(arena))
	if init_options_json != "" {
		opts, perr := json.parse_string(init_options_json, spec = .JSON, parse_integers = true, allocator = arena)
		if perr != nil {
			return false, .Invalid_Params, "invalid initialisation options", .Error_Response
		}
		jsonutil.obj_set(&params, "initializationOptions", opts)
	}

	result, code, message, cerr := client_call(
		cl, METHOD_INITIALIZE, json.Value(json.Object(params)), arena, token, INITIALIZE_TIMEOUT_MS,
	)
	if cerr != .None {
		return false, code, message, cerr
	}

	sync.mutex_lock(&cl.state_mu)
	cl.is_initialized = true
	cl.caps = parse_server_caps(result)
	sync.mutex_unlock(&cl.state_mu)

	// initialized carries an empty object; params:null is avoided here
	// because some servers reject a null params on this notification.
	empty := jsonutil.json_object(0, context.temp_allocator)
	if !client_notify(cl, METHOD_INITIALIZED, json.Value(json.Object(empty))) {
		return false, .None, "", .Closed
	}
	return true, .None, "", .None
}

// client_shutdown speaks the teardown half: shutdown request (short
// deadline — a wedged server must not hold the caller), then the exit
// notification. On a failed shutdown request the exit notification is not
// sent: the caller (lsproc) escalates to process termination instead.
// A client that never completed initialize has nothing to tear down.
client_shutdown :: proc(
	cl: ^Client,
	arena: mem.Allocator,
	token: ^platform.Cancel_Token = nil,
) -> (err_code: jsonrpc.Err_Code, err_message: string, call_err: jsonrpc.Call_Err) {
	sync.mutex_lock(&cl.state_mu)
	initialized := cl.is_initialized
	sync.mutex_unlock(&cl.state_mu)
	if !initialized {
		return .None, "", .None
	}

	_, code, message, cerr := client_call(cl, METHOD_SHUTDOWN, nil, arena, token, SHUTDOWN_TIMEOUT_MS)
	if cerr != .None {
		return code, message, cerr
	}
	if !client_notify(cl, METHOD_EXIT, nil) {
		return .None, "", .Closed
	}
	return .None, "", .None
}

// client_caps snapshots the cached server capabilities. The
// position-lookup consumers gate on these before sending: a server that
// never declared the provider answers the request with its own raw
// method-not-found error, so the gate declines first with a clean
// message instead.
client_caps :: proc(cl: ^Client) -> Server_Caps {
	sync.mutex_lock(&cl.state_mu)
	caps := cl.caps
	sync.mutex_unlock(&cl.state_mu)
	return caps
}

// client_is_initialized reports whether the handshake completed.
client_is_initialized :: proc(cl: ^Client) -> bool {
	sync.mutex_lock(&cl.state_mu)
	initialized := cl.is_initialized
	sync.mutex_unlock(&cl.state_mu)
	return initialized
}

// The client capabilities: what this client actually implements. Servers
// key their behavior off these; claiming more than we answer would make
// them send requests we drop, or delegate duties (file watching) we never
// perform.
client_capabilities :: proc(arena: mem.Allocator) -> json.Value {
	// No dynamic registration anywhere: registerCapability is acked, not
	// modeled, and no file watcher sits behind didChangeWatchedFiles —
	// servers must keep their own watching and their static providers.
	workspace := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&workspace, "configuration", json.Boolean(true))
	watched := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&watched, "dynamicRegistration", json.Boolean(false))
	jsonutil.obj_set(&workspace, "didChangeWatchedFiles", json.Value(json.Object(watched)))
	jsonutil.obj_set(&workspace, "workspaceFolders", json.Boolean(true))

	// textDocument: documentSymbol and publishDiagnostics are exercised;
	// synchronization declares nothing — didOpen/didChange(full)/didClose
	// are the required core, and didSave is never sent.
	text_document := jsonutil.json_object(2, arena)
	doc_symbol := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&doc_symbol, "hierarchicalDocumentSymbolSupport", json.Boolean(true))
	jsonutil.obj_set(&text_document, "documentSymbol", json.Value(json.Object(doc_symbol)))
	pub_diag := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&pub_diag, "versionSupport", json.Boolean(true))
	jsonutil.obj_set(&pub_diag, "relatedInformation", json.Boolean(true))
	jsonutil.obj_set(&text_document, "publishDiagnostics", json.Value(json.Object(pub_diag)))

	// window/workDoneProgress/create is answered and $/progress is
	// consumed — declared to match.
	window := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&window, "workDoneProgress", json.Boolean(true))

	general := jsonutil.json_object(1, arena)
	// UTF-16 is the position convention end to end (every column is
	// computed as UTF-16 code units); declaring utf-8 would make
	// utf-8-negotiating servers misread each position on non-ASCII lines.
	jsonutil.obj_set(
		&general,
		"positionEncodings",
		jsonutil.json_array({jsonutil.json_string("utf-16")}, arena),
	)

	caps := jsonutil.json_object(4, arena)
	jsonutil.obj_set(&caps, "workspace", json.Value(json.Object(workspace)))
	jsonutil.obj_set(&caps, "textDocument", json.Value(json.Object(text_document)))
	jsonutil.obj_set(&caps, "window", json.Value(json.Object(window)))
	jsonutil.obj_set(&caps, "general", json.Value(json.Object(general)))
	return json.Value(json.Object(caps))
}

// parse_server_caps reads InitializeResult into the closed view. A missing
// textDocumentSync is treated as Full (full-replacement events are what we
// send regardless, and they are valid under every kind).
parse_server_caps :: proc(result: json.Value) -> Server_Caps {
	caps := Server_Caps{sync_kind = .Full}
	caps_v, ok := jsonutil.obj_get(result, "capabilities")
	if !ok {
		return caps
	}
	sync_v, sync_found := jsonutil.obj_get(caps_v, "textDocumentSync")
	caps.sync_kind = sync_kind_of(sync_v, sync_found)
	caps.definition = cap_flag(caps_v, "definitionProvider")
	caps.declaration = cap_flag(caps_v, "declarationProvider")
	caps.type_definition = cap_flag(caps_v, "typeDefinitionProvider")
	caps.implementation = cap_flag(caps_v, "implementationProvider")
	caps.references = cap_flag(caps_v, "referencesProvider")
	caps.document_symbol = cap_flag(caps_v, "documentSymbolProvider")
	caps.workspace_symbol = cap_flag(caps_v, "workspaceSymbolProvider")
	caps.document_diagnostic = cap_flag(caps_v, "diagnosticProvider")
	return caps
}

sync_kind_of :: proc(v: json.Value, found: bool) -> Sync_Kind {
	if !found {
		return .Full
	}
	#partial switch x in v {
	case json.Integer:
		switch x {
		case 0:
			return .None
		case 2:
			return .Incremental
		case:
			return .Full
		}
	case json.Object:
		change_v, ok := jsonutil.obj_get(json.Value(x), "change")
		if ok {
			#partial switch c in change_v {
			case json.Integer:
				if c == 0 {
					return .None
				} else if c == 2 {
					return .Incremental
				}
			case:
			}
		}
		return .Full
	case:
	}
	return .Full
}

// cap_flag applies the LSP truthiness rule for provider capabilities:
// absent, false, and null mean "not provided"; an object form means
// provided (it carries options — an empty options object still enables
// the capability); a bare number or string counts as provided.
cap_flag :: proc(caps_v: json.Value, key: string) -> bool {
	v, found := jsonutil.obj_get(caps_v, key)
	if !found || v == nil {
		return false
	}
	#partial switch x in v {
	case json.Boolean:
		return x
	case json.Object:
		return true
	case json.Array:
		return len(x) > 0
	case:
		return true
	}
}
