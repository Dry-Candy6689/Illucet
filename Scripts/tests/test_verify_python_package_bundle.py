import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1] / "verify-python-package-bundle.py"
)
SPEC = importlib.util.spec_from_file_location("python_bundle_verifier", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class VerifyPythonPackageBundleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.config = self.root / "Dependencies.sh"
        self.packages = self.root / "PythonPackages"
        self.config.write_text(
            '\n'.join(
                [
                    'YTDLP_VERSION="2026.08.19"',
                    'YTDLP_EJS_VERSION="0.8.0"',
                    'CERTIFI_VERSION="2026.7.22"',
                ]
            ),
            encoding="utf-8",
        )
        self.write_distribution("yt-dlp", "2026.8.19", "yt_dlp-2026.8.19")
        self.write_distribution("yt-dlp-ejs", "0.8.0", "yt_dlp_ejs-0.8.0")
        self.write_distribution("certifi", "2026.7.22", "certifi-2026.7.22")
        version_module = self.packages / "yt_dlp" / "version.py"
        version_module.parent.mkdir(parents=True)
        version_module.write_text(
            "__version__ = '2026.08.19'\n",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write_distribution(self, name: str, version: str, directory: str) -> None:
        metadata = self.packages / f"{directory}.dist-info" / "METADATA"
        metadata.parent.mkdir(parents=True)
        metadata.write_text(
            f"Name: {name}\nVersion: {version}\n",
            encoding="utf-8",
        )

    def test_accepts_exact_pinned_bundle(self) -> None:
        verified = VERIFIER.verify_bundle(self.config, self.packages)
        self.assertEqual(verified["yt-dlp"], "2026.8.19")
        self.assertEqual(verified["yt-dlp-ejs"], "0.8.0")
        self.assertEqual(verified["certifi"], "2026.7.22")

    def test_rejects_stale_runtime_version(self) -> None:
        (self.packages / "yt_dlp" / "version.py").write_text(
            "__version__ = '2026.07.04'\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            VERIFIER.VerificationError,
            "yt-dlp runtime version mismatch",
        ):
            VERIFIER.verify_bundle(self.config, self.packages)

    def test_rejects_stale_distribution_metadata(self) -> None:
        metadata = self.packages / "yt_dlp-2026.8.19.dist-info" / "METADATA"
        metadata.write_text(
            "Name: yt-dlp\nVersion: 2026.7.4\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            VERIFIER.VerificationError,
            "yt-dlp version mismatch",
        ):
            VERIFIER.verify_bundle(self.config, self.packages)

    def test_rejects_duplicate_distribution_metadata(self) -> None:
        self.write_distribution("yt-dlp", "2026.7.4", "yt_dlp-2026.7.4")
        with self.assertRaisesRegex(
            VERIFIER.VerificationError,
            "expected exactly one yt-dlp distribution",
        ):
            VERIFIER.verify_bundle(self.config, self.packages)

    def test_nightly_package_and_runtime_versions_are_distinct_exact_pins(self) -> None:
        self.config.write_text(self.config.read_text().replace(
            'YTDLP_VERSION="2026.08.19"',
            'YTDLP_VERSION="2026.09.27.232945"\n'
            'YTDLP_PACKAGE_VERSION="2026.9.27.232945.dev0"'
        ))
        metadata = self.packages / "yt_dlp-2026.8.19.dist-info" / "METADATA"
        metadata.write_text("Name: yt-dlp\nVersion: 2026.9.27.232945.dev0\n")
        (self.packages / "yt_dlp" / "version.py").write_text(
            "__version__ = '2026.09.27.232945'\n"
        )
        self.assertEqual(VERIFIER.verify_bundle(self.config, self.packages)["yt-dlp"],
                         "2026.9.27.232945.dev0")
        metadata.write_text("Name: yt-dlp\nVersion: 2026.09.27.232945dev\n")
        self.assertEqual(VERIFIER.verify_bundle(self.config, self.packages)["yt-dlp"], "2026.09.27.232945dev")
        metadata.write_text("Name: yt-dlp\nVersion: 2026.9.27.232945.dev1\n")
        with self.assertRaisesRegex(VERIFIER.VerificationError, "version mismatch"):
            VERIFIER.verify_bundle(self.config, self.packages)


if __name__ == "__main__":
    unittest.main()
