# Read-only embedded Sparkle checks

This is a constrained implementation slice for #33. Enable **Sources → Check embedded Sparkle feeds**, then scan. The setting is persisted and defaults off for existing and new preferences. Store receipts, system applications and independently established manager routes take precedence. Feed observations never create a manager route, open an enclosure, launch an application or authorize an installation.

## Scope and result

An application must have an embedded `SUFeedURL`, numeric marketing/build metadata and no `SURequireSignedFeed` requirement. Maccet compares `CFBundleVersion` with the feed's `sparkle:version`, and displays `sparkle:shortVersionString` separately. It understands top-level version elements and legacy namespaced enclosure attributes. Selection is independent of feed order and considers minimum/maximum macOS, minimum installed build, macOS enclosures, Apple Silicon hardware requirements and channels. Untagged releases are the default channel; a separately established channel can add matching tagged releases. Unknown hardware/version rules, custom versions, complex major-upgrade rules, missing releases and unsupported feeds do not become current/eligible claims.

The embedded feed can differ from the application's runtime feed, delegate-selected channels, custom comparator or skipped-release policy. The result explicitly describes its observed scope. A current result means no newer supported numeric release in that scope; it does not certify parity with the running updater. Signed appcasts are unsupported until feed authentication is implemented. HTTPS transport and a bundle-declared feed are not a verified publisher mapping or a code signature. The built-in updater must confirm and install every offered release. #34's installation workflow remains separate work.

## Network and parsing limits

- HTTPS URL of at most 2,048 UTF-8 bytes, conventional DNS hostname, default HTTPS port, no user information or fragment. Literal IP addresses and local/special-use hostname suffixes are rejected. Hostname resolution and TLS trust use the platform; the check does not pin publisher keys, DNS answers or remote IPs.
- No redirects, credentials, cookie store, response cache, embedded-resource loads, enclosure downloads or release-note requests. HTTP authentication challenges are canceled; TLS uses platform trust. Only a successful XML/RSS response is accepted.
- Request timeout 15 seconds, total resource timeout 20 seconds. Decoded response bytes are capped at 1 MiB during iteration, even without a Content-Length header; session cancellation follows completion/failure.
- At most 16 feed requests begin within a 30-second monotonic scan budget. An already-started request may consume its remaining resource timeout. Omitted feeds stay unchecked with a smaller-folder suggestion. Cancellation prevents further requests.
- UTF-8 XML only, no NULs, DTDs, entity declarations or external entity resolution. At most 256 items, 20,000 elements, depth 16, 16 attributes per element, 4 KiB attribute values and 16 KiB text nodes. Unknown release requirements and conflicting metadata fail conservatively. Nested delta enclosures cannot replace full releases.

## Verification

Controlled fixtures exercise selection, channel/OS/hardware/build filtering, legacy namespace aliases, malicious/malformed/excessive XML, conflicting rules, URL restrictions, HTTP status/type/size rejection including an oversized streamed body, explicit opt-in, store/manager precedence, scan request limits, serialization and denied automatic eligibility. HTTP tests use an in-process URL protocol; they contact no remote service. These checks establish the supported subset, not real-vendor coverage, arbitrary updater-delegate equivalence or an independent benchmark.

Format references: [Sparkle publishing documentation](https://sparkle-project.org/documentation/publishing/) and [SUAppcastItem reference](https://sparkle-project.org/documentation/api-reference/Classes/SUAppcastItem.html).
