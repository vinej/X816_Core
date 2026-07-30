.p816
; ============================================================================
; loadtest.s -- minimal loadable program, to prove the handoff.
;
; Paints the screen BLUE. Nothing else. The point is to distinguish three
; outcomes at a glance:
;
;   BLUE   the program loaded and boot.s jumped to it
;   BANDS  boot.s ran but found no magic -- the load did not reach $01:0000
;   BLACK  neither ran
;
; It also exercises two things nothing else has: the HPS/ioctl loader path
; into SDRAM, and CODE EXECUTION from SDRAM -- every instruction fetch here
; stalls the CPU on flat_sdram, where the bands demo and both conformance
; tests ran entirely out of bank-0 BRAM.
;
; Entry state, set by boot.s: native mode, 8-bit A, 16-bit X/Y, DBR = $00,
; D = $0000, S = $7FFF. PBR is $01 because we arrived by JML, so absolute
; addressing still reaches bank $00 -- which is where the I/O page is.
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

.segment "MAGIC"
        .byte   "X816"          ; boot.s checks these four bytes

.segment "CODE"
start:
        sep     #$20            ; 8-bit A
        rep     #$10            ; 16-bit X/Y
.a8
.i16
        ; VERA: layer 0, 320x240, 8bpp bitmap at VRAM $00000
        stz     VERA_CTRL
        lda     #$11            ; VGA output + layer 0 enable
        sta     VERA_DC_VIDEO
        lda     #$40            ; half scale -> 320x240 active
        sta     VERA_DC_HSCALE
        sta     VERA_DC_VSCALE
        lda     #$07            ; bitmap mode, 8bpp
        sta     VERA_L0_CONFIG
        stz     VERA_L0_TILEB

        stz     VERA_CTRL
        stz     VERA_ADDR_L
        stz     VERA_ADDR_M
        lda     #$10            ; increment 1, addr[19:16] = 0
        sta     VERA_ADDR_H

        ldy     #240
@line:  ldx     #320
@px:    lda     #6              ; blue
        sta     VERA_DATA0
        dex
        bne     @px
        dey
        bne     @line

halt:   wai
        bra     halt
