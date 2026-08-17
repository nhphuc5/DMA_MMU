`timescale 1ns / 1ps

// Lightweight CPU-side MMU for the PicoRV32 AXI4-Lite master port.
//
// The module is intentionally smaller than the CVA6 MMU.  PicoRV32 does not
// implement the privileged CSRs, cache interfaces, or exception pipeline that
// the CVA6 Sv32/Sv39 page-table walker expects.  This block keeps the parts
// that are useful in this SoC:
//   * 4 KiB pages and virtual-to-physical translation
//   * software-managed, fully-associative page table
//   * fully-associative TLB with invalid-entry-first / pseudo-LRU replacement
//   * separate read, write, and execute permissions
//   * TLB invalidate, hit/miss counters, and sticky fault information
//
// Only CPU accesses pass through this block.  DMA accesses continue to use the
// independent DMA-side IOMMU.  The 0x1000_0000 DMA register window and the
// 0x2000_0000 UART window are physical MMIO and bypass translation.  The MMU
// control window at 0x3000_0000 is consumed locally and never reaches the
// system router.
module picorv32_cpu_mmu #(
    parameter int ADDR_WIDTH  = 32,
    parameter int DATA_WIDTH  = 32,
    parameter int PAGE_SHIFT  = 12,
    parameter int PT_ENTRIES  = 16,
    parameter int TLB_ENTRIES = 4,
    parameter logic [31:0] MMU_REG_BASE = 32'h3000_0000
) (
    input  logic clk_i,
    input  logic rst_ni,

    // PicoRV32-facing AXI4-Lite slave port
    input  logic [ADDR_WIDTH-1:0] s_axil_awaddr,
    input  logic [2:0]            s_axil_awprot,
    input  logic                  s_axil_awvalid,
    output logic                  s_axil_awready,
    input  logic [DATA_WIDTH-1:0] s_axil_wdata,
    input  logic [DATA_WIDTH/8-1:0] s_axil_wstrb,
    input  logic                  s_axil_wvalid,
    output logic                  s_axil_wready,
    output logic [1:0]            s_axil_bresp,
    output logic                  s_axil_bvalid,
    input  logic                  s_axil_bready,
    input  logic [ADDR_WIDTH-1:0] s_axil_araddr,
    input  logic [2:0]            s_axil_arprot,
    input  logic                  s_axil_arvalid,
    output logic                  s_axil_arready,
    output logic [DATA_WIDTH-1:0] s_axil_rdata,
    output logic [1:0]            s_axil_rresp,
    output logic                  s_axil_rvalid,
    input  logic                  s_axil_rready,

    // System-router-facing AXI4-Lite master port
    output logic [ADDR_WIDTH-1:0] m_axil_awaddr,
    output logic [2:0]            m_axil_awprot,
    output logic                  m_axil_awvalid,
    input  logic                  m_axil_awready,
    output logic [DATA_WIDTH-1:0] m_axil_wdata,
    output logic [DATA_WIDTH/8-1:0] m_axil_wstrb,
    output logic                  m_axil_wvalid,
    input  logic                  m_axil_wready,
    input  logic [1:0]            m_axil_bresp,
    input  logic                  m_axil_bvalid,
    output logic                  m_axil_bready,
    output logic [ADDR_WIDTH-1:0] m_axil_araddr,
    output logic [2:0]            m_axil_arprot,
    output logic                  m_axil_arvalid,
    input  logic                  m_axil_arready,
    input  logic [DATA_WIDTH-1:0] m_axil_rdata,
    input  logic [1:0]            m_axil_rresp,
    input  logic                  m_axil_rvalid,
    output logic                  m_axil_rready,

    output logic                  fault_irq_o,
    output logic                  enabled_o,
    output logic                  cpu_idle_o,
    output logic [31:0]           tlb_hit_count_o,
    output logic [31:0]           tlb_miss_count_o
);

    localparam int STRB_WIDTH = DATA_WIDTH/8;
    localparam int VPN_WIDTH  = ADDR_WIDTH-PAGE_SHIFT;
    localparam int PT_IDX_W   = $clog2(PT_ENTRIES);
    localparam int TLB_IDX_W  = $clog2(TLB_ENTRIES);
    localparam logic [7:0] PT_ENTRIES_U8  = PT_ENTRIES;
    localparam logic [7:0] TLB_ENTRIES_U8 = TLB_ENTRIES;
    localparam logic [7:0] PAGE_SHIFT_U8  = PAGE_SHIFT;

    localparam logic [2:0] FAULT_NONE  = 3'd0;
    localparam logic [2:0] FAULT_PAGE  = 3'd1;
    localparam logic [2:0] FAULT_READ  = 3'd2;
    localparam logic [2:0] FAULT_WRITE = 3'd3;
    localparam logic [2:0] FAULT_EXEC  = 3'd4;

    // MMU register offsets.
    localparam logic [7:0] REG_PT_INDEX = 8'h00;
    localparam logic [7:0] REG_PT_VPN   = 8'h04;
    localparam logic [7:0] REG_PT_PPN   = 8'h08;
    localparam logic [7:0] REG_PT_FLAGS = 8'h0c;
    localparam logic [7:0] REG_TLB_CTRL = 8'h10;
    localparam logic [7:0] REG_CONTROL  = 8'h14;
    localparam logic [7:0] REG_STATUS   = 8'h18;
    localparam logic [7:0] REG_FAULT_VA = 8'h1c;
    localparam logic [7:0] REG_TLB_HITS = 8'h20;
    localparam logic [7:0] REG_TLB_MISS = 8'h24;
    localparam logic [7:0] REG_CONFIG   = 8'h28;

    // Page-table entry flags: bit0 valid, bit1 read, bit2 write, bit3 execute.
    logic [VPN_WIDTH-1:0] pt_vpn_q [0:PT_ENTRIES-1];
    logic [VPN_WIDTH-1:0] pt_ppn_q [0:PT_ENTRIES-1];
    logic                 pt_valid_q [0:PT_ENTRIES-1];
    logic                 pt_read_q  [0:PT_ENTRIES-1];
    logic                 pt_write_q [0:PT_ENTRIES-1];
    logic                 pt_exec_q  [0:PT_ENTRIES-1];

    logic [VPN_WIDTH-1:0] tlb_vpn_q [0:TLB_ENTRIES-1];
    logic [VPN_WIDTH-1:0] tlb_ppn_q [0:TLB_ENTRIES-1];
    logic                 tlb_valid_q [0:TLB_ENTRIES-1];
    logic                 tlb_read_q  [0:TLB_ENTRIES-1];
    logic                 tlb_write_q [0:TLB_ENTRIES-1];
    logic                 tlb_exec_q  [0:TLB_ENTRIES-1];

    logic [PT_IDX_W-1:0] pt_index_q;
    logic [VPN_WIDTH-1:0] pt_stage_vpn_q;
    logic [VPN_WIDTH-1:0] pt_stage_ppn_q;
    logic mmu_enable_q;
    logic fault_pending_q;
    logic [2:0] fault_code_q;
    logic [ADDR_WIDTH-1:0] fault_vaddr_q;
    logic [31:0] tlb_hit_count_q;
    logic [31:0] tlb_miss_count_q;

    logic plru_access_q;
    logic [TLB_IDX_W-1:0] plru_access_idx_q;
    logic [TLB_IDX_W-1:0] plru_replace_idx;

    pseudoLRU #(
        .ENTRIES(TLB_ENTRIES)
    ) cpu_tlb_plru (
        .clk_i(clk_i),
        .rstn_i(rst_ni),
        .access_hit_i(plru_access_q),
        .access_idx_i(plru_access_idx_q),
        .replacement_idx_o(plru_replace_idx)
    );

    function automatic logic is_mmu_register(input logic [ADDR_WIDTH-1:0] addr);
        is_mmu_register = addr[31:8] == MMU_REG_BASE[31:8];
    endfunction

    // This SoC uses the upper address regions as physical MMIO.  Keeping them
    // untranslated lets bare-metal firmware configure DMA, IOMMU, and UART
    // even after CPU virtual-memory translation is enabled.
    function automatic logic is_mmio_bypass(input logic [ADDR_WIDTH-1:0] addr);
        is_mmio_bypass = addr[31:28] != 4'h0;
    endfunction

    typedef enum logic [2:0] {
        W_COLLECT,
        W_CLASSIFY,
        W_LOOKUP,
        W_TLB_RESULT,
        W_PT_RESULT,
        W_SEND,
        W_WAIT_B,
        W_LOCAL_B
    } wstate_t;

    typedef enum logic [2:0] {
        R_IDLE,
        R_CLASSIFY,
        R_LOOKUP,
        R_TLB_RESULT,
        R_PT_RESULT,
        R_SEND,
        R_WAIT_R,
        R_LOCAL_R
    } rstate_t;

    wstate_t wstate_q;
    rstate_t rstate_q;

    logic [ADDR_WIDTH-1:0] wr_vaddr_q, wr_paddr_q;
    logic [2:0] wr_prot_q;
    logic [DATA_WIDTH-1:0] wr_data_q;
    logic [STRB_WIDTH-1:0] wr_strb_q;
    logic aw_hold_q, w_hold_q;
    logic aw_sent_q, w_sent_q;
    logic [1:0] local_bresp_q;
    logic wr_tlb_hit_q;
    logic [TLB_IDX_W-1:0] wr_tlb_idx_q;
    logic wr_tlb_perm_q;
    logic wr_pt_hit_q;
    logic [PT_IDX_W-1:0] wr_pt_idx_q;
    logic wr_pt_perm_q;

    logic [ADDR_WIDTH-1:0] rd_vaddr_q, rd_paddr_q;
    logic [2:0] rd_prot_q;
    logic [DATA_WIDTH-1:0] local_rdata_q;
    logic [1:0] local_rresp_q;
    logic rd_tlb_hit_q;
    logic [TLB_IDX_W-1:0] rd_tlb_idx_q;
    logic rd_tlb_perm_q;
    logic rd_pt_hit_q;
    logic [PT_IDX_W-1:0] rd_pt_idx_q;
    logic rd_pt_perm_q;

    // Parallel TLB/page-table lookup results for the current write address.
    logic wr_tlb_hit, wr_pt_hit;
    logic [TLB_IDX_W-1:0] wr_tlb_idx;
    logic [PT_IDX_W-1:0] wr_pt_idx;
    logic wr_tlb_perm, wr_pt_perm;

    // Parallel TLB/page-table lookup results for the current read/fetch.
    logic rd_tlb_hit, rd_pt_hit;
    logic [TLB_IDX_W-1:0] rd_tlb_idx;
    logic [PT_IDX_W-1:0] rd_pt_idx;
    logic rd_tlb_perm, rd_pt_perm;

    logic tlb_has_invalid;
    logic [TLB_IDX_W-1:0] tlb_invalid_idx;
    logic [TLB_IDX_W-1:0] tlb_fill_idx;

    always_comb begin
        wr_tlb_hit = 1'b0;
        wr_tlb_idx = '0;
        wr_tlb_perm = 1'b0;
        for (int unsigned i = 0; i < TLB_ENTRIES; i++) begin
            if (!wr_tlb_hit && tlb_valid_q[i]
                    && tlb_vpn_q[i] == wr_vaddr_q[ADDR_WIDTH-1:PAGE_SHIFT]) begin
                wr_tlb_hit = 1'b1;
                wr_tlb_idx = i[TLB_IDX_W-1:0];
                wr_tlb_perm = tlb_write_q[i];
            end
        end

        wr_pt_hit = 1'b0;
        wr_pt_idx = '0;
        wr_pt_perm = 1'b0;
        for (int unsigned i = 0; i < PT_ENTRIES; i++) begin
            if (!wr_pt_hit && pt_valid_q[i]
                    && pt_vpn_q[i] == wr_vaddr_q[ADDR_WIDTH-1:PAGE_SHIFT]) begin
                wr_pt_hit = 1'b1;
                wr_pt_idx = i[PT_IDX_W-1:0];
                wr_pt_perm = pt_write_q[i];
            end
        end

        rd_tlb_hit = 1'b0;
        rd_tlb_idx = '0;
        rd_tlb_perm = 1'b0;
        for (int unsigned i = 0; i < TLB_ENTRIES; i++) begin
            if (!rd_tlb_hit && tlb_valid_q[i]
                    && tlb_vpn_q[i] == rd_vaddr_q[ADDR_WIDTH-1:PAGE_SHIFT]) begin
                rd_tlb_hit = 1'b1;
                rd_tlb_idx = i[TLB_IDX_W-1:0];
                rd_tlb_perm = rd_prot_q[2] ? tlb_exec_q[i] : tlb_read_q[i];
            end
        end

        rd_pt_hit = 1'b0;
        rd_pt_idx = '0;
        rd_pt_perm = 1'b0;
        for (int unsigned i = 0; i < PT_ENTRIES; i++) begin
            if (!rd_pt_hit && pt_valid_q[i]
                    && pt_vpn_q[i] == rd_vaddr_q[ADDR_WIDTH-1:PAGE_SHIFT]) begin
                rd_pt_hit = 1'b1;
                rd_pt_idx = i[PT_IDX_W-1:0];
                rd_pt_perm = rd_prot_q[2] ? pt_exec_q[i] : pt_read_q[i];
            end
        end

        tlb_has_invalid = 1'b0;
        tlb_invalid_idx = '0;
        for (int unsigned i = 0; i < TLB_ENTRIES; i++) begin
            if (!tlb_has_invalid && !tlb_valid_q[i]) begin
                tlb_has_invalid = 1'b1;
                tlb_invalid_idx = i[TLB_IDX_W-1:0];
            end
        end
        tlb_fill_idx = tlb_has_invalid ? tlb_invalid_idx : plru_replace_idx;
    end

    // AXI4-Lite combinational interface.  Address and data are held in
    // registers before translation, which keeps the associative lookup off
    // the PicoRV32 ready path and helps preserve system Fmax.
    always_comb begin
        s_axil_awready = (wstate_q == W_COLLECT) && !aw_hold_q;
        s_axil_wready  = (wstate_q == W_COLLECT) && !w_hold_q;
        s_axil_bvalid  = 1'b0;
        s_axil_bresp   = 2'b00;
        s_axil_arready = (rstate_q == R_IDLE);
        s_axil_rvalid  = 1'b0;
        s_axil_rdata   = '0;
        s_axil_rresp   = 2'b00;

        m_axil_awaddr  = wr_paddr_q;
        m_axil_awprot  = wr_prot_q;
        m_axil_awvalid = (wstate_q == W_SEND) && !aw_sent_q;
        m_axil_wdata   = wr_data_q;
        m_axil_wstrb   = wr_strb_q;
        m_axil_wvalid  = (wstate_q == W_SEND) && !w_sent_q;
        m_axil_bready  = (wstate_q == W_WAIT_B) && s_axil_bready;

        m_axil_araddr  = rd_paddr_q;
        m_axil_arprot  = rd_prot_q;
        m_axil_arvalid = (rstate_q == R_SEND);
        m_axil_rready  = (rstate_q == R_WAIT_R) && s_axil_rready;

        if (wstate_q == W_WAIT_B) begin
            s_axil_bvalid = m_axil_bvalid;
            s_axil_bresp  = m_axil_bresp;
        end else if (wstate_q == W_LOCAL_B) begin
            s_axil_bvalid = 1'b1;
            s_axil_bresp  = local_bresp_q;
        end

        if (rstate_q == R_WAIT_R) begin
            s_axil_rvalid = m_axil_rvalid;
            s_axil_rdata  = m_axil_rdata;
            s_axil_rresp  = m_axil_rresp;
        end else if (rstate_q == R_LOCAL_R) begin
            s_axil_rvalid = 1'b1;
            s_axil_rdata  = local_rdata_q;
            s_axil_rresp  = local_rresp_q;
        end

        cpu_idle_o = (wstate_q == W_COLLECT) && !aw_hold_q && !w_hold_q
                  && (rstate_q == R_IDLE)
                  && !s_axil_awvalid && !s_axil_wvalid && !s_axil_arvalid;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : cpu_mmu_state
        integer i;
        if (!rst_ni) begin
            wstate_q <= W_COLLECT;
            rstate_q <= R_IDLE;
            wr_vaddr_q <= '0;
            wr_paddr_q <= '0;
            wr_prot_q <= '0;
            wr_data_q <= '0;
            wr_strb_q <= '0;
            aw_hold_q <= 1'b0;
            w_hold_q <= 1'b0;
            aw_sent_q <= 1'b0;
            w_sent_q <= 1'b0;
            local_bresp_q <= 2'b00;
            wr_tlb_hit_q <= 1'b0;
            wr_tlb_idx_q <= '0;
            wr_tlb_perm_q <= 1'b0;
            wr_pt_hit_q <= 1'b0;
            wr_pt_idx_q <= '0;
            wr_pt_perm_q <= 1'b0;
            rd_vaddr_q <= '0;
            rd_paddr_q <= '0;
            rd_prot_q <= '0;
            local_rdata_q <= '0;
            local_rresp_q <= 2'b00;
            rd_tlb_hit_q <= 1'b0;
            rd_tlb_idx_q <= '0;
            rd_tlb_perm_q <= 1'b0;
            rd_pt_hit_q <= 1'b0;
            rd_pt_idx_q <= '0;
            rd_pt_perm_q <= 1'b0;
            pt_index_q <= '0;
            pt_stage_vpn_q <= '0;
            pt_stage_ppn_q <= '0;
            mmu_enable_q <= 1'b0;
            fault_pending_q <= 1'b0;
            fault_code_q <= FAULT_NONE;
            fault_vaddr_q <= '0;
            fault_irq_o <= 1'b0;
            tlb_hit_count_q <= '0;
            tlb_miss_count_q <= '0;
            plru_access_q <= 1'b0;
            plru_access_idx_q <= '0;
            for (i = 0; i < PT_ENTRIES; i = i + 1) begin
                pt_vpn_q[i] <= '0;
                pt_ppn_q[i] <= '0;
                pt_valid_q[i] <= 1'b0;
                pt_read_q[i] <= 1'b0;
                pt_write_q[i] <= 1'b0;
                pt_exec_q[i] <= 1'b0;
            end
            for (i = 0; i < TLB_ENTRIES; i = i + 1) begin
                tlb_vpn_q[i] <= '0;
                tlb_ppn_q[i] <= '0;
                tlb_valid_q[i] <= 1'b0;
                tlb_read_q[i] <= 1'b0;
                tlb_write_q[i] <= 1'b0;
                tlb_exec_q[i] <= 1'b0;
            end
        end else begin
            plru_access_q <= 1'b0;

            // ------------------------- Write path -------------------------
            case (wstate_q)
                W_COLLECT: begin
                    if (s_axil_awvalid && s_axil_awready) begin
                        wr_vaddr_q <= s_axil_awaddr;
                        wr_prot_q <= s_axil_awprot;
                        aw_hold_q <= 1'b1;
                    end
                    if (s_axil_wvalid && s_axil_wready) begin
                        wr_data_q <= s_axil_wdata;
                        wr_strb_q <= s_axil_wstrb;
                        w_hold_q <= 1'b1;
                    end
                    if (aw_hold_q && w_hold_q)
                        wstate_q <= W_CLASSIFY;
                end

                W_CLASSIFY: begin
                    local_bresp_q <= 2'b00;
                    if (is_mmu_register(wr_vaddr_q)) begin
                        case (wr_vaddr_q[7:0])
                            REG_PT_INDEX: pt_index_q <= wr_data_q[PT_IDX_W-1:0];
                            REG_PT_VPN:   pt_stage_vpn_q <= wr_data_q[VPN_WIDTH-1:0];
                            REG_PT_PPN:   pt_stage_ppn_q <= wr_data_q[VPN_WIDTH-1:0];
                            REG_PT_FLAGS: begin
                                pt_vpn_q[pt_index_q] <= pt_stage_vpn_q;
                                pt_ppn_q[pt_index_q] <= pt_stage_ppn_q;
                                pt_valid_q[pt_index_q] <= wr_data_q[0];
                                pt_read_q[pt_index_q] <= wr_data_q[1];
                                pt_write_q[pt_index_q] <= wr_data_q[2];
                                pt_exec_q[pt_index_q] <= wr_data_q[3];
                                // Updating a PTE invalidates cached copies.
                                for (i = 0; i < TLB_ENTRIES; i = i + 1)
                                    tlb_valid_q[i] <= 1'b0;
                            end
                            REG_TLB_CTRL: begin
                                if (wr_data_q[0]) begin
                                    for (i = 0; i < TLB_ENTRIES; i = i + 1)
                                        tlb_valid_q[i] <= 1'b0;
                                end
                                if (wr_data_q[1]) begin
                                    tlb_hit_count_q <= '0;
                                    tlb_miss_count_q <= '0;
                                end
                                if (wr_data_q[2]) begin
                                    fault_pending_q <= 1'b0;
                                    fault_code_q <= FAULT_NONE;
                                    fault_irq_o <= 1'b0;
                                end
                            end
                            REG_CONTROL: mmu_enable_q <= wr_data_q[0];
                            default: local_bresp_q <= 2'b11;
                        endcase
                        wstate_q <= W_LOCAL_B;
                    end else if (!mmu_enable_q || is_mmio_bypass(wr_vaddr_q)) begin
                        wr_paddr_q <= wr_vaddr_q;
                        aw_sent_q <= 1'b0;
                        w_sent_q <= 1'b0;
                        wstate_q <= W_SEND;
                    end else begin
                        wstate_q <= W_LOOKUP;
                    end
                end

                W_LOOKUP: begin
                    // Register the four-entry TLB comparison before updating
                    // state/fault registers.  The added stage is paid by every
                    // translated access but removes the last critical
                    // associative-compare control path at 150 MHz.
                    wr_tlb_hit_q <= wr_tlb_hit;
                    wr_tlb_idx_q <= wr_tlb_idx;
                    wr_tlb_perm_q <= wr_tlb_perm;
                    wstate_q <= W_TLB_RESULT;
                end

                W_TLB_RESULT: begin
                    if (wr_tlb_hit_q) begin
                        tlb_hit_count_q <= tlb_hit_count_q + 1;
                        plru_access_q <= 1'b1;
                        plru_access_idx_q <= wr_tlb_idx_q;
                        if (wr_tlb_perm_q) begin
                            wr_paddr_q <= {tlb_ppn_q[wr_tlb_idx_q],
                                          wr_vaddr_q[PAGE_SHIFT-1:0]};
                            aw_sent_q <= 1'b0;
                            w_sent_q <= 1'b0;
                            wstate_q <= W_SEND;
                        end else begin
                            local_bresp_q <= 2'b11;
                            fault_pending_q <= 1'b1;
                            fault_code_q <= FAULT_WRITE;
                            fault_vaddr_q <= wr_vaddr_q;
                            fault_irq_o <= 1'b1;
                            wstate_q <= W_LOCAL_B;
                        end
                    end else begin
                        tlb_miss_count_q <= tlb_miss_count_q + 1;
                        // Register the 16-entry associative PT result before
                        // updating the TLB.  This extra miss-only stage removes
                        // the long VA -> PT compare -> TLB write path without
                        // changing mappings, permissions, or hit behaviour.
                        wr_pt_hit_q <= wr_pt_hit;
                        wr_pt_idx_q <= wr_pt_idx;
                        wr_pt_perm_q <= wr_pt_perm;
                        wstate_q <= W_PT_RESULT;
                    end
                end

                W_PT_RESULT: begin
                        if (wr_pt_hit_q) begin
                            tlb_vpn_q[tlb_fill_idx] <= pt_vpn_q[wr_pt_idx_q];
                            tlb_ppn_q[tlb_fill_idx] <= pt_ppn_q[wr_pt_idx_q];
                            tlb_valid_q[tlb_fill_idx] <= pt_valid_q[wr_pt_idx_q];
                            tlb_read_q[tlb_fill_idx] <= pt_read_q[wr_pt_idx_q];
                            tlb_write_q[tlb_fill_idx] <= pt_write_q[wr_pt_idx_q];
                            tlb_exec_q[tlb_fill_idx] <= pt_exec_q[wr_pt_idx_q];
                            plru_access_q <= 1'b1;
                            plru_access_idx_q <= tlb_fill_idx;
                            if (wr_pt_perm_q) begin
                                wr_paddr_q <= {pt_ppn_q[wr_pt_idx_q],
                                              wr_vaddr_q[PAGE_SHIFT-1:0]};
                                aw_sent_q <= 1'b0;
                                w_sent_q <= 1'b0;
                                wstate_q <= W_SEND;
                            end else begin
                                local_bresp_q <= 2'b11;
                                fault_pending_q <= 1'b1;
                                fault_code_q <= FAULT_WRITE;
                                fault_vaddr_q <= wr_vaddr_q;
                                fault_irq_o <= 1'b1;
                                wstate_q <= W_LOCAL_B;
                            end
                        end else begin
                            local_bresp_q <= 2'b11;
                            fault_pending_q <= 1'b1;
                            fault_code_q <= FAULT_PAGE;
                            fault_vaddr_q <= wr_vaddr_q;
                            fault_irq_o <= 1'b1;
                            wstate_q <= W_LOCAL_B;
                        end
                end

                W_SEND: begin
                    if (m_axil_awvalid && m_axil_awready)
                        aw_sent_q <= 1'b1;
                    if (m_axil_wvalid && m_axil_wready)
                        w_sent_q <= 1'b1;
                    if ((aw_sent_q || (m_axil_awvalid && m_axil_awready))
                            && (w_sent_q || (m_axil_wvalid && m_axil_wready)))
                        wstate_q <= W_WAIT_B;
                end

                W_WAIT_B: begin
                    if (m_axil_bvalid && s_axil_bready) begin
                        aw_hold_q <= 1'b0;
                        w_hold_q <= 1'b0;
                        aw_sent_q <= 1'b0;
                        w_sent_q <= 1'b0;
                        wstate_q <= W_COLLECT;
                    end
                end

                default: begin // W_LOCAL_B
                    if (s_axil_bvalid && s_axil_bready) begin
                        aw_hold_q <= 1'b0;
                        w_hold_q <= 1'b0;
                        wstate_q <= W_COLLECT;
                    end
                end
            endcase

            // -------------------------- Read path -------------------------
            case (rstate_q)
                R_IDLE: begin
                    if (s_axil_arvalid && s_axil_arready) begin
                        rd_vaddr_q <= s_axil_araddr;
                        rd_prot_q <= s_axil_arprot;
                        rstate_q <= R_CLASSIFY;
                    end
                end

                R_CLASSIFY: begin
                    local_rresp_q <= 2'b00;
                    if (is_mmu_register(rd_vaddr_q)) begin
                        case (rd_vaddr_q[7:0])
                            REG_PT_INDEX: local_rdata_q <= {{(DATA_WIDTH-PT_IDX_W){1'b0}}, pt_index_q};
                            REG_PT_VPN:   local_rdata_q <= {{(DATA_WIDTH-VPN_WIDTH){1'b0}}, pt_vpn_q[pt_index_q]};
                            REG_PT_PPN:   local_rdata_q <= {{(DATA_WIDTH-VPN_WIDTH){1'b0}}, pt_ppn_q[pt_index_q]};
                            REG_PT_FLAGS: local_rdata_q <= {{(DATA_WIDTH-4){1'b0}},
                                pt_exec_q[pt_index_q], pt_write_q[pt_index_q],
                                pt_read_q[pt_index_q], pt_valid_q[pt_index_q]};
                            REG_CONTROL: local_rdata_q <= {{(DATA_WIDTH-1){1'b0}}, mmu_enable_q};
                            REG_STATUS: local_rdata_q <= {{(DATA_WIDTH-5){1'b0}},
                                fault_code_q, fault_pending_q, mmu_enable_q};
                            REG_FAULT_VA: local_rdata_q <= fault_vaddr_q;
                            REG_TLB_HITS: local_rdata_q <= tlb_hit_count_q;
                            REG_TLB_MISS: local_rdata_q <= tlb_miss_count_q;
                            REG_CONFIG: local_rdata_q <= {PT_ENTRIES_U8, TLB_ENTRIES_U8,
                                                         PAGE_SHIFT_U8, 8'h01};
                            default: begin
                                local_rdata_q <= 32'hDEAD_BEEF;
                                local_rresp_q <= 2'b11;
                            end
                        endcase
                        rstate_q <= R_LOCAL_R;
                    end else if (!mmu_enable_q || is_mmio_bypass(rd_vaddr_q)) begin
                        rd_paddr_q <= rd_vaddr_q;
                        rstate_q <= R_SEND;
                    end else begin
                        rstate_q <= R_LOOKUP;
                    end
                end

                R_LOOKUP: begin
                    rd_tlb_hit_q <= rd_tlb_hit;
                    rd_tlb_idx_q <= rd_tlb_idx;
                    rd_tlb_perm_q <= rd_tlb_perm;
                    rstate_q <= R_TLB_RESULT;
                end

                R_TLB_RESULT: begin
                    if (rd_tlb_hit_q) begin
                        tlb_hit_count_q <= tlb_hit_count_q + 1;
                        plru_access_q <= 1'b1;
                        plru_access_idx_q <= rd_tlb_idx_q;
                        if (rd_tlb_perm_q) begin
                            rd_paddr_q <= {tlb_ppn_q[rd_tlb_idx_q],
                                          rd_vaddr_q[PAGE_SHIFT-1:0]};
                            rstate_q <= R_SEND;
                        end else begin
                            local_rdata_q <= 32'hDEAD_BEEF;
                            local_rresp_q <= 2'b11;
                            fault_pending_q <= 1'b1;
                            fault_code_q <= rd_prot_q[2] ? FAULT_EXEC : FAULT_READ;
                            fault_vaddr_q <= rd_vaddr_q;
                            fault_irq_o <= 1'b1;
                            rstate_q <= R_LOCAL_R;
                        end
                    end else begin
                        tlb_miss_count_q <= tlb_miss_count_q + 1;
                        rd_pt_hit_q <= rd_pt_hit;
                        rd_pt_idx_q <= rd_pt_idx;
                        rd_pt_perm_q <= rd_pt_perm;
                        rstate_q <= R_PT_RESULT;
                    end
                end

                R_PT_RESULT: begin
                        if (rd_pt_hit_q) begin
                            tlb_vpn_q[tlb_fill_idx] <= pt_vpn_q[rd_pt_idx_q];
                            tlb_ppn_q[tlb_fill_idx] <= pt_ppn_q[rd_pt_idx_q];
                            tlb_valid_q[tlb_fill_idx] <= pt_valid_q[rd_pt_idx_q];
                            tlb_read_q[tlb_fill_idx] <= pt_read_q[rd_pt_idx_q];
                            tlb_write_q[tlb_fill_idx] <= pt_write_q[rd_pt_idx_q];
                            tlb_exec_q[tlb_fill_idx] <= pt_exec_q[rd_pt_idx_q];
                            plru_access_q <= 1'b1;
                            plru_access_idx_q <= tlb_fill_idx;
                            if (rd_pt_perm_q) begin
                                rd_paddr_q <= {pt_ppn_q[rd_pt_idx_q],
                                              rd_vaddr_q[PAGE_SHIFT-1:0]};
                                rstate_q <= R_SEND;
                            end else begin
                                local_rdata_q <= 32'hDEAD_BEEF;
                                local_rresp_q <= 2'b11;
                                fault_pending_q <= 1'b1;
                                fault_code_q <= rd_prot_q[2] ? FAULT_EXEC : FAULT_READ;
                                fault_vaddr_q <= rd_vaddr_q;
                                fault_irq_o <= 1'b1;
                                rstate_q <= R_LOCAL_R;
                            end
                        end else begin
                            local_rdata_q <= 32'hDEAD_BEEF;
                            local_rresp_q <= 2'b11;
                            fault_pending_q <= 1'b1;
                            fault_code_q <= FAULT_PAGE;
                            fault_vaddr_q <= rd_vaddr_q;
                            fault_irq_o <= 1'b1;
                            rstate_q <= R_LOCAL_R;
                        end
                end

                R_SEND: begin
                    if (m_axil_arvalid && m_axil_arready)
                        rstate_q <= R_WAIT_R;
                end

                R_WAIT_R: begin
                    if (m_axil_rvalid && s_axil_rready)
                        rstate_q <= R_IDLE;
                end

                default: begin // R_LOCAL_R
                    if (s_axil_rvalid && s_axil_rready)
                        rstate_q <= R_IDLE;
                end
            endcase
        end
    end

    assign enabled_o = mmu_enable_q;
    assign tlb_hit_count_o = tlb_hit_count_q;
    assign tlb_miss_count_o = tlb_miss_count_q;

    initial begin
        if (ADDR_WIDTH != 32 || DATA_WIDTH != 32)
            $error("picorv32_cpu_mmu currently requires 32-bit AXI address/data");
        if ((1 << TLB_IDX_W) != TLB_ENTRIES)
            $error("TLB_ENTRIES must be a power of two");
    end

endmodule
