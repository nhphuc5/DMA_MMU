`timescale 1ns / 1ps

// Descriptor scheduler shared by the three AXI data movers.
//
// Transfer types:
//   0: memory -> memory      (axi_cdma)
//   1: peripheral -> memory  (axi_dma_wr)
//   2: memory -> peripheral  (axi_dma_rd)
//
// DMA scheduling modes:
//   0: burst, chunks contain cfg_burst_words beats (or AXI maximum)
//   1: cycle stealing, one beat followed by a bus-release gap
//   2: transparent, one beat is launched only while cpu_bus_idle_i is high
module dma_axi_scheduler #(
    parameter int ADDR_WIDTH = 16,
    parameter int LEN_WIDTH = 20,
    parameter int DATA_WIDTH = 32,
    parameter int PAGE_SHIFT = 12,
    parameter int AXI_MAX_BURST_LEN = 16
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,

    input  logic                    cfg_start_i,
    input  logic [1:0]              cfg_transfer_type_i,
    input  logic [1:0]              cfg_dma_mode_i,
    input  logic [7:0]              cfg_burst_words_i,
    input  logic [ADDR_WIDTH-1:0]   cfg_src_vaddr_i,
    input  logic [ADDR_WIDTH-1:0]   cfg_dst_vaddr_i,
    input  logic [LEN_WIDTH-1:0]    cfg_length_bytes_i,
    input  logic                    cpu_bus_idle_i,
    // Page-table maintenance invalidates translated-address reuse as well as
    // the IOMMU's own TLB.
    input  logic                    translation_invalidate_i,

    output logic                    busy_o,
    output logic                    done_o,
    output logic                    fault_o,
    output logic [7:0]              fault_code_o,

    output logic                    iommu_req_valid_o,
    input  logic                    iommu_req_ready_i,
    output logic [ADDR_WIDTH-1:0]   iommu_req_vaddr_o,
    output logic [LEN_WIDTH-1:0]    iommu_req_len_o,
    output logic                    iommu_req_write_o,
    input  logic                    iommu_resp_valid_i,
    input  logic                    iommu_resp_allow_i,
    input  logic [ADDR_WIDTH-1:0]   iommu_resp_paddr_i,
    input  logic [2:0]              iommu_resp_fault_i,

    output logic [ADDR_WIDTH-1:0]   cdma_desc_src_addr_o,
    output logic [ADDR_WIDTH-1:0]   cdma_desc_dst_addr_o,
    output logic [LEN_WIDTH-1:0]    cdma_desc_len_o,
    output logic                    cdma_desc_valid_o,
    input  logic                    cdma_desc_ready_i,
    input  logic [3:0]              cdma_status_error_i,
    input  logic                    cdma_status_valid_i,

    output logic [ADDR_WIDTH-1:0]   axis_rd_desc_addr_o,
    output logic [LEN_WIDTH-1:0]    axis_rd_desc_len_o,
    output logic                    axis_rd_desc_valid_o,
    input  logic                    axis_rd_desc_ready_i,
    input  logic [3:0]              axis_rd_status_error_i,
    input  logic                    axis_rd_status_valid_i,
    output logic                    axis_rd_last_chunk_o,

    output logic [ADDR_WIDTH-1:0]   axis_wr_desc_addr_o,
    output logic [LEN_WIDTH-1:0]    axis_wr_desc_len_o,
    output logic                    axis_wr_desc_valid_o,
    input  logic                    axis_wr_desc_ready_i,
    input  logic [3:0]              axis_wr_status_error_i,
    input  logic                    axis_wr_status_valid_i
);

    localparam int BYTES_PER_BEAT = DATA_WIDTH/8;
    localparam int ADDR_ALIGN_BITS = $clog2(BYTES_PER_BEAT);
    localparam int BURST_VALUE_WIDTH = 8 + ADDR_ALIGN_BITS;
    localparam logic [LEN_WIDTH-1:0] MAX_BURST_BYTES =
        AXI_MAX_BURST_LEN * BYTES_PER_BEAT;
    localparam logic [PAGE_SHIFT:0] PAGE_SIZE_BYTES =
        {1'b1, {PAGE_SHIFT{1'b0}}};

    localparam logic [1:0] TYPE_MEM_TO_MEM = 2'd0;
    localparam logic [1:0] TYPE_DEV_TO_MEM = 2'd1;
    localparam logic [1:0] TYPE_MEM_TO_DEV = 2'd2;

    localparam logic [1:0] MODE_BURST       = 2'd0;
    localparam logic [1:0] MODE_CYCLE_STEAL = 2'd1;
    localparam logic [1:0] MODE_TRANSPARENT = 2'd2;

    localparam logic [7:0] FAULT_NONE       = 8'h00;
    localparam logic [7:0] FAULT_BAD_COMMAND = 8'h01;
    localparam logic [7:0] FAULT_SRC_IOMMU   = 8'h20;
    localparam logic [7:0] FAULT_DST_IOMMU   = 8'h30;
    localparam logic [7:0] FAULT_AXI_CDMA    = 8'h40;
    localparam logic [7:0] FAULT_AXI_READ    = 8'h50;
    localparam logic [7:0] FAULT_AXI_WRITE   = 8'h60;

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_PREPARE,
        ST_LIMIT_SRC_PAGE,
        ST_LIMIT_DST_PAGE,
        ST_AUTH_SRC_REQ,
        ST_AUTH_SRC_WAIT,
        ST_AUTH_DST_REQ,
        ST_AUTH_DST_WAIT,
        ST_ISSUE_DESC,
        ST_WAIT_ENGINE,
        ST_GAP,
        ST_DONE,
        ST_FAULT
    } state_t;

    state_t state_q;

    logic [1:0] transfer_type_q;
    logic [1:0] dma_mode_q;
    logic [7:0] burst_words_q;
    logic [ADDR_WIDTH-1:0] current_src_vaddr_q;
    logic [ADDR_WIDTH-1:0] current_dst_vaddr_q;
    logic [ADDR_WIDTH-1:0] current_src_paddr_q;
    logic [ADDR_WIDTH-1:0] current_dst_paddr_q;
    logic                  src_translation_valid_q;
    logic                  dst_translation_valid_q;
    // Registered 1..PAGE_SIZE counters avoid rebuilding PAGE_SIZE-offset
    // and a second comparator from the virtual address for every chunk.
    logic [PAGE_SHIFT:0]   src_page_remaining_q;
    logic [PAGE_SHIFT:0]   dst_page_remaining_q;
    logic [LEN_WIDTH-1:0] remaining_q;
    logic [LEN_WIDTH-1:0] chunk_len_q;

    logic use_src_memory;
    logic use_dst_memory;
    logic [LEN_WIDTH-1:0] requested_chunk;
    logic selected_desc_ready;
    logic selected_status_valid;
    logic [3:0] selected_status_error;

    assign use_src_memory = transfer_type_q != TYPE_DEV_TO_MEM;
    assign use_dst_memory = transfer_type_q != TYPE_MEM_TO_DEV;
    assign busy_o = state_q != ST_IDLE && state_q != ST_DONE
                 && state_q != ST_FAULT;

    always_comb begin
        if (dma_mode_q == MODE_BURST) begin
            // The downstream engines cannot issue a burst longer than
            // AXI_MAX_BURST_LEN.  Clamp here so every engine descriptor is
            // bounded as well; larger software transfers are still handled
            // by the scheduler as multiple descriptors.
            if (burst_words_q == 0
                || burst_words_q > AXI_MAX_BURST_LEN)
                requested_chunk = MAX_BURST_BYTES;
            else
                requested_chunk = {
                    {(LEN_WIDTH-BURST_VALUE_WIDTH){1'b0}},
                    burst_words_q,
                    {ADDR_ALIGN_BITS{1'b0}}
                };
        end else begin
            requested_chunk = BYTES_PER_BEAT;
        end

    end

    always_comb begin
        iommu_req_valid_o = 1'b0;
        iommu_req_vaddr_o = current_src_vaddr_q;
        iommu_req_len_o = chunk_len_q;
        iommu_req_write_o = 1'b0;

        if (state_q == ST_AUTH_SRC_REQ) begin
            iommu_req_valid_o = 1'b1;
        end else if (state_q == ST_AUTH_DST_REQ) begin
            iommu_req_valid_o = 1'b1;
            iommu_req_vaddr_o = current_dst_vaddr_q;
            iommu_req_write_o = 1'b1;
        end

        cdma_desc_src_addr_o = current_src_paddr_q;
        cdma_desc_dst_addr_o = current_dst_paddr_q;
        cdma_desc_len_o = chunk_len_q;
        cdma_desc_valid_o = state_q == ST_ISSUE_DESC
                         && transfer_type_q == TYPE_MEM_TO_MEM;

        axis_rd_desc_addr_o = current_src_paddr_q;
        axis_rd_desc_len_o = chunk_len_q;
        axis_rd_desc_valid_o = state_q == ST_ISSUE_DESC
                            && transfer_type_q == TYPE_MEM_TO_DEV;

        axis_wr_desc_addr_o = current_dst_paddr_q;
        axis_wr_desc_len_o = chunk_len_q;
        axis_wr_desc_valid_o = state_q == ST_ISSUE_DESC
                            && transfer_type_q == TYPE_DEV_TO_MEM;

        selected_desc_ready = 1'b0;
        selected_status_valid = 1'b0;
        selected_status_error = 4'd0;
        case (transfer_type_q)
            TYPE_MEM_TO_MEM: begin
                selected_desc_ready = cdma_desc_ready_i;
                selected_status_valid = cdma_status_valid_i;
                selected_status_error = cdma_status_error_i;
            end
            TYPE_DEV_TO_MEM: begin
                selected_desc_ready = axis_wr_desc_ready_i;
                selected_status_valid = axis_wr_status_valid_i;
                selected_status_error = axis_wr_status_error_i;
            end
            default: begin
                selected_desc_ready = axis_rd_desc_ready_i;
                selected_status_valid = axis_rd_status_valid_i;
                selected_status_error = axis_rd_status_error_i;
            end
        endcase

        axis_rd_last_chunk_o = transfer_type_q == TYPE_MEM_TO_DEV
                             && remaining_q == chunk_len_q
                             && (state_q == ST_ISSUE_DESC
                                 || state_q == ST_WAIT_ENGINE);
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= ST_IDLE;
            transfer_type_q <= TYPE_MEM_TO_MEM;
            dma_mode_q <= MODE_BURST;
            burst_words_q <= '0;
            current_src_vaddr_q <= '0;
            current_dst_vaddr_q <= '0;
            current_src_paddr_q <= '0;
            current_dst_paddr_q <= '0;
            src_translation_valid_q <= 1'b0;
            dst_translation_valid_q <= 1'b0;
            src_page_remaining_q <= PAGE_SIZE_BYTES;
            dst_page_remaining_q <= PAGE_SIZE_BYTES;
            remaining_q <= '0;
            chunk_len_q <= '0;
            done_o <= 1'b0;
            fault_o <= 1'b0;
            fault_code_o <= FAULT_NONE;
        end else begin
            done_o <= 1'b0;
            fault_o <= 1'b0;

            case (state_q)
                ST_IDLE: begin
                    fault_code_o <= FAULT_NONE;
                    if (cfg_start_i) begin
                        transfer_type_q <= cfg_transfer_type_i;
                        dma_mode_q <= cfg_dma_mode_i;
                        burst_words_q <= cfg_burst_words_i;
                        current_src_vaddr_q <= cfg_src_vaddr_i;
                        current_dst_vaddr_q <= cfg_dst_vaddr_i;
                        src_translation_valid_q <= 1'b0;
                        dst_translation_valid_q <= 1'b0;
                        src_page_remaining_q <= {
                            1'b0,
                            ~cfg_src_vaddr_i[PAGE_SHIFT-1:0]
                        } + 1'b1;
                        dst_page_remaining_q <= {
                            1'b0,
                            ~cfg_dst_vaddr_i[PAGE_SHIFT-1:0]
                        } + 1'b1;
                        remaining_q <= cfg_length_bytes_i;

                        if (cfg_length_bytes_i == 0
                            || cfg_length_bytes_i[ADDR_ALIGN_BITS-1:0] != 0
                            || cfg_transfer_type_i == 2'b11
                            || cfg_dma_mode_i == 2'b11
                            || ((cfg_transfer_type_i != TYPE_DEV_TO_MEM)
                                && cfg_src_vaddr_i[ADDR_ALIGN_BITS-1:0] != 0)
                            || ((cfg_transfer_type_i != TYPE_MEM_TO_DEV)
                                && cfg_dst_vaddr_i[ADDR_ALIGN_BITS-1:0] != 0)) begin
                            fault_code_o <= FAULT_BAD_COMMAND;
                            state_q <= ST_FAULT;
                        end else begin
                            state_q <= ST_PREPARE;
                        end
                    end
                end

                ST_PREPARE: begin
                    if (dma_mode_q != MODE_TRANSPARENT || cpu_bus_idle_i) begin
                        // Pipeline the three minimum operations.  The old
                        // single-cycle chain (burst, remaining, source page,
                        // destination page) was the post-route critical path.
                        chunk_len_q <= remaining_q < requested_chunk
                                     ? remaining_q : requested_chunk;
                        state_q <= ST_LIMIT_SRC_PAGE;
                    end
                end

                ST_LIMIT_SRC_PAGE: begin
                    if (use_src_memory
                        && src_page_remaining_q < chunk_len_q)
                        chunk_len_q <= src_page_remaining_q;
                    state_q <= ST_LIMIT_DST_PAGE;
                end

                ST_LIMIT_DST_PAGE: begin
                    if (use_dst_memory
                        && dst_page_remaining_q < chunk_len_q)
                        chunk_len_q <= dst_page_remaining_q;
                    if (use_src_memory && !src_translation_valid_q)
                        state_q <= ST_AUTH_SRC_REQ;
                    else if (use_dst_memory && !dst_translation_valid_q)
                        state_q <= ST_AUTH_DST_REQ;
                    else
                        state_q <= ST_ISSUE_DESC;
                end

                ST_AUTH_SRC_REQ: begin
                    if (iommu_req_valid_o && iommu_req_ready_i)
                        state_q <= ST_AUTH_SRC_WAIT;
                end

                ST_AUTH_SRC_WAIT: begin
                    if (iommu_resp_valid_i) begin
                        if (iommu_resp_allow_i) begin
                            current_src_paddr_q <= iommu_resp_paddr_i;
                            src_translation_valid_q <= 1'b1;
                            state_q <= use_dst_memory
                                       && !dst_translation_valid_q
                                     ? ST_AUTH_DST_REQ : ST_ISSUE_DESC;
                        end else begin
                            fault_code_o <= FAULT_SRC_IOMMU
                                          | {5'd0, iommu_resp_fault_i};
                            state_q <= ST_FAULT;
                        end
                    end
                end

                ST_AUTH_DST_REQ: begin
                    if (iommu_req_valid_o && iommu_req_ready_i)
                        state_q <= ST_AUTH_DST_WAIT;
                end

                ST_AUTH_DST_WAIT: begin
                    if (iommu_resp_valid_i) begin
                        if (iommu_resp_allow_i) begin
                            current_dst_paddr_q <= iommu_resp_paddr_i;
                            dst_translation_valid_q <= 1'b1;
                            state_q <= ST_ISSUE_DESC;
                        end else begin
                            fault_code_o <= FAULT_DST_IOMMU
                                          | {5'd0, iommu_resp_fault_i};
                            state_q <= ST_FAULT;
                        end
                    end
                end

                ST_ISSUE_DESC: begin
                    if (selected_desc_ready)
                        state_q <= ST_WAIT_ENGINE;
                end

                ST_WAIT_ENGINE: begin
                    if (selected_status_valid) begin
                        if (selected_status_error != 0) begin
                            case (transfer_type_q)
                                TYPE_MEM_TO_MEM:
                                    fault_code_o <= FAULT_AXI_CDMA
                                                  | selected_status_error;
                                TYPE_DEV_TO_MEM:
                                    fault_code_o <= FAULT_AXI_WRITE
                                                  | selected_status_error;
                                default:
                                    fault_code_o <= FAULT_AXI_READ
                                                  | selected_status_error;
                            endcase
                            state_q <= ST_FAULT;
                        end else if (remaining_q == chunk_len_q) begin
                            remaining_q <= '0;
                            state_q <= ST_DONE;
                        end else begin
                            remaining_q <= remaining_q - chunk_len_q;
                            current_src_vaddr_q <= current_src_vaddr_q
                                                 + chunk_len_q;
                            current_dst_vaddr_q <= current_dst_vaddr_q
                                                 + chunk_len_q;
                            // The authorized PA advances linearly inside a
                            // page.  Reuse it for the next one-beat descriptor
                            // and ask the IOMMU again only at a page boundary.
                            if (use_src_memory) begin
                                current_src_paddr_q <= current_src_paddr_q
                                                     + chunk_len_q;
                                if (chunk_len_q == src_page_remaining_q) begin
                                    src_translation_valid_q <= 1'b0;
                                    src_page_remaining_q <= PAGE_SIZE_BYTES;
                                end else begin
                                    src_page_remaining_q
                                        <= src_page_remaining_q
                                           - chunk_len_q[PAGE_SHIFT:0];
                                end
                            end
                            if (use_dst_memory) begin
                                current_dst_paddr_q <= current_dst_paddr_q
                                                     + chunk_len_q;
                                if (chunk_len_q == dst_page_remaining_q) begin
                                    dst_translation_valid_q <= 1'b0;
                                    dst_page_remaining_q <= PAGE_SIZE_BYTES;
                                end else begin
                                    dst_page_remaining_q
                                        <= dst_page_remaining_q
                                           - chunk_len_q[PAGE_SHIFT:0];
                                end
                            end
                            if (dma_mode_q == MODE_TRANSPARENT)
                                state_q <= ST_PREPARE;
                            else
                                state_q <= ST_GAP;
                        end
                    end
                end

                ST_GAP: begin
                    // A complete cycle with no new descriptor allows another
                    // AXI master to win the round-robin interconnect.
                    state_q <= ST_PREPARE;
                end

                ST_DONE: begin
                    done_o <= 1'b1;
                    state_q <= ST_IDLE;
                end

                ST_FAULT: begin
                    fault_o <= 1'b1;
                    state_q <= ST_IDLE;
                end

                default: state_q <= ST_IDLE;
            endcase

            // Maintenance has priority over a simultaneous lookup response:
            // no later chunk may bypass a fresh permission check.
            if (translation_invalidate_i) begin
                src_translation_valid_q <= 1'b0;
                dst_translation_valid_q <= 1'b0;
            end
        end
    end

endmodule
