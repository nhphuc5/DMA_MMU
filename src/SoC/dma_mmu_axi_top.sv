`timescale 1ns / 1ps

// AXI-integrated DMA + IOMMU IP.
//
// Control: AXI4-Lite slave
// Memory:  AXI4-Full master
// Device:  AXI4-Stream sink/source
//
// The top reuses axi_cdma for memory-to-memory, axi_dma_wr for stream-to-memory,
// axi_dma_rd for memory-to-stream, and axi_crossbar for independent fair
// round-robin arbitration of AXI4 read and write requests.
module dma_mmu_axi_top #(
    parameter int AXI_ADDR_WIDTH = 16,
    parameter int AXI_DATA_WIDTH = 32,
    parameter int AXI_ID_WIDTH = 4,
    parameter int AXIL_ADDR_WIDTH = 8,
    // With the default 16-bit AXI address space, a wider transfer counter
    // cannot describe a legal single transfer and only lengthens carry paths.
    parameter int LEN_WIDTH = 16,
    parameter int PAGE_SHIFT = 12,
    parameter int PT_ENTRIES = 16,
    parameter int TLB_ENTRIES = 4,
    parameter int AXI_MAX_BURST_LEN = 16,
    parameter int DESC_QUEUE_DEPTH = 8
) (
    input  logic                         aclk,
    input  logic                         aresetn,
    input  logic                         cpu_bus_idle_i,
    output logic                         irq_o,

    // AXI4-Lite slave control interface
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

    // AXI4-Full memory master interface
    // The crossbar appends one source bit to the engine ID so responses can
    // be routed back to CDMA or the streaming engine.
    output logic [AXI_ID_WIDTH:0]        m_axi_awid,
    output logic [AXI_ADDR_WIDTH-1:0]    m_axi_awaddr,
    output logic [7:0]                   m_axi_awlen,
    output logic [2:0]                   m_axi_awsize,
    output logic [1:0]                   m_axi_awburst,
    output logic                         m_axi_awlock,
    output logic [3:0]                   m_axi_awcache,
    output logic [2:0]                   m_axi_awprot,
    output logic [3:0]                   m_axi_awqos,
    output logic [3:0]                   m_axi_awregion,
    output logic                         m_axi_awvalid,
    input  logic                         m_axi_awready,
    output logic [AXI_DATA_WIDTH-1:0]    m_axi_wdata,
    output logic [AXI_DATA_WIDTH/8-1:0]  m_axi_wstrb,
    output logic                         m_axi_wlast,
    output logic                         m_axi_wvalid,
    input  logic                         m_axi_wready,
    input  logic [AXI_ID_WIDTH:0]        m_axi_bid,
    input  logic [1:0]                   m_axi_bresp,
    input  logic                         m_axi_bvalid,
    output logic                         m_axi_bready,
    output logic [AXI_ID_WIDTH:0]        m_axi_arid,
    output logic [AXI_ADDR_WIDTH-1:0]    m_axi_araddr,
    output logic [7:0]                   m_axi_arlen,
    output logic [2:0]                   m_axi_arsize,
    output logic [1:0]                   m_axi_arburst,
    output logic                         m_axi_arlock,
    output logic [3:0]                   m_axi_arcache,
    output logic [2:0]                   m_axi_arprot,
    output logic [3:0]                   m_axi_arqos,
    output logic [3:0]                   m_axi_arregion,
    output logic                         m_axi_arvalid,
    input  logic                         m_axi_arready,
    input  logic [AXI_ID_WIDTH:0]        m_axi_rid,
    input  logic [AXI_DATA_WIDTH-1:0]    m_axi_rdata,
    input  logic [1:0]                   m_axi_rresp,
    input  logic                         m_axi_rlast,
    input  logic                         m_axi_rvalid,
    output logic                         m_axi_rready,

    // Peripheral -> DMA stream
    input  logic [AXI_DATA_WIDTH-1:0]    s_axis_periph_tdata,
    input  logic [AXI_DATA_WIDTH/8-1:0]  s_axis_periph_tkeep,
    input  logic                         s_axis_periph_tvalid,
    output logic                         s_axis_periph_tready,
    input  logic                         s_axis_periph_tlast,

    // DMA -> peripheral stream
    output logic [AXI_DATA_WIDTH-1:0]    m_axis_periph_tdata,
    output logic [AXI_DATA_WIDTH/8-1:0]  m_axis_periph_tkeep,
    output logic                         m_axis_periph_tvalid,
    input  logic                         m_axis_periph_tready,
    output logic                         m_axis_periph_tlast
);

    localparam int AXI_STRB_WIDTH = AXI_DATA_WIDTH/8;
    localparam int VPN_WIDTH = AXI_ADDR_WIDTH-PAGE_SHIFT;
    // The scheduler bounds every engine descriptor to one AXI burst.  Keep
    // the public/programmed length at LEN_WIDTH, but size the internal DMA
    // engine counters only for the largest descriptor they can receive.
    // With the default 16 beats x 4 bytes this is 7 bits (0..64), instead of
    // a 16-bit carry chain on every burst calculation.
    localparam int ENGINE_LEN_WIDTH =
        $clog2(AXI_MAX_BURST_LEN*AXI_STRB_WIDTH + 1);

    wire rst = !aresetn;

    // ---------------------------------------------------------------------
    // AXI-Lite registers
    // ---------------------------------------------------------------------
    logic legacy_cfg_start;
    logic [AXI_ADDR_WIDTH-1:0] legacy_cfg_src_vaddr;
    logic [AXI_ADDR_WIDTH-1:0] legacy_cfg_dst_vaddr;
    logic [LEN_WIDTH-1:0] legacy_cfg_length_bytes;
    logic [1:0] legacy_cfg_transfer_type;
    logic [1:0] legacy_cfg_dma_mode;
    logic [7:0] legacy_cfg_burst_words;
    logic launch_request;
    logic [AXI_ADDR_WIDTH-1:0] launch_request_src;
    logic [AXI_ADDR_WIDTH-1:0] launch_request_dst;
    logic [LEN_WIDTH-1:0] launch_request_len;
    logic [1:0] launch_request_type;
    logic [1:0] launch_request_mode;
    logic [7:0] launch_request_burst;
    logic launch_request_queued;
    logic launch_request_requires_grant;
    logic [7:0] launch_request_id;
    logic scheduler_cfg_start;
    logic [AXI_ADDR_WIDTH-1:0] scheduler_cfg_src_vaddr;
    logic [AXI_ADDR_WIDTH-1:0] scheduler_cfg_dst_vaddr;
    logic [LEN_WIDTH-1:0] scheduler_cfg_length_bytes;
    logic [1:0] scheduler_cfg_transfer_type;
    logic [1:0] scheduler_cfg_dma_mode;
    logic [7:0] scheduler_cfg_burst_words;
    // Compatibility/debug alias retained for existing waveform scripts and
    // performance monitors.  It now covers both legacy and queued launches.
    wire cfg_start = scheduler_cfg_start;
    logic dma_busy;
    logic dma_done;
    logic dma_fault;
    logic [7:0] dma_fault_code;
    logic scheduler_dma_done;
    logic scheduler_dma_fault;
    logic [7:0] scheduler_dma_fault_code;
    logic control_busy;

    logic access_manual_enable;
    logic periph_request_enable;
    logic access_grant_cmd;
    logic access_deny_cmd;
    logic access_clear_denied_cmd;
    logic access_request_pending;
    logic access_grant_active;
    logic access_denied_sticky;
    logic access_denied_pulse;
    logic [AXI_ADDR_WIDTH-1:0] access_request_src;
    logic [AXI_ADDR_WIDTH-1:0] access_request_dst;
    logic [LEN_WIDTH-1:0] access_request_len;
    logic [1:0] access_request_type;
    logic [1:0] access_request_mode;
    logic [7:0] access_request_burst;
    logic access_request_queued;
    logic access_request_peripheral;
    logic [7:0] access_request_id;
    logic periph_request_issued_q;
    logic periph_launch_request;

    logic desc_push;
    logic [AXI_ADDR_WIDTH-1:0] desc_push_src;
    logic [AXI_ADDR_WIDTH-1:0] desc_push_dst;
    logic [LEN_WIDTH-1:0] desc_push_len;
    logic [1:0] desc_push_type;
    logic [1:0] desc_push_mode;
    logic [7:0] desc_push_burst;
    logic desc_push_irq;
    logic [7:0] desc_push_id;
    logic [AXI_ADDR_WIDTH-1:0] desc_push_next;
    logic desc_flush;
    logic desc_resume;
    logic desc_pause;
    logic desc_push_rejected;
    logic [3:0] desc_queue_count;
    logic desc_queue_empty;
    logic desc_queue_full;
    logic desc_queue_valid;
    logic desc_queue_pop;
    logic [AXI_ADDR_WIDTH-1:0] desc_head_src;
    logic [AXI_ADDR_WIDTH-1:0] desc_head_dst;
    logic [LEN_WIDTH-1:0] desc_head_len;
    logic [1:0] desc_head_type;
    logic [1:0] desc_head_mode;
    logic [7:0] desc_head_burst;
    logic desc_head_irq;
    logic [7:0] desc_head_id;
    logic [AXI_ADDR_WIDTH-1:0] desc_head_next;

    logic completion_pop;
    logic completion_push;
    logic completion_valid;
    logic completion_empty;
    logic completion_full;
    logic [3:0] completion_count;
    logic [7:0] completion_id;
    logic completion_done;
    logic completion_fault;
    logic [7:0] completion_fault_code;
    logic [LEN_WIDTH-1:0] completion_bytes;
    logic [31:0] completion_total_q;

    logic queue_active_q;
    logic queue_launch_pending_q;
    logic queue_halted_q;
    logic queue_paused_q;
    logic [AXI_ADDR_WIDTH-1:0] active_src_q;
    logic [AXI_ADDR_WIDTH-1:0] active_dst_q;
    logic [LEN_WIDTH-1:0] active_len_q;
    logic [1:0] active_type_q;
    logic [1:0] active_mode_q;
    logic [7:0] active_burst_q;
    logic active_irq_q;
    logic [7:0] active_id_q;
    logic [AXI_ADDR_WIDTH-1:0] active_next_q;

    logic pt_write;
    logic [$clog2(PT_ENTRIES)-1:0] pt_index;
    logic [VPN_WIDTH-1:0] pt_vpn;
    logic [VPN_WIDTH-1:0] pt_ppn;
    logic pt_valid;
    logic pt_read;
    logic pt_write_perm;
    logic tlb_invalidate;
    logic [31:0] tlb_hit_count;
    logic [31:0] tlb_miss_count;

    // Last-command performance snapshot.  Working counters are sampled from
    // real AXI/AXI-Stream handshakes; the read-only snapshot remains stable
    // until the next DMA command completes.
    logic [31:0] perf_seq;
    logic perf_valid;
    logic perf_fault;
    logic [1:0] perf_transfer_type;
    logic [1:0] perf_dma_mode;
    logic [31:0] perf_length;
    logic [31:0] perf_total_cycles;
    logic [31:0] perf_src_bytes;
    logic [31:0] perf_src_span;
    logic [31:0] perf_dst_bytes;
    logic [31:0] perf_dst_span;
    logic [31:0] perf_axi_r_bytes;
    logic [31:0] perf_axi_r_cycles;
    logic [31:0] perf_axi_w_bytes;
    logic [31:0] perf_axi_w_cycles;

    dma_axil_regs #(
        .AXIL_ADDR_WIDTH(AXIL_ADDR_WIDTH),
        .DMA_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .LEN_WIDTH(LEN_WIDTH),
        .PAGE_SHIFT(PAGE_SHIFT),
        .PT_ENTRIES(PT_ENTRIES)
    ) regs_inst (
        .clk_i(aclk),
        .rst_ni(aresetn),
        .s_axil_awaddr,
        .s_axil_awprot,
        .s_axil_awvalid,
        .s_axil_awready,
        .s_axil_wdata,
        .s_axil_wstrb,
        .s_axil_wvalid,
        .s_axil_wready,
        .s_axil_bresp,
        .s_axil_bvalid,
        .s_axil_bready,
        .s_axil_araddr,
        .s_axil_arprot,
        .s_axil_arvalid,
        .s_axil_arready,
        .s_axil_rdata,
        .s_axil_rresp,
        .s_axil_rvalid,
        .s_axil_rready,
        .cfg_start_o(legacy_cfg_start),
        .cfg_src_vaddr_o(legacy_cfg_src_vaddr),
        .cfg_dst_vaddr_o(legacy_cfg_dst_vaddr),
        .cfg_length_bytes_o(legacy_cfg_length_bytes),
        .cfg_transfer_type_o(legacy_cfg_transfer_type),
        .cfg_dma_mode_o(legacy_cfg_dma_mode),
        .cfg_burst_words_o(legacy_cfg_burst_words),
        .dma_busy_i(control_busy),
        .dma_done_i(dma_done),
        .dma_fault_i(dma_fault),
        .dma_fault_code_i(dma_fault_code),
        .dma_done_irq_i(queue_active_q ? active_irq_q : 1'b1),
        .irq_o,
        .access_manual_enable_o(access_manual_enable),
        .periph_request_enable_o(periph_request_enable),
        .access_grant_o(access_grant_cmd),
        .access_deny_o(access_deny_cmd),
        .access_clear_denied_o(access_clear_denied_cmd),
        .access_request_pending_i(access_request_pending),
        .access_grant_active_i(access_grant_active),
        .access_denied_sticky_i(access_denied_sticky),
        .access_request_src_i(access_request_src),
        .access_request_dst_i(access_request_dst),
        .access_request_len_i(access_request_len),
        .access_request_type_i(access_request_type),
        .access_request_mode_i(access_request_mode),
        .access_request_burst_i(access_request_burst),
        .access_request_queued_i(access_request_queued),
        .access_request_peripheral_i(access_request_peripheral),
        .access_request_id_i(access_request_id),
        .desc_push_o(desc_push),
        .desc_src_addr_o(desc_push_src),
        .desc_dst_addr_o(desc_push_dst),
        .desc_length_o(desc_push_len),
        .desc_transfer_type_o(desc_push_type),
        .desc_dma_mode_o(desc_push_mode),
        .desc_burst_words_o(desc_push_burst),
        .desc_irq_o(desc_push_irq),
        .desc_id_o(desc_push_id),
        .desc_next_addr_o(desc_push_next),
        .desc_flush_o(desc_flush),
        .desc_resume_o(desc_resume),
        .desc_pause_o(desc_pause),
        .desc_push_rejected_i(desc_push_rejected),
        .desc_queue_count_i(desc_queue_count),
        .desc_queue_empty_i(desc_queue_empty),
        .desc_queue_full_i(desc_queue_full),
        .desc_queue_active_i(queue_active_q || queue_launch_pending_q),
        .desc_queue_halted_i(queue_halted_q),
        .desc_queue_paused_i(queue_paused_q),
        .completion_pop_o(completion_pop),
        .completion_valid_i(completion_valid),
        .completion_count_i(completion_count),
        .completion_id_i(completion_id),
        .completion_done_i(completion_done),
        .completion_fault_i(completion_fault),
        .completion_fault_code_i(completion_fault_code),
        .completion_bytes_i(completion_bytes),
        .completion_total_i(completion_total_q),
        .pt_write_o(pt_write),
        .pt_index_o(pt_index),
        .pt_vpn_o(pt_vpn),
        .pt_ppn_o(pt_ppn),
        .pt_valid_o(pt_valid),
        .pt_read_o(pt_read),
        .pt_write_perm_o(pt_write_perm),
        .tlb_invalidate_o(tlb_invalidate),
        .tlb_hit_count_i(tlb_hit_count),
        .tlb_miss_count_i(tlb_miss_count),
        .perf_seq_i(perf_seq),
        .perf_valid_i(perf_valid),
        .perf_fault_i(perf_fault),
        .perf_transfer_type_i(perf_transfer_type),
        .perf_dma_mode_i(perf_dma_mode),
        .perf_length_i(perf_length),
        .perf_total_cycles_i(perf_total_cycles),
        .perf_src_bytes_i(perf_src_bytes),
        .perf_src_span_i(perf_src_span),
        .perf_dst_bytes_i(perf_dst_bytes),
        .perf_dst_span_i(perf_dst_span),
        .perf_axi_r_bytes_i(perf_axi_r_bytes),
        .perf_axi_r_cycles_i(perf_axi_r_cycles),
        .perf_axi_w_bytes_i(perf_axi_w_bytes),
        .perf_axi_w_cycles_i(perf_axi_w_cycles)
    );

    // ---------------------------------------------------------------------
    // Descriptor and completion queues
    // ---------------------------------------------------------------------
    dma_descriptor_fifo #(
        .ADDR_WIDTH(AXI_ADDR_WIDTH),
        .LEN_WIDTH(LEN_WIDTH),
        .DEPTH(DESC_QUEUE_DEPTH),
        .ID_WIDTH(8)
    ) descriptor_fifo_inst (
        .clk_i(aclk),
        .rst_ni(aresetn),
        .flush_i(desc_flush),
        .push_i(desc_push),
        .push_src_addr_i(desc_push_src),
        .push_dst_addr_i(desc_push_dst),
        .push_length_i(desc_push_len),
        .push_transfer_type_i(desc_push_type),
        .push_dma_mode_i(desc_push_mode),
        .push_burst_words_i(desc_push_burst),
        .push_irq_i(desc_push_irq),
        .push_id_i(desc_push_id),
        .push_next_desc_i(desc_push_next),
        .push_accepted_o(),
        .push_rejected_o(desc_push_rejected),
        .pop_i(desc_queue_pop),
        .valid_o(desc_queue_valid),
        .src_addr_o(desc_head_src),
        .dst_addr_o(desc_head_dst),
        .length_o(desc_head_len),
        .transfer_type_o(desc_head_type),
        .dma_mode_o(desc_head_mode),
        .burst_words_o(desc_head_burst),
        .irq_o(desc_head_irq),
        .id_o(desc_head_id),
        .next_desc_o(desc_head_next),
        .empty_o(desc_queue_empty),
        .full_o(desc_queue_full),
        .count_o(desc_queue_count)
    );

    assign completion_push = queue_active_q && (dma_done || dma_fault);

    dma_completion_fifo #(
        .LEN_WIDTH(LEN_WIDTH),
        .DEPTH(DESC_QUEUE_DEPTH),
        .ID_WIDTH(8)
    ) completion_fifo_inst (
        .clk_i(aclk),
        .rst_ni(aresetn),
        .flush_i(1'b0),
        .push_i(completion_push),
        .push_id_i(active_id_q),
        .push_done_i(dma_done),
        .push_fault_i(dma_fault),
        .push_fault_code_i(dma_fault_code),
        .push_bytes_i(dma_done ? active_len_q : '0),
        .pop_i(completion_pop),
        .valid_o(completion_valid),
        .id_o(completion_id),
        .done_o(completion_done),
        .fault_o(completion_fault),
        .fault_code_o(completion_fault_code),
        .bytes_o(completion_bytes),
        .empty_o(completion_empty),
        .full_o(completion_full),
        .count_o(completion_count)
    );

    assign control_busy = dma_busy || queue_active_q
                        || queue_launch_pending_q || !desc_queue_empty
                        || access_request_pending || access_grant_active;

    // Pop and register a descriptor only when the scheduler and completion
    // path can both accept it.  Registering the FIFO head also breaks the
    // long AXI-Lite/FIFO-to-scheduler timing path.
    assign desc_queue_pop = desc_queue_valid
                          && !queue_active_q
                          && !queue_launch_pending_q
                          && !queue_halted_q
                          && !queue_paused_q
                          && !completion_full
                          && !dma_busy && !dma_done && !dma_fault
                          && !access_request_pending && !access_grant_active
                          && !legacy_cfg_start;

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            queue_active_q <= 1'b0;
            queue_launch_pending_q <= 1'b0;
            queue_halted_q <= 1'b0;
            queue_paused_q <= 1'b0;
            active_src_q <= '0;
            active_dst_q <= '0;
            active_len_q <= '0;
            active_type_q <= '0;
            active_mode_q <= '0;
            active_burst_q <= '0;
            active_irq_q <= 1'b0;
            active_id_q <= '0;
            active_next_q <= '0;
            completion_total_q <= '0;
        end else begin
            if (desc_pause)
                queue_paused_q <= 1'b1;
            if (desc_resume) begin
                queue_halted_q <= 1'b0;
                queue_paused_q <= 1'b0;
            end
            if (desc_flush) begin
                queue_halted_q <= 1'b0;
                queue_paused_q <= 1'b0;
            end

            if (desc_queue_pop) begin
                active_src_q <= desc_head_src;
                active_dst_q <= desc_head_dst;
                active_len_q <= desc_head_len;
                active_type_q <= desc_head_type;
                active_mode_q <= desc_head_mode;
                active_burst_q <= desc_head_burst;
                active_irq_q <= desc_head_irq;
                active_id_q <= desc_head_id;
                active_next_q <= desc_head_next;
                queue_active_q <= 1'b1;
                queue_launch_pending_q <= 1'b1;
            end else if (queue_launch_pending_q) begin
                queue_launch_pending_q <= 1'b0;
            end

            if (completion_push) begin
                completion_total_q <= completion_total_q + 1'b1;
                queue_active_q <= 1'b0;
                if (dma_fault)
                    queue_halted_q <= 1'b1;
            end
        end
    end

    // An autonomous UART/RX request is generated only from real AXI-Stream
    // data becoming valid.  The CPU pre-programs the legacy destination,
    // length, mode, and burst template, but does not write START.  CPU START
    // and queued descriptors have priority and are implicit grants.
    assign periph_launch_request = periph_request_enable
                                 && s_axis_periph_tvalid
                                 && !periph_request_issued_q
                                 && desc_queue_empty
                                 && !queue_active_q
                                 && !queue_launch_pending_q
                                 && !legacy_cfg_start
                                 && !dma_busy && !dma_done && !dma_fault
                                 && !access_request_pending
                                 && !access_grant_active;

    assign launch_request = legacy_cfg_start || queue_launch_pending_q
                          || periph_launch_request;
    assign launch_request_src = queue_active_q
                              ? active_src_q : legacy_cfg_src_vaddr;
    assign launch_request_dst = queue_active_q
                              ? active_dst_q : legacy_cfg_dst_vaddr;
    assign launch_request_len = queue_active_q
                              ? active_len_q : legacy_cfg_length_bytes;
    assign launch_request_type = periph_launch_request
                               ? 2'd1
                               : (queue_active_q
                                  ? active_type_q
                                  : legacy_cfg_transfer_type);
    assign launch_request_mode = queue_active_q
                               ? active_mode_q : legacy_cfg_dma_mode;
    assign launch_request_burst = queue_active_q
                                ? active_burst_q : legacy_cfg_burst_words;
    assign launch_request_queued = queue_active_q;
    assign launch_request_requires_grant = periph_launch_request;
    assign launch_request_id = periph_launch_request
                             ? 8'hff
                             : (queue_active_q ? active_id_q : 8'd0);

    // One held AXI-Stream word may create at most one permission request.
    // The latch clears after the accepted/denied request has finished and
    // the peripheral has removed TVALID, or immediately when auto-trigger is
    // disabled by software.
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            periph_request_issued_q <= 1'b0;
        end else begin
            if (!periph_request_enable)
                periph_request_issued_q <= 1'b0;
            else if (periph_launch_request)
                periph_request_issued_q <= 1'b1;
            else if (!s_axis_periph_tvalid
                     && !access_request_pending
                     && !access_grant_active
                     && !dma_busy)
                periph_request_issued_q <= 1'b0;
        end
    end

    // A CPU-authorized launch boundary is safer than gating AXI VALID in the
    // middle of a transaction: DENY occurs before the scheduler, IOMMU, RAM,
    // or UART observes any request.  Auto mode preserves the original
    // zero-extra-cycle behavior for all existing firmware and regressions.
    dma_access_controller #(
        .ADDR_WIDTH(AXI_ADDR_WIDTH),
        .LEN_WIDTH(LEN_WIDTH)
    ) access_controller_inst (
        .clk_i(aclk),
        .rst_ni(aresetn),
        .manual_enable_i(access_manual_enable),
        .grant_i(access_grant_cmd),
        .deny_i(access_deny_cmd),
        .clear_denied_i(access_clear_denied_cmd),
        .launch_valid_i(launch_request),
        .launch_requires_grant_i(launch_request_requires_grant),
        .launch_src_i(launch_request_src),
        .launch_dst_i(launch_request_dst),
        .launch_len_i(launch_request_len),
        .launch_type_i(launch_request_type),
        .launch_mode_i(launch_request_mode),
        .launch_burst_i(launch_request_burst),
        .launch_queued_i(launch_request_queued),
        .launch_id_i(launch_request_id),
        .transfer_done_i(scheduler_dma_done),
        .transfer_fault_i(scheduler_dma_fault),
        .scheduler_start_o(scheduler_cfg_start),
        .scheduler_src_o(scheduler_cfg_src_vaddr),
        .scheduler_dst_o(scheduler_cfg_dst_vaddr),
        .scheduler_len_o(scheduler_cfg_length_bytes),
        .scheduler_type_o(scheduler_cfg_transfer_type),
        .scheduler_mode_o(scheduler_cfg_dma_mode),
        .scheduler_burst_o(scheduler_cfg_burst_words),
        .request_pending_o(access_request_pending),
        .grant_active_o(access_grant_active),
        .denied_sticky_o(access_denied_sticky),
        .denied_pulse_o(access_denied_pulse),
        .request_src_o(access_request_src),
        .request_dst_o(access_request_dst),
        .request_len_o(access_request_len),
        .request_type_o(access_request_type),
        .request_mode_o(access_request_mode),
        .request_burst_o(access_request_burst),
        .request_queued_o(access_request_queued),
        .request_peripheral_o(access_request_peripheral),
        .request_id_o(access_request_id)
    );

    localparam logic [7:0] FAULT_CPU_ACCESS_DENIED = 8'h70;
    assign dma_done = scheduler_dma_done;
    assign dma_fault = scheduler_dma_fault || access_denied_pulse;
    assign dma_fault_code = access_denied_pulse
                          ? FAULT_CPU_ACCESS_DENIED
                          : scheduler_dma_fault_code;

    // ---------------------------------------------------------------------
    // IOMMU and scheduler
    // ---------------------------------------------------------------------
    logic iommu_req_valid;
    logic iommu_req_ready;
    logic [AXI_ADDR_WIDTH-1:0] iommu_req_vaddr;
    logic [LEN_WIDTH-1:0] iommu_req_len;
    logic iommu_req_write;
    logic iommu_resp_valid;
    logic iommu_resp_allow;
    logic [AXI_ADDR_WIDTH-1:0] iommu_resp_paddr;
    logic [2:0] iommu_resp_fault;

    dma_iommu_tlb #(
        .ADDR_WIDTH(AXI_ADDR_WIDTH),
        .LEN_WIDTH(LEN_WIDTH),
        .PAGE_SHIFT(PAGE_SHIFT),
        .PT_ENTRIES(PT_ENTRIES),
        .TLB_ENTRIES(TLB_ENTRIES)
    ) iommu_inst (
        .clk_i(aclk),
        .rst_ni(aresetn),
        .req_valid_i(iommu_req_valid),
        .req_ready_o(iommu_req_ready),
        .req_vaddr_i(iommu_req_vaddr),
        .req_len_bytes_i(iommu_req_len),
        .req_write_i(iommu_req_write),
        .resp_valid_o(iommu_resp_valid),
        .resp_allow_o(iommu_resp_allow),
        .resp_paddr_o(iommu_resp_paddr),
        .resp_fault_o(iommu_resp_fault),
        .pt_write_i(pt_write),
        .pt_index_i(pt_index),
        .pt_vpn_i(pt_vpn),
        .pt_ppn_i(pt_ppn),
        .pt_valid_i(pt_valid),
        .pt_read_i(pt_read),
        .pt_write_perm_i(pt_write_perm),
        .tlb_invalidate_i(tlb_invalidate),
        .tlb_hit_count_o(tlb_hit_count),
        .tlb_miss_count_o(tlb_miss_count)
    );

    logic [AXI_ADDR_WIDTH-1:0] cdma_desc_src_addr;
    logic [AXI_ADDR_WIDTH-1:0] cdma_desc_dst_addr;
    logic [LEN_WIDTH-1:0] cdma_desc_len;
    logic cdma_desc_valid;
    wire cdma_desc_ready;
    wire [3:0] cdma_status_error;
    wire cdma_status_valid;

    logic [AXI_ADDR_WIDTH-1:0] rd_desc_addr;
    logic [LEN_WIDTH-1:0] rd_desc_len;
    logic rd_desc_valid;
    wire rd_desc_ready;
    wire [3:0] rd_status_error;
    wire rd_status_valid;
    logic rd_last_chunk;

    logic [AXI_ADDR_WIDTH-1:0] wr_desc_addr;
    logic [LEN_WIDTH-1:0] wr_desc_len;
    logic wr_desc_valid;
    wire wr_desc_ready;
    wire [3:0] wr_status_error;
    wire wr_status_valid;

    dma_axi_scheduler #(
        .ADDR_WIDTH(AXI_ADDR_WIDTH),
        .LEN_WIDTH(LEN_WIDTH),
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .PAGE_SHIFT(PAGE_SHIFT),
        .AXI_MAX_BURST_LEN(AXI_MAX_BURST_LEN)
    ) scheduler_inst (
        .clk_i(aclk),
        .rst_ni(aresetn),
        .cfg_start_i(scheduler_cfg_start),
        .cfg_transfer_type_i(scheduler_cfg_transfer_type),
        .cfg_dma_mode_i(scheduler_cfg_dma_mode),
        .cfg_burst_words_i(scheduler_cfg_burst_words),
        .cfg_src_vaddr_i(scheduler_cfg_src_vaddr),
        .cfg_dst_vaddr_i(scheduler_cfg_dst_vaddr),
        .cfg_length_bytes_i(scheduler_cfg_length_bytes),
        .cpu_bus_idle_i,
        .translation_invalidate_i(pt_write || tlb_invalidate),
        .busy_o(dma_busy),
        .done_o(scheduler_dma_done),
        .fault_o(scheduler_dma_fault),
        .fault_code_o(scheduler_dma_fault_code),
        .iommu_req_valid_o(iommu_req_valid),
        .iommu_req_ready_i(iommu_req_ready),
        .iommu_req_vaddr_o(iommu_req_vaddr),
        .iommu_req_len_o(iommu_req_len),
        .iommu_req_write_o(iommu_req_write),
        .iommu_resp_valid_i(iommu_resp_valid),
        .iommu_resp_allow_i(iommu_resp_allow),
        .iommu_resp_paddr_i(iommu_resp_paddr),
        .iommu_resp_fault_i(iommu_resp_fault),
        .cdma_desc_src_addr_o(cdma_desc_src_addr),
        .cdma_desc_dst_addr_o(cdma_desc_dst_addr),
        .cdma_desc_len_o(cdma_desc_len),
        .cdma_desc_valid_o(cdma_desc_valid),
        .cdma_desc_ready_i(cdma_desc_ready),
        .cdma_status_error_i(cdma_status_error),
        .cdma_status_valid_i(cdma_status_valid),
        .axis_rd_desc_addr_o(rd_desc_addr),
        .axis_rd_desc_len_o(rd_desc_len),
        .axis_rd_desc_valid_o(rd_desc_valid),
        .axis_rd_desc_ready_i(rd_desc_ready),
        .axis_rd_status_error_i(rd_status_error),
        .axis_rd_status_valid_i(rd_status_valid),
        .axis_rd_last_chunk_o(rd_last_chunk),
        .axis_wr_desc_addr_o(wr_desc_addr),
        .axis_wr_desc_len_o(wr_desc_len),
        .axis_wr_desc_valid_o(wr_desc_valid),
        .axis_wr_desc_ready_i(wr_desc_ready),
        .axis_wr_status_error_i(wr_status_error),
        .axis_wr_status_valid_i(wr_status_valid)
    );

    // ---------------------------------------------------------------------
    // AXI engines
    // ---------------------------------------------------------------------
    wire [AXI_ID_WIDTH-1:0] c_awid;
    wire [AXI_ADDR_WIDTH-1:0] c_awaddr;
    wire [7:0] c_awlen;
    wire [2:0] c_awsize;
    wire [1:0] c_awburst;
    wire c_awlock;
    wire [3:0] c_awcache;
    wire [2:0] c_awprot;
    wire c_awvalid;
    wire c_awready;
    wire [AXI_DATA_WIDTH-1:0] c_wdata;
    wire [AXI_STRB_WIDTH-1:0] c_wstrb;
    wire c_wlast;
    wire c_wvalid;
    wire c_wready;
    wire [AXI_ID_WIDTH-1:0] c_bid;
    wire [1:0] c_bresp;
    wire c_bvalid;
    wire c_bready;
    wire [AXI_ID_WIDTH-1:0] c_arid;
    wire [AXI_ADDR_WIDTH-1:0] c_araddr;
    wire [7:0] c_arlen;
    wire [2:0] c_arsize;
    wire [1:0] c_arburst;
    wire c_arlock;
    wire [3:0] c_arcache;
    wire [2:0] c_arprot;
    wire c_arvalid;
    wire c_arready;
    wire [AXI_ID_WIDTH-1:0] c_rid;
    wire [AXI_DATA_WIDTH-1:0] c_rdata;
    wire [1:0] c_rresp;
    wire c_rlast;
    wire c_rvalid;
    wire c_rready;

    axi_cdma #(
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_STRB_WIDTH(AXI_STRB_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .AXI_MAX_BURST_LEN(AXI_MAX_BURST_LEN),
        .LEN_WIDTH(ENGINE_LEN_WIDTH),
        .TAG_WIDTH(8),
        .ENABLE_UNALIGNED(0)
    ) cdma_inst (
        .clk(aclk), .rst(rst),
        .s_axis_desc_read_addr(cdma_desc_src_addr),
        .s_axis_desc_write_addr(cdma_desc_dst_addr),
        .s_axis_desc_len(cdma_desc_len[ENGINE_LEN_WIDTH-1:0]),
        .s_axis_desc_tag(8'd0),
        .s_axis_desc_valid(cdma_desc_valid),
        .s_axis_desc_ready(cdma_desc_ready),
        .m_axis_desc_status_tag(),
        .m_axis_desc_status_error(cdma_status_error),
        .m_axis_desc_status_valid(cdma_status_valid),
        .m_axi_awid(c_awid), .m_axi_awaddr(c_awaddr),
        .m_axi_awlen(c_awlen), .m_axi_awsize(c_awsize),
        .m_axi_awburst(c_awburst), .m_axi_awlock(c_awlock),
        .m_axi_awcache(c_awcache), .m_axi_awprot(c_awprot),
        .m_axi_awvalid(c_awvalid), .m_axi_awready(c_awready),
        .m_axi_wdata(c_wdata), .m_axi_wstrb(c_wstrb),
        .m_axi_wlast(c_wlast), .m_axi_wvalid(c_wvalid),
        .m_axi_wready(c_wready), .m_axi_bid(c_bid),
        .m_axi_bresp(c_bresp), .m_axi_bvalid(c_bvalid),
        .m_axi_bready(c_bready), .m_axi_arid(c_arid),
        .m_axi_araddr(c_araddr), .m_axi_arlen(c_arlen),
        .m_axi_arsize(c_arsize), .m_axi_arburst(c_arburst),
        .m_axi_arlock(c_arlock), .m_axi_arcache(c_arcache),
        .m_axi_arprot(c_arprot), .m_axi_arvalid(c_arvalid),
        .m_axi_arready(c_arready), .m_axi_rid(c_rid),
        .m_axi_rdata(c_rdata), .m_axi_rresp(c_rresp),
        .m_axi_rlast(c_rlast), .m_axi_rvalid(c_rvalid),
        .m_axi_rready(c_rready), .enable(1'b1)
    );

    wire [AXI_ID_WIDTH-1:0] d_arid;
    wire [AXI_ADDR_WIDTH-1:0] d_araddr;
    wire [7:0] d_arlen;
    wire [2:0] d_arsize;
    wire [1:0] d_arburst;
    wire d_arlock;
    wire [3:0] d_arcache;
    wire [2:0] d_arprot;
    wire d_arvalid;
    wire d_arready;
    wire [AXI_ID_WIDTH-1:0] d_rid;
    wire [AXI_DATA_WIDTH-1:0] d_rdata;
    wire [1:0] d_rresp;
    wire d_rlast;
    wire d_rvalid;
    wire d_rready;
    wire [AXI_DATA_WIDTH-1:0] rd_tdata;
    wire [AXI_STRB_WIDTH-1:0] rd_tkeep;
    wire rd_tvalid;
    wire rd_tready;
    wire rd_tlast;

    axi_dma_rd #(
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_STRB_WIDTH(AXI_STRB_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .AXI_MAX_BURST_LEN(AXI_MAX_BURST_LEN),
        .AXIS_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXIS_KEEP_ENABLE(1),
        .AXIS_KEEP_WIDTH(AXI_STRB_WIDTH),
        .AXIS_LAST_ENABLE(1),
        .AXIS_ID_ENABLE(0), .AXIS_ID_WIDTH(1),
        .AXIS_DEST_ENABLE(0), .AXIS_DEST_WIDTH(1),
        .AXIS_USER_ENABLE(0), .AXIS_USER_WIDTH(1),
        .LEN_WIDTH(ENGINE_LEN_WIDTH), .TAG_WIDTH(8),
        .ENABLE_SG(0), .ENABLE_UNALIGNED(0),
        .SINGLE_BURST_DESC(1)
    ) dma_rd_inst (
        .clk(aclk), .rst(rst),
        .s_axis_read_desc_addr(rd_desc_addr),
        .s_axis_read_desc_len(rd_desc_len[ENGINE_LEN_WIDTH-1:0]),
        .s_axis_read_desc_tag(8'd0),
        .s_axis_read_desc_id(1'b0),
        .s_axis_read_desc_dest(1'b0),
        .s_axis_read_desc_user(1'b0),
        .s_axis_read_desc_valid(rd_desc_valid),
        .s_axis_read_desc_ready(rd_desc_ready),
        .m_axis_read_desc_status_tag(),
        .m_axis_read_desc_status_error(rd_status_error),
        .m_axis_read_desc_status_valid(rd_status_valid),
        .m_axis_read_data_tdata(rd_tdata),
        .m_axis_read_data_tkeep(rd_tkeep),
        .m_axis_read_data_tvalid(rd_tvalid),
        .m_axis_read_data_tready(rd_tready),
        .m_axis_read_data_tlast(rd_tlast),
        .m_axis_read_data_tid(), .m_axis_read_data_tdest(),
        .m_axis_read_data_tuser(),
        .m_axi_arid(d_arid), .m_axi_araddr(d_araddr),
        .m_axi_arlen(d_arlen), .m_axi_arsize(d_arsize),
        .m_axi_arburst(d_arburst), .m_axi_arlock(d_arlock),
        .m_axi_arcache(d_arcache), .m_axi_arprot(d_arprot),
        .m_axi_arvalid(d_arvalid), .m_axi_arready(d_arready),
        .m_axi_rid(d_rid), .m_axi_rdata(d_rdata),
        .m_axi_rresp(d_rresp), .m_axi_rlast(d_rlast),
        .m_axi_rvalid(d_rvalid), .m_axi_rready(d_rready),
        .enable(1'b1)
    );

    wire [AXI_ID_WIDTH-1:0] d_awid;
    wire [AXI_ADDR_WIDTH-1:0] d_awaddr;
    wire [7:0] d_awlen;
    wire [2:0] d_awsize;
    wire [1:0] d_awburst;
    wire d_awlock;
    wire [3:0] d_awcache;
    wire [2:0] d_awprot;
    wire d_awvalid;
    wire d_awready;
    wire [AXI_DATA_WIDTH-1:0] d_wdata;
    wire [AXI_STRB_WIDTH-1:0] d_wstrb;
    wire d_wlast;
    wire d_wvalid;
    wire d_wready;
    wire [AXI_ID_WIDTH-1:0] d_bid;
    wire [1:0] d_bresp;
    wire d_bvalid;
    wire d_bready;

    axi_dma_wr #(
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_STRB_WIDTH(AXI_STRB_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .AXI_MAX_BURST_LEN(AXI_MAX_BURST_LEN),
        .AXIS_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXIS_KEEP_ENABLE(1),
        .AXIS_KEEP_WIDTH(AXI_STRB_WIDTH),
        // Descriptor length controls chunking; top-level TLAST is accepted
        // as frame metadata but is not allowed to terminate an intermediate
        // one-beat cycle-stealing descriptor.
        .AXIS_LAST_ENABLE(0),
        .AXIS_ID_ENABLE(0), .AXIS_ID_WIDTH(1),
        .AXIS_DEST_ENABLE(0), .AXIS_DEST_WIDTH(1),
        .AXIS_USER_ENABLE(0), .AXIS_USER_WIDTH(1),
        .LEN_WIDTH(ENGINE_LEN_WIDTH), .TAG_WIDTH(8),
        .ENABLE_SG(0), .ENABLE_UNALIGNED(0)
    ) dma_wr_inst (
        .clk(aclk), .rst(rst),
        .s_axis_write_desc_addr(wr_desc_addr),
        .s_axis_write_desc_len(wr_desc_len[ENGINE_LEN_WIDTH-1:0]),
        .s_axis_write_desc_tag(8'd0),
        .s_axis_write_desc_valid(wr_desc_valid),
        .s_axis_write_desc_ready(wr_desc_ready),
        .m_axis_write_desc_status_len(),
        .m_axis_write_desc_status_tag(),
        .m_axis_write_desc_status_id(),
        .m_axis_write_desc_status_dest(),
        .m_axis_write_desc_status_user(),
        .m_axis_write_desc_status_error(wr_status_error),
        .m_axis_write_desc_status_valid(wr_status_valid),
        .s_axis_write_data_tdata(s_axis_periph_tdata),
        .s_axis_write_data_tkeep(s_axis_periph_tkeep),
        .s_axis_write_data_tvalid(s_axis_periph_tvalid),
        .s_axis_write_data_tready(s_axis_periph_tready),
        .s_axis_write_data_tlast(s_axis_periph_tlast),
        .s_axis_write_data_tid(1'b0),
        .s_axis_write_data_tdest(1'b0),
        .s_axis_write_data_tuser(1'b0),
        .m_axi_awid(d_awid), .m_axi_awaddr(d_awaddr),
        .m_axi_awlen(d_awlen), .m_axi_awsize(d_awsize),
        .m_axi_awburst(d_awburst), .m_axi_awlock(d_awlock),
        .m_axi_awcache(d_awcache), .m_axi_awprot(d_awprot),
        .m_axi_awvalid(d_awvalid), .m_axi_awready(d_awready),
        .m_axi_wdata(d_wdata), .m_axi_wstrb(d_wstrb),
        .m_axi_wlast(d_wlast), .m_axi_wvalid(d_wvalid),
        .m_axi_wready(d_wready), .m_axi_bid(d_bid),
        .m_axi_bresp(d_bresp), .m_axi_bvalid(d_bvalid),
        .m_axi_bready(d_bready), .enable(1'b1), .abort(1'b0)
    );

    // The read engine can complete its descriptor status before all buffered
    // AXI-Stream beats leave its output FIFO.  Therefore TLAST is generated
    // from an independent end-to-end byte counter, not from scheduler state.
    logic [LEN_WIDTH-1:0] m2s_bytes_remaining_q;
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            m2s_bytes_remaining_q <= '0;
        end else begin
            if (scheduler_cfg_start
                    && scheduler_cfg_transfer_type == 2'd2)
                m2s_bytes_remaining_q <= scheduler_cfg_length_bytes;
            else if (rd_tvalid && rd_tready
                     && m2s_bytes_remaining_q >= AXI_STRB_WIDTH)
                m2s_bytes_remaining_q <= m2s_bytes_remaining_q
                                          - AXI_STRB_WIDTH;
        end
    end

    assign m_axis_periph_tdata = rd_tdata;
    assign m_axis_periph_tkeep = rd_tkeep;
    assign m_axis_periph_tvalid = rd_tvalid;
    assign rd_tready = m_axis_periph_tready;
    assign m_axis_periph_tlast = rd_tvalid
                               && m2s_bytes_remaining_q == AXI_STRB_WIDTH;

    // ---------------------------------------------------------------------
    // On-board throughput monitor
    // ---------------------------------------------------------------------
    // One command is active at a time.  Consequently the merged top-level
    // AXI handshakes can be attributed unambiguously to that command.  The
    // source/destination counters describe the DMA endpoints; AXI counters
    // describe complete memory transactions (AR..RLAST and AW..BRESP).
    function automatic logic [31:0] perf_keep_bytes(
        input logic [AXI_STRB_WIDTH-1:0] keep
    );
        integer k;
        begin
            perf_keep_bytes = 32'd0;
            for (k = 0; k < AXI_STRB_WIDTH; k = k + 1)
                perf_keep_bytes = perf_keep_bytes + keep[k];
        end
    endfunction

    logic perf_active_q;
    logic perf_done_pending_q;
    logic [31:0] perf_cycle_q;
    logic [1:0] perf_type_q;
    logic [1:0] perf_mode_q;
    logic [31:0] perf_length_q;

    logic perf_src_seen_q;
    logic [31:0] perf_src_first_q, perf_src_last_q;
    logic [31:0] perf_src_bytes_q;
    logic perf_dst_seen_q;
    logic [31:0] perf_dst_first_q, perf_dst_last_q;
    logic [31:0] perf_dst_bytes_q;
    logic perf_ar_seen_q;
    logic [31:0] perf_ar_first_q;
    logic perf_r_done_seen_q;
    logic [31:0] perf_r_done_q;
    logic [31:0] perf_axi_r_bytes_q;
    logic perf_aw_seen_q;
    logic [31:0] perf_aw_first_q;
    logic perf_b_done_seen_q;
    logic [31:0] perf_b_done_q;
    logic [31:0] perf_axi_w_bytes_q;

    wire perf_axi_r_hs = m_axi_rvalid && m_axi_rready;
    wire perf_axi_w_hs = m_axi_wvalid && m_axi_wready;
    wire perf_ar_hs = m_axi_arvalid && m_axi_arready;
    wire perf_aw_hs = m_axi_awvalid && m_axi_awready;
    wire perf_b_hs = m_axi_bvalid && m_axi_bready;
    wire perf_axis_in_hs = s_axis_periph_tvalid
                              && s_axis_periph_tready;
    wire perf_axis_out_hs = m_axis_periph_tvalid
                               && m_axis_periph_tready;
    wire perf_src_hs = (perf_type_q == 2'd1) ? perf_axis_in_hs
                                                : perf_axi_r_hs;
    wire perf_dst_hs = (perf_type_q == 2'd2) ? perf_axis_out_hs
                                                : perf_axi_w_hs;
    wire [31:0] perf_src_hs_bytes =
        (perf_type_q == 2'd1) ? perf_keep_bytes(s_axis_periph_tkeep)
                              : AXI_STRB_WIDTH;
    wire [31:0] perf_dst_hs_bytes =
        (perf_type_q == 2'd2) ? perf_keep_bytes(m_axis_periph_tkeep)
                              : perf_keep_bytes(m_axi_wstrb);

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            perf_active_q <= 1'b0;
            perf_done_pending_q <= 1'b0;
            perf_cycle_q <= 32'd0;
            perf_type_q <= 2'd0;
            perf_mode_q <= 2'd0;
            perf_length_q <= 32'd0;
            perf_src_seen_q <= 1'b0;
            perf_src_first_q <= 32'd0;
            perf_src_last_q <= 32'd0;
            perf_src_bytes_q <= 32'd0;
            perf_dst_seen_q <= 1'b0;
            perf_dst_first_q <= 32'd0;
            perf_dst_last_q <= 32'd0;
            perf_dst_bytes_q <= 32'd0;
            perf_ar_seen_q <= 1'b0;
            perf_ar_first_q <= 32'd0;
            perf_r_done_seen_q <= 1'b0;
            perf_r_done_q <= 32'd0;
            perf_axi_r_bytes_q <= 32'd0;
            perf_aw_seen_q <= 1'b0;
            perf_aw_first_q <= 32'd0;
            perf_b_done_seen_q <= 1'b0;
            perf_b_done_q <= 32'd0;
            perf_axi_w_bytes_q <= 32'd0;
            perf_seq <= 32'd0;
            perf_valid <= 1'b0;
            perf_fault <= 1'b0;
            perf_transfer_type <= 2'd0;
            perf_dma_mode <= 2'd0;
            perf_length <= 32'd0;
            perf_total_cycles <= 32'd0;
            perf_src_bytes <= 32'd0;
            perf_src_span <= 32'd0;
            perf_dst_bytes <= 32'd0;
            perf_dst_span <= 32'd0;
            perf_axi_r_bytes <= 32'd0;
            perf_axi_r_cycles <= 32'd0;
            perf_axi_w_bytes <= 32'd0;
            perf_axi_w_cycles <= 32'd0;
        end else if (scheduler_cfg_start) begin
            perf_active_q <= 1'b1;
            perf_done_pending_q <= 1'b0;
            perf_cycle_q <= 32'd0;
            perf_type_q <= scheduler_cfg_transfer_type;
            perf_mode_q <= scheduler_cfg_dma_mode;
            perf_length_q <= {{(32-LEN_WIDTH){1'b0}},
                              scheduler_cfg_length_bytes};
            perf_src_seen_q <= 1'b0;
            perf_src_first_q <= 32'd0;
            perf_src_last_q <= 32'd0;
            perf_src_bytes_q <= 32'd0;
            perf_dst_seen_q <= 1'b0;
            perf_dst_first_q <= 32'd0;
            perf_dst_last_q <= 32'd0;
            perf_dst_bytes_q <= 32'd0;
            perf_ar_seen_q <= 1'b0;
            perf_ar_first_q <= 32'd0;
            perf_r_done_seen_q <= 1'b0;
            perf_r_done_q <= 32'd0;
            perf_axi_r_bytes_q <= 32'd0;
            perf_aw_seen_q <= 1'b0;
            perf_aw_first_q <= 32'd0;
            perf_b_done_seen_q <= 1'b0;
            perf_b_done_q <= 32'd0;
            perf_axi_w_bytes_q <= 32'd0;
        end else if (perf_active_q) begin
            perf_cycle_q <= perf_cycle_q + 1'b1;

            // The read engine reports descriptor completion before every
            // buffered AXI-Stream beat is necessarily accepted downstream.
            // Remember that early DONE and keep measuring until the complete
            // M2S payload has crossed the DMA output handshake.
            if (dma_done && perf_type_q == 2'd2)
                perf_done_pending_q <= 1'b1;

            if (perf_src_hs) begin
                if (!perf_src_seen_q) perf_src_first_q <= perf_cycle_q;
                perf_src_seen_q <= 1'b1;
                perf_src_last_q <= perf_cycle_q;
                perf_src_bytes_q <= perf_src_bytes_q + perf_src_hs_bytes;
            end
            if (perf_dst_hs) begin
                if (!perf_dst_seen_q) perf_dst_first_q <= perf_cycle_q;
                perf_dst_seen_q <= 1'b1;
                perf_dst_last_q <= perf_cycle_q;
                perf_dst_bytes_q <= perf_dst_bytes_q + perf_dst_hs_bytes;
            end
            if (perf_ar_hs && !perf_ar_seen_q) begin
                perf_ar_seen_q <= 1'b1;
                perf_ar_first_q <= perf_cycle_q;
            end
            if (perf_axi_r_hs) begin
                perf_axi_r_bytes_q <= perf_axi_r_bytes_q + AXI_STRB_WIDTH;
                if (m_axi_rlast) begin
                    perf_r_done_seen_q <= 1'b1;
                    perf_r_done_q <= perf_cycle_q;
                end
            end
            if (perf_aw_hs && !perf_aw_seen_q) begin
                perf_aw_seen_q <= 1'b1;
                perf_aw_first_q <= perf_cycle_q;
            end
            if (perf_axi_w_hs)
                perf_axi_w_bytes_q <= perf_axi_w_bytes_q
                                      + perf_keep_bytes(m_axi_wstrb);
            if (perf_b_hs) begin
                perf_b_done_seen_q <= 1'b1;
                perf_b_done_q <= perf_cycle_q;
            end

            if (dma_fault
                    || (perf_type_q != 2'd2 && dma_done)
                    || ((perf_done_pending_q || dma_done)
                        && perf_type_q == 2'd2
                        && perf_dst_bytes_q
                           + (perf_dst_hs ? perf_dst_hs_bytes : 0)
                           >= perf_length_q)) begin
                perf_active_q <= 1'b0;
                perf_done_pending_q <= 1'b0;
                perf_seq <= perf_seq + 1'b1;
                perf_valid <= 1'b1;
                perf_fault <= dma_fault;
                perf_transfer_type <= perf_type_q;
                perf_dma_mode <= perf_mode_q;
                perf_length <= perf_length_q;
                perf_total_cycles <= perf_cycle_q + 1'b1;
                perf_src_bytes <= perf_src_bytes_q
                                  + (perf_src_hs ? perf_src_hs_bytes : 0);
                perf_src_span <= perf_src_hs
                    ? (perf_src_seen_q
                       ? perf_cycle_q - perf_src_first_q + 1'b1 : 32'd1)
                    : (perf_src_seen_q
                       ? perf_src_last_q - perf_src_first_q + 1'b1 : 32'd0);
                perf_dst_bytes <= perf_dst_bytes_q
                                  + (perf_dst_hs ? perf_dst_hs_bytes : 0);
                perf_dst_span <= perf_dst_hs
                    ? (perf_dst_seen_q
                       ? perf_cycle_q - perf_dst_first_q + 1'b1 : 32'd1)
                    : (perf_dst_seen_q
                       ? perf_dst_last_q - perf_dst_first_q + 1'b1 : 32'd0);
                perf_axi_r_bytes <= perf_axi_r_bytes_q
                    + (perf_axi_r_hs ? AXI_STRB_WIDTH : 0);
                perf_axi_r_cycles <= (perf_axi_r_hs && m_axi_rlast)
                    ? (perf_ar_seen_q
                       ? perf_cycle_q - perf_ar_first_q + 1'b1 : 32'd1)
                    : ((perf_ar_seen_q && perf_r_done_seen_q)
                       ? perf_r_done_q - perf_ar_first_q + 1'b1 : 32'd0);
                perf_axi_w_bytes <= perf_axi_w_bytes_q
                    + (perf_axi_w_hs ? perf_keep_bytes(m_axi_wstrb) : 0);
                perf_axi_w_cycles <= perf_b_hs
                    ? (perf_aw_seen_q
                       ? perf_cycle_q - perf_aw_first_q + 1'b1 : 32'd1)
                    : ((perf_aw_seen_q && perf_b_done_seen_q)
                       ? perf_b_done_q - perf_aw_first_q + 1'b1 : 32'd0);
            end
        end
    end

    // ---------------------------------------------------------------------
    // Fair AXI4 arbitration.  Port 0 is CDMA; port 1 combines stream read and
    // stream write engines.  axi_crossbar has separate read and write
    // arbiters; both use round-robin and hold ownership until the final
    // BRESP/RLAST.  Separate arbiters are required because CDMA reads and
    // writes concurrently.
    // ---------------------------------------------------------------------
    wire [1:0] ic_s_awready;
    wire [1:0] ic_s_wready;
    wire [2*AXI_ID_WIDTH-1:0] ic_s_bid;
    wire [3:0] ic_s_bresp;
    wire [1:0] ic_s_bvalid;
    wire [1:0] ic_s_arready;
    wire [2*AXI_ID_WIDTH-1:0] ic_s_rid;
    wire [2*AXI_DATA_WIDTH-1:0] ic_s_rdata;
    wire [3:0] ic_s_rresp;
    wire [1:0] ic_s_rlast;
    wire [1:0] ic_s_rvalid;
    wire [1:0] unused_s_buser;
    wire [1:0] unused_s_ruser;
    wire unused_m_awuser;
    wire unused_m_wuser;
    wire unused_m_aruser;

    assign c_awready = ic_s_awready[0];
    assign d_awready = ic_s_awready[1];
    assign c_wready = ic_s_wready[0];
    assign d_wready = ic_s_wready[1];
    assign c_bid = ic_s_bid[0 +: AXI_ID_WIDTH];
    assign d_bid = ic_s_bid[AXI_ID_WIDTH +: AXI_ID_WIDTH];
    assign c_bresp = ic_s_bresp[0 +: 2];
    assign d_bresp = ic_s_bresp[2 +: 2];
    assign c_bvalid = ic_s_bvalid[0];
    assign d_bvalid = ic_s_bvalid[1];
    assign c_arready = ic_s_arready[0];
    assign d_arready = ic_s_arready[1];
    assign c_rid = ic_s_rid[0 +: AXI_ID_WIDTH];
    assign d_rid = ic_s_rid[AXI_ID_WIDTH +: AXI_ID_WIDTH];
    assign c_rdata = ic_s_rdata[0 +: AXI_DATA_WIDTH];
    assign d_rdata = ic_s_rdata[AXI_DATA_WIDTH +: AXI_DATA_WIDTH];
    assign c_rresp = ic_s_rresp[0 +: 2];
    assign d_rresp = ic_s_rresp[2 +: 2];
    assign c_rlast = ic_s_rlast[0];
    assign d_rlast = ic_s_rlast[1];
    assign c_rvalid = ic_s_rvalid[0];
    assign d_rvalid = ic_s_rvalid[1];

    axi_crossbar #(
        .S_COUNT(2), .M_COUNT(1),
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .ADDR_WIDTH(AXI_ADDR_WIDTH),
        .STRB_WIDTH(AXI_STRB_WIDTH),
        .S_ID_WIDTH(AXI_ID_WIDTH),
        .M_ID_WIDTH(AXI_ID_WIDTH+1),
        .AWUSER_ENABLE(0), .AWUSER_WIDTH(1),
        .WUSER_ENABLE(0), .WUSER_WIDTH(1),
        .BUSER_ENABLE(0), .BUSER_WIDTH(1),
        .ARUSER_ENABLE(0), .ARUSER_WIDTH(1),
        .RUSER_ENABLE(0), .RUSER_WIDTH(1),
        .S_THREADS({2{32'd1}}),
        .S_ACCEPT({2{32'd4}}),
        .M_REGIONS(1),
        .M_BASE_ADDR(0), .M_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .M_CONNECT_READ(2'b11), .M_CONNECT_WRITE(2'b11),
        .M_ISSUE(32'd8), .M_SECURE(1'b0)
    ) crossbar_inst (
        .clk(aclk), .rst(rst),
        .s_axi_awid({d_awid, c_awid}),
        .s_axi_awaddr({d_awaddr, c_awaddr}),
        .s_axi_awlen({d_awlen, c_awlen}),
        .s_axi_awsize({d_awsize, c_awsize}),
        .s_axi_awburst({d_awburst, c_awburst}),
        .s_axi_awlock({d_awlock, c_awlock}),
        .s_axi_awcache({d_awcache, c_awcache}),
        .s_axi_awprot({d_awprot, c_awprot}),
        .s_axi_awqos(8'd0), .s_axi_awuser(2'd0),
        .s_axi_awvalid({d_awvalid, c_awvalid}),
        .s_axi_awready(ic_s_awready),
        .s_axi_wdata({d_wdata, c_wdata}),
        .s_axi_wstrb({d_wstrb, c_wstrb}),
        .s_axi_wlast({d_wlast, c_wlast}),
        .s_axi_wuser(2'd0),
        .s_axi_wvalid({d_wvalid, c_wvalid}),
        .s_axi_wready(ic_s_wready),
        .s_axi_bid(ic_s_bid), .s_axi_bresp(ic_s_bresp),
        .s_axi_buser(unused_s_buser), .s_axi_bvalid(ic_s_bvalid),
        .s_axi_bready({d_bready, c_bready}),
        .s_axi_arid({d_arid, c_arid}),
        .s_axi_araddr({d_araddr, c_araddr}),
        .s_axi_arlen({d_arlen, c_arlen}),
        .s_axi_arsize({d_arsize, c_arsize}),
        .s_axi_arburst({d_arburst, c_arburst}),
        .s_axi_arlock({d_arlock, c_arlock}),
        .s_axi_arcache({d_arcache, c_arcache}),
        .s_axi_arprot({d_arprot, c_arprot}),
        .s_axi_arqos(8'd0), .s_axi_aruser(2'd0),
        .s_axi_arvalid({d_arvalid, c_arvalid}),
        .s_axi_arready(ic_s_arready),
        .s_axi_rid(ic_s_rid), .s_axi_rdata(ic_s_rdata),
        .s_axi_rresp(ic_s_rresp), .s_axi_rlast(ic_s_rlast),
        .s_axi_ruser(unused_s_ruser), .s_axi_rvalid(ic_s_rvalid),
        .s_axi_rready({d_rready, c_rready}),
        .m_axi_awid, .m_axi_awaddr, .m_axi_awlen, .m_axi_awsize,
        .m_axi_awburst, .m_axi_awlock, .m_axi_awcache,
        .m_axi_awprot, .m_axi_awqos, .m_axi_awregion,
        .m_axi_awuser(unused_m_awuser), .m_axi_awvalid,
        .m_axi_awready, .m_axi_wdata, .m_axi_wstrb,
        .m_axi_wlast, .m_axi_wuser(unused_m_wuser),
        .m_axi_wvalid, .m_axi_wready, .m_axi_bid,
        .m_axi_bresp, .m_axi_buser(1'b0), .m_axi_bvalid,
        .m_axi_bready, .m_axi_arid, .m_axi_araddr,
        .m_axi_arlen, .m_axi_arsize, .m_axi_arburst,
        .m_axi_arlock, .m_axi_arcache, .m_axi_arprot,
        .m_axi_arqos, .m_axi_arregion,
        .m_axi_aruser(unused_m_aruser), .m_axi_arvalid,
        .m_axi_arready, .m_axi_rid, .m_axi_rdata,
        .m_axi_rresp, .m_axi_rlast, .m_axi_ruser(1'b0),
        .m_axi_rvalid, .m_axi_rready
    );

endmodule
