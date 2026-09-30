// The symbol-edit svc face: method names plus the daemon-side operations
// behind them. Every op refuses aubade's own state directory by location
// (state_target_denied — the folder template can place it anywhere) and
// resolves the name path against a fresh outline
// and hands positions to the editor's symbol-edit procs; every relative
// path goes through normalize_rel first, so a caller's "./a.go" and "a.go"
// are one file for the editor's buffer keys and the move's same-file
// decision alike. Both sources resolve the editor's view of the file — an
// open buffer when one exists, the disk otherwise — the same bytes the
// editor's own transactions read and apply, so resolve and apply can
// never disagree about the content. The fresh parse also rewrites the
// file's symbol-index rows, so finds stay current. Files the tree-sitter
// pass cannot outline (no grammar, or the tags query declines) resolve
// through the LSP producer's document symbols instead — the same source
// order the read side uses, so an edit needs a language server only when
// tree-sitter cannot name the symbol at all. move stays grammar-only:
// its lang checks, comment extraction, and brace validation are
// tree-sitter-shaped, and it resolves the target file's outline once —
// the anchor and the duplicate-name guard both read that one parse, and
// a move never writes a second declaration of a name the target has.
package svc

import "core:mem"
import "core:strings"
import "src:editor"
import "src:platform"
import "src:symbol"
import "src:ts"

METHOD_SYMBOL_REPLACE_BODY :: "svc.symbol/replace_body" // {name_path, relative_path, body} -> {}
METHOD_SYMBOL_INSERT_BEFORE :: "svc.symbol/insert_before" // {name_path, relative_path, body} -> {}
METHOD_SYMBOL_INSERT_AFTER :: "svc.symbol/insert_after" // {name_path, relative_path, body} -> {}
METHOD_SYMBOL_MOVE :: "svc.symbol/move" // {name_path, source_relative_path, target_relative_path, target_position, mode?} -> {summary}
METHOD_SYMBOL_INSERT_DOCSTRING :: "svc.symbol/insert_docstring" // {name_path, relative_path, comment} -> {}
METHOD_SYMBOL_DELETE_DOCSTRING :: "svc.symbol/delete_docstring" // {name_path, relative_path} -> {}
METHOD_SYMBOL_REPLACE_DOCSTRING :: "svc.symbol/replace_docstring" // {name_path, relative_path, comment} -> {}

// lang_for_file resolves the tree-sitter language name for a project
// file by the detection ladder — exact Linguist filename first (Makefile,
// Dockerfile, .bashrc), then the multi-suffix extension scan ("" when no
// grammar serves it).
lang_for_file :: proc(src: ^TS_Source, rel: string) -> string {
	base := rel_base(rel)
	idx, ok := ts.registry_detect(base)
	if !ok {
		return ""
	}
	table := ts.GRAMMARS
	return table[idx].name
}

// resolve_symbol resolves `pattern` to a unique symbol in `rel`. The
// forest is allocated in `a` — the request arena in every handler — and
// is never individually freed: arena-interior pointers must not be
// delete()d (the arena dies wholesale at request end). `source` is the
// parse basis: the exact bytes the returned ranges were resolved against
// (the sourced TS arm), or "" when the resolution came from the LSP
// fallback — those ranges belong to the server's mirror, and the caller
// reads an advisory basis from the editor instead (edit_basis). Source
// order mirrors the read side: the tree-sitter pass first, and when it
// yields no outline at all (no grammar, tags query declines) the LSP
// producer's document symbols for the same file. `lsp_lang` is non-empty
// only when the resolution came from that fallback — the server's
// language id cloned into `a`, for callers that need comment syntax;
// every other caller deletes it.
resolve_symbol :: proc(
	src: ^TS_Source,
	lsp_src: ^LSP_Source,
	pattern: string,
	rel: string,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> (match: ^symbol.Symbol, roots: []^symbol.Symbol, source: string, lsp_lang: string, err: platform.Err) {
	forest, basis, ferr := ts_source_file_symbols_sourced(src, rel, a)
	if ferr != nil {
		return nil, nil, "", "", ferr
	}
	if len(forest) == 0 && lsp_src != nil {
		// The edit ops need only the symbol's range — no follow-up
		// request ties them to a live client — so use_cache=true (an L1
		// hit serves without starting anything). A port refusal
		// propagates: for a file neither source serves it is the honest
		// answer, install hint included.
		l_roots, client, uri, lang_id, lerr := lsp_document_symbols(lsp_src, rel, a, token, true)
		if lerr != nil {
			return nil, nil, "", "", lerr
		}
		lsp_source_release(lsp_src, client, uri)
		if uri != "" {
			delete(uri, a)
		}
		forest = l_roots
		lsp_lang = lang_id
		// The mirror's ranges have no byte basis here; edit_basis supplies
		// the advisory editor view. The TS basis dies with the arena.
		basis = ""
	}
	found, find_err, find_msg := symbol.symbol_find_unique(forest, pattern)
	if find_err != .None {
		if lsp_lang != "" {
			delete(lsp_lang, a)
		}
		kind := platform.Err_Kind.Invalid
		if find_err == .No_Match {
			kind = .NotFound
		}
		return nil, nil, "", "", wrapped_err(kind, find_msg, a)
	}
	return found, forest, basis, lsp_lang, nil
}

// edit_basis supplies the editor guard's basis for one resolved symbol:
// the TS arm's exact parse bytes when it produced them, otherwise — the
// LSP fallback arm — the editor's view read now. The fallback basis is
// advisory: the LSP ranges come from the server's mirror, whose strict
// correspondence with the buffer is outside the best-effort sync design;
// the guard still refuses any buffer change between this read and the
// splice. `owned_fallback` marks the one case where the caller frees the
// basis (the editor-allocator clone) after the edit consumed it — the
// TS basis rides the request arena and dies wholesale.
edit_basis :: proc(ed: ^editor.Editor, rel: string, source: string, a := context.allocator) -> (basis: string, owned_fallback: bool, err: platform.Err) {
	if source != "" {
		return source, false, nil
	}
	read, rerr, _ := editor.editor_read_file(ed, rel)
	if rerr != .None {
		return "", false, wrapped_err(.Internal, "edit basis: could not read the file to edit", a)
	}
	return read, true, nil
}

// Symbol_String_Edit is the editor face the range-only string edits
// share: apply one string payload to the resolved symbol against its
// parse basis.
Symbol_String_Edit :: proc(e: ^editor.Editor, rel: string, s: ^symbol.Symbol, source: string, value: string) -> (editor.Editor_Err, string)

// symbol_docstring_lang picks the comment-syntax language for one
// docstring op — the grammar's, or the fallback's for a grammar-less
// file — freeing the fallback clone when the grammar already decided.
// owns_fallback marks the one case where the caller frees instead: after
// the editor job consumed the clone synchronously.
symbol_docstring_lang :: proc(src: ^TS_Source, rel_n: string, lsp_lang: string, a: mem.Allocator) -> (lang: string, owns_fallback: bool) {
	lang = lang_for_file(src, rel_n)
	if lang != "" {
		if lsp_lang != "" {
			delete(lsp_lang, a)
		}
		return lang, false
	}
	return lsp_lang, true
}

// symbol_edit_string_op drives the range-only string edits (body inserts):
// resolve the target once, drop the fallback's language clone (a body
// insert needs only the symbol's range, never comment syntax), then
// apply `edit` under `op_name`'s error prefix.
symbol_edit_string_op :: proc(
	src: ^TS_Source,
	ed: ^editor.Editor,
	name_path: string,
	rel: string,
	value: string,
	op_name: string,
	edit: Symbol_String_Edit,
	lsp_src: ^LSP_Source = nil,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> platform.Err {
	rel_n := normalize_rel(rel, context.temp_allocator)
	if derr, denied := state_target_denied(ed, rel_n, a); denied {
		return derr
	}
	match, _, source, lsp_lang, rerr := resolve_symbol(src, lsp_src, name_path, rel_n, a, token)
	if rerr != nil {
		return rerr
	}
	if lsp_lang != "" {
		delete(lsp_lang, a) // range-only op: the fallback's language clone is unused
	}
	basis, owned, berr := edit_basis(ed, rel_n, source, a)
	if berr != nil {
		return berr
	}
	defer if owned {
		delete(basis, ed.allocator)
	}
	eerr, emsg := edit(ed, rel_n, match, basis, value)
	if eerr != .None {
		return editor_err_map(op_name, eerr, emsg, a)
	}
	return nil
}

symbol_edit_replace_body :: proc(
	src: ^TS_Source,
	ed: ^editor.Editor,
	name_path: string,
	rel: string,
	body: string,
	lsp_src: ^LSP_Source = nil,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> platform.Err {
	return symbol_edit_string_op(src, ed, name_path, rel, body, "replace_body", editor.editor_symbol_replace_body, lsp_src, a, token)
}

symbol_edit_insert_before :: proc(
	src: ^TS_Source,
	ed: ^editor.Editor,
	name_path: string,
	rel: string,
	body: string,
	lsp_src: ^LSP_Source = nil,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> platform.Err {
	return symbol_edit_string_op(src, ed, name_path, rel, body, "insert_before", editor.editor_symbol_insert_before, lsp_src, a, token)
}

symbol_edit_insert_after :: proc(
	src: ^TS_Source,
	ed: ^editor.Editor,
	name_path: string,
	rel: string,
	body: string,
	lsp_src: ^LSP_Source = nil,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> platform.Err {
	return symbol_edit_string_op(src, ed, name_path, rel, body, "insert_after", editor.editor_symbol_insert_after, lsp_src, a, token)
}

symbol_edit_insert_docstring :: proc(
	src: ^TS_Source,
	ed: ^editor.Editor,
	name_path: string,
	rel: string,
	comment: string,
	lsp_src: ^LSP_Source = nil,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> platform.Err {
	rel_n := normalize_rel(rel, context.temp_allocator)
	if derr, denied := state_target_denied(ed, rel_n, a); denied {
		return derr
	}
	match, _, source, lsp_lang, rerr := resolve_symbol(src, lsp_src, name_path, rel_n, a, token)
	if rerr != nil {
		return rerr
	}
	lang, owns := symbol_docstring_lang(src, rel_n, lsp_lang, a)
	basis, owns_basis, berr := edit_basis(ed, rel_n, source, a)
	if berr != nil {
		if owns && lsp_lang != "" {
			delete(lsp_lang, a)
		}
		return berr
	}
	// The fallback basis is ed-allocator-owned; the editor job consumes it
	// synchronously, and the deferred delete covers every return path.
	defer if owns_basis {
		delete(basis, ed.allocator)
	}
	eerr, emsg := editor.editor_symbol_insert_docstring(ed, rel_n, match, basis, lang, comment)
	if owns && lsp_lang != "" {
		delete(lsp_lang, a) // the editor job consumed the language synchronously
	}
	if eerr != .None {
		return editor_err_map("insert_docstring", eerr, emsg, a)
	}
	return nil
}

symbol_edit_delete_docstring :: proc(
	src: ^TS_Source,
	ed: ^editor.Editor,
	name_path: string,
	rel: string,
	lsp_src: ^LSP_Source = nil,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> platform.Err {
	rel_n := normalize_rel(rel, context.temp_allocator)
	if derr, denied := state_target_denied(ed, rel_n, a); denied {
		return derr
	}
	match, _, source, lsp_lang, rerr := resolve_symbol(src, lsp_src, name_path, rel_n, a, token)
	if rerr != nil {
		return rerr
	}
	lang, owns := symbol_docstring_lang(src, rel_n, lsp_lang, a)
	basis, owns_basis, berr := edit_basis(ed, rel_n, source, a)
	if berr != nil {
		if owns && lsp_lang != "" {
			delete(lsp_lang, a)
		}
		return berr
	}
	defer if owns_basis {
		delete(basis, ed.allocator) // the editor job consumed the basis synchronously
	}
	eerr, emsg := editor.editor_symbol_delete_docstring(ed, rel_n, match, basis, lang)
	if owns && lsp_lang != "" {
		delete(lsp_lang, a) // the editor job consumed the language synchronously
	}
	if eerr != .None {
		return editor_err_map("delete_docstring", eerr, emsg, a)
	}
	return nil
}

symbol_edit_replace_docstring :: proc(
	src: ^TS_Source,
	ed: ^editor.Editor,
	name_path: string,
	rel: string,
	comment: string,
	lsp_src: ^LSP_Source = nil,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> platform.Err {
	rel_n := normalize_rel(rel, context.temp_allocator)
	if derr, denied := state_target_denied(ed, rel_n, a); denied {
		return derr
	}
	match, _, source, lsp_lang, rerr := resolve_symbol(src, lsp_src, name_path, rel_n, a, token)
	if rerr != nil {
		return rerr
	}
	lang, owns := symbol_docstring_lang(src, rel_n, lsp_lang, a)
	basis, owns_basis, berr := edit_basis(ed, rel_n, source, a)
	if berr != nil {
		if owns && lsp_lang != "" {
			delete(lsp_lang, a)
		}
		return berr
	}
	defer if owns_basis {
		delete(basis, ed.allocator) // the editor job consumed the basis synchronously
	}
	eerr, emsg := editor.editor_symbol_replace_docstring(ed, rel_n, match, basis, lang, comment)
	if owns && lsp_lang != "" {
		delete(lsp_lang, a) // the editor job consumed the language synchronously
	}
	if eerr != .None {
		return editor_err_map("replace_docstring", eerr, emsg, a)
	}
	return nil
}

// symbol_edit_move moves/copies a leaf symbol between files (or within
// one). target_position is "end" or a name path resolved in the target
// file. Returns the summary (owned by `a`).
symbol_edit_move :: proc(
	src: ^TS_Source,
	ed: ^editor.Editor,
	name_path: string,
	source_rel: string,
	target_rel: string,
	target_position: string,
	mode: editor.Move_Mode,
	a := context.allocator,
	token: ^platform.Cancel_Token = nil,
) -> (summary: string, err: platform.Err) {
	// Caller spellings of one file must collapse onto the canonical key
	// before the same-file decision and the editor's buffer lookups:
	// "./a.go" and "a.go" are one file, not a source/target pair.
	src_rel := normalize_rel(source_rel, context.temp_allocator)
	dst_rel := normalize_rel(target_rel, context.temp_allocator)
	// Both endpoints carry the state refusal, like file_move: moving a
	// symbol out of the managed tree corrupts it as surely as moving one
	// in.
	if derr, denied := state_target_denied(ed, src_rel, a); denied {
		return "", derr
	}
	if derr, denied := state_target_denied(ed, dst_rel, a); denied {
		return "", derr
	}
	source_lang := lang_for_file(src, src_rel)
	if source_lang == "" {
		return "", wrapped_err(.Invalid, strings.concatenate({"unsupported file type: ", source_rel}, context.temp_allocator), a)
	}
	target_lang := lang_for_file(src, dst_rel)
	if target_lang == "" {
		return "", wrapped_err(.Invalid, strings.concatenate({"unsupported file type: ", target_rel}, context.temp_allocator), a)
	}

	sym, _, source_contents, _, rerr := resolve_symbol(src, nil, name_path, src_rel, a, token)
	if rerr != nil {
		return "", rerr
	}
	// The resolve basis doubles as the move's source bytes: the extract
	// slices the very parse the ranges came from, and the per-file guard
	// refuses the splice when the buffer moved since. It rides the request
	// arena (no delete); the target read below stays an
	// editor-allocator clone the defer returns.
	target_contents, trerr, trmsg := editor.editor_read_file(ed, dst_rel)
	if trerr != .None {
		return "", editor_err_map("move", trerr, trmsg, a)
	}
	defer delete(target_contents, ed.allocator)

	// One target parse serves the anchor and the duplicate guard; the
	// anchor's error kinds mirror resolve_symbol's.
	target_roots, tferr := ts_source_file_symbols(src, dst_rel, a)
	if tferr != nil {
		return "", tferr
	}
	target_sym: ^symbol.Symbol
	if target_position != "end" {
		found, find_err, find_msg := symbol.symbol_find_unique(target_roots, target_position)
		if find_err != .None {
			kind := platform.Err_Kind.Invalid
			if find_err == .No_Match {
				kind = .NotFound
			}
			return "", wrapped_err(kind, find_msg, a)
		}
		target_sym = found
	}
	if derr := move_duplicate_check(target_roots, src_rel, dst_rel, name_path, sym, mode, a); derr != nil {
		return "", derr
	}

	msg, merr, mmsg := editor.editor_symbol_move(
		ed, name_path, sym, src_rel, source_lang, source_contents,
		dst_rel, target_lang, target_contents, target_sym,
		target_position, mode,
	)
	if merr != .None {
		return "", editor_err_map("move", merr, mmsg, a)
	}
	return strings.clone(msg, a), nil
}

// name_path_leaf returns the last component of a slash-separated name
// path — the declaration name a move carries into the target file.
name_path_leaf :: proc(name_path: string) -> string {
	for i := len(name_path) - 1; i >= 0; i -= 1 {
		if name_path[i] == '/' {
			return name_path[i+1:]
		}
	}
	return name_path
}

// move_duplicate_check rejects a move/copy whose declaration name the
// target file already declares: a duplicate silently breaks every later
// symbol op on that name (ambiguous resolution). The one exemption is
// the symbol's own declaration being repositioned within the same file —
// two parses of the same bytes never share nodes, so identity is decided
// by the range start. Copy mode gets no exemption: even a same-file copy
// duplicates the declaration.
move_duplicate_check :: proc(
	target_roots: []^symbol.Symbol,
	src_rel, dst_rel: string,
	name_path: string,
	sym: ^symbol.Symbol,
	mode: editor.Move_Mode,
	a := context.allocator,
) -> platform.Err {
	leaf := name_path_leaf(name_path)
	dup, find_err, find_msg := symbol.symbol_find_unique(target_roots, leaf)
	switch find_err {
	case .No_Match, .Bad_Pattern:
		return nil
	case .Ambiguous:
		// Several of that name already sit in the target; find_msg lists
		// their full paths.
		return wrapped_err(.Invalid, strings.concatenate({
			"cannot move \"", name_path, "\": target ", dst_rel,
			" already declares \"", leaf, "\" (", find_msg, ")",
		}, a), a)
	case .None:
	}
	if mode != .Copy && platform.path_equal(src_rel, dst_rel) &&
		dup.range != nil && sym.range != nil &&
		dup.range.start.line == sym.range.start.line &&
		dup.range.start.character == sym.range.start.character {
		return nil
	}
	full := symbol.symbol_full_name_path(dup, context.temp_allocator)
	return wrapped_err(.Invalid, strings.concatenate({
		"cannot move \"", name_path, "\": target ", dst_rel,
		" already declares \"", full, "\"; rename the symbol or choose a different target",
	}, a), a)
}
