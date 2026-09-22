// The svc.ast face: syntactic parse and tree-sitter query over raw code
// strings, no project state. Both ops are bounded by fixed input caps
// (1 MiB of source, 64 KiB of query text), so they take no cancel token;
// the grammars and parsers they touch are created and destroyed within
// the calling thread.
package svc

import "core:fmt"
import "core:strings"
import "src:platform"
import "src:ts"

METHOD_AST_PARSE :: "svc.ast/parse" // {lang, code, max_answer_chars?} -> {sexpr}
METHOD_AST_QUERY :: "svc.ast/query" // {lang, code, query} -> {matches: [{pattern, captures: [{name, text, start_byte, end_byte}]}]}

AST_MAX_CODE_BYTES :: 1 << 20 // 1 MiB of source per parse
AST_MAX_QUERY_BYTES :: 1 << 16 // 64 KiB of .scm query text

// ast_parse renders the named-node tree of `code` as an S-expression.
// max_chars <= 0 keeps the ts default; a positive bound cuts the walk
// (the parens stay balanced). The returned string owns `a`.
ast_parse :: proc(code: string, lang: string, max_chars: int, a := context.allocator) -> (sexpr: string, err: platform.Err) {
	if len(code) > AST_MAX_CODE_BYTES {
		return "", wrapped_err(
			.Invalid,
			fmt.aprintf("code is too large (%d bytes); maximum is %d bytes", len(code), AST_MAX_CODE_BYTES, allocator = a),
			a,
		)
	}
	res, perr := ts.parse(code, lang)
	if perr != "" {
		// parse's only failure mode is language resolution — a caller mistake.
		return "", wrapped_err(.Invalid, perr, a)
	}
	defer ts.parse_release(&res)
	out := ts.to_s_expr(ts.parse_root(&res), res.source, max_chars)
	return strings.clone(out, a), nil
}

// ast_query compiles an .scm query against `code` and returns the
// structured matches (names, texts, byte ranges) allocated in `a`.
// Display shaping (the "No matches found." answer, max-chars truncation)
// belongs to the tool layer.
ast_query :: proc(code: string, lang: string, query_str: string, a := context.allocator) -> (matches: []ts.Match_Result, err: platform.Err) {
	if len(code) > AST_MAX_CODE_BYTES {
		return nil, wrapped_err(
			.Invalid,
			fmt.aprintf("code is too large (%d bytes); maximum is %d bytes", len(code), AST_MAX_CODE_BYTES, allocator = a),
			a,
		)
	}
	if len(query_str) > AST_MAX_QUERY_BYTES {
		return nil, wrapped_err(
			.Invalid,
			fmt.aprintf("query is too large (%d bytes); maximum is %d bytes", len(query_str), AST_MAX_QUERY_BYTES, allocator = a),
			a,
		)
	}
	res, qkind, qmsg := ts.query(code, lang, query_str, a)
	if qkind != .None {
		kind := platform.Err_Kind.Invalid
		if qkind == .Internal {
			kind = .Internal
		}
		return nil, wrapped_err(kind, qmsg, a)
	}
	return res, nil
}

