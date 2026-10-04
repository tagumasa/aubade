# Aubade

A symbol-level code intelligence server for AI agents and code editors: agents connect over the Model Context Protocol, editors over the Language Server Protocol, and one shared per-project daemon answers both.

Named after the poetic form called the aubade — a song about lovers parting at dawn. The best-known example comes from Shakespeare's Romeo and Juliet (III.v), where Juliet tries to convince Romeo that the bird they hear is the nightingale, not the lark — that it is still night and not yet morning:

> *Wilt thou be gone? it is not yet near day:*
> *It was the nightingale, and not the lark,*
> *That pierc'd the fearful hollow of thine ear.*

LLMs make the same mistake Juliet makes: they hear what they want to hear. They hallucinate functions that don't exist, misread call chains, and confuse the structure of the code in front of them. They mistake the lark for the nightingale. Aubade provides the ground truth — symbol definitions from LSP, AST structure from tree-sitter, safe rollback via shadow git — so that when the LLM insists it's still night, you have the dawn to prove otherwise.

## Quick start

```bash
# Build from source: clone with submodules (lexbor lives in one):
#   git clone --recurse-submodules <repo-url>
# Requires the Odin compiler (latest nightly, odin-lang.org), `just`,
# and a C/C++ toolchain.
just build

# Build and install in one step:
sh scripts/build_install.sh

# Initialise global configuration
aubade init

# Register with your AI client
aubade setup claudecode    # or: codex / opencode / qwen / zcode

# Editors (VSCode / VSCodium): package and install the extension
just vsix
codium --install-extension editors/vscode/aubade-*.vsix
```

The install script needs the C artifacts under `lib/` that
`just build` produces; with a plain `just build` you instead put the
repository-root binary on your `PATH` yourself. Install destinations,
`AUBADE_INSTALL_DIR`, and the Windows procedure —
`scripts\build_install.ps1` from a Visual Studio developer prompt —
are in [Building from source](#building-from-source) and
[docs/windows-build.md](docs/windows-build.md).

For manual MCP configuration, the server command is:

```json
{
  "mcpServers": {
    "aubade": {
      "command": "aubade",
      "args": ["mcp", "--context", "agent", "--project-from-cwd"]
    }
  }
}
```

MCP is served over stdio. Every CLI command accepts three global flags: `--project <path-or-registered-name>`, `--project-from-cwd`, and `--log-level <DEBUG|INFO|WARNING|ERROR>`.

Editors are served over LSP 3.17 (`aubade lsp`): the extension is a thin launcher that starts one child per workspace folder and needs no registration command — see [docs/lsp-server.md](docs/lsp-server.md) and [editors/vscode/README.md](editors/vscode/README.md). `aubade setup` registers AI clients only.

Client-by-client setup, hooks, and the full configuration reference live in [docs/](docs/index.md).

## How it works

Aubade serves symbol-level code intelligence from two engines:

- **Tree-sitter (primary)**: symbol search (`symbol_find`, `symbol_list`) runs fully in-process from bundled grammars — no language server involved, so it works instantly at session start and keeps working when a server crashes. For any language with a bundled grammar, tree-sitter takes priority; the language server is consulted for symbol search only when the tree-sitter pass yields nothing (a language without a grammar, or an outline that came back empty) — never when it returns symbols.
- **Language servers (semantic, lazy)**: references, implementations, declarations, diagnostics, code actions, formatting, inlay hints, and call hierarchy — plus symbol search for languages tree-sitter does not serve — start the matching language server on first use and keep it alive while idle. When a server dies, the next call replaces it; a failed start arms a short cooldown, so a broken toolchain cannot fork-bomb.

In mixed-language projects, languages without a bundled grammar (e.g. Lean) still appear in directory- and project-wide symbol searches through whatever language servers are already running — broad searches never *start* servers, they only use running ones, so a project-wide `symbol_find` cannot fan out into dozens of server launches.

```
        AI agent                           Editor (VSCode / VSCodium)
  (Claude, Codex, ...)
            │                                           │
            │ MCP over stdio                            │ LSP 3.17 over stdio
            ▼                                           ▼
      ┌───────────┐                               ┌───────────┐
      │ aubade mcp│                               │ aubade lsp│
      └─────┬─────┘                               └─────┬─────┘
            │                                           │
            └─────────────────────┬─────────────────────┘
            internal RPC (loopback TCP, token handshake)
                                  ▼
        ┌───────────────────────────────────────────────────┐
        │                   aubade daemon                   │
        │   one per project, shared by every session child  │
        │                                                   │
        │  tree-sitter symbol engine + hot parse-tree LRU,  │
        │     on the SQLite store (name index, per-file     │
        │    payloads): symbol_find / symbol_list answer    │
        │       instantly, no language server involved      │
        │                                                   │
        │    language-server clients (lazy start, capped    │
        │   memory): references, diagnostics, formatting,   │
        │     code actions, inlay hints, call hierarchy     │
        │                                                   │
        │    shadow git snapshots (optional), web fetcher   │
        └─────────────────────────┬─────────────────────────┘
                                  │ LSP (JSON-RPC), started lazily
                                  ▼
                   ┌─────────────────────────────┐
                   │    gopls, rust-analyzer,    │
                   │ typescript-language-server, │
                   │  ols, pyright, clangd, ...  │
                   └─────────────────────────────┘
```

Per-mode diagrams (MCP and LSP), the child↔daemon fabric, and the
two-writer round trip are in [docs/architecture.md](docs/architecture.md).

Symbol resolution is three-tier: a SQLite name index answers name queries without parsing anything; each file's symbol forest is persisted as a compact payload in SQLite, with a bounded in-memory mirror in front; and a bounded LRU keeps hot parse trees in the daemon's memory so follow-up work on recently-touched files skips re-parsing. The on-disk index survives restarts, and every cache is bounded by entries and bytes — the full resident-memory budget, its ledgers, and how the parse-tree charge is calibrated are specified in [docs/memory.md](docs/memory.md). The full architecture (lookup flow, crawl, freshness heal, edit propagation) is in [docs/symbol-engine.md](docs/symbol-engine.md).

Language servers run under OS-level memory containment — cgroup v2 on Linux, an RSS watchdog on macOS, kernel Job objects on Windows — with built-in multi-gigabyte defaults; a contained server killed at its limit restarts on the next call. Platform details and caveats are in [docs/configuration.md](docs/configuration.md#language-servers); aubade's own resident-memory budget is [docs/memory.md](docs/memory.md).

The tree-sitter engine has known blind spots: most grammars' outline queries are inferred (full overrides exist for Go, Odin, and TypeScript), receiver-based owner nesting is Go-only (Rust `impl`-block methods surface as top-level functions), and markup/data languages have no symbol outline. The full list is in [docs/symbol-engine.md](docs/symbol-engine.md#known-limitations).

## Process model

One binary, three roles:

- **MCP child** (`aubade mcp --project <path>`) — one lightweight process per client session. It speaks MCP over stdio and forwards all work to the daemon over a local RPC.
- **LSP child** (`aubade lsp`) — one process per editor window. It speaks LSP 3.17 over stdio: semantic tokens and the document outline from the bundled grammars, debounced tree-sitter syntax diagnostics, and navigation/formatting/code-action/inlay-hint/call-hierarchy relays into the project's language servers. Hover, completion, and rename stay with the editor's dedicated language-server extensions. When the editor owns a document, agent edits to it route through `workspace/applyEdit`, so the agent and the human edit through one arbiter. Details: [docs/lsp-server.md](docs/lsp-server.md).
- **Daemon** (one per project, spawned on demand, singleton via a lock) — owns the language-server clients, tree-sitter caches, editor buffers, the SQLite store, and shadow git. It outlives individual sessions: the next session reconnects to warm caches and already-running language servers, and the daemon exits on its own once the last child disconnects.

`aubade daemon status` reports the pid, port, and connected children; `aubade daemon stop` is refused while sessions are still connected.

Project state lives under `<project>/.aubade/`: `project.jsonc`, `aubade.db` (SQLite — the symbol index, per-file symbol payloads, the append-only tracker event log, and the rendered sprint reports the tracker exports), `memories/` (project memory notes). The global home is `~/.aubade`, overridable with `AUBADE_HOME`: `config.jsonc`, `contexts/`, `modes/`, the machine-owned `projects.json` registry, global `memories/`, per-project `daemon/` runtime directories, shadow-git `snapshot/` repositories, and `hook_data/` for the client hooks.

## Tools

Aubade's MCP tools fall into the groups below; the reference with per-tool semantics is [docs/tools.md](docs/tools.md), and `aubade tool list` previews exactly what a session would see once contexts and modes are applied. The editor-facing LSP surface is a separate, overlapping interface — see [docs/lsp-server.md](docs/lsp-server.md).

**Symbol operations** — `symbol_list`, `symbol_find`, `symbol_find_dead_code`, `symbol_find_references`, `symbol_find_implementations`, `symbol_find_declaration`, `symbol_replace_body`, `symbol_insert_before`, `symbol_insert_after`, `symbol_move`, `symbol_rename`, `symbol_delete`, `symbol_insert_docstring`, `symbol_delete_docstring`, `symbol_replace_docstring`

**File operations** — `file_read`, `file_write`, `file_list_dir`, `file_find`, `file_search`, `file_read_outline`, `file_replace`, `file_insert_lines`*, `file_replace_lines`*, `file_delete_lines`*, `file_delete`, `file_move`

**AST operations** — `ast_parse`, `ast_query`, `ast_find_duplicates`

**Memories** — `memory_write`, `memory_read`, `memory_list`, `memory_replace`, `memory_rename`, `memory_delete`

**Incident tracker** — `incident_create`, `incident_verify`, `incident_update`, `incident_resolve`, `incident_delete`, `incident_list`, `incident_get`, `sprint_start`, `sprint_close`, `sprint_update`, `sprint_record_verification`, `sprint_list`, `sprint_get`, `tracker_export`

**Language servers** — `langserver_list`, `langserver_get_diagnostics`, `langserver_get_code_actions`, `langserver_format`, `langserver_get_inlay_hints`, `langserver_find_calls`; management `langserver_start`*, `langserver_stop`*, `langserver_restart`*, `langserver_reload`*

**Shadow git (optional)** — `shadow_snapshot`, `shadow_log`, `shadow_diff`, `shadow_patch`, `shadow_restore`, `shadow_revert_file`

**Web (optional)** — `web_fetch`, `web_search` (needs a search provider in `config.jsonc`: Brave, Tavily, Perplexity, DuckDuckGo, or SearXNG)

**Onboarding** — `onboarding_check`, `onboarding_read_instructions`, `onboarding_run`

**Shell** — `shell_run`

**Project configuration** — `config_get`, `config_set`, `config_delete`

**Capability markers (optional)** — `marker_symbolic_read`, `marker_can_edit`, `marker_symbolic_edit` — no-op tools that let a context's prompt key on what the client grants

Optional tools — the ones marked `*` above, plus the shadow-git, web, and marker groups — stay hidden until included. Inclusion is set via `included_optional_tools` (or the whole set is pinned with `fixed_tools`) in the global config, a context, a mode, or a project; `read_only` projects strip every file-modifying tool, including the config write pair. The composition rules are in [docs/configuration.md](docs/configuration.md#tool-visibility).

## Configuration

Everything is JSONC — JSON with comments. Files are generated once from commented templates by explicit commands (`aubade init`, `aubade project create .`) and are never rewritten as a side effect of reading them; aubade rewrites only its own machine-owned state (`projects.json` and the database).

- **Global** `~/.aubade/config.jsonc` — shared across projects: tool visibility, shell/web guards, memory patterns, defaults.
- **Project** `<project>/.aubade/project.jsonc` — per-project language servers, ignore rules, `read_only`, added modes; `.aubade/project.local.jsonc` overrides it per developer, unversioned.
- **Contexts** adapt tool descriptions and visibility per MCP client (`--context claudecode`, `--context zcode`, …); **modes** are named presets that exclude tools and inject prompts. Custom ones live in `~/.aubade/contexts/` and `~/.aubade/modes/`.

Every key, default, and precedence rule is in [docs/configuration.md](docs/configuration.md); language-server configuration and memory containment in its [Language servers](docs/configuration.md#language-servers) section.

## Supported languages

Language servers for the languages you are likely to work with are configured out of the box: C/C++ (clangd), C#, Elixir, Go (gopls), Haskell, Java (jdtls), Kotlin, Lua, Odin (ols), Python (pyright, with jedi and ty alternates), Ruby (ruby-lsp), Rust (rust-analyzer), Scala (metals), Swift (sourcekit-lsp), Terraform, TypeScript (typescript-language-server, with vtsls), Zig (zls), and more.

Symbol search runs on the bundled tree-sitter grammars, including C#, Dart, Go, Java, Kotlin, Odin, Python, Rust, TypeScript, and Zig. A language server is consulted only for languages without a grammar (see [How it works](#how-it-works)).

## Safety

- **Path containment**: every path is cleaned and resolved — symlinks included — and must stay inside the project root and the configured workspace folders; the check fails closed.
- **Sensitive reads**: reading credential-like paths is gated by a read-ask heuristic; **shell** commands run through allow/block regex rules with a scrubbed environment; **web** tools pass a URL guard.
- **No telemetry**: no analytics, crash reporting, or update checks, and never an outbound request of aubade's own — all state stays in `~/.aubade` and `<project>/.aubade/` on your machine.

The full security model — every gate, the IPC trust boundary, limits, and non-goals — is [docs/security.md](docs/security.md).

## CLI reference

```
aubade init                                           Initialise global configuration
aubade mcp [--project <path>]                         Start an MCP session (stdio)
aubade lsp [--project <path>]                         Start an LSP server child session (stdio)
aubade daemon status | stop                           Inspect or stop the project daemon
aubade setup <client>                                 Register with a client: claudecode, codex, opencode, qwen, zcode
aubade uninstall <client>                             Remove the registration (inverse of setup)
aubade project create|list|index|delete|check-ignore|doctor    Manage projects
aubade tool list | show <name>                        Inspect the tool table and folded visibility
aubade memory list|show|write|check|fix-references    Manage memories
aubade tracker list|show|export|report                Inspect incidents and sprints (report prints TSV/JSON)
aubade prompt render|list|show                        Render and inspect system prompts
aubade prompt override list|create|edit|delete        Manage prompt-template overrides
aubade context list|create|edit|delete                Manage contexts
aubade mode list|create|edit|delete                   Manage modes
aubade config edit                                    Edit config.jsonc in $EDITOR
aubade hook activate|cleanup|remind|auto-approve      Client hook helper (claudecode, codex, vscode)
aubade about                                          Print version, licence, and vendored components
```

## Relationship to Serena

Aubade's design reference is the MCP tool interface of [oraios/serena](https://github.com/oraios/serena). It shares no code with Serena, and it reaches a similar feature set by different means, under its own namespaced tool names (`symbol_find`, `file_replace`, `incident_create`, …) — `aubade tool list` shows the current surface. Notable differences:

- A single static binary written in Odin — no Python runtime; the bundled grammars dominate the on-disk size but never slow startup
- A per-project daemon keeps language servers, caches, and the SQLite symbol store warm across sessions
- Three-tier symbol resolution: a SQLite name index, per-file sparse symbol payloads in SQLite, and a bounded hot parse-tree LRU
- OS-level memory containment for language servers (cgroup v2 on Linux, an RSS watchdog on macOS, kernel Job objects on Windows)
- Shadow git for workspace snapshots and rollback
- A built-in incident tracker with verification records and per-sprint reports
- An LSP 3.17 server face for code editors beside the MCP surface — semantic tokens, outline, diagnostics, and navigation relays from the same daemon — with a VSCode extension

## Building from source

Prerequisites and the clone step are in the [Quick start](#quick-start). After the first `just build` (the grammar compile is slow; later builds are incremental), two ways to put the binary on your machine:

- **Install script** — `sh scripts/build_install.sh` (Linux/macOS) installs to `~/.local/bin`; on Windows, `scripts\build_install.ps1` installs to `%LOCALAPPDATA%\Programs\aubade` and adds the directory to the user PATH. `AUBADE_INSTALL_DIR` overrides the destination on both; the scripts warn when a different `aubade` resolves earlier on `PATH`.
- **Manual** — a plain `just build` leaves the `aubade` binary at the repository root; copy it anywhere on your `PATH` yourself.

Windows-specific build details are in [docs/windows-build.md](docs/windows-build.md).

## Requirements

- Language servers for the languages you work with — optional; symbol search needs none of them
- Linux, macOS, or Windows

## Contributing

Bug fixes are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for
guidelines on new features and the release cadence.

## Licence

MIT — see [LICENSE](LICENSE).

Third-party components (SQLite, PCRE2, lexbor, tree-sitter and its
grammars) — acknowledgments, pins, and licences:
[third_party/README.md](third_party/README.md); the per-grammar licence
notice is [docs/licenses.md](docs/licenses.md); `aubade about` prints the
summary at runtime.
