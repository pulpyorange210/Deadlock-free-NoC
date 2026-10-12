# Engineering Log

## Decisions

**D1 — Port encoding is `[0] LOCAL [1] NORTH [2] EAST [3] SOUTH [4] WEST`.**
Fixed once and used identically for every 5-wide request/grant/valid/ready
vector and every flattened flit bus in `route_compute.v`, `rr_arbiter.v`,
`crossbar.v` and `router.v`. Chosen so LOCAL is index 0 and the cardinals run
clockwise from North. Recorded here because a mismatch between two modules on
this encoding is silent in simulation until a flit ejects on the wrong port.

**D2 — Flit layout is `{dest_x[X_W], dest_y[Y_W], payload[DATA_W]}`, MSB first,
`FLIT_W = X_W + Y_W + DATA_W`.** At the Phase 1 parameters (X_W=1, Y_W=1,
DATA_W=32) that is a 34-bit flit. `route_compute` slices it with
`flit[FLIT_W-1 -: X_W]` and `flit[DATA_W +: Y_W]`, so no width is written
literally anywhere.

**D3 — FIFO depth is 4 (§8 Q8).** Depth 4 is the smallest power-of-two depth
that covers the round-trip of the on/off backpressure loop with margin: a flit
takes 1 cycle to cross a router, so a downstream `full` is visible upstream the
cycle after it asserts, and 2 slots would already avoid loss. 4 was chosen over
2 so that a blocked output does not immediately backpressure its neighbour on
the first stall cycle. Measured cost at depth 4: 120 LUTs as distributed RAM per
router, and it is the dominant term in the router's 493 LUTs. Storage inferred
by Vivado as distributed RAM (180 RAMD32 + 60 RAMS32), not flip-flops and not
block RAM, so the depth costs no BRAM at all.

**D4 — `full` does not bypass a simultaneous pop.** `full` is
`count == DEPTH` on the registered occupancy count only. Making `full` depend on
`rd_en` would let a router's upstream `ready` depend on that router's own grant,
which depends on `ready` — the combinational loop the backpressure path is
structurally prone to, and the one hazard in this design that simulation would
not reliably report. Cost: one buffer slot of throughput at the full mark. Benefit:
the loop cannot exist by construction rather than being broken by a register
after the fact. Vivado synthesis reports 0 combinational loops and 0 critical
warnings on `router.v`, confirming this.

**D5 — Requests are masked outside the arbiter, not inside it (§8 Q6).**
`router.v` computes `req_masked[k][i] = req[i][k] & out_ready[k]` before the
arbiter sees anything, so `rr_arbiter` never receives a request for an output
that cannot accept a flit. That is what makes advancing `priority_ptr` on
`|grant` correct: every grant the arbiter issues is a grant that actually
happens (§8 Q5). The contract is written into the header of `rr_arbiter.v`
because instantiating it with unmasked requests silently breaks the bounded-wait
guarantee — see B2, where exactly that mutation survives every test except T8.

**D6 — Backpressure end to end (§8 Q6), as built.** Downstream input FIFO
reaches `count == 4` → `full` asserts → that router's `in_ready` deasserts →
upstream sees `out_ready[k]` low → upstream masks every request for output k →
no arbiter grant for k → no pop of the granted input's FIFO → that FIFO fills
and asserts its own `full`. Propagation is one hop per cycle, upstream, against
the direction of data. Verified by tb_router T4 (no ejection for 12 cycles with
EAST ready low, flit intact afterwards) and T5 (`in_ready` deasserts after
exactly FIFO_DEPTH=4 accepted flits, all 4 recovered in order).

**D7 — Toolchain: Icarus 14.0 and Yosys 0.68 from OSS CAD Suite, with Vivado
XSim as a second opinion.** The machine started with only Vivado 2025.1
(`C:\Xilinx\2025.1`) installed, so Phase 1 was first brought up on XSim; OSS CAD
Suite 2026-09-03 (568 MB) was then extracted to `C:\tools\oss-cad-suite`,
supplying Icarus Verilog 14.0, Yosys 0.68 and GTKWave, so every simulation and
synthesis command in `README.md` runs as written. Yosys is also what Phase 4's
OpenLane flow uses.
Running both simulators is kept as standing practice: it is what caught B5.
Environment notes worth not rediscovering — `yosys.exe` fails with
`error while loading shared libraries: libreadline8.dll` unless
`C:\tools\oss-cad-suite\environment.ps1` is sourced first (adding only `bin` to
PATH is not enough). XSim rejects a design where only some modules carry a
timescale, so the RTL stays timescale-free and `xelab` is invoked with
`--timescale 1ns/1ps`. XSim also rejects any source file carrying a UTF-8 BOM
(`VRFC 10-9623 unexpected non-printable character with the hex value '0xef'`),
so RTL is written as UTF-8 without BOM.

**D8 — `out_valid` depends combinationally on `out_ready`, deliberately, and it
is still loop-free.** Because requests are masked by `out_ready` (D5), a grant
only exists when the receiver can take the flit, so `out_valid[k] = |grant[k]`
inherits that dependency. This is the opposite of the usual AXI-style rule that
valid must not depend on ready, so it is worth being able to defend: the chain
is `out_valid_A[k] -> grant_A[k] -> req_masked_A -> out_ready_A[k] ->
in_ready_B -> ~full_B`, and `full_B` is a function of a register only (D4), so
the chain terminates in a flop and no combinational loop can close through the
link. The alternative — asserting valid regardless of ready and dropping the
flit when the receiver cannot take it — is the mutation `mutC`, which loses
flits. Confirmed by Vivado: 0 combinational loops, 0 critical warnings.

**D9 — Verification of the testbench itself is part of the phase gate.** A
passing self-checking bench proves nothing until it has been shown to fail. Each
phase's bench is run against deliberate mutations of the RTL, one invariant per
mutation, and every mutation must be caught. This found B1 immediately: the
first version of tb_router passed 38/38 checks against a fixed-priority
arbiter — the one failure the sustained-load test exists to catch.

**D10 — Sources split into `rtl/` and `tb/` to scope the synthesis glob, not as
a convention.** The Yosys sanity check reads a glob. With everything in one
directory that glob is `*.v`, which pulls `tb_router.v` into synthesis; the
obvious alternative, filtering by a `tb_*` filename rule, only holds as long as
every future bench remembers to be named that way. Putting synthesizable RTL in
`rtl/` makes the glob `rtl/*.v`, and a file cannot end up in synthesis unless
someone puts it in the RTL directory — a decision made when the file is created
rather than a naming convention that has to be re-obeyed each time.

Implementation detail worth not rediscovering: **yosys does not expand
wildcards itself.** `yosys -p "read_verilog rtl/*.v; ..."` fails with
``ERROR: File `rtl/*.v' not found or is a directory``, because the pattern is
inside a quoted `-p` string and never reaches the shell. The working form
passes the files as positional arguments so the shell expands them:
`yosys -p "hierarchy -top router; ..." rtl/*.v`. That is the form `README.md`
carries, verified by running it.

**D11 — The Phase 1 regression runs the whole assertion suite twice, at 1-bit
and 2-bit coordinates.** At 1-bit coordinates a router at (0,0) has two
unsatisfiable routing conditions, so its SOUTH and WEST arbiters constant-fold
away (B3) and only three output arbiters are live; covering four directions
needs two DUTs, at (0,0) and (1,1), and no single router instance ever has five
arbiters in play. The suite was therefore passing without having exercised the
configuration the design is actually parameterized for. `tb_router_core` is now
parameterized on coordinate width and DUT coordinates, and `tb_router`
instantiates it twice: CONFIG 1 at X_W=Y_W=1 in a 2x2 space with DUTs at (0,0)
and (1,1), CONFIG 2 at X_W=Y_W=2 in a 4x4 space with the DUT at (1,1), where
every direction is reachable.

*Result.* CONFIG 1: **52 assertions, 0 errors.** CONFIG 2: **65 assertions,
0 errors.** Total **117 assertions, 0 errors**, identical under Icarus Verilog
14.0 and Vivado XSim 2025.1. (These were 51/64/115 when this entry was first
written; T10, the white-box invariant-3 check, later added one per config.)
Nothing in the 2-bit configuration failed, so no
RTL change came out of this. The 13 extra assertions in CONFIG 2 are T9, added
because running the existing suite at 2-bit coordinates still only proved the
five arbiters *structurally* present — DUT A drove EAST/NORTH/LOCAL and DUT B
drove WEST/SOUTH, so no single instance had driven all five. T9 injects on all
five inputs at once, each flit destined for a different output, and asserts that
all five eject **in the same cycle** with full port coverage and correct
per-port destination. It passes at cycle 1410 with coverage `11111`, which is
also the direct evidence that the crossbar is non-blocking across outputs. T9 is
gated on an `ALL_DIRS` parameter because it cannot run at 1-bit coordinates.

*Mutation results are unchanged by the sweep*, which is the point: every
mutation is caught in both configurations — mutA 2 errors per config, mutB 10,
mutC 7, mutD 1.

**D12 — Mesh wiring and the edge tie-off rule.**

Router numbering, fixed for the whole build: `r0 = (0,0)`, `r1 = (1,0)`,
`r2 = (0,1)`, `r3 = (1,1)`. Endpoint bus index equals router number.

Each row below is one direction of one link. The source router's output port
drives the destination router's input port, and the destination's `in_ready`
for that port drives the source's `out_ready` — flit and valid forwards, ready
backwards.

| src router | src port | dst router | dst port | link id |
|---|---|---|---|---|
| r0 (0,0) | EAST  | r1 (1,0) | WEST  | 0 |
| r1 (1,0) | WEST  | r0 (0,0) | EAST  | 1 |
| r0 (0,0) | NORTH | r2 (0,1) | SOUTH | 2 |
| r2 (0,1) | SOUTH | r0 (0,0) | NORTH | 3 |
| r1 (1,0) | NORTH | r3 (1,1) | SOUTH | 4 |
| r3 (1,1) | SOUTH | r1 (1,0) | NORTH | 5 |
| r2 (0,1) | EAST  | r3 (1,1) | WEST  | 6 |
| r3 (1,1) | WEST  | r2 (0,1) | EAST  | 7 |

Off-mesh ports — each router uses exactly two of four cardinals plus Local:
r0 SOUTH/WEST, r1 EAST/SOUTH, r2 NORTH/WEST, r3 NORTH/EAST. The link ids are
the same ones `tb_mesh` uses to assert the path a two-hop flit took.

**An off-mesh output has `ready` tied LOW, never high.** Ready low masks every
request for that output before the arbiter sees it (D5), so no grant is issued,
the FIFO is never popped, and the flit stays where it is. A routing bug that
aims a flit off the mesh then shows up as a stalled flit and backpressure —
observable, and the flit still exists to be found in a waveform. Ready high
would do the opposite: the arbiter would grant, the crossbar would drive the
flit onto a wire that goes nowhere, and the FIFO would pop. The flit would be
destroyed silently, breaking the lossless invariant in the one way that leaves
no evidence. Off-mesh inputs are held invalid, flit zero.

*One consequence worth knowing before relying on the assertion.* Because
`out_valid[k] = |grant[k]` and requests are masked by ready (D8), a tied-off
output **cannot** assert valid in this design — the "no valid on a tied-off
output" check is a guard on that property, not a live routing check, and it can
never fire. What actually catches a misrouted flit is the companion check that
no input ever *requests* a tied-off output. Verified non-vacuous by aiming a
Stage 1 flit at (1,0): the request check fired at cycle 7 with the EAST bit set,
the flit stalled rather than vanishing, and the valid check stayed silent.

**D13 — Phase 2 results.**

Built in three stages, regression re-run at each: Stage 1 one router at (0,0)
with all cardinals tied off (19 checks), Stage 2 adding r1 and the single
r0-EAST/r1-WEST link (37 checks), Stage 3 the full four-router mesh (61 checks).
**No RTL bug was found at any stage** — each passed on its first run, and the
only defect found in Phase 2 was in the verification itself (B6).

*Section 6 suite.* All seven cases pass: 49 checks, 0 errors, 381 flits
injected and 381 ejected, 0 left outstanding in the scoreboard, 0 ejections
unmatched. Identical under Icarus Verilog 14.0 and Vivado XSim 2025.1.

- Two-hop is asserted on the **path**, not arrival: all four diagonals take
  X first then Y (links 0→4, 7→3, 1→2, 6→5). A Y-first route reaches the same
  endpoint over the other two links, so arrival alone would prove nothing.
- Backpressure absorbed exactly **12 flits** before the injecting endpoint
  stalled — 3 FIFOs of 4 on the path r0 Local, r1 West, r3 South.
- Sustained load: 199 grants, worst-case wait **5 grants** against a bound of
  25 (two round-robin stages of 5).

*Per-source service under load was 33/33/66/67, and that is correct.* Traffic
to ep3 converges on r3's Local arbiter through three inputs: SOUTH carries both
ep0 and ep1, WEST carries ep2, LOCAL carries ep3. Round-robin gives each input
a third of the grants, and the SOUTH third is then split again between ep0 and
ep1 at r1's NORTH arbiter — so a sixth each. Round-robin is fair **per
arbiter**, not end-to-end; sources that share a link share that link's share.
Worth being able to say out loud, because it looks like unfairness and is not.

*Synthesis.* Hierarchical: 13250 cells, 2720 storage flops (4 x 680), 240
control flops (4 x 60), 0 latches, `check -assert` reports 0 problems.
Flattened: 8098 cells, 1632 storage flops, 168 control flops. The difference is
exactly the eight off-mesh input FIFOs constant-folded away — 8 x 136 = 1088
storage flops and 8 x 9 = 72 control flops — because their write enable is tied
to zero. The edge tie-offs therefore cost nothing in the final netlist.

**D14 — Implementation runs against a registered boundary, not raw `mesh_top`.**

`mesh_top` exposes all four endpoint interfaces as top-level ports: 145 input
and 140 output ports at X_W=Y_W=1. Timing that boundary measures the package
and the I/O buffer, not the interconnect, so implementation is run on
`impl/mesh_top_timing.v` — a synthesis-only wrapper that registers every
endpoint input and output plus reset. It lives outside `rtl/` precisely so the
`rtl/*.v` glob cannot pull it into the deliverable (D10), and it is never
simulated: the added registers shift the handshake by a cycle in each
direction, so it is deliberately *not* functionally equivalent to `mesh_top`.
The mesh itself is untouched — the registers sit outside it, so no internal
path is altered by their presence.

*What an unregistered run actually does, measured rather than assumed.* Two
control runs on raw `mesh_top` at 10 ns:

| Run | Constraints | WNS | Critical path endpoint | Fmax |
|---|---|---|---|---|
| C1 | `create_clock` only | +3.077 ns | `u_r0/.../u_fifo/mem_reg.../RAMA_D1/I` (internal) | 144.4 MHz |
| C2 | + `set_input_delay`/`set_output_delay` 1.0 ns | +2.430 ns | **`ep_out_flit[86]` (a port)** | 132.1 MHz |

So the failure mode is not quite the one anticipated. Without I/O delay
constraints the port paths are not *mis*-timed, they are **not timed at all** —
C1's `check_timing` reports `no_input_delay (145)` and `no_output_delay (140)`,
both flagged HIGH, and WNS comes only from internal paths. The danger is
therefore two-sided: either the boundary is silently excluded and the report
covers less of the design than it appears to, or the moment any I/O constraint
is added a flop-to-pad path takes over the critical path and the headline
number stops describing the interconnect — C2, where Fmax drops 12 MHz to a
path ending at a package pin. Registering the boundary removes both outcomes:
every constrained path is then flop-to-flop inside the mesh.

*The check is capable of failing.* "Both endpoints are internal" is only
evidence if it can come out false, and C2 is the demonstration — same RTL, same
part, same period, endpoint `ep_out_flit[86]`. Every run reported below was
checked against that criterion and every one names two internal cells.

**D15 — Timing results, Vivado 2025.1, xc7k70tfbv676-1.**

Post-**implementation** (place and route) numbers throughout. Post-synthesis
timing ignores routing delay and is optimistic; no number here comes from it.
Flow per run: `synth_design -mode out_of_context`, `opt_design`,
`place_design`, `phys_opt_design`, `route_design`, then
`report_timing_summary`. Script is `impl/run_impl.tcl`.

*Iterations.* `Fmax = 1 / (T_clk - WNS)`:

| Iteration | Period | WNS | T_clk − WNS | Fmax |
|---|---|---|---|---|
| 1 | 10.000 ns | +3.141 ns | 6.859 ns | 145.8 MHz |
| 2 | 6.900 ns | +0.732 ns | 6.168 ns | 162.1 MHz |
| 3 (final) | 6.200 ns | +0.429 ns | 5.771 ns | **173.3 MHz** |

*Two different numbers get called "the critical path" and they are not the
same thing.* For the final run:

- **5.543 ns is the data path delay** — the actual propagation from source flop
  clock pin to destination data pin, which the report splits as logic 0.640 ns
  plus routing 4.903 ns.
- **5.771 ns is `T_clk − WNS`**, the slack-derived budget, and it is what the
  Fmax formula in §7.2 uses.

The 0.228 ns gap between them is not an inconsistency, it is the rest of the
setup equation: destination setup requirement 0.159 ns (RAMD32) + clock
uncertainty 0.035 ns + clock skew penalty 0.034 ns = 0.228 ns exactly. Fmax is
computed from 5.771 ns because a real clock has to pay for setup, jitter and
skew as well as propagation; quoting 1/5.543 ns would be 180.4 MHz and would be
overstating the result by 7 MHz.

Three passes, then stopped. The gain from iteration 1 to 3 is 27.5 MHz and it
is entirely the tool optimizing against a tighter constraint — the RTL never
changed. That is the concrete reason a loose constraint understates Fmax.

**Result: 173.3 MHz on a Kintex-7 FPGA (xc7k70tfbv676-1), speed grade -1.**
This is an FPGA number. LUT and routing delays on an FPGA are far worse than
ASIC standard cells, and 88% of this critical path is routing, so the same RTL
would run several times faster on silicon. Nothing here is an ASIC result.

*Timing closure, final run.* WNS **+0.429 ns**, TNS 0.000, 0 failing setup
endpoints of 2514. Pulse width WPWS +2.190 ns, 0 failing of 993.

*Hold: WHS **+0.040 ns**, THS 0.000, 0 failing hold endpoints of 2514.*
Positive, as required, and reported rather than omitted — but it is a thin
margin, 40 ps, and worth stating as such rather than waving through. Two things
make it acceptable. It is met at **every** endpoint, not on average: the total
hold slack is 0.000 ns with zero failing endpoints, so nothing is marginal-
but-passing hidden behind a good worst case. And **hold does not degrade as the
clock period tightens** — hold analysis compares a launch and a capture on the
*same* clock edge, so `T_clk` does not enter the equation. Measured across all
three iterations, WHS was 0.040 ns at 10.000 ns, at 6.900 ns and at 6.200 ns:
identical to the picosecond. Pushing the constraint further would eat setup
margin without touching hold. A hold violation here would have to come from a
placement or clock-tree change, not from a faster clock.

*Critical path (§8 Q9).*

- Start: `u_mesh/u_r1/g_input[0].u_fifo/rd_ptr_reg[0]/C` — r1's Local input
  FIFO read pointer.
- End: `u_mesh/u_r0/g_input[2].u_fifo/mem_reg_0_3_0_5/RAMB_D1/I` — the
  distributed-RAM write data pin of r0's East input FIFO.
- Through, in order: r1's FIFO memory read (RAMD32, read address from
  `rd_ptr`) → head flit → route/select LUT → **`u_r1/g_output[4].u_arb`, the
  round-robin arbiter for r1's WEST output** (five LUT levels) → crossbar →
  the r1-WEST-to-r0-EAST link → r0's East FIFO write port.
- 7 logic levels: LUT3 x1, LUT5 x3, LUT6 x2, RAMD32 x1.
- Data path delay 5.543 ns = **logic 0.640 ns (11.5%) + routing 4.903 ns
  (88.5%)**. The single largest contributor is one net inside the arbiter,
  `priority_ptr_reg[2]_2`, fanout 45, 0.988 ns of pure routing.

The path therefore crosses a whole router *and* a link in one cycle: FIFO read,
route compute, arbitrate, crossbar, and write into the next router's FIFO.
Three ways to break it, in the order they are worth doing:

1. **Register the link.** Pipeline the crossbar output so the path ends at a
   flop in the source router instead of the downstream FIFO's RAM write port.
   This is the one structural cut that halves the path, turning a single
   cross-router path into two shorter ones, and it also lets the placer put the
   two routers further apart without penalty — which matters precisely because
   routing, not logic, dominates. Cost: one cycle of latency per hop, so 2 to 4
   cycles end-to-end across a 2x2 mesh.
2. **Register the routing decision.** Compute `req` when a flit is *written*
   into the FIFO and store it alongside the flit, so the arbiter starts from a
   register rather than a combinational chain out of LUTRAM. Removes the RAMD32
   read and the route LUT from the path. Costs FIFO width, not latency.
3. **Reduce the arbiter's fanout-45 net.** Worth naming because the honest
   reading of "logic 11.5%, routing 88.5%" is that cutting logic levels buys
   less than it looks like it should; on this design the wins are in fanout and
   placement locality, not in shortening the LUT chain.

*Utilization, final run, X_W=Y_W=1.* 989 Slice LUTs (703 as logic, 286 as
memory), 421 Slice Registers, **0 BRAM**, 0 DSP. On xc7k70t that is 2.41% of
LUTs and 0.51% of registers.

**The FIFOs infer distributed RAM, not block RAM:** 430 RAMD32 + 142 RAMS32
primitives, 0 of 135 Block RAM Tiles used. This is a required outcome, not a
missed optimization — see D16.

*Utilization at X_W=Y_W=2, same 6.200 ns constraint, for comparison:* 967 Slice
LUTs (681 logic, 286 memory), 423 Slice Registers, 0 BRAM; WNS +0.408 ns, Fmax
172.7 MHz.

**989 LUTs / 421 FF / 0 BRAM at X_W=Y_W=1 is the design as specified** — §3.1
fixes coordinates at 1 bit each for a 2x2 mesh. The X_W=2 figure is a scaling
reference for §8 Q11, not the deliverable.

Two honest caveats on that comparison. First, the two numbers are within 2% of
each other and the 2-bit build is *smaller* in LUTs, which is optimization
variance between runs rather than a real saving — the parameterization is
genuinely taking effect, confirmed by checking rather than assuming: the
top-level flit bus is 136 bits at X_W=1 and 144 at X_W=2, and r0's input-0 FIFO
memory grows from 56 to 91 primitives. Second, the as-specified number already
includes the corner-router constant folding recorded in B3: at 1-bit
coordinates each corner router has two unsatisfiable routing conditions, so 989
LUTs is *not* the cost of four general 5-port routers, and a 4x4 mesh will not
be four times this.

**D16 — FIFO storage must be distributed RAM, not block RAM. 0 BRAM is a
requirement met, not an optimization missed.**

Vivado maps the input FIFOs to LUTRAM (430 RAMD32 + 142 RAMS32) and uses 0 of
135 Block RAM Tiles. That is the outcome the design needs, and it would be a
bug if it went the other way.

A Xilinx block RAM has a **synchronous** read port: the data appears one cycle
after the address. The router's datapath depends on the opposite. `fifo.rd_data`
is an asynchronous read of `mem[rd_ptr]`, so the head flit is visible in the
same cycle it becomes valid, and `route_compute` and the arbiter both consume it
combinationally within that cycle (D4). Move the storage to block RAM and the
head flit arrives a cycle late: route computation, arbitration and the crossbar
all slip by one cycle, and either per-hop latency doubles or the FIFO needs an
output-register bypass path that reintroduces exactly the combinational
complexity D4 was avoiding.

The capacity argument points the same way. A 4-entry x 34-bit FIFO is 136 bits.
One 18 Kb block RAM would hold it 135 times over, so each of the 20 FIFOs would
burn a whole BRAM to use 0.7% of it — 20 of the part's 135 tiles for 2.7 Kb of
real storage. LUTRAM costs 286 LUTs for all of it.

So the depth-4 choice (D3) and the asynchronous-read choice are the same
decision seen from two sides: depth 4 is small enough that LUTRAM is the natural
target, and LUTRAM is what makes one-cycle-per-hop possible. A future 4x4 build
with deeper FIFOs would have to revisit this, and the thing to revisit is not
"should we use BRAM" but "can the head-flit path tolerate a registered read".

**D17 — Why XY dimension-order routing is deadlock-free (§8 Q1).**

Deadlock in a wormhole/store-and-forward network needs a cycle in the channel
dependency graph: a set of channels each held by a packet that is waiting for
the next channel in the set, with no channel ever released. Nodes in that graph
are channels (here, the 8 inter-router link directions); an edge A→B exists if a
packet can occupy A while requesting B.

Concretely for this 2x2 mesh, using the link ids from D12, the clockwise ring is
link 0 (r0 EAST→r1) → link 4 (r1 NORTH→r3) → link 7 (r3 WEST→r2) → link 3
(r2 SOUTH→r0) → back to link 0. The deadlock that ring would represent: four
packets, one held in each of r0, r1, r2 and r3, every FIFO on the ring full,
each packet needing the link the next router is holding. Nothing times out,
nothing backs off, and the network is stopped permanently.

Walk the ring and check each turn against XY:

| Dependency | Turn at that router | XY? |
|---|---|---|
| link 0 → link 4 | arrive r1 heading East, leave North | X→Y, allowed |
| link 4 → link 7 | arrive r3 heading North, leave West | **Y→X, impossible** |
| link 7 → link 3 | arrive r2 heading West, leave South | X→Y, allowed |
| link 3 → link 0 | arrive r0 heading South, leave East | **Y→X, impossible** |

The counter-clockwise ring (links 1 → 2 → 6 → 5) breaks the same way, at
North→East in r2 and South→West in r1. Both rings need two dependencies that
cannot exist, so neither ring can form, so the graph is acyclic and deadlock is
impossible.

The reason those two dependencies cannot exist is worth stating precisely,
because it is easy to describe XY as if each router refuses certain turns. It
does not. `route_compute` never looks at which input port a flit arrived on — it
compares destination against its own coordinates and nothing else. The turn
restriction is **emergent from applying the same rule everywhere**: a packet
resolves X completely before it moves in Y, so a packet that is already moving
in Y has, by construction, no X displacement left, and therefore can never
request an X channel. The forbidden turns are not blocked; they are unreachable.

That distinction matters for what actually threatens the property, which is not
one router routing badly but routers **disagreeing** about the order — see D18.

**D18 — The forbidden turns, and what breaks if a Y→X turn happens (§8 Q2).**

Of the eight turns in a 2D mesh, XY forbids the four Y→X turns:
North→East, North→West, South→East, South→West. The four X→Y turns
(East→North, East→South, West→North, West→South) and all straight-through
moves are allowed.

*Empirically, in two parts.*

`mutA` flips the routing order in `route_compute` from XY to YX for every
router. It is caught by tb_router T2a and T3c and by tb_mesh's path assertions.
But it is worth being honest about what that proves: a network where **every**
router uses YX is also deadlock-free — YX is simply the mirror-image ordering,
with the four X→Y turns unreachable instead. `mutA` demonstrates that the
implemented order matches the specified order. It does not demonstrate deadlock.

The mutation that actually attacks the dependency graph is a router that
disagrees with its neighbours, so two further experiments were run:

- **`mutE`** — only r3 (1,1) uses YX. This enables one real Y→X turn: r3 sends
  (0,0)-bound traffic South first, so it arrives at r1 from the north still
  needing X movement, and r1 sends it West. South→West now happens. Caught by
  exactly one assertion, tb_mesh C2's path check on ep3→ep0, which took links
  5,1 instead of 7,3. **No flit was lost and nothing hung: 381 injected, 381
  ejected.** One enabled turn is not a cycle — the counter-clockwise ring still
  needs North→East at r2, which r2 (still XY) cannot produce.
- **`mutF`** — r0 and r3 both use YX, chosen to enable *both* turns the
  counter-clockwise ring needs: North→East at r2 (r0 now sends (1,1)-bound
  traffic north first) and South→West at r1. Caught by two assertions, C2 on
  ep0→ep3 (links 2,6 instead of 0,4) and C2 on ep3→ep0 (links 5,1 instead of
  7,3). **The cycle is now constructible, and still 382 injected / 382 ejected,
  no hang.**

So what breaks if a Y→X turn is allowed is *possibility*, not immediate
failure. `mutF` removes the structural guarantee — after it, a deadlock is
merely a traffic pattern away, and the network's correctness stops being a
property of the design and becomes a property of the workload. That is the
whole argument for the restriction: not that cycles are unlikely, but that they
are unconstructible.

It also means the tests that catch these mutations are the **path** assertions,
never the scoreboard. Loss, duplication and misdelivery checks all pass on
`mutE` and `mutF`. See D22.

**D19 — What XY costs, and what adaptive routing would need (§8 Q3).**

XY is deterministic and oblivious. Deterministic: source and destination fix
the route completely, so there is exactly one legal path per pair. Oblivious:
the routing function cannot see congestion, queue occupancy or link state, so
it cannot react to any of it.

The cost is that a hot link cannot be routed around even when an idle path
exists. This design shows the effect directly. Under the sustained-load case,
all four endpoints sending to ep3, per-source delivery was 33/33/66/67 (D13):
ep0 and ep1 traffic is funnelled onto the single r1-NORTH-to-r3 link and gets
half the service that ep2 and ep3 get, while the r2-EAST-to-r3 link carries only
ep2. An adaptive router could have pushed some ep0 traffic around through r2 and
equalised it. XY cannot, by construction.

Adaptive routing would buy that back and immediately give up the deadlock
argument in D17, because the whole argument is that alternative paths do not
exist. Allowing a packet to take a non-minimal or congestion-dependent turn
reintroduces the Y→X dependencies and the rings in D17 become constructible.
Recovering deadlock freedom then needs **virtual channels**: multiple logically
independent buffer sets per physical link, with the routing function restricted
so that a packet changes to a strictly higher-numbered VC when it takes a turn
that would otherwise close a cycle. The dependency graph becomes acyclic again
because it is now ordered by VC index rather than by dimension.

That is a real cost, not a formality: per-link buffering multiplies by the VC
count, every arbiter gains a VC-selection stage in front of it, and the
per-output round-robin in this design becomes a two-level arbitration
(VC first, then input). On a build whose critical path already runs FIFO read →
route → arbitrate → crossbar → link in one cycle (D15), adding a second
arbitration level lands directly on the worst path. Virtual channels are
explicitly out of scope for this project, and XY is the choice that makes that
scope honest — not a limitation worked around, but the reason no workaround is
needed.

**D20 — On/off flow control rather than credit-based (§8 Q7).**

What is built is on/off: a receiver's `full` deasserts the sender's `ready`,
which masks the arbitration request (D5, D6). The sender holds nothing but a
single ready wire per link, and there are no counters at either end.

Credit-based flow control instead gives the sender a count of free buffer slots
downstream. The sender decrements on send and the receiver returns a credit when
a slot frees. The sender never has to see the receiver's current state, only its
own credit count, which is why credit-based wins when the round-trip signalling
latency is long: with on/off, a receiver that fills must get `full` back to the
sender before the sender stops, and everything already in flight during that
round trip has to be absorbed by buffering that exists solely to cover the
signalling delay.

Here the links are single-cycle and combinational, so that round trip is
effectively zero and there is nothing for credits to hide. The measured cost of
on/off in this build is the buffering the stall occupies, and it is exactly the
FIFOs already on the path, no more:

- Stage 2, one hop, ep0 blocked at ep1: **8 flits** absorbed before backpressure
  reached the injecting endpoint — 2 FIFOs of 4, r0-Local and r1-West.
- Section 6 case 6, two hops, ep0 blocked at ep3: **12 flits** absorbed — 3
  FIFOs of 4, r0-Local, r1-West and r3-South.

Both numbers are exactly `hops x FIFO_DEPTH` with no extra slack anywhere, which
is the signature of a flow control scheme adding nothing of its own. Credit-based
would have needed a credit counter and a return path per link direction — eight
of each in this mesh — to buy back a round-trip delay that is not there.

Credit-based would start to win if links became registered (which is exactly the
pipelining proposed in D15 to break the critical path), or if the mesh grew
physically large enough that a link crossed a chip region, or if buffers were
made deep enough that a per-link occupancy count was worth having for its own
sake. Registering the links is the realistic trigger: it is the one change
already on the table, and it would put a cycle of latency into the ready path
that on/off has to cover with an extra buffer slot per link.

**D21 — Round-robin over fixed priority, with the starvation scenario measured
(§8 Q4).**

Fixed priority is smaller and faster: a leading-one select over the request
vector, no state, no pointer update, one less level of logic on the path D15
identifies as critical. It is rejected anyway, because under sustained load it
does not merely degrade — it stops serving some inputs entirely.

*The exact scenario, measured on this design.* Take one output port with all
five inputs holding a flit for it and refilling every cycle, which is what
tb_router T7 drives. Fixed priority grants the lowest-index requester. Input 0
is refilled the cycle after it is served, so it is requesting again on the next
cycle, and it wins again. Inputs 1 to 4 never win while input 0 has traffic.
Substituting a fixed-priority arbiter (`mutB`) and running that test:

| Arbiter | Grants to inputs 0..4 | Worst-case wait |
|---|---|---|
| Fixed priority (`mutB`) | 199 / 0 / 0 / 0 / 0 | 199 grants, i.e. unbounded |
| Round-robin (as built) | 39 / 40 / 40 / 40 / 40 | **4 grants** |

Four inputs out of five received nothing at all for the whole 200-cycle window.
Not slow service — no service. The only reason they were ever served is that the
test eventually stops injecting, which is why the analysis window has to exclude
the drain (B1).

Round-robin bounds this because the pointer advances past the winner: after
input `i` is granted, it becomes lowest priority, so every other requester is
ahead of it in the rotation and must be served before `i` can win again. With N
inputs the wait is at most N grants. Measured worst case is 4 against the bound
of 5, and it stays 4 when the receiver is only ready 4 cycles in 7 (T8), which
is the case that also depends on the pointer not moving on a stalled request
(D5, T10).

**D22 — What the testbench checks, and what it would miss (§8 Q10).**

*Checks.* 117 assertions at router level in two coordinate configurations, 49 at
mesh level covering all seven §6 cases. Payload integrity, correct destination,
no loss and no duplication all come from one scoreboard mechanism: every
injected flit is pushed keyed by destination, and every ejection must find and
retire an exact match at the endpoint it appeared on. End of test asserts the
scoreboard empty — 381 injected, 381 ejected, 0 outstanding, 0 unmatched.
Bounded service is measured separately. Routing order is asserted on the
**path** a flit took across the links, not on arrival. Invariant 3 is checked
white-box every cycle on all ten arbiters. *(Phase 5: extended to all twenty
mesh arbiters as well — see D27 and the per-arbiter monitor.)* All of it runs
identically under Icarus and XSim, and every check has been shown to fail against at least one
deliberate RTL mutation (D9).

*What it would miss.* Five things, in rough order of how much they should worry
a reader:

1. **It cannot demonstrate deadlock, and would not catch a dependency cycle by
   observing one.** `mutF` enables both Y→X turns the ring in D17 needs, making
   the cycle constructible, and the suite still reports 382 injected / 382
   ejected with no hang — it is caught only by the path assertions noticing the
   route changed. Deadlock needs all four ring channels held at once with full
   FIFOs, and no test drives rotational traffic. Deadlock freedom rests on the
   structural argument in D17, not on simulation, and that is a claim of a
   different kind from everything else in this log.
2. **The compounding-contention margin is unexercised.** The mesh bound is 25
   grants — two round-robin stages of 5 — but the measured worst case under
   sustained load is 5, so the entire range from 6 to 25 has never been
   visited. Nothing is wrong with the design; the reason is the traffic pattern.
   All four sources aim at ep3, so contention resolves at r3's Local arbiter
   with at most three live requesters, and the second stage barely engages. A
   pattern that forced two full five-way contentions in series — several
   sources sharing an intermediate link *and* colliding again at the
   destination — would be needed to put pressure on that bound, and it does not
   exist in the suite. The bound is therefore asserted but not probed.

   ***Superseded by D27.*** This item is wrong, and the error is in the bound,
   not the traffic. Such a pattern cannot be built: a 2×2 gives every router
   three live inputs, the three-way ceiling occurs only at a LOCAL output where
   a grant is terminal, and the true bound for this metric is 5 — the measured
   value. The range 6 to 25 is unreachable by construction, not unvisited. Left
   in place as written because it is what was believed at the time; D27 carries
   the enumeration and the correction.
3. **No off-by-one-cycle or latency assertions.** Tests wait a generous number
   of cycles and then check what arrived. A change that added a pipeline stage
   everywhere would pass every test, so the suite would not notice per-hop
   latency regressing from 1 cycle to 2.

   ***Closed by D29 (Phase 5, Stage C4).*** Per-flit hop-count and cycle bounds
   are now asserted, so a uniformly added pipeline stage fails loudly.
4. **One flit width, one FIFO depth, one mesh size.** DATA_W=32 and
   FIFO_DEPTH=4 throughout. The parameterization is exercised only on coordinate
   width (D11), so a bug that only appears at FIFO_DEPTH=2, at a non-power-of-two
   depth, or at a different payload width would not be found.

   ***Closed by D29 (Phase 5, Stage C3), except for mesh size.*** The full
   regression now runs clean at DATA_W 32 / 40 / 48 / 64 and FIFO_DEPTH 2 / 4 / 8.
   Mesh size remains 2×2 by scope (D23 covers what a 4×4 would change).
5. **No reset-during-traffic test.** Reset is asserted once at the start of each
   run. A flit in flight when reset asserts, or a partially-drained FIFO on reset
   release, is never exercised.

   ***Closed by D29 (Phase 5, Stage C2).*** Reset is now asserted mid-injection
   with flits in flight, with the discard policy stated and asserted rather than
   hand-waved: 12 flits deliberately discarded, scoreboard reconciled.

*Status of this list after Phase 5.* Items 3, 4 and 5 are closed by Stage C;
item 2 was not a gap at all and is superseded by D27; item 1 is the one that
remains, and it is closed not by a test but as an accepted finding in **D34**,
which records why no testbench of this shape could close it.

**D23 — Scaling to 4x4: what changes and what breaks (§8 Q11).**

*What is already ready.* Every width is derived from `X_W`, `Y_W`, `DATA_W` and
`FIFO_DEPTH`, and the router has been synthesized and simulated at
`X_W=Y_W=2` — the coordinate width a 4x4 mesh needs. tb_router runs its whole
suite in that configuration (65 assertions, 0 errors) and it is the only
configuration in which all five output arbiters are live at once (D11). The
routing rule, the arbiter and the FIFO are all size-independent as written.

*What changes mechanically.* `mesh_top` is the only file that has to be
rewritten, and it is pure wiring: 16 router instances instead of 4, 48 link
directions instead of 8, and the tie-off pattern applied to the 16 edge ports
instead of 8. The wiring table in D12 grows but does not change shape. Nothing
inside `rtl/router.v` or below needs to be touched, which is the claim
invariant 6 exists to protect.

*What breaks, or at least stops being free.*

1. **The utilization number does not scale by 4.** 989 LUTs at X_W=Y_W=1 already
   reflects corner-router constant folding: at 1-bit coordinates, `dest_x < 0`
   and `dest_y < 0` are unsatisfiable at r0, so two of its five output arbiters
   fold away entirely (B3), and every router in a 2x2 is a corner. A 4x4 mesh
   has 4 corner routers, 8 edge routers and **4 interior routers with all five
   arbiters live and none foldable**. The right per-router estimate for the
   interior is the 2-bit interior figure, not the 2x2 average. Expect
   noticeably more than 4x989 LUTs for 4x the routers.
2. **Latency and the bounded-wait bound both grow.** Worst-case hop count goes
   from 2 to 6, and the per-source service bound compounds per arbitration
   stage: the 2x2 bound is 5x5 = 25 (D22), and a 4x4 route crossing up to 6
   routers makes it 5^6 in the worst case. That number stops being a useful
   guarantee long before it stops being true, which is the real limitation —
   round-robin bounds each hop, not the path.
3. **The critical path gets worse before it gets better.** D15 already measures
   88% of the critical path as routing delay on a design occupying 2.4% of the
   part. A 4x4 mesh spreads over more of the die, and the dominant term is the
   one that grows with physical distance. Registering the links (D15, fix 1)
   stops being an optional optimization and becomes a prerequisite.
4. **FIFO depth should be revisited, and with it D16.** Depth 4 was chosen for a
   single-cycle link (D3). Once links are registered, the backpressure round
   trip lengthens and depth 4 stops covering it. Deeper FIFOs eventually make
   block RAM plausible, at which point the synchronous-read problem in D16 has
   to be solved rather than avoided.

*What does not break.* Deadlock freedom. The argument in D17 is about the
channel dependency graph being acyclic under XY, and it holds for any 2D mesh of
any size — the rings get longer, and every one of them still needs at least one
Y→X turn to close.

**D24 — Throughput limit and where the bottleneck is (§8 Q12).**

*The limit.* One flit per cycle per link direction, and one flit per cycle per
output port. Each output has one arbiter issuing at most one one-hot grant per
cycle, and the crossbar drives one flit per output, so a router's ceiling is 5
flits per cycle only if all five outputs are active simultaneously and
independently — which T9 confirms actually happens (all five granted in the same
cycle, port coverage `11111`). At 173.3 MHz with a 34-bit flit that is
173.3 Mflit/s per link direction, or about 5.9 Gbit/s per direction and
47 Gbit/s across all 8 link directions if every one were saturated.

*Where the bottleneck actually is, measured.* Not the arbiter. Under the
sustained-load case with all four endpoints sending to ep3, per-source delivery
was 33/33/66/67 out of 199 grants (D13). Every arbiter in that run was behaving
perfectly fairly — the round-robin at r3's Local output split its grants evenly
across the three inputs that were requesting: SOUTH, WEST and LOCAL, a third
each. The asymmetry appears one level up: **ep0 and ep1 traffic converges onto
r3's single SOUTH input port before it ever reaches that arbiter**, so the two
of them share one third between them while ep2 gets a full third to itself over
r3's WEST input.

The bottleneck is therefore the **shared downstream input port**, not the
arbitration that follows it. This is worth being precise about because the
symptom looks like arbiter unfairness and the fix for arbiter unfairness would
do nothing: round-robin is fair over the requesters it can see, and it cannot
see that one of its inputs is carrying two sources' worth of traffic. Fairness
is per-arbiter, not end-to-end, and no local arbitration policy recovers
end-to-end fairness without carrying source information in the flit.

The second-order limit is head-of-line blocking, which follows from the same
structure: each input port has one FIFO with one head flit, so a flit blocked on
a busy output stalls everything behind it in that FIFO even if those flits are
destined for idle outputs. Virtual channels are the standard fix and are out of
scope (D19). At depth 4 the exposure is bounded to 3 flits behind any blocked
head.

**D25 — Phase 4: OpenLane / Sky130 ASIC flow. One clean routed run inside a
25-minute processing timebox; LVS not reached.**

Stretch goal, timeboxed at 25 minutes of processing (setup excluded). Result:
**the flow routed cleanly and produced GDSII**, but the timebox expired during
LVS extraction, so the run is partial and only one clock period was attempted.
No tightening iterations were run. **Nothing in `rtl/` was modified** — the hard
rule held, and the flow needed no RTL change to route.

*Setup, and what it cost.* Docker CLI was present but the daemon was down;
Docker Desktop turned out to be installed under a per-user path
(`%LOCALAPPDATA%\Programs\DockerDesktop`) rather than `C:\Program Files`, and
starting it from there brought the daemon up in 5 seconds. `openlane2` images do
not exist at the obvious tags — `ghcr.io/efabless/openlane2:latest` and
`ghcr.io/librelane/librelane:latest` both 404 — so this is OpenLane 1,
`efabless/openlane:latest`, 5.25 GB. The PDK is not bundled; `volare` inside the
image fetched sky130A into a mounted `PDK_ROOT`.

*One setup problem worth recording.* OpenLane pins an exact open_pdks commit and
refuses to start on a mismatch:
`The version of open_pdks used in building the PDK does not match the version
OpenLane was tested on (installed: c6d73a35..., tested: bdc9412b...)`.
The pinned version download failed partway with `_ssl.c:989: The handshake
operation timed out`. Rather than fight the network, the run used
`flow.tcl -ignore_mismatches`, a documented flag, against the one-revision-newer
PDK. That is a real caveat on every number below: they come from open_pdks
c6d73a35, not the revision OpenLane was validated against.

*Configuration.* Top is `impl/mesh_top_timing.v`, the same registered-boundary
wrapper the Vivado run used, so the DUT boundary is identical and the comparison
is like-for-like at the boundary. `config.json` reads both `rtl/` and `impl/`
via `dir::` paths and is at `openlane/mesh_top_timing/`. Clock period 20 ns
(50 MHz), deliberately loose, because the first goal was closure not a number.
`FP_CORE_UTIL` 30, `PL_TARGET_DENSITY_PCT` 40.

*Results, post-route.*

| Metric | Value |
|---|---|
| Clock period | 20.000 ns |
| Worst setup slack, slowest corner | +7.384 ns |
| Worst setup slack, typical / fastest | +7.577 / +7.751 ns |
| Worst hold slack, all three corners | **+0.11 ns** |
| WNS / TNS reported | 0.00 / 0.00 |
| Detailed-router DRC violations | **0** |
| Layout-vs-layout XOR differences | **0** |
| Standard cells | **8183** |
| Standard-cell area | **97 190.71 µm²** |
| Die area | 580.22 × 590.94 µm = **342 860 µm²** |
| GDSII | written, 26.52 MB |
| LVS | **not reached** |

*Derived Fmax: 20.000 − 7.384 = 12.616 ns → **79.3 MHz**, on an internal
flop-to-flop path.* This corrects an error in the first version of this entry,
which claimed the worst path terminated at output port `ep_out_flit[59]` and
that 79.3 MHz was therefore only a lower bound. That was wrong. It came from
reading the **last** `Startpoint:` block printed in the multi-corner STA log,
which is not the worst path — the log prints 6003 paths in no particular order.
A standalone OpenSTA run against the routed netlist and the slow-corner SPEF
settles it:

| Query | Worst path | Slack |
|---|---|---|
| `report_checks` (any endpoint) | `_13182_ → _13444_`, both flops | **7.384 ns** |
| `report_checks -to [all_registers -data_pins]` | `_13182_ → _13444_`, identical | 7.384 ns |
| `report_checks -to [all_outputs]` | `_12339_ → ep_out_flit[59]` | ~15.4 ns |

The overall worst path and the worst internal path are the **same path**, and
the best port path has more than twice the slack. The boundary is a non-issue
here, and it was never unconstrained in the first place: the flow's own SDC
carries 144 `set_output_delay` and matching `set_input_delay` constraints at
4.000 ns (OpenLane's default 20% of the clock period). So **79.3 MHz is the
ASIC Fmax at this constraint and it is comparable like-for-like with the FPGA's
173.3 MHz**, both being internal flop-to-flop paths.

*Critical path, identified.* Endpoint is named in the netlist:
`_13444_/Q` drives `\u_mesh.u_r2.g_input[3].u_fifo.mem[1][4]` — the **write data
of r2's SOUTH input FIFO memory**. The start flop's output `_00004_` drives the
`.S0` select pins of 4:1 multiplexers, which is a FIFO **read pointer** bit; the
first cell on the path is a `mux4_1` selecting on it, i.e. the `mem[rd_ptr]`
read mux. Between them the path runs through `nand4b_1`, `mux2_1`, `mux4_2`,
`and2_1`, `a221o_1`, `a21o_2`, `and2_1`, `or3_1`, `nand2_1`, `or3_1`, `mux2_1`
plus four drive buffers.

**This is architecturally the same path as the FPGA's**: FIFO read → route and
arbitrate → crossbar → link → downstream FIFO write. Honest limit on the
identification — the two endpoints are confirmed by name, but the middle is
inferred from cell types and position, because Yosys flattening left the
intermediate nets anonymous (`_04037_` and similar). No net on the path carries
an RTL name that would prove which arbiter it crosses.

*Timing breakdown.* Data path delay 11.706 ns (arrival 14.167 minus 2.461 ns of
launch clock network). The slack-derived budget `T_clk − WNS` is 12.616 ns; the
0.910 ns difference is library setup 0.233 + clock uncertainty 0.250 + negative
clock skew 0.531 − CRPR 0.103, the same reconciliation D15 makes for the FPGA.
**17 combinational cells** separate the two flops, of which 4 are drive buffers,
so roughly 13 real logic stages against the FPGA's 7 logic levels.

*Pad-limited or logic-limited — not established.* The expectation going in was
that ~290 top-level ports against ~1000 cells of logic might make the die
pin-limited. The measurement does not answer it: cell area 97 190 µm² divided by
the `FP_CORE_UTIL` of 30 gives ≈324 000 µm², which is essentially the 342 860 µm²
die that came out. **The die was sized by the utilization setting I chose, not
by pin placement**, so nothing here shows whether pins would have forced a floor.
Settling it needs a run with `FP_CORE_UTIL` raised until either pin placement or
routability becomes the binding constraint. Recorded as an open question rather
than as a finding.

*On the checks that passed.* The XOR check states its result positively —
`Total XOR differences: 0` — and is trustworthy as written. The DRC result is
weaker evidence: `reports/routing/drt.drc` is a zero-length file, and an empty
file is consistent both with "no violations found" and with "no report written".
**I did not confirm that check is capable of failing**, so it is recorded as
"0 violations reported" rather than "0 violations". Confirming it would mean
deliberately over-constraining routing until the detailed router gives up and
checking that the file then has content.

*How far the flow got.* Synthesis, floorplan, tap/decap, PDN, placement, CTS,
global and detailed routing, parasitic extraction, three-corner post-route STA,
IR drop, Magic and KLayout GDSII, and the layout XOR all completed. The flow was
inside step 38, Magic SPICE extraction for LVS, when the timebox expired; that
step is slow here because the run directory is a mounted Windows volume. LVS
status is therefore **unknown, not clean** — it never ran.

**D26 — FPGA versus ASIC: what the two numbers do and do not say.**

| | FPGA | ASIC |
|---|---|---|
| Target | Kintex-7 xc7k70tfbv676-1 (28 nm) | Sky130A (130 nm) |
| Flow | Vivado 2025.1, post-implementation | OpenLane 1, post-route |
| Constraint | 6.200 ns | 20.000 ns |
| Worst setup slack | +0.429 ns | +7.384 ns (slowest corner) |
| Hold slack | +0.040 ns | +0.11 ns |
| Frequency | **173.3 MHz**, internal path | **79.3 MHz**, internal path |
| Critical path logic depth | 7 logic levels | 17 cells (~13 logic stages) |
| Area | 989 LUT / 421 FF / 0 BRAM | 8183 cells, 97 190 µm² std cell |

*What the comparison legitimately says.* The same RTL, with the same registered
boundary, closes timing with positive setup and hold margin on two completely
different substrates and two independent tool flows, with zero DRC violations
and zero layout XOR differences on the ASIC side. That is a portability result
and it is the one worth claiming.

*What it does not say.* It is **not** a statement that the design is slower as an
ASIC than on an FPGA. Three reasons, any one of which is disqualifying:

1. **The nodes are five generations apart.** Sky130 is a 130 nm process;
   the Kintex-7 is 28 nm. A 130 nm standard-cell implementation running at a
   lower frequency than a 28 nm FPGA is the expected outcome and says nothing
   about the RTL. The usual "ASIC is several times faster than FPGA" intuition
   compares like nodes, and these are not like nodes.
2. **The ASIC run was one loose-constraint pass.** The FPGA number took three
   tightening iterations and moved 145.8 → 162.1 → 173.3 MHz purely from
   constraint pressure, with no RTL change. The Sky130 run had a 20 ns
   constraint and +7.4 ns of slack, meaning the tool was never asked to try. A
   comparable Sky130 number needs the same two or three tightening passes, which
   the timebox did not allow.

*The interesting question, answered: the balance shifted to logic depth, and the
bottleneck did **not** move off the structure.* The prediction going in was that
the FPGA's 88.5%-routing, fanout-45-arbiter-net critical path would rebalance
toward logic on standard cells, and that the bottleneck might leave the arbiter
entirely. Half right:

- **It rebalanced toward logic, decisively.** On the FPGA the single largest
  contributor to the path was a *net* — 0.988 ns of routing on a fanout-45
  arbiter signal — with routing at 88.5% of the total. On Sky130 the largest
  contributors are *cell* arcs: `mux4_1` at 1.611 ns, `mux4_2` at 1.258 ns,
  `or3_1` at 1.022 ns, the launch flop's clk→Q at 0.955 ns, all driving loads of
  0.068 pF or less. The path is gate-delay-limited, not wire-limited.
- **The logic got deeper, which is the mechanism.** 7 FPGA logic levels became
  17 standard cells (~13 real stages plus 4 drive buffers). One 6-input LUT
  absorbs a chunk of logic that Sky130 has to build from 2-to-4-input gates, so
  the same RTL cone stretches into roughly twice the stages.
- **But it stayed on the same architectural path.** FIFO read pointer → read mux
  → route/arbitrate → crossbar → downstream FIFO write, ending in r2's SOUTH
  input FIFO. The bottleneck did not move to a different structure; the FPGA and
  ASIC agree on *where* the design is slow and disagree only on *why*.

One caveat kept explicit: an exact ASIC logic-versus-routing percentage was not
computed, because OpenSTA folds net delay into each driving cell's arc in this
report format and a separate breakdown was not extracted. The claim above rests
on which individual items are largest and on the load capacitances, not on a
computed split comparable to the FPGA's 11.5 / 88.5.

*That caveat is now closed as a finding: see D35.* It was promoted rather than
resolved — the split is not obtainable from this report format at all, and D35
records the measurement that demonstrates why, plus the Stage B evidence that
strengthens the qualitative claim above.

The tightening passes this entry called for were run in Stage B, and the result
is **D32**. There were nine of them rather than the two or three estimated here,
and they moved the ASIC from 79.26 MHz to **96.61 MHz**, +21.9% with no RTL
change — within a rounding error of the +21.9% the same discipline bought on the
FPGA. So the 79.3 MHz in the table above is the **baseline**, superseded as the
headline ASIC figure by D32's 3.000 ns interior optimum. Everything this entry
concludes survives that supersession: the node gap, the shift from wire-limited
to gate-delay-limited, and the bottleneck staying on the same architectural path
are all properties of the comparison, not of the constraint the ASIC side was
run at. The one row that is period-dependent is critical path depth, which goes
17 cells at 20 ns to 13 at 3.000 ns — tabulated in D35.

**D27 — A 2x2 mesh cannot present a five-way contention; the Case 5 metric is
already saturating its true structural bound of 5, not sitting 20 grants below a
bound of 25 (Phase 5, Stage C).**

Stage C set out to build "two full five-way contentions in series" so the
mesh-level worst-case wait would move off its measured 5 toward the stated bound
of 25. The topology was enumerated exhaustively before any testbench code was
written: all 16 source-destination pairs, their XY paths, and for every output
port in the mesh the set of input ports that can legally hold a flit requesting
it. The enumerator applies the same routing function `route_compute.v`
implements and the link table in `mesh_top.v`; it is reproduced at the end of
this entry.

The pattern was not built. It cannot be built.

*Full path enumeration.* Every legal route in the mesh, as router.input->output:

| src->dst | hops |
|---|---|
| ep0->ep0 | r0.LOCAL->LOCAL |
| ep0->ep1 | r0.LOCAL->EAST, r1.WEST->LOCAL |
| ep0->ep2 | r0.LOCAL->NORTH, r2.SOUTH->LOCAL |
| ep0->ep3 | r0.LOCAL->EAST, r1.WEST->NORTH, r3.SOUTH->LOCAL |
| ep1->ep0 | r1.LOCAL->WEST, r0.EAST->LOCAL |
| ep1->ep1 | r1.LOCAL->LOCAL |
| ep1->ep2 | r1.LOCAL->WEST, r0.EAST->NORTH, r2.SOUTH->LOCAL |
| ep1->ep3 | r1.LOCAL->NORTH, r3.SOUTH->LOCAL |
| ep2->ep0 | r2.LOCAL->SOUTH, r0.NORTH->LOCAL |
| ep2->ep1 | r2.LOCAL->EAST, r3.WEST->SOUTH, r1.NORTH->LOCAL |
| ep2->ep2 | r2.LOCAL->LOCAL |
| ep2->ep3 | r2.LOCAL->EAST, r3.WEST->LOCAL |
| ep3->ep0 | r3.LOCAL->WEST, r2.EAST->SOUTH, r0.NORTH->LOCAL |
| ep3->ep1 | r3.LOCAL->SOUTH, r1.NORTH->LOCAL |
| ep3->ep2 | r3.LOCAL->WEST, r2.EAST->LOCAL |
| ep3->ep3 | r3.LOCAL->LOCAL |

*Per-output contention, every output port in the mesh.* The "sources" column is
which endpoints' traffic can arrive on that input, which is what determines how
deep a merged stream one input can carry:

| output | requesters | input <- sources |
|---|---|---|
| r0.LOCAL | **3** | LOCAL<-{ep0}  NORTH<-{ep2,ep3}  EAST<-{ep1} |
| r0.NORTH | 2 | LOCAL<-{ep0}  EAST<-{ep1} |
| r0.EAST  | 1 | LOCAL<-{ep0} |
| r1.LOCAL | **3** | LOCAL<-{ep1}  NORTH<-{ep2,ep3}  WEST<-{ep0} |
| r1.NORTH | 2 | LOCAL<-{ep1}  WEST<-{ep0} |
| r1.WEST  | 1 | LOCAL<-{ep1} |
| r2.LOCAL | **3** | LOCAL<-{ep2}  EAST<-{ep3}  SOUTH<-{ep0,ep1} |
| r2.SOUTH | 2 | LOCAL<-{ep2}  EAST<-{ep3} |
| r2.EAST  | 1 | LOCAL<-{ep2} |
| r3.LOCAL | **3** | LOCAL<-{ep3}  SOUTH<-{ep0,ep1}  WEST<-{ep2} |
| r3.SOUTH | 2 | LOCAL<-{ep3}  WEST<-{ep2} |
| r3.WEST  | 1 | LOCAL<-{ep3} |

*Per output class.*

| Output class | Max requesters | Why |
|---|---|---|
| LOCAL (ejection) | **3** | all three live inputs can hold a flit for this router |
| Cardinal "toward" | **2** | no-U-turn removes the input the link arrives on |
| Cardinal "away" | **1** | XY forbids the transit flits that would use it |

*Why five-way is impossible.* Two reasons that compound. First, the edge
tie-offs in `mesh_top.v` leave every router with **three live inputs, not
five** — r0 has LOCAL/NORTH/EAST, r1 has LOCAL/NORTH/WEST, r2 has
LOCAL/SOUTH/EAST, r3 has LOCAL/SOUTH/WEST. Each router in a 2x2 has two
neighbours, not four. The arbiters are instantiated N=5 and their internal bound
is genuinely 5 grants, but the mesh can never present more than three requests
to one. Second, XY routing cuts the reachable degree further, per the table
above: no-U-turn caps a cardinal output at two candidate inputs, and XY caps an
"away" output at one.

*Why two maximal contentions cannot be composed.* The ceiling of three occurs
**only at a LOCAL output**, and a LOCAL grant is terminal — the flit ejects and
never arbitrates again. There is no such thing as winning a 3-way contention and
then contending again. Two three-way contentions in series is therefore
impossible for the same structural reason, not merely untested. The deepest
series structure any flit can experience in this topology is **a 2-way cardinal
contention followed by a 3-way local contention**, and the diagonal routes
(ep0->ep3, ep1->ep2, ep2->ep1, ep3->ep0) are the only ones that reach even that:
1-way, then 2-way, then 3-way.

This is a structural argument of the same kind as the deadlock-freedom argument
in D17 — a property established by construction over the channel set rather than
by simulation — and it is worth more than the test it replaces.

*The real bound, and what the measured 5 actually means.* `tb_mesh.v:583` asserts
`max_wait <= 25`, derived as "two round-robin stages of at most 5 grants each".
That derivation assumes five-way arbiters at both stages. The reachable
structure for Case 5's victim (ep0, all four endpoints injecting at ep3) is:

- `r0.LOCAL->EAST` — 1-way, no wait possible
- `r1.WEST->NORTH` — 2-way against ep1's local injection
- `r3.SOUTH->LOCAL` — 3-way against WEST<-{ep2} and LOCAL<-{ep3}

Under saturation the r1.NORTH arbiter alternates strictly between its two
continuously-requesting inputs, so the SOUTH stream arriving at r3 is a 1:1
ep0/ep1 interleave. The r3.LOCAL arbiter is round-robin over three live inputs,
so between two SOUTH grants there is at most one WEST grant and one LOCAL grant.
The worst-case ejection order at ep3 between two ep0 ejections is therefore
`S(ep0) W(ep2) L(ep3) S(ep1) W(ep2) L(ep3) S(ep0)` — five ejections strictly
between the two ep0 events.

| Quantity | Value |
|---|---|
| Bound asserted at `tb_mesh.v:583` (derived, 5 x 5) | 25 |
| **True structural bound for this metric** | **5** |
| Worst measured, Case 5 | **5** |

**Case 5 is already saturating its structural bound exactly.** The gap between 5
and 25 is an artifact of the derivation, not headroom the design has yet to be
pushed into, and there was never 20 grants of unexercised margin to find. The
characterisation in the previous status notes — "the compounding-contention
margin is unexercised" — was wrong: the margin does not exist.

The `max_wait <= 25` assertion is left exactly as written. It is still sound,
being a valid upper bound, and Stage C's constraint is to add to the suite
rather than modify it; retuning a load-bearing test mid-stage is how it rots.
The real bound is recorded here instead.

*Metric correction — first-class, not a footnote.* The replacement pattern
(C8b, next entry) deliberately throttles its victim by head-of-line blocking,
and the victim's end-to-end ejection gap will rise as a direct result. **That
gap is not starvation.** Round-robin promises bounded wait to an input that is
*continuously requesting*; it promises nothing whatsoever to an input whose FIFO
is empty. A victim held back by its own upstream is not being starved by an
arbiter, and asserting on its ejection gap would manufacture a false finding —
reporting a defect where the design is behaving exactly as specified.

This is the same class of error as B1, where tb_router's starvation metric was
undefined for an input that was never served at all and therefore reported
health while four of five inputs received nothing. Both are the same mistake:
**a fairness metric evaluated over a window in which the fairness property does
not apply.** The difference is that B1 was found after the test was written and
believed correct, and this one was found before any testbench code existed,
because the bound was derived from the topology first. Deriving the structural
bound before writing the test is what turned a would-be false positive into a
design finding.

The consequence for the build: C8b's load-bearing assertions are lossless
delivery and scoreboard reconciliation under sustained HOL blocking, with the
ejection gap reported as a measurement only. The fairness property is asserted
instead by the per-arbiter monitor, which counts grants issued by an arbiter
while a given input's `req_masked` is held high and ungranted. That formulation
is immune to offered-load effects by construction, which is precisely why it is
the right instrument here.

*Documentation corrected in the same pass.* This entry invalidated four shipped
claims, all repaired alongside it: a "margin is unexercised" line in the
project's own working notes (a local file, not part of the published repo),
`RATIONALE.md` Q10 (false causal clause attributing the low number to
single-destination convergence), `RATIONALE.md` Q11 (the 5^2 figure for a 2x2;
the 4x4 claim survives and the discontinuity is now stated explicitly), and the
same two in `RATIONALE_FULL.md`.

*Enumerator.* Reproduced so the tables above are re-derivable without rerunning
the build. Port encoding 0 LOCAL, 1 NORTH, 2 EAST, 3 SOUTH, 4 WEST.

    my @R = ([0,0],[1,0],[0,1],[1,1]);           # r0..r3
    my @PN = ("LOCAL","NORTH","EAST","SOUTH","WEST");
    sub rid { my($x,$y)=@_; for my $i (0..3){ return $i if $R[$i][0]==$x && $R[$i][1]==$y } -1 }
    sub route { my($mx,$my,$dx,$dy)=@_;          # mirrors route_compute.v
      return 2 if $dx>$mx; return 4 if $dx<$mx;
      return 1 if $dy>$my; return 3 if $dy<$my; return 0 }
    my %LINK = (1=>[0,1,3], 3=>[0,-1,1], 2=>[1,0,4], 4=>[-1,0,2]);  # out -> dx,dy,in
    my %req;
    for my $s (0..3) { for my $d (0..3) {
      my ($cx,$cy) = @{$R[$s]}; my ($dx,$dy) = @{$R[$d]}; my $in = 0;
      for (my $g=0; $g<8; $g++) {
        my $r = rid($cx,$cy); my $o = route($cx,$cy,$dx,$dy);
        $req{"$r,$o"}{$in}{$s} = 1;
        last if $o == 0;
        my ($ddx,$ddy,$nin) = @{$LINK{$o}};
        $cx += $ddx; $cy += $ddy; $in = $nin;
      } } }
    for my $k (sort keys %req) {
      my ($r,$o) = split /,/, $k; my @ins = sort keys %{$req{$k}};
      printf "r%s.%-6s %d  %s\n", $r, $PN[$o], scalar(@ins),
        join("  ", map { "$PN[$_]<-{".join(",", map {"ep$_"} sort keys %{$req{$k}{$_}})."}" } @ins);
    }


**D28 — Per-arbiter monitors on all twenty mesh arbiters, plus C8a/C8b
head-of-line traffic; D27's enumeration converted from a paper argument into a
measured one (Phase 5, Stage C).**

Three mechanisms added to `tb/tb_mesh.v`, all running continuously across every
case in the file, and two new traffic cases. No `rtl/` file was touched, so the
Phase 3 FPGA and Phase 4 ASIC numbers stand and Stages A/B are not invalidated.

*Scale, before and after.* Icarus, full mesh regression:

| | before | after |
|---|---|---|
| assertions | 49 | **96** |
| flits injected / ejected | 381 / 381 | **2200 / 2200** |
| outstanding, unmatched | 0, 0 | **0, 0** |

*What was built.*

1. **Per-arbiter bounded-wait monitor**, all 20 arbiters (4 routers × 5
   outputs). Counts, per arbiter per input, the grants that arbiter issues while
   that input's request is visible to it and ungranted; asserts the count never
   exceeds N=5. The wait is counted in *grants issued by that arbiter*, never in
   cycles: a cycle where the arbiter grants nobody is not a cycle anyone was
   passed over, and a masked request is not a request. That is what makes the
   check immune to offered-load effects, which is the whole point of D27's
   metric correction.
2. **Invariant 3 monitor**, all 20 arbiters. `priority_ptr` may change only on a
   cycle where its output both granted and the receiver was ready. This is the
   mesh-level counterpart of tb_router's T10, which covers only the ten
   router-level arbiters.
3. **Requester census**, all 20 arbiters. Records the maximum number of
   simultaneous *unmasked* requesters each arbiter ever sees, and asserts it
   against the caps D27 derived by enumeration.
4. **C8a — uniform all-to-all saturation.** All four endpoints inject every
   cycle, cycling destination through all four endpoints. First case in the
   suite where an input FIFO holds flits for *different* output ports, so the
   first that can exhibit head-of-line blocking at all. Offered load is
   symmetric under the mesh's rotation group, so the end-to-end gap is a fair
   measure here and is asserted.
5. **C8b — targeted compounding contention under HOL blocking.** ep0 cycles
   `[→ep2,→ep2,→ep2,→ep1]`; ep1 alternates `[→ep2,→ep1]`, feeding both the 2-way
   contention at r0.NORTH (via r1→r0→r2) and the 3-way contention at r1.LOCAL;
   ep2 and ep3 stream at ep1, merging at r3.SOUTH. Victim ep0, observed at ep1.
   The deepest series structure the topology allows (D27).

*Results.*

| Measurement | Value |
|---|---|
| C5 worst wait (untouched test) | 5, unchanged — bound 25 still asserted |
| C8a worst end-to-end gap, any source at any endpoint | **3** (bound 25) |
| C8b measured gap at ep1: ep0 / ep2 / ep3 | **14 / 4 / 4** |
| Per-arbiter worst wait, any arbiter, whole run | **2 grants** (bound 5) |
| C8b flits delivered exactly once under sustained HOL | **619 / 619** |

C8b's 14-versus-4 split is head-of-line blocking made visible: ep0 is throttled
three-to-one by its own schedule, and its ejection gap rises accordingly while
ep2 and ep3, which are not throttled, stay at 4. Per D27 that gap is **reported,
not asserted** — a source held back by its own upstream is not being starved,
and asserting on it would manufacture a defect where the design is correct. What
C8b asserts instead is what a sustained stalled FIFO head actually puts at risk:
invariants 4 and 5, no loss and no duplication. 619 injected, 619 ejected, zero
unmatched.

*D27 is now measured, not merely argued.* The requester census reproduces the
enumerated caps **exactly** on all twelve live arbiters — not merely within
them:

| router | LOCAL | NORTH | EAST | SOUTH | WEST |
|---|---|---|---|---|---|
| r0 measured / predicted | 3 / 3 | 2 / 2 | 1 / 1 | 0 / 0 | 0 / 0 |
| r1 measured / predicted | 3 / 3 | 2 / 2 | 0 / 0 | 0 / 0 | 1 / 1 |
| r2 measured / predicted | 3 / 3 | 0 / 0 | 1 / 1 | 2 / 2 | 0 / 0 |
| r3 measured / predicted | 3 / 3 | 0 / 0 | 0 / 0 | 2 / 2 | 1 / 1 |

A second, independent confirmation falls out of the bounded-wait monitor: the
worst wait at any arbiter across the whole 2200-flit run is **2 grants**, which
is exactly (3 requesters − 1). Round-robin over k continuously-requesting inputs
passes an input over at most k−1 times; measuring 2 says the mesh never presented
a fourth requester to any arbiter, arrived at from a different direction than the
census. The arbiters' own bound of 5 is unreachable in a 2×2, as D27 argued.

*One correction caught by the Stage C exit criterion.* The monitor as first
built checked bounded-wait on all 20 arbiters — but `RATIONALE.md` §5's claim is
specifically about the *pointer-update* property, not bounded wait. As shipped,
the §5 sentence was false for the mesh. The exit criterion requires fixing the
monitor to the documentation rather than the documentation to the monitor, so
the invariant 3 monitor (mechanism 2 above) was added and §5 is now true as
written. It was caught because `mutS` was caught by tb_router's T10 and by
nothing at mesh level — a mutation escaping one bench and not the other is what
exposed the gap.

*Mutation validation.* Every new assertion family has been shown to fail against
a deliberate RTL mutation, run out-of-tree so no mutated source enters `rtl/`:

| mutation | what it breaks | caught by | evidence |
|---|---|---|---|
| `mutB` — fixed priority, rotation removed | invariant 2 | **bounded-wait monitor** | fires cyc 189 naming r3 output 0 inputs 3 and 4; C5 does not notice until cyc 582. Worst wait 312 grants against bound 5 |
| `mutS` — `req_masked[k][i] = req[i][k]`, arbiter sees unmasked requests | invariant 3 | **invariant 3 monitor** | the only mesh-level check that fires; tb_router T10/T8 also catch it |
| `mutY` — Y before X in `route_compute.v` | invariant 1 | **D27 requester caps** | r0.EAST, r2.EAST and r3.WEST each measure 2 requesters against a predicted 1; C2 path assertions also fire |
| `mutR` — `else if (\|grant)` → `else if (\|req)` | **nothing — vacuous** | not catchable | see below |

*`mutR` is provably vacuous, and that is worth recording.* The intended
invariant 3 mutation at `rr_arbiter.v:62` cannot be caught by any test, because
it does not change the design. `grant` is the leading-one of `req` after
rotation, so `grant` is non-zero exactly when `req` is non-zero; `|grant` and
`|req` are the same expression. Running it produced output **bit-identical** to
the baseline across all 2200 flits — Compare-Object reported zero differing
lines. An assertion cannot be validated against a mutation that produces an
identical design, and a mutation that is believed meaningful but is not would
have silently certified the monitor as validated when it was not. The real
invariant 3 defect lives one level up, in where the masking is applied
(`router.v`, D5), which is what `mutS` mutates and what the new monitor catches.

*Tools.* Icarus 14.0 and Vivado 2025.1 XSim produce identical output — 96
checks, 0 errors, and the same measured values line for line. Yosys re-run on
the unchanged `rtl/`: `Found and reported 0 problems`, `Found 0 SCCs`, no
inferred latches.

**D29 — Stage C2/C3/C4: reset during traffic, parameter sweep, latency bounds.
Stage C complete; RTL frozen for Stages A and B (Phase 5).**

Three remaining Stage C items built together in `tb/tb_mesh.v`. As with D28, no
`rtl/` file was touched — so the Phase 3 FPGA and Phase 4 ASIC numbers still
come from the code in the repo, and Stages A/B may now run against frozen RTL.

*Scale.* Default configuration, Icarus:

| | after D28 | after D29 |
|---|---|---|
| mesh assertions | 96 | **109** |
| flits injected | 2200 | **2376** |
| ejected / discarded / outstanding / unmatched | 2200 / — / 0 / 0 | **2364 / 12 / 0 / 0** |

---

**C2 — reset during traffic (Case 9).**

*The policy, decided explicitly rather than hand-waved.* A flit accepted into
the network but not yet ejected when reset asserts **is lost, without
exception**. `fifo.v` clears `wr_ptr`, `rd_ptr` and `count` on reset and
deliberately does not clear `mem`; the stale payload is unreachable because the
pointers and count say the FIFO is empty. Reset means discard, not drain. There
is no flush protocol and none is in scope.

The scoreboard therefore cannot be carried across a reset — every outstanding
entry would score as a loss and the end-of-test check would fail on correct
behaviour. It is purged instead, and **the purge count is asserted non-zero**,
because a purge of zero would mean the test proved nothing.

That forced a second change. The end-of-test conservation check was
`total_ejected == sb_n`, which is false the moment a reset legitimately discards
anything: it failed at 2376 injected against 2364 ejected. It was **not**
weakened to an inequality. A `sb_discarded` counter was added and the check is
now `total_ejected + sb_discarded == sb_n` — still exact, with the policy-defined
loss accounted for by name rather than tolerated.

*Measured at the moment of reset.* Reset is asserted mid-injection with `valid`
still high on every endpoint; injection is not stopped first, because reset
landing on an active handshake is the case worth testing.

| Quantity | Value |
|---|---|
| FIFOs non-empty when reset asserted | **11 of 20** |
| flits resident in the mesh | **12** |
| scoreboard outstanding | **12** |
| purged by policy | **12** |
| FIFOs non-empty after reset | **0 of 20** |
| `priority_ptr` values not zero after reset | **0 of 20** |
| pre-reset flits ejected after reset (zombies) | **0** |
| post-reset all-to-all delivered | **16 of 16** |

*Mutation validation.* Two mutations, and the first one is a lesson in what a
validating mutation has to be.

- `mutFR` — reset removed from `fifo.v` entirely. **Rejected as a validator.**
  It is too destructive to prove anything: `count` is X from power-up, the
  design never works at all, and the run dies on a simulation timeout at Case 1.
  A mutation that breaks everything does not demonstrate that Case 9
  specifically is load-bearing.
- `mutFR2` — reset removed but replaced with an `initial` block setting the same
  three registers. This is the right validator, and it describes a **real
  hazard**: on an FPGA the bitstream initializes registers exactly this way, so
  a missing reset is invisible in any test that resets only once at time zero.
  On an ASIC those registers power up X. `mutFR2` **passes every existing case —
  C1 through C8** — and fails only at Case 9, on three separate assertions:
  FIFOs not empty after reset (`r0` input 0 count=2, four others non-zero), an
  output still asserting valid during reset, and **ZOMBIE FLIT** — something
  injected before the reset ejected after it, which is stale `mem` being re-read
  through a pointer that never cleared.
- `mutPR` — `priority_ptr` reset removed. Caught by the pointer check: all five
  `r0` arbiters read X after reset.

---

**C4 — latency bounds.**

Every scoreboard entry is stamped with its injection cycle; retirement computes
end-to-end latency and bins it by hop count, because a 2-hop flit legitimately
costs more than a 1-hop one and one global bound would hide a regression in the
cheap case.

*Measured, and the structure is exact.* On an idle mesh the cost is **one cycle
per hop plus one for ejection**, with zero jitter — min equals max at every hop
count:

| hops | unloaded (min = max) | loaded min / mean / max | n |
|---|---|---|---|
| 0 | 1 | 1 / 2 / 11 | 563 |
| 1 | 2 | 2 / 6 / 34 | 1176 |
| 2 | 3 | 3 / 12 / 57 | 625 |

*Two different bounds, for two different things.* `LAT_UNLOADED_BOUND = 3` is
set to the exact observed worst case on an idle mesh and deliberately **not**
padded — padding it defeats the purpose, since a single extra pipeline stage
takes a 2-hop flit from 3 cycles to 5 and must fail. `LAT_LOADED_BOUND = 200` is
deliberately loose at roughly 3.5x the worst measured 57: loaded latency is
queueing delay and a function of offered load, so a tight bound there would
constrain the traffic pattern rather than the design. It exists to catch an
unbounded stall, not to police jitter.

*Mutation validation.* `mutLAT` adds one pipeline stage on flit visibility in
`fifo.v` — a newly written flit becomes visible to route compute one cycle late.
It is safe by construction: it can only ever delay availability, never create a
phantom, because drain still deasserts through the `count` term. The result is
the exact regression class the spec named — **functionally correct, measurably
slower**:

| | baseline | `mutLAT` |
|---|---|---|
| 1-hop min | 2 | **3** |
| 2-hop min | 3 | **4** |
| unloaded worst | 3 | **6** |
| flits lost | 0 | **0** |
| assertions firing | none | **C4 only** |

Every other assertion in the file passes under `mutLAT`: nothing is lost,
nothing is duplicated, the scoreboard reconciles, the arbiters stay in bounds.
Before C4 existed, this mutation was invisible to the entire suite.

---

**C3 — parameter sweep.**

*One source change was needed first.* `mk_flit` built the payload by
concatenation as `{dx, dy, src, seq, MAGIC}`, which is exactly 32 bits and
therefore silently mis-sized the moment `DATA_W` moved off 32 — the testbench
itself carried the bug class the sweep exists to hunt. It now writes the payload
by field position (`src` top 8 bits, `seq` next 16, `MAGIC` bottom 8, zero
padding between), correct at any `DATA_W >= 32`. Below 32 the fields would
overlap; that is the documented floor.

Configuration is by prefix file rather than command-line define — a two-line
`.vh` compiled ahead of the testbench, since macros persist across files in
compilation order. Icarus accepts `-DCFG_DATA_W=64`, but Vivado's `xvlog -d`
splits a valued macro on the `=` and fails with `Can not find file: 64`. The
prefix file works identically in both and needs no define support at all.

*Results — seven configurations, all passing:*

| DATA_W | FIFO_DEPTH | result |
|---|---|---|
| 32 | 2 | PASS (103 checks) |
| 32 | 4 | PASS (109 checks) |
| 32 | 8 | PASS (121 checks) |
| 40 | 2 | PASS (103 checks) |
| 48 | 4 | PASS (109 checks) |
| 64 | 4 | PASS (109 checks) |
| 64 | 8 | PASS (121 checks) |

The check count tracks `FIFO_DEPTH` because Case 6 injects `8*FIFO_DEPTH` flits
and asserts the endpoint of each. Invariant 6's claim — that scaling is an
instantiation change, not a rewrite — is now tested across four payload widths
and three FIFO depths rather than asserted.

*Mutation validation — and this is the one that shows the sweep earns its keep.*
`mutW` changes one line of `route_compute.v` from
`flit[DATA_W +: Y_W]` to `flit[32 +: Y_W]` — the classic hardcoded magic width,
and precisely what invariant 6 forbids.

| config | `mutW` result |
|---|---|
| DATA_W=32 | **PASS, 109 checks, 0 errors** |
| DATA_W=48 | FAIL, 15 errors |
| DATA_W=64 | FAIL, 48 errors |

At the default configuration the bug is completely invisible — every one of the
109 assertions passes, including all of D28's monitors. Only running at another
width exposes it. That is the entire argument for the sweep, demonstrated rather
than asserted.

---

*Stage C exit criterion, discharged.* `RATIONALE.md` §5 and the D22 note claim
the white-box pointer check covers all twenty mesh arbiters. Verified against
the landed testbench: 20 `priority_ptr` taps, 20 `req_masked` taps, 20 requester
census taps, `ARB_N = 20`. The claims are true as written; neither was
retrofitted.

*Tools.* Icarus 14.0 and Vivado 2025.1 XSim agree. Yosys on the unchanged
`rtl/`: `Found and reported 0 problems`, `Found 0 SCCs`, no inferred latches.

*Stage C is complete. RTL is frozen.* Stages A and B may now run, and their
numbers will come from the code in the repo. Nothing in C1-C4 found a defect in
`rtl/` — four assertion families were added and validated against six
mutations, and the design passed all of them.


**D30 — Stage A: the Sky130 flow completes, and LVS is clean.** The Phase 4 row
had read "routed, DRC and XOR clean, LVS not reached" since the flow stalled in
Magic's SPICE extraction (B7). With that stall root-caused and fixed, one full
OpenLane run at the unchanged 20 ns period, tag `run_lvs2`, carried the design
through every signoff step for the first time.

*Results.* netgen reports `LVS reports no net, device, pin, or property
mismatches. Total errors = 0`, comparing Magic's LEF-extracted layout netlist
(`MAGIC_EXT_USE_GDS=0`) against the `vlog2Verilog` powered netlist
(`LVS_INSERT_POWER_PINS=1`). Magic signoff DRC `COUNT: 0`. KLayout DRC 0.
KLayout-vs-Magic GDS XOR 0 differences. Magic's extraction feedback file
`38-spice.ext_feedback.txt` is empty at 0 lines. GDSII written, 27 MB.

*Signoff DRC and the antenna check had never run either.* They sit after `lvs`
in OpenLane's step order — `gds_magic -> gds_klayout -> lvs -> drc ->
antenna_check` — so the B7 stall blocked three signoff results, not one. The
"0 DRC violations" quoted previously came from the routing-stage Magic DRC check
that runs immediately after detailed routing, which is an earlier and different
check from signoff DRC. Stage A converted three unknowns into results, and one
of them is not clean; see D31.

*The baseline reproduced bit-exactly.* Against `run_loose`, with `rtl/` frozen
at Stage C and the identical pinned PDK
(`open_pdks c6d73a35f524070e85faff4a6a9eef49553ebc2b`, matching
`run_loose/PDK_SOURCES`):

| Metric | run_loose | run_lvs2 |
|---|---|---|
| Setup slack, max RC corner / Slowest lib | +7.3836 ns | +7.3836 ns |
| Hold slack, max RC corner / Fastest lib | +0.1112 ns | +0.1112 ns |
| Fmax at the 20 ns period | 79.26 MHz | 79.26 MHz |
| Cell count, Yosys | 8183 | 8183 |
| Chip area, Yosys | 97190.7136 um2 | 97190.7136 um2 |
| Floorplan | 569.02 x 568.48 | 569.02 x 568.48 |

Every digit matches, so the flow is deterministic across the mount change and
79.3 MHz stands as the Phase 4 figure. It remains a single loose pass; Stage B
tightens it.

*Tools.* OpenLane 1.1.1 in `efabless/openlane:latest`, with Yosys, OpenROAD,
Magic, netgen and KLayout. Full flow wall time 12m27s, exit code 0. Step
runtimes: SPICE extraction 16.52 s, LVS 8.67 s, signoff DRC 132.29 s, antenna
check 2.64 s.

**D31 — 20 antenna violations, found the first time the check ever ran.**
OpenROAD's antenna rule checker ran for the first time in this project
(`run_lvs2`, step 44) and reports 20 violating pins: 16 on met1, 2 on met2, 2 on
met3. Worst partial/required ratio is 3.27 — partial 1307.0 against a required
400.0 — on net `_03645_`, pin `_08627_/A1`, met1. Second and third worst are
2.83 and 2.64, also met1. The full list is
`reports/signoff/44-antenna_violators.rpt`.

*Why this was invisible until now.* The antenna check sits after `lvs` in the
step order, so the B7 extraction stall prevented it from ever running (D30). It
is not a regression — nothing about the design changed. It is a result that was
never previously obtained.

*Status: open, folded into Stage B.* OpenLane does not fail the flow on antenna
violations by default, which is why `run_lvs2` completed with exit code 0
despite them. Recording the finding here rather than leaving it silent, per the
Phase 5 rule that gaps are written up rather than passed over. The standard
remedies — raising `GRT_ANTENNA_ITERS`, or diode insertion via
`DIODE_INSERTION_STRATEGY` — cost area and are an implementation trade-off, not
an RTL change, so `rtl/` stays frozen either way and this does not invalidate
Stage A or B. Decided: carry it into Stage B rather than fix it in isolation,
because Stage B is already trading area against period and the antenna remedies
draw on the same budget. Every Stage B pass therefore records the antenna
violator count alongside period, WNS, cell count and area, and D31 closes when
Stage B does — either at 0 violators or as a written acceptance with the area
cost of clearing them stated.

**D32 — Stage B: the ASIC tightening sequence, and why its x-axis is an
optimisation driver rather than a constraint.** Phase 4's last open item was a
post-route Fmax obtained by tightening rather than from one loose pass. Nine
full OpenLane runs, `CLOCK_PERIOD` the only variable, every other knob
regenerated identically each pass. Pass/fail is scored on setup slack at the
**max RC corner / Slowest lib** — the corner the 79.26 MHz baseline came from,
and the one OpenLane itself never checks (B8).

*Result: 79.26 MHz -> 96.61 MHz, +17.35 MHz, +21.9%, with no RTL change and
1.94% more area.*

| CLOCK_PERIOD | Slowest WNS | Achieved path | Fmax | Synth area (um2) | Post cells | Core area (um2) | Antenna pins | Worst ratio | Hold @ Fastest |
|---|---|---|---|---|---|---|---|---|---|
| 20.000 | +7.3836 | 12.6164 | 79.26 | 97190.7136 | 71602 | 323476.4896 | 20 | 3.27 | +0.1112 |
| 12.000 | -0.6164 | 12.6164 | 79.26 | 97190.7136 | 71602 | 323476.4896 | 20 | 3.27 | +0.1112 |
| 6.000 | -5.5952 | 11.5952 | 86.24 | 97190.7136 | 70946 | 323476.4896 | 13 | 3.17 | +0.0987 |
| 4.000 | -6.9118 | 10.9118 | 91.64 | 99081.2768 | 72761 | 329739.9968 | 21 | 2.99 | +0.0884 |
| 3.500 | -7.0600 | 10.5600 | 94.70 | 99075.0208 | 72351 | 329739.9968 | 13 | 3.43 | +0.0827 |
| 3.250 | -7.2819 | 10.5319 | 94.95 | 99075.0208 | 72319 | 329739.9968 | 16 | 3.41 | +0.0842 |
| **3.000** | **-7.3513** | **10.3513** | **96.61** | **99075.0208** | **72220** | **329739.9968** | **17** | **3.46** | **+0.0851** |
| 2.500 | -8.0882 | 10.5882 | 94.44 | 99075.0208 | 73385 | 329739.9968 | 19 | 3.41 | +0.0297 |
| 2.000 | -8.6264 | 10.6264 | 94.11 | 99075.0208 | 75279 | 329739.9968 | 14 | 3.42 | -0.0716 |

*The curve has three regions, and only the middle one is a tightening
sequence.* From 20 ns to about 6.3 ns the implementation does not change at all
— bit-identical netlist and DEF, 79.26 MHz throughout, because OpenLane's
optimisers work at the Typical corner where slack is still hugely positive
(B8). Below that knee, measured at 6.2447 ns, the resizer engages and the
achieved path falls: 11.5952 ns at 6.000, 10.9118 at 4.000, 10.3513 at 3.000.
Below 3.000 it **rises again** — 10.5882 at 2.500 and 10.6264 at 2.000 — so the
sequence has a genuine interior optimum rather than an asymptote.

*The turning point is the interesting part, and it is the §8 Q9 answer.* Past
the optimum the tool keeps spending area and stops buying speed. Placed
instances go 72220 -> 73385 -> 75279 from 3.000 down to 2.000 ns, 4.2% more
cells, while Fmax falls 96.61 -> 94.44 -> 94.11 MHz and final utilisation drops
40.47% -> 34.75% as the design spreads out. The resizer is buffering paths it
cannot fix; the added buffers lengthen the very paths they were inserted to
repair. Area and speed are positively correlated only up to the knee, and
decouple below it.

*Cost of the 21.9%.* Yosys chip area 97190.7136 -> 99075.0208 um2 (+1.94%),
core area 323476.4896 -> 329739.9968 um2 (+1.94%), placed instances 71602 ->
72220 (+0.86%). Yosys cell count is 8183 at every single period — synthesis
under `SYNTH_STRATEGY "AREA 0"` maps the same cells throughout and the area
change is cell *sizing*, not cell count. The one synthesis-area step is between
6.000 and 4.000 ns (97190.7136 -> 99081.2768), so abc's mapping does respond to
the period, but only once and only below the knee.

*Hold degrades monotonically and is what rules out the bottom of the range.*
Hold slack at the Fastest corner — the corner that governs hold — falls
+0.1112 -> +0.0851 across the useful range and goes **negative at 2.000 ns**
(-0.0716). So 2.000 ns is disqualified on hold as well as on frequency. At the
chosen 3.000 ns it is +0.0851 ns, positive with margin. The separate negative
min-delay numbers seen at the Slowest corner are an artefact of `set_input_delay`
being 0.20 x period: the worst hold path migrates off internal logic onto an
input port as the period shrinks (internal `_13399_`->`_13400_` at 20 ns,
`ep_in_flit[87]` at 12 ns, `ep_in_flit[82]` at 6 ns). Internal hold is not
degrading; the constraint on the wrapper's ports is.

*Signoff held at every point in the sequence.* All nine runs: netgen LVS clean,
Magic signoff DRC 0, KLayout DRC 0, GDS XOR 0 differences, tritonRoute 0
violations. Tightening bought 21.9% without breaking a single signoff check.

*Antenna violations do not track the period.* Counts across the sweep are 20,
20, 13, 21, 13, 16, 17, 19, 14 — no monotonic trend in either direction, so the
concern that tighter constraints would lengthen metal runs and multiply
violations is not borne out. Worst partial/required ratio does drift up slightly,
3.27 at baseline to 3.46 at the chosen point. The count is dominated by routing
detail rather than by constraint. Verdict and closure of D31 is D33.

*Reproducibility.* The repo's `openlane/mesh_top_timing/config.json` carries
`CLOCK_PERIOD` 3.000 so a clone reproduces the headline run. Flow wall time per
pass ran 12m27s at 20 ns to 14m07s at 3 ns, rising with the extra resizer and
routing work.

*Tools.* OpenLane 1.1.1 in `efabless/openlane:latest`, Yosys, OpenROAD resizer
and OpenSTA, Magic, netgen, KLayout. Both design and PDK in container-local
volumes throughout (B7).

**D33 — The 20 antenna violations are accepted, with the cost of clearing them
measured rather than estimated. D31 closes.** D31 required either 0 violators or
a written acceptance stating what clearing them would cost. Both remedies were
run at the chosen 3.000 ns operating point so the cost is measured.

*Starting point.* At 3.000 ns the design has **17 violating pins across 16 nets**,
worst partial/required ratio **3.46** — partial 1382.78 against a required 400.0
— on net `_03630_`, pin `_08617_/A1`, met1. The count is 17 rather than D31's 20
because the layout changed with the period; across the whole Stage B sweep the
count moved between 13 and 21 with no trend (D32).

*Remedy 1, more global-route repair iterations: no effect whatsoever.*
`GRT_MAX_DIODE_INS_ITERS` 1 -> 5, everything else identical. The run's
`config.tcl` confirms the value took (`set ::env(GRT_MAX_DIODE_INS_ITERS) "5"`),
and the routed DEF came back **bit-identical**, md5 `65b665c8...` against
`65b665c8...`. Same 17 violations, same 96 diodes, same slack. OpenROAD's
global-route antenna repair converges in a single iteration on this design, so
the iteration count is not a lever. Recording this because it looks like the
obvious first knob and it is inert.

*Remedy 2, heuristic diode insertion: works, and costs more than it is worth.*
`RUN_HEURISTIC_DIODE_INSERTION` 1 with `DIODE_ON_PORTS "in"`:

| Metric | `sb_03p000` | `sb_03p000_heur` | Delta |
|---|---|---|---|
| Antenna violating pins | 17 | **3** | -14 |
| Worst partial/required ratio | 3.46 | 2.05 | -1.41 |
| Setup WNS, Slowest | -7.3513 | -7.6492 | -0.2979 |
| Achieved path | 10.3513 ns | 10.6492 ns | +0.2979 |
| **Fmax** | **96.61 MHz** | **93.90 MHz** | **-2.71** |
| Diode cells | 96 | **6029** | +5933 |
| Placed instances | 72220 | 75543 | +4.6% |
| Final utilisation | 40.4748% | 44.9774% | +4.50 pts |
| Flow wall time | 14m07s | **6h17m46s** | 27x |

Signoff stayed clean throughout — LVS clean, Magic DRC 0, KLayout DRC 0, XOR 0,
hold at Fastest +0.0873 ns.

*Verdict: accept the violations.* Clearing costs **2.71 MHz, 2.8% of the
frequency the whole Stage B bisection was run to win**, plus 5933 extra diode
cells. At the LEF size of `sky130_fd_sc_hd__diode_2`, 0.920 x 2.720 um, that is
**14846 um2 of added diode area** — 4.5% of the 329740 um2 core. And it still
does not reach zero: 3 violations remain, one of them at ratio 1.00, exactly on
the limit. Paying a fifth of the stage's frequency gain for a partial fix is the
wrong trade, so the violations stand as a documented open item.

*A wrong estimate, corrected in the open.* Before running remedy 2 the cost was
estimated at roughly 17 diodes, about 43 um2, on the assumption that a diode is
inserted per violating pin. The measurement is **6029 diodes and 14846 um2**,
some 350x that estimate, because heuristic insertion places diodes on every pin
meeting the threshold rather than only on violators. The estimate was wrong in
kind, not just in magnitude, which is the reason D31 demanded a measured cost
rather than an argued one.

*What would actually fix this.* Not a diode strategy but shorter met1 runs on
the offending nets — local jogging or promoting those routes to a higher layer,
which is a router-level fix outside both the CLOCK_PERIOD scope of this stage
and the frozen `rtl/`. Noted as a recommendation, not run.

*Tools.* OpenLane 1.1.1, OpenROAD antenna checker and global router, Magic,
netgen, KLayout, `md5sum`.

**D34 — Finding: the suite cannot demonstrate deadlock, and a simulation of this
shape never could. Accepted in writing rather than fixed (Phase 5, Stage D).**
The project's completion criteria require every remaining verification gap to be
either closed or written up as a finding carrying its evidence and the reason the
evidence cannot be obtained. This is the first of two. It is recorded as a
finding rather than a caveat because the limitation is structural: it is not an
artefact of how much testbench time was spent, and no further testbench work
removes it.

*The finding.* `tb_mesh.v` produces no evidence for or against deadlock freedom.
Every deadlock-relevant check it carries is an assertion about the *route a flit
took*, never about the absence of a cyclic wait.

*The evidence, already on the record.* D18's mutations E and F are the only
experiments that have ever put a genuine Y→X turn into this mesh:

- **`mutE`** — only r3 (1,1) uses YX, creating one real South→West turn. Caught
  by exactly one assertion, tb_mesh C2's ep3→ep0 path check, which saw links 5,1
  instead of 7,3. **381 injected / 381 ejected, no hang.**
- **`mutF`** — r0 and r3 both use YX, enabling both turns the counter-clockwise
  ring needs (North→East at r2, South→West at r1), so the channel dependency
  cycle becomes constructible. Caught by two path assertions, C2 on ep0→ep3 and
  C2 on ep3→ep0. **382 injected / 382 ejected, no hang, scoreboard reconciled.**

With the structural guarantee deleted, the loss, duplication, misdelivery and
bounded-wait checks all passed unchanged. The suite did not notice that the
property it exists to protect had been removed.

*Why the evidence cannot be obtained.* Two independent reasons, either one
sufficient.

1. **Deadlock freedom is universally quantified over traffic; simulation
   samples.** A cyclic wait needs all four ring channels held simultaneously with
   full FIFOs and every holder blocked on the next. `mutF` makes that state
   reachable, but reaching it requires rotational traffic that saturates the ring,
   and "the suite ran without hanging" over a finite stimulus is not evidence that
   no stimulus hangs. Adding a rotational pattern and a watchdog would move the
   boundary by one pattern, not remove it.
2. **The project's own standard for an assertion cannot be met here.** D9
   requires every assertion to have been shown to fail against a deliberate RTL
   mutation, on the grounds that an assertion which has never failed is not
   evidence. A hang watchdog against the real RTL can never fire, because XY makes
   the cycle unconstructible — that is the theorem, not a test result. Make it fire
   by combining `mutF` with rotational traffic and what has been demonstrated is
   that *the mutant* deadlocks, which is a property of the mutant. Neither
   configuration yields a statement about the shipped design.

*What the claim rests on instead, and why that is stronger rather than weaker.*
D17: XY resolves all X displacement before any Y movement, so a packet already
moving in Y has no X request left to make; each of the two rings around the
square needs a Y→X turn to close; both are unreachable; the channel dependency
graph is therefore acyclic and deadlock is impossible by construction rather than
improbable in practice. That is a statement over all traffic patterns, which is
strictly more than any finite simulation can return, and it is why the design
carries no timeout, no detection and no recovery. Stated honestly: deadlock
freedom here is argued structurally, and simulation corroborates it only in the
weak sense that nothing ever hung.

*What would actually close it, and why it was not done.* Formal property
checking — a bounded model check over the channel dependency graph, or symbolic
reachability over the ready/valid handshake — is the right instrument for a
universally-quantified property, and it would return the same answer D17 argues
by hand. It is outside this build's scope. Recording that the correct instrument
exists and was not used is part of the finding; omitting it would overstate what
the project establishes.

*What this does not diminish.* `mutE` and `mutF` earn their place regardless.
They are what establishes that the **path** assertions, and only the path
assertions, are load-bearing for routing order — the scoreboard is blind to a
dimension-order change because a Y-first route reaches the same endpoint over
different links. They are also why RATIONALE §2 can say that what breaks under a
forbidden turn is *possibility*, not function.

*Where a reader meets this.* Stated in `RATIONALE.md` §10, `RATIONALE_FULL.md`
§10 and `README.md` under "The testbench is itself tested", so the limitation
appears beside the mutation table that produced it rather than only here.

*Status.* **Accepted, not fixed.** *Tools.* Icarus Verilog 14.0 and Vivado XSim
(the D18 mutation runs). Nothing was re-run for this entry.

**D35 — Finding: the exact ASIC logic-versus-routing split is not obtainable in
this report format, measured rather than asserted. D26's caveat closes (Phase 5,
Stage D).** The second of the two gaps that close as findings.

*The finding.* There is no Sky130 figure comparable to the FPGA's logic 0.640 ns
(11.5%) / routing 4.903 ns (88.5%) from D15, and none can be produced from the
reports this flow writes without re-deriving each cell arc's delay-versus-load
sensitivity by hand. This is not a flag that was left unset.

*Why. OpenSTA's path format attributes net RC to the driving cell.* Each cell row
carries a delay computed against the capacitance of the net it drives, so the
wire's contribution is already inside the cell number. The separate net rows
carry only the interconnect propagation OpenSTA attributes on its own, and on
this design that is negligible.

*Measured, so the claim is evidence and not an excuse.* Summing the net-delay
column across the entire data path of the Slowest-corner critical path, launch
flop Q to capture flop D, in the baseline run and the chosen Stage B point:

| Run | Constraint | Data-path cells | Summed net delay | Implied "routing" share |
|---|---|---|---|---|
| `run_lvs2` | 20.000 ns | 17 | 0.04 ns | 0.4% |
| `sb_03p000` | 3.000 ns | 13 | 0.03 ns | 0.3% |

Taken at face value those say the ASIC path is 99.6–99.7% logic against the
FPGA's 11.5%. That is not a measurement of the design; it is the report format.
The largest single net delay anywhere on the 3.000 ns path is **0.01 ns**,
against a largest cell arc of **1.51 ns** — which is a sharper statement of
"gate-delay-limited" than D26 could make, and simultaneously the reason the
percentage split is unusable in the direction the FPGA-versus-ASIC comparison
needs.

*The qualitative finding stands, and Stage B strengthened it.* Both runs launch
from the **same** flop, `_13182_` — the FIFO read-pointer bit whose `mux4` select
starts the path (D25). The tightening remapped the cone to fewer, higher-drive
stages:

| | 20.000 ns (`run_lvs2`) | 3.000 ns (`sb_03p000`) |
|---|---|---|
| Data-path cells | 17 | 13 |
| Of which buffers / delay cells | 5 | 3 |
| Real logic stages | 12 | 10 |
| Cell types, in path order | `mux4_1`, `buf_2`, `nand4b_1`, `mux2_1`, `mux4_2`, `and2_1`, `a221o_1`, `a21o_2`, `and2_1`, `or3_1`, `buf_2`, `nand2_1`, `or3_1`, `buf_2`, `buf_4`, `mux2_1`, `clkbuf_1` | `mux4_2`, `and4b_1`, `mux2_1`, `a211o_4`, `and4b_1`, `a221o_1`, `a21o_4`, `dlygate4sd1_1`, `clkbuf_2`, `and3_1`, `a221o_2`, `mux2_1`, `clkbuf_1` |
| Largest cell arc | `mux4_1` 1.61 ns | `mux4_2` 1.51 ns |

The endpoint differs — `_13444_` at 20 ns, `_13384_` at 3.000 ns — so this is the
same cone, not a re-identified endpoint, and it is stated as such.

*D26's endpoint identification, corroborated directly.* D26 named the 20 ns path
as ending in r2's SOUTH input FIFO. That was inference at the time; the
`run_lvs2` gate-level netlist settles it, mapping `_13444_` to
`u_mesh.u_r2.g_input[3].u_fifo.mem[1][4]` — router 2, input port 3 (SOUTH, per
D1), FIFO storage slot 1, bit 4. The inference was correct.

*A claim that had run ahead of the log, now backed.* `RATIONALE.md` §9 and
`RATIONALE_FULL.md` already state that the Stage B path is "13 standard cells
deep" and that tightening cut it from 17. Stage B recorded frequency, area and
cell count but not path depth, so until this entry those two figures had no log
entry behind them. They are now verified against the committed Slowest-corner
reports of both runs. No flow was re-run and no number changed.

*What would close it properly, and why it was not attempted.* A genuine split
needs per-net parasitics attributed separately from cell arcs: read the SPEF,
re-derive each arc's delay at zero load, and difference the two. That is a
modelling exercise rather than a report option, and it would need the
`sb_03p000` gate-level netlist and SPEF. Not attempted, and recorded as not
attempted.

*Evidence kept in the repo.* The OpenLane run directories are gitignored (~800 MB
across eleven runs, regenerable from `openlane/mesh_top_timing/config.json`), so
Stage E extracted what this entry and D26, D32 and D33 cite into
`reports/asic/` — per-run `metrics.csv`, and for both runs above the
Slowest-corner worst path pulled out of an 18–21 MB `multi_corner_sta.max.rpt`.
The two tables here are re-derivable from
`reports/asic/*_slowest_critical_path.rpt` without re-running anything.

*Status.* **Accepted as not obtainable in this report format.** D26's caveat
paragraph now points here. *Tools.* OpenSTA multi-corner reports from the
`run_lvs2` and `sb_03p000` run directories, `awk` for the column sums, and the
`run_lvs2` gate-level netlist for the flop mapping. No flow was re-run.


**D36 — The OpenLane image is pinned by digest and by platform, not by the
`latest` tag.**
Every docker command in `README.md` referenced `efabless/openlane:latest`. A
moving tag means a stranger following the README gets whatever OpenLane is
current on the day they clone, not the one that produced the numbers beside the
instructions — which breaks the requirement that a stranger can clone the repo
and reproduce its numbers, silently and at an unpredictable future date. All
four references in `README.md` now read
`efabless/openlane@sha256:26719ced90c315b8b4ad7b9dc3e9a176991cea4c3f3282660d8d60d0f0cae229`.

*What the digest is.* The `RepoDigests[0]` of the locally pulled
`efabless/openlane:latest`, confirmed against the remote registry with
`docker manifest inspect` as a valid multi-architecture manifest list (amd64 and
arm64), so the pinned reference is pullable by someone who has never had the
tag. OpenLane version 1.1.1.

*How it was confirmed to be the image the runs actually used.* Not by date —
the image reports a `Created` timestamp of `1970-01-01T00:00:01Z`, a
reproducible-build epoch, and its image ID happens to equal its manifest digest
under the containerd image store, so neither field carries provenance. The
evidence is the nix store paths instead. `run_lvs2` (Stage A) recorded three:
`xpc7xd67rslanlqh566s6jph53bn830w-openlane1-1.1.1`,
`sx2v0i73mn1ih2z1nk61pm9n5gjgpidy-yosys` and
`wq2q0njg3sx8wvj2akz7x1qxwyrv9xlr-yosys-abc`; `sb_03p000` (Stage B, the run the
96.6 MHz figure comes from) recorded the same openlane1 path. All three exist,
byte-identically, in the image now carrying that digest.

That check is stronger than it first looks. A nix store path is a content hash
of the derivation output, and `flow.tcl` — which pins openroad, magic, netgen,
klayout, opensta, iverilog and verilator by their own exact nix hashes — lives
*inside* the `xpc7xd67…-openlane1-1.1.1` derivation. An identical openlane1 hash
therefore implies every tool binary in the flow is identical, not merely that
OpenLane's version string matches. Had `latest` moved to a different build since
the runs, these hashes would differ. They do not.

*Amendment: the index digest alone was not sufficient.*
`sha256:26719ced…` is a manifest **list**, not a single image — it covers
`linux/amd64` and `linux/arm64`. Docker resolves a manifest list to the host's
architecture silently, so on an ARM machine that same digest yields the arm64
variant: a separate build whose nix store paths differ from the ones recorded by
`run_lvs2` and `sb_03p000` by construction, since a nix output hash is
platform-specific. The identity argument above, and therefore every published
ASIC number, holds for amd64 only. Pinning the index digest without the platform
left exactly the hole the pin was meant to close, just a narrower one.

`docker image inspect` reports the local image as `Architecture: amd64`,
`Os: linux`, on an `x86_64` daemon, so both runs used the amd64 variant. Its
per-platform manifest digest is
`sha256:764bc72b66d4d3d1b168d6cb307bcac0b169cf847f663dc3aaf38b06d0099285`
(the arm64 sibling, recorded only to identify what is *not* being claimed, is
`sha256:840fe28388494220dae9e2be6cf3c7cb2dadfa0eabae4144f0873b9ee949597f`).
Every `docker run` in `README.md` now carries
`--platform linux/amd64`, which also lets an ARM host reproduce the published
numbers under emulation — slower, but the identical binaries. The arm64 variant
was not pulled or inspected; that its nix paths differ is a structural property
of per-platform nix builds, not something measured here.

*Tools.* Docker Desktop 4.87.0 / Engine 29.7.2 (`docker inspect`,
`docker manifest inspect` for the per-platform digests, `docker image inspect`
by digest and for the `Architecture` field, `docker info` for the daemon
architecture), `grep` over the `run_lvs2` and `sb_03p000` run directories for
the recorded nix store paths. No flow was re-run and no RTL, testbench or
OpenLane config was touched.

**D37 — One post-freeze edit to `rtl/`, comment-only, proven not to change the
netlist.** The header comment of `rtl/fifo.v` justified `full` not bypassing a
simultaneous pop by pointing at a hazard list in a file that is not part of the
repo, which left a reader with nothing to follow. The comment now names the loop
it avoids directly: `full` → request masking → grant → crossbar, which a
pop-bypassing `full` would close through the upstream `ready`. No code changed.

Because the RTL was frozen before Stages A and B, any `rtl/` edit would normally
invalidate every FPGA and ASIC number. This one is shown not to. The flattened
Yosys run (`hierarchy -top mesh_top; flatten; proc; opt; fsm; opt; memory; opt;
techmap; opt; check -assert; scc`) was taken before and after the edit; the
`stat` output and the `write_verilog -noattr` netlist are **byte-identical**
(matching SHA-256), `check -assert` reports no problems and `scc` finds 0 SCCs.
The Icarus `tb_mesh` regression still reports **PASS, 109 checks, 0 errors**
(2376 injected, 2364 ejected, 12 discarded by reset, 0 outstanding, 0 unmatched).
Every published number therefore still comes from the RTL in the repo.

*Tools.* Yosys (oss-cad-suite), Icarus Verilog `iverilog`/`vvp`, PowerShell
`Get-FileHash`.

## Bugs


**B1 — tb_router's starvation metric was blind to starvation.**

*Symptom.* The Phase 1 bench passed 38 of 38 checks against `mutB`, an
`rr_arbiter` mutated to plain fixed priority
(`assign grant = req & (~req + ONE_N)`, rotation removed). The sustained-load
test is the one test fixed-priority arbitration must fail — that is the entire
reason it exists — so a pass against `mutB` was a failure of the bench.

*Caught by.* Mutation testing under XSim, not by the bench itself — this is the
bug the bench had, so no test reported it. Instrumenting T7 with a per-source
histogram showed the truth: under load, source 0 took 200 of 216 grants and
sources 1–4 took exactly 4 each.

*Root cause.* The metric was **gap since that input's own last service** —
`n - last_ej[s]`, the distance between two consecutive ejections carrying the
same source id. That quantity is *undefined* for an input that is never served:
with no two services there is no pair to take a distance between, so a starved
input contributed no sample at all and could not raise the maximum. Starvation
was invisible by construction, not by an off-by-one — the more completely an
input was starved, the less the metric had to say about it. A second defect hid
the backstop: the analysis window ran to the end of the log, including the drain
after streaming stopped, where a starved input finally gets served once its
rival goes idle, so the `last_ej[p] >= 0` "was it ever served" check passed too.

*Fix.* Replaced the metric with "grants observed since this input was last
served", which is what §3.5 actually bounds and which counts a never-served
input at its true value; froze the analysis window at `stream_ej = ej_count`
before the drain; added a per-input fair-share assertion
(`served[p] >= upto/10`, against an expected `upto/5`); added T8, sustained load
with the receiver ready only 4 cycles in 7.

*Before/after.* Against `mutB`, before: PASS, 38 checks, 0 errors, reported
worst-case wait 1 grant. After: FAIL, 51 checks, 10 errors, reported worst-case
wait 199 grants against a bound of 5 and per-input service 199/0/0/0/0. Against
the real RTL the same checks give worst-case wait 4 grants and per-input service
39/40/40/40/40 out of 199 grants.

*Mutation coverage.* Four mutations, one invariant each, all caught in both
regression configurations. Counts are total errors across both configs:

| Mutation | Before T10 | After T10 | Caught by |
|---|---|---|---|
| `mutA` Y-first routing | 4 | 4 | T2a, T3c |
| `mutB` fixed priority | 20 | 20 | T7/T8 `max_wait`, fair share |
| `mutC` unmasked req + lossy pop | 14 | **16** | T4b, T5 x4, T8 x2, T10 |
| `mutD` unmasked req only | 2 | **4** | T8 `max_wait`, T10 |

`mutD` used to be a **single-covered mutation**: T8 was the only test that saw
it, through exactly one assertion (`max_wait <= 5`), because T7 holds every
output ready for its whole run and cannot distinguish a phantom grant from a
real one (detail in B2). T10 removes that single point of coverage by checking
the cause white-box instead of the consequence: `priority_ptr` may change only
on a cycle where the output both granted and was ready. The "and was ready" is
the load-bearing half — checking `|grant` alone would not catch `mutD`, which
does issue a grant, just for an output that cannot take the flit.

**B2 — T7 alone could not see a priority pointer advancing on a grant that never
happened.**

*Symptom.* `mutD` — `router.v` with the request masking removed
(`req_masked[k][i] = req[i][k]`) but the pop still gated by `out_ready`, so no
flit is lost and invariant 3 is violated in isolation — passed every test in the
bench including the rebuilt T7.

*Caught by.* T8 in tb_router under XSim, the sustained-load test with the LOCAL
receiver deasserting ready 3 cycles in every 7. T7 cannot see it because T7
holds every output ready for its whole run, so a pointer that advances on
phantom grants advances identically to one that advances on real ones.

*Root cause.* With requests unmasked, the arbiter issues grants for an output
that cannot accept a flit and advances `priority_ptr` past inputs that were never
actually served, so the rotation loses its place whenever the output is blocked.

*Fix.* No RTL change — the shipped design already masks requests before the
arbiter (D5). The fix was to the bench: T8 now covers the case, and the masking
contract is documented in the `rr_arbiter.v` header so a future refactor cannot
quietly reintroduce it.

*Before/after.* Against `mutD`, T7 reports worst-case wait 4 grants (passes);
T8 reports worst-case wait 8 grants against a bound of 5 (fails). Against the
real RTL, T8 reports worst-case wait 4 grants, per-input service 34/34/34/34/35
out of 171 grants, 191 flits injected and 191 ejected.

**B3 — Router at (0,0) synthesizes with 44 flip-flops, not the hand-counted 50.**

*Symptom.* Vivado synthesis of `router.v` at the default parameters reported 44
flip-flops. Hand count is 5 FIFOs × (2 wr_ptr + 2 rd_ptr + 3 count) + 5 arbiters
× 3-bit `priority_ptr` = 35 + 15 = 50. Reading a synthesis log includes checking
that the reported flop count roughly matches a hand count of the storage the
design is supposed to have, so the 6-flop gap had to be explained rather than
accepted.

*Caught by.* Vivado 2025.1 `synth_design`, by listing every FLOP_LATCH cell and
grouping by parent instance.

*Root cause.* Not a bug. Instances `g_output[3].u_arb` (SOUTH) and
`g_output[4].u_arb` (WEST) have no flops because at MY_X=0, MY_Y=0 with 1-bit
coordinates `dest_x < MY_X_V` and `dest_y < MY_Y_V` are unsatisfiable, so those
two request bits are constant zero and both arbiters constant-fold away. That is
the edge-port tie-off of a corner router, proved by synthesis rather than
assumed.

*Fix.* None needed. Confirmed it is parameter-driven and not a hardcoded
assumption by re-synthesizing the same RTL at X_W=2, Y_W=2, MY_X=1, MY_Y=1 — a
4×4-scale interior router: all five arbiters survive, 50 flip-flops, exactly the
hand count, 0 latches.

*Before/after.* Corner router (X_W=Y_W=1, at (0,0)): 493 slice LUTs — 373 as
logic, 120 as distributed RAM — 44 FFs, 0 latches. Interior router (X_W=Y_W=2,
at (1,1)): 762 slice LUTs — 642 as logic, 120 as distributed RAM — 50 FFs,
0 latches. Target part xc7a35tcpg236-1, out-of-context, no timing constraint.

**B4 — Yosys reports 60 control flops per router where the hand count is 50.**

*Symptom.* `yosys -p "... proc; opt; fsm; opt; memory; opt; techmap; opt; check
-assert; stat"` on `router.v` reported 680 `$_DFFE_PP_` plus 50
`$_SDFFE_PN0P_` and 10 `$_SDFF_PN0_`. The 680 is exactly the FIFO storage
(5 FIFOs x 4 entries x 34 bits) and matches. The 60 reset flops do not: the hand
count is 5 FIFOs x (2 wr_ptr + 2 rd_ptr + 3 count) + 5 arbiters x 3-bit
priority_ptr = 35 + 15 = 50. Per module, each `fifo` showed 9 reset flops
instead of 7.

*Caught by.* Yosys 0.68 `stat`, by comparing the per-module counts against a
hand count. It is invisible in simulation and Vivado does not show it.

*Root cause.* Not a design bug. Yosys's MEMORY_DFF pass logged
`Extracted addr FF from read port 0 of fifo.mem: $\mem$rdreg[0]` — it pulled the
`rd_ptr` register into the memory's read port to turn the asynchronous read
`mem[rd_ptr]` into a synchronous read port, which is behaviour-preserving. But
`rd_ptr` still has other loads (the wrap comparison and the occupancy count), so
the original register survives too and the address register is a duplicate:
2 extra flops per FIFO, 10 per router.

*Fix.* None. Confirmed by dumping the register cells: each FIFO holds
`\wr_ptr` (2), `\rd_ptr` (2), `\count` (3) and the duplicate
`$\mem$rdreg[0]$q` (2). Vivado, which has a real distributed-RAM primitive with
an asynchronous read, does not make the duplicate and reports exactly the
hand-counted 7 control flops per FIFO.

*Before/after.* Same RTL, two mappings. Yosys generic: 680 storage flops +
60 control flops, 0 `$dlatch`, 0 warnings, 0 combinational loops. Vivado
xc7a35tcpg236-1: storage as 120 LUTs of distributed RAM (180 RAMD32 + 60 RAMS32)
and 44 flops, 0 latches. The two disagree on flop count only because Yosys has
no LUTRAM target here, not because the design differs.

**B5 — Testbench cycle counter raced the ejection monitor, making reported
cycle numbers simulator-dependent.**

*Symptom.* The same `tb_router.v` reported test T6's two contending flits
ejecting on cycles 115 and 116 under Vivado XSim but 114 and 116 under Icarus
Verilog 14.0. All 51 assertions passed under both, so no test flagged it.

*Caught by.* Running both simulators on the same source and diffing the output,
which is the only reason it surfaced.

*Root cause.* `always @(posedge clk) cyc = cyc + 1;` used a blocking assignment
while the ejection monitor read `cyc` on the same posedge, so the two always
blocks raced and the value recorded depended on which the simulator scheduled
first.

*Fix.* Changed the counter to non-blocking (`cyc <= cyc + 1`), so every reader
deterministically sees the pre-edge value.

*Before/after.* Before: T6 reported cycles 115 and 116 (XSim) versus 114 and 116
(Icarus). After: both simulators report 114 and 115, and the full run is
identical between them — 51 checks, 0 errors, T7 worst wait 4 grants with
per-input service 39/40/40/40/40, T8 worst wait 4 grants with 34/34/34/34/35.
The mutation suite also now returns identical error counts under both
simulators: mutA 2, mutB 10, mutC 7, mutD 1.

**B6 — The first mesh-level combinational loop check could not have found a
loop.**

*Symptom.* `yosys -p "hierarchy -top mesh_top; ...; check -assert; scc"`
reported `Found 0 SCCs in module mesh_top` and 0 problems. The number was right
but the check was not: it was run on the hierarchical netlist.

*Caught by.* Reading what the Yosys `scc` pass actually does before trusting
its answer, rather than by any test. On a hierarchical design `scc` analyses
each module separately and treats a `router` instance as an opaque cell, so it
has no way to see a path entering a router's input and leaving its output
combinationally. The loop the mesh is at risk of is exactly that shape: a
router's `out_ready` depending on its neighbour's `in_ready` around the four
sides of the square. Every link in that ring crosses a module boundary, so the
hierarchical run was structurally incapable of reporting it.

*Root cause.* Verification-side, not RTL: `flatten` was missing from the pass
list, so the analysis never saw the ring as a single graph.

*Fix.* Added `flatten` before the loop analysis, giving the checked command
`yosys -p "hierarchy -top mesh_top; flatten; proc; opt; fsm; opt; memory; opt;
techmap; opt; check -assert; scc" rtl/*.v`. Then confirmed the check is not
vacuous with a positive control: making the FIFO's `full` bypass a simultaneous
pop (`count == CNT_DEPTH && !rd_en`) — precisely the change decision D4 exists
to avoid — closes the ready path through grant and back to ready.

*Before/after.* Hierarchical run on the real design: `Found 0 SCCs`, which
proved nothing about the ring. Flattened run on the real design: `Found 0 SCCs
in module mesh_top`, 0 problems, 0 latches — this one is meaningful. Flattened
run on the positive control: **`Found 1 SCCs in module mesh_top`**. So the mesh
ready path is loop-free, D4's reasoning holds at mesh level and not just at
router level, and the check that says so can actually fail.

**B7 — Magic's SPICE extraction hung on the PDK mount, not on the design
directory.**

*Symptom.* The Sky130 flow reached step 38, `Magic Spice Export from LEF`, and
never returned. `38-spice.log` stopped growing at 51,720 bytes with the final
line `Processing mesh_top_timing`. Every earlier step, including detailed
routing, routing-stage DRC and GDS XOR, completed normally. Because
`run_lvs_step` is `run_magic_spice_export` followed by `run_lvs`, and `drc` and
`antenna_check` follow `lvs`, this single hang withheld three signoff results
(D30, D31).

*Caught by.* Reading `/proc/<pid>` of the live Magic process inside the running
container, after a second run reproduced the identical stall.

*Root cause.* Magic's extraction is dominated by small-file reads of the PDK,
and the PDK was mounted from Windows over Docker Desktop's 9P/drvfs transport —
`/proc/mounts` inside the container showed
`C:\134 /pdk 9p ro,...,msize=65536`. Every such read is a cross-OS RPC. The
earlier diagnosis blamed the *design* directory's I/O and prescribed moving the
design into a container-local volume. That was the wrong mount. Run `run_lvs1`
did exactly that — design on ext4, PDK still on 9P — and stalled at the same
step, `38-spice.log` frozen at 51,719 bytes on the same `Processing
mesh_top_timing` line. Moving the design roughly halved the time taken to
*reach* the stall, 11m39s to about 6m, and moved the stall itself not at all.

*Evidence at the stall.* Magic's `wchan` was `p9_client_rpc`. 5,196,745
voluntary context switches against 37 involuntary. 13,650 jiffies of system time
against 552 of user time — 96% of its life in the kernel awaiting 9P round
trips, not computing. `/work` was `ext4` in that same container, so the design
directory was demonstrably not the bottleneck.

*Fix.* Put the PDK in a container-local volume too. Copying it across 9P was
itself the same pathology: 2.2 GB moving at 10-15 MB/min, extrapolating to
2.5-3.5 hours. So `volare` fetched the identical pinned version straight into
the volume over the network in about a minute —
`volare enable --pdk sky130 c6d73a35f524070e85faff4a6a9eef49553ebc2b`, the exact
hash recorded in `run_loose/PDK_SOURCES`. The PDK is therefore provably
unchanged and the reproduced numbers remain comparable to the baseline.

*Before/after.* Step 38, SPICE extraction: on 9P, never completed — observed
past 25 minutes with zero log growth and confirmed blocked in 9P RPC, in two
independent runs. On ext4: **16.52 seconds**. netgen LVS immediately after:
8.67 seconds. Full flow 12m27s, exit code 0, LVS `Total errors = 0`.

*Asymmetry worth recording.* The 9P penalty is on small-file reads, not
throughput. Copying the 854 MB of finished run output back out to Windows took
11 seconds. Many small reads are pathological; bulk writes are fine. This is why
"copy in, run local, copy out" works at all.

*Tools.* Docker Desktop 4.87.0 with Engine 29.7.2, OpenLane 1.1.1, Magic,
netgen, volare.

**B8 — Tightening CLOCK_PERIOD from 20 ns to 12 ns produced a bit-identical
implementation, because OpenLane optimises at one corner and signs off at
another.** Stage B pass 1 set `CLOCK_PERIOD` to 12.000 ns, 0.6164 ns below the
measured 12.6164 ns critical path, expecting OpenROAD to work harder under the
tighter constraint. Signoff reported setup WNS **-0.6164 ns** at the max RC
corner / Slowest lib — exactly the baseline +7.3836 ns shifted by the -8.0000 ns
period delta, to four decimal places. A slack that moves by precisely the change
in constraint means the path did not change at all.

*How it was caught.* Not by the slack number, which on its own looks like an
ordinary failed timing run. `md5sum` on the two runs' outputs:

| Artifact | run_lvs2 (20 ns) | sb_12p000 (12 ns) |
|---|---|---|
| `results/synthesis/mesh_top_timing.v` | `64508735...` | `64508735...` |
| `results/final/verilog/gl/mesh_top_timing.v` | `cdd6b31f...` | `cdd6b31f...` |
| `results/routing/mesh_top_timing.def` | `c2973d12...` | `c2973d12...` |
| `results/final/def/mesh_top_timing.def` | `c2973d12...` | `c2973d12...` |

Bit-identical netlist and bit-identical layout. Every derived metric agreed
too: 8183 cells, 97190.7136 um2, 71602 placed instances, 323476.4896 um2 core
area, 87 diodes, 7205 fill cells, 20 antenna violations at worst ratio 3.27.
An 8 ns tightening of the constraint changed nothing whatsoever in the design.

*The constraint did propagate.* `results/final/sdc/mesh_top_timing.sdc` carries
`create_clock -name clk -period 12.0000` against the baseline's `20.0000`, so
this is not a stale-config or overwrite failure.

*Root cause.* OpenLane's synthesis and its placement and routing resizers
evaluate timing at the **Typical** corner only —
`read_liberty -corner Typical .../sky130_fd_sc_hd__tt_025C_1v80.lib` in
`logs/routing/19-rsz_design_sta.log` — while signoff
(`logs/signoff/31-rcx_mcsta.max.log`) is multi-corner and the quoted figure is
the **Slowest** corner, `sky130_fd_sc_hd__ss_100C_1v60.lib`. On this design the
two corners differ by roughly 6.4 ns of path delay. At a 12 ns period the
routing-stage STA reports worst setup slack **+6.3241 ns at Typical**, so
`repair_timing` sees no violation, inserts no buffer and resizes no cell. The
optimiser was never asked to do anything.

*Consequence for the stage.* `CLOCK_PERIOD` is inert on the implementation for
every period above the Typical-corner path delay, measured at **6.2447 ns**. In
that whole range — 20 ns down to about 6.3 ns — the design is one fixed layout
and 79.26 MHz is a constant, not a floor that tightening will lift. The premise
that a tighter constraint makes OpenROAD try harder is false anywhere above that
knee. A tightening sequence only becomes a real experiment below it.

*A second-order effect, verified so it is not mistaken for noise.* The Slowest
corner's worst slack moved by exactly the period delta, but the Typical corner's
moved by -7.6124 ns rather than -8.0000. The cause is that OpenLane sets IO
delays as a fixed fraction of the clock period: `set_input_delay 4.0000` at
20 ns becomes `2.4000` at 12 ns, i.e. 0.20 x period. IO paths therefore gain
relief as the period shrinks, and the Typical worst path migrated from an output
port path (`Endpoint: ep_out_flit[59]`) at 20 ns to an internal flop-to-flop
path (`Endpoint: _13444_`) at 12 ns. The Slowest corner's worst path is internal
flop-to-flop at both periods, which is why it tracked the constraint exactly and
why the headline figure is an internal path rather than an I/O artefact.

*Tools.* OpenLane 1.1.1, OpenROAD resizer and OpenSTA, Yosys, `md5sum`.

**B9 — The README's OpenLane copy-back step misplaced results on a fresh clone,
because `runs/` is gitignored and so does not exist there.**
*Symptom.* The last README command, `cp -a /work/.../runs/run1
/host/openlane/mesh_top_timing/runs/`, exited 0 but put the run's contents
directly in `runs/` (`runs/reports/`, `runs/results/` and so on), with no
`run1/` directory. The README's own pointer to the signed-off frequency,
`reports/signoff/*-sta-rcx_max/` under the run, was therefore not where a reader
following it would look.
*Caught by.* The fresh-clone reproduction below, the first time the README's
OpenLane block was run from a clone rather than from the working copy, where
`runs/` already existed from earlier runs and hid the problem.
*Root cause.* When the destination directory does not exist, `cp -a SRC DST/`
creates `DST` as a copy of `SRC` rather than copying `SRC` into it, and a
gitignored directory is never present in a clone.
*Fix.* The command now runs `mkdir -p /host/openlane/mesh_top_timing/runs`
before the `cp`. Re-run against an empty destination, it exits 0 and produces
`runs/run1/reports/metrics.csv` as documented.

*The reproduction that found it, and what it showed.* Commit `b450942` was
cloned from GitHub into an empty directory, and the README's OpenLane block was
run verbatim except for using two new, empty volumes (`noc_work_repro`,
`noc_pdk_repro`), since the staging step's `rm -rf /work/openlane/*/runs` would
otherwise have wiped the stored Stage B runs. So the PDK was fetched from scratch
by `volare`. `docker pull` by the pinned digest exited 0, as did the PDK fetch,
staging and the copy-back. The flow exited 255 with `Flow failed` on a Typical-corner
setup violation, which is the documented, intended result at 3.000 ns (B8). The
flow took 13 m 22 s.

Against the published `sb_03p000` row of `reports/metrics.csv`, **89 of 93
columns are identical**. The four that differ are the run tag, `total_runtime`,
`routed_runtime` and `Peak_Memory_Usage_MB`. Identical columns include
synth_cell_count 8183, TotalCells 72220, CoreArea 329739.9968 µm², wire length
344140, vias 71053, every WNS/TNS figure, critical_path_ns 3.91, routing, Magic
and KLayout violations 0, lvs_total_errors 0, and 17 pin / 16 net antenna
violations. The Slowest-corner report gives data arrival 4.04 ns and slack
−0.41 ns in both. KLayout XOR reported no differences, and the LVS report reads
`Total errors = 0`.

The final GDSII files differ in raw SHA-256 (`c6bd0d71…` published, `109365ea…`
reproduced). After zeroing the timestamp payload of all 170 BGNLIB/BGNSTR
records, both hash to `0432491de021342b80e2ce5dac7bcc22486902be0f1c5915381fdb4eb8a4ac11`.
The layout a stranger gets from the README is byte-identical to the one the
published numbers describe, and the only difference is when it was written.

The other README commands were also run from the same clone. Icarus `tb_router`
gave PASS 117 checks, `tb_mesh` gave PASS 109, and the `DATA_W` 64 /
`FIFO_DEPTH` 8 prefix-file sweep gave PASS 121, the documented count at depth 8.
The flattened Yosys run reported `Found and reported 0 problems.` and
`Found 0 SCCs.` Vivado was not re-run from the clone.

*Tools.* git, Docker Desktop with the pinned OpenLane 1.1.1 image, volare,
Icarus Verilog, Yosys, and a short Python GDSII record walker run inside the
OpenLane container.
