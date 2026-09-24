// Runtime prerequisite checks: PATH lookup with fallback directories
// (the executable-resolution seam itself lives in platform/exec_path.odin
// — every consumer of launchability goes through it), the default check
// over RequiredBinaries/RequiredAnyOf, and the small directory/env
// helpers those checks share. Paths that make a *decision* (these
// checks) fail closed; pure construction stays swallow-and-surface per
// the path-builder contract.
package langserver

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "src:platform"

// look_path_with_fallbacks resolves name via PATH first, then by probing
// the given directories. The result is owned by `a`; "" when absent.
look_path_with_fallbacks :: proc(name: string, dirs: []string, a := context.allocator) -> string {
	if p := platform.find_in_path(name, context.temp_allocator); p != "" {
		return strings.clone(p, a)
	}
	for dir in dirs {
		p := platform.probe_in_dir(dir, name)
		if p != "" {
			return strings.clone(p, a)
		}
	}
	return ""
}

// resolve_configured_path turns a configured language-server path into the
// absolute argv[0] the start path uses: "" means no path was configured
// (use_normal = true — the entry's own command resolution applies), an
// absolute path passes through verbatim (it must keep working without a
// useful PATH: clients can spawn aubade with a scrubbed environment),
// "~"/"~/..." expands against `home`, and any other relative path anchors
// at the project root — the daemon's cwd is not a defined base. Pure
// construction: whether the result names an executable stays with the
// start path's fail-closed check, which reports this exact value in its
// error. The result is owned by `a`; scratch rides the temp allocator.
resolve_configured_path :: proc(
	path: string,
	project_root: string,
	home: string,
	a := context.allocator,
) -> (resolved: string, use_normal: bool) {
	if path == "" {
		return "", true
	}
	ta := context.temp_allocator
	base := path
	if path == "~" || strings.has_prefix(path, "~/") || strings.has_prefix(path, "~\\") {
		if len(path) == 1 {
			base = home
		} else {
			base = strings.concatenate({home, path[1:]}, ta)
		}
	}
	if filepath.is_abs(base) {
		clean, _ := filepath.clean(base, ta)
		return strings.clone(clean, a), false
	}
	joined, _ := filepath.join([]string{project_root, base}, ta)
	return strings.clone(joined, a), false
}

// clean_env_path validates a path-valued env var: empty and
// directory-traversing values are rejected (empty return), others pass
// through unchanged.
clean_env_path :: proc(val: string) -> string {
	if val == "" {
		return ""
	}
	if platform.has_dot_dot(val) {
		return ""
	}
	return val
}

// dedupe_dirs removes duplicate entries while preserving order, keying
// on the filesystem's canonical case (platform.path_fold) so case
// spellings of one directory dedup where the filesystem folds case. The
// fold key is intra-procedure scratch — the map dies at return and `d`
// outlives it — and the result (and its strings) is owned by `a`.
dedupe_dirs :: proc(dirs: []string, a := context.allocator) -> []string {
	out := make([dynamic]string, 0, len(dirs), a)
	seen := make(map[string]bool, len(dirs), a)
	defer delete(seen)
	for d in dirs {
		if d == "" {
			continue
		}
		key := platform.path_fold(d, context.temp_allocator)
		if seen[key] {
			continue
		}
		seen[key] = true
		append(&out, strings.clone(d, a))
	}
	return out[:]
}

// home_dir resolves the user's home directory ("" when unavailable);
// owned by `a`.
home_dir :: proc(a := context.allocator) -> string {
	raw := ""
	when ODIN_OS == .Windows {
		raw = os.get_env("USERPROFILE", context.temp_allocator)
	} else {
		raw = os.get_env("HOME", context.temp_allocator)
	}
	if raw == "" {
		return ""
	}
	return strings.clone(raw, a)
}

// node_available reports whether a Node.js runtime is on PATH (several
// npm-installed servers delegate to it).
node_available :: proc() -> bool {
	return platform.binary_available("node")
}

// default_check_runtime verifies every RequiredBinaries entry and every
// RequiredAnyOf group. Failure messages carry the install hint and live
// on the caller's arena.
default_check_runtime :: proc(e: ^Entry, arena: mem.Allocator) -> platform.Err {
	for req in e.required_binaries {
		if !platform.binary_available(req.name) {
			return not_installed_err(req.display_name, e.install_hint, arena)
		}
	}
	for req in e.required_any_of {
		if platform.find_first_binary(req.names) == "" {
			return not_installed_err(req.display_name, e.install_hint, arena)
		}
	}
	return nil
}

// INSTALL_CONSENT_NOTE is the standing instruction woven into every
// not-installed refusal: installing is the agent's job, but only with the
// user's consent, and the server comes up through the start tool. A
// binary at a custom path needs no install at all — pin it in the config.
// The routes it names must stay executable in a default session (where
// the management tools are inactive), so the primary route is config_set
// (always visible, applies live) and the optional tools are called out
// as such.
INSTALL_CONSENT_NOTE :: " Ask the user for consent before installing; once installed, start the server with langserver_start. A custom path needs no install: config_set with key language_servers, value = the array naming the server and its binary (e.g. [{\"name\": \"odin\", \"path\": \"/absolute/path/to/ols\"}]) pins it in .aubade/project.jsonc and applies it live (config_get with include_schema documents every key and the path forms). Editing the file by hand is the fallback; apply that with langserver_reload or a new session. The start/reload tools are optional — when they are inactive in this session, enable them via included_optional_tools (config_set is always active)."

// not_installed_err builds the "not installed / how to install" failure;
// the message lives on the caller's arena.
not_installed_err :: proc(display_name: string, install_hint: string, arena: mem.Allocator) -> platform.Err {
	if install_hint != "" {
		return platform.Wrapped{
			kind = .NotFound,
			msg = strings.concatenate(
				{display_name, " is not installed or not in PATH. Install: ", install_hint, ".", INSTALL_CONSENT_NOTE},
				arena,
			),
		}
	}
	return platform.Wrapped{
		kind = .NotFound,
		msg = strings.concatenate({display_name, " is not installed or not in PATH.", INSTALL_CONSENT_NOTE}, arena),
	}
}
