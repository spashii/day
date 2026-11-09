#!/bin/zsh
# Proves that a Mac release reached the Mac that builds Day: tools/verify-release.sh [VERSION BUILD]
#
# A release is not verified until /Applications/Day.app on that Mac reports it, because a
# feed that lists an update proves nothing about whether Day installs it. Without arguments
# it takes the newest release in site/appcast.xml. tools/release.sh runs it after --publish;
# it runs on its own too, from the Mac or from Linux, where it runs on $DAY_MAC.
#
# It waits, for up to 20 minutes in all, first for the update feed to list the release (the
# feed goes out through GitHub Pages and the update host's cache), then for Day to install it.
# It never quits Day. It moves Sparkle's last check time back, which a running Day with the
# idle installer takes as "check now"; the update it finds installs at Day's first idle
# moment, by Day's own rule (Core/Sources/DayCore/Rules/UpdateInstall.swift). Day that is not
# running is opened in the background, and checks as it starts. A Day older than the idle
# installer checks only at launch and installs only on quit, so it times out here: quit it
# and open it again once.
#
# Exits 0 when the installed version and build both match, and 1 otherwise.
set -euo pipefail
root=${0:A:h:h}

die() { print -u2 -- "$*"; exit 1 }

if (( $# == 2 )); then
  version=$1
  build=$2
elif (( $# == 0 )); then
  # The newest item comes first in the feed.
  newest=$(perl -0ne 'print "$2 $1\n" if m{<item>.*?<sparkle:version>([^<]+)</sparkle:version>.*?<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>}s' \
    $root/site/appcast.xml)
  [[ -n $newest ]] || die "No release in site/appcast.xml."
  version=${newest% *}
  build=${newest#* }
else
  die "usage: ${0:t} [VERSION BUILD]"
fi

if [[ $(uname) != Darwin ]]; then
  [[ -n ${DAY_MAC:-} ]] || die "Set DAY_MAC to the ssh host of the Mac that builds Day."
  exec ssh $DAY_MAC "zsh -s -- ${(q)version} ${(q)build}" < ${0:A}
fi

app=/Applications/Day.app
domain=io.github.spashii.day
deadline=$(( $(date +%s) + 20 * 60 ))
host=$(hostname -s)

installed() {
  local plist=$app/Contents/Info.plist
  # Sparkle swaps the bundle while it installs, so a read can fail for a moment.
  print -r -- "$(plutil -extract CFBundleShortVersionString raw -o - $plist 2>/dev/null || true) $(plutil -extract CFBundleVersion raw -o - $plist 2>/dev/null || true)"
}

say() { print -r -- "[$(date +%H:%M:%S)] $*" }

now=$(installed)
say "expecting Day $version ($build) on $host; installed: ${now:-none}"
if [[ $now == "$version $build" ]]; then
  say "verified: /Applications/Day.app on $host is $version ($build)"
  exit 0
fi
[[ -d $app ]] || die "Day is not installed in /Applications on $host."

# The feed Sparkle reads, from the installed app. self=1 keeps these reads out of the update
# host's counts, as the owner's own checks are.
feed=$(plutil -extract SUFeedURL raw -o - $app/Contents/Info.plist)
while true; do
  body=$(curl -fsS "$feed?self=1" 2>/dev/null || true)
  [[ $body == *"<sparkle:version>$build</sparkle:version>"* ]] && break
  (( $(date +%s) < deadline )) || die "Not verified: $feed does not list build $build after 20 minutes."
  sleep 30
done
say "the feed lists build $build"

defaults write $domain SULastCheckTime -date "2001-01-01 00:00:00 +0000"
if ! pgrep -qx Day; then
  open -g $app
  say "Day was not running; opened it in the background"
fi

last=$now
while (( $(date +%s) < deadline )); do
  now=$(installed)
  if [[ $now == "$version $build" ]]; then
    say "verified: /Applications/Day.app on $host is $version ($build)"
    exit 0
  fi
  if [[ $now != "$last" && -n ${now// /} ]]; then
    say "installed: $now"
    last=$now
  fi
  sleep 10
done

say "not verified: /Applications/Day.app on $host is ${now:-unreadable}, not $version ($build)"
# Day logs each step of an update it holds: ready, why it waits, installing.
log show --last 25m --style compact \
  --predicate "subsystem == \"$domain\" AND category == \"update\"" 2>/dev/null | tail -5 || true
print -u2 -- "A Day that predates the idle installer installs only when it quits: quit it and open it again."
exit 1
