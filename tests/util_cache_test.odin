// Tests for Bounded_Cache key ownership: with the key hooks set, the
// cache clones keys on fresh insert and releases them on eviction and
// destroy — callers may hand in borrowed (request-arena) keys.
package tests

import "core:mem"
import "core:strings"
import "core:testing"

import "src:util"

cache_test_key_clone :: proc(k: string, a: mem.Allocator) -> string {
	return strings.clone(k, a)
}

cache_test_key_release :: proc(k: string, a: mem.Allocator) {
	delete(k, a)
}

@(test)
bounded_cache_owns_its_keys :: proc(t: ^testing.T) {
	c: util.Bounded_Cache(string, int)
	util.cache_init(&c, 2, context.allocator, nil, 0, nil, cache_test_key_clone, cache_test_key_release)
	defer util.cache_destroy(&c)

	// Keys handed in from a scratch arena that dies before the lookups —
	// the cache must carry its own copies (the map-entry lifetime rule).
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	sa := mem.dynamic_arena_allocator(&arena)
	k1 := strings.clone("alpha", sa)
	k2 := strings.clone("beta", sa)
	util.cache_put(&c, k1, 1)
	util.cache_put(&c, k2, 2)
	mem.dynamic_arena_destroy(&arena)

	v, ok := util.cache_get(&c, "alpha")
	testing.expect(t, ok, "alpha resolvable after the arena died")
	testing.expect_value(t, v, 1)

	// The get refreshed alpha, so beta is the LRU entry: a third insert
	// evicts beta and releases its owned key alongside the value.
	util.cache_put(&c, "gamma", 3)
	_, gone := util.cache_get(&c, "beta")
	testing.expect(t, !gone, "beta evicted at the entry cap")
	_, kept := util.cache_get(&c, "alpha")
	testing.expect(t, kept, "alpha still present after the eviction")

	// Replace keeps the original owned key; destroy releases each owned
	// key exactly once (bad frees surface in the leak output).
	util.cache_put(&c, "alpha", 9)
	v2, ok2 := util.cache_get(&c, "alpha")
	testing.expect(t, ok2, "alpha after replace")
	testing.expect_value(t, v2, 9)
}

@(test)
bounded_cache_remove_releases_and_refuses_pins :: proc(t: ^testing.T) {
	c: util.Bounded_Cache(string, int)
	util.cache_init(&c, 4, context.allocator, nil, 0, nil, cache_test_key_clone, cache_test_key_release)
	defer util.cache_destroy(&c)

	util.cache_put(&c, "one", 1)
	util.cache_put(&c, "two", 2)

	removed := util.cache_remove(&c, "one")
	testing.expect(t, removed, "one removed")
	_, gone := util.cache_get(&c, "one")
	testing.expect(t, !gone, "one absent after remove")
	again := util.cache_remove(&c, "one")
	testing.expect(t, !again, "second remove of one is a miss")

	// A removed key can come back: the re-insert clones the caller's key
	// fresh (the released owned key is gone for good).
	util.cache_put(&c, "one", 10)
	v, ok := util.cache_get(&c, "one")
	testing.expect(t, ok, "one re-inserted")
	testing.expect_value(t, v, 10)

	// Pinned entries are refused — the pin contract promises the value
	// stays with its holder.
	pinned := util.cache_pin(&c, "two")
	testing.expect(t, pinned, "two pinned")
	refused := util.cache_remove(&c, "two")
	testing.expect(t, !refused, "remove refused while pinned")
	util.cache_unpin(&c, "two")
	after := util.cache_remove(&c, "two")
	testing.expect(t, after, "two removable after unpin")
}

@(test)
bounded_cache_put_refuses_pinned_replace :: proc(t: ^testing.T) {
	c: util.Bounded_Cache(string, int)
	util.cache_init(&c, 4, context.allocator, nil, 0, nil, cache_test_key_clone, cache_test_key_release)
	defer util.cache_destroy(&c)

	util.cache_put(&c, "k", 1)
	pinned := util.cache_pin(&c, "k")
	testing.expect(t, pinned, "k pinned")

	// The put must be a pure no-op: the stored value survives, the pin
	// count survives, and the caller keeps ownership of the new value.
	stored := util.cache_put(&c, "k", 2)
	testing.expect(t, !stored, "replace refused while pinned")
	v, ok := util.cache_get(&c, "k")
	testing.expect(t, ok, "k still present after the refused put")
	testing.expect_value(t, v, 1)
	testing.expect_value(t, util.cache_pinned_count(&c), 1)

	// After the pin drops, the same put replaces normally.
	util.cache_unpin(&c, "k")
	replaced := util.cache_put(&c, "k", 3)
	testing.expect(t, replaced, "replace allowed once unpinned")
	v2, ok2 := util.cache_get(&c, "k")
	testing.expect(t, ok2, "k present after replace")
	testing.expect_value(t, v2, 3)
}

Cache_View_Val :: struct {
	s: string,
}

cache_view_release :: proc(v: Cache_View_Val) {
	delete(v.s, context.allocator)
}

cache_view_copy :: proc(v: ^Cache_View_Val, user: rawptr) {
	out := cast(^string)user
	out^ = strings.clone(v.s, context.allocator)
}

@(test)
bounded_cache_view_copies_under_lock :: proc(t: ^testing.T) {
	// cache_view hands the value to the callback under the cache mutex:
	// a copy taken inside survives a later replace (whose release frees
	// the original) — the pattern cache_get cannot offer, since its
	// returned copy races exactly that release.
	c: util.Bounded_Cache(string, Cache_View_Val)
	util.cache_init(&c, 4, context.allocator, cache_view_release)
	defer util.cache_destroy(&c)

	owned := strings.clone("payload", context.allocator)
	util.cache_put(&c, "k", Cache_View_Val{s = owned})

	got := ""
	present := util.cache_view(&c, "k", cache_view_copy, &got)
	testing.expect(t, present)
	testing.expect_value(t, got, "payload")

	replaced := strings.clone("next", context.allocator)
	testing.expect(t, util.cache_put(&c, "k", Cache_View_Val{s = replaced}))
	testing.expect_value(t, got, "payload")

	missing := util.cache_view(&c, "absent", cache_view_copy, &got)
	testing.expect(t, !missing)
	testing.expect_value(t, got, "payload")
	delete(got, context.allocator)
}
