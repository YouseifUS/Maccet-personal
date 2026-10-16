# Changelog

## 0.1.2 — 2026-10-16

### Added

- Automatic dependency preparation on every GUI launch: install missing Homebrew/MacPorts and install or update mas; refresh existing Homebrew and MacPorts before checking apps.
- Bundled startup script, progress and failure results, Retry Setup, and protection against quitting during source installers.
- Official GitHub release installer selection by OS, SHA-256 checks, Gatekeeper assessment, and macOS administrator authorization.
- Apple developer tools installer handoff when prerequisites are missing.
- Packaged SwiftPM resources and a read-only startup resource diagnostic.

### Boundaries

- Fresh automatic Homebrew installation uses the official Apple Silicon package. Intel requires an initial manual Homebrew installation; routine maintenance then runs automatically.
- Apple tool installation and administrator authorization require system interaction. Offline and unsupported installer failures preserve available-source checks and can be retried.
- Application upgrades still require review. Startup does not run a broad package upgrade or global cleanup.
- Installer and maintenance behavior is exercised through controlled fixtures; real privileged source installation still needs clean-machine validation.

## 0.1.1 — 2026-10-16

### Added

- MacPorts adapter: installed-file ownership, local-index update checks, dry-run previews, and a named-package update through macOS authorization.
- Independent route aggregation across Homebrew, MacPorts, and App Store. One inventory entry and one selected execution route per app.
- Explicit manager selection when several managers claim the same installed app; store receipts retain store ownership.
- System applications in inventory, including Safari, labeled as maintained by macOS and excluded from third-party updates.
- Deep-folder discovery without the previous arbitrary four-level limit and support for an app bundle used as a scan root.

### Validation boundaries

- 49 executable checks passed, including multi-manager aggregation, selection, single-manager planning, and installed-file ownership.
- MacPorts is not installed on the validation machine. Its adapter uses documented command formats and controlled fixtures; real MacPorts installs remain unverified.
- Public cross-catalog discovery, Nix, pkgsrc/pkgin, and reviewed ownership migration remain future work. No additional managers were installed on the user's machine.

## 0.1.0 — 2026-10-16

First local alpha of the native macOS app.

### Added

- Application bundle inventory, custom folders, receipt/feed metadata, and duplicate-instance handling.
- Homebrew Cask checks and identity-based App Store checks using `mas` 7+.
- Unified update list, installed inventory, App Store view, source health, and app details.
- Explicit update plans, selected/all-eligible updates, normal-quit requests, deferral, and cancellation of remaining work.
- Target revalidation and fresh installed-version/build verification.
- Persisted attempts, interrupted-operation recovery, exclusions, and report export.
- Isolated Homebrew attempt caches and post-verification cleanup of owned artifacts only.
- Source-independent core, read-only diagnostics, executable checks, and local app packaging.

### Release boundaries

- Ad-hoc signed local build; no public release or notarization.
- Sparkle checking, general app-cache cleanup, source adoption, scheduling, and additional managers are deferred.
- Real update installation and privileged App Store authentication require controlled integration validation before a stable release.
