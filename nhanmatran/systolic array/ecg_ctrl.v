// =============================================================================
// Module: ecg_ctrl (Vivado-compatible version)
//
// Thay đổi so với ecg_ctrl_v2.v cho Vivado synthesis:
//
//  1. Pool loops -> counter FSM (S_POOL1_RD/WR, S_POOL2_RD/WR states)
//     BRAM không đọc combinational được -> cần 1 cycle read latency
//
//  2. weight_rom dùng $readmemh("ecg_weights.hex", ...) thay vì initial=0
//     Vivado tự synthesize thành Block RAM từ .coe file hoặc $readmemh
//
//  3. fmap_mem + weight_rom đọc qua registered output (1-cycle latency)
//     Tất cả read path đều có pipeline register
//
//  4. acc[] reset unrolled thủ công (không dùng for-loop trong sequential)
//
//  5. Không có initial block (ngoại trừ $readmemh cho ROM)
// =============================================================================

module ecg_ctrl #(
    parameter DATA_WIDTH        = 8,
    parameter OUTPUT_DATA_WIDTH = 16,
    parameter ARRAY_SIZE        = 4,
    parameter INPUT_LEN         = 128,
    parameter NUM_CLASSES       = 4
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,

    input  wire [7:0]  ecg_wdata,
    input  wire [6:0]  ecg_waddr,
    input  wire        ecg_we,

    output reg         tpu_start,
    input  wire        tpu_done,

    output reg  [31:0] sram_rdata_w,
    output reg  [31:0] sram_rdata_d,
    input  wire [3:0]  sram_raddr_w,
    input  wire [3:0]  sram_raddr_d,

    input  wire        sram_we_a,
    input  wire [63:0] sram_wdata_a,
    input  wire [2:0]  sram_waddr_a,

    output reg  [1:0]  pred_class,
    output reg         done
);

// =========================================================================
// BRAMs — Vivado synthesizes reg [N:0] mem [0:M] as Block RAM
// khi có registered read (output registered 1 cycle sau address)
// =========================================================================
reg [31:0] fmap_mem   [0:2047];  // feature map + ECG raw
(* rom_style = "block" *)
reg [31:0] weight_rom [0:127];   // weight ROM

// Weight ROM init từ hex file (Vivado hỗ trợ $readmemh trong synthesis)
initial $readmemh("ecg_weights.hex", weight_rom);

// =========================================================================
// FSM states — thêm POOL states với counter
// =========================================================================
localparam S_IDLE       = 5'd0;
localparam S_CONV1_FIRE = 5'd1;
localparam S_CONV1_WAIT = 5'd2;
localparam S_CONV1_WR   = 5'd3;  // write result to fmap_mem
localparam S_POOL1_RD   = 5'd4;  // read even/odd pair (2 cycles: addr then data)
localparam S_POOL1_RD2  = 5'd5;  // wait for BRAM read latency
localparam S_POOL1_WR   = 5'd6;  // write max to pool output
localparam S_CONV2_FIRE = 5'd7;
localparam S_CONV2_WAIT = 5'd8;
localparam S_CONV2_WR   = 5'd9;
localparam S_POOL2_RD   = 5'd10;
localparam S_POOL2_RD2  = 5'd11;
localparam S_POOL2_WR   = 5'd12;
localparam S_FC1_FIRE   = 5'd13;
localparam S_FC1_WAIT   = 5'd14;
localparam S_FC1_ACC    = 5'd15;
localparam S_FC2_FIRE   = 5'd16;
localparam S_FC2_WAIT   = 5'd17;
localparam S_FC2_ACC    = 5'd18;
localparam S_ARGMAX     = 5'd19;
localparam S_DONE       = 5'd20;

reg [4:0] state;

// Counters
reg [7:0]  win_idx;
reg [7:0]  tile_idx;
reg [3:0]  grp_idx;
reg [6:0]  pool_cnt;    // 0..61 for pool1, 0..28 for pool2

// Feature map SRAM address bases (word addresses)
localparam [10:0] CONV1_BASE = 11'd128;   // 125 words
localparam [10:0] POOL1_BASE = 11'd253;   // 62 words
localparam [10:0] CONV2_BASE = 11'd315;   // 59 words
localparam [10:0] POOL2_BASE = 11'd374;   // 29 words
localparam [10:0] FC1_BASE   = 11'd403;   // 16 words

// =========================================================================
// Weight ROM address — registered (1-cycle read latency)
// =========================================================================
reg [6:0]  w_rom_addr;
reg [10:0] d_mem_addr;
reg [31:0] w_data_q, d_data_q;  // registered outputs

always @(posedge clk) begin
    w_data_q <= weight_rom[w_rom_addr];
    d_data_q <= fmap_mem[d_mem_addr];
end

// =========================================================================
// sram_rdata_w / sram_rdata_d: respond to tpu_top's address requests
// tpu_top generates raddr 0..3 for the 4 valid rows, 4..6 as padding
// We keep w_rom_addr and d_mem_addr pointing at base of current tile;
// add sram_raddr offset for the specific row
// =========================================================================
reg [6:0]  w_base_addr;   // base in weight_rom for current layer/tile
reg [10:0] d_base_addr;   // base in fmap_mem for current data tile

always @(posedge clk) begin
    // Respond to tpu_top's address: base + raddr (0..3), padding for 4..6
    if (sram_raddr_w <= 4'd3)
        sram_rdata_w <= weight_rom[w_base_addr + {5'b0, sram_raddr_w[1:0]}];
    else
        sram_rdata_w <= 32'h0;

    if (sram_raddr_d <= 4'd3)
        sram_rdata_d <= fmap_mem[d_base_addr + {7'b0, sram_raddr_d[1:0]}];
    else
        sram_rdata_d <= 32'h0;
end

// =========================================================================
// ECG write port
// =========================================================================
always @(posedge clk) begin
    if (ecg_we)
        fmap_mem[{4'b0, ecg_waddr}] <= {24'b0, ecg_wdata};
end

// =========================================================================
// Result capture from tpu_top (during ROLLING, sram_we_a pulses 7 times)
// C[i][0] = filter_i output for current window
// appears at sram_wdata_a[i*16+15 : i*16] when sram_waddr_a == i
// =========================================================================
reg signed [OUTPUT_DATA_WIDTH-1:0] conv_out [0:3];

always @(posedge clk) begin
    if (sram_we_a) begin
        case (sram_waddr_a)
            3'd0: conv_out[0] <= $signed(sram_wdata_a[15:0]);
            3'd1: conv_out[1] <= $signed(sram_wdata_a[31:16]);
            3'd2: conv_out[2] <= $signed(sram_wdata_a[47:32]);
            3'd3: conv_out[3] <= $signed(sram_wdata_a[63:48]);
            default: ;
        endcase
    end
end

// =========================================================================
// Accumulators (INT32, unrolled — no for-loop in sequential block)
// =========================================================================
reg signed [31:0] acc0,  acc1,  acc2,  acc3;
reg signed [31:0] acc4,  acc5,  acc6,  acc7;
reg signed [31:0] acc8,  acc9,  acc10, acc11;
reg signed [31:0] acc12, acc13, acc14, acc15;
reg signed [31:0] fc2_acc0, fc2_acc1, fc2_acc2, fc2_acc3;

// Helper: select accumulator by group*4+offset
// (read-only combinational mux)
wire signed [31:0] cur_acc0 = (grp_idx==0) ? acc0  : (grp_idx==1) ? acc4  :
                               (grp_idx==2) ? acc8  : acc12;
wire signed [31:0] cur_acc1 = (grp_idx==0) ? acc1  : (grp_idx==1) ? acc5  :
                               (grp_idx==2) ? acc9  : acc13;
wire signed [31:0] cur_acc2 = (grp_idx==0) ? acc2  : (grp_idx==1) ? acc6  :
                               (grp_idx==2) ? acc10 : acc14;
wire signed [31:0] cur_acc3 = (grp_idx==0) ? acc3  : (grp_idx==1) ? acc7  :
                               (grp_idx==2) ? acc11 : acc15;

// =========================================================================
// ReLU + INT8 saturation
// =========================================================================
function [7:0] relu8;
    input signed [OUTPUT_DATA_WIDTH-1:0] x;
    relu8 = x[OUTPUT_DATA_WIDTH-1] ? 8'd0
          : (|x[14:8])             ? 8'd127
          :                          x[7:0];
endfunction

// =========================================================================
// Pool temporary registers (BRAM read latency = 1 cycle)
// =========================================================================
reg [10:0] pool_rd_addr_even, pool_rd_addr_odd;
reg [31:0] pool_even_q, pool_odd_q;
reg        pool_reading_odd;  // flag: first cycle reads even, second reads odd

always @(posedge clk) begin
    pool_even_q <= fmap_mem[pool_rd_addr_even];
    pool_odd_q  <= fmap_mem[pool_rd_addr_odd];
end

// =========================================================================
// Main FSM
// =========================================================================
reg signed [31:0] best_val;
reg [1:0]         best_idx;

always @(posedge clk) begin
    if (~rst_n) begin
        state      <= S_IDLE;
        tpu_start  <= 1'b0;
        done       <= 1'b0;
        pred_class <= 2'd0;
        win_idx    <= 8'd0;
        tile_idx   <= 8'd0;
        grp_idx    <= 4'd0;
        pool_cnt   <= 7'd0;
        w_base_addr <= 7'd0;
        d_base_addr <= 11'd0;
        // Acc reset (unrolled)
        acc0  <= 0; acc1  <= 0; acc2  <= 0; acc3  <= 0;
        acc4  <= 0; acc5  <= 0; acc6  <= 0; acc7  <= 0;
        acc8  <= 0; acc9  <= 0; acc10 <= 0; acc11 <= 0;
        acc12 <= 0; acc13 <= 0; acc14 <= 0; acc15 <= 0;
        fc2_acc0 <= 0; fc2_acc1 <= 0; fc2_acc2 <= 0; fc2_acc3 <= 0;
    end
    else begin
        tpu_start <= 1'b0;

        case (state)

        // -----------------------------------------------------------------
        S_IDLE: begin
            done    <= 1'b0;
            win_idx <= 8'd0;
            if (start) begin
                w_base_addr <= 7'd0;        // conv1 weights: rom[0..3]
                d_base_addr <= 11'd0;       // ecg raw[0..3]
                state       <= S_CONV1_FIRE;
            end
        end

        // -----------------------------------------------------------------
        // CONV1: 125 windows
        // w_base_addr = 0 (fixed for all conv1 windows)
        // d_base_addr = win_idx (slides by 1 each window)
        // -----------------------------------------------------------------
        S_CONV1_FIRE: begin
            tpu_start <= 1'b1;
            state     <= S_CONV1_WAIT;
        end

        S_CONV1_WAIT: begin
            if (tpu_done) state <= S_CONV1_WR;
        end

        S_CONV1_WR: begin
            // Write 4 filter outputs (ReLU + pack) to conv1 area
            fmap_mem[CONV1_BASE + {3'b0, win_idx}] <= {
                relu8(conv_out[3]), relu8(conv_out[2]),
                relu8(conv_out[1]), relu8(conv_out[0])
            };
            if (win_idx == 8'd124) begin
                win_idx  <= 8'd0;
                pool_cnt <= 7'd0;
                // Pre-set pool read addresses for first pair
                pool_rd_addr_even <= CONV1_BASE;
                pool_rd_addr_odd  <= CONV1_BASE + 11'd1;
                state    <= S_POOL1_RD;
            end
            else begin
                win_idx     <= win_idx + 1'b1;
                d_base_addr <= d_base_addr + 11'd1;
                state       <= S_CONV1_FIRE;
            end
        end

        // -----------------------------------------------------------------
        // POOL1: MaxPool1D(2), 62 pairs
        // S_POOL1_RD:  set BRAM addresses, wait 1 cycle for read latency
        // S_POOL1_RD2: addresses already registered above; data available
        //              after the registered read in pool_even_q/odd_q
        // S_POOL1_WR:  compute max, write to pool1 area
        // -----------------------------------------------------------------
        S_POOL1_RD: begin
            // Already set rd addresses; wait 1 cycle for BRAM output
            state <= S_POOL1_RD2;
        end

        S_POOL1_RD2: begin
            // data now in pool_even_q, pool_odd_q
            state <= S_POOL1_WR;
        end

        S_POOL1_WR: begin
            begin : pool1_max
                reg [7:0] m0, m1, m2, m3;
                m0 = ($signed(pool_even_q[7:0])   > $signed(pool_odd_q[7:0]))   ? pool_even_q[7:0]   : pool_odd_q[7:0];
                m1 = ($signed(pool_even_q[15:8])  > $signed(pool_odd_q[15:8]))  ? pool_even_q[15:8]  : pool_odd_q[15:8];
                m2 = ($signed(pool_even_q[23:16]) > $signed(pool_odd_q[23:16])) ? pool_even_q[23:16] : pool_odd_q[23:16];
                m3 = ($signed(pool_even_q[31:24]) > $signed(pool_odd_q[31:24])) ? pool_even_q[31:24] : pool_odd_q[31:24];
                fmap_mem[POOL1_BASE + {4'b0, pool_cnt}] <= {m3, m2, m1, m0};
            end
            if (pool_cnt == 7'd61) begin
                // Done with pool1, setup conv2
                pool_cnt    <= 7'd0;
                win_idx     <= 8'd0;
                w_base_addr <= 7'd4;        // conv2 weights: rom[4..7]
                d_base_addr <= POOL1_BASE;
                state       <= S_CONV2_FIRE;
            end
            else begin
                pool_cnt <= pool_cnt + 1'b1;
                pool_rd_addr_even <= CONV1_BASE + {4'b0, pool_cnt[6:0], 1'b0} + 11'd2; // next even
                pool_rd_addr_odd  <= CONV1_BASE + {4'b0, pool_cnt[6:0], 1'b0} + 11'd3; // next odd
                state <= S_POOL1_RD;
            end
        end

        // -----------------------------------------------------------------
        // CONV2: 59 windows, Cin=4 (4 channels packed per word)
        // -----------------------------------------------------------------
        S_CONV2_FIRE: begin
            tpu_start <= 1'b1;
            state     <= S_CONV2_WAIT;
        end

        S_CONV2_WAIT: begin
            if (tpu_done) state <= S_CONV2_WR;
        end

        S_CONV2_WR: begin
            fmap_mem[CONV2_BASE + {3'b0, win_idx}] <= {
                relu8(conv_out[3]), relu8(conv_out[2]),
                relu8(conv_out[1]), relu8(conv_out[0])
            };
            if (win_idx == 8'd58) begin
                win_idx  <= 8'd0;
                pool_cnt <= 7'd0;
                pool_rd_addr_even <= CONV2_BASE;
                pool_rd_addr_odd  <= CONV2_BASE + 11'd1;
                state    <= S_POOL2_RD;
            end
            else begin
                win_idx     <= win_idx + 1'b1;
                d_base_addr <= d_base_addr + 11'd1;
                state       <= S_CONV2_FIRE;
            end
        end

        // -----------------------------------------------------------------
        // POOL2: 29 pairs
        // -----------------------------------------------------------------
        S_POOL2_RD:  state <= S_POOL2_RD2;

        S_POOL2_RD2: state <= S_POOL2_WR;

        S_POOL2_WR: begin
            begin : pool2_max
                reg [7:0] n0, n1, n2, n3;
                n0 = ($signed(pool_even_q[7:0])   > $signed(pool_odd_q[7:0]))   ? pool_even_q[7:0]   : pool_odd_q[7:0];
                n1 = ($signed(pool_even_q[15:8])  > $signed(pool_odd_q[15:8]))  ? pool_even_q[15:8]  : pool_odd_q[15:8];
                n2 = ($signed(pool_even_q[23:16]) > $signed(pool_odd_q[23:16])) ? pool_even_q[23:16] : pool_odd_q[23:16];
                n3 = ($signed(pool_even_q[31:24]) > $signed(pool_odd_q[31:24])) ? pool_even_q[31:24] : pool_odd_q[31:24];
                fmap_mem[POOL2_BASE + {4'b0, pool_cnt[5:0]}] <= {n3, n2, n1, n0};
            end
            if (pool_cnt == 7'd28) begin
                // Reset accumulators (unrolled — no for loop)
                acc0  <= 0; acc1  <= 0; acc2  <= 0; acc3  <= 0;
                acc4  <= 0; acc5  <= 0; acc6  <= 0; acc7  <= 0;
                acc8  <= 0; acc9  <= 0; acc10 <= 0; acc11 <= 0;
                acc12 <= 0; acc13 <= 0; acc14 <= 0; acc15 <= 0;
                tile_idx    <= 8'd0;
                grp_idx     <= 4'd0;
                w_base_addr <= 7'd8;
                d_base_addr <= POOL2_BASE;
                state       <= S_FC1_FIRE;
            end
            else begin
                pool_cnt <= pool_cnt + 1'b1;
                pool_rd_addr_even <= CONV2_BASE + {5'b0, pool_cnt[5:0], 1'b0} + 11'd2;
                pool_rd_addr_odd  <= CONV2_BASE + {5'b0, pool_cnt[5:0], 1'b0} + 11'd3;
                state <= S_POOL2_RD;
            end
        end

        // -----------------------------------------------------------------
        // FC1: 116->16, tile 29x4 groups
        // w_base_addr = 8 + grp*29 + tile
        // d_base_addr = POOL2_BASE + tile (each word = 4xINT8 features)
        // -----------------------------------------------------------------
        S_FC1_FIRE: begin
            w_base_addr <= 7'd8 + {3'b0, grp_idx} * 7'd29 + {0, tile_idx[5:0]};
            d_base_addr <= POOL2_BASE + {3'b0, tile_idx};
            tpu_start   <= 1'b1;
            state       <= S_FC1_WAIT;
        end

        S_FC1_WAIT: begin
            if (tpu_done) state <= S_FC1_ACC;
        end

        S_FC1_ACC: begin
            // Accumulate into the right group registers (no array indexing in sequential)
            case (grp_idx[1:0])
                2'd0: begin
                    acc0 <= cur_acc0 + {{16{conv_out[0][15]}}, conv_out[0]};
                    acc1 <= cur_acc1 + {{16{conv_out[1][15]}}, conv_out[1]};
                    acc2 <= cur_acc2 + {{16{conv_out[2][15]}}, conv_out[2]};
                    acc3 <= cur_acc3 + {{16{conv_out[3][15]}}, conv_out[3]};
                end
                2'd1: begin
                    acc4 <= cur_acc0 + {{16{conv_out[0][15]}}, conv_out[0]};
                    acc5 <= cur_acc1 + {{16{conv_out[1][15]}}, conv_out[1]};
                    acc6 <= cur_acc2 + {{16{conv_out[2][15]}}, conv_out[2]};
                    acc7 <= cur_acc3 + {{16{conv_out[3][15]}}, conv_out[3]};
                end
                2'd2: begin
                    acc8  <= cur_acc0 + {{16{conv_out[0][15]}}, conv_out[0]};
                    acc9  <= cur_acc1 + {{16{conv_out[1][15]}}, conv_out[1]};
                    acc10 <= cur_acc2 + {{16{conv_out[2][15]}}, conv_out[2]};
                    acc11 <= cur_acc3 + {{16{conv_out[3][15]}}, conv_out[3]};
                end
                2'd3: begin
                    acc12 <= cur_acc0 + {{16{conv_out[0][15]}}, conv_out[0]};
                    acc13 <= cur_acc1 + {{16{conv_out[1][15]}}, conv_out[1]};
                    acc14 <= cur_acc2 + {{16{conv_out[2][15]}}, conv_out[2]};
                    acc15 <= cur_acc3 + {{16{conv_out[3][15]}}, conv_out[3]};
                end
            endcase

            if (tile_idx < 8'd28) begin
                tile_idx <= tile_idx + 1'b1;
                state    <= S_FC1_FIRE;
            end
            else if (grp_idx < 4'd3) begin
                tile_idx <= 8'd0;
                grp_idx  <= grp_idx + 1'b1;
                state    <= S_FC1_FIRE;
            end
            else begin
                // Store FC1 results (ReLU, pack as INT8 1-per-word)
                fmap_mem[FC1_BASE +  0] <= {24'b0, relu8(acc0[15:0])};
                fmap_mem[FC1_BASE +  1] <= {24'b0, relu8(acc1[15:0])};
                fmap_mem[FC1_BASE +  2] <= {24'b0, relu8(acc2[15:0])};
                fmap_mem[FC1_BASE +  3] <= {24'b0, relu8(acc3[15:0])};
                fmap_mem[FC1_BASE +  4] <= {24'b0, relu8(acc4[15:0])};
                fmap_mem[FC1_BASE +  5] <= {24'b0, relu8(acc5[15:0])};
                fmap_mem[FC1_BASE +  6] <= {24'b0, relu8(acc6[15:0])};
                fmap_mem[FC1_BASE +  7] <= {24'b0, relu8(acc7[15:0])};
                fmap_mem[FC1_BASE +  8] <= {24'b0, relu8(acc8[15:0])};
                fmap_mem[FC1_BASE +  9] <= {24'b0, relu8(acc9[15:0])};
                fmap_mem[FC1_BASE + 10] <= {24'b0, relu8(acc10[15:0])};
                fmap_mem[FC1_BASE + 11] <= {24'b0, relu8(acc11[15:0])};
                fmap_mem[FC1_BASE + 12] <= {24'b0, relu8(acc12[15:0])};
                fmap_mem[FC1_BASE + 13] <= {24'b0, relu8(acc13[15:0])};
                fmap_mem[FC1_BASE + 14] <= {24'b0, relu8(acc14[15:0])};
                fmap_mem[FC1_BASE + 15] <= {24'b0, relu8(acc15[15:0])};
                // Reset FC2 accumulators
                fc2_acc0 <= 0; fc2_acc1 <= 0;
                fc2_acc2 <= 0; fc2_acc3 <= 0;
                tile_idx    <= 8'd0;
                state       <= S_FC2_FIRE;
            end
        end

        // -----------------------------------------------------------------
        // FC2: 16->4, 4 tiles
        // w_base_addr = 124 + tile_idx
        // d_base_addr = FC1_BASE + tile_idx*4 (4 INT8 per tile, 1/word)
        // -----------------------------------------------------------------
        S_FC2_FIRE: begin
            w_base_addr <= 7'd124 + {5'b0, tile_idx[1:0]};
            d_base_addr <= FC1_BASE + {3'b0, tile_idx[1:0], 2'b00};
            tpu_start   <= 1'b1;
            state       <= S_FC2_WAIT;
        end

        S_FC2_WAIT: begin
            if (tpu_done) state <= S_FC2_ACC;
        end

        S_FC2_ACC: begin
            fc2_acc0 <= fc2_acc0 + {{16{conv_out[0][15]}}, conv_out[0]};
            fc2_acc1 <= fc2_acc1 + {{16{conv_out[1][15]}}, conv_out[1]};
            fc2_acc2 <= fc2_acc2 + {{16{conv_out[2][15]}}, conv_out[2]};
            fc2_acc3 <= fc2_acc3 + {{16{conv_out[3][15]}}, conv_out[3]};
            if (tile_idx < 4'd3) begin
                tile_idx <= tile_idx + 1'b1;
                state    <= S_FC2_FIRE;
            end
            else begin
                state <= S_ARGMAX;
            end
        end

        // -----------------------------------------------------------------
        S_ARGMAX: begin
            best_val = fc2_acc0; best_idx = 2'd0;
            if ($signed(fc2_acc1) > $signed(best_val)) begin best_val = fc2_acc1; best_idx = 2'd1; end
            if ($signed(fc2_acc2) > $signed(best_val)) begin best_val = fc2_acc2; best_idx = 2'd2; end
            if ($signed(fc2_acc3) > $signed(best_val)) begin best_idx = 2'd3; end
            pred_class <= best_idx;
            state      <= S_DONE;
        end

        S_DONE: begin
            done  <= 1'b1;
            state <= S_IDLE;
        end

        default: state <= S_IDLE;
        endcase
    end
end

// Unused wires for compatibility
wire [6:0]  _w_rom_addr_unused = w_rom_addr;
wire [10:0] _d_mem_addr_unused = d_mem_addr;
wire [31:0] _q_unused0 = w_data_q;
wire [31:0] _q_unused1 = d_data_q;

endmodule