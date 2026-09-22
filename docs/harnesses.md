# Harness Setup (AI clients)

Aubade speaks MCP over stdio, so any MCP-capable client can run it.
First-class registration is a single command:

```bash
aubade setup claudecode     # or: codex / opencode / qwen / zcode
aubade uninstall claudecode # inverse of setup, same client names
```

Setup registers the **binary that is performing the setup** (its resolved
absolute path, not a bare `aubade`), so after rebuilding or reinstalling,
re-run `aubade setup <client>` — already-attached sessions keep running the
old binary otherwise. Re-running setup is always safe: an identical
registration is left untouched, a differing one is updated.

## Manual registration

For any client without a setup handler, point its MCP server configuration
at:

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

- `--context <name>` selects a built-in context (default `desktop-app`) —
  see [Choosing a context](#choosing-a-context) below.
- `--project-from-cwd` resolves the project from the working directory the
  client spawns aubade in; `--project <path-or-registered-name>` pins it
  explicitly instead.
- `--log-level <DEBUG|INFO|WARNING|ERROR>` overrides the config log level.

Hermes Agent and TRAE have no setup handler — see
[Hermes Agent](#hermes-agent) and [TRAE](#trae) below for their
manual registration.

## Claude Code

```bash
aubade setup claudecode
```

Registers through the client's own CLI:

```
claude mcp add --scope user aubade -- <aubade-binary> mcp --context claudecode --project-from-cwd
```

The `claudecode` context is single-project and excludes the tools that
duplicate Claude Code's built-in file/shell handling (`file_read`,
`file_write`, `shell_run`, `file_list_dir`); the search tools stay exposed so
content and name lookups can run through aubade's token-capped,
ignore-aware `file_search`/`file_find` instead of raw grep/glob. Setup
requires a functional `claude` on `PATH`.

**Hooks are recommended.** Claude Code fires session lifecycle hooks that
keep aubade's instructions in the model's context:

```
aubade hook activate   --client claudecode   # SessionStart
aubade hook remind     --client claudecode   # PreToolUse
aubade hook auto-approve --client claudecode # PreToolUse
aubade hook cleanup    --client claudecode   # SessionEnd
```

See [Hooks](#hooks) for what each verb does and
[`examples/hooks/claudecode/settings.example.json`](../examples/hooks/claudecode/settings.example.json)
for ready-to-merge wiring.

## Codex

```bash
aubade setup codex
```

Registers through the client's own CLI:

```
codex mcp add aubade -- <aubade-binary> mcp --context codex --project-from-cwd
```

The `codex` context excludes the tools that duplicate Codex's own: the file
tools (`file_read`, `file_write`, `file_list_dir`), line editing
(`file_replace`), and the shell tool. Setup requires a functional `codex`
on `PATH`. Hooks use `--client codex`.

## Hermes Agent

No `aubade setup` handler: registration is a manual edit of Hermes's YAML
config (`hermes mcp add` is interactive — it probes the server and asks for
per-tool confirmation — so it does not automate well). Hermes reads MCP
servers from the `mcp_servers` map in `$HERMES_HOME/config.yaml`
(default `~/.hermes/config.yaml`; Windows:
`%LOCALAPPDATA%\hermes\config.yaml`). If the file already has an
`mcp_servers:` key, add only the `aubade` entry under it; otherwise append
the whole block at the end of the file:

```yaml
mcp_servers:
  aubade:
    command: /absolute/path/to/aubade
    args: ["mcp", "--project-from-cwd"]
    enabled: true
```

Prefer the resolved absolute path of the binary — Hermes spawns exactly what
is written, and a bare `aubade` only works while it stays on `PATH`. No
`--context` is passed (the default `desktop-app` context exposes the full
toolset); add `"--context", "<name>"` to `args` for a tighter context — see
[Choosing a context](#choosing-a-context).

To remove the registration, delete the `aubade` key from `mcp_servers`
(dropping the whole `mcp_servers:` key when it becomes empty is fine), or
run `hermes mcp remove aubade` — that one subcommand is non-interactive.

## OpenCode

```bash
aubade setup opencode
```

Writes the entry into `~/.config/opencode/opencode.json` (under `mcp.aubade`,
type `local`, command as an array), preserving an existing file's formatting:

```json
{
  "mcp": {
    "aubade": {
      "type": "local",
      "command": ["<aubade-binary>", "mcp", "--project-from-cwd"]
    }
  }
}
```

Note the registration passes **no `--context`**: OpenCode runs on the default
`desktop-app` context (full toolset). Add `"--context", "<name>"` to the
command array manually if you want a tighter context.

## Qwen Code

```bash
aubade setup qwen
```

Registers through the client's own CLI (user scope, `~/.qwen/settings.json`
under `mcpServers`):

```
qwen mcp add aubade -- <aubade-binary> mcp --context qwen --project-from-cwd
```

The `qwen` context is single-project and excludes the tools duplicated by
Qwen Code's own file/shell tools (`file_read`, `file_write`, `shell_run`,
`file_list_dir`); the search tools stay exposed — prefer aubade's
token-capped `file_search`/`file_find`. Whether the MCP `instructions`
field (which carries the context prompt) reaches the model is not
documented for Qwen Code; the exclusion applies regardless, since tool
visibility is folded server-side. The entry as JSON:

```json
{
  "mcpServers": {
    "aubade": {
      "command": "/absolute/path/to/aubade",
      "args": ["mcp", "--context", "qwen", "--project-from-cwd"]
    }
  }
}
```

Setup requires a functional `qwen` on `PATH` (npm: `@qwen-code/qwen-code`).

## TRAE

No `aubade setup` handler: TRAE has no non-interactive registration command
(the IDE manages servers through its Settings → MCP panel, and the TraeCode
CLI opens the config in an editor), and its documented configuration sites
are per-project or YAML — neither fits a machine-global automated write.
Two products, two formats:

**TRAE IDE** — per-project `.trae/mcp.json` in the project root, the same
`mcpServers` shape as the manual registration above:

```json
{
  "mcpServers": {
    "aubade": {
      "command": "/absolute/path/to/aubade",
      "args": ["mcp", "--project-from-cwd"]
    }
  }
}
```

If the file already has an `mcpServers` key, add only the `aubade` entry
under it. The file is committed per project (mind version control); TRAE's
global MCP location is not officially documented, so for a machine-wide
registration use the IDE's Settings → MCP → Add (manually) panel, which
accepts the same JSON. No `--context` is passed by default — see
[Choosing a context](#choosing-a-context).

**TraeCode CLI** — global config `trae_cli.yaml` (opened by
`traecli config edit`), `mcp_servers` is a list:

```yaml
mcp_servers:
- name: aubade
  type: stdio
  command: /absolute/path/to/aubade
  args: ["mcp", "--project-from-cwd"]
```

To remove the registration, delete the entry from the respective file (or
the `aubade` key / project file in the IDE).

## ZCode

```bash
aubade setup zcode
```

Writes the server entry into `~/.zcode/cli/config.json` (under
`mcp.servers.aubade`, type stdio, args `mcp --context zcode
--project-from-cwd`), merging into an existing file while preserving its
comments and layout.

### Known client issue: ZCode ignores the MCP `instructions` field

MCP servers return an `instructions` string in the `initialize` response,
which clients surface to the model (Claude Code and most other clients do).
Aubade puts the context prompt (e.g. the `zcode` context's tool-usage rules)
and the onboarding directive there.

As of August 2026, ZCode appears not to pass this field to the model: tool
names and descriptions arrive, but the instructions text does not.
Consequences in ZCode: the context prompt and onboarding directive are not
seen at session start or after `/compact`, so the model may skip
`onboarding_check`/`onboarding_run`. The `onboarding_read_instructions` tool still
returns the full context-aware prompt when called, and clients that honor
`instructions` are unaffected.

Workaround: `aubade setup zcode` maintains the following snippet in
`~/.zcode/AGENTS.md` as a marker-delimited managed block
(`<!-- aubade:zcode:begin -->` … `<!-- aubade:zcode:end -->`); re-running
setup refreshes the block while content outside it is preserved, and
`aubade uninstall zcode` removes it (the file is deleted when the block was
its only content). To add it manually, paste:

```
When the aubade MCP server is connected: at the start of every session, and
again immediately after any context compaction (/compact), call the aubade
tools `onboarding_read_instructions` and `onboarding_check` before starting
work. If onboarding has not been performed, run the `onboarding_run` tool
first.
```

This looks like a ZCode-side gap; re-test after ZCode updates and remove
this note once the instructions reach the model.

The `zcode` context is single-project and excludes tools redundant with the
client's own file/shell tools (`file_read`, `file_write`, `shell_run`,
`file_list_dir`); the search tools stay exposed — prefer aubade's
token-capped, ignore-aware `file_search`/`file_find` over built-in
grep/glob. ZCode also speaks the Claude Code hook JSON
contract, so hook configs pass `--client claudecode`;
ZCode has no SessionEnd event, so `cleanup` has no natural wiring there.

## Choosing a context

Contexts adapt tool visibility, descriptions, and prompts to the client (the
full built-in inventory is in [configuration.md](configuration.md#contexts)).
Per client family:

| Client shape | Context | Why |
|--------------|---------|-----|
| CLI coding agent with own file/shell tools | `claudecode`, `codex`, `copilot-cli`, `qwen`, `zcode` | Duplicated tools excluded; CLI agents get the symbolic-tools-first prompt. |
| System prompt provided by the harness | `agent`, `oaicompat-agent` | Full toolset minus `onboarding_read_instructions`; the harness supplies the system prompt. |
| IDE-embedded agent | `antigravity`, `ide`, `jb-ai-assistant`, `jb-copilot-plugin`, `junie`, `vscode` | Basic file/shell ops assumed covered; single-project. |
| Desktop chat app | `chatgpt`, `desktop-app` (default) | Full toolset; `chatgpt` tunes the prompt for the desktop chat interface. |

Custom contexts live in `~/.aubade/contexts/<name>.jsonc`;
`aubade context create --from-internal <name>` copies a built-in as a
starting point.

## Hooks

Hook verbs ship with the binary (`aubade hook [--client <name>] <verb>`).
Each reads the client's hook payload as JSON from stdin and prints the
response JSON on stdout (nothing when the hook decides not to speak);
per-session state lives under `$AUBADE_HOME/hook_data/<session_id>`.

| Verb | Event | What it does |
|------|-------|--------------|
| `activate` | SessionStart | Tells the agent to activate the project and read the Aubade manual first. |
| `remind` | PreToolUse | Denies raw file-read and text-search overuse and nudges toward aubade's symbolic tools. |
| `auto-approve` | PreToolUse | Auto-allows aubade's symbolic tools when the session runs under `acceptEdits`. |
| `cleanup` | SessionEnd | Drops the session's per-session hook data. |

The `--client` flag accepts `claudecode` (default), `vscode`, and `codex` —
it selects the payload dialect, and ZCode speaks the Claude Code one. Sample
wiring for Claude Code and ZCode lives under [`examples/hooks/`](../examples/README.md),
including `tracker-context.sh`, a SessionStart sample that injects the active
sprint's open incidents into the session context.

## Uninstall

`aubade uninstall <client>` is the inverse of setup, per client:

- **claudecode / codex / qwen** — removes the registration through the
  client's own `mcp remove` command (after checking its `mcp list`);
  "not configured" is a no-op success.
- **opencode** — removes the `mcp.aubade` member from
  `~/.config/opencode/opencode.json`, preserving the rest of the file.
- **zcode** — removes the config entry and the managed block from
  `~/.zcode/AGENTS.md`; the AGENTS.md file is deleted when the block was its
  only content, and hollow parent objects (`"servers": {}`) stay in place.
