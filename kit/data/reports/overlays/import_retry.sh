#!/bin/bash
# import_retry.sh <bin> <base> <csv> — import_overlay.sh with 60s retry x5
set -o pipefail
BIN="$1"; BASE="$2"; CSV="$3"
for i in 1 2 3 4 5; do
  echo "=== attempt $i: $(basename "$BIN") ==="
  if ~/workspace/suikoden/kit/tools/import_overlay.sh "$BIN" "$BASE" "$CSV" 2>&1 | tail -5; then
    echo "IMPORT_DONE $(basename "$BIN") attempt $i"
    exit 0
  fi
  echo "attempt $i failed, sleeping 60s"
  sleep 60
done
echo "IMPORT_FAILED $(basename "$BIN") after 5 attempts"
exit 1
