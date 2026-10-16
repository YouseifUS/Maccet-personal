# Release validation

Current local alpha: **0.1.2**. Startup dependency preparation is covered by **62 passing checks**, packaging validation, installer trust checks, and an isolated UI failure/retry exercise described below.

## 0.1.0 baseline

Date: October 16, 2026.

## Environment exercised

| Item | Observed value |
| --- | --- |
| Machine architecture | Apple Silicon / arm64 |
| macOS | 27.0.1 |
| Swift | Apple Swift 6.4 |
| Developer tools | Command Line Tools; no full Xcode test framework required |
| Homebrew | 7.0.9 |
| mas | 7.0.0 |
| Deployment target | macOS 13.0; older macOS versions were not exercised |

## Automated behavior checks

`bash scripts/test.sh`: **36 checks passed, 0 failed**.

The executable suite covers:

- Bundle discovery, metadata failures, overlapping roots, nested helpers, and separate copies.
- Numeric version/build comparison, non-numeric manual cases, and downgrade avoidance.
- Homebrew JSON parsing, exact installed-target matching, self-updated apps, and conflicting ownership.
- App Store JSON identity/path matching, receipt requirements, duplicate copies, and source failures.
- Update All eligibility with ignored apps and skipped source releases.
- Explicit cask scope, dry-run review, stage callbacks, changed installed identity/version, and changed target metadata.
- Simulated installation success, unchanged installed releases, installation failure, and cancellation before mutation.
- Fresh version/build verification and separate cleanup failures after a verified update.
- Isolated caches, marker checks, symlink replacement, nested links, and preservation of sibling failed-attempt caches.
- Local persistence, interrupted-operation recovery, credential redaction, and valid JSON report export.
- Real benign process output, nonzero status, and timeout handling.

Update execution tests use synthetic app bundles and fake source processes. They do not upgrade installed user applications or exercise privileged authentication.

## Read-only integration checks

The built app's diagnostic entry points were exercised against the local machine:

- Inventory discovered **33 applications** with **3 App Store receipts** and no folder-access warnings in this environment.
- Both source integrations completed successfully.
- **5 of 33 applications** were checked through supported ownership/identity routes.
- **4 applications** were current according to their selected source.
- **1 application** had an eligible update: Windows App **11.4.3 → 11.4.4**.
- The other **28 applications** remained visibly unchecked; the app did not claim complete coverage.
- A Homebrew app already matching the catalog was treated as current despite an older manager installation receipt.

These are observations from one machine at the validation time, not a guarantee of the same counts or release availability elsewhere.

## Native UI checks

The packaged app was launched with its data redirected into an isolated workspace folder.

- Confirmed first-launch view and all sidebar destinations are present.
- Started a real read-only scan from **Check for Updates** and observed completion in the UI.
- Confirmed the UI showed 33 apps, coverage of 5/33, one eligible update, and the unchecked count.
- Opened **Review Update** and confirmed it contained only the selected app and target release.
- Canceled the plan without starting installation.
- Opened **Installed Apps** and confirmed checked and unchecked applications remain distinguishable.
- Opened **Sources** and confirmed actual tool versions and successful source checks.
- Visually inspected the main window and update-review sheet in the machine's existing dark appearance.
- Confirmed the app remained responsive while processing the scan.

A startup issue where the GUI held a main-actor job around AppKit's event loop was found during UI validation, fixed by using a synchronous GUI entry point, and retested successfully.

## Build and packaging checks

- Produced the optimized arm64 application bundle with a generated multi-resolution icon.
- Verified its local ad-hoc code signature with `codesign --verify --deep --strict`.
- Inspected dynamic library dependencies: only system frameworks/libraries are needed; no local build-folder library is required.
- Packaged the application as a ZIP archive.
- Release packaging omits debug information; the source remains available for rebuilding with debug symbols.
- The local restricted execution environment needed access to macOS icon services during packaging. Normal local builds use the supplied script directly.

## Not yet validated

- Installing an actual Homebrew or App Store update on a controlled machine.
- The administrator authorization and Apple Account interaction during a real store update.
- Real application quit/refusal behavior across different apps and unsaved-document workflows.
- Source-managed installations that require an interactive terminal, special installers, or additional system permissions.
- Real interruption during a third-party installation and subsequent repair outside the synthetic recovery checks.
- macOS 13–26, Intel hardware, older compatible Swift toolchains, and additional Homebrew/mas versions.
- A full VoiceOver, keyboard-only, localization, light-appearance, and resizing audit.
- Developer ID signing, notarization, universal binaries, and public distribution.

These limits are why 0.1.0 is labeled a **local alpha**. The scan and review paths have real-machine evidence; installation, verification, and cleanup have automated controlled-fixture evidence and still need real-install integration validation before a stable release.


## 0.1.1 follow-up — multi-manager routing and inventory

- **49 checks passed, 0 failed** after adding MacPorts and the source resolver.
- MacPorts parser/adapter fixtures were checked against the official command documentation and upstream output implementation.
- Multiple verified source routes produce one app entry. An unresolved ownership conflict blocks execution; selecting a route creates a plan using only that manager.
- A broad MacPorts selector such as `outdated` is rejected as an individual package identity.
- App Store receipt ownership cannot be overridden by another manager's claim.
- Deeply nested app discovery and system inventory were exercised without allowing system apps into the update queue.
- The local machine has Homebrew and mas, but no MacPorts installation. Therefore no increase in third-party update coverage is claimed solely from adding MacPorts.
- Final read-only validation found **111 applications: 33 third-party and 78 managed by macOS**. All previously discovered application paths were preserved; Safari is now included. No duplicate instances or source-check errors were found.
- Safari's hidden public link was previously omitted by hidden-file filtering. Hidden app bundles are now included, while hidden non-app directories are pruned. Directory pruning never runs on plain files or symlinks, preserving sibling app links.
- An isolated GUI copy displayed all three source entries, including MacPorts marked Missing. The QA copy was closed without starting any installs.
- No real application update, package-manager installation, or global cleanup was performed during this follow-up.

References: [MacPorts command manual](https://man.macports.org/port.1.html), [installed-file ownership](https://man.macports.org/port-provides.1.html).


## 0.1.2 follow-up — startup source preparation

Date: October 16, 2026. Same Apple Silicon / macOS 27.0.1 / Swift 6.4 validation environment as the baseline.

- `bash scripts/test.sh`: **62 checks passed, 0 failed**. All 49 previous checks still pass.
- Startup fixtures exercise installed-tool maintenance, all-missing installation, per-step progress, independent failure handling, missing Apple tools and the system installer handoff, canceled authorization, checksum mismatch, Gatekeeper rejection, repeated-launch maintenance, MacPorts-owned mas, old mas rejection, Intel initial-install limitations, and installer OS/URL/digest/uniqueness validation.
- The actual bundled shell script passes syntax validation and rejects unknown actions, unsupported Homebrew executable paths, invalid installer hashes, and unexpected arguments without invoking installation.
- The optimized arm64 app builds and its ad-hoc signature verifies. The ZIP passes integrity checks.
- A copy of the packaged app in a separate folder passes `--check-startup-script`, proving the SwiftPM resource bundle travels with the app. Read-only `--inventory-json --folder /Applications` still discovers **33 apps** and bypasses launch setup.
- Downloaded the current official Homebrew 7.0.9 package and MacPorts 2.12.7 package for macOS 27 without installing them. Their SHA-256 values match the official GitHub release asset digests. Both pass macOS Gatekeeper assessment as Notarized Developer ID installers; `pkgutil --check-signature` also confirms trusted installer signatures.
- A separate signed QA copy uses an intentionally failing startup script, an unreachable network proxy, an isolated data directory, and disabled application source checks. Confirmed startup progress, disabled update controls during setup, failed-step explanations, the persistent setup-attention banner, **Sources → Retry Setup**, and the quit-protection dialog during preparation. No real source installer or maintenance command was run by that QA copy.

No real Homebrew installation/update, MacPorts installation/selfupdate, mas upgrade, or privileged installer execution was performed. Those mutation paths are covered by controlled command fixtures and official installer trust checks, and still require clean-machine integration validation. Apple tool installation handoff, Intel/macOS 13–26 behavior, and actual authentication cancellation remain unverified on real installations. The unchanged broader release limitations above still apply.
