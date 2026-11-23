#!/usr/bin/env bash
# Make a frontmost app hang (main thread blocked) for S seconds, to test the "front app hung" path.
# Freezes TextEdit with SIGSTOP, which looks exactly like a hung main thread to the Accessibility probe.
# Usage: hang-app.sh [S=8]   (bring TextEdit to front within 3 s)
S="${1:-8}"
open -a TextEdit
echo "Click into TextEdit now and keep typing; freezing it in 3 s for ${S}s ..."
sleep 3
PID=$(pgrep -x TextEdit | head -1)
kill -STOP "$PID"; echo "TextEdit ($PID) frozen"
sleep "$S"
kill -CONT "$PID"; echo "TextEdit resumed"
