// Tests for src/safety/envguard.odin. Pure functions only; no env I/O.
package tests

import "core:strings"
import "core:testing"
import "src:safety"

// scrub_default scrubs through a guard carrying the default prefix list —
// the production scrub path (the checker owns its guard; the deleted
// default-list twin lived only for these tests).
scrub_default :: proc(env: []string) -> []string {
	g: safety.Env_Guard
	safety.envguard_init(&g)
	defer safety.envguard_destroy(&g)
	return safety.envguard_scrub(&g, env, context.temp_allocator)
}

@(test)
scrub_env_keeps_allowed :: proc(t: ^testing.T) {
	got := scrub_default({"PATH=/usr/bin", "HOME=/root"})
	testing.expect_value(t, len(got), 2)
	// Order-preserving.
	found_path := false
	found_home := false
	for entry in got {
		if strings.has_prefix(entry, "PATH=") { found_path = true }
		if strings.has_prefix(entry, "HOME=") { found_home = true }
	}
	testing.expect(t, found_path)
	testing.expect(t, found_home)
}

@(test)
scrub_env_drops_unknown :: proc(t: ^testing.T) {
	got := scrub_default({"FOOBAR=value", "HOME=/root"})
	testing.expect_value(t, len(got), 1)
	testing.expect(t, strings.has_prefix(got[0], "HOME="))
}

@(test)
scrub_env_keeps_windows_system_vars :: proc(t: ^testing.T) {
	got := scrub_default({
		"SystemRoot=C:\\Windows",
		"ComSpec=C:\\Windows\\system32\\cmd.exe",
		"PATHEXT=.COM;.EXE;.BAT;.CMD",
		"APPDATA=C:\\Users\\u\\AppData\\Roaming",
		"PROCESSOR_ARCHITECTURE=AMD64",
		"NUMBER_OF_PROCESSORS=8",
	})
	testing.expect_value(t, len(got), 6)
	for entry in got {
		testing.expect(t, !strings.contains(entry, ".."))
	}
}

@(test)
scrub_env_windows_path_vars_reject_traversal :: proc(t: ^testing.T) {
	// The Windows data roots are path-like keys: a ".." segment in the
	// value rejects the entry like the unix path set.
	got := scrub_default({"APPDATA=C:\\Users\\u\\..\\..\\escape"})
	testing.expect_value(t, len(got), 0)
}

@(test)
scrub_env_drops_secret_substrings :: proc(t: ^testing.T) {
	got := scrub_default({
		"HOME=/root",
		"MY_KEY=value",
		"MY_TOKEN=value",
		"MY_PASSWORD=value",
		"DB_AUTH=value",
	})
	// The HOME entry survives. Everything with a secret substring is dropped.
	for entry in got {
		testing.expect(t, !strings.contains(entry, "_KEY="))
		testing.expect(t, !strings.contains(entry, "_TOKEN="))
		testing.expect(t, !strings.contains(entry, "_PASSWORD="))
		testing.expect(t, !strings.contains(entry, "_AUTH="))
	}
}

@(test)
scrub_env_rejects_null_bytes :: proc(t: ^testing.T) {
	home_bytes: [5]u8 = {'r', 'o', 'o', 't', 0x00}
	got := scrub_default({
		strings.concatenate({"HOME=", string(home_bytes[:])}, context.temp_allocator),
	})
	testing.expect_value(t, len(got), 0)
}

@(test)
scrub_env_path_traversal_rejected :: proc(t: ^testing.T) {
	// ".." in a PATH-like variable value rejects the entry.
	got := scrub_default({
		"PATH=/usr/bin:/tmp/../escape:/usr/local/bin",
	})
	testing.expect_value(t, len(got), 0)
}

@(test)
scrub_env_goproxy_valid :: proc(t: ^testing.T) {
	got := scrub_default({"GOPROXY=https://proxy.example.com"})
	testing.expect_value(t, len(got), 1)
}

@(test)
scrub_env_goproxy_off :: proc(t: ^testing.T) {
	got := scrub_default({"GOPROXY=off"})
	testing.expect_value(t, len(got), 1)
}

@(test)
scrub_env_goproxy_direct :: proc(t: ^testing.T) {
	got := scrub_default({"GOPROXY=direct"})
	testing.expect_value(t, len(got), 1)
}

@(test)
scrub_env_goproxy_invalid_scheme :: proc(t: ^testing.T) {
	got := scrub_default({"GOPROXY=ftp://example.com"})
	testing.expect_value(t, len(got), 0)
}

@(test)
scrub_env_git_cap :: proc(t: ^testing.T) {
	// GIT_ values beyond 1024 bytes are truncated; the value (now shorter)
	// survives.
	long := strings.clone(strings_repeat("x", 2000), context.temp_allocator)
	got := scrub_default(
		{strings.concatenate({"GIT_TRACE=", long}, context.temp_allocator)},
	)
	testing.expect_value(t, len(got), 1)
	testing.expect(t, len(got[0]) <= len("GIT_TRACE=") + 1024 + 1)
}

@(test)
scrub_env_skips_entries_without_equals :: proc(t: ^testing.T) {
	got := scrub_default({
		"PATH",
		"HOME=/root",
	})
	testing.expect_value(t, len(got), 1)
}

@(test)
scrub_env_max_value_len_caps_long :: proc(t: ^testing.T) {
	// Non-GIT_ keys cap at MAX_ENV_VALUE_LEN (8192).
	long := strings.clone(strings_repeat("x", 10_000), context.temp_allocator)
	got := scrub_default(
		{strings.concatenate({"HOME=", long}, context.temp_allocator)},
	)
	testing.expect_value(t, len(got), 1)
	// "HOME=" (5) + 8192.
	testing.expect_value(t, len(got[0]), 5 + safety.MAX_ENV_VALUE_LEN)
}

@(test)
scrub_env_case_insensitive_match :: proc(t: ^testing.T) {
	// Allowed-prefix and secret check must be case-insensitive.
	got := scrub_default({"home=/r"})
	testing.expect_value(t, len(got), 1)

	got = scrub_default({"my_key=v"})
	testing.expect_value(t, len(got), 0)
}

@(test)
is_path_like_key :: proc(t: ^testing.T) {
	testing.expect(t, safety.is_path_like_key("PATH"))
	testing.expect(t, safety.is_path_like_key("HOME"))
	testing.expect(t, !safety.is_path_like_key("LANG"))
}

// The checker-owned guard is live: prefixes added through the guard take
// effect via scrub_environment (the facade once ignored its checker).
@(test)
scrub_environment_uses_checker_guard :: proc(t: ^testing.T) {
	s := new(safety.Safety_Checker, context.allocator)
	safety.safety_checker_init(s, context.allocator)
	defer {
		safety.safety_checker_destroy(s)
		free(s, context.allocator)
	}

	got := safety.scrub_environment(s, {"HOME=/root", "MYAPP_TOOL=x"}, context.temp_allocator)
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, got[0], "HOME=/root")

	// A borrowed static prefix widens the allow set.
	safety.envguard_add_allowed(&s.env_guard, "MYAPP_")
	got2 := safety.scrub_environment(s, {"HOME=/root", "MYAPP_TOOL=x"}, context.temp_allocator)
	testing.expect_value(t, len(got2), 2)
}
