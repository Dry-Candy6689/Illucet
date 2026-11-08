import hashlib
import io
import json
from pathlib import Path
import stat
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import illucet_package_install as installer
import illucet_runtime_contract as contract


class PackageInstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.destination = self.root / "site-packages"
        self.destination.mkdir()

    def wheels(self, extra=None):
        result = []
        for name, module in installer.PACKAGES.items():
            version = "2026.10.10.233141.dev0" if name == "yt-dlp" else "0.8.0"
            runtime = "2026.10.10.233141" if name == "yt-dlp" else version
            file = self.root / (module + ".whl")
            with zipfile.ZipFile(file, "w") as archive:
                archive.writestr(module + "/__init__.py", f'__version__ = "{runtime}"\n')
                if name != "certifi":
                    archive.writestr(module + ("/version.py" if name == "yt-dlp" else "/_version.py"),
                                     f'__version__ = "{runtime}"\n')
                if name == "yt-dlp" and extra:
                    archive.writestr(*extra)
            result.append({"package": name, "version": version, "path": str(file),
                           "sha256": hashlib.sha256(file.read_bytes()).hexdigest()})
        return result

    def test_extracts_without_executing_downloaded_code(self):
        wheels = self.wheels(("yt_dlp/danger.py", "raise RuntimeError('must not execute')"))
        versions = installer.extract_packages(wheels, str(self.destination))
        self.assertEqual(versions["ytDLP"], "2026.10.10.233141")
        self.assertEqual(versions["ejs"], "0.8.0")
        self.assertTrue((self.destination / "yt_dlp/danger.py").is_file())

    def master_archive(self, extra=None, channel="master"):
        version = "2026.10.10.123456"
        path = self.root / "yt-dlp.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            files = {
                "yt-dlp/pyproject.toml": (
                    '[project]\nname = "yt-dlp"\nrequires-python = ">=3.11"\n'
                    '[project.optional-dependencies]\npin = ["yt-dlp-ejs==0.8.0", "certifi==0.8.0"]\n'
                ),
                "yt-dlp/yt_dlp/__init__.py": "raise RuntimeError('must not execute')\n",
                "yt-dlp/yt_dlp/version.py": (
                    f'__version__ = "{version}"\nCHANNEL = "{channel}"\n'
                    'ORIGIN = "yt-dlp/yt-dlp-master-builds"\n'
                ),
                "yt-dlp/test/test_fixture.py": "# excluded from the install\n",
            }
            for name, text in files.items():
                contents = text.encode()
                member = tarfile.TarInfo(name)
                member.size = len(contents)
                archive.addfile(member, io.BytesIO(contents))
            if extra:
                archive.addfile(extra, io.BytesIO(b"x" * extra.size))
        return {"package": "yt-dlp", "format": "masterSource", "path": str(path),
                "version": version, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}

    def test_master_stages_only_the_extractor_using_verified_dependency_pins(self):
        master = self.master_archive()
        self.assertEqual(installer.inspect_master_archive(master), {
            "requiresPython": ">=3.11",
            "requirements": ["yt-dlp-ejs==0.8.0", "certifi==0.8.0"],
        })
        self.assertEqual(list(self.destination.iterdir()), [])
        versions = installer.extract_packages([master, *self.wheels()[1:]], str(self.destination))
        self.assertEqual(versions, {"ytDLP": master["version"], "ejs": "0.8.0", "certifi": "0.8.0"})
        self.assertEqual({p.name for p in self.destination.iterdir()}, {"yt_dlp", "yt_dlp_ejs", "certifi"})

    def test_master_rejects_wrong_identity_and_unsafe_members(self):
        with self.assertRaises(ValueError):
            installer.inspect_master_archive(self.master_archive(channel="nightly"))
        for name in ("yt-dlp/../../escape", "yt-dlp/yt_dlp/VERSION.py", "yt-dlp/yt_dlp/loader.pth",
                     "yt-dlp/yt_dlp/native.dylib"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                installer.inspect_master_archive(self.master_archive(tarfile.TarInfo(name)))
        for link_type in (tarfile.SYMTYPE, tarfile.LNKTYPE):
            link = tarfile.TarInfo("yt-dlp/yt_dlp/link")
            link.type = link_type
            link.linkname = "outside"
            with self.assertRaises(ValueError):
                installer.inspect_master_archive(self.master_archive(link))
        self.assertFalse((self.root / "escape").exists())

    def test_master_rejects_hash_mismatch_and_bounded_tar_expansion(self):
        master = self.master_archive()
        with self.assertRaisesRegex(ValueError, "integrity"):
            installer.inspect_master_archive({**master, "sha256": "0" * 64})
        with patch.object(installer, "MAX_EXPANDED", 1024), self.assertRaisesRegex(ValueError, "expansion"):
            installer.inspect_master_archive(master)

    def test_certifi_runtime_date_matches_normalized_distribution_version(self):
        wheels = self.wheels()
        certificate = next(wheel for wheel in wheels if wheel["package"] == "certifi")
        path = Path(certificate["path"])
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("certifi/__init__.py", '__version__ = "2026.07.22"\n')
        certificate["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.assertEqual(installer.extract_packages(wheels, str(self.destination))["certifi"], "2026.7.22")

    def test_official_documentation_is_ignored_but_arbitrary_data_is_rejected(self):
        prefix = "yt_dlp-2026.10.10.233141.dev0.data/"
        for suffix in installer.YTDLP_UNUSED_DATA:
            with tempfile.TemporaryDirectory() as directory:
                installer.extract_packages(self.wheels((prefix + suffix, "unused")), directory)
                self.assertFalse(any(Path(directory).glob("*.data")))
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                installer.extract_packages(self.wheels((prefix + "scripts/unsafe", "bad")), directory)

    def test_rejects_hash_mismatch_before_extraction(self):
        wheels = self.wheels()
        wheels[0]["sha256"] = "0" * 64
        with self.assertRaises(ValueError):
            installer.extract_packages(wheels, str(self.destination))
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_rejects_traversal_native_code_and_import_hooks(self):
        for name in ("../escape", "/escape", "yt_dlp/../../escape", "yt_dlp\\escape",
                     "yt_dlp/a.pth", "yt_dlp/a.so", "yt_dlp/a.pyc", "other/__init__.py"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ValueError):
                    installer.extract_packages(self.wheels((name, "bad")), directory)
        self.assertFalse((self.root / "escape").exists())

    def test_rejects_symlink_and_case_collision(self):
        symlink = zipfile.ZipInfo("yt_dlp/link")
        symlink.create_system = 3
        symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
        for entry in ((symlink, "outside"), ("yt_dlp/VERSION.py", "collision")):
            with tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ValueError):
                    installer.extract_packages(self.wheels(entry), directory)

    def test_rejects_limits_and_nonempty_destination(self):
        with patch.object(installer, "MAX_EXPANDED", 1):
            with self.assertRaises(ValueError):
                installer.extract_packages(self.wheels(), str(self.destination))
        (self.destination / "existing").write_text("preserve")
        with self.assertRaises(ValueError):
            installer.extract_packages(self.wheels(), str(self.destination))
        self.assertEqual((self.destination / "existing").read_text(), "preserve")

    def test_version_is_literal_not_evaluated(self):
        version = self.root / "version.py"
        version.write_text('__version__ = __import__("os").getcwd()')
        with self.assertRaises(ValueError):
            installer._literal_version(version)

    def test_verified_runtime_contract_preserves_native_version(self):
        path = self.root / "_illucet_runtime.json"
        data = {"schemaVersion": 1, "ytDLP": "2026.10.10.233141", "ejs": "0.8.0",
                "certifi": "2026.7.22", "quickJS": contract.QUICKJS_VERSION}
        path.write_text(json.dumps(data))
        with patch.object(sys, "_illucet_package_root", str(self.root), create=True):
            self.assertEqual(contract.expected_versions()[0], data["ytDLP"])
            data["quickJS"] = "incompatible"
            path.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                contract.expected_versions()


if __name__ == "__main__":
    unittest.main()
