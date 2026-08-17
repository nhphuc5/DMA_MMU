`timescale 1ns / 1ps

// AXI4-Lite control/status register bank for dma_mmu_axi_top.
module dma_axil_regs #(
    parameter int AXIL_ADDR_WIDTH = 8,
    parameter int DMA_ADDR_WIDTH = 16,
    parameter int LEN_WIDTH = 20,
    parameter int PAGE_SHIFT = 12,
    parameter int PT_ENTRIES = 16
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,

    input  logic [AXIL_ADDR_WIDTH-1:0]   s_axil_awaddr,
    input  logic [2:0]                   s_axil_awprot,
    input  logic                         s_axil_awvalid,
    output logic                         s_axil_awready,
    input  logic [31:0]                  s_axil_wdata,
    input  logic [3:0]                   s_axil_wstrb,
    input  logic                         s_axil_wvalid,
    output logic                         s_axil_wready,
    output logic [1:0]                   s_axil_bresp,
    output logic                         s_axil_bvalid,
    input  logic                         s_axil_bready,
    input  logic [AXIL_ADDR_WIDTH-1:0]   s_axil_araddr,
    input  logic [2:0]                   s_axil_arprot,
    input  logic                         s_axil_arvalid,
    output logic                         s_axil_arready,
    output logic [31:0]                  s_axil_rdata,
    output logic [1:0]                   s_axil_rresp,
    output logic                         s_axil_rvalid,
    input  logic                         s_axil_rready,

    output logic                         cfg_start_o,
    output logic [DMA_ADDR_WIDTH-1:0]    cfg_src_vaddr_o,
    output logic [DMA_ADDR_WIDTH-1:0]    cfg_dst_vaddr_o,
    output logic [LEN_WIDTH-1:0]         cfg_length_bytes_o,
    output logic [1:0]                   cfg_transfer_type_o,
    output logic [1:0]                   cfg_dma_mode_o,
    output logic [7:0]                   cfg_burst_words_o,

    input  logic                         dma_busy_i,
    input  logic                         dma_done_i,
    input  logic                         dma_fault_i,
    input  logic [7:0]                   dma_fault_code_i,
    input  logic                         dma_done_irq_i,
    output logic                         irq_o,

    // Autonomous-peripheral DMA authorization.  Both controls reset low for
    // backward compatibility.  CPU START/PUSH commands are implicit grants;
    // only an enabled peripheral trigger can require explicit GRANT/DENY.
    output logic                         access_manual_enable_o,
    output logic                         periph_request_enable_o,
    output logic                         access_grant_o,
    output logic                         access_deny_o,
    output logic                         access_clear_denied_o,
    input  logic                         access_request_pending_i,
    input  logic                         access_grant_active_i,
    input  logic                         access_denied_sticky_i,
    input  logic [DMA_ADDR_WIDTH-1:0]    access_request_src_i,
    input  logic [DMA_ADDR_WIDTH-1:0]    access_request_dst_i,
    input  logic [LEN_WIDTH-1:0]         access_request_len_i,
    input  logic [1:0]                   access_request_type_i,
    input  logic [1:0]                   access_request_mode_i,
    input  logic [7:0]                   access_request_burst_i,
    input  logic                         access_request_queued_i,
    input  logic                         access_request_peripheral_i,
    input  logic [7:0]                   access_request_id_i,

    // Descriptor queue programming interface.  Software first writes the
    // staging registers and then writes DESC_COMMAND.PUSH.
    output logic                         desc_push_o,
    output logic [DMA_ADDR_WIDTH-1:0]    desc_src_addr_o,
    output logic [DMA_ADDR_WIDTH-1:0]    desc_dst_addr_o,
    output logic [LEN_WIDTH-1:0]         desc_length_o,
    output logic [1:0]                   desc_transfer_type_o,
    output logic [1:0]                   desc_dma_mode_o,
    output logic [7:0]                   desc_burst_words_o,
    output logic                         desc_irq_o,
    output logic [7:0]                   desc_id_o,
    output logic [DMA_ADDR_WIDTH-1:0]    desc_next_addr_o,
    output logic                         desc_flush_o,
    output logic                         desc_resume_o,
    output logic                         desc_pause_o,
    input  logic                         desc_push_rejected_i,
    input  logic [3:0]                   desc_queue_count_i,
    input  logic                         desc_queue_empty_i,
    input  logic                         desc_queue_full_i,
    input  logic                         desc_queue_active_i,
    input  logic                         desc_queue_halted_i,
    input  logic                         desc_queue_paused_i,

    // Completion queue head.  Reading does not remove a record; software
    // explicitly writes COMP_POP after it has consumed the result.
    output logic                         completion_pop_o,
    input  logic                         completion_valid_i,
    input  logic [3:0]                   completion_count_i,
    input  logic [7:0]                   completion_id_i,
    input  logic                         completion_done_i,
    input  logic                         completion_fault_i,
    input  logic [7:0]                   completion_fault_code_i,
    input  logic [LEN_WIDTH-1:0]         completion_bytes_i,
    input  logic [31:0]                  completion_total_i,

    output logic                         pt_write_o,
    output logic [$clog2(PT_ENTRIES)-1:0] pt_index_o,
    output logic [DMA_ADDR_WIDTH-PAGE_SHIFT-1:0] pt_vpn_o,
    output logic [DMA_ADDR_WIDTH-PAGE_SHIFT-1:0] pt_ppn_o,
    output logic                         pt_valid_o,
    output logic                         pt_read_o,
    output logic                         pt_write_perm_o,
    output logic                         tlb_invalidate_o,
    input  logic [31:0]                  tlb_hit_count_i,
    input  logic [31:0]                  tlb_miss_count_i
);

    localparam int VPN_WIDTH = DMA_ADDR_WIDTH-PAGE_SHIFT;

    localparam logic [7:0] REG_CONTROL   = 8'h00;
    localparam logic [7:0] REG_STATUS    = 8'h04;
    localparam logic [7:0] REG_SRC_ADDR  = 8'h08;
    localparam logic [7:0] REG_DST_ADDR  = 8'h0c;
    localparam logic [7:0] REG_LENGTH    = 8'h10;
    localparam logic [7:0] REG_CONFIG    = 8'h14;
    localparam logic [7:0] REG_FAULT     = 8'h18;
    localparam logic [7:0] REG_PT_INDEX  = 8'h20;
    localparam logic [7:0] REG_PT_VPN    = 8'h24;
    localparam logic [7:0] REG_PT_PPN    = 8'h28;
    localparam logic [7:0] REG_PT_FLAGS  = 8'h2c;
    localparam logic [7:0] REG_TLB_CTRL  = 8'h30;
    localparam logic [7:0] REG_TLB_HITS  = 8'h34;
    localparam logic [7:0] REG_TLB_MISS  = 8'h38;
    localparam logic [7:0] REG_DESC_SRC  = 8'h40;
    localparam logic [7:0] REG_DESC_DST  = 8'h44;
    localparam logic [7:0] REG_DESC_LEN  = 8'h48;
    localparam logic [7:0] REG_DESC_CFG  = 8'h4c;
    localparam logic [7:0] REG_DESC_FLAGS = 8'h50;
    localparam logic [7:0] REG_DESC_NEXT = 8'h54;
    localparam logic [7:0] REG_DESC_CMD  = 8'h58;
    localparam logic [7:0] REG_QUEUE_STATUS = 8'h5c;
    localparam logic [7:0] REG_COMP_STATUS = 8'h60;
    localparam logic [7:0] REG_COMP_BYTES = 8'h64;
    localparam logic [7:0] REG_COMP_POP = 8'h68;
    localparam logic [7:0] REG_COMP_TOTAL = 8'h6c;
    localparam logic [7:0] REG_ACCESS_CTRL = 8'h70;
    localparam logic [7:0] REG_ACCESS_STATUS = 8'h74;
    localparam logic [7:0] REG_ACCESS_CMD = 8'h78;
    localparam logic [7:0] REG_ACCESS_SRC = 8'h7c;
    localparam logic [7:0] REG_ACCESS_DST = 8'h80;
    localparam logic [7:0] REG_ACCESS_LEN = 8'h84;
    localparam logic [7:0] REG_ACCESS_INFO = 8'h88;

    logic [AXIL_ADDR_WIDTH-1:0] awaddr_q;
    logic [31:0] wdata_q;
    logic [3:0] wstrb_q;
    logic aw_pending_q;
    logic w_pending_q;

    logic irq_enable_q;
    logic irq_pending_q;
    logic done_sticky_q;
    logic fault_sticky_q;
    logic [7:0] fault_code_sticky_q;
    logic queue_overflow_sticky_q;
    logic access_manual_enable_q;
    logic periph_request_enable_q;

    logic [31:0] src_reg_q;
    logic [31:0] dst_reg_q;
    logic [31:0] length_reg_q;
    logic [31:0] config_reg_q;
    logic [31:0] pt_index_reg_q;
    logic [31:0] pt_vpn_reg_q;
    logic [31:0] pt_ppn_reg_q;
    logic [31:0] pt_flags_reg_q;
    logic [31:0] desc_src_reg_q;
    logic [31:0] desc_dst_reg_q;
    logic [31:0] desc_len_reg_q;
    logic [31:0] desc_cfg_reg_q;
    logic [31:0] desc_flags_reg_q;
    logic [31:0] desc_next_reg_q;

    function automatic [31:0] merge_wstrb(
        input [31:0] old_value,
        input [31:0] new_value,
        input [3:0] strb
    );
        automatic logic [31:0] result;
        begin
            result = old_value;
            for (int unsigned n = 0; n < 4; n++)
                if (strb[n])
                    result[n*8 +: 8] = new_value[n*8 +: 8];
            return result;
        end
    endfunction

    always_comb begin
        s_axil_awready = !aw_pending_q;
        s_axil_wready = !w_pending_q;
        s_axil_bresp = 2'b00;
        s_axil_arready = !s_axil_rvalid;
        s_axil_rresp = 2'b00;

        cfg_src_vaddr_o = src_reg_q[DMA_ADDR_WIDTH-1:0];
        cfg_dst_vaddr_o = dst_reg_q[DMA_ADDR_WIDTH-1:0];
        cfg_length_bytes_o = length_reg_q[LEN_WIDTH-1:0];
        cfg_transfer_type_o = config_reg_q[1:0];
        cfg_dma_mode_o = config_reg_q[3:2];
        cfg_burst_words_o = config_reg_q[15:8];

        desc_src_addr_o = desc_src_reg_q[DMA_ADDR_WIDTH-1:0];
        desc_dst_addr_o = desc_dst_reg_q[DMA_ADDR_WIDTH-1:0];
        desc_length_o = desc_len_reg_q[LEN_WIDTH-1:0];
        desc_transfer_type_o = desc_cfg_reg_q[1:0];
        desc_dma_mode_o = desc_cfg_reg_q[3:2];
        desc_burst_words_o = desc_cfg_reg_q[15:8];
        desc_irq_o = desc_flags_reg_q[0];
        desc_id_o = desc_flags_reg_q[15:8];
        desc_next_addr_o = desc_next_reg_q[DMA_ADDR_WIDTH-1:0];

        pt_index_o = pt_index_reg_q[$clog2(PT_ENTRIES)-1:0];
        pt_vpn_o = pt_vpn_reg_q[VPN_WIDTH-1:0];
        pt_ppn_o = pt_ppn_reg_q[VPN_WIDTH-1:0];
        pt_valid_o = pt_flags_reg_q[0];
        pt_read_o = pt_flags_reg_q[1];
        pt_write_perm_o = pt_flags_reg_q[2];

        access_manual_enable_o = access_manual_enable_q;
        periph_request_enable_o = periph_request_enable_q;
        // An autonomous request must always wake the CPU; otherwise disabling
        // the normal DONE/FAULT interrupt could deadlock a peripheral holding
        // AXI-Stream TVALID while it waits for GRANT.  irq_enable_q continues
        // to mask only completion/fault interrupts.
        irq_o = access_request_pending_i
              || (irq_enable_q && irq_pending_q);
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            awaddr_q <= '0;
            wdata_q <= '0;
            wstrb_q <= '0;
            aw_pending_q <= 1'b0;
            w_pending_q <= 1'b0;
            s_axil_bvalid <= 1'b0;
            s_axil_rvalid <= 1'b0;
            s_axil_rdata <= '0;
            cfg_start_o <= 1'b0;
            tlb_invalidate_o <= 1'b0;
            pt_write_o <= 1'b0;
            desc_push_o <= 1'b0;
            desc_flush_o <= 1'b0;
            desc_resume_o <= 1'b0;
            desc_pause_o <= 1'b0;
            completion_pop_o <= 1'b0;
            access_grant_o <= 1'b0;
            access_deny_o <= 1'b0;
            access_clear_denied_o <= 1'b0;
            irq_enable_q <= 1'b0;
            irq_pending_q <= 1'b0;
            done_sticky_q <= 1'b0;
            fault_sticky_q <= 1'b0;
            fault_code_sticky_q <= '0;
            queue_overflow_sticky_q <= 1'b0;
            access_manual_enable_q <= 1'b0;
            periph_request_enable_q <= 1'b0;
            src_reg_q <= '0;
            dst_reg_q <= '0;
            length_reg_q <= '0;
            config_reg_q <= 32'h0000_1000;
            pt_index_reg_q <= '0;
            pt_vpn_reg_q <= '0;
            pt_ppn_reg_q <= '0;
            pt_flags_reg_q <= '0;
            desc_src_reg_q <= '0;
            desc_dst_reg_q <= '0;
            desc_len_reg_q <= '0;
            desc_cfg_reg_q <= 32'h0000_1000;
            desc_flags_reg_q <= '0;
            desc_next_reg_q <= '0;
        end else begin
            cfg_start_o <= 1'b0;
            tlb_invalidate_o <= 1'b0;
            pt_write_o <= 1'b0;
            desc_push_o <= 1'b0;
            desc_flush_o <= 1'b0;
            desc_resume_o <= 1'b0;
            desc_pause_o <= 1'b0;
            completion_pop_o <= 1'b0;
            access_grant_o <= 1'b0;
            access_deny_o <= 1'b0;
            access_clear_denied_o <= 1'b0;

            if (dma_done_i) begin
                done_sticky_q <= 1'b1;
                if (dma_done_irq_i)
                    irq_pending_q <= 1'b1;
            end
            if (dma_fault_i) begin
                fault_sticky_q <= 1'b1;
                fault_code_sticky_q <= dma_fault_code_i;
                irq_pending_q <= 1'b1;
            end
            if (desc_push_rejected_i)
                queue_overflow_sticky_q <= 1'b1;

            if (s_axil_awvalid && s_axil_awready) begin
                awaddr_q <= s_axil_awaddr;
                aw_pending_q <= 1'b1;
            end
            if (s_axil_wvalid && s_axil_wready) begin
                wdata_q <= s_axil_wdata;
                wstrb_q <= s_axil_wstrb;
                w_pending_q <= 1'b1;
            end

            if (aw_pending_q && w_pending_q && !s_axil_bvalid) begin
                case (awaddr_q[7:0])
                    REG_CONTROL: begin
                        if (wstrb_q[0]) begin
                            if (wdata_q[0] && !dma_busy_i)
                                cfg_start_o <= 1'b1;
                            if (wdata_q[1]) begin
                                done_sticky_q <= 1'b0;
                                fault_sticky_q <= 1'b0;
                                fault_code_sticky_q <= '0;
                                irq_pending_q <= 1'b0;
                                queue_overflow_sticky_q <= 1'b0;
                            end
                            irq_enable_q <= wdata_q[2];
                        end
                    end
                    REG_SRC_ADDR:
                        src_reg_q <= merge_wstrb(src_reg_q, wdata_q, wstrb_q);
                    REG_DST_ADDR:
                        dst_reg_q <= merge_wstrb(dst_reg_q, wdata_q, wstrb_q);
                    REG_LENGTH:
                        length_reg_q <= merge_wstrb(length_reg_q,
                                                   wdata_q, wstrb_q);
                    REG_CONFIG:
                        config_reg_q <= merge_wstrb(config_reg_q,
                                                   wdata_q, wstrb_q);
                    REG_PT_INDEX:
                        pt_index_reg_q <= merge_wstrb(pt_index_reg_q,
                                                     wdata_q, wstrb_q);
                    REG_PT_VPN:
                        pt_vpn_reg_q <= merge_wstrb(pt_vpn_reg_q,
                                                   wdata_q, wstrb_q);
                    REG_PT_PPN:
                        pt_ppn_reg_q <= merge_wstrb(pt_ppn_reg_q,
                                                   wdata_q, wstrb_q);
                    REG_PT_FLAGS: begin
                        pt_flags_reg_q <= merge_wstrb(pt_flags_reg_q,
                                                     wdata_q, wstrb_q);
                        // Writing PT_FLAGS commits the entry.
                        pt_write_o <= 1'b1;
                    end
                    REG_TLB_CTRL: begin
                        if (wstrb_q[0] && wdata_q[0])
                            tlb_invalidate_o <= 1'b1;
                    end
                    REG_DESC_SRC:
                        desc_src_reg_q <= merge_wstrb(desc_src_reg_q,
                                                      wdata_q, wstrb_q);
                    REG_DESC_DST:
                        desc_dst_reg_q <= merge_wstrb(desc_dst_reg_q,
                                                      wdata_q, wstrb_q);
                    REG_DESC_LEN:
                        desc_len_reg_q <= merge_wstrb(desc_len_reg_q,
                                                      wdata_q, wstrb_q);
                    REG_DESC_CFG:
                        desc_cfg_reg_q <= merge_wstrb(desc_cfg_reg_q,
                                                      wdata_q, wstrb_q);
                    REG_DESC_FLAGS:
                        desc_flags_reg_q <= merge_wstrb(desc_flags_reg_q,
                                                        wdata_q, wstrb_q);
                    REG_DESC_NEXT:
                        desc_next_reg_q <= merge_wstrb(desc_next_reg_q,
                                                       wdata_q, wstrb_q);
                    REG_DESC_CMD: begin
                        if (wstrb_q[0]) begin
                            if (wdata_q[0])
                                desc_push_o <= 1'b1;
                            if (wdata_q[1])
                                desc_flush_o <= 1'b1;
                            if (wdata_q[2])
                                desc_resume_o <= 1'b1;
                            if (wdata_q[3])
                                desc_pause_o <= 1'b1;
                        end
                    end
                    REG_COMP_POP: begin
                        if (wstrb_q[0] && wdata_q[0])
                            completion_pop_o <= 1'b1;
                    end
                    REG_ACCESS_CTRL: begin
                        if (wstrb_q[0]) begin
                            access_manual_enable_q <= wdata_q[0];
                            periph_request_enable_q <= wdata_q[1];
                        end
                    end
                    REG_ACCESS_CMD: begin
                        if (wstrb_q[0]) begin
                            if (wdata_q[0])
                                access_grant_o <= 1'b1;
                            if (wdata_q[1])
                                access_deny_o <= 1'b1;
                            if (wdata_q[2])
                                access_clear_denied_o <= 1'b1;
                        end
                    end
                    default: begin end
                endcase
                aw_pending_q <= 1'b0;
                w_pending_q <= 1'b0;
                s_axil_bvalid <= 1'b1;
            end else if (s_axil_bvalid && s_axil_bready) begin
                s_axil_bvalid <= 1'b0;
            end

            if (s_axil_arvalid && s_axil_arready) begin
                case (s_axil_araddr[7:0])
                    REG_CONTROL:
                        s_axil_rdata <= {29'd0, irq_enable_q, 2'd0};
                    REG_STATUS:
                        s_axil_rdata <= {16'd0, fault_code_sticky_q,
                                         4'd0, irq_o, fault_sticky_q,
                                         done_sticky_q, dma_busy_i};
                    REG_SRC_ADDR: s_axil_rdata <= src_reg_q;
                    REG_DST_ADDR: s_axil_rdata <= dst_reg_q;
                    REG_LENGTH: s_axil_rdata <= length_reg_q;
                    REG_CONFIG: s_axil_rdata <= config_reg_q;
                    REG_FAULT:
                        s_axil_rdata <= {24'd0, fault_code_sticky_q};
                    REG_PT_INDEX: s_axil_rdata <= pt_index_reg_q;
                    REG_PT_VPN: s_axil_rdata <= pt_vpn_reg_q;
                    REG_PT_PPN: s_axil_rdata <= pt_ppn_reg_q;
                    REG_PT_FLAGS: s_axil_rdata <= pt_flags_reg_q;
                    REG_TLB_HITS: s_axil_rdata <= tlb_hit_count_i;
                    REG_TLB_MISS: s_axil_rdata <= tlb_miss_count_i;
                    REG_DESC_SRC: s_axil_rdata <= desc_src_reg_q;
                    REG_DESC_DST: s_axil_rdata <= desc_dst_reg_q;
                    REG_DESC_LEN: s_axil_rdata <= desc_len_reg_q;
                    REG_DESC_CFG: s_axil_rdata <= desc_cfg_reg_q;
                    REG_DESC_FLAGS: s_axil_rdata <= desc_flags_reg_q;
                    REG_DESC_NEXT: s_axil_rdata <= desc_next_reg_q;
                    REG_DESC_CMD: s_axil_rdata <= 32'd0;
                    REG_QUEUE_STATUS:
                        s_axil_rdata <= {12'd0, completion_count_i,
                                         1'b0,
                                         desc_queue_paused_i,
                                         completion_valid_i,
                                         queue_overflow_sticky_q,
                                         desc_queue_halted_i,
                                         desc_queue_active_i,
                                         desc_queue_full_i,
                                         desc_queue_empty_i,
                                         4'd0, desc_queue_count_i};
                    REG_COMP_STATUS:
                        s_axil_rdata <= {completion_id_i, 8'd0,
                                         completion_fault_code_i, 5'd0,
                                         completion_fault_i,
                                         completion_done_i,
                                         completion_valid_i};
                    REG_COMP_BYTES:
                        s_axil_rdata <= {{(32-LEN_WIDTH){1'b0}},
                                         completion_bytes_i};
                    REG_COMP_POP: s_axil_rdata <= 32'd0;
                    REG_COMP_TOTAL: s_axil_rdata <= completion_total_i;
                    REG_ACCESS_CTRL:
                        s_axil_rdata <= {30'd0, periph_request_enable_q,
                                         access_manual_enable_q};
                    REG_ACCESS_STATUS:
                        s_axil_rdata <= {15'd0, access_request_peripheral_i,
                                         access_request_id_i,
                                         access_request_mode_i,
                                         access_request_type_i,
                                         access_request_queued_i,
                                         access_denied_sticky_i,
                                         access_grant_active_i,
                                         access_request_pending_i};
                    REG_ACCESS_CMD: s_axil_rdata <= 32'd0;
                    REG_ACCESS_SRC:
                        s_axil_rdata <= {{(32-DMA_ADDR_WIDTH){1'b0}},
                                         access_request_src_i};
                    REG_ACCESS_DST:
                        s_axil_rdata <= {{(32-DMA_ADDR_WIDTH){1'b0}},
                                         access_request_dst_i};
                    REG_ACCESS_LEN:
                        s_axil_rdata <= {{(32-LEN_WIDTH){1'b0}},
                                         access_request_len_i};
                    REG_ACCESS_INFO:
                        s_axil_rdata <= {24'd0, access_request_burst_i};
                    default: s_axil_rdata <= 32'd0;
                endcase
                s_axil_rvalid <= 1'b1;
            end else if (s_axil_rvalid && s_axil_rready) begin
                s_axil_rvalid <= 1'b0;
            end
        end
    end

    logic _unused;
    assign _unused = &{1'b0, s_axil_awprot, s_axil_arprot};

endmodule
