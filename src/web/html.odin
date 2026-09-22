// HTML to markdown conversion over the lexbor parse tree: emphasis
// buffers with empty-content skipping, headers/lists/pre/blockquote
// structure, readability-style dropping of nav/footer/aside-classed
// subtrees, safe href/src filtering, and post-processing cleanups.
package web

import "core:mem"
import "core:strings"

import "src:regex"
import "src:util"

HTML_SKIP_TAGS :: []string{
	"script", "style", "head", "noscript", "template",
	"nav", "footer", "aside", "header", "form", "dialog",
}

HTML_UNLIKELY_KEYWORDS :: []string{
	"menu", "nav", "footer", "sidebar", "cookie", "banner", "sponsor",
	"advert", "popup", "modal", "newsletter", "share", "social",
}

Converter :: struct {
	stack:      [dynamic]strings.Builder,
	link_hrefs: [dynamic]string,
	link_open:  [dynamic]bool,
	emph:       [dynamic]string,
	ol_counters: [dynamic]int,
	in_pre:     bool,
	list_depth: int,
	allocator:  mem.Allocator,
}

// html_to_markdown parses the document and renders its readable content
// as markdown. The whole conversion — parse tree, walk buffers, and the
// post-processing regex chain — runs on a scratch arena freed before the
// procedure returns, so the intermediates (pop buffers, concatenations,
// regex replacements, lowercased tokens) never depend on the caller's
// allocation discipline; the caller receives the single result string
// owned by `a`. `post` supplies fetcher-owned compiled patterns; nil
// compiles them per call.
html_to_markdown :: proc(html_src: string, a := context.allocator, post: ^Html_Post_Procs = nil) -> (string, bool) {
	// An empty document is empty markdown — a real parse of zero bytes has
	// no body element and must not be an error.
	if html_src == "" {
		return "", true
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, a)
	scratch := mem.dynamic_arena_allocator(&arena)

	// Scope both ambient allocators to the scratch arena for the walk:
	// helpers that default to context.allocator (to_lower, repeat, split)
	// land there too instead of leaving unowned strings behind.
	saved_allocator := context.allocator
	saved_temp := context.temp_allocator
	context.allocator = scratch
	context.temp_allocator = scratch
	defer {
		context.allocator = saved_allocator
		context.temp_allocator = saved_temp
	}
	defer mem.dynamic_arena_destroy(&arena)

	doc, body, ok := lxb_parse_one(html_src)
	if !ok {
		return "", false
	}
	defer lxb_document_destroy(doc)

	c: Converter
	c.allocator = scratch
	c.stack = make([dynamic]strings.Builder, 0, 8, scratch)
	cb := strings.builder_make_len_cap(0, 4096, scratch)
	append(&c.stack, cb)

	html_walk(&c, body)

	md := html_post_process(strings.to_string(c.stack[0]), scratch, post)
	return strings.clone(md, a), true
}

// --- walk --------------------------------------------------------------------

Walk_Frame :: struct {
	node:    ^LXB_Dom_Node,
	is_exit: bool,
}

html_walk :: proc(c: ^Converter, root: ^LXB_Dom_Node) {
	a := c.allocator
	frames := make([dynamic]Walk_Frame, 0, 64, a)
	defer delete(frames)
	root_frame: Walk_Frame
	root_frame.node = root
	append(&frames, root_frame)

	for len(frames) > 0 {
		frame := pop(&frames)

		node := frame.node
		if frame.is_exit {
			html_exit_element(c, node)
			continue
		}

		if node == nil {
			continue
		}

		if node.type_ == LXB_NODE_ELEMENT {
			tag := lxb_node_tag(node, context.temp_allocator)
			if html_skip_tag(tag) || html_unlikely_node(node) {
				continue
			}
		}

		if node.type_ == LXB_NODE_TEXT {
			text := lxb_node_text(node)
			if !c.in_pre {
				collapsed := html_collapse_text(text, context.temp_allocator)
				if collapsed != "" {
					html_write(c, collapsed)
				}
			} else if text != "" {
				html_write(c, text)
			}
			continue
		}

		if node.type_ != LXB_NODE_ELEMENT {
			html_push_children(c, &frames, node)
			continue
		}

		skip_children := html_enter_element(c, node)
		if !skip_children {
			exit_frame: Walk_Frame
			exit_frame.node = node
			exit_frame.is_exit = true
			append(&frames, exit_frame)
			html_push_children(c, &frames, node)
		}
	}
}

html_push_children :: proc(c: ^Converter, frames: ^[dynamic]Walk_Frame, node: ^LXB_Dom_Node) {
	// Push in reverse so the first child pops first.
	child := lxb_last_child(node)
	if child == nil {
		return
	}
	children := make([dynamic]^LXB_Dom_Node, 0, 8, c.allocator)
	defer delete(children)
	for n := child; n != nil; n = lxb_prev(n) {
		append(&children, n)
	}
	for i := 0; i < len(children); i += 1 {
		f: Walk_Frame
		f.node = children[i]
		append(frames, f)
	}
}

lxb_last_child :: proc(node: ^LXB_Dom_Node) -> ^LXB_Dom_Node {
	return node.last_child
}

html_skip_tag :: proc(tag: string) -> bool {
	for t in HTML_SKIP_TAGS {
		if tag == t {
			return true
		}
	}
	return false
}

// html_unlikely_node drops subtrees whose class/id tokens smell like
// chrome (menus, banners, share bars) unless a content-ish token
// (article/main/content) vouches for them.
html_unlikely_node :: proc(node: ^LXB_Dom_Node) -> bool {
	// One lowercase+trim per attribute value: the token matcher used to
	// re-lower its input for every keyword probe (~26 passes per element).
	class_lower := strings.to_lower(strings.trim_space(html_attr(node, "class", context.temp_allocator)), context.temp_allocator)
	id_lower := strings.to_lower(strings.trim_space(html_attr(node, "id", context.temp_allocator)), context.temp_allocator)
	if css_tokens_any(class_lower, "article", "main", "content") ||
	   css_tokens_any(id_lower, "article", "main", "content") {
		return false
	}
	for kw in HTML_UNLIKELY_KEYWORDS {
		if css_tokens_any(class_lower, kw) || css_tokens_any(id_lower, kw) {
			return true
		}
	}
	return false
}

// css_tokens_any reports whether any whitespace/-/_ separated token of the
// already-lowercased `s` equals one of the keywords.
css_tokens_any :: proc(s: string, keywords: ..string) -> bool {
	lower := s
	if lower == "" {
		return false
	}
	// Split on whitespace, then on '-' and '_' inside each token.
	i := 0
	for i < len(lower) {
		for i < len(lower) && is_css_space(lower[i]) {
			i += 1
		}
		start := i
		for i < len(lower) && !is_css_space(lower[i]) {
			i += 1
		}
		if i > start {
			token := lower[start:i]
			part_start := 0
			for j := 0; j <= len(token); j += 1 {
				if j == len(token) || token[j] == '-' || token[j] == '_' {
					part := token[part_start:j]
					for kw in keywords {
						if part == kw {
							return true
						}
					}
					part_start = j + 1
				}
			}
		}
	}
	return false
}

is_css_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
}

// html_attr reads one attribute's value (empty when absent).
html_attr :: proc(node: ^LXB_Dom_Node, key: string, a := context.allocator) -> string {
	attr := lxb_first_attribute(node)
	for attr != nil {
		name, value := lxb_attr_pair(attr)
		if strings.to_lower(strings.trim_space(name)) == key {
			return strings.clone(value, a)
		}
		attr = lxb_next_attribute(attr)
	}
	return ""
}

html_collapse_text :: proc(text: string, a := context.allocator) -> string {
	out := make([dynamic]u8, 0, len(text), a)
	defer delete(out)
	prev_space := false
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if c == '\n' {
			c = ' '
		}
		if c == ' ' || c == '\t' {
			if prev_space {
				continue
			}
			prev_space = true
			append(&out, ' ')
			continue
		}
		prev_space = false
		append(&out, c)
	}
	res := strings.clone(transmute(string)(out[:]), a)
	return res
}

// --- element enter/exit ------------------------------------------------------

html_write :: proc(c: ^Converter, s: string) {
	strings.write_string(&c.stack[len(c.stack) - 1], s)
}

html_push_buf :: proc(c: ^Converter) {
	b := strings.builder_make_len_cap(0, 256, c.allocator)
	append(&c.stack, b)
}

html_pop_buf :: proc(c: ^Converter) -> string {
	top := c.stack[len(c.stack) - 1]
	s := strings.clone(strings.to_string(top), c.allocator)
	strings.builder_destroy(&top)
	_ = pop(&c.stack)
	return s
}

html_enter_element :: proc(c: ^Converter, node: ^LXB_Dom_Node) -> bool {
	tag := lxb_node_tag(node, context.temp_allocator)
	switch tag {
	case "b", "strong":
		append(&c.emph, "**")
		html_push_buf(c)
	case "i", "em":
		append(&c.emph, "*")
		html_push_buf(c)
	case "del", "s":
		append(&c.emph, "~~")
		html_push_buf(c)

	case "a":
		href := normalize_attr(html_attr(node, "href", context.temp_allocator))
		if href != "" && !is_safe_href(href) {
			href = "#"
		}
		has_href := href != ""
		append(&c.link_open, has_href)
		if has_href {
			append(&c.link_hrefs, href)
			html_push_buf(c)
		}

	case "h1": html_write(c, "\n\n# ")
	case "h2": html_write(c, "\n\n## ")
	case "h3": html_write(c, "\n\n### ")
	case "h4": html_write(c, "\n\n#### ")
	case "h5": html_write(c, "\n\n##### ")
	case "h6": html_write(c, "\n\n###### ")

	case "p":  html_write(c, "\n\n")
	case "br": html_write(c, "\n")
	case "hr": html_write(c, "\n\n---\n\n")

	case "ol":
		append(&c.ol_counters, 1)
		if c.list_depth == 0 {
			html_write(c, "\n")
		}
		c.list_depth += 1
	case "ul":
		if c.list_depth == 0 {
			html_write(c, "\n")
		}
		c.list_depth += 1
	case "li":
		html_write(c, "\n")
		if c.list_depth > 1 {
			indent := strings.repeat("    ", c.list_depth - 1)
			html_write(c, indent)
		}
		parent := node.parent
		if parent != nil && lxb_node_tag(parent, context.temp_allocator) == "ol" && len(c.ol_counters) > 0 {
			idx := c.ol_counters[len(c.ol_counters) - 1]
			num := util.int_to_dec(idx, context.temp_allocator)
			html_write(c, num)
			html_write(c, ". ")
			c.ol_counters[len(c.ol_counters) - 1] += 1
		} else {
			html_write(c, "- ")
		}

	case "pre":
		c.in_pre = true
		html_write(c, "\n\n```\n")
	case "code":
		if !c.in_pre {
			html_write(c, "`")
		}

	case "blockquote":
		html_push_buf(c)

	case "img":
		src := normalize_attr(html_attr(node, "src", context.temp_allocator))
		if src == "" {
			src = normalize_attr(html_attr(node, "data-src", context.temp_allocator))
		}
		if src == "" {
			return true // skip children
		}
		alt := escape_md_alt(normalize_attr(html_attr(node, "alt", context.temp_allocator)), c.allocator)
		if is_safe_image_src(src) {
			html_write(c, strings.concatenate({"![", alt, "](", src, ")"}, c.allocator))
		}
		return true
	}
	return false
}

html_exit_element :: proc(c: ^Converter, node: ^LXB_Dom_Node) {
	tag := lxb_node_tag(node, context.temp_allocator)
	switch tag {
	case "b", "strong", "i", "em", "del", "s":
		if len(c.emph) == 0 {
			return
		}
		marker := c.emph[len(c.emph) - 1]
		_ = pop(&c.emph)
		inner := strings.trim_space(html_pop_buf(c))
		if inner != "" {
			html_write(c, strings.concatenate({marker, inner, marker}, c.allocator))
		}

	case "a":
		if len(c.link_open) == 0 {
			return
		}
		has_href := c.link_open[len(c.link_open) - 1]
		_ = pop(&c.link_open)
		if !has_href {
			return
		}
		href := c.link_hrefs[len(c.link_hrefs) - 1]
		_ = pop(&c.link_hrefs)
		inner := strings.trim_space(html_pop_buf(c))
		if strings.contains(inner, "\n") {
			// Link only the first non-empty, non-image line.
			out := make([dynamic]u8, 0, len(inner) + 16, c.allocator)
			linked := false
			line_start := 0
			for i := 0; i <= len(inner); i += 1 {
				if i == len(inner) || inner[i] == '\n' {
					line := strings.trim_space(inner[line_start:i])
					if line != "" && !strings.has_prefix(line, "![") && !linked {
						// Byte-index copy: `for ch in` iterates runes and would
						// truncate multi-byte UTF-8 link text.
						linked_line := strings.concatenate({"[", line, "](", href, ")"}, c.allocator)
						for j in 0..<len(linked_line) {
							append(&out, linked_line[j])
						}
						linked = true
					} else {
						for j in 0..<len(line) {
							append(&out, line[j])
						}
					}
					if i != len(inner) {
						append(&out, '\n')
					}
					line_start = i + 1
				}
			}
			html_write(c, transmute(string)(out[:]))
			delete(out)
		} else {
			html_write(c, strings.concatenate({"[", inner, "](", href, ")"}, c.allocator))
		}

	case "h1", "h2", "h3", "h4", "h5", "h6",
	     "p", "div", "section", "article", "header", "footer", "aside", "nav", "figure":
		html_write(c, "\n")

	case "ol":
		c.list_depth -= 1
		if c.list_depth < 0 {
			c.list_depth = 0
		}
		if len(c.ol_counters) > 0 {
			_ = pop(&c.ol_counters)
		}
		if c.list_depth == 0 {
			html_write(c, "\n")
		}
	case "ul":
		c.list_depth -= 1
		if c.list_depth < 0 {
			c.list_depth = 0
		}
		if c.list_depth == 0 {
			html_write(c, "\n")
		}

	case "pre":
		c.in_pre = false
		html_write(c, "\n```\n\n")
	case "code":
		if !c.in_pre {
			html_write(c, "`")
		}

	case "blockquote":
		inner := strings.trim_space(html_pop_buf(c))
		quoted := make([dynamic]string, 0, 8, c.allocator)
		defer delete(quoted)
		line_start := 0
		for i := 0; i <= len(inner); i += 1 {
			if i == len(inner) || inner[i] == '\n' {
				line := inner[line_start:i]
				if strings.trim_space(line) == "" {
					append(&quoted, ">")
				} else {
					append(&quoted, strings.concatenate({"> ", line}, c.allocator))
				}
				line_start = i + 1
			}
		}
		deduped := make([dynamic]string, 0, len(quoted), c.allocator)
		defer delete(deduped)
		for i := 0; i < len(quoted); i += 1 {
			if quoted[i] == ">" && i > 0 && len(deduped) > 0 && deduped[len(deduped) - 1] == ">" {
				continue
			}
			append(&deduped, quoted[i])
		}
		joined, _ := strings.join(deduped[:], "\n", c.allocator)
		html_write(c, strings.concatenate({"\n\n", joined, "\n\n"}, c.allocator))
	}
}

normalize_attr :: proc(val: string) -> string {
	out := make([dynamic]u8, 0, len(val), context.temp_allocator)
	for i := 0; i < len(val); i += 1 {
		c := val[i]
		if c == '\n' || c == '\r' || c == '\t' {
			continue
		}
		append(&out, c)
	}
	res := strings.trim_space(transmute(string)(out[:]))
	return res
}

is_safe_href :: proc(href: string) -> bool {
	lower := strings.to_lower(strings.trim_space(href))
	if strings.has_prefix(lower, "javascript:") ||
	   strings.has_prefix(lower, "vbscript:") ||
	   strings.has_prefix(lower, "data:") {
		return false
	}
	// No scheme, or http/https/mailto only.
	if !strings.contains(lower, ":") {
		return true
	}
	if strings.has_prefix(lower, "http:") || strings.has_prefix(lower, "https:") ||
	   strings.has_prefix(lower, "mailto:") {
		return true
	}
	return false
}

is_safe_image_src :: proc(src: string) -> bool {
	lower := strings.to_lower(strings.trim_space(src))
	if strings.has_prefix(lower, "data:image/") {
		return true
	}
	return is_safe_href(src)
}

escape_md_alt :: proc(s: string, a := context.allocator) -> string {
	out := make([dynamic]u8, 0, len(s) + 8, a)
	defer delete(out)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch c {
		case '\\', '[', ']':
			append(&out, '\\')
		}
		append(&out, c)
	}
	return strings.clone(transmute(string)(out[:]), a)
}

// --- post-processing ---------------------------------------------------------

// The five post-processing patterns, compiled once by the Fetcher and
// reused across conversions — a per-call compile + JIT was pure setup cost
// on every web_fetch. Hostless callers (tests, direct html_to_markdown
// use) pass nil and get the per-call compile-destroy path.
Html_Post_Procs :: struct {
	re_image_link:   regex.Regex,
	re_empty_item:   regex.Regex,
	re_empty_header: regex.Regex,
	re_blank:        regex.Regex,
	re_lead_space:   regex.Regex,
}

html_post_procs_init :: proc(p: ^Html_Post_Procs, a := context.allocator) -> bool {
	re_image_link, e1 := regex.compile_regex(`\[!\[\]\(<[^>]*>\)\]\(<[^>]*>\)`, a)
	re_empty_item, e2 := regex.compile_regex(`(?m)^[-*][ \t]*$`, a)
	re_empty_header, e3 := regex.compile_regex(`(?m)^#{1,6}[ \t]*$`, a)
	re_blank, e4 := regex.compile_regex(`\n{3,}`, a)
	re_lead_space, e5 := regex.compile_regex(`(?m)^([ \t])([^ \t\n])`, a)
	p.re_image_link = re_image_link
	p.re_empty_item = re_empty_item
	p.re_empty_header = re_empty_header
	p.re_blank = re_blank
	p.re_lead_space = re_lead_space
	if e1 != nil || e2 != nil || e3 != nil || e4 != nil || e5 != nil {
		html_post_procs_destroy(p) // destroy tolerates zeroed Regex values
		return false
	}
	return true
}

html_post_procs_destroy :: proc(p: ^Html_Post_Procs) {
	regex.regex_destroy(&p.re_image_link)
	regex.regex_destroy(&p.re_empty_item)
	regex.regex_destroy(&p.re_empty_header)
	regex.regex_destroy(&p.re_blank)
	regex.regex_destroy(&p.re_lead_space)
}

html_post_process :: proc(res: string, a := context.allocator, post: ^Html_Post_Procs = nil) -> string {
	out := res

	// Parameters are immutable — copy into a local to point it at the
	// per-call fallback set. The fallback's destroy defer sits at
	// PROCEDURE scope: a block-scoped defer would fire at the `if` exit,
	// destroying the regexes before the passes below run (destroy zeroes
	// them, and every replace then silently no-ops).
	procs := post
	local: Html_Post_Procs
	owns_local := false
	if procs == nil {
		if !html_post_procs_init(&local, a) {
			return strings.clone(out, a)
		}
		procs = &local
		owns_local = true
	}
	defer if owns_local {
		html_post_procs_destroy(&local)
	}

	out = regex.regex_replace_all(&procs.re_image_link, out, "", a)
	out = regex.regex_replace_all(&procs.re_empty_item, out, "", a)
	out = regex.regex_replace_all(&procs.re_empty_header, out, "", a)
	out = regex.regex_replace_all(&procs.re_blank, out, "\n\n", a)
	out = regex.regex_replace_all(&procs.re_lead_space, out, "$2", a)

	// Line-level cleanups: strip trailing spaces and neutralize the
	// leftover empty link/list artifacts.
	lines := strings.split(out, "\n")
	cleaned := make([dynamic]string, 0, len(lines), a)
	defer delete(cleaned)
	for i := 0; i < len(lines); i += 1 {
		line := strings.trim_right_space(lines[i])
		trimmed := strings.trim_space(line)
		if trimmed == "[](</>)" || trimmed == "[](#)" || trimmed == "-" {
			append(&cleaned, "")
			continue
		}
		append(&cleaned, strings.clone(line, a))
	}
	delete(lines)
	joined, _ := strings.join(cleaned[:], "\n", a)
	return strings.clone(strings.trim_space(joined), a)
}
