#!/usr/bin/env python3
"""
Prepare the files a user loads, and the image Carl programs at build time.

    python3 updater/mkfirmware.py syn/build/mosaic.bin

⚠ PORTED FROM c64-ice40-ram/updater/mkfirmware.py (DRAMa).  Changed for MOSaic:
the file is MOSAIC.BIN, the magic is "MOSA"/"ASOM" and the board revision 'A',
so neither board's updater accepts the other's image; and the D64 is built
here too (updater/out/MOSAIC.D64) since loose files cannot be served.  The
header format, slot layout and icemulti cross-check are unchanged.

Writes into updater/out/:

    MOSAIC.BIN        the bitstream plus its header -- this is what ships
    MOSAIC.D64        for OWNERS: UPDATE and MOSAIC.BIN
    MOSAICDEV.D64     for DEVELOPMENT: DEVUPDATE (slot B only), BOOTB, BOOTA,
                      IDENT, UPDATEDIAG and MOSAIC.BIN
    flash-initial.bin the whole 2-slot flash, for programming a NEW board

⚠ THE TRAILER EXISTS BECAUSE THE BOARD CANNOT READ ITS OWN FLASH BACK. There is
no MISO path -- handing even one bit to the C64 cost more timing than the whole
feature was worth -- so a written image can never be verified after the fact. It
can only be checked ON THE WAY PAST, as it streams from disk, which is what the
trailer is for. A corrupt download, a bad sector or a half-copied file is then
caught BEFORE the boot pointer moves, and the board keeps running what it has.

Header, 18 bytes, at the START of MOSAIC.BIN:

    "MOSA"        4   magic, so the updater refuses an unrelated file outright
    version       2   little-endian; shown to the user and checked against the board
    board rev     1   'A' -- refuses an image built for different hardware
    reserved      1
    length        4   little-endian, of the bitstream alone
    crc16         2   CCITT over the bitstream alone
    "ASOM"        4   end marker, so a truncated file cannot look complete

⚠ AT THE START, NOT THE END, AND THAT IS A 6502 CONSTRAINT. A trailer cannot be
read until the whole file has gone past, and the file is 102 KB on a machine with
39 KB free -- so the updater would have to buffer a sliding window just to find
it. A header is read once, up front, and gives the length to stream against and
the checksum to compare at the end. It also means a truncated file is caught by
running out of data before `length` bytes, rather than by a missing trailer.

⚠ The assert below is not decoration -- it caught this comment claiming 16 bytes
while the fields add to 18, which is exactly the kind of drift that would have
the 6502 reading the length from the wrong offset.
"""
import pathlib
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "updater" / "out"

MAGIC = b"MOSA"
END = b"ASOM"
BOARD_REV = ord("A")
VERSION = 1

# ⚠ 128 KB ALIGNMENT, AND IMAGE 0 ALIGNED TOO (-A, not -a). With -a16 icemulti
# leaves image 0 at 0x0000A0 -- immediately after the header, INSIDE the same
# 4 KB sector. The commit step erases that sector to rewrite the boot pointer,
# which would take the start of the image with it. -A17 puts the header alone in
# sector 0 and the slots at 0x020000 and 0x040000, clear of it and of each other
# (the image is ~102 KB, so 64 KB alignment would not have been enough either).
ALIGN = 17
SLOT_A = 0x020000
SLOT_B = 0x040000


def boot_record(addr):
    """One 32-byte multiboot record. Format confirmed against icemulti's output:
    sync, then 44 03 followed by a 24-bit big-endian boot address."""
    r = bytearray(32)
    r[0:4] = bytes([0x7E, 0xAA, 0x99, 0x7E])
    r[4:7] = bytes([0x92, 0x00, 0x00])
    r[7:9] = bytes([0x44, 0x03])
    r[9:12] = bytes([(addr >> 16) & 0xFF, (addr >> 8) & 0xFF, addr & 0xFF])
    r[12:15] = bytes([0x82, 0x00, 0x00])
    r[15:17] = bytes([0x01, 0x08])
    return bytes(r)


def crc16_ccitt(data, crc=0xFFFF):
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def main(argv):
    if len(argv) != 2:
        sys.exit(__doc__)
    src = pathlib.Path(argv[1])
    if not src.exists():
        sys.exit(f"no such bitstream: {src}")
    img = src.read_bytes()

    # ⚠ REFUSE AN IMAGE THAT WILL NOT FIT ITS SLOT. Slots are 128 KB apart; an
    # image larger than that would overwrite the next one, and the first anybody
    # would know is a board that boots something half-overwritten.
    if len(img) > (SLOT_B - SLOT_A):
        sys.exit(f"bitstream is {len(img)} bytes, larger than the "
                 f"{SLOT_B - SLOT_A} byte slot")

    OUT.mkdir(exist_ok=True)
    # a deliberately different image, only so icemulti cannot deduplicate during
    # the cross-check below
    shorter = OUT / ".half.bin"
    shorter.write_bytes(img[:len(img) // 2])
    trailer = (MAGIC + struct.pack("<H", VERSION) + bytes([BOARD_REV, 0])
               + struct.pack("<I", len(img)) + struct.pack("<H", crc16_ccitt(img))
               + END)
    assert len(trailer) == 18, len(trailer)
    (OUT / "MOSAIC.BIN").write_bytes(trailer + img)

    # ⚠ THE HEADER IS BUILT HERE, NOT BY icemulti, BECAUSE icemulti
    # DEDUPLICATES IDENTICAL IMAGES. Handing it the same bitstream twice
    # collapses both slots onto one address -- which looks like it worked and
    # would have the updater write slot B while the board boots the same bytes
    # from slot A. Verified byte-for-byte against icemulti's output below, so
    # this is a reimplementation of a known format, not a guess at one.
    hdr = (boot_record(SLOT_A)           # record 0: cold boot
           + boot_record(SLOT_A)         # record 1: warm image 0
           + boot_record(SLOT_B)         # record 2: warm image 1
           + boot_record(SLOT_A)         # record 3: unused
           + boot_record(SLOT_A))        # record 4: unused
    assert len(hdr) == 160

    flash = bytearray(b"\xff" * (SLOT_B + len(img)))
    flash[0:160] = hdr
    flash[SLOT_A:SLOT_A + len(img)] = img
    flash[SLOT_B:SLOT_B + len(img)] = img
    multi = OUT / "flash-initial.bin"
    multi.write_bytes(bytes(flash))

    # ⚠ CROSS-CHECK AGAINST icemulti EVERY RUN, using two DELIBERATELY DIFFERENT
    # images so its deduplication cannot hide a disagreement. If the reference
    # tool ever emits a different header, this stops rather than shipping a
    # boot pointer built from a format we no longer match.
    ref = OUT / ".icemulti-ref.bin"
    r = subprocess.run([str(pathlib.Path.home() / "oss-cad-suite" / "bin" / "icemulti"), "-p0", f"-A{ALIGN}", "-o", str(ref),
                        str(src), str(shorter)], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"icemulti failed:\n{r.stdout}{r.stderr}")
    if ref.read_bytes()[:160] != hdr:
        sys.exit("our header no longer matches icemulti's -- the multiboot "
                 "format has changed and the commit step must be revisited")
    ref.unlink()

    print(f"   bitstream    {len(img):>7} bytes  crc16 ${crc16_ccitt(img):04X}")
    print(f"   MOSAIC.BIN   {len(img) + 18:>7} bytes  (+18 byte header)")
    print(f"   flash-initial{multi.stat().st_size:>7} bytes")
    shorter.unlink()
    print(f"   header alone in sector 0; slots at "
          f"0x{SLOT_A:06X} and 0x{SLOT_B:06X}  (matches icemulti)")
    # the header table flash.asm writes at commit must be these bytes
    asm = (ROOT / "updater" / "flash.asm").read_text()
    tbl = asm[asm.index("\nheader\n"):asm.index("fname ")]
    got = bytes(int(x, 16) for x in __import__("re").findall(r"\$([0-9A-Fa-f]{2})", tbl))
    if got != hdr:
        sys.exit("flash.asm's header table differs from the one built here")
    print("   flash.asm's header table matches")

    # the disks.  Loose files cannot be served (README), so everything ships
    # inside a D64.  ⚠ TWO DISKS: an OWNER never sees the development tools --
    # warm-booting an untested slot is for the bench, not for a user.
    progs = {"UPDATE": ("flash.asm", []), "UPDATEDIAG": ("flash.asm", ["-DVERBOSE=1"]),
             "DEVUPDATE": ("flash.asm", ["-DDEV=1"]), "BOOTB": ("boot.asm", ["-DIMAGE=1"]),
             "BOOTA": ("boot.asm", ["-DIMAGE=0"]), "IDENT": ("boot.asm", ["-DIDENT=1"])}
    for name, (src_asm, defs) in progs.items():
        r = subprocess.run(["acme", "-f", "cbm", *defs, "-o", str(OUT / f"{name}.PRG"), src_asm],
                           cwd=ROOT / "updater", capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"acme failed on {name}:\n{r.stdout}{r.stderr}")
    for disk, label, names in (("MOSAIC.D64", "mosaic fw,01", ["UPDATE"]),
                               ("MOSAICDEV.D64", "mosaic dev,02",
                                ["DEVUPDATE", "BOOTB", "BOOTA", "IDENT", "UPDATEDIAG"])):
        d64 = OUT / disk
        if d64.exists():
            d64.unlink()
        cmd = ["c1541", "-format", label, "d64", str(d64)]
        for n in names:
            cmd += ["-write", str(OUT / f"{n}.PRG"), n.lower()]
        cmd += ["-write", str(OUT / "MOSAIC.BIN"), "mosaic.bin"]
        r = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
        if r.returncode != 0 or not d64.exists():
            sys.exit(f"c1541 failed:\n{r.stdout}{r.stderr}")
        print(f"   {disk:<14}{d64.stat().st_size:>7} bytes  ({', '.join(n.lower() for n in names)}, mosaic.bin)")
    print(f"   -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
