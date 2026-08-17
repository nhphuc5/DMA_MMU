# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "AXI_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "AXI_DATA_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "AXI_ID_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "BANK_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "CAL_TIMEOUT" -parent ${Page_0}
  ipgui::add_param $IPINST -name "COL_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "DDR_BASE_ADDR" -parent ${Page_0}
  ipgui::add_param $IPINST -name "DDR_SIZE_BYTES" -parent ${Page_0}
  ipgui::add_param $IPINST -name "REFRESH_CYCLES" -parent ${Page_0}
  ipgui::add_param $IPINST -name "RESET_CYCLES" -parent ${Page_0}
  ipgui::add_param $IPINST -name "ROW_WIDTH" -parent ${Page_0}


}

proc update_PARAM_VALUE.AXI_ADDR_WIDTH { PARAM_VALUE.AXI_ADDR_WIDTH } {
	# Procedure called to update AXI_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.AXI_ADDR_WIDTH { PARAM_VALUE.AXI_ADDR_WIDTH } {
	# Procedure called to validate AXI_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.AXI_DATA_WIDTH { PARAM_VALUE.AXI_DATA_WIDTH } {
	# Procedure called to update AXI_DATA_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.AXI_DATA_WIDTH { PARAM_VALUE.AXI_DATA_WIDTH } {
	# Procedure called to validate AXI_DATA_WIDTH
	return true
}

proc update_PARAM_VALUE.AXI_ID_WIDTH { PARAM_VALUE.AXI_ID_WIDTH } {
	# Procedure called to update AXI_ID_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.AXI_ID_WIDTH { PARAM_VALUE.AXI_ID_WIDTH } {
	# Procedure called to validate AXI_ID_WIDTH
	return true
}

proc update_PARAM_VALUE.BANK_WIDTH { PARAM_VALUE.BANK_WIDTH } {
	# Procedure called to update BANK_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.BANK_WIDTH { PARAM_VALUE.BANK_WIDTH } {
	# Procedure called to validate BANK_WIDTH
	return true
}

proc update_PARAM_VALUE.CAL_TIMEOUT { PARAM_VALUE.CAL_TIMEOUT } {
	# Procedure called to update CAL_TIMEOUT when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.CAL_TIMEOUT { PARAM_VALUE.CAL_TIMEOUT } {
	# Procedure called to validate CAL_TIMEOUT
	return true
}

proc update_PARAM_VALUE.COL_WIDTH { PARAM_VALUE.COL_WIDTH } {
	# Procedure called to update COL_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.COL_WIDTH { PARAM_VALUE.COL_WIDTH } {
	# Procedure called to validate COL_WIDTH
	return true
}

proc update_PARAM_VALUE.DDR_BASE_ADDR { PARAM_VALUE.DDR_BASE_ADDR } {
	# Procedure called to update DDR_BASE_ADDR when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.DDR_BASE_ADDR { PARAM_VALUE.DDR_BASE_ADDR } {
	# Procedure called to validate DDR_BASE_ADDR
	return true
}

proc update_PARAM_VALUE.DDR_SIZE_BYTES { PARAM_VALUE.DDR_SIZE_BYTES } {
	# Procedure called to update DDR_SIZE_BYTES when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.DDR_SIZE_BYTES { PARAM_VALUE.DDR_SIZE_BYTES } {
	# Procedure called to validate DDR_SIZE_BYTES
	return true
}

proc update_PARAM_VALUE.REFRESH_CYCLES { PARAM_VALUE.REFRESH_CYCLES } {
	# Procedure called to update REFRESH_CYCLES when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.REFRESH_CYCLES { PARAM_VALUE.REFRESH_CYCLES } {
	# Procedure called to validate REFRESH_CYCLES
	return true
}

proc update_PARAM_VALUE.RESET_CYCLES { PARAM_VALUE.RESET_CYCLES } {
	# Procedure called to update RESET_CYCLES when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.RESET_CYCLES { PARAM_VALUE.RESET_CYCLES } {
	# Procedure called to validate RESET_CYCLES
	return true
}

proc update_PARAM_VALUE.ROW_WIDTH { PARAM_VALUE.ROW_WIDTH } {
	# Procedure called to update ROW_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.ROW_WIDTH { PARAM_VALUE.ROW_WIDTH } {
	# Procedure called to validate ROW_WIDTH
	return true
}


proc update_MODELPARAM_VALUE.AXI_ADDR_WIDTH { MODELPARAM_VALUE.AXI_ADDR_WIDTH PARAM_VALUE.AXI_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.AXI_ADDR_WIDTH}] ${MODELPARAM_VALUE.AXI_ADDR_WIDTH}
}

proc update_MODELPARAM_VALUE.AXI_DATA_WIDTH { MODELPARAM_VALUE.AXI_DATA_WIDTH PARAM_VALUE.AXI_DATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.AXI_DATA_WIDTH}] ${MODELPARAM_VALUE.AXI_DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.AXI_ID_WIDTH { MODELPARAM_VALUE.AXI_ID_WIDTH PARAM_VALUE.AXI_ID_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.AXI_ID_WIDTH}] ${MODELPARAM_VALUE.AXI_ID_WIDTH}
}

proc update_MODELPARAM_VALUE.DDR_BASE_ADDR { MODELPARAM_VALUE.DDR_BASE_ADDR PARAM_VALUE.DDR_BASE_ADDR } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.DDR_BASE_ADDR}] ${MODELPARAM_VALUE.DDR_BASE_ADDR}
}

proc update_MODELPARAM_VALUE.DDR_SIZE_BYTES { MODELPARAM_VALUE.DDR_SIZE_BYTES PARAM_VALUE.DDR_SIZE_BYTES } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.DDR_SIZE_BYTES}] ${MODELPARAM_VALUE.DDR_SIZE_BYTES}
}

proc update_MODELPARAM_VALUE.ROW_WIDTH { MODELPARAM_VALUE.ROW_WIDTH PARAM_VALUE.ROW_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.ROW_WIDTH}] ${MODELPARAM_VALUE.ROW_WIDTH}
}

proc update_MODELPARAM_VALUE.COL_WIDTH { MODELPARAM_VALUE.COL_WIDTH PARAM_VALUE.COL_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.COL_WIDTH}] ${MODELPARAM_VALUE.COL_WIDTH}
}

proc update_MODELPARAM_VALUE.BANK_WIDTH { MODELPARAM_VALUE.BANK_WIDTH PARAM_VALUE.BANK_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.BANK_WIDTH}] ${MODELPARAM_VALUE.BANK_WIDTH}
}

proc update_MODELPARAM_VALUE.RESET_CYCLES { MODELPARAM_VALUE.RESET_CYCLES PARAM_VALUE.RESET_CYCLES } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.RESET_CYCLES}] ${MODELPARAM_VALUE.RESET_CYCLES}
}

proc update_MODELPARAM_VALUE.REFRESH_CYCLES { MODELPARAM_VALUE.REFRESH_CYCLES PARAM_VALUE.REFRESH_CYCLES } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.REFRESH_CYCLES}] ${MODELPARAM_VALUE.REFRESH_CYCLES}
}

proc update_MODELPARAM_VALUE.CAL_TIMEOUT { MODELPARAM_VALUE.CAL_TIMEOUT PARAM_VALUE.CAL_TIMEOUT } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.CAL_TIMEOUT}] ${MODELPARAM_VALUE.CAL_TIMEOUT}
}

