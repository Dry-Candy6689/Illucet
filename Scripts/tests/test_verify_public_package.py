import importlib.util
import hashlib
import io
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("public_package", Path(__file__).resolve().parents[1] / "verify-public-package.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PublicPackageTests(unittest.TestCase):
    def test_reports_categories_without_echoing_values(self):
        secret = "ghp_" + "a" * 36
        results = module.inspect_payload("payload.bin", secret.encode(), [])
        self.assertEqual(results, ["payload.bin: access token"])
        self.assertNotIn(secret, str(results))

    def test_scans_nested_archives_and_signing_profiles(self):
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, "w") as archive:
            archive.writestr("Payload/App.app/embedded.mobileprovision", b"profile")
            archive.writestr("Payload/App.app/binary", ("/" + "Users/" + "someone/private/").encode())
        results = module.inspect_payload("release.ipa", inner.getvalue(), [])
        self.assertTrue(any("personal signing material" in result for result in results))
        self.assertTrue(any("personal home path" in result for result in results))

    def test_private_denylist_covers_binary_encodings_and_filenames(self):
        for encoding in ("utf-8", "utf-16-le", "utf-16-be"):
            with self.subTest(encoding=encoding):
                results = module.inspect_payload("binary", "FormerProduct".encode(encoding), ["formerproduct"])
                self.assertTrue(any("denylist match" in result for result in results))
        self.assertTrue(module.inspect_payload("FormerProduct.png", b"image", ["FormerProduct"]))

    def test_public_notices_and_synthetic_addresses_are_allowed(self):
        self.assertEqual(module.inspect_payload("LICENSE", b"Copyright contributors. Contact maintainer@example.invalid", []), [])

    def test_upstream_exception_requires_exact_bytes_and_rule(self):
        upstream = ("AIza" + "a" * 35).encode()
        allowlist = {"PythonPackages/upstream.py": {"sha256": hashlib.sha256(upstream).hexdigest(), "rules": ["access token"]}}
        label = "release.ipa!Payload/App.app/PythonPackages/upstream.py"
        self.assertEqual(module.inspect_payload(label, upstream, [], allowlist), [])
        self.assertTrue(module.inspect_payload(label, upstream + b"changed", [], allowlist))
        self.assertTrue(module.inspect_payload(label, upstream, ["upstream.py"], allowlist))

    def test_webpage_paths_are_not_personal_home_directories(self):
        self.assertEqual(module.inspect_payload("source.py", b"https://example.invalid/home/person/video", []), [])


if __name__ == "__main__":
    unittest.main()
