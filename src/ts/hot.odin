// Hot parse-tree LRU — the L2 of the three-tier symbol resolution: the
// parent keeps recently used TSTrees so repeat symbol work skips the
// parse. Budget per the storage design: 5,000 files / 128 MiB. Buffered
// files pin their tree (never evicted while open) and didChange updates
// it in place through ts_tree_edit; every other entry is validated
// against the file bytes on use, so an external edit reparses instead
// of serving a stale tree.
//
// Ownership discipline (the map-entry lifetime rule): readers go through
// hot_acquire — a pin plus the entry's mutex — and the cache enforces the
// pin contract structurally (cache_put refuses to replace a pinned entry),
// so a pinned entry is never freed underneath its holders; refreshes swap
// the tree and source in place, so a pinned entry struct outlives its
// content swap and blocked readers resume against the new tree.
package ts

import "core:mem"
import "core:strings"
import "core:sync"

import "src:util"

HOT_MAX_ENTRIES :: 5000
HOT_MAX_BYTES   :: 128 * 1024 * 1024
// Per-node charge for a resident tree. The ledger must bound the real
// memory a tree occupies, and a tree-sitter tree runs several multiples
// of its source: measured 2026-09-06 (Linux, mallinfo2 deltas over live
// trees) at 119.6-132.5 malloc bytes per node across the odin and C
// grammars — the odin grammar's trees run ~25x their source length, so a
// source-length-only ledger let a 128 MiB budget hold multiples of that
// in real memory. 144 is the measured ceiling rounded up to a 16-byte
// multiple; ts_node_descendant_count supplies the node count.
HOT_NODE_BYTES :: 144
// The incremental refresh only parses what the cold path would: sources
// grown past the TS producer's parse gate tombstone the entry instead of
// re-parsing megabytes under the entry pin (the pin serializes against
// every reader of that key).
HOT_EDIT_MAX_SOURCE_BYTES :: 1 << 20

Hot_Tree :: struct {
	tree:      Tree,
	lang:      Language,
	lang_name: string, // owned; the outliner key
	source:    string, // owned; what the tree was parsed or edited against
	cost:      int,
	mu:        sync.Mutex, // serializes tree/source swaps against queries
	allocator: mem.Allocator,
}

Hot_Trees :: struct {
	cache:     util.Bounded_Cache(string, ^Hot_Tree),
	allocator: mem.Allocator,
}

hot_trees_init :: proc(ht: ^Hot_Trees, a := context.allocator) {
	ht^ = {allocator = a}
	util.cache_init(
		&ht.cache, HOT_MAX_ENTRIES, a, hot_release_entry, HOT_MAX_BYTES, hot_byte_cost,
		hot_key_clone, hot_key_release,
	)
}

hot_trees_destroy :: proc(ht: ^Hot_Trees) {
	util.cache_destroy(&ht.cache)
	ht^ = {}
}

// hot_pinned_count surfaces the teardown invariant check (buffer pins
// must be gone before destroy).
hot_pinned_count :: proc(ht: ^Hot_Trees) -> int {
	return util.cache_pinned_count(&ht.cache)
}

// hot_pinned_keys clones the pinned entries' keys (rel paths) into `a` —
// the teardown diagnostic names the offender instead of a bare count.
hot_pinned_keys :: proc(ht: ^Hot_Trees, a: mem.Allocator) -> []string {
	keys: [dynamic]string
	defer delete(keys)
	util.cache_pinned_keys(&ht.cache, &keys)
	cloned := make([]string, len(keys), a)
	for k, i in keys {
		cloned[i] = strings.clone(k, a)
	}
	return cloned
}

hot_byte_cost :: proc(v: ^Hot_Tree) -> int {
	return v.cost
}

// hot_key_clone / hot_key_release give the cache ownership of its keys:
// callers hand in rel_paths normalized on per-request scratch, so the
// cache must carry its own copy (the map-entry lifetime rule).
hot_key_clone :: proc(k: string, a: mem.Allocator) -> string {
	return strings.clone(k, a)
}

hot_key_release :: proc(k: string, a: mem.Allocator) {
	delete(k, a)
}

// hot_release_entry is the cache destructor: it frees the tree, the
// owned strings, and the entry itself.
hot_release_entry :: proc(v: ^Hot_Tree) {
	if v.tree != nil {
		tree_delete(v.tree)
	}
	delete(v.lang_name, v.allocator)
	delete(v.source, v.allocator)
	free(v, v.allocator)
}

// hot_acquire pins the entry and takes its mutex; the tree may be
// queried until the matching hot_release. False when the key has no
// entry.
hot_acquire :: proc(ht: ^Hot_Trees, key: string) -> (^Hot_Tree, bool) {
	if !util.cache_pin(&ht.cache, key) {
		return nil, false
	}
	v, ok := util.cache_get(&ht.cache, key)
	if !ok {
		// Unreachable: a pinned entry cannot be removed or replaced
		// (cache_remove and cache_put both refuse pins).
		util.cache_unpin(&ht.cache, key)
		return nil, false
	}
	sync.mutex_lock(&v.mu)
	return v, true
}

hot_release :: proc(ht: ^Hot_Trees, key: string, e: ^Hot_Tree) {
	sync.mutex_unlock(&e.mu)
	util.cache_unpin(&ht.cache, key)
}

// hot_insert stores a freshly parsed tree under a key with no entry;
// ownership of the tree transfers here. When a concurrent insert won the
// key in the refresh-miss window and the entry is pinned, cache_put
// refuses the replace — the loser entry (tree, strings, struct) is freed
// on the spot. The roots the caller already computed borrow nothing
// (Symbol is plain data), so dropping this tree is safe. Nothing is
// returned: the entry that ends up in the cache belongs to the cache.
hot_insert :: proc(ht: ^Hot_Trees, key: string, tree: Tree, lang: Language, lang_name, source: string) {
	e := new(Hot_Tree, ht.allocator)
	e^ = {
		tree      = tree,
		lang      = lang,
		lang_name = strings.clone(lang_name, ht.allocator),
		source    = strings.clone(source, ht.allocator),
		cost      = len(source) + hot_tree_node_bytes(tree),
		allocator = ht.allocator,
	}
	if !util.cache_put(&ht.cache, key, e) {
		hot_release_entry(e)
	}
}

// hot_tree_node_bytes estimates a tree's own memory: node count times the
// calibrated per-node charge (see HOT_NODE_BYTES). A nil tree (a
// tombstoned or re-parse-failed entry) carries no tree bytes.
hot_tree_node_bytes :: proc(tree: Tree) -> int {
	if tree == nil {
		return 0
	}
	root := tree_root_node(tree)
	return int(node_descendant_count(root)) * HOT_NODE_BYTES
}

// hot_recompute_cost re-derives the entry's charge from its current
// residents (source clone plus tree nodes) and charges the delta — the
// single accounting point for in-place mutations that touch the tree,
// the source, or both. Enforcement still runs at the next put (an
// eviction needs an unpinned victim).
hot_recompute_cost :: proc(ht: ^Hot_Trees, e: ^Hot_Tree) {
	cost := len(e.source) + hot_tree_node_bytes(e.tree)
	util.cache_charge(&ht.cache, cost - e.cost)
	e.cost = cost
}

// hot_refresh swaps an existing entry's tree and source in place,
// freeing the old ones (the entry mutex is held: no reader is mid-query,
// and blocked readers resume against the new tree). False when the key
// has no entry — the caller inserts instead. The swap charges its byte
// delta (cache_charge), so the budget ledger stays exact; enforcement
// still runs at the next put (an eviction needs an unpinned victim).
hot_refresh :: proc(ht: ^Hot_Trees, key: string, tree: Tree, lang: Language, lang_name, source: string) -> bool {
	e, ok := hot_acquire(ht, key)
	if !ok {
		return false
	}
	if e.tree != nil {
		tree_delete(e.tree)
	}
	e.tree = tree
	e.lang = lang
	e.lang_name = swap_string(e.lang_name, lang_name, e.allocator)
	hot_swap_source(ht, e, source)
	hot_release(ht, key, e)
	return true
}

// hot_swap_source installs a new source string into a held entry, frees
// the old bytes, and re-derives the charge — callers reach it after any
// tree swap or re-parse, so one recompute covers both residents.
hot_swap_source :: proc(ht: ^Hot_Trees, e: ^Hot_Tree, source: string) {
	delete(e.source, e.allocator)
	e.source = strings.clone(source, e.allocator)
	hot_recompute_cost(ht, e)
}

// hot_tombstone drops a held entry's content (tree and source) while
// keeping the entry itself, refunding its bytes — the entry resumes as
// a nil-tree placeholder until a later insert replaces it.
hot_tombstone :: proc(ht: ^Hot_Trees, e: ^Hot_Tree) {
	if e.tree != nil {
		tree_delete(e.tree)
		e.tree = nil
	}
	delete(e.source, e.allocator)
	e.source = ""
	util.cache_charge(&ht.cache, -e.cost)
	e.cost = 0
}

// hot_edit applies a didChange as an incremental ts_tree_edit — the edit
// is the common prefix/suffix diff of old and new sources, which is
// correct for any change shape — and swaps the stored source. A key with
// no entry is left alone: the first symbol pass parses the file. A source
// grown past HOT_EDIT_MAX_SOURCE_BYTES tombstones the entry (tree and
// source dropped): the diff would be a near-full re-parse under the entry
// pin, and the cold path refuses such sources anyway.
hot_edit :: proc(ht: ^Hot_Trees, key: string, new_source: string) {
	e, ok := hot_acquire(ht, key)
	if !ok {
		return
	}
	if len(new_source) > HOT_EDIT_MAX_SOURCE_BYTES {
		hot_tombstone(ht, e)
		hot_release(ht, key, e)
		return
	}
	old := e.source
	start := 0
	min_len := min(len(old), len(new_source))
	for start < min_len && old[start] == new_source[start] {
		start += 1
	}
	end_old, end_new := len(old), len(new_source)
	for end_old > start && end_new > start && old[end_old - 1] == new_source[end_new - 1] {
		end_old -= 1
		end_new -= 1
	}
	if end_old != start || end_new != start {
		if e.tree != nil {
			edit := Input_Edit{
				start_byte    = u32(start),
				old_end_byte  = u32(end_old),
				new_end_byte  = u32(end_new),
				start_point   = hot_byte_point(old, start),
				old_end_point = hot_byte_point(old, end_old),
				new_end_point = hot_byte_point(new_source, end_new),
			}
			tree_edit(e.tree, &edit)
		}
		// tree_edit only shifts the existing nodes' ranges; the re-parse
		// with the edited tree as the reuse base materializes nodes for
		// the inserted text and reuses every unchanged subtree. A failed
		// re-parse drops the edited tree: its ranges were already
		// shifted, so keeping it against the swapped-in source would
		// serve a stale tree through the byte-equality gate (the next
		// use takes the full reparse path instead). A tombstoned (nil)
		// tree parses fresh: parse_with_old accepts no reuse base.
		pr, perr := parse_with_old(new_source, e.lang_name, e.tree)
		if perr == "" {
			if e.tree != nil {
				tree_delete(e.tree)
			}
			e.tree = pr.tree
			e.lang = pr.lang
		} else if e.tree != nil {
			tree_delete(e.tree)
			e.tree = nil
		}
	}
	hot_swap_source(ht, e, new_source)
	hot_release(ht, key, e)
}

// hot_pin_buffered / hot_unpin_buffered implement the open-buffer pin
// rule: a buffered file's tree is never evicted. Pinning returns false
// when the key has no entry yet (the pin is simply lost — see the header:
// the entry validates against the file bytes on use, so the miss only
// costs a reparse). Unpinning a key that was never pinned is a no-op.
hot_pin_buffered :: proc(ht: ^Hot_Trees, key: string) -> bool {
	return util.cache_pin(&ht.cache, key)
}

hot_unpin_buffered :: proc(ht: ^Hot_Trees, key: string) {
	_ = util.cache_unpin(&ht.cache, key)
}

// hot_byte_point computes a tree-sitter Point (row, byte column) for a
// byte offset.
hot_byte_point :: proc(s: string, byte_off: int) -> Point {
	row := u32(0)
	col := u32(0)
	for i := 0; i < byte_off && i < len(s); i += 1 {
		if s[i] == '\n' {
			row += 1
			col = 0
		} else {
			col += 1
		}
	}
	return {row = row, col = col}
}

swap_string :: proc(old: string, new: string, a: mem.Allocator) -> string {
	delete(old, a)
	return strings.clone(new, a)
}
