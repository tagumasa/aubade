---
name: verify-incident
description: Judge a reported Aubade incident before working it — confirm with file:line plus quoted evidence, or reject as a false positive with an fp_pattern. Use before starting work on any incident in status reported, when triaging incident_list output, or when the user asks whether a finding is real.
---

# Verify an incident

Never work an unverified incident: a false positive wastes a fix and
pollutes the sprint statistics. `incident_verify` is the gate.

## Steps

1. `incident_get` for the full description and timeline.
2. Reproduce the finding or locate the code. Evidence for a code
   finding is `file:line` plus the actual quoted line — a paraphrase
   is not evidence.
3. Real → confirm; not real → reject with the pattern that produced
   the false positive:

```
incident_verify:
  id: INC-104
  verdict: confirmed
  reason: "read_only strip runs before the mode fold"
  evidence: "src/tools/fold.odin:73 \"if read_only {\""

incident_verify:
  id: INC-105
  verdict: rejected
  fp_pattern: untraced-guard
  reason: "the write path is guarded"
  evidence: "src/safety/pathguard.odin — the symlink walk re-checks containment at every hop"
```

Rejected incidents stay recorded, never deleted: the per-pattern
false-positive rate is how detection quality is judged across a
sprint.

## fp_pattern values

- `untraced-guard` — the finding ignored a guard the code does have
- `hallucinated` — the cited code or symbol does not exist
- `spec` — behavior is intended per the spec or design docs
- `threat-model` — out of scope for the project's threat model
- `design-intent` — a deliberate trade-off, documented in the code

## After confirming

Drive the workflow: record the root cause with `incident_update
root_cause` — that call moves the incident to `root_caused`, the state
`incident_resolve` resolves from — then fix it, and when the fix lands
follow the resolve-incident skill.
