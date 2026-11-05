# What not to claim

Every sentence on the site, in the README and in the App Store listing (`fastlane/metadata`) is true only because the code does it. Before adding a claim, find the code that makes it true. When a feature changes, change the copy in the same commit. This file is not published with the site.

## About Google

- Not "verified by Google", "approved by Google" or "official". The OAuth client is unverified, and Google shows its warning screen once per account. Say what the app says: "Google will flag it as unverified."
- Not "works with every Google account". A Google Workspace administrator can block apps that are not configured, and Day cannot know whether yours does. Say "Google accounts".
- Not "every calendar you have" without the limit: Day shows the calendars Google lists for each signed-in account, and a calendar you hide in Day stays in Google. The sentence in the README, on the site and in the store description is "Day shows the calendars Google lists for each of your accounts as one, read-only."
- Not "Google Calendar" as the app's name or in its Google consent-screen name, and no Google logos. "Google Calendar" appears only to say what Day reads and where edits open. Keep "not affiliated with Google" in the footer and in the store description.

## About what Day does

- Not "edit", "create", "manage", "plan", "schedule" or "RSVP". Day is read-only. Edits open in Google Calendar.
- Not "live", "instant" or "always up to date". iOS decides when a widget reloads, and Google drops some change notices. The widget shows its data's age when it is stale ("As of 9:12") and falls back to the last events it saved.
- Not that reminders arrive at the same moment on every device. Each device schedules its own from what it last synced.
- Not Apple Calendar, iCloud calendars, Outlook or any calendar that is not Google's. iCloud is named only for the sign-in and the settings that sync between the person's devices.
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

- Say the line exactly: "Day reads your calendars from Google and keeps them on your devices. Your sign-in moves between them in iCloud Keychain, which is end-to-end encrypted. To pick up changes sooner, Google tells Day's server at apps.idea2prod.in that a calendar changed, never what changed, and the server keeps only random IDs, push addresses and the device type. On the Mac, Day also checks for updates through apps.idea2prod.in, which counts checks and downloads by app, version and country and never stores your IP address." The iPhone and the store listing carry it without its last sentence. "Day itself collects nothing" is no longer true and appears nowhere.
- Not "nothing leaves your device". Calendars go between the device and Google, the sign-in moves between the person's devices in iCloud Keychain, the shown/hidden toggles and icons sync through iCloud, Google's change notices reach Day's server, and the Mac checks for updates through apps.idea2prod.in.
- Not "secure", "private by design" or "bank-level". "End-to-end encrypted" is said only of the sign-in in iCloud Keychain, which is Apple's. The settings in the iCloud key-value store are ordinary iCloud data under coded keys, and the events are plain files in the app's own container.
- "Without iCloud Keychain it stays in this device's keychain" is an assumption about how synchronizable items behave with iCloud Keychain off; confirm it on a device before the iPhone ships.
- Not "deletes everything when you remove an account". The privacy page says removal takes out the sign-in, the saved events and the calendar settings from all the person's devices; that is `AppModel.removeAccount` here and `SyncEngine.reconcileAccounts` on each other device, on its next pass. Revoking at Google is retried until Google answers, but the page promises only the settings link.
- The privacy page says the widgets read the same saved events and sign-in. If the widget starts fetching from Google by itself, the sentence is still true; add that it does, and keep the Limited Use line.
- Keep `app/PrivacyInfo.xcprivacy` and the App Store privacy answers ("Data Not Linked to You": a device identifier, used to deliver updates to your calendars) saying the same as the privacy page.

## About people and other products

- No names of other calendar apps, no comparisons, no "better than". No user counts, ratings or quotes.
- No real names, companies, addresses or calendars in examples. The site, the screenshots and the store listing use the invented week (Maya, Acme, Lisbon).
