#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 LayoutKeeper contributors
"""Seal/check an existing candidate without signing, installing, or requesting permission."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def inventory(bundle):
    result = {}
    for path in sorted(bundle.rglob('*')):
        if path.is_symlink():
            raise ValueError('Symlinks are not supported in this frozen prototype')
        if path.is_file():
            result[str(path.relative_to(bundle))] = hashlib.sha256(path.read_bytes()).hexdigest()
    if not result:
        raise ValueError('Empty or missing bundle')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['seal', 'check'])
    parser.add_argument('bundle', type=Path)
    parser.add_argument('manifest', type=Path)
    args = parser.parse_args()
    subprocess.run(['codesign', '--verify', '--strict', str(args.bundle)], check=True)
    current = inventory(args.bundle)
    if args.action == 'seal':
        # Exclusive creation prevents silently redefining an already frozen release.
        with args.manifest.open('x') as output:
            json.dump({'format': 1, 'files': current}, output, indent=2, sort_keys=True)
        print('Frozen inventory created. Bundle unchanged; no keys or permissions used.')
    else:
        expected = json.loads(args.manifest.read_text())
        if expected.get('format') != 1 or expected.get('files') != current:
            raise ValueError('Frozen release changed: do not use its previous authorization')
        print('PASS: frozen bundle matches all recorded files.')


if __name__ == '__main__':
    main()
