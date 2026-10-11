#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 LayoutKeeper contributors
set -euo pipefail
project_dir="${0:A:h:h}"
signing_identity="${SPACEPORT_SIGNING_IDENTITY:--}"
if [[ "$signing_identity" != "-" && "${SPACEPORT_ALLOW_KEYCHAIN_SIGNING:-0}" != "1" ]]; then
  print -u2 "Existing private-key signing requires explicit authorization. No build or keychain operation attempted."
  exit 3
fi
build_dir="${LAYOUTKEEPER_BUILD_DIR:-${SPACEPORT_BUILD_DIR:-$project_dir/.build}}"  # SPACEPORT_BUILD_DIR: legacy name
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/swift-cache"
cd "$project_dir"
swift build -c release --disable-sandbox --scratch-path "$build_dir" --cache-path "$build_dir/cache"
bin_dir="$(swift build -c release --disable-sandbox --scratch-path "$build_dir" --cache-path "$build_dir/cache" --show-bin-path)"
# Builds are candidates. Never overwrite the GUI bundle whose TCC grant is being used.
app_dir="$project_dir/build-products/LayoutKeeper.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
# Replace by rename so a running copy keeps its mapped (old) executable instead of crashing on modified pages.
cp "$bin_dir/LayoutKeeper" "$app_dir/Contents/MacOS/LayoutKeeper.new" && mv -f "$app_dir/Contents/MacOS/LayoutKeeper.new" "$app_dir/Contents/MacOS/LayoutKeeper"
cp "$bin_dir/layoutkeeperctl" "$project_dir/build-products/layoutkeeperctl.new" && mv -f "$project_dir/build-products/layoutkeeperctl.new" "$project_dir/build-products/layoutkeeperctl"
# Compatibility alias for the old CLI name (a symlink; the old spaceportctl binary, if any, is replaced by the link).
ln -sfn layoutkeeperctl "$project_dir/build-products/spaceportctl"
cp "$project_dir/scripts/Info.plist" "$app_dir/Contents/Info.plist.new" && mv -f "$app_dir/Contents/Info.plist.new" "$app_dir/Contents/Info.plist"
codesign --force --sign "$signing_identity" --timestamp=none --identifier local.layoutkeeper.app "$app_dir"
codesign --verify --strict "$app_dir"
print "Built candidate $app_dir"
print "Nothing was installed. Older build-products/SpacePort.app (if present) is left untouched. Use scripts/install-local.py only for an intentional local update."
