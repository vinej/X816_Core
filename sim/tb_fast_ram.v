//============================================================================
// tb_fast_ram.v  --  banks $01-$04 in BRAM, on the real RTL.
//
// Four properties:
//
//   1. Every byte lane of a 32-bit word stores and returns independently.
//      This is the one that matters most, because the array is 32 bits wide
//      and the CPU is 8: a byte-enable that wrote the wrong lane, or a read
//      mux that picked the wrong one, would corrupt three bytes in four of
//      every program loaded -- and would do it identically every time, so it
//      would look like a compiler or loader fault rather than a memory one.
//   2. Writing one byte does NOT disturb its three neighbours in the same
//      word. A read-modify-write built from a stale word would pass check 1
//      and fail this.
//   3. The read is available on the CPU's next posedge -- the negedge-read
//      convention that makes the access single-cycle, which is the entire
//      reason the module exists.
//   4. The loader port reaches the array across its clock domain, and what it
//      wrote is what the CPU reads back.
//
// WORDS is small here: the lane arithmetic and the handshake do not care how
// deep the array is, and 65,536 words would only make the run slower.
//============================================================================
`timescale 1ns / 1ps

module tb_fast_ram;

    localparam WORDS = 64;

    reg         clk = 1'b0;
    reg  [17:0] addr = 0;
    reg         cs = 1'b0;
    reg         we = 1'b0;
    reg  [7:0]  wr_data = 0;
    wire [7:0]  rd_data;

    reg         ld_clk = 1'b0;
    reg         ld_wr = 1'b0;
    reg  [17:0] ld_addr = 0;
    reg  [7:0]  ld_data = 0;
    wire        ld_busy;

    integer errors = 0;

    fast_ram #(.WORDS(WORDS)) dut (
        .clk(clk), .addr(addr), .cs(cs), .we(we),
        .wr_data(wr_data), .rd_data(rd_data),
        .ld_clk(ld_clk), .ld_wr(ld_wr), .ld_addr(ld_addr),
        .ld_data(ld_data), .ld_busy(ld_busy)
    );

    always #5  clk    = ~clk;     // the CPU
    always #3  ld_clk = ~ld_clk;  // the loader, deliberately unrelated

    task check(input cond, input [8*64:1] what);
        begin
            if (!cond) begin
                $display("[TB] FAIL: %0s", what);
                errors = errors + 1;
            end else
                $display("[TB] ok:   %0s", what);
        end
    endtask

    // THE ADDRESS IS PRESENTED FOR A WHOLE CYCLE, which is what the CPU does
    // and what these tasks got wrong first time: driving addr AT the negedge
    // races the RAM's negedge read, so it latches the PREVIOUS address and
    // every read comes back one behind. That looked like an RTL fault and was
    // not -- the negedge convention is bank0_ram's and is correct. A bus model
    // has to respect the same setup the real bus provides.
    task cpu_write(input [17:0] a, input [7:0] d);
        begin
            @(posedge clk);
            addr = a; wr_data = d; cs = 1'b1; we = 1'b1;
            @(posedge clk);            // the write lands here
            cs = 1'b0; we = 1'b0;
        end
    endtask

    task cpu_read(input [17:0] a, output [7:0] d);
        begin
            @(posedge clk);
            addr = a; cs = 1'b1; we = 1'b0;   // stable for the whole cycle
            @(negedge clk);                   // the RAM latches here
            @(posedge clk);                   // the CPU samples here
            d = rd_data;
            cs = 1'b0;
        end
    endtask

    integer i;
    reg [7:0] b;

    initial begin
        $display("[TB] fast_ram: %0d words, 256 KB at full size", WORDS);

        // ---- 1: every byte lane, independently ----------------------------
        for (i = 0; i < 8; i = i + 1)
            cpu_write(i[17:0], 8'h10 + i[7:0]);
        for (i = 0; i < 8; i = i + 1) begin
            cpu_read(i[17:0], b);
            if (b !== (8'h10 + i[7:0])) begin
                $display("[TB] FAIL: byte %0d read %02h wanted %02h",
                         i, b, 8'h10 + i[7:0]);
                errors = errors + 1;
            end
        end
        check(errors == 0, "1: every byte lane stores and returns");

        // ---- 2: a write does not disturb the rest of its word --------------
        cpu_write(5, 8'hEE);              // word 1, lane 1
        cpu_read(4, b); check(b === 8'h14, "2a: lane 0 of the word survived");
        cpu_read(6, b); check(b === 8'h16, "2b: lane 2 survived");
        cpu_read(7, b); check(b === 8'h17, "2c: lane 3 survived");
        cpu_read(5, b); check(b === 8'hEE, "2d: ...and lane 1 took the write");

        // ---- 3: single-cycle -- valid at the FIRST posedge after the address
        // cpu_read samples at the posedge immediately following the address
        // being presented, so every check above already depended on it. Assert
        // it explicitly so the reason is recorded rather than implied.
        cpu_read(0, b);
        check(b === 8'h10, "3: the byte is ready at the next posedge");

        // ---- 4: the loader reaches the array across its clock domain -------
        @(negedge ld_clk);
        ld_addr = 18'd12; ld_data = 8'hC5; ld_wr = 1'b1;
        @(posedge ld_clk);
        @(negedge ld_clk);
        ld_wr = 1'b0;
        repeat (20) @(posedge clk);       // let the handshake carry it over
        cpu_read(12, b);
        check(b === 8'hC5, "4: a loader byte crosses and lands where asked");

        if (errors == 0)
            $display("*** PASS *** fast_ram: byte lanes, neighbours, single-cycle read, loader");
        else
            $display("*** FAIL *** fast_ram: %0d check(s) failed", errors);
        $finish;
    end

endmodule
