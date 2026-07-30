//`default_nettype none

module top(
    input  wire       clk25,

    // External bus interface
    input  wire       extbus_cs_n,   /* Chip select */
    input  wire       extbus_rd_n,   /* Read strobe */
    input  wire       extbus_wr_n,   /* Write strobe */
    input  wire [4:0] extbus_a,      /* Address */
    inout  wire [7:0] extbus_d,      /* Data (bi-directional) */
    output wire       extbus_irq_n,  /* IRQ */

    // VGA interface
    output reg  [3:0] vga_r,
    output reg  [3:0] vga_g,
    output reg  [3:0] vga_b,
    output reg        vga_hsync,
    output reg        vga_vsync,
    // 2026-06-21: added vga_de for HDMI sinks (ADV7513 needs DE).  Aligned
    // with vga_r/g/b through the same posedge-clk register stage in top.v.
    output reg        vga_de,
    // Opacity bit for the external MiSTer bitmap compositor: 1 = this pixel is
    // a VERA sprite/layer pixel (show VERA), 0 = transparent (show bitmap).
    // Aligned with vga_r/g/b through every register stage.
    output reg        vga_opaque,

    // SPI interface
    output wire       spi_sck,
    output wire       spi_mosi,
    input  wire       spi_miso,
    output wire       spi_ssel_n_sd,

    // Audio output
    output wire       audio_lrck,
    output wire       audio_bck,
    output wire       audio_data,

    // 2026-06-21: debug taps -- C5G_min probes these from outside to see
    // what VERA's bus capture pipeline actually latched (wrdata_r/wraddr_r)
    // and when its do_write pulse fires.  Hierarchical references to
    // module-internal wires aren't allowed by Quartus, so expose as ports.
    output wire [7:0] dbg_wrdata_r,
    output wire [4:0] dbg_wraddr_r,
    output wire       dbg_do_write,
    output wire [1:0] dbg_video_mode,   // = video_output_mode_r (0=off,1=VGA)
    output wire [2:0] dbg_dcsel,         // = dc_select_r (DCSEL)
    output wire       spi_busy_out,      // SPI busy -> x16.sv stalls $9F3E reads on it
    output wire       spi_autotx_out,    // auto-tx enabled -> fast read in use

    // 2026-06-22: NTSC composite encoder taps for scope verification.
    // luma/chroma are 6-bit digital -- raw probes only, no DAC.  Encoder
    // runs continuously regardless of video_output_mode_r.
    output wire [5:0] composite_luma,
    output wire [5:0] composite_chroma);

    localparam [7:0] VERA_VERSION_MAJOR = 8'd47;
    localparam [7:0] VERA_VERSION_MINOR = 8'd0;
    localparam [7:0] VERA_VERSION_PATCH = 8'd2;

    //////////////////////////////////////////////////////////////////////////
    // Synchronize external asynchronous reset signal to clk25 domain
    //////////////////////////////////////////////////////////////////////////
    reg [7:0] por_cnt_r = 0;
    always @(posedge clk25) if (!por_cnt_r[7]) por_cnt_r <= por_cnt_r + 8'd1;

    wire reset;
    reset_sync reset_sync_clk25(
        .async_rst_in(!por_cnt_r[7]),
        .clk(clk25),
        .reset_out(reset));

    wire clk = clk25;

    //////////////////////////////////////////////////////////////////////////
    // Bus accessible registers
    //////////////////////////////////////////////////////////////////////////
    // jyv 2026-07-07 (VERA FX): ADDR0/ADDR1, DATA0/DATA1, the increment
    // decoders and the internal-bus (ib_*) registers moved into the new
    // addr_data module (ported from vera-module v47.0.2), which also
    // implements the FX helpers.  They surface here as wires.
    wire [16:0] vram_addr_0_r;
    wire [16:0] vram_addr_1_r;
    wire        vram_addr_nib_0_r;
    wire        vram_addr_nib_1_r;
    wire  [3:0] vram_addr_incr_0_r;
    wire  [3:0] vram_addr_incr_1_r;
    wire        vram_addr_nib_incr_0_r;
    wire        vram_addr_nib_incr_1_r;
    wire        vram_addr_decr_0_r;
    wire        vram_addr_decr_1_r;
    wire  [7:0] vram_data0_r;
    wire  [7:0] vram_data1_r;

    wire [16:0] ib_addr_r;
    wire        ib_addr_nibble_r;
    wire        ib_4bit_mode_r;
    wire        ib_cache_write_enabled_r;
    wire        ib_transparency_enabled_r;
    wire        ib_one_byte_cache_cycling_r;
    wire [31:0] ib_mult_accum_cache32_r;
    wire  [7:0] ib_cache8_r;
    wire  [7:0] ib_wrdata_r;
    wire        ib_write_r;
    wire        ib_do_access_r;

    wire  [7:0] fx_fill_length_low;
    wire  [7:0] fx_fill_length_high;

    wire        fx_transparency_enabled;
    wire        fx_cache_write_enabled;
    wire        fx_cache_fill_enabled;
    wire        fx_one_byte_cache_cycling;
    wire        fx_16bit_hop;
    wire        fx_4bit_mode;
    wire  [1:0] fx_addr1_mode;

    reg        vram_addr_select_r,            vram_addr_select_next;
    // jyv 2026-06-28: widened from 1 bit to capture DCSEL so the X16 R49
    // KERNAL's screen_save_state can use DCSEL=2 to access FX_CTRL without
    // aliasing to DCSEL=0's DC_VIDEO.
    // jyv 2026-07-07 (VERA FX): widened again to the full 6 bits (CTRL bits
    // [6:1]) -- DCSEL 2-6 now select the real FX registers (addr_data) and
    // DCSEL 7-63 read back the VERA version, exactly like vera-module 47.x.
    reg  [5:0] dc_select_r,                   dc_select_next;
    reg        fpga_reconfigure_r,            fpga_reconfigure_next;
    reg        irq_enable_vsync_r,            irq_enable_vsync_next;
    reg        irq_enable_line_r,             irq_enable_line_next;
    reg        irq_enable_sprite_collision_r, irq_enable_sprite_collision_next;
    reg        irq_enable_audio_fifo_low_r,   irq_enable_audio_fifo_low_next;
    reg        irq_status_vsync_r,            irq_status_vsync_next;
    reg        irq_status_line_r,             irq_status_line_next;
    reg        irq_status_sprite_collision_r, irq_status_sprite_collision_next;
    reg  [8:0] irq_line_r,                    irq_line_next;
    reg        sprites_enabled_r,             sprites_enabled_next;
    reg        l0_enabled_r,                  l0_enabled_next;
    reg        l1_enabled_r,                  l1_enabled_next;

    reg        chroma_disable_r,              chroma_disable_next;
    // jyv 2026-07-07: DC_VIDEO bit 3 ("NTSC/RGB: 240p progressive", 47.x).
    // Register fidelity only -- the MiSTer scan-out is always VGA timing.
    reg        dc_progressive_r,              dc_progressive_next;
    reg  [7:0] dc_hscale_r,                   dc_hscale_next;
    reg  [7:0] dc_vscale_r,                   dc_vscale_next;
    reg  [7:0] dc_border_color_r,             dc_border_color_next;
    reg  [9:0] dc_active_hstart_r,            dc_active_hstart_next;
    reg  [9:0] dc_active_hstop_r,             dc_active_hstop_next;
    reg  [8:0] dc_active_vstart_r,            dc_active_vstart_next;
    reg  [8:0] dc_active_vstop_r,             dc_active_vstop_next;

    reg  [1:0] l0_color_depth_r,              l0_color_depth_next;
    reg        l0_bitmap_mode_r,              l0_bitmap_mode_next;
    reg        l0_attr_mode_r,                l0_attr_mode_next;
    reg        l0_tile_height_r,              l0_tile_height_next;
    reg        l0_tile_width_r,               l0_tile_width_next;
    reg  [1:0] l0_map_height_r,               l0_map_height_next;
    reg  [1:0] l0_map_width_r,                l0_map_width_next;
    reg  [7:0] l0_map_baseaddr_r,             l0_map_baseaddr_next;
    reg  [7:0] l0_tile_baseaddr_r,            l0_tile_baseaddr_next;
    reg [11:0] l0_hscroll_r,                  l0_hscroll_next;
    reg [11:0] l0_vscroll_r,                  l0_vscroll_next;

    reg  [1:0] l1_color_depth_r,              l1_color_depth_next;
    reg        l1_bitmap_mode_r,              l1_bitmap_mode_next;
    reg        l1_attr_mode_r,                l1_attr_mode_next;
    reg        l1_tile_height_r,              l1_tile_height_next;
    reg        l1_tile_width_r,               l1_tile_width_next;
    reg  [1:0] l1_map_height_r,               l1_map_height_next;
    reg  [1:0] l1_map_width_r,                l1_map_width_next;
    reg  [7:0] l1_map_baseaddr_r,             l1_map_baseaddr_next;
    reg  [7:0] l1_tile_baseaddr_r,            l1_tile_baseaddr_next;
    reg [11:0] l1_hscroll_r,                  l1_hscroll_next;
    reg [11:0] l1_vscroll_r,                  l1_vscroll_next;

    reg  [1:0] video_output_mode_r,           video_output_mode_next;

    reg  [7:0] audio_pcm_sample_rate_r,       audio_pcm_sample_rate_next;
    reg        audio_mode_stereo_r,           audio_mode_stereo_next;
    reg        audio_mode_16bit_r,            audio_mode_16bit_next;
    reg        audio_fifo_reset_r,            audio_fifo_reset_next;
    wire       audio_fifo_full;
    reg  [3:0] audio_pcm_volume_r,            audio_pcm_volume_next;
    reg  [7:0] audio_fifo_wrdata_r,           audio_fifo_wrdata_next;
    reg        audio_fifo_write_r,            audio_fifo_write_next;

    wire [3:0] sprite_collisions;
    wire       current_field;
    wire [7:0] vram_rddata;

    wire       audio_fifo_low;
    wire       audio_fifo_empty;
    wire       sprcol_irq;
    wire       vblank_pulse;
    wire       line_irq;
    wire [8:0] scanline;

    reg        spi_select_r,                  spi_select_next;
    reg        spi_slow_r,                    spi_slow_next;
    reg        spi_autotx_r,                  spi_autotx_next;
    // jyv 2026-07-07 (VERA FX): the old version_mode_r $7E-compat shim is
    // gone -- DCSEL is 6 bits now, so the ROM's VERA_CTRL=$7E lands on
    // DCSEL=63 which reads back the version bytes natively (like real 47.x).
    reg  [7:0] spi_txdata;
    reg        spi_txstart;
    wire       spi_busy;
    wire [7:0] spi_rxdata;
    reg        tx_pending;   // declared before first use (rddata $1F) -- ModelSim
                             // needs declare-before-use; updater logic is below.

    reg [7:0] rddata;
    always @* case (extbus_a)
        5'h00: rddata = vram_addr_select_r ? vram_addr_1_r[7:0] : vram_addr_0_r[7:0];
        5'h01: rddata = vram_addr_select_r ? vram_addr_1_r[15:8] : vram_addr_0_r[15:8];
        5'h02: rddata = vram_addr_select_r
                            ? {vram_addr_incr_1_r, vram_addr_decr_1_r, vram_addr_nib_incr_1_r, vram_addr_nib_1_r, vram_addr_1_r[16]}
                            : {vram_addr_incr_0_r, vram_addr_decr_0_r, vram_addr_nib_incr_0_r, vram_addr_nib_0_r, vram_addr_0_r[16]};
        5'h03: rddata = vram_data0_r;
        5'h04: rddata = vram_data1_r;
        5'h05: rddata = {1'b0, dc_select_r, vram_addr_select_r};

        5'h06: rddata = {irq_line_r[8], scanline[8], 2'b0, irq_enable_audio_fifo_low_r, irq_enable_sprite_collision_r, irq_enable_line_r, irq_enable_vsync_r};
        5'h07: rddata = {sprite_collisions,   audio_fifo_low,              irq_status_sprite_collision_r, irq_status_line_r, irq_status_vsync_r};
        5'h08: rddata = scanline[7:0];

        // jyv 2026-07-07 (VERA FX): $9F29-$9F2C bank by the full 6-bit DCSEL,
        // exactly like vera-module 47.x: 0 = DC_VIDEO etc., 1 = display
        // geometry, 2 = FX_CTRL readback, 5 = polygon fill length (read-only),
        // everything else (incl. 63) = version bytes 'V', major, minor, patch.
        5'h09: begin
            case (dc_select_r)
                6'd0: rddata = {current_field, sprites_enabled_r, l1_enabled_r, l0_enabled_r, dc_progressive_r, chroma_disable_r, video_output_mode_r};
                6'd1: rddata = dc_active_hstart_r[9:2];
                6'd2: rddata = {fx_transparency_enabled, fx_cache_write_enabled, fx_cache_fill_enabled, fx_one_byte_cache_cycling, fx_16bit_hop, fx_4bit_mode, fx_addr1_mode};
                default: rddata = 8'h56; // 'V'
            endcase
        end
        5'h0A: begin
            case (dc_select_r)
                6'd0: rddata = dc_hscale_r;
                6'd1: rddata = dc_active_hstop_r[9:2];
                default: rddata = VERA_VERSION_MAJOR;
            endcase
        end
        5'h0B: begin
            case (dc_select_r)
                6'd0: rddata = dc_vscale_r;
                6'd1: rddata = dc_active_vstart_r[8:1];
                6'd5: rddata = fx_fill_length_low;
                default: rddata = VERA_VERSION_MINOR;
            endcase
        end
        5'h0C: begin
            case (dc_select_r)
                6'd0: rddata = dc_border_color_r;
                6'd1: rddata = dc_active_vstop_r[8:1];
                6'd5: rddata = fx_fill_length_high;
                default: rddata = VERA_VERSION_PATCH;
            endcase
        end

        5'h0D: rddata = {l0_map_height_r, l0_map_width_r, l0_attr_mode_r, l0_bitmap_mode_r, l0_color_depth_r};
        5'h0E: rddata = l0_map_baseaddr_r;
        5'h0F: rddata = {l0_tile_baseaddr_r[7:2], l0_tile_height_r, l0_tile_width_r};
        5'h10: rddata = l0_hscroll_r[7:0];
        5'h11: rddata = {4'b0, l0_hscroll_r[11:8]};
        5'h12: rddata = l0_vscroll_r[7:0];
        5'h13: rddata = {4'b0, l0_vscroll_r[11:8]};

        5'h14: rddata = {l1_map_height_r, l1_map_width_r, l1_attr_mode_r, l1_bitmap_mode_r, l1_color_depth_r};
        5'h15: rddata = l1_map_baseaddr_r;
        5'h16: rddata = {l1_tile_baseaddr_r[7:2], l1_tile_height_r, l1_tile_width_r};
        5'h17: rddata = l1_hscroll_r[7:0];
        5'h18: rddata = {4'b0, l1_hscroll_r[11:8]};
        5'h19: rddata = l1_vscroll_r[7:0];
        5'h1A: rddata = {4'b0, l1_vscroll_r[11:8]};

        5'h1B: rddata = {audio_fifo_full, audio_fifo_empty, audio_mode_16bit_r, audio_mode_stereo_r, audio_pcm_volume_r};
        5'h1C: rddata = audio_pcm_sample_rate_r;
        5'h1D: rddata = 8'h00;

        5'h1E: rddata = spi_rxdata;
        // Report busy = spi_busy | tx_pending.  tx_pending covers the gap between the
        // CPU writing $9F3E (starting a transfer) and VERA's pipelined do_write
        // actually asserting spi_busy -- without it, R49's slow read polls busy too
        // early, sees "not busy", and reads the STALE previous byte (e.g. sector byte
        // 510 comes back 0x00).  On real HW busy asserts immediately; this restores
        // that behaviour on the MiSTer's pipelined bus.
        5'h1F: rddata = {spi_busy | tx_pending, 4'b0, spi_autotx_r, spi_slow_r, spi_select_r};
    endcase

    wire bus_read  = !extbus_cs_n &&  extbus_wr_n && !extbus_rd_n;
    wire bus_write = !extbus_cs_n && !extbus_wr_n;
    assign extbus_d = bus_read ? rddata : 8'bZ;

    // Transfer-pending: set the instant the CPU accesses $9F3E in a way that starts a
    // transfer (any write; or a read while auto-tx is on), cleared once spi_busy is
    // really high.  Bridges VERA's do_write/do_read pipeline latency so the busy bit
    // is never falsely 0 between the access and the transfer start.
    // (tx_pending is declared up with the SPI regs -- declare-before-use.)
    always @(posedge clk or posedge reset) begin
        if (reset)
            tx_pending <= 1'b0;
        else if ((bus_write && extbus_a == 5'h1E) ||
                 (bus_read  && extbus_a == 5'h1E && spi_autotx_r))
            tx_pending <= 1'b1;
        else if (spi_busy)
            tx_pending <= 1'b0;
    end

    wire [3:0] irq_enable = {irq_enable_audio_fifo_low_r, irq_enable_sprite_collision_r, irq_enable_line_r, irq_enable_vsync_r};
    wire [3:0] irq_status = {audio_fifo_low,              irq_status_sprite_collision_r, irq_status_line_r, irq_status_vsync_r};

    assign extbus_irq_n = (irq_status & irq_enable) == 0;

    // Capture address / write-data.
    reg [4:0] rdaddr_r;
    reg [4:0] wraddr_r;
    reg [7:0] wrdata_r;

    // Synchronize read and write strobes into the clk domain, and capture the
    // address/data synchronously.
    reg [2:0] bus_read_r;
    reg [2:0] bus_write_r;
    always @(posedge clk) begin
        bus_read_r  <= {bus_read_r[1:0], bus_read};
        bus_write_r <= {bus_write_r[1:0], bus_write};

        // 2026-06-29 (MiSTer port): capture addr/data SYNCHRONOUSLY on the
        // synchronized RISING edge of the strobe, instead of using bus_write /
        // bus_read as gated (combinational) clocks.  The original
        //   always @(posedge bus_write) wraddr_r <= extbus_a;   (+ data/read)
        // inferred an unconstrained, glitch-prone gated clock (wr_n_o_cld) that
        // latched the WRONG VERA register on congested Cyclone V routing, so the
        // DC_VIDEO output-mode write never took effect (black screen).  The
        // x16.sv bus pipeline holds extbus_a/extbus_d stable for the whole
        // multi-cycle strobe, so sampling them a couple of clk cycles in is
        // safe and deterministic.
        if (bus_write_r[2:1] == 2'b01) begin   // synced rising edge of write
            wraddr_r <= extbus_a;
            wrdata_r <= extbus_d;
        end
        if (bus_read_r[2:1] == 2'b01) begin    // synced rising edge of read
            rdaddr_r <= extbus_a;
        end
    end

    wire do_read  = bus_read_r[2:1] == 2'b10;
    wire do_write = bus_write_r[2:1] == 2'b10;

    // Debug taps to C5G_min (see port comment).
    assign dbg_wrdata_r = wrdata_r;
    assign dbg_wraddr_r = wraddr_r;
    assign dbg_video_mode = video_output_mode_r;
    assign dbg_dcsel      = dc_select_r[2:0];
    assign dbg_do_write = do_write;
    assign spi_busy_out = spi_busy;
    assign spi_autotx_out = spi_autotx_r;
    wire [4:0] access_addr = do_write ? wraddr_r : rdaddr_r;
    wire [7:0] write_data  = wrdata_r;

    always @* begin
        vram_addr_select_next            = vram_addr_select_r;
        dc_select_next                   = dc_select_r;
        fpga_reconfigure_next            = fpga_reconfigure_r;
        irq_enable_audio_fifo_low_next   = irq_enable_audio_fifo_low_r;
        irq_enable_vsync_next            = irq_enable_vsync_r;
        irq_enable_line_next             = irq_enable_line_r;
        irq_enable_sprite_collision_next = irq_enable_sprite_collision_r;
        irq_status_vsync_next            = irq_status_vsync_r;
        irq_status_line_next             = irq_status_line_r;
        irq_status_sprite_collision_next = irq_status_sprite_collision_r;
        irq_line_next                    = irq_line_r;
        sprites_enabled_next             = sprites_enabled_r;
        l0_enabled_next                  = l0_enabled_r;
        l1_enabled_next                  = l1_enabled_r;
        chroma_disable_next              = chroma_disable_r;
        dc_progressive_next              = dc_progressive_r;
        dc_hscale_next                   = dc_hscale_r;
        dc_vscale_next                   = dc_vscale_r;
        dc_border_color_next             = dc_border_color_r;
        dc_active_hstart_next            = dc_active_hstart_r;
        dc_active_hstop_next             = dc_active_hstop_r;
        dc_active_vstart_next            = dc_active_vstart_r;
        dc_active_vstop_next             = dc_active_vstop_r;
        l0_color_depth_next              = l0_color_depth_r;
        l0_bitmap_mode_next              = l0_bitmap_mode_r;
        l0_attr_mode_next                = l0_attr_mode_r;
        l0_tile_height_next              = l0_tile_height_r;
        l0_tile_width_next               = l0_tile_width_r;
        l0_map_height_next               = l0_map_height_r;
        l0_map_width_next                = l0_map_width_r;
        l0_map_baseaddr_next             = l0_map_baseaddr_r;
        l0_tile_baseaddr_next            = l0_tile_baseaddr_r;
        l0_hscroll_next                  = l0_hscroll_r;
        l0_vscroll_next                  = l0_vscroll_r;
        l1_color_depth_next              = l1_color_depth_r;
        l1_bitmap_mode_next              = l1_bitmap_mode_r;
        l1_attr_mode_next                = l1_attr_mode_r;
        l1_tile_height_next              = l1_tile_height_r;
        l1_tile_width_next               = l1_tile_width_r;
        l1_map_height_next               = l1_map_height_r;
        l1_map_width_next                = l1_map_width_r;
        l1_map_baseaddr_next             = l1_map_baseaddr_r;
        l1_tile_baseaddr_next            = l1_tile_baseaddr_r;
        l1_hscroll_next                  = l1_hscroll_r;
        l1_vscroll_next                  = l1_vscroll_r;
        video_output_mode_next           = video_output_mode_r;

        audio_pcm_sample_rate_next       = audio_pcm_sample_rate_r;
        audio_mode_stereo_next           = audio_mode_stereo_r;
        audio_mode_16bit_next            = audio_mode_16bit_r;
        audio_fifo_reset_next            = 0;
        audio_pcm_volume_next            = audio_pcm_volume_r;
        audio_fifo_wrdata_next           = audio_fifo_wrdata_r;
        audio_fifo_write_next            = 0;

        spi_select_next                  = spi_select_r;
        spi_slow_next                    = spi_slow_r;
        spi_autotx_next                  = spi_autotx_r;

        spi_txdata                       = write_data;
        spi_txstart                      = 0;

        // jyv 2026-07-07 (VERA FX): addresses 00-04 (ADDRx, DATA0/1) and the
        // DCSEL 2-6 banks of 09-0C are handled inside addr_data now.
        if (do_write) begin
            case (access_addr)
                5'h05: begin
                    fpga_reconfigure_next = write_data[7];
                    dc_select_next        = write_data[6:1];
                    vram_addr_select_next = write_data[0];
                end

                5'h06: begin
                    irq_line_next[8]                 = write_data[7];
                    irq_enable_audio_fifo_low_next   = write_data[3];
                    irq_enable_sprite_collision_next = write_data[2];
                    irq_enable_line_next             = write_data[1];
                    irq_enable_vsync_next            = write_data[0];
                end
                5'h07: begin
                    // Clear status bits
                    irq_status_sprite_collision_next = irq_status_sprite_collision_r & !write_data[2];
                    irq_status_line_next             = irq_status_line_r             & !write_data[1];
                    irq_status_vsync_next            = irq_status_vsync_r            & !write_data[0];
                end
                5'h08: irq_line_next[7:0] = write_data;

                // jyv 2026-06-28: $9F29-$9F2C writes are DCSEL-banked.
                // DCSEL=0 -> DC_VIDEO etc.  DCSEL=1 -> display geometry.
                // jyv 2026-07-07 (VERA FX): DCSEL 2-6 are the FX registers,
                // decoded inside addr_data (this case ignores them here, so
                // the X16 R49 KERNAL's `stz $9F29` under DCSEL=2 still can't
                // fall through and zero DC_VIDEO).
                5'h09: begin
                    if (dc_select_r == 6'd0) begin
                        sprites_enabled_next   = write_data[6];
                        l1_enabled_next        = write_data[5];
                        l0_enabled_next        = write_data[4];
                        dc_progressive_next    = write_data[3];
                        chroma_disable_next    = write_data[2];
                        video_output_mode_next = write_data[1:0];
                    end else if (dc_select_r == 3'd1) begin
                        dc_active_hstart_next[9:2] = write_data;
                        dc_active_hstart_next[1:0] = 0;
                    end
                    // else: ignore (no-op for DCSEL>=2)
                end
                5'h0A: begin
                    if (dc_select_r == 3'd0) begin
                        dc_hscale_next            = write_data;
                    end else if (dc_select_r == 3'd1) begin
                        dc_active_hstop_next[9:2] = write_data;
                        dc_active_hstop_next[1:0] = 0;
                    end
                    // else: ignore (no-op for DCSEL>=2)
                end
                5'h0B: begin
                    if (dc_select_r == 3'd0) begin
                        dc_vscale_next             = write_data;
                    end else if (dc_select_r == 3'd1) begin
                        dc_active_vstart_next[8:1] = write_data;
                        dc_active_vstart_next[0]   = 0;
                    end
                    // else: ignore (no-op for DCSEL>=2)
                end
                5'h0C: begin
                    if (dc_select_r == 3'd0) begin
                        dc_border_color_next      = write_data;
                    end else if (dc_select_r == 3'd1) begin
                        dc_active_vstop_next[8:1] = write_data;
                        dc_active_vstop_next[0]   = 0;
                    end
                    // else: ignore (no-op for DCSEL>=2)
                end

                5'h0D: begin
                    l0_map_height_next  = write_data[7:6];
                    l0_map_width_next   = write_data[5:4];
                    l0_attr_mode_next   = write_data[3];
                    l0_bitmap_mode_next = write_data[2];
                    l0_color_depth_next = write_data[1:0];
                end
                5'h0E: l0_map_baseaddr_next = write_data;
                5'h0F: begin
                    l0_tile_baseaddr_next[7:2] = write_data[7:2];
                    l0_tile_baseaddr_next[1:0] = 0;

                    l0_tile_height_next = write_data[1];
                    l0_tile_width_next  = write_data[0];
                end
                5'h10: l0_hscroll_next[7:0]  = write_data;
                5'h11: l0_hscroll_next[11:8] = write_data[3:0];
                5'h12: l0_vscroll_next[7:0]  = write_data;
                5'h13: l0_vscroll_next[11:8] = write_data[3:0];

                5'h14: begin
                    l1_map_height_next  = write_data[7:6];
                    l1_map_width_next   = write_data[5:4];
                    l1_attr_mode_next   = write_data[3];
                    l1_bitmap_mode_next = write_data[2];
                    l1_color_depth_next = write_data[1:0];
                end
                5'h15: l1_map_baseaddr_next = write_data;
                5'h16: begin
                    l1_tile_baseaddr_next[7:2] = write_data[7:2];
                    l1_tile_baseaddr_next[1:0] = 0;

                    l1_tile_height_next = write_data[1];
                    l1_tile_width_next  = write_data[0];
                end
                5'h17: l1_hscroll_next[7:0]  = write_data;
                5'h18: l1_hscroll_next[11:8] = write_data[3:0];
                5'h19: l1_vscroll_next[7:0]  = write_data;
                5'h1A: l1_vscroll_next[11:8] = write_data[3:0];

                5'h1B: begin
                    audio_fifo_reset_next       = write_data[7];
                    audio_mode_16bit_next       = write_data[5];
                    audio_mode_stereo_next      = write_data[4];
                    audio_pcm_volume_next       = write_data[3:0];
                end
                5'h1C: audio_pcm_sample_rate_next = write_data;
                5'h1D: begin
                    audio_fifo_wrdata_next = write_data;
                    audio_fifo_write_next  = 1;
                end

                5'h1E: spi_txstart = 1;
                5'h1F: begin
                    spi_autotx_next = write_data[2];
                    spi_slow_next   = write_data[1];
                    spi_select_next = write_data[0];
                end
            endcase
        end

        // SPI auto-tx function
        if (spi_autotx_r && access_addr == 5'h1E && do_read) begin
            spi_txdata = 8'hFF;
            spi_txstart = 1;
        end

        if (sprcol_irq) begin
            irq_status_sprite_collision_next = 1;
        end
        if (line_irq) begin
            irq_status_line_next = 1;
        end
        if (vblank_pulse) begin
            irq_status_vsync_next = 1;
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            vram_addr_select_r            <= 0;
            dc_select_r                   <= 0;
            fpga_reconfigure_r            <= 0;
            irq_enable_audio_fifo_low_r   <= 0;
            irq_enable_vsync_r            <= 0;
            irq_enable_line_r             <= 0;
            irq_enable_sprite_collision_r <= 0;
            irq_status_vsync_r            <= 0;
            irq_status_line_r             <= 0;
            irq_status_sprite_collision_r <= 0;
            irq_line_r                    <= 0;
            sprites_enabled_r             <= 0;
            l0_enabled_r                  <= 0;
            l1_enabled_r                  <= 0;
            chroma_disable_r              <= 0;
            dc_progressive_r              <= 0;
            dc_hscale_r                   <= 8'd128;
            dc_vscale_r                   <= 8'd128;
            dc_border_color_r             <= 0;
            dc_active_hstart_r            <= 10'd0;
            dc_active_hstop_r             <= 10'd640;
            dc_active_vstart_r            <= 9'd0;
            dc_active_vstop_r             <= 9'd480;
            l0_color_depth_r              <= 0;
            l0_bitmap_mode_r              <= 0;
            l0_attr_mode_r                <= 0;
            l0_tile_height_r              <= 0;
            l0_tile_width_r               <= 0;
            l0_map_height_r               <= 0;
            l0_map_width_r                <= 0;
            l0_map_baseaddr_r             <= 0;
            l0_tile_baseaddr_r            <= 0;
            l0_hscroll_r                  <= 0;
            l0_vscroll_r                  <= 0;
            l1_color_depth_r              <= 0;
            l1_bitmap_mode_r              <= 0;
            l1_attr_mode_r                <= 0;
            l1_tile_height_r              <= 0;
            l1_tile_width_r               <= 0;
            l1_map_height_r               <= 0;
            l1_map_width_r                <= 0;
            l1_map_baseaddr_r             <= 0;
            l1_tile_baseaddr_r            <= 0;
            l1_hscroll_r                  <= 0;
            l1_vscroll_r                  <= 0;
            video_output_mode_r           <= 0;
            audio_pcm_sample_rate_r       <= 0;
            audio_mode_stereo_r           <= 0;
            audio_mode_16bit_r            <= 0;
            audio_fifo_reset_r            <= 0;
            audio_pcm_volume_r            <= 0;
            audio_fifo_wrdata_r           <= 0;
            audio_fifo_write_r            <= 0;
            spi_select_r                  <= 0;
            spi_slow_r                    <= 0;
            spi_autotx_r                  <= 0;

        end else begin
            vram_addr_select_r            <= vram_addr_select_next;
            dc_select_r                   <= dc_select_next;
            fpga_reconfigure_r            <= fpga_reconfigure_next;
            irq_enable_audio_fifo_low_r   <= irq_enable_audio_fifo_low_next;
            irq_enable_vsync_r            <= irq_enable_vsync_next;
            irq_enable_line_r             <= irq_enable_line_next;
            irq_enable_sprite_collision_r <= irq_enable_sprite_collision_next;
            irq_status_vsync_r            <= irq_status_vsync_next;
            irq_status_line_r             <= irq_status_line_next;
            irq_status_sprite_collision_r <= irq_status_sprite_collision_next;
            irq_line_r                    <= irq_line_next;
            sprites_enabled_r             <= sprites_enabled_next;
            l0_enabled_r                  <= l0_enabled_next;
            l1_enabled_r                  <= l1_enabled_next;
            chroma_disable_r              <= chroma_disable_next;
            dc_progressive_r              <= dc_progressive_next;
            dc_hscale_r                   <= dc_hscale_next;
            dc_vscale_r                   <= dc_vscale_next;
            dc_border_color_r             <= dc_border_color_next;
            dc_active_hstart_r            <= dc_active_hstart_next;
            dc_active_hstop_r             <= dc_active_hstop_next;
            dc_active_vstart_r            <= dc_active_vstart_next;
            dc_active_vstop_r             <= dc_active_vstop_next;
            l0_color_depth_r              <= l0_color_depth_next;
            l0_bitmap_mode_r              <= l0_bitmap_mode_next;
            l0_attr_mode_r                <= l0_attr_mode_next;
            l0_tile_height_r              <= l0_tile_height_next;
            l0_tile_width_r               <= l0_tile_width_next;
            l0_map_height_r               <= l0_map_height_next;
            l0_map_width_r                <= l0_map_width_next;
            l0_map_baseaddr_r             <= l0_map_baseaddr_next;
            l0_tile_baseaddr_r            <= l0_tile_baseaddr_next;
            l0_hscroll_r                  <= l0_hscroll_next;
            l0_vscroll_r                  <= l0_vscroll_next;
            l1_color_depth_r              <= l1_color_depth_next;
            l1_bitmap_mode_r              <= l1_bitmap_mode_next;
            l1_attr_mode_r                <= l1_attr_mode_next;
            l1_tile_height_r              <= l1_tile_height_next;
            l1_tile_width_r               <= l1_tile_width_next;
            l1_map_height_r               <= l1_map_height_next;
            l1_map_width_r                <= l1_map_width_next;
            l1_map_baseaddr_r             <= l1_map_baseaddr_next;
            l1_tile_baseaddr_r            <= l1_tile_baseaddr_next;
            l1_hscroll_r                  <= l1_hscroll_next;
            l1_vscroll_r                  <= l1_vscroll_next;
            video_output_mode_r           <= video_output_mode_next;
            audio_pcm_sample_rate_r       <= audio_pcm_sample_rate_next;
            audio_mode_stereo_r           <= audio_mode_stereo_next;
            audio_mode_16bit_r            <= audio_mode_16bit_next;
            audio_fifo_reset_r            <= audio_fifo_reset_next;
            audio_pcm_volume_r            <= audio_pcm_volume_next;
            audio_fifo_wrdata_r           <= audio_fifo_wrdata_next;
            audio_fifo_write_r            <= audio_fifo_write_next;
            spi_select_r                  <= spi_select_next;
            spi_slow_r                    <= spi_slow_next;
            spi_autotx_r                  <= spi_autotx_next;
        end
    end

    //////////////////////////////////////////////////////////////////////////
    // Address/data engine (ADDR0/1, DATA0/1, FX helpers, 32-bit cache,
    // multiplier/accumulator) -- jyv 2026-07-07, ported from vera-module
    // v47.0.2.  See addr_data.v.
    //////////////////////////////////////////////////////////////////////////
    addr_data addr_data(
        .reset(reset),
        .clk(clk),

        .do_read(do_read),
        .do_write(do_write),
        .access_addr(access_addr),
        .write_data(write_data),
        .vram_rddata(vram_rddata),

        .vram_addr_select(vram_addr_select_r),
        .dc_select(dc_select_r),

        .vram_addr_0(vram_addr_0_r),
        .vram_addr_1(vram_addr_1_r),
        .vram_addr_nib_0(vram_addr_nib_0_r),
        .vram_addr_nib_1(vram_addr_nib_1_r),
        .vram_addr_incr_0(vram_addr_incr_0_r),
        .vram_addr_incr_1(vram_addr_incr_1_r),
        .vram_addr_nib_incr_0(vram_addr_nib_incr_0_r),
        .vram_addr_nib_incr_1(vram_addr_nib_incr_1_r),
        .vram_addr_decr_0(vram_addr_decr_0_r),
        .vram_addr_decr_1(vram_addr_decr_1_r),
        .vram_data0(vram_data0_r),
        .vram_data1(vram_data1_r),

        .ib_addr(ib_addr_r),
        .ib_addr_nibble(ib_addr_nibble_r),
        .ib_4bit_mode(ib_4bit_mode_r),
        .ib_cache_write_enabled(ib_cache_write_enabled_r),
        .ib_transparency_enabled(ib_transparency_enabled_r),
        .ib_one_byte_cache_cycling(ib_one_byte_cache_cycling_r),
        .ib_mult_accum_cache32(ib_mult_accum_cache32_r),
        .ib_cache8(ib_cache8_r),
        .ib_wrdata(ib_wrdata_r),
        .ib_write(ib_write_r),
        .ib_do_access(ib_do_access_r),

        .fx_transparency_enabled(fx_transparency_enabled),
        .fx_cache_write_enabled(fx_cache_write_enabled),
        .fx_cache_fill_enabled(fx_cache_fill_enabled),
        .fx_one_byte_cache_cycling(fx_one_byte_cache_cycling),
        .fx_16bit_hop(fx_16bit_hop),
        .fx_4bit_mode(fx_4bit_mode),
        .fx_addr1_mode(fx_addr1_mode),

        .fx_fill_length_low(fx_fill_length_low),
        .fx_fill_length_high(fx_fill_length_high));

    //////////////////////////////////////////////////////////////////////////
    // Video RAM
    //////////////////////////////////////////////////////////////////////////
    wire [14:0] l0_addr;
    wire [31:0] l0_rddata;
    wire        l0_strobe;
    wire        l0_ack;

    wire [14:0] l1_addr;
    wire [31:0] l1_rddata;
    wire        l1_strobe;
    wire        l1_ack;

    wire [14:0] spr_addr;
    wire [31:0] spr_rddata;
    wire        spr_strobe;
    wire        spr_ack;

    vram_if vram_if(
        .clk(clk),

        // Interface 0 - 8-bit (highest priority)
        .if0_addr(ib_addr_r),
        .if0_addr_nibble(ib_addr_nibble_r),
        .if0_4bit_mode(ib_4bit_mode_r),
        .if0_cache_write_enabled(ib_cache_write_enabled_r),
        .if0_transparency_enabled(ib_transparency_enabled_r),
        .if0_one_byte_cache_cycling(ib_one_byte_cache_cycling_r),
        .if0_mult_accum_cache32(ib_mult_accum_cache32_r),
        .if0_cache8(ib_cache8_r),
        .if0_wrdata(ib_wrdata_r),
        .if0_rddata(vram_rddata),
        .if0_strobe(ib_do_access_r),
        .if0_write(ib_write_r),

        // Interface 1 - 32-bit read only
        .if1_addr(l0_addr),
        .if1_rddata(l0_rddata),
        .if1_strobe(l0_strobe & l0_enabled_r),
        .if1_ack(l0_ack),

        // Interface 2 - 32-bit read only
        .if2_addr(l1_addr),
        .if2_rddata(l1_rddata),
        .if2_strobe(l1_strobe & l1_enabled_r),
        .if2_ack(l1_ack),

        // Interface 3 - 32-bit read only
        .if3_addr(spr_addr),
        .if3_rddata(spr_rddata),
        .if3_strobe(spr_strobe),
        .if3_ack(spr_ack));

    //////////////////////////////////////////////////////////////////////////
    // Renderers
    //////////////////////////////////////////////////////////////////////////
    wire        next_line;

    wire  [9:0] lb_rdidx;
    wire  [7:0] l0_lb_rddata;
    wire  [7:0] l1_lb_rddata;
    wire [15:0] spr_lb_rddata;
    wire        spr_lb_erase_start;

    wire  [8:0] line_idx;
    wire        line_render_start;

    reg active_line_buf_r;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            active_line_buf_r <= 0;
        end else begin
            if (next_line) begin
                active_line_buf_r <= !active_line_buf_r;
            end
        end
    end

    //////////////////////////////////////////////////////////////////////////
    // Layer 0 renderer
    //////////////////////////////////////////////////////////////////////////
    wire  [9:0] l0_linebuf_wridx;
    wire  [7:0] l0_linebuf_wrdata;
    wire        l0_linebuf_wren;

    layer_renderer l0_renderer(
        .rst(reset),
        .clk(clk),

        // Composer interface
        .line_idx(line_idx),
        .line_render_start(line_render_start),

        // Register interface
        .color_depth(l0_color_depth_r),
        .bitmap_mode(l0_bitmap_mode_r),
        .attr_mode(l0_attr_mode_r),
        .tile_height(l0_tile_height_r),
        .tile_width(l0_tile_width_r),
        .map_height(l0_map_height_r),
        .map_width(l0_map_width_r),
        .map_baseaddr(l0_map_baseaddr_r),
        .tile_baseaddr(l0_tile_baseaddr_r),
        .hscroll(l0_hscroll_r),
        .vscroll(l0_vscroll_r),

        // Bus master interface
        .bus_addr(l0_addr),
        .bus_rddata(l0_rddata),
        .bus_strobe(l0_strobe),
        .bus_ack(l0_ack),

        // Line buffer interface
        .linebuf_wridx(l0_linebuf_wridx),
        .linebuf_wrdata(l0_linebuf_wrdata),
        .linebuf_wren(l0_linebuf_wren));

    // Layer 0 line buffer
    layer_line_buffer l0_line_buffer(
        .rst(reset),
        .clk(clk),

        .active_render_buffer(active_line_buf_r),

        // Renderer interface
        .renderer_wr_idx(l0_linebuf_wridx),
        .renderer_wr_data(l0_linebuf_wrdata),
        .renderer_wr_en(l0_linebuf_wren),

        // Composer interface
        .composer_rd_idx(lb_rdidx),
        .composer_rd_data(l0_lb_rddata));

    //////////////////////////////////////////////////////////////////////////
    // Layer 1 renderer
    //////////////////////////////////////////////////////////////////////////
    wire  [9:0] l1_linebuf_wridx;
    wire  [7:0] l1_linebuf_wrdata;
    wire        l1_linebuf_wren;

    layer_renderer l1_renderer(
        .rst(reset),
        .clk(clk),

        // Composer interface
        .line_idx(line_idx),
        .line_render_start(line_render_start),

        // Register interface
        .color_depth(l1_color_depth_r),
        .bitmap_mode(l1_bitmap_mode_r),
        .attr_mode(l1_attr_mode_r),
        .tile_height(l1_tile_height_r),
        .tile_width(l1_tile_width_r),
        .map_height(l1_map_height_r),
        .map_width(l1_map_width_r),
        .map_baseaddr(l1_map_baseaddr_r),
        .tile_baseaddr(l1_tile_baseaddr_r),
        .hscroll(l1_hscroll_r),
        .vscroll(l1_vscroll_r),

        // Bus master interface
        .bus_addr(l1_addr),
        .bus_rddata(l1_rddata),
        .bus_strobe(l1_strobe),
        .bus_ack(l1_ack),

        // Line buffer interface
        .linebuf_wridx(l1_linebuf_wridx),
        .linebuf_wrdata(l1_linebuf_wrdata),
        .linebuf_wren(l1_linebuf_wren));

    // Layer 1 line buffer
    layer_line_buffer l1_line_buffer(
        .rst(reset),
        .clk(clk),

        .active_render_buffer(active_line_buf_r),

        // Renderer interface
        .renderer_wr_idx(l1_linebuf_wridx),
        .renderer_wr_data(l1_linebuf_wrdata),
        .renderer_wr_en(l1_linebuf_wren),

        // Composer interface
        .composer_rd_idx(lb_rdidx),
        .composer_rd_data(l1_lb_rddata));

    //////////////////////////////////////////////////////////////////////////
    // Sprite renderer
    //////////////////////////////////////////////////////////////////////////
    wire  [7:0] sprite_idx;
    wire [31:0] sprite_attr;
    wire  [9:0] sprite_lb_renderer_rd_idx;
    wire [15:0] sprite_lb_renderer_rd_data;
    wire  [9:0] sprite_lb_renderer_wr_idx;
    wire [15:0] sprite_lb_renderer_wr_data;
    wire        sprite_lb_renderer_wr_en;

    sprite_renderer sprite_renderer(
        .rst(reset),
        .clk(clk),

        // Register interface
        .collisions(sprite_collisions),
        .sprcol_irq(sprcol_irq),

        // Composer interface
        .line_idx(line_idx),
        .line_render_start(line_render_start),
        .frame_done(vblank_pulse),

        // Bus master interface
        .bus_addr(spr_addr),
        .bus_rddata(spr_rddata),
        .bus_strobe(spr_strobe),
        .bus_ack(spr_ack),

        // Sprite attribute RAM interface
        .sprite_idx(sprite_idx),
        .sprite_attr(sprite_attr),

        // Line buffer interface
        .linebuf_rdidx(sprite_lb_renderer_rd_idx),
        .linebuf_rddata(sprite_lb_renderer_rd_data),

        .linebuf_wridx(sprite_lb_renderer_wr_idx),
        .linebuf_wrdata(sprite_lb_renderer_wr_data),
        .linebuf_wren(sprite_lb_renderer_wr_en));

    // Sprite line buffer
    sprite_line_buffer sprite_line_buffer(
        .rst(reset),
        .clk(clk),

        .active_render_buffer(active_line_buf_r),

        // Renderer interface
        .renderer_rd_idx(sprite_lb_renderer_rd_idx),
        .renderer_rd_data(sprite_lb_renderer_rd_data),
        .renderer_wr_idx(sprite_lb_renderer_wr_idx),
        .renderer_wr_data(sprite_lb_renderer_wr_data),
        .renderer_wr_en(sprite_lb_renderer_wr_en),

        // Composer interface
        .composer_rd_idx(lb_rdidx),
        .composer_rd_data(spr_lb_rddata),
        .composer_erase_start(spr_lb_erase_start));

    // Sprite attribute RAM
    wire        sprite_attr_write  = (ib_addr_r[16:10] == 'b1111111) && ib_do_access_r && ib_write_r;
    wire  [7:0] sprite_attr_wraddr = ib_addr_r[9:2];
    wire [31:0] sprite_attr_wrdata = {4{ib_wrdata_r}};

    reg [3:0] sprite_attr_bytesel;
    always @* case (ib_addr_r[1:0])
        3'd0: sprite_attr_bytesel = 4'b0001;
        3'd1: sprite_attr_bytesel = 4'b0010;
        3'd2: sprite_attr_bytesel = 4'b0100;
        3'd3: sprite_attr_bytesel = 4'b1000;
    endcase

    sprite_ram sprite_attr_ram(
        // 2026-06-21: sim/sprite_ram.v doesn't have rst_i either.
        .wr_clk_i(clk),
        .rd_clk_i(clk),
        .wr_clk_en_i(1'b1),
        .rd_en_i(1'b1),
        .rd_clk_en_i(1'b1),
        .wr_en_i(sprite_attr_write),
        .wr_data_i(sprite_attr_wrdata),
        .ben_i(sprite_attr_bytesel),
        .wr_addr_i(sprite_attr_wraddr),
        .rd_addr_i(sprite_idx),
        .rd_data_o(sprite_attr));

    //////////////////////////////////////////////////////////////////////////
    // Composer
    //////////////////////////////////////////////////////////////////////////
    wire [7:0] composer_display_data;
    wire       composer_display_opaque;
    wire       next_pixel;
    wire       next_frame;
    wire       composer_display_current_field;

    wire       dc_interlaced = video_output_mode_r[1];

    composer composer(
        .rst(reset),
        .clk(clk),

        // Register interface
        .interlaced(dc_interlaced),
        .frac_x_incr(dc_hscale_r),
        .frac_y_incr(dc_vscale_r),
        .border_color(dc_border_color_r),
        .active_hstart(dc_active_hstart_r),
        .active_hstop(dc_active_hstop_r),
        .active_vstart(dc_active_vstart_r),
        .active_vstop(dc_active_vstop_r),
        .irqline(irq_line_r),
        .layer0_enabled(l0_enabled_r),
        .layer1_enabled(l1_enabled_r),
        .sprites_enabled(sprites_enabled_r),

        .current_field(current_field),
        .line_irq(line_irq),
        .scanline(scanline),

        // Render interface
        .line_idx(line_idx),
        .line_render_start(line_render_start),
        .lb_rdidx(lb_rdidx),
        .layer0_lb_rddata(l0_lb_rddata),
        .layer1_lb_rddata(l1_lb_rddata),
        .sprite_lb_rddata(spr_lb_rddata),
        .sprite_lb_erase_start(spr_lb_erase_start),

        // Display interface
        .display_next_frame(next_frame),
        .display_next_line(next_line),
        .display_next_pixel(next_pixel),
        .display_current_field(composer_display_current_field),
        .display_data(composer_display_data),
        .display_opaque(composer_display_opaque));

    // Delay the opacity bit by one clock to align with palette_rgb_data (the
    // palette read stage), then it rides video_vga's and top's output
    // registers alongside vga_r/g/b -- see video_vga.opaque_in / vga_opaque.
    reg composer_display_opaque_r;
    always @(posedge clk) composer_display_opaque_r <= composer_display_opaque;

    //////////////////////////////////////////////////////////////////////////
    // Palette
    //////////////////////////////////////////////////////////////////////////
    wire [15:0] palette_rgb_data;

    wire        palette_write   = (ib_addr_r[16:9] == 'b11111101) && ib_do_access_r && ib_write_r;
    wire  [1:0] palette_bytesel = ib_addr_r[0] ? 2'b10 : 2'b01;
    wire  [7:0] palette_wridx   = ib_addr_r[8:1];
    wire [15:0] palette_wrdata  = {2{ib_wrdata_r}};

    palette_ram palette_ram(
        // 2026-06-21: sim/palette_ram.v doesn't have rst_i (Quartus inferable
        // version vs. Lattice IP), so drop the unused reset connection.
        .wr_clk_i(clk),
        .rd_clk_i(clk),
        .wr_clk_en_i(1'b1),
        .rd_en_i(1'b1),
        .rd_clk_en_i(1'b1),
        .wr_en_i(palette_write),
        .wr_data_i(palette_wrdata),
        .ben_i(palette_bytesel),
        .wr_addr_i(palette_wridx),
        .rd_addr_i(composer_display_data),
        .rd_data_o(palette_rgb_data));

    //////////////////////////////////////////////////////////////////////////
    // Composite video
    //////////////////////////////////////////////////////////////////////////
    wire       video_composite_next_frame;
    wire       video_composite_next_line;
    wire       video_composite_display_next_pixel;
    wire       video_composite_vblank_pulse;

    wire [5:0] video_composite_luma, video_composite_chroma;
    wire [3:0] video_rgb_r, video_rgb_g, video_rgb_b;
    wire       video_rgb_sync_n;

    // 2026-06-22: NTSC composite encoder restored.  C5G has no NTSC pin and
    // no external DAC, so the analog signal isn't usable for a TV.  The
    // luma[5] / chroma[5] outputs are routed to GPIO in C5G_min for scope
    // verification of the encoder's timing.
    video_composite video_composite(
        .rst(reset),
        .clk(clk),

        // Line buffer / palette interface
        .palette_rgb_data(palette_rgb_data[11:0]),

        .next_frame(video_composite_next_frame),
        .next_line(video_composite_next_line),
        .next_pixel(video_composite_display_next_pixel),
        .vblank_pulse(video_composite_vblank_pulse),
        .current_field(composer_display_current_field),

        // Composite interface
        .luma(video_composite_luma),
        .chroma(video_composite_chroma),

        // RGB interface (NTSC-RGB component path, not used here)
        .rgb_r(video_rgb_r),
        .rgb_g(video_rgb_g),
        .rgb_b(video_rgb_b),
        .rgb_sync_n(video_rgb_sync_n));

    // Pipe the encoder taps to the new top-level outputs.
    assign composite_luma   = video_composite_luma;
    assign composite_chroma = video_composite_chroma;

    //////////////////////////////////////////////////////////////////////////
    // VGA video
    //////////////////////////////////////////////////////////////////////////
    wire       video_vga_next_frame;
    wire       video_vga_next_line;
    wire       video_vga_display_next_pixel;
    wire       video_vga_vblank_pulse;

    wire [3:0] video_vga_r, video_vga_g, video_vga_b;
    wire       video_vga_hsync, video_vga_vsync, video_vga_de;
    wire       video_vga_opaque;

    video_vga video_vga(
        .rst(reset),
        .clk(clk),

        // Palette interface
        .palette_rgb_data(palette_rgb_data[11:0]),

        .next_frame(video_vga_next_frame),
        .next_line(video_vga_next_line),
        .next_pixel(video_vga_display_next_pixel),
        .vblank_pulse(video_vga_vblank_pulse),

        // VGA interface
        .vga_r(video_vga_r),
        .vga_g(video_vga_g),
        .vga_b(video_vga_b),
        .vga_hsync(video_vga_hsync),
        .vga_vsync(video_vga_vsync),
        .vga_de(video_vga_de),
        .opaque_in(composer_display_opaque_r),
        .vga_opaque(video_vga_opaque));

    //////////////////////////////////////////////////////////////////////////
    // Video output selection
    //
    // jyv 2026-07-07 (MiSTer fallback): the MiSTer scan-out is HDMI/VGA
    // only -- there is no NTSC composite or 15 kHz RGB sink, and the old
    // faithful mux killed hsync/vsync/DE the instant a program selected
    // output mode 2 (NTSC) or 3 (RGB), dropping the HDMI link until reset
    // (mode 0 "off" did the same).  Instead the whole render + scan-out
    // pipeline now ALWAYS runs the VGA timing:
    //   mode 0 (off)        -> black screen, but sync/DE keep running so
    //                          the scaler never loses lock
    //   mode 1 (VGA)        -> normal picture
    //   modes 2/3 (NTSC/RGB)-> the same picture on VGA timing (content
    //                          stays visible instead of a dead display;
    //                          geometry authored for 240p NTSC will simply
    //                          show as the equivalent VGA frame)
    // The register value itself is preserved (readback + chroma_disable
    // semantics untouched), and the composite encoder still runs for the
    // luma/chroma debug taps.
    //////////////////////////////////////////////////////////////////////////
    assign next_frame   = video_vga_next_frame;
    assign next_line    = video_vga_next_line;
    assign next_pixel   = video_vga_display_next_pixel;
    assign vblank_pulse = video_vga_vblank_pulse;

    wire display_on = (video_output_mode_r != 2'b00);

    always @(posedge clk) begin
        vga_r      <= display_on ? video_vga_r : 4'd0;
        vga_g      <= display_on ? video_vga_g : 4'd0;
        vga_b      <= display_on ? video_vga_b : 4'd0;
        vga_hsync  <= video_vga_hsync;
        vga_vsync  <= video_vga_vsync;
        vga_de     <= video_vga_de;
        vga_opaque <= display_on & video_vga_opaque;   // no VERA output -> no sprites
    end

    //////////////////////////////////////////////////////////////////////////
    // FPGA reconfiguration
    //////////////////////////////////////////////////////////////////////////
    // 2026-06-21: Phase 1 strip -- WARMBOOT is a Lattice iCE40 primitive used
    // to trigger FPGA self-reconfiguration.  No equivalent on Cyclone V, and
    // the X16 doesn't actually depend on it for normal operation.  Drop it.

    //////////////////////////////////////////////////////////////////////////
    // SPI interface
    //////////////////////////////////////////////////////////////////////////
    assign spi_ssel_n_sd = !spi_select_r;

    // 2026-06-22: SPI controller restored (was Phase-1 stripped).  Drives
    // the on-board uSD slot via SD_CLK/SD_CMD/SD_DAT[0,3] from C5G_min.
    spictrl spictrl(
        .rst(reset),
        .clk(clk),

        // Register interface
        .txdata(spi_txdata),
        .txstart(spi_txstart),
        .rxdata(spi_rxdata),
        .busy(spi_busy),

        // Force SD SPI slow (~390 kHz) so the HPS sd_card bridge (clk_spi = cpu_clk,
        // 8 MHz) has huge oversampling margin and clean MISO timing.  R49's FAST read
        // uses auto-transmit with NO busy-poll and would starve at this speed -- so we
        // instead make VERA STALL each $9F3E read until the transfer completes (see the
        // spi_busy gate on cpu_rdy in x16.sv), which makes R49's fast read wait per
        // byte and work correctly even at slow sck.
        .slow(1'b1),

        // SPI interface
        .spi_sck(spi_sck),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso));

    //////////////////////////////////////////////////////////////////////////
    // Audio  (2026-06-21: restored after stub-out for the "Hello X16" build.)
    //////////////////////////////////////////////////////////////////////////
    wire audio_write = (ib_addr_r[16:6] == 'b11111100111) && ib_do_access_r && ib_write_r;

    audio audio(
        .rst(reset),
        .clk(clk),

        // PSG interface
        .attr_addr(ib_addr_r[5:0]),
        .attr_wrdata(ib_wrdata_r),
        .attr_write(audio_write),

        // Register interface
        .sample_rate(audio_pcm_sample_rate_r),
        .mode_stereo(audio_mode_stereo_r),
        .mode_16bit(audio_mode_16bit_r),
        .volume(audio_pcm_volume_r),

        // Audio FIFO interface
        .fifo_reset(audio_fifo_reset_r),
        .fifo_wrdata(audio_fifo_wrdata_r),
        .fifo_write(audio_fifo_write_r),
        .fifo_full(audio_fifo_full),
        .fifo_almost_empty(audio_fifo_low),
        .fifo_empty(audio_fifo_empty),

        // I2S audio output
        .i2s_lrck(audio_lrck),
        .i2s_bck(audio_bck),
        .i2s_data(audio_data));

endmodule
