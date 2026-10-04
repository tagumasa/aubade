# Aubade for VSCode / VSCodium

A thin launcher for aubade's LSP server (`aubade lsp`). The extension starts
one `aubade lsp` child per workspace folder and hands it the LSP wire; all
protocol logic lives in the server binary. The project root is resolved
server-side from initialize's `rootUri`, so the extension passes no
`--project`/`--project-from-cwd` flags and multi-root workspaces just work
(one child per folder, one daemon per project).

What you get once `aubade` is running:

- **Semantic-token highlights** (`textDocument/semanticTokens/full`) and a
  **document outline** (`textDocument/documentSymbol`) from aubade's bundled
  tree-sitter grammars — available immediately, no language server required.
- **Diagnostics** — tree-sitter syntax diagnostics immediately; once a real
  language server (gopls, pyright, rust-analyzer, ...) is available, aubade's
  daemon aggregates it and relays its diagnostics, definitions/references,
  formatting, and other features through (those arrive as dynamic
  registrations after the language server becomes ready).

## Prerequisite

`aubade` must be on PATH and must be a **v1.1 or newer build** (the `lsp`
subcommand does not exist before v1.1). Build and install it from the
repository root:

```sh
scripts/build_install.sh
```

## Installing

Build the vsix from the repository root (resolves npm from PATH or nvm), then
install it:

```sh
just vsix
codium --install-extension editors/vscode/aubade-*.vsix
```

On Windows, `just vsix` is unavailable: run `editors/vscode/package-vsix.sh`
through a POSIX shell such as Git Bash, or build the vsix inside the CI job
(Linux-only).

## Manual E2E check

1. `just vsix` produces `editors/vscode/aubade-*.vsix`.
2. `codium --install-extension editors/vscode/aubade-*.vsix` — exit 0;
   `codium --list-extensions` shows `tagumasa.aubade`.
3. Open a project folder (`code`/`codium <project>`), open a source file:
   expect semantic-token highlights and an outline (Outline view) without any
   language-server extension installed.
4. Introduce a syntax error (unbalanced brace): expect a syntax diagnostic
   (tree-sitter ERROR/MISSING) after a short debounce.
5. With a real language server installed (e.g. gopls), open a Go file:
   after the server becomes ready its diagnostics and navigation features
   relay through aubade.
6. Multi-root: add a second folder to the workspace — each folder gets its
   own child (Output panel shows one `Aubade: <folder>` channel per folder).

Uninstall with `codium --uninstall-extension tagumasa.aubade`.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `aubade.path` | `"aubade"` | Path to the aubade binary to launch (`<path> lsp`). |
| `aubade.diagnostics.disabledLanguages` | `[]` | Language IDs for which aubade suppresses its own diagnostics. |

### Per-language diagnostics toggle

Semantic tokens from multiple providers merge in the editor, but diagnostics
duplicate. If you already run a dedicated language-server extension for a
language (and do not want aubade's syntax squiggles beside its diagnostics),
list that language ID:

```jsonc
{
  "aubade.diagnostics.disabledLanguages": ["go", "python"]
}
```

Aubade's publications for those languages are replaced with an empty set.
This is a configuration surface, not advice: dedicated extensions and aubade
can otherwise coexist.

## Development

`editors/vscode/package-vsix.sh` (also wired as `just vsix`) resolves npm
from PATH, falling back to the newest nvm-managed node; runs `npm install`
(generating the committed `package-lock.json`), type-checks with `tsc`,
bundles `src/extension.ts` into a single `out/extension.js` with esbuild
(`vscode-languageclient` is bundled — the vsix ships no `node_modules`), and
packages with `vsce package --no-dependencies`.
