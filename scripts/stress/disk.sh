#!/usr/bin/env bash
# Heavy disk IO: write then read back a large file.  Usage: disk.sh [GB=10] [DIR=$TMPDIR]
# Shows up in JankWatch as process "dd" (disk IO).
GB="${1:-10}"; DIR="${2:-${TMPDIR:-/tmp}}"; F="$DIR/jankwatch-disk-test.bin"
trap 'rm -f "$F"; exit' INT TERM EXIT
echo "writing ${GB}GB to $F"
dd if=/dev/urandom of="$F" bs=1m count=$((GB * 1024)) 2>&1 | tail -1
sync
echo "reading back"
dd if="$F" of=/dev/null bs=1m 2>&1 | tail -1
