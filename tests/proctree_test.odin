// proctree_env_cstrings: the execve array contract. The terminator byte
// is the load-bearing part — an append-grown array reads whatever follows
// its last entry (and an empty override would have no [0] to take), so
// every consumer goes through the one shared declaration.
package tests

import "core:os"
import "core:testing"

import "src:platform"

cstring_eq :: proc(c: cstring, s: string) -> bool {
	p := cast([^]u8)c
	for i in 0..<len(s) {
		if p[i] != s[i] {
			return false
		}
	}
	return p[len(s)] == 0
}

@(test)
proctree_env_cstrings_terminates_override :: proc(t: ^testing.T) {
	envp, err := platform.proctree_env_cstrings({"A=1", "B=2"}, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, cstring_eq(envp[0], "A=1"))
	testing.expect(t, cstring_eq(envp[1], "B=2"))
	testing.expect(t, envp[2] == nil, "the trailing nil is the execve terminator")
}

@(test)
proctree_env_cstrings_empty_override_is_valid :: proc(t: ^testing.T) {
	// A non-nil empty override is a real input shape (a dynamic grown to
	// nothing): the array must still exist with its terminator at index 0,
	// not panic on taking [0] of an append-grown empty.
	empty := make([dynamic]string, 0, 1, context.temp_allocator)
	defer delete(empty)
	envp, err := platform.proctree_env_cstrings(empty[:], context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, envp[0] == nil)
}

@(test)
proctree_env_cstrings_nil_inherits_and_terminates :: proc(t: ^testing.T) {
	// nil = inherit: the array mirrors os.environ with the terminator
	// right after. The walk is bounded by the expected count so a missing
	// terminator fails the test instead of walking off the allocation.
	environ, _ := os.environ(context.temp_allocator)
	defer for e in environ {
		delete(e, context.temp_allocator)
	}
	envp, err := platform.proctree_env_cstrings(nil, context.temp_allocator)
	testing.expect(t, err == nil)
	count := 0
	for envp[count] != nil && count < len(environ) + 8 {
		count += 1
	}
	testing.expectf(t, count == len(environ), "walked %d entries for %d environment strings", count, len(environ))
}
