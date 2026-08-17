`timescale 1ns / 1ps

module tb_dma_mmu_axi_top #(
    parameter bit AUTO_FINISH = 1'b1,
    parameter LOG_PATH = "D:/DMA_MMU-main(1)/reports/dma_mmu_axi_test.log",
    parameter PERF_LOG_PATH = "D:/DMA_MMU-main(1)/reports/dma_throughput.log",
    parameter EDGE_LOG_PATH = "D:/DMA_MMU-main(1)/reports/dma_edge_cases.log"
) (
    output logic test_done_o,
    output logic test_pass_o
);

    localparam int AXI_ADDR_WIDTH = 16;
    localparam int AXI_DATA_WIDTH = 32;
    localparam int AXI_ID_WIDTH = 4;
    localparam int M_AXI_ID_WIDTH = AXI_ID_WIDTH+1;
    localparam int WORDS = 8;
    localparam int BUS_BYTES = AXI_DATA_WIDTH/8;
    // Match the behavioral benchmark to the post-route verified SoC target.
    localparam real SIM_CLOCK_PERIOD_NS = 6.667;
    localparam real SIM_CLOCK_MHZ = 1000.0/SIM_CLOCK_PERIOD_NS;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #(SIM_CLOCK_PERIOD_NS/2.0) clk = ~clk;

    logic cpu_bus_idle;
    wire irq;

    logic [7:0] axil_awaddr;
    logic [2:0] axil_awprot;
    logic axil_awvalid;
    wire axil_awready;
    logic [31:0] axil_wdata;
    logic [3:0] axil_wstrb;
    logic axil_wvalid;
    wire axil_wready;
    wire [1:0] axil_bresp;
    wire axil_bvalid;
    logic axil_bready;
    logic [7:0] axil_araddr;
    logic [2:0] axil_arprot;
    logic axil_arvalid;
    wire axil_arready;
    wire [31:0] axil_rdata;
    wire [1:0] axil_rresp;
    wire axil_rvalid;
    logic axil_rready;

    wire [M_AXI_ID_WIDTH-1:0] m_axi_awid;
    wire [AXI_ADDR_WIDTH-1:0] m_axi_awaddr;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire m_axi_awlock;
    wire [3:0] m_axi_awcache;
    wire [2:0] m_axi_awprot;
    wire [3:0] m_axi_awqos;
    wire [3:0] m_axi_awregion;
    wire m_axi_awvalid;
    wire m_axi_awready;
    wire [AXI_DATA_WIDTH-1:0] m_axi_wdata;
    wire [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb;
    wire m_axi_wlast;
    wire m_axi_wvalid;
    wire m_axi_wready;
    wire [M_AXI_ID_WIDTH-1:0] m_axi_bid;
    wire [1:0] m_axi_bresp;
    wire m_axi_bvalid;
    wire m_axi_bready;
    wire [M_AXI_ID_WIDTH-1:0] m_axi_arid;
    wire [AXI_ADDR_WIDTH-1:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire m_axi_arlock;
    wire [3:0] m_axi_arcache;
    wire [2:0] m_axi_arprot;
    wire [3:0] m_axi_arqos;
    wire [3:0] m_axi_arregion;
    wire m_axi_arvalid;
    wire m_axi_arready;
    wire [M_AXI_ID_WIDTH-1:0] m_axi_rid;
    wire [AXI_DATA_WIDTH-1:0] m_axi_rdata;
    wire [1:0] m_axi_rresp;
    wire m_axi_rlast;
    wire m_axi_rvalid;
    wire m_axi_rready;

    logic [31:0] s_axis_tdata;
    logic [3:0] s_axis_tkeep;
    logic s_axis_tvalid;
    wire s_axis_tready;
    logic s_axis_tlast;
    wire [31:0] m_axis_tdata;
    wire [3:0] m_axis_tkeep;
    wire m_axis_tvalid;
    logic m_axis_tready;
    wire m_axis_tlast;

    dma_mmu_axi_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .AXIL_ADDR_WIDTH(8),
        .LEN_WIDTH(16),
        .PAGE_SHIFT(12),
        .PT_ENTRIES(16),
        .TLB_ENTRIES(4),
        .AXI_MAX_BURST_LEN(16)
    ) dut (
        .aclk(clk), .aresetn(rst_n), .cpu_bus_idle_i(cpu_bus_idle),
        .irq_o(irq),
        .s_axil_awaddr(axil_awaddr), .s_axil_awprot(axil_awprot),
        .s_axil_awvalid(axil_awvalid), .s_axil_awready(axil_awready),
        .s_axil_wdata(axil_wdata), .s_axil_wstrb(axil_wstrb),
        .s_axil_wvalid(axil_wvalid), .s_axil_wready(axil_wready),
        .s_axil_bresp(axil_bresp), .s_axil_bvalid(axil_bvalid),
        .s_axil_bready(axil_bready), .s_axil_araddr(axil_araddr),
        .s_axil_arprot(axil_arprot), .s_axil_arvalid(axil_arvalid),
        .s_axil_arready(axil_arready), .s_axil_rdata(axil_rdata),
        .s_axil_rresp(axil_rresp), .s_axil_rvalid(axil_rvalid),
        .s_axil_rready(axil_rready),
        .m_axi_awid, .m_axi_awaddr, .m_axi_awlen, .m_axi_awsize,
        .m_axi_awburst, .m_axi_awlock, .m_axi_awcache, .m_axi_awprot,
        .m_axi_awqos, .m_axi_awregion, .m_axi_awvalid, .m_axi_awready,
        .m_axi_wdata, .m_axi_wstrb, .m_axi_wlast, .m_axi_wvalid,
        .m_axi_wready, .m_axi_bid, .m_axi_bresp, .m_axi_bvalid,
        .m_axi_bready, .m_axi_arid, .m_axi_araddr, .m_axi_arlen,
        .m_axi_arsize, .m_axi_arburst, .m_axi_arlock, .m_axi_arcache,
        .m_axi_arprot, .m_axi_arqos, .m_axi_arregion, .m_axi_arvalid,
        .m_axi_arready, .m_axi_rid, .m_axi_rdata, .m_axi_rresp,
        .m_axi_rlast, .m_axi_rvalid, .m_axi_rready,
        .s_axis_periph_tdata(s_axis_tdata),
        .s_axis_periph_tkeep(s_axis_tkeep),
        .s_axis_periph_tvalid(s_axis_tvalid),
        .s_axis_periph_tready(s_axis_tready),
        .s_axis_periph_tlast(s_axis_tlast),
        .m_axis_periph_tdata(m_axis_tdata),
        .m_axis_periph_tkeep(m_axis_tkeep),
        .m_axis_periph_tvalid(m_axis_tvalid),
        .m_axis_periph_tready(m_axis_tready),
        .m_axis_periph_tlast(m_axis_tlast)
    );

    axi_ram #(
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .ADDR_WIDTH(AXI_ADDR_WIDTH),
        .STRB_WIDTH(AXI_DATA_WIDTH/8),
        .ID_WIDTH(M_AXI_ID_WIDTH),
        .PIPELINE_OUTPUT(0)
    ) mem_inst (
        .clk(clk), .rst(!rst_n),
        .s_axi_awid(m_axi_awid), .s_axi_awaddr(m_axi_awaddr),
        .s_axi_awlen(m_axi_awlen), .s_axi_awsize(m_axi_awsize),
        .s_axi_awburst(m_axi_awburst), .s_axi_awlock(m_axi_awlock),
        .s_axi_awcache(m_axi_awcache), .s_axi_awprot(m_axi_awprot),
        .s_axi_awvalid(m_axi_awvalid), .s_axi_awready(m_axi_awready),
        .s_axi_wdata(m_axi_wdata), .s_axi_wstrb(m_axi_wstrb),
        .s_axi_wlast(m_axi_wlast), .s_axi_wvalid(m_axi_wvalid),
        .s_axi_wready(m_axi_wready), .s_axi_bid(m_axi_bid),
        .s_axi_bresp(m_axi_bresp), .s_axi_bvalid(m_axi_bvalid),
        .s_axi_bready(m_axi_bready), .s_axi_arid(m_axi_arid),
        .s_axi_araddr(m_axi_araddr), .s_axi_arlen(m_axi_arlen),
        .s_axi_arsize(m_axi_arsize), .s_axi_arburst(m_axi_arburst),
        .s_axi_arlock(m_axi_arlock), .s_axi_arcache(m_axi_arcache),
        .s_axi_arprot(m_axi_arprot), .s_axi_arvalid(m_axi_arvalid),
        .s_axi_arready(m_axi_arready), .s_axi_rid(m_axi_rid),
        .s_axi_rdata(m_axi_rdata), .s_axi_rresp(m_axi_rresp),
        .s_axi_rlast(m_axi_rlast), .s_axi_rvalid(m_axi_rvalid),
        .s_axi_rready(m_axi_rready)
    );

    integer errors = 0;
    integer log_fd;
    integer perf_log_fd;
    integer edge_log_fd;
    integer aw_count;
    integer ar_count;
    integer max_awlen;
    integer max_arlen;
    integer transparent_blocked_cycles;
    logic transparent_pattern_enable;
    logic [31:0] stream_out [0:31];
    integer stream_out_count;
    integer stream_out_last_count;
    integer cfg_start_pulse_count;

    // D01-D09 summary values.  Fmax is not mode-dependent; these arrays hold
    // behavioral latency/throughput and protocol characteristics only.
    longint unsigned matrix_command_cycles [1:9];
    real matrix_command_mbps [1:9];
    integer matrix_ar_transactions [1:9];
    integer matrix_aw_transactions [1:9];
    integer matrix_max_arlen [1:9];
    integer matrix_max_awlen [1:9];
    integer matrix_gap_cycles [1:9];
    integer matrix_transparent_wait_cycles [1:9];

    // Performance monitor.  It observes only existing valid/ready handshakes;
    // therefore it does not change the RTL or the measured implementation.
    longint unsigned perf_cycle_count;
    logic perf_window;
    logic perf_seen_start;
    logic perf_seen_done;
    longint unsigned perf_dma_start_cycle;
    longint unsigned perf_dma_done_cycle;
    integer perf_bus_r_bytes;
    integer perf_bus_w_bytes;
    integer perf_axis_in_bytes;
    integer perf_axis_out_bytes;
    integer perf_bus_ar_transactions;
    integer perf_bus_aw_transactions;
    longint unsigned perf_bus_r_first_cycle;
    longint unsigned perf_bus_r_last_cycle;
    longint unsigned perf_bus_w_first_cycle;
    longint unsigned perf_bus_w_last_cycle;
    // Full AXI transaction windows include address/control and response
    // overhead.  These are intentionally separate from the active data-beat
    // windows above, which only describe instantaneous bus bandwidth.
    longint unsigned perf_bus_r_txn_first_cycle;
    longint unsigned perf_bus_r_txn_last_cycle;
    longint unsigned perf_bus_w_txn_first_cycle;
    longint unsigned perf_bus_w_txn_last_cycle;
    longint unsigned perf_axis_in_first_cycle;
    longint unsigned perf_axis_in_last_cycle;
    longint unsigned perf_axis_out_first_cycle;
    longint unsigned perf_axis_out_last_cycle;
    integer perf_max_arlen;
    integer perf_max_awlen;
    integer perf_gap_cycles;
    integer perf_transparent_wait_cycles;
    integer perf_axi_ar_stall_cycles;
    integer perf_axi_aw_stall_cycles;
    integer perf_axi_w_stall_cycles;
    reg [15:0] force_iommu_vaddr;
    reg [19:0] force_iommu_length;
    reg force_iommu_write;

    function automatic integer keep_bytes(input logic [3:0] keep);
        begin
            keep_bytes = keep[0] + keep[1] + keep[2] + keep[3];
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            perf_cycle_count <= 0;
            perf_seen_start <= 1'b0;
            perf_seen_done <= 1'b0;
            perf_dma_start_cycle <= 0;
            perf_dma_done_cycle <= 0;
            cfg_start_pulse_count <= 0;
        end else begin
            perf_cycle_count <= perf_cycle_count + 1;
            if (dut.cfg_start)
                cfg_start_pulse_count <= cfg_start_pulse_count + 1;
            if (perf_window) begin
                if (dut.cfg_start) begin
                    perf_seen_start <= 1'b1;
                    perf_seen_done <= 1'b0;
                    perf_dma_start_cycle <= perf_cycle_count;
                end
                if ((dut.dma_done || dut.dma_fault) && perf_seen_start) begin
                    perf_seen_done <= 1'b1;
                    perf_dma_done_cycle <= perf_cycle_count;
                end

                if (m_axi_arvalid && m_axi_arready) begin
                    if (perf_bus_ar_transactions == 0)
                        perf_bus_r_txn_first_cycle <= perf_cycle_count;
                    perf_bus_ar_transactions <= perf_bus_ar_transactions + 1;
                    if (m_axi_arlen > perf_max_arlen)
                        perf_max_arlen <= m_axi_arlen;
                end
                if (m_axi_awvalid && m_axi_awready) begin
                    if (perf_bus_aw_transactions == 0)
                        perf_bus_w_txn_first_cycle <= perf_cycle_count;
                    perf_bus_aw_transactions <= perf_bus_aw_transactions + 1;
                    if (m_axi_awlen > perf_max_awlen)
                        perf_max_awlen <= m_axi_awlen;
                end

                // Scheduler state encoding is declared in dma_axi_scheduler:
                // ST_PREPARE=1 and ST_GAP=10.  These counters verify the mode
                // behavior without influencing any ready/valid signal.
                if (dut.scheduler_inst.state_q == 4'd10)
                    perf_gap_cycles <= perf_gap_cycles + 1;
                if (dut.dma_busy
                    && dut.scheduler_inst.dma_mode_q == 2'd2
                    && !cpu_bus_idle)
                    perf_transparent_wait_cycles
                        <= perf_transparent_wait_cycles + 1;

                if (m_axi_arvalid && !m_axi_arready)
                    perf_axi_ar_stall_cycles <= perf_axi_ar_stall_cycles + 1;
                if (m_axi_awvalid && !m_axi_awready)
                    perf_axi_aw_stall_cycles <= perf_axi_aw_stall_cycles + 1;
                if (m_axi_wvalid && !m_axi_wready)
                    perf_axi_w_stall_cycles <= perf_axi_w_stall_cycles + 1;

                if (m_axi_rvalid && m_axi_rready) begin
                    if (perf_bus_r_bytes == 0)
                        perf_bus_r_first_cycle <= perf_cycle_count;
                    perf_bus_r_last_cycle <= perf_cycle_count;
                    perf_bus_r_bytes <= perf_bus_r_bytes + BUS_BYTES;
                    if (m_axi_rlast)
                        perf_bus_r_txn_last_cycle <= perf_cycle_count;
                end
                if (m_axi_wvalid && m_axi_wready) begin
                    if (perf_bus_w_bytes == 0)
                        perf_bus_w_first_cycle <= perf_cycle_count;
                    perf_bus_w_last_cycle <= perf_cycle_count;
                    perf_bus_w_bytes <= perf_bus_w_bytes
                                      + keep_bytes(m_axi_wstrb);
                end
                if (m_axi_bvalid && m_axi_bready)
                    perf_bus_w_txn_last_cycle <= perf_cycle_count;
                if (s_axis_tvalid && s_axis_tready) begin
                    if (perf_axis_in_bytes == 0)
                        perf_axis_in_first_cycle <= perf_cycle_count;
                    perf_axis_in_last_cycle <= perf_cycle_count;
                    perf_axis_in_bytes <= perf_axis_in_bytes
                                        + keep_bytes(s_axis_tkeep);
                end
                if (m_axis_tvalid && m_axis_tready) begin
                    if (perf_axis_out_bytes == 0)
                        perf_axis_out_first_cycle <= perf_cycle_count;
                    perf_axis_out_last_cycle <= perf_cycle_count;
                    perf_axis_out_bytes <= perf_axis_out_bytes
                                         + keep_bytes(m_axis_tkeep);
                end
            end
        end
    end

    task automatic perf_begin;
        begin
            // Change the measurement window away from a sampling edge.
            @(negedge clk);
            perf_window = 1'b1;
            perf_seen_start = 1'b0;
            perf_seen_done = 1'b0;
            perf_dma_start_cycle = 0;
            perf_dma_done_cycle = 0;
            perf_bus_r_bytes = 0;
            perf_bus_w_bytes = 0;
            perf_axis_in_bytes = 0;
            perf_axis_out_bytes = 0;
            perf_bus_ar_transactions = 0;
            perf_bus_aw_transactions = 0;
            perf_bus_r_first_cycle = 0;
            perf_bus_r_last_cycle = 0;
            perf_bus_w_first_cycle = 0;
            perf_bus_w_last_cycle = 0;
            perf_bus_r_txn_first_cycle = 0;
            perf_bus_r_txn_last_cycle = 0;
            perf_bus_w_txn_first_cycle = 0;
            perf_bus_w_txn_last_cycle = 0;
            perf_axis_in_first_cycle = 0;
            perf_axis_in_last_cycle = 0;
            perf_axis_out_first_cycle = 0;
            perf_axis_out_last_cycle = 0;
            perf_max_arlen = 0;
            perf_max_awlen = 0;
            perf_gap_cycles = 0;
            perf_transparent_wait_cycles = 0;
            perf_axi_ar_stall_cycles = 0;
            perf_axi_aw_stall_cycles = 0;
            perf_axi_w_stall_cycles = 0;
        end
    endtask

    task automatic perf_end_and_log(
        input string test_name,
        input [1:0] transfer_type,
        input integer payload_bytes,
        input integer matrix_id
    );
        longint unsigned command_cycles;
        longint unsigned source_first;
        longint unsigned source_last;
        longint unsigned source_span;
        longint unsigned destination_first;
        longint unsigned destination_last;
        longint unsigned destination_span;
        longint unsigned data_first;
        longint unsigned data_last;
        longint unsigned data_span;
        longint unsigned bus_r_span;
        longint unsigned bus_w_span;
        longint unsigned bus_r_full_span;
        longint unsigned bus_w_full_span;
        integer source_bytes;
        integer destination_bytes;
        real command_mbps;
        real source_mbps;
        real destination_mbps;
        real end_to_end_mbps;
        real bus_r_mbps;
        real bus_w_mbps;
        real bus_r_effective_mbps;
        real bus_w_effective_mbps;
        real bus_r_efficiency;
        real bus_w_efficiency;
        real dma_standalone_mbps;
        real system_loss_percent;
        begin
            @(negedge clk);
            perf_window = 1'b0;

            command_cycles = perf_seen_start && perf_seen_done
                           ? perf_dma_done_cycle-perf_dma_start_cycle+1 : 0;
            bus_r_span = perf_bus_r_bytes != 0
                       ? perf_bus_r_last_cycle-perf_bus_r_first_cycle+1 : 0;
            bus_w_span = perf_bus_w_bytes != 0
                       ? perf_bus_w_last_cycle-perf_bus_w_first_cycle+1 : 0;
            bus_r_full_span = perf_bus_ar_transactions != 0
                           && perf_bus_r_bytes != 0
                           ? perf_bus_r_txn_last_cycle
                             -perf_bus_r_txn_first_cycle+1 : 0;
            bus_w_full_span = perf_bus_aw_transactions != 0
                           && perf_bus_w_bytes != 0
                           ? perf_bus_w_txn_last_cycle
                             -perf_bus_w_txn_first_cycle+1 : 0;

            case (transfer_type)
                2'd0: begin // memory -> memory
                    source_bytes = perf_bus_r_bytes;
                    source_first = perf_bus_r_first_cycle;
                    source_last = perf_bus_r_last_cycle;
                    destination_bytes = perf_bus_w_bytes;
                    destination_first = perf_bus_w_first_cycle;
                    destination_last = perf_bus_w_last_cycle;
                end
                2'd1: begin // peripheral -> memory
                    source_bytes = perf_axis_in_bytes;
                    source_first = perf_axis_in_first_cycle;
                    source_last = perf_axis_in_last_cycle;
                    destination_bytes = perf_bus_w_bytes;
                    destination_first = perf_bus_w_first_cycle;
                    destination_last = perf_bus_w_last_cycle;
                end
                default: begin // memory -> peripheral
                    source_bytes = perf_bus_r_bytes;
                    source_first = perf_bus_r_first_cycle;
                    source_last = perf_bus_r_last_cycle;
                    destination_bytes = perf_axis_out_bytes;
                    destination_first = perf_axis_out_first_cycle;
                    destination_last = perf_axis_out_last_cycle;
                end
            endcase

            source_span = source_bytes != 0
                        ? source_last-source_first+1 : 0;
            destination_span = destination_bytes != 0
                             ? destination_last-destination_first+1 : 0;
            if (source_bytes != 0 && destination_bytes != 0) begin
                data_first = source_first < destination_first
                           ? source_first : destination_first;
                data_last = source_last > destination_last
                          ? source_last : destination_last;
                data_span = data_last-data_first+1;
            end else begin
                data_span = 0;
            end

            command_mbps = command_cycles != 0
                         ? payload_bytes*SIM_CLOCK_MHZ/command_cycles : 0.0;
            source_mbps = source_span != 0
                        ? source_bytes*SIM_CLOCK_MHZ/source_span : 0.0;
            destination_mbps = destination_span != 0
                             ? destination_bytes*SIM_CLOCK_MHZ
                               /destination_span : 0.0;
            end_to_end_mbps = data_span != 0
                            ? payload_bytes*SIM_CLOCK_MHZ/data_span : 0.0;
            bus_r_mbps = bus_r_span != 0
                       ? perf_bus_r_bytes*SIM_CLOCK_MHZ/bus_r_span : 0.0;
            bus_w_mbps = bus_w_span != 0
                       ? perf_bus_w_bytes*SIM_CLOCK_MHZ/bus_w_span : 0.0;
            bus_r_effective_mbps = bus_r_full_span != 0
                                 ? perf_bus_r_bytes*SIM_CLOCK_MHZ
                                   /bus_r_full_span : 0.0;
            bus_w_effective_mbps = bus_w_full_span != 0
                                 ? perf_bus_w_bytes*SIM_CLOCK_MHZ
                                   /bus_w_full_span : 0.0;
            bus_r_efficiency = bus_r_span != 0
                             ? 100.0*perf_bus_r_bytes
                               /(bus_r_span*BUS_BYTES) : 0.0;
            bus_w_efficiency = bus_w_span != 0
                             ? 100.0*perf_bus_w_bytes
                               /(bus_w_span*BUS_BYTES) : 0.0;
            // Standalone reference assumes an ideal source and destination:
            // one DATA_WIDTH beat is accepted every clock, with no AXI
            // address/response, IOMMU, arbitration, or software overhead.
            dma_standalone_mbps = BUS_BYTES*SIM_CLOCK_MHZ;
            system_loss_percent = dma_standalone_mbps != 0.0
                                ? 100.0*(dma_standalone_mbps-command_mbps)
                                  /dma_standalone_mbps : 0.0;
            if (matrix_id >= 1 && matrix_id <= 9) begin
                matrix_command_cycles[matrix_id] = command_cycles;
                matrix_command_mbps[matrix_id] = command_mbps;
                matrix_ar_transactions[matrix_id]
                    = perf_bus_ar_transactions;
                matrix_aw_transactions[matrix_id]
                    = perf_bus_aw_transactions;
                matrix_max_arlen[matrix_id] = perf_max_arlen;
                matrix_max_awlen[matrix_id] = perf_max_awlen;
                matrix_gap_cycles[matrix_id] = perf_gap_cycles;
                matrix_transparent_wait_cycles[matrix_id]
                    = perf_transparent_wait_cycles;
            end

            if (perf_log_fd != 0) begin
                $fdisplay(perf_log_fd,
                    "------------------------------------------------------------");
                $fdisplay(perf_log_fd, "TEST: %s", test_name);
                $fdisplay(perf_log_fd,
                    "Payload=%0d bytes | clock=%.3f MHz", payload_bytes,
                    SIM_CLOCK_MHZ);
                $fdisplay(perf_log_fd, "[A] DMA STANDALONE REFERENCE (ideal interfaces, no bus/control wait)");
                case (transfer_type)
                    2'd0: $fdisplay(perf_log_fd,
                        "    DMA-only datapath: READ=%.3f MB/s, WRITE=%.3f MB/s (theoretical 1 word/clock)",
                        dma_standalone_mbps, dma_standalone_mbps);
                    2'd1: $fdisplay(perf_log_fd,
                        "    DMA-only datapath: STREAM-IN=%.3f MB/s, MEMORY-WRITE=%.3f MB/s (theoretical 1 word/clock)",
                        dma_standalone_mbps, dma_standalone_mbps);
                    default: $fdisplay(perf_log_fd,
                        "    DMA-only datapath: MEMORY-READ=%.3f MB/s, STREAM-OUT=%.3f MB/s (theoretical 1 word/clock)",
                        dma_standalone_mbps, dma_standalone_mbps);
                endcase
                $fdisplay(perf_log_fd, "[B] CURRENT DMA SUBSYSTEM MEASURED (cfg_start-to-done)");
                $fdisplay(perf_log_fd,
                    "    Complete command: %0d cycles, effective=%.3f MB/s, reduction_vs_DMA_only=%.2f%%",
                    command_cycles, command_mbps, system_loss_percent);
                $fdisplay(perf_log_fd,
                    "    Source endpoint active span: bytes=%0d cycles=%0d, instantaneous=%.3f MB/s",
                    source_bytes, source_span, source_mbps);
                $fdisplay(perf_log_fd,
                    "    Destination endpoint active span: bytes=%0d cycles=%0d, instantaneous=%.3f MB/s",
                    destination_bytes, destination_span, destination_mbps);
                $fdisplay(perf_log_fd,
                    "    Data-window only: %0d cycles, effective=%.3f MB/s",
                    data_span, end_to_end_mbps);
                $fdisplay(perf_log_fd, "[C] AXI BUS DETAILS");
                $fdisplay(perf_log_fd,
                    "    AXI READ full transaction (AR -> last R): bytes=%0d AR=%0d cycles=%0d, effective=%.3f MB/s",
                    perf_bus_r_bytes, perf_bus_ar_transactions,
                    bus_r_full_span, bus_r_effective_mbps);
                $fdisplay(perf_log_fd,
                    "    AXI READ active data beats only: cycles=%0d, instantaneous=%.3f MB/s, utilization=%.2f%%",
                    bus_r_span, bus_r_mbps, bus_r_efficiency);
                $fdisplay(perf_log_fd,
                    "    AXI WRITE full transaction (AW -> B): bytes=%0d AW=%0d cycles=%0d, effective=%.3f MB/s",
                    perf_bus_w_bytes, perf_bus_aw_transactions,
                    bus_w_full_span, bus_w_effective_mbps);
                $fdisplay(perf_log_fd,
                    "    AXI WRITE active data beats only: cycles=%0d, instantaneous=%.3f MB/s, utilization=%.2f%%",
                    bus_w_span, bus_w_mbps, bus_w_efficiency);
                $fdisplay(perf_log_fd,
                    "    AXI-Stream IN=%0d bytes | AXI-Stream OUT=%0d bytes",
                    perf_axis_in_bytes, perf_axis_out_bytes);
                $fdisplay(perf_log_fd,
                    "[D] MODE TIMING CHECK: scheduler_gap_cycles=%0d transparent_cpu_busy_wait_cycles=%0d",
                    perf_gap_cycles, perf_transparent_wait_cycles);
            end
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            aw_count <= 0;
            ar_count <= 0;
            max_awlen <= 0;
            max_arlen <= 0;
        end else begin
            if (m_axi_awvalid && m_axi_awready) begin
                aw_count <= aw_count + 1;
                if (m_axi_awlen > max_awlen)
                    max_awlen <= m_axi_awlen;
            end
            if (m_axi_arvalid && m_axi_arready) begin
                ar_count <= ar_count + 1;
                if (m_axi_arlen > max_arlen)
                    max_arlen <= m_axi_arlen;
            end
        end
    end

    integer transparent_divider;
    always @(posedge clk) begin
        if (!rst_n) begin
            cpu_bus_idle <= 1'b1;
            transparent_divider <= 0;
            transparent_blocked_cycles <= 0;
        end else if (!transparent_pattern_enable) begin
            cpu_bus_idle <= 1'b1;
            transparent_divider <= 0;
        end else begin
            transparent_divider <= transparent_divider + 1;
            cpu_bus_idle <= (transparent_divider[1:0] != 2'b00);
            if (!cpu_bus_idle && dut.dma_busy)
                transparent_blocked_cycles <= transparent_blocked_cycles + 1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            stream_out_count <= 0;
            stream_out_last_count <= 0;
        end else if (m_axis_tvalid && m_axis_tready) begin
            stream_out[stream_out_count] <= m_axis_tdata;
            stream_out_count <= stream_out_count + 1;
            if (m_axis_tlast)
                stream_out_last_count <= stream_out_last_count + 1;
        end
    end

    task automatic log_message(input string msg);
        begin
            $display("%s", msg);
            if (log_fd != 0)
                $fdisplay(log_fd, "[%0t] %s", $time, msg);
        end
    endtask

    task automatic fail(input string msg);
        begin
            errors = errors + 1;
            $display("ERROR: %s", msg);
            if (log_fd != 0)
                $fdisplay(log_fd, "[%0t] ERROR: %s", $time, msg);
        end
    endtask

    task automatic edge_result(
        input bit condition,
        input string test_id,
        input string detail
    );
        begin
            if (condition) begin
                $display("PASS %s: %s", test_id, detail);
                if (edge_log_fd != 0)
                    $fdisplay(edge_log_fd, "[%0t] PASS %-8s %s",
                              $time, test_id, detail);
            end else begin
                errors = errors + 1;
                $display("ERROR %s: %s", test_id, detail);
                if (log_fd != 0)
                    $fdisplay(log_fd, "[%0t] ERROR %s: %s",
                              $time, test_id, detail);
                if (edge_log_fd != 0)
                    $fdisplay(edge_log_fd, "[%0t] FAIL %-8s %s",
                              $time, test_id, detail);
            end
        end
    endtask

    task automatic axil_write(input [7:0] addr, input [31:0] data);
        bit aw_done;
        bit w_done;
        begin
            aw_done = 0;
            w_done = 0;
            @(posedge clk);
            axil_awaddr <= addr;
            axil_awvalid <= 1'b1;
            axil_wdata <= data;
            axil_wstrb <= 4'hf;
            axil_wvalid <= 1'b1;
            axil_bready <= 1'b1;
            while (!(aw_done && w_done)) begin
                @(posedge clk);
                if (!aw_done && axil_awvalid && axil_awready) begin
                    aw_done = 1;
                    axil_awvalid <= 1'b0;
                end
                if (!w_done && axil_wvalid && axil_wready) begin
                    w_done = 1;
                    axil_wvalid <= 1'b0;
                end
            end
            while (!axil_bvalid)
                @(posedge clk);
            if (axil_bresp != 2'b00)
                fail($sformatf("AXI-Lite write response %0d", axil_bresp));
            @(posedge clk);
            axil_bready <= 1'b0;
        end
    endtask

    task automatic axil_read(input [7:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            axil_araddr <= addr;
            axil_arvalid <= 1'b1;
            axil_rready <= 1'b1;
            while (!(axil_arvalid && axil_arready))
                @(posedge clk);
            @(posedge clk);
            axil_arvalid <= 1'b0;
            while (!axil_rvalid)
                @(posedge clk);
            data = axil_rdata;
            if (axil_rresp != 2'b00)
                fail($sformatf("AXI-Lite read response %0d", axil_rresp));
            @(posedge clk);
            axil_rready <= 1'b0;
        end
    endtask

    task automatic program_page(
        input [3:0] index,
        input [3:0] vpn,
        input [3:0] ppn,
        input bit read_perm,
        input bit write_perm
    );
        begin
            axil_write(8'h20, index);
            axil_write(8'h24, vpn);
            axil_write(8'h28, ppn);
            axil_write(8'h2c, {29'd0, write_perm, read_perm, 1'b1});
        end
    endtask

    task automatic run_dma(
        input [15:0] src,
        input [15:0] dst,
        input [19:0] length,
        input [1:0] transfer_type,
        input [1:0] dma_mode,
        input [7:0] burst_words,
        output [31:0] final_status
    );
        integer timeout;
        reg [31:0] status;
        begin
            axil_write(8'h00, 32'h0000_0002);
            axil_write(8'h08, src);
            axil_write(8'h0c, dst);
            axil_write(8'h10, length);
            axil_write(8'h14, {16'd0, burst_words, 4'd0,
                               dma_mode, transfer_type});
            axil_write(8'h00, 32'h0000_0001);
            status = 0;
            timeout = 0;
            while (!status[1] && !status[2] && timeout < 5000) begin
                axil_read(8'h04, status);
                timeout = timeout + 1;
            end
            if (timeout >= 5000)
                fail("DMA timeout");
            final_status = status;
        end
    endtask

    task automatic enqueue_descriptor(
        input [15:0] src,
        input [15:0] dst,
        input [15:0] length,
        input [1:0] transfer_type,
        input [1:0] dma_mode,
        input [7:0] burst_words,
        input bit irq_enable,
        input [7:0] desc_id,
        input [15:0] next_desc
    );
        begin
            axil_write(8'h40, src);
            axil_write(8'h44, dst);
            axil_write(8'h48, length);
            axil_write(8'h4c, {16'd0, burst_words, 4'd0,
                               dma_mode, transfer_type});
            axil_write(8'h50, {16'd0, desc_id, 7'd0, irq_enable});
            axil_write(8'h54, next_desc);
            axil_write(8'h58, 32'h0000_0001);
        end
    endtask

    task automatic pop_completion(
        output [31:0] completion_status,
        output [31:0] transferred_bytes
    );
        begin
            axil_read(8'h60, completion_status);
            axil_read(8'h64, transferred_bytes);
            if (!completion_status[0])
                fail("completion FIFO unexpectedly empty");
            else
                axil_write(8'h68, 32'h0000_0001);
        end
    endtask

    task automatic configure_dma(
        input [15:0] src,
        input [15:0] dst,
        input [19:0] length,
        input [1:0] transfer_type,
        input [1:0] dma_mode,
        input [7:0] burst_words
    );
        begin
            axil_write(8'h00, 32'h0000_0002);
            axil_write(8'h08, src);
            axil_write(8'h0c, dst);
            axil_write(8'h10, length);
            axil_write(8'h14, {16'd0, burst_words, 4'd0,
                               dma_mode, transfer_type});
        end
    endtask

    task automatic start_dma;
        begin
            axil_write(8'h00, 32'h0000_0001);
        end
    endtask

    task automatic wait_dma(output [31:0] final_status);
        integer timeout;
        reg [31:0] poll_status;
        begin
            poll_status = 0;
            timeout = 0;
            while (!poll_status[1] && !poll_status[2] && timeout < 5000) begin
                axil_read(8'h04, poll_status);
                timeout = timeout + 1;
            end
            if (timeout >= 5000)
                fail("DMA timeout");
            final_status = poll_status;
        end
    endtask

    task automatic send_peripheral_frame_pattern(
        input integer count,
        input [31:0] base_data
    );
        begin
            for (int n = 0; n < count; n++) begin
                @(posedge clk);
                s_axis_tdata <= base_data + n;
                s_axis_tkeep <= 4'hf;
                s_axis_tlast <= (n == count-1);
                s_axis_tvalid <= 1'b1;
                while (!(s_axis_tvalid && s_axis_tready))
                    @(posedge clk);
                s_axis_tvalid <= 1'b0;
            end
            @(posedge clk);
            s_axis_tlast <= 1'b0;
        end
    endtask

    task automatic send_peripheral_frame(input integer count);
        begin
            send_peripheral_frame_pattern(count, 32'hd100_0000);
        end
    endtask

    // Drive the IOMMU request port directly only while the DMA scheduler is
    // idle.  This isolates range, TLB, invalidate, and replacement behavior
    // without bypassing any logic inside dma_iommu_tlb.
    task automatic direct_iommu_lookup(
        input [15:0] vaddr,
        input [19:0] length,
        input bit write_access,
        output bit allow,
        output [15:0] paddr,
        output [2:0] fault_code
    );
        integer timeout;
        begin
            while (dut.dma_busy)
                @(negedge clk);
            @(negedge clk);
            force_iommu_vaddr = vaddr;
            force_iommu_length = length;
            force_iommu_write = write_access;
            force dut.iommu_req_vaddr = force_iommu_vaddr;
            force dut.iommu_req_len = force_iommu_length;
            force dut.iommu_req_write = force_iommu_write;
            force dut.iommu_req_valid = 1'b1;
            timeout = 0;
            while (!dut.iommu_req_ready && timeout < 50) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            @(posedge clk);
            @(negedge clk);
            force dut.iommu_req_valid = 1'b0;
            timeout = 0;
            while (!dut.iommu_resp_valid && timeout < 50) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            allow = dut.iommu_resp_allow;
            paddr = dut.iommu_resp_paddr;
            fault_code = dut.iommu_resp_fault;
            release dut.iommu_req_valid;
            release dut.iommu_req_vaddr;
            release dut.iommu_req_len;
            release dut.iommu_req_write;
            if (timeout >= 50)
                fail("Direct IOMMU lookup timeout");
        end
    endtask

    task automatic log_matrix_summary;
        begin
            if (perf_log_fd != 0) begin
                $fdisplay(perf_log_fd,
                    "============================================================");
                $fdisplay(perf_log_fd,
                    "D01-D09 TIMING AND THROUGHPUT SUMMARY");
                $fdisplay(perf_log_fd,
                    "ID  DIRECTION  MODE          CYCLES  MB/s     AR AW ARLEN AWLEN GAP CPU-WAIT");
                $fdisplay(perf_log_fd,
                    "D01 M2M        BURST         %6d %8.3f %2d %2d %5d %5d %3d %8d",
                    matrix_command_cycles[1], matrix_command_mbps[1],
                    matrix_ar_transactions[1], matrix_aw_transactions[1],
                    matrix_max_arlen[1], matrix_max_awlen[1],
                    matrix_gap_cycles[1], matrix_transparent_wait_cycles[1]);
                $fdisplay(perf_log_fd,
                    "D02 M2M        CYCLE-STEAL   %6d %8.3f %2d %2d %5d %5d %3d %8d",
                    matrix_command_cycles[2], matrix_command_mbps[2],
                    matrix_ar_transactions[2], matrix_aw_transactions[2],
                    matrix_max_arlen[2], matrix_max_awlen[2],
                    matrix_gap_cycles[2], matrix_transparent_wait_cycles[2]);
                $fdisplay(perf_log_fd,
                    "D03 M2M        TRANSPARENT   %6d %8.3f %2d %2d %5d %5d %3d %8d",
                    matrix_command_cycles[3], matrix_command_mbps[3],
                    matrix_ar_transactions[3], matrix_aw_transactions[3],
                    matrix_max_arlen[3], matrix_max_awlen[3],
                    matrix_gap_cycles[3], matrix_transparent_wait_cycles[3]);
                $fdisplay(perf_log_fd,
                    "D04 S2M        BURST         %6d %8.3f %2d %2d %5d %5d %3d %8d",
                    matrix_command_cycles[4], matrix_command_mbps[4],
                    matrix_ar_transactions[4], matrix_aw_transactions[4],
                    matrix_max_arlen[4], matrix_max_awlen[4],
                    matrix_gap_cycles[4], matrix_transparent_wait_cycles[4]);
                $fdisplay(perf_log_fd,
                    "D05 S2M        CYCLE-STEAL   %6d %8.3f %2d %2d %5d %5d %3d %8d",
                    matrix_command_cycles[5], matrix_command_mbps[5],
                    matrix_ar_transactions[5], matrix_aw_transactions[5],
                    matrix_max_arlen[5], matrix_max_awlen[5],
                    matrix_gap_cycles[5], matrix_transparent_wait_cycles[5]);
                $fdisplay(perf_log_fd,
                    "D06 S2M        TRANSPARENT   %6d %8.3f %2d %2d %5d %5d %3d %8d",
                    matrix_command_cycles[6], matrix_command_mbps[6],
                    matrix_ar_transactions[6], matrix_aw_transactions[6],
                    matrix_max_arlen[6], matrix_max_awlen[6],
                    matrix_gap_cycles[6], matrix_transparent_wait_cycles[6]);
                $fdisplay(perf_log_fd,
                    "D07 M2S        BURST         %6d %8.3f %2d %2d %5d %5d %3d %8d",
                    matrix_command_cycles[7], matrix_command_mbps[7],
                    matrix_ar_transactions[7], matrix_aw_transactions[7],
                    matrix_max_arlen[7], matrix_max_awlen[7],
                    matrix_gap_cycles[7], matrix_transparent_wait_cycles[7]);
                $fdisplay(perf_log_fd,
                    "D08 M2S        CYCLE-STEAL   %6d %8.3f %2d %2d %5d %5d %3d %8d",
                    matrix_command_cycles[8], matrix_command_mbps[8],
                    matrix_ar_transactions[8], matrix_aw_transactions[8],
                    matrix_max_arlen[8], matrix_max_awlen[8],
                    matrix_gap_cycles[8], matrix_transparent_wait_cycles[8]);
                $fdisplay(perf_log_fd,
                    "D09 M2S        TRANSPARENT   %6d %8.3f %2d %2d %5d %5d %3d %8d",
                    matrix_command_cycles[9], matrix_command_mbps[9],
                    matrix_ar_transactions[9], matrix_aw_transactions[9],
                    matrix_max_arlen[9], matrix_max_awlen[9],
                    matrix_gap_cycles[9], matrix_transparent_wait_cycles[9]);
                $fdisplay(perf_log_fd,
                    "NOTE: Burst must use multi-beat AXI; Cycle-Stealing must show GAP cycles; Transparent must show CPU-WAIT cycles.");
            end
        end
    endtask

    reg [31:0] status;
    reg [31:0] hit_count;
    reg [31:0] miss_count;
    reg [31:0] hit_before;
    reg [31:0] miss_before;
    bit iommu_allow;
    reg [15:0] iommu_paddr;
    reg [2:0] iommu_fault;
    reg backpressure_held_ok;
    reg [31:0] backpressure_data;
    integer aw_before;
    integer ar_before;
    integer start_before;
    integer queue_irq_rise_count;
    integer queue_irq_before;
    reg irq_previous;
    reg [7:0] queue_irq_active_id;
    reg [31:0] queue_status;
    reg [31:0] completion_status;
    reg [31:0] completion_transferred_bytes;
    reg [31:0] access_status;
    reg [31:0] access_src;
    reg [31:0] access_dst;
    reg [31:0] access_len;
    integer queue_timeout;

    // Record which queued descriptor actually caused the externally visible
    // interrupt.  This verifies that per-descriptor IRQ suppression works.
    always @(posedge clk) begin
        if (!rst_n) begin
            irq_previous <= 1'b0;
            queue_irq_rise_count <= 0;
            queue_irq_active_id <= 0;
        end else begin
            irq_previous <= irq;
            if (irq && !irq_previous) begin
                queue_irq_rise_count <= queue_irq_rise_count + 1;
                queue_irq_active_id <= dut.active_id_q;
            end
        end
    end

    initial begin : axi_test_sequence
        test_done_o = 1'b0;
        test_pass_o = 1'b0;
        log_fd = $fopen(LOG_PATH, "w");
        if (log_fd == 0) begin
            $display("Cannot open AXI test log");
            test_done_o = 1'b1;
            if (AUTO_FINISH)
                $finish;
            disable axi_test_sequence;
        end
        perf_log_fd = $fopen(PERF_LOG_PATH, "w");
        if (perf_log_fd == 0) begin
            $display("Cannot open DMA throughput log");
            $fclose(log_fd);
            log_fd = 0;
            test_done_o = 1'b1;
            if (AUTO_FINISH)
                $finish;
            disable axi_test_sequence;
        end
        edge_log_fd = $fopen(EDGE_LOG_PATH, "w");
        if (edge_log_fd == 0) begin
            $display("Cannot open DMA edge-case log");
            $fclose(perf_log_fd);
            $fclose(log_fd);
            perf_log_fd = 0;
            log_fd = 0;
            test_done_o = 1'b1;
            if (AUTO_FINISH)
                $finish;
            disable axi_test_sequence;
        end
        $fdisplay(edge_log_fd,
            "DMA/IOMMU/AXI EDGE, ERROR-INJECTION, AND ROBUSTNESS REPORT");
        $fdisplay(edge_log_fd,
            "Every PASS is generated from observed RTL state, AXI handshakes, status, or memory data.");
        $fdisplay(edge_log_fd,
            "Clock=%.3f MHz, DATA_WIDTH=%0d bits, PAGE_SIZE=4096 bytes",
            SIM_CLOCK_MHZ, AXI_DATA_WIDTH);
        $fdisplay(perf_log_fd, "DMA AND AXI BUS THROUGHPUT REPORT");
        $fdisplay(perf_log_fd,
            "Clock used by this behavioral benchmark: %.3f MHz",
            SIM_CLOCK_MHZ);
        $fdisplay(perf_log_fd,
            "[A] DMA standalone is the ideal raw datapath reference: one 32-bit word/clock, no bus/control wait.");
        $fdisplay(perf_log_fd,
            "[B] Current DMA subsystem is measured from cfg_start to done and includes all protocol/control latency.");
        $fdisplay(perf_log_fd,
            "CPU-side MMU is not in the DMA data path; its cost is reported separately in cpu_mmu_throughput.log.");
        $fdisplay(perf_log_fd,
            "[C] AXI full-transaction speed includes AR-to-last-R or AW-to-B; active-beat speed is diagnostic only.");
        $fdisplay(perf_log_fd,
            "MB/s uses decimal MB. Maximum of a 32-bit bus at %.3f MHz is %.3f MB/s per direction.",
            SIM_CLOCK_MHZ, BUS_BYTES*SIM_CLOCK_MHZ);
        $fdisplay(perf_log_fd, "FORMULAS (f_MHz is the clock frequency in MHz):");
        $fdisplay(perf_log_fd,
            "  Time(s) = cycles/(f_MHz*1,000,000)");
        $fdisplay(perf_log_fd,
            "  Throughput(MB/s) = bytes/time/1,000,000 = bytes*f_MHz/cycles");
        $fdisplay(perf_log_fd,
            "  Ideal one-beat throughput = (DATA_WIDTH/8)*f_MHz = %0d*%.3f = %.3f MB/s",
            BUS_BYTES, SIM_CLOCK_MHZ, BUS_BYTES*SIM_CLOCK_MHZ);
        $fdisplay(perf_log_fd,
            "  Bus utilization(%%) = 100*transferred_bytes/(active_cycles*bytes_per_beat)");
        $fdisplay(perf_log_fd,
            "  Burst: C_total=C_fixed+C_address_setup+C_AXI_protocol+C_data_beats.");
        $fdisplay(perf_log_fd,
            "  Cycle-Stealing: C_total=C_fixed+C_address_setup+C_active+C_release_gap+C_protocol.");
        $fdisplay(perf_log_fd,
            "  Transparent: C_total=C_fixed+C_address_setup+C_active+C_CPU_busy_wait+C_protocol.");
        $fdisplay(perf_log_fd,
            "  AXI read full cycles: AR handshake -> final R handshake; AXI write full cycles: AW handshake -> B handshake.");

        axil_awaddr = 0;
        axil_awprot = 0;
        axil_awvalid = 0;
        axil_wdata = 0;
        axil_wstrb = 0;
        axil_wvalid = 0;
        axil_bready = 0;
        axil_araddr = 0;
        axil_arprot = 0;
        axil_arvalid = 0;
        axil_rready = 0;
        s_axis_tdata = 0;
        s_axis_tkeep = 0;
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        m_axis_tready = 1;
        cpu_bus_idle = 1;
        transparent_pattern_enable = 0;
        perf_window = 1'b0;
        for (int n = 1; n <= 9; n++) begin
            matrix_command_cycles[n] = 0;
            matrix_command_mbps[n] = 0.0;
            matrix_ar_transactions[n] = 0;
            matrix_aw_transactions[n] = 0;
            matrix_max_arlen[n] = 0;
            matrix_max_awlen[n] = 0;
            matrix_gap_cycles[n] = 0;
            matrix_transparent_wait_cycles[n] = 0;
        end

        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (8) @(posedge clk);

        log_message("DMA/MMU AXI SELF-CHECKING TEST START");
        log_message("Programming 4 KiB software page table");
        program_page(0, 4'h1, 4'h0, 1, 1); // VA 1000 -> PA 0000
        program_page(1, 4'h2, 4'h1, 1, 1); // VA 2000 -> PA 1000
        program_page(2, 4'h3, 4'h2, 1, 1); // VA 3000 -> PA 2000
        program_page(3, 4'h4, 4'h3, 1, 0); // read-only page

        for (int n = 0; n < WORDS; n++) begin
            mem_inst.mem[n] = 32'ha500_0000 + n;
            mem_inst.mem['h400+n] = 0;
            mem_inst.mem['h800+n] = 0;
        end

        // -------------------------------------------------------------
        log_message("D01: memory -> memory, BURST mode");
        aw_before = aw_count;
        ar_before = ar_count;
        perf_begin();
        run_dma(16'h1000, 16'h2000, WORDS*4, 2'd0, 2'd0, 8'd8,
                status);
        perf_end_and_log("D01 M2M / BURST", 2'd0, WORDS*4, 1);
        if (status[2])
            fail($sformatf("M2M fault code=%02x", status[15:8]));
        for (int n = 0; n < WORDS; n++)
            if (mem_inst.mem['h400+n] !== 32'ha500_0000+n)
                fail($sformatf("M2M word %0d expected=%08x got=%08x",
                               n, 32'ha500_0000+n,
                               mem_inst.mem['h400+n]));
        log_message("M2M DATA: memory input -> memory output");
        for (int n = 0; n < WORDS; n++) begin
            if (mem_inst.mem[n] === mem_inst.mem['h400+n])
                log_message($sformatf(
                    "  WORD[%0d] IN  VA=0x%04x DATA=0x%08x | OUT VA=0x%04x DATA=0x%08x | MATCH",
                    n, 16'h1000+n*4, mem_inst.mem[n],
                    16'h2000+n*4, mem_inst.mem['h400+n]));
            else
                log_message($sformatf(
                    "  WORD[%0d] IN  VA=0x%04x DATA=0x%08x | OUT VA=0x%04x DATA=0x%08x | MISMATCH",
                    n, 16'h1000+n*4, mem_inst.mem[n],
                    16'h2000+n*4, mem_inst.mem['h400+n]));
        end
        log_message($sformatf("PASS M2M: AR transactions=%0d AW transactions=%0d max ARLEN=%0d max AWLEN=%0d",
                    ar_count-ar_before, aw_count-aw_before,
                    max_arlen, max_awlen));
        edge_result(matrix_ar_transactions[1] == 1
                    && matrix_aw_transactions[1] == 1
                    && matrix_max_arlen[1] == WORDS-1
                    && matrix_max_awlen[1] == WORDS-1,
                    "D01", "Burst is continuous: one AR/AW burst, LEN=7");

        // -------------------------------------------------------------
        log_message("D05: peripheral -> memory, CYCLE-STEALING mode");
        aw_before = aw_count;
        perf_begin();
        fork
            begin
                run_dma(16'h0000, 16'h3000, WORDS*4,
                        2'd1, 2'd1, 8'd1, status);
            end
            begin
                send_peripheral_frame(WORDS);
            end
        join
        perf_end_and_log("D05 S2M / CYCLE-STEALING", 2'd1,
                         WORDS*4, 5);
        if (status[2])
            fail($sformatf("S2M fault code=%02x", status[15:8]));
        for (int n = 0; n < WORDS; n++)
            if (mem_inst.mem['h800+n] !== 32'hd100_0000+n)
                fail($sformatf("S2M word %0d expected=%08x got=%08x",
                               n, 32'hd100_0000+n,
                               mem_inst.mem['h800+n]));
        if (aw_count-aw_before != WORDS)
            fail($sformatf("Cycle stealing expected %0d one-beat writes, got %0d",
                           WORDS, aw_count-aw_before));
        log_message("S2M DATA: AXI-Stream peripheral input -> memory output");
        for (int n = 0; n < WORDS; n++) begin
            if (mem_inst.mem['h800+n] === 32'hd100_0000+n)
                log_message($sformatf(
                    "  WORD[%0d] IN  S_AXIS DATA=0x%08x | OUT VA=0x%04x DATA=0x%08x | MATCH",
                    n, 32'hd100_0000+n, 16'h3000+n*4,
                    mem_inst.mem['h800+n]));
            else
                log_message($sformatf(
                    "  WORD[%0d] IN  S_AXIS DATA=0x%08x | OUT VA=0x%04x DATA=0x%08x | MISMATCH",
                    n, 32'hd100_0000+n, 16'h3000+n*4,
                    mem_inst.mem['h800+n]));
        end
        log_message($sformatf("PASS S2M: %0d independent one-beat writes with release gaps",
                              aw_count-aw_before));
        edge_result(matrix_aw_transactions[5] == WORDS
                    && matrix_max_awlen[5] == 0
                    && matrix_gap_cycles[5] >= WORDS-1,
                    "D05", "Cycle-Stealing issued one-beat writes and released the bus");

        // -------------------------------------------------------------
        log_message("D09: memory -> peripheral, TRANSPARENT mode");
        stream_out_count = 0;
        stream_out_last_count = 0;
        transparent_blocked_cycles = 0;
        ar_before = ar_count;
        transparent_pattern_enable = 1;
        perf_begin();
        run_dma(16'h1000, 16'h0000, WORDS*4,
                2'd2, 2'd2, 8'd1, status);
        transparent_pattern_enable = 0;
        repeat (5) @(posedge clk);
        perf_end_and_log("D09 M2S / TRANSPARENT", 2'd2,
                         WORDS*4, 9);
        if (status[2])
            fail($sformatf("M2S fault code=%02x", status[15:8]));
        if (stream_out_count != WORDS)
            fail($sformatf("M2S expected %0d stream beats, got %0d",
                           WORDS, stream_out_count));
        for (int n = 0; n < WORDS; n++)
            if (stream_out[n] !== 32'ha500_0000+n)
                fail($sformatf("M2S beat %0d expected=%08x got=%08x",
                               n, 32'ha500_0000+n, stream_out[n]));
        if (stream_out_last_count != 1)
            fail($sformatf("M2S expected one TLAST, got %0d",
                           stream_out_last_count));
        if (transparent_blocked_cycles == 0)
            fail("Transparent test did not create CPU-busy cycles");
        log_message("M2S DATA: memory input -> AXI-Stream peripheral output");
        for (int n = 0; n < WORDS; n++) begin
            if (mem_inst.mem[n] === stream_out[n])
                log_message($sformatf(
                    "  WORD[%0d] IN  VA=0x%04x DATA=0x%08x | OUT M_AXIS DATA=0x%08x TLAST=%0d | MATCH",
                    n, 16'h1000+n*4, mem_inst.mem[n], stream_out[n],
                    (n == WORDS-1)));
            else
                log_message($sformatf(
                    "  WORD[%0d] IN  VA=0x%04x DATA=0x%08x | OUT M_AXIS DATA=0x%08x TLAST=%0d | MISMATCH",
                    n, 16'h1000+n*4, mem_inst.mem[n], stream_out[n],
                    (n == WORDS-1)));
        end
        log_message($sformatf("PASS M2S: beats=%0d TLAST=%0d CPU-busy wait cycles=%0d AR transactions=%0d",
                              stream_out_count, stream_out_last_count,
                              transparent_blocked_cycles,
                              ar_count-ar_before));
        edge_result(matrix_ar_transactions[9] == WORDS
                    && matrix_max_arlen[9] == 0
                    && matrix_transparent_wait_cycles[9] > 0,
                    "D09", "Transparent transfer waited for CPU idle and used one-beat reads");

        // -------------------------------------------------------------
        log_message("D02: memory -> memory, CYCLE-STEALING mode");
        for (int n = 0; n < WORDS; n++) begin
            mem_inst.mem[n] = 32'ha200_0000+n;
            mem_inst.mem['h400+n] = 0;
        end
        perf_begin();
        run_dma(16'h1000, 16'h2000, WORDS*4, 2'd0, 2'd1, 8'd1,
                status);
        perf_end_and_log("D02 M2M / CYCLE-STEALING", 2'd0,
                         WORDS*4, 2);
        if (status[2])
            fail($sformatf("D02 fault code=%02x", status[15:8]));
        for (int n = 0; n < WORDS; n++)
            if (mem_inst.mem['h400+n] !== 32'ha200_0000+n)
                fail($sformatf("D02 word %0d mismatch", n));
        edge_result(matrix_ar_transactions[2] == WORDS
                    && matrix_aw_transactions[2] == WORDS
                    && matrix_max_arlen[2] == 0
                    && matrix_max_awlen[2] == 0
                    && matrix_gap_cycles[2] >= WORDS-1,
                    "D02", "M2M Cycle-Stealing used 8 one-beat read/write transactions plus gaps");

        // -------------------------------------------------------------
        log_message("D03: memory -> memory, TRANSPARENT mode");
        for (int n = 0; n < WORDS; n++) begin
            mem_inst.mem[n] = 32'ha300_0000+n;
            mem_inst.mem['h400+n] = 0;
        end
        transparent_pattern_enable = 1;
        perf_begin();
        run_dma(16'h1000, 16'h2000, WORDS*4, 2'd0, 2'd2, 8'd1,
                status);
        transparent_pattern_enable = 0;
        repeat (3) @(posedge clk);
        perf_end_and_log("D03 M2M / TRANSPARENT", 2'd0,
                         WORDS*4, 3);
        if (status[2])
            fail($sformatf("D03 fault code=%02x", status[15:8]));
        for (int n = 0; n < WORDS; n++)
            if (mem_inst.mem['h400+n] !== 32'ha300_0000+n)
                fail($sformatf("D03 word %0d mismatch", n));
        edge_result(matrix_ar_transactions[3] == WORDS
                    && matrix_aw_transactions[3] == WORDS
                    && matrix_max_arlen[3] == 0
                    && matrix_max_awlen[3] == 0
                    && matrix_transparent_wait_cycles[3] > 0,
                    "D03", "M2M Transparent progressed only during CPU-idle opportunities");

        // -------------------------------------------------------------
        log_message("D04: peripheral -> memory, BURST mode");
        for (int n = 0; n < WORDS; n++)
            mem_inst.mem['h800+n] = 0;
        perf_begin();
        fork
            begin
                run_dma(16'h0000, 16'h3000, WORDS*4,
                        2'd1, 2'd0, 8'd8, status);
            end
            begin
                send_peripheral_frame_pattern(WORDS, 32'hd400_0000);
            end
        join
        perf_end_and_log("D04 S2M / BURST", 2'd1, WORDS*4, 4);
        if (status[2])
            fail($sformatf("D04 fault code=%02x", status[15:8]));
        for (int n = 0; n < WORDS; n++)
            if (mem_inst.mem['h800+n] !== 32'hd400_0000+n)
                fail($sformatf("D04 word %0d mismatch", n));
        edge_result(matrix_aw_transactions[4] == 1
                    && matrix_max_awlen[4] == WORDS-1,
                    "D04", "S2M Burst accepted the stream and issued one 8-beat AXI write");

        // -------------------------------------------------------------
        log_message("D06: peripheral -> memory, TRANSPARENT mode");
        for (int n = 0; n < WORDS; n++)
            mem_inst.mem['h800+n] = 0;
        transparent_pattern_enable = 1;
        perf_begin();
        fork
            begin
                run_dma(16'h0000, 16'h3000, WORDS*4,
                        2'd1, 2'd2, 8'd1, status);
            end
            begin
                send_peripheral_frame_pattern(WORDS, 32'hd600_0000);
            end
        join
        transparent_pattern_enable = 0;
        repeat (3) @(posedge clk);
        perf_end_and_log("D06 S2M / TRANSPARENT", 2'd1,
                         WORDS*4, 6);
        if (status[2])
            fail($sformatf("D06 fault code=%02x", status[15:8]));
        for (int n = 0; n < WORDS; n++)
            if (mem_inst.mem['h800+n] !== 32'hd600_0000+n)
                fail($sformatf("D06 word %0d mismatch", n));
        edge_result(matrix_aw_transactions[6] == WORDS
                    && matrix_max_awlen[6] == 0
                    && matrix_transparent_wait_cycles[6] > 0,
                    "D06", "S2M Transparent waited for CPU idle and issued one-beat writes");

        // -------------------------------------------------------------
        log_message("D07: memory -> peripheral, BURST mode");
        for (int n = 0; n < WORDS; n++)
            mem_inst.mem[n] = 32'he700_0000+n;
        stream_out_count = 0;
        stream_out_last_count = 0;
        perf_begin();
        run_dma(16'h1000, 16'h0000, WORDS*4,
                2'd2, 2'd0, 8'd8, status);
        repeat (3) @(posedge clk);
        perf_end_and_log("D07 M2S / BURST", 2'd2, WORDS*4, 7);
        if (status[2])
            fail($sformatf("D07 fault code=%02x", status[15:8]));
        for (int n = 0; n < WORDS; n++)
            if (stream_out[n] !== 32'he700_0000+n)
                fail($sformatf("D07 stream beat %0d mismatch", n));
        edge_result(stream_out_count == WORDS
                    && stream_out_last_count == 1
                    && matrix_ar_transactions[7] == 1
                    && matrix_max_arlen[7] == WORDS-1,
                    "D07", "M2S Burst produced 8 stream beats/TLAST from one AXI read burst");

        // -------------------------------------------------------------
        log_message("D08: memory -> peripheral, CYCLE-STEALING mode");
        for (int n = 0; n < WORDS; n++)
            mem_inst.mem[n] = 32'he800_0000+n;
        stream_out_count = 0;
        stream_out_last_count = 0;
        perf_begin();
        run_dma(16'h1000, 16'h0000, WORDS*4,
                2'd2, 2'd1, 8'd1, status);
        repeat (3) @(posedge clk);
        perf_end_and_log("D08 M2S / CYCLE-STEALING", 2'd2,
                         WORDS*4, 8);
        if (status[2])
            fail($sformatf("D08 fault code=%02x", status[15:8]));
        for (int n = 0; n < WORDS; n++)
            if (stream_out[n] !== 32'he800_0000+n)
                fail($sformatf("D08 stream beat %0d mismatch", n));
        edge_result(stream_out_count == WORDS
                    && stream_out_last_count == 1
                    && matrix_ar_transactions[8] == WORDS
                    && matrix_max_arlen[8] == 0
                    && matrix_gap_cycles[8] >= WORDS-1,
                    "D08", "M2S Cycle-Stealing used one-beat reads and released the bus");

        log_matrix_summary();

        // -------------------------------------------------------------
        log_message("E01: IOMMU denies write to read-only page");
        run_dma(16'h0000, 16'h4000, 4,
                2'd1, 2'd0, 8'd1, status);
        if (!status[2])
            fail("IOMMU permission test did not fault");
        if (status[15:8] != 8'h32)
            fail($sformatf("Expected destination permission fault 0x32, got %02x",
                           status[15:8]));
        else begin
            log_message($sformatf(
                "IOMMU I/O: IN request=S2M WRITE dst_VA=0x4000 length=4 | OUT allow=0 fault=0x%02x",
                status[15:8]));
            log_message("PASS IOMMU: write permission fault code 0x32");
        end
        edge_result(status[2] && status[15:8] == 8'h32,
                    "E01", "write to read-only page rejected with destination permission fault 0x32");

        // -------------------------------------------------------------
        log_message("E02-E05: unmapped, read permission, and 4 KiB boundary checks");
        run_dma(16'hf000, 16'h0000, 4,
                2'd2, 2'd0, 8'd1, status);
        edge_result(status[2] && status[15:8] == 8'h21,
                    "E02", "unmapped source page rejected with source page fault 0x21");

        run_dma(16'h0000, 16'hf000, 4,
                2'd1, 2'd0, 8'd1, status);
        edge_result(status[2] && status[15:8] == 8'h31,
                    "E03", "unmapped destination page rejected with destination page fault 0x31");

        program_page(10, 4'hb, 4'ha, 0, 1); // write-only page
        run_dma(16'hb000, 16'h0000, 4,
                2'd2, 2'd0, 8'd1, status);
        edge_result(status[2] && status[15:8] == 8'h22,
                    "E04", "read from write-only page rejected with source permission fault 0x22");

        direct_iommu_lookup(16'h1ffc, 20'd8, 1'b0,
                            iommu_allow, iommu_paddr, iommu_fault);
        edge_result(!iommu_allow && iommu_fault == 3'd3,
                    "E05", "single IOMMU request crossing a 4 KiB page returned RANGE fault 3");

        // The scheduler must split a legal command at both page boundaries.
        mem_inst.mem['h3fe] = 32'hc500_0000;
        mem_inst.mem['h3ff] = 32'hc500_0001;
        mem_inst.mem['h400] = 32'hc500_0002;
        mem_inst.mem['h401] = 32'hc500_0003;
        mem_inst.mem['h7fe] = 0;
        mem_inst.mem['h7ff] = 0;
        mem_inst.mem['h800] = 0;
        mem_inst.mem['h801] = 0;
        ar_before = ar_count;
        aw_before = aw_count;
        run_dma(16'h1ff8, 16'h2ff8, 16,
                2'd0, 2'd0, 8'd8, status);
        edge_result(!status[2]
                    && mem_inst.mem['h7fe] == 32'hc500_0000
                    && mem_inst.mem['h7ff] == 32'hc500_0001
                    && mem_inst.mem['h800] == 32'hc500_0002
                    && mem_inst.mem['h801] == 32'hc500_0003
                    && ar_count-ar_before == 2
                    && aw_count-aw_before == 2,
                    "E06", "cross-page command was split into two authorized AXI chunks and data matched");

        // -------------------------------------------------------------
        log_message("E07: TLB miss/hit/invalidate/pseudo-LRU replacement");
        program_page(4, 4'h5, 4'h4, 1, 1);
        program_page(5, 4'h6, 4'h5, 1, 1);
        program_page(6, 4'h7, 4'h6, 1, 1);
        program_page(7, 4'h8, 4'h7, 1, 1);
        program_page(8, 4'h9, 4'h8, 1, 1);
        axil_read(8'h34, hit_before);
        axil_read(8'h38, miss_before);
        direct_iommu_lookup(16'h1000, 4, 0,
                            iommu_allow, iommu_paddr, iommu_fault);
        direct_iommu_lookup(16'h2000, 4, 0,
                            iommu_allow, iommu_paddr, iommu_fault);
        direct_iommu_lookup(16'h3000, 4, 0,
                            iommu_allow, iommu_paddr, iommu_fault);
        direct_iommu_lookup(16'h4000, 4, 0,
                            iommu_allow, iommu_paddr, iommu_fault);
        direct_iommu_lookup(16'h1004, 4, 0,
                            iommu_allow, iommu_paddr, iommu_fault);
        direct_iommu_lookup(16'h5000, 4, 0,
                            iommu_allow, iommu_paddr, iommu_fault);
        direct_iommu_lookup(16'h5004, 4, 0,
                            iommu_allow, iommu_paddr, iommu_fault);
        axil_write(8'h30, 32'h1);
        direct_iommu_lookup(16'h5008, 4, 0,
                            iommu_allow, iommu_paddr, iommu_fault);
        axil_read(8'h34, hit_count);
        axil_read(8'h38, miss_count);
        edge_result(hit_count-hit_before == 2
                    && miss_count-miss_before == 6
                    && iommu_allow && iommu_paddr == 16'h4008,
                    "E07", $sformatf("TLB observed hits=%0d misses=%0d; fifth page replaced one of four entries; invalidate forced a new miss",
                    hit_count-hit_before, miss_count-miss_before));

        // -------------------------------------------------------------
        log_message("E08-E10: AXI READY delay and stream backpressure");
        mem_inst.mem[0] = 32'he810_0001;
        stream_out_count = 0;
        perf_begin();
        force m_axi_arready = 1'b0;
        fork
            begin
                run_dma(16'h1000, 16'h0000, 4,
                        2'd2, 2'd0, 8'd1, status);
            end
            begin
                wait (m_axi_arvalid);
                repeat (9) @(posedge clk);
                release m_axi_arready;
            end
        join
        @(negedge clk);
        perf_window = 1'b0;
        edge_result(!status[2] && perf_axi_ar_stall_cycles >= 8
                    && stream_out[0] == 32'he810_0001,
                    "E08", $sformatf("ARREADY delayed; request held for %0d cycles and data remained correct",
                    perf_axi_ar_stall_cycles));

        mem_inst.mem['h400] = 0;
        perf_begin();
        force m_axi_awready = 1'b0;
        force m_axi_wready = 1'b0;
        fork
            begin
                run_dma(16'h0000, 16'h2000, 4,
                        2'd1, 2'd0, 8'd1, status);
            end
            begin
                send_peripheral_frame_pattern(1, 32'he820_0001);
            end
            begin
                wait (m_axi_awvalid || m_axi_wvalid);
                repeat (8) @(posedge clk);
                release m_axi_awready;
                release m_axi_wready;
            end
        join
        @(negedge clk);
        perf_window = 1'b0;
        edge_result(!status[2]
                    && (perf_axi_aw_stall_cycles >= 8
                        || perf_axi_w_stall_cycles >= 8)
                    && mem_inst.mem['h400] == 32'he820_0001,
                    "E09", $sformatf("AW/W READY delayed; AW stalls=%0d W stalls=%0d and memory data matched",
                    perf_axi_aw_stall_cycles, perf_axi_w_stall_cycles));

        mem_inst.mem[0] = 32'he830_0001;
        stream_out_count = 0;
        backpressure_held_ok = 1'b1;
        backpressure_data = 0;
        m_axis_tready = 0;
        fork
            begin
                run_dma(16'h1000, 16'h0000, 4,
                        2'd2, 2'd0, 8'd1, status);
            end
            begin
                wait (m_axis_tvalid);
                backpressure_data = m_axis_tdata;
                repeat (8) begin
                    @(negedge clk);
                    if (!m_axis_tvalid
                        || m_axis_tdata !== backpressure_data)
                        backpressure_held_ok = 1'b0;
                end
                m_axis_tready = 1;
            end
        join
        repeat (2) @(posedge clk);
        edge_result(!status[2] && backpressure_held_ok
                    && backpressure_data == 32'he830_0001
                    && stream_out_count == 1
                    && stream_out[0] == 32'he830_0001,
                    "E10", $sformatf("AXI-Stream backpressure held VALID/data for 8 cycles; count=%0d data=%08x",
                    stream_out_count, stream_out[0]));

        // -------------------------------------------------------------
        log_message("E11-E12: injected AXI SLVERR/DECERR propagation");
        force m_axi_rresp = 2'b10;
        run_dma(16'h1000, 16'h0000, 4,
                2'd2, 2'd0, 8'd1, status);
        release m_axi_rresp;
        edge_result(status[2] && status[15:8] == 8'h54,
                    "E11", "AXI read SLVERR propagated as DMA source fault 0x54");

        force m_axi_bresp = 2'b11;
        fork
            begin
                run_dma(16'h0000, 16'h2000, 4,
                        2'd1, 2'd0, 8'd1, status);
            end
            begin
                send_peripheral_frame_pattern(1, 32'he120_0001);
            end
        join
        release m_axi_bresp;
        edge_result(status[2] && status[15:8] == 8'h67,
                    "E12", "AXI write DECERR propagated as DMA destination fault 0x67");

        // -------------------------------------------------------------
        log_message("E13-E18: special lengths, alignment, and multiple bursts");
        run_dma(16'h1000, 16'h2000, 0,
                2'd0, 2'd0, 8'd8, status);
        edge_result(status[2] && status[15:8] == 8'h01,
                    "E13", "zero-byte command rejected as bad command");

        mem_inst.mem[0] = 32'he140_0001;
        mem_inst.mem['h400] = 0;
        run_dma(16'h1000, 16'h2000, 4,
                2'd0, 2'd0, 8'd1, status);
        edge_result(!status[2] && mem_inst.mem['h400] == 32'he140_0001,
                    "E14", "one-word command completed and copied exact data");

        run_dma(16'h1000, 16'h2000, 6,
                2'd0, 2'd0, 8'd8, status);
        edge_result(status[2] && status[15:8] == 8'h01,
                    "E15", "non-word-multiple length rejected as bad command");

        run_dma(16'h1002, 16'h0000, 4,
                2'd2, 2'd0, 8'd1, status);
        edge_result(status[2] && status[15:8] == 8'h01,
                    "E16", "unaligned memory source rejected as bad command");

        run_dma(16'h0000, 16'h2002, 4,
                2'd1, 2'd0, 8'd1, status);
        edge_result(status[2] && status[15:8] == 8'h01,
                    "E17", "unaligned memory destination rejected as bad command");

        for (int n = 0; n < 20; n++) begin
            mem_inst.mem[n] = 32'he180_0000+n;
            mem_inst.mem['h400+n] = 0;
        end
        ar_before = ar_count;
        aw_before = aw_count;
        run_dma(16'h1000, 16'h2000, 80,
                2'd0, 2'd0, 8'd8, status);
        for (int n = 0; n < 20; n++)
            if (mem_inst.mem['h400+n] !== 32'he180_0000+n)
                fail($sformatf("E18 multi-burst word %0d mismatch", n));
        edge_result(!status[2] && ar_count-ar_before == 3
                    && aw_count-aw_before == 3,
                    "E18", "80-byte transfer split into 8+8+4 beat bursts and all 20 words matched");

        // -------------------------------------------------------------
        log_message("E19: a new start command is ignored while DMA is busy");
        mem_inst.mem['h400] = 0;
        configure_dma(16'h0000, 16'h2000, 4,
                      2'd1, 2'd0, 8'd1);
        start_dma();
        wait (dut.dma_busy);
        @(negedge clk);
        start_before = cfg_start_pulse_count;
        axil_write(8'h00, 32'h0000_0001);
        repeat (3) @(posedge clk);
        edge_result(cfg_start_pulse_count == start_before,
                    "E19", "register block suppressed cfg_start while dma_busy=1");
        send_peripheral_frame_pattern(1, 32'he190_0001);
        wait_dma(status);
        edge_result(!status[2] && mem_inst.mem['h400] == 32'he190_0001,
                    "E19-DATA", "original in-flight command completed without corruption");

        // -------------------------------------------------------------
        log_message("Q01: eight-entry descriptor FIFO and queued scatter-gather");
        // Clear old sticky state, enable global IRQ, and pause dispatch so
        // software can fill all eight physical FIFO entries before execution.
        axil_write(8'h00, 32'h0000_0006);
        axil_write(8'h58, 32'h0000_0008);
        queue_irq_before = queue_irq_rise_count;

        for (int q = 0; q < 8; q++) begin
            // VA page 1 maps to physical page 0; VA page 2 maps to physical
            // page 1.  Spacing each word by 0x20 makes the buffers genuinely
            // non-contiguous and therefore exercises queued scatter-gather.
            mem_inst.mem['h040 + q*8] = 32'hd500_0000 + q;
            mem_inst.mem['h480 + q*8] = 32'd0;
            enqueue_descriptor(16'h1100 + q*16'h0020,
                               16'h2200 + q*16'h0020,
                               16'd4, 2'd0, q % 3, 8'd4,
                               (q == 7), 8'h10 + q,
                               (q == 7) ? 16'd0
                                        : 16'h8000 + (q+1)*16'h0020);
        end

        axil_read(8'h5c, queue_status);
        edge_result(queue_status[3:0] == 8 && queue_status[9]
                    && queue_status[14],
                    "Q01-FULL", "all eight descriptor slots were occupied while dispatch was paused");

        // A ninth descriptor must not overwrite any of the eight queued
        // commands.  Rejection is reported by the sticky overflow flag.
        enqueue_descriptor(16'h1100, 16'h2200, 16'd4,
                           2'd0, 2'd0, 8'd1, 1'b0, 8'h7f, 16'd0);
        axil_read(8'h5c, queue_status);
        edge_result(queue_status[3:0] == 8 && queue_status[12],
                    "Q01-OVF", "ninth push was rejected without corrupting FIFO contents");

        axil_write(8'h58, 32'h0000_0004); // RESUME
        queue_status = 0;
        queue_timeout = 0;
        while (queue_status[19:16] != 8 && queue_timeout < 10000) begin
            axil_read(8'h5c, queue_status);
            queue_timeout = queue_timeout + 1;
        end
        if (queue_timeout >= 10000)
            fail("Q01 descriptor queue timeout");
        edge_result(queue_status[3:0] == 0 && !queue_status[10]
                    && queue_status[19:16] == 8,
                    "Q01-RUN", "eight queued descriptors executed in sequence and generated eight completions");

        for (int q = 0; q < 8; q++) begin
            edge_result(mem_inst.mem['h480 + q*8]
                        == 32'hd500_0000 + q,
                        $sformatf("Q01-DATA%0d", q),
                        $sformatf("non-contiguous word copied to destination: %08x",
                                  mem_inst.mem['h480 + q*8]));
            pop_completion(completion_status,
                           completion_transferred_bytes);
            edge_result(completion_status[31:24] == 8'h10 + q
                        && completion_status[2:0] == 3'b011
                        && completion_transferred_bytes == 4,
                        $sformatf("Q01-COMP%0d", q),
                        $sformatf("completion ID=0x%02x DONE=1 bytes=%0d",
                                  completion_status[31:24],
                                  completion_transferred_bytes));
        end
        axil_read(8'h5c, queue_status);
        edge_result(!queue_status[13] && queue_status[19:16] == 0,
                    "Q01-POP", "CPU consumed all completion records");
        edge_result(irq && queue_irq_rise_count == queue_irq_before + 1
                    && queue_irq_active_id == 8'h17,
                    "Q01-IRQ", "only the final descriptor's IRQ flag raised the interrupt");
        axil_read(8'h6c, status);
        edge_result(status == 8,
                    "Q01-TOTAL", "hardware completion counter recorded eight queued commands");

        // -------------------------------------------------------------
        log_message("Q02: stop-on-error preserves descriptors after a fault");
        axil_write(8'h00, 32'h0000_0006);
        axil_write(8'h58, 32'h0000_0008); // PAUSE
        mem_inst.mem['h040] = 32'hd520_0000;
        mem_inst.mem['h041] = 32'hd520_0001;
        mem_inst.mem['h042] = 32'hd520_0002;
        mem_inst.mem['h4c0] = 32'd0;
        mem_inst.mem['h4c2] = 32'd0;
        enqueue_descriptor(16'h1100, 16'h2300, 16'd4,
                           2'd0, 2'd0, 8'd1, 1'b0, 8'h20, 16'd0);
        enqueue_descriptor(16'h1104, 16'h4000, 16'd4,
                           2'd0, 2'd0, 8'd1, 1'b1, 8'h21, 16'd0);
        enqueue_descriptor(16'h1108, 16'h2308, 16'd4,
                           2'd0, 2'd0, 8'd1, 1'b0, 8'h22, 16'd0);
        axil_write(8'h58, 32'h0000_0004); // RESUME

        queue_status = 0;
        queue_timeout = 0;
        while (!queue_status[11] && queue_timeout < 5000) begin
            axil_read(8'h5c, queue_status);
            queue_timeout = queue_timeout + 1;
        end
        if (queue_timeout >= 5000)
            fail("Q02 queue did not halt after IOMMU fault");
        edge_result(queue_status[11] && queue_status[3:0] == 1
                    && queue_status[19:16] == 2,
                    "Q02-HALT", "permission fault halted the queue and retained the following descriptor");
        edge_result(mem_inst.mem['h4c0] == 32'hd520_0000
                    && mem_inst.mem['h4c2] == 32'd0,
                    "Q02-DATA", "descriptor before fault completed; descriptor after fault did not execute");

        pop_completion(completion_status, completion_transferred_bytes);
        edge_result(completion_status[31:24] == 8'h20
                    && completion_status[2:0] == 3'b011
                    && completion_transferred_bytes == 4,
                    "Q02-COMP0", "first descriptor reported successful completion");
        pop_completion(completion_status, completion_transferred_bytes);
        edge_result(completion_status[31:24] == 8'h21
                    && completion_status[2:0] == 3'b101
                    && completion_status[15:8] == 8'h32
                    && completion_transferred_bytes == 0,
                    "Q02-COMP1", "faulting descriptor reported IOMMU write-permission fault 0x32");

        axil_write(8'h58, 32'h0000_0002); // FLUSH pending descriptors
        repeat (3) @(posedge clk);
        axil_read(8'h5c, queue_status);
        edge_result(queue_status[8] && !queue_status[11]
                    && queue_status[3:0] == 0,
                    "Q02-FLUSH", "software flushed the retained descriptor and cleared halt state");
        axil_read(8'h6c, status);
        edge_result(status == 10,
                    "Q02-TOTAL", "completion counter includes eight successes, one later success, and one fault");

        // -------------------------------------------------------------
        log_message("A01-A04: hybrid CPU-authorized and peripheral-autonomous DMA access");
        axil_write(8'h00, 32'h0000_0006); // clear status, enable IRQ
        axil_write(8'h70, 32'h0000_0001); // grant/deny applies to peripheral requests

        // A01: a legacy START is itself the CPU authorization.  It must not
        // create a second request IRQ or wait for a redundant grant.
        mem_inst.mem['h000] = 32'ha010_0001;
        mem_inst.mem['h400] = 32'd0;
        configure_dma(16'h1000, 16'h2000, 4,
                      2'd0, 2'd0, 8'd1);
        ar_before = ar_count;
        aw_before = aw_count;
        axil_write(8'h00, 32'h0000_0005); // START + IRQ enable
        wait_dma(status);
        axil_read(8'h74, access_status);
        edge_result(!status[2] && mem_inst.mem['h400] == 32'ha010_0001
                    && ar_count > ar_before && aw_count > aw_before
                    && !access_status[0] && !access_status[16],
                    "A01-CPU", "CPU START executed immediately without a redundant request/grant handshake");

        // A02: descriptor PUSH is also explicit CPU authorization.  Queue
        // execution remains automatic even when peripheral grant mode is on.
        axil_write(8'h00, 32'h0000_0006);
        mem_inst.mem['h001] = 32'ha020_0002;
        mem_inst.mem['h401] = 32'd0;
        enqueue_descriptor(16'h1004, 16'h2004, 16'd4,
                           2'd0, 2'd0, 8'd1, 1'b1, 8'ha2, 16'd0);
        queue_status = 0;
        queue_timeout = 0;
        while (!queue_status[13] && queue_timeout < 5000) begin
            axil_read(8'h5c, queue_status);
            queue_timeout = queue_timeout + 1;
        end
        pop_completion(completion_status, completion_transferred_bytes);
        axil_read(8'h74, access_status);
        edge_result(completion_status[31:24] == 8'ha2
                    && completion_status[2:0] == 3'b011
                    && completion_transferred_bytes == 4
                    && mem_inst.mem['h401] == 32'ha020_0002
                    && !access_status[0] && !access_status[16],
                    "A02-QUEUE", "CPU-pushed descriptor executed immediately and preserved completion ID/data");

        // A03: UART RX can autonomously request an S2M transfer.  This is
        // the only path that raises a request IRQ and waits for CPU grant.
        axil_write(8'h00, 32'h0000_0006);
        mem_inst.mem['h403] = 32'd0;
        configure_dma(16'h0000, 16'h200c, 4,
                      2'd1, 2'd0, 8'd1);
        axil_write(8'h70, 32'h0000_0003); // grant mode + UART auto request
        ar_before = ar_count;
        aw_before = aw_count;
        @(posedge clk);
        s_axis_tdata <= 32'ha030_0003;
        s_axis_tkeep <= 4'hf;
        s_axis_tlast <= 1'b1;
        s_axis_tvalid <= 1'b1;
        wait (dut.access_request_pending);
        axil_read(8'h74, access_status);
        repeat (6) @(posedge clk);
        log_message($sformatf(
            "A03 request snapshot: status=0x%08x irq=%0d AR=%0d/%0d AW=%0d/%0d RAM=0x%08x",
            access_status, irq, ar_count, ar_before, aw_count, aw_before,
            mem_inst.mem['h403]));
        edge_result(access_status[0] && access_status[16]
                    && access_status[5:4] == 2'd1 && irq
                    && ar_count == ar_before && aw_count == aw_before
                    && mem_inst.mem['h403] == 0,
                    "A03-REQ", "autonomous UART request raised IRQ and remained outside IOMMU/AXI before grant");
        axil_write(8'h78, 32'h0000_0001); // GRANT
        wait (s_axis_tready);
        @(posedge clk);
        s_axis_tvalid <= 1'b0;
        s_axis_tlast <= 1'b0;
        wait_dma(status);
        axil_read(8'h74, access_status);
        edge_result(!status[2] && mem_inst.mem['h403] == 32'ha030_0003
                    && aw_count > aw_before && !access_status[1:0],
                    "A03-GRANT", "CPU grant released the autonomous UART word through IOMMU into RAM");

        // A04: denial must terminate the autonomous request with fault 0x70
        // and must not leak an AXI write or modify memory.
        axil_write(8'h00, 32'h0000_0006);
        mem_inst.mem['h404] = 32'd0;
        configure_dma(16'h0000, 16'h2010, 4,
                      2'd1, 2'd0, 8'd1);
        aw_before = aw_count;
        @(posedge clk);
        s_axis_tdata <= 32'ha040_0004;
        s_axis_tkeep <= 4'hf;
        s_axis_tlast <= 1'b1;
        s_axis_tvalid <= 1'b1;
        wait (dut.access_request_pending);
        axil_write(8'h78, 32'h0000_0002); // DENY
        @(posedge clk);
        s_axis_tvalid <= 1'b0;
        s_axis_tlast <= 1'b0;
        wait_dma(status);
        axil_read(8'h74, access_status);
        edge_result(status[2] && status[15:8] == 8'h70
                    && access_status[2] && access_status[16]
                    && aw_count == aw_before && mem_inst.mem['h404] == 0,
                    "A04-DENY", "CPU denial returned fault 0x70 with no AXI write or RAM change");
        axil_write(8'h78, 32'h0000_0004); // clear denied sticky

        // Restore default behavior before the legacy reset test.
        axil_write(8'h70, 32'h0000_0000);
        axil_write(8'h00, 32'h0000_0002);

        // -------------------------------------------------------------
        log_message("E20: reset while DMA is actively waiting for peripheral data");
        configure_dma(16'h0000, 16'h2000, 4,
                      2'd1, 2'd0, 8'd1);
        start_dma();
        wait (dut.dma_busy);
        repeat (2) @(posedge clk);
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);
        axil_read(8'h04, status);
        edge_result(!dut.dma_busy && status[2:0] == 3'b000
                    && !m_axi_arvalid && !m_axi_awvalid
                    && !m_axi_wvalid,
                    "E20", "mid-transfer reset returned scheduler/registers/AXI outputs to idle with no stale DONE/FAULT");

        axil_read(8'h34, hit_count);
        axil_read(8'h38, miss_count);
        edge_result(hit_count == 0 && miss_count == 0,
                    "E20-TLB", "reset also cleared TLB hit/miss counters");

        if (errors == 0)
            log_message("ALL DMA/MMU AXI TESTS PASSED");
        else
            log_message($sformatf("DMA/MMU AXI TESTS FAILED: %0d errors", errors));

        test_pass_o = (errors == 0);
        test_done_o = 1'b1;
        if (perf_log_fd != 0) begin
            $fdisplay(perf_log_fd,
                "------------------------------------------------------------");
            $fdisplay(perf_log_fd, "END OF THROUGHPUT REPORT");
            $fclose(perf_log_fd);
            perf_log_fd = 0;
        end
        if (edge_log_fd != 0) begin
            $fdisplay(edge_log_fd,
                "------------------------------------------------------------");
            if (errors == 0)
                $fdisplay(edge_log_fd,
                    "ALL DMA/IOMMU/AXI EDGE AND ROBUSTNESS TESTS PASSED");
            else
                $fdisplay(edge_log_fd,
                    "EDGE/ROBUSTNESS TESTS FAILED: %0d total errors", errors);
            $fclose(edge_log_fd);
            edge_log_fd = 0;
        end
        $fclose(log_fd);
        log_fd = 0;
        if (AUTO_FINISH) begin
            repeat (10) @(posedge clk);
            $finish;
        end
    end

    initial begin
        #2ms;
        if (!test_done_o) begin
            $display("GLOBAL TIMEOUT: DMA/IOMMU AXI test");
            if (log_fd != 0) begin
                $fdisplay(log_fd, "[%0t] GLOBAL TIMEOUT", $time);
                $fclose(log_fd);
                log_fd = 0;
            end
            if (perf_log_fd != 0) begin
                $fdisplay(perf_log_fd, "GLOBAL TIMEOUT");
                $fclose(perf_log_fd);
                perf_log_fd = 0;
            end
            if (edge_log_fd != 0) begin
                $fdisplay(edge_log_fd, "GLOBAL TIMEOUT");
                $fclose(edge_log_fd);
                edge_log_fd = 0;
            end
            test_pass_o = 1'b0;
            test_done_o = 1'b1;
            if (AUTO_FINISH)
                $finish;
        end
    end

    wire _unused = &{1'b0, irq, m_axi_awqos, m_axi_awregion,
                     m_axi_arqos, m_axi_arregion};

endmodule
