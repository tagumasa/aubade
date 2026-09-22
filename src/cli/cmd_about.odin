// `aubade about` — the attribution surface: version, the project
// licence, the vendored components with their licenses, and a
// per-license-kind summary of the grammar manifest the builder emits.
// The per-grammar detail (license and pin per language) is rendered by
// the same builder step into docs/licenses.md; SPDX ids print here
// verbatim. The component rows mirror the builder's pins (tools/build).
package cli

import "core:fmt"
import "core:strings"

import "src:ts"

run_about :: proc(args: []string, g: ^Globals, version: string) -> int {
	rest := make([dynamic]string, 0, len(args), context.temp_allocator)
	if !strip_globals(args, g, &rest) {
		return usage_error("about", "invalid global flag value")
	}
	if len(rest) != 0 {
		return usage_error("about", "about takes no arguments")
	}

	fmt.println(strings.concatenate({"aubade ", version}, context.temp_allocator))
	fmt.println("License: MIT")
	fmt.println()
	fmt.println("Vendored components:")

	components := []string{
		"  tree-sitter v0.26.9 - MIT",
		"  tree-sitter grammars - see the license manifest below",
		"  SQLite 3.53.0 - Public Domain",
		"  PCRE2 10.47 (+ SLJIT) - BSD-3-Clause / BSD-2-Clause",
		"  lexbor v2.3.0 - Apache-2.0",
		"  libcurl - system library at link time",
	}
	for c in components {
		fmt.println(c)
	}

	// Materialize the generated table locally before indexing (the
	// compiler rejects variable indexing straight into constant data).
	rows := ts.GRAMMAR_LICENSES
	kinds := make(map[string]int, 8, context.temp_allocator)
	for i in 0..<len(rows) {
		kinds[rows[i].license] += 1
	}
	names := make([dynamic]string, 0, len(kinds), context.temp_allocator)
	for k in kinds {
		append(&names, k)
	}
	// Kind order: by count descending, then alphabetical — deterministic.
	for i in 1..<len(names) {
		key := names[i]
		j := i - 1
		for j >= 0 && (kinds[names[j]] < kinds[key] || (kinds[names[j]] == kinds[key] && key < names[j])) {
			names[j + 1] = names[j]
			j -= 1
		}
		names[j + 1] = key
	}

	fmt.println()
	fmt.printfln("Grammar licenses (%d grammars):", len(rows))
	for n in names {
		fmt.printfln("  %d x %s", kinds[n], n)
	}
	fmt.println("  per-grammar licenses and pins: docs/licenses.md in the source tree")
	return 0
}
