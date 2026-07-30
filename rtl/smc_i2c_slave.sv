//============================================================================
// smc_i2c_slave.sv  -  Minimal SMC (System Management Controller) I2C slave.
//
// The X16 KERNAL talks to an external microcontroller at I2C address $42
// for keyboard, mouse, power button, and several housekeeping registers.
// Without a slave ACKing, every i2c_read_byte / i2c_write_byte in KERNAL
// NACKs and the boot stalls (PS/2 init, DIAG POST, audio init, etc.).
//
// This module snoops the bit-banged I2C bus on VIA1 PA[0]=SDA, PA[1]=SCL
// and:
//   - ACKs writes to address $42, captures the register pointer byte,
//     then ACKs and discards any further data bytes
//   - ACKs reads from address $42, sends $00 for every byte requested
//     (regardless of register pointer)
//   - Returns to idle on STOP or on an unrecognized address
//
// Returning $00 for everything is enough for boot:
//   reg $09 (power-on type)  -> 0 = normal power-on
//   keyboard / mouse buffers -> empty
//   power button / pending events -> none
//
// The slave only drives SDA low (open-drain).  SCL is driven by the
// master alone.  Inputs sda_bus / scl_bus are the actual bus state
// (combination of all open-drain drivers + pull-up).
//============================================================================
module smc_i2c_slave #(
    parameter logic [6:0] SLAVE_ADDR = 7'h42
) (
    input  logic clk,            // pix_clk (25.175 MHz)
    input  logic reset_n,
    input  logic sda_bus,        // SDA bus state (post-OR of all drivers)
    input  logic scl_bus,        // SCL bus state
    output logic sda_drive_low   // 1 = slave pulls SDA low
);

    // ---- Synchronize SDA/SCL into our clock domain ----
    logic sda_s1, sda_s2, sda_s3;
    logic scl_s1, scl_s2, scl_s3;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sda_s1 <= 1'b1; sda_s2 <= 1'b1; sda_s3 <= 1'b1;
            scl_s1 <= 1'b1; scl_s2 <= 1'b1; scl_s3 <= 1'b1;
        end else begin
            sda_s1 <= sda_bus; sda_s2 <= sda_s1; sda_s3 <= sda_s2;
            scl_s1 <= scl_bus; scl_s2 <= scl_s1; scl_s3 <= scl_s2;
        end
    end

    wire sda      = sda_s2;
    wire scl      = scl_s2;
    wire scl_rise = scl_s2 & ~scl_s3;
    wire scl_fall = ~scl_s2 & scl_s3;
    wire sda_rise = sda_s2 & ~sda_s3;
    wire sda_fall = ~sda_s2 & sda_s3;

    // START: SDA falls while SCL is high.  STOP: SDA rises while SCL is high.
    wire start_cond = sda_fall & scl;
    wire stop_cond  = sda_rise & scl;

    // ---- Slave state machine ----
    typedef enum logic [3:0] {
        S_IDLE,
        S_ADDR,         // shifting in 7 addr + 1 R/W bit
        S_ADDR_ACK,     // pull SDA low while SCL low, hold through high
        S_REG_RX,       // shifting in 8-bit register pointer (write phase)
        S_REG_ACK,
        S_WRDATA,       // shifting in 8-bit write data
        S_WRDATA_ACK,
        S_RDDATA,       // shifting out 8-bit read data
        S_RDDATA_ACK    // waiting for master's ACK/NACK on read
    } state_t;

    state_t       state;
    logic [7:0]   shift;
    logic [3:0]   bitcnt;
    logic         rw_bit;        // 0 = write, 1 = read
    logic [7:0]   reg_ptr;

    // For now, all reads return $00. Keep reg_ptr in the expression so
    // the captured register pointer remains referenced.
    wire [7:0] smc_rd_data = reg_ptr & 8'h00;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state         <= S_IDLE;
            shift         <= 8'h00;
            bitcnt        <= 4'h0;
            rw_bit        <= 1'b0;
            reg_ptr       <= 8'h00;
            sda_drive_low <= 1'b0;
        end else begin
            // STOP -> reset to IDLE, release SDA.
            if (stop_cond) begin
                state         <= S_IDLE;
                sda_drive_low <= 1'b0;
            end
            // START / repeated START -> begin address phase.
            else if (start_cond) begin
                state         <= S_ADDR;
                bitcnt        <= 4'h0;
                shift         <= 8'h00;
                sda_drive_low <= 1'b0;
            end
            else case (state)
                S_IDLE: ; // wait

                // 8 bits: 7 address + 1 R/W, sampled on SCL rising.
                S_ADDR: begin
                    if (scl_rise) begin
                        shift  <= {shift[6:0], sda};
                        bitcnt <= bitcnt + 4'h1;
                        if (bitcnt == 4'h7) begin
                            // 8th bit: full byte is {shift[6:0], sda}.
                            // High 7 bits are address; low bit is R/W.
                            if (shift[6:0] == SLAVE_ADDR) begin
                                rw_bit <= sda;          // last bit = R/W
                                state  <= S_ADDR_ACK;
                            end else begin
                                state  <= S_IDLE;       // not us, ignore
                            end
                        end
                    end
                end

                // ACK: pull SDA low while SCL is low, keep through SCL high,
                // release on next SCL falling.
                S_ADDR_ACK: begin
                    if (scl_fall && !sda_drive_low) begin
                        // SCL just went low for the first time after the
                        // 8th data bit; assert ACK now.
                        sda_drive_low <= 1'b1;
                    end else if (scl_fall && sda_drive_low) begin
                        // SCL going low after our ACK -- release.
                        sda_drive_low <= 1'b0;
                        bitcnt        <= 4'h0;
                        shift         <= 8'h00;
                        if (rw_bit) begin
                            state <= S_RDDATA;
                        end else begin
                            state <= S_REG_RX;
                        end
                    end
                end

                S_REG_RX: begin
                    if (scl_rise) begin
                        shift  <= {shift[6:0], sda};
                        bitcnt <= bitcnt + 4'h1;
                        if (bitcnt == 4'h7) begin
                            reg_ptr <= {shift[6:0], sda};
                            state   <= S_REG_ACK;
                        end
                    end
                end

                S_REG_ACK: begin
                    if (scl_fall && !sda_drive_low) begin
                        sda_drive_low <= 1'b1;
                    end else if (scl_fall && sda_drive_low) begin
                        sda_drive_low <= 1'b0;
                        bitcnt        <= 4'h0;
                        shift         <= 8'h00;
                        state         <= S_WRDATA;
                    end
                end

                // Write data: just shift in 8 bits and ACK; we don't
                // store anything for now.
                S_WRDATA: begin
                    if (scl_rise) begin
                        bitcnt <= bitcnt + 4'h1;
                        if (bitcnt == 4'h7) state <= S_WRDATA_ACK;
                    end
                end

                S_WRDATA_ACK: begin
                    if (scl_fall && !sda_drive_low) begin
                        sda_drive_low <= 1'b1;
                    end else if (scl_fall && sda_drive_low) begin
                        sda_drive_low <= 1'b0;
                        bitcnt        <= 4'h0;
                        state         <= S_WRDATA;
                    end
                end

                // Read data: drive each bit on SCL falling so it is
                // stable when master clocks SCL high.
                S_RDDATA: begin
                    if (scl_fall) begin
                        sda_drive_low <= ~smc_rd_data[7 - bitcnt[2:0]];
                        bitcnt        <= bitcnt + 4'h1;
                        if (bitcnt == 4'h7) state <= S_RDDATA_ACK;
                    end
                end

                S_RDDATA_ACK: begin
                    if (scl_fall) begin
                        sda_drive_low <= 1'b0;          // release for master
                    end
                    if (scl_rise) begin
                        // Master's ACK (low) -> more bytes; NACK (high) -> stop.
                        // Simplest: always return to receive another byte.
                        // Real STOP will hit the top-level stop_cond.
                        bitcnt <= 4'h0;
                        state  <= S_RDDATA;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
