#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 LayoutKeeper contributors
# Usage: ./scripts/make-dmg.sh --arch arm64|x86_64
# Packages build-products/<arch>/LayoutKeeper.app into build-products/LayoutKeeper-<version>-<AppleSilicon|Intel>.dmg
# and runs the privacy gate on the app before and on the final dmg contents after packaging.
set -euo pipefail
cd "${0:A:h}/.."
[[ "${1:-}" == "--arch" && -n "${2:-}" ]] || { print -u2 "usage: $0 --arch arm64|x86_64"; exit 2 }
arch=$2
case $arch in arm64) name=AppleSilicon;; x86_64) name=Intel;; *) print -u2 "unknown arch $arch"; exit 2;; esac
app="build-products/$arch/LayoutKeeper.app"
[[ -d $app ]] || { print -u2 "missing $app; run ./scripts/build.sh --arch $arch first"; exit 1 }
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
python3 scripts/privacy-gate.py "$app"
dmg="build-products/LayoutKeeper-$version-$name.dmg"
stage=$(mktemp -d /tmp/lkdmg.XXXX)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/LayoutKeeper.app"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname "LayoutKeeper $version" -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg"
if ! python3 scripts/privacy-gate.py "$dmg"; then rm -f "$dmg"; print -u2 "removed $dmg"; exit 1; fi
shasum -a 256 "$dmg"
