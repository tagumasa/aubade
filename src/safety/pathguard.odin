// Path containment: lexical checks for parent-directory traversal and
// session-ID components, plus a stat-backed symlink-aware validator
// for joining a relative path to a project root.
//
// The single source of truth for the auxiliary lexical check used across
// all path-validation call sites. Centralising it here prevents the
// recurring bug where callers use plain `HasPrefix(rel, "..")`, which
// incorrectly rejects legitimate filenames beginning with two dots.
package safety

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Path_Escape_Error describes why a path failed the containment check.
Path_Escape_Error :: struct {
	reason:   string,
	rel:      string,
	resolved: string,
}

pathguard_escapes_root :: proc(rel: string) -> bool {
	if rel == ".." {
		return true
	}
	// Both separators: on Windows a caller may hand in `\`-separated
	// components, and matching only the host separator would miss the
	// other one.
	if strings.has_prefix(rel, "../") || strings.has_prefix(rel, "..\\") {
		return true
	}
	if filepath.is_abs(rel) {
		return true
	}
	return false
}

// pathguard_validate_contained checks that joining `rel` to `root` stays inside `root`,
// both lexically and after symlink resolution. The returned absolute path is
// the resolved path (post-symlink-chain) so callers can use it directly
// without re-validating.
//
// The not-yet-existing tail of the path stays lexical: the resolution walk
// stops at the first missing component, so the returned path is the resolved
// prefix joined with the lexical tail. This is the fail-open path used by
// tools that want to write to a not-yet-existent file inside the project —
// every existing ancestor is still resolved and escape-checked.
pathguard_validate_contained :: proc(root, rel: string, a: mem.Allocator) -> (string, Path_Escape_Error) {
	root_clean, root_clean_err := filepath.clean(root, a)
	if root_clean_err != nil {
		return "", {reason = "clean failed", rel = rel}
	}

	// Resolve symlinks component-wise: the existing ancestors of a
	// not-yet-existing target are verified too, and a chain that crosses
	// out of the root is a rejection, not a fail-open. The root itself may
	// be a symlink; resolve it first so the walk's containment prefix is
	// the real root.
	root_resolved := root_clean
	root_res, root_status := pathguard_resolve_symlinks(root_clean, "", a)
	if root_status == .Resolved {
		root_resolved = root_res
	}
	return pathguard_validate_from_roots(root_clean, root_resolved, rel, a)
}

// pathguard_validate_contained_resolved is the containment check for
// callers that already hold the root's resolved spelling (one
// pathguard_resolve_root at owner init): the root cannot change under a
// running daemon, and re-resolving it cost one lstat plus readlink per
// component on every checked read. The behavior is identical to
// pathguard_validate_contained; only the root's own re-resolution is
// skipped. The caller must pass a root produced by pathguard_resolve_root
// (resolved, or the raw spelling when resolution failed — the same
// fallback the internal path takes).
pathguard_validate_contained_resolved :: proc(root_resolved, rel: string, a: mem.Allocator) -> (string, Path_Escape_Error) {
	root_clean, root_clean_err := filepath.clean(root_resolved, a)
	if root_clean_err != nil {
		return "", {reason = "clean failed", rel = rel}
	}
	return pathguard_validate_from_roots(root_clean, root_clean, rel, a)
}

// pathguard_validate_from_roots is the containment body shared by the two
// entry points: root_clean is the join prefix, root_resolved the
// resolution walk's containment prefix.
pathguard_validate_from_roots :: proc(root_clean, root_resolved, rel: string, a: mem.Allocator) -> (string, Path_Escape_Error) {
	if rel == "" || rel == "." || rel == "/" || rel == "\\" {
		return "", {reason = "empty or root-relative path not allowed", rel = rel}
	}
	abs_path, join_err := filepath.join({root_clean, rel}, a)
	if join_err != nil {
		return "", {reason = "join failed", rel = rel}
	}
	cleaned, clean_err := filepath.clean(abs_path, a)
	if clean_err != nil {
		return "", {reason = "clean failed", rel = rel}
	}
	abs_path = cleaned

	rel2, rel_err := filepath.rel(root_clean, abs_path, a)
	if rel_err != filepath.Relative_Error.None {
		return "", {reason = "cannot relate to root", rel = rel}
	}
	if rel2 == "." {
		return "", {reason = "path resolves to root itself", rel = rel}
	}
	if pathguard_escapes_root(rel2) {
		return "", {reason = "path escapes root", rel = rel, resolved = abs_path}
	}

	resolved, status := pathguard_resolve_symlinks(abs_path, root_resolved, a)
	switch status {
	case .Escaped:
		return "", {reason = "symlink target escapes root", rel = rel, resolved = resolved}
	case .Unresolved:
		return "", {reason = "symlink chain cannot be resolved", rel = rel, resolved = resolved}
	case .Missing:
		// The tail does not exist yet: its existing ancestors were resolved
		// and escape-checked; the lexical tail was contained pre-resolution.
		return resolved, {}
	case .Resolved:
		// Full chain resolved: re-check containment below.
	}

	res_rel, res_err := filepath.rel(root_resolved, resolved, a)
	if res_err != filepath.Relative_Error.None {
		return "", {reason = "cannot relate resolved to root", rel = rel, resolved = resolved}
	}
	if pathguard_escapes_root(res_rel) {
		return "", {reason = "symlink target escapes root", rel = rel, resolved = resolved}
	}
	return resolved, {}
}

// pathguard_validate_contained_dir checks that `requested` (absolute, or relative to
// `root`) names a path inside `root`, with the root itself allowed — the
// directory-containment flavor used for working-directory checks.
// pathguard_validate_contained must keep rejecting the root itself (file tools never
// target it), while a cwd of exactly the project root is legitimate.
pathguard_validate_contained_dir :: proc(root, requested: string, a: mem.Allocator) -> (string, Path_Escape_Error) {
	root_clean, root_clean_err := filepath.clean(root, a)
	if root_clean_err != nil {
		return "", {reason = "clean failed", rel = requested}
	}
	cand := requested
	if !filepath.is_abs(cand) {
		joined, jerr := filepath.join({root_clean, cand}, a)
		if jerr != nil {
			return "", {reason = "join failed", rel = requested}
		}
		cand = joined
	}
	cand_clean, clean_err := filepath.clean(cand, a)
	if clean_err != nil {
		return "", {reason = "clean failed", rel = requested}
	}
	cand = cand_clean

	rel, rerr := filepath.rel(root_clean, cand, a)
	if rerr != filepath.Relative_Error.None {
		return "", {reason = "cannot relate to root", rel = requested}
	}
	if rel == "." {
		// The root itself: resolve its own symlinks so the returned path is
		// the real directory (same contract as pathguard_validate_contained).
		res, status := pathguard_resolve_symlinks(root_clean, "", a)
		if status == .Escaped || status == .Unresolved {
			return "", {reason = "symlink chain cannot be resolved", rel = requested, resolved = res}
		}
		if status == .Resolved {
			return res, {}
		}
		return root_clean, {}
	}
	if pathguard_escapes_root(rel) {
		return "", {reason = "path escapes root", rel = requested, resolved = cand}
	}
	return pathguard_validate_contained(root, rel, a)
}

// pathguard_resolve_root returns the symlink-resolved spelling of an absolute
// project root (the raw spelling, cloned, when resolution fails). Every
// path the guard hands out is resolved; a root kept in an unresolved
// spelling (macOS temp trees: /var vs /private/var) makes every prefix
// compare between the two spellings miss. This is canonicalization, not
// a security decision: an unresolvable root keeps working exactly as
// before, and per-path containment checks still run on every later call.
pathguard_resolve_root :: proc(root: string, a: mem.Allocator) -> string {
	// Scratch on the temp allocator — the validator's intermediates
	// (clean/rel/join) would leak through `a` — and hand back a fresh
	// a-owned string in both branches (never an alias of the input, so
	// the caller can free it unconditionally).
	resolved, perr := pathguard_validate_contained_dir(root, root, context.temp_allocator)
	if perr.reason != "" {
		return strings.clone(root, a)
	}
	return strings.clone(resolved, a)
}

// Resolve_Status classifies the outcome of the component-wise symlink walk.
Resolve_Status :: enum {
	Resolved,   // every component exists; the chain ends on a non-link path
	Missing,    // a component does not exist; the returned path is the
	            // verified prefix joined with the lexical tail
	Escaped,    // a symlink target lifted the walk above `prefix`
	Unresolved, // iteration budget exhausted (symlink loop or too-deep chain)
}

// pathguard_resolve_symlinks walks `path` component by component, resolving symlinks
// as they appear. Walking components (not the whole path) is what verifies
// the existing ancestors of a not-yet-existing target: a new file written
// through a symlinked directory is checked against the directory the shell
// would actually touch. When `prefix` is non-empty, any symlink step that
// lifts the walk above `prefix` reports .Escaped; the walk is bounded, and
// budget exhaustion reports .Unresolved (a looping chain must not fail open).
pathguard_resolve_symlinks :: proc(path, prefix: string, a: mem.Allocator, depth: int = 0) -> (string, Resolve_Status) {
	if depth > 8 {
		// A hop target whose resolution needs its own nested walk is
		// bounded: chains of chains (a link to a link to a link...) this
		// deep are pathological, and the budget must not fail open.
		return path, .Unresolved
	}
	// The walk is intra-procedure scratch on the temp allocator; every
	// value handed back to the caller is cloned into `a` so the join,
	// clean, readlink, and stat intermediates never leak through the
	// caller's allocator.
	ta := context.temp_allocator
	if len(path) == 0 {
		return path, .Missing
	}
	// Callers hand us cleaned absolute paths. filepath.abs returns "" for
	// inputs it cannot stat on this toolchain, and the empty string would
	// poison the peel loop below — so absolute input is used as-is and only
	// relative input goes through abs.
	abs := path
	if !filepath.is_abs(path) {
		anchored, _ := filepath.abs(path, ta)
		if len(anchored) == 0 {
			return path, .Unresolved
		}
		abs = anchored
	}

	// Peel the path into components, root first. The peel is bounded: this
	// toolchain's dir("") and dir(".") map to each other and never converge,
	// so the loop must not depend on dir alone to terminate.
	stack := make([dynamic]string, 0, 16, ta)
	defer delete(stack)
	cur := abs
	for peels := 0; peels <= 256; peels += 1 {
		d := filepath.dir(cur)
		if d == cur {
			break
		}
		if peels == 256 || len(d) >= len(cur) {
			return path, .Unresolved
		}
		append(&stack, filepath.base(cur))
		cur = d
	}
	current := cur

	for i := len(stack) - 1; i >= 0; i -= 1 {
		next, jerr := filepath.join({current, stack[i]}, ta)
		if jerr != nil {
			return strings.clone(current, a), .Unresolved
		}
		hops := 0
		for {
			hops += 1
			if hops > 64 {
				return strings.clone(current, a), .Unresolved
			}
			// lstat does not follow links; a missing component ends the
			// verified prefix — everything below it stays lexical. The
			// info's fullpath clone is owned by `ta` and freed at once.
			info, lerr := os.lstat(next, ta)
			if lerr == nil {
				os.file_info_delete(info, ta)
			}
			if lerr != nil {
				out := current
				for j := i; j >= 0; j -= 1 {
					out, jerr = filepath.join({out, stack[j]}, ta)
					if jerr != nil {
						return strings.clone(current, a), .Unresolved
					}
				}
				return strings.clone(out, a), .Missing
			}
			// readlink is the canonical symlink check.
			target, rerr := os.read_link(next, ta)
			if rerr != nil {
				current = next // plain component
				break
			}
			if filepath.is_abs(target) {
				cleaned, clean_err := filepath.clean(target, ta)
				// clean always allocates a fresh string; target's backing
				// is no longer aliased once it returns.
				delete(target, ta)
				if clean_err != nil {
					return strings.clone(current, a), .Unresolved
				}
				next = cleaned
			} else {
				parent := filepath.dir(next)
				joined, jerr2 := filepath.join({parent, target}, ta)
				delete(target, ta)
				if jerr2 != nil {
					return strings.clone(current, a), .Unresolved
				}
				cleaned, clean_err := filepath.clean(joined, ta)
				if clean_err != nil {
					return strings.clone(current, a), .Unresolved
				}
				next = cleaned
			}
			// Canonicalize the hop target through its own nested walk:
			// an absolute target can name the location through a
			// different symlink spelling of its ancestors (macOS /var
			// vs /private/var), which later lexical compares cannot
			// match. Root walks (empty prefix) need this just as much —
			// otherwise a resolved root keeps the unresolved spelling
			// and every later containment compare against it misses.
			phys, pst := pathguard_resolve_symlinks(next, "", ta, depth + 1)
			if pst == .Unresolved {
				return strings.clone(current, a), .Unresolved
			}
			next = phys
			if len(prefix) > 0 {
				rel, rel_err := filepath.rel(prefix, next, ta)
				// A relative path that cannot be computed is treated as an
				// escape (fail closed: e.g. a cross-drive symlink target on
				// Windows), never as a pass.
				if rel_err != filepath.Relative_Error.None || pathguard_escapes_root(rel) {
					// Exception: while the walk is still above the root
					// (current is a proper ancestor of the prefix), a
					// symlink hop may land on an ancestor of the root.
					// macOS temp trees hit this on every path: the project
					// root sits under /private/var/folders/... while the
					// walk starts from the /var/folders/... spelling, so
					// the /var -> /private/var hop must be allowed to
					// leave the tree and let the remaining components
					// descend back into it. The proper-ancestor guard
					// keeps in-project links pointing at ancestors
					// (a ../.. escape) rejected: once current reaches the
					// root, this exception no longer applies.
					above := false
					if current != prefix {
						cur_rel, cur_err := filepath.rel(current, prefix, ta)
						if cur_err == filepath.Relative_Error.None && !pathguard_escapes_root(cur_rel) {
							above = true
						}
					}
					if above {
						back, back_err := filepath.rel(next, prefix, ta)
						if back_err == filepath.Relative_Error.None && !pathguard_escapes_root(back) {
							continue
						}
					}
					return strings.clone(next, a), .Escaped
				}
			}
		}
	}
	return strings.clone(current, a), .Resolved
}

// pathguard_validate_session_id checks that a session identifier is safe to use as a
// filesystem path component. Rejects empty strings, traversal segments,
// path separators, and control characters.
pathguard_validate_session_id :: proc(id: string) -> (ok: bool, reason: string) {
	if len(id) == 0 {
		return false, "session ID is empty"
	}
	if id == "." || id == ".." {
		return false, "session ID is a path traversal component"
	}
	if strings.contains_any(id, `/\`) {
		return false, "session ID contains path separators"
	}
	if strings.contains(id, "..") {
		return false, "session ID contains traversal sequence"
	}
	if len(id) > 256 {
		return false, "session ID is too long"
	}
	for ch in id {
		if ch < 0x20 || ch == 0x7F {
			return false, "session ID contains control character"
		}
	}
	return true, ""
}
