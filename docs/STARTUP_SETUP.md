# Source readiness and explicit preparation — 0.1.2

The GUI reads the configured application inventory, checks readiness of applicable enabled source tools, and scans available sources once per app process. Opening another window does not repeat this sequence. Startup does not install tools, refresh indexes, upgrade helpers, download packages, or request authorization.

Source maintenance is split into two explicit, independently reviewable actions:

- **Sources → Install Missing Tools** adds only missing source tools and their dependencies. It does not upgrade already-installed tools or the App Store helper.
- **Sources → Upgrade Source Tools** updates installed Homebrew, MacPorts and mas. These commands inherently refresh local metadata (`brew update` refreshes Homebrew; `port -N selfupdate` refreshes MacPorts base and port definitions), so they are not presented as metadata-untouched.

After a partial failure, the same action offers a retry that repeats only failed or unfinished steps. Application updates remain in their reviewed update queue and are never started by either maintenance action.

## Independently scoped metadata requests

**Sources → Refresh Metadata** uses `SourceMetadataRefresh` and separate per-source results/last-attempt time. It does not reuse or overwrite tool-preparation evidence and does not turn a metadata failure into a previous setup retry. Metadata failures remain visible in source attention; a later request can clear them. The following app scan is serialized with the request, and existing update selections/reviews are cleared first.

- Homebrew: use the same Maccet cache as ordinary scans and run `outdated --cask --greedy --json=v2` with `HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_FORCE_API_AUTO_UPDATE=1`, `HOMEBREW_API_AUTO_UPDATE_SECS=0` and a cleared `HOMEBREW_API_UPDATED`. Homebrew classifies `outdated` as an API auto-update command, while its Git/tool auto-update returns early under NO_AUTO_UPDATE. API-disabled Git-tap mode fails this narrow request; it never falls back to `brew update`. A completed cask check can still use verified cached data if the upstream API is unavailable, so the UI labels completion/attempt time rather than guaranteed freshness.
- MacPorts: the bundled `ports-sync` action requests only `/opt/local/bin/port -N sync` through normal macOS authorization. The [official sync manual](https://man.macports.org/port-sync.1.html) distinguishes port definitions from the base update performed by [selfupdate](https://man.macports.org/port-selfupdate.1.html). Base/tool updates remain explicit preparation.
- App Store: there is no local package index to maintain. The following ordinary application scan performs its live check.

Missing tools do not trigger installation, developer-tool requests, helper upgrades or a different maintenance intent. Disabled sources, inventory relevance and the optional-MacPorts policy still apply. Independent sources can complete after another request fails. Source versions and canonical destinations are validated before the metadata command. Homebrew API behavior was checked against the official 6.0.0 and installed 7.0.9 implementation; this does not close the live/clean-machine acceptance gates.

## Read-only readiness

`DependencySetup.checkReadiness` shares applicability policy, validated version probes, and canonical path recording with explicit preparation. Existing mas readiness does not add dependencies of a future maintenance action. It only runs `xcode-select --print-path` and required tools' version commands, each with a 20-second timeout. The Apple-tools result describes whether a developer directory is selected; explicit preparation checks `clang` before maintenance. Launch avoids invoking developer-tool shims that may request installation. Missing tools show **Unavailable**, failed or incompatible version probes show **Failed**, and successful source tools expose their canonical path and reported version. Apple tools being unavailable does not hide working source tools. Disabled and unnecessary tools receive no commands. Readiness success does not claim the source index is fresh or reuse a previous maintenance result.

The following application scan can contact source services and use the local MacPorts index. Inventory and working sources remain usable when other tools are unavailable. Choose **Install Missing Tools** to add tools, **Upgrade Source Tools** to update installed tools, or **Refresh Metadata** to refresh indexes without changing tools. The UI distinguishes each action from readiness; quit protection applies during maintenance and application updates, while readiness checks can be closed normally.

## Applicable tools

Source switches apply to preparation as well as application checks. A disabled
source is skipped unless its manager is required by the enabled App Store
helper: an existing MacPorts-owned mas uses MacPorts; other mas installations,
including a missing helper, use Homebrew. The setup UI identifies that manager
as **Required for App Store** even when its own application source is disabled.
If all sources are disabled, source steps show **Disabled**, developer tools
show **Not needed**, and inventory continues without setup commands or
authorization prompts. The sequence below runs only for required tools.

When inventory completes without warnings, an empty or macOS-only inventory
needs no source preparation. Store-receipt applications may need App Store;
applications without receipts may need Homebrew or MacPorts. Store-only
inventories prepare only the helper's package-manager route, and inventories
without store-receipt applications skip mas. Package managers remain potential
routes: this filtering does not prove ownership of a non-store application.

Any inventory warning, or an API caller omitting inventory, keeps candidate checks conservative. Installing an absent optional MacPorts manager additionally needs ownership/dependency evidence, previous successful explicit preparation on retry, or the current-session Sources opt-in. Warnings remain visible. Every preparation attempt, including
retry, recomputes these needs; previously successful steps are reused only
when still applicable. The later source check remains a separate operation
and uses the same inventory-applicability rules.

## Install Missing Tools sequence

1. Check Apple developer tools with `xcrun --find clang`. If missing, request Apple's installer using `xcode-select --install`. The system controls its download, license, and installation. Finish it and retry **Install Missing Tools**; dependent work is paused until then.
2. Find Homebrew under `/opt/homebrew/bin` or `/usr/local/bin`. When missing on Apple Silicon, download `Homebrew.pkg` from the latest official `Homebrew/brew` GitHub release, verify the release SHA-256 and Gatekeeper assessment, and install through macOS authorization. Check its version. No `brew update` is run here; use **Upgrade Source Tools** for that.
3. Find MacPorts at `/opt/local/bin/port`. When missing, select exactly one package from the latest official `macports/macports-base` release whose OS major version matches this Mac. Verify SHA-256 and Gatekeeper before installing through macOS authorization. Check its version. No `port selfupdate` is run here; use **Upgrade Source Tools** for that.
4. For a missing `mas`, install it through Homebrew with `brew install --formula mas`. An existing `/opt/local/bin/mas` is left to MacPorts; an existing Homebrew-owned `mas` is not upgraded. Check that the helper reports version 7 or later.
5. Show the result of each step, then scan applications using the available sources. A failed step does not turn its status into success or prevent an independent source from completing.

## Upgrade Source Tools sequence

1. Developer tools are not reinstalled. **Upgrade Source Tools** only touches installed tools required by the enabled sources; missing required managers report failure instead of being installed.
2. For required Homebrew, run `brew update` and check its version. This refreshes Homebrew's local metadata.
3. For required MacPorts, run `port -N selfupdate` with administrator authorization and check its version. This refreshes MacPorts base and port definitions.
4. For required `mas`: if it is `/opt/local/bin/mas`, update it through MacPorts (`port -N -k upgrade mas`); otherwise update it through Homebrew (`brew upgrade --formula mas`). Check that the helper reports version 7 or later.
5. Show the result of each step, then scan applications using the available sources. A failed step does not turn its status into success or prevent an independent source from completing.

`Sources/UpdaterCore/Resources/prepare-sources.sh` contains the fixed maintenance operations. `DependencySetup` drives prerequisite checks, release selection, downloads, verification, and progress. SwiftPM bundles the script, and the build script copies its resource bundle into the app. The distributed app does not depend on the source checkout or its build cache.

## Authorization and failure handling

macOS owns the administrator dialog. Maccet does not collect passwords. Authorization can be canceled in that dialog. An active privileged installer is allowed to finish; closing Maccet during source preparation is blocked to avoid abandoning it. Source maintenance is serialized with application scans and updates.

Progress is step-based, without a download percentage. Failed and canceled steps show their diagnostic message in **Sources**. A retry of the same action rechecks Apple developer tools (for **Install Missing Tools**) and repeats failed or unfinished steps. A successful tool's `SetupItem` records its canonical executable path and reported version. Required cached tools must still resolve to that path and pass a fresh, read-only version command within 20 seconds; mas must still report version 7 or later. The current version replaces the previous observation. Missing tools, changed paths or symlink targets, failed commands, empty versions, and incompatible mas versions invalidate the cached success. **Install Missing Tools** may add a missing tool; **Upgrade Source Tools** reports it as failed and never installs it.

Healthy tools retain their successful result without repeating maintenance, including a package manager required by a failed mas step. Disabled and unnecessary tools run no readiness probes. Maintenance success is reused only for retry within the same action in the current session. A launch readiness result never substitutes for maintenance. There is no automatic retry loop.

Downloaded packages use a private per-attempt temporary directory and are removed when the attempt finishes. Packages are checked before authorization and rechecked by the authorized process immediately before installation. Missing release digests, foreign URLs, ambiguous packages, mismatched hashes, and rejected signatures block installation. Source tools may keep their normal metadata caches. Shared caches and installed app data are not deleted by startup.

## Platform limits

The current official Homebrew package supports Apple Silicon. On Intel, install Homebrew once from its official instructions, then use **Install Missing Tools** or **Upgrade Source Tools**; updates to that existing installation are automated. This app's macOS 13 deployment target does not promise that the latest upstream tools support every older macOS release. Missing OS-specific MacPorts installers are reported rather than guessed. No installer is compiled from source as a fallback.

An App Store account may still need to be signed in through Apple's own app. Xcode licenses and additional source-specific requirements may need system interaction. The app cannot grant itself system privileges or accept licenses for the user.

Changing source switches affects app checks and the next preparation run; it does not interrupt an active installer. Disabled source steps do not count as setup failures. Installing an additional manager does not adopt existing applications or automatically expand verified ownership coverage.

## Scope of explicit changes

**Install Missing Tools** adds missing source tools and their dependencies without upgrading already-installed tools. **Upgrade Source Tools** updates the enabled source tools themselves; `brew update` and `port -N selfupdate` inherently refresh local metadata, so the UI reports that accurately rather than claiming metadata was untouched. Neither action installs missing managers, upgrades user applications, invokes `port upgrade outdated`, performs application cask upgrades, or runs global cleanup. Inventory application upgrades continue through the existing explicit review queue.

The diagnostic entry points `--inventory-json`, `--scan-json`, and `--check-startup-script` bypass GUI setup. The last command validates that the bundled startup script is readable and has valid shell syntax without installing or updating anything.

## Separated maintenance intents validation — 18 October 2026

`DependencySetup` now exposes `installMissingTools()` and `upgradeSourceTools()` in addition to the combined `prepare()` path. `bash scripts/test.sh` passes **192 core checks**, including new coverage that install-missing does not upgrade installed tools, that upgrade-tools does not install missing managers, and that partial retries preserve unrelated ready work. `bash scripts/test-setup-retry.sh` passes **20 orchestration checks** against `AppModel`, covering the new **Install Missing Tools** and **Upgrade Source Tools** buttons, retry semantics, and continued independence from **Refresh Metadata**. The release build, packaging, local ad-hoc signature verification, and bundled startup-script check pass. No real source tools or applications were maintained.

## Retry validation — 16 October 2026

The historical validation sections below describe behavior at the time of each PR. Current launch and maintenance behavior is described above.

Two regressions reproduced the old retry behavior by repeating the full setup
call used by the GUI: **68 passed, 2 failed**. The retry API now receives the
previous session result. `bash scripts/test.sh` passes **74 checks**, including
partial failures, repeated failure, a failed helper, a missing previously ready
tool, and a MacPorts-owned helper. The existing fresh-launch check still
requires full maintenance on each launch.

`bash scripts/test-setup-retry.sh` passes **3 orchestration checks** against
`AppModel`: partial failure, retry of only the failed source followed by a scan,
and full preparation in a new session. Source commands and tool discovery are
injected, so the test does not install or maintain real tools.

An isolated copy of the user's local work, with merged PRs #1–#2 and this
change, passes **85 core checks**, the **5 existing UI orchestration checks**,
and the **3 setup retry checks**. The PR release build, packaging, local ad-hoc
signature verification, and bundled startup-script syntax check also pass.

The isolated inventory baseline remains **112 apps** (34 third-party,
78 system-managed), with **0 warnings**. Environment: Apple Silicon arm64,
macOS 27.0.1, Swift 6.4. The original checkout and installed applications were
left untouched. This closes only the retry behavior in Phase C; need-based
source preparation, readiness details, and clean-machine acceptance remain open.

## Disabled-source validation — 16 October 2026

The controlled GUI regression failed before this change because disabling all
sources still triggered preparation commands. After the fix,
`bash scripts/test.sh` passes **82 core checks** and
`bash scripts/test-setup-retry.sh` passes **5 orchestration checks**.
Coverage includes all sources disabled with no tools, Homebrew-only and
MacPorts-only preparation, both mas ownership routes, a missing helper,
missing Apple tools, and changing source settings between retries.

The PR release build, packaging, local signature verification, and bundled
startup-script syntax check pass. A fresh read-only inventory found 112 apps
with no warnings. No installed applications or source tools were maintained.
An isolated snapshot containing the unpublished local UI redesign passes
93 core, 5 existing UI orchestration, and 5 setup orchestration checks. Its
phase labels were adapted to `SetupPhase.title` and its dependency display
updated for compatibility; the original checkout was left untouched.

This addresses enabled-source selection in Phase C. Deciding which enabled
sources are useful to the discovered application inventory, fuller readiness
reporting, and clean-machine acceptance remain open.

## Inventory-based preparation validation — 16 October 2026

Before this change, the controlled GUI regression failed because an empty
inventory still triggered tool maintenance. After the fix,
`bash scripts/test.sh` passes **90 core checks** and
`bash scripts/test-setup-retry.sh` passes **8 orchestration checks**.
Coverage includes complete empty and system-only inventories, non-store
inventories, both store-helper manager routes, incomplete inventory, disabled
sources, missing developer tools, and changed inventory between retries.
The GUI test also checks that inventory is published before the first
developer-tool command runs.

The PR release build, packaging, local signature verification, and bundled
startup-script syntax check pass. An isolated snapshot of the unpublished
local UI passes **101 core checks**, **5 existing UI orchestration checks**,
and **8 setup orchestration checks**. In that snapshot, the existing
developer-tool failure assertion was adapted to expect mas to remain
**Not needed** for its non-store fixtures, and the setup copy was updated.
The original checkout was left untouched.

A fresh read-only inventory found **112 apps** (34 third-party, 78 managed by
macOS), with **0 warnings**. Environment: Apple Silicon arm64, macOS 27.0.1,
Swift 6.4. No installed applications or source tools were maintained.

This adds conservative applicability filtering for preparation. Exact package
ownership checks, richer readiness reporting, and clean-machine acceptance
remain separate requirements; preparation does not establish update coverage.

## Source-check applicability — 16 October 2026

Preparation and update checks share `InventoryResult.applicableSources`.
Complete empty/system-only inventories run no source commands. Store-only
inventories check App Store without querying package managers; non-store
inventories skip App Store. Inventory warnings keep all enabled sources
applicable, and disabled settings always take precedence.

`SourceHealth.checkRequired` records whether the current inventory needs the
check. A skipped source is displayed as **Not needed**, independently of
whether its tool is installed. Required missing or failed tools still produce
attention, and skipped checks never mark an application current. Changing
scan settings invalidates the old applicability decision until a new scan.
The optional field is backward compatible: older reports decode with unknown
applicability and retain conservative attention behavior.

Two regressions failed before the fix: **90 passed, 2 failed**. After the fix,
`bash scripts/test.sh` passes **98 checks** and
`bash scripts/test-setup-retry.sh` passes **9 orchestration checks**. Cases
cover unnecessary installed/missing tools, store-only and non-store inventories,
required failures, incomplete inventory, disabled settings, old-report decoding,
and changed scan settings. These checks use controlled commands and fixtures.

The PR release build, packaging, local ad-hoc signature verification, and
bundled startup-script syntax check pass. A fresh read-only inventory contains
112 apps with no warnings. An isolated unpublished UI snapshot passes
109 core, 5 existing UI, and 9 setup orchestration checks; its attention and
source badges were adapted for applicability. The original checkout and
installed applications were not changed.

This distinguishes source-check applicability from tool presence. Canonical
tool/version readiness details and clean-machine acceptance remain open.

## Cached readiness validation — 17 October 2026

Three regressions reproduced stale retry readiness: **98 passed, 3 failed**.
A relocated Homebrew, a failing MacPorts executable, and a downgraded mas had
all retained their previous Ready results. After the fix,
`bash scripts/test.sh` passes **106 core checks** and
`bash scripts/test-setup-retry.sh` passes **11 orchestration checks**.
Additional cases cover symlink retargeting, canonical aliases, current version
reporting, bounded probes, empty responses, disabled sources, and helper recovery
without repeating healthy manager maintenance. Commands use controlled runners;
no tools or applications are updated by these tests.

The PR release build, packaging, local ad-hoc signature verification, and bundled
startup-script check pass. A fresh read-only inventory remains at **112 apps**
(34 third-party, 78 system-managed), with **0 warnings**. The isolated unpublished
UI snapshot passes **117 core**, **5 existing UI**, and **11 setup orchestration**
checks. The original checkout remains untouched.

This verifies current canonical location and reported version before reusing
preparation. The minimum-version policy remains mas 7 or later; Homebrew and
MacPorts must execute successfully and report a nonempty version. Binary-signature
validation, broader compatibility policy, separation of startup detection from
maintenance, and clean-machine acceptance remain open.

## Readiness-only launch validation — 17 October 2026

A controlled GUI regression failed because opening the app performed source
maintenance. Startup now calls `checkReadiness`, then scans working sources.
`Prepare Sources` calls the maintenance API explicitly; its first run cannot
reuse a successful readiness probe as a successful maintenance result.
Partial maintenance still offers `Retry Setup` and retains healthy work.

`bash scripts/test.sh` passes **114 core checks** and
`bash scripts/test-setup-retry.sh` passes **15 orchestration checks**. Coverage
includes present/missing tools, read-only failures, incompatible mas, missing
Apple tools with working sources, disabled and unnecessary sources, manager
dependencies, repeated windows, a new launch, explicit maintenance, and recovery.
Controlled commands exercise failure paths without installing or updating tools.

The release build, packaging, local ad-hoc signature verification, and bundled
startup-script check pass. An isolated unpublished UI copy passes **125 core**,
**5 existing UI**, and **15 setup orchestration** checks. A fresh read-only
inventory remains **112 apps** (34 third-party, 78 system-managed), with **0
warnings**. The original checkout and installed applications remain untouched.

Launch checks the selected Apple developer directory with `xcode-select
--print-path`; compiler validation remains in explicit preparation. This avoids
launching developer-tool shims on a machine without tools. Readiness does not
certify a working compiler, a fresh source index, or current source metadata.
Index refresh and helper upgrades still share the explicit preparation action;
separate maintenance actions and clean-machine acceptance remain open in Phase C.

## References

- [Apple developer-directory selection](https://developer.apple.com/documentation/xcode/configuring-command-line-tools-settings)
- [Apple command-line tool shims and installation](https://developer.apple.com/library/archive/documentation/Xcode/Conceptual/RN-Xcode-Archive/Chapters/xc5_release_notes.html)

- [Homebrew installation and package constraints](https://docs.brew.sh/Installation)
- [Homebrew update and named formula operations](https://docs.brew.sh/Manpage)
- [MacPorts installation and selfupdate](https://www.macports.org/install.php)
- [mas installation](https://github.com/mas-cli/mas)
