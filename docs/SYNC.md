# Sync

How Day keeps Google's calendars current on the Mac, in the iPhone app and on the Lock Screen: what refreshes when, what each refresh costs, what can still leave data stale, and what a push relay would add later.

The code is `Core/Sources/DayCore/Sync/` and `Core/Sources/DayCore/Google/CalendarAPI.swift`; the tests are `Core/Tests/DayCoreTests/SyncTests.swift`, recorded and invented Google answers played step by step.

## How a refresh reads Google

Every list is read incrementally, as Google's guide describes (https://developers.google.com/workspace/calendar/api/guides/sync).

- **Full read.** `events.list` with `singleEvents=true`, `timeMin` today minus 35 days and `timeMax` the end of today plus 127, `maxResults=2500`, `eventLabelVersion=1` and a `fields` mask that includes `nextSyncToken`. Pages follow `nextPageToken`, each page repeating the first request with only `pageToken` added; the last page carries `nextSyncToken`. No `orderBy` (Google refuses it beside a token, and a read that sends it gets no token back) and no `showDeleted` (a token always brings deletions).
- **Incremental read.** The same request with `syncToken` in place of `timeMin` and `timeMax`, which Google refuses beside a token. Pages follow `nextPageToken` with the same token until the last page brings the next one. The answer holds only what changed, `cancelled` items included.
- **Applying changes.** A `cancelled` item removes the event with its ID: a deleted event (only `id` is sent), a cancelled instance of a series (`id`, `recurringEventId`, `originalStartTime`), an event moved to another calendar (it leaves a cancelled item behind and arrives on the other calendar as new) and the organizer's own deleted copy, which still carries its details. Anything else replaces the copy with the same ID, so a moved instance keeps its ID and its slot in the series at the new time. An event that now falls outside the days the calendar covers is dropped, so the result always equals what a full read of those days would give.
- **A series edited as a whole is read again, not applied.** An instance's ID is `<series>_<original start>`. Changing a series for all events gives every instance in the window a new ID, and a "this and following" edit starts a second series. Google documents that with `singleEvents` and `showDeleted` both on, "only single instances of deleted events (but not the underlying recurring events) are returned"; it does not say the old instance IDs come back cancelled. So when one change set holds two or more different non-cancelled instances of the same series, the diff is not applied: that calendar is read by window in the same refresh (one more call, a new token, other calendars untouched). One edited occurrence, or any number of cancelled ones, is still just a diff. A cancelled series removing its instances by ID prefix stays as a second line of defence; Google is not expected to send that shape.
- **410 Gone**, a 400 for the token, or a last page with no token: that calendar's token is dropped, its events are wiped and it is read in full in the same refresh. No other calendar is touched.
- **Cancelling.** A refresh can be cancelled, and the system does that to a background task when its time is up. Cancelling the caller that started a refresh cancels every request, including a token call and its retries; the calendars that had already answered are written (events first, then tokens), the rest keep what they had, nothing is marked signed out, and the report says Google was not reached. A caller that joined a refresh already running stops waiting when it is cancelled and leaves the run to its starter. The foreground's pull to refresh is deliberately not cancelled by SwiftUI redrawing the list.
- **The calendar list** works the same way with `calendarList.list`. An entry marked `deleted` or `hidden` removes the calendar, with its events and its token.
- **A full read is due** when a calendar has no token, when the token's window no longer holds today minus 35 through plus 120 (the window slides a day each day; the extra week ahead keeps a token good until the next daily read), when its last full read is as old as its own interval, and when the calendar's own entry changed in a way its events decode from (its color, labels, zone or access role), because an incremental read only returns events that changed. The daily read is the repair for whatever an incremental read cannot carry. A full read stamped in the future means the clock moved back since, and counts as due.
- **The daily reads are spread.** Every calendar's first full read happens in the same refresh, so left alone they would all come due together every day: one slow refresh that reads every window, the list and the labels, which is the one a background task cannot always finish. Each calendar's interval is therefore 24 hours less a fixed share of up to 6 hours, taken from a hash of its account and calendar ID (the same on every launch), and the account's list has its own share. The reads fall on different refreshes, between 18 and 24 hours apart, and any one of them is at most a day old.
- **A calendar Google gave no token for** cannot be read incrementally. It is read in full once an hour, not on every refresh (without this, the Mac would read its five-month window every 3 minutes). Between those reads it keeps its events and counts as answered.

### Files

In the App Group container on iPhone, `~/Library/Application Support/Day/` on the Mac. Each file is plain JSON, replaced atomically.

- `events-<sub>.json`: one account's events. Rewritten only when they change, since a quiet refresh changes nothing and this is the largest file.
- `sync-<sub>.json`: beside it, the last complete refresh and, per calendar, the token, the window of the full read that issued it, when that read ran and the days its events are complete for. Written after the events: a crash between the two leaves new events with old tokens, and reading changes again from an old token is harmless, because every change carries the event's whole current state. The other order could lose a change for good.
- `near-<sub>.json`: written last, a copy of the part the widget needs: the account's events overlapping yesterday through ten days ahead, with every calendar's sync state as it was when they were written. The widget reads this one small file instead of decoding five months of events with their descriptions, which keeps its work inside the 5 seconds and its memory far from the extension's ceiling. It is used only if it holds the days the widget wants (it does for two days without the app running); otherwise that account is read from the full cache.
- `calendars-<sub>.json`: the calendar list with labels and its own token.
- `widget-snapshot.json`: merged visible events from today through eight days ahead, for the Lock Screen.

**Read order.** The app writes events, then the sync file, then the near file. A reader in another process reads the sync file before the events. Whatever moment it lands on, it then gets events at least as new as the tokens: new events with an old token only means reading some changes again. The other order could pair old events with a new token, read no changes, and write a snapshot without the change, stamped newer than the app's correct one.

### The Month beyond the window

Scrolling past the covered days fetches the stretch by window, with no token, from the covered edge outward in steps of about six months, never further than two years from today. The stretch joins the calendar's covered days and is stamped with the time it was fetched (the oldest stretch's time). Google does not say whether a token remembers the window it was issued for, so nothing is known to keep such a stretch current. It is trusted for an hour: after that the covered days fall back to the full read's, the events stay on screen, and the Month fetches the stretch again as soon as it draws it. The daily full read narrows coverage the same way. A deletion made in Google beyond the window therefore shows within an hour of the Month drawing it, not within a day.

This hour is a precaution, not a measurement. If an incremental read does return changes outside the window it was issued for, the expiry can go.

## What refreshes when

**Mac**

- Launch, coming to the front (once a minute at most), Command-R.
- Every 3 minutes while running.
- Wake from sleep, and the network coming back.
- A new day, a changed time zone and a changed clock.

**iPhone app**

- Launch, coming to the front (once a minute at most), pull to refresh, and every 3 minutes while it stays in front.
- The network coming back while it runs; a new day, zone or clock.
- Leaving the front: a read of the widget's days only, within 8 seconds, so the background time the system grants can end with the widget reload. It is skipped when a refresh began within the last minute (the same span that spares a return to the front), so a visit costs one round of requests, not two.
- `BGAppRefreshTask` (`io.github.spashii.day.refresh`), asked for 15 minutes out whenever the app changes phase and again from each run. Each run is the full incremental refresh, so the next launch opens on current data. It spends at most 20 seconds with one try per request (no backoff), and it stops at once when the system cancels it, keeping whatever calendars had answered. Because the daily reads are spread, a run rarely meets more than one.

**Lock Screen widget**

- Every timeline reload runs its own incremental read: for each visible calendar, the changes since the app's token when that token's window holds today through eight days ahead, else those days by window (also when the changes rewrite a series). One try per call, 4.5 seconds for the read and 5 for the whole reload. On a deadline or any failure the snapshot on disk renders. The changes are laid over the events in the app's near file in memory and only the snapshot is written; the app's files and tokens are never touched, and the app reads the same changes again on its next refresh.
- A snapshot under a minute old renders without a read: that is the reload the app asks for right after writing one.
- Timelines ask to reload 30 minutes out, about 48 a day, inside the 40 to 70 WidgetKit grants a widget that is seen often.
- The app asks for a reload only when its snapshot changed in what the widget shows (events, account counts) or when the data's age moved by an hour, so the `As of` line never appears over fresh data. A refresh that found nothing new costs the widget no reload.
- Tokens are in the keychain at After First Unlock and the files at the matching file protection, so a locked phone refreshes.

**Two writers of the snapshot.** The app and the widget both write `widget-snapshot.json`. A writer replaces it only when its `fetchedAt` is at least as new, and the read, the comparison and the replace run inside one `NSFileCoordinator` write, which both processes take, so neither can slip in between the other's check and rename. A file stamped more than 5 minutes in the future loses to any writer, so a clock that moved back cannot freeze the widget.

## When things go wrong

- **Offline.** Every call fails as offline; the cache, the tokens and the snapshot stay as they were, the screen says `Offline. Showing events as of 9:40.` (the last refresh in which every calendar answered), and the next refresh reads from the same tokens. The network coming back triggers one at once.
- **A partial grant.** If the grant lost calendar access, the token call says so and the account is marked signed out in the app. Its events and tokens stay on screen and on disk, and the account list shows the button `Sign In Again…` beside it. Signing in again keeps the tokens, so the next refresh reads only what changed meanwhile.
- **One account signed out** never touches another account, and one calendar failing never touches another calendar: the ones that answered are written. Only the app decides an account is signed out, from Google's answer and after comparing the refresh token it used with the one now in the keychain. The widget never invents it. A keychain item the widget cannot find (the same answer the keychain gives when the extension cannot see the app's items, as on a first install with a mismatched profile) leaves the account as the app last left it, and the other accounts are still read. A keychain that cannot be read at all (before the first unlock) keeps the snapshot on disk.
- **Clock skew.** A full read stamped in the future counts as due. A snapshot stamped more than 5 minutes ahead loses to any writer and counts as stale. An access token that expires early on the device's clock costs an early refresh; one that expires late costs a 401, which is answered with a refresh and one more try. A new day, zone or clock change refreshes at once.
- **Two writers of the snapshot.** See above: newer `fetchedAt` wins, inside one file coordination.
- **A cancelled refresh.** See Cancelling above.
- **A damaged cache file** reads as no file. Events with no sync file read as never synced, so every calendar is read in full once.

## What one refresh costs

Two accounts and five visible calendars, as an example.

- **A refresh that finds nothing:** 2 `calendarList.list` and 5 `events.list` calls, each answered with little more than a token (about a kilobyte with headers, gzip). An access token lasts an hour, so add one token call per account per hour.
- **A refresh that finds changes:** the same calls, with the changed events in the answers. A series edited for all its instances returns each instance, so a weekly meeting edited for good brings a few hundred items once, and then that calendar's window is read once more (a window read for that one calendar, a few hundred kilobytes at most, and a new token).
- **The daily full read:** a window read of about five months per calendar (one page each for most calendars), a full list per account and one `calendars.get` per calendar that may define labels, each falling between 18 and 24 hours after the last, so in a day they are spread over different refreshes.
- **A calendar with no token:** one window read an hour, otherwise nothing.
- **A stretch the Month fetched:** one window read per calendar for the stretch, when the Month draws it and it is more than an hour old.
- **Near file:** a few kilobytes per account written on every refresh, and read by the widget instead of the whole cache.
- **Mac, all day:** 20 refreshes an hour is about 140 small calls an hour. Google's limit is 600 requests per minute per user (https://developers.google.com/workspace/calendar/api/guides/quota).
- **Lock Screen:** about 5 small calls per reload, about 240 a day, plus token refreshes.

Reading the full window on every refresh instead would take the same number of calls, each answered with up to hundreds of kilobytes.

## What still makes data stale

- **WidgetKit decides when the widget reloads.** 30 minutes is a request. The system grants 40 to 70 reloads a day to a widget that is seen often, fewer to one that is not, and may hold reloads back while the phone is locked and idle. No reload means no read: a change made in Google reaches the Lock Screen at the next reload, usually within half an hour, sometimes later.
- **The background task runs when iOS chooses.** It learns from how often the app is opened, runs none while Low Power Mode is on or Background App Refresh is off for Day, and none after the app is swiped away from the app switcher, until it is opened again.
- **Before the first unlock after a restart** the keychain and the files are unreadable; the widget shows its last snapshot until the phone is unlocked once.
- **A slow network** ends a widget reload at 5 seconds with the old snapshot. The next reload tries again.
- **The Mac asleep** reads nothing; it refreshes on wake. While the app is hidden, App Nap may stretch the 3-minute timer.
- **Google leaves some changes out of incremental reads.** A calendar renamed by its owner, its zone changed, or this account's access changed reach Day at the next daily full read of the list. Label definitions are read once a day.
- **The Month far ahead or behind.** Stretches fetched by window are kept current by incremental reads only if Google reports changes outside a token's window, which it does not document; they are fetched again when drawn once they are an hour old, so what the Month shows there is at most an hour behind while it is on screen.
- **A calendar Google gave no token for** is up to an hour behind.

## Still to measure on a phone

None of this has run on a device yet. Four measurements, each one afternoon:

1. **The widget's memory and time.** With a real cache (all accounts, five months), reload the widget with the near file and then with it deleted (the widget then reads the whole cache), and note peak memory (Xcode's memory gauge on the extension) and the time from `getTimeline` to completion. If the whole-cache read is comfortably small, the near file can go. For scale only, on a Mac in a release build with 4,200 invented events across three accounts (5 MB of JSON, descriptions included), reading the whole cache took 43 ms and added about 11 MB of memory; reading the near files (137 KB each) took 4.5 ms and added about 1 MB. A phone is slower and the extension's ceiling is about 30 MB, so the phone's own figures decide.
2. **Series edits.** Change a recurring event's time for all events, and make a "this and following" edit, then refresh and look in `events-<sub>.json` for leftover instances of the old series. They should be none either way; the re-read makes it so even if Google does not cancel the old ones. A log line saying whether it did would settle which path Google takes.
3. **The token and its window.** Edit one event dated beyond today plus 127 days, and delete another, then run an incremental read of that calendar. If Google returns them, a token reports changes outside its window and the one-hour expiry of the Month's stretches can go. If it does not, the expiry is what keeps those stretches within an hour.
4. **The background task.** Run it from Xcode (`_simulateLaunchForTaskWithIdentifier:`), once with a slow network, and watch that it ends at 20 seconds and that the next foreground refresh finishes what it left.

## Later: Google push through a relay and APNs widget pushes

What it would take to bring a change to the Lock Screen in seconds rather than at the next reload.

- **Google's side.** `events.watch` per calendar and `calendarList.watch` per account (https://developers.google.com/workspace/calendar/api/guides/push). Both work with the `calendar.readonly` scope Day already has, so the app can open the channels itself and no server ever holds a Google token. Google then posts an empty notification (a channel ID and a resource state, no data) to an HTTPS address with a valid certificate. Channels expire and are not renewed automatically: the app would call `watch` again before each expiry, from launch, the background task or a widget reload.
- **The relay.** A small HTTPS service that maps a channel ID to the widget push tokens of the devices that opened it, and on each notification sends an APNs widget push. It needs an APNs key, a domain with a certificate, somewhere to store the mapping, and uptime. The mapping ties calendars to devices, which changes what the privacy page can say ("collects nothing").
- **Apple's side.** iOS 26 adds WidgetKit push notifications (https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications): the widget extension gets the Push Notifications capability, a `WidgetPushHandler` registered with `.pushHandler(_:)` receives the push token in `pushTokenDidChange(_:widgets:)` and hands it to the relay, and the relay posts with `apns-push-type: widgets`, `apns-topic: io.github.spashii.day.push-type.widgets` and `{"aps": {"content-changed": true}}`. WidgetKit then reloads the timeline, which runs the widget's own incremental read: the push carries no data, so nothing about events passes through the relay or Apple.
- **Limits.** Apple budgets widget pushes too and delivers them opportunistically, as an addition to timeline reloads, not a replacement, and developers report pushes accepted by APNs that never reloaded the widget (https://developer.apple.com/forums/thread/839182). The Mac would gain little: it already reads every 3 minutes.

Worth it only if the Lock Screen still lags after a few weeks of stage two on a real phone.
