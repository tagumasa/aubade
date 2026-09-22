// Glob helpers: brace expansion, glob → regex translation, and
// single-glob matching over a caller-owned cache (nil compiles per call
// — no production caller caches today).
package regex

import "core:mem"
import "core:strings"
import "src:util"


// expand_braces expands brace alternatives ("foo.{ts,js}" → both), looping
// until no group remains (nested braces expand one level per pass). Pure
// temp scratch: the returned patterns and every intermediate string live
// on context.temp_allocator, so nothing here is caller-owned and the proc
// is safe to call from any allocator context.
expand_braces :: proc(pattern: string) -> []string {
	ta := context.temp_allocator
	patterns := make([dynamic]string, 0, 4, ta)
	append(&patterns, pattern)

	for {
		expanded := false
		next := make([dynamic]string, 0, len(patterns) * 2, ta)
		for p in patterns {
			s, e, found := first_brace_group(p)
			if !found {
				append(&next, p)
				continue
			}
			expanded = true
			prefix := p[:s]
			suffix := p[e + 1:]
			options := strings.split(p[s + 1:e], ",", ta)
			for opt in options {
				merged := strings.concatenate({prefix, opt, suffix}, ta)
				append(&next, merged)
			}
		}
		delete(patterns)
		patterns = next
		if !expanded {
			break
		}
	}
	return patterns[:]
}


// glob_append appends raw bytes; glob_append_quoted appends one
// metachar-escaped byte (single-file helpers — Odin has no closures).
glob_append :: proc(buf: ^[dynamic]u8, s: string) {
	append(buf, s)
}

glob_append_quoted :: proc(buf: ^[dynamic]u8, c: u8) {
	switch c {
	case '.', '+', '*', '?', '(', ')', '|', '[', ']', '{', '}', '^', '$', '\\':
		append(buf, '\\')
	case:
	}
	append(buf, c)
}

// first_brace_group finds the leftmost brace pair with no nested braces —
// the plain-string equivalent of matching `\{([^{}]+)\}`.
first_brace_group :: proc(p: string) -> (start: int, end: int, found: bool) {
	for i in 0..<len(p) {
		if p[i] != '{' {
			continue
		}
		j := i + 1
		for j < len(p) {
			if p[j] == '{' {
				break // nested: this opener cannot close cleanly
			}
			if p[j] == '}' {
				if j > i + 1 {
					return i, j, true
				}
				break // empty group {}: skip this opener
			}
			j += 1
		}
	}
	return 0, 0, false
}

// glob_to_regex translates a glob (*, **, ?, [seq], {braces}, backslash
// escapes) into a regex string. Anchoring is the caller's concern. The
// result is allocated on `a` and owned by the caller: free it with
// delete(result, a), or let the owning arena die.
glob_to_regex :: proc(glob_pat: string, a := context.allocator) -> string {
	buf := make([dynamic]u8, 0, len(glob_pat) + 16, a)

	i := 0
	for i < len(glob_pat) {
		ch := glob_pat[i]
		if ch == '*' && i + 1 < len(glob_pat) && glob_pat[i + 1] == '*' {
			if i + 2 < len(glob_pat) && glob_pat[i + 2] == '/' {
				glob_append(&buf, "(?:.*/)?")
				i += 3
			} else {
				glob_append(&buf, ".*")
				i += 2
			}
		} else if ch == '*' {
			glob_append(&buf, "[^/]*")
			i += 1
		} else if ch == '?' {
			glob_append(&buf, "[^/]")
			i += 1
		} else if ch == '[' {
			j := i + 1
			for j < len(glob_pat) {
				if glob_pat[j] == '\\' && j + 1 < len(glob_pat) {
					j += 2
					continue
				}
				if glob_pat[j] == ']' {
					break
				}
				j += 1
			}
			if j >= len(glob_pat) || glob_pat[j] != ']' {
				glob_append(&buf, "\\[")
				i += 1
			} else {
				append(&buf, '[')
				i += 1
				if i < len(glob_pat) && glob_pat[i] == '!' {
					append(&buf, '^')
					i += 1
				}
				for i < len(glob_pat) && glob_pat[i] != ']' {
					if glob_pat[i] == '\\' && i + 1 < len(glob_pat) {
						append(&buf, glob_pat[i])
						append(&buf, glob_pat[i + 1])
						i += 2
					} else {
						append(&buf, glob_pat[i])
						i += 1
					}
				}
				if i < len(glob_pat) && glob_pat[i] == ']' {
					append(&buf, ']')
					i += 1
				}
			}
		} else if ch == '{' {
			depth := 1
			j := i + 1
			for j < len(glob_pat) && depth > 0 {
				if glob_pat[j] == '\\' && j + 1 < len(glob_pat) {
					j += 2
					continue
				}
				if glob_pat[j] == '{' {
					depth += 1
				} else if glob_pat[j] == '}' {
					depth -= 1
				}
				j += 1
			}
			if depth > 0 {
				glob_append(&buf, "\\{")
				i += 1
			} else {
				glob_append(&buf, "(?:")
				i += 1
				brace_depth := 1
				for i < len(glob_pat) && brace_depth > 0 {
					if glob_pat[i] == '{' {
						brace_depth += 1
					} else if glob_pat[i] == '}' {
						brace_depth -= 1
						if brace_depth == 0 {
							break
						}
					}
					if glob_pat[i] == '\\' && i + 1 < len(glob_pat) {
						glob_append_quoted(&buf, glob_pat[i + 1])
						i += 2
					} else if glob_pat[i] == ',' && brace_depth == 1 {
						glob_append(&buf, "|")
						i += 1
					} else {
						glob_append_quoted(&buf, glob_pat[i])
						i += 1
					}
				}
				if i < len(glob_pat) && glob_pat[i] == '}' {
					glob_append(&buf, ")")
					i += 1
				}
			}
		} else if ch == '\\' {
			if i + 1 < len(glob_pat) {
				i += 1
				glob_append_quoted(&buf, glob_pat[i])
			} else {
				glob_append(&buf, "\\\\")
			}
			i += 1
		} else {
			glob_append_quoted(&buf, ch)
			i += 1
		}
	}
	res := string(buf[:])
	buf = nil // the bytes are now owned by the result on `a`
	return res
}

// glob_match matches a path against a glob (backslashes normalize to
// slashes; braces expand; ** crosses directory separators). cache may be
// nil — then every pattern compiles fresh.
glob_match :: proc(pattern: string, path: string, cache: ^util.Bounded_Cache(string, Regex)) -> bool {
	norm_pattern, _ := strings.replace_all(pattern, "\\", "/", context.temp_allocator)
	norm_path, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)

	patterns := expand_braces(norm_pattern)
	for p in patterns {
		if glob_match_single(p, norm_path, cache) {
			return true
		}
	}
	return false
}

glob_match_single :: proc(pattern: string, path: string, cache: ^util.Bounded_Cache(string, Regex)) -> bool {
	if !strings.contains(pattern, "**") {
		return simple_glob_match(pattern, path, cache)
	}
	if simple_glob_match(pattern, path, cache) {
		return true
	}
	if strings.contains(pattern, "/**/") {
		zero_dir, _ := strings.replace_all(pattern, "/**/", "/", context.temp_allocator)
		if simple_glob_match(zero_dir, path, cache) {
			return true
		}
	}
	if strings.has_prefix(pattern, "**/") {
		zero_dir := pattern[3:]
		if simple_glob_match(zero_dir, path, cache) {
			return true
		}
	}
	return false
}

simple_glob_match :: proc(pattern: string, path: string, cache: ^util.Bounded_Cache(string, Regex)) -> bool {
	if cache != nil {
		// The cached Regex points into PCRE2 memory the cache may free on
		// a concurrent put or eviction — cache_get only lends. Pin the
		// entry across the match (the hot-tree acquire discipline) and
		// match through a call-local buffer: the cache shares the Regex
		// across threads, and its own match_data serves one thread at a
		// time (regex_match_local).
		if util.cache_pin(cache, pattern) {
			if re, ok := util.cache_get(cache, pattern); ok {
				matched := regex_match_local(&re, path)
				util.cache_unpin(cache, pattern)
				return matched
			}
			util.cache_unpin(cache, pattern)
		}
	}
	anchored := strings.concatenate(
		{"^", glob_to_regex(pattern, context.temp_allocator), "$"},
		context.temp_allocator,
	)
	// A cached regex lives for the cache's lifetime: it must be compiled
	// on the cache's allocator, never the ambient temp — a temp-backed
	// entry dangles after the calling thread's scratch reset. An
	// uncached compile is use-and-destroy scratch and stays on temp.
	compile_alloc := context.temp_allocator
	if cache != nil {
		compile_alloc = cache.allocator
	}
	re, err := compile_regex(anchored, compile_alloc)
	if err != nil {
		return false
	}
	if cache != nil {
		// The match runs on our exclusively-owned regex; ownership of the
		// compiled regex transfers to the cache's release hook only on a
		// successful put — no defer here (it would free a regex the cache
		// still holds, and defer fires at block scope, not just proc
		// return). A refused put means a concurrent reader pinned the
		// pattern's entry after this compile started: the cached regex
		// wins, ours served this one match and is freed here. Build the
		// cache through glob_cache_init — it wires the key hooks
		// (patterns arrive from brace expansion on scratch) and the regex
		// release hook.
		matched := regex_match(&re, path)
		if !util.cache_put(cache, pattern, re) {
			regex_destroy(&re)
		}
		return matched
	}
	defer regex_destroy(&re)
	return regex_match(&re, path)
}

// glob_cache_init wires a Bounded_Cache for compiled globs: keys are
// cloned on insert (glob patterns reach the cache off brace expansion on
// scratch allocators — the stored key must not borrow them), and evicted
// values release their compiled regex.
glob_cache_init :: proc(c: ^util.Bounded_Cache(string, Regex), max_entries: int, a := context.allocator) {
	util.cache_init(c, max_entries, a, regex_cache_release, 0, nil, glob_key_clone, glob_key_release)
}

glob_key_clone :: proc(k: string, a: mem.Allocator) -> string {
	return strings.clone(k, a)
}

glob_key_release :: proc(k: string, a: mem.Allocator) {
	delete(k, a)
}

// regex_cache_release frees a cached compiled regex (Bounded_Cache hook).
regex_cache_release :: proc(re: Regex) {
	r := re
	regex_destroy(&r)
}


