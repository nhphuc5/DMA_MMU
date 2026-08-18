`timescale 1ns / 1ps

module tb_axil_to_apb_bridge;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic [7:0] awaddr, araddr;
    logic [2:0] awprot, arprot;
    logic awvalid, awready;
    logic [31:0] wdata;
    logic [3:0] wstrb;
    logic wvalid, wready;
    logic [1:0] bresp;
    logic bvalid, bready;
    logic arvalid, arready;
    logic [31:0] rdata;
    logic [1:0] rresp;
    logic rvalid, rready;

    logic [7:0] paddr;
    logic psel, penable, pwrite;
    logic [31:0] pwdata, prdata;
    logic [3:0] pstrb;
    logic pready, pslverr;

    logic [31:0] apb_mem [0:63];
    logic [2:0] wait_q;
    integer transactions;

    axil_to_apb_bridge #(.ADDR_WIDTH(8), .DATA_WIDTH(32)) dut (
        .clk_i(clk), .rst_ni(rst_n),
        .s_axil_awaddr(awaddr), .s_axil_awprot(awprot),
        .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(wstrb),
        .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid),
        .s_axil_bready(bready), .s_axil_araddr(araddr),
        .s_axil_arprot(arprot), .s_axil_arvalid(arvalid),
        .s_axil_arready(arready), .s_axil_rdata(rdata),
        .s_axil_rresp(rresp), .s_axil_rvalid(rvalid),
        .s_axil_rready(rready), .m_apb_paddr(paddr),
        .m_apb_psel(psel), .m_apb_penable(penable),
        .m_apb_pwrite(pwrite), .m_apb_pwdata(pwdata),
        .m_apb_pstrb(pstrb), .m_apb_prdata(prdata),
        .m_apb_pready(pready), .m_apb_pslverr(pslverr)
    );

    assign pready = psel && penable && wait_q == 0;
    assign pslverr = paddr == 8'hfc;
    assign prdata = pslverr ? 32'h0 : apb_mem[paddr[7:2]];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wait_q <= 0;
            transactions <= 0;
        end else begin
            if (psel && !penable)
                wait_q <= 2;
            else if (psel && penable && wait_q != 0)
                wait_q <= wait_q - 1'b1;

            if (psel && penable && pready) begin
                transactions <= transactions + 1;
                if (pwrite && !pslverr) begin
                    for (int byte_index = 0; byte_index < 4; byte_index++)
                        if (pstrb[byte_index])
                            apb_mem[paddr[7:2]][byte_index*8 +: 8]
                                <= pwdata[byte_index*8 +: 8];
                end
            end

            if (penable && !psel)
                $fatal(1, "APB PENABLE asserted without PSEL");
        end
    end

    task automatic send_aw(input logic [7:0] address);
        begin
            awaddr = address;
            awvalid = 1'b1;
            do @(posedge clk); while (!awready);
            awvalid = 1'b0;
        end
    endtask

    task automatic send_w(input logic [31:0] data,
                          input logic [3:0] strobe);
        begin
            wdata = data;
            wstrb = strobe;
            wvalid = 1'b1;
            do @(posedge clk); while (!wready);
            wvalid = 1'b0;
        end
    endtask

    task automatic finish_write(input logic [1:0] expected_resp);
        begin
            bready = 1'b1;
            do @(posedge clk); while (!bvalid);
            if (bresp !== expected_resp)
                $fatal(1, "BRESP=%b expected=%b", bresp, expected_resp);
            @(posedge clk);
            bready = 1'b0;
        end
    endtask

    task automatic write_aw_first(input logic [7:0] address,
                                  input logic [31:0] data,
                                  input logic [3:0] strobe,
                                  input logic [1:0] expected_resp);
        begin
            send_aw(address);
            repeat (3) @(posedge clk);
            send_w(data, strobe);
            finish_write(expected_resp);
        end
    endtask

    task automatic write_w_first(input logic [7:0] address,
                                 input logic [31:0] data,
                                 input logic [3:0] strobe,
                                 input logic [1:0] expected_resp);
        begin
            send_w(data, strobe);
            repeat (3) @(posedge clk);
            send_aw(address);
            finish_write(expected_resp);
        end
    endtask

    task automatic write_together(input logic [7:0] address,
                                  input logic [31:0] data,
                                  input logic [3:0] strobe);
        fork
            send_aw(address);
            send_w(data, strobe);
        join
        finish_write(2'b00);
    endtask

    task automatic read_axil(input logic [7:0] address,
                             input logic [31:0] expected_data,
                             input logic [1:0] expected_resp);
        begin
            araddr = address;
            arvalid = 1'b1;
            rready = 1'b1;
            do @(posedge clk); while (!arready);
            arvalid = 1'b0;
            do @(posedge clk); while (!rvalid);
            if (rresp !== expected_resp)
                $fatal(1, "RRESP=%b expected=%b", rresp, expected_resp);
            if (expected_resp == 2'b00 && rdata !== expected_data)
                $fatal(1, "RDATA=%08x expected=%08x", rdata, expected_data);
            @(posedge clk);
            rready = 1'b0;
        end
    endtask

    initial begin
        awaddr = 0; awprot = 0; awvalid = 0;
        wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
        araddr = 0; arprot = 0; arvalid = 0; rready = 0;
        for (int index = 0; index < 64; index++)
            apb_mem[index] = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        write_aw_first(8'h10, 32'h1122_3344, 4'b1111, 2'b00);
        write_w_first(8'h14, 32'haabb_ccdd, 4'b1111, 2'b00);
        write_together(8'h18, 32'h5566_7788, 4'b0101);
        read_axil(8'h10, 32'h1122_3344, 2'b00);
        read_axil(8'h14, 32'haabb_ccdd, 2'b00);
        read_axil(8'h18, 32'h0066_0088, 2'b00);
        write_aw_first(8'hfc, 32'hdead_beef, 4'b1111, 2'b10);
        read_axil(8'hfc, 32'h0, 2'b10);

        if (transactions != 8)
            $fatal(1, "APB transaction count=%0d expected=8", transactions);
        $display("AXI-LITE TO APB BRIDGE TEST PASSED: AW/W ordering, wait states, WSTRB, PSLVERR");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "AXI-Lite to APB bridge timeout");
    end
endmodule
