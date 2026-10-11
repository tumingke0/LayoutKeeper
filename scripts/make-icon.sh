#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 LayoutKeeper contributors
# Regenerates Resources/AppIcon.icns and docs/images/icon.png from scripts/make-icon.swift.
set -euo pipefail
project_dir="${0:A:h:h}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export CLANG_MODULE_CACHE_PATH="$work/clang-cache"
xcrun swiftc -O "$project_dir/scripts/make-icon.swift" -o "$work/make-icon"
"$work/make-icon" "$work/AppIcon.iconset" "$work/icon-1024.png"
mkdir -p "$project_dir/Resources"
iconutil -c icns "$work/AppIcon.iconset" -o "$project_dir/Resources/AppIcon.icns"
cp "$work/icon-1024.png" "$project_dir/docs/images/icon.png"
print "Wrote Resources/AppIcon.icns and docs/images/icon.png"
