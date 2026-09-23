// Dead-code candidate scan: one whole-project walk, two passes over the
// same file list, each spread over the bounded scan pool (scan_pool) and
// merged in walk order — per-file work runs in parallel, but every
// ordering the answer exposes comes from the merge, so it stays
// identical to a sequential walk. The definition pass parses every
// grammar-served file (borrowing a byte-identical tree from the L2 hot
// cache when one is resident; scans never land their parses there) and
// collects definition records — name, kind, name span, parent chain,
// attribute guard. The use pass then tokenizes every text file and
// counts, per definition name, the word occurrences that fall outside
// declaration name spans; it runs strictly after the whole definition
// pass (and its merge) so a use in an early file of a name defined
// later still counts. A definition
// with zero such occurrences, no entry-point prefix, and no
// attribute/decorator line directly above is reported as a candidate.
//
// The judgement is conservative in one direction only: any textual
// occurrence counts as a use (comments, strings, prose included),
// tokens inside another definition's name span keep same-name
// definitions mutually alive, and a file that cannot be read back on
// the use pass marks every definition it carries alive. So a reported
// candidate's name appears nowhere in the project text outside its own
// declaration spans — "dead" here means unused inside the project;
// consumers outside it (a library's callers, an external framework's
// string-built dispatch) are invisible to the scan and belong to
// review, not to the tool. The walk, ignore rules, and file budget
// mirror the symbol crawl so both share one notion of "the project".
package svc

import "core:mem"
import "core:os"
import "core:sort"
import "core:strings"
import "src:config"
import "src:editor"
import "src:pathspec"
import "src:platform"
import "src:safety"
import "src:ts"
import "src:util"

DEAD_SCAN_DEFAULT_LIMIT :: 200
DEAD_SCAN_MAX_LIMIT :: 1000
// Names starting with one of these are entry points the project invokes
// by convention (test runners, command hooks, process entry); the daemon
// replaces the set wholesale when the caller passes entry_prefixes.
DEAD_SCAN_DEFAULT_ENTRY_PREFIXES :: []string{"test_", "Test", "main"}

// Binary sniff window for the use pass: a NUL byte in the first bytes of
// a file that no grammar served marks it non-text (grammar-served files
// are exempt — they were parsed as source on the first pass).
DEAD_SCAN_SNIFF_BYTES :: 8192

// Depth bound for the outline-flattening work stack, mirroring the
// symbol tree walkers: generated or adversarial files nest arbitrarily
// deep; beyond the bound the walk truncates (degrade, never crash).
DEAD_SCAN_MAX_DEPTH :: 500

Dead_Scan_Candidate :: struct {
	path:      string, // project-relative
	line:      i64,    // 0-based row of the name
	kind:      string, // outline kind ("function", "method", ...)
	name:      string,
	name_path: string, // parent chain joined with '/' ("" = top level)
}

Dead_Scan_Stats :: struct {
	files_scanned:    int, // text files tokenized on the use pass
	files_parsed:     int, // files that produced definition records
	definitions:      int, // definition records collected
	candidates_total: int, // candidates before the report limit
	truncated:        bool, // candidates list cut by limit
	walk_truncated:   bool, // file walk hit MAX_CRAWL_FILES
}

// One walked regular file. All strings are walk-arena clones.
Dead_Scan_File :: struct {
	rel:      string,
	abs:      string,
	filename: string,
}

// One definition collected on the parse pass. Strings are clones in the
// caller's allocator; start/end byte bound the name inside its file.
Dead_Def :: struct {
	name:         string,
	path:         string,
	kind:         string,
	name_path:    string,
	line:         i64,
	start_byte:   u32,
	end_byte:     u32,
	attr_guarded: bool, // an attribute/decorator line sits directly above
	unreadable:   bool, // the use pass could not read the file back
}

dead_scan :: proc(
	src: ^TS_Source,
	path_prefix: string, // normalized project-relative dir, "" = whole project
	entry_prefixes: []string, // resolved (defaults applied by the caller)
	limit: int,
	ignore: Ignore_Config,
	deny: ^safety.Deny_List,
	stats: ^Dead_Scan_Stats,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> (candidates: []Dead_Scan_Candidate, err: platform.Err) {
	stats^ = {}

	walk_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&walk_arena, src.allocator)
	defer mem.dynamic_arena_destroy(&walk_arena)
	walk := mem.dynamic_arena_allocator(&walk_arena)
	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, src.allocator)
	defer mem.dynamic_arena_destroy(&scratch_arena)

	// Phase 0: the file list, under the crawl's traversal rules.
	files := make([dynamic]Dead_Scan_File, 0, 128, walk)
	walk_truncated, walk_cancelled := dead_scan_files(src, ignore, deny, token, walk, &scratch_arena, &files)
	if walk_cancelled {
		return nil, wrapped_err(.Cancelled, "dead scan: cancelled", a)
	}
	stats.walk_truncated = walk_truncated

	// Definition pass, parallel over the scan pool. The name set and uses
	// map live in the caller's allocator for the whole scan, so their keys
	// are cloned on first insert by the merge (a worker-arena key would rot
	// with the arena); jobs stage in worker result arenas until then. The
	// sorted name spans the use pass must skip ride in `spans`, keyed by
	// path.
	name_set := make(map[string]bool, 256, a)
	uses := make(map[string]int, 256, a)
	defs := make([dynamic]Dead_Def, 0, 512, a)
	spans := make(map[string][]ts.Span, 64, a)
	def_jobs := make([]^Dead_Defs_Job, len(files), a)
	def_ctx := Dead_Defs_Ctx{src = src, files = files[:], jobs = def_jobs[:]}
	def_run := scan_run(src.allocator, len(files), token, dead_scan_defs_body, &def_ctx, 0)
	if def_run.cancelled {
		scan_run_destroy(&def_run)
		return nil, wrapped_err(.Cancelled, "dead scan: cancelled", a)
	}
	for i := 0; i < len(files); i += 1 {
		job := def_jobs[i]
		if job == nil || len(job.defs) == 0 {
			continue
		}
		path := strings.clone(files[i].rel, a)
		for def in job.defs {
			// The map keys must own their bytes: `def.name` views the
			// worker result arena, which dies at scan_run_destroy below —
			// an arena-view key rots with it and every later lookup
			// misses. The def record shares this clone.
			name := strings.clone(def.name, a)
			if _, seen := name_set[name]; !seen {
				name_set[name] = true
				uses[name] = 0
			}
			append(&defs, Dead_Def{
				name         = name,
				path         = path,
				kind         = strings.clone(def.kind, a),
				name_path    = strings.clone(def.name_path, a),
				line         = def.line,
				start_byte   = def.start_byte,
				end_byte     = def.end_byte,
				attr_guarded = def.attr_guarded,
			})
		}
		span_copy := make([]ts.Span, len(job.spans), a)
		for j in 0..<len(job.spans) {
			span_copy[j] = job.spans[j]
		}
		spans[path] = span_copy
		stats.files_parsed += 1
		stats.definitions += len(job.defs)
	}
	scan_run_destroy(&def_run)

	// Use pass — strictly after the whole definition pass (and its merge):
	// any name the project defines must already sit in name_set when any
	// file's tokens are counted. name_set and spans are frozen read-only
	// for the workers; one count per name and only zero/nonzero matters,
	// so summing per-file hit maps in walk order lands on the exact
	// sequential totals.
	use_jobs := make([]^Dead_Use_Job, len(files), a)
	use_ctx := Dead_Use_Ctx{
		src      = src,
		files    = files[:],
		jobs     = use_jobs[:],
		name_set = &name_set,
		spans    = &spans,
	}
	use_run := scan_run(src.allocator, len(files), token, dead_scan_uses_body, &use_ctx, 0)
	if use_run.cancelled {
		scan_run_destroy(&use_run)
		return nil, wrapped_err(.Cancelled, "dead scan: cancelled", a)
	}
	for i := 0; i < len(files); i += 1 {
		job := use_jobs[i]
		if job == nil {
			continue
		}
		if job.unreadable {
			dead_scan_mark_unreadable(files[i].rel, &defs)
			continue
		}
		for name, n in job.hits {
			uses[name] += n
		}
		if job.scanned {
			stats.files_scanned += 1
		}
	}
	scan_run_destroy(&use_run)

	// Judgement: zero uses, no convention guard, path filter, then the
	// report limit. Candidates keep walk order until the final sort.
	prefix_slash := ""
	if path_prefix != "" {
		prefix_slash = strings.concatenate({path_prefix, "/"}, a)
	}
	out := make([dynamic]Dead_Scan_Candidate, 0, 16, a)
	stats.candidates_total = 0
	for i in 0..<len(defs) {
		def := defs[i]
		if def.unreadable || def.attr_guarded || uses[def.name] > 0 {
			continue
		}
		if dead_scan_is_entry(def.name, entry_prefixes) {
			continue
		}
		if path_prefix != "" && def.path != path_prefix && !strings.has_prefix(def.path, prefix_slash) {
			continue
		}
		stats.candidates_total += 1
		if len(out) < limit {
			append(&out, Dead_Scan_Candidate{
				path      = def.path,
				line      = def.line,
				kind      = def.kind,
				name      = def.name,
				name_path = def.name_path,
			})
		}
	}
	stats.truncated = stats.candidates_total > len(out)
	sc := Sorted_Candidates{items = out}
	if len(out) > 1 {
		sort.sort({len = ds_len, less = ds_less, swap = ds_swap, collection = &sc})
	}
	return out[:], nil
}

Sorted_Candidates :: struct {
	items: [dynamic]Dead_Scan_Candidate,
}

// Dead_Scan_Walk is the walk's shared state (the crawl's Crawl_Walk
// counterpart, without the index batch): everything the per-directory
// helper needs that never changes across the walk.
Dead_Scan_Walk :: struct {
	src:       ^TS_Source,
	ignore:    Ignore_Config,
	deny:      ^safety.Deny_List,
	walk:      mem.Allocator, // walk-frame arena (recursed dir paths, the file list — O(depth + files kept))
	scratch:   ^mem.Dynamic_Arena, // per-directory scratch, reset per directory
	rel_buf:   ^[dynamic]u8, // reusable child rel-path builder (see dead_scan_dir)
	abs_buf:   ^[dynamic]u8, // reusable child abs-path builder
	files:     ^[dynamic]Dead_Scan_File,
	token:     ^platform.Cancel_Token,
	truncated: bool,
	cancelled: bool,
}

// dead_scan_dir mirrors crawl_dir's traversal rules (ignore stack, deny
// list, symlink skip, depth cap) and its enumeration discipline: entries
// are freed at each directory boundary and child paths build in the
// reusable buffers, so only the kept file records and the recursion's
// cloned paths (both on the walk allocator) scale beyond one directory.
dead_scan_dir :: proc(w: ^Dead_Scan_Walk, abs_dir, rel_dir: string, depth: int, stack: ^[dynamic]^pathspec.Path_Spec) -> (stopped: bool) {
	if depth > MAX_CRAWL_DEPTH {
		w.truncated = true
		return false
	}
	mem.dynamic_arena_free_all(w.scratch)
	scratch := mem.dynamic_arena_allocator(w.scratch)
	entries, derr := os.read_all_directory_by_path(abs_dir, w.src.allocator)
	if derr != nil {
		return false
	}
	defer os.file_info_slice_delete(entries, w.src.allocator)
	sort_entries_by_name(entries)

	pushed := false
	if !w.ignore.no_gitignore {
		pushed = maybe_push_gitignore(w.src.allocator, scratch, abs_dir, rel_dir, stack)
	}

	walk_buf_set(w.rel_buf, rel_dir)
	walk_buf_set(w.abs_buf, abs_dir)
	rel_mark := len(w.rel_buf^)
	abs_mark := len(w.abs_buf^)

	for i in 0..<len(entries) {
		if w.token != nil {
			if _, fired := platform.token_check(w.token); fired {
				w.cancelled = true
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
			if !w.ignore.no_gitignore && stack_match_dir(stack, child_rel, scratch) {
				resize(w.rel_buf, rel_mark)
				continue
			}
			walk_buf_append(w.abs_buf, "/")
			walk_buf_append(w.abs_buf, name)
			child_abs := string(w.abs_buf^[:])
			if w.deny != nil && safety.is_denied(w.deny, child_abs) {
				resize(w.abs_buf, abs_mark)
				resize(w.rel_buf, rel_mark)
				continue
			}
			if dead_scan_dir(
				w,
				strings.clone(child_abs, w.walk),
				strings.clone(child_rel, w.walk),
				depth + 1,
				stack,
			) {
				stopped = true
			}
			resize(w.abs_buf, abs_mark)
		case .Regular:
			if len(w.files^) >= MAX_CRAWL_FILES {
				w.truncated = true
				stopped = true
			} else {
				// Ignored and deny-listed files stay invisible to both
				// passes — the same rule the crawl applies.
				skip := !w.ignore.no_gitignore && stack_match_file(stack, child_rel)
				walk_buf_append(w.abs_buf, "/")
				walk_buf_append(w.abs_buf, name)
				child_abs := string(w.abs_buf^[:])
				if !skip && !(w.deny != nil && safety.is_denied(w.deny, child_abs)) {
					// The record outlives this directory's buffer views —
					// every string is cloned onto the walk allocator.
					append(w.files, Dead_Scan_File{
						rel      = strings.clone(child_rel, w.walk),
						abs      = strings.clone(child_abs, w.walk),
						filename = strings.clone(name, w.walk),
					})
				}
				resize(w.abs_buf, abs_mark)
			}
		case: // symlinks and special files are skipped, not followed
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

// dead_scan_files enumerates the project's regular files under the crawl's
// traversal rules (ignore stack, deny list, symlink skip, depth cap, file
// budget): the shared phase 0 of the dead-code and clone scans, so both
// hold one notion of "the project". File records live on `walk`;
// enumeration transients are freed per directory boundary (see
// dead_scan_dir) — callers hand their walk-frame arena and per-directory
// scratch arena, and own the files dynamic.
dead_scan_files :: proc(
	src: ^TS_Source,
	ignore: Ignore_Config,
	deny: ^safety.Deny_List,
	token: ^platform.Cancel_Token,
	walk: mem.Allocator,
	scratch: ^mem.Dynamic_Arena,
	files: ^[dynamic]Dead_Scan_File,
) -> (truncated: bool, cancelled: bool) {
	stack := make([dynamic]^pathspec.Path_Spec, 0, 8, src.allocator)
	defer {
		for i in 0..<len(stack) {
			pathspec.pathspec_destroy(stack[i])
		}
		delete(stack)
	}
	rel_buf := make([dynamic]u8, 0, 512, src.allocator)
	defer delete(rel_buf)
	abs_buf := make([dynamic]u8, 0, 1024, src.allocator)
	defer delete(abs_buf)
	w := Dead_Scan_Walk{
		src     = src,
		ignore  = ignore,
		deny    = deny,
		walk    = walk,
		scratch = scratch,
		rel_buf = &rel_buf,
		abs_buf = &abs_buf,
		files   = files,
		token   = token,
	}
	dead_scan_dir(&w, src.project_root, "", 0, &stack)
	return w.truncated, w.cancelled
}

// One file's definition-pass output, built in a worker's result arena
// and cloned into the caller's allocator by the merge.
Dead_Defs_Job :: struct {
	defs:  [dynamic]Dead_Def,
	spans: [dynamic]ts.Span, // source-order name spans (sorted for the use pass)
}

Dead_Defs_Ctx :: struct {
	src:   ^TS_Source,
	files: []Dead_Scan_File,
	jobs:  []^Dead_Defs_Job, // one slot per file, written by its claiming worker, read after the join
}

// dead_scan_defs_body runs one file's definition work on a scan worker:
// read, grammar resolution, the outline query through scan_tree_acquire
// (the L2 hot cache when the bytes match, a fresh parse freed at release
// otherwise — scans never land their parses in the cache), and the
// flattening collect — all into the
// worker's arenas. Per-file failures are silent skips: a file with no
// grammar serves no definitions.
dead_scan_defs_body :: proc(w: ^Scan_Worker, i: int) {
	ctx := cast(^Dead_Defs_Ctx)w.pool.user
	f := ctx.files[i]
	ra := scan_result(w)
	job := new(Dead_Defs_Job, ra)
	job^ = {
		defs  = make([dynamic]Dead_Def, 0, 32, ra),
		spans = make([dynamic]ts.Span, 0, 32, ra),
	}
	ctx.jobs[i] = job

	scratch := scan_scratch(w)
	contents, from_editor := dead_scan_read(ctx.src, f, scratch)
	if contents == "" {
		return
	}
	defer if from_editor {
		delete(contents, ctx.src.ed.allocator)
	}
	idx, ok := ts.registry_detect(f.filename)
	if !ok {
		first := contents
		for b := 0; b < len(contents); b += 1 {
			if contents[b] == '\n' {
				first = contents[:b]
				break
			}
		}
		idx, ok = ts.registry_lookup_by_shebang(first)
		if !ok {
			return
		}
	}
	table := ts.GRAMMARS
	lang := table[idx].name
	o := outliner_for(ctx.src, lang)
	if o == nil {
		return
	}

	h, hok := scan_tree_acquire(ctx.src, lang, contents, f.rel)
	if !hok {
		return
	}
	defer scan_tree_release(&h)
	forest, _ := ts.outline_tree(o, h.tree, contents, scratch)
	if len(forest) == 0 {
		return
	}
	dead_scan_collect(forest, f.rel, contents, &job.defs, &job.spans, ra)
}

// dead_scan_collect flattens one outline forest into definition records
// and name spans (in source order — the spans array stays sorted for the
// use pass's binary search) in the worker's result arena; the merge
// replays them into the scan-wide structures in walk order. The walk is
// an explicit work stack: outline nesting is source-driven and can
// exceed any recursion budget.
dead_scan_collect :: proc(
	forest: []ts.Outline_Symbol,
	path: string,
	contents: string,
	defs: ^[dynamic]Dead_Def,
	file_spans: ^[dynamic]ts.Span,
	a: mem.Allocator,
) {
	Collect_Item :: struct {
		sym:    ts.Outline_Symbol,
		prefix: string,
	}
	stack := make([dynamic]Collect_Item, 0, 64, context.temp_allocator)
	defer delete(stack)
	for i := len(forest) - 1; i >= 0; i -= 1 {
		append(&stack, Collect_Item{sym = forest[i]})
	}
	for len(stack) > 0 {
		item := stack[len(stack) - 1]
		pop(&stack)
		sym := item.sym
		name := strings.clone(sym.name, a)
		name_path := name
		if item.prefix != "" {
			name_path = strings.concatenate({item.prefix, "/", name}, a)
		}
		if sym.owner != "" {
			name_path = strings.concatenate({sym.owner, "/", name_path}, a)
		}
		append(defs, Dead_Def{
			name         = name,
			path         = strings.clone(path, a),
			kind         = strings.clone(sym.kind, a),
			name_path    = name_path,
			line         = i64(sym.name_span.start_point.row),
			start_byte   = sym.name_span.start_byte,
			end_byte     = sym.name_span.end_byte,
			attr_guarded = dead_scan_attr_guarded(contents, sym.name_span.start_byte),
		})
		append(file_spans, sym.name_span)
		for i := len(sym.children) - 1; i >= 0; i -= 1 {
			if len(stack) < DEAD_SCAN_MAX_DEPTH {
				append(&stack, Collect_Item{sym = sym.children[i], prefix = name_path})
			}
		}
	}
}

// dead_scan_attr_guarded reports whether the nearest non-blank line above
// the definition's name starts with '@' — Odin attributes
// (@(test)/@(export)) and Python/TS/Java decorators. Convention-invoked
// definitions are excluded from the candidate set.
dead_scan_attr_guarded :: proc(contents: string, at_byte: u32) -> bool {
	if at_byte > u32(len(contents)) {
		return false
	}
	// Line start of the name's line.
	start := int(at_byte)
	for start > 0 && contents[start - 1] != '\n' {
		start -= 1
	}
	// Walk up over blank lines; the first non-blank line decides.
	for start > 0 {
		prev_end := start - 1 // the '\n' of the line above
		prev_start := prev_end
		for prev_start > 0 && contents[prev_start - 1] != '\n' {
			prev_start -= 1
		}
		trimmed := strings.trim_space(contents[prev_start:prev_end])
		if len(trimmed) == 0 {
			start = prev_start
			continue
		}
		return trimmed[0] == '@'
	}
	return false
}

// One file's use-pass output, built in a worker's result arena.
Dead_Use_Job :: struct {
	unreadable: bool,           // the read-back failed; the merge marks the file's definitions alive
	scanned:    bool,           // counted in files_scanned
	hits:       map[string]int, // per-file use counts; keys cloned into the result arena (contents views die with the scratch reset)
}

Dead_Use_Ctx :: struct {
	src:      ^TS_Source,
	files:    []Dead_Scan_File,
	jobs:     []^Dead_Use_Job,
	name_set: ^map[string]bool, // frozen by the completed definition merge; read-only here
	spans:    ^map[string][]ts.Span, // likewise frozen
}

// dead_scan_uses_body tokenizes one file on a scan worker and counts,
// per definition name, the word occurrences outside declaration name
// spans. name_set and spans are read-only for the whole pass. A file
// the definition pass recorded but this pass cannot read back flags
// unreadable — the merge marks its definitions alive.
dead_scan_uses_body :: proc(w: ^Scan_Worker, i: int) {
	ctx := cast(^Dead_Use_Ctx)w.pool.user
	f := ctx.files[i]
	ra := scan_result(w)
	job := new(Dead_Use_Job, ra)
	job^ = {hits = make(map[string]int, 8, ra)}
	ctx.jobs[i] = job

	contents, from_editor := dead_scan_read(ctx.src, f, scan_scratch(w))
	if contents == "" {
		job.unreadable = true
		return
	}
	defer if from_editor {
		delete(contents, ctx.src.ed.allocator)
	}

	file_spans, has_spans := ctx.spans^[f.rel]
	if !has_spans {
		// A file the parse pass never served may be binary; a served one
		// was source text and must be counted however odd its bytes.
		sniff_len := len(contents)
		if sniff_len > DEAD_SCAN_SNIFF_BYTES {
			sniff_len = DEAD_SCAN_SNIFF_BYTES
		}
		for b := 0; b < sniff_len; b += 1 {
			if contents[b] == 0 {
				return
			}
		}
	}

	c := 0
	for c < len(contents) {
		if !dead_scan_word_start(contents[c]) {
			c += 1
			continue
		}
		j := c + 1
		for j < len(contents) && dead_scan_word_part(contents[j]) {
			j += 1
		}
		token := contents[c:j]
		if _, hit := ctx.name_set^[token]; hit {
			if !has_spans || !dead_scan_in_spans(file_spans, u32(c), u32(j)) {
				if n, ok := job.hits[token]; ok {
					job.hits[token] = n + 1
				} else {
					job.hits[strings.clone(token, ra)] = 1
				}
			}
		}
		c = j
	}
	job.scanned = true
}

// dead_scan_read resolves one file's bytes: the editor's view when it
// holds one (unsaved-buffer uses stay visible), else the disk read under
// the crawl's size budget — enforced at read time, so a file growing past
// the cap mid-scan still refuses. "" covers empty, oversize, and
// unreadable alike — none of them can carry definitions or uses.
dead_scan_read :: proc(src: ^TS_Source, f: Dead_Scan_File, scratch: mem.Allocator) -> (contents: string, from_editor: bool) {
	if src.ed != nil {
		read, rerr, _ := editor.editor_read_file(src.ed, f.rel)
		if rerr == .None {
			return read, true
		}
	}
	data, outcome := util.read_bounded_file(f.abs, MAX_SOURCE_FILE_BYTES, scratch)
	if outcome != .Ok {
		return "", false
	}
	// Match the editor's buffer view for UTF-8 files (BOM-stripped,
	// \r\n pairs folded): both passes then see identical bytes whether a
	// file resolves through an open buffer or the disk, so recorded name
	// spans stay aligned with the tokenized text. The lone-\r rewrite in
	// read_text_normalise_cr is length-preserving — offsets survive it.
	body := util.strip_utf8_bom(data)
	return read_text_normalise_cr(string(body), scratch), false
}

dead_scan_mark_unreadable :: proc(rel: string, defs: ^[dynamic]Dead_Def) {
	for i in 0..<len(defs^) {
		if defs^[i].path == rel {
			defs^[i].unreadable = true
		}
	}
}

// dead_scan_in_spans reports a token [start, end) fully inside one of
// the file's (sorted) name spans. A definition's own name token is not a
// use of the name.
dead_scan_in_spans :: proc(file_spans: []ts.Span, start, end: u32) -> bool {
	lo, hi := 0, len(file_spans)
	for lo < hi {
		mid := (lo + hi) / 2
		if file_spans[mid].start_byte <= start {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {
		return false
	}
	span := file_spans[lo - 1]
	return start >= span.start_byte && end <= span.end_byte
}

// Word shape: identifiers start with a letter/_/$/non-ASCII byte and
// continue with those or digits. Every byte >= 0x80 is a word byte, so
// UTF-8 identifiers tokenize exactly as their declaration did; prose
// merely grows junk tokens that never hit the name set.
dead_scan_word_start :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$' || c >= 0x80
}

dead_scan_word_part :: proc(c: u8) -> bool {
	return dead_scan_word_start(c) || (c >= '0' && c <= '9')
}

dead_scan_is_entry :: proc(name: string, entry_prefixes: []string) -> bool {
	for p in entry_prefixes {
		if p != "" && strings.has_prefix(name, p) {
			return true
		}
	}
	return false
}

ds_len :: proc(it: sort.Interface) -> int {
	sc := cast(^Sorted_Candidates)it.collection
	return len(sc.items)
}

ds_less :: proc(it: sort.Interface, i, j: int) -> bool {
	sc := cast(^Sorted_Candidates)it.collection
	a, b := sc.items[i], sc.items[j]
	if a.path != b.path {
		return a.path < b.path
	}
	if a.line != b.line {
		return a.line < b.line
	}
	return a.name < b.name
}

ds_swap :: proc(it: sort.Interface, i, j: int) {
	sc := cast(^Sorted_Candidates)it.collection
	sc.items[i], sc.items[j] = sc.items[j], sc.items[i]
}
