`timescale 1ns/1ps
// ============================================================================
// tb_vera2.v -- the VERA2 bitmap layer, end to end.
//
// Real RTL: vera2_regs + vera2_engine + flat_sdram + sdram_sim.  The chain
// under test is the whole one a program actually uses:
//
//   CPU store to $E0:xxxx -> flat_sdram window (2 bytes/word) -> fb stream ->
//   line buffer -> palette -> bmp_r/g/b
//
// Nothing here is stubbed, which matters: every earlier bug in this project's
// video work lived in the JOIN between two pieces that were each fine.
//
// Tests:
//   T1  ID/CTRL registers, and that the ID reads $00 with the OSD master
//       switch off -- "absent" and "present but disabled" are different
//       answers and software needs both.
//   T2  DISPBASE readback, including that bit 0 is forced even.
//   T3  4bpp scanout: a pattern written with ordinary CPU stores comes out as
//       the right pixels, in the right order, through the real palette.
//   T4  The layer is INVISIBLE when disabled -- bmp_active must never rise, or
//       a core with the OSD switch off would not be stock.
//
// PASS = zero mismatches.
// ============================================================================
module tb_vera2;

    reg pix_clk = 0;    always #20   pix_clk   = ~pix_clk;   // 25 MHz
    reg cpu_clk = 0;    always #62.5 cpu_clk   = ~cpu_clk;   // 8 MHz
    reg sdram_clk = 0;  always #5    sdram_clk = ~sdram_clk; // 100 MHz
    reg reset_n = 0;

    // ---- register block ----
    reg        rg_cs = 0, rg_rwn = 1;
    reg  [3:0] rg_addr = 0;
    reg  [7:0] rg_di = 0;
    wire [7:0] rg_do;
    reg        master_en = 1;

    wire        v2_enable, v2_passthru;
    wire  [1:0] v2_mode;
    wire [19:0] v2_disp_base;
    wire        pal_we;
    wire  [7:0] pal_idx;
    wire [11:0] pal_data;

    vera2_regs u_regs (
        .clk(cpu_clk), .reset_n(reset_n),
        .cs(rg_cs), .rwn(rg_rwn), .cpu_rdy(1'b1),
        .addr(rg_addr), .di(rg_di), .do_o(rg_do),
        .master_en(master_en),
        .bmp_enable(v2_enable), .bmp_mode(v2_mode),
        .bmp_passthru(v2_passthru), .disp_base(v2_disp_base),
        .pal_we(pal_we), .pal_idx(pal_idx), .pal_data(pal_data));

    // ---- engine <-> flat_sdram stream (declared before the instances) ----
    wire        fb_go;
    wire [23:0] fb_base;
    wire [10:0] fb_len;
    wire        fb_valid;
    wire [15:0] fb_word;
    wire        fb_done;

    reg        de = 0, vs = 0;
    wire [3:0] bmp_r, bmp_g, bmp_b;
    wire       bmp_active;

    vera2_engine u_eng (
        .pix_clk(pix_clk), .reset_n(reset_n),
        .enable(v2_enable), .mode(v2_mode),
        .de(de), .vs(vs), .disp_base(v2_disp_base),
        .bmp_r(bmp_r), .bmp_g(bmp_g), .bmp_b(bmp_b), .bmp_active(bmp_active),
        .pal_clk(cpu_clk), .pal_we(pal_we), .pal_idx(pal_idx), .pal_data(pal_data),
        .sdram_clk(sdram_clk),
        .fb_go(fb_go), .fb_base(fb_base), .fb_len(fb_len),
        .fb_valid(fb_valid), .fb_word(fb_word), .fb_done(fb_done));

    // ---- CPU port into flat memory ----
    reg         cs = 0, we = 0;
    reg  [23:0] byte_addr = 0;
    reg   [7:0] wr_data = 0;
    wire  [7:0] rd_data;
    wire        ready;

    wire [12:0] SDRAM_A;  wire [15:0] SDRAM_DQ;  wire [1:0] SDRAM_BA;
    wire SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
    wire SDRAM_CKE, SDRAM_CLK, SDRAM_DQML, SDRAM_DQMH;

    flat_sdram u_flat (
        .clk(cpu_clk), .reset_n(reset_n),
        // adv tied high: see tb_vfb.v.
        .cs(cs), .we(we), .adv(1'b1), .byte_addr(byte_addr),
        .wr_data(wr_data), .rd_data(rd_data), .ready(ready),
        .sdram_clk(sdram_clk),
        .ld_wr(1'b0), .ld_addr(24'd0), .ld_data(8'd0), .ld_busy(),
        .fb_go(fb_go), .fb_base(fb_base), .fb_len(fb_len),
        .fb_valid(fb_valid), .fb_word(fb_word), .fb_done(fb_done),
        .SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ), .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH));

    integer errors = 0;
    integer k;

    task chk(input [31:0] got, input [31:0] want, input [127:0] name);
        begin
            if (got !== want) begin
                errors = errors + 1;
                $display("[TB] MISMATCH %-20s got %0h, want %0h", name, got, want);
            end
        end
    endtask

    task reg_write(input [3:0] a, input [7:0] d);
        begin
            @(negedge cpu_clk); rg_cs = 1; rg_rwn = 0; rg_addr = a; rg_di = d;
            @(negedge cpu_clk); rg_cs = 0; rg_rwn = 1;
        end
    endtask

    task reg_read(input [3:0] a, output [7:0] d);
        begin
            @(negedge cpu_clk); rg_cs = 1; rg_rwn = 1; rg_addr = a;
            @(negedge cpu_clk); d = rg_do; rg_cs = 0;
        end
    endtask

    task cpu_write(input [23:0] a, input [7:0] d);
        begin
            @(negedge cpu_clk); cs = 1; we = 1; byte_addr = a; wr_data = d;
            @(posedge cpu_clk);
            while (!ready) @(posedge cpu_clk);
            @(negedge cpu_clk); cs = 0; we = 0;
        end
    endtask

    // Capture the pixel stream while the layer says it is active.
    reg  [3:0] seen [0:1023];
    integer    seen_n = 0;
    reg        capture = 0;
    always @(posedge pix_clk) begin
        if (capture && bmp_active) begin
            if (seen_n < 1024) seen[seen_n] = bmp_r;
            seen_n = seen_n + 1;
        end
    end

    reg [7:0] d8;
    reg [3:0] px_hi, px_lo;

    initial begin
        repeat (20) @(posedge cpu_clk);
        reset_n = 1;
        repeat (600) @(posedge sdram_clk);

        // ---- T1: identity and control ---------------------------------
        $display("[TB] T1 ID / CTRL");
        reg_read(4'h1, d8);  chk(d8, 8'hB5, "ID with master on");
        master_en = 0;
        reg_read(4'h1, d8);  chk(d8, 8'h00, "ID with master off");
        master_en = 1;
        reg_write(4'h0, 8'h05);              // enable=1, mode=2 (4bpp)
        reg_read(4'h0, d8);  chk(d8, 8'h05, "CTRL readback");
        chk(v2_mode, 2'd2, "mode = 4bpp");
        chk(v2_enable, 1'b1, "enable");

        // ---- T2: display base ------------------------------------------
        $display("[TB] T2 DISPBASE");
        reg_write(4'h2, 8'hFF);              // bit 0 must be forced even
        reg_write(4'h3, 8'h12);
        reg_write(4'h4, 8'h03);
        reg_read(4'h2, d8);  chk(d8, 8'hFE, "DISPL forced even");
        reg_read(4'h3, d8);  chk(d8, 8'h12, "DISPM");
        reg_read(4'h4, d8);  chk(d8, 8'h03, "DISPH");
        chk(v2_disp_base, 20'h312FE, "disp_base assembled");
        // back to 0 for the scanout test
        reg_write(4'h2, 8'h00); reg_write(4'h3, 8'h00); reg_write(4'h4, 8'h00);

        // ---- palette: entry i -> R=G=B=i, so bmp_r IS the pixel index ----
        for (k = 0; k < 16; k = k + 1) begin
            reg_write(4'h6, k[7:0]);                 // PALADR
            reg_write(4'h7, {k[3:0], k[3:0]});       // PALLO = {G,B}
            reg_write(4'h8, {4'b0, k[3:0]});         // PALHI = R, commits
        end

        // ---- framebuffer: 4bpp, high nibble = left pixel ----------------
        // FB byte k holds pixels 2k (hi nibble) and 2k+1 (lo nibble).
        // Write pixel p = p & 15, so the scanned line should read 0,1,2,...
        // Build the nibbles as 4-bit REGS first. Concatenating raw integers
        // makes 32-bit operands, so {a,b} keeps only the low 8 bits of b and
        // the high nibble silently writes as 0 -- which presents as "every
        // even pixel is colour 0" and looks exactly like an RTL unpack bug.
        // Third time this trap has appeared in this suite.
        for (k = 0; k < 320; k = k + 1) begin
            px_hi = (2*k)   & 4'hF;      // left pixel  -> high nibble
            px_lo = (2*k+1) & 4'hF;      // right pixel -> low nibble
            cpu_write(24'hE00000 + k[23:0], {px_hi, px_lo});
        end
        repeat (400) @(posedge sdram_clk);

        // ---- T3: scan one line and check the pixels ---------------------
        $display("[TB] T3 4bpp scanout through the real palette");
        // vsync: schedules the fetch of line 0 during blanking.
        @(negedge pix_clk); vs = 1;
        repeat (4) @(negedge pix_clk); vs = 0;
        // A 4bpp line fetch is ~1790 sdram_clk = ~18 us; give it room, as real
        // vertical blanking does.
        repeat (3000) @(posedge pix_clk);

        seen_n = 0; capture = 1;
        @(negedge pix_clk); de = 1;
        repeat (640) @(negedge pix_clk);
        de = 0;
        repeat (16) @(negedge pix_clk);
        capture = 0;

        if (seen_n < 640) begin
            errors = errors + 1;
            $display("[TB] MISMATCH active-count      got %0d, want >= 640", seen_n);
        end else begin
            for (k = 0; k < 640; k = k + 1) begin
                if (seen[k] !== (k & 4'hF)) begin
                    errors = errors + 1;
                    if (errors < 16)
                        $display("[TB] MISMATCH pixel[%0d]        got %0h, want %0h",
                                 k, seen[k], k & 4'hF);
                end
            end
        end

        // ---- T4: disabled means invisible -------------------------------
        $display("[TB] T4 disabled layer never activates");
        reg_write(4'h0, 8'h00);              // software disable
        repeat (10) @(posedge pix_clk);
        seen_n = 0; capture = 1;
        @(negedge pix_clk); vs = 1;
        repeat (4) @(negedge pix_clk); vs = 0;
        repeat (500) @(posedge pix_clk);
        de = 1; repeat (640) @(negedge pix_clk); de = 0;
        repeat (16) @(negedge pix_clk);
        capture = 0;
        chk(seen_n, 0, "no active pixels when off");

        if (errors == 0) begin
            $display("[TB] all 4 tests clean");
            $display("*** PASS *** vera2: store -> window -> stream -> palette -> pixel");
        end else begin
            $display("[TB] %0d mismatches", errors);
            $display("*** FAIL: vera2 bitmap layer ***");
        end
        $finish;
    end

    initial begin
        #40_000_000;
        $display("[TB] TIMEOUT");
        $display("*** FAIL: timeout ***");
        $finish;
    end

endmodule
