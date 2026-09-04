# args: tag top period xw io_delay(0|1)
set tag       [lindex $argv 0]
set top       [lindex $argv 1]
set period    [lindex $argv 2]
set xw        [lindex $argv 3]
set io_delay  [lindex $argv 4]
set part      xc7k70tfbv676-1

file mkdir reports
foreach f [glob rtl/*.v] { read_verilog $f }
if {$top eq "mesh_top_timing"} { read_verilog impl/mesh_top_timing.v }

# XDC: clock always; input/output delay only for the control experiment
set xdc reports/${tag}.xdc
set fh [open $xdc w]
puts $fh "create_clock -period $period -name clk \[get_ports clk\]"
if {$io_delay == 1} {
    puts $fh "set_input_delay  -clock clk 1.000 \[get_ports {ep_in_flit\[*\] ep_in_valid\[*\] ep_out_ready\[*\] rst_n}\]"
    puts $fh "set_output_delay -clock clk 1.000 \[get_ports {ep_out_flit\[*\] ep_out_valid\[*\] ep_in_ready\[*\]}\]"
}
close $fh
read_xdc $xdc

synth_design -top $top -part $part -mode out_of_context \
    -generic X_W=$xw -generic Y_W=$xw
opt_design
place_design
phys_opt_design
route_design

report_timing_summary -file reports/${tag}_timing.rpt
report_utilization    -file reports/${tag}_util.rpt
report_timing -max_paths 3 -delay_type max -file reports/${tag}_path.rpt

set sp [get_timing_paths -delay_type max -max_paths 1]
set hp [get_timing_paths -delay_type min -max_paths 1]
set wns [get_property SLACK $sp]
set whs [get_property SLACK $hp]
set stp [get_property STARTPOINT_PIN $sp]
set enp [get_property ENDPOINT_PIN   $sp]

puts "@@RESULT tag=$tag top=$top period=$period xw=$xw io_delay=$io_delay"
puts "@@WNS $wns"
puts "@@WHS $whs"
puts "@@START $stp"
puts "@@END   $enp"
if {$wns ne ""} {
    set fmax [expr {1000.0 / ($period - $wns)}]
    puts "@@FMAX_MHZ [format %.1f $fmax]"
}
