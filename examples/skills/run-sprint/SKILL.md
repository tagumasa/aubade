---
name: run-sprint
description: Run an Aubade sprint as a scoped work period — start with a goal, file into it, close with the false-positive statistics, and review the reports. Use when beginning an audit or feature round, when the user mentions sprints or asks what this sprint covers, when closing or reviewing a sprint, or when a session ends with the sprint still open.
---

# Run a sprint

A sprint scopes one work period — usually one audit or feature round.
Its point is the summary: per-label counts, the false-positive rate,
and what moved where.

The whole cycle, end to end:

```
 BACKLOG --sprint_start(name, goal)--> ACTIVE SPRINT --sprint_close-->
                                          |
                                          v
                             sprint_reports row (SQLite)
                             (totals, FP rate, per-label matrix)

 inside the sprint, each incident walks:

 reported -> confirmed -> root_caused -> resolved
    \-----> rejected -- kept as data; its fp_pattern feeds the FP stats
```

Nothing is lost at close: unfinished incidents keep their sprint
assignment (the report lists them), and rejected ones stay as
false-positive data.

## Starting

```
sprint_start:
  name: "audit round 5"
  goal: >
    Re-audit src/tools after the fold_visibility refactor;
    everything found goes in as incidents, FP rate target under 20%.
```

Read the previous sprint's goal and outcome first (`sprint_get` on the
last closed sprint) — the prior round's outcome is the design input
for this one.

## During

- File incidents with `sprint: "current"` (the file-incident skill).
- Browse with `incident_list` and `sprint: "current"`.
- Move incidents through verify → root cause → resolve; unfinished work
  just stays open and keeps its sprint assignment through the close.

## Handing off between sessions

A sprint usually outlives one session. When a session ends with the
sprint still open, leave a handoff note so the next one can resume
without archaeology:

```
sprint_update:
  id: current
  note: >
    Handoff — verified: C2, crawl-cap tests green (recorded).
    In flight: freshness-heal rewrite in src/svc/ts_source.odin —
    compiles, suite not run yet. Next: run the suite, record C3.
    DEF-004 is still open.
```

- Start the body with `Handoff` and state three things: what is done
  and verified, what is in flight and exactly where it stands, and the
  next step for each open must task.
- Notes are append-only — writing a new handoff does not remove the
  old one, and that is by design: only the newest `Handoff` note is
  current, everything earlier is history. Write each handoff from the
  actual state; never restate an earlier one.
- Resuming an open sprint: read the newest `Handoff` note first
  (`sprint_get` on "current"), check it against `incident_list`, then
  continue the round.

## Closing

`sprint_close` (optionally with an `outcome` summary) stores the
report row in the tracker store: totals, the per-label matrix, FP rate,
patterns, anomalies. `tracker_export` re-renders the report rows on
demand.

Outside the session, the CLI reads the same store:

- `aubade tracker list --sprint current` — terminal view
- `aubade tracker show SPR-002` — the sprint in full
- `aubade tracker report --sprint SPR-002 --format tsv` —
  every row for a spreadsheet; `--output file` to save, `--format json`
  for scripts
