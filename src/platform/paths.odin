// Filesystem layout under AUBADE_HOME
// ($AUBADE_HOME if absolute without '..' segments, otherwise $HOME/.aubade).
package platform

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "src:util"

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

// user_home resolves the canonical user home directory, owned by
// `allocator`; "" when every source declines. Windows prefers the
// Profile known folder over $HOME — an inherited $HOME there is often
// an MSYS/Git-Bash POSIX spelling that names nothing on the native
// filesystem — while the other platforms read $HOME first and fall
// back to the OS lookup ($AUBADE_HOME does not redirect any of this).
user_home :: proc(allocator := context.allocator) -> string {
	ta := context.temp_allocator
	home := ""
	when ODIN_OS == .Windows {
		home, _ = os.user_home_dir(ta)
		if home == "" {
			if v, ok := os.lookup_env_alloc("HOME", ta); ok && v != "" {
				home = v
			}
		}
	} else {
		if v, ok := os.lookup_env_alloc("HOME", ta); ok && v != "" {
			home = v
		}
		if home == "" {
			home, _ = os.user_home_dir(ta)
		}
	}
	if home == "" {
		return ""
	}
	clean, _ := filepath.clean(home, ta)
	return strings.clone(clean, allocator)
}

// user_homes collects every spelling the user's home directory can
// carry for the project-root refusal: the canonical user_home plus, on
// Windows, $HOME itself — the canonical Profile spelling and an env
// spelling (a redirected home in test and embedded environments) name
// the same directory through different sources, and a root matching
// either must be refused. The returned slice and every entry are owned
// by `allocator`: free each entry and the slice with that allocator
// (request arenas free_all instead).
user_homes :: proc(allocator := context.allocator) -> []string {
	homes := make([dynamic]string, 0, 2, allocator)
	collect :: proc(homes: ^[dynamic]string, allocator: mem.Allocator, spelling: string) {
		if spelling == "" {
			return
		}
		for h in homes^ {
			if path_equal_any_sep(h, spelling) {
				return
			}
		}
		append(homes, strings.clone(spelling, allocator))
	}
	canonical := user_home(allocator)
	if canonical != "" {
		collect(&homes, allocator, canonical)
		delete(canonical, allocator)
	}
	when ODIN_OS == .Windows {
		if v, ok := os.lookup_env_alloc("HOME", context.temp_allocator); ok {
			collect(&homes, allocator, v)
		}
	}
	out := make([]string, len(homes), allocator)
	copy(out, homes[:])
	delete(homes)
	return out
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

// path_equal_any_sep is path_equal with separator normalization: both
// spellings compare as forward-slash views, so "C:/Users/x" and
// "C:\Users\x" name one path. The fold basis matches path_fold's, so
// the family can never disagree about path identity.
path_equal_any_sep :: proc(a, b: string) -> bool {
	return path_equal(forward_slash_view(a), forward_slash_view(b))
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

// windows_path_is_root reports whether a Windows path spelling names a
// filesystem root: a current-drive root ("/", "\", "///"), a drive root
// ("C:\", "c:/", or the drive-relative "C:"), a UNC share root
// ("\\server\share"), or a verbatim/device form of any of these
// ("\\?\C:\", "\\?\UNC\server\share", "\\.\PhysicalDrive0"). Lexical —
// both separators are accepted, no filesystem is touched — so it stays
// a shared declaration and the suite verifies Windows spellings on
// every platform. It must run on the raw spelling: on Windows,
// filepath.clean("/") collapses to "." (a bare separator is not a
// rooted start there), and a cleaned root is no longer recognizable.
windows_path_is_root :: proc(path: string) -> bool {
	is_sep :: proc(c: u8) -> bool {
		return c == '/' || c == '\\'
	}
	rest_is_seps :: proc(s: string) -> bool {
		for i in 0..<len(s) {
			if !is_sep(s[i]) {
				return false
			}
		}
		return true
	}
	// host_share_is_root answers for the "host<sep>share" body of a UNC
	// spelling: a share name present, then nothing but separators.
	host_share_is_root :: proc(s: string) -> bool {
		if len(s) == 0 {
			return false
		}
		i := 0
		for i < len(s) && !is_sep(s[i]) {
			i += 1
		}
		if i == len(s) {
			return false
		}
		j := i + 1
		for j < len(s) && !is_sep(s[j]) {
			j += 1
		}
		return j > i+1 && rest_is_seps(s[j:])
	}
	p := path
	if len(p) == 0 {
		return false
	}
	// Verbatim prefixes: `\\?\C:\` reduces to its plain spelling,
	// `\\?\UNC\host\share` to the UNC body; the device namespace
	// `\\.\name` is one component whose volume is the whole string.
	if len(p) >= 4 && is_sep(p[0]) && is_sep(p[1]) && p[2] == '?' && is_sep(p[3]) {
		if len(p) >= 8 && p[4] == 'U' && p[5] == 'N' && p[6] == 'C' && is_sep(p[7]) {
			return host_share_is_root(p[8:])
		}
		p = p[4:]
	} else if len(p) >= 4 && is_sep(p[0]) && is_sep(p[1]) && p[2] == '.' && is_sep(p[3]) {
		return !strings.contains_any(p[4:], "/\\")
	}
	// Drive root, drive-relative included: volume letter plus nothing
	// or separators.
	if len(p) >= 2 && p[1] == ':' {
		c := p[0]
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') {
			return rest_is_seps(p[2:])
		}
	}
	// UNC share root: host and share after the leading pair.
	if len(p) >= 3 && is_sep(p[0]) && is_sep(p[1]) && !is_sep(p[2]) {
		return host_share_is_root(p[2:])
	}
	// Current-drive root: separators and nothing else.
	return rest_is_seps(p)
}

// project_root_refused is the single rule for project roots aubade never
// accepts: the user's home directory and a filesystem root — a daemon over
// either indexes and snapshots every file below it. `root` may be the raw
// or a resolved spelling (the Windows filesystem-root test reads the raw
// form — see windows_path_is_root); `homes` is user_homes' candidate list
// (empty leaves only the filesystem-root test active). The second return
// is display text for the caller's error line.
project_root_refused :: proc(root: string, homes: []string) -> (bool, string) {
	for home in homes {
		if home != "" && path_equal_any_sep(root, home) {
			return true, "it is the user's home directory"
		}
	}
	when ODIN_OS == .Windows {
		if windows_path_is_root(root) {
			return true, "it is a filesystem root"
		}
	} else {
		parent := filepath.dir(root)
		if parent == root {
			return true, "it is a filesystem root"
		}
	}
	return false, ""
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

// path_hash64 folds a path string to a 64-bit fingerprint
// (util.hash64_words). Compact walk-side path sets (the crawl's seen-set)
// key on it so they never retain path strings: a 64-bit accidental
// collision across n distinct paths is ~n²/2⁶⁵ — it
// delays one vanished path's purge by a walk (the TTL sweep still reaps
// the rows) and never affects a live answer.
path_hash64 :: proc(path: string) -> u64 {
	return util.hash64_words(path, util.HASH64_FNV_OFFSET)
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
