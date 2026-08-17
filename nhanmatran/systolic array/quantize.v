// Module: quantize (4x4)
// Converts 21-bit signed accumulator output to 16-bit saturated output.
//
// BUG FIXES vs original:
//  - ARRAY_SIZE parameter updated default to 4.
//  - FIX: original compared ori_shifted_data (signed) against integer literals
//    max_val/min_val without explicit signed casting - in some tools this
//    causes unsigned comparison. Fixed by declaring max_val/min_val as
//    signed localparams and using $signed() explicitly.
//  - ORI_WIDTH correctly derived from DATA_WIDTH (21 bits for 8-bit data): unchanged.
//  - Output quantization truncates to lower OUTPUT_DATA_WIDTH bits after
//    saturation check - correct, unchanged.

module quantize #(
    parameter ARRAY_SIZE        = 4,
    parameter SRAM_DATA_WIDTH   = 32,
    parameter DATA_WIDTH        = 8,
    parameter OUTPUT_DATA_WIDTH = 16
)(
    input  signed [ARRAY_SIZE*(DATA_WIDTH*2+5)-1:0]        ori_data,
    output reg signed [ARRAY_SIZE*OUTPUT_DATA_WIDTH-1:0]   quantized_data
);

// FIX: declare as signed so comparisons are unambiguous
localparam signed [OUTPUT_DATA_WIDTH-1:0] MAX_VAL =  32767;
localparam signed [OUTPUT_DATA_WIDTH-1:0] MIN_VAL = -32768;

localparam ORI_WIDTH = DATA_WIDTH*2 + 5;  // 21 bits

reg signed [ORI_WIDTH-1:0] ori_shifted_data;
integer i;

always @(*) begin
    for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
        ori_shifted_data = ori_data[i*ORI_WIDTH +: ORI_WIDTH];

        // FIX: use $signed() to guarantee signed comparison
        if ($signed(ori_shifted_data) >= $signed({{(ORI_WIDTH-OUTPUT_DATA_WIDTH){1'b0}}, MAX_VAL}))
            quantized_data[i*OUTPUT_DATA_WIDTH +: OUTPUT_DATA_WIDTH] = MAX_VAL;
        else if ($signed(ori_shifted_data) <= $signed({{(ORI_WIDTH-OUTPUT_DATA_WIDTH){1'b1}}, MIN_VAL}))
            quantized_data[i*OUTPUT_DATA_WIDTH +: OUTPUT_DATA_WIDTH] = MIN_VAL;
        else
            quantized_data[i*OUTPUT_DATA_WIDTH +: OUTPUT_DATA_WIDTH] =
                ori_shifted_data[OUTPUT_DATA_WIDTH-1:0];
    end
end

endmodule