; ============================================================================
; font8x8.inc -- 8x8 1bpp glyphs for ASCII $20-$5F (64 characters).
;
; Space, punctuation, digits and uppercase -- enough for readable output
; without carrying a full 256-glyph set. Each glyph is 8 bytes, one per
; scanline, MSB = leftmost pixel, which is the layout VERA's 1bpp tile mode
; expects.
;
; Hand-authored in the conventional 8x8 terminal style. Typeface *designs*
; are not copyrightable (only specific font software is), and these are
; plain bitmaps written for this project, so there is no third-party
; provenance to track -- consistent with the ROM-free stance of the core.
;
; Lower case is deliberately absent. Add $60-$7F here and widen the range
; check in putc when it is wanted.
; ============================================================================

FONT_FIRST = $20
FONT_LAST  = $5F

font8x8:
        .byte $00,$00,$00,$00,$00,$00,$00,$00   ; $20 space
        .byte $18,$18,$18,$18,$18,$00,$18,$00   ; $21 !
        .byte $6C,$6C,$48,$00,$00,$00,$00,$00   ; $22 "
        .byte $6C,$6C,$FE,$6C,$FE,$6C,$6C,$00   ; $23 #
        .byte $18,$3E,$60,$3C,$06,$7C,$18,$00   ; $24 $
        .byte $00,$C6,$CC,$18,$30,$66,$C6,$00   ; $25 %
        .byte $38,$6C,$38,$76,$DC,$CC,$76,$00   ; $26 &
        .byte $18,$18,$30,$00,$00,$00,$00,$00   ; $27 '
        .byte $0C,$18,$30,$30,$30,$18,$0C,$00   ; $28 (
        .byte $30,$18,$0C,$0C,$0C,$18,$30,$00   ; $29 )
        .byte $00,$66,$3C,$FF,$3C,$66,$00,$00   ; $2A *
        .byte $00,$18,$18,$7E,$18,$18,$00,$00   ; $2B +
        .byte $00,$00,$00,$00,$00,$18,$18,$30   ; $2C ,
        .byte $00,$00,$00,$7E,$00,$00,$00,$00   ; $2D -
        .byte $00,$00,$00,$00,$00,$18,$18,$00   ; $2E .
        .byte $06,$0C,$18,$30,$60,$C0,$80,$00   ; $2F /
        .byte $7C,$C6,$CE,$DE,$F6,$E6,$7C,$00   ; $30 0
        .byte $18,$38,$18,$18,$18,$18,$7E,$00   ; $31 1
        .byte $7C,$C6,$06,$1C,$30,$66,$FE,$00   ; $32 2
        .byte $7C,$C6,$06,$3C,$06,$C6,$7C,$00   ; $33 3
        .byte $1C,$3C,$6C,$CC,$FE,$0C,$1E,$00   ; $34 4
        .byte $FE,$C0,$C0,$FC,$06,$C6,$7C,$00   ; $35 5
        .byte $38,$60,$C0,$FC,$C6,$C6,$7C,$00   ; $36 6
        .byte $FE,$C6,$0C,$18,$30,$30,$30,$00   ; $37 7
        .byte $7C,$C6,$C6,$7C,$C6,$C6,$7C,$00   ; $38 8
        .byte $7C,$C6,$C6,$7E,$06,$0C,$78,$00   ; $39 9
        .byte $00,$18,$18,$00,$00,$18,$18,$00   ; $3A :
        .byte $00,$18,$18,$00,$00,$18,$18,$30   ; $3B ;
        .byte $0C,$18,$30,$60,$30,$18,$0C,$00   ; $3C <
        .byte $00,$00,$7E,$00,$7E,$00,$00,$00   ; $3D =
        .byte $60,$30,$18,$0C,$18,$30,$60,$00   ; $3E >
        .byte $7C,$C6,$0C,$18,$18,$00,$18,$00   ; $3F ?
        .byte $7C,$C6,$DE,$DE,$DE,$C0,$78,$00   ; $40 @
        .byte $38,$6C,$C6,$C6,$FE,$C6,$C6,$00   ; $41 A
        .byte $FC,$66,$66,$7C,$66,$66,$FC,$00   ; $42 B
        .byte $3C,$66,$C0,$C0,$C0,$66,$3C,$00   ; $43 C
        .byte $F8,$6C,$66,$66,$66,$6C,$F8,$00   ; $44 D
        .byte $FE,$62,$68,$78,$68,$62,$FE,$00   ; $45 E
        .byte $FE,$62,$68,$78,$68,$60,$F0,$00   ; $46 F
        .byte $3C,$66,$C0,$C0,$CE,$66,$3E,$00   ; $47 G
        .byte $C6,$C6,$C6,$FE,$C6,$C6,$C6,$00   ; $48 H
        .byte $3C,$18,$18,$18,$18,$18,$3C,$00   ; $49 I
        .byte $1E,$0C,$0C,$0C,$CC,$CC,$78,$00   ; $4A J
        .byte $E6,$66,$6C,$78,$6C,$66,$E6,$00   ; $4B K
        .byte $F0,$60,$60,$60,$62,$66,$FE,$00   ; $4C L
        .byte $C6,$EE,$FE,$FE,$D6,$C6,$C6,$00   ; $4D M
        .byte $C6,$E6,$F6,$DE,$CE,$C6,$C6,$00   ; $4E N
        .byte $7C,$C6,$C6,$C6,$C6,$C6,$7C,$00   ; $4F O
        .byte $FC,$66,$66,$7C,$60,$60,$F0,$00   ; $50 P
        .byte $7C,$C6,$C6,$C6,$D6,$DE,$7C,$06   ; $51 Q
        .byte $FC,$66,$66,$7C,$6C,$66,$E6,$00   ; $52 R
        .byte $7C,$C6,$60,$38,$0C,$C6,$7C,$00   ; $53 S
        .byte $7E,$7E,$5A,$18,$18,$18,$3C,$00   ; $54 T
        .byte $C6,$C6,$C6,$C6,$C6,$C6,$7C,$00   ; $55 U
        .byte $C6,$C6,$C6,$C6,$C6,$6C,$38,$00   ; $56 V
        .byte $C6,$C6,$C6,$D6,$FE,$EE,$C6,$00   ; $57 W
        .byte $C6,$6C,$38,$38,$6C,$C6,$C6,$00   ; $58 X
        .byte $66,$66,$66,$3C,$18,$18,$3C,$00   ; $59 Y
        .byte $FE,$C6,$8C,$18,$32,$66,$FE,$00   ; $5A Z
        .byte $3C,$30,$30,$30,$30,$30,$3C,$00   ; $5B [
        .byte $C0,$60,$30,$18,$0C,$06,$02,$00   ; $5C \
        .byte $3C,$0C,$0C,$0C,$0C,$0C,$3C,$00   ; $5D ]
        .byte $10,$38,$6C,$C6,$00,$00,$00,$00   ; $5E ^
        .byte $00,$00,$00,$00,$00,$00,$00,$FF   ; $5F _
font8x8_end:
