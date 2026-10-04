// The Ops_Host implementation: one langserver relay operation against the
// daemon's existing svc faces. The daemon round trip, the rel-path
// resolution, and the client-uri spelling live here; the wire shapes and
// the column conversions stay on the face side (lspserver's ops relay).
// Failures answer failed=true with the wire's message — the face turns
// them into empty answers plus one log line, never error responses.
package session

import "core:encoding/json"
import "core:mem"

import "src:jsonrpc"
import "src:jsonutil"
import "src:lsp"
import "src:lspserver"
import "src:platform"
import "src:svc"
import "src:symbol"

// The langserver ops leg's budget (format, code actions, inlay hints, call
// hierarchy). A real LS's first answer on a cold project can spend several
// package loads on top of the handshake the start face already paid, so
// this sits above the doc face's 15s — still far under the start
// handshake's 50s.
LSP_OPS_CALL_DEADLINE_MS :: i64(20_000)

host_lsp_ops :: proc(host: rawptr, req: lspserver.Ops_Request, arena: mem.Allocator) -> lspserver.Ops_Result {
	r: lspserver.Ops_Result
	h := cast(^Lsp_Host)host
	rel := lsp_rel_path(h, req.uri)
	if rel == "" {
		return r // outside the project root; lsp_rel_path logged
	}
	conn := lsp_parent_conn(h)
	if conn == nil {
		r.failed = true
		r.err_message = "the daemon link is down"
		return r
	}
	// The open-view set resolves once per operation: every answer document
	// below spells through the same snapshot (lsp_relay_client_uri),
	// however many items the answer carries.
	views := relay_uri_table_build(h, arena)
	switch req.kind {
	case .Formatting:
		ops_host_format(h, conn, rel, req, arena, &r)
	case .Code_Actions:
		ops_host_code_actions(h, conn, rel, views, req, arena, &r)
	case .Inlay_Hints:
		ops_host_inlay_hints(h, conn, rel, req, arena, &r)
	case .Prepare_Call_Hierarchy:
		ops_host_prepare(h, conn, rel, views, req, arena, &r)
	case .Call_Edges:
		ops_host_edges(h, conn, rel, views, req, arena, &r)
	}
	return r
}

// ops_host_format runs svc.langserver/format; the text-edit DTO array
// passes through verbatim (the face owns its wire rendering).
ops_host_format :: proc(h: ^Lsp_Host, conn: ^jsonrpc.Conn, rel: string, req: lspserver.Ops_Request, arena: mem.Allocator, r: ^lspserver.Ops_Result) {
	guard := lsp_call_begin(h)
	cc := svc.client_langserver_format(
		conn, rel, req.tab_size, req.insert_spaces,
		arena, platform.mono_ms() + LSP_OPS_CALL_DEADLINE_MS, guard.token,
	)
	lsp_call_end(h, guard)
	ops_host_items(cc, r)
}

// ops_host_code_actions runs svc.langserver/code_actions and re-spells the
// answer's edit changes keys — the svc face keys them by rel path, the
// editor's uri spelling lives here. A key that escapes the root drops its
// entry; an edit left without entries drops.
ops_host_code_actions :: proc(h: ^Lsp_Host, conn: ^jsonrpc.Conn, rel: string, views: Relay_Uri_Table, req: lspserver.Ops_Request, arena: mem.Allocator, r: ^lspserver.Ops_Result) {
	guard := lsp_call_begin(h)
	cc := svc.client_langserver_code_actions(
		conn, rel, req.start_line, req.start_col, req.end_line, req.end_col,
		arena, platform.mono_ms() + LSP_OPS_CALL_DEADLINE_MS, guard.token,
	)
	lsp_call_end(h, guard)
	if !ops_host_items(cc, r) {
		return
	}
	items, is_arr := jsonutil.as_array(r.items)
	if !is_arr {
		return
	}
	for item in items {
		obj, is_obj := jsonutil.as_object(item)
		if !is_obj {
			continue
		}
		if edit_v, has_edit := obj["edit"]; has_edit {
			if edit, built := ops_host_respell_edit(h, views, edit_v, arena); built {
				obj["edit"] = edit
			} else {
				delete_key(&obj, "edit")
			}
		}
	}
}

// ops_host_respell_edit re-spells one edit DTO's changes keys from rel
// paths into the client's uri spelling; a key that escapes the root drops,
// and an edit with no surviving keys drops entirely.
ops_host_respell_edit :: proc(h: ^Lsp_Host, views: Relay_Uri_Table, edit_v: json.Value, arena: mem.Allocator) -> (json.Value, bool) {
	changes_v, ok := jsonutil.obj_get(edit_v, "changes")
	if !ok {
		return nil, false
	}
	changes_obj, is_obj := jsonutil.as_object(changes_v)
	if !is_obj {
		return nil, false
	}
	changes := jsonutil.json_object(len(changes_obj), arena)
	added := 0
	for rel, edits_v in changes_obj {
		uri := lsp_relay_client_uri(h, views, rel, arena)
		if uri == "" {
			continue
		}
		jsonutil.obj_set(&changes, uri, edits_v)
		added += 1
	}
	if added == 0 {
		return nil, false
	}
	out := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&out, "changes", json.Value(json.Object(changes)))
	return json.Value(json.Object(out)), true
}

// ops_host_inlay_hints runs svc.langserver/inlay_hints; the hint DTO array
// passes through verbatim.
ops_host_inlay_hints :: proc(h: ^Lsp_Host, conn: ^jsonrpc.Conn, rel: string, req: lspserver.Ops_Request, arena: mem.Allocator, r: ^lspserver.Ops_Result) {
	guard := lsp_call_begin(h)
	cc := svc.client_langserver_inlay_hints(
		conn, rel, req.start_line, req.start_col, req.end_line, req.end_col,
		arena, platform.mono_ms() + LSP_OPS_CALL_DEADLINE_MS, guard.token,
	)
	lsp_call_end(h, guard)
	ops_host_items(cc, r)
}

// ops_host_prepare synthesizes textDocument/prepareCallHierarchy from the
// symbol inventory: svc.symbol/list for the document (one round trip),
// then the shared outline ladder (relay_pick_hit: deepest containing
// selectionRange, deepest containing range, then the exact-start
// candidates). The hit renders into the unified call-item DTO the face
// expects; a hit without a full range is skipped.
ops_host_prepare :: proc(h: ^Lsp_Host, conn: ^jsonrpc.Conn, rel: string, views: Relay_Uri_Table, req: lspserver.Ops_Request, arena: mem.Allocator, r: ^lspserver.Ops_Result) {
	guard := lsp_call_begin(h)
	cc := svc.client_symbol_list(conn, rel, arena, platform.mono_ms() + LSP_OPS_CALL_DEADLINE_MS, guard.token)
	lsp_call_end(h, guard)
	if cc.call_err != .None {
		r.failed = true
		r.err_message = cc.err_message
		return
	}
	symbols_v, ok := jsonutil.obj_get(cc.result, "symbols")
	if !ok {
		return
	}
	roots, is_arr := jsonutil.as_array(symbols_v)
	if !is_arr {
		return
	}
	walk := Relay_Walk{arena = arena, line = req.start_line, col = req.start_col}
	relay_walk(roots, "", &walk)

	hit, _ := relay_pick_hit(&walk)
	if hit == nil {
		return // no symbol at the position: an ordinary empty answer
	}

	sl, sc, el, ec := relay_range_bounds_ops(hit, "range")
	if sl < 0 {
		return
	}
	sel_sl, sel_sc, sel_el, sel_ec := relay_range_bounds_ops(hit, "selection_range")
	if sel_sl < 0 {
		sel_sl, sel_sc, sel_el, sel_ec = sl, sc, el, ec
	}

	node_rel := rel
	if lv, have_loc := jsonutil.obj_get(hit, "location"); have_loc {
		if rp, found := jsonutil.obj_get(lv, "rel_path"); found {
			if s := jsonutil.value_str(rp); s != "" {
				node_rel = s
			}
		}
	}
	uri := lsp_relay_client_uri(h, views, node_rel, arena)
	if uri == "" {
		return
	}

	dto := jsonutil.json_object(5, arena)
	jsonutil.obj_set(&dto, "name", jsonutil.json_string(ops_host_str(hit, "name")))
	jsonutil.obj_set(&dto, "kind", jsonutil.json_int(jsonutil.obj_get_int(hit, "kind")))
	jsonutil.obj_set(&dto, "uri", jsonutil.json_string(uri))
	jsonutil.obj_set_object(&dto, "range", ops_host_flat_range(sl, sc, el, ec, arena))
	jsonutil.obj_set_object(&dto, "selection_range", ops_host_flat_range(sel_sl, sel_sc, sel_el, sel_ec, arena))
	items := make([]json.Value, 1, arena)
	items[0] = json.Value(json.Object(dto))
	r.items = jsonutil.json_array(items, arena)
}

// ops_host_edges runs svc.langserver/call_hierarchy in the request's
// direction and converts the edge DTOs into the unified call-item shape:
// the kind name recovers to its number, the endpoint's rel path re-spells
// to the client uri, and the point positions flatten into range blocks.
// An edge whose endpoint escapes the root drops (no followable uri).
ops_host_edges :: proc(h: ^Lsp_Host, conn: ^jsonrpc.Conn, rel: string, views: Relay_Uri_Table, req: lspserver.Ops_Request, arena: mem.Allocator, r: ^lspserver.Ops_Result) {
	direction := lsp.Call_Direction.Incoming
	if !req.incoming {
		direction = .Outgoing
	}
	guard := lsp_call_begin(h)
	cc := svc.client_langserver_call_hierarchy(
		conn, rel, req.start_line, req.start_col, lsp.call_direction_string(direction),
		arena, platform.mono_ms() + LSP_OPS_CALL_DEADLINE_MS, guard.token,
	)
	lsp_call_end(h, guard)
	if cc.call_err != .None {
		r.failed = true
		r.err_message = cc.err_message
		return
	}
	items_v, ok := jsonutil.obj_get(cc.result, "items")
	if !ok {
		return
	}
	items, is_arr := jsonutil.as_array(items_v)
	if !is_arr {
		return
	}
	out := make([dynamic]json.Value, 0, len(items), arena)
	for item in items {
		obj, is_obj := jsonutil.as_object(item)
		if !is_obj {
			continue
		}
		rel_of := ""
		if v, found := obj["relative_path"]; found {
			rel_of = jsonutil.value_str(v)
		}
		uri := lsp_relay_client_uri(h, views, rel_of, arena)
		if uri == "" {
			continue
		}
		line := int(jsonutil.obj_get_int(item, "line"))
		col := int(jsonutil.obj_get_int(item, "col"))
		sel_line := int(jsonutil.obj_get_int(item, "selection_line"))
		sel_col := int(jsonutil.obj_get_int(item, "selection_col"))

		dto := jsonutil.json_object(7, arena)
		jsonutil.obj_set(&dto, "name", jsonutil.json_string(ops_host_str(item, "name")))
		jsonutil.obj_set(&dto, "kind", jsonutil.json_int(i64(symbol.kind_from_name(ops_host_str(item, "kind")))))
		jsonutil.obj_set(&dto, "uri", jsonutil.json_string(uri))
		jsonutil.obj_set_object(&dto, "range", ops_host_flat_range(line, col, line, col, arena))
		jsonutil.obj_set_object(&dto, "selection_range", ops_host_flat_range(sel_line, sel_col, sel_line, sel_col, arena))
		if fr_v, found := obj["from_ranges"]; found {
			if _, is_ranges := jsonutil.as_array(fr_v); is_ranges {
				jsonutil.obj_set(&dto, "from_ranges", fr_v)
			}
		}
		append(&out, json.Value(json.Object(dto)))
	}
	r.items = jsonutil.json_array(out[:], arena)
}

// ops_host_items extracts the list answer's items array into the result
// (false when the call failed or the answer carried no array — an empty
// result either way).
ops_host_items :: proc(cc: svc.Client_Call, r: ^lspserver.Ops_Result) -> bool {
	if cc.call_err != .None {
		r.failed = true
		r.err_message = cc.err_message
		return false
	}
	items_v, ok := jsonutil.obj_get(cc.result, "items")
	if !ok {
		return false
	}
	if _, is_arr := jsonutil.as_array(items_v); !is_arr {
		return false
	}
	r.items = items_v
	return true
}

// ops_host_str reads a node's string member ("" when absent).
ops_host_str :: proc(node: json.Value, key: string) -> string {
	if v, found := jsonutil.obj_get(node, key); found {
		return jsonutil.value_str(v)
	}
	return ""
}

// relay_range_bounds_ops reads an outline node's Range-shaped member into
// the flattened block (-1 line when the member is absent or misshaped).
relay_range_bounds_ops :: proc(node: json.Value, member: string) -> (sl, sc, el, ec: int) {
	rng, ok := jsonutil.obj_get(node, member)
	if !ok {
		sl = -1
		return
	}
	sl, sc, el, ec = relay_range_bounds(rng)
	return
}

// ops_host_flat_range renders one flattened range block (the raw object
// map, the shape obj_set_object embeds).
ops_host_flat_range :: proc(sl, sc, el, ec: int, arena: mem.Allocator) -> map[string]json.Value {
	rng := jsonutil.json_object(4, arena)
	jsonutil.obj_set(&rng, "start_line", jsonutil.json_int(i64(sl)))
	jsonutil.obj_set(&rng, "start_col", jsonutil.json_int(i64(sc)))
	jsonutil.obj_set(&rng, "end_line", jsonutil.json_int(i64(el)))
	jsonutil.obj_set(&rng, "end_col", jsonutil.json_int(i64(ec)))
	return rng
}
