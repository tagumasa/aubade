// The memories domain core (markdown memories): memory-name validation
// and path resolution, read-only/ignored pattern classification, the
// listing model, and `mem:<name>` cross-reference rewriting. Pure
// string/regex work only — the file I/O lives behind the svc boundary
// (svc.memory/*), so this package never touches os/thread and stays
// unit-testable.
package memory

import "core:mem"
import "core:slice"
import "core:sort"
import "core:strings"
import "src:platform"
import "src:regex"

GLOBAL_TOPIC :: platform.GLOBAL_MEMORIES_TOPIC
GLOBAL_PREFIX :: GLOBAL_TOPIC + "/"
MEMORY_SUFFIX :: ".md"
REF_PREFIX :: "mem:"

// MAX_MEMORY_READ_BYTES caps one memory read; a memory beyond it is a
// pathology, not content.
MAX_MEMORY_READ_BYTES :: 10 << 20

// ---------------------------------------------------------------------------
// Read-only / ignored patterns
// ---------------------------------------------------------------------------

// Pattern_Set holds the compiled full-match (^...$) patterns behind
// read_only_memory_patterns / ignored_memory_patterns. A PCRE2 Regex
// belongs to the thread that uses it, so a set is compiled where the
// matching happens (per request, on the request/temp allocator) and
// released at scope end with pattern_set_destroy — never shared across
// worker threads.
Pattern_Set :: struct {
	patterns:  [dynamic]regex.Regex,
	allocator: mem.Allocator,
}

// pattern_set_compile deduplicates the pattern strings and compiles each
// into a full-match anchored regex. Invalid patterns are skipped (the
// reference warns and continues); the skipped count and the first bad
// pattern are returned so access-gate callers can refuse instead of
// failing open. `bad` is a view into `patterns`, not a clone.
pattern_set_compile :: proc(patterns: []string, a: mem.Allocator) -> (set: Pattern_Set, skipped: int, bad: string) {
	set = Pattern_Set{
		patterns  = make([dynamic]regex.Regex, 0, len(patterns), a),
		allocator = a,
	}
	seen := make(map[string]bool, len(patterns), context.temp_allocator)
	for p in patterns {
		if p in seen {
			continue
		}
		seen[p] = true
		anchored := strings.concatenate({"^", p, "$"}, context.temp_allocator)
		re, err := regex.compile_regex(anchored, a)
		if err != nil {
			skipped += 1
			if bad == "" {
				bad = p
			}
			continue
		}
		append(&set.patterns, re)
	}
	delete(seen)
	return set, skipped, bad
}

pattern_set_destroy :: proc(set: ^Pattern_Set) {
	for i in 0..<len(set.patterns) {
		regex.regex_destroy(&set.patterns[i])
	}
	if set.patterns != nil {
		delete(set.patterns)
		set.patterns = nil
	}
}

pattern_set_match :: proc(set: ^Pattern_Set, name: string) -> bool {
	for i in 0..<len(set.patterns) {
		if regex.regex_match(&set.patterns[i], name) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------

// normalize_name strips one trailing ".md" — callers may spell the
// suffix; it is treated as implicit.
normalize_name :: proc(name: string) -> string {
	return strings.trim_suffix(name, MEMORY_SUFFIX)
}

is_global_name :: proc(name: string) -> bool {
	return name == GLOBAL_TOPIC || strings.has_prefix(name, GLOBAL_PREFIX)
}

// validate_name rejects empty names and traversal segments. Error
// messages are allocated on `a`.
validate_name :: proc(name: string, a: mem.Allocator) -> platform.Err {
	if strings.trim_space(name) == "" {
		return platform.Wrapped{
			kind = .Invalid,
			msg  = strings.clone("memory_name must not be empty", a),
		}
	}
	if platform.has_dot_dot(name) {
		return platform.Wrapped{
			kind = .Invalid,
			msg = strings.concatenate(
				{"memory name cannot contain '..' segments for security reasons. Got: ", name},
				a,
			),
		}
	}
	return nil
}

// resolve_rel maps a validated memory name onto its path relative to the
// owning memory root ("a/b.md"): global memories strip the leading
// "global/" and live under the global root, every other name under the
// project root. Bare "global" addresses the root itself and is refused.
// The returned rel is allocated on `a`.
resolve_rel :: proc(name: string, a: mem.Allocator) -> (rel: string, global: bool, err: platform.Err) {
	if name == GLOBAL_TOPIC {
		return "", false, platform.Wrapped{
			kind = .Invalid,
			msg  = strings.clone(
				"bare \"global\" is not a valid memory name; use \"global/<name>\" to address a global memory",
				a,
			),
		}
	}
	if is_global_name(name) {
		sub := strings.trim_prefix(name, GLOBAL_PREFIX)
		return strings.concatenate({sub, MEMORY_SUFFIX}, a), true, nil
	}
	return strings.concatenate({name, MEMORY_SUFFIX}, a), false, nil
}

// ---------------------------------------------------------------------------
// Listing model
// ---------------------------------------------------------------------------

// Memories_List is the two-bucket listing (writable + read-only); names
// are cloned onto the owning allocator at add time.
Memories_List :: struct {
	memories:           [dynamic]string,
	read_only_memories: [dynamic]string,
	allocator:          mem.Allocator,
}

memories_list_init :: proc(ml: ^Memories_List, a: mem.Allocator) {
	ml^ = {
		memories           = make([dynamic]string, 0, 8, a),
		read_only_memories = make([dynamic]string, 0, 4, a),
		allocator                  = a,
	}
}

memories_list_destroy :: proc(ml: ^Memories_List) {
	for i in 0..<len(ml.memories) {
		if ml.memories[i] != "" {
			delete(ml.memories[i], ml.allocator)
		}
	}
	if ml.memories != nil {
		delete(ml.memories)
		ml.memories = nil
	}
	for i in 0..<len(ml.read_only_memories) {
		if ml.read_only_memories[i] != "" {
			delete(ml.read_only_memories[i], ml.allocator)
		}
	}
	if ml.read_only_memories != nil {
		delete(ml.read_only_memories)
		ml.read_only_memories = nil
	}
}

// memories_list_add appends a name to the appropriate bucket, skipping
// duplicates (the caller sorts when the listing is complete).
memories_list_add :: proc(ml: ^Memories_List, name: string, read_only: bool) {
	bucket := &ml.memories
	if read_only {
		bucket = &ml.read_only_memories
	}
	if slice.contains(bucket^[:], name) {
		return
	}
	append(bucket, strings.clone(name, ml.allocator))
}

memories_list_sort :: proc(ml: ^Memories_List) {
	sort.quick_sort(ml.memories[:])
	sort.quick_sort(ml.read_only_memories[:])
}

// ---------------------------------------------------------------------------
// `mem:` cross-references
// ---------------------------------------------------------------------------

// reference_pattern builds the `mem:<name>` reference matcher for one
// memory name. The trailing boundary group ([^\w/] or end of text) is
// preserved during replacement so `mem:foo` cannot match inside
// `mem:foobar` or `mem:foo/bar`. Allocated on `a`.
reference_pattern :: proc(name: string, a: mem.Allocator) -> string {
	return strings.concatenate(
		{REF_PREFIX, regex.quote_meta(name, context.temp_allocator), "([^\\w/]|$)"},
		a,
	)
}

// has_reference reports whether content references the memory by name.
has_reference :: proc(content: string, name: string) -> bool {
	pattern := reference_pattern(name, context.temp_allocator)
	re, err := regex.compile_regex(pattern, context.temp_allocator)
	if err != nil {
		return false
	}
	defer regex.regex_destroy(&re)
	return regex.regex_match(&re, content)
}

// rewrite_references rewrites every `mem:<old>` reference into
// `mem:<new>`, preserving the boundary character after each match. The
// result is allocated on `a` only when at least one reference changed;
// otherwise content is returned unchanged (borrowed) and the caller must
// not free it separately.
rewrite_references :: proc(content: string, old_name, new_name: string, a: mem.Allocator) -> (out: string, count: int) {
	pattern := reference_pattern(old_name, context.temp_allocator)
	re, err := regex.compile_regex(pattern, context.temp_allocator)
	if err != nil {
		return content, 0
	}
	defer regex.regex_destroy(&re)

	matches := regex.regex_find_all(&re, content, context.temp_allocator)
	if len(matches) == 0 {
		return content, 0
	}

	buf := make([dynamic]u8, 0, len(content) + len(new_name) + 16, a)
	prev := 0
	for m in matches {
		append(&buf, content[prev:m.start])
		append(&buf, REF_PREFIX)
		append(&buf, new_name)
		// Group 1 is the boundary character, or the empty end-of-text
		// match (start < 0 marks an unset group).
		captures := regex.regex_captures_at(&re, content, m.start, context.temp_allocator)
		if len(captures) > 1 && captures[1].start >= 0 {
			append(&buf, content[captures[1].start:captures[1].end])
		}
		prev = m.end
		count += 1
	}
	append(&buf, content[prev:])
	out = string(buf[:])
	buf = nil // the bytes are now owned by `out` on `a`
	return out, count
}
