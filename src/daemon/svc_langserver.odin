// The svc.langserver/* lifecycle handlers: control over the project's
// language-server manager. start/stop/restart/reload are mutating — they
// spawn or stop processes every child of this daemon shares, so read-only
// sessions are refused at the boundary; list is a plain read.
//
// The request handlers (diagnostics/code_actions/format/inlay_hints/
// call_hierarchy) resolve the file's server through the shared LSP port
// (starting one on demand), open the document, and forward one request
// — the same per-call ensure semantics every LSP read uses.
package daemon

import "core:encoding/json"
import "core:mem"
import "core:strings"

import "src:jsonutil"
import "src:langserver"
import "src:lsp"
import "src:platform"
import "src:svc"
import "src:util"

register_langserver_methods :: proc(t: ^svc.Table) {
	svc.table_register_mutating(t, svc.METHOD_LANGSERVER_START, handle_langserver_start)
	svc.table_register_mutating(t, svc.METHOD_LANGSERVER_STOP, handle_langserver_stop)
	svc.table_register_mutating(t, svc.METHOD_LANGSERVER_RESTART, handle_langserver_restart)
	svc.table_register_mutating(t, svc.METHOD_LANGSERVER_RELOAD, handle_langserver_reload)
	svc.table_register(t, svc.METHOD_LANGSERVER_LIST, handle_langserver_list)
	svc.table_register(t, svc.METHOD_LANGSERVER_DIAGNOSTICS, handle_langserver_diagnostics)
	svc.table_register(t, svc.METHOD_LANGSERVER_CODE_ACTIONS, handle_langserver_code_actions)
	svc.table_register(t, svc.METHOD_LANGSERVER_FORMAT, handle_langserver_format)
	svc.table_register(t, svc.METHOD_LANGSERVER_INLAY_HINTS, handle_langserver_inlay_hints)
	svc.table_register(t, svc.METHOD_LANGSERVER_CALL_HIERARCHY, handle_langserver_call_hierarchy)
}

handle_langserver_start :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	lang, err := file_require_str(ctx, params, "language")
	if err != nil {
		return nil, err
	}
	if langserver.registry_find(d.ls_reg, lang) == nil {
		return nil, svc.wrapped_err(
			.NotFound,
			strings.concatenate({"no language server is registered for language: ", lang}, ctx.allocator),
			ctx.allocator,
		)
	}
	if serr := langserver.manager_start(d.ls, lang, ctx.allocator, ctx.token); serr != nil {
		return nil, serr
	}
	return svc.langserver_result(ctx.allocator), nil
}

handle_langserver_stop :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	lang, err := file_require_str(ctx, params, "language")
	if err != nil {
		return nil, err
	}
	if serr := langserver.manager_stop(d.ls, lang, ctx.token); serr != nil {
		// A bare NotFound (the manager's never-started refusal) reads
		// better with the language named; wrapped errors (cooldown,
		// install hints) pass through with their own context.
		if serr == platform.Err(.NotFound) {
			return nil, svc.wrapped_err(
				.NotFound,
				strings.concatenate({"no running language server for language: ", lang}, ctx.allocator),
				ctx.allocator,
			)
		}
		return nil, serr
	}
	return svc.langserver_result(ctx.allocator), nil
}

handle_langserver_restart :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	lang, present, err := file_opt_str(ctx, params, "language")
	if err != nil {
		return nil, err
	}
	if present && lang != "" {
		// Per-language restart: the manager builds the replacement,
		// swaps it in, and only then stops the old server — a failed
		// build leaves the running one alone.
		if langserver.registry_find(d.ls_reg, lang) == nil {
			return nil, svc.wrapped_err(
				.NotFound,
				strings.concatenate({"no language server is registered for language: ", lang}, ctx.allocator),
				ctx.allocator,
			)
		}
		if rerr := langserver.manager_restart(d.ls, lang, ctx.allocator, ctx.token); rerr != nil {
			return nil, rerr
		}
		return svc.langserver_result(ctx.allocator), nil
	}
	// No language: cold reset of the whole manager — each language
	// rebuilds its server on its next use. manager_reset, not
	// manager_stop_all: the shutdown flag would refuse every later start
	// for the daemon's lifetime. (An Odin-side surface: the base tool
	// set has start/stop/list only, with no restart tool — the
	// per-language branch above runs the stop+start sequence in one
	// step.)
	langserver.manager_reset(d.ls, ctx.token)
	return svc.langserver_result(ctx.allocator), nil
}

// apply_language_settings re-reads the language-server settings from disk
// and swaps them into the live manager: a cold reset first (servers
// started under the old config do not survive it), then the allowlist,
// command overrides, options, and folder seeds swap, then eager start
// re-runs for the new allowlist. A config load failure changes nothing —
// the refusal is fail-closed. Shared by the langserver/reload method and
// the config write path (config_set/config_delete applying live keys).
apply_language_settings :: proc(
	d:     ^Daemon,
	token: ^platform.Cancel_Token,
	arena: mem.Allocator,
) -> (applied: int, stopped: int, err: platform.Err) {
	allow, overrides, options, _, seeds, lerr := resolve_language_settings(d)
	if lerr != nil {
		return 0, 0, svc.wrapped_err(
			.Invalid,
			strings.concatenate(
				{"language server settings were not applied: ", platform.err_message(lerr, arena)},
				arena,
			),
			arena,
		)
	}
	applied = len(overrides)
	stopped = langserver.manager_reset(d.ls, token)
	langserver.manager_set_allow(d.ls, allow)
	langserver.free_strings(allow, d.allocator)
	langserver.manager_set_overrides(d.ls, overrides)
	langserver.free_string_array_map(overrides, d.allocator)
	langserver.manager_set_options(d.ls, options)
	langserver.free_string_map(options, d.allocator)
	langserver.manager_set_seeds(d.ls, seeds)
	langserver.free_strings(seeds, d.allocator)
	langserver.manager_start_eager(d.ls, token)
	return applied, stopped, nil
}

// handle_langserver_reload re-reads the language-server settings from
// disk and applies them to the live manager (see apply_language_settings;
// a config load failure changes nothing — the refusal is fail-closed).
// The reload's scope is the language-server subsystem only; read_only and
// editor settings stay fixed at daemon start.
handle_langserver_reload :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	applied, stopped, err := apply_language_settings(d, ctx.token, ctx.allocator)
	if err != nil {
		return nil, err
	}
	out := jsonutil.json_object(2, ctx.allocator)
	jsonutil.obj_set(&out, "overrides", jsonutil.json_int(i64(applied)))
	jsonutil.obj_set(&out, "stopped", jsonutil.json_int(i64(stopped)))
	return json.Value(json.Object(out)), nil
}

handle_langserver_list :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	rows := langserver.manager_status(d.ls, ctx.allocator)

	// The list shows configured-or-running languages. With no
	// allowlist the manager falls back to the whole registry; keep only
	// the running rows in that case so an unconfigured project reads as
	// empty (the hint below) instead of dozens of not-running entries.
	// The flag goes through the manager's mutex — set_allow frees the old
	// slice after a reload swap, and this handler can race one.
	configured := langserver.manager_allow_configured(d.ls)
	n := 0
	for row in rows {
		if configured || row.running {
			rows[n] = row
			n += 1
		}
	}
	rows = rows[:n]

	out := jsonutil.json_object(1, ctx.allocator)
	if len(rows) == 0 {
		jsonutil.obj_set(&out, "message", jsonutil.json_string(svc.LANGSERVER_EMPTY_HINT))
		return json.Value(json.Object(out)), nil
	}
	items := make([]json.Value, len(rows), ctx.allocator)
	for i in 0..<len(rows) {
		entry := jsonutil.json_object(5, ctx.allocator)
		jsonutil.obj_set(&entry, "language", jsonutil.json_string(rows[i].id))
		jsonutil.obj_set(&entry, "running", jsonutil.json_bool(rows[i].running))
		jsonutil.obj_set(&entry, "folders", jsonutil.json_int(i64(rows[i].folders)))
		if rows[i].root != "" {
			jsonutil.obj_set(&entry, "root", jsonutil.json_string(rows[i].root))
		}
		// The registry's degradation note (e.g. ols without a collections
		// config drops cross-package references) — surfaced on the row so
		// the silent degradation the note describes becomes visible.
		if note := langserver.manager_config_note(d.ls, rows[i].id, rows[i].root, ctx.allocator); note != "" {
			jsonutil.obj_set(&entry, "note", jsonutil.json_string(note))
		}
		items[i] = json.Value(json.Object(entry))
	}
	jsonutil.obj_set(&out, "items", jsonutil.json_array(items, ctx.allocator))
	return json.Value(json.Object(out)), nil
}

// langserver_open resolves the file's server and opens the document for
// a request handler (the daemon's shared LSP port, editor view, and
// project root).
langserver_open :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (svc.Langserver_Doc, platform.Err) {
	d := cast(^Daemon)ctx.user
	rel, err := file_require_str(ctx, params, "relative_path")
	if err != nil {
		return {}, err
	}
	return svc.langserver_open_document(daemon_lsp_client_for, d.lsp_port, d.ed, d.cfg.project_root, rel, ctx.allocator, ctx.token, daemon_lsp_client_release)
}

handle_langserver_diagnostics :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	doc, derr := langserver_open(ctx, params)
	if derr != nil {
		return nil, derr
	}
	defer svc.langserver_doc_release(doc)

	// Pull only from a server that advertises diagnosticProvider: one that
	// never declared it (gopls) owes no useful textDocument/diagnostic
	// answer, and an always-pull first rendered its empty reply as a clean
	// file while the stored push diagnostics held real errors. The store is
	// the source whenever the pull did not authoritatively answer — the
	// server never declared pull support, or its request failed.
	items: json.Value = nil
	pulled := false
	if lsp.client_caps(doc.client).document_diagnostic {
		perr: platform.Err
		items, perr = lsp.request_document_diagnostic(doc.client, doc.uri, ctx.allocator, ctx.token)
		if perr != nil {
			items = nil
		} else {
			pulled = true
		}
	}
	if !pulled {
		if stored, ok := lsp.diagnostics_store_get(&doc.client.diagnostics, doc.uri, ctx.allocator); ok {
			parsed, parse_err := json.parse_string(stored, spec = .JSON, parse_integers = true, allocator = ctx.allocator)
			if parse_err == nil {
				items = parsed
			}
		}
	}

	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "items", svc.langserver_diagnostics_json(items, ctx.allocator))
	return json.Value(json.Object(out)), nil
}

handle_langserver_code_actions :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	sl, p1, e1 := file_opt_int(ctx, params, "start_line")
	if e1 != nil {
		return nil, e1
	}
	sc, p2, e2 := file_opt_int(ctx, params, "start_col")
	if e2 != nil {
		return nil, e2
	}
	el, p3, e3 := file_opt_int(ctx, params, "end_line")
	if e3 != nil {
		return nil, e3
	}
	ec, p4, e4 := file_opt_int(ctx, params, "end_col")
	if e4 != nil {
		return nil, e4
	}
	if !p1 || !p2 || !p3 || !p4 {
		return nil, svc.wrapped_err(.Invalid, "start_line, start_col, end_line, and end_col are required", ctx.allocator)
	}

	doc, derr := langserver_open(ctx, params)
	if derr != nil {
		return nil, derr
	}
	defer svc.langserver_doc_release(doc)

	// The stored diagnostics ride along as the action context ("" sends
	// an empty context); the reply is the raw heterogeneous array.
	stored, _ := lsp.diagnostics_store_get(&doc.client.diagnostics, doc.uri, ctx.allocator)
	raw, aerr := lsp.request_code_actions(doc.client, doc.uri, sl, sc, el, ec, stored, ctx.allocator, ctx.token)
	if aerr != nil {
		return nil, aerr
	}

	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "items", svc.langserver_code_actions_json(raw, d.cfg.project_root, ctx.allocator))
	return json.Value(json.Object(out)), nil
}

handle_langserver_format :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	doc, derr := langserver_open(ctx, params)
	if derr != nil {
		return nil, derr
	}
	defer svc.langserver_doc_release(doc)
	tab_size := 4
	if v, p, e := file_opt_int(ctx, params, "tab_size"); e != nil {
		return nil, e
	} else if p && v > 0 {
		tab_size = v
	}
	insert_spaces := true
	if v, p, e := file_opt_bool(ctx, params, "insert_spaces"); e != nil {
		return nil, e
	} else if p {
		insert_spaces = v
	}

	edits, ferr := lsp.request_formatting(doc.client, doc.uri, tab_size, insert_spaces, ctx.allocator, ctx.token)
	if ferr != nil {
		return nil, ferr
	}

	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "items", svc.langserver_text_edits_json(edits, ctx.allocator))
	return json.Value(json.Object(out)), nil
}

handle_langserver_inlay_hints :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	sl, p1, e1 := file_opt_int(ctx, params, "start_line")
	if e1 != nil {
		return nil, e1
	}
	sc, p2, e2 := file_opt_int(ctx, params, "start_col")
	if e2 != nil {
		return nil, e2
	}
	el, p3, e3 := file_opt_int(ctx, params, "end_line")
	if e3 != nil {
		return nil, e3
	}
	ec, p4, e4 := file_opt_int(ctx, params, "end_col")
	if e4 != nil {
		return nil, e4
	}
	if !p1 || !p2 || !p3 || !p4 {
		return nil, svc.wrapped_err(.Invalid, "start_line, start_col, end_line, and end_col are required", ctx.allocator)
	}

	doc, derr := langserver_open(ctx, params)
	if derr != nil {
		return nil, derr
	}
	defer svc.langserver_doc_release(doc)

	hints, herr := lsp.request_inlay_hints(doc.client, doc.uri, sl, sc, el, ec, ctx.allocator, ctx.token)
	if herr != nil {
		return nil, herr
	}

	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "items", svc.langserver_inlay_hints_json(hints, ctx.allocator))
	return json.Value(json.Object(out)), nil
}

handle_langserver_call_hierarchy :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	line, p1, e1 := file_opt_int(ctx, params, "line")
	if e1 != nil {
		return nil, e1
	}
	col, p2, e2 := file_opt_int(ctx, params, "col")
	if e2 != nil {
		return nil, e2
	}
	if !p1 || !p2 {
		return nil, svc.wrapped_err(.Invalid, "line and col are required", ctx.allocator)
	}
	direction, derr2 := file_require_str(ctx, params, "direction")
	if derr2 != nil {
		return nil, derr2
	}
	dir, dok := lsp.call_direction_from_string(direction)
	if !dok {
		return nil, svc.wrapped_err(
			.Invalid,
			strings.concatenate(
				{"invalid direction: must be ", util.quoted_join(lsp.CALL_DIRECTION_NAMES, " or ", "\"", ctx.allocator)},
				ctx.allocator,
			),
			ctx.allocator,
		)
	}

	doc, derr := langserver_open(ctx, params)
	if derr != nil {
		return nil, derr
	}
	defer svc.langserver_doc_release(doc)

	items, perr := lsp.request_prepare_call_hierarchy(doc.client, doc.uri, line, col, ctx.allocator, ctx.token)
	if perr != nil {
		return nil, perr
	}
	edges := make([dynamic]lsp.Call_Edge, 0, 8, ctx.allocator)
	for item in items {
		if dir == .Incoming {
			batch, berr := lsp.request_incoming_calls(doc.client, item, ctx.allocator, ctx.token)
			if berr != nil {
				delete(edges)
				return nil, berr
			}
			for edge in batch {
				append(&edges, edge)
			}
		} else {
			batch, berr := lsp.request_outgoing_calls(doc.client, item, ctx.allocator, ctx.token)
			if berr != nil {
				delete(edges)
				return nil, berr
			}
			for edge in batch {
				append(&edges, edge)
			}
		}
	}

	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "items", svc.langserver_call_edges_json(edges[:], ctx.allocator))
	return json.Value(json.Object(out)), nil
}
