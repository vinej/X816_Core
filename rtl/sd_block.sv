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
// CLOCKING
//
// hps_io runs on clk_sys, and in x816.sv clk_sys IS sdram_clk (100 MHz), the
// same domain as flat_sdram's and bank0_ram's loader ports.  So the block
// buffer, the HPS handshake and the DMA all live in ONE domain.  Only the CPU
// register interface crosses, and the stall makes that nearly free.
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
// executes after the transfer has completed.  Read $9F8A afterwards to check
// for an error.
//
// REGISTERS -- $9F81-$9F8C, in the SYSCTL page.  See doc/MEMORY_MAP.md.
//
//   $9F81-$9F84  LBA[31:0]      block number, little-endian
//   $9F85-$9F87  MEM[23:0]      DMA address, little-endian (READ only)
//   $9F88        COUNT          blocks to transfer, 1-255 (READ only)
//   $9F89        CMD            WRITE ONLY. 1 = READ, 2 = WRITE,
//                                3 = READBUF, 4 = RESET
//   $9F8A        STATUS         READ ONLY. bit0 busy, bit1 error,
//                                bit7 card present
//   $9F8B        -- MUST STAY UNMAPPED, see below --
//   $9F8C        DATA           block-buffer window, auto-incrementing
//
// CMD AND STATUS ARE SEPARATE ADDRESSES ON PURPOSE.
//
// The obvious design is one register: write a command, read the status back.
// It does not survive a C compiler. Calypsi ELIDES A VOLATILE READ that
// immediately follows a volatile write to the SAME address, and then tests
// the value it wrote instead. Reduced to three functions and read off the
// listing:
//
//     SD_CMD = 3; return SD_CMD & 2;              -> read elided
//     SD_CMD = 3; s = SD_CMD; return s & 2;       -> read elided
//     SD_CMD = 3; other_io = 0; return SD_CMD & 2;-> read emitted
//
// So every status check returned "error", because the command value 3 has
// bit 1 set. Splitting the addresses removes the hazard at the source: a read
// of STATUS is never a read of the address just written, so there is nothing
// for an optimiser to fold. It is also the more honest description of the
// hardware -- these were always two different registers wearing one address.
//
// $9F8B IS A DELIBERATE GAP AND MUST STAY ONE.
//
// DATA has a read SIDE EFFECT: it advances the buffer pointer. A 16-bit read
// is two bus cycles, so reading the register immediately BELOW DATA also
// reads DATA and consumes a byte. With DATA at $9F8A -- adjacent to STATUS --
// every status poll silently ate a byte of the sector, and the C compiler
// makes this routine rather than exotic: Calypsi's manual states it "may
// generate code that reads 8 and 24 bit objects using 16 bit access".
//
// Nothing readable may ever be placed at $9F8B. Registers ABOVE DATA are
// safe -- only the one below it is not.
//
// READ streams COUNT blocks straight into memory.  READBUF fetches ONE block
// into the buffer without touching memory -- which is what a FAT chain walk
// or a directory scan wants, since those inspect a few bytes of a sector and
// copying it into RAM first would be wasted work.  WRITE sends the buffer,
// which the CPU fills through $9F8C.
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

    wire   sub_sel = cs & (addr >= 4'h1) & (addr <= 4'hC) & (addr != 4'hB);
    assign rd_sel  = sub_sel;

    // done toggle coming back from the sdram domain
    logic done_tgl;                     // sdram domain
    logic [2:0] done_sync;              // cpu domain
    wire  done_pulse = done_sync[2] ^ done_sync[1];

    logic err_sd;                       // sdram domain
    logic [1:0] err_sync;

    logic [7:0] cpu_rd_s2;              // the CPU's view of the buffer window
    wire        buf_a_we = cs & we & (addr == 4'hC) & ~busy;

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
                    4'hC: bufptr <= bufptr + 9'd1;   // data written below
                    default: ;
                endcase
            end
            // A read of the data window advances the pointer too.
            if (cs & ~we & (addr == 4'hC) & ~busy)
                bufptr <= bufptr + 9'd1;
        end
    end

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
            4'hA:    rd_data = {card_present, 5'b0, err_cpu, busy};
            4'hC:    rd_data = cpu_rd_s2;
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
    // FSM state -- declared before the buffer, whose read mux looks at it
    // ------------------------------------------------------------------
    localparam CMD_READ    = 2'd1;
    localparam CMD_WRITE   = 2'd2;
    localparam CMD_READBUF = 2'd3;

    typedef enum logic [2:0] {
        S_IDLE, S_REQ, S_WAIT, S_DMA_ADDR, S_DMA_WR, S_NEXT, S_DONE
    } state_t;
    state_t st;

    logic [31:0] lba_r;
    logic [23:0] mem_r;
    logic  [7:0] blk_left;
    logic  [1:0] cmd_r;
    logic  [8:0] dma_i;
    logic        ack_q;

    // ------------------------------------------------------------------
    // 512-byte block buffer -- ONE clock, one write port, one read port.
    //
    // NOT true dual port, and not for want of trying.  Quartus will not infer
    // TDP across two clocks on this part:
    //
    //   Error (276001): Cannot synthesize dual-port RAM logic "...|blkbuf"
    //
    // and it refuses identically whether the ports read old data or forward
    // the written byte (Altera's own documented TDP template).  bank0_ram.sv
    // already says why in its header -- "M10K has two ports and the read port
    // owns one, so the loader cannot have a port of its own" -- and solves it
    // the way this now does: mux the writers onto one port, dedicate the other
    // to reads, one clock domain.
    //
    // So the buffer lives entirely on sdram_clk and the CPU's accesses cross
    // into it.  The timing is comfortable rather than tight: sdram_clk is
    // 100 MHz against an 8 MHz CPU, and two consecutive `lda SD_DATA` are at
    // least four CPU cycles apart -- around fifty sdram cycles.  The pointer is
    // stable for hundreds of nanoseconds before either side looks at it.
    // ------------------------------------------------------------------
    (* ramstyle = "M10K" *) logic [7:0] blkbuf [0:511];

    // ---- CPU write, carried across by a toggle ----
    // The address is captured AT the write.  bufptr increments on the same
    // edge, so sampling it afterwards would write to the next slot.
    logic [8:0] cpu_wr_addr;
    logic [7:0] cpu_wr_data;
    logic       cpu_wr_tgl;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cpu_wr_addr <= 9'd0; cpu_wr_data <= 8'd0; cpu_wr_tgl <= 1'b0;
        end else if (buf_a_we) begin
            cpu_wr_addr <= bufptr;
            cpu_wr_data <= wr_data;
            cpu_wr_tgl  <= ~cpu_wr_tgl;
        end
    end

    logic [2:0] cpu_wr_sync;
    wire        cpu_wr_pulse = cpu_wr_sync[2] ^ cpu_wr_sync[1];
    logic [8:0] bufptr_s1, bufptr_s2;
    always_ff @(posedge sdram_clk) begin
        cpu_wr_sync <= {cpu_wr_sync[1:0], cpu_wr_tgl};
        bufptr_s1   <= bufptr;
        bufptr_s2   <= bufptr_s1;
    end

    // ---- the one write port and the one read port ----
    logic [8:0] buf_wa, buf_ra;
    logic       buf_we;
    logic [7:0] buf_wd, buf_q;

    always_comb begin
        // Writers: the HPS while a block is arriving, the CPU while idle.
        // Never both -- the CPU is stalled for the whole transfer.
        buf_we = sd_buff_wr | cpu_wr_pulse;
        buf_wa = sd_buff_wr ? sd_buff_addr : cpu_wr_addr;
        buf_wd = sd_buff_wr ? sd_buff_dout : cpu_wr_data;

        // Readers: the DMA while streaming, the HPS while it takes a block for
        // a card write, the CPU's window otherwise.
        // buf_ra holds dma_i across BOTH DMA states, so the byte presented
        // in S_DMA_ADDR is still the one buf_q carries in S_DMA_WR -- and it
        // stays valid if dma_busy holds us there.
        if (st == S_DMA_ADDR || st == S_DMA_WR) buf_ra = dma_i;
        else if (st != S_IDLE)                  buf_ra = sd_buff_addr;
        else                                    buf_ra = bufptr_s2;
    end

    always_ff @(posedge sdram_clk) begin
        if (buf_we) blkbuf[buf_wa] <= buf_wd;
        buf_q <= blkbuf[buf_ra];
    end

    assign sd_buff_din = buf_q;

    // The CPU samples buf_q through two flops.  It is stable long before the
    // access -- see the timing note above -- so this is metastability
    // protection, not a handshake.
    logic [7:0] cpu_rd_s1;
    always_ff @(posedge clk) begin
        cpu_rd_s1 <= buf_q;
        cpu_rd_s2 <= cpu_rd_s1;
    end

    // ------------------------------------------------------------------
    // Transfer FSM (sdram_clk)
    // ------------------------------------------------------------------
    logic [2:0] start_sync;
    wire        start_pulse = start_sync[2] ^ start_sync[1];

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
            // request is dropped on ack and the transfer is complete when ack
            // falls again.
            S_WAIT: begin
                if (sd_ack) begin
                    sd_rd <= 1'b0;
                    sd_wr <= 1'b0;
                end
                if (ack_q & ~sd_ack) begin
                    if (cmd_r == CMD_READ) begin
                        dma_i <= 9'd0;
                        st    <= S_DMA_ADDR;
                    end else begin
                        st <= S_NEXT;
                    end
                end
            end

            // TWO STATES PER BYTE, AND THE SPLIT IS NOT OPTIONAL.
            //
            // buf_q is a REGISTERED read: the byte for address N appears the
            // cycle AFTER N is presented.  A single state cannot both present
            // dma_i and consume buf_q, because dma_i only increments at the
            // END of the cycle -- so buf_q lags by one and every byte after
            // the first repeats its predecessor.  That is exactly what
            // hardware did: sdtest went blue on test 3 while the emulator
            // stayed green, because the emulator models no read pipeline.
            //
            // Presenting the address one state early and consuming it in the
            // next is the boring, obviously-correct shape.  It costs 1024
            // sdram cycles per block, about 10 us at 100 MHz -- nothing
            // against the HPS round trip that fetched the block.
            S_DMA_ADDR: st <= S_DMA_WR;

            // dma_busy is the loader FIFO's backpressure.  Holding here is
            // safe: buf_ra is still dma_i, so buf_q keeps presenting the same
            // byte until the write is accepted.
            S_DMA_WR: begin
                if (!dma_busy) begin
                    dma_wr   <= 1'b1;
                    dma_addr <= mem_r + {15'd0, dma_i};
                    dma_data <= buf_q;
                    if (dma_i == 9'd511) begin
                        st <= S_NEXT;
                    end else begin
                        dma_i <= dma_i + 9'd1;
                        st    <= S_DMA_ADDR;
                    end
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

endmodule
