# Board-level non-DDR constraints for dma_mmu_picorv32_vc707_ddr3_top.
# The tracked MIG configuration and its generated XDC own SYSCLK and every
# DDR3 SODIMM pin/electrical/timing constraint.

set_property CFGBVS GND [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]

# Active-high CPU_RESET push button.  It also drives MIG sys_rst.
set_property PACKAGE_PIN AV40 [get_ports cpu_reset]
set_property IOSTANDARD LVCMOS18 [get_ports cpu_reset]

# USB-UART bridge (115200 baud with the 150-MHz SoC clock).
set_property PACKAGE_PIN AU33 [get_ports uart_rx_i]
set_property IOSTANDARD LVCMOS18 [get_ports uart_rx_i]
set_property PACKAGE_PIN AU36 [get_ports uart_tx_o]
set_property IOSTANDARD LVCMOS18 [get_ports uart_tx_o]

# LED0=MIG calibration complete, LED1=CPU trap, LED2=DMA IRQ,
# LED3=MIG and SoC clock managers locked.
set_property PACKAGE_PIN AM39 [get_ports {led_o[0]}]
set_property PACKAGE_PIN AN39 [get_ports {led_o[1]}]
set_property PACKAGE_PIN AR37 [get_ports {led_o[2]}]
set_property PACKAGE_PIN AT37 [get_ports {led_o[3]}]
set_property IOSTANDARD LVCMOS18 [get_ports {led_o[*]}]

set_false_path -from [get_ports cpu_reset]
set_false_path -from [get_ports uart_rx_i]
set_false_path -to [get_ports uart_tx_o]
set_false_path -to [get_ports {led_o[*]}]

# soc_reset_pipe is the standard asynchronous-assert/synchronous-release
# reset synchronizer.  Recovery/removal on its asynchronous PRE pins is not a
# synchronous data-path requirement; the ASYNC_REG pipeline provides three
# clean SoC clock edges before rst_ni is released.
set_false_path -to [get_pins -hierarchical -regexp \
    {.*soc_reset_pipe_reg(\[[0-9]+\])?(_replica_[0-9]+)?/PRE}]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
