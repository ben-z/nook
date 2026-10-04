import json
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import package


class VersionTests(unittest.TestCase):
    def test_invalid_versions_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for value in ("", "1.2", "v1.2.3", "01.2.3", "1.2.3-beta", "1.2.3\n4.5.6"):
                with self.subTest(value=value):
                    (root / "VERSION").write_text(value)
                    with self.assertRaises(ValueError):
                        package.read_version(root)

    def test_missing_version_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(FileNotFoundError):
                package.read_version(Path(directory))

    def test_release_tag_must_match_the_version(self):
        package.check_tag("1.2.3", "v1.2.3")
        for tag in ("1.2.3", "v1.2.4", "v1.2.3-beta", "v01.2.3"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                package.check_tag("1.2.3", tag)


class ArchiveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.version = package.read_version(ROOT)
        cls.archive = ROOT / "dist" / f"Nook-{cls.version}-macos-universal.zip"
        cls.source = ROOT / "dist" / f"Nook-{cls.version}-source.zip"
        if not cls.archive.is_file() or not cls.source.is_file():
            raise RuntimeError("Run scripts/check.sh to build the required release archives")
        cls.minimum = json.loads((ROOT / "dist/release.json").read_text())["minimumMacOS"]

    def rewrite_archive(self, destination, change):
        with zipfile.ZipFile(self.archive) as original, zipfile.ZipFile(destination, "w") as modified:
            for entry in original.infolist():
                modified.writestr(entry, change(entry.filename, original.read(entry)))

    def test_extracted_app_signature_and_both_architectures(self):
        package.verify_app_archive(self.archive, self.version, self.minimum)

    def test_tampered_resource_is_rejected_by_signature_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            modified = Path(directory) / "tampered.zip"
            self.rewrite_archive(modified, lambda name, data:
                                 data + b"tampered" if name.endswith("/Resources/NOTICE") else data)
            with self.assertRaises(subprocess.CalledProcessError):
                package.verify_app_archive(modified, self.version, self.minimum)

    def test_stale_app_version_is_rejected(self):
        def change(name, data):
            if name.endswith("/Info.plist"):
                info = plistlib.loads(data)
                info["CFBundleShortVersionString"] = "99.98.97"
                return plistlib.dumps(info)
            return data
        with tempfile.TemporaryDirectory() as directory:
            modified = Path(directory) / "stale.zip"
            self.rewrite_archive(modified, change)
            with self.assertRaisesRegex(ValueError, "metadata"):
                package.verify_app_archive(modified, self.version, self.minimum)

    def test_unsafe_and_duplicate_archive_paths_are_rejected(self):
        for names in (("Nook.app/../../escape",), ("/Nook.app/escape",), ("Other.app/file",),
                      ("Nook.app/file", "Nook.app/file")):
            with self.subTest(names=names), tempfile.TemporaryDirectory() as directory:
                archive = Path(directory) / "unsafe.zip"
                with zipfile.ZipFile(archive, "w") as zipped:
                    zipped.writestr(names[0], b"payload")
                    for name in names[1:]:
                        with self.assertWarns(UserWarning):
                            zipped.writestr(name, b"payload")
                with self.assertRaises(ValueError):
                    package.extract_app_archive(archive, Path(directory) / "extracted")

    def test_symlink_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "symlink.zip"
            entry = zipfile.ZipInfo("Nook.app/link")
            entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            with zipfile.ZipFile(archive, "w") as zipped:
                zipped.writestr(entry, b"../../outside")
            with self.assertRaisesRegex(ValueError, "symlink"):
                package.extract_app_archive(archive, Path(directory) / "extracted")

    def test_source_archive_contains_exactly_the_committed_files(self):
        tracked = set(subprocess.check_output(
            ["git", "ls-files"], cwd=ROOT, text=True
        ).splitlines())
        prefix = f"nook-{self.version}/"
        with zipfile.ZipFile(self.source) as zipped:
            files = {entry.filename.removeprefix(prefix) for entry in zipped.infolist() if not entry.is_dir()}
            self.assertEqual(files, tracked)
            self.assertTrue(zipped.getinfo(prefix + "build.sh").external_attr >> 16 & 0o111)
            self.assertEqual(zipped.read(prefix + "VERSION"), (ROOT / "VERSION").read_bytes())


if __name__ == "__main__":
    unittest.main()
