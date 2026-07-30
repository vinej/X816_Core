.p816
; ============================================================================
; hello.s -- X816 "Hello World": VERA text mode, 80x60, with reusable
;            putc/puts primitives.
;
; Deliberately not a hardcoded string blit. Text output is the foundation a
; monitor, a REPL and every error message needs, so it is written as routines
; from the start rather than something to redo later.
;
; Runs in place from SDRAM at $01:0004 -- boot.s jumps here after finding the
; "X816" magic. Every instruction fetch therefore stalls the CPU on
; flat_sdram, which is the normal condition for a flat machine.
;
; VRAM layout:
;   $00000-$03FFF   tilemap, 128x64 entries x 2 bytes
;   $04100-$042FF   font, 64 glyphs x 8 bytes (tile $20 onwards)
;
; The map is 128 wide, so a map address is (y*128 + x)*2 = y*256 + x*2 --
; which means ADDR_M is simply the row and ADDR_L is the column doubled. No
; multiply needed anywhere.
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
VERA_L0_MAPBASE= $9F2E
VERA_L0_TILEB  = $9F2F

SCR_COLS       = 80
SCR_ROWS       = 60
MAP_W          = 128            ; VERA map width (must be >= SCR_COLS)
TILE_VRAM      = $04000         ; font tile base
ATTR           = $01            ; white on black, VERA default palette

; direct page
curx           = $10
cury           = $11
strptr         = $12            ; 3 bytes: long pointer (lo, hi, bank)
tmp            = $15            ; NOT $14 -- that is strptr+2, the bank byte

.segment "MAGIC"
        .byte   "X816"

.segment "CODE"
start:
        sep     #$20
        rep     #$10
.a8
.i16
        jsr     text_init
        jsr     cls

        lda     #<msg1
        ldx     #>msg1
        jsr     puts
        jsr     newline
        lda     #<msg2
        ldx     #>msg2
        jsr     puts
        jsr     newline
        jsr     newline
        lda     #<msg3
        ldx     #>msg3
        jsr     puts

halt:   wai
        bra     halt

msg1:   .byte   "HELLO WORLD", 0
msg2:   .byte   "X816 - FLAT 16 MB, 65C816 NATIVE MODE", 0
msg3:   .byte   "RUNNING FROM SDRAM AT $01:0004", 0

; ----------------------------------------------------------------------------
; text_init -- VERA layer 0 in 80x60 text mode, font uploaded to VRAM.
;
; Full 640x480 (HSCALE/VSCALE = 128) rather than the 320x240 the bring-up
; demos used, so this is 80x60 characters.
; ----------------------------------------------------------------------------
text_init:
        stz     VERA_CTRL               ; DCSEL=0, ADDRSEL=0
        lda     #$11                    ; VGA output + layer 0 enable
        sta     VERA_DC_VIDEO
        lda     #$80                    ; 1:1 scale -> 640x480 active
        sta     VERA_DC_HSCALE
        sta     VERA_DC_VSCALE

        ; L0_CONFIG: map height 64 (1<<6), map width 128 (2<<4),
        ; bitmap mode off, colour depth 0 -> 1bpp text mode with attributes
        lda     #$60
        sta     VERA_L0_CONFIG
        stz     VERA_L0_MAPBASE         ; tilemap at VRAM $00000
        ; TILEBASE: (base >> 11) << 2, plus tile height/width bits (0 = 8x8)
        lda     #((TILE_VRAM >> 11) << 2)
        sta     VERA_L0_TILEB

        ; ---- upload the font -------------------------------------------
        ; Tile N lives at TILE_VRAM + N*8, so the first glyph ($20) goes to
        ; TILE_VRAM + $100.
        stz     VERA_CTRL
        lda     #<(TILE_VRAM + FONT_FIRST * 8)
        sta     VERA_ADDR_L
        lda     #>(TILE_VRAM + FONT_FIRST * 8)
        sta     VERA_ADDR_M
        lda     #$10 | ^(TILE_VRAM + FONT_FIRST * 8)   ; incr 1 + addr[19:16]
        sta     VERA_ADDR_H

        ldx     #0
@fu:    lda     f:font8x8,x             ; long: data is in OUR bank, DBR is $00
        sta     VERA_DATA0
        inx
        cpx     #(font8x8_end - font8x8)
        bne     @fu
        rts

; ----------------------------------------------------------------------------
; cls -- clear the whole 128x64 map, home the cursor.
; The full map is cleared, not just the visible 80x60, so nothing stale shows
; at the edges if the display size is ever changed.
; ----------------------------------------------------------------------------
cls:
        stz     VERA_CTRL
        stz     VERA_ADDR_L
        stz     VERA_ADDR_M
        lda     #$10                    ; incr 1, addr[19:16] = 0
        sta     VERA_ADDR_H

        ldx     #(MAP_W * 64)           ; entries; two bytes written each
@c:     lda     #' '
        sta     VERA_DATA0
        lda     #ATTR
        sta     VERA_DATA0
        dex
        bne     @c

        stz     curx
        stz     cury
        rts

; ----------------------------------------------------------------------------
; putc -- print the character in A at the cursor, advance.
; Characters outside the font range print as space rather than as garbage.
; ----------------------------------------------------------------------------
putc:
        cmp     #FONT_FIRST
        bcc     @space
        cmp     #FONT_LAST+1
        bcc     @ok
@space: lda     #' '
@ok:    sta     tmp

        ; VERA address = row*256 + col*2, so no multiply is needed
        stz     VERA_CTRL
        lda     curx
        asl     a
        sta     VERA_ADDR_L
        lda     cury
        sta     VERA_ADDR_M
        lda     #$10
        sta     VERA_ADDR_H

        lda     tmp
        sta     VERA_DATA0              ; character
        lda     #ATTR
        sta     VERA_DATA0              ; colour

        inc     curx
        lda     curx
        cmp     #SCR_COLS
        bcc     putc_done
        ; fall through: end of line wraps to the next row

; ----------------------------------------------------------------------------
; newline -- column 0, next row. Also the tail of putc.
; Plain labels rather than cheap locals here: `newline` would otherwise close
; putc's cheap-local scope and hide the shared exit.
; ----------------------------------------------------------------------------
newline:
        stz     curx
        inc     cury
        lda     cury
        cmp     #SCR_ROWS
        bcc     putc_done
        stz     cury                    ; wrap rather than scroll, for now
putc_done:
        rts

; ----------------------------------------------------------------------------
; puts -- print the NUL-terminated string at A (low) / X (high).
; ----------------------------------------------------------------------------
puts:
        sta     strptr
        stx     strptr+1
        phk                             ; our bank -- strings live with the code
        pla
        sta     strptr+2
        ldy     #0
@l:     lda     [strptr],y              ; long indirect: DBR is $00, we are not
        beq     @end
        phy
        jsr     putc
        ply
        iny
        bra     @l
@end:   rts

        .include "font8x8.inc"
