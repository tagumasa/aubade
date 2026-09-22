# Aubade Configuration

Every aubade-owned configuration file is **JSONC** — JSON with `//` comments
and tolerated trailing commas. Files are generated exactly once from commented
templates by an explicit command (`aubade init`, `aubade project create`,
`aubade context create`, `aubade mode create`) and are never rewritten as a
side effect of reading them: aubade rewrites only its own machine-owned state
(the `projects.json` registry and the SQLite database).

A key set to `null` — or removed — means "unset": the built-in default applies.
Unknown keys warn and are skipped, so a typo never fails a session start. Each
config file is capped at 1 MiB.

## File locations

| File | Created by | Scope |
|------|------------|-------|
| `~/.aubade/config.jsonc` | `aubade init` | Global, shared across all projects |
| `~/.aubade/contexts/<name>.jsonc` | `aubade context create` | Custom context (global) |
| `~/.aubade/modes/<name>.jsonc` | `aubade mode create` | Custom mode (global) |
| `~/.aubade/projects.json` | aubade itself | Machine-owned project registry — never edit |
| `<project>/.aubade/project.jsonc` | `aubade project create .` | Per project, versioned |
| `<project>/.aubade/project.local.jsonc` | by hand | Per project, local overrides, keep out of VCS |

`~/.aubade` is overridable with the `AUBADE_HOME` environment variable. The
per-project `.aubade` directory location follows the global
`project_aubade_folder_location` template (default `$projectDir/.aubade`;
placeholders: `$projectDir`, `$projectFolderName`). Everything aubade keeps
for the project lives under it: the config files, the index database, and
the memories.

## Global configuration (`~/.aubade/config.jsonc`)

| Key | Default | Meaning |
|-----|---------|---------|
| `line_ending` | `"native"` | Line-ending convention when writing source files: `"lf"`, `"crlf"`, or `"native"`. Overridable per project. |
| `log_level` | `"warning"` | Minimum log level: `"debug"`, `"info"`, `"warning"`, `"error"`. The `--log-level` flag overrides it per command. |
| `trace_lsp_communication` | `false` | Trace the communication between aubade and language servers. |
| `eager_language_servers` | `false` | Start all language servers at session start instead of lazily on first use. |
| `ignored_paths` | `[]` | Paths to ignore across all projects (gitignore syntax: `*` and `**` allowed). Applied by the file tools' walk, the symbol index crawl, and `project check-ignore`; a configured path is a hard skip — a `.gitignore` negation cannot re-include it. A project's list extends this one. |
| `read_only_memory_patterns` | `[]` | Regex patterns that mark matching memory entries read-only. A project's list extends this one. |
| `ignored_memory_patterns` | `[]` | Regex patterns for memories to ignore completely. A project's list extends this one. |
| `tool_timeout` | `30` | Timeout in seconds after which tool executions are terminated. |
| `default_max_tool_answer_chars` | `150000` | Default character cap for tool answers. |
| `excluded_tools` | `[]` | Tool names (namespaced, e.g. `"symbol_find"`) to exclude globally. |
| `included_optional_tools` | `[]` | Optional tools (disabled by default) to include. |
| `fixed_tools` | `[]` | Exact base tool set, replacing the default set. Cannot be combined with `excluded_tools` / `included_optional_tools`. |
| `base_modes` | `[]` | Mode names that are always active. The active set is `base_modes` + `default_modes` (+ a project's `added_modes`). |
| `default_modes` | `["interactive", "editing"]` | Mode names activated by default. A project's `default_modes` replaces this list. |
| `symbol_info_budget` | `10` | Time budget (seconds) per tool call for retrieving extra symbol information. `0` disables the budget. Overridable per project. |
| `project_aubade_folder_location` | `"$projectDir/.aubade"` | Template for the per-project data folder location. |
| `blocked_shell_commands` | `[]` | Regex patterns blocking shell commands (matched against the normalized full command line). A project's list extends this one. |
| `allowed_shell_commands` | `[]` | Regex patterns allowing shell commands; when non-empty, only matching commands are permitted. A project's list extends this one. |
| `blocked_url_patterns` | `[]` | Regex patterns blocking URLs for the web tools (matched against the raw URL string, including every redirect hop). A project's list extends this one. |
| `web` | see below | Web fetch/search configuration. |

## Project configuration (`.aubade/project.jsonc`)

All global shared keys above are also valid here (`line_ending`,
`symbol_info_budget`, tool visibility, mode/memory/shell pattern lists) with
per-project semantics: a project's `default_modes` **replaces** the global
list, while the pattern lists (`ignored_paths`, memory patterns, shell
patterns) **extend** their global counterparts. Project-only keys:

| Key | Default | Meaning |
|-----|---------|---------|
| `project_name` | — | The name by which the project is referenced within aubade. |
| `language_servers` | `[]` | Servers to start, one object per server: `{"name": <language id>, "path": <server binary>}`. See [Language servers](#language-servers). |
| `language_server_commands` | `{}` | Language id → explicit argv (`argv[0]` is an executable path or a PATH name). An entry wins over a `language_servers` path and over the built-in command. |
| `language_server_options` | `{}` | Language id → initialization-options object, passed through at the initialize handshake and merged over the server's built-in options (your top-level keys win). |
| `encoding` | `"utf-8"` | The encoding used by text files in the project (UTF-8, UTF-16, latin-1). |
| `ignore_all_files_in_gitignore` | `true` | Whether the project's `.gitignore` files are used to ignore files in the file tools' walk and the symbol index crawl. The built-in directory exclusions (`.git`, `node_modules`, …) always apply. |
| `ignored_paths` | `[]` | Additional paths to ignore in this project (extends the global list). |
| `read_only` | `false` | Read-only mode: every file-modifying tool is stripped, including the config write pair. |
| `initial_prompt` | `""` | Initial prompt, appended as a dedicated section of the system prompt served on session start. |
| `added_modes` | `[]` | Extra modes activated in addition to the default set. |
| `additional_workspace_folders` | `[]` | Extra workspace folders for cross-package reference support in monorepos. |

`language_server_commands` and `language_server_options` are **live** keys:
`config_set` applies them without a restart (running servers restart on
demand), and `langserver_reload` picks up hand edits.

## Local override (`.aubade/project.local.jsonc`)

Developer-specific overrides of the project config. Use the same keys as
`project.jsonc`; any key set here overrides the `project.jsonc` value **whole**
— a list or map key replaces its counterpart entirely, it does not merge. The
file is created by hand (or seeded once by `aubade project create`) and kept
out of version control.

## Language servers

`language_servers` names the servers to start, one object per server:
`{"name": <language id>, "path": <server binary>}`. `name` is the language id
(`"go"`; for C use `"cpp"`, for JavaScript `"typescript"`). `path` is an OS
path to that server's binary:

- **absolute** — used verbatim; keeps working when aubade is spawned without
  a useful `PATH` (some clients scrub the environment);
- **`~/`-anchored** — expanded against the home directory;
- **relative** — anchored at the project root, not the daemon's working
  directory;
- **omitted or empty** — normal resolution: the built-in registry command is
  searched in `PATH`.

The resolved path becomes the server's start command as-is; a missing or
non-executable binary fails closed with an error naming the exact path tried.
Resolution precedence for one language:

1. `language_server_commands` argv (only `argv[0]` is verified),
2. the `language_servers` entry's `path`,
3. the built-in registry command searched in `PATH`.

A language needing extra arguments takes a full argv in
`language_server_commands`; initialization options go in
`language_server_options` — those are the server's own options, the binary's
location is designated by `language_servers`' `path`, never there.

Servers start lazily on first semantic use by default;
`eager_language_servers: true` restores starting all of them at session
start. Every server process is memory-contained: a multi-gigabyte ceiling per
server, with extra headroom for gopls (cgroup v2 on Linux, an RSS
watchdog on macOS — built-in defaults, not config keys). When a contained
server is killed at the limit,
the restart machinery brings it back on the next call.

## Tool visibility

Tool visibility composes from every layer — global config, project config,
context, mode — through one triple:

- `excluded_tools` / `included_optional_tools` — **incremental** mode:
  start from the default set, remove / add;
- `fixed_tools` — **fixed** mode: an exact set replacing the default.
  Combining `fixed_tools` with an incremental selector is a load error.

Optional tools (the line-editing trio, shadow git, web, management markers)
stay hidden until included. A `read_only: true` project strips every
file-modifying tool, including the config write pair. Unknown tool names warn
and are skipped.

Preview the folded result for a project with `aubade tool list`.

## Modes

Modes are named presets that exclude tools and inject prompts. Built-ins:

| Mode | Effect |
|------|--------|
| `interactive` | Interactive mode for clarification and step-by-step work (default). |
| `editing` | All tools, with detailed instructions for code editing (default). |
| `planning` | Only read-only tools, focused on analysis and planning. |
| `onboarding` | Only read-only tools, focused on collecting and saving project memories. |
| `no-onboarding` | The onboarding process is not used. |
| `no-memories` | Excludes the memory tools (and onboarding, which relies on memory). |
| `one-shot` | Focus on completely finishing a task without interaction. |

The active set is `base_modes` (global) + `default_modes` (global, replaced by
a project's own list) + `added_modes` (project, additional). Custom modes live
in `~/.aubade/modes/<name>.jsonc` (`aubade mode create`), with the keys
`description`, `prompt`, and the visibility triple.

## Contexts

Contexts adapt tool descriptions, visibility, and prompts for specific MCP
clients, selected at startup with `--context <name>` (the default is
`desktop-app`). Built-ins:

| Context | Single project | Notes |
|---------|----------------|-------|
| `agent` | — | System prompt provided at startup. |
| `antigravity` | yes | IDE coding agent; basic file/shell ops excluded. |
| `chatgpt` | — | Desktop chat client; full toolset with a chat-interface prompt. |
| `claudecode` | yes | Claude Code; file/shell duplicates excluded. |
| `codex` | — | Codex; file/shell tools and line editing excluded. |
| `copilot-cli` | yes | CLI coding agent; basic ops excluded. |
| `desktop-app` | — | Full toolset (the default). |
| `ide` | yes | Generic IDE coding agent. |
| `jb-ai-assistant` | yes | JetBrains AI Assistant. |
| `jb-copilot-plugin` | yes | JetBrains Copilot plugin. |
| `junie` | yes | Junie. |
| `oaicompat-agent` | — | OpenAI-compatible tool definitions. |
| `qwen` | yes | Qwen Code; file/shell duplicates excluded. |
| `vscode` | yes | VS Code. |
| `zcode` | yes | ZCode; file/shell duplicates excluded. |

A context marked `single_project: true` pins the server to the project
resolved at startup and drops `config_get`. Custom contexts live in
`~/.aubade/contexts/<name>.jsonc`; `aubade context create --from-internal
<name>` starts from a copy of a built-in. Custom files are resolved before
the built-ins, so a user file can shadow a built-in name.

## Web configuration

The `web` block controls `web_fetch` / `web_search`:

```jsonc
"web": {
    "fetch_proxy": "",            // http://, https://, socks5://, or socks5h:// URL
    "fetch_limit_bytes": 0,       // cap for fetched bytes, 0..52428800 (50 MiB)
    "search_provider": "auto",    // auto | brave | tavily | perplexity | duckduckgo | searxng
    "allow_private_hosts": false, // whether fetching private-network hosts is allowed (rarely wise)
    "whitelist_hosts": [],        // bare hostnames exempt from the private-host guard
    "brave":      { "api_keys": [], "max_results": 0, "enabled": false },
    "tavily":     { "api_keys": [], "base_url": "", "max_results": 0, "enabled": false },
    "perplexity": { "api_keys": [], "max_results": 0, "enabled": false },
    "duckduckgo": { "max_results": 0, "enabled": false },
    "searxng":    { "base_url": "", "max_results": 0, "enabled": false },
}
```

`search_provider: "auto"` picks the first provider with credentials.
`web_search` stays hidden until a provider is configured.

## Precedence summary

For any shared key the effective value resolves project → global → built-in
default. Whether a project value merges or replaces depends on the key:

| Behaviour | Keys |
|-----------|------|
| Project **replaces** | `default_modes`, `line_ending`, `symbol_info_budget`, visibility triple, `language_server_commands` / `language_server_options` (per language in `project.local.jsonc`) |
| Project **extends** | `ignored_paths`, `blocked_shell_commands`, `allowed_shell_commands`, `blocked_url_patterns`, `read_only_memory_patterns`, `ignored_memory_patterns` |

`project.local.jsonc` overrides `project.jsonc` key-whole for every key.

## Managing configuration at runtime

- `config_get` — read effective values; with `include_schema: true` it
  documents every key with its schema.
- `config_set` / `config_delete` — write `.aubade/project.jsonc` through the
  daemon (validated, applied live for the language-server keys; map-valued
  keys take a `member` for one language id).
- `aubade config edit` — open `config.jsonc` in `$EDITOR`.
- `langserver_reload` — apply hand-edited language-server keys to a running
  daemon; a new session picks them up regardless.
