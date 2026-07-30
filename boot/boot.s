.p816
; ============================================================================
; boot.s -- X816 boot ROM overlay, $00:FF00-$00:FFFF (256 bytes).
;
; This is the ONLY non-volatile code in the machine, and it exists for one
; structural reason: the 65816 always leaves RESET in EMULATION mode (E=1) and
; always fetches its reset vector from $00FFFC.  There is no native reset
; vector and no pin that changes this, so the top of bank 0 must be readable
; before any software has run.
;
; What it does, in order:
;   1. enters NATIVE mode and sets M=0/X=0 (full 16-bit registers)
;   2. establishes S, D and DBR for a flat bank-0 world
;   3. COPIES ITSELF into the RAM underneath the overlay, then drops the
;      overlay -- from that point bank 0 is 64 KB of uniform RAM, the vector
;      table lives in RAM and is patchable, and the machine is genuinely flat
;   4. if a program with the "X816" magic is present at PROG_BASE, jumps to
;      it and never returns -- the program runs in place from SDRAM
;   5. otherwise brings VERA up in 320x240 8bpp bitmap mode and paints
;      horizontal bands, a font-free proof that CPU, flat bus, I/O decode and
;      video all work, then parks in WAI
;
; Step 3 is the interesting one.  Writes to $FF00-$FFFF always reach RAM even
; while the overlay is mapped for reads (see boot_rom.sv / bank0_ram.sv), so
; the page can copy ROM-over-RAM at the SAME address and then unmap itself
; without disturbing the instruction stream -- the very next fetch comes from
; RAM holding identical bytes.
; ============================================================================

; ---- I/O map (bank $00, page $9F -- deliberately the same layout as the
;      Commander X16 so its VERA/VIA/YM register offsets port over unchanged)
VERA_ADDR_L   = $9F20
VERA_ADDR_M   = $9F21
VERA_ADDR_H   = $9F22
VERA_DATA0    = $9F23
VERA_CTRL     = $9F25
VERA_DC_VIDEO = $9F29
VERA_DC_HSCALE= $9F2A
VERA_DC_VSCALE= $9F2B
VERA_L0_CONFIG= $9F2D
VERA_L0_TILEB = $9F2F

; X816 system control (new; not an X16 register)
SYSCTL        = $9F80          ; bit 0: boot ROM overlay enable (1 at reset)

; Where a loaded program lives. Bank $01 is the first SDRAM bank -- bank $00
; is BRAM and holds the direct page, the stack and this stub, so a load must
; not land there. The RTL's HPS loader adds this base to the file offset, so
; a program links at PROG_BASE+4 and loads from offset 0.
PROG_BASE     = $010000
; Magic at PROG_BASE is the four bytes "X816"; the entry point is PROG_BASE+4.

.segment "BOOT"
; ----------------------------------------------------------------------------
reset:
        sei
        clc
        xce                     ; E=0 -> NATIVE mode
        rep     #$30            ; M=0, X=0 -> 16-bit A and 16-bit X/Y
.a16
.i16
        lda     #$7FFF
        tcs                     ; stack at the top of the first 32K of bank 0
        lda     #$0000
        tcd                     ; direct page = $0000
        phk
        plb                     ; DBR = PBR = $00

; ---- copy this page into the RAM beneath it, then unmap the overlay --------
        ldx     #$0000
@copy:  lda     $FF00,x         ; reads ROM  (overlay still mapped)
        sta     $FF00,x         ; writes RAM (always goes underneath)
        inx
        inx                     ; 16-bit A moves two bytes per pass
        cpx     #$0100
        bne     @copy

        sep     #$20
.a8
        stz     SYSCTL          ; overlay off -- bank 0 is now uniform RAM

; ---- hand over to a loaded program, if there is one ------------------------
; Programs live at PROG_BASE in SDRAM, not bank $00, so a load cannot trample
; the direct page, the stack or this stub. The four-byte magic distinguishes
; "a program was loaded" from "SDRAM powered up as noise" -- bank $00 is BRAM
; and comes up zeroed, but banks $01+ do not.
;
; Nothing is copied down: the program runs in place from SDRAM, which is the
; normal case for a flat machine and exercises the CPU stall path.
        lda     PROG_BASE+0
        cmp     #'X'
        bne     no_prog
        lda     PROG_BASE+1
        cmp     #'8'
        bne     no_prog
        lda     PROG_BASE+2
        cmp     #'1'
        bne     no_prog
        lda     PROG_BASE+3
        cmp     #'6'
        bne     no_prog
        jml     PROG_BASE+4     ; long jump: sets PBR, program owns the machine

; ---- nothing loaded: paint the bring-up bands ------------------------------
no_prog:
        rep     #$20
.a16
        jsr     vera_init
        jsr     paint

halt:   wai                     ; native WAI; the '816 core implements it
        bra     halt

; ----------------------------------------------------------------------------
; VERA: layer 0, 320x240, 8bpp bitmap, data at VRAM $00000.
; ----------------------------------------------------------------------------
vera_init:
        sep     #$20
.a8
        stz     VERA_CTRL       ; ADDRSEL=0, DCSEL=0
        lda     #$11            ; DC_VIDEO: VGA output (1) + layer 0 enable ($10)
        sta     VERA_DC_VIDEO
        lda     #$40            ; 64 = half scale -> 320 active pixels across
        sta     VERA_DC_HSCALE
        sta     VERA_DC_VSCALE  ; and 240 down
        lda     #$07            ; L0_CONFIG: bitmap mode ($04) + 8bpp ($03)
        sta     VERA_L0_CONFIG
        stz     VERA_L0_TILEB   ; bitmap base $00000, 320-wide
        rep     #$20
.a16
        rts

; ----------------------------------------------------------------------------
; Paint 240 lines x 320 pixels, colour = line number.  Horizontal bands in the
; default palette: unmistakable, and needs no font in VRAM.
; ----------------------------------------------------------------------------
paint:
        sep     #$20
.a8
        stz     VERA_CTRL       ; select ADDR port 0
        stz     VERA_ADDR_L
        stz     VERA_ADDR_M
        lda     #$10            ; increment = 1, VRAM addr[19:16] = 0
        sta     VERA_ADDR_H

        ldy     #240
@line:  ldx     #320
@px:    tya                     ; A is 8-bit: takes the low byte of Y
        sta     VERA_DATA0
        dex
        bne     @px
        dey
        bne     @line

        rep     #$20
.a16
        rts

; ----------------------------------------------------------------------------
; Unhandled interrupts: park rather than run off into RAM.
; ----------------------------------------------------------------------------
trap:   rti

; ----------------------------------------------------------------------------
; 65816 NATIVE-mode vectors.  Once the overlay is dropped these sit in RAM at
; the same addresses, so an OS can repoint them by plain stores.
; ----------------------------------------------------------------------------
.segment "VECT816"              ; $FFE4
        .addr   trap            ; $FFE4 COP
        .addr   trap            ; $FFE6 BRK
        .addr   trap            ; $FFE8 ABORT
        .addr   trap            ; $FFEA NMI
        .addr   trap            ; $FFEC (reserved)
        .addr   trap            ; $FFEE IRQ

; ----------------------------------------------------------------------------
; Emulation-mode vectors.  Only RESET is ever taken here in normal operation --
; the CPU is in native mode from the fourth instruction onward.
; ----------------------------------------------------------------------------
.segment "VECTORS"              ; $FFF4
        .addr   trap            ; $FFF4 COP
        .addr   trap            ; $FFF6 (reserved)
        .addr   trap            ; $FFF8 ABORT
        .addr   trap            ; $FFFA NMI
        .addr   reset           ; $FFFC RESET  <-- the one the silicon forces
        .addr   trap            ; $FFFE IRQ/BRK
