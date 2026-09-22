// Duplicate-code (clone) scan: one whole-project walk under the crawl's
// traversal rules, then a structural pass over every grammar-served
// file, spread over the bounded scan pool (scan_pool) and merged in
// walk order — per-file work runs in parallel, but record indices and
// bucket append order come from the merge, so the assembled answer is
// identical to a sequential walk. Each named subtree of at least
// min_nodes named nodes becomes a candidate
// carrying two hashes over the full child structure — named and anonymous
// nodes alike, comments dropped. Formatting and comment noise never reach
// the hash; operators do, because an anonymous node's kind is its literal
// text (so `a+b` and `a-b` hash apart).
//
//	exact   — kinds and leaf texts as written. Two fragments share it iff
//	          their trees are identical (a Type-1 clone).
//	renamed — identifier leaves canonicalized by first occurrence within
//	          the fragment (de Bruijn style) and every other named leaf
//	          abstracted to its kind. Two fragments share it iff some
//	          consistent bijective identifier renaming — with any literal
//	          values — maps one onto the other (a Type-2 clone). A
//	          non-injective merge (two names collapsed into one) keeps the
//	          hashes apart by construction.
//
// Buckets key on (language, hash), so equal shapes in different grammars
// never group. Exact buckets with >= 2 records report as kind "exact"; a
// renamed bucket spanning >= 2 distinct exact hashes reports as kind
// "renamed" carrying all its records (exact twins and their renamed
// cousins stay visible in one group). Maximal-clone suppression then walks
// the groups largest-first and drops any record whose span lies inside an
// already-kept record of the same file, so the interior blocks of a large
// duplicate do not re-report as their own groups; an exact group below
// two surviving records disappears, while a renamed group reports fully
// whenever one record survives (its occurrences are facts about one
// canonical fragment — covered members ride along).
//
// The answer is deterministic by construction: the walk order is sorted,
// every list is ordered, and the report order is the total order
// (descending node count, first record's (path, start_byte), kind, hash) —
// no map iteration order reaches the output. Candidates covering a parse
// error are skipped: their structure is parser guesswork, not code.
package svc

import "core:encoding/json"
import "core:mem"
import "core:sort"
import "core:strings"
import "src:jsonutil"
import "src:platform"
import "src:safety"
import "src:ts"

CLONE_SCAN_DEFAULT_MIN_NODES :: 50
CLONE_SCAN_MIN_NODES_FLOOR :: 10
CLONE_SCAN_MAX_MIN_NODES :: 100000
CLONE_SCAN_DEFAULT_LIMIT :: 50
CLONE_SCAN_MAX_LIMIT :: 500
// The hash walk checks the cancel token every N popped nodes so a cancel
// takes effect inside a file, not at the next file boundary.
CLONE_SCAN_CANCEL_EVERY :: 4096
// Depth bound for both walk stacks, mirroring the dead-scan walkers:
// generated or adversarial trees nest arbitrarily deep; past the bound the
// walk skips the deeper subtree (degrade, never crash).
CLONE_SCAN_MAX_DEPTH :: 500

METHOD_AST_FIND_DUPLICATES :: "svc.ast/find_duplicates" // request: {path_prefix?, min_nodes?, limit?} -> {groups: [...], stats: {...}}

// FNV-1a 64 over the hashed bytes; the constants are the published ones,
// so identical trees hash identically across runs, platforms, and builds.
CLONE_FNV_OFFSET :: 0xcbf29ce484222325
CLONE_FNV_PRIME :: 0x100000001b3

Clone_Kind :: enum {
	Exact,
	Renamed,
}

Clone_Span :: struct {
	path:       string, // project-relative, caller-arena clone
	start_line: i64, // 0-based row, inclusive
	end_line:   i64, // 0-based row, inclusive
}

Clone_Group :: struct {
	kind:      Clone_Kind,
	root_kind: string, // tree-sitter kind of the fragment root
	nodes:     int, // named-node count of one occurrence
	spans:     []Clone_Span,
}

Clone_Stats :: struct {
	files_scanned:  int, // files whose contents were read
	files_parsed:   int, // files that contributed >= 1 candidate
	groups_total:   int, // groups surviving suppression, before the limit
	truncated:      bool, // groups list cut by limit
	walk_truncated: bool, // file walk hit MAX_CRAWL_FILES
}

// One candidate subtree occurrence. Every string the record carries lives
// in the caller's allocator; the record never borrows walk-arena memory.
Clone_Record :: struct {
	path:         string,
	root_kind:    string,
	lang:         string, // static grammar-table string (never dies)
	start_byte:   u32,
	end_byte:     u32,
	start_row:    i64,
	end_row:      i64,
	nodes:        int,
	exact_hash:   u64,
	renamed_hash: u64,
}

// Bucket key: a hash is only comparable within one grammar.
Clone_Key :: struct {
	lang: string, // static grammar-table string (never dies)
	hash: u64,
}

Pending_Group :: struct {
	kind:    Clone_Kind,
	key:     Clone_Key,
	records: []int,
}

clone_scan :: proc(
	src: ^TS_Source,
	path_prefix: string, // normalized project-relative dir, "" = whole project
	min_nodes: int,
	limit: int,
	ignore: Ignore_Config,
	deny: ^safety.Deny_List,
	stats: ^Clone_Stats,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> (groups: []Clone_Group, err: platform.Err) {
	stats^ = {}

	walk_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&walk_arena, src.allocator)
	defer mem.dynamic_arena_destroy(&walk_arena)
	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, src.allocator)
	defer mem.dynamic_arena_destroy(&scratch_arena)

	// Phase 0: the file list, under the crawl's traversal rules — the
	// dead-scan walker verbatim, so both scans share one notion of
	// "the project".
	files := make([dynamic]Dead_Scan_File, 0, 128, mem.dynamic_arena_allocator(&walk_arena))
	walk_truncated, walk_cancelled := dead_scan_files(src, ignore, deny, token, mem.dynamic_arena_allocator(&walk_arena), &scratch_arena, &files)
	if walk_cancelled {
		return nil, wrapped_err(.Cancelled, "clone scan: cancelled", a)
	}
	stats.walk_truncated = walk_truncated

	// Phase 1: candidates, parallel over the scan pool. Records and
	// buckets live in `a` for the whole scan; map values are rewritten
	// after each append (a dynamic's header is stored by value). The
	// merge replays each file's records and bucket adds in walk order,
	// so global record indices land exactly as the sequential scan wrote
	// them.
	prefix_slash := ""
	if path_prefix != "" {
		prefix_slash = strings.concatenate({path_prefix, "/"}, a)
	}
	records := make([dynamic]Clone_Record, 0, 256, a)
	exact_buckets := make(map[Clone_Key][dynamic]int, 64, a)
	renamed_buckets := make(map[Clone_Key][dynamic]int, 64, a)
	clone_jobs := make([]^Clone_Job, len(files), a)
	clone_ctx := Clone_Scan_Ctx{
		src          = src,
		files        = files[:],
		jobs         = clone_jobs[:],
		min_nodes    = min_nodes,
		path_prefix  = path_prefix,
		prefix_slash = prefix_slash,
	}
	clone_run := scan_run(src.allocator, len(files), token, clone_scan_body, &clone_ctx, 0)
	if clone_run.cancelled {
		scan_run_destroy(&clone_run)
		return nil, wrapped_err(.Cancelled, "clone scan: cancelled", a)
	}
	for i := 0; i < len(files); i += 1 {
		job := clone_jobs[i]
		if job == nil {
			continue
		}
		if job.read {
			stats.files_scanned += 1
		}
		if len(job.records) == 0 {
			continue
		}
		base := len(records)
		path := strings.clone(job.records[0].path, a)
		for r in job.records {
			append(&records, Clone_Record{
				path         = path,
				root_kind    = strings.clone(r.root_kind, a),
				lang         = r.lang,
				start_byte   = r.start_byte,
				end_byte     = r.end_byte,
				start_row    = r.start_row,
				end_row      = r.end_row,
				nodes        = r.nodes,
				exact_hash   = r.exact_hash,
				renamed_hash = r.renamed_hash,
			})
		}
		for add in job.adds {
			if add.renamed {
				clone_bucket_add(&renamed_buckets, add.key, base + add.local, a)
			} else {
				clone_bucket_add(&exact_buckets, add.key, base + add.local, a)
			}
		}
		stats.files_parsed += 1
	}
	scan_run_destroy(&clone_run)

	// Phase 2: groups. Bucket iteration order never reaches the output —
	// the report is re-sorted on a total order below.
	pending := make([dynamic]Pending_Group, 0, 16, a)
	for key, idxs in exact_buckets {
		if len(idxs) < 2 {
			continue
		}
		clone_sort_records(records[:], idxs[:])
		append(&pending, Pending_Group{kind = .Exact, key = key, records = idxs[:]})
	}
	for key, idxs in renamed_buckets {
		if len(idxs) < 2 {
			continue
		}
		// ">= 2 distinct exact hashes": any record differing from the
		// first. An all-exact bucket is already fully reported as its
		// exact group; a renamed cousin is what makes the finding.
		mixed := false
		for i in 1..<len(idxs) {
			if records[idxs[i]].exact_hash != records[idxs[0]].exact_hash {
				mixed = true
				break
			}
		}
		if !mixed {
			continue
		}
		clone_sort_records(records[:], idxs[:])
		append(&pending, Pending_Group{kind = .Renamed, key = key, records = idxs[:]})
	}
	sc := Sorted_Pending{items = pending, records = records[:]}
	if len(pending) > 1 {
		sort.sort({len = cp_len, less = cp_less, swap = cp_swap, collection = &sc})
	}

	// Phase 3: maximal-clone suppression, largest first. `kept` files the
	// byte spans already reported; a record contained in a kept span of
	// the same file drops out. An exact group needs two surviving records.
	// A renamed group reports its WHOLE record set whenever at least one
	// record survives outside every kept span: its occurrences are facts
	// about one canonical fragment, so the members an exact group already
	// covered ride along instead of vanishing (the exact pair and its
	// renamed cousin stay visible together) — but only the survivors'
	// spans become covering spans.
	kept := make(map[string][dynamic]Clone_Span_Bytes, 8, a)
	out := make([dynamic]Clone_Group, 0, 16, a)
	stats.groups_total = 0
	for gi in 0..<len(pending) {
		g := pending[gi]
		survivors := make([dynamic]int, 0, len(g.records), context.temp_allocator)
		for idx in g.records {
			r := records[idx]
			if clone_span_covered(&kept, r.path, r.start_byte, r.end_byte) {
				continue
			}
			append(&survivors, idx)
		}
		report := len(survivors) >= 2
		if !report && g.kind == .Renamed && len(g.records) >= 2 && len(survivors) >= 1 {
			report = true
		}
		if !report {
			continue
		}
		stats.groups_total += 1
		if len(out) >= limit {
			continue
		}
		span_source := survivors[:]
		if g.kind == .Renamed {
			span_source = g.records
		}
		spans := make([]Clone_Span, len(span_source), a)
		for i in 0..<len(span_source) {
			r := records[span_source[i]]
			spans[i] = {path = r.path, start_line = r.start_row, end_line = r.end_row}
		}
		for idx in survivors {
			r := records[idx]
			clone_span_keep(&kept, r.path, r.start_byte, r.end_byte, a)
		}
		first := records[g.records[0]]
		append(&out, Clone_Group{
			kind      = g.kind,
			root_kind = first.root_kind,
			nodes     = first.nodes,
			spans     = spans,
		})
	}
	stats.truncated = stats.groups_total > len(out)
	return out[:], nil
}

// One file's phase-1 output, built in a worker's result arena and
// replayed into the scan-wide records and buckets by the merge.
Clone_Job :: struct {
	read:    bool,
	records: [dynamic]Clone_Record,
	adds:    [dynamic]Clone_Add,
}

// One bucket membership: which bucket (exact/renamed), the bucket key,
// and the record's LOCAL index within its job (the merge rebases it).
Clone_Add :: struct {
	renamed: bool,
	key:     Clone_Key,
	local:   int,
}

Clone_Scan_Ctx :: struct {
	src:          ^TS_Source,
	files:        []Dead_Scan_File,
	jobs:         []^Clone_Job, // one slot per file, written by its claiming worker, read after the join
	min_nodes:    int,
	path_prefix:  string, // normalized project-relative dir, "" = whole project
	prefix_slash: string,
}

clone_scan_body :: proc(w: ^Scan_Worker, i: int) {
	ctx := cast(^Clone_Scan_Ctx)w.pool.user
	f := ctx.files[i]
	// path_prefix filters the report: out-of-scope occurrences cannot
	// group (the dead scan applies the same rule to its candidates).
	if ctx.path_prefix != "" && f.rel != ctx.path_prefix && !strings.has_prefix(f.rel, ctx.prefix_slash) {
		return
	}
	ra := scan_result(w)
	job := new(Clone_Job, ra)
	job^ = {
		records = make([dynamic]Clone_Record, 0, 16, ra),
		adds    = make([dynamic]Clone_Add, 0, 16, ra),
	}
	ctx.jobs[i] = job
	read, cancelled := clone_scan_file(ctx.src, f, ctx.min_nodes, job, scan_scratch(w), ra, w.pool.token)
	job.read = read
	if cancelled {
		w.cancel_seen = true
	}
}

// Clone_Span_Bytes is a suppression bookkeeping span: file-relative byte
// range of an already-reported occurrence (tree byte ranges nest exactly).
Clone_Span_Bytes :: struct {
	start, end: u32,
}

// Clone_File_Ctx carries one file's scan state so the walk helpers take
// the context, not a parameter list that grows with every field.
Clone_File_Ctx :: struct {
	path:          string, // result-arena clone of the rel path
	lang:          string,
	contents:      string,
	min_nodes:     int,
	job:           ^Clone_Job, // this file's records and bucket adds
	a:             mem.Allocator, // the worker's result arena
	scratch:       mem.Allocator, // the main walk's per-file frame data
	// The renamed-hash pass gets its own arena, reset after every
	// candidate: the pass runs once per candidate, and without the reset
	// one deeply nested file would accumulate every pass's frames —
	// O(sum of candidate sizes), quadratic on adversarial files. With it,
	// the pass costs at most one candidate's worth of memory.
	renamed_arena: ^mem.Dynamic_Arena,
	token:         ^platform.Cancel_Token,
}

// clone_scan_file parses one file and fills its job's candidate records.
// Per-file failures are silent skips (no grammar, unreadable, unparseable
// — none can carry candidates). Returns whether anything was read and
// whether the cancel token fired mid-walk.
clone_scan_file :: proc(
	src: ^TS_Source,
	f: Dead_Scan_File,
	min_nodes: int,
	job: ^Clone_Job,
	scratch: mem.Allocator,
	ra: mem.Allocator,
	token: ^platform.Cancel_Token,
) -> (read: bool, cancelled: bool) {
	contents, from_editor := dead_scan_read(src, f, scratch)
	if contents == "" {
		return false, false
	}
	defer if from_editor {
		delete(contents, src.ed.allocator)
	}

	idx, ok := ts.registry_detect(f.filename)
	if !ok {
		first := contents
		for i := 0; i < len(contents); i += 1 {
			if contents[i] == '\n' {
				first = contents[:i]
				break
			}
		}
		idx, ok = ts.registry_lookup_by_shebang(first)
		if !ok {
			return true, false
		}
	}
	table := ts.GRAMMARS
	lang := table[idx].name

	// The tree comes through scan_tree_acquire: a byte-identical L2 hot
	// cache entry is borrowed; anything else parses fresh and is freed at
	// release (scans never land parses in the cache — see
	// Scan_Tree_Handle).
	h, hok := scan_tree_acquire(src, lang, contents, f.rel)
	if !hok {
		return true, false
	}
	defer scan_tree_release(&h)
	root := ts.tree_root_node(h.tree)
	if ts.node_is_null(root) {
		return true, false
	}

	renamed_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&renamed_arena, src.allocator)
	defer mem.dynamic_arena_destroy(&renamed_arena)

	c := Clone_File_Ctx{
		path          = strings.clone(f.rel, ra),
		lang          = lang,
		contents      = contents,
		min_nodes     = min_nodes,
		job           = job,
		a             = ra,
		scratch       = scratch,
		renamed_arena = &renamed_arena,
		// The hash walk keeps its intra-file cancel checkpoints (per
		// candidate and every CLONE_SCAN_CANCEL_EVERY nodes) — the pool's
		// claim loop only checkpoints between files.
		token         = token,
	}
	if !clone_hash_walk(&c, root) {
		return true, true
	}
	return true, false
}

// One frame of the hash walk's explicit post-order stack.
Clone_Walk_Frame :: struct {
	node:        ts.Node,
	child_index: u32, // next child to descend into
	child_count: u32,
	had_children: bool, // the node had any children at all (comments may leave the list empty)
	hashes:      [dynamic]u64, // child hashes, in child order
	nodes:       int, // named-node count accumulated from children
}

// clone_hash_walk hashes every node bottom-up and records candidates.
// FNV-1a 64 runs over the node's kind (a flag byte marks named vs
// anonymous — anonymous kinds are literal text), then, in order, the
// children's hashes; a named leaf folds its source text in (an anonymous
// leaf is its kind). Comment nodes are skipped wholesale. Each named,
// error-free subtree of at least min_nodes named nodes becomes a
// candidate: the exact hash straight from this walk, the renamed hash from
// a dedicated canonicalizing pass over that subtree. The stack is explicit
// so deep generated trees cannot overflow the thread stack; the frame hash
// lists live in the per-file scratch arena and total out linear in the
// file's node count (the arena resets at the next file).
clone_hash_walk :: proc(c: ^Clone_File_Ctx, root: ts.Node) -> (completed: bool) {
	frames := make([dynamic]Clone_Walk_Frame, 0, 64, c.scratch)
	append(&frames, Clone_Walk_Frame{
		node         = root,
		child_count  = ts.node_child_count(root),
		had_children = ts.node_child_count(root) > 0,
		hashes       = make([dynamic]u64, 0, 4, c.scratch),
	})
	since_check := 0
	for len(frames) > 0 {
		fi := len(frames) - 1
		if frames[fi].child_index < frames[fi].child_count {
			child := ts.node_child(frames[fi].node, frames[fi].child_index)
			frames[fi].child_index += 1
			if ts.node_is_null(child) || clone_is_comment(child) {
				continue
			}
			if len(frames) >= CLONE_SCAN_MAX_DEPTH {
				continue // skip the too-deep subtree; the parent completes
			}
			append(&frames, Clone_Walk_Frame{
				node         = child,
				child_count  = ts.node_child_count(child),
				had_children = ts.node_child_count(child) > 0,
				hashes       = make([dynamic]u64, 0, 4, c.scratch),
			})
			continue
		}

		// Children done: fold this node's values.
		fr := frames[fi]
		h := clone_hash_node(fr.node, fr.hashes[:], fr.had_children, c.contents)
		nodes := fr.nodes
		if ts.node_is_named(fr.node) {
			nodes += 1
		}
		if ts.node_is_named(fr.node) && !clone_is_comment(fr.node) && nodes >= c.min_nodes && !ts.node_has_error(fr.node) {
			if c.token != nil {
				if _, fired := platform.token_check(c.token); fired {
					return false
				}
			}
			rh, ok := clone_renamed_hash(fr.node, c)
			// Reset the pass's arena per candidate (see Clone_File_Ctx):
			// the next candidate starts from a clean frame arena however
			// many candidates this file carries.
			mem.dynamic_arena_free_all(c.renamed_arena)
			if ok {
				clone_record_candidate(&fr, h, rh, nodes, c)
			}
		}

		pop(&frames)
		if len(frames) > 0 {
			parent := &frames[len(frames) - 1]
			append(&parent.hashes, h)
			parent.nodes += nodes
		}

		since_check += 1
		if since_check >= CLONE_SCAN_CANCEL_EVERY {
			since_check = 0
			if c.token != nil {
				if _, fired := platform.token_check(c.token); fired {
					return false
				}
			}
		}
	}
	return true
}

// clone_hash_node is one node's exact hash: named/anonymous flag, kind,
// then the child hashes in order; a true named leaf folds its text in (an
// anonymous leaf is already its literal text as the kind).
clone_hash_node :: proc(node: ts.Node, child_hashes: []u64, had_children: bool, source: string) -> u64 {
	h: u64 = CLONE_FNV_OFFSET
	if ts.node_is_named(node) {
		h = clone_fnv_byte(h, 1)
	} else {
		h = clone_fnv_byte(h, 0)
	}
	h = clone_fnv_bytes(h, ts.cstring_to_string(ts.node_type(node)))
	h = clone_fnv_byte(h, ':')
	for ch in child_hashes {
		h = clone_fnv_u64(h, ch)
		h = clone_fnv_byte(h, ',')
	}
	if !had_children && ts.node_is_named(node) {
		h = clone_fnv_bytes(h, ts.node_text(node, source))
	}
	return h
}

// One frame of the renamed-hash walk's explicit stack.
Clone_Renamed_Frame :: struct {
	node:        ts.Node,
	child_index: u32,
	child_count: u32,
	hashes:      [dynamic]u64,
}

// clone_renamed_hash hashes one subtree with identifiers canonicalized:
// every named leaf whose kind ends in "identifier" is replaced by its
// first-occurrence ordinal within the fragment (de Bruijn style — leaves
// come out of a post-order walk in document order), every other named
// leaf by its kind alone (literal values abstracted; anonymous kinds stay,
// so operators still count). Two fragments share the hash iff a consistent
// bijective identifier renaming maps one onto the other. ok=false means
// the depth bound cut the fragment — the caller skips the candidate.
clone_renamed_hash :: proc(node: ts.Node, c: ^Clone_File_Ctx) -> (hash: u64, ok: bool) {
	// Everything here lives in the pass's own arena (reset per candidate
	// by the caller) — the map, the frame stack, and the per-frame hash
	// lists alike.
	ra := mem.dynamic_arena_allocator(c.renamed_arena)
	seen := make(map[string]int, 8, ra)
	frames := make([dynamic]Clone_Renamed_Frame, 0, 32, ra)
	append(&frames, Clone_Renamed_Frame{
		node        = node,
		child_count = ts.node_child_count(node),
		hashes      = make([dynamic]u64, 0, 4, ra),
	})
	for len(frames) > 0 {
		fi := len(frames) - 1
		if frames[fi].child_index < frames[fi].child_count {
			child := ts.node_child(frames[fi].node, frames[fi].child_index)
			frames[fi].child_index += 1
			if ts.node_is_null(child) || clone_is_comment(child) {
				continue
			}
			if len(frames) >= CLONE_SCAN_MAX_DEPTH {
				return 0, false
			}
			append(&frames, Clone_Renamed_Frame{
				node        = child,
				child_count = ts.node_child_count(child),
				hashes      = make([dynamic]u64, 0, 4, ra),
			})
			continue
		}

		fr := frames[fi]
		h: u64 = CLONE_FNV_OFFSET
		if ts.node_is_named(fr.node) {
			h = clone_fnv_byte(h, 1)
		} else {
			h = clone_fnv_byte(h, 0)
		}
		kind := ts.cstring_to_string(ts.node_type(fr.node))
		h = clone_fnv_bytes(h, kind)
		h = clone_fnv_byte(h, ':')
		for ch in fr.hashes[:] {
			h = clone_fnv_u64(h, ch)
			h = clone_fnv_byte(h, ',')
		}
		if fr.child_count == 0 && ts.node_is_named(fr.node) {
			if strings.has_suffix(kind, "identifier") {
				text := ts.node_text(fr.node, c.contents)
				n, found := seen[text]
				if !found {
					n = len(seen)
					seen[text] = n
				}
				h = clone_fnv_byte(h, '#')
				h = clone_fnv_u64(h, u64(n))
			}
			// Other named leaves (literal values) contribute nothing here:
			// the kind alone is already in the hash.
		}

		pop(&frames)
		if len(frames) == 0 {
			// The root's own hash is the fragment's renamed hash.
			return h, true
		}
		parent := &frames[len(frames) - 1]
		append(&parent.hashes, h)
	}
	return 0, false
}

clone_record_candidate :: proc(fr: ^Clone_Walk_Frame, exact, renamed: u64, nodes: int, c: ^Clone_File_Ctx) {
	append(&c.job.records, Clone_Record{
		path         = c.path,
		root_kind    = strings.clone(ts.cstring_to_string(ts.node_type(fr.node)), c.a),
		lang         = c.lang,
		start_byte   = ts.node_start_byte(fr.node),
		end_byte     = ts.node_end_byte(fr.node),
		start_row    = i64(ts.node_start_point(fr.node).row),
		end_row      = i64(ts.node_end_point(fr.node).row),
		nodes        = nodes,
		exact_hash   = exact,
		renamed_hash = renamed,
	})
	// The merge rebases `local` onto the global record index in walk
	// order, so bucket membership lands exactly as the sequential scan
	// wrote it.
	local := len(c.job.records) - 1
	append(&c.job.adds, Clone_Add{renamed = false, key = Clone_Key{lang = c.lang, hash = exact}, local = local})
	append(&c.job.adds, Clone_Add{renamed = true, key = Clone_Key{lang = c.lang, hash = renamed}, local = local})
}

// clone_bucket_add appends one record index to a bucket, making the list
// on first insert. The key's lang string is a static grammar-table view —
// it never dies, so the stored key header stays valid.
clone_bucket_add :: proc(buckets: ^map[Clone_Key][dynamic]int, key: Clone_Key, idx: int, a: mem.Allocator) {
	lst, ok := buckets^[key]
	if !ok {
		lst = make([dynamic]int, 0, 2, a)
	}
	append(&lst, idx)
	buckets^[key] = lst
}

clone_is_comment :: proc(node: ts.Node) -> bool {
	return ts.cstring_to_string(ts.node_type(node)) == "comment"
}

clone_fnv_byte :: proc(h: u64, b: u8) -> u64 {
	return (h ~ u64(b)) * CLONE_FNV_PRIME
}

clone_fnv_bytes :: proc(h: u64, s: string) -> u64 {
	x := h
	for i in 0..<len(s) {
		x = clone_fnv_byte(x, s[i])
	}
	return x
}

clone_fnv_u64 :: proc(h: u64, v: u64) -> u64 {
	x := h
	for i in 0..<8 {
		x = clone_fnv_byte(x, u8(v >> u64(8 * i)))
	}
	return x
}

clone_span_covered :: proc(kept: ^map[string][dynamic]Clone_Span_Bytes, path: string, start, end: u32) -> bool {
	spans, have := kept^[path]
	if !have {
		return false
	}
	for s in spans {
		if start >= s.start && end <= s.end {
			return true
		}
	}
	return false
}

clone_span_keep :: proc(kept: ^map[string][dynamic]Clone_Span_Bytes, path: string, start, end: u32, a: mem.Allocator) {
	lst, have := kept^[path]
	if !have {
		lst = make([dynamic]Clone_Span_Bytes, 0, 4, a)
	}
	append(&lst, Clone_Span_Bytes{start = start, end = end})
	kept^[path] = lst
}

// ---------------------------------------------------------------------------
// Report ordering (explicit sort.Interface structs, the house style)
// ---------------------------------------------------------------------------

// clone_sort_records orders one group's record indices in place by (path,
// start_byte, end descending) — the outer span first when two share a
// start, so within-group containment resolves outward.
clone_sort_records :: proc(records: []Clone_Record, idxs: []int) {
	if len(idxs) < 2 {
		return
	}
	sr := Sorted_Record_Idx{items = idxs, records = records}
	sort.sort({len = cr_len, less = cr_less, swap = cr_swap, collection = &sr})
}

Sorted_Record_Idx :: struct {
	items:   []int,
	records: []Clone_Record,
}

cr_len :: proc(it: sort.Interface) -> int {
	sr := cast(^Sorted_Record_Idx)it.collection
	return len(sr.items)
}

cr_less :: proc(it: sort.Interface, i, j: int) -> bool {
	sr := cast(^Sorted_Record_Idx)it.collection
	a := sr.records[sr.items[i]]
	b := sr.records[sr.items[j]]
	if a.path != b.path {
		return a.path < b.path
	}
	if a.start_byte != b.start_byte {
		return a.start_byte < b.start_byte
	}
	return a.end_byte > b.end_byte
}

cr_swap :: proc(it: sort.Interface, i, j: int) {
	sr := cast(^Sorted_Record_Idx)it.collection
	sr.items[i], sr.items[j] = sr.items[j], sr.items[i]
}

Sorted_Pending :: struct {
	items:   [dynamic]Pending_Group,
	records: []Clone_Record,
}

cp_len :: proc(it: sort.Interface) -> int {
	cp := cast(^Sorted_Pending)it.collection
	return len(cp.items)
}

// cp_less is the report's total order: descending node count, then the
// first record's (path, start_byte), then kind (exact before renamed),
// then the hash. Two distinct groups never tie on all four — equal hash
// and kind is the same bucket — so the order, and with it the whole
// answer, is a function of the input bytes alone.
cp_less :: proc(it: sort.Interface, i, j: int) -> bool {
	cp := cast(^Sorted_Pending)it.collection
	ga, gb := cp.items[i], cp.items[j]
	ra, rb := cp.records[ga.records[0]], cp.records[gb.records[0]]
	if ra.nodes != rb.nodes {
		return ra.nodes > rb.nodes
	}
	if ra.path != rb.path {
		return ra.path < rb.path
	}
	if ra.start_byte != rb.start_byte {
		return ra.start_byte < rb.start_byte
	}
	if ga.kind != gb.kind {
		return ga.kind == .Exact
	}
	return ga.key.hash < gb.key.hash
}

cp_swap :: proc(it: sort.Interface, i, j: int) {
	cp := cast(^Sorted_Pending)it.collection
	cp.items[i], cp.items[j] = cp.items[j], cp.items[i]
}

// ---------------------------------------------------------------------------
// Wire shapes
// ---------------------------------------------------------------------------

clone_groups_json :: proc(groups: []Clone_Group, arena: mem.Allocator) -> json.Value {
	items := make([]json.Value, len(groups), arena)
	for i in 0..<len(groups) {
		g := groups[i]
		kind_str := "exact"
		if g.kind == .Renamed {
			kind_str = "renamed"
		}
		spans := make([]json.Value, len(g.spans), arena)
		for j in 0..<len(g.spans) {
			so := jsonutil.json_object(3, arena)
			jsonutil.obj_set(&so, "path", jsonutil.json_string(g.spans[j].path))
			jsonutil.obj_set(&so, "start_line", jsonutil.json_int(g.spans[j].start_line))
			jsonutil.obj_set(&so, "end_line", jsonutil.json_int(g.spans[j].end_line))
			spans[j] = json.Value(json.Object(so))
		}
		obj := jsonutil.json_object(4, arena)
		jsonutil.obj_set(&obj, "kind", jsonutil.json_string(kind_str))
		jsonutil.obj_set(&obj, "root_kind", jsonutil.json_string(g.root_kind))
		jsonutil.obj_set(&obj, "nodes", jsonutil.json_int(i64(g.nodes)))
		jsonutil.obj_set(&obj, "occurrences", jsonutil.json_array(spans, arena))
		items[i] = json.Value(json.Object(obj))
	}
	return jsonutil.json_array(items, arena)
}

clone_stats_json :: proc(stats: ^Clone_Stats, arena: mem.Allocator) -> json.Value {
	obj := jsonutil.json_object(5, arena)
	jsonutil.obj_set(&obj, "files_scanned", jsonutil.json_int(i64(stats.files_scanned)))
	jsonutil.obj_set(&obj, "files_parsed", jsonutil.json_int(i64(stats.files_parsed)))
	jsonutil.obj_set(&obj, "groups_total", jsonutil.json_int(i64(stats.groups_total)))
	jsonutil.obj_set(&obj, "truncated", jsonutil.json_bool(stats.truncated))
	jsonutil.obj_set(&obj, "walk_truncated", jsonutil.json_bool(stats.walk_truncated))
	return json.Value(json.Object(obj))
}
