#!/usr/bin/env python3

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

import ci_swiftpm_cache as cache


class SwiftPMCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ci-input-cache-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True)
        self.original_ns = time.time_ns() - 5_000_000_000
        self.names = ["Package.swift", "Sources/Main.swift", "Sources/probe.c", "Tests/Resources/fixture.md"]
        for name in self.names:
            self.write(name, "original\n", self.original_ns)
        self.git("add", ".")
        cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")

    def git(self, *arguments):
        subprocess.run(["git", *arguments], cwd=self.root, check=True, capture_output=True)

    def write(self, name, content, timestamp=None):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        if timestamp is not None:
            os.utime(path, ns=(timestamp, timestamp))
        return path

    def result(self, context="test-context"):
        return cache.restore(self.root, cache.DEFAULT_METADATA, context)

    def metadata(self, mutate):
        path = self.root / cache.DEFAULT_METADATA
        document = json.loads(path.read_text())
        mutate(document)
        path.write_text(json.dumps(document))

    def test_identical_contents_restore_swift_c_manifest_and_resource_timestamps(self):
        for name in self.names:
            self.write(name, "original\n")
        self.assertEqual(self.result()["restored"], len(self.names))
        for name in self.names:
            self.assertEqual((self.root / name).stat().st_mtime_ns, self.original_ns)
            self.assertEqual((self.root / name).read_text(), "original\n")

    def test_changed_same_size_content_is_not_given_old_timestamp(self):
        path = self.write("Sources/Main.swift", "modified\n")
        changed_ns = path.stat().st_mtime_ns
        result = self.result()
        self.assertEqual(result["changed"], 1)
        self.assertEqual(path.stat().st_mtime_ns, changed_ns)
        self.assertEqual(path.read_text(), "modified\n")

    def test_changed_content_with_preserved_or_older_timestamp_is_invalidated(self):
        for timestamp in (self.original_ns, self.original_ns - 1_000_000_000):
            with self.subTest(timestamp=timestamp):
                path = self.write("Sources/Main.swift", "modified\n", timestamp)
                self.assertEqual(self.result()["changed"], 1)
                self.assertGreater(path.stat().st_mtime_ns, self.original_ns)
                self.assertEqual(path.read_text(), "modified\n")

    def test_added_deleted_and_untracked_files_keep_checkout_state(self):
        path = self.write("Sources/Added.swift", "new\n")
        new_ns = path.stat().st_mtime_ns
        untracked = self.write("Sources/Untracked.swift", "untracked\n")
        untracked_ns = untracked.stat().st_mtime_ns
        (self.root / "Sources/Main.swift").unlink()
        self.git("add", "-A", "--", "Sources/Main.swift", "Sources/Added.swift")
        result = self.result()
        self.assertEqual(result["missing"], 1)
        self.assertFalse((self.root / "Sources/Main.swift").exists())
        self.assertEqual(path.stat().st_mtime_ns, new_ns)
        self.assertEqual(untracked.stat().st_mtime_ns, untracked_ns)

    def test_changed_git_or_filesystem_permissions_are_not_normalized(self):
        path = self.root / "Sources/probe.c"
        self.write("Sources/probe.c", "original\n")
        path.chmod(0o755)
        new_ns = path.stat().st_mtime_ns
        self.assertEqual(self.result()["changed"], 1)
        self.assertEqual(path.stat().st_mtime_ns, new_ns)
        self.assertEqual(path.stat().st_mode & 0o777, 0o755)
        self.git("add", "Sources/probe.c")
        self.assertEqual(self.result()["changed"], 1)

    def test_wrong_context_missing_and_malformed_metadata_fall_back_without_writes(self):
        path = self.write("Sources/Main.swift", "original\n")
        new_ns = path.stat().st_mtime_ns
        self.assertIn("fallback", self.result("other-toolchain"))
        metadata = self.root / cache.DEFAULT_METADATA
        metadata.write_text("{broken")
        self.assertIn("fallback", self.result())
        metadata.unlink()
        self.assertIn("fallback", self.result())
        self.assertEqual(path.stat().st_mtime_ns, new_ns)

    def test_malicious_paths_reject_entire_metadata_before_restoring_valid_records(self):
        for name in ("../outside", "/outside", "Sources/../outside", "Sources//Main.swift", "."):
            with self.subTest(name=name):
                cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")
                path = self.write("Sources/Main.swift", "original\n")
                new_ns = path.stat().st_mtime_ns
                self.metadata(lambda doc: doc["files"].update({name: doc["files"]["Package.swift"]}))
                self.assertIn("fallback", self.result())
                self.assertEqual(path.stat().st_mtime_ns, new_ns)

    def test_invalid_records_reject_entire_metadata_before_any_write(self):
        for key, value in (("sha256", "bad"), ("mtime_ns", -1), ("mtime_ns", True), ("git_mode", "120000"), ("file_mode", -1), ("size", -1)):
            with self.subTest(key=key, value=value):
                cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")
                path = self.write("Sources/Main.swift", "original\n")
                new_ns = path.stat().st_mtime_ns
                self.metadata(lambda doc: doc["files"]["Package.swift"].update({key: value}))
                self.assertIn("fallback", self.result())
                self.assertEqual(path.stat().st_mtime_ns, new_ns)

    def test_symlink_input_and_ancestor_cannot_write_outside_repository(self):
        with tempfile.TemporaryDirectory(prefix="ci-input-outside-") as external:
            outside = Path(external) / "Main.swift"
            outside.write_text("original\n")
            outside_ns = outside.stat().st_mtime_ns
            inside = self.root / "Sources/Main.swift"
            inside.unlink()
            inside.symlink_to(outside)
            self.assertEqual(self.result()["unavailable"], 1)
            self.assertEqual(outside.stat().st_mtime_ns, outside_ns)
            inside.unlink()
            (self.root / "Sources/probe.c").unlink()
            (self.root / "Sources").rmdir()
            (self.root / "Sources").symlink_to(external, target_is_directory=True)
            self.assertEqual(self.result()["unavailable"], 2)
            self.assertEqual(outside.stat().st_mtime_ns, outside_ns)

    def test_symlink_metadata_is_not_read(self):
        with tempfile.TemporaryDirectory(prefix="ci-input-meta-") as external:
            metadata = self.root / cache.DEFAULT_METADATA
            outside = Path(external) / "metadata.json"
            outside.write_bytes(metadata.read_bytes())
            metadata.unlink()
            metadata.symlink_to(outside)
            self.assertIn("fallback", self.result())

    def test_git_tracked_symlinks_are_not_snapshotted(self):
        link = self.root / "TrackedLink.swift"
        link.symlink_to(self.root / "Sources/Main.swift")
        self.git("add", "TrackedLink.swift")
        cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")
        files = json.loads((self.root / cache.DEFAULT_METADATA).read_text())["files"]
        self.assertNotIn("TrackedLink.swift", files)

    def test_context_changes_with_toolchain_sdk_flags_and_dependencies(self):
        for name in cache.CONTEXT_INPUTS:
            self.write(name, "context-input\n")
        versions = {
            ("xcodebuild", "-version"): "Xcode test build",
            ("swift", "--version"): "Swift test version",
            ("swift", "build", "--help"): "default: native",
            ("xcrun", "--sdk", "macosx", "--show-sdk-path"): "/sdk",
            ("xcrun", "--sdk", "macosx", "--show-sdk-version"): "test-sdk",
            ("xcrun", "--sdk", "macosx", "--show-sdk-build-version"): "test-build",
        }
        with patch.object(cache.subprocess, "check_output", side_effect=lambda args, **_: versions[args]), \
                patch.object(cache.platform, "machine", return_value="arm64"):
            baseline = cache.build_context(self.root, "macos26-arm64")
            self.assertEqual(baseline, cache.build_context(self.root, "macos26-arm64"))
            self.assertNotEqual(baseline["context"], cache.build_context(self.root, "macos15-arm64")["context"])
            for arguments, version in list(versions.items()):
                with self.subTest(arguments=arguments):
                    versions[arguments] = version + "-changed"
                    self.assertNotEqual(baseline["context"], cache.build_context(self.root, "macos26-arm64")["context"])
                    versions[arguments] = version
            for name in cache.CONTEXT_INPUTS:
                with self.subTest(name=name):
                    self.write(name, "changed-context\n")
                    self.assertNotEqual(baseline["context"], cache.build_context(self.root, "macos26-arm64")["context"])
                    self.write(name, "context-input\n")
            with patch.object(cache.platform, "machine", return_value="x86_64"):
                self.assertNotEqual(baseline["context"], cache.build_context(self.root, "macos26-arm64")["context"])


if __name__ == "__main__":
    unittest.main()
