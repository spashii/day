cask "day" do
  version "0.1.0"
  # Placeholder until the first release: tools/release.sh writes the real checksum.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/spashii/day/releases/download/v#{version}/Day-#{version}.dmg"
  name "Day"
  desc "Shows all your Google calendars as one"
  homepage "https://spashii.github.io/day/"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Day.app"

  # Day stays running in the menu bar after its window closes, so it is quit before removal.
  uninstall quit: "io.github.spashii.day"

  zap trash: [
    "~/Library/Application Support/Day",
    "~/Library/Caches/io.github.spashii.day",
    "~/Library/Preferences/io.github.spashii.day.plist",
  ]
end
