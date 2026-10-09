# The LSP server (`aubade lsp`)

Aubade serves editors as well as AI agents. The same per-project daemon
that answers MCP tool calls also backs an LSP 3.17 server face, spoken by
the `aubade lsp` child over stdio (Content-Length framing). One child per
editor window, one daemon per project: the editor child and any agent
children of the same project share the language servers, open buffers,
and the symbol index.

```
editor (VSCode / VSCodium) ⇄ LSP (stdio) ⇄ aubade lsp child ⇄ daemon ⇄ gopls, rust-analyzer, ...
```

## What the face serves

- **Semantic tokens** — `textDocument/semanticTokens/full`, a static
  capability. Tokens come from the bundled tree-sitter grammars' highlight
  queries, so they are available from the first keystroke, before any
  language server exists; the token/modifier legend advertised at
  initialize is derived from the same mapping tables the encoder uses.
- **Document outline** — `textDocument/documentSymbol`, static. The reply
  is hierarchical `DocumentSymbol[]` when the client declared
  `hierarchicalDocumentSymbolSupport`, flat `SymbolInformation[]`
  otherwise; the two forms are never mixed.
- **Syntax diagnostics** — `textDocument/publishDiagnostics` carrying
  tree-sitter ERROR/MISSING walks. Publishing is debounced: a burst of
  changes inside the quiet window (`PUBLISH_DEBOUNCE_MS`) coalesces into
  one publish per document, and `didClose` clears a document's
  diagnostics immediately. Once a real language server for the language
  is live, the tree-sitter publish stands back — the live server's own
  diagnostics are relayed instead, stamped with the version the editor's
  buffer carries.
- **Definition jumps** — `textDocument/definition` and `/declaration`,
  static. The daemon answers them itself: the identifier under the cursor
  is read off the document's current contents, the file's own outline
  answers with identifier extents, and the project's name index tops an
  otherwise-empty answer up cross-file. No language server is involved —
  the jump works with none running. The answer is name-exact (scope
  resolution and stdlib names are the servers' business); a click the
  outline and the index do not know answers empty.
- **References relay** — `textDocument/references`, the one navigation an
  index cannot answer, relayed to the project's language servers. It
  arrives by **dynamic registration** (one `client/registerCapability`
  batch per language, with a per-language documentSelector) once that
  language's server is ready; when a server stops, the registrations are
  withdrawn the same way.
- **Language-server ops relays** — the same dynamic drive registers
  `textDocument/formatting`, `/codeAction`, `/inlayHint`, and the
  call-hierarchy family (`prepareCallHierarchy`, `incomingCalls`,
  `outgoingCalls`), relayed to the running language server.
- **Two-writer editing** — when an editor owns a document (its `lsp`
  child was the last to open it), agent tool edits to that document are
  routed through `workspace/applyEdit` in the version-pinned
  `documentChanges` form — never the version-less `changes` map — and the
  tool call waits until the applied version advances past the version it
  pinned. The agent and the human edit the same buffer through one
  arbiter, so neither side's write is silently clobbered. The routing
  fails loudly when the editor cannot take the edit; it never falls back
  to writing the file behind the editor's back.

## What it deliberately does not serve

Hover, completion, rename, `typeDefinition`, `implementation`, and
`workspace/symbol` are not offered — neither statically nor in the
dynamic batch. Editors already run dedicated language-server extensions
for those; aubade's face exists for what the bundled grammars give every
file instantly and for one shared daemon per project, not to shadow the
real servers.

## Document sync and encodings

Sync is **Full**: `didOpen`/`didChange` carry the whole document text.
Ranged or incremental changes are refused — dropped with at most one log
line per document. `didSave` is accepted and carries no server-side
work; `didClose` releases the daemon-side buffer and clears diagnostics.

The **position encoding** is negotiated at initialize: **utf-8 when the
client offers it** (columns are bytes — tree-sitter's own convention),
**utf-16 otherwise**. The specification makes utf-16 the mandatory
baseline every client must accept, so an offer naming neither encoding
degrades to utf-16 instead of failing the connection. Under a utf-8
connection, wire columns convert through the open document's text in
both directions, and an answer piece whose text cannot be served is
**dropped** rather than emitted with a UTF-16 number in a byte column.

**Degradation rule** (the relay rule): misses and failures answer empty
arrays or empty token data, never error responses; each degraded shape
logs at most one line per document per open. An answer the daemon
computed over disk truth the open view does not mirror (an evicted
buffer) is treated the same way — empty, not misplaced spans.

## VSCode / VSCodium extension

The extension in [`editors/vscode/`](../editors/vscode/README.md) is a
thin launcher: it starts one `aubade lsp` child per workspace folder and
hands it the LSP wire — all protocol logic lives in the server binary.
Build it with `just vsix` and install the produced `aubade-*.vsix`;
with `aubade.path` unset the extension resolves the launch command from
the editor's `PATH` and then the documented install locations (setting
`aubade.path` overrides the whole ladder), and the
binary must be a v1.1 or newer build. The setting
`aubade.diagnostics.disabledLanguages` suppresses aubade's own
diagnostics per language — for languages where a dedicated extension
already publishes them. Full install steps, the manual E2E checklist,
and packaging notes are in the extension's README.

## Command line

```
aubade lsp [--project <path>] [--project-from-cwd] [--log-level <LEVEL>]
```

The project root resolves at `initialize` — the client's `rootUri`, else
the first workspace folder — unless `--project`/`--project-from-cwd`
binds it at startup, so the extension passes no project flags and
multi-root workspaces get one child (and one daemon) per folder. The
child spawns and connects to the project daemon on demand, exactly like
the MCP child. Shared child flags — `--in-process`,
`--trace-lsp-communication`, and the heartbeat tuning flags — behave as
they do on `aubade mcp`.

## End-to-end driver

`just e2e-lspserver` (from the repository root) drives a real
`aubade lsp` child over stdio through the full lifecycle: initialize and
encoding negotiation, semantic tokens, document outline, syntax
diagnostics inside the debounce window, the dynamic-registration batch,
a definition jump answered from the daemon's index at a use site, mirrored
diagnostics once a (fake) language server goes live, then
`shutdown`/`exit`. It runs on every CI leg.
