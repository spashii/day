#!/bin/zsh
# Runs DayCore's tests on the Mac: tools/test.sh [NAME] [swift test arguments]
#
# From Linux it syncs the checkout to ~/build/NAME on the Mac (tools/sync.sh, NAME defaults
# to "day") and runs itself there. Arguments after NAME go to swift test, so
# `tools/test.sh day-rules --filter SummaryTests` runs one suite.
set -euo pipefail
root=${0:A:h:h}
name=day
if [[ ${1:-} != -* && -n ${1:-} ]]; then
  name=$1
  shift
fi
if [[ $(uname) != Darwin ]]; then
  $root/tools/sync.sh $name
  exec ssh ${DAY_MAC:-mac-air} "cd ~/build/$name && zsh -lic 'tools/test.sh ${(q)@}'"
fi

cd $root/Core
swift test "$@"
