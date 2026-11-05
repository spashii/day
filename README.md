# Day

All your Google calendars as one, on Mac and iPhone. Read-only; edits open in Google Calendar.

Day shows the calendars Google lists for each of your accounts as one, read-only. It answers three questions faster than Google Calendar does: what is next, what does today look like, and what big thing is coming. Everything else is one tap away in Google Calendar, which is why Day has no plus button.

- **The next event on the Lock Screen.** A widget in three sizes, above or below the clock, with the next event from every calendar. After the last event of the day it shows tomorrow's first one.
- **The month's big events by name.** Multi-day events are bars, one-offs that matter get a colored rule and a title, and recurring events are gray dots.
- **A menu bar item on the Mac.** The next event in the menu bar, and today in a panel, with Join on the current or next meeting.

## Features

- Several Google accounts at once, merged into one view. A calendar shared between accounts appears once, and an event on two calendars appears once.
- The calendars you see are the ones Google shows by default; a toggle per calendar hides the rest in Day without touching Google.
- Colors are Google's, mapped to the nearest system color, so light, dark and Increase Contrast come from the system.
- Day view with all-day events, an Earlier row that folds away what has ended, a red line for now, and gaps of an hour or more.
- Event sheet on iPhone and popover on Mac: time (with the zone it was written in, when that differs from yours), repeats, a Join button for Meet, Zoom, Teams, Webex and Whereby links, place, the guest list with everyone's answer, organizer first, the calendar, the description, and Open in Google Calendar.
- Reminders from your Google events, with Join on calls. Each Mac and iPhone has its own switch.
- Cached events show immediately and refresh quietly. When Google cannot be reached, a line says how old the events are. When Google signs an account out, a line says so, with Sign In Again.
- Light and dark follow the system.
- Mac: one window with the month and a day pane, Apple Calendar's keyboard shortcuts, and Open at login if you choose it.

Not in Day: editing or creating events, replying to invitations, search, a week view, Home Screen widgets, iPad, Apple Watch.

## Requirements

- Mac: Apple silicon, macOS 26 or later.
- iPhone: iOS 26 or later.
- A Google account.

## Install

**Mac.** Download the disk image from the [latest release](https://apps.idea2prod.in/day/download), open it, and drag Day to Applications. Or install it with Homebrew:

```sh
brew tap spashii/day https://github.com/spashii/day
brew trust spashii/day
brew install --cask day
```

Day is signed with a Developer ID and notarized, so macOS only asks whether to open an app downloaded from the internet. Click **Open**. Day updates itself, and Settings has Check for Updates.

**iPhone.** The iPhone app is distributed through TestFlight. It is not on the App Store yet. After installing it, press and hold the Lock Screen, choose Customize, and add the Next widget above or below the clock.

To build from source, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Using Day

1. **Add a Google account.** Day opens on a screen with one button, Add Google Account. Google will flag it as unverified. Choose Advanced, then continue to Day.
2. **Choose calendars.** Each account lists its calendars with a switch. Hidden calendars stay in Google.
3. **Read the day.** Day opens on today. Swipe sideways for other days, or go back to the month.
4. **Open in Google Calendar** from any event to edit it.

On the Mac, the keyboard follows Apple Calendar: Command-T for today, Shift-Command-T to go to a date, the arrow keys to move between days, Command-J to join the current or next meeting, Command-E to open the event in Google Calendar, and Command-R to refresh. Every shortcut is also in the menus.

## Privacy

**Mac.** Day reads your calendars from Google and keeps them on your devices. Your sign-in moves between them in iCloud Keychain, which is end-to-end encrypted. To pick up changes sooner, Google tells Day's server at apps.idea2prod.in that a calendar changed, never what changed, and the server keeps only random IDs, push addresses and the device type. On the Mac, Day also checks for updates through apps.idea2prod.in, which counts checks and downloads by app, version and country and never stores your IP address.

**iPhone.** Day reads your calendars from Google and keeps them on your devices. Your sign-in moves between them in iCloud Keychain, which is end-to-end encrypted. To pick up changes sooner, Google tells Day's server at apps.idea2prod.in that a calendar changed, never what changed, and the server keeps only random IDs, push addresses and the device type.

It has no analytics and no accounts of its own. Day asks Google for read-only access to your calendars and for your email address. The sign-in is kept in iCloud Keychain, or in the device's keychain without it. Which calendars you show, and their icons, sync through iCloud. Your events are stored in the app's own folder: `~/Library/Application Support/Day` on the Mac. The full text is in [site/privacy.html](https://apps.idea2prod.in/day/privacy.html).

## Uninstall

With Homebrew, `brew uninstall --zap --cask day` removes the app and its files. By hand, quit Day, move it to the Trash, and remove:

```sh
rm -rf ~/Library/Application\ Support/Day ~/Library/Caches/io.github.spashii.day
rm -f ~/Library/Preferences/io.github.spashii.day.plist
```

Remove your accounts in Day before deleting it, so their sign-ins leave the keychain. Removing an account removes it from all your devices: its sign-in, its saved events and its calendar settings. You can also end Day's access at any time from your Google account's security settings. On iPhone, delete the app.

## How it works

Day signs in to Google with read-only access and keeps your events on the device. One Swift package holds every rule that turns events into marks and rows, so the Mac app, the iPhone app and the Lock Screen widget always agree. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the details.

## License

MIT, see [LICENSE](LICENSE). The Mac app includes [Sparkle](https://sparkle-project.org); its license is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Day is not affiliated with or endorsed by Google. Google Calendar is a trademark of Google LLC.
