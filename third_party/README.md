# third_party — vendored C dependencies

Aubade links a handful of C libraries. Everything that can be consumed as a
pristine upstream checkout is fetched at build time and pinned in code
(tree-sitter core and the grammar parsers — see `tools/build/grammars.odin`).
This directory holds the exceptions: components whose build inputs cannot be
reproduced by a plain clone at a tag, because what Aubade compiles is a
release artifact, a patched tree, or a generated file.

## Acknowledgments

Aubade builds on the work of these projects, with thanks:

- **SQLite** — D. Richard Hipp and the SQLite contributors
  (https://sqlite.org)
- **PCRE2** — Philip Hazel and the PCRE2 project
  (https://github.com/PCRE2Project/pcre2); its regular-expression JIT uses
  **SLJIT** by Zoltán Herczeg (https://github.com/zherczeg/sljit)
- **lexbor** — Alexander Borisov and the lexbor contributors
  (https://github.com/lexbor/lexbor)
- **tree-sitter-perl** — the tree-sitter-perl contributors
  (https://github.com/tree-sitter-perl/tree-sitter-perl)
- **tree-sitter** core and the grammar parsers, which are fetched rather
  than vendored; their per-grammar licence manifest is generated into
  `src/ts/licenses_table.odin` and rendered as the human-readable notice
  `docs/licenses.md`, and `aubade about` summarizes it at runtime.

`aubade about` prints the same component versions and licences at runtime.
When bumping any pin, update that output (`src/cli/cmd_about.odin`) and this
file together.

## The vendored trees

| Component | Upstream | Pin | Licence | Licence text in this repo |
|---|---|---|---|---|
| lexbor | github.com/lexbor/lexbor | v2.3.0 (git submodule) | Apache-2.0 | `third_party/lexbor/LICENSE` |
| PCRE2 (+ SLJIT) | github.com/PCRE2Project/pcre2 | 10.47 release tarball | BSD-3-Clause / BSD-2-Clause | `third_party/pcre2/LICENCE.md`, `third_party/pcre2/deps/sljit/LICENSE` |
| SQLite | sqlite.org | 3.53.0 amalgamation | Public Domain | embedded in `third_party/sqlite/sqlite3.c` (header comment) |
| tree-sitter-perl | github.com/tree-sitter-perl/tree-sitter-perl | `ad74e6db234c35d537de9358799a8e0cc4f5dee0` | MIT | `third_party/tree-sitter-perl/LICENSE` |

### lexbor — HTML5 parser (git submodule)

Pristine upstream tree, so it is registered as a git submodule pinned at the
`v2.3.0` tag. After cloning this repository, fetch it with:

    git submodule update --init third_party/lexbor

The build compiles only the HTML parser stack — core, dom, encoding, html,
ns, tag, unicode, punycode, and the current platform's ports — directly with
`-DLEXBOR_STATIC` (no cmake involved); the css/selectors trees that the HTML
headers reference are compiled too, while url/utils/wasm stay uncompiled.
`odin run tools/build -- install-lexbor` produces
`lib/<os>_<arch>/liblexbor.a`.

Bump procedure:

1. `git -C third_party/lexbor fetch --tags`
2. `git -C third_party/lexbor checkout --detach <new-tag-sha>`
3. `git add third_party/lexbor` (records the new gitlink)
4. Delete `lib/<os>_<arch>/liblexbor.a` and run
   `odin run tools/build -- install-lexbor`
5. Update the version row in `src/cli/cmd_about.odin` and the table above.

### PCRE2 — regular expressions (patched tree)

Vendored from the official release tarball (10.47), not a git checkout,
because the tree here is not pristine: upstream's NON-AUTOTOOLS-BUILD
renames (`pcre2.h.generic` → `pcre2.h`,
`pcre2_chartables.c.dist` → `pcre2_chartables.c`) are applied, `src/config.h`
carries the 8-bit + JIT selection, and the standalone tools and tests are
excluded. A submodule checkout would not reproduce this file set.
`third_party/pcre2/README.md` documents the tree, the configuration, and the
version-bump checklist (rebuild `config.h`, re-check `PCRE2_SOURCES`,
re-emit the checksum registry).

### SQLite — embedded database (amalgamation)

The amalgamation zip is SQLite's canonical distribution form — a git
checkout of a mirror does not yield `sqlite3.c`. Three files
(`sqlite3.c`, `sqlite3.h`, `sqlite3ext.h`) are vendored as-is;
`third_party/sqlite/PROVENANCE.txt` records the version and download URL,
and the public-domain dedication is embedded in the `sqlite3.c` header
comment. Bumping means downloading the new amalgamation zip, replacing the
three files, updating `PROVENANCE.txt`, `aubade about`, the table above,
and re-emitting the checksum registry.

### tree-sitter-perl — generated parser (derived artifact)

Upstream never commits `src/parser.c` (the project builds via
`tree-sitter generate`), so the generated parser for the pinned revision is
committed here together with the tree_sitter headers it includes. This is a
derived artifact of
`ad74e6db234c35d537de9358799a8e0cc4f5dee0` and cannot be a submodule.
`third_party/tree-sitter-perl/VENDORED.md` records the pin and the full
regeneration procedure for a new pin; its MIT licence text is committed
alongside as `LICENSE`; a regeneration re-emits the checksum registry.

## Integrity registry

`third_party/CHECKSUMS.txt` pins the SHA-256 of every file under the three
non-submodule trees, so accidental edits to the vendored sources surface
instead of silently becoming part of the build:

    odin run tools/build -- verify-checksums   # walk + compare (CI runs this)
    odin run tools/build -- emit-checksums     # regenerate after an
                                               # intentional change

After deliberately changing any vendored file (version bump, licence
addition), re-run `emit-checksums` and commit `CHECKSUMS.txt` together
with the change. lexbor is not covered — its revision is the submodule
gitlink, which git itself enforces. The trees are checked out with EOL
conversion disabled (`.gitattributes`, `third_party/** -text`) so the
registry holds on every platform.
