// Tests for the svc document-sync face: the editor buffer adopt seam, the
// open/change/close path through the one installed buffer listener (hot
// pin/edit; L0 rows are left to the read-side heal), the latest-wins
// coalescing under the single apply worker, the per-document version home,
// and the read-only boundary refusal. Direct-driven on a hand-built
// fixture, plus the channel-transport in-process daemon for the wire face.
package tests

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "src:daemon"
import "src:editor"
import "src:jsonrpc"
import "src:jsonutil"
import "src:platform"
import "src:store"
import "src:ts"
import "src:svc"

// The direct-drive fixture: a temp project, the real file-IO editor with
// the sync bridge installed (stub server port, real hot cache, real
// tree-sitter source over a temp db), and the document-sync face over it.
// `with_worker` runs the face's single apply worker on a thread, exactly
// as the daemon does; worker-less tests drive the answer rule without
// racing a pickup.
Doc_Sync_Fixture :: struct {
	dir:    string,
	db_dir: string,
	db:     ^store.DB,
	clock:  ^platform.Clock,
	src:    ^svc.TS_Source,
	e:      ^editor.Editor,
	bridge: ^svc.Editor_Sync,
	ds:     ^svc.Doc_Sync,
	worker: ^thread.Thread,
}

doc_sync_fixture :: proc(t: ^testing.T, max_buffers: int, with_worker: bool) -> Doc_Sync_Fixture {
	dir, err := os.make_directory_temp("", "aubade-docsync-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	// The index db lives outside the project root, like the daemon keeps it.
	db_dir, derr := os.make_directory_temp("", "aubade-docsyncdb-", context.allocator)
	if derr != nil {
		testing.fail_now(t, "temp db dir failed")
	}
	db_path, _ := filepath.join([]string{db_dir, "symbols.db"}, context.temp_allocator)
	db, oerr := store.db_open(db_path, context.allocator)
	if oerr != nil {
		testing.fail_now(t, "db open failed")
	}
	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, true, context.allocator)
	src := new(svc.TS_Source, context.allocator)
	svc.ts_source_init(src, dir, db, clock, context.allocator)
	e := new(editor.Editor, context.allocator)
	editor.editor_init(e, dir, .Lf, "", svc.editor_file_io_port(), context.allocator, max_buffers, 1 << 30)
	bridge := new(svc.Editor_Sync, context.allocator)
	svc.editor_sync_init(bridge, dir, hot_sync_stub_port, nil, context.allocator, hot = &src.hot)
	svc.editor_sync_install(bridge, e)
	ds := new(svc.Doc_Sync, context.allocator)
	svc.doc_sync_init(ds, dir, e, context.allocator)
	f := Doc_Sync_Fixture{
		dir = dir, db_dir = db_dir, db = db, clock = clock,
		src = src, e = e, bridge = bridge, ds = ds,
	}
	if with_worker {
		f.worker = thread.create_and_start_with_poly_data(ds, doc_sync_worker_entry, self_cleanup = false)
	}
	return f
}

doc_sync_worker_entry :: proc(ds: ^svc.Doc_Sync) {
	svc.doc_sync_worker_run(ds)
}

doc_sync_fixture_destroy :: proc(f: ^Doc_Sync_Fixture) {
	svc.doc_sync_stop(f.ds)
	if f.worker != nil {
		thread.join(f.worker)
		free(f.worker, context.allocator)
	}
	svc.doc_sync_destroy(f.ds)
	free(f.ds, context.allocator)
	svc.editor_sync_uninstall(f.bridge, f.e)
	svc.editor_sync_destroy(f.bridge)
	free(f.bridge, context.allocator)
	editor.editor_destroy(f.e)
	free(f.e, context.allocator)
	if !svc.ts_source_destroy(f.src) {
		svc.ts_source_log_destroy_refusal(f.src)
	}
	free(f.src, context.allocator)
	store.db_close(f.db)
	f.db = nil
	free(f.clock, context.allocator)
	_ = os.remove_all(f.dir)
	delete(f.dir)
	_ = os.remove_all(f.db_dir)
	delete(f.db_dir)
}

doc_sync_write_file :: proc(f: ^Doc_Sync_Fixture, name: string, content: string) {
	path, _ := filepath.join([]string{f.dir, name}, context.temp_allocator)
	fp, werr := os.open(path, {.Write, .Create, .Trunc}, {.Read_User, .Write_User, .Read_Group, .Read_Other})
	if werr != nil {
		return
	}
	os.write(fp, transmute([]u8)content)
	os.close(fp)
}

// doc_sync_read_disk returns a fixture file's raw disk bytes as a
// caller-owned string (context.allocator): the caller deletes it.
doc_sync_read_disk :: proc(f: ^Doc_Sync_Fixture, name: string) -> string {
	path, _ := filepath.join([]string{f.dir, name}, context.temp_allocator)
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		return ""
	}
	defer delete(data)
	return strings.clone(string(data), context.allocator)
}

doc_sync_buffer_of :: proc(e: ^editor.Editor, rel: string) -> ^editor.File_Buffer {
	key := platform.path_fold(rel, context.temp_allocator)
	sync.mutex_lock(&e.mu)
	buf := e.buffers[key]
	sync.mutex_unlock(&e.mu)
	return buf
}

// doc_sync_warm_hot seeds the L2 hot entry for rel from the given text:
// the buffer-open pin lands only on an entry that already exists (a pin
// for a missing key is lost by design). Seeding directly keeps the warm
// deterministic — a symbol-pass warm would be an L1-cache hit once a crawl
// has indexed the file and would fill no hot entry at all.
doc_sync_warm_hot :: proc(t: ^testing.T, hot: ^ts.Hot_Trees, rel, text: string) {
	pr, perr := ts.parse(text, "go")
	testing.expectf(t, perr == "", "warm parse failed: %s", perr)
	ts.hot_insert(hot, rel, pr.tree, pr.lang, "go", text)
}

// doc_sync_expect_change_effects asserts an applied change's downstream
// effects through the one listener: the pinned L2 hot tree carries the new
// bytes, and the L0 index rows do NOT answer for the change's symbol — the
// change path defers the row rewrite to the file's first reader (the
// symbol_find content-freshness heal), so a consecutive-change storm
// leaves the rows at their last-read state.
doc_sync_expect_change_effects :: proc(t: ^testing.T, f: ^Doc_Sync_Fixture, rel, want_source_contains, absent_symbol: string) {
	e, ok := ts.hot_acquire(&f.src.hot, rel)
	testing.expectf(t, ok, "hot entry must exist for %s", rel)
	if ok {
		testing.expect(t, strings.contains(e.source, want_source_contains), "hot tree source must track the applied text")
		ts.hot_release(&f.src.hot, rel, e)
	}
	rows, lerr := store.symbol_names_lookup(f.db, absent_symbol, context.temp_allocator)
	testing.expectf(t, lerr == nil, "symbol lookup failed: %v", lerr)
	for r in rows {
		testing.expectf(t, r.path != rel, "L0 rows must not answer for %s in %s before a reader arrives", absent_symbol, rel)
	}
}

@(test)
doc_sync_open_adopts_client_text :: proc(t: ^testing.T) {
	f := doc_sync_fixture(t, editor.EDITOR_MAX_BUFFERS, true)
	defer doc_sync_fixture_destroy(&f)

	disk_text := "package main\n\nfunc on_disk() {}\n"
	doc_sync_write_file(&f, "open.go", disk_text)
	doc_sync_warm_hot(t, &f.src.hot, "open.go", disk_text)

	text := "package main\n\nfunc client_text() {}\n"
	deadline := platform.mono_ms() + 10_000
	outcome, oerr := svc.doc_sync_open(f.ds, "open.go", "go", 7, text, nil, deadline, context.temp_allocator)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}
	testing.expect(t, !outcome.superseded, "a plain open must apply")
	testing.expect(t, outcome.has_version && outcome.version == 7, "the open answer carries the applied version")

	// The buffer carries the client text; the disk is untouched.
	buf := doc_sync_buffer_of(f.e, "open.go")
	testing.expect(t, buf != nil, "the buffer must exist after the open")
	if buf != nil {
		testing.expect_value(t, buf.contents, text)
	}
	disk := doc_sync_read_disk(&f, "open.go")
	defer delete(disk, context.allocator)
	testing.expect(t, strings.contains(disk, "func on_disk"), "the open must not touch the disk")

	// The listener saw the open: the hot tree is pinned for the buffer.
	testing.expect_value(t, ts.hot_pinned_count(&f.src.hot), 1)

	// The version home records the applied version.
	v, has := svc.doc_sync_last_applied_version(f.ds, "open.go")
	testing.expect(t, has && v == 7, "the version home carries the applied version")
}

// The single-source-of-truth regression: while the document is open, a
// synced buffer's unsaved client text survives every read path (the reload
// probe must not adopt the differing disk over it, and a failed edit's
// rollback restores the snapshot, not the disk) — the truth reverts to the
// disk only when the close drops the buffer.
@(test)
doc_sync_unsaved_text_survives_reads :: proc(t: ^testing.T) {
	f := doc_sync_fixture(t, editor.EDITOR_MAX_BUFFERS, true)
	defer doc_sync_fixture_destroy(&f)

	disk_text := "package main\n\nfunc probe_disk() {}\n"
	doc_sync_write_file(&f, "probe.go", disk_text)

	deadline := platform.mono_ms() + 10_000
	client_text := "package main\n\nfunc probe_client() {}\n"
	_, oerr := svc.doc_sync_open(f.ds, "probe.go", "go", 1, client_text, nil, deadline, context.temp_allocator)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}

	// A tool read (the path every symbol query takes) returns the client's
	// unsaved text — not the disk bytes sitting under it.
	read, rerr, _ := editor.editor_read_file(f.e, "probe.go")
	testing.expectf(t, rerr == .None, "read failed: %v", rerr)
	if rerr == .None {
		testing.expect_value(t, read, client_text)
		delete(read, f.e.allocator)
	}
	buf := doc_sync_buffer_of(f.e, "probe.go")
	testing.expect(t, buf != nil, "the buffer must survive the read")
	if buf != nil {
		testing.expect_value(t, buf.contents, client_text)

		// The rollback path restores the snapshot for a synced buffer —
		// the disk branch would have swapped the client text out.
		editor.rollback_buffer(f.e, buf, "probe.go", client_text)
		testing.expect_value(t, buf.contents, client_text)
	}

	// The close reverts the truth to the disk: the dropped buffer means the
	// next read serves the disk bytes.
	cerr := svc.doc_sync_close(f.ds, "probe.go", context.temp_allocator)
	testing.expectf(t, cerr == nil, "close failed: %v", cerr)
	if cerr != nil {
		return
	}
	after, aerr, _ := editor.editor_read_file(f.e, "probe.go")
	testing.expectf(t, aerr == .None, "post-close read failed: %v", aerr)
	if aerr == .None {
		testing.expect_value(t, after, disk_text)
		delete(after, f.e.allocator)
	}
}

@(test)
doc_sync_change_edits_hot_and_defers_l0 :: proc(t: ^testing.T) {
	f := doc_sync_fixture(t, editor.EDITOR_MAX_BUFFERS, true)
	defer doc_sync_fixture_destroy(&f)

	disk_text := "package main\n\nfunc before_edit() {}\n"
	doc_sync_write_file(&f, "edit.go", disk_text)
	doc_sync_warm_hot(t, &f.src.hot, "edit.go", disk_text)

	deadline := platform.mono_ms() + 10_000
	_, oerr := svc.doc_sync_open(f.ds, "edit.go", "go", 1, disk_text, nil, deadline, context.temp_allocator)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}

	// The change applies through hot_edit on the pinned tree; the L0 row
	// rewrite is deferred to the file's first reader, so the changed-in
	// symbol is not indexed here. The answer carries the applied version.
	changed := "package main\n\nfunc before_edit() {}\n\nfunc after_marker() {}\n"
	outcome, cerr := svc.doc_sync_change(f.ds, "edit.go", 2, changed, nil, deadline, context.temp_allocator)
	testing.expectf(t, cerr == nil, "change failed: %v", cerr)
	if cerr != nil {
		return
	}
	testing.expect(t, !outcome.superseded && outcome.version == 2, "the change must apply and answer version 2")
	doc_sync_expect_change_effects(t, &f, "edit.go", "func after_marker", "after_marker")

	v, has := svc.doc_sync_last_applied_version(f.ds, "edit.go")
	testing.expect(t, has && v == 2, "the version home advanced with the change")
}

@(test)
doc_sync_close_unpins_and_clears_version :: proc(t: ^testing.T) {
	f := doc_sync_fixture(t, editor.EDITOR_MAX_BUFFERS, true)
	defer doc_sync_fixture_destroy(&f)

	disk_text := "package main\n\nfunc closer() {}\n"
	doc_sync_write_file(&f, "close.go", disk_text)
	doc_sync_warm_hot(t, &f.src.hot, "close.go", disk_text)

	deadline := platform.mono_ms() + 10_000
	_, oerr := svc.doc_sync_open(f.ds, "close.go", "go", 3, disk_text, nil, deadline, context.temp_allocator)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}
	testing.expect_value(t, ts.hot_pinned_count(&f.src.hot), 1)

	cerr := svc.doc_sync_close(f.ds, "close.go", context.temp_allocator)
	testing.expectf(t, cerr == nil, "close failed: %v", cerr)
	if cerr != nil {
		return
	}

	// The drop ran the ordinary close path: the hot pin went with the
	// close notification, the version record cleared, and the buffer left
	// the editor (the next read sees the disk).
	testing.expect_value(t, ts.hot_pinned_count(&f.src.hot), 0)
	_, has := svc.doc_sync_last_applied_version(f.ds, "close.go")
	testing.expect(t, !has, "the version record clears on close")
	testing.expect_value(t, len(f.e.buffers), 0)

	// A second close is idempotent; a change after close is refused.
	cerr = svc.doc_sync_close(f.ds, "close.go", context.temp_allocator)
	testing.expectf(t, cerr == nil, "a second close must succeed: %v", cerr)
	_, cherr := svc.doc_sync_change(f.ds, "close.go", 4, "package main\n", nil, deadline, context.temp_allocator)
	testing.expect(t, cherr != nil, "a change after close must be refused")
}

// doc_sync_wait_pending_version polls until the document's pending slot
// carries `version` or the applied record already covers it (bounded: a
// submit that never lands fails the test instead of hanging it — the
// suite's arrival-wait pattern). Chaining on this is what makes a storm's
// arrival order deterministic: latest-wins is by arrival, so a storm that
// asserts "only the newest version landed" must submit in version order.
doc_sync_wait_pending_version :: proc(t: ^testing.T, ds: ^svc.Doc_Sync, rel: string, version: i32) -> bool {
	key := platform.path_fold(rel, context.temp_allocator)
	deadline := platform.mono_ms() + 10_000
	for platform.mono_ms() < deadline {
		sync.mutex_lock(&ds.mu)
		e := ds.docs[key]
		got := false
		if e != nil {
			if e.has_pending && e.pending.version >= version {
				got = true
			}
			if e.has_version && e.last_applied_version >= version {
				got = true
			}
		}
		sync.mutex_unlock(&ds.mu)
		if got {
			return true
		}
		time.sleep(2 * time.Millisecond)
	}
	testing.expectf(t, false, "pending version %d never reached the slot for %s", version, rel)
	return false
}

// Rapid chained changes race the single worker: every request answers,
// only the newest text can be the final buffer and index state, and the
// newest request answers as applied with the final version.
@(test)
doc_sync_storm_applies_only_latest :: proc(t: ^testing.T) {
	f := doc_sync_fixture(t, editor.EDITOR_MAX_BUFFERS, true)
	defer doc_sync_fixture_destroy(&f)

	disk_text := "package main\n\nfunc warm_storm() {}\n"
	doc_sync_write_file(&f, "storm.go", disk_text)
	doc_sync_warm_hot(t, &f.src.hot, "storm.go", disk_text)

	deadline := platform.mono_ms() + 10_000
	_, oerr := svc.doc_sync_open(f.ds, "storm.go", "go", 1, disk_text, nil, deadline, context.temp_allocator)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}

	versions := [4]i32{2, 3, 4, 5}
	texts := [4]string{
		"package main\n\nfunc storm_v2() {}\n",
		"package main\n\nfunc storm_v3() {}\n",
		"package main\n\nfunc storm_v4() {}\n",
		"package main\n\nfunc storm_v5_marker() {}\n",
	}
	jobs: [4]^Doc_Sync_Change_Job
	threads: [4]^thread.Thread
	for i in 0..<4 {
		jobs[i] = new(Doc_Sync_Change_Job, context.allocator)
		jobs[i]^ = {f = &f, rel = "storm.go", version = versions[i], text = texts[i]}
		threads[i] = thread.create_and_start_with_poly_data(jobs[i], doc_sync_change_job_entry, self_cleanup = false)
		// The next change submits only after this one reached the slot or
		// applied — the arrival order (and so the coalescing outcome) is
		// deterministic.
		if !doc_sync_wait_pending_version(t, f.ds, "storm.go", versions[i]) {
			break
		}
	}
	for i in 0..<4 {
		if threads[i] != nil {
			thread.join(threads[i])
			free(threads[i], context.allocator)
		}
	}

	// Every request is answered once the storm settles.
	for i in 0..<4 {
		if jobs[i] == nil {
			continue
		}
		testing.expectf(t, jobs[i].oerr == nil, "change v%d failed: %v", versions[i], jobs[i].oerr)
	}
	// The newest request answers as applied with the final version.
	if jobs[3] != nil {
		testing.expect(t, !jobs[3].superseded, "the newest change must apply")
		testing.expect_value(t, jobs[3].answer_version, 5)
	}
	for i in 0..<4 {
		if jobs[i] != nil {
			free(jobs[i], context.allocator)
		}
	}

	// Only the newest text landed: the buffer and the version home
	// describe v5, and the index rows stayed untouched by the storm —
	// nothing here read them, so no rewrite was paid.
	buf := doc_sync_buffer_of(f.e, "storm.go")
	testing.expect(t, buf != nil, "the buffer must exist after the storm")
	if buf != nil {
		testing.expect_value(t, buf.contents, texts[3])
	}
	v, has := svc.doc_sync_last_applied_version(f.ds, "storm.go")
	testing.expect(t, has && v == 5, "the version home carries the final version")
	doc_sync_expect_change_effects(t, &f, "storm.go", "func storm_v5_marker", "storm_v5_marker")
	stale_rows, lerr := store.symbol_names_lookup(f.db, "storm_v2", context.temp_allocator)
	testing.expectf(t, lerr == nil, "stale symbol lookup failed: %v", lerr)
	testing.expect_value(t, len(stale_rows), 0)
}

Doc_Sync_Change_Job :: struct {
	f:             ^Doc_Sync_Fixture,
	rel:           string,
	version:       i32,
	text:          string,
	oerr:          platform.Err,
	superseded:    bool,
	answer_version: i32,
}

doc_sync_change_job_entry :: proc(job: ^Doc_Sync_Change_Job) {
	outcome, err := svc.doc_sync_change(
		job.f.ds, job.rel, job.version, job.text,
		nil, platform.mono_ms() + 10_000, context.temp_allocator,
	)
	job.oerr = err
	job.superseded = outcome.superseded
	job.answer_version = outcome.version
}

// A change whose version the applied record already covers answers
// immediately as superseded and leaves the buffer and version untouched.
@(test)
doc_sync_stale_change_answers_superseded :: proc(t: ^testing.T) {
	f := doc_sync_fixture(t, editor.EDITOR_MAX_BUFFERS, true)
	defer doc_sync_fixture_destroy(&f)

	disk_text := "package main\n\nfunc stale_base() {}\n"
	doc_sync_write_file(&f, "stale.go", disk_text)
	doc_sync_warm_hot(t, &f.src.hot, "stale.go", disk_text)

	deadline := platform.mono_ms() + 10_000
	applied := "package main\n\nfunc applied_marker() {}\n"
	_, oerr := svc.doc_sync_open(f.ds, "stale.go", "go", 5, applied, nil, deadline, context.temp_allocator)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}

	outcome, cerr := svc.doc_sync_change(f.ds, "stale.go", 3, "package main\n\nfunc older_text() {}\n", nil, deadline, context.temp_allocator)
	testing.expectf(t, cerr == nil, "stale change must answer, not fail: %v", cerr)
	if cerr != nil {
		return
	}
	testing.expect(t, outcome.superseded, "a stale version answers as superseded")
	testing.expect(t, outcome.has_version && outcome.version == 5, "the answer carries the applied version")

	buf := doc_sync_buffer_of(f.e, "stale.go")
	testing.expect(t, buf != nil && strings.contains(buf.contents, "func applied_marker"), "the stale text must not reach the buffer")
	v, has := svc.doc_sync_last_applied_version(f.ds, "stale.go")
	testing.expect(t, has && v == 5, "the version home must not move for a stale change")
}

// Dropping a queued pending (a close of the document) answers the parked
// change at once — it must not wait for an apply that will never happen.
// Runs without the worker so the pickup cannot race the close; the open
// state is installed directly (an open through the face would park
// forever waiting for an apply that no worker will run).
@(test)
doc_sync_close_answers_parked_change :: proc(t: ^testing.T) {
	f := doc_sync_fixture(t, editor.EDITOR_MAX_BUFFERS, false)
	defer doc_sync_fixture_destroy(&f)

	disk_text := "package main\n\nfunc park_base() {}\n"
	doc_sync_write_file(&f, "park.go", disk_text)
	doc_sync_warm_hot(t, &f.src.hot, "park.go", disk_text)

	key := platform.path_fold("park.go", context.temp_allocator)
	entry := new(svc.Doc_Sync_Doc, context.allocator)
	entry^ = {
		key      = strings.clone(key, context.allocator),
		rel_path = strings.clone("park.go", context.allocator),
	}
	sync.mutex_lock(&f.ds.mu)
	f.ds.docs[entry.key] = entry
	sync.mutex_unlock(&f.ds.mu)

	job := new(Doc_Sync_Change_Job, context.allocator)
	job^ = {f = &f, rel = "park.go", version = 9, text = "package main\n\nfunc parked_text() {}\n"}
	thr := thread.create_and_start_with_poly_data(job, doc_sync_change_job_entry, self_cleanup = false)

	// Wait until the change's text sits in the pending slot (bounded poll;
	// worker-less, so nothing can pick it up before the close).
	if !doc_sync_wait_pending_version(t, f.ds, "park.go", 9) {
		thread.join(thr)
		free(thr, context.allocator)
		free(job, context.allocator)
		return
	}

	cerr := svc.doc_sync_close(f.ds, "park.go", context.temp_allocator)
	testing.expectf(t, cerr == nil, "close failed: %v", cerr)
	thread.join(thr)
	testing.expectf(t, job.oerr == nil, "the parked change must answer, not fail: %v", job.oerr)
	testing.expect(t, job.superseded, "a dropped pending answers as superseded")
	free(thr, context.allocator)
	free(job, context.allocator)

	// The entry freed with its last waiter; on a failure path it may still
	// be present, and freeing it here keeps the suite leak-clean either way.
	sync.mutex_lock(&f.ds.mu)
	left := f.ds.docs[key]
	if left != nil {
		delete_key(&f.ds.docs, left.key)
	}
	sync.mutex_unlock(&f.ds.mu)
	testing.expectf(t, left == nil, "the closed document's entry must free with its last waiter")
	if left != nil {
		delete(left.key, context.allocator)
		delete(left.rel_path, context.allocator)
		free(left, context.allocator)
	}
}

// The answer rule is pure per-entry state: exercised directly for the
// same-stream watermark supersede, the queued-newer answer, the
// applied-version coverage, and the stream/close endings.
@(test)
doc_sync_answer_rule :: proc(t: ^testing.T) {
	f := doc_sync_fixture(t, editor.EDITOR_MAX_BUFFERS, false)
	defer doc_sync_fixture_destroy(&f)

	e := new(svc.Doc_Sync_Doc, context.allocator)
	e^ = {
		key      = strings.clone("rule.go", context.allocator),
		rel_path = strings.clone("rule.go", context.allocator),
	}
	sync.mutex_lock(&f.ds.mu)
	f.ds.docs[e.key] = e
	sync.mutex_unlock(&f.ds.mu)
	defer {
		delete_key(&f.ds.docs, e.key)
		delete(e.key, context.allocator)
		delete(e.rel_path, context.allocator)
		free(e, context.allocator)
	}
	stream := e.stream

	// No version, no pending, no watermark: a change waits.
	done, sup := svc.doc_sync_result_locked(e, stream, 5)
	testing.expect(t, !done, "an uncovered change must wait")

	// The watermark answers replaced-in-slot requests; a newer version
	// past the watermark still waits.
	e.watermark = 4
	e.has_watermark = true
	done, sup = svc.doc_sync_result_locked(e, stream, 4)
	testing.expect(t, done && sup, "a replaced-in-slot version answers superseded")
	done, sup = svc.doc_sync_result_locked(e, stream, 5)
	testing.expect(t, !done, "a version past the watermark waits")

	// A queued newer pending answers the older one immediately.
	e.has_pending = true
	e.pending = svc.Doc_Sync_Pending{stream = stream, version = 7, is_open = false}
	done, sup = svc.doc_sync_result_locked(e, stream, 6)
	testing.expect(t, done && sup, "a version under the queued pending answers superseded")

	// Applied coverage: at-or-below the applied version answers; the
	// watermark keeps a replaced request's answer honest. The watermark
	// moves to 6 here because that is what a real replace leaves: v7 took
	// v6's place in the slot before either applied.
	e.last_applied_version = 7
	e.has_version = true
	e.has_pending = false
	e.watermark = 6
	done, sup = svc.doc_sync_result_locked(e, stream, 6)
	testing.expect(t, done && sup, "a covered-and-replaced version answers superseded")
	done, sup = svc.doc_sync_result_locked(e, stream, 7)
	testing.expect(t, done && !sup, "the applied version answers as applied")

	// A re-open bumps the stream: the old stream's requests answer at once.
	done, sup = svc.doc_sync_result_locked(e, stream + 1, 1)
	testing.expect(t, done && sup, "a stream mismatch answers superseded")

	// A close answers everything left.
	e.is_closed = true
	done, sup = svc.doc_sync_result_locked(e, stream, 99)
	testing.expect(t, done && sup, "a closed document answers superseded")
}

// A change on a document whose buffer an eviction dropped re-opens the
// buffer ADOPTING the client text — never the stale disk bytes.
@(test)
doc_sync_change_after_eviction_adopts_client_text :: proc(t: ^testing.T) {
	f := doc_sync_fixture(t, 1, true)
	defer doc_sync_fixture_destroy(&f)

	disk_a := "package main\n\nfunc evict_a_disk() {}\n"
	disk_b := "package main\n\nfunc evict_b_disk() {}\n"
	doc_sync_write_file(&f, "evict_a.go", disk_a)
	doc_sync_write_file(&f, "evict_b.go", disk_b)
	doc_sync_warm_hot(t, &f.src.hot, "evict_a.go", disk_a)
	doc_sync_warm_hot(t, &f.src.hot, "evict_b.go", disk_b)

	deadline := platform.mono_ms() + 10_000
	text_a := "package main\n\nfunc evict_a_client() {}\n"
	_, oerr := svc.doc_sync_open(f.ds, "evict_a.go", "go", 1, text_a, nil, deadline, context.temp_allocator)
	testing.expectf(t, oerr == nil, "open a failed: %v", oerr)
	if oerr != nil {
		return
	}
	testing.expect_value(t, ts.hot_pinned_count(&f.src.hot), 1)

	// Opening b evicts a through the ordinary close path (the bound is 1).
	// The apply's answer can outrun its post-apply prune, so the eviction
	// checkpoints run the bound pass explicitly before asserting.
	text_b := "package main\n\nfunc evict_b_client() {}\n"
	_, oerr = svc.doc_sync_open(f.ds, "evict_b.go", "go", 1, text_b, nil, deadline, context.temp_allocator)
	testing.expectf(t, oerr == nil, "open b failed: %v", oerr)
	if oerr != nil {
		return
	}
	editor.editor_prune_buffers(f.e, "evict_b.go")
	testing.expect(t, doc_sync_buffer_of(f.e, "evict_a.go") == nil, "the bound must have evicted a")
	testing.expect_value(t, ts.hot_pinned_count(&f.src.hot), 1)

	text_a2 := "package main\n\nfunc evict_a_client_v2() {}\n"
	outcome, cerr := svc.doc_sync_change(f.ds, "evict_a.go", 2, text_a2, nil, deadline, context.temp_allocator)
	testing.expectf(t, cerr == nil, "change after eviction failed: %v", cerr)
	if cerr != nil {
		return
	}
	testing.expect(t, !outcome.superseded, "the re-opening change must apply")

	buf := doc_sync_buffer_of(f.e, "evict_a.go")
	testing.expect(t, buf != nil, "the change must re-open the evicted buffer")
	if buf != nil {
		testing.expect_value(t, buf.contents, text_a2)
	}
	disk := doc_sync_read_disk(&f, "evict_a.go")
	defer delete(disk, context.allocator)
	testing.expect(t, strings.contains(disk, "func evict_a_disk"), "the disk must stay untouched")
	// The re-opened a evicted b; the explicit bound pass makes the pin
	// checkpoint independent of the apply's own prune timing.
	editor.editor_prune_buffers(f.e, "evict_a.go")
	testing.expect_value(t, ts.hot_pinned_count(&f.src.hot), 1)
	v, has := svc.doc_sync_last_applied_version(f.ds, "evict_a.go")
	testing.expect(t, has && v == 2, "the version home advanced across the eviction")
}

// The editor seam itself: adopt creates the buffer from the given text
// without any disk read (the file need not exist), adopts differing text
// on a live buffer with the change notification, and treats an equal
// adopt as a no-op.
@(test)
doc_sync_buffer_adopt_seam :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "aubade-docseam-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	e := new(editor.Editor, context.allocator)
	editor.editor_init(e, dir, .Lf, "", svc.editor_file_io_port(), context.allocator)
	defer {
		editor.editor_destroy(e)
		free(e, context.allocator)
	}

	rec := new(Event_Rec, context.allocator)
	rec.events = make([dynamic]Rec_Event, 0, 4, context.allocator)
	defer {
		delete(rec.events)
		free(rec, context.allocator)
	}
	editor.editor_set_listener(e, {on_open = rec_open, on_change = rec_change, on_close = rec_close, user = rec})

	// buffer_adopt's contract is a held file lock; the helper provides it
	// (the release pairs by path — the handle itself is not needed).
	doc_sync_seam_adopt :: proc(e: ^editor.Editor, rel, text: string) -> ^editor.File_Buffer {
		editor.file_lock(e, rel)
		defer editor.file_release(e, rel)
		return editor.buffer_adopt(e, rel, text)
	}

	// No file on disk at all: the adopt creates the buffer from the text
	// and fires the open notification.
	text := "adopted\ncontents\n"
	buf := doc_sync_seam_adopt(e, "seam.go", text)
	testing.expect(t, buf != nil, "adopt must create the buffer")
	testing.expect_value(t, buf.contents, text)
	testing.expect_value(t, len(rec.events), 1)
	testing.expect_value(t, rec.events[0].kind, "open")
	testing.expect_value(t, rec.events[0].path, "seam.go")

	// A differing adopt updates in place with the change notification.
	text2 := "adopted\ncontents two\n"
	buf2 := doc_sync_seam_adopt(e, "seam.go", text2)
	testing.expect(t, buf2 == buf, "the adopt reuses the live buffer")
	testing.expect_value(t, buf.contents, text2)
	testing.expect_value(t, len(rec.events), 2)
	testing.expect_value(t, rec.events[1].kind, "change")

	// An equal adopt is a no-op: no version bump, no notification.
	version_before := buf.version
	buf3 := doc_sync_seam_adopt(e, "seam.go", text2)
	testing.expect(t, buf3 == buf && buf.version == version_before, "an equal adopt changes nothing")
	testing.expect_value(t, len(rec.events), 2)
}

// --- channel transport (the wire face) ---------------------------------------

doc_sync_pair_warm :: proc(t: ^testing.T, d: ^daemon.Daemon, rel, disk_text: string) {
	doc_sync_warm_hot(t, &d.ts.hot, rel, disk_text)
}

@(test)
doc_sync_channel_open_change_close :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)
	// The startup warm crawl indexes the fixture from disk; waiting for it
	// keeps the disk rows from landing after the test's newer ones.
	testing.expect(t, wait_index_warm(pair, 10_000), "index warm timed out")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	svc_symbol_write_file(t, pair.tmp, "wire.go", "package main\n\nfunc wire_base() {}\n")
	doc_sync_pair_warm(t, pair.daemon, "wire.go", "package main\n\nfunc wire_base() {}\n")

	open_call := svc.client_doc_open(pair.conn, "wire.go", "go", 1, "package main\n\nfunc wire_open() {}\n", alloc, deadline)
	testing.expect_value(t, open_call.call_err, jsonrpc.Call_Err.None)
	if open_call.call_err != .None {
		return
	}
	testing.expect_value(t, jsonutil.obj_get_int(open_call.result, "version"), 1)
	superseded, _ := json_bool_field(open_call.result, "superseded")
	testing.expect(t, !superseded, "a plain open answers as applied")

	// Daemon side: the buffer adopted the open's text and the hot tree is
	// pinned for it.
	buf := doc_sync_buffer_of(pair.daemon.ed, "wire.go")
	testing.expect(t, buf != nil, "the buffer must exist after the wire open")
	if buf != nil {
		testing.expect_value(t, buf.contents, "package main\n\nfunc wire_open() {}\n")
	}
	testing.expect_value(t, ts.hot_pinned_count(&pair.daemon.ts.hot), 1)

	change_call := svc.client_doc_change(pair.conn, "wire.go", 2, "package main\n\nfunc wire_open() {}\n\nfunc wire_marker() {}\n", alloc, deadline)
	testing.expect_value(t, change_call.call_err, jsonrpc.Call_Err.None)
	if change_call.call_err != .None {
		return
	}
	testing.expect_value(t, jsonutil.obj_get_int(change_call.result, "version"), 2)

	// The applied change's effects through the one listener: the hot tree
	// tracks the new text, and the L0 rows do not — the rewrite waits for
	// the file's first reader (the symbol_find heal).
	e, ok := ts.hot_acquire(&pair.daemon.ts.hot, "wire.go")
	testing.expect(t, ok, "hot entry must exist")
	if ok {
		testing.expect(t, strings.contains(e.source, "func wire_marker"), "the hot tree tracks the applied text")
		ts.hot_release(&pair.daemon.ts.hot, "wire.go", e)
	}
	rows, lerr := store.symbol_names_lookup(pair.daemon.db, "wire_marker", context.temp_allocator)
	testing.expectf(t, lerr == nil, "symbol lookup failed: %v", lerr)
	for r in rows {
		testing.expectf(t, r.path != "wire.go", "the L0 rows must not answer for the applied text before a reader arrives")
	}

	v, has := svc.doc_sync_last_applied_version(pair.daemon.doc_sync, "wire.go")
	testing.expect(t, has && v == 2, "the version home advanced on the daemon")

	close_call := svc.client_doc_close(pair.conn, "wire.go", alloc, deadline)
	testing.expect_value(t, close_call.call_err, jsonrpc.Call_Err.None)
	testing.expect_value(t, ts.hot_pinned_count(&pair.daemon.ts.hot), 0)
	_, has = svc.doc_sync_last_applied_version(pair.daemon.doc_sync, "wire.go")
	testing.expect(t, !has, "the version record cleared")
	testing.expect(t, doc_sync_buffer_of(pair.daemon.ed, "wire.go") == nil, "the buffer dropped on close")

	again := svc.client_doc_close(pair.conn, "wire.go", alloc, deadline)
	testing.expect_value(t, again.call_err, jsonrpc.Call_Err.None)
}

// The wire storm: rapid changes over the channel coalesce through the
// daemon's pending slot; every request answers, and the newest one
// answers applied with the final version. Submissions chain on the slot
// (see doc_sync_wait_pending_version) so the arrival order — and with it
// the final text — is deterministic.
@(test)
doc_sync_channel_storm :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)
	testing.expect(t, wait_index_warm(pair, 10_000), "index warm timed out")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	svc_symbol_write_file(t, pair.tmp, "cstorm.go", "package main\n\nfunc cstorm_base() {}\n")
	doc_sync_pair_warm(t, pair.daemon, "cstorm.go", "package main\n\nfunc cstorm_base() {}\n")

	open_call := svc.client_doc_open(pair.conn, "cstorm.go", "go", 1, "package main\n\nfunc cstorm_base() {}\n", alloc, deadline)
	testing.expect_value(t, open_call.call_err, jsonrpc.Call_Err.None)
	if open_call.call_err != .None {
		return
	}

	versions := [4]i32{2, 3, 4, 5}
	texts := [4]string{
		"package main\n\nfunc cstorm_v2() {}\n",
		"package main\n\nfunc cstorm_v3() {}\n",
		"package main\n\nfunc cstorm_v4() {}\n",
		"package main\n\nfunc cstorm_v5_marker() {}\n",
	}
	jobs: [4]^Doc_Sync_Wire_Job
	threads: [4]^thread.Thread
	for i in 0..<4 {
		jobs[i] = new(Doc_Sync_Wire_Job, context.allocator)
		jobs[i]^ = {conn = pair.conn, rel = "cstorm.go", version = versions[i], text = texts[i]}
		threads[i] = thread.create_and_start_with_poly_data(jobs[i], doc_sync_wire_change_entry, self_cleanup = false)
		if !doc_sync_wait_pending_version(t, pair.daemon.doc_sync, "cstorm.go", versions[i]) {
			break
		}
	}
	for i in 0..<4 {
		if threads[i] != nil {
			thread.join(threads[i])
			free(threads[i], context.allocator)
		}
	}
	for i in 0..<4 {
		if jobs[i] == nil {
			continue
		}
		testing.expectf(t, jobs[i].call_err == jsonrpc.Call_Err.None, "change v%d failed: %v", versions[i], jobs[i].call_err)
	}
	// The newest request answers as applied with the final version.
	if jobs[3] != nil {
		testing.expect(t, !jobs[3].superseded, "the newest change must apply")
		testing.expect_value(t, jobs[3].answer_version, 5)
	}
	for i in 0..<4 {
		if jobs[i] != nil {
			free(jobs[i], context.allocator)
		}
	}

	buf := doc_sync_buffer_of(pair.daemon.ed, "cstorm.go")
	testing.expect(t, buf != nil, "the buffer must exist after the storm")
	if buf != nil {
		testing.expect_value(t, buf.contents, texts[3])
	}
	v, has := svc.doc_sync_last_applied_version(pair.daemon.doc_sync, "cstorm.go")
	testing.expect(t, has && v == 5, "the version home carries the final version")
	stale_rows, lerr := store.symbol_names_lookup(pair.daemon.db, "cstorm_v2", context.temp_allocator)
	testing.expectf(t, lerr == nil, "stale symbol lookup failed: %v", lerr)
	testing.expect_value(t, len(stale_rows), 0)
	// The storm wrote no rows at all: nothing read cstorm.go, so even the
	// newest text's symbol is not indexed yet — the rewrite waits for a
	// reader.
	final_rows, ferr := store.symbol_names_lookup(pair.daemon.db, "cstorm_v5_marker", context.temp_allocator)
	testing.expectf(t, ferr == nil, "final symbol lookup failed: %v", ferr)
	for r in final_rows {
		testing.expectf(t, r.path != "cstorm.go", "the storm must not index the newest text without a reader")
	}
}

Doc_Sync_Wire_Job :: struct {
	conn:           ^jsonrpc.Conn,
	rel:            string,
	version:        i32,
	text:           string,
	call_err:       jsonrpc.Call_Err,
	answer_version: i64,
	superseded:     bool,
}

doc_sync_wire_change_entry :: proc(job: ^Doc_Sync_Wire_Job) {
	call := svc.client_doc_change(job.conn, job.rel, job.version, job.text, context.temp_allocator, platform.mono_ms() + 10_000)
	job.call_err = call.call_err
	if call.call_err == .None {
		job.answer_version = jsonutil.obj_get_int(call.result, "version")
		job.superseded, _ = json_bool_field(call.result, "superseded")
	}
}

// A read-only project refuses the mutating document-sync face at the
// boundary; the editor surface degrades to serving disk state there.
@(test)
doc_sync_channel_read_only_refusal :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	svc_symbol_write_file(t, pair.tmp, "ro.go", "package main\n\nfunc ro_base() {}\n")
	pair.daemon.cfg.read_only = true

	call := svc.client_doc_open(pair.conn, "ro.go", "go", 1, "package main\n\nfunc ro_client() {}\n", alloc, deadline)
	testing.expect_value(t, call.call_err, jsonrpc.Call_Err.Error_Response)
	if call.call_err != .Error_Response {
		return
	}
	testing.expect_value(t, call.err_code, jsonrpc.Err_Code.Invalid_Request)
	testing.expect(t, strings.contains(call.err_message, "read-only"), "the refusal names the read-only project")

	buf := doc_sync_buffer_of(pair.daemon.ed, "ro.go")
	testing.expect(t, buf == nil, "the refused open must not create a buffer")
}

// --- the stream-generation ABA regression -----------------------------------

// Doc_Sync_Listener_Log records the buffer adoptions the apply worker
// performs, as the one installed listener (the recorder replaces the
// fixture's bridge for the test's scope). The events clone into the log's
// own allocator: the callback runs on the WORKER thread, whose temp
// allocator its frame loop resets — a temp-allocated event would die
// with the frame that produced it.
Doc_Sync_Listener_Log :: struct {
	events:    [dynamic]string, // "open:<text>" / "change:<text>" per callback
	allocator: mem.Allocator,
}

doc_sync_listener_open :: proc(user: rawptr, rel_path: string, contents: string) {
	log := cast(^Doc_Sync_Listener_Log)user
	append(&log.events, strings.concatenate({"open:", contents}, log.allocator))
}

doc_sync_listener_change :: proc(user: rawptr, rel_path: string, contents: string) {
	log := cast(^Doc_Sync_Listener_Log)user
	append(&log.events, strings.concatenate({"change:", contents}, log.allocator))
}

// A close that frees the entry (nobody waits) followed by a re-open
// recreates it, and a per-entry stream counter would restart at the very
// value an in-flight apply item of the OLD generation carries — the
// worker's staleness and record checks would match the NEW generation and
// adopt the closed session's text under it. Streams come from the face's
// counter, so the staged first-generation item is stale and only the
// re-opened generation's text is ever adopted: exactly one open event, of
// the second text.
@(test)
doc_sync_stream_survives_entry_recreation :: proc(t: ^testing.T) {
	f := doc_sync_fixture(t, editor.EDITOR_MAX_BUFFERS, false)
	defer doc_sync_fixture_destroy(&f)

	log := new(Doc_Sync_Listener_Log, context.allocator)
	log^ = {events = make([dynamic]string, 0, 4, context.allocator), allocator = context.allocator}
	defer {
		for e in log.events {
			delete(e, log.allocator)
		}
		delete(log.events)
		free(log, context.allocator)
	}
	editor.editor_set_listener(f.e, {on_open = doc_sync_listener_open, on_change = doc_sync_listener_change, user = log})

	token := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(token)
	// token_destroy owns the struct's own free (its contract ends in
	// free(t, a)) — the caller frees nothing after it.
	defer platform.token_destroy(token, context.allocator)
	platform.token_fire(token, .Shutdown)

	text1 := "package main\n\nfunc generation_one() {}\n"
	text2 := "package main\n\nfunc generation_two() {}\n"
	deadline := platform.mono_ms() + 10_000

	// Generation one: the open parks on the fired token and answers
	// Cancelled at once, but its full text stays queued for the worker.
	_, oerr := svc.doc_sync_open(f.ds, "aba.go", "go", 1, text1, token, deadline, context.temp_allocator)
	testing.expectf(t, oerr != nil, "the cancelled open must answer an error")
	// The close frees the entry (no waiters remain); the re-open below
	// creates a fresh one.
	cerr := svc.doc_sync_close(f.ds, "aba.go", context.temp_allocator)
	testing.expectf(t, cerr == nil, "close failed: %v", cerr)
	if cerr != nil {
		return
	}
	// Generation two: queued behind the first generation's item.
	_, oerr2 := svc.doc_sync_open(f.ds, "aba.go", "go", 2, text2, token, deadline, context.temp_allocator)
	testing.expectf(t, oerr2 != nil, "the cancelled re-open must answer an error")

	// The worker starts AFTER both generations are staged: it drains the
	// first item (stale — its stream belongs to a freed generation) and
	// then the second (applies). The fixture's destroy ladder stops and
	// joins the worker it now owns.
	f.worker = thread.create_and_start_with_poly_data(f.ds, doc_sync_worker_entry, self_cleanup = false)

	deadline = platform.mono_ms() + 10_000
	for {
		v, has := svc.doc_sync_last_applied_version(f.ds, "aba.go")
		if has && v == 2 {
			break
		}
		if platform.mono_ms() >= deadline {
			testing.expectf(t, false, "the re-opened generation never applied (v=%d has=%v)", v, has)
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	testing.expect_value(t, len(log.events), 1)
	if len(log.events) == 1 {
		want := strings.concatenate({"open:", text2}, context.temp_allocator)
		testing.expectf(t, log.events[0] == want, "the single adoption must be the second generation's text, got %q", log.events[0])
	}
	buf := doc_sync_buffer_of(f.e, "aba.go")
	testing.expect(t, buf != nil, "the buffer must exist after the apply")
	if buf != nil {
		testing.expect_value(t, buf.contents, text2)
	}
}
