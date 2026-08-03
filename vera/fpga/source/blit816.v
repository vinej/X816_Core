//`default_nettype none
//============================================================================
// blit816.v -- VRAM bulk fill/copy engine (doc/BLIT816.md).
//
// WHY THIS EXISTS.  VERA gives the CPU one 8-bit data port, so clearing a
// framebuffer costs one `sta` per byte: the 76,800 bytes of a 320x240 8bpp
// screen is ~38 ms at 8 MHz, a 26 fps ceiling before anything is drawn.  This
// engine does the same fill in under a millisecond by moving 32 bits per VRAM
// slot, which is what makes bitmap modes usable in 128 KB at all.
//
// It runs on a fifth, LOWEST-priority vram_if port, so it can never disturb
// scanout -- it soaks up idle VRAM slots (all of them in blanking, the
// leftovers during active display).  That is also why it has no cycle
// guarantee: it is fast, not deterministic.
//
// 2026-08-02: narrowed from the 19-bit VERA816 address space back to stock
// VERA's 17 bits when VRAM returned to 128 KB.  That also RETIRED A LATENT
// BUG: cache_tag_r is 15 bits and was compared against a 17-bit src_n[18:2],
// so a source read crossing a 128 KB boundary could report a false cache hit
// and copy the wrong bytes.  At 17-bit addresses the widths match exactly.
//
// This is the only non-stock register bank left in VERA; the 352 KB VERA816
// extension removed alongside it lives in git history.
//
// Programming model (registers live in top.v's DCSEL=33 bank, $9F29-$9F2C):
//   BLT_IDX  ($9F29 R/W)  index into the parameter file, 0-9
//   BLT_DATA ($9F2A R/W)  the indexed parameter byte; a WRITE auto-increments
//                         BLT_IDX (reads do not)
//   BLT_CTRL ($9F2B W)    bit0 = start COPY, bit1 = start FILL
//            ($9F2B R)    bit0 = busy
//   BLT_ID   ($9F2C R)    $B6 -- feature detect
//   parameters: 0-2 SRC (17-bit byte addr, little-endian, bit 16 in byte 2)
//               3-5 DST, 6-8 LEN (bytes), 9 = fill VALUE
//
// Semantics (the contract -- emulator implements the same):
//   * Byte-granular: any SRC/DST alignment, any LEN. LEN=0 starts nothing.
//   * COPY is ascending. Overlap is defined only for DST < SRC or disjoint
//     ranges (the "doubling" idiom, DST = SRC+LEN, is disjoint).
//   * Addresses wrap modulo 128 KB, matching stock VERA's data-port
//     auto-increment wrap.  LEN is 17 bits, so one operation covers all VRAM.
//   * SRC/DST/LEN read back as the engine left them (LEN=0, pointers at
//     one-past-end).
//   * Parameter writes while busy are ignored.
//
// Speed: FILL runs at a 32-bit word per granted slot on aligned runs; COPY
// at word-read + word-write per 4 bytes when SRC and DST are co-aligned,
// else byte writes backed by a cached source word (1 read per 4 source
// bytes). Worst case is ~2 slots/byte; best is 4 bytes/slot.
//============================================================================
module blit816(
    input  wire        rst,
    input  wire        clk,

    // Register interface (single-cycle strobes from top.v, DCSEL=33)
    input  wire  [3:0] reg_idx,
    input  wire        reg_data_we,
    input  wire  [7:0] reg_wrdata,
    output reg   [7:0] reg_rddata,
    input  wire        start_copy,
    input  wire        start_fill,
    output wire        busy,

    // VRAM word port (vram_if interface 4 -- lowest priority)
    output reg  [14:0] vram_addr,
    output reg  [31:0] vram_wrdata,
    output reg   [7:0] vram_wrnibblesel,
    input  wire [31:0] vram_rddata,
    output reg         vram_write,
    output wire        vram_strobe,
    input  wire        vram_ack);

    //////////////////////////////////////////////////////////////////////////
    // Parameter file (doubles as the working counters while running)
    //////////////////////////////////////////////////////////////////////////
    reg [16:0] src_r, dst_r, len_r;
    reg  [7:0] val_r;
    reg        op_fill_r;

    always @* case (reg_idx)
        4'd0:    reg_rddata = src_r[7:0];
        4'd1:    reg_rddata = src_r[15:8];
        4'd2:    reg_rddata = {7'b0, src_r[16]};
        4'd3:    reg_rddata = dst_r[7:0];
        4'd4:    reg_rddata = dst_r[15:8];
        4'd5:    reg_rddata = {7'b0, dst_r[16]};
        4'd6:    reg_rddata = len_r[7:0];
        4'd7:    reg_rddata = len_r[15:8];
        4'd8:    reg_rddata = {7'b0, len_r[16]};
        4'd9:    reg_rddata = val_r;
        default: reg_rddata = 8'h00;
    endcase

    //////////////////////////////////////////////////////////////////////////
    // Engine
    //////////////////////////////////////////////////////////////////////////
    localparam [1:0] ST_IDLE = 2'd0, ST_RD = 2'd1, ST_WR = 2'd2;
    reg [1:0]  state_r;
    reg        strobe_r;
    reg        wr_is_word_r;
    reg [31:0] cache_r;         // last source word fetched
    reg [14:0] cache_tag_r;     // its word address
    reg        cache_valid_r;

    assign busy        = (state_r != ST_IDLE);
    assign vram_strobe = strobe_r && !vram_ack;

    // one byte of a 32-bit VRAM word (word layout: byte 0 = bits [7:0])
    function [7:0] word_byte(input [31:0] w, input [1:0] b);
        case (b)
            2'd0: word_byte = w[7:0];
            2'd1: word_byte = w[15:8];
            2'd2: word_byte = w[23:16];
            2'd3: word_byte = w[31:24];
        endcase
    endfunction

    // nibble-select mask for one byte lane
    function [7:0] byte_mask(input [1:0] b);
        case (b)
            2'd0: byte_mask = 8'b0000_0011;
            2'd1: byte_mask = 8'b0000_1100;
            2'd2: byte_mask = 8'b0011_0000;
            2'd3: byte_mask = 8'b1100_0000;
        endcase
    endfunction

    // Post-write pointer/length advance, evaluated combinationally so the ack
    // cycle can both retire this access and launch the next.
    wire [16:0] step   = wr_is_word_r ? 17'd4 : 17'd1;
    wire [16:0] len_n  = len_r - step;
    wire [16:0] dst_n  = dst_r + step;
    wire [16:0] src_n  = src_r + step;

    wire fill_word_first = (len_r >= 17'd4) && (dst_r[1:0] == 2'b00);
    wire fill_word_n     = (len_n >= 17'd4) && (dst_n[1:0] == 2'b00);
    wire copy_word_n     = (len_n >= 17'd4) && (dst_n[1:0] == 2'b00) && (src_n[1:0] == 2'b00);
    wire cache_hit_n     = cache_valid_r && (cache_tag_r == src_n[16:2]);
    wire copy_word_now   = (len_r >= 17'd4) && (dst_r[1:0] == 2'b00) && (src_r[1:0] == 2'b00);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state_r          <= ST_IDLE;
            strobe_r         <= 0;
            wr_is_word_r     <= 0;
            vram_addr        <= 0;
            vram_wrdata      <= 0;
            vram_wrnibblesel <= 0;
            vram_write       <= 0;
            cache_r          <= 0;
            cache_tag_r      <= 0;
            cache_valid_r    <= 0;
            src_r            <= 0;
            dst_r            <= 0;
            len_r            <= 0;
            val_r            <= 0;
            op_fill_r        <= 0;

        end else begin
            // parameter writes land only while idle
            if (reg_data_we && state_r == ST_IDLE) begin
                case (reg_idx)
                    4'd0: src_r[7:0]   <= reg_wrdata;
                    4'd1: src_r[15:8]  <= reg_wrdata;
                    4'd2: src_r[16]    <= reg_wrdata[0];
                    4'd3: dst_r[7:0]   <= reg_wrdata;
                    4'd4: dst_r[15:8]  <= reg_wrdata;
                    4'd5: dst_r[16]    <= reg_wrdata[0];
                    4'd6: len_r[7:0]   <= reg_wrdata;
                    4'd7: len_r[15:8]  <= reg_wrdata;
                    4'd8: len_r[16]    <= reg_wrdata[0];
                    4'd9: val_r        <= reg_wrdata;
                    default: ;
                endcase
            end

            case (state_r)
                ST_IDLE: begin
                    if ((start_fill || start_copy) && len_r != 0) begin
                        op_fill_r     <= start_fill;
                        cache_valid_r <= 0;
                        if (start_fill) begin
                            // first fill write straight away
                            vram_addr        <= dst_r[16:2];
                            vram_wrdata      <= {4{val_r}};
                            vram_wrnibblesel <= fill_word_first ? 8'hFF : byte_mask(dst_r[1:0]);
                            wr_is_word_r     <= fill_word_first;
                            vram_write       <= 1;
                            strobe_r         <= 1;
                            state_r          <= ST_WR;
                        end else begin
                            // copy: fetch the first source word
                            vram_addr  <= src_r[16:2];
                            vram_write <= 0;
                            strobe_r   <= 1;
                            state_r    <= ST_RD;
                        end
                    end
                end

                ST_RD: if (vram_ack) begin
                    cache_r       <= vram_rddata;
                    cache_tag_r   <= src_r[16:2];
                    cache_valid_r <= 1;
                    // launch the write this fetch was for
                    vram_addr        <= dst_r[16:2];
                    vram_wrdata      <= copy_word_now ? vram_rddata
                                                     : {4{word_byte(vram_rddata, src_r[1:0])}};
                    vram_wrnibblesel <= copy_word_now ? 8'hFF : byte_mask(dst_r[1:0]);
                    wr_is_word_r     <= copy_word_now;
                    vram_write       <= 1;
                    strobe_r         <= 1;
                    state_r          <= ST_WR;
                end

                ST_WR: if (vram_ack) begin
                    len_r <= len_n;
                    dst_r <= dst_n;
                    if (!op_fill_r) src_r <= src_n;

                    if (len_n == 0) begin
                        strobe_r   <= 0;
                        vram_write <= 0;
                        state_r    <= ST_IDLE;
                    end else if (op_fill_r) begin
                        vram_addr        <= dst_n[16:2];
                        vram_wrdata      <= {4{val_r}};
                        vram_wrnibblesel <= fill_word_n ? 8'hFF : byte_mask(dst_n[1:0]);
                        wr_is_word_r     <= fill_word_n;
                        vram_write       <= 1;
                        strobe_r         <= 1;
                    end else if (cache_hit_n) begin
                        // next source byte/word is already in the cache
                        vram_addr        <= dst_n[16:2];
                        vram_wrdata      <= copy_word_n ? cache_r
                                                        : {4{word_byte(cache_r, src_n[1:0])}};
                        vram_wrnibblesel <= copy_word_n ? 8'hFF : byte_mask(dst_n[1:0]);
                        wr_is_word_r     <= copy_word_n;
                        vram_write       <= 1;
                        strobe_r         <= 1;
                    end else begin
                        // refill the cache from the next source word
                        vram_addr  <= src_n[16:2];
                        vram_write <= 0;
                        strobe_r   <= 1;
                        state_r    <= ST_RD;
                    end
                end

                default: state_r <= ST_IDLE;
            endcase
        end
    end

endmodule
