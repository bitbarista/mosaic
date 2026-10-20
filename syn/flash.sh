#!/bin/bash
# Flash a bitstream over the FT232H, and verify it.
#
#   syn/flash.sh syn/build/mosaic.bin    # the functional image
#
# Ported unchanged in substance from c64-ice40-ram on 2026-10-02. J3 carries
# the same seven nets in the same order as that board's J12, to the same
# W25Q16JV, so the same FT232H cable and the same iceprog invocation apply.
#
# ⚠ THIS USES iceprog, NOT openFPGALoader, AND THAT IS NOT A PREFERENCE.
# See c64-ice40-ram ERRATA D-13. openFPGALoader v0.13.1 SILENTLY FAILS TO WRITE ANYTHING
# ABOVE 0x10000 on this setup. The images are 104090 bytes, so roughly a third
# of every bitstream never reached the flash: the device kept whatever was
# there before, the FPGA could not configure, and the board looked dead. This
# script previously wrote with openFPGALoader and then worked around two more
# defects in the same tool -- a --verify that aborts with a glibc buffer
# overflow, and a --dump-flash that is unreliable -- by reading the flash back
# in 256-byte chunks with retries. That readback was the only thing that ever
# noticed the write defect, and it was mistaken for tool noise for hours.
#
# iceprog erases in proper 64 kB blocks, writes the whole image, and verifies
# it itself. Confirmed 2026-09-05 on Rev B board #1: "VERIFY OK" first attempt,
# on an image that openFPGALoader had failed 81 chunks on.
#
# ⚠ DO NOT "IMPROVE" THIS BACK TO openFPGALoader because it detects the cable
# more conveniently. The failure is silent, and it costs a full bring-up.
#
# ON THE BENCH: VPROG powers the board through D3. Nothing else on J3 may see
# 5 V -- ring out pin 1 before first use.
#
# IN A C64: ONLY ONE THAT IS SWITCHED ON, and then connect NO power wire, GND
# first, then the signals. The machine crashes when CRESET goes low --
# expected; this board IS its CPU. Power-cycle after.
# ⚠ NEVER power through J3 in a C64 that is switched OFF (DEFERRED D-16):
# +3V3 comes up, and U11 drives PHI2 and U3 passes the config SPI onto P5,
# P2 and P3 into a dead machine's input clamps.
#
# J4 does NOT need fitting to program: iceprog holds CRESET low and talks to
# the flash directly, with the FPGA tri-stated throughout. J4 is the field
# update enable (SETTLED S-19) and should be OUT for ordinary programming.
set -u
BIN="${1:?usage: flash.sh <bitstream.bin>}"
[ -f "$BIN" ] || { echo "no such file: $BIN"; exit 1; }
cd "$(dirname "$0")/.."

command -v iceprog >/dev/null 2>&1 || {
    echo "iceprog not on PATH. It ships with oss-cad-suite:"
    echo "    export PATH=~/oss-cad-suite/bin:\$PATH"
    exit 1
}

SZ=$(stat -c%s "$BIN")
echo "== writing and verifying $BIN ($SZ bytes) with iceprog"

# ⚠ KEEP THE STATUS, NOT THE TAIL. `iceprog ... | tail` reports tail's exit
# status, which is always 0 -- the trap this repo has hit seven times. Capture,
# then decide.
# ⚠ SPI_SLOW=1: iceprog -s, 50 kHz instead of 6 MHz.  In a C64, J3's SCK is
# also P5, which the machine loads with 1K into Q2's base (through U3, always
# on); at 6 MHz that verified marginally, and on 2026-10-02 it stopped
# verifying at all ("Found difference between flash and file!").
OUT=$(iceprog ${SPI_SLOW:+-s} "$BIN" 2>&1); RC=$?
printf '%s\n' "$OUT" | tr '\r' '\n' | grep -vE '^\s*(addr 0x.*)?$' | tail -8

if [ "$RC" -ne 0 ]; then
    echo "FLASH FAILED (iceprog exit $RC)"
    exit "$RC"
fi
# ⚠ TWO CHECKS, ON PURPOSE. The exit status alone cannot distinguish "verified"
# from "did something else and returned 0"; the string alone cannot see a crash
# after printing it. Both must agree, as with the Fmax gate in synth.sh.
if ! printf '%s\n' "$OUT" | grep -q "VERIFY OK"; then
    echo "FLASH FAILED: iceprog exited 0 but did not report VERIFY OK"
    exit 1
fi
echo "VERIFY PASS: $BIN confirmed in flash"
