// Tests for the typed LSP request helpers: location parsing and
// enrichment (Location and LocationLink reply forms), the reference
// context flag on the wire, hover contents shapes, documentSymbol
// conversion through the shared finalize pipeline, rename edit parsing,
// formatting/inlay-hint/call-hierarchy/workspace-symbol round trips, and
// the diagnostics getter. Wire tests ride the lsp_pair fake server; pure
// parsers run on parsed JSON directly. Result allocations go through a
// per-test arena (the tracking allocator would otherwise flag every
// helper result as a leak), and indexing is guarded behind length checks
// (a bounds panic skips the defers that shut the pair down).
package tests

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"

import "src:jsonrpc"
import "src:jsonutil"
import "src:lsp"
import "src:platform"
import "src:symbol"

// canned_* handlers reply fixed payloads parsed in the request's arena;
// they never touch conn.host, so any connection can host them.

h_definition_links :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	v, _ := json.parse_string(
		`[{"targetUri":"file:///proj/pkg/a.go","targetSelectionRange":{"start":{"line":3,"character":8},"end":{"line":3,"character":16}}},{"uri":"file:///proj/pkg/b.go","range":{"start":{"line":0,"character":0},"end":{"line":1,"character":2}}}]`,
		spec = .JSON, parse_integers = true, allocator = arena,
	)
	return {result = v}, .Respond
}

// h_references_flag replies a location whose file answers whether the
// request's context carried includeDeclaration (capture-free flag
// plumbing: the reply IS the observation).
h_references_flag :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	file := "ref-false.go"
	if ctx_v, ok := jsonutil.obj_get(env.params, "context"); ok {
		if flag_v, fok := jsonutil.obj_get(ctx_v, "includeDeclaration"); fok {
			#partial switch x in flag_v {
			case json.Boolean:
				if x {
					file = "ref-true.go"
				}
			case:
			}
		}
	}
	body := strings.concatenate(
		{`[{"uri":"file:///proj/`, file, `","range":{"start":{"line":9,"character":0},"end":{"line":9,"character":4}}}]`},
		arena,
	)
	v, _ := json.parse_string(body, spec = .JSON, parse_integers = true, allocator = arena)
	return {result = v}, .Respond
}

h_hover_markdown :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	v, _ := json.parse_string(
		`{"contents":{"value":"func f(x int) int","kind":"markdown"}}`,
		spec = .JSON, parse_integers = true, allocator = arena,
	)
	return {result = v}, .Respond
}

h_formatting :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	v, _ := json.parse_string(
		`[{"range":{"start":{"line":0,"character":0},"end":{"line":2,"character":0}},"newText":"package main\n\n"}]`,
		spec = .JSON, parse_integers = true, allocator = arena,
	)
	return {result = v}, .Respond
}

h_inlay_hints :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	v, _ := json.parse_string(
		`[{"position":{"line":0,"character":4},"label":[{"value":"x "},{"value":"int"}],"tooltip":{"value":"type of x"}}]`,
		spec = .JSON, parse_integers = true, allocator = arena,
	)
	return {result = v}, .Respond
}

h_call_prepare :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	v, _ := json.parse_string(
		`{"name":"f","detail":"func()","kind":12,"uri":"file:///proj/m.go","range":{"start":{"line":1,"character":0},"end":{"line":2,"character":0}},"selectionRange":{"start":{"line":1,"character":5},"end":{"line":1,"character":6}}}`,
		spec = .JSON, parse_integers = true, allocator = arena,
	)
	return {result = v}, .Respond
}

h_incoming_calls :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	v, _ := json.parse_string(
		`[{"from":{"name":"g","kind":12,"uri":"file:///proj/caller.go","range":{"start":{"line":4,"character":0},"end":{"line":5,"character":0}},"selectionRange":{"start":{"line":4,"character":5},"end":{"line":4,"character":6}}},"fromRanges":[{"start":{"line":6,"character":0},"end":{"line":6,"character":3}}]}]`,
		spec = .JSON, parse_integers = true, allocator = arena,
	)
	return {result = v}, .Respond
}

h_workspace_symbol :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	v, _ := json.parse_string(
		`[{"name":"Query","kind":12,"location":{"uri":"file:///proj/w.go","range":{"start":{"line":5,"character":1},"end":{"line":5,"character":6}}},"containerName":"pkg"}]`,
		spec = .JSON, parse_integers = true, allocator = arena,
	)
	return {result = v}, .Respond
}

// test_split_receiver is the receiver-name hook shape the Go entry
// installs: "(*Type).Method" rewrites to Method under Type.
test_split_receiver :: proc(kind: symbol.Symbol_Kind, name: string, rel_path: string) -> (normalized: string, receiver: string) {
	if !strings.has_prefix(name, "(*") {
		return name, ""
	}
	if close := strings.index(name, ")"); close >= 0 && close + 2 < len(name) && name[close + 1] == '.' {
		return name[close + 2:], name[2:close]
	}
	return name, ""
}

@(test)
lsp_uri_roundtrip :: proc(t: ^testing.T) {
	path, ok := lsp.uri_to_path("file:///a%20b/c%2Fd.go", context.temp_allocator)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, path, "/a b/c/d.go")

	_, ok = lsp.uri_to_path("mailto:someone@example.com", context.temp_allocator)
	testing.expect_value(t, ok, false)

	// The authority form (file://server/share/x) is a UNC share: Windows
	// grounds it to the platform's two-leading-separator spelling, every
	// other platform reports it unresolvable rather than returning a
	// relative-looking path that happens to decode.
	when ODIN_OS == .Windows {
		unc, unc_ok := lsp.uri_to_path("file://server/share/a%20b.go", context.temp_allocator)
		testing.expect_value(t, unc_ok, true)
		if unc_ok {
			testing.expect_value(t, unc, "//server/share/a b.go")
		}

		// RFC 8089: a "localhost" authority reads as if no authority
		// were present, so the drive form decodes like a plain local
		// one (this arm compiles only on the Windows CI matrix).
		local, local_ok := lsp.uri_to_path("file://localhost/C:/tmp/a%20b.go", context.temp_allocator)
		testing.expect_value(t, local_ok, true)
		if local_ok {
			testing.expect_value(t, local, "C:/tmp/a b.go")
		}

		caps, caps_ok := lsp.uri_to_path("file://LocalHost/C:/tmp/x.go", context.temp_allocator)
		testing.expect_value(t, caps_ok, true)
		if caps_ok {
			testing.expect_value(t, caps, "C:/tmp/x.go")
		}
	} else {
		_, unc_ok := lsp.uri_to_path("file://server/share/a%20b.go", context.temp_allocator)
		testing.expect_value(t, unc_ok, false)

		// RFC 8089: a "localhost" authority reads exactly as if no
		// authority were present (hosts compare case-insensitively), so
		// its path decodes like a plain local one.
		local, local_ok := lsp.uri_to_path("file://localhost/tmp/a%20b.go", context.temp_allocator)
		testing.expect_value(t, local_ok, true)
		testing.expect_value(t, local, "/tmp/a b.go")

		caps, caps_ok := lsp.uri_to_path("file://LocalHost/tmp/x.go", context.temp_allocator)
		testing.expect_value(t, caps_ok, true)
		testing.expect_value(t, caps, "/tmp/x.go")

		// Authority-only form (no path) stays unresolvable.
		_, auth_ok := lsp.uri_to_path("file://localhost", context.temp_allocator)
		testing.expect_value(t, auth_ok, false)
	}

	uri := symbol.file_uri("/a b/c.go", context.temp_allocator)
	testing.expect_value(t, uri, "file:///a%20b/c.go")

	testing.expect_value(t, lsp.rel_path_for_root("/proj", "/proj/pkg/a.go"), "pkg/a.go")
	testing.expect_value(t, lsp.rel_path_for_root("/proj", "/other/pkg/a.go"), "")
	testing.expect_value(t, lsp.rel_path_for_root("/proj", "/proj"), "")
}

@(test)
lsp_location_helpers :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	p := lsp_pair_init(t)
	defer lsp_pair_shutdown(p)
	p.client.root_abs = strings.clone("/proj", p.allocator)

	jsonrpc.conn_register(p.fake.conn, lsp.METHOD_DEFINITION, h_definition_links)
	locs, err := lsp.request_definition(p.client, "file:///proj/src/m.go", 5, 2, a)
	testing.expectf(t, err == nil, "definition: %s", platform.err_message(err))
	testing.expect_value(t, len(locs), 2)
	if len(locs) != 2 {
		return
	}
	// First element is a LocationLink: the selection range wins.
	testing.expect_value(t, locs[0].rel_path, "pkg/a.go")
	testing.expect_value(t, locs[0].range.start.line, 3)
	testing.expect_value(t, locs[0].range.start.character, 8)
	// Second element is a plain Location.
	testing.expect_value(t, locs[1].rel_path, "pkg/b.go")
	testing.expect_value(t, locs[1].abs_path, "/proj/pkg/b.go")

	// The typeDefinition and implementation helpers ride the same
	// location machinery (the reply shape is shared across the family).
	jsonrpc.conn_register(p.fake.conn, lsp.METHOD_TYPE_DEFINITION, h_definition_links)
	tlocs, terr := lsp.request_type_definition(p.client, "file:///proj/src/m.go", 5, 2, a)
	testing.expectf(t, terr == nil, "typeDefinition: %s", platform.err_message(terr))
	testing.expect_value(t, len(tlocs), 2)
	if len(tlocs) == 2 {
		testing.expect_value(t, tlocs[0].rel_path, "pkg/a.go")
	}
	jsonrpc.conn_register(p.fake.conn, lsp.METHOD_IMPLEMENTATION, h_definition_links)
	ilocs, ierr := lsp.request_implementation(p.client, "file:///proj/src/m.go", 5, 2, a)
	testing.expectf(t, ierr == nil, "implementation: %s", platform.err_message(ierr))
	testing.expect_value(t, len(ilocs), 2)
	if len(ilocs) == 2 {
		testing.expect_value(t, ilocs[1].rel_path, "pkg/b.go")
	}
}

@(test)
lsp_references_flag_reaches_wire :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	p := lsp_pair_init(t)
	defer lsp_pair_shutdown(p)
	p.client.root_abs = strings.clone("/proj", p.allocator)

	jsonrpc.conn_register(p.fake.conn, lsp.METHOD_REFERENCES, h_references_flag)
	locs, err := lsp.request_references(p.client, "file:///proj/m.go", 1, 1, false, a)
	testing.expectf(t, err == nil, "references: %s", platform.err_message(err))
	testing.expect_value(t, len(locs), 1)
	if len(locs) == 1 {
		testing.expect_value(t, locs[0].rel_path, "ref-false.go")
	}

	locs, err = lsp.request_references(p.client, "file:///proj/m.go", 1, 1, true, a)
	testing.expectf(t, err == nil, "references 2: %s", platform.err_message(err))
	testing.expect_value(t, len(locs), 1)
	if len(locs) == 1 {
		testing.expect_value(t, locs[0].rel_path, "ref-true.go")
	}
}

@(test)
lsp_hover_forms :: proc(t: ^testing.T) {
	// Pure shapes: bare string, MarkedString object, mixed array.
	sv, _ := json.parse_string(`"plain text"`, spec = .JSON, allocator = context.temp_allocator)
	parsed := lsp.hover_parse(sv, 0)
	testing.expect_value(t, parsed.has_text, true)
	testing.expect_value(t, parsed.text, "plain text")
	testing.expect_value(t, parsed.markdown, false)

	mv, _ := json.parse_string(`{"language":"go","value":"func f()"}`, spec = .JSON, allocator = context.temp_allocator)
	parsed = lsp.hover_parse(mv, 0)
	testing.expect_value(t, parsed.has_text, true)
	testing.expect_value(t, parsed.text, "func f()")

	av, _ := json.parse_string(`["first",{"value":"second","kind":"markdown"}]`, spec = .JSON, allocator = context.temp_allocator)
	parsed = lsp.hover_parse(av, 0)
	testing.expect_value(t, parsed.has_text, true)
	testing.expect_value(t, parsed.text, "first\nsecond")
	testing.expect_value(t, parsed.markdown, true)

	// Wire: markdown hover, and a null reply is "no hover", not an error.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	p := lsp_pair_init(t)
	defer lsp_pair_shutdown(p)
	p.client.root_abs = strings.clone("/proj", p.allocator)
	jsonrpc.conn_register(p.fake.conn, lsp.METHOD_HOVER, h_hover_markdown)
	res, found, err := lsp.request_hover(p.client, "file:///proj/m.go", 2, 3, a)
	testing.expectf(t, err == nil, "hover: %s", platform.err_message(err))
	testing.expect_value(t, found, true)
	testing.expect_value(t, res.text, "func f(x int) int")
	testing.expect_value(t, res.is_markdown, true)
}

@(test)
lsp_document_symbol_conversion :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Hierarchical (nested + receiver-qualified top-level) and flat
	// SymbolInformation elements in one reply.
	v, perr := json.parse_string(
		`[{"name":"Client","kind":23,"range":{"start":{"line":0,"character":0},"end":{"line":9,"character":0}},"selectionRange":{"start":{"line":0,"character":6},"end":{"line":0,"character":12}},"children":[{"name":"ID","kind":8,"range":{"start":{"line":1,"character":1},"end":{"line":1,"character":5}},"selectionRange":{"start":{"line":1,"character":1},"end":{"line":1,"character":3}}}]},{"name":"(*Client).Call","kind":6,"range":{"start":{"line":3,"character":0},"end":{"line":5,"character":1}},"selectionRange":{"start":{"line":3,"character":20},"end":{"line":3,"character":24}}},{"name":"flat_func","kind":12,"location":{"uri":"file:///proj/pkg/x.go","range":{"start":{"line":7,"character":0},"end":{"line":8,"character":0}}},"containerName":"mod"}]`,
		spec = .JSON, parse_integers = true, allocator = a,
	)
	testing.expectf(t, perr == nil, "parse failed")
	if perr != nil {
		return
	}
	// Contents flow: the flat entry recovers its selection range from the
	// source text (findIdentifierRange port) — flat_func at line 7, name
	// first occurring at column 5 ("func flat_func").
	contents := "package pkg\n\ntype Client struct{}\n\nfunc (c *Client) Call() {}\n\nvar keep = 1\nfunc flat_func() {}\n"
	forest := lsp.symbols_from_document_symbol(v, contents, a)
	roots := symbol.finalize_symbol_tree(forest, symbol.Pipeline_Options{
		allocator     = a,
		normalize = test_split_receiver,
		abs_path  = "/proj/pkg/x.go",
		rel_path  = "pkg/x.go",
	})
	// The arena owns the forest; no manual destroy.

	// The receiver-qualified method nested under its type; the flat
	// symbol stayed top-level with its container name.
	testing.expect_value(t, len(roots), 2)
	if len(roots) != 2 {
		return
	}
	by_name := make(map[string]^symbol.Symbol, 2, a)
	for r in roots {
		by_name[r.name] = r
	}
	client, has_client := by_name["Client"]
	testing.expect_value(t, has_client, true)
	flat, has_flat := by_name["flat_func"]
	testing.expect_value(t, has_flat, true)
	delete(by_name)
	if !has_client || !has_flat {
		return
	}
	// The flat form's recovered selection range: "flat_func" first occurs
	// on line 7 at rune column 5 ("func flat_func"), spanning 9 runes.
	testing.expect(t, flat.selection_range != nil)
	if flat.selection_range != nil {
		testing.expect_value(t, flat.selection_range.start.line, 7)
		testing.expect_value(t, flat.selection_range.start.character, 5)
		testing.expect_value(t, flat.selection_range.end.character, 14)
	}
	testing.expect_value(t, len(client.children), 2)
	if len(client.children) != 2 {
		return
	}
	testing.expect_value(t, client.children[0].name, "ID")
	testing.expect_value(t, client.children[1].name, "Call")
	testing.expect_value(t, client.children[1].parent, client)
	testing.expect_value(t, flat.container_name, "mod")
	testing.expect_value(t, flat.location.uri, "file:///proj/pkg/x.go")
	testing.expect_value(t, flat.location.rel_path, "pkg/x.go")
	testing.expect_value(t, flat.location.range.start.line, 7)
	// The flat form's location range mirrors into rng — the range rng
	// consumers (the editor's symbol-edit transactions) need to work on
	// flat replies.
	testing.expect(t, flat.range != nil)
	if flat.range != nil {
		testing.expect_value(t, flat.range.start.line, 7)
		testing.expect_value(t, flat.range.start.character, 0)
		testing.expect_value(t, flat.range.end.line, 8)
		testing.expect_value(t, flat.range.end.character, 0)
	}
	// The pipeline anchors every symbol to the file.
	testing.expect_value(t, client.location.rel_path, "pkg/x.go")
}

// The flat form's selection recovery counts UTF-16 code units: an astral
// character is one rune but two units, and every consumer of these columns
// converts UTF-16 to byte offsets.
@(test)
lsp_flat_selection_columns_are_utf16_units :: proc(t: ^testing.T) {
	rng := lsp.identifier_range_on_line("x := \"😀\" fn alpha", "alpha", 0)
	testing.expect_value(t, rng.start.character, 13)
	testing.expect_value(t, rng.end.character, 18)
}

@(test)
lsp_rename_edits_forms :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	cl := lsp.Client{root_abs = "/proj"}

	changes, _ := json.parse_string(
		`{"changes":{"file:///proj/r.go":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"z"}]}}`,
		spec = .JSON, parse_integers = true, allocator = a,
	)
	edits := lsp.rename_edits_from_json(changes, &cl, a)
	testing.expect_value(t, len(edits), 1)
	if len(edits) == 1 {
		testing.expect_value(t, edits[0].rel_path, "r.go")
		testing.expect_value(t, edits[0].new_text, "z")
	}

	doc_changes, _ := json.parse_string(
		`{"documentChanges":[{"textDocument":{"uri":"file:///proj/d.go","version":3},"edits":[{"range":{"start":{"line":4,"character":2},"end":{"line":4,"character":5}},"newText":"q"}]}]}`,
		spec = .JSON, parse_integers = true, allocator = a,
	)
	edits = lsp.rename_edits_from_json(doc_changes, &cl, a)
	testing.expect_value(t, len(edits), 1)
	if len(edits) == 1 {
		testing.expect_value(t, edits[0].rel_path, "d.go")
		testing.expect_value(t, edits[0].range.start.line, 4)
		testing.expect_value(t, edits[0].new_text, "q")
	}
}

@(test)
lsp_formatting_inlay_call_hierarchy :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	p := lsp_pair_init(t)
	defer lsp_pair_shutdown(p)
	p.client.root_abs = strings.clone("/proj", p.allocator)

	jsonrpc.conn_register(p.fake.conn, lsp.METHOD_FORMATTING, h_formatting)
	edits, err := lsp.request_formatting(p.client, "file:///proj/m.go", 4, true, a)
	testing.expectf(t, err == nil, "formatting: %s", platform.err_message(err))
	testing.expect_value(t, len(edits), 1)
	if len(edits) == 1 {
		testing.expect_value(t, edits[0].new_text, "package main\n\n")
		testing.expect_value(t, edits[0].range.end.line, 2)
	}

	jsonrpc.conn_register(p.fake.conn, lsp.METHOD_INLAY_HINT, h_inlay_hints)
	hints, herr := lsp.request_inlay_hints(p.client, "file:///proj/m.go", 0, 0, 9, 0, a)
	testing.expectf(t, herr == nil, "inlay: %s", platform.err_message(herr))
	testing.expect_value(t, len(hints), 1)
	if len(hints) == 1 {
		testing.expect_value(t, hints[0].label, "x int")
		testing.expect_value(t, hints[0].tooltip, "type of x")
		testing.expect_value(t, hints[0].pos.character, 4)
	}

	jsonrpc.conn_register(p.fake.conn, lsp.METHOD_PREPARE_CALL_HIERARCHY, h_call_prepare)
	items, perr := lsp.request_prepare_call_hierarchy(p.client, "file:///proj/m.go", 1, 5, a)
	testing.expectf(t, perr == nil, "prepare: %s", platform.err_message(perr))
	testing.expect_value(t, len(items), 1)
	if len(items) != 1 {
		return
	}
	testing.expect_value(t, items[0].name, "f")
	testing.expect_value(t, items[0].kind, symbol.Symbol_Kind.Function)
	testing.expect_value(t, items[0].rel_path, "m.go")

	jsonrpc.conn_register(p.fake.conn, lsp.METHOD_INCOMING_CALLS, h_incoming_calls)
	edges, ierr := lsp.request_incoming_calls(p.client, items[0], a)
	testing.expectf(t, ierr == nil, "incoming: %s", platform.err_message(ierr))
	testing.expect_value(t, len(edges), 1)
	if len(edges) == 1 && len(edges[0].from_ranges) == 1 {
		testing.expect_value(t, edges[0].item.name, "g")
		testing.expect_value(t, edges[0].item.rel_path, "caller.go")
		testing.expect_value(t, edges[0].from_ranges[0].start.line, 6)
	}
}

@(test)
lsp_workspace_symbol_helper :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	p := lsp_pair_init(t)
	defer lsp_pair_shutdown(p)
	p.client.root_abs = strings.clone("/proj", p.allocator)

	jsonrpc.conn_register(p.fake.conn, lsp.METHOD_WORKSPACE_SYMBOL, h_workspace_symbol)
	roots, err := lsp.request_workspace_symbol(p.client, "Que", a)
	testing.expectf(t, err == nil, "workspace symbol: %s", platform.err_message(err))
	testing.expect_value(t, len(roots), 1)
	if len(roots) != 1 {
		return
	}
	testing.expect_value(t, roots[0].name, "Query")
	testing.expect_value(t, roots[0].container_name, "pkg")
	testing.expect_value(t, roots[0].location.rel_path, "w.go")
	testing.expect_value(t, roots[0].location.range.start.line, 5)
}

@(test)
lsp_diagnostics_store_get :: proc(t: ^testing.T) {
	s: lsp.Diagnostics_Store
	lsp.diagnostics_store_init(&s, context.allocator)
	defer lsp.diagnostics_store_destroy(&s)

	lsp.diagnostics_store_set(&s, "file:///proj/a.go", `[{"message":"x"}]`)
	lsp.diagnostics_store_set(&s, "file:///proj/b.go", `[]`)

	raw, ok := lsp.diagnostics_store_get(&s, "file:///proj/a.go", context.temp_allocator)
	testing.expect_value(t, ok, true)
	testing.expect(t, raw == `[{"message":"x"}]`)

	_, ok = lsp.diagnostics_store_get(&s, "file:///proj/b.go", context.temp_allocator)
	testing.expect_value(t, ok, false)
	_, ok = lsp.diagnostics_store_get(&s, "file:///proj/missing.go", context.temp_allocator)
	testing.expect_value(t, ok, false)

	lsp.diagnostics_store_set(&s, "file:///proj/a.go", `[]`)
	_, ok = lsp.diagnostics_store_get(&s, "file:///proj/a.go", context.temp_allocator)
	testing.expect_value(t, ok, false)
}

// h_document_diagnostic_full replies a full pull report; the delta
// variant replies the non-full kind the helper must decline.
h_document_diagnostic_full :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	v, _ := json.parse_string(
		`{"kind":"full","items":[{"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":7}},"severity":2,"message":"unused variable x","source":"testls","code":"W0913"}]}`,
		spec = .JSON, parse_integers = true, allocator = arena,
	)
	return {result = v}, .Respond
}

h_document_diagnostic_delta :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	v, _ := json.parse_string(
		`{"kind":"delta","resultId":"r1","items":[]}`,
		spec = .JSON, parse_integers = true, allocator = arena,
	)
	return {result = v}, .Respond
}

@(test)
lsp_pull_diagnostics_shapes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	p := lsp_pair_init(t)
	defer lsp_pair_shutdown(p)

	// No handler registered: the fake answers method-not-found — the
	// pull-unsupported signal callers fall back to the push store on.
	_, err0 := lsp.request_document_diagnostic(p.client, "file:///proj/m.go", a)
	testing.expect(t, err0 != nil, "unhandled method must surface an error")

	// A full report flattens to its items.
	jsonrpc.conn_register(p.fake.conn, lsp.METHOD_DOCUMENT_DIAGNOSTIC, h_document_diagnostic_full)
	items, err := lsp.request_document_diagnostic(p.client, "file:///proj/m.go", a)
	testing.expectf(t, err == nil, "pull full: %s", platform.err_message(err))
	arr, ok := jsonutil.as_array(items)
	testing.expectf(t, ok && len(arr) == 1, "full report items: ok=%v len=%d", ok, len(arr))
	if ok && len(arr) == 1 {
		msg_v, mok := jsonutil.obj_get(arr[0], "message")
		testing.expectf(t, mok, "message missing")
		testing.expect_value(t, jsonutil.value_str(msg_v), "unused variable x")
	}

	// A delta report declines without an error.
	jsonrpc.conn_register(p.fake.conn, lsp.METHOD_DOCUMENT_DIAGNOSTIC, h_document_diagnostic_delta)
	items2, err2 := lsp.request_document_diagnostic(p.client, "file:///proj/m.go", a)
	testing.expectf(t, err2 == nil, "delta must not error: %s", platform.err_message(err2))
	_, ok2 := jsonutil.as_array(items2)
	testing.expect_value(t, ok2, false)
}
