`timescale 1ns / 1ps

// One-master AXI4-Lite address decoder used by the PicoRV32 SoC.
//
// Address map:
//   0x0000_0000 - (2**RAM_ADDR_WIDTH)-1 : shared system RAM
//   0x1000_0000 - 0x1000_00FF : DMA/IOMMU control registers
//   0x2000_0000 - 0x2000_00FF : UART control/data registers
//   0x4000_0000 - 0x4000_00FF : 4x4 systolic accelerator registers
//   0x5000_0000 - 0x5000_00FF : read-only DDR controller status
//
// PicoRV32 issues one memory transaction at a time.  This router nevertheless
// buffers AW and W independently so it remains AXI4-Lite protocol compliant.
module picorv32_axil_router #(
    parameter int RAM_ADDR_WIDTH = 16,
    parameter int BRAM_ADDR_WIDTH = RAM_ADDR_WIDTH,
    parameter int PERIPH_ADDR_WIDTH = 8,
    parameter bit DDR_ENABLE = 1'b0,
    parameter logic [31:0] DDR_BASE_ADDR = 32'h8000_0000,
    parameter logic [31:0] DDR_SIZE_BYTES = 32'h4000_0000
) (
    input  logic clk_i,
    input  logic rst_ni,

    input  logic [31:0] s_axil_awaddr,
    input  logic [2:0]  s_axil_awprot,
    input  logic        s_axil_awvalid,
    output logic        s_axil_awready,
    input  logic [31:0] s_axil_wdata,
    input  logic [3:0]  s_axil_wstrb,
    input  logic        s_axil_wvalid,
    output logic        s_axil_wready,
    output logic [1:0]  s_axil_bresp,
    output logic        s_axil_bvalid,
    input  logic        s_axil_bready,
    input  logic [31:0] s_axil_araddr,
    input  logic [2:0]  s_axil_arprot,
    input  logic        s_axil_arvalid,
    output logic        s_axil_arready,
    output logic [31:0] s_axil_rdata,
    output logic [1:0]  s_axil_rresp,
    output logic        s_axil_rvalid,
    input  logic        s_axil_rready,

    // RAM-side AXI4-Lite master
    output logic [RAM_ADDR_WIDTH-1:0] m_ram_awaddr,
    output logic [2:0]                m_ram_awprot,
    output logic                      m_ram_awvalid,
    input  logic                      m_ram_awready,
    output logic [31:0]               m_ram_wdata,
    output logic [3:0]                m_ram_wstrb,
    output logic                      m_ram_wvalid,
    input  logic                      m_ram_wready,
    input  logic [1:0]                m_ram_bresp,
    input  logic                      m_ram_bvalid,
    output logic                      m_ram_bready,
    output logic [RAM_ADDR_WIDTH-1:0] m_ram_araddr,
    output logic [2:0]                m_ram_arprot,
    output logic                      m_ram_arvalid,
    input  logic                      m_ram_arready,
    input  logic [31:0]               m_ram_rdata,
    input  logic [1:0]                m_ram_rresp,
    input  logic                      m_ram_rvalid,
    output logic                      m_ram_rready,

    // DMA/IOMMU register-side AXI4-Lite master
    output logic [PERIPH_ADDR_WIDTH-1:0] m_dma_awaddr,
    output logic [2:0]                   m_dma_awprot,
    output logic                         m_dma_awvalid,
    input  logic                         m_dma_awready,
    output logic [31:0]                  m_dma_wdata,
    output logic [3:0]                   m_dma_wstrb,
    output logic                         m_dma_wvalid,
    input  logic                         m_dma_wready,
    input  logic [1:0]                   m_dma_bresp,
    input  logic                         m_dma_bvalid,
    output logic                         m_dma_bready,
    output logic [PERIPH_ADDR_WIDTH-1:0] m_dma_araddr,
    output logic [2:0]                   m_dma_arprot,
    output logic                         m_dma_arvalid,
    input  logic                         m_dma_arready,
    input  logic [31:0]                  m_dma_rdata,
    input  logic [1:0]                   m_dma_rresp,
    input  logic                         m_dma_rvalid,
    output logic                         m_dma_rready,

    // UART register-side AXI4-Lite master
    output logic [PERIPH_ADDR_WIDTH-1:0] m_uart_awaddr,
    output logic [2:0]                   m_uart_awprot,
    output logic                         m_uart_awvalid,
    input  logic                         m_uart_awready,
    output logic [31:0]                  m_uart_wdata,
    output logic [3:0]                   m_uart_wstrb,
    output logic                         m_uart_wvalid,
    input  logic                         m_uart_wready,
    input  logic [1:0]                   m_uart_bresp,
    input  logic                         m_uart_bvalid,
    output logic                         m_uart_bready,
    output logic [PERIPH_ADDR_WIDTH-1:0] m_uart_araddr,
    output logic [2:0]                   m_uart_arprot,
    output logic                         m_uart_arvalid,
    input  logic                         m_uart_arready,
    input  logic [31:0]                  m_uart_rdata,
    input  logic [1:0]                   m_uart_rresp,
    input  logic                         m_uart_rvalid,
    output logic                         m_uart_rready,

    // Systolic accelerator register-side AXI4-Lite master
    output logic [PERIPH_ADDR_WIDTH-1:0] m_systolic_awaddr,
    output logic [2:0]                   m_systolic_awprot,
    output logic                         m_systolic_awvalid,
    input  logic                         m_systolic_awready,
    output logic [31:0]                  m_systolic_wdata,
    output logic [3:0]                   m_systolic_wstrb,
    output logic                         m_systolic_wvalid,
    input  logic                         m_systolic_wready,
    input  logic [1:0]                   m_systolic_bresp,
    input  logic                         m_systolic_bvalid,
    output logic                         m_systolic_bready,
    output logic [PERIPH_ADDR_WIDTH-1:0] m_systolic_araddr,
    output logic [2:0]                   m_systolic_arprot,
    output logic                         m_systolic_arvalid,
    input  logic                         m_systolic_arready,
    input  logic [31:0]                  m_systolic_rdata,
    input  logic [1:0]                   m_systolic_rresp,
    input  logic                         m_systolic_rvalid,
    output logic                         m_systolic_rready,

    input  logic [31:0] ddr_status_i,
    output logic cpu_bus_idle_o
);

    typedef enum logic [2:0] {
        SEL_RAM, SEL_DMA, SEL_UART, SEL_SYSTOLIC, SEL_DDR_STATUS, SEL_DECERR
    } target_t;
    typedef enum logic [1:0] {W_COLLECT, W_SEND, W_RESPONSE} wstate_t;
    typedef enum logic [1:0] {R_IDLE, R_SEND, R_RESPONSE} rstate_t;

    wstate_t wstate_q;
    rstate_t rstate_q;
    target_t wtarget_q, rtarget_q;

    logic [31:0] awaddr_q, araddr_q;
    logic [2:0]  awprot_q, arprot_q;
    logic [31:0] wdata_q;
    logic [3:0]  wstrb_q;
    logic aw_hold_q, w_hold_q;
    logic aw_sent_q, w_sent_q;
    // Keep the CPU-facing read-ready path registered.  This is functionally
    // identical to decoding R_IDLE combinationally, but removes the read-FSM
    // decode from the PicoRV32 AXI-Lite handshake critical path.
    (* max_fanout = 8 *) logic s_arready_q;

    function automatic target_t decode_target(input logic [31:0] addr);
        // Decode the complete configured RAM aperture.  The previous fixed
        // 64-KiB check rejected the image/scratch buffers at 0x0001_0000 and
        // above when RAM_ADDR_WIDTH=18, even though the AXI RAM is 256 KiB.
        if (addr[31:8] == 24'h100000)
            decode_target = SEL_DMA;
        else if (addr[31:8] == 24'h200000)
            decode_target = SEL_UART;
        else if (addr[31:8] == 24'h400000)
            decode_target = SEL_SYSTOLIC;
        else if (DDR_ENABLE && addr[31:8] == 24'h500000)
            decode_target = SEL_DDR_STATUS;
        else if ({1'b0, addr} < (33'd1 << BRAM_ADDR_WIDTH))
            decode_target = SEL_RAM;
        else if (DDR_ENABLE && addr >= DDR_BASE_ADDR
                 && {1'b0, addr} < ({1'b0, DDR_BASE_ADDR}
                                    + {1'b0, DDR_SIZE_BYTES}))
            decode_target = SEL_RAM;
        else
            decode_target = SEL_DECERR;
    endfunction

    always_comb begin
        s_axil_awready = 1'b0;
        s_axil_wready  = 1'b0;
        s_axil_bresp   = 2'b00;
        s_axil_bvalid  = 1'b0;
        s_axil_arready = s_arready_q;
        s_axil_rdata   = 32'd0;
        s_axil_rresp   = 2'b00;
        s_axil_rvalid  = 1'b0;

        m_ram_awaddr = awaddr_q[RAM_ADDR_WIDTH-1:0];
        m_ram_awprot = awprot_q;
        m_ram_awvalid = 1'b0;
        m_ram_wdata = wdata_q;
        m_ram_wstrb = wstrb_q;
        m_ram_wvalid = 1'b0;
        m_ram_bready = 1'b0;
        m_ram_araddr = araddr_q[RAM_ADDR_WIDTH-1:0];
        m_ram_arprot = arprot_q;
        m_ram_arvalid = 1'b0;
        m_ram_rready = 1'b0;

        m_dma_awaddr = awaddr_q[PERIPH_ADDR_WIDTH-1:0];
        m_dma_awprot = awprot_q;
        m_dma_awvalid = 1'b0;
        m_dma_wdata = wdata_q;
        m_dma_wstrb = wstrb_q;
        m_dma_wvalid = 1'b0;
        m_dma_bready = 1'b0;
        m_dma_araddr = araddr_q[PERIPH_ADDR_WIDTH-1:0];
        m_dma_arprot = arprot_q;
        m_dma_arvalid = 1'b0;
        m_dma_rready = 1'b0;

        m_uart_awaddr = awaddr_q[PERIPH_ADDR_WIDTH-1:0];
        m_uart_awprot = awprot_q;
        m_uart_awvalid = 1'b0;
        m_uart_wdata = wdata_q;
        m_uart_wstrb = wstrb_q;
        m_uart_wvalid = 1'b0;
        m_uart_bready = 1'b0;
        m_uart_araddr = araddr_q[PERIPH_ADDR_WIDTH-1:0];
        m_uart_arprot = arprot_q;
        m_uart_arvalid = 1'b0;
        m_uart_rready = 1'b0;

        m_systolic_awaddr = awaddr_q[PERIPH_ADDR_WIDTH-1:0];
        m_systolic_awprot = awprot_q;
        m_systolic_awvalid = 1'b0;
        m_systolic_wdata = wdata_q;
        m_systolic_wstrb = wstrb_q;
        m_systolic_wvalid = 1'b0;
        m_systolic_bready = 1'b0;
        m_systolic_araddr = araddr_q[PERIPH_ADDR_WIDTH-1:0];
        m_systolic_arprot = arprot_q;
        m_systolic_arvalid = 1'b0;
        m_systolic_rready = 1'b0;

        if (wstate_q == W_COLLECT) begin
            s_axil_awready = !aw_hold_q;
            s_axil_wready  = !w_hold_q;
        end else if (wstate_q == W_SEND) begin
            case (wtarget_q)
                SEL_RAM: begin
                    m_ram_awvalid = !aw_sent_q;
                    m_ram_wvalid  = !w_sent_q;
                end
                SEL_DMA: begin
                    m_dma_awvalid = !aw_sent_q;
                    m_dma_wvalid  = !w_sent_q;
                end
                SEL_UART: begin
                    m_uart_awvalid = !aw_sent_q;
                    m_uart_wvalid  = !w_sent_q;
                end
                SEL_SYSTOLIC: begin
                    m_systolic_awvalid = !aw_sent_q;
                    m_systolic_wvalid  = !w_sent_q;
                end
                default: begin end
            endcase
        end else begin
            case (wtarget_q)
                SEL_RAM: begin
                    s_axil_bresp = m_ram_bresp;
                    s_axil_bvalid = m_ram_bvalid;
                    m_ram_bready = s_axil_bready;
                end
                SEL_DMA: begin
                    s_axil_bresp = m_dma_bresp;
                    s_axil_bvalid = m_dma_bvalid;
                    m_dma_bready = s_axil_bready;
                end
                SEL_UART: begin
                    s_axil_bresp = m_uart_bresp;
                    s_axil_bvalid = m_uart_bvalid;
                    m_uart_bready = s_axil_bready;
                end
                SEL_SYSTOLIC: begin
                    s_axil_bresp = m_systolic_bresp;
                    s_axil_bvalid = m_systolic_bvalid;
                    m_systolic_bready = s_axil_bready;
                end
                SEL_DDR_STATUS: begin
                    // The status page is intentionally read-only.
                    s_axil_bresp = 2'b10;
                    s_axil_bvalid = 1'b1;
                end
                default: begin
                    s_axil_bresp = 2'b11;
                    s_axil_bvalid = 1'b1;
                end
            endcase
        end

        if (rstate_q == R_SEND) begin
            case (rtarget_q)
                SEL_RAM:  m_ram_arvalid  = 1'b1;
                SEL_DMA:  m_dma_arvalid  = 1'b1;
                SEL_UART: m_uart_arvalid = 1'b1;
                SEL_SYSTOLIC: m_systolic_arvalid = 1'b1;
                default: begin end
            endcase
        end else begin
            case (rtarget_q)
                SEL_RAM: begin
                    s_axil_rdata = m_ram_rdata;
                    s_axil_rresp = m_ram_rresp;
                    s_axil_rvalid = m_ram_rvalid;
                    m_ram_rready = s_axil_rready;
                end
                SEL_DMA: begin
                    s_axil_rdata = m_dma_rdata;
                    s_axil_rresp = m_dma_rresp;
                    s_axil_rvalid = m_dma_rvalid;
                    m_dma_rready = s_axil_rready;
                end
                SEL_UART: begin
                    s_axil_rdata = m_uart_rdata;
                    s_axil_rresp = m_uart_rresp;
                    s_axil_rvalid = m_uart_rvalid;
                    m_uart_rready = s_axil_rready;
                end
                SEL_SYSTOLIC: begin
                    s_axil_rdata = m_systolic_rdata;
                    s_axil_rresp = m_systolic_rresp;
                    s_axil_rvalid = m_systolic_rvalid;
                    m_systolic_rready = s_axil_rready;
                end
                SEL_DDR_STATUS: begin
                    s_axil_rdata = ddr_status_i;
                    s_axil_rresp = 2'b00;
                    s_axil_rvalid = 1'b1;
                end
                default: begin
                    s_axil_rdata = 32'hDEAD_BEEF;
                    s_axil_rresp = 2'b11;
                    s_axil_rvalid = 1'b1;
                end
            endcase
        end

        cpu_bus_idle_o = (wstate_q == W_COLLECT) && !aw_hold_q && !w_hold_q
                      && (rstate_q == R_IDLE) && !s_axil_awvalid
                      && !s_axil_wvalid && !s_axil_arvalid;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        logic aw_fire, w_fire;
        logic target_aw_fire, target_w_fire;
        if (!rst_ni) begin
            wstate_q <= W_COLLECT;
            rstate_q <= R_IDLE;
            wtarget_q <= SEL_RAM;
            rtarget_q <= SEL_RAM;
            awaddr_q <= '0;
            araddr_q <= '0;
            awprot_q <= '0;
            arprot_q <= '0;
            wdata_q <= '0;
            wstrb_q <= '0;
            aw_hold_q <= 1'b0;
            w_hold_q <= 1'b0;
            aw_sent_q <= 1'b0;
            w_sent_q <= 1'b0;
            s_arready_q <= 1'b1;
        end else begin
            aw_fire = s_axil_awvalid && s_axil_awready;
            w_fire  = s_axil_wvalid && s_axil_wready;
            target_aw_fire = (m_ram_awvalid && m_ram_awready)
                           || (m_dma_awvalid && m_dma_awready)
                           || (m_uart_awvalid && m_uart_awready)
                           || (m_systolic_awvalid && m_systolic_awready);
            target_w_fire = (m_ram_wvalid && m_ram_wready)
                          || (m_dma_wvalid && m_dma_wready)
                          || (m_uart_wvalid && m_uart_wready)
                          || (m_systolic_wvalid && m_systolic_wready);

            case (wstate_q)
                W_COLLECT: begin
                    if (aw_fire) begin
                        awaddr_q <= s_axil_awaddr;
                        awprot_q <= s_axil_awprot;
                        aw_hold_q <= 1'b1;
                    end
                    if (w_fire) begin
                        wdata_q <= s_axil_wdata;
                        wstrb_q <= s_axil_wstrb;
                        w_hold_q <= 1'b1;
                    end
                    if ((aw_hold_q || aw_fire) && (w_hold_q || w_fire)) begin
                        wtarget_q <= decode_target(aw_hold_q ? awaddr_q
                                                            : s_axil_awaddr);
                        aw_sent_q <= 1'b0;
                        w_sent_q <= 1'b0;
                        wstate_q <= W_SEND;
                    end
                end
                W_SEND: begin
                    if (target_aw_fire)
                        aw_sent_q <= 1'b1;
                    if (target_w_fire)
                        w_sent_q <= 1'b1;
                    if (wtarget_q == SEL_DECERR
                        || wtarget_q == SEL_DDR_STATUS
                        || ((aw_sent_q || target_aw_fire)
                            && (w_sent_q || target_w_fire)))
                        wstate_q <= W_RESPONSE;
                end
                default: begin
                    if (s_axil_bvalid && s_axil_bready) begin
                        aw_hold_q <= 1'b0;
                        w_hold_q <= 1'b0;
                        aw_sent_q <= 1'b0;
                        w_sent_q <= 1'b0;
                        wstate_q <= W_COLLECT;
                    end
                end
            endcase

            case (rstate_q)
                R_IDLE: begin
                    if (s_axil_arvalid && s_axil_arready) begin
                        araddr_q <= s_axil_araddr;
                        arprot_q <= s_axil_arprot;
                        rtarget_q <= decode_target(s_axil_araddr);
                        s_arready_q <= 1'b0;
                        rstate_q <= R_SEND;
                    end
                end
                R_SEND: begin
                    if (rtarget_q == SEL_DECERR
                        || rtarget_q == SEL_DDR_STATUS
                        || (m_ram_arvalid && m_ram_arready)
                        || (m_dma_arvalid && m_dma_arready)
                        || (m_uart_arvalid && m_uart_arready)
                        || (m_systolic_arvalid && m_systolic_arready))
                        rstate_q <= R_RESPONSE;
                end
                default: begin
                    if (s_axil_rvalid && s_axil_rready) begin
                        s_arready_q <= 1'b1;
                        rstate_q <= R_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
