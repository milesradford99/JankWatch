#!/usr/bin/env bash
# Force Spotlight to re-index the startup volume (needs admin). Indexing can run for 10-60 minutes and is a
# realistic root-owned background culprit (mds_stores / mdworker). Run only on a machine where that is OK.
set -e
read -r -p "Re-index Spotlight on / ? This takes a while. [y/N] " a
[ "$a" = "y" ] || exit 0
sudo mdutil -E /
echo "watch: ps -Ao pid,pcpu,comm | grep -E 'mds|mdworker'"
