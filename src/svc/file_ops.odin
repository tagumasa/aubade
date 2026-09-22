// The file svc face: method names plus the daemon-side file operations
// behind them. Buffer-backed reads and edits run through the editor
// (snapshot discipline, project encoding and line endings); the direct-FS
// ops (write/delete/move) validate through the path guard and keep open
// buffers coherent by dropping them; list/find/search share the
// gitignore-aware project walk with the symbol crawl.
package svc

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:sort"
import "core:strings"
import "core:sync"
import "src:config"
import "src:editor"
import "src:pathspec"
import "src:platform"
import "src:regex"
import "src:safety"
import "src:util"

METHOD_FILE_READ :: "svc.file/read" // {relative_path, start_line?, end_line?, max_answer_chars?} -> {content, read_ask, truncated, total_chars}
METHOD_FILE_WRITE :: "svc.file/write" // {relative_path, content} -> {overwrote}
METHOD_FILE_LIST_DIR :: "svc.file/list_dir" // {relative_path, recursive?, skip_ignored_files?, include_line_counts?} -> {dirs, files, truncated}
METHOD_FILE_FIND :: "svc.file/find" // {file_mask, relative_path?} -> {files, truncated}
METHOD_FILE_SEARCH :: "svc.file/search" // File_Search_Req shape -> {matches, total_matches, truncated}
METHOD_FILE_OUTLINE :: "svc.file/outline" // {relative_path, path?, max_answer_chars?} -> {content, mode, start_line, end_line, truncated, read_ask}
METHOD_FILE_REPLACE :: "svc.file/replace" // {relative_path, needle, repl, mode, allow_multiple_occurrences?} -> {}
METHOD_FILE_INSERT_LINES :: "svc.file/insert_lines" // {relative_path, line, content} -> {}
METHOD_FILE_REPLACE_LINES :: "svc.file/replace_lines" // {relative_path, start_line, end_line, content} -> {}
METHOD_FILE_DELETE_LINES :: "svc.file/delete_lines" // {relative_path, start_line, end_line} -> {}
METHOD_FILE_DELETE :: "svc.file/delete" // {relative_path} -> {}
METHOD_FILE_MOVE :: "svc.file/move" // {source_relative_path, target_relative_path} -> {}

FILE_WALK_MAX_DEPTH :: 100 // matches the symbol crawl bound
FILE_WALK_MAX_FILES :: 5000 // walk file budget: bounds list/find/search work
FILE_LIST_MAX_ENTRIES :: 20000 // combined dirs+files bound for one listing
FILE_SEARCH_MAX_MATCHES_PER_FILE :: 10000
BINARY_SNIFF_LEN :: 4096

// ---------------------------------------------------------------------------
// Gitignore-aware project walk
// ---------------------------------------------------------------------------

File_Walk_Kind :: enum {
	Directory,
	File,
}

File_Walk_Control :: enum {
	Continue,
	Stop,
}

// File_Walk_Visit sees every directory (before the descend decision) and
// every regular file the walk reaches, in sorted order. Returning .Stop
// aborts the whole walk. `rel` is the slash-separated project-relative
// path and `abs` the joined absolute path; both borrow the walk's internal
// buffers and are valid only for the duration of the call — a visitor that
// keeps one clones it into its own result allocator.
File_Walk_Visit :: proc(ctx: rawptr, kind: File_Walk_Kind, rel: string, abs: string) -> File_Walk_Control

// Ignore_Config is the walk-level projection of the user's ignore
// configuration: `extra` compiles the configured ignored_paths (a hard
// skip, like the built-in directory list — a .gitignore negation cannot
// re-include a configured path) and `no_gitignore` turns the per-directory
// .gitignore stacks off (ignore_all_files_in_gitignore=false). The
// built-in directory list always applies and is not configurable here.
// The zero value is exactly the walk's behavior with no ignore config.
Ignore_Config :: struct {
	extra:        ^pathspec.Path_Spec,
	no_gitignore: bool,
	// The managed state directory's project-relative spelling ("" when it
	// sits outside the project). Walks skip it by location: the folder
	// template can name it anything, so a name match would both miss a
	// relocated directory and over-ignore a same-named user directory.
	// Owned by the same allocator as `extra`'s Odin memory.
	managed_rel:  string,
}

// managed_state_rel reports whether rel is the managed state directory
// itself or inside it: the location-based skip every walk applies beside
// the builtin name list. Both spellings are project-relative with forward
// slashes; the comparison carries the filesystem's case sensitivity.
managed_state_rel :: proc(managed_rel, rel: string) -> bool {
	if managed_rel == "" {
		return false
	}
	if platform.path_equal(rel, managed_rel) {
		return true
	}
	if len(rel) <= len(managed_rel) {
		return false
	}
	if !platform.path_equal(rel[:len(managed_rel)], managed_rel) {
		return false
	}
	c := rel[len(managed_rel)]
	return c == '/' || c == '\\'
}

// ignore_config_load projects the global and project configs onto
// Ignore_Config: the project's ignored_paths extend the global list, and
// the project's gitignore gate maps to no_gitignore. `a` owns the loaded
// configs and the compiled spec's Odin memory — release the spec's C side
// with spec_release_c_side before `a` dies. Load failures degrade to
// defaults: an unreadable config must not fail the walk.
ignore_config_load :: proc(project_root, home: string, a: mem.Allocator) -> (out: Ignore_Config) {
	lines := make([dynamic]string, 0, 4, a)
	defer delete(lines)

	global, _, gerr := config.load_global(home, a)
	// load_global returns a nil config on failure; the location pointer is
	// passed only when the global actually loaded — &nil.field is a non-nil
	// offset pointer that load_project_for_root would dereference.
	global_location: ^string = nil
	if gerr == nil {
		global_location = &global.project_aubade_folder_location
		for p in global.ignored_paths {
			append(&lines, p)
		}
	} else {
		util.log_warning(strings.concatenate(
			{"ignore config: global config unreadable, using defaults: ", platform.err_message(gerr)},
		))
	}
	// The already-loaded global carries the managed-dir location — pass it
	// through instead of letting the resolver parse the global a second
	// time on every config-composing call. A nil location makes the
	// resolver degrade to the default location on its own.
	project, _, perr := config.load_project_for_root(project_root, home, a, global_location)
	if perr == nil {
		for p in project.ignored_paths {
			append(&lines, p)
		}
		out.no_gitignore = !project.ignore_all_files_in_gitignore
	} else {
		util.log_warning(strings.concatenate(
			{"ignore config: project config unreadable, using defaults: ", platform.err_message(perr)},
		))
	}
	if len(lines) > 0 {
		if spec := pathspec.from_lines(lines[:], a); spec != nil && len(spec.patterns) > 0 {
			out.extra = spec
		}
	}
	// The walk's location-based state exclusion: the managed directory's
	// rel spelling comes from the same loaded global that carried the
	// ignored_paths — no second parse of the global config.
	template := ""
	if global_location != nil {
		template = global_location^
	}
	out.managed_rel = config.managed_rel_for(project_root, template, a)
	return out
}

// spec_release_c_side frees only the C side of a spec whose Odin memory
// lives on a request arena or thread temp allocator: the compiled PCRE2
// code lives outside that allocator, so it needs the explicit release,
// while every Odin allocation in the spec is allocator-interior and dies
// with the allocator's free_all — freeing those here would hand arena
// pointers to the backing allocator.
spec_release_c_side :: proc(spec: ^pathspec.Path_Spec) {
	if spec == nil {
		return
	}
	for i in 0..<len(spec.patterns) {
		if spec.patterns[i].re != nil {
			regex.regex_destroy(spec.patterns[i].re)
		}
	}
}

// path_ignored answers, read-only, whether the project walk would skip
// rel_path: each directory's .gitignore scopes its subtree (deepest spec
// wins, unless the config disables gitignore) and the default-ignored
// directory names plus the configured ignored_paths always prune. The
// pieces are the walk's own — this is a question over the same policy,
// not a second one. A path whose final component names a directory is
// judged with the directory semantics (a trailing-slash match counts).
path_ignored :: proc(project_root, rel_path: string, ignore: Ignore_Config, a := context.allocator) -> bool {
	// The walk's ownership discipline: every intermediate (the normalized
	// path, the component list, the specs and their scratch) lives on one
	// arena; only the C-side regexes are released explicitly, the rest
	// dies with the arena.
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, a)
	scratch_alloc := mem.dynamic_arena_allocator(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)

	rel := normalize_rel(rel_path, scratch_alloc)
	if rel == "" {
		return false
	}
	// Aubade's own state directory is invisible to the walk wherever the
	// folder template placed it — files inside it are as skipped as the
	// directory itself.
	if managed_state_rel(ignore.managed_rel, rel) {
		return true
	}
	parts := make([dynamic]string, 0, 8, scratch_alloc)
	start := 0
	for i := 0; i <= len(rel); i += 1 {
		if i == len(rel) || rel[i] == '/' {
			if i > start {
				append(&parts, rel[start:i])
			}
			start = i + 1
		}
	}
	if len(parts) == 0 {
		return false
	}

	stack := make([dynamic]^pathspec.Path_Spec, 0, 8, scratch_alloc)
	defer {
		for spec in stack {
			spec_release_c_side(spec)
		}
		delete(stack)
	}

	// A trailing slash (or an existing directory) judges the final
	// component with the directory semantics.
	last_is_dir := len(rel_path) > 0 && rel_path[len(rel_path) - 1] == '/'
	if info, serr := os.stat(strings.concatenate({project_root, "/", rel}, scratch_alloc), context.temp_allocator); serr == nil {
		last_is_dir = info.type == .Directory
		os.file_info_delete(info, context.temp_allocator)
	}

	cur_abs := project_root
	cur_rel := ""
	if !ignore.no_gitignore {
		_ = maybe_push_gitignore(scratch_alloc, scratch_alloc, cur_abs, cur_rel, &stack)
	}
	for i := 0; i < len(parts) - 1; i += 1 {
		name := parts[i]
		if config.default_ignored_dir(name) {
			return true
		}
		child_rel := join_rel(cur_rel, name, scratch_alloc)
		if pathspec.pathspec_match_path(child_rel, ignore.extra) {
			return true
		}
		if !ignore.no_gitignore && stack_match_dir(&stack, child_rel, scratch_alloc) {
			return true
		}
		cur_rel = child_rel
		joined, jerr := filepath.join({cur_abs, name}, scratch_alloc)
		if jerr != nil {
			return false
		}
		cur_abs = joined
		if !ignore.no_gitignore {
			_ = maybe_push_gitignore(scratch_alloc, scratch_alloc, cur_abs, cur_rel, &stack)
		}
	}

	last := parts[len(parts) - 1]
	if last_is_dir {
		return config.default_ignored_dir(last) ||
			pathspec.pathspec_match_path(rel, ignore.extra) ||
			(!ignore.no_gitignore && stack_match_dir(&stack, rel, scratch_alloc))
	}
	return pathspec.pathspec_match_path(rel, ignore.extra) ||
		(!ignore.no_gitignore && stack_match_file(&stack, rel))
}

// file_walk drives `visit` over the directory start_abs (project-relative
// start_rel, "" for the project root). skip_ignored applies gitignore
// scoping (each directory's .gitignore scopes its subtree, deepest spec
// wins); ignore.extra prunes configured ignored_paths (hard skip);
// default-ignored directories are always skipped; symlinks and special
// files are never followed — the fail-closed posture shared with the
// symbol crawl. Cancellation is checked once per entry.
//
// `heap` is a durable non-arena allocator (the callers hand the editor's,
// which the daemon backs with the process allocator). It carries the
// enumeration machinery: each directory's entries are freed at the
// directory boundary, child paths build in reusable buffers, and the
// recursion's own frame data is O(depth) — so a whole-project walk's
// transient memory stays flat in the project's file count. (Placing the
// enumeration on the caller's request arena instead once scaled every
// walk's transient with the file budget, and the request arena's
// high-water rode the handling worker's allocator: request-arena memory
// is freed wholesale, so a freed directory bought nothing back.)
file_walk :: proc(
	start_abs: string,
	start_rel: string,
	recursive: bool,
	skip_ignored: bool,
	ignore: Ignore_Config,
	deny: ^safety.Deny_List,
	visit: File_Walk_Visit,
	vctx: rawptr,
	token: ^platform.Cancel_Token,
	heap: mem.Allocator,
) -> (stopped: bool) {
	stack := make([dynamic]^pathspec.Path_Spec, 0, 8, heap)
	defer {
		for i in 0..<len(stack) {
			pathspec.pathspec_destroy(stack[i])
		}
		delete(stack)
	}
	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, heap)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	walk_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&walk_arena, heap)
	defer mem.dynamic_arena_destroy(&walk_arena)
	rel_buf := make([dynamic]u8, 0, 512, heap)
	defer delete(rel_buf)
	abs_buf := make([dynamic]u8, 0, 1024, heap)
	defer delete(abs_buf)
	w := File_Walk_State{
		recursive    = recursive,
		skip_ignored = skip_ignored,
		ignore       = ignore,
		deny         = deny,
		visit        = visit,
		vctx         = vctx,
		token        = token,
		heap         = heap,
		walk         = mem.dynamic_arena_allocator(&walk_arena),
		scratch      = &scratch_arena,
		rel_buf      = &rel_buf,
		abs_buf      = &abs_buf,
	}
	if deny != nil {
		safety.deny_walk_init(&w.deny_walk, start_abs, w.walk)
	}
	return file_walk_dir(&w, start_abs, start_rel, 0, &stack)
}

// File_Walk_State is one file_walk's shared state (the crawl's Crawl_Walk
// counterpart): the visit facts plus the enumeration machinery.
// `heap` frees between boundaries (entries, specs, buffers);
// `walk` carries only the recursion's frame data — each recursing
// directory's cloned rel/abs path, O(depth); `scratch` resets at every
// directory boundary (gitignore parse and match temporaries).
File_Walk_State :: struct {
	recursive:    bool,
	skip_ignored: bool,
	ignore:       Ignore_Config,
	deny:         ^safety.Deny_List,
	visit:        File_Walk_Visit,
	vctx:         rawptr,
	token:        ^platform.Cancel_Token, // nil: no cancellation
	heap:         mem.Allocator,
	walk:         mem.Allocator,
	scratch:      ^mem.Dynamic_Arena,
	rel_buf:      ^[dynamic]u8,
	abs_buf:      ^[dynamic]u8,
	// The walk's deny-composition state (see safety.Deny_Walk): the current
	// directory's resolved spelling, mutated to the child's at every
	// recursion and restored on return. Zero-valued when deny is nil and
	// never consulted then.
	deny_walk: safety.Deny_Walk,
}

file_walk_dir :: proc(
	w: ^File_Walk_State,
	abs_dir: string,
	rel_dir: string,
	depth: int,
	stack: ^[dynamic]^pathspec.Path_Spec,
) -> (stopped: bool) {
	if depth > FILE_WALK_MAX_DEPTH {
		return false
	}
	if w.token != nil {
		if _, fired := platform.token_check(w.token); fired {
			return true
		}
	}
	mem.dynamic_arena_free_all(w.scratch)
	scratch := mem.dynamic_arena_allocator(w.scratch)

	// Entries on the heap allocator, freed at this boundary (see
	// file_walk): the peak is one directory's entries and the freed
	// blocks are reused instead of ratcheting the worker's footprint.
	entries, derr := os.read_all_directory_by_path(abs_dir, w.heap)
	if derr != nil {
		return false
	}
	defer os.file_info_slice_delete(entries, w.heap)
	sort_entries_by_name(entries)

	pushed := false
	if w.skip_ignored {
		pushed = maybe_push_gitignore(w.heap, scratch, abs_dir, rel_dir, stack)
	}

	// Child paths build into the reusable buffers at this directory's
	// watermark: a file's path is a buffer view consumed before the next
	// entry, while a recursing directory's path is cloned to the walk
	// allocator (the subtree re-seeds the buffers — and re-seeding always
	// rewrites the parent's own prefix bytes first, so truncating back to
	// the mark restores the parent's path). The root case mirrors
	// join_rel: top-level entries carry no leading slash.
	walk_buf_set(w.rel_buf, rel_dir)
	walk_buf_set(w.abs_buf, abs_dir)
	rel_mark := len(w.rel_buf^)
	abs_mark := len(w.abs_buf^)

	for i in 0..<len(entries) {
		if w.token != nil {
			if _, fired := platform.token_check(w.token); fired {
				stopped = true
				break
			}
		}
		name := entries[i].name
		if config.default_ignored_dir(name) {
			continue
		}
		if rel_mark > 0 {
			walk_buf_append(w.rel_buf, "/")
		}
		walk_buf_append(w.rel_buf, name)
		child_rel := string(w.rel_buf^[:])
		if pathspec.pathspec_match_path(child_rel, w.ignore.extra) {
			resize(w.rel_buf, rel_mark)
			continue
		}
		if managed_state_rel(w.ignore.managed_rel, child_rel) {
			resize(w.rel_buf, rel_mark)
			continue
		}
		#partial switch entries[i].type {
		case .Directory:
			if w.skip_ignored && stack_match_dir(stack, child_rel, scratch) {
				resize(w.rel_buf, rel_mark)
				continue
			}
			walk_buf_append(w.abs_buf, "/")
			walk_buf_append(w.abs_buf, name)
			child_abs := string(w.abs_buf^[:])
			if w.deny != nil {
				// Deny via the walk's composed resolution (safety.Deny_Walk).
				// The child state must be live across visit + recursion and
				// restored for this directory's later entries: a defer here
				// would fire at the if-block's exit, before the recursion —
				// restore explicitly instead. The break path may leave the
				// child state in place: the parent frame restores its own.
				saved_walk := w.deny_walk
				child_dw: safety.Deny_Walk
				if safety.deny_walk_entry(&saved_walk, w.deny, child_abs, name, &child_dw) {
					resize(w.abs_buf, abs_mark)
					resize(w.rel_buf, rel_mark)
					continue
				}
				w.deny_walk = child_dw
				if w.visit(w.vctx, .Directory, child_rel, child_abs) == .Stop {
					resize(w.abs_buf, abs_mark)
					resize(w.rel_buf, rel_mark)
					stopped = true
					break
				}
				if w.recursive && file_walk_dir(
					w,
					strings.clone(child_abs, w.walk),
					strings.clone(child_rel, w.walk),
					depth + 1,
					stack,
				) {
					stopped = true
				}
				w.deny_walk = saved_walk
				resize(w.abs_buf, abs_mark)
			} else {
				if w.visit(w.vctx, .Directory, child_rel, child_abs) == .Stop {
					resize(w.abs_buf, abs_mark)
					resize(w.rel_buf, rel_mark)
					stopped = true
					break
				}
				if w.recursive && file_walk_dir(
					w,
					strings.clone(child_abs, w.walk),
					strings.clone(child_rel, w.walk),
					depth + 1,
					stack,
				) {
					stopped = true
				}
				resize(w.abs_buf, abs_mark)
			}
		case .Regular:
			if w.skip_ignored && stack_match_file(stack, child_rel) {
				resize(w.rel_buf, rel_mark)
				continue
			}
			walk_buf_append(w.abs_buf, "/")
			walk_buf_append(w.abs_buf, name)
			child_abs := string(w.abs_buf^[:])
			if w.deny != nil && safety.deny_walk_entry(&w.deny_walk, w.deny, child_abs, name, nil) {
				resize(w.abs_buf, abs_mark)
				resize(w.rel_buf, rel_mark)
				continue
			}
			if w.visit(w.vctx, .File, child_rel, child_abs) == .Stop {
				resize(w.abs_buf, abs_mark)
				resize(w.rel_buf, rel_mark)
				stopped = true
				break
			}
			resize(w.abs_buf, abs_mark)
		case: // symlinks and special files are not followed
		}
		resize(w.rel_buf, rel_mark)
		if stopped {
			break
		}
	}

	if pushed {
		last := len(stack^) - 1
		pathspec.pathspec_destroy(stack[last])
		pop(stack)
	}
	return stopped
}

// ---------------------------------------------------------------------------
// Error mapping
// ---------------------------------------------------------------------------

// editor_err_map converts an editor failure onto the closed platform
// kinds — the one place editor kinds cross this boundary, with no string
// matching anywhere. Containment refusals read as Denied; unavailable
// positions, malformed values, and unsupported symbol shapes as Invalid;
// IO failures as Internal.
editor_err_map :: proc(op: string, e: editor.Editor_Err, msg: string, a: mem.Allocator) -> platform.Err {
	kind: platform.Err_Kind
	#partial switch e {
	case .NotFound:
		kind = .NotFound
	case .Outside_Root:
		kind = .Denied
	case .IO, .Internal:
		kind = .Internal
	case:
		kind = .Invalid
	}
	if msg != "" {
		return wrapped_err(kind, strings.concatenate({op, ": ", msg}, a), a)
	}
	return wrapped_err(kind, op, a)
}

// ---------------------------------------------------------------------------
// Read
// ---------------------------------------------------------------------------

File_Read_Result :: struct {
	content: string, // owned by `a`
	read_ask: bool, // sensitive-content prompt heuristic hit
	truncated: bool, // content withheld: it exceeded max_chars
	total_chars: int, // full sliced length before the max_chars gate
}

// file_read returns the file's current contents (open buffer preferred,
// disk otherwise), sliced to the inclusive 0-based line range. max_chars
// > 0 gates the payload: an over-budget read returns empty content with
// truncated set — shaping the too-long notice is the tool's job.
// read_text_normalise_cr prepares editor-read contents for the LF line
// split: a \r\n pair folds to a single \n (one logical newline — a byte-wise
// rewrite would double the break), and a surviving lone '\r' (content the
// editor's pair-only read folding leaves in place) rewrites to '\n'. Input
// without any '\r' passes through as the same bytes.
read_text_normalise_cr :: proc(contents: string, a: mem.Allocator) -> string {
	if !strings.contains(contents, "\r") {
		return contents
	}
	b := strings.builder_make_len_cap(0, len(contents) + 1, a)
	i := 0
	for i < len(contents) {
		c := contents[i]
		if c == '\r' {
			if i + 1 < len(contents) && contents[i + 1] == '\n' {
				i += 1
			}
			strings.write_byte(&b, '\n')
		} else {
			strings.write_byte(&b, c)
		}
		i += 1
	}
	out := strings.clone(strings.to_string(b), a)
	strings.builder_destroy(&b)
	return out
}

// sensitive_path_denied is the one gate for the single-file content faces
// (file_read, file_outline, file_search's file scope): deny globs (.env,
// *.pem, ...) and the system-location check both resolve symlinks, so a
// link inside the tree pointing at credentials or /etc is judged by its
// target. nil deny (tests, hostless callers) skips the gate. A join
// failure denies: the gate decides on a path and must fail closed.
sensitive_path_denied :: proc(
	ed: ^editor.Editor,
	deny: ^safety.Deny_List,
	rel: string,
	a: mem.Allocator,
) -> (err: platform.Err, denied: bool) {
	if deny == nil {
		return nil, false
	}
	rel_n := normalize_rel(rel, context.temp_allocator)
	abs, jerr := filepath.join({ed.project_root, rel_n}, context.temp_allocator)
	if jerr != nil || safety.is_denied(deny, abs) || safety.is_sensitive_system_path(abs) {
		return wrapped_err(
			.Denied,
			strings.concatenate({"read denied for sensitive path: ", rel_n}, a),
			a,
		), true
	}
	return nil, false
}

// state_target_denied is the mutating faces' refusal on aubade's own
// per-project state: the index database, the memories, and the generated
// files under the managed directory. The folder template can place that
// directory anywhere under the project, so the refusal resolves the
// actual location rather than matching a name. Reads stay allowed — the
// sensitive-path deny globs still judge them.
state_target_denied :: proc(ed: ^editor.Editor, rel: string, a: mem.Allocator) -> (err: platform.Err, denied: bool) {
	ta := context.temp_allocator
	template := config.global_managed_template(platform.aubade_home(ta))
	mrel := config.managed_rel_for(ed.project_root, template, ta)
	nrel := normalize_rel(rel, ta)
	if !managed_state_rel(mrel, nrel) {
		return nil, false
	}
	return wrapped_err(
		.Denied,
		strings.concatenate({"refusing to modify aubade's own state directory: ", nrel}, a),
		a,
	), true
}

file_read :: proc(
	ed: ^editor.Editor,
	deny: ^safety.Deny_List,
	rel: string,
	start_line: int,
	end_line: int, // inclusive; honored when end_set
	end_set: bool,
	max_chars: int,
	a: mem.Allocator,
) -> (File_Read_Result, platform.Err) {
	// The sensitive-path gate runs before anything is opened; the advisory
	// read_ask banner further down is not a substitute.
	if derr, denied := sensitive_path_denied(ed, deny, rel, a); denied {
		return {}, derr
	}
	contents, rerr, rmsg := editor.editor_read_file(ed, rel)
	if rerr != .None {
		return {}, editor_err_map("file read", rerr, rmsg, a)
	}
	// Allocated by the editor's allocator (worker threads do not inherit
	// it as context.allocator), so the free names it explicitly.
	defer delete(contents, ed.allocator)

	// The editor strips CR only when CRLF pairs are present; normalize any
	// surviving lone CR to LF (read_text_normalise_cr also folds a pair,
	// should one ever reach the buffer through inserted text).
	text := read_text_normalise_cr(contents, a)

	lines := strings.split(text, "\n", a)
	start := start_line
	if start < 0 {
		start = 0
	}
	res: File_Read_Result
	res.total_chars = len(text)
	if start >= len(lines) {
		return res, nil
	}
	end := len(lines)
	if end_set && end_line < end {
		end = end_line + 1
	}
	if end > len(lines) {
		end = len(lines)
	}
	if end < start {
		end = start
	}
	sliced, _ := strings.join(lines[start:end], "\n", a)
	res.content = sliced
	res.read_ask = safety.is_read_ask(rel)
	if max_chars > 0 && len(sliced) > max_chars {
		res.content = ""
		res.truncated = true
	}
	return res, nil
}

// ---------------------------------------------------------------------------
// Write / delete / move (direct FS, buffer-coherent)
// ---------------------------------------------------------------------------

// file_write creates or overwrites rel with content, creating missing
// parent directories. The payload goes through the editor's save (project
// encoding + line endings); any open buffer for the target is dropped so
// subsequent reads see the new content.
file_write :: proc(ed: ^editor.Editor, rel: string, content: string, a: mem.Allocator) -> (overwrote: bool, err: platform.Err) {
	abs, perr, preason := editor.safe_path(ed, rel)
	if perr != .None {
		return false, wrapped_err(
			.Invalid,
			strings.concatenate({"file write: invalid path: ", preason}, a),
			a,
		)
	}
	if derr, denied := state_target_denied(ed, rel, a); denied {
		return false, derr
	}
	kind, _, sok := util.stat_kind_size(abs)
	if sok {
		if kind != .Regular {
			return false, wrapped_err(
				.Invalid,
				strings.concatenate({"file write: path exists but is not a regular file: ", rel}, a),
				a,
			)
		}
		overwrote = true
	}
	parent, _ := filepath.split(abs)
	if parent != "" {
		if merr := os.make_directory_all(parent, os.Permissions{.Read_User, .Write_User, .Execute_User}); merr != nil &&
			!os.exists(parent) {
			return false, wrapped_err(
				.Internal,
				strings.concatenate({"file write: cannot create directories for ", rel}, a),
				a,
			)
		}
	}
	// A whole-file rewrite keeps a BOM the target already carried: an
	// editor read-modify-write cycle reads the file BOM-stripped, so
	// dropping the marker here would silently re-sign the file. New files
	// gain nothing, and save itself skips the prepend when the incoming
	// content already starts with its own BOM.
	had_bom := false
	if overwrote {
		if f, oerr := os.open(abs, {.Read}, os.Permissions{.Read_User}); oerr == nil {
			head: [3]u8
			n, _ := os.read(f, head[:])
			had_bom = n == 3 && util.has_utf8_bom(head[:])
			os.close(f)
		}
	}
	// The per-file lock is the disk-write mutex for project files: without
	// it a concurrent edit_file on the same path interleaves its
	// read-modify-write with this save and one of the two writes is lost.
	// The buffer drop shares the same critical section through the locked
	// variant (editor_drop_buffer would re-acquire the mutex).
	h := editor.file_lock(ed, rel)
	defer editor.file_release(ed, rel)
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)
	if werr, wmsg := editor.save(ed, rel, content, had_bom); werr != .None {
		return false, editor_err_map("file write failed", werr, wmsg, a)
	}
	editor.drop_buffer_locked(ed, rel)
	return overwrote, nil
}

// file_delete removes a regular file and drops any open buffer for it.
file_delete :: proc(ed: ^editor.Editor, rel: string, a: mem.Allocator) -> platform.Err {
	abs, perr, preason := editor.safe_path(ed, rel)
	if perr != .None {
		return wrapped_err(.Invalid, strings.concatenate({"file delete: invalid path: ", preason}, a), a)
	}
	if derr, denied := state_target_denied(ed, rel, a); denied {
		return derr
	}
	kind, _, sok := util.stat_kind_size(abs)
	if !sok {
		return wrapped_err(.NotFound, strings.concatenate({"file not found: ", rel}, a), a)
	}
	if kind != .Regular {
		return wrapped_err(
			.Invalid,
			strings.concatenate({"path is not a regular file: ", rel}, a),
			a,
		)
	}
	// Same per-file serialization as file_write: the remove and the buffer
	// drop pair against any in-flight edit on this path.
	h := editor.file_lock(ed, rel)
	defer editor.file_release(ed, rel)
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)
	if rerr := os.remove(abs); rerr != nil {
		return wrapped_err(
			.Internal,
			strings.concatenate({"failed to delete file: ", rel}, a),
			a,
		)
	}
	editor.drop_buffer_locked(ed, rel)
	return nil
}

// file_move renames src_rel to dst_rel (target must not exist; missing
// target parents are created) and drops the source's open buffer.
file_move :: proc(ed: ^editor.Editor, src_rel, dst_rel: string, a: mem.Allocator) -> platform.Err {
	src_abs, sperr, sreason := editor.safe_path(ed, src_rel)
	if sperr != .None {
		return wrapped_err(
			.Invalid,
			strings.concatenate({"file move: invalid source path: ", sreason}, a),
			a,
		)
	}
	dst_abs, dperr, dreason := editor.safe_path(ed, dst_rel)
	if dperr != .None {
		return wrapped_err(
			.Invalid,
			strings.concatenate({"file move: invalid target path: ", dreason}, a),
			a,
		)
	}
	// Both endpoints carry the state refusal: moving a file OUT of the
	// managed tree corrupts it as surely as moving one in.
	if derr, denied := state_target_denied(ed, src_rel, a); denied {
		return derr
	}
	if derr, denied := state_target_denied(ed, dst_rel, a); denied {
		return derr
	}
	kind, _, sok := util.stat_kind_size(src_abs)
	if !sok {
		return wrapped_err(
			.NotFound,
			strings.concatenate({"source file not found: ", src_rel}, a),
			a,
		)
	}
	if kind != .Regular {
		return wrapped_err(
			.Invalid,
			strings.concatenate({"source path is not a regular file: ", src_rel}, a),
			a,
		)
	}
	// Both per-file locks are held across the exists-check, the rename, and
	// the source's buffer drop, acquired in folded-key order:
	// any pair of concurrent moves that share both endpoints takes the same
	// first lock, so the pair serializes instead of deadlocking. The
	// source's lock is load-bearing: file_write and file_delete on src
	// serialize on it, and holding only the target's lock let a concurrent
	// file_write on src land between the rename and the buffer drop,
	// resurrecting the moved file at its old path.
	if platform.path_equal(src_rel, dst_rel) {
		// Same path is the same file: the target exists, and locking the
		// same handle's mutex twice would self-deadlock (non-recursive).
		return wrapped_err(
			.Invalid,
			strings.concatenate({"target file already exists: ", dst_rel}, a),
			a,
		)
	}
	// Order the two locks by the FOLDED spellings: case-varied spellings
	// of a shared endpoint pair fold to the same lock pair, and raw
	// lexicographic order can disagree across case variants ("a" vs "B"
	// orders one way raw, the other folded) — the reverse move would
	// then take the locks in the opposite order and deadlock.
	first_rel := platform.path_fold(src_rel, context.temp_allocator)
	second_rel := platform.path_fold(dst_rel, context.temp_allocator)
	if second_rel < first_rel {
		first_rel, second_rel = second_rel, first_rel
	}
	fh := editor.file_lock(ed, first_rel)
	defer editor.file_release(ed, first_rel)
	sync.mutex_lock(&fh.mu)
	defer sync.mutex_unlock(&fh.mu)
	oh := editor.file_lock(ed, second_rel)
	defer editor.file_release(ed, second_rel)
	sync.mutex_lock(&oh.mu)
	defer sync.mutex_unlock(&oh.mu)
	if _, _, dok := util.stat_kind_size(dst_abs); dok {
		return wrapped_err(
			.Invalid,
			strings.concatenate({"target file already exists: ", dst_rel}, a),
			a,
		)
	}
	parent, _ := filepath.split(dst_abs)
	if parent != "" {
		if merr := os.make_directory_all(parent, os.Permissions{.Read_User, .Write_User, .Execute_User}); merr != nil &&
			!os.exists(parent) {
			return wrapped_err(
				.Internal,
				strings.concatenate({"file move: cannot create directories for ", dst_rel}, a),
				a,
			)
		}
	}
	if rerr := os.rename(src_abs, dst_abs); rerr != nil {
		return wrapped_err(
			.Internal,
			strings.concatenate({"failed to move file: ", src_rel}, a),
			a,
		)
	}
	editor.drop_buffer_locked(ed, src_rel)
	return nil
}

// ---------------------------------------------------------------------------
// Line counting (list_dir include_line_counts)
// ---------------------------------------------------------------------------

// count_file_lines counts newline-terminated lines (adding one for a final
// unterminated line) and reports files whose first BINARY_SNIFF_LEN bytes
// contain a NUL byte as binary. Streams through a stack buffer so per-file
// counting never touches the allocator.
count_file_lines :: proc(abs_path: string) -> (lines: int, binary: bool) {
	f, oerr := os.open(abs_path, {.Read}, os.Permissions{.Read_User})
	if oerr != nil {
		return 0, false
	}
	defer os.close(f)

	buf: [16 * 1024]u8
	total_newlines := 0
	last_byte := u8(0)
	total_bytes := 0
	first_chunk := true
	for {
		n, rerr := os.read(f, buf[:])
		if n > 0 {
			chunk := buf[:]
			if first_chunk {
				sniff := n
				if sniff > BINARY_SNIFF_LEN {
					sniff = BINARY_SNIFF_LEN
				}
				for i in 0..<sniff {
					if chunk[i] == 0 {
						return 0, true
					}
				}
				first_chunk = false
			}
			for i in 0..<n {
				if chunk[i] == '\n' {
					total_newlines += 1
				}
			}
			last_byte = chunk[n - 1]
			total_bytes += n
		}
		if n == 0 || rerr != nil {
			break
		}
	}
	if total_bytes > 0 && last_byte != '\n' {
		total_newlines += 1
	}
	return total_newlines, false
}

// ---------------------------------------------------------------------------
// list_dir
// ---------------------------------------------------------------------------

File_List_Entry :: struct {
	name: string, // owned by the result allocator
	lines: int, // valid when has_lines
	binary: bool,
	has_lines: bool,
}

File_List_Result :: struct {
	dirs: []string, // owned by the result allocator, walk order
	files: []File_List_Entry,
	truncated: bool,
}

List_Walk_Ctx :: struct {
	allocator: mem.Allocator,
	include_line_counts: bool,
	count: int,
	truncated: bool,
	dirs: [dynamic]string,
	entries: [dynamic]File_List_Entry,
}

list_dir_visit :: proc(data: rawptr, kind: File_Walk_Kind, rel: string, abs: string) -> File_Walk_Control {
	c := cast(^List_Walk_Ctx)data
	if c.count >= FILE_LIST_MAX_ENTRIES {
		c.truncated = true
		return .Stop
	}
	c.count += 1
	if kind == .Directory {
		append(&c.dirs, strings.clone(rel, c.allocator))
		return .Continue
	}
	entry := File_List_Entry{name = strings.clone(rel, c.allocator)}
	if c.include_line_counts {
		lines, binary := count_file_lines(abs)
		entry.lines = lines
		entry.binary = binary
		entry.has_lines = true
	}
	append(&c.entries, entry)
	return .Continue
}

// file_list_dir lists the directory's children. recursive descends
// subtrees; skip_ignored applies gitignore scoping (still gated by the
// config's gitignore switch); include_line_counts streams each file for a
// count (binary files report binary=true). relative_path "" addresses the
// project root.
file_list_dir :: proc(
	ed: ^editor.Editor,
	rel: string,
	recursive: bool,
	skip_ignored: bool,
	include_line_counts: bool,
	ignore: Ignore_Config,
	deny: ^safety.Deny_List,
	a: mem.Allocator,
	token: ^platform.Cancel_Token,
) -> (File_List_Result, platform.Err) {
	scope := rel
	if scope == "" {
		scope = "."
	}
	abs, derr := safety.pathguard_validate_contained_dir(ed.project_root, scope, context.temp_allocator)
	if derr.reason != "" {
		return {}, wrapped_err(
			.Invalid,
			strings.concatenate({"file list: invalid path: ", derr.reason}, a),
			a,
		)
	}
	kind, _, sok := util.stat_kind_size(abs)
	if !sok {
		return {}, wrapped_err(
			.NotFound,
			strings.concatenate({"Directory not found: ", rel}, a),
			a,
		)
	}
	if kind != .Directory {
		return {}, wrapped_err(
			.Invalid,
			strings.concatenate({"expected a directory path, but got a file: ", rel}, a),
			a,
		)
	}

	ctx := List_Walk_Ctx{
		allocator = a,
		include_line_counts = include_line_counts,
	}
	ctx.dirs = make([dynamic]string, 0, 16, a)
	ctx.entries = make([dynamic]File_List_Entry, 0, 16, a)
	file_walk(abs, normalize_rel(scope, a), recursive, skip_ignored && !ignore.no_gitignore, ignore, deny, list_dir_visit, &ctx, token, ed.allocator)
	return {dirs = ctx.dirs[:], files = ctx.entries[:], truncated = ctx.truncated}, nil
}

// ---------------------------------------------------------------------------
// find (file_mask)
// ---------------------------------------------------------------------------

// Mask_Matcher holds the find_file mask compiled once: patterns containing
// '/' match the whole relative path, bare patterns match the base name,
// and a lowercased retry makes matching case-insensitive everywhere.
Mask_Matcher :: struct {
	full: bool,
	re: regex.Regex,
	lower: regex.Regex,
	lower_same: bool, // pattern is already all-lowercase: no retry
}

mask_matcher_init :: proc(mask: string, a: mem.Allocator) -> (m: Mask_Matcher, err: platform.Err) {
	norm, _ := strings.replace_all(mask, "\\", "/", a)
	m.full = strings.contains(norm, "/")
	lowered := strings.to_lower(norm, a)
	m.lower_same = lowered == norm

	anchored := strings.concatenate({"^", regex.glob_to_regex(norm, a), "$"}, a)
	re, cerr := regex.compile_regex(anchored, a)
	if cerr != nil {
		return {}, wrapped_err(.Invalid, strings.concatenate({"invalid file mask: ", mask}, a), a)
	}
	m.re = re
	if !m.lower_same {
		anchored_lower := strings.concatenate({"^", regex.glob_to_regex(lowered, a), "$"}, a)
		re_lower, cerr2 := regex.compile_regex(anchored_lower, a)
		if cerr2 != nil {
			regex.regex_destroy(&m.re)
			return {}, wrapped_err(.Invalid, strings.concatenate({"invalid file mask: ", mask}, a), a)
		}
		m.lower = re_lower
	}
	return m, nil
}

mask_matcher_destroy :: proc(m: ^Mask_Matcher) {
	regex.regex_destroy(&m.re)
	if !m.lower_same {
		regex.regex_destroy(&m.lower)
	}
}

mask_match :: proc(m: ^Mask_Matcher, rel: string) -> bool {
	subject := rel
	if !m.full {
		subject = filepath.base(rel)
	}
	if regex.regex_match(&m.re, subject) {
		return true
	}
	if m.lower_same {
		return false
	}
	lower_subject := strings.to_lower(subject, context.temp_allocator)
	return regex.regex_match(&m.lower, lower_subject)
}

Find_Walk_Ctx :: struct {
	allocator: mem.Allocator,
	matcher: ^Mask_Matcher,
	count: int,
	truncated: bool,
	files: [dynamic]string,
}

find_visit :: proc(data: rawptr, kind: File_Walk_Kind, rel: string, abs: string) -> File_Walk_Control {
	c := cast(^Find_Walk_Ctx)data
	if kind == .Directory {
		return .Continue
	}
	if c.count >= FILE_WALK_MAX_FILES {
		c.truncated = true
		return .Stop
	}
	c.count += 1
	if mask_match(c.matcher, rel) {
		append(&c.files, strings.clone(rel, c.allocator))
	}
	return .Continue
}

// file_find lists files matching mask under within ("" or "." for the
// project root). Ignored paths are always skipped; a file scope is matched
// against itself.
file_find :: proc(
	ed: ^editor.Editor,
	mask: string,
	within: string,
	ignore: Ignore_Config,
	deny: ^safety.Deny_List,
	a: mem.Allocator,
	token: ^platform.Cancel_Token,
) -> (files: []string, truncated: bool, err: platform.Err) {
	matcher, merr := mask_matcher_init(mask, a)
	if merr != nil {
		return nil, false, merr
	}
	defer mask_matcher_destroy(&matcher)

	scope := within
	if scope == "" {
		scope = "."
	}
	abs, derr := safety.pathguard_validate_contained_dir(ed.project_root, scope, context.temp_allocator)
	if derr.reason != "" {
		return nil, false, wrapped_err(
			.Invalid,
			strings.concatenate({"file find: invalid path: ", derr.reason}, a),
			a,
		)
	}
	kind, _, sok := util.stat_kind_size(abs)
	if !sok {
		return nil, false, wrapped_err(
			.NotFound,
			strings.concatenate({"relative path does not exist: ", within}, a),
			a,
		)
	}
	if kind == .Regular {
		out := make([dynamic]string, 0, 1, a)
		rel := normalize_rel(scope, a)
		if mask_match(&matcher, rel) {
			append(&out, rel)
		}
		return out[:], false, nil
	}
	if kind != .Directory {
		return nil, false, wrapped_err(
			.Invalid,
			strings.concatenate({"not a directory or regular file: ", within}, a),
			a,
		)
	}

	ctx := Find_Walk_Ctx{allocator = a, matcher = &matcher}
	ctx.files = make([dynamic]string, 0, 16, a)
	file_walk(abs, normalize_rel(scope, a), true, !ignore.no_gitignore, ignore, deny, find_visit, &ctx, token, ed.allocator)
	return ctx.files[:], ctx.truncated, nil
}

// ---------------------------------------------------------------------------
// search (regex over file contents)
// ---------------------------------------------------------------------------

File_Search_Req :: struct {
	pattern: string,
	multiline: bool, // ^/$ match line boundaries (otherwise whole-subject)
	context_before: int,
	context_after: int,
	include_glob: string, // anchored full-path glob; "" disables
	exclude_glob: string,
	scope_rel: string, // file or directory; "" for the project root
	offset: int, // skip the first N matches after the (path, line) sort
	limit: int, // cap the returned matches; 0 = all remaining
}

File_Search_Match :: struct {
	path: string, // owned by the result allocator
	line: int, // 0-based line of the match start
	display: string, // context block, reference format
}

Search_Walk_Ctx :: struct {
	allocator: mem.Allocator,
	ed: ^editor.Editor,
	re: ^regex.Regex,
	before: int,
	after: int,
	include: regex.Regex, // valid when has_include
	has_include: bool,
	exclude: regex.Regex, // valid when has_exclude
	has_exclude: bool,
	scratch: ^mem.Dynamic_Arena, // one file's working set, reset per file
	matches: [dynamic]File_Search_Match,
	files_seen: int,
	truncated: bool,
}

search_visit :: proc(data: rawptr, kind: File_Walk_Kind, rel: string, abs: string) -> File_Walk_Control {
	c := cast(^Search_Walk_Ctx)data
	if kind == .Directory {
		return .Continue
	}
	if c.files_seen >= FILE_WALK_MAX_FILES {
		c.truncated = true
		return .Stop
	}
	c.files_seen += 1
	if c.has_include && !regex.regex_match(&c.include, rel) {
		return .Continue
	}
	if c.has_exclude && regex.regex_match(&c.exclude, rel) {
		return .Continue
	}
	file_search_content(c, rel)
	return .Continue
}

file_search_content :: proc(c: ^Search_Walk_Ctx, rel: string) {
	// Unreadable and oversized files are skipped, not fatal — a failed
	// read just drops the file.
	contents, rerr, _ := editor.editor_read_file(c.ed, rel)
	if rerr != .None {
		return
	}
	defer delete(contents, c.ed.allocator)

	// One file's working set — the split lines, the per-line offsets, and
	// the match ranges — lives on the per-file scratch arena, reset for
	// every file. Request-arena placement once retained every visited
	// file's lines for the whole search, scaling the request's peak (and
	// with it the handling worker's allocator high-water) with the walk's
	// file budget instead of the answer's size. The temp allocator resets
	// at the same boundary: the file read's helpers (path resolution, the
	// stat probe) allocate on context.temp_allocator and arena frees are
	// no-ops mid-request, so without the reset one search accumulates
	// every file's temp churn on the worker's temp arena, which retains
	// its high-water for the daemon's lifetime (the request-boundary reset
	// alone fires once per search, not per file).
	mem.dynamic_arena_free_all(c.scratch)
	free_all(context.temp_allocator)
	sa := mem.dynamic_arena_allocator(c.scratch)

	// The match scan runs first: files with no match — the overwhelming
	// majority of a whole-tree search — never pay the line split and
	// offset table (two full passes plus a line-count-sized array per
	// visited file).
	ranges := regex.regex_find_all(c.re, contents, sa)
	if len(ranges) == 0 {
		return
	}
	if len(ranges) > FILE_SEARCH_MAX_MATCHES_PER_FILE {
		ranges = ranges[:FILE_SEARCH_MAX_MATCHES_PER_FILE]
		c.truncated = true
	}

	lines := strings.split(contents, "\n", sa)
	offsets := make([dynamic]int, 0, len(lines) + 1, sa)
	pos := 0
	for line in lines {
		append(&offsets, pos)
		pos += len(line) + 1
	}

	// One path clone per file, shared by every match record (the request
	// arena outlives the answer; a per-match clone multiplied the copy by
	// the match count).
	path_owned := strings.clone(rel, c.allocator)

	li := 0
	for r in ranges {
		start_line, next := line_for_offset(offsets[:], li, r.start)
		li = next
		end_line, next2 := line_for_offset(offsets[:], li, r.end)
		li = next2

		from := start_line - c.before
		if from < 0 {
			from = 0
		}
		to := end_line + c.after + 1
		if to > len(lines) {
			to = len(lines)
		}
		append(&c.matches, File_Search_Match{
			path = path_owned,
			line = start_line,
			display = match_display(lines, offsets[:], from, to, start_line, end_line, r.start, c.allocator),
		})
	}
}

// line_for_offset maps a byte offset to its 0-based line, resuming from
// `from` (matches arrive in order, so the cursor only moves forward).
line_for_offset :: proc(offsets: []int, from: int, offset: int) -> (line: int, next: int) {
	li := from
	if li >= len(offsets) {
		li = len(offsets) - 1
	}
	for li + 1 < len(offsets) && offsets[li + 1] <= offset {
		li += 1
	}
	return li, li
}

// match_display renders one match's context block: match lines carry the
// "  >NNNN:" prefix, context lines "...NNNN:" (width-4 right-aligned line
// numbers). Each line is windowed around the match: an unclamped line
// lets a single minified-JSON match
// (whole megabyte-scale files live on one line) eat the entire answer
// budget. `match_start` is the match's byte offset; `offsets` are the
// per-line start offsets the caller already computed.
FILE_SEARCH_LINE_WINDOW :: 480

match_display :: proc(lines: []string, offsets: []int, from, to, start_line, end_line, match_start: int, a: mem.Allocator) -> string {
	b := strings.builder_make_len_cap(0, 64, a)
	for i in from..<to {
		prefix := "..."
		if i >= start_line && i <= end_line {
			prefix = "  >"
		}
		num := util.int_to_dec(i, a)
		pad := 4 - len(num)
		if pad < 0 {
			pad = 0
		}
		strings.write_string(&b, prefix)
		for _ in 0..<pad {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, num)
		strings.write_string(&b, ":")
		write_windowed_line(&b, lines[i], offsets, i, start_line, match_start)
		if i + 1 < to {
			strings.write_byte(&b, '\n')
		}
	}
	return strings.to_string(b)
}

// write_windowed_line writes one display line, whole when it fits the
// window, else sliced around the match (the line where the match starts
// centers on its column; every other line windows from the start). Cuts
// back off to UTF-8 rune boundaries and mark themselves with "…".
write_windowed_line :: proc(b: ^strings.Builder, line: string, offsets: []int, i: int, start_line: int, match_start: int) {
	if len(line) <= FILE_SEARCH_LINE_WINDOW {
		strings.write_string(b, line)
		return
	}
	col := 0
	if i == start_line && match_start >= offsets[i] {
		col = match_start - offsets[i]
	}
	lo := col - FILE_SEARCH_LINE_WINDOW / 2
	if lo < 0 {
		lo = 0
	}
	hi := lo + FILE_SEARCH_LINE_WINDOW
	if hi > len(line) {
		hi = len(line)
	}
	for lo > 0 && (line[lo] & 0xC0) == 0x80 {
		lo -= 1
	}
	for hi < len(line) && (line[hi] & 0xC0) == 0x80 {
		hi += 1
	}
	if lo > 0 {
		strings.write_string(b, "…")
	}
	strings.write_string(b, line[lo:hi])
	if hi < len(line) {
		strings.write_string(b, "…")
	}
}

// file_search runs the regex over the scope (one file, or a directory
// walk with gitignore scoping) and returns per-match records with context
// blocks. The include/exclude globs filter full relative paths. Matches
// come back in (path, line) order with the pre-offset total alongside, so
// a caller can page a long answer with offset/limit deterministically.
file_search :: proc(
	ed: ^editor.Editor,
	req: File_Search_Req,
	ignore: Ignore_Config,
	deny: ^safety.Deny_List,
	a: mem.Allocator,
	token: ^platform.Cancel_Token,
) -> (matches: []File_Search_Match, total: int, truncated: bool, err: platform.Err) {
	// One compile: "sm" for multiline, plain dot-all otherwise — a second
	// compile used to overwrite the first Regex without destroying it.
	flags := "s"
	if req.multiline {
		flags = "sm"
	}
	re, cerr := regex.compile_regex_with_flags(req.pattern, flags, a)
	if cerr != nil {
		return nil, 0, false, wrapped_err(.Invalid, "invalid regex pattern", a)
	}
	defer regex.regex_destroy(&re)

	include: regex.Regex
	has_include := false
	if trimmed := strings.trim_space(req.include_glob); trimmed != "" {
		r, gerr := anchored_glob_regex(trimmed, a)
		if gerr != nil {
			return nil, 0, false, gerr
		}
		include = r
		has_include = true
	}
	defer if has_include {
		regex.regex_destroy(&include)
	}
	exclude: regex.Regex
	has_exclude := false
	if trimmed := strings.trim_space(req.exclude_glob); trimmed != "" {
		r, gerr := anchored_glob_regex(trimmed, a)
		if gerr != nil {
			return nil, 0, false, gerr
		}
		exclude = r
		has_exclude = true
	}
	defer if has_exclude {
		regex.regex_destroy(&exclude)
	}

	scope := req.scope_rel
	if scope == "" {
		scope = "."
	}
	abs, derr := safety.pathguard_validate_contained_dir(ed.project_root, scope, context.temp_allocator)
	if derr.reason != "" {
		return nil, 0, false, wrapped_err(
			.Invalid,
			strings.concatenate({"file search: invalid path: ", derr.reason}, a),
			a,
		)
	}
	kind, _, sok := util.stat_kind_size(abs)
	if !sok {
		return nil, 0, false, wrapped_err(
			.NotFound,
			strings.concatenate({"relative path does not exist: ", req.scope_rel}, a),
			a,
		)
	}

	// Per-file scratch (see file_search_content): the editor's allocator
	// backs it — the same durable heap allocator the file reads use — so
	// per-file working sets free between files instead of stacking on the
	// request arena.
	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, ed.allocator)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	ctx := Search_Walk_Ctx{
		allocator = a,
		ed = ed,
		re = &re,
		before = req.context_before,
		after = req.context_after,
		include = include,
		has_include = has_include,
		exclude = exclude,
		has_exclude = has_exclude,
		scratch = &scratch_arena,
	}
	ctx.matches = make([dynamic]File_Search_Match, 0, 16, a)

	if kind == .Regular {
		// The single-file scope faces the same sensitive-path gate as
		// file_read/file_outline — the walk branch gates every visited
		// entry, so leaving the file branch ungated would let a scoped
		// search return denied files' content.
		if derr, denied := sensitive_path_denied(ed, deny, scope, a); denied {
			return nil, 0, false, derr
		}
		file_search_content(&ctx, normalize_rel(scope, a))
	} else if kind == .Directory {
		file_walk(abs, normalize_rel(scope, a), true, !ignore.no_gitignore, ignore, deny, search_visit, &ctx, token, ed.allocator)
	} else {
		return nil, 0, false, wrapped_err(
			.Invalid,
			strings.concatenate({"not a directory or regular file: ", req.scope_rel}, a),
			a,
		)
	}
	// The match budget protects the worker from pathological backtracking;
	// a hit means the pattern ate its budget on at least one file, so the
	// (partial) match list would be silently wrong — fail typed instead.
	if re.limit_hit {
		return nil, 0, false, wrapped_err(
			.Invalid,
			"regex match limit exceeded: the pattern's backtracking ran out of budget; simplify the pattern (e.g. drop nested unbounded quantifiers)",
			a,
		)
	}
	// Paging: matches are sorted (path, line) — the walk's file order is
	// directory enumeration — then offset skips the front and limit caps
	// the tail. total (the pre-offset count) rides the wire so the child
	// can tell a page boundary from the end of the answer.
	total = len(ctx.matches)
	if total > 1 {
		sc := Sorted_Matches{items = ctx.matches}
		sort.sort({len = fs_len, less = fs_less, swap = fs_swap, collection = &sc})
	}
	kept := ctx.matches[:]
	if req.offset > 0 {
		if req.offset >= total {
			kept = kept[:0]
		} else {
			kept = kept[req.offset:]
		}
	}
	if req.limit > 0 && len(kept) > req.limit {
		kept = kept[:req.limit]
	}
	return kept, total, ctx.truncated, nil
}

// Sorted_Matches is the paging sort harness: pages are cut over the
// (path, line) order, not the walk's directory-enumeration order, so the
// same query with the same offset always pages the same sequence.
Sorted_Matches :: struct {
	items: [dynamic]File_Search_Match,
}

fs_len :: proc(it: sort.Interface) -> int {
	sc := cast(^Sorted_Matches)it.collection
	return len(sc.items)
}

fs_less :: proc(it: sort.Interface, i, j: int) -> bool {
	sc := cast(^Sorted_Matches)it.collection
	a, b := sc.items[i], sc.items[j]
	if a.path != b.path {
		return a.path < b.path
	}
	return a.line < b.line
}

fs_swap :: proc(it: sort.Interface, i, j: int) {
	sc := cast(^Sorted_Matches)it.collection
	sc.items[i], sc.items[j] = sc.items[j], sc.items[i]
}

// anchored_glob_regex compiles a full-path glob filter (include/exclude
// semantics: anchored, case-sensitive, no lowercased retry). The caller
// owns the compiled regex and releases it with regex_destroy.
anchored_glob_regex :: proc(pattern: string, a: mem.Allocator) -> (re: regex.Regex, err: platform.Err) {
	anchored := strings.concatenate({"^", regex.glob_to_regex(pattern, a), "$"}, a)
	compiled, cerr := regex.compile_regex(anchored, a)
	if cerr != nil {
		return {}, wrapped_err(
			.Invalid,
			strings.concatenate({"invalid glob pattern: ", pattern}, a),
			a,
		)
	}
	return compiled, nil
}

// ---------------------------------------------------------------------------
// Buffer-backed edits
// ---------------------------------------------------------------------------

validate_line_range :: proc(start_line, end_line: int, a: mem.Allocator) -> platform.Err {
	if start_line < 0 {
		return wrapped_err(
			.Invalid,
			strings.concatenate({
				"start_line must be non-negative, got ",
				util.int_to_dec(start_line, a),
			}, a),
			a,
		)
	}
	if end_line < 0 {
		return wrapped_err(
			.Invalid,
			strings.concatenate({
				"end_line must be non-negative, got ",
				util.int_to_dec(end_line, a),
			}, a),
			a,
		)
	}
	if end_line < start_line {
		return wrapped_err(
			.Invalid,
			strings.concatenate({
				"end_line (",
				util.int_to_dec(end_line, a),
				") must be >= start_line (",
				util.int_to_dec(start_line, a),
				")",
			}, a),
			a,
		)
	}
	return nil
}

// file_replace replaces needle by repl under the replace mode (the
// regex.REPLACE_MODE_NAMES vocabulary; first occurrence unless
// allow_multiple).
file_replace :: proc(
	ed: ^editor.Editor,
	rel: string,
	needle: string,
	repl: string,
	mode: string,
	allow_multiple: bool,
	a: mem.Allocator,
) -> platform.Err {
	if derr, denied := state_target_denied(ed, rel, a); denied {
		return derr
	}
	if _, ok := regex.replace_mode_from_string(mode); !ok {
		return wrapped_err(
			.Invalid,
			strings.concatenate(
				{"mode must be ", util.quoted_join(regex.REPLACE_MODE_NAMES, " or ", "\"", a), ", got: ", mode},
				a,
			),
			a,
		)
	}
	if eerr, emsg := editor.editor_replace_content(ed, rel, needle, repl, mode, allow_multiple); eerr != .None {
		return editor_err_map("file replace", eerr, emsg, a)
	}
	return nil
}

// file_insert_lines inserts content before the given 0-based line,
// appending a trailing newline when missing.
file_insert_lines :: proc(ed: ^editor.Editor, rel: string, line: int, content: string, a: mem.Allocator) -> platform.Err {
	if derr, denied := state_target_denied(ed, rel, a); denied {
		return derr
	}
	if line < 0 {
		return wrapped_err(
			.Invalid,
			strings.concatenate({"line must be non-negative, got ", util.int_to_dec(line, a)}, a),
			a,
		)
	}
	with_newline := util.ensure_trailing_newline(content, context.temp_allocator)
	if eerr, emsg := editor.editor_insert_at_line(ed, rel, line, with_newline); eerr != .None {
		return editor_err_map("file insert", eerr, emsg, a)
	}
	return nil
}

// file_replace_lines replaces the inclusive 0-based line range with
// content (a trailing newline is appended when missing).
file_replace_lines :: proc(
	ed: ^editor.Editor,
	rel: string,
	start_line, end_line: int,
	content: string,
	a: mem.Allocator,
) -> platform.Err {
	if derr, denied := state_target_denied(ed, rel, a); denied {
		return derr
	}
	if verr := validate_line_range(start_line, end_line, a); verr != nil {
		return verr
	}
	if eerr, emsg := editor.editor_replace_lines(ed, rel, start_line, end_line, content); eerr != .None {
		return editor_err_map("file replace lines", eerr, emsg, a)
	}
	return nil
}

// file_delete_lines removes the inclusive 0-based line range.
file_delete_lines :: proc(ed: ^editor.Editor, rel: string, start_line, end_line: int, a: mem.Allocator) -> platform.Err {
	if derr, denied := state_target_denied(ed, rel, a); denied {
		return derr
	}
	if verr := validate_line_range(start_line, end_line, a); verr != nil {
		return verr
	}
	if eerr, emsg := editor.editor_delete_lines(ed, rel, start_line, end_line); eerr != .None {
		return editor_err_map("file delete lines", eerr, emsg, a)
	}
	return nil
}
