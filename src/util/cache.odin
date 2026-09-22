// Bounded_Cache: the one cache container every aubade cache goes through —
// a mutex-guarded LRU keyed map with a hard entry cap, an optional byte
// budget (evaluated once per put through byte_cost, with in-place cost
// mutations charged through cache_charge), an optional value
// destructor for owned values (the destructor runs on eviction and
// destroy, so cached resources are never leaked by the bounds), and
// pinning: pinned entries are never evicted, never removed, and never
// replaced — cache_put on a pinned key is a refused no-op that returns
// false (ownership of the value stays with the caller). cache_destroy
// reports leftover pins through cache_pinned_count so callers can check
// the invariant at teardown. K must be a valid map key type.
//
// Release hooks run under the cache mutex (evict, replace, and destroy
// paths): they must only free the handed-over value and never re-enter
// the same cache — get/put/pin on it from a hook self-deadlocks. Releasing
// outside the lock is not an option: cache_get lends borrowed values, so
// an unlocked release window would hand out freed memory.
package util

import "base:intrinsics"
import "core:mem"
import "core:sync"

Cache_Entry :: struct($K: typeid, $V: typeid) {
	key:    K,
	value:  V,
	pinned: int, // > 0: not evictable
	prev:   ^Cache_Entry(K, V),
	next:   ^Cache_Entry(K, V),
}

Bounded_Cache :: struct($K: typeid, $V: typeid) where intrinsics.type_is_valid_map_key(K) {
	max_entries: int,
	max_bytes:   int, // 0 = no byte budget
	total_bytes: int,
	byte_cost:   proc(V) -> int, // optional; evaluated once at put
	release:     proc(V),        // optional; called on evict/destroy
	key_clone:   proc(K, mem.Allocator) -> K, // optional; the cache owns its keys
	key_release: proc(K, mem.Allocator),      // optional; frees an owned key on evict/destroy
	entries:     map[K]^Cache_Entry(K, V),
	head:        ^Cache_Entry(K, V), // most recently used
	tail:        ^Cache_Entry(K, V), // least recently used
	count:       int,
	allocator:   mem.Allocator,
	mu:       sync.Mutex,
}

cache_init :: proc(
	c:           ^Bounded_Cache($K, $V),
	max_entries: int,
	a:           mem.Allocator           = context.allocator,
	release:     proc(V)                 = nil,
	max_bytes:   int                     = 0,
	byte_cost:   proc(V) -> int          = nil,
	key_clone:   proc(K, mem.Allocator) -> K = nil,
	key_release: proc(K, mem.Allocator)      = nil,
) {
	limit := max_entries
	if limit < 1 {
		limit = 1
	}
	// A byte budget without a cost function can never trigger (put skips
	// the accounting), which fail-opens the cache's byte bound — that
	// incoherent construction is a programmer error, caught here at init
	// rather than silently unbounded.
	if max_bytes > 0 && byte_cost == nil {
		panic("Bounded_Cache: max_bytes requires a byte_cost function")
	}
	c^ = {
		max_entries = limit,
		max_bytes   = max_bytes,
		byte_cost   = byte_cost,
		release     = release,
		key_clone   = key_clone,
		key_release = key_release,
		entries     = make(map[K]^Cache_Entry(K, V), 16, a),
		allocator   = a,
	}
}

cache_destroy :: proc(c: ^Bounded_Cache($K, $V)) {
	sync.mutex_lock(&c.mu)
	for _, entry in c.entries {
		if c.release != nil {
			c.release(entry.value)
		}
		if c.key_release != nil {
			c.key_release(entry.key, c.allocator)
		}
		free(entry, c.allocator)
	}
	sync.mutex_unlock(&c.mu)
	delete(c.entries)
	c.entries = nil
	c.head = nil
	c.tail = nil
	c.count = 0
	c.total_bytes = 0
}

// cache_pinned_count reports how many entries still hold pins. Teardown
// code that requires "no in-use trees remain" checks this after destroy is
// NOT an option (destroy releases everything), so check before destroy.
cache_pinned_count :: proc(c: ^Bounded_Cache($K, $V)) -> int {
	sync.mutex_lock(&c.mu)
	n := 0
	for _, entry in c.entries {
		if entry.pinned > 0 {
			n += 1
		}
	}
	sync.mutex_unlock(&c.mu)
	return n
}

// cache_pinned_keys appends the keys of entries that still hold pins to
// `out`. The keys are borrowed: a pinned entry is never removed, replaced,
// or evicted, so they stay valid while the pins hold — copy them out if
// they must outlive that. Teardown diagnostics use it to name the
// offenders instead of reporting a bare count.
cache_pinned_keys :: proc(c: ^Bounded_Cache($K, $V), out: ^[dynamic]K) {
	sync.mutex_lock(&c.mu)
	for _, entry in c.entries {
		if entry.pinned > 0 {
			append(out, entry.key)
		}
	}
	sync.mutex_unlock(&c.mu)
}

// cache_pin marks an entry in-use: it will not be evicted until the
// matching unpin. Returns false when the key is absent.
cache_pin :: proc(c: ^Bounded_Cache($K, $V), key: K) -> bool {
	sync.mutex_lock(&c.mu)
	entry, ok := c.entries[key]
	if ok {
		entry.pinned += 1
	}
	sync.mutex_unlock(&c.mu)
	return ok
}

// cache_remove explicitly drops a key's entry, releasing the owned key and
// value exactly like an eviction. Pinned entries are refused (the pin
// contract promises the value stays with its holder) — the caller retries
// after the pins release. Caches that hand out clones instead of lent
// pointers (the store's payload mirror) never pin and can always remove.
cache_remove :: proc(c: ^Bounded_Cache($K, $V), key: K) -> bool {
	sync.mutex_lock(&c.mu)
	entry, ok := c.entries[key]
	if !ok {
		sync.mutex_unlock(&c.mu)
		return false
	}
	if entry.pinned > 0 {
		sync.mutex_unlock(&c.mu)
		return false
	}
	cache_unlink(c, entry)
	delete_key(&c.entries, entry.key)
	if c.key_release != nil {
		c.key_release(entry.key, c.allocator)
	}
	c.count -= 1
	if c.byte_cost != nil {
		c.total_bytes -= c.byte_cost(entry.value)
	}
	if c.release != nil {
		c.release(entry.value)
	}
	free(entry, c.allocator)
	sync.mutex_unlock(&c.mu)
	return true
}

cache_unpin :: proc(c: ^Bounded_Cache($K, $V), key: K) -> bool {
	sync.mutex_lock(&c.mu)
	entry, ok := c.entries[key]
	if ok && entry.pinned > 0 {
		entry.pinned -= 1
	}
	sync.mutex_unlock(&c.mu)
	return ok
}

// cache_get returns the value for key and moves it to the front. The
// value is LENT: for values carrying interior pointers (payload bytes,
// strings), a concurrent put or eviction on another thread may free them
// the moment the mutex releases — copy such values out under the lock via
// cache_view instead of holding the returned struct across other cache
// calls.
cache_get :: proc(c: ^Bounded_Cache($K, $V), key: K) -> (res: V, found: bool) {
	sync.mutex_lock(&c.mu)
	entry, ok := c.entries[key]
	if !ok {
		sync.mutex_unlock(&c.mu)
		return
	}
	cache_unlink(c, entry)
	cache_push_front(c, entry)
	res = entry.value
	sync.mutex_unlock(&c.mu)
	return res, true
}

// cache_view runs `fn` with the entry's value while the cache mutex is
// held: the value cannot be evicted or replaced mid-callback, so values
// with interior pointers can be copied out safely (the pattern cache_get
// cannot offer). The callback must not re-enter the cache — the same
// contract the release hooks run under. Missing keys return false without
// invoking the callback.
cache_view :: proc(c: ^Bounded_Cache($K, $V), key: K, fn: proc(v: ^V, user: rawptr), user: rawptr) -> bool {
	sync.mutex_lock(&c.mu)
	entry, ok := c.entries[key]
	if ok {
		cache_unlink(c, entry)
		cache_push_front(c, entry)
		fn(&entry.value, user)
	}
	sync.mutex_unlock(&c.mu)
	return ok
}

// cache_put inserts or replaces key, then evicts least-recently-used
// unpinned entries until both the entry cap and the byte budget hold.
// A pinned existing entry is never replaced — the call is a no-op that
// returns false, leaving ownership of value with the caller (the same
// pin contract cache_remove and evict_locked enforce).
cache_put :: proc(c: ^Bounded_Cache($K, $V), key: K, value: V) -> bool {
	sync.mutex_lock(&c.mu)
	cost := 0
	if c.byte_cost != nil {
		cost = c.byte_cost(value)
	}
	if entry, ok := c.entries[key]; ok {
		if entry.pinned > 0 {
			sync.mutex_unlock(&c.mu)
			return false
		}
		// Charge the old value's bytes before releasing it — afterwards
		// byte_cost would read freed memory (evict_locked's order).
		if c.byte_cost != nil {
			c.total_bytes -= c.byte_cost(entry.value)
		}
		if c.release != nil {
			c.release(entry.value)
		}
		entry.value = value
		if c.byte_cost != nil {
			c.total_bytes += cost
		}
		cache_unlink(c, entry)
		cache_push_front(c, entry)
	} else {
		// Fresh inserts clone the key when the cache owns keys; the
		// replace path above keeps the existing owned key untouched.
		owned := key
		if c.key_clone != nil {
			owned = c.key_clone(key, c.allocator)
		}
		fresh := new(Cache_Entry(K, V), c.allocator)
		fresh^ = {key = owned, value = value}
		c.entries[owned] = fresh
		cache_push_front(c, fresh)
		c.count += 1
		c.total_bytes += cost
	}
	evict_locked(c)
	sync.mutex_unlock(&c.mu)
	return true
}

// cache_charge adjusts the byte budget for a value whose byte cost its
// owner mutated in place (the hot tree cache swaps an entry's source
// under the entry pin). delta is the cost change since the value's put
// or last charge; the mutation must already be complete — the charge
// moves only the ledger, never values. Budget enforcement stays at put
// time (an eviction needs an unpinned victim); the ledger's exactness
// is what keeps that enforcement meaningful. No-op without a byte
// budget.
cache_charge :: proc(c: ^Bounded_Cache($K, $V), delta: int) {
	if c.byte_cost == nil {
		return
	}
	sync.mutex_lock(&c.mu)
	c.total_bytes += delta
	sync.mutex_unlock(&c.mu)
}

// evict_locked enforces the bounds; the mutex must be held. Pinned entries
// are skipped — when everything is pinned the cache may exceed its caps
// until pins release.
evict_locked :: proc(c: ^Bounded_Cache($K, $V)) {
	for c.count > c.max_entries || (c.max_bytes > 0 && c.total_bytes > c.max_bytes) {
		victim: ^Cache_Entry(K, V)
		for e := c.tail; e != nil; e = e.prev {
			if e.pinned == 0 {
				victim = e
				break
			}
		}
		if victim == nil {
			return
		}
		cache_unlink(c, victim)
		delete_key(&c.entries, victim.key)
		if c.key_release != nil {
			c.key_release(victim.key, c.allocator)
		}
		c.count -= 1
		if c.byte_cost != nil {
			c.total_bytes -= c.byte_cost(victim.value)
		}
		if c.release != nil {
			c.release(victim.value)
		}
		free(victim, c.allocator)
	}
}

cache_unlink :: proc(c: ^Bounded_Cache($K, $V), entry: ^Cache_Entry(K, V)) {
	if entry.prev != nil {
		entry.prev.next = entry.next
	} else {
		c.head = entry.next
	}
	if entry.next != nil {
		entry.next.prev = entry.prev
	} else {
		c.tail = entry.prev
	}
	entry.prev = nil
	entry.next = nil
}

cache_push_front :: proc(c: ^Bounded_Cache($K, $V), entry: ^Cache_Entry(K, V)) {
	entry.prev = nil
	entry.next = c.head
	if c.head != nil {
		c.head.prev = entry
	}
	c.head = entry
	if c.tail == nil {
		c.tail = entry
	}
}

// cache_import_anchor exists for the per-directory check (packages compile
// with -no-entry-point and no consumers there): the unused-import analysis
// skips generic definitions (still so on dev-2026-09-nightly), so without
// one concrete instantiation the imports used only by Bounded_Cache would
// be flagged. The anchor also smoke-compiles the container for a common
// key/value pair.
@(private)
cache_import_anchor :: proc() {
	c: Bounded_Cache(string, int)
	cache_init(&c, 1)
	cache_put(&c, "anchor", 0)
	cache_destroy(&c)
}

