// Tests for the platform path helpers: the Windows root predicate is
// a shared lexical declaration, so its spelling battery runs on every
// platform, and the project-root refusal rule is checked directly
// against candidate lists.
package tests

import "core:os"
import "core:testing"
import "src:platform"

@(test)
windows_root_spellings :: proc(t: ^testing.T) {
	roots := []string{
		"/",          `\`,          "///",          `C:\`,
		"C:/",        "c:",         "C:",           "//srv/share",
		`\\srv\share`, `\\srv\share\`, `\\?\C:\`,   "//?/C:/",
		`\\?\UNC\srv\share`, `\\.\PhysicalDrive0`,
	}
	for s in roots {
		testing.expectf(t, platform.windows_path_is_root(s), "%s must read as a filesystem root", s)
	}
	not_roots := []string{
		"", ".", "relative", "/home", `C:\Users`, "//srv",
		`\\srv\share\dir`, "D:/x", "CC:", `:\`, `\\?\C:\Users`, "/a",
	}
	for s in not_roots {
		testing.expectf(t, !platform.windows_path_is_root(s), "%s must not read as a filesystem root", s)
	}
}

@(test)
project_root_refusal_rule :: proc(t: ^testing.T) {
	// The home compare takes every candidate spelling; an empty
	// candidate list leaves only the filesystem-root test.
	homes := make([]string, 1, context.temp_allocator)
	defer delete(homes, context.temp_allocator)

	home := "/home/someone"
	homes[0] = home
	refused, why := platform.project_root_refused(home, homes)
	testing.expect(t, refused)
	testing.expect_value(t, why, "it is the user's home directory")

	// A separator-differing home spelling matches on Windows, where
	// drive paths arrive both ways (on the other platforms a backslash
	// is a legal filename character and no normalization applies).
	when ODIN_OS == .Windows {
		homes[0] = `C:\Users\a`
		refused, _ = platform.project_root_refused("C:/Users/a", homes)
		testing.expect(t, refused)
	}

	// Not a root, not the home: accepted.
	homes[0] = home
	refused, _ = platform.project_root_refused("/no/such/root", homes)
	testing.expect(t, !refused)

	// No candidates: the filesystem-root test still holds on the
	// current platform's spelling of "/".
	refused, why = platform.project_root_refused("/", nil)
	testing.expect(t, refused)
	testing.expect_value(t, why, "it is a filesystem root")

	refused, _ = platform.project_root_refused("/no/such/root", nil)
	testing.expect(t, !refused)
}

@(test)
user_homes_reflects_home_redirect :: proc(t: ^testing.T) {
	// A redirected $HOME must appear among the refusal candidates:
	// every isolation-style test (and embedded environment) depends on
	// it, on Windows where the canonical Profile spelling is first, as
	// much as elsewhere.
	fake, err := os.make_directory_temp("", "aubade-paths-home-", context.allocator)
	if err != nil {
		testing.expectf(t, false, "temp home failed")
		return
	}
	defer {
		_ = os.remove_all(fake)
		delete(fake)
	}
	old, had := os.lookup_env_alloc("HOME", context.temp_allocator)
	os.set_env("HOME", fake)
	defer if had {
		os.set_env("HOME", old)
	} else {
		os.unset_env("HOME")
	}

	homes := platform.user_homes(context.allocator)
	found := false
	for h in homes {
		if platform.path_equal_any_sep(h, fake) {
			found = true
		}
		delete(h, context.allocator)
	}
	delete(homes, context.allocator)
	testing.expect(t, found, "the redirected $HOME must be a refusal candidate")
}
