// Shared helpers for the tool implementations: validated-argument
// accessors, wire-result member accessors, answer shaping (paging
// footers; length limiting and max-chars resolution live in util.text),
// and the svc call outcome mapping.
package tools

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "src:jsonrpc"
import "src:jsonutil"
import "src:platform"
import "src:svc"
import "src:util"

// --- validated argument accessors -----------------------------------------

arg_has :: proc(args: ^Args, key: string) -> bool {
	_, found := args.values[key]
	return found
}

arg_str :: proc(args: ^Args, key: string) -> string {
	if v, ok := args.values[key]; ok {
		return jsonutil.value_str(v)
	}
	return ""
}

arg_bool :: proc(args: ^Args, key: string) -> bool {
	if v, ok := args.values[key]; ok {
		return jsonutil.value_bool(v)
	}
	return false
}

// arg_int reads a validated integer parameter (0 when absent).
arg_int :: proc(args: ^Args, key: string) -> int {
	if v, ok := args.values[key]; ok {
		return int(jsonutil.value_int(v))
	}
	return 0
}

// arg_u32_array reads a validated Int_Array parameter ([] when absent).
arg_u32_array :: proc(args: ^Args, key: string, a: mem.Allocator) -> []u32 {
	v, ok := args.values[key]
	if !ok || v == nil {
		return nil
	}
	items, aok := jsonutil.as_array(v)
	if !aok {
		return nil
	}
	out := make([]u32, len(items), a)
	for i := 0; i < len(items); i += 1 {
		out[i] = u32(jsonutil.value_int(items[i]))
	}
	return out
}

// arg_str_array reads a validated Str_Array parameter onto the arena
// (nil when absent); the parameter kind was already checked by the
// generated validator.
arg_str_array :: proc(args: ^Args, key: string, a: mem.Allocator) -> []string {
	v, ok := args.values[key]
	if !ok {
		return nil
	}
	arr, aok := jsonutil.as_array(v)
	if !aok {
		return nil
	}
	out := make([dynamic]string, 0, len(arr), a)
	for it in arr {
		#partial switch x in it {
		case json.String:
			append(&out, string(x))
		case:
		}
	}
	return out[:]
}

// --- answer shaping ------------------------------------------------------------
// resolve_max_chars / limit_length live in util.text (the single
// implementations); call them as util.resolve_max_chars /
// util.limit_length.

// to_json renders a JSON value deterministically: sorted map keys, and
// no HTML escaping (<, >, & stay literal).
to_json :: proc(v: json.Value, ctx: ^Tool_Ctx) -> string {
	return jsonutil.marshal_value(v, ctx.allocator)
}

// search_footer renders the notes appended under a paged answer: the
// resume line names the next offset whenever more entries remain past
// this page, and the walk-cap warning says the scan itself stopped early
// (its results are incomplete, not merely unpaged). `noun` names the
// paged entries ("matches", "symbols"). Empty when the answer carries
// neither caveat.
search_footer :: proc(offset, returned, total: int, walk_truncated: bool, noun: string, a := context.allocator) -> string {
	out := ""
	if walk_truncated {
		out = "[walk caps hit — the scan stopped early; results are incomplete]"
	}
	if offset+returned < total {
		line := strings.concatenate({
			"[showing ", noun, " ",
			util.int_to_dec(offset+1, a), "-", util.int_to_dec(offset+returned, a),
			" of ", util.int_to_dec(total, a),
			" — pass offset=", util.int_to_dec(offset+returned, a),
			" for the next page]",
		}, a)
		if out != "" {
			out = strings.concatenate({out, "\n", line}, a)
		} else {
			out = line
		}
	}
	if returned == 0 && total > 0 && offset >= total {
		line := strings.concatenate({
			"[no ", noun, " at or past offset ",
			util.int_to_dec(offset, a), " (total ", util.int_to_dec(total, a), ")]",
		}, a)
		if out != "" {
			out = strings.concatenate({out, "\n", line}, a)
		} else {
			out = line
		}
	}
	return out
}

// --- tool result helpers -----------------------------------------------------

// ok_result answers with the fixed success string.
ok_result :: proc(ctx: ^Tool_Ctx) -> Tool_Result {
	result: Tool_Result = {err_kind = .Internal}
	result_init(&result, ctx)
	append(&result.contents, text_content("OK"))
	return result
}

// err_result answers with an error marker and message.
err_result :: proc(ctx: ^Tool_Ctx, msg: string) -> Tool_Result {
	result: Tool_Result = {err_kind = .Internal}
	result_init(&result, ctx, 1)
	result.is_error = true
	append(&result.contents, text_content(msg))
	return result
}

// wire_kind decodes the one typed transient channel the boundary keeps:
// Server_Retryable maps back to .Retryable so the dispatch retry stage
// can judge a failure without string-matching the message. Every other
// boundary code (Invalid_Params, Invalid_Request, ...) arrives as
// .Internal — the boundary types kinds onto codes, but only the
// retryable one round-trips.
wire_kind :: proc(code: jsonrpc.Err_Code) -> platform.Err_Kind {
	if code == .Server_Retryable {
		return .Retryable
	}
	return .Internal
}

// err_result_code answers with the wire error code woven in when the peer
// actually answered with one, so the model can tell an invalid-params
// rejection apart from an internal failure. Local failures (timeout,
// cancel, transport) carry .None and render message-only.
err_result_code :: proc(ctx: ^Tool_Ctx, code: jsonrpc.Err_Code, msg: string) -> Tool_Result {
	text := msg
	if code != .None {
		text = strings.concatenate({"[code ", util.int_to_dec(cast(int)code, ctx.allocator), "] ", msg}, ctx.allocator)
	}
	result := err_result(ctx, text)
	result.err_kind = wire_kind(code)
	return result
}

// text_result answers with plain text content.
text_result :: proc(ctx: ^Tool_Ctx, text: string) -> Tool_Result {
	result: Tool_Result = {err_kind = .Internal}
	result_init(&result, ctx, 1)
	append(&result.contents, text_content(text))
	return result
}

// call_result maps a svc client call onto a tool result: success hands
// the wire result to `render`, wire errors become error results carrying
// the daemon's message.
call_result :: proc(
	ctx: ^Tool_Ctx,
	call: svc.Client_Call,
	render: proc(ctx: ^Tool_Ctx, result: json.Value) -> Tool_Result,
) -> Tool_Result {
	switch call.call_err {
	case .None:
		return render(ctx, call.result)
	case .Error_Response:
		result := err_result(ctx, call.err_message)
		result.err_kind = wire_kind(call.err_code)
		return result
	case .Timeout:
		return err_result(ctx, "svc call timed out")
	case .Cancelled:
		return err_result(ctx, "svc call cancelled")
	case .Closed:
		return err_result(ctx, "svc connection closed")
	case .Transport, .Malformed_Reply:
		return err_result(ctx, "svc call failed")
	}
	return err_result(ctx, "svc call failed")
}

// call_text_result maps a svc call onto the length-limited JSON answer the
// read tools return: a failed call answers with the wire code and message,
// success renders the result JSON with the shortened variants ahead of the
// full form.
call_text_result :: proc(ctx: ^Tool_Ctx, call: svc.Client_Call, max_chars: int, shortened: []string) -> Tool_Result {
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	return text_result(ctx, util.limit_length(to_json(call.result, ctx), max_chars, shortened, ctx.allocator))
}

// call_ok_or_err answers mutating ops: an empty-object reply is the
// reference's "OK".
call_ok_or_err :: proc(ctx: ^Tool_Ctx, call: svc.Client_Call) -> Tool_Result {
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	return ok_result(ctx)
}

// --- wire-result member accessors --------------------------------------------

// json_str / json_bool / json_int read typed members off a wire result.
json_str :: proc(v: json.Value, key: string) -> (string, bool) {
	if f, ok := jsonutil.obj_get(v, key); ok {
		return jsonutil.value_str(f), true
	}
	return "", false
}

json_bool :: proc(v: json.Value, key: string) -> (bool, bool) {
	if f, ok := jsonutil.obj_get(v, key); ok {
		#partial switch x in f {
		case json.Boolean:
			return bool(x), true
		case:
		}
	}
	return false, false
}

json_int :: proc(v: json.Value, key: string) -> (i64, bool) {
	if f, ok := jsonutil.obj_get(v, key); ok {
		#partial switch x in f {
		case json.Integer:
			return i64(x), true
		case:
		}
	}
	return 0, false
}

// call_text extracts the parent's rendered markdown payload.
call_text :: proc(result: json.Value) -> string {
	text, _ := json_str(result, "text")
	return text
}

// counts_by_path_json counts an answer's entries per path for a shortened
// answer: {path: count}. list_key picks the entries array, path_key the
// entry's file field; an entry without the field lands under "unknown".
// The to_json render sorts the file keys — the first-seen paths list only
// keeps the construction deterministic.
counts_by_path_json :: proc(result: json.Value, list_key: string, path_key: string, ctx: ^Tool_Ctx) -> json.Value {
	out := jsonutil.json_object(0, ctx.allocator)
	list_v, ok := jsonutil.obj_get(result, list_key)
	if !ok {
		return json.Value(json.Object(out))
	}
	items, _ := jsonutil.as_array(list_v)
	paths := make([dynamic]string, 0, 8, ctx.allocator)
	counts := make(map[string]int, 8, ctx.allocator)
	for m in items {
		path, _ := json_str(m, path_key)
		if path == "" {
			path = "unknown"
		}
		if _, seen := counts[path]; !seen {
			append(&paths, path)
			counts[path] = 0
		}
		counts[path] += 1
	}
	for p in paths {
		jsonutil.obj_set(&out, p, jsonutil.json_int(i64(counts[p])))
	}
	return json.Value(json.Object(out))
}

// svc_deadline resolves the per-call deadline for svc round trips: the
// dispatch deadline, 0 = none (the dispatch token still cancels the request).
svc_deadline :: proc(ctx: ^Tool_Ctx) -> i64 {
	return ctx.deadline_ms
}

// need_svc reports whether the parent link is usable; svc-backed applies
// answer with a typed error when it is not (the visibility fold normally
// withdraws these tools before this can fire).
need_svc :: proc(ctx: ^Tool_Ctx) -> bool {
	return ctx.svc_conn != nil
}
