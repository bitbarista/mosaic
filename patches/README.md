# Local patches to third-party RTL

`rtl/t65/` is the unmodified 2015 T65 release (FPGAARCADE SVN rev 1347),
imported byte-for-byte in commit `77dbf88`; its provenance and hashes are in
`rtl/t65/SOURCE.md`. Every local change lives here as a patch against that
release, so the divergence stays auditable, and each is marked `LOCAL PATCH`
in the source with its ERRATA number.

BSD-3-Clause permits modification; the copyright notice stays in place and is
unaltered. `NOTICE` lists the same changes for the product documentation.

| patch | ERRATA | what |
|---|---|---|
| `01-t65-e10-e11-e41-e51-alu-latch.patch` | E-10, E-11, E-41, E-51 | A taken branch reads `PC+2` (the address comes from `PC`, not `PCAdder`). JAM/KIL freezes the CPU with the bus at `$FFFF, $FFFE, $FFFE, $FFFF...`. ANE's constant is `$EF`, or `$EE` when RDY held the operand cycle. Reset decrements S three times (reads at `$01C0/BF/BE` from S=`$C0`), sets I and leaves D alone. `T65_ALU.vhd`: a default `Q2_t := BusA` so the ALU has no latch. |
| `02-t65-e52-sh-page-cross.patch` | E-52 | SHA/SHX/SHY/TAS: when the index carries into the high byte, the write goes to the page of the value written, as perfect6502 does. |
| `03-t65-e39-e53-rdy-held-interrupts.patch` | E-39, E-53 | **E-39:** IRQ is latched every cycle; while RDY holds an instruction's last cycle the interrupt decision is re-polled on every repeat, with the I flag as CLI/SEI have just written it; a branch polls in its operand cycle. **E-53:** an NMI that hijacks BRK/IRQ keeps the `$FFFA/B` vector when RDY holds the vector read. |
| `04-t65-e54-sh-rdy-held.patch` | E-54 | SHA/SHX/SHY/TAS: when RDY held the read step just before the write, the value is stored without the `and (H+1)` term; on a page crossing the page is still the masked value (perfect6502; VICE testprogs `CPU/sha`, `shs`, `shxy` 2-5 on the real C64). |

## Reproducing `rtl/t65/`

1. Take the four 2015 files (hashes in `rtl/t65/SOURCE.md`) and convert them
   from CRLF to LF line endings. The patches are made on LF files.
2. Apply in order with `patch -p3` from inside `rtl/t65/`:
   `01-…`, `02-…`, `03-…`, `04-…`.

The result is byte-identical to `rtl/t65/` (checked 2026-10-14, with patch 04). `T65_Pack.vhd` and `T65_MCode.vhd` carry no local changes.
