# Security model

Aubade is a local, single-user MCP server. This document describes the
safety layer: what it enforces, where each gate runs, and what it
deliberately does not promise. Config keys referenced here are documented in
[configuration.md](configuration.md).

The threat the safety layer addresses is a misdirected or prompt-injected
MCP client: tool calls that walk out of the project tree, exfiltrate
secrets into command output or web requests, execute destructive shell
commands, or read credential files. It is not a sandbox — commands and
language servers run with the invoking user's privileges.

## Process model and local IPC

One child process per MCP client session speaks MCP over stdio; one parent
daemon per project (flock-guarded singleton) owns the caches, language
servers, and database. The child talks to the parent over loopback TCP:

- The listen port is always ephemeral (`bind(0)`) — there is no port
  configuration surface to collide with or scan for.
- The endpoint (port plus a random startup token) is published in a `0600`
  file inside the daemon's `0700` directory under `AUBADE_HOME`, so only
  the owning user can read it. Loopback TCP accepts connections from any
  local process; possession of the token at the `svc.hello` handshake is
  what authorizes a connection. Every other request method is refused
  until hello completes, and the shutdown command re-checks the token.
- This protects against other local users, not against processes running
  as the same user — a same-user process can read the endpoint file and is
  inside the trust boundary by definition.

## Path containment

Every caller-supplied relative path is joined to the project root through
one validator (`safety.pathguard_validate_contained` / `pathguard_validate_contained_dir`),
used by the file tools, the editor buffer sync, the symbol and
language-server operations, the tree-sitter crawl, the shell tool's
working directory, and the shadow-git paths:

- Lexical checks reject `..` traversal (both separators), absolute
  relative paths, and — for identifiers that become path components, such
  as hook session IDs — separators, control characters, and traversal
  sequences.
- The validator then walks the path component by component with `lstat`,
  resolving symlinks as they appear. A symlink whose target lifts the walk
  above the root is an escape; chains that loop or exceed the resolution
  budget fail closed (`.Unresolved` is a refusal, never a pass). A
  not-yet-existing tail is checked through its verified ancestors, so a
  new file written through a symlinked directory is checked against the
  directory the write would actually touch.
- The project root itself is symlink-resolved once at every entry point
  (`safety.pathguard_resolve_root`), so containment compares canonical spellings
  (macOS `/var` vs `/private/var`) instead of lexical prefixes.

## Sensitive-path rules

The deny list recognizes three grades of sensitivity:

- **Deny globs (hard read block).** `file_read` refuses a target whose
  symlink-resolved path matches the deny globs — `**/.env`,
  `**/*.env.*`, `**/*.pem`, `**/*.key`, `**/id_rsa*`, `**/*credentials*`,
  `**/*secret*`, `**/.aws/credentials`, `**/.gnupg/**`, `**/.kube/config`,
  `**/token*`, `**/.npmrc`, `**/.pypirc`, `**/NTUSER.DAT` — and the same
  match skips entries in the `file_search` / `file_find` /
  `file_list_dir` walks and the symbol-index crawl, so credential files
  are neither readable, searchable, enumerable, nor indexed through the
  agent surface. Paths are percent-decoded, cleaned, and symlink-resolved
  before matching, case-insensitively on macOS/Windows filesystems. A
  system-location check (`/etc`, `/boot`, systemd, the docker sockets,
  the Windows registry hives) is applied on the same read path as
  defense in depth. The editor buffer sync is exempt: files the user
  opens in their own IDE are not agent requests.
- **Read-ask (advisory).** `file_read` prefixes its answer with a notice
  when the target looks credential-like but is not deny-globbed:
  basenames such as `*.p12`, `*.jks`, `*.ppk`, `creds.env`, or residency
  in directories such as `.docker`, `.azure`, `.config/hub`.
- **Write-denied (enforced on restore).** Exact paths and directory
  prefixes that must never be written: `/etc/sudoers`, `/etc/passwd`,
  `/etc/shadow`, `/etc/ssh/`, `/etc/pam.d/`, `/etc/systemd/`; the user's
  shell rc files, `.gitconfig`, `.netrc`, `.pgpass`, SSH keys and
  `authorized_keys`; the `.ssh`/`.aws`/`.gnupg`/`.kube`/`.docker`/
  `.azure`/`.config/{gh,hub}` trees; the AUBADE_HOME itself (including
  its `auth.yml` and `.env`); on Windows the DPAPI `Protect` and
  `Credentials` trees. Paths are `$VAR`-expanded before matching, and an
  expansion that empties path segments denies (fail closed — an unset
  variable must not shorten a path past the gate). The check is advisory
  with respect to time-of-check/time-of-use; it is enforced on
  shadow-git restore targets (`shadow_restore` refuses to write these).

## Shell execution

`shell_run` applies, in order:

1. **Structural parsing.** The command is tokenized with quoting,
   escapes, and command separators resolved — not regexed as a raw
   string. Constructs the parser cannot resolve deterministically
   (command substitution, variable expansion, unbalanced quotes) are
   reported as warnings.
2. **Blocked patterns.** The default rule set matches the normalized
   pipeline: recursive deletes from `/` or the home directory, `mkfs`,
   raw-disk `dd` and redirects to block devices, `curl`/`wget` piped
   into a shell, world-writable `chmod` on absolute paths, fork bombs,
   redirects into `/etc` and the Windows system directories,
   `find -delete`/`-exec rm`/`xargs rm` over the home directory, and the
   Windows `del`/`rmdir`/`format`/`Remove-Item -Recurse -Force` drive-root
   forms.
3. **Sensitive write-target detection.** Commands referencing `~/.ssh`,
   `.env`, `/etc`, `/boot`, raw `/dev` devices, or the cloud credential
   directories are refused (arguments to filter flags such as
   `--exclude` are skipped, so a grep over `--exclude .env` still runs).
4. **Optional executable allowlist.** If `allowed_shell_commands`
   configures any pattern, every sub-command's executable must match the
   anchored patterns and any non-deterministic construct refuses the
   whole command.
5. **Containment and hygiene at spawn.** The working directory is
   validated against the project root (the root itself is allowed); the
   child environment is scrubbed (below); output is capped at 10 MiB per
   stream; a 120 s safety timeout kills runaway children (clamped to the
   request's remaining deadline, and a cancelled request kills the
   command mid-run); the JSON answer is length-limited.

`blocked_shell_commands` / `allowed_shell_commands` are regex patterns
matched against the normalized full command line, merged global →
project (concatenation — project config can extend the lists, never
shrink them). A pattern that fails to compile warns and is skipped; one
bad regex does not take the guard down. A session without a safety
checker refuses to run any command.

## Environment hygiene

The shell child's environment is rebuilt from an allowlist of prefixes
(`HOME`, `PATH`, `LANG`, `GOPATH`, `XDG_`, `AUBADE_`, `GIT_`, ...). On
top of the prefix check: any variable whose name contains `KEY`,
`TOKEN`, `SECRET`, `PASSWORD`, `CREDENTIAL`, `PASSWD`, or `AUTH` is
dropped; values containing null bytes are dropped; path-like variables
(`PATH`, `PYTHONPATH`, `GOPATH`, ...) reject values with `..` segments;
`GOPROXY` must be `OFF`, `DIRECT`, or an `http(s)://` URL; values are
capped at 8 KiB (`GIT_*` at 1 KiB).

Language servers are user-configured tooling, launched from the
registry or `language_server_commands` in config: they inherit the
daemon's environment, not the scrubbed one. A foreign project's language
server configuration is untrusted — review it the same way you review its
build scripts.

## Network egress (web tools)

Web fetch and search go through the daemon's fetcher, which applies:

- **Scheme and host gates.** Only `http`/`https`; the host must not be
  an obvious private or local-network name unless `web.allow_private_hosts`
  is set or the host is listed in `web.whitelist_hosts`.
- **URL guard.** Cloud metadata endpoints are blocked by address
  (`169.254.169.254`, `169.254.170.2`, `100.100.100.200`), the entire
  link-local range is blocked, and known exfiltration/staging hosts
  (webhook/request-capture services, paste sites) are blocked by
  hostname pattern. `data:` URLs with base64 payloads are blocked. The
  hostname is canonicalised before matching (single-integer, hex, and
  octal IPv4 forms; mixed notation; IPv4-mapped IPv6), so an alternate
  encoding of a blocked address does not bypass the lookup.
- **Configured patterns.** `blocked_url_patterns` (global + project,
  merged) are regexes matched against the raw URL string before any
  request; invalid patterns warn and are skipped.
- **Secrets in URLs.** A URL that embeds a vendor token (`sk-...`,
  `ghp_...`, `AKIA...`, ...) is refused, checked both raw and
  query-unescaped.
- **Redirects.** Every redirect hop re-runs the full gate bundle — an
  allowed page redirecting to a blocked or secret-bearing URL is
  refused before the hop is dialed.
- **Volume and lifecycle.** `web.fetch_limit_bytes` caps the transfer
  (hard ceiling 50 MiB); concurrent fetches are slot-capped (a full slot
  set answers busy instead of queueing); a cancelled request aborts the
  transfer; the proxy setting is scheme-validated
  (`http/https/socks5/socks5h`).
- **Redaction.** Fetched page text is scrubbed (below) before it
  reaches the model.

Host checks operate on the URL's host as written; DNS resolution-time
rebinding (a public hostname resolving to a private address) is not
re-checked after resolution.

## Output hygiene

- **Redaction.** A regex rule set scrubs vendor API keys, bearer
  tokens, private key blocks, environment-variable secrets, JSON secret
  fields, database connection strings, JWTs, and URL credentials /
  sensitive query parameters (`access_token`, `api_key`, ...) from tool
  output. Input is capped at 1 MiB. Web fetch text is redacted today.
- **Answer caps.** Search and read tools are token-capped
  (`max_answer_chars` / `default_max_tool_answer_chars`), bounding how
  much data one call can move into the model's context.

## Tool surface and write capability

Contexts and modes fold tool visibility (see
[configuration.md](configuration.md#contexts)); per client, duplicated or
dangerous tools are excluded entirely rather than merely discouraged. A
`read_only: true` project strips every tool marked as an editor —
including the config write pair — at **both** hosts, and the daemon
additionally refuses every mutating RPC method with `project is
read-only`, so a client that never saw the stripped tool list still
cannot mutate.

## Edit safety net

When shadow git is enabled, an isolated repository under
`AUBADE_HOME/snapshot/<projectID>` (the project directory wired in via
`GIT_WORK_TREE`) tracks workspace state as snapshots, giving a rollback
path for tool edits. Every git conversation holds the repository mutex
and runs under a 60 s timeout; git output is capped at 50 MiB. Restore
targets pass the write-denied gate above.

## Configuration trust

Config composes from the global file in `AUBADE_HOME` and the project's
`.aubade/project.jsonc` (+ `project.local.jsonc`). The project files
travel with the repository: a cloned repo can carry ignore lists,
shell-command and URL block patterns (which can only extend the guard
lists), and `language_server_commands` — process spawn directives.
Review a foreign `.aubade/` directory before pointing aubade at a
repository, the same way you would review its build scripts. Aubade
never rewrites user config files as a side effect of reading them;
machine-written state goes to the registry file and the internal
database.

User-controlled secrets (web provider API keys) live in the global
config under `AUBADE_HOME`; that tree is in the write-denied set, and
values are never echoed into tool output by the config tooling.

## Limits and non-goals

- The gates are check-time decisions: the write gate is advisory with
  respect to races (TOCTOU), and containment is re-validated per call
  but cannot fence a file another process moves after the check.
- The deny-list read block covers the agent surface (`file_read`,
  search/find/list walks, the index crawl); it is not a filesystem
  permission, and the IDE's own buffer sync is deliberately exempt.
- `shell_run` children run as the user, unsandboxed (no namespaces,
  seccomp, or chroot). The guard blocks pattern classes of destructive
  commands; it cannot judge arbitrary misuse.
- URL blocking is name- and literal-address-based; it does not pin
  resolved IPs.
- The IPC boundary authenticates against other local users only;
  same-user processes are trusted.
