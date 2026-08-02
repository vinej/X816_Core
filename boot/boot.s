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
;   4. if the kernel firmware carries the "X816" magic at $F0:0000, jumps to
;      its entry ($F0:0004); else if a program with the magic sits at
;      PROG_BASE, jumps to that -- either way the code runs in place from
;      SDRAM (doc/KERNEL.md §7)
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

; The contract this stub is the far end of: where an image lives, what marks
; it as one, and where SYSCTL is. Generated from X816_core/tools/contract.py,
; which is also what x816.sv's PROG_BASE/FW_BASE are checked against --
; `python tools/contract.py --check`. Every value below used to be a literal
; here AND a localparam there AND a .equ in the runtime, agreeing by memory.
.include "x816_contract.inc"

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

; X816 system control (new; not an X16 register) is X816_SYSCTL, bit 0 =
; X816_SYSCTL_OVERLAY (boot ROM overlay enable, 1 at reset).
;
; Where a loaded program lives is X816_PROG_BASE. Bank $01 is the first SDRAM
; bank -- bank $00 is BRAM and holds the direct page, the stack and this stub,
; so a load must not land there. The RTL's HPS loader adds this base to the
; file offset, so a program links at X816_PROG_ENTRY and loads from offset 0.
;
; X816_FW_BASE is the kernel firmware region (doc/KERNEL.md §3): HPS-loaded
; as boot2.rom, write-protected by the core. Checked before X816_PROG_BASE.
; Magic at either base is the four bytes "X816"; the entry point is base+4.

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
        stz     X816_SYSCTL          ; overlay off -- bank 0 is now uniform RAM

; ---- hand over: kernel firmware first, then a loaded program ---------------
; Both bases are SDRAM: an absent image reads as power-up noise, and the
; four-byte magic is what tells a loaded image from that noise (bank $00 is
; BRAM and comes up zeroed; banks $01+ do not). The kernel wins when both are
; present (doc/KERNEL.md §7 step 3); the PROG_BASE path is the pre-kernel
; fallback every conformance image boots through, and stays.
;
; Nothing is copied down: kernel and program alike run in place from SDRAM,
; which is the normal case for a flat machine and exercises the CPU stall
; path. The loops compare against this ROM's own copy of the string, so the
; bytes checked and the bytes shipped cannot drift.
        ldx     #0
@fwchk: lda     f:X816_FW_BASE,x
        cmp     magic,x
        bne     @no_fw
        inx
        cpx     #4
        bne     @fwchk
        jml     X816_FW_ENTRY       ; kernel owns the machine

@no_fw: ldx     #0
@pgchk: lda     f:X816_PROG_BASE,x
        cmp     magic,x
        bne     no_prog
        inx
        cpx     #4
        bne     @pgchk
        jml     X816_PROG_ENTRY     ; long jump: sets PBR, program owns the machine

magic:  .byte   "X816"

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
