from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify-project-state.py"
SPEC = importlib.util.spec_from_file_location("project_verifier", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ProjectVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for relative in MODULE.REQUIRED_FILES:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("# Entry\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_minimal_required_documents_pass(self) -> None:
        self.assertEqual(MODULE.verify(self.root), [])

    def test_missing_required_document_fails(self) -> None:
        (self.root / "docs/Development.md").unlink()
        self.assertIn("required file is missing: docs/Development.md", MODULE.verify(self.root))

    def test_reports_broken_relative_link(self) -> None:
        (self.root / "README.md").write_text("[missing](docs/absent.md)\n", encoding="utf-8")
        self.assertTrue(any("broken local link" in issue and "docs/absent.md" in issue
                            for issue in MODULE.verify(self.root)))

    def test_rejects_path_escape(self) -> None:
        (self.root / "README.md").write_text("[outside](../../outside.md)\n", encoding="utf-8")
        self.assertTrue(any("link escapes repository" in issue for issue in MODULE.verify(self.root)))

    def test_valid_relative_and_external_links_pass(self) -> None:
        (self.root / "docs/guide.md").write_text("# Guide\n", encoding="utf-8")
        (self.root / "README.md").write_text(
            "[guide](docs/guide.md) [site](https://example.com/a) [anchor](#intro)\n",
            encoding="utf-8",
        )
        self.assertEqual(MODULE.verify(self.root), [])

    def test_ignored_vendor_markdown_is_not_scanned(self) -> None:
        path = self.root / "Vendor/Package/README.md"
        path.parent.mkdir(parents=True)
        path.write_text("[missing](does-not-exist.md)\n", encoding="utf-8")
        self.assertEqual(MODULE.verify(self.root), [])

if __name__ == "__main__":
    unittest.main()
