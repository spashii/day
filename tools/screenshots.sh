#!/bin/zsh
# Pictures of every screen the brief lists, all on the invented fixture:
#   tools/screenshots.sh [NAME] [iphone] [lock] [widget] [mac]
#
# From Linux it syncs the checkout to ~/build/NAME on the Mac (tools/sync.sh, NAME defaults
# to "day"), runs itself there, and copies the pictures with their index.html into
# ~/artifacts/day/ (DAY_ARTIFACTS overrides). Naming parts runs only those; none runs all.
#
# On the Mac it builds into build/dd (DAY_DERIVED overrides), then:
# - iphone: the app in its own simulator (DAY_SIM, default "day-shots", an iPhone 17 on iOS
#   27.2), on FixtureStore with a fixed clock (-Now), driven by AXe, light and dark.
# - lock: the three "Next" families added through the Lock Screen's own widget gallery, awake
#   and in Always-On. The widget runs on the real clock with the bundled invented week, so
#   its text is whatever that week says at this hour in Amsterdam.
# - widget: the golden Lock Screen table and every widget state, drawn by the widget's own
#   views in tools/shots (not vibrant: only the Lock Screen draws that).
# - mac: the window, a popover, Go to Date, the menu bar label and panel and Settings, drawn
#   by tools/shots into windows placed off every screen, so nothing appears on the desktop.
#   Glass is drawn by the window server and is missing from these pictures; the day pane
#   inside it is drawn again on a flat ground.
#
# Nothing here signs with a real identity, uploads or touches Google.
set -euo pipefail
trap 'print -u2 "screenshots.sh: stopped at line $LINENO"' ZERR
root=${0:A:h:h}
name=day
if [[ ${1:-} != (iphone|lock|widget|mac) && -n ${1:-} ]]; then
  name=$1
  shift
fi
parts=(${@:-iphone lock widget mac})

if [[ $(uname) != Darwin ]]; then
  host=${DAY_MAC:-mac-air}
  out=${DAY_ARTIFACTS:-$HOME/artifacts/day}
  $root/tools/sync.sh $name
  ssh $host "cd ~/build/$name && zsh -lic 'DAY_DERIVED=${DAY_DERIVED:-} DAY_SIM=${DAY_SIM:-} tools/screenshots.sh ${(j: :)parts}'"
  mkdir -p $out
  rsync -a --delete --exclude '.*' --exclude manifest.tsv --exclude done.txt --exclude dump.txt \
    $host:build/$name/build/shots/ $out/
  echo "pictures: $out/index.html"
  exit 0
fi

cd $root
dd=${DAY_DERIVED:-$root/build/dd}
[[ $dd == /* ]] || dd=$root/$dd
shots=$root/build/shots
mkdir -p $shots
manifest=$shots/manifest.tsv
bundle=io.github.spashii.day

# One line per picture: part, file, caption. index.html is built from it at the end, so a
# part run alone keeps the lines of the parts it did not run.
record() {
  local part=$1 file=$2 caption=$3
  touch $manifest
  grep -v -F "	$file	" $manifest > $manifest.tmp || true
  print -r -- "$part	$file	$caption" >> $manifest.tmp
  mv $manifest.tmp $manifest
}

build() {
  (cd app && xcodegen generate --quiet)
  if (( ${parts[(I)widget]} || ${parts[(I)mac]} )); then
    (cd tools/shots && xcodegen generate --quiet)
  fi
  if (( ${parts[(I)iphone]} || ${parts[(I)lock]} )); then
    # Signed to run locally, which is what carries the App Group into the simulator; with
    # CODE_SIGNING_ALLOWED=NO the widget could not read what the app writes.
    xcodebuild -project app/Day.xcodeproj -scheme DayPhone -configuration Debug \
      -destination "generic/platform=iOS Simulator" -derivedDataPath $dd -quiet build
  fi
  if (( ${parts[(I)widget]} )); then
    xcodebuild -project tools/shots/Shots.xcodeproj -scheme DayWidgetShots -configuration Debug \
      -destination "generic/platform=iOS Simulator" -derivedDataPath $dd -quiet build
  fi
  if (( ${parts[(I)mac]} )); then
    xcodebuild -project tools/shots/Shots.xcodeproj -scheme DayMacShots -configuration Debug \
      -destination "platform=macOS,arch=arm64" -derivedDataPath $dd -quiet build
  fi
}

# MARK: Simulator

simname=${DAY_SIM:-day-shots}
sim=

boot_simulator() {
  sim=$(xcrun simctl list devices -j | jq -r --arg n $simname \
    '[.devices[][] | select(.name == $n and .isAvailable)] | first | .udid // empty')
  if [[ -z $sim ]]; then
    local runtime=$(xcrun simctl list runtimes -j | jq -r \
      '[.runtimes[] | select(.identifier | startswith("com.apple.CoreSimulator.SimRuntime.iOS-27-2")) | select(.isAvailable)] | first | .identifier')
    sim=$(xcrun simctl create $simname com.apple.CoreSimulator.SimDeviceType.iPhone-17 $runtime)
  fi
  xcrun simctl boot $sim 2>/dev/null || true
  xcrun simctl bootstatus $sim -b >/dev/null
  xcrun simctl install $sim $dd/Build/Products/Debug-iphonesimulator/Day.app
}

# The status bar reads the clock the app was given, so a picture never shows two times.
clock() {
  xcrun simctl status_bar $sim override --time $1 --dataNetwork wifi --wifiMode active \
    --wifiBars 3 --cellularMode active --cellularBars 4 --operatorName '' \
    --batteryState charged --batteryLevel 100
}

# Launches Day on the fixture at 4 November, HH:MM, optionally in one of FixtureStore's states.
launch() {
  local time=$1
  local -a state=()
  [[ -n ${2:-} ]] && state=(-FixtureState $2)
  clock $time
  xcrun simctl launch --terminate-running-process $sim $bundle \
    -UseFixtures invented-week -Now 2026-11-04T$time $state >/dev/null
  sleep 3
}

# The centre of the first on-screen element matching a jq condition, as "x y".
find_element() {
  { axe describe-ui --udid $sim 2>/dev/null || true } | jq -r --arg w 402 "
    [.. | objects | select(has(\"frame\") and .frame != null)
      | select(.frame.x >= 0 and .frame.x < (\$w | tonumber) and .frame.y >= 0 and .frame.y < 900)
      | select($1)]
    | first | select(. != null)
    | \"\(.frame.x + .frame.width / 2) \(.frame.y + .frame.height / 2)\"" 2>/dev/null || true
}

tap_where() {
  local xy
  for _ in {1..8}; do
    xy=$(find_element $1)
    [[ -n $xy ]] && break
    sleep 1
  done
  if [[ -z $xy ]]; then
    # The picture after it shows what was on screen instead, which is the useful report.
    print -u2 "not on screen: $1"
    return 0
  fi
  axe tap -x ${xy% *} -y ${xy#* } --udid $sim >/dev/null
  sleep ${2:-1.5}
}

tap_label() {
  tap_where "(.AXLabel // \"\") == \"$1\"" ${2:-}
}

tap_prefix() {
  tap_where "(.AXLabel // \"\") | startswith(\"$1\")" ${2:-}
}

snap() {
  local file=$1 caption=$2 part=${3:-iphone}
  sleep 1
  xcrun simctl io $sim screenshot $shots/$file >/dev/null 2>&1
  record $part $file $caption
}

iphone_pass() {
  local look=$1 p=iphone-$1
  xcrun simctl ui $sim appearance $look

  launch 12:10 noAccount
  snap $p-first-run.png "First run, no account ($look)"
  tap_label "Add Google Account…" 2
  snap $p-first-run-added.png "First run after one account: Add Another Account… and Done ($look)"
  launch 12:10 allSignedOut
  snap $p-first-run-signed-out.png "Every account signed out: Sign In Again… beside each ($look)"

  for time in 07:50 12:10 14:10 17:30; do
    launch $time
    snap $p-day-${time/:/}.png "Day at $time on Wednesday 4 November ($look)"
  done

  launch 15:10
  tap_prefix "Earlier:"
  snap $p-day-1510-earlier.png "Day at 15:10 with Earlier unfolded ($look)"

  launch 12:10
  tap_prefix "Investor call,"
  snap $p-event-sheet.png "Event sheet for Investor call, medium detent ($look)"
  # Dragged by its grabber: a drag that starts on the content scrolls the content instead.
  local grabber=$(find_element '(.AXLabel // "") == "Sheet Grabber"')
  if [[ -n $grabber ]]; then
    axe swipe --start-x ${grabber% *} --start-y ${grabber#* } --end-x ${grabber% *} --end-y 60 \
      --duration 0.8 --udid $sim >/dev/null
    sleep 1.5
  fi
  snap $p-event-sheet-large.png "Event sheet, large detent ($look)"

  launch 13:55
  snap $p-day-1355-join.png "Day at 13:55: Join on Investor call, 5 minutes before ($look)"

  launch 12:10 offline
  snap $p-state-offline.png "Offline line under the summary ($look)"
  launch 12:10 unreachable
  snap $p-state-unreachable.png "Google unreachable line under the summary ($look)"
  launch 12:10 signedOut
  snap $p-state-signed-out.png "One account signed out: its events stay, line under the summary ($look)"
  launch 12:10 loading
  snap $p-state-loading.png "First fetch with nothing cached: Loading… ($look)"
  launch 12:10 noCalendars
  snap $p-state-no-calendars.png "Every calendar hidden: No calendars shown. ($look)"

  launch 12:10
  tap_where '.AXUniqueId == "BackButton"'
  snap $p-month.png "Month, opened on the current week ($look)"
  # Slow enough not to fling: two week rows, so the title moves to the month with most days.
  axe swipe --start-x 201 --start-y 600 --end-x 201 --end-y 400 --duration 1.5 --udid $sim >/dev/null
  sleep 2
  snap $p-month-later.png "Month two rows on: the title follows the month holding most visible days; Berlin and Sinterklaas bars, 1 Dec ($look)"
  launch 12:10
  tap_where '.AXUniqueId == "BackButton"'
  tap_where '(.AXLabel // "") == "November" and .type == "Button"'
  snap $p-go-to-date.png "Go to Date, from a tap on the month title ($look)"
  launch 12:10
  tap_where '.AXUniqueId == "BackButton"'
  tap_label Calendars
  snap $p-calendars.png "Calendars sheet: accounts and visibility ($look)"
}

iphone() {
  boot_simulator
  iphone_pass light
  iphone_pass dark
  xcrun simctl terminate $sim $bundle 2>/dev/null || true
  xcrun simctl ui $sim appearance light
}

# MARK: Lock Screen

# Adds the inline, rectangular and circular "Next" widgets through the Lock Screen's own
# editor, once per simulator. The editor's Done button has no accessibility element, so it
# is the one tap by position.
add_lock_widgets() {
  local marker=$shots/.lock-widgets-$sim
  [[ -f $marker ]] && return 0
  axe button lock --udid $sim >/dev/null
  sleep 2
  axe touch -x 200 -y 600 --down --up --delay 1.6 --udid $sim >/dev/null
  sleep 2
  tap_where '.AXUniqueId == "posterboard-customize-button"' 2.5
  tap_where '.AXUniqueId == "grouped-widgets-reticle-view"' 2.5
  tap_where '(.AXLabel // "") == "Day" and .type == "Button"' 2.5
  tap_where '(.AXLabel // "") == "Day, Next" and (.AXValue // "") == "Widget, Rectangular"' 2
  tap_where '(.AXLabel // "") == "Day, Next" and (.AXValue // "") == "Widget, Circular"' 2
  tap_label close 2.5
  tap_where '(.AXLabel // "") | endswith(", Top Widget")' 3
  tap_label "Day, Next, Top Widget" 2
  axe swipe --start-x 200 --start-y 392 --end-x 200 --end-y 860 --duration 0.4 --udid $sim >/dev/null
  sleep 2
  axe tap -x 328 -y 33 --udid $sim >/dev/null
  sleep 3
  axe tap -x 200 -y 400 --udid $sim >/dev/null
  sleep 2
  touch $marker
}

lock() {
  [[ -n $sim ]] || boot_simulator
  # The widget falls back to the bundled week only while the app has written no snapshot.
  local group=$(xcrun simctl get_app_container $sim $bundle group.io.github.spashii.day 2>/dev/null || true)
  [[ -n $group ]] && rm -f "$group/Library/Application Support/Day/widget-snapshot.json"
  xcrun simctl terminate $sim $bundle 2>/dev/null || true
  xcrun simctl ui $sim appearance light
  add_lock_widgets
  # The widget reads the real clock, so the Lock Screen keeps its own: the status bar
  # override would set a date with the wrong weekday. Its events are the invented week's, in
  # Amsterdam time, at this moment.
  xcrun simctl status_bar $sim clear
  local amsterdam=$(TZ=Europe/Amsterdam date +%H:%M)
  for look in light dark; do
    xcrun simctl ui $sim appearance $look
    # Home unlocks a simulator without a passcode. The side button then dims the Lock Screen
    # into Always-On, and a second press wakes it.
    axe button home --udid $sim >/dev/null
    sleep 2
    axe button lock --udid $sim >/dev/null
    sleep 4
    snap lock-aod-$look.png "Always-On: line 3 gone and line 2 in clock times; $amsterdam in Amsterdam ($look)" lock
    axe button lock --udid $sim >/dev/null
    sleep 4
    snap lock-$look.png "Lock Screen with the inline, rectangular and circular Next; $amsterdam in Amsterdam ($look)" lock
  done
  xcrun simctl ui $sim appearance light
}

# MARK: Widget views

widget() {
  [[ -n $sim ]] || boot_simulator
  local app=$dd/Build/Products/Debug-iphonesimulator/DayWidgetShots.app
  xcrun simctl install $sim $app
  rm -rf $shots/widget
  mkdir -p $shots/widget
  xcrun simctl launch --terminate-running-process $sim io.github.spashii.day.shots.widget \
    -ShotsTo $shots/widget >/dev/null
  for _ in {1..60}; do
    [[ -f $shots/widget/done.txt ]] && break
    sleep 1
  done
  xcrun simctl terminate $sim io.github.spashii.day.shots.widget 2>/dev/null || true
  [[ -f $shots/widget/done.txt ]] || { print -u2 "widget views did not finish"; return 1 }
  while IFS=$'\t' read -r file caption; do
    record widget widget/$file $caption
  done < $shots/widget/done.txt
}

# MARK: Mac

mac() {
  local app=$dd/Build/Products/Debug/DayMacShots.app
  rm -rf $shots/mac
  mkdir -p $shots/mac
  # Runs as an accessory app: no Dock icon, no menu bar, windows placed off every screen. It
  # quits when done; five minutes is far past a normal run.
  $app/Contents/MacOS/DayMacShots -ShotsTo $shots/mac > $root/build/mac-shots.log 2>&1 &
  local pid=$!
  for _ in {1..300}; do
    kill -0 $pid 2>/dev/null || break
    sleep 1
  done
  kill $pid 2>/dev/null || true
  [[ -f $shots/mac/done.txt ]] || { print -u2 "mac views did not finish"; return 1 }
  while IFS=$'\t' read -r file caption; do
    record mac mac/$file $caption
  done < $shots/mac/done.txt
}

# MARK: Index

# Only pictures the manifest names are kept, so a renamed or dropped shot does not linger in
# the folder that is copied to Linux.
prune() {
  local -a keep=(${(f)"$(cut -f2 $manifest)"})
  local file
  for file in $shots/*.png(N) $shots/*/*.png(N); do
    (( ${keep[(Ie)${file#$shots/}]} )) || rm -f $file
  done
}

index() {
  prune
  local html=$shots/index.html
  {
    print '<!doctype html><html lang="en"><head><meta charset="utf-8">'
    print '<meta name="viewport" content="width=device-width, initial-scale=1">'
    print '<title>Day: screens</title><style>'
    print ':root{color-scheme:light dark;font-family:-apple-system,system-ui,sans-serif}'
    print 'body{margin:16px;max-width:1400px}h1{font-size:22px}h2{font-size:18px;margin-top:32px}'
    print '.grid{display:flex;flex-wrap:wrap;gap:16px;align-items:flex-start}'
    print 'figure{margin:0;max-width:300px}figure.wide{max-width:680px}'
    print 'img{width:100%;border:1px solid #8884;border-radius:6px}'
    print 'figcaption{font-size:13px;margin-top:4px;line-height:1.3}p{max-width:760px;line-height:1.4}'
    print '</style></head><body>'
    print "<h1>Day: every screen, on the invented fixture</h1>"
    print "<p>Built $(date '+%Y-%m-%d %H:%M') from the working tree. iPhone 17 simulator, iOS 27.2; Mac app views from tools/shots. All events, people and accounts are invented.</p>"
    local -A titles=(
      iphone "iPhone app"
      lock "Lock Screen, through the widget gallery"
      widget "Lock Screen widget views, the golden table and every state"
      mac "Mac"
    )
    local -A notes=(
      iphone "FixtureStore with -Now on Wednesday 4 November 2026 in Amsterdam; the status bar shows the same clock."
      lock "Added through the Lock Screen editor's own gallery and drawn by the system in its vibrant mode. The widget reads the real clock and the bundled invented week, moved so its Wednesday is today, in Amsterdam time; the clock above it is the Mac's own zone. Always-On is the dimmed state the side button leaves the simulator in."
      widget "Drawn by the widget's own views (NextViews.swift) from widgetTimeline, at the six times of the brief's table and in each state, on a dark ground. Only the Lock Screen draws the vibrant rendering, so these are the text and layout, not the final pixels."
      mac "Drawn by the app's own views in tools/shots, in windows placed off every screen. Glass (the inspector's floating pane, the menu bar panel's material) is drawn by the window server and does not appear here."
    )
    for part in iphone lock widget mac; do
      grep -q "^$part	" $manifest 2>/dev/null || continue
      print "<h2>$titles[$part]</h2><p>$notes[$part]</p><div class=\"grid\">"
      local class=
      [[ $part == (mac|widget) ]] && class=' class="wide"'
      grep "^$part	" $manifest | while IFS=$'\t' read -r _ file caption; do
        print "<figure$class><a href=\"$file\"><img src=\"$file\" alt=\"${caption//\"/&quot;}\" loading=\"lazy\"></a><figcaption>$caption</figcaption></figure>"
      done
      print '</div>'
    done
    print '</body></html>'
  } > $html
}

build
for part in $parts; do
  $part
done
# A booted simulator holds a few GB; the next run boots it again with its Lock Screen intact.
[[ -n $sim ]] && xcrun simctl shutdown $sim 2>/dev/null || true
index
echo "pictures: $shots/index.html"
