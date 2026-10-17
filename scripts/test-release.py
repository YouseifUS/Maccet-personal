#!/usr/bin/env python3
"""Run release orchestration with disposable bundles and intercepted Apple tools."""
import importlib.util
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("maccet_release", Path(__file__).with_name("release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class Fixture:
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="maccet release check ")
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        self.info = {"CFBundleIdentifier": "test.maccet.release", "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "4",
                     "CFBundleExecutable": "MaccetFixture", "LSMinimumSystemVersion": "13.0"}
        (self.root / "scripts/Info.plist").write_bytes(plistlib.dumps(self.info))
        self.env = {"MACCET_SIGNING_IDENTITY": "a" * 40, "MACCET_TEAM_ID": "TEAMID1234", "MACCET_NOTARY_PROFILE": "Fixture profile"}
        self.calls = []
        self.failure = None
        self.bad_team = False
        self.runtime = True
        self.timestamp = True
        self.accepted = True
        self.tamper = False
        self.nested = False
        self.bad_extracted_arch = False
        self.workflow = release.ReleaseWorkflow(self.root, self.env, self.run)

    def run(self, args, **kwargs):
        self.calls.append(args)
        output, error, status = "", "", 0
        if self.failure and self.failure(args):
            return subprocess.CompletedProcess(args, 1, "", "Controlled failure")
        if args[0] == "/bin/bash":
            contents = self.root / "dist/Maccet.app/Contents"
            (contents / "MacOS").mkdir(parents=True, exist_ok=True)
            (contents / "Resources").mkdir(exist_ok=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps(self.info))
            (contents / "MacOS/MaccetFixture").write_bytes(b"disposable test binary")
            if self.nested:
                (contents / "Frameworks/Unexpected.framework").mkdir(parents=True)
        elif args[0] == "/usr/bin/ditto":
            if "-c" in args:
                source, target = Path(args[-2]), Path(args[-1])
                with zipfile.ZipFile(target, "w") as archive:
                    for path in source.rglob("*"):
                        if path.is_file():
                            archive.write(path, str(path.relative_to(source.parent)))
            elif "-x" in args:
                target = Path(args[-1])
                with zipfile.ZipFile(args[-2]) as archive:
                    archive.extractall(target)
                if self.tamper:
                    data = dict(self.info); data["CFBundleVersion"] = "tampered"
                    (target / "Maccet.app/Contents/Info.plist").write_bytes(plistlib.dumps(data))
            else:
                shutil.copytree(args[-2], args[-1], symlinks=True)
        elif args[:2] == ["/usr/bin/lipo", "-archs"]:
            output = "x86_64\n" if self.bad_extracted_arch and "Delivered" in args[-1] else "arm64\n"
        elif args[:2] == ["/usr/bin/codesign", "--display"]:
            error = "TeamIdentifier=%s\nCodeDirectory v=20500 flags=0x10000(%s) hashes=10\n%s" % (
                "OTHER12345" if self.bad_team else "TEAMID1234", "runtime" if self.runtime else "none",
                "Timestamp=Fixture timestamp\n" if self.timestamp else "Signed Time=Fixture local time\n")
        elif args[0:3] == ["/usr/bin/xcrun", "notarytool", "submit"]:
            output = json.dumps({"id": "12345678-1234-1234-1234-123456789abc", "status": "Accepted" if self.accepted else "Invalid"})
        return subprocess.CompletedProcess(args, status, output, error)

    def close(self):
        self.temporary.cleanup()


class ReleaseChecks(unittest.TestCase):
    def fixture(self):
        fixture = Fixture(); self.addCleanup(fixture.close); return fixture

    def test_success_verifies_extracted_stapled_distribution_before_publication(self):
        fixture = self.fixture()
        output = fixture.workflow.run()
        manifest = json.loads((output / "verification.json").read_text())
        self.assertEqual(manifest["teamID"], "TEAMID1234")
        self.assertEqual(manifest["architectures"], ["arm64"])
        self.assertEqual(len(manifest["sha256"]), 64)
        self.assertEqual(len([call for call in fixture.calls if call[0] == "/usr/sbin/spctl"]), 2)
        self.assertTrue(any("Delivered/Maccet.app" in call[-1] for call in fixture.calls if "--test-requirement" in call))
        signing = next(call for call in fixture.calls if call[:2] == ["/usr/bin/codesign", "--force"])
        self.assertIn("--timestamp", signing); self.assertIn("runtime", signing); self.assertNotIn("--deep", signing)
        self.assertEqual((output / manifest["archive"]).stat().st_mode & 0o777, 0o600)
        self.assertEqual(set(path.name for path in output.iterdir()), {manifest["archive"], "verification.json"})
        self.assertTrue((fixture.root / "dist/Maccet.app").exists())

    def test_missing_configuration_never_builds_or_contacts_apple(self):
        fixture = self.fixture(); fixture.workflow.environment = {}
        with self.assertRaises(release.ReleaseError): fixture.workflow.run()
        self.assertEqual(fixture.calls, [])
        self.assertFalse((fixture.root / "dist").exists())

    def test_ad_hoc_identity_and_option_like_profiles_are_rejected(self):
        for identity, profile in [("-", "Fixture"), ("a" * 40, "--force"), ("a" * 40, "bad\nprofile")]:
            fixture = self.fixture()
            fixture.workflow.environment["MACCET_SIGNING_IDENTITY"] = identity
            fixture.workflow.environment["MACCET_NOTARY_PROFILE"] = profile
            with self.assertRaises(release.ReleaseError): fixture.workflow.run()
            self.assertEqual(fixture.calls, [])

    def test_signing_notary_stapling_and_gatekeeper_failures_never_publish(self):
        predicates = [lambda a: a[:2] == ["/usr/bin/codesign", "--force"],
                      lambda a: a[:3] == ["/usr/bin/xcrun", "notarytool", "submit"],
                      lambda a: a[:3] == ["/usr/bin/xcrun", "stapler", "staple"],
                      lambda a: a[0] == "/usr/sbin/spctl"]
        for predicate in predicates:
            fixture = self.fixture(); fixture.failure = predicate
            with self.assertRaises(release.ReleaseError): fixture.workflow.run()
            self.assertFalse(any((fixture.root / "dist").glob("Maccet-*-notarized")))
            self.assertTrue(fixture.workflow.stage.exists())

    def test_wrong_team_missing_runtime_or_timestamp_fail_before_upload(self):
        for setting, value in [("bad_team", True), ("runtime", False), ("timestamp", False)]:
            fixture = self.fixture(); setattr(fixture, setting, value)
            with self.assertRaises(release.ReleaseError): fixture.workflow.run()
            self.assertFalse(any(call[:3] == ["/usr/bin/xcrun", "notarytool", "submit"] for call in fixture.calls))

    def test_invalid_notary_verdict_and_tampered_delivered_bundle_never_publish(self):
        for setting in ["accepted", "tamper"]:
            fixture = self.fixture(); setattr(fixture, setting, setting == "tamper")
            with self.assertRaises(release.ReleaseError): fixture.workflow.run()
            self.assertFalse(any((fixture.root / "dist").glob("Maccet-*-notarized")))

    def test_nested_code_requires_explicit_signing_policy(self):
        fixture = self.fixture(); fixture.nested = True
        with self.assertRaises(release.ReleaseError): fixture.workflow.run()
        self.assertFalse(any(call[:2] == ["/usr/bin/codesign", "--force"] for call in fixture.calls))

    def test_extracted_architecture_and_gatekeeper_failures_never_publish(self):
        fixture = self.fixture(); fixture.bad_extracted_arch = True
        with self.assertRaises(release.ReleaseError): fixture.workflow.run()
        self.assertFalse(any((fixture.root / "dist").glob("Maccet-*-notarized")))
        fixture = self.fixture()
        fixture.failure = lambda a: a[0] == "/usr/sbin/spctl" and "Delivered" in a[-1]
        with self.assertRaises(release.ReleaseError): fixture.workflow.run()
        self.assertFalse(any((fixture.root / "dist").glob("Maccet-*-notarized")))

    def test_concurrent_release_is_rejected_before_build(self):
        fixture = self.fixture(); (fixture.root / "dist").mkdir()
        with (fixture.root / "dist/.developer-id-release.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(release.ReleaseError): fixture.workflow.run()
        self.assertEqual(fixture.calls, [])

    def test_cli_help_and_missing_configuration_do_not_require_credentials(self):
        script = Path(__file__).with_name("release.sh")
        environment = {"PATH": "/usr/bin:/bin"}
        help_result = subprocess.run(["/bin/bash", str(script), "--help"], env=environment, capture_output=True, text=True)
        self.assertEqual(help_result.returncode, 0)
        result = subprocess.run(["/bin/bash", str(script)], env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("MACCET_SIGNING_IDENTITY", result.stderr)
        self.assertNotIn("Private diagnostics retained", result.stderr)

    def test_existing_distribution_is_preserved(self):
        fixture = self.fixture(); existing = fixture.workflow.run()
        original = (existing / "verification.json").read_bytes()
        with self.assertRaises(release.ReleaseError): fixture.workflow.run()
        self.assertEqual((existing / "verification.json").read_bytes(), original)
        self.assertEqual(len([call for call in fixture.calls if call[:3] == ["/usr/bin/xcrun", "notarytool", "submit"]]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
