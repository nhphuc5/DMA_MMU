# Timing constraints for dma_mmu_picorv32_soc.
# High-performance target: 150 MHz on Artix-7 speed grade -1.
# This is a real timing target, not an estimated clock annotation.
create_clock -name sys_clk -period 6.667 [get_ports clk_i]
set_clock_uncertainty 0.100 [get_clocks sys_clk]

# Reset and UART RX are asynchronous external inputs.  Both are handled by
# asynchronous reset logic / a two-flop RX synchronizer inside the RTL.
set_false_path -from [get_ports rst_ni]
set_false_path -from [get_ports uart_rx_i]

# Pin LOC and IOSTANDARD constraints are intentionally not guessed. Add the
# correct PACKAGE_PIN/IOSTANDARD values for your exact FPGA board before
# generating a bitstream. Synthesis and implementation do not require them.
