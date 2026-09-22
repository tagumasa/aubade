// `aubade tracker` — the human-facing view over the event log: list and
// show are read-only, export stores the rendered sprint reports as
// sprint_reports rows in the tracker store, report emits the structured
// TSV/JSON rows. The CLI opens the project's SQLite events table
// directly (the event stream stays read-only — its writes flow through
// the daemon's manager by design), so no daemon has to be running for
// inspection or export.
package cli

import "core:fmt"
import "core:strconv"
import "core:strings"

import "src:config"
import "src:daemon"
import "src:util"
import "src:platform"
import "src:store"
import "src:tracker"

TRACKER_SUBCMDS :: []Sub_Cmd_Entry{
	{name = "list",   run = tracker_list_cmd},
	{name = "show",   run = tracker_show_cmd},
	{name = "export", run = tracker_export_cmd},
	{name = "report", run = tracker_report_cmd},
}

run_tracker_cmd :: proc(args: []string, g: ^Globals, version: string) -> int {
	return run_subcommands("tracker", TRACKER_SUBCMDS, args, g)
}

// cli_tracker holds the manager and its store handle so every
// subcommand closes both on one path.
Cli_Tracker :: struct {
	m:  ^tracker.Manager,
	db: ^store.DB,
}

// tracker_open opens the events table and folds the manager. The CLI
// never mints events — the writable handle exists for derived-artifact
// writes (export's sprint_reports rows); the event stream stays a
// daemon-owned write path.
tracker_open :: proc(cmd: string, g: ^Globals) -> (Cli_Tracker, bool) {
	root, code := resolve_project_root(cmd, g)
	if code != 0 {
		return {}, false
	}
	db_path := daemon.project_db_path(root, platform.aubade_home(context.temp_allocator), context.temp_allocator)
	db, err := store.db_open(db_path, context.allocator)
	if err != nil {
		fmt.eprintf("aubade %s: cannot open tracker store: %s\n", cmd, platform.err_message(err, context.temp_allocator))
		return {}, false
	}
	m := new(tracker.Manager, context.allocator)
	// snapshots=false: snapshot writes belong to the daemon's manager —
	// the CLI restores a snapshot when one exists but never writes one.
	if terr := tracker.manager_init(m, db, cli_wall_ns, 0, 1, false, context.allocator); terr != nil {
		fmt.eprintf("aubade %s: cannot fold events: %s\n", cmd, platform.err_message(terr, context.temp_allocator))
		store.db_close(db)
		return {}, false
	}
	return {m = m, db = db}, true
}

tracker_close :: proc(ct: Cli_Tracker) {
	tracker.manager_destroy(ct.m)
	free(ct.m)
	store.db_close(ct.db)
}

cli_wall_ns :: proc() -> i64 {
	return platform.wall_ms() * 1_000_000
}

// tracker_sanitize strips terminal-control content from tracker text before
// it reaches a terminal: whole ANSI escape sequences (a pasted clear-
// screen would otherwise wipe the user's display) and stray C0/C1
// control runes, keeping newlines and tabs. Multi-byte UTF-8 passes
// through byte-for-byte — only the C1 runes' own two-byte encoding
// (c2 80..c2 9f) is stripped, never the continuation bytes of
// well-formed text.
tracker_sanitize :: proc(s: string) -> string {
	buf := make([dynamic]u8, 0, len(s), context.temp_allocator)
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '\n' || c == '\t' {
			append(&buf, c)
			i += 1
			continue
		}
		if c == 0x1b && i + 1 < len(s) {
			next := s[i + 1]
			if next == '[' { // CSI: parameter bytes then a final 0x40-0x7e
				i += 2
				for i < len(s) && s[i] >= 0x20 && s[i] <= 0x3f {
					i += 1
				}
				if i < len(s) && s[i] >= 0x40 && s[i] <= 0x7e {
					i += 1
				}
			} else if next == ']' { // OSC: through BEL or ESC backslash
				i += 2
				for i < len(s) {
					if s[i] == 0x07 {
						i += 1
						break
					}
					if s[i] == 0x1b && i + 1 < len(s) && s[i + 1] == '\\' {
						i += 2
						break
					}
					i += 1
				}
			} else { // two-rune escape
				i += 2
			}
			continue
		}
		if c < 0x20 || c == 0x7f {
			i += 1
			continue
		}
		if c < 0x80 {
			append(&buf, c)
			i += 1
			continue
		}
		// Multi-byte territory. C1 control RUNES (U+0080-U+009F) encode
		// as c2 80..c2 9f — only that two-byte shape is stripped; a byte-
		// range check here would shred every UTF-8 continuation byte that
		// lands in 0x80-0x9f (it shredded the em-dash in the empty-list
		// message). Well-formed sequences pass through byte-for-byte;
		// stray or truncated continuations are dropped.
		if c == 0xc2 && i + 1 < len(s) && s[i + 1] >= 0x80 && s[i + 1] <= 0x9f {
			i += 2
			continue
		}
		seq_len := 0
		switch {
		case c >= 0xc2 && c <= 0xdf:
			seq_len = 2
		case c >= 0xe0 && c <= 0xef:
			seq_len = 3
		case c >= 0xf0 && c <= 0xf4:
			seq_len = 4
		}
		if seq_len == 0 || i + seq_len > len(s) {
			i += 1
			continue
		}
		valid := true
		for j := 1; j < seq_len; j += 1 {
			if s[i + j] & 0xc0 != 0x80 {
				valid = false
				break
			}
		}
		if !valid {
			i += 1
			continue
		}
		for j := 0; j < seq_len; j += 1 {
			append(&buf, s[i + j])
		}
		i += seq_len
	}
	return string(buf[:])
}

// --- flag parsing ------------------------------------------------------------

// tracker_flag_str fetches one --flag value ("--flag value" or
// "--flag=value").
tracker_flag_str :: proc(cmd: string, args: []string, flag: string, i: ^int) -> (string, bool, int) {
	arg := args[i^]
	if !strings.has_prefix(arg, flag) {
		return "", false, 0
	}
	rest := arg[len(flag):]
	if strings.has_prefix(rest, "=") {
		i^ += 1
		return rest[1:], true, 0
	}
	if rest != "" {
		return "", false, 0
	}
	if i^ + 1 >= len(args) {
		return "", true, usage_error(cmd, strings.concatenate({flag, " requires a value"}, context.temp_allocator))
	}
	val := args[i^ + 1]
	i^ += 2
	return val, true, 0
}

// tracker_filter_flags parses the shared incident-filter flags into f;
// limit_out (when non-nil) also accepts --limit. Returns the exit code
// (0 = keep going).
tracker_filter_flags :: proc(cmd: string, args: []string, f: ^tracker.Incident_Filter, limit_out: ^int) -> int {
	status := make([dynamic]string, 0, 4, context.temp_allocator)
	priority := make([dynamic]string, 0, 4, context.temp_allocator)
	i := 0
	for i < len(args) {
		if val, ok, code := tracker_flag_str(cmd, args, "--status", &i); ok {
			if code != 0 {
				return code
			}
			append(&status, val)
			continue
		}
		if val, ok, code := tracker_flag_str(cmd, args, "--priority", &i); ok {
			if code != 0 {
				return code
			}
			append(&priority, val)
			continue
		}
		if val, ok, code := tracker_flag_str(cmd, args, "--sprint", &i); ok {
			if code != 0 {
				return code
			}
			f.sprint = val
			continue
		}
		if val, ok, code := tracker_flag_str(cmd, args, "--label", &i); ok {
			if code != 0 {
				return code
			}
			f.label = val
			continue
		}
		if val, ok, code := tracker_flag_str(cmd, args, "--verdict", &i); ok {
			if code != 0 {
				return code
			}
			f.verdict = val
			continue
		}
		if val, ok, code := tracker_flag_str(cmd, args, "--blocked-by", &i); ok {
			if code != 0 {
				return code
			}
			f.blocked_by = val
			continue
		}
		if val, ok, code := tracker_flag_str(cmd, args, "--assignee", &i); ok {
			if code != 0 {
				return code
			}
			f.assignee = val
			continue
		}
		if val, ok, code := tracker_flag_str(cmd, args, "--created-by", &i); ok {
			if code != 0 {
				return code
			}
			f.created_by = val
			continue
		}
		if val, ok, code := tracker_flag_str(cmd, args, "--query", &i); ok {
			if code != 0 {
				return code
			}
			f.query = val
			continue
		}
		if val, ok, code := tracker_flag_str(cmd, args, "--sort", &i); ok {
			if code != 0 {
				return code
			}
			f.sort = val
			continue
		}
		if limit_out != nil {
			if val, ok, code := tracker_flag_str(cmd, args, "--limit", &i); ok {
				if code != 0 {
					return code
				}
				n, parsed := strconv.parse_int(val)
				if !parsed {
					return usage_error(cmd, "--limit requires an integer")
				}
				(limit_out^) = int(n)
				continue
			}
		}
		return usage_error(cmd, strings.concatenate({"unknown flag \"", args[i], "\""}, context.temp_allocator))
	}
	if len(status) > 0 {
		f.status = status[:]
	}
	if len(priority) > 0 {
		f.priority = priority[:]
	}
	return 0
}

// --- subcommands ---------------------------------------------------------------

tracker_list_cmd :: proc(args: []string, g: ^Globals) -> int {
	f: tracker.Incident_Filter
	limit := 0
	if code := tracker_filter_flags("tracker list", args, &f, &limit); code != 0 {
		return code
	}
	f.limit = limit

	ct, ok := tracker_open("tracker list", g)
	if !ok {
		return 1
	}
	defer tracker_close(ct)

	text, err := tracker.manager_list_incidents(ct.m, &f, platform.wall_ms(), context.temp_allocator)
	if err != nil {
		fmt.eprintf("aubade tracker list: %s\n", platform.err_message(err, context.temp_allocator))
		return 1
	}
	fmt.println(tracker_sanitize(text))
	return 0
}

tracker_show_cmd :: proc(args: []string, g: ^Globals) -> int {
	positional := make([dynamic]string, 0, 1, context.temp_allocator)
	i := 0
	for i < len(args) {
		if !strings.has_prefix(args[i], "-") {
			append(&positional, args[i])
			i += 1
			continue
		}
		return usage_error("tracker show", strings.concatenate({"unknown flag \"", args[i], "\""}, context.temp_allocator))
	}
	if len(positional) != 1 {
		return usage_error("tracker show", "exactly one incident or sprint id is required")
	}
	id := positional[0]

	ct, ok := tracker_open("tracker show", g)
	if !ok {
		return 1
	}
	defer tracker_close(ct)

	text: string
	err: platform.Err
	if id == "current" || strings.has_prefix(id, "SPR-") {
		text, err = tracker.manager_get_sprint(ct.m, id, 0, context.temp_allocator)
	} else {
		text, err = tracker.manager_get_incident(ct.m, id, 0, context.temp_allocator)
	}
	if err != nil {
		fmt.eprintf("aubade tracker show: %s\n", platform.err_message(err, context.temp_allocator))
		return 1
	}
	fmt.println(tracker_sanitize(text))
	return 0
}

tracker_export_cmd :: proc(args: []string, g: ^Globals) -> int {
	sprint := ""
	i := 0
	for i < len(args) {
		if val, ok, code := tracker_flag_str("tracker export", args, "--sprint", &i); ok {
			if code != 0 {
				return code
			}
			sprint = val
			continue
		}
		return usage_error("tracker export", strings.concatenate({"unknown flag \"", args[i], "\""}, context.temp_allocator))
	}

	ct, ok := tracker_open("tracker export", g)
	if !ok {
		return 1
	}
	defer tracker_close(ct)

	ack, err := tracker.manager_export(ct.m, sprint, context.temp_allocator)
	if err != nil {
		fmt.eprintf("aubade tracker export: %s\n", platform.err_message(err, context.temp_allocator))
		return 1
	}
	fmt.println(ack)
	return 0
}

tracker_report_cmd :: proc(args: []string, g: ^Globals) -> int {
	f: tracker.Incident_Filter
	format := tracker.REPORT_FORMAT_NAMES[0]
	output := ""
	i := 0
	for i < len(args) {
		if val, ok, code := tracker_flag_str("tracker report", args, "--format", &i); ok {
			if code != 0 {
				return code
			}
			format = val
			continue
		}
		if val, ok, code := tracker_flag_str("tracker report", args, "--output", &i); ok {
			if code != 0 {
				return code
			}
			output = val
			continue
		}
		break
	}
	rf, fok := tracker.report_format_from_string(format)
	if !fok {
		return usage_error(
			"tracker report",
			strings.concatenate(
				{"--format must be ", util.quoted_join(tracker.REPORT_FORMAT_NAMES, " or ", "", context.temp_allocator)},
				context.temp_allocator,
			),
		)
	}
	if code := tracker_filter_flags("tracker report", args[i:], &f, nil); code != 0 {
		return code
	}

	ct, ok := tracker_open("tracker report", g)
	if !ok {
		return 1
	}
	defer tracker_close(ct)

	out, err := tracker.manager_render_incident_report(ct.m, &f, rf, context.temp_allocator)
	if err != nil {
		fmt.eprintf("aubade tracker report: %s\n", platform.err_message(err, context.temp_allocator))
		return 1
	}
	if output == "" {
		// Raw report bytes: no counts header, no sanitization, no
		// trailing newline beyond the report's own records.
		fmt.print(out)
		return 0
	}
	root, rcode := resolve_project_root("tracker report", g)
	if rcode != 0 {
		return rcode
	}
	newline := config.line_ending_newline(cli_effective_line_ending(root))
	content := tracker.report_apply_line_ending(out, newline, context.temp_allocator)
	// Atomic publish (tmp + rename): the previous file stays intact until
	// the new one is fully written, and the write result is checked — a
	// short write or IO error must not exit 0 with a truncated report.
	if werr := platform.atomic_write(output, transmute([]u8)content, {.Read_User, .Write_User}); werr != nil {
		fmt.eprintf("aubade tracker report: cannot write %s\n", output)
		return 1
	}
	return 0
}

// cli_effective_line_ending resolves project → global → native for the
// CLI's report writes (stdout rendering always stays LF), through the one
// shared precedence helper.
cli_effective_line_ending :: proc(root: string) -> config.Line_Ending {
	home := platform.aubade_home(context.temp_allocator)
	// A failed load returns nil; the zero Shared_Config's *_set flags read
	// as "key absent", so the helper falls through to the next layer.
	global, _, gerr := config.load_global(home, context.temp_allocator)
	g: config.Global_Config
	if gerr == nil {
		g = global^
	}
	project, _, perr := config.load_project_for_root(root, home, context.temp_allocator)
	p: config.Project_Config
	if perr == nil {
		p = project^
	}
	return config.resolve_line_ending(&p.shared, &g.shared)
}
