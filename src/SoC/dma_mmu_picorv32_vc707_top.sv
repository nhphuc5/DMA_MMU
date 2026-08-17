`timescale 1ns / 1ps

// Board-level wrapper for the AMD/Xilinx VC707 evaluation board.
//
// VC707 provides a 200 MHz differential system clock.  The MMCM converts it
// to the 150 MHz clock used by the verified PicoRV32 + DMA/IOMMU SoC.  The
// original SoC remains board-independent and is instantiated unchanged.
module dma_mmu_picorv32_vc707_top #(
    parameter MEM_INIT_FILE = "",
    // Keep 16 as the compatibility default.  The final image-processing
    // build overrides this to 18 for a 256 KiB on-chip AXI RAM.
    parameter integer SOC_AXI_ADDR_WIDTH = 16
) (
    input  wire       sys_clk_p,
    input  wire       sys_clk_n,
    input  wire       cpu_reset,
    input  wire       uart_rx_i,
    output wire       uart_tx_o,
    output wire [3:0] led_o
);

    wire clk_200mhz;
    wire mmcm_clkfb_unbuf;
    wire mmcm_clkfb;
    wire mmcm_clk150_unbuf;
    wire clk_150mhz;
    wire mmcm_locked;

    IBUFDS #(
        .DIFF_TERM("TRUE"),
        .IBUF_LOW_PWR("FALSE"),
        .IOSTANDARD("LVDS")
    ) sysclk_ibufds_inst (
        .I(sys_clk_p),
        .IB(sys_clk_n),
        .O(clk_200mhz)
    );

    // 200 MHz * 3 / 1 / 4 = 150 MHz; MMCM VCO = 600 MHz.
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(5.000),
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(3.000),
        .CLKOUT0_DIVIDE_F(4.000),
        .STARTUP_WAIT("FALSE")
    ) sysclk_mmcm_inst (
        .CLKIN1(clk_200mhz),
        .CLKFBIN(mmcm_clkfb),
        .RST(cpu_reset),
        .PWRDWN(1'b0),
        .CLKFBOUT(mmcm_clkfb_unbuf),
        .CLKOUT0(mmcm_clk150_unbuf),
        .LOCKED(mmcm_locked),
        .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(),
        .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(),
        .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB()
    );

    BUFG mmcm_feedback_bufg_inst (
        .I(mmcm_clkfb_unbuf),
        .O(mmcm_clkfb)
    );

    BUFG soc_clock_bufg_inst (
        .I(mmcm_clk150_unbuf),
        .O(clk_150mhz)
    );

    // Reset asserts asynchronously when the push button is pressed or the
    // MMCM loses lock, then releases synchronously after three SoC clocks.
    wire reset_async = cpu_reset | ~mmcm_locked;
    reg [2:0] reset_pipe = 3'b111;
    always @(posedge clk_150mhz or posedge reset_async) begin
        if (reset_async)
            reset_pipe <= 3'b111;
        else
            reset_pipe <= {reset_pipe[1:0], 1'b0};
    end
    wire soc_rst_ni = ~reset_pipe[2];

    wire cpu_trap;
    wire dma_irq;
    wire uart_irq;
    wire [7:0] uart_tx_byte_unused;
    wire uart_tx_byte_valid_unused;

    dma_mmu_picorv32_soc #(
        .AXI_ADDR_WIDTH(SOC_AXI_ADDR_WIDTH),
        .UART_DEFAULT_DIV(1300),
        .MEM_INIT_FILE(MEM_INIT_FILE)
    ) soc_inst (
        .clk_i(clk_150mhz),
        .rst_ni(soc_rst_ni),
        .uart_rx_i(uart_rx_i),
        .uart_tx_o(uart_tx_o),
        .cpu_trap_o(cpu_trap),
        .dma_irq_o(dma_irq),
        .uart_irq_o(uart_irq),
        .uart_tx_byte_o(uart_tx_byte_unused),
        .uart_tx_byte_valid_o(uart_tx_byte_valid_unused)
    );

    // Simple board-level observability.  DONE/FAULT remain available through
    // UART and registers; these LEDs are only live indicators.
    assign led_o[0] = mmcm_locked;
    assign led_o[1] = cpu_trap;
    assign led_o[2] = dma_irq;
    assign led_o[3] = uart_irq;

endmodule
