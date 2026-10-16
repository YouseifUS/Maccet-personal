# Unified macOS App Updater

> A proposed macOS desktop application that discovers installed apps, checks multiple update sources, presents one reliable update list, and updates supported apps from one place.

**Project status:** Planning and specification. This repository does not yet contain a working application. All screens, modules, functions, and milestones below describe intended behavior.

**Working title:** Unified macOS App Updater. The final product name is undecided.

## 1. The Problem

macOS applications are installed and updated through different channels: Homebrew, the Mac App Store, direct downloads, built-in updaters, and vendor-specific tools. Users must check several places and cannot easily tell which applications are outdated or which update attempts succeeded.

The project brings these channels into one interface while preserving the identity, installation source, and update requirements of each app.

## 2. Product Goals

- Discover applications in standard and user-selected application folders.
- Identify the installed release and available update sources for each application.
- Present one deduplicated list of available, compatible updates.
- Support updating an individual application, selected applications, or all eligible applications.
- Include a dedicated view of Mac App Store updates.
- Show applications that need manual intervention and explain the next action.
- Verify update results by inspecting the installed application again.
- Remove known obsolete update downloads and temporary files after successful updates.
- Explain missing coverage honestly: an unchecked app is never labeled up to date.
- Grow coverage through independent source adapters rather than hard-coded UI logic.

### Product principles

1. **Coverage is measured by applications checked successfully, not by the number of integrated package managers.**
2. **Finding an update and installing an update are separate capabilities.**
3. **Every installed application instance has one active update route for a particular update operation.**
4. **Existing installation ownership and release channels are preserved unless the user explicitly changes them.**
5. **A completed command is evidence of an attempt, not proof that an update succeeded.**
6. **Cleanup removes identified update artifacts, not arbitrary application data.**

## 3. Scope and Release Boundaries

| Area | First release | Later expansion |
| --- | --- | --- |
| Desktop apps | Scan standard/custom app folders; identify installed apps | Better coverage of unusual layouts and vendor suites |
| Homebrew Casks | Detect managed apps, check updates, update, verify | Explicit adoption workflow for suitable unmanaged apps |
| Mac App Store | List updates through `mas`; attempt supported updates; provide fallback | Refine behavior across tested macOS and `mas` versions |
| Sparkle | Record useful metadata where available; no universal update promise | Feed-based checks, then installation for explicitly supported cases |
| Vendor integrations | Explain unsupported/manual update routes | Add individual integrations with documented capabilities |
| Cleanup | Known update downloads and temporary artifacts | Optional app-cache cleanup using reviewed per-app rules |
| Developer packages | Outside the initial application list | Separate optional section for tools and package ecosystems |
| Automation | Manual scan and user-initiated updates | Scheduled checks and optional notifications |

The first release does not include OS upgrades, a general package installation marketplace, application uninstallation, universal rollback, or unattended updates for every application.

## 4. Supported Sources and Their Limits

### 4.1 Homebrew Casks

The adapter detects the available Homebrew installation, reads its managed cask inventory, refreshes metadata when appropriate, and asks Homebrew to check and update selected managed applications.

Requirements:

- Use supported structured output where available and validate its schema.
- Distinguish Homebrew-managed apps from apps that merely have a matching catalog entry.
- Account for casks with self-updating behavior or non-specific versions; do not silently treat them as ordinary version comparisons.
- Show catalog freshness and avoid claiming a newer release is available when the source cannot establish it.
- Serialize mutations against the same Homebrew installation.
- Capture the actual scope of a planned operation, including related changes that the package manager can identify.
- Coordinate Homebrew's own cleanup behavior with the app's cleanup reporting; do not count the same removal twice.

Homebrew supports update, outdated, upgrade, cleanup, and cask adoption operations. Adoption has conditions, including matching existing artifacts, and must not be treated as a universal migration mechanism. See the [Homebrew manual](https://docs.brew.sh/Manpage).

### 4.2 Mac App Store via `mas`

The adapter uses `mas` to discover installed store applications, check available updates, and attempt selected updates.

Requirements:

- Detect the installed `mas` version and supported output/options.
- Associate store IDs with discovered application instances where reliable evidence exists.
- Report account, permissions, indexing, network, and compatibility problems separately.
- Handle authentication through supported macOS/App Store interactions; never collect Apple Account credentials in the app.
- Allow the user to open the relevant App Store page when automated updating is unavailable.
- Treat inaccurate or incomplete store lookup results as uncertainty, not proof of current status.
- Verify the installed result after an update attempt.

`mas` documents both update operations and limitations of its outdated-app detection. Behavior must be tested on the project's supported macOS versions. See the [mas documentation](https://github.com/mas-cli/mas/blob/main/README.md).

### 4.3 Sparkle Update Feeds

Many applications publish update information through Sparkle appcasts. An adapter can use available application metadata and feed information to investigate updates.

Later-phase requirements:

- Discover feed metadata without executing arbitrary application code.
- Interpret release/build versions, compatibility restrictions, and release channels.
- Respect feed validation and archive signature requirements.
- Classify each integration as detection-only, manual handoff, or supported installation.
- Never infer that a readable feed makes external installation safe or supported.

See the [Sparkle documentation](https://sparkle-project.org/documentation/).

### 4.4 Vendor-Specific Sources

Add integrations individually for applications that require a vendor updater, official release endpoint, or a special installation process.

Each integration must define its identity mapping, authoritative source, version comparison, compatibility checks, installation method, verification method, and cleanup ownership. If only a manual handoff is supported, the UI must say so.

### 4.5 Additional Package Managers

Potential future adapter candidates include MacPorts and Nix, followed by optional developer ecosystems such as npm, Python tooling, and Cargo.

These are evaluation candidates, not promised first-release support. Each requires a coverage study and its own installation/environment model. A manager must never update packages owned by a different manager. Developer tools and project-local dependencies must not be mixed into the desktop application update queue.

## 5. Main User Journey

1. Launch the app and select application folders.
2. Review detected update sources and any missing dependencies.
3. Click **Check for Updates**.
4. Watch partial results arrive while other sources finish.
5. Review available updates, manual actions, exclusions, and unchecked apps.
6. Select applications or choose **Update All**.
7. Review the concrete update plan: selected apps, required closures, permissions, and manual actions.
8. Start the update queue.
9. Follow any supported authentication or application-close prompts.
10. Review verified results, failures, deferred work, and cleanup results.

The app remains useful when only some sources are available. It must not require installing every integration to perform a scan.

## 6. UI and Navigation

### 6.1 Visual Direction

- Native macOS desktop layout with a sidebar, toolbar, main list, and details inspector.
- System typography, standard controls, light/dark appearance, and clear keyboard focus.
- App icons and readable names take priority over technical package identifiers.
- Status labels always include text; color alone never conveys meaning.
- Progress is determinate only when reliable progress data exists.
- Technical logs are available through a details action rather than dominating the normal workflow.
- Layout must support resizing, long app names, accessibility text sizing, and localized strings.

### 6.2 Sidebar

| Screen | Purpose |
| --- | --- |
| Updates | Unified list of available updates and actions requiring attention |
| Installed Apps | Complete discovered inventory and coverage status |
| App Store | Filtered store inventory and update actions |
| Activity | Current queue and historical scan/update/cleanup results |
| Cleanup | Eligible update artifacts, estimates, and removal results |
| Sources | Integration availability, health, versions, and configuration |
| Settings | Scan locations, update policies, exclusions, and privacy preferences |

### 6.3 Main Screen Wireframe

```text
+----------------------------------------------------------------------------------+
| Unified macOS App Updater       [Search apps...]     [Check for Updates]           |
+------------------+---------------------------------------------------------------+
| Updates       5  | Updates                                      [Update All (3)]  |
| Installed Apps   | Checked 32 of 40 apps · 3 automatic · 2 need action             |
| App Store        | Last checked: 2 minutes ago · 8 apps could not be checked       |
| Activity         |                                                               |
| Cleanup          | [All sources v] [All statuses v] [Show ignored]                |
| Sources          |                                                               |
| Settings         | [x] App A   2.1 -> 2.3   Homebrew       Ready        [Update]   |
|                  | [x] App B   5.0 -> 5.2   App Store      Ready        [Update]   |
|                  | [x] App C   1.0 -> 1.1   Homebrew       Ready        [Update]   |
|                  | [ ] App D   3.0 -> 3.2   Vendor         Manual       [Open]     |
|                  | [ ] App E   4.0 -> 4.1   App Store      Sign-in      [Resolve]  |
|                  |                                                               |
|                  | [View unchecked apps]                    [Update Selected]    |
+------------------+---------------------------------------------------------------+
```

All counts and application names in the wireframe are illustrative. Source counts overlap in the underlying inventory and must be deduplicated before being displayed as app counts.

### 6.4 First Launch

- Explain the app's purpose in one short screen.
- Offer `/Applications` and `~/Applications` as initial scan locations.
- Let the user add/remove folders and resolve access restrictions.
- Detect sources and show **Available**, **Missing**, **Disabled**, or **Needs Attention**.
- Explain what each optional dependency enables and offer setup guidance.
- Do not silently install package managers or change application ownership.
- Allow the first scan with the sources already available.

### 6.5 Updates Screen

Each row shows a selection checkbox, app icon/name, installed version, target version, selected source, update status, and primary action.

Functions:

- Search by application name and filter by source/status.
- Select eligible rows, update one, update selected, or update all eligible rows.
- Open application details and release notes when provided by a validated source.
- Ignore an application or skip a particular release.
- Resolve blockers or open a supported manual update route.
- Show incompatible newer releases separately from installable updates.
- Show stale results and source failures without clearing valid partial results.

**Update All** includes the currently known, eligible, non-ignored applications. Its label and review screen show the exact count. If filters hide included apps, the review screen must still list them. It must never expand into an unreviewed blanket manager upgrade.

**Update Selected** operates only on explicitly selected eligible rows. Results that change before execution require plan revalidation.

### 6.6 Installed Apps Screen

- List discovered application instances, including unsupported and unchecked ones.
- Show path, installed release, ownership evidence, detected sources, and last successful check.
- Filter by up-to-date, update available, unchecked, unsupported, ignored, or blocked.
- Reveal an application in Finder or open it.
- Explain why a source matched or why an identity is ambiguous.
- Keep separate copies visible when the same application exists at multiple paths.
- Later: offer an explicit, reviewed adoption workflow where supported.

### 6.7 App Details Inspector

Display:

- App name, icon, bundle ID, installed path, marketing version, and build version.
- Architecture and macOS compatibility information when known.
- Ownership, alternative source matches, and selected update route.
- Target release, channel, release notes, and source freshness.
- Detection confidence and any uncertainty or blockers.
- Running state, anticipated closure requirements, and required privileges.
- Last update attempt, verification result, and relevant cleanup result.

Actions: **Update**, **Open Updater**, **Open App Store**, **Open Official Page**, **Reveal in Finder**, **Skip This Version**, **Ignore App**, and **View Logs**, shown only when applicable.

### 6.8 App Store Screen

Present store apps using the same underlying inventory, statuses, and queue as the unified view. Show a clear setup or account-resolution state when needed. Store updates must not create duplicate update jobs when also selected from the Updates screen.

### 6.9 Update Review and Progress

Before execution, show the selected apps, target releases, download sizes when known, required closures, permission requirements, and exclusions. Unknown sizes must remain labeled unknown.

During execution, show each task's state and an overall completed-app count. Offer **Cancel Remaining**; stop active work only at a safe point supported by the adapter. Never forcibly terminate a package manager during a critical installation phase merely to satisfy a cancel request.

If an app must close, offer **Quit and Update**, **Defer**, and **Cancel Remaining** as appropriate. Never force-quit an application automatically. Ask the user to save work when a closure is required.

### 6.10 Activity Screen

- Show active operations and timestamped scan/update/cleanup history.
- Show source failures separately from individual app failures.
- Provide concise error explanations, suggested next steps, and redacted technical details.
- Retry eligible failures after refreshing their prerequisites.
- Export a user-requested report, with logs included only by explicit choice.
- After restart, identify interrupted operations and inspect installed state before offering retry.

### 6.11 Cleanup Screen

- Group candidates by owning source or operation.
- Show artifact description, path in details, eligibility reason, and estimated reclaimable space.
- Distinguish automatic post-success cleanup from optional manual cleanup.
- Show actual removal results and failures separately from estimates.
- Explain when a manager controls cleanup and precise reclaimed bytes are unavailable.
- Never present failed-update artifacts as automatically safe to delete.

### 6.12 Sources and Settings

**Sources:** Enable/disable an adapter, inspect executable/version information, test connectivity, view compatibility status, refresh metadata, and open setup guidance.

**Settings:** Scan folders, exclusions, preferred release channels, ignored applications/releases, cleanup policy, history retention, and appearance. Scheduled checks, notifications, and menu bar behavior belong to later milestones.

Default behavior: stable channels, manual updates, no forced application closure, no source migration, no broad app-cache deletion, and no background installation.

### 6.13 Required Empty and Error States

Design explicit states for: first scan, scanning, no apps found, no eligible updates among checked apps, incomplete coverage, offline/stale results, unavailable sources, denied folder access, authentication required, unsupported app, ambiguous match, incompatible release, partial batch failure, interrupted operation, and cleanup failure.

The phrase **All apps are up to date** is allowed only when all in-scope, non-excluded apps were successfully checked and no eligible updates remain. Otherwise report the checked subset and unchecked count.

## 7. Discovery, Identity, and Matching

### Inventory rules

- Scan configured application roots; avoid blindly traversing the entire disk.
- Treat `.app` bundles as units and avoid listing embedded helpers as independent top-level apps by default.
- Exclude system application locations from update operations in the first release.
- Handle inaccessible folders as partial failures.
- Resolve aliases/symlinks carefully and prevent duplicate discovery and recursive loops.
- Read app metadata without launching discovered executables.
- Keep multiple installed copies distinguishable by canonical location and identity.

### Matching rules

Use available evidence: bundle ID, canonical path, package-manager records, App Store identity, code-signing identity, and adapter-specific mappings. Names are supporting evidence only.

An app may have multiple catalog matches but only one selected installation route. Prefer the existing owner when known. Ambiguous ownership must block automatic replacement until resolved. Never replace an App Store edition with a direct-download edition merely because their names match.

### Version and compatibility rules

- Keep both display version and build version.
- Use source-specific comparison rules; do not assume every app uses semantic versioning.
- Compare within the same product edition and release channel.
- Check available macOS and architecture requirements before planning an update.
- Classify unknown or incomparable versions explicitly.
- Do not downgrade when the installed release is newer than a source catalog entry.
- A newer release that cannot run on the machine is an incompatible release, not an eligible update.

## 8. State Model

Store separate dimensions instead of forcing every condition into one status field.

| Dimension | Values |
| --- | --- |
| Check state | Never checked, checking, checked, stale, failed, unsupported |
| Release result | Current, update available, newer incompatible release, unknown, installed newer than catalog |
| Install capability | Automatic, manual handoff, detection only, unsupported |
| Blockers | App running, authentication, permission, source missing, ambiguous identity, compatibility unknown, operation conflict |
| User policy | Included, app ignored, release skipped, channel preference |
| Task state | Queued, preflight, downloading, installing, waiting for user, verifying, succeeded, failed, deferred, canceled, interrupted |
| Cleanup state | Not eligible, pending, complete, partial failure, retained |

A verified update can succeed while cleanup fails. A command can complete while verification remains unresolved. The UI and history must preserve both distinctions.

## 9. Update Execution Contract

1. Refresh or validate the selected source result.
2. Confirm the application instance still exists at the expected location.
3. Revalidate ownership, target release, channel, compatibility, and current installed version.
4. Inspect source locks, running-app requirements, privileges, disk space, and connectivity where measurable.
5. Produce a concrete plan with known related changes and unresolved prerequisites.
6. Obtain the required user actions through the review screen and supported OS prompts.
7. Execute through the selected adapter with bounded concurrency and exclusive mutation per source installation.
8. Stream supported progress; retain diagnostic output without exposing credentials.
9. Re-read installed metadata using fresh inventory data, including manager/store state when relevant.
10. Record verified success, explicit failure, or unresolved verification with a useful explanation.
11. Clean eligible update artifacts only after the corresponding update is verified and no active operation needs them.

Independent tasks may continue after one failure. Preserve manager dependencies and avoid concurrent operations against the same app instance. Stop queue expansion if a newly discovered conflict makes the remaining plan unsafe or invalid.

Do not promise universal atomic updates or rollback. Third-party installers may perform partial changes. Preserve available recovery information and explain the supported recovery route for the particular source.

## 10. Cleanup Policy

### Eligible by default

- Completed download artifacts owned by this app and no longer referenced by active tasks.
- Temporary extraction directories owned by a verified, completed operation.
- Obsolete package-manager update artifacts removed through a supported, understood manager cleanup operation.

### Excluded by default

- Documents, preferences, licenses, databases, credentials, and application support data.
- Arbitrary contents of application cache directories.
- Unknown/shared paths or files still in use.
- Files retained for an unresolved failure or an explicitly supported recovery workflow.
- Old package environments or dependency versions whose removal changes recovery options without a separately reviewed policy.

### Implementation requirements

- Every cleanup candidate records its owner, canonical path, reason, retention rule, and active references.
- Restrict deletion to approved roots and reject path traversal, unsafe symlink targets, and broad wildcard deletion.
- Revalidate path and ownership immediately before deletion.
- Treat a cleanup failure as separate from the already verified update outcome.
- Estimate space conservatively and avoid double-counting shared files.
- Never use Homebrew `zap` as routine post-update cleanup; its purpose is more complete application removal and it may affect associated/shared files. See the [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook).

## 11. Proposed Architecture

The recommended starting point is a native Swift/SwiftUI application with a UI-independent core. This is a proposed implementation direction, not a completed technology decision. Minimum macOS version and distribution requirements must be confirmed during feasibility work.

```text
SwiftUI Screens and View Models
              |
Application Services
  ScanCoordinator | UpdatePlanner | UpdateQueue | CleanupService
              |
Domain Models and Source Resolution
              |
Source Adapter Interface
  Homebrew | App Store / mas | Sparkle | Vendor / Future Managers
              |
macOS Integration and Local Storage
  Bundle metadata | Processes | Files | OS authorization | History
```

### Responsibilities

| Module | Responsibility |
| --- | --- |
| AppInventory | Discover and inspect application instances |
| SourceRegistry | Detect adapters, capabilities, and source installation contexts |
| IdentityResolver | Match apps to sources and select one supported route |
| ScanCoordinator | Run checks, merge partial results, and report coverage |
| UpdatePlanner | Create and revalidate the reviewed operation plan |
| UpdateQueue | Schedule tasks, respect locks, and manage cancellation |
| UpdateVerifier | Inspect the actual installed result |
| CleanupService | Identify and remove eligible artifacts |
| ProcessRunner | Run supported executables with argument arrays and stream output |
| AuthorizationService | Request supported OS privileges only when necessary |
| HistoryStore | Persist operation state, outcomes, and sanitized diagnostics |
| SettingsStore | Persist scan roots, exclusions, channels, and policies |

Prefer existing, maintained APIs and manager interfaces. Add privileged components only when a demonstrated installation path requires them. Establish signing, notarization, sandbox implications, and distribution feasibility before committing to a public release route.

## 12. Core Data Models

| Model | Essential information |
| --- | --- |
| ApplicationInstance | Internal ID, bundle ID, canonical path, name, versions, architecture, identity evidence, running state |
| SourceInstallation | Adapter ID, executable/context, version, availability, capabilities, health |
| SourceMatch | App instance, source identity, package/store/feed ID, ownership evidence, confidence, limitations |
| UpdateCandidate | App instance, source match, target release/build, channel, compatibility, install capability, freshness |
| CheckResult | App instance, check state, release result, source evidence, checked time, errors |
| UpdatePlan | Explicit app scope, targets, related changes, prerequisites, exclusions, creation time |
| UpdateTask | Plan item, state, progress, timestamps, cancellation request, output references, result |
| VerificationResult | Observed installed state, expected target, evidence, verified/unresolved/failed outcome |
| CleanupArtifact | Owner, path, size estimate, eligibility reason, references, retention policy |
| OperationRecord | Scan/update/cleanup history, per-app outcomes, source errors, actual or unknown reclaimed bytes |
| UserPreferences | Scan locations, exclusions, source settings, ignored apps/releases, channel and cleanup policies |

Persist application and source identities without assuming a bundle ID is globally unique across installed copies. Store timestamps consistently and display them in the user's locale/time zone.

## 13. Functional API Catalog

The names below describe intended responsibilities. They are not implemented APIs, and final signatures may change. Services should return typed results and structured errors rather than presentation strings or unparsed command output.

### Application inventory

| Function | Expected behavior |
| --- | --- |
| `discoverApplications(scanRoots)` | Enumerate supported top-level app bundles and report inaccessible roots |
| `readApplicationMetadata(path)` | Read identity, versions, architecture, and useful update metadata |
| `canonicalizeApplicationPath(path)` | Normalize location safely and detect duplicate references |
| `getRunningState(application)` | Determine running processes associated with this app instance |
| `refreshApplication(applicationID)` | Reinspect one instance after an update or external change |

### Sources and discovery orchestration

| Function | Expected behavior |
| --- | --- |
| `detectSourceInstallations()` | Find available integrations and their installation contexts |
| `getSourceCapabilities(sourceID)` | Report check/install/verify/cleanup/manual-handoff support |
| `validateSource(sourceID)` | Check availability, supported version, and necessary access |
| `refreshSourceMetadata(sourceID)` | Refresh source metadata with timeout and freshness tracking |
| `matchApplication(application, sources)` | Return evidence-backed source matches and ambiguities |
| `resolveUpdateRoute(application, matches, policy)` | Select an allowed route or return an explicit blocker |
| `scanForUpdates(scope)` | Coordinate inventory, checks, deduplication, and partial results |
| `cancelScan(scanID)` | Stop new check work and safely finish/cancel supported requests |
| `calculateCoverage(scanResult)` | Count successfully checked, unknown, excluded, and failed apps |

### Adapter contract

| Function | Expected behavior |
| --- | --- |
| `listManagedApplications(context)` | Return source-owned inventory when the source has one |
| `checkForUpdate(application, match)` | Return source-specific release evidence and compatibility |
| `compareVersions(installed, candidate)` | Apply the source's release/build comparison semantics |
| `prepareUpdate(candidate)` | Describe actions, prerequisites, known side effects, and locks |
| `performUpdate(preparedTask, progressSink)` | Run only the prepared operation and emit supported progress |
| `verifyUpdate(task)` | Return fresh evidence of the installed result |
| `getManualUpdateAction(application)` | Return a validated supported handoff, if available |
| `listCleanupArtifacts(operation)` | Identify artifacts and ownership/retention constraints |

Adapters may declare an operation unsupported. Detection-only adapters must not provide a misleading installation action. Source-specific operations require typed capability checks before invocation.

### Planning and execution

| Function | Expected behavior |
| --- | --- |
| `buildUpdatePlan(selection)` | Produce explicit targets, prerequisites, exclusions, and known related changes |
| `revalidateUpdatePlan(planID)` | Detect stale candidates, changed versions, ownership changes, and conflicts |
| `enqueueUpdatePlan(planID)` | Persist and start reviewed tasks without duplicate app jobs |
| `requestApplicationQuit(applicationID)` | Request a normal quit and wait for an observable result |
| `deferTask(taskID)` | Leave the app unchanged by this task and continue independent work |
| `cancelRemaining(planID)` | Cancel queued work and request safe cancellation for active work |
| `retryFailedTask(taskID)` | Refresh prerequisites and create a new traceable attempt |
| `recoverInterruptedOperations()` | Inspect installed/source state before deciding how to resume |

### Cleanup, history, and user preferences

| Function | Expected behavior |
| --- | --- |
| `buildCleanupPlan(operationIDs)` | Identify eligible owned artifacts and conservative size estimates |
| `validateCleanupArtifact(artifactID)` | Recheck path, ownership, references, and policy immediately before removal |
| `executeCleanup(planID)` | Remove only valid candidates and record individual outcomes |
| `recordOperationResult(result)` | Persist scan/update/verification/cleanup results independently |
| `exportReport(scope, includeLogs)` | Export chosen records with sensitive data redacted |
| `setApplicationIgnored(applicationID, ignored)` | Exclude/include an app without losing its inventory record |
| `skipRelease(applicationID, releaseIdentity)` | Skip one source/channel-specific release |
| `setScanLocations(locations)` | Validate and save application scan roots |
| `setSourceEnabled(sourceID, enabled)` | Change source usage without uninstalling dependencies |
| `setCleanupPolicy(policy)` | Configure eligible artifact retention and post-success cleanup |

## 14. Security, Privacy, and Reliability

- Keep inventory, settings, and operation history local by default.
- Explain that remote checks contact the selected update sources and may disclose lookup identifiers to them.
- Do not upload a full installed-app inventory to a separate service by default.
- Never store Apple Account passwords or scrape credentials from other apps.
- Run external tools with validated executable paths and argument arrays, avoiding shell interpolation.
- Treat remote feeds, release notes, filenames, and process output as untrusted input.
- Validate update origins and preserve each source's integrity/signature checks.
- Do not execute scripts taken from an update feed or release-note page.
- Request elevated privileges only for operations that require them through a supported authorization path.
- Sanitize logs and reports; avoid access tokens, private feed query strings, and credential-bearing URLs.
- Keep the UI responsive while scanning, downloading, and waiting on external tools.
- Use timeouts for checks and clearly distinguish timeout, cancellation, network failure, and unsupported behavior.
- Persist in-flight operation state so crashes/restarts do not trigger blind reinstallation or cleanup.

## 15. Testing and Acceptance Criteria

### Automated tests

- Metadata parsing: missing fields, malformed bundles, display/build versions, duplicate copies.
- Identity resolution: identical names, App Store/direct editions, conflicting evidence, multiple owners.
- Version comparison: build-only updates, non-semantic versions, incomparable versions, installed newer than catalog.
- Compatibility: unsupported macOS/architecture, unknown requirements, stable/beta separation.
- Adapter parsing: saved fixtures for supported tool versions and invalid/partial output.
- Scan aggregation: partial source failures, stale data, cancellation, deduplicated coverage counts.
- Queue behavior: per-source locks, duplicate requests, deferred apps, partial failures, safe cancellation.
- Verification: command success with unchanged version, delayed metadata, unexpected installed release.
- Cleanup: failed verification, shared artifacts, symlinks, path traversal, in-use files, unknown sizes.
- Recovery: interrupted installs, external updates during a session, app moved or removed before execution.

### Manual integration tests

Use controlled machines or disposable test environments. Establish the support matrix before testing real updates.

- Test Homebrew and `mas` separately, then together.
- Test missing sources, unsupported versions, denied access, unavailable accounts, offline operation, and network interruption.
- Test a running app, required authorization, an individual failure within a batch, and post-update cleanup failure.
- Test Apple Silicon and Intel behavior only where the release claims support.
- Test keyboard navigation, VoiceOver, long text, light/dark appearance, and window resizing.
- Confirm no credentials appear in exported reports or logs.

### First-release acceptance checklist

- [ ] The app scans configured application folders without launching discovered apps.
- [ ] Multiple installed copies remain distinguishable; multiple source matches do not duplicate one instance.
- [ ] Homebrew and App Store integrations expose explicit capability and health states.
- [ ] Missing dependencies produce useful setup states instead of crashing the app.
- [ ] Unknown/failed checks are never shown as up to date.
- [ ] Available updates show installed/target releases and the selected source.
- [ ] Update All has explicit, reviewable scope and excludes ignored/ineligible apps.
- [ ] Update Selected cannot silently include unrelated app updates.
- [ ] Authentication and required app closure have clear user flows.
- [ ] One failed task does not discard successful results or block independent work unnecessarily.
- [ ] Success is verified against fresh installed state.
- [ ] Cleanup cannot delete arbitrary app data and does not run after unresolved verification.
- [ ] Cleanup failures do not relabel verified updates as failed installations.
- [ ] Restart recovery inspects state before retrying interrupted work.
- [ ] History and export contain useful, sanitized results.

## 16. Implementation Roadmap

### Milestone 0 — Feasibility and Technical Decisions

- [ ] Finalize the product name and initial desktop-app-only scope.
- [ ] Select minimum macOS version and supported CPU architectures.
- [ ] Validate native UI/core choices against the team's skills and distribution needs.
- [ ] Prototype read-only inventory, Homebrew structured output, and `mas` lookups.
- [ ] Verify `mas` update/authentication behavior on the intended support matrix.
- [ ] Determine required privileges and whether any privileged helper is necessary.
- [ ] Validate code signing, notarization, sandbox constraints, and the intended distribution route.
- [ ] Document source versions and unsupported cases.

**Exit condition:** A documented, tested path exists for inventory plus at least one update through each first-release source, or any source limitations are explicitly reflected in the release scope.

### Milestone 1 — Inventory and Read-Only Scanning

- [ ] Build inventory and metadata models.
- [ ] Add configurable scan roots and partial-access reporting.
- [ ] Implement source detection and Homebrew/App Store adapters for checks.
- [ ] Add identity resolution, version rules, and source routing.
- [ ] Implement Updates, Installed Apps, App Store, Sources, and essential Settings screens.
- [ ] Add honest coverage counts, uncertainty states, and source freshness.
- [ ] Add parser/matching/aggregation tests.

**Exit condition:** Users receive a reliable unified update list without making installation changes.

### Milestone 2 — Reviewed Updates and Verification

- [ ] Implement explicit plans, preflight checks, locks, and queue persistence.
- [ ] Add individual, selected, and all-eligible update actions.
- [ ] Implement normal app closure, deferral, authentication handoff, and safe cancellation.
- [ ] Add source-specific execution and fresh verification.
- [ ] Implement Activity, failure details, retry, and restart recovery.
- [ ] Test complete and partial update batches.

**Exit condition:** Supported updates complete with verified, inspectable per-app results.

### Milestone 3 — Cleanup and First Release

- [ ] Implement owned-artifact tracking and cleanup policies.
- [ ] Add post-success cleanup and the Cleanup screen.
- [ ] Report estimates, observed removals, unknown sizes, and cleanup failures accurately.
- [ ] Add ignored apps/releases, report export, and history retention.
- [ ] Complete accessibility and supported-platform testing.
- [ ] Finalize packaging, signing, distribution instructions, and user documentation.

**Exit condition:** All first-release acceptance criteria pass on the declared support matrix.

### Milestone 4 — Broader Application Coverage

- [ ] Add Sparkle feed discovery and detection-only checks.
- [ ] Implement supported installation cases only after independent validation.
- [ ] Add selected vendor integrations based on measured unsupported-app demand.
- [ ] Add explicit adoption previews for supported unmanaged apps.
- [ ] Add scheduled checks, optional notifications, and menu bar status.

### Milestone 5 — Optional Developer Tools

- [ ] Evaluate additional managers by incremental coverage and maintenance cost.
- [ ] Define separate inventory, environment, permissions, and cleanup models for developer tools.
- [ ] Keep project-local packages outside global updates unless explicitly added to scope.
- [ ] Add adapters one at a time with their own capability declarations and tests.

## 17. Definition of Done

The first release is complete when a user can discover their desktop apps, see trustworthy Homebrew and App Store update results, update eligible apps through a reviewed queue, inspect verified outcomes, and clean eligible update artifacts without losing application data.

Unsupported apps, unavailable sources, manual actions, and uncertain checks must remain visible. Universal application coverage is a long-term direction, not a release guarantee.

## 18. Open Decisions

- Final product name and visual identity.
- Minimum macOS version, architecture support, and distribution channel.
- Exact tested versions of external tools and the dependency setup experience.
- Whether any source requires a privileged helper.
- History and download retention defaults.
- Which vendor/Sparkle cases provide the most useful next increase in coverage.
- Whether the reusable core will eventually support a CLI in addition to the desktop UI.

These decisions do not change the initial focus: a native desktop experience for application updates, with developer package ecosystems reserved for a separate later expansion.

## 19. Official References

- [Homebrew manual: commands, casks, upgrades, adoption, and cleanup](https://docs.brew.sh/Manpage)
- [Homebrew Cask Cookbook: application definitions and removal behavior](https://docs.brew.sh/Cask-Cookbook)
- [mas: Mac App Store CLI, update commands, requirements, and detection limitations](https://github.com/mas-cli/mas/blob/main/README.md)
- [Sparkle: update feeds, signatures, compatibility, and installation mechanisms](https://sparkle-project.org/documentation/)

Recheck these upstream documents when implementing each adapter. Tool behavior and macOS integration requirements can change independently of this specification.
