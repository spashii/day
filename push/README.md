# day-push

Day's push relay. When a Google calendar changes, Google posts a notification with no event data to this Worker, and the Worker wakes the devices that watch that calendar with an Apple push. The device then runs its own incremental sync with its own Google sign-in. The relay never holds a Google token and never sees an event.

It is the Cloudflare Worker `day-push` on the Cloudflare account that serves apps.idea2prod.in. It has no route, no custom domain and no workers.dev address. The update host Worker `app-updates` owns `apps.idea2prod.in` and forwards `/day/push` and `/day/devices` here through a service binding:

```toml
# in app-updates' wrangler.toml
[[services]]
binding = "DAY_PUSH"
service = "day-push"
```

```js
// in app-updates' fetch handler, before its own routes
if (url.pathname === "/day/push" || url.pathname === "/day/devices" || url.pathname.startsWith("/day/devices/")) {
  return env.DAY_PUSH.fetch(request);
}
```

`apps.idea2prod.in/robots.txt` must keep allowing `/day/push` for the `APIs-Google` user agent, or Google stops delivering.

## Endpoints

### `POST /day/devices`

Registers an install or refreshes it. Call it on first launch to get the channel token, again after `events.watch` and `calendarList.watch` with the channels they returned, and whenever a push token changes.

```json
{
  "install": "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b",
  "platform": "ios",
  "environment": "production",
  "tokens": { "app": "<hex APNs token>", "widget": "<hex WidgetKit push token>" },
  "channels": [{ "id": "<channel ID given to watch>", "expiration": "1731405600000" }]
}
```

- `install`: a random UUID the device makes once and keeps. It is the only credential, so keep it private to the device.
- `platform`: `ios` or `macos`. A Mac gets only the background push, so its `widget` token is ignored.
- `environment`: `sandbox` for development builds, `production` for TestFlight, App Store and Developer ID builds. It picks the APNs host.
- `tokens`: hex strings. A token given as a string is set, `null` clears it, and an omitted one keeps its stored value, so the widget extension can send only its own token.
- `channels`: the install's whole current set, which replaces the stored set. Omit it to leave the channels alone. `expiration` is Google's `expiration` from the watch response, in milliseconds, as a string or a number. At most 300.

The answer is `200` with `{ "channelToken": "<install>.<signature>" }`. Put it in the `token` field of every `events.watch` and `calendarList.watch` request, with `address` `https://apps.idea2prod.in/day/push`. It is the same for the life of the install, so the device can keep it. Errors are `400` with `{ "error": "..." }`, or `503` when storage is down.

### `DELETE /day/devices/<install>`

Removes the install, its channels and any pending push. Answers `204`. Call it when Day signs out of its last account or is reset, after stopping the channels with Google.

### `POST /day/push`

Google's webhook. The Worker:

1. Checks `X-Goog-Channel-Token`. A token it did not sign gets `401`.
2. Answers `200` at once when `X-Goog-Resource-State` is `sync`, Google's first message on a new channel.
3. Answers `200` without doing anything unless `X-Goog-Channel-ID` is a channel this install still holds. That covers an install that no longer exists, and channels the device dropped but could not stop at Google (the account was removed or signed out, the calendar was hidden): Google keeps posting to them until they expire, and none of those posts may wake the device. The answer is `200` because Google retries only `5xx`.
4. Otherwise schedules a push for the install and answers `200` with no body. Any internal failure answers `503`, which Google retries with backoff.

The Worker reads no other Google header. `X-Goog-Channel-ID` is the random string the device made. `X-Goog-Resource-URI` contains the calendar ID, often an email address, and is never read, logged or stored.

A change Google reports on a new channel in the seconds between `events.watch` and the registration that lists the channel is dropped by step 3. The device's own refresh timers cover it.

## The pushes

A burst of notifications for one install becomes one push at the end of a 3 second window (`COALESCE_MS`). The next change after that opens a new window, so an install gets at most one push per window and no change is left without one. The window lives in a Durable Object per install, `InstallCoalescer`, with an alarm. The same alarm deletes old send times (see the rate limit below). The object stores the install ID only while a push is pending, and that is how it tells the two jobs apart: a change that arrives while the deletion alarm is pending replaces it with the 3 second window, and the push re-arms it. A timestamp in D1 could only throttle on the leading edge and would drop a change that lands just after a push. The alarm is a timer that outlives the request and is retried if it fails, and the object serializes notifications for one install, so two in the same instant cannot both schedule a push.

When the alarm fires:

- iPhone: a WidgetKit push to the widget token, subject to the rate limit below (`apns-push-type: widgets`, topic `io.github.spashii.day.push-type.widgets`, `{"aps":{"content-changed":true}}`) and a background push to the app token (`apns-push-type: background`, `apns-priority: 5`, topic `io.github.spashii.day`, `{"aps":{"content-available":1}}`).
- Mac: the background push to the app token.

Both expire after an hour, so a device that was offline gets the latest one when it comes back. Tokens Apple answers with `BadDeviceToken` or `Unregistered` are cleared; the device sends a new one when it next registers. Pushes use plain `fetch`: a Worker's outbound fetch speaks HTTP/2 to APNs. The provider token is an ES256 JWT for team `JMCP69LCSU`, issued at the start of each 30 minute window, which keeps every isolate inside Apple's 20 to 60 minute refresh rule.

### Widget push rate limit

Apple budgets WidgetKit pushes per app and delivers them opportunistically, and the app's own `reloadTimelines` after a background sync draws on the same budget. One widget push per change would spend it in a burst (a colleague reorganizing a shared calendar, forty invites landing) and the Lock Screen would then stop reloading for the rest of the day, with the fallback gone too. The 3 second window folds only near-simultaneous notifications, so the widget push has its own limit, kept per install by the Durable Object:

- The first three widget pushes in any rolling hour go out at once.
- After that, at most one every 15 minutes. A long run of changes sends six widget pushes in its first hour (the three, then one at 15, 30 and 45 minutes) and four an hour after that.
- A push the limit holds back is dropped, not delayed. The background push still goes out on the 3 second window, so the app syncs and reloads its own timelines. A change right after the three are spent can therefore reach the Lock Screen late, until the next widget push is allowed or the app next reloads the timelines. Delaying it to the end of the 15 minutes would need a second timer and more stored state, and is not done.
- Only pushes Apple accepted count. The background push is never limited here because iOS throttles it by itself.

The Durable Object keeps the send times (milliseconds since the epoch) of the accepted widget pushes, and each one is deleted when it turns an hour old. Every write prunes the list to the last hour. The object's alarm also does the deleting: after a push that leaves send times, the alarm is set for the hour mark of the oldest one. It deletes the expired times and arms itself again for the next, so the stored list is gone an hour after the install's last widget push. `forget()` removes it at once.

## Stored per device

This is what the privacy page promises, word for word:

> For each device, Day's server keeps a random install ID, random IDs for its Google change notices with their expiry times, its Apple push addresses, the device type, whether it runs a test or release build, when it last checked in, and the times of its Lock Screen updates in the last hour. A device that hasn't checked in for 30 days is deleted, and drops out of the database's backups 30 days after that. Nothing else.

Any new field the relay stores per device goes to the copy owner before it ships, so the privacy page stays true.

Where each item lives:

- Random install ID: `installs.install_id`, and `channels.install_id` to tie a channel to it.
- Random IDs for its Google change notices with their expiry times: `channels.channel_id` and `channels.expiry`.
- Apple push addresses: `installs.app_token` and `installs.widget_token`.
- Device type: `installs.platform`.
- Test or release build: `installs.environment`.
- When it last checked in: `installs.last_seen`.
- Times of its Lock Screen updates in the last hour: the Durable Object's `widgetPushes` list.

## What it stores

D1 database `day-push`, schema in `migrations/`:

- `installs`, one row per install: install ID, platform (`ios` or `macos`), environment (`sandbox` or `production`), app token, widget token, last seen (when it last registered).
- `channels`, one row per channel: channel ID, install ID, expiry.

Each install's Durable Object holds the send times of its widget pushes from the last hour. While a push is pending it also holds the install ID and an alarm set to the end of the 3 second window; the alarm is otherwise the deletion of the oldest send time. Nothing else is in it, and the Durable Object's storage is deleted with the install (`forget()`, which calls `deleteAll`).

Never stored or logged: calendar IDs, email addresses, Google tokens, event data, IP addresses, and when an install first registered. Last seen is kept only because the 30 day cleanup needs it.

A cron at 03:17 UTC deletes expired channels, then every install that has not registered for 30 days, whether or not it still has channels, together with its channels and its Durable Object storage. It handles 40 installs a run and takes the rest on the next. An install whose Durable Object could not be cleared keeps its row, so the next run tries again. The same run then asks the Durable Object of every install in D1 to delete send times older than an hour, and its stored list once that is empty (`prune()`). The object's alarm already does this; the pass is the backstop for lists the alarm never covered, and it leaves a pending push's alarm alone. It walks D1 by install ID in pages of 100 and makes one Durable Object call per install, and Cloudflare caps the subrequests of one invocation, so past a few thousand installs it has to spread across runs the way the 40 install limit does.

Workers observability is off on purpose: invocation logs record request details, and Google's headers carry the calendar ID. Do not turn it on, add Logpush or a tail consumer, or run `wrangler tail` on this Worker or on `app-updates`, because a tail shows each request's headers. The Worker's own log lines (an APNs failure reason, a storage failure name) carry nothing from the request.

## Secrets

- `HMAC_KEY`: 32 random bytes, base64url. Signs channel tokens. Changing it invalidates every channel until devices register and watch again.
- `APNS_KEY`: the text of the `.p8` APNs signing key, PEM included.
- `APNS_KEY_ID`: that key's ID.

Until both APNs secrets are set, notifications are accepted and coalesced, and the push is skipped with a log line. The team ID and the topic are plain variables in `wrangler.toml`.

```sh
npx wrangler secret put HMAC_KEY
npx wrangler secret put APNS_KEY
npx wrangler secret put APNS_KEY_ID
```

The values live outside the repository; each command asks for its value.

## Deploy and test

Run these from this folder under `zsh -lic`, with a token for the Cloudflare account that serves apps.idea2prod.in in `CLOUDFLARE_API_TOKEN`:

```sh
npm install
npm test                                              # vitest inside workerd, all local
npx wrangler d1 migrations apply day-push --remote    # only when migrations/ changed
npx wrangler deploy
```

The tests cover registration and the stored columns, token checks, channels an install no longer holds, coalescing, the widget push rate limit, deleting send times when they expire (alarm and write pruning, with the 3 second window intact), the push headers and payloads, the JWT signature, dropping dead tokens, deletion and the cron (30 days silent deletes the install, its channels and its Durable Object storage, and the prune pass deletes old send times and empty lists in every install's object). The privacy test sends notifications carrying an email address in `X-Goog-Resource-URI` through the success path, a forged token, a channel the install does not hold, Apple refusing the push and storage failing, and fails if any log line, table row or Durable Object entry contains it.
