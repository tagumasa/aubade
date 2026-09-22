// Regenerates the grammar tables from a gotreesitter checkout, which is
// external to this repository — its path is a required argument:
//
//	odin run scripts/extract_table -- <gotreesitter-dir> [--src-table=<path>]
//
// Inputs read (relative to the checkout root):
//
//	grammars/languages.lock          name / repo / commit pin / subdir / exts
//	grammars/registry_builtin_gen.go registry Name + Extensions
//	grammars/linguist_gen.go         linguist aliases and extension claims
//
// Outputs (rewritten wholesale):
//
//	tools/build/grammars.odin    the build pin table (Grammar_Desc rows)
//	src/ts/grammars_table.odin   the runtime registry table (GRAMMARS);
//	                            --src-table=<path> overrides the path
//
// The curated set below keeps the verified release-tag pins, alias sets,
// and extension lists of the initial eleven grammars (csharp is renamed
// to the registry id c_sharp, with "csharp" kept as an alias; .tsx moves
// to the dedicated tsx grammar). Everything else pins to the gotreesitter
// lock commit. Row order is alphabetical and extension claims resolve
// first-wins in that order; the linguist pass runs after the registry
// pass, so shipped extensions always outrank linguist fallbacks.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

main :: proc() {
	context.logger = log.create_console_logger(.Debug when ODIN_DEBUG else .Info, {.Level, .Terminal_Color})

	dir := ""
	src_table_out := ""
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "--src-table=") {
			src_table_out = arg[len("--src-table="):]
		} else {
			dir = arg
		}
	}
	if dir == "" {
		fmt.eprintln("usage: odin run scripts/extract_table -- <gotreesitter-dir> [--src-table=<path>]")
		fmt.eprintln("The gotreesitter checkout is external to this repository; pass its root.")
		os.exit(1)
	}
	if src_table_out == "" {
		src_table_out = join_path(repo_root(), "src", "ts", "grammars_table.odin")
	}
	if !extract_table(dir, src_table_out) {
		os.exit(1)
	}
}

// scripts/extract_table/main.odin -> repository root
repo_root :: proc() -> string {
	return filepath.dir(filepath.dir(#file))
}

join_path :: proc(paths: ..string) -> string {
	joined, err := filepath.join(paths, context.allocator)
	assert(err == nil)
	return joined
}

Extract_Entry :: struct {
	name:       string,
	repo:       string,
	pin:        string,
	path:       string,
	symbol:     string,
	aliases:    [dynamic]string,
	extensions: [dynamic]string,
}

// Linguist_Claim pairs a Linguist detection key (an exact filename like
// "Makefile" or a shebang interpreter like "python3") with the grammar
// name it resolves to. The runtime twin lives in src/ts/grammars.odin.
Linguist_Claim :: struct {
	key:     string,
	grammar: string,
}

Curated_Row :: struct {
	name:    string,
	tag:     string, // verified release-tag pin kept verbatim
	aliases: string, // comma separated
	exts:    string, // comma separated, no spaces
}

CURATED_ROWS :: []Curated_Row{
	{name = "c",          tag = "v0.24.2", aliases = "",             exts = ".c,.h"},
	{name = "c_sharp",    tag = "v0.23.5", aliases = "cs,c#,csharp", exts = ".cs"},
	{name = "cpp",        tag = "v0.23.4", aliases = "c++,cxx",      exts = ".cpp,.cc,.cxx,.hpp,.hh,.hxx"},
	{name = "go",         tag = "v0.25.0", aliases = "golang",       exts = ".go"},
	{name = "java",       tag = "v0.23.5", aliases = "",             exts = ".java"},
	{name = "javascript", tag = "v0.25.0", aliases = "js",           exts = ".js,.jsx,.mjs,.cjs"},
	// json5 tolerates comments, so it also serves .jsonc (file_outline,
	// ast tools, detection). Kept here — not as a hand edit on the
	// generated table — so regenerations preserve the claim.
	{name = "json5",       tag = "aa630ef48903ab99e406a8acd2e2933077cc34e1", aliases = "", exts = ".json5,.jsonc"},
	{name = "markdown",   tag = "v0.5.3",  aliases = "md",           exts = ".md,.markdown"},
	{name = "odin",       tag = "v1.3.0",  aliases = "",             exts = ".odin"},
	{name = "python",     tag = "v0.25.0", aliases = "py",           exts = ".py"},
	{name = "rust",       tag = "v0.24.2", aliases = "rs",           exts = ".rs"},
	{name = "typescript", tag = "v0.23.2", aliases = "ts",           exts = ".ts"},
}

// Linguist claims suppressed from the registry table: vimdoc claiming
// .txt would route every plain text file through a pointless parse (the
// gotreesitter registry detects .txt the same way; plain text stays
// unclaimed here instead).
SUPPRESSED_EXTENSIONS :: []string{".txt"}

// Grammars excluded from the registry, in two groups.
//
// caddy, disassembly, and jq ship GPL-3.0 LICENSE files (verified
// against the pinned clones); the project is MIT and distributes one
// self-contained statically linked binary, so GPL code cannot ride
// along and LGPL could not meet its relink terms either.
// `emit-licenses` fails when a grammar classified GPL/LGPL enters the
// table, so a registry refresh cannot reintroduce one silently.
//
// The rest carry no license file at all in their pinned trees (checked
// under lib/<os>_<arch>/grammars/<name>/ after a build): permission to
// redistribute cannot be verified, so they stay out until a pin that
// ships a recognizable LICENSE — re-adding one is an edit here plus a
// regeneration.
//
// tree-sitter-perl ships no parser.c upstream (the project builds via
// `tree-sitter generate`); its committed generated parser under
// third_party/tree-sitter-perl keeps it in the registry — see that
// directory's VENDORED.md.
EXCLUDED_GRAMMARS :: []string{
	"caddy", "disassembly", "jq",
	"authzed", "brightscript", "clojure", "cooklang", "corn", "ebnf",
	"eds", "eex", "elsa", "facility", "gitcommit", "janet", "ron",
	"tmux", "twig", "vhdl",
}

Pin_Fix :: struct {
	name: string,
	tag:  string,
}

// Commit-pin overrides for grammars whose lock commit stopped shipping
// the generated parser.c: pinned to the last verified commit that has
// one (checked by cloning and listing the tree).
PIN_FIXES :: []Pin_Fix{
	{name = "swift", tag = "ce6a915cd937ecb2c6d9f79bbf7ef7f7c1ccc61a"},
}

Symbol_Fix :: struct {
	name:   string,
	symbol: string,
}

// C-symbol overrides for grammars whose entry point is not spelled
// tree_sitter_<name> (verified with nm over the built archives).
SYMBOL_FIXES :: []Symbol_Fix{
	{name = "cobol",   symbol = "tree_sitter_COBOL"},
	{name = "move",    symbol = "tree_sitter_move_on_aptos"},
	{name = "nushell", symbol = "tree_sitter_nu"},
}

extract_table :: proc(gts_dir: string, src_table_out: string) -> bool {
	lock, lok := read_text_file(join_path(gts_dir, "grammars", "languages.lock"))
	if !lok {
		return false
	}
	registry, rok := read_text_file(join_path(gts_dir, "grammars", "registry_builtin_gen.go"))
	if !rok {
		return false
	}
	linguist, liok := read_text_file(join_path(gts_dir, "grammars", "linguist_gen.go"))
	if !liok {
		return false
	}

	entries: [dynamic]Extract_Entry
	if !parse_lock(lock, &entries) {
		return false
	}

	// Drop excluded grammars before any indexing happens.
	kept := make([dynamic]Extract_Entry, 0, len(entries))
	for i in 0..<len(entries) {
		if excluded_grammar(entries[i].name) {
			log.warnf("grammar %q excluded from the registry", entries[i].name)
			continue
		}
		append(&kept, entries[i])
	}
	entries = kept

	reg_exts := parse_registry_extensions(registry)
	alias_map := parse_linguist_map(linguist, "linguistToGrammar")
	ext_map := parse_linguist_map(linguist, "linguistExtensions")

	// Index by name for the merges. The map borrows the dynamic array's
	// storage; no appends to `entries` happen after this line.
	by_name := make(map[string]^Extract_Entry)
	for i in 0..<len(entries) {
		if _, dup := by_name[entries[i].name]; dup {
			log.errorf("duplicate grammar %q in the lock", entries[i].name)
			return false
		}
		by_name[entries[i].name] = &entries[i]
	}

	// Registry extensions merge (dedup, lowercased).
	for name, exts in reg_exts {
		e, known := by_name[name]
		if !known {
			log.warnf("registry extension entry %q has no lock row, skipped", name)
			continue
		}
		for ext in exts {
			append_unique(&e.extensions, strings.to_lower(ext))
		}
	}

	// Curated rows override pin / aliases / extensions verbatim.
	curated := CURATED_ROWS
	for ci in 0..<len(curated) {
		row := curated[ci]
		e, known := by_name[row.name]
		if !known {
			log.errorf("curated grammar %q missing from the lock", row.name)
			return false
		}
		e.pin = row.tag
		e.aliases = make([dynamic]string, 0, 8)
		e.extensions = make([dynamic]string, 0, 12)
		for alias in split_comma(row.aliases) {
			if alias != "" {
				append(&e.aliases, alias)
			}
		}
		for ext in split_comma(row.exts) {
			if ext != "" {
				append(&e.extensions, ext)
			}
		}
	}

	// Commit-pin fixes apply after the curated set (they only move the
	// pin; aliases and extensions still come from the registry data).
	fixes := PIN_FIXES
	for fi in 0..<len(fixes) {
		e, known := by_name[fixes[fi].name]
		if !known {
			log.errorf("pin fix for unknown grammar %q", fixes[fi].name)
			return false
		}
		e.pin = fixes[fi].tag
	}

	// C-symbol fixes for grammars whose entry point is not the default
	// tree_sitter_<name> spelling.
	sym_fixes := SYMBOL_FIXES
	for fi in 0..<len(sym_fixes) {
		e, known := by_name[sym_fixes[fi].name]
		if !known {
			log.errorf("symbol fix for unknown grammar %q", sym_fixes[fi].name)
			return false
		}
		e.symbol = sym_fixes[fi].symbol
	}

	// Linguist aliases merge after the curated set (curated aliases keep
	// priority order at the front), then every alias list is sorted so
	// the generated file does not depend on map iteration order.
	for alias, name in alias_map {
		if alias == name {
			continue
		}
		e, known := by_name[name]
		if !known {
			continue
		}
		append_unique(&e.aliases, alias)
	}
	for i in 0..<len(entries) {
		sort_strings(&entries[i].aliases)
	}

	// Alphabetical row order; extension claims resolve first-wins in it.
	sort_entries(&entries)
	// Rebuild the name index after the sort: the map holds pointers into
	// the dynamic array, and sorting permutes the occupants.
	by_name = make(map[string]^Extract_Entry)
	for i in 0..<len(entries) {
		by_name[entries[i].name] = &entries[i]
	}
	claimed := make(map[string]bool)
	dropped := 0
	for i in 0..<len(entries) {
		e := &entries[i]
		kept := make([dynamic]string, 0, len(e.extensions))
		for j in 0..<len(e.extensions) {
			ext := e.extensions[j]
			if ext == "" || suppressed_extension(ext) {
				dropped += 1
				continue
			}
			if claimed[ext] {
				dropped += 1
				continue
			}
			claimed[ext] = true
			append(&kept, ext)
		}
		e.extensions = kept
	}

	// Linguist extension fallbacks: sorted by extension for determinism,
	// assigned only when nothing shipped claims the extension.
	linguist_exts := make([dynamic]string, 0, len(ext_map))
	for ext in ext_map {
		append(&linguist_exts, ext)
	}
	sort_strings(&linguist_exts)
	linguist_added := 0
	for i in 0..<len(linguist_exts) {
		ext := linguist_exts[i]
		if ext == "" || suppressed_extension(ext) || claimed[ext] {
			continue
		}
		e, known := by_name[ext_map[ext]]
		if !known {
			continue
		}
		claimed[ext] = true
		append_unique(&e.extensions, ext)
		linguist_added += 1
	}

	// Linguist exact-filename claims and shebang interpreters: filtered to
	// registered grammars (claims naming unregistered languages are dead
	// weight), sorted by key so the generated tables are deterministic.
	fname_map := parse_linguist_map(linguist, "linguistFilenames")
	filenames := make([dynamic]Linguist_Claim, 0, len(fname_map))
	for key, name in fname_map {
		if _, known := by_name[name]; known {
			append(&filenames, Linguist_Claim{key = key, grammar = name})
		}
	}
	sort_claims(&filenames)

	interp_map := parse_linguist_map(linguist, "linguistInterpreters")
	interpreters := make([dynamic]Linguist_Claim, 0, len(interp_map))
	for key, name in interp_map {
		if _, known := by_name[name]; known {
			append(&interpreters, Linguist_Claim{key = key, grammar = name})
		}
	}
	sort_claims(&interpreters)

	if !write_build_table(entries[:]) {
		return false
	}
	if !write_src_table(entries[:], filenames[:], interpreters[:], src_table_out) {
		return false
	}

	alias_total := 0
	ext_total := 0
	for e in entries {
		alias_total += len(e.aliases)
		ext_total += len(e.extensions)
	}
	log.infof(
		"extracted %d grammars, %d extensions (%d from linguist), %d aliases, %d filenames, %d interpreters, %d conflicting/suppressed claims dropped",
		len(entries), ext_total, linguist_added, alias_total, len(filenames), len(interpreters), dropped,
	)
	return true
}

read_text_file :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		log.errorf("could not read %q: %s", path, os.error_string(err))
		return "", false
	}
	return string(data), true
}

// split_fields splits on runs of spaces/tabs/CRs.
split_fields :: proc(line: string) -> []string {
	out: [dynamic]string
	i := 0
	for i < len(line) {
		for i < len(line) && (line[i] == ' ' || line[i] == '\t' || line[i] == '\r') {
			i += 1
		}
		if i >= len(line) {
			break
		}
		start := i
		for i < len(line) && line[i] != ' ' && line[i] != '\t' && line[i] != '\r' {
			i += 1
		}
		append(&out, line[start:i])
	}
	return out[:]
}

split_comma :: proc(s: string) -> []string {
	out: [dynamic]string
	start := 0
	for i in 0..<len(s) {
		if s[i] == ',' {
			if i > start {
				append(&out, s[start:i])
			}
			start = i + 1
		}
	}
	if start < len(s) {
		append(&out, s[start:])
	}
	return out[:]
}

// go_all_strings returns the contents of every Go double-quoted string
// literal on the line (ignoring escaped quotes).
go_all_strings :: proc(line: string) -> []string {
	out: [dynamic]string
	i := 0
	for i < len(line) {
		if line[i] != '"' {
			i += 1
			continue
		}
		start := i + 1
		j := start
		for j < len(line) {
			if line[j] == '"' && (j == 0 || line[j-1] != '\\') {
				break
			}
			j += 1
		}
		if j >= len(line) {
			break
		}
		if j > start {
			append(&out, line[start:j])
		}
		i = j + 1
	}
	return out[:]
}

parse_lock :: proc(content: string, out: ^[dynamic]Extract_Entry) -> bool {
	for line in strings.split_lines(content) {
		t := strings.trim_space(line)
		if t == "" || strings.has_prefix(t, "#") {
			continue
		}
		fields := split_fields(t)
		if len(fields) < 3 {
			log.errorf("malformed lock line: %q", t)
			return false
		}
		e := Extract_Entry{
			name = fields[0],
			repo = fields[1],
			pin  = fields[2],
			aliases    = make([dynamic]string, 0, 4),
			extensions = make([dynamic]string, 0, 8),
		}
		for fi in 3..<len(fields) {
			f := fields[fi]
			if strings.has_prefix(f, ".") {
				for ext in split_comma(f) {
					append(&e.extensions, strings.to_lower(ext))
				}
			} else if f == "src" {
				// Match the build table convention: the parser lives at
				// <path>/src, so the src component drops off the path.
				e.path = ""
			} else if strings.has_suffix(f, "/src") {
				e.path = f[:len(f) - len("/src")]
			} else {
				e.path = f
			}
		}
		append(out, e)
	}
	return true
}

parse_registry_extensions :: proc(content: string) -> map[string][]string {
	exts_of := make(map[string][]string)
	in_entry := false
	name := ""
	for line in strings.split_lines(content) {
		t := strings.trim_space(line)
		if strings.has_prefix(t, "Register(LangEntry{") {
			in_entry = true
			name = ""
			continue
		}
		if !in_entry {
			continue
		}
		if strings.has_prefix(t, "Name:") {
			parts := go_all_strings(t)
			if len(parts) > 0 {
				name = parts[0]
			}
		} else if strings.has_prefix(t, "Extensions:") {
			parts := go_all_strings(t)
			if name != "" && len(parts) > 0 {
				exts_of[name] = parts
			}
		} else if t == "})" {
			in_entry = false
		}
	}
	return exts_of
}

parse_linguist_map :: proc(content: string, map_name: string) -> map[string]string {
	out := make(map[string]string)
	needle := strings.concatenate({"var ", map_name, " = map[string]string{"})
	in_map := false
	for line in strings.split_lines(content) {
		if !in_map {
			if strings.contains(line, needle) {
				in_map = true
			}
			continue
		}
		t := strings.trim_space(line)
		if t == "}" {
			break
		}
		parts := go_all_strings(t)
		if len(parts) == 2 {
			out[parts[0]] = parts[1]
		}
	}
	return out
}

suppressed_extension :: proc(ext: string) -> bool {
	list := SUPPRESSED_EXTENSIONS
	for i in 0..<len(list) {
		if list[i] == ext {
			return true
		}
	}
	return false
}

excluded_grammar :: proc(name: string) -> bool {
	list := EXCLUDED_GRAMMARS
	for i in 0..<len(list) {
		if list[i] == name {
			return true
		}
	}
	return false
}

append_unique :: proc(list: ^[dynamic]string, s: string) {
	for i in 0..<len(list^) {
		if list[i] == s {
			return
		}
	}
	append(list, s)
}

str_lt :: proc(a, b: string) -> bool {
	n := min(len(a), len(b))
	for i in 0..<n {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return len(a) < len(b)
}

sort_strings :: proc(list: ^[dynamic]string) {
	for i in 1..<len(list^) {
		v := list[i]
		j := i - 1
		for j >= 0 && str_lt(v, list[j]) {
			list[j+1] = list[j]
			j -= 1
		}
		list[j+1] = v
	}
}

sort_claims :: proc(list: ^[dynamic]Linguist_Claim) {
	for i in 1..<len(list^) {
		v := list[i]
		j := i - 1
		for j >= 0 && str_lt(v.key, list[j].key) {
			list[j+1] = list[j]
			j -= 1
		}
		list[j+1] = v
	}
}

// Entry structs only hold handles to their dynamic arrays, so permuting
// them permutes ownership safely.
sort_entries :: proc(entries: ^[dynamic]Extract_Entry) {
	for i in 1..<len(entries^) {
		e := entries[i]
		j := i - 1
		for j >= 0 && str_lt(e.name, entries[j].name) {
			entries[j+1] = entries[j]
			j -= 1
		}
		entries[j+1] = e
	}
}

escape_odin_string :: proc(s: string) -> string {
	needs := false
	for i in 0..<len(s) {
		if s[i] == '"' || s[i] == '\\' {
			needs = true
			break
		}
	}
	if !needs {
		return s
	}
	out := make([dynamic]u8, 0, len(s) + 8)
	for i in 0..<len(s) {
		if s[i] == '"' || s[i] == '\\' {
			append(&out, '\\')
		}
		append(&out, s[i])
	}
	return string(out[:])
}

string_list_literal :: proc(values: []string) -> string {
	out: [dynamic]string
	append(&out, "{")
	for v, i in values {
		if i > 0 {
			append(&out, ", ")
		}
		append(&out, "\"")
		append(&out, escape_odin_string(v))
		append(&out, "\"")
	}
	append(&out, "}")
	return strings.concatenate(out[:])
}

write_build_table :: proc(entries: []Extract_Entry) -> bool {
	name_w, repo_w, tag_w := 0, 0, 0
	for e in entries {
		name_w = max(name_w, len(e.name))
		repo_w = max(repo_w, len(e.repo))
		tag_w = max(tag_w, len(e.pin))
	}

	buf := strings.builder_make()
	ws :: strings.write_string
	ws(&buf, "// Grammar table: the source of truth for which tree-sitter grammars\n")
	ws(&buf, "// tools/build fetches and pins. Pins are upstream release tags or\n")
	ws(&buf, "// 40-hex commit SHAs (commit pins clone via fetch + checkout). The\n")
	ws(&buf, "// rows are generated from the gotreesitter registry by\n")
	ws(&buf, "// `odin run scripts/extract_table -- <gotreesitter-dir>`; the\n")
	ws(&buf, "// struct, the core pin, and find_grammar are fixed template parts.\n")
	ws(&buf, "package build\n\n")
	ws(&buf, "TREE_SITTER_REPO :: \"https://github.com/tree-sitter/tree-sitter\"\n")
	ws(&buf, "TREE_SITTER_TAG  :: \"v0.26.9\"\n\n")
	ws(&buf, "Grammar_Desc :: struct {\n")
	ws(&buf, "\tname: string, // language id used by the registry and lib layout\n")
	ws(&buf, "\trepo: string, // git URL to clone from\n")
	ws(&buf, "\ttag:  string, // pinned release tag or 40-hex commit SHA\n")
	ws(&buf, "\tpath: string, // subdirectory inside the repo holding src/ (\"\" = root)\n")
	ws(&buf, "\t// C symbol of the language entry point when it is not tree_sitter_<name>\n")
	ws(&buf, "\t// (e.g. the C# grammar exports tree_sitter_c_sharp).\n")
	ws(&buf, "\tsymbol: string, // \"\" = tree_sitter_<name>\n")
	ws(&buf, "}\n\n")
	ws(&buf, "GRAMMARS :: []Grammar_Desc{\n")
	for e in entries {
		line := strings.concatenate({
			"\t{name = \"", e.name, "\",",
			strings.repeat(" ", name_w - len(e.name) + 2),
			"repo = \"", e.repo, "\",",
			strings.repeat(" ", repo_w - len(e.repo) + 2),
			"tag = \"", e.pin, "\"",
		})
		if e.path != "" {
			line = strings.concatenate({line, ", path = \"", e.path, "\""})
		}
		if e.symbol != "" {
			line = strings.concatenate({line, ", symbol = \"", e.symbol, "\""})
		}
		ws(&buf, line)
		ws(&buf, "},\n")
	}
	ws(&buf, "}\n\n")
	ws(&buf, "find_grammar :: proc(name: string) -> (Grammar_Desc, bool) {\n")
	ws(&buf, "\tfor g in GRAMMARS {\n")
	ws(&buf, "\t\tif g.name == name {\n")
	ws(&buf, "\t\t\treturn g, true\n")
	ws(&buf, "\t\t}\n")
	ws(&buf, "\t}\n")
	ws(&buf, "\treturn Grammar_Desc{}, false\n")
	ws(&buf, "}\n")

	path := join_path(repo_root(), "tools", "build", "grammars.odin")
	if err := os.write_entire_file(path, buf.buf[:]); err != nil {
		log.errorf("could not write %q: %s", path, os.error_string(err))
		return false
	}
	log.infof("wrote %q (%d rows)", path, len(entries))
	return true
}

write_src_table :: proc(
	entries: []Extract_Entry,
	filenames: []Linguist_Claim,
	interpreters: []Linguist_Claim,
	out_path: string,
) -> bool {
	name_w := 0
	for e in entries {
		name_w = max(name_w, len(e.name))
	}

	buf := strings.builder_make()
	ws :: strings.write_string
	ws(&buf, "// GENERATED FILE — regenerate with `odin run scripts/extract_table\n")
	ws(&buf, "// -- <gotreesitter-dir>`; do not edit by hand. Row order\n")
	ws(&buf, "// is alphabetical and extension claims resolve first-wins in it\n")
	ws(&buf, "// (linguist fallbacks only fill unclaimed extensions). Consumers\n")
	ws(&buf, "// materialize the table before indexing (the compiler rejects\n")
	ws(&buf, "// variable indexing straight into constant data).\n")
	ws(&buf, "package ts\n\n")
	for e in entries {
		fmt.sbprintf(&buf, "import ts_%s \"grammars:%s\"\n", e.name, e.name)
	}
	ws(&buf, "\n")
	ws(&buf, "GRAMMARS :: []Grammar_Entry{\n")
	for e in entries {
		symbol := e.symbol
		if symbol == "" {
			symbol = strings.concatenate({"tree_sitter_", e.name})
		}
		language := strings.concatenate({"ts_", e.name, ".", symbol})
		line := strings.concatenate({
			"\t{name = \"", e.name, "\",",
			strings.repeat(" ", name_w - len(e.name) + 2),
			"aliases = ", string_list_literal(e.aliases[:]),
			", extensions = ", string_list_literal(e.extensions[:]),
			",\n\t language = ", language,
			", tags_query = ts_", e.name, ".TAGS},\n",
		})
		ws(&buf, line)
	}
	ws(&buf, "}\n")

	ws(&buf, "\n// Linguist exact-filename claims (the detection tier checked before\n")
	ws(&buf, "// extensions: Makefile, Dockerfile, .bashrc, ...) and shebang\n")
	ws(&buf, "// interpreter claims (#!/usr/bin/env python3 -> python3), filtered to\n")
	ws(&buf, "// registered grammars and sorted by key.\n")
	ws(&buf, "LINGUIST_FILENAMES :: []Linguist_Claim{\n")
	for c in filenames {
		// fmt would treat the literal brace as a parameter brace — the
		// rows are concatenated, like the GRAMMARS rows above.
		line := strings.concatenate({
			"\t{key = \"", escape_odin_string(c.key), "\", grammar = \"", escape_odin_string(c.grammar), "\"},\n",
		})
		ws(&buf, line)
	}
	ws(&buf, "}\n")
	ws(&buf, "LINGUIST_INTERPRETERS :: []Linguist_Claim{\n")
	for c in interpreters {
		line := strings.concatenate({
			"\t{key = \"", escape_odin_string(c.key), "\", grammar = \"", escape_odin_string(c.grammar), "\"},\n",
		})
		ws(&buf, line)
	}
	ws(&buf, "}\n")

	if err := os.write_entire_file(out_path, buf.buf[:]); err != nil {
		log.errorf("could not write %q: %s", out_path, os.error_string(err))
		return false
	}
	log.infof("wrote %q (%d rows, %d filenames, %d interpreters)", out_path, len(entries), len(filenames), len(interpreters))
	return true
}
