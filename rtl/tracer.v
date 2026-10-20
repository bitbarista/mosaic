// ---------------------------------------------------------------------------
// Bus tracer -- a bring-up instrument (2026-10-02).
//
// Rev A failed every serial-bus load in a real C64 while every register,
// timing and simulation check passed, and there was no scope to look at the
// wires.  This records what the CPU itself sees.
//
// Storage is two of the UP5K's four SPRAMs, otherwise unused: 16K entries x
// 32 bits (word 0 in SPRAM 0, word 1 in SPRAM 1).  Two modes:
//
//   CIA  (arm)      one entry per bus cycle on $DC00-$DDFF:
//                   word 0 = bus-cycle stamp, word 1 = {data, rw, A8, 00, A3..A0}.
//                   Linear: stops when full, so the START is kept.
//   ALL  (arm_all)  one entry per bus cycle, every cycle, the CPU's or not:
//                   word 0 = address, word 1 = {data, rw, sync, rdy, aec, 0000}.
//                   A ring: on `trig` it records POST more entries and stops,
//                   keeping what led up to the trigger.
//
// Driven by cpu6510.v's key on $0000 (see there):  arm, arm_all, arm_menu, stop, dump.
//   MENU (arm_menu) ALL's ring, frozen when the CPU JAMS (holding the 16K
//                   cycles that led there) or, failing that, when the bus is
//                   taken for 128 cycles (the Ultimate's menu) -- for hangs.
//   PAGE (arm_page) MENU, and also frozen POST_PAGE (8192, half the ring)
//                   entries after the first CPU write into a chosen page
//                   (cpu6510 $8F + the page byte).
// Dump presents, on $0001 reads: mode (0 CIA, 1 ALL), count lo, count hi, then
// each entry oldest first as word0 lo, word0 hi, word1 lo, word1 hi.
// Recording also stops whenever the C64 holds /RESET, so a hung run can be
// reset from the Ultimate's menu and read afterwards.  Nothing here is reset
// by /RES; the contents survive until the FPGA is reconfigured.
// ---------------------------------------------------------------------------
`default_nettype none

module tracer (
    input  wire        clk,
    input  wire        freeze,         // the C64 is holding /RESET
    input  wire        ev_valid,       // CIA mode: a CIA cycle completed
    input  wire [31:0] ev,
    input  wire        step,           // ALL mode: any bus cycle completed
    input  wire [31:0] all_ev,
    input  wire        trig,           // ALL mode: freeze the ring after POST more
    input  wire        res_rise,       // the core came out of reset
    input  wire        boot_trig,      // BOOT mode's freeze condition
    input  wire        dma_long,       // the bus taken for 128 cycles: stop at once
    input  wire        jam,            // the CPU jammed: MENU stops at once
    input  wire        arm,
    input  wire        arm_all,
    input  wire        arm_menu,       // ALL ring, frozen only by dma_long (cpu6510 $4F)
    input  wire        arm_page,       // the same, also frozen POST after pagew (cpu6510 $8F + page)
    input  wire        pc_short,       // cpu6510 $CF: keep POST_PC after the trigger, not POST_PAGE
    input  wire        arm_resume,     // RESUME ring (cpu6510 $0F): freeze POST_RES after a long hold ENDS
    input  wire        pagew,          // a CPU write into the chosen page
    input  wire        stop,
    input  wire        dump,
    input  wire        rd_next,
    output reg  [7:0]  byte_o = 8'h00
);
    localparam integer DEPTH = 16384;
    localparam integer POST  = 512;
    // PAGE keeps HALF the ring after its trigger: a decruncher writing a whole
    // page (~5K cycles with its loader calls) fits, with 8K cycles of before.
    localparam integer POST_PAGE = 8192;
    // $CF (stage 2 = an opcode fetch): what matters is how the CPU GOT there,
    // so keep almost the whole ring before it
    localparam integer POST_PC = 512;
    // RESUME ($0F, 2026-10-07): The Hat crashes the INSTANT the Ultimate's menu
    // releases the bus after a disk swap.  The ring runs through the hold
    // (dma_long does NOT freeze it), and freezes POST_RES cycles after the bus
    // has been free (AEC and RDY high) for 8 cycles in a row -- so it holds the
    // end of the hold and the first ~15,000 cycles after it.
    localparam integer POST_RES = 15000;

    reg        armed = 1'b0;
    reg        mode  = 1'b0;           // 0 CIA, 1 ALL
    // ⚠ BOOT: armed from configuration.  On every reset release, until it has
    // caught something, the ring re-arms in ALL mode and freezes POST entries
    // after a BRK fetch or a fetch of $FE66 (a crashed boot's warm start), or
    // stops at once if the bus is taken for 128 cycles (the Ultimate's menu).
    // Any software arm cancels it.  Contents survive later resets as before.
    reg        boot_pend = 1'b1;
    reg        bootmode  = 1'b0;
    reg        menumode  = 1'b0;
    reg        pagemode  = 1'b0;
    reg        resumemode = 1'b0, held = 1'b0;
    reg [3:0]  freecnt = 4'd0;
    reg [14:0] count = 15'd0;          // CIA: entries; ALL: saturates at DEPTH
    reg [13:0] wptr  = 14'd0;          // next write
    reg        trigd = 1'b0;
    reg [13:0] post  = 14'd0;
    reg        we = 1'b0;
    reg [13:0] waddr = 14'd0;
    reg [31:0] wdata = 32'h0;

    reg [15:0] ridx = 16'h0;           // byte index into the dump stream
    reg        ld1 = 1'b0, ld2 = 1'b0;

    wire [15:0] ev_idx  = ridx - 16'd3;
    wire [13:0] oldest  = (count == DEPTH[14:0]) ? wptr : 14'd0;
    wire [13:0] raddr   = oldest + ev_idx[15:2];
    wire [1:0]  rbyte   = ev_idx[1:0];

    wire [15:0] dout0, dout1;
    wire [13:0] addr = we ? waddr : raddr;

    wire take = armed && !freeze &&
                (mode ? step : (ev_valid && count != DEPTH[14:0]));

    always @(posedge clk) begin
        we <= 1'b0;
        if (take) begin
            we    <= 1'b1;
            waddr <= wptr;
            wdata <= mode ? all_ev : ev;
            wptr  <= wptr + 14'd1;
            if (count != DEPTH[14:0]) count <= count + 15'd1;
            if (mode && trigd) begin
                if (post == (resumemode ? POST_RES[13:0] : pagemode ? (pc_short ? POST_PC[13:0] : POST_PAGE[13:0]) : POST[13:0]) - 14'd1) armed <= 1'b0;
                post <= post + 14'd1;
            end
        end
        if (mode && armed && !bootmode && !menumode && !resumemode && trig) trigd <= 1'b1;
        if (resumemode && armed && !trigd) begin
            if (dma_long) held <= 1'b1;
            if (held && step) begin
                if (all_ev[4] && all_ev[5]) freecnt <= freecnt + 4'd1; else freecnt <= 4'd0;
                if (freecnt == 4'd7) trigd <= 1'b1;
            end
        end
        if (menumode && armed && (dma_long || jam)) armed <= 1'b0;
        if (pagemode && armed && pagew && !trigd) trigd <= 1'b1;
        if (bootmode && armed && boot_trig && !trigd) begin trigd <= 1'b1; boot_pend <= 1'b0; end
        if (bootmode && armed && dma_long && !trigd) armed <= 1'b0;
        if (arm || arm_all || arm_menu || arm_page || arm_resume) begin
            armed <= 1'b1; mode <= arm_all | arm_menu | arm_page | arm_resume; count <= 15'd0; wptr <= 14'd0;
            resumemode <= arm_resume; held <= 1'b0; freecnt <= 4'd0;
            trigd <= 1'b0; post <= 14'd0; bootmode <= 1'b0; boot_pend <= 1'b0;
            menumode <= arm_menu | arm_page; pagemode <= arm_page;
        end else if (res_rise && boot_pend && !freeze) begin
            armed <= 1'b1; mode <= 1'b1; count <= 15'd0; wptr <= 14'd0;
            trigd <= 1'b0; post <= 14'd0; bootmode <= 1'b1; menumode <= 1'b0; pagemode <= 1'b0; resumemode <= 1'b0;
        end
        if (stop || freeze)   armed <= 1'b0;
        if (dump)             begin armed <= 1'b0; ridx <= 16'h0; ld1 <= 1'b1; end
        else if (rd_next)     begin ridx <= ridx + 16'd1; ld1 <= 1'b1; end
        else                  ld1 <= 1'b0;
        ld2 <= ld1;
        if (ld2)
            case (ridx)
                16'd0:   byte_o <= {3'b0, resumemode, pagemode, menumode, bootmode, mode};   // 0 CIA, 1 ALL, 3 BOOT, 5 MENU, 13 PAGE, 17 RESUME
                16'd1:   byte_o <= count[7:0];
                16'd2:   byte_o <= {1'b0, count[14:8]};
                default: case (rbyte)
                    2'd0: byte_o <= dout0[7:0];
                    2'd1: byte_o <= dout0[15:8];
                    2'd2: byte_o <= dout1[7:0];
                    2'd3: byte_o <= dout1[15:8];
                endcase
            endcase
    end

    SB_SPRAM256KA ram0 (
        .ADDRESS(addr), .DATAIN(wdata[31:16]), .MASKWREN(4'b1111), .WREN(we),
        .CHIPSELECT(1'b1), .CLOCK(clk), .STANDBY(1'b0), .SLEEP(1'b0),
        .POWEROFF(1'b1), .DATAOUT(dout0));
    SB_SPRAM256KA ram1 (
        .ADDRESS(addr), .DATAIN(wdata[15:0]), .MASKWREN(4'b1111), .WREN(we),
        .CHIPSELECT(1'b1), .CLOCK(clk), .STANDBY(1'b0), .SLEEP(1'b0),
        .POWEROFF(1'b1), .DATAOUT(dout1));
endmodule

`default_nettype wire
