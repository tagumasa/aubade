---
name: resolve-incident
description: Close out a fixed Aubade incident properly — re-test the fix, then resolve with the commit hash and covering tests as evidence. Use when a fix for a tracked incident is done, when the user asks to close or resolve an incident, or before reporting an incident as fixed.
---

# Resolve an incident

Resolving is a statement that the fix is verified, not that the code was
touched. The gate is the re-check: confirm the original finding under
the fix, then resolve.

## Steps

1. Tests first, while the incident is still open: run the suite
   covering the change; add a regression test for the incident if none
   exists.
2. Re-check the original finding under the fix (the repro or the cited
   lines) — resolving without this step reports a verification that
   never happened.
3. Resolve (valid only from `root_caused`, which recording the root
   cause already set):

```
incident_resolve:
  id: INC-104
  resolution: fixed
  evidence: "commit 1a2b3c4 + tests/fold_test.odin regression case"
```

`resolution` is `fixed` (gone), `mitigated` (guarded, still present),
or `documented` (accepted with a note). Resolving without re-checking
the finding under the fix skips the point of the evidence — don't.

## When the fix cannot land

Set `blocked_by` to the incident that must land first and leave the
status alone; the dependency graph keeps the chain visible. If the
incident turns out to be a false positive after all, that is the
verify-incident skill's job, not a resolution.
