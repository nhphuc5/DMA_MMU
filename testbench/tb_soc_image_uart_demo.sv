`timescale 1ns / 1ps

// Self-checking image transfer regression.
// This test does not invent output data: every UART payload byte is compared
// against the converted image byte that was embedded in AXI RAM.
module tb_soc_image_uart_demo;
    localparam integer IMAGE_BYTES = 4096;
    localparam real CLOCK_PERIOD_NS = 6.667;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic uart_rx = 1'b1;
    wire uart_tx;
    wire cpu_trap;
    wire dma_irq;
    wire uart_irq;
    wire [7:0] tx_byte;
    wire tx_byte_valid;

    reg [7:0] expected_1 [0:IMAGE_BYTES-1];
    reg [7:0] expected_2 [0:IMAGE_BYTES-1];
    reg [7:0] expected_3 [0:IMAGE_BYTES-1];

    integer phase;
    integer header_index;
    integer payload_index;
    integer mismatch_count;
    integer total_payload_bytes;
    integer log_fd;

    always #(CLOCK_PERIOD_NS/2.0) clk = ~clk;

    dma_mmu_picorv32_soc #(
        .UART_DEFAULT_DIV(4),
        .MEM_INIT_FILE("D:/DMA_MMU-main(1)/firmware/build/image_demo/soc_image_demo_with_images.hex")
    ) dut (
        .clk_i(clk), .rst_ni(rst_n),
        .uart_rx_i(uart_rx), .uart_tx_o(uart_tx),
        .cpu_trap_o(cpu_trap), .dma_irq_o(dma_irq),
        .uart_irq_o(uart_irq),
        .uart_tx_byte_o(tx_byte), .uart_tx_byte_valid_o(tx_byte_valid)
    );

    function automatic [7:0] header_byte(
        input integer image_id,
        input integer byte_index
    );
        begin
            case (byte_index)
                0: header_byte = "I";
                1: header_byte = "M";
                2: header_byte = "G";
                default: header_byte = "0" + image_id;
            endcase
        end
    endfunction

    function automatic [7:0] done_byte(input integer byte_index);
        begin
            case (byte_index)
                0: done_byte = "D";
                1: done_byte = "O";
                2: done_byte = "N";
                default: done_byte = "E";
            endcase
        end
    endfunction

    task automatic finish_test(input bit pass);
        begin
            if (pass) begin
                $display("[%0t] PASS: three real RAM images transferred through DMA M2S and UART", $time);
                $display("[%0t] PASS: compared %0d payload bytes, mismatches=%0d", $time,
                         total_payload_bytes, mismatch_count);
                if (log_fd)
                    $fdisplay(log_fd,
                        "PASS: IMG1/IMG2/IMG3, 64x64 gray8, %0d bytes compared, mismatches=%0d",
                        total_payload_bytes, mismatch_count);
            end else begin
                $error("Image UART DMA regression failed: phase=%0d header=%0d payload=%0d mismatches=%0d trap=%0b",
                       phase, header_index, payload_index, mismatch_count, cpu_trap);
                if (log_fd)
                    $fdisplay(log_fd,
                        "FAIL: phase=%0d header=%0d payload=%0d mismatches=%0d trap=%0b",
                        phase, header_index, payload_index, mismatch_count, cpu_trap);
            end
            if (log_fd)
                $fclose(log_fd);
            $finish;
        end
    endtask

    initial begin
        $readmemh("D:/DMA_MMU-main(1)/firmware/build/image_demo/images/image_1_64x64.hex8", expected_1);
        $readmemh("D:/DMA_MMU-main(1)/firmware/build/image_demo/images/image_2_64x64.hex8", expected_2);
        $readmemh("D:/DMA_MMU-main(1)/firmware/build/image_demo/images/image_3_64x64.hex8", expected_3);
        log_fd = $fopen("D:/DMA_MMU-main(1)/reports/image_uart_dma_test.log", "w");
        if (log_fd) begin
            $fdisplay(log_fd, "DMA MEMORY-TO-UART IMAGE TEST");
            $fdisplay(log_fd, "Format: 64x64 grayscale, 4096 bytes/image");
            $fdisplay(log_fd, "IMG1 RAM=0x8000, IMG2 RAM=0x9000, IMG3 RAM=0xA000");
            $fdisplay(log_fd, "Path: AXI RAM -> DMA AXI4 read -> AXI-Stream -> UART");
            $fdisplay(log_fd, "------------------------------------------------------------");
        end
        phase = 0;
        header_index = 0;
        payload_index = 0;
        mismatch_count = 0;
        total_payload_bytes = 0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;

        // At divider 4 the complete stream is under 6 ms.  A generous limit
        // makes a stalled DMA/UART path fail deterministically.
        #(12_000_000);
        finish_test(1'b0);
    end

    always @(posedge clk) begin : monitor_uart_bytes
        reg [7:0] expected;
        integer image_id;
        if (rst_n && cpu_trap)
            finish_test(1'b0);

        if (rst_n && tx_byte_valid) begin
            case (phase)
                0, 2, 4: begin
                    image_id = (phase / 2) + 1;
                    expected = header_byte(image_id, header_index);
                    if (tx_byte !== expected) begin
                        mismatch_count = mismatch_count + 1;
                        $error("IMG%0d header[%0d]: got %02x expected %02x",
                               image_id, header_index, tx_byte, expected);
                        finish_test(1'b0);
                    end
                    if (header_index == 3) begin
                        $display("[%0t] IMG%0d header received; checking 4096 bytes", $time, image_id);
                        header_index = 0;
                        payload_index = 0;
                        phase = phase + 1;
                    end else begin
                        header_index = header_index + 1;
                    end
                end
                1, 3, 5: begin
                    case (phase)
                        1: expected = expected_1[payload_index];
                        3: expected = expected_2[payload_index];
                        default: expected = expected_3[payload_index];
                    endcase
                    if (tx_byte !== expected) begin
                        mismatch_count = mismatch_count + 1;
                        $error("IMG%0d payload[%0d]: got %02x expected %02x",
                               (phase+1)/2, payload_index, tx_byte, expected);
                        finish_test(1'b0);
                    end
                    total_payload_bytes = total_payload_bytes + 1;
                    if (payload_index == IMAGE_BYTES-1) begin
                        $display("[%0t] IMG%0d payload PASS", $time, (phase+1)/2);
                        if (log_fd)
                            $fdisplay(log_fd,
                                "PASS IMG%0d: 4096/4096 payload bytes matched",
                                (phase+1)/2);
                        payload_index = 0;
                        header_index = 0;
                        phase = phase + 1;
                    end else begin
                        payload_index = payload_index + 1;
                    end
                end
                6: begin
                    expected = done_byte(header_index);
                    if (tx_byte !== expected) begin
                        mismatch_count = mismatch_count + 1;
                        finish_test(1'b0);
                    end
                    if (header_index == 3)
                        finish_test(mismatch_count == 0 &&
                                    total_payload_bytes == 3*IMAGE_BYTES);
                    else
                        header_index = header_index + 1;
                end
                default: finish_test(1'b0);
            endcase
        end
    end

endmodule
