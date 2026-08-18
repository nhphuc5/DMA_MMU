`timescale 1ns / 1ps

module axil_to_apb_bridge #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32
) (
    input  logic clk_i,
    input  logic rst_ni,

    // AXI4-Lite Slave Interface
    input  logic [ADDR_WIDTH-1:0] s_axil_awaddr,
    input  logic [2:0]            s_axil_awprot,
    input  logic                  s_axil_awvalid,
    output logic                  s_axil_awready,
    input  logic [DATA_WIDTH-1:0] s_axil_wdata,
    input  logic [3:0]            s_axil_wstrb,
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

    // APB Master Interface
    output logic [ADDR_WIDTH-1:0] m_apb_paddr,
    output logic                  m_apb_psel,
    output logic                  m_apb_penable,
    output logic                  m_apb_pwrite,
    output logic [DATA_WIDTH-1:0] m_apb_pwdata,
    output logic [3:0]            m_apb_pstrb,
    input  logic [DATA_WIDTH-1:0] m_apb_prdata,
    input  logic                  m_apb_pready,
    input  logic                  m_apb_pslverr
);

    typedef enum logic [1:0] { IDLE, SETUP, ACCESS, RESP } state_t;
    state_t state_q;

    logic is_read_q;
    logic [ADDR_WIDTH-1:0] addr_q;
    logic [DATA_WIDTH-1:0] wdata_q;
    logic [3:0] wstrb_q;
    logic aw_pending_q;
    logic w_pending_q;

    wire aw_fire = s_axil_awvalid && s_axil_awready;
    wire w_fire  = s_axil_wvalid && s_axil_wready;
    wire ar_fire = s_axil_arvalid && s_axil_arready;
    wire write_complete = (aw_pending_q || aw_fire)
                       && (w_pending_q || w_fire);

    always_comb begin
        s_axil_awready = 1'b0;
        s_axil_wready  = 1'b0;
        s_axil_bvalid  = 1'b0;
        s_axil_arready = 1'b0;
        s_axil_rvalid  = 1'b0;
        
        m_apb_psel     = 1'b0;
        m_apb_penable  = 1'b0;
        m_apb_pwrite   = !is_read_q;
        m_apb_paddr    = addr_q;
        m_apb_pwdata   = wdata_q;
        m_apb_pstrb    = wstrb_q;

        case (state_q)
            IDLE: begin
                // AXI4-Lite AW and W are independent channels. Capture either
                // order and begin APB only after both halves are available.
                s_axil_awready = !aw_pending_q;
                s_axil_wready  = !w_pending_q;
                // Preserve deterministic write priority once either write
                // channel is pending or being presented by the master.
                s_axil_arready = !aw_pending_q && !w_pending_q
                                && !s_axil_awvalid && !s_axil_wvalid;
            end
            SETUP: begin
                m_apb_psel = 1'b1;
            end
            ACCESS: begin
                m_apb_psel = 1'b1;
                m_apb_penable = 1'b1;
            end
            RESP: begin
                if (is_read_q) begin
                    s_axil_rvalid = 1'b1;
                end else begin
                    s_axil_bvalid = 1'b1;
                end
            end
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= IDLE;
            is_read_q <= 1'b0;
            addr_q <= '0;
            wdata_q <= '0;
            wstrb_q <= '0;
            aw_pending_q <= 1'b0;
            w_pending_q <= 1'b0;
            
            s_axil_bresp <= 2'b00;
            s_axil_rresp <= 2'b00;
            s_axil_rdata <= '0;
        end else begin
            case (state_q)
                IDLE: begin
                    if (aw_fire) begin
                        addr_q <= s_axil_awaddr;
                        aw_pending_q <= 1'b1;
                    end
                    if (w_fire) begin
                        wdata_q <= s_axil_wdata;
                        wstrb_q <= s_axil_wstrb;
                        w_pending_q <= 1'b1;
                    end

                    if (write_complete) begin
                        is_read_q <= 1'b0;
                        // When the final half arrives this cycle, use it
                        // directly because nonblocking assignments update the
                        // pending registers after this decision.
                        if (aw_fire)
                            addr_q <= s_axil_awaddr;
                        if (w_fire) begin
                            wdata_q <= s_axil_wdata;
                            wstrb_q <= s_axil_wstrb;
                        end
                        aw_pending_q <= 1'b0;
                        w_pending_q <= 1'b0;
                        state_q <= SETUP;
                    end else if (ar_fire) begin
                        is_read_q <= 1'b1;
                        addr_q <= s_axil_araddr;
                        state_q <= SETUP;
                    end
                end
                SETUP: begin
                    state_q <= ACCESS;
                end
                ACCESS: begin
                    if (m_apb_pready) begin
                        if (is_read_q) begin
                            s_axil_rdata <= m_apb_prdata;
                            s_axil_rresp <= m_apb_pslverr ? 2'b10 : 2'b00;
                        end else begin
                            s_axil_bresp <= m_apb_pslverr ? 2'b10 : 2'b00;
                        end
                        state_q <= RESP;
                    end
                end
                RESP: begin
                    if (is_read_q && s_axil_rvalid && s_axil_rready) begin
                        state_q <= IDLE;
                    end else if (!is_read_q && s_axil_bvalid && s_axil_bready) begin
                        state_q <= IDLE;
                    end
                end
            endcase
        end
    end

    logic _unused;
    assign _unused = &{1'b0, s_axil_awprot, s_axil_arprot};

endmodule
