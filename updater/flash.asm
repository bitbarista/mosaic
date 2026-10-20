; ---------------------------------------------------------------------------
; MOSaic -- firmware updater (DEFERRED D-7)
;
; Rewrites MOSaic's own configuration flash, from the C64 it is the CPU of.
; No programmer touches the board: J3 in-system programming is SUSPENDED
; (ERRATA E-48, two boards lost).  This is the route instead.
;
;   fit the J4 link (C64 OFF), power on, then:  LOAD"UPDATE",8,1 : RUN
;
; Ported from c64-ice40-ram/updater/flash.asm (DRAMa).  Kept from it, on
; purpose: the FPGA holds no protocol (flash opcodes live here); a header with
; a CRC16 refuses a corrupt or foreign file before anything is committed;
; BOTH slots are written so "which slot is live" never has to be asked; the
; boot header, alone in its 4 KB sector, is rewritten last.
;
; Different here, because this board is the CPU:
;   * the SPI wires ARE the processor port (updater/spi.asm), and MISO is
;     readable -- so the busy flag is POLLED, and each slot is READ BACK and
;     checksummed BEFORE the boot pointer moves to it.  DRAMa can only check
;     the file on the way past.
;   * the file is MOSAIC.BIN with its own magic ("MOSA"), so neither board's
;     updater will take the other board's image.
;   * the unlock is FLPORT = $CE00, never DRAMa's $CF00.
;
; ⚠ SHIP THE D64 (updater/README.md): a USB/SD adapter will not serve a loose
; .BIN as a PRG file; it fails at OPEN and looks like a broken updater.
; ---------------------------------------------------------------------------

!cpu 6510

CHROUT  = $FFD2
!ifdef HOST {
; ⚠ -DHOST: THE IMAGE COMES FROM THE HOST, NOT A DISK.  The Ultimate writes it
; into C64 RAM by DMA, a chunk at a time, through the mailbox below
; (sim/hw/host_update.py; sim/mix/test_updater.py's +host bench).  The KERNAL's
; file calls are replaced by local ones with the same contract, so every check
; below -- header before erase, CRC, read-back, commit order -- is unchanged.
; 2026-10-06: the disk route stalled in OPEN on board #3 (cause unknown); this
; route has no serial bus in it at all.
SETLFS  = h_ok
SETNAM  = h_ok
OPEN    = h_open
CLOSE   = h_ok
CHKIN   = h_ok
CLRCHN  = h_ok
CHRIN   = h_chrin
READST  = h_readst
H_REQ   = $02F1             ; updater -> host: 1 = from the start, 2 = next chunk;
                            ; the host writes the chunk, H_LEN, then H_REQ = 0
H_LEN   = $02F2             ; 2 bytes: the chunk's length; 0 = no more data
H_LAST  = $02F4             ; nonzero: this chunk is the file's last
H_WIN   = $2000             ; the window: up to 32 KB, $2000-$9FFF
h_ptr   = $F7               ; $F7/$F8: zero page for (h_ptr),y
} else {
SETLFS  = $FFBA
SETNAM  = $FFBD
OPEN    = $FFC0
CLOSE   = $FFC3
CHKIN   = $FFC6
CLRCHN  = $FFCC
CHRIN   = $FFCF
READST  = $FFB7
}

zp_ptr  = $FB               ; print pointer (indirect needs zero page)
fl_src  = $FD               ; spi.asm's program_page source pointer

BUF     = $C000             ; 256-byte page buffer, in the free block
HDRBUF  = $C100
CASS1   = $C0               ; the KERNAL's tape-motor interlock flag
RESULT  = $02F0             ; $00 done, $FF failed, $AA still running -- for the
                            ; Ultimate's readmem (sim/hw), alongside the build ID
                            ; read_id leaves at $02F8

SLOT_A  = $02               ; top bytes of $020000 and $040000
SLOT_B  = $04

; --- BASIC stub: 10 SYS 2061 -------------------------------------------------
* = $0801
        !byte $0b,$08,$0a,$00,$9e,$32,$30,$36,$31,$00,$00,$00
* = $080d

; THE INVARIANT (DRAMa's): at rest the header points at slot A and both slots
; hold the current image, so B is always the spare.
;   1. write + verify B   2. commit B   3. write + verify A   4. commit A
; Every long operation lands on a slot the board is not booting from; the only
; exposure is the two header rewrites (a 4 KB erase + one page, polled).
; ⚠ A BOARD STILL ON THE PLAIN LAYOUT (one image at $000000, as iceprog wrote
; it) upgrades through the same steps: B and A lie above the old image, and
; step 2's header erase takes only its first 4 KB -- after B is verified.
main
        lda #$AA
        sta RESULT
        lda #<msg_hello
        ldy #>msg_hello
        jsr print

        ; ⚠ J4 FIRST, IN SOFTWARE TOO.  The gateware needs it regardless; this
        ; only turns "flash not responding" into the actual instruction.
        lda $00
        and #%11101111              ; P4 an input (it is in the KERNAL's $2F)
        sta $00
        lda $01
        and #%00010000
        beq +
        lda #$FF
        sta RESULT
        lda #<msg_noj4
        ldy #>msg_noj4
        jmp print
+
        ; ⚠ THE KERNAL'S IRQ RUNS THE TAPE MOTOR -- P5, OUR SCK -- whenever the
        ; sense line (P4) reads low and CASS1 is 0, and J4 holds P4 low.  CASS1
        ; nonzero tells it to leave P5 alone.  Restored at the end.
        lda CASS1
        sta cass_save
        lda #1
        sta CASS1

        jsr port_setup
        jsr unlock
        jsr read_id                 ; which build is doing this (shown below)
        jsr flash_wake

!ifdef VERBOSE {
        lda #<msg_jid
        ldy #>msg_jid
        jsr print
}
        jsr flash_check
!ifdef VERBOSE {
        lda fl_jid
        jsr print_hex_sp
        lda fl_jid+1
        jsr print_hex_sp
        lda fl_jid+2
        jsr print_hex
}
        bcc +
        lda #<msg_nowel
        ldy #>msg_nowel
        jmp finish_msg
+
!ifdef DEV {
        ; ---- DEVELOPMENT: slot B only, NEVER the header, NEVER slot A ----
        ; The golden image in A stays the cold boot; BOOTB tries this one, and
        ; a power cycle always comes back to A.
        lda #SLOT_B
        sta fl_base
        lda #<msg_dev
        ldy #>msg_dev
        jsr print
        jsr do_slot
        bcc +
        lda #<msg_p1fail
        ldy #>msg_p1fail
        jmp finish_msg
+       lda #0
        sta RESULT
        lda #<msg_devdone
        ldy #>msg_devdone
        jmp finish_msg
} else {
        ; ---- pass 1: the spare slot ------------------------------------
        lda #SLOT_B
        sta fl_base
        lda #<msg_pass1
        ldy #>msg_pass1
        jsr print
        jsr do_slot
        bcc +
        lda #<msg_p1fail
        ldy #>msg_p1fail
        jmp finish_msg
+       jsr commit
        bcc +
        lda #<msg_cfail
        ldy #>msg_cfail
        jmp finish_msg
+
        ; ---- pass 2: the slot the header pointed at --------------------
        lda #SLOT_A
        sta fl_base
        lda #<msg_pass2
        ldy #>msg_pass2
        jsr print
        jsr do_slot
        bcc +
        lda #<msg_p2fail
        ldy #>msg_p2fail
        jmp finish_msg
+       jsr commit
        bcc +
        lda #<msg_cfail
        ldy #>msg_cfail
        jmp finish_msg
+       lda #0
        sta RESULT
        lda #<msg_done
        ldy #>msg_done
}

; lock the port, give the machine its own port and tape flag back, print A/Y
finish_msg
        pha
        tya
        pha
        lda RESULT                  ; anything but a success is a failure
        beq +
        lda #$FF
        sta RESULT
+       jsr lock_port
        jsr port_restore
        lda cass_save
        sta CASS1
        pla
        tay
        pla
        jmp print

; ============================================================================
; One slot: erase, stream the file into it, then read it back.  Carry SET on
; any failure, with the reason already printed.
; ⚠ THE FILE'S HEADER IS CHECKED BEFORE THE ERASE (DRAMa erased first): a
; foreign, truncated or wrong-board file then changes NOTHING in the flash.
do_slot
        jsr open_image
        bcs +
        jsr erase_slot
        bcc ++
        jsr close_image
        lda #<msg_flerr
        ldy #>msg_flerr
        jsr print
        sec
+       rts
++      jsr write_image
        bcs +
        jsr verify_slot
+       rts

erase_slot
        jsr set_slot_addr
        lda #CMD_BE64
        jsr erase_cmd               ; first 64 KB (polled)
        bcs +
        inc fl_addr
        lda #CMD_BE64
        jsr erase_cmd               ; second: the image is ~102 KB
+       rts

set_slot_addr
        lda fl_base
        sta fl_addr
        lda #0
        sta fl_addr+1
        sta fl_addr+2
        rts

; ============================================================================
; Stream MOSAIC.BIN into the slot, a page at a time, the CRC folded in on the
; way past.  The image does not fit in memory (102 KB, 39 KB free).
open_image
        lda #1
        ldx #8
        ldy #2
        jsr SETLFS
        lda #fname_end - fname
        ldx #<fname
        ldy #>fname
        jsr SETNAM
        jsr OPEN
        bcc +
        jmp .io_err
+       ldx #1
        jsr CHKIN
        bcc +
        jmp .io_err
+       ldy #0                      ; the 18-byte header first
.rh     jsr CHRIN
        sta HDRBUF,y
        iny
        cpy #18
        bne .rh
        jsr READST
        beq +
        jmp .io_err
+
        ; ⚠ REFUSE ANYTHING THAT IS NOT OURS, BEFORE WRITING A SINGLE BYTE.
        ; (inverted branches + JMP: the handlers are beyond a branch's reach)
        ldy #3
-       lda HDRBUF,y
        cmp magic,y
        bne .bf
        lda HDRBUF+14,y
        cmp magic_end,y
        bne .bf
        dey
        bpl -
        lda HDRBUF+6                ; board revision
        cmp #"A"
        beq +
        jmp .bad_rev
+       lda HDRBUF+11               ; length < 128 KB: must fit its slot
        bne .bf
        lda HDRBUF+10
        cmp #2
        bcc +
.bf     jmp .bad_file
+       clc
        rts

close_image
        jsr CLRCHN
        lda #1
        jmp CLOSE

write_image
        jsr crc_init
        jsr set_slot_addr
        lda #<BUF
        sta fl_src
        lda #>BUF
        sta fl_src+1
.page
        ldy #0
.fill   jsr CHRIN
        sta BUF,y
        jsr crc_byte
        jsr dec_rem
        beq .last
        ; ⚠ EOF BEFORE THE HEADER'S LENGTH IS A SHORT FILE.  Without this a
        ; truncated file read on past its end and was reported as BAD CHECKSUM
        ; -- safe, but the wrong reason (test_updater.py case G).  The 1541
        ; sets EOF WITH the last byte, so it is only an error while bytes remain.
        jsr READST
        and #%01000000
        bne .short
        iny
        bne .fill
        lda #0
        sta fl_len                  ; a full page
        jsr program_page
        bcs .fl_err
        jsr prog_dot
        inc fl_addr+1
        bne .page
        inc fl_addr
        jmp .page
.last   iny                         ; Y+1 bytes in the final page
        sty fl_len
        jsr READST                  ; the file must not have run short
        and #%10111111              ; (EOF on the very last byte is right)
        bne .io_err
        jsr program_page
        bcs .fl_err
        jsr CLRCHN
        lda #1
        jsr CLOSE
        lda fl_crc                  ; ⚠ COMPARE BEFORE GOING ANY FURTHER
        cmp HDRBUF+12
        bne .bad_crc
        lda fl_crc+1
        cmp HDRBUF+13
        bne .bad_crc
        clc
        rts
.bad_crc
        lda #<msg_crc
        ldy #>msg_crc
        jmp .fail_msg
.bad_file
        lda #<msg_notours
        ldy #>msg_notours
        jmp .fail_msg
.bad_rev
        lda #<msg_wrongrev
        ldy #>msg_wrongrev
        jmp .fail_msg
.fl_err
        lda #<msg_flerr
        ldy #>msg_flerr
.fail_msg
        pha
        tya
        pha
        jsr CLRCHN
        lda #1
        jsr CLOSE
        pla
        tay
        pla
        jsr print
        sec
        rts
.short
.io_err
        jsr CLRCHN
        lda #1
        jsr CLOSE
        lda #<msg_failed
        ldy #>msg_failed
        jsr print
        sec
        rts

; ============================================================================
; ⚠ READ THE SLOT BACK AND CHECKSUM IT -- the step DRAMa cannot do.  The file's
; CRC proved the DISK was good; this proves the FLASH holds it.  One READ
; command for the whole image (interrupts are off for it: ~35 s, no disk I/O).
verify_slot
        lda #<msg_verify
        ldy #>msg_verify
        jsr print
        jsr crc_init
        jsr set_slot_addr
        jsr read_start
.vr     jsr spi_read
        jsr crc_byte
        jsr dec_rem
        bne .vr
        jsr spi_release
        lda fl_crc
        cmp HDRBUF+12
        bne .vbad
        lda fl_crc+1
        cmp HDRBUF+13
        bne .vbad
        clc
        rts
.vbad   lda #<msg_vbad
        ldy #>msg_vbad
        jsr print
        sec
        rts

crc_init
        lda HDRBUF+8
        sta fl_rem
        lda HDRBUF+9
        sta fl_rem+1
        lda HDRBUF+10
        sta fl_rem+2
        lda #$FF
        sta fl_crc
        sta fl_crc+1
        rts

; decrement the 24-bit remaining count; Z set when it reaches zero
dec_rem
        lda fl_rem
        bne +
        lda fl_rem+1
        bne ++
        dec fl_rem+2
++      dec fl_rem+1
+       dec fl_rem
        lda fl_rem
        ora fl_rem+1
        ora fl_rem+2
        rts

; ⚠ CRC16-CCITT, MSB FIRST, POLYNOMIAL $1021 -- mkfirmware.py's; check_key.py
; guards it.  A = the byte; fl_crc low byte first.  Preserves Y.
crc_byte
        stx crc_x
        eor fl_crc+1
        sta fl_crc+1
        ldx #8
.cb     asl fl_crc
        rol fl_crc+1
        bcc .cs
        lda fl_crc
        eor #$21
        sta fl_crc
        lda fl_crc+1
        eor #$10
        sta fl_crc+1
.cs     dex
        bne .cb
        ldx crc_x
        rts

; ============================================================================
; COMMIT -- point the board at fl_base.  ⚠ THE ONLY STEP THAT CAN BRICK IT:
; between the erase and the program there is no header.  Polled, so it lasts
; as long as the flash takes (4 KB erase: typ 45 ms, max 400 ms) and no longer.
; The header written is then READ BACK and compared.  Carry SET on failure.
commit
        lda #<msg_commit
        ldy #>msg_commit
        jsr print
        lda fl_base
        sta header + 9              ; record 0 IS the cold-boot pointer
        lda #0
        sta header + 10
        sta header + 11
        sta fl_addr
        sta fl_addr+1
        sta fl_addr+2
        lda #CMD_SE4K
        jsr erase_cmd
        bcs .cx
        lda #<header
        sta fl_src
        lda #>header
        sta fl_src+1
        lda #160
        sta fl_len
        jsr program_page
        bcs .cx
        jsr read_start              ; and check it
        ldy #0
-       sty crc_x
        jsr spi_read
        ldy crc_x
        cmp header,y
        bne .cbad
        iny
        cpy #160
        bne -
        jsr spi_release
        clc
        rts
.cbad   jsr spi_release
        sec
.cx     rts

; one dot per 4 pages.  ⚠ Y IS THE PAGE INDEX; keep it across CHROUT.
prog_dot
        tya
        pha
        dec dot_cnt
        bne .nodot
        lda #4
        sta dot_cnt
        lda #"."
        jsr CHROUT
.nodot  pla
        tay
        rts

print_hex_sp
        jsr hex2
        lda #" "
        jmp CHROUT
print_hex
        jsr hex2
        lda #13
        jmp CHROUT
hex2    pha
        lsr
        lsr
        lsr
        lsr
        jsr .nib
        pla
        and #$0F
.nib    cmp #10
        bcc +
        adc #6
+       adc #$30
        jmp CHROUT

print
        sta zp_ptr
        sty zp_ptr+1
        ldy #0
-       lda (zp_ptr),y
        beq +
        tya
        pha
        lda (zp_ptr),y
        jsr CHROUT
        pla
        tay
        iny
        bne -
+       rts

!ifdef HOST {
; ---- the host-fed file: the KERNAL's contract, from RAM -------------------
h_ok    clc
        rts

h_open  lda #1                      ; from the start
        jsr h_ask
        clc
        rts

; the next byte in A; Y and X preserved.  READST then says EOF ($40) once the
; last byte the host has has been taken, exactly as the 1541 sets it.
h_chrin stx h_x
        sty h_y
        lda h_left
        ora h_left+1
        bne +
        lda #2                      ; this chunk is used up: ask for the next
        jsr h_ask
+       ldy #0
        lda (h_ptr),y
        pha
        inc h_ptr
        bne +
        inc h_ptr+1
+       lda h_left
        bne +
        dec h_left+1
+       dec h_left
        lda h_left                  ; empty now, and the host said that was all?
        ora h_left+1
        bne +
        lda h_last
        beq +
        lda #$40
        sta h_st
+       pla
        ldx h_x
        ldy h_y
        rts

h_readst
        lda h_st
        rts

; ask (A = 1 or 2) and wait for the host to answer.  An empty answer is the
; end of the data: h_st gets EOF and CHRIN then returns zeros, which the CRC
; and the length check catch as a short file.
h_ask   sta H_REQ
-       lda H_REQ
        bne -
        lda #<H_WIN
        sta h_ptr
        lda #>H_WIN
        sta h_ptr+1
        lda H_LEN
        sta h_left
        lda H_LEN+1
        sta h_left+1
        lda #0
        sta h_st
        sta h_last
        lda H_LEN
        ora H_LEN+1
        bne +
        lda #$40
        sta h_st
        lda #1                      ; nothing to read: hand back the window's
        sta h_left                  ; first byte once, with EOF already set
+       lda H_LAST                  ; the host says whether more follows
        sta h_last
        rts

h_left  !byte 0,0
h_st    !byte 0
h_last  !byte 0
h_x     !byte 0
h_y     !byte 0
}

!source "spi.asm"

fl_rem  !byte 0,0,0
fl_crc  !byte 0,0
fl_base !byte SLOT_B
crc_x   !byte 0
dot_cnt !byte 4
cass_save !byte 0

magic     !text "MOSA"
magic_end !text "ASOM"

; ⚠ THE MULTIBOOT HEADER: five 32-byte records, record 0 the cold-boot pointer
; (offsets 9-11 patched at run time).  mkfirmware.py builds the same bytes and
; checks them against icemulti; check_key.py checks this table against it.
header
        !byte $7E,$AA,$99,$7E,$92,$00,$00,$44
        !byte $03,$02,$00,$00,$82,$00,$00,$01
        !byte $08,$00,$00,$00,$00,$00,$00,$00
        !byte $00,$00,$00,$00,$00,$00,$00,$00
        !byte $7E,$AA,$99,$7E,$92,$00,$00,$44
        !byte $03,$02,$00,$00,$82,$00,$00,$01
        !byte $08,$00,$00,$00,$00,$00,$00,$00
        !byte $00,$00,$00,$00,$00,$00,$00,$00
        !byte $7E,$AA,$99,$7E,$92,$00,$00,$44
        !byte $03,$04,$00,$00,$82,$00,$00,$01
        !byte $08,$00,$00,$00,$00,$00,$00,$00
        !byte $00,$00,$00,$00,$00,$00,$00,$00
        !byte $7E,$AA,$99,$7E,$92,$00,$00,$44
        !byte $03,$02,$00,$00,$82,$00,$00,$01
        !byte $08,$00,$00,$00,$00,$00,$00,$00
        !byte $00,$00,$00,$00,$00,$00,$00,$00
        !byte $7E,$AA,$99,$7E,$92,$00,$00,$44
        !byte $03,$02,$00,$00,$82,$00,$00,$01
        !byte $08,$00,$00,$00,$00,$00,$00,$00
        !byte $00,$00,$00,$00,$00,$00,$00,$00

fname       !text "MOSAIC.BIN,P,R"
fname_end

msg_hello   !text 147,"MOSAIC FIRMWARE UPDATE",13,13,0
msg_noj4    !text "J4 IS NOT FITTED.",13,13,"TURN THE C64 OFF, FIT THE J4 LINK,",13,"TURN IT ON AND RUN THIS AGAIN.",13,"NOTHING HAS BEEN CHANGED.",13,0
msg_nowel   !text 13,"FLASH IS NOT RESPONDING.",13,"NOTHING HAS BEEN CHANGED.",13,0
msg_pass1   !text "STEP 1 OF 2 - SPARE SLOT",13,0
msg_pass2   !text 13,"STEP 2 OF 2 - MAIN SLOT",13,0
msg_verify  !text 13,"CHECKING...",13,0
msg_vbad    !text "FLASH DOES NOT MATCH THE FILE",13,0
msg_flerr   !text "FLASH DID NOT FINISH",13,0
msg_p1fail  !text "STOPPED. BOARD IS UNCHANGED.",13,0
msg_p2fail  !text "BOARD IS UPDATED AND WORKING.",13,13,"RUN THIS AGAIN TO RESTORE THE SPARE.",13,0
msg_cfail   !text "HEADER WRITE FAILED.",13,"DO NOT SWITCH OFF. RUN THIS AGAIN.",13,0
; ⚠ REMOVING J4 IS PART OF FINISHING: while it is fitted the flash port can be
; unlocked, and the KERNAL sees PLAY pressed (a datasette motor would run).
msg_done    !text 13,"UPDATE COMPLETE.",13,13,"1. TURN THE C64 OFF.",13,"2. REMOVE THE J4 LINK.",13,"3. TURN IT BACK ON.",13,0
msg_failed  !text "DISK ERROR - NOT PROGRAMMED",13,0
msg_crc     !text "BAD CHECKSUM - NOT COMMITTED",13,0
msg_notours !text "NOT A MOSAIC FIRMWARE FILE",13,0
msg_wrongrev !text "FIRMWARE IS FOR A DIFFERENT BOARD",13,0
msg_commit  !text 13,"COMMITTING - DO NOT SWITCH OFF",13,0
msg_dev     !text "DEVELOPMENT: SLOT B ONLY",13,"SLOT A AND THE BOOT HEADER UNTOUCHED",13,0
msg_devdone !text 13,"SLOT B WRITTEN AND CHECKED.",13,"RUN BOOTB TO TRY IT. POWER OFF/ON",13,"ALWAYS RETURNS TO SLOT A.",13,0
!ifdef VERBOSE {
msg_jid     !text "JEDEC (WANT EF 40 15): ",0
}
