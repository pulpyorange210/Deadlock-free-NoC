# Deadlock-Free On-Chip Interconnect — 2×2 NoC Mesh

A from-scratch RTL implementation of a Network-on-Chip: a 2×2 mesh of five-port
routers that moves single-flit packets between four network endpoints without
ever deadlocking, starving an input, or dropping a flit.

This document is the complete specification. Build from this alone — no
reference implementation is assumed or available.

---

## 1. What we are building and why

An SoC has many blocks that need to talk to each other. Point-to-point wiring
does not scale, and a shared bus becomes a bottleneck. A **Network-on-Chip
(NoC)** solves this by treating on-chip communication as a packet-switched
network: data is wrapped into packets and routed hop by hop through a mesh of
routers.

Three problems have to be solved simultaneously, and they are the intellectual
content of this project:

| Problem | Consequence if unsolved | Our mechanism |
|---|---|---|
| **Deadlock** | Packets hold buffers while waiting for buffers others hold; the network locks up permanently | XY dimension-order routing |
| **Starvation** | One input port never wins arbitration under sustained traffic | Per-output round-robin arbitration |
| **Buffer overflow** | A flit is forwarded to a full downstream buffer and is silently lost | On/off backpressure |

The deliverable is synthesizable Verilog/SystemVerilog, a self-checking
testbench, and synthesis + implementation results including a defensible Fmax
number.

### Vocabulary used throughout

- **Flit** — *flow control unit*. The smallest unit of data that moves across a
  link in one cycle and that flow control operates on. In this design every
  packet is exactly one flit, which removes packet reassembly from scope.
- **Port** — a bidirectional connection point on a router. Each router has five:
  North, South, East, West, and Local (the attached endpoint).
- **Crossbar** — the switch fabric inside a router that connects any input port
  to any output port.
- **Backpressure** — a signal travelling *upstream*, opposite to data, telling
  the sender to stop.
- **Channel dependency graph (CDG)** — a directed graph where nodes are channels
  (links) and an edge A→B means a packet holding A may wait for B. **A cycle in
  this graph is a potential deadlock.** Everything about our routing choice
  exists to keep this graph acyclic.

---

## 2. Requirements

### Required (core build)

| Tool | Purpose | Notes |
|---|---|---|
| **Icarus Verilog** (`iverilog`) or **Verilator** | RTL simulation | Icarus is simpler for a mixed behavioural testbench; Verilator is faster but stricter and needs a C++ harness. Icarus is the default assumption here. |
| **GTKWave** | Waveform viewing | Essential for debugging the crossbar and arbiter |
| **Yosys** | Logic synthesis / design sanity check | Catches inferred latches, combinational loops, width mismatches |
| **Git** | Version control | |
| A text editor / IDE | | |

Install on Debian/Ubuntu:
```bash
sudo apt install iverilog gtkwave yosys git
```

### Required for the Fmax number

| Tool | Purpose |
|---|---|
| **AMD/Xilinx Vivado** (free WebPACK edition is sufficient) | Synthesis **and implementation** (place & route), then post-implementation timing analysis. This is the only tool in the required set that produces a defensible maximum frequency, because it accounts for real routing delay. |

A target part must be chosen. Any modern 7-series or newer device works; this
spec assumes a Kintex-7 (`xc7k70tfbv676-1`) unless changed.

### Optional — ASIC flow, only if time permits

| Tool | Purpose |
|---|---|
| **OpenLane** (wraps Yosys + OpenROAD) | Full open-source RTL-to-GDSII flow on the SkyWater **Sky130** open PDK |
| **OpenROAD** | Placement, clock tree synthesis, routing, and static timing analysis |
| **Docker** | OpenLane is distributed as a container; strongly recommended over a native install |
| **KLayout** or **Magic** | Viewing the resulting GDSII layout |

This path yields an ASIC-context timing and area result rather than an FPGA one,
which is more representative of real silicon. It is also a multi-hour setup with
real debugging overhead on first use. **Treat it as a stretch goal.** Do not
begin it until the core build, testbench, and Vivado results are complete.

### Assumed knowledge

Verilog RTL coding, FSM design, synchronous FIFOs, and basic static timing
concepts (setup, hold, slack). No prior NoC knowledge is required — this
document covers it.

---

## 3. Architecture

### 3.1 Topology

A 2×2 mesh. Routers are addressed by (X, Y) coordinates:

```
            (0,1) ──────── (1,1)
              │              │
              │              │
            (0,0) ──────── (1,0)
```

Each router has an attached **endpoint** on its Local port — the traffic source
and sink. Edge ports (those pointing off the mesh) are tied off: their inputs
are held invalid and their outputs are left unconnected. In a 2×2 mesh every
router uses exactly two of its four cardinal ports plus Local.

Coordinates are 1 bit each for a 2×2 mesh, but **all widths must be
parameterized** so the design scales to 4×4 without edits.

### 3.2 Flit format

```
+----------+----------+---------------------------+
|  dest_x  |  dest_y  |          payload          |
+----------+----------+---------------------------+
   X_W bits   Y_W bits         DATA_W bits
```

Carried alongside as separate wires, not inside the flit:
- `valid` — asserted by the sender when the flit on the bus is real
- `ready` — asserted by the receiver when it can accept a flit this cycle

A flit transfers on any cycle where `valid && ready` are both high. This is the
standard ready/valid handshake; it must hold on every link, including the
endpoint interfaces.

Recommended parameters:
```verilog
parameter X_W        = 1;   // X coordinate width
parameter Y_W        = 1;   // Y coordinate width
parameter DATA_W     = 32;  // payload width
parameter FIFO_DEPTH = 4;   // per-input-port buffer depth
localparam FLIT_W    = X_W + Y_W + DATA_W;
```

Include a source ID or sequence number inside the payload during testing so the
testbench can identify exactly which flit arrived where.

### 3.3 Router microarchitecture

Every router is identical. Five input ports, five output ports, and this
pipeline per input:

```
   input link ──▶ [ input FIFO ] ──▶ [ route compute ] ──▶ [ arbiter request ]
                                                                    │
                                                                    ▼
                                                          [ crossbar ] ──▶ output link
```

**Input FIFO.** One synchronous FIFO per input port, `FIFO_DEPTH` entries deep,
`FLIT_W` wide. Asserts `full` upstream and exposes `empty` plus the head flit
downstream. This is the buffer that backpressure protects.

**Route computation.** Combinational. Looks at the head flit's `dest_x`/`dest_y`
and this router's own `(MY_X, MY_Y)` parameters, and produces a one-hot
`req[4:0]` naming the output port the flit wants. The XY algorithm is in §3.4.

**Arbitration.** One round-robin arbiter per *output* port, each seeing requests
from all five inputs. Detail in §3.5.

**Crossbar.** For each output port, a mux selecting the head flit of whichever
input won that output's arbitration. Because arbitration is per-output and
one-hot, two outputs may be driven from different inputs in the same cycle —
the crossbar is genuinely non-blocking across outputs.

**Dequeue.** An input port's FIFO is popped only on a cycle where it both won
arbitration and the downstream receiver was ready. This coupling is what makes
the design lossless.

### 3.4 XY dimension-order routing

The routing rule, evaluated on the head flit at each hop:

```
if      (dest_x > MY_X)  →  route EAST
else if (dest_x < MY_X)  →  route WEST
else if (dest_y > MY_Y)  →  route NORTH
else if (dest_y < MY_Y)  →  route SOUTH
else                     →  route LOCAL   (this router is the destination)
```

**Why this is deadlock-free — the core claim of the project.**

A packet always resolves its X displacement completely before it makes any Y
movement. Consequently a packet that is travelling in the Y dimension can never
turn back into the X dimension. Of the eight possible turns in a 2D mesh, this
forbids two: **North→East, North→West, South→East, South→West** are all
prohibited (any Y-to-X turn), while X-to-Y turns are permitted.

Removing those turns makes the channel dependency graph **acyclic by
construction**. A deadlock cycle in a mesh requires packets waiting in a loop —
for example, four packets each holding a channel on one side of a square and
each waiting for the next side clockwise. Completing such a loop requires at
least one Y→X turn. With those turns forbidden, no cycle can form, so no
deadlock is possible. Note this is a *structural* guarantee, not a probabilistic
one: it needs no timeouts, no deadlock detection, and no recovery mechanism.

The cost is that XY routing is **deterministic and oblivious** — it cannot route
around congestion, because it has exactly one legal path per source/destination
pair. Adaptive routing would allow congestion avoidance but reintroduces cycles
in the CDG and then needs virtual channels to break them. That tradeoff is the
central design decision here and must be understood, not just implemented.

### 3.5 Round-robin arbitration

Each output port has an arbiter that receives up to five requests per cycle and
issues at most one one-hot grant.

**Why not fixed priority.** With a static priority order, an input low in the
order can be starved indefinitely: if a higher-priority input has traffic every
cycle, the lower one never wins. In a NoC under sustained load from all
neighbours this is a real failure, not a theoretical one.

**Mechanism.** The arbiter holds a `priority_ptr` naming which input is
currently highest priority. It grants the requesting input that is nearest to
the pointer in circular order. On issuing a grant to input *i*, the pointer
advances to *i+1* (mod 5) — so the input that just won becomes *lowest*
priority. Every requester is therefore guaranteed service within five grants,
which bounds worst-case wait and eliminates starvation.

Implementation approach: rotate the request vector by the pointer, run a simple
fixed-priority (leading-one) select on the rotated vector, then rotate the grant
back. This keeps the logic small and avoids a large case statement.

The pointer updates **only when a grant is actually issued**, and a grant is
only real when the downstream can accept it (see §3.6). Do not advance the
pointer on a masked or stalled request.

### 3.6 On/off backpressure (flow control)

The rule: **a flit is granted the crossbar only on a cycle when the receiver can
actually accept it.**

Mechanism: whenever a downstream input FIFO asserts `full`, the corresponding
upstream output port's `ready` deasserts. That deasserted ready **masks the
arbitration request** for that output — the arbiter simply never sees requests
for an output that cannot accept a flit. The flit stays in its input FIFO, and
that FIFO in turn eventually fills and backpressures its own upstream neighbour.
Backpressure propagates hop by hop, upstream, against the direction of data.

This is **on/off** (or *stop-and-go*) flow control. The alternative,
**credit-based** flow control, has the sender track a count of free downstream
buffer slots and decrement on send. Credit-based is more efficient on long links
where the round-trip signalling latency is significant, but it needs credit
return paths and counters at both ends. On/off is chosen here because links are
single-cycle and the added complexity buys nothing at this scale.

**Critical timing caution.** The backpressure path — downstream `full` → upstream
request masking → grant → crossbar — is combinational and is a likely
combinational-loop hazard if a router's own ready depends on its own grant
depends on its own ready. Break any such loop with a register. Yosys will flag
genuine loops; treat any such warning as a design error, never as tool noise.

---

## 4. Module hierarchy

```
mesh_top
├── router  (MY_X=0, MY_Y=0)
├── router  (MY_X=1, MY_Y=0)
├── router  (MY_X=0, MY_Y=1)
├── router  (MY_X=1, MY_Y=1)
└── (inter-router link wiring + tied-off edge ports)

router
├── fifo            × 5   (one per input port)
├── route_compute   × 5   (combinational)
├── rr_arbiter      × 5   (one per output port)
└── crossbar        × 1
```

Suggested files:

| File | Contents |
|---|---|
| `fifo.v` | Parameterized synchronous FIFO, `full`/`empty`, head-flit output |
| `route_compute.v` | XY routing, flit + own coords → one-hot request |
| `rr_arbiter.v` | Round-robin arbiter, N requests → one-hot grant |
| `crossbar.v` | Per-output mux driven by grants |
| `router.v` | Assembles the above into one 5-port router |
| `mesh_top.v` | Instantiates 4 routers, wires links, ties off edges |
| `tb_router.v` | Single-router testbench |
| `tb_mesh.v` | Full-mesh self-checking testbench |

---

## 5. Build phases

### Phase 1 — one router, one flit

Build `fifo`, `route_compute`, `rr_arbiter`, `crossbar`, and `router`. Get a
single flit to travel from one input port, through the crossbar, out the correct
output port, in simulation.

Success criterion: inject one flit at the Local input destined for a neighbour;
observe it leave on the correct cardinal output with payload intact.

Run **Yosys** at the end of this phase (see §7) before building anything on top.

### Phase 2 — the 2×2 mesh

Build `mesh_top`. Wire the four routers, propagate ready/valid and backpressure
across the inter-router links, and tie off edge ports.

Success criterion: a flit injected at router (0,0) destined for (1,1) traverses
two hops and ejects at (1,1)'s Local output. Verify by inspection that it went
X-first then Y — this is the routing algorithm proving itself.

Re-run Yosys; the inter-router wiring is where width mismatches and unconnected
ports appear.

### Phase 3 — self-checking testbench and results

Build `tb_mesh` per §6, then run the Vivado flow per §7.

**Fallback rule, decided in advance:** if the mesh is not working by the end of
Phase 2, freeze the deliverable at a single fully-working 5-port router. A
router with XY routing, round-robin arbitration, backpressure, and a passing
self-checking testbench is a complete and legitimate project. It is strictly
better than a mesh that half-works.

### Phase 4 — ASIC flow (only if time permits)

OpenLane / OpenROAD on Sky130. See §7.3. Do not start this before Phase 3 is
finished.

---

## 6. Verification

The testbench must be **self-checking** — pass/fail decided by assertions in the
bench, never by a human reading waveforms. Waveforms are for debugging, not for
deciding correctness.

### Required test cases

| Case | What it proves |
|---|---|
| **Single-hop** | Basic routing and crossbar function; one flit, adjacent router |
| **Two-hop** | XY ordering is correct; flit from (0,0) to (1,1) must go X then Y |
| **Simultaneous injection** | Arbitration works; all four endpoints inject in the same cycle |
| **Output contention** | Two inputs request the same output on the same cycle; exactly one wins, the other is retried and eventually served |
| **Sustained load / starvation** | Every input requests the same output every cycle for many cycles; assert that every input is served within a bounded window. This is the test that proves round-robin, and fixed-priority logic will fail it |
| **Backpressure / FIFO full** | Hold an endpoint's ready low until its FIFO fills; assert no flit is lost and that backpressure propagates upstream |
| **All-to-all** | Every source sends to every destination; assert every flit arrives exactly once at the right place |

### Assertions to implement

- **Payload integrity** — the payload ejected equals the payload injected
- **Correct destination** — a flit ejects only at the router whose coordinates match its `dest_x`/`dest_y`
- **No loss** — flits ejected == flits injected, at end of test
- **No duplication** — each unique sequence number ejects exactly once
- **Bounded service** — under sustained contention, no input waits more than N grants

A scoreboard approach works well: push every injected flit into a queue keyed by
destination, pop and compare on ejection, and assert the queues are empty at end
of test.

---

## 7. Synthesis and implementation

### 7.1 Yosys — design sanity check (required, fast)

Yosys performs **logic synthesis** only. It maps RTL to gates and reports cell
counts. It does **not** place or route, so it cannot produce a defensible Fmax.
Its value here is catching structural bugs early.

```bash
yosys -p "read_verilog *.v; hierarchy -top mesh_top; proc; opt; fsm; opt; \
          memory; opt; techmap; opt; stat"
```

Read the log, not just the summary. Specifically check:

- **`$dlatch` count must be zero.** Any inferred latch in a design intended to be
  fully synchronous is a bug — almost always an incomplete `if` or `case`.
- **`$dff` count** should roughly match hand-counted flops (FIFO storage,
  arbiter pointers, any pipeline registers). A large mismatch means something is
  not inferring as intended.
- **Combinational loop** warnings — a real design error here, most likely in the
  backpressure path (§3.6).
- **Width mismatch** warnings — silent truncation, common where flit width and
  coordinate width interact.
- **Multiple drivers**, **driven but unused**, **assigned but never used** —
  usually a forgotten connection that simulation did not exercise.

Run at the end of Phase 1 and again at the end of Phase 2.

### 7.2 Vivado — the Fmax number (required)

Fmax requires **synthesis and implementation**, because post-synthesis timing
ignores routing delay and is optimistic.

1. **Constrain the clock.** Without a constraint no meaningful timing is
   reported. In an XDC file:
   ```tcl
   create_clock -period 10.000 -name clk [get_ports clk]
   ```
2. **Run synthesis, then implementation** (place & route).
3. **Open the post-implementation timing summary** and read **WNS** (worst
   negative slack) on the setup path.
4. **Compute:**
   ```
   Fmax = 1 / (T_clk − WNS)
   ```
   Example: with a 10 ns period and WNS of +2 ns, the critical path is 8 ns, so
   Fmax ≈ 125 MHz. Negative WNS means the constraint was missed and the true
   Fmax is below what was requested.
5. **Iterate once or twice.** Tighten the period toward the computed Fmax and
   re-run; the tool optimizes against the constraint, so a tight constraint often
   yields a better result than a loose one. Two or three passes is enough — do
   not spend the schedule tuning.

Also record from the same run:
- **The critical path** — start point, end point, and which module it runs
  through. On a NoC this is typically the arbiter's priority-pointer logic or
  the crossbar select path.
- **Utilization** — LUTs, FFs, BRAM (the FIFOs may or may not infer block RAM
  at this depth).
- **Hold slack** — must be positive. If it is not, report it honestly rather
  than omitting it.

**State the number as an FPGA result.** FPGA LUT and routing delays are far worse
than ASIC standard cells; the same RTL would run several times faster on
silicon. Saying "on FPGA" is accurate and expected. Implying otherwise is not.

### 7.3 OpenLane / OpenROAD — ASIC flow (only if time permits)

An open-source RTL-to-GDSII flow on the SkyWater Sky130 PDK, giving an
ASIC-context result: cell area in µm², a real static timing analysis with a
standard cell library, and a GDSII layout.

Outline:
1. Install OpenLane via Docker (strongly preferred over a native build).
2. Create a design directory with the RTL and a `config.json` naming the top
   module, clock port, and target clock period.
3. Run the flow; it executes synthesis (Yosys), floorplanning, placement, clock
   tree synthesis, routing (OpenROAD), and signoff STA.
4. Record post-route **WNS**, cell area, and cell count. View the GDSII in
   KLayout.

Expect real setup and debugging time on first use — floorplan utilization and
clock period often need several attempts to converge. **This is a stretch goal.
Skip it entirely if the core deliverables are not finished.**

---

## 8. Design decisions to be able to defend

Keep a running one-page rationale note *while building*, not afterwards.
Reconstructed reasoning reads differently from remembered reasoning.

Every one of these should have an answer:

1. Why XY dimension-order routing, and why is it deadlock-free? Draw the cyclic
   channel dependency that XY prevents.
2. Which turns are forbidden, and what would break if a Y→X turn were allowed?
3. What does XY routing cost? (Deterministic, cannot avoid congestion.) What
   would adaptive routing require to stay deadlock-free? (Virtual channels.)
4. Why round-robin over fixed priority? Describe the exact starvation scenario.
5. How does the priority pointer update on a grant, and why does that bound
   worst-case wait?
6. Walk through backpressure end to end: what asserts `full`, what masks the
   request, what stalls, and how does it propagate upstream?
7. Why on/off flow control rather than credit-based? When would credit-based win?
8. What is the FIFO depth and why that number?
9. What is the critical path, and how would it be broken? (Have a concrete
   answer — e.g. pipelining route computation a stage earlier.)
10. What does the testbench check, and what would it miss?
11. How would this scale to 4×4? What changes, and what breaks?
12. What is the throughput limit, and where is the bottleneck?

---

## 9. Deliverables

- [ ] Synthesizable RTL: `fifo`, `route_compute`, `rr_arbiter`, `crossbar`,
      `router`, `mesh_top` — all parameterized
- [ ] Self-checking testbench covering every case in §6, with assertions
- [ ] Clean Yosys run: zero inferred latches, no combinational loops, cell counts
      matching expectation
- [ ] Vivado post-implementation results: Fmax, critical path with named
      endpoints, LUT/FF utilization, positive hold slack
- [ ] One-page design rationale note answering §8
- [ ] *(Stretch)* OpenLane/OpenROAD Sky130 results: post-route WNS, cell area,
      GDSII

---

## 10. Scope boundaries

Explicitly **out of scope**, to keep the build finishable:

- Multi-flit packets (head/body/tail flits, packet reassembly)
- Virtual channels
- Adaptive or minimal-adaptive routing
- Multiple clock domains / CDC between routers — the mesh is fully synchronous
- Error detection or correction on links
- Quality-of-service classes or traffic prioritization
- Meshes larger than 2×2 (though all widths must be parameterized so scaling is
  an instantiation change, not a rewrite)
