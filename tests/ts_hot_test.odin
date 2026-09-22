// Tests for the L2 hot parse-tree cache (the C.2.4 audit item): reuse on
// byte-identical reads, in-place refresh on external edits, incremental
// ts_tree_edit fidelity (an edited tree serves the same outline as a
// reparsed one), and the buffered-file pin lifecycle.
package tests

import "core:mem"
import "core:strings"
import "core:testing"

import "src:editor"
import "src:lsp"
import "src:platform"
import "src:symbol"
import "src:svc"
import "src:ts"

roots_have_symbol :: proc(roots: []^symbol.Symbol, name: string) -> bool {
	for i in 0..<len(roots) {
		if roots[i].name == name {
			return true
		}
	}
	return false
}

@(test)
hot_tree_reuse_and_refresh :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "a.go", "package main\n\nfunc alpha() int { return 1 }\n")
	roots, err := svc.ts_source_file_symbols(f.src, "a.go")
	testing.expectf(t, err == nil, "err: %v", err)
	testing.expect_value(t, len(roots), 1)
	symbol.symbol_forest_destroy(roots)

	// The first pass lands the tree in the hot cache with the file bytes.
	e, ok := ts.hot_acquire(&f.src.hot, "a.go")
	testing.expect(t, ok, "hot entry must exist after the first pass")
	if !ok {
		return
	}
	testing.expect(t, strings.contains(e.source, "func alpha"), "cached source matches the file")
	testing.expect_value(t, e.lang_name, "go")
	ts.hot_release(&f.src.hot, "a.go", e)

	// An external edit reparses and refreshes the entry in place.
	ts_write_file(t, f, "a.go", "package main\n\nfunc alpha() int { return 2 }\n\nfunc beta() {}\n")
	roots, err = svc.ts_source_file_symbols(f.src, "a.go")
	testing.expectf(t, err == nil, "err: %v", err)
	testing.expect(t, len(roots) == 2, "both functions after the edit")
	if len(roots) == 2 {
		testing.expect(t, roots_have_symbol(roots, "beta"), "beta indexed")
	}
	symbol.symbol_forest_destroy(roots)

	e, ok = ts.hot_acquire(&f.src.hot, "a.go")
	testing.expect(t, ok, "hot entry still present")
	if ok {
		testing.expect(t, strings.contains(e.source, "func beta"), "entry refreshed in place")
		ts.hot_release(&f.src.hot, "a.go", e)
	}

	// A byte-identical pass serves from the hot tree (the entry source
	// equals the disk bytes, so no reparse path runs).
	roots, err = svc.ts_source_file_symbols(f.src, "a.go")
	testing.expectf(t, err == nil, "err: %v", err)
	testing.expect_value(t, len(roots), 2)
	symbol.symbol_forest_destroy(roots)
}

@(test)
hot_tree_incremental_edit_matches_reparse :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "b.go", "package main\n\nfunc alpha() int { return 1 }\n")
	roots, err := svc.ts_source_file_symbols(f.src, "b.go")
	testing.expectf(t, err == nil, "err: %v", err)
	symbol.symbol_forest_destroy(roots)

	// The editor bridge's didChange: an incremental ts_tree_edit against
	// the cached tree, before the disk catches up.
	new_source := "package main\n\nfunc alpha() int { return 1 }\n\nfunc beta(x int) int { return x }\n"
	ts.hot_edit(&f.src.hot, "b.go", new_source)

	// Disk follows; the byte-identical check serves the EDITED tree, so
	// the outline proves the edit kept the tree consistent.
	ts_write_file(t, f, "b.go", new_source)
	roots, err = svc.ts_source_file_symbols(f.src, "b.go")
	testing.expectf(t, err == nil, "err: %v", err)
	testing.expect_value(t, len(roots), 2)
	if len(roots) == 2 {
		testing.expect(t, roots_have_symbol(roots, "beta"), "edited tree serves the new symbol")
		beta := roots[0]
		if roots[1].name == "beta" {
			beta = roots[1]
		}
		testing.expect_value(t, beta.selection_range.start.line, 4) // 0-based
	}
	symbol.symbol_forest_destroy(roots)

	e, ok := ts.hot_acquire(&f.src.hot, "b.go")
	if ok {
		testing.expect_value(t, e.source, new_source)
		ts.hot_release(&f.src.hot, "b.go", e)
	}
}

@(test)
hot_tree_buffer_pin_lifecycle :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	// A pin for a key with no entry is a no-op (the first symbol pass
	// parses later).
	ts.hot_pin_buffered(&f.src.hot, "none.go")
	testing.expect_value(t, ts.hot_pinned_count(&f.src.hot), 0)
	ts.hot_unpin_buffered(&f.src.hot, "none.go")

	ts_write_file(t, f, "c.go", "package main\n\nfunc gamma() {}\n")
	roots, err := svc.ts_source_file_symbols(f.src, "c.go")
	testing.expectf(t, err == nil, "err: %v", err)
	symbol.symbol_forest_destroy(roots)

	// Open pins the (now existing) tree, close releases it — and the pin
	// survives intermediate acquire/release cycles from symbol passes.
	ts.hot_pin_buffered(&f.src.hot, "c.go")
	testing.expect_value(t, ts.hot_pinned_count(&f.src.hot), 1)
	e, ok := ts.hot_acquire(&f.src.hot, "c.go")
	testing.expect(t, ok, "pinned entry acquires normally")
	if ok {
		ts.hot_release(&f.src.hot, "c.go", e)
	}
	testing.expect_value(t, ts.hot_pinned_count(&f.src.hot), 1)
	ts.hot_unpin_buffered(&f.src.hot, "c.go")
	testing.expect_value(t, ts.hot_pinned_count(&f.src.hot), 0)
}

@(test)
hot_insert_race_with_pinned_entry :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "d.go", "package main\n\nfunc alpha() {}\n")
	roots, err := svc.ts_source_file_symbols(f.src, "d.go")
	testing.expectf(t, err == nil, "err: %v", err)
	symbol.symbol_forest_destroy(roots)

	loser_src := "package main\n\nfunc loser() {}\n"
	pr, perr := ts.parse(loser_src, "go")
	testing.expectf(t, perr == "", "parse: %v", perr)

	// The race the pin contract now settles: a buffered open (or an
	// in-flight reader) pins the winner, and the loser's insert arrives
	// through the refresh-miss window. The refused put must free the
	// loser's tree/strings/entry (the tracking allocator proves it) and
	// leave the winner's entry untouched.
	pinned := ts.hot_pin_buffered(&f.src.hot, "d.go")
	testing.expect(t, pinned, "winner pinned")
	ts.hot_insert(&f.src.hot, "d.go", pr.tree, pr.lang, "go", loser_src)
	testing.expect_value(t, ts.hot_pinned_count(&f.src.hot), 1)
	e, ok := ts.hot_acquire(&f.src.hot, "d.go")
	testing.expect(t, ok, "winner entry still acquires")
	if ok {
		testing.expect(t, strings.contains(e.source, "func alpha"), "winner source intact")
		ts.hot_release(&f.src.hot, "d.go", e)
	}

	// Without a pin the same racing insert replaces the entry (the old
	// value had no holder — same freedom as eviction).
	ts.hot_unpin_buffered(&f.src.hot, "d.go")
	pr2, perr2 := ts.parse(loser_src, "go")
	testing.expectf(t, perr2 == "", "parse: %v", perr2)
	ts.hot_insert(&f.src.hot, "d.go", pr2.tree, pr2.lang, "go", loser_src)
	e2, ok2 := ts.hot_acquire(&f.src.hot, "d.go")
	testing.expect(t, ok2, "replaced entry acquires")
	if ok2 {
		testing.expect(t, strings.contains(e2.source, "func loser"), "unpinned race replaces")
		ts.hot_release(&f.src.hot, "d.go", e2)
	}
}

hot_sync_stub_port :: proc(
	user: rawptr,
	rel_path: string,
	may_start: bool,
	arena: mem.Allocator,
	token: ^platform.Cancel_Token,
) -> (client: ^lsp.Client, language_id: string, normalize: symbol.Normalize_Name_Proc, err: platform.Err) {
	return nil, "", nil, nil
}

@(test)
editor_sync_uninstall_drops_buffer_pins :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "e.go", "package main\n\nfunc delta() {}\n")
	roots, err := svc.ts_source_file_symbols(f.src, "e.go")
	testing.expectf(t, err == nil, "err: %v", err)
	symbol.symbol_forest_destroy(roots)

	e := new(editor.Editor, context.allocator)
	editor.editor_init(e, f.dir, .Lf, "", svc.editor_file_io_port(), context.allocator)
	sync := new(svc.Editor_Sync, context.allocator)
	svc.editor_sync_init(sync, f.dir, hot_sync_stub_port, nil, context.allocator, hot = &f.src.hot)
	svc.editor_sync_install(sync, e)

	// Opening a buffer pins its hot tree and records it in the sync's
	// ledger.
	werr, wmsg := editor.editor_insert_at_line(e, "e.go", 1, "// hi\n")
	testing.expectf(t, werr == .None, "insert: %s", wmsg)
	testing.expect_value(t, ts.hot_pinned_count(&f.src.hot), 1)

	// Uninstall drops the pin even though no buffer-close ever fires at
	// teardown (editor_destroy releases buffers silently) — the daemon's
	// hot_pinned_count teardown invariant depends on this.
	svc.editor_sync_uninstall(sync, e)
	testing.expect_value(t, ts.hot_pinned_count(&f.src.hot), 0)

	// Uninstall is idempotent: a second pass finds an empty ledger.
	svc.editor_sync_uninstall(sync, e)
	testing.expect_value(t, ts.hot_pinned_count(&f.src.hot), 0)

	svc.editor_sync_destroy(sync)
	free(sync, context.allocator)
	editor.editor_destroy(e)
	free(e, context.allocator)
}

// Buffer-bound eviction must run through the ordinary close path: the
// dropped buffer's hot-tree pin is released with the close notification,
// or a long-lived daemon's pinned set — and the parse trees it shields
// from eviction — grows without bound with every distinct edited file.
@(test)
editor_buffer_eviction_releases_hot_pins :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "a.go", "package main\n\nfunc alpha() {}\n")
	ts_write_file(t, f, "b.go", "package main\n\nfunc beta() {}\n")

	// Hot entries first (the buffer-open pin lands only on an entry that
	// exists), then a 1-file editor bound: editing b evicts a.
	roots, err := svc.ts_source_file_symbols(f.src, "a.go")
	testing.expectf(t, err == nil, "a.go symbols: %v", err)
	symbol.symbol_forest_destroy(roots)
	roots, err = svc.ts_source_file_symbols(f.src, "b.go")
	testing.expectf(t, err == nil, "b.go symbols: %v", err)
	symbol.symbol_forest_destroy(roots)

	e := new(editor.Editor, context.allocator)
	editor.editor_init(e, f.dir, .Lf, "", svc.editor_file_io_port(), context.allocator, 1, 1 << 30)
	sync := new(svc.Editor_Sync, context.allocator)
	svc.editor_sync_init(sync, f.dir, hot_sync_stub_port, nil, context.allocator, hot = &f.src.hot)
	svc.editor_sync_install(sync, e)
	defer {
		svc.editor_sync_uninstall(sync, e)
		svc.editor_sync_destroy(sync)
		free(sync, context.allocator)
		editor.editor_destroy(e)
		free(e, context.allocator)
	}

	werr, wmsg := editor.editor_insert_at_line(e, "a.go", 1, "// hi\n")
	testing.expectf(t, werr == .None, "insert a: %s", wmsg)
	testing.expect_value(t, ts.hot_pinned_count(&f.src.hot), 1)

	// The bound is 1: opening b closes a, and a's pin must go with it.
	werr, wmsg = editor.editor_insert_at_line(e, "b.go", 1, "// hi\n")
	testing.expectf(t, werr == .None, "insert b: %s", wmsg)
	testing.expect_value(t, len(e.buffers), 1)
	_, b_in := e.buffers["b.go"]
	testing.expect(t, b_in, "the just-edited buffer stays")
	testing.expect_value(t, ts.hot_pinned_count(&f.src.hot), 1)

	// Cycling back re-opens a and closes b: the pin count must settle at
	// 1, never accumulate.
	werr, wmsg = editor.editor_insert_at_line(e, "a.go", 2, "// again\n")
	testing.expectf(t, werr == .None, "re-insert a: %s", wmsg)
	testing.expect_value(t, len(e.buffers), 1)
	testing.expect_value(t, ts.hot_pinned_count(&f.src.hot), 1)
}

// The L2 refresh only parses what the cold path would: a source grown
// past the parse gate tombstones the entry (no tree, no source) instead
// of re-parsing megabytes under the pin; shrinking back under the gate
// re-parses fresh through the nil-tree path.
@(test)
hot_edit_tombstones_oversize_sources :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "a.go", "package main\n\nfunc alpha() int { return 1 }\n")
	roots, err := svc.ts_source_file_symbols(f.src, "a.go")
	testing.expectf(t, err == nil, "err: %v", err)
	symbol.symbol_forest_destroy(roots)

	pad_len := (ts.HOT_EDIT_MAX_SOURCE_BYTES / 7) + 8
	big := strings.repeat("// pad\n", pad_len, context.temp_allocator)
	testing.expect(t, len(big) > ts.HOT_EDIT_MAX_SOURCE_BYTES, "fixture must exceed the gate")
	ts.hot_edit(&f.src.hot, "a.go", big)

	e, ok := ts.hot_acquire(&f.src.hot, "a.go")
	testing.expect(t, ok, "the entry survives the tombstone (the buffer pin)")
	if !ok {
		return
	}
	testing.expect(t, e.tree == nil, "a tombstoned entry carries no tree")
	testing.expect_value(t, len(e.source), 0)
	ts.hot_release(&f.src.hot, "a.go", e)

	ts.hot_edit(&f.src.hot, "a.go", "package main\n\nfunc alpha() int { return 3 }\n")
	e, ok = ts.hot_acquire(&f.src.hot, "a.go")
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect(t, e.tree != nil, "a fresh tree after shrinking back under the gate")
	testing.expect(t, strings.contains(e.source, "return 3"))
	ts.hot_release(&f.src.hot, "a.go", e)
}

// The byte ledger is exact across every in-place mutation: edits and
// refreshes charge their delta, a tombstone refunds the freed bytes, and
// the ledger always equals the sum of live entry costs. Unrefunded
// tombstones once left phantom bytes in total_bytes that evicted every
// unpinned entry on each later insert; drifting edits kept the
// budget from bounding live memory.
@(test)
hot_byte_ledger_tracks_in_place_mutations :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "a.go", "package main\n\nfunc alpha() int { return 1 }\n")
	roots, err := svc.ts_source_file_symbols(f.src, "a.go")
	testing.expectf(t, err == nil, "err: %v", err)
	symbol.symbol_forest_destroy(roots)

	e, ok := ts.hot_acquire(&f.src.hot, "a.go")
	testing.expect(t, ok, "entry after first pass")
	if !ok {
		return
	}
	testing.expect(t, e.cost > 0, "fixture source must be non-empty")
	testing.expect_value(t, f.src.hot.cache.total_bytes, e.cost)
	ts.hot_release(&f.src.hot, "a.go", e)

	// hot_edit charges the grown source plus its re-parsed tree's nodes.
	grown := strings.repeat("// pad\n", 64, context.temp_allocator)
	ts.hot_edit(&f.src.hot, "a.go", grown)
	e, ok = ts.hot_acquire(&f.src.hot, "a.go")
	testing.expect(t, ok, "entry after edit")
	if !ok {
		return
	}
	testing.expectf(t, e.cost > len(grown), "cost %d must charge beyond the %d source bytes", e.cost, len(grown))
	testing.expect_value(t, f.src.hot.cache.total_bytes, e.cost)
	ts.hot_release(&f.src.hot, "a.go", e)

	// hot_refresh charges the swapped source and tree together.
	small := "package main\n\nfunc beta() {}\n"
	pr, perr := ts.parse(small, "go")
	testing.expectf(t, perr == "", "parse: %v", perr)
	testing.expect(t, ts.hot_refresh(&f.src.hot, "a.go", pr.tree, pr.lang, "go", small), "refresh hits the entry")
	e, ok = ts.hot_acquire(&f.src.hot, "a.go")
	testing.expect(t, ok, "entry after refresh")
	if !ok {
		return
	}
	testing.expectf(t, e.cost > len(small), "cost %d must charge beyond the %d source bytes", e.cost, len(small))
	testing.expect_value(t, f.src.hot.cache.total_bytes, e.cost)
	ts.hot_release(&f.src.hot, "a.go", e)

	// A tombstone refunds the entry's bytes entirely — the ledger must
	// not keep the freed cost as phantom bytes.
	pad_len := (ts.HOT_EDIT_MAX_SOURCE_BYTES / 7) + 8
	big := strings.repeat("// pad\n", pad_len, context.temp_allocator)
	ts.hot_edit(&f.src.hot, "a.go", big)
	testing.expect_value(t, f.src.hot.cache.total_bytes, 0)

	// Repeated tombstones leave no phantom bytes either, and the cache
	// still admits fresh inserts afterwards.
	tomb_src := "package main\n\nfunc t() {}\n"
	keys := []string{"t1.go", "t2.go"}
	for key in keys {
		pair, pair_err := ts.parse(tomb_src, "go")
		testing.expectf(t, pair_err == "", "parse: %v", pair_err)
		ts.hot_insert(&f.src.hot, key, pair.tree, pair.lang, "go", tomb_src)
		ts.hot_edit(&f.src.hot, key, big)
		testing.expect_value(t, f.src.hot.cache.total_bytes, 0)
	}
	fresh := "package main\n\nfunc fresh() {}\n"
	pf, pf_err := ts.parse(fresh, "go")
	testing.expectf(t, pf_err == "", "parse: %v", pf_err)
	ts.hot_insert(&f.src.hot, "fresh.go", pf.tree, pf.lang, "go", fresh)
	ef, okf := ts.hot_acquire(&f.src.hot, "fresh.go")
	testing.expect(t, okf, "cache admits inserts after tombstones")
	if okf {
		testing.expect_value(t, f.src.hot.cache.total_bytes, ef.cost)
		ts.hot_release(&f.src.hot, "fresh.go", ef)
	}
}

// The ledger charges what the tree actually costs: the source clone plus
// the tree's node count at the calibrated per-node rate. A
// source-length-only ledger once let a 128 MiB budget hold ~25x that in
// real memory on odin-grammar trees (measured 2026-09-06; see
// HOT_NODE_BYTES) — the daemon's ~1 GB RSS on large projects.
@(test)
hot_cost_charges_tree_nodes :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	src := "package main\n\nfunc alpha() int { return 1 }\nfunc beta() {}\n"
	pr, perr := ts.parse(src, "go")
	testing.expectf(t, perr == "", "parse: %v", perr)
	nodes := ts.node_descendant_count(ts.tree_root_node(pr.tree))
	testing.expect(t, nodes > 0, "fixture source must produce nodes")
	ts.hot_insert(&f.src.hot, "n.go", pr.tree, pr.lang, "go", src)

	e, ok := ts.hot_acquire(&f.src.hot, "n.go")
	testing.expect(t, ok, "entry after insert")
	if !ok {
		return
	}
	expect_cost := len(src) + int(nodes) * ts.HOT_NODE_BYTES
	testing.expectf(t, e.cost == expect_cost, "cost %d != source %d + %d nodes x %d", e.cost, len(src), nodes, ts.HOT_NODE_BYTES)
	testing.expect_value(t, f.src.hot.cache.total_bytes, e.cost)
	ts.hot_release(&f.src.hot, "n.go", e)

	// The tree component dominates on real sources: it must exceed the
	// source bytes for this fixture.
	testing.expectf(
		t,
		int(nodes) * ts.HOT_NODE_BYTES > len(src),
		"tree charge %d must exceed source %d",
		int(nodes) * ts.HOT_NODE_BYTES,
		len(src),
	)
}

// Teardown refuses to free under a live pin: a reader holding a hot
// entry borrows the tree, the outliners, and the struct itself, so the
// destroy leaks the whole source instead (daemon exit reaps it) — and
// proceeds normally once the pin releases. The deferred fixture destroy
// tolerates the already-destroyed source (its deletes are no-ops on the
// zeroed struct). The refusal is a silent predicate: this test asserts
// the boolean, and the callers that leak-to-exit on a refusal (the
// daemon teardown, the fixture) report it through
// svc.ts_source_log_destroy_refusal — a deliberate refusal here must
// not put an error line in the suite log.
@(test)
ts_source_destroy_refuses_under_live_pins :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "p.go", "package main\n\nfunc pinned() {}\n")
	roots, err := svc.ts_source_file_symbols(f.src, "p.go")
	testing.expectf(t, err == nil, "err: %v", err)
	symbol.symbol_forest_destroy(roots)

	testing.expect(t, ts.hot_pin_buffered(&f.src.hot, "p.go"), "buffer pin lands")
	testing.expect(t, !svc.ts_source_destroy(f.src), "destroy must refuse under a live pin")

	// The refusal freed nothing: the entry still serves readers.
	e, ok := ts.hot_acquire(&f.src.hot, "p.go")
	testing.expect(t, ok, "the pinned entry survives the refused destroy")
	if ok {
		testing.expect(t, e.tree != nil, "tree intact after the refusal")
		ts.hot_release(&f.src.hot, "p.go", e)
	}

	ts.hot_unpin_buffered(&f.src.hot, "p.go")
	testing.expect(t, svc.ts_source_destroy(f.src), "destroy proceeds once the pin releases")
}
