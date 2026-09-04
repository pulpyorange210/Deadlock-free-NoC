set R /work/openlane/mesh_top_timing/runs/run_loose
read_liberty /pdk/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__ss_100C_1v60.lib
read_verilog $R/results/routing/mesh_top_timing.nl.v
link_design mesh_top_timing
read_spef $R/results/routing/mca/spef/mesh_top_timing.max.spef
read_sdc $R/tmp/20-mesh_top_timing.sdc
set_propagated_clock [all_clocks]
puts "@@=== worst path WITH NET NAMES ==="
report_checks -path_delay max -group_count 1 -digits 3 -fields {net fanout cap}
