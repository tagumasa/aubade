// The svc.web/* handlers: the web family's parent side. The fetcher and
// searcher are built once per daemon from the global web config; a failed
// construction (bad proxy, unparsable whitelist, no search provider)
// leaves that half nil and its method refuses — the daemon stays up.
package daemon

import "core:encoding/json"
import "core:mem"
import "core:strings"

import "src:config"
import "src:jsonutil"
import "src:platform"
import "src:safety"
import "src:svc"
import "src:util"
import "src:web"

register_web_methods :: proc(t: ^svc.Table) {
	svc.table_register(t, svc.METHOD_WEB_FETCH, handle_web_fetch)
	svc.table_register(t, svc.METHOD_WEB_SEARCH, handle_web_search)
}

// web_for_project builds the daemon-owned web state: the fetcher (always,
// unless its transport cannot exist) and the searcher (only when a
// provider is configured). The URL guard starts from the default safety
// rules and then merges the blocked_url_patterns lists (global then
// project — concatenation, the same merge the shell guard uses).
web_for_project :: proc(d: ^Daemon) -> (fetcher: ^web.Fetcher, searcher: ^web.Searcher, checker: ^safety.Safety_Checker) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, d.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	global, _, gerr := config.load_global(d.cfg.home, a)
	wc: config.Web_Config
	if gerr == nil {
		wc = global.web
	}
	patterns := make([dynamic]string, 0, 4, a)
	if gerr == nil {
		for p in global.shared.blocked_url_patterns {
			append(&patterns, p)
		}
	} else {
		util.log_warning("web safety: global config unreadable; default URL rules only")
	}
	project, _, perr := config.load_project_for_root(d.cfg.project_root, d.cfg.home, a)
	if perr == nil {
		for p in project.shared.blocked_url_patterns {
			append(&patterns, p)
		}
	}

	checker = new(safety.Safety_Checker, d.allocator)
	safety.safety_checker_init(checker, d.allocator)
	// One bad regex warns and is skipped: it must not take the guard down
	// (the shell guard's feed shares the stance).
	for pat in patterns {
		if ok, why := safety.urlguard_add_blocked_pattern(&checker.url_guard, pat, "blocked by config"); !ok {
			util.log_warning(strings.concatenate(
				{"invalid blocked_url_patterns entry: ", why},
				context.temp_allocator,
			))
		}
	}

	f := new(web.Fetcher, d.allocator)
	fok, bad := web.fetcher_init(
		f,
		wc.fetch_proxy,
		"markdown",
		wc.fetch_limit_bytes,
		wc.whitelist_hosts,
		checker,
		wc.allow_private_hosts,
		d.allocator,
	)
	if fok {
		fetcher = f
	} else {
		if bad != "" {
			util.log_warning(strings.concatenate({
				"web fetcher construction failed: invalid whitelist entry ", bad,
			}, context.temp_allocator))
		} else {
			util.log_warning("web fetcher construction failed; web_fetch will refuse")
		}
		web.fetcher_destroy(f)
		free(f, d.allocator)
	}

	opts := web.search_options_from_config(&wc, a)
	s := new(web.Searcher, d.allocator)
	sok, sbad := web.searcher_init(s, opts, d.allocator)
	if sok {
		searcher = s
	} else {
		if sbad != "" {
			util.log_warning(strings.concatenate({
				"web searcher construction failed: invalid whitelist entry ", sbad,
			}, context.temp_allocator))
		} else {
			util.log_info("no web search provider configured; web_search will refuse")
		}
		web.searcher_destroy(s)
		free(s, d.allocator)
	}
	return fetcher, searcher, checker
}

web_state_destroy :: proc(d: ^Daemon) {
	if d.fetcher != nil {
		web.fetcher_destroy(d.fetcher)
		free(d.fetcher, d.allocator)
		d.fetcher = nil
	}
	if d.searcher != nil {
		web.searcher_destroy(d.searcher)
		free(d.searcher, d.allocator)
		d.searcher = nil
	}
	if d.web_safety != nil {
		safety.safety_checker_destroy(d.web_safety)
		free(d.web_safety, d.allocator)
		d.web_safety = nil
	}
}

handle_web_fetch :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	if d.fetcher == nil {
		return nil, platform.Wrapped{
			kind = .Terminated,
			msg  = "web fetch is not configured",
		}
	}
	url, uerr := file_require_str(ctx, params, "url")
	if uerr != nil {
		return nil, uerr
	}
	max_chars := 0
	if val, present, ierr := file_opt_int(ctx, params, "max_chars"); ierr != nil {
		return nil, ierr
	} else if present {
		max_chars = val
	}
	text, ferr_kind, ferr := web.fetcher_fetch(d.fetcher, url, max_chars, ctx.token, ctx.allocator)
	if ferr_kind != .None {
		return nil, svc.wrapped_err(web.web_err_platform_kind(ferr_kind), ferr, ctx.allocator)
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "text", jsonutil.json_string(text))
	return json.Value(json.Object(out)), nil
}

handle_web_search :: proc(ctx: ^svc.Svc_Ctx, params: json.Value) -> (json.Value, platform.Err) {
	d := cast(^Daemon)ctx.user
	if d.searcher == nil {
		return nil, platform.Wrapped{
			kind = .Terminated,
			msg  = "search provider is not configured",
		}
	}
	query, qerr := file_require_str(ctx, params, "query")
	if qerr != nil {
		return nil, qerr
	}
	count := 0
	if val, present, ierr := file_opt_int(ctx, params, "count"); ierr != nil {
		return nil, ierr
	} else if present {
		count = val
	}
	range_code, _, rerr := file_opt_str(ctx, params, "range")
	if rerr != nil {
		return nil, rerr
	}
	text, serr_kind, serr := web.searcher_search(d.searcher, query, count, range_code, ctx.token, ctx.allocator)
	if serr_kind != .None {
		return nil, svc.wrapped_err(web.web_err_platform_kind(serr_kind), serr, ctx.allocator)
	}
	out := jsonutil.json_object(1, ctx.allocator)
	jsonutil.obj_set(&out, "text", jsonutil.json_string(text))
	return json.Value(json.Object(out)), nil
}
