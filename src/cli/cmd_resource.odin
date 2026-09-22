// `aubade context` / `aubade mode` / `aubade config` — the JSONC
// user-resource families. Contexts and modes live as user files under
// $AUBADE_HOME/contexts|modes (shadowing same-named built-ins) and are
// created from commented templates or copied from a built-in; `config
// edit` opens the global config in the user's editor. These commands
// only ever write files the user explicitly asked to create — nothing
// here rewrites an existing user file.
package cli

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "src:config"
import "src:platform"
import "src:util"

// Resource_Kind carries every decision that differs between the context
// and mode families — the user dir, the name listing, the built-in
// serialiser and predicates, the fresh-file template, and the prose
// spellings — so no resource subcommand branches on the kind string.
Resource_Kind :: struct {
	spell:         string, // CLI noun and message spelling ("context"/"mode")
	display:       string, // capitalised noun for prose ("Context"/"Mode")
	dir:           proc(home: string, a: mem.Allocator) -> string,
	names:         proc(home: string, a: mem.Allocator) -> []string,
	def_jsonc:     proc(name: string, a: mem.Allocator) -> (string, bool),
	is_builtin:    proc(name: string) -> bool,
	builtin_names: proc(a: mem.Allocator) -> string,
	template:      proc(a: mem.Allocator) -> string,
}

RESOURCE_KINDS :: []Resource_Kind{
	{
		spell         = "context",
		display       = "Context",
		dir           = platform.contexts_dir,
		names         = config.list_context_names,
		def_jsonc     = context_def_jsonc_named,
		is_builtin    = context_is_builtin,
		builtin_names = context_builtin_names,
		template      = config.template_context,
	},
	{
		spell         = "mode",
		display       = "Mode",
		dir           = platform.modes_dir,
		names         = config.list_mode_names,
		def_jsonc     = mode_def_jsonc_named,
		is_builtin    = mode_is_builtin,
		builtin_names = mode_builtin_names,
		template      = config.template_mode,
	},
}

// resource_kind finds the family row for a kind spelling — the two nouns
// the root command table routes here. The row comes back by value: a
// pointer into the materialized table would dangle with this frame.
resource_kind :: proc(kind: string) -> (Resource_Kind, bool) {
	table := RESOURCE_KINDS
	for i in 0..<len(table) {
		if table[i].spell == kind {
			return table[i], true
		}
	}
	return {}, false
}

// def_names_csv renders a built-in table's names comma-joined for the
// --from-internal refusal (generic over the def type: both tables carry
// a name field).
def_names_csv :: proc($T: typeid, defs: []T, a := context.allocator) -> string {
	names := make([dynamic]string, 0, len(defs), context.temp_allocator)
	defer delete(names)
	for &d in defs {
		append(&names, d.name)
	}
	return util.quoted_join(names[:], ", ", "", a)
}

context_builtin_names :: proc(a: mem.Allocator) -> string {
	return def_names_csv(config.Context_Def, config.BUILTIN_CONTEXTS, a)
}

mode_builtin_names :: proc(a: mem.Allocator) -> string {
	return def_names_csv(config.Mode_Def, config.BUILTIN_MODES, a)
}

// def_named reports whether a built-in table carries the name.
def_named :: proc($T: typeid, defs: []T, name: string) -> bool {
	for &d in defs {
		if d.name == name {
			return true
		}
	}
	return false
}

context_is_builtin :: proc(name: string) -> bool {
	return def_named(config.Context_Def, config.BUILTIN_CONTEXTS, name)
}

mode_is_builtin :: proc(name: string) -> bool {
	return def_named(config.Mode_Def, config.BUILTIN_MODES, name)
}

// context_def_jsonc_named serialises a built-in context by name; false
// means the name is not a built-in.
context_def_jsonc_named :: proc(name: string, a: mem.Allocator) -> (string, bool) {
	defs := config.BUILTIN_CONTEXTS
	for i in 0..<len(defs) {
		if defs[i].name == name {
			// Copy within this proc; the serialiser only reads the slices.
			def := defs[i]
			return config.context_def_jsonc(&def, a), true
		}
	}
	return "", false
}

mode_def_jsonc_named :: proc(name: string, a: mem.Allocator) -> (string, bool) {
	defs := config.BUILTIN_MODES
	for i in 0..<len(defs) {
		if defs[i].name == name {
			def := defs[i]
			return config.mode_def_jsonc(&def, a), true
		}
	}
	return "", false
}

// Resource_Subcmd is one row of the resource family's subcommand table —
// the runners take the family row instead of a kind string.
Resource_Subcmd :: struct {
	name: string,
	run:  proc(k: ^Resource_Kind, args: []string) -> int,
}

RESOURCE_SUBCMDS :: []Resource_Subcmd{
	{name = "list",   run = resource_list_cmd},
	{name = "create", run = resource_create_common},
	{name = "edit",   run = resource_edit_common},
	{name = "delete", run = resource_delete_common},
}

// run_resource_cmd is the shared `context`/`mode` dispatch: both noun
// families expose the same subcommands over the same user-resource
// files, so one table drives both.
run_resource_cmd :: proc(kind: string, args: []string, g: ^Globals, version: string) -> int {
	k, known := resource_kind(kind)
	if !known {
		return usage_error(kind, "unknown resource family")
	}
	rest, code := run_subcmd(kind, table_names(Resource_Subcmd, RESOURCE_SUBCMDS, context.temp_allocator), args, g)
	if code != 0 {
		return code
	}
	for e in RESOURCE_SUBCMDS {
		if e.name == rest[0] {
			return e.run(&k, rest[1:])
		}
	}
	return usage_error(kind, strings.concatenate(
		{"unknown subcommand \"", rest[0], "\""},
		context.temp_allocator,
	))
}

run_context_cmd :: proc(args: []string, g: ^Globals, version: string) -> int {
	return run_resource_cmd("context", args, g, version)
}

run_mode_cmd :: proc(args: []string, g: ^Globals, version: string) -> int {
	return run_resource_cmd("mode", args, g, version)
}

CONFIG_SUBCMDS :: []Sub_Cmd_Entry{
	{name = "edit", run = config_edit_cmd},
}

run_config_cmd :: proc(args: []string, g: ^Globals, version: string) -> int {
	return run_subcommands("config", CONFIG_SUBCMDS, args, g)
}

// --- shared helpers ---------------------------------------------------------

// resource_name_safe is the resource-name rule: a letter/digit first,
// then letters, digits, hyphens, underscores.
resource_name_safe :: proc(name: string) -> bool {
	if name == "" {
		return false
	}
	first := name[0]
	starts_ok := (first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z') || (first >= '0' && first <= '9')
	if !starts_ok {
		return false
	}
	for i := 1; i < len(name); i += 1 {
		c := name[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_'
		if !ok {
			return false
		}
	}
	return true
}

// write_text_file writes body to a fresh path; the open itself is the
// existence test (.Excl), so a concurrent creator of the same path can
// never be truncated over. Failures print the cmd-prefixed error and
// return false.
write_text_file :: proc(cmd: string, path: string, body: string) -> bool {
	f, oerr := os.open(path, {.Write, .Create, .Excl}, os.Permissions{.Read_User, .Write_User})
	if oerr != nil {
		if os.exists(path) {
			fmt.eprintf("aubade %s: %s already exists\n", cmd, path)
		} else {
			fmt.eprintf("aubade %s: cannot create %s\n", cmd, path)
		}
		return false
	}
	werr := platform.write_all(f, transmute([]u8)body)
	os.close(f)
	if werr != nil {
		// The O_EXCL create already claimed the path: leaving the
		// truncated body there makes every retry refuse with "already
		// exists" until the user removes it by hand. The file is closed
		// above, so the remove also works on Windows.
		_ = os.remove(path)
		fmt.eprintf("aubade %s: cannot write %s\n", cmd, path)
		return false
	}
	return true
}

// resource_list_cmd lists a family's names with "(internal)" for
// built-ins and "(at <path>)" for user files (a user file shadows the
// same-named built-in, so a path wins).
resource_list_cmd :: proc(k: ^Resource_Kind, args: []string) -> int {
	if len(args) > 0 {
		return usage_error(strings.concatenate({k.spell, " list"}, context.temp_allocator), "takes no arguments")
	}
	home := platform.aubade_home(context.temp_allocator)
	names := k.names(home, context.temp_allocator)
	defer delete(names, context.temp_allocator)

	dir := k.dir(home, context.temp_allocator)
	max_len := 0
	for n in names {
		if len(n) > max_len {
			max_len = len(n)
		}
	}
	for n in names {
		nparts := []string{dir, strings.concatenate({n, ".jsonc"}, context.temp_allocator)}
		path, _ := filepath.join(nparts, context.temp_allocator)
		desc := "(internal)"
		if os.exists(path) {
			desc = strings.concatenate({"(at ", path, ")"}, context.temp_allocator)
		}
		pad := max_len + 4 - len(n)
		spaces := strings.repeat(" ", pad, context.temp_allocator)
		fmt.printf("%s%s%s\n", n, spaces, desc)
		delete(spaces, context.temp_allocator)
	}
	return 0
}

// resource_create_common implements create for one family: the fresh
// commented template by default, or the built-in definition serialised
// to JSONC with --from-internal. An existing destination is never
// overwritten (create is explicit generation, like init).
resource_create_common :: proc(k: ^Resource_Kind, args: []string) -> int {
	cmd := strings.concatenate({k.spell, " create"}, context.temp_allocator)
	name := ""
	from_internal := ""
	pos := make([dynamic]string, 0, 1, context.temp_allocator)
	i := 0
	for i < len(args) {
		if args[i] == "--from-internal" {
			if i + 1 >= len(args) {
				return usage_error(cmd, "--from-internal requires a value")
			}
			i += 1
			from_internal = args[i]
			i += 1
			continue
		}
		if strings.has_prefix(args[i], "-") {
			return usage_error(cmd, strings.concatenate({"unknown flag \"", args[i], "\""}, context.temp_allocator))
		}
		append(&pos, args[i])
		i += 1
	}
	if len(pos) > 1 {
		return usage_error(cmd, "at most one name is allowed")
	}
	if len(pos) == 1 {
		name = pos[0]
	}
	if name == "" && from_internal == "" {
		return usage_error(cmd, "provide at least a name or --from-internal")
	}
	if name == "" {
		name = from_internal
	}
	if !resource_name_safe(name) {
		return usage_error(cmd, strings.concatenate(
			{"name \"", name, "\" contains invalid characters; only letters, digits, hyphens and underscores are allowed"},
			context.temp_allocator,
		))
	}

	home := platform.aubade_home(context.temp_allocator)
	dir := k.dir(home, context.temp_allocator)
	dparts := []string{dir, strings.concatenate({name, ".jsonc"}, context.temp_allocator)}
	dest, _ := filepath.join(dparts, context.temp_allocator)
	if os.exists(dest) {
		fmt.eprintf("aubade %s: %s already exists\n", cmd, dest)
		return 1
	}

	body := ""
	if from_internal != "" {
		serialised, found := k.def_jsonc(from_internal, context.temp_allocator)
		if !found {
			fmt.eprintf("aubade %s: internal %s %q not found; available: %s\n", cmd, k.spell, from_internal, k.builtin_names(context.temp_allocator))
			return 1
		}
		body = serialised
	} else {
		body = k.template(context.temp_allocator)
	}

	if err := os.make_directory_all(dir); err != nil && !os.is_directory(dir) {
		fmt.eprintf("aubade %s: cannot create %s\n", cmd, dir)
		return 1
	}
	if !write_text_file(cmd, dest, body) {
		return 1
	}
	fmt.printf("Created %s %q at %s\n", k.spell, name, dest)
	return open_in_editor(cmd, dest) ? 0 : 1
}

// resource_edit_common implements edit: a user file opens in the editor;
// a built-in name without a user file is refused with the
// create --from-internal hint (exit 0); an
// unknown name is an error.
resource_edit_common :: proc(k: ^Resource_Kind, args: []string) -> int {
	cmd := strings.concatenate({k.spell, " edit"}, context.temp_allocator)
	if len(args) != 1 {
		return usage_error(cmd, "requires exactly one name")
	}
	name := args[0]
	if !resource_name_safe(name) {
		return usage_error(cmd, strings.concatenate(
			{"name \"", name, "\" contains invalid characters; only letters, digits, hyphens and underscores are allowed"},
			context.temp_allocator,
		))
	}
	home := platform.aubade_home(context.temp_allocator)
	dir := k.dir(home, context.temp_allocator)
	pparts := []string{dir, strings.concatenate({name, ".jsonc"}, context.temp_allocator)}
	path, _ := filepath.join(pparts, context.temp_allocator)
	if !os.exists(path) {
		if k.is_builtin(name) {
			fmt.printf(
				"%s %q is an internal %s and cannot be edited directly.\nUse 'aubade %s create --from-internal %s' to create a custom %s first.\n",
				k.display, name, k.spell, k.spell, name, k.spell,
			)
			return 0
		}
		fmt.eprintf(
			"aubade %s: custom %s %q not found. Create it with: aubade %s create %s\n",
			cmd, k.spell, name, k.spell, name,
		)
		return 1
	}
	return open_in_editor(cmd, path) ? 0 : 1
}

// resource_delete_common implements delete for user files.
resource_delete_common :: proc(k: ^Resource_Kind, args: []string) -> int {
	cmd := strings.concatenate({k.spell, " delete"}, context.temp_allocator)
	if len(args) != 1 {
		return usage_error(cmd, "requires exactly one name")
	}
	name := args[0]
	if !resource_name_safe(name) {
		return usage_error(cmd, strings.concatenate(
			{"name \"", name, "\" contains invalid characters; only letters, digits, hyphens and underscores are allowed"},
			context.temp_allocator,
		))
	}
	home := platform.aubade_home(context.temp_allocator)
	dir := k.dir(home, context.temp_allocator)
	pparts := []string{dir, strings.concatenate({name, ".jsonc"}, context.temp_allocator)}
	path, _ := filepath.join(pparts, context.temp_allocator)
	if !os.exists(path) {
		fmt.eprintf("aubade %s: custom %s %q not found\n", cmd, k.spell, name)
		return 1
	}
	if rerr := os.remove(path); rerr != nil {
		fmt.eprintf("aubade %s: cannot remove %s\n", cmd, path)
		return 1
	}
	fmt.printf("Deleted custom %s %q.\n", k.spell, name)
	return 0
}

// --- config edit ---------------------------------------------------------------

// config_edit_cmd opens $AUBADE_HOME/config.jsonc in the user's editor.
// A missing file is refused with the init hint (the config is generated
// exactly once, by init).
config_edit_cmd :: proc(args: []string, g: ^Globals) -> int {
	if len(args) > 0 {
		return usage_error("config edit", "takes no arguments")
	}
	home := platform.aubade_home(context.temp_allocator)
	path := platform.config_path(home, context.temp_allocator)
	if !os.exists(path) {
		fmt.eprintf("aubade config edit: config file does not exist: %s (run aubade init first)\n", path)
		return 1
	}
	return open_in_editor("config edit", path) ? 0 : 1
}
