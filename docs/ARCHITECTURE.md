# Architecture

Day shows the calendars Google lists for each of your accounts as one, read-only, on iPhone and Mac. This page is the map of the code and the contracts the pieces build against.

## Layout

```
Core/                       Swift package, Foundation only
  Package.swift             DayCore (library), day-cli (executable), DayCoreTests
  Sources/DayCore/
    Model/                  the types every target shares
    Google/                 OAuth with PKCE, token store protocol, Calendar API client, decoding
    Sync/                   fetch window, cache files, widget snapshot file
    Rules/                  pure functions from events to marks, rows and text
  Sources/day-cli/          prints a fixture's days through the rules
  Tests/DayCoreTests/
    Fixtures/               invented-week.json and recorded Google responses (all invented)
app/
  project.yml               XcodeGen: DayMac, DayPhone, DayWidget
  Shared/Model/             CalendarStore, FixtureStore, AppModel, KeychainTokenStore, Routes, Colors
  Shared/Views/             Month, Day, Event, Accounts, States; used by both apps
  Shared/Resources/         Localizable.xcstrings
  iPhone/                   iPhone entry point and shell
  Mac/                      Mac entry point, window, menu bar, settings, updates
  Widget/                   the Lock Screen widget "Next"
  AppIcon.icon              Icon Composer icon, picked up by project.yml when present
  PrivacyInfo.xcprivacy     privacy manifest, picked up when present
tools/                      sync.sh, build.sh, test.sh, release scripts
```

Generated files stay out of git: `app/Day.xcodeproj`, every `Info.plist` and `.entitlements` under `app/`, and `build/`. `app/project.yml` is the only place their contents are written.

## Targets

| Target | Product | Sources | Notes |
|---|---|---|---|
| `DayMac` | `Day.app`, `io.github.spashii.day`, macOS 26 | `app/Mac`, `app/Shared` | Regular app with a Dock icon, unsandboxed, no App Group. Sparkle 2.10.1 pinned exactly. Debug is signed with the "Blend Dev" identity when it exists (`tools/build.sh`), ad hoc otherwise. The hardened runtime is off in Debug, because library validation refuses Sparkle under a certificate with no team; Release keeps it for notarization. |
| `DayPhone` | `Day.app`, `io.github.spashii.day`, iOS 26, iPhone only | `app/iPhone`, `app/Shared` | App Group `group.io.github.spashii.day`, URL schemes `day` and the reversed Google client ID, background fetch with task `io.github.spashii.day.refresh`. Embeds the widget. |
| `DayWidget` | `DayWidget.appex`, `io.github.spashii.day.widget` | `app/Widget`, `app/Shared/Model/KeychainTokenStore.swift` | Same App Group, no Data Protection entitlement (it would hide the widget while the phone is locked). Does not compile the shared views or stores. |

All three link `DayCore` and bundle `invented-week.json`. Swift 6 language mode everywhere, with no default actor isolation: Core is `Sendable` and nonisolated, `CalendarStore` and its implementations are `@MainActor`.

The Google OAuth client ID is the build setting `DAY_GOOGLE_CLIENT_ID` in `project.yml`, without its `.apps.googleusercontent.com` suffix. It becomes the Info.plist key `GoogleClientID` in all three targets and the `com.googleusercontent.apps.<id>` URL scheme on the iPhone. While it holds the placeholder `000000000000-placeholder`, both apps run on the fixture.

Simulator builds are signed to run locally (no Apple account needed). That signature carries the App Group entitlement; `CODE_SIGNING_ALLOWED=NO` drops it and the widget can no longer read the app's snapshot.

## Model

`Core/Sources/DayCore/Model/`, all `Codable`, `Hashable`, `Sendable`. These are the contract: change them only together with every caller.

- `AccountID(sub:)`, encoded as a bare string. `Account { id, email, addedAt, signedOut }`, with `domain` and `isConsumer`.
- `CalendarID(account:googleID:)`, with `isHoliday`. `CalendarInfo { id, name, colorHex, selected, isPrimary, accessRole, timeZone, labels }`, with `colorKey`. `LabelInfo { name, colorHex }`. `AccessRole` is ordered so the highest wins.
- `CivilDate { year, month, day }`: a wall-calendar day with no zone, encoded as `"2026-11-04"`, `Strideable` so a `ClosedRange<CivilDate>` is a collection of days. `init(_:in:)` and `date(in:)` take a `TimeZone` or a `Calendar`. All-day events are civil dates with an exclusive end, never a `Date` at UTC midnight.
- `EventTime`: `.allDay(start:endExclusive:)` or `.timed(start:end:authoredZone:)`, with `start(in:)`, `end(in:)` and `interval(in:)`.
- `EventKind` (Google's `eventType`), `EventStatus`, `Response` (`none` means no guest list; compare optionals against `Response.none` explicitly).
- `EventID(calendar:googleID:)`. `Event { id, iCalUID, originalStart, title, time, kind, status, isRecurring, response, isOrganizer, attendeeCount, attendeeDomains, isFree, location, joinURL, htmlLink, description, colorKey, calendars }`. `attendeeDomains` holds the guests' email domains except the account holder's own address and rooms; month rule 4 needs it to tell outside guests from colleagues. `description` is plain text. Missing keys decode to defaults, so a cache written before a field existed still loads.
- `ColorKey`: the 13 system colors. `ColorKey(hex:)` maps Google's hex by hue, with low chroma to gray and dark muted oranges to brown. Decoding uses it for events; the accounts list uses it for calendars. `Colors.swift` in the app turns a key into a SwiftUI `Color`.
- Rule results (`RuleOutputs.swift`): `MonthMark`, `Summary { first, second }`, `NextEvents { current, next }`, `DayRow`, `WidgetEntry`, `RectangularLines`, `WhenLine`, `CircularContent`, `MenuBarLabel`.
- `WidgetSnapshot { fetchedAt, accountCount, signedOutAccounts, events }` (`Snapshot.swift`), the contents of `widget-snapshot.json`. Sync reads and writes the file (atomic replace, newer `fetchedAt` wins) in extensions of this type; it is declared once, here.
- `DayLink`: `day://day/<yyyy-mm-dd>` and `day://event/<sub>/<calendar>/<event>`, every component percent-encoded because calendar IDs carry `#`, `@` and `+`. The widget builds these and the app's `onOpenURL` parses them with the same type.
- `DayIdentifiers`: bundle IDs, App Group, URL scheme, widget kind, keychain service, refresh task, the client ID key and its placeholder.
- `DayJSON`: the one encoder and decoder (ISO 8601 dates, sorted keys) for fixtures, cache files and the snapshot.
- `Fixture { timeZone, locale, now, fetchedAt, accounts, calendars, events }` with `load(from:)` and `calendar`.

## Rules

`Core/Sources/DayCore/Rules/`, pure functions with no I/O. Every surface calls these and none recomputes their logic.

```swift
func merged(_ events: [Event]) -> [Event]
func monthMark(_ event: Event, account: Account, calendar: CalendarInfo, in local: Calendar) -> MonthMark
func coveredDays(_ event: Event, calendar: Calendar) -> ClosedRange<CivilDate>
func summarize(day: CivilDate, events: [Event], now: Date, calendar: Calendar) -> Summary
func nextEvents(events: [Event], now: Date, calendar: Calendar) -> NextEvents
func joinableEvent(next: NextEvents, now: Date) -> Event?
func dayRows(day: CivilDate, events: [Event], now: Date, calendar: Calendar) -> [DayRow]
func widgetTimeline(events: [Event], now: Date, fetchedAt: Date, signedOutAccounts: Int, calendar: Calendar) -> [WidgetEntry]
func noAccountWidgetEntry(now: Date, calendar: Calendar) -> WidgetEntry
func menuBarLabel(next: NextEvents, now: Date, calendar: Calendar) -> MenuBarLabel
enum Formatting  // count words, times, durations, day and month titles, event sheet lines, Earlier line, place
```

What each shape carries, where it is not obvious:

- `merged` keeps input order as the last tiebreak, so pass events in account order, first-added account first.
- `monthMark` takes the reader's `Calendar`, because whether a timed event covers a second day (it must run past 05:00 there) depends on the zone. Rule 5, short internal one-offs as dots, is the single branch at the end of the function; deleting it titles them.
- `summarize` and `dayRows` want the day's events plus the next day's, which sentence two may name. `CalendarStore.dayEvents(_:)` returns exactly that.
- `DayRow` has `allDay(Event, position:)`, `allDayMore(String)` for `2 more`, `earlier([Event])` (its text is `Formatting.earlier`), `nowLine(Date)`, `event(Event, secondLine:showsJoin:)` and `gap(String, start:)`. Its `id` is stable across minutes, so the `List` animates inserts and removals only.
- `WidgetEntry.url` is the inline and circular tap (today); `RectangularLines.url` is the rectangular tap (the event sheet). `WhenLine` carries the clock text, the start to render with `.reference(to:)` when within the hour, and the Always-On form. Line 3 is `RectangularLines.after`.
- `MenuBarLabel` carries whether the symbol shows and the text, because the quiet state shows both.
- Times are `H:mm` in 24-hour locales (`9:30`, `14:00`) and the system's own form in 12-hour ones. `Formatting` holds every such string: `clock`, `countdown`, `free`, `more`, `dayTime`, `until`, `signedOut` and `truncated` (the menu bar title, cut with an ellipsis).
- `widgetTimeline` puts entries at every candidate start and end in the next 24 hours, at local midnight, an hour before each start (where `in 60 min` begins), and where the snapshot turns 2 and 24 hours old (`As of`, `Open to update`). Changes less than 5 minutes apart share one entry, at the later time.

## Stores

`app/Shared/Model/CalendarStore.swift` is what every view reads:

```swift
@MainActor protocol CalendarStore: AnyObject, Observable {
    var accounts: [Account] { get }
    var calendars: [CalendarInfo] { get }
    var status: StoreStatus { get }          // .current, .loading, .offline, .unreachable
    var lastFetchedAt: Date? { get }
    var now: Date { get }                    // the clock every rule runs on
    var calendar: Calendar { get }           // the zone and locale every rule runs in
    func events(in days: ClosedRange<CivilDate>) -> [Event]
    func isVisible(_ calendar: CalendarID) -> Bool
    func setVisible(_ visible: Bool, calendar: CalendarID)
    func refresh() async
    func addAccount(using session: WebAuthenticationSession) async throws
    func signInAgain(_ account: AccountID, using session: WebAuthenticationSession) async throws
    func removeAccount(_ account: AccountID)
}
```

Signed-out accounts, no accounts and all calendars hidden are read from `accounts` and visibility (`signedOutAccounts`, `needsFirstRun`, `allCalendarsHidden`), because they can hold alongside any fetch status. Views take the store from the environment, pass `store.calendar` and `store.now` to the rules, and set the `calendar` and `timeZone` environment from the store, so times read the same in previews, screenshots and on device. Sign-in takes the view's `webAuthenticationSession`, so the store needs no window.

`AppModel` is the real store over Google. `FixtureStore` serves `invented-week.json`. `FixtureStore.fromLaunchArguments()` returns a fixture store when `-UseFixtures` is passed or no Google client is configured, else nil:

- `-UseFixtures invented-week`: the fixture by name, from the app bundle.
- `-Now 2026-11-04T12:10`: a fixed clock in the fixture's zone, or ISO 8601 with an offset.
- `-FixtureState offline`: one of `normal`, `loading`, `offline`, `unreachable`, `signedOut`, `allSignedOut`, `noAccount`, `noCalendars`.

## The invented week

`Core/Tests/DayCoreTests/Fixtures/invented-week.json`, in `Europe/Amsterdam` with locale `en_GB`, clock at Wednesday 4 November 2026, 12:10. Every person, address and account in it is invented. Two accounts, `you@gmail.com` (added first) and `you@acme.com`, and five calendars: Personal, Holidays in the Netherlands, Birthdays, the work calendar with a "Customer" label, and Team offsites (off by default). Events run from 26 October to 5 December so the month has rows above and below the current week.

| Day | What is on it |
|---|---|
| Mon 2 Nov | Standup, 1:1 with Priya, a flight from Gmail in the evening, working location |
| Tue 3 Nov | Lisbon begins (all-day, three days); three recurring meetings 13:00 to 18:00 with a two-hour gap |
| Wed 4 Nov | Standup 9:30, Design review 11:00, Lunch with Maya 12:30 (one-off, a place, no guests), Investor call 14:00 (one-off, outside guests, on both accounts, written in New York time), Acme sync 14:30, Weekly planning 16:00; plus Lisbon day 2 of 3, a working location and a declined Vendor demo |
| Thu 5 Nov | Standup 9:30, Design review 11:00, focus time, a short internal one-off, a flight from Gmail 20:30 to 00:15 written in Lisbon time |
| Fri 6 Nov | Four meetings 10:00 to 16:00, one of them a one-off Investor call at 15:00; a recurring out of office in the evening |
| Sat 7 Nov | Dentist 14:30, Dinner with Maya 19:00 |
| Sun 8 Nov | A birthday and nothing else |
| Mon 9 to Thu 12 Nov | A one-off out of office until Friday; recurring meetings declined; Board call Monday 15:00 kept on; Sint Maarten on Wednesday |
| Later | Coffee with Ana, a short internal check-in, Quarterly planning (three hours), Berlin (three days), Team offsite on the hidden calendar, a cancelled instance, Sinterklaas |

The fixture lists events as each account's fetch returns them: the Investor call appears twice until `merged` folds it.

## Building

The Linux checkout has no Swift toolchain; everything builds on the Mac over SSH. Each line of work uses its own folder name, so builds never share a folder or DerivedData.

```
tools/sync.sh [NAME]                  copy the checkout to ~/build/NAME on the Mac (default day)
tools/build.sh [NAME]                 sync, then xcodegen and build the Mac app and the iPhone app with its widget
tools/test.sh [NAME] [swift test args] sync, then swift test in Core
tools/screenshots.sh [NAME] [parts]   sync, then picture every screen on the invented week into ~/artifacts/day
```

Run on the Mac itself, the same scripts build in place. Products land in `build/dd/Build/Products/`. `DAY_MAC` overrides the host (default `mac-air`). The private planning documents under `docs/` are not copied.

## Rules for every line of UI

System components, SF Pro text styles, system colors and SF Symbols only. Zero `.glassEffect`, zero `.shadow`, zero gradients, no custom fonts. Color means which calendar an event belongs to; red means now. Copy is facts (counts, times, titles, places, actions), with no em dashes and no exclamation marks.

## Screenshots

`tools/screenshots.sh` pictures every screen the product has, on the invented week, in light and dark, and writes an `index.html` beside them. Parts can run alone: `iphone`, `lock`, `widget`, `mac`.

- `iphone`: the app in its own simulator (`DAY_SIM`, default `day-shots`, an iPhone 17 on iOS 27.2), launched with `-UseFixtures`, `-Now` and `-FixtureState` and driven by AXe through accessibility labels. The status bar shows the same clock as `-Now`.
- `lock`: the three "Next" families added through the Lock Screen's own widget gallery, once per simulator. The widget reads the real clock and, while the client ID is the placeholder, the invented week moved to today, so its text is that week at this hour in Amsterdam.
- `widget` and `mac` build `tools/shots/project.yml`, two renderers that compile the app's own view files and nothing new: `DayWidgetShots` draws the widget's views at the six times of the brief's table and in every state, including Always-On; `DayMacShots` draws the window, a popover, Go to Date, the menu bar label and panel and both Settings tabs into windows placed off every screen, so it runs on a locked Mac and shows nothing on the desktop. Glass and the window server's vibrancy are missing from those pictures: the day pane is drawn again on a flat ground, and switches and tinted text buttons draw in their inactive gray because the renderer is never the active app.

