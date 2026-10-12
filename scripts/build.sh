#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 LayoutKeeper contributors
set -euo pipefail
project_dir="${0:A:h:h}"
# Optional target architecture: ./scripts/build.sh --arch arm64|x86_64 (or LAYOUTKEEPER_ARCH=...).
# Without it, builds for the host and writes build-products/LayoutKeeper.app as before.
# With it, writes build-products/<arch>/LayoutKeeper.app and build-products/<arch>/layoutkeeperctl.
arch="${LAYOUTKEEPER_ARCH:-}"
while (( $# > 0 )); do
  case "$1" in
    --arch) (( $# >= 2 )) || { print -u2 "--arch needs a value (arm64 or x86_64)"; exit 2; }; arch="$2"; shift 2 ;;
    --arch=*) arch="${1#--arch=}"; shift ;;
    -h|--help) print "Usage: scripts/build.sh [--arch arm64|x86_64]"; exit 0 ;;
    *) print -u2 "Unknown option: $1"; exit 2 ;;
  esac
done
case "$arch" in
  ""|arm64|x86_64) ;;
  *) print -u2 "Unsupported --arch '$arch' (use arm64 or x86_64)"; exit 2 ;;
esac
signing_identity="${SPACEPORT_SIGNING_IDENTITY:--}"
if [[ "$signing_identity" != "-" && "${SPACEPORT_ALLOW_KEYCHAIN_SIGNING:-0}" != "1" ]]; then
  print -u2 "Existing private-key signing requires explicit authorization. No build or keychain operation attempted."
  exit 3
fi
build_dir="${LAYOUTKEEPER_BUILD_DIR:-${SPACEPORT_BUILD_DIR:-$project_dir/.build}}"  # SPACEPORT_BUILD_DIR: legacy name
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/swift-cache"
cd "$project_dir"
swift_args=(-c release --disable-sandbox --scratch-path "$build_dir" --cache-path "$build_dir/cache")
out_dir="$project_dir/build-products"
if [[ -n "$arch" ]]; then
  swift_args+=(--arch "$arch")
  out_dir="$project_dir/build-products/$arch"
fi
swift build "${swift_args[@]}"
bin_dir="$(swift build "${swift_args[@]}" --show-bin-path)"
# Builds are candidates. Never overwrite the GUI bundle whose TCC grant is being used.
app_dir="$out_dir/LayoutKeeper.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
# Replace by rename so a running copy keeps its mapped (old) executable instead of crashing on modified pages.
cp "$bin_dir/LayoutKeeper" "$app_dir/Contents/MacOS/LayoutKeeper.new" && mv -f "$app_dir/Contents/MacOS/LayoutKeeper.new" "$app_dir/Contents/MacOS/LayoutKeeper"
cp "$bin_dir/layoutkeeperctl" "$out_dir/layoutkeeperctl.new" && mv -f "$out_dir/layoutkeeperctl.new" "$out_dir/layoutkeeperctl"
# Compatibility alias for the old CLI name (a symlink; the old spaceportctl binary, if any, is replaced by the link).
ln -sfn layoutkeeperctl "$out_dir/spaceportctl"
# Drop debug-symbol (stab) entries: they embed absolute build paths, which would leak the builder's home folder.
strip -S "$app_dir/Contents/MacOS/LayoutKeeper" "$out_dir/layoutkeeperctl"
cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns.new" && mv -f "$app_dir/Contents/Resources/AppIcon.icns.new" "$app_dir/Contents/Resources/AppIcon.icns"
cp "$project_dir/scripts/Info.plist" "$app_dir/Contents/Info.plist.new" && mv -f "$app_dir/Contents/Info.plist.new" "$app_dir/Contents/Info.plist"
# App icon. AppIcon.icns is the classic icon; macOS 26+ resolves CFBundleIconName from an asset catalog,
# so also compile Assets.car from the same artwork. Without actool, drop CFBundleIconName so it does not dangle.
icon_work="$(mktemp -d)"
if iconutil -c iconset "$project_dir/Resources/AppIcon.icns" -o "$icon_work/AppIcon.iconset" \
  && mkdir -p "$icon_work/Assets.xcassets/AppIcon.appiconset" "$icon_work/out" \
  && cp "$icon_work/AppIcon.iconset/"*.png "$icon_work/Assets.xcassets/AppIcon.appiconset/" \
  && print '{"info":{"author":"xcode","version":1}}' > "$icon_work/Assets.xcassets/Contents.json" \
  && { print '{"images":['
       first=1
       for size in 16 32 128 256 512; do for scale in 1 2; do
         suffix=""; (( scale == 2 )) && suffix="@2x"
         (( first )) || print ','
         first=0
         print "{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"${scale}x\",\"filename\":\"icon_${size}x${size}${suffix}.png\"}"
       done; done
       print '],"info":{"author":"xcode","version":1}}'; } > "$icon_work/Assets.xcassets/AppIcon.appiconset/Contents.json" \
  && xcrun actool --compile "$icon_work/out" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
       --output-partial-info-plist "$icon_work/partial.plist" "$icon_work/Assets.xcassets" >/dev/null \
  && [[ -f "$icon_work/out/Assets.car" ]]; then
  cp "$icon_work/out/Assets.car" "$app_dir/Contents/Resources/Assets.car.new" && mv -f "$app_dir/Contents/Resources/Assets.car.new" "$app_dir/Contents/Resources/Assets.car"
else
  print -u2 "warning: actool unavailable; bundling AppIcon.icns only and removing CFBundleIconName"
  rm -f "$app_dir/Contents/Resources/Assets.car"
  /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$app_dir/Contents/Info.plist" 2>/dev/null || true
fi
rm -rf "$icon_work"
codesign --force --sign "$signing_identity" --timestamp=none --identifier local.layoutkeeper.app "$app_dir"
codesign --verify --strict "$app_dir"
print "Built candidate $app_dir${arch:+ ($arch)}"
print "Nothing was installed. Older build-products/SpacePort.app (if present) is left untouched. Use scripts/install-local.py only for an intentional local update."
