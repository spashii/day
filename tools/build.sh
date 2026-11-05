#!/bin/zsh
# Builds Day for the Mac and for the iPhone simulator: tools/build.sh [NAME]
#
# From Linux it syncs the checkout to ~/build/NAME on the Mac (tools/sync.sh, NAME defaults
# to "day") and runs itself there. On the Mac it builds in place into build/dd: the Mac app
# signed with the "Blend Dev" identity from tools/dev-identity.sh when it exists, so a
# keychain item one build creates stays readable by the next (ad hoc otherwise, which macOS
# treats as a new app every build), and the iPhone app with its widget for the simulator,
# signed to run locally. That signature needs no Apple account and is what carries the App
# Group entitlement in the simulator; CODE_SIGNING_ALLOWED=NO drops it, and the widget then
# cannot read the snapshot the app writes.
set -euo pipefail
root=${0:A:h:h}
name=day
if [[ ${1:-} != -* && -n ${1:-} ]]; then
  name=$1
  shift
fi
if [[ $(uname) != Darwin ]]; then
  [[ -n ${DAY_MAC:-} ]] || { print -u2 "Set DAY_MAC to the ssh host of the Mac that builds Day."; exit 1; }
  $root/tools/sync.sh $name
  exec ssh $DAY_MAC "cd ~/build/$name && zsh -lic 'tools/build.sh ${(q)@}'"
fi

cd $root
version=$(<VERSION)
number=$(git rev-list --count HEAD 2>/dev/null || echo 1)

identity=-
keychain=
kc=~/Library/Keychains/blend-dev.keychain-db
if [[ -f $kc ]]; then
  security unlock-keychain -p blend-dev $kc
  identity="Blend Dev"
  keychain=$kc
fi

(cd app && xcodegen generate --quiet)
xcodebuild -project app/Day.xcodeproj -scheme DayMac -configuration Debug \
  -destination "platform=macOS,arch=arm64" -derivedDataPath build/dd -quiet \
  MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$number CODE_SIGN_IDENTITY="$identity" \
  ${keychain:+OTHER_CODE_SIGN_FLAGS=--keychain $keychain} build
xcodebuild -project app/Day.xcodeproj -scheme DayPhone -configuration Debug \
  -destination "generic/platform=iOS Simulator" -derivedDataPath build/dd -quiet \
  MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$number build
echo "mac: $root/build/dd/Build/Products/Debug/Day.app"
echo "iphone: $root/build/dd/Build/Products/Debug-iphonesimulator/Day.app"
