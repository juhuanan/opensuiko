#!/bin/bash
# import_area_cde.sh — import Area C/D/E overlay labels into the shared Ghidra project.
# Retries up to 5x with 60s sleep on failure (concurrent-project lock).
set -u
KIT=~/workspace/suikoden/kit
BIN_DIR=$KIT/extracted/bin_overlays/DATA
WORK=$KIT/work/overlays
LOG=$WORK/import_cde.log

run_one() {
  local bin="$1" base="$2" csv="$3"
  local name
  name=$(basename "$bin")
  for attempt in 1 2 3 4 5; do
    echo "[$(date +%T)] $name attempt $attempt" >> "$LOG"
    if "$KIT/tools/import_overlay.sh" "$bin" "$base" "$csv" >> "$LOG" 2>&1; then
      echo "[$(date +%T)] $name OK (attempt $attempt)" >> "$LOG"
      return 0
    fi
    echo "[$(date +%T)] $name FAILED attempt $attempt; sleeping 60s" >> "$LOG"
    sleep 60
  done
  echo "[$(date +%T)] $name FAILED after 5 attempts" >> "$LOG"
  return 1
}

: > "$LOG"
FAILED=0
import() { run_one "$1" "$2" "$3" || FAILED=$((FAILED+1)); }

# Area C
import "$BIN_DIR/06_AREA.C/C_DATA.BIN" 0x80080000 "$WORK/c_data_labels.csv"
import "$BIN_DIR/06_AREA.C/VC3.BIN"     0x80010000 "$WORK/vc3_labels.csv"
import "$BIN_DIR/06_AREA.C/VC6.BIN"     0x80010000 "$WORK/vc6_labels.csv"
# Area D
import "$BIN_DIR/07_AREA.D/D_DATA.BIN" 0x80080000 "$WORK/d_data_labels.csv"
import "$BIN_DIR/07_AREA.D/K_DATA.BIN" 0x80080000 "$WORK/k_data_labels.csv"
for n in 1 2 3 4 5; do
  import "$BIN_DIR/07_AREA.D/VD$n.BIN" 0x80010000 "$WORK/vd$n""_labels.csv"
done
import "$BIN_DIR/07_AREA.D/VD6.BIN" 0x80010000 "$WORK/vd6_labels.csv"
import "$BIN_DIR/07_AREA.D/VD7.BIN" 0x80010000 "$WORK/vd7_labels.csv"
# Area E
import "$BIN_DIR/08_AREA.E/E_DATA.BIN" 0x80080000 "$WORK/e_data_labels.csv"
for n in 1 2 3 4 5 6; do
  import "$BIN_DIR/08_AREA.E/VE$n.BIN" 0x80010000 "$WORK/ve$n""_labels.csv"
done

echo "[$(date +%T)] DONE. failed=$FAILED" >> "$LOG"
echo "DONE failed=$FAILED"
