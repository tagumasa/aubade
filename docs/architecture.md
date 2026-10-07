# Architecture

Aubade is one binary in three roles — an MCP child, an LSP child, and
one per-project daemon that both children share. This page shows each
session mode as a diagram and the fabric underneath them; the deep dives
live in their own pages ([symbol engine](symbol-engine.md),
[memory](memory.md), [security model](security.md),
[the LSP server](lsp-server.md), [tools](tools.md)).

## MCP mode — an agent session

```
┌─────────────────┐
│    AI agent     │   Claude Code, Codex, OpenCode, Qwen, ZCode, …
└────────┬────────┘
         │
         │   MCP over stdio (JSON-RPC): tool calls down, answers up
         │
┌────────▼────────┐
│   aubade mcp    │   thin child, one per session — it parses the
└────────┬────────┘   protocol and forwards the work to the daemon
         │
         │   internal RPC over loopback TCP (token handshake)
         │
┌────────▼─────────────────────────────────────────┐
│                   aubade daemon                  │
│    one per project · spawned on demand · warm    │
│                                                  │
│  tree-sitter symbol engine + hot parse-tree LRU  │
│    ▲ symbol_list / symbol_find answer from here  │
│      instantly — no language server involved     │
│    │ backed by the SQLite store: name index +    │
│      per-file symbol payloads                    │
│                                                  │
│  language-server clients — lazy start, OS-level  │
│    memory containment                            │
│    ▲ references, implementations, declarations,  │
│      diagnostics, code actions, formatting,      │
│      inlay hints, call hierarchy                 │
│                                                  │
│  shadow git snapshots (optional) · web fetcher   │
└──────────────────────┬───────────────────────────┘
                       │
                       │   LSP (JSON-RPC), one client per language server
                       │
              ┌────────▼────────┐
              │ gopls · ols · … │
              └─────────────────┘
```

The child owns no state: every tool call is forwarded to the daemon, so
a second agent session on the same project reuses the same warm caches
and already-running language servers. What each tool does is
[tools.md](tools.md); how symbol answers resolve is
[symbol-engine.md](symbol-engine.md); language-server configuration and
containment are [configuration.md](configuration.md#language-servers).

## LSP mode — an editor session

```
┌───────────────────┐
│ VSCode / VSCodium │   the aubade extension is a thin launcher —
└─────────┬─────────┘   one aubade lsp child per workspace folder
          │
          │   LSP 3.17 over stdio (Content-Length)
          │
┌─────────▼─────────┐
│     aubade lsp    │   project root resolves at initialize
└──┬──────────────▲─┘   (rootUri, else workspaceFolders[0])
   │              │
   │ requests     │ pushes (daemon → child → editor):
   │              │ publishDiagnostics · registerCapability
   │              │ · workspace/applyEdit
   │              │
┌──▼───────────────────────────────────────────────┐
│                   aubade daemon                  │
│   the same daemon any aubade mcp children of the │
│   project share — one symbol index, one set of   │
│   language servers, one buffer state             │
│                                                  │
│  bundled tree-sitter grammars                    │
│    ▲ semantic-token captures and syntax-error    │
│      walks — no language server needed           │
│    ▲ document outlines (documentSymbol)          │
│                                                  │
│  language-server relays, registered dynamically  │
│    per language once that server is live:        │
│    definition · declaration · references ·       │
│    formatting · code actions · inlay hints ·     │
│    call hierarchy                                │
│                                                  │
│  editor buffers: the open document's truth —     │
│    agent edits to an editor-owned document go    │
│    back through the editor (round trip below)    │
└──────────────────────────────────────────────────┘
```

Requests flow down the left; the daemon also pushes up the right —
debounced diagnostics, the per-language dynamic registrations, and
edit applications. The full editor-facing capability list, sync rules,
and encoding negotiation are [lsp-server.md](lsp-server.md).

### The two-writer round trip

When an agent tool edit names a file whose document an editor owns (an
`lsp` child did the last didOpen), the edit crosses the editor instead
of the disk:

1. The daemon's routing face pins the observed document version V into
   every change (the version-pinned `documentChanges` form — never the
   version-less `changes` map) and pushes the batch to the owner child.
2. The child re-spells each document into the editor's own uri,
   converts the columns into the negotiated encoding, and forwards one
   `workspace/applyEdit`.
3. The editor applies; its `didChange` echo flows back through the
   document-sync face as the ordinary keystroke path.
4. The tool call answers only after `applied=true` **and** the echo
   advanced the applied version past V. Version-mismatch rejections
   retry against the fresh text within one bounded deadline.
5. Every unrouteable shape — a stuck or capability-less editor, a blown
   deadline — fails explicitly; the one fallback is the owner going
   away, which returns the document to the non-open state.

## The fabric both children share

- **Lifecycle**: a child spawns the daemon on demand (flock-guarded
  singleton per project) and reconnects to a warm one when it exists.
  Child liveness is a heartbeat; the daemon exits on its own once the
  last child disconnects.
- **Transport**: the internal RPC rides loopback TCP with an ephemeral
  port, a `0600` endpoint file in the daemon's `0700` directory, and a
  startup token checked at the hello handshake — every other method is
  refused until hello completes. The trust model and its limits are
  [security.md](security.md#process-model-and-local-ipc).
- **Load shedding**: the queues at both ends are bounded chans — a full
  inbound queue is refused while reading continues, and outbound frames
  past their deadline are dropped. Load is shed at the source rather
  than buffered. The bounds sit in [memory.md](memory.md)'s budget
  table.
- **Request memory**: each request's scratch lives on an arena destroyed
  when the request and its derived work complete — nothing per-request
  survives into daemon lifetime (the model is
  [memory.md](memory.md#model)).
- **Cancellation**: every stoppable operation carries a cancellation
  token (tokens derive from a parent, never appear on their own), and a
  cancel takes effect by the next checkpoint — a blocking wait, an RPC
  round trip, or the next file of a long CPU loop.
- **Threading**: both children share one shape — a stdio reader thread
  feeding a bounded frame queue into one dispatch loop. The LSP child
  adds two off-dispatch threads: the debounced publish pass and the
  apply worker (plus the registration drive on its starter thread), so
  a slow editor never parks the dispatch loop.
