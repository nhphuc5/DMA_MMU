`timescale 1ns / 1ps

// End-to-end proof for PicoRV32 -> AXI4-Lite -> systolic accelerator -> UART.
// The CPU executes the real C++ firmware from AXI RAM.  PASS is accepted only
// after the firmware has read and compared all sixteen hardware results.
module tb_soc_systolic_demo;
    localparam real CLOCK_PERIOD_NS = 6.667;
    localparam integer UART_DIVIDER = 4;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic uart_rx = 1'b1;
    wire uart_tx;
    wire cpu_trap;
    wire dma_irq;
    wire uart_irq;
    wire [7:0] tx_byte;
    wire tx_byte_valid;

    integer log_fd;
    integer pass_index = 0;
    integer emitted_bytes = 0;
    integer element;
    logic finished = 1'b0;
    localparam integer PASS_LENGTH = 13;
    reg [7:0] pass_text [0:PASS_LENGTH-1];

    always #(CLOCK_PERIOD_NS/2.0) clk = ~clk;

    dma_mmu_picorv32_soc #(
        .UART_DEFAULT_DIV(UART_DIVIDER),
        .MEM_INIT_FILE("D:/DMA_MMU-main(1)/firmware/build/systolic_demo/soc_systolic_demo.hex")
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .uart_rx_i(uart_rx),
        .uart_tx_o(uart_tx),
        .cpu_trap_o(cpu_trap),
        .dma_irq_o(dma_irq),
        .uart_irq_o(uart_irq),
        .uart_tx_byte_o(tx_byte),
        .uart_tx_byte_valid_o(tx_byte_valid)
    );

    initial begin
        pass_text[0]  = "S"; pass_text[1]  = "Y";
        pass_text[2]  = "S"; pass_text[3]  = "T";
        pass_text[4]  = "O"; pass_text[5]  = "L";
        pass_text[6]  = "I"; pass_text[7]  = "C";
        pass_text[8]  = " "; pass_text[9]  = "P";
        pass_text[10] = "A"; pass_text[11] = "S";
        pass_text[12] = "S";
        log_fd = $fopen("D:/DMA_MMU-main(1)/reports/systolic_soc_test.log", "w");
        repeat (12) @(posedge clk);
        rst_n <= 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n && cpu_trap && !finished) begin
            $error("PicoRV32 entered trap state");
            if (log_fd != 0) $fclose(log_fd);
            $finish;
        end

        if (tx_byte_valid && !finished) begin
            emitted_bytes = emitted_bytes + 1;
            $write("%c", tx_byte);
            if (log_fd != 0) $fwrite(log_fd, "%c", tx_byte);

            if (tx_byte == pass_text[pass_index]) begin
                pass_index = pass_index + 1;
            end else begin
                pass_index = (tx_byte == pass_text[0]) ? 1 : 0;
            end

            if (pass_index == PASS_LENGTH) begin
                // Independently inspect the values that the accelerator made
                // available to firmware over AXI4-Lite.
                for (element = 0; element < 16; element = element + 1) begin
                    case (element)
                        0:  if ($signed(dut.systolic_accel_inst.matrix_c_flat[element*32 +: 32]) !== 14) $fatal;
                        1:  if ($signed(dut.systolic_accel_inst.matrix_c_flat[element*32 +: 32]) !== 6)  $fatal;
                        2:  if ($signed(dut.systolic_accel_inst.matrix_c_flat[element*32 +: 32]) !== 13) $fatal;
                        3:  if ($signed(dut.systolic_accel_inst.matrix_c_flat[element*32 +: 32]) !== 9)  $fatal;
                        4:  if ($signed(dut.systolic_accel_inst.matrix_c_flat[element*32 +: 32]) !== 0)  $fatal;
                        5:  if ($signed(dut.systolic_accel_inst.matrix_c_flat[element*32 +: 32]) !== 6)  $fatal;
                        6:  if ($signed(dut.systolic_accel_inst.matrix_c_flat[element*32 +: 32]) !== 2)  $fatal;
                        7:  if ($signed(dut.systolic_accel_inst.matrix_c_flat[element*32 +: 32]) !== 2)  $fatal;
                        8:  if ($signed(dut.systolic_accel_inst.matrix_c_flat[element*32 +: 32]) !== 0)  $fatal;
                        9:  if ($signed(dut.systolic_accel_inst.matrix_c_flat[element*32 +: 32]) !== 2)  $fatal;
                        10: if ($signed(dut.systolic_accel_inst.matrix_c_flat[element*32 +: 32]) !== 11) $fatal;
                        11: if ($signed(dut.systolic_accel_inst.matrix_c_flat[element*32 +: 32]) !== -11) $fatal;
                        12: if ($signed(dut.systolic_accel_inst.matrix_c_flat[element*32 +: 32]) !== 15) $fatal;
                        13: if ($signed(dut.systolic_accel_inst.matrix_c_flat[element*32 +: 32]) !== 9)  $fatal;
                        14: if ($signed(dut.systolic_accel_inst.matrix_c_flat[element*32 +: 32]) !== 15) $fatal;
                        15: if ($signed(dut.systolic_accel_inst.matrix_c_flat[element*32 +: 32]) !== 9)  $fatal;
                    endcase
                end
                finished = 1'b1;
                $display("\nALL PICORV32/SYSTOLIC SYSTEM TESTS PASSED (%0d UART bytes)", emitted_bytes);
                if (log_fd != 0) begin
                    $fdisplay(log_fd, "\nALL PICORV32/SYSTOLIC SYSTEM TESTS PASSED (%0d UART bytes)", emitted_bytes);
                    $fclose(log_fd);
                end
                $finish;
            end
        end
    end

    initial begin
        #2_000_000;
        if (!finished) begin
            $error("Timeout waiting for SYSTOLIC PASS from PicoRV32 firmware");
            if (log_fd != 0) $fclose(log_fd);
            $finish;
        end
    end

endmodule
