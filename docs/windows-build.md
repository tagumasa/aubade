# Building Aubade on Windows

Aubade's build has two phases: C artifacts (tree-sitter grammars, SQLite, PCRE2)
compiled by a build tool written in Odin, then the Odin binary linked against them.
On Windows the C toolchain is **MSVC-only** — MinGW and cross-compilation are not
supported.

## Prerequisites

| Tool | How to get it | Notes |
|------|---------------|-------|
| **Odin** (latest nightly) | https://odin-lang.org/docs/install/ | The tracked nightly is listed in AGENTS.md; CI pins the frozen dev-YYYY-M release via `setup-odin`. |
| **just** | `cargo install just` or `winget install just` | Command runner; optional but recommended. |
| **MSVC** | Visual Studio 2022+ with "Desktop development with C++" workload | The **x64 Native Tools Command Prompt** is required — it sets `cl.exe`, `link.exe`, and the include/lib paths. |
| **Git** | https://git-scm.com/download/win | The C-artifact build clones tree-sitter core and the grammar sources from GitHub (pinned tags/SHAs). |
| **vcpkg** | Visual Studio's "C++ vcpkg package manager" component, or a standalone clone | Provides the `libcurl.lib` the link step needs — see step 2. Must be on `PATH`. |

> **Do not use MinGW.** Odin's Windows target expects MSVC for linking C artifacts.

## Quick start (PowerShell from a VS Developer Prompt)

```powershell
# 1. Clone and enter the repo
git clone --recurse-submodules https://github.com/tagumasa/aubade.git
cd aubade

# 2. Build C artifacts (tree-sitter, SQLite, PCRE2, all grammars)
#    The first build is slow; incremental builds are fast.
just build

# 3. Provide libcurl for the link step (one-time per Odin install — step 2 below)
vcpkg install curl:x64-windows-static-md
$odinDir = Split-Path (Split-Path (Get-Command odin).Source)
New-Item -ItemType Directory -Force "$odinDir\vendor\curl\lib" | Out-Null
Copy-Item "$env:VCPKG_INSTALLATION_ROOT\installed\x64-windows-static-md\lib\libcurl.lib" "$odinDir\vendor\curl\lib\libcurl.lib"

# 4. Link the aubade binary
#    (just build already does this, but if you only need relinking:)
just build-binary

# 5. Install to %LOCALAPPDATA%\Programs\aubade (adds to user PATH)
.\scripts\build_install.ps1
```

After install, verify:

```powershell
aubade --version
# => aubade <version>
```

## Step-by-step

### 1. Build C artifacts

The build tool (`tools/build`) compiles tree-sitter core, SQLite, PCRE2, lexbor,
and every registered grammar parser into static libraries under
`lib/windows_amd64/`.

```powershell
# Full build (C core + all grammars):
just build

# Or step by step:
just install-core        # tree-sitter, SQLite, PCRE2, lexbor
just build-parsers       # all grammars
```

To build a subset of grammars (faster for development):

```powershell
just parsers go,odin,python
```

Output lives in `lib/windows_amd64/grammars/` — a single
`libtree-sitter-grammars.a` archive plus individual `.obj` files.

> **Known issue:** a few grammars (cobol, crystal, haskell, nim) have C++ scanners
> incompatible with MSVC. The build tool skips them automatically; the binary
> still starts but those languages won't have tree-sitter parsing.

### 2. Provide libcurl for `vendor:curl`

Aubade's web tools (`web_fetch` / `web_search`) link `vendor:curl` — Linux
links the system libcurl (plus mbedTLS, which the import block also names),
but on Windows the Odin toolchain ships no `libcurl.lib`, so one must be
placed in the toolchain's `vendor\curl\lib` before linking:

```powershell
vcpkg install curl:x64-windows-static-md

# Copy the import library next to Odin's vendor:curl package.
# ($env:VCPKG_INSTALLATION_ROOT is set by vcpkg; on GitHub-hosted
# runners it points at the vcpkg install — CI runs exactly these
# commands.)
$odinDir = Split-Path (Split-Path (Get-Command odin).Source)
New-Item -ItemType Directory -Force "$odinDir\vendor\curl\lib" | Out-Null
Copy-Item "$env:VCPKG_INSTALLATION_ROOT\installed\x64-windows-static-md\lib\libcurl.lib" "$odinDir\vendor\curl\lib\libcurl.lib"
```

The `[schannel]` feature flag no longer exists in vcpkg's curl port —
Schannel is its default TLS backend on Windows — so the plain triplet above
is the correct spelling. This is a one-time setup per Odin toolchain
install; redo it after replacing the compiler.

### 3. Link the Odin binary

```powershell
just build-binary
# equivalent to:
# odin build src -collection:src=src -collection:grammars=lib/windows_amd64/grammars -out:aubade.exe
```

The resulting `aubade.exe` is dominated by the grammars' const parse tables
in `.rodata`; unused grammars' pages never become resident.

### 4. Install

```powershell
.\scripts\build_install.ps1
```

This copies `aubade.exe` to `%LOCALAPPDATA%\Programs\aubade` and adds the
directory to the user-level `PATH`. Override the install directory with
`$env:AUBADE_INSTALL_DIR`.

### 5. Initialize and register clients

```powershell
aubade init                      # create global config (~/.aubade/)
aubade setup opencode            # register with OpenCode
aubade setup claudecode         # or Claude Code, Codex, ZCode, etc.
```

## Just recipes (Windows)

All `just` recipes use PowerShell on Windows (`set windows-shell` in justfile).

| Recipe | What it does |
|--------|-------------|
| `just build` | Full build: C artifacts + grammars + Odin binary |
| `just build-binary` | Link Odin binary only (requires `lib/`) |
| `just build-parsers` | Build every grammar parser |
| `just parsers <langs>` | Build a subset of grammars |
| `just install-core` | Build C core libraries (tree-sitter, SQLite, PCRE2) |
| `just check` | Type-check with `-vet -strict-style` |
| `just test` | Run test suite (`ODIN_TEST_THREADS=1`) |
| `just clean` | Remove all C artifacts in `lib/` |
| `just rebuild-c` | Clean + rebuild all C artifacts |

## Troubleshooting

### "C artifacts missing under lib\..."

Run `just build` first. The Odin compiler cannot link without the static
libraries in `lib/windows_amd64/grammars/`.

### "the Odin compiler is not on PATH"

Install the Odin nightly and ensure `odin` is on your `PATH`. The build tracks
the **latest nightly** — if a nightly breaks, pin the last known-good hash
(listed in AGENTS.md).

### Grammar build errors ("scanner may be incompatible with MSVC")

Expected for cobol, crystal, haskell, nim. The build continues and skips them.
No action needed.

### `just` not found

Install with `cargo install just` or `winget install just`. Alternatively, run
the underlying Odin commands directly (see justfile).

### "Failed to parse file" / "Unknown error whilst reading path grammars:*"

On Windows this usually means the `lib/` cache is corrupted. Run
`just rebuild-c` to do a clean rebuild of all C artifacts.

### PATH conflicts

`build_install.ps1` warns if another `aubade` resolves earlier on `PATH`.
Remove the conflicting entry, or set `$env:AUBADE_INSTALL_DIR` to control
the install location.

### Link errors mentioning curl (`curl_*` symbols, `libcurl.lib` not found)

`vendor:curl` needs a `libcurl.lib` in the Odin toolchain's
`vendor\curl\lib` — see step 2. This is the one link prerequisite the
compiler does not ship on Windows.

## Architecture notes

- **Single binary**: no Python runtime; the bundled grammars dominate the
  on-disk size but startup is instant.
- **Daemon model**: the first MCP session spawns a per-project daemon
  (`aubade _daemon --project <path>`) that keeps language servers, caches,
  and the SQLite symbol store warm. Subsequent sessions connect over TCP.
- **MSVC-only linking**: the C artifacts reference the C++ runtime (some
  grammar scanners are C++). MSVC links it automatically from object file
  references; MinGW does not.
