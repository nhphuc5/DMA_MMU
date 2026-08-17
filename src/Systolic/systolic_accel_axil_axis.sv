`timescale 1ns / 1ps

// AXI4-Lite control plus AXI4-Stream datapath wrapper for the 4x4 systolic
// matrix multiplier.  The original register map is preserved.  Two extra
// registers select the DMA stream endpoint and expose stream progress:
//   0x84 STREAM_CTRL   W bit0: 0=UART endpoint, 1=Systolic endpoint
//                      W bit1: clear partial stream input (when idle)
//                      W bit2: clear stream protocol error
//   0x88 STREAM_STATUS R bit0: selected, bit1: accepting input,
//                      bit2: computing, bit3: result pending,
//                      bits[7:4]: input words, bits[12:8]: output words,
//                      bit16: protocol error
//
// Stream input is eight 32-bit beats: four packed INT8 rows of A followed by
// four packed INT8 rows of B. Stream output is sixteen signed INT32 results
// in row-major order, with TLAST on result 15.  Backpressure is fully honored.
module systolic_accel_axil_axis #(
    parameter int ADDR_WIDTH = 8
) (
    input  logic                  aclk,
    input  logic                  aresetn,

    input  logic [ADDR_WIDTH-1:0] s_axil_awaddr,
    input  logic [2:0]            s_axil_awprot,
    input  logic                  s_axil_awvalid,
    output logic                  s_axil_awready,
    input  logic [31:0]           s_axil_wdata,
    input  logic [3:0]            s_axil_wstrb,
    input  logic                  s_axil_wvalid,
    output logic                  s_axil_wready,
    output logic [1:0]            s_axil_bresp,
    output logic                  s_axil_bvalid,
    input  logic                  s_axil_bready,

    input  logic [ADDR_WIDTH-1:0] s_axil_araddr,
    input  logic [2:0]            s_axil_arprot,
    input  logic                  s_axil_arvalid,
    output logic                  s_axil_arready,
    output logic [31:0]           s_axil_rdata,
    output logic [1:0]            s_axil_rresp,
    output logic                  s_axil_rvalid,
    input  logic                  s_axil_rready,

    input  logic [31:0]           s_axis_tdata,
    input  logic [3:0]            s_axis_tkeep,
    input  logic                  s_axis_tvalid,
    output logic                  s_axis_tready,
    input  logic                  s_axis_tlast,

    output logic [31:0]           m_axis_tdata,
    output logic [3:0]            m_axis_tkeep,
    output logic                  m_axis_tvalid,
    input  logic                  m_axis_tready,
    output logic                  m_axis_tlast,

    output logic                  stream_select_o,
    output logic                  irq_o
);

    logic [ADDR_WIDTH-1:0] awaddr_q;
    logic [31:0] wdata_q;
    logic [3:0] wstrb_q;
    logic aw_hold_q, w_hold_q;

    logic [31:0] a_row_q[0:3];
    logic [31:0] b_row_q[0:3];
    wire [127:0] matrix_a_flat = {a_row_q[3], a_row_q[2],
                                  a_row_q[1], a_row_q[0]};
    wire [127:0] matrix_b_flat = {b_row_q[3], b_row_q[2],
                                  b_row_q[1], b_row_q[0]};
    wire [511:0] matrix_c_flat;
    wire core_busy, core_done;
    wire [7:0] core_cycles;
    logic start_pulse_q, clear_done_pulse_q;

    logic stream_select_q;
    logic [3:0] stream_input_count_q;
    logic [4:0] stream_output_index_q;
    logic stream_start_pending_q;
    logic stream_operation_q;
    logic stream_output_active_q;
    logic stream_error_q;

    wire aw_fire = s_axil_awvalid && s_axil_awready;
    wire w_fire  = s_axil_wvalid && s_axil_wready;
    wire write_commit = !s_axil_bvalid
                      && (aw_hold_q || aw_fire)
                      && (w_hold_q || w_fire);
    wire [ADDR_WIDTH-1:0] write_addr = aw_hold_q ? awaddr_q
                                                 : s_axil_awaddr;
    wire [31:0] write_data = w_hold_q ? wdata_q : s_axil_wdata;
    wire [3:0] write_strb = w_hold_q ? wstrb_q : s_axil_wstrb;
    wire stream_in_fire = s_axis_tvalid && s_axis_tready;
    wire stream_out_fire = m_axis_tvalid && m_axis_tready;

    integer index;

    function automatic [31:0] apply_wstrb(
        input [31:0] old_value,
        input [31:0] new_value,
        input [3:0] byte_enable
    );
        integer byte_index;
        begin
            apply_wstrb = old_value;
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                if (byte_enable[byte_index])
                    apply_wstrb[byte_index*8 +: 8]
                        = new_value[byte_index*8 +: 8];
        end
    endfunction

    assign s_axil_awready = !aw_hold_q && !s_axil_bvalid;
    assign s_axil_wready  = !w_hold_q && !s_axil_bvalid;
    assign s_axil_bresp   = 2'b00;
    assign s_axil_arready = !s_axil_rvalid;
    assign s_axil_rresp   = 2'b00;

    assign stream_select_o = stream_select_q;
    assign s_axis_tready = stream_select_q && !core_busy
                         && !stream_start_pending_q
                         && !stream_output_active_q;
    assign m_axis_tvalid = stream_select_q && stream_output_active_q;
    assign m_axis_tdata = matrix_c_flat[stream_output_index_q*32 +: 32];
    assign m_axis_tkeep = 4'hf;
    assign m_axis_tlast = stream_output_index_q == 5'd15;
    assign irq_o = core_done;

    systolic_matmul_4x4 core_inst (
        .clk_i(aclk), .rst_ni(aresetn),
        .start_i(start_pulse_q),
        .clear_done_i(clear_done_pulse_q),
        .matrix_a_i(matrix_a_flat), .matrix_b_i(matrix_b_flat),
        .matrix_c_o(matrix_c_flat),
        .busy_o(core_busy), .done_o(core_done),
        .cycle_count_o(core_cycles)
    );

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            awaddr_q <= '0;
            wdata_q <= '0;
            wstrb_q <= '0;
            aw_hold_q <= 1'b0;
            w_hold_q <= 1'b0;
            s_axil_bvalid <= 1'b0;
            s_axil_rvalid <= 1'b0;
            s_axil_rdata <= '0;
            start_pulse_q <= 1'b0;
            clear_done_pulse_q <= 1'b0;
            stream_select_q <= 1'b0;
            stream_input_count_q <= '0;
            stream_output_index_q <= '0;
            stream_start_pending_q <= 1'b0;
            stream_operation_q <= 1'b0;
            stream_output_active_q <= 1'b0;
            stream_error_q <= 1'b0;
            for (index = 0; index < 4; index = index + 1) begin
                a_row_q[index] <= '0;
                b_row_q[index] <= '0;
            end
        end else begin
            start_pulse_q <= 1'b0;
            clear_done_pulse_q <= 1'b0;

            if (aw_fire) begin
                awaddr_q <= s_axil_awaddr;
                aw_hold_q <= 1'b1;
            end
            if (w_fire) begin
                wdata_q <= s_axil_wdata;
                wstrb_q <= s_axil_wstrb;
                w_hold_q <= 1'b1;
            end

            if (write_commit) begin
                case (write_addr[7:2])
                    6'h00: begin
                        if (write_strb[0] && write_data[0] && !core_busy
                            && !stream_output_active_q)
                            start_pulse_q <= 1'b1;
                        if (write_strb[0] && write_data[1])
                            clear_done_pulse_q <= 1'b1;
                    end
                    6'h04: a_row_q[0] <= apply_wstrb(a_row_q[0], write_data, write_strb);
                    6'h05: a_row_q[1] <= apply_wstrb(a_row_q[1], write_data, write_strb);
                    6'h06: a_row_q[2] <= apply_wstrb(a_row_q[2], write_data, write_strb);
                    6'h07: a_row_q[3] <= apply_wstrb(a_row_q[3], write_data, write_strb);
                    6'h08: b_row_q[0] <= apply_wstrb(b_row_q[0], write_data, write_strb);
                    6'h09: b_row_q[1] <= apply_wstrb(b_row_q[1], write_data, write_strb);
                    6'h0a: b_row_q[2] <= apply_wstrb(b_row_q[2], write_data, write_strb);
                    6'h0b: b_row_q[3] <= apply_wstrb(b_row_q[3], write_data, write_strb);
                    6'h21: begin
                        if (write_strb[0]) begin
                            if (!core_busy && !stream_start_pending_q
                                && !stream_output_active_q)
                                stream_select_q <= write_data[0];
                            if (write_data[1] && !core_busy
                                && !stream_start_pending_q) begin
                                stream_input_count_q <= '0;
                                stream_operation_q <= 1'b0;
                            end
                            if (write_data[2])
                                stream_error_q <= 1'b0;
                        end
                    end
                    default: begin end
                endcase
                aw_hold_q <= 1'b0;
                w_hold_q <= 1'b0;
                s_axil_bvalid <= 1'b1;
            end else if (s_axil_bvalid && s_axil_bready) begin
                s_axil_bvalid <= 1'b0;
            end

            if (stream_in_fire) begin
                if (stream_input_count_q < 4)
                    a_row_q[stream_input_count_q[1:0]]
                        <= apply_wstrb(a_row_q[stream_input_count_q[1:0]],
                                      s_axis_tdata, s_axis_tkeep);
                else
                    b_row_q[stream_input_count_q[1:0]]
                        <= apply_wstrb(b_row_q[stream_input_count_q[1:0]],
                                      s_axis_tdata, s_axis_tkeep);

                if (s_axis_tkeep != 4'hf)
                    stream_error_q <= 1'b1;
                // TLAST is allowed after either four-word DMA packet.  This
                // permits A and B to arrive through two independent M2S
                // descriptors without changing the DMA descriptor format.
                if (s_axis_tlast && (stream_input_count_q != 4'd3)
                                 && (stream_input_count_q != 4'd7))
                    stream_error_q <= 1'b1;

                if (stream_input_count_q == 4'd7) begin
                    stream_input_count_q <= '0;
                    stream_start_pending_q <= 1'b1;
                    stream_operation_q <= 1'b1;
                end else begin
                    stream_input_count_q <= stream_input_count_q + 1'b1;
                end
            end

            // Delay START by one clock so the eighth input beat is already
            // committed to the B matrix register before the core samples it.
            if (stream_start_pending_q && !core_busy) begin
                stream_start_pending_q <= 1'b0;
                start_pulse_q <= 1'b1;
                clear_done_pulse_q <= 1'b1;
            end

            if (core_done && stream_operation_q
                && !stream_output_active_q) begin
                stream_output_active_q <= 1'b1;
                stream_output_index_q <= '0;
                stream_operation_q <= 1'b0;
            end

            if (stream_out_fire) begin
                if (stream_output_index_q == 5'd15) begin
                    stream_output_active_q <= 1'b0;
                    stream_output_index_q <= '0;
                end else begin
                    stream_output_index_q <= stream_output_index_q + 1'b1;
                end
            end

            if (s_axil_arvalid && s_axil_arready) begin
                case (s_axil_araddr[7:2])
                    6'h00: s_axil_rdata <= 32'd0;
                    6'h01: s_axil_rdata <= {29'd0, core_done, core_done, core_busy};
                    6'h02: s_axil_rdata <= {8'd32, 8'd8, 8'd4, 8'd1};
                    6'h03: s_axil_rdata <= {24'd0, core_cycles};
                    6'h04: s_axil_rdata <= a_row_q[0];
                    6'h05: s_axil_rdata <= a_row_q[1];
                    6'h06: s_axil_rdata <= a_row_q[2];
                    6'h07: s_axil_rdata <= a_row_q[3];
                    6'h08: s_axil_rdata <= b_row_q[0];
                    6'h09: s_axil_rdata <= b_row_q[1];
                    6'h0a: s_axil_rdata <= b_row_q[2];
                    6'h0b: s_axil_rdata <= b_row_q[3];
                    6'h10: s_axil_rdata <= matrix_c_flat[  0 +: 32];
                    6'h11: s_axil_rdata <= matrix_c_flat[ 32 +: 32];
                    6'h12: s_axil_rdata <= matrix_c_flat[ 64 +: 32];
                    6'h13: s_axil_rdata <= matrix_c_flat[ 96 +: 32];
                    6'h14: s_axil_rdata <= matrix_c_flat[128 +: 32];
                    6'h15: s_axil_rdata <= matrix_c_flat[160 +: 32];
                    6'h16: s_axil_rdata <= matrix_c_flat[192 +: 32];
                    6'h17: s_axil_rdata <= matrix_c_flat[224 +: 32];
                    6'h18: s_axil_rdata <= matrix_c_flat[256 +: 32];
                    6'h19: s_axil_rdata <= matrix_c_flat[288 +: 32];
                    6'h1a: s_axil_rdata <= matrix_c_flat[320 +: 32];
                    6'h1b: s_axil_rdata <= matrix_c_flat[352 +: 32];
                    6'h1c: s_axil_rdata <= matrix_c_flat[384 +: 32];
                    6'h1d: s_axil_rdata <= matrix_c_flat[416 +: 32];
                    6'h1e: s_axil_rdata <= matrix_c_flat[448 +: 32];
                    6'h1f: s_axil_rdata <= matrix_c_flat[480 +: 32];
                    6'h20: s_axil_rdata <= 32'h5359_5354;
                    6'h21: s_axil_rdata <= {31'd0, stream_select_q};
                    6'h22: s_axil_rdata <= {15'd0, stream_error_q, 3'd0,
                                             stream_output_index_q,
                                             stream_input_count_q,
                                             stream_output_active_q,
                                             core_busy,
                                             s_axis_tready,
                                             stream_select_q};
                    default: s_axil_rdata <= 32'd0;
                endcase
                s_axil_rvalid <= 1'b1;
            end else if (s_axil_rvalid && s_axil_rready) begin
                s_axil_rvalid <= 1'b0;
            end
        end
    end

    wire _unused = &{1'b0, s_axil_awprot, s_axil_arprot};

endmodule
