#!/usr/bin/env python3
"""The updater shares constants across languages.  Prove they still agree.

    python3 updater/check_key.py          # exit 0 = all agree

  1. the unlock key   -- an LFSR in rtl/cpu6510.v (FL_SEED, FL_LEN, taps),
                         sixteen literal bytes in updater/spi.asm
  2. the key address  -- FL_ADDR in the RTL, FLPORT in the .asm
  3. the CRC16        -- mkfirmware.py's Python against flash.asm's polynomial
  4. NOT DRAMa's      -- c64-ice40-ram's address and keys ($CF00; seeds $A5,
                         $4B) must differ from ours, and no 16-byte window of
                         either board's key sequence may overlap the other's:
                         these writes reach RAM, so a DRAMa in the same machine
                         sees every one of them

Ported from c64-ice40-ram/updater/check_key.py.  The RTL is the source; the
.asm is only ever checked against it.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RTL = ROOT / "rtl" / "cpu6510.v"
ASM = ROOT / "updater" / "spi.asm"
FLASH = ROOT / "updater" / "flash.asm"
DRAMA = {"addr": 0xCF00, "seeds": (0xA5, 0x4B)}   # c64-ice40-ram rtl/c64ram.v, rtl/spi_port.v


def lfsr(seed, n, taps):
    out, v = [], seed
    for _ in range(n):
        out.append(v)
        fb = 0
        for t in taps:
            fb ^= (v >> t) & 1
        v = ((v << 1) | fb) & 0xFF
    return out


def rtl():
    s = RTL.read_text()
    seed = int(re.search(r"localparam \[7:0\]\s+FL_SEED\s*=\s*8'h([0-9A-Fa-f]{2})", s).group(1), 16)
    addr = int(re.search(r"localparam \[15:0\]\s+FL_ADDR\s*=\s*16'h([0-9A-Fa-f]{4})", s).group(1), 16)
    n = int(re.search(r"localparam integer FL_LEN\s*=\s*(\d+)", s).group(1))
    m = re.search(r"fl_lfsr_next\s*=\s*\{v\[6:0\],\s*([^}]+)\}", s)
    taps = [int(t) for t in re.findall(r"v\[(\d+)\]", m.group(1))]
    return seed, addr, n, taps


def main():
    ok = True
    seed, addr, n, taps = rtl()
    want = lfsr(seed, n, taps)
    a = ASM.read_text()
    got = [int(x, 16) for x in re.findall(r"\$([0-9A-Fa-f]{2})", re.search(r"^fl_key\s+!byte\s+(.*)$", a, re.M).group(1))]
    port = int(re.search(r"^FLPORT\s*=\s*\$([0-9A-Fa-f]{4})", a, re.M).group(1), 16)

    def check(name, cond, detail=""):
        nonlocal ok
        print(f"  {'ok  ' if cond else 'FAIL'} {name} {detail}")
        ok &= bool(cond)

    check("key: spi.asm == the RTL's LFSR", got == want,
          f"(seed ${seed:02X}, {n} bytes, taps {taps})" + ("" if got == want else
          f"\n       rtl {' '.join(f'{x:02X}' for x in want)}\n       asm {' '.join(f'{x:02X}' for x in got)}"))
    check("address: FLPORT == FL_ADDR", port == addr, f"(${addr:04X})")
    check("address differs from DRAMa's", addr != DRAMA["addr"], f"(${addr:04X} vs ${DRAMA['addr']:04X})")
    cyc = lfsr(0x01, 255, taps)
    for s in DRAMA["seeds"]:
        d = (cyc.index(seed) - cyc.index(s)) % 255
        check(f"key windows disjoint from DRAMa seed ${s:02X}", n <= d <= 255 - n, f"({d} steps apart)")

    sys.path.insert(0, str(ROOT / "updater"))
    import mkfirmware
    py = mkfirmware.crc16_ccitt(bytes(range(256)))
    f = FLASH.read_text()
    at = re.search(r"^crc_byte\s*$", f, re.M).start()          # the routine, not a call to it
    poly = re.findall(r"eor #\$([0-9A-Fa-f]{2})", f[at:at + 600])
    check("CRC16: flash.asm polynomial is $1021", poly[:2] == ["21", "10"], f"(eor #${poly[:2]})")
    check("CRC16: mkfirmware over $00..$FF is $3FBD (the sibling's measured 6502 value)", py == 0x3FBD, f"(${py:04X})")
    print("check_key:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
