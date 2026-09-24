// Executable-path resolution through PATH: the single home of the
// platform's launchability rules. Windows resolution must probe the
// executable extensions CreateProcess honors (.exe directly, .cmd/.bat
// through the interpreter it starts for them) because a bare name handed
// to a Windows spawn resolves .exe only — npm's global installs surface
// as .cmd shims and would otherwise read as absent. Consumers that make
// a decision on the answer (language-server runtime checks, client
// setup) fail closed on ""; pure construction never calls in here.
package platform

import "core:os"
import "core:path/filepath"
import "core:strings"

when ODIN_OS == .Windows {
	PATH_LIST_SEP :: ";"
} else {
	PATH_LIST_SEP :: ":"
}

// The file extensions CreateProcess can launch — .exe directly,
// .cmd/.bat through the interpreter CreateProcess starts for them.
// This is the one home of the rule: PATH probing (probe_in_dir) and
// the launchability check (has_launchable_extension) both read it, and
// no consumer re-spells the list.
LAUNCHABLE_SUFFIXES :: [3]string{".exe", ".cmd", ".bat"}

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
	exact, _ := filepath.join({dir, name}, context.temp_allocator)
	if is_executable_file(exact) {
		return exact
	}
	when ODIN_OS == .Windows {
		for suf in LAUNCHABLE_SUFFIXES {
			cand := strings.concatenate({name, suf}, context.temp_allocator)
			p, _ := filepath.join({dir, cand}, context.temp_allocator)
			if is_executable_file(p) {
				return p
			}
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
		for suffix in LAUNCHABLE_SUFFIXES {
			if strings.equal_fold(ext, suffix) {
				return true
			}
		}
		return false
	}
}
