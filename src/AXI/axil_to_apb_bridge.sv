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
                // Simple strict prioritization: AXI write takes precedence over read
                if (s_axil_awvalid && s_axil_wvalid) begin
                    s_axil_awready = 1'b1;
                    s_axil_wready  = 1'b1;
                end else if (s_axil_arvalid && !(s_axil_awvalid && s_axil_wvalid)) begin
                    s_axil_arready = 1'b1;
                end
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
            
            s_axil_bresp <= 2'b00;
            s_axil_rresp <= 2'b00;
            s_axil_rdata <= '0;
        end else begin
            case (state_q)
                IDLE: begin
                    if (s_axil_awvalid && s_axil_wvalid) begin
                        is_read_q <= 1'b0;
                        addr_q <= s_axil_awaddr;
                        wdata_q <= s_axil_wdata;
                        wstrb_q <= s_axil_wstrb;
                        state_q <= SETUP;
                    end else if (s_axil_arvalid) begin
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

endmodule
