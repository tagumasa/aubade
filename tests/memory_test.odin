// Unit tests for the memories domain core: pattern classification,
// name validation and resolution, the listing model, and `mem:` reference
// rewriting. Everything runs on one request-style arena per test.
package tests

import "core:mem"
import "core:testing"
import "src:memory"

// Each test declares its arena inline: a Dynamic_Arena is
// self-referential, so a helper returning one by value would hand back
// an arena whose state points into a dead stack frame.

@(test)
memory_pattern_set_full_match :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	patterns := []string{"auth/.*", "pinned"}
	set, skipped, bad := memory.pattern_set_compile(patterns, a)
	testing.expect_value(t, skipped, 0)
	testing.expect_value(t, bad, "")
	defer memory.pattern_set_destroy(&set)

	// Full-match anchoring: "auth/.*" matches the topic, not a suffix.
	testing.expect(t, memory.pattern_set_match(&set, "auth/login"))
	testing.expect(t, !memory.pattern_set_match(&set, "xauth/login"))
	testing.expect(t, memory.pattern_set_match(&set, "pinned"))
	testing.expect(t, !memory.pattern_set_match(&set, "pinned-extra"))

	// Duplicates compile once; invalid patterns are skipped, not fatal —
	// but the first bad one is named so access gates can refuse.
	dup := []string{"pinned", "pinned", "([unclosed"}
	set2, skipped2, bad2 := memory.pattern_set_compile(dup, a)
	defer memory.pattern_set_destroy(&set2)
	testing.expect_value(t, skipped2, 1)
	testing.expect_value(t, bad2, "([unclosed")
	testing.expect(t, memory.pattern_set_match(&set2, "pinned"))
}

@(test)
memory_name_validation_and_resolution :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// The implicit ".md" suffix is stripped before anything else.
	testing.expect_value(t, memory.normalize_name("guide.md"), "guide")
	testing.expect_value(t, memory.normalize_name("guide"), "guide")

	// Whole ".." segments refuse; odd-but-legal names like "..a" do not
	// (they are not traversal), so they are not in the list. The literal
	// is static data — no delete.
	bad_names := []string{"", "   ", "..", "a/../b", "a\\..\\b"}
	for i in 0..<len(bad_names) {
		if memory.validate_name(bad_names[i], a) == nil {
			testing.expectf(t, false, "name must be rejected: %s", bad_names[i])
			return
		}
	}
	if memory.validate_name("auth/login", a) != nil {
		testing.expectf(t, false, "plain name must pass")
		return
	}

	// Resolution: project names stay under the project root, global
	// names strip the prefix, bare "global" refuses.
	rel, global, err := memory.resolve_rel("auth/login", a)
	testing.expect(t, err == nil)
	testing.expect_value(t, rel, "auth/login.md")
	testing.expect(t, !global)

	rel, global, err = memory.resolve_rel("global/java/style", a)
	testing.expect(t, err == nil)
	testing.expect_value(t, rel, "java/style.md")
	testing.expect(t, global)

	_, _, err = memory.resolve_rel("global", a)
	testing.expect(t, err != nil, "bare global must refuse")
}

@(test)
memory_list_model :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	ml: memory.Memories_List
	memory.memories_list_init(&ml, a)
	defer memory.memories_list_destroy(&ml)

	memory.memories_list_add(&ml, "b", false)
	memory.memories_list_add(&ml, "a", false)
	memory.memories_list_add(&ml, "a", false) // dedup
	memory.memories_list_add(&ml, "pinned", true)
	memory.memories_list_sort(&ml)

	testing.expect_value(t, len(ml.memories), 2)
	testing.expect_value(t, ml.memories[0], "a")
	testing.expect_value(t, ml.memories[1], "b")
	testing.expect_value(t, len(ml.read_only_memories), 1)
	testing.expect_value(t, ml.read_only_memories[0], "pinned")
}

@(test)
memory_reference_rewrite :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	content := "see mem:foo first, then mem:foo/bar and mem:foobar; also (mem:foo) plus mem:foo."

	// Only the whole-name reference matches; longer names sharing the
	// prefix stay untouched.
	out, count := memory.rewrite_references(content, "foo", "bar", a)
	testing.expect_value(t, count, 3)
	testing.expect_value(
		t,
		out,
		"see mem:bar first, then mem:foo/bar and mem:foobar; also (mem:bar) plus mem:bar.",
	)

	// No reference: content comes back borrowed and uncounted.
	same, zero := memory.rewrite_references("nothing here", "foo", "bar", a)
	testing.expect_value(t, zero, 0)
	testing.expect_value(t, same, "nothing here")

	// Detection agrees with the rewrite (used by rename propagation).
	testing.expect(t, memory.has_reference("x mem:foo!", "foo"))
	testing.expect(t, !memory.has_reference("x mem:foobar", "foo"))

	// End-of-text reference (the empty boundary group) rewrites cleanly.
	tail, tail_count := memory.rewrite_references("see mem:foo", "foo", "quux", a)
	testing.expect_value(t, tail_count, 1)
	testing.expect_value(t, tail, "see mem:quux")
}

// Renaming to a non-ASCII name must rewrite byte-exact references (a
// rune loop once truncated every multi-byte codepoint in the new name).
@(test)
rewrite_references_non_ascii_new_name :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	out, count := memory.rewrite_references("see mem:foo and mem:foo!", "foo", "日本語", a)
	testing.expect_value(t, count, 2)
	testing.expect(t, out == "see mem:日本語 and mem:日本語!", out)
}
