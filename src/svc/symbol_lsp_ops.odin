// The LSP-required symbol ops: reference/implementation/declaration
// retrieval, workspace-wide rename, and the references-checked delete.
// Every op resolves the name path through the file's language server
// (document symbols of the exact server that answers the follow-up
// request, so identifier positions agree by construction), sends one
// request, and maps the reply back onto resolved symbols — the
// retriever-equivalent layer the five symbol tools sit on. Positions are
// LSP-shaped (0-based lines, UTF-16 columns) end to end.
package svc

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:strings"

import "src:editor"
import "src:jsonutil"
import "src:lsp"
import "src:platform"
import "src:safety"
import "src:symbol"
import "src:util"

METHOD_SYMBOL_FIND_REFERENCES :: "svc.symbol/find_references"     // {name_path, relative_path, include_imports?, include_self?, include_file_symbols?, include_kinds?, exclude_kinds?} -> {items}
METHOD_SYMBOL_FIND_IMPLEMENTATIONS :: "svc.symbol/find_implementations" // {name_path, relative_path, include_body?, include_info?, include_kinds?, exclude_kinds?} -> {items}
METHOD_SYMBOL_FIND_DECLARATION :: "svc.symbol/find_declaration"   // {name_path, relative_path} -> {items}
METHOD_SYMBOL_RENAME :: "svc.symbol/rename"                       // {name_path, relative_path, new_name} -> {summary}
METHOD_SYMBOL_DELETE :: "svc.symbol/delete"                       // {name_path_pattern, relative_path, include_comments?} -> {} | {refusal}

// Symbol_Reference is one reference site resolved to its containing
// symbol; sym is a File-kind pseudo-symbol when nothing contains the site
// and file symbols were requested. content_around is the source text one
// line around the site ("" when the file could not be read).
Symbol_Reference :: struct {
	sym:            ^symbol.Symbol,
	line:           int,
	col:            int,
	content_around: string,
}

// Impl_Entry is one resolved implementation symbol; info carries hover
// text when it was requested and the server answered.
Impl_Entry :: struct {
	sym:  ^symbol.Symbol,
	info: string,
}

// Decl_Entry is a lightweight declaration location: the queried symbol's
// name/kind anchored at the declaration the server reported.
Decl_Entry :: struct {
	name:     string,
	kind:     symbol.Symbol_Kind,
	rel_path: string,
	line:     int,
	col:      int,
}

// Symbol_File_View caches one file's resolved server view (forest +
// client + uri) across the resolution loop: several references in one
// file must not trigger one documentSymbol round trip each. forest ==
// nil marks "no server serves this file" so the miss is not retried.
Symbol_File_View :: struct {
	forest: []^symbol.Symbol,
	client: ^lsp.Client,
	uri:    string,
}

// symbol_lsp_resolve resolves a name path through the file's language
// server: strict document symbols (the server starts on demand; the
// refusal with its install hint propagates), then the shared unique
// matcher. The returned symbol belongs to the forest allocated in `a`.
symbol_lsp_resolve :: proc(
	src: ^LSP_Source,
	name_path: string,
	rel: string,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> (match: ^symbol.Symbol, client: ^lsp.Client, uri: string, language_id: string, err: platform.Err) {
	if name_path == "" {
		return nil, nil, "", "", wrapped_err(.Invalid, "name_path is required", a)
	}
	// use_cache=false: the resolve flows need the live client for their
	// follow-up requests — an L1 hit would return nil and force the
	// server anyway, so they keep the resolve-then-request behavior.
	f_roots, f_client, f_uri, f_lang, derr := lsp_document_symbols(src, rel, a, token, false)
	if derr != nil {
		return nil, nil, "", "", derr
	}
	found, ferr, fmsg := symbol.symbol_find_unique(f_roots, name_path)
	if ferr != .None {
		kind := platform.Err_Kind.Invalid
		if ferr == .No_Match {
			kind = .NotFound
		}
		// The resolve failed after the pin: return it before propagating,
		// and drop the language clone this frame owns.
		lsp_source_release(src, f_client, f_uri)
		if f_lang != "" {
			delete(f_lang, a)
		}
		return nil, nil, "", "", wrapped_err(kind, fmsg, a)
	}
	return found, f_client, f_uri, f_lang, nil
}

// symbol_selection_position is where the symbol's name identifier sits —
// selectionRange start when the producer filled it, full-range start
// otherwise.
symbol_selection_position :: proc(s: ^symbol.Symbol) -> (line, col: int, ok: bool) {
	if s == nil {
		return 0, 0, false
	}
	if s.selection_range != nil {
		return int(s.selection_range.start.line), int(s.selection_range.start.character), true
	}
	if s.range != nil {
		return int(s.range.start.line), int(s.range.start.character), true
	}
	return 0, 0, false
}

// ---------------------------------------------------------------------------
// Position matching over a resolved forest
// ---------------------------------------------------------------------------

pos_later :: proc(a, b: symbol.Position) -> bool {
	if a.line != b.line {
		return a.line > b.line
	}
	return a.character > b.character
}

rng_contains :: proc(r: ^symbol.Range, line, col: int) -> bool {
	if r == nil {
		return false
	}
	p := symbol.Position{line = u32(line), character = u32(col)}
	if pos_later(r.start, p) {
		return false
	}
	return !pos_later(p, r.end) && p != r.end
}

pos_at_start :: proc(r: ^symbol.Range, line, col: int) -> bool {
	if r == nil {
		return false
	}
	return r.start.line == u32(line) && r.start.character == u32(col)
}

// symbol_at_position picks the symbol a location-family answer points at:
// the deepest selectionRange containing the position, then the deepest
// full range containing it, then exact starts (a priority ladder; no
// flat-symbol same-line heuristics). Deepest = the candidate whose range
// starts latest — a child's range never starts before its parent's.
symbol_at_position :: proc(roots: []^symbol.Symbol, line, col: int) -> ^symbol.Symbol {
	best_sel:    ^symbol.Symbol = nil
	best_rng:    ^symbol.Symbol = nil
	first_sel:   ^symbol.Symbol = nil
	first_start: ^symbol.Symbol = nil

	stack := make([dynamic][]^symbol.Symbol, 0, 16, context.temp_allocator)
	append(&stack, roots)
	for len(stack) > 0 {
		level := stack[len(stack) - 1]
		pop(&stack)
		for i in 0..<len(level) {
			s := level[i]
			if s.selection_range != nil {
				if rng_contains(s.selection_range, line, col) {
					if best_sel == nil || pos_later(s.selection_range.start, best_sel.selection_range.start) {
						best_sel = s
					}
				} else if first_sel == nil && pos_at_start(s.selection_range, line, col) {
					first_sel = s
				}
			}
			if s.range != nil {
				if rng_contains(s.range, line, col) {
					if best_rng == nil || pos_later(s.range.start, best_rng.range.start) {
						best_rng = s
					}
				} else if first_start == nil && pos_at_start(s.range, line, col) {
					first_start = s
				}
			}
			if len(s.children) > 0 {
				append(&stack, s.children[:])
			}
		}
	}
	if best_sel != nil {
		return best_sel
	}
	if best_rng != nil {
		return best_rng
	}
	if first_sel != nil {
		return first_sel
	}
	return first_start
}

kind_allowed :: proc(k: symbol.Symbol_Kind, include, exclude: []u32) -> bool {
	if len(include) > 0 {
		hit := false
		for x in include {
			if x == u32(k) {
				hit = true
				break
			}
		}
		if !hit {
			return false
		}
	}
	for x in exclude {
		if x == u32(k) {
			return false
		}
	}
	return true
}

// file_pseudo_symbol synthesizes the File-kind fallback entry for a
// reference no symbol contains (allocated in `a`).
file_pseudo_symbol :: proc(rel: string, a: mem.Allocator) -> ^symbol.Symbol {
	base := rel
	if i := strings.last_index(rel, "/"); i >= 0 {
		base = rel[i + 1:]
	}
	if j := strings.last_index(base, "."); j > 0 {
		base = base[:j]
	}
	s := symbol.symbol_new(a)
	s.name = strings.clone(base, a)
	s.kind = .File
	s.location = new(symbol.Location, a)
	s.location^ = {rel_path = strings.clone(rel, a)}
	return s
}

// ref_content_around extracts lines [line-1, line+1] of the file contents
// ("" when out of range). One byte scan, no intermediate allocations.
ref_content_around :: proc(contents: string, line: int, a: mem.Allocator) -> string {
	if line < 0 || len(contents) == 0 {
		return ""
	}
	first := line - 1
	if first < 0 {
		first = 0
	}
	last := line + 1
	start_off := -1
	end_off := -1
	cur_line := 0
	i := 0
	for i <= len(contents) {
		if cur_line == first && start_off < 0 {
			start_off = i
		}
		if i == len(contents) || contents[i] == '\n' {
			if cur_line == last {
				end_off = i
				break
			}
			cur_line += 1
			i += 1
		} else {
			i += 1
		}
	}
	if start_off < 0 {
		return ""
	}
	if end_off < 0 {
		end_off = len(contents)
	}
	return strings.clone(strings.trim_right(strings.trim_right(contents[start_off:end_off], "\n"), "\r"), a)
}

// file_views_release drops the server pins behind a view cache: every
// resolved view holds one port hand-out (the request arena frees the view
// itself, but only the release returns the pin).
file_views_release :: proc(src: ^LSP_Source, cache: map[string]^Symbol_File_View) {
	for _, v in cache {
		if v != nil && v.client != nil {
			lsp_source_release(src, v.client, v.uri)
		}
	}
}

// file_view_resolve fills the per-file view cache: strict document
// symbols, with a nil forest marking an unserved file (the miss is cached
// too — one refusal per file, not one per reference).
file_view_resolve :: proc(
	src: ^LSP_Source,
	cache: ^map[string]^Symbol_File_View,
	rel: string,
	a: mem.Allocator,
	token: ^platform.Cancel_Token,
) {
	if rel == "" {
		return
	}
	if _, ok := cache^[rel]; ok {
		return
	}
	// use_cache=false, as in symbol_lsp_resolve: these flows hold the
	// client for follow-up requests.
	roots, client, uri, file_lang, derr := lsp_document_symbols(src, rel, a, token, false)
	if derr != nil {
		miss := new(Symbol_File_View, a)
		miss^ = {forest = nil, client = nil, uri = ""}
		cache^[rel] = miss
		return
	}
	if file_lang != "" {
		delete(file_lang, a)
	}
	view := new(Symbol_File_View, a)
	view^ = {forest = roots, client = client, uri = uri}
	cache^[rel] = view
}

// file_contents_read reads a project file for the reference-context
// rendering: the editor buffer when one is live, the disk otherwise.
file_contents_read :: proc(src: ^LSP_Source, ed: ^editor.Editor, rel: string, a: mem.Allocator) -> string {
	if ed != nil {
		read, rerr, _ := editor.editor_read_file(ed, rel)
		if rerr == .None {
			cloned := strings.clone(read, a)
			delete(read, ed.allocator)
			return cloned
		}
	}
	ta := context.temp_allocator
	abs, perr := safety.pathguard_validate_contained(src.project_root, rel, ta)
	if perr.reason != "" {
		return ""
	}
	info, serr := os.stat(abs, ta)
	if serr != nil || info.type == .Directory {
		if serr == nil {
			os.file_info_delete(info, ta)
		}
		return ""
	}
	os.file_info_delete(info, ta)
	contents, rerr := read_source_file(abs, a)
	if rerr != "" {
		return ""
	}
	return contents
}

// ---------------------------------------------------------------------------
// find_references
// ---------------------------------------------------------------------------

// unsupported_lookup_err is the capability gate's decline: a position
// lookup the server never declared (declarationProvider and kin) must
// not go over the wire — the server would answer its own raw
// method-not-found internal error instead. `hint` names a sibling tool
// that does work, when there is one.
unsupported_lookup_err :: proc(lang, lookup, capability, hint: string, a: mem.Allocator) -> platform.Err {
	who := "the language server for this file"
	if lang != "" {
		who = strings.concatenate({"the ", lang, " language server"}, a)
	}
	msg := strings.concatenate(
		{who, " does not support ", lookup, " lookups (no ", capability, " capability)", hint},
		a,
	)
	return wrapped_err(.NotFound, msg, a)
}

// symbol_lsp_find_references answers the symbols that reference the named
// symbol. Each reference site is resolved to its containing symbol; the
// filters decide what counts: the symbol's own declaration sites only
// with include_self, same-name import lines only with include_imports,
// sites no symbol contains only with include_file_symbols (as File-kind
// pseudo entries), and the kind filters gate every entry.
symbol_lsp_find_references :: proc(
	src: ^LSP_Source,
	ed: ^editor.Editor,
	name_path: string,
	rel: string,
	include_imports: bool,
	include_self: bool,
	include_file_symbols: bool,
	include_kinds: []u32,
	exclude_kinds: []u32,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> (refs: []Symbol_Reference, err: platform.Err) {
	match, client, uri, resolve_lang, rerr := symbol_lsp_resolve(src, name_path, rel, a, token)
	// The language clone is `a`-owned and lives until the capability gate
	// has named the server; the deferred delete covers every return path.
	defer if resolve_lang != "" {
		delete(resolve_lang, a)
	}
	if rerr != nil {
		return nil, rerr
	}
	defer lsp_source_release(src, client, uri)
	line, col, pok := symbol_selection_position(match)
	if !pok {
		return nil, wrapped_err(
			.Invalid,
			strings.concatenate({"symbol \"", name_path, "\" has no identifier position"}, a),
			a,
		)
	}
	if !lsp.client_caps(client).references {
		return nil, unsupported_lookup_err(resolve_lang, "reference", "referencesProvider", "", a)
	}

	locs, lerr := lsp.request_references(client, uri, line, col, false, a, token)
	if lerr != nil {
		return nil, lerr
	}

	// The target's own forest is already resolved; seed the cache so the
	// self/import checks never re-request it.
	target_rel := rel
	if match.location != nil && match.location.rel_path != "" {
		target_rel = match.location.rel_path
	}
	cache := make(map[string]^Symbol_File_View, 4, a)
	defer delete(cache)
	defer file_views_release(src, cache)
	file_view_resolve(src, &cache, target_rel, a, token)

	contents_cache := make(map[string]string, 4, a)
	defer delete(contents_cache)

	out := make([dynamic]Symbol_Reference, 0, len(locs), a)
	for loc in locs {
		ref_line := int(loc.range.start.line)
		ref_col := int(loc.range.start.character)
		ref_rel := loc.rel_path

		container: ^symbol.Symbol = nil
		if ref_rel != "" {
			file_view_resolve(src, &cache, ref_rel, a, token)
			if v, ok := cache[ref_rel]; ok && v != nil && v.forest != nil {
				container = symbol_at_position(v.forest, ref_line, ref_col)
			}
		}

		if container != nil &&
			container.selection_range != nil &&
			// Same-file detection carries the filesystem's case
			// sensitivity (the server's relativized spelling may differ
			// in case from the caller's argument where the filesystem
			// folds case).
			platform.path_equal(ref_rel, target_rel) &&
			pos_at_start(container.selection_range, ref_line, ref_col) {
			// The symbol's own declaration site.
			if !include_self {
				continue
			}
		} else if !include_imports && container != nil &&
			container.name == match.name && container.kind == match.kind &&
			container.selection_range != nil &&
			// Only a reference AT a same-name symbol's identifier start is
			// an import/alias declaration. A use site inside its body is a
			// real reference — a sibling overload or a same-named function
			// in another file — and must survive the filter, so the same
			// position predicate the self-branch uses decides. Matching
			// against the resolved target (not a reply-order-dependent
			// first sighting) keeps the answer independent of ordering.
			pos_at_start(container.selection_range, ref_line, ref_col) {
			// A same-name import/alias declaration of the target.
			continue
		}

		file_symbol := false
		if container == nil {
			if !include_file_symbols || ref_rel == "" {
				continue
			}
			container = file_pseudo_symbol(ref_rel, a)
			file_symbol = true
		}
		if !file_symbol && !kind_allowed(container.kind, include_kinds, exclude_kinds) {
			continue
		}
		if file_symbol && !kind_allowed(.File, include_kinds, exclude_kinds) {
			continue
		}

		around := ""
		if ref_rel != "" {
			if cached, ok := contents_cache[ref_rel]; ok {
				around = ref_content_around(cached, ref_line, a)
			} else {
				contents := file_contents_read(src, ed, ref_rel, a)
				contents_cache[ref_rel] = contents
				around = ref_content_around(contents, ref_line, a)
			}
		}
		append(&out, Symbol_Reference{sym = container, line = ref_line, col = ref_col, content_around = around})
	}
	if len(out) == 0 {
		delete(out)
		return nil, nil
	}
	return out[:], nil
}

// ---------------------------------------------------------------------------
// find_implementations
// ---------------------------------------------------------------------------

// symbol_lsp_find_implementations answers the symbols implementing the
// named symbol: one implementation request, then each reported location
// resolved to the symbol at that position in the target file's own
// document symbols. include_info additionally attaches hover text per
// result (a server without hover contributes no info, never an error).
symbol_lsp_find_implementations :: proc(
	src: ^LSP_Source,
	name_path: string,
	rel: string,
	include_info: bool,
	include_kinds: []u32,
	exclude_kinds: []u32,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> (entries: []Impl_Entry, err: platform.Err) {
	match, client, uri, resolve_lang, rerr := symbol_lsp_resolve(src, name_path, rel, a, token)
	// The language clone is `a`-owned and lives until the capability gate
	// has named the server; the deferred delete covers every return path.
	defer if resolve_lang != "" {
		delete(resolve_lang, a)
	}
	if rerr != nil {
		return nil, rerr
	}
	defer lsp_source_release(src, client, uri)
	line, col, pok := symbol_selection_position(match)
	if !pok {
		return nil, nil
	}
	if !lsp.client_caps(client).implementation {
		return nil, unsupported_lookup_err(resolve_lang, "implementation", "implementationProvider", "", a)
	}

	locs, lerr := lsp.request_implementation(client, uri, line, col, a, token)
	if lerr != nil {
		return nil, lerr
	}
	if len(locs) == 0 {
		return nil, nil
	}

	cache := make(map[string]^Symbol_File_View, 4, a)
	defer delete(cache)
	defer file_views_release(src, cache)

	// The batch hover pass runs under the resolved symbol_info_budget
	// (seconds; 0 leaves it unbounded — tests and bare sources). One
	// monotonic deadline covers the batch: each hover also carries it as a
	// derived token deadline, and once spent the remaining entries return
	// without info rather than as errors — the implementation list itself
	// is already known.
	hover_deadline := i64(0)
	hover_token := token
	hover_timer: ^platform.Timer = nil
	if src.symbol_info_budget_s > 0 {
		hover_deadline = platform.clock_now(src.clock) + i64(src.symbol_info_budget_s * 1000.0)
		if token != nil {
			hover_token = platform.token_derive(token, hover_deadline, a)
			// derive only records the deadline; the Clock timer fires it.
			hover_timer = platform.clock_timer_add(src.clock, hover_deadline, hover_deadline_fire, hover_token)
		}
	}
	// Proc-scope defers (a defer inside the deriving if would fire at block
	// exit, long before the loop). LIFO: the timer cancels first — when the
	// cancel finds nothing, a fire pass owns the timer and will call
	// token_fire after the clock mutex was released, so the wait lets that
	// fire complete before token_destroy frees the token — then the child
	// dies before its parent (the caller's token outlives this call).
	defer if hover_token != token {
		platform.token_destroy(hover_token, a)
	}
	defer if hover_timer != nil {
		if !platform.clock_timer_cancel(src.clock, hover_timer) {
			platform.token_wait(hover_token)
		}
	}

	out := make([dynamic]Impl_Entry, 0, len(locs), a)
	for loc in locs {
		if loc.rel_path == "" {
			continue
		}
		file_view_resolve(src, &cache, loc.rel_path, a, token)
		view, ok := cache[loc.rel_path]
		if !ok || view == nil || view.forest == nil {
			continue
		}
		impl := symbol_at_position(view.forest, int(loc.range.start.line), int(loc.range.start.character))
		if impl == nil {
			continue
		}
		if !kind_allowed(impl.kind, include_kinds, exclude_kinds) {
			continue
		}
		info := ""
		if include_info && impl.selection_range != nil {
			if hover_deadline > 0 && platform.clock_now(src.clock) >= hover_deadline {
				// Budget spent — the remaining entries answer without info.
				append(&out, Impl_Entry{sym = impl, info = info})
				continue
			}
			iline := int(impl.selection_range.start.line)
			icol := int(impl.selection_range.start.character)
			hover, found, herr := lsp.request_hover(view.client, view.uri, iline, icol, a, hover_token)
			if herr == nil && found {
				info = hover.text
			}
		}
		append(&out, Impl_Entry{sym = impl, info = info})
	}
	if len(out) == 0 {
		delete(out)
		return nil, nil
	}
	return out[:], nil
}

// hover_deadline_fire is the Clock timer body for the batch hover deadline
// (the same shape as the tool dispatch's deadline timer).
hover_deadline_fire :: proc(data: rawptr) {
	platform.token_fire(cast(^platform.Cancel_Token)data, .Deadline)
}

// ---------------------------------------------------------------------------
// find_declaration
// ---------------------------------------------------------------------------

// symbol_lsp_find_declaration answers where the named symbol is declared:
// the queried symbol's name and kind anchored at each declaration
// location the server reports.
symbol_lsp_find_declaration :: proc(
	src: ^LSP_Source,
	name_path: string,
	rel: string,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> (entries: []Decl_Entry, err: platform.Err) {
	match, client, uri, resolve_lang, rerr := symbol_lsp_resolve(src, name_path, rel, a, token)
	// The language clone is `a`-owned and lives until the capability gate
	// has named the server; the deferred delete covers every return path.
	defer if resolve_lang != "" {
		delete(resolve_lang, a)
	}
	if rerr != nil {
		return nil, rerr
	}
	defer lsp_source_release(src, client, uri)
	line, col, pok := symbol_selection_position(match)
	if !pok {
		return nil, nil
	}
	if !lsp.client_caps(client).declaration {
		return nil, unsupported_lookup_err(
			resolve_lang, "declaration", "declarationProvider",
			"; symbol_find resolves the symbol's definition",
			a,
		)
	}

	locs, lerr := lsp.request_declaration(client, uri, line, col, a, token)
	if lerr != nil {
		return nil, lerr
	}
	if len(locs) == 0 {
		return nil, nil
	}

	out := make([dynamic]Decl_Entry, 0, len(locs), a)
	for loc in locs {
		if loc.rel_path == "" {
			continue
		}
		append(&out, Decl_Entry{
			name     = match.name,
			kind     = match.kind,
			rel_path = loc.rel_path,
			line     = int(loc.range.start.line),
			col      = int(loc.range.start.character),
		})
	}
	if len(out) == 0 {
		delete(out)
		return nil, nil
	}
	return out[:], nil
}

// ---------------------------------------------------------------------------
// rename
// ---------------------------------------------------------------------------

Rename_Apply_Job :: struct {
	edits: []lsp.Rename_Edit, // sorted descending by position by the caller
}

rename_apply_step :: proc(ef: ^editor.Edited_File, user: rawptr) -> (err: editor.Editor_Err, msg: string) {
	job := cast(^Rename_Apply_Job)user
	for e in job.edits {
		// Edits are expressed against the pre-edit document; applying
		// from the last position back keeps every remaining position
		// valid as the tail shifts.
		if derr, dmsg := editor.edited_delete_between(
			ef, int(e.range.start.line), int(e.range.start.character),
			int(e.range.end.line), int(e.range.end.character),
		); derr != .None {
			return derr, dmsg
		}
		if e.new_text != "" {
			if ierr, imsg := editor.edited_insert_text(
				ef, int(e.range.start.line), int(e.range.start.character), e.new_text,
			); ierr != .None {
				return ierr, imsg
			}
		}
	}
	return .None, ""
}

// rename_edits_descending sorts one file's edits by start position,
// latest first (insertion sort — rename edit lists are small).
rename_edits_descending :: proc(edits: []lsp.Rename_Edit) {
	for i := 1; i < len(edits); i += 1 {
		e := edits[i]
		j := i - 1
		for j >= 0 &&
			(edits[j].range.start.line < e.range.start.line ||
				(edits[j].range.start.line == e.range.start.line &&
					edits[j].range.start.character < e.range.start.character)) {
			edits[j + 1] = edits[j]
			j -= 1
		}
		edits[j + 1] = e
	}
}

// symbol_lsp_rename renames the symbol across the workspace: one rename
// request, then the returned edits applied per file (each file is one
// atomic editor transaction; a failed file aborts the remaining ones —
// the applied prefix stays). Edits whose file
// URI resolves outside the project are skipped.
symbol_lsp_rename :: proc(
	src: ^LSP_Source,
	ed: ^editor.Editor,
	name_path: string,
	rel: string,
	new_name: string,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> (summary: string, err: platform.Err) {
	if ed == nil {
		return "", wrapped_err(.Internal, "editor unavailable", a)
	}
	if new_name == "" {
		return "", wrapped_err(.Invalid, "new_name is required", a)
	}
	if derr, denied := state_target_denied(ed, rel, a); denied {
		return "", derr
	}
	match, client, uri, resolve_lang, rerr := symbol_lsp_resolve(src, name_path, rel, a, token)
	// The language clone is `a`-owned; these flows don't carry it onward.
	if resolve_lang != "" {
		delete(resolve_lang, a)
	}
	if rerr != nil {
		return "", rerr
	}
	defer lsp_source_release(src, client, uri)
	line, col, pok := symbol_selection_position(match)
	if !pok {
		return "", wrapped_err(
			.Invalid,
			strings.concatenate({"symbol \"", name_path, "\" does not have a valid position in file for renaming"}, a),
			a,
		)
	}

	edits, rrerr := lsp.request_rename(client, uri, line, col, new_name, a, token)
	if rrerr != nil {
		return "", rrerr
	}
	if len(edits) == 0 {
		return "", wrapped_err(
			.Invalid,
			strings.concatenate(
				{"language server returned no rename edits for symbol \"", name_path, "\"; the symbol might not support renaming"},
				a,
			),
			a,
		)
	}

	// Group per file, first-seen order.
	files := make([dynamic]string, 0, 4, a)
	defer delete(files)
	by_file := make(map[string][dynamic]lsp.Rename_Edit, 4, a)
	defer {
		for _, v in by_file {
			delete(v)
		}
		delete(by_file)
	}
	applied := 0
	for e in edits {
		if e.rel_path == "" {
			continue
		}
		if _, ok := by_file[e.rel_path]; !ok {
			by_file[e.rel_path] = make([dynamic]lsp.Rename_Edit, 0, 4, a)
			append(&files, e.rel_path)
		}
		append(&by_file[e.rel_path], e)
	}
	if len(files) == 0 {
		return "", wrapped_err(
			.Invalid,
			strings.concatenate(
				{"renaming symbol \"", name_path, "\" to \"", new_name, "\" resulted in no changes being applied; renaming may not be supported"},
				a,
			),
			a,
		)
	}

	for f in files {
		// Per-file cancellation checkpoint: the apply stage writes and
		// re-truths file by file, so a fired token stops between files
		// with the partial count in the message.
		if token != nil {
			if _, fired := platform.token_check(token); fired {
				return "", wrapped_err(
					.Cancelled,
					strings.concatenate({"rename cancelled during apply after ", util.int_to_dec(applied, a), " edits"}, a),
					a,
				)
			}
		}
		// A view over the map entry's own backing: sorting through it
		// orders the stored list itself.
		file_edits := by_file[f][:]
		rename_edits_descending(file_edits)
		job := Rename_Apply_Job{edits = file_edits}
		aerr, amsg := editor.editor_edit_ctx(ed, f, {apply = rename_apply_step, user = &job})
		if aerr != .None {
			if applied == 0 {
				return "", wrapped_err(
					.Internal,
					strings.concatenate({"rename apply failed in ", f, ": ", amsg}, a),
					a,
				)
			}
			return "", wrapped_err(
				.Internal,
				strings.concatenate({"rename apply failed in ", f, " after ", util.int_to_dec(applied, a), " edits: ", amsg}, a),
				a,
			)
		}
		applied += len(file_edits)
	}
	if applied == 0 {
		return "", wrapped_err(
			.Invalid,
			strings.concatenate(
				{"renaming symbol \"", name_path, "\" to \"", new_name, "\" resulted in no changes being applied; renaming may not be supported"},
				a,
			),
			a,
		)
	}
	summary = strings.concatenate(
		{"Successfully renamed \"", name_path, "\" to \"", new_name, "\" (", util.int_to_dec(applied, a), " edits applied)"},
		a,
	)
	return summary, nil
}

// ---------------------------------------------------------------------------
// delete (references-checked)
// ---------------------------------------------------------------------------

// symbol_lsp_delete removes the named symbol when nothing references it.
// Any reference site flips the answer to a refusal naming the files and
// lines; an unreferenced symbol is deleted through the editor (optionally
// with its preceding docstring/comment block).
symbol_lsp_delete :: proc(
	src: ^LSP_Source,
	ed: ^editor.Editor,
	name_path: string,
	rel: string,
	include_comments: bool,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> (refusal: string, err: platform.Err) {
	if ed == nil {
		return "", wrapped_err(.Internal, "editor unavailable", a)
	}
	if derr, denied := state_target_denied(ed, rel, a); denied {
		return "", derr
	}
	match, client, uri, language_id, rerr := symbol_lsp_resolve(src, name_path, rel, a, token)
	// The language clone is `a`-owned; the editor job consumes it
	// synchronously, and the deferred delete covers every return path.
	defer if language_id != "" {
		delete(language_id, a)
	}
	if rerr != nil {
		return "", rerr
	}
	defer lsp_source_release(src, client, uri)
	line, col, pok := symbol_selection_position(match)
	if !pok {
		return "", wrapped_err(
			.Invalid,
			strings.concatenate({"symbol \"", name_path, "\" has no identifier position"}, a),
			a,
		)
	}

	locs, lerr := lsp.request_references(client, uri, line, col, false, a, token)
	if lerr != nil {
		return "", lerr
	}
	if len(locs) > 0 {
		// {file: [lines]} in first-seen order.
		files := make([dynamic]string, 0, 4, a)
		defer delete(files)
		lines_by := make(map[string][dynamic]int, 4, a)
		defer {
			for _, v in lines_by {
				delete(v)
			}
			delete(lines_by)
		}
		for loc in locs {
			if loc.rel_path == "" {
				continue
			}
			if _, ok := lines_by[loc.rel_path]; !ok {
				lines_by[loc.rel_path] = make([dynamic]int, 0, 4, a)
				append(&files, loc.rel_path)
			}
			append(&lines_by[loc.rel_path], int(loc.range.start.line))
		}
		refusal = delete_refusal(name_path, files[:], &lines_by, a)
		return refusal, nil
	}

	if derr, dmsg := editor.editor_symbol_delete(ed, rel, match, include_comments, language_id); derr != .None {
		return "", wrapped_err(.Internal, dmsg, a)
	}
	return "", nil
}

// delete_refusal renders the "cannot delete" answer: the symbol's name
// path plus the {file: [reference lines]} JSON in first-seen order.
delete_refusal :: proc(name_path: string, files: []string, lines_by: ^map[string][dynamic]int, a: mem.Allocator) -> string {
	obj := jsonutil.json_object(len(files), a)
	for f in files {
		ls := lines_by^[f]
		items := make([]json.Value, len(ls), a)
		for i in 0..<len(ls) {
			items[i] = jsonutil.json_int(i64(ls[i]))
		}
		jsonutil.obj_set(&obj, f, jsonutil.json_array(items, a))
	}
	doc := json.Value(json.Object(obj))
	rendered := jsonutil.marshal_value(doc, a)
	return strings.concatenate(
		{"Cannot delete, the symbol \"", name_path, "\" is referenced in: ", rendered},
		a,
	)
}
