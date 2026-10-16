# Maccet — Application Redesign

**Design specification · 01 · 16 October 2026**

**Baseline:** the current 0.1.2 alpha. **Stage:** design planning, before UI implementation.

<img src="assets/branding/maccet-icon.png" width="112" alt="Maccet app icon: rounded navy M with an orange update dot on a white tile.">

This document defines the next visual design of **the Maccet macOS application**: its name, logo treatment, colors, layout, screens, sheets, and system dialogs. It is the reference for the redesign work. Descriptions below are proposed UI decisions, not claims that the new interface already exists.

## 1. The direction

Maccet should feel like a small, carefully made Mac utility: easy to leave open, easy to read at a glance, and clear about what will happen when you press a button.

The identity comes from the existing logo. Deep navy gives the interface its structure. Orange marks the next useful action and an update that needs attention. Rounded corners echo the M without turning every control into a capsule. App icons, names, and versions carry the content; decoration stays around the edges.

The recognizable composition is a **navy sidebar beside a warm, quiet workspace**, with a single orange primary action. Light and dark appearances share that structure. Screens should look related even when their content changes from an app table to setup steps or history.

### Decisions that guide every screen

- **One clear next action.** Checking, reviewing, installing, and verifying must look like different stages.
- **Coverage is visible.** “No updates found” needs the context of how many apps were checked.
- **Names before identifiers.** The application name and icon lead; paths and package IDs belong in details.
- **A useful amount of space.** Room between groups, compact rows within a group.
- **Progress describes actual work.** Show the current stage; show a percentage only when measured data supports it.
- **Mac conventions remain familiar.** Native window controls, menus, sheets, keyboard focus, and authorization dialogs.

## 2. Name, wordmark, and logo

### Product name

| Surface | Required wording |
| --- | --- |
| Product name | **Maccet** |
| Main window title | **Maccet** |
| Application menu | **Maccet** |
| About menu item / panel title | **About Maccet** |
| Visible app bundle / Dock name | **Maccet.app** / **Maccet** |
| Sidebar wordmark | **Maccet** |
| Main tagline | **Your Mac updates, together.** |
| About panel supporting line | **A little less to keep up with.** |
| Report default filename | **maccet-report.json** |

Use the capitalization above consistently. `Maccet-personal` is the repository name, not an interface label. The first redesign pass changes user-facing names; internal Swift target names, the bundle identifier, stored-data paths, and existing user history need a separate migration decision before they are renamed.

### Existing artwork

| Asset | Role |
| --- | --- |
| [maccet-mark.png](assets/branding/maccet-mark.png) | Transparent navy M and orange dot; for light backgrounds. |
| [maccet-icon.png](assets/branding/maccet-icon.png) | White macOS tile containing the mark; used in the sidebar, About panel, and setup screen. |
| `assets/branding/Maccet.icns` | Existing native icon package; retained for application packaging. |

Keep the existing M silhouette, proportions, rounded terminals, and the clear gap around the orange circle. The dot belongs to the logo; it is always present and must not be used as a live unread badge.

**Placement rules**

- Sidebar icon: 36 × 36 pt, followed by the wordmark. Setup: 64 × 64 pt. About: 96 × 96 pt.
- Keep clear space of at least one orange-dot diameter around a standalone mark.
- Use the white-tile app icon on the navy sidebar and dark surfaces. The navy transparent mark needs a light surface.
- The wordmark uses SF Pro, semibold, with its normal spacing. Do not redraw the M as a font character.
- Preserve the app icon's existing white tile. Do not add a second white container, colored glow, or drop shadow to it.
- Navigation icons and empty-state symbols use SF Symbols, not repeated copies of the logo.

## 3. Color system

The brand anchors are **Maccet Navy `#032A43`** and **Maccet Orange `#FF6A00`**. The remaining colors are interface companions chosen for surfaces, legibility, and state.

### Surfaces and text

| Token | Light appearance | Dark appearance | Use |
| --- | --- | --- | --- |
| `brand.navy` | `#032A43` | `#032A43` | Brand artwork and identity |
| `brand.orange` | `#FF6A00` | `#FF6A00` | Primary button fill and update accent |
| `window.background` | `#F5F4F0` | `#0C1620` | Workspace behind content |
| `surface.primary` | `#FFFFFF` | `#111F2B` | Tables, cards, sheets |
| `surface.secondary` | `#EEEFEA` | `#182A38` | Grouped areas and inset controls |
| `sidebar.background` | `#032A43` | `#071B2A` | Sidebar fill |
| `sidebar.selected` | `#193B52` | `#17364B` | Selected navigation row |
| `sidebar.text` | `#F8FAFC` | `#F8FAFC` | Sidebar labels and wordmark |
| `sidebar.secondary` | `#A8B9C6` | `#A8B9C6` | Group labels, tagline, version |
| `text.primary` | `#102B3D` | `#EEF4F7` | Titles and primary values |
| `text.secondary` | `#576A78` | `#A7B8C5` | Supporting text |
| `text.tertiary` | `#617481` | `#8FA5B5` | Dates and metadata |
| `border.subtle` | `#DDE3E6` | `#2C4050` | Dividers and card edges |
| `selection.background` | `#E8EEF2` | `#193B52` | Selected app rows |
| `accent.text` | `#B54708` | `#FF9B57` | Small orange-related labels and links |
| `accent.soft` | `#FFF1E6` | `#33261F` | Ready-to-update summary and badges |
| `focus.ring` | `#B54708` | `#FF9B57` | Keyboard focus outline |

### Status colors

| Meaning | Light text / background | Dark text / background | Symbol |
| --- | --- | --- | --- |
| Update available | `#B54708` / `#FFF1E6` | `#FFB27A` / `#33261F` | `arrow.up.circle` |
| Verified / current | `#1E654A` / `#EAF5EE` | `#87D9B1` / `#16362C` | `checkmark.circle` |
| Needs attention | `#82500A` / `#FFF4D9` | `#F5D084` / `#392F1C` | `exclamationmark.triangle` |
| Failed / interrupted | `#AA3038` / `#FCEDEE` | `#FFADB3` / `#3B222B` | `exclamationmark.circle` |
| Not checked / deferred | `#576A78` / `#EEF1F3` | `#B5C4CE` / `#223340` | `minus.circle` |
| Managed by macOS | `#375A77` / `#EAF0F7` | `#B0CDE7` / `#1D3246` | `lock.shield` |

Colors always accompany a label or symbol. Green means a verified result or current source result, not “the button you should press.” Orange identifies the product and update action; failures use red and manual attention uses amber.

**Primary button:** navy text on orange. White on `#FF6A00` gives approximately 2.87:1 contrast; navy on the same fill gives approximately 5.16:1. Small orange text uses `accent.text`, not the raw brand orange. Target at least 4.5:1 for normal text and 3:1 for essential control boundaries. Recheck the final composite colors if material or opacity changes are introduced.

## 4. Typography, spacing, and materials

### Type

Use system fonts so text follows macOS rendering and accessibility preferences.

| Role | Font | Baseline size / line height |
| --- | --- | --- |
| Page title | SF Pro Display, semibold | 28 / 34 pt |
| Sheet title | SF Pro Display, semibold | 23 / 29 pt |
| Sidebar wordmark | SF Pro, semibold | 20 / 25 pt |
| Summary value | SF Pro Rounded, semibold | 30 / 36 pt |
| Section heading | SF Pro, semibold | 15 / 21 pt |
| App name and main body | SF Pro, medium / regular | 13 / 19 pt |
| Supporting copy | SF Pro, regular | 12 / 18 pt |
| Group label / metadata | SF Pro, medium / regular | 11 / 16 pt |
| Versions and diagnostic values | SF Mono, regular | 11–12 / 17 pt |

Use sentence case for titles and buttons. Small uppercase labels are reserved for sidebar groups and table headers. Long application names truncate in rows and appear in full in Details and accessibility labels. Versions use monospaced digits; titles do not.

### Geometry

- Spacing scale: **4, 8, 12, 16, 24, 32, 40 pt**.
- Main page padding: **28 pt**. Gaps between page sections: **24 pt**. Card padding: **20 pt**.
- Card radius: **14 pt**. List container: **12 pt**. Buttons and fields: **8 pt**. Status badges: **6 pt**. A count badge may be a capsule.
- Standard button height: **32 pt**; compact row action: **26 pt**. Search field: **32 pt**, around **280 pt** wide.
- Cards use a 1 pt border. Avoid a shadow around every group. Sheets use macOS's own elevation.
- The sidebar has a controlled solid fill. The toolbar and native sheets may use system materials, with a solid-surface fallback when Reduce Transparency is enabled.

### Motion

Hover changes the background quietly. Row selection and disclosure animate over roughly **120–160 ms**; stage changes over **180–220 ms**. There is no looping logo animation, confetti, or pulsing update dot. Under Reduce Motion, use immediate state changes and keep native activity indicators where work is ongoing.

## 5. Main application window

**Title:** Maccet. **Initial size:** 1240 × 800 pt. **Minimum:** 1080 × 720 pt.

Keep a native macOS title bar and traffic-light controls. Below it, the window has a sidebar, the current page, and a narrow persistent status strip. The content header carries the page title and its actions; the window title does not need another oversized logo.

```text
┌──────────────────────────────────────────────────────────────────────────┐
│  ● ● ●                           Maccet                                   │
├─────────────────┬────────────────────────────────────────────────────────┤
│ [icon] Maccet   │ Updates                 [Check for Updates] [Update All]│
│                 │ One place for the updates your sources can find.       │
│ LIBRARY         ├────────────────────────────────────────────────────────┤
│ • Updates    3  │ [Applications]       [Ready to update]       [Checked]  │
│   Installed Apps│                                                        │
│   App Store     │ [Search applications] [All sources ▾]  [Show ignored]  │
│                 │ ┌────────────────────────────────────────────────────┐ │
│ MANAGE          │ │ App           Version        Source   Status/Action │ │
│   Activity      │ │ …                                                    │
│   Cleanup       │ └────────────────────────────────────────────────────┘ │
│   Sources       │                                                        │
│   Settings      │ [3 selected] [Clear]                 [Update Selected] │
│                 ├────────────────────────────────────────────────────────┤
│ Local to this Mac│ Checked 18 of 25 third-party apps · 3 ready            │
│ 0.1.2 · Alpha   │                                      Last checked …    │
└─────────────────┴────────────────────────────────────────────────────────┘
```

Counts above are illustrative layout content, never hard-coded statistics.

### Sidebar

Width **232 pt**, adjustable from **220 to 270 pt**. Top identity block: 36 pt app icon, Maccet wordmark, and the short line “Your Mac updates, together.” The tagline may wrap to two lines.

Two groups preserve the existing navigation:

| Group | Item | SF Symbol | Badge |
| --- | --- | --- | --- |
| Library | Updates | `arrow.triangle.2.circlepath` | Eligible update count only; hidden at zero |
| Library | Installed Apps | `square.grid.2x2` | None |
| Library | App Store | `app.badge` | None |
| Manage | Activity | `clock.arrow.circlepath` | None |
| Manage | Cleanup | `sparkles` | None |
| Manage | Sources | `externaldrive.connected.to.line.below` | Small attention symbol only when setup needs attention |
| Manage | Settings | `slider.horizontal.3` | None |

Navigation rows are 36 pt high, with 10 pt corners and 12 pt horizontal inset. The selected row uses `sidebar.selected`, a 3 × 18 pt orange leading marker, and bright text. Unselected symbols are subdued; the entire row remains clickable. Bottom metadata reads “Local to this Mac” and “0.1.2 · Alpha.”

### Header and status strip

Page title at upper left, a one-line explanation beneath it. Actions align to the upper right, with one orange action at most. On update pages, **Check for Updates** is secondary and **Update All (N)** is primary. When no eligible apps exist, omit the count and disable Update All with an accessible reason.

The status strip is approximately 32 pt high, with a spinner only during work, a short stage description, and last-check information. Important failures also appear beside their affected content; the strip must not be the only place to discover an error. Long diagnostics open through a disclosure in the relevant screen.

At minimum width, reduce flexible gaps before shrinking text. Names take the remaining row width. Paths and previews wrap. Oversized diagnostic content scrolls inside its own disclosure rather than widening the window.

## 6. Screen specifications

### 6.1 Updates

**Purpose:** decide which eligible applications to update and understand what needs intervention.

**Header:** “Updates” / “One place for the updates your sources can find.”

At the top, three equal summary cards, approximately **104 pt** high:

| Card | Main value | Supporting text | Treatment |
| --- | --- | --- | --- |
| Applications | Discovered app count | “In your scan folders” | Neutral surface |
| Ready to update | Eligible app count | “Ready for review” | Soft orange surface and dark-orange value |
| Checked | Checked third-party / discovered third-party | Separate count “N updated with macOS” | Neutral surface; actual coverage is explicit |

Below them, show a compact amber banner only when source checks or setup are incomplete. Its action, **View Sources**, opens the source explanation.

The next row contains search, source picker, Show ignored, and the result count. The list sits inside one bordered surface. Table headings stay visible while rows scroll.

**App row anatomy:** selection checkbox → 36 pt application icon → name and secondary identifier → installed and target versions → source label → textual status and action. Baseline row height **76 pt**, with enough vertical expansion for larger text. Versions remain aligned; an orange arrow points from installed to target. Use a small badge for “Update available,” not a fully orange row.

Eligible rows offer **Review Update**. Conflicting routes offer **Choose Manager**. Manual cases offer the existing source handoff where available. An ineligible checkbox is disabled with its reason exposed to accessibility. Clicking the app name opens Details; clicking the checkbox only changes selection.

The selected-app bar stays above the bottom status strip and appears only when selection exists. It contains the count, **Clear**, and **Update Selected**. **Update All** continues to include all eligible apps, regardless of the current search filter; its help text makes that scope clear. A filter must not silently change the global action.

**States:**

- Before results: “Checking your sources…” with indeterminate progress; counts use a dash until known.
- Partial scan: show available rows and label the scan as ongoing. Mutation actions remain disabled.
- No updates: “No updates found in the checked apps.” Include the coverage count and **View Installed Apps**.
- No search matches: “No apps match this view.” Offer **Clear search**; keep filters visible.
- Ambiguous ownership: amber badge, **Choose Manager**, and no automatic update action.
- Failed source: retain usable results, with the source banner visible.

### 6.2 Installed Apps

**Purpose:** see what is installed, where it lives, and whether Maccet can check it.

**Header:** “Installed Apps” / “Your applications, their sources, and what we could check.” Primary header action: **Check for Updates**. No global install action on this page.

Reuse the summary cards, filters, and app-row geometry from Updates. The inventory includes unchecked and system-managed apps. Separate installed copies remain separate rows; show a short location hint when names repeat, with the full path in Details.

System-managed apps use the blue-gray **Updated with macOS** badge and no third-party install control. Apps with no verified route show **Not checked** and a brief reason in Details. A discovered Sparkle feed is metadata, not a supported update route.

When folders contain no readable apps, show a restrained folder symbol, “No applications found,” and **Open Settings**. For a system-only inventory, report zero third-party apps without dividing by zero or implying full third-party coverage.

### 6.3 App Store

**Purpose:** work with store apps without starting a separate queue or losing the rest of the library.

**Header:** “App Store” / “Store updates, alongside the rest of your apps.”

Use the same list design with receipt-backed store inventory. Replace the source picker with a static **App Store · via mas** label. Keep search and Show ignored. Summary values are scoped to the store view and must be computed from its inventory; label them “Store apps,” “Ready to update,” and “Checked store apps.”

**Update All (N)** is scoped to eligible store apps. Opening review uses the same review sheet as Updates. A store failure shows a concise inline explanation and **Open App Store** where the existing handoff is available.

If no store apps are identified, show “No App Store apps found in these folders.” If store apps exist but the source fails, show the source failure instead of an empty-library message. Authentication remains a system interaction.

### 6.4 Activity

**Purpose:** follow the running queue and read the outcome of past attempts.

**Header:** “Activity” / “Every attempt, with its outcome.” Secondary action: **Export Report…**.

When a queue is running, place a **Current update** card above history. It shows the application icon, name, version transition, source, and current stage. Stages use a simple sequence: **Queued → Checking → Installing → Verifying → Result**. Only report a queue count or stage the app actually knows; do not invent download progress.

History is a vertically grouped list. Each record shows app name, version transition, state badge, source, time, and a short result. A disclosure reveals the full captured message, app path, and cleanup outcome. It does not imply access to logs the core has not retained.

| State | Visual treatment | Action |
| --- | --- | --- |
| Queued / checking / installing / verifying | Neutral stage label and progress indicator for active work | Cancel Remaining at queue level |
| Succeeded | Green **Verified** badge | Inspect details |
| Failed | Red **Failed** badge and readable reason | Rescan Before Retrying |
| Deferred | Neutral **Deferred** badge; explain the running app | Rescan Before Retrying |
| Interrupted | Red **Interrupted** badge; explain that the result needs checking | Rescan Before Retrying |
| Canceled | Neutral **Canceled** badge | Inspect details |

For a completed queue with mixed outcomes, show a neutral summary such as “2 verified · 1 needs attention.” One failed app must not make verified apps look failed. A verified app with a cleanup error keeps its verified installation badge and receives a separate cleanup warning.

Empty history: clock symbol, “Your update history starts here,” and “Completed and attempted updates will appear here.”

### 6.5 Cleanup

**Purpose:** explain and control the existing per-attempt cleanup policy.

**Header:** “Cleanup” / “Finish the update. Leave less behind.” No large orange cleaning button.

The first card has a modest `sparkles` symbol, “Cleanup after verification,” and the policy toggle **Remove update downloads after successful verification**. Supporting copy explains that this applies to isolated Homebrew update downloads.

Under **Cleanup results**, show rows with app, date, result, and the recorded explanation. Distinguish **Removed**, **Retained**, and **Cleanup needs attention** only when the underlying record supports that wording. Preserve any more specific captured message.

Use green for confirmed removal, neutral for deliberately retained files, and amber for cleanup failures. Do not display gigabytes saved, a disk scan, shared-cache deletion, or an Uninstall action. No cleanup history: “No cleanup results yet. Results appear after update attempts.”

### 6.6 Sources

**Purpose:** see which tools are usable and resolve setup or checking problems.

**Header:** “Sources” / “Know where every update comes from.”

The page begins with a setup summary: latest preparation state and **Retry Setup** or **Prepare Sources Again**. The expanded summary uses the same step component as the startup screen.

Below it, use three full-width source cards in a vertical stack: **Homebrew**, **MacPorts**, and **App Store via mas**. A card contains:

1. Source symbol, name, version when known, and a textual state badge.
2. The current health message; any failed step gets a visible reason.
3. A disclosure for executable path and longer diagnostics.
4. **Use this source for app checks** and **Setup & documentation ↗**.

Do not invent distinct manager brand colors. All cards use Maccet surfaces and semantic state colors. A working source is green only in its status indicator, not as a full green panel.

A persistent short explanation below the switches reads: **“These switches control app checks. Source tools are still prepared when Maccet opens.”** This distinction must remain visible without expanding diagnostics.

When a source is disabled, label it **Checks disabled**; do not call it missing. A missing tool, failed maintenance, disabled checking, and successful checking are different conditions and may need separate labels on one card. MacPorts results identify that checks use its local index. Setup and check health must not overwrite one another visually.

### 6.7 Settings

**Purpose:** adjust existing scan behavior and exclusions without becoming a second dashboard.

**Header:** “Settings” / “Make update checks work for you.”

Use a scrolling column with a comfortable maximum width of **840 pt**, aligned with other page content. Group cards have short headings and native controls.

| Section | Design and behavior |
| --- | --- |
| Scan locations | Folder rows with a folder symbol, selectable path, and Remove action. **Add Folder…** opens the native folder picker. Include the existing system-app inventory toggle. Explain that changing folders requires a new scan. |
| Exclusions | Counts of ignored apps and skipped releases, a short explanation, and **Reset All Exclusions**. Disabled when nothing is excluded. |
| Privacy & behavior | Brief rows describing local history, source network access, reviewed updates, and normal quit behavior. Include the existing 1,000-record history limit. |

Follow the macOS appearance automatically in this redesign. There is no new theme selector, scheduling switch, telemetry switch, login control, or automatic application-update preference.

The exclusion reset is immediate, matching current behavior, and applies only to Maccet's ignore/skip preferences. Its supporting copy states the scope; do not style it like a destructive file-deletion command. App updates, installs, cleanup-policy edits, and source mutations stay disabled while conflicting work is busy.

## 7. Startup preparation screen

This is a temporary main-content state inside the Maccet window, shown on every GUI launch while sources prepare. It is not a first-run-only onboarding wizard or an extra standalone window.

Center a column up to **680 pt** wide in the workspace. Top: 64 pt app icon, **“Getting your update sources ready”**, and “Maccet prepares its source tools before checking your apps.”

Use a single surface containing the actual setup sequence:

| Step | Visual contents |
| --- | --- |
| Apple developer tools | Step title, system-installer explanation when required, current outcome |
| Homebrew | Installing, refreshing, ready, or failed message |
| MacPorts | Installing, refreshing, ready, or failed message |
| App Store helper / mas | Installing, updating, version requirement, or failed message |

Rows use a pending circle, an indeterminate spinner, a green check, or a red failure symbol, plus text. Keep a failed row visible while independent steps continue. There is no fake “80% complete” bar and no “Skip setup” action that bypasses an active installer.

Bottom copy: **“macOS may ask for administrator permission. Keep Maccet open until installers finish.”** Technical details sit in a disclosure. Apple tool installation and Intel Homebrew limitations explain the concrete next step, followed by **Retry Setup** when setup has stopped.

After setup ends, proceed into the automatic scan. If some sources failed, show available results and a persistent **Some update sources need attention** banner with **View Sources** and **Retry Setup**. The banner must not cover content or present failed setup as a completed app update.

## 8. Sheets and secondary windows

### 8.1 Review Updates sheet

**Default size:** 720 × 640 pt; resize vertically as needed within the parent window. Use a native attached sheet with a scrolling middle and a fixed footer.

Top: **Review updates**, followed by the actual included app count. Each app card contains its icon, name, installed → target release, selected source, and the source-provided operation preview. Start long previews collapsed under **Operation details**; required dependency changes and important warnings remain visible in the summary. If no structured summary exists, show the preview text rather than inventing one.

Below the app list:

- **Request a normal quit for running apps** toggle, off by default when opening a new review.
- Explanatory copy for deferral, unsaved work, and apps that refuse to quit.
- Current cleanup policy in one secondary line.
- A reminder that identity and target release will be checked again.

Fixed footer: **Cancel** on the left and orange **Start Updates** on the right. Escape cancels review. Starting updates is an explicit click or focused Space action; an incidental Return key must not launch installation. A changed or invalid plan requires a new review rather than silently replacing targets.

```text
┌──────────────────────────────────────────────────┐
│ Review updates                                   │
│ 3 apps included                                  │
│ ┌──────────────────────────────────────────────┐ │
│ │ [icon] Application       1.2 → 1.3            │ │
│ │ Homebrew                                     │ │
│ │ ▸ Operation details                          │ │
│ └──────────────────────────────────────────────┘ │
│ … scrollable app list …                          │
│ □ Request a normal quit for running apps         │
│ Running apps will otherwise be deferred.         │
│ Cleanup: isolated downloads after verification   │
├──────────────────────────────────────────────────┤
│ [Cancel]                         [Start Updates] │
└──────────────────────────────────────────────────┘
```

### 8.2 Application Details sheet

**Default size:** 760 × 620 pt, with a scrolling body for long paths and accessibility text.

Header: 56 pt app icon, full app name, bundle identifier, and a secondary **Done** button. The installed → target release comparison gets a quiet inset strip when a target exists.

Body sections:

| Section | Contents |
| --- | --- |
| Installation | Installed version, build, path, and Reveal in Finder |
| Update | Target release when established, current state, explanatory message |
| Source | Chosen source and package identity; available verified routes when there is a choice |

For multiple routes, show a native radio-choice group titled **Update using**. Each option contains the manager, target or check state, and the existing route explanation. Selection uses navy/neutral surfaces with a small orange indicator. Keep the rule **“Only the selected manager will update this copy.”** visible. No route is automatically chosen when ownership remains ambiguous. Receipt-backed App Store ownership cannot be overridden.

For a Sparkle feed, show the existing informational note that feed checking is not implemented. Do not show a checkmark for feed coverage.

Footer: **Reveal in Finder**, **Ignore App / Stop Ignoring**, and **Skip Release** when relevant; one trailing action, **Review Update** when eligible or **Open Source** when a supported handoff exists. Keep secondary actions visually quiet and allow them to wrap at larger text sizes. Escape closes the sheet.

### 8.3 About Maccet panel

Use the native About panel where possible, approximately **420 × 360 pt**. Show the 96 pt icon, **Maccet**, version and build read from the bundle, an **Alpha** label, and “A little less to keep up with.”

Do not add unsupported license, developer, website, or copyright details. Credits can be added only when supplied by the project owner. About is reached through **Maccet → About Maccet**, not a new sidebar item.

## 9. Dialogs and native panels

### Actionable error alert

Use a native alert attached to the relevant window. Replace a generic title when the context is known: **“Couldn’t export the report”**, **“The update plan changed”**, or **“Saved data couldn’t be read.”** State the concrete issue and the next action in one or two sentences. Keep a selectable detailed message in the relevant screen for longer diagnostics. **OK** dismisses the current generic error; add a retry only where an existing operation can be invoked deliberately.

### Quitting during an update

Native alert titled **“An update is still running”**. Explain that the active installation must finish. Buttons: **Keep Maccet Open** as the default, and **Cancel Remaining** as secondary. The latter requests queue cancellation; it does not claim to terminate the active installer. No Force Quit button.

### Quitting during source preparation

Native alert titled **“Sources are still being prepared”**. Explain that installers must finish and authorization may be canceled in the system dialog. Offer **Keep Maccet Open**. Do not offer a cancellation action unsupported by the preparation process.

### Folder picker

Keep `NSOpenPanel`: directories only, multiple selection allowed. Title **Choose application folders**, confirmation **Add Folders**. Supporting text explains system apps are updated through macOS. Native favorites, file navigation, appearance, and accessibility remain intact.

### Report save panel

Keep `NSSavePanel`: title **Export Maccet report**, default filename `maccet-report.json`, JSON file type, native **Save** and **Cancel**. No custom replacement file browser. If export fails, preserve the inventory and show an export-specific error.

### Administrator and Apple dialogs

macOS owns authorization, installer, and App Store account dialogs. Maccet gives context before they appear, then reports the outcome. The redesign adds no password fields, Apple Account form, replacement administrator dialog, or simulated permission screen.

## 10. Shared components and interaction rules

| Component | Design contract |
| --- | --- |
| Primary button | Orange fill, navy semibold label, 8 pt radius; stronger orange on hover, clear pressed state. Disabled uses a neutral fill and readable muted label. |
| Secondary button | Native bordered or quiet surface treatment; primary text, no competing orange fill. |
| Text action | `accent.text` or platform link treatment; clear focus and hover feedback. |
| Status badge | Small symbol plus wording, 6 pt corners, soft semantic background. Remains readable without color. |
| Search | Native magnifier, clear button, accessible name “Search applications”; preserve the typed query while results arrive. |
| Source picker | Native menu with All sources and the implemented sources. The source label is never inferred from a mere catalog match. |
| Table selection | Distinct row tint and checkbox state; hovering never looks selected. |
| Information banner | Symbol, short title, one explanation, relevant action. Expand vertically for long text. |
| Details disclosure | Native chevron, no card-within-card decoration. Paths and messages are selectable. |
| Empty state | One 40–48 pt symbol, short title, useful explanation, at most one relevant action. |
| Stage indicator | Pending, active, complete, failed states with text. Do not turn elapsed time into progress. |

### Accessibility and keyboard

All controls need meaningful accessible labels, including app selection, source switches, and attention badges. Decorative symbols and repeated app icons are hidden from accessibility. Row announcements include name, installed version, available target, source, and state.

Keep **⌘R** for Check for Updates and the standard macOS application shortcuts. Tab follows the visual order. Space activates the focused control. Escape dismisses cancellable sheets and panels. Never intercept a standard system shortcut for branding.

Use a 2 pt visible focus outline where custom controls need one. Text-size increases may grow rows and sheets rather than clip labels. Reduce Motion, Reduce Transparency, and Increase Contrast need explicit visual checks. Test long paths, long app names, unknown versions, and mixed outcomes in both appearances.

## 11. Behavior the redesign must preserve

The visual work keeps the current update model intact:

- Every installed copy retains its identity and path. App names alone do not establish ownership.
- One selected verified route executes an app's update; unresolved route conflicts block it.
- App Store receipt ownership remains protected. System apps are inventory-only.
- Application updates require a reviewed plan, followed by target and identity revalidation.
- Running apps are deferred or asked to quit normally; they are never force-quit.
- Cancel Remaining does not forcibly terminate an active installation.
- An update command finishing is followed by installed-version verification.
- Cleanup is limited to the isolated artifacts of a verified Homebrew attempt. Failed attempts retain their downloads.
- Source preparation still runs at each GUI launch; source-check switches do not disable that maintenance.
- Missing coverage remains visible. A failed check or unchecked app cannot become “up to date” through presentation.
- Restart recovery marks unfinished work Interrupted and requires a rescan; there is no automatic retry or recovery cleanup.

Cross-catalog adoption, new package managers, scheduling, notifications, global cleaning, rollback, and a menu-bar companion are outside this redesign. Their controls should not appear as decorative placeholders.

## 12. Implementation order and review checklist

This file is the planning deliverable. The application UI is implemented in a later step using the following order:

1. **Identity and foundation:** apply the Maccet visible name, logo rules, color tokens, typography, and light/dark surfaces. Preserve data paths and internal identifiers.
2. **Shared window:** sidebar, page header, status strip, buttons, badges, summary cards, and app rows.
3. **Inventory views:** Updates, Installed Apps, and App Store, including loading, empty, partial, ignored, and ownership-conflict states.
4. **Decision sheets:** Review Updates and Application Details, including a deliberate route choice and long previews.
5. **Supporting pages:** startup preparation, Sources, Activity, Cleanup, and Settings.
6. **Native surfaces:** About, error and quit alerts, folder picker, save panel, menu wording, and visible app-bundle name.
7. **Review:** all screens at initial and minimum window size, both appearances, keyboard navigation, larger text, and the existing behavior checks.

### Completion criteria

- [ ] Every user-facing product label uses Maccet; intentional technical legacy names stay documented.
- [ ] The original logo remains intact and readable on each surface.
- [ ] Navy and orange identify the app; status colors retain their own meanings.
- [ ] All seven navigation screens and the startup state follow this specification.
- [ ] Review, Details, About, alerts, folder selection, and report export are covered.
- [ ] Primary actions, selection, focus, disabled state, and busy state are visually distinct.
- [ ] Coverage, system-managed apps, conflicting ownership, and manual actions are explicit.
- [ ] No clipped paths, inaccessible labels, invented progress, fabricated counts, or unsupported controls.
- [ ] Verified updates and cleanup outcomes remain separate in mixed-result cases.
- [ ] The existing core behavior checks still pass after UI work.

## 13. Project reference

This specification was mapped to the current navigation and views in `Sources/UnifiedUpdater/Views.swift`, application state in `AppModel.swift`, the main window and quit alerts in `Main.swift`, current branding assets, and the app bundle metadata in `scripts/Info.plist`.

For current implemented behavior and limitations, see [README.md](README.md), [startup setup](docs/STARTUP_SETUP.md), and [validation](docs/VALIDATION.md). The [original product specification](docs/PRODUCT_SPEC.md) contains broader plans; it does not replace the current implementation as the behavior reference for this redesign.
