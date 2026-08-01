`timescale 1ns/1ps
// ============================================================================
// P65C816 NATIVE-mode IRQ trampoline test under X16-shaped stalls -- X816
// port of x16_mister/sim816.  DUT is X816's p65c816_flat_wrap; decode is
// addr[15:0] with a bank-0 qualifier (everything in these programs is bank 0).
//
// Runs irqnat.s (faithful R49 c816_irqb -> trampoline -> emu handler ->
// 16-bit unwind path) against:
//   * a fake VERA: $9F27 ISR, bit0 = level IRQ, cleared by writing 1
//   * the real VERA read-stall shape (vera_read_stall >= 2 to proceed) --
//     x816.sv carries the same stall verbatim
//   * an optional LFSR random stall on top (STALL_ON=1, ~25%)
//
// Storm signature: stack below $01D0 (nesting), emu-vector fetches ($FFFE,
// evec != 0), or cnt (completed handlers) not advancing.
// ============================================================================
module tb_native #(
    parameter         HEXFILE    = "irqnat.hex",  // irqnat = hooked-cinv
                                                  // irqdef = DEFAULT path
    parameter integer STALL_ON   = 1,
    parameter integer IRQ_PERIOD = 3000     // enabled-cycles between VSYNCs
);
    reg clk = 0; always #5 clk = ~clk;
    reg res_n = 0;

    wire        r_w_n, sync;
    wire [23:0] addr24;
    wire [7:0]  dout;
    wire [23:0] pc;
    reg  [7:0]  din;

    wire [15:0] addr = addr24[15:0];
    wire        b0   = (addr24[23:16] == 8'h00);

    // ---- LFSR stall (~25% when STALL_ON) ----
    reg [15:0] lfsr = 16'hACE1;
    always @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    wire lfsr_en = (STALL_ON != 0) ? (lfsr[1] | lfsr[0]) : 1'b1;

    // ---- VERA read stall, verbatim shape from x816.sv ----
    wire vera_cs   = b0 & (addr[15:5] == 11'b10011111001);   // $9F20-$9F3F
    wire vera_read = vera_cs & r_w_n;
    reg [1:0] vera_read_stall = 0;
    always @(posedge clk or negedge res_n)
        if (!res_n) vera_read_stall <= 0;
        else if (vera_read) begin if (vera_read_stall != 2'd3) vera_read_stall <= vera_read_stall + 2'd1; end
        else vera_read_stall <= 0;
    wire cpu_rdy_base = (~vera_read | (vera_read_stall >= 2'd2));

    wire enable = cpu_rdy_base & lfsr_en;

    // ---- fake VERA ISR: level IRQ until handler writes 1 to clear ----
    reg        isr = 0;
    integer    vsync_cnt = 0;
    reg        irq_armed = 0;
    always @(posedge clk or negedge res_n) begin
        if (!res_n) begin isr <= 0; vsync_cnt <= 0; end
        else begin
            if (irq_armed) begin
                if (enable) begin
                    vsync_cnt <= vsync_cnt + 1;
                    if (vsync_cnt >= IRQ_PERIOD) begin vsync_cnt <= 0; isr <= 1'b1; end
                end
                // handler write: $9F27 with bit0 set clears the IRQ
                if (enable && ~r_w_n && b0 && addr == 16'h9F27 && dout[0]) isr <= 1'b0;
            end
        end
    end
    wire irq_n = ~isr;

    // ---- memory ----
    reg [7:0] ram [0:32767];
    reg [7:0] rom [0:8191];
    integer i;
    initial begin
        $readmemh(HEXFILE, rom);
        for (i=0;i<32768;i=i+1) ram[i]=0;
    end
    always @(*) begin
        if      (b0 && addr == 16'h9F27) din = {7'd0, isr};
        else if (vera_cs)                din = 8'h00;
        else if (b0 && addr < 16'h8000)  din = ram[addr[14:0]];
        else if (b0 && addr >= 16'hE000) din = rom[addr[12:0]];
        else                             din = 8'h00;
    end
    always @(posedge clk) if (enable && ~r_w_n && b0 && addr < 16'h8000) ram[addr[14:0]] <= dout;

    // ---- DUT ----
    p65c816_flat_wrap dut(.clk(clk), .enable(enable), .res_n(res_n), .irq_n(irq_n),
        .nmi_n(1'b1), .abort_n(1'b1), .r_w_n(r_w_n), .sync(sync), .addr(addr24),
        .din(din), .dout(dout), .pc(pc));

    // ---- stack / vector monitors ----
    reg [15:0] last_stack_addr = 0, min_stack_addr = 16'hFFFF;
    always @(posedge clk)
        if (enable && ~r_w_n && b0 && addr[15:8]==8'h01) begin
            last_stack_addr <= addr;
            if (addr < min_stack_addr) min_stack_addr <= addr;
        end

    reg [15:0] prev_addr = 0;
    integer nat_irqn = 0, emu_vecn = 0;
    reg storm = 0;
    always @(posedge clk) begin
        if (enable && r_w_n && b0 && addr==16'hFFEE && prev_addr!=16'hFFEE) begin
            nat_irqn = nat_irqn + 1;
            if (nat_irqn <= 8 || (nat_irqn % 20)==0)
                $display("[NIRQ %0d] t=%0t stack=%04x cnt=%02x minstk=%04x",
                         nat_irqn, $time, last_stack_addr, ram[0], min_stack_addr);
        end
        if (enable && r_w_n && b0 && addr==16'hFFFE && prev_addr!=16'hFFFE) begin
            emu_vecn = emu_vecn + 1;
            $display("[EVEC %0d] t=%0t *** EMULATION VECTOR FETCH (the monitor path on HW) ***", emu_vecn, $time);
        end
        if (last_stack_addr != 0 && last_stack_addr < 16'h01D0 && !storm) begin
            storm = 1;
            $display("[TB] *** STACK DESCENDING: %04x -- NESTING STORM ***", last_stack_addr);
        end
        if (enable) prev_addr <= addr;
    end

    initial begin
        $display("[TB] P65C816 (flat wrap) NATIVE trampoline + stalls: STALL_ON=%0d IRQ_PERIOD=%0d", STALL_ON, IRQ_PERIOD);
        repeat(20) @(posedge clk); res_n = 1;
        repeat(1500) @(posedge clk);    // let reset+XCE+CLI finish under stalls
        irq_armed = 1;
        repeat(120000) @(posedge clk);
        $display("[TB] done. native IRQs=%0d  emu-vector fetches=%0d  evec=%02x  cnt=%02x  hookd=%02x  min stack=%04x  %s",
                 nat_irqn, emu_vecn, ram[15], ram[0], ram[14], min_stack_addr,
                 (emu_vecn!=0 || min_stack_addr<16'h01D0) ? "*** FAIL (storm/monitor) ***" :
                 (nat_irqn==0) ? "*** FAIL (no IRQ taken) ***" :
                 (ram[14]!=0)  ? "*** FAIL (wrong cinv branch) ***" : "clean");
        $finish;
    end

    initial begin #15000000; $display("[TB] TIMEOUT (pc=%06x cnt=%02x)", pc, ram[0]); $finish; end
endmodule
