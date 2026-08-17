`timescale 1ns / 1ps

// AXI4 slave front-end for the project-owned DDR3 controller core.
//
// Supported transactions:
//   * FIXED, INCR, and legal AXI4 WRAP bursts
//   * 1-, 2-, and 4-byte transfers on a 32-bit data bus
//   * independent read/write addresses, IDs, response backpressure
//   * byte write strobes, 4-KiB boundary and aperture checks
//
// The implementation intentionally permits one read burst and one write
// burst to be active, but serializes individual beats into the compact DDR
// scheduler.  This is small, deterministic, and does not infer DSP blocks.
module axi_ddr3_controller #(
    parameter int AXI_ADDR_WIDTH   = 32,
    parameter int AXI_DATA_WIDTH   = 32,
    parameter int AXI_ID_WIDTH     = 6,
    parameter logic [AXI_ADDR_WIDTH-1:0] DDR_BASE_ADDR = 32'h8000_0000,
    parameter logic [AXI_ADDR_WIDTH-1:0] DDR_SIZE_BYTES = 32'h4000_0000,
    parameter int ROW_WIDTH        = 16,
    parameter int COL_WIDTH        = 10,
    parameter int BANK_WIDTH       = 3,
    parameter int RESET_CYCLES     = 64,
    parameter int REFRESH_CYCLES   = 1170,
    parameter int CAL_TIMEOUT      = 65535
) (
    input  logic                         aclk,
    input  logic                         aresetn,

    input  logic [AXI_ID_WIDTH-1:0]      s_axi_awid,
    input  logic [AXI_ADDR_WIDTH-1:0]    s_axi_awaddr,
    input  logic [7:0]                   s_axi_awlen,
    input  logic [2:0]                   s_axi_awsize,
    input  logic [1:0]                   s_axi_awburst,
    input  logic                         s_axi_awlock,
    input  logic [3:0]                   s_axi_awcache,
    input  logic [2:0]                   s_axi_awprot,
    input  logic [3:0]                   s_axi_awqos,
    input  logic                         s_axi_awvalid,
    output logic                         s_axi_awready,
    input  logic [AXI_DATA_WIDTH-1:0]    s_axi_wdata,
    input  logic [AXI_DATA_WIDTH/8-1:0]  s_axi_wstrb,
    input  logic                         s_axi_wlast,
    input  logic                         s_axi_wvalid,
    output logic                         s_axi_wready,
    output logic [AXI_ID_WIDTH-1:0]      s_axi_bid,
    output logic [1:0]                   s_axi_bresp,
    output logic                         s_axi_bvalid,
    input  logic                         s_axi_bready,

    input  logic [AXI_ID_WIDTH-1:0]      s_axi_arid,
    input  logic [AXI_ADDR_WIDTH-1:0]    s_axi_araddr,
    input  logic [7:0]                   s_axi_arlen,
    input  logic [2:0]                   s_axi_arsize,
    input  logic [1:0]                   s_axi_arburst,
    input  logic                         s_axi_arlock,
    input  logic [3:0]                   s_axi_arcache,
    input  logic [2:0]                   s_axi_arprot,
    input  logic [3:0]                   s_axi_arqos,
    input  logic                         s_axi_arvalid,
    output logic                         s_axi_arready,
    output logic [AXI_ID_WIDTH-1:0]      s_axi_rid,
    output logic [AXI_DATA_WIDTH-1:0]    s_axi_rdata,
    output logic [1:0]                   s_axi_rresp,
    output logic                         s_axi_rlast,
    output logic                         s_axi_rvalid,
    input  logic                         s_axi_rready,

    output logic                         init_done_o,
    output logic                         calib_done_o,
    output logic                         calib_error_o,
    output logic                         refresh_busy_o,
    output logic [31:0]                  refresh_count_o,

    output logic                         dfi_cmd_valid_o,
    input  logic                         dfi_cmd_ready_i,
    output logic [2:0]                   dfi_cmd_o,
    output logic [BANK_WIDTH-1:0]        dfi_bank_o,
    output logic [ROW_WIDTH-1:0]         dfi_addr_o,
    output logic [AXI_DATA_WIDTH-1:0]    dfi_wrdata_o,
    output logic [AXI_DATA_WIDTH/8-1:0]  dfi_wrmask_o,
    input  logic                         dfi_rddata_valid_i,
    input  logic [AXI_DATA_WIDTH-1:0]    dfi_rddata_i,
    input  logic                         dfi_error_i,
    output logic                         phy_calib_start_o,
    input  logic                         phy_calib_done_i,
    input  logic                         phy_calib_error_i
);

    localparam int STRB_WIDTH = AXI_DATA_WIDTH/8;
    localparam int MAX_SIZE = $clog2(STRB_WIDTH);
    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;
    localparam logic [1:0] RESP_DECERR = 2'b11;

    initial begin
        if (AXI_DATA_WIDTH != 32)
            $error("axi_ddr3_controller currently requires AXI_DATA_WIDTH=32");
        if (DDR_SIZE_BYTES == 0)
            $error("DDR_SIZE_BYTES must be non-zero");
    end

    function automatic logic wrap_len_legal(input logic [7:0] len);
        wrap_len_legal = len == 8'd1 || len == 8'd3
                      || len == 8'd7 || len == 8'd15;
    endfunction

    function automatic logic [AXI_ADDR_WIDTH-1:0] burst_span(
        input logic [7:0] len,
        input logic [2:0] size
    );
        logic [AXI_ADDR_WIDTH-1:0] beats;
        begin
            beats = {{(AXI_ADDR_WIDTH-9){1'b0}}, 1'b0, len} + 1'b1;
            burst_span = beats << size;
        end
    endfunction

    function automatic logic [AXI_ADDR_WIDTH-1:0] next_addr(
        input logic [AXI_ADDR_WIDTH-1:0] addr,
        input logic [2:0] size,
        input logic [1:0] burst,
        input logic [7:0] len
    );
        logic [AXI_ADDR_WIDTH-1:0] increment;
        logic [AXI_ADDR_WIDTH-1:0] wrap_mask;
        begin
            increment = {{(AXI_ADDR_WIDTH-1){1'b0}}, 1'b1} << size;
            if (burst == 2'b00)
                next_addr = addr;
            else if (burst == 2'b10) begin
                wrap_mask = burst_span(len, size) - 1'b1;
                next_addr = (addr & ~wrap_mask)
                          | ((addr + increment) & wrap_mask);
            end else
                next_addr = addr + increment;
        end
    endfunction

    function automatic logic [1:0] validate_burst(
        input logic [AXI_ADDR_WIDTH-1:0] addr,
        input logic [7:0] len,
        input logic [2:0] size,
        input logic [1:0] burst
    );
        logic [AXI_ADDR_WIDTH:0] aperture_end;
        logic [AXI_ADDR_WIDTH:0] transaction_end;
        logic [AXI_ADDR_WIDTH-1:0] span;
        logic [AXI_ADDR_WIDTH-1:0] align_mask;
        begin
            // A FIXED burst repeatedly accesses one transfer location; its
            // aperture/4-KiB check must not reserve len+1 adjacent beats.
            span = burst == 2'b00
                 ? ({{(AXI_ADDR_WIDTH-1){1'b0}}, 1'b1} << size)
                 : burst_span(len, size);
            aperture_end = {1'b0, DDR_BASE_ADDR} + {1'b0, DDR_SIZE_BYTES};
            transaction_end = {1'b0, addr} + {1'b0, span};
            align_mask = ({{(AXI_ADDR_WIDTH-1){1'b0}}, 1'b1} << size) - 1'b1;
            if (addr < DDR_BASE_ADDR || transaction_end > aperture_end)
                validate_burst = RESP_DECERR;
            else if (size > MAX_SIZE || burst == 2'b11)
                validate_burst = RESP_SLVERR;
            else if ((addr & align_mask) != 0)
                validate_burst = RESP_SLVERR;
            else if (burst == 2'b10 && !wrap_len_legal(len))
                validate_burst = RESP_SLVERR;
            else if (burst != 2'b00
                     && ({1'b0, addr[11:0]} + {1'b0, span[11:0]}) > 13'd4096)
                validate_burst = RESP_SLVERR;
            else
                validate_burst = RESP_OKAY;
        end
    endfunction

    logic wr_active_q;
    logic [AXI_ID_WIDTH-1:0] wr_id_q;
    logic [AXI_ADDR_WIDTH-1:0] wr_addr_q;
    logic [7:0] wr_len_q;
    logic [7:0] wr_beat_q;
    logic [2:0] wr_size_q;
    logic [1:0] wr_burst_q;
    logic [1:0] wr_error_q;
    logic wr_wait_q;
    logic wr_last_q;
    logic wr_expected_last_q;

    logic rd_active_q;
    logic [AXI_ID_WIDTH-1:0] rd_id_q;
    logic [AXI_ADDR_WIDTH-1:0] rd_addr_q;
    logic [7:0] rd_len_q;
    logic [7:0] rd_beat_q;
    logic [2:0] rd_size_q;
    logic [1:0] rd_burst_q;
    logic [1:0] rd_error_q;
    logic rd_wait_q;

    logic bvalid_q;
    logic [AXI_ID_WIDTH-1:0] bid_q;
    logic [1:0] bresp_q;
    logic rvalid_q;
    logic [AXI_ID_WIDTH-1:0] rid_q;
    logic [AXI_DATA_WIDTH-1:0] rdata_q;
    logic [1:0] rresp_q;
    logic rlast_q;

    logic arb_write_q;
    logic core_req_valid;
    logic core_req_ready;
    logic core_req_write;
    logic core_req_tag;
    logic [AXI_ADDR_WIDTH-1:0] core_req_addr;
    logic [AXI_DATA_WIDTH-1:0] core_req_wdata;
    logic [STRB_WIDTH-1:0] core_req_wstrb;
    logic core_rsp_valid;
    logic core_rsp_write;
    logic core_rsp_tag;
    logic [AXI_DATA_WIDTH-1:0] core_rsp_rdata;
    logic core_rsp_error;

    // One-entry native request queue.  Besides decoupling AXI backpressure
    // from the DDR scheduler, this is an intentional timing boundary: AXI
    // error/arbitration logic cannot feed the core FSM combinationally.
    logic request_valid_q;
    logic request_write_q;
    logic request_tag_q;
    logic [AXI_ADDR_WIDTH-1:0] request_addr_q;
    logic [AXI_DATA_WIDTH-1:0] request_wdata_q;
    logic [STRB_WIDTH-1:0] request_wstrb_q;

    wire wr_memory_pending = wr_active_q && wr_error_q == RESP_OKAY
                          && !wr_wait_q && s_axi_wvalid && !bvalid_q;
    wire rd_memory_pending = rd_active_q && rd_error_q == RESP_OKAY
                          && !rd_wait_q && !rvalid_q;
    wire request_slot_free = !request_valid_q;
    wire choose_write = request_slot_free && wr_memory_pending
                     && (!rd_memory_pending || arb_write_q);
    wire choose_read = request_slot_free && rd_memory_pending
                    && !choose_write;

    always_comb begin
        core_req_valid = request_valid_q;
        core_req_write = request_write_q;
        core_req_tag = request_tag_q;
        core_req_addr = request_addr_q;
        core_req_wdata = request_wdata_q;
        core_req_wstrb = request_wstrb_q;

        s_axi_awready = calib_done_o && !calib_error_o
                     && !wr_active_q && !bvalid_q;
        s_axi_arready = calib_done_o && !calib_error_o
                     && !rd_active_q && !rvalid_q;
        s_axi_wready = 1'b0;
        if (wr_active_q && !wr_wait_q && !bvalid_q) begin
            if (wr_error_q != RESP_OKAY)
                s_axi_wready = 1'b1;
            else if (choose_write)
                s_axi_wready = 1'b1;
        end
    end

    assign s_axi_bid = bid_q;
    assign s_axi_bresp = bresp_q;
    assign s_axi_bvalid = bvalid_q;
    assign s_axi_rid = rid_q;
    assign s_axi_rdata = rdata_q;
    assign s_axi_rresp = rresp_q;
    assign s_axi_rlast = rlast_q;
    assign s_axi_rvalid = rvalid_q;

    ddr3_controller_core #(
        .ADDR_WIDTH(AXI_ADDR_WIDTH),
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .ROW_WIDTH(ROW_WIDTH),
        .COL_WIDTH(COL_WIDTH),
        .BANK_WIDTH(BANK_WIDTH),
        .RESET_CYCLES(RESET_CYCLES),
        .REFRESH_CYCLES(REFRESH_CYCLES),
        .CAL_TIMEOUT(CAL_TIMEOUT)
    ) controller_core_inst (
        .clk_i(aclk), .rst_ni(aresetn),
        .req_valid_i(core_req_valid), .req_ready_o(core_req_ready),
        .req_write_i(core_req_write), .req_tag_i(core_req_tag),
        .req_addr_i(core_req_addr), .req_wdata_i(core_req_wdata),
        .req_wstrb_i(core_req_wstrb),
        .rsp_valid_o(core_rsp_valid), .rsp_ready_i(1'b1),
        .rsp_write_o(core_rsp_write), .rsp_tag_o(core_rsp_tag),
        .rsp_rdata_o(core_rsp_rdata), .rsp_error_o(core_rsp_error),
        .init_done_o, .calib_done_o, .calib_error_o,
        .refresh_busy_o, .refresh_count_o,
        .dfi_cmd_valid_o, .dfi_cmd_ready_i, .dfi_cmd_o,
        .dfi_bank_o, .dfi_addr_o, .dfi_wrdata_o, .dfi_wrmask_o,
        .dfi_rddata_valid_i, .dfi_rddata_i, .dfi_error_i,
        .phy_calib_start_o, .phy_calib_done_i, .phy_calib_error_i
    );

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wr_active_q <= 1'b0;
            wr_id_q <= '0;
            wr_addr_q <= '0;
            wr_len_q <= '0;
            wr_beat_q <= '0;
            wr_size_q <= '0;
            wr_burst_q <= '0;
            wr_error_q <= RESP_OKAY;
            wr_wait_q <= 1'b0;
            wr_last_q <= 1'b0;
            wr_expected_last_q <= 1'b0;
            rd_active_q <= 1'b0;
            rd_id_q <= '0;
            rd_addr_q <= '0;
            rd_len_q <= '0;
            rd_beat_q <= '0;
            rd_size_q <= '0;
            rd_burst_q <= '0;
            rd_error_q <= RESP_OKAY;
            rd_wait_q <= 1'b0;
            bvalid_q <= 1'b0;
            bid_q <= '0;
            bresp_q <= RESP_OKAY;
            rvalid_q <= 1'b0;
            rid_q <= '0;
            rdata_q <= '0;
            rresp_q <= RESP_OKAY;
            rlast_q <= 1'b0;
            arb_write_q <= 1'b1;
            request_valid_q <= 1'b0;
            request_write_q <= 1'b0;
            request_tag_q <= 1'b0;
            request_addr_q <= '0;
            request_wdata_q <= '0;
            request_wstrb_q <= '0;
        end else begin
            if (request_valid_q && core_req_ready)
                request_valid_q <= 1'b0;

            if (bvalid_q && s_axi_bready)
                bvalid_q <= 1'b0;
            if (rvalid_q && s_axi_rready) begin
                rvalid_q <= 1'b0;
                if (rlast_q)
                    rd_active_q <= 1'b0;
                else begin
                    rd_beat_q <= rd_beat_q + 1'b1;
                    rd_addr_q <= next_addr(rd_addr_q, rd_size_q,
                                           rd_burst_q, rd_len_q);
                end
            end

            if (s_axi_awvalid && s_axi_awready) begin
                wr_active_q <= 1'b1;
                wr_id_q <= s_axi_awid;
                wr_addr_q <= s_axi_awaddr;
                wr_len_q <= s_axi_awlen;
                wr_beat_q <= '0;
                wr_size_q <= s_axi_awsize;
                wr_burst_q <= s_axi_awburst;
                wr_error_q <= validate_burst(s_axi_awaddr, s_axi_awlen,
                                               s_axi_awsize, s_axi_awburst);
            end
            if (s_axi_arvalid && s_axi_arready) begin
                rd_active_q <= 1'b1;
                rd_id_q <= s_axi_arid;
                rd_addr_q <= s_axi_araddr;
                rd_len_q <= s_axi_arlen;
                rd_beat_q <= '0;
                rd_size_q <= s_axi_arsize;
                rd_burst_q <= s_axi_arburst;
                rd_error_q <= validate_burst(s_axi_araddr, s_axi_arlen,
                                               s_axi_arsize, s_axi_arburst);
            end

            // Invalid reads generate deterministic zero data without touching
            // the DDR command scheduler, one beat per AXI handshake.
            if (rd_active_q && rd_error_q != RESP_OKAY && !rvalid_q) begin
                rid_q <= rd_id_q;
                rdata_q <= '0;
                rresp_q <= rd_error_q;
                rlast_q <= rd_beat_q == rd_len_q;
                rvalid_q <= 1'b1;
            end

            if (choose_write && s_axi_wvalid && s_axi_wready) begin
                request_valid_q <= 1'b1;
                request_write_q <= 1'b1;
                request_tag_q <= 1'b1;
                request_addr_q <= wr_addr_q - DDR_BASE_ADDR;
                request_wdata_q <= s_axi_wdata;
                request_wstrb_q <= s_axi_wstrb;
                arb_write_q <= 1'b0;
                begin
                    wr_wait_q <= 1'b1;
                    wr_last_q <= s_axi_wlast;
                    // Pipeline the burst-end comparison at the request queue
                    // boundary.  The DDR response path therefore does not
                    // contain an 8-bit equality decoder feeding every AXI
                    // state/address clock enable.
                    wr_expected_last_q <= wr_beat_q == wr_len_q;
                end
            end else if (choose_read) begin
                request_valid_q <= 1'b1;
                request_write_q <= 1'b0;
                request_tag_q <= 1'b0;
                request_addr_q <= rd_addr_q - DDR_BASE_ADDR;
                request_wdata_q <= '0;
                request_wstrb_q <= '0;
                arb_write_q <= 1'b1;
                rd_wait_q <= 1'b1;
            end

            // Invalid writes still consume the exact announced burst so a bad
            // request cannot desynchronize the W channel.
            if (s_axi_wvalid && s_axi_wready && wr_error_q != RESP_OKAY) begin
                if (s_axi_wlast || wr_beat_q == wr_len_q) begin
                    bid_q <= wr_id_q;
                    bresp_q <= wr_error_q;
                    bvalid_q <= 1'b1;
                    wr_active_q <= 1'b0;
                end else begin
                    wr_beat_q <= wr_beat_q + 1'b1;
                    wr_addr_q <= next_addr(wr_addr_q, wr_size_q,
                                           wr_burst_q, wr_len_q);
                end
            end

            if (core_rsp_valid) begin
                if (core_rsp_write) begin
                    wr_wait_q <= 1'b0;
                    if (core_rsp_error || wr_last_q != wr_expected_last_q)
                        wr_error_q <= RESP_SLVERR;
                    if (wr_last_q || wr_expected_last_q) begin
                        bid_q <= wr_id_q;
                        bresp_q <= (core_rsp_error
                                   || wr_last_q != wr_expected_last_q)
                                   ? RESP_SLVERR : wr_error_q;
                        bvalid_q <= 1'b1;
                        wr_active_q <= 1'b0;
                    end else begin
                        wr_beat_q <= wr_beat_q + 1'b1;
                        wr_addr_q <= next_addr(wr_addr_q, wr_size_q,
                                               wr_burst_q, wr_len_q);
                    end
                end else begin
                    rd_wait_q <= 1'b0;
                    rid_q <= rd_id_q;
                    rdata_q <= core_rsp_rdata;
                    rresp_q <= core_rsp_error ? RESP_SLVERR : RESP_OKAY;
                    rlast_q <= rd_beat_q == rd_len_q;
                    rvalid_q <= 1'b1;
                end
            end
        end
    end

    logic _unused;
    assign _unused = &{1'b0, s_axi_awlock, s_axi_awcache, s_axi_awprot,
                       s_axi_awqos, s_axi_arlock, s_axi_arcache,
                       s_axi_arprot, s_axi_arqos, core_rsp_tag};

endmodule
