#!/bin/bash
# run.sh - headless PCSX-Redux probe runner for the Suikoden kit.
#
# Usage: run.sh <probe.lua> [outdir]
#
# Env overrides:
#   SUIKODEN_EMU     PCSX-Redux AppRun (default: July build under ~/workspace/tools/pcsx-redux)
#   SUIKODEN_BIOS    PSX BIOS (default: ~/workspace/suikoden/SCPH1001.BIN)
#   SUIKODEN_ISO     disc image (default: ~/workspace/suikoden/"Suikoden (v1.1).cue")
#   SUIKODEN_FRAMES  vsync budget (default: 7200)
#   SUIKODEN_OUT     probe output path (default: <outdir>/<probe>.csv)
#   SUIKODEN_TIMEOUT wall-clock timeout in seconds (default: 300)
#
# The probe reads SUIKODEN_OUT / SUIKODEN_FRAMES itself. Probe stdout
# (PCSX.log lines) goes to <outdir>/<probe>.emu.log.

set -u

PROBE="${1:?usage: run.sh <probe.lua> [outdir]}"
OUTDIR="${2:-${SUIKODEN_OUTDIR:-/tmp/suikoden-emu}}"

EMU="${SUIKODEN_EMU:-$HOME/workspace/tools/pcsx-redux/b290/squashfs-root/AppRun}"
BIOS="${SUIKODEN_BIOS:-$HOME/workspace/suikoden/SCPH1001.BIN}"
ISO="${SUIKODEN_ISO:-$HOME/workspace/suikoden/Suikoden (v1.1).cue}"
FRAMES="${SUIKODEN_FRAMES:-7200}"
TIMEOUT="${SUIKODEN_TIMEOUT:-300}"

STEM="$(basename "$PROBE" .lua)"
LOG="$OUTDIR/$STEM.emu.log"

for f in "$EMU" "$BIOS" "$ISO" "$PROBE"; do
    [ -e "$f" ] || { echo "run.sh: missing: $f" >&2; exit 2; }
done
mkdir -p "$OUTDIR"

export SUIKODEN_FRAMES="$FRAMES"
export SUIKODEN_OUT="${SUIKODEN_OUT:-$OUTDIR/$STEM.csv}"

echo "run.sh: probe=$STEM frames=$FRAMES out=$SUIKODEN_OUT log=$LOG"

timeout "$TIMEOUT" "$EMU" \
    -cli -logfile "$LOG" -stdout \
    -interpreter -debugger \
    -iso "$ISO" -bios "$BIOS" \
    -run -dofile "$PROBE" 2>&1 | grep -vE "^$" | tail -5

echo "run.sh: exit=$? out=$SUIKODEN_OUT"
