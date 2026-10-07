// Semantic-token highlights face: one compiled highlights query per
// language, held by the caller (the daemon's language-source state caches
// it per language), run over freshly parsed trees. Unlike query_tree —
// a one-shot tool that compiles its query on every call — this face
// compiles once at build and keeps the compiled query plus its predicate
// table together, the same split the outliner uses.
//
// Bounds are this face's own: a source-size gate and a capture-count
// bound. Exceeding either is a typed decline carried in the run result —
// never a silent truncation and never an error — so the caller reports
// the decline instead of serving tokens that stop mid-file. The output
// is a flat capture array sorted by start position ascending; matches
// arrive from the cursor in query order, so the flattening and the sort
// are this file's job.
package ts

import "base:runtime"
import "core:sort"
import "core:strings"

// The face's own bounds (query_tree's MAX_* constants are the tool
// face's, not these): sources past one mebibyte decline before parsing —
// the same magnitude the hot layer's refresh gate uses
// (HOT_EDIT_MAX_SOURCE_BYTES) — and a run emits at most
// HIGHLIGHTS_MAX_CAPTURES captures before declining.
HIGHLIGHTS_MAX_SOURCE_BYTES :: 1 << 20
HIGHLIGHTS_MAX_CAPTURES     :: 8192

// Highlight_Decline closes the run's failure vocabulary. Declines are
// observable outcomes, not errors: an empty source matched nothing, a
// bound was hit and the caller must say so.
Highlight_Decline :: enum {
	None,
	Query_Empty,      // the language ships no highlights query
	Source_Too_Large, // source past HIGHLIGHTS_MAX_SOURCE_BYTES
	Capture_Bound,    // run stopped at HIGHLIGHTS_MAX_CAPTURES or the cursor's matching ceiling
	Nil_Tree,
	Nil_Holder, // caller misuse: build_highlights never returned nil with err == ""
	Internal, // engine allocation failure (query cursor)
}

// Highlights is the compiled-per-language holder. All strings in `preds`
// borrow `query`; the regexes own PCRE2 state released by
// predicates_destroy. Destroy order is predicates BEFORE query — the
// borrowed views die with the Query.
Highlights :: struct {
	query:         Query, // nil when query_empty
	query_empty:   bool,
	preds:         Query_Predicates,
	source_limit:  int, // the face's source-size bound, for callers that report it
	capture_limit: int, // the face's capture-count bound, for callers that report it
	allocator:     runtime.Allocator,
}

// Highlight_Capture is one query capture: the capture name and its byte
// range in the source it was run against. `name` is a clone owned by the
// run's allocator (request arenas free_all it; other callers use
// highlights_run_destroy).
Highlight_Capture :: struct {
	name:       string,
	start_byte: int,
	end_byte:   int,
}

// Highlights_Run is one run's answer: the flat captures (sorted by
// start_byte, then end_byte, ascending) plus the typed decline. A decline
// other than None may carry the captures gathered before the bound — the
// caller reports the decline rather than silently serving a partial set.
Highlights_Run :: struct {
	captures: []Highlight_Capture,
	decline:  Highlight_Decline,
}

// grammar_highlights_query_empty reports whether the language's registry
// entry ships an empty highlights query — the same query_source_empty rule
// build_highlights applies — for callers that must tell a query-empty
// grammar's observable decline from a compile refusal without building the
// holder (the face's cached nil verdict hides both). false when no grammar
// serves the language.
grammar_highlights_query_empty :: proc(lang_name: string) -> bool {
	idx, ok := registry_lookup(lang_name)
	if !ok {
		return false
	}
	// Materialize the registry locally before indexing (the compiler
	// rejects variable indexing straight into constant data).
	table := GRAMMARS
	return query_source_empty(table[idx].highlights_query)
}

// build_highlights compiles the grammar's shipped highlights query with
// its predicate table; compile_grammar_query carries the build skeleton
// the outliner shares. There is no override ladder and no inference
// fallback — highlights has neither (the outliner's ladder serves the
// outline's definition-capture needs). An empty query source builds
// successfully with query_empty set: the decline is typed and observable
// at run time, never silently empty. A non-empty source that fails to
// compile is an error — nothing sensible falls back to.
build_highlights :: proc(lang_name: string, a := context.allocator) -> (h: ^Highlights, err: string) {
	idx, ok := registry_lookup(lang_name)
	if !ok {
		return nil, strings.concatenate({"unsupported language: ", lang_name}, context.temp_allocator)
	}
	// Materialize the registry locally before indexing (the compiler
	// rejects variable indexing straight into constant data).
	table := GRAMMARS
	lang, available := registry_language(idx)
	if !available {
		return nil, strings.concatenate({"language unavailable on this platform: ", lang_name}, context.temp_allocator)
	}

	h = new(Highlights, a)
	h^ = {
		source_limit  = HIGHLIGHTS_MAX_SOURCE_BYTES,
		capture_limit = HIGHLIGHTS_MAX_CAPTURES,
		allocator     = a,
	}

	h.query, h.query_empty, err = compile_grammar_query(lang, table[idx].highlights_query, "highlights", table[idx].name)
	if err != "" {
		highlights_destroy(h)
		return nil, err
	}
	if h.query_empty {
		return h, ""
	}
	preds, perr := compile_predicates(h.query, a)
	if perr != "" {
		highlights_destroy(h)
		return nil, perr
	}
	h.preds = preds
	return h, ""
}

// highlights_destroy releases the holder. The predicate table borrows the
// query, so it dies first.
highlights_destroy :: proc(h: ^Highlights) {
	if h == nil {
		return
	}
	a := h.allocator
	predicates_destroy(&h.preds, a)
	if h.query != nil {
		query_delete(h.query)
	}
	free(h, a)
}

// highlights_run executes the holder's compiled query over an
// already-parsed tree and flattens the matches into one capture array
// sorted by start position. Captures (and every name clone) are allocated
// in `a` and owned by the caller: request arenas free_all them, other
// allocators use highlights_run_destroy. The tree is only borrowed —
// nodes are read before returning.
highlights_run :: proc(h: ^Highlights, tree: Tree, source: string, a := context.allocator) -> Highlights_Run {
	if h == nil {
		return Highlights_Run{decline = .Nil_Holder}
	}
	if h.query_empty || h.query == nil {
		return Highlights_Run{decline = .Query_Empty}
	}
	if tree == nil {
		return Highlights_Run{decline = .Nil_Tree}
	}
	if len(source) > h.source_limit {
		return Highlights_Run{decline = .Source_Too_Large}
	}

	cursor := query_cursor_new()
	if cursor == nil {
		// Cursor allocation failure is an engine failure, not a decline —
		// it rides the same typed channel (out of memory makes no capture
		// promise) and the face surfaces it as an internal error.
		return Highlights_Run{decline = .Internal}
	}
	defer query_cursor_delete(cursor)
	// The cursor's match limit rides the capture bound: served captures can
	// never pass it. It is a ceiling, not a count — predicate-filtered and
	// zero-capture matches spend the match budget without serving captures
	// — so a limit hit means completeness is unknowable (the served set may
	// still be under the bound), and the run declines rather than answer a
	// possibly-truncated set.
	query_cursor_set_match_limit(cursor, u32(h.capture_limit))
	query_cursor_exec(cursor, h.query, tree_root_node(tree))

	dyn := make([dynamic]Highlight_Capture, 0, 64, a)
	decline := Highlight_Decline.None

	match: Query_Match
	for query_cursor_next_match(cursor, &match) {
		if !predicates_match(&h.preds, &match, source) {
			continue
		}
		room := h.capture_limit - len(dyn)
		if room <= 0 {
			decline = .Capture_Bound
			break
		}
		take := min(int(match.capture_count), room)
		for i in 0..<take {
			cap := match.captures[i]
			append(&dyn, Highlight_Capture{
				name       = capture_name(h.query, cap.index, a),
				start_byte = int(node_start_byte(cap.node)),
				end_byte   = int(node_end_byte(cap.node)),
			})
		}
		if take < int(match.capture_count) {
			decline = .Capture_Bound
			break
		}
	}
	if decline == .None && query_cursor_did_exceed_match_limit(cursor) {
		// The cursor hit its match ceiling: the dropped in-flight matches
		// make completeness unknowable, so the decline says so (under the
		// capture-bound reason) instead of serving tokens that stop
		// mid-file.
		decline = .Capture_Bound
	}

	hl_sort(dyn[:])
	return Highlights_Run{captures = dyn[:], decline = decline}
}

// highlights_run_destroy frees a run built by highlights_run for
// allocators that need explicit deletes (request arenas skip this —
// free_all covers it). Pass the allocator that produced the run (the
// default matches highlights_run's own default).
highlights_run_destroy :: proc(r: Highlights_Run, a := context.allocator) {
	for i in 0..<len(r.captures) {
		if r.captures[i].name != "" {
			delete(r.captures[i].name, a)
		}
	}
	delete(r.captures, a)
}

// ---------------------------------------------------------------------------
// Position sort
// ---------------------------------------------------------------------------

// Highlights_Sort_Box boxes the flat capture array for core:sort's
// Interface (the codebase's sort shape — no closures).
Highlights_Sort_Box :: struct {
	items: []Highlight_Capture,
}

hl_len :: proc(it: sort.Interface) -> int {
	b := cast(^Highlights_Sort_Box)it.collection
	return len(b.items)
}

hl_less :: proc(it: sort.Interface, i, j: int) -> bool {
	b := cast(^Highlights_Sort_Box)it.collection
	x, y := b.items[i], b.items[j]
	if x.start_byte != y.start_byte {
		return x.start_byte < y.start_byte
	}
	return x.end_byte < y.end_byte
}

hl_swap :: proc(it: sort.Interface, i, j: int) {
	b := cast(^Highlights_Sort_Box)it.collection
	b.items[i], b.items[j] = b.items[j], b.items[i]
}

// hl_sort orders the flat captures by (start_byte, end_byte) ascending.
hl_sort :: proc(items: []Highlight_Capture) {
	if len(items) > 1 {
		box := Highlights_Sort_Box{items = items}
		sort.sort({len = hl_len, less = hl_less, swap = hl_swap, collection = &box})
	}
}
