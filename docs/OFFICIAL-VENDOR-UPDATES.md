# Official vendor-assisted updates: Chrome

This is the first constrained vendor family for #35. It adds a guided/manual route, not a generic vendor installer. Broader suite-manager/vendor families and real required-update acceptance remain separate work.

## Identity and channel

The supported bundle IDs are `com.google.Chrome`, `.beta`, `.dev` and `.canary`. A fresh strict signature check must satisfy the exact bundle identifier, Apple generic anchor, Developer ID intermediate/leaf certificate requirements and Google team `EQHXZ8M8AV`. Invalid, unsigned, ad-hoc and other-publisher applications cannot request the vendor API. Matching a name is insufficient. These pins follow [Chromium's updater branding](https://chromium.googlesource.com/chromium/src/+/main/chrome/updater/branding.gni) and [its documented Chrome Developer ID requirement](https://chromium.googlesource.com/chromium/src/+/13cec53b57158706ea3e057ba2d5a8aac2acc3c1/chrome/browser/safe_browsing/incident_reporting/binary_integrity_analyzer_mac.cc).

The user explicitly confirms `stable`, `extended`, `beta`, `dev` or `canary` from the installed copy's settings/administrator policy. Review binds to canonical path, bundle ID and a currently valid Apple-rooted publisher identity. The bundle name, suffix or `KSChannelID=universal` is not used to infer a release channel. [Google's Mac management documentation](https://support.google.com/chrome/a/answer/7591084?hl=en) explains that policies can change channels without a new bundle identity. Separate local copies retain separate reviews.

A bounded 4 KiB Mach-O header read establishes executable architectures without launching the application. The route uses `mac_arm64` when the host and installed binary support it, otherwise `mac` for an x86_64-capable binary. Unsupported formats/architectures fail conservatively. Executable symlinks resolving outside the bundle are rejected. The current baseline is macOS 13, per [Google's requirements](https://support.google.com/chrome/answer/95346), reviewed 18 October 2026; release-specific compatibility remains a vendor decision.

## Read-only metadata

Enable **Sources → Check supported vendor releases**. Store receipts, system apps and established manager routes take precedence. The first family requests a fixed Google VersionHistory URL for the reviewed channel/platform, filtering live releases with positive rollout fraction. It compares numeric four-component versions, ignores zero-fraction/ended/future records, checks returned resource identities and rejects malformed, oversized, excessive or paginated/incomplete results. The source is the [official VersionHistory API reference](https://developer.chrome.com/docs/web-platform/versionhistory/reference).

JSON requests share the bounded metadata transport: no redirects/HTTP authentication/cookies/cache, HTTPS/platform TLS, 512 KiB decoded data, 15-second request and 20-second resource timeouts. A scan processes at most eight recognized copies within a 30-second request-start budget; omitted copies stay unchecked. The application identity/installed metadata is read again after the response, so an application changed during checking requires a rescan. Vendor observations cannot grant automatic eligibility or manager ownership. They take precedence over generic embedded-feed observations for the supported vendor family.

A published-release observation is not a policy-aware update offer. Google can stagger rollouts, administrators can pin/disable updates and an individual release may change compatibility. Those conditions remain explicitly unobserved; the handoff asks the user to confirm them in Chrome. No downgrade or policy change is requested.

## Guided handoff and independent result

For a newer observed release, **Review Assisted Update** refreshes the official metadata and rejects a changed target/channel. The immutable review retains the exact application, target, platform and signing evidence. **Record Handoff and Open Instructions** persists a separate vendor-assisted record before opening the fixed [Google update instructions](https://support.google.com/chrome/answer/95414?co=GENIE.Platform%3DDesktop&hl=en). Maccet launches no vendor installer and does not open a URL supplied by a feed/catalog.

Complete the update through Chrome's own Help/About interface. Save work before relaunching and close the reviewed copy before **Activity → Verify Reviewed Result**. Verification acquires canonical per-app ownership, rejects another active Maccet operation, and reads fresh path/bundle/receipt/version, pinned publisher, reviewed signature and executable-platform evidence. The exact reviewed version is required. A different/newer release or changed channel requires a new check/review; it is not silently accepted as the original target. Running-instance detection uses canonical copy paths, conservatively blocking unknown-path instances with the same bundle ID.

`vendor-history.json` records awaiting/not-verified/verified outcomes and successful verification time independently of automatic history. Report export includes that history with the existing recursive diagnostic redaction. No automatic success is invented and no cache cleanup or external policy mutation is performed. Live signing review context is retained only in the current session; history remains readable after restart, but a new review is needed for new verification context.

## Verification

Controlled checks exercise served-release filtering, returned identity/version/pagination limits, Mach-O formats, publisher rejection, explicit channel/copy boundaries, target revalidation, unchanged/wrong identity/receipt/path/channel/architecture/running/ownership results, UI opt-in/review/handoff, separate persistence/export and denied automatic eligibility. Positive publisher identities are test-injected only through the testing interface; unsigned/ad-hoc fixtures are rejected by the production validator. No successful real Chrome update, real vendor installer or full third-party certification is claimed. #19's real target acceptance remains open.

This PR is stacked on discovery PR #59 and uses the bounded network transport introduced by #57. App Store-assisted work in #58 remains independent.
