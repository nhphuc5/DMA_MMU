`timescale 1ns / 1ps

// Complete demonstration SoC:
//   PicoRV32 CPU + DMA/IOMMU IP + shared AXI RAM + UART
//
// The CPU is an AXI4-Lite master.  Its accesses are decoded to system RAM,
// DMA/IOMMU control registers, or UART registers.  CPU RAM traffic and the
// DMA AXI4-Full master share one memory port through an AXI crossbar with
// independent read/write arbitration. UART is the only external peripheral
// and is also the DMA's
// AXI4-Stream source/sink.
module dma_mmu_picorv32_soc #(
    parameter int AXI_ADDR_WIDTH = 16,
    parameter int BRAM_ADDR_WIDTH = AXI_ADDR_WIDTH,
    parameter int AXI_DATA_WIDTH = 32,
    parameter int DMA_AXI_ID_WIDTH = 4,
    parameter int UART_DEFAULT_DIV = 434,
    parameter MEM_INIT_FILE = "",
    parameter bit ENABLE_DDR3 = 1'b0,
    parameter logic [31:0] DDR_BASE_ADDR = 32'h8000_0000,
    parameter logic [31:0] DDR_SIZE_BYTES = 32'h4000_0000
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic uart_rx_i,
    output logic uart_tx_o,

    output logic cpu_trap_o,
    output logic dma_irq_o,
    output logic uart_irq_o,
    output logic [7:0] uart_tx_byte_o,
    output logic uart_tx_byte_valid_o,

    output logic ddr_init_done_o,
    output logic ddr_calib_done_o,
    output logic ddr_calib_error_o,
    output logic ddr_refresh_busy_o,
    output logic [31:0] ddr_refresh_count_o,
    output logic ddr_dfi_cmd_valid_o,
    input  logic ddr_dfi_cmd_ready_i,
    output logic [2:0] ddr_dfi_cmd_o,
    output logic [2:0] ddr_dfi_bank_o,
    output logic [15:0] ddr_dfi_addr_o,
    output logic [31:0] ddr_dfi_wrdata_o,
    output logic [3:0] ddr_dfi_wrmask_o,
    input  logic ddr_dfi_rddata_valid_i,
    input  logic [31:0] ddr_dfi_rddata_i,
    input  logic ddr_dfi_error_i,
    output logic ddr_phy_calib_start_o,
    input  logic ddr_phy_calib_done_i,
    input  logic ddr_phy_calib_error_i
);

    localparam int SYS_ID_WIDTH = DMA_AXI_ID_WIDTH + 1;
    // The system crossbar adds one source-routing bit for CPU vs. DMA.
    localparam int MEM_ID_WIDTH = SYS_ID_WIDTH + 1;
    wire rst = !rst_ni;

    initial begin
        if (ENABLE_DDR3 && AXI_ADDR_WIDTH != 32)
            $error("ENABLE_DDR3 requires AXI_ADDR_WIDTH=32");
        if (BRAM_ADDR_WIDTH > AXI_ADDR_WIDTH)
            $error("BRAM_ADDR_WIDTH cannot exceed AXI_ADDR_WIDTH");
    end

    // ------------------------------------------------------------------
    // PicoRV32 AXI4-Lite master
    // ------------------------------------------------------------------
    wire cpu_awvalid, cpu_awready;
    wire [31:0] cpu_awaddr;
    wire [2:0] cpu_awprot;
    wire cpu_wvalid, cpu_wready;
    wire [31:0] cpu_wdata;
    wire [3:0] cpu_wstrb;
    wire cpu_bvalid, cpu_bready;
    wire cpu_arvalid, cpu_arready;
    wire [31:0] cpu_araddr;
    wire [2:0] cpu_arprot;
    wire cpu_rvalid, cpu_rready;
    wire [31:0] cpu_rdata;
    wire [31:0] cpu_irq;
    wire [31:0] cpu_eoi;
    wire cpu_mmu_fault_irq;
    wire cpu_mmu_enabled;
    wire cpu_mmu_idle;
    wire [31:0] cpu_mmu_tlb_hits;
    wire [31:0] cpu_mmu_tlb_misses;

    wire systolic_irq;
    // IRQ bit 6 is reserved for CPU-side MMU faults.  Existing DMA/UART IRQ
    // positions stay unchanged so old firmware remains compatible.
    assign cpu_irq = {25'd0, cpu_mmu_fault_irq, dma_irq_o, uart_irq_o, systolic_irq, 3'd0};

    picorv32_axi #(
        .ENABLE_COUNTERS(1),
        .ENABLE_COUNTERS64(0),
        .ENABLE_REGS_16_31(1),
        .ENABLE_REGS_DUALPORT(1),
        .BARREL_SHIFTER(1),
        // Extra execution cycles preserve the RV32 ISA while shortening the
        // ALU/branch paths for a higher system clock.
        .TWO_CYCLE_COMPARE(1),
        .TWO_CYCLE_ALU(1),
        .COMPRESSED_ISA(0),
        .ENABLE_MUL(1),
        .ENABLE_IRQ(1),
        .ENABLE_IRQ_TIMER(0),
        .REGS_INIT_ZERO(1),
        .PROGADDR_RESET(32'h0000_0000),
        .PROGADDR_IRQ(32'h0000_0010),
        .STACKADDR(32'h0000_FFFC)
    ) cpu_inst (
        .clk(clk_i),
        .resetn(rst_ni),
        .trap(cpu_trap_o),
        .mem_axi_awvalid(cpu_awvalid),
        .mem_axi_awready(cpu_awready),
        .mem_axi_awaddr(cpu_awaddr),
        .mem_axi_awprot(cpu_awprot),
        .mem_axi_wvalid(cpu_wvalid),
        .mem_axi_wready(cpu_wready),
        .mem_axi_wdata(cpu_wdata),
        .mem_axi_wstrb(cpu_wstrb),
        .mem_axi_bvalid(cpu_bvalid),
        .mem_axi_bready(cpu_bready),
        .mem_axi_arvalid(cpu_arvalid),
        .mem_axi_arready(cpu_arready),
        .mem_axi_araddr(cpu_araddr),
        .mem_axi_arprot(cpu_arprot),
        .mem_axi_rvalid(cpu_rvalid),
        .mem_axi_rready(cpu_rready),
        .mem_axi_rdata(cpu_rdata),
        .pcpi_valid(), .pcpi_insn(), .pcpi_rs1(), .pcpi_rs2(),
        .pcpi_wr(1'b0), .pcpi_rd(32'd0),
        .pcpi_wait(1'b0), .pcpi_ready(1'b0),
        .irq(cpu_irq),
        .eoi(cpu_eoi),
        .trace_valid(), .trace_data()
    );

    // ------------------------------------------------------------------
    // CPU-side MMU.  CPU RAM accesses are virtual and translated here;
    // physical MMIO windows (DMA/UART) bypass translation.  This is separate
    // from the DMA-side IOMMU inside dma_mmu_axi_top.
    // ------------------------------------------------------------------
    wire cpu_bus_awvalid, cpu_bus_awready;
    wire [31:0] cpu_bus_awaddr;
    wire [2:0] cpu_bus_awprot;
    wire cpu_bus_wvalid, cpu_bus_wready;
    wire [31:0] cpu_bus_wdata;
    wire [3:0] cpu_bus_wstrb;
    wire cpu_bus_bvalid, cpu_bus_bready;
    wire [1:0] cpu_bus_bresp;
    wire cpu_bus_arvalid, cpu_bus_arready;
    wire [31:0] cpu_bus_araddr;
    wire [2:0] cpu_bus_arprot;
    wire cpu_bus_rvalid, cpu_bus_rready;
    wire [31:0] cpu_bus_rdata;
    wire [1:0] cpu_bus_rresp;

    picorv32_cpu_mmu cpu_mmu_inst (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .s_axil_awaddr(cpu_awaddr), .s_axil_awprot(cpu_awprot),
        .s_axil_awvalid(cpu_awvalid), .s_axil_awready(cpu_awready),
        .s_axil_wdata(cpu_wdata), .s_axil_wstrb(cpu_wstrb),
        .s_axil_wvalid(cpu_wvalid), .s_axil_wready(cpu_wready),
        .s_axil_bresp(), .s_axil_bvalid(cpu_bvalid),
        .s_axil_bready(cpu_bready),
        .s_axil_araddr(cpu_araddr), .s_axil_arprot(cpu_arprot),
        .s_axil_arvalid(cpu_arvalid), .s_axil_arready(cpu_arready),
        .s_axil_rdata(cpu_rdata), .s_axil_rresp(),
        .s_axil_rvalid(cpu_rvalid), .s_axil_rready(cpu_rready),

        .m_axil_awaddr(cpu_bus_awaddr), .m_axil_awprot(cpu_bus_awprot),
        .m_axil_awvalid(cpu_bus_awvalid), .m_axil_awready(cpu_bus_awready),
        .m_axil_wdata(cpu_bus_wdata), .m_axil_wstrb(cpu_bus_wstrb),
        .m_axil_wvalid(cpu_bus_wvalid), .m_axil_wready(cpu_bus_wready),
        .m_axil_bresp(cpu_bus_bresp), .m_axil_bvalid(cpu_bus_bvalid),
        .m_axil_bready(cpu_bus_bready),
        .m_axil_araddr(cpu_bus_araddr), .m_axil_arprot(cpu_bus_arprot),
        .m_axil_arvalid(cpu_bus_arvalid), .m_axil_arready(cpu_bus_arready),
        .m_axil_rdata(cpu_bus_rdata), .m_axil_rresp(cpu_bus_rresp),
        .m_axil_rvalid(cpu_bus_rvalid), .m_axil_rready(cpu_bus_rready),
        .fault_irq_o(cpu_mmu_fault_irq), .enabled_o(cpu_mmu_enabled),
        .cpu_idle_o(cpu_mmu_idle),
        .tlb_hit_count_o(cpu_mmu_tlb_hits),
        .tlb_miss_count_o(cpu_mmu_tlb_misses)
    );

    // ------------------------------------------------------------------
    // CPU AXI4-Lite address router
    // ------------------------------------------------------------------
    wire cpu_bus_idle;

    wire [AXI_ADDR_WIDTH-1:0] cpu_ram_awaddr, cpu_ram_araddr;
    wire [2:0] cpu_ram_awprot, cpu_ram_arprot;
    wire cpu_ram_awvalid, cpu_ram_awready;
    wire [31:0] cpu_ram_wdata;
    wire [3:0] cpu_ram_wstrb;
    wire cpu_ram_wvalid, cpu_ram_wready;
    wire [1:0] cpu_ram_bresp;
    wire cpu_ram_bvalid, cpu_ram_bready;
    wire cpu_ram_arvalid, cpu_ram_arready;
    wire [31:0] cpu_ram_rdata;
    wire [1:0] cpu_ram_rresp;
    wire cpu_ram_rvalid, cpu_ram_rready;

    wire [7:0] dma_axil_awaddr, dma_axil_araddr;
    wire [2:0] dma_axil_awprot, dma_axil_arprot;
    wire dma_axil_awvalid, dma_axil_awready;
    wire [31:0] dma_axil_wdata;
    wire [3:0] dma_axil_wstrb;
    wire dma_axil_wvalid, dma_axil_wready;
    wire [1:0] dma_axil_bresp;
    wire dma_axil_bvalid, dma_axil_bready;
    wire dma_axil_arvalid, dma_axil_arready;
    wire [31:0] dma_axil_rdata;
    wire [1:0] dma_axil_rresp;
    wire dma_axil_rvalid, dma_axil_rready;

    wire [7:0] uart_axil_awaddr, uart_axil_araddr;
    wire [2:0] uart_axil_awprot, uart_axil_arprot;
    wire uart_axil_awvalid, uart_axil_awready;
    wire [31:0] uart_axil_wdata;
    wire [3:0] uart_axil_wstrb;
    wire uart_axil_wvalid, uart_axil_wready;
    wire [1:0] uart_axil_bresp;
    wire uart_axil_bvalid, uart_axil_bready;
    wire uart_axil_arvalid, uart_axil_arready;
    wire [31:0] uart_axil_rdata;
    wire [1:0] uart_axil_rresp;
    wire uart_axil_rvalid, uart_axil_rready;

    wire [7:0] systolic_axil_awaddr, systolic_axil_araddr;
    wire [2:0] systolic_axil_awprot, systolic_axil_arprot;
    wire systolic_axil_awvalid, systolic_axil_awready;
    wire [31:0] systolic_axil_wdata;
    wire [3:0] systolic_axil_wstrb;
    wire systolic_axil_wvalid, systolic_axil_wready;
    wire [1:0] systolic_axil_bresp;
    wire systolic_axil_bvalid, systolic_axil_bready;
    wire systolic_axil_arvalid, systolic_axil_arready;
    wire [31:0] systolic_axil_rdata;
    wire [1:0] systolic_axil_rresp;
    wire systolic_axil_rvalid, systolic_axil_rready;

    wire [7:0] uart_apb_paddr;
    wire uart_apb_psel;
    wire uart_apb_penable;
    wire uart_apb_pwrite;
    wire [31:0] uart_apb_pwdata;
    wire [3:0] uart_apb_pstrb;
    wire [31:0] uart_apb_prdata;
    wire uart_apb_pready;
    wire uart_apb_pslverr;

    picorv32_axil_router #(
        .RAM_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .BRAM_ADDR_WIDTH(BRAM_ADDR_WIDTH),
        .PERIPH_ADDR_WIDTH(8),
        .DDR_ENABLE(ENABLE_DDR3),
        .DDR_BASE_ADDR(DDR_BASE_ADDR),
        .DDR_SIZE_BYTES(DDR_SIZE_BYTES)
    ) cpu_router_inst (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .s_axil_awaddr(cpu_bus_awaddr), .s_axil_awprot(cpu_bus_awprot),
        .s_axil_awvalid(cpu_bus_awvalid), .s_axil_awready(cpu_bus_awready),
        .s_axil_wdata(cpu_bus_wdata), .s_axil_wstrb(cpu_bus_wstrb),
        .s_axil_wvalid(cpu_bus_wvalid), .s_axil_wready(cpu_bus_wready),
        .s_axil_bresp(cpu_bus_bresp), .s_axil_bvalid(cpu_bus_bvalid),
        .s_axil_bready(cpu_bus_bready),
        .s_axil_araddr(cpu_bus_araddr), .s_axil_arprot(cpu_bus_arprot),
        .s_axil_arvalid(cpu_bus_arvalid), .s_axil_arready(cpu_bus_arready),
        .s_axil_rdata(cpu_bus_rdata), .s_axil_rresp(cpu_bus_rresp),
        .s_axil_rvalid(cpu_bus_rvalid), .s_axil_rready(cpu_bus_rready),

        .m_ram_awaddr(cpu_ram_awaddr), .m_ram_awprot(cpu_ram_awprot),
        .m_ram_awvalid(cpu_ram_awvalid), .m_ram_awready(cpu_ram_awready),
        .m_ram_wdata(cpu_ram_wdata), .m_ram_wstrb(cpu_ram_wstrb),
        .m_ram_wvalid(cpu_ram_wvalid), .m_ram_wready(cpu_ram_wready),
        .m_ram_bresp(cpu_ram_bresp), .m_ram_bvalid(cpu_ram_bvalid),
        .m_ram_bready(cpu_ram_bready),
        .m_ram_araddr(cpu_ram_araddr), .m_ram_arprot(cpu_ram_arprot),
        .m_ram_arvalid(cpu_ram_arvalid), .m_ram_arready(cpu_ram_arready),
        .m_ram_rdata(cpu_ram_rdata), .m_ram_rresp(cpu_ram_rresp),
        .m_ram_rvalid(cpu_ram_rvalid), .m_ram_rready(cpu_ram_rready),

        .m_dma_awaddr(dma_axil_awaddr), .m_dma_awprot(dma_axil_awprot),
        .m_dma_awvalid(dma_axil_awvalid), .m_dma_awready(dma_axil_awready),
        .m_dma_wdata(dma_axil_wdata), .m_dma_wstrb(dma_axil_wstrb),
        .m_dma_wvalid(dma_axil_wvalid), .m_dma_wready(dma_axil_wready),
        .m_dma_bresp(dma_axil_bresp), .m_dma_bvalid(dma_axil_bvalid),
        .m_dma_bready(dma_axil_bready),
        .m_dma_araddr(dma_axil_araddr), .m_dma_arprot(dma_axil_arprot),
        .m_dma_arvalid(dma_axil_arvalid), .m_dma_arready(dma_axil_arready),
        .m_dma_rdata(dma_axil_rdata), .m_dma_rresp(dma_axil_rresp),
        .m_dma_rvalid(dma_axil_rvalid), .m_dma_rready(dma_axil_rready),

        .m_uart_awaddr(uart_axil_awaddr), .m_uart_awprot(uart_axil_awprot),
        .m_uart_awvalid(uart_axil_awvalid), .m_uart_awready(uart_axil_awready),
        .m_uart_wdata(uart_axil_wdata), .m_uart_wstrb(uart_axil_wstrb),
        .m_uart_wvalid(uart_axil_wvalid), .m_uart_wready(uart_axil_wready),
        .m_uart_bresp(uart_axil_bresp), .m_uart_bvalid(uart_axil_bvalid),
        .m_uart_bready(uart_axil_bready),
        .m_uart_araddr(uart_axil_araddr), .m_uart_arprot(uart_axil_arprot),
        .m_uart_arvalid(uart_axil_arvalid), .m_uart_arready(uart_axil_arready),
        .m_uart_rdata(uart_axil_rdata), .m_uart_rresp(uart_axil_rresp),
        .m_uart_rvalid(uart_axil_rvalid), .m_uart_rready(uart_axil_rready),
        .m_systolic_awaddr(systolic_axil_awaddr), .m_systolic_awprot(systolic_axil_awprot),
        .m_systolic_awvalid(systolic_axil_awvalid), .m_systolic_awready(systolic_axil_awready),
        .m_systolic_wdata(systolic_axil_wdata), .m_systolic_wstrb(systolic_axil_wstrb),
        .m_systolic_wvalid(systolic_axil_wvalid), .m_systolic_wready(systolic_axil_wready),
        .m_systolic_bresp(systolic_axil_bresp), .m_systolic_bvalid(systolic_axil_bvalid),
        .m_systolic_bready(systolic_axil_bready),
        .m_systolic_araddr(systolic_axil_araddr), .m_systolic_arprot(systolic_axil_arprot),
        .m_systolic_arvalid(systolic_axil_arvalid), .m_systolic_arready(systolic_axil_arready),
        .m_systolic_rdata(systolic_axil_rdata), .m_systolic_rresp(systolic_axil_rresp),
        .m_systolic_rvalid(systolic_axil_rvalid), .m_systolic_rready(systolic_axil_rready),
        .cpu_bus_idle_o(cpu_bus_idle)
    );

    // ------------------------------------------------------------------
    // DMA + IOMMU IP and UART AXI4-Stream endpoint
    // ------------------------------------------------------------------
    wire [SYS_ID_WIDTH-1:0] dma_awid, dma_bid, dma_arid, dma_rid;
    wire [AXI_ADDR_WIDTH-1:0] dma_awaddr, dma_araddr;
    wire [7:0] dma_awlen, dma_arlen;
    wire [2:0] dma_awsize, dma_arsize;
    wire [1:0] dma_awburst, dma_arburst;
    wire dma_awlock, dma_arlock;
    wire [3:0] dma_awcache, dma_arcache;
    wire [2:0] dma_awprot, dma_arprot;
    wire [3:0] dma_awqos, dma_arqos, dma_awregion, dma_arregion;
    wire dma_awvalid, dma_awready;
    wire [31:0] dma_wdata;
    wire [3:0] dma_wstrb;
    wire dma_wlast, dma_wvalid, dma_wready;
    wire [1:0] dma_bresp;
    wire dma_bvalid, dma_bready;
    wire dma_arvalid, dma_arready;
    wire [31:0] dma_rdata;
    wire [1:0] dma_rresp;
    wire dma_rlast, dma_rvalid, dma_rready;

    wire [31:0] dma_to_periph_tdata, periph_to_dma_tdata;
    wire [3:0] dma_to_periph_tkeep, periph_to_dma_tkeep;
    wire dma_to_periph_tvalid, dma_to_periph_tready, dma_to_periph_tlast;
    wire periph_to_dma_tvalid, periph_to_dma_tready, periph_to_dma_tlast;

    wire [31:0] dma_to_uart_tdata, uart_to_dma_tdata;
    wire [3:0] dma_to_uart_tkeep, uart_to_dma_tkeep;
    wire dma_to_uart_tvalid, dma_to_uart_tready, dma_to_uart_tlast;
    wire uart_to_dma_tvalid, uart_to_dma_tready, uart_to_dma_tlast;

    dma_mmu_axi_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(DMA_AXI_ID_WIDTH),
        .AXIL_ADDR_WIDTH(8),
        .LEN_WIDTH(AXI_ADDR_WIDTH),
        .PAGE_SHIFT(12),
        .PT_ENTRIES(16),
        .TLB_ENTRIES(4),
        .AXI_MAX_BURST_LEN(16)
    ) dma_iommu_inst (
        .aclk(clk_i), .aresetn(rst_ni),
        .cpu_bus_idle_i(cpu_bus_idle && cpu_mmu_idle), .irq_o(dma_irq_o),
        .s_axil_awaddr(dma_axil_awaddr), .s_axil_awprot(dma_axil_awprot),
        .s_axil_awvalid(dma_axil_awvalid), .s_axil_awready(dma_axil_awready),
        .s_axil_wdata(dma_axil_wdata), .s_axil_wstrb(dma_axil_wstrb),
        .s_axil_wvalid(dma_axil_wvalid), .s_axil_wready(dma_axil_wready),
        .s_axil_bresp(dma_axil_bresp), .s_axil_bvalid(dma_axil_bvalid),
        .s_axil_bready(dma_axil_bready),
        .s_axil_araddr(dma_axil_araddr), .s_axil_arprot(dma_axil_arprot),
        .s_axil_arvalid(dma_axil_arvalid), .s_axil_arready(dma_axil_arready),
        .s_axil_rdata(dma_axil_rdata), .s_axil_rresp(dma_axil_rresp),
        .s_axil_rvalid(dma_axil_rvalid), .s_axil_rready(dma_axil_rready),
        .m_axi_awid(dma_awid), .m_axi_awaddr(dma_awaddr),
        .m_axi_awlen(dma_awlen), .m_axi_awsize(dma_awsize),
        .m_axi_awburst(dma_awburst), .m_axi_awlock(dma_awlock),
        .m_axi_awcache(dma_awcache), .m_axi_awprot(dma_awprot),
        .m_axi_awqos(dma_awqos), .m_axi_awregion(dma_awregion),
        .m_axi_awvalid(dma_awvalid), .m_axi_awready(dma_awready),
        .m_axi_wdata(dma_wdata), .m_axi_wstrb(dma_wstrb),
        .m_axi_wlast(dma_wlast), .m_axi_wvalid(dma_wvalid),
        .m_axi_wready(dma_wready),
        .m_axi_bid(dma_bid), .m_axi_bresp(dma_bresp),
        .m_axi_bvalid(dma_bvalid), .m_axi_bready(dma_bready),
        .m_axi_arid(dma_arid), .m_axi_araddr(dma_araddr),
        .m_axi_arlen(dma_arlen), .m_axi_arsize(dma_arsize),
        .m_axi_arburst(dma_arburst), .m_axi_arlock(dma_arlock),
        .m_axi_arcache(dma_arcache), .m_axi_arprot(dma_arprot),
        .m_axi_arqos(dma_arqos), .m_axi_arregion(dma_arregion),
        .m_axi_arvalid(dma_arvalid), .m_axi_arready(dma_arready),
        .m_axi_rid(dma_rid), .m_axi_rdata(dma_rdata),
        .m_axi_rresp(dma_rresp), .m_axi_rlast(dma_rlast),
        .m_axi_rvalid(dma_rvalid), .m_axi_rready(dma_rready),
        .s_axis_periph_tdata(periph_to_dma_tdata),
        .s_axis_periph_tkeep(periph_to_dma_tkeep),
        .s_axis_periph_tvalid(periph_to_dma_tvalid),
        .s_axis_periph_tready(periph_to_dma_tready),
        .s_axis_periph_tlast(periph_to_dma_tlast),
        .m_axis_periph_tdata(dma_to_periph_tdata),
        .m_axis_periph_tkeep(dma_to_periph_tkeep),
        .m_axis_periph_tvalid(dma_to_periph_tvalid),
        .m_axis_periph_tready(dma_to_periph_tready),
        .m_axis_periph_tlast(dma_to_periph_tlast)
    );

    wire systolic_stream_sel;
    wire [31:0] systolic_axis_out_tdata, systolic_axis_in_tdata;
    wire [3:0]  systolic_axis_out_tkeep, systolic_axis_in_tkeep;
    wire        systolic_axis_out_tvalid, systolic_axis_out_tlast, systolic_axis_out_tready;
    wire        systolic_axis_in_tvalid, systolic_axis_in_tlast, systolic_axis_in_tready;

    // Stream Demux: DMA to Peripheral
    assign systolic_axis_in_tdata  = dma_to_periph_tdata;
    assign systolic_axis_in_tkeep  = dma_to_periph_tkeep;
    assign systolic_axis_in_tvalid = systolic_stream_sel ? dma_to_periph_tvalid : 1'b0;
    assign systolic_axis_in_tlast  = dma_to_periph_tlast;

    assign dma_to_uart_tdata  = dma_to_periph_tdata;
    assign dma_to_uart_tkeep  = dma_to_periph_tkeep;
    assign dma_to_uart_tvalid = systolic_stream_sel ? 1'b0 : dma_to_periph_tvalid;
    assign dma_to_uart_tlast  = dma_to_periph_tlast;

    assign dma_to_periph_tready = systolic_stream_sel ? systolic_axis_in_tready : dma_to_uart_tready;

    // Stream Mux: Peripheral to DMA
    assign periph_to_dma_tdata  = systolic_stream_sel ? systolic_axis_out_tdata : uart_to_dma_tdata;
    assign periph_to_dma_tkeep  = systolic_stream_sel ? systolic_axis_out_tkeep : uart_to_dma_tkeep;
    assign periph_to_dma_tvalid = systolic_stream_sel ? systolic_axis_out_tvalid : uart_to_dma_tvalid;
    assign periph_to_dma_tlast  = systolic_stream_sel ? systolic_axis_out_tlast : uart_to_dma_tlast;

    assign systolic_axis_out_tready = systolic_stream_sel ? periph_to_dma_tready : 1'b0;
    assign uart_to_dma_tready     = systolic_stream_sel ? 1'b0 : periph_to_dma_tready;

    systolic_accel_axil_axis #(
        .ADDR_WIDTH(8)
    ) systolic_accel_inst (
        .aclk(clk_i), .aresetn(rst_ni),
        .s_axil_awaddr(systolic_axil_awaddr), .s_axil_awprot(systolic_axil_awprot),
        .s_axil_awvalid(systolic_axil_awvalid), .s_axil_awready(systolic_axil_awready),
        .s_axil_wdata(systolic_axil_wdata), .s_axil_wstrb(systolic_axil_wstrb),
        .s_axil_wvalid(systolic_axil_wvalid), .s_axil_wready(systolic_axil_wready),
        .s_axil_bresp(systolic_axil_bresp), .s_axil_bvalid(systolic_axil_bvalid),
        .s_axil_bready(systolic_axil_bready),
        .s_axil_araddr(systolic_axil_araddr), .s_axil_arprot(systolic_axil_arprot),
        .s_axil_arvalid(systolic_axil_arvalid), .s_axil_arready(systolic_axil_arready),
        .s_axil_rdata(systolic_axil_rdata), .s_axil_rresp(systolic_axil_rresp),
        .s_axil_rvalid(systolic_axil_rvalid), .s_axil_rready(systolic_axil_rready),
        .s_axis_tdata(systolic_axis_in_tdata),
        .s_axis_tkeep(systolic_axis_in_tkeep),
        .s_axis_tvalid(systolic_axis_in_tvalid),
        .s_axis_tready(systolic_axis_in_tready),
        .s_axis_tlast(systolic_axis_in_tlast),
        .m_axis_tdata(systolic_axis_out_tdata),
        .m_axis_tkeep(systolic_axis_out_tkeep),
        .m_axis_tvalid(systolic_axis_out_tvalid),
        .m_axis_tready(systolic_axis_out_tready),
        .m_axis_tlast(systolic_axis_out_tlast),
        .stream_select_o(systolic_stream_sel),
        .irq_o(systolic_irq)
    );

    axil_to_apb_bridge #(
        .ADDR_WIDTH(8),
        .DATA_WIDTH(32)
    ) uart_bridge_inst (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .s_axil_awaddr(uart_axil_awaddr), .s_axil_awprot(uart_axil_awprot),
        .s_axil_awvalid(uart_axil_awvalid), .s_axil_awready(uart_axil_awready),
        .s_axil_wdata(uart_axil_wdata), .s_axil_wstrb(uart_axil_wstrb),
        .s_axil_wvalid(uart_axil_wvalid), .s_axil_wready(uart_axil_wready),
        .s_axil_bresp(uart_axil_bresp), .s_axil_bvalid(uart_axil_bvalid),
        .s_axil_bready(uart_axil_bready),
        .s_axil_araddr(uart_axil_araddr), .s_axil_arprot(uart_axil_arprot),
        .s_axil_arvalid(uart_axil_arvalid), .s_axil_arready(uart_axil_arready),
        .s_axil_rdata(uart_axil_rdata), .s_axil_rresp(uart_axil_rresp),
        .s_axil_rvalid(uart_axil_rvalid), .s_axil_rready(uart_axil_rready),
        .m_apb_paddr(uart_apb_paddr), .m_apb_psel(uart_apb_psel),
        .m_apb_penable(uart_apb_penable), .m_apb_pwrite(uart_apb_pwrite),
        .m_apb_pwdata(uart_apb_pwdata), .m_apb_pstrb(uart_apb_pstrb),
        .m_apb_prdata(uart_apb_prdata), .m_apb_pready(uart_apb_pready),
        .m_apb_pslverr(uart_apb_pslverr)
    );

    uart_apb_axis #(
        .APB_ADDR_WIDTH(8),
        .DEFAULT_DIV(UART_DEFAULT_DIV)
    ) uart_inst (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .s_apb_paddr(uart_apb_paddr), .s_apb_psel(uart_apb_psel),
        .s_apb_penable(uart_apb_penable), .s_apb_pwrite(uart_apb_pwrite),
        .s_apb_pwdata(uart_apb_pwdata), .s_apb_pstrb(uart_apb_pstrb),
        .s_apb_prdata(uart_apb_prdata), .s_apb_pready(uart_apb_pready),
        .s_apb_pslverr(uart_apb_pslverr),
        .s_axis_tx_tdata(dma_to_uart_tdata),
        .s_axis_tx_tkeep(dma_to_uart_tkeep),
        .s_axis_tx_tvalid(dma_to_uart_tvalid),
        .s_axis_tx_tready(dma_to_uart_tready),
        .s_axis_tx_tlast(dma_to_uart_tlast),
        .m_axis_rx_tdata(uart_to_dma_tdata),
        .m_axis_rx_tkeep(uart_to_dma_tkeep),
        .m_axis_rx_tvalid(uart_to_dma_tvalid),
        .m_axis_rx_tready(uart_to_dma_tready),
        .m_axis_rx_tlast(uart_to_dma_tlast),
        .uart_tx_o(uart_tx_o), .uart_rx_i(uart_rx_i),
        .irq_o(uart_irq_o),
        .tx_byte_o(uart_tx_byte_o),
        .tx_byte_valid_o(uart_tx_byte_valid_o)
    );

    // ------------------------------------------------------------------
    // Shared AXI4 system interconnect: CPU RAM port + DMA memory master
    // ------------------------------------------------------------------
    wire [1:0] sys_s_awready, sys_s_wready, sys_s_bvalid;
    wire [2*SYS_ID_WIDTH-1:0] sys_s_bid;
    wire [3:0] sys_s_bresp;
    wire [1:0] sys_s_arready, sys_s_rvalid, sys_s_rlast;
    wire [2*SYS_ID_WIDTH-1:0] sys_s_rid;
    wire [63:0] sys_s_rdata;
    wire [3:0] sys_s_rresp;

    assign cpu_ram_awready = sys_s_awready[0];
    assign dma_awready = sys_s_awready[1];
    assign cpu_ram_wready = sys_s_wready[0];
    assign dma_wready = sys_s_wready[1];
    assign cpu_ram_bvalid = sys_s_bvalid[0];
    assign dma_bvalid = sys_s_bvalid[1];
    assign cpu_ram_bresp = sys_s_bresp[1:0];
    assign dma_bresp = sys_s_bresp[3:2];
    assign dma_bid = sys_s_bid[2*SYS_ID_WIDTH-1:SYS_ID_WIDTH];
    assign cpu_ram_arready = sys_s_arready[0];
    assign dma_arready = sys_s_arready[1];
    assign cpu_ram_rvalid = sys_s_rvalid[0];
    assign dma_rvalid = sys_s_rvalid[1];
    assign cpu_ram_rdata = sys_s_rdata[31:0];
    assign dma_rdata = sys_s_rdata[63:32];
    assign cpu_ram_rresp = sys_s_rresp[1:0];
    assign dma_rresp = sys_s_rresp[3:2];
    assign dma_rlast = sys_s_rlast[1];
    assign dma_rid = sys_s_rid[2*SYS_ID_WIDTH-1:SYS_ID_WIDTH];

    wire [MEM_ID_WIDTH-1:0] mem_awid, mem_bid, mem_arid, mem_rid;
    wire [AXI_ADDR_WIDTH-1:0] mem_awaddr, mem_araddr;
    wire [7:0] mem_awlen, mem_arlen;
    wire [2:0] mem_awsize, mem_arsize;
    wire [1:0] mem_awburst, mem_arburst;
    wire mem_awlock, mem_arlock;
    wire [3:0] mem_awcache, mem_arcache;
    wire [2:0] mem_awprot, mem_arprot;
    wire [3:0] mem_awqos, mem_arqos, mem_awregion, mem_arregion;
    wire mem_awvalid, mem_awready;
    wire [31:0] mem_wdata;
    wire [3:0] mem_wstrb;
    wire mem_wlast, mem_wvalid, mem_wready;
    wire [1:0] mem_bresp;
    wire mem_bvalid, mem_bready;
    wire mem_arvalid, mem_arready;
    wire [31:0] mem_rdata;
    wire [1:0] mem_rresp;
    wire mem_rlast, mem_rvalid, mem_rready;

    // Use the full crossbar here instead of axi_interconnect.  The latter has
    // one combined transaction state machine: if it accepts a CDMA write
    // address before CDMA has produced WDATA, it blocks the read channel that
    // CDMA needs to produce that WDATA.  Independent read/write arbitration
    // avoids that legal AXI AW-before-W deadlock.
    axi_crossbar #(
        .S_COUNT(2), .M_COUNT(1),
        .DATA_WIDTH(32), .ADDR_WIDTH(AXI_ADDR_WIDTH),
        .STRB_WIDTH(4),
        .S_ID_WIDTH(SYS_ID_WIDTH), .M_ID_WIDTH(MEM_ID_WIDTH),
        .S_THREADS({2{32'd2}}), .S_ACCEPT({2{32'd4}}),
        .M_REGIONS(1), .M_ISSUE(32'd8),
        .M_BASE_ADDR({AXI_ADDR_WIDTH{1'b0}}),
        .M_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .M_CONNECT_READ(2'b11), .M_CONNECT_WRITE(2'b11)
    ) system_axi_crossbar (
        .clk(clk_i), .rst(rst),
        .s_axi_awid({dma_awid, {SYS_ID_WIDTH{1'b0}}}),
        .s_axi_awaddr({dma_awaddr, cpu_ram_awaddr}),
        .s_axi_awlen({dma_awlen, 8'd0}),
        .s_axi_awsize({dma_awsize, 3'b010}),
        .s_axi_awburst({dma_awburst, 2'b01}),
        .s_axi_awlock({dma_awlock, 1'b0}),
        .s_axi_awcache({dma_awcache, 4'd0}),
        .s_axi_awprot({dma_awprot, cpu_ram_awprot}),
        .s_axi_awqos({dma_awqos, 4'd0}), .s_axi_awuser(2'b00),
        .s_axi_awvalid({dma_awvalid, cpu_ram_awvalid}),
        .s_axi_awready(sys_s_awready),
        .s_axi_wdata({dma_wdata, cpu_ram_wdata}),
        .s_axi_wstrb({dma_wstrb, cpu_ram_wstrb}),
        .s_axi_wlast({dma_wlast, 1'b1}), .s_axi_wuser(2'b00),
        .s_axi_wvalid({dma_wvalid, cpu_ram_wvalid}),
        .s_axi_wready(sys_s_wready),
        .s_axi_bid(sys_s_bid), .s_axi_bresp(sys_s_bresp),
        .s_axi_buser(), .s_axi_bvalid(sys_s_bvalid),
        .s_axi_bready({dma_bready, cpu_ram_bready}),
        .s_axi_arid({dma_arid, {SYS_ID_WIDTH{1'b0}}}),
        .s_axi_araddr({dma_araddr, cpu_ram_araddr}),
        .s_axi_arlen({dma_arlen, 8'd0}),
        .s_axi_arsize({dma_arsize, 3'b010}),
        .s_axi_arburst({dma_arburst, 2'b01}),
        .s_axi_arlock({dma_arlock, 1'b0}),
        .s_axi_arcache({dma_arcache, 4'd0}),
        .s_axi_arprot({dma_arprot, cpu_ram_arprot}),
        .s_axi_arqos({dma_arqos, 4'd0}), .s_axi_aruser(2'b00),
        .s_axi_arvalid({dma_arvalid, cpu_ram_arvalid}),
        .s_axi_arready(sys_s_arready),
        .s_axi_rid(sys_s_rid), .s_axi_rdata(sys_s_rdata),
        .s_axi_rresp(sys_s_rresp), .s_axi_rlast(sys_s_rlast),
        .s_axi_ruser(), .s_axi_rvalid(sys_s_rvalid),
        .s_axi_rready({dma_rready, cpu_ram_rready}),

        .m_axi_awid(mem_awid), .m_axi_awaddr(mem_awaddr),
        .m_axi_awlen(mem_awlen), .m_axi_awsize(mem_awsize),
        .m_axi_awburst(mem_awburst), .m_axi_awlock(mem_awlock),
        .m_axi_awcache(mem_awcache), .m_axi_awprot(mem_awprot),
        .m_axi_awqos(mem_awqos), .m_axi_awregion(mem_awregion),
        .m_axi_awuser(), .m_axi_awvalid(mem_awvalid),
        .m_axi_awready(mem_awready),
        .m_axi_wdata(mem_wdata), .m_axi_wstrb(mem_wstrb),
        .m_axi_wlast(mem_wlast), .m_axi_wuser(),
        .m_axi_wvalid(mem_wvalid), .m_axi_wready(mem_wready),
        .m_axi_bid(mem_bid), .m_axi_bresp(mem_bresp),
        .m_axi_buser(1'b0), .m_axi_bvalid(mem_bvalid),
        .m_axi_bready(mem_bready),
        .m_axi_arid(mem_arid), .m_axi_araddr(mem_araddr),
        .m_axi_arlen(mem_arlen), .m_axi_arsize(mem_arsize),
        .m_axi_arburst(mem_arburst), .m_axi_arlock(mem_arlock),
        .m_axi_arcache(mem_arcache), .m_axi_arprot(mem_arprot),
        .m_axi_arqos(mem_arqos), .m_axi_arregion(mem_arregion),
        .m_axi_aruser(), .m_axi_arvalid(mem_arvalid),
        .m_axi_arready(mem_arready),
        .m_axi_rid(mem_rid), .m_axi_rdata(mem_rdata),
        .m_axi_rresp(mem_rresp), .m_axi_rlast(mem_rlast),
        .m_axi_ruser(1'b0), .m_axi_rvalid(mem_rvalid),
        .m_axi_rready(mem_rready)
    );

    generate
        if (ENABLE_DDR3) begin : g_bram_ddr3
            axi_bram_ddr3_subsystem #(
                .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
                .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
                .AXI_ID_WIDTH(MEM_ID_WIDTH),
                .BRAM_ADDR_WIDTH(BRAM_ADDR_WIDTH),
                .BOOT_INIT_FILE(MEM_INIT_FILE),
                .DDR_BASE_ADDR(DDR_BASE_ADDR),
                .DDR_SIZE_BYTES(DDR_SIZE_BYTES)
            ) memory_subsystem_inst (
                .clk_i(clk_i), .rst_i(rst),
                .s_axi_awid(mem_awid), .s_axi_awaddr(mem_awaddr),
                .s_axi_awlen(mem_awlen), .s_axi_awsize(mem_awsize),
                .s_axi_awburst(mem_awburst), .s_axi_awlock(mem_awlock),
                .s_axi_awcache(mem_awcache), .s_axi_awprot(mem_awprot),
                .s_axi_awqos(mem_awqos), .s_axi_awregion(mem_awregion),
                .s_axi_awvalid(mem_awvalid), .s_axi_awready(mem_awready),
                .s_axi_wdata(mem_wdata), .s_axi_wstrb(mem_wstrb),
                .s_axi_wlast(mem_wlast), .s_axi_wvalid(mem_wvalid),
                .s_axi_wready(mem_wready), .s_axi_bid(mem_bid),
                .s_axi_bresp(mem_bresp), .s_axi_bvalid(mem_bvalid),
                .s_axi_bready(mem_bready), .s_axi_arid(mem_arid),
                .s_axi_araddr(mem_araddr), .s_axi_arlen(mem_arlen),
                .s_axi_arsize(mem_arsize), .s_axi_arburst(mem_arburst),
                .s_axi_arlock(mem_arlock), .s_axi_arcache(mem_arcache),
                .s_axi_arprot(mem_arprot), .s_axi_arqos(mem_arqos),
                .s_axi_arregion(mem_arregion), .s_axi_arvalid(mem_arvalid),
                .s_axi_arready(mem_arready), .s_axi_rid(mem_rid),
                .s_axi_rdata(mem_rdata), .s_axi_rresp(mem_rresp),
                .s_axi_rlast(mem_rlast), .s_axi_rvalid(mem_rvalid),
                .s_axi_rready(mem_rready),
                .ddr_init_done_o, .ddr_calib_done_o,
                .ddr_calib_error_o, .ddr_refresh_busy_o,
                .ddr_refresh_count_o,
                .dfi_cmd_valid_o(ddr_dfi_cmd_valid_o),
                .dfi_cmd_ready_i(ddr_dfi_cmd_ready_i),
                .dfi_cmd_o(ddr_dfi_cmd_o), .dfi_bank_o(ddr_dfi_bank_o),
                .dfi_addr_o(ddr_dfi_addr_o),
                .dfi_wrdata_o(ddr_dfi_wrdata_o),
                .dfi_wrmask_o(ddr_dfi_wrmask_o),
                .dfi_rddata_valid_i(ddr_dfi_rddata_valid_i),
                .dfi_rddata_i(ddr_dfi_rddata_i),
                .dfi_error_i(ddr_dfi_error_i),
                .phy_calib_start_o(ddr_phy_calib_start_o),
                .phy_calib_done_i(ddr_phy_calib_done_i),
                .phy_calib_error_i(ddr_phy_calib_error_i)
            );
        end else begin : g_bram_only
            axi_ram #(
                .DATA_WIDTH(32), .ADDR_WIDTH(AXI_ADDR_WIDTH),
                .STRB_WIDTH(4), .ID_WIDTH(MEM_ID_WIDTH),
                .PIPELINE_OUTPUT(1), .INIT_FILE(MEM_INIT_FILE)
            ) system_ram_inst (
                .clk(clk_i), .rst(rst),
                .s_axi_awid(mem_awid), .s_axi_awaddr(mem_awaddr),
                .s_axi_awlen(mem_awlen), .s_axi_awsize(mem_awsize),
                .s_axi_awburst(mem_awburst), .s_axi_awlock(mem_awlock),
                .s_axi_awcache(mem_awcache), .s_axi_awprot(mem_awprot),
                .s_axi_awvalid(mem_awvalid), .s_axi_awready(mem_awready),
                .s_axi_wdata(mem_wdata), .s_axi_wstrb(mem_wstrb),
                .s_axi_wlast(mem_wlast), .s_axi_wvalid(mem_wvalid),
                .s_axi_wready(mem_wready), .s_axi_bid(mem_bid),
                .s_axi_bresp(mem_bresp), .s_axi_bvalid(mem_bvalid),
                .s_axi_bready(mem_bready), .s_axi_arid(mem_arid),
                .s_axi_araddr(mem_araddr), .s_axi_arlen(mem_arlen),
                .s_axi_arsize(mem_arsize), .s_axi_arburst(mem_arburst),
                .s_axi_arlock(mem_arlock), .s_axi_arcache(mem_arcache),
                .s_axi_arprot(mem_arprot), .s_axi_arvalid(mem_arvalid),
                .s_axi_arready(mem_arready), .s_axi_rid(mem_rid),
                .s_axi_rdata(mem_rdata), .s_axi_rresp(mem_rresp),
                .s_axi_rlast(mem_rlast), .s_axi_rvalid(mem_rvalid),
                .s_axi_rready(mem_rready)
            );

            always_comb begin
                ddr_init_done_o = 1'b0;
                ddr_calib_done_o = 1'b0;
                ddr_calib_error_o = 1'b0;
                ddr_refresh_busy_o = 1'b0;
                ddr_refresh_count_o = '0;
                ddr_dfi_cmd_valid_o = 1'b0;
                ddr_dfi_cmd_o = '0;
                ddr_dfi_bank_o = '0;
                ddr_dfi_addr_o = '0;
                ddr_dfi_wrdata_o = '0;
                ddr_dfi_wrmask_o = '1;
                ddr_phy_calib_start_o = 1'b0;
            end
        end
    endgenerate

    logic _unused;
    assign _unused = &{1'b0, cpu_eoi, dma_awregion, dma_arregion,
                       mem_awqos, mem_arqos, mem_awregion, mem_arregion};

endmodule
