# Check whether the exact VC707 Virtex-7 device is installed in this Vivado.
set part_name "xc7vx485tffg1761-2"
set matches [get_parts -quiet $part_name]
if {[llength $matches] == 0} {
    puts stderr "VC707_DEVICE_SUPPORT=NOT_INSTALLED"
    puts stderr "Missing Vivado part: $part_name"
    exit 2
}
puts "VC707_DEVICE_SUPPORT=INSTALLED"
puts "VC707_PART=[lindex $matches 0]"
set board_matches [get_board_parts -quiet *vc707*]
if {[llength $board_matches] == 0} {
    puts "VC707_BOARD_FILES=NOT_INSTALLED (optional; part+XDC flow still works)"
} else {
    puts "VC707_BOARD_FILES=[lindex $board_matches 0]"
}
exit 0
