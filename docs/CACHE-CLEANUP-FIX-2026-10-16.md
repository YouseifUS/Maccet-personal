# Cache directory replacement — 16 October 2026

Scope: one Phase F fix, based on `8bb9b45` after PR #1 merged.

## Descriptor-bound follow-up — 17 October 2026

The later adversarial fixture inserts a directory-name swap after identity and marker validation. The previous path-based removal deleted a disposable replacement's `Keep` file. The revised cleanup opens and checks root/attempt directory descriptors, reads a bounded regular ownership marker relative to the attempt, and performs the entire file walk with `openat`/`fstatat`/`unlinkat` relative to held directory descriptors. Each child directory is opened without following symlinks, matched against its observed identity and constrained to the attempt's filesystem device.

Cleanup retains directory entries and the root ownership marker. It does not perform a later pathname `rmdir`: POSIX offers no atomic inode-conditional directory removal, so checking an inode and then removing its name would reopen the same race. Download/log file entries and symlinks inside the original opened namespace are removed; symlink targets, replacement attempts and sibling failed attempts are preserved. The UI explains the retained metadata/empty-folder policy.

This is descriptor-relative containment on the local macOS filesystem exercised by the fixtures, not an immutable snapshot against concurrent writers. Files added during a walk can remain. Renaming an already opened owned directory does not change which directory the cleanup walks. No path-based recursive removal is used after validation. Existing pre-validation replacement guards remain in place. The historical limits below describe the previous implementation.

## Observation and reproduction

Cleanup checked the canonical path, UUID, absence of a symlink, and ownership
marker. Moving the original attempt directory aside and copying it back
preserved all those values. Cleanup then deleted the replacement directory,
including newly added files. Replacing the parent directory and moving the
original attempt into the replacement parent also passed the old checks.

Three fixture regressions reproduced these cases, including a simulated
verified update with a swapped cache: **65 passed, 3 failed** before the fix.

## Change

`OwnedUpdateCache` now records the filesystem device and inode of both the
canonical root and attempt directory when created. Cleanup uses `lstat` to
require actual directories with the same identities before reading the
ownership marker and deleting the attempt. A mismatch blocks cleanup and
retains the artifacts. Existing verification, marker, symlink, sibling-attempt,
and disabled-cleanup rules remain in force.

The engine regression confirms that a verified installation remains successful
while directory replacement is reported as a separate cleanup failure.

## Evidence and limits

- PR core suite: **68 passed, 0 failed** after the fix.
- Fresh isolated copy of local work, with merged PR #1 and this patch:
  **79 core checks passed, 0 failed**.
- The same copy passed **5 UI orchestration checks, 0 failed**.
- The PR release build, packaging, ad-hoc signature verification, and bundled
  startup-script syntax check passed. Setup was not executed.
- Read-only isolated inventory: **112 apps**, including **34 third-party**
  and **78 system-managed**, with **0 warnings**. No update sources were
  queried by this inventory run.
- Environment: macOS 27.0.1, Apple Silicon arm64, Swift 6.4.
- The original checkout and installed applications were not changed.

The tests cover directory replacement before cleanup validation. Validation
and path-based deletion remain separate operations; this is not an atomic
defense against a concurrent swap between those operations. The broader
Phase F gate and real-update acceptance tests remain open.
