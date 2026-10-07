// The relay face: the three position-started requests (definition,
// references, declaration) the child answers out of the daemon's symbol
// inventory, plus the daemon→child diagnostics republish and the dynamic
// registration wrappers. This layer is transport-agnostic like the rest of
// the package: the position conversion against the open-document view
// happens here, everything that needs the daemon crosses the Relay_Host /
// Text_For_Uri_Host proc fields.
//
// Column discipline: the svc face's positions are UTF-16 end to
// end. The inbound request position arrives in the connection's encoding —
// under a utf-8 connection `character` is a byte column and converts to
// UTF-16 through the view's text before the host is called. The host's
// answer columns are UTF-16 and convert back to the negotiated encoding
// for the reply — .Utf16 passes through, .Utf8 goes through the TARGET
// file's line bytes, and a location whose text cannot be served is DROPPED
// rather than emitted with a UTF-16 number in a byte column.
//
// Concurrency: the request handlers and the republish run on whatever
// thread dispatches their frame; both touch view state only through the
// mu-guarded snapshot helpers. server_register_capabilities and
// server_unregister_capabilities are the ONE exception to the
// dispatch-thread-only send rule: they run on the host's starter thread
// (the registration drive must not park the dispatch loop behind a slow
// editor client), which is safe because conn_call's pending table and the
// outbound write path are internally locked, and they gate their activity
// on server_is_shutdown themselves.
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

Relay_Kind :: enum {
	Definition,
	References,
	Declaration,
}

// Relay_Location is one answer site. `uri` arrives in the client-facing
// spelling — the HOST resolves every location into the spelling the
// connected editor used (the open view's own uri when the child holds that
// document, the canonical root-relative file URI otherwise); this face
// renders it verbatim. Columns are UTF-16 code units.
Relay_Location :: struct {
	uri:     string,
	line:    int,
	col:     int,
	has_end: bool,
	end_line: int,
	end_col: int,
}

Relay_Result :: struct {
	locations:  []Relay_Location, // arena-owned
	failed:     bool,             // the fetch itself failed (err_message says why)
	err_message: string,
}

// Relay_Host resolves one position-started lookup against the daemon's
// symbol inventory. `uri` names the open document (client spelling), the
// position is UTF-16, and the answer locations are already re-spelled for
// the client (see Relay_Location). Misses answer empty — never an error.
Relay_Host :: proc(host: rawptr, uri: string, line: int, col_utf16: int, include_declaration: bool, kind: Relay_Kind, arena: mem.Allocator) -> Relay_Result

// Text_For_Uri_Host serves one document's text for the answer-column
// conversion: the view text for open documents, a fetched file otherwise.
// ok=false means the text cannot be served; the face drops the location.
Text_For_Uri_Host :: proc(host: rawptr, uri: string, arena: mem.Allocator) -> (text: string, ok: bool)

// Capability_Registration is one dynamic registration (or unregistration):
// the id the client later unregisters by, the method, and the language id
// that becomes the documentSelector's single language filter.
Capability_Registration :: struct {
	id:      string,
	method:  string,
	language: string,
}

// ---------------------------------------------------------------------------
// Request handlers (definition / references / declaration)
// ---------------------------------------------------------------------------

handle_relay_request :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	s := server_from_conn(conn)
	reply, action, gated := request_gate_reply(s, conn, env, arena)
	if gated {
		return reply, action
	}

	kind := relay_kind_of(env.method)
	p, ok := parse_relay_params(env.params)
	if !ok {
		reply = {is_error = true, err_code = .Invalid_Params, err_message = "textDocument.uri and position are required"}
		return reply, .Respond
	}

	// Editors only ask the relay for open documents; anything else is a
	// normal empty answer, not a refusal (and never reaches the host).
	if !server_is_tracking_uri(s, p.uri) {
		return relay_reply(nil, arena)
	}

	// The svc face speaks UTF-16: under a utf-8 connection the wire
	// character is a byte column and converts through the view's text.
	col_utf16 := p.character
	if s.encoding == .Utf8 {
		snap, have := server_snapshot_doc(s, p.uri, arena)
		if !have {
			return relay_reply(nil, arena)
		}
		col_utf16 = relay_request_utf16_col(snap.text, p.line, p.character, arena)
	}

	if s.relay == nil {
		return relay_reply(nil, arena)
	}
	rr := s.relay(s.host, p.uri, p.line, col_utf16, p.include_declaration, kind, arena)
	if rr.failed {
		log_message(s, fmt.aprintf("relay %s unavailable for %s: %s; answering empty", env.method, p.uri, rr.err_message, allocator = arena))
		return relay_reply(nil, arena)
	}
	return relay_reply(relay_locations_json(s, rr.locations, arena), arena)
}

// relay_reply wraps one relay answer: an empty Location[] when locations is
// nil, else the rendered array.
relay_reply :: proc(locations: json.Value, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	result := locations
	if result == nil {
		empty := make([dynamic]json.Value, 0, 0, arena)
		result = jsonutil.json_array(empty[:], arena)
	}
	reply: jsonrpc.Reply = {result = result}
	return reply, .Respond
}

relay_kind_of :: proc(method: string) -> Relay_Kind {
	kind: Relay_Kind = .Definition
	switch method {
	case lsp.METHOD_REFERENCES:
		kind = .References
	case lsp.METHOD_DECLARATION:
		kind = .Declaration
	case:
	}
	return kind
}

Relay_Params :: struct {
	uri:                 string,
	line:                int,
	character:           int,
	include_declaration: bool, // references context.includeDeclaration
}

parse_relay_params :: proc(params: json.Value) -> (p: Relay_Params, ok: bool) {
	td, have := jsonutil.obj_get(params, "textDocument")
	if !have {
		return
	}
	if uv, found := jsonutil.obj_get(td, "uri"); found {
		p.uri = jsonutil.value_str(uv)
	}
	if p.uri == "" {
		return
	}
	pos, have_pos := jsonutil.obj_get(params, "position")
	if !have_pos {
		return
	}
	p.line = int(jsonutil.obj_get_int(pos, "line"))
	p.character = int(jsonutil.obj_get_int(pos, "character"))
	if ctx, found := jsonutil.obj_get(params, "context"); found {
		p.include_declaration = jsonutil.obj_get_bool(ctx, "includeDeclaration")
	}
	return p, true
}

// relay_request_utf16_col converts a utf-8 connection's byte column on one
// line into the UTF-16 column the svc face expects. Lines past the
// document's end clamp to the last line; columns past the line's end clamp
// inside the converter — the same tolerance the editor-side positions get.
relay_request_utf16_col :: proc(text: string, line, byte_col: int, a: mem.Allocator) -> int {
	starts := util.line_start_offsets(text, a)
	if len(starts) == 0 {
		return 0
	}
	return util.byte_offset_to_utf16_col(relay_line_text(text, starts, relay_clamped_line(starts, line)), byte_col)
}

// relay_target_byte_col converts one answer location's UTF-16 column into
// the target file's byte column (the utf-8 connection's negotiated unit)
// over the document's line-start index (relay_line_index's).
relay_target_byte_col :: proc(text: string, starts: []int, line, col_utf16: int) -> int {
	if len(starts) == 0 {
		return 0
	}
	return util.utf16_col_to_byte_offset(relay_line_text(text, starts, relay_clamped_line(starts, line)), col_utf16)
}

// relay_line_text returns the byte slice of one line excluding its '\n'
// delimiter, KEEPING a preceding '\r' — the same span the daemon's
// Position_Converter measures symbol columns over (its line end is the
// next start minus the '\n' only), so answer columns converted here
// round-trip the daemon-side conversion exactly. The publish/tokens
// families strip the '\r' as well (doc_line_span): their spans are
// converted fresh from bytes, and LSP counts neither half of a "\r\n"
// terminator as a line character.
relay_line_text :: proc(text: string, starts: []int, line: int) -> string {
	line_end := len(text)
	if line + 1 < len(starts) {
		line_end = starts[line + 1]
	}
	line_text_end := line_end
	if line_text_end > starts[line] && line_text_end <= len(text) && text[line_text_end - 1] == '\n' {
		line_text_end -= 1
	}
	return text[starts[line]:line_text_end]
}

// relay_clamped_line bounds one line number onto a line index. Line
// indexes always carry at least the offset 0 (line_start_offsets), so the
// empty guard is structural. The clamp rides WITH the converted column:
// a position past the document's end emits the line it was measured
// against, never the stale line number beside a clamped column.
relay_clamped_line :: proc(starts: []int, line: int) -> int {
	if len(starts) == 0 {
		return 0
	}
	ln := line
	if ln < 0 {
		ln = 0
	}
	if ln >= len(starts) {
		ln = len(starts) - 1
	}
	return ln
}

// relay_locations_json renders the answer's Location[] in the negotiated
// encoding. Under utf-8 each location's target file text and line index are
// served through relay_line_index (cached per request arena — one fetch and
// one scan per document per request); an unservable location is dropped,
// never emitted with a UTF-16 number in a byte column, and the drop logs
// once per request.
relay_locations_json :: proc(s: ^Server, locs: []Relay_Location, a: mem.Allocator) -> json.Value {
	items := make([dynamic]json.Value, 0, len(locs), a)
	texts := make(map[string]string, 8, a)
	starts := make(map[string][]int, 8, a)
	dropped_logged := false
	for loc in locs {
		sc := loc.col
		ec := loc.end_col
		sl := loc.line
		el := loc.has_end ? loc.end_line : loc.line
		if s.encoding == .Utf8 {
			text, lines, ok := relay_line_index(s, loc.uri, &texts, &starts, a)
			if !ok {
				if !dropped_logged {
					log_message(s, fmt.aprintf("relay answer text unavailable for %s; the location was dropped", loc.uri, allocator = a))
					dropped_logged = true
				}
				continue
			}
			// The clamped lines ride with their converted columns (see
			// relay_clamped_line): a position past the document's end never
			// mixes a stale line number with a last-line column.
			sl = relay_clamped_line(lines, loc.line)
			sc = relay_target_byte_col(text, lines, loc.line, loc.col)
			el = loc.has_end ? relay_clamped_line(lines, loc.end_line) : sl
			ec = loc.has_end ? relay_target_byte_col(text, lines, loc.end_line, loc.end_col) : sc
		} else if !loc.has_end {
			ec = loc.col // point range: start == end
		}

		start := jsonutil.json_object(2, a)
		jsonutil.obj_set(&start, "line", jsonutil.json_int(i64(sl)))
		jsonutil.obj_set(&start, "character", jsonutil.json_int(i64(sc)))
		end := jsonutil.json_object(2, a)
		jsonutil.obj_set(&end, "line", jsonutil.json_int(i64(el)))
		jsonutil.obj_set(&end, "character", jsonutil.json_int(i64(ec)))
		rng := jsonutil.json_object(2, a)
		jsonutil.obj_set_object(&rng, "start", start)
		jsonutil.obj_set_object(&rng, "end", end)

		item := jsonutil.json_object(2, a)
		jsonutil.obj_set(&item, "uri", jsonutil.json_string(loc.uri))
		jsonutil.obj_set_object(&item, "range", rng)
		append(&items, json.Value(json.Object(item)))
	}
	return jsonutil.json_array(items[:], a)
}

// relay_text_cached fetches one location document's text at most once per
// request: the cache (and its keys and values) lives in the request arena.
relay_text_cached :: proc(s: ^Server, uri: string, texts: ^map[string]string, a: mem.Allocator) -> (string, bool) {
	if t, ok := texts^[uri]; ok {
		return t, true
	}
	if s.text_for_uri == nil {
		return "", false
	}
	text, ok := s.text_for_uri(s.host, uri, a)
	if !ok {
		return "", false
	}
	texts^[strings.clone(uri, a)] = strings.clone(text, a)
	return text, true
}

// relay_line_index serves one document's text and line-start index for the
// request's lifetime: the text rides the per-request text cache, the line
// index a parallel per-uri cache — one fetch and one scan per document per
// request, however many endpoints convert through it (a references answer
// would otherwise rescan the whole document per endpoint). Both caches and
// their keys live in the request arena.
relay_line_index :: proc(s: ^Server, uri: string, texts: ^map[string]string, starts: ^map[string][]int, a: mem.Allocator) -> (text: string, lines: []int, ok: bool) {
	text, ok = relay_text_cached(s, uri, texts, a)
	if !ok {
		return
	}
	if st, cached := starts^[uri]; cached {
		return text, st, true
	}
	lines = util.line_start_offsets(text, a)
	starts^[strings.clone(uri, a)] = lines
	return text, lines, true
}

// ---------------------------------------------------------------------------
// Diagnostics republish
// ---------------------------------------------------------------------------

// publish_relay_diagnostics forwards one daemon push of the stored real-LS
// diagnostic set for `uri` onto the editor connection. The items string is
// the marshaled LSP Diagnostic[] with UTF-16 positions; the republish uses
// THE VIEW's uri and current version — the daemon's mirror version is not
// the editor's number space, and a stale-looking stamp can get the publish
// discarded. A document the view does not hold returns silently (the
// daemon may serve other children); under a utf-8 connection every range
// column converts through the snapshot's line index — each diagnostic's
// own, and its relatedInformation's when every related location names
// this document (anything else drops the member; see the conversion
// block).
publish_relay_diagnostics :: proc(s: ^Server, uri: string, items_json: string, a: mem.Allocator) {
	items_v, perr := json.parse_string(items_json, spec = .JSON, parse_integers = true, allocator = a)
	if perr != nil {
		log_message(s, "relay diagnostics push did not parse; dropped")
		return
	}
	items, is_arr := jsonutil.as_array(items_v)
	if !is_arr {
		log_message(s, "relay diagnostics push carried no diagnostic array; dropped")
		return
	}
	snap, ok := server_snapshot_doc(s, uri, a)
	if !ok {
		return
	}
	if s.encoding == .Utf8 {
		starts := util.line_start_offsets(snap.text, a)
		for item in items {
			if rng, has := jsonutil.obj_get(item, "range"); has {
				relay_fix_position(snap.text, starts, rng, "start")
				relay_fix_position(snap.text, starts, rng, "end")
			}
			// The conversion truth is THIS document's text: a related
			// location naming another file (or the same file through a
			// different uri spelling) would convert against the wrong
			// bytes, so the member drops to the wire-legal empty array
			// rather than carry columns no text vouches for.
			if rel_v, has := jsonutil.obj_get(item, "relatedInformation"); has {
				if rels, is_rel_arr := jsonutil.as_array(rel_v); is_rel_arr {
					same_doc := true
					for rel in rels {
						rel_uri := ""
						if loc, has_loc := jsonutil.obj_get(rel, "location"); has_loc {
							if u, has_u := jsonutil.obj_get(loc, "uri"); has_u {
								rel_uri = jsonutil.value_str(u)
							}
						}
						if rel_uri != snap.uri {
							same_doc = false
							break
						}
					}
					if same_doc {
						for rel in rels {
							if loc, has_loc := jsonutil.obj_get(rel, "location"); has_loc {
								if rng, has_rng := jsonutil.obj_get(loc, "range"); has_rng {
									relay_fix_position(snap.text, starts, rng, "start")
									relay_fix_position(snap.text, starts, rng, "end")
								}
							}
						}
					} else {
						// Mutate through the object's map (the for-binding's
						// item value is not addressable).
						if m, is_obj := jsonutil.as_object(item); is_obj {
							m["relatedInformation"] = jsonutil.json_array(make([]json.Value, 0, a), a)
						}
					}
				}
			}
		}
	}

	params := jsonutil.json_object(3, a)
	jsonutil.obj_set(&params, "uri", jsonutil.json_string(snap.uri))
	jsonutil.obj_set(&params, "version", jsonutil.json_int(i64(snap.version)))
	jsonutil.obj_set(&params, "diagnostics", jsonutil.json_array(items, a))
	// The send shares s.mu with the close path (publish_due_flush's rule):
	// a didClose landing between the snapshot above and this send frees the
	// view and sends its clearing publish — the re-check under the lock
	// keeps this republish silent for a closed document, so the close-clear
	// stays the last publishDiagnostics a closed document receives.
	sync.mutex_lock(&s.mu)
	if s.docs[uri] != nil {
		_ = jsonrpc.conn_notify(s.conn, lsp.METHOD_PUBLISH_DIAGNOSTICS, json.Value(json.Object(params)), a)
	}
	sync.mutex_unlock(&s.mu)
}

// relay_fix_position rewrites one range endpoint's character column in
// place (the parsed value is request-arena scratch nobody else reads).
// Lines past the document clamp to the last line — the CLAMPED line is
// emitted with the column it was measured against, never the stale line
// beside a converted column — and columns past the line's end clamp
// inside the converter: never a UTF-16 number in a byte column.
relay_fix_position :: proc(text: string, starts: []int, rng: json.Value, which: string) {
	pos, ok := jsonutil.obj_get(rng, which)
	if !ok {
		return
	}
	m, is_obj := jsonutil.as_object(pos)
	if !is_obj {
		return
	}
	line := relay_clamped_line(starts, int(jsonutil.obj_get_int(pos, "line")))
	col := int(jsonutil.obj_get_int(pos, "character"))
	m["line"] = jsonutil.json_int(i64(line))
	m["character"] = jsonutil.json_int(i64(util.utf16_col_to_byte_offset(relay_line_text(text, starts, line), col)))
}

// ---------------------------------------------------------------------------
// Dynamic registration wrappers
// ---------------------------------------------------------------------------

// server_register_capabilities sends ONE client/registerCapability for the
// whole batch, building each entry's documentSelector from its language.
// Runs on the host's starter thread, NOT the dispatch thread — see the
// package comment. ok=false means the call failed; the caller leaves the
// language unregistered and lets its next state change re-drive this.
server_register_capabilities :: proc(s: ^Server, registrations: []Capability_Registration, a: mem.Allocator, deadline_ms: i64) -> bool {
	items := make([]json.Value, len(registrations), a)
	for reg, i in registrations {
		entry := jsonutil.json_object(3, a)
		jsonutil.obj_set(&entry, "id", jsonutil.json_string(reg.id))
		jsonutil.obj_set(&entry, "method", jsonutil.json_string(reg.method))
		selector_item := jsonutil.json_object(1, a)
		jsonutil.obj_set(&selector_item, "language", jsonutil.json_string(reg.language))
		one := make([]json.Value, 1, a)
		one[0] = json.Value(json.Object(selector_item))
		options := jsonutil.json_object(1, a)
		jsonutil.obj_set(&options, "documentSelector", jsonutil.json_array(one, a))
		jsonutil.obj_set_object(&entry, "registerOptions", options)
		items[i] = json.Value(json.Object(entry))
	}
	params := jsonutil.json_object(1, a)
	jsonutil.obj_set(&params, "registrations", jsonutil.json_array(items, a))
	_, _, _, cerr := jsonrpc.conn_call(
		s.conn,
		lsp.METHOD_REGISTER_CAPABILITY,
		json.Value(json.Object(params)),
		a,
		platform.mono_ms() + deadline_ms,
	)
	return cerr == .None
}

// server_unregister_capabilities sends ONE client/unregisterCapability.
// The params member is spelled "unregisterations" — that is the
// specification's own wire spelling, not a typo introduced here. Runs on
// the host's starter thread (see server_register_capabilities).
server_unregister_capabilities :: proc(s: ^Server, unregistrations: []Capability_Registration, a: mem.Allocator, deadline_ms: i64) -> bool {
	items := make([]json.Value, len(unregistrations), a)
	for reg, i in unregistrations {
		entry := jsonutil.json_object(2, a)
		jsonutil.obj_set(&entry, "id", jsonutil.json_string(reg.id))
		jsonutil.obj_set(&entry, "method", jsonutil.json_string(reg.method))
		items[i] = json.Value(json.Object(entry))
	}
	params := jsonutil.json_object(1, a)
	jsonutil.obj_set(&params, "unregisterations", jsonutil.json_array(items, a))
	_, _, _, cerr := jsonrpc.conn_call(
		s.conn,
		lsp.METHOD_UNREGISTER_CAPABILITY,
		json.Value(json.Object(params)),
		a,
		platform.mono_ms() + deadline_ms,
	)
	return cerr == .None
}

// ---------------------------------------------------------------------------
// View-side helpers the host and the republish share
// ---------------------------------------------------------------------------

// server_is_shutdown reports the face's shutdown latch under mu, for the
// off-dispatch threads (the registration drive) that must stop touching
// the connection once shutdown began.
server_is_shutdown :: proc(s: ^Server) -> bool {
	sync.mutex_lock(&s.mu)
	v := s.is_shutdown
	sync.mutex_unlock(&s.mu)
	return v
}

// server_view_uris clones the open view's uri set into the caller's arena
// under mu. The host matches answer documents against the open set by rel
// path — the one place the client-facing spelling is decided.
server_view_uris :: proc(s: ^Server, a: mem.Allocator) -> []string {
	sync.mutex_lock(&s.mu)
	uris := make([]string, len(s.docs), a)
	i := 0
	for u in s.docs {
		uris[i] = strings.clone(u, a)
		i += 1
	}
	sync.mutex_unlock(&s.mu)
	return uris
}
