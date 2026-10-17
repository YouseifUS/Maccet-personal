# Platform validation

The deployment target remains macOS 13. That is a build configuration, not a claim that every macOS 13+ installation has passed real update acceptance.

## Repeatable CI matrix

`.github/workflows/macos-validation.yml` runs on pull requests, main/CI branch pushes and manual dispatch. Its explicit runner matrix is macOS 15 Intel (`x86_64`), macOS 15 Apple Silicon (`arm64`) and macOS 26 Apple Silicon (`arm64`). The labels follow [GitHub's hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners); the actual OS/SDK/Swift versions are recorded by each job because runner images change. No compiler version is inferred from a label.

Each job runs `bash scripts/validate-platform.sh <expected-architecture>`. It records the revision, OS, CPU architecture, Swift/SDK/Xcode and Python versions, then runs core, UI-model, setup and release-orchestration checks and a local release build. The generated ZIP is extracted and checked for strict ad-hoc signature integrity, exact binary architecture, valid bundle metadata and the actual delivered startup script's presence, bytes and shell syntax. The extracted executable also runs its resource diagnostic from outside the checkout. Failures stop the gate and propagate through log capture. Logs are retained for 14 days even on failure; previous local logs are removed on rerun. CI does not publish an installable release.

The workflow uses read-only repository permissions, pinned official action commits, no persisted checkout credentials and no signing/notarization secrets. Tests use disposable fixtures and controlled source commands. It does not prepare package managers, run real application installers, scan the host's application inventory or submit notarization requests.

For local use, omit the architecture argument to require the current host's architecture. A Command Line Tools installation can run these checks; when full Xcode is unavailable the environment log says so and records the selected developer directory plus Swift/SDK versions. Logs are written under the ignored `.build/platform-validation/` directory.

## Evidence and remaining acceptance

Local combined behavior was exercised on macOS 27.0.1 arm64 with Swift 6.4; see [integration evidence](ISSUE-WORK-INTEGRATION-2026-10-18.md) and [keyboard/accessibility evidence](ACCESSIBILITY-VALIDATION-2026-10-18.md). A workflow definition alone is not evidence that its matrix passed: consult the PR's actual Actions runs and their uploaded environment/test logs.

On 18 October 2026 the complete new platform script passed locally on that macOS 27.0.1 arm64/Swift 6.4 Command Line Tools host: 186 core checks, 9 UI-model checks, 17 setup checks, 11 release-orchestration tests, release build and all extracted-package gates. This local result does not stand in for the hosted matrix.

Hosted checks cover controlled adapter/installer-selection/failure fixtures and resource packaging. They do not certify native keyboard/VoiceOver behavior, actual first installation of Homebrew/MacPorts/mas, real App Store authentication or updates, vendor-managed rollout behavior, Gatekeeper delivery or Developer ID notarization. macOS 13/14, macOS 26 Intel, older compatible compiler/SDK combinations and clean-machine real update paths remain unverified unless separately documented. Intel first-install and upstream tool limits remain in [source preparation](STARTUP_SETUP.md). Issue #37 therefore remains open for the wider acceptance matrix.
