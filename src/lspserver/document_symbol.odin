// The textDocument/documentSymbol face: one document's outline served from
// the daemon's symbol inventory through Outline_Host (svc.symbol/list's
// {symbols: [...]} answer, columns UTF-16 end to end). Static capability —
// advertised at initialize, answered on every connection. The reply shape
// follows the client's initialize declaration: hierarchical DocumentSymbol[]
// when it declared textDocument.documentSymbol.hierarchicalDocumentSymbol-
// Support, flat SymbolInformation[] otherwise (absent bit = flat; the two
// forms are never mixed).
//
// Degradation follows the relay rule: a host that failed, an answer without
// a symbol list, or — under a utf-8 connection — a requested document whose
// text cannot be served all answer an EMPTY array with at most one log
// line, never an error response, and never a UTF-16 number in a byte
// column. Nodes without a usable range drop whole (their subtree with
// them): documentSymbol requires range and selectionRange, so a tree with
// holes is worse than none.
package lspserver

import "core:encoding/json"
import "core:fmt"
import "core:mem"

import "src:jsonrpc"
import "src:jsonutil"
import "src:util"

handle_document_symbol :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	s := server_from_conn(conn)
	reply, action, gated := request_gate_reply(s, conn, env, arena)
	if gated {
		return reply, action
	}

	uri := ""
	if td, ok := jsonutil.obj_get(env.params, "textDocument"); ok {
		if u, found := jsonutil.obj_get(td, "uri"); found {
			uri = jsonutil.value_str(u)
		}
	}
	if uri == "" {
		reply = {is_error = true, err_code = .Invalid_Params, err_message = "textDocument.uri is required"}
		return reply, .Respond
	}
	return document_symbol_reply(s, uri, arena)
}

// document_symbol_reply renders one document's outline in the negotiated
// encoding and shape. There is no open-document gate: the daemon serves the
// indexed state for any project file, open or not.
document_symbol_reply :: proc(s: ^Server, uri: string, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	if s.outline == nil {
		return relay_reply(nil, arena)
	}
	outline, ok := s.outline(s.host, uri, arena)
	if !ok {
		log_message(s, fmt.aprintf("document symbols unavailable for %s; answering empty", uri, allocator = arena))
		return relay_reply(nil, arena)
	}
	symbols_v, have := jsonutil.obj_get(outline, "symbols")
	roots: []json.Value
	if have {
		roots, _ = jsonutil.as_array(symbols_v)
	}
	if roots == nil {
		log_message(s, fmt.aprintf("the document symbols answer for %s carried no symbol list; answering empty", uri, allocator = arena))
		return relay_reply(nil, arena)
	}

	// The requested document is the conversion truth: under a utf-8
	// connection every answer column converts through its line bytes. The
	// view snapshot wins when the document is open, the host's fetch
	// otherwise. The line index is built once per request, not per node.
	conv: Ds_Position_Conv
	if s.encoding == .Utf8 {
		text: string
		served := false
		if snap, have_snap := server_snapshot_doc(s, uri, arena); have_snap {
			text, served = snap.text, true
		} else if s.text_for_uri != nil {
			text, served = s.text_for_uri(s.host, uri, arena)
		}
		if !served {
			log_message(s, fmt.aprintf("the text of %s cannot be served in the connection's encoding; answering empty document symbols", uri, allocator = arena))
			return relay_reply(nil, arena)
		}
		conv.active = true
		conv.text = text
		conv.starts = util.line_start_offsets(text, arena)
	}

	items := make([dynamic]json.Value, 0, len(roots), arena)
	if s.can_hierarchical_symbols {
		for node in roots {
			if item, rendered := ds_document_symbol_json(node, &conv, arena); rendered {
				append(&items, item)
			}
		}
	} else {
		ds_symbols_flat(roots, uri, &conv, &items, arena)
	}
	return relay_reply(jsonutil.json_array(items[:], arena), arena)
}

// Ds_Position_Conv carries the requested document's conversion truth for a
// utf-8 connection; under utf-16 it is inert and columns pass through.
Ds_Position_Conv :: struct {
	active: bool,
	text:   string,
	starts: []int,
}

// ds_col converts one answer column into the connection's unit: the UTF-16
// column through the target line's bytes under utf-8, unchanged under
// utf-16. Lines past the document clamp to the last line, columns past the
// line's end clamp inside the converter — never a UTF-16 number in a byte
// column.
ds_col :: proc(c: ^Ds_Position_Conv, line, col_utf16: int) -> int {
	if !c.active {
		return col_utf16
	}
	if len(c.starts) == 0 {
		return 0
	}
	return util.utf16_col_to_byte_offset(relay_line_text(c.text, c.starts, relay_clamped_line(c.starts, line)), col_utf16)
}

// ds_range_json renders one svc range object ({start,end:{line,character}})
// as an LSP Range object (still unwrapped — the callers embed it with
// obj_set_object). false means the value is not the expected shape — the
// caller drops the node that carried it.
ds_range_json :: proc(rng: json.Value, c: ^Ds_Position_Conv, a: mem.Allocator) -> (obj: map[string]json.Value, ok: bool) {
	start, have_start := jsonutil.obj_get(rng, "start")
	if !have_start {
		return nil, false
	}
	end, have_end := jsonutil.obj_get(rng, "end")
	if !have_end {
		return nil, false
	}
	sl := int(jsonutil.obj_get_int(start, "line"))
	sc := int(jsonutil.obj_get_int(start, "character"))
	el := int(jsonutil.obj_get_int(end, "line"))
	ec := int(jsonutil.obj_get_int(end, "character"))

	s_obj := jsonutil.json_object(2, a)
	jsonutil.obj_set(&s_obj, "line", jsonutil.json_int(i64(sl)))
	jsonutil.obj_set(&s_obj, "character", jsonutil.json_int(i64(ds_col(c, sl, sc))))
	e_obj := jsonutil.json_object(2, a)
	jsonutil.obj_set(&e_obj, "line", jsonutil.json_int(i64(el)))
	jsonutil.obj_set(&e_obj, "character", jsonutil.json_int(i64(ds_col(c, el, ec))))
	obj = jsonutil.json_object(2, a)
	jsonutil.obj_set_object(&obj, "start", s_obj)
	jsonutil.obj_set_object(&obj, "end", e_obj)
	return obj, true
}

// ds_document_symbol_json renders one outline node as a DocumentSymbol
// (children nested). A node with no selection_range uses its range as the
// selectionRange; children survive only when at least one rendered.
ds_document_symbol_json :: proc(node: json.Value, c: ^Ds_Position_Conv, a: mem.Allocator) -> (json.Value, bool) {
	m, is_obj := jsonutil.as_object(node)
	if !is_obj {
		return nil, false
	}
	rng_v, has_range := m["range"]
	if !has_range {
		return nil, false
	}
	rng, rng_ok := ds_range_json(rng_v, c, a)
	if !rng_ok {
		return nil, false
	}

	name := ""
	if nv, found := m["name"]; found {
		name = jsonutil.value_str(nv)
	}
	kind := i64(0)
	if kv, found := m["kind"]; found {
		kind = jsonutil.value_int(kv)
	}

	item := jsonutil.json_object(6, a)
	jsonutil.obj_set(&item, "name", jsonutil.json_string(name))
	if dv, found := m["detail"]; found {
		if d := jsonutil.value_str(dv); d != "" {
			jsonutil.obj_set(&item, "detail", jsonutil.json_string(d))
		}
	}
	jsonutil.obj_set(&item, "kind", jsonutil.json_int(kind))
	jsonutil.obj_set_object(&item, "range", rng)
	if sel_v, has_sel := m["selection_range"]; has_sel {
		if sel, sel_ok := ds_range_json(sel_v, c, a); sel_ok {
			jsonutil.obj_set_object(&item, "selectionRange", sel)
		} else {
			jsonutil.obj_set_object(&item, "selectionRange", rng)
		}
	} else {
		jsonutil.obj_set_object(&item, "selectionRange", rng)
	}
	if kids_v, found := m["children"]; found {
		if kids, is_arr := jsonutil.as_array(kids_v); is_arr {
			child_items := make([dynamic]json.Value, 0, len(kids), a)
			for kid in kids {
				if ci, cok := ds_document_symbol_json(kid, c, a); cok {
					append(&child_items, ci)
				}
			}
			if len(child_items) > 0 {
				jsonutil.obj_set(&item, "children", jsonutil.json_array(child_items[:], a))
			}
		}
	}
	return json.Value(json.Object(item)), true
}

// ds_symbols_flat walks the outline pre-order into SymbolInformation items —
// the flat form carries no tree, so children flatten after their parent. A
// node without a usable range drops with its subtree (the same rule the
// hierarchical form applies). Flat items carry the requested uri verbatim
// (the client's spelling).
ds_symbols_flat :: proc(nodes: []json.Value, uri: string, c: ^Ds_Position_Conv, items: ^[dynamic]json.Value, a: mem.Allocator) {
	for node in nodes {
		item, rendered := ds_symbol_information_json(node, uri, c, a)
		if !rendered {
			continue
		}
		append(items, item)
		if kids_v, found := jsonutil.obj_get(node, "children"); found {
			if kids, is_arr := jsonutil.as_array(kids_v); is_arr {
				ds_symbols_flat(kids, uri, c, items, a)
			}
		}
	}
}

// ds_symbol_information_json renders one outline node as a flat
// SymbolInformation over its full range.
ds_symbol_information_json :: proc(node: json.Value, uri: string, c: ^Ds_Position_Conv, a: mem.Allocator) -> (json.Value, bool) {
	rng_v, has_range := jsonutil.obj_get(node, "range")
	if !has_range {
		return nil, false
	}
	rng, rng_ok := ds_range_json(rng_v, c, a)
	if !rng_ok {
		return nil, false
	}
	name := ""
	if nv, found := jsonutil.obj_get(node, "name"); found {
		name = jsonutil.value_str(nv)
	}

	loc := jsonutil.json_object(2, a)
	jsonutil.obj_set(&loc, "uri", jsonutil.json_string(uri))
	jsonutil.obj_set_object(&loc, "range", rng)
	item := jsonutil.json_object(3, a)
	jsonutil.obj_set(&item, "name", jsonutil.json_string(name))
	jsonutil.obj_set(&item, "kind", jsonutil.json_int(jsonutil.obj_get_int(node, "kind")))
	jsonutil.obj_set_object(&item, "location", loc)
	return json.Value(json.Object(item)), true
}
