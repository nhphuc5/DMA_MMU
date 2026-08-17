`timescale 1ns / 1ps

// Hybrid DMA launch authorization controller.
//
// CPU START and descriptor-PUSH commands are already authorized by the CPU,
// so they are forwarded without an extra request/grant round trip.  Only an
// autonomous peripheral-originated command sets launch_requires_grant_i.  If
// peripheral authorization is enabled, that command is captured, raises an
// IRQ-visible request, and cannot reach the IOMMU/data plane until software
// writes GRANT.  DENY blocks it before any AXI4 or AXI-Stream transaction.
module dma_access_controller #(
    parameter int ADDR_WIDTH = 16,
    parameter int LEN_WIDTH = 20
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,

    input  logic                    manual_enable_i,
    input  logic                    grant_i,
    input  logic                    deny_i,
    input  logic                    clear_denied_i,

    input  logic                    launch_valid_i,
    input  logic                    launch_requires_grant_i,
    input  logic [ADDR_WIDTH-1:0]   launch_src_i,
    input  logic [ADDR_WIDTH-1:0]   launch_dst_i,
    input  logic [LEN_WIDTH-1:0]    launch_len_i,
    input  logic [1:0]              launch_type_i,
    input  logic [1:0]              launch_mode_i,
    input  logic [7:0]              launch_burst_i,
    input  logic                    launch_queued_i,
    input  logic [7:0]              launch_id_i,

    input  logic                    transfer_done_i,
    input  logic                    transfer_fault_i,

    output logic                    scheduler_start_o,
    output logic [ADDR_WIDTH-1:0]   scheduler_src_o,
    output logic [ADDR_WIDTH-1:0]   scheduler_dst_o,
    output logic [LEN_WIDTH-1:0]    scheduler_len_o,
    output logic [1:0]              scheduler_type_o,
    output logic [1:0]              scheduler_mode_o,
    output logic [7:0]              scheduler_burst_o,

    output logic                    request_pending_o,
    output logic                    grant_active_o,
    output logic                    denied_sticky_o,
    output logic                    denied_pulse_o,
    output logic [ADDR_WIDTH-1:0]   request_src_o,
    output logic [ADDR_WIDTH-1:0]   request_dst_o,
    output logic [LEN_WIDTH-1:0]    request_len_o,
    output logic [1:0]              request_type_o,
    output logic [1:0]              request_mode_o,
    output logic [7:0]              request_burst_o,
    output logic                    request_queued_o,
    output logic                    request_peripheral_o,
    output logic [7:0]              request_id_o
);

    logic launch_after_grant_q;

    // CPU-originated launches and autonomous launches with authorization
    // disabled remain zero-extra-cycle.  A captured peripheral request is
    // released by the registered GRANT pulse.
    always_comb begin
        scheduler_start_o = launch_after_grant_q
                          || (launch_valid_i
                              && (!launch_requires_grant_i
                                  || !manual_enable_i));

        if (launch_valid_i
            && (!launch_requires_grant_i || !manual_enable_i)) begin
            scheduler_src_o = launch_src_i;
            scheduler_dst_o = launch_dst_i;
            scheduler_len_o = launch_len_i;
            scheduler_type_o = launch_type_i;
            scheduler_mode_o = launch_mode_i;
            scheduler_burst_o = launch_burst_i;
        end else begin
            scheduler_src_o = request_src_o;
            scheduler_dst_o = request_dst_o;
            scheduler_len_o = request_len_o;
            scheduler_type_o = request_type_o;
            scheduler_mode_o = request_mode_o;
            scheduler_burst_o = request_burst_o;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            launch_after_grant_q <= 1'b0;
            request_pending_o <= 1'b0;
            grant_active_o <= 1'b0;
            denied_sticky_o <= 1'b0;
            denied_pulse_o <= 1'b0;
            request_src_o <= '0;
            request_dst_o <= '0;
            request_len_o <= '0;
            request_type_o <= '0;
            request_mode_o <= '0;
            request_burst_o <= '0;
            request_queued_o <= 1'b0;
            request_peripheral_o <= 1'b0;
            request_id_o <= '0;
        end else begin
            launch_after_grant_q <= 1'b0;
            denied_pulse_o <= 1'b0;

            if (clear_denied_i)
                denied_sticky_o <= 1'b0;

            if (transfer_done_i || transfer_fault_i)
                grant_active_o <= 1'b0;

            // Capture every accepted command so software/debug always sees
            // the exact descriptor whose access is being considered.
            if (launch_valid_i && !request_pending_o && !grant_active_o) begin
                request_src_o <= launch_src_i;
                request_dst_o <= launch_dst_i;
                request_len_o <= launch_len_i;
                request_type_o <= launch_type_i;
                request_mode_o <= launch_mode_i;
                request_burst_o <= launch_burst_i;
                request_queued_o <= launch_queued_i;
                request_peripheral_o <= launch_requires_grant_i;
                request_id_o <= launch_id_i;

                if (manual_enable_i && launch_requires_grant_i)
                    request_pending_o <= 1'b1;
                else
                    grant_active_o <= 1'b1;
            end

            if (manual_enable_i) begin
                if (grant_i && request_pending_o) begin
                    request_pending_o <= 1'b0;
                    grant_active_o <= 1'b1;
                    launch_after_grant_q <= 1'b1;
                end else if (deny_i && request_pending_o) begin
                    request_pending_o <= 1'b0;
                    grant_active_o <= 1'b0;
                    denied_sticky_o <= 1'b1;
                    denied_pulse_o <= 1'b1;
                end
            end else if (request_pending_o) begin
                // Disabling manual authorization safely releases an already
                // captured request instead of leaving the DMA permanently
                // busy.
                request_pending_o <= 1'b0;
                grant_active_o <= 1'b1;
                launch_after_grant_q <= 1'b1;
            end
        end
    end

endmodule
