.p816
; ============================================================================
; sdtest.s -- SD block device conformance test.
;
;   GREEN    all tests passed
;   RED      test 1: no card present
;   YELLOW   test 2: READBUF -- wrong data through the $9F8A window
;   BLUE     test 3: READ (DMA) -- wrong data in memory
;   MAGENTA  test 4: multi-block DMA -- LBA or address failed to advance
;   CYAN     test 5: WRITE -- what came back is not what went out
;   WHITE    test 6: a read past the end of the image did not report an error
;
; Runs as a LOADABLE program at $01:0000, not a boot overlay, so it needs no
; bitstream rebuild once the RTL is in: build it like hello.s and load it the
; usual way.
;
; Needs boot/sdtest.img mounted (OSD "Mount SD", or -sdcard for the emulator).
; Generate it with boot/mksdtest.py. Every block carries a pattern derived
; from its own LBA -- byte i of block n is (n*7 + i*3 + 1) & $FF -- so reading
; the wrong block fails, not just reading the wrong bytes. A test that only
; checked "did I get 512 bytes" would pass while fetching block 0 every time.
;
; The device is documented in doc/MEMORY_MAP.md; the RTL is rtl/sd_block.sv
; and the emulator's counterpart is src/sdblock.c in X816_Emulator.
; ============================================================================

SD_LBA0        = $9F81
SD_LBA1        = $9F82
SD_LBA2        = $9F83
SD_LBA3        = $9F84
SD_MEM0        = $9F85
SD_MEM1        = $9F86
SD_MEM2        = $9F87
SD_COUNT       = $9F88
SD_CMD         = $9F89          ; write only
SD_STATUS      = $9F8A          ; read only -- see rtl/sd_block.sv
SD_DATA        = $9F8C          ; $9F8B is a mandatory gap below it

CMD_READ       = 1
CMD_WRITE      = 2
CMD_READBUF    = 3
CMD_RESET      = 4

ST_ERROR       = $02
ST_PRESENT     = $80

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

; Landing zone for DMA: bank $02, well clear of this program at $01:xxxx.
DMA_BANK       = $02
DMA_ADDR       = $020000

colour         = $10
tmp            = $11
expect         = $12

.segment "MAGIC"
        .byte   "X816"

.segment "CODE"
start:
        sep     #$30                    ; 8-bit A/X/Y throughout
.a8
.i8

; ---- test 1: is a card mounted? --------------------------------------------
        lda     SD_STATUS
        and     #ST_PRESENT
        bne     t1_ok
        lda     #1
        jmp     fail
t1_ok:

; ---- test 2: READBUF, read back through the data window --------------------
; Block 3 rather than block 0: block 0 is what a device that ignores the LBA
; would hand back, so using it would hide exactly the bug worth catching.
        jsr     set_lba3
        lda     #CMD_READBUF
        sta     SD_CMD
        lda     SD_STATUS
        and     #ST_ERROR
        beq     t2_read
        lda     #2
        jmp     fail
t2_read:
        lda     #CMD_RESET              ; rewind the window
        sta     SD_CMD
        ; expected byte i = (3*7 + i*3 + 1) = 22 + i*3
        lda     #22
        sta     expect
        ldx     #0
t2_loop:
        lda     SD_DATA                 ; auto-increments
        cmp     expect
        beq     t2_next
        lda     #2
        jmp     fail
t2_next:
        lda     expect
        clc
        adc     #3
        sta     expect
        inx
        bne     t2_loop                 ; 256 bytes is a sufficient sample
        bra     t3

; ---- test 3: READ, one block straight into memory --------------------------
t3:
        jsr     set_lba3
        lda     #<DMA_ADDR
        sta     SD_MEM0
        lda     #>DMA_ADDR
        sta     SD_MEM1
        lda     #^DMA_ADDR
        sta     SD_MEM2
        lda     #1
        sta     SD_COUNT
        lda     #CMD_READ
        sta     SD_CMD                  ; the CPU is frozen until this completes
        lda     SD_STATUS
        and     #ST_ERROR
        beq     t3_check
        lda     #3
        jmp     fail
t3_check:
        lda     #22
        sta     expect
        ldx     #0
t3_loop:
        lda     f:DMA_ADDR,x
        cmp     expect
        beq     t3_next
        lda     #3
        jmp     fail
t3_next:
        lda     expect
        clc
        adc     #3
        sta     expect
        inx
        bne     t3_loop

; ---- test 4: multi-block DMA advances both LBA and address -----------------
; Four blocks from LBA 8. Checking the FIRST byte of the LAST block proves the
; LBA advanced (content) and the destination advanced (position) -- one wrong
; without the other still fails.
        lda     #8
        sta     SD_LBA0
        stz     SD_LBA1
        stz     SD_LBA2
        stz     SD_LBA3
        lda     #<DMA_ADDR
        sta     SD_MEM0
        lda     #>DMA_ADDR
        sta     SD_MEM1
        lda     #^DMA_ADDR
        sta     SD_MEM2
        lda     #4
        sta     SD_COUNT
        lda     #CMD_READ
        sta     SD_CMD
        lda     SD_STATUS
        and     #ST_ERROR
        beq     t4_check
        lda     #4
        jmp     fail
t4_check:
        ; block 11 lands at DMA_ADDR + 3*512 = +$600; byte 0 = 11*7 + 1 = 78
        lda     f:DMA_ADDR+$600
        cmp     #78
        beq     t5
        lda     #4
        jmp     fail

; ---- test 5: WRITE, then read back ----------------------------------------
; Block 64 is scratch -- mksdtest.py leaves it patterned like the rest, and
; the test overwrites it, so re-running is idempotent.
t5:
        lda     #CMD_RESET
        sta     SD_CMD
        lda     #$A5                    ; fill the buffer with a walking value
        ldx     #0
t5_fill:
        sta     SD_DATA
        clc
        adc     #1
        inx
        bne     t5_fill
        ldx     #0
t5_fill2:
        sta     SD_DATA
        clc
        adc     #1
        inx
        bne     t5_fill2

        jsr     set_lba64
        lda     #CMD_WRITE
        sta     SD_CMD
        lda     SD_STATUS
        and     #ST_ERROR
        beq     t5_back
        lda     #5
        jmp     fail
t5_back:
        jsr     set_lba64
        lda     #CMD_READBUF
        sta     SD_CMD
        lda     #CMD_RESET
        sta     SD_CMD
        lda     #$A5
        sta     expect
        ldx     #0
t5_cmp:
        lda     SD_DATA
        cmp     expect
        beq     t5_next
        lda     #5
        jmp     fail
t5_next:
        inc     expect
        inx
        bne     t5_cmp

; ---- test 6: a read past the end of the image must report an error ---------
; Without this the device could "succeed" on every request and tests 2-5 would
; still pass, because they never ask for anything that is not there.
        lda     #$FF
        sta     SD_LBA0
        sta     SD_LBA1
        sta     SD_LBA2
        stz     SD_LBA3                 ; LBA $00FFFFFF -- far past any image
        lda     #CMD_READBUF
        sta     SD_CMD
        lda     SD_STATUS
        and     #ST_ERROR
        bne     all_ok
        lda     #6
        jmp     fail

all_ok:
        lda     #0
; ---- report ----------------------------------------------------------------
fail:
        tax
        ; f: -- the table is in bank $01 with the code, but DBR stays $00 so
        ; the I/O page is reachable. Plain absolute would read bank $00.
        ; This is the trap the core's README calls out for every program
        ; running outside bank $00, and it costs a black screen, not a wrong
        ; colour, because the byte fetched is whatever happens to be there.
        lda     f:colours,x
        sta     colour
        jsr     paint
halt:   wai
        bra     halt

colours:
        .byte   $05, $02, $07, $06, $04, $03, $01   ; green red yellow blue magenta cyan white

set_lba3:
        lda     #3
        sta     SD_LBA0
        stz     SD_LBA1
        stz     SD_LBA2
        stz     SD_LBA3
        rts

set_lba64:
        lda     #64
        sta     SD_LBA0
        stz     SD_LBA1
        stz     SD_LBA2
        stz     SD_LBA3
        rts

; ----------------------------------------------------------------------------
; paint -- fill a 320x240 8bpp bitmap with `colour`, as boot/vramtest.s does.
; ----------------------------------------------------------------------------
paint:
        stz     VERA_CTRL
        lda     #$11                    ; VGA output + layer 0 enable
        sta     VERA_DC_VIDEO
        lda     #$40                    ; half scale -> 320x240 active
        sta     VERA_DC_HSCALE
        sta     VERA_DC_VSCALE
        lda     #$07                    ; bitmap mode, 8bpp
        sta     VERA_L0_CONFIG
        stz     VERA_L0_TILEB
        stz     VERA_CTRL
        stz     VERA_ADDR_L
        stz     VERA_ADDR_M
        lda     #$10                    ; increment 1, addr[19:16] = 0
        sta     VERA_ADDR_H
        rep     #$10
.i16
        ldy     #240
@line:  ldx     #320
@px:    lda     colour
        sta     VERA_DATA0
        dex
        bne     @px
        dey
        bne     @line
        sep     #$10
.i8
        rts
