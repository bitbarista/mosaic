#!/bin/bash
# Hands-free flashing with a hand-held pogo-pin probe on J3.
#
#   syn/pogo.sh                          # syn/build/mosaic.bin, the shipped image
#   syn/pogo.sh other.bin                # any other image
#   syn/pogo.sh --sound-test             # check the voice prompts, then exit
#   syn/pogo.sh --usb-last X.bin         # BENCH: probe seated first, USB in last (E-48)
#
# Both hands are on the probe, so nothing here waits for the keyboard. The
# script polls the flash ID over J3; when it reads the Winbond ID twice in a
# row the pins are seated, and it writes and verifies through syn/flash.sh.
# Every state change is SPOKEN, because your eyes are on the pins:
#
#   "ready"     armed, press the probe on
#   "contact"   ID read twice, writing now -- keep holding
#   "pass"      VERIFY OK -- lift off, next board
#   "fail"      anything else -- lift off and press on again to retry
#
# After either result it waits for the probe to come OFF before it re-arms, so
# a board is never written twice by a probe that was just left resting on it.
#
# Ported from c64-ice40-ram on 2026-10-02. J3 is that board's J12 at half the
# pitch: the same seven nets in the same order, to the same W25Q16JV, so the
# FT232H end and everything below are unchanged.
#
# ⚠ THE PROBE IS NOT THE DRAM BOARD'S. J3 is 1.27 mm and that probe is 2.54 mm;
# the 7-way 1.27 mm probe's wire colours are below (Carl, 2026-10-05); they
# happen to match the DRAM probe's, but were given for THIS probe. Connector pin n of the FT232H
# breakout's bottom row, starting at 5V, is: 5V GND D0 D1 D2 D3 D4 D5 D6 D7.
#
#   J3   net        pogo    10-way  FT232H
#    1   VPROG      purple    1     5V      <- through D3; the ONLY pin that may see 5 V
#    2   GND        grey      2     GND
#    3   SPI_CS_N   white     7     D4
#    4   SPI_SCK    black     3     D0      (P5 on the socket side)
#    5   SPI_MOSI   brown     4     D1      (P2)
#    6   SPI_MISO   red       5     D2      (P3)
#    7   CRESET_N   orange   10     D7
#   ⚠ THE CABLE IN USE FROM 2026-10-06 (Carl): BLACK IS SCK, RED IS MISO --
#   neither is power.  PURPLE is +5 V, GREY is ground.  (The earlier cable was
#   black 5V / brown GND / red D4 / orange D0 / yellow D1 / green D2 / blue D7.)
#   Series resistors: tried 2026-10-05/06 and REMOVED -- 1k in each D line made
#   the ID read EE 00 00 00 at 6 MHz and 50 kHz on two boards (ERRATA E-48);
#   mechanism not understood.
#
# ⚠ D6 IS EMPTY, so iceprog's "cdone: high" line is the FT232H's own floating
# input, NOT the board's CDONE. It proves nothing.
#
# Shift the connector one pin left onto 3V and GND shorts USB 5V to ground.
# Meter it first: purple-to-grey reads +5 V at the tips.
#
# ⚠ BENCH ONLY, OR A C64 THAT IS SWITCHED ON. This script powers the board
# through VPROG. Pressed onto a board in a C64 that is OFF, it back-feeds the
# dead machine through PHI2, P5, P2 and P3 (DEFERRED D-16).
#
# SPACE forces a write immediately (if the ID check is the thing that is
# wrong); q quits. Neither is needed in normal use.
#
# The write itself is syn/flash.sh, unchanged -- iceprog, never openFPGALoader
# (ERRATA D-13), and both the exit status and "VERIFY OK" must agree. A probe
# that slips mid-write fails the verify; it cannot pass a partial image.
set -u
cd "$(dirname "$0")/.."
export PATH=~/oss-cad-suite/bin:$PATH

# Winbond W25Q16JV (U8), 2 MB -- the ID the DRAM board's identical part
# returned (its ERRATA F-14).
# A board with no power reads 00 00 00 00 or FF FF FF FF, so this also proves
# the probe's power and ground pins are seated, not just the SPI ones.
WANT_ID="0xEF 0x40 0x15"

say() {
    echo ">> $*"
    if command -v spd-say >/dev/null 2>&1; then
        spd-say -w -r 20 "$*" 2>/dev/null || printf '\a'
    else
        printf '\a'
    fi
}

# --slow: write at 50 kHz (iceprog -s) -- for a board in a C64, where SCK is
# loaded by the machine's P5 circuit.  Slower (~40 s); hold the probe on.
if [ "${1:-}" = "--slow" ]; then
    export SPI_SLOW=1
    shift
    echo "slow SPI: iceprog -s (50 kHz), about 40 s per write -- keep the probe on"
fi

# --usb-last: the probe is seated BEFORE anything is powered (ERRATA E-48).
# Start with the programmer's USB UNPLUGGED, press the probe on, THEN plug the
# USB in: VPROG and the FT232H come up together through pins that are already
# seated, so the order the pins touch in no longer matters.  ONE ID check, ONE
# write, no polling loop (every `iceprog -t` pulls CRESET and re-configures the
# FPGA).  Afterwards UNPLUG THE USB FIRST, then lift the probe: the board and the
# FT232H lose power together.  Bench only -- not in a C64 (VPROG powers the board).
if [ "${1:-}" = "--usb-last" ]; then
    USB_LAST=1
    shift
fi

# --readback: on contact, read the flash ID (verbose, incl. status) and the
# first 256 kB at 50 kHz into syn/build/readback.bin, then exit.  Writes nothing.
if [ "${1:-}" = "--readback" ]; then
    READBACK=1
    shift
fi

if [ "${1:-}" = "--sound-test" ]; then
    for w in ready contact pass fail; do say "$w"; done
    exit 0
fi

BIN="${1:-syn/build/mosaic.bin}"
[ -f "$BIN" ] || { echo "no such file: $BIN"; exit 1; }
command -v iceprog >/dev/null 2>&1 || { echo "iceprog not found in ~/oss-cad-suite/bin"; exit 1; }

echo "image: $BIN  $(stat -c%s "$BIN") bytes  md5 $(md5sum "$BIN" | cut -d' ' -f1)"
ft232h() { lsusb | grep -q "0403:6014"; }
read_id() {   # prints "0xEF 0x40 0x15 0x00" or nothing
    iceprog ${SPI_SLOW:+-s} -t 2>&1 | sed -n 's/^flash ID: *//p' | head -1
}
seated() { case "$(read_id)" in "$WANT_ID"*) return 0 ;; *) return 1 ;; esac; }

if [ "${USB_LAST:-0}" = "1" ]; then
    if ft232h; then
        say "unplug the programmer"
        echo "   the FT232H is on USB: UNPLUG it (the probe must be seated with no power)"
        while ft232h; do sleep 0.5; done
    fi
    say "seat the probe, then plug in the programmer"
    echo "   probe on J3 first, held still; THEN plug the FT232H's USB in"
    while ! ft232h; do sleep 0.3; done
    sleep 1.5                                  # enumeration, and the board's rails
    id=$(read_id)
    case "$id" in
        "$WANT_ID"*) ;;
        *) echo "== flash ID '$id', want '$WANT_ID': not seated, or no power -- NOTHING WRITTEN"
           say "fail"; say "unplug the programmer, then lift the probe"; exit 1 ;;
    esac
    say "contact"
    if [ "${READBACK:-0}" = "1" ]; then
        iceprog -v -t > syn/build/readback_id.txt 2>&1
        iceprog -s -r syn/build/readback.bin > syn/build/readback_log.txt 2>&1; RC=$?
        tail -3 syn/build/readback_log.txt
    else
        syn/flash.sh "$BIN"; RC=$?
    fi
    [ "$RC" -eq 0 ] && say "pass" || say "fail"
    say "unplug the programmer, then lift the probe"
    echo "   UNPLUG THE USB FIRST, then lift the probe"
    exit "$RC"
fi

# Preflight: everything that can be checked BEFORE you pick up the probe.
ft232h || { echo "FT232H (0403:6014) not on USB -- plug it in"; exit 1; }


# Raw keypresses, restored on any exit.
STTY=$(stty -g); trap 'stty "$STTY"; echo; echo "passed: $PASS  failed: $FAIL"' EXIT
stty -icanon -echo min 0 time 0

key() { local k; k=$(dd bs=1 count=1 2>/dev/null); printf '%s' "$k"; }

PASS=0; FAIL=0
while :; do
    say "ready"
    # Wait for two consecutive good IDs (debounce), or SPACE.
    hits=0
    while [ $hits -lt 2 ]; do
        case "$(key)" in
            q) exit 0 ;;
            " ") hits=2; break ;;
        esac
        if seated; then hits=$((hits+1)); else hits=0; fi
        sleep 0.2
    done

    say "contact"
    if [ "${READBACK:-0}" = "1" ]; then
        iceprog -v -t > syn/build/readback_id.txt 2>&1
        iceprog -s -r syn/build/readback.bin > syn/build/readback_log.txt 2>&1; RC=$?
        cat syn/build/readback_id.txt | grep -iv "^$" | tail -12
        tail -3 syn/build/readback_log.txt
        ls -l syn/build/readback.bin 2>/dev/null
        [ "$RC" -eq 0 ] && say "pass" || say "fail"
        exit "$RC"
    fi
    T0=$(date +%s.%N)
    syn/flash.sh "$BIN"; RC=$?
    DT=$(printf '%.1f' "$(echo "$(date +%s.%N) - $T0" | bc)")

    if [ "$RC" -eq 0 ]; then
        PASS=$((PASS+1)); echo "== PASS in ${DT}s ($PASS passed, $FAIL failed)"; say "pass"
    else
        FAIL=$((FAIL+1)); echo "== FAIL after ${DT}s ($PASS passed, $FAIL failed)"; say "fail"
    fi

    # Re-arm only once the probe is off: three consecutive non-ID reads.
    misses=0
    while [ $misses -lt 3 ]; do
        [ "$(key)" = q ] && exit 0
        if seated; then misses=0; else misses=$((misses+1)); fi
        sleep 0.2
    done
done
