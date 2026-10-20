; ---------------------------------------------------------------------------
; MOSaic -- BOOTB / BOOTA / IDENT (development loop, updater/README.md)
;
;   acme -DIMAGE=1 -> BOOTB : warm boot into slot B (header record 2)
;   acme -DIMAGE=0 -> BOOTA : warm boot into slot A (header record 1)
;   acme -DIDENT=1 -> IDENT : print the running build's ID, and stop
;
; Needs J4.  The build ID is left at $02F8/$02F9 and RESULT ($02F0) is $00 once
; it was read -- for the Ultimate's readmem -- or $FF if J4 is missing.  A warm
; boot does not return: the FPGA reconfigures and the machine restarts from its
; reset vector, as if from /RES -- and the KERNAL's reset clears $0000-$03FF,
; so run IDENT afterwards to see which build is running.
; ⚠ A POWER CYCLE ALWAYS BOOTS SLOT A (the cold boot).
; ---------------------------------------------------------------------------
!cpu 6510
CHROUT  = $FFD2
RESULT  = $02F0
fl_src  = $FD

* = $0801
        !byte $0b,$08,$0a,$00,$9e,$32,$30,$36,$31,$00,$00,$00
* = $080d
        lda #$FF
        sta RESULT
        lda $00
        and #%11101111
        sta $00
        lda $01
        and #%00010000
        beq +
        ldx #0
-       lda msg_noj4,x
        beq ++
        jsr CHROUT
        inx
        bne -
++      rts
+       jsr port_setup
        jsr unlock
        jsr read_id
        lda #0
        sta RESULT
        ldx #0
-       lda msg_id,x
        beq +
        jsr CHROUT
        inx
        bne -
+       lda fl_id+1
        jsr hex2
        lda fl_id
        jsr hex2
        lda #13
        jsr CHROUT
!ifdef IDENT {
        jsr lock_port
        jmp port_restore
} else {
        lda #IMAGE
        jmp warm_boot
}
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

msg_noj4 !text "J4 IS NOT FITTED",13,0
msg_id   !text "MOSAIC BUILD ",0

!source "spi.asm"
