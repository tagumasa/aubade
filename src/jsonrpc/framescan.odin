// Structural sanity for inbound JSON frames: the single-pass scan lives
// in util (shared with the config/hooks/tracker consumers of untrusted
// JSON); this name keeps the jsonrpc-facing spelling the wire faces and
// their tests were written against.
package jsonrpc

import "src:util"

MAX_JSON_DEPTH :: util.MAX_JSON_DEPTH

frame_sanity_ok :: proc(body: []u8) -> bool {
	return util.json_sanity_ok(body)
}
