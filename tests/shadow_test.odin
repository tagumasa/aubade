// Shadow git service tests against a real git CLI: the full snapshot
// lifecycle (snapshot → diff/patch/log → restore → revert_file) plus the
// refusal paths (hash validation, workspace escapes, symlink targets).
// The repository lands under a temp home; AUBADE_HOME is not consulted.
package tests

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

import "src:platform"
import "src:shadow"

@(test)
validate_hash_accepts_both_object_formats :: proc(t: ^testing.T) {
	// The shadow repository inherits the user's init.defaultObjectFormat,
	// so a sha256 default produces 64-hex ids that must clear the same
	// guard as the 40-hex sha1 ids. The charset check stays the injection
	// guard: a 65-char all-hex string is still refused on length alone.
	sha1 := "0123456789abcdef0123456789abcdef01234567"
	sha256 := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	too_long := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0"
	if err := shadow.validate_hash(sha1); err != nil {
		testing.expectf(t, false, "sha1-length id refused: %s", shadow_err_text(err))
		return
	}
	if err := shadow.validate_hash(sha256); err != nil {
		testing.expectf(t, false, "sha256-length id refused: %s", shadow_err_text(err))
		return
	}
	testing.expect(t, shadow.validate_hash(too_long, context.temp_allocator) != nil, "65-char id must be refused")
}

Shadow_Env :: struct {
	workspace: string,
	home:      string,
	sg:        ^shadow.Shadow_Git,
	arena:     ^mem.Dynamic_Arena,
}

// shadow_setup makes a temp workspace with one file and an initialized
// shadow repository under a temp home. A nil sg means the expects already
// fired and the caller must simply return.
shadow_setup :: proc(t: ^testing.T, label: string) -> Shadow_Env {
	env: Shadow_Env
	tmp, terr := os.make_directory_temp("", label, context.allocator)
	if terr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	env.workspace = tmp
	// The home is its own temp tree: the snapshot repository must sit
	// outside the tracked workspace (a repo nested inside its work tree
	// makes git ignore GIT_WORK_TREE).
	home_dir, herr := os.make_directory_temp("", "aubade-shadow-home-", context.allocator)
	if herr != nil {
		os.remove_all(tmp)
		delete(tmp, context.allocator)
		testing.fail_now(t, "home temp dir failed")
	}
	env.home = home_dir
	env.arena = new(mem.Dynamic_Arena, context.allocator)
	mem.dynamic_arena_init(env.arena, context.allocator)

	first := strings.concatenate({tmp, "/a.txt"}, context.temp_allocator)
	if werr := os.write_entire_file_from_string(first, "one\n"); werr != nil {
		// The arena and temp dirs are already live: fail_now would skip
		// every caller defer, so report and hand the half-built env back
		// — its teardown is nil-guarded and the caller defers it.
		testing.expectf(t, false, "seed file failed")
		return env
	}

	env.sg = new(shadow.Shadow_Git, context.allocator)
	ierr := shadow.shadow_init(env.sg, env.home, tmp, context.allocator)
	if ierr != nil {
		testing.expectf(t, false, "shadow_init: %s", shadow_err_text(ierr))
		shadow_teardown(&env)
		return env
	}
	rerr := shadow.shadow_repo_init(env.sg)
	if rerr != nil {
		testing.expectf(t, false, "shadow_repo_init: %s", shadow_err_text(rerr))
		shadow_teardown(&env)
		return env
	}
	return env
}

// shadow_teardown releases everything without assertions so both the
// happy path and a failed expect can share it (fail_now would skip defers).
shadow_teardown :: proc(env: ^Shadow_Env) {
	if env.sg != nil {
		shadow.shadow_destroy(env.sg, context.allocator)
		free(env.sg, context.allocator)
		env.sg = nil
	}
	if env.workspace != "" {
		os.remove_all(env.workspace)
		delete(env.workspace, context.allocator)
	}
	if env.home != "" {
		os.remove_all(env.home)
		delete(env.home, context.allocator)
	}
	if env.arena != nil {
		mem.dynamic_arena_destroy(env.arena)
		free(env.arena, context.allocator)
	}
	env^ = {}
}

shadow_err_text :: proc(e: platform.Err) -> string {
	return platform.err_message(e, context.temp_allocator)
}

// shadow_patch must report exact path spellings: plain --name-only output
// C-quotes non-ASCII and special characters (core.quotePath is on by
// default), so the listing rides -z and splits on NUL.
@(test)
test_shadow_patch_odd_path_names :: proc(t: ^testing.T) {
	env := shadow_setup(t, "aubade-shadow-q-")
	if env.sg == nil {
		return
	}
	defer shadow_teardown(&env)
	a := mem.dynamic_arena_allocator(env.arena)

	h1, err := shadow.shadow_snapshot(env.sg, "first", nil, a)
	if err != nil {
		testing.expectf(t, false, "snapshot 1: %s", shadow_err_text(err))
		return
	}

	// One non-ASCII name and one carrying a double quote: both come back
	// C-quoted from plain diff output, exact only through -z. The quote
	// name is POSIX-only — Win32 forbids `"` in file names — so the
	// corpus and its expectations drop it there.
	odd1 := strings.concatenate({env.workspace, "/日本語.odin"}, context.temp_allocator)
	if werr := os.write_entire_file_from_string(odd1, "odd\n"); werr != nil {
		testing.expect(t, false, "seed non-ASCII name failed")
		return
	}
	want_files := 1
	when ODIN_OS != .Windows {
		odd2 := strings.concatenate({env.workspace, "/quote\"name.txt"}, context.temp_allocator)
		if werr2 := os.write_entire_file_from_string(odd2, "quoted\n"); werr2 != nil {
			testing.expect(t, false, "seed quote-name failed")
			return
		}
		want_files = 2
	}
	h2, err2 := shadow.shadow_snapshot(env.sg, "second", nil, a)
	if err2 != nil {
		testing.expectf(t, false, "snapshot 2: %s", shadow_err_text(err2))
		return
	}

	files, perr := shadow.shadow_patch(env.sg, h1, h2, nil, a)
	if perr != nil {
		testing.expectf(t, false, "patch: %s", shadow_err_text(perr))
		return
	}
	testing.expect(t, len(files) == want_files, "patch lists the odd-named files")
	saw_non_ascii := false
	saw_quote := false
	for f in files {
		if f == "日本語.odin" {
			saw_non_ascii = true
		}
		if f == "quote\"name.txt" {
			saw_quote = true
		}
	}
	testing.expect(t, saw_non_ascii, "patch spells the non-ASCII name exactly")
	when ODIN_OS != .Windows {
		testing.expect(t, saw_quote, "patch spells the quote name exactly")
	}
}

// The daemon's own project state must never enter the snapshot: the
// restore gate refuses writes under .aubade/, so a tracked state file
// would make its own snapshot unrestorable.
@(test)
test_shadow_excludes_managed_state :: proc(t: ^testing.T) {
	env := shadow_setup(t, "aubade-shadow-m-")
	if env.sg == nil {
		return
	}
	defer shadow_teardown(&env)
	a := mem.dynamic_arena_allocator(env.arena)

	managed := strings.concatenate({env.workspace, "/.aubade"}, context.temp_allocator)
	if merr := os.make_directory_all(managed, {.Read_User, .Write_User, .Execute_User}); merr != nil {
		testing.expect(t, false, "managed dir failed")
		return
	}
	db := strings.concatenate({managed, "/aubade.db"}, context.temp_allocator)
	if werr := os.write_entire_file_from_string(db, "sqlite-bytes\n"); werr != nil {
		testing.expect(t, false, "managed db seed failed")
		return
	}

	h1, err := shadow.shadow_snapshot(env.sg, "with-managed-state", nil, a)
	if err != nil {
		testing.expectf(t, false, "snapshot: %s", shadow_err_text(err))
		return
	}

	files, ferr := shadow.shadow_files_at(env.sg, h1, nil, a)
	if ferr != nil {
		testing.expectf(t, false, "files_at: %s", shadow_err_text(ferr))
		return
	}
	for f in files {
		testing.expectf(t, !strings.has_prefix(f, ".aubade/"), "managed state tracked: %s", f)
	}

	if rerr := shadow.shadow_restore(env.sg, h1, nil); rerr != nil {
		testing.expectf(t, false, "restore: %s", shadow_err_text(rerr))
	}
}

@(test)
test_shadow_lifecycle :: proc(t: ^testing.T) {
	env := shadow_setup(t, "aubade-shadow-")
	if env.sg == nil {
		return
	}
	defer shadow_teardown(&env)
	a := mem.dynamic_arena_allocator(env.arena)

	// First snapshot of the seeded file.
	h1, err := shadow.shadow_snapshot(env.sg, "first", nil, a)
	if err != nil {
		testing.expectf(t, false, "snapshot 1: %s", shadow_err_text(err))
		return
	}
	testing.expect(t, is_lower_hex(h1) && len(h1) == 40, "full 40-hex commit hash expected")

	// An unchanged workspace returns HEAD without a new commit.
	h1b, err2 := shadow.shadow_snapshot(env.sg, "", nil, a)
	if err2 != nil {
		testing.expectf(t, false, "snapshot 1b: %s", shadow_err_text(err2))
		return
	}
	testing.expect(t, h1b == h1, "unchanged snapshot returns HEAD")

	// Change the file, add a second one, snapshot again.
	second := strings.concatenate({env.workspace, "/a.txt"}, context.temp_allocator)
	if werr := os.write_entire_file_from_string(second, "two\n"); werr != nil {
		testing.expectf(t, false, "rewrite failed")
		return
	}
	extra := strings.concatenate({env.workspace, "/b.txt"}, context.temp_allocator)
	if werr2 := os.write_entire_file_from_string(extra, "new\n"); werr2 != nil {
		testing.expectf(t, false, "seed b failed")
		return
	}
	h2, err3 := shadow.shadow_snapshot(env.sg, "second", nil, a)
	if err3 != nil {
		testing.expectf(t, false, "snapshot 2: %s", shadow_err_text(err3))
		return
	}
	testing.expect(t, h2 != h1, "changed workspace makes a new commit")

	// diff names both files; patch lists them.
	diff, derr := shadow.shadow_diff(env.sg, h1, h2, nil, a)
	if derr != nil {
		testing.expectf(t, false, "diff: %s", shadow_err_text(derr))
		return
	}
	testing.expect(t, strings.contains(diff, "a.txt"), "diff mentions a.txt")
	testing.expect(t, strings.contains(diff, "b.txt"), "diff mentions b.txt")

	files, perr := shadow.shadow_patch(env.sg, h1, h2, nil, a)
	if perr != nil {
		testing.expectf(t, false, "patch: %s", shadow_err_text(perr))
		return
	}
	testing.expect(t, len(files) == 2, "patch lists two files")

	// log is newest-first.
	log, lerr := shadow.shadow_log(env.sg, 10, nil, a)
	if lerr != nil {
		testing.expectf(t, false, "log: %s", shadow_err_text(lerr))
		return
	}
	testing.expect(t, len(log) == 2 && log[0] == h2 && log[1] == h1, "log order")

	// revert_file restores a.txt to its first-snapshot content.
	if rerr := shadow.shadow_revert_file(env.sg, h1, "a.txt", nil, a); rerr != nil {
		testing.expectf(t, false, "revert_file: %s", shadow_err_text(rerr))
		return
	}
	content, _ := os.read_entire_file_from_path(second, a)
	testing.expect(t, string(content) == "one\n", "reverted content")

	// restore rolls the whole workspace back to snapshot 1 (b.txt goes).
	if rerr2 := shadow.shadow_restore(env.sg, h1, nil, a); rerr2 != nil {
		testing.expectf(t, false, "restore: %s", shadow_err_text(rerr2))
		return
	}
	if _, berr := os.read_entire_file_from_path(extra, context.temp_allocator); berr == nil {
		testing.expectf(t, false, "b.txt should be gone after restore")
		return
	}
}

@(test)
test_shadow_refusals :: proc(t: ^testing.T) {
	env := shadow_setup(t, "aubade-shadow-ref-")
	if env.sg == nil {
		return
	}
	defer shadow_teardown(&env)
	a := mem.dynamic_arena_allocator(env.arena)

	h1, err := shadow.shadow_snapshot(env.sg, "s", nil, a)
	if err != nil {
		testing.expectf(t, false, "snapshot: %s", shadow_err_text(err))
		return
	}

	// Malformed hashes never reach a git command line.
	if _, derr := shadow.shadow_diff(env.sg, "../../etc", h1, nil, a); derr == nil {
		testing.expectf(t, false, "traversal hash refused")
		return
	}
	if _, derr2 := shadow.shadow_diff(env.sg, h1, "ZZZZZZZ", nil, a); derr2 == nil {
		testing.expectf(t, false, "non-hex hash refused")
		return
	}

	// Workspace escapes and root paths are refused.
	if rerr := shadow.shadow_revert_file(env.sg, h1, "../outside.txt", nil, a); rerr == nil {
		testing.expectf(t, false, "escape refused")
		return
	}
	if rerr2 := shadow.shadow_revert_file(env.sg, h1, "/", nil, a); rerr2 == nil {
		testing.expectf(t, false, "root refused")
		return
	}

	// The workspace gate carries the filesystem's case sensitivity: a path
	// that walks above the root and re-enters with a case-variant spelling
	// of the workspace directory is inside on macOS/Windows (one directory,
	// two spellings) and genuinely outside on Linux. The contained arm must
	// restore through the canonical relative spelling — a tracked file
	// must never fall into the not-in-snapshot removal branch.
	slash := strings.last_index_byte(env.workspace, '/')
	base := env.workspace[slash + 1:]
	case_variant := strings.concatenate(
		{"../", strings.to_upper(base, context.temp_allocator), "/a.txt"},
		context.temp_allocator,
	)
	if platform.case_insensitive_fs() {
		if rerr := shadow.shadow_revert_file(env.sg, h1, case_variant, nil, a); rerr != nil {
			testing.expectf(t, false, "case-variant spelling must stay contained: %s", shadow_err_text(rerr))
			return
		}
		a_path := strings.concatenate({env.workspace, "/a.txt"}, context.temp_allocator)
		content, cerr := os.read_entire_file_from_path(a_path, a)
		testing.expectf(t, cerr == nil, "a.txt still present after case-variant revert")
		testing.expect(t, string(content) == "one\n", "case-variant revert restored the tracked content")
	} else {
		if rerr := shadow.shadow_revert_file(env.sg, h1, case_variant, nil, a); rerr == nil {
			testing.expectf(t, false, "case-variant spelling is a different directory here")
			return
		}
	}

	// A symlink target is refused even when the path itself is contained
	// (Windows symlink creation needs privileges; the check is skipped
	// there rather than failing the suite).
	when ODIN_OS != .Windows {
		link := strings.concatenate({env.workspace, "/link.txt"}, context.temp_allocator)
		if terr := os.symlink("a.txt", link); terr == nil {
			if rerr3 := shadow.shadow_revert_file(env.sg, h1, "link.txt", nil, a); rerr3 == nil {
				testing.expectf(t, false, "symlink refused")
			}
			os.remove(link)
		}
	}
}

@(test)
test_shadow_restore_gate :: proc(t: ^testing.T) {
	env := shadow_setup(t, "aubade-shadow-gate-")
	if env.sg == nil {
		return
	}
	defer shadow_teardown(&env)
	a := mem.dynamic_arena_allocator(env.arena)

	extra := strings.concatenate({env.workspace, "/b.txt"}, context.temp_allocator)
	if werr := os.write_entire_file_from_string(extra, "new\n"); werr != nil {
		testing.expectf(t, false, "seed b failed")
		return
	}
	h1, err := shadow.shadow_snapshot(env.sg, "gate", nil, a)
	if err != nil {
		testing.expectf(t, false, "snapshot: %s", shadow_err_text(err))
		return
	}

	// files_at lists the tracked set at the hash — the rewrite set the
	// restore gate checks.
	paths, ferr := shadow.shadow_files_at(env.sg, h1, nil, a)
	if ferr != nil {
		testing.expectf(t, false, "files_at: %s", shadow_err_text(ferr))
		return
	}
	testing.expect(t, len(paths) == 2, "files_at lists both tracked files")

	// A clean set restores.
	if rerr := shadow.shadow_restore(env.sg, h1, nil, a); rerr != nil {
		testing.expectf(t, false, "clean restore: %s", shadow_err_text(rerr))
		return
	}

	// A tracked path that has become a symlink escaping the root refuses
	// the whole rewrite before anything is written (Windows symlink
	// creation needs privileges; the check is skipped there).
	when ODIN_OS != .Windows {
		tracked := strings.concatenate({env.workspace, "/a.txt"}, context.temp_allocator)
		if rmerr := os.remove(tracked); rmerr != nil {
			testing.expectf(t, false, "remove a.txt failed")
			return
		}
		if lerr := os.symlink("../aubade-shadow-gate-escape", tracked); lerr != nil {
			testing.expectf(t, false, "symlink failed")
			return
		}
		rerr := shadow.shadow_restore(env.sg, h1, nil, a)
		if rerr == nil {
			testing.expectf(t, false, "restore over escaping symlink refused")
			return
		}
		testing.expectf(
			t,
			strings.contains(shadow_err_text(rerr), "restore refused"),
			"refusal names the gate: %s", shadow_err_text(rerr),
		)
		// Nothing was written through the link.
		escaped := strings.concatenate({env.workspace, "/../aubade-shadow-gate-escape"}, context.temp_allocator)
		if _, eerr := os.read_entire_file_from_path(escaped, context.temp_allocator); eerr == nil {
			testing.expectf(t, false, "escape target must not exist")
		}

		// Reset the leaf link, then exercise the intermediate-directory
		// case: a tracked path under a parent directory replaced by a
		// symlink passes the lexical gate and the leaf lstat (the stat
		// follows the directory link) — only component resolution catches
		// it.
		os.remove(tracked)
		if rwerr := os.write_entire_file_from_string(tracked, "one\n"); rwerr != nil {
			testing.expectf(t, false, "reset a.txt failed")
			return
		}

		sub := strings.concatenate({env.workspace, "/sub"}, context.temp_allocator)
		if merr := os.make_directory(sub, os.Permissions{.Read_User, .Write_User, .Execute_User}); merr != nil {
			testing.expectf(t, false, "seed sub failed")
			return
		}
		seed_c := strings.concatenate({sub, "/c.txt"}, context.temp_allocator)
		if swerr := os.write_entire_file_from_string(seed_c, "inner\n"); swerr != nil {
			testing.expectf(t, false, "seed c.txt failed")
			return
		}
		h2, serr := shadow.shadow_snapshot(env.sg, "gate2", nil, a)
		if serr != nil {
			testing.expectf(t, false, "snapshot 2: %s", shadow_err_text(serr))
			return
		}

		outside := strings.concatenate({env.workspace, "/../aubade-shadow-gate-mid"}, context.temp_allocator)
		if oerr := os.make_directory(outside, os.Permissions{.Read_User, .Write_User, .Execute_User}); oerr != nil {
			testing.expectf(t, false, "seed outside dir failed")
			return
		}
		outside_c := strings.concatenate({outside, "/c.txt"}, context.temp_allocator)
		if owerr := os.write_entire_file_from_string(outside_c, "outside\n"); owerr != nil {
			testing.expectf(t, false, "seed outside c.txt failed")
			return
		}
		os.remove_all(sub)
		if lerr2 := os.symlink("../aubade-shadow-gate-mid", sub); lerr2 != nil {
			testing.expectf(t, false, "dir symlink failed")
			return
		}
		rerr2 := shadow.shadow_restore(env.sg, h2, nil, a)
		if rerr2 == nil {
			testing.expectf(t, false, "restore through symlinked parent refused")
			return
		}
		testing.expectf(
			t,
			strings.contains(shadow_err_text(rerr2), "sub/c.txt"),
			"refusal names the tracked path under the symlinked parent: %s", shadow_err_text(rerr2),
		)
		// Nothing was written through the directory link.
		outside_got, _ := os.read_entire_file_from_path(outside_c, context.temp_allocator)
		testing.expect(t, string(outside_got) == "outside\n", "outside file must be untouched")

		// The single-path gate refuses the same shape.
		if rerr3 := shadow.shadow_revert_file(env.sg, h2, "sub/c.txt", nil, a); rerr3 == nil {
			testing.expectf(t, false, "revert_file through symlinked parent refused")
		}

		// Cleanup beyond the workspace tree: the outside directory is a
		// temp sibling the fixture teardown does not know about.
		os.remove(sub)
		os.remove_all(outside)
	}
}

// is_lower_hex reports whether s is non-empty lowercase hex — the shape
// of a git object id, stronger than a bare length pin.
is_lower_hex :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for c in s {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}
