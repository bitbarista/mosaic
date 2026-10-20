# Programming and updating MOSaic

Fit the plug pins first ([ASSEMBLY.md](ASSEMBLY.md)), but not the J4 header yet.

A new board needs a programmer **once**, on the bench, to load its first image. From then on,
every update is done from the C64 itself, with MOSaic in the CPU socket.

| Stage | Where | Tools |
|---|---|---|
| [1. First programming](#1-first-programming) | bench, board on its own | FT232H + 7-way 1.27 mm pogo probe |
| [2. Fitting and checking](#2-fitting-it-in-the-c64) | in the C64 | none |
| [3. Two-slot layout and updates](#3-updates-from-the-c64) | in the C64 | J4 link, `MOSAIC.D64` on a disk drive or SD/USB adapter |

---

## 1. First programming

### What you need

> **Linux only.** The programming script, `syn/pogo.sh`, has only been written and tested
> for Linux. It uses `lsusb` to see the programmer arrive and `spd-say` for its spoken
> prompts.


- **An FT232H breakout board** (USB to SPI). `iceprog` drives it directly.
- **A 7-way, 1.27 mm pitch pogo probe.** J3 on the board is seven bare 1.27 mm plated holes,
  with no header fitted. The holes locate the pogo tips, so the probe is held by hand.
  A 2.54 mm probe will not fit.
  <!-- RELEASE TODO (Carl): where to buy the probe (link or part name) -->
- **A Linux PC** with `lsusb` (package `usbutils`) and, optionally, `spd-say`
  (`speech-dispatcher`).
- **`iceprog`**, from [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) or
  your distribution's `fpga-icestorm` package. `syn/flash.sh` expects OSS CAD Suite in
  `~/oss-cad-suite`; any `iceprog` on your `PATH` also works.
- **The image:** `syn/build/mosaic.bin` (build `$2ECB`, md5 `6a16527c77c44bc291d11e6a1fa41198`).
  Check the md5 before flashing.

⚠ Use `iceprog`, **not** `openFPGALoader`. The version tested (v0.13.1) reported success
without writing anything to this flash chip.

### Wiring the probe

| J3 pin | Signal | FT232H pin |
|---|---|---|
| 1 | VPROG (power in) | 5V |
| 2 | GND | GND |
| 3 | SPI_CS_N | D4 |
| 4 | SPI_SCK | D0 |
| 5 | SPI_MOSI | D1 |
| 6 | SPI_MISO | D2 |
| 7 | CRESET_N | D7 |

J3 has no pin 1 mark of its own. **Pin 1 is the pad at the left-hand end of the row, next to
the plug-pin column, with the board's notch end (semicircle) at the top:**

<p align="center"><img src="../hardware/render/mosaic_top_marked.png" width="800" alt="MOSaic top view: notch end, pin 1, J3 pin 1 and J4 marked"></p>

- **No series resistors in the data lines.** 1 kΩ resistors in the D lines broke the ID read.
- **Meter the probe before first use.** Pin 1 to pin 2 must read +5 V at the tips. If the
  connector is shifted one pin on the FT232H header, USB 5 V is shorted to ground.
- The board is powered through VPROG, so it needs no other supply.

### Flashing

Do this with the board **out of the C64** and with **J4 not fitted**, because the J4
header gets in the way of the probe.

1. With the programmer's USB **unplugged**, start the script:

   ```
   syn/pogo.sh --usb-last syn/build/mosaic.bin
   ```

   If the FT232H is already plugged in, it asks you to unplug it and waits until you do.
   Everything from here on is hands-free. The script speaks each step, so your eyes and
   both hands can stay on the probe.
2. When it says **"seat the probe, then plug in the programmer"**, press the probe onto J3
   and hold it still.
3. Plug the programmer's USB in. The script sees it arrive and reads the flash ID
   (`EF 40 15`, a Winbond W25Q16JV). It says **"contact"**, then writes and verifies the
   image.
4. It says **"pass"** only when the verify succeeds. Anything else is **"fail"**, and
   nothing is written if the ID read fails.
5. When it says **"unplug the programmer, then lift the probe"**, do exactly that, in that
   order.

If it failed, run the script again from step 1.

The spoken prompts use `spd-say` (speech-dispatcher) if it is installed. Otherwise the
terminal beeps and the prompts are printed.

**Why this order matters.** Two prototype boards were lost while being programmed with the
probe pressed onto a powered programmer. The cause has not been measured. Every board
programmed in the order above has survived, but so far that is one board, so treat the
order as required. See [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

⚠ **Never program a board that is in a switched-off C64.** VPROG would back-feed the
unpowered machine through the CPU port pins.

---

## 2. Fitting it in the C64

1. C64 **off and unplugged**.
2. Remove the 6510, noting which way round it was, and fit MOSaic in its socket the same way.
   The semicircle marking and the pin 1 mark on MOSaic's board go at the same end as the notch
   on the 6510 and on the socket (see the picture in [Wiring the probe](#wiring-the-probe)).
3. Power on. The C64 should start to the normal BASIC screen.

MOSaic fits a C64 with a **socketed** 6510. It has been tested in a breadbin 250407 board.
The C64C has not been checked. It does not fit a 1541 or a C128.

---

## 3. Updates from the C64

A freshly programmed board holds a single image. The first update converts it to the
**two-slot layout**:

- **Slot A** is always the image that runs after power-on.
- **Slot B** is the backup.

An update writes both slots and checks them, and the boot header is rewritten last. If an
update is interrupted, the board still starts from the slot that was not being written. Run
the update again straight away.

### J4: the update link

J4 is a 2-way 1.27 mm header, fitted by the owner and not part of the assembly order. With
a jumper on J4, a program on the C64 can unlock and write the flash. Without it, nothing
can, so normal use never touches the flash.

### Running an update

Tested on hardware with build `$2ECB`: the owner's steps below, from `MOSAIC.D64` on an
Ultimate II+ USB stick, then a power cycle (`test-results/hardware/update_d64_2ecb_20261020.log`).

1. C64 **off**. Fit the jumper on **J4**.
2. Power on. From `MOSAIC.D64` on a disk drive or SD/USB adapter:

   ```
   LOAD"UPDATE",8,1
   RUN
   ```

3. Wait for `UPDATE COMPLETE`.
4. Power off, **remove the J4 jumper**, power on.

Don't skip removing J4. While it is fitted, the KERNAL sees the datasette's PLAY key as
pressed, so a connected datasette's motor runs.

**Use the `.D64`, not a loose `.BIN`.** SD/USB adapters won't open a bare `.BIN` as a file,
and the failure looks exactly like a broken updater.

`updater/out/MOSAIC.D64` holds the `$2ECB` image. To build one from your own bitstream, use
`python3 updater/mkfirmware.py syn/build/mosaic.bin`, which needs
[acme](https://sourceforge.net/projects/acme-crossass/).

### More detail

`updater/README.md` covers how the updater reaches the flash, the flash layout, the
development tools (`DEVUPDATE`, `BOOTB`, `IDENT`) and the simulation tests behind them.
