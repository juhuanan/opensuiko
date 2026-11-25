#!/bin/bash
# batch dump all 29 overlay files
PY=~/workspace/.venv/bin/python
KIT=~/workspace/suikoden/kit
declare -A FILES
# area A
FILES[a_data]="$KIT/extracted/bin_overlays/DATA/01_AREA.A/A_DATA.BIN 0x80080000"
FILES[dragon0]="$KIT/extracted/bin_overlays/DATA/01_AREA.A/DRAGON0.BIN 0x80010000"
FILES[va1]="$KIT/extracted/bin_overlays/DATA/01_AREA.A/VA1.BIN 0x80010000"
FILES[va4]="$KIT/extracted/bin_overlays/DATA/01_AREA.A/VA4.BIN 0x80010000"
FILES[va7]="$KIT/extracted/bin_overlays/DATA/01_AREA.A/VA7.BIN 0x80010000"
FILES[va8]="$KIT/extracted/bin_overlays/DATA/01_AREA.A/VA8.BIN 0x80010000"
FILES[va9]="$KIT/extracted/bin_overlays/DATA/01_AREA.A/VA9.BIN 0x80010000"
# area B
FILES[b_data]="$KIT/extracted/bin_overlays/DATA/02_AREA.B/B_DATA.BIN 0x80080000"
for f in VB2 VB3 VB4 VB5 VB5A1 VB5A2 VB5AG VB5B1 VB5B2 VB5B3 VB5B4 VB5BG VB5C1 VB5C2 VB5C3 VB5C4 VB5CG VB5G VB6 VB7A; do
  FILES[$(echo $f | tr 'A-Z' 'a-z')]="$KIT/extracted/bin_overlays/DATA/02_AREA.B/$f.BIN 0x80010000"
done
FILES[vb7d]="$KIT/extracted/bin_overlays/DATA/02_AREA.B/VB7D.BIN 0x80010000"
for name in "${!FILES[@]}"; do
  set -- ${FILES[$name]}
  $PY ../dump.py "$1" "$2" > "${name}_full.txt" 2>"${name}_err.txt"
  $PY jtable_extract.py "$1" "$2" > "${name}_jtables.txt" 2>/dev/null
  echo "$name: $(grep -c 'FUNC 0x' ${name}_full.txt) funcs, $(wc -l < ${name}_jtables.txt) jtables"
done
