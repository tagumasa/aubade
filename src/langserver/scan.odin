// Project language detection: a bounded directory walk that classifies
// files by extension and returns the language ids ordered by file count
// (descending). This feeds the project.jsonc language_servers allowlist
// at init time. The walk resolves the project's managed state directory
// and skips it by location — its files (memories, generated state) are
// aubade's own, not project sources, wherever the folder template placed
// the directory.
package langserver

import "core:os"
import "core:path/filepath"
import "core:sort"
import "core:strings"

import "src:config"
import "src:platform"

SCAN_MAX_DEPTH :: 32

Scan_Result :: struct {
	// ids are the detected language ids ordered by descending file count
	// (ties break by id ascending); owned by the caller's allocator.
	ids:    []string,
	counts: map[string]int, // same allocator; ids are the keys that made the cut
}

// scan_project_languages walks the project root, classifying every file
// through the registry's extension detection, and returns the languages
// ordered by file count. Symlinks are not followed. The result and its
// strings/map are owned by `a`.
scan_project_languages :: proc(root: string, reg: ^Registry, a := context.allocator) -> Scan_Result {
	counts := make(map[string]int, 16, context.temp_allocator)
	managed := config.managed_dir_for_root(root, platform.aubade_home(context.temp_allocator), context.temp_allocator)
	scan_walk(root, reg, counts, 0, managed)
	res := Scan_Result{}
	res.counts = make(map[string]int, len(counts), a)
	for id, n in counts {
		res.counts[strings.clone(id, a)] = n
	}
	delete(counts)

	pairs := make([dynamic]Scan_Pair, 0, len(res.counts), context.temp_allocator)
	for id, n in res.counts {
		append(&pairs, Scan_Pair{id = id, n = n})
	}
	pp := Scan_Pairs_Ctx{xs = pairs}
	sort.sort({len = sp_len, less = sp_less, swap = sp_swap, collection = &pp})
	ids := make([dynamic]string, 0, len(pairs), a)
	for p in pairs {
		append(&ids, strings.clone(p.id, a))
	}
	res.ids = ids[:]
	return res
}

Scan_Pair :: struct {
	id: string,
	n:  int,
}

// scan_walk classifies every file under dir. `managed` is the project's
// resolved state directory (possibly nonexistent): it is skipped by
// location so state files never count as project sources.
scan_walk :: proc(dir: string, reg: ^Registry, counts_in: map[string]int, depth: int, managed: string) {
	counts := counts_in // procedure parameters are immutable; the local mutates the same backing
	if depth > SCAN_MAX_DEPTH {
		return
	}
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	for e in entries {
		name := e.name
		if name == "" || name == "." || name == ".." {
			continue
		}
		#partial switch e.type {
		case .Directory:
			if !config.default_ignored_dir(name) {
				child, _ := filepath.join({dir, name}, context.temp_allocator)
				if !platform.path_equal(child, managed) {
					scan_walk(child, reg, counts, depth + 1, managed)
				}
			}
		case .Regular:
			if entry := registry_detect(reg, name); entry != nil {
				counts[entry.id] = counts[entry.id] + 1
			}
		case:
		}
	}
	os.file_info_slice_delete(entries, context.temp_allocator)
}

Scan_Pairs_Ctx :: struct {
	xs: [dynamic]Scan_Pair,
}

sp_len :: proc(it: sort.Interface) -> int {
	c := cast(^Scan_Pairs_Ctx)it.collection
	return len(c.xs)
}

sp_less :: proc(it: sort.Interface, i, j: int) -> bool {
	c := cast(^Scan_Pairs_Ctx)it.collection
	if c.xs[i].n != c.xs[j].n {
		return c.xs[i].n > c.xs[j].n
	}
	return c.xs[i].id < c.xs[j].id
}

sp_swap :: proc(it: sort.Interface, i, j: int) {
	c := cast(^Scan_Pairs_Ctx)it.collection
	c.xs[i], c.xs[j] = c.xs[j], c.xs[i]
}
