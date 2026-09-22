# PCRE2 (vendored)

PCRE2 10.47, vendored from the official release tarball:
https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.gz

Aubade links the 8-bit library with JIT as a static archive
(`lib/<os>/<arch>/pcre2-8.a`, built by `tools/build`). The sources here are
pristine upstream files with exactly two renames prescribed by upstream's
NON-AUTOTOOLS-BUILD instructions:

- `src/pcre2.h`            ← `src/pcre2.h.generic`
- `src/pcre2_chartables.c` ← `src/pcre2_chartables.c.dist`

## What is vendored

- `src/` — the library modules (`pcre2_*.c`) and their private headers.
  Upstream's standalone tools and tests are NOT vendored: `pcre2_dftables.c`,
  `pcre2_fuzzsupport.c`, `pcre2_jit_test.c`, `pcre2demo.c`, `pcre2grep.c`,
  `pcre2posix.c`, `pcre2posix_test.c`, `pcre2test.c`, plus the autotools/
  CMake machinery (`config.h.*`, `pcre2.h.in`, `*.sym`).
- `deps/sljit/` — the SLJIT backend PCRE2's JIT compiles in via
  `#include "../deps/sljit/sljit_src/sljitLir.c"` (relative to `src/`), so its
  position inside this tree is load-bearing.

## Build configuration

`src/config.h` is upstream `config.h.generic` with two appended lines
(`#define SUPPORT_PCRE2_8`, `#define SUPPORT_JIT`) — the 8-bit + JIT library
selection — following upstream's NON-AUTOTOOLS-BUILD instructions. The
remaining selection, the code-unit width, is passed per library by
`tools/build` (`-DHAVE_CONFIG_H -DPCRE2_CODE_UNIT_WIDTH=8`). Upstream warns
that config usage can change between releases — after a version bump, re-check
NON-AUTOTOOLS-BUILD in the new tarball, rebuild `config.h` from the new
`config.h.generic` plus the two defines, and re-check the `PCRE2_SOURCES` list
in `tools/build/build_impl.odin`.

## Licenses

- PCRE2: BSD-3-Clause — `LICENCE.md` (the tarball's COPYING is GPL and covers
  only the pcre2grep/pcre2test tools, which are not vendored).
- SLJIT: BSD-2-Clause — `deps/sljit/LICENSE`.
