//============================================================================
//  X816 for MiSTer  --  a flat 16 MB, native-mode-only 65C816 machine.
//
//  This is NOT a Commander X16 and cannot run X16 software.  It reuses the
//  X16 core's PERIPHERALS (VERA, YM2151, 6522 VIAs, the SMC keyboard path)
//  and the whole MiSTer framework, but replaces the machine architecture:
//
//    X16                                  X816
//    ---------------------------------    ---------------------------------
//    16-bit address bus                   FLAT 24-bit bus, 16 MB
//    ROM bank latch at $0001              no banking at all
//    RAM bank latch at $0000              no banking at all
//    $A000-$BFFF HiRAM window             no windows
//    256 KB system ROM in BRAM            256-byte boot overlay, then none
//    65C816 running in EMULATION mode     NATIVE mode, M=0/X=0
//
//  MEMORY MAP
//    $00:0000-$00:9EFF   RAM   (bank-0 BRAM, single cycle)
//    $00:9F00-$00:9FFF   I/O   (same page layout as the X16 -- see below)
//    $00:A000-$00:FEFF   RAM   (bank-0 BRAM, single cycle)
//    $00:FF00-$00:FFFF   boot ROM overlay for READS while SYSCTL[0]=1,
//                        RAM underneath for writes and after SYSCTL[0]=0
//    $01:0000-$04:FFFF   RAM   (BRAM, single cycle -- program code lands
//                        here, so it runs 4.47x faster than it used to)
//    $05:0000-$FF:FFFF   RAM   (SDRAM, stalls the CPU per access)
//
//  I/O page ($00:9Fxx) is deliberately byte-for-byte the X16's, so VERA, VIA
//  and YM2151 register offsets -- and any driver written against them --
//  port over unchanged.  One 256-byte hole in a 16 MB space is a cheap price
//  for that.
//    $9F00-$9F0F  VIA #1      $9F20-$9F3F  VERA
//    $9F10-$9F1F  VIA #2      $9F40-$9F4F  YM2151
//    $9F80-$9F8F  SYSCTL      (new: X816 system control, not an X16 register)
//
//  CLOCKS come from the X16 core's PLL IP with outclk_1 retuned to 14 MHz
//  (a hand edit of the frequency parameter in pll/pll_0002.v -- Quartus
//  recomputes the counters at synthesis; VCO 1400 MHz divides all four
//  outputs exactly): outclk_0 25.0 MHz (VERA pixel), outclk_1 14.0 MHz
//  (CPU + peripherals), outclk_2 8.0 MHz (spare -- the pre-turbo CPU clock),
//  outclk_3 100.0 MHz (SDRAM + hps_io).
//
//  TURBO.  The cpu_clk domain runs at 14 MHz (STA: domain Fmax 17.7 MHz,
//  limited by the negedge BRAM reads, so 14 closes with a 26% margin; 12.5
//  and 14 both proven on hardware 2026-08-04).  14 IS THE CEILING: a 16 MHz
//  build passed STA everywhere (+8 ns setup in this domain) and still
//  crashed the board -- rtl/cpu_pace.sv's header carries the post-mortem.
//  CPU speed is set by SYSCTL[2] via rtl/cpu_pace.sv: 0 (reset default) paces
//  the CPU's clock-enable to exactly 8.000 MHz average for compatibility with
//  every number measured so far; 1 advances every cycle = 14 MHz.  The OSD
//  "CPU Turbo" switch (CONF_STR O6) ORs over the software bit, giving a
//  persistent whole-machine 14 MHz without touching any software.  The
//  domain CLOCK never switches, so peripherals, the ms timer and the VERA
//  strobe timing are mode-independent.  A paced CPU HOLDS a bus state for
//  extra cycles, so every level-sensitive commit point in the machine takes
//  `cpu_adv` (advance = cpu_rdy & pace) instead of cpu_rdy -- grep cpu_adv
//  below; flat_sdram and sd_block grew an `adv` port for the same reason.
//
//  NOTE the emu-level PLL instance must stay named `pll` with inner instance
//  `pll_inst`: sys/sys_top.sdc matches the path emu|pll|pll_inst|altera_pll_i
//  to decouple the core clocks from the HDMI/audio clock groups.
//
//  SCOPE OF THIS BUILD (bring-up).  Deliberately not yet wired, each of which
//  is a straight lift from the X16 core when wanted:
//    * guest SD card (spi_sd_master100 + sd_card + hps_io virtual block dev)
//    * RTC / NVRAM backing (rtc_x16, nvram_backer)
//    * serial card (x16_serial_card)
//    * SDRAM bitmap layer (bitmap_regs, bitmap_engine)
//  See doc/PORTING.md for the order these should come back in.
//============================================================================

module emu
(
    `include "sys/emu_ports.vh"
);

    // ========================================================================
    // Clock generation
    // ========================================================================
    wire pll_locked;
    wire pix_clk;       // VERA pixel clock            -- 25.0 MHz
    wire cpu_clk;       // CPU + VIA + SMC              -- 14.0 MHz (see TURBO)
    wire clk8_spare;    // spare: the pre-turbo CPU clock --  8.0 MHz
    wire sdram_clk;     // SDRAM controller + hps_io    -- 100.0 MHz

    // FREE-RUN the core PLL (rst tied 0).  hps_io and the pixel clock are both
    // driven from it, so feeding the framework RESET into .rst stops the OSD
    // and HDMI along with the core and can deadlock the re-lock/handshake race
    // on a slow-corner board.  Reset is handled internally instead: every
    // domain's reset gates on (~RESET & pll_locked).
    pll pll (
        .refclk   (CLK_50M),
        .rst      (1'b0),
        .outclk_0 (pix_clk),
        .outclk_1 (cpu_clk),      // 14.0 MHz -- retuned from 12.5 (round 2)
        .outclk_2 (clk8_spare),   //  8.0 MHz -- was cpu_clk before turbo
        .outclk_3 (sdram_clk),
        .locked   (pll_locked)
    );

    // ========================================================================
    // Resets
    // ========================================================================
    wire dl_hold;                    // HPS image download in progress
    wire smc_reset_req, smc_nmi_req, smc_power_off_req;
    wire [7:0] smc_act_led;

    // SMC reset request (I2C command $02; power-off $01 is treated as a reset
    // -- there is no PSU to switch here).  smc_x16 emits a 1-cycle cpu_clk
    // pulse; stretch it so every domain's synchronizer sees it and so the SMC
    // itself resets and drops the request.
    reg [7:0] smc_rst_stretch = 8'd0;
    always @(posedge cpu_clk)
        if (smc_reset_req | smc_power_off_req) smc_rst_stretch <= 8'd255;
        else if (smc_rst_stretch != 8'd0)      smc_rst_stretch <= smc_rst_stretch - 8'd1;
    wire smc_reset_hold = (smc_rst_stretch != 8'd0);

    wire sys_rst_n = ~RESET & pll_locked & ~dl_hold & ~smc_reset_hold;

    // Memory-side reset EXCLUDES the download hold: flat_sdram must stay alive
    // (refresh + loader port) while an image streams in with the CPU parked.
    wire mem_rst_n_raw = ~RESET & pll_locked;
    reg [1:0] mem_rst_sync = 2'b00;
    always @(posedge cpu_clk or negedge mem_rst_n_raw)
        if (!mem_rst_n_raw) mem_rst_sync <= 2'b00;
        else                mem_rst_sync <= {mem_rst_sync[0], 1'b1};
    wire mem_reset_n = mem_rst_sync[1];

    reg [1:0] cpu_rst_sync = 2'b00;
    always @(posedge cpu_clk or negedge sys_rst_n)
        if (!sys_rst_n) cpu_rst_sync <= 2'b00;
        else            cpu_rst_sync <= {cpu_rst_sync[0], 1'b1};
    wire cpu_reset_n = cpu_rst_sync[1];

    // ========================================================================
    // HPS_IO
    // ========================================================================
    localparam CONF_STR = {
        "X816;;",
        // "SC" rather than plain "S": MiSTer Main only REMEMBERS and
        // auto-remounts SC entries at core start (user_io.cpp checks 'S','C'),
        // which is what makes the last-mounted image come back by itself.
        // A plain "S" would mount from the OSD but forget it on the next boot.
        "SC0,IMG,Mount SD;",
        "-;",
        "F1,BIN,Load Image;",
        "-;",
        // VERA2: the SDRAM bitmap layer (doc/VERA2.md). Master switch, default
        // OFF -- with it off the core is bit-identical to stock VERA, and the
        // $9F61 ID register reads $00 so software can feature-detect.
        "O5,VERA2 Bitmap Layer,Off,On;",
        // TURBO from the OSD: ORed with SYSCTL[2], so On forces 14 MHz from
        // power-on without any software involvement (boot.s's `stz
        // X816_SYSCTL` clears the SOFTWARE bit while dropping the overlay --
        // the OSD bit is immune).  Off leaves the machine software-controlled:
        // 8 MHz at reset, 14 when a program sets $9F80 bit 2.  The setting
        // persists in the core's .cfg like every OSD option.
        "O6,CPU Turbo,Off (8MHz),On (14MHz);",
        "-;",
        "J1,A,B,X,Y,L,R,Select,Start;",
        "V,v0.1"
    };

    wire [127:0] status;
    wire  [1:0]  buttons;
    wire         forced_scandoubler;
    wire         direct_video;
    wire [10:0]  ps2_key;
    wire [24:0]  ps2_mouse;
    wire [15:0]  ps2_mouse_ext;
    wire [31:0]  joystick_0, joystick_1;
    wire         ioctl_download;
    wire         ioctl_wr;
    wire [26:0]  ioctl_addr;
    wire  [7:0]  ioctl_dout;
    wire [15:0]  ioctl_index;
    wire         ioctl_wait;

    // One virtual block device: the guest SD card (rtl/sd_block.sv).
    wire [31:0] sd_lba[1];
    wire  [5:0] sd_blk_cnt[1];  assign sd_blk_cnt[0]  = 6'd0;  // one block per request
    wire  [7:0] sd_buff_din[1];
    wire        sd_rd_w, sd_wr_w, sd_ack_w;
    wire  [8:0] sd_buff_addr;
    wire  [7:0] sd_buff_dout;
    wire        sd_buff_wr;
    wire        img_mounted;
    wire [63:0] img_size;

    // hps_io runs at 100 MHz.  At 8 MHz the FPGA->HPS readout direction
    // undersamples the HPS bus strobes; every working MiSTer core runs this
    // block in the 32-112 MHz range.  ps2_key/ps2_mouse are 2-FF synced into
    // cpu_clk below; everything else stays inside the 100 MHz domain.
    hps_io #(.CONF_STR(CONF_STR)) u_hps (
        .clk_sys           (sdram_clk),
        .HPS_BUS           (HPS_BUS),
        .buttons           (buttons),
        .status            (status),
        .forced_scandoubler(forced_scandoubler),
        .direct_video      (direct_video),
        .ps2_key           (ps2_key),
        .ps2_mouse         (ps2_mouse),
        .ps2_mouse_ext     (ps2_mouse_ext),
        .joystick_0        (joystick_0),
        .joystick_1        (joystick_1),
        .ioctl_download    (ioctl_download),
        .ioctl_wr          (ioctl_wr),
        .ioctl_addr        (ioctl_addr),
        .ioctl_dout        (ioctl_dout),
        .ioctl_index       (ioctl_index),
        .ioctl_wait        (ioctl_wait),
        .sd_lba            (sd_lba),
        .sd_blk_cnt        (sd_blk_cnt),
        .sd_rd             (sd_rd_w),
        .sd_wr             (sd_wr_w),
        .sd_ack            (sd_ack_w),
        .sd_buff_addr      (sd_buff_addr),
        .sd_buff_dout      (sd_buff_dout),
        .sd_buff_din       (sd_buff_din),
        .sd_buff_wr        (sd_buff_wr),
        .img_mounted       (img_mounted),
        .img_size          (img_size)
    );

    // ---- image download ----------------------------------------------------
    // ioctl_index encoding (MiSTer Main): an OSD file pick sends
    // {ext_index, slot[5:0]}, so "Load Image" is 6'd1 in the slot bits; the
    // bootN.rom auto-load loop instead sends N<<6, i.e. boot1.rom = 16'h0040.
    // Match both.  The file's byte offset IS the flat address, so an image
    // linked for $01:0000 is written with 24'h010000 + offset.
    // boot2.rom (index 16'h0080) is the KERNEL, loaded into the firmware
    // region at FW_BASE (doc/KERNEL.md §3). boot1.rom / OSD "Load Image" are
    // program images at PROG_BASE.
    wire dl_is_fw = (ioctl_index == 16'h0080);
    assign dl_hold = ioctl_download & ((ioctl_index[5:0] == 6'd1) |
                                       (ioctl_index      == 16'h0040) |
                                       dl_is_fw);
    // Programs load at PROG_BASE, not at raw file offset. Offset 0 would land
    // on the zero page and trample the direct page, the stack and the boot
    // stub's RAM copy. Bank $01 is the first SDRAM bank, so a loaded program
    // also runs in place from SDRAM rather than out of BRAM.
    //
    // boot/boot.s looks for the four-byte magic "X816" at FW_BASE first (the
    // kernel), then at PROG_BASE, and jumps to base+4; with neither it falls
    // back to the bands demo. Keep the three in step if any of this moves.
    localparam [23:0] PROG_BASE = 24'h01_0000;
    localparam [23:0] FW_BASE   = 24'hF0_0000;

    // 25-bit sum: carry out means the file ran past the top of the flat
    // space. Drop those bytes instead of letting them wrap onto bank $00
    // (zero page / stack), which is where a 24-bit add would put them.
    wire [24:0] dl_sum  = {1'b0, (dl_is_fw ? FW_BASE : PROG_BASE)}
                        + {1'b0, ioctl_addr[23:0]};
    wire [23:0] dl_addr = dl_sum[23:0];
    wire        dl_wr   = ioctl_wr & dl_hold & (ioctl_addr[26:24] == 3'd0)
                        & ~dl_sum[24];
    // Retained so the bank-0 loader path still works if PROG_BASE is ever moved
    // there; unreachable while PROG_BASE is in SDRAM.
    wire        dl_to_bank0 = (dl_addr[23:16] == 8'h00);
    wire        dl_to_fast  = (dl_addr[23:16] >= 8'h01) & (dl_addr[23:16] <= 8'h04);

    wire bank0_ld_busy, fast_ld_busy, sdram_ld_busy;
    assign ioctl_wait = bank0_ld_busy | fast_ld_busy | sdram_ld_busy;

    // ---- SD block device ---------------------------------------------------
    // Shares the loader write ports with the ioctl downloader.  They can never
    // be active together: dl_hold holds the CPU in reset for the whole
    // download, so no program is running to issue an SD command.
    wire        sd_busy;
    wire  [7:0] sd_reg_data;
    wire        sd_reg_sel;
    wire        sd_dma_wr;
    wire [23:0] sd_dma_addr;
    wire  [7:0] sd_dma_data;
    wire        sd_dma_to_bank0 = (sd_dma_addr[23:16] == 8'h00);
    wire        sd_dma_to_fast  = (sd_dma_addr[23:16] >= 8'h01)
                                & (sd_dma_addr[23:16] <= 8'h04);


    // ========================================================================
    // CPU
    // ========================================================================
    wire [23:0] cpu_a;
    wire [23:0] cpu_pc;
    wire  [7:0] cpu_di;
    wire  [7:0] cpu_do;
    wire        cpu_rwn;
    wire        cpu_sync;
    wire        cpu_bus_valid;
    wire        cpu_emu_mode;
    wire        cpu_i_flag;
    wire        cpu_wait_state;
    wire        cpu_rdy;              // driven by the stall network below

    // TURBO pacing (header, and rtl/cpu_pace.sv).  cpu_rdy is the STALL
    // network (VERA read stall, SDRAM, SD); pace_adv is the SPEED governor.
    // cpu_adv is their conjunction: "the CPU consumes its bus state at this
    // posedge".  Every level-sensitive commit point below takes cpu_adv, NOT
    // cpu_rdy -- with the pacer holding the CPU, cpu_rdy can be high for
    // cycles during which nothing must commit twice.
    wire pace_adv;
    wire cpu_adv = cpu_rdy & pace_adv;

    // Declared here, written by the SYSCTL block below -- declare-before-use,
    // the vera2 wires' lesson.
    reg sysctl_turbo = 1'b0;

    // OSD turbo (CONF_STR O6, status[6]) is quasi-static but crosses from
    // hps_io's 100 MHz domain; 2-FF sync it before it touches the CPU enable
    // cone.  Effective speed is the OR: either the OSD or software may engage
    // 14 MHz, and the pacer switches modes cleanly mid-run by design
    // (sim/tb_cpu_pace.v property 4).
    reg [1:0] osd_turbo_sync = 2'b00;
    always @(posedge cpu_clk) osd_turbo_sync <= {osd_turbo_sync[0], status[6]};
    wire osd_turbo   = osd_turbo_sync[1];
    wire turbo_en    = sysctl_turbo | osd_turbo;

    cpu_pace u_pace (
        .clk     (cpu_clk),
        .reset_n (cpu_reset_n),
        .turbo   (turbo_en),
        .adv_en  (pace_adv)
    );

    wire vera_irq_n, via1_irq_n, via2_irq_n, ym_irq_n;

    // VERA IRQ is generated in pix_clk -> 2-FF sync into cpu_clk.
    reg [1:0] vera_irq_sync = 2'b11;
    always @(posedge cpu_clk or negedge cpu_reset_n)
        if (!cpu_reset_n) vera_irq_sync <= 2'b11;
        else              vera_irq_sync <= {vera_irq_sync[0], vera_irq_n};

    // YM2151 timer IRQ lives in pix_clk too.
    reg [1:0] ym_irq_sync = 2'b11;
    always @(posedge cpu_clk or negedge cpu_reset_n)
        if (!cpu_reset_n) ym_irq_sync <= 2'b11;
        else              ym_irq_sync <= {ym_irq_sync[0], ym_irq_n};

    // via*_irq_n are already cpu_clk-synchronous.
    wire cpu_irq_n = vera_irq_sync[1] & via1_irq_n & via2_irq_n & ym_irq_sync[1];

    // SMC NMI request -> stretched low pulse on the edge-sensitive NMI input.
    reg [3:0] smc_nmi_stretch = 4'd0;
    always @(posedge cpu_clk or negedge cpu_reset_n)
        if (!cpu_reset_n)                 smc_nmi_stretch <= 4'd0;
        else if (smc_nmi_req)             smc_nmi_stretch <= 4'd15;
        else if (smc_nmi_stretch != 4'd0) smc_nmi_stretch <= smc_nmi_stretch - 4'd1;
    wire cpu_nmi_n = (smc_nmi_stretch == 4'd0);

    p65c816_flat_wrap u_cpu (
        .clk        (cpu_clk),
        .enable     (cpu_adv),
        .res_n      (cpu_reset_n),
        .irq_n      (cpu_irq_n),
        .nmi_n      (cpu_nmi_n),
        .abort_n    (1'b1),               // no ABORT source in this machine
        .r_w_n      (cpu_rwn),
        .sync       (cpu_sync),
        .addr       (cpu_a),
        .din        (cpu_di),
        .dout       (cpu_do),
        .pc         (cpu_pc),
        .emu_mode   (cpu_emu_mode),
        .i_flag     (cpu_i_flag),
        .wait_state (cpu_wait_state),
        .mlb        (),
        .bus_valid  (cpu_bus_valid)
    );

    // ========================================================================
    // Address decode  --  flat 24-bit
    // ========================================================================
    // Every chip select is qualified with dec_valid.  On the '816's internal
    // cycles A_OUT carries in-flight address math -- GHOST addresses that must
    // not reach I/O with read side effects (VERA's data-port auto-increment,
    // the VIA's flag clears) nor start an SDRAM access.
    //
    // WRITE cycles are exempt (the `| ~cpu_rwn` term): WE is asserted only on
    // true write cycles, and dropping a write whose VA flag mis-synthesises is
    // catastrophic -- on the X16 that exact bug made '816 STA abs,X writes
    // vanish on silicon while being perfect in RTL sim.  Ghost READS stay
    // fully gated.
    wire dec_valid = cpu_bus_valid | ~cpu_rwn;

    wire bank0     = (cpu_a[23:16] == 8'h00);
    wire io_page   = bank0 & (cpu_a[15:8] == 8'h9F);

    wire via1_cs   = dec_valid & io_page & (cpu_a[7:4] == 4'h0);   // $9F00-$9F0F
    wire via2_cs   = dec_valid & io_page & (cpu_a[7:4] == 4'h1);   // $9F10-$9F1F
    wire vera_cs   = dec_valid & io_page & (cpu_a[7:5] == 3'b001); // $9F20-$9F3F
    wire ym_cs     = dec_valid & io_page & (cpu_a[7:4] == 4'h4);   // $9F40-$9F4F
    wire sysctl_cs = dec_valid & io_page & (cpu_a[7:4] == 4'h8);   // $9F80-$9F8F
    wire timer_cs  = dec_valid & io_page & (cpu_a[7:4] == 4'h9) & (cpu_a[3:2] == 2'b00); // $9F90-$9F93
    wire vera2_cs  = dec_valid & io_page & (cpu_a[7:4] == 4'h6);   // $9F60-$9F6F

    // Boot ROM overlay: READ-ONLY shadow of $00:FF00-$00:FFFF.  Writes fall
    // through to the RAM underneath so the stub can copy itself down before
    // clearing SYSCTL[0] -- see boot/boot.s.
    wire rom_overlay_en;
    wire boot_page  = bank0 & (cpu_a[15:8] == 8'hFF);
    wire boot_sel   = dec_valid & boot_page & rom_overlay_en & cpu_rwn;

    wire bank0_cs   = dec_valid & bank0 & ~io_page;   // includes $FF00 for writes

    // Firmware write-protect (doc/KERNEL.md §3): banks $F0-$FF hold the
    // HPS-loaded kernel. CPU stores there are dropped -- no chip select, so
    // flat_sdram idles ready and the write silently vanishes, which is the
    // protection. Reads are unrestricted, and the HPS/SD-DMA loader ports
    // bypass this by construction (that is how the kernel arrives).
    wire fw_region  = (cpu_a[23:20] == 4'hF);

    // Banks $01-$04 are BRAM (rtl/fast_ram.sv).  That is where the HPS loader
    // drops a program, so a program's CODE is single-cycle without anything
    // being rebuilt -- measured 4.47x against SDRAM, doc/AUDIT.md 6.2.
    wire fast_region = (cpu_a[23:16] >= 8'h01) & (cpu_a[23:16] <= 8'h04);
    wire fast_cs     = dec_valid & fast_region;

    wire flat_cs    = dec_valid & ~bank0 & ~fast_region   // $05-$FF -> SDRAM
                    & ~(fw_region & ~cpu_rwn);        // ...minus firmware stores

    // ========================================================================
    // SYSCTL ($00:9F80)
    //   bit 0  boot ROM overlay enable.  Set at reset; software clears it once
    //          it has populated $FF00-$FFFF in RAM, after which bank 0 is 64 KB
    //          of uniform RAM and the vectors are patchable.
    //   bit 2  TURBO.  0 at reset: the CPU is paced to an exact 8.000 MHz
    //          average (rtl/cpu_pace.sv).  Write 1 for the full 14 MHz.
    //          Read-write, takes effect on the next cycle, switchable at any
    //          time -- the domain clock never changes, only the CPU's enable.
    //          The OSD "CPU Turbo" switch (status[6]) ORs over this bit:
    //          with it On the machine is 14 MHz regardless of what software
    //          writes here.  Read-back returns the EFFECTIVE speed
    //          (software bit OR OSD), so a program that asserts its speed
    //          sees the truth -- with the side effect that a read-modify-
    //          write under OSD-On copies 1 into the software bit, which is
    //          harmless: the machine was already at 14.
    // Read-back also exposes the CPU's live E flag (bit 1) so software can
    // assert that it really is in native mode.  cpu_wait_state is deliberately
    // NOT exposed here: it is high whenever the CPU is not advancing for any
    // reason, so a read of it can only ever return 0 -- the read itself commits
    // only on an advancing cycle.  It goes to LED_USER instead.
    //
    // This write commit is deliberately NOT gated by cpu_adv: a paced CPU
    // holds the write state for extra cycles and the same value lands each
    // time -- idempotent, the via65c22 write argument exactly.
    // ========================================================================
    reg sysctl_overlay = 1'b1;
    always @(posedge cpu_clk or negedge cpu_reset_n) begin
        if (!cpu_reset_n) begin
            sysctl_overlay <= 1'b1;
            sysctl_turbo   <= 1'b0;
        end else if (sysctl_cs && ~cpu_rwn && cpu_a[3:0] == 4'h0) begin
            sysctl_overlay <= cpu_do[0];
            sysctl_turbo   <= cpu_do[2];
        end
    end
    assign rom_overlay_en = sysctl_overlay;

    // Keyboard diagnostic counters, driven far below where the PS/2 sync lives
    // but declared here because the read mux just underneath uses them.
    reg [7:0] dbg_arrive_r, dbg_push_r, dbg_drop_r;

    // $9F80 is SYSCTL proper; $9F81-$9F8C belong to the SD block device, and
    // $9F8D-$9F8F are the keyboard diagnostic counters.
    wire [7:0] sysctl_data = (cpu_a[3:0] == 4'h0)
                           ? {5'b0, turbo_en, cpu_emu_mode, sysctl_overlay}
                           : sd_reg_sel ? sd_reg_data
                           : (cpu_a[3:0] == 4'hD) ? dbg_arrive_r
                           : (cpu_a[3:0] == 4'hE) ? dbg_push_r
                           : (cpu_a[3:0] == 4'hF) ? dbg_drop_r
                                        : 8'h00;

    // ========================================================================
    // Free-running millisecond timer ($00:9F90-$00:9F93, little-endian)
    //
    // The kernel's monotonic clock (doc/KERNEL.md 5.6).  It is a separate
    // module for one reason: everything else in this file can only be proven
    // by compiling a bitstream, and the property that matters here -- that the
    // count keeps advancing while cpu_rdy is LOW, so an SD transfer does not
    // steal time (doc/AUDIT.md L-4) -- is exactly the one a screen cannot
    // show.  sim/tb_ms_timer.v drives it directly instead.  rtl/ms_timer.sv
    // carries the full argument.
    //
    // The divider is passed explicitly rather than left to the module's
    // default so that tools/contract.py can check THIS instantiation: a wrong
    // override here would leave TIME_GET answering confidently in the wrong
    // unit, which nothing downstream could detect.
    // ========================================================================
    wire [7:0] timer_data;

    ms_timer #(.TIMER_DIV(14'd14000)) u_timer (
        .clk     (cpu_clk),
        .reset_n (cpu_reset_n),
        .cs      (timer_cs),
        .rd      (cpu_rwn),
        .cpu_rdy (cpu_adv),
        .addr    (cpu_a[1:0]),
        .rd_data (timer_data)
    );

    sd_block u_sd (
        .clk          (cpu_clk),
        .reset_n      (cpu_reset_n),
        .cs           (sysctl_cs),
        .we           (~cpu_rwn),
        .adv          (cpu_adv),
        .addr         (cpu_a[3:0]),
        .wr_data      (cpu_do),
        .rd_data      (sd_reg_data),
        .rd_sel       (sd_reg_sel),
        .busy         (sd_busy),

        .sdram_clk    (sdram_clk),
        .sd_lba       (sd_lba[0]),
        .sd_rd        (sd_rd_w),
        .sd_wr        (sd_wr_w),
        .sd_ack       (sd_ack_w),
        .sd_buff_addr (sd_buff_addr),
        .sd_buff_dout (sd_buff_dout),
        .sd_buff_din  (sd_buff_din[0]),
        .sd_buff_wr   (sd_buff_wr),
        .img_mounted  (img_mounted),
        .img_size     (img_size),

        .dma_wr       (sd_dma_wr),
        .dma_addr     (sd_dma_addr),
        .dma_data     (sd_dma_data),
        .dma_busy     (bank0_ld_busy | fast_ld_busy | sdram_ld_busy)
    );


    // ========================================================================
    // Memory
    // ========================================================================
    wire [7:0] bank0_data, boot_data, sdram_data, fast_data;
    wire       sdram_ready;

    // Byte offset within the 256 KB: bank $01 is offset 0, so the bank number
    // less one supplies the top two bits.
    wire [7:0]  fast_bank_m1 = cpu_a[23:16] - 8'd1;
    wire [17:0] fast_addr    = {fast_bank_m1[1:0], cpu_a[15:0]};

    wire [7:0]  fast_ld_bank_m1 = (sd_dma_wr ? sd_dma_addr[23:16]
                                             : dl_addr[23:16]) - 8'd1;
    wire [17:0] fast_ld_addr    = {fast_ld_bank_m1[1:0],
                                   sd_dma_wr ? sd_dma_addr[15:0] : dl_addr[15:0]};

    fast_ram u_fast (
        .clk     (cpu_clk),
        .addr    (fast_addr),
        .cs      (fast_cs),
        .we      (~cpu_rwn),
        .wr_data (cpu_do),
        .rd_data (fast_data),
        .ld_clk  (sdram_clk),
        .ld_wr   ((dl_wr & dl_to_fast) | (sd_dma_wr & sd_dma_to_fast)),
        .ld_addr (fast_ld_addr),
        .ld_data (sd_dma_wr ? sd_dma_data : ioctl_dout),
        .ld_busy (fast_ld_busy)
    );

    bank0_ram u_bank0 (
        .clk     (cpu_clk),
        .addr    (cpu_a[15:0]),
        .cs      (bank0_cs),
        .we      (~cpu_rwn),
        .wr_data (cpu_do),
        .rd_data (bank0_data),
        .ld_clk  (sdram_clk),
        .ld_wr   ((dl_wr &  dl_to_bank0) | (sd_dma_wr &  sd_dma_to_bank0)),
        .ld_addr (sd_dma_wr ? sd_dma_addr[15:0] : dl_addr[15:0]),
        .ld_data (sd_dma_wr ? sd_dma_data       : ioctl_dout),
        .ld_busy (bank0_ld_busy)
    );

    boot_rom u_boot (
        .clk     (cpu_clk),
        .addr    (cpu_a[7:0]),
        .rd_data (boot_data)
    );

    flat_sdram u_flat (
        .clk        (cpu_clk),
        .reset_n    (mem_reset_n),        // stays alive through a download
        .cs         (flat_cs),
        .we         (~cpu_rwn),
        .adv        (cpu_adv),
        .byte_addr  (cpu_a),
        .wr_data    (cpu_do),
        .rd_data    (sdram_data),
        .ready      (sdram_ready),

        .sdram_clk  (sdram_clk),
        .ld_wr      ((dl_wr & ~dl_to_bank0 & ~dl_to_fast)
                     | (sd_dma_wr & ~sd_dma_to_bank0 & ~sd_dma_to_fast)),
        .ld_addr    (sd_dma_wr ? sd_dma_addr : dl_addr),
        .ld_data    (sd_dma_wr ? sd_dma_data : ioctl_dout),
        .ld_busy    (sdram_ld_busy),

        // Framebuffer stream -- the VERA2 scanout engine's line fetch.
        .fb_go      (v2_fb_go),
        .fb_base    (v2_fb_base),
        .fb_len     (v2_fb_len),
        .fb_valid   (v2_fb_valid),
        .fb_word    (v2_fb_word),
        .fb_done    (v2_fb_done),

        .SDRAM_A    (SDRAM_A),
        .SDRAM_DQ   (SDRAM_DQ),
        .SDRAM_BA   (SDRAM_BA),
        .SDRAM_nCS  (SDRAM_nCS),
        .SDRAM_nWE  (SDRAM_nWE),
        .SDRAM_nRAS (SDRAM_nRAS),
        .SDRAM_nCAS (SDRAM_nCAS),
        .SDRAM_CKE  (SDRAM_CKE),
        .SDRAM_CLK  (SDRAM_CLK),
        .SDRAM_DQML (SDRAM_DQML),
        .SDRAM_DQMH (SDRAM_DQMH)
    );

    // ========================================================================
    // VERA  --  CPU bus pipeline
    //
    // Inherited from the X16 core and rescaled for the cpu_clk domain (14 MHz
    // since the second turbo step; the cycle counts below were validated on
    // hardware at 12.5 and again at 14): the pipeline absorbs the cpu_clk vs
    // pix_clk skew so VERA sees stable address/data/strobe for the whole
    // transaction.  VERA's top.v 3-FF syncs the strobes at 25 MHz and
    // EDGE-detects them (capture on the synced rising edge, commit on the
    // falling edge), so a wider or held strobe is still exactly one bus
    // event -- that property is what both the rescale and the TURBO pacer
    // lean on.
    //
    //   WRITES are posted: the CPU advances immediately and a fixed 3-stage
    //   q-window presents the strobe for 214 ns (240 at 12.5 MHz, 250 in the
    //   8 MHz design), with data/drive chained one stage past the strobe.  A
    //   paced CPU holds vera_write for extra cycles; the q-chain just shifts
    //   the widened pulse -- still one falling edge, same data throughout.
    //   The window must NOT be widened past 3 stages: two turbo writes land
    //   as little as 4 cpu cycles apart, and a 4-stage OR-window would bridge
    //   the gap between them -- no falling edge, two writes fused into one.
    //
    //   READS stall the CPU (3 cycles, 214 ns of strobe -- 240 at 12.5 MHz,
    //   was 2 cycles at 8) and the strobe is delayed-start, LIVE-END:
    //   asserted from one cycle into the read until the CPU actually consumes
    //   it.  214 ns is the thinnest margin at 14 MHz: worst case the 25 MHz
    //   sync needs 3 pix cycles to see the rise plus one to present data =
    //   ~160 ns before extbus_d is meaningful, leaving ~54 ns -- proven on
    //   hardware 2026-08-04.  (The 16 MHz attempt widened this stall to 4
    //   cycles and still crashed for reasons STA could not see; the revert
    //   restores the proven 3.)  Live-end matters twice over.  With the
    //   pacer holding the CPU past the stall release, the strobe stays low
    //   until the delayed sample -- VERA keeps driving data (top.v drives
    //   extbus_d for as long as rd_n is low).  And it RELEASES the instant
    //   the CPU moves on, so the data-port auto-increment (which VERA
    //   commits on the falling edge) lands ~390 ns before the earliest
    //   possible next data-port read -- more margin than the 8 MHz design had.
    //
    // Two things here are NOT simplifiable.  vera_access must not be gated by
    // cpu_rdy (gating kills it during the read stall), and the write strobes
    // must use the LATCHED q-flags rather than live cpu_rwn.
    // ========================================================================
    wire vera_access = vera_cs;
    wire vera_write  = vera_access & ~cpu_rwn;
    wire vera_read   = vera_access &  cpu_rwn;

    reg        vera_write_q1,  vera_write_q2,  vera_write_q3,  vera_write_q4;
    reg        vera_read_q1;
    reg  [7:0] cpu_do_q1,      cpu_do_q2,      cpu_do_q3,      cpu_do_q4;
    reg  [4:0] cpu_a5_q1;

    always @(posedge cpu_clk or negedge cpu_reset_n) begin
        if (!cpu_reset_n) begin
            vera_write_q1  <= 1'b0;  vera_write_q2  <= 1'b0;
            vera_write_q3  <= 1'b0;  vera_write_q4  <= 1'b0;
            vera_read_q1   <= 1'b0;
            cpu_do_q1      <= 8'h00; cpu_do_q2      <= 8'h00;
            cpu_do_q3      <= 8'h00; cpu_do_q4      <= 8'h00;
            cpu_a5_q1      <= 5'h00;
        end else begin
            vera_write_q1  <= vera_write;
            vera_write_q2  <= vera_write_q1;
            vera_write_q3  <= vera_write_q2;
            vera_write_q4  <= vera_write_q3;
            vera_read_q1   <= vera_read;
            if (vera_access) cpu_a5_q1 <= cpu_a[4:0];
            if (vera_write)  cpu_do_q1 <= cpu_do;
            cpu_do_q2      <= cpu_do_q1;
            cpu_do_q3      <= cpu_do_q2;
            cpu_do_q4      <= cpu_do_q3;
        end
    end

    wire vera_write_bw  = vera_write_q1 | vera_write_q2 | vera_write_q3;
    wire vera_read_bw   = vera_read & vera_read_q1;          // live-end
    wire vera_access_bw = vera_write_bw | vera_read_bw;

    reg [1:0] vera_read_stall = 2'h0;
    always @(posedge cpu_clk or negedge cpu_reset_n) begin
        if (!cpu_reset_n)     vera_read_stall <= 2'h0;
        else if (vera_read) begin
            if (vera_read_stall != 2'd3) vera_read_stall <= vera_read_stall + 2'd1;
        end else              vera_read_stall <= 2'h0;
    end

    // Global stall.  flat_sdram.ready idles high when unselected, so a plain
    // AND combines the VERA read stall with the SDRAM access stall.
    // sd_busy freezes the CPU for the whole SD transfer.  That is what makes
    // the DMA safe without arbitration -- the CPU issues no memory access
    // while it runs -- and it is why software never has to poll: the
    // instruction after the command write executes once the transfer is done.
    assign cpu_rdy = (~vera_read | (vera_read_stall >= 2'd3)) & sdram_ready & ~sd_busy;

    wire [4:0] vera_a_out = vera_access ? cpu_a[4:0] : cpu_a5_q1;
    wire [7:0] vera_d_out = vera_write    ? cpu_do    :
                            vera_write_q1 ? cpu_do_q1 :
                            vera_write_q2 ? cpu_do_q2 :
                            vera_write_q3 ? cpu_do_q3 :
                                            cpu_do_q4;

    wire [7:0] vera_extbus_d;
    wire       vera_d_drive = vera_write | vera_write_q1 | vera_write_q2
                            | vera_write_q3 | vera_write_q4;
    assign vera_extbus_d = vera_d_drive ? vera_d_out : 8'hZZ;

    wire [3:0] vera_r, vera_g, vera_b;
    wire       vera_hs, vera_vs, vera_de, vera_opaque;
    wire       vera_audio_lrck, vera_audio_bck, vera_audio_data;

    top u_vera (
        .clk25           (pix_clk),

        .extbus_cs_n     (~vera_access_bw),
        .extbus_rd_n     (~vera_read_bw),
        .extbus_wr_n     (~vera_write_bw),
        .extbus_a        (vera_a_out),
        .extbus_d        (vera_extbus_d),
        .extbus_irq_n    (vera_irq_n),

        .vga_r           (vera_r),
        .vga_g           (vera_g),
        .vga_b           (vera_b),
        .vga_hsync       (vera_hs),
        .vga_vsync       (vera_vs),
        .vga_de          (vera_de),
        .vga_opaque      (vera_opaque),

        // VERA's own SPI master is unused; the guest SD is a later step.
        .spi_sck         (),
        .spi_mosi        (),
        .spi_miso        (1'b1),
        .spi_ssel_n_sd   (),

        .audio_lrck      (vera_audio_lrck),
        .audio_bck       (vera_audio_bck),
        .audio_data      (vera_audio_data),

        .dbg_wrdata_r    (),
        .dbg_wraddr_r    (),
        .dbg_do_write    (),
        .dbg_video_mode  (),
        .dbg_dcsel       (),
        .spi_busy_out    (),
        .spi_autotx_out  (),

        .composite_luma  (),
        .composite_chroma()
    );

    // ========================================================================
    // VERA2 -- the SDRAM bitmap layer (doc/VERA2.md)
    //
    // 640x480 linear framebuffer scanned out of the $E0:0000 window in SDRAM
    // and composited over VERA. VERA is untouched: it still owns the video
    // TIMING (hsync/vsync/de), and the bitmap rides its raster.
    //
    // Off by default at both ends -- the OSD master switch AND the software
    // enable bit must agree -- so a core with the switch off is bit-identical
    // to stock.
    // ========================================================================
    // Declared before the instances that connect them: an undeclared name in a
    // port connection becomes an implicit ONE-BIT wire, which would silently
    // truncate fb_base from 24 bits to 1.
    wire        v2_fb_go;
    wire [23:0] v2_fb_base;
    wire [10:0] v2_fb_len;
    wire        v2_fb_valid;
    wire [15:0] v2_fb_word;
    wire        v2_fb_done;

    wire       v2_enable, v2_passthru;
    wire [1:0] v2_mode;
    wire [19:0] v2_disp_base;
    wire  [7:0] vera2_data;
    wire        v2_pal_we;
    wire  [7:0] v2_pal_idx;
    wire [11:0] v2_pal_data;
    wire  [3:0] v2_r, v2_g, v2_b;
    wire        v2_active;
    wire        v2_master = status[5];

    vera2_regs u_vera2_regs (
        .clk          (cpu_clk),
        .reset_n      (cpu_reset_n),
        .cs           (vera2_cs),
        .rwn          (cpu_rwn),
        .cpu_rdy      (cpu_adv),
        .addr         (cpu_a[3:0]),
        .di           (cpu_do),
        .do_o         (vera2_data),

        .master_en    (v2_master),
        .bmp_enable   (v2_enable),
        .bmp_mode     (v2_mode),
        .bmp_passthru (v2_passthru),
        .disp_base    (v2_disp_base),

        .pal_we       (v2_pal_we),
        .pal_idx      (v2_pal_idx),
        .pal_data     (v2_pal_data)
    );

    vera2_engine u_vera2 (
        .pix_clk    (pix_clk),
        .reset_n    (cpu_reset_n),
        .enable     (v2_enable),
        .mode       (v2_mode),
        .de         (vera_de),
        .vs         (vera_vs),
        .disp_base  (v2_disp_base),
        .bmp_r      (v2_r),
        .bmp_g      (v2_g),
        .bmp_b      (v2_b),
        .bmp_active (v2_active),

        .pal_clk    (cpu_clk),
        .pal_we     (v2_pal_we),
        .pal_idx    (v2_pal_idx),
        .pal_data   (v2_pal_data),

        .sdram_clk  (sdram_clk),
        .fb_go      (v2_fb_go),
        .fb_base    (v2_fb_base),
        .fb_len     (v2_fb_len),
        .fb_valid   (v2_fb_valid),
        .fb_word    (v2_fb_word),
        .fb_done    (v2_fb_done)
    );

    // Composition. The bitmap replaces VERA's pixel wherever it is active;
    // with passthru set, VERA's OPAQUE pixels (sprites, the mouse pointer)
    // come back over the top, which is what keeps a hardware cursor usable.
    wire show_bmp = v2_active & ~(v2_passthru & vera_opaque);
    wire [3:0] out_r = show_bmp ? v2_r : vera_r;
    wire [3:0] out_g = show_bmp ? v2_g : vera_g;
    wire [3:0] out_b = show_bmp ? v2_b : vera_b;

    // ========================================================================
    // IKAOPM (YM2151)
    //
    // Clocking and handshake carried over from the X16 core.  EMUCLK = pix_clk
    // with a /7 clock enable = 3.5714 MHz phiM (-0.23%, ~4 cents flat); the
    // CPU bus is crossed by a toggle handshake rather than sampled raw, and
    // reads return a synced status with the write-pending flag OR'd into BUSY
    // so a busy-poll issued right after a write cannot outrun the handshake.
    // ========================================================================
    wire        ym_wr = ym_cs & ~cpu_rwn;
    wire [15:0] ym_emu_r, ym_emu_l;
    wire  [7:0] ym_od;

    reg [1:0] ymrst_sync = 2'b00;
    always @(posedge pix_clk or negedge sys_rst_n)
        if (!sys_rst_n) ymrst_sync <= 2'b00;
        else            ymrst_sync <= {ymrst_sync[0], 1'b1};
    wire ym_reset_n = ymrst_sync[1];

    reg [2:0] ym_div = 3'd0;
    always @(posedge pix_clk) ym_div <= (ym_div == 3'd6) ? 3'd0 : ym_div + 3'd1;
    wire ym_pcen_n = (ym_div != 3'd0);

    // cpu-domain write capture: one capture per bus-write edge
    reg       ym_req_t = 1'b0;
    reg       ym_wr_d  = 1'b0;
    reg       ym_wa0   = 1'b0;
    reg [7:0] ym_wdat  = 8'h00;
    always @(posedge cpu_clk) begin
        ym_wr_d <= ym_wr;
        if (ym_wr & ~ym_wr_d) begin
            ym_wa0   <= cpu_a[0];
            ym_wdat  <= cpu_do;
            ym_req_t <= ~ym_req_t;
        end
    end

    reg [2:0] ym_req_s = 3'b000;
    always @(posedge pix_clk) ym_req_s <= {ym_req_s[1:0], ym_req_t};
    wire ym_req_edge = ym_req_s[2] ^ ym_req_s[1];

    reg       ym_ack_t  = 1'b0;
    reg       ym_bus_wr = 1'b0;
    reg [4:0] ym_hold   = 5'd0;
    reg       ym_a0_r   = 1'b0;
    reg [7:0] ym_d_r    = 8'h00;
    reg [7:0] ym_status = 8'h00;
    // After a DATA write (A0=1), hold the busy shadow until the OPM's own BUSY
    // flag is seen rising then falling: IKAOPM silently drops a data write
    // issued while the previous one is unconsumed, exactly like the real chip.
    reg [1:0] ym_post = 2'd0;
    reg [8:0] ym_tmo  = 9'd0;
    always @(posedge pix_clk) begin
        case (ym_post)
        2'd0: begin
            ym_status <= ym_od;              // idle = continuous status capture
            if (ym_req_edge) begin
                ym_a0_r   <= ym_wa0;
                ym_d_r    <= ym_wdat;
                ym_bus_wr <= 1'b1;
                ym_hold   <= 5'd15;          // 16 pix cycles = 640 ns > 2 phiM
                ym_post   <= 2'd1;
            end
        end
        2'd1: begin
            if (ym_hold != 5'd0) ym_hold <= ym_hold - 5'd1;
            else begin
                ym_bus_wr <= 1'b0;
                if (ym_a0_r) begin
                    ym_post <= 2'd2;
                    ym_tmo  <= 9'd200;       // ~8 us guard for the busy rise
                end else begin
                    ym_ack_t <= ~ym_ack_t;
                    ym_post  <= 2'd0;
                end
            end
        end
        2'd2: begin
            ym_tmo <= ym_tmo - 9'd1;
            if (ym_od[7]) begin
                ym_post <= 2'd3;
                ym_tmo  <= 9'd500;           // ~20 us >= real busy duration
            end else if (ym_tmo == 9'd0) begin
                ym_ack_t <= ~ym_ack_t;
                ym_post  <= 2'd0;
            end
        end
        2'd3: begin
            ym_tmo <= ym_tmo - 9'd1;
            if (!ym_od[7] || ym_tmo == 9'd0) begin
                ym_ack_t <= ~ym_ack_t;
                ym_post  <= 2'd0;
            end
        end
        endcase
    end

    reg [1:0] ym_ack_s    = 2'b00;
    reg [7:0] ym_status_s = 8'h00, ym_status_c = 8'h00;
    always @(posedge cpu_clk) begin
        ym_ack_s    <= {ym_ack_s[0], ym_ack_t};
        ym_status_s <= ym_status;
        ym_status_c <= ym_status_s;
    end
    wire       ym_pending = ym_req_t ^ ym_ack_s[1];
    wire [7:0] ym_rd_data = {ym_status_c[7] | ym_pending, ym_status_c[6:0]};

    IKAOPM #(
        .FULLY_SYNCHRONOUS (1),
        .FAST_RESET        (1),
        .USE_BRAM          (0)
    ) u_ym2151 (
        .i_EMUCLK      (pix_clk),
        .i_phiM_PCEN_n (ym_pcen_n),
        .i_IC_n        (ym_reset_n),
        .i_CS_n        (1'b0),                    // always selected (see FSM)
        .i_RD_n        (ym_bus_wr),               // idle: continuous status read
        .i_WR_n        (~ym_bus_wr),
        .i_A0          (ym_bus_wr ? ym_a0_r : 1'b0),
        .i_D           (ym_d_r),
        .o_D           (ym_od),
        .o_D_OE        (),
        .o_CT1         (),
        .o_CT2         (),
        .o_IRQ_n       (ym_irq_n),
        .o_SH1         (),
        .o_SH2         (),
        .o_SO          (),
        .o_EMU_R       (ym_emu_r),
        .o_EMU_L       (ym_emu_l),
        .o_EMU_R_SAMPLE(),
        .o_EMU_L_SAMPLE()
    );

    // ========================================================================
    // VIA #1  --  SNES gamepads + the internal I2C bus to the SMC
    // ========================================================================
    wire [7:0] via1_data;
    wire [7:0] via1_pa_in, via1_pa_out, via1_pa_oe;
    wire [7:0] via1_pb_in, via1_pb_out, via1_pb_oe;

    // I2C: VIA1 PA[1] = SCL, PA[0] = SDA, open-drain, combined with the SMC.
    wire smc_sda_drv_low;
    wire via_sda_drv_low = via1_pa_oe[0] & ~via1_pa_out[0];
    wire via_scl_drv_low = via1_pa_oe[1] & ~via1_pa_out[1];
    wire bus_sda = ~(via_sda_drv_low | smc_sda_drv_low);
    wire bus_scl = ~via_scl_drv_low;

    // MiSTer pads arrive in the 100 MHz hps_io domain as quasi-static button
    // levels -> 2-FF sync into cpu_clk.
    reg [11:0] joy0_s1, joy0_s2, joy1_s1, joy1_s2;
    always @(posedge cpu_clk) begin
        joy0_s1 <= joystick_0[11:0];  joy0_s2 <= joy0_s1;
        joy1_s1 <= joystick_1[11:0];  joy1_s2 <= joy1_s1;
    end

    wire snes_latch = via1_pa_out[2] | ~via1_pa_oe[2];   // pulled up when undriven
    wire snes_clk   = via1_pa_out[3] | ~via1_pa_oe[3];
    wire snes_data1, snes_data2;

    snes_pad u_pad1 (
        .clk(cpu_clk), .reset_n(cpu_reset_n),
        .joy(joy0_s2), .latch(snes_latch), .jclk(snes_clk), .data(snes_data1)
    );
    snes_pad u_pad2 (
        .clk(cpu_clk), .reset_n(cpu_reset_n),
        .joy(joy1_s2), .latch(snes_latch), .jclk(snes_clk), .data(snes_data2)
    );

    assign via1_pa_in[0]   = bus_sda;
    assign via1_pa_in[1]   = bus_scl;
    assign via1_pa_in[3:2] = via1_pa_out[3:2] | ~via1_pa_oe[3:2];
    assign via1_pa_in[4]   = 1'b1;          // pad #4 absent
    assign via1_pa_in[5]   = 1'b1;          // pad #3 absent
    assign via1_pa_in[6]   = snes_data2;
    assign via1_pa_in[7]   = snes_data1;
    assign via1_pb_in[7:6] = 2'b11;
    assign via1_pb_in[5:0] = via1_pb_out[5:0] | ~via1_pb_oe[5:0];

    via65c22 u_via1 (
        .clk     (cpu_clk),
        .reset_n (cpu_reset_n),
        .cs      (via1_cs),
        .rwn     (cpu_rwn),
        .enable  (cpu_adv),
        .addr    (cpu_a[3:0]),
        .di      (cpu_do),
        .do_o    (via1_data),
        .pa_in   (via1_pa_in),
        .pa_out  (via1_pa_out),
        .pa_oe   (via1_pa_oe),
        .pb_in   (via1_pb_in),
        .pb_out  (via1_pb_out),
        .pb_oe   (via1_pb_oe),
        .ca1_in  (1'b0),
        .ca2_in  (1'b0),
        .cb1_in  (1'b0),
        .cb2_in  (1'b0),
        .ca2_out (), .ca2_oe (),
        .cb1_out (), .cb1_oe (),
        .cb2_out (), .cb2_oe (),
        .irq_n   (via1_irq_n)
    );

    // ========================================================================
    // VIA #2  --  user port, left floating/pulled-up like the stock machine
    // ========================================================================
    wire [7:0] via2_data;
    wire [7:0] via2_pa_in, via2_pa_out, via2_pa_oe;
    wire [7:0] via2_pb_in, via2_pb_out, via2_pb_oe;

    assign via2_pa_in = via2_pa_out | ~via2_pa_oe;
    assign via2_pb_in = via2_pb_out | ~via2_pb_oe;

    via65c22 u_via2 (
        .clk     (cpu_clk),
        .reset_n (cpu_reset_n),
        .cs      (via2_cs),
        .rwn     (cpu_rwn),
        .enable  (cpu_adv),
        .addr    (cpu_a[3:0]),
        .di      (cpu_do),
        .do_o    (via2_data),
        .pa_in   (via2_pa_in),
        .pa_out  (via2_pa_out),
        .pa_oe   (via2_pa_oe),
        .pb_in   (via2_pb_in),
        .pb_out  (via2_pb_out),
        .pb_oe   (via2_pb_oe),
        .ca1_in  (1'b0),
        .ca2_in  (1'b0),
        .cb1_in  (1'b0),
        .cb2_in  (1'b0),
        .ca2_out (), .ca2_oe (),
        .cb1_out (), .cb1_oe (),
        .cb2_out (), .cb2_oe (),
        .irq_n   (via2_irq_n)
    );

    // ========================================================================
    // Keyboard / mouse: hps_io ps2_key -> ps2_to_smc_bridge -> smc_x16 (I2C $42)
    // ========================================================================
    wire [7:0] smc_uart_byte;
    wire       smc_uart_byte_valid;

    // ps2_key/ps2_mouse originate in the 100 MHz domain.  Bit [10] / bit [24]
    // is a toggle marking each new event and the payload changes WITH it.
    //
    // This used to be a plain 11-bit vector 2-FF sync, justified on the grounds
    // that the payload is stable between events (milliseconds apart).  That
    // reasoning is wrong, and the bug it hides is exactly the reported one:
    // keys that are typed but never arrive.  The hazard is not the gap BETWEEN
    // events, it is the instant of the transition.  Every bit crosses at once
    // and each resolves independently, so the destination can latch the NEW
    // toggle beside a STALE `pressed` bit -- a make recorded as a break, or a
    // break as a make.  A lost make is a keystroke that never happened; a
    // spurious break explains a RELEASE count running ahead of PRESS, which is
    // what the hardware measurement showed (20 presses against 22 releases).
    //
    // The correct pattern is to synchronise the FLAG alone and read the DATA
    // only once the flag has been seen, by which point the payload has been
    // settled for milliseconds.  Two extra clocks is enormous margin at 8 MHz.
    reg        ktog_s1, ktog_s2, ktog_s3;
    reg  [9:0] kpay_r;
    reg        kout_tog;
    reg  [1:0] kdelay;
    always @(posedge cpu_clk or negedge cpu_reset_n) begin
        if (!cpu_reset_n) begin
            ktog_s1 <= 1'b0; ktog_s2 <= 1'b0; ktog_s3 <= 1'b0;
            kpay_r  <= 10'd0; kout_tog <= 1'b0; kdelay <= 2'd0;
        end else begin
            ktog_s1 <= ps2_key[10];
            ktog_s2 <= ktog_s1;
            ktog_s3 <= ktog_s2;
            if (kdelay != 2'd0) begin
                kdelay <= kdelay - 2'd1;
                if (kdelay == 2'd1) begin
                    // Settled: read the payload straight from the source, the
                    // standard flag-then-data handshake.
                    kpay_r   <= ps2_key[9:0];
                    kout_tog <= ~kout_tog;
                end
            end else if (ktog_s2 != ktog_s3) begin
                kdelay <= 2'd2;
            end
        end
    end
    wire [10:0] ps2_key_s2 = {kout_tog, kpay_r};

    // The mouse path has the SAME hazard and is deliberately left alone: it is
    // not implicated in the reported fault, and there is no way to test a
    // change to it here.  If the mouse ever reports phantom buttons or stuck
    // movement, this is the first place to look.
    reg [24:0] ps2_mouse_s1, ps2_mouse_s2;
    reg  [7:0] ps2_mwheel_s1, ps2_mwheel_s2;
    always @(posedge cpu_clk) begin
        ps2_mouse_s1  <= ps2_mouse;      ps2_mouse_s2  <= ps2_mouse_s1;
        ps2_mwheel_s1 <= ps2_mouse_ext[7:0];
        ps2_mwheel_s2 <= ps2_mwheel_s1;
    end

    // ---- keyboard diagnostic counters, readable at $9F8D-$9F8F -------------
    // Three stages, three counters, so one hardware run says where a keystroke
    // died instead of another round of reasoning:
    //   $9F8D  makes that crossed into the core at all   (this sync)
    //   $9F8E  makes that reached the SMC key FIFO       (translation + space)
    //   $9F8F  keys dropped because the FIFO was full
    // Compare against what was typed, in that order; the first one that falls
    // short is the guilty stage.  Free-running 8-bit, wrapping, cleared only by
    // reset -- software reads them twice and subtracts.
    wire      smc_key_push, smc_key_drop;
    wire      kbd_arrive_make = (kdelay == 2'd1) & ps2_key[9];
    always @(posedge cpu_clk or negedge cpu_reset_n) begin
        if (!cpu_reset_n) begin
            dbg_arrive_r <= 8'h00; dbg_push_r <= 8'h00; dbg_drop_r <= 8'h00;
        end else begin
            if (kbd_arrive_make) dbg_arrive_r <= dbg_arrive_r + 8'd1;
            if (smc_key_push)    dbg_push_r   <= dbg_push_r   + 8'd1;
            if (smc_key_drop)    dbg_drop_r   <= dbg_drop_r   + 8'd1;
        end
    end

    ps2_to_smc_bridge u_ps2_bridge (
        .clk             (cpu_clk),
        .reset_n         (cpu_reset_n),
        .ps2_key         (ps2_key_s2),
        .ps2_mouse       (ps2_mouse_s2),
        .ps2_mouse_wheel (ps2_mwheel_s2),
        .uart_byte       (smc_uart_byte),
        .uart_byte_valid (smc_uart_byte_valid)
    );

    smc_x16 u_smc (
        .clk             (cpu_clk),
        .reset_n         (cpu_reset_n),
        .sda_bus         (bus_sda),
        .scl_bus         (bus_scl),
        .sda_drive_low   (smc_sda_drv_low),
        .uart_byte       (smc_uart_byte),
        .uart_byte_valid (smc_uart_byte_valid),
        .power_off_req   (smc_power_off_req),   // treated as a reset here
        .reset_req       (smc_reset_req),
        .nmi_req         (smc_nmi_req),
        .act_led_r       (smc_act_led),
        .dbg_kbd_count   (),
        .dbg_key_push    (smc_key_push),
        .dbg_key_drop    (smc_key_drop),
        .dbg_saw_start   (),
        .dbg_saw_addr_match(),
        .dbg_saw_byte    (),
        .dbg_saw_repeat  (),
        .dbg_saw_stop    (),
        .dbg_saw_tx      (),
        .dbg_last_cmd    (),
        .dbg_last_addr_byte(),
        .dbg_kbd_pop     (),
        .dbg_tx_byte     ()
    );

    // ========================================================================
    // CPU data-in mux
    //
    // Open-bus emulation: unmapped reads return the last byte seen on the data
    // bus, like a real floating bus.  Returning $00 makes device-detection code
    // false-positive on "something present answering 0".
    // ========================================================================
    reg [7:0] open_bus_r = 8'h00;
    always @(posedge cpu_clk)
        if (cpu_adv) open_bus_r <= cpu_rwn ? cpu_di : cpu_do;

    // boot_sel FIRST: the overlay shadows the top page of bank-0 RAM on reads.
    assign cpu_di = boot_sel   ? boot_data     :
                    vera_cs    ? vera_extbus_d :
                    vera2_cs   ? vera2_data    :
                    ym_cs      ? ym_rd_data    :
                    via1_cs    ? via1_data     :
                    via2_cs    ? via2_data     :
                    sysctl_cs  ? sysctl_data   :
                    timer_cs   ? timer_data    :
                    bank0_cs   ? bank0_data    :
                    fast_cs    ? fast_data     :
                    flat_cs    ? sdram_data    :
                                 open_bus_r;

    // ========================================================================
    // Video out
    // ========================================================================
    assign CLK_VIDEO = pix_clk;
    assign CE_PIXEL  = 1'b1;

    assign VGA_R       = {out_r, out_r};
    assign VGA_G       = {out_g, out_g};
    assign VGA_B       = {out_b, out_b};
    assign VGA_HS      = vera_hs;
    assign VGA_VS      = vera_vs;
    assign VGA_DE      = vera_de;
    assign VGA_F1      = 1'b0;
    assign VGA_SL      = 2'b00;
    assign VGA_SCALER  = 1'b0;
    assign VGA_DISABLE = 1'b0;
    assign VIDEO_ARX   = 13'd4;
    assign VIDEO_ARY   = 13'd3;

    assign HDMI_FREEZE    = 1'b0;
    assign HDMI_BLACKOUT  = 1'b0;
    assign HDMI_BOB_DEINT = 1'b0;

    // ========================================================================
    // Audio out  --  VERA (PSG + PCM, I2S serial) mixed with the YM2151
    // ========================================================================
    wire signed [15:0] vera_al, vera_ar;
    i2s_rx u_i2s_rx (
        .clk   (pix_clk),
        .lrck  (vera_audio_lrck),
        .bck   (vera_audio_bck),
        .data  (vera_audio_data),
        .left  (vera_al),
        .right (vera_ar)
    );

    function automatic [15:0] sat16(input signed [17:0] s);
        sat16 = (s >  18'sd32767) ? 16'h7FFF :
                (s < -18'sd32768) ? 16'h8000 : s[15:0];
    endfunction

    // VERA's full scale through the top-16 I2S tap is +/-16K (the 17-bit
    // PSG+PCM mix sits in bits [23:7], so the tap sees mix>>1) while the YM
    // runs a full +/-32K.  Scale VERA x2 so full-scale matches, like the real
    // board's analog mixer.
    reg [15:0] audio_l_r, audio_r_r;
    always @(posedge pix_clk) begin
        audio_l_r <= sat16($signed({{2{ym_emu_l[15]}}, ym_emu_l})
                         + ($signed({{2{vera_al[15]}}, vera_al}) <<< 1));
        audio_r_r <= sat16($signed({{2{ym_emu_r[15]}}, ym_emu_r})
                         + ($signed({{2{vera_ar[15]}}, vera_ar}) <<< 1));
    end

    assign AUDIO_L   = audio_l_r;
    assign AUDIO_R   = audio_r_r;
    assign AUDIO_S   = 1'b1;        // signed
    assign AUDIO_MIX = 2'b00;

    // ========================================================================
    // Tie-offs for unused framework signals
    // ========================================================================
    // LED_USER: activity.  cpu_wait_state here is a genuine bus-idle indicator
    // -- it lights whenever the CPU is parked, whether in WAI/STP or stalled on
    // an SDRAM access, which makes a wedged core visually obvious.
    assign LED_USER  = ioctl_download | (smc_act_led != 8'h00) | cpu_wait_state;
    assign LED_POWER = 2'b00;
    assign LED_DISK  = 2'b00;
    assign BUTTONS   = 2'b00;

    assign SD_SCK    = 1'b0;
    assign SD_MOSI   = 1'b0;
    assign SD_CS     = 1'b1;

    assign UART_TXD  = 1'b1;
    assign UART_RTS  = 1'b0;
    assign UART_DTR  = 1'b0;

    assign DDRAM_CLK      = cpu_clk;
    assign DDRAM_BURSTCNT = 8'h00;
    assign DDRAM_ADDR     = 29'h0;
    assign DDRAM_RD       = 1'b0;
    assign DDRAM_DIN      = 64'h0;
    assign DDRAM_BE       = 8'h00;
    assign DDRAM_WE       = 1'b0;

    assign USER_OUT = 7'h7F;
    assign ADC_BUS  = 4'hZ;

    // Named sink for signals that are read nowhere else.
    //
    // IT DOES NOT PREVENT TRIMMING, despite what this comment used to claim.
    // `_unused_cpu` is assigned and never read, so the fitter removes it and
    // everything feeding it. A memory instantiated purely to see whether it
    // would infer was sunk here and vanished from the fit report without a
    // word -- the compile reported the same block count as if it had never
    // been added. Anything that must SURVIVE synthesis has to reach a device
    // output, not a named wire.
    wire _unused_cpu = cpu_sync | cpu_i_flag | (|cpu_pc) | buttons[0]
                     | forced_scandoubler | direct_video | (|status);

endmodule
