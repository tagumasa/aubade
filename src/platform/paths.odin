// Filesystem layout under AUBADE_HOME
// ($AUBADE_HOME if absolute without '..' segments, otherwise $HOME/.aubade).
package platform

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:os"
import "core:path/filepath"
import "core:strings"

MANAGED_DIR_NAME :: ".aubade"

// aubade_home resolves the aubade home directory. The env lookups and
// joins are intra-procedure scratch on the temp allocator; the caller
// receives one string owned by `allocator` (the raw lookup results are
// never returned through it).
aubade_home :: proc(allocator := context.allocator) -> string {
	ta := context.temp_allocator
	dir, found := os.lookup_env_alloc("AUBADE_HOME", ta)
	if found && dir != "" {
		trimmed := strings.trim_space(dir)
		if filepath.is_abs(trimmed) && !has_dot_dot(trimmed) {
			clean, _ := filepath.clean(trimmed, ta)
			return strings.clone(clean, allocator)
		}
	}
	home, ok := os.lookup_env_alloc("HOME", ta)
	if !ok || home == "" {
		home, _ = os.user_home_dir(ta)
	}
	joined, _ := filepath.join([]string{home, MANAGED_DIR_NAME}, ta)
	return strings.clone(joined, allocator)
}

// forward_slash_view returns `path` with Windows backslashes turned into
// forward slashes, for separator-insensitive comparison against paths of
// the other spelling (decoded URIs use '/', Windows absolute paths arrive
// '\'); on the other platforms it is the input unchanged. The Windows
// result borrows temp memory — use it within the caller's scratch scope.
forward_slash_view :: proc(path: string) -> string {
	when ODIN_OS == .Windows {
		buf := make([dynamic]u8, 0, len(path), context.temp_allocator)
		for i in 0..<len(path) {
			c := path[i]
			if c == '\\' {
				c = '/'
			}
			append(&buf, c)
		}
		return string(buf[:])
	} else {
		return path
	}
}

// strip_root_prefix reports whether `abs_path` sits under `root` and
// returns the part after the root separator (original spelling, caller
// copies what it keeps). Lexical — no symlink resolution; callers needing
// the canonical spelling resolve first. The root compare carries the
// filesystem's case sensitivity (path_prefix_equal) and tolerates either
// separator on both spellings (Windows absolute paths arrive backslashed;
// a hand-built "root + \"/\"" prefix matches neither).
strip_root_prefix :: proc(abs_path: string, root: string) -> (rel: string, ok: bool) {
	if len(abs_path) <= len(root) {
		return "", false
	}
	if !path_prefix_equal(abs_path, root) {
		return "", false
	}
	sep := abs_path[len(root)]
	if sep != '/' && sep != '\\' {
		return "", false
	}
	return abs_path[len(root) + 1:], true
}

// case_insensitive_fs is the single home of the filesystem
// case-sensitivity switch: macOS and Windows filesystems fold path case
// (two spellings differing only in case denote one file), Linux
// filesystems are case-sensitive (distinct spellings are distinct
// files). Path identity — map keys, equality, dedup — carries this
// switch, never a bare ==.
case_insensitive_fs :: proc() -> bool {
	when ODIN_OS == .Darwin || ODIN_OS == .Windows {
		return true
	} else {
		return false
	}
}

// path_prefix_equal reports whether `path` begins with the `prefix`
// spelling, ignoring separator differences (both sides compared as
// forward-slash views) and carrying the filesystem's case sensitivity —
// the prefix sibling of path_equal, for callers that verify the boundary
// character themselves. The fold basis matches path_fold's, so the three
// can never disagree about whether one spelling prefixes another.
path_prefix_equal :: proc(path, prefix: string) -> bool {
	if len(prefix) > len(path) {
		return false
	}
	p_slash := forward_slash_view(path)
	f_slash := forward_slash_view(prefix)
	return path_equal(p_slash[:len(f_slash)], f_slash)
}

// path_equal compares two path spellings with the filesystem's case
// sensitivity: ASCII case-folded on macOS/Windows, exact elsewhere. The
// fold basis matches path_fold's, so the two can never disagree about
// whether two spellings name one path.
path_equal :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	if case_insensitive_fs() {
		for i in 0 ..< len(a) {
			ca, cb := a[i], b[i]
			if ca >= 'A' && ca <= 'Z' {
				ca += 'a' - 'A'
			}
			if cb >= 'A' && cb <= 'Z' {
				cb += 'a' - 'A'
			}
			if ca != cb {
				return false
			}
		}
		return true
	}
	return a == b
}

// path_fold returns the canonical key spelling for `path`: ASCII-case-
// folded, owned by `allocator`, on case-insensitive filesystems; the
// input unchanged (a view — long-lived maps clone it on insert) on
// case-sensitive ones. Folding is idempotent and length-preserving, so
// every spelling of one path folds to one key.
path_fold :: proc(path: string, allocator := context.allocator) -> string {
	when ODIN_OS == .Darwin || ODIN_OS == .Windows {
		scratch := make([dynamic]u8, len(path), context.temp_allocator)
		defer delete(scratch)
		for i in 0 ..< len(path) {
			c := path[i]
			if c >= 'A' && c <= 'Z' {
				c += 'a' - 'A'
			}
			scratch[i] = c
		}
		return strings.clone(string(scratch[:]), allocator)
	}
	return path
}

has_dot_dot :: proc(path: string) -> bool {
	// Both separators: Windows roots arrive with backslashes and must not
	// slip a `..\` past a '/'-only split.
	i := 0
	for i < len(path) {
		j := i
		for j < len(path) && path[j] != '/' && path[j] != '\\' {
			j += 1
		}
		if j - i == 2 && path[i] == '.' && path[i + 1] == '.' {
			return true
		}
		i = j + 1
	}
	return false
}

// normalize_project_root makes an absolute, cleaned project root (case is
// preserved; comparisons across case-insensitive filesystems must use
// equal-fold helpers, not ==). Intermediates run on the temp allocator so
// the failure paths cannot strand a half-normalized string on the caller's;
// only the accepted result is cloned out.
normalize_project_root :: proc(root: string, allocator := context.allocator) -> (string, bool) {
	clean, err := filepath.clean(root, context.temp_allocator)
	if err != nil {
		return "", false
	}
	if !filepath.is_abs(clean) {
		abs, aerr := filepath.abs(clean, context.temp_allocator)
		// abs returns "" (without an error) for input it cannot stat on
		// this nightly — an empty root must not leak to callers.
		if aerr != nil || len(abs) == 0 {
			return "", false
		}
		clean = abs
	}
	return strings.clone(clean, allocator), true
}

// project_id derives the stable daemon directory name for a project root:
// the first 16 hex chars of the SHA-256 of the normalized root. On
// case-insensitive filesystems (macOS, Windows) the root is ASCII-case-folded
// first so differently-cased spellings of one project share a daemon.
project_id :: proc(normalized_root: string, allocator := context.allocator) -> string {
	hash_bytes := transmute([]u8)normalized_root
	owned: []u8 = nil
	when ODIN_OS == .Darwin || ODIN_OS == .Windows {
		// No defer here: a defer inside the `when` binds to that block's
		// scope; the buffer must outlive the hashing below.
		owned = make([]u8, len(normalized_root), allocator)
		for i in 0..<len(normalized_root) {
			c := normalized_root[i]
			if c >= 'A' && c <= 'Z' {
				c = c + ('a' - 'A')
			}
			owned[i] = c
		}
		hash_bytes = owned
	}
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, hash_bytes)
	if owned != nil {
		delete(owned, allocator)
	}
	digest: [32]u8
	sha2.final(&ctx, digest[:])
	enc, _ := hex.encode(digest[:8], allocator)
	return string(enc)
}

// path_hash64 folds a path string to a 64-bit FNV-1a hash. Compact
// walk-side path sets (the crawl's seen-set) key on it so they never
// retain path strings: a 64-bit accidental collision across n distinct
// paths is ~n²/2⁶⁵ — it delays one vanished path's purge by a walk (the
// TTL sweep still reaps the rows) and never affects a live answer.
path_hash64 :: proc(path: string) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for i in 0..<len(path) {
		h = (h ~ cast(u64)(path[i])) * 0x100000001b3
	}
	return h
}

// daemon_dir is $AUBADE_HOME/daemon/<projectID>.
daemon_dir :: proc(home, id: string, allocator := context.allocator) -> string {
	joined, _ := filepath.join([]string{home, "daemon", id}, allocator)
	return joined
}

DAEMON_LOCK_NAME     :: "spawn.lock"    // singleton guard: OS file lock, never renamed, no payload
DAEMON_ENDPOINT_NAME :: "endpoint.json" // {pid, port, started_at, token}: discovery + auth

daemon_lock_path :: proc(dir: string, allocator := context.allocator) -> string {
	joined, _ := filepath.join([]string{dir, DAEMON_LOCK_NAME}, allocator)
	return joined
}

daemon_endpoint_path :: proc(dir: string, allocator := context.allocator) -> string {
	joined, _ := filepath.join([]string{dir, DAEMON_ENDPOINT_NAME}, allocator)
	return joined
}

// --- config files (JSONC — one format for every aubade-owned config file) ---

CONFIG_NAME           :: "config.jsonc"         // user-edited global config, never rewritten by aubade
PROJECTS_REGISTRY_NAME :: "projects.json"       // machine-owned project registry, freely rewritten
PROJECT_CONFIG_NAME   :: "project.jsonc"        // user-edited project config
PROJECT_LOCAL_NAME    :: "project.local.jsonc"  // user-owned local overlay, seeded once
CONTEXTS_DIR_NAME     :: "contexts"             // user-defined contexts (<name>.jsonc)
MODES_DIR_NAME        :: "modes"                // user-defined modes (<name>.jsonc)

config_path :: proc(home: string, allocator := context.allocator) -> string {
	joined, _ := filepath.join([]string{home, CONFIG_NAME}, allocator)
	return joined
}

projects_registry_path :: proc(home: string, allocator := context.allocator) -> string {
	joined, _ := filepath.join([]string{home, PROJECTS_REGISTRY_NAME}, allocator)
	return joined
}

contexts_dir :: proc(home: string, allocator := context.allocator) -> string {
	joined, _ := filepath.join([]string{home, CONTEXTS_DIR_NAME}, allocator)
	return joined
}

modes_dir :: proc(home: string, allocator := context.allocator) -> string {
	joined, _ := filepath.join([]string{home, MODES_DIR_NAME}, allocator)
	return joined
}

project_config_path :: proc(managed_dir: string, allocator := context.allocator) -> string {
	joined, _ := filepath.join([]string{managed_dir, PROJECT_CONFIG_NAME}, allocator)
	return joined
}

project_local_path :: proc(managed_dir: string, allocator := context.allocator) -> string {
	joined, _ := filepath.join([]string{managed_dir, PROJECT_LOCAL_NAME}, allocator)
	return joined
}

// --- memories layout (markdown memories under the managed/global trees) ---

MEMORIES_DIR_NAME :: "memories"
GLOBAL_MEMORIES_TOPIC :: "global"

// project_memories_dir is <managed_dir>/memories — the project-scoped
// memory root under the project's managed directory (whose location the
// config layer resolves from the global folder template).
project_memories_dir :: proc(managed_dir: string, allocator := context.allocator) -> string {
	joined, _ := filepath.join([]string{managed_dir, MEMORIES_DIR_NAME}, allocator)
	return joined
}

// global_memories_dir is $AUBADE_HOME/memories/global — the cross-project
// memory root (addressed through the "global/" name prefix).
global_memories_dir :: proc(home: string, allocator := context.allocator) -> string {
	joined, _ := filepath.join([]string{home, MEMORIES_DIR_NAME, GLOBAL_MEMORIES_TOPIC}, allocator)
	return joined
}
