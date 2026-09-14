# Design Rationale — 2×2 Mesh Network-on-Chip

A 2×2 mesh of five-port routers moving single-flit packets between four
endpoints. Flits are 34 bits: 1-bit X coordinate, 1-bit Y coordinate, 32-bit
payload. Each input port has a 4-entry FIFO; each output port has its own
round-robin arbiter; a crossbar connects them. Routing is XY dimension-order,
flow control is on/off backpressure, and the whole design is synchronous to one
clock.

**Result: 173.3 MHz on a Xilinx Kintex-7 FPGA (xc7k70tfbv676-1, speed grade
−1)**, from post-implementation timing after place and route — worst negative
slack +0.429 ns against a 6.200 ns constraint. Hold slack +0.040 ns, positive at
every one of 2514 endpoints. 989 LUTs, 421 flip-flops, 0 block RAMs. This is an
FPGA number; 88% of the critical path is routing delay, and the same RTL on an
ASIC standard-cell process would run several times faster.

Verification is 117 assertions at router level across two coordinate
configurations and 109 at mesh level covering all seven required test cases plus
two head-of-line contention cases and a mid-traffic reset, with a scoreboard
that retired 2376 injected flits against 2364 ejected and 12 deliberately
discarded by that reset, none lost, none duplicated, none misdelivered. The
whole suite re-runs clean at DATA_W 32/40/48/64 and FIFO_DEPTH 2/4/8. Everything runs identically under Icarus
Verilog and Vivado XSim.

---

### 1. Why XY dimension-order routing, and why is it deadlock-free?

A packet resolves its entire X displacement before it makes any Y movement.
Deadlock requires a cycle in the channel dependency graph — a set of channels
each occupied by a packet waiting for the next channel in the set, forever.

In this mesh the only candidate cycles are the two rings around the square. Take
the clockwise one: (0,0) east to (1,0), north to (1,1), west to (0,1), south
back to (0,0). Closing it needs a packet at (1,1) that arrived heading north to
leave heading west, and a packet at (0,0) that arrived heading south to leave
heading east. Both are Y-then-X moves, and under XY a packet that is moving in Y
has already finished its X movement — it has no X displacement left to request.
The counter-clockwise ring breaks identically at the other two corners. Neither
ring can form, the graph is acyclic, and deadlock is impossible by construction:
no timeouts, no detection, no recovery.

Worth being precise about the mechanism: no router inspects which port a flit
arrived on, and no router refuses a turn. Route computation compares the
destination against the router's own coordinates and nothing else. The forbidden
turns are not blocked — applying the same rule at every router makes them
unreachable.

### 2. Which turns are forbidden, and what breaks if a Y→X turn is allowed?

The four Y→X turns: North→East, North→West, South→East, South→West. The four
X→Y turns and all straight-through moves are permitted.

What breaks is *possibility*, not immediate function. This was tested by making
individual routers disagree with their neighbours about dimension order. With
one router flipped to Y-first, one genuine South→West turn appears in the
network — and 381 flits still arrived intact with no hang, because one enabled
turn is not a cycle. With two specific routers flipped, both turns the
counter-clockwise ring needs are enabled and the cycle becomes constructible;
382 flits still arrived, because the test traffic never saturates the ring
rotationally. That is exactly the point: after such a change the network's
correctness stops being a property of the design and becomes a property of the
workload. The restriction is not that cycles are unlikely, but that they cannot
be built.

Both experiments were caught by assertions on the *path* a flit took across the
links, never by the loss or duplication checks, which passed throughout.

### 3. What does XY routing cost, and what would adaptive routing require?

It is deterministic and oblivious: one legal path per source–destination pair,
and no visibility of congestion. A hot link cannot be avoided even when an idle
path exists. Measured directly — with all four endpoints sending to one
destination, delivery split 33/33/66/67, because two sources are funnelled onto
a single shared link while a parallel link carries only one. An adaptive router
could have balanced that. XY cannot.

Adaptive routing would recover it and immediately forfeit the argument above,
since that argument depends on alternative paths not existing. Restoring
deadlock freedom would then require **virtual channels**: several independent
buffer sets per link, with turns that would close a cycle forced to move the
packet to a strictly higher-numbered channel, so the dependency graph is ordered
by channel index instead of by dimension. That multiplies per-link buffering by
the channel count and puts a second arbitration stage in front of every output —
landing squarely on the path that is already critical. Virtual channels are out
of scope here, and XY is what makes that scope honest rather than a gap.

### 4. Why round-robin rather than fixed priority?

Fixed priority is smaller and one logic level shorter, and it starves. With all
five inputs holding a flit for the same output and refilling every cycle, a
fixed-priority arbiter grants the lowest-indexed requester, which is refilled
and requesting again on the next cycle, and wins again permanently.

Substituting a fixed-priority arbiter into this design and running the
sustained-load test gives grants of **199 / 0 / 0 / 0 / 0** across the five
inputs over a 200-cycle window, with a worst-case wait of 199 grants — four
inputs received nothing at all. The round-robin arbiter as built gives
**39 / 40 / 40 / 40 / 40** with a worst-case wait of **4 grants**. Not degraded
service versus good service: no service versus fair service.

### 5. How does the priority pointer update, and why does that bound the wait?

On granting input *i*, the pointer advances to *i*+1 modulo 5, making the winner
lowest priority. Every other requester is then ahead of it in the rotation and
must be served before it can win again, so with N inputs no requester waits more
than N grants. Measured worst case is 4 against the bound of 5.

The subtlety that makes it true: the pointer advances only on a grant that
actually transferred a flit. Requests are masked by the receiver's ready before
the arbiter sees them, so a grant is only ever issued for an output that can
accept. An arbiter that advanced on a stalled or masked request would look
correct in any test where the receiver is always ready, and would silently lose
its place whenever an output was blocked. A white-box assertion checks every
cycle, on all ten router-level arbiters and, from Phase 5, on all twenty in the
mesh, that the pointer changes only when its output both granted and was ready
— verified to fail against exactly that defect.

### 6. Walk through backpressure end to end.

A downstream input FIFO reaches 4 entries and asserts `full`. That router's
`in_ready` for the port deasserts. The upstream router sees its `out_ready` for
that output go low, which masks every arbitration request for that output before
the arbiter sees it. No grant is issued, so no FIFO is popped, so the flit stays
where it is. That upstream FIFO then fills in turn and asserts its own `full`.
Backpressure propagates one hop per cycle, upstream, against the flow of data.

Nothing is ever dropped, because the pop is conditioned on both winning
arbitration and the receiver being ready. `full` is computed purely from the
registered occupancy count and deliberately does not bypass a simultaneous pop —
if it did, a router's upstream ready would depend on its own grant, which depends
on its own ready, and that is a combinational loop. Verified: a flattened
analysis of the whole mesh reports zero logic loops, while a deliberately
bypassed version reports one.

### 7. Why on/off flow control rather than credit-based?

On/off carries one ready wire per link and no state. Credit-based instead gives
the sender a count of free downstream slots, decremented on send and replenished
by returned credits, so the sender never needs to see the receiver's live state.
That wins when round-trip signalling latency is significant, because on/off must
get `full` back to the sender before it stops, and everything in flight during
that round trip needs buffering that exists only to cover the delay.

Here links are single-cycle and combinational, so that round trip is
effectively zero and credits would hide nothing. The measured cost of on/off is
exactly the buffering already on the path and no more: blocking a destination one
hop away absorbs **8 flits** before the source stalls, and two hops away absorbs
**12** — precisely hops × FIFO depth, with no slack anywhere. Credit-based would
have added a counter and a return path per link direction, sixteen of each
across this mesh, to buy back a delay that does not exist.

Credit-based starts to win if the links become registered — which is the leading
proposal for improving Fmax — or if the mesh grows large enough that a link
crosses a physical region, or if buffers get deep enough that per-link occupancy
is worth tracking for its own sake.

### 8. What is the FIFO depth and why that number?

Four entries. A flit crosses a router in one cycle, so a downstream `full` is
visible upstream on the next cycle and two slots would already prevent loss.
Four was chosen over two so that a briefly blocked output does not immediately
backpressure its neighbour, which would turn every transient stall into a
network-wide event.

The cost is small and measured: 286 LUTs of distributed RAM for all twenty
FIFOs, and no block RAM at all. Depth 4 and the storage choice are really one
decision. A block RAM has a synchronous read port, but the design reads the head
flit asynchronously so that route computation and arbitration can both consume it
in the cycle it becomes valid; a registered read would add a cycle to every hop.
A 136-bit FIFO would also use 0.7% of an 18 Kb block RAM. So 0 block RAMs is a
requirement met, not an optimization missed.

### 9. What is the critical path, and how would it be broken?

It runs from the read pointer of one router's Local input FIFO, through that
FIFO's distributed-RAM read, the route computation, all five logic levels of that
router's West-output round-robin arbiter, the crossbar, across the link, and into
the write data pin of the neighbouring router's East input FIFO. Seven logic
levels. It crosses an entire router *and* a link in a single cycle.

Data path delay is 5.543 ns, of which **logic is 0.640 ns (11.5%) and routing is
4.903 ns (88.5%)**. The single largest contributor is one net inside the
arbiter with a fanout of 45, costing 0.988 ns of pure routing. (The timing
budget of 5.771 ns used for Fmax is larger than the 5.543 ns propagation because
it also carries setup time, clock uncertainty and skew — 0.228 ns together.)

Three fixes, in the order worth doing:

1. **Register the link.** Pipelining the crossbar output ends the path at a flop
   in the source router instead of the neighbour's RAM write port. It is the one
   structural cut that halves the path, and it also frees the placer to separate
   the two routers — which matters most precisely because routing dominates.
   Costs one cycle of latency per hop.
2. **Register the routing decision.** Compute the output request when a flit is
   *written* into the FIFO and store it alongside, so arbitration begins from a
   register rather than a combinational chain out of LUTRAM. Removes the memory
   read and the route logic from the path, at the cost of FIFO width, not
   latency.
3. **Reduce the arbiter's high-fanout net.** Named explicitly because with logic
   at 11.5% of the path, shortening the LUT chain buys much less than it appears
   to; the real wins here are fanout and placement locality.

### 10. What does the testbench check, and what would it miss?

One scoreboard mechanism covers four properties at once: every injected flit is
recorded against its destination, and every ejection must find and retire an
exact match at the endpoint where it appeared — so correct destination, payload
integrity, no duplication and no loss all fall out of the same check, with the
scoreboard asserted empty at end of test. Routing order is asserted on the path a
flit actually took across the links, not on its arrival. Bounded service is
measured over a window that deliberately excludes the post-load drain, because
including it hides starvation. Every assertion has been shown to fail against at
least one deliberate RTL mutation; a testbench that has never failed is not
evidence.

What it would miss, most important first:

- **It cannot demonstrate deadlock.** With the dependency cycle made
  constructible, the suite still reported 382 flits injected and 382 ejected with
  no hang; the mixed routing order was caught only by the path assertions.
  Deadlock needs all four ring channels held simultaneously with full buffers,
  and no test drives rotational traffic. Deadlock freedom rests on the structural
  argument, not on simulation — a claim of a different kind from everything else
  here.
- **The compounding-contention margin does not exist.** Previously recorded here
  as untested, on the reasoning that the bound is 25 and the measured worst case
  5, so the range 6 to 25 had never been visited. That was wrong, and the error
  was in the bound rather than the traffic. A 2×2 gives every router two
  neighbours and therefore three live inputs, not five; no-U-turn caps a cardinal
  output at two requesters and XY caps an outbound one at a single requester; and
  the three-way ceiling occurs only at a LOCAL output, where a grant is terminal
  and cannot be composed with a second contention. Case 5 therefore runs a 2-way
  stage into a 3-way stage, whose true bound is 5 — exactly the measured value.
  The metric is saturated, not unexercised, and 25 is a valid but loose upper
  bound left in place deliberately (D27). What genuinely was untested is
  head-of-line blocking, which the original suite could not exhibit at all:
  every case sent each source to one destination, so no input FIFO ever held a
  stalled head in front of a flit bound elsewhere. Cases 8a and 8b now do
  (D28), and the per-arbiter monitor covering all twenty mesh arbiters measures
  a worst wait of 2 grants against the arbiters' bound of 5 — independently
  confirming the three-requester ceiling D27 derived.
- No latency assertions — a change adding a pipeline stage everywhere would pass
  every test.
- One payload width, one FIFO depth, one mesh size. Only coordinate width is
  exercised across configurations.
- No reset-during-traffic test.

### 11. How would this scale to 4×4?

Every width derives from parameters, and the router has already been synthesized
and simulated at 2-bit coordinates — the width a 4×4 mesh needs, and the only
configuration in which all five output arbiters are simultaneously live. Only the
top-level wiring file changes: sixteen routers, forty-eight link directions, the
same tie-off pattern on sixteen edge ports. Nothing inside the router changes.

What does not scale linearly:

- **Utilization.** The 989-LUT figure already reflects constant folding at the
  corners: with 1-bit coordinates two routing conditions are unsatisfiable at
  each corner router, so two of its five arbiters vanish entirely — and in a 2×2
  mesh every router is a corner. A 4×4 mesh has four interior routers with all
  five arbiters live and nothing foldable, so expect appreciably more than four
  times the area for four times the routers.
- **Latency and the service bound.** Worst-case hops go from 2 to 6, and the
  per-source bound compounds per arbitration stage. The compounding is
  discontinuous, not smooth. Five per hop assumes five live inputs, which no
  router in a 2×2 has — every one is a corner with three, so this mesh bounds at
  5 rather than 5² (D27). A 4×4 has four genuine interior routers with five live
  inputs each, so five-way arbitration and 5ⁿ per-stage compounding become
  reachable there for the first time — up to 5⁶ on the longest path. That stops
  being a useful guarantee well before it stops being true: round-robin bounds
  each hop, not the path.
- **Timing.** Routing is already 88% of the critical path at 2.4% device
  occupancy. A larger mesh spreads further across the die and the dominant term
  grows with distance. Registering the links stops being optional.
- **FIFO depth.** Depth 4 assumes a single-cycle link. Once links are registered
  the backpressure round trip lengthens and depth must grow — and deep enough
  buffers eventually make block RAM plausible, at which point the synchronous-read
  problem has to be solved rather than sidestepped.

Deadlock freedom does not change. The argument is about the dependency graph
being acyclic under XY, and it holds for a 2D mesh of any size: the rings get
longer, and every one of them still needs at least one Y→X turn to close.

### 12. What is the throughput limit, and where is the bottleneck?

The ceiling is one flit per cycle per link direction and one per cycle per output
port — each output has a single arbiter issuing at most one grant per cycle. A
router can move five flits in one cycle when all five outputs are independently
active, which is confirmed rather than assumed: a test injects on all five inputs
with five different destinations and asserts all five are granted in the same
cycle. At 173.3 MHz with 34-bit flits that is about 5.9 Gbit/s per link
direction.

The bottleneck is **not the arbiter**. Under converging load the split was
33/33/66/67, and every arbiter in that run was behaving perfectly fairly — the
destination's arbiter divided its grants evenly among the three inputs that were
requesting. The asymmetry is one level upstream: two sources' traffic merges onto
a single shared input port before reaching that arbiter, so they divide one third
between them while a third source has another third to itself. **The shared
downstream input port is the limit**, and this matters because the symptom looks
like arbiter unfairness while the fix for arbiter unfairness would achieve
nothing. Round-robin is fair over the requesters it can see; it cannot see that
one of its inputs carries two sources.

The second-order limit is head-of-line blocking, from the same structure: one
FIFO per input means a flit blocked on a busy output stalls flits behind it that
are bound for idle outputs. Virtual channels are the standard remedy and are out
of scope. At depth 4 the exposure is bounded to three flits behind any blocked
head.
