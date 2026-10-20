# Known issues and operating rules

What a builder or owner needs to know. Everything here was found by measurement or by the
project's own checks.

## Operating rules

- **Program a new board on the bench, with the probe seated before the programmer's USB is
  plugged in.** Two prototype boards were lost while being programmed with the probe pressed
  onto a powered programmer. The cause has not been measured. Every board programmed in the
  order in [PROGRAMMING.md](PROGRAMMING.md#flashing) has survived, but so far that is one
  board.
- **Never power the board through J3 while it is in a C64 that is switched off.** The board
  would then feed power back into the unpowered machine through the CPU port pins. In a
  C64 that is switched **on**, or on the bench, this does not apply.
- **Keep the J4 jumper off in normal use.** While it is fitted, the C64 sees the datasette's
  PLAY key as pressed. Fit it only to update the firmware.

## Against the 6510 datasheet

The project's board checks (see `test-results/simulation/`) compare MOSaic's interface
with the AC and DC tables in the original 6510 datasheet. A few parameters fall outside
those tables. **None of them has caused a fault on hardware.**

- **AC timing, 2 parameters:**
  - Address setup time (tADS) can reach 311 ns against the table's 300 ns maximum, at the
    worst-case corner.
  - The PHI2 pulse width is within -12.7..+13.3 ns of the PHI0 half-period, against the
    table's -80..+10 ns.
- **DC levels, 38 of 175 checks:** input low threshold, typical capacitance, input leakage
  and off-state current on some pins. These are electrical properties of the FPGA and the
  buffer chips, which differ from the 1980s NMOS 6510's.

## Power-on

The FPGA's 3.3 V supply is switched on by its 1.2 V supply, in the order Lattice asks for.
The enable threshold is guaranteed only at 0.4 V, slightly below Lattice's 0.5 V figure.
No board has shown a problem. If one ever fails to start at power-on but starts after a
reset, the power-up order is the first thing to check.

## Testing so far

- One C64 so far: a PAL breadbin, board 250407. The C64C, with its 8500 CPU, has not been
  checked.
- `interrupts/irqdma/test6b` from the VICE testprogs gave one mismatch in 96 runs and could
  not be reproduced. The VICE testbench developers haven't seen this test misbehave before,
  though other tests in the testbench have needed fixing over the years. The run logs are in
  `test-results/hardware/`.
- MOSaic does not fit a 1541 or a C128, which use different CPUs.
