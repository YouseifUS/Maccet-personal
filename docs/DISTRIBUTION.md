# Owner-operated Developer ID distribution

This prepares the legitimate signing/notarization pipeline requested by #38. It does not provide a signing certificate, private key, Apple account, Keychain profile or a notarized release. The public-distribution and clean-target acceptance gates remain open until the owner executes and validates them. Ordinary `scripts/build.sh` remains the local ad-hoc alpha build.

## Configure on a trusted signing machine

Use a real **Developer ID Application** identity in the signing user's Keychain and an appropriate Apple Developer team. Find the exact certificate identity fingerprint with Apple's `security find-identity -v -p codesigning` command. The release workflow accepts its 40-character SHA-1 identity selector, then independently verifies the signed application's Developer ID requirement/team. It rejects ad-hoc identity selection.

Create an existing notarytool Keychain profile interactively, outside the repository, using `xcrun notarytool store-credentials`. Let Apple's tool prompt for credentials, or use your organization's legitimate existing Keychain setup. No password, private key or Apple ID is placed in a repository file or release manifest. The release script uses only the profile name. Follow [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) and your organization's credential policy.

Set these environment values for an explicit release run:

- `MACCET_SIGNING_IDENTITY`: exact Keychain signing-identity fingerprint.
- `MACCET_TEAM_ID`: expected ten-character team identifier.
- `MACCET_NOTARY_PROFILE`: existing notarytool Keychain profile name.

Then run `bash scripts/release.sh` from the repository. `--help` works without credentials. Missing/invalid configuration stops before building or contacting Apple. Python 3.9+ and Apple's build/signing/notary tools are required; the script uses `/usr/bin/python3` supplied with the exercised Command Line Tools setup. Tools are located with `xcrun`; their presence is not a platform certification.

## Gates and output

The workflow serializes releases with an owned kernel-held lock. It builds the ordinary local alpha, copies it into a private staging directory, and inspects the executable's actual architectures. Existing distribution output for the same version/build/architecture is preserved. Increment `CFBundleVersion` for a new distribution.

This product currently contains one code-bearing executable. Nested helpers/frameworks/extensions or executable resource bundles require an explicit inside-out signing policy and are rejected. Signing uses the exact identity, a secure timestamp and Hardened Runtime, without `sudo`, entitlement exceptions or deep signing. This follows [Apple's distribution-signing guidance](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/).

The staged application must satisfy its exact bundle ID, Apple Developer ID certificate chain and configured team. Runtime/timestamp evidence, source identity/version metadata, architecture and the bundled startup-script check are verified before upload. Notary submission uses the existing Keychain profile, JSON output and an explicit wait timeout. Only a completed `Accepted` verdict with a valid submission ID proceeds.

The ticket is stapled to the application, validated and assessed by Gatekeeper. The final ZIP is created from that stapled application, extracted into another staging directory and checked again for metadata, architecture, signature/team, stapled ticket, Gatekeeper and bundled resources. Only then is a complete output directory atomically published:

`dist/Maccet-<version>-build<build>-macOS-<architecture>-notarized/`

It contains the ZIP and `verification.json` with archive SHA-256, actual architectures, bundle/version/build/minimum-OS metadata, team, submission ID, check list and verification time. Architecture metadata states which slices exist; it does not certify runtime behavior on another CPU/OS. No public upload, GitHub release or repository merge is performed.

Private intermediate apps, upload ZIPs and command/notary diagnostics remain under `dist/.developer-id-*` for the owner. They are excluded from the distributable folder and ignored by Git. Preserve needed evidence before removing those owner-created staging folders. A rejected/failed/timed-out submission publishes no distribution. A notary job may continue after a client timeout; inspect Apple's existing job/history before explicitly retrying. The workflow does not automatically resubmit or bypass validation.

## Verification and remaining acceptance

`/usr/bin/python3 scripts/test-release.py` runs eleven controlled orchestration checks with intercepted Apple tools and disposable bundles. They cover the success ordering, argument safety, missing configuration, signer/team/runtime/timestamp rejection, notary/stapling/Gatekeeper failures, tampered/extracted artifacts, concurrency, nested-code policy and preservation of prior output. Those simulated Apple verdicts are test data, not signing/notarization evidence.

Before claiming a public release, the owner must run the real workflow, inspect the actual manifest and archived diagnostics, and test the delivered ZIP/app on a separate suitable Gatekeeper-enabled target, including offline ticket behavior, native launch/readiness/resources, authorization cancellation and reviewed update flows. Record exact OS/CPU/tool versions. Do not disable Gatekeeper, remove quarantine or use signing/notary bypass flags to make acceptance pass. The full OS/architecture matrix (#37), real update/clean-machine acceptance (#19), accessibility matrix (#36) and owner delivery proof (#38) remain separate gates.
