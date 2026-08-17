`timescale 1ns / 1ps

// Unified verification top.  Both existing self-checking environments run in
// parallel, while the synthesizable top remains dma_mmu_picorv32_soc.
module tb_dma_iommu_picorv32_unified;
    logic axi_done;
    logic axi_pass;
    logic soc_done;
    logic soc_pass;
    logic cpu_mmu_done;
    logic cpu_mmu_pass;
    integer log_fd;

    tb_dma_mmu_axi_top #(
        .AUTO_FINISH(1'b0),
        .LOG_PATH("D:/DMA_MMU-main(1)/reports/dma_mmu_axi_test.log"),
        .PERF_LOG_PATH("D:/DMA_MMU-main(1)/reports/dma_throughput.log"),
        .EDGE_LOG_PATH("D:/DMA_MMU-main(1)/reports/dma_edge_cases.log")
    ) axi_verification (
        .test_done_o(axi_done),
        .test_pass_o(axi_pass)
    );

    tb_dma_mmu_picorv32_soc #(
        .AUTO_FINISH(1'b0),
        .LOG_PATH("D:/DMA_MMU-main(1)/reports/picorv32_soc_test.log")
    ) soc_verification (
        .test_done_o(soc_done),
        .test_pass_o(soc_pass)
    );

    tb_picorv32_cpu_mmu #(
        .AUTO_FINISH(1'b0),
        .LOG_PATH("D:/DMA_MMU-main(1)/reports/cpu_mmu_test.log")
    ) cpu_mmu_verification (
        .test_done_o(cpu_mmu_done),
        .test_pass_o(cpu_mmu_pass)
    );

    task automatic unified_log(input string msg);
        begin
            $display("[%0t] %s", $time, msg);
            if (log_fd != 0)
                $fdisplay(log_fd, "[%0t] %s", $time, msg);
        end
    endtask

    initial begin : unified_test
        log_fd = $fopen(
            "D:/DMA_MMU-main(1)/reports/unified_verification.log", "w");
        if (log_fd == 0) begin
            $fatal(1, "Cannot open unified verification log");
        end

        unified_log("UNIFIED CPU + DMA + IOMMU + AXI VERIFICATION START");
        unified_log("Running CPU MMU, PicoRV32 SoC, and DMA/IOMMU AXI tests in parallel");

        wait (axi_done && soc_done && cpu_mmu_done);
        #1;
        unified_log($sformatf("DMA/IOMMU AXI component: %s",
                             axi_pass ? "PASSED" : "FAILED"));
        unified_log($sformatf("PicoRV32 CPU/SoC component: %s",
                             soc_pass ? "PASSED" : "FAILED"));
        unified_log($sformatf("CPU-side MMU protection component: %s",
                             cpu_mmu_pass ? "PASSED" : "FAILED"));

        if (axi_pass && soc_pass && cpu_mmu_pass)
            unified_log("ALL UNIFIED CPU/DMA/IOMMU/AXI TESTS PASSED");
        else
            unified_log("UNIFIED VERIFICATION FAILED");

        $fclose(log_fd);
        log_fd = 0;
        if (!(axi_pass && soc_pass && cpu_mmu_pass))
            $fatal(1, "Unified verification failed");
        $finish;
    end

    initial begin
        #2ms;
        if (!(axi_done && soc_done && cpu_mmu_done)) begin
            unified_log($sformatf(
                "UNIFIED TIMEOUT: AXI=%0d SoC=%0d CPU-MMU=%0d",
                axi_done, soc_done, cpu_mmu_done));
            if (log_fd != 0) begin
                $fclose(log_fd);
                log_fd = 0;
            end
            $fatal(1, "Unified verification timeout");
        end
    end
endmodule
