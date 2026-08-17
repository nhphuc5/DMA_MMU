`timescale 1ns / 1ps

// Focused self-check for CPU-side translation and protection fault paths.
module tb_picorv32_cpu_mmu #(
    parameter bit AUTO_FINISH = 1'b1,
    parameter string LOG_PATH = "D:/DMA_MMU-main(1)/reports/cpu_mmu_test.log",
    parameter string PERF_LOG_PATH = "D:/DMA_MMU-main(1)/reports/cpu_mmu_throughput.log"
) (
    output logic test_done_o,
    output logic test_pass_o
);
    localparam logic [31:0] MMU_BASE = 32'h3000_0000;
    localparam real CPU_CLOCK_MHZ = 100.0;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic [31:0] s_awaddr, s_wdata, s_araddr, s_rdata;
    logic [2:0] s_awprot, s_arprot;
    logic [3:0] s_wstrb;
    logic s_awvalid, s_awready, s_wvalid, s_wready;
    logic [1:0] s_bresp, s_rresp;
    logic s_bvalid, s_bready, s_arvalid, s_arready, s_rvalid, s_rready;

    logic [31:0] m_awaddr, m_wdata, m_araddr, m_rdata;
    logic [2:0] m_awprot, m_arprot;
    logic [3:0] m_wstrb;
    logic m_awvalid, m_awready, m_wvalid, m_wready;
    logic [1:0] m_bresp, m_rresp;
    logic m_bvalid, m_bready, m_arvalid, m_arready, m_rvalid, m_rready;

    logic fault_irq, mmu_enabled, cpu_idle;
    logic [31:0] hit_count, miss_count;
    logic [31:0] memory [0:16383];
    logic [31:0] held_awaddr, held_wdata;
    logic [3:0] held_wstrb;
    logic aw_seen, w_seen;
    integer downstream_writes, downstream_reads, errors, log_fd, perf_log_fd;
    longint unsigned perf_cycle_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            perf_cycle_count <= 0;
        else
            perf_cycle_count <= perf_cycle_count + 1;
    end

    picorv32_cpu_mmu dut (
        .clk_i(clk), .rst_ni(rst_n),
        .s_axil_awaddr(s_awaddr), .s_axil_awprot(s_awprot),
        .s_axil_awvalid(s_awvalid), .s_axil_awready(s_awready),
        .s_axil_wdata(s_wdata), .s_axil_wstrb(s_wstrb),
        .s_axil_wvalid(s_wvalid), .s_axil_wready(s_wready),
        .s_axil_bresp(s_bresp), .s_axil_bvalid(s_bvalid), .s_axil_bready(s_bready),
        .s_axil_araddr(s_araddr), .s_axil_arprot(s_arprot),
        .s_axil_arvalid(s_arvalid), .s_axil_arready(s_arready),
        .s_axil_rdata(s_rdata), .s_axil_rresp(s_rresp),
        .s_axil_rvalid(s_rvalid), .s_axil_rready(s_rready),
        .m_axil_awaddr(m_awaddr), .m_axil_awprot(m_awprot),
        .m_axil_awvalid(m_awvalid), .m_axil_awready(m_awready),
        .m_axil_wdata(m_wdata), .m_axil_wstrb(m_wstrb),
        .m_axil_wvalid(m_wvalid), .m_axil_wready(m_wready),
        .m_axil_bresp(m_bresp), .m_axil_bvalid(m_bvalid), .m_axil_bready(m_bready),
        .m_axil_araddr(m_araddr), .m_axil_arprot(m_arprot),
        .m_axil_arvalid(m_arvalid), .m_axil_arready(m_arready),
        .m_axil_rdata(m_rdata), .m_axil_rresp(m_rresp),
        .m_axil_rvalid(m_rvalid), .m_axil_rready(m_rready),
        .fault_irq_o(fault_irq), .enabled_o(mmu_enabled), .cpu_idle_o(cpu_idle),
        .tlb_hit_count_o(hit_count), .tlb_miss_count_o(miss_count)
    );

    assign m_awready = !m_bvalid && !aw_seen;
    assign m_wready  = !m_bvalid && !w_seen;
    assign m_arready = !m_rvalid;
    assign m_bresp = 2'b00;
    assign m_rresp = 2'b00;

    // Minimal AXI-Lite physical-memory target.
    always_ff @(posedge clk or negedge rst_n) begin
        integer byte_idx;
        logic [31:0] commit_addr, commit_data;
        logic [3:0] commit_strb;
        if (!rst_n) begin
            aw_seen <= 1'b0;
            w_seen <= 1'b0;
            m_bvalid <= 1'b0;
            m_rvalid <= 1'b0;
            m_rdata <= '0;
            held_awaddr <= '0;
            held_wdata <= '0;
            held_wstrb <= '0;
            downstream_writes <= 0;
            downstream_reads <= 0;
        end else begin
            if (m_awvalid && m_awready) begin
                held_awaddr <= m_awaddr;
                aw_seen <= 1'b1;
            end
            if (m_wvalid && m_wready) begin
                held_wdata <= m_wdata;
                held_wstrb <= m_wstrb;
                w_seen <= 1'b1;
            end
            if (!m_bvalid
                    && (aw_seen || (m_awvalid && m_awready))
                    && (w_seen || (m_wvalid && m_wready))) begin
                commit_addr = aw_seen ? held_awaddr : m_awaddr;
                commit_data = w_seen ? held_wdata : m_wdata;
                commit_strb = w_seen ? held_wstrb : m_wstrb;
                if (commit_addr[31:16] == 16'h0000)
                    for (byte_idx = 0; byte_idx < 4; byte_idx = byte_idx + 1)
                        if (commit_strb[byte_idx])
                            memory[commit_addr[15:2]][byte_idx*8 +: 8]
                                <= commit_data[byte_idx*8 +: 8];
                downstream_writes <= downstream_writes + 1;
                aw_seen <= 1'b0;
                w_seen <= 1'b0;
                m_bvalid <= 1'b1;
            end else if (m_bvalid && m_bready) begin
                m_bvalid <= 1'b0;
            end
            if (m_arvalid && m_arready) begin
                m_rdata <= (m_araddr[31:16] == 16'h0000)
                    ? memory[m_araddr[15:2]] : 32'h55AA_1234;
                m_rvalid <= 1'b1;
                downstream_reads <= downstream_reads + 1;
            end else if (m_rvalid && m_rready) begin
                m_rvalid <= 1'b0;
            end
        end
    end

    task automatic log_msg(input string msg);
        begin
            $display("[%0t] %s", $time, msg);
            if (log_fd != 0) $fdisplay(log_fd, "[%0t] %s", $time, msg);
        end
    endtask

    task automatic check(input bit condition, input string msg);
        begin
            if (condition) log_msg({"PASS: ", msg});
            else begin errors = errors + 1; log_msg({"FAIL: ", msg}); end
        end
    endtask

    task automatic axil_write(
        input logic [31:0] addr,
        input logic [31:0] data,
        input logic [1:0] expected_resp
    );
        begin
            do @(negedge clk); while (!(s_awready && s_wready));
            s_awaddr = addr; s_awprot = 3'b000; s_awvalid = 1'b1;
            s_wdata = data; s_wstrb = 4'hf; s_wvalid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            s_awvalid = 1'b0; s_wvalid = 1'b0;
            do @(negedge clk); while (!s_bvalid);
            check(s_bresp == expected_resp,
                $sformatf("write response at 0x%08x", addr));
        end
    endtask

    task automatic axil_read(
        input logic [31:0] addr,
        input logic [2:0] prot,
        input logic [1:0] expected_resp,
        output logic [31:0] data
    );
        begin
            do @(negedge clk); while (!s_arready);
            s_araddr = addr; s_arprot = prot; s_arvalid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            s_arvalid = 1'b0;
            do @(negedge clk); while (!s_rvalid);
            data = s_rdata;
            check(s_rresp == expected_resp,
                $sformatf("read response at 0x%08x", addr));
        end
    endtask

    // Measure one complete CPU-side AXI-Lite request from the moment the
    // request task starts until its B/R response is visible to the CPU.
    task automatic axil_write_timed(
        input logic [31:0] addr,
        input logic [31:0] data,
        input logic [1:0] expected_resp,
        output longint unsigned cycles
    );
        longint unsigned start_cycle;
        begin
            start_cycle = perf_cycle_count;
            axil_write(addr, data, expected_resp);
            cycles = perf_cycle_count-start_cycle;
        end
    endtask

    task automatic axil_read_timed(
        input logic [31:0] addr,
        input logic [2:0] prot,
        input logic [1:0] expected_resp,
        output logic [31:0] data,
        output longint unsigned cycles
    );
        longint unsigned start_cycle;
        begin
            start_cycle = perf_cycle_count;
            axil_read(addr, prot, expected_resp, data);
            cycles = perf_cycle_count-start_cycle;
        end
    endtask

    task automatic program_pte(
        input logic [3:0] index,
        input logic [19:0] vpn,
        input logic [19:0] ppn,
        input logic [3:0] flags
    );
        begin
            axil_write(MMU_BASE + 32'h00, index, 2'b00);
            axil_write(MMU_BASE + 32'h04, vpn, 2'b00);
            axil_write(MMU_BASE + 32'h08, ppn, 2'b00);
            axil_write(MMU_BASE + 32'h0c, flags, 2'b00);
        end
    endtask

    initial begin : cpu_mmu_test
        logic [31:0] data;
        integer writes_before;
        longint unsigned direct_write_cycles, direct_read_cycles;
        longint unsigned mmu_miss_write_cycles, mmu_hit_write_cycles;
        longint unsigned mmu_miss_read_cycles, mmu_hit_read_cycles;
        real direct_write_mbps, direct_read_mbps;
        real mmu_miss_write_mbps, mmu_hit_write_mbps;
        real mmu_miss_read_mbps, mmu_hit_read_mbps;
        errors = 0; test_done_o = 1'b0; test_pass_o = 1'b0;
        s_awaddr = '0; s_awprot = '0; s_awvalid = 1'b0;
        s_wdata = '0; s_wstrb = 4'hf; s_wvalid = 1'b0; s_bready = 1'b1;
        s_araddr = '0; s_arprot = '0; s_arvalid = 1'b0; s_rready = 1'b1;
        for (int i = 0; i < 16384; i++) memory[i] = '0;
        log_fd = $fopen(LOG_PATH, "w");
        if (log_fd == 0) $fatal(1, "Cannot open CPU MMU log");
        perf_log_fd = $fopen(PERF_LOG_PATH, "w");
        if (perf_log_fd == 0) $fatal(1, "Cannot open CPU MMU performance log");
        log_msg("CPU-SIDE MMU SELF-CHECK START");
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Baseline: CPU supplies a physical address while the CPU MMU is
        // disabled.  This measures the direct hardware access only; a
        // software page-table lookup, if used, must be counted separately.
        axil_write_timed(32'h0000_1000, 32'h1111_2222, 2'b00,
                         direct_write_cycles);
        check(memory[32'h1000 >> 2] == 32'h1111_2222,
              "disabled MMU bypasses RAM address");
        axil_read_timed(32'h0000_1000, 3'b000, 2'b00, data,
                        direct_read_cycles);
        check(data == 32'h1111_2222,
              "disabled MMU direct physical read preserves data");

        // VA page 8 -> PA page 3, valid/read/write but no execute.
        program_pte(4'd0, 20'h00008, 20'h00003, 4'b0111);
        axil_write(MMU_BASE + 32'h14, 32'h1, 2'b00);
        check(mmu_enabled, "MMU enable register");
        axil_write_timed(32'h0000_8004, 32'hC0DE_CAFE, 2'b00,
                         mmu_miss_write_cycles);
        check(memory[32'h3004 >> 2] == 32'hC0DE_CAFE,
              "write VA 0x8004 reaches physical RAM 0x3004");
        axil_write_timed(32'h0000_8008, 32'h1234_ABCD, 2'b00,
                         mmu_hit_write_cycles);
        check(memory[32'h3008 >> 2] == 32'h1234_ABCD,
              "TLB-hit write reaches the same translated page");
        axil_read_timed(32'h0000_8004, 3'b000, 2'b00, data,
                        mmu_hit_read_cycles);
        check(data == 32'hC0DE_CAFE, "read translation and TLB hit preserve data");
        check(hit_count != 0 && miss_count != 0, "TLB hit/miss counters advance");

        // A fresh mapped page provides a measured read miss followed by a
        // read hit to the same virtual page.
        memory[32'h4000 >> 2] = 32'hA5A5_5A5A;
        program_pte(4'd1, 20'h0000a, 20'h00004, 4'b0011);
        axil_read_timed(32'h0000_a000, 3'b000, 2'b00, data,
                        mmu_miss_read_cycles);
        check(data == 32'hA5A5_5A5A,
              "CPU MMU TLB-miss read translates through the page table");
        axil_read_timed(32'h0000_a000, 3'b000, 2'b00, data,
                        mmu_hit_read_cycles);
        check(data == 32'hA5A5_5A5A,
              "CPU MMU TLB-hit read preserves translated data");

        direct_write_mbps = 4.0*CPU_CLOCK_MHZ/direct_write_cycles;
        direct_read_mbps = 4.0*CPU_CLOCK_MHZ/direct_read_cycles;
        mmu_miss_write_mbps = 4.0*CPU_CLOCK_MHZ/mmu_miss_write_cycles;
        mmu_hit_write_mbps = 4.0*CPU_CLOCK_MHZ/mmu_hit_write_cycles;
        mmu_miss_read_mbps = 4.0*CPU_CLOCK_MHZ/mmu_miss_read_cycles;
        mmu_hit_read_mbps = 4.0*CPU_CLOCK_MHZ/mmu_hit_read_cycles;

        $fdisplay(perf_log_fd, "CPU-SIDE MMU ADDRESS-TRANSLATION PERFORMANCE REPORT");
        $fdisplay(perf_log_fd, "Clock: %.3f MHz | transfer size per AXI-Lite access: 4 bytes", CPU_CLOCK_MHZ);
        $fdisplay(perf_log_fd, "FORMULA: Time(s)=cycles/(f_MHz*1,000,000)");
        $fdisplay(perf_log_fd, "FORMULA: Throughput(MB/s)=bytes*f_MHz/cycles");
        $fdisplay(perf_log_fd, "NO-MMU baseline means CPU supplies PA directly; CPU software lookup time is not included.");
        $fdisplay(perf_log_fd, "NO MMU WRITE: C=%0d; T=4*%.3f/%0d=%.3f MB/s",
                  direct_write_cycles, CPU_CLOCK_MHZ, direct_write_cycles,
                  direct_write_mbps);
        $fdisplay(perf_log_fd, "CPU MMU WRITE TLB MISS: C=%0d; T=4*%.3f/%0d=%.3f MB/s; extra=%0d cycles",
                  mmu_miss_write_cycles, CPU_CLOCK_MHZ,
                  mmu_miss_write_cycles, mmu_miss_write_mbps,
                  mmu_miss_write_cycles-direct_write_cycles);
        $fdisplay(perf_log_fd, "CPU MMU WRITE TLB HIT : C=%0d; T=4*%.3f/%0d=%.3f MB/s; extra=%0d cycles",
                  mmu_hit_write_cycles, CPU_CLOCK_MHZ,
                  mmu_hit_write_cycles, mmu_hit_write_mbps,
                  mmu_hit_write_cycles-direct_write_cycles);
        $fdisplay(perf_log_fd, "NO MMU READ : C=%0d; T=4*%.3f/%0d=%.3f MB/s",
                  direct_read_cycles, CPU_CLOCK_MHZ, direct_read_cycles,
                  direct_read_mbps);
        $fdisplay(perf_log_fd, "CPU MMU READ TLB MISS : C=%0d; T=4*%.3f/%0d=%.3f MB/s; extra=%0d cycles",
                  mmu_miss_read_cycles, CPU_CLOCK_MHZ,
                  mmu_miss_read_cycles, mmu_miss_read_mbps,
                  mmu_miss_read_cycles-direct_read_cycles);
        $fdisplay(perf_log_fd, "CPU MMU READ TLB HIT  : C=%0d; T=4*%.3f/%0d=%.3f MB/s; extra=%0d cycles",
                  mmu_hit_read_cycles, CPU_CLOCK_MHZ,
                  mmu_hit_read_cycles, mmu_hit_read_mbps,
                  mmu_hit_read_cycles-direct_read_cycles);
        $fdisplay(perf_log_fd, "TRUE CPU-SOFTWARE TRANSLATION: C_total=C_SW_page_lookup+C_direct; T=4*f_MHz/C_total.");
        $fdisplay(perf_log_fd, "C_SW_page_lookup must be measured in firmware; it is intentionally not fabricated here.");

        axil_read(32'h0000_8004, 3'b100, 2'b11, data);
        check(data == 32'hDEAD_BEEF && fault_irq,
              "execute permission fault blocks RAM and raises IRQ");
        axil_write(MMU_BASE + 32'h10, 32'h4, 2'b00);
        check(!fault_irq, "fault clear releases IRQ");

        writes_before = downstream_writes;
        axil_write(32'h0000_9000, 32'hBAD0_0001, 2'b11);
        check(downstream_writes == writes_before,
              "unmapped write is blocked before physical AXI");
        axil_read(MMU_BASE + 32'h18, 3'b000, 2'b00, data);
        check(data[4:2] == 3'd1 && data[1], "page-fault status is sticky");
        axil_write(MMU_BASE + 32'h10, 32'h4, 2'b00);

        memory[32'h4000 >> 2] = 32'hA5A5_5A5A;
        program_pte(4'd1, 20'h0000a, 20'h00004, 4'b0011);
        writes_before = downstream_writes;
        axil_write(32'h0000_a000, 32'hFFFF_0000, 2'b11);
        check(downstream_writes == writes_before,
              "write-permission fault blocks physical AXI write");
        axil_write(MMU_BASE + 32'h10, 32'h4, 2'b00);
        axil_read(32'h0000_a000, 3'b000, 2'b00, data);
        check(data == 32'hA5A5_5A5A, "read-only mapping still permits read");

        writes_before = downstream_writes;
        axil_write(32'h1000_0040, 32'h1234_5678, 2'b00);
        check(downstream_writes == writes_before + 1,
              "physical MMIO bypass reaches downstream router");

        test_pass_o = (errors == 0);
        test_done_o = 1'b1;
        // Keep the two string-producing calls separate.  XSim 2025.1 can
        // terminate its kernel when a literal string and $sformatf result are
        // mixed in a conditional expression passed to a string task.
        if (errors == 0)
            log_msg("ALL CPU MMU TESTS PASSED");
        else
            log_msg($sformatf("CPU MMU TEST FAILED: %0d errors", errors));
        $fclose(log_fd); log_fd = 0;
        $fclose(perf_log_fd); perf_log_fd = 0;
        if (AUTO_FINISH) begin
            if (!test_pass_o) $fatal(1, "CPU MMU self-check failed");
            $finish;
        end
    end

    initial begin
        #100us;
        if (!test_done_o) $fatal(1, "CPU MMU self-check timeout");
    end
endmodule
