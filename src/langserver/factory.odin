// The production factory: spawns the server process (lsproc), wraps its
// stdio in a jsonrpc connection, pumps stdout into the read loop and
// drains stderr on dedicated threads, and runs the lsp handshake. The
// server-lifetime allocator (the manager's) owns everything the factory
// creates; argv/env are request-arena views consumed during the spawn.
package langserver

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:thread"

import "src:jsonrpc"
import "src:jsonutil"
import "src:lsproc"
import "src:lsp"
import "src:platform"
import "src:safety"
import "src:util"

// LSP connections cap frames at 64 MiB; anything larger is a broken
// peer, not a payload.
LSP_FRAME_CAP_BYTES :: 64 * 1024 * 1024

STDERR_PUMP_BUF :: 4096
STDERR_LINE_CAP :: 2048
TRACE_BODY_CAP :: 2048

// production_factory returns the real factory bound to the manager
// (its allocator and clock are what the create call consumes).
production_factory :: proc(m: ^Manager) -> Factory {
	return {user = m, create = factory_create}
}

// own_text honors the a-owned return contract on the pass-through paths:
// the source text belongs to the caller (the registry entry or the config
// clone), so it is cloned onto `a`. An empty text stays the "" literal,
// which no caller frees.
own_text :: proc(s: string, a: mem.Allocator) -> string {
	if s == "" {
		return ""
	}
	return strings.clone(s, a)
}

// merge_init_options_json combines the registry entry's static
// initialization options with the language's user options from the
// project config (both serialized object text): a shallow merge where
// user top-level keys win. Either side may be "". A user text that
// fails to re-parse (the config loader validated it once) falls back to
// the entry text rather than failing the start. Everything allocates on
// `a`; the returned text is `a`-owned.
merge_init_options_json :: proc(entry_json, user_json: string, a := context.allocator) -> string {
	if user_json == "" {
		return own_text(entry_json, a)
	}
	user, uerr := json.parse_string(user_json, spec = .JSON, parse_integers = true, allocator = a)
	if uerr != nil {
		return own_text(entry_json, a)
	}
	if entry_json == "" {
		return own_text(user_json, a)
	}
	entry, eerr := json.parse_string(entry_json, spec = .JSON, parse_integers = true, allocator = a)
	if eerr != nil {
		return own_text(user_json, a)
	}
	#partial switch uv in user {
	case json.Object:
		// Mutate the user object in place (parser-produced maps inside
		// unions are safe to edit; the switch binding is immutable, so
		// the map header is copied out first): every entry key the user
		// did not set carries over.
		um := uv
		#partial switch ev in entry {
		case json.Object:
			for k, v in ev {
				if _, ok := um[k]; !ok {
					um[k] = v
				}
			}
		case:
		}
	case:
		return own_text(entry_json, a)
	}
	return jsonutil.marshal_value(user, a)
}

factory_create :: proc(
	user:            rawptr,
	entry:           ^Entry,
	argv:            []string,
	env:             []string,
	folders:         []Workspace_Folder, // at least one; [0] is the primary root
	memory_limit_mb: int,
	clock:           ^platform.Clock,
	a:               mem.Allocator,
	token:           ^platform.Cancel_Token,
) -> (s: ^Server, err: platform.Err) {
	if len(folders) == 0 {
		return nil, platform.Err(.Internal)
	}
	// Everything implicit here (thread handles above all) must outlive
	// the request that triggered the start: pin the context allocator
	// to the server-lifetime allocator, scoped back before return.
	saved_allocator := context.allocator
	context.allocator = a
	defer context.allocator = saved_allocator
	m := cast(^Manager)user
	launch := lsproc.Launch{
		command        = argv,
		working_dir    = folders[0].path,
		env            = env,
		language_id    = entry.id,
		memory_limit_mb = memory_limit_mb,
	}
	child, spawn_err := lsproc.lsproc_spawn(launch, clock, a)
	if spawn_err != nil {
		return nil, spawn_err
	}

	s = new(Server, a)
	s^ = {
		language_id = strings.clone(entry.id, a),
		entry       = entry,
		child       = child,
		folders     = owned_folder_paths(folders, a),
		allocator   = a,
	}

	conn := new(jsonrpc.Conn, a)
	reader: jsonrpc.Reader
	writer: jsonrpc.Writer
	jsonrpc.reader_init(&reader, stdio_read_fn, s, LSP_FRAME_CAP_BYTES, a)
	jsonrpc.writer_init(&writer, stdio_write_fn, s)
	jsonrpc.conn_init(conn, reader, writer, a)
	if manager_trace_enabled(m) {
		// Set before the read loop and any send: the hook is write-once.
		conn.trace = lsp_trace_fn
		conn.trace_user = s
	}
	// The dedicated writer: a server that stops reading its stdin must
	// block exactly this one thread, never an editor file lock or the
	// stop path (its kill unwedges the writer; the join waits for that).
	// The conn is wired BEFORE the start: the failure branch destroys the
	// server, and server_destroy releases whatever is wired — a conn left
	// unassigned here would leak, a client assigned after the branch would
	// be nil-dereferenced there.
	s.conn = conn
	if !jsonrpc.conn_start_outbound(conn, jsonrpc.OUTBOUND_FRAMES_CAP, jsonrpc.OUTBOUND_BYTES_CAP) {
		server_destroy(s)
		return nil, platform.Err(.Internal)
	}

	client := new(lsp.Client, a)
	lsp.client_init(client, conn, clock, entry.id, a)
	// root_abs is the relativization base the location helpers resolve
	// server-reported URIs against — the PROJECT root, never the primary
	// folder: every announced folder sits under it, so answers from any
	// folder land on project-relative paths (what the index and the tools
	// speak). Pointing it at folders[0] silently dropped every reference
	// outside the first announced folder. The server's working directory
	// and rootUri still follow folders[0].
	//
	// The base must carry the RESOLVED spelling: editor and index paths
	// come out of the path guard symlink-resolved, and a root spelled
	// through a symlinked ancestor (macOS /var vs /private/var temp
	// trees) would make every prefix compare miss. Canonicalize once
	// here (temp-allocator scratch, clone into `a`); an unresolvable
	// root keeps its raw spelling.
	root_base := m.root
	resolved, perr := safety.pathguard_validate_contained_dir(m.root, m.root, context.temp_allocator)
	if perr.reason == "" {
		root_base = resolved
	}
	client.root_abs = strings.clone(root_base, a)
	s.client = client

	if entry.config_item != nil {
		client.config_provider = entry_config_provider
		client.config_host = entry
	}

	// The read loop must run before the handshake: replies arrive over
	// it. Same for the stderr drain — a server blocked on a full stderr
	// pipe never answers initialize.
	s.reader = thread.create_and_start_with_data(
		s, reader_thread_main, self_cleanup = false, name = "langserver-lsp-read",
	)
	s.stderr_pump = thread.create_and_start_with_data(
		s, stderr_thread_main, self_cleanup = false, name = "langserver-lsp-stderr",
	)
	if s.reader == nil || s.stderr_pump == nil {
		server_destroy(s)
		return nil, platform.Err(.Internal)
	}

	hs_folders := make([]lsp.Folder, len(folders), context.temp_allocator)
	for i in 0..<len(folders) {
		hs_folders[i] = {uri = folders[i].uri, name = folders[i].name}
	}
	// User options from the project config merge over the entry's static
	// initialization options (user top-level keys win) — ols's collections
	// are the worked example: they reach the server through this handshake
	// channel, never through a per-server config file.
	init_options := merge_init_options_json(
		entry.init_options_json,
		clone_options_json(m, entry.id, context.temp_allocator),
		context.temp_allocator,
	)
	ok, code, message, cerr := lsp.client_initialize(
		client, hs_folders, context.temp_allocator, token, init_options,
	)
	if !ok {
		// The token shortens the unwind when the failure IS the
		// cancellation (a fired token skips the shutdown round trip).
		server_destroy(s, token)
		// lsp.call_error is the single exhaustive Call_Err → Err_Kind
		// mapping; it also clones the message onto `a`, because the
		// handshake's copy lives on the request's temp allocator.
		// ok == false without a call outcome would break the
		// fail-closed contract; keep the boundary honest as .Internal.
		if cerr == .None {
			return nil, platform.Err(.Internal)
		}
		return nil, lsp.call_error("initialize", code, message, cerr, a)
	}

	// Cross-file reference readiness: the event window (first
	// publishDiagnostics or WorkDone end) or the settle fallback. The
	// outcome does not gate the start — a quiet server is still usable.
	_ = lsp.client_wait_cross_file_refs(client, token)
	return s, nil
}

// owned_folder_paths clones the folder paths onto the server-lifetime
// allocator (the create call's folder views die with the request arena).
owned_folder_paths :: proc(folders: []Workspace_Folder, a: mem.Allocator) -> []string {
	paths := make([]string, len(folders), context.temp_allocator)
	for i in 0..<len(folders) {
		paths[i] = folders[i].path
	}
	return clone_strings(paths, a)
}

reader_thread_main :: proc(data: rawptr) {
	s := cast(^Server)data
	_ = jsonrpc.conn_read_loop(s.conn)
}

// stderr_thread_main drains the server's stderr and logs it line by line
// at debug level — the minimal form of stderr classification:
// everything a server writes is diagnostics. The read blocks; EOF means
// the child is gone and the pump exits.
stderr_thread_main :: proc(data: rawptr) {
	s := cast(^Server)data
	rbuf: [STDERR_PUMP_BUF]u8
	line: [STDERR_LINE_CAP]u8
	n := 0
	for {
		r, eof := lsproc.lsproc_read_stderr(s.child, rbuf[:])
		if eof {
			stderr_flush(s, line[:], &n)
			return
		}
		for i := 0; i < r; i += 1 {
			if rbuf[i] == '\n' {
				stderr_flush(s, line[:], &n)
			} else if n < len(line) {
				// Overlong tails are dropped, never split into a second
				// line.
				line[n] = rbuf[i]
				n += 1
			}
		}
	}
}

// stderr_flush logs one assembled line. The message string is consumed
// inside the log call before this frame returns, so building it in a
// stack buffer is safe.
stderr_flush :: proc(s: ^Server, line: []u8, n: ^int) {
	if n^ == 0 {
		return
	}
	buf: [STDERR_LINE_CAP + 48]u8
	w := trace_put(buf[:], 0, "lsp ")
	w = trace_put(buf[:], w, s.language_id)
	w = trace_put(buf[:], w, " stderr: ")
	w = trace_put(buf[:], w, string(line[:n^]))
	util.log_debug(string(buf[:w]))
	n^ = 0
}

// lsp_trace_fn renders one traced LSP frame at debug level, truncated: a
// full documentSymbol reply dwarfs any log line. Stack buffer only — the
// hook runs on the reader and sender threads, where neither context
// allocator belongs to this package.
lsp_trace_fn :: proc(user: rawptr, outbound: bool, body: string) {
	s := cast(^Server)user
	buf: [TRACE_BODY_CAP + 64]u8
	w := trace_put(buf[:], 0, "lsp ")
	w = trace_put(buf[:], w, s.language_id)
	w = trace_put(buf[:], w, outbound ? " -> " : " <- ")
	take := len(body)
	if take > TRACE_BODY_CAP {
		take = TRACE_BODY_CAP
	}
	for i := 0; i < take; i += 1 {
		buf[w] = body[i]
		w += 1
	}
	if len(body) > TRACE_BODY_CAP {
		w = trace_put(buf[:], w, "...")
	}
	util.log_debug(string(buf[:w]))
}

// trace_put appends s into buf at offset n and returns the new offset;
// anything past the buffer is dropped (log lines are best-effort).
trace_put :: proc(buf: []u8, n_in: int, s: string) -> int {
	n := n_in
	for i := 0; i < len(s) && n < len(buf); i += 1 {
		buf[n] = s[i]
		n += 1
	}
	return n
}

// stdio_read_fn adapts lsproc's stdout reader to the jsonrpc Reader:
// n > 0 is data, EOF maps to the framing layer's .Eof, anything else is
// an I/O failure.
stdio_read_fn :: proc(data: rawptr, buf: []u8) -> (int, jsonrpc.Read_Err) {
	s := cast(^Server)data
	n, eof := lsproc.lsproc_read_stdout(s.child, buf)
	if n > 0 {
		return n, .None
	}
	if eof {
		return 0, .Eof
	}
	return 0, .Io
}

// stdio_write_fn adapts lsproc's stdin writer; the -1 failure return
// (EBADF/EPIPE after stop or death) maps to .Io.
stdio_write_fn :: proc(data: rawptr, buf: []u8) -> (int, jsonrpc.Read_Err) {
	s := cast(^Server)data
	n := lsproc.lsproc_write_stdin(s.child, buf)
	if n >= 0 {
		return n, .None
	}
	return 0, .Io
}

// entry_config_provider answers workspace/configuration item by item
// through the entry's per-section handler.
entry_config_provider :: proc(user: rawptr, params: json.Value, arena: mem.Allocator) -> json.Value {
	e := cast(^Entry)user
	arr := make(json.Array, 0, 2, arena)
	if items, ok := jsonutil.obj_get(params, "items"); ok {
		#partial switch x in items {
		case json.Array:
			for item in x {
				section := ""
				if sv, sok := jsonutil.obj_get(item, "section"); sok {
					section = jsonutil.value_str(sv)
				}
				append(&arr, e.config_item(section, arena))
			}
		case:
		}
	}
	return json.Value(json.Array(arr))
}
