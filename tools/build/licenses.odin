// emit-licenses: the grammar/version license manifest behind `aubade
// about`. Reads each built grammar's copied LICENSE file under
// lib/<os>_<arch>/grammars/<name>/ plus the builder's pin table, and
// writes the generated src/ts/licenses_table.odin (committed; regenerate
// when pins change) and docs/licenses.md — the human-readable
// attribution notice rendered from the same rows. License classification
// is a text scan over the LICENSE files' SPDX markers — no license is
// fetched or guessed beyond what the clones themselves ship. The run
// FAILS when a grammar classifies as GPL-3.0 or LGPL-2.1: the project is
// MIT and distributes one statically linked binary, which GPL cannot
// ride along in and LGPL cannot meet the relink terms of — such
// grammars belong in EXCLUDED_GRAMMARS (tools/build/extract.odin), and
// the manifest is still written first so the offending rows stay on
// record.
package build

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

License_Row :: struct {
	name:    string,
	pin:     string,
	license: string,
	repo:    string,
}

emit_licenses :: proc(src_out: string) -> bool {
	grammars_dir := join_path(lib_dir(), "grammars")

	rows: [dynamic]License_Row
	defer delete(rows)
	missing: [dynamic]string
	defer delete(missing)
	copyleft: [dynamic]string
	defer delete(copyleft)

	table := GRAMMARS
	for i in 0..<len(table) {
		g := table[i]
		license := "unknown"
		for lname in ([]string{"LICENSE", "LICENSE.txt", "LICENSE.md", "LICENSE.rst"}) {
			parts := []string{grammars_dir, g.name, lname}
			path, _ := filepath.join(parts, context.temp_allocator)
			if data, ok := read_text_file(path); ok {
				license = classify_license(data)
				break
			}
		}
		if license == "unknown" {
			append(&missing, g.name)
		}
		if license == "GPL-3.0" || license == "LGPL-2.1" {
			append(&copyleft, g.name)
		}
		append(&rows, License_Row{name = g.name, pin = g.tag, license = license, repo = g.repo})
	}
	sort_license_rows(&rows)

	buf := strings.builder_make()
	ws :: strings.write_string
	ws(&buf, "// GENERATED FILE — regenerate with `odin run tools/build --\n")
	ws(&buf, "// emit-licenses` after a full install-parsers run (the LICENSE files\n")
	ws(&buf, "// it reads live under lib/<os>_<arch>/grammars/); do not edit by\n")
	ws(&buf, "// hand. Rows are alphabetical.\n")
	ws(&buf, "package ts\n\n")
	ws(&buf, "Grammar_License :: struct {\n\tname:    string,\n\tpin:     string,\n\tlicense: string,\n}\n\n")
	ws(&buf, "GRAMMAR_LICENSES :: []Grammar_License{\n")
	for r in rows {
		line := strings.concatenate({
			"\t{name = \"", escape_odin_string(r.name), "\", pin = \"", escape_odin_string(r.pin),
			"\", license = \"", escape_odin_string(r.license), "\"},\n",
		}, context.temp_allocator)
		ws(&buf, line)
	}
	ws(&buf, "}\n")

	if err := os.write_entire_file(src_out, buf.buf[:]); err != nil {
		log.errorf("could not write %q: %s", src_out, os.error_string(err))
		return false
	}
	strings.builder_destroy(&buf)

	if !write_licenses_doc(rows[:]) {
		return false
	}

	by_kind := make(map[string]int)
	defer delete(by_kind)
	for r in rows {
		by_kind[r.license] += 1
	}
	for kind, count in by_kind {
		log.infof("license kind: %s=%d", kind, count)
	}
	log.infof("wrote %q (%d grammars; %d without a recognizable LICENSE)", src_out, len(rows), len(missing))
	if len(copyleft) > 0 {
		log.errorf(
			"copyleft-licensed grammars %s cannot ship inside the statically linked binary — add them to EXCLUDED_GRAMMARS in tools/build/extract.odin and regenerate the tables",
			strings.join(copyleft[:], ", "),
		)
		return false
	}
	return true
}

// classify_license scans a LICENSE body for SPDX markers, most specific
// first (Apache before its own header wording, LGPL before GPL). All
// phrase matching runs over whitespace-collapsed text: license texts
// wrap mid-phrase, and a needle broken across a newline once left an ISC
// file unclassified.
classify_license :: proc(text: string) -> string {
	lower := strings.to_lower(text, context.temp_allocator)
	norm := collapse_ws(lower)
	if id, ok := spdx_identifier(norm); ok {
		return id
	}
	if strings.contains(norm, "apache license") {
		return "Apache-2.0"
	}
	if strings.contains(norm, "mozilla public license") {
		return "MPL-2.0"
	}
	if strings.contains(norm, "gnu lesser general public license") {
		return "LGPL-2.1"
	}
	if strings.contains(norm, "gnu general public license") {
		return "GPL-3.0"
	}
	if strings.contains(norm, "permission is hereby granted, free of charge") {
		return "MIT"
	}
	if strings.contains(norm, "redistribution and use in source and binary forms") {
		if strings.contains(norm, "neither the name") {
			return "BSD-3-Clause"
		}
		return "BSD-2-Clause"
	}
	if strings.contains(norm, "isc license") || strings.contains(norm, "permission to use, copy, modify, and/or distribute this software for any purpose") {
		return "ISC"
	}
	if strings.contains(norm, "this is free and unencumbered software released into the public domain") {
		return "Unlicense"
	}
	if strings.contains(norm, "cc0 1.0 universal") || strings.contains(norm, "creative commons zero") {
		return "CC0-1.0"
	}
	return "unknown"
}

// collapse_ws maps every whitespace run to a single space.
collapse_ws :: proc(s: string) -> string {
	out := make([dynamic]u8, 0, len(s) + 1, context.temp_allocator)
	prev_space := false
	for i in 0..<len(s) {
		c := s[i]
		is_space := c == ' ' || c == '\n' || c == '\r' || c == '\t'
		if is_space {
			if !prev_space {
				append(&out, ' ')
			}
		} else {
			append(&out, c)
		}
		prev_space = is_space
	}
	return string(out[:])
}

// spdx_identifier reads an SPDX-License-Identifier line (some grammars
// ship nothing else — wat's LICENSE is one line). Returns ("", false)
// when no such line exists; an unrecognized expression also reports
// false so the phrase scan below can still try. Word tokens are matched
// exactly so "mit" cannot match inside another identifier.
spdx_identifier :: proc(norm: string) -> (string, bool) {
	marker := "spdx-license-identifier:"
	idx := strings.index(norm, marker)
	if idx < 0 {
		return "", false
	}
	expr := norm[idx + len(marker):]
	if semi := strings.index(expr, ";"); semi >= 0 {
		expr = expr[:semi]
	}
	words := strings.split(expr, " ")
	has :: proc(words: []string, word: string) -> bool {
		for w in words {
			if w == word {
				return true
			}
		}
		return false
	}
	if has(words, "cc0-1.0") {
		return "CC0-1.0", true
	}
	if has(words, "unlicense") {
		return "Unlicense", true
	}
	if has(words, "apache-2.0") {
		if has(words, "with") && has(words, "llvm-exception") {
			return "Apache-2.0 WITH LLVM-exception", true
		}
		return "Apache-2.0", true
	}
	if has(words, "mpl-2.0") {
		return "MPL-2.0", true
	}
	if has(words, "gpl-3.0") || has(words, "gpl-2.0") {
		return "GPL-3.0", true
	}
	if has(words, "lgpl-2.1") || has(words, "lgpl-3.0") {
		return "LGPL-2.1", true
	}
	if has(words, "bsd-3-clause") {
		return "BSD-3-Clause", true
	}
	if has(words, "bsd-2-clause") {
		return "BSD-2-Clause", true
	}
	if has(words, "isc") {
		return "ISC", true
	}
	if has(words, "mit") {
		return "MIT", true
	}
	return "", false
}

// write_licenses_doc renders docs/licenses.md — the human-readable
// attribution notice: acknowledgments, the per-licence-kind summary
// (same order as `aubade about`), and one row per grammar with its
// upstream repository, pin, and licence. Same rows as the manifest
// table, so the two never drift.
write_licenses_doc :: proc(rows: []License_Row) -> bool {
	path := join_path(repo_root(), "docs", "licenses.md")
	buf := strings.builder_make()
	ws :: strings.write_string

	ws(&buf, "<!-- GENERATED FILE — regenerate with `odin run tools/build --\n")
	ws(&buf, "     emit-licenses` after a full install-parsers run; do not edit\n")
	ws(&buf, "     by hand. Rows are alphabetical. -->\n\n")
	ws(&buf, "# Grammar licences and acknowledgments\n\n")
	ws(&buf, "Aubade is MIT-licensed (see the repository `LICENSE`). The binary\n")
	ws(&buf, "also embeds, statically compiled, the vendored C libraries documented\n")
	ws(&buf, "in [third_party/README.md](../third_party/README.md) — tree-sitter\n")
	ws(&buf, "core, SQLite, PCRE2 with its SLJIT JIT, and lexbor; libcurl is a\n")
	ws(&buf, "system library resolved at link time — and the tree-sitter grammar\n")
	ws(&buf, "parsers listed below, each built from the pinned upstream revision\n")
	ws(&buf, "recorded here.\n\n")
	ws(&buf, "With thanks to the tree-sitter project, to the authors and\n")
	ws(&buf, "maintainers of every grammar below, and to the library teams above.\n\n")
	ws(&buf, "`aubade about` prints the per-licence-kind summary at runtime; the\n")
	ws(&buf, "machine-readable manifest behind this document is the generated\n")
	ws(&buf, "table `src/ts/licenses_table.odin`.\n\n")

	ws(&buf, "## Summary\n\n")
	by_kind := make(map[string]int)
	defer delete(by_kind)
	for r in rows {
		by_kind[r.license] += 1
	}
	names := make([dynamic]string, 0, len(by_kind))
	defer delete(names)
	for k in by_kind {
		append(&names, k)
	}
	// Count descending, then alphabetical — the same order `aubade about`
	// prints, so the two summaries read identically.
	for i in 1..<len(names) {
		key := names[i]
		j := i - 1
		for j >= 0 && (by_kind[names[j]] < by_kind[key] || (by_kind[names[j]] == by_kind[key] && key < names[j])) {
			names[j + 1] = names[j]
			j -= 1
		}
		names[j + 1] = key
	}
	for i in 0..<len(names) {
		fmt.sbprintf(&buf, "- %d x %s\n", by_kind[names[i]], names[i])
	}
	fmt.sbprintf(&buf, "\n%d grammars in total.\n", len(rows))

	ws(&buf, "\n## Per-grammar manifest\n\n")
	ws(&buf, "| Language | Upstream | Pin | Licence |\n")
	ws(&buf, "|---|---|---|---|\n")
	for r in rows {
		repo := r.repo
		if strings.has_prefix(repo, "https://") {
			repo = repo[len("https://"):]
		}
		line := strings.concatenate({
			"| ", r.name, " | ", repo, " | `", r.pin, "` | ", r.license, " |\n",
		}, context.temp_allocator)
		ws(&buf, line)
	}

	if err := os.write_entire_file(path, buf.buf[:]); err != nil {
		log.errorf("could not write %q: %s", path, os.error_string(err))
		strings.builder_destroy(&buf)
		return false
	}
	strings.builder_destroy(&buf)
	log.infof("wrote %q (%d grammars)", path, len(rows))
	return true
}

sort_license_rows :: proc(rows: ^[dynamic]License_Row) {
	for i in 1..<len(rows^) {
		v := rows[i]
		j := i - 1
		for j >= 0 && str_lt(v.name, rows[j].name) {
			rows[j + 1] = rows[j]
			j -= 1
		}
		rows[j + 1] = v
	}
}
