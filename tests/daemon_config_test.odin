// resolve_editor_settings hands back the encoding owned by the caller's
// allocator: the config parse runs on a private arena destroyed at return,
// so a string left pointing into that arena is freed memory. The
// test resolves a project that sets encoding + line_ending, checks both,
// and frees the string through the same allocator — against the old
// arena-escape the delete was a bad free of arena-interior bytes.
package tests

import "core:os"
import "core:path/filepath"
import "core:testing"

import "src:config"
import "src:daemon"

@(test)
resolve_editor_settings_clones_encoding :: proc(t: ^testing.T) {
	tmp, terr := os.make_directory_temp("", "aubade-cfg-", context.allocator)
	if terr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		os.remove_all(tmp)
		delete(tmp, context.allocator)
	}

	home, _ := filepath.join([]string{tmp, "home"}, context.allocator)
	defer delete(home, context.allocator)
	if herr := os.make_directory(home); herr != nil {
		testing.fail_now(t, "home dir failed")
	}
	root, _ := filepath.join([]string{tmp, "proj"}, context.allocator)
	defer delete(root, context.allocator)
	if rerr := os.make_directory(root); rerr != nil {
		testing.fail_now(t, "project dir failed")
	}
	managed, _ := filepath.join([]string{root, ".aubade"}, context.allocator)
	defer delete(managed, context.allocator)
	if merr := os.make_directory(managed); merr != nil {
		testing.fail_now(t, "managed dir failed")
	}
	cfg_path, _ := filepath.join([]string{managed, "project.jsonc"}, context.allocator)
	defer delete(cfg_path, context.allocator)
	body := "{\"encoding\": \"utf-16\", \"line_ending\": \"crlf\"}"
	if werr := os.write_entire_file_from_string(cfg_path, body); werr != nil {
		testing.fail_now(t, "project.jsonc write failed")
	}

	d := new(daemon.Daemon, context.allocator)
	defer free(d, context.allocator)
	d^ = {cfg = daemon.default_config(root, home, nil)}

	line_ending, encoding := daemon.resolve_editor_settings(d, context.allocator)
	testing.expect_value(t, line_ending, config.Line_Ending.Crlf)
	testing.expect_value(t, encoding, "utf-16")
	// The resolved string is owned by the passed allocator (the clone the
	// fix added); freeing it here is a clean delete, not an arena interior.
	delete(encoding, context.allocator)
}

@(test)
config_edit_key_tables_are_project_keys :: proc(t: ^testing.T) {
	// The daemon's config-edit tables must stay inside the loader's key
	// knowledge: every live-applicable key and every member-writable key
	// is a real project key, and a member edit is always live-applicable
	// (the member write rewrites a map the live reload re-reads).
	for key in daemon.CONFIG_LIVE_KEYS {
		testing.expectf(t, config.project_key_known(key), "live key %q is not a known project key", key)
	}
	for key in daemon.CONFIG_MEMBER_KEYS {
		testing.expectf(t, config.project_key_known(key), "member key %q is not a known project key", key)
		live := false
		for k in daemon.CONFIG_LIVE_KEYS {
			if k == key {
				live = true
				break
			}
		}
		testing.expectf(t, live, "member key %q is not live-applicable", key)
	}
}
