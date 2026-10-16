# Marketing-version verification fix — 16 October 2026

This change addresses one Phase F requirement from the implementation plan:
do not report success unless the reviewed installed release is verified.
It does not close the wider Phase F gate or the App Store automatic-installation gate.

## Reproduction and cause

`UpdateEngine.verify` used `ReleaseComparison.satisfies` for every source.
That helper accepts a plain target matching either the marketing version or
the build, which supports Homebrew catalogs that use build numbers.
App Store targets and the supported MacPorts targets are marketing versions.
For these sources, a reviewed target of `2.0` incorrectly passed verification
when the installed marketing version was still `1.0` (or changed to `1.5`)
and only the build matched `2.0`.

The new regression suite failed before the production change: **64 passed,
1 failed**, at the App Store build-only assertion. The shared verifier now
requires the marketing version for App Store and MacPorts, while retaining
Homebrew's build-only and combined version/build handling. Existing identity,
path, receipt, changed-release, and explicit target-build checks still apply.

## Current baseline and isolation

The user's checkout contained uncommitted work, including the audit and UI
changes. It was copied to an isolated development directory for validation;
the original checkout was not modified. This PR is based on published commit
`623bd1b1bc2cbd6a2764eaae9db109bd1f5d11c4` and contains only this fix, its
regressions, and this evidence note.

Fresh evidence on 16 October 2026, distinct from the earlier audit:

- Environment: Apple Silicon arm64, macOS 27.0.1 (26A434), Swift 6.4.
- The copied local baseline passed **73 core checks** before applying the fix.
- Read-only inventory used the default roots: `/Applications`,
  `~/Applications`, `/System/Applications`, and
  `/System/Library/CoreServices/Applications`.
- It found **112 applications**, including **34 third-party** and **78
  system-managed**, with **0 inventory warnings**. This was inventory only;
  the 34 third-party applications remained unchecked for updates.
- Read-only version probes found Homebrew **7.0.9** at
  `/opt/homebrew/bin/brew` and mas **7.0.0**, resolving to
  `/opt/homebrew/Cellar/mas/7.0.0/bin/mas`. MacPorts was unavailable.
- Inventory ran with an isolated `UNIFIED_UPDATER_DATA_DIR`; no saved user
  preferences or history were loaded. Default preferences disable no sources,
  but this inventory run did not perform source checks or refresh metadata.

## Acceptance

- Published base plus fix: `bash scripts/test.sh` — **65 passed, 0 failed**.
- Copied local work plus the same patch: `bash scripts/test.sh` —
  **76 passed, 0 failed**.
- Copied local work plus fix: `bash scripts/test-ui-model.sh` —
  **5 passed, 0 failed**.
- PR release: `bash scripts/build.sh` — compiled, packaged, and passed local
  ad-hoc signature verification. macOS icon packaging required running the
  build outside the execution sandbox; the same icon command succeeded there.
- Packaged executable: `--check-startup-script` — bundled script found and
  syntax accepted; setup was not executed.
- Added regressions reject build-only matches for App Store and MacPorts,
  accept normalized marketing versions, enforce an explicit target build,
  reject identity replacement, and preserve Homebrew build-only targets.

All installation tests use injected command runners and temporary fixture
applications. No installed application was updated. These results establish
the verifier's behavior; they do not diagnose the mas stall, prove a real
automatic App Store/MacPorts update, or certify broader platform support.
