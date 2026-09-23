// Workspace root detection for multi-root entries: a bounded walk that
// collects every directory under the project root holding one of the
// entry's root markers (a Go module, a repository checkout). Markers may
// nest — submodules inside repositories, testdata modules inside
// modules — and overlapping folders are all collected; how a server
// reconciles them is its own convention. The walk skips the same
// default-ignored directories as language detection plus the project's
// managed state directory (by location — machine state must never
// surface as a workspace folder) and does not read .gitignore files
// (marker directories of ignored trees stay findable — a deliberate
// limitation that keeps the walk O(entries), not O(patterns × entries)).
package langserver

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:sort"
import "core:strings"

import "src:config"
import "src:platform"
import "src:util"

ROOT_SCAN_MAX_DEPTH   :: 6
ROOT_SCAN_MAX_VISITED :: 2048
MAX_WORKSPACE_FOLDERS :: 8

// Workspace_Folder is one directory handed to a server at initialize.
// path is the absolute directory; uri and name are derived once so every
// consumer (the wire params, status rows) shares one spelling.
Workspace_Folder :: struct {
	path: string,
	uri:  string,
	name: string,
}

// scan_language_roots returns the workspace folder directories for a
// multi-root entry: every seed first (already validated as contained in
// the project root by the caller), then every marker directory found
// under root, sorted. Seed-first is deliberate — the first folder
// carries meaning for some servers (ols resolves its ols.json from
// folders[0]) — and the sorted tail keeps the order deterministic
// across sessions. Duplicates fold away, case-insensitively on
// filesystems where that is the comparison. No markers and no seeds
// resolve to the project root itself. The result is owned by `a`; all
// walk scratch stays on the temp allocator.
scan_language_roots :: proc(root: string, markers: []string, seeds: []string, a := context.allocator) -> []string {
	if len(markers) == 0 && len(seeds) == 0 {
		single := [1]string{root}
		return clone_strings(single[:], a)
	}

	ctx := Roots_Scan{
		markers = markers,
		managed = config.managed_dir_for_root(root, platform.aubade_home(context.temp_allocator), context.temp_allocator),
	}
	ctx.found = make([dynamic]string, 0, MAX_WORKSPACE_FOLDERS, context.temp_allocator)
	roots_visit(root, &ctx, 0)
	discovered := ctx.found[:]
	sort.quick_sort(discovered)

	out := make([dynamic]string, 0, MAX_WORKSPACE_FOLDERS, a)
	seen := make(map[string]bool, MAX_WORKSPACE_FOLDERS, context.temp_allocator)
	dropped := 0
	add_root :: proc(out: ^[dynamic]string, seen: ^map[string]bool, dir: string, dropped: ^int, a: mem.Allocator) {
		if len(out^) >= MAX_WORKSPACE_FOLDERS {
			dropped^ += 1
			return
		}
		key := fold_dir_key(dir)
		if seen^[key] {
			return
		}
		seen^[key] = true
		append(&out^, strings.clone(dir, a))
	}
	for s in seeds {
		add_root(&out, &seen, s, &dropped, a)
	}
	for d in discovered {
		add_root(&out, &seen, d, &dropped, a)
	}
	delete(ctx.found)
	delete(seen)

	if dropped > 0 {
		util.log_warning(strings.concatenate(
			{
				"langserver: workspace root scan found more roots than the cap allows; dropped ",
				util.int_to_dec(dropped, context.temp_allocator),
			},
			context.temp_allocator,
		))
	}
	if len(out) == 0 {
		delete(out)
		single := [1]string{root}
		return clone_strings(single[:], a)
	}
	return out[:]
}

Roots_Scan :: struct {
	markers: []string,
	managed: string,       // the project's resolved state directory — never a workspace folder
	found:   [dynamic]string, // temp-owned views of the walked directories
	visited: int,
}

// roots_visit walks one directory: it records `dir` when a marker entry
// is present, recurses into non-ignored child directories, and stops at
// the depth/visit/folder caps. Marker entries themselves are never
// descended (".git" names its parent, not a subtree to scan).
roots_visit :: proc(dir: string, ctx: ^Roots_Scan, depth: int) {
	if depth > ROOT_SCAN_MAX_DEPTH || ctx.visited >= ROOT_SCAN_MAX_VISITED || len(ctx.found) >= MAX_WORKSPACE_FOLDERS {
		return
	}
	ctx.visited += 1
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	marked := false
	for e in entries {
		name := e.name
		if name == "" || name == "." || name == ".." {
			continue
		}
		if is_root_marker(name, ctx.markers) {
			marked = true
			continue
		}
		#partial switch e.type {
		case .Directory:
			if !config.default_ignored_dir(name) {
				child, _ := filepath.join({dir, name}, context.temp_allocator)
				if !platform.path_equal(child, ctx.managed) {
					roots_visit(child, ctx, depth + 1)
				}
			}
		case:
		}
	}
	os.file_info_slice_delete(entries, context.temp_allocator)
	if marked {
		append(&ctx.found, dir)
	}
}

// A marker matches the directory entry's ACTUAL spelling — and on
// case-insensitive filesystems (Darwin/Windows) a file created as GO.mod
// IS the go.mod file, so the comparison folds case there (the same
// spelling rule as fold_dir_key below). Linux keeps the exact compare: a
// differently-cased name there is a genuinely different file.
is_root_marker :: proc(name: string, markers: []string) -> bool {
	for m in markers {
		when ODIN_OS == .Darwin || ODIN_OS == .Windows {
			if strings.equal_fold(m, name) {
				return true
			}
		} else {
			if m == name {
				return true
			}
		}
	}
	return false
}

// fold_dir_key builds the dedup key for a directory path: exact on
// case-sensitive filesystems, ASCII-folded on macOS/Windows — the same
// spelling rule the daemon project id uses. The key is a view on Linux
// and a temp-owned lowercase clone elsewhere; either way its lifetime
// only needs to outlive the map it keys.
fold_dir_key :: proc(p: string) -> string {
	when ODIN_OS == .Darwin || ODIN_OS == .Windows {
		return strings.to_lower(p, context.temp_allocator)
	} else {
		return p
	}
}
