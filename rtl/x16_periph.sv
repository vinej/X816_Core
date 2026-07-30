//============================================================================
// x16_periph.sv -- small X16 peripherals for the MiSTer top level:
//   * snes_pad : SNES controller shift register on the VIA1 pins
//   * i2s_rx   : deserializer for VERA's I2S audio output
// Kept in their own file so the ModelSim testbenches (sim/tb_periph.v) can
// compile the exact shipped modules (x16.sv needs the framework include).
//============================================================================

//============================================================================
// snes_pad -- SNES controller shift register on the VIA1 pins, fed from a
// MiSTer joystick vector (CONF_STR "J1,A,B,X,Y,L,R,Select,Start" order:
// joy[0..3] = R,L,D,U directions, joy[4..11] = A,B,X,Y,L,R,Select,Start).
//
// Protocol (KERNAL r49 joystick.s): LATCH pulse loads the register; DATA
// then presents bit 0 (B); each CLK rising edge advances to the next bit.
// Wire order, ACTIVE LOW: B,Y,Select,Start,Up,Down,Left,Right,A,X,L,R,
// then ID = 1111 (standard pad) and eight 0 bits (byte 2 = $00 = present;
// an absent pad would read all 1s, which is what the undriven PA4/PA5
// lines return for pads 3/4).
//============================================================================
module snes_pad (
    input  logic        clk,          // cpu_clk
    input  logic        reset_n,
    input  logic [11:0] joy,          // MiSTer joystick (active high)
    input  logic        latch,        // VIA1 PA2
    input  logic        jclk,         // VIA1 PA3
    output logic        data
);
    // 24-bit report, shifted out MSB first
    wire [23:0] report = {
        ~joy[5],  ~joy[7],  ~joy[10], ~joy[11],   // B  Y  Select Start
        ~joy[3],  ~joy[2],  ~joy[1],  ~joy[0],    // Up Down Left Right
        ~joy[4],  ~joy[6],  ~joy[8],  ~joy[9],    // A  X  L  R
        4'b1111,                                  // ID: standard SNES pad
        8'b0000_0000                              // byte 2: $00 = present
    };

    logic [23:0] sr;
    logic        jclk_d;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sr     <= 24'hFFFFFF;
            jclk_d <= 1'b1;
        end else begin
            jclk_d <= jclk;
            if (latch)                  sr <= report;           // load while latch high
            else if (jclk & ~jclk_d)    sr <= {sr[22:0], 1'b0}; // shift on CLK rising
        end
    end

    assign data = sr[23];

endmodule

//============================================================================
// i2s_rx -- deserializer for VERA's I2S audio output (vera dacif.v format).
//
// All three inputs are generated REGISTERED on `clk` (same clock domain):
// bck = clk/2; lrck toggles every 256 clk (fs = clk/512); each half-frame
// carries one pad bit then a 24-bit two's-complement sample MSB-first (LEFT
// while lrck = 0, loaded at the lrck falling edge); data changes on bck
// falling edges, so it is stable across every bck rising edge.  Shift on
// bck RISING edges, restart the bit counter at each lrck edge, and after
// 25 bits (pad + 24) keep the top 16 bits of the sample.
//============================================================================
module i2s_rx (
    input  logic               clk,      // = the transmitter's clock (pix_clk)
    input  logic               lrck,
    input  logic               bck,
    input  logic               data,
    output logic signed [15:0] left  = '0,
    output logic signed [15:0] right = '0
);
    // power-up init (FPGA config default; also keeps RTL sim out of X-land)
    logic [24:0] sr     = '0;
    logic [4:0]  cnt    = '0;
    logic        bck_d  = 1'b0;
    logic        lrck_d = 1'b0;

    always_ff @(posedge clk) begin
        bck_d <= bck;
        if (~bck_d & bck) begin                  // bck rising: data valid
            if (lrck != lrck_d) begin            // new half-frame
                // this detection lands exactly on the PAD bit (the frame is
                // loaded one clk after the lrck toggle, and the first shift
                // comes one bck later), so consuming it here leaves cnt=0
                // aligned with the sample's MSB.
                lrck_d <= lrck;
                cnt    <= 5'd0;
            end else if (cnt < 5'd24) begin
                sr  <= {sr[23:0], data};
                cnt <= cnt + 5'd1;
                if (cnt == 5'd23) begin
                    // the bit shifting in now is the LSB; the sample's top
                    // 16 bits are sr[22:7] at this instant.
                    // lrck=0 half carries LEFT (loaded at the falling edge).
                    if (~lrck_d) left  <= sr[22:7];
                    else         right <= sr[22:7];
                end
            end
        end
    end

endmodule
