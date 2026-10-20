// ---------------------------------------------------------------------------
// MOS 6510 wrapper around T65 -- the I/O port, the bus interface and PHI2.
//
// WRITTEN FRESH FROM THE DATASHEET.  C64_MiSTer's rtl/cpu_6510.vhd does this
// job and CANNOT BE USED: it is Peter Wendrich's FPGA-64, whose terms are
// "strictly for personal educational purposes... not allowed to copy, upload or
// redistribute this work in any way".  T65 itself is BSD-3-Clause (Daniel
// Wallner, Mike Johnson, Wolfgang Scherr, Morten Leikvoll) and is used under
// that licence -- see rtl/t65/.  The behaviour below is the 6510's documented
// specification, not anyone's implementation of it:
//   datasheets/audit/MOS_6510.txt, "6510 MICROPROCESSOR WITH I/O"
//     "An 8-bit Bi-Directional I/O Port is located on-chip with the Output
//      Register at Address 0001 and the Data-Direction Register at Address
//      0000. The I/O Port is bit-by-bit programmable."
//     "The Address Bus, R/W, and Data Bus are valid only when the Address
//      Enable Control line is high. When low, the Address Bus, R/W and Data
//      Bus are in a high-impedance state."
// ---------------------------------------------------------------------------
`default_nettype none

module cpu6510 #(
    // ⚠ PHI0 -> PHI2 DELAY, IN FABRIC-CLOCK CYCLES.  A real 6510 delays PHI2
    // from PHI0 by 30-40 ns, temperature dependent (Bauer, "The MOS 6567/6569
    // video controller", and reference/vic-article.txt in the DRAM project).
    // At a 48 MHz HFOSC one cycle is 20.8 ns, so 2 cycles = 41.7 ns is the
    // closest available approximation and the default.
    //
    // ⚠ THIS COSTS JITTER, AND THE TRADE IS REAL.  PHI0 is asynchronous to the
    // fabric clock, so a counted delay varies by +/-1 clock: 41.7 ns becomes
    // 21-62 ns cycle to cycle.  Setting PHI2_DELAY = 0 gives a clean edge with
    // no delay at all.  Neither is a 6510.  The value must be MEASURED on a
    // real one (plan P1) and this parameter set from the measurement; it is a
    // parameter precisely so that the measurement can change it without
    // touching the logic.
    parameter integer PHI2_DELAY = 2,

    // Cycles for an unused port bit's charge to decay 1 -> 0.  See the port
    // section below for where this number comes from.
    parameter integer PORT_FALLOFF = 350000,
    // ⚠ ERRATA E-47.  1: read data, the port pins, /IRQ and /NMI come in
    // ALREADY CAPTURED (cap_*), taken by rtl/top.v at the edge where this
    // board's PHI2 falls -- where a 6510 latches them.  0 (the default, for the
    // cycle-level harnesses sim/vice, sim/lorenz, sim/iec): captured here on
    // PHI0's own falling edge, as before.
    parameter integer EXT_CAP = 0,
    // the build's identity, read back by software through the unlocked flash
    // port (FL_ADDR, FL_ADDR+1): syn/synth.sh sets it from a hash of the RTL
    parameter [15:0] BUILD_ID = 16'h0000
) (
    input  wire        clk,        // free-running fabric clock (SB_HFOSC)
    input  wire        phi0,       // 6510 pin 1, from the VIC
    input  wire        res_n,      // pin 40
    input  wire        rdy,        // pin 2   (the C64 drives this from BA)
    input  wire        irq_n,      // pin 3
    input  wire        nmi_n,      // pin 4
    input  wire        aec,        // pin 5

    output wire [15:0] a,          // pins 7-20, 22, 23
    output wire        rw,         // pin 38   HIGH = read
    output wire        phi2,       // pin 39
    input  wire [7:0]  d_in,       // pins 30-37, as seen at the FPGA
    output wire [7:0]  d_out,
    output wire        d_drive,    // 1 = this chip owns the data bus

    input  wire [5:0]  p_in,       // pins 24-29, as seen at the FPGA
    input  wire [7:0]  cap_d,      // EXT_CAP: D, as at this board's PHI2 falling
    input  wire [5:0]  cap_p,      // EXT_CAP: the port pins, the same instant
    input  wire        cap_irq_n,  // EXT_CAP: /IRQ, the same instant
    input  wire        cap_nmi_n,  // EXT_CAP: /NMI, the same instant
    input  wire        p3_live,    // 1 = something real drives P3 (the flash, D-7); read its pin
    output wire        spi_cs_n,   // the config flash's /CS (D-7 updater): high unless J4 + key
    output wire        wb_boot,    // to SB_WARMBOOT (top.v): J4 + key + $4x to FL_ADDR
    output wire [1:0]  wb_sel,     //   the warm-boot image
    output wire [5:0]  p_out,
    output wire [5:0]  p_drive,    // per-bit: the port is bit-by-bit programmable

    // ---- bus tracer tap (top.v's tracer; unconnected in the benches) -------
    output wire        trc_ev_valid,   // one bus cycle completed on a CIA
    output wire [31:0] trc_ev,         // {stamp[15:0], data, rw, A8, 00, A3..A0}
    output wire        trc_arm, trc_stop, trc_dump,
    output wire        trc_arm_all,    // record EVERY cycle, ring, stop on trc_trig
    output wire        trc_arm_menu,   // record EVERY cycle, ring, stop when the bus is taken
    output wire        trc_arm_resume, // record EVERY cycle, ring, stop 15000 after a long hold ends
    output wire        trc_arm_page,   // MENU ring that also freezes after a write into trc_page
    output wire        trc_pagew,      // a CPU write into page trc_page
    output wire        trc_pc_short,   // $CF mode: keep 512 cycles after the trigger, not 8192
    output wire [31:0] trc_all_ev,     // {A[15:0], data, rw, sync, rdy, aec, 0000}
    output wire        trc_trig,       // a CIA2 access other than $DD00
    output wire        trc_step,       // any bus cycle completed
    output wire        trc_res_rise,   // the core just came out of reset
    output wire        trc_boot_trig,  // BRK fetched, or the KERNAL's warm start ($FE66)
    output wire        trc_dma_long,   // the bus has been taken for 128 cycles
    output wire        trc_jam,        // the CPU has jammed (a JAM/KIL opcode)
    output wire        trc_rd_next,    // a $0001 read consumed a trace byte
    input  wire [7:0]  trc_byte        // the byte $0001 returns while dumping
);

    // ---- cycle enable -----------------------------------------------------
    // T65 advances one 6510 cycle per clk where Enable is high.  A 6510 cycle
    // is phi1 then phi2 and ENDS ON PHI0 FALLING: the address and R/W go out in
    // phi1 (tADS, max 300 ns after PHI0 falls), hold still through phi2 while
    // the machine does the access, and read data is latched as phi2 ends.  So
    // the cycle is anchored to PHI0's FALLING edge and Enable is a single
    // fabric-clock pulse there.
    //
    // ⚠ ERRATA E-33: THIS WAS THE RISING EDGE, AND REV A SHOWED A BLANK SCREEN.
    // Stepped on phi0_rise, the core changed A and R/W ~240 ns INTO phi2 -- in
    // the middle of the C64's own access -- and took read data at that moment
    // rather than at the end of phi2.  DRAMa, fitted alongside, flashed code 5
    // (bus contention): after a read, the core started driving a write while
    // the RAM was still driving the read.  Every bench ran PHI0 at a 24 ns
    // period against a 2 ns clock and a RAM that answered A instantly, where a
    // mid-phi2 address change is invisible.  sim/board/run_realtime.py runs the
    // board at the C64's real 985 kHz and 12 MHz and fails the old edge.
    //
    // ⚠ PHI0 IS ASYNCHRONOUS TO clk and must be synchronised before its edge
    // is detected, or a metastable sample becomes a whole missed or doubled
    // CPU cycle.  Two flops, then edge-detect on the synchronised copy.  At
    // 12 MHz that puts Enable 167-250 ns after PHI0 falls: inside tADS's 300.
    // ---- power-on reset, our own ---------------------------------------------
    // ⚠ ERRATA E-35.  A 6510 is reset by /RES and has no other way to start;
    // a 6510 is also powered by the same rail the reset circuit watches.
    // MOSaic is not: the FPGA must load its configuration first, and if that
    // finishes after the C64's reset pulse has ended, T65 never sees Res_n
    // low.  It then starts from the configuration's power-up state -- IR = $00,
    // a BRK -- takes the BRK through $FFFE with no stack, and the machine
    // never boots.  How long configuration takes depends on how fast +5V
    // rises (DEFERRED D-17), and an Ultimate II+ on the expansion port loads
    // that rail: Rev A "sometimes won't boot at all with Ultimate II+ plugged
    // in" (2026-10-02).  T65's reset is asynchronous, so a few clocks low is a
    // full reset; the core then fetches $FFFC like any 6510 coming out of
    // /RES.  8 clocks is far inside the shortest reset any bench applies, so
    // no verified trace moves.
    reg [3:0] por = 4'd0;
    always @(posedge clk) if (!por[3]) por <= por + 4'd1;
    wire core_res_n = res_n & por[3];

    reg [2:0] phi0_sync = 3'b000;
    always @(posedge clk) phi0_sync <= {phi0_sync[1:0], phi0};
    wire phi0_fall = (phi0_sync[2:1] == 2'b10);
    wire phi0_rise = (phi0_sync[2:1] == 2'b01);

    // ---- RDY: sampled MID-CYCLE, used at its end -----------------------------
    // ⚠ NOT AT THE STEP.  A 6510 judges RDY within the cycle it is finishing --
    // "a negative transition ... during or coincident with phase one (phi1)
    // will halt the microprocessor" on that cycle -- so the value that decides
    // whether cycle c completes is the one seen during c, not the one the VIC
    // sets as c ends.  Sampled at phi0_fall instead, the core took RDY going
    // high at the end of the LAST STOLEN cycle as permission to complete it,
    // and latched the floating bus of a cycle AEC had given to the VIC:
    // sim/board/run_dynamic.py's badline jumped to $E0zz (found 2026-10-02 while
    // fixing E-33).
    reg rdy_s = 1'b1, aec_s = 1'b0;
    always @(posedge clk) if (phi0_rise) begin
        rdy_s   <= rdy;
        aec_s   <= aec;             // the CPU owns this phi2 (for the tracer)
    end
    // ⚠ E-49: ON THE BOARD (EXT_CAP) THE CORE'S RDY IS top.v's VERDICT FOR THE
    // CYCLE THAT JUST ENDED (low at T+3 or at the end of phi2), set as PHI0
    // falls; the benches keep rdy_s.  EVERYTHING that asks "did this cycle
    // complete?" must use the same signal as the core -- the tracer's dump
    // counted bytes with rdy_s and slipped under badlines (2026-10-07).
    wire rdy_core = EXT_CAP ? rdy : rdy_s;

    // ⚠ /IRQ AND /NMI ARE TAKEN AT THE END OF PHI2, ON THE EDGE (ERRATA E-37).
    // A 6502's interrupt inputs feed a level detector (IRQ) and an edge
    // detector (NMI) that are open throughout phi2, so what counts is the
    // line as phi2 ENDS: a source that pulls /IRQ low late in phi2 of the
    // penultimate cycle still gets its interrupt after that instruction.
    // These were sampled at phi0_rise -- 170-250 ns INTO phi2 after the
    // synchroniser -- and so missed any fall in the last ~250 ns of phi2 by a
    // whole cycle, which near an instruction boundary is a whole instruction.
    // Found by sim/vice: MOSaic as VICE's CPU matched VICE's own 6510 for
    // 2,104,027 consecutive bus accesses of a cold boot and then took the
    // KERNAL's CIA1 timer IRQ one instruction late.  Every earlier bench
    // changed /IRQ on a cycle boundary, where the two sample points agree.
    // Captured by PHI0 itself, like d_cap, and consumed by the core at the
    // phi0_fall step 2-3 clocks later.
    reg irq_n_p = 1'b1, nmi_n_p = 1'b1;
    always @(negedge phi0) begin
        irq_n_p <= irq_n;
        nmi_n_p <= nmi_n;
    end
    wire irq_n_s = EXT_CAP ? cap_irq_n : irq_n_p;
    wire nmi_n_s = EXT_CAP ? cap_nmi_n : nmi_n_p;

    // ---- read data, captured ON the edge ------------------------------------
    // ⚠ NOT THROUGH THE SYNCHRONISER.  By the time phi0_fall fires, phi1 is
    // 170-250 ns old: the VIC owns the bus and the RAM released it 10 ns
    // (tHR) after PHI0 fell.  The byte has to be taken by PHI0 itself -- the
    // sibling's EDD 5.5.1 rule, "capture paths must be edge-triggered, not
    // clock-sampled".  PHI0 is on pin 44, a global input (syn/mosaic.pcf).
    // ⚠ CROSSING INTO clk IS SAFE BY CONSTRUCTION, not by luck: d_cap changes
    // only at PHI0's fall and is read only at phi0_fall, two to three clk
    // edges later, and then not again for a whole ~1 us bus cycle.
    reg [7:0] d_cap_p = 8'h00;
    always @(negedge phi0) d_cap_p <= d_in;
    wire [7:0] d_cap = EXT_CAP ? cap_d : d_cap_p;
    // ⚠ AND THE PORT PINS WITH IT.  ERRATA E-44: port_rd took p_in straight
    // into the core at the phi0_fall step, 170-250 ns after PHI0 fell, so a
    // read of $0001 needed the pins held that long into phi1 -- the 6510's
    // tPDH is 30 ns (sim/board/run_ac.py).  A data read was already taken on
    // the edge; the port now is too, the same edge, the same crossing argument.
    reg [5:0] p_cap_p = 6'h00;
    always @(negedge phi0) p_cap_p <= p_in;
    wire [5:0] p_cap = EXT_CAP ? cap_p : p_cap_p;

    // ---- PHI2 -------------------------------------------------------------
    // ⚠ COMBINATIONAL, NEVER REGISTERED.  Registering PHI0 onto the fabric
    // clock would put +/- one clock period of jitter on the MACHINE's clock.
    // This is c64-ice40-ram EDD 5.5.1's rule -- capture paths must be
    // edge-triggered, not clock-sampled -- pointed at an output.
    //
    // PHI2 reaches ONLY CIA1, CIA2, SID and the expansion port -- the PLA, VIC,
    // colour RAM and the LS257s are gated by /AEC instead -- and this board
    // supplies address, data and R/W to the first three itself.  So what the
    // delay actually sets is PHI2's relationship to PHI0 and AEC, which is what
    // a cartridge and the VIC's arbitration boundary see.
    generate
        if (PHI2_DELAY == 0) begin : g_phi2_direct
            assign phi2 = phi0;
        end else begin : g_phi2_delayed
            reg [PHI2_DELAY-1:0] phi2_sr = {PHI2_DELAY{1'b0}};
            always @(posedge clk) phi2_sr <= {phi2_sr[PHI2_DELAY-2:0], phi0};
            assign phi2 = phi2_sr[PHI2_DELAY-1];
        end
    endgenerate

    // ---- T65 --------------------------------------------------------------
    wire        t65_rw_n;
    wire        t65_sync;          // opcode fetch (for the bus tracer)
    wire [23:0] t65_a;
    wire [7:0]  t65_do;
    // ⚠ DECLARED HERE, ASSIGNED BELOW.  It is used by the T65 instantiation
    // that follows but computed from the port registers further down, and
    // declaration-after-use is not portable -- yosys accepted it, iverilog
    // refused to elaborate, which is what kept this module out of a testbench.
    wire [7:0]  d_to_core;

    T65 core (
        .Mode    (2'b00),          // 6502, with the undocumented opcodes
        .Res_n   (core_res_n),
        .Enable  (phi0_fall),
        .Clk     (clk),
        .Rdy     (rdy_core),
        .Abort_n (1'b1),
        .IRQ_n   (irq_n_s),
        .NMI_n   (nmi_n_s),
        .SO_n    (1'b1),
        .Sync    (t65_sync),
        .R_W_n   (t65_rw_n),
        .A       (t65_a),
        .DI      (d_to_core),
        .DO      (t65_do)
    );

    assign a  = t65_a[15:0];
    assign rw = t65_rw_n;

    // ---- the I/O port at $0000 / $0001 ------------------------------------
    // ⚠ THE REGISTER IS 8 BITS AND THE PACKAGE HAS 6 PINS.  The datasheet's
    // signal description says "I/O Port (P0-P7) -- Eight pins are used for the
    // peripheral port"; the 40-pin DIP bonds out only P0-P5.  Bits 6 and 7
    // therefore exist in the register with NO PIN, and that is the physical
    // origin of the behaviour below -- an internal node with capacitance and
    // nothing driving it.  An earlier version of this file had a 6-bit
    // register, which is not a 6510.
    //
    // ⚠ The port is INSIDE the CPU: accesses to $0000/$0001 never reach the
    // bus, and the core must be shown the port's value rather than the pins.
    reg [7:0] ddr = 8'h00;         // $0000. Reset: all INPUTS.
    reg [7:0] pr  = 8'h00;         // $0001, the output latch

    // The "capacitor" on bits 6 and 7, and its discharge timer.
    //
    // Behaviour and the 350,000-cycle figure are VICE's, which is the most
    // carefully tested model of this that exists (src/c64/c64mem.c,
    // C64_CPU6510_DATA_PORT_FALL_OFF_CYCLES = 350000 for a 6510; an 8500 is
    // 1500000).  VICE's own comment records why it matters: "cpuports.prg from
    // the lorenz testsuite will fail when the falloff takes less".
    //
    //   - writing $01 while the bit is an OUTPUT charges the capacitor and
    //     restarts the timer
    //   - writing $00 to turn an OUTPUT bit into an INPUT transfers the current
    //     data bit to the capacitor and starts the timer
    //   - on expiry the capacitor reads 0.  Decay is only 1 -> 0; a stored 0
    //     is already there.
    //
    // ⚠ VICE adds rand(0, FALLOFF/5) to model part-to-part spread.  A fixed
    // value is used here: one FPGA is one part, and a pseudo-random timer would
    // make the design unreproducible in simulation for no gain in fidelity.
    localparam integer FW = $clog2(PORT_FALLOFF + 1);
    reg [FW-1:0] cap_timer [7:6];
    reg [7:6]    cap;
    reg [7:6]    cap_armed;

    wire port_sel = (t65_a[15:1] == 15'd0);   // $0000 or $0001
    wire port_ddr = (t65_a[0] == 1'b0);
    wire writing  = (t65_rw_n == 1'b0);
    wire port_wr  = phi0_fall && port_sel && writing;

    integer b;
    always @(posedge clk) begin
        if (!core_res_n) begin
            ddr <= 8'h00;
            pr  <= 8'h00;
            cap <= 2'b00;
            cap_armed <= 2'b00;
        end else begin
            for (b = 6; b <= 7; b = b + 1) begin
                if (port_wr && !port_ddr && ddr[b]) begin
                    // written while an output: charge and restart
                    cap[b]       <= t65_do[b];
                    cap_timer[b] <= PORT_FALLOFF[FW-1:0];
                    cap_armed[b] <= 1'b1;
                end else if (port_wr && port_ddr && ddr[b] && !t65_do[b]) begin
                    // an output being turned into an input: the charge is left
                    // on the floating node
                    cap[b]       <= pr[b];
                    cap_timer[b] <= PORT_FALLOFF[FW-1:0];
                    cap_armed[b] <= 1'b1;
                end else if (cap_armed[b] && phi0_fall) begin
                    if (cap_timer[b] == 0) begin
                        cap[b]       <= 1'b0;
                        cap_armed[b] <= 1'b0;
                    end else begin
                        cap_timer[b] <= cap_timer[b] - 1'b1;
                    end
                end
            end
            if (port_wr) begin
                if (port_ddr) ddr <= t65_do;
                else          pr  <= t65_do;
            end
        end
    end

    // ⚠ P3 AND P5 ARE NOT READ FROM THEIR PINS AS INPUTS.  ERRATA E-32.
    // Nothing in a C64 drives either (c64-250407 netlist): P3 /CASS_WRT goes to
    // FB1 and the tape port only, P5 /CASS_MOTOR to R4 1K into Q2's base with
    // R3 10K to ground.  So on MOSaic, as inputs, P3 floats (the FPGA pin is
    // -pullup no) and P5 sits at ~0.9 V -- MOSaic's R4 10K pull-up into that
    // base -- between the iCE40's VIL 0.8 and VIH 2.0.  A real 6510 reads:
    //   P5: 0 -- the base resistors hold it low;
    //   P3: the LAST LEVEL DRIVEN onto it, the charge left on a net with
    //       nothing else on it (VICE models the same, and Lorenz cpuport
    //       checks both directions: $FF-then-input reads 1, $00-then-input 0).
    // So those two are supplied here, and the pins are never consulted.
    // EXCEPT P3 WHILE p3_live: DEFERRED D-7's updater selects the flash and
    // reads its DO on P3, which is then a driven pin and must be read as one.
    // p3_held is NOT cleared by /RES -- a floating net's charge does not reset.
    reg p3_held = 1'b0;
    always @(posedge clk)
        if (ddr[3]) p3_held <= pr[3];
    wire p3_in = p3_live ? p_cap[3] : p3_held;

    // Reading $0001: an OUTPUT bit reads back its latch, an INPUT bit reads the
    // pin -- and for bits 6 and 7 there is no pin, so an INPUT bit reads the
    // capacitor.  The output-bit case makes the datassette sense line work.
    wire [7:0] pin_or_cap = {cap[7], cap[6], 1'b0, p_cap[4], p3_in, p_cap[2:0]};
    wire [7:0] port_rd    = (ddr & pr) | (~ddr & pin_or_cap);

    // ⚠ THE WRITE LOOPBACK IS A REQUIREMENT OF T65, NOT A CONVENIENCE.
    // T65.vhd's header: "TAKE CARE you route the DO signal back to the DI
    // signal while R_W_n='0', otherwise some undocumented opcodes won't work
    // correctly."  It is load-bearing: on the write-back cycle of an RMW
    // illegal (SLO, RLA, SRE, RRA, DCP, ISC) the core takes the SECOND ALU
    // operand off DI, so without this the accumulator gets the operand as
    // READ instead of as SHIFTED -- memory still gets the right byte, so the
    // fault is invisible until something uses A.  SHA/SHX/SHY read DI+1 here
    // too.
    //
    // This used to fall out by accident: d_drive puts DO on the pins during a
    // write and d_in read it straight back through the bus switch.  That was
    // wrong for $0000/$0001, where d_drive is deliberately deasserted and
    // nothing drives the pins at all -- so "SLO $01" would have taken garbage
    // off a floating bus.  Do it in silicon here instead, where it does not
    // depend on AEC, on the level shifters, or on an input-buffer round trip.
    // ---- the flash port: DEFERRED D-7's C64-side updater ----------------------
    // Ported from c64-ice40-ram's rtl/spi_port.v (read it first).  On this board
    // the flash already sits on the processor port -- CLK = P5, DI = P2,
    // DO = P3 -- so the updater bit-bangs SCK and MOSI by writing $0001 and reads
    // MISO as port bit 3 (DDR bit 3 clear; p3_live reads the pin while /CS is
    // low).  The ONE thing the gateware adds is /CS, behind two gates:
    //
    //   1. J4 (PROG_EN, SETTLED S-19): P4 held LOW from OUTSIDE with DDR bit 4
    //      CLEAR -- a fitted link, which no program can fake (an output bit
    //      reads its latch; only an input bit with something pulling it low
    //      reads 0).  HELD, NOT SAMPLED: losing it at any instant locks the
    //      port and releases /CS.
    //   2. A KEY of sixteen LFSR bytes written CONSECUTIVELY to FL_ADDR, any
    //      other value restarting it -- the sibling's defence against accident.
    //      The key is public; J4 is the defence against malice.
    //
    // ⚠ FL_ADDR AND FL_SEED MUST DIFFER FROM DRAMa'S ($CF00, $A5).  These are
    // ordinary CPU writes and reach RAM, so a DRAMa in the same machine sees
    // them: with one address and one key, this updater would unlock DRAMa's
    // flash port too (and DRAMa's would unlock this one).
    //
    // Once unlocked, a write to FL_ADDR:
    //   $80-$FF   lock again
    //   $40-$7F   WARM BOOT into image bits 1:0 (SB_WARMBOOT, top.v): the
    //             development loop's way into the EXPERIMENTAL slot B, while the
    //             cold boot stays on the GOLDEN slot A -- so a power cycle always
    //             comes back to a working image (updater/README.md)
    //   $00-$3F   /CS from bit 2 (the sibling's bit, so the .asm files read alike)
    // and, while unlocked, READS of FL_ADDR / FL_ADDR+1 return BUILD_ID lo / hi
    // instead of RAM -- so a test can prove WHICH image it is running on before
    // it trusts a result.  Locked, those addresses are ordinary RAM.
    // Reset locks.  CPU accesses only: the Ultimate's DMA is not seen.
    localparam [15:0] FL_ADDR = 16'hCE00;
    localparam [7:0]  FL_SEED = 8'h3C;
    localparam integer FL_LEN = 16;
    function [7:0] fl_lfsr_next;            // x^8 + x^6 + x^5 + x^4 + 1, as spi_port.v
        input [7:0] v;
        fl_lfsr_next = {v[6:0], v[7] ^ v[5] ^ v[4] ^ v[3]};
    endfunction
    wire fl_j4 = !ddr[4] && !p_cap[4];      // the link: an input bit held low from outside
    wire fl_wr = phi0_fall && aec_s && writing && core_res_n && (t65_a[15:0] == FL_ADDR);
    reg  [7:0] fl_key = FL_SEED;
    reg  [4:0] fl_idx = 5'd0;
    reg        fl_unlocked = 1'b0;
    reg        fl_cs_n = 1'b1;
    reg        fl_wb = 1'b0;                // to SB_WARMBOOT's BOOT: held once set,
    reg  [1:0] fl_wb_sel = 2'b00;           // the reconfiguration ends it
    always @(posedge clk)
        if (!core_res_n || !fl_j4) begin
            fl_key <= FL_SEED; fl_idx <= 5'd0; fl_unlocked <= 1'b0; fl_cs_n <= 1'b1;
        end else if (fl_wr) begin
            if (!fl_unlocked) begin
                if (t65_do == fl_key) begin
                    fl_key <= fl_lfsr_next(fl_key);
                    fl_idx <= fl_idx + 5'd1;
                    if (fl_idx == FL_LEN[4:0] - 5'd1) fl_unlocked <= 1'b1;
                end else begin
                    fl_key <= FL_SEED; fl_idx <= 5'd0;   // any wrong byte restarts
                end
            end else if (t65_do[7]) begin
                fl_key <= FL_SEED; fl_idx <= 5'd0; fl_unlocked <= 1'b0; fl_cs_n <= 1'b1;
            end else if (t65_do[6]) begin
                fl_cs_n <= 1'b1; fl_wb_sel <= t65_do[1:0]; fl_wb <= 1'b1;
            end else
                fl_cs_n <= t65_do[2];
        end
    // ⚠ fl_wb IS NOT CLEARED BY RESET OR BY LOSING J4: once the command is
    // accepted the FPGA is about to reconfigure, and a BOOT that drops again
    // before it does would leave the half-started boot to chance.
    assign wb_boot = fl_wb;
    assign wb_sel  = fl_wb_sel;
    wire       fl_id_rd = fl_unlocked && fl_j4 && !writing && (t65_a[15:1] == FL_ADDR[15:1]);
    wire [7:0] fl_id    = t65_a[0] ? BUILD_ID[15:8] : BUILD_ID[7:0];
    // the link folded in once more at the output: /CS cannot be low without it
    assign spi_cs_n = fl_cs_n || !fl_unlocked || !fl_j4;


    reg trc_dumping = 1'b0;     // the bus tracer is reading out (end of file)
    assign d_to_core =
        writing   ? t65_do :
        fl_id_rd  ? fl_id :
        !port_sel ? d_cap :
        port_ddr  ? ddr :
        trc_dumping ? trc_byte : port_rd;

    assign p_out   = pr[5:0];
    assign p_drive = ddr[5:0];

    // ---- who owns the data bus -------------------------------------------
    // The board's '541s tri-state the ADDRESS and R/W from /AEC in hardware, so
    // those are driven continuously here.  D0-D7 pass through a bus SWITCH,
    // which has no direction control, so the FPGA's own tri-state is the only
    // thing that releases them.
    assign d_out   = t65_do;
    // ⚠ RELEASED ON PHI0 HERE; THE 6510's WRITE-DATA HOLD IS ADDED IN top.v,
    // against the delayed PHI2 it is measured from (ERRATA E-36).
    assign d_drive = aec & phi0 & writing & !port_sel;

    // ---- bus tracer: the tap and its command key ------------------------------
    // A bring-up instrument, added 2026-10-02 to see the serial bus from the
    // CPU's side on a real machine (every $DD00 read samples CLK/DATA IN, every
    // write drives ATN/CLK/DATA OUT).  It records, it never alters a cycle.
    //
    // COMMANDS are a key of four writes to $0000 -- $EF $6F $EF $6F -- and then
    // $AF (arm: clear and record), $2F (stop) or $EF (dump).  Every one of those
    // values is $2F in bits 0-5, the KERNAL's own DDR, so no port pin ever
    // changes direction; only bits 6/7, which have no pins, differ.  And $0000
    // never reaches the external bus, so nothing outside the CPU can see it.
    // While dumping, reads of $0001 return the trace instead of the port; the
    // next write to $0000 ends that.
    reg [31:0] trc_key = 32'h0;
    wire       trc_keyed = (trc_key == 32'hEF6FEF6F) && port_wr && port_ddr;
    always @(posedge clk)
        if (port_wr && port_ddr) begin
            trc_key     <= {trc_key[23:0], t65_do};
            trc_dumping <= trc_keyed && (t65_do == 8'hEF);
        end
    assign trc_arm  = trc_keyed && (t65_do == 8'hAF);
    assign trc_stop = trc_keyed && (t65_do == 8'h2F);
    assign trc_dump = trc_keyed && (t65_do == 8'hEF);
    assign trc_arm_all = trc_keyed && (t65_do == 8'h6F);
    // $4F: the ring of every cycle, frozen only by the bus being taken for 128
    // cycles -- opening the Ultimate's menu after a hang.  For hangs that never
    // fetch a BRK: arm, start the program from BASIC, open the menu when it
    // hangs, reset, run the dump.  A software arm, so resets do not re-arm.
    assign trc_arm_menu = trc_keyed && (t65_do == 8'h4F);
    // $0F: the RESUME ring (tracer.v) -- the Ultimate's menu, from the other side
    assign trc_arm_resume = trc_keyed && (t65_do == 8'h0F);
    // ⚠ $4F AND $8F BREAK THE RULE ABOVE: bits 0-5 are $0F, so for the few
    // cycles until the arm program writes $2F back, P5 (and for the page
    // byte below, P0-P2) is an input.  Only the diag arm programs send them,
    // with interrupts off, from RAM, before the program under test starts.
    // $8F, then more writes to $0000: the MENU ring, which also freezes 8192
    // cycles after a chosen CPU write -- a
    // loader's first byte into a block, with the 16K cycles before it (the
    // header that placed it) kept.
    // ... then THREE more writes: an address (high, low) and a value.
    // $CF (2026-10-06): the same, then TWO MORE -- an instruction address (high,
    // low).  Stage 2 is then the first OPCODE FETCH there after the arm, not
    // the next write, and the ring keeps only 512 cycles after it (tracer.v
    // pc_short), so ~15,900 cycles of history BEFORE the CPU reached it.  For
    // NLP's crash point 2: arm on the routine's $00 -> $DD02 (VICE 46,438,035),
    // trigger on reaching the loader's poll at $0223, which a 6510 does not do
    // there -- the ring then holds the divergence.
    reg [2:0] trc_pg_want = 3'd0;
    reg       trc_pcmode = 1'b0;
    reg [7:0] trc_page = 8'hFF, trc_lo = 8'hFF, trc_val = 8'hFF, trc_pcp = 8'hFF, trc_pcl = 8'hFF;
    reg [1:0] trc_pg_n = 2'd0;
    wire      trc_pg_last = (trc_pg_want == (trc_pcmode ? 3'd5 : 3'd3));
    always @(posedge clk)
        if (port_wr && port_ddr) begin
            if (trc_pg_want != 3'd0) begin
                case (trc_pg_want)
                    3'd1: trc_page <= t65_do;
                    3'd2: trc_lo   <= t65_do;
                    3'd3: trc_val  <= t65_do;
                    3'd4: trc_pcp  <= t65_do;
                    3'd5: trc_pcl  <= t65_do;
                    default: ;
                endcase
                trc_pg_want <= trc_pg_last ? 3'd0 : trc_pg_want + 3'd1;
            end else if (trc_keyed && (t65_do == 8'h8F || t65_do == 8'hCF)) begin
                trc_pg_want <= 3'd1;
                trc_pcmode  <= (t65_do == 8'hCF);
            end
        end
    assign trc_arm_page = port_wr && port_ddr && (trc_pg_want != 3'd0) && trc_pg_last;
    assign trc_pc_short = trc_pcmode;
    // TWO STAGES: the first write of VAL to the address only ARMS; the NEXT
    // write to that address, of any value, triggers.  A block written right
    // and later overwritten by a stray store is caught at the stray store.
    wire trc_hit  = phi0_fall && aec_s && writing && core_res_n && (t65_a[15:0] == {trc_page, trc_lo});
    // $CF's stage 2: an opcode fetch that COMPLETES (not one halted by RDY)
    wire trc_fetch = phi0_fall && aec_s && rdy_core && !writing && t65_sync && core_res_n &&
                     (t65_a[15:0] == {trc_pcp, trc_pcl});
    reg  trc_seen = 1'b0;
    always @(posedge clk)
        if (trc_arm_page) trc_seen <= 1'b0;
        else if (trc_hit && t65_do == trc_val) trc_seen <= 1'b1;
    assign trc_pagew = trc_seen && (trc_pcmode ? trc_fetch : trc_hit);
    // ⚠ ONLY A READ THAT COMPLETES consumes a byte.  A read halted by RDY (a
    // badline's 3 BA cycles, then 40 stolen) repeats every cycle, and counting
    // each repeat skipped bytes: Rev A's first two dumps slipped mid-file, and
    // the misaligned tail read like a crash after a badline (2026-10-02).
    assign trc_rd_next = phi0_fall && rdy_core && aec_s && port_sel && !port_ddr && !writing && trc_dumping;

    // One event per completed bus cycle on $DC00-$DDFF (CIA1/CIA2 and their
    // mirrors) while the CPU owned the bus.  The stamp counts bus cycles.
    reg [15:0] trc_stamp = 16'h0;
    always @(posedge clk) if (phi0_fall) trc_stamp <= trc_stamp + 16'd1;
    assign trc_ev_valid = phi0_fall && aec_s && core_res_n && (t65_a[15:9] == 7'b1101110);
    assign trc_ev = {trc_stamp, (writing ? t65_do : d_cap),
                     !writing, t65_a[8], 2'b00, t65_a[3:0]};
    // ALL-CYCLES mode: every completed bus cycle, whoever owned it, and the
    // trigger that freezes the ring -- a CIA2 access to anything but $DD00,
    // which the KERNAL's serial code never makes (Rev A's crash read $DD05).
    assign trc_all_ev = {t65_a[15:0], (writing ? t65_do : d_cap),
                         !writing, t65_sync, rdy_core, aec_s, 4'b0000};
    assign trc_step = phi0_fall && core_res_n;
    // The ring freezes on the first sign that execution has left the rails.
    // Rev A's first capture overran its crash: a stray CIA2 access alone did
    // not fire, and the ring recorded the Ultimate's menu instead.
    //   1. a CIA2 access other than $DD00 (the first crash read $DD05)
    //   2. an opcode fetched outside $0800-$0FFF (the trace PRG) and $E000+
    //      (the KERNAL) -- nothing else should run during the capture
    //   3. BRK fetched as an opcode
    //   4. the bus taken for 128 cycles in a row: no badline is that long, so
    //      it is a DMA (the Ultimate's menu) -- keep what came before it
    reg [7:0] trc_aec_lo = 8'h0;
    always @(posedge clk) if (phi0_fall)
        trc_aec_lo <= aec_s ? 8'h0 : (trc_aec_lo == 8'hFF ? 8'hFF : trc_aec_lo + 8'h1);
    wire trc_pc_odd = t65_sync && !(t65_a[15:12] == 4'h0 && t65_a[11]) && (t65_a[15:13] != 3'b111);
    assign trc_trig = phi0_fall && core_res_n && (
        (aec_s && (t65_a[15:8] == 8'hDD) && (t65_a[3:0] != 4'h0)) ||
        (aec_s && trc_pc_odd) ||
        (aec_s && t65_sync && d_cap == 8'h00) ||
        (trc_aec_lo == 8'd128));
    // BOOT mode (rtl/tracer.v arms itself on each reset release until it has
    // caught one): a crashing boot ends in BRK and the BRK/NMI warm start at
    // $FE66 -- the bare READY with no banner that Rev A showed when the
    // Ultimate supplied the stock KERNAL (2026-10-02).
    assign trc_boot_trig = phi0_fall && core_res_n && aec_s && t65_sync &&
                           (d_cap == 8'h00 || t65_a[15:0] == 16'hFE66);
    assign trc_dma_long  = phi0_fall && (trc_aec_lo == 8'd128);
    // A JAM: T65 then fetches "opcodes" at $FFFF every cycle (ERRATA E-11's
    // jammed bus).  No running program fetches four opcodes in a row at one
    // address with RDY high -- the PC moves -- so the fourth is the crash, and
    // the MENU ring freezes on it with the 16K cycles that led there.
    reg [2:0] trc_jam_n = 3'd0;
    always @(posedge clk) if (phi0_fall)
        trc_jam_n <= (aec_s && rdy_core && t65_sync && t65_a[15:0] == 16'hFFFF) ?
                     (trc_jam_n == 3'd7 ? 3'd7 : trc_jam_n + 3'd1) : 3'd0;
    assign trc_jam = phi0_fall && (trc_jam_n == 3'd3) && aec_s && rdy_core && t65_sync &&
                     t65_a[15:0] == 16'hFFFF;
    reg trc_res_q = 1'b0;
    always @(posedge clk) trc_res_q <= core_res_n;
    assign trc_res_rise = core_res_n && !trc_res_q;

endmodule

`default_nettype wire
