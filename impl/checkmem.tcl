set xw [lindex $argv 0]
foreach f [glob rtl/*.v] { read_verilog $f }
read_verilog impl/mesh_top_timing.v
synth_design -top mesh_top_timing -part xc7k70tfbv676-1 -mode out_of_context \
    -generic X_W=$xw -generic Y_W=$xw
set ramd [llength [get_cells -hier -filter {REF_NAME == RAMD32}]]
set rams [llength [get_cells -hier -filter {REF_NAME == RAMS32}]]
# how many FIFO instances survived, and how wide is one memory
set fifos [llength [get_cells -hier -filter {NAME =~ *u_fifo}]]
set m0 [llength [get_cells -hier -filter {NAME =~ *u_r0/g_input[0].u_fifo/mem_reg*}]]
puts "@@XW=$xw RAMD32=$ramd RAMS32=$rams total_lutram=[expr {$ramd+$rams}] fifo_insts=$fifos r0_in0_mem_cells=$m0"
