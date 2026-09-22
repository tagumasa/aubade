// The LSP symbol source: the language-server producer that fills the
// store's symbol index. One file read becomes one single-transaction
// write (L0 name rows + the L1 file row) through the same
// store.write_symbol_index the tree-sitter source uses — producers never
// touch SQLite directly, and the produced forest runs the same shared
// finalize pipeline, so name paths, parents, and bodies behave
// identically regardless of producer.
//
// Client resolution is a port proc (the daemon wires registry detection +
// manager ensure behind it; tests wire a fake peer), keeping this package
// decoupled from the manager's lifecycle.
package svc

import "base:runtime"
import "core:mem"
import "core:strings"

import "src:editor"
import "src:lsp"
import "src:platform"
import "src:safety"
import "src:store"
import "src:symbol"
import "src:util"

// Client_For_File_Proc resolves the language server serving a file.
// may_start selects the semantics: with it, the resolver may start (and
// wait for) the server; without it, only an already-running server is
// returned. language_id feeds the didOpen language and the index rows;
// normalize is the per-language rename hook from the registry entry (nil
// = none). The error is the caller's "no server" signal — producers treat
// every resolution failure as "not served here" rather than a hard error.
Client_For_File_Proc :: proc(
	user: rawptr,
	rel_path: string,
	may_start: bool,
	arena: mem.Allocator,
	token: ^platform.Cancel_Token,
) -> (client: ^lsp.Client, language_id: string, normalize: symbol.Normalize_Name_Proc, err: platform.Err)

// Client_Release_Proc drops one Client_For_File_Proc hand-out: the
// resolver pinned the serving server for the caller's duration, and the
// client must not be used after its release.
Client_Release_Proc :: proc(user: rawptr, client: ^lsp.Client)

LSP_Source :: struct {
	project_root: string, // absolute, owned clone
	db:           ^store.DB,
	clock:        ^platform.Clock, // monotonic clock for index timestamps
	ed:           ^editor.Editor, // buffer view for open files (nil = disk reads)
	// Total time budget (seconds) for the batch hover pass of
	// symbol_find_implementations with include_info; set by the daemon from
	// the resolved symbol_info_budget config (project → global → default).
	// 0 leaves the pass unbounded (tests and bare constructions).
	symbol_info_budget_s: f64,
	port:                 Client_For_File_Proc,
	release:              Client_Release_Proc, // nil = the resolver pins nothing
	user:                 rawptr,
	allocator:            runtime.Allocator,
}

lsp_source_init :: proc(
	src: ^LSP_Source,
	project_root: string,
	db: ^store.DB,
	clock: ^platform.Clock,
	ed: ^editor.Editor,
	port: Client_For_File_Proc,
	user: rawptr,
	release: Client_Release_Proc = nil,
	a := context.allocator,
) {
	src^ = {
		project_root = strings.clone(project_root, a),
		db           = db,
		clock        = clock,
		ed           = ed,
		port         = port,
		release      = release,
		user         = user,
		allocator    = a,
	}
}

lsp_source_destroy :: proc(src: ^LSP_Source) {
	delete(src.project_root, src.allocator)
	src^ = {}
}

// lsp_source_release drops the server pin a port hand-out took and, when
// the hand-out opened the document mirror (lsp_document_symbols' bridge
// open), that opener's didClose pair — the refcounted mirror keeps
// entries other openers still hold. uri "" (cache hits, resolve
// refusals, clientless callers) opens nothing and closes nothing. Ops
// that hold a client beyond lsp_document_symbols' return release it
// when their last request on it completes; nil release (test fakes)
// pins nothing.
lsp_source_release :: proc(src: ^LSP_Source, client: ^lsp.Client, uri: string = "") {
	if client != nil && uri != "" {
		_ = lsp.doc_close(client, uri)
	}
	if src.release != nil && client != nil {
		src.release(src.user, client)
	}
}

// lsp_source_file_symbols returns the finalized symbol roots for one file
// (allocated in `a`) and refreshes the file's index rows in the same pass.
// Files with no language server (none configured, none detected, start
// refused or in cooldown) return empty roots and no error — the caller's
// source order decides what to try next. Only protocol and index failures
// surface as errors.
lsp_source_file_symbols :: proc(src: ^LSP_Source, rel_path: string, a := context.allocator, token: ^platform.Cancel_Token = nil) -> (roots: []^symbol.Symbol, err: platform.Err) {
	file_roots, client, uri, lang_id, derr := lsp_document_symbols(src, rel_path, a, token)
	// The lenient producer drops the client and language on the floor;
	// drop their pins, the bridge open's pair, and clones too.
	lsp_source_release(src, client, uri)
	// The swallowed-by-design results are still `a`-owned: release what
	// the lenient contract drops (the uri and language clones and, on a
	// port refusal, the re-wrapped message).
	if uri != "" {
		delete(uri, a)
	}
	if lang_id != "" {
		delete(lang_id, a)
	}
	if derr != nil {
		#partial switch w in derr {
		case platform.Wrapped:
			if w.msg != "" {
				delete(w.msg, a)
			}
		case:
		}
		return nil, nil
	}
	return file_roots, nil
}

// lsp_document_symbols is the strict core behind the lenient producer:
// it resolves the file's server (starting it on demand), opens the
// document with the buffer-aware contents, converts the documentSymbol
// reply into the finalized forest, and refreshes the file's index rows.
// Unlike lsp_source_file_symbols a failed server resolution propagates
// (re-wrapped into `a` — the port builds its errors on the scratch
// arena), so the LSP-backed symbol tools can answer with the reason.
// Empty roots without an error mean the file genuinely has no symbols.
// The client stays owned by the manager; uri is cloned into `a`.
//
// use_cache serves the outline family from the L1 payload when the
// (path, hash) row is current — skipping the port call, the document
// open, and the documentSymbol round trip, and returning client=nil (the
// caller's release tolerates that). Callers that need the server for
// follow-up requests pass false and keep the resolve-then-request
// behavior.
//
// may_start=false resolves only an already-running server — the read-side
// freshness heal and the editor-change hook run where a spawn (fork/exec
// plus a 45 s handshake) must never happen (inside find's request or the
// editor's per-file notification).
lsp_document_symbols :: proc(
	src: ^LSP_Source,
	rel_path: string,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
	use_cache: bool = true,
	may_start: bool = true,
) -> (roots: []^symbol.Symbol, client: ^lsp.Client, uri: string, language_id: string, err: platform.Err) {
	// Per-call scratch arena: the document reply's raw JSON dies with the
	// call; only the converted forest (in `a`) and the index rows survive
	// into the caller's scope.
	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, src.allocator)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)

	rel := normalize_rel(rel_path, scratch)
	if rel == "" {
		return nil, nil, "", "", wrapped_err(.Invalid, "lsp source: empty relative path", a)
	}
	abs, perr := safety.pathguard_validate_contained(src.project_root, rel, scratch)
	if perr.reason != "" {
		return nil, nil, "", "", wrapped_err(.Invalid, strings.concatenate({"lsp source: invalid path: ", perr.reason}, scratch), a)
	}
	kind, size, sok := util.stat_kind_size(abs, scratch)
	if !sok {
		return nil, nil, "", "", wrapped_err(.NotFound, strings.concatenate({"lsp source: path not found: ", rel}, scratch), a)
	}
	if kind == .Directory {
		return nil, nil, "", "", wrapped_err(.Invalid, "lsp source: path is a directory", a)
	}

	// The contents the server must see: the shared editor-or-disk read
	// (from_editor IS the ownership of `contents` — free through the same
	// flag, never through "was it empty"). Resolved before the port call
	// so the L1 probe below can skip the server entirely.
	contents, from_editor, crerr := read_source_contents(src.ed, rel, abs, size, scratch)
	if crerr != "" {
		return nil, nil, "", "", wrapped_err(
			.Internal,
			strings.concatenate({"lsp source: ", crerr, ": ", rel}, scratch),
			a,
		)
	}
	defer if from_editor {
		delete(contents, src.ed.allocator)
	}

	// L1 payload: a hit resolves the outline without the server round
	// trip (fill order mirror -> SQLite -> re-fetch). The key is hashed
	// from the contents just read, so a hit is fresh by construction;
	// read errors and undecodable payloads are plain misses.
	hash := editor.content_hash_hex(contents, scratch)
	if use_cache {
		if payload, row_lang, found, perr := store.symbol_cache_payload(src.db, rel, hash, platform.clock_now(src.clock), scratch); perr == nil && found {
			if cached, dok := symbol.decode_symbol_payload(payload, abs, rel, a); dok {
				bf := symbol.body_factory_from_contents(contents, scratch)
				symbol.populate_symbol_bodies(cached, bf, 0, a)
				return cached, nil, symbol.file_uri(abs, a), strings.clone(row_lang, a), nil
			}
		}
	}

	normalize: symbol.Normalize_Name_Proc
	cerr: platform.Err
	client, language_id, normalize, cerr = src.port(src.user, rel, may_start, scratch, token)
	if cerr != nil {
		// The scratch arena dies at return: the error crosses into `a`
		// with its cause chain intact (not flattened to text).
		return nil, nil, "", "", platform.err_clone(cerr, a)
	}
	// The port builds its returns on the scratch arena; everything this
	// procedure returns must live in `a` (callers own and free it there).
	language_id = strings.clone(language_id, a)

	uri = symbol.file_uri(abs, a)
	// Refcounted per URI: a shared epoch keeps its text, and this open's
	// pair is the caller's lsp_source_release (uri in hand).
	_ = lsp.doc_open(client, uri, language_id, contents)

	// The raw reply lives in the scratch arena — the converted forest (in
	// `a`) clones everything it keeps. A failing request re-wraps into `a`
	// so the error outlives the scratch reset at return.
	value, rerr := lsp.request_document_symbol(client, uri, scratch, token)
	if rerr != nil {
		// The error contract empties every return, so the caller can
		// neither release the pin nor free the clones — the producer drops
		// its own hand-out (a leaked pin parks a retired server forever:
		// the sweep destroys only at inflight zero).
		lsp_source_release(src, client, uri)
		if uri != "" {
			delete(uri, a)
		}
		if language_id != "" {
			delete(language_id, a)
		}
		return nil, nil, "", "", platform.err_clone(rerr, a)
	}
	forest := lsp.symbols_from_document_symbol(value, contents, a)
	if len(forest) == 0 {
		return nil, client, uri, language_id, nil
	}

	bf := symbol.body_factory_from_contents(contents, scratch)
	opts := symbol.Pipeline_Options{
		allocator         = a,
		normalize     = normalize,
		abs_path      = abs,
		rel_path      = rel,
		body_factory  = bf,
	}
	roots = symbol.finalize_symbol_tree(forest, opts)
	if len(roots) == 0 {
		return nil, client, uri, language_id, nil
	}

	// hash was computed from these contents before the L1 probe; the row
	// key and the payload are written together with the L0 rows.
	rows := index_rows_from_tree(roots, scratch)
	if werr := store.write_symbol_index(src.db, rel, hash, language_id, rows, symbol.encode_symbol_payload(roots, scratch), platform.clock_now(src.clock)); werr != nil {
		lsp_source_release(src, client, uri)
		if uri != "" {
			delete(uri, a)
		}
		if language_id != "" {
			delete(language_id, a)
		}
		return nil, nil, "", "", platform.err_clone(werr, a)
	}
	return roots, client, uri, language_id, nil
}
