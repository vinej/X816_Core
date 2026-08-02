//============================================================================
// tb_switch_ram.v  --  the 256 KB switchable block, on the real RTL.
//
// The properties, in the order they matter:
//
//   1. FAST: the CPU port stores and returns bytes, at every lane of a word.
//      Lane coverage is the point -- a mapping that got byte 0 right and byte
//      3 wrong would pass any single-address test and corrupt one byte in
//      four of every program loaded.
//   2. FAST: a VERA write CANNOT reach the memory. This is the safety
//      property. In FAST mode VERA is still scanning out from its own 128 KB
//      and its bus is still moving; if any of that reached the block it would
//      overwrite the running program, and the symptom would be a program that
//      corrupts itself in proportion to screen activity.
//   3. VIDEO: the VERA port stores and returns 32-bit words, and the
//      per-nibble write enables mask correctly -- FX depends on those.
//   4. VIDEO: a CPU write CANNOT reach the memory. The mirror of 2.
//   5. The two views AGREE on layout: a byte the CPU wrote at address N is
//      the corresponding byte of the word VERA reads. Nothing depends on that
//      today, because a mode change is a cold boot and wipes the block -- but
//      a mapping that disagreed would be a silent trap for whoever assumed it
//      later.
//
// Checks 2 and 4 are the ones worth having. A block that works in both modes
// but does not ISOLATE them would pass 1, 3 and 5 and destroy a machine.
//
// WORDS is overridden to something small: the real array is 65,536 words and
// the lane arithmetic under test does not care how deep it is.
//============================================================================
`timescale 1ns / 1ps

module tb_switch_ram;

    localparam WORDS  = 64;
    localparam AWIDTH = 6;

    reg               fast_mode = 1'b1;
    reg               vera_clk = 1'b0;
    reg  [AWIDTH-1:0] vera_addr = 0;
    reg  [31:0]       vera_wrdata = 0;
    reg  [7:0]        vera_wrnibblesel = 8'h00;
    reg               vera_write = 1'b0;
    wire [31:0]       vera_rddata;

    reg               cpu_clk = 1'b0;
    reg               cpu_cs = 1'b0;
    reg               cpu_we = 1'b0;
    reg  [AWIDTH+1:0] cpu_addr = 0;
    reg  [7:0]        cpu_wrdata = 0;
    wire [7:0]        cpu_rddata;

    integer errors = 0;

    switch_ram #(.WORDS(WORDS), .AWIDTH(AWIDTH)) dut (
        .fast_mode(fast_mode),
        .vera_clk(vera_clk), .vera_addr(vera_addr), .vera_wrdata(vera_wrdata),
        .vera_wrnibblesel(vera_wrnibblesel), .vera_write(vera_write),
        .vera_rddata(vera_rddata),
        .cpu_clk(cpu_clk), .cpu_cs(cpu_cs), .cpu_we(cpu_we),
        .cpu_addr(cpu_addr), .cpu_wrdata(cpu_wrdata), .cpu_rddata(cpu_rddata)
    );

    // Deliberately different periods: the two owners are in different clock
    // domains on the real machine and the block must not care.
    always #5  cpu_clk  = ~cpu_clk;
    always #3  vera_clk = ~vera_clk;

    task check(input cond, input [8*64:1] what);
        begin
            if (!cond) begin
                $display("[TB] FAIL: %0s", what);
                errors = errors + 1;
            end else begin
                $display("[TB] ok:   %0s", what);
            end
        end
    endtask

    task cpu_write(input [AWIDTH+1:0] a, input [7:0] d);
        begin
            @(negedge cpu_clk);
            cpu_addr = a; cpu_wrdata = d; cpu_cs = 1'b1; cpu_we = 1'b1;
            @(posedge cpu_clk);
            @(negedge cpu_clk);
            cpu_cs = 1'b0; cpu_we = 1'b0;
        end
    endtask

    task cpu_read(input [AWIDTH+1:0] a, output [7:0] d);
        begin
            @(negedge cpu_clk);
            cpu_addr = a; cpu_cs = 1'b1; cpu_we = 1'b0;
            @(posedge cpu_clk);          // address registered here
            @(posedge cpu_clk);          // data valid after it
            d = cpu_rddata;
            @(negedge cpu_clk);
            cpu_cs = 1'b0;
        end
    endtask

    task vera_wr(input [AWIDTH-1:0] a, input [31:0] d, input [7:0] nib);
        begin
            @(negedge vera_clk);
            vera_addr = a; vera_wrdata = d; vera_wrnibblesel = nib;
            vera_write = 1'b1;
            @(posedge vera_clk);
            @(negedge vera_clk);
            vera_write = 1'b0; vera_wrnibblesel = 8'h00;
        end
    endtask

    task vera_rd(input [AWIDTH-1:0] a, output [31:0] d);
        begin
            @(negedge vera_clk);
            vera_addr = a;
            @(posedge vera_clk);
            @(negedge vera_clk);
            d = vera_rddata;
        end
    endtask

    integer i;
    reg [7:0]  b;
    reg [31:0] w;

    initial begin
        $display("[TB] switch_ram: %0d words, %0d KB at full size", WORDS, 256);

        // ---- 1: FAST -- the CPU port works at every lane -------------------
        fast_mode = 1'b1;
        for (i = 0; i < 8; i = i + 1)
            cpu_write(i[AWIDTH+1:0], 8'hA0 + i[7:0]);
        errors = errors;
        for (i = 0; i < 8; i = i + 1) begin
            cpu_read(i[AWIDTH+1:0], b);
            if (b !== (8'hA0 + i[7:0])) begin
                $display("[TB] FAIL: byte %0d read %02h, wanted %02h",
                         i, b, 8'hA0 + i[7:0]);
                errors = errors + 1;
            end
        end
        check(errors == 0, "1: FAST -- every byte lane stores and returns");

        // ---- 2: FAST -- VERA cannot write -----------------------------------
        // The safety property. VERA's bus keeps moving in FAST mode; if it
        // reached this memory it would overwrite the running program.
        vera_wr(0, 32'hFFFFFFFF, 8'hFF);
        cpu_read(0, b);
        check(b === 8'hA0,
              "2: FAST -- a VERA write cannot reach the block");

        // ---- 3: VIDEO -- the VERA port works, nibble enables mask ----------
        fast_mode = 1'b0;
        vera_wr(10, 32'h12345678, 8'hFF);
        vera_rd(10, w);
        check(w === 32'h12345678, "3a: VIDEO -- a full word stores and returns");

        vera_wr(10, 32'hFFFFFFFF, 8'h01);       // lane 0 only
        vera_rd(10, w);
        check(w === 32'h1234567F,
              "3b: VIDEO -- per-nibble write enables mask (FX needs this)");

        vera_wr(10, 32'h00000000, 8'h80);       // lane 7 only
        vera_rd(10, w);
        check(w === 32'h0234567F, "3c: VIDEO -- the top nibble masks too");

        // ---- 4: VIDEO -- the CPU cannot write -------------------------------
        cpu_write(40, 8'h5A);                   // word 10, lane 0
        vera_rd(10, w);
        check(w === 32'h0234567F,
              "4: VIDEO -- a CPU write cannot reach the block");

        // ---- 5: the two views agree on layout -------------------------------
        // Byte N belongs to word N>>2, lane N[1:0]. Written by the CPU in
        // FAST, read as a word by VERA in VIDEO -- which cannot happen on the
        // real machine (a mode change is a cold boot) but proves the mapping.
        fast_mode = 1'b1;
        cpu_write(20, 8'h11);                   // word 5, byte 0
        cpu_write(21, 8'h22);                   // word 5, byte 1
        cpu_write(22, 8'h33);                   // word 5, byte 2
        cpu_write(23, 8'h44);                   // word 5, byte 3
        fast_mode = 1'b0;
        vera_rd(5, w);
        check(w === 32'h44332211,
              "5: byte N is byte N[1:0] of word N>>2, little-endian");

        if (errors == 0)
            $display("*** PASS *** switch_ram: both modes work and NEITHER can reach the other's memory");
        else
            $display("*** FAIL *** switch_ram: %0d check(s) failed", errors);
        $finish;
    end

endmodule
