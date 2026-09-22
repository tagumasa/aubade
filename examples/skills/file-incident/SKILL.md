---
name: file-incident
description: File a bug or finding as an Aubade incident the moment it is concrete enough to name, instead of fixing it untracked or losing it in chat history. Use whenever a bug, regression, suspicious code path, or audit finding surfaces in a project whose tools include incident_create, when the user reports a problem, or when a finding is being deferred for later.
---

# File an incident

Found something worth tracking? File it first, fix it later — anything
not filed is lost when the session ends.

## Steps

1. Check for a duplicate: `incident_list` with a `query` on the key
   words of the title, plus any alias it might already be filed under.
2. File it with `incident_create` and the field conventions below.
3. New incidents start `reported`, which means unverified. Do not start
   fixing yet — judge it first (the verify-incident skill).

## File the cause, not the symptom

Look one level down before filing: name the mechanism that produces an
observation, not the observation — a surface-level filing earns
a surface-level fix while the cause keeps producing symptoms. One
cause is one incident: several tools failing the same way through one
broken helper is a single incident with each symptom as an evidence
line, not one incident per symptom. Check for duplicates at the cause
level too — the same defect surfaces under unrelated titles. If a
duplicate slips through anyway, `incident_delete` it with
`duplicate_of` naming the canonical incident.

## Field conventions

- `title` — one imperative line: "standalone server ignores read_only",
  not "bug?" or "read_only problem maybe".
- `description` — for code findings, `file:line` plus a short quote of
  the offending lines; otherwise how to reproduce or where observed.
- `priority` — urgent: active outage or data loss. high: security or
  corruption risk. medium: functional bug (default). low: cosmetic or
  test coverage. Deciding should cost less than a glance — when torn,
  leave it at `medium`.
- `labels` — stable lowercase project vocabulary ("mcp", "editor"); labels
  drive the per-label sprint statistics, so avoid one-offs.
- `sprint` — omit for the backlog, "current" for the active sprint.
- `blocked_by` — incident IDs that must land first.
- `aliases` — external IDs (e.g. "R5-SG-01") so later filings dedupe.

## Example

```
incident_create:
  title: "read_only strip misses mode-added editing tools"
  description: >
    src/tools/fold.odin:73 — the read_only strip runs before the mode
    fold, so a mode can re-enable editing tools on a read_only project
  priority: high
  labels: [tools, config]
  sprint: current
```
