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

        .include "text.inc"
