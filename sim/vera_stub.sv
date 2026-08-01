//============================================================================
// vera_stub.sv -- behavioral VERA register stub for the full-ROM boot sim.
//
// Enough for the R49 KERNAL to boot: readable/writable register file at
// $9F20-$9F3F, VSYNC ISR bit at ~60 Hz with IEN gating and write-1-to-clear,
// version registers ('V',0,3,7 when DCSEL=63) for the splash check, DATA
// ports swallow writes / read 0 (no VRAM model), and the SD SPI regs
// ($9F3E data / $9F3F ctrl) read $FF / $00 = "no card", so the boot probe
// times out exactly like the unmounted-image case on HW.
//============================================================================
module vera_stub #(
    parameter integer VSYNC_PERIOD = 133333   // cpu_clk cycles per frame
) (
    input  logic       clk,        // cpu_clk
    input  logic       reset_n,
    input  logic       cs,         // $9F20-$9F3F
    input  logic       we,         // write strobe (cs & ~rwn & enable)
    input  logic [4:0] addr,       // cpu_a[4:0]
    input  logic [7:0] wr_data,
    output logic [7:0] rd_data,
    output logic       irq_n
);
    logic [7:0] regs [0:31];
    integer     vcnt;

    wire [7:0] ctrl = regs[5];
    wire [7:0] ien  = regs[6];
    logic [7:0] isr;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            integer i;
            for (i = 0; i < 32; i = i + 1) regs[i] <= 8'h00;
            isr  <= 8'h00;
            vcnt <= 0;
        end else begin
            vcnt <= vcnt + 1;
            if (vcnt >= VSYNC_PERIOD) begin
                vcnt   <= 0;
                isr[0] <= 1'b1;                    // VSYNC
            end
            if (we) begin
                if (addr == 5'h07) isr <= isr & ~wr_data;   // W1C
                else               regs[addr] <= wr_data;
            end
        end
    end

    assign irq_n = ~|(isr & ien & 8'h0F);

    always_comb begin
        case (addr)
            5'h03, 5'h04: rd_data = 8'h00;          // DATA0/1: no VRAM model
            5'h07:        rd_data = isr;
            5'h09: rd_data = (ctrl == 8'h7E) ? "V"   : regs[9];
            5'h0A: rd_data = (ctrl == 8'h7E) ? 8'h00 : regs[10];
            5'h0B: rd_data = (ctrl == 8'h7E) ? 8'h03 : regs[11];
            5'h0C: rd_data = (ctrl == 8'h7E) ? 8'h07 : regs[12];
            5'h1E: rd_data = 8'hFF;                 // SPI data: no card
            5'h1F: rd_data = 8'h00;                 // SPI ctrl: not busy
            default: rd_data = regs[addr];
        endcase
    end
endmodule
