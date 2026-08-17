`timescale 1ns / 1ps

module tb_axi_ddr3_controller;
    localparam int ADDR_WIDTH = 32;
    localparam int DATA_WIDTH = 32;
    localparam int ID_WIDTH = 6;
    localparam logic [31:0] DDR_BASE = 32'h8000_0000;
    localparam logic [31:0] DDR_SIZE = 32'h0004_0000;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #3.333 clk = ~clk; // 150 MHz nominal

    logic [ID_WIDTH-1:0] awid;
    logic [31:0] awaddr;
    logic [7:0] awlen;
    logic [2:0] awsize;
    logic [1:0] awburst;
    logic awlock;
    logic [3:0] awcache;
    logic [2:0] awprot;
    logic [3:0] awqos;
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
    logic arlock;
    logic [3:0] arcache;
    logic [2:0] arprot;
    logic [3:0] arqos;
    logic arvalid;
    wire arready;
    wire [ID_WIDTH-1:0] rid;
    wire [31:0] rdata;
    wire [1:0] rresp;
    wire rlast;
    wire rvalid;
    logic rready;

    wire init_done;
    wire calib_done;
    wire calib_error;
    wire refresh_busy;
    wire [31:0] controller_refresh_count;
    wire dfi_cmd_valid;
    wire dfi_cmd_ready;
    wire [2:0] dfi_cmd;
    wire [2:0] dfi_bank;
    wire [15:0] dfi_addr;
    wire [31:0] dfi_wrdata;
    wire [3:0] dfi_wrmask;
    wire dfi_rddata_valid;
    wire [31:0] dfi_rddata;
    wire dfi_error;
    wire phy_calib_start;
    wire phy_calib_done;
    wire phy_calib_error;

    logic model_stall;
    logic inject_error;
    wire [31:0] act_count;
    wire [31:0] pre_count;
    wire [31:0] read_count;
    wire [31:0] write_count;
    wire [31:0] model_refresh_count;
    wire model_protocol_error;

    integer checks = 0;
    integer failures = 0;

    axi_ddr3_controller #(
        .AXI_ADDR_WIDTH(ADDR_WIDTH),
        .AXI_DATA_WIDTH(DATA_WIDTH),
        .AXI_ID_WIDTH(ID_WIDTH),
        .DDR_BASE_ADDR(DDR_BASE),
        .DDR_SIZE_BYTES(DDR_SIZE),
        .RESET_CYCLES(8),
        .REFRESH_CYCLES(80),
        .CAL_TIMEOUT(128)
    ) dut (
        .aclk(clk), .aresetn(rst_n),
        .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen),
        .s_axi_awsize(awsize), .s_axi_awburst(awburst),
        .s_axi_awlock(awlock), .s_axi_awcache(awcache),
        .s_axi_awprot(awprot), .s_axi_awqos(awqos),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bid(bid), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid),
        .s_axi_bready(bready),
        .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(arlen),
        .s_axi_arsize(arsize), .s_axi_arburst(arburst),
        .s_axi_arlock(arlock), .s_axi_arcache(arcache),
        .s_axi_arprot(arprot), .s_axi_arqos(arqos),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rlast(rlast), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .init_done_o(init_done), .calib_done_o(calib_done),
        .calib_error_o(calib_error), .refresh_busy_o(refresh_busy),
        .refresh_count_o(controller_refresh_count),
        .dfi_cmd_valid_o(dfi_cmd_valid), .dfi_cmd_ready_i(dfi_cmd_ready),
        .dfi_cmd_o(dfi_cmd), .dfi_bank_o(dfi_bank), .dfi_addr_o(dfi_addr),
        .dfi_wrdata_o(dfi_wrdata), .dfi_wrmask_o(dfi_wrmask),
        .dfi_rddata_valid_i(dfi_rddata_valid), .dfi_rddata_i(dfi_rddata),
        .dfi_error_i(dfi_error), .phy_calib_start_o(phy_calib_start),
        .phy_calib_done_i(phy_calib_done),
        .phy_calib_error_i(phy_calib_error)
    );

    ddr3_dfi_memory_model #(
        .MODEL_ADDR_WIDTH(16), .READ_LATENCY(3), .CALIB_CYCLES(4)
    ) memory_model (
        .clk_i(clk), .rst_ni(rst_n), .stall_i(model_stall),
        .inject_error_i(inject_error),
        .dfi_cmd_valid_i(dfi_cmd_valid), .dfi_cmd_ready_o(dfi_cmd_ready),
        .dfi_cmd_i(dfi_cmd), .dfi_bank_i(dfi_bank), .dfi_addr_i(dfi_addr),
        .dfi_wrdata_i(dfi_wrdata), .dfi_wrmask_i(dfi_wrmask),
        .dfi_rddata_valid_o(dfi_rddata_valid), .dfi_rddata_o(dfi_rddata),
        .dfi_error_o(dfi_error), .phy_calib_start_i(phy_calib_start),
        .phy_calib_done_o(phy_calib_done),
        .phy_calib_error_o(phy_calib_error),
        .act_count_o(act_count), .pre_count_o(pre_count),
        .read_count_o(read_count), .write_count_o(write_count),
        .refresh_count_o(model_refresh_count),
        .protocol_error_o(model_protocol_error)
    );

    task automatic check(input logic condition, input string name);
        begin
            checks = checks + 1;
            if (condition)
                $display("PASS %s", name);
            else begin
                failures = failures + 1;
                $display("FAIL %s", name);
            end
        end
    endtask

    task automatic drive_aw(
        input logic [31:0] addr,
        input logic [7:0] len,
        input logic [2:0] size,
        input logic [1:0] burst,
        input logic [ID_WIDTH-1:0] id
    );
        integer timeout;
        begin
            @(negedge clk);
            awaddr = addr; awlen = len; awsize = size; awburst = burst;
            awid = id; awvalid = 1'b1;
            #1;
            timeout = 0;
            while (!awready && timeout < 2000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(timeout < 2000, "AW handshake completed");
            @(negedge clk);
            awvalid = 1'b0;
        end
    endtask

    // last_mode: 0=correct, 1=early on first beat, 2=omit final WLAST.
    task automatic write_generated(
        input logic [31:0] addr,
        input logic [7:0] len,
        input logic [2:0] size,
        input logic [1:0] burst,
        input logic [ID_WIDTH-1:0] id,
        input logic [31:0] seed,
        input logic [3:0] strb,
        input integer last_mode,
        input logic [1:0] expected_resp,
        input integer response_stall
    );
        integer beat;
        integer timeout;
        begin
            drive_aw(addr, len, size, burst, id);
            beat = 0;
            while (beat <= len) begin
                @(negedge clk);
                wdata = seed + beat;
                wstrb = strb;
                wlast = last_mode == 1 ? beat == 0
                      : last_mode == 2 ? 1'b0 : beat == len;
                wvalid = 1'b1;
                #1;
                timeout = 0;
                while (!wready && timeout < 4000) begin
                    @(negedge clk); timeout = timeout + 1;
                end
                check(timeout < 4000, "W beat handshake completed");
                @(negedge clk);
                wvalid = 1'b0; wlast = 1'b0;
                if (last_mode == 1)
                    beat = len + 1;
                else
                    beat = beat + 1;
            end
            repeat (response_stall) @(negedge clk);
            bready = 1'b1;
            #1;
            timeout = 0;
            while (!bvalid && timeout < 4000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(timeout < 4000, "B response completed");
            check(bresp == expected_resp, "B response code");
            check(bid == id, "B response ID preserved");
            @(negedge clk); bready = 1'b0;
        end
    endtask

    task automatic drive_ar(
        input logic [31:0] addr,
        input logic [7:0] len,
        input logic [2:0] size,
        input logic [1:0] burst,
        input logic [ID_WIDTH-1:0] id
    );
        integer timeout;
        begin
            @(negedge clk);
            araddr = addr; arlen = len; arsize = size; arburst = burst;
            arid = id; arvalid = 1'b1;
            #1;
            timeout = 0;
            while (!arready && timeout < 2000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(timeout < 2000, "AR handshake completed");
            @(negedge clk); arvalid = 1'b0;
        end
    endtask

    task automatic read_generated(
        input logic [31:0] addr,
        input logic [7:0] len,
        input logic [2:0] size,
        input logic [1:0] burst,
        input logic [ID_WIDTH-1:0] id,
        input logic [31:0] seed,
        input logic [1:0] expected_resp,
        input integer response_stall,
        input logic check_payload
    );
        integer beat;
        integer timeout;
        begin
            drive_ar(addr, len, size, burst, id);
            for (beat = 0; beat <= len; beat = beat+1) begin
                repeat (response_stall) @(negedge clk);
                rready = 1'b1;
                #1;
                timeout = 0;
                while (!rvalid && timeout < 4000) begin
                    @(negedge clk); timeout = timeout + 1;
                end
                check(timeout < 4000, "R beat completed");
                check(rresp == expected_resp, "R response code");
                check(rid == id, "R response ID preserved");
                check(rlast == (beat == len), "RLAST position");
                if (check_payload)
                    check(rdata == seed + beat, "RDATA matched written burst");
                @(negedge clk); rready = 1'b0;
            end
        end
    endtask

    task automatic read_single_value(
        input logic [31:0] addr,
        input logic [31:0] expected,
        input logic [1:0] expected_resp,
        input string name
    );
        integer timeout;
        begin
            drive_ar(addr, 0, 3'd2, 2'b01, 6'h2a);
            rready = 1'b1;
            #1;
            timeout = 0;
            while (!rvalid && timeout < 4000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(timeout < 4000, {name, " response"});
            check(rresp == expected_resp, {name, " response code"});
            if (expected_resp == 0)
                check(rdata == expected, {name, " data"});
            @(negedge clk); rready = 1'b0;
        end
    endtask

    initial begin
        awid='0; awaddr='0; awlen='0; awsize=3'd2; awburst=2'b01;
        awlock=0; awcache=0; awprot=0; awqos=0; awvalid=0;
        wdata=0; wstrb=0; wlast=0; wvalid=0; bready=0;
        arid='0; araddr='0; arlen='0; arsize=3'd2; arburst=2'b01;
        arlock=0; arcache=0; arprot=0; arqos=0; arvalid=0; rready=0;
        model_stall=0; inject_error=0;

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        wait (calib_done || calib_error);
        check(init_done, "DDR initialization sequence completed");
        check(calib_done && !calib_error, "PHY calibration completed");
        check(!model_protocol_error, "Initialization command ordering legal");

        write_generated(DDR_BASE+32'h100, 0, 2, 2'b01, 6'h01,
                        32'h1122_3344, 4'hf, 0, 0, 0);
        read_single_value(DDR_BASE+32'h100, 32'h1122_3344, 0,
                          "single write/read");

        write_generated(DDR_BASE+32'h200, 8'd15, 2, 2'b01, 6'h02,
                        32'ha500_0000, 4'hf, 0, 0, 3);
        read_generated(DDR_BASE+32'h200, 8'd15, 2, 2'b01, 6'h03,
                       32'ha500_0000, 0, 2, 1'b1);

        // Byte-enable behavior: only byte lanes 0 and 2 change.
        write_generated(DDR_BASE+32'h300, 0, 2, 2'b01, 6'h04,
                        32'haabb_ccdd, 4'hf, 0, 0, 0);
        write_generated(DDR_BASE+32'h300, 0, 2, 2'b01, 6'h05,
                        32'h1122_3344, 4'b0101, 0, 0, 0);
        read_single_value(DDR_BASE+32'h300, 32'haa22_cc44, 0,
                          "partial WSTRB");

        // Narrow aligned halfword transaction into upper lanes.
        write_generated(DDR_BASE+32'h302, 0, 1, 2'b01, 6'h06,
                        32'h5566_0000, 4'b1100, 0, 0, 0);
        read_single_value(DDR_BASE+32'h300, 32'h5566_cc44, 0,
                          "narrow halfword");

        // FIXED burst repeatedly updates one location.
        write_generated(DDR_BASE+32'h400, 3, 2, 2'b00, 6'h07,
                        32'hf100_0000, 4'hf, 0, 0, 0);
        read_single_value(DDR_BASE+32'h400, 32'hf100_0003, 0,
                          "FIXED burst");

        // Legal four-beat WRAP: 0x42c, 0x420, 0x424, 0x428.
        write_generated(DDR_BASE+32'h42c, 3, 2, 2'b10, 6'h08,
                        32'hc200_0000, 4'hf, 0, 0, 0);
        read_generated(DDR_BASE+32'h42c, 3, 2, 2'b10, 6'h09,
                       32'hc200_0000, 0, 1, 1'b1);

        // DFI command-ready backpressure must hold the AXI request/data.
        model_stall = 1'b1;
        fork
            begin
                repeat (12) @(negedge clk);
                model_stall = 1'b0;
            end
            write_generated(DDR_BASE+32'h500, 0, 2, 2'b01, 6'h0a,
                            32'hdead_beef, 4'hf, 0, 0, 4);
        join
        read_single_value(DDR_BASE+32'h500, 32'hdead_beef, 0,
                          "DFI backpressure");

        // AXI decode/protocol errors never reach the DDR command stream.
        write_generated(32'h7000_0000, 0, 2, 2'b01, 6'h10,
                        0, 4'hf, 0, 2'b11, 0);
        read_generated(DDR_BASE+DDR_SIZE, 0, 2, 2'b01, 6'h11,
                       0, 2'b11, 0, 1'b0);
        write_generated(DDR_BASE+32'h600, 0, 3, 2'b01, 6'h12,
                        0, 4'hf, 0, 2'b10, 0);
        read_generated(DDR_BASE+32'h602, 0, 2, 2'b01, 6'h13,
                       0, 2'b10, 0, 1'b0);
        write_generated(DDR_BASE+32'h700, 2, 2, 2'b10, 6'h14,
                        0, 4'hf, 0, 2'b10, 0);
        read_generated(DDR_BASE+32'h700, 0, 2, 2'b11, 6'h15,
                       0, 2'b10, 0, 1'b0);
        write_generated(DDR_BASE+32'hffc, 1, 2, 2'b01, 6'h16,
                        0, 4'hf, 0, 2'b10, 0);

        // WLAST protocol violations return SLVERR without hanging the slave.
        write_generated(DDR_BASE+32'h800, 3, 2, 2'b01, 6'h17,
                        32'he100_0000, 4'hf, 1, 2'b10, 0);
        write_generated(DDR_BASE+32'h840, 1, 2, 2'b01, 6'h18,
                        32'he200_0000, 4'hf, 2, 2'b10, 0);

        // Backend errors propagate to AXI SLVERR.
        inject_error = 1'b1;
        write_generated(DDR_BASE+32'h900, 0, 2, 2'b01, 6'h19,
                        32'hbad0_bad0, 4'hf, 0, 2'b10, 0);
        read_generated(DDR_BASE+32'h100, 0, 2, 2'b01, 6'h1a,
                       0, 2'b10, 0, 1'b0);
        inject_error = 1'b0;

        // Open-row hit and row-conflict paths both execute.
        begin : row_policy_test
            integer act_before;
            integer pre_before;
            integer refresh_before;
            // Align the observation window immediately after a refresh so
            // the mandatory periodic PRECHARGE-ALL cannot be mistaken for a
            // failure of the open-row policy.
            refresh_before = controller_refresh_count;
            while (controller_refresh_count == refresh_before)
                @(negedge clk);
            act_before = act_count;
            pre_before = pre_count;
            write_generated(DDR_BASE+32'h1000, 0, 2, 2'b01, 6'h20,
                            32'h0101_0101, 4'hf, 0, 0, 0);
            write_generated(DDR_BASE+32'h1004, 0, 2, 2'b01, 6'h21,
                            32'h0202_0202, 4'hf, 0, 0, 0);
            check(act_count-act_before <= 1, "open-row hit avoided extra ACT");
            write_generated(DDR_BASE+32'h9000, 0, 2, 2'b01, 6'h22,
                            32'h0303_0303, 4'hf, 0, 0, 0);
            check(pre_count > pre_before, "row conflict issued PRECHARGE");
        end

        // Controller and model must observe periodic refresh with all banks
        // precharged; traffic resumes afterwards.
        begin : refresh_test
            integer refresh_before;
            refresh_before = controller_refresh_count;
            while (controller_refresh_count == refresh_before)
                @(negedge clk);
            check(model_refresh_count != 0, "periodic refresh reached memory");
            check(!model_protocol_error, "refresh issued with banks closed");
            write_generated(DDR_BASE+32'ha00, 0, 2, 2'b01, 6'h23,
                            32'h4455_6677, 4'hf, 0, 0, 0);
            read_single_value(DDR_BASE+32'ha00, 32'h4455_6677, 0,
                              "traffic after refresh");
        end

        check(write_count != 0 && read_count != 0,
              "DFI read/write commands exercised");

        // Reset while a request is blocked must clear every AXI response and
        // rerun initialization/calibration without stale data handshakes.
        model_stall = 1'b1;
        drive_aw(DDR_BASE+32'hb00, 0, 2, 2'b01, 6'h24);
        @(negedge clk); wdata=32'h1234_5678; wstrb=4'hf;
        wlast=1; wvalid=1;
        repeat (4) @(negedge clk);
        rst_n=0;
        repeat (4) @(negedge clk);
        check(!bvalid && !rvalid, "reset cleared AXI responses");
        wvalid=0; wlast=0; model_stall=0; rst_n=1;
        wait (calib_done || calib_error);
        check(calib_done && !calib_error, "recalibration after reset");

        check(!model_protocol_error, "no DFI protocol errors");

        $display("DDR3 AXI CONTROLLER: checks=%0d failures=%0d", checks, failures);
        if (failures != 0)
            $fatal(1, "DDR3 AXI controller regression failed");
        $display("ALL DDR3 AXI CONTROLLER TESTS PASSED");
        $finish;
    end

    initial begin
        #20ms;
        $fatal(1, "DDR3 AXI controller regression timeout");
    end

endmodule
