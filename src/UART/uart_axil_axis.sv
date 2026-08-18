`timescale 1ns / 1ps

// UART peripheral for the PicoRV32 + DMA/IOMMU SoC.
//
// CPU side: AXI4-Lite registers
//   0x00 DIVIDER  R/W  UART clock divider
//   0x04 DATA     W/R  CPU transmit / receive byte
//   0x08 STATUS   R    [0]TX ready [1]RX valid [2]RX overrun
//                       [3]DMA TX buffered [4]DMA RX word ready
//   0x0c CONTROL  R/W  [0]DMA TX enable [1]DMA RX enable
//                       [2]flush partial DMA RX word (write pulse)
//
// DMA side: 32-bit AXI4-Stream.  TX words are unpacked into UART bytes; RX
// bytes are packed into words.  A partial RX word can be emitted by CONTROL[2].
module uart_axil_axis #(
    parameter int AXIL_ADDR_WIDTH = 8,
    parameter int DEFAULT_DIV = 434
) (
    input  logic clk_i,
    input  logic rst_ni,

    input  logic [AXIL_ADDR_WIDTH-1:0] s_axil_awaddr,
    input  logic [2:0]                 s_axil_awprot,
    input  logic                       s_axil_awvalid,
    output logic                       s_axil_awready,
    input  logic [31:0]                s_axil_wdata,
    input  logic [3:0]                 s_axil_wstrb,
    input  logic                       s_axil_wvalid,
    output logic                       s_axil_wready,
    output logic [1:0]                 s_axil_bresp,
    output logic                       s_axil_bvalid,
    input  logic                       s_axil_bready,
    input  logic [AXIL_ADDR_WIDTH-1:0] s_axil_araddr,
    input  logic [2:0]                 s_axil_arprot,
    input  logic                       s_axil_arvalid,
    output logic                       s_axil_arready,
    output logic [31:0]                s_axil_rdata,
    output logic [1:0]                 s_axil_rresp,
    output logic                       s_axil_rvalid,
    input  logic                       s_axil_rready,

    // DMA memory-to-UART stream (DMA is stream source)
    input  logic [31:0] s_axis_tx_tdata,
    input  logic [3:0]  s_axis_tx_tkeep,
    input  logic        s_axis_tx_tvalid,
    output logic        s_axis_tx_tready,
    input  logic        s_axis_tx_tlast,

    // DMA UART-to-memory stream (DMA is stream sink)
    output logic [31:0] m_axis_rx_tdata,
    output logic [3:0]  m_axis_rx_tkeep,
    output logic        m_axis_rx_tvalid,
    input  logic        m_axis_rx_tready,
    output logic        m_axis_rx_tlast,

    output logic uart_tx_o,
    input  logic uart_rx_i,
    output logic irq_o,

    // Verification observability; these may be left open in hardware.
    output logic [7:0] tx_byte_o,
    output logic       tx_byte_valid_o
);

    localparam logic [7:0] REG_DIVIDER = 8'h00;
    localparam logic [7:0] REG_DATA    = 8'h04;
    localparam logic [7:0] REG_STATUS  = 8'h08;
    localparam logic [7:0] REG_CONTROL = 8'h0c;

    logic [31:0] divider_q;
    logic dma_tx_enable_q, dma_rx_enable_q;

    logic [AXIL_ADDR_WIDTH-1:0] awaddr_q;
    logic [31:0] wdata_q;
    logic [3:0] wstrb_q;
    logic aw_pending_q, w_pending_q;
    logic rx_flush_pulse_q;
    logic cpu_rx_pop_q;

    logic [7:0] cpu_tx_data_q;
    logic cpu_tx_pending_q;

    logic [31:0] tx_word_q;
    logic [3:0] tx_keep_q;
    logic tx_word_valid_q;
    logic [1:0] tx_byte_index;
    logic dma_tx_byte_valid;
    logic [7:0] dma_tx_byte;

    logic [7:0] uart_rx_data;
    logic uart_rx_valid, uart_rx_ready;
    logic uart_rx_overrun;
    logic uart_tx_ready;
    logic uart_tx_valid;
    logic [7:0] uart_tx_data;

    logic [31:0] rx_pack_data_q;
    logic [2:0] rx_pack_count_q;
    logic [31:0] rx_axis_data_q;
    logic [3:0] rx_axis_keep_q;
    logic rx_axis_valid_q, rx_axis_last_q;
    // A second completed RX word is retained while the first word waits for
    // DMA authorization.  Without this skid entry a physical UART cannot be
    // backpressured and bytes arriving during the CPU grant latency overrun.
    logic [31:0] rx_pending_data_q;
    logic [3:0] rx_pending_keep_q;
    logic rx_pending_valid_q, rx_pending_last_q;

    function automatic [31:0] merge_wstrb(
        input [31:0] old_value,
        input [31:0] new_value,
        input [3:0] strobe
    );
        automatic logic [31:0] value;
        value = old_value;
        for (int n = 0; n < 4; n++)
            if (strobe[n])
                value[n*8 +: 8] = new_value[n*8 +: 8];
        return value;
    endfunction

    always_comb begin
        tx_byte_index = 0;
        if (tx_keep_q[0])
            tx_byte_index = 0;
        else if (tx_keep_q[1])
            tx_byte_index = 1;
        else if (tx_keep_q[2])
            tx_byte_index = 2;
        else if (tx_keep_q[3])
            tx_byte_index = 3;

        dma_tx_byte_valid = tx_word_valid_q && |tx_keep_q;
        dma_tx_byte = tx_word_q[tx_byte_index*8 +: 8];
        uart_tx_valid = cpu_tx_pending_q || dma_tx_byte_valid;
        uart_tx_data = cpu_tx_pending_q ? cpu_tx_data_q : dma_tx_byte;

        s_axis_tx_tready = dma_tx_enable_q && !tx_word_valid_q;
        m_axis_rx_tdata = rx_axis_data_q;
        m_axis_rx_tkeep = rx_axis_keep_q;
        m_axis_rx_tvalid = rx_axis_valid_q;
        m_axis_rx_tlast = rx_axis_last_q;
        // Continue packing one additional word while the AXI-Stream output is
        // stalled.  Backpressure reaches the serial engine only when both
        // completed-word slots are occupied.
        uart_rx_ready = dma_rx_enable_q ? !rx_pending_valid_q : cpu_rx_pop_q;

        tx_byte_o = uart_tx_data;
        tx_byte_valid_o = uart_tx_valid && uart_tx_ready;
        irq_o = uart_rx_valid || uart_rx_overrun;
    end

    simpleuart_dma #(
        .DEFAULT_DIV(DEFAULT_DIV)
    ) uart_engine (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .cfg_divider_i(divider_q),
        .serial_tx_o(uart_tx_o),
        .serial_rx_i(uart_rx_i),
        .tx_data_i(uart_tx_data),
        .tx_valid_i(uart_tx_valid),
        .tx_ready_o(uart_tx_ready),
        .rx_data_o(uart_rx_data),
        .rx_valid_o(uart_rx_valid),
        .rx_ready_i(uart_rx_ready),
        .rx_overrun_o(uart_rx_overrun)
    );

    // AXI4-Lite register bank
    always_comb begin
        s_axil_awready = !aw_pending_q;
        s_axil_wready = !w_pending_q;
        s_axil_bresp = 2'b00;
        s_axil_arready = !s_axil_rvalid;
        s_axil_rresp = 2'b00;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            divider_q <= DEFAULT_DIV;
            dma_tx_enable_q <= 1'b1;
            dma_rx_enable_q <= 1'b1;
            awaddr_q <= '0;
            wdata_q <= '0;
            wstrb_q <= '0;
            aw_pending_q <= 1'b0;
            w_pending_q <= 1'b0;
            s_axil_bvalid <= 1'b0;
            s_axil_rvalid <= 1'b0;
            s_axil_rdata <= '0;
            rx_flush_pulse_q <= 1'b0;
            cpu_rx_pop_q <= 1'b0;
            cpu_tx_data_q <= '0;
            cpu_tx_pending_q <= 1'b0;
        end else begin
            rx_flush_pulse_q <= 1'b0;
            cpu_rx_pop_q <= 1'b0;

            if (s_axil_awvalid && s_axil_awready) begin
                awaddr_q <= s_axil_awaddr;
                aw_pending_q <= 1'b1;
            end
            if (s_axil_wvalid && s_axil_wready) begin
                wdata_q <= s_axil_wdata;
                wstrb_q <= s_axil_wstrb;
                w_pending_q <= 1'b1;
            end

            if (aw_pending_q && w_pending_q && !s_axil_bvalid) begin
                // A CPU DATA write waits until the one-byte staging register
                // is free.  Other register writes always complete immediately.
                if (awaddr_q[7:0] != REG_DATA || !cpu_tx_pending_q) begin
                    case (awaddr_q[7:0])
                        REG_DIVIDER:
                            divider_q <= merge_wstrb(divider_q, wdata_q, wstrb_q);
                        REG_DATA: begin
                            if (wstrb_q[0]) begin
                                cpu_tx_data_q <= wdata_q[7:0];
                                cpu_tx_pending_q <= 1'b1;
                            end
                        end
                        REG_STATUS: begin
                            // Reserved for future sticky-status clears.
                        end
                        REG_CONTROL: begin
                            if (wstrb_q[0]) begin
                                dma_tx_enable_q <= wdata_q[0];
                                dma_rx_enable_q <= wdata_q[1];
                                rx_flush_pulse_q <= wdata_q[2];
                            end
                        end
                        default: begin end
                    endcase
                    aw_pending_q <= 1'b0;
                    w_pending_q <= 1'b0;
                    s_axil_bvalid <= 1'b1;
                end
            end
            if (s_axil_bvalid && s_axil_bready)
                s_axil_bvalid <= 1'b0;

            if (s_axil_arvalid && s_axil_arready) begin
                case (s_axil_araddr[7:0])
                    REG_DIVIDER: s_axil_rdata <= divider_q;
                    REG_DATA: begin
                        s_axil_rdata <= uart_rx_valid
                                           ? {24'd0, uart_rx_data}
                                           : 32'hFFFF_FFFF;
                        if (!dma_rx_enable_q && uart_rx_valid)
                            cpu_rx_pop_q <= 1'b1;
                    end
                    REG_STATUS:
                        s_axil_rdata <= {27'd0, rx_axis_valid_q,
                                        tx_word_valid_q, uart_rx_overrun,
                                        uart_rx_valid, uart_tx_ready};
                    REG_CONTROL:
                        s_axil_rdata <= {30'd0, dma_rx_enable_q,
                                        dma_tx_enable_q};
                    default: s_axil_rdata <= 32'd0;
                endcase
                s_axil_rvalid <= 1'b1;
            end
            if (s_axil_rvalid && s_axil_rready)
                s_axil_rvalid <= 1'b0;

            if (cpu_tx_pending_q && uart_tx_ready)
                cpu_tx_pending_q <= 1'b0;
        end
    end

    // DMA TX word unpacker
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            tx_word_q <= '0;
            tx_keep_q <= '0;
            tx_word_valid_q <= 1'b0;
        end else begin
            if (s_axis_tx_tvalid && s_axis_tx_tready) begin
                tx_word_q <= s_axis_tx_tdata;
                tx_keep_q <= s_axis_tx_tkeep;
                tx_word_valid_q <= |s_axis_tx_tkeep;
            end else if (!cpu_tx_pending_q && dma_tx_byte_valid
                         && uart_tx_ready) begin
                tx_keep_q[tx_byte_index] <= 1'b0;
                if ((tx_keep_q & ~(4'b0001 << tx_byte_index)) == 0)
                    tx_word_valid_q <= 1'b0;
            end
        end
    end

    // UART RX byte packer
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rx_pack_data_q <= '0;
            rx_pack_count_q <= 0;
            rx_axis_data_q <= '0;
            rx_axis_keep_q <= '0;
            rx_axis_valid_q <= 1'b0;
            rx_axis_last_q <= 1'b0;
            rx_pending_data_q <= '0;
            rx_pending_keep_q <= '0;
            rx_pending_valid_q <= 1'b0;
            rx_pending_last_q <= 1'b0;
        end else begin
            if (rx_axis_valid_q && m_axis_rx_tready) begin
                if (rx_pending_valid_q) begin
                    rx_axis_data_q <= rx_pending_data_q;
                    rx_axis_keep_q <= rx_pending_keep_q;
                    rx_axis_valid_q <= 1'b1;
                    rx_axis_last_q <= rx_pending_last_q;
                    rx_pending_valid_q <= 1'b0;
                    rx_pending_last_q <= 1'b0;
                end else begin
                    rx_axis_valid_q <= 1'b0;
                    rx_axis_last_q <= 1'b0;
                end
            end

            if (dma_rx_enable_q && uart_rx_valid && uart_rx_ready) begin
                rx_pack_data_q[rx_pack_count_q*8 +: 8] <= uart_rx_data;
                if (rx_pack_count_q == 3) begin
                    if (rx_axis_valid_q && !m_axis_rx_tready) begin
                        rx_pending_data_q <= {uart_rx_data,
                                              rx_pack_data_q[23:0]};
                        rx_pending_keep_q <= 4'b1111;
                        rx_pending_valid_q <= 1'b1;
                        rx_pending_last_q <= 1'b0;
                    end else begin
                        rx_axis_data_q <= {uart_rx_data,
                                           rx_pack_data_q[23:0]};
                        rx_axis_keep_q <= 4'b1111;
                        rx_axis_valid_q <= 1'b1;
                        rx_axis_last_q <= 1'b0;
                    end
                    rx_pack_count_q <= 0;
                end else begin
                    rx_pack_count_q <= rx_pack_count_q + 1'b1;
                end
            end

            if (rx_flush_pulse_q && rx_pack_count_q != 0
                && !rx_pending_valid_q) begin
                if (rx_axis_valid_q && !m_axis_rx_tready) begin
                    rx_pending_data_q <= rx_pack_data_q;
                    rx_pending_keep_q <=
                        (4'b0001 << rx_pack_count_q) - 1'b1;
                    rx_pending_valid_q <= 1'b1;
                    rx_pending_last_q <= 1'b1;
                end else begin
                    rx_axis_data_q <= rx_pack_data_q;
                    rx_axis_keep_q <=
                        (4'b0001 << rx_pack_count_q) - 1'b1;
                    rx_axis_valid_q <= 1'b1;
                    rx_axis_last_q <= 1'b1;
                end
                rx_pack_count_q <= 0;
            end
        end
    end

    logic _unused;
    assign _unused = &{1'b0, s_axil_awprot, s_axil_arprot,
                       s_axis_tx_tlast};

endmodule
