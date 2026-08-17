// Module: write_out (4x4)
// FIX: Reverted to standard synchronous pipelining. Combinational data
// is perfectly fine to latch at the clock edge alongside its control signals.

module write_out #(
    parameter ARRAY_SIZE        = 4,
    parameter OUTPUT_DATA_WIDTH = 16
)(
    input  wire                                            clk,
    input  wire                                            rst_n,
    input  wire                                            sram_write_enable,
    input  wire [1:0]                                      data_set,
    input  wire [2:0]                                      matrix_index,
    input  wire signed [ARRAY_SIZE*OUTPUT_DATA_WIDTH-1:0]  quantized_data,

    output reg                                             sram_write_enable_a0,
    output reg  [ARRAY_SIZE*OUTPUT_DATA_WIDTH-1:0]         sram_wdata_a,
    output reg  [2:0]                                      sram_waddr_a,

    output reg                                             sram_write_enable_b0,
    output reg  [ARRAY_SIZE*OUTPUT_DATA_WIDTH-1:0]         sram_wdata_b,
    output reg  [2:0]                                      sram_waddr_b,

    output reg                                             sram_write_enable_c0,
    output reg  [ARRAY_SIZE*OUTPUT_DATA_WIDTH-1:0]         sram_wdata_c,
    output reg  [2:0]                                      sram_waddr_c
);

always @(posedge clk) begin
    if (~rst_n) begin
        sram_write_enable_a0 <= 1'b0;
        sram_write_enable_b0 <= 1'b0;
        sram_write_enable_c0 <= 1'b0;
        sram_wdata_a <= 0;
        sram_wdata_b <= 0;
        sram_wdata_c <= 0;
        sram_waddr_a <= 3'b0;
        sram_waddr_b <= 3'b0;
        sram_waddr_c <= 3'b0;
    end
    else begin
        // Reset tín hiệu write_enable mỗi chu kỳ để tránh tạo Latch
        sram_write_enable_a0 <= 1'b0;
        sram_write_enable_b0 <= 1'b0;
        sram_write_enable_c0 <= 1'b0;

        if (sram_write_enable) begin
            case (data_set)
                2'd0: begin
                    sram_write_enable_a0 <= 1'b1;
                    sram_wdata_a         <= quantized_data;
                    sram_waddr_a         <= matrix_index;
                end
                2'd1: begin
                    sram_write_enable_b0 <= 1'b1;
                    sram_wdata_b         <= quantized_data;
                    sram_waddr_b         <= matrix_index;
                end
                2'd2: begin
                    sram_write_enable_c0 <= 1'b1;
                    sram_wdata_c         <= quantized_data;
                    sram_waddr_c         <= matrix_index;
                end
                default: ;
            endcase
        end
    end
end

endmodule