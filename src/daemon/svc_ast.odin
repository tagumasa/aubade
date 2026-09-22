// The svc.ast/* handlers: parse the wire params (the tool argument
// names) and forward to the syntactic ts ops. No daemon state is
// involved — the grammars live in this process, which is why the tools
// cross the svc boundary for these.
package daemon

import "core:encoding/json"
import "src:jsonutil"
import "src:platform"
import "src:svc"

register_ast_methods :: proc(t: ^svc.Table) {
	svc.table_register(t, svc.METHOD_AST_PARSE, handle_ast_parse)
	svc.table_register(t, svc.METHOD_AST_QUERY, handle_ast_query)
}

handle_ast_parse :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	lang, err := file_require_str(ctx, params, "lang")
	if err != nil {
		return nil, err
	}
	code, cerr := file_present_str(ctx, params, "code")
	if cerr != nil {
		return nil, cerr
	}
	max_chars := 0
	if v, p, e := file_opt_int(ctx, params, "max_answer_chars"); e != nil {
		return nil, e
	} else if p {
		max_chars = v
	}

	sexpr, perr := svc.ast_parse(code, lang, max_chars, ctx.allocator)
	if perr != nil {
		return nil, perr
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "sexpr", jsonutil.json_string(sexpr))
	return json.Value(json.Object(out)), nil
}

handle_ast_query :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	lang, err := file_require_str(ctx, params, "lang")
	if err != nil {
		return nil, err
	}
	code, cerr := file_present_str(ctx, params, "code")
	if cerr != nil {
		return nil, cerr
	}
	query, qerr := file_require_str(ctx, params, "query")
	if qerr != nil {
		return nil, qerr
	}

	matches, merr := svc.ast_query(code, lang, query, ctx.allocator)
	if merr != nil {
		return nil, merr
	}
	items := make([]json.Value, len(matches), ctx.allocator)
	for i in 0..<len(matches) {
		m := matches[i]
		caps := make([]json.Value, len(m.captures), ctx.allocator)
		for j in 0..<len(m.captures) {
			c := m.captures[j]
			cobj := jsonutil.json_object(4, ctx.allocator)
			jsonutil.obj_set(&cobj, "name", jsonutil.json_string(c.name))
			jsonutil.obj_set(&cobj, "text", jsonutil.json_string(c.text))
			jsonutil.obj_set(&cobj, "start_byte", jsonutil.json_int(i64(c.start_byte)))
			jsonutil.obj_set(&cobj, "end_byte", jsonutil.json_int(i64(c.end_byte)))
			caps[j] = json.Value(json.Object(cobj))
		}
		mobj := jsonutil.json_object(2, ctx.allocator)
		jsonutil.obj_set(&mobj, "pattern", jsonutil.json_int(i64(m.pattern_index)))
		jsonutil.obj_set(&mobj, "captures", jsonutil.json_array(caps, ctx.allocator))
		items[i] = json.Value(json.Object(mobj))
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "matches", jsonutil.json_array(items, ctx.allocator))
	return json.Value(json.Object(out)), nil
}
