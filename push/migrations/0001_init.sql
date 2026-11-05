-- Only what the relay needs to wake a device. No calendar IDs, emails, Google
-- tokens, event data or IP addresses are stored anywhere.

CREATE TABLE installs (
  install_id   TEXT PRIMARY KEY,               -- random UUID made by the device
  platform     TEXT NOT NULL CHECK (platform IN ('ios', 'macos')),
  environment  TEXT NOT NULL CHECK (environment IN ('sandbox', 'production')),
  app_token    TEXT,                           -- APNs token of the app (iPhone or Mac)
  widget_token TEXT,                           -- WidgetKit push token (iPhone only)
  created      INTEGER NOT NULL,               -- ms since epoch
  last_seen    INTEGER NOT NULL                -- ms since epoch, last registration
);

CREATE TABLE channels (
  channel_id TEXT PRIMARY KEY,                 -- random ID the device gave events.watch
  install_id TEXT NOT NULL REFERENCES installs (install_id) ON DELETE CASCADE,
  expiry     INTEGER NOT NULL                  -- ms since epoch, from Google's watch response
);

CREATE INDEX channels_install ON channels (install_id);
CREATE INDEX channels_expiry ON channels (expiry);
