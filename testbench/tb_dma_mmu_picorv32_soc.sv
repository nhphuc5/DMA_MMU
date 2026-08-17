`timescale 1ns / 1ps

module tb_dma_mmu_picorv32_soc #(
    parameter bit AUTO_FINISH = 1'b1,
    parameter LOG_PATH = "D:/DMA_MMU-main(1)/reports/picorv32_soc_test.log"
) (
    output logic test_done_o,
    output logic test_pass_o
);
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

    localparam real SIM_CLOCK_PERIOD_NS = 6.667;
    localparam integer UART_DIVIDER = 4;
    // simpleuart_dma advances one serial bit when divcnt > divider.
    localparam integer UART_BIT_CYCLES = UART_DIVIDER + 2;

    event uart_rx_request;
    integer pending_s2m_index;
    integer active_m2s_index;
    integer m2s_byte_count;
    logic [2:0] m2m_checked;
    logic [2:0] s2m_injected;
    logic [2:0] s2m_checked;
    logic [2:0] m2s_checked;
    logic queue_checked;
    logic cpu_mmu_checked;
    logic peripheral_autonomous_checked;
    logic capture_m2s;
    logic access_pending_d;
    integer access_request_count;
    integer access_grant_count;
    integer access_deny_count;

    always #(SIM_CLOCK_PERIOD_NS/2.0) clk = ~clk;

    dma_mmu_picorv32_soc #(
        .UART_DEFAULT_DIV(UART_DIVIDER),
        // Keep an absolute path so both XSim and ModelSim find the firmware.
        .MEM_INIT_FILE("D:/DMA_MMU-main(1)/firmware/build/soc_demo.hex")
    ) dut (
        .clk_i(clk), .rst_ni(rst_n),
        .uart_rx_i(uart_rx), .uart_tx_o(uart_tx),
        .cpu_trap_o(cpu_trap), .dma_irq_o(dma_irq),
        .uart_irq_o(uart_irq),
        .uart_tx_byte_o(tx_byte),
        .uart_tx_byte_valid_o(tx_byte_valid),
        // DDR is disabled in this compatibility regression; drive every
        // optional PHY input to a deterministic value to avoid X propagation.
        .ddr_dfi_cmd_ready_i(1'b0),
        .ddr_dfi_rddata_valid_i(1'b0),
        .ddr_dfi_rddata_i(32'b0),
        .ddr_dfi_error_i(1'b0),
        .ddr_phy_calib_done_i(1'b0),
        .ddr_phy_calib_error_i(1'b0)
    );

    function automatic [31:0] expected_m2m_word(
        input integer test_index,
        input integer word_index
    );
        begin
            case (test_index)
                0: case (word_index)
                       0: expected_m2m_word = 32'h1111_1111;
                       1: expected_m2m_word = 32'h2222_2222;
                       2: expected_m2m_word = 32'h3333_3333;
                       default: expected_m2m_word = 32'h4444_4444;
                   endcase
                1: expected_m2m_word = (word_index == 0)
                                          ? 32'h1212_1212 : 32'h2323_2323;
                default: expected_m2m_word = (word_index == 0)
                                               ? 32'h3434_3434 : 32'h4545_4545;
            endcase
        end
    endfunction

    function automatic [31:0] expected_s2m_word(
        input integer test_index,
        input integer word_index
    );
        begin
            case (test_index)
                0: expected_s2m_word = (word_index == 0)
                                          ? 32'hA3A2_A1A0 : 32'hA7A6_A5A4;
                1: expected_s2m_word = (word_index == 0)
                                          ? 32'hB3B2_B1B0 : 32'hB7B6_B5B4;
                default: expected_s2m_word = (word_index == 0)
                                               ? 32'hC3C2_C1C0 : 32'hC7C6_C5C4;
            endcase
        end
    endfunction

    function automatic [7:0] expected_m2s_byte(
        input integer test_index,
        input integer byte_index
    );
        begin
            case (test_index)
                0: expected_m2s_byte = 8'h10 + byte_index;
                1: expected_m2s_byte = 8'h20 + byte_index;
                default: expected_m2s_byte = 8'h30 + byte_index;
            endcase
        end
    endfunction

    function automatic [8*17-1:0] dma_mode_name(input integer test_index);
        begin
            case (test_index)
                0: dma_mode_name = "BURST";
                1: dma_mode_name = "CYCLE-STEALING";
                default: dma_mode_name = "TRANSPARENT";
            endcase
        end
    endfunction

    initial begin
        test_done_o = 1'b0;
        test_pass_o = 1'b0;
        pending_s2m_index = 0;
        active_m2s_index = 0;
        m2s_byte_count = 0;
        m2m_checked = 3'b000;
        s2m_injected = 3'b000;
        s2m_checked = 3'b000;
        m2s_checked = 3'b000;
        queue_checked = 1'b0;
        cpu_mmu_checked = 1'b0;
        peripheral_autonomous_checked = 1'b0;
        capture_m2s = 1'b0;
        access_pending_d = 1'b0;
        access_request_count = 0;
        access_grant_count = 0;
        access_deny_count = 0;

        log_fd = $fopen(LOG_PATH, "w");
        if (log_fd == 0) begin
            $display("Cannot open PicoRV32 SoC test log");
            test_done_o = 1'b1;
            if (AUTO_FINISH)
                $finish;
        end
    end

    task automatic soc_log(input string msg);
        begin
            $display("[%0t] %s", $time, msg);
            if (log_fd != 0)
                $fdisplay(log_fd, "[%0t] %s", $time, msg);
        end
    endtask

    task automatic verify_descriptor_queue;
        integer n;
        integer source_address;
        integer destination_address;
        reg [31:0] source_value;
        reg [31:0] destination_value;
        reg local_pass;
        begin
            local_pass = dut.dma_iommu_inst.completion_total_q == 8
                      && dut.dma_iommu_inst.desc_queue_empty
                      && !dut.dma_iommu_inst.queue_active_q
                      && !dut.dma_iommu_inst.completion_valid;
            for (n = 0; n < 8; n = n + 1) begin
                source_address = 16'h4100 + n*16'h20;
                destination_address = 16'h5200 + n*16'h20;
                source_value = dut.g_bram_only.system_ram_inst.mem[source_address >> 2];
                destination_value =
                    dut.g_bram_only.system_ram_inst.mem[destination_address >> 2];
                soc_log($sformatf(
                    "  QUEUE[%0d] RAM[0x%04x]=0x%08x -> RAM[0x%04x]=0x%08x %s",
                    n, source_address, source_value, destination_address,
                    destination_value,
                    source_value === destination_value ? "MATCH" : "MISMATCH"));
                if (source_value !== 32'h5100_0000+n
                    || destination_value !== source_value)
                    local_pass = 1'b0;
            end

            if (!local_pass) begin
                $error("eight-entry descriptor queue verification failed");
                complete_soc_test(1'b0,
                    "SOC TEST FAILED: CPU descriptor FIFO/scatter-gather test");
            end else begin
                queue_checked = 1'b1;
                soc_log("PASS Q01: PicoRV32 submitted eight scattered descriptors; FIFO order, data, and completions matched");
            end
        end
    endtask

    task automatic complete_soc_test(input bit passed, input string msg);
        begin
            if (!test_done_o) begin
                soc_log(msg);
                test_pass_o = passed;
                test_done_o = 1'b1;
                if (log_fd != 0) begin
                    $fclose(log_fd);
                    log_fd = 0;
                end
                if (AUTO_FINISH)
                    $finish;
            end
        end
    endtask

    task automatic verify_m2m(input integer test_index);
        integer source_address;
        integer destination_address;
        integer word_count;
        integer n;
        reg [31:0] source_value;
        reg [31:0] destination_value;
        reg [31:0] expected_value;
        reg local_pass;
        begin
            source_address = 16'h4000 + test_index * 16'h20;
            destination_address = 16'h5000 + test_index * 16'h20;
            word_count = (test_index == 0) ? 4 : 2;
            local_pass = dut.dma_iommu_inst.scheduler_inst.transfer_type_q === 2'd0
                         && dut.dma_iommu_inst.scheduler_inst.dma_mode_q
                            === test_index[1:0];
            soc_log($sformatf(
                "  D0%0d CONTROL: scheduler latched direction=%0d mode=%0d",
                test_index + 1,
                dut.dma_iommu_inst.scheduler_inst.transfer_type_q,
                dut.dma_iommu_inst.scheduler_inst.dma_mode_q));

            for (n = 0; n < word_count; n = n + 1) begin
                source_value = dut.g_bram_only.system_ram_inst.mem[(source_address >> 2) + n];
                destination_value = dut.g_bram_only.system_ram_inst.mem[(destination_address >> 2) + n];
                expected_value = expected_m2m_word(test_index, n);
                soc_log($sformatf(
                    "  D0%0d WORD[%0d]: RAM input[0x%04x]=0x%08x -> RAM output[0x%04x]=0x%08x",
                    test_index + 1, n, source_address + n*4, source_value,
                    destination_address + n*4, destination_value));
                if (source_value !== expected_value
                    || destination_value !== expected_value)
                    local_pass = 1'b0;
            end

            if (!local_pass) begin
                $error("D0%0d M2M data comparison failed", test_index + 1);
                complete_soc_test(1'b0,
                    $sformatf("SOC TEST FAILED: D0%0d M2M data mismatch", test_index + 1));
            end else begin
                m2m_checked[test_index] = 1'b1;
                soc_log($sformatf("PASS D0%0d: Memory -> Memory / %s; actual RAM data matches",
                    test_index + 1, dma_mode_name(test_index)));
            end
        end
    endtask

    task automatic verify_s2m(input integer test_index);
        integer destination_address;
        integer n;
        reg [31:0] actual_value;
        reg [31:0] expected_value;
        reg local_pass;
        begin
            destination_address = 16'h6000 + test_index * 16'h20;
            local_pass = s2m_injected[test_index]
                         && dut.dma_iommu_inst.scheduler_inst.transfer_type_q === 2'd1
                         && dut.dma_iommu_inst.scheduler_inst.dma_mode_q
                            === test_index[1:0];
            soc_log($sformatf(
                "  D0%0d CONTROL: scheduler latched direction=%0d mode=%0d",
                test_index + 4,
                dut.dma_iommu_inst.scheduler_inst.transfer_type_q,
                dut.dma_iommu_inst.scheduler_inst.dma_mode_q));

            for (n = 0; n < 2; n = n + 1) begin
                actual_value = dut.g_bram_only.system_ram_inst.mem[(destination_address >> 2) + n];
                expected_value = expected_s2m_word(test_index, n);
                soc_log($sformatf(
                    "  D0%0d WORD[%0d]: UART input bytes -> RAM output[0x%04x]=0x%08x (expected 0x%08x)",
                    test_index + 4, n, destination_address + n*4,
                    actual_value, expected_value));
                if (actual_value !== expected_value)
                    local_pass = 1'b0;
            end

            if (!local_pass) begin
                $error("D0%0d S2M data comparison failed", test_index + 4);
                complete_soc_test(1'b0,
                    $sformatf("SOC TEST FAILED: D0%0d UART-to-memory mismatch", test_index + 4));
            end else begin
                s2m_checked[test_index] = 1'b1;
                soc_log($sformatf("PASS D0%0d: Peripheral -> Memory / %s; physical UART input matches RAM",
                    test_index + 4, dma_mode_name(test_index)));
            end
        end
    endtask

    // Drive one real 8N1 UART frame into the SoC RX pin, LSB first.
    task automatic send_uart_byte(input logic [7:0] value);
        begin
            @(negedge clk);
            uart_rx <= 1'b0;
            repeat (UART_BIT_CYCLES) @(negedge clk);
            for (int bit_index = 0; bit_index < 8; bit_index++) begin
                uart_rx <= value[bit_index];
                repeat (UART_BIT_CYCLES) @(negedge clk);
            end
            uart_rx <= 1'b1;
            repeat (UART_BIT_CYCLES) @(negedge clk);
        end
    endtask

    initial begin
        repeat (12) @(posedge clk);
        rst_n <= 1'b1;
    end

    // A/B/C are emitted after CPU-issued S2M commands start.  R is different:
    // it sends E0..E7 before START so UART RX itself creates the autonomous
    // DMA request that firmware must grant.  This process models the external
    // serial peripheral and drives real 8N1 frames into uart_rx_i.
    initial begin : uart_rx_stimulus
        integer request_index;
        integer n;
        reg [7:0] value;
        forever begin
            @uart_rx_request;
            request_index = pending_s2m_index;
            if (!test_done_o) begin
                if (request_index == 3) begin
                    soc_log("P01 INPUT: UART autonomously sends eight bytes 0xE0..0xE7 before any CPU START");
                    for (n = 0; n < 8; n = n + 1) begin
                        value = 8'hE0 + n;
                        send_uart_byte(value);
                        soc_log($sformatf("  P01 UART RX autonomous byte[%0d]=0x%02x", n, value));
                    end
                    soc_log("P01 INPUT COMPLETE: UART supplied two AXI-Stream words");
                end else begin
                    soc_log($sformatf(
                        "D0%0d INPUT: sending eight physical 8N1 UART bytes 0x%02x..0x%02x",
                        request_index + 4, 8'hA0 + request_index*16,
                        8'hA7 + request_index*16));
                    for (n = 0; n < 8; n = n + 1) begin
                        value = 8'hA0 + request_index*16 + n;
                        send_uart_byte(value);
                        soc_log($sformatf("  D0%0d UART RX input byte[%0d]=0x%02x",
                            request_index + 4, n, value));
                    end
                    s2m_injected[request_index] = 1'b1;
                    soc_log($sformatf("D0%0d INPUT COMPLETE: all eight UART frames reached uart_rx_i",
                        request_index + 4));
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            access_pending_d = 1'b0;
        end else begin
            if (dut.dma_iommu_inst.access_request_pending
                && !access_pending_d) begin
                access_request_count = access_request_count + 1;
                soc_log($sformatf(
                    "ACCESS REQUEST[%0d]: peripheral=%0d id=0x%02x queued=%0d type=%0d mode=%0d src=0x%04x dst=0x%04x length=%0d",
                    access_request_count,
                    dut.dma_iommu_inst.access_request_peripheral,
                    dut.dma_iommu_inst.access_request_id,
                    dut.dma_iommu_inst.access_request_queued,
                    dut.dma_iommu_inst.access_request_type,
                    dut.dma_iommu_inst.access_request_mode,
                    dut.dma_iommu_inst.access_request_src,
                    dut.dma_iommu_inst.access_request_dst,
                    dut.dma_iommu_inst.access_request_len));
            end

            if (dut.dma_iommu_inst.access_grant_cmd) begin
                access_grant_count = access_grant_count + 1;
                soc_log($sformatf(
                    "CPU GRANT[%0d]: request accepted; DMA may now reach IOMMU/AXI/UART",
                    access_grant_count));
            end

            if (dut.dma_iommu_inst.access_deny_cmd) begin
                access_deny_count = access_deny_count + 1;
                soc_log($sformatf(
                    "CPU DENY[%0d]: request blocked before all data interfaces",
                    access_deny_count));
            end

            if (dut.dma_iommu_inst.access_request_pending
                && dut.dma_iommu_inst.scheduler_cfg_start) begin
                $error("scheduler started while CPU access request was pending");
                complete_soc_test(1'b0,
                    "SOC TEST FAILED: DMA bypassed CPU access authorization");
            end

            access_pending_d = dut.dma_iommu_inst.access_request_pending;
        end

        if (!test_done_o && rst_n && cpu_trap) begin
            $error("PicoRV32 entered trap state");
            complete_soc_test(1'b0,
                "SOC TEST FAILED: PicoRV32 entered trap state");
        end

        if (!test_done_o && tx_byte_valid) begin
            soc_log($sformatf("UART TX observed byte: 0x%02x", tx_byte));

            // F is reserved as a firmware failure marker and never occurs in
            // any of the selected M2S payload patterns.
            if (tx_byte == 8'h46) begin
                $error("CPU firmware reported DMA/IOMMU failure");
                complete_soc_test(1'b0,
                    "SOC TEST FAILED: CPU firmware reported DMA/IOMMU failure");
            end else if (capture_m2s) begin
                // Payload handling has priority over marker decoding because
                // D09 intentionally transmits ASCII-valued bytes 0x30..0x37.
                if (m2s_byte_count >= 8
                    || tx_byte !== expected_m2s_byte(active_m2s_index, m2s_byte_count)) begin
                    $error("D0%0d M2S UART mismatch at byte %0d",
                        active_m2s_index + 7, m2s_byte_count);
                    complete_soc_test(1'b0,
                        $sformatf("SOC TEST FAILED: D0%0d memory-to-UART mismatch",
                            active_m2s_index + 7));
                end else begin
                    soc_log($sformatf(
                        "  D0%0d BYTE[%0d]: RAM input=0x%02x -> physical UART output=0x%02x MATCH",
                        active_m2s_index + 7, m2s_byte_count,
                        expected_m2s_byte(active_m2s_index, m2s_byte_count), tx_byte));
                    if (m2s_byte_count == 7) begin
                        capture_m2s = 1'b0;
                        m2s_checked[active_m2s_index] = 1'b1;
                        soc_log($sformatf(
                            "PASS D0%0d DATA: all eight RAM bytes emerged from the actual UART path",
                            active_m2s_index + 7));
                    end
                    m2s_byte_count = m2s_byte_count + 1;
                end
            end else begin
                case (tx_byte)
                    8'h53: soc_log("FIRMWARE START: PicoRV32 is executing the D01-D09 matrix"); // S

                    8'h4d: begin // M: CPU-side MMU self-test completed
                        if (dut.g_bram_only.system_ram_inst.mem[16'h3000 >> 2]
                                !== 32'hc0de_c0de
                            || !dut.cpu_mmu_enabled
                            || dut.cpu_mmu_fault_irq
                            || dut.cpu_mmu_tlb_misses == 0) begin
                            $error("CPU-side MMU translation self-test failed");
                            complete_soc_test(1'b0,
                                "SOC TEST FAILED: CPU MMU VA-to-PA translation");
                        end else begin
                            cpu_mmu_checked = 1'b1;
                            soc_log($sformatf(
                                "PASS CPU MMU: VA 0x00008000 -> PA 0x00003000, RAM=0x%08x, TLB hits=%0d misses=%0d",
                                dut.g_bram_only.system_ram_inst.mem[16'h3000 >> 2],
                                dut.cpu_mmu_tlb_hits,
                                dut.cpu_mmu_tlb_misses));
                        end
                    end

                    8'h31: verify_m2m(0); // D01 completion
                    8'h32: verify_m2m(1); // D02 completion
                    8'h33: verify_m2m(2); // D03 completion

                    8'h41: begin // A: request D04 input
                        if (m2m_checked !== 3'b111) begin
                            $error("D04 started before D01-D03 passed");
                            complete_soc_test(1'b0,
                                "SOC TEST FAILED: invalid phase before D04");
                        end else begin
                            pending_s2m_index = 0;
                            soc_log("D04 ACTIVE: Peripheral -> Memory / Burst");
                            -> uart_rx_request;
                        end
                    end
                    8'h42: begin // B: request D05 input
                        if (!s2m_checked[0]) begin
                            $error("D05 started before D04 passed");
                            complete_soc_test(1'b0,
                                "SOC TEST FAILED: invalid phase before D05");
                        end else begin
                            pending_s2m_index = 1;
                            soc_log("D05 ACTIVE: Peripheral -> Memory / Cycle-Stealing");
                            -> uart_rx_request;
                        end
                    end
                    8'h43: begin // C: request D06 input
                        if (!s2m_checked[1]) begin
                            $error("D06 started before D05 passed");
                            complete_soc_test(1'b0,
                                "SOC TEST FAILED: invalid phase before D06");
                        end else begin
                            pending_s2m_index = 2;
                            soc_log("D06 ACTIVE: Peripheral -> Memory / Transparent");
                            -> uart_rx_request;
                        end
                    end

                    8'h34: verify_s2m(0); // D04 completion
                    8'h35: verify_s2m(1); // D05 completion
                    8'h36: verify_s2m(2); // D06 completion

                    8'h58: begin // X: D07 payload follows
                        if (s2m_checked !== 3'b111) begin
                            $error("D07 started before D04-D06 passed");
                            complete_soc_test(1'b0,
                                "SOC TEST FAILED: invalid phase before D07");
                        end else begin
                            active_m2s_index = 0;
                            m2s_byte_count = 0;
                            capture_m2s = 1'b1;
                            soc_log("D07 ACTIVE: Memory -> Peripheral / Burst; capturing UART output");
                        end
                    end
                    8'h59: begin // Y: D08 payload follows
                        if (!m2s_checked[0]) begin
                            $error("D08 started before D07 passed");
                            complete_soc_test(1'b0,
                                "SOC TEST FAILED: invalid phase before D08");
                        end else begin
                            active_m2s_index = 1;
                            m2s_byte_count = 0;
                            capture_m2s = 1'b1;
                            soc_log("D08 ACTIVE: Memory -> Peripheral / Cycle-Stealing; capturing UART output");
                        end
                    end
                    8'h5A: begin // Z: D09 payload follows
                        if (!m2s_checked[1]) begin
                            $error("D09 started before D08 passed");
                            complete_soc_test(1'b0,
                                "SOC TEST FAILED: invalid phase before D09");
                        end else begin
                            active_m2s_index = 2;
                            m2s_byte_count = 0;
                            capture_m2s = 1'b1;
                            soc_log("D09 ACTIVE: Memory -> Peripheral / Transparent; capturing UART output");
                        end
                    end

                    8'h37: begin // D07 command completion
                        soc_log($sformatf(
                            "  D07 CONTROL: scheduler latched direction=%0d mode=%0d",
                            dut.dma_iommu_inst.scheduler_inst.transfer_type_q,
                            dut.dma_iommu_inst.scheduler_inst.dma_mode_q));
                        if (!m2s_checked[0]
                            || dut.dma_iommu_inst.scheduler_inst.transfer_type_q !== 2'd2
                            || dut.dma_iommu_inst.scheduler_inst.dma_mode_q !== 2'd0) begin
                            $error("D07 completed before its UART payload matched");
                            complete_soc_test(1'b0,
                                "SOC TEST FAILED: incomplete D07 output");
                        end else
                            soc_log("PASS D07: Memory -> Peripheral / Burst; DMA completed without fault");
                    end
                    8'h38: begin // D08 command completion
                        soc_log($sformatf(
                            "  D08 CONTROL: scheduler latched direction=%0d mode=%0d",
                            dut.dma_iommu_inst.scheduler_inst.transfer_type_q,
                            dut.dma_iommu_inst.scheduler_inst.dma_mode_q));
                        if (!m2s_checked[1]
                            || dut.dma_iommu_inst.scheduler_inst.transfer_type_q !== 2'd2
                            || dut.dma_iommu_inst.scheduler_inst.dma_mode_q !== 2'd1) begin
                            $error("D08 completed before its UART payload matched");
                            complete_soc_test(1'b0,
                                "SOC TEST FAILED: incomplete D08 output");
                        end else
                            soc_log("PASS D08: Memory -> Peripheral / Cycle-Stealing; DMA completed without fault");
                    end
                    8'h39: begin // D09 command completion
                        soc_log($sformatf(
                            "  D09 CONTROL: scheduler latched direction=%0d mode=%0d",
                            dut.dma_iommu_inst.scheduler_inst.transfer_type_q,
                            dut.dma_iommu_inst.scheduler_inst.dma_mode_q));
                        if (!m2s_checked[2]
                            || dut.dma_iommu_inst.scheduler_inst.transfer_type_q !== 2'd2
                            || dut.dma_iommu_inst.scheduler_inst.dma_mode_q !== 2'd2) begin
                            $error("D09 completed before its UART payload matched");
                            complete_soc_test(1'b0,
                                "SOC TEST FAILED: incomplete D09 output");
                        end else
                            soc_log("PASS D09: Memory -> Peripheral / Transparent; DMA completed without fault");
                    end

                    8'h51: verify_descriptor_queue(); // Q

                    8'h52: begin // R: external UART now creates autonomous request
                        if (!queue_checked) begin
                            $error("P01 started before descriptor queue passed");
                            complete_soc_test(1'b0,
                                "SOC TEST FAILED: invalid phase before P01");
                        end else begin
                            pending_s2m_index = 3;
                            soc_log("P01 ACTIVE: no CPU START; waiting for UART RX to request DMA and CPU grant");
                            -> uart_rx_request;
                        end
                    end

                    8'h56: begin // V: autonomous transfer verified by firmware
                        if (dut.g_bram_only.system_ram_inst.mem[16'h6060 >> 2]
                                !== 32'hE3E2_E1E0
                            || dut.g_bram_only.system_ram_inst.mem[16'h6064 >> 2]
                                !== 32'hE7E6_E5E4
                            || access_request_count != 1
                            || access_grant_count != 1
                            || access_deny_count != 0
                            || !dut.dma_iommu_inst.access_request_peripheral) begin
                            $error("P01 autonomous UART DMA verification failed");
                            complete_soc_test(1'b0,
                                "SOC TEST FAILED: peripheral request/grant/data path");
                        end else begin
                            peripheral_autonomous_checked = 1'b1;
                            soc_log("PASS P01: UART generated the only access request; CPU granted it; RAM contains E0..E7");
                        end
                    end

                    8'h50: begin // P
                        if (m2m_checked !== 3'b111
                            || s2m_checked !== 3'b111
                            || m2s_checked !== 3'b111
                            || !queue_checked
                            || !cpu_mmu_checked
                            || !peripheral_autonomous_checked
                            || access_request_count != 1
                            || access_grant_count != 1
                            || access_deny_count != 0) begin
                            $error("Firmware pass arrived before all nine checks completed");
                            complete_soc_test(1'b0,
                                "SOC TEST FAILED: incomplete D01-D09/Q01/access-controller verification");
                        end else begin
                            soc_log("PASS HYBRID ACCESS: CPU START/PUSH needed no duplicate grants; one UART request received one CPU grant");
                            soc_log("PASS: PicoRV32 executed all 3 directions x 3 modes, eight queued descriptors, and autonomous UART DMA");
                            complete_soc_test(1'b1,
                                "SOC TEST PASSED: D01-D09 + Q01 + autonomous peripheral P01");
                        end
                    end

                    default: begin
                        $error("Unexpected firmware UART marker 0x%02x", tx_byte);
                        complete_soc_test(1'b0,
                            $sformatf("SOC TEST FAILED: unexpected UART byte 0x%02x", tx_byte));
                    end
                endcase
            end
        end
    end

    initial begin
        #500000;
        if (!test_done_o) begin
            $error("Timeout waiting for PicoRV32 firmware completion");
            complete_soc_test(1'b0,
                "SOC TEST FAILED: timeout waiting for D01-D09 completion");
        end
    end

endmodule
