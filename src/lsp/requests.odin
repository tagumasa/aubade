// Typed request helpers over client_call: each builds the wire params,
// sends the request under the client's timeout and cancel token, and
// parses the reply into the closed result views the LSP symbol source and
// the langserver tools consume. Results and their strings are allocated
// in the caller-supplied allocator (the request arena in the daemon);
// failures come back as platform.Err with the message in the same
// allocator. Location-bearing results are enriched against the client's
// workspace root when one is set.
package lsp

import "core:encoding/json"
import "core:mem"
import "core:strings"

import "src:jsonrpc"
import "src:jsonutil"
import "src:platform"
import "src:symbol"

// ---------------------------------------------------------------------------
// Shared plumbing
// ---------------------------------------------------------------------------

// text_document_id builds {textDocument: {uri}}.
text_document_id :: proc(uri: string, a: mem.Allocator) -> json.Value {
	td := jsonutil.json_object(1, a)
	jsonutil.obj_set(&td, "uri", jsonutil.json_string(uri))
	return json.Value(json.Object(td))
}

// position_params builds TextDocumentPositionParams.
position_params :: proc(uri: string, line, col: int, a: mem.Allocator) -> map[string]json.Value {
	td := jsonutil.json_object(1, a)
	jsonutil.obj_set(&td, "uri", jsonutil.json_string(uri))
	pos := jsonutil.json_object(2, a)
	jsonutil.obj_set(&pos, "line", jsonutil.json_int(i64(line)))
	jsonutil.obj_set(&pos, "character", jsonutil.json_int(i64(col)))
	params := jsonutil.json_object(2, a)
	jsonutil.obj_set(&params, "textDocument", json.Value(json.Object(td)))
	jsonutil.obj_set(&params, "position", json.Value(json.Object(pos)))
	return params
}

// range_to_json builds a wire range from the model form.
range_to_json :: proc(r: symbol.Range, a: mem.Allocator) -> json.Value {
	start := jsonutil.json_object(2, a)
	jsonutil.obj_set(&start, "line", jsonutil.json_int(i64(r.start.line)))
	jsonutil.obj_set(&start, "character", jsonutil.json_int(i64(r.start.character)))
	end := jsonutil.json_object(2, a)
	jsonutil.obj_set(&end, "line", jsonutil.json_int(i64(r.end.line)))
	jsonutil.obj_set(&end, "character", jsonutil.json_int(i64(r.end.character)))
	out := jsonutil.json_object(2, a)
	jsonutil.obj_set(&out, "start", json.Value(json.Object(start)))
	jsonutil.obj_set(&out, "end", json.Value(json.Object(end)))
	return json.Value(json.Object(out))
}

// call_error maps a client_call outcome onto the closed platform error
// vocabulary; the message is cloned into `a` so it outlives the call.
call_error :: proc(op: string, code: jsonrpc.Err_Code, message: string, call_err: jsonrpc.Call_Err, a: mem.Allocator) -> platform.Err {
	switch call_err {
	case .None:
		return nil
	case .Timeout:
		return platform.Wrapped{kind = .Timeout, msg = strings.concatenate({op, " timed out"}, a)}
	case .Cancelled:
		return platform.Wrapped{kind = .Cancelled, msg = strings.concatenate({op, " cancelled"}, a)}
	case .Closed, .Transport:
		return platform.Wrapped{kind = .Terminated, msg = strings.concatenate({op, ": connection lost"}, a)}
	case .Error_Response:
		detail := message
		if detail == "" {
			detail = jsonrpc.code_message(code)
		}
		return platform.Wrapped{
			kind = .Internal,
			msg  = strings.concatenate({op, " failed: ", detail}, a),
		}
	case .Malformed_Reply:
		return platform.Wrapped{kind = .Internal, msg = strings.concatenate({op, ": malformed reply"}, a)}
	}
	return nil
}

// ---------------------------------------------------------------------------
// documentSymbol / workspace-symbol
// ---------------------------------------------------------------------------

// request_document_symbol returns the raw documentSymbol reply for
// conversion through symbols_from_document_symbol (the producer owns the
// finalize pass).
request_document_symbol :: proc(cl: ^Client, uri: string, a := context.allocator, token: ^platform.Cancel_Token = nil) -> (result: json.Value, err: platform.Err) {
	params := jsonutil.json_object(1, a)
	jsonutil.obj_set(&params, "textDocument", text_document_id(uri, a))
	raw, code, message, cerr := client_call(cl, METHOD_DOCUMENT_SYMBOL, json.Value(json.Object(params)), a, token)
	if cerr != .None {
		return nil, call_error("documentSymbol", code, message, cerr, a)
	}
	return raw, nil
}

// request_workspace_symbol searches every workspace file for the query;
// the flat SymbolInformation replies become shallow forest nodes with
// enriched locations (no finalize pass — the caller nests or flattens as
// it needs).
request_workspace_symbol :: proc(cl: ^Client, query: string, a := context.allocator, token: ^platform.Cancel_Token = nil) -> (roots: []^symbol.Symbol, err: platform.Err) {
	params := jsonutil.json_object(1, a)
	jsonutil.obj_set(&params, "query", jsonutil.json_string(query))
	raw, code, message, cerr := client_call(cl, METHOD_WORKSPACE_SYMBOL, json.Value(json.Object(params)), a, token)
	if cerr != .None {
		return nil, call_error("workspace/symbol", code, message, cerr, a)
	}

	out := make([dynamic]^symbol.Symbol, 0, 8, a)
	items, ok := jsonutil.as_array(raw)
	if ok {
		for item in items {
			node := workspace_symbol_node(item, cl, a)
			if node != nil {
				append(&out, node)
			}
		}
	}
	if len(out) == 0 {
		delete(out)
		return nil, nil
	}
	return out[:], nil
}

// workspace_symbol_node converts one SymbolInformation element.
workspace_symbol_node :: proc(v: json.Value, cl: ^Client, a: mem.Allocator) -> ^symbol.Symbol {
	obj, ok := jsonutil.as_object(v)
	if !ok {
		return nil
	}
	loc_v, lok := obj["location"]
	if !lok {
		return nil
	}
	node := symbol.symbol_new(a)
	if name_v, nok := obj["name"]; nok {
		node.name = symbol.clone_string(jsonutil.value_str(name_v), a)
	}
	if kind_v, kok := obj["kind"]; kok {
		node.kind = kind_from_json(kind_v)
	}
	if container_v, cok := obj["containerName"]; cok {
		node.container_name = symbol.clone_string(jsonutil.value_str(container_v), a)
	}
	loc := new(symbol.Location, a)
	if uri_v, uok := jsonutil.obj_get(loc_v, "uri"); uok {
		loc.uri = symbol.clone_string(jsonutil.value_str(uri_v), a)
	}
	if rng_v, gok := jsonutil.obj_get(loc_v, "range"); gok {
		if r, rok := range_from_json(rng_v); rok {
			loc.range = r
		}
	}
	location_enrich(cl, loc, a)
	node.location = loc
	return node
}

// ---------------------------------------------------------------------------
// Locations (definition / typeDefinition / implementation / references)
// ---------------------------------------------------------------------------

request_definition :: proc(cl: ^Client, uri: string, line, col: int, a := context.allocator, token: ^platform.Cancel_Token = nil) -> ([]symbol.Location, platform.Err) {
	return request_locations(cl, METHOD_DEFINITION, uri, line, col, false, a, token)
}

// request_declaration asks where the symbol at the position is declared
// (distinct from definition for languages that separate the two).
request_declaration :: proc(cl: ^Client, uri: string, line, col: int, a := context.allocator, token: ^platform.Cancel_Token = nil) -> ([]symbol.Location, platform.Err) {
	return request_locations(cl, METHOD_DECLARATION, uri, line, col, false, a, token)
}

// request_type_definition asks where the symbol's TYPE is declared. It
// has no callers yet — kept for the client surface's completeness;
// callers that wire it up gate on the cached capabilities (client_caps)
// before sending.
request_type_definition :: proc(cl: ^Client, uri: string, line, col: int, a := context.allocator, token: ^platform.Cancel_Token = nil) -> ([]symbol.Location, platform.Err) {
	return request_locations(cl, METHOD_TYPE_DEFINITION, uri, line, col, false, a, token)
}

// request_implementation asks for concrete implementations of the symbol
// at the position (interfaces' implementations, overrides).
request_implementation :: proc(cl: ^Client, uri: string, line, col: int, a := context.allocator, token: ^platform.Cancel_Token = nil) -> ([]symbol.Location, platform.Err) {
	return request_locations(cl, METHOD_IMPLEMENTATION, uri, line, col, false, a, token)
}

// request_references asks for reference sites; include_declaration mirrors
// the wire ReferenceContext flag (a declaration is a site only when set).
request_references :: proc(cl: ^Client, uri: string, line, col: int, include_declaration: bool, a := context.allocator, token: ^platform.Cancel_Token = nil) -> ([]symbol.Location, platform.Err) {
	return request_locations(cl, METHOD_REFERENCES, uri, line, col, include_declaration, a, token)
}

// request_locations serves the location-family requests: single Location,
// Location arrays, and LocationLink forms (targetUri/targetRange/
// targetSelectionRange) all normalise into enriched Locations. Replies
// without a resolvable file URI are dropped.
request_locations :: proc(
	cl: ^Client,
	method: string,
	uri: string,
	line, col: int,
	include_declaration: bool,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> ([]symbol.Location, platform.Err) {
	params := position_params(uri, line, col, a)
	if method == METHOD_REFERENCES {
		ctx := jsonutil.json_object(1, a)
		jsonutil.obj_set(&ctx, "includeDeclaration", jsonutil.json_bool(include_declaration))
		jsonutil.obj_set(&params, "context", json.Value(json.Object(ctx)))
	}
	raw, code, message, cerr := client_call(cl, method, json.Value(json.Object(params)), a, token)
	if cerr != .None {
		return nil, call_error(method, code, message, cerr, a)
	}

	out := make([dynamic]symbol.Location, 0, 4, a)
	if items, ok := jsonutil.as_array(raw); ok {
		for item in items {
			append_location_from_json(&out, item, cl, a)
		}
	} else {
		append_location_from_json(&out, raw, cl, a)
	}
	if len(out) == 0 {
		delete(out)
		return nil, nil
	}
	return out[:], nil
}

// append_location_from_json reads one Location or LocationLink element;
// anything else is skipped (mixed and partially-shaped replies stay
// answerable).
append_location_from_json :: proc(out: ^[dynamic]symbol.Location, v: json.Value, cl: ^Client, a: mem.Allocator) {
	obj, ok := jsonutil.as_object(v)
	if !ok {
		return
	}
	loc := symbol.Location{}
	if uri_v, uok := obj["uri"]; uok {
		loc.uri = symbol.clone_string(jsonutil.value_str(uri_v), a)
		if r, rok := range_from_json(obj["range"]); rok {
			loc.range = r
		}
	} else if target_v, tok := obj["targetUri"]; tok {
		loc.uri = symbol.clone_string(jsonutil.value_str(target_v), a)
		if r, rok := range_from_json(obj["targetSelectionRange"]); rok {
			loc.range = r
		} else if r2, rok2 := range_from_json(obj["targetRange"]); rok2 {
			loc.range = r2
		}
	} else {
		return
	}
	if loc.uri == "" {
		return
	}
	location_enrich(cl, &loc, a)
	append(out, loc)
}

// ---------------------------------------------------------------------------
// Hover
// ---------------------------------------------------------------------------

Hover_Result :: struct {
	text:        string, // owned by the caller's allocator
	is_markdown: bool,
}

// request_hover asks for hover text at the position; found=false means the
// server had nothing (a null reply or empty content is an answer, not a
// failure).
request_hover :: proc(cl: ^Client, uri: string, line, col: int, a := context.allocator, token: ^platform.Cancel_Token = nil) -> (res: Hover_Result, found: bool, err: platform.Err) {
	params := position_params(uri, line, col, a)
	raw, code, message, cerr := client_call(cl, METHOD_HOVER, json.Value(json.Object(params)), a, token)
	if cerr != .None {
		return {}, false, call_error("hover", code, message, cerr, a)
	}
	contents_v, ok := jsonutil.obj_get(raw, "contents")
	if !ok {
		return {}, false, nil
	}
	parsed := hover_parse(contents_v, 0)
	if !parsed.has_text {
		return {}, false, nil
	}
	return {text = strings.clone(parsed.text, a), is_markdown = parsed.markdown}, true, nil
}

Hover_Parse :: struct {
	text:     string, // scratch (temp allocator)
	markdown: bool,
	has_text: bool,
}

// hover_parse flattens the Hover contents shapes — MarkedString (string or
// {language, value}), MarkupContent ({value, kind}), and arrays of
// MarkedString — into one text (joined with newlines). Scratch allocation;
// callers clone the surviving text.
hover_parse :: proc(v: json.Value, depth: int) -> Hover_Parse {
	if v == nil || depth > symbol.MAX_RECURSION_DEPTH {
		return {}
	}
	if items, ok := jsonutil.as_array(v); ok {
		b := strings.builder_make(context.temp_allocator)
		any, any_markdown := false, false
		for item in items {
			p := hover_parse(item, depth + 1)
			if !p.has_text {
				continue
			}
			if any {
				strings.write_byte(&b, '\n')
			}
			strings.write_string(&b, p.text)
			any = true
			if p.markdown {
				any_markdown = true
			}
		}
		if !any {
			return {}
		}
		return {text = strings.to_string(b), markdown = any_markdown, has_text = true}
	}
	if obj, ok := jsonutil.as_object(v); ok {
		value_v, vak := obj["value"]
		if !vak {
			return {}
		}
		text := strings.trim_space(jsonutil.value_str(value_v))
		if text == "" {
			return {}
		}
		markdown := false
		if kind_v, kok := obj["kind"]; kok {
			markdown = jsonutil.value_str(kind_v) == "markdown"
		}
		return {text = text, markdown = markdown, has_text = true}
	}
	#partial switch x in v {
	case json.String:
		text := strings.trim_space(string(x))
		if text != "" {
			return {text = text, has_text = true}
		}
	case:
	}
	return {}
}

// ---------------------------------------------------------------------------
// Rename
// ---------------------------------------------------------------------------

// Rename_Edit is one edit of a rename WorkspaceEdit, resolved to the file
// it touches.
Rename_Edit :: struct {
	uri:      string,
	abs_path: string,
	rel_path: string,
	range:    symbol.Range,
	new_text: string,
}

request_rename :: proc(cl: ^Client, uri: string, line, col: int, new_name: string, a := context.allocator, token: ^platform.Cancel_Token = nil) -> ([]Rename_Edit, platform.Err) {
	params := position_params(uri, line, col, a)
	jsonutil.obj_set(&params, "newName", jsonutil.json_string(new_name))
	raw, code, message, cerr := client_call(cl, METHOD_RENAME, json.Value(json.Object(params)), a, token)
	if cerr != .None {
		return nil, call_error("rename", code, message, cerr, a)
	}
	return rename_edits_from_json(raw, cl, a), nil
}

// rename_edits_from_json reads both WorkspaceEdit shapes: the "changes"
// map (uri → TextEdit[]) and the "documentChanges" array
// ({textDocument: {uri}, edits}). Edits without a usable range keep the
// zero range — the tool layer still needs their file.
rename_edits_from_json :: proc(value: json.Value, cl: ^Client, a: mem.Allocator) -> []Rename_Edit {
	out := make([dynamic]Rename_Edit, 0, 4, a)
	if changes_v, ok := jsonutil.obj_get(value, "changes"); ok {
		if changes, cok := jsonutil.as_object(changes_v); cok {
			for uri, edits_v in changes {
				append_rename_edits(&out, uri, edits_v, cl, a)
			}
		}
	}
	if dc_v, ok := jsonutil.obj_get(value, "documentChanges"); ok {
		if entries, eok := jsonutil.as_array(dc_v); eok {
			for entry in entries {
				td_v, tok := jsonutil.obj_get(entry, "textDocument")
				if !tok {
					continue
				}
				uri_v, uok := jsonutil.obj_get(td_v, "uri")
				edits_v, edok := jsonutil.obj_get(entry, "edits")
				if !uok || !edok {
					continue
				}
				append_rename_edits(&out, jsonutil.value_str(uri_v), edits_v, cl, a)
			}
		}
	}
	if len(out) == 0 {
		delete(out)
		return nil
	}
	return out[:]
}

append_rename_edits :: proc(out: ^[dynamic]Rename_Edit, uri: string, edits_v: json.Value, cl: ^Client, a: mem.Allocator) {
	items, ok := jsonutil.as_array(edits_v)
	if !ok || uri == "" {
		return
	}
	for item in items {
		edit := Rename_Edit{uri = symbol.clone_string(uri, a)}
		if rng_v, gok := jsonutil.obj_get(item, "range"); gok {
			if r, rok := range_from_json(rng_v); rok {
				edit.range = r
			}
		}
		if text_v, tok := jsonutil.obj_get(item, "newText"); tok {
			edit.new_text = symbol.clone_string(jsonutil.value_str(text_v), a)
		}
		loc := symbol.Location{uri = edit.uri}
		location_enrich(cl, &loc, a)
		edit.abs_path = loc.abs_path
		edit.rel_path = loc.rel_path
		append(out, edit)
	}
}

// ---------------------------------------------------------------------------
// Code actions / formatting / inlay hints
// ---------------------------------------------------------------------------

// request_code_actions asks for code actions over a range. Code actions
// are heterogeneous (commands, edits, nested edits), so the reply is the
// raw JSON array for the tool layer to pass through; diagnostics_json is
// the stored diagnostics array embedded in the request context ("" sends
// an empty context).
request_code_actions :: proc(
	cl: ^Client,
	uri: string,
	start_line, start_col, end_line, end_col: int,
	diagnostics_json: string,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> (result: json.Value, err: platform.Err) {
	params := jsonutil.json_object(3, a)
	jsonutil.obj_set(&params, "textDocument", text_document_id(uri, a))
	rng := symbol.Range{
		start = {line = u32(max(start_line, 0)), character = u32(max(start_col, 0))},
		end   = {line = u32(max(end_line, 0)), character = u32(max(end_col, 0))},
	}
	jsonutil.obj_set(&params, "range", range_to_json(rng, a))
	ctx := jsonutil.json_object(1, a)
	diags := jsonutil.json_array({}, a)
	if diagnostics_json != "" {
		parsed, perr := json.parse_string(diagnostics_json, spec = .JSON, parse_integers = true, allocator = a)
		if perr != nil {
			return nil, platform.Wrapped{kind = .Invalid, msg = "invalid diagnostics JSON"}
		}
		diags = parsed
	}
	jsonutil.obj_set(&ctx, "diagnostics", diags)
	jsonutil.obj_set(&params, "context", json.Value(json.Object(ctx)))

	raw, code, message, cerr := client_call(cl, METHOD_CODE_ACTION, json.Value(json.Object(params)), a, token)
	if cerr != .None {
		return nil, call_error("codeAction", code, message, cerr, a)
	}
	return raw, nil
}

// request_document_diagnostic pulls diagnostics (textDocument/diagnostic).
// Servers without pull support answer with an error — that returns as err
// and callers fall back to the push store. A report whose kind is not "full" (or without
// items) answers nil items and no error: only full reports flatten.
request_document_diagnostic :: proc(cl: ^Client, uri: string, a := context.allocator, token: ^platform.Cancel_Token = nil) -> (items: json.Value, err: platform.Err) {
	params := jsonutil.json_object(1, a)
	jsonutil.obj_set(&params, "textDocument", text_document_id(uri, a))

	raw, code, message, cerr := client_call(cl, METHOD_DOCUMENT_DIAGNOSTIC, json.Value(json.Object(params)), a, token)
	if cerr != .None {
		return nil, call_error("documentDiagnostic", code, message, cerr, a)
	}
	kind := ""
	if kind_v, kok := jsonutil.obj_get(raw, "kind"); kok {
		kind = jsonutil.value_str(kind_v)
	}
	if kind != "full" {
		return nil, nil
	}
	items_v, iok := jsonutil.obj_get(raw, "items")
	if !iok {
		return nil, nil
	}
	return items_v, nil
}

// Text_Edit is a wire TextEdit resolved to the model range.
Text_Edit :: struct {
	range:    symbol.Range,
	new_text: string,
}

// request_formatting asks for whole-document formatting.
request_formatting :: proc(cl: ^Client, uri: string, tab_size: int, insert_spaces: bool, a := context.allocator, token: ^platform.Cancel_Token = nil) -> ([]Text_Edit, platform.Err) {
	params := jsonutil.json_object(2, a)
	jsonutil.obj_set(&params, "textDocument", text_document_id(uri, a))
	options := jsonutil.json_object(2, a)
	jsonutil.obj_set(&options, "tabSize", jsonutil.json_int(i64(tab_size)))
	jsonutil.obj_set(&options, "insertSpaces", jsonutil.json_bool(insert_spaces))
	jsonutil.obj_set(&params, "options", json.Value(json.Object(options)))

	raw, code, message, cerr := client_call(cl, METHOD_FORMATTING, json.Value(json.Object(params)), a, token)
	if cerr != .None {
		return nil, call_error("formatting", code, message, cerr, a)
	}
	return text_edits_from_json(raw, a), nil
}

text_edits_from_json :: proc(value: json.Value, a: mem.Allocator) -> []Text_Edit {
	out := make([dynamic]Text_Edit, 0, 4, a)
	items, ok := jsonutil.as_array(value)
	if !ok {
		delete(out)
		return nil
	}
	for item in items {
		edit := Text_Edit{}
		if rng_v, gok := jsonutil.obj_get(item, "range"); gok {
			if r, rok := range_from_json(rng_v); rok {
				edit.range = r
			}
		}
		if text_v, tok := jsonutil.obj_get(item, "newText"); tok {
			edit.new_text = symbol.clone_string(jsonutil.value_str(text_v), a)
		}
		append(&out, edit)
	}
	if len(out) == 0 {
		delete(out)
		return nil
	}
	return out[:]
}

// Inlay_Hint_Kind is the closed view of the wire InlayHintKind
// vocabulary; the members keep the wire values, and out-of-range wire
// numbers decode to .Unspecified.
Inlay_Hint_Kind :: enum {
	Unspecified,
	Type,     // wire 1
	Parameter, // wire 2
}

// INLAY_HINT_KIND_NAMES is the one spelling table (the render side omits
// the kind when the name is empty).
INLAY_HINT_KIND_NAMES :: []string{"", "type", "parameter"}

inlay_hint_kind_name :: proc(k: Inlay_Hint_Kind) -> string {
	names := INLAY_HINT_KIND_NAMES
	return names[cast(int)k]
}

// Inlay_Hint is the closed view of a wire InlayHint: position, flattened
// label, and tooltip text.
Inlay_Hint :: struct {
	pos:           symbol.Position,
	label:         string,
	tooltip:       string,
	kind:          Inlay_Hint_Kind,
	padding_left:  bool,
	padding_right: bool,
}

// request_inlay_hints asks for hints inside a range (the whole document
// when the range is the full extent).
request_inlay_hints :: proc(
	cl: ^Client,
	uri: string,
	start_line, start_col, end_line, end_col: int,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> ([]Inlay_Hint, platform.Err) {
	params := jsonutil.json_object(2, a)
	jsonutil.obj_set(&params, "textDocument", text_document_id(uri, a))
	rng := symbol.Range{
		start = {line = u32(max(start_line, 0)), character = u32(max(start_col, 0))},
		end   = {line = u32(max(end_line, 0)), character = u32(max(end_col, 0))},
	}
	jsonutil.obj_set(&params, "range", range_to_json(rng, a))

	raw, code, message, cerr := client_call(cl, METHOD_INLAY_HINT, json.Value(json.Object(params)), a, token)
	if cerr != .None {
		return nil, call_error("inlayHint", code, message, cerr, a)
	}

	out := make([dynamic]Inlay_Hint, 0, 4, a)
	items, ok := jsonutil.as_array(raw)
	if !ok {
		delete(out)
		return nil, nil
	}
	for item in items {
		hint := Inlay_Hint{}
		if pos_v, pok := jsonutil.obj_get(item, "position"); pok {
			hint.pos = position_from_json(pos_v)
		}
		if label_v, lok := jsonutil.obj_get(item, "label"); lok {
			hint.label = symbol.clone_string(inlay_label_text(label_v), a)
		}
		if tooltip_v, tok := jsonutil.obj_get(item, "tooltip"); tok {
			hint.tooltip = symbol.clone_string(tooltip_text(tooltip_v), a)
		}
		if kind_v, kok := jsonutil.obj_get(item, "kind"); kok {
			#partial switch x in kind_v {
			case json.Integer:
				if x >= 0 && x <= cast(i64)Inlay_Hint_Kind.Parameter {
					hint.kind = cast(Inlay_Hint_Kind)(x)
				}
			case:
			}
		}
		if pl_v, pok := jsonutil.obj_get(item, "paddingLeft"); pok {
			#partial switch x in pl_v {
			case json.Boolean:
				hint.padding_left = x
			case:
			}
		}
		if pr_v, prok := jsonutil.obj_get(item, "paddingRight"); prok {
			#partial switch x in pr_v {
			case json.Boolean:
				hint.padding_right = x
			case:
			}
		}
		append(&out, hint)
	}
	if len(out) == 0 {
		delete(out)
		return nil, nil
	}
	return out[:], nil
}

// inlay_label_text flattens the label forms (string or part arrays) into
// one string (scratch).
inlay_label_text :: proc(v: json.Value) -> string {
	if parts, ok := jsonutil.as_array(v); ok {
		b := strings.builder_make(context.temp_allocator)
		for part in parts {
			if value_v, pok := jsonutil.obj_get(part, "value"); pok {
				strings.write_string(&b, jsonutil.value_str(value_v))
			}
		}
		return strings.to_string(b)
	}
	return jsonutil.value_str(v)
}

// tooltip_text flattens the tooltip forms (string or MarkupContent,
// scratch).
tooltip_text :: proc(v: json.Value) -> string {
	if value_v, ok := jsonutil.obj_get(v, "value"); ok {
		return jsonutil.value_str(value_v)
	}
	return jsonutil.value_str(v)
}

// ---------------------------------------------------------------------------
// Call hierarchy
// ---------------------------------------------------------------------------

// Call_Item is a call-hierarchy item (both the prepare reply and the
// endpoints of incoming/outgoing edges), resolved to its file.
Call_Item :: struct {
	name:            string,
	kind:            symbol.Symbol_Kind,
	detail:          string,
	uri:             string,
	abs_path:        string,
	rel_path:        string,
	range:           symbol.Range,
	selection_range: symbol.Range,
}

// Call_Edge is one incoming or outgoing call: the other endpoint plus the
// ranges in the caller the call sites occupy.
Call_Edge :: struct {
	item:        Call_Item,
	from_ranges: []symbol.Range,
}

// request_prepare_call_hierarchy prepares hierarchy items at the position.
request_prepare_call_hierarchy :: proc(cl: ^Client, uri: string, line, col: int, a := context.allocator, token: ^platform.Cancel_Token = nil) -> ([]Call_Item, platform.Err) {
	params := position_params(uri, line, col, a)
	raw, code, message, cerr := client_call(cl, METHOD_PREPARE_CALL_HIERARCHY, json.Value(json.Object(params)), a, token)
	if cerr != .None {
		return nil, call_error("prepareCallHierarchy", code, message, cerr, a)
	}

	out := make([dynamic]Call_Item, 0, 2, a)
	if items, ok := jsonutil.as_array(raw); ok {
		for item in items {
			if ci, cok := call_item_from_json(item, cl, a); cok {
				append(&out, ci)
			}
		}
	} else if ci, cok := call_item_from_json(raw, cl, a); cok {
		append(&out, ci)
	}
	if len(out) == 0 {
		delete(out)
		return nil, nil
	}
	return out[:], nil
}

// Call_Direction is the call-hierarchy edge vocabulary: which way the
// reported edges point from the prepared item.
Call_Direction :: enum {
	Incoming,
	Outgoing,
}

// CALL_DIRECTION_NAMES is the one spelling table for Call_Direction: the
// schema enum hints and the daemon-side parse derive from it.
CALL_DIRECTION_NAMES :: []string{"incoming", "outgoing"}

// call_direction_from_string parses one direction spelling by traversing
// the names table (the from_string half of the single declaration).
call_direction_from_string :: proc(s: string) -> (d: Call_Direction, ok: bool) {
	names := CALL_DIRECTION_NAMES
	for dir in Call_Direction {
		if names[cast(int)dir] == s {
			return dir, true
		}
	}
	return .Incoming, false
}

// call_direction_string renders one direction spelling from the same
// table.
call_direction_string :: proc(d: Call_Direction) -> string {
	names := CALL_DIRECTION_NAMES
	return names[cast(int)d]
}

// request_incoming_calls asks who calls the item.
request_incoming_calls :: proc(cl: ^Client, item: Call_Item, a := context.allocator, token: ^platform.Cancel_Token = nil) -> ([]Call_Edge, platform.Err) {
	return call_edges(cl, METHOD_INCOMING_CALLS, item, "from", a, token)
}

// request_outgoing_calls asks whom the item calls.
request_outgoing_calls :: proc(cl: ^Client, item: Call_Item, a := context.allocator, token: ^platform.Cancel_Token = nil) -> ([]Call_Edge, platform.Err) {
	return call_edges(cl, METHOD_OUTGOING_CALLS, item, "to", a, token)
}

call_edges :: proc(cl: ^Client, method: string, item: Call_Item, endpoint_key: string, a := context.allocator, token: ^platform.Cancel_Token = nil) -> ([]Call_Edge, platform.Err) {
	params := jsonutil.json_object(1, a)
	jsonutil.obj_set(&params, "item", call_item_to_json(item, a))
	raw, code, message, cerr := client_call(cl, method, json.Value(json.Object(params)), a, token)
	if cerr != .None {
		return nil, call_error(method, code, message, cerr, a)
	}

	out := make([dynamic]Call_Edge, 0, 4, a)
	entries, ok := jsonutil.as_array(raw)
	if !ok {
		delete(out)
		return nil, nil
	}
	for entry in entries {
		endpoint_v, eok := jsonutil.obj_get(entry, endpoint_key)
		if !eok {
			continue
		}
		ci, cok := call_item_from_json(endpoint_v, cl, a)
		if !cok {
			continue
		}
		ranges := make([dynamic]symbol.Range, 0, 2, a)
		if fr_v, fok := jsonutil.obj_get(entry, "fromRanges"); fok {
			if fr_items, aok := jsonutil.as_array(fr_v); aok {
				for fr in fr_items {
					if r, rok := range_from_json(fr); rok {
						append(&ranges, r)
					}
				}
			}
		}
		append(&out, Call_Edge{item = ci, from_ranges = ranges[:]})
	}
	if len(out) == 0 {
		delete(out)
		return nil, nil
	}
	return out[:], nil
}

call_item_from_json :: proc(v: json.Value, cl: ^Client, a: mem.Allocator) -> (item: Call_Item, ok: bool) {
	obj, is_obj := jsonutil.as_object(v)
	if !is_obj {
		return {}, false
	}
	uri_v, uok := obj["uri"]
	if !uok {
		return {}, false
	}
	item.uri = symbol.clone_string(jsonutil.value_str(uri_v), a)
	if name_v, nok := obj["name"]; nok {
		item.name = symbol.clone_string(jsonutil.value_str(name_v), a)
	}
	if kind_v, kok := obj["kind"]; kok {
		item.kind = kind_from_json(kind_v)
	}
	if detail_v, dok := obj["detail"]; dok {
		item.detail = symbol.clone_string(jsonutil.value_str(detail_v), a)
	}
	if r, rok := range_from_json(obj["range"]); rok {
		item.range = r
	}
	if r, rok := range_from_json(obj["selectionRange"]); rok {
		item.selection_range = r
	}
	loc := symbol.Location{uri = item.uri}
	location_enrich(cl, &loc, a)
	item.abs_path = loc.abs_path
	item.rel_path = loc.rel_path
	return item, true
}

// call_item_to_json rebuilds the wire item for the incoming/outgoing
// params (servers echo the item they prepared; rebuilding the subset we
// kept is the round trip the wire shape allows).
call_item_to_json :: proc(item: Call_Item, a: mem.Allocator) -> json.Value {
	out := jsonutil.json_object(6, a)
	jsonutil.obj_set(&out, "name", jsonutil.json_string(item.name))
	jsonutil.obj_set(&out, "kind", jsonutil.json_int(i64(item.kind)))
	if item.detail != "" {
		jsonutil.obj_set(&out, "detail", jsonutil.json_string(item.detail))
	}
	jsonutil.obj_set(&out, "uri", jsonutil.json_string(item.uri))
	jsonutil.obj_set(&out, "range", range_to_json(item.range, a))
	jsonutil.obj_set(&out, "selectionRange", range_to_json(item.selection_range, a))
	return json.Value(json.Object(out))
}
