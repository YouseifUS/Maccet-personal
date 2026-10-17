# Authenticated source discovery

This implements the candidate and dated-cache layer requested by #30, on top of #31's signed mapping schema. A catalog can suggest sources for applications that no installed manager claims. Suggestions never become executable routes, automatic-update eligibility or checked-release coverage. There is no name-based matching, guessed package identity or implicit ownership transfer.

## Configure and use

1. Obtain a trusted publisher's HTTPS endpoint, key ID, base64 Ed25519 public key and trusted minimum revision through an independent trusted channel. No production publisher or trust key is shipped/invented by Maccet.
2. In **Sources → Configure Publisher**, enter those values and verify the displayed SHA-256 public-key fingerprint with your trusted publisher. **Trust Publisher and Save** persists the explicit trust choice; saving performs no network request.
3. Choose **Refresh Discovery Catalog**. The endpoint must return `application/json` with the signed envelope documented in [the trust specification](SOURCE-MAPPING-TRUST.md). Signature keys from downloaded data are never accepted as trust anchors.
4. A normal application scan reads only a currently authenticated, unexpired cache. Open an application's Details to inspect matching-bundle candidates and their evidence.
5. If the application has a valid certificate-signed publisher, confirm its installed release channel from the application's own settings. The review is bound to canonical path, bundle ID and validated team. Separate local copies require separate reviews; unknown publisher/channel evidence stays provisional. Conflicts stay visible and cannot create an installer route.

A matched mapping establishes the catalog's identity/channel/platform evidence. It does not establish an available release, download authenticity, installed-manager ownership or permission to adopt/update the app. System apps are excluded and store receipts exclude non-store catalog candidates. Existing manager routes remain independent. Disabling discovery stops catalog use/refresh and preserves the cache; no applications or managers are removed.

## Bounds, freshness and failures

The shared metadata transport requires conventional HTTPS DNS URLs without user-info/fragments/custom ports, rejects literal IP and local/special-use hostname suffixes, refuses redirects/HTTP authentication/cookies/cache, and uses platform TLS trust. It does not pin DNS answers or remote IPs. Requests have a 15-second request timeout, 20-second resource timeout and a 2 MiB decoded-response cap. Sparkle reuses the same transport with its independent XML MIME policy and 1 MiB cap.

Catalog envelopes/payloads/mappings retain the existing schema, signature, revision, expiry and parser limits. Verification uses completion time, including time spent in flight. A catalog that expires while being fetched cannot be accepted. Each refresh holds kernel ownership across retrieval and acceptance; another Maccet instance cannot duplicate the refresh. Successful refreshes are limited to one per hour while the cache remains valid; failures or an expired cache have a one-minute retry interval. Wall-clock rollback does not bypass the interval. Catalog validity still assumes an appropriate system clock.

A failed/invalid/offline refresh preserves the known-good signed envelope. It is usable only while its signature, trusted minimum revision and expiry remain valid. Expired or unauthenticated caches produce no candidates. Last attempt, last successful fetch, issued/expiry dates and revision remain separate; sanitized last-refresh failures remain visible across ordinary scans. Cancellation prevents acceptance. Refresh-state files are bounded regular-file reads without leaf-symlink following.

Caches are namespaced by the explicitly pinned key ID/public key. Changing an endpoint for the same publisher does not reset its accepted revision. Changing trust identity starts a separate namespace; carry the publisher's trusted minimum revision into that explicit configuration. Key rotation/default production catalog distribution remain publisher/deployment policy, not data trusted from a network response.

## Verification and limits

Fixture checks exercise signed refreshes, success/failure rate limits, offline/invalid response fallback, expiry, cancellation, concurrent instances, in-flight expiry, revision rollback, exact bundle/publisher/channel/platform matching, independent local copies, receipt protection, denied plan/coverage eligibility, JSON transport bounds and UI configuration/refresh persistence. Tests use ephemeral signing keys, in-process responses and disposable stores; no production publisher or real application update is claimed. The independent 300-case benchmark (#32) remains separate acceptance work.

This PR is based on the bounded Sparkle PR (#57) to share its network transport; it does not depend on App Store attention PR #58.
