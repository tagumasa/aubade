#!/bin/sh
# Package the Aubade VSCode extension into editors/vscode/*.vsix.
#
# npm is resolved from PATH first, then from the newest nvm-managed node:
# the nvm toolchain is often off the non-interactive PATH even when node
# itself is on it, so the fallback globs ~/.nvm/versions/node/*/bin/npm and
# takes the highest version (sort -V). Fails with a clear message when
# neither is present.
set -eu

cd "$(dirname "$0")"

NPM=""
if command -v npm >/dev/null 2>&1; then
    NPM="$(command -v npm)"
else
    for candidate in $(ls -1d "$HOME"/.nvm/versions/node/*/bin/npm 2>/dev/null | sort -V); do
        NPM="$candidate"
    done
fi
if [ -z "$NPM" ]; then
    echo "package-vsix.sh: npm not found on PATH and no ~/.nvm/versions/node/*/bin/npm" >&2
    echo "  install node (e.g. via nvm) and retry" >&2
    exit 1
fi
# `npm run` re-invokes npm through PATH, so the resolved toolchain directory
# must be on PATH for child scripts too.
PATH="$(dirname "$NPM"):$PATH"
export PATH
echo "using npm: $NPM"

# npm install generates package-lock.json on first run (committed for
# reproducible builds); node_modules is never shipped — esbuild bundles
# vscode-languageclient into out/extension.js and vsce runs with
# --no-dependencies.
"$NPM" install

rm -rf out
"$NPM" run compile

# Ship the repository's MIT LICENSE with the extension (vsce only looks in
# the extension directory); the copy is transient.
cp ../../LICENSE LICENSE
trap 'rm -f LICENSE' EXIT

./node_modules/.bin/vsce package --no-dependencies

vsix="$(ls -1t aubade-*.vsix | head -1)"
echo "package-vsix.sh: produced $(pwd)/$vsix"
