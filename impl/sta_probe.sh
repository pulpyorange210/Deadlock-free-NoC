#!/bin/bash
R=/work/openlane/mesh_top_timing/runs/run_loose
echo "--- liberty corners available ---"
ls /pdk/sky130A/libs.ref/sky130_fd_sc_hd/lib/ | head -20
echo "--- netlists ---"
ls -la $R/results/routing/*.v 2>/dev/null
echo "--- sdc candidates ---"
find $R -name "*.sdc" 2>/dev/null | head -10
echo "--- sta / openroad binaries ---"
which sta openroad 2>/dev/null
echo "--- base sdc used by the flow ---"
grep -m5 -E "create_clock|set_output_delay|set_input_delay|IO_PCT|set_load" $R/tmp/*.sdc 2>/dev/null | head -12
