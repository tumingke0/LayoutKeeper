#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 LayoutKeeper contributors
set -euo pipefail
project_dir="${0:A:h:h}"
build_dir="${LAYOUTKEEPER_BUILD_DIR:-${SPACEPORT_BUILD_DIR:-$project_dir/.build}}"  # SPACEPORT_BUILD_DIR: legacy name
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/swift-cache"
cd "$project_dir"
swift test --disable-sandbox --scratch-path "$build_dir" --cache-path "$build_dir/cache"
