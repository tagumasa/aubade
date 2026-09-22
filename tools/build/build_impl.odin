// Core and grammar build steps. Each step is skipped when its artifact
// already exists, so reruns only build what is missing; `clean` starts over.
package build

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

repo_root :: proc() -> string {
	// tools/build/build_impl.odin -> repository root
	return filepath.dir(filepath.dir(filepath.dir(#file)))
}

target_dir :: proc() -> string {
	os_part: string
	when ODIN_OS == .Windows {
		os_part = "windows"
	} else when ODIN_OS == .Darwin {
		os_part = "darwin"
	} else when ODIN_OS == .Linux {
		os_part = "linux"
	} else {
		os_part = "unknown_os"
	}
	arch_part: string
	when ODIN_ARCH == .amd64 {
		arch_part = "amd64"
	} else when ODIN_ARCH == .arm64 {
		arch_part = "arm64"
	} else {
		arch_part = "unknown_arch"
	}
	return strings.concatenate({os_part, "_", arch_part})
}

lib_ext :: proc() -> string {
	when ODIN_OS == .Windows {
		return ".lib"
	} else {
		return ".a"
	}
}

lib_dir :: proc() -> string {
	return join_path(repo_root(), "lib", target_dir())
}

cache_dir :: proc() -> string {
	return join_path(repo_root(), "tools", "build", "cache")
}

install_core :: proc() -> bool {
	ok := install_tree_sitter()
	ok = install_sqlite() && ok
	ok = install_pcre2() && ok
	ok = install_lexbor() && ok
	return ok
}

install_parsers :: proc(langs: []string) -> bool {
	selected: [dynamic]Grammar_Desc

	if len(langs) == 0 {
		for g in GRAMMARS {
			append(&selected, g)
		}
	} else {
		for lang in langs {
			trimmed := strings.trim_space(lang)
			if trimmed == "" {
				continue
			}
			if g, ok := find_grammar(trimmed); ok {
				append(&selected, g)
			} else {
				log.errorf("unknown grammar %q (see tools/build/grammars.odin)", trimmed)
				return false
			}
		}
	}

	any_built := false
	ok_count := 0
	skipped: [dynamic]string
	defer delete(skipped)
	for g in selected {
		gok, built := install_parser(g)
		if !gok {
			log.warnf("grammar %q failed to install, skipping (scanner may be incompatible with MSVC)", g.name)
			// The registry table imports every grammars:<name> package
			// unconditionally, so a failed install must still leave a
			// resolvable package behind — otherwise every later compile
			// dies on an empty package directory.
			if !write_stub_binding(g) {
				return false
			}
			append(&skipped, g.name)
			continue
		}
		ok_count += 1
		any_built = any_built || built
	}
	if len(skipped) > 0 {
		log.warnf("skipped %d grammars: %s", len(skipped), strings.join(skipped[:], ", "))
	}
	if ok_count == 0 && len(selected) > 0 {
		// Every selected grammar failed — nothing to archive. (Judged by
		// the installed count, not by "something new was built": a fully
		// cached rerun builds nothing, and one failing grammar must not
		// fail a run whose archive is already complete.)
		log.errorf("all %d selected grammars failed to install", len(selected))
		return false
	}

	// The shared grammar archive is derived state: recreate it fresh from
	// every persisted object whenever anything changed or it is missing.
	// lib.exe quietly drops merge-style updates that feed the output back
	// in as an input (exiting 0 while leaving the target stale or absent),
	// and `ar cr` overwrites wholesale anyway.
	merged_path := join_path(lib_dir(), strings.concatenate({"libtree-sitter-grammars", lib_ext()}))
	if any_built || !os.exists(merged_path) {
		objs := make([dynamic]string, 0, 512, context.allocator)
		defer {
			for o in objs {
				delete(o, context.allocator)
			}
			delete(objs)
		}
		if !collect_grammar_objs(join_path(lib_dir(), "grammars"), &objs) {
			return false
		}
		if len(objs) == 0 {
			log.errorf("no grammar objects found under %q to archive", join_path(lib_dir(), "grammars"))
			return false
		}
		if !archive_objs(merged_path, ..objs[:]) {
			return false
		}
		log.infof("archived %d grammar objects into %q", len(objs), merged_path)
	}

	// Verification pass: a partially-written collection must fail here,
	// loudly, with the filesystem reason. Trusting file existence alone
	// lets a tree whose tail grammars are empty or missing pass as fully
	// installed and surface much later as unresolved `grammars:*` imports
	// in odin build. Grammars that were skipped (scanner incompatible)
	// verify their stub binding only — objects stay legitimately absent.
	ok := true
	is_skipped :: proc(name: string, skipped: []string) -> bool {
		for s in skipped {
			if s == name {
				return true
			}
		}
		return false
	}
	for g in selected {
		dest := join_path(lib_dir(), "grammars", g.name)
		binding_path := join_path(dest, strings.concatenate({g.name, ".odin"}))
		if bok, why := grammar_binding_ok(binding_path); !bok {
			log.errorf("grammar %q binding %q is not usable: %s", g.name, binding_path, why)
			ok = false
		}
		if is_skipped(g.name, skipped[:]) {
			continue
		}
		if !grammar_objs_present(dest) {
			log.errorf("grammar %q has no persisted objects under %q", g.name, grammar_obj_dir(dest))
			ok = false
		}
	}
	if !os.exists(merged_path) {
		log.errorf("shared grammar archive %q is missing", merged_path)
		ok = false
	}
	return ok
}

clean :: proc() -> bool {
	return rmrf(join_path(repo_root(), "lib"))
}

install_tree_sitter :: proc() -> (ok: bool) {
	dest := lib_dir()
	lib_path := join_path(dest, strings.concatenate({"libtree-sitter", lib_ext()}))
	if os.exists(lib_path) {
		log.infof("tree-sitter core already built at %q, skipping", lib_path)
		return true
	}

	src_dir := join_path(cache_dir(), "tree-sitter")
	if !os.exists(join_path(src_dir, "lib", "src", "lib.c")) {
		if !exec("git", "clone", "--depth=1", "--branch=" + TREE_SITTER_TAG, TREE_SITTER_REPO, src_dir) {
			return false
		}
	}
	defer rmrf(src_dir)

	if err := os.make_directory_all(dest); err != nil && err != .Exist {
		log.errorf("could not create %q: %s", dest, os.error_string(err))
		return false
	}

	obj := compile_c_file(
		join_path(src_dir, "lib", "src", "lib.c"),
		"tree-sitter.o",
		[]string{
			join_path(src_dir, "lib", "include"),
			join_path(src_dir, "lib", "src"),
			join_path(src_dir, "lib", "src", "wasm"),
		},
	)
	defer rmrf(obj)
	if obj == "" {
		return false
	}

	return archive_objs(lib_path, obj)
}

install_sqlite :: proc() -> (ok: bool) {
	dest := lib_dir()
	lib_path := join_path(dest, strings.concatenate({"sqlite3", lib_ext()}))
	if os.exists(lib_path) {
		log.infof("sqlite already built at %q, skipping", lib_path)
		return true
	}
	src := join_path(repo_root(), "third_party", "sqlite", "sqlite3.c")
	if !os.exists(src) {
		log.errorf("sqlite amalgamation missing at %q (vendored under third_party/sqlite)", src)
		return false
	}

	obj := compile_c_file(src, "sqlite3.o", nil)
	defer rmrf(obj)
	if obj == "" {
		return false
	}
	return archive_objs(lib_path, obj)
}

// PCRE2 8-bit + JIT, vendored pristine under third_party/pcre2 (see its
// README). The feature selection lives in the vendored config.h; the code
// unit width is a per-library define. Revisit this list, config.h, and the
// defines together when bumping the vendored version.
PCRE2_SOURCES :: []string{
	"pcre2_auto_possess.c",
	"pcre2_chartables.c",
	"pcre2_chkdint.c",
	"pcre2_compile.c",
	"pcre2_compile_cgroup.c",
	"pcre2_compile_class.c",
	"pcre2_config.c",
	"pcre2_context.c",
	"pcre2_convert.c",
	"pcre2_dfa_match.c",
	"pcre2_error.c",
	"pcre2_extuni.c",
	"pcre2_find_bracket.c",
	"pcre2_jit_compile.c",
	"pcre2_maketables.c",
	"pcre2_match.c",
	"pcre2_match_data.c",
	"pcre2_match_next.c",
	"pcre2_newline.c",
	"pcre2_ord2utf.c",
	"pcre2_pattern_info.c",
	"pcre2_script_run.c",
	"pcre2_serialize.c",
	"pcre2_string_utils.c",
	"pcre2_study.c",
	"pcre2_substitute.c",
	"pcre2_substring.c",
	"pcre2_tables.c",
	"pcre2_ucd.c",
	"pcre2_valid_utf.c",
	"pcre2_xclass.c",
}

install_pcre2 :: proc() -> (ok: bool) {
	dest := lib_dir()
	lib_path := join_path(dest, strings.concatenate({"pcre2-8", lib_ext()}))
	if os.exists(lib_path) {
		log.infof("pcre2 already built at %q, skipping", lib_path)
		return true
	}
	src_dir := join_path(repo_root(), "third_party", "pcre2", "src")
	if !os.exists(join_path(src_dir, "pcre2.h")) {
		log.errorf("pcre2 sources missing under %q (vendored in third_party/pcre2)", src_dir)
		return false
	}

	if err := os.make_directory_all(dest); err != nil && err != .Exist {
		log.errorf("could not create %q: %s", dest, os.error_string(err))
		return false
	}

	objs: [dynamic]string
	defer {
		for o in objs {
			rmrf(o)
		}
	}
	sources := PCRE2_SOURCES
	for i in 0..<len(sources) {
		name := sources[i]
		obj := compile_c_file(
			join_path(src_dir, name),
			strings.concatenate({name[:len(name) - 2], ".o"}),
			nil,
			[]string{"-DHAVE_CONFIG_H", "-DPCRE2_CODE_UNIT_WIDTH=8"},
		)
		if obj == "" {
			return false
		}
		append(&objs, obj)
	}
	return archive_objs(lib_path, ..objs[:])
}

// lexbor: the HTML5 parser behind web_fetch's readability conversion.
// third_party/lexbor is a git submodule pinned at the v2.3.0 tag; the HTML
// stack and the css and selectors trees it references compile directly with
// -DLEXBOR_STATIC (no cmake involved) — url/utils/wasm stay uncompiled —
// and only the current platform's port sources are included.
install_lexbor :: proc() -> (ok: bool) {
	dest := lib_dir()
	lib_path := join_path(dest, strings.concatenate({"liblexbor", lib_ext()}))
	if os.exists(lib_path) {
		log.infof("lexbor already built at %q, skipping", lib_path)
		return true
	}
	root := join_path(repo_root(), "third_party", "lexbor")
	src_root := join_path(root, "source")
	if !os.exists(join_path(src_root, "lexbor", "html", "html.h")) {
		log.errorf(
			"lexbor sources missing under %q (git submodule; run: git submodule update --init third_party/lexbor)",
			src_root,
		)
		return false
	}

	if err := os.make_directory_all(dest); err != nil && err != .Exist {
		log.errorf("could not create %q: %s", dest, os.error_string(err))
		return false
	}

	sources: [dynamic]string
	defer {
		for s in sources {
			delete(s, context.allocator)
		}
		delete(sources)
	}
	if !collect_c_sources(join_path(src_root, "lexbor"), &sources) {
		return false
	}

	objs: [dynamic]string
	defer {
		for o in objs {
			rmrf(o)
		}
	}
	for src in sources {
		obj_name := strings.clone(src, context.allocator)
		for i := 0; i < len(obj_name); i += 1 {
			if obj_name[i] == '/' || obj_name[i] == '\\' || obj_name[i] == ':' {
				obj_name = strings.clone(
					strings.concatenate({obj_name[:i], "_", obj_name[i + 1:]}, context.allocator),
					context.allocator,
				)
			}
		}
		obj := compile_c_file(
			src,
			strings.concatenate({obj_name[:len(obj_name) - 2], ".o"}),
			[]string{src_root},
			[]string{"-DLEXBOR_STATIC"},
		)
		delete(obj_name, context.allocator)
		if obj == "" {
			return false
		}
		append(&objs, obj)
	}
	return archive_objs(lib_path, ..objs[:])
}

LEXBOR_UNUSED_TREES :: []string{"url", "utils", "wasm"}

// collect_c_sources walks one directory tree gathering .c files, skipping
// the other platform's port sources (the lexbor ports ship both trees).
collect_c_sources :: proc(dir: string, out: ^[dynamic]string) -> bool {
	entries, err := os.read_directory_by_path(dir, -1, context.allocator)
	if err != nil {
		log.errorf("could not list %q: %s", dir, os.error_string(err))
		return false
	}
	for e in entries {
		if e.name == "." || e.name == ".." {
			continue
		}
		child := join_path(dir, e.name)
		if e.type == .Directory {
			skip_tree := false
			when ODIN_OS == .Windows {
				skip_tree = e.name == "posix"
			} else {
				skip_tree = e.name == "windows_nt"
			}
			// Only the HTML parser stack links: css, selectors, url,
			// utils, and wasm stay uncompiled (their headers are still
			// reachable through -I for the modules that reference them).
			for unused in LEXBOR_UNUSED_TREES {
				if e.name == unused {
					skip_tree = true
				}
			}
			if skip_tree {
				continue
			}
			if !collect_c_sources(child, out) {
				return false
			}
			continue
		}
		if strings.has_suffix(e.name, ".c") {
			append(out, strings.clone(child, context.allocator))
		}
	}
	os.file_info_slice_delete(entries, context.allocator)
	return true
}
// spelling depending on the grammar. The C++ spellings select the C++
// compiler so scanner objects link against the C++ runtime they expect.
// Scanner sources that may accompany a grammar's parser.c, in C or C++
// spelling depending on the grammar. The C++ spellings select the C++
// compiler so scanner objects link against the C++ runtime they expect.
SCANNER_SOURCE_NAMES :: []string{"scanner.c", "scanner.cc", "scanner.cpp", "scanner.cxx"}

// is_commit_sha reports whether a pin is a raw 40-hex commit id rather
// than a release tag; commit pins cannot go through clone --branch and
// need the fetch + checkout path instead.
is_commit_sha :: proc(pin: string) -> bool {
	if len(pin) != 40 {
		return false
	}
	for i in 0..<len(pin) {
		c := pin[i]
		is_hex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
		if !is_hex {
			return false
		}
	}
	return true
}

// clone_grammar checks out the grammar's pinned revision. Tag pins clone
// with --branch; commit pins clone the tip and fetch the exact commit
// (shallow when the server allows it, full clone as the fallback).
clone_grammar :: proc(g: Grammar_Desc, src_dir: string) -> bool {
	if !is_commit_sha(g.tag) {
		return exec("git", "clone", "--depth=1", strings.concatenate({"--branch=", g.tag}), g.repo, src_dir)
	}
	if !exec("git", "clone", "--depth=1", g.repo, src_dir) {
		if !exec("git", "clone", g.repo, src_dir) {
			return false
		}
	}
	if !exec("git", "-C", src_dir, "fetch", "--depth=1", "origin", g.tag) {
		if !exec("git", "-C", src_dir, "fetch", "origin", g.tag) {
			return false
		}
	}
	return exec("git", "-C", src_dir, "checkout", "--detach", g.tag)
}

// path_base returns the final component of a slash-separated path.
path_base :: proc(p: string) -> string {
	for i := len(p) - 1; i >= 0; i -= 1 {
		if p[i] == '/' || p[i] == '\\' {
			return p[i+1:]
		}
	}
	return p
}

// vendored_parser_path resolves the committed generated parser for
// grammars whose pinned revisions carry no parser.c (upstream builds via
// `tree-sitter generate`): third_party/<repo-name>/parser.c, keyed by
// the repository's base name. "" when the layout has no such directory.
vendored_parser_path :: proc(g: Grammar_Desc) -> string {
	repo := path_base(strings.trim_suffix(g.repo, "/"))
	if repo == "" || strings.has_prefix(repo, ".") {
		return ""
	}
	return join_path(repo_root(), "third_party", repo, "parser.c")
}

// grammar_obj_dir is where a grammar's compiled objects persist inside the
// cached lib/ tree; the shared archive is recreated from these, so they must
// outlive any single build run's scratch directory.
grammar_obj_dir :: proc(dest: string) -> string {
	return join_path(dest, "obj")
}

// grammar_binding_ok reports whether a generated binding is readable and
// carries content. os.exists alone is not enough: a run killed mid-write
// (or a copy with mangled permissions) leaves zero-byte or unreadable
// files that still exist, and such a shard must read as "not installed"
// so the next run rebuilds it instead of passing a broken collection to
// the compiler.
grammar_binding_ok :: proc(binding_path: string) -> (ok: bool, why: string) {
	data, err := os.read_entire_file(binding_path, context.temp_allocator)
	if err != nil {
		return false, os.error_string(err)
	}
	if len(data) == 0 {
		return false, "file is empty"
	}
	return true, ""
}

// grammar_binding_is_stub reports whether a binding is the nil-language
// stub write_stub_binding leaves behind for a grammar whose C sources
// failed to build. Real bindings always carry a foreign import of the
// shared grammar archive; the stub deliberately carries none.
grammar_binding_is_stub :: proc(binding_path: string) -> bool {
	data, err := os.read_entire_file(binding_path, context.temp_allocator)
	if err != nil {
		return false
	}
	return !strings.contains(transmute(string)data, "foreign import")
}

// grammar_objs_present reports whether dest carries at least one persisted
// object — together with a usable binding this is the installed marker
// for a grammar.
grammar_objs_present :: proc(dest: string) -> bool {
	obj_dir := grammar_obj_dir(dest)
	if !os.exists(obj_dir) {
		return false
	}
	entries, err := os.read_directory_by_path(obj_dir, -1, context.allocator)
	if err != nil {
		return false
	}
	defer os.file_info_slice_delete(entries, context.allocator)
	for e in entries {
		if strings.has_suffix(e.name, ".o") {
			return true
		}
	}
	return false
}

// collect_grammar_objs gathers every persisted grammar object under
// lib/<target>/grammars/*/obj/ — the complete input set of the shared
// archive.
collect_grammar_objs :: proc(grammars_root: string, out: ^[dynamic]string) -> bool {
	entries, err := os.read_directory_by_path(grammars_root, -1, context.allocator)
	if err != nil {
		log.errorf("could not list %q: %s", grammars_root, os.error_string(err))
		return false
	}
	defer os.file_info_slice_delete(entries, context.allocator)
	for e in entries {
		if e.name == "." || e.name == ".." || e.type != .Directory {
			continue
		}
		obj_dir := grammar_obj_dir(join_path(grammars_root, e.name))
		if !os.exists(obj_dir) {
			continue
		}
		oentries, oerr := os.read_directory_by_path(obj_dir, -1, context.allocator)
		if oerr != nil {
			continue
		}
		// A block-scoped defer: runs at each loop iteration's exit.
		defer os.file_info_slice_delete(oentries, context.allocator)
		for oe in oentries {
			if strings.has_suffix(oe.name, ".o") {
				append(out, join_path(obj_dir, oe.name))
			}
		}
	}
	return true
}

install_parser :: proc(g: Grammar_Desc) -> (ok: bool, built: bool) {
	dest := join_path(lib_dir(), "grammars", g.name)
	binding_path := join_path(dest, strings.concatenate({g.name, ".odin"}))
	// A grammar is installed when its binding and its persisted objects are
	// both in place; the shared archive is rebuilt from the objects
	// separately (see install_parsers). A stub binding does not count: it
	// marks a previous failure, so the grammar is retried (and the stub
	// replaced) on every run until it builds.
	if bok, _ := grammar_binding_ok(binding_path); bok && !grammar_binding_is_stub(binding_path) && grammar_objs_present(dest) {
		log.infof("grammar %q already installed at %q, skipping", g.name, dest)
		return true, false
	}

	src_dir := join_path(cache_dir(), "grammars", g.name)
	if !os.exists(src_dir) {
		if !clone_grammar(g, src_dir) {
			return false, false
		}
	}
	defer rmrf(src_dir)

	lang_dir := src_dir
	if g.path != "" {
		lang_dir = join_path(src_dir, g.path)
	}
	parser_src := join_path(lang_dir, "src")

	if err := os.make_directory_all(dest); err != nil && err != .Exist {
		log.errorf("could not create %q: %s", dest, os.error_string(err))
		return false, false
	}

	objs: [dynamic]string
	defer {
		for o in objs {
			rmrf(o)
		}
	}
	parser_c := join_path(parser_src, "parser.c")
	// The include path always carries the clone's src (scanner headers,
	// tree_sitter/parser.h); a vendored parser adds its own directory
	// (upstreams that never commit the runtime headers).
	includes := make([dynamic]string, 0, 2, context.allocator)
	append(&includes, parser_src)
	if !os.exists(parser_c) {
		// Grammars whose pinned revisions ship no parser.c (upstream
		// builds via `tree-sitter generate`) carry a vendored generated
		// parser under third_party/<repo-name>; the clone still supplies
		// the scanner, headers, and license.
		parser_c = vendored_parser_path(g)
		if parser_c == "" || !os.exists(parser_c) {
			log.errorf("grammar %q has no parser.c under %q and no vendored parser", g.name, parser_src)
			return false, false
		}
		log.infof("grammar %q uses the vendored parser.c %q", g.name, parser_c)
		append(&includes, filepath.dir(parser_c))
	}
	sources := make([dynamic]string, 0, 2, context.allocator)
	append(&sources, parser_c)
	scanners := SCANNER_SOURCE_NAMES
	for i in 0..<len(scanners) {
		scanner := scanners[i]
		if os.exists(join_path(parser_src, scanner)) {
			append(&sources, join_path(parser_src, scanner))
		}
	}
	for csrc in sources {
		base := path_base(csrc)
		is_cxx := !strings.has_suffix(base, ".c")
		obj := compile_c_file(csrc, strings.concatenate({g.name, "-", base[:len(base) - 2], ".o"}), includes[:], cxx = is_cxx)
		if obj == "" {
			return false, false
		}
		append(&objs, obj)
	}

	// Persist the objects inside the cached lib/ tree (replacing any stale
	// set left by an earlier revision of this grammar): the shared archive
	// is recreated from them after the build loop.
	obj_dir := grammar_obj_dir(dest)
	if !rmrf(obj_dir) {
		return false, false
	}
	if err := os.make_directory_all(obj_dir); err != nil && err != .Exist {
		log.errorf("could not create %q: %s", obj_dir, os.error_string(err))
		return false, false
	}
	for o in objs {
		if !copy_file(o, join_path(obj_dir, path_base(o))) {
			return false, false
		}
	}

	// Queries: only the tags query is consumed (outline); grammars that
	// ship none still get an empty tags.scm so the generated binding can
	// always expose TAGS and the runtime falls back to query inference.
	// Prefer <path>/queries, fall back to the repository root.
	queries_src := join_path(lang_dir, "queries")
	if !os.exists(join_path(queries_src, "tags.scm")) {
		queries_src = join_path(src_dir, "queries")
	}
	dest_queries := join_path(dest, "queries")
	if err := os.make_directory_all(dest_queries); err != nil && err != .Exist {
		log.errorf("could not create %q: %s", dest_queries, os.error_string(err))
		return false, false
	}
	tags_src := join_path(queries_src, "tags.scm")
	tags_dst := join_path(dest_queries, "tags.scm")
	if os.exists(tags_src) {
		if !copy_file(tags_src, tags_dst) {
			return false, false
		}
	} else if werr := os.write_entire_file(tags_dst, ""); werr != nil {
		log.errorf("could not write %q: %s", tags_dst, os.error_string(werr))
		return false, false
	}

	for lname in ([]string{"LICENSE", "LICENSE.txt", "LICENSE.md", "LICENSE.rst"}) {
		if copy_file(join_path(src_dir, lname), join_path(dest, lname), try_it = true) {
			break
		}
	}

	if !write_parser_binding(g, dest) {
		return false, false
	}

	log.infof("successfully built grammar %q (%s @ %s)", g.name, g.repo, g.tag)
	return true, true
}

write_parser_binding :: proc(g: Grammar_Desc, dest: string) -> bool {
	buf := strings.builder_make()
	ws :: strings.write_string

	fmt.sbprintf(&buf, "package ts_%s\n\n", g.name)
	fmt.sbprintf(&buf, "foreign import lib %q\n\n", strings.concatenate({"../../libtree-sitter-grammars", lib_ext()}))
	symbol := g.symbol
	if symbol == "" {
		symbol = strings.concatenate({"tree_sitter_", g.name})
	}
	ws(&buf, "@(default_calling_convention = \"c\")\n")
	ws(&buf, "foreign lib {\n")
	fmt.sbprintf(&buf, "\t%s :: proc() -> rawptr ---\n", symbol)
	ws(&buf, "}\n")

	// install_parser guarantees queries/tags.scm exists (empty when the
	// grammar ships none); an empty TAGS sends the runtime to the
	// inferred tags query.
	ws(&buf, "\nTAGS :: #load(\"queries/tags.scm\", string)\n")

	bindings_path := join_path(dest, strings.concatenate({g.name, ".odin"}))
	if werr := os.write_entire_file(bindings_path, buf.buf[:]); werr != nil {
		log.errorf("failed writing bindings: %s", os.error_string(werr))
		return false
	}
	return true
}

// write_stub_binding leaves a resolvable package behind for a grammar that
// failed to build: the registry table imports every grammars:<name>
// package unconditionally, so an install failure without a stub would
// break every later compile with an empty package directory. The stub's
// language proc returns nil, which registry_language reports as
// "unavailable on this platform" at runtime. A later successful install
// overwrites the stub (write_parser_binding writes the same path).
write_stub_binding :: proc(g: Grammar_Desc) -> bool {
	dest := join_path(lib_dir(), "grammars", g.name)
	if err := os.make_directory_all(dest); err != nil && err != .Exist {
		log.errorf("could not create %q: %s", dest, os.error_string(err))
		return false
	}
	symbol := g.symbol
	if symbol == "" {
		symbol = strings.concatenate({"tree_sitter_", g.name})
	}
	buf := strings.builder_make()
	ws :: strings.write_string
	fmt.sbprintf(&buf, "package ts_%s\n\n", g.name)
	// Braces are prose here, not format parameters: sbprintf would treat
	// them as parameter braces, so brace-bearing lines go through
	// write_string.
	ws(&buf, "// Stub binding: this grammar's C sources failed to build on this\n")
	ws(&buf, "// platform; the language resolves but stays unavailable at runtime.\n")
	ws(&buf, symbol)
	ws(&buf, " :: proc \"c\" () -> rawptr {\n\treturn nil\n}\n\n")
	ws(&buf, "TAGS :: \"\"\n")

	bindings_path := join_path(dest, strings.concatenate({g.name, ".odin"}))
	if werr := os.write_entire_file(bindings_path, buf.buf[:]); werr != nil {
		log.errorf("failed writing stub binding: %s", os.error_string(werr))
		return false
	}
	return true
}
