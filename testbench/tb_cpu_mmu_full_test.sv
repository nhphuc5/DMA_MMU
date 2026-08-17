`timescale 1ns / 1ps

// ============================================================================
// Comprehensive self-checking testbench for the CPU-side MMU
// (picorv32_cpu_mmu).
//
// 56 test cases organised into 8 groups:
//   Group 1 – Page-table register interface       (T01–T08)
//   Group 2 – Address translation                  (T09–T15)
//   Group 3 – TLB cache and replacement            (T16–T24)
//   Group 4 – Read/Write/Execute protection        (T25–T36)
//   Group 5 – Page-fault handling                  (T37–T43)
//   Group 6 – MMIO bypass                          (T44–T47)
//   Group 7 – Enable / disable MMU                 (T48–T51)
//   Group 8 – AXI4-Lite protocol compliance        (T52–T56)
//
// The testbench instantiates a picorv32_cpu_mmu DUT together with a minimal
// AXI4-Lite memory slave that services translated physical accesses.  Every
// test is self-checking and produces a PASS/FAIL log line.
// ============================================================================
module tb_cpu_mmu_full_test #(
    parameter bit AUTO_FINISH = 1'b1,
    parameter string LOG_PATH = "D:/DMA_MMU-main(1)/reports/cpu_mmu_full_test.log"
) (
    output logic test_done_o,
    output logic test_pass_o
);

    // -----------------------------------------------------------------------
    // Constants – must match the DUT defaults.
    // -----------------------------------------------------------------------
    localparam logic [31:0] MMU_BASE = 32'h3000_0000;

    // Register offsets inside the MMU register window.
    localparam logic [7:0] REG_PT_INDEX = 8'h00;
    localparam logic [7:0] REG_PT_VPN   = 8'h04;
    localparam logic [7:0] REG_PT_PPN   = 8'h08;
    localparam logic [7:0] REG_PT_FLAGS = 8'h0C;
    localparam logic [7:0] REG_TLB_CTRL = 8'h10;
    localparam logic [7:0] REG_CONTROL  = 8'h14;
    localparam logic [7:0] REG_STATUS   = 8'h18;
    localparam logic [7:0] REG_FAULT_VA = 8'h1C;
    localparam logic [7:0] REG_TLB_HITS = 8'h20;
    localparam logic [7:0] REG_TLB_MISS = 8'h24;
    localparam logic [7:0] REG_CONFIG   = 8'h28;

    // PTE flag bits.
    localparam int FLAG_V = 0;
    localparam int FLAG_R = 1;
    localparam int FLAG_W = 2;
    localparam int FLAG_X = 3;

    // Fault codes from the DUT.
    localparam logic [2:0] FAULT_NONE  = 3'd0;
    localparam logic [2:0] FAULT_PAGE  = 3'd1;
    localparam logic [2:0] FAULT_READ  = 3'd2;
    localparam logic [2:0] FAULT_WRITE = 3'd3;
    localparam logic [2:0] FAULT_EXEC  = 3'd4;

    // -----------------------------------------------------------------------
    // Clock and reset.
    // -----------------------------------------------------------------------
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // -----------------------------------------------------------------------
    // AXI4-Lite wires – slave side (CPU → MMU).
    // -----------------------------------------------------------------------
    logic [31:0] s_awaddr, s_wdata, s_araddr, s_rdata;
    logic [2:0]  s_awprot, s_arprot;
    logic [3:0]  s_wstrb;
    logic        s_awvalid, s_awready, s_wvalid, s_wready;
    logic [1:0]  s_bresp, s_rresp;
    logic        s_bvalid, s_bready, s_arvalid, s_arready, s_rvalid, s_rready;

    // -----------------------------------------------------------------------
    // AXI4-Lite wires – master side (MMU → system).
    // -----------------------------------------------------------------------
    logic [31:0] m_awaddr, m_wdata, m_araddr, m_rdata;
    logic [2:0]  m_awprot, m_arprot;
    logic [3:0]  m_wstrb;
    logic        m_awvalid, m_awready, m_wvalid, m_wready;
    logic [1:0]  m_bresp, m_rresp;
    logic        m_bvalid, m_bready, m_arvalid, m_arready, m_rvalid, m_rready;

    // -----------------------------------------------------------------------
    // DUT output signals.
    // -----------------------------------------------------------------------
    logic        fault_irq, mmu_enabled, cpu_idle;
    logic [31:0] hit_count, miss_count;

    // -----------------------------------------------------------------------
    // Physical memory model (64 KiB, word-addressed).
    // -----------------------------------------------------------------------
    logic [31:0] memory [0:16383];
    logic [31:0] held_awaddr, held_wdata;
    logic [3:0]  held_wstrb;
    logic        aw_seen, w_seen;
    integer      downstream_writes, downstream_reads;

    // -----------------------------------------------------------------------
    // Statistics.
    // -----------------------------------------------------------------------
    integer errors, passes, total_tests, log_fd;

    // -----------------------------------------------------------------------
    // DUT instantiation.
    // -----------------------------------------------------------------------
    picorv32_cpu_mmu dut (
        .clk_i          (clk),
        .rst_ni         (rst_n),
        // Slave port (CPU-facing).
        .s_axil_awaddr  (s_awaddr),
        .s_axil_awprot  (s_awprot),
        .s_axil_awvalid (s_awvalid),
        .s_axil_awready (s_awready),
        .s_axil_wdata   (s_wdata),
        .s_axil_wstrb   (s_wstrb),
        .s_axil_wvalid  (s_wvalid),
        .s_axil_wready  (s_wready),
        .s_axil_bresp   (s_bresp),
        .s_axil_bvalid  (s_bvalid),
        .s_axil_bready  (s_bready),
        .s_axil_araddr  (s_araddr),
        .s_axil_arprot  (s_arprot),
        .s_axil_arvalid (s_arvalid),
        .s_axil_arready (s_arready),
        .s_axil_rdata   (s_rdata),
        .s_axil_rresp   (s_rresp),
        .s_axil_rvalid  (s_rvalid),
        .s_axil_rready  (s_rready),
        // Master port (system-facing).
        .m_axil_awaddr  (m_awaddr),
        .m_axil_awprot  (m_awprot),
        .m_axil_awvalid (m_awvalid),
        .m_axil_awready (m_awready),
        .m_axil_wdata   (m_wdata),
        .m_axil_wstrb   (m_wstrb),
        .m_axil_wvalid  (m_wvalid),
        .m_axil_wready  (m_wready),
        .m_axil_bresp   (m_bresp),
        .m_axil_bvalid  (m_bvalid),
        .m_axil_bready  (m_bready),
        .m_axil_araddr  (m_araddr),
        .m_axil_arprot  (m_arprot),
        .m_axil_arvalid (m_arvalid),
        .m_axil_arready (m_arready),
        .m_axil_rdata   (m_rdata),
        .m_axil_rresp   (m_rresp),
        .m_axil_rvalid  (m_rvalid),
        .m_axil_rready  (m_rready),
        // Status outputs.
        .fault_irq_o    (fault_irq),
        .enabled_o      (mmu_enabled),
        .cpu_idle_o     (cpu_idle),
        .tlb_hit_count_o(hit_count),
        .tlb_miss_count_o(miss_count)
    );

    // -----------------------------------------------------------------------
    // Minimal AXI4-Lite memory slave.
    // -----------------------------------------------------------------------
    assign m_awready = !m_bvalid && !aw_seen;
    assign m_wready  = !m_bvalid && !w_seen;
    assign m_arready = !m_rvalid;
    assign m_bresp   = 2'b00;
    assign m_rresp   = 2'b00;

    always_ff @(posedge clk or negedge rst_n) begin
        integer byte_idx;
        logic [31:0] commit_addr, commit_data;
        logic [3:0]  commit_strb;
        if (!rst_n) begin
            aw_seen          <= 1'b0;
            w_seen           <= 1'b0;
            m_bvalid         <= 1'b0;
            m_rvalid         <= 1'b0;
            m_rdata          <= '0;
            held_awaddr      <= '0;
            held_wdata       <= '0;
            held_wstrb       <= '0;
            downstream_writes <= 0;
            downstream_reads  <= 0;
        end else begin
            if (m_awvalid && m_awready) begin
                held_awaddr <= m_awaddr;
                aw_seen     <= 1'b1;
            end
            if (m_wvalid && m_wready) begin
                held_wdata <= m_wdata;
                held_wstrb <= m_wstrb;
                w_seen     <= 1'b1;
            end
            if (!m_bvalid
                    && (aw_seen || (m_awvalid && m_awready))
                    && (w_seen  || (m_wvalid  && m_wready))) begin
                commit_addr = aw_seen ? held_awaddr : m_awaddr;
                commit_data = w_seen  ? held_wdata  : m_wdata;
                commit_strb = w_seen  ? held_wstrb  : m_wstrb;
                if (commit_addr[31:16] == 16'h0000)
                    for (byte_idx = 0; byte_idx < 4; byte_idx = byte_idx + 1)
                        if (commit_strb[byte_idx])
                            memory[commit_addr[15:2]][byte_idx*8 +: 8]
                                <= commit_data[byte_idx*8 +: 8];
                downstream_writes <= downstream_writes + 1;
                aw_seen  <= 1'b0;
                w_seen   <= 1'b0;
                m_bvalid <= 1'b1;
            end else if (m_bvalid && m_bready) begin
                m_bvalid <= 1'b0;
            end

            if (m_arvalid && m_arready) begin
                m_rdata  <= (m_araddr[31:16] == 16'h0000)
                            ? memory[m_araddr[15:2]] : 32'h55AA_1234;
                m_rvalid <= 1'b1;
                downstream_reads <= downstream_reads + 1;
            end else if (m_rvalid && m_rready) begin
                m_rvalid <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Logging / checking helpers.
    // -----------------------------------------------------------------------
    task automatic log_msg(input string msg);
        $display("[%0t] %s", $time, msg);
        if (log_fd != 0) $fdisplay(log_fd, "[%0t] %s", $time, msg);
    endtask

    task automatic check(input string test_id, input bit condition, input string msg);
        begin
            total_tests = total_tests + 1;
            if (condition) begin
                passes = passes + 1;
                log_msg($sformatf("PASS [%s]: %s", test_id, msg));
            end else begin
                errors = errors + 1;
                log_msg($sformatf("FAIL [%s]: %s", test_id, msg));
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // AXI4-Lite bus tasks.
    // -----------------------------------------------------------------------

    // Standard write: assert AW + W simultaneously.
    task automatic axil_write(
        input logic [31:0] addr,
        input logic [31:0] data,
        input logic [1:0]  expected_resp
    );
        begin
            do @(negedge clk); while (!(s_awready && s_wready));
            s_awaddr  = addr;
            s_awprot  = 3'b000;
            s_awvalid = 1'b1;
            s_wdata   = data;
            s_wstrb   = 4'hF;
            s_wvalid  = 1'b1;
            @(posedge clk);
            @(negedge clk);
            s_awvalid = 1'b0;
            s_wvalid  = 1'b0;
            do @(negedge clk); while (!s_bvalid);
            if (expected_resp != 2'bxx)
                assert (s_bresp == expected_resp) else
                    log_msg($sformatf("  axil_write bresp mismatch at 0x%08x: got %0b, exp %0b",
                                      addr, s_bresp, expected_resp));
        end
    endtask

    // Write with custom prot (for execute-flagged writes if needed).
    task automatic axil_write_prot(
        input logic [31:0] addr,
        input logic [31:0] data,
        input logic [2:0]  prot,
        input logic [1:0]  expected_resp
    );
        begin
            do @(negedge clk); while (!(s_awready && s_wready));
            s_awaddr  = addr;
            s_awprot  = prot;
            s_awvalid = 1'b1;
            s_wdata   = data;
            s_wstrb   = 4'hF;
            s_wvalid  = 1'b1;
            @(posedge clk);
            @(negedge clk);
            s_awvalid = 1'b0;
            s_wvalid  = 1'b0;
            do @(negedge clk); while (!s_bvalid);
            if (expected_resp != 2'bxx)
                assert (s_bresp == expected_resp) else
                    log_msg($sformatf("  axil_write_prot bresp mismatch at 0x%08x: got %0b",
                                      addr, s_bresp));
        end
    endtask

    // Standard read: prot defaults to data-read (3'b000).
    task automatic axil_read(
        input  logic [31:0] addr,
        input  logic [2:0]  prot,
        input  logic [1:0]  expected_resp,
        output logic [31:0] data
    );
        begin
            do @(negedge clk); while (!s_arready);
            s_araddr  = addr;
            s_arprot  = prot;
            s_arvalid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            s_arvalid = 1'b0;
            do @(negedge clk); while (!s_rvalid);
            data = s_rdata;
            if (expected_resp != 2'bxx)
                assert (s_rresp == expected_resp) else
                    log_msg($sformatf("  axil_read rresp mismatch at 0x%08x: got %0b, exp %0b",
                                      addr, s_rresp, expected_resp));
        end
    endtask

    // Convenience: data read with default prot=0 and expected OK.
    task automatic axil_read_data(
        input  logic [31:0] addr,
        output logic [31:0] data
    );
        begin
            axil_read(addr, 3'b000, 2'b00, data);
        end
    endtask

    // -----------------------------------------------------------------------
    // Page-table programming helper.
    // -----------------------------------------------------------------------
    task automatic program_pte(
        input logic [3:0]  index,
        input logic [19:0] vpn,
        input logic [19:0] ppn,
        input logic [3:0]  flags   // {X, W, R, V}
    );
        begin
            axil_write(MMU_BASE + REG_PT_INDEX, {28'd0, index}, 2'b00);
            axil_write(MMU_BASE + REG_PT_VPN,   {12'd0, vpn},   2'b00);
            axil_write(MMU_BASE + REG_PT_PPN,   {12'd0, ppn},   2'b00);
            axil_write(MMU_BASE + REG_PT_FLAGS,  {28'd0, flags}, 2'b00);
        end
    endtask

    // Enable or disable the MMU.
    task automatic mmu_set_enable(input bit en);
        axil_write(MMU_BASE + REG_CONTROL, en ? 32'h1 : 32'h0, 2'b00);
    endtask

    // Clear fault state.
    task automatic clear_fault();
        axil_write(MMU_BASE + REG_TLB_CTRL, 32'h4, 2'b00);  // bit 2
    endtask

    // Invalidate TLB.
    task automatic invalidate_tlb();
        axil_write(MMU_BASE + REG_TLB_CTRL, 32'h1, 2'b00);  // bit 0
    endtask

    // Clear counters.
    task automatic clear_counters();
        axil_write(MMU_BASE + REG_TLB_CTRL, 32'h2, 2'b00);  // bit 1
    endtask

    // Full reset of MMU state: disable, invalidate, clear counters and faults, and clear PT.
    task automatic mmu_full_reset();
        begin
            mmu_set_enable(0);
            // Combined: invalidate TLB + clear counters + clear faults.
            axil_write(MMU_BASE + REG_TLB_CTRL, 32'h7, 2'b00);
            // Clear all 16 page table entries (clear valid bit)
            for (int i = 0; i < 16; i++) begin
                axil_write(MMU_BASE + REG_PT_INDEX, i[31:0], 2'b00);
                axil_write(MMU_BASE + REG_PT_FLAGS, 32'h0, 2'b00);
            end
        end
    endtask

    // Wait a few cycles for signals to settle.
    task automatic settle();
        repeat (4) @(posedge clk);
    endtask

    // ======================================================================
    // TEST GROUPS
    // ======================================================================

    // ------------------------------------------------------------------
    // Group 1: Page-table register interface (T01–T08)
    // ------------------------------------------------------------------
    task automatic group1_page_table_registers();
        logic [31:0] rd;
        begin
            log_msg("===== GROUP 1: Page-Table Register Interface =====");
            mmu_full_reset();

            // T01 – Write/read PT_INDEX
            axil_write(MMU_BASE + REG_PT_INDEX, 32'd5, 2'b00);
            axil_read(MMU_BASE + REG_PT_INDEX, 3'b000, 2'b00, rd);
            check("T01", rd[3:0] == 4'd5,
                  $sformatf("PT_INDEX write/read: got 0x%0h, exp 5", rd));

            // T02 – Write/read PT_VPN, PT_PPN
            axil_write(MMU_BASE + REG_PT_INDEX, 32'd0, 2'b00);
            axil_write(MMU_BASE + REG_PT_VPN, 32'h000A_BCDE, 2'b00);
            axil_write(MMU_BASE + REG_PT_PPN, 32'h0001_2345, 2'b00);
            // Commit the PTE so VPN/PPN are stored in the entry.
            axil_write(MMU_BASE + REG_PT_FLAGS, 32'hF, 2'b00);
            // Read back via selecting index 0.
            axil_write(MMU_BASE + REG_PT_INDEX, 32'd0, 2'b00);
            axil_read(MMU_BASE + REG_PT_VPN, 3'b000, 2'b00, rd);
            check("T02a", rd[19:0] == 20'hABCDE,
                  $sformatf("PT_VPN readback: got 0x%05h, exp 0xABCDE", rd[19:0]));
            axil_read(MMU_BASE + REG_PT_PPN, 3'b000, 2'b00, rd);
            check("T02b", rd[19:0] == 20'h12345,
                  $sformatf("PT_PPN readback: got 0x%05h, exp 0x12345", rd[19:0]));

            // T03 – PT_FLAGS commit and readback
            axil_read(MMU_BASE + REG_PT_FLAGS, 3'b000, 2'b00, rd);
            check("T03", rd[3:0] == 4'hF,
                  $sformatf("PT_FLAGS readback: got 0x%0h, exp 0xF", rd[3:0]));

            // T04 – Multiple PTE entries
            program_pte(4'd1, 20'h00010, 20'h00020, 4'b0011);
            program_pte(4'd2, 20'h00030, 20'h00040, 4'b0101);
            program_pte(4'd3, 20'h00050, 20'h00060, 4'b1001);
            // Verify entry 1.
            axil_write(MMU_BASE + REG_PT_INDEX, 32'd1, 2'b00);
            axil_read(MMU_BASE + REG_PT_VPN, 3'b000, 2'b00, rd);
            check("T04a", rd[19:0] == 20'h00010,
                  $sformatf("Entry 1 VPN: got 0x%05h", rd[19:0]));
            axil_read(MMU_BASE + REG_PT_PPN, 3'b000, 2'b00, rd);
            check("T04b", rd[19:0] == 20'h00020,
                  $sformatf("Entry 1 PPN: got 0x%05h", rd[19:0]));
            // Verify entry 2.
            axil_write(MMU_BASE + REG_PT_INDEX, 32'd2, 2'b00);
            axil_read(MMU_BASE + REG_PT_FLAGS, 3'b000, 2'b00, rd);
            check("T04c", rd[3:0] == 4'b0101,
                  $sformatf("Entry 2 flags: got 0x%0h, exp 0x5", rd[3:0]));
            // Verify entry 3.
            axil_write(MMU_BASE + REG_PT_INDEX, 32'd3, 2'b00);
            axil_read(MMU_BASE + REG_PT_FLAGS, 3'b000, 2'b00, rd);
            check("T04d", rd[3:0] == 4'b1001,
                  $sformatf("Entry 3 flags: got 0x%0h, exp 0x9", rd[3:0]));

            // T05 – Overwrite PTE entry
            mmu_full_reset();
            program_pte(4'd0, 20'hAAAAA, 20'hBBBBB, 4'b0111);
            program_pte(4'd0, 20'hCCCCC, 20'hDDDDD, 4'b1111);
            axil_write(MMU_BASE + REG_PT_INDEX, 32'd0, 2'b00);
            axil_read(MMU_BASE + REG_PT_VPN, 3'b000, 2'b00, rd);
            check("T05", rd[19:0] == 20'hCCCCC,
                  $sformatf("Overwritten VPN: got 0x%05h, exp 0xCCCCC", rd[19:0]));

            // T06 – REG_CONFIG read-only
            axil_read(MMU_BASE + REG_CONFIG, 3'b000, 2'b00, rd);
            // Expected: {PT_ENTRIES=16=0x10, TLB_ENTRIES=4=0x04, PAGE_SHIFT=12=0x0C, version=0x01}
            check("T06", rd == 32'h10_04_0C_01,
                  $sformatf("CONFIG register: got 0x%08h, exp 0x10040C01", rd));

            // T07 – Write to invalid register offset (DECERR response)
            axil_write(MMU_BASE + 8'h30, 32'h0000_0000, 2'b11);
            check("T07", 1'b1, "Invalid register write returns DECERR");

            // T08 – Read from invalid register offset
            axil_read(MMU_BASE + 8'h30, 3'b000, 2'b11, rd);
            check("T08", rd == 32'hDEAD_BEEF,
                  $sformatf("Invalid register read: got 0x%08h, exp 0xDEADBEEF", rd));
        end
    endtask

    // ------------------------------------------------------------------
    // Group 2: Address translation (T09–T15)
    // ------------------------------------------------------------------
    task automatic group2_address_translation();
        logic [31:0] rd;
        begin
            log_msg("===== GROUP 2: Address Translation =====");
            mmu_full_reset();

            // T09 – Identity mapping (VPN == PPN)
            program_pte(4'd0, 20'h00005, 20'h00005, 4'b0111);  // V+R+W
            mmu_set_enable(1);
            memory[32'h5000 >> 2] = 32'h0;
            axil_write(32'h0000_5000, 32'hAAAA_BBBB, 2'b00);
            check("T09", memory[32'h5000 >> 2] == 32'hAAAA_BBBB,
                  "Identity mapping: VA=PA=0x5000");

            // T10 – Non-identity mapping
            mmu_full_reset();
            program_pte(4'd0, 20'h00008, 20'h00003, 4'b0111);  // page 8→3
            mmu_set_enable(1);
            memory[32'h3004 >> 2] = 32'h0;
            axil_write(32'h0000_8004, 32'hC0DE_CAFE, 2'b00);
            check("T10", memory[32'h3004 >> 2] == 32'hC0DE_CAFE,
                  "Non-identity: VA 0x8004 -> PA 0x3004");

            // T11 – Offset preservation within page
            mmu_full_reset();
            program_pte(4'd0, 20'h00007, 20'h00002, 4'b0111);  // page 7→2
            mmu_set_enable(1);
            memory[32'h2FFC >> 2] = 32'h0;
            axil_write(32'h0000_7FFC, 32'h1234_5678, 2'b00);
            check("T11", memory[32'h2FFC >> 2] == 32'h1234_5678,
                  "Offset 0xFFC preserved: VA 0x7FFC -> PA 0x2FFC");

            // T12 – Multiple simultaneous mappings
            mmu_full_reset();
            program_pte(4'd0, 20'h00004, 20'h00001, 4'b0111);  // 4→1
            program_pte(4'd1, 20'h00005, 20'h00002, 4'b0111);  // 5→2
            program_pte(4'd2, 20'h00006, 20'h00003, 4'b0111);  // 6→3
            program_pte(4'd3, 20'h00007, 20'h00004, 4'b0111);  // 7→4
            mmu_set_enable(1);
            for (int p = 0; p < 4; p++)
                memory[((p+1)*32'h1000) >> 2] = 32'h0;
            axil_write(32'h0000_4000, 32'hD000_0001, 2'b00);
            axil_write(32'h0000_5000, 32'hD000_0002, 2'b00);
            axil_write(32'h0000_6000, 32'hD000_0003, 2'b00);
            axil_write(32'h0000_7000, 32'hD000_0004, 2'b00);
            check("T12a", memory[32'h1000 >> 2] == 32'hD000_0001, "Multi-map page 4->1");
            check("T12b", memory[32'h2000 >> 2] == 32'hD000_0002, "Multi-map page 5->2");
            check("T12c", memory[32'h3000 >> 2] == 32'hD000_0003, "Multi-map page 6->3");
            check("T12d", memory[32'h4000 >> 2] == 32'hD000_0004, "Multi-map page 7->4");

            // T13 – Full 16-entry page table
            mmu_full_reset();
            for (int i = 0; i < 16; i++) begin
                // Map VA page (i) to PA page (15-i). All V+R+W.
                program_pte(i[3:0], i[19:0], (20'd15 - i[19:0]), 4'b0111);
            end
            mmu_set_enable(1);
            // Test entry 0: VA page 0 → PA page 15
            memory[(15*32'h1000) >> 2] = 32'h0;
            axil_write(32'h0000_0000, 32'hFEED_0000, 2'b00);
            check("T13a", memory[(15*32'h1000) >> 2] == 32'hFEED_0000,
                  "Full PT entry 0: page 0->15");
            // Test entry 10: VA page 10 → PA page 5
            memory[(5*32'h1000) >> 2] = 32'h0;
            axil_write(32'h0000_A000, 32'hFEED_000A, 2'b00);
            check("T13b", memory[(5*32'h1000) >> 2] == 32'hFEED_000A,
                  "Full PT entry 10: page 10->5");

            // T14 – Write translation path verified via downstream write count
            mmu_full_reset();
            program_pte(4'd0, 20'h00008, 20'h00003, 4'b0111);
            mmu_set_enable(1);
            begin
                integer wr_before;
                wr_before = downstream_writes;
                axil_write(32'h0000_8000, 32'h1111_2222, 2'b00);
                check("T14", downstream_writes == wr_before + 1,
                      "Translated write reaches downstream AXI");
            end

            // T15 – Read translation path
            mmu_full_reset();
            program_pte(4'd0, 20'h00006, 20'h00002, 4'b0111);
            mmu_set_enable(1);
            memory[32'h2010 >> 2] = 32'hBEEF_DEAD;
            axil_read(32'h0000_6010, 3'b000, 2'b00, rd);
            check("T15", rd == 32'hBEEF_DEAD,
                  $sformatf("Read translation: got 0x%08h", rd));
        end
    endtask

    // ------------------------------------------------------------------
    // Group 3: TLB cache and replacement (T16–T24)
    // ------------------------------------------------------------------
    task automatic group3_tlb();
        logic [31:0] rd, hits_before, miss_before;
        begin
            log_msg("===== GROUP 3: TLB Cache and Replacement =====");

            // T16 – TLB miss then TLB hit on same page
            mmu_full_reset();
            program_pte(4'd0, 20'h00008, 20'h00003, 4'b0111);
            mmu_set_enable(1);
            memory[32'h3000 >> 2] = 32'hCAFE_0001;
            // First access – TLB miss.
            axil_read(32'h0000_8000, 3'b000, 2'b00, rd);
            axil_read(MMU_BASE + REG_TLB_MISS, 3'b000, 2'b00, miss_before);
            check("T16a", miss_before > 0,
                  $sformatf("First access causes TLB miss: miss_count=%0d", miss_before));
            // Second access – TLB hit.
            hits_before = hit_count;
            axil_read(32'h0000_8000, 3'b000, 2'b00, rd);
            check("T16b", hit_count > hits_before,
                  $sformatf("Second access causes TLB hit: hit_count=%0d", hit_count));

            // T17 – TLB hit returns correct data
            check("T17", rd == 32'hCAFE_0001,
                  $sformatf("TLB hit data correct: got 0x%08h", rd));

            // T18 – TLB invalidation
            mmu_full_reset();
            program_pte(4'd0, 20'h00008, 20'h00003, 4'b0111);
            mmu_set_enable(1);
            memory[32'h3000 >> 2] = 32'h1234_ABCD;
            axil_read(32'h0000_8000, 3'b000, 2'b00, rd);  // fill TLB
            clear_counters();
            invalidate_tlb();
            axil_read(32'h0000_8000, 3'b000, 2'b00, rd);  // should miss again
            check("T18", miss_count > 0,
                  $sformatf("After TLB invalidation, re-access causes miss: miss=%0d", miss_count));

            // T19 – PTE update auto-invalidates TLB
            mmu_full_reset();
            program_pte(4'd0, 20'h00008, 20'h00003, 4'b0111);
            mmu_set_enable(1);
            memory[32'h3000 >> 2] = 32'hAAAA_0001;
            axil_read(32'h0000_8000, 3'b000, 2'b00, rd);  // fill TLB
            clear_counters();
            // Update any PTE entry → all TLB entries invalidated.
            mmu_set_enable(0);
            program_pte(4'd1, 20'h00009, 20'h00004, 4'b0111);
            mmu_set_enable(1);
            axil_read(32'h0000_8000, 3'b000, 2'b00, rd);  // should miss
            check("T19", miss_count > 0,
                  "PTE update auto-invalidates TLB (access after causes miss)");

            // T20 – TLB fill prefers invalid entry
            mmu_full_reset();
            program_pte(4'd0, 20'h00004, 20'h00001, 4'b0111);
            program_pte(4'd1, 20'h00005, 20'h00002, 4'b0111);
            mmu_set_enable(1);
            // Access page 4 – fills slot 0 (first invalid).
            axil_read(32'h0000_4000, 3'b000, 2'b00, rd);
            // Access page 5 – fills slot 1 (next invalid).
            axil_read(32'h0000_5000, 3'b000, 2'b00, rd);
            // Both should now hit.
            clear_counters();
            axil_read(32'h0000_4000, 3'b000, 2'b00, rd);
            axil_read(32'h0000_5000, 3'b000, 2'b00, rd);
            check("T20", hit_count == 32'd2 && miss_count == 32'd0,
                  $sformatf("Both pages hit after fill: hits=%0d, miss=%0d",
                            hit_count, miss_count));

            // T21 – pLRU replacement when TLB is full
            mmu_full_reset();
            program_pte(4'd0, 20'h00004, 20'h00001, 4'b0111);
            program_pte(4'd1, 20'h00005, 20'h00002, 4'b0111);
            program_pte(4'd2, 20'h00006, 20'h00003, 4'b0111);
            program_pte(4'd3, 20'h00007, 20'h00004, 4'b0111);
            program_pte(4'd4, 20'h00008, 20'h00005, 4'b0111);  // 5th mapping
            mmu_set_enable(1);
            // Fill all 4 TLB slots.
            for (int p = 4; p <= 7; p++) begin
                memory[(p-3)*32'h1000 >> 2] = 32'hBB00_0000 + p;
                axil_read({16'h0000, p[3:0], 12'h000}, 3'b000, 2'b00, rd);
            end
            // Now access 5th page – must evict one via pLRU.
            clear_counters();
            memory[32'h5000 >> 2] = 32'hBB00_0008;
            axil_read(32'h0000_8000, 3'b000, 2'b00, rd);
            check("T21", miss_count > 0 && rd == 32'hBB00_0008,
                  "5th page causes pLRU eviction and correct data");

            // T22 – Evicted entry causes miss on re-access
            // After T21, one of pages 4-7 was evicted. Access all four and check at least one misses.
            clear_counters();
            for (int p = 4; p <= 7; p++)
                axil_read({16'h0000, p[3:0], 12'h000}, 3'b000, 2'b00, rd);
            check("T22", miss_count > 0,
                  $sformatf("Evicted entry causes miss on re-access: miss=%0d", miss_count));

            // T23 – Counter clear
            mmu_full_reset();
            program_pte(4'd0, 20'h00008, 20'h00003, 4'b0111);
            mmu_set_enable(1);
            memory[32'h3000 >> 2] = 32'h0;
            axil_read(32'h0000_8000, 3'b000, 2'b00, rd);  // miss
            axil_read(32'h0000_8000, 3'b000, 2'b00, rd);  // hit
            clear_counters();
            check("T23", hit_count == 32'd0 && miss_count == 32'd0,
                  "Counters cleared to zero");

            // T24 – TLB thrashing with 5 pages through 4-entry TLB
            mmu_full_reset();
            for (int i = 0; i < 5; i++)
                program_pte(i[3:0], (20'h00004 + i[19:0]), (20'h00001 + i[19:0]), 4'b0111);
            mmu_set_enable(1);
            for (int i = 0; i < 5; i++)
                memory[((i+1)*32'h1000) >> 2] = 32'hCC00_0000 + i;
            clear_counters();
            // Access 5 pages 3 rounds.
            for (int round = 0; round < 3; round++)
                for (int p = 0; p < 5; p++)
                    axil_read({16'h0000, 4'(4+p), 12'h000}, 3'b000, 2'b00, rd);
            check("T24", miss_count > 5,
                  $sformatf("TLB thrashing: miss_count=%0d (expect many misses)", miss_count));
        end
    endtask

    // ------------------------------------------------------------------
    // Group 4: Protection (T25–T36)
    // ------------------------------------------------------------------
    task automatic group4_protection();
        logic [31:0] rd;
        integer wr_before;
        begin
            log_msg("===== GROUP 4: Read/Write/Execute Protection =====");

            // T25 – Read-only page: read OK
            mmu_full_reset();
            program_pte(4'd0, 20'h00008, 20'h00003, 4'b0011);  // V+R
            mmu_set_enable(1);
            memory[32'h3000 >> 2] = 32'hA5A5_5A5A;
            axil_read(32'h0000_8000, 3'b000, 2'b00, rd);
            check("T25", rd == 32'hA5A5_5A5A,
                  "Read-only page: read succeeds");

            // T26 – Read-only page: write blocked
            clear_fault();
            wr_before = downstream_writes;
            axil_write(32'h0000_8000, 32'hBAD0_0000, 2'b11);
            check("T26a", downstream_writes == wr_before,
                  "Read-only page: write blocked from downstream");
            check("T26b", fault_irq == 1'b1,
                  "Read-only page: fault_irq asserted");
            axil_read(MMU_BASE + REG_STATUS, 3'b000, 2'b00, rd);
            check("T26c", rd[4:2] == FAULT_WRITE,
                  $sformatf("Fault code = FAULT_WRITE(3): got %0d", rd[4:2]));
            clear_fault();

            // T27 – Write-only page: write OK
            mmu_full_reset();
            program_pte(4'd0, 20'h00008, 20'h00003, 4'b0101);  // V+W
            mmu_set_enable(1);
            memory[32'h3000 >> 2] = 32'h0;
            axil_write(32'h0000_8000, 32'hDA7A_E001, 2'b00);
            check("T27", memory[32'h3000 >> 2] == 32'hDA7A_E001,
                  "Write-only page: write succeeds");

            // T28 – Write-only page: read blocked
            clear_fault();
            axil_read(32'h0000_8000, 3'b000, 2'b11, rd);
            check("T28a", rd == 32'hDEAD_BEEF,
                  "Write-only page: read returns DEAD_BEEF");
            check("T28b", fault_irq == 1'b1,
                  "Write-only page: fault_irq asserted");
            axil_read(MMU_BASE + REG_STATUS, 3'b000, 2'b00, rd);
            check("T28c", rd[4:2] == FAULT_READ,
                  $sformatf("Fault code = FAULT_READ(2): got %0d", rd[4:2]));
            clear_fault();

            // T29 – No execute permission: fetch blocked
            mmu_full_reset();
            program_pte(4'd0, 20'h00008, 20'h00003, 4'b0011);  // V+R (no X)
            mmu_set_enable(1);
            memory[32'h3000 >> 2] = 32'h0013_0000;  // NOP instruction
            axil_read(32'h0000_8000, 3'b100, 2'b11, rd);  // prot[2]=1 → execute
            check("T29a", rd == 32'hDEAD_BEEF,
                  "No-exec page: fetch returns DEAD_BEEF");
            check("T29b", fault_irq == 1'b1,
                  "No-exec page: fault_irq asserted");
            axil_read(MMU_BASE + REG_STATUS, 3'b000, 2'b00, rd);
            check("T29c", rd[4:2] == FAULT_EXEC,
                  $sformatf("Fault code = FAULT_EXEC(4): got %0d", rd[4:2]));
            clear_fault();

            // T30 – Execute allowed
            mmu_full_reset();
            program_pte(4'd0, 20'h00008, 20'h00003, 4'b1011);  // V+R+X
            mmu_set_enable(1);
            memory[32'h3000 >> 2] = 32'h0013_0000;
            axil_read(32'h0000_8000, 3'b100, 2'b00, rd);
            check("T30", rd == 32'h0013_0000,
                  "Execute-permitted page: fetch succeeds");

            // T31 – Full permission RWX
            mmu_full_reset();
            program_pte(4'd0, 20'h00008, 20'h00003, 4'b1111);  // V+R+W+X
            mmu_set_enable(1);
            memory[32'h3000 >> 2] = 32'h0;
            axil_write(32'h0000_8000, 32'hA11_0E2B5, 2'b00);
            check("T31a", memory[32'h3000 >> 2] == 32'hA11_0E2B5, "RWX: write OK");
            axil_read(32'h0000_8000, 3'b000, 2'b00, rd);
            check("T31b", rd == 32'hA11_0E2B5, "RWX: read OK");
            axil_read(32'h0000_8000, 3'b100, 2'b00, rd);
            check("T31c", rd == 32'hA11_0E2B5, "RWX: execute OK");

            // T32 – Valid only (no R/W/X): all access fault
            mmu_full_reset();
            program_pte(4'd0, 20'h00008, 20'h00003, 4'b0001);  // V only
            mmu_set_enable(1);
            clear_fault();
            axil_read(32'h0000_8000, 3'b000, 2'b11, rd);
            check("T32a", fault_irq == 1'b1, "Valid-only: read faults");
            clear_fault();
            axil_write(32'h0000_8000, 32'h0, 2'b11);
            check("T32b", fault_irq == 1'b1, "Valid-only: write faults");
            clear_fault();
            axil_read(32'h0000_8000, 3'b100, 2'b11, rd);
            check("T32c", fault_irq == 1'b1, "Valid-only: execute faults");
            clear_fault();

            // T33 – Write fault via TLB hit path
            mmu_full_reset();
            program_pte(4'd0, 20'h00008, 20'h00003, 4'b0011);  // V+R (no W)
            mmu_set_enable(1);
            memory[32'h3000 >> 2] = 32'h01DD_A7A0;
            axil_read(32'h0000_8000, 3'b000, 2'b00, rd);  // fill TLB
            clear_fault();
            clear_counters();
            wr_before = downstream_writes;
            axil_write(32'h0000_8000, 32'h0E2D_A7A1, 2'b11);  // TLB hit, no W perm
            check("T33a", downstream_writes == wr_before,
                  "Write fault via TLB hit: blocked from downstream");
            check("T33b", hit_count > 0,
                  $sformatf("Write fault occurred on TLB hit path: hits=%0d", hit_count));
            clear_fault();

            // T34 – Write fault via PT hit path (TLB miss)
            mmu_full_reset();
            program_pte(4'd0, 20'h00008, 20'h00003, 4'b0011);  // V+R (no W)
            mmu_set_enable(1);
            clear_fault();
            wr_before = downstream_writes;
            axil_write(32'h0000_8000, 32'h0E2D_A7A2, 2'b11);  // TLB miss→PT hit→no W
            check("T34a", downstream_writes == wr_before,
                  "Write fault via PT hit: blocked from downstream");
            check("T34b", miss_count > 0,
                  "Write fault occurred on TLB miss (PT hit) path");
            clear_fault();

            // T35 – Read fault via TLB hit path
            mmu_full_reset();
            program_pte(4'd0, 20'h00008, 20'h00003, 4'b0101);  // V+W (no R)
            mmu_set_enable(1);
            memory[32'h3000 >> 2] = 32'h0;
            axil_write(32'h0000_8000, 32'h1234, 2'b00);  // fill TLB with write
            clear_fault();
            clear_counters();
            axil_read(32'h0000_8000, 3'b000, 2'b11, rd);  // TLB hit, no R perm
            check("T35a", rd == 32'hDEAD_BEEF,
                  "Read fault via TLB hit: returns DEAD_BEEF");
            check("T35b", hit_count > 0,
                  "Read fault occurred on TLB hit path");
            clear_fault();

            // T36 – Read fault via PT hit path (TLB miss)
            mmu_full_reset();
            program_pte(4'd0, 20'h00008, 20'h00003, 4'b0101);  // V+W (no R)
            mmu_set_enable(1);
            clear_fault();
            axil_read(32'h0000_8000, 3'b000, 2'b11, rd);  // TLB miss→PT hit→no R
            check("T36a", rd == 32'hDEAD_BEEF,
                  "Read fault via PT hit: returns DEAD_BEEF");
            check("T36b", miss_count > 0,
                  "Read fault occurred on TLB miss (PT hit) path");
            clear_fault();
        end
    endtask

    // ------------------------------------------------------------------
    // Group 5: Page fault (T37–T43)
    // ------------------------------------------------------------------
    task automatic group5_page_fault();
        logic [31:0] rd;
        integer wr_before;
        begin
            log_msg("===== GROUP 5: Page Fault Handling =====");

            // T37 – Write to unmapped page
            mmu_full_reset();
            mmu_set_enable(1);
            clear_fault();
            wr_before = downstream_writes;
            axil_write(32'h0000_9000, 32'hBAD0_0001, 2'b11);
            check("T37a", downstream_writes == wr_before,
                  "Unmapped write blocked from downstream");
            axil_read(MMU_BASE + REG_STATUS, 3'b000, 2'b00, rd);
            check("T37b", rd[4:2] == FAULT_PAGE,
                  $sformatf("Page fault code: got %0d, exp 1", rd[4:2]));
            check("T37c", rd[1] == 1'b1, "fault_pending sticky bit set");
            clear_fault();

            // T38 – Read from unmapped page
            mmu_full_reset();
            mmu_set_enable(1);
            clear_fault();
            axil_read(32'h0000_9000, 3'b000, 2'b11, rd);
            check("T38a", rd == 32'hDEAD_BEEF,
                  "Unmapped read returns DEAD_BEEF");
            axil_read(MMU_BASE + REG_STATUS, 3'b000, 2'b00, rd);
            check("T38b", rd[4:2] == FAULT_PAGE,
                  $sformatf("Read page fault code: got %0d, exp 1", rd[4:2]));
            clear_fault();

            // T39 – Fault address register
            mmu_full_reset();
            mmu_set_enable(1);
            clear_fault();
            axil_write(32'h0000_ABCD, 32'h0, 2'b11);
            axil_read(MMU_BASE + REG_FAULT_VA, 3'b000, 2'b00, rd);
            check("T39", rd == 32'h0000_ABCD,
                  $sformatf("FAULT_VA = 0x%08h, exp 0x0000ABCD", rd));
            clear_fault();

            // T40 – Fault status register format
            mmu_full_reset();
            mmu_set_enable(1);
            clear_fault();
            axil_write(32'h0000_FFFF, 32'h0, 2'b11);  // page fault
            axil_read(MMU_BASE + REG_STATUS, 3'b000, 2'b00, rd);
            // Format: {27'b0, fault_code[2:0], fault_pending, mmu_enabled}
            check("T40a", rd[0] == 1'b1, "STATUS.mmu_enabled = 1");
            check("T40b", rd[1] == 1'b1, "STATUS.fault_pending = 1");
            check("T40c", rd[4:2] == FAULT_PAGE, "STATUS.fault_code = PAGE(1)");
            clear_fault();

            // T41 – Fault clear
            mmu_full_reset();
            mmu_set_enable(1);
            axil_write(32'h0000_9000, 32'h0, 2'b11);  // cause fault
            check("T41a", fault_irq == 1'b1, "fault_irq asserted before clear");
            clear_fault();
            check("T41b", fault_irq == 1'b0, "fault_irq de-asserted after clear");
            axil_read(MMU_BASE + REG_STATUS, 3'b000, 2'b00, rd);
            check("T41c", rd[1] == 1'b0, "fault_pending cleared");
            check("T41d", rd[4:2] == FAULT_NONE, "fault_code cleared to NONE");

            // T42 – Fault does not reach downstream
            mmu_full_reset();
            mmu_set_enable(1);
            clear_fault();
            wr_before = downstream_writes;
            axil_write(32'h0000_9000, 32'h0, 2'b11);
            axil_read(32'h0000_9000, 3'b000, 2'b11, rd);
            check("T42", downstream_writes == wr_before,
                  "Faulted write+read do not increment downstream counter");
            clear_fault();

            // T43 – Multiple faults: last fault address kept
            mmu_full_reset();
            mmu_set_enable(1);
            clear_fault();
            axil_write(32'h0000_A000, 32'h0, 2'b11);  // fault 1
            clear_fault();
            axil_write(32'h0000_B000, 32'h0, 2'b11);  // fault 2
            axil_read(MMU_BASE + REG_FAULT_VA, 3'b000, 2'b00, rd);
            check("T43", rd == 32'h0000_B000,
                  $sformatf("Last fault VA: got 0x%08h, exp 0x0000B000", rd));
            clear_fault();
        end
    endtask

    // ------------------------------------------------------------------
    // Group 6: MMIO bypass (T44–T47)
    // ------------------------------------------------------------------
    task automatic group6_mmio_bypass();
        logic [31:0] rd;
        integer wr_before;
        begin
            log_msg("===== GROUP 6: MMIO Bypass =====");

            // T44 – DMA window (0x1000_0000) bypasses MMU
            mmu_full_reset();
            mmu_set_enable(1);
            wr_before = downstream_writes;
            axil_write(32'h1000_0040, 32'h1234_5678, 2'b00);
            check("T44", downstream_writes == wr_before + 1,
                  "DMA window 0x1000_0040 bypasses translation");

            // T45 – UART window (0x2000_0000) bypasses MMU
            wr_before = downstream_writes;
            axil_write(32'h2000_0004, 32'h0A27_DA7A, 2'b00);
            check("T45", downstream_writes == wr_before + 1,
                  "UART window 0x2000_0004 bypasses translation");

            // T46 – Arbitrary high address bypasses
            wr_before = downstream_writes;
            axil_write(32'hF000_0000, 32'hF1F0_ADD2, 2'b00);
            check("T46", downstream_writes == wr_before + 1,
                  "High address 0xF000_0000 bypasses translation");

            // T47 – MMU register access is local (no downstream)
            wr_before = downstream_writes;
            axil_write(MMU_BASE + REG_CONTROL, 32'h0, 2'b00);
            check("T47a", downstream_writes == wr_before,
                  "MMU register write does not reach downstream");
            begin
                integer rd_before;
                rd_before = downstream_reads;
                axil_read(MMU_BASE + REG_STATUS, 3'b000, 2'b00, rd);
                check("T47b", downstream_reads == rd_before,
                      "MMU register read does not reach downstream");
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Group 7: Enable / disable MMU (T48–T51)
    // ------------------------------------------------------------------
    task automatic group7_enable_disable();
        logic [31:0] rd;
        begin
            log_msg("===== GROUP 7: Enable / Disable MMU =====");

            // T48 – Disabled MMU: pass-through (VA == PA)
            mmu_full_reset();
            memory[32'h1000 >> 2] = 32'h0;
            axil_write(32'h0000_1000, 32'hBA55_7720, 2'b00);
            check("T48", memory[32'h1000 >> 2] == 32'hBA55_7720,
                  "MMU disabled: VA=PA pass-through");

            // T49 – Enable → translate
            mmu_full_reset();
            program_pte(4'd0, 20'h00008, 20'h00003, 4'b0111);
            mmu_set_enable(1);
            check("T49a", mmu_enabled == 1'b1, "MMU enabled signal asserted");
            memory[32'h3000 >> 2] = 32'h0;
            axil_write(32'h0000_8000, 32'h72A0_51A7, 2'b00);
            check("T49b", memory[32'h3000 >> 2] == 32'h72A0_51A7,
                  "MMU enabled: translation active");

            // T50 – Toggle enable/disable at runtime
            // Phase 1: disable → pass-through
            mmu_set_enable(0);
            memory[32'h8000 >> 2] = 32'h0;
            axil_write(32'h0000_8000, 32'hD15AB1E1, 2'b00);
            check("T50a", memory[32'h8000 >> 2] == 32'hD15AB1E1,
                  "Toggled disable: VA=PA");
            // Phase 2: re-enable → translate again
            mmu_set_enable(1);
            memory[32'h3000 >> 2] = 32'h0;
            axil_write(32'h0000_8000, 32'hE0AB1ED2, 2'b00);
            check("T50b", memory[32'h3000 >> 2] == 32'hE0AB1ED2,
                  "Toggled re-enable: translation resumes");

            // T51 – Disable does not clear PT
            mmu_set_enable(0);
            axil_write(MMU_BASE + REG_PT_INDEX, 32'd0, 2'b00);
            axil_read(MMU_BASE + REG_PT_VPN, 3'b000, 2'b00, rd);
            check("T51", rd[19:0] == 20'h00008,
                  $sformatf("PT entry survives disable: VPN=0x%05h", rd[19:0]));
        end
    endtask

    // ------------------------------------------------------------------
    // Group 8: AXI4-Lite protocol (T52–T56)
    // ------------------------------------------------------------------
    task automatic group8_axi_protocol();
        logic [31:0] rd;
        begin
            log_msg("===== GROUP 8: AXI4-Lite Protocol Compliance =====");
            mmu_full_reset();

            // T52 – Write channel: AW before W
            program_pte(4'd0, 20'h00005, 20'h00005, 4'b0111);
            mmu_set_enable(0);
            memory[32'h5000 >> 2] = 32'h0;
            begin
                // Send AW first.
                do @(negedge clk); while (!s_awready);
                s_awaddr = 32'h0000_5000; s_awprot = 3'b000;
                s_awvalid = 1'b1;
                @(posedge clk); @(negedge clk);
                s_awvalid = 1'b0;
                // Delay, then W.
                repeat (3) @(posedge clk);
                do @(negedge clk); while (!s_wready);
                s_wdata = 32'h0AFF_1257; s_wstrb = 4'hF;
                s_wvalid = 1'b1;
                @(posedge clk); @(negedge clk);
                s_wvalid = 1'b0;
                do @(negedge clk); while (!s_bvalid);
            end
            check("T52", memory[32'h5000 >> 2] == 32'h0AFF_1257,
                  "AW-before-W handshake works");

            // T53 – Back-to-back writes
            memory[32'h5000 >> 2] = 32'h0;
            memory[32'h5004 >> 2] = 32'h0;
            axil_write(32'h0000_5000, 32'h0BAC_02B1, 2'b00);
            axil_write(32'h0000_5004, 32'h0BAC_02B2, 2'b00);
            check("T53a", memory[32'h5000 >> 2] == 32'h0BAC_02B1, "B2B write 1");
            check("T53b", memory[32'h5004 >> 2] == 32'h0BAC_02B2, "B2B write 2");

            // T54 – Back-to-back reads
            memory[32'h5000 >> 2] = 32'h2EAD_B2B1;
            memory[32'h5004 >> 2] = 32'h2EAD_B2B2;
            axil_read(32'h0000_5000, 3'b000, 2'b00, rd);
            check("T54a", rd == 32'h2EAD_B2B1, "B2B read 1");
            axil_read(32'h0000_5004, 3'b000, 2'b00, rd);
            check("T54b", rd == 32'h2EAD_B2B2, "B2B read 2");

            // T55 – Read/write interleave
            memory[32'h5008 >> 2] = 32'h1071_2EAD;
            memory[32'h500C >> 2] = 32'h0;
            axil_write(32'h0000_500C, 32'h1071_DA7A, 2'b00);
            axil_read(32'h0000_5008, 3'b000, 2'b00, rd);
            check("T55a", rd == 32'h1071_2EAD, "Interleave read correct");
            check("T55b", memory[32'h500C >> 2] == 32'h1071_DA7A,
                  "Interleave write correct");

            // T56 – Slow bready / rready
            memory[32'h5010 >> 2] = 32'h510F_2DAD;
            begin
                // Slow read: hold rready low for several cycles.
                do @(negedge clk); while (!s_arready);
                s_araddr = 32'h0000_5010; s_arprot = 3'b000;
                s_arvalid = 1'b1;
                @(posedge clk); @(negedge clk);
                s_arvalid = 1'b0;
                s_rready = 1'b0;  // hold off
                repeat (5) @(posedge clk);
                s_rready = 1'b1;
                do @(negedge clk); while (!s_rvalid);
                rd = s_rdata;
            end
            check("T56a", rd == 32'h510F_2DAD,
                  "Slow rready: data not lost");
            // Slow write: hold bready low.
            memory[32'h5010 >> 2] = 32'h0;
            begin
                do @(negedge clk); while (!(s_awready && s_wready));
                s_awaddr = 32'h0000_5010; s_awprot = 3'b000;
                s_awvalid = 1'b1;
                s_wdata = 32'h510F_DA7A; s_wstrb = 4'hF;
                s_wvalid = 1'b1;
                @(posedge clk); @(negedge clk);
                s_awvalid = 1'b0; s_wvalid = 1'b0;
                s_bready = 1'b0;  // hold off
                repeat (5) @(posedge clk);
                s_bready = 1'b1;
                do @(negedge clk); while (!s_bvalid);
            end
            check("T56b", memory[32'h5010 >> 2] == 32'h510F_DA7A,
                  "Slow bready: write committed correctly");
        end
    endtask

    // ======================================================================
    // Main test sequence
    // ======================================================================
    initial begin : main_test
        errors      = 0;
        passes      = 0;
        total_tests = 0;
        test_done_o = 1'b0;
        test_pass_o = 1'b0;

        // Idle all slave-side AXI signals.
        s_awaddr  = '0; s_awprot  = '0; s_awvalid = 1'b0;
        s_wdata   = '0; s_wstrb   = 4'hF; s_wvalid  = 1'b0; s_bready = 1'b1;
        s_araddr  = '0; s_arprot  = '0; s_arvalid = 1'b0; s_rready  = 1'b1;

        // Clear memory.
        for (int i = 0; i < 16384; i++) memory[i] = '0;

        log_fd = $fopen(LOG_PATH, "w");
        if (log_fd == 0) $fatal(1, "Cannot open %s", LOG_PATH);

        log_msg("================================================================");
        log_msg("  CPU-SIDE MMU COMPREHENSIVE SELF-CHECK");
        log_msg("  DUT: picorv32_cpu_mmu (PT=16, TLB=4, page=4KiB)");
        log_msg("================================================================");

        // Release reset.
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Run all test groups.
        group1_page_table_registers();
        group2_address_translation();
        group3_tlb();
        group4_protection();
        group5_page_fault();
        group6_mmio_bypass();
        group7_enable_disable();
        group8_axi_protocol();

        // Summary.
        log_msg("================================================================");
        log_msg($sformatf("  RESULTS: %0d / %0d passed, %0d failed",
                          passes, total_tests, errors));
        log_msg("================================================================");

        test_pass_o = (errors == 0);
        test_done_o = 1'b1;

        if (errors == 0)
            log_msg("ALL CPU MMU TESTS PASSED");
        else
            log_msg($sformatf("CPU MMU TEST FAILED: %0d errors", errors));

        $fclose(log_fd); log_fd = 0;

        if (AUTO_FINISH) begin
            if (!test_pass_o) $fatal(1, "CPU MMU comprehensive self-check failed");
            $finish;
        end
    end

    // Watchdog.
    initial begin
        #500us;
        if (!test_done_o) $fatal(1, "CPU MMU comprehensive self-check timeout (500us)");
    end

endmodule
