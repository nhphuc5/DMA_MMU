`timescale 1ns / 1ps

// Verifies the board-facing branch without simulating encrypted/vendor MIG
// internals.  A small AXI slave stands in for MIG and checks that axi_ram is
// retained, DDR addresses are rebased, AXI metadata/WSTRB are preserved,
// backpressure is tolerated, and calibration status is propagated.
module tb_axi_bram_external_ddr_subsystem;
    localparam int ID_WIDTH = 6;
    localparam logic [31:0] DDR_BASE = 32'h8000_0000;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #3.333 clk = ~clk;

    logic [ID_WIDTH-1:0] awid = '0;
    logic [31:0] awaddr = '0;
    logic [7:0] awlen = '0;
    logic [2:0] awsize = 3'd2;
    logic [1:0] awburst = 2'b01;
    logic awvalid = 1'b0;
    wire awready;
    logic [31:0] wdata = '0;
    logic [3:0] wstrb = '0;
    logic wlast = 1'b0;
    logic wvalid = 1'b0;
    wire wready;
    wire [ID_WIDTH-1:0] bid;
    wire [1:0] bresp;
    wire bvalid;
    logic bready = 1'b1;
    logic [ID_WIDTH-1:0] arid = '0;
    logic [31:0] araddr = '0;
    logic [7:0] arlen = '0;
    logic [2:0] arsize = 3'd2;
    logic [1:0] arburst = 2'b01;
    logic arvalid = 1'b0;
    wire arready;
    wire [ID_WIDTH-1:0] rid;
    wire [31:0] rdata;
    wire [1:0] rresp;
    wire rlast;
    wire rvalid;
    logic rready = 1'b1;

    wire [ID_WIDTH-1:0] mig_awid, mig_arid;
    wire [31:0] mig_awaddr, mig_araddr;
    wire [7:0] mig_awlen, mig_arlen;
    wire [2:0] mig_awsize, mig_arsize;
    wire [1:0] mig_awburst, mig_arburst;
    wire mig_awvalid, mig_wvalid, mig_wlast, mig_bready;
    wire mig_arvalid, mig_rready;
    wire [31:0] mig_wdata;
    wire [3:0] mig_wstrb;
    logic mig_awready = 1'b0;
    logic mig_wready = 1'b0;
    logic [ID_WIDTH-1:0] mig_bid = '0;
    logic [1:0] mig_bresp = 2'b00;
    logic mig_bvalid = 1'b0;
    logic mig_arready = 1'b0;
    logic [ID_WIDTH-1:0] mig_rid = '0;
    logic [31:0] mig_rdata = '0;
    logic [1:0] mig_rresp = 2'b00;
    logic mig_rlast = 1'b0;
    logic mig_rvalid = 1'b0;

    logic external_calib_done = 1'b0;
    logic external_calib_error = 1'b0;
    wire init_done, calib_done, calib_error;
    wire refresh_busy;
    wire [31:0] refresh_count;

    axi_bram_ddr3_subsystem #(
        .AXI_ADDR_WIDTH(32), .AXI_DATA_WIDTH(32),
        .AXI_ID_WIDTH(ID_WIDTH), .BRAM_ADDR_WIDTH(16),
        .USE_EXTERNAL_DDR_AXI(1'b1),
        .DDR_BASE_ADDR(DDR_BASE), .DDR_SIZE_BYTES(32'h4000_0000)
    ) dut (
        .clk_i(clk), .rst_i(rst),
        .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen),
        .s_axi_awsize(awsize), .s_axi_awburst(awburst), .s_axi_awlock(1'b0),
        .s_axi_awcache(4'b0), .s_axi_awprot(3'b0), .s_axi_awqos(4'b0),
        .s_axi_awregion(4'b0), .s_axi_awvalid(awvalid),
        .s_axi_awready(awready), .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb), .s_axi_wlast(wlast), .s_axi_wvalid(wvalid),
        .s_axi_wready(wready), .s_axi_bid(bid), .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(arlen),
        .s_axi_arsize(arsize), .s_axi_arburst(arburst), .s_axi_arlock(1'b0),
        .s_axi_arcache(4'b0), .s_axi_arprot(3'b0), .s_axi_arqos(4'b0),
        .s_axi_arregion(4'b0), .s_axi_arvalid(arvalid),
        .s_axi_arready(arready), .s_axi_rid(rid), .s_axi_rdata(rdata),
        .s_axi_rresp(rresp), .s_axi_rlast(rlast), .s_axi_rvalid(rvalid),
        .s_axi_rready(rready),
        .m_ddr_axi_awid(mig_awid), .m_ddr_axi_awaddr(mig_awaddr),
        .m_ddr_axi_awlen(mig_awlen), .m_ddr_axi_awsize(mig_awsize),
        .m_ddr_axi_awburst(mig_awburst), .m_ddr_axi_awvalid(mig_awvalid),
        .m_ddr_axi_awready(mig_awready), .m_ddr_axi_wdata(mig_wdata),
        .m_ddr_axi_wstrb(mig_wstrb), .m_ddr_axi_wlast(mig_wlast),
        .m_ddr_axi_wvalid(mig_wvalid), .m_ddr_axi_wready(mig_wready),
        .m_ddr_axi_bid(mig_bid), .m_ddr_axi_bresp(mig_bresp),
        .m_ddr_axi_bvalid(mig_bvalid), .m_ddr_axi_bready(mig_bready),
        .m_ddr_axi_arid(mig_arid), .m_ddr_axi_araddr(mig_araddr),
        .m_ddr_axi_arlen(mig_arlen), .m_ddr_axi_arsize(mig_arsize),
        .m_ddr_axi_arburst(mig_arburst), .m_ddr_axi_arvalid(mig_arvalid),
        .m_ddr_axi_arready(mig_arready), .m_ddr_axi_rid(mig_rid),
        .m_ddr_axi_rdata(mig_rdata), .m_ddr_axi_rresp(mig_rresp),
        .m_ddr_axi_rlast(mig_rlast), .m_ddr_axi_rvalid(mig_rvalid),
        .m_ddr_axi_rready(mig_rready),
        .external_ddr_calib_done_i(external_calib_done),
        .external_ddr_calib_error_i(external_calib_error),
        .dfi_cmd_ready_i(1'b0), .dfi_rddata_valid_i(1'b0),
        .dfi_rddata_i(32'd0), .dfi_error_i(1'b0),
        .phy_calib_done_i(1'b0), .phy_calib_error_i(1'b0),
        .ddr_init_done_o(init_done), .ddr_calib_done_o(calib_done),
        .ddr_calib_error_o(calib_error), .ddr_refresh_busy_o(refresh_busy),
        .ddr_refresh_count_o(refresh_count)
    );

    integer cycles = 0;
    integer external_aw_count = 0;
    integer external_ar_count = 0;
    logic aw_seen = 1'b0;
    logic [ID_WIDTH-1:0] held_awid = '0;
    logic [31:0] held_awaddr = '0;
    logic [31:0] memory_word = 32'ha5a5_a5a5;
    logic [31:0] observed_awaddr = '0;
    logic [ID_WIDTH-1:0] observed_awid = '0;
    logic [7:0] observed_awlen = '0;
    logic [2:0] observed_awsize = '0;
    logic [1:0] observed_awburst = '0;
    logic [3:0] observed_wstrb = '0;

    // Backpressure-capable one-word stand-in for the generated MIG AXI port.
    always_ff @(posedge clk) begin
        if (rst) begin
            cycles <= 0;
            mig_awready <= 1'b0;
            mig_wready <= 1'b0;
            mig_arready <= 1'b0;
            mig_bvalid <= 1'b0;
            mig_rvalid <= 1'b0;
            mig_rlast <= 1'b0;
            aw_seen <= 1'b0;
            external_aw_count <= 0;
            external_ar_count <= 0;
            memory_word <= 32'ha5a5_a5a5;
        end else begin
            cycles <= cycles + 1;
            // Periodically deassert READY so the bridge must hold VALID/data.
            mig_awready <= cycles[1:0] != 2'b00;
            mig_wready <= cycles[1:0] != 2'b01;
            mig_arready <= cycles[1:0] != 2'b10;

            if (mig_bvalid && mig_bready)
                mig_bvalid <= 1'b0;
            if (mig_rvalid && mig_rready) begin
                mig_rvalid <= 1'b0;
                mig_rlast <= 1'b0;
            end

            if (mig_awvalid && mig_awready) begin
                aw_seen <= 1'b1;
                held_awid <= mig_awid;
                held_awaddr <= mig_awaddr;
                observed_awid <= mig_awid;
                observed_awaddr <= mig_awaddr;
                observed_awlen <= mig_awlen;
                observed_awsize <= mig_awsize;
                observed_awburst <= mig_awburst;
                external_aw_count <= external_aw_count + 1;
            end
            if (mig_wvalid && mig_wready) begin
                observed_wstrb <= mig_wstrb;
                if (mig_wstrb[0]) memory_word[7:0] <= mig_wdata[7:0];
                if (mig_wstrb[1]) memory_word[15:8] <= mig_wdata[15:8];
                if (mig_wstrb[2]) memory_word[23:16] <= mig_wdata[23:16];
                if (mig_wstrb[3]) memory_word[31:24] <= mig_wdata[31:24];
                if (aw_seen && mig_wlast) begin
                    mig_bid <= held_awid;
                    mig_bresp <= 2'b00;
                    mig_bvalid <= 1'b1;
                    aw_seen <= 1'b0;
                end
            end
            if (mig_arvalid && mig_arready) begin
                external_ar_count <= external_ar_count + 1;
                mig_rid <= mig_arid;
                mig_rdata <= memory_word;
                mig_rresp <= 2'b00;
                mig_rlast <= 1'b1;
                mig_rvalid <= 1'b1;
            end
        end
    end

    integer checks = 0;
    integer failures = 0;
    task automatic check(input logic condition, input string name);
        begin
            checks = checks + 1;
            if (condition) $display("PASS %s", name);
            else begin failures = failures + 1; $display("FAIL %s", name); end
        end
    endtask

    task automatic write_word(
        input logic [31:0] address, input logic [31:0] data,
        input logic [3:0] strobe, input logic [ID_WIDTH-1:0] id
    );
        begin
            @(negedge clk);
            awaddr = address; awid = id; awvalid = 1'b1;
            do @(posedge clk); while (!awready);
            @(negedge clk); awvalid = 1'b0;
            wdata = data; wstrb = strobe; wlast = 1'b1; wvalid = 1'b1;
            do @(posedge clk); while (!wready);
            @(negedge clk); wvalid = 1'b0; wlast = 1'b0;
            do @(negedge clk); while (!bvalid);
            check(bresp == 2'b00 && bid == id, "write response and ID");
        end
    endtask

    task automatic read_word(
        input logic [31:0] address, input logic [ID_WIDTH-1:0] id,
        output logic [31:0] data
    );
        begin
            @(negedge clk);
            araddr = address; arid = id; arvalid = 1'b1;
            do @(posedge clk); while (!arready);
            @(negedge clk); arvalid = 1'b0;
            do @(negedge clk); while (!rvalid);
            data = rdata;
            check(rresp == 2'b00 && rid == id && rlast,
                  "read response, ID and RLAST");
        end
    endtask

    logic [31:0] captured_data;
    integer aw_before, ar_before;
    initial begin
        repeat (8) @(negedge clk);
        rst = 1'b0;
        repeat (3) @(negedge clk);
        check(!init_done && !calib_done && !calib_error,
              "external MIG status starts uncalibrated");
        external_calib_done = 1'b1;
        repeat (2) @(negedge clk);
        check(init_done && calib_done && !calib_error,
              "external MIG calibration status propagated");

        aw_before = external_aw_count;
        ar_before = external_ar_count;
        write_word(32'h0000_0100, 32'h1122_3344, 4'hf, 6'h11);
        read_word(32'h0000_0100, 6'h12, captured_data);
        check(captured_data == 32'h1122_3344,
              "retained axi_ram read/write data");
        check(external_aw_count == aw_before && external_ar_count == ar_before,
              "low address never reached external MIG port");

        write_word(DDR_BASE + 32'h120, 32'h1122_3344, 4'b0101, 6'h21);
        check(observed_awaddr == 32'h0000_0120,
              "DDR AXI address rebased to MIG zero");
        check(observed_awid == 6'h21 && observed_wstrb == 4'b0101,
              "DDR AXI ID and WSTRB preserved");
        check(held_awaddr == 32'h0000_0120 && observed_awlen == 0
              && observed_awsize == 3'd2 && observed_awburst == 2'b01,
              "DDR AXI word transaction metadata preserved");
        read_word(DDR_BASE + 32'h120, 6'h22, captured_data);
        check(captured_data == 32'ha522_a544,
              "external MIG read returned partial-write result");
        check(external_aw_count == aw_before + 1
              && external_ar_count == ar_before + 1,
              "high address selected external MIG port once");

        external_calib_error = 1'b1;
        #1;
        check(calib_error, "external MIG calibration error propagated");
        check(!refresh_busy && refresh_count == 0,
              "MIG-owned refresh status has defined external value");

        $display("EXTERNAL MIG BRIDGE: checks=%0d failures=%0d", checks, failures);
        if (failures != 0)
            $fatal(1, "External MIG bridge regression failed");
        $display("ALL EXTERNAL MIG BRIDGE TESTS PASSED");
        $finish;
    end

    initial begin
        #2ms;
        $fatal(1, "External MIG bridge regression timeout");
    end
endmodule
