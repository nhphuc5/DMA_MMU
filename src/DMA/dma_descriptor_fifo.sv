`timescale 1ns / 1ps

// Eight-entry descriptor queue used by the DMA control plane.  The queue
// deliberately stores all descriptor metadata locally so software may submit
// several non-contiguous transfers without waiting for each transfer to end.
module dma_descriptor_fifo #(
    parameter int ADDR_WIDTH = 16,
    parameter int LEN_WIDTH = 20,
    parameter int DEPTH = 8,
    parameter int ID_WIDTH = 8
) (
    input  logic                     clk_i,
    input  logic                     rst_ni,
    input  logic                     flush_i,

    input  logic                     push_i,
    input  logic [ADDR_WIDTH-1:0]    push_src_addr_i,
    input  logic [ADDR_WIDTH-1:0]    push_dst_addr_i,
    input  logic [LEN_WIDTH-1:0]     push_length_i,
    input  logic [1:0]               push_transfer_type_i,
    input  logic [1:0]               push_dma_mode_i,
    input  logic [7:0]               push_burst_words_i,
    input  logic                     push_irq_i,
    input  logic [ID_WIDTH-1:0]      push_id_i,
    input  logic [ADDR_WIDTH-1:0]    push_next_desc_i,
    output logic                     push_accepted_o,
    output logic                     push_rejected_o,

    input  logic                     pop_i,
    output logic                     valid_o,
    output logic [ADDR_WIDTH-1:0]    src_addr_o,
    output logic [ADDR_WIDTH-1:0]    dst_addr_o,
    output logic [LEN_WIDTH-1:0]     length_o,
    output logic [1:0]               transfer_type_o,
    output logic [1:0]               dma_mode_o,
    output logic [7:0]               burst_words_o,
    output logic                     irq_o,
    output logic [ID_WIDTH-1:0]      id_o,
    output logic [ADDR_WIDTH-1:0]    next_desc_o,

    output logic                     empty_o,
    output logic                     full_o,
    output logic [$clog2(DEPTH+1)-1:0] count_o
);

    localparam int PTR_WIDTH = (DEPTH <= 2) ? 1 : $clog2(DEPTH);

    logic [ADDR_WIDTH-1:0] src_mem [0:DEPTH-1];
    logic [ADDR_WIDTH-1:0] dst_mem [0:DEPTH-1];
    logic [LEN_WIDTH-1:0] len_mem [0:DEPTH-1];
    logic [1:0] type_mem [0:DEPTH-1];
    logic [1:0] mode_mem [0:DEPTH-1];
    logic [7:0] burst_mem [0:DEPTH-1];
    logic irq_mem [0:DEPTH-1];
    logic [ID_WIDTH-1:0] id_mem [0:DEPTH-1];
    logic [ADDR_WIDTH-1:0] next_mem [0:DEPTH-1];

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

        // A simultaneous pop makes room for a push even when initially full.
        pop_accept = pop_i && !empty_o;
        push_accept = push_i && (!full_o || pop_accept);
        push_accepted_o = push_accept;
        push_rejected_o = push_i && !push_accept;

        src_addr_o = empty_o ? '0 : src_mem[read_ptr_q];
        dst_addr_o = empty_o ? '0 : dst_mem[read_ptr_q];
        length_o = empty_o ? '0 : len_mem[read_ptr_q];
        transfer_type_o = empty_o ? '0 : type_mem[read_ptr_q];
        dma_mode_o = empty_o ? '0 : mode_mem[read_ptr_q];
        burst_words_o = empty_o ? '0 : burst_mem[read_ptr_q];
        irq_o = empty_o ? 1'b0 : irq_mem[read_ptr_q];
        id_o = empty_o ? '0 : id_mem[read_ptr_q];
        next_desc_o = empty_o ? '0 : next_mem[read_ptr_q];
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
                src_mem[write_ptr_q] <= push_src_addr_i;
                dst_mem[write_ptr_q] <= push_dst_addr_i;
                len_mem[write_ptr_q] <= push_length_i;
                type_mem[write_ptr_q] <= push_transfer_type_i;
                mode_mem[write_ptr_q] <= push_dma_mode_i;
                burst_mem[write_ptr_q] <= push_burst_words_i;
                irq_mem[write_ptr_q] <= push_irq_i;
                id_mem[write_ptr_q] <= push_id_i;
                next_mem[write_ptr_q] <= push_next_desc_i;
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

