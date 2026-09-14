`timescale 1ns/1ps
`default_nettype none
//----------------------------------------------------------------------------
// tb/tb_mesh.v -- full-mesh self-checking testbench (NOC_MESH_PROJECT.md §6).
//
// Pass/fail is decided entirely by assertions. Waveforms are for debugging only.
//
// Scoreboard. Every injected flit is pushed into a per-destination queue keyed
// by (destination, exact flit). On ejection the monitor searches that
// destination's outstanding entries for an exact match and retires it. One
// mechanism therefore covers four of the required assertions at once:
//   - correct destination : the search is scoped to the ejecting endpoint
//   - payload integrity   : the match is on the whole flit, magic byte included
//   - no duplication      : a second copy finds no outstanding entry and fails
//   - no loss             : any entry still outstanding at end of test fails
// Bounded service is measured separately in case 5.
//
// A flit's payload carries {src_id[7:0], seq[15:0], MAGIC[7:0]}, so a
// misdelivered or duplicated flit is identifiable, not just detectable.
//
// Two continuous white-box monitors run for the whole simulation:
//   - edge tie-offs: no off-mesh output is ever driven OR requested. The
//     request half is the one that catches a routing bug at the edge; with
//     ready tied low the valid half cannot fire in this design and is kept as
//     a guard on that property.
//   - link transfers: every flit crossing an inter-router link is logged, so
//     the two-hop case can assert the PATH taken. A Y-first route reaches the
//     same endpoint over the other two links, so arrival alone proves nothing.
//----------------------------------------------------------------------------
module tb_mesh;

    localparam X_W        = 1;
    localparam Y_W        = 1;
    // Overridable from the command line so one source runs the whole C3
    // parameter sweep: iverilog -DCFG_DATA_W=64, xvlog -d CFG_DATA_W=64.
    // DATA_W must be >= 32; below that the src/seq/MAGIC fields overlap.
`ifndef CFG_DATA_W
  `define CFG_DATA_W 32
`endif
`ifndef CFG_FIFO_DEPTH
  `define CFG_FIFO_DEPTH 4
`endif
    localparam DATA_W     = `CFG_DATA_W;
    localparam FIFO_DEPTH = `CFG_FIFO_DEPTH;
    localparam FLIT_W     = X_W + Y_W + DATA_W;

    localparam P_LOCAL = 0;
    localparam P_NORTH = 1;
    localparam P_EAST  = 2;
    localparam P_SOUTH = 3;
    localparam P_WEST  = 4;

    localparam [7:0] MAGIC = 8'h5A;

    // Latency bounds (Stage C4), set from measurement on the design as built.
    //
    // Unloaded cost is exactly one cycle per hop plus one for ejection, and it
    // is deterministic on an idle mesh: measured min/max are 1/1 at 0 hops,
    // 2/2 at 1 hop, 3/3 at 2 hops. The bound is therefore set to the exact
    // observed worst case, not padded. Padding it would defeat the purpose --
    // a single extra pipeline stage anywhere in the datapath takes a 2-hop
    // flit from 3 cycles to 5 and must fail here.
    localparam LAT_UNLOADED_BOUND = 3;
    //
    // Loaded latency is queueing delay and depends on offered load, so a tight
    // bound here would constrain the traffic pattern rather than the design.
    // Worst measured across the whole suite is 57 cycles (2-hop, under C8b's
    // sustained head-of-line blocking). The ceiling is deliberately loose at
    // ~3.5x that: it exists to catch an unbounded stall, not to police jitter.
    localparam LAT_LOADED_BOUND   = 200;

    integer errors = 0;
    integer checks = 0;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    //------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------
    reg  [FLIT_W-1:0]   ep_flit [0:3];
    reg  [3:0]          ep_in_valid  = 4'b0;
    reg  [3:0]          ep_out_ready = 4'b1111;
    wire [3:0]          ep_in_ready;
    wire [3:0]          ep_out_valid;
    wire [4*FLIT_W-1:0] ep_in_flit_flat;
    wire [4*FLIT_W-1:0] ep_out_flit_flat;
    wire [FLIT_W-1:0]   ep_out [0:3];

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_pack
            assign ep_in_flit_flat[gi*FLIT_W +: FLIT_W] = ep_flit[gi];
            assign ep_out[gi] = ep_out_flit_flat[gi*FLIT_W +: FLIT_W];
        end
    endgenerate

    mesh_top #(
        .X_W(X_W), .Y_W(Y_W), .DATA_W(DATA_W), .FIFO_DEPTH(FIFO_DEPTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .ep_in_flit(ep_in_flit_flat),
        .ep_in_valid(ep_in_valid),
        .ep_in_ready(ep_in_ready),
        .ep_out_flit(ep_out_flit_flat),
        .ep_out_valid(ep_out_valid),
        .ep_out_ready(ep_out_ready)
    );

    //------------------------------------------------------------------
    // Helpers
    //------------------------------------------------------------------
    // Payload is built by field position rather than concatenation so it is
    // correct at any DATA_W >= 32: src occupies the top 8 bits, seq the next
    // 16, MAGIC the bottom 8, and any width above 32 becomes zero padding in
    // between. A concatenation would silently mis-size the moment DATA_W
    // moved off 32 -- which is exactly the truncation the C3 sweep hunts.
    function [FLIT_W-1:0] mk_flit;
        input [X_W-1:0]  dx;
        input [Y_W-1:0]  dy;
        input [7:0]      src;
        input [15:0]     seq;
        reg [DATA_W-1:0] pay;
        begin
            pay                 = {DATA_W{1'b0}};
            pay[DATA_W-1 -: 8]  = src;
            pay[DATA_W-9 -: 16] = seq;
            pay[7:0]            = MAGIC;
            mk_flit = {dx, dy, pay};
        end
    endfunction

    function [7:0] flit_src;
        input [FLIT_W-1:0] f;
        begin flit_src = f[DATA_W-1 -: 8]; end
    endfunction

    function [15:0] flit_seq;
        input [FLIT_W-1:0] f;
        begin flit_seq = f[DATA_W-9 -: 16]; end
    endfunction

    // endpoint index -> coordinates: ep0=(0,0) ep1=(1,0) ep2=(0,1) ep3=(1,1)
    function [X_W-1:0] ep_x;
        input integer e;
        begin ep_x = e[0]; end
    endfunction

    function [Y_W-1:0] ep_y;
        input integer e;
        begin ep_y = e[1]; end
    endfunction

    task ck;
        input          cond;
        input [1023:0] msg;
        begin
            checks = checks + 1;
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("  [FAIL] cyc=%0d  %0s", cyc, msg);
            end
        end
    endtask

    //------------------------------------------------------------------
    // Scoreboard
    //------------------------------------------------------------------
    localparam SB_MAX = 8192;
    reg [FLIT_W-1:0] sb_flit [0:SB_MAX-1];
    integer          sb_dest [0:SB_MAX-1];
    reg              sb_used [0:SB_MAX-1];
    integer          sb_n           = 0;   // total injected
    integer          sb_outstanding = 0;   // injected but not yet ejected
    integer          sb_miss        = 0;   // ejections matching nothing
    integer          sb_discarded   = 0;   // deliberately discarded by a reset (C9 policy)
    integer          total_ejected  = 0;

    // Latency instrumentation (Phase 5, Stage C4). Every scoreboard entry is
    // stamped with its injection cycle; retirement computes end-to-end latency
    // in cycles. Binned by hop count, since a 2-hop flit legitimately costs
    // more than a 1-hop one and a single global bound would hide that.
    integer          sb_cyc  [0:SB_MAX-1];
    integer          lat_max [0:2];
    integer          lat_min [0:2];
    integer          lat_sum [0:2];
    integer          lat_n   [0:2];
    integer          lat_unloaded_max = 0;   // measured only while idle-ish
    reg              lat_track_unloaded = 1'b0;
    integer          lat_viol = 0;

    // Hop count between two endpoints under XY: ep0=(0,0) ep1=(1,0)
    // ep2=(0,1) ep3=(1,1). Link crossings, so a self-send is 0.
    function integer hop_count;
        input integer s;
        input integer d;
        integer dx, dy;
        begin
            dx = (s % 2) - (d % 2);
            dy = (s / 2) - (d / 2);
            if (dx < 0) dx = -dx;
            if (dy < 0) dy = -dy;
            hop_count = dx + dy;
        end
    endfunction


    task sb_push;
        input integer          dst;
        input [FLIT_W-1:0]     f;
        begin
            sb_flit[sb_n] = f;
            sb_dest[sb_n] = dst;
            sb_used[sb_n] = 1'b1;
            sb_cyc [sb_n] = cyc;
            sb_n           = sb_n + 1;
            sb_outstanding = sb_outstanding + 1;
        end
    endtask

    //------------------------------------------------------------------
    // Ejection monitor + scoreboard retirement
    //------------------------------------------------------------------
    localparam EJ_MAX = 8192;
    integer          ej_count = 0;
    integer          ej_ep    [0:EJ_MAX-1];
    reg [FLIT_W-1:0] ej_flit  [0:EJ_MAX-1];
    integer          ej_cyc   [0:EJ_MAX-1];

    integer mp;
    integer si;
    integer found;
    integer lat_h;
    integer lat_v;
    always @(posedge clk) begin
        if (rst_n) begin
            for (mp = 0; mp < 4; mp = mp + 1) begin
                if (ep_out_valid[mp] && ep_out_ready[mp]) begin
                    ej_ep  [ej_count] = mp;
                    ej_flit[ej_count] = ep_out[mp];
                    ej_cyc [ej_count] = cyc;
                    ej_count      = ej_count + 1;
                    total_ejected = total_ejected + 1;

                    found = -1;
                    for (si = 0; si < sb_n; si = si + 1) begin
                        if (found < 0 && sb_used[si] && sb_dest[si] == mp
                            && sb_flit[si] === ep_out[mp]) found = si;
                    end
                    if (found >= 0) begin
                        sb_used[found] = 1'b0;
                        sb_outstanding = sb_outstanding - 1;
                        lat_h = hop_count(flit_src(ep_out[mp]), mp);
                        lat_v = cyc - sb_cyc[found];
                        if (lat_h >= 0 && lat_h <= 2) begin
                            lat_n  [lat_h] = lat_n[lat_h] + 1;
                            lat_sum[lat_h] = lat_sum[lat_h] + lat_v;
                            if (lat_v > lat_max[lat_h]) lat_max[lat_h] = lat_v;
                            if (lat_v < lat_min[lat_h]) lat_min[lat_h] = lat_v;
                        end
                        if (lat_track_unloaded && lat_v > lat_unloaded_max)
                            lat_unloaded_max = lat_v;
                    end else begin
                        sb_miss = sb_miss + 1;
                        if (sb_miss <= 8)
                            $display("  [FAIL] cyc=%0d ep%0d ejected an unexpected flit %h (src %0d seq %0d) -- misdelivery, duplicate or corruption",
                                     cyc, mp, ep_out[mp],
                                     flit_src(ep_out[mp]), flit_seq(ep_out[mp]));
                    end
                end
            end
        end
    end

    //------------------------------------------------------------------
    // Edge tie-off monitor (white box)
    //------------------------------------------------------------------
    // bit order: [4]WEST [3]SOUTH [2]EAST [1]NORTH [0]LOCAL
    // In a 2x2 mesh each router uses exactly two of four cardinals plus Local.
    localparam [4:0] R0_TIED = 5'b11000;   // r0 (0,0): SOUTH, WEST
    localparam [4:0] R1_TIED = 5'b01100;   // r1 (1,0): EAST,  SOUTH
    localparam [4:0] R2_TIED = 5'b10010;   // r2 (0,1): NORTH, WEST
    localparam [4:0] R3_TIED = 5'b00110;   // r3 (1,1): NORTH, EAST

    wire [4:0] r0_req [0:4];
    wire [4:0] r1_req [0:4];
    wire [4:0] r2_req [0:4];
    wire [4:0] r3_req [0:4];

    assign r0_req[0] = dut.u_r0.req[0];
    assign r0_req[1] = dut.u_r0.req[1];
    assign r0_req[2] = dut.u_r0.req[2];
    assign r0_req[3] = dut.u_r0.req[3];
    assign r0_req[4] = dut.u_r0.req[4];
    assign r1_req[0] = dut.u_r1.req[0];
    assign r1_req[1] = dut.u_r1.req[1];
    assign r1_req[2] = dut.u_r1.req[2];
    assign r1_req[3] = dut.u_r1.req[3];
    assign r1_req[4] = dut.u_r1.req[4];
    assign r2_req[0] = dut.u_r2.req[0];
    assign r2_req[1] = dut.u_r2.req[1];
    assign r2_req[2] = dut.u_r2.req[2];
    assign r2_req[3] = dut.u_r2.req[3];
    assign r2_req[4] = dut.u_r2.req[4];
    assign r3_req[0] = dut.u_r3.req[0];
    assign r3_req[1] = dut.u_r3.req[1];
    assign r3_req[2] = dut.u_r3.req[2];
    assign r3_req[3] = dut.u_r3.req[3];
    assign r3_req[4] = dut.u_r3.req[4];

    wire [4:0] r0_req_any = r0_req[0] | r0_req[1] | r0_req[2] | r0_req[3] | r0_req[4];
    wire [4:0] r1_req_any = r1_req[0] | r1_req[1] | r1_req[2] | r1_req[3] | r1_req[4];
    wire [4:0] r2_req_any = r2_req[0] | r2_req[1] | r2_req[2] | r2_req[3] | r2_req[4];
    wire [4:0] r3_req_any = r3_req[0] | r3_req[1] | r3_req[2] | r3_req[3] | r3_req[4];

    integer tie_valid_viol = 0;
    integer tie_req_viol   = 0;

    task tie_check;
        input integer rid;
        input [4:0]   ovalid;
        input [4:0]   rany;
        input [4:0]   tied;
        begin
            if (|(ovalid & tied)) begin
                tie_valid_viol = tie_valid_viol + 1;
                if (tie_valid_viol <= 5)
                    $display("  [FAIL] cyc=%0d r%0d asserted valid on a tied-off output (%b)",
                             cyc, rid, ovalid & tied);
            end
            if (|(rany & tied)) begin
                tie_req_viol = tie_req_viol + 1;
                if (tie_req_viol <= 5)
                    $display("  [FAIL] cyc=%0d r%0d requested a tied-off output (%b) -- flit aimed off the mesh",
                             cyc, rid, rany & tied);
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n) begin
            tie_check(0, dut.r0_out_valid, r0_req_any, R0_TIED);
            tie_check(1, dut.r1_out_valid, r1_req_any, R1_TIED);
            tie_check(2, dut.r2_out_valid, r2_req_any, R2_TIED);
            tie_check(3, dut.r3_out_valid, r3_req_any, R3_TIED);
        end
    end

    //------------------------------------------------------------------
    // Link transfer monitor. Link ids follow the wiring table in mesh_top.v.
    //------------------------------------------------------------------
    localparam L_R0E_R1W = 0;   // r0 EAST  -> r1 WEST
    localparam L_R1W_R0E = 1;   // r1 WEST  -> r0 EAST
    localparam L_R0N_R2S = 2;   // r0 NORTH -> r2 SOUTH
    localparam L_R2S_R0N = 3;   // r2 SOUTH -> r0 NORTH
    localparam L_R1N_R3S = 4;   // r1 NORTH -> r3 SOUTH
    localparam L_R3S_R1N = 5;   // r3 SOUTH -> r1 NORTH
    localparam L_R2E_R3W = 6;   // r2 EAST  -> r3 WEST
    localparam L_R3W_R2E = 7;   // r3 WEST  -> r2 EAST

    wire [7:0]        lnk_valid;
    wire [7:0]        lnk_ready;
    wire [FLIT_W-1:0] lnk_flit [0:7];

    assign lnk_valid[L_R0E_R1W] = dut.r0_out_valid[P_EAST];
    assign lnk_ready[L_R0E_R1W] = dut.r0_out_ready[P_EAST];
    assign lnk_flit [L_R0E_R1W] = dut.r0_out_flit[P_EAST*FLIT_W +: FLIT_W];
    assign lnk_valid[L_R1W_R0E] = dut.r1_out_valid[P_WEST];
    assign lnk_ready[L_R1W_R0E] = dut.r1_out_ready[P_WEST];
    assign lnk_flit [L_R1W_R0E] = dut.r1_out_flit[P_WEST*FLIT_W +: FLIT_W];
    assign lnk_valid[L_R0N_R2S] = dut.r0_out_valid[P_NORTH];
    assign lnk_ready[L_R0N_R2S] = dut.r0_out_ready[P_NORTH];
    assign lnk_flit [L_R0N_R2S] = dut.r0_out_flit[P_NORTH*FLIT_W +: FLIT_W];
    assign lnk_valid[L_R2S_R0N] = dut.r2_out_valid[P_SOUTH];
    assign lnk_ready[L_R2S_R0N] = dut.r2_out_ready[P_SOUTH];
    assign lnk_flit [L_R2S_R0N] = dut.r2_out_flit[P_SOUTH*FLIT_W +: FLIT_W];
    assign lnk_valid[L_R1N_R3S] = dut.r1_out_valid[P_NORTH];
    assign lnk_ready[L_R1N_R3S] = dut.r1_out_ready[P_NORTH];
    assign lnk_flit [L_R1N_R3S] = dut.r1_out_flit[P_NORTH*FLIT_W +: FLIT_W];
    assign lnk_valid[L_R3S_R1N] = dut.r3_out_valid[P_SOUTH];
    assign lnk_ready[L_R3S_R1N] = dut.r3_out_ready[P_SOUTH];
    assign lnk_flit [L_R3S_R1N] = dut.r3_out_flit[P_SOUTH*FLIT_W +: FLIT_W];
    assign lnk_valid[L_R2E_R3W] = dut.r2_out_valid[P_EAST];
    assign lnk_ready[L_R2E_R3W] = dut.r2_out_ready[P_EAST];
    assign lnk_flit [L_R2E_R3W] = dut.r2_out_flit[P_EAST*FLIT_W +: FLIT_W];
    assign lnk_valid[L_R3W_R2E] = dut.r3_out_valid[P_WEST];
    assign lnk_ready[L_R3W_R2E] = dut.r3_out_ready[P_WEST];
    assign lnk_flit [L_R3W_R2E] = dut.r3_out_flit[P_WEST*FLIT_W +: FLIT_W];

    localparam LG_MAX = 16384;
    integer          lg_count = 0;
    integer          lg_link [0:LG_MAX-1];
    reg [FLIT_W-1:0] lg_flit [0:LG_MAX-1];

    integer li;
    always @(posedge clk) begin
        if (rst_n) begin
            for (li = 0; li < 8; li = li + 1) begin
                if (lnk_valid[li] && lnk_ready[li]) begin
                    lg_link[lg_count] = li;
                    lg_flit[lg_count] = lnk_flit[li];
                    lg_count = lg_count + 1;
                end
            end
        end
    end

    integer path_len;
    integer path_buf [0:15];

    task path_of;
        input [15:0] s;
        integer a;
        begin
            path_len = 0;
            for (a = 0; a < lg_count; a = a + 1) begin
                if (flit_seq(lg_flit[a]) == s) begin
                    if (path_len < 16) path_buf[path_len] = lg_link[a];
                    path_len = path_len + 1;
                end
            end
        end
    endtask

    task expect_path2;
        input [15:0]   s;
        input integer  l0;
        input integer  l1;
        input [1023:0] name;
        begin
            path_of(s);
            checks = checks + 1;
            if (path_len != 2) begin
                errors = errors + 1;
                $display("  [FAIL] %0s: crossed %0d links, expected 2", name, path_len);
            end else if (path_buf[0] != l0 || path_buf[1] != l1) begin
                errors = errors + 1;
                $display("  [FAIL] %0s: took links %0d,%0d expected %0d,%0d -- not X-first-then-Y",
                         name, path_buf[0], path_buf[1], l0, l1);
            end else begin
                $display("  [ok]   %0s (links %0d then %0d)", name, l0, l1);
            end
        end
    endtask

    //------------------------------------------------------------------
    // PER-ARBITER BOUNDED-WAIT MONITOR (white box, Phase 5 / Stage C)
    //
    // Covers all TWENTY arbiters in the mesh (4 routers x 5 outputs), not the
    // ten at router level. Runs continuously across every case in this file.
    //
    // Property asserted -- the one round-robin actually promises:
    //   an input whose request is VISIBLE TO THE ARBITER (i.e. already masked
    //   by the receiver's ready) and ungranted waits at most N=5 grants before
    //   that arbiter serves it.
    //
    // The wait is counted in GRANTS ISSUED BY THAT ARBITER, never in cycles.
    // A cycle where the arbiter grants nobody is not a cycle anyone was passed
    // over, and a cycle where the request is masked is not a request at all.
    // This is what makes the monitor immune to offered-load effects: a source
    // throttled by head-of-line blocking upstream simply stops requesting, and
    // an input that is not requesting is not being starved (D27, metric
    // correction). An end-to-end ejection gap cannot distinguish those two and
    // is therefore reported, not asserted, wherever load is asymmetric.
    //
    // The monitor also records the maximum number of SIMULTANEOUS REQUESTERS
    // each arbiter ever sees, which turns D27's paper enumeration into a
    // measured result. Predicted caps, asserted at end of test:
    //   LOCAL outputs 3, cardinal "toward" 2, cardinal "away" 1, tied-off 0,
    //   and no arbiter anywhere above 3.
    //------------------------------------------------------------------
    localparam ARB_N      = 20;          // 4 routers x 5 outputs
    localparam ARB_BOUND  = 5;           // N grants, the arbiter's own bound

    wire [4:0] arb_reqm [0:ARB_N-1];     // requests as the arbiter sees them
    wire [4:0] arb_gnt  [0:ARB_N-1];     // one-hot grant
    wire [2:0] arb_nreq [0:ARB_N-1];     // unmasked structural requester count

    // Per-arbiter taps: index a = r*5 + k, router r, output port k.
    assign arb_reqm[ 0] = dut.u_r0.req_masked[0];  assign arb_gnt[ 0] = dut.u_r0.grant[0];   // r0.LOCAL
    assign arb_reqm[ 1] = dut.u_r0.req_masked[1];  assign arb_gnt[ 1] = dut.u_r0.grant[1];   // r0.NORTH
    assign arb_reqm[ 2] = dut.u_r0.req_masked[2];  assign arb_gnt[ 2] = dut.u_r0.grant[2];   // r0.EAST
    assign arb_reqm[ 3] = dut.u_r0.req_masked[3];  assign arb_gnt[ 3] = dut.u_r0.grant[3];   // r0.SOUTH
    assign arb_reqm[ 4] = dut.u_r0.req_masked[4];  assign arb_gnt[ 4] = dut.u_r0.grant[4];   // r0.WEST
    assign arb_reqm[ 5] = dut.u_r1.req_masked[0];  assign arb_gnt[ 5] = dut.u_r1.grant[0];   // r1.LOCAL
    assign arb_reqm[ 6] = dut.u_r1.req_masked[1];  assign arb_gnt[ 6] = dut.u_r1.grant[1];   // r1.NORTH
    assign arb_reqm[ 7] = dut.u_r1.req_masked[2];  assign arb_gnt[ 7] = dut.u_r1.grant[2];   // r1.EAST
    assign arb_reqm[ 8] = dut.u_r1.req_masked[3];  assign arb_gnt[ 8] = dut.u_r1.grant[3];   // r1.SOUTH
    assign arb_reqm[ 9] = dut.u_r1.req_masked[4];  assign arb_gnt[ 9] = dut.u_r1.grant[4];   // r1.WEST
    assign arb_reqm[10] = dut.u_r2.req_masked[0];  assign arb_gnt[10] = dut.u_r2.grant[0];   // r2.LOCAL
    assign arb_reqm[11] = dut.u_r2.req_masked[1];  assign arb_gnt[11] = dut.u_r2.grant[1];   // r2.NORTH
    assign arb_reqm[12] = dut.u_r2.req_masked[2];  assign arb_gnt[12] = dut.u_r2.grant[2];   // r2.EAST
    assign arb_reqm[13] = dut.u_r2.req_masked[3];  assign arb_gnt[13] = dut.u_r2.grant[3];   // r2.SOUTH
    assign arb_reqm[14] = dut.u_r2.req_masked[4];  assign arb_gnt[14] = dut.u_r2.grant[4];   // r2.WEST
    assign arb_reqm[15] = dut.u_r3.req_masked[0];  assign arb_gnt[15] = dut.u_r3.grant[0];   // r3.LOCAL
    assign arb_reqm[16] = dut.u_r3.req_masked[1];  assign arb_gnt[16] = dut.u_r3.grant[1];   // r3.NORTH
    assign arb_reqm[17] = dut.u_r3.req_masked[2];  assign arb_gnt[17] = dut.u_r3.grant[2];   // r3.EAST
    assign arb_reqm[18] = dut.u_r3.req_masked[3];  assign arb_gnt[18] = dut.u_r3.grant[3];   // r3.SOUTH
    assign arb_reqm[19] = dut.u_r3.req_masked[4];  assign arb_gnt[19] = dut.u_r3.grant[4];   // r3.WEST

    // Structural requesters for output k: how many inputs hold a flit wanting
    // it, taken UNMASKED so downstream ready cannot hide one. This is the
    // quantity D27 predicts caps at 3 / 2 / 1 by output class.
    assign arb_nreq[ 0] = r0_req[0][0] + r0_req[1][0] + r0_req[2][0] + r0_req[3][0] + r0_req[4][0];
    assign arb_nreq[ 1] = r0_req[0][1] + r0_req[1][1] + r0_req[2][1] + r0_req[3][1] + r0_req[4][1];
    assign arb_nreq[ 2] = r0_req[0][2] + r0_req[1][2] + r0_req[2][2] + r0_req[3][2] + r0_req[4][2];
    assign arb_nreq[ 3] = r0_req[0][3] + r0_req[1][3] + r0_req[2][3] + r0_req[3][3] + r0_req[4][3];
    assign arb_nreq[ 4] = r0_req[0][4] + r0_req[1][4] + r0_req[2][4] + r0_req[3][4] + r0_req[4][4];
    assign arb_nreq[ 5] = r1_req[0][0] + r1_req[1][0] + r1_req[2][0] + r1_req[3][0] + r1_req[4][0];
    assign arb_nreq[ 6] = r1_req[0][1] + r1_req[1][1] + r1_req[2][1] + r1_req[3][1] + r1_req[4][1];
    assign arb_nreq[ 7] = r1_req[0][2] + r1_req[1][2] + r1_req[2][2] + r1_req[3][2] + r1_req[4][2];
    assign arb_nreq[ 8] = r1_req[0][3] + r1_req[1][3] + r1_req[2][3] + r1_req[3][3] + r1_req[4][3];
    assign arb_nreq[ 9] = r1_req[0][4] + r1_req[1][4] + r1_req[2][4] + r1_req[3][4] + r1_req[4][4];
    assign arb_nreq[10] = r2_req[0][0] + r2_req[1][0] + r2_req[2][0] + r2_req[3][0] + r2_req[4][0];
    assign arb_nreq[11] = r2_req[0][1] + r2_req[1][1] + r2_req[2][1] + r2_req[3][1] + r2_req[4][1];
    assign arb_nreq[12] = r2_req[0][2] + r2_req[1][2] + r2_req[2][2] + r2_req[3][2] + r2_req[4][2];
    assign arb_nreq[13] = r2_req[0][3] + r2_req[1][3] + r2_req[2][3] + r2_req[3][3] + r2_req[4][3];
    assign arb_nreq[14] = r2_req[0][4] + r2_req[1][4] + r2_req[2][4] + r2_req[3][4] + r2_req[4][4];
    assign arb_nreq[15] = r3_req[0][0] + r3_req[1][0] + r3_req[2][0] + r3_req[3][0] + r3_req[4][0];
    assign arb_nreq[16] = r3_req[0][1] + r3_req[1][1] + r3_req[2][1] + r3_req[3][1] + r3_req[4][1];
    assign arb_nreq[17] = r3_req[0][2] + r3_req[1][2] + r3_req[2][2] + r3_req[3][2] + r3_req[4][2];
    assign arb_nreq[18] = r3_req[0][3] + r3_req[1][3] + r3_req[2][3] + r3_req[3][3] + r3_req[4][3];
    assign arb_nreq[19] = r3_req[0][4] + r3_req[1][4] + r3_req[2][4] + r3_req[3][4] + r3_req[4][4];

    integer arb_wait     [0:ARB_N*5-1];  // grants passed over since this input asked
    integer arb_worst    [0:ARB_N*5-1];  // worst such wait observed
    integer arb_maxreq   [0:ARB_N-1];    // max simultaneous requesters seen
    integer arb_grants   [0:ARB_N-1];    // grants issued, for reporting
    integer arb_wait_viol = 0;
    integer arb_worst_any = 0;

    integer mi, mk;
    integer mg;

    initial begin
        for (mi = 0; mi < ARB_N*5; mi = mi + 1) begin
            arb_wait[mi]  = 0;
            arb_worst[mi] = 0;
        end
        for (mi = 0; mi < 3; mi = mi + 1) begin
            lat_max[mi] = 0;
            lat_min[mi] = 1000000;
            lat_sum[mi] = 0;
            lat_n[mi]   = 0;
        end
        for (mi = 0; mi < ARB_N; mi = mi + 1) begin
            arb_maxreq[mi] = 0;
            arb_grants[mi] = 0;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            for (mi = 0; mi < ARB_N*5; mi = mi + 1) arb_wait[mi] = 0;
        end else begin
            for (mi = 0; mi < ARB_N; mi = mi + 1) begin
                // Structural requester census -- unmasked, so a blocked
                // downstream cannot hide a requester from the D27 caps.
                if (arb_nreq[mi] > arb_maxreq[mi]) arb_maxreq[mi] = arb_nreq[mi];

                mg = |arb_gnt[mi];               // did this arbiter serve anyone?
                if (mg) arb_grants[mi] = arb_grants[mi] + 1;

                for (mk = 0; mk < 5; mk = mk + 1) begin
                    if (arb_gnt[mi][mk]) begin
                        // Served. Retire the wait.
                        if (arb_wait[mi*5+mk] > arb_worst[mi*5+mk])
                            arb_worst[mi*5+mk] = arb_wait[mi*5+mk];
                        if (arb_wait[mi*5+mk] > arb_worst_any)
                            arb_worst_any = arb_wait[mi*5+mk];
                        arb_wait[mi*5+mk] = 0;
                    end else if (arb_reqm[mi][mk] && mg) begin
                        // Requesting, visible to the arbiter, and passed over
                        // in favour of somebody else. That is one grant of wait.
                        arb_wait[mi*5+mk] = arb_wait[mi*5+mk] + 1;
                        if (arb_wait[mi*5+mk] > arb_worst_any)
                            arb_worst_any = arb_wait[mi*5+mk];
                        if (arb_wait[mi*5+mk] > ARB_BOUND) begin
                            arb_wait_viol = arb_wait_viol + 1;
                            if (arb_wait_viol <= 8)
                                $display("  [FAIL] cyc=%0d BOUNDED-WAIT VIOLATION: arbiter %0d (r%0d out %0d) input %0d waited %0d grants, bound %0d",
                                         cyc, mi, mi/5, mi%5, mk,
                                         arb_wait[mi*5+mk], ARB_BOUND);
                        end
                    end
                end
            end
        end
    end

    //------------------------------------------------------------------
    // INVARIANT 3 MONITOR (white box) -- the pointer-update property, on all
    // twenty mesh arbiters. This is the mesh-level counterpart of tb_router's
    // T10, which covers only the ten router-level arbiters.
    //
    // `priority_ptr` may change ONLY on a cycle where its output both granted
    // and the receiver was ready, i.e. on a grant that actually transferred a
    // flit. An arbiter that advances on a masked or stalled request keeps its
    // bounded-wait property intact locally and looks correct in any test where
    // the receiver is always ready -- it loses its place only under sustained
    // backpressure, which is exactly when fairness matters. Simulation of the
    // functional path will not notice; only this check will.
    //------------------------------------------------------------------
    wire [2:0] arb_ptr  [0:ARB_N-1];
    wire       arb_ordy [0:ARB_N-1];

    assign arb_ptr[ 0] = dut.u_r0.g_output[0].u_arb.priority_ptr;  assign arb_ordy[ 0] = dut.u_r0.out_ready[0];   // r0.LOCAL
    assign arb_ptr[ 1] = dut.u_r0.g_output[1].u_arb.priority_ptr;  assign arb_ordy[ 1] = dut.u_r0.out_ready[1];   // r0.NORTH
    assign arb_ptr[ 2] = dut.u_r0.g_output[2].u_arb.priority_ptr;  assign arb_ordy[ 2] = dut.u_r0.out_ready[2];   // r0.EAST
    assign arb_ptr[ 3] = dut.u_r0.g_output[3].u_arb.priority_ptr;  assign arb_ordy[ 3] = dut.u_r0.out_ready[3];   // r0.SOUTH
    assign arb_ptr[ 4] = dut.u_r0.g_output[4].u_arb.priority_ptr;  assign arb_ordy[ 4] = dut.u_r0.out_ready[4];   // r0.WEST
    assign arb_ptr[ 5] = dut.u_r1.g_output[0].u_arb.priority_ptr;  assign arb_ordy[ 5] = dut.u_r1.out_ready[0];   // r1.LOCAL
    assign arb_ptr[ 6] = dut.u_r1.g_output[1].u_arb.priority_ptr;  assign arb_ordy[ 6] = dut.u_r1.out_ready[1];   // r1.NORTH
    assign arb_ptr[ 7] = dut.u_r1.g_output[2].u_arb.priority_ptr;  assign arb_ordy[ 7] = dut.u_r1.out_ready[2];   // r1.EAST
    assign arb_ptr[ 8] = dut.u_r1.g_output[3].u_arb.priority_ptr;  assign arb_ordy[ 8] = dut.u_r1.out_ready[3];   // r1.SOUTH
    assign arb_ptr[ 9] = dut.u_r1.g_output[4].u_arb.priority_ptr;  assign arb_ordy[ 9] = dut.u_r1.out_ready[4];   // r1.WEST
    assign arb_ptr[10] = dut.u_r2.g_output[0].u_arb.priority_ptr;  assign arb_ordy[10] = dut.u_r2.out_ready[0];   // r2.LOCAL
    assign arb_ptr[11] = dut.u_r2.g_output[1].u_arb.priority_ptr;  assign arb_ordy[11] = dut.u_r2.out_ready[1];   // r2.NORTH
    assign arb_ptr[12] = dut.u_r2.g_output[2].u_arb.priority_ptr;  assign arb_ordy[12] = dut.u_r2.out_ready[2];   // r2.EAST
    assign arb_ptr[13] = dut.u_r2.g_output[3].u_arb.priority_ptr;  assign arb_ordy[13] = dut.u_r2.out_ready[3];   // r2.SOUTH
    assign arb_ptr[14] = dut.u_r2.g_output[4].u_arb.priority_ptr;  assign arb_ordy[14] = dut.u_r2.out_ready[4];   // r2.WEST
    assign arb_ptr[15] = dut.u_r3.g_output[0].u_arb.priority_ptr;  assign arb_ordy[15] = dut.u_r3.out_ready[0];   // r3.LOCAL
    assign arb_ptr[16] = dut.u_r3.g_output[1].u_arb.priority_ptr;  assign arb_ordy[16] = dut.u_r3.out_ready[1];   // r3.NORTH
    assign arb_ptr[17] = dut.u_r3.g_output[2].u_arb.priority_ptr;  assign arb_ordy[17] = dut.u_r3.out_ready[2];   // r3.EAST
    assign arb_ptr[18] = dut.u_r3.g_output[3].u_arb.priority_ptr;  assign arb_ordy[18] = dut.u_r3.out_ready[3];   // r3.SOUTH
    assign arb_ptr[19] = dut.u_r3.g_output[4].u_arb.priority_ptr;  assign arb_ordy[19] = dut.u_r3.out_ready[4];   // r3.WEST

    reg [2:0] arb_ptr_q  [0:ARB_N-1];
    reg       arb_xfer_q [0:ARB_N-1];      // grant AND ready, previous cycle
    integer   arb_ptr_viol = 0;
    integer   pi;

    initial begin
        for (pi = 0; pi < ARB_N; pi = pi + 1) begin
            arb_ptr_q[pi]  = 3'd0;
            arb_xfer_q[pi] = 1'b0;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            for (pi = 0; pi < ARB_N; pi = pi + 1) begin
                arb_ptr_q[pi]  = arb_ptr[pi];
                arb_xfer_q[pi] = 1'b0;
            end
        end else begin
            for (pi = 0; pi < ARB_N; pi = pi + 1) begin
                if (arb_ptr[pi] !== arb_ptr_q[pi] && !arb_xfer_q[pi]) begin
                    arb_ptr_viol = arb_ptr_viol + 1;
                    if (arb_ptr_viol <= 8)
                        $display("  [FAIL] cyc=%0d INVARIANT 3: arbiter %0d (r%0d out %0d) priority_ptr moved %0d -> %0d with no completed grant",
                                 cyc, pi, pi/5, pi%5, arb_ptr_q[pi], arb_ptr[pi]);
                end
                arb_ptr_q[pi]  = arb_ptr[pi];
                arb_xfer_q[pi] = (|arb_gnt[pi]) && arb_ordy[pi];
            end
        end
    end


    //------------------------------------------------------------------
    // FIFO occupancy taps (white box) -- used by the reset-during-traffic
    // case to prove the network was actually loaded when reset hit, and that
    // every FIFO came back empty afterwards.
    //------------------------------------------------------------------
    // Deliberately wider than any CNT_W this design will use. CNT_W is
    // clog2(FIFO_DEPTH+1) -- 3 at depth 4, 4 at depth 8 -- so a tap sized to
    // the current depth would silently truncate under the C3 parameter sweep.
    // Zero-extension into a wider wire is harmless; truncation would not be.
    wire [7:0]  fifo_cnt [0:19];
    wire        fifo_mt  [0:19];

    // FIFO occupancy taps: index f = r*5 + i, router r, INPUT port i.
    assign fifo_cnt[ 0] = dut.u_r0.g_input[0].u_fifo.count;  assign fifo_mt[ 0] = dut.u_r0.g_input[0].u_fifo.empty;   // r0.LOCAL
    assign fifo_cnt[ 1] = dut.u_r0.g_input[1].u_fifo.count;  assign fifo_mt[ 1] = dut.u_r0.g_input[1].u_fifo.empty;   // r0.NORTH
    assign fifo_cnt[ 2] = dut.u_r0.g_input[2].u_fifo.count;  assign fifo_mt[ 2] = dut.u_r0.g_input[2].u_fifo.empty;   // r0.EAST
    assign fifo_cnt[ 3] = dut.u_r0.g_input[3].u_fifo.count;  assign fifo_mt[ 3] = dut.u_r0.g_input[3].u_fifo.empty;   // r0.SOUTH
    assign fifo_cnt[ 4] = dut.u_r0.g_input[4].u_fifo.count;  assign fifo_mt[ 4] = dut.u_r0.g_input[4].u_fifo.empty;   // r0.WEST
    assign fifo_cnt[ 5] = dut.u_r1.g_input[0].u_fifo.count;  assign fifo_mt[ 5] = dut.u_r1.g_input[0].u_fifo.empty;   // r1.LOCAL
    assign fifo_cnt[ 6] = dut.u_r1.g_input[1].u_fifo.count;  assign fifo_mt[ 6] = dut.u_r1.g_input[1].u_fifo.empty;   // r1.NORTH
    assign fifo_cnt[ 7] = dut.u_r1.g_input[2].u_fifo.count;  assign fifo_mt[ 7] = dut.u_r1.g_input[2].u_fifo.empty;   // r1.EAST
    assign fifo_cnt[ 8] = dut.u_r1.g_input[3].u_fifo.count;  assign fifo_mt[ 8] = dut.u_r1.g_input[3].u_fifo.empty;   // r1.SOUTH
    assign fifo_cnt[ 9] = dut.u_r1.g_input[4].u_fifo.count;  assign fifo_mt[ 9] = dut.u_r1.g_input[4].u_fifo.empty;   // r1.WEST
    assign fifo_cnt[10] = dut.u_r2.g_input[0].u_fifo.count;  assign fifo_mt[10] = dut.u_r2.g_input[0].u_fifo.empty;   // r2.LOCAL
    assign fifo_cnt[11] = dut.u_r2.g_input[1].u_fifo.count;  assign fifo_mt[11] = dut.u_r2.g_input[1].u_fifo.empty;   // r2.NORTH
    assign fifo_cnt[12] = dut.u_r2.g_input[2].u_fifo.count;  assign fifo_mt[12] = dut.u_r2.g_input[2].u_fifo.empty;   // r2.EAST
    assign fifo_cnt[13] = dut.u_r2.g_input[3].u_fifo.count;  assign fifo_mt[13] = dut.u_r2.g_input[3].u_fifo.empty;   // r2.SOUTH
    assign fifo_cnt[14] = dut.u_r2.g_input[4].u_fifo.count;  assign fifo_mt[14] = dut.u_r2.g_input[4].u_fifo.empty;   // r2.WEST
    assign fifo_cnt[15] = dut.u_r3.g_input[0].u_fifo.count;  assign fifo_mt[15] = dut.u_r3.g_input[0].u_fifo.empty;   // r3.LOCAL
    assign fifo_cnt[16] = dut.u_r3.g_input[1].u_fifo.count;  assign fifo_mt[16] = dut.u_r3.g_input[1].u_fifo.empty;   // r3.NORTH
    assign fifo_cnt[17] = dut.u_r3.g_input[2].u_fifo.count;  assign fifo_mt[17] = dut.u_r3.g_input[2].u_fifo.empty;   // r3.EAST
    assign fifo_cnt[18] = dut.u_r3.g_input[3].u_fifo.count;  assign fifo_mt[18] = dut.u_r3.g_input[3].u_fifo.empty;   // r3.SOUTH
    assign fifo_cnt[19] = dut.u_r3.g_input[4].u_fifo.count;  assign fifo_mt[19] = dut.u_r3.g_input[4].u_fifo.empty;   // r3.WEST


    // Predicted requester cap per output, from the D27 enumeration.
    //   LOCAL 3, cardinal toward the rest of the mesh 2, cardinal away 1,
    //   off-mesh tied-off 0.
    function integer req_cap;
        input integer r;
        input integer k;
        begin
            req_cap = 0;
            case (r)
            0: case (k)                       // r0 (0,0): live LOCAL/NORTH/EAST
                 P_LOCAL: req_cap = 3;
                 P_NORTH: req_cap = 2;
                 P_EAST : req_cap = 1;
                 default: req_cap = 0;
               endcase
            1: case (k)                       // r1 (1,0): live LOCAL/NORTH/WEST
                 P_LOCAL: req_cap = 3;
                 P_NORTH: req_cap = 2;
                 P_WEST : req_cap = 1;
                 default: req_cap = 0;
               endcase
            2: case (k)                       // r2 (0,1): live LOCAL/SOUTH/EAST
                 P_LOCAL: req_cap = 3;
                 P_SOUTH: req_cap = 2;
                 P_EAST : req_cap = 1;
                 default: req_cap = 0;
               endcase
            3: case (k)                       // r3 (1,1): live LOCAL/SOUTH/WEST
                 P_LOCAL: req_cap = 3;
                 P_SOUTH: req_cap = 2;
                 P_WEST : req_cap = 1;
                 default: req_cap = 0;
               endcase
            default: req_cap = 0;
            endcase
        end
    endfunction


    //------------------------------------------------------------------
    // Drive helpers
    //------------------------------------------------------------------
    task do_reset;
        integer r;
        begin
            rst_n        = 1'b0;
            ep_in_valid  = 4'b0;
            ep_out_ready = 4'b1111;
            for (r = 0; r < 4; r = r + 1) ep_flit[r] = {FLIT_W{1'b0}};
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            @(negedge clk);
        end
    endtask

    // Inject one flit from src to dst and score it.
    task send;
        input integer src;
        input integer dst;
        input [15:0]  seq;
        reg [FLIT_W-1:0] f;
        begin
            f = mk_flit(ep_x(dst), ep_y(dst), src[7:0], seq);
            @(negedge clk);
            ep_in_valid[src] = 1'b1;
            ep_flit[src]     = f;
            while (ep_in_ready[src] !== 1'b1) @(negedge clk);
            sb_push(dst, f);
            @(negedge clk);
            ep_in_valid[src] = 1'b0;
        end
    endtask

    task clear_ej;
        begin ej_count = 0; end
    endtask

    //------------------------------------------------------------------
    integer n;
    integer a;
    integer b;
    integer accepted;
    integer src_ep;
    integer dst_ep;
    integer seq_ctr;
    reg [3:0] acc;
    integer seq_of  [0:3];
    integer since   [0:3];
    integer worst   [0:3];
    integer served  [0:3];
    integer max_wait;
    integer stream_ej;
    integer ss;
    reg [FLIT_W-1:0] f;

    // C9 reset-during-traffic state (Phase 5, Stage C2)
    integer c9_loaded;
    integer c9_occ;
    integer c9_outstanding;
    integer c9_purged;
    integer c9_bad_fifo;
    integer c9_bad_ptr;
    integer c9_inj_at_reset;
    integer c9_ej_at_release;
    integer c9_miss_before;
    integer c9_post_before;
    integer c9_post;

    // C8 traffic-pattern state (Phase 5, Stage C)
    integer dst_of [0:3];          // current destination per source
    integer phase  [0:3];          // position in that source's repeating cycle
    integer c8_maxgap;
    integer c8_cnt;
    integer c8_inj_before;
    integer c8_ej_before;
    integer c8_miss_before;
    integer c8_inj;
    integer c8_ej;
    integer ca;
    integer cr;
    integer ck_port;

    // C8b destination schedule. ep0 sends three flits to ep2 for every one to
    // ep1, so its ep1-bound flit spends most of its life behind a head aimed
    // at a congested output -- that is the head-of-line blocking the case
    // exists to create. ep1 alternates so it feeds both the r0.NORTH
    // contention (via r1->r0->r2) and the r1.LOCAL contention (self-send).
    function integer c8b_dest;
        input integer src;
        input integer ph;
        begin
            case (src)
                0: c8b_dest = ((ph % 4) == 3) ? 1 : 2;   // [2,2,2,1]
                1: c8b_dest = ((ph % 2) == 1) ? 1 : 2;   // [2,1]
                2: c8b_dest = 1;
                3: c8b_dest = 1;
                default: c8b_dest = 1;
            endcase
        end
    endfunction


    initial begin
        $dumpfile("tb_mesh.vcd");
        $dumpvars(0, tb_mesh);

        $display("=== tb_mesh: 2x2 mesh, NOC_MESH_PROJECT.md section 6 ===");
        do_reset;
        seq_ctr = 0;

        //--------------------------------------------------------------
        // CASE 1 -- single hop, adjacent routers, all four link directions
        //--------------------------------------------------------------
        lat_track_unloaded = 1'b1;   // cases 1-2 run on an idle mesh
        $display("-- Case 1  single-hop");
        clear_ej; lg_count = 0;
        send(0, 1, 16'd1);  repeat (10) @(negedge clk);
        ck(ej_count == 1 && ej_ep[0] == 1, "C1 ep0 -> ep1 single hop");
        clear_ej; lg_count = 0;
        send(1, 0, 16'd2);  repeat (10) @(negedge clk);
        ck(ej_count == 1 && ej_ep[0] == 0, "C1 ep1 -> ep0 single hop");
        clear_ej; lg_count = 0;
        send(0, 2, 16'd3);  repeat (10) @(negedge clk);
        ck(ej_count == 1 && ej_ep[0] == 2, "C1 ep0 -> ep2 single hop");
        clear_ej; lg_count = 0;
        send(2, 0, 16'd4);  repeat (10) @(negedge clk);
        ck(ej_count == 1 && ej_ep[0] == 0, "C1 ep2 -> ep0 single hop");
        clear_ej; lg_count = 0;
        send(3, 1, 16'd5);  repeat (10) @(negedge clk);
        ck(ej_count == 1 && ej_ep[0] == 1, "C1 ep3 -> ep1 single hop");
        clear_ej; lg_count = 0;
        send(2, 3, 16'd6);  repeat (10) @(negedge clk);
        ck(ej_count == 1 && ej_ep[0] == 3, "C1 ep2 -> ep3 single hop");
        $display("  [ok]   C1 six single hops delivered");

        //--------------------------------------------------------------
        // CASE 2 -- two hop, and it must be X first then Y
        //--------------------------------------------------------------
        $display("-- Case 2  two-hop, X before Y");
        clear_ej; lg_count = 0;
        send(0, 3, 16'd10); repeat (12) @(negedge clk);
        ck(ej_count == 1 && ej_ep[0] == 3, "C2 ep0 -> ep3 arrives");
        expect_path2(16'd10, L_R0E_R1W, L_R1N_R3S, "C2 ep0 -> ep3 EAST then NORTH");

        clear_ej; lg_count = 0;
        send(3, 0, 16'd11); repeat (12) @(negedge clk);
        ck(ej_count == 1 && ej_ep[0] == 0, "C2 ep3 -> ep0 arrives");
        expect_path2(16'd11, L_R3W_R2E, L_R2S_R0N, "C2 ep3 -> ep0 WEST then SOUTH");

        clear_ej; lg_count = 0;
        send(1, 2, 16'd12); repeat (12) @(negedge clk);
        ck(ej_count == 1 && ej_ep[0] == 2, "C2 ep1 -> ep2 arrives");
        expect_path2(16'd12, L_R1W_R0E, L_R0N_R2S, "C2 ep1 -> ep2 WEST then NORTH");

        clear_ej; lg_count = 0;
        send(2, 1, 16'd13); repeat (12) @(negedge clk);
        ck(ej_count == 1 && ej_ep[0] == 1, "C2 ep2 -> ep1 arrives");
        expect_path2(16'd13, L_R2E_R3W, L_R3S_R1N, "C2 ep2 -> ep1 EAST then SOUTH");

        //--------------------------------------------------------------
        // CASE 3 -- all four endpoints inject in the same cycle
        //--------------------------------------------------------------
        lat_track_unloaded = 1'b0;   // from here on the mesh is contended
        $display("-- Case 3  simultaneous injection from all four endpoints");
        clear_ej; lg_count = 0;
        @(negedge clk);
        ep_flit[0] = mk_flit(ep_x(1), ep_y(1), 8'd0, 16'd20);
        ep_flit[1] = mk_flit(ep_x(2), ep_y(2), 8'd1, 16'd21);
        ep_flit[2] = mk_flit(ep_x(3), ep_y(3), 8'd2, 16'd22);
        ep_flit[3] = mk_flit(ep_x(0), ep_y(0), 8'd3, 16'd23);
        ep_in_valid = 4'b1111;
        ck(ep_in_ready === 4'b1111, "C3 not every endpoint could accept in the same cycle");
        sb_push(1, ep_flit[0]);
        sb_push(2, ep_flit[1]);
        sb_push(3, ep_flit[2]);
        sb_push(0, ep_flit[3]);
        @(negedge clk);
        ep_in_valid = 4'b0000;
        repeat (20) @(negedge clk);
        ck(ej_count == 4, "C3 four simultaneous injections did not all arrive");
        if (ej_count == 4)
            $display("  [ok]   C3 four simultaneous injections all delivered");

        //--------------------------------------------------------------
        // CASE 4 -- output contention: three sources aimed at one endpoint
        //--------------------------------------------------------------
        $display("-- Case 4  output contention on one endpoint");
        clear_ej; lg_count = 0;
        @(negedge clk);
        ep_flit[0] = mk_flit(ep_x(3), ep_y(3), 8'd0, 16'd30);
        ep_flit[1] = mk_flit(ep_x(3), ep_y(3), 8'd1, 16'd31);
        ep_flit[2] = mk_flit(ep_x(3), ep_y(3), 8'd2, 16'd32);
        ep_in_valid = 4'b0111;
        sb_push(3, ep_flit[0]);
        sb_push(3, ep_flit[1]);
        sb_push(3, ep_flit[2]);
        @(negedge clk);
        ep_in_valid = 4'b0000;
        repeat (24) @(negedge clk);
        ck(ej_count == 3, "C4 the three contending flits did not all arrive");
        for (n = 0; n < ej_count; n = n + 1)
            ck(ej_ep[n] == 3, "C4 a contending flit arrived at the wrong endpoint");
        // exactly one flit may leave a given endpoint per cycle
        for (n = 1; n < ej_count; n = n + 1)
            ck(ej_cyc[n] != ej_cyc[n-1],
               "C4 two flits ejected at the same endpoint in the same cycle");
        if (ej_count == 3)
            $display("  [ok]   C4 three contenders served on cycles %0d, %0d, %0d",
                     ej_cyc[0], ej_cyc[1], ej_cyc[2]);

        //--------------------------------------------------------------
        // CASE 5 -- sustained load / starvation.
        // All four endpoints inject at ep3 every cycle for 200 cycles.
        // Traffic converges on r3's Local output through two arbitration
        // stages, so the per-source bound is 5 grants at each of two stages.
        //--------------------------------------------------------------
        $display("-- Case 5  sustained load / starvation bound");
        clear_ej; lg_count = 0;
        for (a = 0; a < 4; a = a + 1) seq_of[a] = 0;
        @(negedge clk);
        for (a = 0; a < 4; a = a + 1) begin
            ep_in_valid[a] = 1'b1;
            ep_flit[a] = mk_flit(ep_x(3), ep_y(3), a[7:0], 16'd1000 + seq_of[a][15:0]);
        end
        for (n = 0; n < 200; n = n + 1) begin
            acc = ep_in_valid & ep_in_ready;
            for (a = 0; a < 4; a = a + 1)
                if (acc[a]) sb_push(3, ep_flit[a]);
            @(negedge clk);
            for (a = 0; a < 4; a = a + 1) begin
                if (acc[a]) seq_of[a] = seq_of[a] + 1;
                ep_flit[a] = mk_flit(ep_x(3), ep_y(3), a[7:0],
                                     16'd1000 + seq_of[a][15:0]);
            end
        end
        ep_in_valid = 4'b0000;
        stream_ej = ej_count;
        repeat (200) @(negedge clk);

        for (a = 0; a < 4; a = a + 1) begin
            since[a] = 0; worst[a] = 0; served[a] = 0;
        end
        max_wait = 0;
        for (n = 0; n < stream_ej; n = n + 1) begin
            ss = flit_src(ej_flit[n]);
            served[ss] = served[ss] + 1;
            for (b = 0; b < 4; b = b + 1) begin
                if (b == ss) since[b] = 0;
                else begin
                    since[b] = since[b] + 1;
                    if (n >= 20 && since[b] > worst[b]) worst[b] = since[b];
                end
            end
        end
        for (a = 0; a < 4; a = a + 1)
            if (worst[a] > max_wait) max_wait = worst[a];
        $display("         %0d grants under load; per-source service %0d %0d %0d %0d; worst wait %0d grants",
                 stream_ej, served[0], served[1], served[2], served[3], max_wait);
        ck(stream_ej > 100, "C5 throughput collapsed under sustained load");
        // Two round-robin stages of at most 5 grants each bound the wait.
        ck(max_wait <= 25, "C5 a source waited more than 25 grants -- STARVATION");
        for (a = 0; a < 4; a = a + 1)
            ck(served[a] > stream_ej/12, "C5 a source got far below its fair share");
        if (max_wait <= 25)
            $display("  [ok]   C5 every source served within %0d grants (bound 25)", max_wait);

        //--------------------------------------------------------------
        // CASE 6 -- backpressure / FIFO full, propagating across two hops
        //--------------------------------------------------------------
        $display("-- Case 6  backpressure / FIFO full");
        clear_ej; lg_count = 0;
        ep_out_ready[3] = 1'b0;
        accepted = 0;
        @(negedge clk);
        ep_in_valid[0] = 1'b1;
        for (n = 0; n < 8*FIFO_DEPTH; n = n + 1) begin
            ep_flit[0] = mk_flit(ep_x(3), ep_y(3), 8'd0, 16'd2000 + accepted[15:0]);
            if (ep_in_ready[0] === 1'b1) begin
                sb_push(3, ep_flit[0]);
                accepted = accepted + 1;
            end
            @(negedge clk);
        end
        ep_in_valid[0] = 1'b0;
        ck(ep_in_ready[0] === 1'b0,
           "C6 backpressure never reached the injecting endpoint");
        ck(ej_count == 0, "C6 a flit ejected while ep3 was not ready");
        $display("         %0d flits absorbed by the path before ep0 stalled", accepted);
        ep_out_ready[3] = 1'b1;
        repeat (8*FIFO_DEPTH + 40) @(negedge clk);
        ck(ej_count == accepted, "C6 not every stalled flit arrived after release");
        for (n = 0; n < ej_count; n = n + 1)
            ck(ej_ep[n] == 3, "C6 a released flit arrived at the wrong endpoint");
        if (ej_count == accepted)
            $display("  [ok]   C6 all %0d flits arrived after ready reasserted, none lost",
                     accepted);

        //--------------------------------------------------------------
        // CASE 7 -- all-to-all: every source to every destination
        //--------------------------------------------------------------
        $display("-- Case 7  all-to-all");
        clear_ej; lg_count = 0;
        seq_ctr = 3000;
        for (n = 0; n < 8; n = n + 1) begin
            for (src_ep = 0; src_ep < 4; src_ep = src_ep + 1) begin
                for (dst_ep = 0; dst_ep < 4; dst_ep = dst_ep + 1) begin
                    send(src_ep, dst_ep, seq_ctr[15:0]);
                    seq_ctr = seq_ctr + 1;
                end
            end
        end
        repeat (200) @(negedge clk);
        ck(ej_count == 128, "C7 all-to-all did not deliver all 128 flits");
        if (ej_count == 128)
            $display("  [ok]   C7 all 128 source/destination flits delivered exactly once");

        //--------------------------------------------------------------
        // CASE 8a -- uniform all-to-all saturation (Phase 5, Stage C).
        //
        // Every endpoint injects every cycle, cycling its destination through
        // the other three. This is the first test in the suite where an input
        // FIFO holds flits bound for DIFFERENT output ports, so it is the
        // first that can exhibit head-of-line blocking at all: a head bound
        // for a congested output blocks a flit behind it bound for a free one.
        // Every arbiter in the mesh is active and request masking is constant.
        //
        // Offered load is symmetric under the rotation group of the mesh --
        // every source offers the same rate to the same path-length profile --
        // so the end-to-end ejection gap is a fair measure here and IS
        // asserted. C8b, which throttles one source deliberately, is not.
        //--------------------------------------------------------------
        $display("-- Case 8a  uniform all-to-all saturation");
        clear_ej; lg_count = 0;
        for (a = 0; a < 4; a = a + 1) seq_of[a] = 0;
        @(negedge clk);
        for (a = 0; a < 4; a = a + 1) begin
            dst_of[a]        = (a + 1) % 4;
            ep_in_valid[a]   = 1'b1;
            ep_flit[a]       = mk_flit(ep_x(dst_of[a]), ep_y(dst_of[a]),
                                       a[7:0], 16'd4000 + seq_of[a][15:0]);
        end
        for (n = 0; n < 300; n = n + 1) begin
            acc = ep_in_valid & ep_in_ready;
            for (a = 0; a < 4; a = a + 1)
                if (acc[a]) sb_push(dst_of[a], ep_flit[a]);
            @(negedge clk);
            for (a = 0; a < 4; a = a + 1) begin
                if (acc[a]) begin
                    seq_of[a] = seq_of[a] + 1;
                    // Cycle through ALL four destinations, self included.
                    // A self-send is the only way a LOCAL output can reach its
                    // third requester, so excluding it would leave two of the
                    // four D27 caps measured but never actually reached.
                    dst_of[a] = (dst_of[a] + 1) % 4;
                end
                ep_flit[a] = mk_flit(ep_x(dst_of[a]), ep_y(dst_of[a]), a[7:0],
                                     16'd4000 + seq_of[a][15:0]);
            end
        end
        ep_in_valid = 4'b0000;
        stream_ej = ej_count;
        repeat (400) @(negedge clk);

        ck(stream_ej > 200, "C8a throughput collapsed under all-to-all load");

        // Per-destination ejection gap. For each endpoint d, how many
        // ejections at d separate two successive ejections from source s.
        c8_maxgap = 0;
        for (dst_ep = 0; dst_ep < 4; dst_ep = dst_ep + 1) begin
            for (a = 0; a < 4; a = a + 1) begin
                since[a] = 0; worst[a] = 0; served[a] = 0;
            end
            c8_cnt = 0;
            for (n = 0; n < stream_ej; n = n + 1) begin
                if (ej_ep[n] == dst_ep) begin
                    c8_cnt = c8_cnt + 1;
                    ss = flit_src(ej_flit[n]);
                    served[ss] = served[ss] + 1;
                    for (b = 0; b < 4; b = b + 1) begin
                        if (b == ss) since[b] = 0;
                        else begin
                            since[b] = since[b] + 1;
                            // Only once b has actually been served here, so a
                            // cold start is not scored as a gap.
                            if (c8_cnt >= 20 && served[b] > 0
                                && since[b] > worst[b]) worst[b] = since[b];
                        end
                    end
                end
            end
            for (a = 0; a < 4; a = a + 1)
                if (worst[a] > c8_maxgap) c8_maxgap = worst[a];
            $display("         ep%0d: %0d ejections; per-source %0d %0d %0d %0d; worst gap %0d %0d %0d %0d",
                     dst_ep, c8_cnt, served[0], served[1], served[2], served[3],
                     worst[0], worst[1], worst[2], worst[3]);
        end
        $display("         worst end-to-end gap across all endpoints: %0d (bound 25)",
                 c8_maxgap);
        ck(c8_maxgap <= 25, "C8a a source waited more than 25 ejections under symmetric load");
        if (c8_maxgap <= 25)
            $display("  [ok]   C8a every source served within %0d ejections at every endpoint",
                     c8_maxgap);

        //--------------------------------------------------------------
        // CASE 8b -- targeted compounding contention under head-of-line
        // blocking (Phase 5, Stage C).
        //
        //   ep0  [->ep2, ->ep2, ->ep2, ->ep1]   victim; its ep1-bound flit is
        //                                       held behind ep2-bound heads
        //   ep1  [->ep2, ->ep1]                 supplies the second requester
        //                                       at r0.NORTH via r1->r0->r2,
        //                                       and the third at r1.LOCAL
        //   ep2  ->ep1 always                   r2->r3->r1, contends r3.SOUTH
        //   ep3  ->ep1 always                   r3->r1,     contends r3.SOUTH
        //
        // ep0's ep2-bound traffic contends 2-way at r0.NORTH and stalls when
        // r2 backpressures; its ep1-bound flit then sits behind a stalled head
        // even though r0.EAST is free. That is the deepest series structure
        // this topology allows (D27): a 2-way cardinal contention plus HOL,
        // into a 3-way LOCAL contention at r1.
        //
        // THE GAP IS REPORTED, NOT ASSERTED. ep0 is throttled here on purpose,
        // and a throttled source's ejection gap is not starvation -- asserting
        // on it would manufacture a defect where the design is correct (D27).
        // What IS asserted is what a sustained stalled FIFO head actually puts
        // at risk: invariants 4 and 5, i.e. no loss, no duplication, and full
        // scoreboard reconciliation. Fairness is covered by the per-arbiter
        // monitor, which is running throughout.
        //--------------------------------------------------------------
        $display("-- Case 8b  targeted compounding contention under HOL blocking");
        clear_ej; lg_count = 0;
        c8_inj_before = sb_n;
        c8_ej_before  = total_ejected;
        c8_miss_before = sb_miss;
        for (a = 0; a < 4; a = a + 1) begin seq_of[a] = 0; phase[a] = 0; end
        @(negedge clk);
        for (a = 0; a < 4; a = a + 1) begin
            dst_of[a]      = c8b_dest(a, 0);
            ep_in_valid[a] = 1'b1;
            ep_flit[a]     = mk_flit(ep_x(dst_of[a]), ep_y(dst_of[a]),
                                     a[7:0], 16'd5000 + seq_of[a][15:0]);
        end
        for (n = 0; n < 300; n = n + 1) begin
            acc = ep_in_valid & ep_in_ready;
            for (a = 0; a < 4; a = a + 1)
                if (acc[a]) sb_push(dst_of[a], ep_flit[a]);
            @(negedge clk);
            for (a = 0; a < 4; a = a + 1) begin
                if (acc[a]) begin
                    seq_of[a] = seq_of[a] + 1;
                    phase[a]  = phase[a] + 1;
                    dst_of[a] = c8b_dest(a, phase[a]);
                end
                ep_flit[a] = mk_flit(ep_x(dst_of[a]), ep_y(dst_of[a]), a[7:0],
                                     16'd5000 + seq_of[a][15:0]);
            end
        end
        ep_in_valid = 4'b0000;
        stream_ej = ej_count;
        repeat (600) @(negedge clk);

        // Measurement only -- see the header. Gap for ep0 observed at ep1.
        for (a = 0; a < 4; a = a + 1) begin
            since[a] = 0; worst[a] = 0; served[a] = 0;
        end
        c8_cnt = 0;
        for (n = 0; n < ej_count; n = n + 1) begin
            if (ej_ep[n] == 1) begin
                c8_cnt = c8_cnt + 1;
                ss = flit_src(ej_flit[n]);
                served[ss] = served[ss] + 1;
                for (b = 0; b < 4; b = b + 1) begin
                    if (b == ss) since[b] = 0;
                    else begin
                        since[b] = since[b] + 1;
                        if (c8_cnt >= 20 && served[b] > 0
                            && since[b] > worst[b]) worst[b] = since[b];
                    end
                end
            end
        end
        $display("         ep1 received %0d; per-source %0d %0d %0d %0d",
                 c8_cnt, served[0], served[1], served[2], served[3]);
        $display("         MEASURED (not asserted) worst ejection gap at ep1: ep0=%0d ep2=%0d ep3=%0d",
                 worst[0], worst[2], worst[3]);
        $display("         victim ep0 is HOL-throttled by design; this gap is not a fairness result (D27)");

        // What IS asserted: losslessness under a sustained stalled head.
        c8_inj = sb_n - c8_inj_before;
        c8_ej  = total_ejected - c8_ej_before;
        $display("         injected %0d, ejected %0d during C8b", c8_inj, c8_ej);
        ck(c8_inj > 100,  "C8b injected too little to exercise HOL blocking");
        ck(c8_ej == c8_inj,
           "C8b flits were LOST or held under sustained head-of-line blocking");
        ck(sb_miss == c8_miss_before,
           "C8b an ejected flit matched no scoreboard entry -- duplication or misdelivery under HOL");
        if (c8_ej == c8_inj && sb_miss == c8_miss_before)
            $display("  [ok]   C8b %0d flits delivered exactly once under sustained HOL blocking",
                     c8_ej);


        //--------------------------------------------------------------
        // CASE 9 -- reset during traffic (Phase 5, Stage C2).
        //
        // RESET POLICY, DECIDED EXPLICITLY RATHER THAN HAND-WAVED:
        //   A flit accepted into the network but not yet ejected when reset
        //   asserts IS LOST, by design and without exception. fifo.v clears
        //   wr_ptr, rd_ptr and count on reset but deliberately does not clear
        //   `mem`; the stale payload is unreachable because the pointers and
        //   count say the FIFO is empty. Reset means discard, not drain. There
        //   is no flush protocol and none is in scope.
        //
        // So the scoreboard cannot simply be carried across the reset -- every
        // outstanding entry would be scored as a loss and the end-of-test
        // assertion would fail on correct behaviour. It is purged instead, and
        // the count purged is REPORTED, because a purge of zero would mean the
        // test proved nothing.
        //
        // What is asserted, in order of what would actually be a bug:
        //   1. the network really was loaded when reset hit (precondition --
        //      resetting an idle mesh is a vacuous test)
        //   2. every one of the 20 input FIFOs reads empty after reset
        //   3. every one of the 20 priority_ptr values is back to 0
        //   4. no output port is still asserting valid
        //   5. NO ZOMBIE FLITS: nothing injected before the reset is ever
        //      ejected after it. This is the one that would catch `mem` being
        //      re-read through a pointer that did not clear.
        //   6. the mesh works afterwards -- a full all-to-all delivers 100%
        //--------------------------------------------------------------
        $display("-- Case 9  reset during traffic");
        clear_ej; lg_count = 0;
        c9_miss_before = sb_miss;

        // Load the mesh hard: every endpoint injecting every cycle, mixed
        // destinations, so FIFOs at every router carry traffic.
        for (a = 0; a < 4; a = a + 1) seq_of[a] = 0;
        @(negedge clk);
        for (a = 0; a < 4; a = a + 1) begin
            dst_of[a]      = (a + 1) % 4;
            ep_in_valid[a] = 1'b1;
            ep_flit[a]     = mk_flit(ep_x(dst_of[a]), ep_y(dst_of[a]),
                                     a[7:0], 16'd6000 + seq_of[a][15:0]);
        end
        for (n = 0; n < 40; n = n + 1) begin
            acc = ep_in_valid & ep_in_ready;
            for (a = 0; a < 4; a = a + 1)
                if (acc[a]) sb_push(dst_of[a], ep_flit[a]);
            @(negedge clk);
            for (a = 0; a < 4; a = a + 1) begin
                if (acc[a]) begin
                    seq_of[a] = seq_of[a] + 1;
                    dst_of[a] = (dst_of[a] + 1) % 4;
                end
                ep_flit[a] = mk_flit(ep_x(dst_of[a]), ep_y(dst_of[a]), a[7:0],
                                     16'd6000 + seq_of[a][15:0]);
            end
        end

        // Precondition: the mesh must actually be carrying flits right now,
        // otherwise everything below is vacuously true.
        c9_loaded = 0;
        c9_occ    = 0;
        for (n = 0; n < 20; n = n + 1) begin
            if (!fifo_mt[n])  c9_loaded = c9_loaded + 1;
            c9_occ = c9_occ + fifo_cnt[n];
        end
        c9_outstanding = sb_outstanding;
        $display("         at reset: %0d of 20 FIFOs non-empty, %0d flits resident, %0d outstanding in scoreboard",
                 c9_loaded, c9_occ, c9_outstanding);
        ck(c9_loaded >= 4,
           "C9 PRECONDITION: the mesh was not loaded when reset asserted -- test is vacuous");
        ck(c9_outstanding > 0,
           "C9 PRECONDITION: nothing was in flight when reset asserted -- test is vacuous");

        // Assert reset mid-injection, with valid still high on every endpoint.
        // Injection is NOT stopped first: reset landing on an active handshake
        // is the case worth testing.
        c9_inj_at_reset = sb_n;
        rst_n = 1'b0;
        repeat (3) @(negedge clk);

        // Everything outstanding is now gone by policy. Purge it.
        c9_purged = 0;
        for (n = 0; n < sb_n; n = n + 1) begin
            if (sb_used[n]) begin
                sb_used[n]     = 1'b0;
                sb_outstanding = sb_outstanding - 1;
                c9_purged      = c9_purged + 1;
                sb_discarded   = sb_discarded + 1;
            end
        end
        $display("         purged %0d in-flight flits from the scoreboard (lost by reset policy)",
                 c9_purged);
        ck(c9_purged > 0, "C9 reset discarded nothing -- test is vacuous");

        // State checks, taken while reset is still asserted.
        c9_bad_fifo = 0;
        c9_bad_ptr  = 0;
        for (n = 0; n < 20; n = n + 1) begin
            if (fifo_cnt[n] !== 8'd0 || fifo_mt[n] !== 1'b1) begin
                c9_bad_fifo = c9_bad_fifo + 1;
                if (c9_bad_fifo <= 5)
                    $display("  [FAIL] C9 r%0d input %0d FIFO not empty after reset: count=%0d empty=%b",
                             n/5, n%5, fifo_cnt[n], fifo_mt[n]);
            end
            if (arb_ptr[n] !== 3'd0) begin
                c9_bad_ptr = c9_bad_ptr + 1;
                if (c9_bad_ptr <= 5)
                    $display("  [FAIL] C9 r%0d output %0d priority_ptr = %0d after reset, expected 0",
                             n/5, n%5, arb_ptr[n]);
            end
        end
        ck(c9_bad_fifo == 0, "C9 a FIFO was not empty after reset");
        ck(c9_bad_ptr  == 0, "C9 a priority_ptr did not return to 0 after reset");
        ck(dut.r0_out_valid === 5'b0 && dut.r1_out_valid === 5'b0
           && dut.r2_out_valid === 5'b0 && dut.r3_out_valid === 5'b0,
           "C9 an output port still asserted valid during reset");
        if (c9_bad_fifo == 0 && c9_bad_ptr == 0)
            $display("  [ok]   C9 all 20 FIFOs empty and all 20 priority_ptr = 0 after reset");

        // Release. Injection is held off for one cycle so the first post-reset
        // flit is scored cleanly.
        ep_in_valid = 4'b0000;
        rst_n = 1'b1;
        @(negedge clk);
        c9_ej_at_release = total_ejected;

        // Zombie check: give the mesh time to cough up anything that survived.
        repeat (60) @(negedge clk);
        ck(total_ejected == c9_ej_at_release,
           "C9 ZOMBIE FLIT: something injected before reset was ejected after it");
        ck(sb_miss == c9_miss_before,
           "C9 an unexpected flit appeared after reset -- stale FIFO contents were re-read");
        if (total_ejected == c9_ej_at_release)
            $display("  [ok]   C9 no pre-reset flit survived the reset (zombie check clean)");

        // The mesh must work afterwards. Full all-to-all, every pair.
        clear_ej; lg_count = 0;
        c9_post_before = total_ejected;
        seq_ctr = 7000;
        for (src_ep = 0; src_ep < 4; src_ep = src_ep + 1) begin
            for (dst_ep = 0; dst_ep < 4; dst_ep = dst_ep + 1) begin
                send(src_ep, dst_ep, seq_ctr[15:0]);
                seq_ctr = seq_ctr + 1;
            end
        end
        repeat (200) @(negedge clk);
        c9_post = total_ejected - c9_post_before;
        $display("         post-reset all-to-all: %0d of 16 delivered", c9_post);
        ck(c9_post == 16, "C9 the mesh did not work correctly after reset");
        if (c9_post == 16)
            $display("  [ok]   C9 mesh fully functional after reset, all 16 pairs delivered");


        //--------------------------------------------------------------
        // Latency (Phase 5, Stage C4)
        //
        // Binned by hop count, because a 2-hop flit legitimately costs more
        // than a 1-hop one and one global bound would hide a regression in
        // the cheap case. Two different things are checked:
        //
        //   * UNLOADED latency, measured during cases 1 and 2 where a single
        //     flit traverses an otherwise idle mesh. This is the structural
        //     per-hop cost and it is asserted tightly. A pipeline stage added
        //     anywhere in the datapath moves it and fails here -- which is the
        //     regression the suite could previously not see at all, since
        //     every other assertion waits a generous number of cycles and then
        //     checks only what arrived.
        //
        //   * LOADED latency, across the whole run including saturation. This
        //     is queueing delay and is reported, not tightly bounded: it is a
        //     function of offered load, and a bound on it would be a bound on
        //     the traffic pattern rather than on the design. It is still
        //     sanity-checked against a generous ceiling so an unbounded stall
        //     cannot pass silently.
        //--------------------------------------------------------------
        $display("-- Latency");
        for (n = 0; n < 3; n = n + 1) begin
            if (lat_n[n] > 0)
                $display("         %0d-hop: n=%0d  min=%0d  mean=%0d  max=%0d cycles",
                         n, lat_n[n], lat_min[n], lat_sum[n]/lat_n[n], lat_max[n]);
        end
        $display("         unloaded worst (cases 1-2, idle mesh): %0d cycles", lat_unloaded_max);

        ck(lat_unloaded_max > 0,
           "C4 no unloaded latency was measured -- instrumentation is dead");
        ck(lat_unloaded_max <= LAT_UNLOADED_BOUND,
           "C4 UNLOADED LATENCY REGRESSION: a flit on an idle mesh took longer than the structural bound");
        ck(lat_max[1] <= LAT_LOADED_BOUND,
           "C4 a 1-hop flit exceeded the loaded latency ceiling");
        ck(lat_max[2] <= LAT_LOADED_BOUND,
           "C4 a 2-hop flit exceeded the loaded latency ceiling");
        if (lat_unloaded_max <= LAT_UNLOADED_BOUND)
            $display("  [ok]   C4 unloaded latency %0d cycles, bound %0d (per-hop cost unchanged)",
                     lat_unloaded_max, LAT_UNLOADED_BOUND);

        //--------------------------------------------------------------
        // Per-arbiter monitor results (Phase 5, Stage C)
        //--------------------------------------------------------------
        $display("-- Per-arbiter bounded-wait monitor (all %0d mesh arbiters)", ARB_N);
        ck(arb_wait_viol == 0,
           "BOUNDED-WAIT VIOLATION: an arbiter passed over a visible request more than 5 grants");
        ck(arb_ptr_viol == 0,
           "INVARIANT 3: a priority_ptr advanced on a cycle with no completed grant");
        $display("         worst wait observed at any arbiter: %0d grants (bound %0d)",
                 arb_worst_any, ARB_BOUND);

        // D27's paper enumeration, measured. Caps by output class:
        // LOCAL 3, cardinal toward 2, cardinal away 1, tied-off 0.
        $display("-- Max simultaneous requesters per arbiter, measured vs D27 prediction");
        c8_cnt = 0;
        for (ca = 0; ca < ARB_N; ca = ca + 1) begin
            cr      = ca / 5;
            ck_port = ca % 5;
            ck(arb_maxreq[ca] <= req_cap(cr, ck_port),
               "D27 CONTRADICTED: an arbiter saw more simultaneous requesters than the enumeration allows");
            ck(arb_maxreq[ca] <= 3,
               "D27 CONTRADICTED: an arbiter saw more than three simultaneous requesters");
            if (arb_maxreq[ca] > req_cap(cr, ck_port)) begin
                c8_cnt = c8_cnt + 1;
                $display("  [FAIL] r%0d output %0d: measured max %0d requesters, D27 predicts at most %0d",
                         cr, ck_port, arb_maxreq[ca], req_cap(cr, ck_port));
            end
        end
        $display("         r0 LOCAL/NORTH/EAST/SOUTH/WEST max req = %0d %0d %0d %0d %0d  (pred 3 2 1 0 0)",
                 arb_maxreq[0], arb_maxreq[1], arb_maxreq[2], arb_maxreq[3], arb_maxreq[4]);
        $display("         r1 LOCAL/NORTH/EAST/SOUTH/WEST max req = %0d %0d %0d %0d %0d  (pred 3 2 0 0 1)",
                 arb_maxreq[5], arb_maxreq[6], arb_maxreq[7], arb_maxreq[8], arb_maxreq[9]);
        $display("         r2 LOCAL/NORTH/EAST/SOUTH/WEST max req = %0d %0d %0d %0d %0d  (pred 3 0 1 2 0)",
                 arb_maxreq[10], arb_maxreq[11], arb_maxreq[12], arb_maxreq[13], arb_maxreq[14]);
        $display("         r3 LOCAL/NORTH/EAST/SOUTH/WEST max req = %0d %0d %0d %0d %0d  (pred 3 0 0 2 1)",
                 arb_maxreq[15], arb_maxreq[16], arb_maxreq[17], arb_maxreq[18], arb_maxreq[19]);
        if (c8_cnt == 0)
            $display("  [ok]   all %0d arbiters within the D27 enumerated caps; none above 3 requesters",
                     ARB_N);


        //--------------------------------------------------------------
        // End-of-test assertions
        //--------------------------------------------------------------
        $display("-- End of test");
        ck(sb_outstanding == 0, "scoreboard not empty -- flits were LOST");
        ck(sb_miss == 0,        "an ejected flit matched no scoreboard entry -- misdelivery, duplication or corruption");
        // Flits discarded by a reset are a policy-defined loss (C9), not a bug.
        // They are subtracted explicitly so the conservation check stays exact
        // rather than being weakened to an inequality.
        ck(total_ejected + sb_discarded == sb_n,
           "total ejected + deliberately discarded != total injected");
        ck(tie_valid_viol == 0, "a tied-off output asserted valid");
        ck(tie_req_viol   == 0, "an input requested a tied-off output");
        $display("         injected %0d, ejected %0d, discarded-by-reset %0d, outstanding %0d, unmatched %0d",
                 sb_n, total_ejected, sb_discarded, sb_outstanding, sb_miss);

        $display("---------------------------------------------");
        if (errors == 0) $display("tb_mesh: PASS  (%0d checks, 0 errors)", checks);
        else             $display("tb_mesh: FAIL  (%0d checks, %0d errors)", checks, errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #5000000;
        $display("tb_mesh: FAIL -- simulation timeout");
        $finish;
    end

endmodule
`default_nettype wire
