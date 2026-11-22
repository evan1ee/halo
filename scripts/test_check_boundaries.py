#!/usr/bin/env python3
"""Unit tests for scripts/check_boundaries.py, including MODULE_BOUNDARIES §1 naming rules."""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "check_boundaries.py"


class CheckBoundariesNamingTests(unittest.TestCase):
    def _run(self, root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(root)],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_valid_tree_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            domain_src = root / "ios" / "Packages" / "HaloCore" / "Sources" / "HaloDomain"
            domain_src.mkdir(parents=True)
            (domain_src / "Room.swift").write_text("public struct Room: Sendable {}\n")
            feat_src = root / "ios" / "Packages" / "HaloApple" / "Sources" / "FeatureTimeline"
            feat_src.mkdir(parents=True)
            (feat_src / "View.swift").write_text("import HaloDomain\n")

            res = self._run(root)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)

    def test_bad_feature_name_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "ios" / "Packages" / "HaloApple" / "Sources" / "Timeline").mkdir(parents=True)
            res = self._run(root)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("module 'Timeline' must match Halo<Layer> or Feature<Area>", res.stdout)

    def test_bad_layer_name_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "ios" / "Packages" / "CoreUtils" / "Sources" / "CoreUtils").mkdir(parents=True)
            res = self._run(root)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("package 'CoreUtils' must match Halo<Layer>", res.stdout)

    def test_module_name_colliding_with_domain_type_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            domain_src = root / "ios" / "Packages" / "HaloCore" / "Sources" / "HaloDomain"
            domain_src.mkdir(parents=True)
            (domain_src / "FeatureChat.swift").write_text("public struct FeatureChat: Sendable {}\n")
            (root / "ios" / "Packages" / "HaloApple" / "Sources" / "FeatureChat").mkdir(parents=True)

            res = self._run(root)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("module name 'FeatureChat' collides with public type", res.stdout)

    def test_manifest_forbidden_target_dependency_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pkg = root / "ios" / "Packages" / "HaloApple"
            (pkg / "Sources" / "FeatureTimeline").mkdir(parents=True)
            (pkg / "Package.swift").write_text(
                'let package = Package(targets: [\n'
                '    .target(name: "FeatureTimeline", dependencies: ["HaloMatrixAdapter"]),\n'
                '])\n'
            )
            res = self._run(root)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("target FeatureTimeline declares HaloMatrixAdapter", res.stdout)


if __name__ == "__main__":
    unittest.main()
