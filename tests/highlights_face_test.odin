// Tests for the svc.doc/highlights face: captures served over the real
// daemon handler against a real TS_Source + Doc_Sync pair (with the apply
// worker), the per-language compiled-once holder, the degradation ladder
// (no_grammar, no_query, source_too_large, capture_bound), and the version contract — a synced
// document answers its last applied version with the CLIENT's unsaved
// bytes; with none open it answers has_version=false over disk truth.
package tests

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "src:daemon"
import "src:editor"
import "jsonutil:jsonutil"
import "src:platform"
import "src:store"
import "src:ts"
import "src:svc"

Hlface_Fixture :: struct {
	d:      ^daemon.Daemon,
	root:   string,
	clock:  ^platform.Clock,
	token:  platform.Cancel_Token,
	src:    ^svc.TS_Source,
	ds:     ^svc.Doc_Sync,
	bridge: ^svc.Editor_Sync,
	worker: ^thread.Thread,
}

hlface_fixture :: proc(t: ^testing.T) -> ^Hlface_Fixture {
	root, rerr := os.make_directory_temp("", "aubade-hlface-", context.allocator)
	if rerr != nil {
		testing.fail_now(t, "temp root failed")
	}
	f := new(Hlface_Fixture, context.allocator)
	f.root = root

	state, _ := filepath.join([]string{root, ".aubade"}, context.allocator)
	if merr := os.make_directory_all(state, os.Permissions{.Read_User, .Write_User, .Execute_User}); merr != nil {
		testing.fail_now(t, "state dir failed")
	}
	db_path, _ := filepath.join([]string{state, "aubade.db"}, context.allocator)
	db, oerr := store.db_open(db_path, context.allocator)
	if oerr != nil {
		testing.fail_now(t, "db_open failed")
	}
	delete(db_path, context.allocator)
	delete(state, context.allocator)

	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, true) // virtual: nothing here waits

	d := new(daemon.Daemon, context.allocator)
	d^ = {}
	d.cfg = daemon.default_config(root, root, clock)
	d.db = db
	ed := new(editor.Editor, context.allocator)
	editor.editor_init(ed, root, .Lf, "utf-8", svc.editor_file_io_port(), context.allocator)
	d.ed = ed

	platform.token_init_root(&f.token)
	f.d = d
	f.clock = clock
	return f
}

hlface_teardown :: proc(f: ^Hlface_Fixture) {
	editor.editor_destroy(f.d.ed)
	free(f.d.ed, context.allocator)
	store.db_close(f.d.db)
	platform.clock_destroy(f.clock)
	free(f.clock, context.allocator)
	_ = os.remove_all(f.root)
	delete(f.root, context.allocator)
	free(f.d, context.allocator)
	free(f, context.allocator)
}

// hlface_lazy_fixture attaches the real tree-sitter producer, the
// document-sync face with its apply worker, and the sync bridge — the
// daemon's document plumbing, minus sockets.
hlface_lazy_fixture :: proc(t: ^testing.T) -> ^Hlface_Fixture {
	f := hlface_fixture(t)

	src := new(svc.TS_Source, context.allocator)
	svc.ts_source_init(src, f.root, f.d.db, f.clock, context.allocator)
	src.ed = f.d.ed
	f.src = src
	f.d.ts = src

	ds := new(svc.Doc_Sync, context.allocator)
	svc.doc_sync_init(ds, f.root, f.d.ed, context.allocator)
	f.ds = ds
	f.d.doc_sync = ds

	bridge := new(svc.Editor_Sync, context.allocator)
	svc.editor_sync_init(bridge, f.root, hot_sync_stub_port, nil, context.allocator, hot = &src.hot)
	svc.editor_sync_install(bridge, f.d.ed)
	f.bridge = bridge

	f.worker = thread.create_and_start_with_poly_data(ds, doc_sync_worker_entry, self_cleanup = false)
	return f
}

// hlface_lazy_teardown stops the face in the daemon's order (worker
// first), then the producer, before the shared base teardown frees the
// editor and the db under them.
hlface_lazy_teardown :: proc(f: ^Hlface_Fixture) {
	svc.doc_sync_stop(f.ds)
	if f.worker != nil {
		thread.join(f.worker)
		free(f.worker, context.allocator)
	}
	svc.doc_sync_destroy(f.ds)
	free(f.ds, context.allocator)
	svc.editor_sync_uninstall(f.bridge, f.d.ed)
	svc.editor_sync_destroy(f.bridge)
	free(f.bridge, context.allocator)
	if !svc.ts_source_destroy(f.src) {
		svc.ts_source_log_destroy_refusal(f.src)
	}
	free(f.src, context.allocator)
	hlface_teardown(f)
}

hlface_ctx :: proc(f: ^Hlface_Fixture, a: mem.Allocator) -> svc.Svc_Ctx {
	return {allocator = a, token = &f.token, user = f.d}
}

hlface_params :: proc(body: string, a: mem.Allocator) -> json.Value {
	value, perr := json.parse_bytes(transmute([]u8)body, spec = .JSON, parse_integers = true, allocator = a)
	if perr != nil {
		return nil
	}
	return value
}

hlface_write_file :: proc(t: ^testing.T, f: ^Hlface_Fixture, rel, content: string) {
	abs, _ := filepath.join([]string{f.root, rel}, context.temp_allocator)
	if werr := os.write_entire_file_from_bytes(abs, transmute([]u8)content); werr != nil {
		testing.expectf(t, false, "fixture file write failed: %s", rel)
	}
}

// hlface_call drives the real handler; the params object and the result
// live in the caller's arena.
hlface_call :: proc(f: ^Hlface_Fixture, rel: string, a: mem.Allocator) -> (json.Value, platform.Err) {
	ctx := hlface_ctx(f, a)
	body := strings.concatenate({`{"relative_path": "`, rel, `"}`}, a)
	return daemon.handle_doc_highlights(&ctx, hlface_params(body, a))
}

// hlface_holder peeks the language's cached highlights holder under the
// map mutex (observable for the compiled-once contract).
hlface_holder :: proc(f: ^Hlface_Fixture, lang: string) -> ^ts.Highlights {
	sync.mutex_lock(&f.src.mu)
	h := f.src.highlighters[lang]
	sync.mutex_unlock(&f.src.mu)
	return h
}

// hlface_captures_array fetches the response's captures array.
hlface_captures_array :: proc(result: json.Value) -> (json.Value, bool) {
	arr, ok := jsonutil.obj_get(result, "captures")
	return arr, ok
}

// hlface_bool_field reads a boolean field (present, boolean) — the
// package's json helpers cover strings and integers only.
hlface_bool_field :: proc(v: json.Value, key: string) -> (bool, bool) {
	if f, ok := jsonutil.obj_get(v, key); ok {
		#partial switch x in f {
		case json.Boolean:
			return bool(x), true
		case:
		}
	}
	return false, false
}

// hlface_capture_text slices the KNOWN source text at a capture's byte
// range ("" when the range is out of bounds).
hlface_capture_text :: proc(text: string, start, end: i64) -> string {
	if start < 0 || end > i64(len(text)) || start > end {
		return ""
	}
	return text[start:end]
}

// hlface_has_capture reports whether some capture's range slices exactly
// `want` out of the known text.
hlface_has_capture :: proc(result: json.Value, text, want: string) -> bool {
	arr, ok := hlface_captures_array(result)
	if !ok {
		return false
	}
	n := json_array_len(arr)
	for i in 0..<n {
		c := json_array_at(arr, i)
		start, iok := json_int_field(c, "start_byte")
		end, eok := json_int_field(c, "end_byte")
		if !iok || !eok {
			continue
		}
		if hlface_capture_text(text, start, end) == want {
			return true
		}
	}
	return false
}

// hlface_captures_sorted asserts position-ascending order over the flat
// capture array.
hlface_captures_sorted :: proc(result: json.Value) -> bool {
	arr, ok := hlface_captures_array(result)
	if !ok {
		return false
	}
	prev: i64 = -1
	n := json_array_len(arr)
	for i in 0..<n {
		c := json_array_at(arr, i)
		start, iok := json_int_field(c, "start_byte")
		if !iok {
			return false
		}
		if start < prev {
			return false
		}
		prev = start
	}
	return true
}

// ---------------------------------------------------------------------------
// 1. Capture round trip through the face
// ---------------------------------------------------------------------------

@(test)
hlface_captures_round_trip_with_applied_version :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	text := "package main\n\nfunc hlface_probe_fn() {}\n"
	hlface_write_file(t, f, "probe.go", text)
	deadline := platform.mono_ms() + 10_000
	outcome, oerr := svc.doc_sync_open(f.ds, "probe.go", "go", 7, text, nil, deadline, a)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}
	testing.expect(t, !outcome.superseded, "a plain open must apply")

	result, err := hlface_call(f, "probe.go", a)
	testing.expectf(t, err == nil, "highlights: %v", err)
	if err != nil {
		return
	}
	decline, _ := json_str_field(result, "decline")
	testing.expect_value(t, decline, "")
	version, vok := json_int_field(result, "version")
	testing.expect_value(t, vok, true)
	if vok {
		testing.expect_value(t, version, 7)
	}
	has_version, hok := hlface_bool_field(result, "has_version")
	testing.expect_value(t, hok, true)
	if hok {
		testing.expect(t, has_version, "an applied document must carry its version")
	}

	// The function declaration's name capture points at the right bytes.
	off := strings.index(text, "hlface_probe_fn")
	testing.expect(t, off >= 0, "fixture text must contain the probe name")
	if off < 0 {
		return
	}
	arr, aok := hlface_captures_array(result)
	testing.expect_value(t, aok, true)
	if !aok {
		return
	}
	found := false
	n := json_array_len(arr)
	testing.expectf(t, n > 0, "a go document must produce captures, got %d", n)
	for i in 0..<n {
		c := json_array_at(arr, i)
		name, nok := json_str_field(c, "name")
		start, iok := json_int_field(c, "start_byte")
		end, eok := json_int_field(c, "end_byte")
		if !nok || !iok || !eok {
			continue
		}
		if name == "function" && start == i64(off) && end == i64(off) + i64(len("hlface_probe_fn")) {
			found = true
		}
	}
	testing.expect(t, found, "the shipped go query must capture the function name at its bytes")

	// The flat array answers position-ascending.
	testing.expect(t, hlface_captures_sorted(result), "captures must be sorted by start position")
}

// ---------------------------------------------------------------------------
// 1b. The nvim-predicate regression: the shipped odin highlights query
// uses #lua-match?/#not-has-parent?, which the predicate engine must
// accept — a rejection failed every odin request with an internal error.
// ---------------------------------------------------------------------------

@(test)
hlface_odin_query_compiles_and_captures :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	text := "package main\n\nhlface_probe_proc :: proc() {}\n"
	hlface_write_file(t, f, "probe.odin", text)
	deadline := platform.mono_ms() + 10_000
	_, oerr := svc.doc_sync_open(f.ds, "probe.odin", "odin", 3, text, nil, deadline, a)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}

	result, err := hlface_call(f, "probe.odin", a)
	testing.expectf(t, err == nil, "highlights: %v", err)
	if err != nil {
		return
	}
	decline, _ := json_str_field(result, "decline")
	testing.expect_value(t, decline, "")
	arr, aok := hlface_captures_array(result)
	testing.expect_value(t, aok, true)
	if !aok {
		return
	}
	testing.expectf(t, json_array_len(arr) > 0, "an odin document must produce captures, got %d", json_array_len(arr))
	testing.expect(t, hlface_has_capture(result, text, "hlface_probe_proc"), "the shipped odin query must capture the procedure name")
}

// ---------------------------------------------------------------------------
// 2. Compiled once per language
// ---------------------------------------------------------------------------

@(test)
hlface_holder_compiled_once_per_language :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	text := "package main\n\nfunc hlface_once_fn() {}\n"
	hlface_write_file(t, f, "once.go", text)
	deadline := platform.mono_ms() + 10_000
	_, oerr := svc.doc_sync_open(f.ds, "once.go", "go", 1, text, nil, deadline, a)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}

	_, err := hlface_call(f, "once.go", a)
	testing.expectf(t, err == nil, "first call: %v", err)
	if err != nil {
		return
	}
	first := hlface_holder(f, "go")
	testing.expect(t, first != nil, "the first call must cache the language's holder")
	if first == nil {
		return
	}
	testing.expect(t, first.query != nil, "go ships a highlights query — the holder must carry it")

	// The second call reuses the same holder: the cached pointer is
	// unchanged (a rebuilt holder would be a fresh allocation).
	_, err = hlface_call(f, "once.go", a)
	testing.expectf(t, err == nil, "second call: %v", err)
	if err != nil {
		return
	}
	again := hlface_holder(f, "go")
	testing.expect_value(t, again, first)
}

// ---------------------------------------------------------------------------
// 3. Degradation ladder: source_too_large, no_query
// ---------------------------------------------------------------------------

@(test)
hlface_declines_source_too_large :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Disk truth over the bound (no document open): the gate fires before
	// any parse. The bound is ts.HIGHLIGHTS_MAX_SOURCE_BYTES.
	big, rerr := strings.repeat("a", ts.HIGHLIGHTS_MAX_SOURCE_BYTES + 16)
	testing.expectf(t, rerr == nil, "repeat failed: %v", rerr)
	if rerr != nil {
		return
	}
	hlface_write_file(t, f, "big.go", big)
	delete(big, context.allocator)

	result, err := hlface_call(f, "big.go", a)
	testing.expectf(t, err == nil, "highlights: %v", err)
	if err != nil {
		return
	}
	decline, _ := json_str_field(result, "decline")
	testing.expect_value(t, decline, "source_too_large")
	has_version, hok := hlface_bool_field(result, "has_version")
	testing.expect_value(t, hok, true)
	if hok {
		testing.expect(t, !has_version, "no document is open — disk truth carries no version")
	}
}

@(test)
hlface_declines_no_query_for_query_empty_grammar :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// asm serves .s but ships a zero-byte highlights query (the registry's
	// query_empty row).
	hlface_write_file(t, f, "probe.s", "mov eax, 1\n")

	result, err := hlface_call(f, "probe.s", a)
	testing.expectf(t, err == nil, "highlights: %v", err)
	if err != nil {
		return
	}
	decline, _ := json_str_field(result, "decline")
	testing.expect_value(t, decline, "no_query")
	testing.expect(t, hlface_holder(f, "asm") == nil, "a query-empty grammar caches a nil holder")
}

@(test)
hlface_declines_no_grammar :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// No grammar serves .txt — the ladder's first rung, answered before
	// any holder lookup.
	hlface_write_file(t, f, "notes.txt", "plain text\n")

	result, err := hlface_call(f, "notes.txt", a)
	testing.expectf(t, err == nil, "highlights: %v", err)
	if err != nil {
		return
	}
	decline, _ := json_str_field(result, "decline")
	testing.expect_value(t, decline, "no_grammar")
}

// ---------------------------------------------------------------------------
// 4. Degradation ladder: capture_bound
// ---------------------------------------------------------------------------

// The bound needs more captures than any small fixture text produces, so
// the source is generated: about 170 KiB of identical function
// declarations — well under the source gate, far over the capture bound
// (9000 declarations each capture at least their name). The engine-direct
// run also exercises the run's explicit destroy path, the cleanup a
// request arena's free_all would otherwise cover, and the face then
// answers the same decline as an explicit response over a synced document.
@(test)
hlface_declines_capture_bound :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	source, rerr := strings.repeat("func bound_fn() {}\n", 9000)
	testing.expectf(t, rerr == nil, "repeat failed: %v", rerr)
	if rerr != nil {
		return
	}
	defer delete(source, context.allocator)

	h, berr := ts.build_highlights("go", context.allocator)
	testing.expectf(t, berr == "", "build failed: %s", berr)
	if berr != "" {
		return
	}
	defer ts.highlights_destroy(h)
	pr, perr := ts.parse(source, "go")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)
	run := ts.highlights_run(h, pr.tree, source, context.allocator)
	testing.expect_value(t, run.decline, ts.Highlight_Decline.Capture_Bound)
	ts.highlights_run_destroy(run)

	hlface_write_file(t, f, "bound.go", "package main\n")
	deadline := platform.mono_ms() + 10_000
	text := strings.concatenate({"package main\n", source}, a)
	_, oerr := svc.doc_sync_open(f.ds, "bound.go", "go", 3, text, nil, deadline, a)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}
	result, err := hlface_call(f, "bound.go", a)
	testing.expectf(t, err == nil, "highlights: %v", err)
	if err != nil {
		return
	}
	decline, _ := json_str_field(result, "decline")
	testing.expect_value(t, decline, "capture_bound")
	version, vok := json_int_field(result, "version")
	testing.expect_value(t, vok, true)
	if vok {
		testing.expect_value(t, version, 3)
	}
}

// ---------------------------------------------------------------------------
// 5. Version contract
// ---------------------------------------------------------------------------

@(test)
hlface_version_contract_follows_the_document :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	hlface_write_file(t, f, "ver.go", "package main\n\nfunc ver_disk_fn() {}\n")

	// Closed: disk truth, no version.
	result, err := hlface_call(f, "ver.go", a)
	testing.expectf(t, err == nil, "closed call: %v", err)
	if err != nil {
		return
	}
	has_version, hok := hlface_bool_field(result, "has_version")
	testing.expect_value(t, hok, true)
	if hok {
		testing.expect(t, !has_version, "no document is open")
	}
	version, vok := json_int_field(result, "version")
	testing.expect_value(t, vok, true)
	if vok {
		testing.expect_value(t, version, 0)
	}

	deadline := platform.mono_ms() + 10_000
	_, oerr := svc.doc_sync_open(f.ds, "ver.go", "go", 5, "package main\n\nfunc ver_open_fn() {}\n", nil, deadline, a)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}
	result, err = hlface_call(f, "ver.go", a)
	testing.expectf(t, err == nil, "open call: %v", err)
	if err != nil {
		return
	}
	version, vok = json_int_field(result, "version")
	testing.expect_value(t, vok, true)
	if vok {
		testing.expect_value(t, version, 5)
	}

	_, cerr := svc.doc_sync_change(f.ds, "ver.go", 6, "package main\n\nfunc ver_changed_fn() {}\n", nil, deadline, a)
	testing.expectf(t, cerr == nil, "change failed: %v", cerr)
	if cerr != nil {
		return
	}
	result, err = hlface_call(f, "ver.go", a)
	testing.expectf(t, err == nil, "changed call: %v", err)
	if err != nil {
		return
	}
	version, vok = json_int_field(result, "version")
	testing.expect_value(t, vok, true)
	if vok {
		testing.expect_value(t, version, 6)
	}

	// Close reverts the answer to disk truth: has_version false again.
	clerr := svc.doc_sync_close(f.ds, "ver.go", a)
	testing.expectf(t, clerr == nil, "close failed: %v", clerr)
	if clerr != nil {
		return
	}
	result, err = hlface_call(f, "ver.go", a)
	testing.expectf(t, err == nil, "post-close call: %v", err)
	if err != nil {
		return
	}
	has_version, hok = hlface_bool_field(result, "has_version")
	testing.expect_value(t, hok, true)
	if hok {
		testing.expect(t, !has_version, "the document was closed")
	}
}

// ---------------------------------------------------------------------------
// 6. Unsaved text: the face serves the client's bytes, not the disk's
// ---------------------------------------------------------------------------

@(test)
hlface_serves_unsaved_client_text_not_disk :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	disk_text := "package main\n\nfunc hlface_disk_fn() {}\n"
	hlface_write_file(t, f, "unsaved.go", disk_text)
	client_text := "package main\n\nfunc hlface_client_fn() {}\n"
	deadline := platform.mono_ms() + 10_000
	_, oerr := svc.doc_sync_open(f.ds, "unsaved.go", "go", 1, client_text, nil, deadline, a)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}

	result, err := hlface_call(f, "unsaved.go", a)
	testing.expectf(t, err == nil, "highlights: %v", err)
	if err != nil {
		return
	}
	decline, _ := json_str_field(result, "decline")
	testing.expect_value(t, decline, "")
	testing.expect(
		t,
		hlface_has_capture(result, client_text, "hlface_client_fn"),
		"the face must capture the unsaved client text",
	)
	testing.expect(
		t,
		!hlface_has_capture(result, client_text, "hlface_disk_fn"),
		"the disk bytes must not leak into an open document's captures",
	)
}
