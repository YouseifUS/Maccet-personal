# Automatic source setup — 0.1.2

The GUI prepares its dependencies on every launch, once per app process, before an automatic application scan. Opening another window does not repeat setup. Use **Sources → Prepare Sources Again** or **Retry Setup** to run it again deliberately.

## Startup sequence

1. Check Apple developer tools with `xcrun --find clang`. If missing, request Apple's installer using `xcode-select --install`. The system controls its download, license, and installation. Finish it and use **Retry Setup**; dependent work is paused until then.
2. Find Homebrew under `/opt/homebrew/bin` or `/usr/local/bin`. When missing on Apple Silicon, download `Homebrew.pkg` from the latest official `Homebrew/brew` GitHub release, verify the release SHA-256 and Gatekeeper assessment, and install through macOS authorization. Run `brew update` as the logged-in user and check its version.
3. Find MacPorts at `/opt/local/bin/port`. When missing, select exactly one package from the latest official `macports/macports-base` release whose OS major version matches this Mac. Verify SHA-256 and Gatekeeper before installing through macOS authorization. Run `port -N selfupdate` with administrator authorization and check its version.
4. For an existing `/opt/local/bin/mas`, update only `mas` through MacPorts. Otherwise use Homebrew: `brew list --formula --versions mas` determines whether to run `brew install --formula mas` or `brew upgrade --formula mas`. Check that the helper reports version 7 or later.
5. Show the result of each step, then scan applications using the available sources. A failed step does not turn its status into success or prevent an independent source from completing.

`Sources/UpdaterCore/Resources/prepare-sources.sh` contains the fixed startup maintenance operations. `DependencySetup` drives prerequisite checks, release selection, downloads, verification, and progress. SwiftPM bundles the script, and the build script copies its resource bundle into the app. The distributed app does not depend on the source checkout or its build cache.

## Authorization and failure handling

macOS owns the administrator dialog. Maccet does not collect passwords. Authorization can be canceled in that dialog. An active privileged installer is allowed to finish; closing Maccet during source preparation is blocked to avoid abandoning it. Source maintenance is serialized with application scans and updates.

Progress is step-based, without a download percentage. Failed and canceled steps show their diagnostic message in **Sources**. **Retry Setup** reruns checks and refreshes the tools that are already installed. There is no automatic retry loop and no cached success that suppresses future-launch maintenance. Offline launches can therefore show setup failures while local inventory and available sources remain usable.

Downloaded packages use a private per-attempt temporary directory and are removed when the attempt finishes. Packages are checked before authorization and rechecked by the authorized process immediately before installation. Missing release digests, foreign URLs, ambiguous packages, mismatched hashes, and rejected signatures block installation. Source tools may keep their normal metadata caches. Shared caches and installed app data are not deleted by startup.

## Platform limits

The current official Homebrew package supports Apple Silicon. On Intel, install Homebrew once from its official instructions, then use **Retry Setup**; updates to that existing installation are automated. This app's macOS 13 deployment target does not promise that the latest upstream tools support every older macOS release. Missing OS-specific MacPorts installers are reported rather than guessed. No installer is compiled from source as a fallback.

An App Store account may still need to be signed in through Apple's own app. Xcode licenses and additional source-specific requirements may need system interaction. The app cannot grant itself system privileges or accept licenses for the user.

The source enable switches affect application checks; all three dependencies are still maintained at launch. Installing an additional manager does not adopt existing applications or automatically expand verified ownership coverage.

## Scope of automatic changes

Startup updates the tools and their metadata, plus dependencies required to install/update those tools. It never invokes `brew upgrade` without the named `mas` formula, `port upgrade outdated`, application cask upgrades, or global cleanup. Inventory application upgrades continue through the existing explicit review queue.

The diagnostic entry points `--inventory-json`, `--scan-json`, and `--check-startup-script` bypass GUI setup. The last command validates that the bundled startup script is readable and has valid shell syntax without installing or updating anything.

## References

- [Homebrew installation and package constraints](https://docs.brew.sh/Installation)
- [Homebrew update and named formula operations](https://docs.brew.sh/Manpage)
- [MacPorts installation and selfupdate](https://www.macports.org/install.php)
- [mas installation](https://github.com/mas-cli/mas)
