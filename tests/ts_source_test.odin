// Tests for src/svc/ts_source: the single-file symbol path (parse →
// finalize → index write) and the project crawl (gitignore scoping, builtin
// directory exclusions, size budgets, idempotent rewrites). Uses a
// throwaway project directory with a real SQLite index.
package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "src:platform"
import "src:store"
import "src:symbol"
import "src:svc"

TS_Fixture :: struct {
	dir:     string,
	db_dir:  string,
	db_path: string,
	db:      ^store.DB,
	clock:   ^platform.Clock,
	src:     ^svc.TS_Source,
}

ts_fixture :: proc(t: ^testing.T) -> TS_Fixture {
	dir, err := os.make_directory_temp("", "aubade-tssrc-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	// The index db lives outside the project root, like the daemon keeps
	// it under the runtime dir — the crawl must not see the db files.
	db_dir, derr := os.make_directory_temp("", "aubade-tssrcdb-", context.allocator)
	if derr != nil {
		testing.fail_now(t, "temp db dir failed")
	}
	db_path, _ := filepath.join([]string{db_dir, "symbols.db"}, context.allocator)
	db, oerr := store.db_open(db_path, context.allocator)
	if oerr != nil {
		testing.fail_now(t, "db open failed")
	}
	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, true, context.allocator)
	src := new(svc.TS_Source, context.allocator)
	svc.ts_source_init(src, dir, db, clock, context.allocator)
	return TS_Fixture{dir = dir, db_dir = db_dir, db_path = db_path, db = db, clock = clock, src = src}
}

ts_fixture_destroy :: proc(f: TS_Fixture) {
	if !svc.ts_source_destroy(f.src) {
		// A fixture teardown refusal means a test leaked a hot pin —
		// report it named (the suite protocol greps `aubade error:`
		// lines; a deliberate refusal in a test asserts the boolean
		// and stays silent).
		svc.ts_source_log_destroy_refusal(f.src)
	}
	free(f.src, context.allocator)
	store.db_close(f.db)
	delete(f.db_path)
	platform.clock_destroy(f.clock)
	free(f.clock, context.allocator)
	_ = os.remove_all(f.db_dir)
	delete(f.db_dir)
	_ = os.remove_all(f.dir)
	delete(f.dir)
}

// A setup write failure aborts the test loudly: a swallowed failure
// reads downstream as missing files, not as a broken fixture (the
// Windows CI leg once presented exactly that phantom). No threaded
// state exists yet at seeding time, so fail_now's skipped defers cost
// only teardown noise.
ts_write_file :: proc(t: ^testing.T, f: TS_Fixture, name: string, content: string) {
	path, _ := filepath.join([]string{f.dir, name}, context.temp_allocator)
	parent, _ := filepath.split(path)
	if parent != "" {
		// mkdir_all reports .Exist for a directory that is already
		// there — success for this purpose (the tools/build precedent).
		if merr := os.mkdir_all(parent, {.Read_User, .Write_User, .Execute_User}); merr != nil && merr != .Exist {
			testing.fail_now(t, strings.concatenate(
				{"fixture mkdir failed for ", name, ": ", os.error_string(merr)},
				context.temp_allocator,
			))
		}
	}
	fp, err := os.open(path, {.Write, .Create, .Trunc}, {
		.Read_User, .Write_User, .Read_Group, .Read_Other,
	})
	if err != nil {
		testing.fail_now(t, strings.concatenate(
			{"fixture write failed for ", name, ": ", os.error_string(err)},
			context.temp_allocator,
		))
	}
	if _, werr := os.write(fp, transmute([]u8)content); werr != nil {
		os.close(fp)
		testing.fail_now(t, strings.concatenate(
			{"fixture write failed for ", name, ": ", os.error_string(werr)},
			context.temp_allocator,
		))
	}
	if cerr := os.close(fp); cerr != nil {
		testing.fail_now(t, strings.concatenate(
			{"fixture close failed for ", name, ": ", os.error_string(cerr)},
			context.temp_allocator,
		))
	}
}

lookup_rows :: proc(f: TS_Fixture, name: string) -> []store.Symbol_Name_Row_With_File {
	rows, err := store.symbol_names_lookup(f.db, name, context.allocator)
	if err != nil {
		return nil
	}
	return rows
}

free_rows :: proc(rows: []store.Symbol_Name_Row_With_File) {
	store.symbol_names_rows_destroy(rows, context.allocator)
}

@(test)
ts_source_file_symbols_indexes_go_file :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "alpha.go", "package alpha\n\ntype Greeter struct{}\n\nfunc (g *Greeter) Hello() string { return \"hi\" }\n\nfunc Add(a, b int) int { return a + b }\n")

	roots, err := svc.ts_source_file_symbols(f.src, "alpha.go")
	testing.expectf(t, err == nil, "err: %v", err)
	testing.expect(t, len(roots) > 0)
	defer symbol.symbol_forest_destroy(roots)

	// Greeter with the re-nested Hello method, plus Add.
	total := symbol.count_symbols(roots)
	testing.expect(t, total == 3)
	for i in 0..<len(roots) {
		testing.expectf(t, roots[i].location != nil, "location missing for %s", roots[i].name)
	}

	rows := lookup_rows(f, "Add")
	defer free_rows(rows)
	testing.expect(t, len(rows) == 1)
	if len(rows) == 1 {
		testing.expect_value(t, rows[0].path, "alpha.go")
		testing.expect_value(t, rows[0].kind, "Function")
		testing.expect(t, rows[0].line == 6) // 0-based LSP lines
	}

	method_rows := lookup_rows(f, "Hello")
	defer free_rows(method_rows)
	testing.expect(t, len(method_rows) == 1)
	if len(method_rows) == 1 {
		testing.expect_value(t, method_rows[0].parent, "Greeter")
		testing.expect_value(t, method_rows[0].kind, "Method")
		testing.expect(t, len(method_rows[0].hash) == 64) // sha256 hex
	}
}

@(test)
ts_source_file_symbols_rejects_bad_paths :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "notes.txt", "not source\n")
	ts_write_file(t, f, "sub/keep.go", "package sub\n")
	ts_write_file(t, f, "empty.go", "package empty\n")

	err_kind_for :: proc(f_arg: TS_Fixture, rel: string) -> (platform.Err_Kind, bool) {
		roots, e := svc.ts_source_file_symbols(f_arg.src, rel)
		if len(roots) > 0 {
			symbol.symbol_forest_destroy(roots)
		}
		if e == nil {
			return .Internal, false
		}
		kind := platform.err_kind(e)
		msg := platform.err_message(e)
		if msg != "" {
			delete(msg)
		}
		return kind, true
	}

	kind, failed := err_kind_for(f, "missing.go")
	testing.expect(t, failed && kind == .NotFound)

	kind, failed = err_kind_for(f, "")
	testing.expect(t, failed && kind == .Invalid)

	kind, failed = err_kind_for(f, "../outside.go")
	testing.expect(t, failed && kind == .Invalid)

	kind, failed = err_kind_for(f, "sub")
	testing.expect(t, failed && kind == .Invalid)

	// Unsupported extensions are a non-error empty result (the caller
	// routes them elsewhere), and a go file with no definitions indexes
	// nothing but still parses cleanly.
	roots, err := svc.ts_source_file_symbols(f.src, "notes.txt")
	testing.expect(t, err == nil)
	testing.expect(t, len(roots) == 0)

	roots, err = svc.ts_source_file_symbols(f.src, "empty.go")
	testing.expect(t, err == nil)
	testing.expect(t, len(roots) == 0)
}

@(test)
ts_source_crawl_fills_index :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "alpha.go", "package main\n\nfunc Alpha() {}\n")
	ts_write_file(t, f, "sub/.gitignore", "gamma.go\n")
	ts_write_file(t, f, "sub/beta.go", "package sub\n\nfunc Beta() {}\n")
	ts_write_file(t, f, "sub/gamma.go", "package sub\n\nfunc Gamma() {}\n")
	ts_write_file(t, f, "node_modules/delta.go", "package nm\n\nfunc Delta() {}\n")
	ts_write_file(t, f, "notes.txt", "not source\n")

	stats: svc.Crawl_Stats
	err := svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl err: %v", err)
	testing.expect_value(t, stats.dirs_visited, 2) // root + sub
	testing.expect_value(t, stats.files_indexed, 2)
	testing.expect_value(t, stats.files_ignored, 1)
	testing.expect_value(t, stats.files_unsupported, 2) // notes.txt + sub/.gitignore
	testing.expect_value(t, stats.files_failed, 0)
	testing.expect(t, stats.truncated == false)

	alpha := lookup_rows(f, "Alpha")
	defer free_rows(alpha)
	testing.expect(t, len(alpha) == 1)
	if len(alpha) == 1 {
		testing.expect_value(t, alpha[0].path, "alpha.go")
	}

	beta := lookup_rows(f, "Beta")
	defer free_rows(beta)
	testing.expect(t, len(beta) == 1)
	if len(beta) == 1 {
		testing.expect_value(t, beta[0].path, "sub/beta.go")
	}

	gamma := lookup_rows(f, "Gamma")
	defer free_rows(gamma)
	testing.expect(t, len(gamma) == 0)

	delta := lookup_rows(f, "Delta")
	defer free_rows(delta)
	testing.expect(t, len(delta) == 0)
}

@(test)
ts_source_crawl_is_idempotent :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "one.go", "package one\n\nfunc One() {}\n")

	stats: svc.Crawl_Stats
	err := svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl1: %v", err)
	testing.expect_value(t, stats.files_indexed, 1)
	_ = stats.symbols

	// Same content, unchanged stat: the incremental skip takes it — no
	// rewrite, no duplicate L0 rows, the rows stay as crawl1 left them.
	err = svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl2: %v", err)
	testing.expect_value(t, stats.files_indexed, 0)
	testing.expect_value(t, stats.files_unchanged, 1)
	testing.expect_value(t, stats.symbols, 0)

	rows := lookup_rows(f, "One")
	defer free_rows(rows)
	testing.expect(t, len(rows) == 1)

	// Changed content: the old-hash rows vanish in the same transaction.
	ts_write_file(t, f, "one.go", "package one\n\nfunc One() {}\n\nfunc Two() {}\n")
	err = svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl3: %v", err)
	testing.expect_value(t, stats.files_indexed, 1)
	one := lookup_rows(f, "One")
	defer free_rows(one)
	testing.expect(t, len(one) == 1)
	two := lookup_rows(f, "Two")
	defer free_rows(two)
	testing.expect(t, len(two) == 1)
}

@(test)
ts_source_crawl_bom_shebang_script :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	// An extensionless script carrying a UTF-8 BOM: the crawl's shebang
	// read must come back BOM-stripped or the file never resolves a
	// grammar and stays unsupported (CLONE_BOM_PY lives in the clone-scan
	// fixtures, same package).
	ts_write_file(t, f, "runner", "\xEF\xBB\xBF#!/usr/bin/env python3\n"+CLONE_BOM_PY)

	stats: svc.Crawl_Stats
	err := svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl err: %v", err)
	testing.expect_value(t, stats.files_unsupported, 0)

	rows := lookup_rows(f, "tally")
	defer free_rows(rows)
	testing.expect(t, len(rows) == 1)
	if len(rows) == 1 {
		testing.expect_value(t, rows[0].path, "runner")
	}
}

@(test)
ts_source_crawl_scope_and_budgets :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "root.go", "package root\n\nfunc Root() {}\n")
	ts_write_file(t, f, "nested/deep.go", "package nested\n\nfunc Deep() {}\n")
	// 1.5 MiB of go source exceeds the per-file budget.
	big := make([dynamic]u8, 0, svc.MAX_SOURCE_FILE_BYTES + (1 << 19), context.temp_allocator)
	for len(big) < svc.MAX_SOURCE_FILE_BYTES + (1 << 19) {
		append(&big, "// padding padding padding padding padding\n")
	}
	ts_write_file(t, f, "big.go", string(big[:]))

	// Directory scope: only that subtree.
	stats: svc.Crawl_Stats
	err := svc.ts_source_crawl(f.src, "nested", &stats, {}, nil)
	testing.expectf(t, err == nil, "nested crawl: %v", err)
	testing.expect_value(t, stats.files_indexed, 1)
	deep := lookup_rows(f, "Deep")
	defer free_rows(deep)
	testing.expect(t, len(deep) == 1)
	root_rows := lookup_rows(f, "Root")
	defer free_rows(root_rows)
	testing.expect(t, len(root_rows) == 0)

	// Single-file scope through the crawl entry.
	stats = {}
	err = svc.ts_source_crawl(f.src, "root.go", &stats, {}, nil)
	testing.expectf(t, err == nil, "file crawl: %v", err)
	testing.expect_value(t, stats.files_indexed, 1)

	// Oversize files are counted, never parsed, and never fail the crawl.
	// The two already-committed files skip at the fingerprint probe — the
	// scoped crawls above recorded fingerprints too, so the skip composes
	// across crawl entry points.
	stats = {}
	err = svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "full crawl: %v", err)
	testing.expect_value(t, stats.files_oversize, 1)
	testing.expect_value(t, stats.files_indexed, 0) // root.go + nested/deep.go unchanged
	testing.expect_value(t, stats.files_unchanged, 2)

	// Invalid scopes error before walking.
	stats = {}
	err = svc.ts_source_crawl(f.src, "../escape", &stats, {}, nil)
	testing.expect(t, err != nil)
	testing.expect_value(t, platform.err_kind(err), platform.Err_Kind.Invalid)
	if escape_msg := platform.err_message(err); escape_msg != "" {
		delete(escape_msg)
	}
}

@(test)
scan_tree_borrow_only_never_lands :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	// The whole-project scans resolve trees through this handle: an
	// L2 entry with byte-identical source is borrowed (pinned, no
	// parse), anything else parses fresh and is freed at release — the
	// scan never LANDS a tree in the cache (scan-side inserts evict
	// under the cache mutex and convoy the parallel workers; see
	// Scan_Tree_Handle). The symbol pass is the producer here.
	contents := "package scan\n\nfunc Alpha_scan() {}\n\nfunc Beta_scan() {}\n"
	stale := "package scan\n\nfunc Alpha_scan() {}\n\nfunc Beta_scan() {}\n\n"
	ts_write_file(t, f, "scan.go", contents)
	roots, serr := svc.ts_source_file_symbols(f.src, "scan.go")
	testing.expectf(t, serr == nil, "symbol pass failed")
	if serr != nil {
		return
	}
	defer symbol.symbol_forest_destroy(roots)

	h1, ok1 := svc.scan_tree_acquire(f.src, "go", contents, "scan.go")
	testing.expect(t, ok1)
	if !ok1 {
		return
	}
	testing.expect(t, h1.entry != nil) // borrowed the symbol pass's tree
	tree1 := h1.tree
	svc.scan_tree_release(&h1)

	h2, ok2 := svc.scan_tree_acquire(f.src, "go", stale, "scan.go")
	testing.expect(t, ok2)
	if !ok2 {
		return
	}
	testing.expect(t, h2.entry == nil) // stale bytes re-parse, own the tree
	svc.scan_tree_release(&h2)

	h3, ok3 := svc.scan_tree_acquire(f.src, "go", stale, "scan.go")
	testing.expect(t, ok3)
	if !ok3 {
		return
	}
	testing.expect(t, h3.entry == nil) // nothing landed: still a fresh parse
	testing.expect(t, h3.tree != tree1) // and not the cached tree
	svc.scan_tree_release(&h3)

	h4, ok4 := svc.scan_tree_acquire(f.src, "go", contents, "scan.go")
	testing.expect(t, ok4)
	if !ok4 {
		return
	}
	testing.expect(t, h4.entry != nil) // the cache kept the symbol pass's entry
	testing.expect(t, h4.tree == tree1)
	svc.scan_tree_release(&h4)
}
