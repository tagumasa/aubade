// The documentSymbol host: one svc.symbol/list round trip per face
// request, returning the daemon answer's raw {symbols: [...]} object for
// the face to walk and render. The face owns the LSP shape and the column
// conversion; this host owns only the daemon link. ok=false (path outside
// the root, link down, failed call) sends the face to its empty-answer
// degradation — the face logs the one line, so this host stays silent.
package session

import "core:encoding/json"
import "core:mem"

import "src:platform"
import "src:svc"

host_lsp_outline :: proc(host: rawptr, uri: string, arena: mem.Allocator) -> (outline: json.Value, ok: bool) {
	h := cast(^Lsp_Host)host
	rel := lsp_rel_path(h, uri)
	if rel == "" {
		return json.Value{}, false // outside the project root; lsp_rel_path logged
	}
	conn := lsp_parent_conn(h)
	if conn == nil {
		return json.Value{}, false // the daemon link is down
	}
	guard := lsp_call_begin(h)
	cc := svc.client_symbol_list(conn, rel, arena, platform.mono_ms() + LSP_RELAY_CALL_DEADLINE_MS, guard.token)
	lsp_call_end(h, guard)
	if cc.call_err != .None {
		return json.Value{}, false
	}
	return cc.result, true
}
