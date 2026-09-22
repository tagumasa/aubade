# Memory management

How aubade bounds its own resident memory and its store file — the
budgets, the ledgers behind them, and what is deliberately unbounded.
For the separate topic of capping *language server* processes at the OS
level, see "Memory containment" in the README.

## Model

One daemon process per project owns every long-lived structure; the
per-session `mcp` children are thin forwarders holding no caches. Each
request runs on a frame/task arena that is destroyed when the request
completes, so request memory never accumulates — the daemon's resident
set is exactly:

- bounded caches (below), plus
- data that is unbounded by design (last section), plus
- transient per-request working set (largest single request sets the
  malloc high-water; frames are capped at 32 MiB).

## The budgets

| Structure | Bound | Charge |
|---|---|---|
| Editor open-document buffers | 128 files / 64 MiB | contents + path + fixed overhead |
| Hot parse-tree LRU | 5,000 entries / 128 MiB | source bytes + node count × 144 |
| Store payload mirror | 32,000 entries / 64 MiB | payload + language + fixed overhead |
| SQLite page cache | 64 MiB | `cache_size` pragma |
| WAL file | 8 MiB high-water | `journal_size_limit` pragma |
| Inbound queues | bounded chans (16; 64 frames / 8 MiB outbound) | — |
| Diagnostics store | 500 document URIs, oldest evicted | per-URI payload uncapped |

### Editor open-document buffers

Every file the editing tools touch gets an in-memory buffer (full
contents plus line views). Buffers are *data*, not a cache — but the
daemon's lifetime is unbounded and each distinct edited file once stayed
resident forever, so the set is bounded like a cache: an LRU caps it at
128 files or 64 MiB of charged content, whichever binds first.

Saves are synchronous, so a buffer never holds unsaved state — eviction
runs through the ordinary buffer-close path (per-file lock, close
notification to the document-sync listener, hot-tree unpin) and only
costs a later re-read from disk. The file that triggered a prune is
spared, so a single file larger than the byte budget stays resident and
may leave the ledger above the cap until it ages out — the same
overshoot rule the shared cache container applies to pinned entries.

### Hot parse-tree LRU

Recently parsed files keep their tree-sitter tree so follow-up symbol
work skips re-parsing. The byte ledger charges `len(source) + node_count
× HOT_NODE_BYTES` (144): a tree's own memory dominates, and measured
trees run roughly **25× the source length** on symbol-dense sources
(the Odin grammar; the C grammar runs ~6×). A ledger that charged only
the stored source bytes would let
a "128 MiB" budget hold a multiple of that in real memory.

A file with an open editor buffer *pins* its hot tree (open buffers must
never lose their tree); pinned entries are exempt from eviction, and
when everything is pinned the caps may be exceeded temporarily. Pins are
released when the buffer closes — including when the buffer LRU evicts
it — so pins cannot outlive the buffer set.

### Store payload mirror

The SQLite payload table (per-file symbol forests) sits behind an
in-memory LRU mirror (64 MiB). Entries carry a TTL and are dropped by
read, by the daily sweep, and by LRU pressure.

### SQLite file hygiene

The store opens with `auto_vacuum = INCREMENTAL` — **this pragma must
run before `journal_mode = WAL`**, because setting the journal mode
first materializes the header page, and the database then already counts
as non-empty for `auto_vacuum`, which silently does nothing. On an
incremental store the daily sweep trims the freelist (dead pages left by
index churn) back to the file system once they exceed 64 MiB, using the
bounded `incremental_vacuum` operation. The WAL carries
`journal_size_limit` (8 MiB) so a write spike cannot strand the file at
its high-water size; ordinary autocheckpoint (1,000 pages) keeps the WAL
small anyway.

## Ledger semantics

Every bounded structure follows the same rules:

- **Charges are maintained, not sampled**: the cost of an entry is
  recorded at insert and re-derived at every in-place mutation (contents
  edits, tree swaps). Nothing recomputes sizes by walking live entries,
  which would race concurrent mutation.
- **Pins exempt**: entries held by an in-flight reader or an open buffer
  are never evicted; if every entry is pinned, the caps may be exceeded
  until pins release.
- **Overshoot is tolerated, never churn**: an entry whose own cost
  exceeds the byte budget stays resident rather than being dropped to
  admit nothing.
- **Eviction runs at put time** and at the buffer-prune check; both take
  the per-victim locks in the documented order.

## Calibration

`HOT_NODE_BYTES` (144) is a measured constant, not a guess. The
measurement method, reusable after a tree-sitter bump or grammar change:

1. Parse a representative source once, count the tree's nodes
   (`ts_node_descendant_count` on the root).
2. Parse K copies (K ≈ 100–500), keeping every tree alive, and read the
   process's *malloc bytes in use* before and after — glibc exposes this
   as `mallinfo2().uordblks`. Do **not** measure RSS deltas: freed-and-
   reused malloc chunks make RSS undercount, and first-touch page
   accounting makes it overcount.
3. Bytes per node = delta / (K × node_count). Take the ceiling across
   several grammars (symbol-dense and symbol-sparse) and round up to a
   16-byte multiple.

Re-calibrate when the vendored tree-sitter core moves (its internal
subtree representation can change size) and spot-check the dominant
grammars of the projects you actually serve.

## Unbounded by design

- **Tracker event history** — the SQLite `events` table and the fold
  state grow with tracker activity; they are the audit record, not a
  cache. Retention policy is a product decision, deliberately not a
  silent cap.
- **Open LSP document mirrors** — bounded by what the language-server
  sync actually has open; entries die on didClose.
- **Editor `docs` mirror** — same shape: the open set of the document
  sync, not a cache.
