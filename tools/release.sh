#!/bin/zsh
# Builds the release: tools/release.sh [--publish | --dry-run] [--mac | --iphone] [--skip-tests]
#
# Run it on the Mac, in a clone of the repository: releases are built there and never in CI.
#
# Mac: build/release/Day-VERSION.dmg with Day.app and its desktop widget. With the Developer
# ID set up (see docs/DEVELOPMENT.md) it signs the app, the widget and the Sparkle helpers
# inside it, notarizes and staples both the app and the image, signs the image for Sparkle,
# and writes the release into site/appcast.xml and Casks/day.rb. Without a Developer ID the
# image is signed ad hoc and the feed and the cask stay untouched.
# iPhone: an archive of the app with its widget, exported for App Store Connect. Without an
# App Store Connect key it stops at an unsigned archive, which still proves that it builds.
# Version numbers: VERSION is the marketing version on both platforms, and the commit count
# is the build number (CFBundleVersion, and sparkle:version in the feed), so it rises with
# every commit on one branch, which TestFlight and Sparkle both need.
# Google client: both apps fall back to the invented fixture week while DAY_GOOGLE_CLIENT_ID
# in app/project.yml is the placeholder. A release built that way would show every tester
# and every Mac a calendar that is not theirs, so anything but --dry-run stops until a real
# client ID is set, and checks the built Info.plist files again before packaging or upload.
#
#   --publish     uploads the iPhone build to TestFlight, then creates GitHub release vVERSION
#                 with the image, then commits and pushes the feed and the cask, in that order,
#                 so no Mac is offered an update that is not there yet. It needs a clean,
#                 pushed checkout, gh logged in as spashii, and every credential for the parts
#                 it builds; all of that is checked before anything is built.
#   --dry-run     builds with no identity and no Apple account, so nothing is notarized,
#                 uploaded or written to the feed. For a check that the release path builds. It
#                 is the only mode that accepts the placeholder Google client ID (see Google client above).
#   --mac, --iphone   build one platform only. An iPhone build can go to TestFlight without a
#                 Mac release, and a failed upload can be repeated with --iphone --publish.
#   --skip-tests  leaves out the DayCore tests; not allowed with --publish.
#
# Mac profile: the app claims the keychain group, the iCloud key-value store and push, which
# macOS lets run only with a Developer ID provisioning profile that grants them. The profile
# is $HOME/.blend-signing/Day_DeveloperID.provisionprofile, or DAY_MAC_PROFILE. It is checked
# before anything is built, installed for Xcode, embedded in the app, and the signed app is
# checked for the entitlements. Without it the app is built with the App Group alone, as the
# Debug build runs: --publish stops, anything else warns. The time-sensitive notification
# entitlement is the one exception: a profile made before the App ID had that capability
# lacks it, and then only that entitlement is left out, with a warning. A call's start
# notification arrives at the normal level, and the app keeps its keychain group, which
# falling back to the App Group alone would take from every signed-in account.
#
# Environment: DAY_SIGN_ID and DAY_NOTARY_PROFILE use an identity and a notarytool profile
# from your login keychain instead of the blend-release keychain. DAY_SPARKLE_DIR and
# DAY_SPARKLE_KEY locate Sparkle's tools and the update signing key. DAY_ASC_KEY,
# DAY_ASC_KEY_ID and DAY_ASC_ISSUER name an App Store Connect API key. DAY_RELEASES_URL is
# where the feed points. DAY_BUILD_NUMBER replaces the commit count outside a git checkout.
set -euo pipefail
root=${0:A:h:h}
cd $root

die() { print -u2 -- "$*"; exit 1 }

publish=false
dry=false
tests=true
only=
for arg in "$@"; do
  case $arg in
    --publish) publish=true ;;
    --dry-run) dry=true ;;
    --skip-tests) tests=false ;;
    --mac | --iphone)
      [[ -z $only || $only == ${arg#--} ]] || die "Use --mac or --iphone, not both."
      only=${arg#--} ;;
    *) die "usage: ${0:t} [--publish | --dry-run] [--mac | --iphone] [--skip-tests]" ;;
  esac
done
$publish && $dry && die "--publish and --dry-run cannot be combined."
$publish && ! $tests && die "A release runs the tests."
[[ $(uname) == Darwin ]] || die "Run this on the Mac: it needs Xcode, codesign and hdiutil."
doMac=true
doPhone=true
[[ $only == mac ]] && doPhone=false
[[ $only == iphone ]] && doMac=false

version=$(<VERSION)
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "VERSION must be semver, like 0.1.0: $version"

# The client ID is written without its .apps.googleusercontent.com suffix, as the apps expect.
placeholderClient=000000000000-placeholder
clientID=$(sed -nE 's/^[[:space:]]*DAY_GOOGLE_CLIENT_ID:[[:space:]]*"?([^"[:space:]#]*).*$/\1/p' \
  app/project.yml | head -1)
if ! $dry; then
  [[ -n $clientID ]] || die "DAY_GOOGLE_CLIENT_ID is missing from app/project.yml."
  [[ $clientID != $placeholderClient ]] ||
    die "Google client ID is still the placeholder: set DAY_GOOGLE_CLIENT_ID in app/project.yml, or use --dry-run."
  [[ $clientID =~ '^[A-Za-z0-9-]+$' ]] ||
    die "DAY_GOOGLE_CLIENT_ID in app/project.yml is not a client ID without .apps.googleusercontent.com: $clientID"
fi

# The same check on what was built: a build setting given on the command line, or a stale
# generated project, would otherwise get past the one above.
requireClient() {
  $dry && return 0
  local plist id
  for plist in "$@"; do
    [[ -f $plist ]] || die "Missing $plist: cannot check the Google client ID."
    id=$(plutil -extract GoogleClientID raw -o - $plist) || die "$plist has no GoogleClientID."
    [[ $id != $placeholderClient* ]] || die "Google client ID is still the placeholder in $plist."
    [[ $id == $clientID.apps.googleusercontent.com ]] ||
      die "$plist has GoogleClientID $id, not the one in app/project.yml."
  done
}

# Only a git checkout knows the commit count. In a copy without one, such as the folder
# tools/sync.sh fills, the number is DAY_BUILD_NUMBER or 1, and nothing can be published.
if [[ -n ${DAY_BUILD_NUMBER:-} ]]; then
  $publish && die "DAY_BUILD_NUMBER is for copies without git; a release uses the commit count."
  number=$DAY_BUILD_NUMBER
elif number=$(git rev-list --count HEAD 2>/dev/null); then
  :
else
  $publish && die "Publishing needs a git checkout."
  number=1
fi

signing=$HOME/.blend-signing
kc=$HOME/Library/Keychains/blend-release.keychain-db

# Credentials. The Mac needs a Developer ID Application identity and a notarytool profile;
# the iPhone needs an App Store Connect API key (AuthKey_KEYID.p8 and the issuer ID).
identity=-
profile=
keychainFlags=()
if ! $dry; then
  if [[ -n ${DAY_SIGN_ID:-} ]]; then
    identity=$DAY_SIGN_ID
    profile=${DAY_NOTARY_PROFILE:-}
  elif [[ -f $kc ]]; then
    security unlock-keychain -p "$(<$signing/keychain-password)" $kc
    identity=$(security find-identity -v -p codesigning $kc |
      sed -nE 's/.*"(Developer ID Application: .*)"$/\1/p' | head -1)
    [[ -n $identity ]] || identity=-
    profile=${DAY_NOTARY_PROFILE:-blend-notary}
    keychainFlags=(--keychain $kc)
  fi
fi
sparkle=${DAY_SPARKLE_DIR:-$signing/sparkle-2.10.1}
sparkleKey=${DAY_SPARKLE_KEY:-$signing/sparkle-private-key}
canNotarize=false
if [[ $identity == Developer\ ID\ Application:* && -n $profile ]]; then
  canNotarize=true
fi
canFeed=false
if $canNotarize && [[ -f $sparkleKey && -x $sparkle/bin/sign_update ]]; then
  canFeed=true
fi

# The Mac provisioning profile (see Mac profile above). `macProfileName` stays empty without
# one, and the build then claims the App Group alone (Mac/DayNoProfile.entitlements).
macProfile=${DAY_MAC_PROFILE:-$signing/Day_DeveloperID.provisionprofile}
macProfileName=
macProfileProblem=
macTimeSensitive=false
if $doMac && ! $dry; then
  if [[ ! -f $macProfile ]]; then
    macProfileProblem="no Developer ID provisioning profile at $macProfile (DAY_MAC_PROFILE)"
  else
    macProfilePlist=$(mktemp -t day-profile)
    if ! security cms -D -i $macProfile > $macProfilePlist 2>/dev/null; then
      macProfileProblem="$macProfile is not a provisioning profile"
    else
      # The profile has to grant every entitlement the app claims, for this app, and be valid.
      pb=/usr/libexec/PlistBuddy
      profileValue() { $pb -c "Print :$1" $macProfilePlist 2>/dev/null || true }
      if [[ $(profileValue Entitlements:com.apple.application-identifier) != JMCP69LCSU.io.github.spashii.day ]]; then
        macProfileProblem="$macProfile is not for JMCP69LCSU.io.github.spashii.day"
      fi
      for key in keychain-access-groups com.apple.security.application-groups \
        com.apple.developer.ubiquity-kvstore-identifier com.apple.developer.aps-environment; do
        [[ -n $(profileValue Entitlements:$key) ]] ||
          macProfileProblem="$macProfile does not grant $key"
      done
      [[ $(profileValue Entitlements:com.apple.developer.aps-environment) == production ]] ||
        macProfileProblem="$macProfile does not grant push in production"
      [[ $(profileValue Entitlements:com.apple.developer.usernotifications.time-sensitive) == true ]] &&
        macTimeSensitive=true
      expires=$(plutil -extract ExpirationDate raw -o - $macProfilePlist 2>/dev/null || true)
      [[ -n $expires && $(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' $expires +%s 2>/dev/null || echo 0) -gt $(date +%s) ]] ||
        macProfileProblem="$macProfile has expired"
      if [[ -z $macProfileProblem ]]; then
        macProfileName=$(profileValue Name)
        macProfileUUID=$(profileValue UUID)
        for dir in "$HOME/Library/MobileDevice/Provisioning Profiles" \
          "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
          mkdir -p $dir
          cp $macProfile "$dir/$macProfileUUID.provisionprofile"
        done
      fi
    fi
    rm -f $macProfilePlist
  fi
  if [[ -n $macProfileProblem ]]; then
    $publish && die "Not published: $macProfileProblem."
    print -u2 -- "warning: $macProfileProblem; the Mac app is built without keychain sharing, iCloud settings and push."
  fi
fi

ascKey=
ascKeyID=
ascIssuer=
if ! $dry; then
  ascKey=${DAY_ASC_KEY:-}
  ascKeyID=${DAY_ASC_KEY_ID:-}
  ascIssuer=${DAY_ASC_ISSUER:-}
  if [[ -z $ascKey ]]; then
    keys=($signing/AuthKey_*.p8(N))
    ascKey=${keys[1]:-}
  fi
  if [[ -n $ascKey && -z $ascKeyID ]]; then
    ascKeyID=${${ascKey:t:r}#AuthKey_}
  fi
  if [[ -z $ascIssuer && -f $signing/asc-issuer-id ]]; then
    ascIssuer=$(<$signing/asc-issuer-id)
  fi
fi
canUpload=false
if [[ -f $ascKey && -n $ascKeyID && -n $ascIssuer ]]; then
  canUpload=true
fi

releases=${DAY_RELEASES_URL:-https://github.com/spashii/day/releases/download}

if $publish; then
  # The release is built from HEAD and tagged there, so HEAD has to be exactly what is on
  # GitHub. These checks fail when GitHub cannot be reached, rather than passing.
  [[ -z $(git status --porcelain) ]] || die "Commit everything first. A release that was built earlier without --publish leaves site/appcast.xml and Casks/day.rb changed; git restore them."
  git fetch -q origin
  [[ $(git rev-parse HEAD) == $(git rev-parse "@{u}") ]] || die "Push HEAD first."
  gh auth status >/dev/null
  [[ $(gh api user -q .login) == spashii ]] || die "gh is not logged in as spashii."
  if $doMac; then
    if [[ -n $(gh release list --json tagName -q ".[] | select(.tagName == \"v$version\")") ]]; then
      die "v$version is already released; raise VERSION."
    fi
    $canFeed || die "Not published: a Mac release needs the Developer ID, a notarytool profile and the update key."
    [[ -n $macProfileName ]] || die "Not published: the Mac app needs a Developer ID provisioning profile (${macProfileProblem:-none found})."
  fi
  if $doPhone; then
    $canUpload || die "Not published: the iPhone build needs an App Store Connect key in $signing (AuthKey_KEYID.p8 and asc-issuer-id)."
  fi
fi

out=$root/build/release
mkdir -p $out
# Each platform clears only its own output, so --iphone after --mac keeps the image.
if $doMac; then
  rm -rf $out/xcode-mac $out/stage $out/Day.zip $out/Day-*.dmg*(N)
fi
if $doPhone; then
  rm -rf $out/xcode-iphone $out/Day.xcarchive $out/iphone $out/ExportOptions.plist
fi

# notarytool exits 0 even when Apple rejects the file, so the status is checked here and a
# rejection prints Apple's reasons.
notarize() {
  local result id
  result=$(xcrun notarytool submit $1 --keychain-profile $profile $keychainFlags --wait \
    --output-format json)
  id=$(print -r -- $result | plutil -extract id raw -o - -)
  if [[ $(print -r -- $result | plutil -extract status raw -o - -) != Accepted ]]; then
    xcrun notarytool log $id --keychain-profile $profile $keychainFlags >&2
    return 1
  fi
  echo "notarized: ${1:t} ($id)"
}

if $tests; then
  (cd Core && swift test)
fi

(cd app && xcodegen generate --quiet)

buildMac() {
  # Hardened runtime and a timestamp only go with a Developer ID. Without one, library
  # validation would refuse Sparkle in the ad hoc app, so the app is built without it.
  local flags=() signFlags=()
  if [[ $identity == Developer\ ID\ Application:* ]]; then
    signFlags=(--timestamp $keychainFlags)
  else
    flags=(ENABLE_HARDENED_RUNTIME=NO)
    [[ $identity != - ]] && signFlags=($keychainFlags)
  fi
  # The profile's name reaches only the app (app/project.yml); a build setting given here
  # would reach the widget too.
  local profileFlags=()
  if [[ -n $macProfileName ]]; then
    profileFlags=(DAY_MAC_PROFILE_NAME="$macProfileName")
    if ! $macTimeSensitive; then
      # Xcode refuses an entitlement the profile does not grant, and macOS would kill the
      # app for it, so it goes and everything else the profile grants stays.
      print -u2 -- "warning: $macProfile does not grant time-sensitive notifications; the Mac app is built without them, and a call's start notification arrives at the normal level. Regenerate the profile after enabling Time Sensitive Notifications on the App ID."
      cp app/Mac/Day.entitlements app/Mac/DayNoTimeSensitive.entitlements
      /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.usernotifications.time-sensitive' \
        app/Mac/DayNoTimeSensitive.entitlements
      profileFlags+=(DAY_MAC_ENTITLEMENTS=Mac/DayNoTimeSensitive.entitlements)
    fi
  else
    print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.application-groups</key><array><string>JMCP69LCSU.io.github.spashii.day</string></array></dict></plist>' \
      > app/Mac/DayNoProfile.entitlements
    profileFlags=(DAY_MAC_ENTITLEMENTS=Mac/DayNoProfile.entitlements)
  fi
  xcodebuild -project app/Day.xcodeproj -scheme DayMac -configuration Release \
    -destination "platform=macOS,arch=arm64" -derivedDataPath $out/xcode-mac -quiet \
    MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$number $profileFlags \
    CODE_SIGN_IDENTITY="$identity" ${signFlags:+OTHER_CODE_SIGN_FLAGS="$signFlags"} $flags build
  local app=$out/xcode-mac/Build/Products/Release/Day.app
  requireClient $app/Contents/Info.plist
  if [[ -n $macProfileName ]]; then
    [[ -f $app/Contents/embedded.provisionprofile ]] ||
      die "$app has no embedded.provisionprofile: Xcode did not embed $macProfileName."
    local claimed key
    claimed=$(codesign -d --entitlements - $app 2>&1 || true)
    local wanted=(keychain-access-groups com.apple.developer.ubiquity-kvstore-identifier
      com.apple.developer.aps-environment)
    $macTimeSensitive && wanted+=(com.apple.developer.usernotifications.time-sensitive)
    for key in $wanted; do
      [[ $claimed == *$key* ]] || die "$app does not carry $key; the profile $macProfileName was not applied."
    done
  fi
  # Xcode signs the Sparkle framework it embeds but not the helpers inside it, and
  # notarization needs every one signed with the Developer ID. This is the order Sparkle's
  # documentation gives for an app that is not sandboxed; the app is signed again last, since
  # its signature covers the framework's.
  local framework=$app/Contents/Frameworks/Sparkle.framework
  if [[ $identity != - && -d $framework ]]; then
    local helpers=$framework/Versions/B code
    local runtime=()
    [[ $identity == Developer\ ID\ Application:* ]] && runtime=(--options runtime)
    for code in $helpers/XPCServices/Installer.xpc $helpers/XPCServices/Downloader.xpc \
      $helpers/Autoupdate $helpers/Updater.app $framework $app; do
      [[ -e $code ]] || continue
      codesign --force --sign "$identity" $runtime --preserve-metadata=entitlements \
        $signFlags $code
    done
  fi
  codesign --verify --deep --strict $app
  # Notarization rejects an app, or any code inside it such as the desktop widget, that
  # carries the debugger entitlement; project.yml keeps it out of Release, and this keeps a
  # change there from reaching a release unnoticed.
  local entitlements signed
  for signed in $app $app/Contents/PlugIns/*.appex(N); do
    entitlements=$(codesign -d --entitlements - $signed 2>&1 || true)
    [[ $entitlements != *get-task-allow* ]] ||
      die "$signed carries the get-task-allow entitlement; a release cannot be notarized."
  done

  local stage=$out/stage
  mkdir -p $stage
  ditto $app $stage/Day.app
  # The app gets its own ticket, so it opens without a network check once copied out of
  # the image.
  if $canNotarize; then
    ditto -c -k --keepParent $stage/Day.app $out/Day.zip
    notarize $out/Day.zip
    xcrun stapler staple $stage/Day.app
    rm $out/Day.zip
    spctl --assess --type execute -v $stage/Day.app
  fi
  ln -s /Applications $stage/Applications
  dmg=$out/Day-$version.dmg
  # LZFSE rather than zlib: hdiutil writes some apps into a zlib image that it cannot read
  # back, while exiting 0. The image is verified either way, so a broken one stops here and
  # never reaches notarization or the feed.
  hdiutil create -quiet -volname "Day $version" -srcfolder $stage -fs HFS+ -format ULFO -ov $dmg
  hdiutil verify -quiet $dmg || die "hdiutil wrote an unreadable image: $dmg"
  if [[ $identity != - ]]; then
    codesign --sign "$identity" $signFlags $dmg
  fi
  if $canNotarize; then
    notarize $dmg
    xcrun stapler staple $dmg
    spctl --assess --type open --context context:primary-signature -v $dmg
  fi
  (cd $out && shasum -a 256 ${dmg:t} | tee ${dmg:t}.sha256)
}

# A notarized image becomes the newest entry in the update feed and the Homebrew cask. Both
# are files in the repo, published by committing them with the GitHub release. The feed
# entry is keyed by build number, so building the same commit twice replaces its own entry.
updateFeed() {
  local signature item sha
  signature=$($sparkle/bin/sign_update --ed-key-file $sparkleKey $dmg)
  item="    <item>
      <title>Day $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$number</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure url=\"$releases/v$version/${dmg:t}\" $signature type=\"application/octet-stream\"/>
    </item>"
  ITEM=$item BUILD=$number perl -0pi -e '
    s{\s*<item>(?:(?!</item>).)*<sparkle:version>\Q$ENV{BUILD}\E</sparkle:version>.*?</item>}{}s;
    s{(<!-- tools/release.sh adds each release below this line. -->)}{$1\n$ENV{ITEM}}' site/appcast.xml
  sha=$(cut -d' ' -f1 $dmg.sha256)
  sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" \
    Casks/day.rb
}

# The archive carries the widget. With an App Store Connect key it is signed by Xcode's
# automatic signing, which registers and downloads profiles through that key; without one it
# is archived unsigned, which checks that it builds and nothing more.
archivePhone() {
  local common=(-project app/Day.xcodeproj -scheme DayPhone -configuration Release
    -destination "generic/platform=iOS" -derivedDataPath $out/xcode-iphone -archivePath $out/Day.xcarchive
    -quiet MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$number)
  if $canUpload; then
    if [[ -f $kc && -f $signing/keychain-password ]]; then
      security unlock-keychain -p "$(<$signing/keychain-password)" $kc
    fi
    xcodebuild archive $common -allowProvisioningUpdates \
      -authenticationKeyPath $ascKey -authenticationKeyID $ascKeyID \
      -authenticationKeyIssuerID $ascIssuer
  else
    xcodebuild archive $common CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
    echo "iphone: archived unsigned; no TestFlight build without an App Store Connect key."
  fi
  local phoneApp=$out/Day.xcarchive/Products/Applications/Day.app
  requireClient $phoneApp/Info.plist $phoneApp/PlugIns/DayWidget.appex/Info.plist
}

# destination is export (an .ipa in build/release/iphone) or upload (straight to App Store
# Connect, where the build appears in TestFlight once it has been processed). The build
# number is fixed above, so Xcode must not choose its own.
exportPhone() {
  local destination=$1
  cat >$out/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$destination</string>
  <key>teamID</key><string>JMCP69LCSU</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
EOF
  plutil -lint $out/ExportOptions.plist >/dev/null
  xcodebuild -exportArchive -archivePath $out/Day.xcarchive -exportPath $out/iphone \
    -exportOptionsPlist $out/ExportOptions.plist -allowProvisioningUpdates \
    -authenticationKeyPath $ascKey -authenticationKeyID $ascKeyID \
    -authenticationKeyIssuerID $ascIssuer
}

dmg=
if $doMac; then
  buildMac
  if $canFeed; then
    updateFeed
  fi
fi
if $doPhone; then
  archivePhone
  if $canUpload && ! $publish; then
    exportPhone export
    echo "iphone: $out/iphone/Day.ipa"
  fi
fi

if $publish; then
  # The iPhone build goes first: it is the part most likely to fail, and a TestFlight build
  # reaches only invited testers, where a Mac release reaches everyone.
  if $doPhone; then
    exportPhone upload
    echo "Uploaded build $number to App Store Connect; it shows in TestFlight after processing."
  fi
  if $doMac; then
    # The image goes up before the feed that offers it.
    gh release create v$version $dmg $dmg.sha256 --target $(git rev-parse HEAD) \
      --title "Day $version" --generate-notes
    git commit -q -m "chore: release $version" site/appcast.xml Casks/day.rb
    git push -q
  fi
  echo "Published v$version."
elif $doMac && $canFeed; then
  echo "Updated site/appcast.xml and Casks/day.rb; tools/release.sh --publish uploads and pushes."
fi
if [[ -n $dmg ]]; then
  echo "$dmg"
fi
