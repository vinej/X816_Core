//============================================================================
// vera2_regs.sv  --  CPU register block for the VERA2 bitmap layer, $9F60-$9F6F.
//
// Adapted from x16_mister/rtl/bitmap_regs.sv, and DELIBERATELY MUCH SMALLER.
// Upstream carries a 20-bit ADDR pointer, a DATA port with signed
// auto-increment strides, and a copy blitter -- all of which exist for one
// reason: its framebuffer lives in SDRAM that the CPU cannot address.
//
// X816's framebuffer IS ordinary CPU memory, at $E0:0000-$EF:FFFF
// (X816_VFB_BASE).  Software draws with plain stores, C pointers and MVN block
// moves at 7 cycles/byte -- which is faster and simpler than a byte-at-a-time
// data port, and needs no registers here at all.  So ADDR/DATA and the blitter
// are not ported, and their slots carry something upstream wanted and could
// not have instead:
//
//   A DISPLAY BASE.  vera_2.md section 8 lists double-buffering as future work
//   because the layer always scans from offset 0.  DISPBASE here is a byte
//   offset into the 1 MB window, latched by the engine at vsync, so a page
//   flip is one register write and is tear-free by construction.  1 MB holds
//   two 8bpp frames (2 x 307,200) or six 4bpp frames (6 x 153,600).
//
// REGISTER MAP
//
//   $9F60  CTRL    R/W  [0] enable, [2:1] mode, [3] passthru
//                       mode 1 = 640x480 8bpp, mode 2 = 640x480 4bpp,
//                       0 and 3 = off.  passthru shows VERA's opaque pixels
//                       (sprites, mouse) OVER the bitmap.
//                       Read: {4'b0, passthru, mode, enable}
//   $9F61  ID      R    $B5 -- feature detect.  Reads $00 when the OSD master
//                       switch is off, so software can tell "no layer" from
//                       "layer present but disabled".
//   $9F62  DISPL   R/W  display base, byte offset [7:0]  (bit 0 ignored --
//                       the fetch works in 16-bit words, so the base is even)
//   $9F63  DISPM   R/W  [15:8]
//   $9F64  DISPH   R/W  [19:16] in bits [3:0]; [7:4] read 0
//   $9F66  PALADR  W    palette index, auto-increments after PALHI
//   $9F67  PALLO   W    {G[3:0], B[3:0]}, latched
//   $9F68  PALHI   W    {----, R[3:0]} -> commits {R,G,B} to palette[idx], idx++
//
//   $9F65, $9F69-$9F6F  reserved; read $00, writes ignored.  ($9F65 is
//   upstream's DATA and $9F69-$9F6F its blitter -- see above for why neither
//   is here.)
//
// Everything resets to 0, so the layer is off and invisible until software
// asks for it, and the OSD master switch gates it besides.
//============================================================================
module vera2_regs #(
    parameter [7:0] MAGIC_ID = 8'hB5
)(
    input  wire        clk,          // cpu_clk
    input  wire        reset_n,
    input  wire        cs,           // $9F60-$9F6F selected
    input  wire        rwn,          // 1 = read
    input  wire        cpu_rdy,      // commit only on a real bus cycle
    input  wire  [3:0] addr,         // cpu_a[3:0]
    input  wire  [7:0] di,
    output reg   [7:0] do_o,

    input  wire        master_en,    // OSD master enable
    output wire        bmp_enable,   // -> vera2_engine.enable
    output wire  [1:0] bmp_mode,     // -> vera2_engine.mode
    output wire        bmp_passthru, // -> the composition mux in x816.sv
    output wire [19:0] disp_base,    // -> vera2_engine.disp_base

    // palette write port -> vera2_engine (pal_clk = this clk)
    output reg         pal_we,
    output reg   [7:0] pal_idx,
    output reg  [11:0] pal_data
);

    reg        enable_r;
    reg  [1:0] mode_r;
    reg        passthru_r;
    reg [19:0] disp_r;
    reg  [7:0] pal_lo;
    reg  [7:0] cur_idx;

    // The layer only runs when BOTH the OSD switch and software agree, which
    // is what makes the core bit-identical to stock with the switch off.
    assign bmp_enable   = enable_r & master_en;
    assign bmp_mode     = mode_r;
    assign bmp_passthru = passthru_r;
    assign disp_base    = disp_r;

    // Single-cycle commit: cpu_rdy is the bus-cycle enable, so a stalled CPU
    // holding the same address does not write twice or auto-increment twice.
    wire acc = cs & cpu_rdy;
    wire wr  = acc & ~rwn;

    always @* begin
        case (addr)
            4'h0:    do_o = {4'b0, passthru_r, mode_r, enable_r};
            // ID reads 0 when the OSD switch is off: "absent" and "present but
            // disabled" are different answers and software wants both.
            4'h1:    do_o = master_en ? MAGIC_ID : 8'h00;
            4'h2:    do_o = disp_r[7:0];
            4'h3:    do_o = disp_r[15:8];
            4'h4:    do_o = {4'b0, disp_r[19:16]};
            default: do_o = 8'h00;
        endcase
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            enable_r   <= 1'b0;
            mode_r     <= 2'd0;
            passthru_r <= 1'b0;
            disp_r     <= 20'd0;
            pal_lo     <= 8'h00;
            cur_idx    <= 8'h00;
            pal_we     <= 1'b0;
            pal_idx    <= 8'h00;
            pal_data   <= 12'h000;
        end else begin
            pal_we <= 1'b0;          // single-cycle strobe

            if (wr) begin
                case (addr)
                    4'h0: begin
                        enable_r   <= di[0];
                        mode_r     <= di[2:1];
                        passthru_r <= di[3];
                    end
                    4'h2: disp_r[7:0]   <= {di[7:1], 1'b0};  // even bases only
                    4'h3: disp_r[15:8]  <= di;
                    4'h4: disp_r[19:16] <= di[3:0];
                    4'h6: cur_idx <= di;
                    4'h7: pal_lo  <= di;
                    4'h8: begin
                        // PALHI commits the whole entry and steps the index, so
                        // a palette upload is idx-once then LO/HI pairs.
                        pal_idx  <= cur_idx;
                        pal_data <= {di[3:0], pal_lo};   // {R, G, B}
                        pal_we   <= 1'b1;
                        cur_idx  <= cur_idx + 8'd1;
                    end
                    default: ;   // $9F61 ID, $9F65 and $9F69-$9F6F: read-only
                endcase
            end
        end
    end

endmodule
