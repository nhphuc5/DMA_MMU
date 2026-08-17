`timescale 1ns / 1ps

// Completion records decouple DMA execution from CPU status polling.  One
// record is produced for every queued descriptor that finishes or faults.
module dma_completion_fifo #(
    parameter int LEN_WIDTH = 20,
    parameter int DEPTH = 8,
    parameter int ID_WIDTH = 8
) (
    input  logic                     clk_i,
    input  logic                     rst_ni,
    input  logic                     flush_i,

    input  logic                     push_i,
    input  logic [ID_WIDTH-1:0]      push_id_i,
    input  logic                     push_done_i,
    input  logic                     push_fault_i,
    input  logic [7:0]               push_fault_code_i,
    input  logic [LEN_WIDTH-1:0]     push_bytes_i,

    input  logic                     pop_i,
    output logic                     valid_o,
    output logic [ID_WIDTH-1:0]      id_o,
    output logic                     done_o,
    output logic                     fault_o,
    output logic [7:0]               fault_code_o,
    output logic [LEN_WIDTH-1:0]     bytes_o,
    output logic                     empty_o,
    output logic                     full_o,
    output logic [$clog2(DEPTH+1)-1:0] count_o
);

    localparam int PTR_WIDTH = (DEPTH <= 2) ? 1 : $clog2(DEPTH);

    logic [ID_WIDTH-1:0] id_mem [0:DEPTH-1];
    logic done_mem [0:DEPTH-1];
    logic fault_mem [0:DEPTH-1];
    logic [7:0] fault_code_mem [0:DEPTH-1];
    logic [LEN_WIDTH-1:0] bytes_mem [0:DEPTH-1];
    logic [PTR_WIDTH-1:0] write_ptr_q;
    logic [PTR_WIDTH-1:0] read_ptr_q;
    logic [$clog2(DEPTH+1)-1:0] count_q;
    logic push_accept;
    logic pop_accept;

    always_comb begin
        empty_o = (count_q == 0);
        full_o = (count_q == DEPTH);
        valid_o = !empty_o;
        count_o = count_q;
        pop_accept = pop_i && !empty_o;
        push_accept = push_i && (!full_o || pop_accept);

        id_o = empty_o ? '0 : id_mem[read_ptr_q];
        done_o = empty_o ? 1'b0 : done_mem[read_ptr_q];
        fault_o = empty_o ? 1'b0 : fault_mem[read_ptr_q];
        fault_code_o = empty_o ? '0 : fault_code_mem[read_ptr_q];
        bytes_o = empty_o ? '0 : bytes_mem[read_ptr_q];
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            write_ptr_q <= '0;
            read_ptr_q <= '0;
            count_q <= '0;
        end else if (flush_i) begin
            write_ptr_q <= '0;
            read_ptr_q <= '0;
            count_q <= '0;
        end else begin
            if (push_accept) begin
                id_mem[write_ptr_q] <= push_id_i;
                done_mem[write_ptr_q] <= push_done_i;
                fault_mem[write_ptr_q] <= push_fault_i;
                fault_code_mem[write_ptr_q] <= push_fault_code_i;
                bytes_mem[write_ptr_q] <= push_bytes_i;
                write_ptr_q <= write_ptr_q + 1'b1;
            end

            if (pop_accept)
                read_ptr_q <= read_ptr_q + 1'b1;

            case ({push_accept, pop_accept})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase
        end
    end

endmodule

