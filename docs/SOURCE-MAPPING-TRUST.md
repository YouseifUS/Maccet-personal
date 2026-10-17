# Versioned source-mapping evidence

`SourceMappingCatalog` is a constrained schema-v1 authoring DTO. `SourceMappingCatalogStore.accept/load` authenticate publisher data and return an `AuthenticatedSourceMappingCatalog` value snapshot. Consumers obtain identity-bound evidence from that authenticated snapshot; a mutable authoring DTO does not expose the matching API.

## Wire format and trust anchors

An envelope contains exactly `keyID`, `payload` and `signature`. Payload and signature are strict base64 strings. The Ed25519 signature covers the UTF-8 domain `Maccet Source Mapping Catalog v1` followed by a NUL byte and the exact decoded payload bytes. Publishers choose their JSON serialization before signing; the client never reserializes signed bytes for verification.

The client receives pinned Ed25519 public keys from trusted configuration. A key supplied in the same envelope/payload is not a trust anchor. No production publisher key or remote endpoint is invented/configured here. An empty registry rejects every publisher. This component performs no networking or installation; broader discovery and feed/vendor execution remain separate work.

The payload carries schema version, monotonically increasing revision, issue/expiry dates and mappings. Input is bounded to 2 MiB per envelope and 1 MiB per payload, with at most 4,096 mappings. Unknown top-level/entry fields, arbitrary commands, unsupported capability/source values, duplicate identities and invalid compatibility/review data are rejected. Metadata URLs require HTTPS, exact reviewed public DNS hosts, no user-info/fragment and the default HTTPS port. No wildcard-domain or suffix matching is used.

## Evidence and execution boundary

Each entry records bundle identity, optional signing team/channel, reviewed official hosts/metadata URL, review date, capability, minimum macOS and permitted architectures. Source-specific package identities use the existing constrained manager validators. Unknown team/channel/domain evidence remains provisional; conflicting bundle/team/channel/OS/architecture or receipt ownership fails matching. Identity inputs must come from independent installed-app evidence, not from the proposed mapping itself.

Authenticated mappings produce `reviewedMapping` evidence. They cannot confer `installedManager` ownership or authorize automatic installation. `Preferences.isEligible` and plan revalidation preserve this boundary; evidence is carried through records/routes and channel-specific release exclusions. Legacy installed-manager routes retain their existing independently checked ownership behavior. Signed catalog authenticity is not an application code signature or an installer capability.

## Retained state and rollback

A new envelope is verified before persistence. Cache acceptance is serialized across Maccet instances using kernel-held ownership. Revisions below the client's trusted minimum or the last accepted revision are rejected; same-revision payload replacement is rejected. Expired cached data cannot be used for matching, but its verified revision still prevents rollback when accepting a later catalog. Advancing the client's minimum does not prevent replacement of an older valid cache with a newer accepted revision.

The retained known-good envelope is stored in a private `LocalStore`; invalid incoming data leaves it intact. Cache reads are bounded regular-file reads without following a leaf symlink. Publisher key rotation must retain old verification keys until the previous accepted catalog can be verified/replaced. Protection assumes the client trust configuration and local state remain trusted; deliberate local-state deletion/reset requires a suitable bundled minimum revision policy.

## Verification

Checks use real ephemeral Ed25519 keys and disposable local stores. They cover trusted/untrusted signatures, rollback/equivocation, expiry and client-minimum advancement, retained known-good state, identity/channel/domain conflicts and unknowns, constrained fields and URLs, route serialization, automatic-eligibility rejection, input bounds and cache symlinks. No private signing key is stored or published.

## Optional discovery consumer

The Sources configuration can explicitly pin an owner-selected publisher and endpoint. `SourceDiscoveryService` retrieves bounded envelopes, preserves this store’s authentication/revision/expiry rules, and attaches candidates independently of manager ownership. Channel reviews are bound to a canonical installed path, bundle and currently validated publisher team. See [the discovery lifecycle](DISCOVERY-CATALOG.md); no default publisher, remote key acceptance, manager adoption or release-check capability is implied.
