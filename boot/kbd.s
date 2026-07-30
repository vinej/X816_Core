.p816
; ============================================================================
; kbd.s -- keyboard echo: read the SMC over bit-banged I2C and print.
;
; Path, end to end:
;   USB keyboard -> MiSTer hps_io ps2_key -> rtl/ps2_to_smc_bridge.sv
;     -> rtl/smc_x16.sv (I2C slave at $42) -> VIA1 PA[1:0] -> this code
;
; The SMC speaks the Commander X16 command set. Command $07 pops one IBM
; System/2 keycode from its FIFO, or returns 0 when empty. Bit 7 of the
; keycode is the release flag, so presses are what we act on.
;
; I2C is bit-banged on VIA1 port A, exactly as the X16 KERNAL does it:
;   PA0 = SDA, PA1 = SCL, both open-drain.
; ORA is left at 0, so a line is driven LOW by making it an output (DDRA bit
; = 1) and RELEASED by making it an input (DDRA bit = 0), where the pull-up
; takes it high. Never drive a line high -- that is what open-drain means, and
; the SMC drives SDA low itself during ACK and reads.
; ============================================================================

VIA1_PA        = $9F01          ; ORA / IRA
VIA1_DDRA      = $9F03

SDA            = $01            ; PA0
SCL            = $02            ; PA1

SMC_ADDR       = $42
SMC_GETKEY     = $07            ; pop one keycode, 0 if the FIFO is empty

; direct page (text.inc uses $10-$15)
i2c_byte       = $16
i2c_cnt        = $17
keycode        = $18
lastkey        = $19            ; last non-zero byte seen, latched for display
beat           = $1A            ; poll counter, proves the loop is alive

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

        lda     #<banner
        ldx     #>banner
        jsr     puts
        jsr     newline
        jsr     newline
        jsr     newline                 ; leave rows 0-2 for the diagnostic

        ; ORA = 0 once: from here, DDRA alone decides drive-low vs release.
        stz     VIA1_PA
        stz     VIA1_DDRA               ; both lines released (high)
        stz     lastkey
        stz     beat

poll:
        jsr     smc_getkey
        sta     keycode

        ; ---- diagnostic ----------------------------------------------------
        ; The instantaneous value is useless: polling runs ~1000x/second, so a
        ; keypress would flash for a millisecond. LATCH the last non-zero byte
        ; instead, and show a heartbeat so a stalled loop is distinguishable
        ; from a silent one.
        ;   left pair  = last non-zero keycode ("00" = none ever seen)
        ;   right pair = heartbeat, must be counting
        lda     keycode
        beq     @nolatch
        sta     lastkey
@nolatch:
        inc     beat

        lda     curx                    ; save the echo cursor
        pha
        lda     cury
        pha
        ldx     #0                      ; diagnostic lives at 0,0
        ldy     #0
        jsr     gotoxy
        lda     lastkey
        jsr     puthex
        lda     #' '
        jsr     putc
        lda     beat
        jsr     puthex
        pla                             ; restore it
        sta     cury
        pla
        sta     curx

        lda     keycode
        beq     poll                    ; 0 = FIFO empty
        bit     #$80
        bne     poll                    ; bit 7 set = key release, ignore

        ; keycode -> ASCII. Force the index to 8 bits: with M=1 and X=0, TAX
        ; would move the whole 16-bit C including the hidden B register.
        cmp     #64
        bcs     poll                    ; out of table range
        rep     #$20
        and     #$00FF
        tax
        sep     #$20
        lda     f:keymap,x
        beq     poll                    ; unmapped key
        cmp     #$0D
        bne     @notcr
        jsr     newline
        bra     poll
@notcr: jsr     putc
        bra     poll

banner: .byte   "X816 KEYBOARD - TYPE SOMETHING", 0

; ----------------------------------------------------------------------------
; smc_getkey -- I2C read of SMC register $07. Returns the keycode in A.
;
;   START, write $42<<1|W, write $07, STOP,
;   START, write $42<<1|R, read one byte with NACK, STOP.
;
; NOTE the full STOP between the command and the read -- NOT a repeated
; START. rtl/smc_x16.sv documents this: the real SMC firmware's I2C_Receive
; early-returns for one-byte writes, leaving the command armed for a separate
; read transaction. That is how the X16 KERNAL drives it, and a repeated
; START does not arm the command.
; ----------------------------------------------------------------------------
smc_getkey:
        jsr     i2c_start
        lda     #(SMC_ADDR << 1)        ; write
        jsr     i2c_write
        lda     #SMC_GETKEY
        jsr     i2c_write
        jsr     i2c_stop                ; full STOP, command stays armed
        jsr     i2c_start
        lda     #(SMC_ADDR << 1) | 1    ; read
        jsr     i2c_write
        jsr     i2c_read_nak
        pha
        jsr     i2c_stop
        pla
        rts

; ----------------------------------------------------------------------------
; I2C primitives. Open-drain via DDRA; ORA stays 0 throughout.
; ----------------------------------------------------------------------------
sda_low:
        lda     VIA1_DDRA
        ora     #SDA
        sta     VIA1_DDRA
        rts
sda_rel:
        lda     VIA1_DDRA
        and     #<~SDA
        sta     VIA1_DDRA
        rts
scl_low:
        lda     VIA1_DDRA
        ora     #SCL
        sta     VIA1_DDRA
        rts
scl_rel:
        lda     VIA1_DDRA
        and     #<~SCL
        sta     VIA1_DDRA
        rts

; START: SDA falls while SCL is high.
i2c_start:
        jsr     sda_rel
        jsr     scl_rel
        jsr     sda_low
        jsr     scl_low
        rts

; STOP: SDA rises while SCL is high.
i2c_stop:
        jsr     sda_low
        jsr     scl_rel
        jsr     sda_rel
        rts

; i2c_write -- send A, MSB first, then read (and discard) the ACK bit.
i2c_write:
        sta     i2c_byte
        lda     #8
        sta     i2c_cnt
@bit:   asl     i2c_byte                ; MSB -> carry
        bcc     @zero
        jsr     sda_rel
        bra     @clk
@zero:  jsr     sda_low
@clk:   jsr     scl_rel
        jsr     scl_low
        dec     i2c_cnt
        bne     @bit
        ; ACK slot: release SDA and give the slave one clock to pull it low
        jsr     sda_rel
        jsr     scl_rel
        jsr     scl_low
        rts

; i2c_read_nak -- read one byte MSB first, answer NACK, return it in A.
i2c_read_nak:
        stz     i2c_byte
        lda     #8
        sta     i2c_cnt
        jsr     sda_rel                 ; let the slave drive SDA
@bit:   asl     i2c_byte
        jsr     scl_rel
        lda     VIA1_PA
        and     #SDA
        beq     @zero
        inc     i2c_byte                ; shifted-in 1
@zero:  jsr     scl_low
        dec     i2c_cnt
        bne     @bit
        ; NACK: leave SDA released for one clock
        jsr     sda_rel
        jsr     scl_rel
        jsr     scl_low
        lda     i2c_byte
        rts

; ----------------------------------------------------------------------------
; IBM System/2 keycode -> ASCII, uppercase (the font has no lower case).
; Extracted from the translation table in rtl/smc_x16.sv, so it matches what
; the hardware actually emits rather than a guess at the layout.
; ----------------------------------------------------------------------------
keymap:
        .byte   0,   0,  '1', '2', '3', '4', '5', '6'    ;  0-7
        .byte   '7', '8', '9', '0', '-', '=', 0,   $08   ;  8-15  ($08 = backspace)
        .byte   $09, 'Q', 'W', 'E', 'R', 'T', 'Y', 'U'   ; 16-23  ($09 = tab)
        .byte   'I', 'O', 'P', '[', ']', '\', 0,   'A'   ; 24-31
        .byte   'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'   ; 32-39
        .byte   ';', 39,  0,   $0D, 0,   0,   'Z', 'X'   ; 40-47  (39 = quote, $0D = enter)
        .byte   'C', 'V', 'B', 'N', 'M', ',', '.', '/'   ; 48-55
        .byte   0,   0,   0,   0,   0,   ' ', 0,   0     ; 56-63

        .include "text.inc"
