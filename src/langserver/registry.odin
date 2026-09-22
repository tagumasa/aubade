// The registry: per-language launch definitions, the extension index
// used for detection, and the probe caches the resolver procs share.
// Every table lives on the registry's own Dynamic_Arena (the Config_Stack
// model): built once at startup, freed wholesale at registry_destroy —
// owned fields are never freed individually, so an Entry gaining a field
// is a clone line in registry_add, not another arm in a teardown tree.
// The tables live on that arena (built at runtime, never constant
// data), and no process-global state exists: the daemon owns the
// Registry and passes it explicitly.
package langserver

import "core:encoding/json"
import "core:mem"
import "core:sort"
import "core:strings"
import "core:sync"

import "src:platform"
import "src:symbol"

// Priority values for language disambiguation in multi-language
// projects; the higher value wins among candidates for an extension.
PRIORITY_EXPERIMENTAL :: 0
PRIORITY_NORMAL       :: 10
PRIORITY_SUPERSET     :: 20

Env_Var :: struct {
	key:   string,
	value: string,
}

// Binary_Req names an executable that must be present for a language
// server to function; display_name is what user-facing messages call it.
Binary_Req :: struct {
	name:         string,
	display_name: string,
}

// Any_Of_Req names a group of executables of which at least one must be
// present; the first match is accepted.
Any_Of_Req :: struct {
	names:        []string,
	display_name: string,
}

// Check_Runtime_Proc verifies the prerequisites for launching the entry's
// server. A nil entry field means the default implementation over
// required_binaries and required_any_of. Failure is .NotFound (wrapped
// messages live on the caller's arena); root_dir is the project root.
Check_Runtime_Proc :: proc(reg: ^Registry, root_dir: string, arena: mem.Allocator) -> platform.Err

// Resolve_Command_Proc probes the system and returns the full argv for
// the server. An empty argv means "no dynamic resolution — use the static
// command/args fields"; an Err means probing itself failed.
Resolve_Command_Proc :: proc(reg: ^Registry, a: mem.Allocator) -> (argv: []string, err: platform.Err)

// Extra_Path_Dirs_Proc returns directories to prepend to the server's
// PATH (covers minimal-PATH launches from GUI apps and sandboxes).
Extra_Path_Dirs_Proc :: proc(reg: ^Registry, a: mem.Allocator) -> []string

// Config_Item_Proc answers one workspace/configuration item for the
// section; the empty object is the default answer.
Config_Item_Proc :: proc(section: string, arena: mem.Allocator) -> json.Value

// Entry describes how to launch and configure one language server;
// initialisation options are
// carried as serialized JSON text (parsed once at handshake time) so the
// entry stays pure data and no synthesized-JSON-object hazards exist.
Entry :: struct {
	id:                      string,
	display_name:            string,
	file_patterns:           []string, // globs, "*.go"
	priority:                int,
	experimental:            bool, // excluded from auto-detection
	// Multi-root workspace resolution: when root_markers is non-empty the
	// manager scans the project root for directories holding one of these
	// marker names (a file or a directory — ".git" is both in the wild) and
	// announces every hit to the server as a workspace folder. Empty = the
	// entry always receives the single project-root folder.
	root_markers:            []string,
	multi_root:              bool, // the server consumes multiple workspace folders
	// Degradation note: when none of these files exists at the server's
	// primary workspace folder (the first announced folder of a running
	// server, the manager root otherwise) AND none of the
	// config_note_option_keys is present in the language's user
	// initialization options, the server's cross-file results silently
	// degrade and config_note is what the list surfaces on the entry's
	// row. Empty = no such note; the note names the config route that
	// restores the capability (never a per-server file).
	config_note_files:       []string,
	config_note_option_keys: []string,
	config_note:             string,
	command:                 string,
	args:                    []string,
	env:                     []Env_Var,
	memory_limit_mb:         int, // 0 = factory default; negative = no containment
	init_options_json:       string, // serialized object or ""
	required_binaries:       []Binary_Req, // all must exist
	required_any_of:         []Any_Of_Req, // each group: at least one
	check_runtime:           Check_Runtime_Proc, // nil = default
	resolve_command:         Resolve_Command_Proc, // nil = static
	extra_path_dirs:         Extra_Path_Dirs_Proc, // nil = none
	config_item:             Config_Item_Proc, // nil = empty object
	normalize:               symbol.Normalize_Name_Proc, // nil = pass-through
	install_hint:            string,
}

Registry :: struct {
	// The arena owns every entry, index, and cached argv; registry_destroy
	// is one wholesale free. `allocator` is the arena's backing
	// allocator: clone and probe sites allocate through it, and nothing
	// needs an individual
	// free (a non-last arena free would be a no-op anyway).
	arena:             mem.Dynamic_Arena,
	owner:             mem.Allocator, // frees the Registry struct itself
	allocator:         mem.Allocator, // the arena's allocator

	entries:           map[string]^Entry,
	by_ext:            map[string][]^Entry, // lowercased ".ext" -> candidates (keys live in the arena)
	ordered:           [dynamic]^Entry, // registration order (registry arena)

	// Probe caches shared by the resolver procs (python module imports
	// spawn a subprocess; caching keeps the cost to once per process,
	// success and failure alike). The registry is owned by one daemon;
	// the mutex only guards these lazily filled caches — probes build
	// their argv on scratch and clone the winner into the arena under the
	// lock, so nothing but the guarded stores touches the arena.
	mu:                sync.Mutex,
	is_pyright_probed: bool,
	pyright_argv:      []string, // arena-owned; valid when is_pyright_ok
	is_pyright_ok:     bool,
	is_msl_probed:     bool,
	msl_argv:          []string, // arena-owned; valid when is_msl_ok
	is_msl_ok:         bool,
}

// registry_build assembles the full language table. Call once per
// process (daemon startup) and destroy with registry_destroy.
registry_build :: proc(a := context.allocator) -> ^Registry {
	reg := new(Registry, a)
	reg^ = {
		owner = a,
	}
	mem.dynamic_arena_init(&reg.arena, a)
	reg.allocator = mem.dynamic_arena_allocator(&reg.arena)
	reg.entries = make(map[string]^Entry, 64, reg.allocator)
	reg.by_ext = make(map[string][]^Entry, 64, reg.allocator)
	reg.ordered = make([dynamic]^Entry, 0, 64, reg.allocator)
	register_major_entries(reg)
	register_jvm_entries(reg)
	register_system_entries(reg)
	register_scripting_entries(reg)
	register_shell_entries(reg)
	register_niche_entries(reg)
	register_data_entries(reg)
	return reg
}

// registry_destroy is a single wholesale free: every table, key, entry,
// and cached argv lives in the arena. Borrowers (the manager's servers)
// must already be gone — the daemon's teardown stops the manager first.
registry_destroy :: proc(reg: ^Registry) {
	mem.dynamic_arena_destroy(&reg.arena)
	free(reg, reg.owner)
}

// registry_add copies the entry's owned strings and slices into the
// registry allocator (copy-in: the caller's literals may live on its
// stack or arena) and indexes the pure-extension patterns. A duplicate
// id is a startup invariant violation.
registry_add :: proc(reg: ^Registry, e: Entry) -> ^Entry {
	if _, exists := reg.entries[e.id]; exists {
		panic("langserver: language already registered")
	}
	stored := new(Entry, reg.allocator)
	stored^ = {
		id                      = strings.clone(e.id, reg.allocator),
		display_name            = strings.clone(e.display_name, reg.allocator),
		file_patterns           = clone_strings(e.file_patterns, reg.allocator),
		root_markers            = clone_strings(e.root_markers, reg.allocator),
		multi_root              = e.multi_root,
		config_note_files       = clone_strings(e.config_note_files, reg.allocator),
		config_note_option_keys = clone_strings(e.config_note_option_keys, reg.allocator),
		config_note             = strings.clone(e.config_note, reg.allocator),
		priority                = e.priority,
		experimental            = e.experimental,
		command                 = strings.clone(e.command, reg.allocator),
		args                    = clone_strings(e.args, reg.allocator),
		env                     = clone_env(e.env, reg.allocator),
		memory_limit_mb         = e.memory_limit_mb,
		init_options_json       = strings.clone(e.init_options_json, reg.allocator),
		required_binaries       = clone_binaries(e.required_binaries, reg.allocator),
		required_any_of         = clone_any_ofs(e.required_any_of, reg.allocator),
		check_runtime           = e.check_runtime,
		resolve_command         = e.resolve_command,
		extra_path_dirs         = e.extra_path_dirs,
		config_item             = e.config_item,
		normalize               = e.normalize,
		install_hint            = strings.clone(e.install_hint, reg.allocator),
	}
	reg.entries[stored.id] = stored
	append(&reg.ordered, stored)
	for pat in stored.file_patterns {
		// Only "*.ext" patterns feed the extension index; the rest are
		// matched by registry_detect_filename's suffix walk.
		if len(pat) > 2 && pat[0] == '*' && pat[1] == '.' {
			// The lowercase clone becomes the map key's storage; it lives
			// in the arena, which outlives the map by construction.
			ext := strings.to_lower(pat[1:], reg.allocator)
			index_extension(reg, ext, stored)
		}
	}
	return stored
}

// index_extension grows a by_ext bucket through the registry allocator
// (map values are not addressable, so the bucket is rebuilt per append —
// the table is built once, so the quadratic cost is irrelevant).
index_extension :: proc(reg: ^Registry, ext: string, e: ^Entry) {
	lst := reg.by_ext[ext]
	grown := make([]^Entry, len(lst) + 1, reg.allocator)
	for item, i in lst {
		grown[i] = item
	}
	grown[len(lst)] = e
	reg.by_ext[ext] = grown
}

registry_count :: proc(reg: ^Registry) -> int {
	return len(reg.entries)
}

// registry_find returns the entry for an id, or nil when unregistered —
// lookups never panic (user input reaches this path).
registry_find :: proc(reg: ^Registry, id: string) -> ^Entry {
	return reg.entries[id]
}

// registry_detect maps a file path to the best non-experimental entry
// for its extension (highest priority wins); nil when nothing matches.
registry_detect :: proc(reg: ^Registry, file_path: string) -> ^Entry {
	ext := path_extension(file_path)
	if ext == "" {
		return nil
	}
	lower := strings.to_lower(ext, context.temp_allocator)
	candidates, ok := reg.by_ext[lower]
	if !ok {
		return nil
	}
	best: ^Entry = nil
	for c in candidates {
		if c.experimental {
			continue
		}
		if best == nil || c.priority > best.priority {
			best = c
		}
	}
	return best
}

// registry_detect_filename matches the basename against every pattern
// (suffix glob), not just pure extensions; highest priority wins.
registry_detect_filename :: proc(reg: ^Registry, filename: string) -> ^Entry {
	base := path_basename(filename)
	best: ^Entry = nil
	for e in reg.ordered {
		if e.experimental {
			continue
		}
		if entry_matches_file(e, base) {
			if best == nil || e.priority > best.priority {
				best = e
			}
		}
	}
	return best
}

// entry_matches_file reports whether the basename matches any pattern.
// Every registered pattern is a "*<suffix>" glob, so suffix comparison
// is exact for the data this registry carries.
entry_matches_file :: proc(e: ^Entry, base: string) -> bool {
	for pat in e.file_patterns {
		if len(pat) >= 1 && pat[0] == '*' {
			if strings.has_suffix(base, pat[1:]) {
				return true
			}
		} else if pat == base {
			return true
		}
	}
	return false
}

// entry_matches_extension reports whether the entry has a pure-extension
// pattern equal to ext (leading dot optional; case-insensitive).
entry_matches_extension :: proc(e: ^Entry, ext_in: string) -> bool {
	if ext_in == "" {
		return false
	}
	ext := ext_in
	if ext[0] != '.' {
		ext = strings.concatenate({".", ext_in}, context.temp_allocator)
	}
	for pat in e.file_patterns {
		if len(pat) > 1 && pat[0] == '*' && strings.equal_fold(pat[1:], ext) {
			return true
		}
	}
	return false
}

// registry_all_ids returns every registered id, sorted. Caller frees the
// slice (strings are clones owned by it).
registry_all_ids :: proc(reg: ^Registry, a := context.allocator) -> []string {
	ids := make([dynamic]string, 0, len(reg.entries), a)
	for id in reg.entries {
		append(&ids, strings.clone(id, a))
	}
	sort_strings(ids[:])
	return ids[:]
}

// registry_non_experimental returns all non-experimental entries sorted
// by display name. The slice is registry data (borrowed entries); the
// caller frees only the slice itself.
registry_non_experimental :: proc(reg: ^Registry, a := context.allocator) -> []^Entry {
	out := make([dynamic]^Entry, 0, len(reg.entries), a)
	for _, e in reg.entries {
		if !e.experimental {
			append(&out, e)
		}
	}
	slice := out[:]
	sort_entries_by_display(slice)
	return slice
}

// registry_filter_registered keeps only the ids present in the registry,
// preserving order. Caller frees the slice.
registry_filter_registered :: proc(reg: ^Registry, ids: []string, a := context.allocator) -> []string {
	out := make([dynamic]string, 0, len(ids), a)
	for id in ids {
		if reg.entries[id] != nil {
			append(&out, strings.clone(id, a))
		}
	}
	return out[:]
}

// --- clone/free helpers ------------------------------------------------------

clone_strings :: proc(src: []string, a: mem.Allocator) -> []string {
	if src == nil {
		return nil
	}
	out := make([]string, len(src), a)
	for s, i in src {
		out[i] = strings.clone(s, a)
	}
	return out
}

free_strings :: proc(src: []string, a: mem.Allocator) {
	if src == nil {
		return
	}
	for s in src {
		delete(s, a)
	}
	delete(src, a)
}

// clone_string_array_map deep-copies a {key → argv} map (keys, slices,
// and strings) into `a`.
clone_string_array_map :: proc(src: map[string][]string, a: mem.Allocator) -> map[string][]string {
	out := make(map[string][]string, len(src), a)
	for k, argv in src {
		out[strings.clone(k, a)] = clone_strings(argv, a)
	}
	return out
}

// free_owned_string_keys frees a map whose string keys are owned clones
// and whose values are plain data, in the collect-then-free order:
// freeing the current key mid-iteration is treated as map mutation
// (conn_destroy's rule), so the map dies before its key bytes do.
free_owned_string_keys :: proc(m: ^map[string]$V, a: mem.Allocator) {
	keys := make([dynamic]string, 0, len(m^), context.temp_allocator)
	for k in m^ {
		append(&keys, k)
	}
	delete(m^)
	for k in keys {
		delete(k, a)
	}
	delete(keys)
}

free_string_array_map :: proc(src: map[string][]string, a: mem.Allocator) {
	if src == nil {
		return
	}
	// Collect then free (freeing the current key mid-iteration is treated
	// as map mutation — conn_destroy's rule): the argv arrays and the
	// owned keys die only after the map does.
	keys := make([dynamic]string, 0, len(src), context.temp_allocator)
	argvs := make([dynamic][]string, 0, len(src), context.temp_allocator)
	for k, argv in src {
		append(&keys, k)
		append(&argvs, argv)
	}
	delete(src)
	for argv in argvs {
		free_strings(argv, a)
	}
	for k in keys {
		delete(k, a)
	}
	delete(keys)
	delete(argvs)
}

// clone_string_map deep-copies a {key → string} map (keys and values)
// into `a`.
clone_string_map :: proc(src: map[string]string, a: mem.Allocator) -> map[string]string {
	out := make(map[string]string, len(src), a)
	for k, v in src {
		out[strings.clone(k, a)] = strings.clone(v, a)
	}
	return out
}

free_string_map :: proc(src: map[string]string, a: mem.Allocator) {
	if src == nil {
		return
	}
	// Collect then free, the free_string_array_map order: keys and values
	// die only after the map does.
	keys := make([dynamic]string, 0, len(src), context.temp_allocator)
	vals := make([dynamic]string, 0, len(src), context.temp_allocator)
	for k, v in src {
		append(&keys, k)
		append(&vals, v)
	}
	delete(src)
	for v in vals {
		delete(v, a)
	}
	for k in keys {
		delete(k, a)
	}
	delete(keys)
	delete(vals)
}

clone_env :: proc(src: []Env_Var, a: mem.Allocator) -> []Env_Var {
	if src == nil {
		return nil
	}
	out := make([]Env_Var, len(src), a)
	for v, i in src {
		out[i] = {
			key   = strings.clone(v.key, a),
			value = strings.clone(v.value, a),
		}
	}
	return out
}

clone_binaries :: proc(src: []Binary_Req, a: mem.Allocator) -> []Binary_Req {
	if src == nil {
		return nil
	}
	out := make([]Binary_Req, len(src), a)
	for r, i in src {
		out[i] = {
			name         = strings.clone(r.name, a),
			display_name = strings.clone(r.display_name, a),
		}
	}
	return out
}

clone_any_ofs :: proc(src: []Any_Of_Req, a: mem.Allocator) -> []Any_Of_Req {
	if src == nil {
		return nil
	}
	out := make([]Any_Of_Req, len(src), a)
	for r, i in src {
		out[i] = {
			names        = clone_strings(r.names, a),
			display_name = strings.clone(r.display_name, a),
		}
	}
	return out
}

// path_extension returns the suffix from the final dot of the basename
// (including the dot), or "" when there is none.
path_extension :: proc(path: string) -> string {
	base := path_basename(path)
	for i := len(base) - 1; i >= 0; i -= 1 {
		if base[i] == '.' {
			return base[i:]
		}
	}
	return ""
}

path_basename :: proc(path: string) -> string {
	start := 0
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			start = i + 1
			break
		}
	}
	return path[start:]
}

sort_strings :: proc(xs: []string) {
	sort.quick_sort(xs)
}

sort_entries_by_display :: proc(xs: []^Entry) {
	ctx := Entries_Sort_Ctx{xs = xs}
	sort.sort({len = se_len, less = se_less, swap = se_swap, collection = &ctx})
}

Entries_Sort_Ctx :: struct {
	xs: []^Entry,
}

se_len :: proc(it: sort.Interface) -> int {
	c := cast(^Entries_Sort_Ctx)it.collection
	return len(c.xs)
}

se_less :: proc(it: sort.Interface, i, j: int) -> bool {
	c := cast(^Entries_Sort_Ctx)it.collection
	return c.xs[i].display_name < c.xs[j].display_name
}

se_swap :: proc(it: sort.Interface, i, j: int) {
	c := cast(^Entries_Sort_Ctx)it.collection
	c.xs[i], c.xs[j] = c.xs[j], c.xs[i]
}
