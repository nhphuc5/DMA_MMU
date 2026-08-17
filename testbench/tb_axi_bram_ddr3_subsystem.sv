`timescale 1ns / 1ps

// Integration regression for the two-target memory map. Detailed AXI corner
// cases are covered by tb_axi_ddr3_controller; this bench proves that the
// original AXI RAM and the DDR target coexist behind the decoder.
module tb_axi_bram_ddr3_subsystem;
    localparam int ID_WIDTH = 6;
    localparam logic [31:0] DDR_BASE = 32'h8000_0000;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #3.333 clk = ~clk;

    logic [ID_WIDTH-1:0] awid;
    logic [31:0] awaddr;
    logic [7:0] awlen;
    logic [2:0] awsize;
    logic [1:0] awburst;
    logic awvalid;
    wire awready;
    logic [31:0] wdata;
    logic [3:0] wstrb;
    logic wlast;
    logic wvalid;
    wire wready;
    wire [ID_WIDTH-1:0] bid;
    wire [1:0] bresp;
    wire bvalid;
    logic bready;
    logic [ID_WIDTH-1:0] arid;
    logic [31:0] araddr;
    logic [7:0] arlen;
    logic [2:0] arsize;
    logic [1:0] arburst;
    logic arvalid;
    wire arready;
    wire [ID_WIDTH-1:0] rid;
    wire [31:0] rdata;
    wire [1:0] rresp;
    wire rlast;
    wire rvalid;
    logic rready;

    wire init_done, calib_done, calib_error, refresh_busy;
    wire [31:0] refresh_count;
    wire dfi_cmd_valid, dfi_cmd_ready;
    wire [2:0] dfi_cmd, dfi_bank;
    wire [15:0] dfi_addr;
    wire [31:0] dfi_wrdata, dfi_rddata;
    wire [3:0] dfi_wrmask;
    wire dfi_rddata_valid, dfi_error;
    wire phy_calib_start, phy_calib_done, phy_calib_error;
    wire [31:0] act_count, pre_count, read_count, write_count;
    wire [31:0] model_refresh_count;
    wire model_protocol_error;

    integer checks = 0;
    integer failures = 0;

    axi_bram_ddr3_subsystem #(
        .AXI_ADDR_WIDTH(32), .AXI_DATA_WIDTH(32),
        .AXI_ID_WIDTH(ID_WIDTH), .BRAM_ADDR_WIDTH(16),
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
        .ddr_init_done_o(init_done), .ddr_calib_done_o(calib_done),
        .ddr_calib_error_o(calib_error), .ddr_refresh_busy_o(refresh_busy),
        .ddr_refresh_count_o(refresh_count), .dfi_cmd_valid_o(dfi_cmd_valid),
        .dfi_cmd_ready_i(dfi_cmd_ready), .dfi_cmd_o(dfi_cmd),
        .dfi_bank_o(dfi_bank), .dfi_addr_o(dfi_addr),
        .dfi_wrdata_o(dfi_wrdata), .dfi_wrmask_o(dfi_wrmask),
        .dfi_rddata_valid_i(dfi_rddata_valid), .dfi_rddata_i(dfi_rddata),
        .dfi_error_i(dfi_error), .phy_calib_start_o(phy_calib_start),
        .phy_calib_done_i(phy_calib_done),
        .phy_calib_error_i(phy_calib_error)
    );

    ddr3_dfi_memory_model #(
        .MODEL_ADDR_WIDTH(16), .READ_LATENCY(3), .CALIB_CYCLES(4)
    ) memory_model (
        .clk_i(clk), .rst_ni(!rst), .stall_i(1'b0),
        .inject_error_i(1'b0), .dfi_cmd_valid_i(dfi_cmd_valid),
        .dfi_cmd_ready_o(dfi_cmd_ready), .dfi_cmd_i(dfi_cmd),
        .dfi_bank_i(dfi_bank), .dfi_addr_i(dfi_addr),
        .dfi_wrdata_i(dfi_wrdata), .dfi_wrmask_i(dfi_wrmask),
        .dfi_rddata_valid_o(dfi_rddata_valid), .dfi_rddata_o(dfi_rddata),
        .dfi_error_o(dfi_error), .phy_calib_start_i(phy_calib_start),
        .phy_calib_done_o(phy_calib_done),
        .phy_calib_error_o(phy_calib_error), .act_count_o(act_count),
        .pre_count_o(pre_count), .read_count_o(read_count),
        .write_count_o(write_count), .refresh_count_o(model_refresh_count),
        .protocol_error_o(model_protocol_error)
    );

    task automatic check(input logic condition, input string name);
        begin
            checks = checks + 1;
            if (condition) $display("PASS %s", name);
            else begin failures = failures + 1; $display("FAIL %s", name); end
        end
    endtask

    task automatic write_word(
        input logic [31:0] addr, input logic [31:0] data,
        input logic [ID_WIDTH-1:0] id,
        output logic [1:0] response, output logic [ID_WIDTH-1:0] response_id
    );
        begin
            @(negedge clk);
            awaddr=addr; awid=id; awlen=0; awsize=2; awburst=2'b01;
            awvalid=1;
            do @(posedge clk); while (!awready);
            @(negedge clk);
            awvalid=0;
            wdata=data; wstrb=4'hf; wlast=1; wvalid=1;
            do @(posedge clk); while (!wready);
            @(negedge clk);
            wvalid=0; wlast=0;
            do @(negedge clk); while (!bvalid);
            response=bresp; response_id=bid;
            @(negedge clk);
        end
    endtask

    task automatic read_word(
        input logic [31:0] addr, input logic [ID_WIDTH-1:0] id,
        output logic [31:0] data, output logic [1:0] response,
        output logic [ID_WIDTH-1:0] response_id
    );
        begin
            @(negedge clk);
            araddr=addr; arid=id; arlen=0; arsize=2; arburst=2'b01;
            arvalid=1;
            do @(posedge clk); while (!arready);
            @(negedge clk);
            arvalid=0;
            do @(negedge clk); while (!rvalid);
            data=rdata; response=rresp; response_id=rid;
            check(rlast, "integration read returned RLAST");
            @(negedge clk);
        end
    endtask

    logic [1:0] captured_resp;
    logic [ID_WIDTH-1:0] captured_id;
    logic [31:0] captured_data;
    integer ddr_writes_before;

    initial begin
        awid=0; awaddr=0; awlen=0; awsize=2; awburst=1; awvalid=0;
        wdata=0; wstrb=0; wlast=0; wvalid=0; bready=1;
        arid=0; araddr=0; arlen=0; arsize=2; arburst=1; arvalid=0; rready=1;
        repeat (8) @(negedge clk);
        rst=0;
        wait (calib_done || calib_error);
        check(init_done && calib_done && !calib_error,
              "subsystem DDR initialized and calibrated");

        ddr_writes_before = write_count;
        write_word(32'h0000_0100, 32'h1122_3344, 6'h11,
                   captured_resp, captured_id);
        check(captured_resp == 2'b00 && captured_id == 6'h11,
              "low address write reached retained AXI RAM");
        read_word(32'h0000_0100, 6'h12, captured_data,
                  captured_resp, captured_id);
        check(captured_resp == 2'b00 && captured_id == 6'h12
              && captured_data == 32'h1122_3344,
              "low address read returned AXI RAM data");
        check(write_count == ddr_writes_before,
              "AXI RAM access did not issue a DDR command");

        write_word(DDR_BASE+32'h100, 32'ha5a5_5a5a, 6'h21,
                   captured_resp, captured_id);
        check(captured_resp == 2'b00 && captured_id == 6'h21,
              "high address write reached DDR controller");
        read_word(DDR_BASE+32'h100, 6'h22, captured_data,
                  captured_resp, captured_id);
        check(captured_resp == 2'b00 && captured_id == 6'h22
              && captured_data == 32'ha5a5_5a5a,
              "high address read returned DDR model data");
        check(write_count > ddr_writes_before && read_count != 0,
              "DDR target emitted read and write commands");
        check(!model_protocol_error, "integration produced legal DFI sequence");

        $display("BRAM+DDR SUBSYSTEM: checks=%0d failures=%0d", checks, failures);
        if (failures != 0) $fatal(1, "BRAM+DDR integration regression failed");
        $display("ALL BRAM+DDR SUBSYSTEM TESTS PASSED");
        $finish;
    end

    initial begin
        #2ms;
        $fatal(1, "BRAM+DDR subsystem regression timeout");
    end

    logic _unused;
    assign _unused = &{1'b0, refresh_busy, refresh_count,
                       model_refresh_count, act_count, pre_count};
endmodule
