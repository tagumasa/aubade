# Aubade examples

Support artifacts for projects running the Aubade tracker: workflow
skills that drive the incident lifecycle, an Odin-conventions skill
for coding rules, and hook samples that keep the tracker in the
agent's context at session start.

```
examples/
  skills/
    file-incident/SKILL.md                  file a finding as soon as it is nameable
    resolve-incident/SKILL.md               re-test under verifying, resolve with evidence
    run-sprint/SKILL.md                     start, run, and close a scoped work period
    verify-incident/SKILL.md                confirm with evidence or reject with a pattern
    odin-conventions/SKILL.md              Odin coding conventions as a loadable skill
  hooks/
    claudecode/settings.example.json        Claude Code hook wiring
    tracker-context.sh                      SessionStart hook sample
```

## The skills

Each skill is one unit — the workflow skills trigger at the moment
that part of the lifecycle starts, and the conventions skill loads
whenever Odin code is written, reviewed, or renamed:

| Skill              | Enters when                                              |
|--------------------|----------------------------------------------------------|
| file-incident      | a bug or finding surfaces and is concrete enough to name |
| resolve-incident   | a fix for a tracked incident is done                     |
| run-sprint         | a work period begins, ends, or is reviewed               |
| verify-incident    | work is about to start on a reported incident            |
| odin-conventions   | Odin code is written, reviewed, or renamed               |

## Installing the skills

Copy the skill directories you want into one of the client's skill
locations:

| Client      | Project scope                 | Every project        |
|-------------|-------------------------------|----------------------|
| Claude Code | `<repo>/.claude/skills/`      | `~/.claude/skills/`  |
| Others      | `<repo>/.agents/skills/`      | `~/.agents/skills/`  |

The `.agents/skills/` locations are a shared convention read by several
Claude Code-compatible harnesses, so they are the best default when
more than one harness matters.

## Hooks

Hook commands ship with aubade itself (`aubade hook --help`):

- `activate` — SessionStart: tells the agent to activate the project
  and read the Aubade manual first.
- `remind` — PreToolUse: denies raw Read/Grep overuse and nudges toward
  Aubade's symbolic tools.
- `auto-approve` — PreToolUse: auto-allows Aubade's symbolic tools when
  the session runs under `acceptEdits`.
- `cleanup` — SessionEnd: drops the session's per-session hook data.

The `--client` flag accepts `claudecode` (default), `vscode`, and
`codex`. A Claude Code-compatible harness that is not on that list uses
the `claudecode` payload — the hook JSON contract is the same.

`tracker-context.sh` is a sample hook: it runs
`aubade tracker list --sprint current --project-from-cwd` and injects
the output as SessionStart `additionalContext`, so every session opens
with the sprint's open incidents. It needs only POSIX sh, and stays
silent (exit 0, no output) when the project has no tracker data.

### Claude Code

1. Copy `tracker-context.sh` to `<repo>/.claude/hooks/tracker-context.sh`.
2. Merge the `hooks` block from `hooks/claudecode/settings.example.json`
   into `~/.claude/settings.json` (user-wide) or
   `<repo>/.claude/settings.json` (shared).

`${CLAUDE_PROJECT_DIR}` resolves to the project root, which is also the
directory the tracker reads via `--project-from-cwd`.

### Other Claude Code-compatible harnesses

`aubade setup` registers the MCP server for Claude Code, Codex
(`codex mcp add`), Opencode (`~/.config/opencode/opencode.json`), and
Qwen Code (`qwen mcp add`) — each client's own config is written by
`aubade setup <client>`.

Hook wiring beyond Claude Code depends on what the harness accepts:

- A harness that runs the Claude Code hook JSON contract (SessionStart
  and PreToolUse entries in a settings-style JSON file) can reuse the
  Claude Code wiring above verbatim: copy the `hooks` block into the
  harness's config, adapt the project-dir variable, and keep
  `--client claudecode`.
- A harness without a hook facility still gets the tracker context
  through the skills and `aubade tracker list`; nothing in the skill
  set requires hooks.

## Trying the sample hook without wiring it

```sh
echo '{}' | AUBADE_BIN=~/.local/bin/aubade sh examples/hooks/tracker-context.sh
```

Run it from a project root that has a tracker (`.aubade/tracker/`).
With no tracker or no incidents the script prints nothing and exits 0.
