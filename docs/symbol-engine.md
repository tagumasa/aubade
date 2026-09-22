# Symbol Engine

How aubade answers "where is this symbol defined?" across a project — the
three-tier resolution pipeline, the two source engines that feed it, and
how edits, discovery crawls, and the read path keep the index current.
Memory budgets for the caches described here live in
[memory.md](memory.md).

## Architecture overview

```
                         symbol_find / symbol_list
                                    │
                    ┌───────────────▼───────────────┐
                    │         L0: name index          │  SQLite table
                    │  (does this name exist? where?) │  symbol_names
                    └───────────────┬───────────────┘
                                    │ candidate files
                    ┌───────────────▼───────────────┐
                    │    L1: per-file payload cache   │  SQLite table
                    │  (full symbol forest, compact)  │  symbol_cache
                    │  + in-memory mirror (64 MiB)    │
                    └───────────────┬───────────────┘
                                    │ cache miss or stale hash
                    ┌───────────────▼───────────────┐
                    │   L2: hot parse-tree LRU        │  In-memory
                    │  (skip re-parse entirely)       │  5,000 / 128 MiB
                    └───────────────┬───────────────┘
                                    │ tree miss
                    ┌───────────────▼───────────────┐
                    │        Fresh parse               │  tree-sitter or
                    │  (parse → outline → write L0+L1) │  LSP fallback
                    └───────────────────────────────┘
```

## Source engines

Two engines produce symbol outlines. Tree-sitter is tried first; the
language server is a fallback for languages without a grammar or when
the grammar's tags query declines a file.

| Engine | Speed | Scope | Failure mode |
|--------|-------|-------|--------------|
| Tree-sitter | Instant, in-process | every bundled grammar | No grammar → empty outline |
| Language server | Network round-trip, lazy-start | configured language servers | Server not started → skipped; server crash → restart on next call |

Both engines write the same SQLite schema and produce the same
`Symbol` tree shape. The downstream pipeline (name-path resolution,
body population, forest search) is engine-agnostic.

## Tier 0: SQLite name index

A flat table answering "does this name exist, and in which files?"

```sql
symbol_names (name TEXT, kind TEXT, path TEXT, hash TEXT,
              line INT, parent TEXT)
  -- case-insensitive lookup:
  INDEX ON symbol_names(name COLLATE NOCASE)
  -- freshness check:
  INDEX ON (path, hash)
```

- **Write**: one transaction per file (or per crawl batch): upsert L1
  payload, delete stale L0 rows for this path, insert fresh rows.
- **Read**: `symbol_names_lookup` (exact, case-insensitive) or
  `symbol_names_lookup_glob` (wildcard via SQL LIKE). Name-path chains
  (`Foo/bar`) are verified by walking the parent column upward.
- **Sweep**: expired rows and orphaned L0 entries are pruned by the
  daily sweep; a row cap (32,000) trims newest-first on overflow.

## Tier 1: per-file payload cache

A compact binary encoding of each file's symbol forest, keyed by
`(path, hash)`:

```sql
symbol_cache (path TEXT, hash TEXT, language TEXT,
              payload BLOB, created_at INT, expires_at INT)
  PRIMARY KEY (path, hash)
```

The payload is a pre-order walk of the symbol tree: name, kind,
container, detail, ranges, children count — no bodies or source
locations (those are re-derived from the current file contents on
decode). An in-memory mirror (32,000 entries / 64 MiB) sits in front
of SQLite so repeated reads hit malloc, not disk.

## Tier 2: hot parse-tree LRU

Recently parsed files keep their tree-sitter tree so follow-up symbol
work skips re-parsing. The byte ledger charges:

```
cost = len(source) + node_count × 144   (HOT_NODE_BYTES)
```

144 bytes per node is a measured constant (see
[Calibration](memory.md#calibration)). A ledger that charged only source
bytes would let a "128 MiB" budget hold a multiple of that in real
memory.

- **Pin contract**: open editor files pin their tree (never evicted
  while open). Pins are released when the buffer closes, so they
  cannot outlive the editor.
- **Incremental edit**: `hot_edit` computes the common prefix/suffix
  diff, applies `ts_tree_edit`, and re-parses with the edited tree as
  reuse base. Files exceeding 1 MiB are tombstoned instead.

## Lookup flow

A single-file read (`ts_source_outline_for_contents`) proceeds:

1. **Hash** the current file contents.
2. **L1 probe**: if `(path, hash)` hits in the mirror or SQLite, decode
   the payload, populate bodies from current source, return — no parse.
3. **L2 probe**: if the cached tree's source matches the current bytes
   exactly, run the outliner against the cached tree — no parse.
4. **Fresh parse**: parse with tree-sitter, outline from the fresh tree,
   insert/refresh the hot cache entry, write L0+L1 index rows in one
   transaction.

## Crawl and discovery

One crawl implementation — `ts_source_crawl` — fills the index from disk,
shared by every trigger below. The walk:

- Applies `.gitignore` scoping, builtin directory exclusions (`.git`,
  `node_modules`, …), the sensitive-path deny list, and caps (5,000
  files, depth 100, 1 MiB per file). Symlinked entries are not followed.
- Per file: detect grammar, stat, read, parse, outline, flatten into L0
  rows + L1 payload.
- Commits in batches: files accumulate until a directory boundary or
  1 MiB of payloads, then flush in one transaction per directory.
- Checks cancellation once per directory entry; a fired token stops
  between directories, keeping already-committed ones.

The crawl never blocks RPC service — every trigger below runs it on its
own thread or inside a request that asked for the answer.

### Incremental skip

Every committed file records a disk fingerprint — `(mtime_ns, size)` in
the `file_stat` table, written inside the same transaction as the rows it
describes. A later crawl re-stats the file and skips the read and parse
entirely when the fingerprint still matches **and** live rows still answer
for the path; liveness is probed, not assumed, because the daily sweep can
expire rows under an unchanged stat. Fingerprints carry no TTL — they are
comparison keys, not cache entries. A file whose outline empties still
commits an entry, so the old rows drop and the empty state sticks instead
of re-parsing on every pass.

### Triggers

- **Startup warm-up** — once per store generation: a background thread
  crawls when the `index.crawled` marker is absent, or again when the
  daily sweep has since emptied every row (a partially touched index
  still counts as crawled — `symbol_list` fills only the files it
  reads).
- **On-miss refresh** — a `symbol_find` whose answer would otherwise be
  empty runs one incremental walk before answering. Aubade-mediated edits
  refresh rows immediately, but out-of-band changes (an agent's own file
  writes, git checkout, scripts) have no row anywhere to trigger the
  freshness heal, so discovery is the only path to them. A min-gap window
  (2 s) bounds bursts of misses for genuinely absent names, and a
  single-flight claim shared with the background loop prevents concurrent
  walks. The walk obeys the request's cancel token and never starts a
  language server (find's rule).
- **Background loop** — the daemon repeats the incremental walk every
  60 s as a hygiene floor. With on-miss discovery in place the interval
  does not gate freshness; it only bounds how long a change nobody asked
  about stays unindexed.

### Vanished-path purge

A completed whole-project walk also removes what it no longer sees: a
recorded path the walk did not reach has been deleted, moved away, or
newly ignored, so its L0/L1 rows and fingerprint go in one pass — without
this, a renamed-away symbol would keep answering until its TTL expires.
The purge is scoped to enumerated subtrees: a subtree the walk could not
enumerate — an unreadable directory, one beyond the depth cap, a symlinked
entry — has its rel-path prefix recorded, and paths under it are kept,
because absence there is not provable (rows under such prefixes can be
real: scoped crawls restart depth at their scope root, and editor writes
know no depth at all). Truncation (file budget reached) and cancellation
suppress the purge wholesale — their unvisited tails cannot be
characterized.

## Freshness heal

On a `symbol_find` read, if the indexed hash differs from the current
file bytes, the file is re-indexed before the answer is returned:

1. The tree-sitter producer re-parses and writes fresh L0+L1 rows.
2. If TS declines (no grammar), the LSP producer from a running server
   is tried (never starts one — `may_start = false`).
3. Stale rows are kept until a verified replacement exists, so a
   partial failure never leaves the index empty.

## Edit propagation

When a symbol edit tool modifies a file:

1. **Hot cache**: the editor's `on_change` callback applies an
   incremental tree edit (`hot_edit`), so the L2 entry tracks the new
   source without a full re-parse.
2. **L0 index**: `ts_source_index_contents` re-parses the editor's
   committed bytes and writes fresh name rows. If the file now declares
   nothing, old rows are purged.
3. **LSP**: `didChange` is sent to the language server, keeping its
   internal state current for the next `references`/`rename` request.
4. **Next read**: the new hash matches, so `symbol_find` returns the
   updated outline without a heal.

## Tree-sitter outline pipeline

The outliner converts a parse tree into a symbol forest:

1. **Tags query**: per-language, selected in priority order:
   - Hand-written override (Go, Odin, TypeScript — their inference
     missed most declarations).
   - Grammar's shipped `tags_query`.
   - Inferred query (generic patterns gated on the grammar's symbol
     table; most grammars use this).
2. **Candidate collection**: run the tags query, collect match sites.
3. **Ambiguity filter**: discard overlapping matches where a more
   specific match exists.
4. **Containment forest**: build parent-child relationships from
   nesting ranges and owner rules (e.g. Go method receiver type).
5. **Symbol conversion**: map tree-sitter node types to the `Symbol`
   model (name, kind, container, ranges).
