# Firmware updater (DEFERRED D-7)

Rewrites MOSaic's configuration flash **from the C64 it is the CPU of**. No
programmer touches the board. **In-system programming through J3 is suspended**
(ERRATA E-48: two boards were lost during J3 programming, cause unproven); this
is the route that replaces it.

Ported from `c64-ice40-ram/updater` (DRAMa), whose README is worth reading.
What carries over unchanged: the FPGA holds no protocol (the flash opcodes live
in the `.prg`), there is a header with a CRC16, **both** slots are written, and
the boot header is rewritten last, alone in its 4 KB sector.

## What the owner does

1. C64 **off**. Fit the **J4** link (PROG_EN, SETTLED S-19).
2. Power on. `LOAD"UPDATE",8,1` and then `RUN`, from `MOSAIC.D64`.
3. When it says `UPDATE COMPLETE`: power off, **remove J4**, power on.

With J4 left fitted, the flash port can still be unlocked, and the KERNAL sees
PLAY pressed, so a connected datasette's motor runs. Removing J4 is part of
finishing the update, not an optional tidy-up.

## How it reaches the flash

| flash pin | net | how the updater drives it |
|---|---|---|
| CLK | P5 | `$01` bit 5, as an output |
| DI | P2 | `$01` bit 2 (CHAREN), as an output |
| DO | P3 | `$01` bit 3, as an **input**. `cpu6510.v`'s `p3_live` reads the pin while /CS is low |
| /CS | SPI_CS_N | **the gateware**: write `$00`/`$04` to `$CE00` (bit 2 = /CS), after the unlock |

The unlock is `rtl/cpu6510.v`'s "flash port" block. Both conditions are needed:

- **J4**: P4 held low *from outside* with DDR bit 4 clear. No program can fake
  this. If the link comes off at any moment, the port locks and /CS goes high.
- **The key**: sixteen LFSR bytes (seed `$3C`) written consecutively to `$CE00`.
  Any other value restarts it, and `$80` or above locks the port again.

⚠ **It must never match DRAMa.** DRAMa uses `$CF00` with seeds `$A5`/`$4B`. These
are ordinary CPU writes that reach RAM, so a DRAMa in the same machine sees all
of them. `check_key.py` proves that the addresses differ and that the key
windows are disjoint (98 and 225 LFSR steps apart).

## What is different from DRAMa, and why

- **Readback works.** MISO is a port pin the CPU reads, so the busy flag is
  **polled** rather than waiting out datasheet maxima. Each slot is also **read
  back and checksummed before the boot pointer moves to it**, and the header is
  read back after it is written. DRAMa can check the file only as it streams past.
- **The file's header is checked before anything is erased.** A foreign,
  truncated or wrong-board file changes nothing.
- **SPI mode 3**, with the clock idling high. CLK is `/CASS_MOTOR`, and the
  KERNAL keeps it high (motor off).
- **CHAREN follows MOSI.** While a transaction runs, `$D000` is character ROM.
  Interrupts are therefore off from `spi_select` to `spi_release`, and nothing
  touches I/O in between.
- **The KERNAL's IRQ runs the tape motor on P5** whenever the sense line (P4)
  reads low, and J4 holds P4 low. The updater sets `$C0` (CASS1) to stop that,
  and restores it at the end.
- **The file is `MOSAIC.BIN`** with magic `MOSA`…`ASOM`, revision `A`. Neither
  board's updater accepts the other's file.

## The development loop: golden slot A, experimental slot B

The updater runs on the CPU it replaces. A gateware build that breaks the CPU
therefore cannot run the updater to undo itself. So during development an
experimental image **never becomes the power-on image**:

| | |
|---|---|
| **slot A = golden** | the cold boot (header record 0). Development never writes it. |
| **slot B = experimental** | written only by `DEVUPDATE`, entered only by `BOOTB` |

1. `DEVUPDATE` (from `MOSAICDEV.D64`) writes `mosaic.bin` to **slot B only**,
   then reads it back and checks it. Slot A and the boot header are never
   touched (`test_updater.py` case H checks them byte for byte).
2. `BOOTB` warm-boots into slot B (`SB_WARMBOOT`, image 1 = header record 2).
   The machine restarts as if from /RES.
3. `IDENT` prints the running build's ID. Run it before trusting any result:
   the ID is read back from the gateware itself (`BUILD_ID`, a hash of the RTL
   set by `syn/synth.sh`). It is also left at `$02F8`/`$02F9` for the
   Ultimate's readmem.
4. **A power cycle always returns to slot A.** If B is broken, switch off and on.
5. To make B the new golden image, run the owner's `UPDATE` with it, which writes
   both slots and the header. Do that only after B has itself run `DEVUPDATE`
   successfully: that proves the image can still update itself.

`BOOTB`, `BOOTA`, `IDENT` and the warm boot all need J4 and the key, exactly as
the flash does. Without J4 nothing can warm-boot, so an owner, who never fits
J4, cannot reach any of this by accident.

Every program leaves `RESULT` at `$02F0` for remote runs: `$00` done, `$FF`
failed, `$AA` still running.

## Building

    python3 updater/mkfirmware.py syn/build/<image>.bin
    python3 updater/check_key.py

Outputs go to `updater/out/`:

| file | what it is |
|---|---|
| `MOSAIC.D64` | for owners: `update` and `mosaic.bin`. **This is what ships.** |
| `MOSAICDEV.D64` | for development: `devupdate`, `bootb`, `boota`, `ident`, `updatediag`, `mosaic.bin` |
| `MOSAIC.BIN` | the bitstream with its 18-byte header |
| `flash-initial.bin` | the whole two-slot flash, for a **new** board's first programming |

⚠ **Ship the D64.** A USB/SD adapter will not serve a loose `.BIN` as a PRG
file. It fails at OPEN, and that looks exactly like a broken updater (DRAMa,
2026-09-05).

## Flash layout

| address | contents |
|---|---|
| `$000000` | multiboot header, alone in its 4 KB sector |
| `$020000` | slot A |
| `$040000` | slot B |

**A board still on iceprog's plain layout** (one image at `$000000`, as every
Rev A board is today) **upgrades through the same steps.** Both slots lie above
the old image. Step 2's header erase takes only the old image's first 4 KB, and
it happens after slot B has been written and verified. `test_updater.py` starts
every case from that plain layout.

## The gates

`python3 updater/check_key.py` checks that the key, address and CRC agree across the RTL,
the `.asm` and the Python. The updater's simulation tests (the flash port against a W25Q16
model, and the unmodified updater end to end on the RTL) are part of the development tree;
their results are in `test-results/simulation/mix_rerun_20261020.log`.

## Still open

- **Hardware.** On board #3, the updater has rewritten slot B from build `$2ECB` and then
  done a full update (both slots and header), checked by cold boot and `IDENT`. Both runs fed
  the image over the Ultimate's API (`-DHOST`). The disk route,
  `UPDATE` from `MOSAIC.D64`, stalled at OPEN in its first attempt on an earlier build
  (`test-results/hardware/update_board3.log`; flash untouched, cause not found). On `$2ECB` it
  completed (2026-10-20, `test-results/hardware/update_d64_2ecb_20261020.log`): `UPDATE COMPLETE`,
  then `IDENT` read `$2ECB` warm and after a power cycle.
- **A new board's first programming** still needs a programmer, once, to put an
  image containing this gateware into the flash. Do it on the bench, never in
  a C64, with `syn/pogo.sh --usb-last syn/build/mosaic.bin` (E-48), with NO
  series resistors: 1 kΩ in the D lines broke the ID read (`EE 00 00`), for a
  reason not yet understood. Then `UPDATE`, run through the C64, converts the
  plain layout to the two slots; `test_updater.py` case A starts from exactly
  that layout. **J4 must not be fitted yet:** its header gets in the way of the pogo
  probe (Carl, 2026-10-05), and iceprog does not need it. Fit J4 after that
  first flash, and leave it fitted for development sessions.
- **Interrupted updates** behave as DRAMa's do. If step 3 is interrupted the
  board still works on B, but a second interrupted update could then land on
  the live slot. If an update is interrupted, run it again.
