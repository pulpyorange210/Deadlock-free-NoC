set xw [lindex $argv 0]
foreach f [glob rtl/*.v] { read_verilog $f }
read_verilog impl/mesh_top_timing.v
synth_design -top mesh_top_timing -part xc7k70tfbv676-1 -mode out_of_context \
    -generic X_W=$xw -generic Y_W=$xw
set p [get_ports ep_in_flit*]
puts "@@XW=$xw  ep_in_flit_bits=[llength [get_ports ep_in_flit[*]]]  ep_out_flit_bits=[llength [get_ports ep_out_flit[*]]]"
puts "@@XW=$xw  total_FF=[llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]"
