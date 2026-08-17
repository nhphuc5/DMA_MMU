`timescale 1ns / 1ps

// Byte-exact 50 KiB system regression:
//   host TXT -> physical 8N1 UART RX -> UART AXI-Stream -> DMA/IOMMU
//   -> AXI4-Full -> AXI RAM
//
// This test does not manufacture the destination data.  Every destination
// byte must be written by a real UART receive frame and a real DMA/AXI write
// handshake before the self-checker can pass.
module tb_uart_file_to_memory;

    localparam int AXI_ADDR_WIDTH = 16;
    localparam int AXI_DATA_WIDTH = 32;
    localparam int AXI_ID_WIDTH = 4;
    localparam int M_AXI_ID_WIDTH = AXI_ID_WIDTH+1;
    localparam int PAYLOAD_BYTES = 50*1024;
    localparam int DEST_BASE = 16'h1000;
    localparam int UART_DIVIDER = 4;
    localparam int UART_BIT_CYCLES = UART_DIVIDER+2;
    localparam real CLK_PERIOD_NS = 6.667;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;

    // DMA control AXI4-Lite BFM
    logic [7:0] d_awaddr, d_araddr;
    logic [2:0] d_awprot, d_arprot;
    logic d_awvalid, d_wvalid, d_bready, d_arvalid, d_rready;
    logic [31:0] d_wdata;
    logic [3:0] d_wstrb;
    wire d_awready, d_wready, d_bvalid, d_arready, d_rvalid;
    wire [1:0] d_bresp, d_rresp;
    wire [31:0] d_rdata;
    wire dma_irq;

    // UART control AXI4-Lite BFM
    logic [7:0] u_awaddr, u_araddr;
    logic [2:0] u_awprot, u_arprot;
    logic u_awvalid, u_wvalid, u_bready, u_arvalid, u_rready;
    logic [31:0] u_wdata;
    logic [3:0] u_wstrb;
    wire u_awready, u_wready, u_bvalid, u_arready, u_rvalid;
    wire [1:0] u_bresp, u_rresp;
    wire [31:0] u_rdata;
    wire uart_irq, uart_tx;
    logic uart_rx = 1'b1;

    // UART <-> DMA AXI4-Stream
    wire [31:0] uart_rx_tdata;
    wire [3:0] uart_rx_tkeep;
    wire uart_rx_tvalid, uart_rx_tready, uart_rx_tlast;
    wire [31:0] dma_tx_tdata;
    wire [3:0] dma_tx_tkeep;
    wire dma_tx_tvalid, dma_tx_tready, dma_tx_tlast;

    // DMA AXI4-Full master -> AXI RAM controller
    wire [M_AXI_ID_WIDTH-1:0] m_axi_awid, m_axi_bid;
    wire [AXI_ADDR_WIDTH-1:0] m_axi_awaddr, m_axi_araddr;
    wire [7:0] m_axi_awlen, m_axi_arlen;
    wire [2:0] m_axi_awsize, m_axi_arsize;
    wire [1:0] m_axi_awburst, m_axi_arburst;
    wire m_axi_awlock, m_axi_arlock;
    wire [3:0] m_axi_awcache, m_axi_arcache;
    wire [2:0] m_axi_awprot, m_axi_arprot;
    wire [3:0] m_axi_awqos, m_axi_arqos;
    wire [3:0] m_axi_awregion, m_axi_arregion;
    wire m_axi_awvalid, m_axi_awready;
    wire [AXI_DATA_WIDTH-1:0] m_axi_wdata, m_axi_rdata;
    wire [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb;
    wire m_axi_wlast, m_axi_wvalid, m_axi_wready;
    wire [1:0] m_axi_bresp, m_axi_rresp;
    wire m_axi_bvalid, m_axi_bready;
    wire [M_AXI_ID_WIDTH-1:0] m_axi_arid, m_axi_rid;
    wire m_axi_arvalid, m_axi_arready;
    wire m_axi_rlast, m_axi_rvalid, m_axi_rready;

    byte unsigned source_data [0:PAYLOAD_BYTES-1];
    string input_path;
    string log_path;
    integer log_fd;
    integer errors;
    integer serial_bytes_sent;
    integer axis_bytes_accepted;
    integer axi_bytes_written;
    integer axi_aw_bursts;
    integer max_awlen;
    longint unsigned cycle_count;
    longint unsigned start_cycle;
    longint unsigned done_cycle;

    dma_mmu_axi_top #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .AXIL_ADDR_WIDTH(8),
        .LEN_WIDTH(16),
        .PAGE_SHIFT(12),
        .PT_ENTRIES(16),
        .TLB_ENTRIES(4),
        .AXI_MAX_BURST_LEN(16)
    ) dma_inst (
        .aclk(clk), .aresetn(rst_n), .cpu_bus_idle_i(1'b1), .irq_o(dma_irq),
        .s_axil_awaddr(d_awaddr), .s_axil_awprot(d_awprot),
        .s_axil_awvalid(d_awvalid), .s_axil_awready(d_awready),
        .s_axil_wdata(d_wdata), .s_axil_wstrb(d_wstrb),
        .s_axil_wvalid(d_wvalid), .s_axil_wready(d_wready),
        .s_axil_bresp(d_bresp), .s_axil_bvalid(d_bvalid),
        .s_axil_bready(d_bready), .s_axil_araddr(d_araddr),
        .s_axil_arprot(d_arprot), .s_axil_arvalid(d_arvalid),
        .s_axil_arready(d_arready), .s_axil_rdata(d_rdata),
        .s_axil_rresp(d_rresp), .s_axil_rvalid(d_rvalid),
        .s_axil_rready(d_rready),
        .m_axi_awid, .m_axi_awaddr, .m_axi_awlen, .m_axi_awsize,
        .m_axi_awburst, .m_axi_awlock, .m_axi_awcache, .m_axi_awprot,
        .m_axi_awqos, .m_axi_awregion, .m_axi_awvalid, .m_axi_awready,
        .m_axi_wdata, .m_axi_wstrb, .m_axi_wlast, .m_axi_wvalid,
        .m_axi_wready, .m_axi_bid, .m_axi_bresp, .m_axi_bvalid,
        .m_axi_bready, .m_axi_arid, .m_axi_araddr, .m_axi_arlen,
        .m_axi_arsize, .m_axi_arburst, .m_axi_arlock, .m_axi_arcache,
        .m_axi_arprot, .m_axi_arqos, .m_axi_arregion, .m_axi_arvalid,
        .m_axi_arready, .m_axi_rid, .m_axi_rdata, .m_axi_rresp,
        .m_axi_rlast, .m_axi_rvalid, .m_axi_rready,
        .s_axis_periph_tdata(uart_rx_tdata),
        .s_axis_periph_tkeep(uart_rx_tkeep),
        .s_axis_periph_tvalid(uart_rx_tvalid),
        .s_axis_periph_tready(uart_rx_tready),
        .s_axis_periph_tlast(uart_rx_tlast),
        .m_axis_periph_tdata(dma_tx_tdata),
        .m_axis_periph_tkeep(dma_tx_tkeep),
        .m_axis_periph_tvalid(dma_tx_tvalid),
        .m_axis_periph_tready(dma_tx_tready),
        .m_axis_periph_tlast(dma_tx_tlast)
    );

    wire [7:0] uart_apb_paddr;
    wire uart_apb_psel;
    wire uart_apb_penable;
    wire uart_apb_pwrite;
    wire [31:0] uart_apb_pwdata;
    wire [3:0] uart_apb_pstrb;
    wire [31:0] uart_apb_prdata;
    wire uart_apb_pready;
    wire uart_apb_pslverr;

    axil_to_apb_bridge #(
        .ADDR_WIDTH(8),
        .DATA_WIDTH(32)
    ) uart_bridge_inst (
        .clk_i(clk), .rst_ni(rst_n),
        .s_axil_awaddr(u_awaddr), .s_axil_awprot(u_awprot),
        .s_axil_awvalid(u_awvalid), .s_axil_awready(u_awready),
        .s_axil_wdata(u_wdata), .s_axil_wstrb(u_wstrb),
        .s_axil_wvalid(u_wvalid), .s_axil_wready(u_wready),
        .s_axil_bresp(u_bresp), .s_axil_bvalid(u_bvalid),
        .s_axil_bready(u_bready), .s_axil_araddr(u_araddr),
        .s_axil_arprot(u_arprot), .s_axil_arvalid(u_arvalid),
        .s_axil_arready(u_arready), .s_axil_rdata(u_rdata),
        .s_axil_rresp(u_rresp), .s_axil_rvalid(u_rvalid),
        .s_axil_rready(u_rready),
        .m_apb_paddr(uart_apb_paddr), .m_apb_psel(uart_apb_psel),
        .m_apb_penable(uart_apb_penable), .m_apb_pwrite(uart_apb_pwrite),
        .m_apb_pwdata(uart_apb_pwdata), .m_apb_pstrb(uart_apb_pstrb),
        .m_apb_prdata(uart_apb_prdata), .m_apb_pready(uart_apb_pready),
        .m_apb_pslverr(uart_apb_pslverr)
    );

    uart_apb_axis #(
        .APB_ADDR_WIDTH(8),
        .DEFAULT_DIV(UART_DIVIDER)
    ) uart_inst (
        .clk_i(clk), .rst_ni(rst_n),
        .s_apb_paddr(uart_apb_paddr), .s_apb_psel(uart_apb_psel),
        .s_apb_penable(uart_apb_penable), .s_apb_pwrite(uart_apb_pwrite),
        .s_apb_pwdata(uart_apb_pwdata), .s_apb_pstrb(uart_apb_pstrb),
        .s_apb_prdata(uart_apb_prdata), .s_apb_pready(uart_apb_pready),
        .s_apb_pslverr(uart_apb_pslverr),
        .s_axis_tx_tdata(dma_tx_tdata), .s_axis_tx_tkeep(dma_tx_tkeep),
        .s_axis_tx_tvalid(dma_tx_tvalid), .s_axis_tx_tready(dma_tx_tready),
        .s_axis_tx_tlast(dma_tx_tlast),
        .m_axis_rx_tdata(uart_rx_tdata), .m_axis_rx_tkeep(uart_rx_tkeep),
        .m_axis_rx_tvalid(uart_rx_tvalid), .m_axis_rx_tready(uart_rx_tready),
        .m_axis_rx_tlast(uart_rx_tlast),
        .uart_tx_o(uart_tx), .uart_rx_i(uart_rx), .irq_o(uart_irq),
        .tx_byte_o(), .tx_byte_valid_o()
    );

    axi_ram #(
        .DATA_WIDTH(AXI_DATA_WIDTH), .ADDR_WIDTH(AXI_ADDR_WIDTH),
        .STRB_WIDTH(AXI_DATA_WIDTH/8), .ID_WIDTH(M_AXI_ID_WIDTH),
        .PIPELINE_OUTPUT(0)
    ) mem_inst (
        .clk(clk), .rst(!rst_n),
        .s_axi_awid(m_axi_awid), .s_axi_awaddr(m_axi_awaddr),
        .s_axi_awlen(m_axi_awlen), .s_axi_awsize(m_axi_awsize),
        .s_axi_awburst(m_axi_awburst), .s_axi_awlock(m_axi_awlock),
        .s_axi_awcache(m_axi_awcache), .s_axi_awprot(m_axi_awprot),
        .s_axi_awvalid(m_axi_awvalid), .s_axi_awready(m_axi_awready),
        .s_axi_wdata(m_axi_wdata), .s_axi_wstrb(m_axi_wstrb),
        .s_axi_wlast(m_axi_wlast), .s_axi_wvalid(m_axi_wvalid),
        .s_axi_wready(m_axi_wready), .s_axi_bid(m_axi_bid),
        .s_axi_bresp(m_axi_bresp), .s_axi_bvalid(m_axi_bvalid),
        .s_axi_bready(m_axi_bready), .s_axi_arid(m_axi_arid),
        .s_axi_araddr(m_axi_araddr), .s_axi_arlen(m_axi_arlen),
        .s_axi_arsize(m_axi_arsize), .s_axi_arburst(m_axi_arburst),
        .s_axi_arlock(m_axi_arlock), .s_axi_arcache(m_axi_arcache),
        .s_axi_arprot(m_axi_arprot), .s_axi_arvalid(m_axi_arvalid),
        .s_axi_arready(m_axi_arready), .s_axi_rid(m_axi_rid),
        .s_axi_rdata(m_axi_rdata), .s_axi_rresp(m_axi_rresp),
        .s_axi_rlast(m_axi_rlast), .s_axi_rvalid(m_axi_rvalid),
        .s_axi_rready(m_axi_rready)
    );

    function automatic integer keep_count(input logic [3:0] keep);
        keep_count = keep[0]+keep[1]+keep[2]+keep[3];
    endfunction

    function automatic [7:0] ram_byte(input integer byte_addr);
        logic [31:0] word_value;
        begin
            word_value = mem_inst.mem[byte_addr >> 2];
            case (byte_addr[1:0])
                2'd0: ram_byte = word_value[7:0];
                2'd1: ram_byte = word_value[15:8];
                2'd2: ram_byte = word_value[23:16];
                default: ram_byte = word_value[31:24];
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_count <= 0;
            axis_bytes_accepted <= 0;
            axi_bytes_written <= 0;
            axi_aw_bursts <= 0;
            max_awlen <= 0;
        end else begin
            cycle_count <= cycle_count+1;
            if (uart_rx_tvalid && uart_rx_tready)
                axis_bytes_accepted <= axis_bytes_accepted+
                                       keep_count(uart_rx_tkeep);
            if (m_axi_wvalid && m_axi_wready)
                axi_bytes_written <= axi_bytes_written+
                                     keep_count(m_axi_wstrb);
            if (m_axi_awvalid && m_axi_awready) begin
                axi_aw_bursts <= axi_aw_bursts+1;
                if (m_axi_awlen > max_awlen)
                    max_awlen <= m_axi_awlen;
            end
        end
    end

    task automatic report_error(input string message);
        begin
            errors = errors+1;
            $display("ERROR: %s", message);
            if (log_fd)
                $fdisplay(log_fd, "ERROR: %s", message);
        end
    endtask

    task automatic dma_write(input [7:0] addr, input [31:0] data);
        bit aw_done;
        bit w_done;
        begin
            aw_done = 0;
            w_done = 0;
            @(posedge clk);
            d_awaddr <= addr;
            d_awvalid <= 1'b1;
            d_wdata <= data;
            d_wstrb <= 4'hf;
            d_wvalid <= 1'b1;
            d_bready <= 1'b1;
            while (!(aw_done && w_done)) begin
                @(posedge clk);
                if (!aw_done && d_awvalid && d_awready) begin
                    aw_done = 1;
                    d_awvalid <= 1'b0;
                end
                if (!w_done && d_wvalid && d_wready) begin
                    w_done = 1;
                    d_wvalid <= 1'b0;
                end
            end
            while (!d_bvalid) @(posedge clk);
            if (d_bresp != 2'b00)
                report_error($sformatf("DMA AXI-Lite write response=%0d", d_bresp));
            @(posedge clk);
            d_bready <= 1'b0;
        end
    endtask

    task automatic dma_read(input [7:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            d_araddr <= addr;
            d_arvalid <= 1'b1;
            d_rready <= 1'b1;
            while (!(d_arvalid && d_arready)) @(posedge clk);
            @(posedge clk);
            d_arvalid <= 1'b0;
            while (!d_rvalid) @(posedge clk);
            data = d_rdata;
            if (d_rresp != 2'b00)
                report_error($sformatf("DMA AXI-Lite read response=%0d", d_rresp));
            @(posedge clk);
            d_rready <= 1'b0;
        end
    endtask

    task automatic uart_write(input [7:0] addr, input [31:0] data);
        bit aw_done;
        bit w_done;
        begin
            aw_done = 0;
            w_done = 0;
            @(posedge clk);
            u_awaddr <= addr;
            u_awvalid <= 1'b1;
            u_wdata <= data;
            u_wstrb <= 4'hf;
            u_wvalid <= 1'b1;
            u_bready <= 1'b1;
            while (!(aw_done && w_done)) begin
                @(posedge clk);
                if (!aw_done && u_awvalid && u_awready) begin
                    aw_done = 1;
                    u_awvalid <= 1'b0;
                end
                if (!w_done && u_wvalid && u_wready) begin
                    w_done = 1;
                    u_wvalid <= 1'b0;
                end
            end
            while (!u_bvalid) @(posedge clk);
            if (u_bresp != 2'b00)
                report_error($sformatf("UART AXI-Lite write response=%0d", u_bresp));
            @(posedge clk);
            u_bready <= 1'b0;
        end
    endtask

    task automatic uart_read(input [7:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            u_araddr <= addr;
            u_arvalid <= 1'b1;
            u_rready <= 1'b1;
            while (!(u_arvalid && u_arready)) @(posedge clk);
            @(posedge clk);
            u_arvalid <= 1'b0;
            while (!u_rvalid) @(posedge clk);
            data = u_rdata;
            if (u_rresp != 2'b00)
                report_error($sformatf("UART AXI-Lite read response=%0d", u_rresp));
            @(posedge clk);
            u_rready <= 1'b0;
        end
    endtask

    task automatic program_identity_page(input integer page);
        begin
            dma_write(8'h20, page);
            dma_write(8'h24, page);
            dma_write(8'h28, page);
            dma_write(8'h2c, 32'h0000_0007); // valid + read + write
        end
    endtask

    task automatic send_uart_byte(input logic [7:0] value);
        integer bit_index;
        begin
            uart_rx <= 1'b0;
            repeat (UART_BIT_CYCLES) @(negedge clk);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index+1) begin
                uart_rx <= value[bit_index];
                repeat (UART_BIT_CYCLES) @(negedge clk);
            end
            uart_rx <= 1'b1;
            repeat (UART_BIT_CYCLES) @(negedge clk);
            serial_bytes_sent = serial_bytes_sent+1;
        end
    endtask

    initial begin : run_test
        integer file_fd;
        integer value;
        integer index;
        integer mismatch_count;
        integer first_mismatch;
        integer source_checksum;
        integer memory_checksum;
        integer timeout;
        reg [31:0] dma_status;
        reg [31:0] uart_status;
        real elapsed_us;
        real payload_mbps;

        errors = 0;
        serial_bytes_sent = 0;
        input_path = "D:/DMA_MMU-main(1)/testdata/uart_input_50k.txt";
        log_path = "D:/DMA_MMU-main(1)/reports/uart_file_to_memory_50k.log";
        value = $value$plusargs("UART_FILE=%s", input_path);
        value = $value$plusargs("UART_LOG=%s", log_path);

        log_fd = $fopen(log_path, "w");
        file_fd = $fopen(input_path, "rb");
        if (file_fd == 0) begin
            $fatal(1, "Cannot open UART input file: %s", input_path);
        end
        index = 0;
        while (!$feof(file_fd) && index < PAYLOAD_BYTES) begin
            value = $fgetc(file_fd);
            if (value >= 0) begin
                source_data[index] = value[7:0];
                index = index+1;
            end
        end
        if (index != PAYLOAD_BYTES || $fgetc(file_fd) != -1)
            $fatal(1, "Input must be exactly %0d bytes; read=%0d", PAYLOAD_BYTES, index);
        $fclose(file_fd);

        d_awaddr = 0; d_awprot = 0; d_awvalid = 0;
        d_wdata = 0; d_wstrb = 0; d_wvalid = 0; d_bready = 0;
        d_araddr = 0; d_arprot = 0; d_arvalid = 0; d_rready = 0;
        u_awaddr = 0; u_awprot = 0; u_awvalid = 0;
        u_wdata = 0; u_wstrb = 0; u_wvalid = 0; u_bready = 0;
        u_araddr = 0; u_arprot = 0; u_arvalid = 0; u_rready = 0;

        repeat (12) @(posedge clk);
        rst_n <= 1'b1;
        repeat (12) @(posedge clk);

        $display("UART 50 KiB FILE-TO-MEMORY TEST START");
        $fdisplay(log_fd, "UART -> AXI-STREAM -> DMA/IOMMU -> AXI4 -> RAM REPORT");
        $fdisplay(log_fd, "Input file: %s", input_path);
        $fdisplay(log_fd, "Payload: %0d bytes (50 KiB)", PAYLOAD_BYTES);
        $fdisplay(log_fd, "Destination VA/PA: 0x%04x..0x%04x", DEST_BASE,
                  DEST_BASE+PAYLOAD_BYTES-1);

        // Initialize the full destination range with a value different from
        // the source.  This makes missing AXI writes visible to the checker.
        for (index = DEST_BASE/4;
             index < (DEST_BASE+PAYLOAD_BYTES)/4; index = index+1)
            mem_inst.mem[index] = 32'hDEAD_BEEF;

        // CPU-like AXI-Lite programming: configure the UART and all 13 pages
        // touched by 0x1000..0xD7FF, then launch S2M in Burst mode.
        uart_write(8'h00, UART_DIVIDER);
        uart_write(8'h0c, 32'h0000_0003); // DMA TX/RX enabled
        for (index = 1; index <= 13; index = index+1)
            program_identity_page(index);
        dma_write(8'h00, 32'h0000_0002); // clear sticky done/fault
        dma_write(8'h08, 32'h0000_0000);
        dma_write(8'h0c, DEST_BASE);
        dma_write(8'h10, PAYLOAD_BYTES);
        dma_write(8'h14, {16'd0, 8'd16, 4'd0, 2'd0, 2'd1});
        dma_write(8'h00, 32'h0000_0001); // START

        start_cycle = cycle_count;
        for (index = 0; index < PAYLOAD_BYTES; index = index+1)
            send_uart_byte(source_data[index]);

        dma_status = 0;
        timeout = 0;
        while (!dma_status[1] && !dma_status[2] && timeout < 200000) begin
            dma_read(8'h04, dma_status);
            timeout = timeout+1;
        end
        done_cycle = cycle_count;
        if (timeout >= 200000)
            report_error("DMA completion timeout");
        if (dma_status[2])
            report_error($sformatf("DMA fault, status=0x%08x", dma_status));

        uart_read(8'h08, uart_status);
        if (uart_status[2])
            report_error("UART RX overrun occurred");

        mismatch_count = 0;
        first_mismatch = -1;
        source_checksum = 0;
        memory_checksum = 0;
        for (index = 0; index < PAYLOAD_BYTES; index = index+1) begin
            source_checksum = source_checksum+source_data[index];
            memory_checksum = memory_checksum+ram_byte(DEST_BASE+index);
            if (ram_byte(DEST_BASE+index) !== source_data[index]) begin
                if (first_mismatch < 0)
                    first_mismatch = index;
                mismatch_count = mismatch_count+1;
            end
        end

        if (serial_bytes_sent != PAYLOAD_BYTES)
            report_error($sformatf("UART serial byte count=%0d", serial_bytes_sent));
        if (axis_bytes_accepted != PAYLOAD_BYTES)
            report_error($sformatf("AXI-Stream byte count=%0d", axis_bytes_accepted));
        if (axi_bytes_written != PAYLOAD_BYTES)
            report_error($sformatf("AXI4 write byte count=%0d", axi_bytes_written));
        if (mismatch_count != 0)
            report_error($sformatf("RAM mismatches=%0d, first offset=0x%0x",
                                   mismatch_count, first_mismatch));

        elapsed_us = real'(done_cycle-start_cycle)*CLK_PERIOD_NS/1000.0;
        payload_mbps = real'(PAYLOAD_BYTES)/elapsed_us;
        $fdisplay(log_fd, "Serial UART bytes sent : %0d", serial_bytes_sent);
        $fdisplay(log_fd, "AXI-Stream bytes accepted: %0d", axis_bytes_accepted);
        $fdisplay(log_fd, "AXI4 bytes written      : %0d", axi_bytes_written);
        $fdisplay(log_fd, "AXI4 write bursts       : %0d", axi_aw_bursts);
        $fdisplay(log_fd, "Maximum AWLEN           : %0d (%0d beats)",
                  max_awlen, max_awlen+1);
        $fdisplay(log_fd, "Source checksum (sum32) : 0x%08x", source_checksum);
        $fdisplay(log_fd, "Memory checksum (sum32) : 0x%08x", memory_checksum);
        $fdisplay(log_fd, "Start-to-done cycles    : %0d", done_cycle-start_cycle);
        $fdisplay(log_fd, "Start-to-done time      : %.3f us", elapsed_us);
        $fdisplay(log_fd, "Effective payload speed : %.3f MB/s", payload_mbps);
        $fdisplay(log_fd, "RAM byte mismatches     : %0d", mismatch_count);
        $fwrite(log_fd, "First 16 input bytes    :");
        for (index = 0; index < 16; index = index+1)
            $fwrite(log_fd, " %02x", source_data[index]);
        $fdisplay(log_fd, "");
        $fwrite(log_fd, "First 16 memory bytes   :");
        for (index = 0; index < 16; index = index+1)
            $fwrite(log_fd, " %02x", ram_byte(DEST_BASE+index));
        $fdisplay(log_fd, "");

        if (errors == 0) begin
            $display("PASS: all %0d UART file bytes reached AXI RAM exactly", PAYLOAD_BYTES);
            $fdisplay(log_fd,
                "PASS: all 51,200 bytes traversed UART/AXIS/DMA/IOMMU/AXI and matched RAM");
        end else begin
            $display("FAIL: UART file transfer errors=%0d", errors);
            $fdisplay(log_fd, "FAIL: errors=%0d", errors);
        end
        $fclose(log_fd);
        #100;
        $finish;
    end

    initial begin
        #100ms;
        $fatal(1, "Global timeout in UART 50 KiB file transfer test");
    end

endmodule
