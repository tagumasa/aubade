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
platform, files a draft release with archives and checksums, and
publishing stays a manual step. Each release pins the upstream
dev-YYYY-MM Odin release it tracks (`.github/workflows/release.yml`
carries the current pin). Bug fixes land on main and ship with the
next tagged release.

## Quick clarifications

Typo fixes, documentation improvements, and test coverage gaps are
welcome as direct pull requests without prior discussion.
