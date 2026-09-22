// projects.json — the machine-owned project registry. This is the ONE
// config-adjacent file aubade freely rewrites (atomic tmp+rename); user
// config files are never touched. Entries
// are normalized absolute roots, deduplicated and sorted on save.
package config

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "src:jsonutil"
import "src:platform"
import "src:util"

Registry :: struct {
	projects: []string, // normalized absolute roots, sorted, deduplicated
}

registry_load :: proc(home: string, a := context.allocator) -> (r: ^Registry, err: platform.Err) {
	r = new(Registry, a)
	r^ = {}
	path := platform.projects_registry_path(home, context.temp_allocator)
	switch util.read_gate(path, MAX_CONFIG_BYTES) {
	case .Too_Large:
		// Refuse rather than pretend the registry is empty: a save after an
		// empty-looking load would discard the (tampered or runaway) file's
		// entries.
		return nil, platform.Wrapped{
			kind = .Invalid,
			msg  = fmt.aprintf("projects.json exceeds the %d byte size limit", MAX_CONFIG_BYTES, allocator = a),
		}
	case .Missing, .Not_Regular:
		// Absent (or not a readable regular file): a fresh install simply
		// has no projects yet.
		return r, nil
	case .Ok:
	}
	data, derr := os.read_entire_file_from_path(path, context.temp_allocator)
	if derr != nil || len(data) == 0 {
		// Empty: a fresh install simply has no projects yet.
		return r, nil
	}
	// Depth/encoding guard before the parser: a tampered projects.json
	// must fail as "malformed", not crash on unbounded nesting.
	if !util.json_sanity_ok(data) {
		return nil, platform.Wrapped{
			kind = .Invalid,
			msg  = "projects.json is malformed",
		}
	}
	value, perr := json.parse_bytes(data, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	if perr != nil {
		// Keep the parse failure as the cause instead of dropping it —
		// err_message renders "projects.json is malformed: <detail>".
		// The chain link shares the caller's allocator: on this error
		// path r is nil, so `a` is the owning scope.
		cause := new(platform.Wrapped, a)
		cause^ = {
			kind = .Invalid,
			msg  = fmt.aprintf("json parse error: %v", perr, allocator = a),
		}
		return nil, platform.Wrapped{
			kind  = .Invalid,
			msg   = "projects.json is malformed",
			cause = cause,
		}
	}
	if v, found := jsonutil.obj_get(value, "projects"); found && v != nil {
		arr, is_arr := jsonutil.as_array(v)
		if !is_arr {
			return nil, platform.Wrapped{
				kind = .Invalid,
				msg  = "projects.json: \"projects\" expects an array of strings",
			}
		}
		list := make([]string, len(arr), a)
		for ev, i in arr {
			#partial switch x in ev {
			case json.String:
				list[i] = strings.clone(string(x), a)
			case:
				return nil, platform.Wrapped{
					kind = .Invalid,
					msg  = "projects.json: \"projects\" expects an array of strings",
				}
			}
		}
		r.projects = list
	}
	return r, nil
}

// registry_save normalizes (clean + absolutize), deduplicates, and sorts the
// entries, then writes them atomically. The registry in memory is not
// modified — re-load to observe the normalized form.
registry_save :: proc(home: string, entries: []string) -> platform.Err {
	normalized := make([dynamic]string, 0, len(entries), context.temp_allocator)
	for e in entries {
		if n, ok := platform.normalize_project_root(e, context.temp_allocator); ok {
			append(&normalized, n)
		}
	}
	// Deduplicate (post-normalization) and sort.
	unique := make([dynamic]string, 0, len(normalized), context.temp_allocator)
	for n in normalized {
		dup := false
		for u in unique {
			if u == n {
				dup = true
				break
			}
		}
		if !dup {
			append(&unique, n)
		}
	}
	for i in 1..<len(unique) {
		k := unique[i]
		j := i - 1
		for j >= 0 && unique[j] > k {
			unique[j + 1] = unique[j]
			j -= 1
		}
		unique[j + 1] = k
	}

	buf := make([dynamic]u8, 0, 64, context.temp_allocator)
	append(&buf, "{\"projects\": [")
	for u, i in unique {
		if i > 0 {
			append(&buf, ", ")
		}
		quoted := json_quote(u, context.temp_allocator)
		append(&buf, quoted)
		delete(quoted, context.temp_allocator)
	}
	append(&buf, "]}")
	body := string(buf[:])

	path := platform.projects_registry_path(home, context.temp_allocator)
	return platform.atomic_write(path, transmute([]u8)body, os.Permissions{.Read_User, .Write_User})
}

registry_destroy :: proc(r: ^Registry, a := context.allocator) {
	for p in r.projects {
		delete(p, a)
	}
	if r.projects != nil {
		delete(r.projects, a)
	}
	free(r, a)
}
