# Aubade Documentation

- [Architecture](architecture.md) — the two session modes as diagrams (MCP for agents, LSP for editors), the shared child↔daemon fabric, the two-writer round trip
- [Configuration](configuration.md) — every config key with defaults, precedence, language servers, contexts, modes, web
- [Tools](tools.md) — the MCP tool surface group by group: per-tool semantics, optional tools, visibility links
- [LSP server](lsp-server.md) — the `aubade lsp` editor face: capabilities, dynamic relays, encodings, the VSCode extension
- [Symbol engine](symbol-engine.md) — three-tier resolution, tree-sitter and LSP sources, crawl and discovery, freshness heal, edit propagation
- [Security model](security.md) — path containment, sensitive-path gates, shell/web guards, IPC, limits
- [Memory management](memory.md) — the resident-memory budget: caches, ledgers, bounds, SQLite hygiene, calibration
- [Harness setup](harnesses.md) — per-client registration (Claude Code, Codex, OpenCode, Qwen, ZCode), hooks, choosing a context
- [Building on Windows](windows-build.md) — MSVC toolchain, C artifacts, just recipes, troubleshooting
- [Licences](licenses.md) — generated per-grammar licence manifest and acknowledgments
