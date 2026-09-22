// cli: the command table and root-level parsing. The global flags
// (--project, --project-from-cwd, --log-level) are declared exactly once
// here and accepted both before and after the subcommand; every runner
// strips them from its own argument list through the same try_global
// helper. Exit codes: 0 success, 1 runtime failure, 2 usage error.
// `_daemon` is the internal spawn verb and stays out of the public table.
package cli

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "src:config"
import "src:daemon"
import "src:platform"
import "src:session"
import "src:util"

Globals :: struct {
	project:          string,
	project_from_cwd: bool,
	log_level:        string,
}

Cmd_Entry :: struct {
	name:   string,
	brief:  string,
	run:    proc(args: []string, g: ^Globals, version: string) -> int,
}

COMMANDS :: []Cmd_Entry{
	{
		name  = "init",
		brief = "Initialise Aubade by creating a global config file",
		run   = run_init,
	},
	{
		name  = "mcp",
		brief = "Start an MCP child session (stdio)",
		run   = run_mcp,
	},
	{
		name  = "setup",
		brief = "Set up Aubade for use with a specific client",
		run   = run_setup,
	},
	{
		name  = "uninstall",
		brief = "Remove Aubade's registration from a client (inverse of setup)",
		run   = run_uninstall,
	},
	{
		name  = "daemon",
		brief = "Inspect or stop the project daemon",
		run   = run_daemon_ctl,
	},
	{
		name  = "hook",
		brief = "Session lifecycle hooks (activate, cleanup, remind, auto-approve)",
		run   = run_hook_cmd,
	},
	{
		name  = "tool",
		brief = "List visible tools (--all/--only-optional/--quiet) or show one tool; both take --context/--mode",
		run   = run_tool_cmd,
	},
	{
		name  = "tracker",
		brief = "Inspect incidents and sprints (list/show/report read-only; export stores reports)",
		run   = run_tracker_cmd,
	},
	{
		name  = "memory",
		brief = "Manage project and global memories (list/show/write/check/fix-references)",
		run   = run_memories_cmd,
	},
	{
		name  = "project",
		brief = "Manage projects (create --index, list, index --file, delete, check-ignore, doctor)",
		run   = run_project_cmd,
	},
	{
		name  = "prompt",
		brief = "Render the system prompt / CC override and manage prompt templates",
		run   = run_prompt_cmd,
	},
	{
		name  = "context",
		brief = "Manage agent contexts (list/create/edit/delete)",
		run   = run_context_cmd,
	},
	{
		name  = "mode",
		brief = "Manage agent modes (list/create/edit/delete)",
		run   = run_mode_cmd,
	},
	{
		name  = "config",
		brief = "Manage Aubade configuration (edit)",
		run   = run_config_cmd,
	},
	{
		name  = "about",
		brief = "Print version and third-party license information",
		run   = run_about,
	},
}

// run parses the root flags, dispatches the subcommand, and returns the
// process exit code.
run :: proc(args: []string, version: string) -> int {
	g: Globals

	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--" {
			i += 1
			break
		}
		if arg == "--version" || arg == "-v" || arg == "--help" || arg == "-h" {
			break // dispatched as the subcommand below
		}
		if arg != "-" && strings.has_prefix(arg, "-") {
			n := try_global(args, i, &g)
			if n > 0 {
				i += n
				continue
			}
			if n < 0 {
				fmt.eprintln(strings.concatenate({
					"aubade: global flags need a valid value (",
					global_flags_summary(context.temp_allocator),
					")",
				}, context.temp_allocator))
				return 2
			}
			fmt.eprintf("aubade: unknown flag %q before subcommand\n", arg)
			return 2
		}
		break
	}

	if i >= len(args) {
		print_usage(version)
		return 2
	}
	name := args[i]
	rest := args[i + 1:]

	switch name {
	case "--version", "-v", "version":
		fmt.printf("aubade %s\n", version)
		return 0
	case "--help", "-h", "help":
		print_usage(version)
		return 0
	case "_daemon":
		// Internal: spawned by children to host the project daemon.
		return run_internal_daemon(rest)
	case:
		for cmd in COMMANDS {
			if cmd.name == name {
				return cmd.run(rest, &g, version)
			}
		}
		fmt.eprintf("aubade: unknown subcommand %q; try --help\n", name)
		return 2
	}
}

// global_flags_summary is the one spelling of the root flag line — the
// usage screen and the bad-value refusal both render it, and the level
// alternatives come from the log vocabulary itself.
global_flags_summary :: proc(a := context.allocator) -> string {
	return strings.concatenate({
		"--project <path>  --project-from-cwd  --log-level <",
		util.wire_names(util.Log_Level, util.log_level_string, "|", "", a),
		">",
	}, a)
}

print_usage :: proc(version: string) {
	fmt.println("aubade — code intelligence server")
	fmt.println("usage: aubade [global flags] <subcommand> [flags]")
	fmt.println(strings.concatenate({"global flags: ", global_flags_summary(context.temp_allocator)}, context.temp_allocator))
	fmt.println("subcommands:")
	for cmd in COMMANDS {
		fmt.printf("  %-8s %s\n", cmd.name, cmd.brief)
	}
	fmt.println("  help     Show this help")
	fmt.println("  version  Print the version")
}

// try_global consumes args[i] (plus its value when the flag takes one) into
// g. Returns the number of arguments consumed, 0 when args[i] is not a
// global flag, and -1 on a missing or invalid value.
try_global :: proc(args: []string, i: int, g: ^Globals) -> int {
	if i >= len(args) {
		return 0
	}
	switch args[i] {
	case "--project":
		if i + 1 >= len(args) {
			return -1
		}
		g.project = args[i + 1]
		return 2
	case "--project-from-cwd":
		g.project_from_cwd = true
		return 1
	case "--log-level":
		if i + 1 >= len(args) {
			return -1
		}
		if _, ok := util.log_parse_level(args[i + 1]); !ok {
			return -1
		}
		g.log_level = args[i + 1]
		return 2
	case:
		return 0
	}
}

// strip_globals removes global flags from args (they may appear anywhere),
// leaving the command-specific ones in rest. Returns false on a bad value.
strip_globals :: proc(args: []string, g: ^Globals, rest: ^[dynamic]string) -> bool {
	i := 0
	for i < len(args) {
		n := try_global(args, i, g)
		if n < 0 {
			return false
		}
		if n > 0 {
			i += n
			continue
		}
		append(rest, args[i])
		i += 1
	}
	return true
}

// resolve_project_root turns the globals into a project root: an explicit
// path (or a registered project name, when the value is not an existing
// path), or the upward search from the working directory (managed config,
// then .git), falling back to the working directory itself. The second
// return is an exit code (0 = ok).
resolve_project_root :: proc(cmd: string, g: ^Globals) -> (string, int) {
	project := g.project
	if project == "" && g.project_from_cwd {
		cwd, err := os.get_working_directory(context.temp_allocator)
		if err != nil {
			fmt.eprintln("aubade: cannot read working directory")
			return "", 1
		}
		home := platform.aubade_home(context.temp_allocator)
		project = config.find_project_root(cwd, home, context.temp_allocator)
		if project == "" {
			project = cwd
		}
	}
	if project == "" {
		return "", usage_error(cmd, "one of --project or --project-from-cwd is required")
	}
	// A value that is not an existing path may be a registered project
	// name (the base name `project list` shows).
	if !os.exists(project) {
		if resolved, found := registry_name_lookup(project); found {
			project = resolved
		} else {
			return "", usage_error(cmd, strings.concatenate(
				{"unknown project \"", project, "\" (not a path and not a registered name)"},
				context.temp_allocator,
			))
		}
	}
	root, ok := platform.normalize_project_root(project, context.temp_allocator)
	if !ok {
		fmt.eprintln("aubade: cannot normalize project root")
		return "", 1
	}
	return root, 0
}

// registry_name_lookup resolves a registered project's base name to its
// path (case-insensitive, like the rest of the path handling).
registry_name_lookup :: proc(name: string) -> (string, bool) {
	home := platform.aubade_home(context.temp_allocator)
	reg, err := config.registry_load(home, context.temp_allocator)
	if err != nil {
		return "", false
	}
	defer config.registry_destroy(reg, context.temp_allocator)
	for p in reg.projects {
		if strings.equal_fold(filepath.base(p), name) {
			// Clone out: the deferred registry_destroy frees the element.
			return strings.clone(p, context.temp_allocator), true
		}
	}
	return "", false
}

// run_mcp parses `aubade mcp` flags and runs the child session.
run_mcp :: proc(args: []string, g: ^Globals, version: string) -> int {
	cfg := session.default_config()
	// Made (not nil) before appending: append on a nil dynamic array grows
	// through context.allocator, which strands the backing under a test
	// tracking allocator.
	contexts := make([dynamic]string, 0, 4, context.allocator)
	modes := make([dynamic]string, 0, 4, context.allocator)
	rest := make([dynamic]string, 0, len(args), context.temp_allocator)
	if !strip_globals(args, g, &rest) {
		return usage_error("mcp", "invalid global flag value")
	}

	i := 0
	for i < len(rest) {
		arg := rest[i]
		handled, ferr := parse_shared_flag(rest[:], &i, &cfg.home, &cfg.hb_ping_ms, &cfg.hb_timeout_ms, &cfg.hb_grace_ms, &cfg.hb_drain_ms)
		if !handled {
			handled, ferr = parse_context_mode_flag(rest[:], &i, &contexts, &modes)
		}
		if handled {
			if ferr != "" {
				return usage_error("mcp", ferr)
			}
			i += 1
			continue
		}
		switch arg {
		case "--in-process":
			cfg.is_in_process = true
		case "--trace-lsp-communication":
			// The session forwards it in svc.hello; the daemon's LSP
			// factory turns frame logging on for servers it starts.
			cfg.trace_lsp = true
		case "--tool-timeout":
			if v, ok := parse_i64_flag(rest[:], &i); ok {
				cfg.tool_timeout_ms = v
			} else {
				return usage_error("mcp", "--tool-timeout requires a number (milliseconds)")
			}
		case:
			return usage_error("mcp", strings.concatenate({"unknown flag: ", arg}, context.temp_allocator))
		}
		i += 1
	}

	root, code := resolve_project_root("mcp", g)
	if code != 0 {
		return code
	}

	cfg.project_root = root
	cfg.contexts = contexts[:]
	// An empty slice must read as "no selection made", not as an explicit
	// empty selection: the config stack treats a non-nil mode list as
	// user-overridden and would skip the project/global default_modes on
	// every plain `aubade mcp` run.
	if len(modes) > 0 {
		cfg.modes = modes[:]
	}
	cfg.log_level = g.log_level // "" = keep the config key's level
	cfg.install_signals = true
	rc := session.run_session(cfg)
	delete(contexts)
	delete(modes)
	return rc
}

// run_internal_daemon parses `aubade _daemon` (spawned by children).
run_internal_daemon :: proc(args: []string) -> int {
	flags: Daemon_Flags
	flags.hb_ping_ms = daemon.DEFAULT_PING_MS
	flags.hb_timeout_ms = daemon.DEFAULT_TIMEOUT_MS
	flags.grace_ms = daemon.DEFAULT_GRACE_MS
	flags.drain_ms = daemon.DEFAULT_DRAIN_MS

	i := 0
	for i < len(args) {
		arg := args[i]
		handled, ferr := parse_shared_flag(args[:], &i, &flags.home, &flags.hb_ping_ms, &flags.hb_timeout_ms, &flags.grace_ms, &flags.drain_ms)
		if handled {
			if ferr != "" {
				return usage_error("_daemon", ferr)
			}
			i += 1
			continue
		}
		switch arg {
		case "--project":
			if i + 1 >= len(args) {
				return usage_error("_daemon", "--project requires a value")
			}
			i += 1
			flags.project_root = args[i]
		case:
			return usage_error("_daemon", strings.concatenate({"unknown flag: ", arg}, context.temp_allocator))
		}
		i += 1
	}

	if flags.project_root == "" {
		return usage_error("_daemon", "--project is required")
	}

	root, ok := platform.normalize_project_root(flags.project_root, context.allocator)
	if !ok {
		fmt.eprintln("aubade: cannot normalize project root")
		return 1
	}

	home := flags.home
	home_owned := false
	if home == "" {
		home = platform.aubade_home(context.allocator)
		home_owned = true
	}
	// The daemon borrows its cfg strings: daemon_cleanup frees only the
	// canonicalized project_root copy it minted itself, never home. These
	// two stay caller-owned, so they are freed here at every exit — root
	// always (normalize_project_root clones unconditionally), home only
	// when it is not the argv view.
	defer {
		delete(root, context.allocator)
		if home_owned {
			delete(home, context.allocator)
		}
	}

	// The daemon is spawned rather than user-invoked, so no --log-level
	// reaches it; the global config key is the shared setting surface and
	// the level is fixed before any thread starts.
	{
		scratch: mem.Dynamic_Arena
		mem.dynamic_arena_init(&scratch, context.allocator)
		level := util.Log_Level.Warning
		gcfg, _, gerr := config.load_global(home, mem.dynamic_arena_allocator(&scratch))
		if gerr == nil && gcfg.log_level != "" {
			if l, lok := util.log_parse_level(gcfg.log_level); lok {
				level = l
			}
		}
		util.log_init(level)
		mem.dynamic_arena_destroy(&scratch)
	}

	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, false)
	dcfg := daemon.default_config(root, home, clock)
	dcfg.hb_ping_ms = flags.hb_ping_ms
	dcfg.hb_timeout_ms = flags.hb_timeout_ms
	dcfg.grace_ms = flags.grace_ms
	dcfg.drain_ms = flags.drain_ms

	d := new(daemon.Daemon, context.allocator)
	if !daemon.daemon_init(d, dcfg) {
		free(d, context.allocator)
		platform.clock_destroy(clock)
		free(clock, context.allocator)
		fmt.eprintln("aubade: cannot initialize daemon directory")
		return 1
	}
	switch daemon.daemon_listen(d) {
	case .AlreadyRunning:
		daemon.daemon_cleanup(d)
		free(d, context.allocator)
		platform.clock_destroy(clock)
		free(clock, context.allocator)
		return 0
	case .LockFailed, .ListenFailed:
		daemon.daemon_cleanup(d)
		free(d, context.allocator)
		platform.clock_destroy(clock)
		free(clock, context.allocator)
		fmt.eprintln("aubade: cannot bind daemon listener")
		return 1
	case .Listening:
	}

	// SIGINT/SIGTERM cut the grace window and run the global stop path
	// (drain deadline, endpoint removal) instead of abrupt termination.
	// Windows reaches the same order through the console
	// handler.
	if platform.install_stop_signals(d.root, context.allocator, exited = &d.signal_watch_exited) {
		d.is_signal_watch_installed = true
	} else {
		util.log_warning("could not install stop signal handlers; kill falls back to default termination")
	}
	code := daemon.daemon_run(d) // ends with daemon_cleanup
	free(d, context.allocator)
	platform.clock_destroy(clock)
	free(clock, context.allocator)
	return code
}

Daemon_Flags :: struct {
	project_root:  string,
	home:          string,
	hb_ping_ms:    i64,
	hb_timeout_ms: i64,
	grace_ms:      i64,
	drain_ms:      i64,
}

usage_error :: proc(cmd: string, msg: string) -> int {
	fmt.eprintf("aubade %s: %s\n", cmd, msg)
	return 2
}

// run_subcmd is the shared subcommand dispatch head: strip the global
// flags, require a subcommand (the refusal names the accepted set), and
// return the stripped rest with exit code 0 — or nil and the usage
// error's exit code.
run_subcmd :: proc(cmd: string, usage: string, args: []string, g: ^Globals) -> ([dynamic]string, int) {
	rest := make([dynamic]string, 0, len(args), context.temp_allocator)
	if !strip_globals(args, g, &rest) {
		return nil, usage_error(cmd, "invalid global flag value")
	}
	if len(rest) == 0 {
		return nil, usage_error(cmd, strings.concatenate({"subcommand required: ", usage}, context.temp_allocator))
	}
	return rest, 0
}

// Sub_Cmd_Entry is one row of a noun family's subcommand table — the
// second-level twin of Cmd_Entry. The refusal message and the dispatch
// in run_subcommands both walk the same table, so the accepted set
// cannot drift from the procs that implement it.
Sub_Cmd_Entry :: struct {
	name: string,
	run:  proc(args: []string, g: ^Globals) -> int,
}

// table_names renders a subcommand table's accepted names comma-joined —
// the generic primitive behind the per-family usage fragments.
table_names :: proc($E: typeid, table: []E, a := context.allocator) -> string {
	names := make([dynamic]string, 0, len(table), context.temp_allocator)
	defer delete(names)
	for &e in table {
		append(&names, e.name)
	}
	return util.quoted_join(names[:], ", ", "", a)
}

// subcommand_usage renders the table's accepted set as the usage
// fragment run_subcmd prefixes with "subcommand required: ".
subcommand_usage :: proc(table: []Sub_Cmd_Entry, a := context.allocator) -> string {
	return table_names(Sub_Cmd_Entry, table, a)
}

// run_subcommands strips the global flags, requires a subcommand (the
// refusal names the table's accepted set), and dispatches through it.
run_subcommands :: proc(cmd: string, table: []Sub_Cmd_Entry, args: []string, g: ^Globals) -> int {
	rest, code := run_subcmd(cmd, subcommand_usage(table, context.temp_allocator), args, g)
	if code != 0 {
		return code
	}
	for e in table {
		if e.name == rest[0] {
			return e.run(rest[1:], g)
		}
	}
	return usage_error(cmd, fmt.aprintf("unknown subcommand %q", rest[0], allocator = context.temp_allocator))
}

// parse_context_mode_flag handles the --context/--mode selector pair
// every config-view consumer takes — the mcp child, `tool`, and
// `prompt render` — appending into the caller's selection lists.
// Returns (handled, err): handled == false leaves the caller's switch to
// speak; err names the flag for usage_error.
parse_context_mode_flag :: proc(
	args: []string,
	i: ^int,
	contexts, modes: ^[dynamic]string,
) -> (handled: bool, err: string) {
	switch args[i^] {
	case "--context":
		if i^ + 1 >= len(args) {
			return true, "--context requires a value"
		}
		i^ += 1
		append(contexts, args[i^])
		return true, ""
	case "--mode":
		if i^ + 1 >= len(args) {
			return true, "--mode requires a value"
		}
		i^ += 1
		append(modes, args[i^])
		return true, ""
	}
	return false, ""
}

parse_i64_flag :: proc(args: []string, i: ^int) -> (i64, bool) {
	if i^ + 1 >= len(args) {
		return 0, false
	}
	value := args[i^ + 1]
	if len(value) == 0 || value[0] == '-' {
		// Timing flags are durations: negatives invert grace/drain math, so
		// they are configuration errors, not values to clamp.
		return 0, false
	}
	v := i64(0)
	for c in value {
		if c < '0' || c > '9' {
			return 0, false
		}
		d := i64(c - '0')
		if v > (9223372036854775807 - d) / 10 {
			return 0, false // decimal overflow
		}
		v = v * 10 + d
	}
	i^ += 1
	return v, true
}

// parse_shared_flag handles one of the five flags the `mcp` child and
// the `_daemon` parent accept together — --home plus the four heartbeat
// and grace/drain --*-ms knobs — writing through the pointers. Returns
// (handled, err): handled == false leaves the caller's switch to speak;
// err != "" names the flag for usage_error.
parse_shared_flag :: proc(
	args: []string,
	i:    ^int,
	home: ^string,
	hb_ping_ms, hb_timeout_ms, grace_ms, drain_ms: ^i64,
) -> (handled: bool, err: string) {
	arg := args[i^]
	if arg == "--home" {
		if i^ + 1 >= len(args) {
			return true, "--home requires a value"
		}
		i^ += 1
		home^ = args[i^]
		return true, ""
	}
	dst: ^i64
	switch arg {
	case "--hb-ping-ms":
		dst = hb_ping_ms
	case "--hb-timeout-ms":
		dst = hb_timeout_ms
	case "--grace-ms":
		dst = grace_ms
	case "--drain-ms":
		dst = drain_ms
	case:
		return false, ""
	}
	if v, ok := parse_i64_flag(args, i); ok {
		dst^ = v
		return true, ""
	}
	return true, strings.concatenate({arg, " requires a number"}, context.temp_allocator)
}
