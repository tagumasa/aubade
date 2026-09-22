// `aubade memory` — the CLI-level memory family: listing, reading,
// writing, referential-integrity checks (mem: references whose target
// does not exist), and the heuristic auto-prefixer that rewrites bare
// occurrences of known memory names into mem: references. The CLI
// builds the same Memory_Files view the daemon serves (config-merged
// read-only/ignored patterns, resolved roots) and works without a
// running daemon — files are the source of truth.
package cli

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sort"
import "core:strings"

import "src:config"
import "src:memory"
import "src:platform"
import "src:regex"
import "src:svc"
import "src:util"

MEMORY_SUBCOMMANDS :: []Sub_Cmd_Entry{
	{name = "list",           run = memories_list_cmd},
	{name = "show",           run = memories_read_cmd},
	{name = "write",          run = memories_write_cmd},
	{name = "check",          run = memories_check_cmd},
	{name = "fix-references", run = memories_autoprefix_cmd},
}

run_memories_cmd :: proc(args: []string, g: ^Globals, version: string) -> int {
	return run_subcommands("memory", MEMORY_SUBCOMMANDS, args, g)
}

// memories_open_global opens the memory files for a command; a
// global-only listing with no project selection opens just the global
// tree instead of demanding a project.
memories_open_global :: proc(cmd: string, g: ^Globals, global_only: bool) -> (^svc.Memory_Files, int) {
	if global_only && g.project == "" && !g.project_from_cwd {
		home := platform.aubade_home(context.temp_allocator)
		mf := new(svc.Memory_Files, context.allocator)
		svc.memory_files_global_only(mf, home, context.allocator)
		return mf, 0
	}
	return memories_open(cmd, g)
}

// memories_open builds the CLI's Memory_Files view: the same merged
// read-only/ignored pattern resolution the daemon applies (global lists
// first, project lists appended).
memories_open :: proc(cmd: string, g: ^Globals) -> (^svc.Memory_Files, int) {
	root, code := resolve_project_root(cmd, g)
	if code != 0 {
		return nil, code
	}
	home := platform.aubade_home(context.temp_allocator)
	mf := new(svc.Memory_Files, context.allocator)
	{
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena, context.allocator)
		// Block scope: the arena dies at the brace, after init cloned
		// everything it keeps.
		defer mem.dynamic_arena_destroy(&arena)
		a := mem.dynamic_arena_allocator(&arena)
		ro: []string
		ig: []string
		if global, _, gerr := config.load_global(home, a); gerr == nil {
			ro = global.shared.read_only_memory_patterns
			ig = global.shared.ignored_memory_patterns
		}
		if project, _, perr := config.load_project_for_root(root, home, a); perr == nil {
			ro = config.stack_merged_strings(ro, project.shared.read_only_memory_patterns, a)
			ig = config.stack_merged_strings(ig, project.shared.ignored_memory_patterns, a)
		}
		svc.memory_files_init(mf, root, home, ro, ig, context.allocator)
	}
	return mf, 0
}

memories_close :: proc(mf: ^svc.Memory_Files) {
	svc.memory_files_destroy(mf)
	free(mf)
}

// --- list / read / write ------------------------------------------------------

memories_list_cmd :: proc(args: []string, g: ^Globals) -> int {
	topic := ""
	global_only := false
	i := 0
	for i < len(args) {
		if val, ok, code := tracker_flag_str("memory list", args, "--topic", &i); ok {
			if code != 0 {
				return code
			}
			topic = val
			continue
		}
		if args[i] == "--global" {
			global_only = true
			i += 1
			continue
		}
		return usage_error("memory list", strings.concatenate({"unknown flag \"", args[i], "\""}, context.temp_allocator))
	}
	if global_only {
		topic = memory.GLOBAL_TOPIC
	}

	// A global-only listing needs no project roots (--global):
	// open just the global tree.
	mf, code := memories_open_global("memory list", g, global_only)
	if code != 0 {
		return code
	}
	defer memories_close(mf)

	list, lerr := svc.memory_list(mf, topic, context.temp_allocator)
	defer memory.memories_list_destroy(&list)
	if lerr != nil {
		return usage_error("memory list", strings.concatenate(
			{"invalid topic \"", topic, "\": empty segments and '.'/'..' are not allowed"},
			context.temp_allocator,
		))
	}
	if len(list.memories) + len(list.read_only_memories) == 0 {
		fmt.println("No memories found.")
		return 0
	}
	header := "Memories"
	if global_only {
		header = "Global memories"
	}
	fmt.printf("%s (%d):\n", header, len(list.memories) + len(list.read_only_memories))
	all := make([dynamic]string, 0, 16, context.temp_allocator)
	for m in list.memories {
		append(&all, m)
	}
	for m in list.read_only_memories {
		append(&all, m)
	}
	ro_set := make(map[string]bool, len(list.read_only_memories), context.temp_allocator)
	for m in list.read_only_memories {
		ro_set[m] = true
	}
	sort.quick_sort(all[:])
	for name in all {
		marker := " "
		if ro_set[name] {
			marker = "r"
		}
		fmt.printf("  [%s] %s\n", marker, name)
	}
	return 0
}

memories_read_cmd :: proc(args: []string, g: ^Globals) -> int {
	name, code := memories_single_name("memory show", args)
	if code != 0 {
		return code
	}
	mf, ocode := memories_open("memory show", g)
	if ocode != 0 {
		return ocode
	}
	defer memories_close(mf)

	content, found, rerr := svc.memory_load(mf, name, context.temp_allocator)
	if rerr != nil {
		fmt.eprintf("aubade memory show: %s\n", platform.err_message(rerr, context.temp_allocator))
		return 1
	}
	if !found {
		fmt.eprintf("aubade memory show: memory %q not found\n", name)
		return 1
	}
	fmt.print(content)
	if !strings.has_suffix(content, "\n") {
		fmt.println()
	}
	return 0
}

memories_write_cmd :: proc(args: []string, g: ^Globals) -> int {
	pos := make([dynamic]string, 0, 1, context.temp_allocator)
	content := ""
	content_file := ""
	i := 0
	for i < len(args) {
		if val, ok, code := tracker_flag_str("memory write", args, "--content", &i); ok {
			if code != 0 {
				return code
			}
			content = val
			continue
		}
		if val, ok, code := tracker_flag_str("memory write", args, "--file", &i); ok {
			if code != 0 {
				return code
			}
			content_file = val
			continue
		}
		if !strings.has_prefix(args[i], "-") {
			append(&pos, args[i])
			i += 1
			continue
		}
		return usage_error("memory write", strings.concatenate({"unknown flag \"", args[i], "\""}, context.temp_allocator))
	}
	if len(pos) != 1 {
		return usage_error("memory write", "exactly one memory name is required")
	}
	name := pos[0]

	body := content
	if body == "" && content_file != "" {
		loaded, merr := memory_file_body(content_file, context.temp_allocator)
		if merr != "" {
			return usage_error("memory write", merr)
		}
		body = loaded
	}
	if body == "" {
		loaded, sok := stdin_read_all(context.temp_allocator, memory.MAX_MEMORY_READ_BYTES)
		if !sok {
			return usage_error("memory write", strings.concatenate(
				{"stdin input exceeds the memory size limit (", util.int_to_dec(memory.MAX_MEMORY_READ_BYTES, context.temp_allocator), " bytes)"},
				context.temp_allocator,
			))
		}
		body = loaded
	}

	mf, code := memories_open("memory write", g)
	if code != 0 {
		return code
	}
	defer memories_close(mf)

	if werr := svc.memory_save(mf, name, body, context.temp_allocator); werr != nil {
		fmt.eprintf("aubade memory write: %s\n", platform.err_message(werr, context.temp_allocator))
		return 1
	}
	fmt.printf("Memory %q written (%d bytes).\n", name, len(body))
	return 0
}

// memory_file_body loads a --file payload under the same bounds the read
// side enforces (memory.MAX_MEMORY_READ_BYTES, regular files only — the
// same stat_kind_size gate memory_load uses). A payload past the cap could
// be saved but never read back, and a device or FIFO would grow the read
// without EOF; both are refused. err is "" on success and a usage message
// otherwise, both on a.
memory_file_body :: proc(path: string, a: mem.Allocator) -> (body: string, err: string) {
	kind, size, sok := util.stat_kind_size(path)
	if !sok {
		return "", strings.concatenate({"cannot read --file: ", path}, a)
	}
	if kind != .Regular {
		return "", strings.concatenate({"--file is not a regular file: ", path}, a)
	}
	if size > memory.MAX_MEMORY_READ_BYTES {
		return "", strings.concatenate(
			{"--file is too large (", util.int_to_dec(cast(int)size, a),
				" bytes); maximum is ", util.int_to_dec(memory.MAX_MEMORY_READ_BYTES, a), " bytes"},
			a,
		)
	}
	data, rerr := os.read_entire_file_from_path(path, a)
	if rerr != nil {
		return "", strings.concatenate({"cannot read --file: ", path}, a)
	}
	return string(data), ""
}

// stdin_read_all drains stdin up to limit bytes; ok=false means the input
// ran past the limit and must be refused, not truncated (memory content is
// never silently cut).
stdin_read_all :: proc(a: mem.Allocator, limit: int) -> (string, bool) {
	buf := make([dynamic]u8, 0, 8192, a)
	tmp: [8192]u8
	for {
		n, rerr := os.read(os.stdin, tmp[:])
		if n > 0 {
			append(&buf, ..tmp[:n])
		}
		if len(buf) > limit {
			delete(buf)
			return "", false
		}
		if rerr != nil || n == 0 {
			break
		}
	}
	return string(buf[:]), true
}

memories_single_name :: proc(cmd: string, args: []string) -> (string, int) {
	pos := make([dynamic]string, 0, 1, context.temp_allocator)
	i := 0
	for i < len(args) {
		if !strings.has_prefix(args[i], "-") {
			append(&pos, args[i])
			i += 1
			continue
		}
		return "", usage_error(cmd, strings.concatenate({"unknown flag \"", args[i], "\""}, context.temp_allocator))
	}
	if len(pos) != 1 {
		return "", usage_error(cmd, "exactly one memory name is required")
	}
	return pos[0], 0
}

// --- reference integrity ------------------------------------------------------

// Memory_Ref is one unresolved mem: reference (the check output row).
Memory_Ref :: struct {
	from: string,
	to:   string,
	line: int,
}

// memories_check_refs scans every memory for mem:<name> references
// whose target is not a known memory. Results sort by from, then line.
memories_check_refs :: proc(mf: ^svc.Memory_Files, a: mem.Allocator) -> []Memory_Ref {
	list, _ := svc.memory_list(mf, "", a) // the empty topic cannot fail validation
	defer memory.memories_list_destroy(&list)
	known := make(map[string]bool, len(list.memories) + len(list.read_only_memories), a)
	all := make([dynamic]string, 0, 16, a)
	for m in list.memories {
		known[m] = true
		append(&all, m)
	}
	for m in list.read_only_memories {
		known[m] = true
		append(&all, m)
	}
	sort.quick_sort(all[:])

	refs := make([dynamic]Memory_Ref, 0, 8, a)
	for name in all {
		content, found, lerr := svc.memory_load(mf, name, a)
		if lerr != nil || !found {
			continue
		}
		// Plain index loop: `for v, i in` binds value-then-index, and
		// the swapped reading once fed a byte value in as an index.
		line_num := 1
		line_start := 0
		for i := 0; i < len(content); i += 1 {
			if content[i] == '\n' {
				scan_ref_line(known, content[line_start:i], name, line_num, &refs, a)
				line_num += 1
				line_start = i + 1
			}
		}
		if line_start < len(content) {
			scan_ref_line(known, content[line_start:], name, line_num, &refs, a)
		}
	}
	delete(known)
	delete(all)
	return refs[:]
}

// scan_ref_line reports the unresolved references on one line. The
// extraction grammar: group 1 is the name, group 2 the boundary
// character (start < 0 marks an unset group).
scan_ref_line :: proc(
	known: map[string]bool,
	line: string,
	from: string,
	line_num: int,
	refs: ^[dynamic]Memory_Ref,
	a: mem.Allocator,
) {
	// Per-call compile on the caller's arena: a Regex belongs to its
	// using thread and is never cached across calls.
	re, cerr := regex.compile_regex("mem:([^\\s)\\]\"'`]+?)([^\\w/]|$)", a)
	if cerr != nil {
		return
	}
	defer regex.regex_destroy(&re)

	ms := regex.regex_find_all(&re, line, a)
	defer delete(ms, a)
	for m in ms {
		caps := regex.regex_captures_at(&re, line, m.start, a)
		// Group 1 is the name: caps[0] is the whole match, which would
		// drag the mem: prefix and the boundary character along and flag
		// every known reference as unknown.
		if len(caps) > 1 && caps[1].start >= 0 && caps[1].end > caps[1].start {
			ref_name := line[caps[1].start:caps[1].end]
			if !known[ref_name] {
				// Both fields are cloned: the listing the names came from is
				// destroyed at proc exit, but the refs escape it.
				append(refs, Memory_Ref{
					from = strings.clone(from, a),
					to   = strings.clone(ref_name, a),
					line = line_num,
				})
			}
		}
		delete(caps, a)
	}
}

memories_check_cmd :: proc(args: []string, g: ^Globals) -> int {
	if len(args) > 0 {
		return usage_error("memory check", strings.concatenate({"unknown flag \"", args[0], "\""}, context.temp_allocator))
	}
	mf, code := memories_open("memory check", g)
	if code != 0 {
		return code
	}
	defer memories_close(mf)

	refs := memories_check_refs(mf, context.temp_allocator)
	if len(refs) == 0 {
		fmt.println("No unresolved memory references found.")
		return 0
	}
	for r in refs {
		fmt.printf("%s:%d references unknown memory %q\n", r.from, r.line, r.to)
	}
	return 1
}

// --- auto-prefix ---------------------------------------------------------------

// memories_autoprefix rewrites bare whole-word occurrences of known
// memory names into mem: references (skipping ones already prefixed).
// Only writable, non-ignored memories are rewritten. dry_run reports
// without writing. Returns the number of modified memories.
memories_autoprefix :: proc(mf: ^svc.Memory_Files, dry_run: bool, a: mem.Allocator) -> int {
	list, _ := svc.memory_list(mf, "", a) // the empty topic cannot fail validation
	defer memory.memories_list_destroy(&list)
	all := make([dynamic]string, 0, 16, a)
	for m in list.memories {
		append(&all, m)
	}
	for m in list.read_only_memories {
		append(&all, m)
	}
	if len(all) == 0 {
		delete(all)
		return 0
	}
	sort.quick_sort(all[:])
	// Longest first so foo/bar wins over foo when both are known.
	ordered := make([dynamic]string, 0, len(all), a)
	for m in all {
		append(&ordered, m)
	}
	for i in 1..<len(ordered) {
		k := ordered[i]
		j := i - 1
		for j >= 0 && len(ordered[j]) < len(k) {
			ordered[j + 1] = ordered[j]
			j -= 1
		}
		ordered[j + 1] = k
	}

	pat_src := make([dynamic]u8, 0, 128, a)
	append(&pat_src, "\\b(")
	for n, i in ordered {
		if i > 0 {
			append(&pat_src, "|")
		}
		append(&pat_src, regex.quote_meta(n, a))
	}
	append(&pat_src, ")\\b")
	// Per-call compile (thread-owned Regex); freed before return.
	re, cerr := regex.compile_regex(string(pat_src[:]), a)
	if cerr != nil {
		delete(all)
		delete(ordered)
		delete(pat_src)
		return 0
	}
	defer regex.regex_destroy(&re)
	delete(pat_src)

	modified := 0
	for name in all {
		if svc.memory_check_not_ignored(mf, name, a) != nil {
			continue
		}
		content, found, lerr := svc.memory_load(mf, name, a)
		if lerr != nil || !found {
			continue
		}
		ms := regex.regex_find_all(&re, content, a)
		if len(ms) == 0 {
			delete(ms, a)
			continue
		}
		// Apply in reverse so earlier ranges stay valid as the string
		// grows; skip ranges already preceded by mem:.
		changes := 0
		out := content
		for i := len(ms) - 1; i >= 0; i -= 1 {
			m := ms[i]
			if m.start >= len(memory.REF_PREFIX) && out[m.start - len(memory.REF_PREFIX):m.start] == memory.REF_PREFIX {
				continue
			}
			out = strings.concatenate({out[:m.start], memory.REF_PREFIX, out[m.start:]}, a)
			changes += 1
		}
		delete(ms, a)
		if changes == 0 {
			continue
		}
		if dry_run {
			modified += 1
			continue
		}
		if svc.memory_save(mf, name, out, a) == nil {
			modified += 1
		}
	}
	delete(all)
	delete(ordered)
	return modified
}

memories_autoprefix_cmd :: proc(args: []string, g: ^Globals) -> int {
	dry_run := false
	i := 0
	for i < len(args) {
		if args[i] == "--dry-run" {
			dry_run = true
			i += 1
			continue
		}
		return usage_error("memory fix-references", strings.concatenate({"unknown flag \"", args[i], "\""}, context.temp_allocator))
	}

	mf, code := memories_open("memory fix-references", g)
	if code != 0 {
		return code
	}
	defer memories_close(mf)

	refs := memories_check_refs(mf, context.temp_allocator)
	if dry_run {
		if len(refs) == 0 {
			fmt.println("Dry run: no references to consider.")
		}
		for r in refs {
			fmt.printf("would review %s:%d (%q)\n", r.from, r.line, r.to)
		}
		return 0
	}
	n := memories_autoprefix(mf, false, context.temp_allocator)
	fmt.printf("Added mem: prefixes in %d memories.\n", n)
	return 0
}
