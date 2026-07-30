.p816
; ============================================================================
; sdramtest.s -- flat SDRAM conformance test, run as a boot overlay.
;
; Banks $01-$FF live in SDRAM via rtl/flat_sdram.sv and have NEVER served a
; CPU access on hardware -- the bands demo and the VERA816 test both run
; entirely in bank $00, which is BRAM. That is 15.9 MB of the 16 MB address
; space unproven, including the whole CPU stall path (cpu_rdy), the write
; FIFO, and the consume-clear read delivery.
;
; Self-contained: no loader, no font, no filesystem. Colour says which test
; failed, so a failure is diagnostic rather than just "red".
;
;   GREEN   pass
;   RED     test 1 -- bank address lines A16-A23
;   PURPLE  test 2 -- mid address lines A8-A15
;   YELLOW  test 3 -- low address lines A0-A7
;   CYAN    test 4 -- data lines D0-D7
;
; This also doubles as a check that the board actually has a 32 MB SDRAM
; module fitted: without one, test 1 fails immediately.
;
; No explicit wait for SDRAM init is needed. flat_sdram holds `ready` low
; until a read completes, and its FSM does not service requests before
; S_IDLE, so the first access self-synchronises by stalling the CPU.
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

ptr            = $20            ; 3-byte long pointer: lo, mid, bank
got            = $10            ; scratch / result colour

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
        sep     #$30            ; 8-bit A/X/Y for the whole test
.a8
.i8

; ---- test 1: bank address lines --------------------------------------------
; One byte at $BB:0000 for BB = $01..$FF, value = bank number. Exercises
; A16-A23 and proves every bank is distinct rather than aliased.
        stz     ptr
        stz     ptr+1
        lda     #$01
        sta     ptr+2
t1w:    lda     ptr+2
        sta     [ptr]
        inc     ptr+2
        bne     t1w             ; $FF -> $00 ends the sweep

        lda     #$01
        sta     ptr+2
t1r:    lda     [ptr]
        cmp     ptr+2
        bne     fail1
        inc     ptr+2
        bne     t1r

; ---- test 2: mid address lines ---------------------------------------------
; 256 locations at 256-byte stride through bank $01. Exercises A8-A15.
; The pattern is XORed so a stuck-at-zero data path cannot pass by accident.
        stz     ptr
        stz     ptr+1
        lda     #$01
        sta     ptr+2
        ldx     #0
t2w:    txa
        eor     #$5A
        sta     [ptr]
        inc     ptr+1
        inx
        bne     t2w

        stz     ptr+1
        ldx     #0
t2r:    lda     [ptr]
        sta     got
        txa
        eor     #$5A
        cmp     got
        bne     fail2
        inc     ptr+1
        inx
        bne     t2r

; ---- test 3: low address lines ---------------------------------------------
; 256 consecutive bytes at $01:0000. Exercises A0-A7 and the byte lane.
        stz     ptr
        stz     ptr+1
        lda     #$01
        sta     ptr+2
        ldy     #0
t3w:    tya
        sta     [ptr],y
        iny
        bne     t3w

        ldy     #0
t3r:    lda     [ptr],y
        sty     got
        cmp     got
        bne     fail3
        iny
        bne     t3r

; ---- test 4: data lines ----------------------------------------------------
; Walking one through all eight bit positions at $02:0000.
        stz     ptr
        stz     ptr+1
        lda     #$02
        sta     ptr+2
        lda     #$01
t4:     sta     got
        sta     [ptr]
        lda     [ptr]
        cmp     got
        bne     fail4
        lda     got
        asl     a
        bne     t4

pass:   lda     #5              ; green
        bra     paint
fail1:  lda     #2              ; red    -- bank lines
        bra     paint
fail2:  lda     #4              ; purple -- mid lines
        bra     paint
fail3:  lda     #7              ; yellow -- low lines
        bra     paint
fail4:  lda     #3              ; cyan   -- data lines

; ----------------------------------------------------------------------------
paint:
        sta     got
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
vera_init:
        stz     VERA_CTRL
        lda     #$11            ; VGA output + layer 0 enable
        sta     VERA_DC_VIDEO
        lda     #$40            ; half scale -> 320x240 active
        sta     VERA_DC_HSCALE
        sta     VERA_DC_VSCALE
        lda     #$07            ; bitmap mode, 8bpp
        sta     VERA_L0_CONFIG
        stz     VERA_L0_TILEB
        rts

trap:   rti

.segment "VECT816"              ; $FFE4
        .addr   trap, trap, trap, trap, trap, trap

.segment "VECTORS"              ; $FFF4
        .addr   trap, trap, trap, trap
        .addr   reset
        .addr   trap
