// The ops relay face: the six langserver-backed requests — formatting,
// code actions, inlay hints, and the call-hierarchy family (prepare,
// incoming calls, outgoing calls). The daemon answers cross the Ops_Host
// proc field as DTO arrays (the shapes are pinned on Ops_Result in
// server.odin); this layer owns the wire rendering and the column
// discipline, the same rules the position relay applies:
//
// Inbound request positions arrive in the negotiated encoding — under a
// utf-8 connection the wire columns are bytes and convert to the svc
// face's UTF-16 through the requested document's text before the host
// call. The host's answer columns are UTF-16 and convert back through each
// item's own file: a utf-16 connection needs no text service at all, under
// utf-8 an answer piece whose text cannot be served is DROPPED (or
// degrades the whole answer when the requested document itself is
// unservable) rather than emitted with a UTF-16 number in a byte column,
// and every drop logs at most once per request. Call-edge fromRanges
// follow the specification's containment: they are relative to the caller
// — the `from` item's file for incoming calls, the prepared document for
// outgoing calls.
//
// Failures and misses answer empty arrays, never error responses (the
// relay rule); only malformed params are protocol violations.
package lspserver

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

import "src:jsonrpc"
import "src:jsonutil"
import "src:lsp"

// ---------------------------------------------------------------------------
// Request handling
// ---------------------------------------------------------------------------

handle_ops_request :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	s := server_from_conn(conn)
	reply, action, gated := request_gate_reply(s, conn, env, arena)
	if gated {
		return reply, action
	}

	kind := ops_kind_of(env.method)
	req, ok := ops_parse_params(env.params, kind)
	if !ok {
		reply = {is_error = true, err_code = .Invalid_Params, err_message = ops_params_error(kind)}
		return reply, .Respond
	}
	if kind == .Call_Edges {
		req.incoming = env.method == lsp.METHOD_INCOMING_CALLS
	}

	// Under a utf-8 connection every position — the request's and the
	// answer's — rides the requested document's text: the open view's
	// snapshot when tracked, the host's fetch otherwise. Without that
	// conversion truth there is no honest answer, so the request degrades
	// to empty before the host is called. The text seeds the per-request
	// caches the renderers share, and converts the request's own wire
	// columns into the UTF-16 the svc face speaks (formatting carries no
	// positions).
	texts := make(map[string]string, 4, arena)
	starts := make(map[string][]int, 4, arena)
	if s.encoding == .Utf8 {
		doc_text, served := ops_request_doc_text(s, req.uri, &texts, arena)
		if !served {
			log_message(s, fmt.aprintf("%s: the document's text is unavailable for %s; answering empty", env.method, req.uri, allocator = arena))
			return relay_reply(nil, arena)
		}
		if req.kind != .Formatting {
			req.start_col = relay_request_utf16_col(doc_text, req.start_line, req.start_col, arena)
			if req.kind == .Code_Actions || req.kind == .Inlay_Hints {
				req.end_col = relay_request_utf16_col(doc_text, req.end_line, req.end_col, arena)
			}
		}
	}

	if s.ops == nil {
		return relay_reply(nil, arena)
	}
	res := s.ops(s.host, req, arena)
	if res.failed {
		log_message(s, fmt.aprintf("%s unavailable for %s: %s; answering empty", env.method, req.uri, res.err_message, allocator = arena))
		return relay_reply(nil, arena)
	}
	return relay_reply(ops_render(s, kind, req, res.items, &texts, &starts, arena), arena)
}

ops_kind_of :: proc(method: string) -> Ops_Kind {
	kind: Ops_Kind = .Formatting
	switch method {
	case lsp.METHOD_CODE_ACTION:
		kind = .Code_Actions
	case lsp.METHOD_INLAY_HINT:
		kind = .Inlay_Hints
	case lsp.METHOD_PREPARE_CALL_HIERARCHY:
		kind = .Prepare_Call_Hierarchy
	case lsp.METHOD_INCOMING_CALLS, lsp.METHOD_OUTGOING_CALLS:
		kind = .Call_Edges
	case:
	}
	return kind
}

// ops_params_error names the members the family's params require — the
// message the Invalid_Params reply carries.
ops_params_error :: proc(kind: Ops_Kind) -> string {
	switch kind {
	case .Formatting:
		return "textDocument.uri is required"
	case .Code_Actions, .Inlay_Hints:
		return "textDocument.uri and range are required"
	case .Prepare_Call_Hierarchy:
		return "textDocument.uri and position are required"
	case .Call_Edges:
		return "item with a uri and a selectionRange is required"
	}
	return "malformed params"
}

// ops_parse_params reads the six families' params into the host request.
// Formatting options honor the client's tabSize/insertSpaces with the
// specification's defaults (4 / true). The edges requests carry no
// textDocument: the prepared item echoes the document uri, and its
// selectionRange start is the point the daemon faces resolve against — the
// rest of the item is opaque to this face.
ops_parse_params :: proc(params: json.Value, kind: Ops_Kind) -> (req: Ops_Request, ok: bool) {
	req.kind = kind
	req.tab_size = 4
	req.insert_spaces = true

	if kind != .Call_Edges {
		td, have := jsonutil.obj_get(params, "textDocument")
		if !have {
			return
		}
		if uv, found := jsonutil.obj_get(td, "uri"); found {
			req.uri = jsonutil.value_str(uv)
		}
		if req.uri == "" {
			return
		}
	}

	switch kind {
	case .Formatting:
		if opts, found := jsonutil.obj_get(params, "options"); found {
			if v := jsonutil.obj_get_int(opts, "tabSize"); v > 0 {
				req.tab_size = int(v)
			}
			if _, present := jsonutil.obj_get(opts, "insertSpaces"); present {
				req.insert_spaces = jsonutil.obj_get_bool(opts, "insertSpaces")
			}
		}
		ok = true
	case .Code_Actions, .Inlay_Hints:
		ok = ops_read_range(params, &req)
	case .Prepare_Call_Hierarchy:
		ok = ops_read_flat_position(params, "position", &req)
	case .Call_Edges:
		item, have := jsonutil.obj_get(params, "item")
		if !have {
			return
		}
		if _, is_obj := jsonutil.as_object(item); !is_obj {
			return
		}
		if uv, found := jsonutil.obj_get(item, "uri"); found {
			req.uri = jsonutil.value_str(uv)
		}
		if req.uri == "" {
			return
		}
		ok = ops_read_range_position(item, "selectionRange", &req)
	}
	return
}

// ops_read_flat_position reads one flat {line, character} member.
ops_read_flat_position :: proc(params: json.Value, member: string, req: ^Ops_Request) -> bool {
	pos, have := jsonutil.obj_get(params, member)
	if !have {
		return false
	}
	req.start_line = int(jsonutil.obj_get_int(pos, "line"))
	req.start_col = int(jsonutil.obj_get_int(pos, "character"))
	return true
}

// ops_read_range_position reads one Range-shaped member's start point (the
// echoed CallHierarchyItem's selectionRange).
ops_read_range_position :: proc(v: json.Value, member: string, req: ^Ops_Request) -> bool {
	rng, have := jsonutil.obj_get(v, member)
	if !have {
		return false
	}
	start, sok := jsonutil.obj_get(rng, "start")
	if !sok {
		return false
	}
	req.start_line = int(jsonutil.obj_get_int(start, "line"))
	req.start_col = int(jsonutil.obj_get_int(start, "character"))
	return true
}

// ops_read_range reads the request's range member (code actions, inlay
// hints).
ops_read_range :: proc(params: json.Value, req: ^Ops_Request) -> bool {
	rng, have := jsonutil.obj_get(params, "range")
	if !have {
		return false
	}
	start, sok := jsonutil.obj_get(rng, "start")
	end, eok := jsonutil.obj_get(rng, "end")
	if !sok || !eok {
		return false
	}
	req.start_line = int(jsonutil.obj_get_int(start, "line"))
	req.start_col = int(jsonutil.obj_get_int(start, "character"))
	req.end_line = int(jsonutil.obj_get_int(end, "line"))
	req.end_col = int(jsonutil.obj_get_int(end, "character"))
	return true
}

// ops_request_doc_text serves the requested document's text — the open
// view's snapshot when tracked, the host's fetch otherwise — and seeds the
// per-request cache with it. The view is the conversion truth for an open
// document, so it is consulted before the fetch even though the session's
// fetch prefers it too.
ops_request_doc_text :: proc(s: ^Server, uri: string, texts: ^map[string]string, a: mem.Allocator) -> (string, bool) {
	if snap, have := server_snapshot_doc(s, uri, a); have {
		texts^[strings.clone(uri, a)] = snap.text
		return snap.text, true
	}
	return relay_text_cached(s, uri, texts, a)
}

// ---------------------------------------------------------------------------
// Wire rendering
// ---------------------------------------------------------------------------

ops_render :: proc(s: ^Server, kind: Ops_Kind, req: Ops_Request, dtos: json.Value, texts: ^map[string]string, starts: ^map[string][]int, a: mem.Allocator) -> json.Value {
	switch kind {
	case .Formatting:
		return ops_render_formatting(s, req, dtos, texts, starts, a)
	case .Code_Actions:
		return ops_render_code_actions(s, req, dtos, texts, starts, a)
	case .Inlay_Hints:
		return ops_render_inlay_hints(s, req, dtos, texts, starts, a)
	case .Prepare_Call_Hierarchy:
		return ops_render_call_items(s, req, dtos, texts, starts, a, true)
	case .Call_Edges:
		return ops_render_call_items(s, req, dtos, texts, starts, a, false)
	}
	return nil
}

// ops_flat_bounds reads one flattened range block (start_line/start_col/
// end_line/end_col) — the DTO shape the host answers carry.
ops_flat_bounds :: proc(v: json.Value) -> (sl, sc, el, ec: int) {
	sl = int(jsonutil.obj_get_int(v, "start_line"))
	sc = int(jsonutil.obj_get_int(v, "start_col"))
	el = int(jsonutil.obj_get_int(v, "end_line"))
	ec = int(jsonutil.obj_get_int(v, "end_col"))
	return
}

// ops_flat_range reads one named member's flattened range block (-1s when
// the member is absent).
ops_flat_range :: proc(dto: json.Value, member: string) -> (sl, sc, el, ec: int) {
	rng, ok := jsonutil.obj_get(dto, member)
	if !ok {
		return -1, -1, -1, -1
	}
	return ops_flat_bounds(rng)
}

// ops_range_json renders one wire Range (the raw object map, the shape
// obj_set_object embeds).
ops_range_json :: proc(sl, sc, el, ec: int, a: mem.Allocator) -> map[string]json.Value {
	start := jsonutil.json_object(2, a)
	jsonutil.obj_set(&start, "line", jsonutil.json_int(i64(sl)))
	jsonutil.obj_set(&start, "character", jsonutil.json_int(i64(sc)))
	end := jsonutil.json_object(2, a)
	jsonutil.obj_set(&end, "line", jsonutil.json_int(i64(el)))
	jsonutil.obj_set(&end, "character", jsonutil.json_int(i64(ec)))
	rng := jsonutil.json_object(2, a)
	jsonutil.obj_set_object(&rng, "start", start)
	jsonutil.obj_set_object(&rng, "end", end)
	return rng
}

// ops_member_str reads one string member ("" when absent or not a string).
ops_member_str :: proc(v: json.Value, key: string) -> string {
	if m, ok := jsonutil.obj_get(v, key); ok {
		return jsonutil.value_str(m)
	}
	return ""
}

// ops_render_formatting renders the text-edit DTOs as TextEdit[] in the
// requested document's encoding. Every edit shares the requested
// document's text and line index, which the request path already cached.
ops_render_formatting :: proc(s: ^Server, req: Ops_Request, dtos: json.Value, texts: ^map[string]string, starts: ^map[string][]int, a: mem.Allocator) -> json.Value {
	items, is_arr := jsonutil.as_array(dtos)
	if !is_arr {
		return nil
	}
	out := make([dynamic]json.Value, 0, len(items), a)
	dropped := false
	for dto in items {
		if _, is_obj := jsonutil.as_object(dto); !is_obj {
			continue
		}
		sl, sc, el, ec := ops_flat_bounds(dto)
		if s.encoding == .Utf8 {
			text, lines, served := relay_line_index(s, req.uri, texts, starts, a)
			if !served {
				if !dropped {
					log_message(s, fmt.aprintf("the formatted document's text is unavailable for %s; its edits were dropped", req.uri, allocator = a))
					dropped = true
				}
				continue
			}
			sc = relay_target_byte_col(text, lines, sl, sc)
			ec = relay_target_byte_col(text, lines, el, ec)
		}
		item := jsonutil.json_object(2, a)
		jsonutil.obj_set_object(&item, "range", ops_range_json(sl, sc, el, ec, a))
		jsonutil.obj_set(&item, "newText", jsonutil.json_string(ops_member_str(dto, "new_text")))
		append(&out, json.Value(json.Object(item)))
	}
	return jsonutil.json_array(out[:], a)
}

// ops_render_edit_changes renders one action DTO's edit — the changes map
// keyed by client uris — as the wire WorkspaceEdit. Each file's edit
// columns convert through that file's own text; a file whose text cannot
// be served drops its entry (logged once per request), and an edit left
// without entries drops entirely.
ops_render_edit_changes :: proc(s: ^Server, edit_v: json.Value, texts: ^map[string]string, starts: ^map[string][]int, dropped: ^bool, a: mem.Allocator) -> map[string]json.Value {
	changes_v, ok := jsonutil.obj_get(edit_v, "changes")
	if !ok {
		return nil
	}
	changes_obj, is_obj := jsonutil.as_object(changes_v)
	if !is_obj {
		return nil
	}
	wire_changes := jsonutil.json_object(len(changes_obj), a)
	added := 0
	for uri, edits_v in changes_obj {
		file := uri
		text := ""
		lines: []int
		served := true
		if s.encoding == .Utf8 {
			text, lines, served = relay_line_index(s, file, texts, starts, a)
		}
		if !served {
			if !dropped^ {
				log_message(s, fmt.aprintf("the edited document's text is unavailable for %s; its edits were dropped", file, allocator = a))
				dropped^ = true
			}
			continue
		}
		edits, edits_arr := jsonutil.as_array(edits_v)
		if !edits_arr {
			continue
		}
		wire_edits := make([dynamic]json.Value, 0, len(edits), a)
		for e in edits {
			sl, sc, el, ec := ops_flat_bounds(e)
			if s.encoding == .Utf8 {
				sc = relay_target_byte_col(text, lines, sl, sc)
				ec = relay_target_byte_col(text, lines, el, ec)
			}
			edit := jsonutil.json_object(2, a)
			jsonutil.obj_set_object(&edit, "range", ops_range_json(sl, sc, el, ec, a))
			jsonutil.obj_set(&edit, "newText", jsonutil.json_string(ops_member_str(e, "new_text")))
			append(&wire_edits, json.Value(json.Object(edit)))
		}
		jsonutil.obj_set(&wire_changes, file, jsonutil.json_array(wire_edits[:], a))
		added += 1
	}
	if added == 0 {
		return nil
	}
	wire := jsonutil.json_object(1, a)
	jsonutil.obj_set(&wire, "changes", json.Value(json.Object(wire_changes)))
	return wire
}

// ops_render_code_actions renders the action DTOs as CodeAction[]: the
// changes map's keys are already client uris (the host re-spelled them).
// A file whose text cannot be served drops its entry — the action and its
// other files survive.
ops_render_code_actions :: proc(s: ^Server, req: Ops_Request, dtos: json.Value, texts: ^map[string]string, starts: ^map[string][]int, a: mem.Allocator) -> json.Value {
	_ = req
	items, is_arr := jsonutil.as_array(dtos)
	if !is_arr {
		return nil
	}
	out := make([dynamic]json.Value, 0, len(items), a)
	dropped := false
	for dto in items {
		if _, is_obj := jsonutil.as_object(dto); !is_obj {
			continue
		}
		wire := jsonutil.json_object(5, a)
		jsonutil.obj_set(&wire, "title", jsonutil.json_string(ops_member_str(dto, "title")))
		if k := ops_member_str(dto, "kind"); k != "" {
			jsonutil.obj_set(&wire, "kind", jsonutil.json_string(k))
		}
		if pv, found := jsonutil.obj_get(dto, "is_preferred"); found {
			if jsonutil.value_bool(pv) {
				jsonutil.obj_set(&wire, "isPreferred", jsonutil.json_bool(true))
			}
		}
		if cmd_v, found := jsonutil.obj_get(dto, "command"); found {
			if _, is_cmd := jsonutil.as_object(cmd_v); is_cmd {
				command := jsonutil.json_object(3, a)
				jsonutil.obj_set(&command, "title", jsonutil.json_string(ops_member_str(cmd_v, "title")))
				jsonutil.obj_set(&command, "command", jsonutil.json_string(ops_member_str(cmd_v, "command")))
				if cmd_obj, cmd_ok := jsonutil.as_object(cmd_v); cmd_ok {
					if args_v, has_args := cmd_obj["arguments"]; has_args {
						jsonutil.obj_set(&command, "arguments", args_v)
					}
				}
				jsonutil.obj_set_object(&wire, "command", command)
			}
		}
		if edit_v, found := jsonutil.obj_get(dto, "edit"); found {
			if edit := ops_render_edit_changes(s, edit_v, texts, starts, &dropped, a); edit != nil {
				jsonutil.obj_set_object(&wire, "edit", edit)
			}
		}
		append(&out, json.Value(json.Object(wire)))
	}
	return jsonutil.json_array(out[:], a)
}

// ops_inlay_kind_int maps the DTO's kind name onto the wire InlayHintKind
// value: the names table's index IS the wire value ("" / "type" /
// "parameter" → 1 / 2). An unknown or absent name is omitted by the
// caller — the member is optional.
ops_inlay_kind_int :: proc(name: string) -> (i32, bool) {
	if name == "" {
		return 0, false
	}
	names := lsp.INLAY_HINT_KIND_NAMES
	for n, i in names {
		if n == name {
			return i32(i), true
		}
	}
	return 0, false
}

// ops_render_inlay_hints renders the hint DTOs as InlayHint[] in the
// requested document's encoding. The label stays a plain string (the DTO's
// flattened form); a hint whose position cannot convert drops.
ops_render_inlay_hints :: proc(s: ^Server, req: Ops_Request, dtos: json.Value, texts: ^map[string]string, starts: ^map[string][]int, a: mem.Allocator) -> json.Value {
	items, is_arr := jsonutil.as_array(dtos)
	if !is_arr {
		return nil
	}
	out := make([dynamic]json.Value, 0, len(items), a)
	dropped := false
	for dto in items {
		if _, is_obj := jsonutil.as_object(dto); !is_obj {
			continue
		}
		pos_v, has_pos := jsonutil.obj_get(dto, "position")
		if !has_pos {
			continue
		}
		line := int(jsonutil.obj_get_int(pos_v, "line"))
		col := int(jsonutil.obj_get_int(pos_v, "column"))
		if s.encoding == .Utf8 {
			text, lines, served := relay_line_index(s, req.uri, texts, starts, a)
			if !served {
				if !dropped {
					log_message(s, fmt.aprintf("the hinted document's text is unavailable for %s; its hints were dropped", req.uri, allocator = a))
					dropped = true
				}
				continue
			}
			col = relay_target_byte_col(text, lines, line, col)
		}
		wire := jsonutil.json_object(3, a)
		pos := jsonutil.json_object(2, a)
		jsonutil.obj_set(&pos, "line", jsonutil.json_int(i64(line)))
		jsonutil.obj_set(&pos, "character", jsonutil.json_int(i64(col)))
		jsonutil.obj_set_object(&wire, "position", pos)
		jsonutil.obj_set(&wire, "label", jsonutil.json_string(ops_member_str(dto, "label")))
		if kv, found := jsonutil.obj_get(dto, "kind"); found {
			if kind, known := ops_inlay_kind_int(jsonutil.value_str(kv)); known {
				jsonutil.obj_set(&wire, "kind", jsonutil.json_int(i64(kind)))
			}
		}
		if tip := ops_member_str(dto, "tooltip"); tip != "" {
			jsonutil.obj_set(&wire, "tooltip", jsonutil.json_string(tip))
		}
		if pv, found := jsonutil.obj_get(dto, "padding_left"); found {
			if jsonutil.value_bool(pv) {
				jsonutil.obj_set(&wire, "paddingLeft", jsonutil.json_bool(true))
			}
		}
		if pv, found := jsonutil.obj_get(dto, "padding_right"); found {
			if jsonutil.value_bool(pv) {
				jsonutil.obj_set(&wire, "paddingRight", jsonutil.json_bool(true))
			}
		}
		append(&out, json.Value(json.Object(wire)))
	}
	return jsonutil.json_array(out[:], a)
}

// ops_render_call_items renders the unified call-item DTOs: prepare's hits
// as CallHierarchyItem[], the edges as CallHierarchyIncomingCall[]
// ({from, fromRanges}) or CallHierarchyOutgoingCall[] ({to, fromRanges}).
// Each item's own ranges convert through its own file's text (a per-item
// drop when unservable, logged once per request); the fromRanges convert
// through the caller's document — the `from` item's file for incoming
// calls, the prepared document for outgoing calls.
ops_render_call_items :: proc(s: ^Server, req: Ops_Request, dtos: json.Value, texts: ^map[string]string, starts: ^map[string][]int, a: mem.Allocator, prepare: bool) -> json.Value {
	items, is_arr := jsonutil.as_array(dtos)
	if !is_arr {
		return nil
	}
	out := make([dynamic]json.Value, 0, len(items), a)
	dropped := false
	for dto in items {
		if _, is_obj := jsonutil.as_object(dto); !is_obj {
			continue
		}
		uri := ops_member_str(dto, "uri")
		item_text := ""
		item_lines: []int
		served := true
		if s.encoding == .Utf8 {
			text, lines, ok := relay_line_index(s, uri, texts, starts, a)
			if !ok {
				served = false
			} else {
				item_text = text
				item_lines = lines
			}
		}
		if !served {
			if !dropped {
				log_message(s, fmt.aprintf("the call item's document text is unavailable for %s; the item was dropped", uri, allocator = a))
				dropped = true
			}
			continue
		}

		sl, sc, el, ec := ops_flat_range(dto, "range")
		sel_sl, sel_sc, sel_el, sel_ec := ops_flat_range(dto, "selection_range")
		if s.encoding == .Utf8 {
			sc = relay_target_byte_col(item_text, item_lines, sl, sc)
			ec = relay_target_byte_col(item_text, item_lines, el, ec)
			sel_sc = relay_target_byte_col(item_text, item_lines, sel_sl, sel_sc)
			sel_ec = relay_target_byte_col(item_text, item_lines, sel_el, sel_ec)
		}

		call_item := jsonutil.json_object(5, a)
		jsonutil.obj_set(&call_item, "name", jsonutil.json_string(ops_member_str(dto, "name")))
		jsonutil.obj_set(&call_item, "kind", jsonutil.json_int(jsonutil.obj_get_int(dto, "kind")))
		jsonutil.obj_set(&call_item, "uri", jsonutil.json_string(uri))
		jsonutil.obj_set_object(&call_item, "range", ops_range_json(sl, sc, el, ec, a))
		jsonutil.obj_set_object(&call_item, "selectionRange", ops_range_json(sel_sl, sel_sc, sel_el, sel_ec, a))

		wire := call_item
		if !prepare {
			// The edges' ranges sit in the caller's document (see the
			// package comment); the item's own uri carried it here for
			// incoming, the prepared document for outgoing.
			source_uri := uri
			if !req.incoming {
				source_uri = req.uri
			}
			source_text := item_text
			source_lines := item_lines
			served = true
			if s.encoding == .Utf8 {
				source_text, source_lines, served = relay_line_index(s, source_uri, texts, starts, a)
			}
			if !served {
				if !dropped {
					log_message(s, fmt.aprintf("the call item's document text is unavailable for %s; the item was dropped", source_uri, allocator = a))
					dropped = true
				}
				continue
			}
			from_ranges := make([dynamic]json.Value, 0, 4, a)
			if fr_v, found := jsonutil.obj_get(dto, "from_ranges"); found {
				if fr, ok := jsonutil.as_array(fr_v); ok {
					for r in fr {
						rl, rc, rel2, re2 := ops_flat_bounds(r)
						if s.encoding == .Utf8 {
							rc = relay_target_byte_col(source_text, source_lines, rl, rc)
							re2 = relay_target_byte_col(source_text, source_lines, rel2, re2)
						}
						append(&from_ranges, json.Value(json.Object(ops_range_json(rl, rc, rel2, re2, a))))
					}
				}
			}
			wire = jsonutil.json_object(2, a)
			key := "to"
			if req.incoming {
				key = "from"
			}
			jsonutil.obj_set_object(&wire, key, call_item)
			jsonutil.obj_set(&wire, "fromRanges", jsonutil.json_array(from_ranges[:], a))
		}
		append(&out, json.Value(json.Object(wire)))
	}
	return jsonutil.json_array(out[:], a)
}
