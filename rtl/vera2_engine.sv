//============================================================================
// vera2_engine.sv  -  SDRAM-backed linear-framebuffer scanout layer.
//
// Ported from x16_mister/rtl/bitmap_engine.sv.  VERA advertises 640x480 bitmap
// modes but its 128 KB VRAM cannot hold one, and X816 gave the VRAM that would
// have held it to program BRAM instead (doc/MEMORY_MAP.md).  This engine scans a
// linear framebuffer out of SDRAM, composited over VERA's output by a mux in
// x816.sv.  VERA itself is untouched.  OSD-gated, off by default.
//
// WHAT CHANGED IN THE PORT
//
//   * FB_BASE_WORD is 24'hE00000, the word base of the framebuffer window
//     flat_sdram.sv maps for banks $E0-$EF.  The framebuffer is ORDINARY CPU
//     MEMORY at $E0:0000 -- software draws with plain stores and MVN block
//     moves.  Upstream's framebuffer is unreachable except through a data
//     port, which is why its register block carries ADDR/DATA and a copy
//     blitter and ours does not (doc/VERA2.md).
//
//   * DISPLAY BASE.  Upstream always scans from offset 0 and vera_2.md lists
//     double-buffering as future work.  disp_base here is a byte offset into
//     the 1 MB window, latched at vsync, so a page flip is one register write
//     and is tear-free by construction.  1 MB holds two 8bpp frames (2 x
//     307,200) or six 4bpp ones.
//
// SPEED, MEASURED (sim/run.sh vfb T9).  A line is 3200 sdram_clk and
// flat_sdram's FB_CYC early-completion path delivers ~8.1 clocks per word:
//     640x480 4bpp = 160 words = ~1300 clk  -- FITS
//     640x480 8bpp = 320 words = ~2595 clk  -- FITS, ~600 clk/line spare
// Both modes are usable.  (The first port of this engine ran the fetch
// through the generic 11-clock access envelope, where 8bpp missed by 12%;
// flat_sdram's FB_CYC comment records the fix.)
//
// PIXEL PIPELINE (pix_clk):  the framebuffer is prefetched one scanline ahead
// into a ping-pong line buffer, then scanned:
//     scan_x -> linebuf[disp_page] -> palette -> bmp_r/g/b
// bmp_active is `de` delayed by the pipeline depth so the colour lines up with
// VERA's active window (the mux only shows bitmap pixels while DE is high).
//
// LINE FETCH (sdram_clk):  at each new active line we ask flat_sdram to stream
// the NEXT line's words (fb_go/fb_base/fb_len -> fb_valid/fb_word), and unpack
// each 16-bit word into pixels.  One word = two 8bpp pixels {odd,even} or four
// 4bpp pixels.  The fetch runs at LOWEST priority inside flat_sdram, so it can
// never stall the CPU for more than one access.
//
// Palette: 256 x RGB444, independent of VERA, written from the register block
// (pal_clk domain).  4bpp uses entries 0..15.
//============================================================================
module vera2_engine #(

    parameter [23:0] FB_BASE_WORD = 24'hE00000   // word base of the $E0-$EF window
)(
    // ---- scanout / pixel domain (pix_clk, 25 MHz) ----
    input  wire        pix_clk,
    input  wire        reset_n,       // async reset (resets both clock domains)
    input  wire        enable,        // master enable (OSD & ctrl.enable)
    input  wire  [1:0] mode,          // 1=640x480x8bpp, 2=640x480x4bpp, else off
    input  wire        de,            // VERA active-display strobe
    input  wire        vs,            // VERA vsync (frame start on rising edge)
    input  wire [19:0] disp_base,     // byte offset of the displayed frame
    output reg   [3:0] bmp_r,
    output reg   [3:0] bmp_g,
    output reg   [3:0] bmp_b,
    output wire        bmp_active,    // 1 = show bitmap pixel (mux select)

    // ---- palette write port (pal_clk = cpu_clk in the SoC) ----
    input  wire        pal_clk,
    input  wire        pal_we,
    input  wire  [7:0] pal_idx,
    input  wire [11:0] pal_data,      // {R[3:0], G[3:0], B[3:0]}

    // ---- SDRAM framebuffer read stream (sdram_clk, 100 MHz) ----
    input  wire        sdram_clk,
    output reg         fb_go,
    output reg  [23:0] fb_base,
    output reg  [10:0] fb_len,
    input  wire        fb_valid,
    input  wire [15:0] fb_word,
    input  wire        fb_done
);
    // DE_TAP: `de` delayed this many pix_clks == the scan pipeline depth, so
    // bmp_active/bmp_rgb line up with the correct source pixel.  (scan_x reg +
    // linebuf read reg + palette read reg + output reg = 4; de_sr[3] is de
    // delayed by 4.)  Verified in sim/tb_bitmap.v.
    localparam integer DE_TAP = 3;

    wire mode_ok = enable & (mode == 2'd1 || mode == 2'd2);

    // ======================================================================
    // Dual-clock storage
    // ======================================================================
    // 2 pages, addressed {page, x[9:0]} -> page 1 starts at 1024 (x is 10-bit,
    // not 640-strided), so the array must span 2048.
    (* ramstyle = "no_rw_check" *) reg [7:0]  linebuf [0:2047];
    (* ramstyle = "no_rw_check" *) reg [11:0] pal     [0:255];

    // palette write (pal_clk)
    always @(posedge pal_clk) if (pal_we) pal[pal_idx] <= pal_data;

    // ======================================================================
    // Scanout (pix_clk)
    // ======================================================================
    reg        de_r, vs_r;
    reg  [9:0] scan_x;
    reg        disp_page;
    reg  [8:0] active_line;           // line index since frame start
    reg  [7:0] de_sr;

    // line-fetch request to the sdram domain (toggle + latched params)
    reg        req_tgl;
    reg  [8:0] req_line;
    reg        req_page;
    // Latched at vsync, NOT used live: a page flip written mid-frame must take
    // effect at the next frame boundary or the picture tears across the seam.
    // This is the whole point of having a display base at all.
    reg [19:0] disp_base_l;

    // pipeline regs
    reg  [7:0] lb_rd;
    reg [11:0] pal_rd;

    wire vs_rise = vs & ~vs_r;
    wire de_rise = de & ~de_r;

    always @(posedge pix_clk or negedge reset_n) begin
      if (!reset_n) begin
        de_r <= 0; vs_r <= 0; de_sr <= 0; scan_x <= 0; disp_page <= 0;
        active_line <= 0; req_tgl <= 0; req_line <= 0; req_page <= 0;
        disp_base_l <= 0;
        lb_rd <= 0; pal_rd <= 0; bmp_r <= 0; bmp_g <= 0; bmp_b <= 0;
      end else begin
        de_r  <= de;
        vs_r  <= vs;
        de_sr <= {de_sr[6:0], de};

        if (vs_rise) begin
            // frame start: schedule fetch of line 0 into page 0 (during vblank)
            active_line <= 9'd0;
            disp_base_l <= disp_base;   // page flips land here, between frames
            if (mode_ok) begin
                req_line <= 9'd0;
                req_page <= 1'b0;
                req_tgl  <= ~req_tgl;
            end
        end

        if (de_rise) begin
            // a new active line begins: it is `active_line`, held in page
            // active_line[0] (fetched during the previous line / vblank).
            disp_page <= active_line[0];
            scan_x    <= 10'd0;
            // schedule fetch of the NEXT line into the alternate page
            if (mode_ok && (active_line + 9'd1 < 9'd480)) begin
                req_line <= active_line + 9'd1;
                req_page <= ~active_line[0];
                req_tgl  <= ~req_tgl;
            end
            active_line <= active_line + 9'd1;
        end else if (de) begin
            scan_x <= scan_x + 10'd1;
        end

        // read pipeline (always clocks; garbage outside the active window is
        // masked by bmp_active)
        lb_rd  <= linebuf[{disp_page, scan_x}];
        pal_rd <= pal[lb_rd];
        bmp_r  <= pal_rd[11:8];
        bmp_g  <= pal_rd[7:4];
        bmp_b  <= pal_rd[3:0];
      end
    end

    assign bmp_active = mode_ok & de_sr[DE_TAP];

    // ======================================================================
    // Line fetch + unpack (sdram_clk)
    // ======================================================================
    // mode synced into this domain (config-time signal; 2FF is plenty)
    reg [1:0] mode_s1, mode_s2;
    always @(posedge sdram_clk) begin mode_s1 <= mode; mode_s2 <= mode_s1; end
    wire       is8     = (mode_s2 == 2'd1);
    wire [10:0] wpl    = is8 ? 11'd320 : 11'd160;  // words per line
    wire [1:0] lastsub = is8 ? 2'd1 : 2'd3;        // last pixel index within a word

    // CDC of the request toggle (req_line/req_page are stable across the flip)
    reg [1:0] reqs;
    reg       reqd;
    reg       pend;
    reg [8:0] pl;
    reg       pp;
    reg [19:0] pb;   // disp_base_l, captured with the request

    localparam F_IDLE = 2'd0, F_RUN = 2'd1, F_UNP = 2'd2;
    reg [1:0]  fstate;
    reg        fpage;
    reg  [9:0] wr_x;
    reg [15:0] word_r;
    reg  [1:0] sub;
    reg        last_r;

    // linebuf write strobes
    reg        lb_we;
    reg [10:0] lb_waddr;
    reg  [7:0] lb_wdata;

    always @(posedge sdram_clk) if (lb_we) linebuf[lb_waddr] <= lb_wdata;

    // pixel selector: extract pixel `s` of `w` for the current bpp
    function [7:0] pixsel(input [15:0] w, input [1:0] s, input is8bpp);
        begin
            if (is8bpp)
                pixsel = s[0] ? w[15:8] : w[7:0];         // odd=high, even=low
            else case (s)                                  // 4bpp, hi nibble=left
                2'd0: pixsel = {4'b0, w[7:4]};
                2'd1: pixsel = {4'b0, w[3:0]};
                2'd2: pixsel = {4'b0, w[15:12]};
                default: pixsel = {4'b0, w[11:8]};
            endcase
        end
    endfunction

    always @(posedge sdram_clk or negedge reset_n) begin
      if (!reset_n) begin
        reqs <= 0; reqd <= 0; pend <= 0; pl <= 0; pp <= 0; pb <= 0;
        fstate <= F_IDLE; fpage <= 0; wr_x <= 0; word_r <= 0; sub <= 0;
        last_r <= 0; fb_go <= 0; fb_base <= 0; fb_len <= 0;
        lb_we <= 0; lb_waddr <= 0; lb_wdata <= 0;
      end else begin
        reqs <= {reqs[0], req_tgl};
        reqd <= reqs[1];
        if (reqs[1] != reqd) begin
            pend <= 1'b1;
            pl   <= req_line;
            pp   <= req_page;
            pb   <= disp_base_l;   // stable across the toggle, like pl/pp
        end

        fb_go <= 1'b0;
        lb_we <= 1'b0;

        case (fstate)
            F_IDLE: if (pend) begin
                pend     <= 1'b0;
                fb_base  <= FB_BASE_WORD + {5'b0, pb[19:1]} + (pl * wpl);
                fb_len   <= wpl;
                fb_go    <= 1'b1;
                fpage    <= pp;
                wr_x     <= 10'd0;
                fstate   <= F_RUN;
            end

            F_RUN: if (fb_valid) begin
                word_r <= fb_word;
                last_r <= fb_done;
                sub    <= 2'd0;
                // write the first pixel of this word right away
                lb_we    <= 1'b1;
                lb_waddr <= {fpage, wr_x};
                lb_wdata <= pixsel(fb_word, 2'd0, is8);
                wr_x     <= wr_x + 10'd1;
                fstate   <= F_UNP;
            end

            F_UNP: begin
                lb_we    <= 1'b1;
                lb_waddr <= {fpage, wr_x};
                lb_wdata <= pixsel(word_r, sub + 2'd1, is8);
                wr_x     <= wr_x + 10'd1;
                sub      <= sub + 2'd1;
                if ((sub + 2'd1) == lastsub) begin
                    fstate <= last_r ? F_IDLE : F_RUN;
                end
            end

            default: fstate <= F_IDLE;
        endcase
      end
    end

endmodule
