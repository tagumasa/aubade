// TS symbol source: the tree-sitter producer that fills the store's symbol
// index. One file read becomes one row set (L0 name rows + the L1 file
// row); the crawl commits a directory's files in one batched transaction,
// walking the project with the builtin directory-name exclusions and
// per-directory .gitignore scoping, under a file-count budget. The index
// is a cache, never the source of truth:
// callers re-validate by content hash when they need freshness, and a miss
// is filled by parsing on demand through here. Symlinked entries are not
// followed — skipping them removes the cycle risk by construction.
package svc

import "base:runtime"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:sort"
import "core:strings"
import "core:sync"
import "src:config"
import "src:editor"
import "src:pathspec"
import "src:platform"
import "src:regex"
import "src:safety"
import "src:store"
import "src:symbol"
import "src:ts"
import "src:util"

MAX_CRAWL_FILES :: 5000
MAX_SOURCE_FILE_BYTES :: 1 << 20 // 1 MiB per file, index inputs included
MAX_CRAWL_DEPTH :: 100
GITIGNORE_FILE :: ".gitignore"

TS_Source :: struct {
	project_root: string, // absolute, cloned in allocator
	db:           ^store.DB,
	clock:        ^platform.Clock, // monotonic clock for index timestamps
	// The editor's view of open files (nil = disk reads — the way test
	// harnesses construct it): single-file reads resolve the bytes the
	// editor's transactions apply against, never a disk state an open
	// buffer may not carry.
	ed:           ^editor.Editor,
	// L2 hot parse-tree LRU: repeat symbol work reuses the cached tree
	// when the bytes still match; the editor bridge keeps buffered trees
	// pinned and incrementally edited.
	hot:          ts.Hot_Trees,
	// Per-language outliners, built on first use and kept for the source's
	// lifetime; a nil entry marks a language that serves no outline data.
	// Compiled queries are immutable and every parse/query call runs its
	// own parser and cursor, so outliners are shared across request
	// threads after the build — the mutex guards only the lazy map itself.
	// Regex predicates match through call-local PCRE2 buffers
	// (regex_match_local): a compiled pattern is thread-safe to match, its
	// cached match_data is not.
	outliners:    map[string]^ts.Outliner,
	// The prebuilt extension tier of grammar detection
	// (ts.registry_extension_map): constant size, first-wins table order
	// baked at init — the crawl probes one map lookup per dot-suffix
	// instead of scanning every grammar's extension list per file.
	ext_map:      map[string]int,
	mu: sync.Mutex,
	allocator:    runtime.Allocator,
}

ts_source_init :: proc(src: ^TS_Source, project_root: string, db: ^store.DB, clock: ^platform.Clock, a := context.allocator) {
	src^ = {
		project_root = strings.clone(project_root, a),
		db           = db,
		clock        = clock,
		outliners    = make(map[string]^ts.Outliner, 8, a),
		ext_map      = ts.registry_extension_map(a),
		allocator    = a,
	}
	ts.hot_trees_init(&src.hot, a)
}

// ts_source_destroy releases the outliners, the hot cache, and the
// source, and reports whether it did. It refuses — returns false,
// leaking the whole source — while any hot entry is still pinned: a
// reader holding a pin borrows the tree, the outliners, and the struct
// itself, so freeing under it would be a use-after-free. Teardown
// drains every producer first (the daemon joins its threads and pool
// before destroying project state), so a surviving pin means a bug
// elsewhere; the leak, reaped at process exit, is the containment.
// The refusal is silent by design — the destroy is a predicate, and the
// callers that treat a refusal as a leak to process exit (the daemon
// teardown, the test fixtures) report it through
// ts_source_log_destroy_refusal; a unit test exercising the refusal
// asserts the boolean without putting an error line in the suite log.
ts_source_destroy :: proc(src: ^TS_Source) -> bool {
	if ts.hot_pinned_count(&src.hot) > 0 {
		return false
	}
	for _, o in src.outliners {
		if o != nil {
			ts.outliner_destroy(o)
		}
	}
	delete(src.outliners)
	// The extension map's keys are owned clones: free them before the
	// table (a bare map delete frees only the table).
	for k, _ in src.ext_map {
		delete(k, src.allocator)
	}
	delete(src.ext_map)
	ts.hot_trees_destroy(&src.hot)
	delete(src.project_root, src.allocator)
	src^ = {}
	return true
}

// ts_source_log_destroy_refusal reports why a refused destroy leaves the
// source leaked — naming the pinned rel paths, so the offender is
// identified instead of counted. For callers that treat a refusal as a
// leak to process exit; harmless on a source whose destroy succeeded
// (no pins, no line).
ts_source_log_destroy_refusal :: proc(src: ^TS_Source) {
	keys := ts.hot_pinned_keys(&src.hot, context.temp_allocator)
	if len(keys) == 0 {
		return
	}
	parts := make([dynamic]string, 0, len(keys) + 4, context.temp_allocator)
	append(&parts, "svc: ")
	append(&parts, util.int_to_dec(len(keys), context.temp_allocator))
	append(&parts, " hot parse-tree entries still pinned at destroy (")
	for k, i in keys {
		if i > 0 {
			append(&parts, ", ")
		}
		append(&parts, k)
	}
	append(&parts, "); leaking the ts source instead of freeing under it")
	util.log_error(strings.concatenate(parts[:], context.temp_allocator))
}

Crawl_Stats :: struct {
	dirs_visited:      int,
	dirs_pruned:       int, // gitignore-pruned or depth-capped subtrees
	dirs_failed:       int, // unreadable directories
	files_indexed:     int,
	files_unchanged:    int, // skipped: disk fingerprint matches and rows are live
	files_ignored:      int, // gitignore-matched files
	files_unsupported:  int, // no grammar or no outline query
	files_oversize:     int,
	files_failed:       int, // read/parse/index errors
	symbols:            int, // L0 rows written
	paths_purged:       int, // vanished files whose rows the walk removed
	truncated:          bool, // file budget reached before the walk finished
	cancelled:          bool, // the cancel token fired mid-walk
}

// ---------------------------------------------------------------------------
// Single-file path
// ---------------------------------------------------------------------------

// ts_source_file_symbols returns the finalized symbol roots for one file
// (allocated in `a`; the caller releases them with
// symbol.symbol_forest_destroy) and refreshes the file's index rows in the
// same pass. Files without tree-sitter outline data return empty roots and
// no error — the caller routes those to another source.
ts_source_file_symbols :: proc(src: ^TS_Source, rel_path: string, a := context.allocator) -> (roots: []^symbol.Symbol, err: platform.Err) {
	roots, _, err = ts_source_file_symbols_detailed(src, rel_path, a)
	return roots, err
}

// ts_source_file_symbols_detailed is ts_source_file_symbols with the
// decline/empty distinction the freshness heal needs: served=false means
// no grammar or outline query serves the file (the LSP producer may),
// while served=true with empty roots means the file parses to an empty
// outline — its indexed rows describe bytes it no longer carries.
ts_source_file_symbols_detailed :: proc(src: ^TS_Source, rel_path: string, a := context.allocator) -> (roots: []^symbol.Symbol, served: bool, err: platform.Err) {
	// Per-call scratch arena: nothing here is shared mutable state (the
	// parser and query cursor are per-call; the db serializes its own
	// writes), so symbol lookups no longer wait behind a crawl.
	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, src.allocator)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)

	rel := normalize_rel(rel_path, scratch)
	if rel == "" {
		return nil, false, wrapped_err(.Invalid, "ts source: empty relative path", a)
	}
	abs, perr := safety.pathguard_validate_contained(src.project_root, rel, scratch)
	if perr.reason != "" {
		return nil, false, wrapped_err(.Invalid, strings.concatenate({"ts source: invalid path: ", perr.reason}, scratch), a)
	}
	kind, size, sok := util.stat_kind_size(abs, scratch)
	if !sok {
		return nil, false, wrapped_err(.NotFound, strings.concatenate({"ts source: path not found: ", rel}, scratch), a)
	}
	if kind == .Directory {
		return nil, false, wrapped_err(.Invalid, "ts source: path is a directory (crawl it instead)", a)
	}

	// The contents to parse: the editor's view when it holds one for
	// this file (the clone belongs to the editor's allocator), else the
	// disk read — the same discipline the LSP producer uses, so every
	// seam resolves the bytes the editor's transactions apply against. A
	// read error falls back to the disk path below.
	contents := ""
	from_editor := false
	if src.ed != nil {
		read, rerr, _ := editor.editor_read_file(src.ed, rel)
		if rerr == .None {
			contents = read
			from_editor = true
		}
	}
	defer if from_editor {
		delete(contents, src.ed.allocator)
	}

	filename := rel_base(rel)
	idx, ok := ts.registry_detect_with_map(src.ext_map, filename, scratch)
	if !ok {
		// Shebang fallback: extensionless scripts resolve via their
		// interpreter line — one bounded disk read on the disk path; the
		// editor path slices the line out of the bytes already in hand.
		if from_editor {
			first := contents
			for i := 0; i < len(contents); i += 1 {
				if contents[i] == '\n' {
					first = contents[:i]
					break
				}
			}
			idx, ok = ts.registry_lookup_by_shebang(first)
		} else if size <= MAX_SOURCE_FILE_BYTES {
			if first, perr := read_first_line(abs, scratch); perr == "" {
				idx, ok = ts.registry_lookup_by_shebang(first)
			}
		}
		if !ok {
			return nil, false, nil
		}
	}
	table := ts.GRAMMARS
	lang := table[idx].name
	o := outliner_for(src, lang)
	if o == nil {
		return nil, false, nil
	}

	if !from_editor {
		disk, rerr := read_source_file(abs, scratch)
		if rerr != "" {
			return nil, true, wrapped_err(.Internal, strings.concatenate({"ts source: ", rerr, ": ", rel}, scratch), a)
		}
		contents = disk
	}

	oerr: platform.Err
	roots, oerr = ts_source_outline_for_contents(src, o, lang, contents, abs, rel, a, scratch)
	return roots, true, oerr
}

// ts_source_outline_for_contents is the shared resolution tail: serve one
// file's outline from its resolved contents and refresh the index rows for
// the bytes the outline was built from. The L1 payload probe comes first
// (a hit is fresh by construction — rows were committed whenever the
// payload was, so no rewrite), then the L2 hot tree, then a fresh parse;
// every parse path rewrites the file's L0 rows and L1 payload in one
// transaction. An empty outline returns no roots WITHOUT a row rewrite —
// the caller decides what an emptied file means (the freshness heal purges
// the path's rows). The forest is allocated in `a`; scratch is the
// per-call arena.
ts_source_outline_for_contents :: proc(
	src: ^TS_Source,
	o: ^ts.Outliner,
	lang: string,
	contents: string,
	abs: string,
	rel: string,
	a: mem.Allocator,
	scratch: mem.Allocator,
) -> (roots: []^symbol.Symbol, err: platform.Err) {
	if len(contents) > MAX_SOURCE_FILE_BYTES {
		msg := strings.concatenate({
			"ts source: file is too large (", util.int_to_dec(len(contents), scratch),
			" bytes); maximum is ", util.int_to_dec(MAX_SOURCE_FILE_BYTES, scratch), " bytes): ", rel,
		}, scratch)
		return nil, wrapped_err(.Invalid, msg, a)
	}

	// L1 payload first: the key is hashed from the contents just read, so
	// a hit is fresh by construction and this file never parses — the
	// decode plus line-sliced bodies are far cheaper than a parse (and the
	// L2 probe is skipped too: L1 comes first in the resolution order). A
	// read error or an undecodable payload is a plain miss — the index is
	// a cache, not a source of truth.
	hash := editor.content_hash_hex(contents, scratch)
	if payload, _, found, perr := store.symbol_cache_payload(src.db, rel, hash, platform.clock_now(src.clock), scratch); perr == nil && found {
		if cached, dok := symbol.decode_symbol_payload(payload, abs, rel, a); dok {
			bf := symbol.body_factory_from_contents(contents, scratch)
			symbol.populate_symbol_bodies(cached, bf, 0, a)
			return cached, nil
		}
	}

	// L2 hot tree: a byte-identical hit skips the parse; anything else
	// parses fresh and refreshes the entry in place (the cache never
	// replaces keys — pinned readers stay safe).
	ferr: string
	if e, hok := ts.hot_acquire(&src.hot, rel); hok {
		if e.tree != nil && e.source == contents {
			roots, ferr = outline_from_tree(o, e.lang_name, e.source, abs, rel, true, e.tree, a, scratch)
			ts.hot_release(&src.hot, rel, e)
		} else {
			ts.hot_release(&src.hot, rel, e)
			roots, ferr = parse_and_cache(src, o, lang, contents, abs, rel, a, scratch)
		}
	} else {
		roots, ferr = parse_and_cache(src, o, lang, contents, abs, rel, a, scratch)
	}
	if ferr != "" {
		return nil, wrapped_err(.Internal, strings.concatenate({"ts source: ", ferr, ": ", rel}, scratch), a)
	}
	if len(roots) == 0 {
		return nil, nil
	}

	rows := index_rows_from_tree(roots, scratch)
	if werr := store.write_symbol_index(src.db, rel, hash, lang, rows, symbol.encode_symbol_payload(roots, scratch), platform.clock_now(src.clock)); werr != nil {
		// The forest lives in `a` (the request arena): it must not be
		// individually freed — the arena dies wholesale at request end.
		return nil, platform.err_clone(werr, a)
	}
	return roots, nil
}

// ts_source_index_contents indexes the bytes handed in — the editor change
// hook's post-edit row refresh. The contents are the editor's view at
// commit time and the caller holds the file's lock: this proc must not
// re-enter the editor, so it never reads the file itself. Returns
// served=false when no tree-sitter outline serves the file's language (the
// caller may try the LSP producer) and ok=false on error (the rows stay
// for the read-side freshness heal or the next crawl).
ts_source_index_contents :: proc(src: ^TS_Source, rel_in: string, contents: string) -> (served: bool, ok: bool) {
	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, src.allocator)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)

	rel := normalize_rel(rel_in, scratch)
	if rel == "" {
		return false, false
	}

	idx, found := ts.registry_detect_with_map(src.ext_map, rel_base(rel), scratch)
	if !found {
		// Shebang fallback, sliced from the bytes already in hand.
		first := contents
		for i := 0; i < len(contents); i += 1 {
			if contents[i] == '\n' {
				first = contents[:i]
				break
			}
		}
		idx, found = ts.registry_lookup_by_shebang(first)
		if !found {
			return false, true
		}
	}
	table := ts.GRAMMARS
	lang := table[idx].name
	o := outliner_for(src, lang)
	if o == nil {
		return false, true
	}

	abs := strings.concatenate({src.project_root, "/", rel}, scratch)
	// The forest lives in the scratch arena — only the DB copies the rows
	// keep survive its teardown below.
	roots, oerr := ts_source_outline_for_contents(src, o, lang, contents, abs, rel, scratch, scratch)
	if oerr != nil {
		return true, false
	}
	if len(roots) == 0 {
		// The committed bytes parse to an empty outline: the file declares
		// nothing now, and the previous rows must not keep answering for
		// it.
		_ = store.delete_symbol_path(src.db, rel)
	}
	return true, true
}

// index_heal_file re-indexes one file whose indexed rows are stale (the
// caller compared the row hash against the current bytes): the
// tree-sitter producer first — it rewrites the file's rows wholesale —
// and when the language serves no tree-sitter outline, the LSP producer
// from a running server (never starts one: this runs on find's read
// path). A file that parses to an empty outline keeps no symbols: its
// rows are purged. The return tells whether the file's rows are now
// current; false leaves them untouched (the producer declined or failed —
// the rows stay until a crawl or a later heal rather than being deleted
// unverifiable).
index_heal_file :: proc(
	src: ^TS_Source,
	lsp_src: ^LSP_Source,
	rel: string,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> bool {
	roots, served, err := ts_source_file_symbols_detailed(src, rel, a)
	if err != nil {
		return false
	}
	if served {
		if len(roots) == 0 {
			// Parses to an empty outline: the file declares nothing now.
			_ = store.delete_symbol_path(src.db, normalize_rel(rel, context.temp_allocator))
		}
		return true
	}
	if lsp_src == nil {
		return false
	}
	l_roots, client, uri, lang_id, lerr := lsp_document_symbols(lsp_src, rel, a, token, use_cache = true, may_start = false)
	if lerr != nil {
		return false
	}
	lsp_source_release(lsp_src, client, uri)
	if uri != "" {
		delete(uri, a)
	}
	if lang_id != "" {
		delete(lang_id, a)
	}
	if len(l_roots) == 0 {
		// The producer wrote no rows for these bytes (empty outline): the
		// stale rows must not keep answering for them.
		_ = store.delete_symbol_path(lsp_src.db, normalize_rel(rel, context.temp_allocator))
	}
	return true
}

// ---------------------------------------------------------------------------
// Project crawl
// ---------------------------------------------------------------------------

// ts_source_crawl walks the scope (a subdirectory, a single file, or the
// whole project when within_rel is empty) and fills the symbol index for
// every tree-sitter-served file it reaches, under the file-count budget.
// The walk is incremental: a file whose recorded disk fingerprint
// (file_stat) still matches AND whose rows are live is skipped without a
// read or parse — only genuinely changed, new, or row-less files parse.
// A completed whole-project walk also purges the rows of paths it no
// longer sees (renamed-away or deleted files stop answering within one
// pass instead of living out the symbol TTL) — except under subtrees it
// could not enumerate, where absence is not provable. Errors stop nothing:
// unreadable paths are counted in stats. Only invalid scopes and
// cancellation produce an error return; `a` owns the returned error's
// message. The optional token is checked once per entry, so a cancel
// takes effect by the next file.
ts_source_crawl :: proc(
	src: ^TS_Source,
	within_rel: string,
	stats: ^Crawl_Stats,
	ignore: Ignore_Config,
	deny: ^safety.Deny_List,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> platform.Err {
	stats^ = {}
	// Per-crawl arenas: scratch one file's working set, reset around every
	// file; the walk arena carries only the recursion's own frame data —
	// each recursing directory's cloned rel/abs path and the unseen
	// prefixes, both O(depth). Directory entries and per-entry joined
	// paths do NOT live here: entries are freed at each directory boundary
	// and child paths build in reusable buffers, so a whole-project walk's
	// transient memory stays flat in the file count (arena-placed
	// enumeration once scaled it with the project — every walk transient
	// ~O(files), freed only into the process allocator where the pages
	// never return to the OS).
	walk_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&walk_arena, src.allocator)
	defer mem.dynamic_arena_destroy(&walk_arena)
	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, src.allocator)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	walk := mem.dynamic_arena_allocator(&walk_arena)

	// The seen-set records every regular file the walk reaches (any
	// disposition) as a 64-bit path hash — the rel strings themselves are
	// not retained (a 151k-file walk once carried every path) — and the
	// unseen-list the rel prefixes of subtrees it could not enumerate
	// (unreadable, depth-capped, or symlinked), cloned onto the walk
	// arena. Both exist only on the whole-project walk: they are the
	// purge's notion of "still in the project", and a scoped crawl must
	// not mistake out-of-scope paths for vanished ones.
	seen: map[u64]bool
	unseen: [dynamic]string
	seen_ptr: ^map[u64]bool
	unseen_ptr: ^[dynamic]string
	if within_rel == "" {
		seen = make(map[u64]bool, 1024, walk)
		unseen = make([dynamic]string, 0, 4, walk)
		seen_ptr = &seen
		unseen_ptr = &unseen
	}

	// Batched index writes: one transaction per directory (and one per
	// CRAWL_BATCH_MAX_BYTES of accumulated payloads) instead of one per
	// file. The batch arena backs every cloned entry; free_all between
	// flushes bounds its memory.
	batch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&batch_arena, src.allocator)
	defer mem.dynamic_arena_destroy(&batch_arena)
	batch := make([dynamic]store.Symbol_Write, 0, 64, src.allocator)
	defer delete(batch)
	b := Crawl_Batch{arena = &batch_arena, entries = &batch}

	// Reusable child-path builders: each directory seeds the buffers with
	// its own rel/abs path and every entry appends at that watermark,
	// truncating back after use, so per-entry paths cost no allocation
	// (see crawl_dir).
	rel_buf := make([dynamic]u8, 0, 512, src.allocator)
	defer delete(rel_buf)
	abs_buf := make([dynamic]u8, 0, 1024, src.allocator)
	defer delete(abs_buf)

	// The walk context bundles the per-entry helpers' shared state (see
	// Crawl_Walk) so crawl_dir and crawl_index_file carry only their
	// per-call facts.
	wctx := Crawl_Walk{
		src     = src,
		stats   = stats,
		ignore  = ignore,
		deny    = deny,
		walk    = walk,
		scratch = &scratch_arena,
		rel_buf = &rel_buf,
		abs_buf = &abs_buf,
		batch   = &b,
		seen    = seen_ptr,
		unseen  = unseen_ptr,
		token   = token,
	}

	scope_rel := normalize_rel(within_rel, walk)
	start_abs := src.project_root
	if scope_rel != "" {
		abs, perr := safety.pathguard_validate_contained(src.project_root, scope_rel, walk)
		if perr.reason != "" {
			return wrapped_err(.Invalid, strings.concatenate({"ts source crawl: invalid path: ", perr.reason}, walk), a)
		}
		kind, _, sok := util.stat_kind_size(abs, walk)
		if !sok {
			return wrapped_err(.NotFound, strings.concatenate({"ts source crawl: path not found: ", scope_rel}, walk), a)
		}
		if kind != .Directory {
			// The single-file scope faces the same deny contract as the
			// walk: deny_walk_init runs only below, so the file branch
			// must judge the scope itself — a deny-listed,
			// grammar-served file must not be parsed and persisted.
			if deny != nil && (safety.is_denied(deny, abs) || safety.is_sensitive_system_path(abs)) {
				return wrapped_err(
					.Denied,
					strings.concatenate({"ts source crawl: read denied for sensitive path: ", scope_rel}, a),
					a,
				)
			}
			crawl_index_file(&wctx, abs, scope_rel, rel_base(scope_rel))
			crawl_batch_flush(src, &b, stats)
			return nil
		}
		start_abs = abs
	}
	if deny != nil {
		safety.deny_walk_init(&wctx.deny_walk, start_abs, walk)
	}

	stack := make([dynamic]^pathspec.Path_Spec, 0, 8, src.allocator)
	defer {
		for i in 0..<len(stack) {
			pathspec.pathspec_destroy(stack[i])
		}
		delete(stack)
	}
	crawl_dir(&wctx, start_abs, scope_rel, 0, &stack)
	crawl_batch_flush(src, &b, stats)
	// Vanished-file purge: only a walk that enumerated the whole project
	// and was neither truncated nor cancelled may conclude that an
	// unvisited recorded path left the project — truncation and
	// cancellation leave an uncharacterizable unvisited tail, so they
	// suppress the purge wholesale. A subtree the walk could not enumerate
	// (unreadable, depth-capped, or symlinked) is narrower: its prefix sits
	// in unseen, and the purge still concludes absence everywhere it
	// walked.
	// A purge error is logged and retried by the next walk; whatever
	// completed is consistent (each per-path drop is its own transaction).
	if seen_ptr != nil && !stats.truncated && !stats.cancelled {
		purged, perr := store.file_stat_purge_unseen(src.db, seen, unseen[:])
		if perr != nil {
			util.log_warning("crawl: vanished-path purge failed; the next walk retries")
		} else {
			stats.paths_purged = purged
		}
	}
	if stats.cancelled {
		return wrapped_err(.Cancelled, "ts source crawl: cancelled", a)
	}
	return nil
}

// Crawl_Walk is one crawl's shared state: everything the per-entry
// helpers need that never changes across the walk. Grouping it keeps
// crawl_dir's signature down to the per-call facts (which directory, at
// what depth, on which ignore stack) and makes a walk-wide addition a
// field, not another threaded parameter.
Crawl_Walk :: struct {
	src:     ^TS_Source,
	stats:   ^Crawl_Stats,
	ignore:  Ignore_Config,
	deny:    ^safety.Deny_List,
	walk:    runtime.Allocator, // walk-frame arena (recursed dir paths, unseen prefixes — O(depth))
	scratch: ^mem.Dynamic_Arena, // per-file scratch, reset around every file
	rel_buf: ^[dynamic]u8, // reusable child rel-path builder (see crawl_dir)
	abs_buf: ^[dynamic]u8, // reusable child abs-path builder (see crawl_dir)
	batch:   ^Crawl_Batch,
	// The purge inputs, nil on scoped crawls (a scoped walk must not
	// mistake out-of-scope paths for vanished ones): every regular file
	// the walk reaches (seen, keyed by path hash — see ts_source_crawl),
	// and the rel prefixes of subtrees it cannot enumerate (unseen —
	// unreadable, depth-capped, or symlinked).
	seen:   ^map[u64]bool,
	unseen: ^[dynamic]string,
	// The walk's deny-composition state (see safety.Deny_Walk): the
	// current directory's resolved spelling, mutated to the child's at
	// every recursion and restored on return. Zero-valued when deny is nil
	// and never consulted then.
	deny_walk: safety.Deny_Walk,
	token:     ^platform.Cancel_Token, // nil: no cancellation
}

// walk_unseen records a subtree prefix the walk could not enumerate: the
// purge keeps every recorded path under it, because absence there is not
// provable. The prefix is cloned — callers may pass a reusable-buffer
// view that dies with the next entry. Only whole-project crawls track
// prefixes.
walk_unseen :: proc(w: ^Crawl_Walk, rel_dir: string) {
	if w.unseen != nil {
		append(w.unseen, strings.clone(rel_dir, w.walk))
	}
}

// walk_buf_set/walk_buf_append build child paths in the crawl's reusable
// buffers: set resets the buffer to one path, append adds a suffix at the
// caller's watermark. Growth reallocates but never rewrites earlier
// bytes, so a caller's [0:mark] prefix stays valid across appends.
walk_buf_set :: proc(buf: ^[dynamic]u8, s: string) {
	resize(buf, 0)
	walk_buf_append(buf, s)
}

walk_buf_append :: proc(buf: ^[dynamic]u8, s: string) {
	at := len(buf^)
	resize(buf, at + len(s))
	if len(s) > 0 {
		mem.copy(&buf^[at], raw_data(transmute([]u8)s), len(s))
	}
}

crawl_dir :: proc(
	w: ^Crawl_Walk,
	abs_dir: string,
	rel_dir: string,
	depth: int,
	stack: ^[dynamic]^pathspec.Path_Spec,
) -> (stopped: bool) {
	if depth > MAX_CRAWL_DEPTH {
		// The subtree exists; the walk just stops here. Its files may well
		// be recorded (a scoped crawl restarts depth at its scope root),
		// so the purge must not read this prefix as vanished.
		walk_unseen(w, rel_dir)
		w.stats.dirs_pruned += 1
		return false
	}
	w.stats.dirs_visited += 1

	// Directory entries on the source allocator, freed at this boundary:
	// arena-placed entries accumulated for the whole crawl (arenas free
	// wholesale), scaling every walk's transient memory with the
	// project's file count. On the heap each directory's entries are
	// returned before the next is read — the peak is one directory's
	// entries and the freed blocks are reused instead of ratcheting RSS.
	entries, derr := os.read_all_directory_by_path(abs_dir, w.src.allocator)
	if derr != nil {
		// Unreadable: the subtree's contents are unknown, not absent.
		walk_unseen(w, rel_dir)
		w.stats.dirs_failed += 1
		return false
	}
	defer os.file_info_slice_delete(entries, w.src.allocator)
	sort_entries_by_name(entries)

	pushed := false
	if !w.ignore.no_gitignore {
		pushed = maybe_push_gitignore(w.src.allocator, mem.dynamic_arena_allocator(w.scratch), abs_dir, rel_dir, stack)
	}

	// Child paths build into the reusable buffers at this directory's
	// watermark: a file's path is a buffer view consumed before the next
	// entry, while a recursing directory's path is cloned to the walk
	// arena (the subtree rewrites the buffers). The root case
	// (rel_dir == "") mirrors join_rel: top-level entries carry no
	// leading slash.
	walk_buf_set(w.rel_buf, rel_dir)
	walk_buf_set(w.abs_buf, abs_dir)
	rel_mark := len(w.rel_buf^)
	abs_mark := len(w.abs_buf^)

	for i in 0..<len(entries) {
		if w.token != nil {
			if _, fired := platform.token_check(w.token); fired {
				w.stats.cancelled = true
				stopped = true
				break
			}
		}
		name := entries[i].name
		if config.default_ignored_dir(name) {
			continue
		}
		if rel_mark > 0 {
			walk_buf_append(w.rel_buf, "/")
		}
		walk_buf_append(w.rel_buf, name)
		child_rel := string(w.rel_buf^[:])
		if pathspec.pathspec_match_path(child_rel, w.ignore.extra) {
			if entries[i].type == .Directory {
				w.stats.dirs_pruned += 1
			} else {
				w.stats.files_ignored += 1
			}
			resize(w.rel_buf, rel_mark)
			continue
		}
		if managed_state_rel(w.ignore.managed_rel, child_rel) {
			// Aubade's own state tree is never indexed, wherever the folder
			// template placed it.
			if entries[i].type == .Directory {
				w.stats.dirs_pruned += 1
			} else {
				w.stats.files_ignored += 1
			}
			resize(w.rel_buf, rel_mark)
			continue
		}
		#partial switch entries[i].type {
		case .Directory:
			if !w.ignore.no_gitignore && stack_match_dir(stack, child_rel, mem.dynamic_arena_allocator(w.scratch)) {
				w.stats.dirs_pruned += 1
			} else {
				walk_buf_append(w.abs_buf, "/")
				walk_buf_append(w.abs_buf, name)
				child_abs := string(w.abs_buf^[:])
				// Sensitive-path deny (symlink-resolved): credential-looking
				// trees are never indexed. The walk composes the child's
				// resolved spelling (safety.Deny_Walk) instead of re-resolving
				// from the root per entry; save/restore around the recursion.
				if w.deny != nil {
					saved_walk := w.deny_walk
					child_dw: safety.Deny_Walk
					if safety.deny_walk_entry(&saved_walk, w.deny, child_abs, name, &child_dw) {
						w.stats.dirs_pruned += 1
					} else {
						w.deny_walk = child_dw
						if crawl_dir(w, strings.clone(child_abs, w.walk), strings.clone(child_rel, w.walk), depth + 1, stack) {
							stopped = true
						}
					}
					w.deny_walk = saved_walk
				} else {
					if crawl_dir(w, strings.clone(child_abs, w.walk), strings.clone(child_rel, w.walk), depth + 1, stack) {
						stopped = true
					}
				}
				resize(w.abs_buf, abs_mark)
			}
		case .Regular:
			if w.stats.files_indexed >= MAX_CRAWL_FILES {
				w.stats.truncated = true
				stopped = true
			} else {
				if !w.ignore.no_gitignore && stack_match_file(stack, child_rel) {
					w.stats.files_ignored += 1
				} else {
					walk_buf_append(w.abs_buf, "/")
					walk_buf_append(w.abs_buf, name)
					child_abs := string(w.abs_buf^[:])
					if w.deny != nil && safety.deny_walk_entry(&w.deny_walk, w.deny, child_abs, name, nil) {
						w.stats.files_ignored += 1
					} else {
						crawl_index_file(w, child_abs, child_rel, name)
					}
					resize(w.abs_buf, abs_mark)
				}
			}
		case .Symlink:
			// Not followed (the cycle-risk rule): files behind this
			// spelling may still be recorded — editor writes and scoped
			// crawls spell paths through links — so the purge keeps the
			// prefix.
			walk_unseen(w, child_rel)
		case: // other special files are neither indexed nor purged around
		}
		resize(w.rel_buf, rel_mark)
		if stopped {
			break
		}
	}

	if pushed {
		last := len(stack^) - 1
		pathspec.pathspec_destroy(stack[last])
		pop(stack)
	}
	// Directory boundary = transaction boundary: this directory's files
	// commit together (a cancel stops between directories, keeping the
	// already-committed ones).
	crawl_batch_flush(w.src, w.batch, w.stats)
	return stopped
}

// One transaction's worth of crawl output. The arena backs every string
// and byte slice in entries; free_all between flushes bounds the batch to
// roughly CRAWL_BATCH_MAX_BYTES regardless of project size.
Crawl_Batch :: struct {
	arena:   ^mem.Dynamic_Arena,
	entries: ^[dynamic]store.Symbol_Write,
	bytes:   int,
	// Queued name rows across the batch — the flush's failure path owes
	// stats.symbols this count back when the transaction never wrote them.
	symbols: int,
}

CRAWL_BATCH_MAX_BYTES :: 1024 * 1024

// crawl_index_file parses one file and queues its index rows into the
// batch, unless the incremental skip applies (recorded disk fingerprint
// matches and live rows answer for the path). Its own arena discipline:
// the per-file scratch is reset on entry and exit, so nothing allocated
// here survives into the next file or the walk frame — the batch clones
// what it keeps.
crawl_index_file :: proc(w: ^Crawl_Walk, abs_path, rel_path, filename: string) {
	mem.dynamic_arena_free_all(w.scratch)
	defer mem.dynamic_arena_free_all(w.scratch)
	sa := mem.dynamic_arena_allocator(w.scratch)

	if w.seen != nil {
		w.seen^[platform.path_hash64(rel_path)] = true
	}

	idx, ok := ts.registry_detect_with_map(w.src.ext_map, filename, sa)
	if !ok {
		// Shebang fallback for extensionless scripts (one bounded read
		// per miss — the walk's fast path stays read-free).
		if first, perr := read_first_line(abs_path, sa); perr == "" {
			idx, ok = ts.registry_lookup_by_shebang(first)
		}
		if !ok {
			w.stats.files_unsupported += 1
			return
		}
	}
	// Materialize the registry locally before indexing (the compiler
	// rejects variable indexing straight into constant data).
	table := ts.GRAMMARS
	lang := table[idx].name
	o := outliner_for(w.src, lang)
	if o == nil {
		w.stats.files_unsupported += 1
		return
	}

	_, size, mtime_ns, sok := util.stat_kind_size_mtime(abs_path, sa)
	if !sok {
		w.stats.files_failed += 1
		return
	}
	// Incremental skip: the disk fingerprint recorded at the last commit
	// still matches AND live rows answer for the path — rows can vanish
	// under an unchanged stat (the TTL sweep), so liveness is probed, not
	// assumed. Probe errors fail toward work: the file parses rather than
	// being skipped unverifiable. (store.fingerprint_skip answers the same
	// conjunction from the parent-memory mirror — one bulk load per daemon
	// life instead of two point queries per file per walk.)
	if store.fingerprint_skip(w.src.db, rel_path, mtime_ns, size, platform.clock_now(w.src.clock)) {
		w.stats.files_unchanged += 1
		return
	}
	if size > MAX_SOURCE_FILE_BYTES {
		w.stats.files_oversize += 1
		return
	}
	// The stat gate above only classifies; the read itself re-derives the
	// bound at read time, so a file growing after the stat surfaces a read
	// failure here instead of an unbounded read.
	contents, rerr := read_source_file(abs_path, sa)
	if rerr != "" {
		w.stats.files_failed += 1
		return
	}

	roots, ferr := parse_outline_roots(o, lang, contents, abs_path, rel_path, false, sa, sa)
	if ferr != "" {
		w.stats.files_failed += 1
		return
	}

	hash := editor.content_hash_hex(contents, sa)
	rows := index_rows_from_tree(roots, sa)
	// An emptied outline still queues the entry: the transaction replaces
	// the path's rows wholesale (nothing for these bytes) and records the
	// fingerprint, so a file that now declares no symbols stops answering
	// and does not re-parse on every pass.
	crawl_batch_append(w.batch, rel_path, hash, lang, rows, symbol.encode_symbol_payload(roots, sa), mtime_ns, size)
	w.stats.files_indexed += 1
	w.stats.symbols += len(rows)
	if crawl_batch_full(w.batch) {
		crawl_batch_flush(w.src, w.batch, w.stats)
	}
}

crawl_batch_append :: proc(b: ^Crawl_Batch, path, hash, language: string, names: []store.Symbol_Name_Row, payload: []u8, mtime_ns, size: i64) {
	a := mem.dynamic_arena_allocator(b.arena)
	rows := make([]store.Symbol_Name_Row, len(names), a)
	for n, i in names {
		rows[i] = {
			name   = strings.clone(n.name, a),
			kind   = strings.clone(n.kind, a),
			line   = n.line,
			parent = strings.clone(n.parent, a),
		}
	}
	bytes := make([]u8, len(payload), a)
	if len(payload) > 0 {
		mem.copy(&bytes[0], &payload[0], len(payload))
	}
	append(b.entries, store.Symbol_Write{
		path     = strings.clone(path, a),
		hash     = strings.clone(hash, a),
		language = strings.clone(language, a),
		names    = rows,
		payload  = bytes,
		mtime_ns = mtime_ns,
		size     = size,
	})
	b.bytes += len(payload) + len(names) * 48
	b.symbols += len(names)
}

crawl_batch_full :: proc(b: ^Crawl_Batch) -> bool {
	return b.bytes >= CRAWL_BATCH_MAX_BYTES
}

// crawl_batch_flush commits the accumulated writes in one transaction and
// resets the batch. A failed batch moves its files from indexed to failed
// in the stats — the per-file accounting of the unbatched path, applied at
// flush granularity.
crawl_batch_flush :: proc(src: ^TS_Source, b: ^Crawl_Batch, stats: ^Crawl_Stats) {
	if len(b.entries^) == 0 {
		return
	}
	if werr := store.write_symbol_index_batch(src.db, b.entries[:], platform.clock_now(src.clock)); werr != nil {
		stats.files_failed += len(b.entries^)
		stats.files_indexed -= len(b.entries^)
		// The queued rows were never written — refund them too, keeping
		// the per-file accounting of the unbatched path.
		stats.symbols -= b.symbols
	}
	b.bytes = 0
	b.symbols = 0
	resize(b.entries, 0)
	mem.dynamic_arena_free_all(b.arena)
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

// outliner_for returns the cached outliner for a language, building it on
// first use under the map's mutex (the build is once per language; a
// concurrent second builder would leak its query). Nil means the language
// serves no outline data (no grammar, an empty tags query, or no definition
// captures); the verdict is cached. The returned outliner is immutable —
// sharing it across threads needs no lock.
outliner_for :: proc(src: ^TS_Source, lang: string) -> ^ts.Outliner {
	sync.mutex_lock(&src.mu)
	o, have := src.outliners[lang]
	if have {
		sync.mutex_unlock(&src.mu)
		return o
	}
	built: ^ts.Outliner = nil
	b, err := ts.build_outliner(lang, src.allocator)
	if err == "" && b != nil {
		if b.query_empty || b.query == nil || !has_definition_capture(b) {
			ts.outliner_destroy(b)
		} else {
			built = b
		}
	}
	src.outliners[lang] = built
	sync.mutex_unlock(&src.mu)
	return built
}

has_definition_capture :: proc(o: ^ts.Outliner) -> bool {
	count := ts.query_capture_count(o.query)
	for i in u32(0)..<count {
		name := ts.query_capture_name_borrowed(o.query, i)
		if len(name) > len(ts.OUTLINE_DEFINITION_PREFIX) && strings.has_prefix(name, ts.OUTLINE_DEFINITION_PREFIX) {
			return true
		}
	}
	return false
}

// parse_outline_roots runs one file through parse → outline → convert →
// finalize. The returned forest is allocated in `a`; every intermediate
// (parse tree, outline forest, converter, body factory) lives in `scratch`
// and dies with it. Bodies are extracted only when the caller keeps the
// forest; index-only crawls skip them.
parse_outline_roots :: proc(
	o: ^ts.Outliner,
	lang: string,
	contents: string,
	abs_path: string,
	rel_path: string,
	want_bodies: bool,
	a: runtime.Allocator,
	scratch: runtime.Allocator,
) -> (roots: []^symbol.Symbol, err: string) {
	pr, perr := ts.parse(contents, lang)
	if perr != "" {
		return nil, perr
	}
	defer ts.parse_release(&pr)
	return outline_from_tree(o, lang, contents, abs_path, rel_path, want_bodies, pr.tree, a, scratch)
}

// parse_and_cache parses fresh and lands the tree in the L2 hot cache —
// refreshing an existing entry in place (pinned readers stay safe) or
// inserting a new one.
parse_and_cache :: proc(
	src: ^TS_Source,
	o: ^ts.Outliner,
	lang: string,
	contents: string,
	abs_path: string,
	rel_path: string,
	a: runtime.Allocator,
	scratch: runtime.Allocator,
) -> (roots: []^symbol.Symbol, err: string) {
	pr, perr := ts.parse(contents, lang)
	if perr != "" {
		return nil, perr
	}
	roots, err = outline_from_tree(o, lang, contents, abs_path, rel_path, true, pr.tree, a, scratch)
	if !ts.hot_refresh(&src.hot, rel_path, pr.tree, pr.lang, lang, contents) {
		ts.hot_insert(&src.hot, rel_path, pr.tree, pr.lang, lang, contents)
	}
	return roots, err
}

// Scan_Tree_Handle is one file's parse tree for the whole-project scans
// (dead-code, duplicates), which walk every grammar-served file per call:
// a byte-identical cached tree is borrowed — pinned, no parse — and
// anything else (miss, stale bytes, tombstone) parses fresh and is freed
// locally at release. Scans never INSERT into the cache: measured on a
// 10k-file project with 4 scan workers, scan-side inserts evict under
// the cache's mutex in their release hooks (whole-tree frees) and the
// resulting convoy eats the parallel speedup entirely — and a scan of
// thousands of files would flush the interactive symbol working set out
// of the LRU for a reuse the budget (~5 MB of source retained) cannot
// deliver anyway.
Scan_Tree_Handle :: struct {
	pr:       ts.Parse_Result, // owned fresh parse (freed at release)
	entry:    ^ts.Hot_Tree, // borrowed hot entry (nil when the parse is owned)
	hot:      ^ts.Hot_Trees,
	rel:      string,
	lang:     string, // grammar of the owned parse (the borrow carries its own)
	contents: string, // the bytes `tree` was parsed against
	tree:     ts.Tree,
}

// scan_tree_acquire resolves one scan file's tree: an L2 hit whose source
// is byte-identical to the just-read contents borrows the cached tree;
// anything else (miss, stale bytes, tombstone) parses fresh. ok=false
// covers only the parse failure — the caller's grammar resolution has
// already happened, so a failure leaves nothing to clean up.
scan_tree_acquire :: proc(src: ^TS_Source, lang: string, contents: string, rel: string) -> (h: Scan_Tree_Handle, ok: bool) {
	if e, hok := ts.hot_acquire(&src.hot, rel); hok {
		if e.tree != nil && e.source == contents {
			return Scan_Tree_Handle{entry = e, hot = &src.hot, rel = rel, contents = contents, tree = e.tree}, true
		}
		ts.hot_release(&src.hot, rel, e)
	}
	pr, perr := ts.parse(contents, lang)
	if perr != "" {
		return {}, false
	}
	return Scan_Tree_Handle{pr = pr, hot = &src.hot, rel = rel, lang = lang, contents = contents, tree = pr.tree}, true
}

// scan_tree_release ends a handle: a borrowed entry unpins, an owned
// parse is freed — nothing lands in the cache (see Scan_Tree_Handle).
// The handle is zeroed either way.
scan_tree_release :: proc(h: ^Scan_Tree_Handle) {
	if h.entry != nil {
		ts.hot_release(h.hot, h.rel, h.entry)
	} else if h.pr.tree != nil {
		ts.tree_delete(h.pr.tree)
	}
	h^ = {}
}

// outline_from_tree runs the outline pipeline over an existing tree. The
// tree stays owned by its holder (the hot cache or the parse result) —
// nothing here releases it.
outline_from_tree :: proc(
	o: ^ts.Outliner,
	lang: string,
	contents: string,
	abs_path: string,
	rel_path: string,
	want_bodies: bool,
	tree: ts.Tree,
	a: runtime.Allocator,
	scratch: runtime.Allocator,
) -> (roots: []^symbol.Symbol, err: string) {
	// Everything below lives in `scratch`, an arena: no explicit destroys —
	// delete()/free() would route arena memory through the general
	// allocator (bad frees). The arena reset owns the lifetime.
	forest, report := ts.outline_tree(o, tree, contents, scratch)
	if ts.report_declined(&report) || len(forest) == 0 {
		return nil, ""
	}

	conv := symbol.position_converter_new(contents, scratch)
	roots = symbol.convert_outline_forest(forest, conv, contents, lang, a)

	bf: ^symbol.Body_Factory = nil
	if want_bodies {
		bf = symbol.body_factory_from_contents(contents, scratch)
	}
	opts := symbol.Pipeline_Options{
		allocator        = a,
		abs_path     = abs_path,
		rel_path     = rel_path,
		body_factory = bf,
	}
	roots = symbol.finalize_symbol_tree(roots, opts)
	return roots, ""
}

// index_rows_from_tree flattens a finalized forest into L0 name rows. The
// row strings borrow the forest (SQLite copies them at bind time); parent
// falls back to container_name for owned symbols left at the top level.
index_rows_from_tree :: proc(roots: []^symbol.Symbol, scratch: runtime.Allocator) -> []store.Symbol_Name_Row {
	rows := make([dynamic]store.Symbol_Name_Row, 0, 32, scratch)
	append_index_rows(&rows, roots)
	return rows[:]
}

append_index_rows :: proc(rows: ^[dynamic]store.Symbol_Name_Row, roots: []^symbol.Symbol, depth := 0) {
	for i in 0..<len(roots) {
		sym := roots[i]
		parent := ""
		if sym.parent != nil {
			parent = sym.parent.name
		} else if sym.container_name != "" {
			parent = sym.container_name
		}
		line: i64 = 0
		if sym.selection_range != nil {
			line = i64(sym.selection_range.start.line)
		}
		append(rows, store.Symbol_Name_Row{name = sym.name, kind = symbol.kind_name(sym.kind), line = line, parent = parent})
		if len(sym.children) > 0 && depth < symbol.MAX_TREE_DEPTH {
			append_index_rows(rows, sym.children[:], depth + 1)
		}
	}
}

// read_source_file reads one indexed source file under the 1 MiB budget,
// the bytes owned by `a`. The bound is enforced at read time
// (util.read_bounded_file) — no caller stat is trusted to bound the read,
// so a file that grows after a stat still surfaces the refusal.
read_source_file :: proc(abs_path: string, a: runtime.Allocator) -> (contents: string, err: string) {
	data, outcome, refused := util.read_bounded_file(abs_path, MAX_SOURCE_FILE_BYTES, a)
	if outcome == .Too_Large {
		// The bounded reader names the bytes it saw at the refusal.
		return "", strings.concatenate({
			"file is too large (", util.int_to_dec(cast(int)refused, a),
			" bytes); maximum is ", util.int_to_dec(MAX_SOURCE_FILE_BYTES, a), " bytes",
		}, a)
	}
	if outcome != .Ok {
		return "", "read failed"
	}
	return string(data), ""
}

// read_first_line returns the first line of a file for the shebang
// probe — one bounded read, never the whole file. A leading UTF-8 BOM is
// stripped so a BOM'd script's `#!` stays visible (whitespace trimming
// does not remove U+FEFF). The result is cloned into the caller's
// allocator (the buffer is stack-owned).
read_first_line :: proc(abs_path: string, a := context.allocator) -> (line: string, err: string) {
	f, oerr := os.open(abs_path, {.Read}, os.Permissions{.Read_User})
	if oerr != nil {
		return "", "open failed"
	}
	defer os.close(f)
	buf: [512]u8
	n, rerr := os.read(f, buf[:])
	if n <= 0 {
		if rerr != nil {
			return "", "read failed"
		}
		return "", "empty"
	}
	data := util.strip_utf8_bom(buf[:n])
	for i in 0..<len(data) {
		if data[i] == '\n' {
			data = data[:i]
			break
		}
	}
	return strings.clone(string(data), a), ""
}

// wrapped_err builds an error whose message outlives this call: scratch
// arenas are reset at return, so escaping messages are cloned into the
// caller's allocator.
wrapped_err :: proc(kind: platform.Err_Kind, msg: string, a: runtime.Allocator) -> platform.Err {
	return platform.Wrapped{kind = kind, msg = strings.clone(msg, a)}
}

// normalize_rel canonicalizes a caller-supplied relative path into the
// slash-separated key form: backslashes become '/', leading "./" and
// trailing slashes are stripped, "" and "." mean the project root.
normalize_rel :: proc(rel: string, a: runtime.Allocator) -> string {
	buf := make([dynamic]u8, 0, len(rel) + 1, a)
	start := 0
	if len(rel) >= 2 && rel[0] == '.' && rel[1] == '/' {
		start = 2
	}
	for i in start..<len(rel) {
		c := rel[i]
		if c == '\\' {
			c = '/'
		}
		append(&buf, c)
	}
	end := len(buf)
	for end > 0 && buf[end - 1] == '/' {
		end -= 1
	}
	out := string(buf[:end])
	if out == "." {
		delete(buf)
		return ""
	}
	return out
}

join_rel :: proc(dir: string, name: string, a: runtime.Allocator) -> string {
	if dir == "" {
		return strings.clone(name, a)
	}
	return strings.concatenate({dir, "/", name}, a)
}

rel_base :: proc(rel: string) -> string {
	if i := strings.last_index_byte(rel, '/'); i >= 0 {
		return rel[i + 1:]
	}
	return rel
}

// ---------------------------------------------------------------------------
// gitignore scoping
// ---------------------------------------------------------------------------

// maybe_push_gitignore loads a directory's .gitignore onto the spec stack.
// The compiled spec (patterns cloned into spec_alloc) is popped and
// destroyed by the caller when the directory is left; `scratch` owns the
// content read and the raw pattern strings for the call's duration.
maybe_push_gitignore :: proc(
	spec_alloc: runtime.Allocator,
	scratch: runtime.Allocator,
	abs_dir: string,
	rel_dir: string,
	stack: ^[dynamic]^pathspec.Path_Spec,
) -> bool {
	parts := []string{abs_dir, GITIGNORE_FILE}
	git_path, jerr := filepath.join(parts, scratch)
	if jerr != nil {
		return false
	}
	// The budget holds at read time, not just at the stat: a .gitignore
	// growing past the cap mid-walk still refuses instead of ballooning
	// the crawl.
	data, outcome, _ := util.read_bounded_file(git_path, MAX_SOURCE_FILE_BYTES, scratch)
	if outcome != .Ok {
		return false
	}
	patterns, _ := pathspec.gitignore_patterns_from_content(string(data), rel_dir, scratch)
	if len(patterns) == 0 {
		return false
	}
	spec := pathspec.from_lines(patterns, spec_alloc)
	if spec == nil || len(spec.patterns) == 0 {
		return false
	}
	append(&stack^, spec)
	return true
}

// stack_match_once applies gitignore precedence across the stacked specs:
// patterns are evaluated root-first and the last match decides, so a deeper
// .gitignore overrides a shallower one.
stack_match_once :: proc(stack: ^[dynamic]^pathspec.Path_Spec, path: string) -> bool {
	matched := false
	for s in 0..<len(stack^) {
		spec := stack[s]
		for i in 0..<len(spec.patterns) {
			if regex.regex_match(spec.patterns[i].re, path) {
				matched = !spec.patterns[i].negate
			}
		}
	}
	return matched
}

stack_match_file :: proc(stack: ^[dynamic]^pathspec.Path_Spec, rel: string) -> bool {
	return stack_match_once(stack, rel)
}

stack_match_dir :: proc(stack: ^[dynamic]^pathspec.Path_Spec, rel: string, a: runtime.Allocator) -> bool {
	if stack_match_once(stack, rel) {
		return true
	}
	with_slash := strings.concatenate({rel, "/"}, a)
	return stack_match_once(stack, with_slash)
}

// ---------------------------------------------------------------------------
// Deterministic directory order (walk entries sort by name)
// ---------------------------------------------------------------------------

Sorted_Entries :: struct {
	entries: []os.File_Info,
}

entries_len :: proc(it: sort.Interface) -> int {
	se := cast(^Sorted_Entries)it.collection
	return len(se.entries)
}

entries_less :: proc(it: sort.Interface, i, j: int) -> bool {
	se := cast(^Sorted_Entries)it.collection
	return se.entries[i].name < se.entries[j].name
}

entries_swap :: proc(it: sort.Interface, i, j: int) {
	se := cast(^Sorted_Entries)it.collection
	se.entries[i], se.entries[j] = se.entries[j], se.entries[i]
}

sort_entries_by_name :: proc(entries: []os.File_Info) {
	if len(entries) < 2 {
		return
	}
	se := Sorted_Entries{entries = entries}
	sort.sort({len = entries_len, less = entries_less, swap = entries_swap, collection = &se})
}
