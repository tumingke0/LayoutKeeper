# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 LayoutKeeper contributors
"""Read-only release protection tests on temporary mock bundles; no signing or AX."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('frozen', Path(__file__).with_name('frozen-release.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FrozenReleaseTests(unittest.TestCase):
    def test_contents_and_added_removed_files_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / 'executable'
            file.write_bytes(b'first')
            original = module.inventory(root)
            self.assertEqual(original, module.inventory(root))
            file.write_bytes(b'updated')
            self.assertNotEqual(original, module.inventory(root))
            file.write_bytes(b'first')
            extra = root / 'resource'
            extra.write_bytes(b'new')
            self.assertNotEqual(original, module.inventory(root))
            extra.unlink()
            self.assertEqual(original, module.inventory(root))

    def test_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'link').symlink_to('/tmp')
            with self.assertRaises(ValueError):
                module.inventory(root)


if __name__ == '__main__':
    unittest.main()
