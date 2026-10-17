#!/usr/bin/env python3
"""Build and verify a Developer ID distribution with an existing Keychain profile."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone


class ReleaseError(Exception):
    pass


class ReleaseWorkflow:
    def __init__(self, root, environment=None, runner=None):
        self.root = Path(root).resolve()
        self.environment = dict(os.environ if environment is None else environment)
        self.runner = runner or subprocess.run
        self.stage = None
        self.phase = "configuration"
        self.command_number = 0

    def command(self, arguments, timeout=180):
        self.command_number += 1
        # No shell interpretation or test-only executable override is exposed by the CLI.
        try:
            result = self.runner(list(map(str, arguments)), cwd=str(self.root), env=self.environment,
                                 capture_output=True, text=True, timeout=timeout, check=False)
        except subprocess.TimeoutExpired as error:
            self.save_log("Command timed out; an uploaded notary job can continue remotely.\n")
            raise ReleaseError("Command timed out during " + self.phase) from error
        self.save_log((result.stdout or "") + (result.stderr or ""))
        if result.returncode != 0:
            raise ReleaseError("Command failed during " + self.phase)
        if len(result.stdout or "") > 1024 * 1024 or len(result.stderr or "") > 1024 * 1024:
            raise ReleaseError("Unexpectedly large command metadata during " + self.phase)
        return result.stdout or "", result.stderr or ""

    def save_log(self, text):
        if self.stage is not None:
            path = self.stage / ("%03d-%s.log" % (self.command_number, self.phase))
            path.write_text(text)
            path.chmod(0o600)

    def configuration(self):
        identity = self.environment.get("MACCET_SIGNING_IDENTITY", "")
        team = self.environment.get("MACCET_TEAM_ID", "")
        profile = self.environment.get("MACCET_NOTARY_PROFILE", "")
        if not re.fullmatch(r"[0-9A-Fa-f]{40}", identity):
            raise ReleaseError("Set MACCET_SIGNING_IDENTITY to the SHA-1 identity fingerprint from your Keychain.")
        if not re.fullmatch(r"[A-Z0-9]{10}", team):
            raise ReleaseError("Set MACCET_TEAM_ID to the expected Developer ID team.")
        if not profile or len(profile) > 128 or profile.startswith("-") or "\n" in profile or "\r" in profile:
            raise ReleaseError("Set MACCET_NOTARY_PROFILE to your existing notarytool Keychain profile name.")
        return identity, team, profile

    @staticmethod
    def info(path):
        data = path.read_bytes()
        if len(data) > 1024 * 1024:
            raise ReleaseError("Unexpectedly large application metadata.")
        return plistlib.loads(data)

    def verify_bundle(self, app, expected, team, architectures, gatekeeper=False):
        info = self.info(app / "Contents/Info.plist")
        for key in ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "CFBundleExecutable", "LSMinimumSystemVersion"]:
            if info.get(key) != expected.get(key):
                raise ReleaseError("The delivered application's identity/version metadata changed.")
        requirement = ('=identifier "%s" and anchor apple generic and '
                       'certificate 1[field.1.2.840.113635.100.6.2.6] exists and '
                       'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
                       'certificate leaf[subject.OU] = "%s"') % (expected["CFBundleIdentifier"], team)
        self.command(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--test-requirement", requirement, app])
        out, err = self.command(["/usr/bin/codesign", "--display", "--verbose=4", app])
        details = out + err
        if not re.search(r"^TeamIdentifier=" + re.escape(team) + r"$", details, re.M):
            raise ReleaseError("The signing team differs from the configured team.")
        if not re.search(r"^CodeDirectory .*flags=.*\([^\n]*\bruntime\b", details, re.M) or not re.search(r"^Timestamp=.+$", details, re.M):
            raise ReleaseError("The distribution lacks Hardened Runtime or a secure timestamp.")
        executable = app / "Contents/MacOS" / expected["CFBundleExecutable"]
        actual_architectures, _ = self.command(["/usr/bin/lipo", "-archs", executable])
        if sorted(set(actual_architectures.strip().split())) != architectures:
            raise ReleaseError("The delivered executable architecture changed.")
        self.command([executable, "--check-startup-script"], timeout=30)
        if gatekeeper:
            self.command(["/usr/bin/xcrun", "stapler", "validate", app])
            self.command(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", app])

    def run(self):
        identity, team, profile = self.configuration()
        expected = self.info(self.root / "scripts/Info.plist")
        for key in ["CFBundleShortVersionString", "CFBundleVersion"]:
            if not re.fullmatch(r"[0-9][A-Za-z0-9._-]{0,63}", str(expected.get(key, ""))):
                raise ReleaseError("Unsupported release version/build metadata.")
        if not re.fullmatch(r"[A-Za-z0-9.-]{1,255}", expected.get("CFBundleIdentifier", "")) or not re.fullmatch(r"[A-Za-z0-9._-]{1,255}", expected.get("CFBundleExecutable", "")):
            raise ReleaseError("Unsupported application identity or executable name.")
        dist = self.root / "dist"
        if dist.is_symlink():
            raise ReleaseError("The release output directory must not be a symlink.")
        dist.mkdir(exist_ok=True)
        lock_path = dist / ".developer-id-release.lock"
        descriptor = os.open(str(lock_path), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, 0o600)
        try:
            lock_info = os.fstat(descriptor)
            if not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != os.getuid() or lock_info.st_nlink != 1:
                raise ReleaseError("The release lock is not an owned regular file.")
            os.fchmod(descriptor, 0o600)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ReleaseError("Another Developer ID release is active.") from error
            self.stage = Path(tempfile.mkdtemp(prefix=".developer-id-", dir=str(dist)))
            self.phase = "tool-preflight"
            self.command(["/usr/bin/xcrun", "--find", "notarytool"])
            self.command(["/usr/bin/xcrun", "--find", "stapler"])
            self.phase = "local-build"
            self.command(["/bin/bash", self.root / "scripts/build.sh"], timeout=900)
            app = self.stage / "Maccet.app"
            self.phase = "copy"
            self.command(["/usr/bin/ditto", dist / "Maccet.app", app])
            # This product currently has one code-bearing executable. Future
            # helpers/frameworks need an explicit inside-out signing policy.
            for nested in app.rglob("*"):
                if nested.is_dir() and nested.suffix in [".app", ".framework", ".xpc", ".appex"]:
                    raise ReleaseError("Nested code requires an explicit signing policy before distribution.")
                if nested.is_dir() and nested.suffix == ".bundle":
                    plist = nested / "Contents/Info.plist"
                    if plist.exists() and self.info(plist).get("CFBundleExecutable"):
                        raise ReleaseError("Executable resource bundles require an explicit signing policy.")
            self.phase = "architecture"
            architecture, _ = self.command(["/usr/bin/lipo", "-archs", app / "Contents/MacOS" / expected["CFBundleExecutable"]])
            architectures = sorted(set(architecture.strip().split()))
            if not architectures or not set(architectures).issubset({"arm64", "x86_64"}):
                raise ReleaseError("Unsupported distribution architecture.")
            arch_label = "universal" if len(architectures) == 2 else architectures[0]
            label = "Maccet-%s-build%s-macOS-%s-notarized" % (expected["CFBundleShortVersionString"], expected["CFBundleVersion"], arch_label)
            destination = dist / label
            if destination.exists() or destination.is_symlink():
                raise ReleaseError("A distribution with this version/build/architecture already exists; preserve it and increment the build.")
            self.phase = "developer-id-signing"
            self.command(["/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp", app])
            self.verify_bundle(app, expected, team, architectures)
            upload = self.stage / "notary-upload.zip"
            self.phase = "notary-upload-archive"
            self.command(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, upload])
            self.phase = "notary-submission"
            out, _ = self.command(["/usr/bin/xcrun", "notarytool", "submit", upload, "--keychain-profile", profile,
                                   "--wait", "--timeout", "30m", "--no-progress", "--output-format", "json"], timeout=2100)
            try:
                verdict = json.loads(out)
            except (TypeError, ValueError) as error:
                raise ReleaseError("Notarytool did not return a complete JSON verdict.") from error
            submission = verdict.get("id", "")
            if verdict.get("status") != "Accepted" or not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", submission):
                raise ReleaseError("Apple did not accept this notarization submission; no distribution was published.")
            self.phase = "stapling"
            self.command(["/usr/bin/xcrun", "stapler", "staple", app])
            self.verify_bundle(app, expected, team, architectures, gatekeeper=True)
            final = self.stage / "ready"
            final.mkdir(mode=0o700)
            archive = final / (label + ".zip")
            self.phase = "distribution-archive"
            self.command(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive])
            self.phase = "delivered-artifact"
            delivered = self.stage / "Delivered"
            self.command(["/usr/bin/ditto", "-x", "-k", archive, delivered])
            self.verify_bundle(delivered / "Maccet.app", expected, team, architectures, gatekeeper=True)
            sha256 = hashlib.sha256()
            with archive.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    sha256.update(chunk)
            manifest = {"bundleID": expected["CFBundleIdentifier"], "version": expected["CFBundleShortVersionString"],
                        "build": expected["CFBundleVersion"], "minimumOS": expected["LSMinimumSystemVersion"],
                        "architectures": architectures, "teamID": team, "submissionID": submission,
                        "archive": archive.name, "sha256": sha256.hexdigest(), "verifiedAt": datetime.now(timezone.utc).isoformat(),
                        "checks": ["Developer ID requirement", "Hardened Runtime", "secure timestamp", "notary Accepted",
                                   "stapled ticket", "Gatekeeper assessment", "extracted signature and bundled resource"]}
            (final / "verification.json").write_text(json.dumps(manifest, indent=2) + "\n")
            for path in final.iterdir():
                path.chmod(0o600)
            self.phase = "publication"
            os.rename(str(final), str(destination))
            # Retain private signing/notary diagnostics for the owner. They are
            # never copied into the distributable directory or the repository.
            return destination
        finally:
            os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog="Requires MACCET_SIGNING_IDENTITY, MACCET_TEAM_ID and MACCET_NOTARY_PROFILE. Credentials stay in an existing Keychain profile; no Apple submission runs without explicit configuration.")
    parser.parse_args()
    workflow = ReleaseWorkflow(Path(__file__).resolve().parent.parent)
    try:
        output = workflow.run()
    except (ReleaseError, OSError, ValueError, plistlib.InvalidFileException) as error:
        print("Release not published: " + str(error), file=sys.stderr)
        if workflow.stage is not None:
            print("Private diagnostics retained at " + str(workflow.stage), file=sys.stderr)
        return 1
    print("Verified Developer ID distribution: " + str(output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
