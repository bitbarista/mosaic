// Board-level top for MOSaic Rev A.  ERRATA E-20 / E-21.
//
// ⚠ UNTIL THIS FILE EXISTED THERE WAS NO DESIGN, ONLY A CORE.  cpu6510.v is
// the 6510 wrapper: it has split d_in/d_out/d_drive and p_in/p_out/p_drive, no
// clock source, and no SPI port.  Nothing tied it to the 39 pins the board was
// laid out for, nothing drove SPI_CS_N even though the board routes it to a
// dedicated FPGA pin, and check_phantom_primitives.py was right to report
// SB_HFOSC as "described in cpu6510.v, instantiated nowhere".
//
// ⚠ THE PORT NAMES HERE MUST MATCH design.FPGA_PINS EXACTLY, because
// syn/gen_pcf.py writes the constraints from that same table -- the board's
// pin assignment and this module's ports are then one fact, not two.  A name
// that does not match shows up as an unconstrained port, which nextpnr places
// wherever it likes and no one notices.  ERRATA E-16 is that shape of mistake.
`default_nettype none
`ifndef MOSAIC_BUILD_ID
`define MOSAIC_BUILD_ID 16'h0000   // syn/synth.sh defines it from a hash of the RTL
`endif

module top #(
    // ⚠ 48 MHz DOES NOT CLOSE, AND THAT WAS NEVER CHECKED UNTIL 2026-09-11.
    // synth.sh stopped at yosys, so the LUT count was known and the timing was
    // not.  nextpnr closes this design at ~22.9 MHz posedge-to-posedge, so the
    // "0b00" 48 MHz the wrapper's PHI2_DELAY comment assumes is unreachable.
    // ⚠ 24 MHz IS THE USEFUL RUNG BECAUSE OF PHI2_DELAY.  At 48 MHz one cycle
    // is 20.8 ns and the wrapper counts 2 for its 41.7 ns; at 24 MHz one cycle
    // IS 41.7 ns, so PHI2_DELAY = 1 preserves the same delay exactly.
    //   0b00 = 48 MHz   0b01 = 24 MHz   0b10 = 12 MHz   0b11 = 6 MHz
    parameter CLKHF_DIV = "0b10",
    // ⚠ DIAGNOSTIC ONLY (E-49), never in a shipped image: 1 = the tracer's
    // word 0 (normally the address) holds the RDY and AEC PINS sampled at
    // 8 points around each PHI0 rise, at 48 MHz -- an in-FPGA logic analyser
    // for the cycle where a read returned RAM instead of the CIA.
    parameter TRACE_PINS = 0
) (
    // ---- inputs from the machine
    input  wire        PHI0,
    input  wire        RDY,
    input  wire        IRQ_N,
    input  wire        NMI_N,
    input  wire        AEC,
    input  wire        RES_N,

    // ---- outputs to the machine
    output wire [15:0] A,
    output wire        RW,
    output wire        PHI2,

    // ---- the data bus and the processor port, both bidirectional
    inout  wire [7:0]  D,
    inout  wire [5:0]  P,

    // ---- configuration flash chip select, dedicated (SETTLED S-8)
    output wire        SPI_CS_N
);

    // ⚠ THE UP5K MAKES ITS OWN CLOCK AND THAT IS WHY IT WAS CHOSEN -- see
    // PRIOR-ART.md.  An iCE40HX4K has no oscillator and needs a crystal; this
    // is the same 48 MHz the wrapper's PHI2_DELAY is counted in.
    // ⚠ THE OSCILLATOR RUNS AT 48 MHz; THE CORE AT 48 / 4 = 12 MHz.  ERRATA E-36.
    // CLKHF_DIV above still names the CORE clock rung (synth.sh gates the core
    // on it); the 48 MHz exists for PHI2 and the write-data hold below, which
    // need finer steps than the core's 83 ns.  The divider feeds a global
    // buffer, so the core sees one clean 12 MHz clock exactly as before.
    wire hf48;
    SB_HFOSC #(.CLKHF_DIV("0b00")) osc (
        .CLKHFEN(1'b1), .CLKHFPU(1'b1), .CLKHF(hf48));
    reg [1:0] cdiv = 2'b00;
    always @(posedge hf48) cdiv <= cdiv + 2'b01;
    wire clk_raw = (CLKHF_DIV == "0b00") ? hf48 :
                   (CLKHF_DIV == "0b01") ? cdiv[0] : cdiv[1];
    wire clk;
    SB_GB core_gb (.USER_SIGNAL_TO_GLOBAL_BUFFER(clk_raw), .GLOBAL_BUFFER_OUTPUT(clk));

    wire [7:0] d_in, d_out;
    wire       d_drive;
    wire [5:0] p_in, p_out, p_drive;
    wire       spi_cs_n;                // the flash's /CS, from the core (D-7)
    wire       wb_boot;                 // warm boot (D-7's development loop)
    wire [1:0] wb_sel;

    // ⚠ PHI2_DELAY IS COUNTED IN FABRIC CYCLES, SO IT MUST FOLLOW THE CLOCK;
    // PORT_FALLOFF IS NOT (see below -- this comment once said "both", and that
    // is how the decay came to be 4x too short).  Leaving PHI2_DELAY at its
    // 48 MHz default after dropping to 12 MHz would make PHI2 four times too
    // late, silently.  ERRATA E-22.  Derived here from CLKHF_DIV so the two
    // cannot drift apart -- E-16 is what a duplicated constant costs.
    localparam integer CLK_HZ =
        (CLKHF_DIV == "0b00") ? 48_000_000 :
        (CLKHF_DIV == "0b01") ? 24_000_000 :
        (CLKHF_DIV == "0b10") ? 12_000_000 : 6_000_000;

    // ⚠ PHI2_DELAY = 0 IS FORCED AT 12 MHz, NOT CHOSEN.  One cycle is 83.3 ns
    // here, and a real 6510's whole phi0->phi2 delay is 30-40 ns -- so 1 is
    // already twice too long and there is nothing between 0 and 1.  At 24 MHz
    // one cycle IS 41.7 ns and the answer would have been 1, which is what made
    // 24 MHz worth chasing; it does not close (23.29 MHz best of 24 seeds).
    localparam integer PHI2_DELAY = (CLK_HZ >= 24_000_000) ? 1 : 0;

    // ⚠ PORT_FALLOFF IS COUNTED IN BUS CYCLES, SO IT DOES NOT FOLLOW THE CLOCK.
    // cpu6510.v decrements the timer on phi0_fall -- once per 6510 cycle -- which
    // is the unit VICE's C64_CPU6510_DATA_PORT_FALL_OFF_CYCLES = 350000 is in
    // (~355 ms at PAL).  ERRATA E-22 read it as FABRIC cycles and "held the time
    // constant" with (CLK_HZ/1000)*7 = 84000, which made the decay ~85 ms: 4x too
    // SHORT, the direction VICE warns breaks lorenz cpuports.prg.  Measured, not
    // argued: sim/mix/test_falloff_units.py shows the unit and reads this value
    // back from the elaborated design.  Only PHI2_DELAY follows the clock.
    localparam integer PORT_FALLOFF = 350000;

    // ⚠ EVERY INPUT ARRIVES INVERTED, AND UNTIL 2026-09-23 NOTHING UNDID IT.
    // All six machine inputs pass through U7, a 74LVC14A -- an INVERTING
    // Schmitt trigger (datasheets/audit/TI_SN74LVC14A.txt: "1A -> 1Y" of a
    // hex inverter).  gen/netlist.py knew: it puts PHI0_N, AEC_N and RDY_N on
    // the pins this module calls PHI0, AEC and RDY.  derivation/area_budget.py
    // recorded the plan -- "LVC14A, invert in RTL" -- and the RTL never did.
    // As built, the CPU ran while the machine held /RES low, halted whenever
    // RDY was HIGH, clocked on the wrong phi0 edge, and drove D0-D7 while the
    // VIC owned the bus.  No bench could see it: every one drove this module's
    // ports with the polarity it ASSUMED.  sim/board/run_dynamic.py, which
    // drives the COPPER from the socket through U7's datasheet model, did.
    //   pin name   carries (after U7)   the core wants
    //   PHI0       /phi0                phi0
    //   AEC        /AEC                 AEC
    //   RDY        /RDY                 RDY
    //   IRQ_N      IRQ  (active HIGH)   /IRQ   -- ⚠ the NET is named IRQ_N
    //   NMI_N      NMI  (active HIGH)   /NMI   -- ⚠ the NET is named NMI_N
    //   RES_N      RES  (active HIGH)   /RES   -- ⚠ the NET is named RES_N
    // The port names stay as design.FPGA_PINS has them (syn/gen_pcf.py writes
    // the constraints from that table); the inversion lives HERE, once.
    // ERRATA E-31.
    wire phi0_in  = ~PHI0;
    wire aec_in   = ~AEC;
    wire rdy_in   = ~RDY;
    wire irq_n_in = ~IRQ_N;
    wire nmi_n_in = ~NMI_N;
    wire res_n_in = ~RES_N;

    // ---- PHI2 and the write-data window, timed as a 6510 times them -------
    // Everything here hangs off ONE chain: PHI0 sampled by the 48 MHz
    // oscillator, p0s[k] = PHI0 as it was k+1 samples (20.8 ns each) ago.
    // nextpnr cannot place the UP5K's PLL with this board's pinout, so the
    // oscillator is the finest ruler there is.  Each edge below is +/-10 ns
    // of jitter around its mean, and the edges keep their ORDER exactly,
    // because they are taps of the same shift register.
    //
    // ⚠ ERRATA E-43 (was E-36's PHI2 = p0s[1]).  A 6510 outputs PHI2 30-40 ns
    // after PHI0; the CIAs, the SID and the expansion port run on it.  p0s[1]
    // was 20.8-41.7 ns IN THE RTL, but the pins add ~20 ns (U7, the pads, the
    // route, the buffer): sim/board/run_ac.py measured 41-61 ns typical at the
    // socket, and its 48 MHz quantum broke the 6510's PWphi2 (+13.4 vs +10).
    // Now PHI0 is sampled on BOTH oscillator edges and PHI2 leaves through the
    // pad's DDR register: each half of the output period carries the sample
    // taken half a period before it.  RTL lag 10.4-20.8 ns, quantum 10.4.
    //   rising half  (D_OUT_0, registered at posedge m): p2n, sampled at m-1/2
    //   falling half (D_OUT_1, registered at negedge m+1/2): p2p, sampled at m
    // Each sample has a half period to settle before the pad register takes it.
    //
    // ⚠ ERRATA E-38: WRITE DATA STARTS WHERE A 6510's DOES, NOT AT AEC.
    // A 6510 puts write data on the bus tMDS after PHI2 rises: 150 ns typical,
    // 200 max (datasheets/audit/MOS_6510.txt).  In a C64 that late start is
    // load-bearing, because phi1 belongs to the VIC and its devices are still
    // on D0-D7 when phi2 begins: the 6567's own AC table puts AEC 18-30 ns and
    // CAS 15-35 ns after the clock edge; behind the PLA and a 4164's tOFF
    // (30-40 ns) the RAM holds the VIC's byte until ~110 ns into phi2, and the
    // character ROM -- read in phi1 on every display-line cycle in text mode --
    // is deselected by the PLA only after AEC rises.  This drove D from
    // AEC & PHI0, ~30-40 ns into phi2: tens of ns of contention on EVERY CPU
    // write, against whichever of them had the bus.  DRAMa (the RAM board)
    // samples its own data pins just before CAS rises and flagged exactly
    // that: fault code 3+2, bus contention, seen intermittently on Rev A.
    //   start = p0s[6]: 125-146 ns after PHI0 rises -- a 6510's typical 150
    //           -- past the RAM's release (~110 worst case), and before the
    //           earliest CAS of a CPU write (RAS 155-190 + tRCD 25-65 = 180+,
    //           plus the PLA), which latches the byte (an early write, tDS = 0).
    //           ⚠ p0s[5] (104-125) was tried first and sim/board/run_realtime.py
    //           caught its fast corner inside the RAM's 110 ns tail.
    //   end   = p0s[3] falling: 62.5-83 ns after PHI0 falls -- the 6567's
    //           Tdh (data held 40 ns past the clock) and >= 20 ns past this
    //           board's own PHI2 falling edge, where the CIAs latch (tHW 10).
    // Which cycles: `wcyc`, taken once per phi2 at p0s[3] & !p0s[4] (62-83 ns
    // in, when AEC -- 18-30 ns behind PHI0 -- has long settled), from the
    // wrapper's d_drive (AEC, PHI0, a write, not $00/$01).  It holds through
    // phi1 for the end of the window.  A /DMA that takes AEC away mid-write
    // clears it after AEC has been low for 3 samples with PHI0 high (<= 63 ns,
    // inside a 6510's tDED of 130); at a normal cycle end PHI0 falls first
    // and AEC 18-30 ns later, so that test can never see three such samples.
    // d_out cannot move inside the window: the core steps 167-250 ns after
    // PHI0 falls, and the window has closed by 83 ns.
    reg [6:0] p0s = 7'b0000000;
    reg [2:0] aec_lo = 3'b000;
    reg       wcyc = 1'b0;
    always @(posedge hf48) begin
        p0s    <= {p0s[5:0], phi0_in};
        aec_lo <= {aec_lo[1:0], !aec_in};
        if (p0s[3] && !p0s[4])
            wcyc <= d_drive;
        else if (p0s[0] && p0s[1] && aec_lo == 3'b111)
            wcyc <= 1'b0;
    end
    // ⚠ PHI2 HAS ITS OWN TWO SAMPLERS, PLACED BESIDE ITS PAD.  Each feeds the
    // pad register half an oscillator period later -- 6.94 ns at 57.6 MHz and
    // 40 % duty (the industrial HFOSC's worst, U1_iCE40.txt Table 4.11).  Fed
    // from p0s[0] across the die the path was 7.14 ns (nextpnr, 5.5 of it
    // routing) and syn/synth.sh now gates it.  PHI0's route TO them is
    // asynchronous and costs nothing.  They must not be merged with
    // p0s[0], which samples the same pin on the same edge -- it did not; see below.
    // ⚠ As PRIMITIVES with a BEL: yosys drops a BEL attribute from an inferred
    // flop, and merged `(* keep *) reg` p2p straight back into p0s[0].  In two
    // TILES: an iCE40 logic tile has one clock polarity for all eight cells.
    wire p2p, p2n;                           // PHI0 at the rising / FALLING edge
`ifdef SYNTHESIS
    (* BEL = "X13/Y30/lc0" *) SB_DFF  p2p_ff (.C(hf48), .D(phi0_in), .Q(p2p));
    (* BEL = "X14/Y30/lc0" *) SB_DFFN p2n_ff (.C(hf48), .D(phi0_in), .Q(p2n));
    SB_IO #(.PIN_TYPE(6'b010001)) phi2_io (  // output DDR, input unused
        .PACKAGE_PIN(PHI2), .OUTPUT_CLK(hf48), .CLOCK_ENABLE(1'b1),
        .D_OUT_0(p2n), .D_OUT_1(p2p));
`else
    reg p2p_sim = 1'b0, p2n_sim = 1'b0;
    always @(posedge hf48) p2p_sim <= phi0_in;
    always @(negedge hf48) p2n_sim <= phi0_in;
    assign p2p = p2p_sim, p2n = p2n_sim;
    // SB_IO's DDR output (yosys ice40/cells_sim.v): D_OUT_0 registered on the
    // rising edge and driven while the clock is high, D_OUT_1 on the falling
    // edge and driven while it is low.  As ONE register written on both edges:
    // the same waveform, without the zero-time glitch a mux of the two shows
    // in simulation at every edge (the benches would count it as a PHI2 edge).
    /* verilator lint_off MULTIDRIVEN */
    reg phi2_q = 1'b0;
    always @(posedge hf48) phi2_q <= p2n;
    always @(negedge hf48) phi2_q <= p2p;
    /* verilator lint_on MULTIDRIVEN */
    assign PHI2 = phi2_q;
`endif

    // ⚠ ERRATA E-46: RDY IS JUDGED IN THE FIRST ~100 ns OF PHI2, NOT MID-CYCLE.
    // MCS6500 signal description: "A negative transition to the low state
    // during, or coincident with, phase one and up to 100 ns after phase two
    // will halt the microprocessor."  A later dip, gone before phi1, does not.
    // cpu6510.v took RDY at its phi0_rise step, 167-250 ns into phi2 -- and the
    // Ultimate II+ pulls /DMA (ANDed into the C64's RDY and AEC) low for 96 ns
    // ~160-180 ns into phi2 on EVERY KERNAL fetch it serves (its KERNAL probe,
    // slot_server_v4.vhd; firmware default "CPU Addr valid after PHI2" 112 ns).
    // MOSaic stalled on those fetches where a 6510 does not (sim/board/tb_ac.v
    // MODE 2).  Now RDY is taken once per cycle at the p0s[3] strobe -- 62-83 ns
    // after PHI0 rises in the RTL (78-104 at the HFOSC's -20 %), i.e. 35-95 ns
    // after this board's PHI2 rises -- and held for the core's step.
    // ⚠ ERRATA E-47: READ DATA, THE PORT, /IRQ AND /NMI ARE TAKEN WHERE A 6510
    // TAKES THEM -- AT ITS OWN PHI2 FALLING -- not on PHI0's.  A 6510 latches
    // the bus at the end of its phi2, ~30-40 ns after PHI0 falls; MOSaic took
    // it on PHI0's edge, ~34 ns earlier, which cuts into a slow device's
    // access time: the 6526 allows up to 550 ns from its register select
    // (Tacc), i.e. data valid as late as ~590 ns into a C64 cycle, after PHI0
    // falls (507) and before a 6510's phi2 does.  A real C64's memory holds
    // its data past a 6510's phi2 (tHR 10 ns), so taking it there is as safe
    // for DRAM -- stock or DRAMa -- as a 6510 is.
    // The instant: the pad register's edge that turns PHI2 low, or the rising
    // oscillator edge half a period before it -- never after it, as a 6510's
    // latch closes on its internal phi2, a little ahead of its PHI2 pin.
    //   PHI2 falls at posedge m   when p2p (sampled at m-1) = 1, p2n (m-1/2) = 0
    //   PHI2 falls at negedge m+1/2 when p2n (m-1/2) = 1, p2p (m) = 0
    // ⚠ RISING EDGES ONLY, AND p2n RE-TIMED FIRST.  Taken on the falling edge
    // and handed to a rising-edge register, the bus was a half-cycle path and
    // hf48 fell to 44 MHz; deciding straight from p2n across the die was one
    // too (47.7).  So p2n is re-timed by p2n_r, placed beside it, and the
    // decision is made one rising edge LATE, on cap_s, the bus as it was at
    // the previous rising edge m:
    //   PHI2 fell at posedge m:     p2p_d (sampled m-1) = 1, p2n_r (m-1/2) = 0
    //   PHI2 fell at negedge m+1/2: p2n_r (m-1/2) = 1, p2p (m) = 0
    // Either way cap_s holds the bus at m -- the fall edge itself, or half a
    // period before it.
    wire p2n_r;
`ifdef SYNTHESIS
    (* BEL = "X13/Y30/lc1" *) SB_DFF p2n_r_ff (.C(hf48), .D(p2n), .Q(p2n_r));
`else
    reg p2n_rr = 1'b0;
    always @(posedge hf48) p2n_rr <= p2n;
    assign p2n_r = p2n_rr;
`endif
    reg [15:0] cap_s = 16'hFFFF, cap_q = 16'hFFFF;    // {D, P, /IRQ, /NMI}
    reg        p2p_d = 1'b0;
    always @(posedge hf48) begin
        cap_s <= {D, P, irq_n_in, nmi_n_in};
        p2p_d <= p2p;
        if ((p2p_d && !p2n_r) || (p2n_r && !p2p)) cap_q <= cap_s;
    end

    // ⚠ ERRATA E-49: HALT IF RDY IS LOW AT T+3 *OR* AT THE END OF PHI2.
    // Measured on board #3 (TRACE_PINS): at some sprite-DMA starts the VIC
    // drops BA late in phi2 (between T+4 and past T+6 ticks), and a 6510 still
    // halts there -- MOSaic, judging only at T+3, completed the read and took
    // the RAM the PLA serves to a BA-low read (C64 PLA Dissected 2.4): CIA
    // reads wrong ~1e-4 at DMA starts (diag/ciasoak.asm: golden 9-103 per M,
    // real 6510 0), and irqdma one cycle off (record1: 7128 of 16384).  With
    // the end-of-phi2 term: ciasoak 0/0 twice and record1 0 of 16384 (build
    // $3B62).  The Ultimate's ~96 ns /DMA probe (E-46) is over before phi2
    // ends and is high at both points; in the last stolen cycle of a DMA RDY
    // is still low at T+3, so a cycle the VIC owns is never completed.
    // rdy_q is the verdict for the cycle that just ended, set as PHI0 falls;
    // the core uses it at its step (cpu6510.v, EXT_CAP).
    reg rdy_mid = 1'b1, rdy_q = 1'b1;
    reg [1:0] rdy_lag = 2'b11;
    always @(posedge hf48) begin
        rdy_lag <= {rdy_lag[0], rdy_in};
        if (p0s[3] && !p0s[4]) rdy_mid <= rdy_in;
        if (!p0s[0] && p0s[1]) rdy_q <= rdy_mid & rdy_lag[1];
    end

    // ---- TRACE_PINS: the RDY and AEC pins around each PHI0 rise (E-49) -------
    // T = the hf48 tick that first sees PHI0 high (p0s[0] && !p0s[1]); the
    // pins are kept 16 ticks deep and snapshotted at T+11, so each bit is the
    // pin at a fixed tick from T (20.8 ns a tick; PHI0 rose 1-2 ticks before T).
    //   RDY: T-4, T-2, T, T+1, T+2, T+3, T+4, T+6   (rdy_q is taken at T+3)
    //   AEC: T-4, T-2, T, T+2, T+4, T+6, T+8, T+10
    // MSB first = earliest.  The tracer stores them in word 0, in place of
    // the address, for the bus cycle that ends at the next PHI0 fall.
    reg [15:0] rdy_h = 16'hFFFF, aec_h = 16'hFFFF;
    reg [3:0]  tk = 4'd15;
    reg [7:0]  pin_rdy = 8'hFF, pin_aec = 8'hFF;
    always @(posedge hf48) begin
        rdy_h <= {rdy_h[14:0], rdy_in};
        aec_h <= {aec_h[14:0], aec_in};
        if (p0s[0] && !p0s[1]) tk <= 4'd0;
        else if (tk != 4'd15) tk <= tk + 4'd1;
        if (tk == 4'd11) begin      // rdy_h[j] here = the pin at T+10-j
            pin_rdy <= {rdy_h[14], rdy_h[12], rdy_h[10], rdy_h[9], rdy_h[8], rdy_h[7], rdy_h[6], rdy_h[4]};
            pin_aec <= {aec_h[14], aec_h[12], aec_h[10], aec_h[8], aec_h[6], aec_h[4], aec_h[2], aec_h[0]};
        end
    end
    wire   d_en = wcyc & p0s[6] & p0s[3];
    wire   phi2_core;          // the wrapper's undelayed PHI2: unused on the board
    wire        trc_ev_valid, trc_arm, trc_stop, trc_dump, trc_rd_next;
    wire        trc_arm_all, trc_arm_menu, trc_arm_resume, trc_arm_page, trc_pagew, trc_pc_short, trc_trig, trc_step, trc_res_rise, trc_boot_trig, trc_dma_long, trc_jam;
    wire [31:0] trc_ev, trc_all_ev;
    wire [31:0] trc_ev_pins = TRACE_PINS ? {pin_rdy, pin_aec, trc_all_ev[15:0]} : trc_all_ev;
    wire [7:0]  trc_byte;

    cpu6510 #(.PHI2_DELAY(PHI2_DELAY), .PORT_FALLOFF(PORT_FALLOFF), .EXT_CAP(1),
              .BUILD_ID(`MOSAIC_BUILD_ID)) cpu (
        .clk(clk), .phi0(phi0_in), .res_n(res_n_in), .rdy(rdy_q),
        .irq_n(irq_n_in), .nmi_n(nmi_n_in), .aec(aec_in),
        .a(A), .rw(RW), .phi2(phi2_core),
        .d_in(d_in), .d_out(d_out), .d_drive(d_drive),
        .p_in(p_in), .p_out(p_out), .p_drive(p_drive),
        .cap_d(cap_q[15:8]), .cap_p(cap_q[7:2]), .cap_irq_n(cap_q[1]), .cap_nmi_n(cap_q[0]),
        // P3 is a driven pin only while the flash is selected and its DO is on
        // it: the D-7 updater, with J4 fitted and the key written (E-32, D-7)
        .p3_live(!SPI_CS_N),
        .spi_cs_n(spi_cs_n),
        .wb_boot(wb_boot), .wb_sel(wb_sel),
        .trc_ev_valid(trc_ev_valid), .trc_ev(trc_ev),
        .trc_arm(trc_arm), .trc_stop(trc_stop), .trc_dump(trc_dump),
        .trc_arm_all(trc_arm_all), .trc_arm_menu(trc_arm_menu), .trc_arm_resume(trc_arm_resume), .trc_arm_page(trc_arm_page), .trc_pagew(trc_pagew), .trc_pc_short(trc_pc_short), .trc_all_ev(trc_all_ev), .trc_trig(trc_trig),
        .trc_step(trc_step), .trc_res_rise(trc_res_rise),
        .trc_boot_trig(trc_boot_trig), .trc_dma_long(trc_dma_long), .trc_jam(trc_jam),
        .trc_rd_next(trc_rd_next), .trc_byte(trc_byte));

    // The bus tracer: a bring-up instrument, see rtl/tracer.v.  It only records
    // what the core already does; /RES held by the C64 freezes it.
    tracer trace (
        .clk(clk), .freeze(!res_n_in),
        .ev_valid(trc_ev_valid), .ev(trc_ev),
        .step(trc_step), .all_ev(trc_ev_pins), .trig(trc_trig),
        .res_rise(trc_res_rise), .boot_trig(trc_boot_trig), .dma_long(trc_dma_long), .jam(trc_jam),
        .arm(trc_arm), .arm_all(trc_arm_all), .arm_menu(trc_arm_menu), .arm_resume(trc_arm_resume), .arm_page(trc_arm_page), .pagew(trc_pagew), .pc_short(trc_pc_short), .stop(trc_stop), .dump(trc_dump),
        .rd_next(trc_rd_next), .byte_o(trc_byte));

    // ⚠ THE DATA BUS IS ONE ENABLE; THE PORT IS SIX.  A 6510's DDR at $0000
    // gives every port bit its own direction, which is the whole reason the
    // board uses a passive bus switch for P0-P5 instead of a transceiver
    // (SETTLED: a '245 has one DIR pin and there are no spare FPGA pins for
    // six).  That per-bit direction has to appear here too.
    assign D = d_en ? d_out : 8'bz;
    assign d_in = D;

    genvar i;
    generate for (i = 0; i < 6; i = i + 1) begin : port
        assign P[i] = p_drive[i] ? p_out[i] : 1'bz;
    end endgenerate
    assign p_in = P;

    // ⚠ HIGH UNLESS THE D-7 UPDATER HAS J4 AND THE KEY (rtl/cpu6510.v, "the
    // flash port").  The FPGA loads its bitstream through this pin before the
    // design exists, and afterwards the flash must stay DESELECTED: R2's 10k
    // pull-up (ERRATA E-20) covers the window before this driver takes over, and
    // the core drives it high from then on -- until a program running on it
    // proves the J4 link is fitted and writes the sixteen-byte key.
    assign SPI_CS_N = spi_cs_n;

    // ⚠ WARM BOOT, FOR THE DEVELOPMENT LOOP ONLY (updater/README.md): the cold
    // boot (header record 0) is the GOLDEN slot A; an EXPERIMENTAL image in
    // slot B is entered through this, after J4 + the key, so a broken one is
    // undone by a power cycle.  S1:S0 pick header records 1-4 (images 0-3).
    SB_WARMBOOT warmboot (.BOOT(wb_boot), .S1(wb_sel[1]), .S0(wb_sel[0]));

endmodule

`default_nettype wire
