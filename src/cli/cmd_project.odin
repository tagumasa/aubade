// `aubade project` — the project management family: create (write-once
// config from the commented template, --language flags or the registry
// scan), list/remove (the machine-owned projects.json registry), index
// (the L0 symbol fill, parent-mediated — spawn the daemon if none is
// running; --file narrows to one file), check-ignore (the walk's
// gitignore predicate as a read-only question), and doctor (a health
// probe over config, the symbol pipeline, and the language-server
// registry through the same daemon link).
package cli

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "src:config"
import "src:daemon"
import "src:jsonrpc"
import "src:jsonutil"
import "src:langserver"
import "src:platform"
import "src:svc"

PROJECT_SUBCOMMANDS :: []Sub_Cmd_Entry{
	{name = "create",       run = project_create_cmd},
	{name = "list",         run = project_list_cmd},
	{name = "index",        run = project_index_cmd},
	{name = "delete",       run = project_remove_cmd},
	{name = "check-ignore", run = project_check_ignore_cmd},
	{name = "doctor",       run = project_doctor_cmd},
}

run_project_cmd :: proc(args: []string, g: ^Globals, version: string) -> int {
	return run_subcommands("project", PROJECT_SUBCOMMANDS, args, g)
}

project_create_cmd :: proc(args: []string, g: ^Globals) -> int {
	name := ""
	langs := make([dynamic]string, 0, 4, context.temp_allocator)
	do_index := false
	interactive := false
	path := g.project
	if path == "" {
		path = "."
	}
	i := 0
	for i < len(args) {
		if val, ok, code := tracker_flag_str("project create", args, "--name", &i); ok {
			if code != 0 {
				return code
			}
			name = val
			continue
		}
		if val, ok, code := tracker_flag_str("project create", args, "--language", &i); ok {
			if code != 0 {
				return code
			}
			append(&langs, val)
			continue
		}
		if args[i] == "--index" {
			do_index = true
			i += 1
			continue
		}
		if args[i] == "--interactive" {
			interactive = true
			i += 1
			continue
		}
		if !strings.has_prefix(args[i], "-") {
			path = args[i]
			i += 1
			continue
		}
		return usage_error("project create", strings.concatenate({"unknown flag \"", args[i], "\""}, context.temp_allocator))
	}

	root, root_code := project_root_for_create(path)
	if root_code != 0 {
		return root_code
	}
	home := platform.aubade_home(context.temp_allocator)
	_, gen_code := project_generate(root, home, name, langs[:], interactive)
	if gen_code != 0 {
		return gen_code
	}

	if do_index {
		fmt.println("Indexing project...")
		g.project = root
		return project_index_run(root, "", g)
	}
	return 0
}

// project_root_for_create resolves and validates the create target.
project_root_for_create :: proc(path: string) -> (string, int) {
	root, ok := platform.normalize_project_root(path, context.temp_allocator)
	if !ok {
		return "", usage_error("project create", strings.concatenate({"cannot resolve project path: ", path}, context.temp_allocator))
	}
	if !os.exists(root) {
		return "", usage_error("project create", strings.concatenate({"project path does not exist: ", root}, context.temp_allocator))
	}
	return root, 0
}

// project_generate writes the initial project config (write-once: an
// existing project.jsonc is never overwritten) and registers the root.
// The language list comes from `langs` or the registry's extension scan;
// every id must exist in the registry before anything is written.
project_generate :: proc(root, home, pname_in: string, langs: []string, interactive: bool) -> (string, int) {
	pname := pname_in
	reg := langserver.registry_build(context.temp_allocator)
	defer langserver.registry_destroy(reg)
	for l in langs {
		if langserver.registry_find(reg, l) == nil {
			return "", usage_error("project create", strings.concatenate(
				{"unknown language \"", l, "\""},
				context.temp_allocator,
			))
		}
	}

	global, _, gerr := config.load_global(home, context.temp_allocator)
	managed_location := ""
	if gerr == nil {
		managed_location = global.project_aubade_folder_location
	}
	managed := config.managed_dir_for(root, managed_location, context.temp_allocator)
	cfg_path := platform.project_config_path(managed, context.temp_allocator)
	if os.exists(cfg_path) {
		return "", usage_error("project create", strings.concatenate(
			{"project already exists: ", cfg_path, " already exists"},
			context.temp_allocator,
		))
	}

	scan_langs := make([dynamic]string, 0, 4, context.temp_allocator)
	effective := langs
	if len(effective) == 0 {
		scan := langserver.scan_project_languages(root, reg, context.temp_allocator)
		for id in scan.ids {
			append(&scan_langs, id)
		}
		effective = scan_langs[:]
		if interactive && len(effective) > 1 {
			effective = prompt_language_selection(effective, context.temp_allocator)
		}
	}

	if pname == "" {
		pname = filepath.base(root)
	}

	body := config.generate_project_config(pname, effective, context.temp_allocator)
	if mkerr := os.make_directory_all(managed, {.Read_User, .Write_User, .Execute_User}); mkerr != nil {
		fmt.eprintf("aubade project create: cannot create %s\n", managed)
		return "", 1
	}
	// Atomic publish with a checked write: a short write or IO error must
	// not leave a truncated (or zeroed) project.jsonc behind.
	if werr := platform.atomic_write(cfg_path, transmute([]u8)body, {.Read_User, .Write_User, .Read_Group, .Read_Other}); werr != nil {
		fmt.eprintf("aubade project create: cannot write %s\n", cfg_path)
		return "", 1
	}

	// Register the root in the machine-owned registry (idempotent; a
	// registration miss never fails the create).
	if reg_err := project_register(home, root); reg_err {
		fmt.eprintln("aubade project create: cannot update projects.json")
	}

	langs_str, _ := strings.join(effective, ", ", context.temp_allocator)
	if langs_str == "" {
		langs_str = "N/A"
	}
	// Plain concatenation: the '{' in a fmt format string would parse
	// as a parameter brace.
	fmt.println(strings.concatenate({"Generated project with languages {", langs_str, "} at ", cfg_path, "."}, context.temp_allocator))
	return cfg_path, 0
}

// prompt_language_selection asks, on stdin, which of the additionally
// detected languages to enable (the primary — the scan's top hit — stays
// enabled unconditionally). EOF answers every remaining prompt with the
// default "no", so a closed or empty stdin degrades to the primary-only
// choice instead of hanging; input past the reader's line budget behaves
// the same way. The returned slice is owned by `a`.
prompt_language_selection :: proc(detected: []string, a := context.allocator) -> []string {
	out := make([dynamic]string, 0, len(detected), a)
	append(&out, detected[0])
	if len(detected) == 1 {
		return out[:]
	}
	fmt.println()
	fmt.println(strings.concatenate({"Detected primary language: ", detected[0]}, a))
	fmt.printf("Additionally detected %d other language(s).\n", len(detected) - 1)
	fmt.println("Note: Enable only languages you need symbolic capabilities for.")
	fmt.println()
	fmt.println("Which additional languages do you want to enable?")
	reader := Line_Reader{buf = make([dynamic]u8, 0, 64, a)}
	defer delete(reader.buf)
	for lang in detected[1:] {
		fmt.printf("Enable %s? (y/N): ", lang)
		line, overflow := reader_next(&reader)
		if overflow {
			fmt.eprintln(
				"aubade project create: stdin input exceeds the 1 MiB line limit; remaining prompts use the default",
			)
			break
		}
		trimmed := strings.to_lower(strings.trim_space(line))
		if trimmed == "y" || trimmed == "yes" {
			append(&out, lang)
		}
	}
	return out[:]
}

// LINE_INPUT_LIMIT caps the bytes Line_Reader will carry for pending
// input — the same 1 MiB stdin budget `aubade hook` enforces. Past the
// budget without a newline the reader refuses to grow further instead of
// ballooning on a piped firehose.
LINE_INPUT_LIMIT :: 1 << 20

// Line_Reader hands out newline-terminated lines from stdin one at a
// time, carrying unread bytes across prompts (a piped stdin may deliver
// several answers in one read; a terminal delivers one line per read).
Line_Reader :: struct {
	buf:    [dynamic]u8,
	eof:    bool,
}

// reader_next returns the next line from stdin. overflow=true means the
// carried buffer passed LINE_INPUT_LIMIT without a newline: the reader
// stops consuming and the caller should fall back to its defaults (the
// same degradation EOF gets).
reader_next :: proc(r: ^Line_Reader) -> (line: string, overflow: bool) {
	for {
		next, found := reader_take_line(r)
		if found {
			return next, false
		}
		if r.eof {
			return "", false
		}
		if reader_over_budget(r) {
			r.eof = true
			return "", true
		}
		chunk: [256]u8
		n, rerr := os.read(os.stdin, chunk[:])
		if rerr != nil || n <= 0 {
			r.eof = true
			continue
		}
		append(&r.buf, ..chunk[:n])
	}
}

// reader_take_line returns the first complete line in the carried buffer
// (a trailing \r is dropped) and consumes it; found=false when no newline
// has arrived yet. At eof the remainder is handed back as the final line
// (possibly empty), and an empty buffer at eof reports found=false.
reader_take_line :: proc(r: ^Line_Reader) -> (line: string, found: bool) {
	for i in 0..<len(r.buf) {
		if r.buf[i] == '\n' {
			end := i
			if end > 0 && r.buf[end - 1] == '\r' {
				end -= 1
			}
			cloned := strings.clone(string(r.buf[:end]), r.buf.allocator)
			rest := len(r.buf) - (i + 1)
			for j in 0..<rest {
				r.buf[j] = r.buf[i + 1 + j]
			}
			resize(&r.buf, rest)
			return cloned, true
		}
	}
	if r.eof && len(r.buf) > 0 {
		cloned := strings.clone(string(r.buf[:]), r.buf.allocator)
		resize(&r.buf, 0)
		return cloned, true
	}
	return "", false
}

// reader_over_budget reports whether the carried buffer has reached the
// hard stdin budget with no complete line in it — the reader stops
// growing there.
reader_over_budget :: proc(r: ^Line_Reader) -> bool {
	return len(r.buf) >= LINE_INPUT_LIMIT
}

// project_register appends the root to projects.json when absent;
// returns true on failure (a registration miss never fails the create).
project_register :: proc(home: string, root: string) -> bool {
	entries, failed := registry_entries(home)
	defer delete(entries)
	if failed {
		return true
	}
	for p in entries {
		if strings.equal_fold(p, root) {
			return false
		}
	}
	append(&entries, root)
	return config.registry_save(home, entries[:]) != nil
}

// registry_entries loads the projects.json paths as an owned dynamic
// (empty when the registry is unreadable — callers always delete it). The
// entries and their strings ride the temp allocator: the registry they
// came from is destroyed at return, so the copies must not alias it.
registry_entries :: proc(home: string) -> (entries: [dynamic]string, failed: bool) {
	reg, err := config.registry_load(home, context.temp_allocator)
	if err != nil {
		return make([dynamic]string, 0, 0, context.temp_allocator), true
	}
	defer config.registry_destroy(reg, context.temp_allocator)
	out := make([dynamic]string, 0, len(reg.projects), context.temp_allocator)
	for p in reg.projects {
		append(&out, strings.clone(p, context.temp_allocator))
	}
	return out, false
}

// --- list / remove --------------------------------------------------------------

project_list_cmd :: proc(args: []string, g: ^Globals) -> int {
	if len(args) > 0 {
		return usage_error("project list", "takes no arguments")
	}
	home := platform.aubade_home(context.temp_allocator)
	entries, err := registry_entries(home)
	defer delete(entries)
	if err {
		fmt.eprintln("aubade project list: cannot read projects.json")
		return 1
	}
	if len(entries) == 0 {
		fmt.println("No projects registered.")
		return 0
	}
	max_name := 0
	for p in entries {
		if len(filepath.base(p)) > max_name {
			max_name = len(filepath.base(p))
		}
	}
	for p in entries {
		fmt.printf("%-*s  %s\n", max_name, filepath.base(p), p)
	}
	return 0
}

project_remove_cmd :: proc(args: []string, g: ^Globals) -> int {
	if len(args) != 1 {
		return usage_error("project delete", "requires exactly one project name or path")
	}
	home := platform.aubade_home(context.temp_allocator)
	entries, err := registry_entries(home)
	defer delete(entries)
	if err {
		fmt.eprintln("aubade project delete: cannot read projects.json")
		return 1
	}

	// Match by registry path or by its base name (the name `project
	// list` shows), case-insensitively like the rest of the path
	// handling.
	hit := -1
	for p, i in entries {
		if strings.equal_fold(p, args[0]) || strings.equal_fold(filepath.base(p), args[0]) {
			hit = i
			break
		}
	}
	if hit < 0 {
		fmt.eprintf("aubade project delete: project %q is not registered\n", args[0])
		return 1
	}
	kept := make([dynamic]string, 0, len(entries) - 1, context.temp_allocator)
	for p, i in entries {
		if i != hit {
			append(&kept, p)
		}
	}
	if serr := config.registry_save(home, kept[:]); serr != nil {
		fmt.eprintln("aubade project delete: cannot update projects.json")
		return 1
	}
	fmt.printf("Project %q removed.\n", entries[hit])
	return 0
}

// --- index (parent-mediated L0 fill) --------------------------------------------

project_index_cmd :: proc(args: []string, g: ^Globals) -> int {
	file := ""
	path := g.project // the global selection is the default target
	i := 0
	for i < len(args) {
		if val, ok, code := tracker_flag_str("project index", args, "--file", &i); ok {
			if code != 0 {
				return code
			}
			file = val
			continue
		}
		if !strings.has_prefix(args[i], "-") {
			path = args[i]
			i += 1
			continue
		}
		return usage_error("project index", strings.concatenate({"unknown flag \"", args[i], "\""}, context.temp_allocator))
	}
	if path == "" {
		return usage_error("project index", "a project path is required (--project or a positional path)")
	}

	root, ok := platform.normalize_project_root(path, context.temp_allocator)
	if !ok {
		return usage_error("project index", strings.concatenate({"cannot resolve project path: ", path}, context.temp_allocator))
	}
	if !os.exists(root) {
		return usage_error("project index", strings.concatenate({"project path does not exist: ", root}, context.temp_allocator))
	}

	home := platform.aubade_home(context.temp_allocator)
	if code := project_ensure_config(root, home); code != 0 {
		return code
	}
	return project_index_run(root, file, g)
}

// project_ensure_config auto-creates the project config when none exists
// (the same write-once generation `create` uses, scan-based).
project_ensure_config :: proc(root, home: string) -> int {
	global, _, gerr := config.load_global(home, context.temp_allocator)
	managed_location := ""
	if gerr == nil {
		managed_location = global.project_aubade_folder_location
	}
	managed := config.managed_dir_for(root, managed_location, context.temp_allocator)
	cfg_path := platform.project_config_path(managed, context.temp_allocator)
	if os.exists(cfg_path) {
		return 0
	}
	fmt.printf("No existing project found for %q. Attempting auto-creation …\n", root)
	_, code := project_generate(root, home, "", nil, false)
	if code == 0 {
		if reg_err := project_register(home, root); reg_err {
			fmt.eprintln("aubade project index: cannot update projects.json")
		}
	}
	return code
}

// project_index_run connects to the project daemon (spawning it when
// none is running), runs the crawl, and prints the summary. `within` is
// "" (whole project) or a project-relative file path.
project_index_run :: proc(root, within: string, g: ^Globals) -> int {
	g.project = root
	link, code := ensure_project_link("project index", g)
	if code != 0 {
		return code
	}
	// The banner precedes the crawl: a large project's fill can run for a
	// while, and a silent CLI reads as hung.
	if within != "" {
		fmt.printf("Indexing %s …\n", within)
	} else {
		fmt.printf("Indexing symbols in %s …\n", root)
	}
	summary, icode := index_summary(link.conn, within, context.temp_allocator)
	close_control(link)
	fmt.println(summary)
	return icode
}

// index_summary performs one svc.index/crawl and renders the stats line.
// Split from the connection plumbing so tests can drive it against a
// channel-transport daemon directly.
index_summary :: proc(conn: ^jsonrpc.Conn, within: string, a := context.allocator) -> (string, int) {
	call := svc.client_index_crawl(conn, within, a, platform.mono_ms() + 600_000)
	if call.call_err != .None {
		msg := call.err_message
		if msg == "" {
			msg = "svc call failed"
		}
		return strings.concatenate({"aubade project index: ", msg}, a), 1
	}
	stats, ok := jsonutil.obj_get(call.result, "stats")
	if !ok {
		return "aubade project index: daemon answered without stats", 1
	}
	files := svc_int(stats, "files_indexed")
	symbols := svc_int(stats, "symbols")
	ignored := svc_int(stats, "files_ignored")
	unsupported := svc_int(stats, "files_unsupported")
	failed := svc_int(stats, "files_failed")
	return fmt.aprintf(
		"Indexed %d files (%d symbols; %d ignored, %d unsupported, %d failed).",
		files, symbols, ignored, unsupported, failed,
		allocator = a,
	), 0
}

// --- check-ignore ----------------------------------------------------------------

project_check_ignore_cmd :: proc(args: []string, g: ^Globals) -> int {
	if len(args) != 1 {
		return usage_error("project check-ignore", "requires exactly one path")
	}
	root, code := resolve_project_root("project check-ignore", g)
	if code != 0 {
		return code
	}

	check := args[0]
	if os.is_absolute_path(check) {
		// Platform containment (case-folding, either separator): a
		// hand-built "root + \"/\"" prefix mis-refuses every Windows
		// backslash spelling of a path that IS under the root.
		rel, under := platform.strip_root_prefix(check, root)
		if !under {
			return usage_error("project check-ignore", strings.concatenate(
				{"path \"", check, "\" is outside the project root"},
				context.temp_allocator,
			))
		}
		check = rel
	}

	home := platform.aubade_home(context.temp_allocator)
	ignore := svc.ignore_config_load(root, home, context.temp_allocator)
	defer svc.spec_release_c_side(ignore.extra)
	ignored := svc.path_ignored(root, check, ignore, context.temp_allocator)
	if ignored {
		fmt.printf("Path %q IS ignored by the project configuration.\n", check)
	} else {
		fmt.printf("Path %q IS NOT ignored by the project configuration.\n", check)
	}
	return 0
}

// --- doctor ----------------------------------------------------------------------

project_doctor_cmd :: proc(args: []string, g: ^Globals) -> int {
	if len(args) > 1 {
		return usage_error("project doctor", "takes at most one project path")
	}
	path := g.project // the global selection is the default target
	if len(args) == 1 {
		path = args[0]
	}
	if path == "" {
		return usage_error("project doctor", "a project path is required (--project or a positional path)")
	}
	root, ok := platform.normalize_project_root(path, context.temp_allocator)
	if !ok {
		return usage_error("project doctor", strings.concatenate({"cannot resolve project path: ", path}, context.temp_allocator))
	}

	g.project = root
	link, code := ensure_project_link("project doctor", g)
	if code != 0 {
		return code
	}
	report, dcode := doctor_report(link.conn, root, context.temp_allocator)
	close_control(link)
	fmt.println(report)
	if dcode == 0 {
		fmt.println("Health check passed - All tools working correctly")
	}
	return dcode
}

// doctor_report probes the project's health through the daemon link: a
// full symbol crawl (the tree-sitter pipeline and the SQLite index) and
// the language-server registry listing. Split from the connection
// plumbing for tests.
doctor_report :: proc(conn: ^jsonrpc.Conn, root: string, a := context.allocator) -> (string, int) {
	home := platform.aubade_home(a)
	sel := config.Stack_Selection{project_root = root}
	stack, serr := config.stack_build(sel, home, a)
	if serr != nil {
		return strings.concatenate(
			{"aubade project doctor: config stack failed: ", platform.err_message(serr, a)},
			a,
		), 1
	}
	defer config.stack_destroy(stack)

	langs_list := make([]string, len(stack.project.language_servers), a)
	for e, i in stack.project.language_servers {
		if e.path != "" {
			langs_list[i] = strings.concatenate({e.name, "=", e.path}, a)
		} else {
			langs_list[i] = e.name
		}
	}
	langs_str, _ := strings.join(langs_list, ", ", a)
	if langs_str == "" {
		langs_str = "N/A"
	}

	lines := make([dynamic]string, 0, 4, a)
	defer delete(lines)
	// The braces are literal display punctuation: fmt would parse them as
	// parameter braces, so the line is joined by concatenation.
	langs := strings.concatenate({"languages {", langs_str, "}"}, a)
	append(&lines, fmt.aprintf("config: project %q, %s, read-only %v",
		stack.project.project_name, langs, stack.project.read_only, allocator = a))

	crawl, ccode := index_summary(conn, "", a)
	append(&lines, crawl)
	if ccode != 0 {
		joined, _ := strings.join(lines[:], "\n", a)
		return joined, 1
	}

	ls_call := svc.client_langserver_list(conn, a, platform.mono_ms() + 10_000)
	if ls_call.call_err != .None {
		append(&lines, fmt.aprintf("language servers: registry query failed: %s",
			ls_call.err_message != "" ? ls_call.err_message : "svc call failed", allocator = a))
		joined, _ := strings.join(lines[:], "\n", a)
		return joined, 1
	}
	ls_count := 0
	if items, ok := jsonutil.obj_get(ls_call.result, "items"); ok {
		#partial switch x in items {
		case json.Array:
			ls_count = len(x)
		case:
		}
	}
	append(&lines, fmt.aprintf("language servers: %d registered", ls_count, allocator = a))

	joined, _ := strings.join(lines[:], "\n", a)
	return joined, 0
}

// --- the daemon link (connect or spawn) -------------------------------------------

// ensure_project_link returns a control link to the project's daemon,
// spawning `aubade _daemon` when no endpoint answers — the same
// parent-mediated fill path the session uses, minus the heartbeat.
ensure_project_link :: proc(cmd: string, g: ^Globals) -> (^Control_Link, int) {
	path, id, code := resolve_control_target(cmd, g)
	if code != 0 {
		return nil, code
	}

	if info, ok := daemon.read_endpoint(path, context.temp_allocator); ok {
		if link, connected := connect_control(info); connected {
			return link, 0
		}
	}

	// Spawn and wait for the endpoint to publish (the spawn lock
	// serializes against a concurrent session doing the same). The config
	// clock is only read while building the spawn argv, so it retires
	// before the wait loop.
	exe, exe_err := os.get_executable_path(context.temp_allocator)
	if exe_err != nil || exe == "" {
		fmt.eprintf("aubade %s: cannot resolve the aubade executable for the daemon spawn\n", cmd)
		return nil, 1
	}
	home := platform.aubade_home(context.temp_allocator)
	{
		clock := new(platform.Clock, context.allocator)
		platform.clock_init(clock, false, context.allocator)
		dcfg := daemon.default_config(g.project, home, clock)
		// The handle is dropped, not tracked: this CLI is a one-shot whose
		// exit releases it (kernel-side) and whose transient flock-loser
		// zombies are reaped by init at the same moment — only the
		// session child, which outlives its daemons, needs the reap list.
		spawned, _ := daemon.spawn_parent(exe, dcfg, dcfg.hb_ping_ms, dcfg.hb_timeout_ms, dcfg.grace_ms, dcfg.drain_ms)
		platform.clock_destroy(clock)
		free(clock, context.allocator)
		if !spawned {
			fmt.eprintf("aubade %s: cannot spawn the project daemon\n", cmd)
			return nil, 1
		}
	}

	// Come-up poll through the real clock — one time discipline.
	clock: platform.Clock
	platform.clock_init(&clock, false)
	deadline := platform.clock_now(&clock) + 10_000
	for platform.clock_now(&clock) < deadline {
		if info, ok := daemon.read_endpoint(path, context.temp_allocator); ok {
			if link, connected := connect_control(info); connected {
				return link, 0
			}
		}
		platform.clock_wait(&clock, 50)
	}
	fmt.eprintf("aubade %s: the daemon for project %s did not come up within 10s\n", cmd, id)
	return nil, 1
}
