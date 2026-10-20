# Test results

The raw records behind the README's status section. All of them are for gateware build
`$2ECB` (`syn/build/mosaic.bin`, md5 `6a16527c77c44bc291d11e6a1fa41198`), unless noted. The
test code itself lives in the development tree and is not part of this release.

## On a real C64

PAL breadbin (250407), with an Ultimate II+ cartridge. Each `$2ECB` log records the build ID
read back from the board (`IDENT`), so every result is tied to the image that was running.

| What | File |
|---|---|
| VICE testprogs (interrupts, CIA, VIC-II, CPU): summary, with the comparison against two earlier builds | `hardware/hw_2ecb_vs_e4e7_3e5d_20261014.txt` |
| The full testprogs run, one line per test | `hardware/hw_2ecb_20261014.log` and `.json` |
| The undocumented SHA/SHX/SHY/TAS tests, 26/26 | `hardware/hw_2ecb_sh_20261014.log` and `.json` |
| The 16 screen-only `ciavarious` CIA tests, checked by eye | `hardware/ciavarious_2ecb_20261019.log` |
| `interrupts/irqdma/test6b`: the 1 mismatch and 95 reruns since | `hardware/test6b_2ecb_*` |
| DRAMscope RAM tester cartridge, 48 runs, no bad bytes | `hardware/dramscope_cart_2ecb_20261015.log` |
| The four-disk NLP demo, start to finish | `hardware/nlp_2ecb_20261015.log` |
| Firmware updates from the C64: slot B, then both slots and the header | `hardware/host_update_t65_2ecb_*` |
| The owner's update from `MOSAIC.D64`, confirmed by `IDENT` after a power cycle | `hardware/update_d64_2ecb_20261020.log` |
| The first disk-update attempt, which stalled on an earlier build (since fixed) | `hardware/update_board3.log` |

## In simulation

`simulation/gate_20261019.log` is the full simulation gate, run on this release tree. Each line
names a suite and its result:

- `cosim`, `opsweep`, `flowsweep`: every instruction compared bus cycle by bus cycle with
  perfect6502, a transistor-level simulation of the real 6502.
- `irqsweep`, `nmi_model`, `rdysweep`, `nmi2sweep`, `shsweep`: interrupt timing, double NMIs
  and the SH* opcodes, each swept against RDY stalls and compared with perfect6502.
- `mutate`: deliberate faults put into the core, to prove the tests catch them.
- `lorenz`, `klaus`: the Lorenz and Klaus Dormann CPU test suites.
- `board_*`: the board's netlist, timing at the socket, power back-feed and logic levels.
  Each check has a `_proof` partner showing it fails on a deliberately broken board.

Two kinds of FAIL appear in that log:

- **`mix`** failed only because a fresh copy of the tree lacked a build folder. After the fix,
  the rerun passed: `simulation/mix_rerun_20261020.log` ends with "2/2 checks passed".
- **`board_ac`, `board_dc`**: the comparison with the original 6510 datasheet tables. A few
  parameters fall outside them, none seen to cause a fault. See
  [docs/KNOWN-ISSUES.md](../docs/KNOWN-ISSUES.md#against-the-6510-datasheet).
