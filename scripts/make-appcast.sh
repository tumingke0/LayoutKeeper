#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 LayoutKeeper contributors
# Usage: ./scripts/make-appcast.sh --arch arm64|x86_64 [--base-url URL] [--out DIR] [--app PATH]
# Zips build-products/<arch>/LayoutKeeper.app into LayoutKeeper-<version>-<AppleSilicon|Intel>.zip, signs it with the
# Sparkle EdDSA key from the login keychain (account "layoutkeeper") and writes appcast-<arch>.xml.
# Default base URL: https://github.com/tumingke0/LayoutKeeper/releases/download/v<version>
# Sparkle tools: SPARKLE_BIN, or .build/sparkle-tools/bin from the Sparkle release tarball (same version as Package.swift).
set -euo pipefail
cd "${0:A:h}/.."
arch="" base="" out="build-products" app=""
while (( $# > 0 )); do
  case "$1" in
    --arch) arch="$2"; shift 2 ;;
    --base-url) base="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --app) app="$2"; shift 2 ;;
    *) print -u2 "unknown option $1"; exit 2 ;;
  esac
done
case $arch in arm64) name=AppleSilicon;; x86_64) name=Intel;; *) print -u2 "usage: $0 --arch arm64|x86_64 [--base-url URL] [--out DIR]"; exit 2;; esac
bin="${SPARKLE_BIN:-.build/sparkle-tools/bin}"
[[ -x "$bin/sign_update" ]] || { print -u2 "missing $bin/sign_update (download the Sparkle release tarball into .build/sparkle-tools)"; exit 1 }
app="${app:-build-products/$arch/LayoutKeeper.app}"
[[ -d $app ]] || { print -u2 "missing $app; run ./scripts/build.sh --arch $arch first"; exit 1 }
plist="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")
minos=$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$plist")
base="${base:-https://github.com/tumingke0/LayoutKeeper/releases/download/v$version}"
python3 scripts/privacy-gate.py "$app"
mkdir -p "$out"
zip="$out/LayoutKeeper-$version-$name.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
# Release notes shown in the update dialog: short HTML from docs/releases/<version>.md, Chinese and English,
# embedded in the appcast (no GitHub page). Sparkle picks the description matching the app's language.
notes="docs/releases/$version.md"
[[ -f $notes ]] || { print -u2 "missing $notes"; exit 1 }
notes_en=$(python3 scripts/release-notes-html.py "$notes" --lang en --version "$version")
notes_zh=$(python3 scripts/release-notes-html.py "$notes" --lang zh --version "$version")
sig=$("$bin/sign_update" --account layoutkeeper "$zip")
[[ "$sig" == *edSignature=* ]] || { print -u2 "sign_update failed"; exit 1 }
cat > "$out/appcast-$arch.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>LayoutKeeper ($arch)</title>
    <link>https://github.com/tumingke0/LayoutKeeper</link>
    <item>
      <title>LayoutKeeper $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minos</sparkle:minimumSystemVersion>
      <description><![CDATA[$notes_en]]></description>
      <description xml:lang="en"><![CDATA[$notes_en]]></description>
      <description xml:lang="zh-Hans"><![CDATA[$notes_zh]]></description>
      <enclosure url="$base/${zip:t}" type="application/octet-stream" $sig />
    </item>
  </channel>
</rss>
XML
print "wrote $zip and $out/appcast-$arch.xml"
