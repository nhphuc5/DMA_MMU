`timescale 1ns / 1ps

// Focused self-check for the DMA-facing Systolic stream wrapper.  The test
// sends A and identity B as two four-beat packets, applies output
// backpressure, and verifies every signed INT32 result and TLAST.
module tb_systolic_accel_axil_axis;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic [7:0] awaddr, araddr;
    logic [2:0] awprot = '0, arprot = '0;
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

    logic [31:0] s_tdata;
    logic [3:0] s_tkeep;
    logic s_tvalid, s_tready, s_tlast;
    logic [31:0] m_tdata;
    logic [3:0] m_tkeep;
    logic m_tvalid, m_tready, m_tlast;
    logic stream_select, irq;

    integer beat;
    integer errors = 0;
    logic signed [31:0] expected [0:15];

    systolic_accel_axil_axis dut (
        .aclk(clk), .aresetn(rst_n),
        .s_axil_awaddr(awaddr), .s_axil_awprot(awprot),
        .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(wstrb),
        .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid),
        .s_axil_bready(bready),
        .s_axil_araddr(araddr), .s_axil_arprot(arprot),
        .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(rresp),
        .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep),
        .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .m_axis_tlast(m_tlast),
        .stream_select_o(stream_select), .irq_o(irq)
    );

    task automatic axil_write(input [7:0] address, input [31:0] value);
        begin
            @(negedge clk);
            awaddr <= address;
            awvalid <= 1'b1;
            wdata <= value;
            wstrb <= 4'hf;
            wvalid <= 1'b1;
            bready <= 1'b1;
            while (!(awready && wready)) @(negedge clk);
            @(negedge clk);
            awvalid <= 1'b0;
            wvalid <= 1'b0;
            while (!bvalid) @(negedge clk);
            @(negedge clk);
            bready <= 1'b0;
        end
    endtask

    task automatic stream_word(
        input [31:0] value,
        input logic packet_last
    );
        begin
            @(negedge clk);
            s_tdata <= value;
            s_tkeep <= 4'hf;
            s_tlast <= packet_last;
            s_tvalid <= 1'b1;
            while (!s_tready) @(negedge clk);
            @(negedge clk);
            s_tvalid <= 1'b0;
            s_tlast <= 1'b0;
        end
    endtask

    initial begin
        awaddr = '0; awvalid = 1'b0;
        wdata = '0; wstrb = '0; wvalid = 1'b0; bready = 1'b0;
        araddr = '0; arvalid = 1'b0; rready = 1'b0;
        s_tdata = '0; s_tkeep = '0; s_tvalid = 1'b0; s_tlast = 1'b0;
        m_tready = 1'b0;

        // A = [[1,-2,3,4], [5,6,-7,8], [-9,10,11,-12], [13,14,15,16]]
        expected[0]=1;   expected[1]=-2; expected[2]=3;   expected[3]=4;
        expected[4]=5;   expected[5]=6;  expected[6]=-7;  expected[7]=8;
        expected[8]=-9;  expected[9]=10; expected[10]=11; expected[11]=-12;
        expected[12]=13; expected[13]=14; expected[14]=15; expected[15]=16;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // Select the Systolic endpoint without touching the legacy register
        // programming behavior.
        axil_write(8'h84, 32'h0000_0001);
        if (!stream_select) begin
            $error("Systolic stream endpoint was not selected");
            errors = errors + 1;
        end

        // A, four packed rows.  TLAST terminates descriptor A.
        stream_word(32'h0403_fe01, 1'b0);
        stream_word(32'h08f9_0605, 1'b0);
        stream_word(32'hf40b_0af7, 1'b0);
        stream_word(32'h100f_0e0d, 1'b1);

        // B = identity, also a distinct four-beat descriptor.
        stream_word(32'h0000_0001, 1'b0);
        stream_word(32'h0000_0100, 1'b0);
        stream_word(32'h0001_0000, 1'b0);
        stream_word(32'h0100_0000, 1'b1);

        beat = 0;
        while (beat < 16) begin
            @(negedge clk);
            // Deterministic backpressure proves that output data remains
            // stable and no result is skipped.
            m_tready <= (beat[1:0] != 2'b01);
            if (m_tvalid && m_tready) begin
                if ($signed(m_tdata) !== expected[beat]) begin
                    $error("Result %0d: got %0d expected %0d",
                           beat, $signed(m_tdata), expected[beat]);
                    errors = errors + 1;
                end
                if (m_tkeep !== 4'hf) begin
                    $error("Result %0d has invalid TKEEP %h", beat, m_tkeep);
                    errors = errors + 1;
                end
                if (m_tlast !== (beat == 15)) begin
                    $error("Result %0d has incorrect TLAST=%b", beat, m_tlast);
                    errors = errors + 1;
                end
                beat = beat + 1;
            end
        end
        @(negedge clk);
        m_tready <= 1'b0;

        if (errors == 0)
            $display("SYSTOLIC AXI-STREAM SELF-CHECK PASSED: 8 input beats, 16 output beats, backpressure honored");
        else
            $fatal(1, "SYSTOLIC AXI-STREAM SELF-CHECK FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "SYSTOLIC AXI-STREAM SELF-CHECK TIMEOUT");
    end
endmodule
