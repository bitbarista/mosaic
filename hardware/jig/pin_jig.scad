// ---------------------------------------------------------------------------
// MOSaic Rev A -- soldering jig for the 40 plug pins (J1, J2)
//
// Holds all 40 turned pins upright and on-pitch so the board can be lowered
// onto them and soldered, instead of using the C64's own 6510 socket as the
// fixture. Ported from c64-ice40-ram hardware/jig/pin_jig_revc.scad -- same
// pin, same printer, same construction (ribs, feet, 4 mm guide depth); only
// the pin field and the hole size differ. Hole positions are taken from
// hardware/mosaic-reva.kicad_pcb and verified against it by gen/check_jig.py
// -- not from a redrawn dimension.
//
// Coordinates are the numbers KiCad shows for this board (page coordinates;
// the aux origin is unset). The model is re-centred below, so the absolute
// values never reach the print.
//
// The 40 pins are a DIP-40 field, two columns of 20 at 2.54 mm, 15.24 mm
// apart:
//     left  column  x = 102.38   J1 1-20, y 75.87 down to 124.13
//     right column  x = 117.62   J2 20-1, same rows
// Three cross ribs tie the columns together:
//     rib  y =  80.95   row 3
//     rib  y = 100.00   between rows 10 and 11 -- the middle of the field
//     rib  y = 119.05   row 18
//
// ⚠ WHY NOT RIBS ON ROWS 1 AND 20, as the DRAM jig puts its ribs on its end
// rows. Row 20 is y = 124.13, and J3 (the pogo pads, 124.30) and J4 (the
// owner-fitted enable link, 123.33 / 124.60) sit on that line between the
// columns. J3 is never fitted, but J4's header is, and a rib under it would
// hold the board off the jig if J4 went on first -- the DRAM jig's J12 rule.
// At row 18 the rib clears J4 pin 1 by 2.68 mm, so the assembly order no
// longer matters and gen/check_jig.py check 5 has nothing to report.
//
// ⚠ NO ORIENTATION TAB, ON PURPOSE. The ribs are symmetric about the middle
// of the field (rows 3 and 18 swap under a 180-degree turn, y = 100 maps to
// itself), and a 2 x 20 field is symmetric both ways, so the jig works in any
// of its four orientations. The DRAM jig needed a tab because its pin field
// was not symmetric; this one has nothing to get wrong.
//
// ⚠ MEASURE YOUR PINS before printing. hole_d must fit the END THAT GOES INTO
// THE JIG -- the body, not the 0.48 mm mating tip. See hole_gauge.scad in
// c64-ice40-ram for how 1.10 was arrived at on the DRAM board.
// ---------------------------------------------------------------------------

/* [Fit] */
// ⚠ 0.10 LARGER THAN THE DRAM JIG'S 1.10, on Carl's instruction (2026-10-02):
// "Jig pin holes need to be 0.1mm larger" -- the DRAM jig's 1.10 holes are too
// tight. 1.10 was the gauge's "best comfortable fit", measured 2026-08-23; its
// .scad was raised to 1.20 the same day to match this one. Still above the
// board's 0.90 drill, which gen/check_jig.py check 2 enforces.
hole_d      = 1.20;
bar_w       = 3.20;   // rib width; must exceed hole_d + 2*wall
thickness   = 4.00;   // guide depth: more = straighter pins, harder to print

/* [Feet] */
// Feet, not a thicker jig: see the DRAM jig's long note. `thickness` is the
// depth at which hole_d was measured; change one and you are back at the
// gauge. `foot_h` touches neither.
foot_h      = 2.00;   // lifts the jig so pin tips can protrude below. 0 = none
foot_d      = 4.00;
overhang    = 3.20;   // column stub past the end pins, carrying a corner foot

/* [Quality] */
$fn         = 48;

// --- pin coordinates, mm, exactly as fabricated (KiCad top view) -----------
// Grouped by reference so this list can be diffed against the board:
//     python3 gen/check_jig.py
X_L = 102.38;  X_R = 117.62;
Y_TOP = 75.87; PITCH = 2.54;
J1 = [for (i=[0:19]) [X_L, Y_TOP + i*PITCH]];          // pin 1 at the top
J2 = [for (i=[0:19]) [X_R, Y_TOP + (19-i)*PITCH]];     // pin 1 at the bottom
PINS = concat(J1, J2);
Y_BOT = Y_TOP + 19*PITCH;                              // 124.13
Y_MID = (Y_TOP + Y_BOT)/2;                             // 100.00
X_MID = (X_L + X_R)/2;                                 // 110.00

// --- ribs: [from, to] ------------------------------------------------------
// The columns run `overhang` past the end pins so a foot can sit at the true
// corner; a foot cannot go anywhere else on a column, because at 2.54 mm
// pitch there is no gap between holes wide enough for one.
RIB_Y = [Y_TOP + 2*PITCH, Y_MID, Y_BOT - 2*PITCH];     // 80.95, 100.00, 119.05
RIBS = concat(
    [[[X_L, Y_TOP - overhang], [X_L, Y_BOT + overhang]],   // left column
     [[X_R, Y_TOP - overhang], [X_R, Y_BOT + overhang]]],  // right column
    [for (y = RIB_Y) [[X_L, y], [X_R, y]]]);               // cross ribs

// --- feet ------------------------------------------------------------------
// One at each corner, on the overhang stubs, so the support polygon is the
// whole frame and no hole is outside it (the DRAM Rev A jig's tipping fault,
// gen/check_jig.py check 4). One more under the middle of each cross rib, in
// the clear 7.62 mm from either column.
FEET = concat(
    [[X_L, Y_TOP - overhang], [X_R, Y_TOP - overhang],     // top corners
     [X_L, Y_BOT + overhang], [X_R, Y_BOT + overhang]],    // bottom corners
    [for (y = RIB_Y) [X_MID, y]]);                         // rib mid-spans

// --- self-checks -----------------------------------------------------------
// These fail the render, not a report nobody reads.
function d2(a, b) = sqrt((a[0]-b[0])*(a[0]-b[0]) + (a[1]-b[1])*(a[1]-b[1]));

// distance from point p to segment [a,b]
function seg_d(p, a, b) =
    let (vx = b[0]-a[0], vy = b[1]-a[1],
         L2 = vx*vx + vy*vy,
         t  = L2 == 0 ? 0 : max(0, min(1, ((p[0]-a[0])*vx + (p[1]-a[1])*vy) / L2)))
    d2(p, [a[0] + t*vx, a[1] + t*vy]);

assert(len(PINS) == 40, "MOSaic has 40 plug pins; the list does not.");

// no two holes coincide
assert(len([for (i=[0:len(PINS)-1]) for (j=[0:len(PINS)-1])
            if (i < j && d2(PINS[i], PINS[j]) < 0.01) 1]) == 0,
       "duplicate pin coordinate");

// every hole must be inside a rib, or it is a hole in mid-air
assert(len([for (p = PINS)
            if (min([for (r = RIBS) seg_d(p, r[0], r[1])]) > bar_w/2 - hole_d/2) 1]) == 0,
       "a pin hole is not fully inside a rib");

// the wall either side of a hole along a column
assert(PITCH - hole_d >= 0.80, "less than 0.8 mm of wall between neighbouring holes");

// no foot may reach a hole
FOOT_MIN = foot_d/2 + hole_d/2 + 0.30;
assert(len([for (f = FEET) for (p = PINS) if (d2(f, p) < FOOT_MIN) 1]) == 0,
       "a foot overlaps a pin hole -- a pin tip would hit the bench through it");

// every foot must have frame above it
assert(len([for (f = FEET)
            if (min([for (r = RIBS) seg_d(f, r[0], r[1])]) > 0.01) 1]) == 0,
       "a foot is not under a rib");

// --- centre on the origin --------------------------------------------------
xs = [for (p=PINS) p[0]];   ys = [for (p=PINS) p[1]];
cx = (min(xs)+max(xs))/2;   cy = (min(ys)+max(ys))/2;
// KiCad Y runs downward; negate it so the model is a true top view.
function T(p) = [p[0]-cx, -(p[1]-cy)];

module rib(a, b) {
    hull() {
        translate(T(a)) cylinder(d=bar_w, h=thickness);
        translate(T(b)) cylinder(d=bar_w, h=thickness);
    }
}

module frame() {
    for (r = RIBS) rib(r[0], r[1]);
}

module feet() {
    if (foot_h > 0)
        for (c = FEET)
            translate(concat(T(c), [-foot_h]))
                cylinder(d=foot_d, h=foot_h + 0.01);
}

module holes() {
    for (p = PINS)
        translate(concat(T(p), [-(foot_h + 1)]))
            cylinder(d=hole_d, h=thickness + foot_h + 2);
}

difference() {
    union() { frame(); feet(); }
    holes();
}

echo(str("pins: ", len(PINS), "  feet: ", len(FEET), "  hole_d: ", hole_d));
echo(str("pin field: ", max(xs)-min(xs), " x ", max(ys)-min(ys), " mm"));
echo(str("part: ", max(xs)-min(xs) + bar_w, " x ",
                   max(ys)-min(ys) + 2*overhang + bar_w, " mm"));
