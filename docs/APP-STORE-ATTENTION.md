# Long-running App Store operations and assisted results

This change addresses the observability and safe-assisted lifecycle portions of #18. A real required-update acceptance run and diagnosis of the historical Windows App stall remain open under #18/#19. No current stall root cause is claimed.

## What is observed

The real runner publishes output-free snapshots of the command it owns: process ID, running/exited state, elapsed monotonic time, cumulative stdout/stderr bytes and time since newly observed output. Stream capture remains bounded and independent. Snapshots are delivered serially; the observer is canceled and joined before the command result returns. Runners that cannot provide live evidence report that limitation rather than claiming silence or a process ID.

For an authorized store update, the owned command is the `osascript` invocation. These snapshots are not a process-tree inspection, download percentage, App Store service state, CPU measurement or proof that the privileged child is active/stalled. In particular, AppleScript can buffer child output. Maccet cannot infer whether a quiet invocation is waiting on authentication, a download/install, a callback or a genuine stall.

After 120 seconds without observed output, a running owned command transitions the UI to **Needs attention**. New output returns the display to **Installing**, while retaining the earlier attention evidence. Neither condition declares success/failure or kills an installer. The queue remains protected, quit protection stays active, and **Cancel Remaining** only skips later work. Activity offers the fixed official App Store URL derived from the validated reviewed store ID, or its updates page for older history without an ID.

## Assisted verification

A settled failed automatic attempt can retain its reviewed plan in the current session. Complete the update through App Store, then choose **Verify Assisted Result** in Activity after the queue/scan settles. Verification is read-only and acquires the same canonical-application ownership as automatic execution. It rejects concurrent ownership, changed canonical paths, bundle or receipt mismatches, an unchanged/wrong target and invalid or changed reviewed signing identity. It applies the same unsigned/ad-hoc limits as automatic verification; unsigned fixtures do not establish publisher authenticity.

The result is an independent `assistedVerification` observation with its own time/message. The original automatic state/message and attention evidence are preserved. It never converts the automatic attempt into success, starts/retries installation, removes artifacts or cleans shared caches. An unsuccessful verification can be retried after the user finishes the update. Successful verification refreshes inventory. Active commands must settle before assisted verification is available; opening App Store does not release operation ownership.

The review's transient signing requirement is not reconstructed from untrusted current metadata after relaunch. History persists, including separate assisted observations; live reviews do not. Relaunch recovers active attention states as **Interrupted**, starts no retry/cleanup, and requires a new scan/review for fresh verification context. Store handoff remains available for recorded failures/interruption.

## Validation

Controlled checks cover a slow benign process with output on both streams, quiet attention and resumed output, observer completion/timeout, intercepted App Store failures and redaction, active ownership preventing verification, correct/unchanged targets, receipt/bundle/path/signature mismatches, old-history decoding, interruption recovery and UI persistence of separate assisted results. Existing queue cancellation and independent-failure checks remain in place. No real App Store update or machine-wide source maintenance is performed by these checks.
