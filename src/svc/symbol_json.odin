// The symbol/index svc face: method names, the wire serialization of a
// finalized symbol forest, and the crawl-stats shape. The daemon produces
// these values; child-side tools consume them unchanged.
package svc

import "core:encoding/json"
import "core:mem"
import "src:jsonutil"
import "src:symbol"

METHOD_SYMBOL_LIST :: "svc.symbol/list"  // request: {path} -> {symbols: [...]}
METHOD_SYMBOL_FIND :: "svc.symbol/find"  // request: {name} -> {matches: [{name, kind, path, hash, line, parent}]}
METHOD_SYMBOL_FIND_DEAD_CODE :: "svc.symbol/find_dead_code"  // request: {path_prefix?, entry_prefixes?, limit?} -> {candidates: [...], stats: {...}}
METHOD_INDEX_CRAWL :: "svc.index/crawl"  // request: {within?} -> {stats: {...}}

// symbol_tree_json serializes a finalized forest. Bodies are deliberately
// absent: list consumers render structure, body consumers fetch per symbol.
symbol_tree_json :: proc(roots: []^symbol.Symbol, arena: mem.Allocator) -> json.Value {
	items := make([]json.Value, len(roots), arena)
	for i in 0..<len(roots) {
		items[i] = symbol_node_json(roots[i], arena)
	}
	return jsonutil.json_array(items, arena)
}

symbol_node_json :: proc(sym: ^symbol.Symbol, arena: mem.Allocator, depth := 0) -> json.Value {
	obj := jsonutil.json_object(10, arena)
	jsonutil.obj_set(&obj, "name", jsonutil.json_string(sym.name))
	jsonutil.obj_set(&obj, "kind", jsonutil.json_int(i64(sym.kind)))
	jsonutil.obj_set(&obj, "kind_name", jsonutil.json_string(symbol.kind_name(sym.kind)))
	jsonutil.obj_set(&obj, "container", jsonutil.json_string(sym.container_name))
	jsonutil.obj_set(&obj, "detail", jsonutil.json_string(sym.detail))
	jsonutil.obj_set(&obj, "overload_index", jsonutil.json_int(i64(sym.overload_idx)))
	if sym.range != nil {
		jsonutil.obj_set(&obj, "range", range_json(sym.range, arena))
	}
	if sym.selection_range != nil {
		jsonutil.obj_set(&obj, "selection_range", range_json(sym.selection_range, arena))
	}
	if sym.location != nil {
		loc := jsonutil.json_object(3, arena)
		jsonutil.obj_set(&loc, "uri", jsonutil.json_string(sym.location.uri))
		jsonutil.obj_set(&loc, "abs_path", jsonutil.json_string(sym.location.abs_path))
		jsonutil.obj_set(&loc, "rel_path", jsonutil.json_string(sym.location.rel_path))
		jsonutil.obj_set(&obj, "location", json.Value(json.Object(loc)))
	}
	if len(sym.children) > 0 && depth < symbol.MAX_TREE_DEPTH {
		items := make([]json.Value, len(sym.children), arena)
		for i in 0..<len(sym.children) {
			items[i] = symbol_node_json(sym.children[i], arena, depth + 1)
		}
		jsonutil.obj_set(&obj, "children", jsonutil.json_array(items, arena))
	}
	return json.Value(json.Object(obj))
}

range_json :: proc(r: ^symbol.Range, arena: mem.Allocator) -> json.Value {
	obj := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&obj, "start", position_json(&r.start, arena))
	jsonutil.obj_set(&obj, "end", position_json(&r.end, arena))
	return json.Value(json.Object(obj))
}

position_json :: proc(p: ^symbol.Position, arena: mem.Allocator) -> json.Value {
	obj := jsonutil.json_object(2, arena)
	jsonutil.obj_set(&obj, "line", jsonutil.json_int(i64(p.line)))
	jsonutil.obj_set(&obj, "character", jsonutil.json_int(i64(p.character)))
	return json.Value(json.Object(obj))
}

dead_scan_candidates_json :: proc(candidates: []Dead_Scan_Candidate, arena: mem.Allocator) -> json.Value {
	items := make([]json.Value, len(candidates), arena)
	for i in 0..<len(candidates) {
		obj := jsonutil.json_object(5, arena)
		jsonutil.obj_set(&obj, "path", jsonutil.json_string(candidates[i].path))
		jsonutil.obj_set(&obj, "line", jsonutil.json_int(candidates[i].line))
		jsonutil.obj_set(&obj, "kind", jsonutil.json_string(candidates[i].kind))
		jsonutil.obj_set(&obj, "name", jsonutil.json_string(candidates[i].name))
		jsonutil.obj_set(&obj, "name_path", jsonutil.json_string(candidates[i].name_path))
		items[i] = json.Value(json.Object(obj))
	}
	return jsonutil.json_array(items, arena)
}

dead_scan_stats_json :: proc(stats: ^Dead_Scan_Stats, arena: mem.Allocator) -> json.Value {
	obj := jsonutil.json_object(7, arena)
	jsonutil.obj_set(&obj, "files_scanned", jsonutil.json_int(i64(stats.files_scanned)))
	jsonutil.obj_set(&obj, "files_parsed", jsonutil.json_int(i64(stats.files_parsed)))
	jsonutil.obj_set(&obj, "definitions", jsonutil.json_int(i64(stats.definitions)))
	jsonutil.obj_set(&obj, "candidates_total", jsonutil.json_int(i64(stats.candidates_total)))
	jsonutil.obj_set(&obj, "truncated", jsonutil.json_bool(stats.truncated))
	jsonutil.obj_set(&obj, "walk_truncated", jsonutil.json_bool(stats.walk_truncated))
	return json.Value(json.Object(obj))
}

crawl_stats_json :: proc(stats: ^Crawl_Stats, arena: mem.Allocator) -> json.Value {
	obj := jsonutil.json_object(13, arena)
	jsonutil.obj_set(&obj, "dirs_visited", jsonutil.json_int(i64(stats.dirs_visited)))
	jsonutil.obj_set(&obj, "dirs_pruned", jsonutil.json_int(i64(stats.dirs_pruned)))
	jsonutil.obj_set(&obj, "dirs_failed", jsonutil.json_int(i64(stats.dirs_failed)))
	jsonutil.obj_set(&obj, "files_indexed", jsonutil.json_int(i64(stats.files_indexed)))
	jsonutil.obj_set(&obj, "files_unchanged", jsonutil.json_int(i64(stats.files_unchanged)))
	jsonutil.obj_set(&obj, "files_ignored", jsonutil.json_int(i64(stats.files_ignored)))
	jsonutil.obj_set(&obj, "files_unsupported", jsonutil.json_int(i64(stats.files_unsupported)))
	jsonutil.obj_set(&obj, "files_oversize", jsonutil.json_int(i64(stats.files_oversize)))
	jsonutil.obj_set(&obj, "files_failed", jsonutil.json_int(i64(stats.files_failed)))
	jsonutil.obj_set(&obj, "symbols", jsonutil.json_int(i64(stats.symbols)))
	jsonutil.obj_set(&obj, "paths_purged", jsonutil.json_int(i64(stats.paths_purged)))
	jsonutil.obj_set(&obj, "truncated", jsonutil.json_bool(stats.truncated))
	return json.Value(json.Object(obj))
}
