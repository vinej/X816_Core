.p816
; ============================================================================
; vramtest.s -- VERA816 conformance test, run as a boot overlay.
;
; Implements the tests in doc/VERA816.md section 8. Self-contained: it needs
; no loader, no font and no filesystem, so it can be the very first thing run
; on either the emulator or real hardware.
;
;   GREEN screen = pass
;   RED   screen = fail
;
; Both implementations must produce green before any application software is
; written against VERA816.
;
; The march walks the FULL 19-bit space in 256-byte steps using VERA's own
; auto-increment, so the address is set exactly once. That covers every
; address bit including 17 and 18, and it runs the populated region and the
; hole in a single pass -- steps 0..1407 are the 352 KB that exists, steps
; 1408..2047 are the hole that must read back as zero.
; ============================================================================

VERA_ADDR_L    = $9F20
VERA_ADDR_M    = $9F21
VERA_ADDR_H    = $9F22
VERA_DATA0     = $9F23
VERA_CTRL      = $9F25
VERA_DC_VIDEO  = $9F29
VERA_DC_HSCALE = $9F2A
VERA_DC_VSCALE = $9F2B
VERA_L0_CONFIG = $9F2D
VERA_L0_TILEB  = $9F2F

; VERA816 extension bank: CTRL = {0, DCSEL[5:0], ADDRSEL}, so DCSEL=32 is $40
DCSEL32        = $40
VERA_VRAMCAP   = $9F2C          ; read-only, 16 KB units -> 22 for 352 KB

STEPS_TOTAL    = 2048           ; $80000 / 256, the whole 19-bit space
STEPS_POPULATED = 1408          ; $58000 / 256, the 352 KB that exists

got            = $10            ; direct page scratch

.segment "BOOT"
; ----------------------------------------------------------------------------
reset:
        sei
        clc
        xce                     ; native mode
        rep     #$38            ; 16-bit A/X/Y, decimal cleared
.a16
.i16
        lda     #$7FFF
        tcs
        lda     #$0000
        tcd
        phk
        plb

; ---- test 3: capability register -------------------------------------------
; VRAMCAP reads 22 on VERA816 and 0 on stock VERA, so this also proves the
; DCSEL=32 bank decodes at all.
        sep     #$20
.a8
        lda     #DCSEL32
        sta     VERA_CTRL
        lda     VERA_VRAMCAP
        cmp     #22
        bne     fail
        stz     VERA_CTRL       ; back to DCSEL=0, ADDRSEL=0

; ---- tests 1 + 2: march the whole 19-bit space, 256-byte steps -------------
; increment nibble 9 = 256; ADDR = $00000
        jsr     addr_zero

        rep     #$10
.i16
        ldx     #0
wr_loop:
        txa                     ; 8-bit A takes X's low byte
        sta     VERA_DATA0
        inx
        cpx     #STEPS_TOTAL
        bne     wr_loop

; read back
        jsr     addr_zero
        ldx     #0
rd_loop:
        lda     VERA_DATA0
        sta     got
        cpx     #STEPS_POPULATED
        bcs     @hole
        txa                     ; expected = step low byte
        bra     @cmp
@hole:  lda     #0              ; the hole must read back as zero
@cmp:   cmp     got
        bne     fail
        inx
        cpx     #STEPS_TOTAL
        bne     rd_loop

; ---- test 4: auto-increment wraps within 19 bits ---------------------------
; After STEPS_TOTAL steps of 256 from zero the address has wrapped exactly
; once, so it must be back at $00000 -- including bits 18:17 in ADDRX.
        lda     VERA_ADDR_L
        bne     fail
        lda     VERA_ADDR_M
        bne     fail
        lda     VERA_ADDR_H
        and     #$01            ; bit 0 is address bit 16; upper nibble is incr
        bne     fail
        lda     #DCSEL32
        sta     VERA_CTRL
        lda     $9F29           ; ADDRX: bits 18:17 of both address registers
        and     #$03
        bne     fail
        stz     VERA_CTRL

pass:   lda     #5              ; green
        bra     paint
fail:   lda     #2              ; red

; ----------------------------------------------------------------------------
; paint -- fill a 320x240 8bpp bitmap with the colour in A
; ----------------------------------------------------------------------------
paint:
        sta     got             ; stash the colour
        jsr     vera_init
        stz     VERA_CTRL
        stz     VERA_ADDR_L
        stz     VERA_ADDR_M
        lda     #$10            ; increment 1, addr[19:16] = 0
        sta     VERA_ADDR_H
        rep     #$10
.i16
        ldy     #240
@line:  ldx     #320
@px:    lda     got
        sta     VERA_DATA0
        dex
        bne     @px
        dey
        bne     @line
halt:   wai
        bra     halt

; ----------------------------------------------------------------------------
addr_zero:
        stz     VERA_CTRL       ; DCSEL=0, ADDRSEL=0
        stz     VERA_ADDR_L
        stz     VERA_ADDR_M
        lda     #$90            ; increment nibble 9 = 256, addr[19:16] = 0
        sta     VERA_ADDR_H
        lda     #DCSEL32
        sta     VERA_CTRL
        stz     $9F29           ; ADDRX = 0
        stz     VERA_CTRL
        rts

vera_init:
        stz     VERA_CTRL
        lda     #$11            ; VGA output + layer 0 enable
        sta     VERA_DC_VIDEO
        lda     #$40            ; half scale -> 320x240 active
        sta     VERA_DC_HSCALE
        sta     VERA_DC_VSCALE
        lda     #$07            ; bitmap mode, 8bpp
        sta     VERA_L0_CONFIG
        stz     VERA_L0_TILEB   ; bitmap base 0, 320 wide
        rts

trap:   rti

.segment "VECT816"              ; $FFE4
        .addr   trap, trap, trap, trap, trap, trap

.segment "VECTORS"              ; $FFF4
        .addr   trap, trap, trap, trap
        .addr   reset
        .addr   trap
