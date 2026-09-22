// Shadow git driven through the git CLI: an isolated repository under
// <home>/snapshot/<projectID> tracks the workspace state. The repository is
// the git directory; the user's project directory is the work tree, wired
// through GIT_WORK_TREE on the commands that need it. Every operation holds
// the mutex for its whole git conversation and runs under a hard timeout —
// a wedged git never pins a daemon worker forever.
package shadow

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

import "src:config"
import "src:platform"
import "src:safety"
import "src:util"

SHADOW_OP_TIMEOUT_MS :: 60_000
MAX_GIT_OUTPUT_BYTES :: 50 * 1024 * 1024
MAX_SNAPSHOTS_LOGGED :: 500

AUTHOR_NAME :: "Aubade Shadow"
AUTHOR_EMAIL :: "shadowgit@aubade.local"

Shadow_Git :: struct {
	repo_dir:     string, // owned by the daemon allocator
	workspace_dir: string, // owned by the daemon allocator
	// The managed state directory's spelling inside the workspace (""
	// when the folder template places it outside the tree): the snapshot
	// walk must never track the daemon's own state, so repo init excludes
	// it. Owned by the daemon allocator.
	managed_exclude: string,
	// The environment snapshot every git invocation carries: the process
	// environment at init plus GIT_CONFIG_NOSYSTEM=1. Built once — each
	// invocation previously cloned the whole environment string-by-string
	// just to append one variable. The strings are shadow-owned; a call's
	// env array only copies the headers.
	env_base:      []string,
	mu:            sync.Mutex,
	has_head:      bool,
}

// shadow_init validates the inputs and records the paths. The repository
// lives at <home>/snapshot/<projectID> where the id is the platform
// project id of the workspace (the daemon-directory identity); the
// repository itself is created by shadow_repo_init.
shadow_init :: proc(
	s: ^Shadow_Git,
	home, workspace_dir: string,
	a := context.allocator,
) -> platform.Err {
	if len(home) == 0 {
		return err_new(.Internal, "shadowgit: dataDir must not be empty")
	}
	if len(workspace_dir) == 0 {
		return err_new(.Internal, "shadowgit: workspaceDir must not be empty")
	}
	id := platform.project_id(workspace_dir, a)
	parts := []string{home, "snapshot", id}
	snapshot_dir, jerr := filepath.join(parts, a)
	delete(id, a)
	if jerr != nil || snapshot_dir == "" {
		return err_new(.Internal, "shadowgit: path join failed")
	}
	s.repo_dir = snapshot_dir
	s.workspace_dir = strings.clone(workspace_dir, a)
	s.has_head = false
	// The managed state directory (global folder template) stays out of
	// snapshots: exclude its in-tree spelling — a template placing it
	// outside the workspace needs no exclusion (the walk never sees it).
	if rel, ok := platform.strip_root_prefix(config.managed_dir_for_root(workspace_dir, home, context.temp_allocator), workspace_dir); ok && rel != "" {
		s.managed_exclude = strings.clone(rel, a)
	}
	// The env snapshot (see Shadow_Git.env_base): os.environ's clones are
	// taken over verbatim, the guard variable appended as its own clone
	// (a bare literal would be static data — freeing it later would be a
	// bad free).
	env_out, _ := os.environ(a)
	base := make([]string, len(env_out) + 1, a)
	for i in 0..<len(env_out) {
		base[i] = env_out[i]
	}
	base[len(env_out)] = strings.clone("GIT_CONFIG_NOSYSTEM=1", a)
	s.env_base = base
	delete(env_out, a)
	return nil
}

shadow_destroy :: proc(s: ^Shadow_Git, a := context.allocator) {
	if s.repo_dir != "" {
		delete(s.repo_dir, a)
	}
	if s.workspace_dir != "" {
		delete(s.workspace_dir, a)
	}
	if s.managed_exclude != "" {
		delete(s.managed_exclude, a)
	}
	for e in s.env_base {
		delete(e, a)
	}
	if s.env_base != nil {
		delete(s.env_base, a)
	}
	s^ = {}
}

// shadow_repo_init creates the git directory and pins the shadow author.
// A repository removed on disk is simply re-initialized.
shadow_repo_init :: proc(s: ^Shadow_Git, a := context.allocator) -> platform.Err {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)

	// An existing directory is the restart case (every daemon after the
	// first finds the repository already created): only a genuine
	// creation failure refuses — make_directory_all reports EEXIST for
	// the success path here.
	if err := os.make_directory_all(s.repo_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}); err != nil {
		if !os.exists(s.repo_dir) {
			return err_new(.Internal, "shadowgit init: mkdir failed")
		}
	}
	if out, gerr := git(s, nil, nil, context.temp_allocator, "init"); gerr != nil {
		return err_new(.Internal, err_with_output("shadowgit init", out, a))
	}
	if out, gerr := git(s, nil, nil, context.temp_allocator, "config", "user.email", AUTHOR_EMAIL); gerr != nil {
		return err_new(.Internal, err_with_output("shadowgit config", out, a))
	}
	if out, gerr := git(s, nil, nil, context.temp_allocator, "config", "user.name", AUTHOR_NAME); gerr != nil {
		return err_new(.Internal, err_with_output("shadowgit config", out, a))
	}
	// The daemon's own project state (the managed directory: the SQLite
	// index and machine-owned config) is not user workspace, and tracking
	// it would poison every later restore — the write gate refuses the
	// managed paths, so a snapshot containing its own state file can never
	// be restored. info/exclude keeps the directory out of add/status/diff
	// alike; the rewrite is idempotent on the restart path.
	exclude_dir, xerr := filepath.join({s.repo_dir, ".git", "info"}, context.temp_allocator)
	if xerr != nil {
		return err_new(.Internal, "shadowgit init: exclude path join failed")
	}
	if merr := os.make_directory_all(exclude_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}); merr != nil && !os.exists(exclude_dir) {
		return err_new(.Internal, "shadowgit init: exclude dir failed")
	}
	exclude_path, perr := filepath.join({exclude_dir, "exclude"}, context.temp_allocator)
	if perr != nil {
		return err_new(.Internal, "shadowgit init: exclude path join failed")
	}
	exclude_entry := platform.MANAGED_DIR_NAME
	if s.managed_exclude != "" {
		exclude_entry = s.managed_exclude
	}
	if werr := os.write_entire_file_from_string(exclude_path, strings.concatenate({exclude_entry, "/\n"}, context.temp_allocator)); werr != nil {
		return err_new(.Internal, "shadowgit init: exclude write failed")
	}
	return nil
}

// shadow_snapshot records the workspace state as a commit and returns the
// commit hash. An unchanged workspace returns the current HEAD without
// creating an empty commit.
shadow_snapshot :: proc(s: ^Shadow_Git, message: string, token: ^platform.Cancel_Token = nil, a := context.allocator) -> (string, platform.Err) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)

	msg := message
	if msg == "" {
		msg = "snapshot"
	}
	if out, gerr := git_work_tree(s, token, "add", "--all"); gerr != nil {
		return "", git_fail_with_output(gerr, "shadowgit snapshot add", out, a)
	}

	if !s.has_head {
		s.has_head = true
		hash, err := snapshot_commit(s, msg, token, a, initial = true)
		if err != nil {
			s.has_head = false
			return "", err
		}
		return hash, nil
	}
	// diff --cached --quiet exits zero when nothing is staged: the
	// workspace matches HEAD, so HEAD is the snapshot.
	if _, gerr := git(s, nil, token, a, "diff", "--cached", "--quiet"); gerr == nil {
		return head_hash(s, token, a)
	}
	return snapshot_commit(s, msg, token, a, initial = false)
}

snapshot_commit :: proc(s: ^Shadow_Git, message: string, token: ^platform.Cancel_Token, a := context.allocator, initial: bool) -> (string, platform.Err) {
	prefix := "shadowgit snapshot commit"
	if initial {
		prefix = "shadowgit snapshot initial commit"
	}
	out, gerr := git(s, nil, token, a, "commit", "--allow-empty", "-m", message)
	if gerr != nil {
		defer delete(out, a) // the error text excerpts it; both paths release it
		return "", git_fail_with_output(gerr, prefix, out, a)
	}
	delete(out, a)
	return head_hash(s, token, a)
}

// shadow_patch lists the files changed between two tree hashes.
shadow_patch :: proc(s: ^Shadow_Git, from, to: string, token: ^platform.Cancel_Token = nil, a := context.allocator) -> ([]string, platform.Err) {
	if err := validate_hash(from, a); err != nil {
		return nil, err
	}
	if err := validate_hash(to, a); err != nil {
		return nil, err
	}
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)

	// -z like shadow_files_at: quotePath C-escapes non-ASCII and special
	// characters in the default --name-only output, and paths containing
	// newlines would split wrong.
	out, gerr := git(s, nil, token, a, "diff", "--name-only", "-z", from, to)
	if gerr != nil {
		defer delete(out, a) // git() hands back its output on error paths too
		return nil, git_fail(gerr, "shadowgit patch: git diff --name-only failed")
	}
	return split_nul(out, a), nil
}

// shadow_diff returns the unified diff between two tree hashes.
shadow_diff :: proc(s: ^Shadow_Git, from, to: string, token: ^platform.Cancel_Token = nil, a := context.allocator) -> (string, platform.Err) {
	if err := validate_hash(from, a); err != nil {
		return "", err
	}
	if err := validate_hash(to, a); err != nil {
		return "", err
	}
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)

	out, gerr := git(s, nil, token, a, "diff", from, to)
	if gerr != nil {
		delete(out, a)
		return "", git_fail(gerr, "shadowgit diff: git diff failed")
	}
	diff := strings.clone(out, a)
	delete(out, a)
	return diff, nil
}

// shadow_files_at lists the tracked file paths a restore to `hash` would
// write over the workspace — the set the restore gate checks before any
// rewrite runs. NUL-separated (-z) so odd path spellings stay exact; the
// paths borrow the ls-tree output buffer, which rides `a`.
shadow_files_at :: proc(s: ^Shadow_Git, hash: string, token: ^platform.Cancel_Token = nil, a := context.allocator) -> ([]string, platform.Err) {
	if err := validate_hash(hash, a); err != nil {
		return nil, err
	}
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	return files_at_unlocked(s, hash, token, a)
}

// files_at_unlocked is shadow_files_at without the mutex — shadow_restore
// calls it under the lock it already holds.
files_at_unlocked :: proc(s: ^Shadow_Git, hash: string, token: ^platform.Cancel_Token, a := context.allocator) -> ([]string, platform.Err) {
	out, gerr := git(s, nil, token, a, "ls-tree", "-r", "--name-only", "-z", hash)
	if gerr != nil {
		return nil, git_fail(gerr, "shadowgit files-at: ls-tree failed")
	}
	paths := make([dynamic]string, 0, 16, a)
	start := 0
	for i := 0; i <= len(out); i += 1 {
		if i == len(out) || out[i] == 0 {
			if i > start {
				append(&paths, out[start:i])
			}
			start = i + 1
		}
	}
	return paths[:], nil
}

// shadow_restore resets the workspace to the state captured by the hash:
// the index is re-read, every tracked file is checked out over the work
// tree, and files unknown to the snapshot are removed. The whole rewrite
// set passes the workspace gate first — every tracked path must sit
// inside the workspace, not be a symlink, and none of its intermediate
// directories may be a symlink resolving outside the workspace (the same
// policing shadow_revert_file applies to its single path): checkout-index
// writes through a symlink that has come to point outside the root, and a
// tree entry spelling an escape writes outside it. The refusal names the
// offending paths (first five) before anything is written.
shadow_restore :: proc(s: ^Shadow_Git, hash: string, token: ^platform.Cancel_Token = nil, a := context.allocator) -> platform.Err {
	if err := validate_hash(hash, a); err != nil {
		return err
	}
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)

	paths, ferr := files_at_unlocked(s, hash, token, context.temp_allocator)
	if ferr != nil {
		return ferr
	}
	bad_total := 0
	offenders := make([dynamic]string, 0, 4, a)
	// The per-path intermediate resolution below walks against the root's
	// resolved spelling, computed once here.
	root_resolved := safety.pathguard_resolve_root(s.workspace_dir, context.temp_allocator)
	for p in paths {
		abs, ok := contained_rel(s.workspace_dir, p, context.temp_allocator)
		is_symlink := false
		if ok {
			if kind, kok := util.lstat_kind(abs); kok && kind == .Symlink {
				is_symlink = true
			}
		}
		if ok && !is_symlink && resolves_inside_workspace(root_resolved, p, context.temp_allocator) {
			continue
		}
		bad_total += 1
		if len(offenders) < 5 {
			append(&offenders, strings.clone(p, a))
		}
	}
	if bad_total > 0 {
		joined, _ := strings.join(offenders[:], ", ", a)
		msg := strings.concatenate({
			"restore refused: ", util.int_to_dec(bad_total, a),
			" tracked path(s) fail the workspace gate: ", joined,
		}, a)
		if bad_total > 5 {
			msg = strings.concatenate({msg, " (and ", util.int_to_dec(bad_total - 5, a), " more)"}, a)
		}
		delete(joined, a)
		for o in offenders {
			delete(o, a)
		}
		delete(offenders)
		return err_new(.Denied, msg)
	}
	delete(offenders)

	rt_out, rt_err := git(s, nil, token, a, "read-tree", "--reset", hash)
	if rt_err != nil {
		defer delete(rt_out, a)
		return git_fail_with_output(rt_err, "shadowgit restore read-tree", rt_out, a)
	}
	delete(rt_out, a)
	if out, gerr := git_work_tree(s, token, "checkout-index", "-a", "-f"); gerr != nil {
		return git_fail_with_output(gerr, "shadowgit restore checkout-index", out, a)
	}
	if out, gerr := git_work_tree(s, token, "clean", "-fd"); gerr != nil {
		return git_fail_with_output(gerr, "shadowgit restore clean", out, a)
	}
	return nil
}

// shadow_revert_file restores one file to its state at the hash. A file
// that did not exist at that hash is removed from the workspace instead.
shadow_revert_file :: proc(s: ^Shadow_Git, hash, file_path: string, token: ^platform.Cancel_Token = nil, a := context.allocator) -> platform.Err {
	if err := validate_hash(hash, a); err != nil {
		return err
	}
	if file_path == "" || file_path == "." || file_path == "/" || file_path == "\\" {
		return err_new(.Invalid, "shadowgit revert-file: empty or root filePath not allowed")
	}
	rel, ok := contained_rel(s.workspace_dir, file_path, context.temp_allocator)
	if !ok {
		return err_new(.Invalid, strings.concatenate(
			{"shadowgit revert-file: path escapes workspace: ", file_path}, a,
		))
	}
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)

	if kind, kok := util.lstat_kind(rel); kok && kind == .Symlink {
		return err_new(.Denied, strings.concatenate(
			{"refusing to operate on symlink: ", file_path}, a,
		))
	}
	// Intermediate components get the same policing: a symlinked parent
	// directory passes the leaf lstat above (the stat follows the link),
	// and a checkout through it writes outside the workspace.
	root_resolved := safety.pathguard_resolve_root(s.workspace_dir, context.temp_allocator)
	if !resolves_inside_workspace(root_resolved, file_path, context.temp_allocator) {
		return err_new(.Denied, strings.concatenate(
			{"refusing to operate through a symlinked directory: ", file_path}, a,
		))
	}

	out, gerr := git(s, nil, token, a, "ls-tree", hash, "--", file_path)
	if gerr != nil {
		defer delete(out, a) // git() hands back its output on error paths too
		return git_fail(gerr, "shadowgit revert-file ls-tree failed")
	}
	defer delete(out, a)
	if strings.trim_space(out) == "" {
		if rerr := os.remove(rel); rerr != nil {
			// A file that vanished between the lstat and the remove is
			// success (it is gone, which is the goal); anything else
			// still present is a real failure.
			if _, still := util.lstat_kind(rel); still {
				return err_new(.Internal, "shadowgit revert-file remove failed")
			}
		}
		return nil
	}
	if cout, cerr := git_work_tree(s, token, "checkout", hash, "--", file_path); cerr != nil {
		// Discriminate on cerr — gerr is the ls-tree error consumed above
		// and is always the zero union here, whose err_kind reads .Internal
		// (flattening every cancellation/deadline into Internal and
		// dropping the typed kind entirely).
		return platform.err_kind(cerr) == .Internal ? err_new(.Internal, err_with_output("shadowgit revert-file checkout", cout, a)) : cerr
	}
	return nil
}

// shadow_log returns the newest-first commit hashes (at most n, capped at
// 500).
shadow_log :: proc(s: ^Shadow_Git, n: int, token: ^platform.Cancel_Token = nil, a := context.allocator) -> ([]string, platform.Err) {
	count := n
	if count < 0 {
		count = 0
	}
	if count > MAX_SNAPSHOTS_LOGGED {
		count = MAX_SNAPSHOTS_LOGGED
	}
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)

	out, gerr := git(s, nil, token, a, "log", log_limit_flag(count, context.temp_allocator), "--format=%H")
	if gerr != nil {
		defer delete(out, a) // git() hands back its output on error paths too
		return nil, git_fail(gerr, "shadowgit log: git log failed")
	}
	return split_lines(out, a), nil
}

// --- internals ---------------------------------------------------------------

head_hash :: proc(s: ^Shadow_Git, token: ^platform.Cancel_Token, a := context.allocator) -> (string, platform.Err) {
	out, gerr := git(s, nil, token, a, "rev-parse", "HEAD")
	if gerr != nil {
		delete(out, a)
		return "", git_fail(gerr, "shadowgit snapshot rev-parse failed")
	}
	hash := strings.clone(strings.trim_space(out), a)
	delete(out, a)
	return hash, nil
}

log_limit_flag :: proc(n: int, a := context.allocator) -> string {
	digits := util.int_to_dec(n, a)
	flag := strings.concatenate({"-", digits}, a)
	delete(digits, a)
	return flag
}

// git runs one git command in the repository directory; `extra_env`
// entries are appended to the inherited environment. The combined output
// (stdout, then stderr when present) is allocated from `a` and owned by
// the caller — the request arena in the daemon, freed when it dies.
git :: proc(s: ^Shadow_Git, extra_env: []string, token: ^platform.Cancel_Token = nil, a := context.allocator, args: ..string) -> (string, platform.Err) {
	// The token is the cancellation checkpoint: a fired token refuses
	// before the child spawns, and a deadline derives a tighter procrun
	// timeout than the 60 s safety cap.
	if token != nil {
		if _, fired := platform.token_check(token); fired {
			return "", err_new(.Cancelled, "shadowgit: operation cancelled")
		}
	}
	op_timeout := i64(SHADOW_OP_TIMEOUT_MS)
	if token != nil && token.deadline > 0 {
		// Real-time read by design (same stance as slot_wait): token
		// deadlines are mono-domain absolute timestamps, and this layer
		// holds no injected clock to re-read one — in production the two
		// sources are identical.
		remaining := token.deadline - platform.mono_ms()
		if remaining <= 0 {
			return "", err_new(.Timeout, "shadowgit: operation deadline already passed")
		}
		if remaining < op_timeout {
			op_timeout = remaining
		}
	}
	command := make([dynamic]string, 0, 1 + len(args), a)
	append(&command, "git")
	for arg in args {
		append(&command, arg)
	}

	// Headers only: the environment strings live in the shadow's snapshot
	// (Shadow_Git.env_base), so a call's array just copies the slice
	// headers and appends this call's extras (owned by the caller's `a`).
	env := make([dynamic]string, 0, len(s.env_base) + len(extra_env), a)
	for e in s.env_base {
		append(&env, e)
	}
	for e in extra_env {
		append(&env, e)
	}

	res, err := platform.procrun(platform.Procrun_Opts {
		command          = command[:],
		working_dir      = s.repo_dir,
		env              = env[:],
		capture_stderr   = true,
		max_stream_bytes = MAX_GIT_OUTPUT_BYTES,
		timeout_ms       = op_timeout,
	}, a)
	delete(command)
	delete(env)
	combined := res.stdout
	if res.stderr != "" {
		combined = strings.concatenate({res.stdout, "\n", res.stderr}, a)
		delete(res.stdout, a)
		delete(res.stderr, a)
	}
	if err != nil {
		return combined, err_new(.Internal, err_with_output("shadowgit git", combined, a))
	}
	if res.timed_out {
		// procrun has reaped the killed git by return, so the repository
		// is definitively idle again — drop the stale index lock a killed
		// index-writing git leaves behind, or every later operation on
		// this daemon-private repository fails until it is removed by
		// hand. Best-effort: a removal failure surfaces through the next
		// operation's error text.
		shadow_remove_stale_index_lock(s)
		return combined, err_new(.Timeout, err_with_output("shadowgit git timed out", combined, a))
	}
	if token != nil {
		if _, fired := platform.token_check(token); fired {
			return combined, err_new(.Cancelled, "shadowgit: operation cancelled")
		}
	}
	if res.exit_code != 0 {
		return combined, err_new(.Internal, err_with_output("shadowgit git", combined, a))
	}
	return combined, nil
}

git_work_tree :: proc(s: ^Shadow_Git, token: ^platform.Cancel_Token = nil, args: ..string) -> (string, platform.Err) {
	// The work-tree export and the captured output are both scratch:
	// callers only read them inside their own frame for error text.
	return git(s, work_tree_env(s, context.temp_allocator), token, context.temp_allocator, ..args)
}

work_tree_env :: proc(s: ^Shadow_Git, a := context.allocator) -> []string {
	env := make([dynamic]string, 0, 1, a)
	append(&env, strings.concatenate({"GIT_WORK_TREE=", s.workspace_dir}, a))
	return env[:]
}

shadow_remove_stale_index_lock :: proc(s: ^Shadow_Git) {
	lock_path, jerr := filepath.join({s.repo_dir, ".git", "index.lock"}, context.temp_allocator)
	if jerr != nil {
		return
	}
	_ = os.remove(lock_path)
}

// split_lines consumes `out` (the git result — both call sites hand over
// their only reference) and returns the non-empty trimmed lines, each
// cloned on `a`.
split_lines :: proc(out: string, a := context.allocator) -> []string {
	raw := strings.trim_space(out) // view into out — never freed directly
	if raw == "" {
		delete(out, a)
		return nil
	}
	lines := strings.split(raw, "\n")
	owned := make([]string, len(lines), a)
	for i in 0..<len(lines) {
		owned[i] = strings.clone(lines[i], a)
	}
	delete(lines)
	delete(out, a) // the allocation's owner (head_hash uses the same shape)
	return owned
}

// split_nul consumes `out` (git -z output: NUL-terminated, unquoted) and
// returns the non-empty paths, each cloned on `a`. -z output carries no
// trailing newline and no quotePath escaping, so every path spelling stays
// exact.
split_nul :: proc(out: string, a := context.allocator) -> []string {
	paths := make([dynamic]string, 0, 16, a)
	start := 0
	for i := 0; i <= len(out); i += 1 {
		if i == len(out) || out[i] == 0 {
			if i > start {
				append(&paths, strings.clone(out[start:i], a))
			}
			start = i + 1
		}
	}
	delete(out, a)
	return paths[:]
}

// contained_rel resolves file_path inside the workspace and returns the
// absolute path when it stays there. The result is scratch memory.
contained_rel :: proc(workspace, file_path: string, a := context.allocator) -> (string, bool) {
	parts := []string{workspace, file_path}
	abs, jerr := filepath.join(parts, a)
	if jerr != nil || abs == "" {
		return "", false
	}
	clean, cerr := filepath.clean(abs, a)
	delete(abs, a)
	if cerr != nil || !filepath.is_abs(clean) {
		delete(clean, a)
		return "", false
	}
	contained := false
	if len(clean) > len(workspace) {
		// Normalise both sides to forward slashes so the containment
		// check works on Windows where filepath.clean uses backslashes.
		clean_slash, _ := strings.replace_all(clean, "\\", "/", context.temp_allocator)
		ws_slash, _ := strings.replace_all(workspace, "\\", "/", context.temp_allocator)
		if len(ws_slash) > 0 && ws_slash[len(ws_slash) - 1] == '/' {
			contained = clean_slash[:len(ws_slash)] == ws_slash
		} else {
			contained = clean_slash[:len(ws_slash) + 1] == strings.concatenate(
				{ws_slash, "/"}, context.temp_allocator,
			)
		}
	}
	if !contained {
		delete(clean, a)
		return "", false
	}
	return clean, true
}

// resolves_inside_workspace reports whether the path's existing components
// all resolve inside the workspace: a symlinked intermediate directory
// passes the lexical containment and the leaf lstat (the stat follows the
// directory link), and a checkout through such a link would write outside
// the root. Resolution runs against the root's resolved spelling, so the
// workspace's own symlinked components (macOS /var -> /private/var) are
// canonical, not escapes.
resolves_inside_workspace :: proc(root_resolved, file_path: string, a := context.allocator) -> bool {
	resolved, perr := safety.pathguard_validate_contained_resolved(root_resolved, file_path, a)
	if perr.reason != "" {
		return false
	}
	delete(resolved, a)
	return true
}

validate_hash :: proc(hash: string, a := context.allocator) -> platform.Err {
	// 7 = git's shortest unambiguous abbreviation; 40/64 = the full sha1
	// and sha256 object ids. The shadow repo inherits the user's
	// init.defaultObjectFormat, so both lengths are native here. The
	// charset check below is the injection guard; this bounds only length.
	if len(hash) < 7 || len(hash) > 64 {
		return hash_err(hash, a)
	}
	for i in 0..<len(hash) {
		// Hashes arrive as ASCII hex; anything else is rejected before it
		// can reach a git command line.
		c := hash[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return hash_err(hash, a)
		}
	}
	return nil
}

hash_err :: proc(hash: string, a := context.allocator) -> platform.Err {
	return err_new(.Invalid, strings.concatenate({"invalid git hash: ", hash}, a))
}

// err_new builds the error value in place. platform.Err is a value
// union, so the heap copy the pointer version made was a pure leak.
err_new :: proc(kind: platform.Err_Kind, msg: string) -> platform.Err {
	w := platform.Wrapped{kind = kind, msg = msg}
	return w
}

err_with_output :: proc(prefix, out: string, a := context.allocator) -> string {
	trimmed := strings.trim_space(out)
	if len(trimmed) > 200 {
		trimmed = trimmed[:200]
	}
	if trimmed == "" {
		return prefix
	}
	return strings.concatenate({prefix, ": ", trimmed}, a)
}

// git_fail maps a failed git invocation onto the boundary error: every
// non-internal kind (cancellation, timeout, ...) crosses as itself, and
// only a plain internal failure is rewrapped with `msg` for context.
git_fail :: proc(gerr: platform.Err, msg: string) -> platform.Err {
	if platform.err_kind(gerr) == .Internal {
		return err_new(.Internal, msg)
	}
	return gerr
}

// git_fail_with_output is git_fail with the command output excerpted
// into the message (err_with_output bounds the excerpt).
git_fail_with_output :: proc(gerr: platform.Err, prefix, out: string, a := context.allocator) -> platform.Err {
	if platform.err_kind(gerr) == .Internal {
		return err_new(.Internal, err_with_output(prefix, out, a))
	}
	return gerr
}
