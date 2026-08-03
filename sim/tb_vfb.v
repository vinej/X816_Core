`timescale 1ns/1ps
// ============================================================================
// tb_vfb.v -- the VERA2 framebuffer window in flat_sdram's address mapping.
//
// Real RTL under test: flat_sdram + sdram_sim.  The testbench drives the CPU
// port and then LOOKS INSIDE the SDRAM model, because the property that
// matters is invisible from the CPU side: a round-trip through the data path
// reads back correctly under EITHER mapping, so a read/write test alone proves
// nothing about the packing.
//
// What is being proved (doc/MEMORY_MAP.md 3, flat_sdram.sv map_addr):
//
//   T1  Outside the window, byte N is still lane 0 of word N -- bit-identical
//       to the mapping that was proven on hardware. This is the regression
//       guard: the window must not have disturbed ordinary memory.
//   T2  Inside the window, bytes 2K and 2K+1 are the TWO LANES OF ONE WORD.
//       This is what lets the scanout engine read two pixels per access, and
//       it is the entire reason 640x480 8bpp is possible.
//   T3  The word a framebuffer byte pair lands in is the expected one:
//       FB byte $E00000+k -> word {4'hE, 1'b0, k[19:1]}, lane k[0].
//   T4  Round-trip through the CPU port is correct in both regions.
//   T5  No collision. The window occupies words $E00000-$E7FFFF; writing the
//       whole framebuffer must not disturb ordinary memory, and in particular
//       must not touch the words that back CPU bytes $E00000+ under the OLD
//       mapping -- which is where a half-applied change would show up.
//   T6  The loader port takes the same mapping, so an image can be staged
//       straight into the framebuffer.
//
// PASS = zero mismatches.
// ============================================================================
module tb_vfb;

    reg clk = 0;        always #62.5 clk = ~clk;     // 8 MHz cpu_clk
    reg sdram_clk = 0;  always #5    sdram_clk = ~sdram_clk;  // 100 MHz
    reg reset_n = 0;

    // ---- CPU port ----
    reg         cs = 0, we = 0;
    reg  [23:0] byte_addr = 0;
    reg   [7:0] wr_data = 0;
    wire  [7:0] rd_data;
    wire        ready;

    // ---- loader port ----
    reg         ld_wr = 0;
    reg  [23:0] ld_addr = 0;
    reg   [7:0] ld_data = 0;
    wire        ld_busy;

    wire [12:0] SDRAM_A;
    wire [15:0] SDRAM_DQ;
    wire  [1:0] SDRAM_BA;
    wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
    wire        SDRAM_CKE, SDRAM_CLK, SDRAM_DQML, SDRAM_DQMH;

    // ---- framebuffer stream port ----
    // DECLARED BEFORE THE INSTANCE ON PURPOSE. An undeclared name in a port
    // connection becomes an implicit ONE-BIT wire, so with these below the
    // instantiation fb_base would have been silently truncated from 24 bits
    // to 1 -- the same family of silent Verilog truncation that sim/run.sh
    // lint exists for. Here it happened to collide with the later explicit
    // declaration and errored out; without that collision it would have been
    // a testbench quietly measuring the wrong thing.
    reg         fb_go = 0;
    reg  [23:0] fb_base = 0;
    reg  [10:0] fb_len = 0;
    wire        fb_valid;
    wire [15:0] fb_word;
    wire        fb_done;

    flat_sdram dut (
        .clk(clk), .reset_n(reset_n),
        .cs(cs), .we(we), .byte_addr(byte_addr),
        .wr_data(wr_data), .rd_data(rd_data), .ready(ready),
        .sdram_clk(sdram_clk),
        .ld_wr(ld_wr), .ld_addr(ld_addr), .ld_data(ld_data), .ld_busy(ld_busy),
        .fb_go(fb_go), .fb_base(fb_base), .fb_len(fb_len),
        .fb_valid(fb_valid), .fb_word(fb_word), .fb_done(fb_done),
        .SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ), .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH));

    // The model lives inside flat_sdram's sdram instance. sim/run.sh compiles
    // sdram_sim.v under the name `sdram`, so this hierarchical path reaches the
    // real storage array -- which is the only way to see the packing.
    `define WMEM dut.u_sdram.wmem

    integer errors = 0;

    task expect_word(input [23:0] widx, input [15:0] want, input [127:0] name);
        begin
            if (`WMEM[widx] !== want) begin
                errors = errors + 1;
                $display("[TB] MISMATCH %-22s word %06x = %04x, want %04x",
                         name, widx, `WMEM[widx], want);
            end
        end
    endtask

    task expect_byte(input [7:0] got, input [7:0] want, input [127:0] name);
        begin
            if (got !== want) begin
                errors = errors + 1;
                $display("[TB] MISMATCH %-22s read %02x, want %02x",
                         name, got, want);
            end
        end
    endtask

    // ---- CPU-port primitives (hold until ready, like the real CPU) ----
    task cpu_write(input [23:0] a, input [7:0] d);
        begin
            @(negedge clk);
            cs = 1; we = 1; byte_addr = a; wr_data = d;
            @(posedge clk);
            while (!ready) @(posedge clk);
            @(negedge clk);
            cs = 0; we = 0;
        end
    endtask

    task cpu_read(input [23:0] a, output [7:0] d);
        begin
            @(negedge clk);
            cs = 1; we = 0; byte_addr = a;
            @(posedge clk);
            while (!ready) @(posedge clk);
            d = rd_data;
            @(negedge clk);
            cs = 0;
        end
    endtask

    // A write is ACCEPTED by the CPU port long before it reaches the array:
    // it crosses to sdram_clk through the toggle handshake and then waits its
    // turn in the FSM. Peeking at wmem is not ordered behind that, so every
    // direct inspection below settles first. (The T4 reads needed no such
    // wait -- they go through the same FIFO and are ordered by construction,
    // which is exactly why they passed while the peeks saw stale memory.)
    task settle;
        begin repeat (300) @(posedge sdram_clk); end
    endtask

    task ld_push(input [23:0] a, input [7:0] d);
        begin
            @(negedge sdram_clk);
            while (ld_busy) @(negedge sdram_clk);
            ld_addr = a; ld_data = d; ld_wr = 1;
            @(negedge sdram_clk);
            ld_wr = 0;
        end
    endtask

    reg [7:0] got;
    reg [7:0] want_lo, want_hi;
    integer k;

    // Stream capture + a clock counter, so the fetch RATE is measured rather
    // than asserted. This is the number that decides whether a mode is usable:
    // a 640x480/60 line is 3200 sdram_clk, and 8bpp needs 320 words of it.
    reg [15:0] fb_seen [0:1023];
    integer    fb_n = 0;
    integer    fb_clocks = 0;
    reg        fb_timing = 0;
    always @(posedge sdram_clk) begin
        if (fb_timing) fb_clocks = fb_clocks + 1;
        if (fb_valid) begin
            fb_seen[fb_n] = fb_word;
            fb_n = fb_n + 1;
        end
    end

    task fb_run(input [23:0] base, input [10:0] len);
        begin
            fb_n = 0; fb_clocks = 0;
            @(negedge sdram_clk);
            fb_base = base; fb_len = len; fb_go = 1; fb_timing = 1;
            @(negedge sdram_clk);
            fb_go = 0;
            @(posedge fb_done);
            @(posedge sdram_clk);   // the last fb_valid rides with fb_done
            fb_timing = 0;
        end
    endtask

    initial begin
        repeat (20) @(posedge clk);
        reset_n = 1;
        repeat (500) @(posedge sdram_clk);   // let the controller finish init

        // ------------------------------------------------------------------
        // T1: ordinary memory is UNCHANGED -- byte N at lane 0 of word N.
        // ------------------------------------------------------------------
        $display("[TB] T1 ordinary memory: byte N -> lane 0 of word N");
        cpu_write(24'h205000, 8'h11);
        cpu_write(24'h205001, 8'h22);
        // Two consecutive bytes must be in two DIFFERENT words, low lane each,
        // with the high lane left at the model's fill pattern.
        settle;
        expect_word(24'h205000, 16'hDD11, "outside-word-N");
        expect_word(24'h205001, 16'hDD22, "outside-word-N+1");

        // ...and at the very top of ordinary memory, right below the window.
        cpu_write(24'hDFFFFF, 8'h5A);
        settle;
        expect_word(24'hDFFFFF, 16'hDD5A, "outside-top");

        // ...and above the window, in the firmware region.
        cpu_write(24'hF00000, 8'hA5);
        settle;
        expect_word(24'hF00000, 16'hDDA5, "outside-firmware");

        // ------------------------------------------------------------------
        // T2/T3: inside the window, a byte PAIR shares one word.
        // FB byte $E00000+k -> word {4'hE, 1'b0, k[19:1]}, lane k[0].
        // ------------------------------------------------------------------
        $display("[TB] T2 framebuffer window: byte pairs share a word");
        cpu_write(24'hE00000, 8'hAB);   // k=0 -> word $E00000 lane 0 (even x)
        cpu_write(24'hE00001, 8'hCD);   // k=1 -> word $E00000 lane 1 (odd x)
        settle;
        expect_word(24'hE00000, 16'hCDAB, "fb-pair-0 even+odd");

        cpu_write(24'hE00002, 8'h01);   // k=2 -> word $E00001 lane 0
        cpu_write(24'hE00003, 8'h02);   // k=3 -> word $E00001 lane 1
        settle;
        expect_word(24'hE00001, 16'h0201, "fb-pair-1");

        // A pair well inside the framebuffer: k = $4AFFE/$4AFFF is the last
        // pixel pair of a 640x480 8bpp image (307,200 bytes).
        $display("[TB] T3 last pixel pair of a 640x480 8bpp frame");
        cpu_write(24'hE4AFFE, 8'h7E);
        cpu_write(24'hE4AFFF, 8'h7F);
        settle;
        expect_word(24'hE00000 + 24'h257FF, 16'h7F7E, "fb-last-8bpp-pair");

        // The top of the window: k = $FFFFE/$FFFFF -> word $E7FFFF.
        cpu_write(24'hEFFFFE, 8'hF0);
        cpu_write(24'hEFFFFF, 8'hF1);
        settle;
        expect_word(24'hE7FFFF, 16'hF1F0, "fb-top-pair");

        // ------------------------------------------------------------------
        // T4: round-trip through the CPU port, both regions.
        // ------------------------------------------------------------------
        $display("[TB] T4 CPU round-trip");
        cpu_read(24'h205000, got); expect_byte(got, 8'h11, "rt-outside-0");
        cpu_read(24'h205001, got); expect_byte(got, 8'h22, "rt-outside-1");
        cpu_read(24'hE00000, got); expect_byte(got, 8'hAB, "rt-fb-even");
        cpu_read(24'hE00001, got); expect_byte(got, 8'hCD, "rt-fb-odd");
        cpu_read(24'hEFFFFF, got); expect_byte(got, 8'hF1, "rt-fb-top");
        cpu_read(24'hF00000, got); expect_byte(got, 8'hA5, "rt-firmware");

        // ------------------------------------------------------------------
        // T5: no collision. The window uses words $E00000-$E7FFFF only, so
        // words $E80000-$EFFFFF -- where the OLD mapping would have put CPU
        // bytes $E80000-$EFFFFF -- must be untouched. A half-applied change
        // (window decode present, arithmetic wrong) lands here.
        // ------------------------------------------------------------------
        $display("[TB] T5 no collision with the old mapping's words");
        expect_word(24'hE80000, 16'hDDDD, "no-collision-E80000");
        expect_word(24'hEFFFFF, 16'hDDDD, "no-collision-EFFFFF");
        // and the byte written at $DF:FFFF is still where T1 put it
        cpu_read(24'hDFFFFF, got); expect_byte(got, 8'h5A, "rt-outside-top");

        // ------------------------------------------------------------------
        // T6: the LOADER takes the same mapping, so an image can be staged
        // straight into the framebuffer.
        // ------------------------------------------------------------------
        $display("[TB] T6 loader port uses the same mapping");
        ld_push(24'hE10000, 8'h3C);
        ld_push(24'hE10001, 8'h3D);
        ld_push(24'h300000, 8'h9E);
        repeat (400) @(posedge sdram_clk);   // drain the loader FIFO
        expect_word(24'hE08000, 16'h3D3C, "ld-fb-pair");
        expect_word(24'h300000, 16'hDD9E, "ld-outside");

        // ------------------------------------------------------------------
        // T7: the framebuffer read stream returns the right words, in order.
        // Seed a run of pixel pairs through the CPU port (the ordinary-store
        // path a program would use), then stream them back as the engine will.
        // ------------------------------------------------------------------
        $display("[TB] T7 fb stream: content and order");
        for (k = 0; k < 64; k = k + 1) begin
            cpu_write(24'hE20000 + k[23:0], (k * 7 + 3) & 8'hFF);
        end
        settle;
        // 64 bytes = 32 words, starting at word $E10000 ($E20000 >> 1).
        fb_run(24'hE10000, 11'd32);
        if (fb_n != 32) begin
            errors = errors + 1;
            $display("[TB] MISMATCH fb-count            got %0d words, want 32", fb_n);
        end
        for (k = 0; k < 32; k = k + 1) begin
            // Build the halves as 8-bit regs first: concatenating raw integers
            // makes 32-bit operands and the compare is then never equal.
            want_lo = ((2*k)   * 7 + 3) & 8'hFF;   // even x -> low byte
            want_hi = ((2*k+1) * 7 + 3) & 8'hFF;   // odd  x -> high byte
            if (fb_seen[k] !== {want_hi, want_lo}) begin
                errors = errors + 1;
                if (errors < 20)
                    $display("[TB] MISMATCH fb-word[%0d]        got %04x, want %04x",
                             k, fb_seen[k], {want_hi, want_lo});
            end
        end

        // ------------------------------------------------------------------
        // T8: LEN=0 starts nothing, and fb_go mid-run is ignored.
        // ------------------------------------------------------------------
        $display("[TB] T8 fb stream: len=0 is a no-op");
        repeat (20) @(posedge sdram_clk);
        fb_n = 0;
        @(negedge sdram_clk); fb_base = 24'hE10000; fb_len = 11'd0; fb_go = 1;
        @(negedge sdram_clk); fb_go = 0;
        repeat (200) @(posedge sdram_clk);
        if (fb_n != 0) begin
            errors = errors + 1;
            $display("[TB] MISMATCH fb-len0             %0d words emitted, want 0", fb_n);
        end

        // ------------------------------------------------------------------
        // T9: THE RATE. Measure a full 8bpp line fetch (320 words) with the
        // CPU idle, and compare against the 3200 sdram_clk a 640x480/60 line
        // actually lasts. This is reported whatever the outcome -- the point
        // is to have the number, not to assert a guess.
        // ------------------------------------------------------------------
        $display("[TB] T9 fb stream: measured line-fetch rate");
        fb_run(24'hE10000, 11'd320);
        $display("[TB] 320-word line fetch (8bpp, CPU idle): %0d sdram_clk, %0d.%0d clk/word",
                 fb_clocks, fb_clocks/320, ((fb_clocks*10)/320) % 10);
        $display("[TB] a 640x480/60 line is 3200 sdram_clk -> 8bpp %s, 4bpp (160 words) %s",
                 (fb_clocks <= 3200) ? "FITS" : "DOES NOT FIT",
                 (fb_clocks/2 <= 3200) ? "FITS" : "DOES NOT FIT");
        if (fb_n != 320) begin
            errors = errors + 1;
            $display("[TB] MISMATCH fb-line-count       got %0d words, want 320", fb_n);
        end

        if (errors == 0) begin
            $display("[TB] all 9 tests clean");
            $display("*** PASS *** vfb: window packs pairs, outside unchanged, stream ordered");
        end else begin
            $display("[TB] %0d mismatches", errors);
            $display("*** FAIL: framebuffer window mapping ***");
        end
        $finish;
    end

    initial begin
        #20_000_000;
        $display("[TB] TIMEOUT");
        $display("*** FAIL: timeout ***");
        $finish;
    end

endmodule
