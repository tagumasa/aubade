// Runtime prerequisite checks: PATH lookup with fallback directories,
// the default check over RequiredBinaries/RequiredAnyOf, and the small
// directory/env helpers the resolver procs share. Paths that make a
// *decision* (these checks) fail closed; pure construction stays
// swallow-and-surface per the path-builder contract.
package langserver

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "src:platform"

when ODIN_OS == .Windows {
	PATH_LIST_SEP :: ";"
} else {
	PATH_LIST_SEP :: ":"
}

// find_in_path resolves an executable through PATH (plus the platform's
// executable suffixes on Windows); "" when absent. The result is owned
// by `a`.
find_in_path :: proc(name: string, a := context.allocator) -> string {
	if name == "" {
		return ""
	}
	if strings.contains_any(name, "/\\") {
		if is_executable_file(name) {
			return strings.clone(name, a)
		}
		return ""
	}
	path := os.get_env("PATH", context.temp_allocator)
	if path == "" {
		return ""
	}
	for dir in strings.split(path, PATH_LIST_SEP, context.temp_allocator) {
		p := probe_in_dir(dir, name)
		if p != "" {
			return strings.clone(p, a)
		}
	}
	return ""
}

// probe_in_dir joins dir/name (plus executable suffixes on Windows) and
// returns the path on the temp allocator when an executable file sits
// there; "" otherwise.
probe_in_dir :: proc(dir: string, name: string) -> string {
	if dir == "" {
		return ""
	}
	when ODIN_OS == .Windows {
		suffixes := [4]string{"", ".exe", ".cmd", ".bat"}
	} else {
		suffixes := [1]string{""}
	}
	for suf in suffixes {
		cand := strings.concatenate({name, suf}, context.temp_allocator)
		p, _ := filepath.join({dir, cand}, context.temp_allocator)
		if is_executable_file(p) {
			return p
		}
	}
	return ""
}

// binary_available reports whether the executable resolves on PATH or by
// direct path (boolean check; no ownership).
binary_available :: proc(name: string) -> bool {
	return find_in_path(name, context.temp_allocator) != ""
}

// find_first_binary returns the first candidate that resolves (temp
// allocator; "" when none do).
find_first_binary :: proc(candidates: []string) -> string {
	for name in candidates {
		if binary_available(name) {
			return name
		}
	}
	return ""
}

// is_executable_file stats the path and reports whether it is a regular
// file the platform can launch: with an execute bit (any class) on
// POSIX; on Windows by file-name extension — presence alone is not
// launchability there (has_launchable_extension, below).
is_executable_file :: proc(path: string) -> bool {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return false
	}
	is_dir := info.type == .Directory
	when ODIN_OS != .Windows {
		executable := .Execute_User in info.mode || .Execute_Group in info.mode || .Execute_Other in info.mode
		os.file_info_delete(info, context.temp_allocator)
		if is_dir {
			return false
		}
		return executable
	} else {
		os.file_info_delete(info, context.temp_allocator)
		if is_dir {
			return false
		}
		return has_launchable_extension(path)
	}
}

when ODIN_OS == .Windows {
	// has_launchable_extension reports whether the file name ends in an
	// extension CreateProcess can launch — .exe directly, .cmd/.bat
	// through the interpreter CreateProcess starts for them — compared
	// case-insensitively (Windows file names carry no case). An
	// extensionless regular file is never launchable: npm's global
	// installs drop an extensionless sh shim beside the real .cmd
	// launcher, and that shim is a shell script no Windows spawn can
	// run. Counting it as the executable makes the availability check
	// pass and moves the failure to spawn time, past the check that
	// exists to catch it.
	has_launchable_extension :: proc(path: string) -> bool {
		dot := strings.last_index_byte(path, '.')
		if dot < 0 {
			return false
		}
		ext := path[dot:]
		launchable := [3]string{".exe", ".cmd", ".bat"}
		for suffix in launchable {
			if strings.equal_fold(ext, suffix) {
				return true
			}
		}
		return false
	}
}

// look_path_with_fallbacks resolves name via PATH first, then by probing
// the given directories. The result is owned by `a`; "" when absent.
look_path_with_fallbacks :: proc(name: string, dirs: []string, a := context.allocator) -> string {
	if p := find_in_path(name, context.temp_allocator); p != "" {
		return strings.clone(p, a)
	}
	for dir in dirs {
		p := probe_in_dir(dir, name)
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

// dedupe_dirs removes duplicate entries while preserving order. The
// result (and its strings) is owned by `a`.
dedupe_dirs :: proc(dirs: []string, a := context.allocator) -> []string {
	out := make([dynamic]string, 0, len(dirs), a)
	seen := make(map[string]bool, len(dirs), a)
	defer delete(seen)
	for d in dirs {
		if d == "" || seen[d] {
			continue
		}
		seen[d] = true
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
	return binary_available("node")
}

// default_check_runtime verifies every RequiredBinaries entry and every
// RequiredAnyOf group. Failure messages carry the install hint and live
// on the caller's arena.
default_check_runtime :: proc(e: ^Entry, arena: mem.Allocator) -> platform.Err {
	for req in e.required_binaries {
		if !binary_available(req.name) {
			return not_installed_err(req.display_name, e.install_hint, arena)
		}
	}
	for req in e.required_any_of {
		if find_first_binary(req.names) == "" {
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
