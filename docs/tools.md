# Tools

Aubade's MCP tool surface, group by group. `aubade tool list` previews
exactly what a session would see once contexts and modes are applied,
and `aubade tool show <name>` prints one tool's full schema. Which tools
are visible composes from config, contexts, and modes — the visibility
rules are in [Tool visibility](configuration.md#tool-visibility); the
editor-facing LSP surface is a separate, overlapping interface described
in [The LSP server](lsp-server.md).

**Symbol operations** — `symbol_list`, `symbol_find`,
`symbol_find_dead_code`, `symbol_find_references`,
`symbol_find_implementations`, `symbol_find_declaration`,
`symbol_replace_body`, `symbol_insert_before`, `symbol_insert_after`,
`symbol_move`, `symbol_rename`, `symbol_delete`,
`symbol_insert_docstring`, `symbol_delete_docstring`,
`symbol_replace_docstring`

`symbol_find_dead_code` reports definitions that are almost surely dead
inside the project. A whole-project scan counts every textual occurrence
of each definition name — comments, strings, and prose included, not
just source — and a candidate is a name that never occurs outside its
own declaration spans.

Two refinements keep the answer honest. Same-name definitions keep each
other alive — precision is preferred over recall — and
convention-invoked names are excluded: attributes or decorators directly
above a definition, plus entry-point prefixes (by default `test_`,
`Test`, and `main`). The result is a review queue rather than a verdict.
"Dead" means unused within this project; consumers outside it are
invisible.

**File operations** — `file_read`, `file_write`, `file_list_dir`,
`file_find`, `file_search`, `file_read_outline`, `file_replace`,
`file_insert_lines`\*, `file_replace_lines`\*, `file_delete_lines`\*,
`file_delete`, `file_move`

`file_read_outline` reads JSON/JSONC/JSON5/YAML structurally instead of
grepping. Without a `path` it renders an indented key tree with 0-based
line numbers and clamped value previews. With a jq-style path —
`.a.b[0].c`, quoted keys via `."odd key"` or `["odd key"]`, negative
indexes, or a terminal `[]` / `| keys` — it returns the exact value(s)
at that path with their line range.

The line numbers feed `file_read`/`file_replace` ranges directly.
Malformed files fail loudly, with the first error row.

**AST operations** — `ast_parse`, `ast_query`, `ast_find_duplicates`

`ast_find_duplicates` reports duplicated code deterministically from
tree-sitter structure. A whole-project scan hashes every named subtree
of at least `min_nodes` nodes over its full shape; comments and
formatting never reach the hash, but operators do. Equal hashes group
into clones: `exact` covers identical fragments, whilst `renamed` covers
copy-paste under a consistent identifier renaming with literal values
abstracted, so a partial rename that collapses two names into one does
not match.

Groups report maximal clones only, so interior blocks of a larger
duplicate do not re-report. Occurrences are 0-based inclusive line spans,
and the answer is byte-identical across runs. `path_prefix` filters the
report; the scan itself always covers the project.

**Memories** — `memory_write`, `memory_read`, `memory_list`,
`memory_replace`, `memory_rename`, `memory_delete`

Memories are persistent markdown notes under
`<project>/.aubade/memories` (project) and `~/.aubade/memories/global`
(shared, addressed by the `global/` name prefix). The onboarding flow
surfaces them in the session prompt; `read_only_memory_patterns` /
`ignored_memory_patterns` pin or hide entries (see
[Configuration](configuration.md)).

**Incident tracker** — `incident_create`, `incident_verify`,
`incident_update`, `incident_resolve`, `incident_delete`,
`incident_list`, `incident_get`, `sprint_start`, `sprint_close`,
`sprint_update`, `sprint_record_verification`, `sprint_list`,
`sprint_get`, `tracker_export`

An event-sourced bug and audit tracker scoped to the project. Incidents
are filed as `reported` and judged with `incident_verify`; false
positives are kept as data for FP statistics, never deleted. An incident
is resolved only after its root cause has been recorded.

Work happens in sprints. A sprint declares its must-do tasks up front,
and each task earns verification records — the latest one wins. Closing
is refused whilst a must task has neither a passing verification nor a
typed defer (`blocked`/`question`/`descope`).

The event log is the source of truth, and the CLI can query it without
an MCP client: `aubade tracker list/show/report`. `tracker export`
re-renders the sprint reports into `sprint_reports` rows in the SQLite
store, so no files are added to the project tree. `read_only` projects
strip the tracker's writing tools.

**Language servers** — `langserver_list`, `langserver_get_diagnostics`,
`langserver_get_code_actions`, `langserver_format`,
`langserver_get_inlay_hints`, `langserver_find_calls`; management
`langserver_start`\*, `langserver_stop`\*, `langserver_restart`\*,
`langserver_reload`\*

**Shadow git (optional)** — `shadow_snapshot`, `shadow_log`,
`shadow_diff`, `shadow_patch`, `shadow_restore`, `shadow_revert_file`

Shadow git keeps workspace snapshots in a private git repository under
the aubade home, separate from the project's own git history.
`shadow_snapshot` records one and returns its commit hash, whilst
`shadow_log`, `shadow_diff`, and `shadow_patch` inspect and export them.

`shadow_restore` and `shadow_revert_file` roll the workspace — or a
single file — back, passing the same containment and write-denial gate
as file writes. Restoring also deletes files the snapshot does not
track, though ignore-excluded files are spared; reverting a file that was
absent from the snapshot deletes it.

**Web (optional)** — `web_fetch`, `web_search` (needs a search provider
in `config.jsonc`: Brave, Tavily, Perplexity, DuckDuckGo, or SearXNG)

**Onboarding** — `onboarding_check`, `onboarding_read_instructions`,
`onboarding_run`

**Shell** — `shell_run`

**Project configuration** — `config_get`, `config_set`,
`config_delete`

**Capability markers (optional)** — `marker_symbolic_read`,
`marker_can_edit`, `marker_symbolic_edit` — no-op tools that let a
context's prompt key on what the client grants

## Optional tools

The tools marked `*` above, plus the shadow-git, web, and marker groups,
stay hidden until included. Inclusion is set via
`included_optional_tools` (or the whole set is pinned with
`fixed_tools`) in the global config, a context, a mode, or a project.
`read_only` projects strip every file-modifying tool, including the
config write pair. The full composition rules are in
[Tool visibility](configuration.md#tool-visibility).
