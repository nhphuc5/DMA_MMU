`timescale 1ns / 1ps

module tb_systolic_accel_axil;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic [7:0] awaddr;
    logic [2:0] awprot;
    logic awvalid, awready;
    logic [31:0] wdata;
    logic [3:0] wstrb;
    logic wvalid, wready;
    logic [1:0] bresp;
    logic bvalid, bready;
    logic [7:0] araddr;
    logic [2:0] arprot;
    logic arvalid, arready;
    logic [31:0] rdata;
    logic [1:0] rresp;
    logic rvalid, rready;
    logic irq;

    integer errors;
    integer i;
    integer signed expected[0:15];
    logic [31:0] value;

    systolic_accel_axil dut (
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
        .irq_o(irq)
    );

    task automatic axil_write(input [7:0] address, input [31:0] data);
        begin
            @(negedge clk);
            awaddr <= address;
            awvalid <= 1'b1;
            wdata <= data;
            wstrb <= 4'hf;
            wvalid <= 1'b1;
            do @(posedge clk); while (!(awready && wready));
            @(negedge clk);
            awvalid <= 1'b0;
            wvalid <= 1'b0;
            bready <= 1'b1;
            do @(posedge clk); while (!bvalid);
            if (bresp != 2'b00) begin
                $display("AXI write response error at 0x%02x", address);
                errors = errors + 1;
            end
            @(negedge clk);
            bready <= 1'b0;
        end
    endtask

    task automatic axil_read(input [7:0] address, output [31:0] data);
        begin
            @(negedge clk);
            araddr <= address;
            arvalid <= 1'b1;
            do @(posedge clk); while (!arready);
            @(negedge clk);
            arvalid <= 1'b0;
            rready <= 1'b1;
            do @(posedge clk); while (!rvalid);
            data = rdata;
            if (rresp != 2'b00) begin
                $display("AXI read response error at 0x%02x", address);
                errors = errors + 1;
            end
            @(negedge clk);
            rready <= 1'b0;
        end
    endtask

    initial begin
        awaddr = 0;
        awprot = 0;
        awvalid = 0;
        wdata = 0;
        wstrb = 0;
        wvalid = 0;
        bready = 0;
        araddr = 0;
        arprot = 0;
        arvalid = 0;
        rready = 0;
        errors = 0;

        // Expected C = A*B in row-major order.
        expected[0]=14; expected[1]=6; expected[2]=13; expected[3]=9;
        expected[4]=0;  expected[5]=6; expected[6]=2;  expected[7]=2;
        expected[8]=0;  expected[9]=2; expected[10]=11; expected[11]=-11;
        expected[12]=15; expected[13]=9; expected[14]=15; expected[15]=9;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("SYSTOLIC AXI SELF-CHECK START");
        axil_read(8'h80, value);
        if (value !== 32'h5359_5354) begin
            $display("FAIL ID: got 0x%08x", value);
            errors = errors + 1;
        end

        // A = [[1,2,3,4],[-1,0,2,1],[5,-2,1,0],[3,3,3,3]]
        axil_write(8'h10, 32'h0403_0201);
        axil_write(8'h14, 32'h0102_00ff);
        axil_write(8'h18, 32'h0001_fe05);
        axil_write(8'h1c, 32'h0303_0303);

        // B = [[1,0,2,-1],[2,1,0,3],[-1,4,1,0],[3,-2,2,1]]
        axil_write(8'h20, 32'hff02_0001);
        axil_write(8'h24, 32'h0300_0102);
        axil_write(8'h28, 32'h0001_04ff);
        axil_write(8'h2c, 32'h0102_fe03);

        axil_write(8'h00, 32'h0000_0001);
        do begin
            axil_read(8'h04, value);
        end while (!value[1]);

        if (!irq) begin
            $display("FAIL: completion IRQ was not asserted");
            errors = errors + 1;
        end

        for (i = 0; i < 16; i = i + 1) begin
            axil_read(8'h40 + 4*i, value);
            if ($signed(value) !== expected[i]) begin
                $display("FAIL C[%0d]: expected %0d, got %0d",
                         i, expected[i], $signed(value));
                errors = errors + 1;
            end else begin
                $display("PASS C[%0d] = %0d", i, $signed(value));
            end
        end

        axil_read(8'h0c, value);
        $display("Systolic hardware cycles = %0d", value);
        axil_write(8'h00, 32'h0000_0002);
        if (errors == 0)
            $display("ALL SYSTOLIC AXI TESTS PASSED");
        else
            $fatal(1, "SYSTOLIC AXI TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "SYSTOLIC AXI TEST TIMEOUT");
    end
endmodule
