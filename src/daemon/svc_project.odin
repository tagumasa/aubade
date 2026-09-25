// Project state backing the symbol/index svc face: the per-project SQLite
// index (opened under the project's managed state directory, placed by
// the global folder template) and the tree-sitter
// source that fills it, plus the handlers serving svc.symbol/* and
// svc.index/*.
package daemon

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "src:config"
import "src:editor"
import "src:langserver"
import "src:jsonutil"
import "src:lsp"
import "src:platform"
import "src:safety"
import "src:shadow"
import "src:store"
import "src:symbol"
import "src:svc"
import "src:tracker"
import "src:util"

PROJECT_DB_NAME :: "aubade.db"

// project_db_path is the project index DB's one canonical path: the
// daemon opens it, and the read-only CLI lookups (tracker, the prompt
// summary) resolve the same spelling from the global folder template.
project_db_path :: proc(project_root, home: string, a := context.allocator) -> string {
	state_dir := config.managed_dir_for_root(project_root, home, a)
	db_path, _ := filepath.join([]string{state_dir, PROJECT_DB_NAME}, a)
	delete(state_dir, a)
	return db_path
}

// LSP_Port adapts the registry+manager pair to the svc producer ports:
// resolution is registry detection followed by manager ensure (may_start)
// or a running-server lookup (close events must never spawn).
LSP_Port :: struct {
	reg: ^langserver.Registry,
	m:   ^langserver.Manager,
}

daemon_lsp_client_for :: proc(
	user: rawptr,
	rel_path: string,
	may_start: bool,
	arena: mem.Allocator,
	token: ^platform.Cancel_Token,
) -> (client: ^lsp.Client, language_id: string, normalize: symbol.Normalize_Name_Proc, err: platform.Err) {
	p := cast(^LSP_Port)user
	entry := langserver.registry_detect(p.reg, rel_path)
	if entry == nil {
		// The message rides the scratch arena like every port error; the
		// strict producer re-clones it into the caller's allocator.
		return nil, "", nil, svc.wrapped_err(.NotFound, strings.concatenate({"no language server is registered for: ", rel_path}, arena), arena)
	}
	if may_start {
		client, err = langserver.manager_ensure(p.m, entry.id, arena, token)
		if err != nil {
			return nil, "", nil, err
		}
		return client, entry.id, entry.normalize, nil
	}
	running, ok := langserver.manager_client_for_file(p.m, rel_path)
	if !ok {
		return nil, "", nil, platform.Err(.NotFound)
	}
	return running, entry.id, entry.normalize, nil
}

// daemon_lsp_client_release returns one port hand-out's server pin.
daemon_lsp_client_release :: proc(user: rawptr, client: ^lsp.Client) {
	p := cast(^LSP_Port)user
	langserver.manager_release(p.m, client)
}

// project_state_init opens the project index, its TS source, and the
// language-server registry+manager. On failure it releases everything it
// created, leaving the daemon in its base state.
project_state_init :: proc(d: ^Daemon) -> bool {
	db_path := project_db_path(d.cfg.project_root, d.cfg.home, d.allocator)
	db_dir, _ := filepath.split(db_path)
	if err := os.make_directory_all(db_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}); err != nil && !os.exists(db_dir) {
		delete(db_path, d.allocator)
		return false
	}
	db, oerr := store.db_open(db_path, d.allocator)
	if oerr != nil {
		delete(db_path, d.allocator)
		return false
	}
	// Startup hygiene for the persistent symbol tables: expired rows go
	// and the table trims to its row cap. The sweep runs on the same
	// monotonic clock the index writes stamp (a wall-clock read here once
	// compared ~1.7e12 unix ms against mono deadlines and deleted every
	// row on every start). Caveat: mono-since-boot deadlines can outlive
	// their TTL across a reboot — stale rows are re-validated on every
	// read, so the worst case is extra work, never wrong answers.
	_ = store.sweep_expired(db, platform.clock_now(d.cfg.clock), store.SYMBOL_CACHE_ROW_CAP)
	trk := new(tracker.Manager, d.allocator)
	origin_seed, rng_seed := tracker_seeds()
	terr := tracker.manager_init(trk, db, daemon_wall_ns, origin_seed, rng_seed, true, d.allocator)
	if terr != nil {
		free(trk, d.allocator)
		store.db_close(db)
		delete(db_path, d.allocator)
		return false
	}
	ts := new(svc.TS_Source, d.allocator)
	svc.ts_source_init(ts, d.cfg.project_root, db, d.cfg.clock, d.allocator)
	ed := new(editor.Editor, d.allocator)
	line_ending, encoding := resolve_editor_settings(d, d.allocator)
	editor.editor_init(ed, d.cfg.project_root, line_ending, encoding, svc.editor_file_io_port(), d.allocator)
	// editor_init takes its own copy; the resolved encoding (owned by
	// d.allocator) is dead once the hand-off is done.
	if encoding != "" {
		delete(encoding, d.allocator)
	}
	// The TS source resolves the editor's view of open files (nil = pure
	// disk reads — the way the test harnesses construct it).
	ts.ed = ed
	d.db = db
	d.tracker = trk
	d.mem_files = memory_files_for_project(d)
	d.shadow = shadow_for_project(d)
	d.fetcher, d.searcher, d.web_safety = web_for_project(d)
	d.ts = ts
	d.ed = ed
	d.db_path = db_path

	reg := langserver.registry_build(d.allocator)
	allow, overrides, options, eager, seeds, _ := resolve_language_settings(d)
	ls := new(langserver.Manager, d.allocator)
	langserver.manager_init(
		ls, reg, d.cfg.project_root, d.cfg.clock, langserver.production_factory(ls), allow, eager, d.allocator,
	)
	if len(overrides) > 0 {
		langserver.manager_set_overrides(ls, overrides)
		langserver.free_string_array_map(overrides, d.allocator)
	}
	if len(options) > 0 {
		langserver.manager_set_options(ls, options)
		langserver.free_string_map(options, d.allocator)
	}
	langserver.manager_set_seeds(ls, seeds)
	langserver.free_strings(seeds, d.allocator)
	langserver.manager_start_idle(ls)
	langserver.manager_start_eager(ls)

	port := new(LSP_Port, d.allocator)
	port^ = {reg = reg, m = ls}
	lsp_src := new(svc.LSP_Source, d.allocator)
	svc.lsp_source_init(lsp_src, d.cfg.project_root, db, d.cfg.clock, ed, daemon_lsp_client_for, port, daemon_lsp_client_release, d.allocator)
	// The batch hover-info bound: symbol_info_budget resolved project →
	// global → default at project startup.
	lsp_src.symbol_info_budget_s = resolve_symbol_info_budget_s(d)
	sync := new(svc.Editor_Sync, d.allocator)
	svc.editor_sync_init(
		sync, d.cfg.project_root, daemon_lsp_client_for, port, d.allocator,
		hot = &d.ts.hot, release = daemon_lsp_client_release,
		ts_src = d.ts,
	)
	svc.editor_sync_install(sync, ed)
	d.ls_reg = reg
	d.ls = ls
	d.lsp_port = port
	d.lsp_src = lsp_src
	d.ls_sync = sync
	return true
}

// resolve_language_settings loads the project's language allowlist, the
// explicit language-server command overrides, the per-language
// initialization options, the extra workspace-folder seeds, and the
// global eager-start flag (project → global → defaults, like the editor
// settings). The allowlist, overrides, options, and seeds are cloned
// onto the daemon allocator; the caller owns them (the manager takes
// its own copy via manager_init / manager_set_allow /
// manager_set_overrides / manager_set_options / manager_set_seeds).
// Override and option entries for unregistered languages are inert by
// construction: start resolves the registry entry first. A load failure
// returns the typed error with the partial outputs cleared — the daemon
// start ignores it (startup resilience: no allowlist / no overrides),
// while the settings reload rejects on it (fail-closed: change nothing).
resolve_language_settings :: proc(
	d: ^Daemon,
) -> (allow: []string, overrides: map[string][]string, options: map[string]string, eager: bool, seeds: []string, err: platform.Err) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	global, _, gerr := config.load_global(d.cfg.home, a)
	if gerr == nil {
		eager = global.eager_language_servers
	} else {
		err = gerr
	}
	project, _, perr := config.load_project_for_root(d.cfg.project_root, d.cfg.home, a)
	if perr == nil {
		if len(project.language_servers) > 0 {
			names := make([]string, len(project.language_servers), a)
			merged := make(map[string][]string, len(project.language_servers), a)
			for e, i in project.language_servers {
				names[i] = e.name
				if e.path == "" {
					continue
				}
				resolved, use_normal := langserver.resolve_configured_path(
					e.path,
					d.cfg.project_root,
					d.cfg.home,
					a,
				)
				if use_normal {
					continue
				}
				argv := make([]string, 1, a)
				argv[0] = resolved
				merged[e.name] = argv
			}
			allow = langserver.clone_strings(names, d.allocator)
			// A full argv from language_server_commands is the more explicit
			// form — it wins over an entry path for the same language.
			for k, v in project.language_server_commands {
				merged[k] = v
			}
			if len(merged) > 0 {
				overrides = langserver.clone_string_array_map(merged, d.allocator)
			}
		} else if len(project.language_server_commands) > 0 {
			overrides = langserver.clone_string_array_map(
				project.language_server_commands,
				d.allocator,
			)
		}
		if len(project.language_server_options) > 0 {
			options = langserver.clone_string_map(project.language_server_options, d.allocator)
		}
		if len(project.additional_workspace_folders) > 0 {
			seeds = resolve_workspace_seeds(d.cfg.project_root, project.additional_workspace_folders, d.allocator)
		}
	} else {
		err = perr
	}
	if err != nil {
		// Ownership stays single-ended: on error the caller applies
		// nothing, so any clones made by the load that succeeded are
		// freed here instead of leaking (the free procs take nil).
		langserver.free_strings(allow, d.allocator)
		langserver.free_string_array_map(overrides, d.allocator)
		langserver.free_string_map(options, d.allocator)
		langserver.free_strings(seeds, d.allocator)
		return nil, nil, nil, false, nil, err
	}
	return allow, overrides, options, eager, seeds, err
}

// resolve_workspace_seeds validates the configured extra workspace
// folders: each must name an existing directory inside the project root
// (the root itself allowed — the working-directory containment flavor).
// Escaping or missing entries are skipped with a warning rather than
// refusing the load: a bad seed must not take the language allowlist
// down with it. Owned by `a`.
resolve_workspace_seeds :: proc(root: string, configured: []string, a: mem.Allocator) -> []string {
	out := make([dynamic]string, 0, len(configured), a)
	for c in configured {
		resolved, escape := safety.pathguard_validate_contained_dir(root, c, context.temp_allocator)
		if escape.reason != "" {
			util.log_warning(strings.concatenate(
				{"additional workspace folder is not inside the project root, skipping: ", c},
				context.temp_allocator,
			))
			continue
		}
		if !os.exists(resolved) {
			util.log_warning(strings.concatenate(
				{"additional workspace folder does not exist, skipping: ", resolved},
				context.temp_allocator,
			))
			continue
		}
		append(&out, strings.clone(resolved, a))
	}
	return out[:]
}

// resolve_editor_settings loads the project's line-ending and encoding
// preferences for the editor instance, project → global → defaults. Load
// failures fall back to the defaults — the daemon starts with or without
// readable config. The encoding is cloned onto `dest` (the config parse
// runs on a private arena destroyed at return); the caller owns the string
// for `dest`'s lifetime.
resolve_editor_settings :: proc(d: ^Daemon, dest := context.allocator) -> (line_ending: config.Line_Ending, encoding: string) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// A failed load returns nil; the zero Shared_Config's *_set flags read
	// as "key absent" — the shared precedence helper falls through to the
	// next layer exactly like a missing key.
	global, _, gerr := config.load_global(d.cfg.home, a)
	g: config.Global_Config
	if gerr == nil {
		g = global^
	}
	project, _, perr := config.load_project_for_root(d.cfg.project_root, d.cfg.home, a)
	p: config.Project_Config
	if perr == nil {
		p = project^
	}
	line_ending = config.resolve_line_ending(&p.shared, &g.shared)
	if p.encoding != "" {
		encoding = strings.clone(p.encoding, dest)
	}
	return line_ending, encoding
}

// resolve_symbol_info_budget_s loads the batch hover-info budget the same
// way (project → global → default). The bound is consumed by the
// symbol_find_implementations hover pass on the LSP source.
resolve_symbol_info_budget_s :: proc(d: ^Daemon) -> f64 {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	global, _, gerr := config.load_global(d.cfg.home, a)
	g: config.Global_Config
	if gerr == nil {
		g = global^
	}
	project, _, perr := config.load_project_for_root(d.cfg.project_root, d.cfg.home, a)
	p: config.Project_Config
	if perr == nil {
		p = project^
	}
	return config.resolve_symbol_info_budget_s(&p.shared, &g.shared)
}

// resolve_read_only loads the project config once at daemon startup: a
// read-only project refuses every mutating svc method. Load failures
// leave it off — the daemon starts with or without readable config.
resolve_read_only :: proc(cfg: Config, a := context.allocator) -> bool {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, a)
	defer mem.dynamic_arena_destroy(&arena)
	project, _, perr := config.load_project_for_root(
		cfg.project_root, cfg.home, mem.dynamic_arena_allocator(&arena),
	)
	if perr != nil {
		return false
	}
	return project.read_only
}

// project_state_destroy releases the language servers, the index, and the
// sources. Runs after the svc table is destroyed: no handler can be
// mid-call anymore. The sync goes first — its listener callbacks reach
// into the manager, so the manager must outlive the listener — then the
// manager (its servers borrow registry entries, so the registry must
// outlive them), and the sources last. The optional token is the daemon's
// shutdown cancellation: handed to the manager, it shortens the language
// server teardown ladder when a stop is already in flight.
project_state_destroy :: proc(d: ^Daemon, token: ^platform.Cancel_Token = nil) {
	web_state_destroy(d)
	if d.shadow != nil {
		shadow.shadow_destroy(d.shadow, d.allocator)
		free(d.shadow, d.allocator)
		d.shadow = nil
	}
	if d.mem_files != nil {
		svc.memory_files_destroy(d.mem_files)
		free(d.mem_files, d.allocator)
		d.mem_files = nil
	}
	if d.tracker != nil {
		tracker.manager_destroy(d.tracker)
		free(d.tracker, d.allocator)
		d.tracker = nil
	}
	if d.ls_sync != nil {
		if d.ed != nil {
			svc.editor_sync_uninstall(d.ls_sync, d.ed)
		}
		svc.editor_sync_destroy(d.ls_sync)
		free(d.ls_sync, d.allocator)
		d.ls_sync = nil
	}
	if d.ls != nil {
		langserver.manager_destroy(d.ls, token)
		free(d.ls, d.allocator)
		d.ls = nil
	}
	if d.ls_reg != nil {
		langserver.registry_destroy(d.ls_reg)
		d.ls_reg = nil
	}
	if d.lsp_src != nil {
		svc.lsp_source_destroy(d.lsp_src)
		free(d.lsp_src, d.allocator)
		d.lsp_src = nil
	}
	if d.lsp_port != nil {
		free(d.lsp_port, d.allocator)
		d.lsp_port = nil
	}
	if d.ed != nil {
		editor.editor_destroy(d.ed)
		free(d.ed, d.allocator)
		d.ed = nil
	}
	if d.ts != nil {
		// A refused destroy means a hot pin survived the drain above —
		// the source (and its struct) leak to process exit instead of
		// freeing under a reader; this path runs only at daemon exit.
		// The refusal is reported here: the destroy itself is a silent
		// predicate, so a test exercising the refusal stays quiet.
		if svc.ts_source_destroy(d.ts) {
			free(d.ts, d.allocator)
		} else {
			svc.ts_source_log_destroy_refusal(d.ts)
		}
		d.ts = nil
	}
	if d.db != nil {
		store.db_close(d.db)
		d.db = nil
	}
	if d.db_path != "" {
		delete(d.db_path, d.allocator)
		d.db_path = ""
	}
}

// handle_symbol_list returns the finalized tree for one file, refreshing
// its index rows in the same pass. Source order: the in-process
// tree-sitter pass first (the cheap path for grammar-backed languages);
// files it does not serve fall through to the LSP producer, which starts
// the file's language server on demand and writes through the same
// single-transaction index path. Files no source serves answer empty.
handle_symbol_list :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user

	path := ""
	if v, ok := jsonutil.obj_get(params, "path"); ok {
		#partial switch x in v {
		case json.String:
			path = string(x)
		case:
			return nil, platform.Wrapped{kind = .Invalid, msg = "path must be a string"}
		}
	} else {
		return nil, platform.Wrapped{kind = .Invalid, msg = "path is required"}
	}

	roots, err := svc.ts_source_file_symbols(d.ts, path, ctx.allocator)
	if err != nil {
		return nil, err
	}
	if len(roots) == 0 && d.lsp_src != nil {
		roots, err = svc.lsp_source_file_symbols(d.lsp_src, path, ctx.allocator, ctx.token)
		if err != nil {
			return nil, err
		}
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "symbols", svc.symbol_tree_json(roots, ctx.allocator))
	return json.Value(json.Object(out)), nil
}

// handle_symbol_find answers a cross-file name lookup from the L0 index
// with precise-by-default matching: exact (case-insensitive) unless a
// component carries `*` (glob discovery). The remaining name-path
// components are verified by walking the indexed parent chain (any depth),
// and a leading '/' anchors the outermost component at the top level.
// Filling is the crawl's job; the read side drops rows whose file has
// disappeared (the freshness gate below) and re-indexes paths whose rows
// no longer match the file's bytes (the content-freshness heal), so
// answers describe the current tree, not the last crawl.
handle_symbol_find :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user

	name := ""
	if v, ok := jsonutil.obj_get(params, "name"); ok {
		#partial switch x in v {
		case json.String:
			name = string(x)
		case:
			return nil, platform.Wrapped{kind = .Invalid, msg = "name must be a string"}
		}
	} else {
		return nil, platform.Wrapped{kind = .Invalid, msg = "name is required"}
	}
	if name == "" {
		return nil, platform.Wrapped{kind = .Invalid, msg = "name must not be empty"}
	}

	comps, anchored, perr := symbol_find_parse_pattern(name, ctx.allocator)
	if perr != nil {
		return nil, perr
	}

	// The innermost component seeds the query — exact (case-insensitive)
	// unless it carries a `*`, which turns it into a glob. Every remaining
	// component, and the anchor, is verified against the indexed parent
	// chain after the freshness gate.
	innermost := comps[len(comps)-1]
	rows, serr := symbol_find_seed_rows(d, innermost, ctx.allocator)
	if serr != nil {
		return nil, serr
	}

	// Freshness gate: a row whose file no longer exists (deleted or moved
	// away out-of-band, ahead of the TTL sweep) would answer from a ghost
	// path. One stat per distinct path decides liveness; gone paths are
	// purged so later lookups do not repeat the walk.
	missing := make(map[string]bool, 8, ctx.allocator)
	for row in rows {
		if _, known := missing[row.path]; !known {
			abs, _ := filepath.join({d.cfg.project_root, row.path}, context.temp_allocator)
			_, _, ok := util.stat_kind_size(abs)
			missing[row.path] = !ok
		}
	}
	for path, gone in missing {
		if gone {
			_ = store.delete_symbol_path(d.db, path)
		}
	}

	// Content freshness: the gate above proved the files exist, not that
	// the rows describe their current bytes — no writer refreshes rows
	// after an edit, so a renamed or moved-away symbol would keep
	// answering from the old rows with a stale line. One content hash per
	// distinct path decides; mismatched files are re-indexed through the
	// producers (a running language server at most — find never starts
	// one), and the seed query re-runs once so renamed-away and
	// renamed-into names both settle.
	if symbol_find_heal_stale(d, rows, missing, ctx.allocator) {
		rerun, rerr := symbol_find_seed_rows(d, innermost, ctx.allocator)
		if rerr != nil {
			return nil, rerr
		}
		rows = rerun
	}

	// Out-of-band discovery, on-miss half: no rows at all for the
	// innermost name means no read-side heal can help — heals re-check
	// paths already in the answer, and a name introduced by an external
	// write (an agent's own file creation, a rename on disk) has no row
	// anywhere to trigger one. One min-gap-guarded incremental walk
	// discovers it here; the seed re-runs so this answer, not just the
	// next one, reflects the walked state. The walk obeys the request's
	// cancel token and never starts a language server (find's rule).
	if len(rows) == 0 && symbol_find_refresh_on_miss(d, ctx) {
		rerun, rerr := symbol_find_seed_rows(d, innermost, ctx.allocator)
		if rerr != nil {
			return nil, rerr
		}
		rows = rerun
		// The walk only indexes files it just stat'ed, so every new path
		// is present and the ghost gate needs no re-run: paths absent
		// from `missing` answer as existing.
	}

	// Name-path verification at any depth: a row whose parent chain does
	// not match the components above the innermost — or whose outermost
	// component is not top-level under an anchored pattern — drops out
	// here, so the index answer obeys the same rule the seed query does.
	if len(comps) > 1 || anchored {
		verified := make([dynamic]store.Symbol_Name_Row_With_File, 0, len(rows), ctx.allocator)
		// One distinct-parents query per (path, name) pair per request:
		// multi-hit names repeat the same seed rows' chains, and the
		// recursive walk revisits pairs across levels — the memo collapses
		// both. Keys and values are request-arena strings (store rows and
		// the parents slices alike), so the map needs no key cloning — it
		// dies with the request arena.
		memo := make(map[Chain_Parents_Key][]string, 16, ctx.allocator)
		for row in rows {
			ok, cerr := symbol_find_chain_verified(d.db, row.path, row.name, comps, anchored, &memo, ctx.allocator)
			if cerr != nil {
				return nil, cerr
			}
			if ok {
				append(&verified, row)
			}
		}
		rows = verified[:]
	}

	items := make([dynamic]json.Value, 0, len(rows), ctx.allocator)
	for i in 0..<len(rows) {
		if missing[rows[i].path] {
			continue
		}
		row := jsonutil.json_object(6, ctx.allocator)
		jsonutil.obj_set(&row, "name", jsonutil.json_string(rows[i].name))
		jsonutil.obj_set(&row, "kind", jsonutil.json_string(rows[i].kind))
		jsonutil.obj_set(&row, "path", jsonutil.json_string(rows[i].path))
		jsonutil.obj_set(&row, "hash", jsonutil.json_string(rows[i].hash))
		jsonutil.obj_set(&row, "line", jsonutil.json_int(rows[i].line))
		jsonutil.obj_set(&row, "parent", jsonutil.json_string(rows[i].parent))
		append(&items, json.Value(json.Object(row)))
	}

	// The index is the merged view of both producers; when it holds
	// nothing live for the pattern, the running language servers top the
	// answer up through workspace/symbol — queried with the innermost
	// component (a full name path is a poor server query) and filtered
	// through the same matching rule, so a fuzzy server reply cannot leak
	// unrelated symbols into the answer. Only already-running servers are
	// asked — a name search must never spawn one (symbol_list and the
	// crawl stay the paths that start servers and fill the index).
	if len(items) == 0 && d.ls != nil {
		running := langserver.manager_running_clients(d.ls, ctx.allocator)
		defer delete(running)
		for rc in running {
			roots, werr := lsp.request_workspace_symbol(rc.client, innermost, ctx.allocator, ctx.token)
			langserver.manager_release(d.ls, rc.client)
			if werr != nil {
				continue
			}
			for root in roots {
				if root.location == nil || root.location.rel_path == "" {
					continue
				}
				if !symbol.index_topup_row_matches(comps, anchored, root.name, root.container_name) {
					continue
				}
				row := jsonutil.json_object(6, ctx.allocator)
				jsonutil.obj_set(&row, "name", jsonutil.json_string(root.name))
				jsonutil.obj_set(&row, "kind", jsonutil.json_string(symbol.kind_name(root.kind)))
				jsonutil.obj_set(&row, "path", jsonutil.json_string(root.location.rel_path))
				jsonutil.obj_set(&row, "hash", jsonutil.json_string(""))
				jsonutil.obj_set(&row, "line", jsonutil.json_int(i64(root.location.range.start.line)))
				jsonutil.obj_set(&row, "parent", jsonutil.json_string(root.container_name))
				append(&items, json.Value(json.Object(row)))
			}
		}
	}

	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "matches", jsonutil.json_array(items[:], ctx.allocator))
	return json.Value(json.Object(out)), nil
}

// symbol_find_seed_rows runs the innermost-component seed query: exact
// (case-insensitive) unless the component carries a `*` glob.
symbol_find_seed_rows :: proc(d: ^Daemon, innermost: string, a: mem.Allocator) -> (rows: []store.Symbol_Name_Row_With_File, err: platform.Err) {
	if strings.contains(innermost, "*") {
		return store.symbol_names_lookup_glob(d.db, innermost, a)
	}
	return store.symbol_names_lookup(d.db, innermost, a)
}

// symbol_find_heal_stale verifies the answer's rows against the current
// file bytes — the editor's view first, the same bytes a producer parse
// would see — and re-indexes every path whose indexed hash no longer
// matches. Returns true when any path was re-indexed (the caller re-runs
// the seed query once). Unreadable or unverifiable paths keep their rows:
// the honest answer until a crawl or a later heal, never a silent purge.
symbol_find_heal_stale :: proc(
	d: ^Daemon,
	rows: []store.Symbol_Name_Row_With_File,
	missing: map[string]bool,
	a: mem.Allocator,
) -> bool {
	// The minimal handler fixtures build no ts source: with nothing to
	// re-index through, the heal is a no-op and the rows answer as seeded.
	if d.ts == nil {
		return false
	}
	// All of a path's rows share one hash (the (path, hash) row key), so
	// the first row per path decides.
	row_hash := make(map[string]string, 8, a)
	defer delete(row_hash)
	for row in rows {
		if missing[row.path] {
			continue
		}
		if _, seen := row_hash[row.path]; !seen {
			row_hash[row.path] = row.hash
		}
	}
	healed := false
	for path, indexed_hash in row_hash {
		abs, _ := filepath.join({d.cfg.project_root, path}, context.temp_allocator)
		kind, size, mtime_ns, sok := util.stat_kind_size_mtime(abs)
		if !sok || kind == .Directory {
			continue
		}
		// The fingerprint gate: when the disk stat still matches the stat
		// the index recorded and live rows answer, the indexed hash IS the
		// hash of the current bytes — skip the full read plus content hash
		// this loop otherwise paid per answered path per request (a common
		// name seeded across thousands of files read every one of them).
		// Gate errors fail toward the read (the hash comparison below is
		// the authority).
		if store.fingerprint_skip(d.db, path, mtime_ns, size, platform.clock_now(d.cfg.clock)) {
			continue
		}
		contents, from_editor, rerr := svc.read_source_contents(d.ed, path, abs, a)
		if rerr != "" {
			continue
		}
		current := editor.content_hash_hex(contents, a)
		if from_editor {
			delete(contents, d.ed.allocator)
		}
		if current == indexed_hash {
			continue
		}
		if svc.index_heal_file(d.ts, d.lsp_src, path, a) {
			healed = true
		}
	}
	return healed
}

// symbol_find_refresh_on_miss claims and runs one incremental discovery
// walk for an empty answer (see the call site for why emptiness is the
// trigger). The guards, in order: a usable TS source, the min-gap window
// (a burst of misses for a genuinely absent name walks at most once per
// window — a completed walk means the index already reflects everything
// observable at that moment), and the single-walk claim shared with the
// background refresh loop. Returns true when a walk ran; the caller
// re-runs its seed query then. The walk's scratch rides the request's
// temp allocator to its normal reset — the walk never frees a frame it
// does not own.
symbol_find_refresh_on_miss :: proc(d: ^Daemon, ctx: ^svc.Svc_Ctx) -> bool {
	if d.ts == nil || d.db == nil {
		return false
	}
	if !index_refresh_due(d) {
		return false
	}
	if !index_refresh_claim(d) {
		return false
	}
	defer index_refresh_release(d)
	index_refresh_walk(d, ctx.token)
	return true
}

// SYMBOL_FIND_MAX_COMPONENTS bounds a symbol_find pattern's depth. Real
// name paths never approach it; the cap keeps a pathological pattern from
// driving one indexed parent query (and one stack frame) per component.
SYMBOL_FIND_MAX_COMPONENTS :: 32

// symbol_find_parse_pattern splits a symbol_find pattern into its
// components with the same grammar as the forest-side name-path matcher:
// a simple name, a relative path ("class/method" — a suffix of the full
// chain), or an anchored one ("/class/method" — the full chain from the
// top level). Trailing separators trim; interior empty segments are
// errors. Overload suffixes ("method[1]") are rejected with a steering
// message: the index rows carry no overload information, and silently
// matching the bare name would answer more than the pattern asked for.
symbol_find_parse_pattern :: proc(pattern: string, a: mem.Allocator) -> (comps: []string, anchored: bool, err: platform.Err) {
	if pattern == "" {
		return nil, false, platform.Wrapped{kind = .Invalid, msg = "name must not be empty"}
	}
	expr := strings.trim_left(pattern, "/")
	expr = strings.trim_right(expr, "/")
	anchored = strings.has_prefix(pattern, "/")

	dyn := make([dynamic]string, 0, 4, a)
	seg_start := 0
	for i := 0; i <= len(expr); i += 1 {
		if i < len(expr) && expr[i] != '/' {
			continue
		}
		part := expr[seg_start:i]
		seg_start = i + 1
		if part == "" {
			if i == 0 && anchored {
				continue
			}
			return nil, false, platform.Wrapped{
				kind = .Invalid,
				msg  = strings.concatenate({"name_path contains empty segment: ", pattern}, a),
			}
		}
		if component_has_overload_index(part) {
			return nil, false, platform.Wrapped{
				kind = .Invalid,
				msg = strings.concatenate({
					"overload index is not supported by symbol_find; use the bare name: ",
					part,
				}, a),
			}
		}
		append(&dyn, part)
	}
	if len(dyn) == 0 {
		return nil, false, platform.Wrapped{kind = .Invalid, msg = "name_path must not be empty after normalisation"}
	}
	if len(dyn) > SYMBOL_FIND_MAX_COMPONENTS {
		return nil, false, platform.Wrapped{
			kind = .Invalid,
			msg  = "name_path is too deep (more than 32 components)",
		}
	}
	return dyn[:], anchored, nil
}

// component_has_overload_index reports whether a pattern component carries
// the overload suffix grammar ("name[<digits>]"), mirroring the forest
// matcher's parse without adopting its disambiguation.
component_has_overload_index :: proc(comp: string) -> bool {
	if !strings.has_suffix(comp, "]") {
		return false
	}
	bracket := strings.last_index(comp, "[")
	if bracket < 0 {
		return false
	}
	idx := comp[bracket+1 : len(comp)-1]
	if len(idx) == 0 {
		return false
	}
	for i := 0; i < len(idx); i += 1 {
		if idx[i] < '0' || idx[i] > '9' {
			return false
		}
	}
	return true
}

// Chain_Parents_Key identifies one distinct-parents query: the symbol's
// file path and name. The values are the query's parent slices. Both ride
// the request arena, as does the memo map itself.
Chain_Parents_Key :: struct {
	path: string,
	name: string,
}

// symbol_find_chain_verified reports whether the symbol `name` in `path`
// has an ancestor chain matching every component of `comps` above the
// innermost (the seed query already matched that one). With `anchored`,
// the outermost matched component must itself sit at the top level — its
// parent set must contain the '' marker.
symbol_find_chain_verified :: proc(
	db: ^store.DB,
	path: string,
	name: string,
	comps: []string,
	anchored: bool,
	memo: ^map[Chain_Parents_Key][]string,
	a: mem.Allocator,
) -> (ok: bool, err: platform.Err) {
	return symbol_find_chain_walk(db, path, name, len(comps)-2, comps, anchored, memo, a)
}

// symbol_find_chain_walk is symbol_find_chain_verified's recursive core:
// `ci` walks the components above the innermost from the inside out, one
// indexed distinct-parents query per level (memoized per request — the
// same (path, name) pairs repeat across seed rows and recursion levels);
// same-name rows at several nesting levels union into the candidate set,
// and any matching branch satisfies the level. Depth is bounded by the
// parse-time component cap.
symbol_find_chain_walk :: proc(
	db: ^store.DB,
	path: string,
	name: string,
	ci: int,
	comps: []string,
	anchored: bool,
	memo: ^map[Chain_Parents_Key][]string,
	a: mem.Allocator,
) -> (ok: bool, err: platform.Err) {
	if ci < 0 && !anchored {
		return true, nil
	}
	key := Chain_Parents_Key{path = path, name = name}
	parents, cached := memo^[key]
	if !cached {
		perr: platform.Err
		parents, perr = store.symbol_names_distinct_parents(db, path, name, a)
		if perr != nil {
			return false, perr
		}
		memo^[key] = parents
	}
	if ci < 0 {
		// Anchored: the outermost component must sit at the top level,
		// which the '' parent marker in the index records.
		for p in parents {
			if p == "" {
				return true, nil
			}
		}
		return false, nil
	}
	for p in parents {
		if p == "" {
			continue
		}
		if !symbol.name_component_matches(comps[ci], p) {
			continue
		}
		matched, werr := symbol_find_chain_walk(db, path, p, ci-1, comps, anchored, memo, a)
		if werr != nil {
			return false, werr
		}
		if matched {
			return true, nil
		}
	}
	return false, nil
}

// handle_symbol_find_dead_code runs the whole-project dead-code scan:
// definitions come from the tree-sitter outline pass, uses from a
// lexical pass over every project text file, and a candidate is a
// definition whose name never occurs outside its own declaration spans.
// path_prefix filters the report only — the scan itself always covers
// the whole project. entry_prefixes replaces the default convention set
// wholesale; limit caps the report (the stats stay whole-population).
handle_symbol_find_dead_code :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user

	path_prefix := ""
	if v, ok := jsonutil.obj_get(params, "path_prefix"); ok {
		#partial switch x in v {
		case json.String:
			path_prefix = string(x)
		case:
			return nil, platform.Wrapped{kind = .Invalid, msg = "path_prefix must be a string"}
		}
	}
	if path_prefix != "" {
		if path_prefix[0] == '/' {
			return nil, platform.Wrapped{kind = .Invalid, msg = "path_prefix must be project-relative, not absolute"}
		}
		path_prefix = svc.normalize_rel(path_prefix, ctx.allocator)
		// Lexical containment: a relative filter may not escape the root.
		start := 0
		for i in 0..=len(path_prefix) {
			if i == len(path_prefix) || path_prefix[i] == '/' {
				if path_prefix[start:i] == ".." {
					return nil, platform.Wrapped{kind = .Invalid, msg = "path_prefix must not contain '..'"}
				}
				start = i + 1
			}
		}
	}

	entry_prefixes := svc.DEAD_SCAN_DEFAULT_ENTRY_PREFIXES
	if v, ok := jsonutil.obj_get(params, "entry_prefixes"); ok {
		arr, aok := jsonutil.as_array(v)
		if !aok {
			return nil, platform.Wrapped{kind = .Invalid, msg = "entry_prefixes must be an array of strings"}
		}
		prefixes := make([]string, len(arr), ctx.allocator)
		for i in 0..<len(arr) {
			#partial switch x in arr[i] {
			case json.String:
				prefixes[i] = string(x)
			case:
				return nil, platform.Wrapped{kind = .Invalid, msg = "entry_prefixes must be an array of strings"}
			}
			if prefixes[i] == "" {
				return nil, platform.Wrapped{kind = .Invalid, msg = "entry_prefixes must not contain empty strings"}
			}
		}
		entry_prefixes = prefixes
	}

	limit := svc.DEAD_SCAN_DEFAULT_LIMIT
	if v, ok := jsonutil.obj_get(params, "limit"); ok {
		#partial switch x in v {
		case json.Integer:
			limit = int(x)
		case:
			return nil, platform.Wrapped{kind = .Invalid, msg = "limit must be an integer"}
		}
		if limit <= 0 || limit > svc.DEAD_SCAN_MAX_LIMIT {
			return nil, platform.Wrapped{kind = .Invalid, msg = fmt.aprintf(
				"limit must be between 1 and %v", svc.DEAD_SCAN_MAX_LIMIT,
				allocator = ctx.allocator,
			)}
		}
	}

	ignore := svc.ignore_config_load(d.cfg.project_root, d.cfg.home, ctx.allocator)
	defer svc.spec_release_c_side(ignore.extra)
	stats: svc.Dead_Scan_Stats
	candidates, err := svc.dead_scan(d.ts, path_prefix, entry_prefixes, limit, ignore, &d.file_safety.deny_list, &stats, ctx.allocator, ctx.token)
	if err != nil {
		return nil, err
	}
	out := jsonutil.json_object(2, ctx.allocator)
	jsonutil.obj_set(&out, "candidates", svc.dead_scan_candidates_json(candidates, ctx.allocator))
	jsonutil.obj_set(&out, "stats", svc.dead_scan_stats_json(&stats, ctx.allocator))
	return json.Value(json.Object(out)), nil
}

// handle_ast_find_duplicates runs the whole-project duplicate scan: every
// grammar-served file parses once, named subtrees of at least min_nodes
// named nodes hash by full structure (kind "exact") and by
// identifier-canonical structure (kind "renamed"), and shared hashes group
// into reported clones. path_prefix filters the report only — the scan
// itself always covers the whole project. min_nodes sets the candidate
// floor and limit caps the report (the stats stay whole-population).
handle_ast_find_duplicates :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user

	path_prefix := ""
	if v, ok := jsonutil.obj_get(params, "path_prefix"); ok {
		#partial switch x in v {
		case json.String:
			path_prefix = string(x)
		case:
			return nil, platform.Wrapped{kind = .Invalid, msg = "path_prefix must be a string"}
		}
	}
	if path_prefix != "" {
		if path_prefix[0] == '/' {
			return nil, platform.Wrapped{kind = .Invalid, msg = "path_prefix must be project-relative, not absolute"}
		}
		path_prefix = svc.normalize_rel(path_prefix, ctx.allocator)
		// Lexical containment: a relative filter may not escape the root.
		start := 0
		for i := 0; i <= len(path_prefix); i += 1 {
			if i == len(path_prefix) || path_prefix[i] == '/' {
				if path_prefix[start:i] == ".." {
					return nil, platform.Wrapped{kind = .Invalid, msg = "path_prefix must not contain '..'"}
				}
				start = i + 1
			}
		}
	}

	min_nodes := svc.CLONE_SCAN_DEFAULT_MIN_NODES
	if v, ok := jsonutil.obj_get(params, "min_nodes"); ok {
		#partial switch x in v {
		case json.Integer:
			min_nodes = int(x)
		case:
			return nil, platform.Wrapped{kind = .Invalid, msg = "min_nodes must be an integer"}
		}
		if min_nodes < svc.CLONE_SCAN_MIN_NODES_FLOOR || min_nodes > svc.CLONE_SCAN_MAX_MIN_NODES {
			return nil, platform.Wrapped{kind = .Invalid, msg = fmt.aprintf(
				"min_nodes must be between %v and %v",
				svc.CLONE_SCAN_MIN_NODES_FLOOR, svc.CLONE_SCAN_MAX_MIN_NODES,
				allocator = ctx.allocator,
			)}
		}
	}

	limit := svc.CLONE_SCAN_DEFAULT_LIMIT
	if v, ok := jsonutil.obj_get(params, "limit"); ok {
		#partial switch x in v {
		case json.Integer:
			limit = int(x)
		case:
			return nil, platform.Wrapped{kind = .Invalid, msg = "limit must be an integer"}
		}
		if limit <= 0 || limit > svc.CLONE_SCAN_MAX_LIMIT {
			return nil, platform.Wrapped{kind = .Invalid, msg = fmt.aprintf(
				"limit must be between 1 and %v", svc.CLONE_SCAN_MAX_LIMIT,
				allocator = ctx.allocator,
			)}
		}
	}

	ignore := svc.ignore_config_load(d.cfg.project_root, d.cfg.home, ctx.allocator)
	defer svc.spec_release_c_side(ignore.extra)
	stats: svc.Clone_Stats
	groups, err := svc.clone_scan(d.ts, path_prefix, min_nodes, limit, ignore, &d.file_safety.deny_list, &stats, ctx.allocator, ctx.token)
	if err != nil {
		return nil, err
	}
	out := jsonutil.json_object(2, ctx.allocator)
	jsonutil.obj_set(&out, "groups", svc.clone_groups_json(groups, ctx.allocator))
	jsonutil.obj_set(&out, "stats", svc.clone_stats_json(&stats, ctx.allocator))
	return json.Value(json.Object(out)), nil
}

// handle_index_crawl fills the symbol index for the scope (whole project
// when `within` is absent). Cancellation takes effect by the next file.
handle_index_crawl :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user

	within := ""
	if v, ok := jsonutil.obj_get(params, "within"); ok {
		#partial switch x in v {
		case json.String:
			within = string(x)
		case:
			return nil, platform.Wrapped{kind = .Invalid, msg = "within must be a string"}
		}
	}

	ignore := svc.ignore_config_load(d.cfg.project_root, d.cfg.home, ctx.allocator)
	defer svc.spec_release_c_side(ignore.extra)
	stats: svc.Crawl_Stats
	err := svc.ts_source_crawl(d.ts, within, &stats, ignore, &d.file_safety.deny_list, ctx.allocator, ctx.token)
	if err != nil {
		return nil, err
	}
	// A successful whole-project crawl is exactly what the startup warm-up
	// would repeat; stamp its marker so the next daemon start skips it.
	// Scoped crawls leave the marker alone — they do not warm the project.
	if within == "" {
		if werr := store.kv_put(d.db, INDEX_WARM_KEY, "1"); werr != nil {
			return nil, werr
		}
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "stats", svc.crawl_stats_json(&stats, ctx.allocator))
	return json.Value(json.Object(out)), nil
}

// daemon_wall_ns feeds the tracker's uid minting: event uids order a
// persistent stream, so wall-clock ns (not the monotonic clock) is the
// input; the manager's watermark enforces strict increase across
// restarts and same-millisecond bursts.
daemon_wall_ns :: proc() -> i64 {
	return platform.wall_ms() * 1_000_000
}

// tracker_seeds draws the per-daemon origin label and rng seeds. Manager
// init must never fail over entropy: on an unavailable OS source the
// fallback mixes wall and monotonic clocks — uids stay unique through the
// timestamp and the duplicate retry either way.
tracker_seeds :: proc() -> (origin: u32, rng: u64) {
	buf: [12]u8
	if platform.random_bytes(buf[:]) {
		origin = u32(buf[0]) | (u32(buf[1]) << 8) | (u32(buf[2]) << 16) | (u32(buf[3]) << 24)
		rng = 0
		for i in 0..<8 {
			rng |= u64(buf[4 + i]) << cast(u32)(8 * i)
		}
		return origin, rng
	}
	return u32(platform.mono_ms()), u64(platform.wall_ms()) ~ 0x9e37_79b9_7f4a_7c15
}
