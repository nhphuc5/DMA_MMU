// Testbench cho Vivado Simulation (Behavioral)
// Vivado: Add Sources -> Add ecg_tb_vivado.v, set as top for simulation
`timescale 1ns/1ps

module ecg_tb_vivado;

reg        clk, rst_n, start;
reg  [7:0] ecg_wdata;
reg  [6:0] ecg_waddr;
reg        ecg_we;
wire [1:0] pred_class;
wire       done;

ecg_top #(
    .DATA_WIDTH(8), .OUTPUT_DATA_WIDTH(16),
    .ARRAY_SIZE(4), .INPUT_LEN(128), .NUM_CLASSES(4)
) dut (
    .clk(clk), .rst_n(rst_n), .start(start),
    .ecg_wdata(ecg_wdata), .ecg_waddr(ecg_waddr), .ecg_we(ecg_we),
    .pred_class(pred_class), .done(done)
);

always #5 clk = ~clk;   // 100 MHz

integer s, cyc;

initial begin
    clk = 0; rst_n = 0; start = 0;
    ecg_we = 0; ecg_waddr = 0; ecg_wdata = 0;

    // Reset
    repeat(4) @(posedge clk);
    @(negedge clk); rst_n = 1;

    // Load synthetic ECG
    for (s = 0; s < 128; s = s + 1) begin
        @(negedge clk);
        ecg_waddr = s[6:0];
        ecg_wdata = (s % 32 == 30) ? 8'd120 :
                    (s % 32 == 29 || s % 32 == 31) ? 8'd40 : 8'd5;
        ecg_we = 1'b1;
    end
    @(negedge clk); ecg_we = 1'b0;

    // Start inference
    @(negedge clk); start = 1'b1;
    @(negedge clk); start = 1'b0;

    // Wait done
    cyc = 0;
    while (!done && cyc < 50000) begin
        @(posedge clk); cyc = cyc + 1;
    end

    if (cyc >= 50000)
        $display("TIMEOUT");
    else begin
        $display("Done at cycle %0d, class=%0d", cyc, pred_class);
        case (pred_class)
            0: $display("=> Normal (N)");
            1: $display("=> Supraventricular (S)");
            2: $display("=> Ventricular (V)");
            3: $display("=> Unclassifiable (Q)");
        endcase
    end
    $finish;
end

endmodule