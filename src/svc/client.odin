// Child-side svc proxies: typed request builders over jsonrpc.conn_call so
// tool implementations never hand-build method names or param objects. The
// returned values borrow the caller's arena; error strings are the wire
// forms, valid until the arena goes.
package svc

import "core:encoding/json"
import "core:mem"
import "src:jsonrpc"
import "src:jsonutil"
import "src:platform"

Client_Call :: struct {
	result:      json.Value,
	err_code:    jsonrpc.Err_Code,
	err_message: string,
	call_err:    jsonrpc.Call_Err,
}

// client_call is the shared spine of every proxy below: one round trip
// whose four-part outcome is wrapped as the Client_Call the tool layer
// maps onto its result.
client_call :: proc(conn: ^jsonrpc.Conn, method: string, params: json.Value, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	result, ecode, msg, cerr := jsonrpc.conn_call(conn, method, params, arena, deadline_ms, token)
	return {result = result, err_code = ecode, err_message = msg, call_err = cerr}
}

client_symbol_list :: proc(conn: ^jsonrpc.Conn, path: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&params, "path", jsonutil.json_string(path))
	return client_call(conn, METHOD_SYMBOL_LIST, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_symbol_find :: proc(conn: ^jsonrpc.Conn, name: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&params, "name", jsonutil.json_string(name))
	return client_call(conn, METHOD_SYMBOL_FIND, json.Value(json.Object(params)), arena, deadline_ms, token)
}

// client_symbol_find_dead_code sends the optional params only when the
// caller provided them: empty path_prefix / nil entry_prefixes / limit
// 0 mean absent, and the daemon applies its defaults.
client_symbol_find_dead_code :: proc(conn: ^jsonrpc.Conn, path_prefix: string, entry_prefixes: []string, limit: int, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	if path_prefix != "" {
		jsonutil.obj_set(&params, "path_prefix", jsonutil.json_string(path_prefix))
	}
	if entry_prefixes != nil {
		items := make([]json.Value, len(entry_prefixes), arena)
		for i in 0..<len(entry_prefixes) {
			items[i] = jsonutil.json_string(entry_prefixes[i])
		}
		jsonutil.obj_set(&params, "entry_prefixes", jsonutil.json_array(items, arena))
	}
	if limit > 0 {
		jsonutil.obj_set(&params, "limit", jsonutil.json_int(i64(limit)))
	}
	return client_call(conn, METHOD_SYMBOL_FIND_DEAD_CODE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_index_crawl :: proc(conn: ^jsonrpc.Conn, within: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(1, arena)
	if within != "" {
		jsonutil.obj_set(&params, "within", jsonutil.json_string(within))
	}
	return client_call(conn, METHOD_INDEX_CRAWL, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_file_read :: proc(
	conn: ^jsonrpc.Conn,
	rel: string,
	start_line: int,
	end_line: int,
	end_set: bool,
	max_chars: int,
	arena: mem.Allocator,
	deadline_ms: i64,
	token:      ^platform.Cancel_Token = nil,
) -> Client_Call {
	params := jsonutil.json_object(4, arena)
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "start_line", jsonutil.json_int(i64(start_line)))
	if end_set {
		jsonutil.obj_set(&params, "end_line", jsonutil.json_int(i64(end_line)))
	}
	if max_chars > 0 {
		jsonutil.obj_set(&params, "max_answer_chars", jsonutil.json_int(i64(max_chars)))
	}
	return client_call(conn, METHOD_FILE_READ, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_file_write :: proc(conn: ^jsonrpc.Conn, rel: string, content: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "content", jsonutil.json_string(content))
	return client_call(conn, METHOD_FILE_WRITE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_file_list_dir :: proc(
	conn: ^jsonrpc.Conn,
	rel: string,
	recursive: bool,
	skip_ignored: bool,
	include_line_counts: bool,
	arena: mem.Allocator,
	deadline_ms: i64,
	token:      ^platform.Cancel_Token = nil,
) -> Client_Call {
	params := jsonutil.json_object(5, arena)
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "recursive", jsonutil.json_bool(recursive))
	jsonutil.obj_set(&params, "skip_ignored_files", jsonutil.json_bool(skip_ignored))
	jsonutil.obj_set(&params, "include_line_counts", jsonutil.json_bool(include_line_counts))
	return client_call(conn, METHOD_FILE_LIST_DIR, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_file_find :: proc(conn: ^jsonrpc.Conn, mask: string, within: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&params, "file_mask", jsonutil.json_string(mask))
	if within != "" {
		jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(within))
	}
	return client_call(conn, METHOD_FILE_FIND, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_file_search :: proc(conn: ^jsonrpc.Conn, req: File_Search_Req, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(10, arena)
	jsonutil.obj_set(&params, "substring_pattern", jsonutil.json_string(req.pattern))
	jsonutil.obj_set(&params, "multiline", jsonutil.json_bool(req.multiline))
	jsonutil.obj_set(&params, "context_lines_before", jsonutil.json_int(i64(req.context_before)))
	jsonutil.obj_set(&params, "context_lines_after", jsonutil.json_int(i64(req.context_after)))
	if req.include_glob != "" {
		jsonutil.obj_set(&params, "paths_include_glob", jsonutil.json_string(req.include_glob))
	}
	if req.exclude_glob != "" {
		jsonutil.obj_set(&params, "paths_exclude_glob", jsonutil.json_string(req.exclude_glob))
	}
	if req.scope_rel != "" {
		jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(req.scope_rel))
	}
	if req.offset > 0 {
		jsonutil.obj_set(&params, "offset", jsonutil.json_int(i64(req.offset)))
	}
	if req.limit > 0 {
		jsonutil.obj_set(&params, "limit", jsonutil.json_int(i64(req.limit)))
	}
	return client_call(conn, METHOD_FILE_SEARCH, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_file_outline :: proc(
	conn: ^jsonrpc.Conn,
	rel: string,
	path: string,
	max_chars: int,
	arena: mem.Allocator,
	deadline_ms: i64,
	token:      ^platform.Cancel_Token = nil,
) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	if path != "" {
		jsonutil.obj_set(&params, "path", jsonutil.json_string(path))
	}
	if max_chars > 0 {
		jsonutil.obj_set(&params, "max_answer_chars", jsonutil.json_int(i64(max_chars)))
	}
	return client_call(conn, METHOD_FILE_OUTLINE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_file_replace :: proc(
	conn: ^jsonrpc.Conn,
	rel: string,
	needle: string,
	repl: string,
	mode: string,
	allow_multiple: bool,
	arena: mem.Allocator,
	deadline_ms: i64,
	token:      ^platform.Cancel_Token = nil,
) -> Client_Call {
	params := jsonutil.json_object(6, arena)
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "needle", jsonutil.json_string(needle))
	jsonutil.obj_set(&params, "repl", jsonutil.json_string(repl))
	jsonutil.obj_set(&params, "mode", jsonutil.json_string(mode))
	jsonutil.obj_set(&params, "allow_multiple_occurrences", jsonutil.json_bool(allow_multiple))
	return client_call(conn, METHOD_FILE_REPLACE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_file_insert_lines :: proc(
	conn: ^jsonrpc.Conn,
	rel: string,
	line: int,
	content: string,
	arena: mem.Allocator,
	deadline_ms: i64,
	token:      ^platform.Cancel_Token = nil,
) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "line", jsonutil.json_int(i64(line)))
	jsonutil.obj_set(&params, "content", jsonutil.json_string(content))
	return client_call(conn, METHOD_FILE_INSERT_LINES, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_file_replace_lines :: proc(
	conn: ^jsonrpc.Conn,
	rel: string,
	start_line: int,
	end_line: int,
	content: string,
	arena: mem.Allocator,
	deadline_ms: i64,
	token:      ^platform.Cancel_Token = nil,
) -> Client_Call {
	params := jsonutil.json_object(4, arena)
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "start_line", jsonutil.json_int(i64(start_line)))
	jsonutil.obj_set(&params, "end_line", jsonutil.json_int(i64(end_line)))
	jsonutil.obj_set(&params, "content", jsonutil.json_string(content))
	return client_call(conn, METHOD_FILE_REPLACE_LINES, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_file_delete_lines :: proc(
	conn: ^jsonrpc.Conn,
	rel: string,
	start_line: int,
	end_line: int,
	arena: mem.Allocator,
	deadline_ms: i64,
	token:      ^platform.Cancel_Token = nil,
) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "start_line", jsonutil.json_int(i64(start_line)))
	jsonutil.obj_set(&params, "end_line", jsonutil.json_int(i64(end_line)))
	return client_call(conn, METHOD_FILE_DELETE_LINES, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_file_delete :: proc(conn: ^jsonrpc.Conn, rel: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	return client_call(conn, METHOD_FILE_DELETE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_file_move :: proc(conn: ^jsonrpc.Conn, src: string, dst: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&params, "source_relative_path", jsonutil.json_string(src))
	jsonutil.obj_set(&params, "target_relative_path", jsonutil.json_string(dst))
	return client_call(conn, METHOD_FILE_MOVE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_ast_parse :: proc(
	conn: ^jsonrpc.Conn,
	lang: string,
	code: string,
	max_chars: int,
	arena: mem.Allocator,
	deadline_ms: i64,
	token:      ^platform.Cancel_Token = nil,
) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&params, "lang", jsonutil.json_string(lang))
	jsonutil.obj_set(&params, "code", jsonutil.json_string(code))
	if max_chars > 0 {
		jsonutil.obj_set(&params, "max_answer_chars", jsonutil.json_int(i64(max_chars)))
	}
	return client_call(conn, METHOD_AST_PARSE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_ast_query :: proc(
	conn: ^jsonrpc.Conn,
	lang: string,
	code: string,
	query: string,
	arena: mem.Allocator,
	deadline_ms: i64,
	token:      ^platform.Cancel_Token = nil,
) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&params, "lang", jsonutil.json_string(lang))
	jsonutil.obj_set(&params, "code", jsonutil.json_string(code))
	jsonutil.obj_set(&params, "query", jsonutil.json_string(query))
	return client_call(conn, METHOD_AST_QUERY, json.Value(json.Object(params)), arena, deadline_ms, token)
}

// client_ast_find_duplicates sends the optional params only when the
// caller provided them: empty path_prefix / 0 min_nodes / 0 limit mean
// absent, and the daemon applies its defaults.
client_ast_find_duplicates :: proc(conn: ^jsonrpc.Conn, path_prefix: string, min_nodes: int, limit: int, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	if path_prefix != "" {
		jsonutil.obj_set(&params, "path_prefix", jsonutil.json_string(path_prefix))
	}
	if min_nodes > 0 {
		jsonutil.obj_set(&params, "min_nodes", jsonutil.json_int(i64(min_nodes)))
	}
	if limit > 0 {
		jsonutil.obj_set(&params, "limit", jsonutil.json_int(i64(limit)))
	}
	return client_call(conn, METHOD_AST_FIND_DUPLICATES, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_symbol_replace_body :: proc(conn: ^jsonrpc.Conn, name_path: string, rel: string, body: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&params, "name_path", jsonutil.json_string(name_path))
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "body", jsonutil.json_string(body))
	return client_call(conn, METHOD_SYMBOL_REPLACE_BODY, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_symbol_insert_before :: proc(conn: ^jsonrpc.Conn, name_path: string, rel: string, body: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&params, "name_path", jsonutil.json_string(name_path))
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "body", jsonutil.json_string(body))
	return client_call(conn, METHOD_SYMBOL_INSERT_BEFORE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_symbol_insert_after :: proc(conn: ^jsonrpc.Conn, name_path: string, rel: string, body: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&params, "name_path", jsonutil.json_string(name_path))
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "body", jsonutil.json_string(body))
	return client_call(conn, METHOD_SYMBOL_INSERT_AFTER, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_symbol_move :: proc(conn: ^jsonrpc.Conn, name_path: string, source_rel: string, target_rel: string, target_position: string, mode: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(6, arena)
	jsonutil.obj_set(&params, "name_path", jsonutil.json_string(name_path))
	jsonutil.obj_set(&params, "source_relative_path", jsonutil.json_string(source_rel))
	jsonutil.obj_set(&params, "target_relative_path", jsonutil.json_string(target_rel))
	jsonutil.obj_set(&params, "target_position", jsonutil.json_string(target_position))
	if mode != "" {
		jsonutil.obj_set(&params, "mode", jsonutil.json_string(mode))
	}
	return client_call(conn, METHOD_SYMBOL_MOVE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_symbol_insert_docstring :: proc(conn: ^jsonrpc.Conn, name_path: string, rel: string, comment: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&params, "name_path", jsonutil.json_string(name_path))
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "comment", jsonutil.json_string(comment))
	return client_call(conn, METHOD_SYMBOL_INSERT_DOCSTRING, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_symbol_delete_docstring :: proc(conn: ^jsonrpc.Conn, name_path: string, rel: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&params, "name_path", jsonutil.json_string(name_path))
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	return client_call(conn, METHOD_SYMBOL_DELETE_DOCSTRING, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_symbol_replace_docstring :: proc(conn: ^jsonrpc.Conn, name_path: string, rel: string, comment: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&params, "name_path", jsonutil.json_string(name_path))
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "comment", jsonutil.json_string(comment))
	return client_call(conn, METHOD_SYMBOL_REPLACE_DOCSTRING, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_langserver_start :: proc(conn: ^jsonrpc.Conn, language: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&params, "language", jsonutil.json_string(language))
	return client_call(conn, METHOD_LANGSERVER_START, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_langserver_stop :: proc(conn: ^jsonrpc.Conn, language: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&params, "language", jsonutil.json_string(language))
	return client_call(conn, METHOD_LANGSERVER_STOP, json.Value(json.Object(params)), arena, deadline_ms, token)
}

// client_langserver_restart sends an empty language for the whole-manager
// cold reset (each language rebuilds on its next use).
client_langserver_restart :: proc(conn: ^jsonrpc.Conn, language: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(1, arena)
	if language != "" {
		jsonutil.obj_set(&params, "language", jsonutil.json_string(language))
	}
	return client_call(conn, METHOD_LANGSERVER_RESTART, json.Value(json.Object(params)), arena, deadline_ms, token)
}

// client_langserver_reload re-reads the language-server settings on the
// daemon (config-failure refusals change nothing there).
client_langserver_reload :: proc(conn: ^jsonrpc.Conn, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	return client_call(conn, METHOD_LANGSERVER_RELOAD, nil, arena, deadline_ms, token)
}

// client_config_set upserts one member of .aubade/project.jsonc on the
// daemon; an empty member writes the top-level key, a non-empty one a
// single entry inside a map-valued key. The value is JSON text validated
// against the loader — a refused write leaves the file untouched.
client_config_set :: proc(conn: ^jsonrpc.Conn, key: string, member: string, value: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&params, "key", jsonutil.json_string(key))
	if member != "" {
		jsonutil.obj_set(&params, "member", jsonutil.json_string(member))
	}
	jsonutil.obj_set(&params, "value", jsonutil.json_string(value))
	return client_call(conn, METHOD_CONFIG_SET, json.Value(json.Object(params)), arena, deadline_ms, token)
}

// client_config_delete removes one member of .aubade/project.jsonc on the
// daemon (top-level key, or a single entry inside a map-valued key when
// member is set). An absent member is a no-op success.
client_config_delete :: proc(conn: ^jsonrpc.Conn, key: string, member: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&params, "key", jsonutil.json_string(key))
	if member != "" {
		jsonutil.obj_set(&params, "member", jsonutil.json_string(member))
	}
	return client_call(conn, METHOD_CONFIG_DELETE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_langserver_list :: proc(conn: ^jsonrpc.Conn, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	return client_call(conn, METHOD_LANGSERVER_LIST, nil, arena, deadline_ms, token)
}

client_langserver_diagnostics :: proc(conn: ^jsonrpc.Conn, rel: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	return client_call(conn, METHOD_LANGSERVER_DIAGNOSTICS, json.Value(json.Object(params)), arena, deadline_ms, token)
}

// range_params builds the relative_path + start/end line/col block the
// two LSP range tools send (code actions, inlay hints).
range_params :: proc(rel: string, start_line, start_col, end_line, end_col: int, arena: mem.Allocator) -> json.Value {
	params := jsonutil.json_object(5, arena)
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "start_line", jsonutil.json_int(i64(start_line)))
	jsonutil.obj_set(&params, "start_col", jsonutil.json_int(i64(start_col)))
	jsonutil.obj_set(&params, "end_line", jsonutil.json_int(i64(end_line)))
	jsonutil.obj_set(&params, "end_col", jsonutil.json_int(i64(end_col)))
	return json.Value(json.Object(params))
}

client_langserver_code_actions :: proc(conn: ^jsonrpc.Conn, rel: string, start_line, start_col, end_line, end_col: int, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	return client_call(conn, METHOD_LANGSERVER_CODE_ACTIONS, range_params(rel, start_line, start_col, end_line, end_col, arena), arena, deadline_ms, token)
}

client_langserver_format :: proc(conn: ^jsonrpc.Conn, rel: string, tab_size: int, insert_spaces: bool, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "tab_size", jsonutil.json_int(i64(tab_size)))
	jsonutil.obj_set(&params, "insert_spaces", jsonutil.json_bool(insert_spaces))
	return client_call(conn, METHOD_LANGSERVER_FORMAT, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_langserver_inlay_hints :: proc(conn: ^jsonrpc.Conn, rel: string, start_line, start_col, end_line, end_col: int, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	return client_call(conn, METHOD_LANGSERVER_INLAY_HINTS, range_params(rel, start_line, start_col, end_line, end_col, arena), arena, deadline_ms, token)
}

client_langserver_call_hierarchy :: proc(conn: ^jsonrpc.Conn, rel: string, line, col: int, direction: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(4, arena)
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "line", jsonutil.json_int(i64(line)))
	jsonutil.obj_set(&params, "col", jsonutil.json_int(i64(col)))
	jsonutil.obj_set(&params, "direction", jsonutil.json_string(direction))
	return client_call(conn, METHOD_LANGSERVER_CALL_HIERARCHY, json.Value(json.Object(params)), arena, deadline_ms, token)
}

// --- svc.memory/* proxies -----------------------------------------------------

client_symbol_find_references :: proc(
	conn: ^jsonrpc.Conn,
	name_path: string,
	rel: string,
	include_imports: bool,
	include_self: bool,
	include_file_symbols: bool,
	include_kinds: []u32,
	exclude_kinds: []u32,
	arena: mem.Allocator,
	deadline_ms: i64,
	token: ^platform.Cancel_Token = nil,
) -> Client_Call {
	params := jsonutil.json_object(7, arena)
	jsonutil.obj_set(&params, "name_path", jsonutil.json_string(name_path))
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "include_imports", jsonutil.json_bool(include_imports))
	jsonutil.obj_set(&params, "include_self", jsonutil.json_bool(include_self))
	jsonutil.obj_set(&params, "include_file_symbols", jsonutil.json_bool(include_file_symbols))
	if len(include_kinds) > 0 {
		jsonutil.obj_set(&params, "include_kinds", kinds_json(include_kinds, arena))
	}
	if len(exclude_kinds) > 0 {
		jsonutil.obj_set(&params, "exclude_kinds", kinds_json(exclude_kinds, arena))
	}
	return client_call(conn, METHOD_SYMBOL_FIND_REFERENCES, json.Value(json.Object(params)), arena, deadline_ms, token)
}

kinds_json :: proc(kinds: []u32, arena: mem.Allocator) -> json.Value {
	items := make([]json.Value, len(kinds), arena)
	for i in 0..<len(kinds) {
		items[i] = jsonutil.json_int(i64(kinds[i]))
	}
	return jsonutil.json_array(items, arena)
}

client_symbol_find_implementations :: proc(
	conn: ^jsonrpc.Conn,
	name_path: string,
	rel: string,
	include_body: bool,
	include_info: bool,
	include_kinds: []u32,
	exclude_kinds: []u32,
	arena: mem.Allocator,
	deadline_ms: i64,
	token: ^platform.Cancel_Token = nil,
) -> Client_Call {
	params := jsonutil.json_object(6, arena)
	jsonutil.obj_set(&params, "name_path", jsonutil.json_string(name_path))
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "include_body", jsonutil.json_bool(include_body))
	jsonutil.obj_set(&params, "include_info", jsonutil.json_bool(include_info))
	if len(include_kinds) > 0 {
		jsonutil.obj_set(&params, "include_kinds", kinds_json(include_kinds, arena))
	}
	if len(exclude_kinds) > 0 {
		jsonutil.obj_set(&params, "exclude_kinds", kinds_json(exclude_kinds, arena))
	}
	return client_call(conn, METHOD_SYMBOL_FIND_IMPLEMENTATIONS, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_symbol_find_declaration :: proc(
	conn: ^jsonrpc.Conn,
	name_path: string,
	rel: string,
	arena: mem.Allocator,
	deadline_ms: i64,
	token: ^platform.Cancel_Token = nil,
) -> Client_Call {
	params := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&params, "name_path", jsonutil.json_string(name_path))
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	return client_call(conn, METHOD_SYMBOL_FIND_DECLARATION, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_symbol_rename :: proc(
	conn: ^jsonrpc.Conn,
	name_path: string,
	rel: string,
	new_name: string,
	arena: mem.Allocator,
	deadline_ms: i64,
	token: ^platform.Cancel_Token = nil,
) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&params, "name_path", jsonutil.json_string(name_path))
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "new_name", jsonutil.json_string(new_name))
	return client_call(conn, METHOD_SYMBOL_RENAME, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_symbol_delete :: proc(
	conn: ^jsonrpc.Conn,
	name_path_pattern: string,
	rel: string,
	include_comments: bool,
	arena: mem.Allocator,
	deadline_ms: i64,
	token: ^platform.Cancel_Token = nil,
) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&params, "name_path_pattern", jsonutil.json_string(name_path_pattern))
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string(rel))
	jsonutil.obj_set(&params, "include_comments", jsonutil.json_bool(include_comments))
	return client_call(conn, METHOD_SYMBOL_DELETE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_memory_list :: proc(conn: ^jsonrpc.Conn, topic: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(1, arena)
	if topic != "" {
		jsonutil.obj_set(&params, "topic", jsonutil.json_string(topic))
	}
	return client_call(conn, METHOD_MEMORY_LIST, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_memory_read :: proc(conn: ^jsonrpc.Conn, name: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&params, "memory_name", jsonutil.json_string(name))
	return client_call(conn, METHOD_MEMORY_READ, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_memory_write :: proc(conn: ^jsonrpc.Conn, name: string, content: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&params, "memory_name", jsonutil.json_string(name))
	jsonutil.obj_set(&params, "content", jsonutil.json_string(content))
	return client_call(conn, METHOD_MEMORY_WRITE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_memory_replace :: proc(conn: ^jsonrpc.Conn, name: string, needle: string, repl: string, mode: string, allow_multiple: bool, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(5, arena)
	jsonutil.obj_set(&params, "memory_name", jsonutil.json_string(name))
	jsonutil.obj_set(&params, "needle", jsonutil.json_string(needle))
	jsonutil.obj_set(&params, "repl", jsonutil.json_string(repl))
	jsonutil.obj_set(&params, "mode", jsonutil.json_string(mode))
	jsonutil.obj_set(&params, "allow_multiple_occurrences", jsonutil.json_bool(allow_multiple))
	return client_call(conn, METHOD_MEMORY_REPLACE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_memory_rename :: proc(conn: ^jsonrpc.Conn, old_name: string, new_name: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&params, "old_name", jsonutil.json_string(old_name))
	jsonutil.obj_set(&params, "new_name", jsonutil.json_string(new_name))
	return client_call(conn, METHOD_MEMORY_RENAME, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_memory_delete :: proc(conn: ^jsonrpc.Conn, name: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&params, "memory_name", jsonutil.json_string(name))
	return client_call(conn, METHOD_MEMORY_DELETE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

// --- tracker ----------------------------------------------------------------

client_tracker_list_incidents :: proc(conn: ^jsonrpc.Conn, status: []string, verdict, sprint, label: string, priority: []string, assignee, created_by, query, blocked_by, sort: string, limit: int, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(11, arena)
	if len(status) > 0 {
		jsonutil.obj_set(&params, "status", jsonutil.json_string_array(status, arena))
	}
	if verdict != "" {
		jsonutil.obj_set(&params, "verdict", jsonutil.json_string(verdict))
	}
	if sprint != "" {
		jsonutil.obj_set(&params, "sprint", jsonutil.json_string(sprint))
	}
	if label != "" {
		jsonutil.obj_set(&params, "label", jsonutil.json_string(label))
	}
	if len(priority) > 0 {
		jsonutil.obj_set(&params, "priority", jsonutil.json_string_array(priority, arena))
	}
	if assignee != "" {
		jsonutil.obj_set(&params, "assignee", jsonutil.json_string(assignee))
	}
	if created_by != "" {
		jsonutil.obj_set(&params, "created_by", jsonutil.json_string(created_by))
	}
	if query != "" {
		jsonutil.obj_set(&params, "query", jsonutil.json_string(query))
	}
	if blocked_by != "" {
		jsonutil.obj_set(&params, "blocked_by", jsonutil.json_string(blocked_by))
	}
	if sort != "" {
		jsonutil.obj_set(&params, "sort", jsonutil.json_string(sort))
	}
	if limit != 0 {
		jsonutil.obj_set(&params, "limit", jsonutil.json_int(i64(limit)))
	}
	return client_call(conn, METHOD_TRACKER_LIST_INCIDENTS, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_tracker_get :: proc(conn: ^jsonrpc.Conn, method: string, id: string, max_chars: int, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&params, "id", jsonutil.json_string(id))
	if max_chars > 0 {
		jsonutil.obj_set(&params, "max_answer_chars", jsonutil.json_int(i64(max_chars)))
	}
	return client_call(conn, method, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_tracker_create :: proc(conn: ^jsonrpc.Conn, req: ^Tracker_Create_Req, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(9, arena)
	jsonutil.obj_set(&params, "title", jsonutil.json_string(req.title))
	jsonutil.obj_set(&params, "description", jsonutil.json_string(req.description))
	if req.priority != "" {
		jsonutil.obj_set(&params, "priority", jsonutil.json_string(req.priority))
	}
	if req.assignee != "" {
		jsonutil.obj_set(&params, "assignee", jsonutil.json_string(req.assignee))
	}
	if req.created_by != "" {
		jsonutil.obj_set(&params, "created_by", jsonutil.json_string(req.created_by))
	}
	if req.sprint != "" {
		jsonutil.obj_set(&params, "sprint", jsonutil.json_string(req.sprint))
	}
	if len(req.labels) > 0 {
		jsonutil.obj_set(&params, "labels", jsonutil.json_string_array(req.labels, arena))
	}
	if len(req.aliases) > 0 {
		jsonutil.obj_set(&params, "aliases", jsonutil.json_string_array(req.aliases, arena))
	}
	if len(req.blocked_by) > 0 {
		jsonutil.obj_set(&params, "blocked_by", jsonutil.json_string_array(req.blocked_by, arena))
	}
	return client_call(conn, METHOD_TRACKER_CREATE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_tracker_verify :: proc(conn: ^jsonrpc.Conn, id, verdict, fp_pattern, reason, evidence: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(5, arena)
	jsonutil.obj_set(&params, "id", jsonutil.json_string(id))
	jsonutil.obj_set(&params, "verdict", jsonutil.json_string(verdict))
	if fp_pattern != "" {
		jsonutil.obj_set(&params, "fp_pattern", jsonutil.json_string(fp_pattern))
	}
	jsonutil.obj_set(&params, "reason", jsonutil.json_string(reason))
	jsonutil.obj_set(&params, "evidence", jsonutil.json_string(evidence))
	return client_call(conn, METHOD_TRACKER_VERIFY, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_tracker_update :: proc(conn: ^jsonrpc.Conn, req: ^Tracker_Update_Req, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(11, arena)
	jsonutil.obj_set(&params, "id", jsonutil.json_string(req.id))
	if req.title_set {
		jsonutil.obj_set(&params, "title", jsonutil.json_string(req.title))
	}
	if req.root_cause_set {
		jsonutil.obj_set(&params, "root_cause", jsonutil.json_string(req.root_cause))
	}
	if req.note_set {
		jsonutil.obj_set(&params, "note", jsonutil.json_string(req.note))
	}
	if req.status_set {
		jsonutil.obj_set(&params, "status", jsonutil.json_string(req.status))
	}
	if req.priority_set {
		jsonutil.obj_set(&params, "priority", jsonutil.json_string(req.priority))
	}
	if req.sprint_set {
		jsonutil.obj_set(&params, "sprint", jsonutil.json_string(req.sprint))
	}
	if req.assignee_set {
		jsonutil.obj_set(&params, "assignee", jsonutil.json_string(req.assignee))
	}
	if req.labels_set {
		jsonutil.obj_set(&params, "labels", jsonutil.json_string_array(req.labels, arena))
	}
	if req.aliases_set {
		jsonutil.obj_set(&params, "aliases", jsonutil.json_string_array(req.aliases, arena))
	}
	if req.blocked_by_set {
		jsonutil.obj_set(&params, "blocked_by", jsonutil.json_string_array(req.blocked_by, arena))
	}
	return client_call(conn, METHOD_TRACKER_UPDATE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_tracker_resolve :: proc(conn: ^jsonrpc.Conn, id, resolution, evidence, note: string, note_set: bool, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(4, arena)
	jsonutil.obj_set(&params, "id", jsonutil.json_string(id))
	jsonutil.obj_set(&params, "resolution", jsonutil.json_string(resolution))
	jsonutil.obj_set(&params, "evidence", jsonutil.json_string(evidence))
	if note_set {
		jsonutil.obj_set(&params, "note", jsonutil.json_string(note))
	}
	return client_call(conn, METHOD_TRACKER_RESOLVE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_tracker_delete :: proc(conn: ^jsonrpc.Conn, id, reason, duplicate_of: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&params, "id", jsonutil.json_string(id))
	jsonutil.obj_set(&params, "reason", jsonutil.json_string(reason))
	if duplicate_of != "" {
		jsonutil.obj_set(&params, "duplicate_of", jsonutil.json_string(duplicate_of))
	}
	return client_call(conn, METHOD_TRACKER_DELETE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_tracker_start_sprint :: proc(conn: ^jsonrpc.Conn, name, goal, follows: string, goal_set: bool, must: []string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(4, arena)
	jsonutil.obj_set(&params, "name", jsonutil.json_string(name))
	if goal_set {
		jsonutil.obj_set(&params, "goal", jsonutil.json_string(goal))
	}
	if follows != "" {
		jsonutil.obj_set(&params, "follows", jsonutil.json_string(follows))
	}
	if len(must) > 0 {
		jsonutil.obj_set(&params, "must", jsonutil.json_string_array(must, arena))
	}
	return client_call(conn, METHOD_TRACKER_START_SPRINT, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_tracker_close_sprint :: proc(conn: ^jsonrpc.Conn, outcome: string, outcome_set: bool, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(1, arena)
	if outcome_set {
		jsonutil.obj_set(&params, "outcome", jsonutil.json_string(outcome))
	}
	return client_call(conn, METHOD_TRACKER_CLOSE_SPRINT, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_tracker_list_sprints :: proc(conn: ^jsonrpc.Conn, include_closed: bool, limit: int, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(2, arena)
	if include_closed {
		jsonutil.obj_set(&params, "include_closed", jsonutil.json_bool(true))
	}
	if limit != 0 {
		jsonutil.obj_set(&params, "limit", jsonutil.json_int(i64(limit)))
	}
	return client_call(conn, METHOD_TRACKER_LIST_SPRINTS, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_tracker_update_sprint :: proc(conn: ^jsonrpc.Conn, req: ^Tracker_Sprint_Update_Req, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(10, arena)
	jsonutil.obj_set(&params, "id", jsonutil.json_string(req.id))
	if req.goal_set {
		jsonutil.obj_set(&params, "goal", jsonutil.json_string(req.goal))
	}
	if req.note_set {
		jsonutil.obj_set(&params, "note", jsonutil.json_string(req.note))
	}
	if req.outcome_set {
		jsonutil.obj_set(&params, "outcome", jsonutil.json_string(req.outcome))
	}
	if req.defer_type != "" {
		jsonutil.obj_set(&params, "defer_type", jsonutil.json_string(req.defer_type))
	}
	if req.defer_task != "" {
		jsonutil.obj_set(&params, "task", jsonutil.json_string(req.defer_task))
	}
	if req.defer_ref != "" {
		jsonutil.obj_set(&params, "ref", jsonutil.json_string(req.defer_ref))
	}
	if req.resolves != "" {
		jsonutil.obj_set(&params, "resolves", jsonutil.json_string(req.resolves))
	}
	if req.must_set {
		jsonutil.obj_set(&params, "must", jsonutil.json_string_array(req.must, arena))
	}
	return client_call(conn, METHOD_TRACKER_UPDATE_SPRINT, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_tracker_record_verification :: proc(conn: ^jsonrpc.Conn, task, definition, outcome, output, session: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(5, arena)
	jsonutil.obj_set(&params, "task", jsonutil.json_string(task))
	jsonutil.obj_set(&params, "definition", jsonutil.json_string(definition))
	jsonutil.obj_set(&params, "outcome", jsonutil.json_string(outcome))
	jsonutil.obj_set(&params, "output", jsonutil.json_string(output))
	if session != "" {
		jsonutil.obj_set(&params, "session", jsonutil.json_string(session))
	}
	return client_call(conn, METHOD_TRACKER_RECORD_VERIFICATION, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_tracker_export :: proc(conn: ^jsonrpc.Conn, sprint: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(1, arena)
	if sprint != "" {
		jsonutil.obj_set(&params, "sprint", jsonutil.json_string(sprint))
	}
	return client_call(conn, METHOD_TRACKER_EXPORT, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_tracker_open_summary :: proc(conn: ^jsonrpc.Conn, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(1, arena)
	return client_call(conn, METHOD_TRACKER_OPEN_SUMMARY, json.Value(json.Object(params)), arena, deadline_ms, token)
}

// --- shadow ------------------------------------------------------------------

client_shadow_snapshot :: proc(conn: ^jsonrpc.Conn, message: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(1, arena)
	if message != "" {
		jsonutil.obj_set(&params, "message", jsonutil.json_string(message))
	}
	return client_call(conn, METHOD_SHADOW_SNAPSHOT, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_shadow_log :: proc(conn: ^jsonrpc.Conn, count: int, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(1, arena)
	if count > 0 {
		jsonutil.obj_set(&params, "count", jsonutil.json_int(i64(count)))
	}
	return client_call(conn, METHOD_SHADOW_LOG, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_shadow_diff :: proc(conn: ^jsonrpc.Conn, from, to: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&params, "from", jsonutil.json_string(from))
	jsonutil.obj_set(&params, "to", jsonutil.json_string(to))
	return client_call(conn, METHOD_SHADOW_DIFF, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_shadow_patch :: proc(conn: ^jsonrpc.Conn, from, to: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&params, "from", jsonutil.json_string(from))
	jsonutil.obj_set(&params, "to", jsonutil.json_string(to))
	return client_call(conn, METHOD_SHADOW_PATCH, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_shadow_restore :: proc(conn: ^jsonrpc.Conn, hash: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(1, arena)
	jsonutil.obj_set(&params, "hash", jsonutil.json_string(hash))
	return client_call(conn, METHOD_SHADOW_RESTORE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_shadow_revert_file :: proc(conn: ^jsonrpc.Conn, hash, file_path: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&params, "hash", jsonutil.json_string(hash))
	jsonutil.obj_set(&params, "file_path", jsonutil.json_string(file_path))
	return client_call(conn, METHOD_SHADOW_REVERT_FILE, json.Value(json.Object(params)), arena, deadline_ms, token)
}

// --- web ----------------------------------------------------------------------

client_web_fetch :: proc(conn: ^jsonrpc.Conn, url: string, max_chars: int, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&params, "url", jsonutil.json_string(url))
	if max_chars > 0 {
		jsonutil.obj_set(&params, "max_chars", jsonutil.json_int(i64(max_chars)))
	}
	return client_call(conn, METHOD_WEB_FETCH, json.Value(json.Object(params)), arena, deadline_ms, token)
}

client_web_search :: proc(conn: ^jsonrpc.Conn, query: string, count: int, range_code: string, arena: mem.Allocator, deadline_ms: i64, token: ^platform.Cancel_Token = nil) -> Client_Call {
	params := jsonutil.json_object(3, arena)
	jsonutil.obj_set(&params, "query", jsonutil.json_string(query))
	if count > 0 {
		jsonutil.obj_set(&params, "count", jsonutil.json_int(i64(count)))
	}
	if range_code != "" {
		jsonutil.obj_set(&params, "range", jsonutil.json_string(range_code))
	}
	return client_call(conn, METHOD_WEB_SEARCH, json.Value(json.Object(params)), arena, deadline_ms, token)
}
