#!/bin/bash
# import_overlay.sh — import one Suikoden PS1 overlay blob into the
# suikoden_overlays Ghidra project, run auto-analysis, apply label CSV.
# Usage: ./import_overlay.sh <bin_path> <base_hex> <csv_path>
#   e.g. ./import_overlay.sh kit/extracted/bin_overlays/DATA/03_SHIRO/AZUKARI.BIN \
#            0x80080000 kit/work/azukari_labels.csv
# Creates $GHIDRA_PROJECT_DIR (default ~/ghidra/suikoden_overlays) on first use.
# Re-running for the same file: delete the program from the project first
# (analyzeHeadless -import refuses duplicates; do NOT use -overwrite with
# the memmap preScript — it wipes/rebuilds memory on a fresh import).
set -u
BIN="$1"; BASE="$2"; CSV="$3"
SIZE=$(wc -c < "$BIN" | tr -d " ")
SPLIT=$(printf "0x%X" $((BASE + SIZE)))

# External toolchain (Ghidra + a JDK). These live outside this repo and are
# NOT present on every machine, so they are env-overridable rather than
# hardcoded. Set GHIDRA_HOME / JAVA_HOME before running.
GHIDRA_HOME="${GHIDRA_HOME:-$HOME/tools/ghidra}"
GHIDRA_PROJECT_DIR="${GHIDRA_PROJECT_DIR:-$HOME/ghidra/suikoden_overlays}"
GHIDRA_SCRIPTS="${GHIDRA_SCRIPTS:-$HOME/ghidra/scripts}"
if [ -z "${JAVA_HOME:-}" ]; then
  for cand in "$HOME/tools"/jdk*/jdk* /opt/homebrew/opt/openjdk /usr/libexec/java_home; do
    [ -x "$cand/bin/java" ] && export JAVA_HOME="$cand" && break
    [ -x "$cand" ] && export JAVA_HOME="$("$cand" 2>/dev/null)" && break
  done
fi
[ -n "${JAVA_HOME:-}" ] || { echo "ERROR: set JAVA_HOME (no JDK autodetected)" >&2; exit 1; }
[ -x "$GHIDRA_HOME/support/analyzeHeadless" ] || {
  echo "ERROR: analyzeHeadless not found under GHIDRA_HOME=$GHIDRA_HOME" >&2
  echo "       set GHIDRA_HOME to your Ghidra install (see kit/docs/emulator.md)" >&2
  exit 1
}
export JAVA_HOME
export OVERLAY_BIN="$BIN"
export OVERLAY_BASE="$BASE"
export OVERLAY_CSV="$CSV"
export OVERLAY_DATA_SPLIT="$SPLIT"
export OVERLAY_NAME="$(basename "$BIN")"

exec "$GHIDRA_HOME/support/analyzeHeadless" \
  "$GHIDRA_PROJECT_DIR" OVERLAYS \
  -import "$BIN" \
  -processor "MIPS:LE:32:default" \
  -loader BinaryLoader \
  -preScript overlay_memmap.java \
  -postScript import_overlay_labels.java \
  -scriptPath "$GHIDRA_SCRIPTS"
