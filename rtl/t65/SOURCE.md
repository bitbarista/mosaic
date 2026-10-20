# Where rtl/t65 comes from

The T65 core at FPGAARCADE SVN rev 1347 (T65.vhd, 2015-05-27, "Ver 313 WoS
January 2015"; T65_ALU/MCode/Pack.vhd rev 1234, 2015-02-28), as released, under
its BSD licence (header of each file).  Nothing later than that release.

The FPGAARCADE SVN (svn.fpgaarcade.com) no longer answers (HTTP 500,
2026-10-12), so the files were taken from public copies of that release, held
byte-identical (line endings aside) by three unrelated owners:

| file | md5, CR stripped | md5 as committed (CRLF) |
|---|---|---|
| T65.vhd       | 1c23b071... | ca81a547... |
| T65_ALU.vhd   | ad5f508b... | e85de648... |
| T65_MCode.vhd | c2fcf61e... | 5f1350f7... |
| T65_Pack.vhd  | 7a529a09... | f6494c28... |

- github.com/mandl/Apple_II_vhdl `src/cpu/t65/` (the committed bytes)
- github.com/zxdos/zxuno `cores/BBCMicro/src/T65/` (and two more cores there)
- github.com/Gehstock/Mist_FPGA `Computer_MiST/Acorn - Electron_MiST/rtl/T65/`

Every other rev-1347 copy found on GitHub is this set plus additions (extra
ports, a changed reset I flag), which marks this set as the unmodified one.

Local changes are made only from this project's own evidence (datasheet,
perfect6502, hardware tests), kept as patches in `patches/`, and listed in
`NOTICE`.

perfect6502 is a test-only reference and is not part of the
product. It checks the core's behaviour against the real die. Its simulator
is MIT; its die netlist (`netlist_6502.h`) is CC BY-NC-SA 3.0. Nothing from it
is copied into the RTL: no node names, no signal structure, no state encoding.
Each local fix states the die's behaviour in this project's own terms, and
perfect6502 only confirms the result.
