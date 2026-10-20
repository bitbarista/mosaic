# `rtl/` — the CPU

| file | licence | what |
|---|---|---|
| `t65/T65.vhd`, `T65_ALU.vhd`, `T65_MCode.vhd`, `T65_Pack.vhd` | **BSD-3-Clause** | the 6502 core, unmodified |
| `cpu6510.v` | this project | the 6510 wrapper: I/O port, bus interface, PHI2 |

## Licence, and the file that is missing on purpose

T65 is BSD-3-Clause — Daniel Wallner, Mike Johnson, Wolfgang Scherr, Morten
Leikvoll, 2002–2015. **All four files carry the header**, checked individually;
it is not enough that `T65.vhd` does. Sellable in a product provided the
copyright notice is reproduced in the documentation and the authors' names are
not used to endorse it.

⚠ **`C64_MiSTer/rtl/cpu_6510.vhd` IS NOT HERE AND MUST NOT BE ADDED.** It does
exactly the job `cpu6510.v` does, and it is Peter Wendrich's FPGA-64:

> "The source-code (VHDL) of FPGA-64 is made available strictly for personal
> educational purposes. It is not allowed to copy, upload or redistribute this
> work in any way, neither in original form nor with additional files or
> changes."

`cpu6510.v` was written from the MOS 6510 datasheet
(`datasheets/audit/MOS_6510.txt`) instead. A DDR at $0000 and a port at $0001
is the part's documented specification, not anyone's implementation of it.

## Size

    SB_LUT4     1063 of 5280 on a UP5K   (20%)
    flip-flops   183
    carries      137

T65 alone is 1055, so the wrapper costs **8 LUTs**. `syn/synth.sh` gates at 60%
of the device — the number is worth knowing mainly so that it is noticed when
it moves.

## Design notes that are not obvious from the code

- **T65 runs on the fabric clock with a one-cycle `Enable`.** The enable is a
  single pulse on PHI0's rising edge, so the core advances exactly one 6510
  cycle per machine cycle. PHI0 is asynchronous to the fabric clock and is
  synchronised through two flops before its edge is detected — a metastable
  sample would otherwise become a missed or doubled CPU cycle.
- **The address bus and R/W are driven continuously.** The board's '541s
  tri-state them from `/AEC` in hardware. Only D0–D7 need the FPGA's own
  tri-state, because they pass through a bus switch, which has no direction
  control.
- **The port pins are driven bit-by-bit from the DDR**, because the port is
  bit-by-bit programmable. Reading $0001 returns the latch for output bits and
  the pin for input bits.
- **Accesses to $0000/$0001 never reach the bus.** The port is inside the CPU,
  so the core is shown the port's value and `d_drive` is suppressed.

## Not done yet

- **PHI2 has no delay.** A real 6510 delays it from PHI0 by 30–40 ns. Here it
  follows PHI0 with gate delay only. PHI2 reaches only CIA1, CIA2, SID and the
  expansion port, so this is a cartridge-compatibility parameter — but it must
  be **measured on a real 6510** before it is settled, not guessed.
- **Port bits 6 and 7.** The 6510 register is 8 bits and only 6 have pins.
  Their read-back behaviour, and the capacitive decay of bits set to input, are
  not modelled.
- **Nothing is verified.** No simulation of any kind has been run: no
  perfect6502 co-simulation, no Klaus Dormann functional test, no Lorenz suite.
  Synthesising is not evidence that it works.
