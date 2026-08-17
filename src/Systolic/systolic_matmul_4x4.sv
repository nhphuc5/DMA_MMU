`timescale 1ns / 1ps

// Four-by-four signed INT8 systolic matrix multiplier.
//
// A values move from left to right, B values move from top to bottom, and
// every processing element accumulates one signed INT8 x INT8 product into a
// signed INT32 result.  Inputs are skewed at the array boundary so matching k
// values meet in processing element (row, column) in the same clock cycle.
module systolic_matmul_4x4 #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic                         start_i,
    input  logic                         clear_done_i,
    input  logic [16*DATA_WIDTH-1:0]     matrix_a_i,
    input  logic [16*DATA_WIDTH-1:0]     matrix_b_i,
    output logic [16*ACC_WIDTH-1:0]      matrix_c_o,
    output logic                         busy_o,
    output logic                         done_o,
    output logic [7:0]                   cycle_count_o
);

    localparam int ARRAY_SIZE     = 4;
    localparam int PROD_WIDTH     = 2*DATA_WIDTH;
    localparam int LAST_MAC_CYCLE = 3*ARRAY_SIZE - 3; // 9 for a 4x4 array

    logic [16*DATA_WIDTH-1:0] matrix_a_q, matrix_b_q;
    logic signed [DATA_WIDTH-1:0] a_pipe_q [0:3][0:3];
    logic signed [DATA_WIDTH-1:0] b_pipe_q [0:3][0:3];
    logic                          a_valid_q[0:3][0:3];
    logic                          b_valid_q[0:3][0:3];
    // Register the 16 products before accumulation.  This preserves the
    // systolic wavefront while breaking the long selector -> multiply -> add
    // path.  The focused attribute maps only the multipliers to DSP48E1; the
    // cycle counter and control logic remain in fabric.
    (* use_dsp = "yes" *) logic signed [PROD_WIDTH-1:0] product_q [0:3][0:3];
    logic product_valid_q [0:3][0:3];
    logic signed [ACC_WIDTH-1:0] accum_q [0:3][0:3];

    logic signed [DATA_WIDTH-1:0] a_next [0:3][0:3];
    logic signed [DATA_WIDTH-1:0] b_next [0:3][0:3];
    logic                          a_valid_next[0:3][0:3];
    logic                          b_valid_next[0:3][0:3];

    logic [7:0] cycle_q;
    integer row_comb, column_comb;
    integer row_seq, column_seq;

    // Form the inputs for the next systolic step.  The boundary injection
    // delay is equal to the row/column index; this is the standard wavefront
    // schedule for an output-stationary systolic matrix multiplier.
    always_comb begin
        for (row_comb = 0; row_comb < ARRAY_SIZE; row_comb = row_comb + 1) begin
            for (column_comb = 0; column_comb < ARRAY_SIZE; column_comb = column_comb + 1) begin
                if (column_comb == 0) begin
                    a_next[row_comb][column_comb] = '0;
                    a_valid_next[row_comb][column_comb] = 1'b0;
                    if ((cycle_q >= row_comb) && (cycle_q < row_comb + ARRAY_SIZE)) begin
                        a_next[row_comb][column_comb] = matrix_a_q[
                            ((row_comb*ARRAY_SIZE + (cycle_q-row_comb))*DATA_WIDTH)
                            +: DATA_WIDTH];
                        a_valid_next[row_comb][column_comb] = 1'b1;
                    end
                end else begin
                    a_next[row_comb][column_comb]
                        = a_pipe_q[row_comb][column_comb-1];
                    a_valid_next[row_comb][column_comb]
                        = a_valid_q[row_comb][column_comb-1];
                end

                if (row_comb == 0) begin
                    b_next[row_comb][column_comb] = '0;
                    b_valid_next[row_comb][column_comb] = 1'b0;
                    if ((cycle_q >= column_comb)
                        && (cycle_q < column_comb + ARRAY_SIZE)) begin
                        b_next[row_comb][column_comb] = matrix_b_q[
                            ((((cycle_q-column_comb)*ARRAY_SIZE) + column_comb)*DATA_WIDTH)
                            +: DATA_WIDTH];
                        b_valid_next[row_comb][column_comb] = 1'b1;
                    end
                end else begin
                    b_next[row_comb][column_comb]
                        = b_pipe_q[row_comb-1][column_comb];
                    b_valid_next[row_comb][column_comb]
                        = b_valid_q[row_comb-1][column_comb];
                end
            end
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            matrix_a_q <= '0;
            matrix_b_q <= '0;
            matrix_c_o <= '0;
            busy_o <= 1'b0;
            done_o <= 1'b0;
            cycle_q <= '0;
            cycle_count_o <= '0;
            for (row_seq = 0; row_seq < ARRAY_SIZE; row_seq = row_seq + 1) begin
                for (column_seq = 0; column_seq < ARRAY_SIZE; column_seq = column_seq + 1) begin
                    a_pipe_q[row_seq][column_seq] <= '0;
                    b_pipe_q[row_seq][column_seq] <= '0;
                    a_valid_q[row_seq][column_seq] <= 1'b0;
                    b_valid_q[row_seq][column_seq] <= 1'b0;
                    product_q[row_seq][column_seq] <= '0;
                    product_valid_q[row_seq][column_seq] <= 1'b0;
                    accum_q[row_seq][column_seq] <= '0;
                end
            end
        end else begin
            if (clear_done_i)
                done_o <= 1'b0;

            if (start_i && !busy_o) begin
                matrix_a_q <= matrix_a_i;
                matrix_b_q <= matrix_b_i;
                busy_o <= 1'b1;
                done_o <= 1'b0;
                cycle_q <= '0;
                cycle_count_o <= '0;
                for (row_seq = 0; row_seq < ARRAY_SIZE; row_seq = row_seq + 1) begin
                    for (column_seq = 0; column_seq < ARRAY_SIZE; column_seq = column_seq + 1) begin
                        a_pipe_q[row_seq][column_seq] <= '0;
                        b_pipe_q[row_seq][column_seq] <= '0;
                        a_valid_q[row_seq][column_seq] <= 1'b0;
                        b_valid_q[row_seq][column_seq] <= 1'b0;
                        product_q[row_seq][column_seq] <= '0;
                        product_valid_q[row_seq][column_seq] <= 1'b0;
                        accum_q[row_seq][column_seq] <= '0;
                    end
                end
            end else if (busy_o) begin
                if (cycle_q <= LAST_MAC_CYCLE) begin
                    for (row_seq = 0; row_seq < ARRAY_SIZE; row_seq = row_seq + 1) begin
                        for (column_seq = 0; column_seq < ARRAY_SIZE; column_seq = column_seq + 1) begin
                            a_pipe_q[row_seq][column_seq]
                                <= a_next[row_seq][column_seq];
                            b_pipe_q[row_seq][column_seq]
                                <= b_next[row_seq][column_seq];
                            a_valid_q[row_seq][column_seq]
                                <= a_valid_next[row_seq][column_seq];
                            b_valid_q[row_seq][column_seq]
                                <= b_valid_next[row_seq][column_seq];
                            product_q[row_seq][column_seq]
                                <= $signed(a_next[row_seq][column_seq])
                                 * $signed(b_next[row_seq][column_seq]);
                            product_valid_q[row_seq][column_seq]
                                <= a_valid_next[row_seq][column_seq]
                                && b_valid_next[row_seq][column_seq];
                            if (product_valid_q[row_seq][column_seq]) begin
                                accum_q[row_seq][column_seq]
                                    <= accum_q[row_seq][column_seq]
                                    + $signed(product_q[row_seq][column_seq]);
                            end
                        end
                    end
                    cycle_q <= cycle_q + 1'b1;
                    cycle_count_o <= cycle_count_o + 1'b1;
                end else if (cycle_q == LAST_MAC_CYCLE + 1) begin
                    // Flush the registered product from the final wavefront
                    // cycle into every accumulator.
                    for (row_seq = 0; row_seq < ARRAY_SIZE; row_seq = row_seq + 1) begin
                        for (column_seq = 0; column_seq < ARRAY_SIZE; column_seq = column_seq + 1) begin
                            product_valid_q[row_seq][column_seq] <= 1'b0;
                            if (product_valid_q[row_seq][column_seq]) begin
                                accum_q[row_seq][column_seq]
                                    <= accum_q[row_seq][column_seq]
                                    + $signed(product_q[row_seq][column_seq]);
                            end
                        end
                    end
                    cycle_q <= cycle_q + 1'b1;
                    cycle_count_o <= cycle_count_o + 1'b1;
                end else begin
                    // The previous edge committed the final MAC.  Capture all
                    // 16 complete results on this edge.
                    for (row_seq = 0; row_seq < ARRAY_SIZE; row_seq = row_seq + 1)
                        for (column_seq = 0; column_seq < ARRAY_SIZE; column_seq = column_seq + 1)
                            matrix_c_o[((row_seq*ARRAY_SIZE+column_seq)*ACC_WIDTH)
                                       +: ACC_WIDTH]
                                <= accum_q[row_seq][column_seq];
                    busy_o <= 1'b0;
                    done_o <= 1'b1;
                    cycle_count_o <= cycle_count_o + 1'b1;
                end
            end
        end
    end

endmodule
