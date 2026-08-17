# VC707 board constraints for dma_mmu_picorv32_vc707_top.
# Target part: XC7VX485T-2FFG1761C (Vivado: xc7vx485tffg1761-2).

# VC707 configuration bank 0 is powered from VCC1V8_FPGA.  Declaring these
# board properties removes CFGBVS-1 and lets Vivado validate configuration-pin
# I/O compatibility when generating the bitstream.
set_property CFGBVS GND [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]

# 200 MHz differential system clock (SYSCLK_P/N).
set_property PACKAGE_PIN E19 [get_ports sys_clk_p]
set_property PACKAGE_PIN E18 [get_ports sys_clk_n]
set_property IOSTANDARD LVDS [get_ports {sys_clk_p sys_clk_n}]
set_property DIFF_TERM TRUE [get_ports {sys_clk_p sys_clk_n}]
create_clock -name vc707_sysclk_200 -period 5.000 [get_ports sys_clk_p]

# Active-high CPU_RESET push button.
set_property PACKAGE_PIN AV40 [get_ports cpu_reset]
set_property IOSTANDARD LVCMOS18 [get_ports cpu_reset]

# USB-UART bridge.  Board USB_UART_TX drives the FPGA RX input; the FPGA TX
# output drives board USB_UART_RX.
set_property PACKAGE_PIN AU33 [get_ports uart_rx_i]
set_property IOSTANDARD LVCMOS18 [get_ports uart_rx_i]
set_property PACKAGE_PIN AU36 [get_ports uart_tx_o]
set_property IOSTANDARD LVCMOS18 [get_ports uart_tx_o]

# User LEDs 0..3.
set_property PACKAGE_PIN AM39 [get_ports {led_o[0]}]
set_property PACKAGE_PIN AN39 [get_ports {led_o[1]}]
set_property PACKAGE_PIN AR37 [get_ports {led_o[2]}]
set_property PACKAGE_PIN AT37 [get_ports {led_o[3]}]
set_property IOSTANDARD LVCMOS18 [get_ports {led_o[*]}]

# External reset and serial RX are asynchronous.  Their RTL paths include
# reset synchronization / the UART two-flop input synchronizer.
set_false_path -from [get_ports cpu_reset]
set_false_path -from [get_ports uart_rx_i]
set_false_path -to [get_ports uart_tx_o]
set_false_path -to [get_ports {led_o[*]}]

# JTAG programming is sufficient for this project.  The bitstream loads the
# 64-KiB internal AXI BRAM from the firmware HEX image.
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
