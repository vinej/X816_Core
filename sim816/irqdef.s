.setcpu "65816"
; ============================================================================
; NATIVE-mode DEFAULT-PATH IRQ test -- the path the R49 KERNAL takes when
; cinv ($0314) is UNHOOKED (points at the ROM `key` handler), i.e. during
; normal boot and all of BASIC.  This is the path the old sim816 tests never
; covered (irqnat.s tested the hooked-cinv trampoline through emulation
; mode); the HW "IRQ storm -> monitor" happened during normal operation, so
; it happened HERE.
;
; Faithful to kernal/x16/65c816/interrupt.s + cbm/irq.s:
;   c816_irqb: c816_interrupt_impl -> jmp (inirq)
;   nnirq:     intr_common_impl cinv, key, irq_emulated_impl
;                = stack check, phx, LDA cinv / CMP #key / BNE hooked
;                -> SEP #$30 ; JMP irq_emulated_impl        (STAYS NATIVE!)
;   irq_emulated_impl: irq_impl work ; ack VERA ;
;                jmp __interrupt_65c816_native_kernal_impl_ret
;   ..._kernal_impl_ret: REP #$31 ; PLA;TCS ; PLY;PLX;PLA ; RTI -> nret
;   __irq_native_ret (nret): PLA->rom_bank; PLB; PLD; PLA;XBA;PLA;XBA; RTI
;
; Storm signature (same as irqnat): stack below $01D0, emulation-vector
; fetches ($FFFE, evec != 0), cnt not advancing, hookd != 0 (wrong branch).
; ============================================================================

cnt       = $00       ; completed handler count
evec      = $0F       ; emulation-vector trap marker (MUST stay 0)
rom_bank  = $01       ; the X16's zp ROM-bank register (dummy here)
hookd     = $0E       ; set if the hooked-cinv branch is taken (MUST stay 0)
stack_ptr = $10       ; kernal stack_ptr variable
cinv_vec  = $0314     ; CBM IRQ RAM vector
inirq_vec = $0316     ; KERNAL native-IRQ RAM vector (inirq kvar)

VERA_ISR  = $9F27

.segment "CODE"
reset:                ; 65C816 resets in EMULATION mode
        sei
        ldx #$ff
        txs
        stz cnt
        stz evec
        stz hookd
        stz rom_bank
        lda #<key     ; cinv = key  ==> the DEFAULT, unhooked state
        sta cinv_vec
        lda #>key
        sta cinv_vec+1
        lda #<nnirq   ; inirq = nnirq (KERNAL init state)
        sta inirq_vec
        lda #>nnirq
        sta inirq_vec+1
        clc
        xce           ; -> NATIVE mode (like the R49 ROM)
        cli
main:
        wai           ; KERNAL-style idle
        nop
        rep #$30      ; stress: 16-bit register activity in the main loop
.A16
.I16
        inx
        dex
        sep #$30
.A8
.I8
        jmp main

; ---------------- native IRQ entry ($FFEE) = c816_irqb ---------------------
.A8
.I8
nirq:
        ; ---- c816_interrupt_impl (verbatim shape) ----
        rep #$30
.A16
.I16
        pha
        phd
        lda #$0000
        tcd
        sep #$20
.A8
        phb
        lda #$00
        pha
        plb
        lda rom_bank
        pha
        stz rom_bank
        phk
        pea nret          ; __irq_native_ret frame
        php
        rep #$20
.A16
        lda $05,S
        pha
        phx
        phy
        jmp (inirq_vec)   ; KERNAL dispatch through the inirq RAM vector

; ---------------- nnirq: intr_common_impl cinv, key, irq_emulated_impl -----
.A16
.I16
nnirq:
        tsx
        tsc
        and #$FF00
        cmp #$0100
        beq :+
        lda stack_ptr
        tcs
:       phx               ; old stack pointer onto (possibly new) stack
        lda cinv_vec      ; 16-bit load of the cinv vector
        cmp #key
        bne hooked
        sep #$30          ; ==== THE DEFAULT PATH: stay NATIVE, 8-bit regs ====
.A8
.I8
        jmp irq_emulated

; hooked-cinv branch (the irqnat.s trampoline) -- must NOT be taken here
.A16
.I16
hooked:
        sep #$30
.A8
.I8
        inc hookd         ; flag the wrong branch, then behave like a handler
        jmp irq_emulated

; -------- irq_emulated_impl (native mode, 8-bit, cbm/irq.s irq_impl) -------
.A8
.I8
irq_emulated:
        jsr subwork       ; stand-ins for ps2data_fetch/mouse_scan/... jsr's
        jsr subwork
        lda VERA_ISR      ; STALLED VERA read (like the real ISR poll)
        and #$01
        lda #$01
        sta VERA_ISR      ; ack VERA VBLANK (clears the level IRQ)
        inc cnt
        jmp kret

subwork:                  ; a little stack + zp traffic like the real scans
        pha
        phx
        lda cnt
        eor #$5A
        sta $20
        plx
        pla
        rts

; ------- __interrupt_65c816_native_kernal_impl_ret (NO xce: stays native) --
.A8
.I8
kret:
        rep #$31
.A16
.I16
        pla               ; old stack pointer
        tcs               ; restore it
        ply
        plx
        pla
        rti               ; pops php'd P + pea'd nret + phk'd bank (native)

; ---------------------- __irq_native_ret (final unwind) --------------------
.A8
.I16
nret:
        pla
        sta rom_bank
        plb
        pld
        pla
        xba
        pla
        xba
        rti               ; pops the hardware native frame -> main

; ---------------- emu-mode `key` handler (address target only) -------------
; cinv POINTS here (that is what makes the default branch match); it is only
; executed if the hooked path ran, which is itself an error in this test.
.A8
.I8
key:
        inc hookd
        ply
        plx
        pla
        rti

; ------------------------------- traps -------------------------------------
.A8
.I8
etrap:                    ; any emulation-vector or unexpected native vector
        inc evec
        rti

.segment "VECT816"        ; native vectors $FFE4-$FFEF
        .word etrap       ; COP    $FFE4
        .word etrap       ; BRK    $FFE6
        .word etrap       ; ABORT  $FFE8
        .word etrap       ; NMI    $FFEA
        .word $0000       ; (none) $FFEC
        .word nirq        ; IRQ    $FFEE

.segment "VECTORS"        ; emulation vectors $FFFA-$FFFF
        .word etrap       ; NMI
        .word reset       ; RESET
        .word etrap       ; IRQ/BRK -- firing here in native mode = THE BUG
