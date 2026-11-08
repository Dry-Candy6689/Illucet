import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("sanitize", Path(__file__).resolve().parents[1] / "sanitize-python-package-metadata.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PackageMetadataTests(unittest.TestCase):
    def test_removes_only_local_provenance_and_its_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            metadata = root / "package.dist-info"
            metadata.mkdir()
            (metadata / "direct_url.json").write_text('{"url":"file:///local/wheel.whl"}')
            (metadata / "METADATA").write_text("Name: package\nVersion: 1\n")
            (metadata / "RECORD").write_text("package.dist-info/direct_url.json,hash,2\npackage.dist-info/METADATA,hash,10\n")
            self.assertEqual(module.sanitize(root), 1)
            self.assertFalse((metadata / "direct_url.json").exists())
            self.assertIn("METADATA,hash,10", (metadata / "RECORD").read_text())
            self.assertEqual((metadata / "METADATA").read_text(), "Name: package\nVersion: 1\n")
            self.assertEqual(module.sanitize(root), 0)

    def test_missing_root_is_an_error(self):
        with self.assertRaises(ValueError):
            module.sanitize(Path("/not-a-package-root"))


if __name__ == "__main__":
    unittest.main()
