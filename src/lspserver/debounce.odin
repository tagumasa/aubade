// The publish debounce window: the pure due-tracking half of the
// diagnostics publish (the timer that fires it lives with the host shell).
// A mark moves the document's due point to now + PUBLISH_DEBOUNCE_MS, so a
// burst of didChanges inside the window leaves one due entry; a fire pass
// drains what the window has released. Every proc takes the current time
// as a value — nothing here reads a clock, so tests drive the window by
// passing advanced timestamps.
package lspserver

import "core:mem"
import "core:strings"

// PUBLISH_DEBOUNCE_MS owns the debounce window's length: the quiet span
// after the last didOpen/didChange before the document's diagnostics
// publish fires. The value is deliberately a named constant, not prose and
// not config — its default moves only through a measured decision, and
// tests advance against the identifier, never the number.
PUBLISH_DEBOUNCE_MS :: 200

// Debounce_Set is the due set: one entry per document whose publish is
// pending, carrying the monotonic-ms timestamp it becomes due at. It is
// not thread-safe; the Server's mu serializes it (handlers mark, the
// publish pass drains).
Debounce_Set :: struct {
	due:       map[string]i64, // uri -> due-at monotonic ms (keys owned clones)
	allocator: mem.Allocator,
}

debounce_init :: proc(ds: ^Debounce_Set, a: mem.Allocator) {
	ds^ = {due = make(map[string]i64, 8, a), allocator = a}
}

debounce_destroy :: proc(ds: ^Debounce_Set) {
	keys := make([dynamic]string, 0, len(ds.due), ds.allocator)
	for k in ds.due {
		append(&keys, k)
	}
	for k in keys {
		delete(k, ds.allocator)
	}
	delete(keys)
	delete(ds.due)
	ds^ = {}
}

// debounce_mark (re)arms one document's window: the due point moves to
// now + PUBLISH_DEBOUNCE_MS, coalescing every change inside the window
// into the single publish the drain will release.
debounce_mark :: proc(ds: ^Debounce_Set, uri: string, now_ms: i64) {
	due_at := now_ms + PUBLISH_DEBOUNCE_MS
	if _, ok := ds.due[uri]; ok {
		ds.due[uri] = due_at
		return
	}
	// First mark: the key joins a long-lived map, so it is cloned into the
	// set's own allocator (the caller's spelling may die with its scope).
	key := strings.clone(uri, ds.allocator)
	ds.due[key] = due_at
}

// debounce_drop removes a document from the set (didClose: the close
// publish is immediate, so nothing may fire later).
debounce_drop :: proc(ds: ^Debounce_Set, uri: string) {
	// delete_key hands back the map-owned stored key (zero-value string
	// when the key was absent — document URIs are never empty).
	old, _ := delete_key(&ds.due, uri)
	if len(old) > 0 {
		delete(old, ds.allocator)
	}
}

// debounce_next_due reports the earliest due point in the set. has=false
// when nothing is pending.
debounce_next_due :: proc(ds: ^Debounce_Set) -> (at_ms: i64, has: bool) {
	for _, at in ds.due {
		if !has || at < at_ms {
			at_ms = at
			has = true
		}
	}
	return
}

// debounce_drain_due removes and returns every document whose window ended
// at or before now_ms. The returned spellings are clones in the caller's
// allocator — the set's own keys are freed here — so the fire pass can
// work outside the lock that guarded the drain.
debounce_drain_due :: proc(ds: ^Debounce_Set, now_ms: i64, a: mem.Allocator) -> []string {
	found := make([dynamic]string, 0, 4, a)
	for u, at in ds.due {
		if at <= now_ms {
			append(&found, strings.clone(u, a))
		}
	}
	for u in found {
		old, _ := delete_key(&ds.due, u)
		if len(old) > 0 {
			delete(old, ds.allocator)
		}
	}
	return found[:]
}
