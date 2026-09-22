// Build program for the C artifacts aubade links against: tree-sitter core,
// the grammar parsers, SQLite, PCRE2, and lexbor. Run from the repository root:
//
//	odin run tools/build -- install
//	odin run tools/build -- install-parsers go,python
//	odin run tools/build -- clean
//
// Artifacts land in lib/<os>_<arch>/ which is untracked; vendored sources
// live in third_party/ (lexbor there is a git submodule — init it with
// `git submodule update --init third_party/lexbor`). The compile/archive
// flow follows laytan/odin-tree-sitter.
package build

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

main :: proc() {
	context.logger = log.create_console_logger(.Debug when ODIN_DEBUG else .Info, {.Level, .Terminal_Color})

	if len(os.args) < 2 {
		usage(os.stderr)
		os.exit(1)
	}

	switch os.args[1] {
	case "help":
		usage(os.stdout)
	case "install":
		ok := install_core()
		os.exit(0 if ok else 1)
	case "install-lexbor":
		ok := install_lexbor()
		os.exit(0 if ok else 1)
	case "install-parsers":
		langs := os.args[2:]
		if len(langs) == 1 && strings.contains(langs[0], ",") {
			langs = strings.split(langs[0], ",", context.temp_allocator)
		}
		ok := install_parsers(langs[:])
		os.exit(0 if ok else 1)
	case "clean":
		ok := clean()
		os.exit(0 if ok else 1)
	case "emit-licenses":
		out := join_path(repo_root(), "src", "ts", "licenses_table.odin")
		for arg in os.args[2:] {
			if strings.has_prefix(arg, "--out=") {
				out = arg[len("--out="):]
			}
		}
		ok := emit_licenses(out)
		os.exit(0 if ok else 1)
	case "emit-checksums":
		ok := emit_checksums()
		os.exit(0 if ok else 1)
	case "verify-checksums":
		ok := verify_checksums()
		os.exit(0 if ok else 1)
	case:
		log.errorf("unknown command %q", os.args[1])
		usage(os.stderr)
		os.exit(1)
	}
}

usage :: proc(fd: ^os.File) {
	w := os.to_stream(fd)
	fmt.wprintf(
		w,
		`%s is a tool for building the C artifacts aubade links against.

usage: odin run tools/build -- <command>

commands:
  install                     Build tree-sitter core, SQLite, PCRE2, and lexbor into lib/<os>_<arch>/
  install-lexbor              Build only the vendored lexbor HTML parser (liblexbor.a)
  install-parsers [langs...]  Build grammars (comma or space separated; no arguments = all grammars in the table)
  emit-licenses [--out=FILE]  Regenerate the grammar license manifest (src/ts/licenses_table.odin)
                              and docs/licenses.md (needs a built lib/)
  emit-checksums              Regenerate third_party/CHECKSUMS.txt (after an intentional
                              vendored-tree change)
  verify-checksums            Check the vendored trees against third_party/CHECKSUMS.txt
  clean                       Remove lib/ entirely
`,
		os.args[0],
	)
}
