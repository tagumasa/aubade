// Sensitive-path deny list and read/write gates: glob deny patterns
// (**/.env, *.pem, ...), write-denied
// exact paths and directory prefixes (shell rc files, ~/.ssh, the aubade
// home), read-ask heuristics (credential-like basenames, sensitive
// directories), and sensitive system locations. All matching happens on
// slash-normalized, percent-decoded, symlink-resolved paths. The write gate
// is advisory (TOCTOU at check time); containment is validated separately.
package safety

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "src:platform"
import "src:regex"
import "src:util"

// deny_path_eq / deny_path_prefix compare write-denied paths with the
// filesystem's case sensitivity: case-insensitive on macOS/Windows (a
// case-varied spelling of a denied path must not bypass the gate),
// exact on case-sensitive systems (distinct paths there are distinct files).
deny_path_eq :: proc(a, b: string) -> bool {
	if platform.case_insensitive_fs() {
		return ci_equal(a, b)
	}
	return a == b
}

deny_path_prefix :: proc(s, prefix: string) -> bool {
	if platform.case_insensitive_fs() {
		return ci_has_prefix(s, prefix)
	}
	return strings.has_prefix(s, prefix)
}

// deny_path_suffix reports whether s ends with suffix, carrying the
// filesystem's case sensitivity like its exact/prefix siblings.
deny_path_suffix :: proc(s, suffix: string) -> bool {
	if platform.case_insensitive_fs() {
		return ci_has_suffix(s, suffix)
	}
	return strings.has_suffix(s, suffix)
}

// deny_path_contains reports whether s contains sub (a whole-segment
// pattern like "/.ssh/"), carrying the filesystem's case sensitivity.
deny_path_contains :: proc(s, sub: string) -> bool {
	if platform.case_insensitive_fs() {
		return ci_contains(s, sub)
	}
	return strings.contains(s, sub)
}

// normalise_for_matching percent-decodes the path. NFC normalization
// before matching would be a no-op here — the deny patterns are ASCII —
// so the decode is the only normalisation applied.
normalise_for_matching :: proc(path: string, a := context.allocator) -> string {
	return util.percent_decode(path, a)
}

DEFAULT_DENY_PATTERNS :: []string{
	"**/.env",
	"**/.env.*",
	"**/.envrc",
	"**/.envrc.*",
	// The name-loose families (token/secret/credentials) deny only
	// credential-container shapes: hidden dotfiles, extensionless files,
	// and the data extensions (csv/json/txt/yaml/yml). Bare prefix/infix
	// forms ("**/token*", "**/*secret*", "**/*credentials*") would deny
	// any source file whose basename merely begins with or contains the
	// word — tokenizer.odin, secrets.go, credentials.go — and the deny
	// list admits no per-project override, so the shapes stay narrow.
	"**/.credentials*",
	"**/credentials",
	"**/*credentials*.csv",
	"**/*credentials*.json",
	"**/*credentials*.txt",
	"**/*credentials*.yaml",
	"**/*credentials*.yml",
	"**/.secret*",
	"**/secret",
	"**/secrets",
	"**/*secret*.csv",
	"**/*secret*.json",
	"**/*secret*.txt",
	"**/*secret*.yaml",
	"**/*secret*.yml",
	"**/.token*",
	"**/token",
	"**/token*.csv",
	"**/token*.json",
	"**/token*.txt",
	"**/token*.yaml",
	"**/token*.yml",
	"**/tokens",
	"**/*.pem",
	"**/*.pem.*",
	"**/*.key",
	"**/id_rsa*",
	"**/id_ed25519*",
	"**/ssh/config",
	"**/.aws/credentials",
	"**/.aws/config",
	"**/.gnupg/**",
	"**/.kube/config",
	"**/.npmrc",
	"**/.pypirc",
	"**/NTUSER.DAT",
	"**/NTUSER.DAT.*",
}

DEFAULT_READ_ASK_PATTERNS :: []string{
	"*.env",
	"*.env.*",
	"*.env.local",
	"*.envrc",
	"*.envrc.*",
	"*.key",
	"*.pem",
	"*.pem.*",
	"*.p12",
	"*.pfx",
	"*.jks",
	"*.secret",
	"*.ppk",
	"*.credentials",
	"credentials.json",
	"credentials*.json",
	"service-account*.json",
	"*.service-account.json",
	"serviceAccountKey.json",
	"id_rsa*",
	"id_ed25519*",
	"id_ecdsa*",
	"id_dsa*",
	"NTUSER.DAT",
	"NTUSER.DAT.*",
}

SENSITIVE_READ_ASK_DIRS :: []string{
	".ssh",
	".aws",
	".gnupg",
	".kube",
	".docker",
	".azure",
	".config/gh",
	".config/hub",
	".gnupg/private-keys-v1.d",
}

SENSITIVE_SYSTEM_PREFIXES :: []string{
	"/etc/",
	"/boot/",
	"/usr/lib/systemd/",
}

SENSITIVE_SYSTEM_EXACT :: []string{
	"/var/run/docker.sock",
	"/run/docker.sock",
}

// Windows-only sensitive locations, joined under SystemRoot at check time
// (the constant tables above are the cross-platform set).
WIN_SENSITIVE_SYSTEM_RELPATHS :: []string{
	"System32\\config",
	"System32\\drivers\\etc",
}

// Deny_List holds compiled deny patterns. Safe for concurrent reads; adds
// take the lock.
Deny_List :: struct {
	mu:        sync.Mutex,
	patterns:  [dynamic]regex.Regex,
	raw:       [dynamic]string,
	allocator: mem.Allocator,
}

denylist_init :: proc(d: ^Deny_List, a := context.allocator) {
	d.patterns = make([dynamic]regex.Regex, 0, len(DEFAULT_DENY_PATTERNS), a)
	d.raw = make([dynamic]string, 0, len(DEFAULT_DENY_PATTERNS), a)
	d.allocator = a
	for p in DEFAULT_DENY_PATTERNS {
		denylist_add_pattern(d, p)
	}
}

denylist_destroy :: proc(d: ^Deny_List) {
	for re in d.patterns {
		r := re
		regex.regex_destroy(&r)
	}
	for s in d.raw {
		delete(s, d.allocator)
	}
	delete(d.patterns)
	delete(d.raw)
	d.patterns = nil
	d.raw = nil
}

denylist_add_pattern :: proc(d: ^Deny_List, pattern: string) -> platform.Err {
	for r in d.raw {
		if r == pattern {
			return nil
		}
	}
	// The deny grammar is the shared glob translator's (*, **, ?, [seq],
	// {braces}); anchoring both ends and case folding are this gate's
	// concern. Backslash separators normalize to '/' first — glob_to_regex
	// reads '\' as an escape, the deny gate reads it as a separator.
	slash, slash_fresh := strings.replace_all(pattern, "\\", "/", context.temp_allocator)
	unanchored := regex.glob_to_regex(slash, context.temp_allocator)
	regex_str := strings.concatenate({"^", unanchored, "$"}, context.temp_allocator)
	delete(unanchored, context.temp_allocator)
	if slash_fresh {
		delete(slash, context.temp_allocator)
	}
	// Case-insensitive filesystems match deny globs across case variants:
	// **/.env must also catch .ENV.
	if platform.case_insensitive_fs() {
		wrapped := strings.concatenate({"(?i)", regex_str}, context.temp_allocator)
		delete(regex_str, context.temp_allocator)
		regex_str = wrapped
	}
	// The list owns the compiled regex for its whole lifetime: it must
	// ride the list's allocator, never the ambient temp (a temp-backed
	// pattern dangles after the caller's scratch reset).
	re, err := regex.compile_regex(regex_str, d.allocator)
	if err != nil {
		return platform.Wrapped{
			kind = .Invalid,
			msg  = strings.concatenate({"invalid deny-list pattern: ", pattern}, context.temp_allocator),
		}
	}
	sync.mutex_lock(&d.mu)
	append(&d.patterns, re)
	append(&d.raw, strings.clone(pattern, d.allocator))
	sync.mutex_unlock(&d.mu)
	return nil
}

// is_denied reports whether the path matches any deny pattern, after
// percent-decoding, cleaning, and symlink resolution. The resolution
// carries no anchor prefix: deny matching canonicalizes, it does not
// contain — an anchored resolver would treat every Windows hop as an
// escape (a drive-letter target is never under "/") and hand matching
// back the un-resolved spelling, where a junction that spells around a
// denied location slips through.
is_denied :: proc(d: ^Deny_List, path: string) -> bool {
	normalised := normalise_for_matching(path, context.temp_allocator)
	cleaned, clean_err := filepath.clean(normalised, context.temp_allocator)
	if clean_err != nil {
		return true // fail closed: the deny decision must not guess
	}
	resolved, status := pathguard_resolve_symlinks(cleaned, "", context.temp_allocator)
	target := cleaned
	if status == .Resolved || status == .Missing {
		target = resolved
	}
	return deny_match_target(d, target)
}

// deny_match_target runs the deny patterns against a path spelling the
// caller has established — the resolution output of is_denied, or a
// walk-composed resolved path (see Deny_Walk). The backslash fold and the
// fail-closed guard are is_denied's matching tail, shared so both entry
// points cannot drift apart.
deny_match_target :: proc(d: ^Deny_List, target: string) -> bool {
	// replace_all has no error channel: an allocation failure collapses the
	// result to "" while the target is non-empty — deny rather than match
	// patterns against nothing.
	slash, _ := strings.replace_all(target, "\\", "/", context.temp_allocator)
	if len(slash) == 0 && len(target) > 0 {
		return true // fail closed: a path we cannot normalize must not pass
	}

	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	for re in d.patterns {
		r := re
		if regex.regex_match(&r, slash) {
			return true
		}
	}
	return false
}

// Deny_Walk carries one directory's resolved spelling through a filesystem
// walk so walk-side deny checks compose instead of re-resolving every
// entry's full path from the root (once measured at ~14 readlink plus a
// matching lstat per file per walk — the walk's dominant syscall cost).
// An entry readdir reported as a real directory or regular file under a
// .Resolved directory resolves to resolved/name by construction: the entry
// itself is not a symlink, and the chain above it is already canonical —
// byte-identical to what is_denied's anchorless resolution would return.
// The state is resolved once per walk root; an unresolvable root (looping
// chains) leaves resolved_ok false and every check falls back to the full
// is_denied — the deny decision never weakens. Two accepted divergences,
// both documented: a name containing '%' falls back (percent-decoding is
// is_denied's input normalizer, and composing through such a name is not
// byte-parity with decode-then-resolve), and the resolved spelling can go
// stale behind a mid-walk swap of an ancestor directory — the same
// readdir-to-check window already existed, and the next walk re-resolves
// the root.
Deny_Walk :: struct {
	resolved:    string, // resolved spelling of the directory this state describes
	resolved_ok: bool, // resolution reached .Resolved — composing applies
	allocator:   mem.Allocator, // owns the resolved clones handed to child states
}

deny_walk_init :: proc(dw: ^Deny_Walk, root_abs: string, a: mem.Allocator) {
	dw^.allocator = a
	// Root walks anchor at "/" (prefix "") exactly like is_denied's
	// resolution; the result is cloned into `a` by the resolver itself.
	resolved, status := pathguard_resolve_symlinks(root_abs, "", a)
	if status == .Resolved {
		dw^.resolved = resolved
		dw^.resolved_ok = true
	} else {
		dw^.resolved = strings.clone(root_abs, a)
		dw^.resolved_ok = false
	}
}

// deny_walk_entry deny-checks one enumerated directory entry: `name` is
// the entry's base name and `entry_abs` its unresolved spelling (the
// fallback's input). Directory entries pass a `child` to receive the
// child's walk state for the recursion; file entries pass nil. A child
// under a non-composable state inherits resolved_ok=false, so the whole
// subtree keeps using the full resolution.
deny_walk_entry :: proc(dw: ^Deny_Walk, d: ^Deny_List, entry_abs, name: string, child: ^Deny_Walk) -> (denied: bool) {
	if !dw.resolved_ok || strings.contains(name, "%") {
		if child != nil {
			child^.resolved = ""
			child^.resolved_ok = false
			child^.allocator = dw.allocator
		}
		return is_denied(d, entry_abs)
	}
	sep := "/"
	if dw.resolved == "/" {
		sep = ""
	}
	composed := strings.concatenate({dw.resolved, sep, name}, context.temp_allocator)
	if child != nil {
		child^.resolved = strings.clone(composed, dw.allocator)
		child^.resolved_ok = true
		child^.allocator = dw.allocator
	}
	return deny_match_target(d, composed)
}

// --- write gate ---------------------------------------------------------------

// Write_Denied_Tables holds the exact paths, directory prefixes, and path
// suffixes that must never be written. The exact/prefix tables are built
// from the user's home directory; when no home resolves (a stripped
// environment), the suffix table keeps the same secrets denied by their
// home-relative spelling — under any directory, because for a write gate
// over-denying is the safe direction. Every entry is an owned clone —
// constants included — so destroy frees them uniformly.
Write_Denied_Tables :: struct {
	exact:     [dynamic]string,
	prefix:    [dynamic]string,
	suffix:    [dynamic]string,
	allocator: mem.Allocator,
}

write_denied_init :: proc(t: ^Write_Denied_Tables, a := context.allocator) {
	t.exact = make([dynamic]string, 0, 18, a)
	t.prefix = make([dynamic]string, 0, 12, a)
	t.suffix = make([dynamic]string, 0, 20, a)
	t.allocator = a
	write_denied_clone_add(&t.exact, "/etc/sudoers", a)
	write_denied_clone_add(&t.exact, "/etc/passwd", a)
	write_denied_clone_add(&t.exact, "/etc/shadow", a)
	write_denied_clone_add(&t.prefix, "/etc/sudoers.d/", a)
	write_denied_clone_add(&t.prefix, "/etc/ssh/", a)
	write_denied_clone_add(&t.prefix, "/etc/pam.d/", a)
	write_denied_clone_add(&t.prefix, "/etc/systemd/", a)

	home, found := os.lookup_env_alloc("HOME", a)
	if found && home == "" {
		// An empty-valued HOME is still an owned clone; release it before
		// the fallback lookup overwrites the binding.
		delete(home, a)
		home, found = os.lookup_env_alloc("USERPROFILE", a)
	}
	if !found || home == "" {
		if found {
			delete(home, a)
		}
		write_denied_load_suffix_fallback(t, a)
		return
	}
	join := write_denied_join
	write_denied_add(&t.exact, join({home, ".ssh", "authorized_keys"}, a))
	write_denied_add(&t.exact, join({home, ".ssh", "id_rsa"}, a))
	write_denied_add(&t.exact, join({home, ".ssh", "id_ed25519"}, a))
	write_denied_add(&t.exact, join({home, ".ssh", "config"}, a))
	write_denied_add(&t.exact, join({home, ".bashrc"}, a))
	write_denied_add(&t.exact, join({home, ".bash_profile"}, a))
	write_denied_add(&t.exact, join({home, ".profile"}, a))
	write_denied_add(&t.exact, join({home, ".zshrc"}, a))
	write_denied_add(&t.exact, join({home, ".zprofile"}, a))
	write_denied_add(&t.exact, join({home, ".gitconfig"}, a))
	write_denied_add(&t.exact, join({home, ".config", "git", "config"}, a))
	write_denied_add(&t.exact, join({home, ".netrc"}, a))
	write_denied_add(&t.exact, join({home, ".pgpass"}, a))
	write_denied_add(&t.exact, join({home, ".npmrc"}, a))
	write_denied_add(&t.exact, join({home, ".pypirc"}, a))
	managed := join({home, platform.MANAGED_DIR_NAME}, a)
	write_denied_add(&t.exact, join({managed, "auth.yml"}, a))
	write_denied_add(&t.exact, join({managed, ".env"}, a))

	write_denied_add_prefix(&t.prefix, {home, ".ssh"}, a)
	write_denied_add_prefix(&t.prefix, {home, ".aws"}, a)
	write_denied_add_prefix(&t.prefix, {home, ".gnupg"}, a)
	write_denied_add_prefix(&t.prefix, {home, ".kube"}, a)
	write_denied_add_prefix(&t.prefix, {home, ".docker"}, a)
	write_denied_add_prefix(&t.prefix, {home, ".azure"}, a)
	write_denied_add_prefix(&t.prefix, {home, ".config", "gh"}, a)
	write_denied_add_prefix(&t.prefix, {home, ".config", "hub"}, a)
	write_denied_add_prefix(&t.prefix, {managed}, a)

	when ODIN_OS == .Windows {
		// DPAPI key material and the credential store.
		write_denied_add_prefix(&t.prefix, {home, "AppData", "Roaming", "Microsoft", "Protect"}, a)
		write_denied_add_prefix(&t.prefix, {home, "AppData", "Local", "Microsoft", "Credentials"}, a)
	}

	// The home path and the managed prefix only fed the joins above; every
	// entry copied what it needs.
	delete(managed, a)
	delete(home, a)
}

// write_denied_load_suffix_fallback denies the home-relative secrets by
// their spelling alone. It runs only when no home directory resolves: a
// stripped environment must not turn ~/.ssh/authorized_keys, id_rsa, the
// cloud credential directories, and the rest into writable paths. The
// rules are suffix matches, so they deny those names under ANY directory —
// over-denying (say, a project-local .ssh fixture) is the safe direction
// for a write gate, and the normal home-resolved path never loads these.
write_denied_load_suffix_fallback :: proc(t: ^Write_Denied_Tables, a: mem.Allocator) {
	// Credential dotfiles whose home-relative spelling is the secret.
	write_denied_clone_add(&t.suffix, ".bashrc", a)
	write_denied_clone_add(&t.suffix, ".bash_profile", a)
	write_denied_clone_add(&t.suffix, ".profile", a)
	write_denied_clone_add(&t.suffix, ".zshrc", a)
	write_denied_clone_add(&t.suffix, ".zprofile", a)
	write_denied_clone_add(&t.suffix, ".gitconfig", a)
	write_denied_clone_add(&t.suffix, ".config/git/config", a)
	write_denied_clone_add(&t.suffix, ".netrc", a)
	write_denied_clone_add(&t.suffix, ".pgpass", a)
	write_denied_clone_add(&t.suffix, ".npmrc", a)
	write_denied_clone_add(&t.suffix, ".pypirc", a)
	// Secret directories (covers the ssh keys and the default-named
	// managed files; a relocated project state directory is denied by the
	// location rule the daemon adds to its tables).
	write_denied_clone_add(&t.suffix, ".ssh/", a)
	write_denied_clone_add(&t.suffix, ".aws/", a)
	write_denied_clone_add(&t.suffix, ".gnupg/", a)
	write_denied_clone_add(&t.suffix, ".kube/", a)
	write_denied_clone_add(&t.suffix, ".docker/", a)
	write_denied_clone_add(&t.suffix, ".azure/", a)
	write_denied_clone_add(&t.suffix, ".config/gh/", a)
	write_denied_clone_add(&t.suffix, ".config/hub/", a)
	write_denied_clone_add(&t.suffix, strings.concatenate({platform.MANAGED_DIR_NAME, "/"}, context.temp_allocator), a)
	when ODIN_OS == .Windows {
		// DPAPI key material and the credential store, home-relative form.
		write_denied_clone_add(&t.suffix, "AppData/Roaming/Microsoft/Protect/", a)
		write_denied_clone_add(&t.suffix, "AppData/Local/Microsoft/Credentials/", a)
	}
}

// write_denied_add appends an exact deny rule, dropping empty results: a join that
// failed (allocation failure only) must not become an inert entry.
write_denied_add :: proc(list: ^[dynamic]string, path: string) {
	if len(path) > 0 {
		append(list, path)
	}
}

// write_denied_clone_add appends a cloned constant rule — every table entry must be
// an owned allocation so destroy frees them uniformly.
write_denied_clone_add :: proc(list: ^[dynamic]string, path: string, a: mem.Allocator) {
	append(list, strings.clone(path, a))
}

// write_denied_add_prefix appends a "dir/" deny prefix built from the parts, dropping
// the rule when the join produced nothing — an empty dir must not degrade
// into the deny-everything "/" prefix. The join result only feeds the
// concatenation, so it is freed here; call sites must not pass an owned
// string they still need.
write_denied_add_prefix :: proc(list: ^[dynamic]string, parts: []string, a: mem.Allocator) {
	dir, _ := filepath.join(parts, a)
	if len(dir) == 0 {
		return
	}
	append(list, strings.concatenate({dir, "/"}, a))
	delete(dir, a)
}

// write_denied_add_dir_prefix appends a "dir/" deny prefix for an
// already-joined directory. The project daemon hands the resolved managed
// state directory here, so the gate refuses that tree by location — the
// name-built entries above cover only the default spelling. The entry is
// built directly on the tables' allocator (an owned clone, like every
// add above); `dir` itself is borrowed and must not need freeing.
write_denied_add_dir_prefix :: proc(t: ^Write_Denied_Tables, dir: string) {
	if len(dir) > 0 {
		append(&t.prefix, strings.concatenate({dir, "/"}, t.allocator))
	}
}

// write_denied_join joins path parts under the given allocator (proc literals
// cannot capture locals — no closures in Odin). A join failure here is
// allocation-only; the empty result is dropped by write_denied_add/write_denied_add_prefix
// rather than becoming an inert or degenerate rule.
write_denied_join :: proc(parts: []string, a: mem.Allocator) -> string {
	joined, _ := filepath.join(parts, a)
	return joined
}

write_denied_destroy :: proc(t: ^Write_Denied_Tables) {
	for s in t.exact {
		delete(s, t.allocator)
	}
	for s in t.prefix {
		delete(s, t.allocator)
	}
	for s in t.suffix {
		delete(s, t.allocator)
	}
	delete(t.exact)
	delete(t.prefix)
	delete(t.suffix)
	t.exact = nil
	t.prefix = nil
	t.suffix = nil
}

// expand_env_safe expands $VAR / ${VAR} and rejects expansions that emptied
// path segments (an unset variable could otherwise shorten the path and
// bypass the gate).
expand_env_safe :: proc(path: string, a := context.allocator) -> (string, bool) {
	expanded := expand_env(path, a)
	if expanded == "" {
		return "", false
	}
	// Normalise to forward slashes so the double-separator check works
	// regardless of whether the input used / or \ (expand_env preserves
	// the caller's separator spelling).
	slash, _ := strings.replace_all(expanded, "\\", "/", a)
	if strings.contains(slash, "//") {
		return "", false
	}
	return expanded, true
}

// expand_env performs $VAR and ${VAR} substitution; unknown variables
// expand to the empty string.
expand_env :: proc(s: string, a := context.allocator) -> string {
	if !strings.contains(s, "$") {
		return s
	}
	buf := make([dynamic]u8, 0, len(s), a)
	i := 0
	for i < len(s) {
		if s[i] != '$' {
			append(&buf, s[i])
			i += 1
			continue
		}
		i += 1
		if i >= len(s) {
			append(&buf, '$')
			break
		}
		name_start := i
		if s[i] == '{' {
			i += 1
			name_start = i
			for i < len(s) && s[i] != '}' {
				i += 1
			}
			if i >= len(s) {
				// Unterminated ${: keep the input verbatim; the partial
				// expansion in buf is discarded with its backing.
				delete(buf)
				return s
			}
			name := s[name_start:i]
			i += 1
			append_env_value(&buf, name, a)
		} else {
			for i < len(s) && (s[i] == '_' || (s[i] >= 'a' && s[i] <= 'z') ||
				(s[i] >= 'A' && s[i] <= 'Z') || (s[i] >= '0' && s[i] <= '9')) {
				i += 1
			}
			if i == name_start {
				append(&buf, '$')
				continue
			}
			name := s[name_start:i]
			append_env_value(&buf, name, a)
		}
	}
	return string(buf[:])
}

append_env_value :: proc(buf: ^[dynamic]u8, name: string, a := context.allocator) {
	if value, found := os.lookup_env_alloc(name, a); found {
		// lookup_env_alloc hands back an owned clone even when the append
		// only copies the bytes; release it here so expand_env stays
		// allocation-clean on any allocator.
		append(buf, value)
		delete(value, a)
	}
}

// is_write_denied reports whether writing the path is denied. Advisory:
// resolution happens at check time (TOCTOU); callers still validate
// containment. Resolution is anchorless like is_denied's — matching
// canonicalizes and must not fall back to a junction spelling.
is_write_denied :: proc(t: ^Write_Denied_Tables, path: string) -> bool {
	expanded, ok := expand_env_safe(path, context.temp_allocator)
	if !ok {
		return true // fail closed on bad expansion
	}
	cleaned, clean_err := filepath.clean(expanded, context.temp_allocator)
	if clean_err != nil {
		return true // fail closed: the deny decision must not guess
	}
	resolved, status := pathguard_resolve_symlinks(cleaned, "", context.temp_allocator)
	if status != .Resolved && status != .Missing {
		resolved = cleaned
	}

	for denied in t.exact {
		d_expanded, dok := expand_env_safe(denied, context.temp_allocator)
		if !dok {
			continue
		}
		d_clean, d_clean_err := filepath.clean(d_expanded, context.temp_allocator)
		if d_clean_err != nil {
			return true // fail closed: a rule we cannot interpret denies
		}
		d_resolved, d_status := pathguard_resolve_symlinks(d_clean, "", context.temp_allocator)
		if d_status != .Resolved && d_status != .Missing {
			d_resolved = d_clean
		}
		if deny_path_eq(resolved, d_resolved) {
			return true
		}
	}
	for prefix in t.prefix {
		dir := strings.trim_suffix(prefix, "/")
		p_expanded, pok := expand_env_safe(dir, context.temp_allocator)
		if !pok {
			continue
		}
		p_clean, p_clean_err := filepath.clean(p_expanded, context.temp_allocator)
		if p_clean_err != nil {
			return true // fail closed: a rule we cannot interpret denies
		}
		p_resolved, p_status := pathguard_resolve_symlinks(p_clean, "", context.temp_allocator)
		if p_status != .Resolved && p_status != .Missing {
			p_resolved = p_clean
		}
		p_trail := strings.concatenate({p_resolved, "/"}, context.temp_allocator)
		// Normalise both sides to forward slashes so backslash paths on
		// Windows do not miss a prefix match.
		r_slash, _ := strings.replace_all(resolved, "\\", "/", context.temp_allocator)
		p_slash, _ := strings.replace_all(p_trail, "\\", "/", context.temp_allocator)
		if deny_path_prefix(r_slash, p_slash) || deny_path_eq(resolved, p_resolved) {
			return true
		}
	}

	// Fallback rules (no home resolved at init): the home-relative spelling
	// is the secret. Compared on slash-normalised paths so separator
	// spelling cannot slip a rule. Directory rules carry a trailing slash
	// and deny the directory itself plus everything inside it.
	if len(t.suffix) > 0 {
		slash, _ := strings.replace_all(resolved, "\\", "/", context.temp_allocator)
		if len(slash) == 0 && len(resolved) > 0 {
			return true // fail closed: a path we cannot normalize must not pass
		}
		for suffix in t.suffix {
			d_expanded, dok := expand_env_safe(suffix, context.temp_allocator)
			if !dok {
				continue
			}
			d_slash, _ := strings.replace_all(d_expanded, "\\", "/", context.temp_allocator)
			if len(d_slash) == 0 && len(d_expanded) > 0 {
				return true // fail closed: a rule we cannot interpret denies
			}
			if deny_path_suffix(slash, d_slash) {
				return true
			}
			if strings.has_suffix(d_slash, "/") {
				inside := strings.concatenate({"/", d_slash}, context.temp_allocator)
				if deny_path_contains(slash, inside) {
					return true
				}
			}
		}
	}
	return false
}

// --- read-ask heuristic --------------------------------------------------------

// is_read_ask reports whether reading the path should prompt the user:
// credential-like basenames or residency inside sensitive directories.
is_read_ask :: proc(path: string) -> bool {
	normalised := normalise_for_matching(path, context.temp_allocator)
	base := filepath.base(normalised)
	for pattern in DEFAULT_READ_ASK_PATTERNS {
		if filepath_match(pattern, base) {
			return true
		}
		if platform.case_insensitive_fs() {
			lower_pattern := strings.to_lower(pattern, context.temp_allocator)
			lower_base := strings.to_lower(base, context.temp_allocator)
			if filepath_match(lower_pattern, lower_base) {
				return true
			}
		}
	}
	slash, _ := strings.replace_all(normalised, "\\", "/", context.temp_allocator)
	for dir in SENSITIVE_READ_ASK_DIRS {
		if path_contains_segment(slash, dir) {
			return true
		}
	}
	return false
}

// path_contains_segment reports whether the slash-separated path contains
// the directory as a whole path component.
path_contains_segment :: proc(path, segment: string) -> bool {
	mid := strings.concatenate({"/", segment, "/"}, context.temp_allocator)
	if strings.contains(path, mid) {
		return true
	}
	if strings.has_prefix(path, strings.concatenate({segment, "/"}, context.temp_allocator)) {
		return true
	}
	if strings.has_suffix(path, strings.concatenate({"/", segment}, context.temp_allocator)) {
		return true
	}
	return false
}

// is_sensitive_system_path reports whether the path points at sensitive
// system locations (/etc, /boot, systemd, the docker socket). Resolution
// is anchorless like is_denied's, so a junction spelling that hides the
// real system location still resolves before the compare.
is_sensitive_system_path :: proc(path: string) -> bool {
	normalised := normalise_for_matching(path, context.temp_allocator)
	cleaned, clean_err := filepath.clean(normalised, context.temp_allocator)
	if clean_err != nil {
		return true // fail closed: the deny decision must not guess
	}
	resolved, status := pathguard_resolve_symlinks(cleaned, "", context.temp_allocator)
	if status != .Resolved && status != .Missing {
		resolved = cleaned
	}
	for prefix in SENSITIVE_SYSTEM_PREFIXES {
		if ci_has_prefix(resolved, prefix) || ci_has_prefix(cleaned, prefix) {
			return true
		}
	}
	when ODIN_OS == .Windows {
		// Registry hives and the drivers/hosts config live under
		// SystemRoot — env-derived, so they cannot sit in the constant
		// table and are appended at init instead.
		sysroot, found := os.lookup_env_alloc("SystemRoot", context.temp_allocator)
		root := "C:\\Windows"
		if found && sysroot != "" {
			root = sysroot
		}
		for rel in WIN_SENSITIVE_SYSTEM_RELPATHS {
			dir, _ := filepath.join({root, rel}, context.temp_allocator)
			if len(dir) == 0 {
				continue
			}
			prefix := strings.concatenate({dir, "\\"}, context.temp_allocator)
			if ci_has_prefix(resolved, prefix) || ci_has_prefix(cleaned, prefix) {
				return true
			}
		}
	}
	for exact in SENSITIVE_SYSTEM_EXACT {
		if deny_path_eq(resolved, exact) || deny_path_eq(cleaned, exact) {
			return true
		}
	}
	return false
}

// filepath_match implements the classic glob dialect: *, ?, [class]
// (with ranges and ^ negation), backslash escapes; no ** and no braces.
filepath_match :: proc(pattern, name: string) -> bool {
	return filepath_match_at(pattern, 0, name, 0)
}

filepath_match_at :: proc(pattern: string, pi: int, name: string, ni: int) -> bool {
	p, n := pi, ni
	for p < len(pattern) {
		switch pattern[p] {
		case '*':
			// Consecutive stars collapse (a/*/b matches a/b).
			for p < len(pattern) && pattern[p] == '*' {
				p += 1
			}
			if p >= len(pattern) {
				return true
			}
			for i := n; i <= len(name); i += 1 {
				if filepath_match_at(pattern, p, name, i) {
					return true
				}
			}
			return false
		case '?':
			if n >= len(name) {
				return false
			}
			p += 1
			n += 1
		case '[':
			if n >= len(name) {
				return false
			}
			matched, next, ok := match_class(pattern, p, name[n])
			if !ok {
				// Malformed class: match the bracket literally.
				if name[n] != '[' {
					return false
				}
				p += 1
				n += 1
				continue
			}
			if !matched {
				return false
			}
			p = next
			n += 1
		case '\\':
			if p + 1 >= len(pattern) {
				return false
			}
			if n >= len(name) || name[n] != pattern[p + 1] {
				return false
			}
			p += 2
			n += 1
		case:
			if n >= len(name) || name[n] != pattern[p] {
				return false
			}
			p += 1
			n += 1
		}
	}
	return n == len(name)
}

// match_class evaluates a [...] class starting at pattern[p] == '[' and
// returns whether c matches plus the offset just past ']'.
match_class :: proc(pattern: string, p: int, c: u8) -> (matched: bool, next: int, ok: bool) {
	i := p + 1
	negated := false
	if i < len(pattern) && (pattern[i] == '^' || pattern[i] == '!') {
		negated = true
		i += 1
	}
	found := false
	first := true
	for i < len(pattern) && (pattern[i] != ']' || first) {
		first = false
		if pattern[i] == '\\' && i + 1 < len(pattern) {
			i += 1
			if pattern[i] == c {
				found = true
			}
			i += 1
			continue
		}
		lo := pattern[i]
		hi := lo
		if i + 2 < len(pattern) && pattern[i + 1] == '-' && pattern[i + 2] != ']' {
			hi = pattern[i + 2]
			i += 3
		} else {
			i += 1
		}
		if c >= lo && c <= hi {
			found = true
		}
	}
	if i >= len(pattern) {
		return false, p, false // unterminated class
	}
	// Skip the closing bracket.
	i += 1
	if negated {
		return !found, i, true
	}
	return found, i, true
}

