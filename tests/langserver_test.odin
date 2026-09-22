// langserver component tests: the registry's detection semantics, the
// runtime prerequisite checks, the project language scan, and the
// manager lifecycle (start, status, restart-after-death, failure
// cooldown, idle reclamation, eager start) against an in-process fake
// factory that reuses the LSP fake-server wire harness. The production
// factory gets one real-process smoke test (a minimal python3 LSP over
// stdio). No sleeps: cooldown and idle tests drive a virtual clock.
package tests

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "src:config"
import "src:jsonrpc"
import "src:langserver"
import "src:lsp"
import "src:platform"

// A shell everyone has (POSIX) / the Windows command interpreter.
when ODIN_OS == .Windows {
	SH_NAME :: "cmd"
} else {
	SH_NAME :: "sh"
}

// --- the fake factory ----------------------------------------------------
//
// The fake factory speaks no wire protocol: it fabricates the completed
// handshake state on a real Client over in-memory pipes, so manager
// lifecycle tests exercise tables, threads, and teardown without the
// protocol layer (the wire handshake itself is covered by the lsp pair
// suite and the production stdio smoke test). Fakes die by connection
// close, exactly how server_alive observes death.

Fake_Peer :: struct {
	up, down: Pipe,
}

Fake_Factory :: struct {
	mu:            sync.Mutex, // peers + mutable fields below (create runs on worker threads)
	allocator:     mem.Allocator, // mutex-wrapped; shared with the manager
	peers:         [dynamic]^Fake_Peer,
	fail_next:     bool,
	// Test hooks: park_language parks create() for that language until
	// its cancel token fires (real-time slices, hard cap — a regression
	// must fail assertions, not hang the runner); entered counts create()
	// entries including parked ones. park_success_language parks create()
	// until release_parked is set and then SUCCEEDS — the shape the
	// restart-after-destroy guard needs (a create finishing after a
	// concurrent manager_destroy).
	park_language:         string,
	park_success_language: string,
	release_parked:        bool,
	entered:               int,
	last_argv:     []string, // most recent create argv, cloned onto alloc
	last_folders:  []string, // most recent create folder paths, cloned onto alloc
}

fake_peer_cleanup :: proc(peer: ^Fake_Peer) {
	pipe_close(&peer.up)
	pipe_close(&peer.down)
	free(peer, context.allocator)
}

fake_ls_create :: proc(
	user:            rawptr,
	entry:           ^langserver.Entry,
	argv:            []string,
	env:             []string,
	folders:         []langserver.Workspace_Folder,
	memory_limit_mb: int,
	clock:           ^platform.Clock,
	a:               mem.Allocator,
	token:           ^platform.Cancel_Token,
) -> (s: ^langserver.Server, err: platform.Err) {
	ff := cast(^Fake_Factory)user
	// The create call runs on the caller's thread; route every implicit
	// allocation through the wrapped allocator the harness shares with
	// the manager.
	context.allocator = ff.allocator

	sync.mutex_lock(&ff.mu)
	fail := ff.fail_next
	if fail {
		ff.fail_next = false
	}
	ff.entered += 1
	park := ff.park_language != "" && ff.park_language == entry.id
	park_ok := ff.park_success_language != "" && ff.park_success_language == entry.id
	// The argv and folder views die with the caller's request arena —
	// record clones so tests can inspect what the manager resolved.
	if ff.last_argv != nil {
		langserver.free_strings(ff.last_argv, ff.allocator)
	}
	ff.last_argv = langserver.clone_strings(argv, ff.allocator)
	if ff.last_folders != nil {
		langserver.free_strings(ff.last_folders, ff.allocator)
	}
	folder_paths := make([]string, len(folders), context.temp_allocator)
	for i in 0..<len(folders) {
		folder_paths[i] = folders[i].path
	}
	ff.last_folders = langserver.clone_strings(folder_paths, ff.allocator)
	sync.mutex_unlock(&ff.mu)
	if fail {
		return nil, platform.Err(.Internal)
	}
	if park {
		// Park until the start's cancel token fires. Real-time slices
		// with a hard cap (~2 s): a regression that hands the eager walk
		// a nil token makes the walk give up and fail the test's
		// assertions instead of hanging the runner.
		for i := 0; i < 400; i += 1 {
			if token != nil {
				if _, fired := platform.token_check(token); fired {
					return nil, platform.Err(.Cancelled)
				}
			}
			time.sleep(5 * time.Millisecond)
		}
		return nil, platform.Err(.Timeout)
	}
	if park_ok {
		// Park until the test releases, then succeed: same real-time
		// slices and hard cap as the cancel-park above.
		released := false
		for i := 0; i < 400; i += 1 {
			sync.mutex_lock(&ff.mu)
			released = ff.release_parked
			sync.mutex_unlock(&ff.mu)
			if released {
				break
			}
			time.sleep(5 * time.Millisecond)
		}
		if !released {
			return nil, platform.Err(.Timeout)
		}
	}

	peer := new(Fake_Peer, a)
	pipe_init(&peer.up, a)
	pipe_init(&peer.down, a)

	client_conn := new(jsonrpc.Conn, a)
	cr: jsonrpc.Reader
	jsonrpc.reader_init(&cr, pipe_read, &peer.down, 64 * 1024, a)
	cw: jsonrpc.Writer
	jsonrpc.writer_init(&cw, pipe_write, &peer.up)
	jsonrpc.conn_init(client_conn, cr, cw, a)

	client := new(lsp.Client, a)
	lsp.client_init(client, client_conn, clock, entry.id, a)
	// The fabricated handshake: initialized with a plausible capability
	// view. No reader thread exists, so nothing would answer a real
	// initialize request — by design (see the block comment above).
	client.is_initialized = true
	client.caps = {
		sync_kind = .Full,
		definition = true,
		document_symbol = true,
	}

	s = new(langserver.Server, a)
	s^ = {
		language_id = strings.clone(entry.id, a),
		entry       = entry,
		folders     = langserver.clone_strings(folder_paths, a),
		client      = client,
		conn        = client_conn,
		allocator       = a,
	}

	sync.mutex_lock(&ff.mu)
	append(&ff.peers, peer)
	sync.mutex_unlock(&ff.mu)
	return s, nil
}

// --- the manager test harness ---------------------------------------------

LS_Test :: struct {
	mu:        mem.Mutex_Allocator,
	allocator: mem.Allocator,
	reg:       ^langserver.Registry,
	m:         ^langserver.Manager,
	clock:     ^platform.Clock,
	ff:        ^Fake_Factory,
	root:      string,
}

// ls_test_init builds a registry with one synthetic language ("tst"), a
// fake factory, and a manager. The mutex-wrapped allocator backs every
// cross-thread allocation.
ls_test_init :: proc(t: ^testing.T, virtual_clock: bool, allow: []string, eager: bool) -> ^LS_Test {
	lt := new(LS_Test, context.allocator)
	mem.mutex_allocator_init(&lt.mu, context.allocator)
	lt.allocator = mem.mutex_allocator(&lt.mu)

	lt.reg = langserver.registry_build(lt.allocator)
	langserver.registry_add(lt.reg, {
		id            = "tst",
		display_name  = "Test",
		file_patterns = {"*.tst"},
		priority      = langserver.PRIORITY_NORMAL,
		command       = "tst-server",
	})

	lt.clock = new(platform.Clock, lt.allocator)
	platform.clock_init(lt.clock, virtual_clock, lt.allocator)

	lt.root = "/proj"

	lt.ff = new(Fake_Factory, lt.allocator)
	lt.ff^ = {allocator = lt.allocator}
	lt.ff.peers = make([dynamic]^Fake_Peer, 0, 4, lt.allocator)

	lt.m = new(langserver.Manager, lt.allocator)
	langserver.manager_init(
		lt.m, lt.reg, lt.root, lt.clock, {user = lt.ff, create = fake_ls_create}, allow, eager, lt.allocator,
	)
	return lt
}

// ls_test_destroy joins and frees everything the harness created. The
// fake peers (bare pipes now) outlive their servers by design — the
// manager frees only the client side — and go last.
ls_test_destroy :: proc(lt: ^LS_Test) {
	langserver.manager_destroy(lt.m)
	free(lt.m, lt.allocator)

	for peer in lt.ff.peers {
		fake_peer_cleanup(peer)
	}
	delete(lt.ff.peers)
	langserver.free_strings(lt.ff.last_argv, lt.allocator)
	langserver.free_strings(lt.ff.last_folders, lt.allocator)
	free(lt.ff, lt.allocator)

	langserver.registry_destroy(lt.reg)
	platform.clock_destroy(lt.clock)
	free(lt.clock, lt.allocator)
	free(lt, context.allocator)
}

ls_peer_count :: proc(lt: ^LS_Test) -> int {
	sync.mutex_lock(&lt.ff.mu)
	n := len(lt.ff.peers)
	sync.mutex_unlock(&lt.ff.mu)
	return n
}

ls_fail_next :: proc(lt: ^LS_Test) {
	sync.mutex_lock(&lt.ff.mu)
	lt.ff.fail_next = true
	sync.mutex_unlock(&lt.ff.mu)
}

ls_set_park :: proc(lt: ^LS_Test, language: string) {
	sync.mutex_lock(&lt.ff.mu)
	lt.ff.park_language = language
	sync.mutex_unlock(&lt.ff.mu)
}

ls_entered_count :: proc(lt: ^LS_Test) -> int {
	sync.mutex_lock(&lt.ff.mu)
	n := lt.ff.entered
	sync.mutex_unlock(&lt.ff.mu)
	return n
}

// ls_last_argv returns the most recent create argv (owned by the fake;
// valid until the next create or destroy).
ls_last_argv :: proc(lt: ^LS_Test) -> []string {
	sync.mutex_lock(&lt.ff.mu)
	argv := lt.ff.last_argv
	sync.mutex_unlock(&lt.ff.mu)
	return argv
}

// ls_last_folders returns the most recent create folder paths (owned by
// the fake; valid until the next create or destroy).
ls_last_folders :: proc(lt: ^LS_Test) -> []string {
	sync.mutex_lock(&lt.ff.mu)
	folders := lt.ff.last_folders
	sync.mutex_unlock(&lt.ff.mu)
	return folders
}

LS_Override_Pair :: struct {
	lang: string,
	argv: []string,
}

// ls_overrides builds an override map on the harness allocator; the caller
// frees it with langserver.free_string_array_map after handing it to
// manager_set_overrides (which takes its own copy).
ls_overrides :: proc(lt: ^LS_Test, pairs: []LS_Override_Pair) -> map[string][]string {
	m := make(map[string][]string, len(pairs), lt.allocator)
	for p in pairs {
		// The pair's key is static test data — clone it so the map is
		// wholly owned by the harness allocator.
		m[strings.clone(p.lang, lt.allocator)] = langserver.clone_strings(p.argv, lt.allocator)
	}
	return m
}

// --- registry ---------------------------------------------------------------

@(test)
langserver_registry_shape :: proc(t: ^testing.T) {
	reg := langserver.registry_build(context.allocator)
	defer langserver.registry_destroy(reg)

	testing.expect(t, langserver.registry_count(reg) == 55)

	go_entry := langserver.registry_detect(reg, "src/main.go")
	if go_entry == nil {
		testing.expectf(t, false, "detect(.go) returned nil")
		return
	}
	testing.expect(t, go_entry.id == "go")

	py_entry := langserver.registry_detect(reg, "pkg/x.PYI")
	if py_entry == nil {
		testing.expectf(t, false, "detect(.PYI) returned nil")
		return
	}
	testing.expect(t, py_entry.id == "python")

	// cpp beats the experimental ccls alternate for the same extension.
	cpp_entry := langserver.registry_detect(reg, "lib/util.cpp")
	if cpp_entry == nil {
		testing.expectf(t, false, "detect(.cpp) returned nil")
		return
	}
	testing.expect(t, cpp_entry.id == "cpp")

	cs_entry := langserver.registry_detect(reg, "src/App.cs")
	if cs_entry == nil {
		testing.expectf(t, false, "detect(.cs) returned nil")
		return
	}
	testing.expect(t, cs_entry.id == "csharp")

	vue_entry := langserver.registry_detect(reg, "ui/App.vue")
	if vue_entry == nil {
		testing.expectf(t, false, "detect(.vue) returned nil")
		return
	}
	testing.expect(t, vue_entry.id == "vue")

	testing.expect(t, langserver.registry_detect(reg, "nope.xyz") == nil)
	testing.expect(t, langserver.registry_detect(reg, "noext") == nil)
	testing.expect(t, langserver.registry_find(reg, "definitely-missing") == nil)

	erl := langserver.registry_detect_filename(reg, "some.app.src")
	if erl == nil {
		testing.expectf(t, false, "detect_filename(.app.src) returned nil")
		return
	}
	testing.expect(t, erl.id == "erlang")

	ids := langserver.registry_all_ids(reg, context.temp_allocator)
	testing.expect(t, len(ids) == 55)

	non_exp := langserver.registry_non_experimental(reg, context.temp_allocator)
	testing.expect(t, len(non_exp) == 42) // 55 registered, 13 experimental

	keep := langserver.registry_filter_registered(reg, {"go", "nope", "odin"}, context.temp_allocator)
	testing.expect(t, len(keep) == 2)
	if len(keep) == 2 {
		testing.expect(t, keep[0] == "go" && keep[1] == "odin")
	}

	// The Go normalize hook splits receiver-qualified methods.
	if go_entry.normalize != nil {
		name, recv := go_entry.normalize(.Method, "(*Client).Call", "src/client.go")
		testing.expect(t, name == "Call")
		testing.expect(t, recv == "Client")
		name2, recv2 := go_entry.normalize(.Function, "plain.func", "src/x.go")
		testing.expect(t, name2 == "plain.func" && recv2 == "")
	} else {
		testing.expectf(t, false, "go entry has no normalize hook")
	}
}

@(test)
langserver_multi_root_entries :: proc(t: ^testing.T) {
	reg := langserver.registry_build(context.allocator)
	defer langserver.registry_destroy(reg)

	markers_match :: proc(got: []string, want: []string) -> bool {
		if len(got) != len(want) {
			return false
		}
		for w in want {
			found := false
			for g in got {
				if g == w {
					found = true
					break
				}
			}
			if !found {
				return false
			}
		}
		return true
	}

	// Only entries whose server is verified to consume multiple workspace
	// folders carry root markers; everything else (typescript-language-
	// server, for one, keeps a single workspace root) stays unclassified
	// so its initialize wire shape is unchanged.
	check :: proc(
		t: ^testing.T, reg: ^langserver.Registry,
		id: string, markers: []string, multi: bool,
	) {
		e := langserver.registry_find(reg, id)
		if e == nil {
			testing.expectf(t, false, "registry_find(%s) returned nil", id)
			return
		}
		if !markers_match(e.root_markers, markers) {
			testing.expectf(
				t, false, "%s root markers mismatch (got %d entries, want %v)",
				id, len(e.root_markers), markers,
			)
		}
		testing.expectf(t, e.multi_root == multi, "%s multi_root mismatch", id)
	}

	check(t, reg, "go",         {"go.mod"},                        true)
	check(t, reg, "odin",       {"ols.json", ".git"},              true)
	check(t, reg, "rust",       {"Cargo.toml"},                    true)
	check(t, reg, "dart",       {"pubspec.yaml"},                  true)
	check(t, reg, "swift",      {"Package.swift"},                 true)
	check(t, reg, "cpp",        {".git", "compile_commands.json"}, true)
	check(t, reg, "typescript", nil,                               false)
}

// --- runtime checks -----------------------------------------------------------

@(test)
langserver_runtime_checks :: proc(t: ^testing.T) {
	testing.expect(t, langserver.binary_available(SH_NAME))
	testing.expect(t, !langserver.binary_available("aubade-definitely-missing-xyz"))

	good := langserver.Entry{
		required_binaries = {{name = SH_NAME, display_name = "shell"}},
	}
	testing.expect(t, langserver.default_check_runtime(&good, context.temp_allocator) == nil)

	bad := langserver.Entry{
		required_binaries = {{name = "aubade-definitely-missing-xyz", display_name = "Missing"}},
	}
	err := langserver.default_check_runtime(&bad, context.temp_allocator)
	testing.expect(t, platform.err_kind(err) == .NotFound)

	any_bad := langserver.Entry{
		required_any_of = {{names = {"nope-a", "nope-b"}, display_name = "Neither"}},
	}
	err2 := langserver.default_check_runtime(&any_bad, context.temp_allocator)
	testing.expect(t, platform.err_kind(err2) == .NotFound)

	any_good := langserver.Entry{
		required_any_of = {{names = {"nope-a", SH_NAME}, display_name = "Either"}},
	}
	testing.expect(t, langserver.default_check_runtime(&any_good, context.temp_allocator) == nil)

	testing.expect(t, langserver.clean_env_path("..") == "")
	testing.expect(t, langserver.clean_env_path("../x") == "")
	testing.expect(t, langserver.clean_env_path("") == "")
	testing.expect(t, langserver.clean_env_path("/usr/local") == "/usr/local")
}

// --- project scan --------------------------------------------------------------

scan_mk_file :: proc(root, rel: string, content: string) {
	p, _ := filepath.join({root, rel}, context.temp_allocator)
	f, err := os.open(p, {.Write, .Create, .Excl}, os.Permissions{.Read_User, .Write_User})
	if err != nil {
		return
	}
	_ = platform.write_all(f, transmute([]u8)content)
	os.close(f)
}

scan_mk_dir :: proc(root, rel: string) {
	p, _ := filepath.join({root, rel}, context.temp_allocator)
	_ = os.make_directory_all(p, os.Permissions{.Read_User, .Write_User, .Execute_User})
}

@(test)
langserver_scan_project_languages :: proc(t: ^testing.T) {
	root, derr := os.make_directory_temp("", "aubade-ls-scan-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp dir failed")
		return
	}
	defer delete(root, context.allocator)
	defer _ = os.remove_all(root)

	mk := "package main\n"
	scan_mk_dir(root, "sub")
	scan_mk_file(root, "a.go", mk)
	scan_mk_file(root, "b.py", "x = 1\n")
	scan_mk_file(root, "d.ts", "let x: number\n")
	scan_mk_file(root, "sub/c.go", "package sub\n")
	scan_mk_dir(root, "node_modules")
	scan_mk_file(root, "node_modules/skip.js", "skip\n")
	scan_mk_dir(root, "vendor")
	scan_mk_file(root, "vendor/skip2.py", "skip\n")

	reg := langserver.registry_build(context.allocator)
	defer langserver.registry_destroy(reg)
	res := langserver.scan_project_languages(root, reg, context.allocator)

	testing.expect(t, len(res.ids) == 3)
	if len(res.ids) == 3 {
		// go (2 files) first; python and typescript tie on 1 and break by id.
		testing.expect(t, res.ids[0] == "go")
		testing.expect(t, res.ids[1] == "python")
		testing.expect(t, res.ids[2] == "typescript")
	}
	testing.expect(t, res.counts["go"] == 2)
	testing.expect(t, res.counts["python"] == 1)
	testing.expect(t, res.counts["typescript"] == 1)

	for id in res.counts {
		delete(id, context.allocator)
	}
	delete(res.counts)
	for id in res.ids {
		delete(id, context.allocator)
	}
	delete(res.ids, context.allocator)
}

// --- manager lifecycle -----------------------------------------------------------

status_row :: proc(rows: []langserver.Status_Row, id: string) -> bool {
	for row in rows {
		if row.id == id {
			return row.running
		}
	}
	return false
}

free_status_rows :: proc(rows: []langserver.Status_Row, a := context.allocator) {
	for row in rows {
		delete(row.id, a)
		if row.root != "" {
			delete(row.root, a)
		}
	}
	delete(rows, a)
}

@(test)
langserver_manager_start_stop_status :: proc(t: ^testing.T) {
	lt := ls_test_init(t, false, {"go", "tst"}, false)
	defer ls_test_destroy(lt)

	testing.expect(t, ls_peer_count(lt) == 0)
	client, err := langserver.manager_ensure(lt.m, "tst", context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, client != nil)
	testing.expect(t, ls_peer_count(lt) == 1)

	rows := langserver.manager_status(lt.m, context.allocator)
	testing.expect(t, len(rows) == 2) // allowlist lists go + tst
	if len(rows) == 2 {
		testing.expect(t, !status_row(rows, "go"))
		testing.expect(t, status_row(rows, "tst"))
	}
	free_status_rows(rows)

	// The running server serves extension-matched file lookups.
	served, ok := langserver.manager_client_for_file(lt.m, "x.tst")
	testing.expect(t, ok && served == client)
	_, ok2 := langserver.manager_client_for_file(lt.m, "x.go")
	testing.expect(t, !ok2)

	testing.expect(t, langserver.manager_stop(lt.m, "tst") == nil)
	testing.expect(t, platform.err_kind(langserver.manager_stop(lt.m, "tst")) == .NotFound)
	testing.expect(t, ls_peer_count(lt) == 1) // the peer existed; the server is gone

	missing_client, missing_err := langserver.manager_ensure(lt.m, "no-such-language", context.temp_allocator)
	testing.expect(t, missing_client == nil)
	testing.expect(t, platform.err_kind(missing_err) == .NotFound)
}

// manager_start holds no hand-out: the ensure it rides on pins the client
// it returns, and a start that kept the pin parked its server on every
// later stop/restart — the retiring sweep's inflight gate skipped the
// teardown and a live process stayed behind a "stopped"/"restarted"
// answer. Both paths must retire-and-destroy synchronously.
@(test)
langserver_manager_start_leaves_no_pin :: proc(t: ^testing.T) {
	lt := ls_test_init(t, false, {"tst"}, false)
	defer ls_test_destroy(lt)

	testing.expect(t, langserver.manager_start(lt.m, "tst", context.temp_allocator) == nil)
	testing.expect(t, ls_peer_count(lt) == 1)

	testing.expect(t, langserver.manager_restart(lt.m, "tst", context.temp_allocator) == nil)
	testing.expect(t, langserver.manager_retiring_count(lt.m) == 0)
	testing.expect(t, ls_peer_count(lt) == 2)

	testing.expect(t, langserver.manager_stop(lt.m, "tst") == nil)
	testing.expect(t, langserver.manager_retiring_count(lt.m) == 0)
}

@(test)
langserver_manager_replaces_dead_server :: proc(t: ^testing.T) {
	lt := ls_test_init(t, false, {"tst"}, false)
	defer ls_test_destroy(lt)

	first, err := langserver.manager_ensure(lt.m, "tst", context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, ls_peer_count(lt) == 1)

	// Kill the server the way an in-process fake dies: the connection
	// closes. The next ensure must replace it.
	sync.mutex_lock(&lt.m.mu)
	dead := lt.m.servers["tst"]
	sync.mutex_unlock(&lt.m.mu)
	if dead == nil {
		testing.expectf(t, false, "server missing after ensure")
		return
	}
	jsonrpc.conn_close(dead.conn)

	second, err2 := langserver.manager_ensure(lt.m, "tst", context.temp_allocator)
	testing.expect(t, err2 == nil)
	testing.expect(t, second != nil && second != first)
	testing.expect(t, ls_peer_count(lt) == 2)

	rows := langserver.manager_status(lt.m, context.allocator)
	testing.expect(t, status_row(rows, "tst"))
	free_status_rows(rows)
}

// The daemon's langserver_start passes a language id that views the RPC
// request arena; when that memory is reused, every table key the manager
// stored as a view rots with it. The manager must own its keys: after the
// caller's bytes are poached in place, keyed lookups still find the
// server, a content-equal ensure reuses it, and the retire paths (the
// ones that once spun unboundedly at shutdown when delete_key missed)
// complete.
@(test)
langserver_manager_table_keys_survive_caller_memory :: proc(t: ^testing.T) {
	lt := ls_test_init(t, false, {"tst"}, false)
	defer ls_test_destroy(lt)

	lang := strings.clone("tst", lt.allocator)
	defer delete(lang, lt.allocator)
	client, err := langserver.manager_ensure(lt.m, lang, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, client != nil)
	testing.expect(t, ls_peer_count(lt) == 1)

	poison := transmute([]byte)lang
	for i in 0..<len(poison) {
		poison[i] = 0x78
	}

	rows := langserver.manager_status(lt.m, context.allocator)
	testing.expect(t, status_row(rows, "tst"))
	free_status_rows(rows)

	again, err2 := langserver.manager_ensure(lt.m, "tst", context.temp_allocator)
	testing.expect(t, err2 == nil)
	testing.expect(t, again == client) // reuse — a rotted key would restart under a fresh one
	testing.expect(t, ls_peer_count(lt) == 1)
	// Both hand-outs (the first ensure and the reuse) return before the
	// stop, so the retire actually drains.
	langserver.manager_release(lt.m, again)
	langserver.manager_release(lt.m, client)

	testing.expect(t, langserver.manager_stop(lt.m, "tst") == nil)
	testing.expect(t, langserver.manager_retiring_count(lt.m) == 0)
}

// A restart must re-key the table entry with the replacement's own id:
// assigning onto an existing key replaces only the value, so an
// overwrite-only insert keeps the retired server's key bytes — and those
// are freed when the retire drains, rotting the entry for the live
// replacement.
@(test)
langserver_manager_restart_rekeys_the_entry :: proc(t: ^testing.T) {
	lt := ls_test_init(t, false, {"tst"}, false)
	defer ls_test_destroy(lt)

	first, err := langserver.manager_ensure(lt.m, "tst", context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, first != nil)

	testing.expect(t, langserver.manager_restart(lt.m, "tst", context.temp_allocator) == nil)
	testing.expect(t, ls_peer_count(lt) == 2)

	// Drop the retired server's hand-out so the sweep really destroys it
	// — the moment its id clone is freed.
	langserver.manager_release(lt.m, first)
	testing.expect(t, langserver.manager_retiring_count(lt.m) == 0)

	rows := langserver.manager_status(lt.m, context.allocator)
	testing.expect(t, status_row(rows, "tst"))
	free_status_rows(rows)

	again, err2 := langserver.manager_ensure(lt.m, "tst", context.temp_allocator)
	testing.expect(t, err2 == nil)
	testing.expect(t, again != nil && again != first)
	testing.expect(t, ls_peer_count(lt) == 2) // the replacement is reused, not restarted over
	langserver.manager_release(lt.m, again)
}

@(test)
langserver_manager_failure_cooldown_virtual :: proc(t: ^testing.T) {
	lt := ls_test_init(t, true, {"tst"}, false)
	defer ls_test_destroy(lt)

	ls_fail_next(lt)

	err := langserver.manager_start(lt.m, "tst", context.temp_allocator)
	testing.expect(t, platform.err_kind(err) == .Internal)
	testing.expect(t, ls_peer_count(lt) == 0)

	// Inside the cooldown the start is refused without touching the
	// factory.
	err2 := langserver.manager_start(lt.m, "tst", context.temp_allocator)
	testing.expect(t, platform.err_kind(err2) == .Retryable)
	testing.expect(t, ls_peer_count(lt) == 0)

	platform.clock_advance(lt.clock, 31_000)
	err3 := langserver.manager_start(lt.m, "tst", context.temp_allocator)
	testing.expect(t, err3 == nil)
	testing.expect(t, ls_peer_count(lt) == 1)

	// The cold reset forgets failure history: arm the cooldown with a
	// failed start, reset, and the next start goes through without
	// waiting out the cooldown.
	langserver.manager_stop(lt.m, "tst")
	ls_fail_next(lt)
	err4 := langserver.manager_start(lt.m, "tst", context.temp_allocator)
	testing.expect(t, platform.err_kind(err4) == .Internal)
	err5 := langserver.manager_start(lt.m, "tst", context.temp_allocator)
	testing.expect(t, platform.err_kind(err5) == .Retryable)
	testing.expect(t, langserver.manager_reset(lt.m) == 0)
	err6 := langserver.manager_start(lt.m, "tst", context.temp_allocator)
	testing.expect(t, err6 == nil)
}

@(test)
langserver_manager_command_overrides :: proc(t: ^testing.T) {
	lt := ls_test_init(t, true, {"tst"}, false)
	defer ls_test_destroy(lt)

	// A second language whose built-in runtime check fails (the required
	// binary does not exist): without an override it refuses to start.
	langserver.registry_add(lt.reg, {
		id                = "chk",
		display_name      = "Check",
		file_patterns     = {"*.chk"},
		priority          = langserver.PRIORITY_NORMAL,
		command           = "chk-server",
		required_binaries = {
			{name = "no-such-chk-binary-xyz", display_name = "Chk"},
		},
	})
	err := langserver.manager_start(lt.m, "chk", context.temp_allocator)
	testing.expect(t, platform.err_kind(err) == .NotFound)
	testing.expect(t, ls_peer_count(lt) == 0)
	// The failed start armed chk's cooldown — clear it before the
	// override attempt below.
	platform.clock_advance(lt.clock, 31_000)

	// Built-in argv without an override.
	err = langserver.manager_start(lt.m, "tst", context.temp_allocator)
	testing.expect(t, err == nil)
	argv := ls_last_argv(lt)
	if len(argv) == 1 {
		testing.expect(t, argv[0] == "tst-server")
	} else {
		testing.expectf(t, false, "built-in argv: %d elements", len(argv))
	}
	langserver.manager_stop(lt.m, "tst")

	// An override replaces the built-in argv and skips the entry's runtime
	// checks (chk starts although its required binary is absent).
	ovr := ls_overrides(lt, {{"tst", {SH_NAME, "--flag"}}, {"chk", {SH_NAME}}})
	langserver.manager_set_overrides(lt.m, ovr)
	langserver.free_string_array_map(ovr, lt.allocator)
	err = langserver.manager_start(lt.m, "tst", context.temp_allocator)
	testing.expect(t, err == nil)
	argv = ls_last_argv(lt)
	if len(argv) == 2 {
		testing.expect(t, argv[0] == SH_NAME && argv[1] == "--flag")
	} else {
		testing.expectf(t, false, "override argv: %d elements", len(argv))
	}
	langserver.manager_stop(lt.m, "tst")
	err = langserver.manager_start(lt.m, "chk", context.temp_allocator)
	testing.expect(t, err == nil)
	argv = ls_last_argv(lt)
	if len(argv) == 1 {
		testing.expect(t, argv[0] == SH_NAME)
	} else {
		testing.expectf(t, false, "chk override argv: %d elements", len(argv))
	}
	langserver.manager_stop(lt.m, "chk")

	// A missing argv[0] fails closed before the factory, with the
	// configured-command message, and arms the cooldown.
	ovr = ls_overrides(lt, {{"tst", {"/no/such/tst-server"}}})
	langserver.manager_set_overrides(lt.m, ovr)
	langserver.free_string_array_map(ovr, lt.allocator)
	err = langserver.manager_start(lt.m, "tst", context.temp_allocator)
	testing.expect(t, platform.err_kind(err) == .NotFound)
	testing.expect(
		t,
		strings.contains(platform.err_message(err, context.temp_allocator), "not executable"),
	)
	testing.expect(t, ls_peer_count(lt) == 3) // three peers above; nothing spawned
	err = langserver.manager_start(lt.m, "tst", context.temp_allocator)
	testing.expect(t, platform.err_kind(err) == .Retryable)
	platform.clock_advance(lt.clock, 31_000)

	// Restart uses the override too (the swap above replaced the map).
	ovr = ls_overrides(lt, {{"tst", {SH_NAME}}})
	langserver.manager_set_overrides(lt.m, ovr)
	langserver.free_string_array_map(ovr, lt.allocator)
	err = langserver.manager_start(lt.m, "tst", context.temp_allocator)
	testing.expect(t, err == nil)
	langserver.manager_stop(lt.m, "tst")
	err = langserver.manager_restart(lt.m, "tst", context.temp_allocator)
	testing.expect(t, err == nil)
	argv = ls_last_argv(lt)
	if len(argv) == 1 {
		testing.expect(t, argv[0] == SH_NAME)
	} else {
		testing.expectf(t, false, "restart override argv: %d elements", len(argv))
	}

	// Clearing the overrides falls back to the built-in argv.
	langserver.manager_stop(lt.m, "tst")
	empty := make(map[string][]string, 0, lt.allocator)
	langserver.manager_set_overrides(lt.m, empty)
	delete(empty)
	err = langserver.manager_start(lt.m, "tst", context.temp_allocator)
	testing.expect(t, err == nil)
	argv = ls_last_argv(lt)
	if len(argv) == 1 {
		testing.expect(t, argv[0] == "tst-server")
	} else {
		testing.expectf(t, false, "cleared argv: %d elements", len(argv))
	}
}

@(test)
langserver_manager_restart_swaps :: proc(t: ^testing.T) {
	lt := ls_test_init(t, false, {"tst"}, false)
	defer ls_test_destroy(lt)

	first, err := langserver.manager_ensure(lt.m, "tst", context.temp_allocator)
	testing.expect(t, err == nil)

	testing.expect(t, langserver.manager_restart(lt.m, "tst", context.temp_allocator) == nil)
	testing.expect(t, ls_peer_count(lt) == 2)

	second, err2 := langserver.manager_ensure(lt.m, "tst", context.temp_allocator)
	testing.expect(t, err2 == nil)
	testing.expect(t, second != nil && second != first)

	restart_err := langserver.manager_restart(lt.m, "no-such", context.temp_allocator)
	testing.expect(t, platform.err_kind(restart_err) == .NotFound)
}

@(test)
langserver_manager_idle_virtual :: proc(t: ^testing.T) {
	lt := ls_test_init(t, true, {"tst"}, false)
	lt.m.idle_timeout_ms = 200
	lt.m.idle_interval_ms = 50
	langserver.manager_start_idle(lt.m)
	defer ls_test_destroy(lt)

	_, err := langserver.manager_ensure(lt.m, "tst", context.temp_allocator)
	testing.expect(t, err == nil)

	// Pump virtual time until the monitor reaps: it wakes on real-time
	// cond slices and reads the injected clock, so advances drive the
	// (shrunken) timeout while a real deadline bounds the wait. The
	// reap broadcasts on the manager cond, which unblocks this poll.
	deadline := platform.mono_ms() + 5000
	sync.mutex_lock(&lt.m.mu)
	reaped := lt.m.servers["tst"] == nil
	for !reaped && platform.mono_ms() < deadline {
		sync.mutex_unlock(&lt.m.mu)
		platform.clock_advance(lt.clock, 50)
		sync.mutex_lock(&lt.m.mu)
		reaped = lt.m.servers["tst"] == nil
		if reaped {
			break
		}
		sync.cond_wait_with_timeout(&lt.m.cond, &lt.m.mu, 20 * 1_000_000)
	}
	sync.mutex_unlock(&lt.m.mu)
	testing.expect(t, reaped)
}

@(test)
langserver_manager_eager_and_stop_all :: proc(t: ^testing.T) {
	lt := ls_test_init(t, false, {"tst"}, true)
	defer ls_test_destroy(lt)

	langserver.manager_start_eager(lt.m)
	testing.expect(t, ls_peer_count(lt) == 1)

	rows := langserver.manager_status(lt.m, context.allocator)
	testing.expect(t, status_row(rows, "tst"))
	free_status_rows(rows)

	langserver.manager_stop_all(lt.m)
	_, err := langserver.manager_ensure(lt.m, "tst", context.temp_allocator)
	testing.expect(t, platform.err_kind(err) == .Terminated)
}

// --- production factory smoke test ---------------------------------------------

// A minimal LSP server in python3: replies to initialize (then pushes an
// empty diagnostics set so the cross-file wait latches instead of
// timing out), answers shutdown, exits on EOF.
PY_SMOKE_SCRIPT :: `
import sys, json
def rd():
    h = b''
    while not h.endswith(b'\r\n\r\n'):
        c = sys.stdin.buffer.read(1)
        if not c:
            raise EOFError
        h += c
    n = 0
    for line in h.split(b'\r\n'):
        if line.lower().startswith(b'content-length'):
            n = int(line.split(b':')[1])
    b = b''
    while len(b) < n:
        c = sys.stdin.buffer.read(n - len(b))
        if not c:
            raise EOFError
        b += c
    return json.loads(b)
def wr(o):
    b = json.dumps(o).encode()
    sys.stdout.buffer.write(b'Content-Length: %d\r\n\r\n' % len(b) + b)
    sys.stdout.buffer.flush()
while True:
    try:
        m = rd()
    except EOFError:
        break
    method = m.get('method')
    if 'id' in m and method == 'initialize':
        wr({'jsonrpc': '2.0', 'id': m['id'], 'result': {'capabilities': {'textDocumentSync': 1}}})
        wr({'jsonrpc': '2.0', 'method': 'textDocument/publishDiagnostics',
            'params': {'uri': 'file:///smoke.py', 'diagnostics': []}})
    elif 'id' in m and method == 'shutdown':
        wr({'jsonrpc': '2.0', 'id': m['id'], 'result': None})
        break
`

smoke_teardown :: proc(lt: ^LS_Test) {
	langserver.manager_destroy(lt.m)
	free(lt.m, lt.allocator)
	langserver.registry_destroy(lt.reg)
	platform.clock_destroy(lt.clock)
	free(lt.clock, lt.allocator)
	free(lt, context.allocator)
}

@(test)
langserver_factory_stdio_smoke :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		// The real stdio assembly is exercised where a POSIX python3
		// exists; Windows runners cover the same code through the
		// fake-factory suite above.
		_ = t
		return
	} else {
		if !langserver.binary_available("python3") {
			return
		}

		root, derr := os.make_directory_temp("", "aubade-ls-smoke-", context.allocator)
		if derr != nil {
			testing.expectf(t, false, "temp dir failed")
			return
		}
		defer delete(root, context.allocator)
		defer _ = os.remove_all(root)

		lt := new(LS_Test, context.allocator)
		mem.mutex_allocator_init(&lt.mu, context.allocator)
		lt.allocator = mem.mutex_allocator(&lt.mu)
		lt.reg = langserver.registry_build(lt.allocator)
		langserver.registry_add(lt.reg, {
			id            = "pysmoke",
			display_name  = "PySmoke",
			file_patterns = {"*.pysmoke"},
			priority      = langserver.PRIORITY_NORMAL,
			command       = "python3",
			args          = {"-c", PY_SMOKE_SCRIPT},
		})
		lt.clock = new(platform.Clock, lt.allocator)
		platform.clock_init(lt.clock, false, lt.allocator)
		lt.root = root
		lt.m = new(langserver.Manager, lt.allocator)
		langserver.manager_init(
			lt.m, lt.reg, root, lt.clock, langserver.production_factory(lt.m), {"pysmoke"}, false, lt.allocator,
		)
		defer smoke_teardown(lt)

		client, err := langserver.manager_ensure(lt.m, "pysmoke", context.temp_allocator)
		if err != nil {
			msg := platform.err_message(err, context.temp_allocator)
			testing.expectf(t, false, "ensure failed: %s", msg)
			return
		}
		testing.expect(t, client != nil)
		testing.expect(t, lsp.client_is_initialized(client))

		caps := lsp.client_caps(client)
		testing.expect(t, caps.sync_kind == .Full)
	}
}

// An in-use server survives a restart: the hand-out pins the old server
// in the retiring list, and only its release lets the sweep destroy it
// (no use-after-free under a concurrent caller).
@(test)
langserver_manager_release_pins_restart :: proc(t: ^testing.T) {
	lt := ls_test_init(t, false, {"tst"}, false)
	defer ls_test_destroy(lt)

	first, err := langserver.manager_ensure(lt.m, "tst", context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, langserver.manager_retiring_count(lt.m), 0)

	testing.expect(t, langserver.manager_restart(lt.m, "tst", context.temp_allocator) == nil)
	// The held hand-out parks the old server instead of destroying it.
	testing.expect_value(t, langserver.manager_retiring_count(lt.m), 1)
	testing.expect_value(t, ls_peer_count(lt), 2)

	langserver.manager_release(lt.m, first)
	testing.expect_value(t, langserver.manager_retiring_count(lt.m), 0)

	// A release for a client the manager no longer knows is a no-op.
	langserver.manager_release(lt.m, first)

	testing.expect(t, langserver.manager_stop(lt.m, "tst") == nil)
}

// manager_config_note: the odin entry's collections note fires while the
// probe base lacks ols.json (the silent same-package degradation of
// references) and clears once the file exists — at a running server's
// first announced folder when one is passed, at the manager root
// otherwise. Entries without note fields never fire.
@(test)
langserver_manager_config_note :: proc(t: ^testing.T) {
	root, derr := os.make_directory_temp("", "aubade-ls-note-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp dir failed")
		return
	}
	defer delete(root, context.allocator)
	defer _ = os.remove_all(root)

	alloc := context.allocator
	reg := langserver.registry_build(alloc)
	defer langserver.registry_destroy(reg)
	clock := new(platform.Clock, alloc)
	platform.clock_init(clock, false, alloc)
	defer {
		platform.clock_destroy(clock)
		free(clock, alloc)
	}
	m := new(langserver.Manager, alloc)
	langserver.manager_init(m, reg, root, clock, langserver.production_factory(m), nil, false, alloc)
	defer {
		langserver.manager_destroy(m)
		free(m, alloc)
	}

	note := langserver.manager_config_note(m, "odin", "", context.temp_allocator)
	testing.expectf(t, note != "", "odin note must fire without ols.json")
	if note != "" {
		testing.expect(t, strings.contains(note, "collections"))
		testing.expect(t, strings.contains(note, "language_server_options"))
		// The remedy must stay inside aubade's config — no per-server
		// config file creation.
		testing.expect(t, !strings.contains(note, "write ols.json"))
	}
	testing.expect(t, langserver.manager_config_note(m, "go", "", context.temp_allocator) == "")
	testing.expect(t, langserver.manager_config_note(m, "no-such-language", "", context.temp_allocator) == "")

	// User options carrying the entry's config_note_option_keys stand the
	// note down; unrelated option keys do not.
	collections := make(map[string]string, 1, context.temp_allocator)
	collections["odin"] = `{"collections": [{"name": "src", "path": "src"}]}`
	langserver.manager_set_options(m, collections)
	testing.expect(t, langserver.manager_config_note(m, "odin", "", context.temp_allocator) == "")
	unrelated := make(map[string]string, 1, context.temp_allocator)
	unrelated["odin"] = `{"enable_format": false}`
	langserver.manager_set_options(m, unrelated)
	testing.expect(t, langserver.manager_config_note(m, "odin", "", context.temp_allocator) != "")
	langserver.manager_set_options(m, make(map[string]string, 0, context.temp_allocator))

	// A running server probes its first announced folder, not the root.
	lsp_write_file(root, "nested/ols.json", "{}")
	nested, _ := filepath.join([]string{root, "nested"}, context.temp_allocator)
	testing.expect(t, langserver.manager_config_note(m, "odin", nested, context.temp_allocator) == "")
	testing.expect(t, langserver.manager_config_note(m, "odin", "", context.temp_allocator) != "")

	// The note clears once the root itself carries the config.
	lsp_write_file(root, "ols.json", "{}")
	testing.expect(t, langserver.manager_config_note(m, "odin", "", context.temp_allocator) == "")
}

// merge_init_options_json: the user object's top-level keys win, entry
// keys the user did not set carry over, and broken user text falls back
// to the entry text instead of failing the start. Comparisons use ==
// (expect_value would parse the braces as format parameters).
@(test)
langserver_merge_init_options :: proc(t: ^testing.T) {
	// Entry-only and user-only pass through untouched.
	testing.expect(t, langserver.merge_init_options_json(`{"a": 1}`, "", context.temp_allocator) == `{"a": 1}`)
	testing.expect(t, langserver.merge_init_options_json("", `{"b": 2}`, context.temp_allocator) == `{"b": 2}`)

	// Shallow merge with the user winning; marshal_value sorts keys.
	merged := langserver.merge_init_options_json(
		`{"keep": 1, "over": 2}`,
		`{"over": 3, "added": 4}`,
		context.temp_allocator,
	)
	testing.expect(t, merged == `{"added":4,"keep":1,"over":3}`, merged)

	// Broken user text falls back to the entry text (the config loader
	// validated it once; this is the defensive re-parse path).
	testing.expect(
		t,
		langserver.merge_init_options_json(`{"a": 1}`, `{broken`, context.temp_allocator) == `{"a": 1}`,
	)

	// A user value that is not an object also falls back to the entry text.
	testing.expect(
		t,
		langserver.merge_init_options_json(`{"a": 1}`, `[1, 2]`, context.temp_allocator) == `{"a": 1}`,
	)
}

// --- multi-root workspace folders ----------------------------------------------

@(test)
langserver_scan_language_roots :: proc(t: ^testing.T) {
	root, derr := os.make_directory_temp("", "aubade-ls-roots-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp dir failed")
		return
	}
	defer delete(root, context.allocator)
	defer _ = os.remove_all(root)

	// Two sibling modules plus a nested one; node_modules carries a
	// marker that must never surface; plain/ has none.
	scan_mk_dir(root, "modA")
	scan_mk_file(root, "modA/go.mod", "module a\n")
	scan_mk_dir(root, "modB")
	scan_mk_file(root, "modB/go.mod", "module b\n")
	scan_mk_dir(root, "modB/sub")
	scan_mk_file(root, "modB/sub/go.mod", "module sub\n")
	scan_mk_dir(root, "node_modules/hidden")
	scan_mk_file(root, "node_modules/hidden/go.mod", "module hidden\n")
	scan_mk_dir(root, "plain")

	go_markers := [1]string{"go.mod"}

	// Discovered roots: all marker dirs, nested included, sorted.
	roots := langserver.scan_language_roots(root, go_markers[:], nil, context.allocator)
	defer langserver.free_strings(roots, context.allocator)
	testing.expect(t, len(roots) == 3)
	if len(roots) == 3 {
		want_a, _ := filepath.join({root, "modA"}, context.temp_allocator)
		want_b, _ := filepath.join({root, "modB"}, context.temp_allocator)
		want_s, _ := filepath.join({root, "modB/sub"}, context.temp_allocator)
		testing.expect(t, roots[0] == want_a)
		testing.expect(t, roots[1] == want_b)
		testing.expect(t, roots[2] == want_s)
	}

	// Seeds come first and fold against discovered duplicates.
	seed_dir, _ := filepath.join({root, "modB"}, context.temp_allocator)
	seeds := [1]string{seed_dir}
	seeded := langserver.scan_language_roots(root, go_markers[:], seeds[:], context.allocator)
	defer langserver.free_strings(seeded, context.allocator)
	testing.expect(t, len(seeded) == 3)
	if len(seeded) == 3 {
		testing.expect(t, seeded[0] == seed_dir)
	}

	// No markers and no seeds resolve to the project root itself.
	bare := langserver.scan_language_roots(root, nil, nil, context.allocator)
	defer langserver.free_strings(bare, context.allocator)
	testing.expect(t, len(bare) == 1)
	if len(bare) == 1 {
		testing.expect(t, bare[0] == root)
	}
}

@(test)
langserver_scan_language_roots_skips_managed_state :: proc(t: ^testing.T) {
	root, derr := os.make_directory_temp("", "aubade-ls-mstate-", context.allocator)
	if derr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(root)
		delete(root, context.allocator)
	}
	home, herr := os.make_directory_temp("", "aubade-ls-mstate-home-", context.allocator)
	if herr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(home)
		delete(home, context.allocator)
	}
	// A relocated managed folder: the root scan must resolve its location
	// through the global config, not the default name.
	cfg_path, _ := filepath.join({home, "config.jsonc"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(
		cfg_path,
		"{\"project_aubade_folder_location\": \"$projectDir/.state\"}\n",
		os.Permissions{.Read_User, .Write_User},
	)

	dirs_to_make := []string{"modA", "modB", ".state"}
	for d in dirs_to_make {
		p, _ := filepath.join({root, d}, context.temp_allocator)
		_ = os.make_directory_all(p, os.Permissions{.Read_User, .Write_User, .Execute_User})
	}
	// Two real module markers, and a marker-named file inside the
	// managed state directory — without the location-based skip it would
	// surface as a third workspace folder.
	files_to_write := []string{"modA/go.mod", "modB/go.mod", ".state/go.mod"}
	for f in files_to_write {
		p, _ := filepath.join({root, f}, context.temp_allocator)
		_ = os.write_entire_file_from_string(p, "go 1.21\n", os.Permissions{.Read_User, .Write_User})
	}

	old, had := set_aubade_home(home)
	defer restore_aubade_home(old, had)

	go_markers := [1]string{"go.mod"}
	roots := langserver.scan_language_roots(root, go_markers[:], nil, context.allocator)
	defer langserver.free_strings(roots, context.allocator)
	testing.expect_value(t, len(roots), 2)
	if len(roots) == 2 {
		want_a, _ := filepath.join({root, "modA"}, context.temp_allocator)
		want_b, _ := filepath.join({root, "modB"}, context.temp_allocator)
		testing.expect(t, roots[0] == want_a)
		testing.expect(t, roots[1] == want_b)
	}
}

// mr_test_init mirrors ls_test_init with a multi-root entry over a real
// temporary project root, so the folder scan walks the actual disk.
mr_test_init :: proc(t: ^testing.T, root: string) -> ^LS_Test {
	lt := new(LS_Test, context.allocator)
	mem.mutex_allocator_init(&lt.mu, context.allocator)
	lt.allocator = mem.mutex_allocator(&lt.mu)

	lt.reg = langserver.registry_build(lt.allocator)
	langserver.registry_add(lt.reg, {
		id            = "mr",
		display_name  = "Multi-Root",
		file_patterns = {"*.mr"},
		priority      = langserver.PRIORITY_NORMAL,
		command       = "mr-server",
		root_markers  = {"mr.marker"},
		multi_root    = true,
	})

	lt.clock = new(platform.Clock, lt.allocator)
	platform.clock_init(lt.clock, true, lt.allocator)

	lt.root = root
	lt.ff = new(Fake_Factory, lt.allocator)
	lt.ff^ = {allocator = lt.allocator}
	lt.ff.peers = make([dynamic]^Fake_Peer, 0, 4, lt.allocator)

	lt.m = new(langserver.Manager, lt.allocator)
	langserver.manager_init(
		lt.m, lt.reg, lt.root, lt.clock, {user = lt.ff, create = fake_ls_create}, {"mr"}, false, lt.allocator,
	)
	// An override to an always-present binary bypasses the entry's
	// runtime probes so the fake factory is reached deterministically.
	override_argv := [1]string{SH_NAME}
	overrides := ls_overrides(lt, {{lang = "mr", argv = override_argv[:]}})
	langserver.manager_set_overrides(lt.m, overrides)
	langserver.free_string_array_map(overrides, lt.allocator)
	return lt
}

@(test)
langserver_multi_root_start_folders :: proc(t: ^testing.T) {
	root, derr := os.make_directory_temp("", "aubade-ls-mr-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp dir failed")
		return
	}
	defer delete(root, context.allocator)
	defer _ = os.remove_all(root)

	scan_mk_dir(root, "app")
	scan_mk_file(root, "app/mr.marker", "")
	scan_mk_dir(root, "lib")
	scan_mk_file(root, "lib/mr.marker", "")

	lt := mr_test_init(t, root)
	defer ls_test_destroy(lt)

	client, err := langserver.manager_ensure(lt.m, "mr", context.temp_allocator)
	if !testing.expectf(t, err == nil, "ensure failed") {
		return
	}
	langserver.manager_release(lt.m, client)

	folders := ls_last_folders(lt)
	testing.expect(t, len(folders) == 2)
	if len(folders) == 2 {
		want_app, _ := filepath.join({root, "app"}, context.temp_allocator)
		want_lib, _ := filepath.join({root, "lib"}, context.temp_allocator)
		testing.expect(t, folders[0] == want_app)
		testing.expect(t, folders[1] == want_lib)
	}

	rows := langserver.manager_status(lt.m, context.allocator)
	mr_row: langserver.Status_Row
	found := false
	for row in rows {
		if row.id == "mr" {
			mr_row = row
			found = true
		} else {
			delete(row.id, context.allocator)
			delete(row.root, context.allocator)
		}
	}
	delete(rows, context.allocator)
	testing.expect(t, found)
	if found {
		testing.expect(t, mr_row.running)
		testing.expect(t, mr_row.folders == 2)
		want_app, _ := filepath.join({root, "app"}, context.temp_allocator)
		testing.expect(t, mr_row.root == want_app)
		delete(mr_row.id, context.allocator)
		delete(mr_row.root, context.allocator)
	}
}

// The single-root invariant: a project root with no markers yields
// exactly the pre-multi-root folder set (the project root alone).
@(test)
langserver_single_root_folders :: proc(t: ^testing.T) {
	root, derr := os.make_directory_temp("", "aubade-ls-sr-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp dir failed")
		return
	}
	defer delete(root, context.allocator)
	defer _ = os.remove_all(root)

	scan_mk_file(root, "plain.mr", "x\n")

	lt := mr_test_init(t, root)
	defer ls_test_destroy(lt)

	client, err := langserver.manager_ensure(lt.m, "mr", context.temp_allocator)
	if !testing.expectf(t, err == nil, "ensure failed") {
		return
	}
	langserver.manager_release(lt.m, client)

	folders := ls_last_folders(lt)
	testing.expect(t, len(folders) == 1)
	if len(folders) == 1 {
		testing.expect(t, folders[0] == root)
	}
}

Park_Worker :: struct {
	m:    ^langserver.Manager,
	done: bool,
	err:  platform.Err,
}

park_worker_main :: proc(data: rawptr) {
	w := cast(^Park_Worker)data
	_, w.err = langserver.manager_ensure(w.m, "tst", context.temp_allocator, nil)
	sync.atomic_store(&w.done, true)
}

// The starting-park is deadline-capped even without a cancel token: a
// waiter that would otherwise slice forever (the buffer-sync paths used
// to arrive here under an editor file lock) reports a timeout instead.
// The deadline counts from the ensure call itself, so the cap can only be
// proven by advancing the clock while the waiter is already parked —
// hence the worker thread. The park's cond slices run on real time by
// design, so the feeder gives them real milliseconds.
@(test)
manager_ensure_park_is_deadline_capped :: proc(t: ^testing.T) {
	lt := ls_test_init(t, true, {"tst"}, false)
	defer ls_test_destroy(lt)

	// Simulate another thread mid-start: the marker makes ensure park.
	sync.mutex_lock(&lt.m.mu)
	lt.m.starting["tst"] = true
	sync.mutex_unlock(&lt.m.mu)
	defer {
		sync.mutex_lock(&lt.m.mu)
		delete_key(&lt.m.starting, "tst")
		sync.mutex_unlock(&lt.m.mu)
	}

	w := new(Park_Worker, context.allocator)
	w^ = {m = lt.m}
	defer free(w, context.allocator)
	th := thread.create_and_start_with_data(w, park_worker_main, self_cleanup = false, name = "ensure-park-worker")
	if th == nil {
		testing.expectf(t, false, "worker thread failed to start")
		return
	}
	for i := 0; i < 300 && !sync.atomic_load(&w.done); i += 1 {
		time.sleep(10 * time.Millisecond)
		platform.clock_advance(lt.clock, 2_000)
	}
	thread.join(th)
	free(th, context.allocator)
	testing.expect(t, w.done, "the capped park must return instead of blocking")
	if w.err != nil {
		testing.expect(
			t,
			platform.err_kind(w.err) == .Timeout,
			"the capped park must time out, got %s",
			platform.kind_name(platform.err_kind(w.err)),
		)
	}
}

@(test)
resolve_configured_path_forms :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Empty path means "nothing configured" — normal resolution applies.
	resolved, use_normal := langserver.resolve_configured_path("", "/proj", "/home/u", a)
	testing.expect_value(t, use_normal, true)
	testing.expect_value(t, resolved, "")

	// Absolute passes through verbatim — the form that keeps working when
	// the client spawns aubade with a scrubbed environment (no useful PATH).
	when ODIN_OS == .Windows {
		// On Windows, only drive-letter paths are absolute.
		resolved, use_normal = langserver.resolve_configured_path("C:\\opt\\ols", "C:\\proj", "C:\\Users\\u", a)
		testing.expect_value(t, use_normal, false)
		testing.expect_value(t, resolved, "C:\\opt\\ols")
	} else {
		resolved, use_normal = langserver.resolve_configured_path("/opt/ols", "/proj", "/home/u", a)
		testing.expect_value(t, use_normal, false)
		testing.expect_value(t, resolved, "/opt/ols")
	}

	// "~" forms expand against home.
	when ODIN_OS == .Windows {
		resolved, use_normal = langserver.resolve_configured_path("~/.local/bin/ols", "C:\\proj", "C:\\Users\\u", a)
		testing.expect_value(t, use_normal, false)
		testing.expect_value(t, resolved, "C:\\Users\\u\\.local\\bin\\ols")
		resolved, _ = langserver.resolve_configured_path("~", "C:\\proj", "C:\\Users\\u", a)
		testing.expect_value(t, resolved, "C:\\Users\\u")
	} else {
		resolved, use_normal = langserver.resolve_configured_path("~/.local/bin/ols", "/proj", "/home/u", a)
		testing.expect_value(t, use_normal, false)
		testing.expect_value(t, resolved, "/home/u/.local/bin/ols")
		resolved, _ = langserver.resolve_configured_path("~", "/proj", "/home/u", a)
		testing.expect_value(t, resolved, "/home/u")
	}

	// Relative anchors at the project root, never the daemon's cwd.
	when ODIN_OS == .Windows {
		resolved, use_normal = langserver.resolve_configured_path("tools/ols", "C:\\proj", "C:\\Users\\u", a)
		testing.expect_value(t, use_normal, false)
		testing.expect_value(t, resolved, "C:\\proj\\tools\\ols")
	} else {
		resolved, use_normal = langserver.resolve_configured_path("tools/ols", "/proj", "/home/u", a)
		testing.expect_value(t, use_normal, false)
		testing.expect_value(t, resolved, "/proj/tools/ols")
	}
}

@(test)
langserver_eager_thread_walks_whole_snapshot :: proc(t: ^testing.T) {
	// The eager thread snapshots the allowlist onto the manager's
	// allocator: its per-start free_all(temp) must not eat the snapshot
	// it is walking, so every configured language (more than the
	// synchronous budget of three) comes up — the freed-backing variant
	// stopped after the first background start.
	lt := ls_test_init(t, false, {"tst", "ts2", "ts3", "ts4", "ts5"}, true)
	defer ls_test_destroy(lt)
	// Four more languages (the literal binds to a local — `for` over a
	// brace literal cannot parse). Distinct patterns keep the extension
	// index unambiguous.
	more := [4]string{"ts2", "ts3", "ts4", "ts5"}
	for id in more {
		langserver.registry_add(lt.reg, {
			id            = id,
			display_name  = id,
			file_patterns = {strings.concatenate({"*.", id}, context.temp_allocator)},
			priority      = langserver.PRIORITY_NORMAL,
			command       = "server",
		})
	}
	langserver.manager_start_eager(lt.m)
	langserver.manager_stop_eager(lt.m) // joins the background walk
	testing.expectf(t, ls_peer_count(lt) == 5, "all five languages started, got %d", ls_peer_count(lt))
}

@(test)
langserver_manager_destroy_cancels_eager_walk :: proc(t: ^testing.T) {
	// Destroy must stop the eager walk BEFORE joining it: the stop flag
	// latches and the cancel token reaches the walk at destroy entry, so
	// a parked in-flight start aborts at its checkpoint and the remaining
	// languages are never started. (The direct manager_stop_eager call
	// keeps its join-the-walk contract — the walk-skip lives in destroy.)
	lt := ls_test_init(t, false, {"tst", "ts2", "ts3", "ts4", "ts5"}, true)
	defer ls_test_destroy(lt)
	more := [4]string{"ts2", "ts3", "ts4", "ts5"}
	for id in more {
		langserver.registry_add(lt.reg, {
			id            = id,
			display_name  = id,
			file_patterns = {strings.concatenate({"*.", id}, context.temp_allocator)},
			priority      = langserver.PRIORITY_NORMAL,
			command       = "server",
		})
	}

	root := new(platform.Cancel_Token, lt.allocator)
	platform.token_init_root(root)

	// tst, ts2, ts3 start within manager_start_eager's synchronous budget
	// of three; the background walk then parks inside create("ts4").
	ls_set_park(lt, "ts4")
	langserver.manager_start_eager(lt.m)

	// Wait for the walk to reach the parked start (capped sync spin; the
	// file's cond-slice polls are the precedent).
	for spin := 0; spin < 500 && ls_entered_count(lt) < 4; spin += 1 {
		time.sleep(2 * time.Millisecond)
	}
	testing.expectf(t, ls_entered_count(lt) == 4, "eager walk reached the parked start (entered=%d)", ls_entered_count(lt))

	platform.token_fire(root, .Shutdown)
	langserver.manager_destroy(lt.m, root)

	// ts5 was never entered and the parked ts4 start aborted: the walk
	// skipped the remainder instead of making destroy wait it out.
	testing.expectf(t, ls_entered_count(lt) == 4, "destroy stopped the walk before ts5 (entered=%d)", ls_entered_count(lt))
	testing.expectf(t, ls_peer_count(lt) == 3, "parked start aborted; the three synchronous peers stand (got %d)", ls_peer_count(lt))
	platform.token_destroy(root, lt.allocator)
}

@(test)
langserver_root_marker_case_rule :: proc(t: ^testing.T) {
	// The marker match follows the filesystem's case rule: exact on
	// Linux, folded on macOS/Windows (a GO.mod created there IS the
	// go.mod file).
	testing.expect(t, langserver.is_root_marker("go.mod", {"go.mod"}), "exact match")
	when ODIN_OS == .Darwin || ODIN_OS == .Windows {
		testing.expect(t, langserver.is_root_marker("GO.MOD", {"go.mod"}), "case-insensitive fs folds")
	} else {
		testing.expect(t, !langserver.is_root_marker("GO.MOD", {"go.mod"}), "linux stays case-sensitive")
	}
}

// A restart whose factory create finishes after a concurrent
// manager_destroy must not insert: destroy drains and deletes
// m.servers inside the create window, so an unconditional insert would
// resurrect the deleted map through the wrong allocator and strand the
// live replacement. The create parks until the test releases it — the
// destroy lands first, then the create succeeds — and the restart must
// answer .Cancelled with the finished server destroyed (zero peers).
@(test)
langserver_manager_restart_after_destroy_refuses_insert :: proc(t: ^testing.T) {
	lt := ls_test_init(t, true, {"tst"}, false)
	defer ls_test_destroy(lt)

	sync.mutex_lock(&lt.ff.mu)
	lt.ff.park_success_language = "tst"
	sync.mutex_unlock(&lt.ff.mu)

	Restart_Worker :: struct {
		m:    ^langserver.Manager,
		err:  platform.Err,
		mu:   sync.Mutex,
		cond: sync.Cond,
		done: bool,
	}
	w := new(Restart_Worker, context.allocator)
	defer free(w, context.allocator)
	w^ = {m = lt.m}

	restart_worker_main :: proc(data: rawptr) {
		rw := cast(^Restart_Worker)data
			err := langserver.manager_restart(rw.m, "tst", context.temp_allocator)
			sync.mutex_lock(&rw.mu)
		rw.err = err
		rw.done = true
		sync.cond_broadcast(&rw.cond)
		sync.mutex_unlock(&rw.mu)
	}
	thr := thread.create_and_start_with_data(w, restart_worker_main, self_cleanup = false)
	if thr == nil {
		testing.expectf(t, false, "worker thread failed to start")
		return
	}

	// Wait until the restart is parked inside create (bounded real time),
	// then destroy the manager under it and let the create finish.
	entered := 0
	for i := 0; i < 400; i += 1 {
		sync.mutex_lock(&lt.ff.mu)
		entered = lt.ff.entered
		sync.mutex_unlock(&lt.ff.mu)
		if entered >= 1 {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expectf(t, entered >= 1, "restart never reached the factory")

	// Fire before destroy, exactly like the eager-walk destroy test: the
	// guard hands m.cancel to server_destroy, and an unfired (or nil)
	// token would leave the graceful teardown parked on the virtual clock
	// forever — the fired token shortens it at once.
	root := new(platform.Cancel_Token, lt.allocator)
	platform.token_init_root(root)
	platform.token_fire(root, .Shutdown)
	langserver.manager_destroy(lt.m, root)

	sync.mutex_lock(&lt.ff.mu)
	lt.ff.release_parked = true
	sync.mutex_unlock(&lt.ff.mu)

	deadline := platform.mono_ms() + 5000
	sync.mutex_lock(&w.mu)
	for !w.done && platform.mono_ms() < deadline {
		sync.cond_wait_with_timeout(&w.cond, &w.mu, 20 * 1_000_000)
	}
	done := w.done
	err := w.err
	sync.mutex_unlock(&w.mu)
	thread.join(thr)
	free(thr, context.allocator)

	testing.expect(t, done, "the guarded restart must return, not hang")
	testing.expectf(t, platform.err_kind(err) == .Cancelled, "restart after destroy must cancel, got %s", platform.kind_name(platform.err_kind(err)))
	// The finished server was destroyed by the guard, not stranded in a
	// resurrected table: fake peers are owned by the harness (freed at
	// ls_test_destroy), so the stranding oracle is the suite's zero-leak
	// discipline — an un-destroyed server and its zero-value-map insert
	// surface as leak lines here.
	// The worker has drained: the token the guard handed to
	// server_destroy is safe to free only now.
	platform.token_destroy(root, lt.allocator)
}

@(test)
ignored_dirs_tables_agree :: proc(t: ^testing.T) {
	// The two DEFAULT_IGNORED_DIRS tables are a deliberate copy: the
	// language scan keeps the walk's ignore set as its own local
	// declaration, and config's table serves the symbol-crawl walkers.
	// This test is what keeps the two spellings honest: same length,
	// same entries, both directions.
	configured := config.DEFAULT_IGNORED_DIRS
	scanned := langserver.DEFAULT_IGNORED_DIRS
	testing.expect_value(t, len(scanned), len(configured))
	for d in configured {
		found := false
		for s in scanned {
			if s == d {
				found = true
				break
			}
		}
		testing.expectf(t, found, "config ignored dir %q missing from the scan table", d)
	}
	for s in scanned {
		found := false
		for d in configured {
			if d == s {
				found = true
				break
			}
		}
		testing.expectf(t, found, "scan ignored dir %q missing from the config table", s)
	}
}
