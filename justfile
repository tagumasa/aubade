# Aubade build tasks. scripts/build_install.sh / .ps1 build and install
# the binary; they mirror the build-binary recipe below.

# just runs every recipe line through sh on all platforms by default,
# and a stock MSVC environment has no sh (the Windows check recipe also
# uses PowerShell cmdlets) — so on Windows recipes run through Windows
# PowerShell instead.
set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

# Host target directory for the built C artifacts (grammars collection root)
os_name := if os() == "macos" { "darwin" } else { os() }
arch_name := if arch() == "aarch64" { "arm64" } else if arch() == "x86_64" { "amd64" } else { arch() }
grammars_dir := "lib/" + os_name + "_" + arch_name + "/grammars"
# Some grammar external scanners are C++ (norg, sql, wolfram): their
# objects reference the C++ runtime, so linking pulls it in. MSVC links
# the C++ runtime from the object file references on its own.
cxx_runtime := if os() == "macos" { "-extra-linker-flags:-lc++" } else if os() == "windows" { "" } else { "-extra-linker-flags:-lstdc++" }

# Show available tasks
default:
    @just --list

# Build the C artifacts (tree-sitter core, SQLite, PCRE2, lexbor) into lib/<os>_<arch>/
install-core:
    odin run tools/build -- install

# Build every grammar parser listed in tools/build/grammars.odin
build-parsers:
    odin run tools/build -- install-parsers

# Build a subset of grammar parsers, e.g. just parsers go,python
parsers langs:
    odin run tools/build -- install-parsers {{langs}}

# Link the aubade binary (requires the C artifacts in lib/). Unix recipes
# raise the file-descriptor soft limit first: odin keeps files open while
# resolving the grammar collection's imports, which blows past macOS's
# default terminal limit (256) — the exhaustion surfaces as "Failed to
# parse file" / "Unknown error whilst reading path" errors on the tail
# imports, indistinguishable from missing grammars. 10240 is macOS's
# usual hard limit; where it is not attainable the flag is skipped and
# the ambient limit stands.
[unix]
build-binary:
    ulimit -n 10240 2>/dev/null || true; odin build src -collection:src=src -collection:grammars={{grammars_dir}} {{cxx_runtime}} -out:aubade

[windows]
build-binary:
    odin build src -collection:src=src -collection:grammars={{grammars_dir}} {{cxx_runtime}} -out:aubade.exe

# Build the aubade binary (requires the C artifacts in lib/)
build: install-core build-parsers build-binary

# Type-check every Odin package with vet and strict style (raises the fd
# soft limit like build-binary). Every check/test recipe opens its log with
# the tree hash and the Odin version it ran: a failure is only actionable
# when the exact code and compiler are on record.
[unix]
check:
    #!/bin/sh
    set -eu
    git log --oneline -1 2>/dev/null || true
    odin version
    ulimit -n 10240 2>/dev/null || true
    odin check src -collection:src=src -collection:grammars={{grammars_dir}} -vet -strict-style
    for d in src/*/; do
        odin check "$d" -collection:src=src -collection:grammars={{grammars_dir}} -vet -strict-style -no-entry-point
    done
    odin check tests -collection:src=src -collection:grammars={{grammars_dir}} -vet -strict-style -no-entry-point
    for d in tools/build tools/verify scripts/extract_table; do
        odin check "$d" -collection:src=src -vet -strict-style
    done

[windows]
check:
    @git log --oneline -1 2> $null; if (-not $?) { Write-Host "(no git metadata)" }
    @odin version
    odin check src -collection:src=src -collection:grammars={{grammars_dir}} -vet -strict-style
    Get-ChildItem src -Directory | ForEach-Object { odin check $_.FullName -collection:src=src -collection:grammars={{grammars_dir}} -vet -strict-style -no-entry-point }
    odin check tests -collection:src=src -collection:grammars={{grammars_dir}} -vet -strict-style -no-entry-point
    @foreach ($d in @('tools/build','tools/verify','scripts/extract_table')) { odin check $d -collection:src=src -vet -strict-style }

# Run the test suite (raises the fd soft limit like build-binary)
[unix]
test:
    @git log --oneline -1 2>/dev/null || true
    @odin version
    ulimit -n 10240 2>/dev/null || true; odin test tests -collection:src=src -collection:grammars={{grammars_dir}} {{cxx_runtime}} -define:ODIN_TEST_THREADS=1

[windows]
test:
    @git log --oneline -1 2> $null; if (-not $?) { Write-Host "(no git metadata)" }
    @odin version
    odin test tests -collection:src=src -collection:grammars={{grammars_dir}} {{cxx_runtime}} -define:ODIN_TEST_THREADS=1

# Remove the C artifacts in lib/ entirely
clean:
    odin run tools/build -- clean

# Full C rebuild: use when the lib/ cache is corrupted, after a compiler
# update, or after changing the grammar pins in tools/build/grammars.odin.
rebuild-c: clean install-core build-parsers

# Real-binary E2E drivers on throwaway copies (pass --keep to inspect)
e2e-cli *args:
    python3 tools/e2e/cli_battery.py {{args}}

e2e-lsp *args:
    python3 tools/e2e/lsp_e2e.py {{args}}

e2e-editing *args:
    python3 tools/e2e/editing_e2e.py {{args}}

e2e-tracker *args:
    python3 tools/e2e/tracker_e2e.py {{args}}

e2e-langserver *args:
    python3 tools/e2e/langserver_e2e.py {{args}}

e2e-shadow *args:
    python3 tools/e2e/shadow_e2e.py {{args}}

e2e-daemon *args:
    python3 tools/e2e/daemon_e2e.py {{args}}
