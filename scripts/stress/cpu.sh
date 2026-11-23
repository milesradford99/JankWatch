#!/usr/bin/env bash
# Saturate the CPU with N busy processes for S seconds.  Usage: cpu.sh [N=all cores] [S=60]
# Shows up in JankWatch as process "yes" (CPU contention).
N="${1:-$(sysctl -n hw.logicalcpu)}"; S="${2:-60}"
echo "starting $N x 'yes' for ${S}s (pid list below). Ctrl-C stops early."
pids=()
for _ in $(seq "$N"); do yes > /dev/null & pids+=($!); done
echo "${pids[@]}"
trap 'kill "${pids[@]}" 2>/dev/null; exit' INT TERM
sleep "$S"; kill "${pids[@]}" 2>/dev/null; echo "stopped"
