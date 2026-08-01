.p816
; ============================================================================
; fwprobe.s -- staged kernel-firmware stand-in for sim/tb_boot (target `fw`).
;
; Streamed to $F0:0000 through flat_sdram's loader port, the path boot2.rom
; takes (ioctl index 16'h0080).  boot.s must take the FIRMWARE magic branch
; and jml $F0:0004.  Entry state per boot/boot.s handover: E=0, A 8-bit,
; X/Y 16-bit, DBR=$00, D=$0000, S=$7FFF.
;
; Witness bytes for the testbench:
;   $00:0400 <- $42   bank-0 BRAM write
;   $00:0401 <- $C7   second BRAM write
;   $00:0402 <- $5A   SDRAM write->readback via $01:3000 (outside firmware)
;   $00:0403 <- $AA   the firmware WRITE-PROTECT held: our attempt to clobber
;                     our own magic byte was dropped and read back unchanged
;             <- $EE  protection did NOT hold (testbench fails instantly)
;
; Linked with fwprobe.cfg (MAGIC at $F0:0000, CODE at $F0:0004).
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
        sta     f:$013000       ; SDRAM write through the wfifo (writable bank)
        lda     #$00            ; scrub A so the readback is load-bearing
        lda     f:$013000
        sta     $0402

        ; ---- write-protect check: try to overwrite our own magic 'X' -------
        lda     #$99
        sta     f:$F00000       ; the core must DROP this store
        lda     f:$F00000       ; read back through the normal read path
        cmp     #'X'
        bne     broken
        lda     #$AA
        sta     $0403           ; protection held
park:   bra     park

broken: lda     #$EE
        sta     $0403           ; protection failed -- testbench FAILs on this
        bra     park
