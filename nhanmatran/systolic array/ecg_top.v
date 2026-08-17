// ecg_top — Vivado version
// Top module: ecg_ctrl_vivado + tpu_top
// Không thêm IP block nào thêm — tpu_top và ecg_ctrl dùng behavioral BRAM
// (Vivado tự infer Block RAM từ reg[31:0] mem[0:N])

module ecg_top #(
    parameter DATA_WIDTH        = 8,
    parameter OUTPUT_DATA_WIDTH = 16,
    parameter ARRAY_SIZE        = 4,
    parameter INPUT_LEN         = 128,
    parameter NUM_CLASSES       = 4
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    // Load ECG signal trước khi start
    input  wire [7:0]  ecg_wdata,
    input  wire [6:0]  ecg_waddr,
    input  wire        ecg_we,
    // Output
    output wire [1:0]  pred_class,
    output wire        done
);

// Internal wires between ecg_ctrl and tpu_top
wire        tpu_start, tpu_done;
wire [31:0] sram_rdata_w, sram_rdata_d;
wire [3:0]  sram_raddr_w, sram_raddr_d;
wire        sram_we_a;
wire [63:0] sram_wdata_a;
wire [2:0]  sram_waddr_a;
// Banks b/c unused but must be connected
wire        sram_we_b,  sram_we_c;
wire [63:0] sram_wdata_b, sram_wdata_c;
wire [2:0]  sram_waddr_b, sram_waddr_c;

// ---- TPU core (không đổi) ----
tpu_top #(
    .ARRAY_SIZE(ARRAY_SIZE),
    .SRAM_DATA_WIDTH(32),
    .DATA_WIDTH(DATA_WIDTH),
    .OUTPUT_DATA_WIDTH(OUTPUT_DATA_WIDTH)
) tpu_inst (
    .clk                 (clk),
    .rst_n               (rst_n),
    .tpu_start           (tpu_start),
    .sram_rdata_w        (sram_rdata_w),
    .sram_rdata_d        (sram_rdata_d),
    .sram_raddr_w        (sram_raddr_w),
    .sram_raddr_d        (sram_raddr_d),
    .sram_write_enable_a0(sram_we_a),
    .sram_wdata_a        (sram_wdata_a),
    .sram_waddr_a        (sram_waddr_a),
    .sram_write_enable_b0(sram_we_b),
    .sram_wdata_b        (sram_wdata_b),
    .sram_waddr_b        (sram_waddr_b),
    .sram_write_enable_c0(sram_we_c),
    .sram_wdata_c        (sram_wdata_c),
    .sram_waddr_c        (sram_waddr_c),
    .tpu_done            (tpu_done)
);

// ---- CNN controller (Vivado-compatible) ----
ecg_ctrl #(
    .DATA_WIDTH(DATA_WIDTH),
    .OUTPUT_DATA_WIDTH(OUTPUT_DATA_WIDTH),
    .ARRAY_SIZE(ARRAY_SIZE),
    .INPUT_LEN(INPUT_LEN),
    .NUM_CLASSES(NUM_CLASSES)
) ctrl_inst (
    .clk        (clk),
    .rst_n      (rst_n),
    .start      (start),
    .ecg_wdata  (ecg_wdata),
    .ecg_waddr  (ecg_waddr),
    .ecg_we     (ecg_we),
    .tpu_start  (tpu_start),
    .tpu_done   (tpu_done),
    .sram_rdata_w(sram_rdata_w),
    .sram_rdata_d(sram_rdata_d),
    .sram_raddr_w(sram_raddr_w),
    .sram_raddr_d(sram_raddr_d),
    .sram_we_a  (sram_we_a),
    .sram_wdata_a(sram_wdata_a),
    .sram_waddr_a(sram_waddr_a),
    .pred_class (pred_class),
    .done       (done)
);

endmodule