// The svc.memory/* face: method names plus the daemon-side memory file
// operations behind them. Memories are markdown files under the
// project's managed directory (<managed>/memories, placed by the global
// folder template) and $AUBADE_HOME/memories/global (the
// "global/" name prefix addresses the latter). Names are validated and
// resolved by the memory domain package; this file owns the I/O —
// bounded reads, atomic writes (temp + fsync + rename + dir sync),
// symlink containment, and the recursive listing walk. Writes serialize
// through one mutex (memory ops are low-frequency; per-path lock
// sharding would serve a concurrency level this daemon does not need).
// Read-only/ignored patterns are compiled per call: a
// PCRE2 Regex belongs to the thread that uses it, and the daemon serves
// requests from a worker pool.
package svc

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "src:config"
import "src:memory"
import "src:platform"
import "src:regex"
import "src:safety"
import "src:util"

METHOD_MEMORY_LIST :: "svc.memory/list" // {topic?} -> {memories?, read_only_memories?}
METHOD_MEMORY_READ :: "svc.memory/read" // {memory_name} -> {content, found}
METHOD_MEMORY_WRITE :: "svc.memory/write" // {memory_name, content} -> {}
METHOD_MEMORY_REPLACE :: "svc.memory/replace" // {memory_name, needle, repl, mode, allow_multiple_occurrences?} -> {}
METHOD_MEMORY_RENAME :: "svc.memory/rename" // {old_name, new_name} -> {propagated}
METHOD_MEMORY_DELETE :: "svc.memory/delete" // {memory_name} -> {found}

MEMORY_DIR_PERMS :: os.Permissions{
	.Read_User, .Write_User, .Execute_User,
	.Read_Group, .Execute_Group,
	.Read_Other, .Execute_Other,
}

MEMORY_FILE_PERMS :: os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other}

MEMORY_WALK_MAX_DEPTH :: 100 // bounds the listing walk
MEMORY_SYMLINK_MAX_HOPS :: 8 // bounds symlink-chain resolution

// Memory_Files is the daemon-owned memory state: the two roots, their
// symlink-resolved forms (containment checks compare against those), and
// the merged read-only/ignored pattern lists.
Memory_Files :: struct {
	allocator:        mem.Allocator,
	mu:               sync.Mutex,
	project_dir:      string,
	global_dir:       string,
	resolved_project: string,
	resolved_global:  string,
	read_only:        []string,
	ignored:          []string,
}

// memory_files_init prepares the memory roots (created best-effort) and
// takes ownership of clones of the merged pattern
// lists. Never fails: unreadable directories surface later as empty
// listings or per-file errors.
// memory_files_global_only initializes just the global tree: the
// project fields stay empty and no project directory is created (the
// global-only listing never touches them).
memory_files_global_only :: proc(mf: ^Memory_Files, home: string, a: mem.Allocator) {
	mf^ = {
		allocator  = a,
		global_dir = platform.global_memories_dir(home, a),
	}
	_ = os.make_directory_all(mf.global_dir, MEMORY_DIR_PERMS)
	mf.resolved_global = resolve_dir_symlinks(mf.global_dir, a)
}

memory_files_init :: proc(
	mf: ^Memory_Files,
	project_root: string,
	home: string,
	read_only_patterns: []string,
	ignored_patterns: []string,
	a: mem.Allocator,
) {
	managed := config.managed_dir_for_root(project_root, home, a)
	mf^ = {
		allocator   = a,
		project_dir = platform.project_memories_dir(managed, a),
		global_dir  = platform.global_memories_dir(home, a),
	}
	delete(managed, a)
	_ = os.make_directory_all(mf.project_dir, MEMORY_DIR_PERMS)
	_ = os.make_directory_all(mf.global_dir, MEMORY_DIR_PERMS)
	mf.resolved_project = resolve_dir_symlinks(mf.project_dir, a)
	mf.resolved_global = resolve_dir_symlinks(mf.global_dir, a)
	mf.read_only = clone_str_slice(read_only_patterns, a)
	mf.ignored = clone_str_slice(ignored_patterns, a)
}

memory_files_destroy :: proc(mf: ^Memory_Files) {
	delete(mf.project_dir, mf.allocator)
	delete(mf.global_dir, mf.allocator)
	if mf.resolved_project != mf.project_dir {
		delete(mf.resolved_project, mf.allocator)
	}
	if mf.resolved_global != mf.global_dir {
		delete(mf.resolved_global, mf.allocator)
	}
	for s in mf.read_only {
		delete(s, mf.allocator)
	}
	if mf.read_only != nil {
		delete(mf.read_only, mf.allocator)
	}
	for s in mf.ignored {
		delete(s, mf.allocator)
	}
	if mf.ignored != nil {
		delete(mf.ignored, mf.allocator)
	}
	mf^ = {}
}

clone_str_slice :: proc(list: []string, a: mem.Allocator) -> []string {
	out := make([]string, len(list), a)
	for s, i in list {
		out[i] = strings.clone(s, a)
	}
	return out
}

// resolve_dir_symlinks follows a directory's symlink chain (bounded,
// best-effort) so containment checks compare resolved paths against
// resolved roots; on any failure the lexical path stands.
resolve_dir_symlinks :: proc(dir: string, a: mem.Allocator) -> string {
	cur := dir
	for _ in 0..<MEMORY_SYMLINK_MAX_HOPS {
		kind, kok := util.lstat_kind(cur)
		if !kok || kind != .Symlink {
			if cur == dir {
				return dir
			}
			return strings.clone(cur, a)
		}
		target, terr := os.read_link(cur, context.temp_allocator)
		if terr != nil {
			break
		}
		next := target
		if !filepath.is_abs(next) {
			next, _ = filepath.join({filepath.dir(cur), next}, context.temp_allocator)
		}
		clean, cerr := filepath.clean(next, context.temp_allocator)
		// clean always allocates a fresh string, so target's backing is no
		// longer aliased once it returns.
		delete(target, context.temp_allocator)
		if cerr != nil {
			break
		}
		cur = clean
	}
	return strings.clone(cur, a)
}

// ---------------------------------------------------------------------------
// Access checks
// ---------------------------------------------------------------------------

// gate_set_compile compiles an access-gate pattern list, refusing the
// operation when any pattern fails to compile: a pattern that silently
// drops out of an ignored/read_only gate fails the gate open for exactly
// the memories it was meant to protect. The set is returned even on
// error (partial), so the caller's unconditional pattern_set_destroy
// stays correct; the caller must check err before matching.
gate_set_compile :: proc(patterns: []string, field: string, a: mem.Allocator) -> (set: memory.Pattern_Set, err: platform.Err) {
	compiled, skipped, bad := memory.pattern_set_compile(patterns, context.temp_allocator)
	if skipped > 0 {
		return compiled, platform.Wrapped{
			kind = .Invalid,
			msg  = strings.concatenate(
				{"invalid regex in ", field, ": '", bad, "' — refused rather than apply the remaining patterns"},
				a,
			),
		}
	}
	return compiled, nil
}

// memory_check_not_ignored refuses names matched by the merged ignored
// patterns (compiled per call, thread ownership).
memory_check_not_ignored :: proc(mf: ^Memory_Files, name: string, a: mem.Allocator) -> platform.Err {
	set, gerr := gate_set_compile(mf.ignored, "ignored_memory_patterns", a)
	defer memory.pattern_set_destroy(&set)
	if gerr != nil {
		return gerr
	}
	if memory.pattern_set_match(&set, name) {
		return platform.Wrapped{
			kind = .Invalid,
			msg = strings.concatenate(
				{"memory '", name, "' matches an ignored_memory_patterns pattern and cannot be accessed"},
				a,
			),
		}
	}
	return nil
}

// memory_check_writeable refuses ignored and (for tool calls, which is
// every caller here) read-only memories.
memory_check_writeable :: proc(mf: ^Memory_Files, name: string, a: mem.Allocator) -> platform.Err {
	if err := memory_check_not_ignored(mf, name, a); err != nil {
		return err
	}
	set, gerr := gate_set_compile(mf.read_only, "read_only_memory_patterns", a)
	defer memory.pattern_set_destroy(&set)
	if gerr != nil {
		return gerr
	}
	if memory.pattern_set_match(&set, name) {
		return platform.Wrapped{
			kind = .Invalid,
			msg  = strings.concatenate({"attempted to write to read_only memory: '", name, "'"}, a),
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Path resolution and containment
// ---------------------------------------------------------------------------

// memory_path resolves a memory name onto its absolute file path under
// the owning root, creating missing subdirectories along the way (the
// reference creates them at resolve time, reads included). The resolved
// root is returned for the symlink containment check.
memory_path :: proc(mf: ^Memory_Files, name: string, a: mem.Allocator) -> (abs: string, root: string, err: platform.Err) {
	norm := memory.normalize_name(name)
	if verr := memory.validate_name(norm, a); verr != nil {
		return "", "", verr
	}
	rel, global, rerr := memory.resolve_rel(norm, a)
	if rerr != nil {
		return "", "", rerr
	}
	base := mf.project_dir
	root = mf.resolved_project
	if global {
		base = mf.global_dir
		root = mf.resolved_global
	}
	joined, jerr := filepath.join({base, rel}, a)
	if jerr != nil {
		return "", "", platform.Wrapped{kind = .Internal, msg = "memory path join failed"}
	}
	// Parent directories appear on demand — a failure is not fatal (the
	// write itself reports it).
	_ = os.make_directory_all(filepath.dir(joined), MEMORY_DIR_PERMS)
	if cerr := memory_check_containment(joined, root, norm, a); cerr != nil {
		delete(joined, a)
		return "", "", cerr
	}
	return joined, root, nil
}

// memory_check_containment refuses a memory whose resolved path escapes
// its root. The walk resolves EVERY component's symlinks — not only the
// final one — because a link hiding in a parent directory is the classic
// escape: lstat resolves intermediate links in the kernel, but comparing
// the lexical spelling (the old final-component-only walk) let a parent
// symlink pass a plain byte-prefix check. The resolved end must stay
// under the RESOLVED root (the memories dir itself may sit behind a
// symlink — macOS /var vs /private/var); a broken chain and an exhausted
// iteration budget refuse too (a looping chain must not fail open).
memory_check_containment :: proc(path: string, root: string, name: string, a: mem.Allocator) -> platform.Err {
	// The root self-walk runs with an EMPTY prefix — the root is what
	// containment is judged against, so it must come back canonically
	// resolved, never escaped-against-itself: a root spelling that
	// traverses an intermediate symlink (macOS /var -> /private/var)
	// makes a self-prefixed walk hop out lexically and return .Escaped
	// with a truncated prefix, under which every sibling path reads as
	// contained. Anything but .Resolved refuses — the root exists
	// (memory_files_init creates it), so an unresolvable or missing root
	// is a failure, never a pass.
	resolved_root, rstatus := safety.pathguard_resolve_symlinks(root, "", context.temp_allocator)
	if rstatus != .Resolved {
		return platform.Wrapped{
			kind = .Invalid,
			msg  = strings.concatenate({"memory \"", name, "\" root cannot be resolved for containment"}, a),
		}
	}
	resolved, status := safety.pathguard_resolve_symlinks(path, resolved_root, context.temp_allocator)
	if status == .Escaped {
		return memory_escaped_err(name, a)
	}
	if status == .Unresolved {
		return platform.Wrapped{
			kind = .Invalid,
			msg  = strings.concatenate({"memory \"", name, "\" cannot be resolved for containment (broken or looping symlink chain)"}, a),
		}
	}
	// .Missing keeps the verified prefix joined with the lexical tail: a
	// nonexistent target is the os call's business to report, and the
	// compare still judges the spelled tail against the resolved root.
	return memory_containment_err(resolved, resolved_root, name, a)
}

// path_under_root reports byte-prefix containment (separator-anchored,
// case-insensitive — macOS/Windows filesystems fold case).
path_under_root :: proc(path: string, root: string) -> bool {
	return len(path) > len(root) && path[len(root)] == u8(filepath.SEPARATOR) &&
		strings.equal_fold(path[:len(root)], root)
}

// memory_escaped_err is the one refusal for a memory path that ends up
// outside its directory — the symlink walk's .Escaped and the final
// prefix compare report the same fact, so they share one spelling.
memory_escaped_err :: proc(name: string, a: mem.Allocator) -> platform.Err {
	return platform.Wrapped{
		kind = .Invalid,
		msg  = strings.concatenate({"memory \"", name, "\" resolves outside its directory via symlink"}, a),
	}
}

// memory_containment_err passes a contained path and refuses an escaped
// one (a memory never legitimately resolves to the root itself).
memory_containment_err :: proc(path: string, root: string, name: string, a: mem.Allocator) -> platform.Err {
	if path_under_root(path, root) {
		return nil
	}
	return memory_escaped_err(name, a)
}

// ---------------------------------------------------------------------------
// Reads and writes
// ---------------------------------------------------------------------------

// memory_load reads one memory. A missing memory is reported found=false
// (the tool layer composes the create-it hint); genuine failures are
// errors.
memory_load :: proc(mf: ^Memory_Files, name: string, a: mem.Allocator) -> (content: string, found: bool, err: platform.Err) {
	if ierr := memory_check_not_ignored(mf, name, a); ierr != nil {
		return "", false, ierr
	}
	abs, _, perr := memory_path(mf, name, a)
	if perr != nil {
		return "", false, perr
	}
	kind, size, sok := util.stat_kind_size(abs)
	if !sok {
		return "", false, nil
	}
	if kind != .Regular {
		return "", false, platform.Wrapped{
			kind = .Invalid,
			msg  = strings.concatenate({"memory ", name, " is not a regular file"}, a),
		}
	}
	if size > memory.MAX_MEMORY_READ_BYTES {
		return "", false, platform.Wrapped{
			kind = .Invalid,
			msg = strings.concatenate(
				{"memory ", name, " is too large (", util.int_to_dec(cast(int)size, a),
					" bytes); maximum is ", util.int_to_dec(memory.MAX_MEMORY_READ_BYTES, a), " bytes)"},
				a,
			),
		}
	}
	data, rerr := os.read_entire_file_from_path(abs, a)
	if rerr != nil {
		return "", false, platform.Wrapped{
			kind = .Invalid,
			msg  = strings.concatenate({"cannot read memory ", name}, a),
		}
	}
	return string(data), true, nil
}

// memory_save writes one memory atomically (temp + fsync + rename).
memory_save :: proc(mf: ^Memory_Files, name: string, content: string, a: mem.Allocator) -> platform.Err {
	if werr := memory_check_writeable(mf, name, a); werr != nil {
		return werr
	}
	abs, _, perr := memory_path(mf, name, a)
	if perr != nil {
		return perr
	}
	sync.mutex_lock(&mf.mu)
	defer sync.mutex_unlock(&mf.mu)
	return memory_write_atomic(abs, content)
}

// memory_delete removes one memory; found=false means it was not there
// (the tool layer words the message).
memory_delete :: proc(mf: ^Memory_Files, name: string, a: mem.Allocator) -> (found: bool, err: platform.Err) {
	if werr := memory_check_writeable(mf, name, a); werr != nil {
		return false, werr
	}
	abs, _, perr := memory_path(mf, name, a)
	if perr != nil {
		return false, perr
	}
	sync.mutex_lock(&mf.mu)
	defer sync.mutex_unlock(&mf.mu)
	if rerr := os.remove(abs); rerr != nil {
		if _, _, sok := util.stat_kind_size(abs); !sok {
			return false, nil
		}
		return false, platform.Wrapped{
			kind = .Invalid,
			msg  = strings.concatenate({"cannot delete memory ", name}, a),
		}
	}
	return true, nil
}

// rename_cross_device reports whether a failed os.rename is the
// cross-device move — EXDEV on the POSIX targets, ERROR_NOT_SAME_DEVICE
// (17) on Windows — the only rename failure the copy-and-delete fallback
// handles; every other error (busy, permission, invalid name) surfaces.
rename_cross_device :: proc(rerr: os.Error) -> bool {
	perr, is_platform := rerr.(os.Platform_Error)
	if !is_platform {
		return false
	}
	when ODIN_OS == .Windows {
		return perr == .NOT_SAME_DEVICE
	} else {
		return perr == .EXDEV
	}
}

// memory_rename moves a memory (cross-scope project <-> global is the
// normal case), falling back to copy-and-delete when the roots sit on
// different filesystems, and rewrites `mem:<old>` references in the
// other writable memories. The propagation count rides the result.
memory_rename :: proc(
	mf: ^Memory_Files,
	old_name: string,
	new_name: string,
	a: mem.Allocator,
) -> (found: bool, propagated: int, err: platform.Err) {
	if werr := memory_check_writeable(mf, old_name, a); werr != nil {
		return false, 0, werr
	}
	if werr := memory_check_writeable(mf, new_name, a); werr != nil {
		return false, 0, werr
	}
	old_abs, _, perr := memory_path(mf, old_name, a)
	if perr != nil {
		return false, 0, perr
	}
	new_abs, _, perr2 := memory_path(mf, new_name, a)
	if perr2 != nil {
		return false, 0, perr2
	}

	sync.mutex_lock(&mf.mu)
	defer sync.mutex_unlock(&mf.mu)

	if _, _, sok := util.stat_kind_size(old_abs); !sok {
		return false, 0, platform.Wrapped{
			kind = .NotFound,
			msg  = strings.concatenate({"memory ", old_name, " not found"}, a),
		}
	}
	if _, _, sok2 := util.stat_kind_size(new_abs); sok2 {
		return false, 0, platform.Wrapped{
			kind = .Invalid,
			msg  = strings.concatenate({"memory ", new_name, " already exists"}, a),
		}
	}

	if rerr := os.rename(old_abs, new_abs); rerr != nil {
		// The copy-plus-delete fallback is for the cross-device move ONLY:
		// every other rename failure (busy, permission, invalid name)
		// must surface instead of triggering an unbounded read and an
		// unconditional delete of the original.
		if !rename_cross_device(rerr) {
			return false, 0, platform.Wrapped{
				kind = .Invalid,
				msg = strings.concatenate(
					{"rename memory ", old_name, " to ", new_name, " failed: ", os.error_string(rerr)},
					a,
				),
			}
		}
		_, old_size, _ := util.stat_kind_size(old_abs)
		if old_size > memory.MAX_MEMORY_READ_BYTES {
			return false, 0, platform.Wrapped{
				kind = .Invalid,
				msg = strings.concatenate(
					{"memory ", old_name, " exceeds the memory read cap; move it across devices manually"},
					a,
				),
			}
		}
		// Cross-device fallback: copy the bytes, then drop the original.
		data, read_err := os.read_entire_file_from_path(old_abs, context.temp_allocator)
		if read_err != nil {
			return false, 0, platform.Wrapped{
				kind = .Invalid,
				msg  = strings.concatenate({"rename memory ", old_name, " to ", new_name, " failed"}, a),
			}
		}
		if werr := memory_write_atomic(new_abs, string(data)); werr != nil {
			return false, 0, werr
		}
		if rmr := os.remove(old_abs); rmr != nil {
			// Both copies exist now; report the partial state rather than
			// silently losing the copy.
			return true, 0, platform.Wrapped{
				kind = .Internal,
				msg = strings.concatenate(
					{"memory copied to ", new_name, " but the old file could not be removed"},
					a,
				),
			}
		}
	}

	propagated = memory_propagate_rename_locked(mf, old_name, new_name, a)
	return true, propagated, nil
}

// memory_propagate_rename_locked rewrites `mem:<old>` references across
// the writable, non-ignored memories (the renamed one excluded). Runs
// under mf.mu; individual rewrite failures are skipped (logged, never
// fatal). The tolerant compile is safe here only because the pattern
// lists are init-time only (memory_files_init owns the clones) and
// memory_rename's writeable checks already refused on any uncompilable
// pattern before the first filesystem touch.
memory_propagate_rename_locked :: proc(mf: ^Memory_Files, old_name, new_name: string, a: mem.Allocator) -> int {
	ro_set, _, _ := memory.pattern_set_compile(mf.read_only, context.temp_allocator)
	defer memory.pattern_set_destroy(&ro_set)
	ig_set, _, _ := memory.pattern_set_compile(mf.ignored, context.temp_allocator)
	defer memory.pattern_set_destroy(&ig_set)

	list := memory_list_all_locked(mf, &ro_set, &ig_set, a)
	defer memory_list_names_destroy(list, a)

	count := 0
	for name in list {
		if name == old_name || name == new_name {
			continue
		}
		if memory.pattern_set_match(&ro_set, name) || memory.pattern_set_match(&ig_set, name) {
			continue
		}
		abs, _, perr := memory_path(mf, name, a)
		if perr != nil {
			continue
		}
		data, rerr := os.read_entire_file_from_path(abs, context.temp_allocator)
		if rerr != nil {
			continue
		}
		content := string(data)
		if !memory.has_reference(content, old_name) {
			continue
		}
		updated, refs := memory.rewrite_references(content, old_name, new_name, a)
		if refs == 0 {
			continue
		}
		if werr := memory_write_atomic(abs, updated); werr != nil {
			delete(updated, a)
			continue
		}
		delete(updated, a)
		count += 1
	}
	return count
}

// memory_edit applies one literal/regex replacement to a memory through
// the shared content replacer (multiline matching, $!N backreferences).
memory_edit :: proc(
	mf: ^Memory_Files,
	name: string,
	needle: string,
	repl: string,
	mode: regex.Replace_Mode,
	allow_multiple: bool,
	a: mem.Allocator,
) -> platform.Err {
	if werr := memory_check_writeable(mf, name, a); werr != nil {
		return werr
	}
	abs, _, perr := memory_path(mf, name, a)
	if perr != nil {
		return perr
	}

	sync.mutex_lock(&mf.mu)
	defer sync.mutex_unlock(&mf.mu)

	if _, _, sok := util.stat_kind_size(abs); !sok {
		return platform.Wrapped{
			kind = .NotFound,
			msg  = strings.concatenate({"memory ", name, " not found"}, a),
		}
	}
	data, rerr := os.read_entire_file_from_path(abs, context.temp_allocator)
	if rerr != nil {
		return platform.Wrapped{
			kind = .Invalid,
			msg  = strings.concatenate({"read memory ", name, " failed"}, a),
		}
	}

	cr: regex.Content_Replacer
	regex.content_replacer_init(&cr, mode, allow_multiple)
	updated, cerr := regex.content_replace(&cr, string(data), needle, repl, a)
	if cerr != nil {
		return cerr
	}
	defer delete(updated, a)
	return memory_write_atomic(abs, updated)
}

// ---------------------------------------------------------------------------
// Atomic write (temp + fsync + rename + dir sync)
// ---------------------------------------------------------------------------

// memory_write_atomic publishes one memory file durably through the
// shared atomic writer. The temp name is stable (not unique): every
// mutating memory op holds mf.mu, so no two writers race on one path.
memory_write_atomic :: proc(path: string, content: string) -> platform.Err {
	return platform.atomic_write(path, transmute([]u8)content, MEMORY_FILE_PERMS)
}

// ---------------------------------------------------------------------------
// Listing
// ---------------------------------------------------------------------------

// memory_topic_valid rejects path-shaped topics before they reach the walk
// join: every '/'-separated segment must be non-empty and free of dot
// components (the memory name validators enforce the same for read/write;
// an unvalidated topic walked out of the root through filepath.join's
// clean of ".." segments).
memory_topic_valid :: proc(topic: string) -> bool {
	if topic == "" {
		return true // the list-everything case
	}
	start := 0
	for i := 0; i <= len(topic); i += 1 {
		if i < len(topic) && topic[i] != '/' {
			continue
		}
		seg := topic[start:i]
		if seg == "" || seg == "." || seg == ".." {
			return false
		}
		start = i + 1
	}
	return true
}

// memory_list collects the memories under one topic: a "global/..."
// topic lists global memories under that subtopic; any other topic
// lists project memories under it; an empty topic lists both roots.
// Classification (read-only buckets, ignored skipping) uses the merged
// patterns. Path-shaped topics (empty segments, "." or "..") are
// rejected — the walk joins the topic onto its root and must not leave it.
memory_list :: proc(mf: ^Memory_Files, topic: string, a: mem.Allocator) -> (memory.Memories_List, platform.Err) {
	if !memory_topic_valid(topic) {
		return {}, platform.Err(.Invalid)
	}
	// A dropped ignored pattern would leak protected names into the
	// listing; a dropped read-only pattern misclassifies the buckets —
	// refuse on uncompilable patterns like the write gates do.
	ro_set, roerr := gate_set_compile(mf.read_only, "read_only_memory_patterns", a)
	defer memory.pattern_set_destroy(&ro_set)
	if roerr != nil {
		return {}, roerr
	}
	ig_set, igerr := gate_set_compile(mf.ignored, "ignored_memory_patterns", a)
	defer memory.pattern_set_destroy(&ig_set)
	if igerr != nil {
		return {}, igerr
	}

	out: memory.Memories_List
	memory.memories_list_init(&out, a)

	if topic != "" && memory.is_global_name(topic) {
		subtopic := ""
		if idx := strings.index(topic, "/"); idx >= 0 {
			subtopic = topic[idx + 1:]
		}
		memory_walk_dir(mf, &out, mf.global_dir, subtopic, memory.GLOBAL_PREFIX, &ro_set, &ig_set, 0)
		return out, nil
	}
	memory_walk_dir(mf, &out, mf.project_dir, topic, "", &ro_set, &ig_set, 0)
	if topic == "" {
		memory_walk_dir(mf, &out, mf.global_dir, "", memory.GLOBAL_PREFIX, &ro_set, &ig_set, 0)
	}
	memory.memories_list_sort(&out)
	return out, nil
}

// memory_list_all_locked gathers every non-ignored memory name (both
// roots, read-only included) — the rename propagation input.
memory_list_all_locked :: proc(
	mf: ^Memory_Files,
	ro_set: ^memory.Pattern_Set,
	ig_set: ^memory.Pattern_Set,
	a: mem.Allocator,
) -> []string {
	out: memory.Memories_List
	memory.memories_list_init(&out, a)
	memory_walk_dir(mf, &out, mf.project_dir, "", "", ro_set, ig_set, 0)
	memory_walk_dir(mf, &out, mf.global_dir, "", memory.GLOBAL_PREFIX, ro_set, ig_set, 0)

	names := make([]string, len(out.memories) + len(out.read_only_memories), a)
	i := 0
	for n in out.memories {
		names[i] = strings.clone(n, a)
		i += 1
	}
	for n in out.read_only_memories {
		names[i] = strings.clone(n, a)
		i += 1
	}
	memory.memories_list_destroy(&out)
	return names
}

memory_list_names_destroy :: proc(names: []string, a: mem.Allocator) {
	for n in names {
		if n != "" {
			delete(n, a)
		}
	}
	if names != nil {
		delete(names, a)
	}
}

// memory_walk_dir recursively collects .md files under
// base_dir/<subtopic>, naming them prefix + relative-path-minus-.md.
// Symlinks and special files are never followed; ignored names are
// skipped; depth is bounded. All scratch lives on the temp allocator;
// collected names are cloned onto the list's own allocator.
memory_walk_dir :: proc(
	mf: ^Memory_Files,
	out: ^memory.Memories_List,
	base_dir: string,
	subtopic: string,
	prefix: string,
	ro_set: ^memory.Pattern_Set,
	ig_set: ^memory.Pattern_Set,
	depth: int,
) {
	if depth > MEMORY_WALK_MAX_DEPTH {
		return
	}
	search := base_dir
	if subtopic != "" {
		search, _ = filepath.join({base_dir, subtopic}, context.temp_allocator)
	}
	entries, derr := os.read_all_directory_by_path(search, context.temp_allocator)
	if derr != nil {
		return
	}
	sort_entries_by_name(entries)

	for i in 0..<len(entries) {
		name := entries[i].name
		#partial switch entries[i].type {
		case .Directory:
			child := name
			if subtopic != "" {
				child = strings.concatenate({subtopic, "/", name}, context.temp_allocator)
			}
			memory_walk_dir(mf, out, base_dir, child, prefix, ro_set, ig_set, depth + 1)
		case .Regular:
			if !strings.has_suffix(name, memory.MEMORY_SUFFIX) {
				continue
			}
			rel := strings.trim_suffix(name, memory.MEMORY_SUFFIX)
			if subtopic != "" {
				rel = strings.concatenate({subtopic, "/", rel}, context.temp_allocator)
			}
			memory_name := rel
			if prefix != "" {
				memory_name = strings.concatenate({prefix, rel}, context.temp_allocator)
			}
			if memory.pattern_set_match(ig_set, memory_name) {
				continue
			}
			memory.memories_list_add(out, memory_name, memory.pattern_set_match(ro_set, memory_name))
		case: // symlinks and special files are not followed
		}
	}
	os.file_info_slice_delete(entries, context.temp_allocator)
}
