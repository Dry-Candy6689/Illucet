import importlib.util
import hashlib
import io
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("runtime_restore", Path(__file__).resolve().parents[1] / "restore-runtime-dependencies.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RuntimeArchiveTests(unittest.TestCase):
    def archive(self, name):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            archive.writestr(name, b"data")
        return zipfile.ZipFile(stream)

    def test_rejects_escape_and_unexpected_payloads(self):
        for name in ("../outside", "/absolute", "Vendor/Other/file", "Vendor/PythonPackages/../outside"):
            with self.subTest(name=name), self.archive(name) as archive:
                with self.assertRaises(ValueError):
                    module.validate_members(archive)

    def test_rejects_symlink_members(self):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            item = zipfile.ZipInfo("Vendor/PythonPackages/link")
            item.create_system = 3
            item.external_attr = 0o120777 << 16
            archive.writestr(item, "../../outside")
        with zipfile.ZipFile(stream) as archive, self.assertRaises(ValueError):
            module.validate_members(archive)

    def test_allows_known_runtime_members(self):
        with self.archive("Vendor/Frameworks/Python.xcframework/Info.plist") as archive:
            module.validate_members(archive)

    def test_complete_restore_preserves_executable_modes(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            archive_path = root / "runtime.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                for component in module.ALLOWED:
                    required = "yt_dlp/version.py" if component.endswith("PythonPackages") else "Info.plist"
                    archive.writestr(component + "/" + required, b"fixture")
                library = zipfile.ZipInfo(module.ALLOWED[0] + "/Python")
                library.create_system = 3
                library.external_attr = 0o100755 << 16
                archive.writestr(library, b"fixture library")
            (root / "Config").mkdir()
            (root / "Config/RuntimeRelease.json").write_text(json.dumps({"sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest()}))
            module.restore(archive_path, root)
            binary = root / module.ALLOWED[0] / "Python"
            self.assertEqual(binary.stat().st_mode & 0o777, 0o755)
            self.assertEqual(binary.read_bytes(), b"fixture library")

    def test_bad_digest_leaves_existing_runtime_untouched(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            (root / "Config").mkdir()
            (root / "Config/RuntimeRelease.json").write_text(json.dumps({"sha256": "0" * 64}))
            existing = root / module.ALLOWED[0]
            existing.mkdir(parents=True)
            (existing / "sentinel").write_text("keep")
            source = root / "bad.zip"
            source.write_bytes(b"bad")
            with self.assertRaises(ValueError):
                module.restore(source, root)
            self.assertEqual((existing / "sentinel").read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
