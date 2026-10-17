# Keyboard and accessibility follow-up — 18 October 2026

Scope: native smoke evidence and focused improvements for #36 on the combined branch in #62. This is not a complete VoiceOver or platform certification. The exercised machine is arm64/macOS 27.0.1 with Swift 6.4.

## Changes

- **Navigate** lists all seven pages with **Command-1 through Command-7**. Switching pages starts no update or source preparation.
- **Edit → Find Application (Command-F)** focuses application search. From a non-inventory page it opens Installed Apps; Updates/App Store retain their current search context. Escape clears the current query.
- Each summary card exposes one ordered accessibility label, such as “Checked: 0 of 6,” instead of letting unrelated labels/numbers merge into one sentence.
- Light tertiary text changes from `#617481` to `#5C6E7A`. Calculated sRGB contrast improves from 4.41:1 to 4.81:1 on the window background and from 4.20:1 to 4.58:1 on the secondary surface; the selection background is 4.52:1. The original dark tertiary pair remains 5.76:1 on its secondary surface. These are token-pair calculations, not a certification of every composite/control state.
- Settings explains optional Google/feed/catalog destinations and separately retained assisted history.

## Native evidence

Testing used six synthetic bundles, isolated application data and disabled manager/feed/vendor checks. No real installer, authorization request or source maintenance was run; global appearance/accessibility settings were not changed.

| Area | Exercised evidence | Limit |
| --- | --- | --- |
| Navigation | All seven Command-number actions selected the matching page in the native accessibility tree | No claim about every system Full Keyboard Access configuration |
| Search | Command-F moved from Activity to Installed Apps and focused the search field; a query filtered six apps to one; Escape restored six | Native text entry was exercised using paste; no input-method matrix |
| Summaries | Three separate ordered accessibility labels exposed application, eligible and checked counts | Accessibility-tree evidence, not spoken VoiceOver announcement certification |
| Details | Long app name/path visible and present in accessible labels; Escape dismissed | Additional release/adoption/assisted review states need broader manual coverage |
| Publisher sheet | Tab moved through fields, empty Return action exposed validation, Escape canceled without saving trust | No production publisher was configured |
| Native dialogs | About showed version/build and closed with Escape; folder chooser canceled without adding a root | Save/authorization/cancellation matrices remain incomplete |
| Activity/Cleanup | Mixed synthetic outcomes and expandable details retained complete explanations | Actual active installations remain covered by controlled orchestration, not this smoke run |

The combined nine UI orchestration checks and local release/resource gates pass with these changes. The earlier combined core/setup/release-workflow gates are recorded in the integration note. A real keyboard-only/VoiceOver/larger-text/high-contrast/reduced-motion/transparency/light-dark/minimum-window/stress-state matrix remains open under #36. OS/architecture and owner-signed distribution acceptance remain separate under #37/#38.
