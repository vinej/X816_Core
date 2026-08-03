`timescale 1ns/1ps
// ============================================================================
// tb_boot.v -- the X816 boot path, end to end, on the real RTL.
//
// Instantiates the actual chain the machine boots through:
//
//   p65c816_flat_wrap -> [decode replica of x816.sv] -> bank0_ram + boot_rom
//                        + flat_sdram (with sdram_sim.v standing in for the
//                        SDRAM chip+controller) + vera_stub + SYSCTL
//
// and runs the SHIPPED 256-byte boot ROM (boot/boot.hex via boot_rom.sv's
// $readmemh -- run.sh copies it next to the work dir).  Two modes:
//
//   MODE=1  (run.sh target `boot`)
//     bootprobe.hex is streamed into flat_sdram's loader port at $01:0000,
//     exactly the path the HPS uses for boot1.rom (CPU held in reset, memory
//     alive).  PASS = overlay dropped + the four magic reads observed + the
//     probe's three witness writes seen with the right values ($42/$C7 to
//     bank-0 BRAM, and a $5A that must survive an SDRAM write->readback).
//
//   MODE=2  (run.sh target `fw`)
//     fwprobe.hex is staged at $F0:0000 -- the kernel firmware path
//     (boot2.rom, ioctl index 16'h0080).  Boot must take the FIRMWARE magic
//     branch.  Additional PASS term: the probe stores $AA to $00:0403 only if
//     its attempt to overwrite its own magic byte was dropped by the
//     firmware write-protect ($EE there = protection broken = instant FAIL).
//
//   MODE=0  (run.sh target `noboot`)
//     Nothing staged; SDRAM powers up as $DD, both magic checks fail, and the
//     boot ROM must fall back to the 320x240 colour-bands demo.  PASS =
//     overlay dropped + >= 76800 committed VERA DATA0 writes (320*240) +
//     the CPU parked in WAI (wait_state high for 20k consecutive cycles).
//
// The decode/glue here REPLICATES x816.sv (line refs in the comments below;
// audit them when the top changes).  Deliberate divergences from the top:
// no VIAs, no YM, no sd_block, no SMC -- their addresses fall through to the
// open-bus register, and cpu_rdy omits the sd_busy term.  The boot ROM
// touches none of them.
//
// Upstream heritage: monitors (fetch trap, ring buffer, heartbeat, timeout)
// follow x16_mister/sim/tb_fullboot.v.
// ============================================================================
module tb_boot #(
    parameter integer MODE        = 1,           // 0=none, 1=program, 2=firmware
    parameter         IMAGE_HEX   = "bootprobe.hex",
    parameter integer IMAGE_LEN   = 0,           // bytes; run.sh passes wc -l
    parameter integer TIMEOUT_CYC = 4_000_000,   // cpu_clk cycles (0.5 s)
    parameter integer RING        = 64
);
    localparam [23:0] STAGE_BASE = (MODE == 2) ? 24'hF00000 : 24'h010000;
    // ---- clocks: 8 MHz cpu, 100 MHz sdram (x816.sv pll outclk_2/outclk_3) --
    reg cpu_clk   = 0; always #62.5 cpu_clk   = ~cpu_clk;
    reg sdram_clk = 0; always #5    sdram_clk = ~sdram_clk;

    // ---- resets: memory alive during staging, CPU held (x816.sv:97-112) ----
    reg mem_reset_n = 0;
    reg cpu_reset_n = 0;
    reg staged      = 0;

    // ---- CPU -------------------------------------------------------------
    wire [23:0] cpu_a, cpu_pc;
    wire  [7:0] cpu_do;
    wire  [7:0] cpu_di;
    wire        cpu_rwn, cpu_sync, cpu_bus_valid;
    wire        cpu_emu_mode, cpu_i_flag, cpu_wait_state;
    wire        cpu_rdy;
    wire        vera_irq_n;

    p65c816_flat_wrap u_cpu (
        .clk        (cpu_clk),
        .enable     (cpu_rdy),
        .res_n      (cpu_reset_n),
        .irq_n      (vera_irq_n),      // stub never raises it (IEN stays 0)
        .nmi_n      (1'b1),
        .abort_n    (1'b1),
        .r_w_n      (cpu_rwn),
        .sync       (cpu_sync),
        .addr       (cpu_a),
        .din        (cpu_di),
        .dout       (cpu_do),
        .pc         (cpu_pc),
        .emu_mode   (cpu_emu_mode),
        .i_flag     (cpu_i_flag),
        .wait_state (cpu_wait_state),
        .bus_valid  (cpu_bus_valid)
    );

    // ---- address decode: replica of x816.sv:305-324 ------------------------
    wire dec_valid = cpu_bus_valid | ~cpu_rwn;

    wire bank0     = (cpu_a[23:16] == 8'h00);
    wire io_page   = bank0 & (cpu_a[15:8] == 8'h9F);

    wire via1_cs   = dec_valid & io_page & (cpu_a[7:4] == 4'h0);   // $9F00-$9F0F (absent here)
    wire via2_cs   = dec_valid & io_page & (cpu_a[7:4] == 4'h1);   // $9F10-$9F1F (absent here)
    wire vera_cs   = dec_valid & io_page & (cpu_a[7:5] == 3'b001); // $9F20-$9F3F -> stub
    wire ym_cs     = dec_valid & io_page & (cpu_a[7:4] == 4'h4);   // $9F40-$9F4F (absent here)
    wire sysctl_cs = dec_valid & io_page & (cpu_a[7:4] == 4'h8);   // $9F80-$9F8F

    wire rom_overlay_en;
    wire boot_page  = bank0 & (cpu_a[15:8] == 8'hFF);
    wire boot_sel   = dec_valid & boot_page & rom_overlay_en & cpu_rwn;

    wire bank0_cs   = dec_valid & bank0 & ~io_page;
    wire fw_region  = (cpu_a[23:20] == 4'hF);         // firmware write-protect
    // Banks $01-$04 are fast_ram, exactly as in x816.sv. This replica has to
    // track that change or the boot test keeps proving the OLD memory map:
    // bootprobe is staged at $01:0000, which is now BRAM, not SDRAM.
    wire fast_region = (cpu_a[23:16] >= 8'h01) & (cpu_a[23:16] <= 8'h04);
    wire fast_cs    = dec_valid & fast_region;
    wire flat_cs    = dec_valid & ~bank0 & ~fast_region & ~(fw_region & ~cpu_rwn);

    // ---- SYSCTL: replica of x816.sv:337-357 (SD regs/counters absent) ------
    reg sysctl_overlay = 1'b1;
    always @(posedge cpu_clk or negedge cpu_reset_n) begin
        if (!cpu_reset_n)                                     sysctl_overlay <= 1'b1;
        else if (sysctl_cs && ~cpu_rwn && cpu_a[3:0] == 4'h0) sysctl_overlay <= cpu_do[0];
    end
    assign rom_overlay_en = sysctl_overlay;

    wire [7:0] sysctl_data = (cpu_a[3:0] == 4'h0)
                           ? {6'b0, cpu_emu_mode, sysctl_overlay}
                           : 8'h00;

    // ---- memories: the real RTL --------------------------------------------
    wire [7:0] bank0_data, boot_data, sdram_data;
    wire       sdram_ready;
    wire [7:0] fast_data;
    wire [7:0] fast_bank_m1 = cpu_a[23:16] - 8'd1;
    wire [17:0] fast_addr   = {fast_bank_m1[1:0], cpu_a[15:0]};

    bank0_ram u_bank0 (
        .clk     (cpu_clk),
        .addr    (cpu_a[15:0]),
        .cs      (bank0_cs),
        .we      (~cpu_rwn),
        .wr_data (cpu_do),
        .rd_data (bank0_data),
        .ld_clk  (sdram_clk),
        .ld_wr   (1'b0),
        .ld_addr (16'h0000),
        .ld_data (8'h00),
        .ld_busy ()
    );

    boot_rom u_boot (
        .clk     (cpu_clk),
        .addr    (cpu_a[7:0]),
        .rd_data (boot_data)
    );

    // loader port: TB-driven, standing in for the ioctl path (x816.sv:415-429)
    reg         ld_wr = 0;
    reg  [23:0] ld_addr = 24'h0;
    reg   [7:0] ld_data = 8'h0;
    wire        ld_busy;

    // ...and routed by destination, exactly as x816.sv routes it. MODE=1
    // stages the probe at $01:0000, which is fast_ram now; MODE=2 stages it at
    // $F0:0000, which is still SDRAM. Getting this wrong would load the image
    // into a memory the CPU does not fetch from, and the failure would look
    // like a broken boot ROM.
    wire        ld_to_fast   = (ld_addr[23:16] >= 8'h01) & (ld_addr[23:16] <= 8'h04);
    wire  [7:0] ld_bank_m1   = ld_addr[23:16] - 8'd1;
    wire [17:0] ld_fast_addr = {ld_bank_m1[1:0], ld_addr[15:0]};
    wire        fast_ld_busy;

    fast_ram u_fast (
        .clk     (cpu_clk),
        .addr    (fast_addr),
        .cs      (fast_cs),
        .we      (~cpu_rwn),
        .wr_data (cpu_do),
        .rd_data (fast_data),
        .ld_clk  (sdram_clk),
        .ld_wr   (ld_wr & ld_to_fast),
        .ld_addr (ld_fast_addr),
        .ld_data (ld_data),
        .ld_busy (fast_ld_busy)
    );

    wire [12:0] sd_pin_a;
    wire [15:0] sd_pin_dq;
    wire  [1:0] sd_pin_ba;

    flat_sdram u_flat (
        .clk        (cpu_clk),
        .reset_n    (mem_reset_n),
        .cs         (flat_cs),
        .we         (~cpu_rwn),
        .byte_addr  (cpu_a),
        .wr_data    (cpu_do),
        .rd_data    (sdram_data),
        .ready      (sdram_ready),

        .sdram_clk  (sdram_clk),
        .ld_wr      (ld_wr & ~ld_to_fast),
        .ld_addr    (ld_addr),
        .ld_data    (ld_data),
        .ld_busy    (ld_busy),

        // Framebuffer stream -- idle until the VERA2 engine lands (stage C).
        .fb_go      (1'b0),
        .fb_base    (24'd0),
        .fb_len     (11'd0),
        .fb_valid   (),
        .fb_word    (),
        .fb_done    (),

        .SDRAM_A    (sd_pin_a),
        .SDRAM_DQ   (sd_pin_dq),
        .SDRAM_BA   (sd_pin_ba),
        .SDRAM_nCS  (),
        .SDRAM_nWE  (),
        .SDRAM_nRAS (),
        .SDRAM_nCAS (),
        .SDRAM_CKE  (),
        .SDRAM_CLK  (),
        .SDRAM_DQML (),
        .SDRAM_DQMH ()
    );

    // ---- VERA stub + the read-stall replica of x816.sv:491-505 -------------
    wire [7:0] vera_stub_rd;
    vera_stub u_vera (
        .clk     (cpu_clk),
        .reset_n (cpu_reset_n),
        .cs      (vera_cs),
        .we      (vera_cs & ~cpu_rwn & cpu_rdy),
        .addr    (cpu_a[4:0]),
        .wr_data (cpu_do),
        .rd_data (vera_stub_rd),
        .irq_n   (vera_irq_n)
    );

    wire vera_read = vera_cs & cpu_rwn;
    reg [1:0] vera_read_stall = 2'h0;
    always @(posedge cpu_clk or negedge cpu_reset_n) begin
        if (!cpu_reset_n)     vera_read_stall <= 2'h0;
        else if (vera_read) begin
            if (vera_read_stall != 2'd3) vera_read_stall <= vera_read_stall + 2'd1;
        end else              vera_read_stall <= 2'h0;
    end

    // x816.sv:505 without the sd_busy term (no sd_block in this TB)
    assign cpu_rdy = (~vera_read | (vera_read_stall >= 2'd2)) & sdram_ready;

    // ---- CPU data-in mux: replica of x816.sv:927-940 -----------------------
    // (via/ym fall through to open bus here -- the boot ROM never reads them)
    reg [7:0] open_bus_r = 8'h00;
    always @(posedge cpu_clk)
        if (cpu_rdy) open_bus_r <= cpu_rwn ? cpu_di : cpu_do;

    assign cpu_di = boot_sel   ? boot_data    :
                    fast_cs    ? fast_data    :
                    vera_cs    ? vera_stub_rd :
                    sysctl_cs  ? sysctl_data  :
                    bank0_cs   ? bank0_data   :
                    flat_cs    ? sdram_data   :
                                 open_bus_r;

    // ========================================================================
    // Staging: stream the probe image into $01:0000 through the loader port,
    // one strobe per byte, throttled by ld_busy -- the ioctl contract.
    // ========================================================================
    reg [7:0] image [0:4095];
    integer   si;
    initial begin
        // memory comes up first (x816.sv: mem reset excludes dl_hold)
        repeat (4) @(posedge sdram_clk);
        mem_reset_n <= 1'b1;
        repeat (600) @(posedge sdram_clk);        // flat_sdram S_INIT is 400

        if (MODE != 0) begin
            if (IMAGE_LEN <= 0) begin
                $display("[TB] *** FAIL: MODE=%0d but IMAGE_LEN=%0d ***", MODE, IMAGE_LEN);
                $finish;
            end
            $readmemh(IMAGE_HEX, image);
            $display("[TB] staging %0d bytes at %06x via the loader port", IMAGE_LEN, STAGE_BASE);
            for (si = 0; si < IMAGE_LEN; si = si + 1) begin
                @(posedge sdram_clk);
                // BOTH busies. x816.sv ORs them into ioctl_wait for exactly
                // this reason: whichever memory the byte is destined for is
                // the one applying backpressure, and honouring only the SDRAM
                // one overruns fast_ram's crossing FIFO and silently drops
                // bytes -- which presents as a boot ROM that finds no magic.
                while (ld_busy | fast_ld_busy) @(posedge sdram_clk);
                ld_wr   <= 1'b1;
                ld_addr <= STAGE_BASE + si;
                ld_data <= image[si];
                @(posedge sdram_clk);
                ld_wr   <= 1'b0;
            end
            repeat (400) @(posedge sdram_clk);    // drain the loader FIFO
        end

        staged <= 1'b1;
        @(posedge cpu_clk);
        cpu_reset_n <= 1'b1;
        $display("[TB] CPU released (MODE=%0d)", MODE);
    end

    // ========================================================================
    // Monitors
    // ========================================================================
    wire committed = cpu_reset_n & cpu_rdy;

    // ring buffer of the last RING committed bus cycles
    reg [23:0] ring_a   [0:RING-1];
    reg  [7:0] ring_d   [0:RING-1];
    reg        ring_rwn [0:RING-1];
    reg        ring_syn [0:RING-1];
    integer    ring_ptr = 0, ring_n = 0;
    always @(posedge cpu_clk) if (committed) begin
        ring_a  [ring_ptr] <= cpu_a;
        ring_d  [ring_ptr] <= cpu_rwn ? cpu_di : cpu_do;
        ring_rwn[ring_ptr] <= cpu_rwn;
        ring_syn[ring_ptr] <= cpu_sync;
        ring_ptr           <= (ring_ptr + 1) % RING;
        if (ring_n < RING) ring_n <= ring_n + 1;
    end

    task dump_ring;
        integer k, idx;
        begin
            $display("[TB] last %0d committed bus cycles (oldest first):", ring_n);
            for (k = 0; k < ring_n; k = k + 1) begin
                idx = (ring_ptr + RING - ring_n + k) % RING;
                $display("[TB]   a=%06x d=%02x rwn=%b sync=%b",
                         ring_a[idx], ring_d[idx], ring_rwn[idx], ring_syn[idx]);
            end
        end
    endtask

    // fetch trap: opcode fetches may only come from the boot page (ROM first,
    // then its RAM copy at the same addresses) or, when staged, the probe.
    // Armed only once the CPU provably starts executing the boot ROM: the
    // P65C816 emits address-0 sync cycles during its internal reset sequence
    // (before the $FFFC vector fetch), and those are not real fetches.
    wire fetch_ok = (cpu_a[23:8] == 16'h00FF) ||
                    ((MODE != 0) && (cpu_a >= STAGE_BASE) && (cpu_a < STAGE_BASE + 24'h800));
    reg     trap_armed = 0;
    integer committed_cyc = 0;
    always @(posedge cpu_clk) if (committed) begin
        committed_cyc = committed_cyc + 1;
        if (!trap_armed && cpu_sync && cpu_a[23:8] == 16'h00FF) begin
            trap_armed <= 1'b1;
            $display("[TB] first boot-ROM fetch at %06x (committed cycle %0d)", cpu_a, committed_cyc);
        end
        if (!trap_armed && committed_cyc > 1000) begin
            $display("[TB] *** CPU never reached the boot ROM within 1000 committed cycles ***");
            dump_ring;
            $display("*** FAIL: no boot fetch ***");
            $finish;
        end
        if (trap_armed && cpu_sync && !fetch_ok) begin
            $display("[TB] *** TRAP: opcode fetch from %06x at t=%0t ***", cpu_a, $time);
            dump_ring;
            $display("*** FAIL: rogue fetch ***");
            $finish;
        end
    end

    // overlay drop (the stz SYSCTL in boot.s)
    reg overlay_was = 1'b1;
    reg overlay_cleared = 1'b0;
    always @(posedge cpu_clk) begin
        overlay_was <= sysctl_overlay;
        if (overlay_was && !sysctl_overlay) begin
            overlay_cleared <= 1'b1;
            $display("[TB] SYSCTL[0] cleared at t=%0t -- overlay dropped, bank 0 is RAM", $time);
        end
    end

    // the four magic reads at the staged base
    integer magic_reads = 0;
    always @(posedge cpu_clk)
        if (committed && cpu_rwn && cpu_bus_valid &&
            cpu_a >= STAGE_BASE && cpu_a <= STAGE_BASE + 24'h3)
            magic_reads = magic_reads + 1;

    // probe witness writes (MODE 1/2); $0403 is the fw write-protect verdict
    reg got42 = 0, gotC7 = 0, got5A = 0, gotAA = 0;
    always @(posedge cpu_clk) if (committed && ~cpu_rwn) begin
        if (cpu_a == 24'h000400 && cpu_do == 8'h42) got42 <= 1'b1;
        if (cpu_a == 24'h000401 && cpu_do == 8'hC7) gotC7 <= 1'b1;
        if (cpu_a == 24'h000402 && cpu_do == 8'h5A) got5A <= 1'b1;   // SDRAM readback value
        if (cpu_a == 24'h000403 && cpu_do == 8'hAA) gotAA <= 1'b1;   // fw store was dropped
        if (cpu_a == 24'h000403 && cpu_do == 8'hEE) begin
            $display("[TB] *** probe reports the firmware write-protect DID NOT hold ***");
            dump_ring;
            $display("*** FAIL: firmware region writable ***");
            $finish;
        end
    end

    // VERA DATA0 writes (STAGE_IMAGE=0: the bands paint, 320*240 of them)
    integer data0_writes = 0;
    always @(posedge cpu_clk)
        if (committed && vera_cs && ~cpu_rwn && cpu_a[4:0] == 5'h03)
            data0_writes = data0_writes + 1;

    // WAI park: wait_state held high with the machine otherwise quiet
    integer wai_streak = 0;
    always @(posedge cpu_clk) begin
        if (cpu_reset_n && cpu_wait_state) wai_streak = wai_streak + 1;
        else                               wai_streak = 0;
    end

    // ========================================================================
    // Verdict / heartbeat / timeout
    // ========================================================================
    integer cyc = 0;
    reg done = 0;
    always @(posedge cpu_clk) begin
        cyc = cyc + 1;

        if (!done && (cyc % 500000) == 0)
            $display("[TB] HEARTBEAT cyc=%0d pc=%06x overlay=%b magic=%0d data0=%0d wai=%0d",
                     cyc, cpu_pc, sysctl_overlay, magic_reads, data0_writes, wai_streak);

        if (!done && MODE != 0 &&
            overlay_cleared && magic_reads >= 4 && got42 && gotC7 && got5A &&
            (MODE != 2 || gotAA)) begin
            done = 1;
            $display("[TB] overlay=dropped magic_reads=%0d witnesses=42/C7/5A%s seen (cyc=%0d)",
                     magic_reads, (MODE == 2) ? "/AA(write-protect)" : "", cyc);
            $display("[TB] boot -> magic @%06x -> jml entry -> bank0 + SDRAM write/readback all good",
                     STAGE_BASE);
            $display("*** PASS ***");
            $finish;
        end

        if (!done && MODE == 0 &&
            overlay_cleared && data0_writes >= 76800 && wai_streak > 20000) begin
            done = 1;
            $display("[TB] overlay=dropped data0_writes=%0d (>=76800) WAI park confirmed (cyc=%0d)",
                     data0_writes, cyc);
            $display("[TB] no image -> magic miss -> bands fallback -> WAI, as designed");
            $display("*** PASS ***");
            $finish;
        end

        if (cyc >= TIMEOUT_CYC) begin
            $display("[TB] TIMEOUT at cyc=%0d: pc=%06x overlay=%b magic=%0d 42/C7/5A/AA=%b%b%b%b data0=%0d wai=%0d",
                     cyc, cpu_pc, sysctl_overlay, magic_reads, got42, gotC7, got5A, gotAA, data0_writes, wai_streak);
            dump_ring;
            $display("*** FAIL: timeout ***");
            $finish;
        end
    end

endmodule
