// Env scrubbing: keep only environment variables whose names match an
// allowed entry — a trailing-underscore entry is a prefix, any other
// entry is an exact name — and whose values pass per-variable
// validation (null-byte rejection, path traversal rejection for
// path-like keys, URL-scheme enforcement, length capping).
package safety

import "core:mem"
import "core:path/filepath"
import "core:strings"
import "core:sync"

DEFAULT_ALLOWED_ENV_KEYS :: []string{
	"HOME",
	"PATH",
	"USER",
	"LANG",
	"LANGUAGE",
	"LC_",
	"TERM",
	"SHELL",
	"EDITOR",
	"PAGER",
	"GOPATH",
	"GOROOT",
	"GOBIN",
	"NODE_PATH",
	"PYTHONPATH",
	"JAVA_HOME",
	"CARGO_HOME",
	"RUSTUP_HOME",
	"XDG_",
	"TMPDIR",
	"TMP",
	"TEMP",
	"LOGNAME",
	"HOSTNAME",
	"LESS",
	"GOPROXY",
	"GOMODCACHE",
	"NPM_CONFIG_PREFIX",
	"VIRTUAL_ENV",
	"CONDA_",
	"AUBADE_",
	"GIT_",
	// Windows system variables: children spawned through the scrubbed
	// environment (the shell tool's cmd.exe and the tools it launches)
	// need SystemRoot and ComSpec to run at all, and the per-user data
	// roots are where Windows CLI tools keep their state. The account
	// identity and home spellings were previously admitted only through
	// the USER/HOME prefix over-match; they are named now that bare
	// entries match exactly. Inert on unix — those names do not exist
	// there.
	"SystemRoot",
	"WINDIR",
	"ComSpec",
	"OS",
	"PATHEXT",
	"APPDATA",
	"LOCALAPPDATA",
	"PROGRAMDATA",
	"ALLUSERSPROFILE",
	"PUBLIC",
	"USERNAME",
	"USERPROFILE",
	"HOMEDRIVE",
	"HOMEPATH",
	"PROCESSOR_",
	"NUMBER_OF_PROCESSORS",
}

SECRET_SUBSTRINGS :: []string{
	"KEY",
	"TOKEN",
	"SECRET",
	"PASSWORD",
	"CREDENTIAL",
	"PASSWD",
	"AUTH",
}

PATH_LIKE_KEYS :: []string{
	"PATH",
	"PYTHONPATH",
	"NODE_PATH",
	"GOPATH",
	"GOROOT",
	"GOBIN",
	"CARGO_HOME",
	"RUSTUP_HOME",
	"GOMODCACHE",
	"NPM_CONFIG_PREFIX",
	"VIRTUAL_ENV",
	"TMPDIR",
	"TMP",
	"TEMP",
	"JAVA_HOME",
	"HOME",
	"XDG_CONFIG_HOME",
	// Windows single-path variables: they take the same ".."-segment
	// rejection as the unix path set above.
	"SystemRoot",
	"WINDIR",
	"ComSpec",
	"APPDATA",
	"LOCALAPPDATA",
	"PROGRAMDATA",
	"ALLUSERSPROFILE",
	"PUBLIC",
}

MAX_ENV_VALUE_LEN :: 8192

// Env_Guard is a value member of Safety_Checker (like the deny list and
// the other guards): init/destroy in place, no heap indirection — the
// allowed list carries its own allocator, so there is nothing else to
// free and no teardown-time allocator question at all.
Env_Guard :: struct {
	mu:      sync.RW_Mutex,
	allowed: [dynamic]string,
}

envguard_init :: proc(g: ^Env_Guard, allowed: []string = DEFAULT_ALLOWED_ENV_KEYS, a := context.allocator) {
	g^ = {}
	g.allowed = make([dynamic]string, 0, len(allowed), a)
	for p in allowed {
		append(&g.allowed, p)
	}
}

envguard_destroy :: proc(g: ^Env_Guard) {
	delete(g.allowed)
	g^ = {}
}

// envguard_add_allowed borrows `entry`: the guard stores the string
// without cloning, and envguard_destroy frees only the list — the caller
// owns the lifetimes of every entry it adds. The entry follows the
// allow-list rule: ending in "_" makes it a prefix, anything else is an
// exact name.
envguard_add_allowed :: proc(g: ^Env_Guard, entry: string) {
	sync.lock(&g.mu)
	defer sync.unlock(&g.mu)
	append(&g.allowed, entry)
}

// envguard_scrub keeps only entries whose keys match the guard's allow
// entries (envguard_add_allowed takes effect) and whose values pass
// validation. The guard lock spans the loop — nothing in it re-enters the
// guard, and a snapshot-then-unlock would leave the slice view dangling
// across a concurrent append.
envguard_scrub :: proc(g: ^Env_Guard, env: []string, a: mem.Allocator) -> []string {
	result := make([dynamic]string, 0, len(env), a)
	sync.lock(&g.mu)
	defer sync.unlock(&g.mu)
	for entry in env {
		eq := strings.index(entry, "=")
		if eq < 0 {
			continue
		}
		key := entry[:eq]
		value := entry[eq + 1:]

		if !key_allowed(key, g.allowed[:]) {
			continue
		}
		if key_contains_secret(key) {
			continue
		}
		cleaned, ok := validate_env_value(key, value)
		if !ok {
			continue
		}
		append(&result, strings.concatenate({key, "=", cleaned}, a))
	}
	return result[:]
}

// key_allowed and key_contains_secret compare case-insensitively against
// the entry/substring tables so we don't need to allocate an upper-cased
// copy of the key on every entry. An allow entry ending in "_" is a
// prefix (LC_, GIT_, PROCESSOR_); every other entry is an exact name
// (HOME, SystemRoot) — the trailing underscore is the declared intent,
// so a bare name never admits names it merely prefixes. The
// secret-substring screen is a second gate, not the thing that keeps an
// over-broad entry safe.
key_allowed :: proc(key: string, entries: []string) -> bool {
	for entry in entries {
		if ci_has_suffix(entry, "_") {
			if ci_has_prefix(key, entry) {
				return true
			}
		} else if ci_equal(key, entry) {
			return true
		}
	}
	return false
}

key_contains_secret :: proc(key: string) -> bool {
	for sub in SECRET_SUBSTRINGS {
		if ci_contains(key, sub) {
			return true
		}
	}
	return false
}

// ci_has_prefix reports whether s starts with prefix using ASCII case-fold
// comparison: 'a' equals 'A', non-ASCII bytes compare equal to themselves.
ci_has_prefix :: proc(s, prefix: string) -> bool {
	if len(prefix) > len(s) {
		return false
	}
	for i in 0 ..< len(prefix) {
		as := s[i]
		ap := prefix[i]
		if as >= 'a' && as <= 'z' { as -= 32 }
		if ap >= 'a' && ap <= 'z' { ap -= 32 }
		if as != ap {
			return false
		}
	}
	return true
}

// ci_has_suffix is ci_has_prefix from the other end: s ends with suffix
// under ASCII case-fold comparison.
ci_has_suffix :: proc(s, suffix: string) -> bool {
	if len(suffix) > len(s) {
		return false
	}
	off := len(s) - len(suffix)
	for i in 0 ..< len(suffix) {
		as := s[off + i]
		af := suffix[i]
		if as >= 'a' && as <= 'z' { as -= 32 }
		if af >= 'a' && af <= 'z' { af -= 32 }
		if as != af {
			return false
		}
	}
	return true
}

ci_contains :: proc(s, sub: string) -> bool {
	if len(sub) == 0 {
		return true
	}
	if len(sub) > len(s) {
		return false
	}
	for start in 0 ..= len(s) - len(sub) {
		match := true
		for i in 0 ..< len(sub) {
			bs := s[start + i]
			bp := sub[i]
			if bs >= 'a' && bs <= 'z' { bs -= 32 }
			if bp >= 'a' && bp <= 'z' { bp -= 32 }
			if bs != bp {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

is_path_like_key :: proc(key: string) -> bool {
	for k in PATH_LIKE_KEYS {
		if ci_equal(key, k) {
			return true
		}
	}
	return false
}

// ci_equal compares two ASCII strings ignoring case.
ci_equal :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		ba := a[i]
		bb := b[i]
		if ba >= 'a' && ba <= 'z' { ba -= 32 }
		if bb >= 'a' && bb <= 'z' { bb -= 32 }
		if ba != bb {
			return false
		}
	}
	return true
}

validate_env_value :: proc(key, value_in: string) -> (string, bool) {
	value := value_in
	// Env var values cannot carry nulls: downstream C APIs read them as
	// NUL-terminated and would truncate at the embedded byte, so the entry
	// is rejected outright.
	if strings.contains_rune(value, 0) {
		return "", false
	}
	// The caps hand back views of the input — the scrub callers concatenate
	// the cleaned value into their own owned entry strings immediately, so
	// no truncation allocation is needed (and the GIT_ cap narrows the
	// capped view rather than allocating a second time).
	if len(value) > MAX_ENV_VALUE_LEN {
		value = value[:MAX_ENV_VALUE_LEN]
	}

	if is_path_like_key(key) {
		parts, serr := filepath.split_list(value, context.temp_allocator)
		if serr != nil {
			return "", false // fail closed: an uncheckable path-like value is rejected
		}
		for part in parts {
			if strings.contains(part, "..") {
				return "", false
			}
		}
	}

	if ci_equal(key, "GOPROXY") {
		if !ci_equal(value, "OFF") && !ci_equal(value, "DIRECT") {
			if !strings.has_prefix(value, "https://") &&
			   !strings.has_prefix(value, "http://") {
				return "", false
			}
		}
	}

	if ci_has_prefix(key, "GIT_") && len(value) > 1024 {
		value = value[:1024]
	}

	return value, true
}
