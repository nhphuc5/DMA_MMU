`timescale 1ns / 1ps

// Compact command-level DDR3 model for controller regression.
// It is intentionally not a pin/timing model: it verifies command ordering,
// bank/row behavior, masks, calibration gating, refresh, and returned data at
// the DFI-lite boundary.  Pin-level PHY verification is a separate test tier.
module ddr3_dfi_memory_model #(
    parameter int DATA_WIDTH       = 32,
    parameter int ROW_WIDTH        = 16,
    parameter int COL_WIDTH        = 10,
    parameter int BANK_WIDTH       = 3,
    parameter int MODEL_ADDR_WIDTH = 16,
    parameter int READ_LATENCY     = 5,
    parameter int CALIB_CYCLES     = 16
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic                         stall_i,
    input  logic                         inject_error_i,

    input  logic                         dfi_cmd_valid_i,
    output logic                         dfi_cmd_ready_o,
    input  logic [2:0]                   dfi_cmd_i,
    input  logic [BANK_WIDTH-1:0]        dfi_bank_i,
    input  logic [ROW_WIDTH-1:0]         dfi_addr_i,
    input  logic [DATA_WIDTH-1:0]        dfi_wrdata_i,
    input  logic [DATA_WIDTH/8-1:0]      dfi_wrmask_i,
    output logic                         dfi_rddata_valid_o,
    output logic [DATA_WIDTH-1:0]        dfi_rddata_o,
    output logic                         dfi_error_o,

    input  logic                         phy_calib_start_i,
    output logic                         phy_calib_done_o,
    output logic                         phy_calib_error_o,

    output logic [31:0]                  act_count_o,
    output logic [31:0]                  pre_count_o,
    output logic [31:0]                  read_count_o,
    output logic [31:0]                  write_count_o,
    output logic [31:0]                  refresh_count_o,
    output logic                         protocol_error_o
);

    localparam int STRB_WIDTH = DATA_WIDTH/8;
    localparam int BANKS = 1 << BANK_WIDTH;
    localparam logic [2:0] CMD_ACT   = 3'd1;
    localparam logic [2:0] CMD_PRE   = 3'd2;
    localparam logic [2:0] CMD_READ  = 3'd3;
    localparam logic [2:0] CMD_WRITE = 3'd4;
    localparam logic [2:0] CMD_REF   = 3'd5;
    localparam logic [2:0] CMD_MRS   = 3'd6;
    localparam logic [2:0] CMD_ZQ    = 3'd7;

    logic [DATA_WIDTH-1:0] mem [0:(1<<MODEL_ADDR_WIDTH)-1];
    logic [ROW_WIDTH-1:0] open_row_q [0:BANKS-1];
    logic [BANKS-1:0] row_open_q;
    logic read_pending_q;
    logic [15:0] read_timer_q;
    logic [MODEL_ADDR_WIDTH-1:0] read_index_q;
    logic read_error_q;
    logic calib_active_q;
    logic [31:0] calib_timer_q;

    logic [31:0] act_count_q;
    logic [31:0] pre_count_q;
    logic [31:0] read_count_q;
    logic [31:0] write_count_q;
    logic [31:0] refresh_count_q;
    logic protocol_error_q;

    wire [ROW_WIDTH+BANK_WIDTH+COL_WIDTH-1:0] linear_word_addr =
        {open_row_q[dfi_bank_i], dfi_bank_i,
         dfi_addr_i[COL_WIDTH-1:0]};
    wire [MODEL_ADDR_WIDTH-1:0] memory_index =
        linear_word_addr[MODEL_ADDR_WIDTH-1:0];

    assign dfi_cmd_ready_o = !stall_i && !read_pending_q;
    assign act_count_o = act_count_q;
    assign pre_count_o = pre_count_q;
    assign read_count_o = read_count_q;
    assign write_count_o = write_count_q;
    assign refresh_count_o = refresh_count_q;
    assign protocol_error_o = protocol_error_q;

    integer i;
    integer b;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            row_open_q <= '0;
            read_pending_q <= 1'b0;
            read_timer_q <= '0;
            read_index_q <= '0;
            read_error_q <= 1'b0;
            dfi_rddata_valid_o <= 1'b0;
            dfi_rddata_o <= '0;
            dfi_error_o <= 1'b0;
            calib_active_q <= 1'b0;
            calib_timer_q <= '0;
            phy_calib_done_o <= 1'b0;
            phy_calib_error_o <= 1'b0;
            act_count_q <= '0;
            pre_count_q <= '0;
            read_count_q <= '0;
            write_count_q <= '0;
            refresh_count_q <= '0;
            protocol_error_q <= 1'b0;
            for (b = 0; b < BANKS; b = b+1)
                open_row_q[b] <= '0;
            for (i = 0; i < (1<<MODEL_ADDR_WIDTH); i = i+1)
                mem[i] <= '0;
        end else begin
            dfi_rddata_valid_o <= 1'b0;

            if (phy_calib_start_i && !phy_calib_done_o) begin
                calib_active_q <= 1'b1;
                calib_timer_q <= CALIB_CYCLES;
            end
            if (calib_active_q) begin
                if (calib_timer_q != 0)
                    calib_timer_q <= calib_timer_q - 1'b1;
                else begin
                    calib_active_q <= 1'b0;
                    phy_calib_done_o <= 1'b1;
                end
            end

            if (read_pending_q) begin
                if (read_timer_q != 0)
                    read_timer_q <= read_timer_q - 1'b1;
                else begin
                    read_pending_q <= 1'b0;
                    dfi_rddata_valid_o <= 1'b1;
                    dfi_rddata_o <= mem[read_index_q];
                    dfi_error_o <= read_error_q;
                end
            end

            if (dfi_cmd_valid_i && dfi_cmd_ready_o) begin
                dfi_error_o <= 1'b0;
                case (dfi_cmd_i)
                    CMD_ACT: begin
                        if (row_open_q[dfi_bank_i])
                            protocol_error_q <= 1'b1;
                        row_open_q[dfi_bank_i] <= 1'b1;
                        open_row_q[dfi_bank_i] <= dfi_addr_i;
                        act_count_q <= act_count_q + 1'b1;
                    end
                    CMD_PRE: begin
                        if (dfi_addr_i[10])
                            row_open_q <= '0;
                        else
                            row_open_q[dfi_bank_i] <= 1'b0;
                        pre_count_q <= pre_count_q + 1'b1;
                    end
                    CMD_READ: begin
                        if (!row_open_q[dfi_bank_i])
                            protocol_error_q <= 1'b1;
                        read_pending_q <= 1'b1;
                        read_timer_q <= READ_LATENCY;
                        read_index_q <= memory_index;
                        read_error_q <= inject_error_i;
                        read_count_q <= read_count_q + 1'b1;
                    end
                    CMD_WRITE: begin
                        if (!row_open_q[dfi_bank_i])
                            protocol_error_q <= 1'b1;
                        for (i = 0; i < STRB_WIDTH; i = i+1)
                            if (!dfi_wrmask_i[i])
                                mem[memory_index][i*8 +: 8]
                                    <= dfi_wrdata_i[i*8 +: 8];
                        dfi_error_o <= inject_error_i;
                        write_count_q <= write_count_q + 1'b1;
                    end
                    CMD_REF: begin
                        if (row_open_q != 0)
                            protocol_error_q <= 1'b1;
                        refresh_count_q <= refresh_count_q + 1'b1;
                    end
                    CMD_MRS, CMD_ZQ: begin end
                    default: protocol_error_q <= 1'b1;
                endcase
            end
        end
    end

endmodule
