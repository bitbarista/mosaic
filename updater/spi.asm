; ---------------------------------------------------------------------------
; MOSaic -- the flash port, the SPI layer (DEFERRED D-7).  !source'd by
; flash.asm (the updater) and by sim/mix's test_spi.asm, so the routines the
; gate runs on the RTL are the routines that ship.
;
; Ported from c64-ice40-ram's updater/flash.asm, whose port is ONE address
; carrying SCK/MOSI/CS_N as bits.  Here the flash already sits on the 6510's
; own processor port, so:
;
;   flash CLK = P5  ($01 bit 5, /CASS_MOTOR)     output
;   flash DI  = P2  ($01 bit 2, CHAREN)          output
;   flash DO  = P3  ($01 bit 3, /CASS_WRT)       INPUT: read it at $01 bit 3
;   flash /CS = the gateware, through FLPORT, only with J4 fitted and the key
;
; ⚠ READBACK IS FREE HERE, unlike DRAMa: MISO is a port pin the CPU reads, so
; the busy flag is POLLED and a written slot is READ BACK and checksummed.
;
; ⚠ SPI MODE 3 -- THE CLOCK IDLES HIGH.  CLK is /CASS_MOTOR, and the KERNAL
; keeps it high (motor off).  Mode 0 would park it low and run a datasette's
; motor for the whole update.  The W25Q16JV takes mode 0 or 3: DI on the
; rising edge, DO changed on the falling edge, either way.
;
; ⚠ P2 IS CHAREN.  With HIRAM/LORAM set, CHAREN = 0 maps the CHARACTER ROM
; over $D000-$DFFF in place of the I/O chips -- so while a transaction runs,
; no I/O may be touched: interrupts are OFF from spi_select to spi_release (the
; KERNAL's IRQ handler reads CIA1), and nothing here calls the KERNAL.
; spi_release puts CHAREN back to 1.
; ---------------------------------------------------------------------------

; ⚠ NOT DRAMa's $CF00 / $A5.  These writes reach RAM, so a DRAMa in the same
; machine sees them; one address and one key would unlock both boards' flash
; ports at once.  rtl/cpu6510.v FL_ADDR / FL_SEED; updater/check_key.py.
FLPORT  = $CE00
FL_SEL  = %00000000         ; bit 2 = /CS: selected
FL_DES  = %00000100         ; deselected
FL_LOCK = $80               ; any value with bit 7: lock the port again

; the processor port while updating: P0/P1 (LORAM/HIRAM) high, P2 = MOSI,
; P5 = SCK.  DDR %00100111: bits 0,1,2,5 out; 3 (MISO) and 4 (the J4 link) IN.
UP_DDR  = %00100111
PB      = %00000011         ; LORAM, HIRAM; MOSI 0, SCK 0
P_MOSI  = %00000100
P_SCK   = %00100000
P_MISO  = %00001000

CMD_WREN   = $06
CMD_WRDI   = $04
CMD_PP     = $02
CMD_READ   = $03
CMD_BE64   = $D8
CMD_SE4K   = $20
CMD_RDSR   = $05
CMD_JEDEC  = $9F
CMD_RELPD  = $AB
CMD_RSTEN  = $66
CMD_RST    = $99

; Unlock -- 16 bytes, in order, to FLPORT.  The gateware also needs J4 (P4 held
; low from outside with DDR bit 4 clear) THROUGHOUT; port_setup clears the bit.
; ⚠ ANY OTHER WRITE TO FLPORT BETWEEN THESE RESTARTS THE SEQUENCE.
unlock
        ldx #0
-       lda fl_key,x
        sta FLPORT
        inx
        cpx #16
        bne -
        rts

lock_port
        lda #FL_LOCK
        sta FLPORT
        rts

; The build's ID into fl_id/fl_id+1 -- only while UNLOCKED: locked, FLPORT is
; ordinary RAM.  Also left at $02F8/$02F9 for the Ultimate's readmem.
read_id
        lda FLPORT
        sta fl_id
        sta $02F8
        lda FLPORT+1
        sta fl_id+1
        sta $02F9
        rts

; WARM BOOT into image A (0-3; header record A+1) -- unlocked only.  The FPGA
; reconfigures from that slot and the core restarts through $FFFC: this call
; does not return.  ⚠ The cold boot (power on) is untouched: always slot A.
warm_boot
        and #%00000011
        ora #%01000000
        sei
        sta FLPORT
-       jmp -                       ; the reconfiguration takes the CPU away

; DDR for the update.  Leaves the port at PB|P_MOSI|P_SCK: CHAREN 1, SCK high.
port_setup
        lda #PB|P_MOSI|P_SCK
        sta $01
        lda #UP_DDR
        sta $00
        rts

; the KERNAL's own port again: DDR $2F, $37
port_restore
        lda #$37
        sta $01
        lda #$2F
        sta $00
        rts

; ⚠ SEI HERE, CLI IN spi_release: CHAREN is about to follow MOSI.
spi_select
        sei
        lda #PB|P_SCK               ; SCK high (mode 3 idle), MOSI 0 = CHAREN 0
        sta $01
        lda #FL_SEL
        sta FLPORT
        rts

spi_release
        lda #FL_DES
        sta FLPORT
        lda #PB|P_MOSI|P_SCK        ; CHAREN back to 1, SCK idle high
        sta $01
        cli
        rts

; Send A, MSB first.  Per bit: SCK low with the data, then SCK high (the flash
; takes DI on the rising edge).  ~22 cycles a bit.  Returns X = 0.
spi_byte
        sta fl_tmp
        ldx #8
-       lda #PB
        asl fl_tmp
        bcc +
        ora #P_MOSI
+       sta $01                     ; SCK low, data set up
        ora #P_SCK
        sta $01                     ; SCK high: the flash samples here
        dex
        bne -
        rts

; Read a byte into A.  Per bit: SCK low (the flash puts the bit on DO at the
; falling edge), read $01 bit 3, SCK high.  MOSI is held 0.  Returns X = 0.
spi_read
        ldx #8
-       lda #PB
        sta $01                     ; SCK low: DO changes
        lda $01
        and #P_MISO
        cmp #P_MISO                 ; carry = the bit
        rol fl_tmp
        lda #PB|P_SCK
        sta $01                     ; SCK high
        dex
        bne -
        lda fl_tmp
        rts

; ⚠ WAKE THE FLASH FIRST (DRAMa's two lost days): the iCE40 leaves it in DEEP
; POWER-DOWN after configuring, and asleep it obeys only $AB.  $FF x4 first
; ends any continuous-read mode, then release, then a software reset.
flash_wake
        jsr spi_select
        lda #4
        sta fl_cnt
-       lda #$FF
        jsr spi_byte
        dec fl_cnt
        bne -
        jsr spi_release
        lda #CMD_RELPD
        jsr spi_cmd
        jsr wait_short              ; tRES1 3 us
        lda #CMD_RSTEN
        jsr spi_cmd
        lda #CMD_RST
        jsr spi_cmd
        jsr wait_short              ; tRST 30 us
        rts

; one-byte command, selected and released around it
spi_cmd
        pha
        jsr spi_select
        pla
        jsr spi_byte
        jmp spi_release

; ~60 us
wait_short
        ldx #12
-       dex
        bne -
        rts

read_status
        jsr spi_select
        lda #CMD_RDSR
        jsr spi_byte
        jsr spi_read
        pha
        jsr spi_release
        pla
        rts

write_enable
        lda #CMD_WREN
        jmp spi_cmd

write_disable
        lda #CMD_WRDI
        jmp spi_cmd

; Poll until not busy.  Carry CLEAR when done, SET if still busy after
; 65536 x fl_tmo polls (~30 s per unit of fl_tmo, set by the caller) -- a flash
; that never finishes must stop the update, not hang it.
wait_ready
        lda #0
        sta fl_pl
        sta fl_ph
-       jsr read_status
        and #%00000001
        beq +
        inc fl_pl
        bne -
        inc fl_ph
        bne -
        dec fl_tmo
        bne -
        sec
        rts
+       clc
        rts

; carry CLEAR if the flash answers EF 40 15 and its WEL toggles both ways --
; questions no stuck bus value can answer ($FF and $00 both fail).
flash_check
        jsr spi_select
        lda #CMD_JEDEC
        jsr spi_byte
        jsr spi_read
        sta fl_jid
        jsr spi_read
        sta fl_jid+1
        jsr spi_read
        sta fl_jid+2
        jsr spi_release
        lda fl_jid
        cmp #$EF
        bne .fc_bad
        lda fl_jid+1
        cmp #$40
        bne .fc_bad
        lda fl_jid+2
        cmp #$15
        bne .fc_bad
        jsr write_enable
        jsr read_status
        and #%00000010
        beq .fc_bad
        jsr write_disable
        jsr read_status
        and #%00000010
        bne .fc_bad
        clc
        rts
.fc_bad
        sec
        rts

; send the 24-bit address in fl_addr (high byte first)
send_addr
        lda fl_addr
        jsr spi_byte
        lda fl_addr+1
        jsr spi_byte
        lda fl_addr+2
        jmp spi_byte

; WREN, then the erase command A at fl_addr, then poll.  Carry as wait_ready.
erase_cmd
        pha
        jsr write_enable
        jsr spi_select
        pla
        jsr spi_byte
        jsr send_addr
        jsr spi_release
        lda #2                      ; up to ~6 s (BE64 max 2 s)
        sta fl_tmo
        jmp wait_ready

; program fl_len bytes (1-256; 0 = 256) from (fl_src) to fl_addr, then poll.
program_page
        jsr write_enable
        jsr spi_select
        lda #CMD_PP
        jsr spi_byte
        jsr send_addr
        ldy #0
-       lda (fl_src),y
        jsr spi_byte
        iny
        cpy fl_len
        bne -
        jsr spi_release
        lda #1                      ; PP max 3 ms
        sta fl_tmo
        jmp wait_ready

; start a READ at fl_addr: leaves the flash SELECTED; take bytes with spi_read
; and finish with spi_release
read_start
        jsr spi_select
        lda #CMD_READ
        jsr spi_byte
        jmp send_addr

fl_addr !byte 0,0,0                 ; 24-bit flash address, big end first
fl_cnt  !byte 0
fl_tmp  !byte 0
fl_tmo  !byte 0
fl_pl   !byte 0
fl_ph   !byte 0
fl_len  !byte 0
fl_jid  !byte 0,0,0
fl_id   !byte 0,0

; ⚠ GENERATED FROM THE RTL'S OWN LFSR (rtl/cpu6510.v FL_SEED, x^8+x^6+x^5+x^4+1).
; updater/check_key.py regenerates it and FAILS if the two ever disagree.
fl_key  !byte $3C,$79,$F3,$E7,$CE,$9C,$39,$73,$E6,$CC,$98,$31,$62,$C5,$8B,$16
