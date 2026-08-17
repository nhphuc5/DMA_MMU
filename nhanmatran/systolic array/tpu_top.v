// Module: tpu_top (4x4)
// Top-level integration of 4x4 TPU systolic array.
//
// BUG FIXES vs original 32x32 tpu_top.v:
//  1. ARRAY_SIZE default changed to 4.
//  2. Reset signal: original used `srstn` at top level but passed it as `rst_n`
//     to sub-modules inconsistently. Unified: top port is `rst_n`, all sub-modules
//     receive rst_n.
//  3. systolic_inst: original passed .srstn() which doesn't exist in systolic module
//     (that module uses .rst_n). Fixed.
//  4. systolic_controll_inst: original called module `systolic_controll` (typo).
//     Fixed to `systolic_controller`.
//  5. write_out module was missing entirely - now included (write_out.v created).
//  6. SRAM input/output ports reduced from 8 banks to 1 bank per axis.
//  7. sram_raddr width reduced from 10-bit to 4-bit (max addr = 6 for 4x4).
//  8. matrix_index and sram_waddr widths corrected to 3-bit.
//  9. ORI_WIDTH localparam kept; wire widths adjusted throughout.

module tpu_top #(
    parameter ARRAY_SIZE        = 4,
    parameter SRAM_DATA_WIDTH   = 32,
    parameter DATA_WIDTH        = 8,
    parameter OUTPUT_DATA_WIDTH = 16
)(
    input  wire        clk,
    input  wire        rst_n,       // Active-low synchronous reset (unified name)
    input  wire        tpu_start,

    // Weight SRAM - single 32-bit port (holds 4 x 8-bit elements)
    input  wire [SRAM_DATA_WIDTH-1:0] sram_rdata_w,
    // Data SRAM - single 32-bit port
    input  wire [SRAM_DATA_WIDTH-1:0] sram_rdata_d,

    // Read addresses to SRAMs
    output wire [3:0] sram_raddr_w,
    output wire [3:0] sram_raddr_d,

    // Output write ports (3 result banks)
    output wire        sram_write_enable_a0,
    output wire [ARRAY_SIZE*OUTPUT_DATA_WIDTH-1:0] sram_wdata_a,
    output wire [2:0]  sram_waddr_a,

    output wire        sram_write_enable_b0,
    output wire [ARRAY_SIZE*OUTPUT_DATA_WIDTH-1:0] sram_wdata_b,
    output wire [2:0]  sram_waddr_b,

    output wire        sram_write_enable_c0,
    output wire [ARRAY_SIZE*OUTPUT_DATA_WIDTH-1:0] sram_wdata_c,
    output wire [2:0]  sram_waddr_c,

    output wire        tpu_done
);

localparam ORI_WIDTH = DATA_WIDTH*2 + 5;  // 21 bits

// ---- Internal wires ----
wire [3:0]   addr_serial_num;
wire signed  [ARRAY_SIZE*ORI_WIDTH-1:0]        ori_data;
wire signed  [ARRAY_SIZE*OUTPUT_DATA_WIDTH-1:0] quantized_data;

wire         alu_start;
wire [8:0]   cycle_num;
wire [2:0]   matrix_index;
wire         sram_write_enable;
wire [1:0]   data_set;

// ---- Address selector ----
addr_sel addr_sel_inst (
    .clk            (clk),
    .addr_serial_num(addr_serial_num),
    .sram_raddr_w   (sram_raddr_w),
    .sram_raddr_d   (sram_raddr_d)
);

// ---- Systolic array ----
// FIX: port name was .srstn() in original - corrected to .rst_n()
systolic #(
    .ARRAY_SIZE     (ARRAY_SIZE),
    .SRAM_DATA_WIDTH(SRAM_DATA_WIDTH),
    .DATA_WIDTH     (DATA_WIDTH)
) systolic_inst (
    .clk            (clk),
    .rst_n          (rst_n),        // FIX: was .srstn() - no such port in systolic.v
    .alu_start      (alu_start),
    .cycle_num      (cycle_num),
    .sram_rdata_w   (sram_rdata_w),
    .sram_rdata_d   (sram_rdata_d),
    .matrix_index   (matrix_index),
    .mul_outcome    (ori_data)
);

// ---- Quantization ----
quantize #(
    .ARRAY_SIZE        (ARRAY_SIZE),
    .SRAM_DATA_WIDTH   (SRAM_DATA_WIDTH),
    .DATA_WIDTH        (DATA_WIDTH),
    .OUTPUT_DATA_WIDTH (OUTPUT_DATA_WIDTH)
) quantize_inst (
    .ori_data       (ori_data),
    .quantized_data (quantized_data)
);

// ---- Controller ----
// FIX: original called module `systolic_controll` (typo) - corrected to systolic_controller
// FIX: port was .srstn() - corrected to .rst_n()
systolic_controller #(
    .ARRAY_SIZE(ARRAY_SIZE)
) systolic_controller_inst (
    .clk              (clk),
    .rst_n            (rst_n),       // FIX: was .srstn()
    .tpu_start        (tpu_start),
    .sram_write_enable(sram_write_enable),
    .addr_serial_num  (addr_serial_num),
    .alu_start        (alu_start),
    .cycle_num        (cycle_num),
    .matrix_index     (matrix_index),
    .data_set         (data_set),
    .tpu_done         (tpu_done)
);

// ---- Write-out ----
// FIX: this module was missing from the original project entirely
write_out #(
    .ARRAY_SIZE        (ARRAY_SIZE),
    .OUTPUT_DATA_WIDTH (OUTPUT_DATA_WIDTH)
) write_out_inst (
    .clk                  (clk),
    .rst_n                (rst_n),
    .sram_write_enable    (sram_write_enable),
    .data_set             (data_set),
    .matrix_index         (matrix_index),
    .quantized_data       (quantized_data),
    .sram_write_enable_a0 (sram_write_enable_a0),
    .sram_wdata_a         (sram_wdata_a),
    .sram_waddr_a         (sram_waddr_a),
    .sram_write_enable_b0 (sram_write_enable_b0),
    .sram_wdata_b         (sram_wdata_b),
    .sram_waddr_b         (sram_waddr_b),
    .sram_write_enable_c0 (sram_write_enable_c0),
    .sram_wdata_c         (sram_wdata_c),
    .sram_waddr_c         (sram_waddr_c)
);

endmodule