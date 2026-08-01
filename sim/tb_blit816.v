`timescale 1ns/1ps
// ============================================================================
// tb_blit816.v -- unit test for the VERA816 VRAM blitter.
//
// Real RTL under test: blit816 + vram_if (with the new lowest-priority if4
// port) + main_ram (the real 352 KB nibble-array VRAM, including its
// unpopulated-hole bounds check).  The testbench drives the engine's register
// interface directly (top.v's DCSEL-33 decode is a mux reviewed separately)
// and seeds/verifies VRAM through the REAL CPU byte port (if0), so the
// arbiter's write path is exercised from both masters.
//
// A behavioral shadow model mirrors every operation, including the
// contract's edges: byte granularity, ascending copy, address wrap modulo
// 512 KB, and the $58000-$7FFFF hole (writes discarded, reads 0).
//
// Tests:
//   T1 fill, word-aligned run          T5 the VERA2 "doubling" idiom
//   T2 fill, misaligned head+tail      T6 LEN=0 is a no-op (busy never rises)
//   T3 copy, co-aligned (word path)    T7 fill under 50% renderer contention
//   T4 copy, misaligned (byte path)    T8 wrap through the hole into $00000
//
// PASS = zero mismatches across all tests.
// ============================================================================
module tb_blit816;
    reg clk = 0; always #20 clk = ~clk;   // 25 MHz pixel clock
    reg rst = 1;

    // ---- engine register interface ----
    reg  [3:0] reg_idx = 0;
    reg        reg_data_we = 0;
    reg  [7:0] reg_wrdata = 0;
    reg        start_copy = 0, start_fill = 0;
    wire [7:0] reg_rddata;
    wire       busy;

    // ---- engine <-> vram_if ----
    wire [16:0] b_addr;
    wire [31:0] b_wrdata;
    wire  [7:0] b_wrnibblesel;
    wire [31:0] b_rddata;
    wire        b_write, b_strobe, b_ack;

    blit816 dut(
        .rst(rst), .clk(clk),
        .reg_idx(reg_idx), .reg_data_we(reg_data_we), .reg_wrdata(reg_wrdata),
        .reg_rddata(reg_rddata), .start_copy(start_copy), .start_fill(start_fill),
        .busy(busy),
        .vram_addr(b_addr), .vram_wrdata(b_wrdata), .vram_wrnibblesel(b_wrnibblesel),
        .vram_rddata(b_rddata), .vram_write(b_write), .vram_strobe(b_strobe),
        .vram_ack(b_ack));

    // ---- CPU byte port (seed + verify) ----
    reg  [18:0] c_addr = 0;
    reg   [7:0] c_wrdata = 0;
    reg         c_strobe = 0, c_write = 0;
    wire  [7:0] c_rddata;

    // ---- contention generator on if2 (a "renderer") ----
    reg         contend = 0;
    reg  [1:0]  ccnt = 0;
    always @(posedge clk) ccnt <= ccnt + 2'd1;
    wire        if2_strobe = contend && ccnt[0];

    vram_if vif(
        .clk(clk),
        .if0_addr(c_addr),
        .if0_addr_nibble(1'b0),
        .if0_4bit_mode(1'b0),
        .if0_cache_write_enabled(1'b0),
        .if0_transparency_enabled(1'b0),
        .if0_one_byte_cache_cycling(1'b0),
        .if0_cache8(8'h00),
        .if0_mult_accum_cache32(32'h0),
        .if0_wrdata(c_wrdata),
        .if0_rddata(c_rddata),
        .if0_strobe(c_strobe),
        .if0_write(c_write),

        .if1_addr(17'h0), .if1_rddata(), .if1_strobe(1'b0), .if1_ack(),
        .if2_addr(17'h00123), .if2_rddata(), .if2_strobe(if2_strobe), .if2_ack(),
        .if3_addr(17'h0), .if3_rddata(), .if3_strobe(1'b0), .if3_ack(),

        .if4_addr(b_addr), .if4_wrdata(b_wrdata), .if4_wrnibblesel(b_wrnibblesel),
        .if4_rddata(b_rddata), .if4_write(b_write), .if4_strobe(b_strobe),
        .if4_ack(b_ack));

    // ---- behavioral shadow model, hole included ----
    localparam integer VRAM_TOP = 'h58000;    // populated bytes: 0..$57FFF
    reg [7:0] model [0:'h57FFF];
    integer i;
    initial for (i = 0; i < VRAM_TOP; i = i + 1) model[i] = 8'h00;

    task m_write(input [18:0] a, input [7:0] d);
        if (a < VRAM_TOP) model[a] = d;
    endtask
    function [7:0] m_read(input [18:0] a);
        m_read = (a < VRAM_TOP) ? model[a] : 8'h00;
    endfunction

    // ---- low-level drivers (negedge-timed so posedge sampling is clean) ----
    task vpoke(input [18:0] a, input [7:0] d);
        begin
            @(negedge clk);
            c_addr = a; c_wrdata = d; c_write = 1; c_strobe = 1;
            @(negedge clk);
            c_strobe = 0; c_write = 0;
            m_write(a, d);
        end
    endtask

    task vpeek(input [18:0] a, output [7:0] d);
        begin
            @(negedge clk);
            c_addr = a; c_write = 0; c_strobe = 1;
            @(negedge clk);
            c_strobe = 0;
            @(negedge clk);
            d = c_rddata;
        end
    endtask

    task reg8(input [3:0] idx, input [7:0] val);
        begin
            @(negedge clk);
            reg_idx = idx; reg_wrdata = val; reg_data_we = 1;
            @(negedge clk);
            reg_data_we = 0;
        end
    endtask

    task set_params(input [18:0] src, input [18:0] dst, input [18:0] len, input [7:0] val);
        begin
            reg8(0, src[7:0]);  reg8(1, src[15:8]);  reg8(2, {5'b0, src[18:16]});
            reg8(3, dst[7:0]);  reg8(4, dst[15:8]);  reg8(5, {5'b0, dst[18:16]});
            reg8(6, len[7:0]);  reg8(7, len[15:8]);  reg8(8, {5'b0, len[18:16]});
            reg8(9, val);
        end
    endtask

    integer wait_cnt;
    task go(input fill);
        begin
            @(negedge clk);
            if (fill) start_fill = 1; else start_copy = 1;
            @(negedge clk);
            start_fill = 0; start_copy = 0;
            wait_cnt = 0;
            while (busy && wait_cnt < 400000) begin
                @(posedge clk);
                wait_cnt = wait_cnt + 1;
            end
            if (busy) begin
                $display("[TB] *** engine stuck busy after %0d cycles ***", wait_cnt);
                $display("*** FAIL: hang ***");
                $finish;
            end
        end
    endtask

    // model-side operations (contract semantics: byte-wise, ascending, wrap)
    integer k;
    reg [18:0] ma;
    task m_fill(input [18:0] dst, input [18:0] len, input [7:0] val);
        for (k = 0; k < len; k = k + 1) begin
            ma = dst + k[18:0];
            m_write(ma, val);
        end
    endtask
    task m_copy(input [18:0] src, input [18:0] dst, input [18:0] len);
        for (k = 0; k < len; k = k + 1)
            m_write(dst + k[18:0], m_read(src + k[18:0]));
    endtask

    integer errors = 0;
    reg [7:0] got;
    task verify(input [18:0] from, input [18:0] to, input [127:0] name);
        begin
            for (ma = from; ma <= to; ma = ma + 1) begin
                vpeek(ma, got);
                if (got !== m_read(ma)) begin
                    errors = errors + 1;
                    if (errors < 20)
                        $display("[TB] MISMATCH %-16s @%05x got=%02x want=%02x",
                                 name, ma, got, m_read(ma));
                end
            end
        end
    endtask

    // ========================================================================
    reg [7:0] tmp;
    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);

        // T1: fill, aligned run inside a seeded field
        // (seed the whole verify window: unwritten VRAM reads X in sim, and a
        // seeded margin is what makes neighbour-clobber detection real)
        $display("[TB] T1 fill aligned");
        for (ma = 'h0FFF8; ma < 'h10130; ma = ma + 1) vpoke(ma, ma[7:0] ^ 8'h11);
        set_params(0, 'h10020, 64, 8'hA5);
        go(1);
        m_fill('h10020, 64, 8'hA5);
        verify('h0FFF8, 'h10128, "fill-aligned");

        // T2: fill, misaligned head + tail
        $display("[TB] T2 fill misaligned");
        for (ma = 'h20000; ma <= 'h20010; ma = ma + 1) vpoke(ma, 8'hEE);
        set_params(0, 'h20001, 9, 8'h3C);
        go(1);
        m_fill('h20001, 9, 8'h3C);
        verify('h20000, 'h20010, "fill-misaligned");

        // T3: copy, co-aligned (word fast path)
        $display("[TB] T3 copy aligned");
        for (ma = 'h30000; ma < 'h30100; ma = ma + 1) vpoke(ma, ma[7:0] ^ 8'h5A);
        for (ma = 'h303F8; ma <= 'h30518; ma = ma + 1) vpoke(ma, 8'hBB);  // dest field
        for (ma = 'h306F8; ma <= 'h30718; ma = ma + 1) vpoke(ma, 8'hDD);  // T4 dest field
        set_params('h30000, 'h30400, 256, 8'h00);
        go(0);
        m_copy('h30000, 'h30400, 256);
        verify('h303F8, 'h30508, "copy-aligned");

        // T4: copy, misaligned (byte path with source-word cache)
        $display("[TB] T4 copy misaligned");
        set_params('h30001, 'h30702, 13, 8'h00);
        go(0);
        m_copy('h30001, 'h30702, 13);
        verify('h306F8, 'h30718, "copy-misaligned");

        // T5: the VERA2 doubling idiom (disjoint ascending copies)
        $display("[TB] T5 doubling");
        for (ma = 'h40000; ma < 'h40010; ma = ma + 1) vpoke(ma, ma[3:0] + 8'hC0);
        set_params('h40000, 'h40010, 16, 8'h00); go(0); m_copy('h40000, 'h40010, 16);
        set_params('h40000, 'h40020, 32, 8'h00); go(0); m_copy('h40000, 'h40020, 32);
        verify('h40000, 'h4003F, "doubling");

        // T6: LEN=0 is a no-op
        $display("[TB] T6 len=0");
        vpoke('h48000, 8'h77);
        set_params('h48000, 'h48000, 0, 8'h99);
        @(negedge clk); start_fill = 1; @(negedge clk); start_fill = 0;
        repeat (20) @(posedge clk);
        if (busy) begin
            $display("*** FAIL: len=0 raised busy ***"); $finish;
        end
        verify('h48000, 'h48000, "len0");

        // T7: fill under 50% renderer contention on if2
        $display("[TB] T7 contention");
        for (ma = 'h4FFF8; ma <= 'h50110; ma = ma + 1) vpoke(ma, 8'h44);
        contend = 1;
        set_params(0, 'h50000, 256, 8'h81);
        go(1);
        contend = 0;
        m_fill('h50000, 256, 8'h81);
        verify('h4FFF8, 'h50108, "contention");

        // T8: wrap modulo 512 KB through the unpopulated hole
        $display("[TB] T8 wrap+hole");
        vpoke('h00000, 8'h10); vpoke('h00001, 8'h20); vpoke('h00002, 8'h30);
        vpoke('h00003, 8'h40); vpoke('h00004, 8'h50);
        set_params(0, 'h7FFFE, 4, 8'h66);
        go(1);
        m_fill('h7FFFE, 4, 8'h66);   // 7FFFE/7FFFF in the hole, wraps to 0/1
        verify('h00000, 'h00004, "wrap-low");
        vpeek('h7FFFE, tmp);
        if (tmp !== 8'h00) begin
            errors = errors + 1;
            $display("[TB] MISMATCH hole @7FFFE got=%02x want=00", tmp);
        end

        if (errors == 0) begin
            $display("[TB] all 8 tests clean");
            $display("*** PASS ***");
        end else begin
            $display("[TB] %0d mismatches", errors);
            $display("*** FAIL: data mismatches ***");
        end
        $finish;
    end

    initial begin
        #80_000_000;   // 2M cycles at 25 MHz
        $display("[TB] TIMEOUT");
        $display("*** FAIL: timeout ***");
        $finish;
    end

endmodule
