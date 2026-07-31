//============================================================================
// sd_block.sv  --  SD block device with DMA, for X816.
//
// The guest "SD card" is a FAT32 image file on the MiSTer's own SD card,
// served block-by-block by the HPS through hps_io's virtual block interface.
// FAT32 is parsed by the guest; the HPS only moves 512-byte blocks.
//
// WHY THIS IS NOT THE X16's SD PATH
//
// The Commander X16 reaches its card by bit-banging VERA's SPI port at $9F3E,
// and the X16 MiSTer core emulates an SPI card behind it (spi_sd_master100.sv)
// -- which is why that core has to stall the CPU on $9F3E reads until queued
// bytes have shifted out.  Software then writes CMD17/CMD24 sequences, CRC7
// and R1 polling, and shifts 512 bytes one at a time through a register.
//
// X816 is not an X16 and its kernel is being written from scratch
// (doc/KERNEL.md), so there is no reason to inherit any of that.  Here the
// CPU writes an LBA, a 24-bit destination and a block count, and the hardware
// moves the data.  A flat 16 MB machine makes a 24-bit DMA address the
// natural shape, the FAT32 code gets much simpler, and the read-stall hack
// disappears because it was a consequence of the SPI approach.
//
// CLOCKING -- the reason this module is as simple as it is
//
// hps_io runs on clk_sys, and in x816.sv clk_sys IS sdram_clk (100 MHz), the
// same domain as flat_sdram's and bank0_ram's loader ports.  So the block
// buffer, the HPS handshake and the DMA all live in ONE domain and need no
// synchronisers between them.  The only clock crossing is the CPU register
// interface, and it is made trivial by the stall (below).
//
// THE STALL IS LOAD-BEARING, NOT LAZINESS
//
// `busy` gates cpu_rdy, so the CPU is frozen for the whole transfer.  Two
// things fall out of that, both load-bearing:
//
//   1. The CPU issues no memory accesses while the DMA runs, so the loader
//      port has the memory to itself and there is no arbitration question.
//   2. LBA/MEM/COUNT cannot change while the FSM is reading them, so they
//      cross domains as static data -- only the start pulse and the done
//      pulse are real CDC, and both are toggles with 2-FF synchronisers.
//
// `busy` is SET in the cpu_clk domain, combinationally on the command write,
// and only CLEARED by the done toggle coming back.  Setting it late would let
// the instruction after the command write run before the stall took effect.
//
// Software therefore never polls: the instruction following the command write
// executes after the transfer has completed.  Read $9F89 afterwards to check
// for an error.
//
// REGISTERS -- $9F81-$9F8A, in the SYSCTL page.  See doc/MEMORY_MAP.md.
//
//   $9F81-$9F84  LBA[31:0]      block number, little-endian
//   $9F85-$9F87  MEM[23:0]      DMA address, little-endian (READ only)
//   $9F88        COUNT          blocks to transfer, 1-255 (READ only)
//   $9F89        CMD (write)    1 = READ, 2 = WRITE, 3 = READBUF, 4 = RESET
//                STATUS (read)  bit0 busy, bit1 error, bit7 card present
//   $9F8A        DATA           block-buffer window, auto-incrementing
//
// READ streams COUNT blocks straight into memory.  READBUF fetches ONE block
// into the buffer without touching memory -- which is what a FAT chain walk
// or a directory scan wants, since those inspect a few bytes of a sector and
// copying it into RAM first would be wasted work.  WRITE sends the buffer,
// which the CPU fills through $9F8A.
//
// Writes go through the buffer rather than by DMA on purpose: the loader
// ports are write-only, so a memory-to-card DMA would have to read main
// memory through the CPU port, and that means muxing into the stall network
// that flat_sdram.sv's header warns about at length.  Reads are the hot path
// for a filesystem; writes are rare, and buffered writes are still far faster
// than SPI because there is no per-byte command overhead.
//============================================================================

module sd_block (
    // ---- CPU register interface (cpu_clk) --------------------------------
    input  logic        clk,            // cpu_clk
    input  logic        reset_n,
    input  logic        cs,             // $9F80-$9F8F selected
    input  logic        we,
    input  logic  [3:0] addr,           // cpu_a[3:0]
    input  logic  [7:0] wr_data,
    output logic  [7:0] rd_data,
    output logic        rd_sel,         // 1 = this module drives rd_data
    output logic        busy,           // 1 = stall the CPU

    // ---- hps_io virtual block device (sdram_clk) -------------------------
    input  logic        sdram_clk,      // == hps_io clk_sys
    output logic [31:0] sd_lba,
    output logic        sd_rd,
    output logic        sd_wr,
    input  logic        sd_ack,
    input  logic  [8:0] sd_buff_addr,
    input  logic  [7:0] sd_buff_dout,   // HPS -> core
    output logic  [7:0] sd_buff_din,    // core -> HPS
    input  logic        sd_buff_wr,
    input  logic        img_mounted,
    input  logic [63:0] img_size,

    // ---- memory loader port (sdram_clk), shared with the ioctl downloader -
    output logic        dma_wr,
    output logic [23:0] dma_addr,
    output logic  [7:0] dma_data,
    input  logic        dma_busy        // backpressure from flat_sdram/bank0
);

    // ------------------------------------------------------------------
    // CPU-side register file
    // ------------------------------------------------------------------
    logic [31:0] r_lba;
    logic [23:0] r_mem;
    logic  [7:0] r_count;
    logic  [1:0] r_cmd;                 // latched command for the FSM
    logic        start_tgl;             // flips to launch a transfer
    logic        err_cpu;
    logic        card_present;

    // Buffer window pointer, CPU side.
    logic  [8:0] bufptr;

    wire   sub_sel = cs & (addr >= 4'h1) & (addr <= 4'hA);
    assign rd_sel  = sub_sel;

    // done toggle coming back from the sdram domain
    logic done_tgl;                     // sdram domain
    logic [2:0] done_sync;              // cpu domain
    wire  done_pulse = done_sync[2] ^ done_sync[1];

    logic err_sd;                       // sdram domain
    logic [1:0] err_sync;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            r_lba <= 32'd0; r_mem <= 24'd0; r_count <= 8'd1;
            r_cmd <= 2'd0; start_tgl <= 1'b0;
            busy  <= 1'b0; err_cpu <= 1'b0; bufptr <= 9'd0;
            done_sync <= 3'd0; err_sync <= 2'd0;
        end else begin
            done_sync <= {done_sync[1:0], done_tgl};
            err_sync  <= {err_sync[0],    err_sd};

            // Clearing busy is the ONLY thing the sdram side may do to it.
            if (done_pulse) begin
                busy    <= 1'b0;
                err_cpu <= err_sync[1];
            end

            if (cs & we & ~busy) begin
                case (addr)
                    4'h1: r_lba[7:0]    <= wr_data;
                    4'h2: r_lba[15:8]   <= wr_data;
                    4'h3: r_lba[23:16]  <= wr_data;
                    4'h4: r_lba[31:24]  <= wr_data;
                    4'h5: r_mem[7:0]    <= wr_data;
                    4'h6: r_mem[15:8]   <= wr_data;
                    4'h7: r_mem[23:16]  <= wr_data;
                    4'h8: r_count       <= wr_data;
                    4'h9: begin
                        case (wr_data[2:0])
                            3'd1, 3'd2, 3'd3: begin
                                r_cmd     <= wr_data[1:0];
                                start_tgl <= ~start_tgl;
                                // Set busy HERE, in this domain, so the next
                                // instruction is already stalled.
                                busy      <= 1'b1;
                                err_cpu   <= 1'b0;
                                bufptr    <= 9'd0;
                            end
                            3'd4:  bufptr <= 9'd0;   // rewind the window
                            default: ;
                        endcase
                    end
                    4'hA: bufptr <= bufptr + 9'd1;   // data written below
                    default: ;
                endcase
            end
            // A read of the data window advances the pointer too.
            if (cs & ~we & (addr == 4'hA) & ~busy)
                bufptr <= bufptr + 9'd1;
        end
    end

    // Buffer, CPU side (port A).  Written on a $9F8A write, read continuously.
    logic [7:0] buf_a_q;
    wire        buf_a_we = cs & we & (addr == 4'hA) & ~busy;

    always_comb begin
        case (addr)
            4'h1:    rd_data = r_lba[7:0];
            4'h2:    rd_data = r_lba[15:8];
            4'h3:    rd_data = r_lba[23:16];
            4'h4:    rd_data = r_lba[31:24];
            4'h5:    rd_data = r_mem[7:0];
            4'h6:    rd_data = r_mem[15:8];
            4'h7:    rd_data = r_mem[23:16];
            4'h8:    rd_data = r_count;
            4'h9:    rd_data = {card_present, 5'b0, err_cpu, busy};
            4'hA:    rd_data = buf_a_q;
            default: rd_data = 8'h00;
        endcase
    end

    // ------------------------------------------------------------------
    // Card presence.  img_mounted is a pulse in the sdram domain; latch it
    // and expose the level.  img_size == 0 means "unmounted".
    // ------------------------------------------------------------------
    logic present_sd;
    always_ff @(posedge sdram_clk) begin
        if (img_mounted) present_sd <= (img_size != 64'd0);
    end
    logic [1:0] present_sync;
    always_ff @(posedge clk) present_sync <= {present_sync[0], present_sd};
    assign card_present = present_sync[1];

    // ------------------------------------------------------------------
    // 512-byte block buffer -- true dual port, A = cpu_clk, B = sdram_clk.
    // The two sides never touch it at the same time: the CPU fills or drains
    // it only while idle, the HPS and the DMA only while busy.
    // ------------------------------------------------------------------
    (* ramstyle = "M10K" *) logic [7:0] blkbuf [0:511];

    logic [8:0] buf_b_addr;
    logic       buf_b_we;
    logic [7:0] buf_b_din;
    logic [7:0] buf_b_q;

    always_ff @(posedge clk) begin
        if (buf_a_we) blkbuf[bufptr] <= wr_data;
        buf_a_q <= blkbuf[bufptr];
    end

    always_ff @(posedge sdram_clk) begin
        if (buf_b_we) blkbuf[buf_b_addr] <= buf_b_din;
        buf_b_q <= blkbuf[buf_b_addr];
    end

    // ------------------------------------------------------------------
    // Transfer FSM (sdram_clk)
    // ------------------------------------------------------------------
    localparam CMD_READ    = 2'd1;
    localparam CMD_WRITE   = 2'd2;
    localparam CMD_READBUF = 2'd3;

    typedef enum logic [2:0] {
        S_IDLE, S_REQ, S_WAIT, S_DMA, S_NEXT, S_DONE
    } state_t;
    state_t st;

    logic [2:0] start_sync;
    wire        start_pulse = start_sync[2] ^ start_sync[1];

    logic [31:0] lba_r;
    logic [23:0] mem_r;
    logic  [7:0] blk_left;
    logic  [1:0] cmd_r;
    logic  [8:0] dma_i;
    logic        ack_q;

    always_ff @(posedge sdram_clk or negedge reset_n) begin
        if (!reset_n) begin
            st <= S_IDLE; sd_rd <= 1'b0; sd_wr <= 1'b0;
            done_tgl <= 1'b0; err_sd <= 1'b0; dma_wr <= 1'b0;
            start_sync <= 3'd0; ack_q <= 1'b0;
        end else begin
            start_sync <= {start_sync[1:0], start_tgl};
            ack_q      <= sd_ack;
            dma_wr     <= 1'b0;

            case (st)
            S_IDLE: begin
                if (start_pulse) begin
                    // Safe to sample these unsynchronised: the CPU is stalled
                    // from the cycle it wrote the command, so they are static.
                    lba_r    <= r_lba;
                    mem_r    <= r_mem;
                    cmd_r    <= r_cmd;
                    blk_left <= (r_cmd == CMD_READ) ? r_count : 8'd1;
                    err_sd   <= 1'b0;
                    st       <= S_REQ;
                end
            end

            S_REQ: begin
                sd_lba <= lba_r;
                if (cmd_r == CMD_WRITE) sd_wr <= 1'b1;
                else                    sd_rd <= 1'b1;
                st <= S_WAIT;
            end

            // hps_io holds sd_ack high while it streams the buffer; the
            // request is dropped on ack and the transfer is complete when
            // ack falls again.
            S_WAIT: begin
                if (sd_ack) begin
                    sd_rd <= 1'b0;
                    sd_wr <= 1'b0;
                end
                if (ack_q & ~sd_ack) begin
                    if (cmd_r == CMD_READ) begin
                        dma_i <= 9'd0;
                        st    <= S_DMA;
                    end else begin
                        st <= S_NEXT;
                    end
                end
            end

            // Stream the buffer into main memory.  dma_busy is the loader
            // FIFO's backpressure -- hold the index when it is asserted.
            S_DMA: begin
                if (!dma_busy) begin
                    dma_wr   <= 1'b1;
                    dma_addr <= mem_r + {15'd0, dma_i};
                    dma_data <= buf_b_q;
                    if (dma_i == 9'd511) st <= S_NEXT;
                    else                 dma_i <= dma_i + 9'd1;
                end
            end

            S_NEXT: begin
                if (blk_left <= 8'd1) st <= S_DONE;
                else begin
                    blk_left <= blk_left - 8'd1;
                    lba_r    <= lba_r + 32'd1;
                    mem_r    <= mem_r + 24'd512;
                    st       <= S_REQ;
                end
            end

            S_DONE: begin
                done_tgl <= ~done_tgl;
                st       <= S_IDLE;
            end
            endcase
        end
    end

    // Port B is the HPS's while a request is in flight, the DMA's afterwards.
    always_comb begin
        if (st == S_DMA) begin
            buf_b_addr = dma_i;
            buf_b_we   = 1'b0;
            buf_b_din  = 8'h00;
        end else begin
            buf_b_addr = sd_buff_addr;
            buf_b_we   = sd_buff_wr;
            buf_b_din  = sd_buff_dout;
        end
    end

    assign sd_buff_din = buf_b_q;

endmodule
