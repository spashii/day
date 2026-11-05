# Developing Day

## Setup

You need a Mac with Apple silicon, macOS 26 or later, a current Xcode with the iOS simulator runtime, and [Homebrew](https://brew.sh).

```sh
brew bundle            # xcodegen
tools/dev-identity.sh  # optional: a stable signing identity for development builds
```

Without `tools/dev-identity.sh`, the Mac app is signed ad hoc, and macOS treats every build as a new app, so the keychain asks for access again each time. The identity it creates, "Blend Dev", is shared with Blend and Voice.

`app/Day.xcodeproj`, every `Info.plist` and every `.entitlements` file are generated from `app/project.yml` and stay out of git.

## Build and run

```sh
tools/build.sh
open build/dd/Build/Products/Debug/Day.app --args -UseFixtures invented-week -Now 2026-11-04T12:10
```

`tools/build.sh` generates the project, builds the Mac app signed with "Blend Dev" when it exists, and builds the iPhone app and its widget for the simulator. Launch arguments, the invented week and the other scripts are in [ARCHITECTURE.md](ARCHITECTURE.md).

The Google client ID is the build setting `DAY_GOOGLE_CLIENT_ID` in `app/project.yml`, without the `.apps.googleusercontent.com` suffix. It becomes the Info.plist key `GoogleClientID` in the Mac app, the iPhone app and the widget, and the `com.googleusercontent.apps.<id>` URL scheme on the iPhone. While it holds the placeholder `000000000000-placeholder`, both apps run on the invented fixture.

To make a client, in the Google Cloud console with a personal account and a project of its own:

1. Enable the Google Calendar API.
2. Under Google Auth Platform, fill in Branding. The app name must not contain a Google product name.
3. Under Audience, choose External, then publish the app so its status is In production. In Testing, refresh tokens expire after 7 days.
4. Under Data Access, add `openid`, `userinfo.email` and `https://www.googleapis.com/auth/calendar.readonly`.
5. Under Clients, create an iOS client for bundle ID `io.github.spashii.day`. It has no secret, and the client ID is not one.

An unverified app shows Google's warning screen once per account and is capped at 100 users.

## Where Day keeps its data

Each account's Google sign-in is a keychain item under the service `io.github.spashii.day.google` (`DayIdentifiers.keychainService`). Events are plain files in the app's own folder: `~/Library/Application Support/Day` on the Mac, and the App Group container on the iPhone, where the widget reads the snapshot the app writes. If Day was deleted before its accounts were removed, search Keychain Access for the service name and delete the items. [ARCHITECTURE.md](ARCHITECTURE.md) has the rest.

## Tests

```sh
tools/test.sh                          # swift test in Core, on the Mac
cd Core && swift test --filter SummaryTests
```

The tests are in `Core/Tests/DayCoreTests`: golden tests for every table and example in the rules (the summary, the Lock Screen widget, the month marks, the day rows), merging across accounts, civil dates, midnight crossings, daylight saving, and decoding of recorded Google responses. Every person, address and account in them is invented.

`day-cli` prints a fixture's days through the same rules, so the text can be read without a simulator: `cd Core && swift run day-cli`.

## The icon

`app/AppIcon.icon` is an Icon Composer file: `icon.json` plus two SVG layers, a row of seven gray dots and one blue bar. The concept in one line: a week of gray dots and one bar. It is plain text, so it diffs like code. To see how the system will draw it:

```sh
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  app/AppIcon.icon --export-image --output-file icon.png --platform iOS \
  --rendition Default --width 1024 --height 1024 --scale 1
```

`--rendition` takes `Default`, `Dark`, `TintedLight`, `TintedDark`, `ClearLight` and `ClearDark`. The dark, tinted and clear renditions use the system's own backgrounds, with the bar and the dots on top, so the icon reads from shape and not from color. `site/icon.svg` is the same concept redrawn for the browser tab.

## Releases

```sh
tools/release.sh --dry-run
```

builds everything a release builds with no identity and no Apple account: it runs the tests, writes `build/release/Day-VERSION.dmg` signed ad hoc, and archives the iPhone app unsigned. Nothing is notarized or uploaded, and the feed and the cask stay as they are. Run it on the Mac, in a clone of the repository.

Every other mode stops with `Google client ID is still the placeholder` until `DAY_GOOGLE_CLIENT_ID` in `app/project.yml` is a real client ID. Both apps run on the invented fixture while it is the placeholder, so a release built that way would show people a calendar that is not theirs. After building, the script reads `GoogleClientID` out of the Mac app, and out of the iPhone app and its widget, and stops again if any of them is not the ID in `app/project.yml`.

`VERSION` is the marketing version on both platforms: raise it by a patch for fixes and by a minor for anything new. The build number is the number of commits (`git rev-list --count HEAD`), used as `CFBundleVersion` on both platforms and as `sparkle:version` in the update feed, so it rises with every commit.

### Mac

Day goes out exactly as [Blend](https://github.com/spashii/blend) does: a Developer ID signature, notarization, a disk image and a Sparkle update feed. Set up on each Mac, once, with Blend's `tools/release-identity.sh` (see its `docs/DEVELOPMENT.md`):

- the Developer ID Application identity in the keychain `blend-release`, unlocked by the password in `~/.blend-signing/keychain-password`, which is how a script over SSH can sign;
- the notarytool profile `blend-notary`;
- Sparkle's tools in `~/.blend-signing/sparkle-2.10.1` and the update signing key in `~/.blend-signing/sparkle-private-key`. Its public half is `SUPublicEDKey` in `app/project.yml`. Losing the key means installed copies can never take another update.

With those in place, `tools/release.sh --mac` signs the app and the Sparkle helpers inside it, notarizes and staples the app and the image, signs the image for Sparkle, and writes the release into `site/appcast.xml` and `Casks/day.rb` for you to read. `DAY_SIGN_ID` and `DAY_NOTARY_PROFILE` use an identity and profile from the login keychain instead.

### iPhone

The build goes to TestFlight through `xcodebuild archive` and `-exportArchive` with the method `app-store-connect`. Set up once:

1. At developer.apple.com, register the App IDs `io.github.spashii.day` and `io.github.spashii.day.widget`, and the App Group `group.io.github.spashii.day`, with the App Groups capability on both. Or sign in to Xcode once on the Mac so automatic signing registers them.
2. In App Store Connect, create the app record "Day" for iOS with the bundle ID `io.github.spashii.day`.
3. Create an App Store Connect API key (Users and Access, Integrations) and put the downloaded `AuthKey_KEYID.p8` in `~/.blend-signing/`, with the issuer ID in a file there called `asc-issuer-id`. `DAY_ASC_KEY`, `DAY_ASC_KEY_ID` and `DAY_ASC_ISSUER` name them elsewhere.
4. An Apple Distribution identity in the `blend-release` keychain, unless Xcode manages the certificate through the API key.

`tools/release.sh --iphone` then exports an `.ipa` into `build/release/iphone`. TestFlight builds expire after 90 days, so a release at least every 90 days keeps the phone app installed.

### Publishing

```sh
tools/release.sh --publish
```

It needs a clean checkout whose HEAD is pushed, `gh` logged in as `spashii`, and every credential above for the platforms it builds; it checks all of that before building anything. It runs the tests, uploads the iPhone build to TestFlight, creates GitHub release `vVERSION` with the disk image and its checksum, then commits and pushes `site/appcast.xml` and `Casks/day.rb`, in that order, so no Mac is offered an update that is not there yet. `--mac` and `--iphone` publish one platform: a failed upload is repeated with `--iphone --publish`.

Before the first release, check [site/WHAT-NOT-TO-CLAIM.md](../site/WHAT-NOT-TO-CLAIM.md) against the README, the site and the store listing. The repository starts private and goes public at the first Mac release.

### Homebrew

`Casks/day.rb` is a cask in this repository, so the repository is its own tap. To bring Day back on a freshly set up Mac, put these two lines in your Brewfile, for example the one in your dotfiles:

```ruby
tap "spashii/day", "https://github.com/spashii/day"
cask "spashii/day/day"
```

Until the first release the cask's checksum is a placeholder of zeros, so installing it fails on purpose.

## The site

`site/` is published to GitHub Pages by `.github/workflows/pages.yml` when it changes on main, without its Markdown files. The Day view on the front page is drawn in HTML and CSS from the invented week, so it needs no screenshots. `.github/workflows/build.yml` is `workflow_dispatch` only: a check that a clean Mac can test and build Day. It signs and uploads nothing, because releases are built on the Mac that holds the keys.

## The App Store

The listing is text in `fastlane/metadata/en-US`. `fastlane deliver` pushes the text and screenshots, and the binary comes from `tools/release.sh`. Copy `fastlane/api_key.json.example` to `fastlane/api_key.json` and point it at the API key. The App Review contact details and the demo account go in `fastlane/metadata/review_information/` as the files named in `fastlane/.gitignore`, which stay out of git. The demo account is a throwaway Google account with invented events.

The App Store needs Google's verification of the calendar scope first: a public homepage, the privacy page, a demo video of the consent flow, and a verified domain. `app/PrivacyInfo.xcprivacy` declares no tracking, no collected data and the one required-reason API the app uses, user defaults, with reason `CA92.1`.
