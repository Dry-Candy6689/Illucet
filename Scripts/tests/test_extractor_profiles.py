#!/usr/bin/env python3
"""Deterministic build-profile provenance, compatibility and mutation tests."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("profiles", ROOT / "Scripts/select-extractor-profile.py")
profiles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profiles)


def metadata(package, version):
    filename = f"{package.replace('-', '_')}-{version}-py3-none-any.whl"
    return {"info": {"name": package, "version": version, "requires_python": ">=3.10",
                     "requires_dist": ['yt-dlp-ejs==0.8.0; extra == "default"',
                                       'certifi==2026.7.22; extra == "default"']},
            "urls": [{"filename": filename, "url": f"https://files.pythonhosted.org/packages/ab/{filename}",
                      "digests": {"sha256": "a" * 64}, "size": 100,
                      "packagetype": "bdist_wheel", "yanked": False}]}


class ProfileTests(unittest.TestCase):
    def test_exact_profiles_normalize_without_moving_aliases(self):
        for profile, release, expected in [
            ("stable", "2026.09.27", "2026.9.27"),
            ("nightly", "2026.09.27.232945", "2026.9.27.232945.dev0"),
            ("pinned", "2026.09.27", "2026.9.27"),
            ("pinned", "2026.09.27.232945", "2026.9.27.232945.dev0")]:
            with self.subTest(profile=profile, release=release):
                self.assertEqual(profiles.resolve(profile, release, metadata)["YTDLP_PACKAGE_VERSION"], expected)
        for profile, release in [("stable", "2026.09.27.1"), ("nightly", "2026.09.27"),
                                 ("pinned", "latest"), ("pinned", "2026.02.30"),
                                 ("pinned", "2026.09.27\n"), ("other", "2026.09.27")]:
            with self.assertRaises(ValueError):
                profiles.resolve(profile, release, metadata)

    def test_exact_dependencies_and_native_pins_preserved(self):
        pins = profiles.resolve("stable", "2026.09.27", metadata)
        source = (ROOT / "Config/Dependencies.sh").read_text()
        rendered = profiles.render(source, pins)
        self.assertIn('YTDLP_PACKAGE_VERSION="2026.9.27"', rendered)
        self.assertIn('YTDLP_PROFILE="stable"', rendered)
        for line in source.splitlines():
            if not line.startswith(("YTDLP_", "CERTIFI_")):
                self.assertIn(line, rendered)
        self.assertEqual(pins["YTDLP_EJS_VERSION"], "0.8.0")

    def test_rejects_yanked_native_duplicate_or_redirected_wheels(self):
        base = metadata("yt-dlp", "2026.9.27")
        changes = [("yanked", True), ("packagetype", "sdist"), ("size", 0),
                   ("size", 33 * 1024 * 1024), ("digests", {"sha256": "bad"}),
                   ("url", base["urls"][0]["url"].replace("files.pythonhosted.org", "evil.test")),
                   ("url", base["urls"][0]["url"] + "?redirect=1")]
        for key, value in changes:
            changed = copy.deepcopy(base)
            changed["urls"][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                profiles.artifact(changed, "yt-dlp", "2026.9.27")
        base["urls"].append(copy.deepcopy(base["urls"][0]))
        with self.assertRaises(ValueError):
            profiles.artifact(base, "yt-dlp", "2026.9.27")

    def test_missing_conflicting_or_incompatible_dependencies_fail(self):
        for requirements in ([], ["certifi>=2026.7.22"],
                             ["certifi==2026.7.22", "certifi==2026.8.1"]):
            with self.assertRaises(ValueError):
                profiles.dependency("certifi", requirements)
        for python in (">=3.16", None, ">=3.10,<3.14"):
            value = metadata("yt-dlp", "2026.9.27")
            value["info"]["requires_python"] = python
            with self.assertRaises(ValueError):
                profiles.artifact(value, "yt-dlp", "2026.9.27")

    def test_failed_resolution_never_changes_config(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Config").mkdir()
            path = root / "Config/Dependencies.sh"
            path.write_text("unchanged")
            with patch.object(profiles, "ROOT", root), patch.object(profiles, "resolve", side_effect=ValueError("fixture")), \
                 patch("sys.argv", ["select", "--profile", "stable", "--version", "2026.09.27", "--apply"]):
                with self.assertRaises(SystemExit):
                    profiles.main()
            self.assertEqual(path.read_text(), "unchanged")

    def test_missing_or_duplicate_pin_refuses_partial_render(self):
        source = (ROOT / "Config/Dependencies.sh").read_text()
        pins = profiles.resolve("pinned", "2026.09.27", metadata)
        for changed in (source + '\nYTDLP_PROFILE="pinned"\n', source.replace("YTDLP_PROFILE=", "MISSING=")):
            with self.assertRaises(ValueError):
                profiles.render(changed, pins)

    def test_apply_updates_only_verified_python_pins(self):
        source = (ROOT / "Config/Dependencies.sh").read_text()
        pins = profiles.resolve("stable", "2026.09.27", metadata)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Config").mkdir()
            path = root / "Config/Dependencies.sh"
            path.write_text(source)
            with patch.object(profiles, "ROOT", root), patch.object(profiles, "resolve", return_value=pins), \
                 patch("sys.argv", ["select", "--profile", "stable", "--version", "2026.09.27", "--apply"]):
                profiles.main()
            self.assertEqual(path.read_text(), profiles.render(source, pins))
            self.assertEqual(list((root / "Config").iterdir()), [path])


if __name__ == "__main__":
    unittest.main()
