`timescale 1ns / 1ps

// Resource-oriented DDR3 command scheduler.
//
// This block deliberately contains no FPGA-vendor memory-controller IP.  It
// accepts one word transaction at a time, tracks the open row in every bank,
// emits a compact DFI-like command stream, performs the JEDEC-style power-up
// command sequence, requests PHY calibration, and periodically refreshes the
// array.  The conservative single-command datapath is intentional: it keeps
// the critical path short and makes ordering at the AXI boundary unambiguous.
// A pipelined/multi-bank scheduler can be added later without changing the
// AXI or PHY contracts.
module ddr3_controller_core #(
    parameter int ADDR_WIDTH       = 32,
    parameter int DATA_WIDTH       = 32,
    parameter int ROW_WIDTH        = 16,
    parameter int COL_WIDTH        = 10,
    parameter int BANK_WIDTH       = 3,
    parameter int RESET_CYCLES     = 64,
    parameter int T_RP_CYCLES      = 3,
    parameter int T_RCD_CYCLES     = 3,
    parameter int T_RFC_CYCLES     = 24,
    parameter int T_MRD_CYCLES     = 4,
    parameter int T_MOD_CYCLES     = 12,
    parameter int T_WR_CYCLES      = 4,
    parameter int REFRESH_CYCLES   = 1170,
    parameter int CAL_TIMEOUT      = 65535
) (
    input  logic                     clk_i,
    input  logic                     rst_ni,

    input  logic                     req_valid_i,
    output logic                     req_ready_o,
    input  logic                     req_write_i,
    input  logic                     req_tag_i,
    input  logic [ADDR_WIDTH-1:0]    req_addr_i,
    input  logic [DATA_WIDTH-1:0]    req_wdata_i,
    input  logic [DATA_WIDTH/8-1:0]  req_wstrb_i,

    output logic                     rsp_valid_o,
    input  logic                     rsp_ready_i,
    output logic                     rsp_write_o,
    output logic                     rsp_tag_o,
    output logic [DATA_WIDTH-1:0]    rsp_rdata_o,
    output logic                     rsp_error_o,

    output logic                     init_done_o,
    output logic                     calib_done_o,
    output logic                     calib_error_o,
    output logic                     refresh_busy_o,
    output logic [31:0]              refresh_count_o,

    // DFI-lite command interface. Commands use DDR encodings local to this
    // project: ACT=1, PRE=2, READ=3, WRITE=4, REF=5, MRS=6, ZQ=7.
    output logic                     dfi_cmd_valid_o,
    input  logic                     dfi_cmd_ready_i,
    output logic [2:0]               dfi_cmd_o,
    output logic [BANK_WIDTH-1:0]    dfi_bank_o,
    output logic [ROW_WIDTH-1:0]     dfi_addr_o,
    output logic [DATA_WIDTH-1:0]    dfi_wrdata_o,
    output logic [DATA_WIDTH/8-1:0]  dfi_wrmask_o,
    input  logic                     dfi_rddata_valid_i,
    input  logic [DATA_WIDTH-1:0]    dfi_rddata_i,
    input  logic                     dfi_error_i,

    output logic                     phy_calib_start_o,
    input  logic                     phy_calib_done_i,
    input  logic                     phy_calib_error_i
);

    localparam int STRB_WIDTH = DATA_WIDTH/8;
    localparam int BYTE_LSB = $clog2(STRB_WIDTH);
    localparam int BANKS = 1 << BANK_WIDTH;
    // Keep the timing counters only as wide as required.  A fixed 32-bit
    // down-counter creates a needlessly long carry chain and high-fanout
    // clock-enable network on 7-series parts.
    localparam int WAIT_MAX_0 = RESET_CYCLES > T_RP_CYCLES
                              ? RESET_CYCLES : T_RP_CYCLES;
    localparam int WAIT_MAX_1 = T_RCD_CYCLES > T_RFC_CYCLES
                              ? T_RCD_CYCLES : T_RFC_CYCLES;
    localparam int WAIT_MAX_2 = T_MRD_CYCLES > T_MOD_CYCLES
                              ? T_MRD_CYCLES : T_MOD_CYCLES;
    localparam int WAIT_MAX_3 = T_WR_CYCLES > WAIT_MAX_0
                              ? T_WR_CYCLES : WAIT_MAX_0;
    localparam int WAIT_MAX_4 = WAIT_MAX_1 > WAIT_MAX_2
                              ? WAIT_MAX_1 : WAIT_MAX_2;
    localparam int WAIT_MAX = WAIT_MAX_3 > WAIT_MAX_4
                            ? WAIT_MAX_3 : WAIT_MAX_4;
    localparam int TIMER_WIDTH = WAIT_MAX < 1 ? 1 : $clog2(WAIT_MAX + 1);
    localparam int REFRESH_TIMER_WIDTH = REFRESH_CYCLES < 1
                                       ? 1 : $clog2(REFRESH_CYCLES + 1);
    localparam int CAL_TIMER_WIDTH = CAL_TIMEOUT < 1
                                   ? 1 : $clog2(CAL_TIMEOUT + 1);

    localparam logic [2:0] CMD_NOP   = 3'd0;
    localparam logic [2:0] CMD_ACT   = 3'd1;
    localparam logic [2:0] CMD_PRE   = 3'd2;
    localparam logic [2:0] CMD_READ  = 3'd3;
    localparam logic [2:0] CMD_WRITE = 3'd4;
    localparam logic [2:0] CMD_REF   = 3'd5;
    localparam logic [2:0] CMD_MRS   = 3'd6;
    localparam logic [2:0] CMD_ZQ    = 3'd7;

    typedef enum logic [4:0] {
        ST_RESET_WAIT,
        ST_INIT_PRE,
        ST_INIT_PRE_WAIT,
        ST_INIT_MRS2,
        ST_INIT_MRS3,
        ST_INIT_MRS1,
        ST_INIT_MRS0,
        ST_INIT_ZQ,
        ST_INIT_ZQ_WAIT,
        ST_CAL_START,
        ST_CAL_WAIT,
        ST_IDLE,
        ST_REQ_PRE,
        ST_REQ_PRE_WAIT,
        ST_REQ_ACT,
        ST_REQ_ACT_WAIT,
        ST_REQ_RW,
        ST_REQ_WRITE_WAIT,
        ST_REQ_READ_WAIT,
        ST_REFRESH_PRE,
        ST_REFRESH_PRE_WAIT,
        ST_REFRESH_CMD,
        ST_REFRESH_WAIT,
        ST_RESPONSE
    } state_t;

    // One-hot encoding removes the wide state decoder from the request and
    // timing-control paths.  This costs a handful of flip-flops but is a
    // better speed/resource trade on LUT6-based 7-series devices.
    (* fsm_encoding = "one_hot" *) state_t state_q;
    logic [TIMER_WIDTH-1:0] timer_q;
    logic [REFRESH_TIMER_WIDTH-1:0] refresh_timer_q;
    logic [CAL_TIMER_WIDTH-1:0] calib_timer_q;
    logic refresh_pending_q;

    logic req_write_q;
    logic req_tag_q;
    logic [ADDR_WIDTH-1:0] req_addr_q;
    logic [DATA_WIDTH-1:0] req_wdata_q;
    logic [STRB_WIDTH-1:0] req_wstrb_q;
    logic [ROW_WIDTH-1:0] req_row_q;
    logic [COL_WIDTH-1:0] req_col_q;
    logic [BANK_WIDTH-1:0] req_bank_q;

    logic [ROW_WIDTH-1:0] open_row_q [0:BANKS-1];
    logic [BANKS-1:0] row_open_q;

    logic rsp_valid_q;
    logic rsp_write_q;
    logic rsp_tag_q;
    logic [DATA_WIDTH-1:0] rsp_rdata_q;
    logic rsp_error_q;
    logic init_done_q;
    logic calib_done_q;
    logic calib_error_q;
    logic [31:0] refresh_count_q;

    wire [ADDR_WIDTH-BYTE_LSB-1:0] req_word_addr =
        req_addr_i[ADDR_WIDTH-1:BYTE_LSB];
    wire [COL_WIDTH-1:0] req_col = req_word_addr[COL_WIDTH-1:0];
    wire [BANK_WIDTH-1:0] req_bank =
        req_word_addr[COL_WIDTH +: BANK_WIDTH];
    wire [ROW_WIDTH-1:0] req_row =
        req_word_addr[COL_WIDTH+BANK_WIDTH +: ROW_WIDTH];

    assign req_ready_o = state_q == ST_IDLE && !refresh_pending_q
                      && !rsp_valid_q;
    assign rsp_valid_o = rsp_valid_q;
    assign rsp_write_o = rsp_write_q;
    assign rsp_tag_o = rsp_tag_q;
    assign rsp_rdata_o = rsp_rdata_q;
    assign rsp_error_o = rsp_error_q;
    assign init_done_o = init_done_q;
    assign calib_done_o = calib_done_q;
    assign calib_error_o = calib_error_q;
    assign refresh_busy_o = state_q == ST_REFRESH_PRE
                         || state_q == ST_REFRESH_PRE_WAIT
                         || state_q == ST_REFRESH_CMD
                         || state_q == ST_REFRESH_WAIT;
    assign refresh_count_o = refresh_count_q;

    always_comb begin
        dfi_cmd_valid_o = 1'b0;
        dfi_cmd_o = CMD_NOP;
        dfi_bank_o = req_bank_q;
        dfi_addr_o = '0;
        dfi_wrdata_o = req_wdata_q;
        // DFI uses a mask (1 means do not write), opposite to AXI WSTRB.
        dfi_wrmask_o = ~req_wstrb_q;
        phy_calib_start_o = state_q == ST_CAL_START;

        case (state_q)
            ST_INIT_PRE, ST_REFRESH_PRE: begin
                dfi_cmd_valid_o = 1'b1;
                dfi_cmd_o = CMD_PRE;
                dfi_bank_o = '0;
                dfi_addr_o[10] = 1'b1; // PRECHARGE ALL
            end
            ST_INIT_MRS2: begin
                dfi_cmd_valid_o = 1'b1;
                dfi_cmd_o = CMD_MRS;
                dfi_bank_o = 3'd2;
                dfi_addr_o = '0;
            end
            ST_INIT_MRS3: begin
                dfi_cmd_valid_o = timer_q == 0;
                dfi_cmd_o = CMD_MRS;
                dfi_bank_o = 3'd3;
                dfi_addr_o = '0;
            end
            ST_INIT_MRS1: begin
                dfi_cmd_valid_o = timer_q == 0;
                dfi_cmd_o = CMD_MRS;
                dfi_bank_o = 3'd1;
                dfi_addr_o = '0;
            end
            ST_INIT_MRS0: begin
                dfi_cmd_valid_o = timer_q == 0;
                dfi_cmd_o = CMD_MRS;
                dfi_bank_o = 3'd0;
                // BL8, sequential, DLL reset. CAS fields are intentionally
                // left for the board PHY wrapper to specialize.
                dfi_addr_o = '0;
                dfi_addr_o[8] = 1'b1;
            end
            ST_INIT_ZQ: begin
                dfi_cmd_valid_o = timer_q == 0;
                dfi_cmd_o = CMD_ZQ;
                dfi_addr_o[10] = 1'b1; // ZQCL
            end
            ST_REQ_PRE: begin
                dfi_cmd_valid_o = 1'b1;
                dfi_cmd_o = CMD_PRE;
                dfi_bank_o = req_bank_q;
            end
            ST_REQ_ACT: begin
                dfi_cmd_valid_o = 1'b1;
                dfi_cmd_o = CMD_ACT;
                dfi_bank_o = req_bank_q;
                dfi_addr_o = req_row_q;
            end
            ST_REQ_RW: begin
                dfi_cmd_valid_o = 1'b1;
                dfi_cmd_o = req_write_q ? CMD_WRITE : CMD_READ;
                dfi_bank_o = req_bank_q;
                dfi_addr_o[COL_WIDTH-1:0] = req_col_q;
            end
            ST_REFRESH_CMD: begin
                dfi_cmd_valid_o = 1'b1;
                dfi_cmd_o = CMD_REF;
            end
            default: begin end
        endcase
    end

    integer bank_index;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= ST_RESET_WAIT;
            timer_q <= RESET_CYCLES;
            refresh_timer_q <= REFRESH_CYCLES;
            calib_timer_q <= '0;
            refresh_pending_q <= 1'b0;
            req_write_q <= 1'b0;
            req_tag_q <= 1'b0;
            req_addr_q <= '0;
            req_wdata_q <= '0;
            req_wstrb_q <= '0;
            req_row_q <= '0;
            req_col_q <= '0;
            req_bank_q <= '0;
            row_open_q <= '0;
            rsp_valid_q <= 1'b0;
            rsp_write_q <= 1'b0;
            rsp_tag_q <= 1'b0;
            rsp_rdata_q <= '0;
            rsp_error_q <= 1'b0;
            init_done_q <= 1'b0;
            calib_done_q <= 1'b0;
            calib_error_q <= 1'b0;
            refresh_count_q <= '0;
            for (bank_index = 0; bank_index < BANKS; bank_index = bank_index+1)
                open_row_q[bank_index] <= '0;
        end else begin
            if (rsp_valid_q && rsp_ready_i)
                rsp_valid_q <= 1'b0;

            // Refresh becomes pending at a fixed interval. Saturating at zero
            // avoids a wide equality/mux feedback path in the scheduler.
            if (init_done_q && calib_done_q) begin
                if (refresh_timer_q != 0)
                    refresh_timer_q <= refresh_timer_q - 1'b1;
                else begin
                    refresh_pending_q <= 1'b1;
                    refresh_timer_q <= REFRESH_CYCLES;
                end
            end

            case (state_q)
                ST_RESET_WAIT: begin
                    if (timer_q != 0)
                        timer_q <= timer_q - 1'b1;
                    else
                        state_q <= ST_INIT_PRE;
                end

                ST_INIT_PRE: if (dfi_cmd_valid_o && dfi_cmd_ready_i) begin
                    row_open_q <= '0;
                    timer_q <= T_RP_CYCLES;
                    state_q <= ST_INIT_PRE_WAIT;
                end
                ST_INIT_PRE_WAIT: begin
                    if (timer_q != 0) timer_q <= timer_q - 1'b1;
                    else state_q <= ST_INIT_MRS2;
                end
                ST_INIT_MRS2: if (dfi_cmd_ready_i) begin
                    timer_q <= T_MRD_CYCLES;
                    state_q <= ST_INIT_MRS3;
                end
                ST_INIT_MRS3: if (dfi_cmd_ready_i && timer_q == 0) begin
                    timer_q <= T_MRD_CYCLES;
                    state_q <= ST_INIT_MRS1;
                end else if (timer_q != 0) timer_q <= timer_q - 1'b1;
                ST_INIT_MRS1: if (dfi_cmd_ready_i && timer_q == 0) begin
                    timer_q <= T_MRD_CYCLES;
                    state_q <= ST_INIT_MRS0;
                end else if (timer_q != 0) timer_q <= timer_q - 1'b1;
                ST_INIT_MRS0: if (dfi_cmd_ready_i && timer_q == 0) begin
                    timer_q <= T_MOD_CYCLES;
                    state_q <= ST_INIT_ZQ;
                end else if (timer_q != 0) timer_q <= timer_q - 1'b1;
                ST_INIT_ZQ: if (dfi_cmd_ready_i && timer_q == 0) begin
                    timer_q <= T_RFC_CYCLES;
                    state_q <= ST_INIT_ZQ_WAIT;
                end else if (timer_q != 0) timer_q <= timer_q - 1'b1;
                ST_INIT_ZQ_WAIT: begin
                    if (timer_q != 0) timer_q <= timer_q - 1'b1;
                    else begin
                        init_done_q <= 1'b1;
                        state_q <= ST_CAL_START;
                    end
                end
                ST_CAL_START: begin
                    calib_timer_q <= CAL_TIMEOUT;
                    state_q <= ST_CAL_WAIT;
                end
                ST_CAL_WAIT: begin
                    if (phy_calib_error_i) begin
                        calib_error_q <= 1'b1;
                        state_q <= ST_CAL_WAIT;
                    end else if (phy_calib_done_i) begin
                        calib_done_q <= 1'b1;
                        state_q <= ST_IDLE;
                    end else if (calib_timer_q != 0) begin
                        calib_timer_q <= calib_timer_q - 1'b1;
                    end else begin
                        calib_error_q <= 1'b1;
                    end
                end

                ST_IDLE: begin
                    if (refresh_pending_q) begin
                        state_q <= ST_REFRESH_PRE;
                    end else if (req_valid_i && req_ready_o) begin
                        req_write_q <= req_write_i;
                        req_tag_q <= req_tag_i;
                        req_addr_q <= req_addr_i;
                        req_wdata_q <= req_wdata_i;
                        req_wstrb_q <= req_wstrb_i;
                        req_row_q <= req_row;
                        req_col_q <= req_col;
                        req_bank_q <= req_bank;
                        if (row_open_q[req_bank] && open_row_q[req_bank] != req_row)
                            state_q <= ST_REQ_PRE;
                        else if (!row_open_q[req_bank])
                            state_q <= ST_REQ_ACT;
                        else
                            state_q <= ST_REQ_RW;
                    end
                end

                ST_REQ_PRE: if (dfi_cmd_ready_i) begin
                    row_open_q[req_bank_q] <= 1'b0;
                    timer_q <= T_RP_CYCLES;
                    state_q <= ST_REQ_PRE_WAIT;
                end
                ST_REQ_PRE_WAIT: begin
                    if (timer_q != 0) timer_q <= timer_q - 1'b1;
                    else state_q <= ST_REQ_ACT;
                end
                ST_REQ_ACT: if (dfi_cmd_ready_i) begin
                    row_open_q[req_bank_q] <= 1'b1;
                    open_row_q[req_bank_q] <= req_row_q;
                    timer_q <= T_RCD_CYCLES;
                    state_q <= ST_REQ_ACT_WAIT;
                end
                ST_REQ_ACT_WAIT: begin
                    if (timer_q != 0) timer_q <= timer_q - 1'b1;
                    else state_q <= ST_REQ_RW;
                end
                ST_REQ_RW: if (dfi_cmd_ready_i) begin
                    if (req_write_q) begin
                        timer_q <= T_WR_CYCLES;
                        state_q <= ST_REQ_WRITE_WAIT;
                    end else begin
                        state_q <= ST_REQ_READ_WAIT;
                    end
                end
                ST_REQ_WRITE_WAIT: begin
                    if (timer_q != 0) timer_q <= timer_q - 1'b1;
                    else begin
                        rsp_write_q <= 1'b1;
                        rsp_tag_q <= req_tag_q;
                        rsp_rdata_q <= '0;
                        rsp_error_q <= dfi_error_i;
                        rsp_valid_q <= 1'b1;
                        state_q <= ST_RESPONSE;
                    end
                end
                ST_REQ_READ_WAIT: if (dfi_rddata_valid_i) begin
                    rsp_write_q <= 1'b0;
                    rsp_tag_q <= req_tag_q;
                    rsp_rdata_q <= dfi_rddata_i;
                    rsp_error_q <= dfi_error_i;
                    rsp_valid_q <= 1'b1;
                    state_q <= ST_RESPONSE;
                end

                ST_REFRESH_PRE: if (dfi_cmd_ready_i) begin
                    row_open_q <= '0;
                    timer_q <= T_RP_CYCLES;
                    state_q <= ST_REFRESH_PRE_WAIT;
                end
                ST_REFRESH_PRE_WAIT: begin
                    if (timer_q != 0) timer_q <= timer_q - 1'b1;
                    else state_q <= ST_REFRESH_CMD;
                end
                ST_REFRESH_CMD: if (dfi_cmd_ready_i) begin
                    timer_q <= T_RFC_CYCLES;
                    state_q <= ST_REFRESH_WAIT;
                end
                ST_REFRESH_WAIT: begin
                    if (timer_q != 0) timer_q <= timer_q - 1'b1;
                    else begin
                        refresh_pending_q <= 1'b0;
                        refresh_count_q <= refresh_count_q + 1'b1;
                        state_q <= ST_IDLE;
                    end
                end

                ST_RESPONSE: if (rsp_valid_q && rsp_ready_i)
                    state_q <= ST_IDLE;
                default: state_q <= ST_RESET_WAIT;
            endcase
        end
    end

    // req_addr_q is retained for debug visibility and future timing policies.
    logic _unused;
    assign _unused = &{1'b0, req_addr_q, CMD_NOP};

endmodule
