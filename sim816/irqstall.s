.setcpu "65C02"                 ; 65C816 resets in emulation mode = 65C02

; P65C816 stall-storm reproduction program.  Emulation mode, IRQ_N held low by
; the TB, cpu_rdy (RDY_IN) randomly stalled ~25% by the TB.  Expected healthy
; behaviour: each IRQ pushes a 3-byte frame at $01FD-$01FF, handler runs, RTI
; pops it -- the stack NEVER descends.  The bug: under stalls the entry
; re-triggers (nesting) and the stack walks down to $0100.

.zeropage
cnt:    .res 1

.segment "CODE"
reset:
        sei
        ldx #$ff
        txs
        stz cnt
        cli                     ; I=0 -> IRQ can be taken
main:
        nop
        nop
        jmp main                ; IRQ interrupts this loop

irq:
        inc cnt                 ; side effect so we can see it ran
        rti

.segment "VECTORS"              ; placed at $FFFA
        .word irq               ; NMI   $FFFA
        .word reset             ; RESET $FFFC
        .word irq               ; IRQ/BRK $FFFE
