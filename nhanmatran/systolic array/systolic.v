// Module: systolic array for matrix multiplication (4x4)
// Scaled down from 32x32 to 4x4 for resource-constrained targets (e.g. Genesys ZU / SonicBOOM)
//
// BUG FIXES vs original 32x32:
//  - ARRAY_SIZE now 4, all hardcoded constants derived from parameter
//  - FIRST_OUT / PARALLEL_START corrected to ARRAY_SIZE+1 / 2*ARRAY_SIZE+1
//  - SRAM input ports reduced from 8 pairs to 1 pair (one 32-bit word holds all 4 x 8-bit elements)
//  - Weight/data queue load logic rewritten to match 1-port, 4-element layout
//  - Reset port renamed consistently to rst_n (was mismatched with tpu_top's srstn)
//  - mul_result sign extension corrected: use DATA_WIDTH*2-1 as MSB index (not hardcoded 15)
//  - Output indexing logic preserved and scaled to 4x4 anti-diagonal pattern

module systolic #(
    parameter ARRAY_SIZE       = 4,   // Size of the array (4x4)
    parameter SRAM_DATA_WIDTH  = 32,  // Data width for SRAM input (holds 4 x 8-bit elements)
    parameter DATA_WIDTH       = 8    // Data width for each matrix element
)(
    input  wire                                         clk,
    input  wire                                         rst_n,          // Active-low synchronous reset
    input  wire                                         alu_start,
    input  wire  [8:0]                                  cycle_num,
    // One SRAM port per axis: each 32-bit word carries ARRAY_SIZE 8-bit elements
    input  wire  [SRAM_DATA_WIDTH-1:0]                  sram_rdata_w,   // weight row
    input  wire  [SRAM_DATA_WIDTH-1:0]                  sram_rdata_d,   // data column
    input  wire  [2:0]                                  matrix_index,   // 3-bit for 4x4 (max index = 7 = 2*4-1)
    output reg signed [(ARRAY_SIZE*(DATA_WIDTH*2+5))-1:0] mul_outcome
);

// ---- Local parameters ----
localparam OUTCOME_WIDTH  = DATA_WIDTH*2 + 5;          // 21 bits per result
// First valid output appears at cycle ARRAY_SIZE+1 (pipeline fills in ARRAY_SIZE cycles, +1 for register)
localparam FIRST_OUT      = ARRAY_SIZE + 1;            // = 5  for 4x4
// Second wave starts after 2*ARRAY_SIZE cycles
localparam PARALLEL_START = 2*ARRAY_SIZE + 1;          // = 9  for 4x4
// Anti-diagonal wrap mask: 2*ARRAY_SIZE (= 8 for 4x4)
localparam DIAG_WRAP      = 2*ARRAY_SIZE;

// ---- Internal storage ----
reg signed [OUTCOME_WIDTH-1:0]   matrix_mul_2D    [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
reg signed [OUTCOME_WIDTH-1:0]   matrix_mul_2D_nx [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
reg signed [DATA_WIDTH-1:0]      data_queue        [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
reg signed [DATA_WIDTH-1:0]      weight_queue      [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
reg signed [DATA_WIDTH*2-1:0]    mul_result;

reg [2:0] upper_bound, lower_bound;   // 3-bit sufficient for index <= 7
integer i, j;

// ----------------------------------------------------------------
// Queue shift register
// Weight flows downward  (row 0 loaded from SRAM, shifts to row N)
// Data  flows rightward  (col 0 loaded from SRAM, shifts to col N)
// ----------------------------------------------------------------
always @(posedge clk) begin
    if (~rst_n) begin
        for (i = 0; i < ARRAY_SIZE; i = i + 1)
            for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                weight_queue[i][j] <= 0;
                data_queue[i][j]   <= 0;
            end
    end
    else if (alu_start) begin
        // Load row-0 of weight_queue from SRAM word (MSB = element 0)
        for (i = 0; i < ARRAY_SIZE; i = i + 1)
            weight_queue[0][i] <= sram_rdata_w[(SRAM_DATA_WIDTH-1 - DATA_WIDTH*i) -: DATA_WIDTH];

        // Shift weight rows downward
        for (i = 1; i < ARRAY_SIZE; i = i + 1)
            for (j = 0; j < ARRAY_SIZE; j = j + 1)
                weight_queue[i][j] <= weight_queue[i-1][j];

        // Load col-0 of data_queue from SRAM word (MSB = element 0)
        for (i = 0; i < ARRAY_SIZE; i = i + 1)
            data_queue[i][0] <= sram_rdata_d[(SRAM_DATA_WIDTH-1 - DATA_WIDTH*i) -: DATA_WIDTH];

        // Shift data columns rightward
        for (i = 0; i < ARRAY_SIZE; i = i + 1)
            for (j = 1; j < ARRAY_SIZE; j = j + 1)
                data_queue[i][j] <= data_queue[i][j-1];
    end
end

// ----------------------------------------------------------------
// Accumulation register
// ----------------------------------------------------------------
always @(posedge clk) begin
    if (~rst_n) begin
        for (i = 0; i < ARRAY_SIZE; i = i + 1)
            for (j = 0; j < ARRAY_SIZE; j = j + 1)
                matrix_mul_2D[i][j] <= 0;
    end
    else begin
        for (i = 0; i < ARRAY_SIZE; i = i + 1)
            for (j = 0; j < ARRAY_SIZE; j = j + 1)
                matrix_mul_2D[i][j] <= matrix_mul_2D_nx[i][j];
    end
end

// ----------------------------------------------------------------
// Combinational MAC logic
// Anti-diagonal (i+j) determines which cell is active each cycle.
// FIRST_OUT   : cell resets accumulator and stores fresh product
// PARALLEL_START : wraps around for second matrix multiply pass
// Otherwise   : accumulate if cycle is past the cell's start
// ----------------------------------------------------------------
always @(*) begin
    if (alu_start) begin
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
            for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                mul_result = weight_queue[i][j] * data_queue[i][j];

                if ((cycle_num >= FIRST_OUT &&
                     (i+j) == (cycle_num - FIRST_OUT) % DIAG_WRAP) ||
                    (cycle_num >= PARALLEL_START &&
                     (i+j) == (cycle_num - PARALLEL_START) % DIAG_WRAP))
                begin
                    // FIX: sign-extend using correct MSB index (DATA_WIDTH*2-1)
                    matrix_mul_2D_nx[i][j] = {{5{mul_result[DATA_WIDTH*2-1]}}, mul_result};
                end
                else if (cycle_num >= 1 && (i + j) <= (cycle_num - 1)) begin
                    matrix_mul_2D_nx[i][j] = matrix_mul_2D[i][j] +
                                             {{5{mul_result[DATA_WIDTH*2-1]}}, mul_result};
                end
                else begin
                    matrix_mul_2D_nx[i][j] = matrix_mul_2D[i][j];
                end
            end
        end
    end
    else begin
        for (i = 0; i < ARRAY_SIZE; i = i + 1)
            for (j = 0; j < ARRAY_SIZE; j = j + 1)
                matrix_mul_2D_nx[i][j] = matrix_mul_2D[i][j];
    end
end

// ----------------------------------------------------------------
// Output mux: select one anti-diagonal row of results
// matrix_index < ARRAY_SIZE  => upper triangle (upper_bound = matrix_index)
// matrix_index >= ARRAY_SIZE => lower triangle (lower_bound = matrix_index)
// ----------------------------------------------------------------
always @(*) begin
    // Default output to 0
    for (i = 0; i < ARRAY_SIZE * OUTCOME_WIDTH; i = i + 1)
        mul_outcome[i] = 1'b0;

    if (matrix_index < ARRAY_SIZE) begin
        upper_bound = matrix_index[2:0];
        lower_bound = 3'd0; // unused in this branch
        for (i = 0; i < ARRAY_SIZE; i = i + 1)
            for (j = 0; j < ARRAY_SIZE - i; j = j + 1)
                if ((i + j) == upper_bound)
                    mul_outcome[i*OUTCOME_WIDTH +: OUTCOME_WIDTH] = matrix_mul_2D[i][j];
    end
    else begin
        lower_bound = matrix_index[2:0];
        upper_bound = 3'd0; // unused in this branch
        for (i = 1; i < ARRAY_SIZE; i = i + 1)
            for (j = ARRAY_SIZE - i; j < ARRAY_SIZE; j = j + 1)
                if ((i + j) == lower_bound)
                    mul_outcome[i*OUTCOME_WIDTH +: OUTCOME_WIDTH] = matrix_mul_2D[i][j];
    end
end

endmodule