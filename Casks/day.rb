cask "day" do
  version "0.1.0"
  # Placeholder until the first release: tools/release.sh writes the real checksum.
  sha256 "df2ee4450410e06a323b1d24198a261970ab65eca93e767257763924ebde1409"

  # The address redirects to the GitHub release (v<version>/Day-<version>.dmg, the name
  # tools/release.sh gives the image), so apps.idea2prod.in can count downloads by version.
  url "https://apps.idea2prod.in/day/download/#{version}"
  name "Day"
  desc "Shows all your Google calendars as one"
  homepage "https://apps.idea2prod.in/day/"

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
