# Design Rationale — 2×2 Mesh Network-on-Chip

Four five-port routers, single-flit 34-bit packets (1-bit X, 1-bit Y, 32-bit
payload). Per input port a 4-entry FIFO; per output port its own round-robin
arbiter; XY dimension-order routing; on/off backpressure; one clock.
**173.3 MHz post-implementation on a Kintex-7 FPGA (xc7k70tfbv676-1, −1); WNS
+0.429 ns at 6.200 ns; hold +0.040 ns; 989 LUT / 421 FF / 0 BRAM.** 226
assertions, all seven required cases plus head-of-line contention, reset under
load and latency bounds; 2376 flits injected, 2364 retired and 12 discarded by
a deliberate mid-traffic reset. Re-run clean at four payload widths and three
FIFO depths.
Evidence and workings: `RATIONALE_FULL.md`.

**1 — Why XY, and why deadlock-free.** X displacement resolves fully before any
Y movement. Deadlock needs a cycle of channels each held by a packet waiting on
the next, and the only candidates are the two rings around the square. Closing
the clockwise ring needs a packet arriving northbound at (1,1) to leave
westbound — but a packet moving in Y has no X displacement left to request. Both
rings break the same way, so the dependency graph is acyclic by construction. No
router inspects its input port: one rule applied everywhere makes the bad turns
unreachable rather than blocked.

**2 — Forbidden turns.** The four Y→X turns: North→East, North→West,
South→East, South→West. Allowing one costs *possibility*, not function —
flipping two routers to Y-first makes the ring constructible and 382 flits still
arrive intact, because the traffic never saturates the ring. Correctness simply
stops being a property of the design and becomes one of the workload.

**3 — What XY costs.** Deterministic and oblivious: one legal path per pair, no
view of congestion. With four endpoints targeting one destination, delivery
split 33/33/66/67 — two sources share a link while a parallel link carries one.
Adaptive routing would fix that and forfeit answer 1, which depends on
alternative paths not existing; recovering deadlock freedom would then need
virtual channels, multiplying buffering and adding a second arbitration stage to
the already-critical path.

**4 — Round-robin over fixed priority.** Fixed priority is smaller and one logic
level shorter, and it starves: the lowest-indexed input refills and wins again
every cycle. Measured over 200 cycles, fixed priority grants **199/0/0/0/0**
while round-robin grants **39/40/40/40/40**. No service versus fair service.

**5 — Pointer update and the bound.** Granting input *i* moves the pointer to
*i*+1 mod 5, making the winner lowest priority, so every other requester is
served before it wins again — at most N grants, measured worst case 4 against a
bound of 5. The pointer advances only on a grant that actually transferred,
since requests are masked by the receiver's ready first. A white-box assertion
checks this every cycle on all ten router-level arbiters and, from Phase 5, on
all twenty in the mesh, because an arbiter advancing on a stalled request looks
correct whenever the receiver is always ready.

**6 — Backpressure end to end.** FIFO hits 4 entries → `full` → that port's
`in_ready` drops → upstream `out_ready` drops → requests for that output are
masked before arbitration → no grant, no pop, flit stays → that FIFO fills and
asserts its own `full`. One hop per cycle, against the data. A pop needs both a
grant and a ready receiver, so nothing is dropped. `full` comes only from the
registered count and never bypasses a simultaneous pop, which would make
upstream ready depend on its own grant. A flattened check of the mesh reports
zero logic loops; a deliberately bypassed version reports one.

**7 — On/off over credit-based.** One ready wire per link, no state. Credit
schemes win when round-trip signalling latency is significant; here links are
single-cycle, so it is effectively zero. Measured cost is exactly the buffering
already present — 8 flits absorbed one hop from a blocked destination, 12 at two
hops, precisely hops × depth. Credit-based wins once links are registered, which
is the leading Fmax fix.

**8 — FIFO depth 4.** Two slots would already prevent loss, since `full` reaches
upstream the cycle after it asserts; four keeps a briefly blocked output from
immediately backpressuring its neighbour. Costs 286 LUTs of distributed RAM and
no block RAM — required rather than merely cheap, because a block RAM's
synchronous read would delay the head flit a cycle, and route compute and
arbitration both consume it combinationally in the cycle it becomes valid.

**9 — Critical path and how to break it.** Local FIFO read pointer → that FIFO's
distributed-RAM read → route compute → five logic levels of the West-output
arbiter → crossbar → link → the neighbour's East FIFO write port: a whole router
and a link in one cycle, seven logic levels, 5.543 ns of which **logic is
0.640 ns (11.5%) and routing 4.903 ns (88.5%)**, the largest single item a
fanout-45 arbiter net at 0.988 ns. In order: register the link (halves the path,
frees the placer, costs a cycle per hop); register the routing decision at FIFO
write so arbitration starts from a flop (costs width, not latency); reduce that
high-fanout net. A Sky130 ASIC run changes the emphasis but not the answer: the
same architectural path is critical there (FIFO read → route/arbitrate →
crossbar → downstream FIFO write), but it is gate-delay-limited rather than
wire-limited — 13 standard cells deep, with the largest contributors being cell
arcs rather than a net. So fix 3 is FPGA-specific, while fixes 1 and 2, which
cut logic depth, are what would help on both. That depth is itself evidence for
fixes 1 and 2: the loose 20 ns pass produced a 17-cell path, and the Stage B
tightening cut it to 13 by remapping to fewer, higher-drive stages, which is
where its +21.9% came from.

**10 — What the testbench checks, and misses.** One scoreboard gives four
properties at once: every injected flit is recorded against its destination, and
every ejection must retire an exact match at the endpoint it appeared on — so
correct destination, payload integrity, no duplication and no loss all fall out
together. Routing order is asserted on the path taken, not on arrival, and every
assertion has been shown to fail against a deliberate RTL mutation. It **cannot
demonstrate deadlock**: with the cycle made constructible, 382 flits still
arrived and only the path assertions noticed, so answer 1 rests on the
structural argument rather than simulation. Worst measured wait is 5, which is
also the *true* structural bound: three live inputs per router means Case 5
composes a 2-way then a 3-way contention, not 5 × 5. The asserted 25 is a
valid but loose upper bound, so that metric is saturated, not unexercised (D27).
The gaps that were real — no latency assertions, a single payload width and FIFO
depth, no reset under traffic — are now closed (D29). What remains is the
deadlock limit above, accepted as a finding rather than fixed, because the
property is quantified over all traffic while simulation only samples it (D34).

**11 — Scaling to 4×4.** Only the top-level wiring changes; the router is
untouched and already runs at the 2-bit coordinates a 4×4 needs. Area will not
be 4×, because 989 LUTs already reflects corner constant-folding and every
router in a 2×2 is a corner, whereas a 4×4 has four interior routers with
nothing foldable. Hops go 2 → 6, and the service bound jumps
rather than scaling smoothly: those same corners have only three live inputs, so
the 2×2 bound is 5, not 5². Five-way arbitration first becomes reachable on the
4×4 interior routers, which is where 5ⁿ per-stage compounding starts applying —
up to 5⁶ on the longest path. It is a 4×4 property the 2×2 never exhibits (D27),
and it stops being useful long before it stops being true.
Timing worsens because routing already dominates, and depth 4 assumes a
single-cycle link. Deadlock freedom is unaffected: longer rings still each need
a Y→X turn to close.

**12 — Throughput limit and bottleneck.** One flit per cycle per link direction
and per output port; a router moves five at once when all five outputs are
active, which a test confirms. About 5.9 Gbit/s per link direction. The
bottleneck is **not the arbiter** — in the 33/33/66/67 split every arbiter
divided grants evenly among the inputs requesting. The asymmetry is one level
upstream, where two sources merge onto one shared input port before reaching
that arbiter. Fixing the arbiter would achieve nothing: round-robin is fair over
the requesters it can see, and cannot see that one input carries two sources.
Second-order is head-of-line blocking, bounded to three flits behind a blocked
head at depth 4.
