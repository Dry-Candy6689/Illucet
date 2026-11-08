import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("branding", Path(__file__).resolve().parents[1] / "verify-branding.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BrandingTests(unittest.TestCase):
    def test_rejects_retired_names_in_binary_and_text_and_filenames(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "FormerName.swift").write_text("let name = 1")
            (root / "current.swift").write_text('let name = "FORMERNAME"')
            (root / "asset.bin").write_bytes(b"\x00FormerName\x00")
            self.assertEqual(len(module.retired_references(list(root.iterdir()), root, ["FormerName"])), 3)

    def test_missing_files_and_history_are_not_current_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.assertEqual(module.retired_references([root / "FormerName.swift"], root, ["FormerName"]), [])

    def test_current_brand_passes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "Illucet.swift"
            path.write_text('let name = "Illucet"')
            self.assertEqual(module.retired_references([path], root, ["FormerName"]), [])


if __name__ == "__main__":
    unittest.main()
