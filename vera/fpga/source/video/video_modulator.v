//`default_nettype none

module video_modulator(
    input  wire        clk,

    input  wire  [3:0] r,
    input  wire  [3:0] g,
    input  wire  [3:0] b,
    input  wire        color_burst,
    input  wire        active,
    input  wire        sync_n_in,

    output reg   [5:0] luma,
    output reg   [5:0] chroma);

    localparam signed [7:0] Y_R = 8'sd27; // 38; //  0.299
    localparam signed [7:0] Y_G = 8'sd53; // 75; //  0.587
    localparam signed [7:0] Y_B = 8'sd10; // 14; //  0.114

    localparam signed [7:0] I_R = 8'sd76;  //  0.5959
    localparam signed [7:0] I_G = -8'sd35; // -0.2746
    localparam signed [7:0] I_B = -8'sd41; // -0.3213

    localparam signed [7:0] Q_R = 8'sd27;  //  0.2115
    localparam signed [7:0] Q_G = -8'sd66; // -0.5227
    localparam signed [7:0] Q_B = 8'sd40;  //  0.3112

    wire signed [4:0] r_s = color_burst ? 5'd9 : {1'b0, r};
    wire signed [4:0] g_s = color_burst ? 5'd9 : {1'b0, g};
    wire signed [4:0] b_s = color_burst ? 5'd0 : {1'b0, b};

    reg signed [11:0] y_s;
    reg signed [11:0] i_s;
    reg signed [11:0] q_s;

    localparam signed [11:0] Y_SYNC_LEVEL = 12'sd0;
    localparam signed [11:0] Y_BLANK_LEVEL = 12'sd544;
    localparam signed [11:0] Y_ACTIVE_OFFSET = 12'sd640;

    always @(posedge clk) begin
        y_s <= (sync_n_in == 0) ? Y_SYNC_LEVEL : Y_BLANK_LEVEL;
        i_s <= 12'sd0;
        q_s <= 12'sd0;

        if (active) begin
            y_s <= (Y_R * r_s) + (Y_G * g_s) + (Y_B * b_s) + Y_ACTIVE_OFFSET;
        end

        if (active || color_burst) begin
            i_s <= (I_R * r_s) + (I_G * g_s) + (I_B * b_s);
            q_s <= (Q_R * r_s) + (Q_G * g_s) + (Q_B * b_s);
        end
    end

    // Color burst frequency: 315/88 MHz = 3579545 Hz
    reg  [23:0] phase_accum_r = 0;
    always @(posedge clk) phase_accum_r <= phase_accum_r + 24'd2402192;

    wire [7:0] sinval;
    video_modulator_sinlut sinlut(
        .clk(clk),
        .phase(phase_accum_r[23:15]),
        .value(sinval));

    wire [7:0] cosval;
    video_modulator_coslut coslut(
        .clk(clk),
        .phase(phase_accum_r[23:15]),
        .value(cosval));

    wire signed [7:0] sinval_s = sinval;
    wire signed [7:0] cosval_s = cosval;

    wire signed [7:0] i8_s = i_s[11:4];
    wire signed [7:0] q8_s = q_s[11:4];

    reg         [7:0] lum;
    reg signed [13:0] chroma_s;

    always @(posedge clk) begin
        if (y_s < 0)
            lum <= 0;
        else if (y_s >= 2047)
            lum <= 255;
        else
            lum <= y_s[10:3];

        chroma_s <= (cosval_s * i8_s) + (sinval_s * q8_s);
    end

    always @(posedge clk) begin
        luma   <= lum[7:2];
        chroma <= chroma_s[13:8] + 6'd32;
    end

endmodule
