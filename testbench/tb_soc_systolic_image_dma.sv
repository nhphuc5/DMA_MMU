`timescale 1ns / 1ps

// Self-checking proof of the complete image datapath.  The testbench never
// computes or injects a matrix result; it only compares the UART image against
// the independent reference produced from the source PNG by the packer.
module tb_soc_systolic_image_dma #(
    parameter MEM_INIT_FILE = "D:/DMA_MMU-main(1)/firmware/build/systolic_image_dma/soc_systolic_image_dma_with_image.hex",
    parameter EXPECTED_FILE = "D:/DMA_MMU-main(1)/firmware/build/systolic_image_dma/assets/expected_output_64x64.hex8"
);
    localparam real CLOCK_PERIOD_NS = 6.667;
    localparam integer IMAGE_BYTES = 4096;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic uart_rx = 1'b1;
    wire uart_tx;
    wire cpu_trap, dma_irq, uart_irq;
    wire [7:0] tx_byte;
    wire tx_byte_valid;

    reg [7:0] expected [0:IMAGE_BYTES-1];
    integer state = 0;
    integer length_index = 0;
    integer payload_length = 0;
    integer payload_index = 0;
    integer pass_index = 0;
    integer errors = 0;
    integer log_fd;
    integer uart_debug_fd;
    integer uart_payload_fd;
    logic finished = 1'b0;
    integer fail_match = 0;
    logic firmware_fail_seen = 1'b0;

    // Datapath diagnostics.  These counters observe real handshakes and make
    // a failed image test distinguish "accelerator produced no data" from
    // "DMA accepted data but AXI never wrote it" without fabricating data.
    integer dbg_systolic_in_beats = 0;
    integer dbg_systolic_out_beats = 0;
    integer dbg_s2m_descriptors = 0;
    integer dbg_dma_write_beats = 0;
    integer dbg_dma_write_responses = 0;
    logic [17:0] dbg_first_s2m_desc_addr = '0;
    logic [17:0] dbg_first_dma_awaddr = '0;
    logic [31:0] dbg_first_dma_wdata = '0;

    always #(CLOCK_PERIOD_NS/2.0) clk = ~clk;

    dma_mmu_picorv32_soc #(
        .AXI_ADDR_WIDTH(18),
        .UART_DEFAULT_DIV(4),
        .MEM_INIT_FILE(MEM_INIT_FILE)
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
        $readmemh(EXPECTED_FILE, expected);
        log_fd = $fopen("D:/DMA_MMU-main(1)/reports/systolic_image_dma_soc_test.log", "w");
        uart_debug_fd = $fopen("D:/DMA_MMU-main(1)/reports/systolic_image_dma_uart_raw.log", "w");
        uart_payload_fd = $fopen("D:/DMA_MMU-main(1)/reports/systolic_image_dma_uart_payload.bin", "wb");
        repeat (12) @(posedge clk);
        rst_n <= 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.systolic_axis_in_tvalid && dut.systolic_axis_in_tready)
                dbg_systolic_in_beats = dbg_systolic_in_beats + 1;
            if (dut.systolic_axis_out_tvalid && dut.systolic_axis_out_tready)
                dbg_systolic_out_beats = dbg_systolic_out_beats + 1;
            if (dut.dma_iommu_inst.wr_desc_valid
                    && dut.dma_iommu_inst.wr_desc_ready) begin
                if (dbg_s2m_descriptors == 0)
                    dbg_first_s2m_desc_addr = dut.dma_iommu_inst.wr_desc_addr;
                dbg_s2m_descriptors = dbg_s2m_descriptors + 1;
            end
            if (dut.dma_iommu_inst.d_awvalid
                    && dut.dma_iommu_inst.d_awready
                    && dbg_dma_write_responses == 0)
                dbg_first_dma_awaddr = dut.dma_iommu_inst.d_awaddr;
            if (dut.dma_iommu_inst.d_wvalid
                    && dut.dma_iommu_inst.d_wready) begin
                if (dbg_dma_write_beats == 0)
                    dbg_first_dma_wdata = dut.dma_iommu_inst.d_wdata;
                dbg_dma_write_beats = dbg_dma_write_beats + 1;
            end
            if (dut.dma_iommu_inst.d_bvalid
                    && dut.dma_iommu_inst.d_bready)
                dbg_dma_write_responses = dbg_dma_write_responses + 1;
        end

        if (rst_n && cpu_trap && !finished) begin
            $error("PicoRV32 entered trap state");
            if (log_fd != 0) $fclose(log_fd);
            if (uart_debug_fd != 0) $fclose(uart_debug_fd);
            if (uart_payload_fd != 0) $fclose(uart_payload_fd);
            $finish;
        end

        if (tx_byte_valid && !finished) begin
            // Keep the complete firmware output.  This makes early failures
            // such as FAIL:ID, FAIL:DMA or FAIL:ACCEL visible instead of
            // ending as an unexplained timeout while looking for SIM1.
            $write("%c", tx_byte);
            if (uart_debug_fd != 0) $fwrite(uart_debug_fd, "%c", tx_byte);
            if (!firmware_fail_seen) begin
                case (fail_match)
                    0: if (tx_byte == "F") fail_match = 1;
                    1: if (tx_byte == "A") fail_match = 2; else fail_match = 0;
                    2: if (tx_byte == "I") fail_match = 3; else fail_match = 0;
                    3: if (tx_byte == "L") fail_match = 4; else fail_match = 0;
                    4: begin
                        if (tx_byte == ":") firmware_fail_seen = 1'b1;
                        fail_match = 0;
                    end
                endcase
            end else if (tx_byte == 8'h0a) begin
                $display("DATAPATH DEBUG: systolic_in=%0d systolic_out=%0d s2m_desc=%0d dma_w=%0d dma_b=%0d",
                         dbg_systolic_in_beats, dbg_systolic_out_beats,
                         dbg_s2m_descriptors, dbg_dma_write_beats,
                         dbg_dma_write_responses);
                $display("FIRST S2M: desc_addr=%08x awaddr=%08x wdata=%08x ram[12000]=%08x",
                         dbg_first_s2m_desc_addr, dbg_first_dma_awaddr,
                         dbg_first_dma_wdata,
                         dut.g_bram_only.system_ram_inst.mem[18'h12000 >> 2]);
                $error("Firmware reported FAIL");
                if (log_fd != 0) $fclose(log_fd);
                if (uart_debug_fd != 0) $fclose(uart_debug_fd);
                if (uart_payload_fd != 0) $fclose(uart_payload_fd);
                $finish;
            end
            case (state)
                0: begin // SIM1 marker
                    case (pass_index)
                        0: if (tx_byte == "S") pass_index = 1;
                        1: if (tx_byte == "I") pass_index = 2; else pass_index = 0;
                        2: if (tx_byte == "M") pass_index = 3; else pass_index = 0;
                        3: begin
                            if (tx_byte == "1") begin
                                state = 1;
                                pass_index = 0;
                                payload_length = 0;
                                length_index = 0;
                            end else begin
                                pass_index = 0;
                            end
                        end
                    endcase
                end

                1: begin // four-byte little-endian length
                    payload_length = payload_length |
                                     (integer'(tx_byte) << (8*length_index));
                    length_index = length_index + 1;
                    if (length_index == 4) begin
                        if (payload_length != IMAGE_BYTES) begin
                            $error("Unexpected UART image length %0d", payload_length);
                            errors = errors + 1;
                        end
                        state = 2;
                    end
                end

                2: begin // real DMA/UART payload
                    // Save only the 4096 image bytes.  This file represents
                    // exactly what crossed the UART TX byte interface, not a
                    // copy taken directly from RAM.
                    if (uart_payload_fd != 0)
                        $fwrite(uart_payload_fd, "%c", tx_byte);
                    if (tx_byte !== expected[payload_index]) begin
                        if (errors < 16)
                            $error("Pixel %0d: got %02x expected %02x",
                                   payload_index, tx_byte, expected[payload_index]);
                        errors = errors + 1;
                    end
                    payload_index = payload_index + 1;
                    if (payload_index == IMAGE_BYTES) begin
                        state = 3;
                        pass_index = 0;
                    end
                end

                3: begin // PASS trailer emitted only after firmware checks
                    case (pass_index)
                        0: if (tx_byte == "P") pass_index = 1;
                        1: if (tx_byte == "A") pass_index = 2; else pass_index = 0;
                        2: if (tx_byte == "S") pass_index = 3; else pass_index = 0;
                        3: begin
                            if (tx_byte == "S" && errors == 0) begin
                                finished = 1'b1;
                                $display("SYSTOLIC IMAGE DMA SOC TEST PASSED: %0d pixels verified", IMAGE_BYTES);
                                if (log_fd != 0) begin
                                    $fdisplay(log_fd, "SYSTOLIC IMAGE DMA SOC TEST PASSED");
                                    $fdisplay(log_fd, "Input: 64x64 GRAY8 tiled INT8 in 256-KiB BRAM");
                                    $fdisplay(log_fd, "Path: BRAM -> DMA/AXI4 -> AXI-Stream -> Systolic -> AXI-Stream -> DMA/AXI4 -> BRAM -> DMA -> UART");
                                    $fdisplay(log_fd, "Verified UART payload bytes: %0d", IMAGE_BYTES);
                                    $fclose(log_fd);
                                end
                                if (uart_debug_fd != 0) $fclose(uart_debug_fd);
                                if (uart_payload_fd != 0) $fclose(uart_payload_fd);
                                $finish;
                            end else begin
                                $error("PASS trailer missing or payload mismatched (%0d errors)", errors);
                                if (log_fd != 0) $fclose(log_fd);
                                if (uart_debug_fd != 0) $fclose(uart_debug_fd);
                                if (uart_payload_fd != 0) $fclose(uart_payload_fd);
                                $finish;
                            end
                        end
                    endcase
                end
            endcase
        end
    end

    initial begin
        // The CPU executes 256 complete DMA/systolic tiles in firmware.  Keep
        // a generous functional timeout; normal completion is much earlier.
        #20_000_000;
        if (!finished) begin
            $display("DATAPATH DEBUG: systolic_in=%0d systolic_out=%0d s2m_desc=%0d dma_w=%0d dma_b=%0d",
                     dbg_systolic_in_beats, dbg_systolic_out_beats,
                     dbg_s2m_descriptors, dbg_dma_write_beats,
                     dbg_dma_write_responses);
            $display("FIRST S2M: desc_addr=%08x awaddr=%08x wdata=%08x ram[12000]=%08x",
                     dbg_first_s2m_desc_addr, dbg_first_dma_awaddr,
                     dbg_first_dma_wdata, dut.g_bram_only.system_ram_inst.mem[18'h12000 >> 2]);
            $error("Timeout: state=%0d pixels=%0d errors=%0d pc=%08x trap=%0b dma_irq=%0b uart_irq=%0b",
                   state, payload_index, errors,
                   dut.cpu_inst.picorv32_core.reg_pc,
                   cpu_trap, dma_irq, uart_irq);
            if (log_fd != 0) $fclose(log_fd);
            if (uart_debug_fd != 0) $fclose(uart_debug_fd);
            if (uart_payload_fd != 0) $fclose(uart_payload_fd);
            $finish;
        end
    end
endmodule
