`timescale 1ns / 1ps

// Two-target memory subsystem: the existing boot AXI RAM remains at address
// zero while the project-owned DDR3 controller occupies DDR_BASE_ADDR.
module axi_bram_ddr3_subsystem #(
    parameter int AXI_ADDR_WIDTH = 32,
    parameter int AXI_DATA_WIDTH = 32,
    parameter int AXI_ID_WIDTH = 6,
    parameter int BRAM_ADDR_WIDTH = 16,
    parameter BOOT_INIT_FILE = "",
    // Select the board-level MIG AXI port instead of the project-owned
    // controller/DFI-lite path.  The default keeps all existing simulations
    // and non-MIG integrations source-compatible.
    parameter bit USE_EXTERNAL_DDR_AXI = 1'b0,
    parameter logic [AXI_ADDR_WIDTH-1:0] DDR_BASE_ADDR = 32'h8000_0000,
    parameter logic [AXI_ADDR_WIDTH-1:0] DDR_SIZE_BYTES = 32'h4000_0000,
    parameter int DDR_ROW_WIDTH = 16,
    parameter int DDR_COL_WIDTH = 10,
    parameter int DDR_BANK_WIDTH = 3
) (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  logic [AXI_ID_WIDTH-1:0]      s_axi_awid,
    input  logic [AXI_ADDR_WIDTH-1:0]    s_axi_awaddr,
    input  logic [7:0]                   s_axi_awlen,
    input  logic [2:0]                   s_axi_awsize,
    input  logic [1:0]                   s_axi_awburst,
    input  logic                         s_axi_awlock,
    input  logic [3:0]                   s_axi_awcache,
    input  logic [2:0]                   s_axi_awprot,
    input  logic [3:0]                   s_axi_awqos,
    input  logic [3:0]                   s_axi_awregion,
    input  logic                         s_axi_awvalid,
    output logic                         s_axi_awready,
    input  logic [AXI_DATA_WIDTH-1:0]    s_axi_wdata,
    input  logic [AXI_DATA_WIDTH/8-1:0]  s_axi_wstrb,
    input  logic                         s_axi_wlast,
    input  logic                         s_axi_wvalid,
    output logic                         s_axi_wready,
    output logic [AXI_ID_WIDTH-1:0]      s_axi_bid,
    output logic [1:0]                   s_axi_bresp,
    output logic                         s_axi_bvalid,
    input  logic                         s_axi_bready,
    input  logic [AXI_ID_WIDTH-1:0]      s_axi_arid,
    input  logic [AXI_ADDR_WIDTH-1:0]    s_axi_araddr,
    input  logic [7:0]                   s_axi_arlen,
    input  logic [2:0]                   s_axi_arsize,
    input  logic [1:0]                   s_axi_arburst,
    input  logic                         s_axi_arlock,
    input  logic [3:0]                   s_axi_arcache,
    input  logic [2:0]                   s_axi_arprot,
    input  logic [3:0]                   s_axi_arqos,
    input  logic [3:0]                   s_axi_arregion,
    input  logic                         s_axi_arvalid,
    output logic                         s_axi_arready,
    output logic [AXI_ID_WIDTH-1:0]      s_axi_rid,
    output logic [AXI_DATA_WIDTH-1:0]    s_axi_rdata,
    output logic [1:0]                   s_axi_rresp,
    output logic                         s_axi_rlast,
    output logic                         s_axi_rvalid,
    input  logic                         s_axi_rready,

    output logic                         ddr_init_done_o,
    output logic                         ddr_calib_done_o,
    output logic                         ddr_calib_error_o,
    output logic                         ddr_refresh_busy_o,
    output logic [31:0]                  ddr_refresh_count_o,
    output logic                         dfi_cmd_valid_o,
    input  logic                         dfi_cmd_ready_i,
    output logic [2:0]                   dfi_cmd_o,
    output logic [DDR_BANK_WIDTH-1:0]    dfi_bank_o,
    output logic [DDR_ROW_WIDTH-1:0]     dfi_addr_o,
    output logic [AXI_DATA_WIDTH-1:0]    dfi_wrdata_o,
    output logic [AXI_DATA_WIDTH/8-1:0]  dfi_wrmask_o,
    input  logic                         dfi_rddata_valid_i,
    input  logic [AXI_DATA_WIDTH-1:0]    dfi_rddata_i,
    input  logic                         dfi_error_i,
    output logic                         phy_calib_start_o,
    input  logic                         phy_calib_done_i,
    input  logic                         phy_calib_error_i,

    // 32-bit AXI4 master exported to a vendor DDR PHY/controller such as MIG.
    // Addresses are rebased to zero at DDR_BASE_ADDR.
    output logic [AXI_ID_WIDTH-1:0]      m_ddr_axi_awid,
    output logic [AXI_ADDR_WIDTH-1:0]    m_ddr_axi_awaddr,
    output logic [7:0]                   m_ddr_axi_awlen,
    output logic [2:0]                   m_ddr_axi_awsize,
    output logic [1:0]                   m_ddr_axi_awburst,
    output logic                         m_ddr_axi_awlock,
    output logic [3:0]                   m_ddr_axi_awcache,
    output logic [2:0]                   m_ddr_axi_awprot,
    output logic [3:0]                   m_ddr_axi_awqos,
    output logic [3:0]                   m_ddr_axi_awregion,
    output logic                         m_ddr_axi_awvalid,
    input  logic                         m_ddr_axi_awready,
    output logic [AXI_DATA_WIDTH-1:0]    m_ddr_axi_wdata,
    output logic [AXI_DATA_WIDTH/8-1:0]  m_ddr_axi_wstrb,
    output logic                         m_ddr_axi_wlast,
    output logic                         m_ddr_axi_wvalid,
    input  logic                         m_ddr_axi_wready,
    input  logic [AXI_ID_WIDTH-1:0]      m_ddr_axi_bid,
    input  logic [1:0]                   m_ddr_axi_bresp,
    input  logic                         m_ddr_axi_bvalid,
    output logic                         m_ddr_axi_bready,
    output logic [AXI_ID_WIDTH-1:0]      m_ddr_axi_arid,
    output logic [AXI_ADDR_WIDTH-1:0]    m_ddr_axi_araddr,
    output logic [7:0]                   m_ddr_axi_arlen,
    output logic [2:0]                   m_ddr_axi_arsize,
    output logic [1:0]                   m_ddr_axi_arburst,
    output logic                         m_ddr_axi_arlock,
    output logic [3:0]                   m_ddr_axi_arcache,
    output logic [2:0]                   m_ddr_axi_arprot,
    output logic [3:0]                   m_ddr_axi_arqos,
    output logic [3:0]                   m_ddr_axi_arregion,
    output logic                         m_ddr_axi_arvalid,
    input  logic                         m_ddr_axi_arready,
    input  logic [AXI_ID_WIDTH-1:0]      m_ddr_axi_rid,
    input  logic [AXI_DATA_WIDTH-1:0]    m_ddr_axi_rdata,
    input  logic [1:0]                   m_ddr_axi_rresp,
    input  logic                         m_ddr_axi_rlast,
    input  logic                         m_ddr_axi_rvalid,
    output logic                         m_ddr_axi_rready,
    input  logic                         external_ddr_calib_done_i,
    input  logic                         external_ddr_calib_error_i
);

    localparam int M_COUNT = 2;
    localparam int STRB_WIDTH = AXI_DATA_WIDTH/8;

    initial begin
        if (AXI_ADDR_WIDTH != 32)
            $error("BRAM+DDR subsystem requires a 32-bit address bus");
        if (BRAM_ADDR_WIDTH > AXI_ADDR_WIDTH)
            $error("BRAM_ADDR_WIDTH cannot exceed AXI_ADDR_WIDTH");
    end

    wire [M_COUNT*AXI_ID_WIDTH-1:0] m_awid;
    wire [M_COUNT*AXI_ADDR_WIDTH-1:0] m_awaddr;
    wire [M_COUNT*8-1:0] m_awlen;
    wire [M_COUNT*3-1:0] m_awsize;
    wire [M_COUNT*2-1:0] m_awburst;
    wire [M_COUNT-1:0] m_awlock;
    wire [M_COUNT*4-1:0] m_awcache;
    wire [M_COUNT*3-1:0] m_awprot;
    wire [M_COUNT*4-1:0] m_awqos;
    wire [M_COUNT*4-1:0] m_awregion;
    wire [M_COUNT-1:0] m_awvalid;
    logic [M_COUNT-1:0] m_awready;
    wire [M_COUNT*AXI_DATA_WIDTH-1:0] m_wdata;
    wire [M_COUNT*STRB_WIDTH-1:0] m_wstrb;
    wire [M_COUNT-1:0] m_wlast;
    wire [M_COUNT-1:0] m_wvalid;
    logic [M_COUNT-1:0] m_wready;
    logic [M_COUNT*AXI_ID_WIDTH-1:0] m_bid;
    logic [M_COUNT*2-1:0] m_bresp;
    logic [M_COUNT-1:0] m_bvalid;
    wire [M_COUNT-1:0] m_bready;
    wire [M_COUNT*AXI_ID_WIDTH-1:0] m_arid;
    wire [M_COUNT*AXI_ADDR_WIDTH-1:0] m_araddr;
    wire [M_COUNT*8-1:0] m_arlen;
    wire [M_COUNT*3-1:0] m_arsize;
    wire [M_COUNT*2-1:0] m_arburst;
    wire [M_COUNT-1:0] m_arlock;
    wire [M_COUNT*4-1:0] m_arcache;
    wire [M_COUNT*3-1:0] m_arprot;
    wire [M_COUNT*4-1:0] m_arqos;
    wire [M_COUNT*4-1:0] m_arregion;
    wire [M_COUNT-1:0] m_arvalid;
    logic [M_COUNT-1:0] m_arready;
    logic [M_COUNT*AXI_ID_WIDTH-1:0] m_rid;
    logic [M_COUNT*AXI_DATA_WIDTH-1:0] m_rdata;
    logic [M_COUNT*2-1:0] m_rresp;
    logic [M_COUNT-1:0] m_rlast;
    logic [M_COUNT-1:0] m_rvalid;
    wire [M_COUNT-1:0] m_rready;

    axi_crossbar #(
        .S_COUNT(1), .M_COUNT(M_COUNT),
        .DATA_WIDTH(AXI_DATA_WIDTH), .ADDR_WIDTH(AXI_ADDR_WIDTH),
        .STRB_WIDTH(STRB_WIDTH),
        .S_ID_WIDTH(AXI_ID_WIDTH), .M_ID_WIDTH(AXI_ID_WIDTH),
        .S_THREADS(32'd2), .S_ACCEPT(32'd4),
        .M_REGIONS(1), .M_ISSUE({M_COUNT{32'd4}}),
        .M_BASE_ADDR({DDR_BASE_ADDR, {AXI_ADDR_WIDTH{1'b0}}}),
        .M_ADDR_WIDTH({32'd30, BRAM_ADDR_WIDTH}),
        .M_CONNECT_READ(2'b11), .M_CONNECT_WRITE(2'b11)
    ) memory_decode_inst (
        .clk(clk_i), .rst(rst_i),
        .s_axi_awid(s_axi_awid), .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awlen(s_axi_awlen), .s_axi_awsize(s_axi_awsize),
        .s_axi_awburst(s_axi_awburst), .s_axi_awlock(s_axi_awlock),
        .s_axi_awcache(s_axi_awcache), .s_axi_awprot(s_axi_awprot),
        .s_axi_awqos(s_axi_awqos), .s_axi_awuser(1'b0),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wlast(s_axi_wlast), .s_axi_wuser(1'b0),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bid(s_axi_bid), .s_axi_bresp(s_axi_bresp), .s_axi_buser(),
        .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_arid(s_axi_arid), .s_axi_araddr(s_axi_araddr),
        .s_axi_arlen(s_axi_arlen), .s_axi_arsize(s_axi_arsize),
        .s_axi_arburst(s_axi_arburst), .s_axi_arlock(s_axi_arlock),
        .s_axi_arcache(s_axi_arcache), .s_axi_arprot(s_axi_arprot),
        .s_axi_arqos(s_axi_arqos), .s_axi_aruser(1'b0),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rid(s_axi_rid), .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp), .s_axi_rlast(s_axi_rlast),
        .s_axi_ruser(), .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr),
        .m_axi_awlen(m_awlen), .m_axi_awsize(m_awsize),
        .m_axi_awburst(m_awburst), .m_axi_awlock(m_awlock),
        .m_axi_awcache(m_awcache), .m_axi_awprot(m_awprot),
        .m_axi_awqos(m_awqos), .m_axi_awregion(m_awregion),
        .m_axi_awuser(), .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb),
        .m_axi_wlast(m_wlast), .m_axi_wuser(),
        .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bid(m_bid), .m_axi_bresp(m_bresp),
        .m_axi_buser(2'b00), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_arid(m_arid), .m_axi_araddr(m_araddr),
        .m_axi_arlen(m_arlen), .m_axi_arsize(m_arsize),
        .m_axi_arburst(m_arburst), .m_axi_arlock(m_arlock),
        .m_axi_arcache(m_arcache), .m_axi_arprot(m_arprot),
        .m_axi_arqos(m_arqos), .m_axi_arregion(m_arregion),
        .m_axi_aruser(), .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rid(m_rid), .m_axi_rdata(m_rdata),
        .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
        .m_axi_ruser(2'b00), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready)
    );

    axi_ram #(
        .DATA_WIDTH(AXI_DATA_WIDTH), .ADDR_WIDTH(BRAM_ADDR_WIDTH),
        .STRB_WIDTH(STRB_WIDTH), .ID_WIDTH(AXI_ID_WIDTH),
        .PIPELINE_OUTPUT(1), .INIT_FILE(BOOT_INIT_FILE)
    ) boot_ram_inst (
        .clk(clk_i), .rst(rst_i),
        .s_axi_awid(m_awid[0 +: AXI_ID_WIDTH]),
        .s_axi_awaddr(m_awaddr[0 +: BRAM_ADDR_WIDTH]),
        .s_axi_awlen(m_awlen[0 +: 8]), .s_axi_awsize(m_awsize[0 +: 3]),
        .s_axi_awburst(m_awburst[0 +: 2]), .s_axi_awlock(m_awlock[0]),
        .s_axi_awcache(m_awcache[0 +: 4]), .s_axi_awprot(m_awprot[0 +: 3]),
        .s_axi_awvalid(m_awvalid[0]), .s_axi_awready(m_awready[0]),
        .s_axi_wdata(m_wdata[0 +: AXI_DATA_WIDTH]),
        .s_axi_wstrb(m_wstrb[0 +: STRB_WIDTH]),
        .s_axi_wlast(m_wlast[0]), .s_axi_wvalid(m_wvalid[0]),
        .s_axi_wready(m_wready[0]), .s_axi_bid(m_bid[0 +: AXI_ID_WIDTH]),
        .s_axi_bresp(m_bresp[0 +: 2]), .s_axi_bvalid(m_bvalid[0]),
        .s_axi_bready(m_bready[0]),
        .s_axi_arid(m_arid[0 +: AXI_ID_WIDTH]),
        .s_axi_araddr(m_araddr[0 +: BRAM_ADDR_WIDTH]),
        .s_axi_arlen(m_arlen[0 +: 8]), .s_axi_arsize(m_arsize[0 +: 3]),
        .s_axi_arburst(m_arburst[0 +: 2]), .s_axi_arlock(m_arlock[0]),
        .s_axi_arcache(m_arcache[0 +: 4]), .s_axi_arprot(m_arprot[0 +: 3]),
        .s_axi_arvalid(m_arvalid[0]), .s_axi_arready(m_arready[0]),
        .s_axi_rid(m_rid[0 +: AXI_ID_WIDTH]),
        .s_axi_rdata(m_rdata[0 +: AXI_DATA_WIDTH]),
        .s_axi_rresp(m_rresp[0 +: 2]), .s_axi_rlast(m_rlast[0]),
        .s_axi_rvalid(m_rvalid[0]), .s_axi_rready(m_rready[0])
    );

    generate
        if (USE_EXTERNAL_DDR_AXI) begin : g_external_ddr
            always_comb begin
                m_ddr_axi_awid     = m_awid[AXI_ID_WIDTH +: AXI_ID_WIDTH];
                m_ddr_axi_awaddr   = m_awaddr[AXI_ADDR_WIDTH +: AXI_ADDR_WIDTH]
                                   - DDR_BASE_ADDR;
                m_ddr_axi_awlen    = m_awlen[8 +: 8];
                m_ddr_axi_awsize   = m_awsize[3 +: 3];
                m_ddr_axi_awburst  = m_awburst[2 +: 2];
                m_ddr_axi_awlock   = m_awlock[1];
                m_ddr_axi_awcache  = m_awcache[4 +: 4];
                m_ddr_axi_awprot   = m_awprot[3 +: 3];
                m_ddr_axi_awqos    = m_awqos[4 +: 4];
                m_ddr_axi_awregion = m_awregion[4 +: 4];
                m_ddr_axi_awvalid  = m_awvalid[1];
                m_awready[1]       = m_ddr_axi_awready;
                m_ddr_axi_wdata    = m_wdata[AXI_DATA_WIDTH +: AXI_DATA_WIDTH];
                m_ddr_axi_wstrb    = m_wstrb[STRB_WIDTH +: STRB_WIDTH];
                m_ddr_axi_wlast    = m_wlast[1];
                m_ddr_axi_wvalid   = m_wvalid[1];
                m_wready[1]        = m_ddr_axi_wready;
                m_bid[AXI_ID_WIDTH +: AXI_ID_WIDTH] = m_ddr_axi_bid;
                m_bresp[2 +: 2]    = m_ddr_axi_bresp;
                m_bvalid[1]        = m_ddr_axi_bvalid;
                m_ddr_axi_bready   = m_bready[1];
                m_ddr_axi_arid     = m_arid[AXI_ID_WIDTH +: AXI_ID_WIDTH];
                m_ddr_axi_araddr   = m_araddr[AXI_ADDR_WIDTH +: AXI_ADDR_WIDTH]
                                   - DDR_BASE_ADDR;
                m_ddr_axi_arlen    = m_arlen[8 +: 8];
                m_ddr_axi_arsize   = m_arsize[3 +: 3];
                m_ddr_axi_arburst  = m_arburst[2 +: 2];
                m_ddr_axi_arlock   = m_arlock[1];
                m_ddr_axi_arcache  = m_arcache[4 +: 4];
                m_ddr_axi_arprot   = m_arprot[3 +: 3];
                m_ddr_axi_arqos    = m_arqos[4 +: 4];
                m_ddr_axi_arregion = m_arregion[4 +: 4];
                m_ddr_axi_arvalid  = m_arvalid[1];
                m_arready[1]       = m_ddr_axi_arready;
                m_rid[AXI_ID_WIDTH +: AXI_ID_WIDTH] = m_ddr_axi_rid;
                m_rdata[AXI_DATA_WIDTH +: AXI_DATA_WIDTH] = m_ddr_axi_rdata;
                m_rresp[2 +: 2]    = m_ddr_axi_rresp;
                m_rlast[1]         = m_ddr_axi_rlast;
                m_rvalid[1]        = m_ddr_axi_rvalid;
                m_ddr_axi_rready   = m_rready[1];

                ddr_init_done_o     = external_ddr_calib_done_i;
                ddr_calib_done_o    = external_ddr_calib_done_i;
                ddr_calib_error_o   = external_ddr_calib_error_i;
                ddr_refresh_busy_o  = 1'b0;
                ddr_refresh_count_o = '0;
                dfi_cmd_valid_o     = 1'b0;
                dfi_cmd_o           = '0;
                dfi_bank_o          = '0;
                dfi_addr_o          = '0;
                dfi_wrdata_o        = '0;
                dfi_wrmask_o        = '1;
                phy_calib_start_o   = 1'b0;
            end
        end else begin : g_internal_ddr
            axi_ddr3_controller #(
                .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH), .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
                .AXI_ID_WIDTH(AXI_ID_WIDTH), .DDR_BASE_ADDR(DDR_BASE_ADDR),
                .DDR_SIZE_BYTES(DDR_SIZE_BYTES), .ROW_WIDTH(DDR_ROW_WIDTH),
                .COL_WIDTH(DDR_COL_WIDTH), .BANK_WIDTH(DDR_BANK_WIDTH)
            ) ddr_controller_inst (
                .aclk(clk_i), .aresetn(!rst_i),
                .s_axi_awid(m_awid[AXI_ID_WIDTH +: AXI_ID_WIDTH]),
                .s_axi_awaddr(m_awaddr[AXI_ADDR_WIDTH +: AXI_ADDR_WIDTH]),
                .s_axi_awlen(m_awlen[8 +: 8]), .s_axi_awsize(m_awsize[3 +: 3]),
                .s_axi_awburst(m_awburst[2 +: 2]), .s_axi_awlock(m_awlock[1]),
                .s_axi_awcache(m_awcache[4 +: 4]), .s_axi_awprot(m_awprot[3 +: 3]),
                .s_axi_awqos(m_awqos[4 +: 4]),
                .s_axi_awvalid(m_awvalid[1]), .s_axi_awready(m_awready[1]),
                .s_axi_wdata(m_wdata[AXI_DATA_WIDTH +: AXI_DATA_WIDTH]),
                .s_axi_wstrb(m_wstrb[STRB_WIDTH +: STRB_WIDTH]),
                .s_axi_wlast(m_wlast[1]), .s_axi_wvalid(m_wvalid[1]),
                .s_axi_wready(m_wready[1]),
                .s_axi_bid(m_bid[AXI_ID_WIDTH +: AXI_ID_WIDTH]),
                .s_axi_bresp(m_bresp[2 +: 2]), .s_axi_bvalid(m_bvalid[1]),
                .s_axi_bready(m_bready[1]),
                .s_axi_arid(m_arid[AXI_ID_WIDTH +: AXI_ID_WIDTH]),
                .s_axi_araddr(m_araddr[AXI_ADDR_WIDTH +: AXI_ADDR_WIDTH]),
                .s_axi_arlen(m_arlen[8 +: 8]), .s_axi_arsize(m_arsize[3 +: 3]),
                .s_axi_arburst(m_arburst[2 +: 2]), .s_axi_arlock(m_arlock[1]),
                .s_axi_arcache(m_arcache[4 +: 4]), .s_axi_arprot(m_arprot[3 +: 3]),
                .s_axi_arqos(m_arqos[4 +: 4]),
                .s_axi_arvalid(m_arvalid[1]), .s_axi_arready(m_arready[1]),
                .s_axi_rid(m_rid[AXI_ID_WIDTH +: AXI_ID_WIDTH]),
                .s_axi_rdata(m_rdata[AXI_DATA_WIDTH +: AXI_DATA_WIDTH]),
                .s_axi_rresp(m_rresp[2 +: 2]), .s_axi_rlast(m_rlast[1]),
                .s_axi_rvalid(m_rvalid[1]), .s_axi_rready(m_rready[1]),
                .init_done_o(ddr_init_done_o), .calib_done_o(ddr_calib_done_o),
                .calib_error_o(ddr_calib_error_o),
                .refresh_busy_o(ddr_refresh_busy_o),
                .refresh_count_o(ddr_refresh_count_o),
                .dfi_cmd_valid_o, .dfi_cmd_ready_i, .dfi_cmd_o, .dfi_bank_o,
                .dfi_addr_o, .dfi_wrdata_o, .dfi_wrmask_o,
                .dfi_rddata_valid_i, .dfi_rddata_i, .dfi_error_i,
                .phy_calib_start_o, .phy_calib_done_i, .phy_calib_error_i
            );

            always_comb begin
                m_ddr_axi_awid = '0;
                m_ddr_axi_awaddr = '0;
                m_ddr_axi_awlen = '0;
                m_ddr_axi_awsize = '0;
                m_ddr_axi_awburst = '0;
                m_ddr_axi_awlock = 1'b0;
                m_ddr_axi_awcache = '0;
                m_ddr_axi_awprot = '0;
                m_ddr_axi_awqos = '0;
                m_ddr_axi_awregion = '0;
                m_ddr_axi_awvalid = 1'b0;
                m_ddr_axi_wdata = '0;
                m_ddr_axi_wstrb = '0;
                m_ddr_axi_wlast = 1'b0;
                m_ddr_axi_wvalid = 1'b0;
                m_ddr_axi_bready = 1'b0;
                m_ddr_axi_arid = '0;
                m_ddr_axi_araddr = '0;
                m_ddr_axi_arlen = '0;
                m_ddr_axi_arsize = '0;
                m_ddr_axi_arburst = '0;
                m_ddr_axi_arlock = 1'b0;
                m_ddr_axi_arcache = '0;
                m_ddr_axi_arprot = '0;
                m_ddr_axi_arqos = '0;
                m_ddr_axi_arregion = '0;
                m_ddr_axi_arvalid = 1'b0;
                m_ddr_axi_rready = 1'b0;
            end
        end
    endgenerate

    logic _unused;
    assign _unused = &{1'b0, s_axi_awregion, s_axi_arregion,
                       m_awregion, m_arregion};

endmodule
