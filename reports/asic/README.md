# ASIC signoff evidence (Sky130 / OpenLane)

The full OpenLane run directories are not tracked — `openlane/*/runs/` is
gitignored because the eleven runs total roughly 800 MB, and every one of them
is regenerable from `openlane/mesh_top_timing/config.json`, which pins
`CLOCK_PERIOD` to the 3.000 ns operating point. What is kept here is the
evidence the engineering log cites, so its numbers can be checked without
re-running a 14-minute flow.

| File | What it backs |
|---|---|
| `<run>_metrics.csv` | One row per run, straight from OpenLane. Areas, `synth_cell_count`, `TotalCells`, `Final_Util`, `DiodeCells` and `pin_antenna_violations` for the D32 tightening table and the D33 diode-cost measurement. |
| `<run>_slowest_critical_path.rpt` | The Slowest-corner worst path, extracted from that run's 18–21 MB `multi_corner_sta.max.rpt`. Backs the D26 / D35 path-depth and cell-type comparison. |
| `<run>_slowest_summary.rpt` | Slowest-corner TNS, WNS and worst setup/hold slack. |

Runs present: `run_lvs2` is the 20 ns Stage A baseline; `sb_*` are the nine
Stage B bisection points, named for their period (`sb_03p000` = 3.000 ns);
`sb_03p000_heur` and `sb_03p000_diode5` are the two antenna remedies priced in
D33.

Note that `metrics.csv` carries OpenLane's own `wns`, which is computed at the
**Typical** corner. The frequencies quoted throughout this project are scored at
the **Slowest** corner instead, which OpenLane never checks — see B8 for why
that distinction is the whole reason the Stage B x-axis is an optimisation
driver rather than a constraint. Read the Slowest figures from the
`_slowest_*.rpt` files, not from the `wns` column.
