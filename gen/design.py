#!/usr/bin/env python3
"""The 6510 board's design: parts, FPGA pin assignment, and connectivity.

SINGLE SOURCE OF TRUTH.  gen_pcb.py owns geometry and nothing else.

Coordinates here are the pin-field frame from derivation/pinmap.py: origin at
the centre of the DIP-40 field, +y UP, pin 1 top-left.  gen_pcb.py flips y for
KiCad.

Topology (derivation/pinmap.py):
    LEFT  column = inputs (pins 1-5) then A0-A13
    RIGHT column = A14/A15, P5-P0, D7-D0, R/W, PHI2, /RES
so each package sits beside the pins it serves and pad->package routes are
short, parallel and non-crossing.
"""

# ---------------------------------------------------------------- identity
# ⚠ MUST MATCH gen/rev.sh.  Two files hold these because the shell scripts
# cannot import Python and the Python cannot source shell; verify.sh checks
# they agree, because ERRATA E-16 is precisely this shape of mistake.
# ⚠ "MOSaic" IS MIXED CASE ON PURPOSE and must not be upper-cased for the
# silkscreen -- the capital MOS is the whole point of the name (SETTLED S-18).
BOARD_NAME = "MOSaic"
SLUG       = "mosaic"
REV        = "A"
REVSLUG    = f"{SLUG}-rev{REV.lower()}"

# --------------------------------------------------------------- iCE40 pins
# SG48 power/config map taken from c64-ice40-ram/hardware/c64ram.net, which is
# fabricated and working -- not re-read from the datasheet.
FPGA_POWER = {1:"+3V3", 22:"+3V3", 24:"+3V3", 33:"+3V3",
              5:"+1V2", 29:"+1V2", 30:"+1V2", 49:"GND"}
FPGA_CFG   = {7:"CDONE", 8:"CRESET_N"}

# ⚠ QFN-48 edges (KiCad y DOWN, verified against the footprint file):
#     1-12 LEFT   13-24 BOTTOM   25-36 RIGHT   37-48 TOP
# The chain runs U7,U2,U1,U4,U3,U5 from +y to -y, so in BOARD terms U1's
# "TOP" edge (37-48) faces U2 (data) and "BOTTOM" (13-24) faces U4 (address).
#
# ⚠ FIXED BY SILICON, NOT CHOSEN: 14=SPI_SO(MOSI) 15=SPI_SCK 16=SPI_SS(CS)
#   17=SPI_SI(MISO).  Everything else is a free permutation (the DRAM board's
#   EDD 5.3 argument applies unchanged).
# ⚠ 39/40/41 are the RGB pins -- OPEN-DRAIN General I/O per FPGA-DS-02008.
#   They carry INPUTS ONLY, and the three chosen are the 3K3 open-collector
#   wire-OR nets that were going to need Schmitt conditioning anyway.
# ⚠ Globals on SG48 are 20/35/37/44.  PHI0 takes 44 (top edge, beside U7).
FPGA_PINS = {
    # TOP edge (37-48) -- faces U2, the data switch
    44:"PHI0",  37:"D0", 38:"D1", 42:"D2", 43:"D3",
    45:"D4", 46:"D5", 47:"D6", 48:"D7",
    39:"IRQ_N", 40:"NMI_N", 41:"RES_N",          # RGB pins, inputs only
    # RIGHT edge (25-36) -- faces the right gutter
    35:"AEC", 36:"RDY", 25:"P0", 26:"P1", 27:"P4",
    28:"A14", 31:"A15", 32:"RW", 34:"PHI2",
    # BOTTOM edge (13-24) -- faces U4, the low address buffer
    14:"P2", 15:"P5", 16:"SPI_CS_N", 17:"P3",     # 14/15/17 SHARED with the port
    13:"A0", 18:"A1", 19:"A2", 20:"A3", 21:"A4", 23:"A5",
    # LEFT edge (1-12) -- faces the left gutter, where A6-A13 land
    11:"A6", 12:"A7", 2:"A8", 3:"A9", 4:"A10", 6:"A11", 9:"A12", 10:"A13",
}
assert len(FPGA_PINS) == 39, len(FPGA_PINS)
assert not (set(FPGA_PINS) & set(FPGA_POWER)), "signal on a power pin"

# ⚠ THE FLASH SHARES THREE PORT LINES, AND THE CHOICE IS FROM THE 250407
# NETLIST, NOT INTUITION.  P5 /CASS_MOTOR (2 pads: R4 only), P3 /CASS_WRT
# (2 pads: FB1 only) and P2 CHAREN (3 pads: R43, U17) are the only 6510 pins
# nothing in the machine drives.  Wiggling CHAREN for ~100 ms during
# configuration flips the memory map while nothing is executing -- the CPU is
# this board.  SPI_CS_N stays DEDICATED: deep power-down is not a decade-scale
# defence against a stray $AB.
SPI_SHARED = {"SPI_MOSI":"P2", "SPI_SCK":"P5", "SPI_MISO":"P3"}

# --------------------------------------------------------------- packages
# ⚠ ONE TABLE.  MPN, schematic symbol and footprint for every part live here and
# nowhere else.  They used to live in three files -- design.py, gen_pcb.py's FP
# overrides and symmap.py's SYMBOL -- and drifted: design.py still named the
# '244 after the board had moved to the '541, the 2G125 after it had moved to
# two 1G125s, and the 0.65 mm TSSOP after the packages had moved to 0.5 mm
# VSSOP to shorten the chain.  Six of fourteen parts disagreed, and nothing
# could see it because each file was self-consistent.
#
# ⚠ THE PACKAGE SUFFIX IN AN MPN IS A CLAIM ABOUT PHYSICAL SIZE, and
# check_bom_packages.py is the only thing that tests it.  D1 was SMAJ6.0A
# (an SMA part) placed on a SOD-123 land pattern; a full route, DRC and a
# schematic parity check all passed.
#
# ref, MPN, symbol (lib:name), footprint, what it does, 6510 pins served
PARTS = [
 ("U1", "ICE40UP5K-SG48I", "FPGA_Lattice:ICE40UP5K-SG48ITR",
  "Package_DFN_QFN:QFN-48-1EP_7x7mm_P0.5mm_EP5.6x5.6mm", "FPGA", []),
 ("U7", "SN74LVC14APWR", "74xx:74HC14", "Package_SO:TSSOP-14_4.4x5mm_P0.65mm",
  "hex Schmitt inverter - the 6 inputs", [1, 2, 3, 4, 5, 40]),
 ("U2", "SN74CB3T3245PWR", "mosaic:SN74CB3T3245", "Package_SO:TSSOP-20_4.4x6.5mm_P0.65mm",
  "octal bus switch - D0-D7", list(range(30, 38))),
 ("U4", "SN74LVC541ADGVR", "74xx:74HCT541", "Package_SO:TSSOP-20_4.4x5mm_P0.4mm",
  "octal buffer /OE=/AEC - A0-A7", list(range(7, 15))),
 ("U3", "SN74CB3T3245PWR", "mosaic:SN74CB3T3245", "Package_SO:TSSOP-20_4.4x6.5mm_P0.65mm",
  "octal bus switch - P0-P5 (6 of 8)", list(range(24, 30))),
 ("U5", "SN74LVC541ADGVR", "74xx:74HCT541", "Package_SO:TSSOP-20_4.4x5mm_P0.4mm",
  "octal buffer /OE=/AEC - A8-A15", list(range(15, 21)) + [22, 23]),
 ("U6", "SN74LVC1G125DCKR", "74xGxx:74LVC1G125", "Package_TO_SOT_SMD:SOT-353_SC-70-5",
  "buffer, /OE=/AEC - R/W", [38]),
 ("U11", "SN74LVC1G125DCKR", "74xGxx:74LVC1G125", "Package_TO_SOT_SMD:SOT-353_SC-70-5",
  "buffer, always on - PHI2", [39]),
 ("U8", "W25Q16JVUXIQ", "mosaic:W25Q16JV_UX",
  "Package_SON:Winbond_USON-8-1EP_3x2mm_P0.5mm_EP0.2x1.6mm", "configuration flash", []),
 ("U9", "NCP115ASN330T2G", "Regulator_Linear:NCV8114ASN330T1G",
  "Package_TO_SOT_SMD:SOT-23-5", "+3V3 LDO", []),
 ("U10", "ME6211C12M5G-N", "Regulator_Linear:NCV8114ASN330T1G",
  "Package_TO_SOT_SMD:SOT-23-5", "+1V2 LDO, enables U9", []),
 # ⚠ SMF6.0A, NOT SMAJ6.0A.  "SMAJ" IS THE SMA PACKAGE.  200 W, 6 V standoff,
 # unidirectional -- ample for a TRANSIENT suppressor, which is all a TVS can
 # be here (it cannot protect against a PSU rail that drifts high and stays
 # there; c64-ice40-ram README 5.7 on D4 says so of its own).
 # ⚠ SOD-123 and SOD-123F are NOT the same land pattern: pads at +/-1.65 with
 # 0.90x1.20, against +/-1.40 with 1.10x1.10.
 ("D1", "SMF6.0A", "Device:D_TVS", "Diode_SMD:D_SOD-123F", "TVS on the socket +5V", []),
 ("D2", "B5819W", "Device:D_Schottky", "Diode_SMD:D_SOD-123",
  "back-feed block, anode at the socket", []),
 ("D3", "B5819W", "Device:D_Schottky", "Diode_SMD:D_SOD-123",
  "VPROG -> +5V, so the programmer can power the board", []),
 # ⚠ THE PLUG PINS ARE A PART SELECTION AND THEY ARE NOT ON THE JLC BOM.
 # M-3: the owner hand-solders them after SMT, exactly as on the DRAM board,
 # whose Rev C JLC BOM carries zero J-lines.  They MUST be turned (round,
 # machined) pins: a square 0.64 mm post wedges in a DIP socket's dual-wipe
 # contact and splays it permanently.  "TURNED PIN" in a description is not a
 # specification, so the part is named here.
 ("J1", None, "Connector_Generic:Conn_01x20", "mosaic:PlugHeader_1x20_P2.54mm_Machined",
  "plug pins, 6510 pins 1-20 -- Switch Electronics 550951, OWNER-FITTED", []),
 ("J2", None, "Connector_Generic:Conn_01x20", "mosaic:PlugHeader_1x20_P2.54mm_Machined",
  "plug pins, 6510 pins 21-40 -- Switch Electronics 550951, OWNER-FITTED", []),
 # ⚠ NO CONNECTOR IS FITTED.  SETTLED S-14: bare pads for a pogo-pin jig.  The
 # MPN is None because there is no part to buy, which is also what keeps J3 out
 # of the BOM -- the same mechanism that keeps the owner-fitted plug pins out.
 ("J3", None, "Connector_Generic:Conn_01x07", "mosaic:ProgPads_1x07_P1.27mm",
  "programming PADS for a pogo jig -- the iCEBreaker Bitsy signals, 7 of them", []),
 # ⚠ OWNER-FITTED, like J1/J2 and like c64-ice40-ram's own J13, which is
 # absent from that project's CPL too.  MPN None keeps it out of the BOM.
 # ⚠ 1.27 mm PITCH, NOT 2.54, AND THE REASON IS THE PLUG PIN BESIDE IT.
 # Carl: "The former is too close to pin 21 of the IC pins."  Measured: the
 # 2.54 mm part put J4.1 within 0.80 mm edge-to-edge of J2.2 -- a turned pin the
 # OWNER HAND-SOLDERS, with an iron, after the board is assembled.  0.80 mm is
 # not a DRC problem; it is an iron-tip problem, and S-12/E-12 already record
 # this project confusing the two once.  The 1.27 mm part is 1.00 x 2.27 mm of
 # copper against 1.70 x 4.24, so it gives the clearance back twice over.
 # ⚠ THIS IS WHERE THE BOARD STOPS COPYING c64-ice40-ram's J13, which is 2.54.
 # That board's jumper has no hand-soldered plug pin next to it.
 ("J4", None, "Connector_Generic:Conn_01x02",
  "Connector_PinHeader_1.27mm:PinHeader_1x02_P1.27mm_Vertical",
  "PROG_EN jumper, 1.27 mm -- bridge to enable flash writes (D-7), OWNER-FITTED", []),
 ("TP1", None, "Connector:TestPoint", "TestPoint:TestPoint_Pad_D1.0mm", "CDONE", []),
]

# Generated passives.  Values are per-group, not per-part.
PASSIVES = (
    # ⚠ FOUR 10k CONFIG PULL-UPS -- ERRATA E-20.  This board had NO discrete
    # resistors at all, and therefore no pull-up on the FPGA's reset, the
    # flash's chip select, CDONE or the config clock.  The sibling has all four.
    [(f"R{i}", "10k", "Device:R", "Resistor_SMD:R_0402_1005Metric",
      "config pull-up") for i in range(1, 5)]
    + [(f"RN{i}", "33R x4 array", "Device:R_Pack04",
      "Resistor_SMD:R_Array_Convex_4x0402", "series damping") for i in range(1, 9)]
    + [(f"C{i}", "100n", "Device:C", "Capacitor_SMD:C_0402_1005Metric", "decoupling")
       for i in range(1, 15)]
    + [(f"C{i}", "4u7", "Device:C", "Capacitor_SMD:C_0603_1608Metric", "bulk")
       for i in range(15, 18)]
    # ⚠ C18-C21 ARE NOT BULK, they are U9's and U10's input and output
    # capacitors (ERRATA E-18) and they must sit AT the regulator pins.
    # ⚠ 0402, NOT 0603, AND THAT IS WHY THEY FIT.  Four 0603s at the LDO end
    # could not be placed at all -- all four fell through gen_pcb.py's
    # anywhere-on-the-rail fallback and landed ~29 mm away, which is the very
    # fault being fixed.  1uF meets both datasheets (ME6211C12 and NCP115 each
    # specify >= 1uF in and out); the extra capacitance of a 4u7 is worth less
    # than being at the pin.
    + [(f"C{i}", "1u", "Device:C", "Capacitor_SMD:C_0402_1005Metric", "LDO in/out")
       for i in range(18, 22)])

# ------------------------------------------------------------------ LCSC
# ⚠ ORDERING CODES, CHECKED AGAINST JLCPCB 2026-09-09.  They live here, beside
# the MPN they belong to, for the same reason everything else does: they used to
# be a column somebody filled in by hand at ordering time, which is how a board
# gets built from a part nobody chose.
#
# ⚠ A CODE IS A CLAIM ABOUT A DATE, NOT A FACT.  Stock moves; re-check before
# ordering.  The figures are what was on the shelf when each was chosen, and are
# recorded so a later shortage is visible as a CHANGE rather than a surprise.
#
# ⚠ AND A SUBSTITUTION SILENTLY INVALIDATES THE ROTATION CHECK.  In the DRAM
# project a rotation override measured on C892048 survived a swap to C236672 and
# shipped a part 90 degrees out.  If a code changes here, that part's rotation
# is unverified again.
LCSC = {
    # passives -- both Basic parts, no feeder fee
    **{f"C{i}":  "C1525"     for i in range(1, 15)},   # 100nF 0402 16V X7R, 35.3M
    **{f"C{i}":  "C19666"    for i in range(15, 18)},  # 4.7uF 0603 16V X5R, 3.89M
    # ⚠ NOT A GUESS.  C52923 is the part c64-ice40-ram already uses for its own
    # LDO input cap ("1uF 0402 25V X5R, Basic -- U8 CIN", gen_sch.py:502), so it
    # is a Basic part that has been through a real order.  There is NO Basic
    # 4.7uF 0402 at 16V -- that project checked, and it is why its bulk caps are
    # 0603 in the first place.
    **{f"C{i}":  "C52923"    for i in range(18, 22)},  # 1uF 0402 25V X5R, Basic
    **{f"RN{i}": "C25501"    for i in range(1, 9)},    # 4D02WGJ0330TCE 33R x4, 193k
    # ⚠ NOT A GUESS: C25744 is the 10k 0402 c64-ice40-ram ordered for its own
    # config pull-ups (R9/R10/R15/R21), so it is a Basic part with an order
    # behind it.  ERRATA E-20.
    **{f"R{i}":   "C25744"    for i in range(1, 5)},    # 10k 0402, config pull-ups
    # ⚠ C207260 (Littelfuse) FELL FROM 17.2k TO 2 AT JLC by 2026-09-25 -- a 5-piece
    # shortfall on Carl's order screen.  Same MPN, same SOD-123FL package, same
    # 6 V / 10.3 V / 200 W unidirectional spec from Shandong Jingdao: LCSC
    # 194,840 in stock, $0.024 vs $0.049.  IR at VRWM 450 uA vs 400 -- at 5 V,
    # below VRWM, far lower in both.  Backup: MDD C123790 (121k).
    "D1":  "C178260",    # SMF6.0A Shandong Jingdao
    "D2":  "C8598",      # B5819W, 543k
    "D3":  "C8598",
    "U1":  "C2678152",   # ICE40UP5K-SG48I, 494  <- the scarce one, and GBP 7.02
    "U2":  "C15298",     # SN74CB3T3245PWR, 764
    "U3":  "C15298",
    "U4":  "C2675530",   # SN74LVC541ADGVR, 244  <- thinnest line
    "U5":  "C2675530",
    "U6":  "C7833",      # SN74LVC1G125DCKR, 2.3k
    "U7":  "C7663",      # SN74LVC14APWR, 69.8k
    "U8":  "C2843335",   # W25Q16JVUXIQ, 1.87k
    "U9":  "C603505",    # NCP115ASN330T2G, 8.65k
    "U10": "C236672",    # ME6211C12M5G, 33.9k
    "U11": "C7833",
    # J1/J2 owner-fitted, J3 is bare pads, TP1 is a test pad -- no part to buy
}

FOOTPRINT = {r: fp for r, _, _, fp, _, _ in PARTS}
FOOTPRINT.update({r: fp for r, _, _, fp, _ in PASSIVES})
SYMBOL_OF = {r: sym for r, _, sym, _, _, _ in PARTS}
SYMBOL_OF.update({r: sym for r, _, sym, _, _ in PASSIVES})
VALUE = {r: (mpn or w) for r, mpn, _, _, w, _ in PARTS}
VALUE.update({r: v for r, v, _, _, _ in PASSIVES})

if __name__ == "__main__":
    print(f"{len(PARTS)} packages, {len(FPGA_PINS)} FPGA signals "
          f"(38 x 6510 + SPI_CS_N)")
    served = sorted(p for *_, ps in PARTS for p in ps)
    missing = sorted(set(range(1,41)) - set(served) - {6,21})   # 6=Vcc 21=Vss
    print(f"6510 pins served by a package: {len(served)}   unserved: {missing}")
    for r, m, sym, fp, w, ps in PARTS:
        print(f"  {r:<4} {str(m):<20} {fp.split(':')[-1][:34]:<36} {w}")
