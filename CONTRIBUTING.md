# Contributing to Aubade

## Bug fixes

Bug fixes are always welcome. If you find a bug, please open an issue
with a minimal reproduction, or submit a pull request with a fix.

## New features and specification changes

Aubade depends on the Odin compiler, which is actively evolving.
New features, tool additions, or changes that follow Odin's own
specification updates require prior discussion — please open an issue
before starting work on a pull request. This helps us align on scope
and avoids duplicated or misplaced effort.

## Release cadence

Odin ships a monthly dev-YYYY-MM release; when an upstream release
carries spec changes or bug fixes, aubade follows with a release of
its own. A release is cut by pushing a `v*` tag: CI builds every
platform, packages the VSCode extension vsix (OS-independent, built
once), files a draft release with archives, the vsix, and checksums,
and publishing stays a manual step. Each release pins the upstream
dev-YYYY-MM Odin release it tracks (`.github/workflows/release.yml`
carries the current pin). Bug fixes land on main and ship with the
next tagged release.

## Quick clarifications

Typo fixes, documentation improvements, and test coverage gaps are
welcome as direct pull requests without prior discussion.

## Design notes

### Why the source is full of `rawptr`

Odin has no closures: a procedure literal cannot capture the lexical
scope around it, so every callback that needs state receives it as an
explicit `rawptr` parameter and casts it back at the receiving end — the
same pairing C libraries have always used. Three forces keep the count
high (over 200 occurrences in `src/`): `core:thread` carries worker
state as erased pointers at its core, the C interfaces (tree-sitter,
SQLite, PCRE2) pass `void *` user payloads through their callbacks, and
non-host packages must hand host handles down across the layer boundary
type-erased. Generics cannot replace most of these (a `$T` procedure
value still captures nothing, and the FFI signatures are fixed), so the
erased-pointer pairs are the deliberate shape of the design, not
untyped shortcuts.
