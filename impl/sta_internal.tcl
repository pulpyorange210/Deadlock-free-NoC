set R /work/openlane/mesh_top_timing/runs/run_loose
read_liberty /pdk/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__ss_100C_1v60.lib
read_verilog $R/results/routing/mesh_top_timing.nl.v
link_design mesh_top_timing
read_spef $R/results/routing/mca/spef/mesh_top_timing.max.spef
read_sdc $R/tmp/20-mesh_top_timing.sdc
set_propagated_clock [all_clocks]

puts "@@=== SUMMARY ==="
puts "@@worst_slack_max [report_worst_slack -max]"
puts "@@worst_slack_min [report_worst_slack -min]"

puts "@@=== 1. OVERALL WORST SETUP PATH (any endpoint) ==="
report_checks -path_delay max -group_count 1 -digits 3

puts "@@=== 2. WORST INTERNAL PATH (endpoint = register data pin) ==="
report_checks -path_delay max -to [all_registers -data_pins] -group_count 1 -digits 3

puts "@@=== 3. WORST PATH ENDING AT AN OUTPUT PORT ==="
report_checks -path_delay max -to [all_outputs] -group_count 1 -digits 3

puts "@@=== 4. WORST PATH STARTING AT AN INPUT PORT ==="
report_checks -path_delay max -from [all_inputs] -group_count 1 -digits 3
