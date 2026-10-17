# Issue work integration — 18 October 2026

This branch combines the focused work below against main `3b6ebbeec024beb4ccda6941b9aeb6c034f7b9dc`. GitHub main has not been merged/changed by this work. It provides one compatibility-reviewed combination; the focused PRs remain available for individual review.

| PR | Work | Issue reference |
| --- | --- | --- |
| #57 | Optional bounded embedded Sparkle observations | #33 |
| #58 | Long-running App Store observations/attention and separate assisted verification | #18 |
| #59 | Explicitly pinned signed discovery catalogs and identity/channel candidates | #30/#31 |
| #60 | Fixed official Chrome metadata and separately verified guided handoffs | #35 |
| #61 | Owner-operated Developer ID/notarization/extracted-distribution gates | #38 |

The App Store branch is independent of the Sparkle/discovery/vendor stack. Additive conflicts in core/UI checks were resolved by retaining all check groups. The shared busy state includes discovery refresh, vendor verification and App Store-assisted verification, preserving their guards. No existing automatic ownership or reviewed-target safety boundary was intentionally relaxed.

## Combined verification

Exercised environment: macOS 27.0.1, arm64, Apple Swift 6.4.

- Core: **186 passed, 0 failed**.
- UI orchestration: **9 passed, 0 failed**.
- Setup orchestration: **17 passed, 0 failed**.
- Release workflow: **11 controlled checks passed**; simulated tool verdicts do not certify notarization.
- Local release build, ad-hoc signature integrity and packaged bundled-script check: **passed**.

Commands: `bash scripts/test.sh`, `bash scripts/test-ui-model.sh`, `bash scripts/test-setup-retry.sh`, `/usr/bin/python3 scripts/test-release.py`, `bash scripts/build.sh` and the packaged executable's `--check-startup-script`.

A native smoke run used isolated preferences, six synthetic app bundles, synthetic mixed history and disabled manager/feed/vendor checks. Updates, Installed Apps, App Store, Activity, Cleanup, Sources and Settings opened. Long names/paths appeared in Details and their accessibility labels; Details/About closed with Escape. The publisher sheet accepted Tab focus, rejected an empty default action without saving trust, and canceled with Escape. The native folder chooser opened/canceled without adding a root. No global appearance/accessibility preferences, real inventory apps, source tools or installed applications were changed by this smoke run.

These observations do not establish a complete keyboard/VoiceOver/light/dark/larger-text/reduced-motion/stress-state matrix. Native inspection identified follow-up work for keyboard navigation and small-text contrast. An accessibility-tree inspection is not a VoiceOver announcement certification.

## Remaining gates

Real required application updates/clean-machine acceptance (#19), historical App Store stall diagnosis and complete process-state attribution (#18), arbitrary runtime Sparkle behavior and trusted installation (#33/#34), production catalog publication and independent benchmark (#30/#32), additional vendors (#35), full accessibility/platform matrices (#36/#37), and owner-executed Developer ID/notarization/clean-target delivery (#38) remain open. Fixture success, public metadata retrieval, local builds and prepared release tooling are not substituted for those gates.
