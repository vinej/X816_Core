.p816
; ============================================================================
; bootprobe.s -- minimal staged program for sim/tb_boot (target `boot`).
;
; Streamed to $01:0000 through flat_sdram's loader port, exactly as the HPS
; ioctl path loads boot1.rom.  Entry state per boot/boot.s handover: E=0,
; A 8-bit, X/Y 16-bit, DBR=$00, D=$0000, S=$7FFF.
;
; Writes three witness bytes the testbench watches for:
;   $00:0400 <- $42   bank-0 BRAM write (absolute, DBR=$00)
;   $00:0401 <- $C7   second BRAM write
;   $00:0402 <- $5A   the value read BACK from an SDRAM write at $01:3000 --
;                     this one proves flat_sdram's write FIFO and the
;                     read-after-write ordering, not just the store
; then parks in a branch-to-self.
;
; Linked with boot/prog.cfg (MAGIC at $01:0000, CODE at $01:0004).
; ============================================================================

.segment "MAGIC"
        .byte   "X816"

.segment "CODE"
.a8
.i16
entry:
        lda     #$42
        sta     $0400           ; DBR=$00 -> bank-0 BRAM
        lda     #$C7
        sta     $0401
        lda     #$5A
        sta     f:$013000       ; SDRAM write through the wfifo
        lda     #$00            ; scrub A so the readback is load-bearing
        lda     f:$013000       ; SDRAM read-after-write
        sta     $0402           ; TB checks this is $5A
park:   bra     park
