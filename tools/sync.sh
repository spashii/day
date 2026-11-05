#!/bin/zsh
# Copies this checkout from Linux to its own folder on the Mac: tools/sync.sh [NAME]
#
# NAME defaults to "day" and lands in ~/build/NAME on $DAY_MAC (default mac-air). Parallel
# work uses one name each, so no two builds share a folder or DerivedData. Build output,
# Swift package caches, the generated Xcode project, Info.plists and entitlements stay on the
# Mac untouched, so the next build is incremental. The private docs are not copied.
set -euo pipefail
root=${0:A:h:h}
name=${1:-day}
host=${DAY_MAC:-mac-air}
ssh $host "mkdir -p build/$name"
rsync -a --delete \
  --exclude .git --exclude .build --exclude build --exclude .dd --exclude .swiftpm \
  --exclude '*.xcodeproj' --exclude 'app/*/Info.plist' --exclude 'app/*/*.entitlements' \
  --exclude 'tools/shots/*/Info.plist' \
  --exclude docs/research --exclude docs/design --exclude docs/brief.md \
  --exclude docs/work-packages.json \
  $root/ $host:build/$name/
