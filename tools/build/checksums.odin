// The vendored-tree checksum registry: third_party/CHECKSUMS.txt pins the
// committed bytes of the vendored C trees. lexbor is not covered — its
// revision is the third_party/lexbor submodule gitlink, which git itself
// enforces. `emit-checksums` regenerates the registry after an intentional
// tree change (version bump, licence addition); `verify-checksums` walks
// the trees and reports any drift — a file that is missing, unregistered,
// or changed — so accidental edits surface instead of silently becoming
// part of the build.
package build

import "core:crypto/sha2"
import "core:log"
import "core:os"
import "core:strings"

CHECKSUMS_FILE :: "third_party/CHECKSUMS.txt"

// The trees the registry covers. lexbor is deliberately absent: its pin is
// the submodule gitlink under third_party/lexbor.
CHECKSUM_TREES :: []string{
	"third_party/sqlite",
	"third_party/pcre2",
	"third_party/tree-sitter-perl",
}

HEX_DIGITS :: "0123456789abcdef"

emit_checksums :: proc() -> (ok: bool) {
	root := repo_root()

	paths: [dynamic]string
	defer {
		for p in paths {
			delete(p, context.allocator)
		}
		delete(paths)
	}
	for tree in CHECKSUM_TREES {
		if !collect_tree_files(join_path(root, tree), &paths) {
			return false
		}
	}

	lines := strings.builder_make_len_cap(0, len(paths) * 96, context.allocator)
	defer strings.builder_destroy(&lines)
	for path in paths {
		digest, dok := file_sha256(path)
		if !dok {
			return false
		}
		strings.write_string(&lines, hex_encode(digest))
		strings.write_string(&lines, "  ")
		strings.write_string(&lines, repo_relative(root, path))
		strings.write_byte(&lines, '\n')
	}
	out := join_path(root, CHECKSUMS_FILE)
	if err := os.write_entire_file(out, lines.buf[:]); err != nil {
		log.errorf("could not write %q: %s", out, os.error_string(err))
		return false
	}
	log.infof("wrote %d file checksums to %q", len(paths), out)
	return true
}

verify_checksums :: proc() -> (ok: bool) {
	root := repo_root()
	reg_path := join_path(root, CHECKSUMS_FILE)
	data, err := os.read_entire_file(reg_path, context.allocator)
	if err != nil {
		log.errorf(
			"could not read %q (generate it with: odin run tools/build -- emit-checksums): %s",
			reg_path,
			os.error_string(err),
		)
		return false
	}
	defer delete(data, context.allocator)

	// Keys are views into `data`, which outlives both maps; everything
	// dies at procedure exit.
	expected := make(map[string][32]u8, 256, context.allocator)
	defer delete(expected)
	if !parse_registry(data, &expected) {
		return false
	}

	paths: [dynamic]string
	defer {
		for p in paths {
			delete(p, context.allocator)
		}
		delete(paths)
	}
	for tree in CHECKSUM_TREES {
		if !collect_tree_files(join_path(root, tree), &paths) {
			return false
		}
	}

	current := make(map[string][32]u8, len(expected), context.allocator)
	defer delete(current)
	for path in paths {
		digest, dok := file_sha256(path)
		if !dok {
			return false
		}
		current[repo_relative(root, path)] = digest
	}

	problems: [dynamic]string
	defer {
		for p in problems {
			delete(p, context.allocator)
		}
		delete(problems)
	}
	for rel, digest in expected {
		cur, has := current[rel]
		if !has {
			append(&problems, strings.concatenate({"missing:      ", rel}, context.allocator))
		} else if cur != digest {
			append(&problems, strings.concatenate({"changed:      ", rel}, context.allocator))
		}
	}
	for rel, _ in current {
		if _, has := expected[rel]; !has {
			append(&problems, strings.concatenate({"unregistered: ", rel}, context.allocator))
		}
	}
	if len(problems) > 0 {
		sort_strings(&problems)
		for p in problems {
			log.errorf("%s", p)
		}
		log.errorf(
			"%d vendored file(s) drifted from %q — emit-checksums only after an intentional change",
			len(problems),
			reg_path,
		)
		return false
	}
	log.infof("verified %d files against %q", len(current), reg_path)
	return true
}

// parse_registry fills `out` with "<64-hex>  <repo-relative-path>" lines;
// blank lines and '#'-prefixed comments are skipped.
parse_registry :: proc(data: []u8, out: ^map[string][32]u8) -> bool {
	i := 0
	for i < len(data) {
		j := i
		for j < len(data) && data[j] != '\n' {
			j += 1
		}
		line := data[i:j]
		i = j + 1
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		if len(line) < 67 || line[64] != ' ' || line[65] != ' ' {
			log.errorf("malformed registry line (expected \"<64-hex>  <path>\"): %q", line)
			return false
		}
		digest, dok := hex_decode(line[:64])
		if !dok {
			log.errorf("malformed hex digest in registry line: %q", line)
			return false
		}
		out^ [string(line[66:])] = digest
	}
	return true
}

// collect_tree_files appends every regular file under `dir`, in
// lexicographic path order — read_directory_by_path does not guarantee an
// iteration order, and the registry must be byte-identical across runs.
collect_tree_files :: proc(dir: string, out: ^[dynamic]string) -> bool {
	entries, err := os.read_directory_by_path(dir, -1, context.allocator)
	if err != nil {
		log.errorf("could not list %q: %s", dir, os.error_string(err))
		return false
	}
	// Entry names are views into the entries array, which stays alive for
	// the whole procedure.
	names := make([dynamic]string, 0, len(entries), context.temp_allocator)
	is_dir := make([dynamic]bool, 0, len(entries), context.temp_allocator)
	defer {
		delete(names)
		delete(is_dir)
	}
	for e in entries {
		if e.name == "." || e.name == ".." {
			continue
		}
		append(&names, e.name)
		append(&is_dir, e.type == .Directory)
	}
	for i := 1; i < len(names); i += 1 {
		n := names[i]
		d := is_dir[i]
		j := i - 1
		for j >= 0 && names[j] > n {
			names[j + 1] = names[j]
			is_dir[j + 1] = is_dir[j]
			j -= 1
		}
		names[j + 1] = n
		is_dir[j + 1] = d
	}
	for i := 0; i < len(names); i += 1 {
		child := join_path(dir, names[i])
		if is_dir[i] {
			if !collect_tree_files(child, out) {
				return false
			}
		} else {
			append(out, child)
		}
	}
	return true
}

file_sha256 :: proc(path: string) -> (digest: [32]u8, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.errorf("could not read %q: %s", path, os.error_string(err))
		return
	}
	defer delete(data, context.temp_allocator)

	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, digest[:])
	return digest, true
}

// hex_encode returns an allocator-owned lowercase hex string — the digest
// bytes live on the caller's stack, so the view must be cloned out.
hex_encode :: proc(digest: [32]u8) -> string {
	hex_digits := HEX_DIGITS
	buf: [64]u8
	for i in 0..<32 {
		buf[i * 2] = hex_digits[digest[i] >> 4]
		buf[i * 2 + 1] = hex_digits[digest[i] & 0xf]
	}
	return strings.clone(string(buf[:]), context.allocator)
}

hex_decode :: proc(hex: []u8) -> (digest: [32]u8, ok: bool) {
	if len(hex) != 64 {
		return
	}
	for i in 0..<32 {
		hi, hok := hex_nibble(hex[i * 2])
		lo, lok := hex_nibble(hex[i * 2 + 1])
		if !hok || !lok {
			return
		}
		digest[i] = hi << 4 | lo
	}
	return digest, true
}

hex_nibble :: proc(c: u8) -> (v: u8, ok: bool) {
	if c >= '0' && c <= '9' {
		return c - '0', true
	}
	if c >= 'a' && c <= 'f' {
		return c - 'a' + 10, true
	}
	return
}

// repo_relative strips the repo-root prefix and normalizes to forward
// slashes so the registry is identical on every platform.  Both root and
// path are normalized to forward slashes before prefix comparison because
// filepath.join on Windows produces backslash paths while #file (and
// therefore repo_root()) may use forward slashes.
repo_relative :: proc(root, path: string) -> string {
	r := normalize_slashes(root)
	p := normalize_slashes(path)
	assert(strings.has_prefix(p, r) && len(p) > len(r))
	rel := p[len(r) + 1:]
	return strings.clone(rel, context.allocator)
}

normalize_slashes :: proc(s: string) -> string {
	if !strings.contains(s, "\\") {
		return s
	}
	normalized := make([dynamic]u8, 0, len(s), context.allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == '\\' {
			c = '/'
		}
		append(&normalized, c)
	}
	res := strings.clone(string(normalized[:]), context.allocator)
	delete(normalized)
	return res
}
