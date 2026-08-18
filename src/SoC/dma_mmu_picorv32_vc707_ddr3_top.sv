`timescale 1ns / 1ps

// Physical VC707 top: PicoRV32 + CPU MMU + DMA/IOMMU + UART + retained AXI
// boot RAM + the board's 1-GiB, 64-bit DDR3 SODIMM through Xilinx MIG 7 Series.
//
// Clock domains:
//   * MIG owns the differential 200-MHz board clock and creates ui_clk=200 MHz.
//   * An MMCM derives the verified 150-MHz SoC clock from ui_clk.
//   * axi_clock_converter crosses 32-bit AXI from 150 MHz to 200 MHz.
//   * axi_dwidth_converter upsizes 32-bit AXI to MIG's 512-bit AXI interface.
module dma_mmu_picorv32_vc707_ddr3_top #(
    parameter MEM_INIT_FILE = "",
    parameter integer BRAM_ADDR_WIDTH = 18,
    parameter integer UART_DEFAULT_DIV = 161
) (
    input  wire        sys_clk_p,
    input  wire        sys_clk_n,
    input  wire        cpu_reset,
    input  wire        uart_rx_i,
    output wire        uart_tx_o,
    output wire [3:0]  led_o,

    output wire [13:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_cas_n,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_cke,
    output wire        ddr3_ras_n,
    output wire        ddr3_reset_n,
    output wire        ddr3_we_n,
    inout  wire [63:0] ddr3_dq,
    inout  wire [7:0]  ddr3_dqs_n,
    inout  wire [7:0]  ddr3_dqs_p,
    output wire [0:0]  ddr3_cs_n,
    output wire [7:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt
);

    localparam integer AXI_ID_WIDTH = 6;

    wire ui_clk;
    wire ui_clk_sync_rst;
    wire mig_mmcm_locked;
    wire init_calib_complete;
    reg  mig_aresetn = 1'b0;

    // The MIG example design registers AXI reset release in the UI domain.
    always @(posedge ui_clk)
        mig_aresetn <= ~ui_clk_sync_rst;

    // Generate the 150-MHz SoC clock from MIG's stable 200-MHz UI clock.
    wire soc_mmcm_clkfb_unbuf;
    wire soc_mmcm_clkfb;
    wire soc_mmcm_clk_unbuf;
    wire clk_150mhz;
    wire soc_mmcm_locked;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(5.000),
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(3.000),
        .CLKOUT0_DIVIDE_F(4.000),
        .STARTUP_WAIT("FALSE")
    ) soc_clock_mmcm_inst (
        .CLKIN1(ui_clk),
        .CLKFBIN(soc_mmcm_clkfb),
        .RST(cpu_reset | ui_clk_sync_rst),
        .PWRDWN(1'b0),
        .CLKFBOUT(soc_mmcm_clkfb_unbuf),
        .CLKOUT0(soc_mmcm_clk_unbuf),
        .LOCKED(soc_mmcm_locked),
        .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(),
        .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(),
        .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB()
    );

    BUFG soc_mmcm_feedback_bufg_inst (
        .I(soc_mmcm_clkfb_unbuf),
        .O(soc_mmcm_clkfb)
    );

    BUFG soc_clock_bufg_inst (
        .I(soc_mmcm_clk_unbuf),
        .O(clk_150mhz)
    );

    wire reset_async = cpu_reset | ~soc_mmcm_locked | ui_clk_sync_rst;
    (* ASYNC_REG = "TRUE" *) reg [2:0] soc_reset_pipe = 3'b111;
    always @(posedge clk_150mhz or posedge reset_async) begin
        if (reset_async)
            soc_reset_pipe <= 3'b111;
        else
            soc_reset_pipe <= {soc_reset_pipe[1:0], 1'b0};
    end
    wire soc_rst_ni = ~soc_reset_pipe[2];

    // Synchronize MIG status before it is exposed through the SoC status page.
    (* ASYNC_REG = "TRUE" *) reg [1:0] calib_sync = 2'b00;
    (* ASYNC_REG = "TRUE" *) reg [1:0] ui_reset_sync = 2'b11;
    always @(posedge clk_150mhz or negedge soc_rst_ni) begin
        if (!soc_rst_ni) begin
            calib_sync <= 2'b00;
            ui_reset_sync <= 2'b11;
        end else begin
            calib_sync <= {calib_sync[0], init_calib_complete};
            ui_reset_sync <= {ui_reset_sync[0], ui_clk_sync_rst};
        end
    end

    // SoC-side 32-bit AXI master (150 MHz).
    wire [AXI_ID_WIDTH-1:0] soc_awid, soc_bid, soc_arid, soc_rid;
    wire [31:0] soc_awaddr, soc_araddr;
    wire [7:0] soc_awlen, soc_arlen;
    wire [2:0] soc_awsize, soc_arsize;
    wire [1:0] soc_awburst, soc_arburst;
    wire soc_awlock, soc_arlock;
    wire [3:0] soc_awcache, soc_arcache;
    wire [2:0] soc_awprot, soc_arprot;
    wire [3:0] soc_awqos, soc_arqos, soc_awregion, soc_arregion;
    wire soc_awvalid, soc_awready;
    wire [31:0] soc_wdata;
    wire [3:0] soc_wstrb;
    wire soc_wlast, soc_wvalid, soc_wready;
    wire [1:0] soc_bresp;
    wire soc_bvalid, soc_bready;
    wire soc_arvalid, soc_arready;
    wire [31:0] soc_rdata;
    wire [1:0] soc_rresp;
    wire soc_rlast, soc_rvalid, soc_rready;

    wire cpu_trap;
    wire dma_irq;
    wire uart_irq;
    wire [7:0] uart_tx_byte_unused;
    wire uart_tx_byte_valid_unused;

    dma_mmu_picorv32_soc #(
        .AXI_ADDR_WIDTH(32),
        .BRAM_ADDR_WIDTH(BRAM_ADDR_WIDTH),
        .UART_DEFAULT_DIV(UART_DEFAULT_DIV),
        .MEM_INIT_FILE(MEM_INIT_FILE),
        .ENABLE_DDR3(1'b1),
        .USE_EXTERNAL_DDR_AXI(1'b1),
        .DDR_BASE_ADDR(32'h8000_0000),
        .DDR_SIZE_BYTES(32'h4000_0000)
    ) soc_inst (
        .clk_i(clk_150mhz), .rst_ni(soc_rst_ni),
        .uart_rx_i(uart_rx_i), .uart_tx_o(uart_tx_o),
        .cpu_trap_o(cpu_trap), .dma_irq_o(dma_irq), .uart_irq_o(uart_irq),
        .uart_tx_byte_o(uart_tx_byte_unused),
        .uart_tx_byte_valid_o(uart_tx_byte_valid_unused),
        .ddr_dfi_cmd_ready_i(1'b0), .ddr_dfi_rddata_valid_i(1'b0),
        .ddr_dfi_rddata_i(32'd0), .ddr_dfi_error_i(1'b0),
        .ddr_phy_calib_done_i(1'b0), .ddr_phy_calib_error_i(1'b0),
        .m_ddr_axi_awid(soc_awid), .m_ddr_axi_awaddr(soc_awaddr),
        .m_ddr_axi_awlen(soc_awlen), .m_ddr_axi_awsize(soc_awsize),
        .m_ddr_axi_awburst(soc_awburst), .m_ddr_axi_awlock(soc_awlock),
        .m_ddr_axi_awcache(soc_awcache), .m_ddr_axi_awprot(soc_awprot),
        .m_ddr_axi_awqos(soc_awqos), .m_ddr_axi_awregion(soc_awregion),
        .m_ddr_axi_awvalid(soc_awvalid), .m_ddr_axi_awready(soc_awready),
        .m_ddr_axi_wdata(soc_wdata), .m_ddr_axi_wstrb(soc_wstrb),
        .m_ddr_axi_wlast(soc_wlast), .m_ddr_axi_wvalid(soc_wvalid),
        .m_ddr_axi_wready(soc_wready), .m_ddr_axi_bid(soc_bid),
        .m_ddr_axi_bresp(soc_bresp), .m_ddr_axi_bvalid(soc_bvalid),
        .m_ddr_axi_bready(soc_bready), .m_ddr_axi_arid(soc_arid),
        .m_ddr_axi_araddr(soc_araddr), .m_ddr_axi_arlen(soc_arlen),
        .m_ddr_axi_arsize(soc_arsize), .m_ddr_axi_arburst(soc_arburst),
        .m_ddr_axi_arlock(soc_arlock), .m_ddr_axi_arcache(soc_arcache),
        .m_ddr_axi_arprot(soc_arprot), .m_ddr_axi_arqos(soc_arqos),
        .m_ddr_axi_arregion(soc_arregion), .m_ddr_axi_arvalid(soc_arvalid),
        .m_ddr_axi_arready(soc_arready), .m_ddr_axi_rid(soc_rid),
        .m_ddr_axi_rdata(soc_rdata), .m_ddr_axi_rresp(soc_rresp),
        .m_ddr_axi_rlast(soc_rlast), .m_ddr_axi_rvalid(soc_rvalid),
        .m_ddr_axi_rready(soc_rready),
        .external_ddr_calib_done_i(calib_sync[1]),
        .external_ddr_calib_error_i(1'b0),
        .external_ddr_ui_reset_i(ui_reset_sync[1])
    );

    // CDC output remains 32-bit AXI in the 200-MHz MIG UI domain.
    wire [AXI_ID_WIDTH-1:0] ui32_awid, ui32_bid, ui32_arid, ui32_rid;
    wire [31:0] ui32_awaddr, ui32_araddr;
    wire [7:0] ui32_awlen, ui32_arlen;
    wire [2:0] ui32_awsize, ui32_arsize;
    wire [1:0] ui32_awburst, ui32_arburst;
    wire [0:0] ui32_awlock, ui32_arlock;
    wire [3:0] ui32_awcache, ui32_arcache;
    wire [2:0] ui32_awprot, ui32_arprot;
    wire [3:0] ui32_awqos, ui32_arqos, ui32_awregion, ui32_arregion;
    wire ui32_awvalid, ui32_awready;
    wire [31:0] ui32_wdata;
    wire [3:0] ui32_wstrb;
    wire ui32_wlast, ui32_wvalid, ui32_wready;
    wire [1:0] ui32_bresp;
    wire ui32_bvalid, ui32_bready;
    wire ui32_arvalid, ui32_arready;
    wire [31:0] ui32_rdata;
    wire [1:0] ui32_rresp;
    wire ui32_rlast, ui32_rvalid, ui32_rready;

    soc_ddr_clock_converter ddr_clock_converter_inst (
        .s_axi_aclk(clk_150mhz), .s_axi_aresetn(soc_rst_ni),
        .s_axi_awid(soc_awid), .s_axi_awaddr(soc_awaddr),
        .s_axi_awlen(soc_awlen), .s_axi_awsize(soc_awsize),
        .s_axi_awburst(soc_awburst), .s_axi_awlock(soc_awlock),
        .s_axi_awcache(soc_awcache), .s_axi_awprot(soc_awprot),
        .s_axi_awregion(soc_awregion), .s_axi_awqos(soc_awqos),
        .s_axi_awvalid(soc_awvalid), .s_axi_awready(soc_awready),
        .s_axi_wdata(soc_wdata), .s_axi_wstrb(soc_wstrb),
        .s_axi_wlast(soc_wlast), .s_axi_wvalid(soc_wvalid),
        .s_axi_wready(soc_wready), .s_axi_bid(soc_bid),
        .s_axi_bresp(soc_bresp), .s_axi_bvalid(soc_bvalid),
        .s_axi_bready(soc_bready), .s_axi_arid(soc_arid),
        .s_axi_araddr(soc_araddr), .s_axi_arlen(soc_arlen),
        .s_axi_arsize(soc_arsize), .s_axi_arburst(soc_arburst),
        .s_axi_arlock(soc_arlock), .s_axi_arcache(soc_arcache),
        .s_axi_arprot(soc_arprot), .s_axi_arregion(soc_arregion),
        .s_axi_arqos(soc_arqos), .s_axi_arvalid(soc_arvalid),
        .s_axi_arready(soc_arready), .s_axi_rid(soc_rid),
        .s_axi_rdata(soc_rdata), .s_axi_rresp(soc_rresp),
        .s_axi_rlast(soc_rlast), .s_axi_rvalid(soc_rvalid),
        .s_axi_rready(soc_rready),
        .m_axi_aclk(ui_clk), .m_axi_aresetn(mig_aresetn),
        .m_axi_awid(ui32_awid), .m_axi_awaddr(ui32_awaddr),
        .m_axi_awlen(ui32_awlen), .m_axi_awsize(ui32_awsize),
        .m_axi_awburst(ui32_awburst), .m_axi_awlock(ui32_awlock),
        .m_axi_awcache(ui32_awcache), .m_axi_awprot(ui32_awprot),
        .m_axi_awregion(ui32_awregion), .m_axi_awqos(ui32_awqos),
        .m_axi_awvalid(ui32_awvalid), .m_axi_awready(ui32_awready),
        .m_axi_wdata(ui32_wdata), .m_axi_wstrb(ui32_wstrb),
        .m_axi_wlast(ui32_wlast), .m_axi_wvalid(ui32_wvalid),
        .m_axi_wready(ui32_wready), .m_axi_bid(ui32_bid),
        .m_axi_bresp(ui32_bresp), .m_axi_bvalid(ui32_bvalid),
        .m_axi_bready(ui32_bready), .m_axi_arid(ui32_arid),
        .m_axi_araddr(ui32_araddr), .m_axi_arlen(ui32_arlen),
        .m_axi_arsize(ui32_arsize), .m_axi_arburst(ui32_arburst),
        .m_axi_arlock(ui32_arlock), .m_axi_arcache(ui32_arcache),
        .m_axi_arprot(ui32_arprot), .m_axi_arregion(ui32_arregion),
        .m_axi_arqos(ui32_arqos), .m_axi_arvalid(ui32_arvalid),
        .m_axi_arready(ui32_arready), .m_axi_rid(ui32_rid),
        .m_axi_rdata(ui32_rdata), .m_axi_rresp(ui32_rresp),
        .m_axi_rlast(ui32_rlast), .m_axi_rvalid(ui32_rvalid),
        .m_axi_rready(ui32_rready)
    );

    // 512-bit AXI signals used by MIG.
    wire [31:0] mig_awaddr, mig_araddr;
    wire [7:0] mig_awlen, mig_arlen;
    wire [2:0] mig_awsize, mig_arsize;
    wire [1:0] mig_awburst, mig_arburst;
    wire [0:0] mig_awlock, mig_arlock;
    wire [3:0] mig_awcache, mig_arcache;
    wire [2:0] mig_awprot, mig_arprot;
    wire [3:0] mig_awqos, mig_arqos, mig_awregion, mig_arregion;
    wire mig_awvalid, mig_awready;
    wire [511:0] mig_wdata, mig_rdata;
    wire [63:0] mig_wstrb;
    wire mig_wlast, mig_wvalid, mig_wready;
    wire [1:0] mig_bresp, mig_rresp;
    wire mig_bvalid, mig_bready;
    wire mig_arvalid, mig_arready;
    wire mig_rlast, mig_rvalid, mig_rready;

    soc_ddr_axi_converter ddr_width_converter_inst (
        .s_axi_aclk(ui_clk), .s_axi_aresetn(mig_aresetn),
        .s_axi_awid(ui32_awid), .s_axi_awaddr(ui32_awaddr),
        .s_axi_awlen(ui32_awlen), .s_axi_awsize(ui32_awsize),
        .s_axi_awburst(ui32_awburst), .s_axi_awlock(ui32_awlock),
        .s_axi_awcache(ui32_awcache), .s_axi_awprot(ui32_awprot),
        .s_axi_awregion(ui32_awregion), .s_axi_awqos(ui32_awqos),
        .s_axi_awvalid(ui32_awvalid), .s_axi_awready(ui32_awready),
        .s_axi_wdata(ui32_wdata), .s_axi_wstrb(ui32_wstrb),
        .s_axi_wlast(ui32_wlast), .s_axi_wvalid(ui32_wvalid),
        .s_axi_wready(ui32_wready), .s_axi_bid(ui32_bid),
        .s_axi_bresp(ui32_bresp), .s_axi_bvalid(ui32_bvalid),
        .s_axi_bready(ui32_bready), .s_axi_arid(ui32_arid),
        .s_axi_araddr(ui32_araddr), .s_axi_arlen(ui32_arlen),
        .s_axi_arsize(ui32_arsize), .s_axi_arburst(ui32_arburst),
        .s_axi_arlock(ui32_arlock), .s_axi_arcache(ui32_arcache),
        .s_axi_arprot(ui32_arprot), .s_axi_arregion(ui32_arregion),
        .s_axi_arqos(ui32_arqos), .s_axi_arvalid(ui32_arvalid),
        .s_axi_arready(ui32_arready), .s_axi_rid(ui32_rid),
        .s_axi_rdata(ui32_rdata), .s_axi_rresp(ui32_rresp),
        .s_axi_rlast(ui32_rlast), .s_axi_rvalid(ui32_rvalid),
        .s_axi_rready(ui32_rready),
        .m_axi_awaddr(mig_awaddr), .m_axi_awlen(mig_awlen),
        .m_axi_awsize(mig_awsize), .m_axi_awburst(mig_awburst),
        .m_axi_awlock(mig_awlock), .m_axi_awcache(mig_awcache),
        .m_axi_awprot(mig_awprot), .m_axi_awregion(mig_awregion),
        .m_axi_awqos(mig_awqos), .m_axi_awvalid(mig_awvalid),
        .m_axi_awready(mig_awready), .m_axi_wdata(mig_wdata),
        .m_axi_wstrb(mig_wstrb), .m_axi_wlast(mig_wlast),
        .m_axi_wvalid(mig_wvalid), .m_axi_wready(mig_wready),
        .m_axi_bresp(mig_bresp), .m_axi_bvalid(mig_bvalid),
        .m_axi_bready(mig_bready), .m_axi_araddr(mig_araddr),
        .m_axi_arlen(mig_arlen), .m_axi_arsize(mig_arsize),
        .m_axi_arburst(mig_arburst), .m_axi_arlock(mig_arlock),
        .m_axi_arcache(mig_arcache), .m_axi_arprot(mig_arprot),
        .m_axi_arregion(mig_arregion), .m_axi_arqos(mig_arqos),
        .m_axi_arvalid(mig_arvalid), .m_axi_arready(mig_arready),
        .m_axi_rdata(mig_rdata), .m_axi_rresp(mig_rresp),
        .m_axi_rlast(mig_rlast), .m_axi_rvalid(mig_rvalid),
        .m_axi_rready(mig_rready)
    );

    vc707_mig mig_inst (
        .ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_ck_p(ddr3_ck_p), .ddr3_cke(ddr3_cke),
        .ddr3_ras_n(ddr3_ras_n), .ddr3_reset_n(ddr3_reset_n),
        .ddr3_we_n(ddr3_we_n), .ddr3_dq(ddr3_dq),
        .ddr3_dqs_n(ddr3_dqs_n), .ddr3_dqs_p(ddr3_dqs_p),
        .init_calib_complete(init_calib_complete),
        .ddr3_cs_n(ddr3_cs_n), .ddr3_dm(ddr3_dm), .ddr3_odt(ddr3_odt),
        .ui_clk(ui_clk), .ui_clk_sync_rst(ui_clk_sync_rst),
        .ui_addn_clk_0(), .ui_addn_clk_1(), .ui_addn_clk_2(),
        .ui_addn_clk_3(), .ui_addn_clk_4(), .mmcm_locked(mig_mmcm_locked),
        .aresetn(mig_aresetn), .app_sr_req(1'b0), .app_ref_req(1'b0),
        .app_zq_req(1'b0), .app_sr_active(), .app_ref_ack(), .app_zq_ack(),
        .s_axi_awid(6'd0), .s_axi_awaddr(mig_awaddr),
        .s_axi_awlen(mig_awlen), .s_axi_awsize(mig_awsize),
        .s_axi_awburst(mig_awburst), .s_axi_awlock(mig_awlock),
        .s_axi_awcache(mig_awcache), .s_axi_awprot(mig_awprot),
        .s_axi_awqos(mig_awqos), .s_axi_awvalid(mig_awvalid),
        .s_axi_awready(mig_awready), .s_axi_wdata(mig_wdata),
        .s_axi_wstrb(mig_wstrb), .s_axi_wlast(mig_wlast),
        .s_axi_wvalid(mig_wvalid), .s_axi_wready(mig_wready),
        .s_axi_bid(), .s_axi_bresp(mig_bresp), .s_axi_bvalid(mig_bvalid),
        .s_axi_bready(mig_bready), .s_axi_arid(6'd0),
        .s_axi_araddr(mig_araddr), .s_axi_arlen(mig_arlen),
        .s_axi_arsize(mig_arsize), .s_axi_arburst(mig_arburst),
        .s_axi_arlock(mig_arlock), .s_axi_arcache(mig_arcache),
        .s_axi_arprot(mig_arprot), .s_axi_arqos(mig_arqos),
        .s_axi_arvalid(mig_arvalid), .s_axi_arready(mig_arready),
        .s_axi_rid(), .s_axi_rdata(mig_rdata), .s_axi_rresp(mig_rresp),
        .s_axi_rlast(mig_rlast), .s_axi_rvalid(mig_rvalid),
        .s_axi_rready(mig_rready), .sys_clk_p(sys_clk_p),
        .sys_clk_n(sys_clk_n), .sys_rst(cpu_reset)
    );

    assign led_o[0] = init_calib_complete;
    assign led_o[1] = cpu_trap;
    assign led_o[2] = dma_irq;
    assign led_o[3] = soc_mmcm_locked & mig_mmcm_locked;

endmodule
