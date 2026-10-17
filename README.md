# Maccet — Personal Development

<img src="assets/branding/maccet-icon.png" width="128" alt="Maccet app icon">

**Your Mac updates, together.**

This private development repository, `Maccet-personal`, contains the current **0.1.2 alpha** of Maccet. Development continues here ahead of a complete public release. Existing source target names, build artifacts, and local storage still use the original `UnifiedUpdater` name.

A native macOS desktop app that combines supported package-manager results and picks exactly one update route per application. Implemented sources: Homebrew, MacPorts, and Mac App Store through `mas`.

**Status:** Local alpha. This is the first implemented slice of the [full product specification](docs/PRODUCT_SPEC.md). The broader roadmap is not a claim that every planned feature ships in the current alpha.

## Multi-manager behavior

Each adapter checks independently. Its evidence-backed routes are collected under the same installed application instance. The app appears once and uses exactly one selected manager for its update. If multiple managers claim the same app and no preference exists, the app remains blocked until you choose a route in **Details → Update using**. The queue deduplicates app instances and revalidates only the selected route.

For example, a verified Homebrew route and a verified MacPorts route can both belong to one app. Choosing MacPorts means only MacPorts receives the install request for that app. Other applications in the same batch can use a different manager. An App Store receipt preserves store ownership.

This release aggregates **installed-manager ownership results**, not the entire public catalogs of every manager. A matching catalog name cannot take over an existing application. Cross-catalog discovery and reviewed ownership transfer remain separate work.

Every GUI launch checks readiness of the applicable enabled source tools before checking applications. Missing tools appear as **Unavailable**; launch does not install tools, refresh their indexes, or request administrator authorization. Readiness and source scans require recognized stable version output, with validated numeric versions stored separately from diagnostic text. The Homebrew 6 baseline includes [the scoped `--no-quit` upgrade option](https://github.com/Homebrew/brew/blob/6.0.0/Library/Homebrew/cmd/upgrade.rb). MacPorts 2.8.1 is the conservative [command-format baseline](https://github.com/macports/macports-base/blob/v2.8.1/src/port/port.tcl); mas 7 supplies identity/path-aware store checking. These minimums do not certify every operating-system and architecture combination. Unknown output and unsupported older versions require preparation or a manual tool update.

MacPorts is optional. Preparation uses an existing manager, known MacPorts ownership, an App Store helper that needs MacPorts maintenance, or the **Include optional MacPorts installation** choice in Sources. That choice applies to preparation in the current session and respects disabled sources and inventory relevance. A previous successful MacPorts preparation remains evidence for an explicit retry if its tool disappears. Unknown/direct-download inventories do not install a missing MacPorts manager automatically, and unclaimed applications remain **Not checked**.

A working App Store helper is checked directly during launch; its package manager and Apple developer tools are required only when the chosen maintenance action needs them. Missing or broken helpers still require attention.

Choose **Sources → Refresh Metadata** to request package data with installed tools and then rescan applications. Homebrew uses API refresh flags with Git/tool auto-update disabled; MacPorts uses `port sync`. Results and last-attempt time are separate from tool-preparation results. Homebrew can reuse verified cached data when upstream is unavailable, so a completed request is not a freshness guarantee; Git-tap-only mode reports an unsupported request instead of broadening into tool maintenance.

Choose **Sources → Prepare Sources** to install missing tools and maintain required sources. Partial preparation failures offer **Retry Setup**, while available sources can still check apps. See [source readiness and preparation](docs/STARTUP_SETUP.md) for prerequisites, authorization, and platform limitations.

Installing a manager does not make it the owner of existing direct-download applications. Coverage still depends on verified ownership; a missing or failed source cannot claim complete coverage.

## What this release does

- Checks source readiness on launch; explicit source preparation uses a bundled script, native authorization, and per-step results.
- Scans `/Applications`, `~/Applications`, standard system application folders, and folders you select.
- Includes hidden application links such as Safari without descending into app helpers or hidden non-app directories.
- Reads bundles without launching them, excludes nested helpers, and removes the old arbitrary folder-depth limit.
- Includes system applications in inventory, labeled **Updated with macOS**, while preventing third-party updates to them.
- Keeps separate installed copies distinct and avoids name-only source matching.
- Checks installed Homebrew Casks, including casks with built-in automatic updaters.
- Checks MacPorts ownership through registered installed files and updates against its local ports index.
- Retains multiple manager routes per app and executes only the chosen one.
- Checks App Store applications through `mas` 7+, matching receipt presence, bundle ID, store ID, and installed path.
- Shows installed/target versions, source health, partial coverage, and manual actions.
- Offers individual, selected, and all-eligible update plans with a review screen.
- Revalidates the app's canonical path, identity, source, and target release before installation. A changed destination requires a new scan and review.
- Defers running apps, or requests a normal quit when you opt in. It never force-quits.
- Uses the macOS administrator authorization dialog for `mas update` when required.
- Verifies fresh installed version/build metadata after an update command finishes.
- Records attempts, independent failures, verification, and cleanup outcomes locally.
- Supports ignored applications, skipped releases, custom folders, and JSON report export.
- Removes only the isolated downloads belonging to a verified Homebrew update when cleanup is enabled.

## Requirements

- macOS 13 or later is the deployment target. See [validation notes](docs/VALIDATION.md) for what was actually exercised.
- Homebrew 6+ in `/opt/homebrew/bin/brew` or `/usr/local/bin/brew` for managed casks.
- Optional MacPorts 2.8.1+ at `/opt/local/bin/port` for MacPorts-managed apps.
- `mas` 7+ under `/opt/homebrew/bin`, `/usr/local/bin`, or `/opt/local/bin` for identity-based store checks.
- A suitable App Store account and any required macOS authorization for store updates.

Readiness and source scans require recognized stable version output, with validated numeric versions stored separately from diagnostic text. The Homebrew 6 baseline includes [the scoped `--no-quit` upgrade option](https://github.com/Homebrew/brew/blob/6.0.0/Library/Homebrew/cmd/upgrade.rb). MacPorts 2.8.1 is the conservative [command-format baseline](https://github.com/macports/macports-base/blob/v2.8.1/src/port/port.tcl); mas 7 supplies identity/path-aware store checking. These minimums do not certify every operating-system and architecture combination. Unknown output and unsupported older versions require preparation or a manual tool update.

MacPorts is optional. Preparation uses an existing manager, known MacPorts ownership, an App Store helper that needs MacPorts maintenance, or the **Include optional MacPorts installation** choice in Sources. That choice applies to preparation in the current session and respects disabled sources and inventory relevance. A previous successful MacPorts preparation remains evidence for an explicit retry if its tool disappears. Unknown/direct-download inventories do not install a missing MacPorts manager automatically, and unclaimed applications remain **Not checked**.

A working App Store helper is checked directly during launch; its package manager and Apple developer tools are required only when the chosen maintenance action needs them. Missing or broken helpers still require attention.

Choose **Sources → Prepare Sources** to install and update these dependencies. Fresh automatic Homebrew installation currently requires Apple Silicon; Intel users must install Homebrew once using its official instructions. During explicit preparation, missing Apple developer tools open Apple's system installer; finish that installer and choose **Retry Setup**. Installer availability and upstream OS support can further limit setup on older macOS versions. Inventory and available sources remain usable if setup fails. Official instructions: [Homebrew](https://docs.brew.sh/Installation), [MacPorts](https://www.macports.org/install.php), and [mas](https://github.com/mas-cli/mas).

## Run the app

Build with the script below, then open `dist/Maccet.app`. The included binary archive is built for the architecture stated in its filename.

1. Wait for source readiness checks and the initial application scan. Open **Sources** to inspect results. Choose **Prepare Sources** when tools need installation or maintenance, complete any macOS authorization, and use **Retry Setup** after a preparation failure.
2. Review application folders in **Settings**.
3. Click **Check for Updates**.
4. Inspect coverage and select **Review Update**, **Update Selected**, or **Update All**.
5. Review the exact application list and any source-provided preview.
6. Save your work, close the applications, and choose **Start Updates**. Optionally request a normal quit for running apps.
7. Inspect **Activity** and **Cleanup** for results.

Explicit source preparation installs or updates the source tools themselves, including `mas` and required tool dependencies. Updates to applications in your inventory require your reviewed update plan. Launch readiness checks, diagnostic commands, and scans do not run source maintenance. Update All uses an explicit list of eligible apps, regardless of search filters; the App Store screen restricts its Update All action to store apps. Authentication can be canceled in the system dialog.

## Screens

| Screen | Implemented behavior |
| --- | --- |
| Updates | Coverage cards, search, source filtering, selection, review plans, ignored items |
| Installed Apps | Inventory, unsupported/unchecked apps, multiple copies, details and Finder actions |
| App Store | Store inventory and update actions using the same shared queue |
| Activity | Live task stages, persisted update attempts, verification and failure explanations, rescan before retry |
| Cleanup | Cleanup policy and per-attempt results; no broad delete action |
| Sources | Separate metadata requests and tool preparation, per-source results, retry, canonical paths, versions, errors, scan controls, and documentation |
| Settings | Application folders, exclusion reset, and privacy/behavior information |

Right-click an app for details, Reveal in Finder, Ignore App, or Skip This Release. **Show ignored** reveals excluded entries; **Settings → Reset All Exclusions** restores them.

## Optional Sparkle feed checks

Enable **Sources → Check embedded Sparkle feeds** to check applications without a manager route or App Store receipt. The setting is off until selected. Compatible numeric releases appear as read-only feed observations; available updates require the application's own updater. Maccet never downloads an enclosure or grants a Sparkle result automatic-installation eligibility.

Requests reject redirects and use HTTPS, private ephemeral sessions, a 1 MiB response cap and request/resource time limits. A scan starts at most 16 requests within a 30-second start budget; omitted feeds remain unchecked. Results cover the embedded feed's default channel, with runtime overrides explicitly unobserved. See [scope, limits and verification](docs/SPARKLE-CHECKS.md).

## Source-mapping trust foundation

The core defines versioned identity/channel/domain/capability evidence and authenticates supplied catalogs with client-pinned Ed25519 keys, revision/expiry checks and a retained known-good cache. Catalog evidence alone cannot authorize automatic installation. See [the wire format and trust boundary](docs/SOURCE-MAPPING-TRUST.md). No production publisher key or remote catalog endpoint is configured; broad discovery remains separate work.

## Update and cleanup behavior

Only one Maccet operation can own a canonical application path for the current user at a time, across engines, separate app instances and separate download caches. Another attempt is deferred before source commands or cache creation; unrelated apps remain independent. Ownership spans preflight, installation, verification and cleanup. macOS releases the lock if its owner exits, but Maccet never retries the installation automatically: rescan and review after interruption. Other package-manager clients do not participate in this Maccet ownership protocol.

Review also records the canonical destination of the selected update tool. Changing a tool symlink after review requires a new scan and plan; the destination is checked again at installation boundaries. This detects destination changes, not in-place binary replacement, library changes or an external retarget in the interval after a check.

Homebrew updates are scoped to a named cask with `--no-quit` and `--skip-cask-deps`. Homebrew's automatic cleanup is disabled for these invocations. A dry run is shown before execution. Homebrew can still perform its own necessary installation actions, such as binary linking; related changes reported by its preview are visible in the review sheet.

The first alpha supports automatic updates for simple, specifically versioned app casks whose target metadata can be verified. A complete SHA-256 package digest is required and must remain unchanged through review and both preflight checks. Missing, malformed, and `no_check` digests require manual attention, as do pinned, disabled, complex installer, non-numeric vendor-version, and ambiguous cases. Apps installed outside Homebrew are not silently adopted, even if they appear in its catalog.

Update review captures code-signature evidence. Signed applications must pass strict resource, nested-code and architecture validation before installation and after the target metadata matches. Certificate-signed replacements must satisfy the reviewed designated requirement, signing identifier and team identity. Ad-hoc signatures establish integrity and a signing identifier, without certifying a publisher. Applications already unsigned at review remain supported without a publisher-authenticity claim; a newly signed replacement must validate. Invalid signatures or changed reviewed signing identities prevent success and retain the attempt's artifacts. These are point-in-time checks, not a guarantee against concurrent external changes or a substitute for Gatekeeper/notarization.

App Store operations use a fixed `mas` executable and validated numeric store ID. The app does not collect or store your Apple Account or administrator password. If a store operation fails, open App Store from the app row and resolve the issue there.

For Homebrew, each update attempt gets a separate cache folder under this app's local data directory. After the reviewed target is verified, only that attempt's download and temporary-log files are eligible for automatic removal. Cleanup retains the directory structure and ownership marker, so a late directory-name swap cannot redirect recursive deletion. Failed or unverified attempts retain their artifacts. Disabling cleanup retains successful-attempt files too.

Shared Homebrew caches, general app caches, user preferences, licenses, and documents are preserved. App Store manages its own downloads. The app does not invoke `brew cleanup`, `uninstall`, `zap`, or a global cache deletion command. This deliberately limits cleanup coverage in this alpha.

**Cancel Remaining** cancels queued work and prevents installation when cancellation arrives before the install stage. An active installation is allowed to finish safely; it is not forcibly terminated. Independent failures do not stop the rest of a valid queue. macOS may show an authorization dialog for each store update.

MacPorts checks use the existing local ports index; the UI labels that limitation. **Refresh Metadata** runs `port -N sync` for index data; **Prepare Sources** runs `port -N selfupdate`, which can also update MacPorts itself, with macOS authorization before rescanning. Launch and diagnostic scans use the existing local index. An update preview uses `port -y -N upgrade <name>`; the reviewed installation uses one named package and may update required dependencies shown in the preview. macOS authorization is requested for the standard root-owned installation. Shared MacPorts caches and inactive versions are retained. Revision-only and incomparable vendor changes require manual verification.

## Build from source

Install Apple's Command Line Tools or Xcode with a Swift toolchain compatible with its macOS SDK. The package has no third-party dependencies.

```bash
bash scripts/test.sh
bash scripts/build.sh
open 'dist/Maccet.app'
```

The build script creates the release executable, application bundle, generated icon, and a ZIP archive in `dist/`. It signs the local app with an ad-hoc signature. The app is **not Developer ID signed or notarized**, and this alpha is not a public distribution release. Developer ID signing and notarization require the owner's signing configuration and remain a separate release step.

The minimum tools version in the manifest is Swift 5.9. Testing older compiler/SDK combinations remains part of the wider support matrix; the validation document names the toolchain used for this build.

## Checks and read-only diagnostics

```bash
# Dependency-free Swift check suite; no real app updates are performed.
bash scripts/test.sh

# Validate the packaged startup resource without installing anything.
'dist/Maccet.app/Contents/MacOS/UnifiedUpdater' --check-startup-script

# Inventory only: no remote source checks.
'dist/Maccet.app/Contents/MacOS/UnifiedUpdater' --inventory-json

# Full read-only source check. May refresh source metadata caches.
'dist/Maccet.app/Contents/MacOS/UnifiedUpdater' --scan-json

# Restrict diagnostics to one application folder.
'dist/Maccet.app/Contents/MacOS/UnifiedUpdater' --inventory-json --folder /Applications
```

The check suite is an executable target named `UpdaterCoreChecks`, rather than XCTest, so it also runs on a Command Line Tools installation without Xcode's test frameworks. It exits nonzero when a check fails and exercises the real core with synthetic app bundles and fake source processes. A real process is used only for benign output/timeout checks.

`UNIFIED_UPDATER_DATA_DIR=/absolute/path` redirects this app's settings/history and source caches for isolated development or UI validation. Diagnostic JSON is a local inspection tool and can contain installed-app metadata; the UI's report export applies diagnostic redaction.

## Local data and privacy

Default storage: `~/Library/Application Support/UnifiedUpdater/`.

- `preferences.json`: scan roots, source configuration, and exclusions.
- `history.json`: up to 1,000 recent update records.
- `SourceCache/`: source metadata and isolated update attempts.

Explicit source preparation contacts GitHub, Homebrew, MacPorts, and Apple services to obtain and verify dependencies. Application checks contact source services. There is no analytics service or separate inventory-upload backend. Reports are exported only to a location you choose. Report contents are written to a new same-directory file with explicit POSIX mode 0600 before atomic publication, including when replacing an existing report. A failed write leaves the previous destination intact. Diagnostic strings redact home paths and common credential-bearing URL values; review any report before sharing it.

Subprocess stdout and stderr are drained independently through anonymous pipes. Only the first 16 MiB of each stream are retained in memory; raw process captures are not written to disk. Excess output is drained and discarded while the command continues. After it exits, an oversized result is rejected with its exit status and a sanitized diagnostic prefix, rather than parsed as complete. Output volume does not terminate an installer. Inherited output descriptors do not delay the owned command or retain its captured buffers after completion.

If the app closes during an operation, active history entries become **Interrupted** on next launch. No operation is automatically retried and no artifacts are automatically deleted during recovery. Rescan first to inspect the installed state.

## Project structure

```text
Package.swift
Sources/
  UpdaterCore/       Inventory, source parsers/adapters, planning, execution,
                     verification, owned cache cleanup, local persistence
  UnifiedUpdater/   SwiftUI desktop screens and application state
Tests/
  UpdaterCoreTests/  Executable behavior-check suite
scripts/            Test, release packaging, icon generation, bundle metadata
docs/
  STARTUP_SETUP.md   Automatic dependency installation and maintenance
  PRODUCT_SPEC.md   Original product plan and future roadmap
  VALIDATION.md     Actual validation evidence and limitations
CHANGELOG.md
```

## Known alpha limitations

- No universal app coverage. Unmanaged direct-download apps remain unchecked.
- Optional Sparkle checks observe numeric default-channel releases from embedded HTTPS feeds. Runtime overrides, custom version comparators, signed appcasts and complex major-upgrade rules require the application’s built-in updater; Maccet does not install Sparkle updates.
- Homebrew and MacPorts are implemented. Nix, pkgsrc/pkgin, developer package updates, app adoption, scheduling, and notifications remain future work.
- MacPorts is tested with controlled fixtures against its documented command formats; it is not installed on the validation machine, so real MacPorts upgrades remain unverified.
- macOS and source-tool combinations beyond those in the validation notes are not certified.
- Apple lookup/indexing delays can hide an App Store update; “Current in source” is deliberately qualified.
- Tool checks time out, but a source operation already in progress is not instantly cancellable.
- Installer output is captured; UI progress is stage-based rather than a claimed download percentage.
- Complex casks or authorization flows that require an interactive terminal are deferred to the source tool.
- Unknown/incompatible releases may require source-specific manual handling; no claim of exhaustive incompatible-release discovery.
- No space-reclaimed measurements, global cleanup, automatic rollback, or guarantee of atomic third-party installation.
- Scan snapshots are not persisted; update history is persisted. Rescan after launch or restart.
- No public GitHub release, Developer ID signature, notarization, or universal binary has been published by this local build.

## Next releases

Current development version: **0.1.2**. Next priorities: cross-catalog discovery with verified identity mappings, Nix profile-aware routing, pkgsrc/pkgin, broader real-device validation, and reviewed source adoption. Sparkle and vendor endpoints can further cover apps not owned by a package manager. See the product specification for the broader roadmap.
