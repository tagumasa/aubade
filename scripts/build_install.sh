#!/usr/bin/env bash
# Build and install the Odin aubade binary to ~/.local/bin (override with
# AUBADE_INSTALL_DIR). The C artifacts under lib/ must already exist —
# `just build` produces them (a full 187-grammar build takes 35-40 minutes;
# later builds are incremental).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v odin >/dev/null 2>&1; then
    echo "error: the Odin compiler is not on PATH — install the tracked nightly first" >&2
    exit 1
fi

os_name="$(uname -s)"
case "$os_name" in
    Linux)  os_name="linux" ;;
    Darwin) os_name="darwin" ;;
    *)
        echo "error: unsupported OS: $os_name (Windows uses scripts/build_install.ps1)" >&2
        exit 1
        ;;
esac
arch_name="$(uname -m)"
case "$arch_name" in
    x86_64)          arch_name="amd64" ;;
    aarch64 | arm64) arch_name="arm64" ;;
    *)
        echo "error: unsupported architecture: $arch_name" >&2
        exit 1
        ;;
esac

lib_dir="$ROOT/lib/${os_name}_${arch_name}"
if [ ! -f "$lib_dir/libtree-sitter.a" ] || [ ! -d "$lib_dir/grammars" ]; then
    echo "error: C artifacts missing under $lib_dir (lib/ is untracked)" >&2
    echo "       run 'just build' first" >&2
    exit 1
fi

# Linker flags mirror the justfile's build-binary recipe; keep in sync.
cxx_runtime="-extra-linker-flags:-lstdc++"
if [ "$os_name" = "darwin" ]; then
    cxx_runtime="-extra-linker-flags:-lc++"
fi

echo "Building aubade from $ROOT ..."
cd "$ROOT"
# odin keeps files open while resolving the grammar collection's imports;
# macOS's default terminal fd soft limit (256) is too low for that (the
# failures look like missing grammars). 10240 is macOS's usual hard limit.
ulimit -n 10240 2>/dev/null || true
odin build src -collection:src=src -collection:grammars="$lib_dir/grammars" \
    "$cxx_runtime" -out:aubade

INSTALL_DIR="${AUBADE_INSTALL_DIR:-$HOME/.local/bin}"
mkdir -p "$INSTALL_DIR"
cp aubade "$INSTALL_DIR/aubade"
chmod 0755 "$INSTALL_DIR/aubade"

echo "Installed: $INSTALL_DIR/aubade"
"$INSTALL_DIR/aubade" --version

# Client registrations point at the absolute path of the binary that runs
# `aubade setup`, so a location change never breaks them — but another
# aubade earlier on PATH shadows this one in shells.
stale="$(command -v aubade || true)"
if [ -n "$stale" ] && [ "$stale" != "$INSTALL_DIR/aubade" ]; then
    echo ""
    echo "note: another aubade resolves earlier on PATH: $stale"
    echo "      (remove it if it is not wanted), then"
    echo "      register your preferred client(s):"
else
    echo ""
    echo "Make sure $INSTALL_DIR is in your PATH."
    echo "First run:  aubade init  — initialise global configuration"
    echo "Then register your preferred client(s):"
fi
echo "  aubade setup claudecode  — auto-configure Claude Code"
echo "  aubade setup codex       — auto-configure Codex CLI"
echo "  aubade setup opencode    — auto-configure OpenCode"
echo "  aubade setup zcode       — auto-configure ZCode"
