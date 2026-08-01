.setcpu "65816"
; ============================================================================
; NATIVE-mode IRQ trampoline test, faithful to the R49 KERNAL 65C816 path
; (kernal/x16/65c816/interrupt.s: c816_irqb -> c816_interrupt_impl ->
;  nnirq/intr_common_impl -> SEC;XCE -> emu-mode cinv handler -> RTI-chain ->
;  __interrupt_65c816_native_ret (REP #$31; PLA; TCS...) -> fake-frame RTI ->
;  __irq_native_ret -> hardware RTI).
;
; The TB provides a fake VERA: $9F27 = ISR (bit0 = VSYNC, level IRQ until the
; handler writes 1 to clear), and VERA-register reads stall the CPU like the
; real x16.sv cpu_rdy (vera_read_stall), optionally + random LFSR stalls.
;
; Storm signature to watch: stack descending below $01F0, emu-vector fetches
; ($FFFE, counts in evec), cnt not advancing.
; ============================================================================

cnt       = $00       ; completed handler count
evec      = $0F       ; emulation-vector trap marker (MUST stay 0)
rom_bank  = $01       ; the X16's zp ROM-bank register (dummy here)
stack_ptr = $10       ; kernal stack_ptr variable (unused: stack stays in page 1)
cinv_vec  = $0314     ; CBM IRQ RAM vector, like the real KERNAL

VERA_ISR  = $9F27

.segment "CODE"
reset:                ; 65C816 resets in EMULATION mode
        sei
        ldx #$ff
        txs
        stz cnt
        stz evec
        stz rom_bank
        lda #<handler
        sta cinv_vec
        lda #>handler
        sta cinv_vec+1
        clc
        xce           ; -> NATIVE mode (like the R49 ROM)
        cli
main:
        wai           ; KERNAL-style idle: wait for interrupt (untested corner!)
        nop
        jmp main      ; IRQ interrupts this loop

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
        pea nret          ; fake RTI-style frame -> __irq_native_ret
        php
        rep #$20
.A16
        lda $05,S
        pha
        phx
        phy
        ; ---- nnirq / intr_common_impl (hooked-cinv path) ----
.I16
        tsx
        tsc
        and #$FF00
        cmp #$0100
        beq :+
        lda stack_ptr
        tcs
:       phx               ; old stack pointer onto (possibly new) stack
        pea tret          ; __interrupt_65c816_native_ret
        sec
        xce               ; -> EMULATION mode, mid-interrupt
.A8
.I8
        clc
        php
        lda $0B,S         ; rebuild 65C02-style frame from the native one
        pha
        lda $09,S
        pha
        lda $07,S
        pha
        jmp (cinv_vec)    ; dispatch like the KERNAL

; ---------------- emu-mode handler (the CBM cinv handler) ------------------
.A8
.I8
handler:
        lda VERA_ISR      ; STALLED VERA read (like reading the real ISR)
        and #$01
        sta VERA_ISR      ; clear the level IRQ source
        inc cnt
        ply               ; CBM epilogue: discard the 3 rebuilt frame bytes...
        plx
        pla
        rti               ; ...and "return" -> pops php'd P + pea'd tret

; ------------- __interrupt_65c816_native_ret (16-bit unwind) ---------------
.A8
.I8
tret:
        clc
        xce               ; back to NATIVE mode
        rep #$31
.A16
.I16
        pla               ; old stack pointer
        tcs               ; restore it (discards trampoline leftovers)
        ply
        plx
        pla
        rti               ; pops the FAKE frame -> nret (still native)

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
