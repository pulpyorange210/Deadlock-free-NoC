# Deadlock-Free NoC — 2×2 Mesh Network-on-Chip

A synthesizable 2×2 mesh Network-on-Chip in Verilog-2001. Five-port routers move
single-flit packets between four endpoints without deadlocking, starving an
input, or dropping a flit — with the deadlock freedom coming from the routing
algorithm's structure rather than from detection and recovery.

| | FPGA | ASIC |
|---|---|---|
| Target | Kintex-7 `xc7k70tfbv676-1` (28 nm) | SkyWater Sky130A (130 nm) |
| Frequency | **173.3 MHz** | **79.3 MHz** |
| Setup slack | +0.429 ns at 6.200 ns | +7.384 ns at 20.000 ns |
| Hold slack | +0.040 ns | +0.11 ns |
| Area | 989 LUT / 421 FF / 0 BRAM | 8183 cells, 97 190 µm² |
| Signoff | 0 failing endpoints of 2514 | 0 DRC violations, 0 layout XOR diffs |

Both figures are post-**implementation** (after place and route), measured on an
identical registered DUT boundary, and both critical paths are internal
flop-to-flop paths rather than I/O paths. The ASIC run is a single
loose-constraint pass and LVS was not reached — see
[`ENGINEERING_LOG.md`](ENGINEERING_LOG.md) for the caveats.

## Architecture

```
        (0,1) r2 ──────── r3 (1,1)
                │            │
                │            │
        (0,0) r0 ──────── r1 (1,0)
```

Each router has five ports — Local plus four cardinals — encoded consistently as
`[0] LOCAL [1] NORTH [2] EAST [3] SOUTH [4] WEST`. Per input port there is a
4-entry FIFO; per output port an independent round-robin arbiter; one crossbar
per router.

```
 input link ──▶ [input FIFO] ──▶ [route compute] ──▶ [arbiter] ──▶ [crossbar] ──▶ output link
```

Flits are 34 bits: `{dest_x[1], dest_y[1], payload[32]}`. Every width derives
from the `X_W`, `Y_W`, `DATA_W` and `FIFO_DEPTH` parameters — the design has been
simulated and synthesized at 2-bit coordinates as well, which is what a 4×4 mesh
would need.

**Three properties the design is built around:**

- **XY dimension-order routing.** X displacement resolves completely before any
  Y movement, which makes all four Y→X turns unreachable and leaves the channel
  dependency graph acyclic. Deadlock is impossible by construction — no
  timeouts, no detection, no recovery, no virtual channels.
- **Round-robin arbitration, one arbiter per output.** The priority pointer
  advances past the winner only on a grant that actually transferred a flit,
  bounding worst-case wait at five grants. Fixed priority starves under
  sustained load; measured, it delivers 199/0/0/0/0 where round-robin delivers
  39/40/40/40/40.
- **On/off backpressure.** A full downstream FIFO deasserts the upstream
  `ready`, which masks that output's arbitration requests before the arbiter
  sees them. A FIFO pops only when its input both won arbitration and the
  receiver was ready, so flits are never dropped.

## Repository layout

| Path | Contents |
|---|---|
| `rtl/` | Synthesizable RTL: `fifo`, `route_compute`, `rr_arbiter`, `crossbar`, `router`, `mesh_top` |
| `tb/` | Self-checking testbenches: `tb_router`, `tb_mesh` |
| `impl/` | Synthesis-only wrapper and flow scripts (Vivado, OpenLane, OpenSTA) |
| `openlane/` | OpenLane design config for the Sky130 flow |
| `reports/` | Vivado timing, path and utilization reports |
| `RATIONALE.md` | One-page answers to the twelve design questions |
| `RATIONALE_FULL.md` | Long form, with the evidence behind each answer |
| `ENGINEERING_LOG.md` | 26 design decisions and 6 bug entries, written during the build |

Nothing that is not synthesizable goes in `rtl/`. `impl/mesh_top_timing.v` is a
synthesis-only wrapper that registers every endpoint port so implementation
times internal logic instead of package and I/O buffer delay; it is deliberately
**not** functionally equivalent to `rtl/mesh_top.v` and is never simulated.

## Running it

Simulation and the synthesis sanity check need [Icarus
Verilog](https://steveicarus.github.io/iverilog/) and
[Yosys](https://yosyshq.net/yosys/) — both ship in the
[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build).

```bash
# Single-router regression: 117 assertions across two coordinate widths
iverilog -g2012 -o sim.out tb/tb_router.v rtl/router.v rtl/fifo.v \
         rtl/route_compute.v rtl/rr_arbiter.v rtl/crossbar.v
vvp sim.out

# Full-mesh regression: seven required cases + HOL, reset and latency, 109 assertions
iverilog -g2012 -o sim.out tb/tb_mesh.v rtl/mesh_top.v rtl/router.v rtl/fifo.v \
         rtl/route_compute.v rtl/rr_arbiter.v rtl/crossbar.v
vvp sim.out

# Parameter sweep. DATA_W and FIFO_DEPTH default to 32 and 4; override either
# with a two-line prefix file compiled ahead of the bench, since macros persist
# across files in compilation order. DATA_W must be >= 32 (below that the
# src/seq/magic payload fields overlap).
cat > cfg.vh <<'EOF'
`define CFG_DATA_W 64
`define CFG_FIFO_DEPTH 8
EOF
iverilog -g2012 -o sim.out cfg.vh tb/tb_mesh.v rtl/mesh_top.v rtl/router.v \
         rtl/fifo.v rtl/route_compute.v rtl/rr_arbiter.v rtl/crossbar.v
vvp sim.out
```

The suite is verified clean at `DATA_W` 32 / 40 / 48 / 64 and `FIFO_DEPTH`
2 / 4 / 8. The assertion count tracks `FIFO_DEPTH` — 103 at depth 2, 109 at 4,
121 at 8 — because the backpressure case injects `8*FIFO_DEPTH` flits and
asserts the arrival endpoint of each.

Under Vivado XSim the same prefix file is passed to `xvlog` ahead of the bench;
`xvlog -d NAME=VALUE` splits a valued macro on the `=` and fails, so the prefix
file is the portable mechanism rather than a command-line define.

```bash
# Synthesis sanity check. `flatten` matters: without it the loop analysis
# treats each router as opaque and cannot see a cycle closing around the mesh.
yosys -p "hierarchy -top mesh_top; flatten; proc; opt; fsm; opt; \
          memory; opt; techmap; opt; check -assert; scc" rtl/*.v
```

Expected: zero inferred latches, `Found and reported 0 problems`, `Found 0 SCCs`.

The glob is scoped to `rtl/` rather than filtered by filename so a testbench can
never be pulled into synthesis. Note that yosys does not expand wildcards
itself — the files are passed as positional arguments so the shell expands them.

```bash
# Vivado implementation (args: tag top period coord_width io_delay)
vivado -mode batch -source impl/run_impl.tcl \
       -tclargs iter3 mesh_top_timing 6.200 1 0
```

```bash
# OpenLane / Sky130, via Docker
docker run --rm -v $PWD:/work -v $PDK_ROOT:/pdk -e PDK_ROOT=/pdk -e PDK=sky130A \
  efabless/openlane:latest \
  flow.tcl -design /work/openlane/mesh_top_timing -tag run1 -overwrite
```

## Verification

Pass/fail is decided by assertions. **117 assertions** at router level across two
coordinate configurations, **49** at mesh level covering all seven required
cases: single-hop, two-hop, simultaneous injection, output contention, sustained
load, backpressure/FIFO-full, and all-to-all.

A single scoreboard covers four properties at once — every injected flit is
recorded against its destination and every ejection must retire an exact match
at the endpoint where it appeared, so correct destination, payload integrity, no
duplication and no loss all fall out together, with the scoreboard asserted
empty at end of test. Last run: **2376 flits injected, 2364 ejected, 12 discarded by
a deliberate mid-traffic reset, 0 outstanding, 0 unmatched.** Routing order is asserted on the *path* a flit took across the
links, not merely on its arrival — a Y-first route reaches the same endpoint
over different links, so arrival alone proves nothing.

Everything runs identically under Icarus Verilog and Vivado XSim. Running both
is deliberate: it is what caught a race in the testbench's own cycle counter.

### The testbench is itself tested

A passing self-checking testbench proves nothing until it has been shown to
fail, so every assertion is validated against deliberate RTL mutations:

| Mutation | Defect injected | Caught by |
|---|---|---|
| A | Y-first instead of X-first routing | routing-order assertions |
| B | Fixed priority instead of round-robin | starvation bound and fair-share |
| C | Unmasked requests, pop ignoring `ready` | loss, FIFO-full and ordering checks |
| D | Unmasked requests only | bounded-wait plus a white-box pointer check |
| E | One router disagreeing on dimension order | two-hop path assertion |
| F | Two routers disagreeing, completing the dependency cycle | two-hop path assertions |

This process found real defects. The first version of the sustained-load test
passed against a fixed-priority arbiter — the one thing it existed to catch —
because its starvation metric measured the gap between an input's *own*
consecutive services, which is undefined for an input that is never served.
Mutation E and F also establish an honest limit: **the suite cannot demonstrate
deadlock.** With the dependency cycle made constructible, 382 flits still
arrived with no hang, and only the path assertions noticed. Deadlock freedom
rests on the structural argument, not on simulation.

## Scope

Deliberately excluded to keep the build finishable: multi-flit packets, virtual
channels, adaptive routing, multiple clock domains, link error detection, QoS
classes, and meshes larger than 2×2. All widths are parameterized so scaling is
an instantiation change rather than a rewrite.

## Further reading

[`RATIONALE.md`](RATIONALE.md) answers the twelve design questions in one page —
why XY is deadlock-free, which turns are forbidden and what breaks otherwise,
what XY costs, why round-robin, how backpressure propagates, why on/off rather
than credit-based, the FIFO depth, the critical path and how to break it, what
the testbench misses, how it scales to 4×4, and where the throughput bottleneck
actually is. [`RATIONALE_FULL.md`](RATIONALE_FULL.md) is the same twelve with
the full evidence. [`ENGINEERING_LOG.md`](ENGINEERING_LOG.md) is the running
record kept during the build.
