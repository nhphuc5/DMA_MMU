// Module: systolic_controller (4x4)
// Scaled down and bug-fixed from original 32x32 systolic_controll.v
//
// BUG FIXES vs original:
//  - Module name corrected to systolic_controller (original had typo: systolic_controll)
//  - Reset port renamed to rst_n (consistent with systolic.v and tpu_top.v)
//  - ROLLING done condition: matrix_index == 63 hardcode replaced with
//    parameter-derived value (2*ARRAY_SIZE - 1) = 7 for 4x4
//  - addr_serial_num max address scaled: 32x32 used 127; 4x4 uses 2*ARRAY_SIZE-1 = 7
//  - addr_serial_num width reduced from 7-bit to 4-bit (max value = 7 fits in 3 bits,
//    using 4 bits for safety)
//  - matrix_index width reduced from 6-bit to 3-bit (max = 7)
//  - cycle_num kept at 9-bit (still valid; small cost)
//  - ROLLING address increment capped at MAX_ADDR = 2*(2*ARRAY_SIZE-1)-1

module systolic_controller #(
    parameter ARRAY_SIZE = 4
)(
    input  wire       clk,
    input  wire       rst_n,        // Active-low synchronous reset (was inconsistently named srstn in top)
    input  wire       tpu_start,

    output reg        sram_write_enable,
    output reg [3:0]  addr_serial_num,  // Reduced from 7-bit; max = 2*(2N-1)-1 = 13 for 4x4
    output reg        alu_start,
    output reg [8:0]  cycle_num,
    output reg [2:0]  matrix_index,     // Reduced from 6-bit; max = 2*ARRAY_SIZE-1 = 7
    output reg [1:0]  data_set,
    output reg        tpu_done
);

// ---- Local parameters ----
localparam IDLE      = 3'd0;
localparam LOAD_DATA = 3'd1;
localparam WAIT1     = 3'd2;
localparam ROLLING   = 3'd3;

// Maximum anti-diagonal index for NxN array = 2N-2, output cycles start at N+1
// addr_serial_num max: we need enough addresses to feed 2*(2*ARRAY_SIZE-1) cycles = 14 for 4x4
localparam MAX_MATRIX_IDX = 2*ARRAY_SIZE - 1;  // = 7  for 4x4
localparam MAX_ADDR        = 4'd13;             // 2*(2*4-1)-1 = 13

reg [2:0] state, state_nx;
reg [2:0] matrix_index_nx;
reg [3:0] addr_serial_num_nx;
reg [8:0] cycle_num_nx;
reg [1:0] data_set_nx;
reg       tpu_done_nx;

// ----------------------------------------------------------------
// Sequential: state + registers
// ----------------------------------------------------------------
always @(posedge clk) begin
    if (~rst_n) begin
        state          <= IDLE;
        data_set       <= 2'b00;
        cycle_num      <= 9'b0;
        matrix_index   <= 3'b0;
        addr_serial_num<= 4'b0;
        tpu_done       <= 1'b0;
    end
    else begin
        state          <= state_nx;
        data_set       <= data_set_nx;
        cycle_num      <= cycle_num_nx;
        matrix_index   <= matrix_index_nx;
        addr_serial_num<= addr_serial_num_nx;
        tpu_done       <= tpu_done_nx;
    end
end

// ----------------------------------------------------------------
// State transition
// ----------------------------------------------------------------
always @(*) begin
    case (state)
        IDLE: begin
            state_nx    = tpu_start ? LOAD_DATA : IDLE;
            tpu_done_nx = 1'b0;
        end
        LOAD_DATA: begin
            state_nx    = WAIT1;
            tpu_done_nx = 1'b0;
        end
        WAIT1: begin
            state_nx    = ROLLING;
            tpu_done_nx = 1'b0;
        end
        ROLLING: begin
            // FIX: was hardcoded 63; now parameter-driven
            if (matrix_index == MAX_MATRIX_IDX[2:0] && data_set == 2'b01) begin
                state_nx    = IDLE;
                tpu_done_nx = 1'b1;
            end
            else begin
                state_nx    = ROLLING;
                tpu_done_nx = 1'b0;
            end
        end
        default: begin
            state_nx    = IDLE;
            tpu_done_nx = 1'b0;
        end
    endcase
end

// ----------------------------------------------------------------
// addr_serial_num generation
// ----------------------------------------------------------------
always @(*) begin
    case (state)
        IDLE:
            addr_serial_num_nx = tpu_start ? 4'b0 : addr_serial_num;
        LOAD_DATA:
            addr_serial_num_nx = 4'b1;
        WAIT1:
            addr_serial_num_nx = 4'd2;
        ROLLING:
            // FIX: capped at MAX_ADDR (was 127, now 13 for 4x4)
            addr_serial_num_nx = (addr_serial_num == MAX_ADDR) ?
                                  addr_serial_num : addr_serial_num + 1'b1;
        default:
            addr_serial_num_nx = 4'b0;
    endcase
end

// ----------------------------------------------------------------
// Systolic array control signals
// ----------------------------------------------------------------
always @(*) begin
    case (state)
        IDLE: begin
            alu_start        = 1'b0;
            cycle_num_nx     = 9'b0;
            matrix_index_nx  = 3'b0;
            data_set_nx      = 2'b0;
            sram_write_enable= 1'b0;
        end
        LOAD_DATA: begin
            alu_start        = 1'b0;
            cycle_num_nx     = 9'b0;
            matrix_index_nx  = 3'b0;
            data_set_nx      = 2'b0;
            sram_write_enable= 1'b0;
        end
        WAIT1: begin
            alu_start        = 1'b0;
            cycle_num_nx     = 9'b0;
            matrix_index_nx  = 3'b0;
            data_set_nx      = 2'b0;
            sram_write_enable= 1'b0;
        end
        ROLLING: begin
            alu_start    = 1'b1;
            cycle_num_nx = cycle_num + 9'b1;

            // Results are valid after ARRAY_SIZE+1 cycles of pipeline fill
            if (cycle_num >= ARRAY_SIZE + 1) begin
                // FIX: was matrix_index == 63; now uses MAX_MATRIX_IDX
                if (matrix_index == MAX_MATRIX_IDX[2:0]) begin
                    matrix_index_nx  = 3'b0;
                    data_set_nx      = data_set + 1'b1;
                end
                else begin
                    matrix_index_nx  = matrix_index + 1'b1;
                    data_set_nx      = data_set;
                end
                sram_write_enable = 1'b1;
            end
            else begin
                matrix_index_nx  = 3'b0;
                data_set_nx      = data_set;
                sram_write_enable= 1'b0;
            end
        end
        default: begin
            alu_start        = 1'b0;
            cycle_num_nx     = 9'b0;
            matrix_index_nx  = 3'b0;
            data_set_nx      = 2'b0;
            sram_write_enable= 1'b0;
        end
    endcase
end

endmodule