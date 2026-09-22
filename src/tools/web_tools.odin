// The web tools: URL fetch with content extraction and provider-backed
// web search. Both are optional (config-included) and need only the web
// capability — they serve any session whose parent link is live, with or
// without a project.
package tools

import "src:svc"

WEB_FETCH_PARAMS :: []Param_Desc{
	{name = "url", kind = .Str, description = "The URL to fetch (http or https).", required = true},
	{name = "max_chars", kind = .Int, description = "Optional cap on the extracted text length."},
}

WEB_SEARCH_RANGES :: []string{"d", "w", "m", "y"}

WEB_SEARCH_PARAMS :: []Param_Desc{
	{name = "query", kind = .Str, description = "The search query.", required = true},
	{name = "count", kind = .Int, description = "Number of results (1-10)."},
	{name = "range", kind = .Str, description = "Temporal range filter: d, w, m, or y.", enum_vals = WEB_SEARCH_RANGES},
}

web_fetch :: Tool_Desc{
	name        = "web_fetch",
	title       = "Fetch a URL",
	description = "Fetch a URL and extract readable content. Use this to retrieve web pages, articles, or API responses.",
	can_edit    = false,
	optional    = true,
	category    = .Web,
	params      = WEB_FETCH_PARAMS,
	needs       = {Cap.Web},
	apply       = web_fetch_apply,
}

web_search :: Tool_Desc{
	name        = "web_search",
	title       = "Search the web",
	description = "Search the web for current information. Supports query, count, and an optional temporal range filter.",
	can_edit    = false,
	optional    = true,
	category    = .Web,
	params      = WEB_SEARCH_PARAMS,
	needs       = {Cap.Web},
	apply       = web_search_apply,
}

// --- applies -----------------------------------------------------------------

web_fetch_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	url := arg_str(args, "url")
	if url == "" {
		return err_result(ctx, "url is required")
	}
	call := svc.client_web_fetch(
		ctx.svc_conn, url, arg_int(args, "max_chars"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	return text_result(ctx, call_text(call.result))
}

web_search_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	if !need_svc(ctx) {
		return err_result(ctx, "parent link unavailable")
	}
	query := arg_str(args, "query")
	if query == "" {
		return err_result(ctx, "query is required")
	}
	call := svc.client_web_search(
		ctx.svc_conn, query, arg_int(args, "count"), arg_str(args, "range"),
		ctx.allocator, svc_deadline(ctx), ctx.cancel,
	)
	if call.call_err != .None {
		return err_result_code(ctx, call.err_code, call.err_message)
	}
	return text_result(ctx, call_text(call.result))
}
