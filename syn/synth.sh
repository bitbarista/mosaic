#!/bin/sh
# Synthesise the 6510 for the iCE40UP5K.
#
# ⚠ VHDL AND VERILOG IN ONE DESIGN.  T65 is VHDL (BSD-3-Clause, rtl/t65/) and
# the 6510 wrapper is Verilog, so yosys runs with the ghdl plugin: `-m ghdl`,
# then `ghdl ... -e T65` imports the elaborated entity and read_verilog adds
# the wrapper on top.  Verified working in this oss-cad-suite.
#
# ⚠ -fsynopsys IS REQUIRED, not optional.  T65_MCode.vhd uses
# ieee.std_logic_unsigned, which is a Synopsys package; without the flag ghdl
# refuses the file and the import fails with "vhdl import failed" -- which
# reads like a syntax error rather than a missing switch.
#
# ⚠ THE ANALYSIS ORDER MATTERS.  T65_Pack defines the types the others use.
set -e
# ⚠ C LOCALE.  The build ID hashes rtl/t65/*.vhd in glob order, and en_GB/en_US
# sort T65.vhd last where C sorts it first: same sources, different ID, and a
# different bitstream.  $2ECB was built under C.
export LC_ALL=C
cd "$(dirname "$0")/.."
YOSYS=${YOSYS:-$HOME/oss-cad-suite/bin/yosys}
OUT=${1:-syn/build/mosaic.json}
# TOPV: the top-level RTL.  Overridable ONLY so syn/test_synth_gate.sh can feed
# a mutated copy through the real flow; nothing else should set it.
TOPV=${TOPV:-rtl/top.v}
mkdir -p "$(dirname "$OUT")"

# the build's identity: software reads it through the unlocked flash port
# (rtl/cpu6510.v BUILD_ID) to prove WHICH image is running -- golden slot A or
# an experimental slot B.  From the sources, so a rebuild of the same RTL gets
# the same ID.
BUILD_ID=$(cat rtl/*.v rtl/t65/*.vhd "$TOPV" | sha1sum | cut -c1-4)
echo "  build ID \$$BUILD_ID"

"$YOSYS" -m ghdl -p "
  ghdl --std=08 -fsynopsys \
       rtl/t65/T65_Pack.vhd rtl/t65/T65_ALU.vhd rtl/t65/T65_MCode.vhd \
       rtl/t65/T65.vhd -e T65;
  read_verilog -DMOSAIC_BUILD_ID=16'h$BUILD_ID rtl/cpu6510.v rtl/tracer.v $TOPV;
  synth_ice40 -top top -json $OUT;
" | tee "$(dirname "$OUT")/synth.log" | tail -3

SYNLOG="$(dirname "$OUT")/synth.log" python3 - <<'PY'
import os, re
t = open(os.environ["SYNLOG"]).read()
# ⚠ DERIVE THE MARKER FROM THE TOP MODULE, DO NOT TYPE IT.  This read
# "=== cpu6510 ===" and the top became `top` on 2026-09-11, so the script died
# with ValueError: substring not found -- after a successful synthesis.  A
# hard-coded name in the tool that reads the tool's own output is the same
# duplicated-fact shape as ERRATA E-16.
import re as _re
_marks = _re.findall(r"^=== (\S+) ===$", t, _re.M)
assert _marks, "no design section in the yosys log"
blk = t[t.rindex(f"=== {_marks[-1]} ==="):]
cells = dict((m[1], int(m[0])) for m in
             re.findall(r"^\s+(\d+)\s+(SB_\w+)", blk, re.M))
lut = cells.get("SB_LUT4", 0)
dff = sum(v for k, v in cells.items() if k.startswith("SB_DFF"))
print(f"\n  SB_LUT4 {lut} of 5280 on a UP5K  ({lut/5280*100:.0f}%)")
print(f"  flip-flops {dff},  carries {cells.get('SB_CARRY',0)}")
# ⚠ A GATE, not a report.  The whole reason to know the number is to notice
# when it moves.
LIMIT = 5280 * 0.60
assert lut < LIMIT, f"LUT use {lut} exceeds the {LIMIT:.0f} gate"
print(f"  gate: under 60% of the device -- PASS")
PY

# ---------------------------------------------------------------- place & route
# ⚠ THIS WAS MISSING UNTIL 2026-09-11 AND IT IS THE HALF THAT PROVES THE BOARD.
# synth.sh stopped at yosys, so the LUT count was known and NOTHING had ever
# asked whether the 39 signals could be placed on the SG48 pins the copper was
# already laid out for.  A pinout error found after fabrication is a respin.
set -e
PCF=${PCF:-syn/mosaic.pcf}
ASC=${ASC:-syn/build/mosaic.asc}
BIN=${BIN:-syn/build/mosaic.bin}
python3 syn/gen_pcf.py "$PCF"
NEXTPNR=${NEXTPNR:-$HOME/oss-cad-suite/bin/nextpnr-ice40}
ICEPACK=${ICEPACK:-$HOME/oss-cad-suite/bin/icepack}
# ⚠ --up5k --package sg48 is the part on the BOM (design.LCSC U1 = C2678152,
# ICE40UP5K-SG48I).  check_bitstream_part.py gates that they agree.
# ⚠ TIMING WAS MEASURED ONCE AND NEVER GATED.  ERRATA E-22 found 22.89 MHz on
# 2026-09-11 and chose the 12 MHz rung; after that this line piped nextpnr
# through `grep ... || true`, so a design that stopped closing would still have
# built a bitstream and exited 0.  Ported from c64-ice40-ram syn/synth.sh:
#   * REQUIRED = the clock top.v actually runs at (derived from CLKHF_DIV, never
#     typed) + 20%, the sibling's margin for HFOSC tolerance;
#   * the Fmax is READ from nextpnr's report, and an unreadable report FAILS;
#   * nextpnr's own exit code must AGREE with the gate -- the sibling's "FLOW
#     BROKEN" rule, so neither answer can be picked for convenience;
#   * the seed is PINNED, so a pass is reproducible.  E-22's 8-seed spread was
#     21.81-23.29 MHz; any of them clears 14.4 by >50%.
PNR_LOG=$(dirname "$OUT")/pnr.log
DIV=$(sed -n 's/.*parameter CLKHF_DIV = "\(0b[01][01]\)".*/\1/p' "$TOPV")
case "$DIV" in
    0b00) CLK_MHZ=48 ;; 0b01) CLK_MHZ=24 ;; 0b10) CLK_MHZ=12 ;; 0b11) CLK_MHZ=6 ;;
    *) echo "CANNOT READ CLKHF_DIV from $TOPV -- refusing to guess the clock"; exit 1 ;;
esac
REQ_MHZ=$(awk -v c="$CLK_MHZ" 'BEGIN{printf "%.1f", c*1.2}')
set +e
"$NEXTPNR" --up5k --package sg48 --json "$OUT" --pcf "$PCF" --asc "$ASC" \
    --freq "$CLK_MHZ" --seed "${PNR_SEED:-1}" > "$PNR_LOG" 2>&1
PNR_RC=$?
set -e
grep -E "Device utilisation|ICESTORM_LC|SB_IO|Max frequency|ERROR" "$PNR_LOG" | tail -8
FMAX=$(grep -E "Max frequency for clock +'clk':" "$PNR_LOG" | tail -1 \
       | grep -oE '[0-9]+\.[0-9]+ MHz' | head -1 | cut -d' ' -f1)
if [ -z "$FMAX" ]; then
    echo "CANNOT READ Fmax for clock 'clk' from $PNR_LOG -- refusing to guess."
    echo "The report format or the clock name has changed; fix the extraction, not the gate."
    exit 1
fi
echo "  routed Fmax: ${FMAX} MHz   (clock ${CLK_MHZ} MHz from CLKHF_DIV=${DIV}; required >= ${REQ_MHZ})"
GATE_RC=$(awk -v f="$FMAX" -v r="$REQ_MHZ" 'BEGIN{print (f+0 < r+0) ? 1 : 0}')
if [ "$GATE_RC" -eq 0 ] && [ "$PNR_RC" -ne 0 ]; then
    echo "FLOW BROKEN: nextpnr exited ${PNR_RC} but the Fmax gate passes (${FMAX} >= ${REQ_MHZ})."
    echo "These must agree. Fix the flow -- do NOT pick whichever answer is more convenient."
    exit 1
fi
if [ "$GATE_RC" -ne 0 ]; then
    echo "TIMING FAIL: ${FMAX} MHz < ${REQ_MHZ} MHz -- the oscillator can outrun the design."
    exit 1
fi
# ⚠ THE 48 MHz DOMAIN IS GATED TOO (ERRATA E-36).  The oscillator runs at 48 MHz
# and only PHI2 and the write-data hold live on it; the same 20 % margin applies.
HF=$(grep -E "Max frequency for clock +'hf48':" "$PNR_LOG" | tail -1 \
     | grep -oE '[0-9]+\.[0-9]+ MHz' | head -1 | cut -d' ' -f1)
if [ -z "$HF" ]; then
    echo "CANNOT READ Fmax for clock 'hf48' from $PNR_LOG -- refusing to guess."
    exit 1
fi
echo "  routed Fmax: ${HF} MHz for hf48   (48 MHz oscillator; required >= 57.6)"
if [ "$(awk -v f="$HF" 'BEGIN{print (f+0 < 57.6) ? 1 : 0}')" -ne 0 ]; then
    echo "TIMING FAIL: hf48 ${HF} MHz < 57.6 MHz"
    exit 1
fi
"$ICEPACK" "$ASC" "$BIN"
ls -l "$BIN" | awk '{print "  bitstream: "$5" bytes -> '"$BIN"'"}'
