# What not to claim

Every sentence on the site, in the README and in the App Store listing (`fastlane/metadata`) is true only because the code does it. Before adding a claim, find the code that makes it true. When a feature changes, change the copy in the same commit. This file is not published with the site.

## About Google

- Not "verified by Google", "approved by Google" or "official". The OAuth client is unverified, and Google shows its warning screen once per account. Say what the app says: "Google will flag it as unverified."
- Not "works with every Google account". A Google Workspace administrator can block apps that are not configured, and Day cannot know whether yours does. Say "Google accounts".
- Not "every calendar you have" without the limit: Day shows the calendars Google lists for each signed-in account, and a calendar you hide in Day stays in Google. The sentence in the README, on the site and in the store description is "Day shows the calendars Google lists for each of your accounts as one, read-only."
- Not "Google Calendar" as the app's name or in its Google consent-screen name, and no Google logos. "Google Calendar" appears only to say what Day reads and where edits open. Keep "not affiliated with Google" in the footer and in the store description.

## About what Day does

- Not "edit", "create", "manage", "plan", "schedule" or "RSVP". Day is read-only. Edits open in Google Calendar.
- Not "live", "instant" or "always up to date". iOS decides when a widget reloads. The widget shows its data's age when it is stale ("As of 9:12") and falls back to the last events it saved.
- Not "notifications" or "reminders". Version one has none.
- Not Apple Calendar, iCloud, Outlook or any calendar that is not Google's.
- Widgets: the iPhone Lock Screen and the Mac desktop (Today, in small, medium and large). No Home Screen, StandBy or Month widget.
- Not iPad, Apple Watch, Android or Windows.
- Not "AI", "smart" or "insights". Every line Day writes comes from fixed rules over event fields, with no language model.
- Not "join any call". Join covers links from Meet, Zoom, Teams, Webex and Whereby, and the video link Google attaches to an event.
- Not "every one-off event is named in the month". Recurring events are dots, and short one-off calls with colleagues are dots too (a single branch in `monthMark`; it goes if that choice is reversed).
- Not "all time zones handled" or a world clock. Times show in the device's zone, with one extra line when an event was written in a zone with a different offset.
- Not "works offline". Events already saved still show, with a line that says how old they are.
- Not VoiceOver or Dynamic Type claims, in the README or anywhere else, until they have been tested on a device.

## About where it is available

- Not "on the App Store" and no App Store badge, until the listing exists. The iPhone app ships through TestFlight first, and the App Store needs Google's verification and App Review.
- Not "signed and notarized" on any page until a release built by `tools/release.sh` with the Developer ID is actually up. The meta line on the site assumes it, so the site goes live with the first Mac release, not before.
- Not "Intel" or "any Mac". The Mac app is Apple silicon with macOS 26 or later. The iPhone app needs iOS 26.
- Not "free forever", "no ads forever" or any promise about the future. "Free and open source" describes the MIT-licensed code.

## About privacy

- Say the line exactly: "Day reads your calendars from Google and keeps them on this device. Day itself collects nothing. On the Mac, it also checks for updates through apps.idea2prod.in, which counts checks and downloads by app, version and country and never stores your IP address."
- Not "nothing leaves your device". Calendars go between the device and Google, and the Mac checks for updates through apps.idea2prod.in.
- Not "secure", "encrypted", "private by design" or "bank-level". The sign-in is in the keychain and the events are plain files in the app's own container. Say that, or say nothing.
- Not "deletes everything when you remove an account" until `AppModel.removeAccount` is checked to delete both the keychain item and the cached files. The privacy page says it does.
- The privacy page says the widgets read the same saved events and sign-in. If the widget starts fetching from Google by itself, the sentence is still true; add that it does, and keep the Limited Use line.
- Keep `app/PrivacyInfo.xcprivacy` and the App Store privacy answers ("Data Not Collected") saying the same as the privacy page.

## About people and other products

- No names of other calendar apps, no comparisons, no "better than". No user counts, ratings or quotes.
- No real names, companies, addresses or calendars in examples. The site, the screenshots and the store listing use the invented week (Maya, Acme, Lisbon).
