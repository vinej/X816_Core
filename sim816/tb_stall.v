`timescale 1ns/1ps
// ============================================================================
// P65C816 stall-IRQ-storm testbench -- X816 port of x16_mister/sim816.
//
// Identical structure to the upstream testbench; the DUT is X816's
// p65c816_flat_wrap (24-bit address bus, no separate rdy pin -- `enable` IS
// the stall input).  The memory decode works on addr[15:0] qualified by a
// bank-0 check, which is exact for this program: everything lives in bank 0.
//
//   STALL_ON=0 : enable=1 always            -> expect clean IRQ/RTI forever
//   STALL_ON=1 : enable low ~25% of cycles  -> the X16's historical nesting
//                storm (stack pushes walking down from $01FD toward $0100)
//                must NOT reproduce on the fixed core
//
// Instrumentation: every IRQ/BRK vector fetch prints the pushed P and the
// stack address; a monotonically-descending stack across entries = NESTING.
// A cycle trace window can be enabled around a chosen entry (TRACE_FROM).
// ============================================================================
module tb_stall #(
    parameter integer STALL_ON   = 1,
    parameter integer TRACE_FROM = 0    // >0: print bus trace from that IRQ entry on (a few hundred cycles)
);
    reg clk = 0; always #5 clk = ~clk;
    reg res_n = 0;
    reg irq_n = 1;

    wire        r_w_n, sync;
    wire [23:0] addr24;
    wire [7:0]  dout;
    wire [23:0] pc;
    reg  [7:0]  din;

    wire [15:0] addr = addr24[15:0];
    wire        b0   = (addr24[23:16] == 8'h00);

    // ---- LFSR stall generator (~25% stall when STALL_ON) ----
    reg [15:0] lfsr = 16'hACE1;
    always @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    wire enable = (STALL_ON != 0) ? (lfsr[1] | lfsr[0]) : 1'b1;   // 00 -> stall (~25%)

    // ---- memory ----
    reg [7:0] ram [0:32767];    // $0000-$7FFF
    reg [7:0] rom [0:8191];     // $E000-$FFFF
    integer i;
    initial begin
        $readmemh("irqstall.hex", rom);
        for (i=0;i<32768;i=i+1) ram[i]=0;
    end

    always @(*) begin
        if      (b0 && addr < 16'h8000)  din = ram[addr[14:0]];
        else if (b0 && addr >= 16'hE000) din = rom[addr[12:0]];
        else                             din = 8'h00;
    end
    // memory honours the stall: commit writes only on enabled cycles
    always @(posedge clk) if (enable && ~r_w_n && b0 && addr < 16'h8000) ram[addr[14:0]] <= dout;

    // ---- DUT ----
    p65c816_flat_wrap dut(.clk(clk), .enable(enable), .res_n(res_n), .irq_n(irq_n),
        .nmi_n(1'b1), .abort_n(1'b1), .r_w_n(r_w_n), .sync(sync), .addr(addr24),
        .din(din), .dout(dout), .pc(pc));

    // ---- capture pushed status byte (last stack write before vector fetch) ----
    reg [7:0]  last_stack_wr   = 8'hxx;
    reg [15:0] last_stack_addr = 0;
    reg [15:0] min_stack_addr  = 16'hFFFF;
    always @(posedge clk)
        if (enable && ~r_w_n && b0 && addr[15:8]==8'h01) begin
            last_stack_wr   <= dout;
            last_stack_addr <= addr;
            if (addr < min_stack_addr) min_stack_addr <= addr;
        end

    // ---- vector-fetch detector (one count per interrupt entry) ----
    reg [15:0] prev_addr = 0;
    integer irqn = 0;
    reg storm = 0;
    always @(posedge clk) begin
        if (enable && r_w_n && b0 && addr==16'hFFFE && prev_addr!=16'hFFFE) begin
            irqn = irqn + 1;
            if (irqn <= 12 || (irqn % 50) == 0)
                $display("[IRQ %0d] t=%0t pushed P=%02x I=%b @stack=%04x cnt=%02x",
                         irqn, $time, last_stack_wr, last_stack_wr[2], last_stack_addr, ram[0]);
            // healthy: every frame lives at $01FD-$01FF. Anything below $01F0 = nesting.
            if (last_stack_addr != 0 && last_stack_addr < 16'h01F0 && !storm) begin
                storm = 1;
                $display("[TB] *** NESTING STORM: stack frame at %04x (entry %0d) ***", last_stack_addr, irqn);
            end
        end
        if (enable) prev_addr <= addr;
    end

    // ---- optional cycle trace around a chosen entry ----
    integer trace_cycles = 0;
    always @(posedge clk) begin
        if (TRACE_FROM > 0 && irqn >= TRACE_FROM && trace_cycles < 400) begin
            trace_cycles = trace_cycles + 1;
            $display("[TR] t=%0t en=%b rwn=%b addr=%06x d=%02x sync=%b",
                     $time, enable, r_w_n, addr24, r_w_n ? din : dout, sync);
        end
    end

    initial begin
        $display("[TB] P65C816 (flat wrap) stall-IRQ storm test: STALL_ON=%0d", STALL_ON);
        repeat(20) @(posedge clk); res_n = 1;
        repeat(800) @(posedge clk);   // let reset handler run (stalls make it slower)
        irq_n = 0;                    // held low: continuous IRQs separated by RTIs
        repeat(30000) @(posedge clk);
        $display("[TB] done. IRQ entries=%0d  min stack addr=%04x  cnt=%02x  %s",
                 irqn, min_stack_addr, ram[0],
                 (min_stack_addr < 16'h01F0) ? "*** STORM (nesting) ***" : "clean (no nesting)");
        if (irqn==0) $display("[TB] *** NO IRQ TAKEN -- check CLI / irq path ***");
        $finish;
    end

    initial begin #4000000; $display("[TB] TIMEOUT (pc=%06x)", pc); $finish; end
endmodule
