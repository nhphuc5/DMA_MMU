`timescale 1ns / 1ps

/*
 * UART byte engine adapted from picorv32-main/picosoc/simpleuart.v.
 * The original divider and 8N1 state machines are retained, but the register
 * interface is replaced with explicit valid/ready byte channels so an AXI
 * register bank and an AXI4-Stream DMA adapter can share it safely.
 */
module simpleuart_dma #(
    parameter int DEFAULT_DIV = 434
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic [31:0] cfg_divider_i,
    output logic        serial_tx_o,
    input  logic        serial_rx_i,

    input  logic [7:0]  tx_data_i,
    input  logic        tx_valid_i,
    output logic        tx_ready_o,

    output logic [7:0]  rx_data_o,
    output logic        rx_valid_o,
    input  logic        rx_ready_i,
    output logic        rx_overrun_o
);

    logic [3:0]  recv_state_q;
    logic [31:0] recv_divcnt_q;
    logic [7:0]  recv_pattern_q;
    logic        rx_meta_q;
    logic        rx_sync_q;

    logic [9:0]  send_pattern_q;
    logic [3:0]  send_bitcnt_q;
    logic [31:0] send_divcnt_q;
    logic        send_dummy_q;

    assign serial_tx_o = send_pattern_q[0];
    assign tx_ready_o = !send_bitcnt_q && !send_dummy_q;

    // UART RX is asynchronous to clk_i.  Two flip-flops prevent the serial
    // input from feeding the receive state machine directly in hardware.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rx_meta_q <= 1'b1;
            rx_sync_q <= 1'b1;
        end else begin
            rx_meta_q <= serial_rx_i;
            rx_sync_q <= rx_meta_q;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            recv_state_q <= 0;
            recv_divcnt_q <= 0;
            recv_pattern_q <= 0;
            rx_data_o <= 0;
            rx_valid_o <= 1'b0;
            rx_overrun_o <= 1'b0;
        end else begin
            recv_divcnt_q <= recv_divcnt_q + 1'b1;
            if (rx_valid_o && rx_ready_i)
                rx_valid_o <= 1'b0;

            case (recv_state_q)
                0: begin
                    if (!rx_sync_q)
                        recv_state_q <= 1;
                    recv_divcnt_q <= 0;
                end
                1: begin
                    if (2*recv_divcnt_q > cfg_divider_i) begin
                        recv_state_q <= 2;
                        recv_divcnt_q <= 0;
                    end
                end
                10: begin
                    if (recv_divcnt_q > cfg_divider_i) begin
                        if (rx_valid_o && !rx_ready_i)
                            rx_overrun_o <= 1'b1;
                        rx_data_o <= recv_pattern_q;
                        rx_valid_o <= 1'b1;
                        recv_state_q <= 0;
                    end
                end
                default: begin
                    if (recv_divcnt_q > cfg_divider_i) begin
                        recv_pattern_q <= {rx_sync_q, recv_pattern_q[7:1]};
                        recv_state_q <= recv_state_q + 1'b1;
                        recv_divcnt_q <= 0;
                    end
                end
            endcase
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            send_pattern_q <= ~10'd0;
            send_bitcnt_q <= 0;
            send_divcnt_q <= 0;
            send_dummy_q <= 1'b1;
        end else begin
            send_divcnt_q <= send_divcnt_q + 1'b1;
            if (send_dummy_q && !send_bitcnt_q) begin
                send_pattern_q <= ~10'd0;
                send_bitcnt_q <= 15;
                send_divcnt_q <= 0;
                send_dummy_q <= 1'b0;
            end else if (tx_valid_i && tx_ready_o) begin
                send_pattern_q <= {1'b1, tx_data_i, 1'b0};
                send_bitcnt_q <= 10;
                send_divcnt_q <= 0;
            end else if (send_divcnt_q > cfg_divider_i && send_bitcnt_q) begin
                send_pattern_q <= {1'b1, send_pattern_q[9:1]};
                send_bitcnt_q <= send_bitcnt_q - 1'b1;
                send_divcnt_q <= 0;
            end
        end
    end

endmodule
