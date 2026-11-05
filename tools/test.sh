#!/bin/zsh
# Runs DayCore's tests on the Mac: tools/test.sh [NAME] [swift test arguments]
#
# From Linux it syncs the checkout to ~/build/NAME on the Mac (tools/sync.sh, NAME defaults
# to "day") and runs itself there. Arguments after NAME go to swift test, so
# `tools/test.sh day-rules --filter MenuBarLabelTests` runs one suite.
set -euo pipefail
root=${0:A:h:h}
name=day
if [[ ${1:-} != -* && -n ${1:-} ]]; then
  name=$1
  shift
fi
if [[ $(uname) != Darwin ]]; then
  [[ -n ${DAY_MAC:-} ]] || { print -u2 "Set DAY_MAC to the ssh host of the Mac that builds Day."; exit 1; }
  $root/tools/sync.sh $name
  exec ssh $DAY_MAC "cd ~/build/$name && zsh -lic 'tools/test.sh ${(q)@}'"
fi

cd $root/Core
swift test "$@"
