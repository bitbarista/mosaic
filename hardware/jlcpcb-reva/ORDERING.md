# Ordering MOSaic Rev A from JLCPCB

Upload the three files in this folder:

| File | What it is |
|---|---|
| `mosaic-reva-gerbers.zip` | the board |
| `mosaic-reva-bom.csv` | the parts list |
| `mosaic-reva-cpl.csv` | the placement file |

Then choose the options below. These are the settings the prototype boards were ordered
with, and JLCPCB's review accepted them unchanged. Settings in **bold** matter; the others
are JLCPCB's defaults.

## The board, as JLCPCB will measure it

Measured from `hardware/mosaic-reva.kicad_pcb` by `gen/check_order_facts.py`:

| | |
|---|---|
| Size | 20.32 × 51.40 mm |
| layers | 4 |
| Vias | **235**, all the same: 235 at 0.40 mm pad / 0.30 mm hole |
| Narrowest track | 0.10 mm |
| Component holes | 40 at 0.90 mm (the plug pins), 9 at 0.65 mm (J3's 7 programming pads and J4's 2) |

## PCB

| | | | |
|---|---|---|---|
| Base material | FR-4, TG135 | Layers | 4 |
| **Dimension** | **20.32 × 51.4 mm** — no rails billed | Qty | your choice |
| Thickness | 1.6 mm | Delivery | Single PCB, 1 design |
| **Surface finish** | **ENIG, 1 U″ gold** | Outer / inner copper | 1 oz / 0.5 oz |
| **Via covering** | **Plugged** — JLC default, no epoxy fill | Via plating method | Not specified |
| Colour / silkscreen | Green / white, ink-jet | Min via hole | 0.3 mm (0.4/0.45 mm) — free tier |
| Stackup / layer sequence | Not specified | Electrical test | Flying Probe, fully tested |
| **Mark on PCB** | **Remove Mark** | Appearance | IPC Class 2 |
| Outline tolerance | ±0.2 mm (regular) | Gold fingers / castellated / edge plating | No |
| Press-fit / blind slot / backdrill / countersink | No | Deburring | No |
| **Shortage preference** | **Require Full Quantity** | Confirm production file | No |
| Build time | standard | Package box | With JLCPCB logo |

## PCBA

| | | | |
|---|---|---|---|
| **Type** | **Economic** | Assembly side | **Top only** |
| Qty | your choice | Panel format | 1 × 1 |
| **Solder paste** | **High temp.** (lead-free) | Nitrogen reflow | Yes (included with Economic) |
| Files | "Complete File, just proceed with my own files" | Tooling holes | Added by JLCPCB |
| Confirm parts placement | No | Photo confirmation | No |
| Bake / clean / conformal coat | No | Special stencil | No |
| Flying probe (on assembly) | No | Function test | No |
| Packaging | Antistatic bubble film | Depanel + edge rail | No |
| Build time | 3–4 days | Stencil / fixture storage | No |

**Check the diode polarity in JLCPCB's placement preview:** the band on D2 and D3 at the
bottom is the cathode, on +5V; D1's cathode is on +5V_SKT.

## Parts

JLCPCB's "Selected Parts" should show these lines, none unselected:

| LCSC | part | designators |
|---|---|---|
| C2678152 | ICE40UP5K-SG48I | U1 |
| C15298 | SN74CB3T3245PWR | U2, U3 |
| C2675530 | SN74LVC541ADGVR | U4, U5 |
| C7833 | SN74LVC1G125DCKR | U6, U11 |
| C7663 | SN74LVC14APWR | U7 |
| C2843335 | W25Q16JVUXIQ | U8 |
| C603505 | NCP115ASN330T2G | U9 |
| C236672 | ME6211C12M5G-N | U10 |
| C178260 | SMF6.0A (Jingdao) | D1 |
| C8598 | B5819W SL | D2, D3 |
| C1525 | CL05B104KO5NNNC 100 nF 16 V | C1–C14 |
| C19666 | CL10A475KO8NNNC 4.7 µF 16 V | C15–C17 |
| C52923 | CL05A105KA5NQNC 1 µF 25 V | C18–C21 |
| C25744 | 0402WGF1002TCE 10.0 kΩ | R1–R4 |
| C25501 | 4D02WGJ0330TCE 4 × 33 Ω | RN1–RN8 |

**Not assembled by JLCPCB:** the 40 turned plug pins (J1, J2) and the J4 header. Fit them by
hand, see [docs/ASSEMBLY.md](../../docs/ASSEMBLY.md). J3 is seven bare plated holes for the
programming probe; nothing is fitted there.

New to JLCPCB? Signing up through [this referral link](https://jlcpcb.com/?from=PBTJYEXOJNFQR)
supports the project at no cost to you.
