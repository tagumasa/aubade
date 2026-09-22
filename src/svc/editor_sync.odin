// Editor→services bridge: installs a Buffer_Listener on the editor and
// forwards open/change/close into (a) didOpen/didChange/didClose on the
// language server resolved for the file — through the same
// Client_For_File_Proc port the LSP symbol source uses — (b) the L2
// hot parse-tree cache (pin on open, incremental ts_tree_edit on change,
// unpin on close), and (c) the symbol index: every change rewrites the
// file's L0 rows so symbol_find answers track the committed bytes. Best
// effort by design: a server that cannot start or a dead connection must
// never fail the edit. The next change re-opens the document after a
// server restart (a didChange for an unopened document degrades to a
// didOpen with the current contents), and servers re-read files on
// didOpen.
package svc

import "base:runtime"
import "core:strings"
import "core:sync"

import "src:editor"
import "src:lsp"
import "src:symbol"
import "src:ts"

Editor_Sync :: struct {
	project_root: string, // absolute, owned clone
	port:         Client_For_File_Proc,
	release:      Client_Release_Proc, // nil = the resolver pins nothing
	hot:          ^ts.Hot_Trees, // nil = no L2 maintenance (tests)
	// Post-edit index refresh (nil = none, the way test harnesses build
	// the sync): every buffer change rewrites the file's L0 rows through
	// the tree-sitter source.
	ts_src:       ^TS_Source,
	// Ledger of the buffer pins this sync applied (normalized rel_paths,
	// owned clones): teardown never fires buffer-close notifications —
	// editor_destroy releases buffers silently — so the ledger is the only
	// reliable unpin path at shutdown.
	pinned:       [dynamic]string,
	mu:           sync.Mutex, // guards pinned
	user:         rawptr,
	allocator:    runtime.Allocator,
}

editor_sync_init :: proc(
	s: ^Editor_Sync,
	project_root: string,
	port: Client_For_File_Proc,
	user: rawptr,
	a := context.allocator,
	hot: ^ts.Hot_Trees = nil,
	release: Client_Release_Proc = nil,
	ts_src: ^TS_Source = nil,
) {
	s^ = {
		project_root = strings.clone(project_root, a),
		port         = port,
		release      = release,
		hot          = hot,
		ts_src       = ts_src,
		pinned       = make([dynamic]string, 0, 8, a),
		user         = user,
		allocator    = a,
	}
}

editor_sync_destroy :: proc(s: ^Editor_Sync) {
	if s.project_root != "" {
		delete(s.project_root, s.allocator)
	}
	for p in s.pinned {
		delete(p, s.allocator)
	}
	delete(s.pinned)
	s^ = {}
}

// editor_sync_install attaches the bridge as the editor's buffer listener
// (replacing any previous listener — one sync sink per editor).
editor_sync_install :: proc(s: ^Editor_Sync, e: ^editor.Editor) {
	editor.editor_set_listener(e, {
		on_open   = sync_on_open,
		on_change = sync_on_change,
		on_close  = sync_on_close,
		user      = s,
	})
}

// editor_sync_uninstall detaches the bridge before either side goes away
// (the daemon tears the sync down before the manager it calls into) and
// drops every buffer pin the ledger holds: without this, shutdown would
// destroy the hot cache with entries still marked in-use — the daemon's
// hot_pinned_count teardown invariant would never hold.
editor_sync_uninstall :: proc(s: ^Editor_Sync, e: ^editor.Editor) {
	editor.editor_clear_listener(e)
	if s.hot != nil {
		sync.mutex_lock(&s.mu)
		for p in s.pinned {
			ts.hot_unpin_buffered(s.hot, p)
			delete(p, s.allocator)
		}
		resize(&s.pinned, 0)
		sync.mutex_unlock(&s.mu)
	}
}

// sync_pin_record / sync_pin_forget maintain the pin ledger alongside the
// cache's own pin counts (the cache cannot enumerate its pins — they are
// anonymous counts, so the applier tracks what it applied).
sync_pin_record :: proc(s: ^Editor_Sync, rel: string) {
	sync.mutex_lock(&s.mu)
	append(&s.pinned, strings.clone(rel, s.allocator))
	sync.mutex_unlock(&s.mu)
}

sync_pin_forget :: proc(s: ^Editor_Sync, rel: string) {
	sync.mutex_lock(&s.mu)
	for p, i in s.pinned {
		if p == rel {
			delete(p, s.allocator)
			last := len(s.pinned) - 1
			s.pinned[i] = s.pinned[last]
			_ = pop(&s.pinned)
			break
		}
	}
	sync.mutex_unlock(&s.mu)
}

// sync_uri renders the file's URI on the project root (scratch — the doc
// sync clones what it keeps).
sync_uri :: proc(s: ^Editor_Sync, rel_path: string) -> string {
	rel := normalize_rel(rel_path, context.temp_allocator)
	abs := strings.concatenate({s.project_root, "/", rel}, context.temp_allocator)
	return symbol.file_uri(abs, context.temp_allocator)
}

// sync_resolve fetches a running client for the file, if any. Buffer
// lifecycle never starts servers: a spawn (fork/exec plus a 45 s handshake)
// must never run inside a notification, which the editor invokes under the
// file's lock — servers start through the explicit language-server
// operations (start/restart) and the symbolic request paths, which run
// outside every editor lock. The client-for-file lookup is
// running-servers-only by design.
sync_resolve :: proc(s: ^Editor_Sync, rel_path: string) -> (client: ^lsp.Client, language_id: string) {
	c, lang, _, err := s.port(s.user, rel_path, false, context.temp_allocator, nil)
	if err != nil {
		return nil, ""
	}
	return c, lang
}

sync_on_open :: proc(user: rawptr, rel_path: string, contents: string) {
	s := cast(^Editor_Sync)user
	// The buffered file's hot tree must survive every eviction pressure
	// until the buffer closes. A pin for a key with no entry yet is
	// simply lost (the entry validates against the file bytes on use, so
	// the miss only costs a reparse) and is not recorded.
	if s.hot != nil {
		rel := normalize_rel(rel_path, context.temp_allocator)
		if ts.hot_pin_buffered(s.hot, rel) {
			sync_pin_record(s, rel)
		}
	}
	client, language_id := sync_resolve(s, rel_path)
	if client == nil {
		return
	}
	defer if s.release != nil {
		s.release(s.user, client)
	}
	_ = lsp.doc_open(client, sync_uri(s, rel_path), language_id, contents)
}

sync_on_change :: proc(user: rawptr, rel_path: string, contents: string) {
	s := cast(^Editor_Sync)user
	if s.hot != nil {
		ts.hot_edit(s.hot, normalize_rel(rel_path, context.temp_allocator), contents)
	}
	client, language_id := sync_resolve(s, rel_path)
	if client != nil {
		defer if s.release != nil {
			s.release(s.user, client)
		}
		uri := sync_uri(s, rel_path)
		if !lsp.doc_change_full(client, uri, contents) {
			// Not open on the client's mirror (a fresh client after a server
			// restart): open it with the current contents instead.
			_ = lsp.doc_open(client, uri, language_id, contents)
		}
	}
	sync_index_change(s, rel_path, contents)
}

// sync_index_change rewrites the file's L0 rows for the contents the
// editor just committed. It runs inside the editor's per-file notification
// — the file lock is held — so it must not re-enter the editor:
// ts_source_index_contents parses the bytes handed to it and never reads
// the file itself. Tree-sitter-served languages only: the LSP producer
// resolves contents through editor_read_file, which would take this same
// file's lock — languages without a grammar stay with the read-side
// freshness heal and the symbolic-op paths. Best effort by design: a
// failure leaves the rows to that heal or the next crawl.
sync_index_change :: proc(s: ^Editor_Sync, rel_path: string, contents: string) {
	if s.ts_src == nil {
		return
	}
	rel := normalize_rel(rel_path, context.temp_allocator)
	if rel == "" {
		return
	}
	_, _ = ts_source_index_contents(s.ts_src, rel, contents)
}

sync_on_close :: proc(user: rawptr, rel_path: string) {
	s := cast(^Editor_Sync)user
	if s.hot != nil {
		rel := normalize_rel(rel_path, context.temp_allocator)
		ts.hot_unpin_buffered(s.hot, rel)
		sync_pin_forget(s, rel)
	}
	client, _ := sync_resolve(s, rel_path)
	if client == nil {
		return
	}
	defer if s.release != nil {
		s.release(s.user, client)
	}
	_ = lsp.doc_close(client, sync_uri(s, rel_path))
}
