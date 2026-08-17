// Module: addr_sel (4x4)
// Scaled down from 32x32 version.
//
// BUG FIXES / CHANGES vs original:
//  - Original had 8 weight banks (w0~w7) + 8 data banks (d0~d7) because
//    32 elements / 4-per-SRAM-word = 8 banks.
//    4x4 has only 4 elements per axis, all fitting in ONE 32-bit SRAM word.
//    So we reduce to 1 weight bank and 1 data bank.
//  - addr_serial_num reduced from 7-bit to 4-bit (max 13 for 4x4).
//  - Address upper bound: original was 98 (= 2*(32+32-1)-1 - 28 last-offset).
//    For 4x4: queue depth = 2*4-1 = 7; addr range per bank = 0..6; max serial = 13.
//    w0/d0 valid when addr_serial_num <= 6 (queue depth - 1).
//  - Output address width reduced from 10-bit to 4-bit (max addr = 6).
//  - No reset in original; kept as is (combinational + registered).

module addr_sel (
    input  wire       clk,
    input  wire [3:0] addr_serial_num,   // 4-bit; max meaningful value = 13 for 4x4

    // Single weight bank and single data bank for 4x4
    output reg  [3:0] sram_raddr_w,      // Address into weight SRAM (0..6)
    output reg  [3:0] sram_raddr_d       // Address into data   SRAM (0..6)
);

// Queue depth for 4x4: 2*N - 1 = 7 addresses (index 0 to 6)
localparam QUEUE_DEPTH = 4'd6;  // max valid address index (0-based, so depth-1)

wire [3:0] sram_raddr_w_nx;
wire [3:0] sram_raddr_d_nx;

// ----------------------------------------------------------------
// Sequential
// ----------------------------------------------------------------
always @(posedge clk) begin
    sram_raddr_w <= sram_raddr_w_nx;
    sram_raddr_d <= sram_raddr_d_nx;
end

// ----------------------------------------------------------------
// Combinational address decode
// For a single bank (offset = 0):
//   valid when addr_serial_num <= QUEUE_DEPTH
//   address = addr_serial_num
//   otherwise output a sentinel (QUEUE_DEPTH+1 = 7 = out-of-range)
// ----------------------------------------------------------------
assign sram_raddr_w_nx = (addr_serial_num <= QUEUE_DEPTH) ?
                          addr_serial_num : (QUEUE_DEPTH + 1'b1);

assign sram_raddr_d_nx = (addr_serial_num <= QUEUE_DEPTH) ?
                          addr_serial_num : (QUEUE_DEPTH + 1'b1);

endmodule