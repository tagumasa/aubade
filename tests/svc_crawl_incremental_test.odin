// The incremental crawl contract: a second walk over unchanged files
// skips them (fingerprint + live rows), a changed file re-parses alone, a
// vanished file's rows are purged, rows lost to the TTL sweep re-parse
// under an unchanged fingerprint, and an emptied outline both stops
// answering and stops re-parsing. The purge is scoped to enumerated
// subtrees: an unreadable, depth-capped, or symlinked directory shields
// its own subtree but never blocks the purge elsewhere.
package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "src:svc"
import "src:store"

@(test)
crawl_skips_unchanged_and_reindexes_changed :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "one.go", "package one\n\nfunc One() {}\n")
	ts_write_file(t, f, "two.go", "package two\n\nfunc Two_Old() {}\n")

	stats: svc.Crawl_Stats
	err := svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl1: %v", err)
	testing.expect_value(t, stats.files_indexed, 2)

	// Nothing changed: the whole walk skips at the fingerprint probe.
	err = svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl2: %v", err)
	testing.expect_value(t, stats.files_indexed, 0)
	testing.expect_value(t, stats.files_unchanged, 2)
	one := lookup_rows(f, "One")
	defer free_rows(one)
	testing.expect(t, len(one) == 1)

	// One file changes on disk (different size): only it re-parses, the
	// renamed-away name stops answering, the new one appears.
	ts_write_file(t, f, "two.go", "package two\n\nfunc Two_New_Name_Here() {}\n")
	err = svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl3: %v", err)
	testing.expect_value(t, stats.files_indexed, 1)
	testing.expect_value(t, stats.files_unchanged, 1)

	old := lookup_rows(f, "Two_Old")
	defer free_rows(old)
	testing.expect(t, len(old) == 0)
	new := lookup_rows(f, "Two_New_Name_Here")
	defer free_rows(new)
	testing.expect(t, len(new) == 1)
}

@(test)
crawl_purges_vanished_files :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "stay.go", "package stay\n\nfunc Stay() {}\n")
	ts_write_file(t, f, "leave.go", "package leave\n\nfunc Leave() {}\n")

	stats: svc.Crawl_Stats
	err := svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl1: %v", err)
	leave := lookup_rows(f, "Leave")
	defer free_rows(leave)
	testing.expect(t, len(leave) == 1)

	gone, _ := filepath.join([]string{f.dir, "leave.go"}, context.temp_allocator)
	_ = os.remove(gone)

	err = svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl2: %v", err)
	testing.expect_value(t, stats.paths_purged, 1)
	testing.expect_value(t, stats.files_unchanged, 1)

	leave_after := lookup_rows(f, "Leave")
	defer free_rows(leave_after)
	testing.expect(t, len(leave_after) == 0)
	stay := lookup_rows(f, "Stay")
	defer free_rows(stay)
	testing.expect(t, len(stay) == 1)

	// The fingerprint went with the rows: a later purge pass does not
	// re-report the path.
	err = svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl3: %v", err)
	testing.expect_value(t, stats.paths_purged, 0)
}

@(test)
crawl_reindexes_ttl_expired_rows :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "aged.go", "package aged\n\nfunc Aged() {}\n")

	stats: svc.Crawl_Stats
	err := svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl1: %v", err)
	testing.expect_value(t, stats.files_indexed, 1)

	// Rows vanish under an unchanged fingerprint (what the TTL sweep
	// does): the skip must not fire on the fingerprint alone.
	derr := store.delete_symbol_path(f.db, "aged.go")
	testing.expectf(t, derr == nil, "delete: %v", derr)

	err = svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl2: %v", err)
	testing.expect_value(t, stats.files_unchanged, 0)
	testing.expect_value(t, stats.files_indexed, 1)
	aged := lookup_rows(f, "Aged")
	defer free_rows(aged)
	testing.expect(t, len(aged) == 1)
}

@(test)
crawl_emptied_outline_records_fingerprint :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "drained.go", "package drained\n\nfunc Drained() {}\n")

	stats: svc.Crawl_Stats
	err := svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl1: %v", err)
	testing.expect_value(t, stats.files_indexed, 1)

	// The file now declares nothing: the crawl must commit an empty
	// entry (old rows drop, fingerprint records) instead of skipping the
	// write — and the NEXT pass must skip (fingerprint recorded for an
	// empty outline too).
	ts_write_file(t, f, "drained.go", "package drained\n// nothing left\n")
	err = svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl2: %v", err)
	testing.expect_value(t, stats.files_indexed, 1)

	drained := lookup_rows(f, "Drained")
	defer free_rows(drained)
	testing.expect(t, len(drained) == 0)

	err = svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl3: %v", err)
	testing.expect_value(t, stats.files_unchanged, 1)
	testing.expect_value(t, stats.files_indexed, 0)
}

// An unreadable directory poisons only its own subtree: the
// purge still concludes absence for paths under enumerated directories,
// and keeps everything under the unreadable one — its contents are
// unknown, not gone. Permission modes are only meaningful on POSIX
// systems; Windows treats them as advisory and the directory stays
// readable.
when ODIN_OS != .Windows {
@(test)
crawl_purges_despite_unreadable_dir :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "stay.go", "package stay\n\nfunc Stay() {}\n")
	ts_write_file(t, f, "leave.go", "package leave\n\nfunc Leave() {}\n")
	ts_write_file(t, f, "locked/hidden.go", "package locked\n\nfunc Hidden() {}\n")

	stats: svc.Crawl_Stats
	err := svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl1: %v", err)
	testing.expect_value(t, stats.files_indexed, 3)

	locked, _ := filepath.join([]string{f.dir, "locked"}, context.temp_allocator)
	_ = os.change_mode(locked, os.Permissions{})
	// Restore before the fixture teardown runs (LIFO): remove_all cannot
	// enter a mode-0 directory.
	defer _ = os.change_mode(locked, {.Read_User, .Write_User, .Execute_User})

	leave, _ := filepath.join([]string{f.dir, "leave.go"}, context.temp_allocator)
	_ = os.remove(leave)

	err = svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl2: %v", err)
	testing.expect_value(t, stats.dirs_failed, 1)
	testing.expect_value(t, stats.paths_purged, 1)
	testing.expect_value(t, stats.files_unchanged, 1)

	leave_after := lookup_rows(f, "Leave")
	defer free_rows(leave_after)
	testing.expect(t, len(leave_after) == 0)
	hidden := lookup_rows(f, "Hidden")
	defer free_rows(hidden)
	testing.expect(t, len(hidden) == 1)
	stay := lookup_rows(f, "Stay")
	defer free_rows(stay)
	testing.expect(t, len(stay) == 1)
}
}

// Rows under a depth-capped subtree survive a whole-project walk: the
// subtree exists, the walk just stops — absence there is not provable.
// The rows are real: a scoped crawl restarts depth at its scope root, so
// it indexes files the whole-project walk can never reach.
@(test)
crawl_keeps_depth_capped_subtree_rows :: proc(t: ^testing.T) {
	// Windows: the chain is MAX_CRAWL_DEPTH+2 components — over 210 path
	// characters on its own — and under the runner's temp prefix the leaf
	// path crosses the 260-character Win32 limit, so the fixture cannot
	// exist there at all (the walk reports the deep chain unreadable, by
	// design).
	when ODIN_OS == .Windows {
		return
	}
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	// A chain of MAX_CRAWL_DEPTH+2 components, leaf file at the bottom.
	rel := ""
	for _ in 0..<svc.MAX_CRAWL_DEPTH + 2 {
		rel = strings.concatenate({rel, "d/"}, context.temp_allocator)
	}
	leaf := strings.concatenate({rel, "deep.go"}, context.temp_allocator)
	ts_write_file(t, f, leaf, "package deep\n\nfunc Deep() {}\n")

	// A scoped crawl down the first three components indexes the leaf
	// (depth restarts at the scope root).
	stats: svc.Crawl_Stats
	err := svc.ts_source_crawl(f.src, "d/d/d", &stats, {}, nil)
	testing.expectf(t, err == nil, "scoped crawl: %v", err)
	testing.expect_value(t, stats.files_indexed, 1)
	deep := lookup_rows(f, "Deep")
	defer free_rows(deep)
	testing.expect(t, len(deep) == 1)

	// The whole-project walk hits the depth cap mid-chain: the leaf is
	// unvisited but under a capped subtree, so it must not read as
	// vanished.
	err = svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl2: %v", err)
	testing.expect_value(t, stats.paths_purged, 0)
	deep_kept := lookup_rows(f, "Deep")
	defer free_rows(deep_kept)
	testing.expect(t, len(deep_kept) == 1)

	// The fingerprint went with the rows: a third scoped pass skips at the
	// probe instead of re-parsing.
	err = svc.ts_source_crawl(f.src, "d/d/d", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl3: %v", err)
	testing.expect_value(t, stats.files_unchanged, 1)
	testing.expect_value(t, stats.files_indexed, 0)
}

// A directory that becomes a symlink keeps its subtree's rows: the walk
// does not follow symlinks, but rows spelled through the link (editor
// writes, earlier walks) are live, not vanished. Symlink creation needs
// privileges Windows CI does not grant.
when ODIN_OS != .Windows {
@(test)
crawl_keeps_symlinked_subtree_rows :: proc(t: ^testing.T) {
	f := ts_fixture(t)
	defer ts_fixture_destroy(f)

	ts_write_file(t, f, "sub/linked.go", "package sub\n\nfunc Linked() {}\n")

	stats: svc.Crawl_Stats
	err := svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl1: %v", err)
	testing.expect_value(t, stats.files_indexed, 1)

	// sub moves outside the project and becomes a symlink to its new
	// location.
	outside, terr := os.make_directory_temp("", "aubade-symtest-", context.allocator)
	testing.expectf(t, terr == nil, "staging dir: %v", terr)
	if terr != nil {
		return
	}
	defer {
		_ = os.remove_all(outside)
		delete(outside, context.allocator)
	}
	sub_dir, _ := filepath.join([]string{f.dir, "sub"}, context.temp_allocator)
	moved, _ := filepath.join([]string{outside, "sub"}, context.temp_allocator)
	// The fixture mutations are checked: a failed rename or symlink
	// leaves the original real directory in place and the assertions
	// below pass vacuously (the premise — a symlinked subtree — never
	// existed).
	if rerr := os.rename(sub_dir, moved); rerr != nil {
		testing.expectf(t, false, "staging move failed: %v", rerr)
		return
	}
	if lerr := os.symlink(moved, sub_dir); lerr != nil {
		testing.expectf(t, false, "symlink creation failed: %v", lerr)
		return
	}

	err = svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, err == nil, "crawl2: %v", err)
	testing.expect_value(t, stats.paths_purged, 0)

	linked := lookup_rows(f, "Linked")
	defer free_rows(linked)
	testing.expect(t, len(linked) == 1)
}
}
