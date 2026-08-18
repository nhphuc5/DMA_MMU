`timescale 1ns / 1ps

// End-to-end, self-checking test for the run-time multi-image protocol.
// No result pixels are written directly into RAM by this testbench.  Input
// bytes enter through the physical UART RX pin and output bytes are observed
// only after the UART TX engine accepts them.
module tb_soc_uart_image_batch #(
    parameter MEM_INIT_FILE = "firmware/prebuilt/vc707_unified/soc_uart_image_batch.hex",
    parameter integer EXPECTED_DMA_MODE = 0
);
    localparam real CLOCK_PERIOD_NS = 6.667;
    // Match the high-volume VC707 firmware exactly (~921600 baud at 150 MHz).
    // The BRAM/DDR crossbar adds legitimate CPU latency, so an artificially
    // faster UART can overrun the one-byte CPU header path in simulation.
    localparam integer UART_DIVIDER = 161;
    localparam integer UART_BIT_CYCLES = UART_DIVIDER + 2;
    localparam integer FRAME_BYTES = 64;
    localparam integer DDR_SIM_ADDR_WIDTH = 20;
    localparam integer DDR_ID_WIDTH = 6;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic uart_rx = 1'b1;
    wire uart_tx;
    wire cpu_trap, dma_irq, uart_irq;
    wire [7:0] tx_byte;
    wire tx_byte_valid;

    // The SoC rebases its 0x8000_0000 DDR aperture before exporting AXI to
    // MIG. The behavioral test keeps a compact 1 MiB backing store and folds
    // the rebased region/slot information into its address.
    wire [DDR_ID_WIDTH-1:0] ddr_awid, ddr_bid, ddr_arid, ddr_rid;
    wire [31:0] ddr_awaddr_raw, ddr_araddr_raw;
    wire [DDR_SIM_ADDR_WIDTH-1:0] ddr_awaddr_sim, ddr_araddr_sim;
    wire [7:0] ddr_awlen, ddr_arlen;
    wire [2:0] ddr_awsize, ddr_arsize;
    wire [1:0] ddr_awburst, ddr_arburst;
    wire ddr_awlock, ddr_arlock;
    wire [3:0] ddr_awcache, ddr_arcache;
    wire [2:0] ddr_awprot, ddr_arprot;
    wire [3:0] ddr_awqos, ddr_arqos;
    wire ddr_awvalid, ddr_awready;
    wire [31:0] ddr_wdata, ddr_rdata;
    wire [3:0] ddr_wstrb;
    wire ddr_wlast, ddr_wvalid, ddr_wready;
    wire [1:0] ddr_bresp, ddr_rresp;
    wire ddr_bvalid, ddr_bready;
    wire ddr_arvalid, ddr_arready;
    wire ddr_rlast, ddr_rvalid, ddr_rready;

    function automatic [DDR_SIM_ADDR_WIDTH-1:0] compress_ddr_addr(
        input logic [31:0] address
    );
        logic [1:0] region;
        begin
            case (address[29:28])
                2'd0: region = 2'd0; // 0x0000_0000: input slots
                2'd1: region = 2'd1; // 0x1000_0000: work slots
                2'd2: region = 2'd2; // 0x2000_0000: output slots
                default: region = 2'd3;
            endcase
            compress_ddr_addr = {region, address[27:26], address[15:0]};
        end
    endfunction

    assign ddr_awaddr_sim = compress_ddr_addr(ddr_awaddr_raw);
    assign ddr_araddr_sim = compress_ddr_addr(ddr_araddr_raw);

    logic [7:0] raster [0:1][0:FRAME_BYTES-1];
    logic [7:0] tiled  [0:1][0:FRAME_BYTES-1];
    logic [7:0] tx_fifo [0:65535];
    integer tx_write = 0;
    integer tx_read = 0;
    integer errors = 0;
    integer log_fd;
    logic finished = 1'b0;

    always #(CLOCK_PERIOD_NS/2.0) clk = ~clk;

    dma_mmu_picorv32_soc #(
        .AXI_ADDR_WIDTH(32),
        .BRAM_ADDR_WIDTH(18),
        .UART_DEFAULT_DIV(UART_DIVIDER),
        .MEM_INIT_FILE(MEM_INIT_FILE),
        .ENABLE_DDR3(1'b1),
        .USE_EXTERNAL_DDR_AXI(1'b1)
    ) dut (
        .clk_i(clk), .rst_ni(rst_n),
        .uart_rx_i(uart_rx), .uart_tx_o(uart_tx),
        .cpu_trap_o(cpu_trap), .dma_irq_o(dma_irq), .uart_irq_o(uart_irq),
        .uart_tx_byte_o(tx_byte), .uart_tx_byte_valid_o(tx_byte_valid),
        .ddr_dfi_cmd_ready_i(1'b0), .ddr_dfi_rddata_valid_i(1'b0),
        .ddr_dfi_rddata_i(32'd0), .ddr_dfi_error_i(1'b0),
        .ddr_phy_calib_done_i(1'b0), .ddr_phy_calib_error_i(1'b0),
        .m_ddr_axi_awid(ddr_awid), .m_ddr_axi_awaddr(ddr_awaddr_raw),
        .m_ddr_axi_awlen(ddr_awlen), .m_ddr_axi_awsize(ddr_awsize),
        .m_ddr_axi_awburst(ddr_awburst), .m_ddr_axi_awlock(ddr_awlock),
        .m_ddr_axi_awcache(ddr_awcache), .m_ddr_axi_awprot(ddr_awprot),
        .m_ddr_axi_awqos(ddr_awqos), .m_ddr_axi_awvalid(ddr_awvalid),
        .m_ddr_axi_awready(ddr_awready), .m_ddr_axi_wdata(ddr_wdata),
        .m_ddr_axi_wstrb(ddr_wstrb), .m_ddr_axi_wlast(ddr_wlast),
        .m_ddr_axi_wvalid(ddr_wvalid), .m_ddr_axi_wready(ddr_wready),
        .m_ddr_axi_bid(ddr_bid), .m_ddr_axi_bresp(ddr_bresp),
        .m_ddr_axi_bvalid(ddr_bvalid), .m_ddr_axi_bready(ddr_bready),
        .m_ddr_axi_arid(ddr_arid), .m_ddr_axi_araddr(ddr_araddr_raw),
        .m_ddr_axi_arlen(ddr_arlen), .m_ddr_axi_arsize(ddr_arsize),
        .m_ddr_axi_arburst(ddr_arburst), .m_ddr_axi_arlock(ddr_arlock),
        .m_ddr_axi_arcache(ddr_arcache), .m_ddr_axi_arprot(ddr_arprot),
        .m_ddr_axi_arqos(ddr_arqos), .m_ddr_axi_arvalid(ddr_arvalid),
        .m_ddr_axi_arready(ddr_arready), .m_ddr_axi_rid(ddr_rid),
        .m_ddr_axi_rdata(ddr_rdata), .m_ddr_axi_rresp(ddr_rresp),
        .m_ddr_axi_rlast(ddr_rlast), .m_ddr_axi_rvalid(ddr_rvalid),
        .m_ddr_axi_rready(ddr_rready),
        .external_ddr_calib_done_i(1'b1),
        .external_ddr_calib_error_i(1'b0),
        .external_ddr_ui_reset_i(1'b0)
    );

    axi_ram #(
        .DATA_WIDTH(32),
        .ADDR_WIDTH(DDR_SIM_ADDR_WIDTH),
        .ID_WIDTH(DDR_ID_WIDTH),
        .PIPELINE_OUTPUT(1)
    ) ddr_ram_inst (
        .clk(clk), .rst(!rst_n),
        .s_axi_awid(ddr_awid), .s_axi_awaddr(ddr_awaddr_sim),
        .s_axi_awlen(ddr_awlen), .s_axi_awsize(ddr_awsize),
        .s_axi_awburst(ddr_awburst), .s_axi_awlock(ddr_awlock),
        .s_axi_awcache(ddr_awcache), .s_axi_awprot(ddr_awprot),
        .s_axi_awvalid(ddr_awvalid), .s_axi_awready(ddr_awready),
        .s_axi_wdata(ddr_wdata), .s_axi_wstrb(ddr_wstrb),
        .s_axi_wlast(ddr_wlast), .s_axi_wvalid(ddr_wvalid),
        .s_axi_wready(ddr_wready), .s_axi_bid(ddr_bid),
        .s_axi_bresp(ddr_bresp), .s_axi_bvalid(ddr_bvalid),
        .s_axi_bready(ddr_bready), .s_axi_arid(ddr_arid),
        .s_axi_araddr(ddr_araddr_sim), .s_axi_arlen(ddr_arlen),
        .s_axi_arsize(ddr_arsize), .s_axi_arburst(ddr_arburst),
        .s_axi_arlock(ddr_arlock), .s_axi_arcache(ddr_arcache),
        .s_axi_arprot(ddr_arprot), .s_axi_arvalid(ddr_arvalid),
        .s_axi_arready(ddr_arready), .s_axi_rid(ddr_rid),
        .s_axi_rdata(ddr_rdata), .s_axi_rresp(ddr_rresp),
        .s_axi_rlast(ddr_rlast), .s_axi_rvalid(ddr_rvalid),
        .s_axi_rready(ddr_rready)
    );

    always @(posedge clk) begin
        if (tx_byte_valid) begin
            tx_fifo[tx_write] = tx_byte;
            tx_write = tx_write + 1;
        end
        if (rst_n && cpu_trap && !finished) begin
            $fdisplay(log_fd, "FAIL: PicoRV32 trap pc=%08x",
                      dut.cpu_inst.picorv32_core.reg_pc);
            $fatal(1, "PicoRV32 trap");
        end
    end

    task automatic send_uart_byte(input logic [7:0] value);
        begin
            @(negedge clk);
            uart_rx <= 1'b0;
            repeat (UART_BIT_CYCLES) @(negedge clk);
            for (int bit_index = 0; bit_index < 8; bit_index++) begin
                uart_rx <= value[bit_index];
                repeat (UART_BIT_CYCLES) @(negedge clk);
            end
            uart_rx <= 1'b1;
            repeat (UART_BIT_CYCLES) @(negedge clk);
        end
    endtask

    task automatic send_u16(input integer value);
        begin
            send_uart_byte(value[7:0]);
            send_uart_byte(value[15:8]);
        end
    endtask

    task automatic send_u32(input logic [31:0] value);
        begin
            send_uart_byte(value[7:0]);
            send_uart_byte(value[15:8]);
            send_uart_byte(value[23:16]);
            send_uart_byte(value[31:24]);
        end
    endtask

    task automatic receive_byte(output logic [7:0] value);
        begin
            while (tx_read == tx_write)
                @(posedge clk);
            value = tx_fifo[tx_read];
            tx_read = tx_read + 1;
        end
    endtask

    task automatic receive_u16(output integer value);
        logic [7:0] b0, b1;
        begin
            receive_byte(b0); receive_byte(b1);
            value = {b1, b0};
        end
    endtask

    task automatic receive_u32(output logic [31:0] value);
        logic [7:0] b0, b1, b2, b3;
        begin
            receive_byte(b0); receive_byte(b1);
            receive_byte(b2); receive_byte(b3);
            value = {b3, b2, b1, b0};
        end
    endtask

    task automatic expect_tag(input [31:0] expected);
        logic [31:0] actual;
        logic [31:0] rejected;
        begin
            receive_u32(actual);
            if (actual !== expected) begin
                if (actual == {"C","N","Y","S"}) begin
                    receive_u32(rejected);
                    $fdisplay(log_fd,
                        "FIRMWARE SYNC: rejected UART word=%08x", rejected);
                end
                errors = errors + 1;
                $fdisplay(log_fd, "TAG ERROR: got=%08x expected=%08x", actual, expected);
                $fatal(1, "Protocol tag mismatch");
            end
        end
    endtask

    function automatic [31:0] frame_crc(input integer frame);
        reg [31:0] crc;
        integer index, bit_index;
        begin
            crc = 32'hffff_ffff;
            for (index = 0; index < FRAME_BYTES; index = index + 1) begin
                crc = crc ^ tiled[frame][index];
                for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                    crc = (crc >> 1) ^ (32'hedb8_8320 & (0 - (crc & 1)));
            end
            frame_crc = ~crc;
        end
    endfunction

    function automatic [31:0] output_crc(input integer frame);
        reg [31:0] crc;
        reg [7:0] value;
        integer index, bit_index;
        begin
            crc = 32'hffff_ffff;
            for (index = 0; index < FRAME_BYTES; index = index + 1) begin
                value = tiled[frame][index] + 8'd128;
                crc = crc ^ value;
                for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                    crc = (crc >> 1) ^ (32'hedb8_8320 & (0 - (crc & 1)));
            end
            output_crc = ~crc;
        end
    endfunction

    task automatic upload_frame(
        input integer frame,
        input integer frame_id,
        input integer original_width,
        input integer original_height
    );
        logic [31:0] response_id, response_offset, response_length;
        logic [31:0] status, response_tag;
        integer offset;
        begin
            send_uart_byte("U"); send_uart_byte("P");
            send_uart_byte("L"); send_uart_byte("2");
            send_u32(frame_id);
            send_u16(original_width); send_u16(original_height);
            send_u16(8); send_u16(8);
            send_u32(FRAME_BYTES); send_u32(frame_crc(frame));
            offset = 0;
            while (offset < FRAME_BYTES) begin
                expect_tag({"2","Y","D","R"});
                receive_u32(response_id);
                receive_u32(response_offset);
                receive_u32(response_length);
                if (response_id != frame_id || response_offset != offset ||
                    response_length == 0 ||
                    response_length > FRAME_BYTES - offset)
                    $fatal(1,
                        "RDY2 mismatch id=%0d offset=%0d length=%0d expected_offset=%0d",
                        response_id, response_offset, response_length, offset);
                // The byte tap fires when RDY2 enters the UART TX engine;
                // model the remaining serial wire time before host payload.
                repeat (12 * UART_BIT_CYCLES) @(posedge clk);
                for (int index = 0; index < response_length; index++)
                    send_uart_byte(tiled[frame][offset + index]);
                offset = offset + response_length;
            end
            receive_u32(response_tag);
            receive_u32(response_id); receive_u32(status);
            if (response_tag == {"2","K","A","N"}) begin
                $fdisplay(log_fd,
                    "UPLOAD NAK frame=%0d status=%0d DMA_STATUS=%08x IOMMU_FAULT=%08x",
                    response_id, status,
                    {29'd0, dut.dma_iommu_inst.dma_fault,
                     dut.dma_iommu_inst.dma_done,
                     dut.dma_iommu_inst.control_busy},
                    {24'd0, dut.dma_iommu_inst.regs_inst.fault_code_sticky_q});
                $fatal(1, "Firmware rejected upload id=%0d status=%0d",
                       response_id, status);
            end
            if (response_tag != {"2","K","C","A"})
                $fatal(1, "Unexpected upload response tag=%08x", response_tag);
            if (response_id != frame_id || status != 0)
                $fatal(1, "Upload rejected id=%0d status=%0d", response_id, status);
            repeat (12 * UART_BIT_CYCLES) @(posedge clk);
            $fdisplay(log_fd,
                "UPLOAD PASS frame=%0d original=%0dx%0d padded=8x8 bytes=64 crc=%08x",
                frame_id, original_width, original_height, frame_crc(frame));
        end
    endtask

    task automatic receive_frame(
        input integer frame,
        input integer expected_id,
        input integer expected_width,
        input integer expected_height
    );
        logic [31:0] frame_id, length, crc, actual_crc;
        integer ow, oh, pw, ph;
        logic [7:0] value;
        integer bit_index;
        begin
            expect_tag({"2","T","U","O"});
            receive_u32(frame_id);
            receive_u16(ow); receive_u16(oh);
            receive_u16(pw); receive_u16(ph);
            receive_u32(length); receive_u32(crc);
            actual_crc = 32'hffff_ffff;
            if (frame_id != expected_id || ow != expected_width ||
                oh != expected_height || pw != 8 || ph != 8 ||
                length != FRAME_BYTES)
                $fatal(1, "Output header mismatch for frame %0d", expected_id);
            for (int index = 0; index < FRAME_BYTES; index++) begin
                receive_byte(value);
                if (value !== (tiled[frame][index] + 8'd128)) begin
                    errors = errors + 1;
                    if (errors < 12)
                        $fdisplay(log_fd,
                            "PIXEL ERROR frame=%0d index=%0d got=%02x expected=%02x",
                            expected_id, index, value,
                            tiled[frame][index] + 8'd128);
                end
                actual_crc = actual_crc ^ value;
                for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                    actual_crc = (actual_crc >> 1) ^
                                 (32'hedb8_8320 & (0 - (actual_crc & 1)));
            end
            actual_crc = ~actual_crc;
            expect_tag({"S","S","A","P"});
            if (crc !== actual_crc || actual_crc !== output_crc(frame))
                $fatal(1, "Output CRC mismatch for frame %0d", expected_id);
            $fdisplay(log_fd,
                "OUTPUT PASS frame=%0d original=%0dx%0d bytes=64 crc=%08x",
                expected_id, expected_width, expected_height, actual_crc);
        end
    endtask

    task automatic receive_perf_report;
        logic [31:0] version, clock_hz, mode, count;
        logic [31:0] transfer_type, commands, payload_bytes;
        logic [31:0] command_cycles, src_bytes, src_span;
        logic [31:0] dst_bytes, dst_span;
        logic [31:0] axi_r_bytes, axi_r_cycles;
        logic [31:0] axi_w_bytes, axi_w_cycles;
        begin
            expect_tag({"1","F","R","P"});
            receive_u32(version);
            receive_u32(clock_hz);
            receive_u32(mode);
            receive_u32(count);
            if (version != 1 || clock_hz != 150_000_000 || count != 3)
                $fatal(1,
                    "Performance header mismatch version=%0d clock=%0d mode=%0d count=%0d",
                    version, clock_hz, mode, count);
            if (mode != EXPECTED_DMA_MODE)
                $fatal(1,
                    "DMA mode mismatch: firmware=%0d expected=%0d",
                    mode, EXPECTED_DMA_MODE);

            for (int expected_type = 0; expected_type < 3; expected_type++) begin
                receive_u32(transfer_type);
                receive_u32(commands);
                receive_u32(payload_bytes);
                receive_u32(command_cycles);
                receive_u32(src_bytes);
                receive_u32(src_span);
                receive_u32(dst_bytes);
                receive_u32(dst_span);
                receive_u32(axi_r_bytes);
                receive_u32(axi_r_cycles);
                receive_u32(axi_w_bytes);
                receive_u32(axi_w_cycles);
                if (transfer_type != expected_type || commands == 0 ||
                    payload_bytes == 0 || command_cycles == 0 ||
                    src_bytes == 0 || src_span == 0 ||
                    dst_bytes == 0 || dst_span == 0)
                    $fatal(1,
                        "Invalid performance record type=%0d commands=%0d payload=%0d cycles=%0d",
                        transfer_type, commands, payload_bytes, command_cycles);
                if (expected_type == 0 &&
                    (axi_r_bytes == 0 || axi_r_cycles == 0 ||
                     axi_w_bytes == 0 || axi_w_cycles == 0))
                    $fatal(1, "M2M AXI counters are incomplete");
                if (expected_type == 1 &&
                    (axi_r_bytes != 0 || axi_r_cycles != 0 ||
                     axi_w_bytes == 0 || axi_w_cycles == 0))
                    $fatal(1, "S2M AXI counters are incorrect");
                if (expected_type == 2 &&
                    (axi_r_bytes == 0 || axi_r_cycles == 0 ||
                     axi_w_bytes != 0 || axi_w_cycles != 0))
                    $fatal(1, "M2S AXI counters are incorrect");
                $fdisplay(log_fd,
                    "PERF type=%0d commands=%0d payload=%0d command_cycles=%0d src=%0d/%0d dst=%0d/%0d axi_r=%0d/%0d axi_w=%0d/%0d",
                    transfer_type, commands, payload_bytes, command_cycles,
                    src_bytes, src_span, dst_bytes, dst_span,
                    axi_r_bytes, axi_r_cycles, axi_w_bytes, axi_w_cycles);
            end
        end
    endtask

    initial begin : test_sequence
        logic [31:0] capacity, completed;
        integer tile_y, tile_x, row, col, src_index, dst_index;

        log_fd = $fopen("uart_image_batch_soc_test.log", "w");

        // Frame 1 is a 7x5 image padded to 8x8 with neutral gray.  Frame 2
        // fills 8x8.  Values differ so slot/address aliasing is detected.
        for (int index = 0; index < FRAME_BYTES; index++) begin
            raster[0][index] = 8'd128;
            raster[1][index] = (index * 3 + 17) & 8'hff;
        end
        for (int y = 0; y < 5; y++)
            for (int x = 0; x < 7; x++)
                raster[0][y*8+x] = (y * 29 + x * 7 + 3) & 8'hff;

        for (int frame = 0; frame < 2; frame++) begin
            dst_index = 0;
            for (tile_y = 0; tile_y < 8; tile_y = tile_y + 4)
                for (tile_x = 0; tile_x < 8; tile_x = tile_x + 4)
                    for (row = 0; row < 4; row = row + 1)
                        for (col = 0; col < 4; col = col + 1) begin
                            src_index = (tile_y + row) * 8 + tile_x + col;
                            tiled[frame][dst_index] = raster[frame][src_index] - 8'd128;
                            dst_index = dst_index + 1;
                        end
        end

        repeat (12) @(posedge clk);
        rst_n <= 1'b1;

        expect_tag({"1","H","C","B"});
        receive_u32(capacity);
        if (capacity != 4)
            $fatal(1, "Unexpected batch capacity %0d", capacity);
        // tx_byte_valid marks acceptance by the UART engine, whereas a PC
        // sees that byte only after all ten serial bits have left the pin.
        // Model that wire-time before the host starts transmitting UPL2.
        repeat (12 * UART_BIT_CYCLES) @(posedge clk);

        upload_frame(0, 101, 7, 5);
        // The fast simulation UART (divider 32) can deliver a new start bit
        // much sooner than the real 115200-baud VC707 link.  Leave the CPU
        // enough time to return from ACK generation to its command parser so
        // the next UPL2 marker cannot be mistaken for residual serial data.
        repeat (2048) @(posedge clk);
        upload_frame(1, 202, 8, 8);

        send_uart_byte("R"); send_uart_byte("U");
        send_uart_byte("N"); send_uart_byte("1");
        send_u32(2);

        receive_frame(0, 101, 7, 5);
        receive_frame(1, 202, 8, 8);
        receive_perf_report();
        expect_tag({"E","N","O","D"});
        receive_u32(completed);
        if (completed != 2 || errors != 0)
            $fatal(1, "Batch failed completed=%0d errors=%0d", completed, errors);

        // Confirm the compact DDR model contains both real high-address input
        // slots and both output slots.  Input and output remain in tile order;
        // the PC performs untile/crop when reconstructing the original PNG.
        for (int word_index = 0; word_index < 16; word_index++) begin
            if (ddr_ram_inst.mem[(20'h00000 >> 2) + word_index] !==
                {tiled[0][word_index*4+3], tiled[0][word_index*4+2],
                 tiled[0][word_index*4+1], tiled[0][word_index*4]})
                $fatal(1, "DDR input slot 0 mismatch word=%0d", word_index);
            if (ddr_ram_inst.mem[(20'h10000 >> 2) + word_index] !==
                {tiled[1][word_index*4+3], tiled[1][word_index*4+2],
                 tiled[1][word_index*4+1], tiled[1][word_index*4]})
                $fatal(1, "DDR input slot 1 mismatch word=%0d", word_index);
            if (ddr_ram_inst.mem[(20'h80000 >> 2) + word_index] !==
                {tiled[0][word_index*4+3] + 8'd128,
                 tiled[0][word_index*4+2] + 8'd128,
                 tiled[0][word_index*4+1] + 8'd128,
                 tiled[0][word_index*4]   + 8'd128})
                $fatal(1, "DDR output slot 0 mismatch word=%0d", word_index);
            if (ddr_ram_inst.mem[(20'h90000 >> 2) + word_index] !==
                {tiled[1][word_index*4+3] + 8'd128,
                 tiled[1][word_index*4+2] + 8'd128,
                 tiled[1][word_index*4+1] + 8'd128,
                 tiled[1][word_index*4]   + 8'd128})
                $fatal(1, "DDR output slot 1 mismatch word=%0d", word_index);
        end

        // Start another batch without resetting the SoC.  Inject the exact
        // stray 0x00 seen on the physical VC707 USB-UART link and prove that
        // firmware re-synchronizes to the following UPL2 marker.
        expect_tag({"1","H","C","B"});
        receive_u32(capacity);
        if (capacity != 4)
            $fatal(1, "Unexpected second-batch capacity %0d", capacity);
        repeat (12 * UART_BIT_CYCLES) @(posedge clk);
        send_uart_byte(8'h00);
        upload_frame(0, 303, 7, 5);
        send_uart_byte("R"); send_uart_byte("U");
        send_uart_byte("N"); send_uart_byte("1");
        send_u32(1);
        receive_frame(0, 303, 7, 5);
        receive_perf_report();
        expect_tag({"E","N","O","D"});
        receive_u32(completed);
        if (completed != 1 || errors != 0)
            $fatal(1, "Second batch failed completed=%0d errors=%0d",
                   completed, errors);
        $fdisplay(log_fd,
            "SECOND BATCH RESYNC PASS: ignored injected byte 00 before UPL2");

        finished = 1'b1;
        $fdisplay(log_fd, "MULTI-IMAGE UART/DMA/SYSTOLIC SOC TEST PASSED");
        $fdisplay(log_fd, "Frames=2; UART RX -> DMA S2M -> RAM -> DMA M2M -> RAM");
        $fdisplay(log_fd, "RAM -> DMA M2S -> Systolic -> DMA S2M -> RAM -> DMA M2S -> UART TX");
        case (EXPECTED_DMA_MODE)
            0: $fdisplay(log_fd,
                "DMA directions exercised: S2M, M2M, M2S; image mode: BURST");
            1: $fdisplay(log_fd,
                "DMA directions exercised: S2M, M2M, M2S; image mode: CYCLE-STEALING");
            2: $fdisplay(log_fd,
                "DMA directions exercised: S2M, M2M, M2S; image mode: TRANSPARENT");
            default: $fatal(1, "Unsupported EXPECTED_DMA_MODE=%0d", EXPECTED_DMA_MODE);
        endcase
        $fclose(log_fd);
        $display("MULTI-IMAGE UART/DMA/SYSTOLIC SOC TEST PASSED");
        $finish;
    end

    initial begin
        #100_000_000;
        if (!finished) begin
            $fdisplay(log_fd,
                "TIMEOUT pc=%08x tx_read=%0d tx_write=%0d trap=%0b",
                dut.cpu_inst.picorv32_core.reg_pc, tx_read, tx_write, cpu_trap);
            $fatal(1, "Multi-image SoC timeout");
        end
    end
endmodule
