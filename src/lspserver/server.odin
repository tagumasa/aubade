// lspserver: the LSP 3.17 server face over jsonrpc.Conn — the editor-
// facing child (`aubade lsp`). Transport-agnostic like the MCP server: the
// host injects a Conn (stdio with Content-Length framing in production,
// in-memory pipes in tests) and implements the host callbacks below. The
// package never imports the svc/session/daemon layers; everything that
// needs the daemon crosses a proc field.
//
// Wire scope: initialize/initialized/shutdown/exit, Full document sync
// (didOpen/didChange/didClose, didSave followed), the static
// textDocument/semanticTokens/full and textDocument/documentSymbol
// answers, and the dynamic-registration relay family (definition,
// references, declaration, formatting, ...) that arrives after
// initialize through the host's registration drive.
//
// Concurrency contract: every handler runs on the one thread that
// dispatches the connection's frames. The debounced diagnostics publish
// (publish_due, on the host's shell thread) runs off that thread, so
// handlers and the publish pass share Server.mu: it guards the open-
// document view's map membership and the uri/text/version/language/note
// fields, the publish due-set, and the is_shutdown/exit flags the pass
// gates on. The pass holds mu only for the due-set drain, the per-document
// snapshots, and each document's final send — that send shares the lock
// with the close path (handle_did_close), so a close-clear is the last
// publishDiagnostics a closed document receives. The per-view line-index
// cache and the encode path stay dispatch-thread-only (the pass derives
// its own index from its snapshot); the negotiated encoding and the
// capability bits are written under mu at initialize, so the readers that
// take mu — the pass's snapshot, server_apply_caps — are ordered after the
// write. server_destroy runs after every face thread has joined, and the
// host reads the exit status only after its dispatch loop has stopped
// draining the connection.
package lspserver

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"

import "src:jsonrpc"
import "src:jsonutil"
import "src:lsp"
import "src:platform"
import "src:util"

// The open-document view's bound: distinct documents tracked child-side.
// The view is a derived mirror of the client's open set (the daemon owns
// the real state), so hitting the bound evicts the oldest entry from the
// view only — the daemon's document stays open, and a later didClose for
// an evicted document is still forwarded.
LSP_MAX_OPEN_DOCUMENTS :: 128

// LSP 3.17's ServerNotInitialized code. jsonrpc.Err_Code carries only the
// JSON-RPC-shared vocabulary, so this LSP-reserved code is sent as a raw
// number through a hand-built error body.
LSP_ERR_SERVER_NOT_INITIALIZED :: i32(-32002)

// The wire spellings of the negotiated position encodings. utf-8 wins when
// the client offers it (its column unit is the byte — tree-sitter's own
// convention); utf-16 is the specification's safe default when the client
// offers nothing or no utf-8.
POSITION_ENCODING_UTF8  :: "utf-8"
POSITION_ENCODING_UTF16 :: "utf-16"

// The document version's wire range (an LSP document version is an i32;
// the wire integer is 64-bit and out-of-range values are refused, not
// wrapped).
DOC_VERSION_MIN :: -2147483648
DOC_VERSION_MAX ::  2147483647

// ---------------------------------------------------------------------------
// Host-callback ports. Arguments borrow the message arena and die when the
// handler returns — the host clones anything it keeps. Every callback runs
// on the connection's dispatch thread.
// ---------------------------------------------------------------------------

// Initialize_Host resolves the session's project root and brings the
// daemon link up: rootUri first (already decoded by the host), then the
// workspace folders, with an explicit CLI --project already bound ahead of
// both. A non-empty result is the error message the initialize reply
// carries; empty means the session is served.
Initialize_Host :: proc(host: rawptr, root_uri: string, workspace_folders: []string, arena: mem.Allocator) -> string

Doc_Open_Host   :: proc(host: rawptr, uri: string, language_id: string, version: i32, text: string)
Doc_Change_Host :: proc(host: rawptr, uri: string, version: i32, text: string)
Doc_Close_Host  :: proc(host: rawptr, uri: string)

// Highlights_Result carries one document-highlights answer, already
// parsed by the host into byte-range captures. has_version is the
// currency signal the encoder gates on: false means the daemon answered
// disk truth (the synced buffer was evicted, or the open's first apply is
// still in flight), whose spans do not index the open view's text.
Highlights_Result :: struct {
	has_version: bool,
	decline:     string,        // "" = success; otherwise the typed decline
	captures:    []Capture_Hit, // ascending by start_byte; arena-owned
	failed:      bool,          // the fetch itself failed (err_message says why)
	err_message: string,
}

Highlights_Host :: proc(host: rawptr, uri: string, arena: mem.Allocator) -> Highlights_Result

// Log_Host receives the face's notes (declines, contract violations). nil
// drops them — hosts that log route to their logger here, tests record
// instead of letting warnings reach the suite log.
Log_Host :: proc(host: rawptr, message: string)

// Outline_Host supplies one document's symbol outline: the svc.symbol/list
// answer ({symbols: [...]} — name/kind/detail/range/selection_range/
// children, columns UTF-16); ok=false when the fetch itself failed. The
// documentSymbol face renders the tree into the connection's encoding;
// the host owns the daemon round trip.
Outline_Host :: proc(host: rawptr, uri: string, arena: mem.Allocator) -> (outline: json.Value, ok: bool)

// Ops_Kind names one langserver relay operation. The svc inventory behind
// the family is fixed: format, code actions, inlay hints, call hierarchy
// (prepare synthesized from the symbol outline, edges through the
// langserver face).
Ops_Kind :: enum {
	Formatting,
	Code_Actions,
	Inlay_Hints,
	Prepare_Call_Hierarchy,
	Call_Edges,
}

// Ops_Request is one relay operation. Columns are UTF-16 end to end (the
// svc faces' convention). Which members carry depends on kind: the
// start/end range for Code_Actions and Inlay_Hints, the start point for
// Prepare_Call_Hierarchy and Call_Edges, the options for Formatting, and
// incoming for Call_Edges' direction. uri is the client's spelling.
Ops_Request :: struct {
	kind:          Ops_Kind,
	uri:           string,
	start_line:    int,
	start_col:     int,
	end_line:      int,
	end_col:       int,
	tab_size:      int,
	insert_spaces: bool,
	incoming:      bool,
}

// Ops_Result carries the operation's answer as the face's DTO array
// (arena-owned; nil renders as an empty reply): text-edit DTOs for
// Formatting, code-action DTOs for Code_Actions, inlay-hint DTOs for
// Inlay_Hints, and call items for Prepare_Call_Hierarchy / Call_Edges —
// each item {name, kind (int), uri (client spelling), range,
// selection_range, from_ranges?}, columns UTF-16, the edges' kind names
// recovered to ints host-side. failed means the fetch itself failed; the
// face answers empty either way (the relay rule: no error responses).
Ops_Result :: struct {
	items:       json.Value,
	failed:      bool,
	err_message: string,
}

// Ops_Host runs one relay operation against the daemon's langserver faces.
Ops_Host :: proc(host: rawptr, req: Ops_Request, arena: mem.Allocator) -> Ops_Result

// ---------------------------------------------------------------------------
// Server state
// ---------------------------------------------------------------------------

Exit_Status :: enum {
	Running,
	Clean,  // exit notification received after shutdown
	Forced, // exit notification received without shutdown
}

// Doc_View is one open document's child-side mirror: the text the client
// last sent and the derived state computed from it. The text is the
// connection's conversion truth (utf-16 columns are derived through it),
// not a second source of document state — the daemon's buffer is.
Doc_View :: struct {
	uri:            string, // the map key (owned clone; open_order aliases it)
	language_id:    string, // owned clone; the didOpen languageId ("" when none)
	text:           string, // owned clone of the latest full text
	version:        i32,
	has_note:       bool,   // the one-log-line-per-file latch
	line_index:     []int,  // owned; line start offsets for utf-16 conversion
	line_version:   i32,
	has_line_index: bool,
}

Server :: struct {
	conn:   ^jsonrpc.Conn,
	host:   rawptr,
	name:   string,
	version: string,

	initialize_host: Initialize_Host,
	doc_open:        Doc_Open_Host,
	doc_change:      Doc_Change_Host,
	doc_close:       Doc_Close_Host,
	highlights:      Highlights_Host,
	diagnostics:     Diagnostics_Host,
	readiness:       Readiness_Host,
	relay:           Relay_Host,          // position→location lookups (definitions/references/declarations)
	text_for_uri:    Text_For_Uri_Host,   // answer-text service for the relay's column conversion
	outline:         Outline_Host,        // svc.symbol/list supply for textDocument/documentSymbol
	ops:             Ops_Host,            // langserver relays: formatting, code actions, inlay hints, call hierarchy
	log:             Log_Host,

	encoding:       Position_Encoding, // negotiated at initialize; Utf16 until then
	is_initialized: bool,
	is_shutdown:    bool,
	exit:           Exit_Status,

	// The editor's capability bits, read from the initialize params: the
	// applyEdit pair (workspace.applyEdit and
	// workspace.workspaceEdit.documentChanges — the apply form the
	// two-writer round trip is fixed to) and documentSymbol's
	// hierarchical form (hierarchicalDocumentSymbolSupport). Written and
	// read under mu: the apply worker (off the dispatch thread) gates
	// every forwarded edit on the apply pair.
	can_apply_edit:           bool,
	can_document_changes:     bool,
	can_hierarchical_symbols: bool,

	// legend holds the connection's wire ranks, derived once at init from
	// the mapping tables' legend procs (semantic_tokens.odin — the tables
	// stay the single source): the legend index of every Token_Type member
	// and the modifier bit of every Token_Modifier member, -1 when the
	// tables never emit the member. The tokens encoder resolves per token
	// by one array read instead of a legend scan.
	legend: Legend_Ranks,

	mu:         sync.Mutex,    // guards the view fields the publish pass reads, deb, is_shutdown/exit
	deb:        Debounce_Set,  // the publish due-set (see debounce.odin)
	docs:       map[string]^Doc_View,
	open_order: [dynamic]string, // URIs in open order; the eviction victim is its head
	allocator:  mem.Allocator,   // must be set before server_init
}

server_init :: proc(s: ^Server, conn: ^jsonrpc.Conn) {
	// The handlers cast conn.host back to ^Server, so the binding ships
	// with the registration — a host cannot forget it.
	conn.host = s
	s.conn = conn
	s.docs = make(map[string]^Doc_View, 8, s.allocator)
	s.open_order = make([dynamic]string, 0, 8, s.allocator)
	debounce_init(&s.deb, s.allocator)
	s.legend = legend_ranks_build()
	jsonrpc.conn_register(conn, lsp.METHOD_INITIALIZE, handle_initialize)
	jsonrpc.conn_register(conn, lsp.METHOD_SHUTDOWN, handle_shutdown)
	jsonrpc.conn_register(conn, lsp.METHOD_SEMANTIC_TOKENS_FULL, handle_semantic_tokens_full)
	jsonrpc.conn_register(conn, lsp.METHOD_DOCUMENT_SYMBOL, handle_document_symbol)
	// The relay requests are registered at init but never advertised
	// statically: the editor sends them only after the host's dynamic
	// registration drive runs (see relay.odin). The langserver ops family
	// below rides the same drive.
	jsonrpc.conn_register(conn, lsp.METHOD_DEFINITION, handle_relay_request)
	jsonrpc.conn_register(conn, lsp.METHOD_REFERENCES, handle_relay_request)
	jsonrpc.conn_register(conn, lsp.METHOD_DECLARATION, handle_relay_request)
	jsonrpc.conn_register(conn, lsp.METHOD_FORMATTING, handle_ops_request)
	jsonrpc.conn_register(conn, lsp.METHOD_CODE_ACTION, handle_ops_request)
	jsonrpc.conn_register(conn, lsp.METHOD_INLAY_HINT, handle_ops_request)
	jsonrpc.conn_register(conn, lsp.METHOD_PREPARE_CALL_HIERARCHY, handle_ops_request)
	jsonrpc.conn_register(conn, lsp.METHOD_INCOMING_CALLS, handle_ops_request)
	jsonrpc.conn_register(conn, lsp.METHOD_OUTGOING_CALLS, handle_ops_request)
	jsonrpc.conn_register_notification(conn, lsp.METHOD_INITIALIZED, handle_initialized)
	jsonrpc.conn_register_notification(conn, lsp.METHOD_EXIT, handle_exit)
	jsonrpc.conn_register_notification(conn, lsp.METHOD_DID_OPEN, handle_did_open)
	jsonrpc.conn_register_notification(conn, lsp.METHOD_DID_CHANGE, handle_did_change)
	jsonrpc.conn_register_notification(conn, lsp.METHOD_DID_CLOSE, handle_did_close)
	jsonrpc.conn_register_notification(conn, lsp.METHOD_DID_SAVE, handle_did_save)
}

// server_destroy frees the face's own state (the view and its derived
// index). Runs after every face thread has joined. The conn is the host's:
// it closes and destroys it.
server_destroy :: proc(s: ^Server) {
	// Collect-then-free: doc_view_free removes its map entry, and a
	// delete_key inside the walk is the one mutation an Odin map forbids
	// mid-iteration.
	entries := make([dynamic]^Doc_View, 0, len(s.docs), s.allocator)
	for _, e in s.docs {
		append(&entries, e)
	}
	for e in entries {
		doc_view_free(s, e)
	}
	delete(entries)
	delete(s.docs)
	delete(s.open_order)
	debounce_destroy(&s.deb)
	s^ = {}
}

server_exit_status :: proc(s: ^Server) -> Exit_Status {
	return s.exit
}

// server_exit_code maps the exit status onto the process exit code: 0 for
// a clean shutdown+exit and for an orderly stream end that never saw an
// exit notification, 1 for exit without shutdown.
server_exit_code :: proc(s: ^Server) -> int {
	return s.exit == .Forced ? 1 : 0
}

// server_is_tracking_uri reports whether the open-document view currently
// holds a document. Dispatch thread only — the publish pass reads the view
// through server_snapshot_doc instead.
server_is_tracking_uri :: proc(s: ^Server, uri: string) -> bool {
	return s.docs[uri] != nil
}

server_from_conn :: proc(conn: ^jsonrpc.Conn) -> ^Server {
	return cast(^Server)conn.host
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

Gate_Verdict :: enum {
	Pass,
	Not_Initialized, // answered with -32002, the LSP-reserved code
	Shutting_Down,   // answered with InvalidRequest
}

// request_gate implements the lifecycle contract for requests: everything
// except initialize waits for initialize (-32002), and after shutdown
// every request is refused (-32600). Notifications are not gated here —
// unknown ones the conn ignores, known ones check the flags themselves.
request_gate :: proc(s: ^Server, method: string) -> Gate_Verdict {
	if method == lsp.METHOD_INITIALIZE {
		return .Pass
	}
	if !s.is_initialized {
		return .Not_Initialized
	}
	if s.is_shutdown {
		return .Shutting_Down
	}
	return .Pass
}

// request_gate_reply answers a request the lifecycle gate refuses: the
// LSP-reserved -32002 before initialize (sent as a protocol error, so the
// caller defers — the answer already went out) or InvalidRequest after
// shutdown. handled=false means the gate passed and the handler runs.
request_gate_reply :: proc(s: ^Server, conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (reply: jsonrpc.Reply, action: jsonrpc.Action, handled: bool) {
	switch request_gate(s, env.method) {
	case .Pass:
	case .Not_Initialized:
		send_protocol_error(conn, env.id, env.id_set, LSP_ERR_SERVER_NOT_INITIALIZED, "server is not initialized", arena)
		return reply, .Defer, true
	case .Shutting_Down:
		reply = {is_error = true, err_code = .Invalid_Request, err_message = "server is shutting down"}
		return reply, .Respond, true
	}
	return reply, .Respond, false
}

handle_initialize :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	s := server_from_conn(conn)
	if s.is_initialized {
		reply: jsonrpc.Reply = {is_error = true, err_code = .Invalid_Request, err_message = "initialize was already received"}
		return reply, .Respond
	}

	root_uri := ""
	if v, ok := jsonutil.obj_get(env.params, "rootUri"); ok {
		root_uri = jsonutil.value_str(v) // "" for null or a non-string
	}
	folders := parse_workspace_folders(env.params, arena)

	if s.initialize_host != nil {
		if fail := s.initialize_host(s.host, root_uri, folders, arena); fail != "" {
			reply: jsonrpc.Reply = {is_error = true, err_code = .Invalid_Request, err_message = fail}
			return reply, .Respond
		}
	}

	// The negotiated encoding and the capability bits are written under
	// mu: the publish pass snapshots the encoding under it and the apply
	// worker reads the apply pair through server_apply_caps, so both are
	// ordered after this write. The dispatch-thread readers (the request
	// gate, the capabilities block below) need no lock — initialize runs
	// once, on the dispatch thread.
	sync.mutex_lock(&s.mu)
	s.encoding = negotiate_encoding(env.params)
	s.can_apply_edit = negotiate_apply_edit(env.params)
	s.can_document_changes = negotiate_document_changes(env.params)
	s.can_hierarchical_symbols = negotiate_hierarchical_symbols(env.params)
	s.is_initialized = true
	sync.mutex_unlock(&s.mu)

	result := jsonutil.json_object(2, arena)

	sync_cap := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&sync_cap, "openClose", jsonutil.json_bool(true))
	jsonutil.obj_set(&sync_cap, "change", jsonutil.json_int(1)) // Full
	save_cap := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&save_cap, "includeText", jsonutil.json_bool(false))
	jsonutil.obj_set_object(&sync_cap, "save", save_cap)

	legend := jsonutil.json_object(2, arena)
	// The legend is derived from the mapping tables (never a second
	// declaration): the same lists every token's wire index is ranked
	// against.
	types, type_count := legend_token_types()
	type_items := make([]json.Value, type_count, arena)
	for i in 0 ..< type_count {
		type_items[i] = jsonutil.json_string(token_type_name(types[i]))
	}
	jsonutil.obj_set(&legend, "tokenTypes", jsonutil.json_array(type_items, arena))
	mods, mod_count := legend_token_modifiers()
	mod_items := make([]json.Value, mod_count, arena)
	for i in 0 ..< mod_count {
		mod_items[i] = jsonutil.json_string(token_modifier_name(mods[i]))
	}
	jsonutil.obj_set(&legend, "tokenModifiers", jsonutil.json_array(mod_items, arena))

	tokens_cap := jsonutil.json_object(3, arena)
	jsonutil.obj_set_object(&tokens_cap, "legend", legend)
	jsonutil.obj_set(&tokens_cap, "full", jsonutil.json_bool(true))
	jsonutil.obj_set(&tokens_cap, "range", jsonutil.json_bool(false))

	caps := jsonutil.json_object(6, arena)
	jsonutil.obj_set_object(&caps, "textDocumentSync", sync_cap)
	jsonutil.obj_set_object(&caps, "semanticTokensProvider", tokens_cap)
	jsonutil.obj_set(&caps, "documentSymbolProvider", jsonutil.json_bool(true))
	// The definition/declaration jump is advertised statically: the daemon
	// answers it out of its own outline and name index, with no language
	// server lifecycle to follow (references stays dynamically registered
	// behind a live server — an index cannot answer it).
	jsonutil.obj_set(&caps, "definitionProvider", jsonutil.json_bool(true))
	jsonutil.obj_set(&caps, "declarationProvider", jsonutil.json_bool(true))
	// The negotiated encoding lives inside capabilities (LSP 3.17
	// ServerCapabilities.positionEncoding): clients that offered utf-8 must
	// see the choice to keep columns correct.
	jsonutil.obj_set(&caps, "positionEncoding", jsonutil.json_string(encoding_wire(s.encoding)))
	jsonutil.obj_set_object(&result, "capabilities", caps)

	info := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&info, "name", jsonutil.json_string(s.name))
	jsonutil.obj_set(&info, "version", jsonutil.json_string(s.version))
	jsonutil.obj_set_object(&result, "serverInfo", info)

	reply: jsonrpc.Reply = {result = json.Value(json.Object(result))}
	return reply, .Respond
}

handle_initialized :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) {
	// The client's acknowledgment of initialize: registered and acted on
	// by nothing — no server-initiated face work waits for this point.
	_ = conn
	_ = env
	_ = arena
}

handle_shutdown :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	s := server_from_conn(conn)
	reply, action, gated := request_gate_reply(s, conn, env, arena)
	if gated {
		return reply, action
	}
	sync.mutex_lock(&s.mu)
	s.is_shutdown = true
	sync.mutex_unlock(&s.mu)
	// The shutdown result is null by specification: an unset Reply result
	// serializes as null.
	reply = {}
	return reply, .Respond
}

handle_exit :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) {
	s := server_from_conn(conn)
	// The publish pass gates on these flags under mu (see the package
	// header), so the write takes it too.
	sync.mutex_lock(&s.mu)
	s.exit = s.is_shutdown ? .Clean : .Forced
	sync.mutex_unlock(&s.mu)
	_ = env
	_ = arena
}

handle_semantic_tokens_full :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	s := server_from_conn(conn)
	reply, action, gated := request_gate_reply(s, conn, env, arena)
	if gated {
		return reply, action
	}

	uri := parse_text_document_uri(env.params)
	if uri == "" {
		reply = {is_error = true, err_code = .Invalid_Params, err_message = "textDocument.uri is required"}
		return reply, .Respond
	}

	data := tokens_for_uri(s, uri, arena)
	items := make([]json.Value, len(data), arena)
	for v, i in data {
		items[i] = jsonutil.json_int(i64(v))
	}
	result := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&result, "data", jsonutil.json_array(items, arena))
	reply = {result = json.Value(json.Object(result))}
	return reply, .Respond
}

handle_did_open :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) {
	_ = arena
	s := server_from_conn(conn)
	if !s.is_initialized || s.is_shutdown {
		return
	}
	p, ok := parse_doc_notification(env.params)
	if !ok {
		log_message(s, "textDocument/didOpen carried malformed params; dropped")
		return
	}
	sync.mutex_lock(&s.mu)
	server_view_open(s, p.uri, p.language_id, p.version, p.text)
	sync.mutex_unlock(&s.mu)
	if s.doc_open != nil {
		s.doc_open(s.host, p.uri, p.language_id, p.version, p.text)
	}
}

handle_did_change :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) {
	_ = arena
	s := server_from_conn(conn)
	if !s.is_initialized || s.is_shutdown {
		return
	}
	p := parse_change_params(env.params)
	sync.mutex_lock(&s.mu)
	view := s.docs[p.uri]
	if view == nil {
		// A change for a document this child never saw open. Nothing is
		// forwarded or parsed, so dropping is safe — and stays silent
		// on purpose: a client that streamed such changes would
		// otherwise turn every keystroke into a log line.
		sync.mutex_unlock(&s.mu)
		return
	}
	if p.uri == "" || !p.has_version || !p.is_full {
		sync.mutex_unlock(&s.mu)
		// The view outlives the lock section: only the dispatch thread —
		// this thread — frees view entries.
		publish_note_once(s, p.uri, "textDocument/didChange carried malformed or ranged (incremental) content; the connection is Full-sync, so the change was dropped")
		return
	}
	// Adopt into the view first (it mirrors the client, not the daemon),
	// then forward.
	if view.text != "" {
		delete(view.text, s.allocator)
	}
	view.text = strings.clone(p.text, s.allocator)
	view.version = p.version
	doc_view_invalidate_index(s, view)
	sync.mutex_unlock(&s.mu)
	if s.doc_change != nil {
		s.doc_change(s.host, p.uri, p.version, p.text)
	}
}

handle_did_close :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) {
	_ = arena
	s := server_from_conn(conn)
	if !s.is_initialized || s.is_shutdown {
		return
	}
	uri := parse_text_document_uri(env.params)
	if uri == "" {
		log_message(s, "textDocument/didClose carried malformed params; dropped")
		return
	}
	// Forwarded even without a view entry: an evicted view entry (or a
	// document left open by a previous connection of this child) still
	// owns daemon-side state that only this close releases.
	if s.doc_close != nil {
		s.doc_close(s.host, uri)
	}
	sync.mutex_lock(&s.mu)
	if e := s.docs[uri]; e != nil {
		view_order_remove(s, uri)
		doc_view_free(s, e)
	}
	// The close publish below is immediate, so nothing may fire later for
	// this uri.
	debounce_drop(&s.deb, uri)
	// The clear shares this lock hold with the pass's per-uri tail
	// (publish_due_flush), which makes it the LAST publishDiagnostics the
	// closed document can receive: a pass that verified the view before
	// this close still holds the mutex, so its send precedes this clear,
	// and a pass after the close sees no view and stays silent.
	publish_close_clear(s, uri, arena)
	sync.mutex_unlock(&s.mu)
}

handle_did_save :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) {
	// Registered to make the accepted notification explicit. didSave
	// carries no child-side work: the disk commit is the editor's save,
	// and the daemon buffer already holds the current text under Full
	// sync, so there is no svc call and no state change.
	_ = conn
	_ = env
	_ = arena
}

// ---------------------------------------------------------------------------
// Semantic tokens
// ---------------------------------------------------------------------------

// tokens_for_uri produces the wire data array for one document, or nil for
// every explicitly-degraded shape: a fetch failure, a daemon-side decline,
// or captures that do not index the open document's current text (a
// version skew the next request self-heals). Each shape answers empty data
// and logs at most one line per open (never a per-request storm).
tokens_for_uri :: proc(s: ^Server, uri: string, arena: mem.Allocator) -> []i32 {
	view := s.docs[uri]
	if view == nil {
		// Tokens are encoded child-side from the open-document view, so
		// a document the client never opened has nothing to answer
		// with. That is a normal client state (requests for closed
		// documents), not a refusal: empty data, no log.
		return nil
	}
	hr := s.highlights(s.host, uri, arena)
	if hr.failed {
		publish_note_once(s, uri, fmt.aprintf("semantic tokens unavailable for %s: %s; answering empty data", uri, hr.err_message, allocator = arena))
		return nil
	}
	if hr.decline != "" {
		publish_note_once(s, uri, fmt.aprintf("semantic tokens declined for %s (%s); answering empty data", uri, hr.decline, allocator = arena))
		return nil
	}
	if !hr.has_version {
		// The currency rule the publish pass applies to disk-truth
		// diagnostics: without a synced version the daemon's captures index
		// disk bytes (an evicted buffer), not the open view's text — a
		// bounds check cannot rule that skew out, so the answer is empty
		// data until the next change re-adopts the buffer.
		publish_note_once(s, uri, fmt.aprintf("semantic tokens for %s were computed over disk truth the open view does not mirror; answering empty data", uri, allocator = arena))
		return nil
	}

	data: []i32
	eerr: Encode_Err
	// The view's line index feeds the encoder under both encodings: every
	// token is measured against its start line's tail (the multi-line
	// clip), and utf-16 columns convert through it. Under a utf-8
	// connection the columns themselves stay bytes — capture ranges ride
	// into the response.
	data, eerr = semantic_tokens_encode(hr.captures, view.text, doc_line_index(s, view), s.encoding, s.legend, arena)
	if eerr != .None {
		publish_note_once(s, uri, fmt.aprintf("semantic tokens for %s do not index the document's current text; answering empty data", uri, allocator = arena))
		return nil
	}
	return data
}

// ---------------------------------------------------------------------------
// Param parsing
// ---------------------------------------------------------------------------

// parse_text_document_uri reads params.textDocument.uri — "" when the
// textDocument member or its uri is absent or not a string. The document
// notifications and the document-scoped requests share the shape.
parse_text_document_uri :: proc(params: json.Value) -> string {
	td, ok := jsonutil.obj_get(params, "textDocument")
	if !ok {
		return ""
	}
	if u, found := jsonutil.obj_get(td, "uri"); found {
		return jsonutil.value_str(u)
	}
	return ""
}

Doc_Params :: struct {
	uri:         string,
	language_id: string,
	text:        string,
	version:     i32,
	has_version: bool,
}

// parse_doc_notification reads the didOpen shape: textDocument with a
// required uri and version, an optional languageId, and a required full
// text.
parse_doc_notification :: proc(params: json.Value) -> (p: Doc_Params, ok: bool) {
	p.uri = parse_text_document_uri(params)
	if p.uri == "" {
		return
	}
	td, _ := jsonutil.obj_get(params, "textDocument") // present: the uri came out of it
	if lv, found := jsonutil.obj_get(td, "languageId"); found {
		p.language_id = jsonutil.value_str(lv)
	}
	if vv, found := jsonutil.obj_get(td, "version"); found {
		// An integer, or the open is malformed: the daemon's own param
		// gate demands an integer, and value_int would silently read a
		// non-integer as 0 — a fabricated version in the stream.
		#partial switch x in vv {
		case json.Integer:
			v := i64(x)
			if v < DOC_VERSION_MIN || v > DOC_VERSION_MAX {
				return
			}
			p.version = i32(v)
			p.has_version = true
		case:
			return
		}
	}
	if !p.has_version {
		return
	}
	if tv, found := jsonutil.obj_get(td, "text"); found {
		#partial switch x in tv {
		case json.String:
			p.text = string(x)
		case:
			return
		}
	} else {
		return
	}
	return p, true
}

Change_Params :: struct {
	uri:         string,
	version:     i32,
	has_version: bool,
	text:        string,
	is_full:     bool, // exactly one range-free content change with a text
}

// parse_change_params reads the didChange shape under the Full-sync
// contract: one content change, no range, carrying the full text. Any
// other shape reports is_full = false — a client contract violation the
// handler refuses instead of misparsing.
parse_change_params :: proc(params: json.Value) -> (p: Change_Params) {
	p.uri = parse_text_document_uri(params)
	if p.uri == "" {
		return
	}
	td, _ := jsonutil.obj_get(params, "textDocument") // present: the uri came out of it
	if vv, found := jsonutil.obj_get(td, "version"); found {
		// Same integer rule as the open: a non-integer leaves has_version
		// unset and the handler drops the malformed change.
		#partial switch x in vv {
		case json.Integer:
			v := i64(x)
			if v >= DOC_VERSION_MIN && v <= DOC_VERSION_MAX {
				p.version = i32(v)
				p.has_version = true
			}
		case:
		}
	}
	cv, found := jsonutil.obj_get(params, "contentChanges")
	if !found {
		return
	}
	items, is_arr := jsonutil.as_array(cv)
	if !is_arr || len(items) != 1 {
		return
	}
	change, is_obj := jsonutil.as_object(items[0])
	if !is_obj {
		return
	}
	if _, has_range := change["range"]; has_range {
		return
	}
	if tv, got := change["text"]; got {
		#partial switch x in tv {
		case json.String:
			p.text = string(x)
			p.is_full = true
		case:
		}
	}
	return
}

// parse_workspace_folders collects the initialize workspace folders' URIs
// (empty when absent or malformed).
parse_workspace_folders :: proc(params: json.Value, a: mem.Allocator) -> []string {
	v, ok := jsonutil.obj_get(params, "workspaceFolders")
	if !ok {
		return nil
	}
	items, is_arr := jsonutil.as_array(v)
	if !is_arr {
		return nil
	}
	dyn := make([dynamic]string, 0, len(items), a)
	for item in items {
		m, is_obj := jsonutil.as_object(item)
		if !is_obj {
			continue
		}
		if uv, found := m["uri"]; found {
			if s := jsonutil.value_str(uv); s != "" {
				append(&dyn, s)
			}
		}
	}
	return dyn[:]
}

// negotiate_encoding picks the connection's position encoding from the
// client's general.positionEncodings offer: utf-8 when offered, utf-16
// otherwise — including an offer naming neither, which stays utf-16 on
// purpose: the specification makes utf-16 the mandatory baseline every
// client must accept, so a non-conforming offer degrades to it instead
// of failing the connection over an encoding this face cannot emit.
negotiate_encoding :: proc(params: json.Value) -> Position_Encoding {
	if caps, ok := jsonutil.obj_get(params, "capabilities"); ok {
		if general, have := jsonutil.obj_get(caps, "general"); have {
			if encs, got := jsonutil.obj_get(general, "positionEncodings"); got {
				if items, is_arr := jsonutil.as_array(encs); is_arr {
					for item in items {
						if jsonutil.value_str(item) == POSITION_ENCODING_UTF8 {
							return .Utf8
						}
					}
				}
			}
		}
	}
	return .Utf16
}

encoding_wire :: proc(e: Position_Encoding) -> string {
	return e == .Utf8 ? POSITION_ENCODING_UTF8 : POSITION_ENCODING_UTF16
}

// negotiate_apply_edit reads workspace.applyEdit: the client's willingness
// to receive server-initiated edit applications at all.
negotiate_apply_edit :: proc(params: json.Value) -> bool {
	caps, ok := jsonutil.obj_get(params, "capabilities")
	if !ok {
		return false
	}
	ws, have := jsonutil.obj_get(caps, "workspace")
	if !have {
		return false
	}
	return jsonutil.obj_get_bool(ws, "applyEdit")
}

// negotiate_document_changes reads workspace.workspaceEdit.documentChanges:
// the version-pinned TextDocumentEdit form the round trip requires (the
// version-less `changes` map would drop the pre-apply version check).
negotiate_document_changes :: proc(params: json.Value) -> bool {
	caps, ok := jsonutil.obj_get(params, "capabilities")
	if !ok {
		return false
	}
	ws, have := jsonutil.obj_get(caps, "workspace")
	if !have {
		return false
	}
	we, got := jsonutil.obj_get(ws, "workspaceEdit")
	if !got {
		return false
	}
	return jsonutil.obj_get_bool(we, "documentChanges")
}

// negotiate_hierarchical_symbols reads
// textDocument.documentSymbol.hierarchicalDocumentSymbolSupport: the
// client's declaration that documentSymbol answers may use the hierarchical
// DocumentSymbol[] form. Absent or false = flat SymbolInformation[].
negotiate_hierarchical_symbols :: proc(params: json.Value) -> bool {
	caps, ok := jsonutil.obj_get(params, "capabilities")
	if !ok {
		return false
	}
	td, have := jsonutil.obj_get(caps, "textDocument")
	if !have {
		return false
	}
	ds, got := jsonutil.obj_get(td, "documentSymbol")
	if !got {
		return false
	}
	return jsonutil.obj_get_bool(ds, "hierarchicalDocumentSymbolSupport")
}

// server_apply_caps reports the negotiated applyEdit bits under mu.
server_apply_caps :: proc(s: ^Server) -> (apply_edit, document_changes: bool) {
	sync.mutex_lock(&s.mu)
	apply_edit, document_changes = s.can_apply_edit, s.can_document_changes
	sync.mutex_unlock(&s.mu)
	return
}

// ---------------------------------------------------------------------------
// Open-document view
// ---------------------------------------------------------------------------

server_view_open :: proc(s: ^Server, uri: string, language_id: string, version: i32, text: string) {
	// Caller holds s.mu. The language rides the view for the publish
	// pass's readiness query; didChange carries none, so only opens set it.
	if e := s.docs[uri]; e != nil {
		// A re-open restarts the client's version stream: adopt the new
		// content, drop everything derived from the old, and count the
		// document as the newest open.
		if e.text != "" {
			delete(e.text, s.allocator)
		}
		e.text = strings.clone(text, s.allocator)
		e.version = version
		if e.language_id != "" {
			delete(e.language_id, s.allocator)
		}
		e.language_id = strings.clone(language_id, s.allocator)
		doc_view_invalidate_index(s, e)
		e.has_note = false
		view_order_move_to_back(s, e.uri)
		return
	}
	if len(s.docs) >= LSP_MAX_OPEN_DOCUMENTS {
		server_view_evict_oldest(s)
	}
	key := strings.clone(uri, s.allocator)
	e := new(Doc_View, s.allocator)
	e^ = {
		uri         = key,
		language_id = strings.clone(language_id, s.allocator),
		text        = strings.clone(text, s.allocator),
		version     = version,
	}
	s.docs[key] = e
	append(&s.open_order, key)
}

// server_view_evict_oldest drops the oldest entry — head of the open
// order — from the view. Daemon-side document state is untouched: the
// entry is a derived view, and a later didClose still reaches the daemon.
server_view_evict_oldest :: proc(s: ^Server) {
	if len(s.open_order) == 0 {
		return
	}
	oldest := s.open_order[0]
	view_order_remove(s, oldest)
	if e := s.docs[oldest]; e != nil {
		doc_view_free(s, e)
	}
}

view_order_remove :: proc(s: ^Server, uri: string) {
	for u, i in s.open_order {
		if u == uri {
			for j := i + 1; j < len(s.open_order); j += 1 {
				s.open_order[j - 1] = s.open_order[j]
			}
			pop(&s.open_order)
			return
		}
	}
}

view_order_move_to_back :: proc(s: ^Server, uri: string) {
	for u, i in s.open_order {
		if u == uri {
			moved := s.open_order[i]
			for j := i + 1; j < len(s.open_order); j += 1 {
				s.open_order[j - 1] = s.open_order[j]
			}
			s.open_order[len(s.open_order) - 1] = moved
			return
		}
	}
}

// doc_view_free releases one entry. The delete_key's handed-back key is
// deliberately discarded: it is the entry's own uri clone, freed below.
doc_view_free :: proc(s: ^Server, e: ^Doc_View) {
	delete_key(&s.docs, e.uri)
	if e.text != "" {
		delete(e.text, s.allocator)
	}
	if e.language_id != "" {
		delete(e.language_id, s.allocator)
	}
	if e.line_index != nil {
		delete(e.line_index, s.allocator)
	}
	delete(e.uri, s.allocator)
	free(e, s.allocator)
}

// doc_line_index returns the view's cached line-start index, rebuilding it
// when the version moved on. The index feeds utf-16 column conversion and
// is built once per version — never per token, never per request when the
// document is unchanged.
doc_line_index :: proc(s: ^Server, v: ^Doc_View) -> []int {
	if v.has_line_index && v.line_version == v.version {
		return v.line_index
	}
	doc_view_invalidate_index(s, v)
	v.line_index = util.line_start_offsets(v.text, s.allocator)
	v.line_version = v.version
	v.has_line_index = true
	return v.line_index
}

doc_view_invalidate_index :: proc(s: ^Server, v: ^Doc_View) {
	if v.line_index != nil {
		delete(v.line_index, s.allocator)
		v.line_index = nil
	}
	v.has_line_index = false
}

log_message :: proc(s: ^Server, msg: string) {
	if s.log != nil {
		s.log(s.host, msg)
	}
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

// send_protocol_error answers a request with a JSON-RPC error whose code
// sits outside the shared jsonrpc.Err_Code vocabulary (LSP reserves
// -32002), so the body is built by hand. It follows the same reply
// deadline rule as every other response — a request's answer must not
// take the notification drop-fast policy.
send_protocol_error :: proc(conn: ^jsonrpc.Conn, id: jsonrpc.Id, id_set: bool, code: i32, message: string, a: mem.Allocator) -> bool {
	body := strings.concatenate(
		{
			`{"jsonrpc":"2.0","error":{"code":`,
			fmt.aprintf("%d", code, allocator = a),
			`,"message":`,
			jsonutil.json_quote(message, a),
			`},"id":`,
			jsonrpc.id_json(id, id_set, a),
			"}",
		},
		a,
	)
	return jsonrpc.conn_send_body(conn, body, platform.mono_ms() + jsonrpc.OUTBOUND_REPLY_TIMEOUT_MS)
}
