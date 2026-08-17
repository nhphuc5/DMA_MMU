`timescale 1ns / 1ps

// DMA-side IOMMU for the AXI project.
//
// The page table is a small software-programmable, fully-associative table.
// A fully-associative TLB caches translations.  On a miss the page table is
// searched, the translation is installed in an invalid TLB entry or in the
// pseudo-LRU victim, and the request is checked for read/write permission.
// Requests must stay inside one 4 KiB page; the DMA scheduler splits larger
// commands at page boundaries.
module dma_iommu_tlb #(
    parameter int ADDR_WIDTH  = 16,
    parameter int LEN_WIDTH   = 20,
    parameter int PAGE_SHIFT  = 12,
    parameter int PT_ENTRIES  = 16,
    parameter int TLB_ENTRIES = 4
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,

    input  logic                         req_valid_i,
    output logic                         req_ready_o,
    input  logic [ADDR_WIDTH-1:0]        req_vaddr_i,
    input  logic [LEN_WIDTH-1:0]         req_len_bytes_i,
    input  logic                         req_write_i,

    output logic                         resp_valid_o,
    output logic                         resp_allow_o,
    output logic [ADDR_WIDTH-1:0]        resp_paddr_o,
    output logic [2:0]                   resp_fault_o,

    input  logic                         pt_write_i,
    input  logic [$clog2(PT_ENTRIES)-1:0] pt_index_i,
    input  logic [ADDR_WIDTH-PAGE_SHIFT-1:0] pt_vpn_i,
    input  logic [ADDR_WIDTH-PAGE_SHIFT-1:0] pt_ppn_i,
    input  logic                         pt_valid_i,
    input  logic                         pt_read_i,
    input  logic                         pt_write_perm_i,
    input  logic                         tlb_invalidate_i,

    output logic [31:0]                  tlb_hit_count_o,
    output logic [31:0]                  tlb_miss_count_o
);

    localparam int VPN_WIDTH = ADDR_WIDTH-PAGE_SHIFT;
    localparam int TLB_INDEX_WIDTH = $clog2(TLB_ENTRIES);

    localparam logic [2:0] IOMMU_FAULT_NONE       = 3'd0;
    localparam logic [2:0] IOMMU_FAULT_PAGE       = 3'd1;
    localparam logic [2:0] IOMMU_FAULT_PERMISSION = 3'd2;
    localparam logic [2:0] IOMMU_FAULT_RANGE      = 3'd3;

    // The associative compare and the selected-entry data mux are deliberately
    // split across two cycles.  This keeps the same request/response protocol
    // while removing the long VPN-compare -> priority -> PPN-mux path.
    typedef enum logic [1:0] {
        LOOKUP_IDLE,
        LOOKUP_MATCH,
        LOOKUP_RESP
    } lookup_state_t;
    lookup_state_t state_q;

    logic [VPN_WIDTH-1:0] pt_vpn_q [0:PT_ENTRIES-1];
    logic [VPN_WIDTH-1:0] pt_ppn_q [0:PT_ENTRIES-1];
    logic                 pt_valid_q [0:PT_ENTRIES-1];
    logic                 pt_read_q [0:PT_ENTRIES-1];
    logic                 pt_write_q [0:PT_ENTRIES-1];

    logic [VPN_WIDTH-1:0] tlb_vpn_q [0:TLB_ENTRIES-1];
    logic [VPN_WIDTH-1:0] tlb_ppn_q [0:TLB_ENTRIES-1];
    logic                 tlb_valid_q [0:TLB_ENTRIES-1];
    logic                 tlb_read_q [0:TLB_ENTRIES-1];
    logic                 tlb_write_q [0:TLB_ENTRIES-1];

    logic [ADDR_WIDTH-1:0] req_vaddr_q;
    logic [LEN_WIDTH-1:0]  req_len_q;
    logic                  req_write_q;

    logic                  tlb_hit;
    logic [TLB_INDEX_WIDTH-1:0] tlb_hit_index;
    logic                  pt_hit;
    logic [$clog2(PT_ENTRIES)-1:0] pt_hit_index;
    logic                  has_invalid_tlb;
    logic [TLB_INDEX_WIDTH-1:0] invalid_tlb_index;
    logic [TLB_INDEX_WIDTH-1:0] plru_replace_index;
    logic [TLB_INDEX_WIDTH-1:0] fill_index;
    logic                  plru_access;
    logic [TLB_INDEX_WIDTH-1:0] plru_access_index;

    logic                  match_range_ok_q;
    logic                  match_tlb_hit_q;
    logic [TLB_INDEX_WIDTH-1:0] match_tlb_index_q;
    logic                  match_pt_hit_q;
    logic [$clog2(PT_ENTRIES)-1:0] match_pt_index_q;
    logic [TLB_INDEX_WIDTH-1:0] match_fill_index_q;

    logic [ADDR_WIDTH:0] req_end_ext;
    logic range_ok;
    logic resp_selected_read;
    logic resp_selected_write;
    logic [VPN_WIDTH-1:0] resp_selected_ppn;
    logic resp_permission_ok;

    integer i;

    assign req_ready_o = (state_q == LOOKUP_IDLE);

    always_comb begin
        tlb_hit = 1'b0;
        tlb_hit_index = '0;
        for (int unsigned n = 0; n < TLB_ENTRIES; n++) begin
            if (!tlb_hit && tlb_valid_q[n]
                && tlb_vpn_q[n] == req_vaddr_q[ADDR_WIDTH-1:PAGE_SHIFT]) begin
                tlb_hit = 1'b1;
                tlb_hit_index = n[TLB_INDEX_WIDTH-1:0];
            end
        end

        pt_hit = 1'b0;
        pt_hit_index = '0;
        for (int unsigned n = 0; n < PT_ENTRIES; n++) begin
            if (!pt_hit && pt_valid_q[n]
                && pt_vpn_q[n] == req_vaddr_q[ADDR_WIDTH-1:PAGE_SHIFT]) begin
                pt_hit = 1'b1;
                pt_hit_index = n[$clog2(PT_ENTRIES)-1:0];
            end
        end

        has_invalid_tlb = 1'b0;
        invalid_tlb_index = '0;
        for (int unsigned n = 0; n < TLB_ENTRIES; n++) begin
            if (!has_invalid_tlb && !tlb_valid_q[n]) begin
                has_invalid_tlb = 1'b1;
                invalid_tlb_index = n[TLB_INDEX_WIDTH-1:0];
            end
        end

        fill_index = has_invalid_tlb ? invalid_tlb_index : plru_replace_index;

        req_end_ext = {1'b0, req_vaddr_q};
        if (req_len_q != 0)
            req_end_ext = {1'b0, req_vaddr_q} + req_len_q - 1'b1;

        range_ok = (req_len_q != 0)
                && !req_end_ext[ADDR_WIDTH]
                && (req_vaddr_q[ADDR_WIDTH-1:PAGE_SHIFT]
                    == req_end_ext[ADDR_WIDTH-1:PAGE_SHIFT]);

        // Entry data is selected only after the match indices have been
        // registered.  This is the second, short lookup pipeline stage.
        resp_selected_ppn = '0;
        resp_selected_read = 1'b0;
        resp_selected_write = 1'b0;
        if (match_tlb_hit_q) begin
            resp_selected_ppn = tlb_ppn_q[match_tlb_index_q];
            resp_selected_read = tlb_read_q[match_tlb_index_q];
            resp_selected_write = tlb_write_q[match_tlb_index_q];
        end else if (match_pt_hit_q) begin
            resp_selected_ppn = pt_ppn_q[match_pt_index_q];
            resp_selected_read = pt_read_q[match_pt_index_q];
            resp_selected_write = pt_write_q[match_pt_index_q];
        end
        resp_permission_ok = req_write_q ? resp_selected_write
                                         : resp_selected_read;

        plru_access = (state_q == LOOKUP_RESP) && match_range_ok_q
                   && (match_tlb_hit_q || match_pt_hit_q);
        plru_access_index = match_tlb_hit_q ? match_tlb_index_q
                                            : match_fill_index_q;
    end

    pseudoLRU #(
        .ENTRIES(TLB_ENTRIES)
    ) tlb_replacement (
        .clk_i(clk_i),
        .rstn_i(rst_ni),
        .access_hit_i(plru_access),
        .access_idx_i(plru_access_index),
        .replacement_idx_o(plru_replace_index)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= LOOKUP_IDLE;
            req_vaddr_q <= '0;
            req_len_q <= '0;
            req_write_q <= 1'b0;
            match_range_ok_q <= 1'b0;
            match_tlb_hit_q <= 1'b0;
            match_tlb_index_q <= '0;
            match_pt_hit_q <= 1'b0;
            match_pt_index_q <= '0;
            match_fill_index_q <= '0;
            resp_valid_o <= 1'b0;
            resp_allow_o <= 1'b0;
            resp_paddr_o <= '0;
            resp_fault_o <= IOMMU_FAULT_NONE;
            tlb_hit_count_o <= '0;
            tlb_miss_count_o <= '0;
            for (i = 0; i < PT_ENTRIES; i = i + 1) begin
                pt_vpn_q[i] <= '0;
                pt_ppn_q[i] <= '0;
                pt_valid_q[i] <= 1'b0;
                pt_read_q[i] <= 1'b0;
                pt_write_q[i] <= 1'b0;
            end
            for (i = 0; i < TLB_ENTRIES; i = i + 1) begin
                tlb_vpn_q[i] <= '0;
                tlb_ppn_q[i] <= '0;
                tlb_valid_q[i] <= 1'b0;
                tlb_read_q[i] <= 1'b0;
                tlb_write_q[i] <= 1'b0;
            end
        end else begin
            resp_valid_o <= 1'b0;

            if (pt_write_i) begin
                pt_vpn_q[pt_index_i] <= pt_vpn_i;
                pt_ppn_q[pt_index_i] <= pt_ppn_i;
                pt_valid_q[pt_index_i] <= pt_valid_i;
                pt_read_q[pt_index_i] <= pt_read_i;
                pt_write_q[pt_index_i] <= pt_write_perm_i;
                // A page-table update invalidates cached translations.
                for (i = 0; i < TLB_ENTRIES; i = i + 1)
                    tlb_valid_q[i] <= 1'b0;
            end else if (tlb_invalidate_i) begin
                for (i = 0; i < TLB_ENTRIES; i = i + 1)
                    tlb_valid_q[i] <= 1'b0;
            end

            case (state_q)
                LOOKUP_IDLE: begin
                    if (req_valid_i && req_ready_o) begin
                        req_vaddr_q <= req_vaddr_i;
                        req_len_q <= req_len_bytes_i;
                        req_write_q <= req_write_i;
                        state_q <= LOOKUP_MATCH;
                    end
                end

                LOOKUP_MATCH: begin
                    match_range_ok_q <= range_ok;
                    match_tlb_hit_q <= tlb_hit;
                    match_tlb_index_q <= tlb_hit_index;
                    match_pt_hit_q <= pt_hit;
                    match_pt_index_q <= pt_hit_index;
                    match_fill_index_q <= fill_index;
                    state_q <= LOOKUP_RESP;
                end

                LOOKUP_RESP: begin
                    resp_valid_o <= 1'b1;
                    resp_allow_o <= 1'b0;
                    resp_paddr_o <= '0;
                    resp_fault_o <= IOMMU_FAULT_PAGE;

                    if (!match_range_ok_q) begin
                        resp_fault_o <= IOMMU_FAULT_RANGE;
                    end else if (match_tlb_hit_q) begin
                        tlb_hit_count_o <= tlb_hit_count_o + 1'b1;
                        resp_allow_o <= resp_permission_ok;
                        resp_paddr_o <= {resp_selected_ppn,
                                         req_vaddr_q[PAGE_SHIFT-1:0]};
                        resp_fault_o <= resp_permission_ok
                                            ? IOMMU_FAULT_NONE
                                            : IOMMU_FAULT_PERMISSION;
                    end else begin
                        tlb_miss_count_o <= tlb_miss_count_o + 1'b1;
                        if (match_pt_hit_q) begin
                            tlb_vpn_q[match_fill_index_q]
                                <= pt_vpn_q[match_pt_index_q];
                            tlb_ppn_q[match_fill_index_q]
                                <= pt_ppn_q[match_pt_index_q];
                            tlb_read_q[match_fill_index_q]
                                <= pt_read_q[match_pt_index_q];
                            tlb_write_q[match_fill_index_q]
                                <= pt_write_q[match_pt_index_q];
                            tlb_valid_q[match_fill_index_q] <= 1'b1;
                            resp_allow_o <= resp_permission_ok;
                            resp_paddr_o <= {resp_selected_ppn,
                                             req_vaddr_q[PAGE_SHIFT-1:0]};
                            resp_fault_o <= resp_permission_ok
                                                ? IOMMU_FAULT_NONE
                                                : IOMMU_FAULT_PERMISSION;
                        end
                    end
                    state_q <= LOOKUP_IDLE;
                end

                default: state_q <= LOOKUP_IDLE;
            endcase
        end
    end

endmodule
