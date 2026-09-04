`timescale 1ns/1ps
`default_nettype none
//----------------------------------------------------------------------------
// tb/tb_router.v -- self-checking single-router testbench (Phase 1).
//
// Pass/fail is decided entirely by the assertions below. Waveforms are for
// debugging only and are never the basis for a pass claim.
//
// The whole assertion suite lives in `tb_router_core`, which is parameterized
// on coordinate width and on the coordinates of its two DUTs. `tb_router`
// instantiates it twice and runs the configurations in sequence:
//
//   CONFIG 1  X_W=Y_W=1, 2x2 coordinates, DUT A (0,0), DUT B (1,1)
//             A can only reach EAST/NORTH/LOCAL and B only WEST/SOUTH/LOCAL,
//             so each router has three live output arbiters and the other two
//             constant-fold away. Two DUTs are needed to cover four directions.
//
//   CONFIG 2  X_W=Y_W=2, 4x4 coordinates, both DUTs at (1,1)
//             Every direction is reachable from (1,1), so all five output
//             arbiters are live and exercised in a single router. CONFIG 1
//             never puts five arbiters in play at once.
//
// Each DUT is exercised through a drive/observe layer muxed by `sel`. A passive
// monitor records every output transfer (port, flit, cycle); each directed test
// clears the log, injects, waits, and then asserts on the whole log -- so
// correct destination, payload integrity, no loss and no duplication are all
// checked at once, including on ports the test was not looking at.
//----------------------------------------------------------------------------

module tb_router_core #(
    parameter        X_W        = 1,
    parameter        Y_W        = 1,
    parameter        DATA_W     = 32,
    parameter        FIFO_DEPTH = 4,
    parameter        AX         = 0,   // DUT A: covers +X (EAST), +Y (NORTH), LOCAL
    parameter        AY         = 0,
    parameter        BX         = 1,   // DUT B: covers -X (WEST), -Y (SOUTH), LOCAL
    parameter        BY         = 1,
    // Set when DUT A can reach all four cardinals and Local, i.e. when its
    // coordinates are interior. Enables T9, which needs every direction at once.
    parameter        ALL_DIRS   = 0,
    parameter [31:0] TAG        = "cfg?"
) (
    input  wire        go,
    output reg         done,
    output reg [31:0]  errors,
    output reg [31:0]  checks
);

    localparam FLIT_W = X_W + Y_W + DATA_W;

    localparam P_LOCAL = 0;
    localparam P_NORTH = 1;
    localparam P_EAST  = 2;
    localparam P_SOUTH = 3;
    localparam P_WEST  = 4;

    localparam [7:0] MAGIC = 8'h5A;

    // Own coordinates, and the neighbour coordinates each directed test aims at.
    localparam [X_W-1:0] AX_V      = AX;
    localparam [Y_W-1:0] AY_V      = AY;
    localparam [X_W-1:0] BX_V      = BX;
    localparam [Y_W-1:0] BY_V      = BY;
    localparam [X_W-1:0] A_EAST_X  = AX + 1;
    localparam [Y_W-1:0] A_NORTH_Y = AY + 1;
    localparam [X_W-1:0] B_WEST_X  = BX - 1;
    localparam [Y_W-1:0] B_SOUTH_Y = BY - 1;
    // Only meaningful when ALL_DIRS: at AX=0 or AY=0 these wrap.
    localparam [X_W-1:0] A_WEST_X  = AX - 1;
    localparam [Y_W-1:0] A_SOUTH_Y = AY - 1;

    initial begin
        done   = 1'b0;
        errors = 32'd0;
        checks = 32'd0;
    end

    //------------------------------------------------------------------
    // Clock, cycle counter
    //------------------------------------------------------------------
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    integer cyc = 0;
    // Non-blocking on purpose: the ejection monitor below reads `cyc` on the
    // same posedge. With a blocking update the two always blocks race and the
    // recorded cycle number becomes simulator-dependent.
    always @(posedge clk) cyc <= cyc + 1;

    //------------------------------------------------------------------
    // Drive / observe layer, muxed onto one of the two DUTs by sel
    //------------------------------------------------------------------
    reg               sel = 1'b0;   // 0 = DUT A, 1 = DUT B
    reg  [FLIT_W-1:0] d_flit [0:4];
    reg  [4:0]        d_valid     = 5'b0;
    reg  [4:0]        d_out_ready = 5'b11111;
    wire [4:0]        d_ready;
    wire [4:0]        d_out_valid;
    wire [FLIT_W-1:0] d_out [0:4];

    wire [5*FLIT_W-1:0] d_flit_flat;
    wire [5*FLIT_W-1:0] a_out_flat;
    wire [5*FLIT_W-1:0] b_out_flat;
    wire [4:0] a_ready;
    wire [4:0] b_ready;
    wire [4:0] a_out_valid;
    wire [4:0] b_out_valid;

    genvar gi;
    generate
        for (gi = 0; gi < 5; gi = gi + 1) begin : g_pack
            assign d_flit_flat[gi*FLIT_W +: FLIT_W] = d_flit[gi];
            assign d_out[gi] = sel ? b_out_flat[gi*FLIT_W +: FLIT_W]
                                   : a_out_flat[gi*FLIT_W +: FLIT_W];
        end
    endgenerate

    assign d_ready     = sel ? b_ready     : a_ready;
    assign d_out_valid = sel ? b_out_valid : a_out_valid;

    wire [4:0] a_in_valid = sel ? 5'b0 : d_valid;
    wire [4:0] b_in_valid = sel ? d_valid : 5'b0;

    router #(
        .X_W(X_W), .Y_W(Y_W), .DATA_W(DATA_W),
        .FIFO_DEPTH(FIFO_DEPTH), .MY_X(AX), .MY_Y(AY)
    ) dut_a (
        .clk(clk), .rst_n(rst_n),
        .in_flit(d_flit_flat), .in_valid(a_in_valid), .in_ready(a_ready),
        .out_flit(a_out_flat), .out_valid(a_out_valid), .out_ready(d_out_ready)
    );

    router #(
        .X_W(X_W), .Y_W(Y_W), .DATA_W(DATA_W),
        .FIFO_DEPTH(FIFO_DEPTH), .MY_X(BX), .MY_Y(BY)
    ) dut_b (
        .clk(clk), .rst_n(rst_n),
        .in_flit(d_flit_flat), .in_valid(b_in_valid), .in_ready(b_ready),
        .out_flit(b_out_flat), .out_valid(b_out_valid), .out_ready(d_out_ready)
    );

    //------------------------------------------------------------------
    // Passive ejection monitor
    //------------------------------------------------------------------
    localparam EJ_MAX = 4096;
    integer           ej_count = 0;
    integer           ej_port [0:EJ_MAX-1];
    reg [FLIT_W-1:0]  ej_flit [0:EJ_MAX-1];
    integer           ej_cyc  [0:EJ_MAX-1];

    integer mp;
    always @(posedge clk) begin
        if (rst_n) begin
            for (mp = 0; mp < 5; mp = mp + 1) begin
                if (d_out_valid[mp] && d_out_ready[mp]) begin
                    ej_port[ej_count] = mp;
                    ej_flit[ej_count] = d_out[mp];
                    ej_cyc [ej_count] = cyc;
                    ej_count = ej_count + 1;
                end
            end
        end
    end

    //------------------------------------------------------------------
    // White-box check on invariant 3.
    //
    // An arbiter's priority_ptr may change ONLY on a cycle where its output
    // actually transferred a flit -- a grant was issued AND the receiver was
    // ready. Note the "and ready": checking `|grant` alone would not catch an
    // arbiter fed unmasked requests, because it does issue a grant, just for an
    // output that cannot take the flit. Nothing moves and the rotation loses
    // its place anyway.
    //
    // This is independent of T8's bounded-wait check: T8 observes the
    // consequence (rotation becomes unfair) from outside the DUT, this observes
    // the cause (the pointer moving with nothing transferred) inside it.
    //------------------------------------------------------------------
    localparam N_ARB = 10;              // 5 output arbiters x 2 DUTs

    wire [2:0] arb_ptr [0:N_ARB-1];
    wire [4:0] arb_gnt [0:N_ARB-1];

    assign arb_ptr[0] = dut_a.g_output[0].u_arb.priority_ptr;
    assign arb_gnt[0] = dut_a.g_output[0].u_arb.grant;
    assign arb_ptr[1] = dut_a.g_output[1].u_arb.priority_ptr;
    assign arb_gnt[1] = dut_a.g_output[1].u_arb.grant;
    assign arb_ptr[2] = dut_a.g_output[2].u_arb.priority_ptr;
    assign arb_gnt[2] = dut_a.g_output[2].u_arb.grant;
    assign arb_ptr[3] = dut_a.g_output[3].u_arb.priority_ptr;
    assign arb_gnt[3] = dut_a.g_output[3].u_arb.grant;
    assign arb_ptr[4] = dut_a.g_output[4].u_arb.priority_ptr;
    assign arb_gnt[4] = dut_a.g_output[4].u_arb.grant;
    assign arb_ptr[5] = dut_b.g_output[0].u_arb.priority_ptr;
    assign arb_gnt[5] = dut_b.g_output[0].u_arb.grant;
    assign arb_ptr[6] = dut_b.g_output[1].u_arb.priority_ptr;
    assign arb_gnt[6] = dut_b.g_output[1].u_arb.grant;
    assign arb_ptr[7] = dut_b.g_output[2].u_arb.priority_ptr;
    assign arb_gnt[7] = dut_b.g_output[2].u_arb.grant;
    assign arb_ptr[8] = dut_b.g_output[3].u_arb.priority_ptr;
    assign arb_gnt[8] = dut_b.g_output[3].u_arb.grant;
    assign arb_ptr[9] = dut_b.g_output[4].u_arb.priority_ptr;
    assign arb_gnt[9] = dut_b.g_output[4].u_arb.grant;

    reg [2:0] ptr_prev      [0:N_ARB-1];
    reg       real_gnt_prev [0:N_ARB-1];
    reg       ptr_armed = 1'b0;
    integer   ptr_violations = 0;
    integer   pv;

    always @(posedge clk) begin
        if (!rst_n) begin
            ptr_armed = 1'b0;
        end else begin
            // priority_ptr is updated non-blocking, so the value read here is
            // the one from before this edge -- exactly the one that the grant
            // captured on the previous edge was allowed to change.
            if (ptr_armed) begin
                for (pv = 0; pv < N_ARB; pv = pv + 1) begin
                    if (!real_gnt_prev[pv] && (arb_ptr[pv] !== ptr_prev[pv])) begin
                        ptr_violations = ptr_violations + 1;
                        if (ptr_violations <= 5)
                            $display("  [FAIL] [%0s] cyc=%0d arbiter %0d: priority_ptr moved %0d -> %0d with no completed grant",
                                     TAG, cyc, pv, ptr_prev[pv], arb_ptr[pv]);
                    end
                end
            end
            for (pv = 0; pv < N_ARB; pv = pv + 1) begin
                ptr_prev[pv]      = arb_ptr[pv];
                real_gnt_prev[pv] = (|arb_gnt[pv]) & d_out_ready[pv % 5];
            end
            ptr_armed = 1'b1;
        end
    end

    //------------------------------------------------------------------
    // Helpers
    //------------------------------------------------------------------
    function [FLIT_W-1:0] mk_flit;
        input [X_W-1:0]  dx;
        input [Y_W-1:0]  dy;
        input [7:0]      src;
        input [15:0]     seq;
        begin
            mk_flit = {dx, dy, src, seq, MAGIC};
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

    function [7:0] flit_magic;
        input [FLIT_W-1:0] f;
        begin flit_magic = f[7:0]; end
    endfunction

    reg [1023:0] tag_s = "-";

    task ck;
        input          cond;
        input [1023:0] msg;
        begin
            checks = checks + 1;
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("  [FAIL] [%0s] cyc=%0d [%0s] %0s", TAG, cyc, tag_s, msg);
            end
        end
    endtask

    task do_reset;
        integer r;
        begin
            rst_n       = 1'b0;
            d_valid     = 5'b0;
            d_out_ready = 5'b11111;
            for (r = 0; r < 5; r = r + 1) d_flit[r] = {FLIT_W{1'b0}};
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            @(negedge clk);
        end
    endtask

    // Inject exactly one flit on port, waiting for the handshake.
    task inject_one;
        input integer      port;
        input [FLIT_W-1:0] f;
        begin
            @(negedge clk);
            d_valid[port] = 1'b1;
            d_flit[port]  = f;
            while (d_ready[port] !== 1'b1) @(negedge clk);
            @(negedge clk);          // the intervening posedge consumed it
            d_valid[port] = 1'b0;
        end
    endtask

    task clear_log;
        begin
            ej_count = 0;
        end
    endtask

    // Assert the log holds exactly one ejection, on exp_port, equal to exp_flit.
    task expect_single;
        input integer      exp_port;
        input [FLIT_W-1:0] exp_flit;
        input [1023:0]     name;
        begin
            checks = checks + 1;
            if (ej_count != 1) begin
                errors = errors + 1;
                $display("  [FAIL] [%0s] %0s: expected exactly 1 ejection, saw %0d",
                         TAG, name, ej_count);
            end else if (ej_port[0] != exp_port) begin
                errors = errors + 1;
                $display("  [FAIL] [%0s] %0s: ejected on port %0d, expected %0d",
                         TAG, name, ej_port[0], exp_port);
            end else if (ej_flit[0] !== exp_flit) begin
                errors = errors + 1;
                $display("  [FAIL] [%0s] %0s: payload corrupt, got %h expected %h",
                         TAG, name, ej_flit[0], exp_flit);
            end else begin
                $display("  [ok]   [%0s] %0s", TAG, name);
            end
        end
    endtask

    //------------------------------------------------------------------
    // Load-test state
    //------------------------------------------------------------------
    integer p;
    integer n;
    integer accepted;
    reg [4:0] acc;
    integer seq_of [0:4];
    integer since  [0:4];   // grants observed since this input was last served
    integer worst  [0:4];   // worst such run, per input
    integer served [0:4];   // grants this input won under load
    integer stream_ej;      // ejections that happened WHILE load was sustained
    integer max_wait;
    integer wrong_port;
    integer corrupt;
    integer injected;
    integer seen;
    integer same_cycle;
    integer exp_src [0:4];
    reg [FLIT_W-1:0] f;

    //------------------------------------------------------------------
    // Sustained-load driver: all five inputs offer a flit destined for this
    // router every cycle, so all five contend for the LOCAL output. With
    // toggle_ready set, the LOCAL receiver goes not-ready 3 cycles in every 7,
    // so requests are masked and no grant may be issued during those cycles.
    //------------------------------------------------------------------
    task run_stream;
        input integer cycles;
        input         toggle_ready;
        integer a;
        integer c;
        begin
            for (a = 0; a < 5; a = a + 1) seq_of[a] = 0;
            @(negedge clk);
            for (a = 0; a < 5; a = a + 1) begin
                d_valid[a] = 1'b1;
                d_flit[a]  = mk_flit(AX_V, AY_V, a[7:0], seq_of[a][15:0]);
            end
            for (c = 0; c < cycles; c = c + 1) begin
                if (toggle_ready) d_out_ready[P_LOCAL] = ((c % 7) < 4);
                acc = d_valid & d_ready;          // what the coming posedge takes
                @(negedge clk);
                for (a = 0; a < 5; a = a + 1) begin
                    if (acc[a]) seq_of[a] = seq_of[a] + 1;
                    d_flit[a] = mk_flit(AX_V, AY_V, a[7:0], seq_of[a][15:0]);
                end
            end
            d_valid = 5'b0;
            d_out_ready[P_LOCAL] = 1'b1;
            injected = 0;
            for (a = 0; a < 5; a = a + 1) injected = injected + seq_of[a];
        end
    endtask

    //------------------------------------------------------------------
    // Bounded-service analysis over the ejections that happened while load was
    // sustained. The drain afterwards is excluded on purpose: a starved input
    // does get served once its rivals go idle, and counting that would hide the
    // starvation this test exists to catch.
    //
    // The metric is "grants observed since this input was last served", which is
    // what §3.5 actually bounds. Measuring the distance between an input's own
    // consecutive services instead would be blind to total starvation, because
    // an input that is never served has no consecutive pair.
    //------------------------------------------------------------------
    task analyze_load;
        input integer  upto;
        input [1023:0] name;
        integer a;
        integer b;
        integer ss;
        begin
            wrong_port = 0;
            corrupt    = 0;
            max_wait   = 0;
            for (a = 0; a < 5; a = a + 1) begin
                since[a]  = 0;
                worst[a]  = 0;
                served[a] = 0;
            end
            for (a = 0; a < upto; a = a + 1) begin
                if (ej_port[a] != P_LOCAL)             wrong_port = wrong_port + 1;
                if (flit_magic(ej_flit[a]) !== MAGIC)  corrupt    = corrupt + 1;
                ss = flit_src(ej_flit[a]);
                served[ss] = served[ss] + 1;
                for (b = 0; b < 5; b = b + 1) begin
                    if (b == ss) begin
                        since[b] = 0;
                    end else begin
                        since[b] = since[b] + 1;
                        if (a >= 10 && since[b] > worst[b]) worst[b] = since[b];
                    end
                end
            end
            for (a = 0; a < 5; a = a + 1)
                if (worst[a] > max_wait) max_wait = worst[a];

            $display("  [%0s] %0s", TAG, name);
            $display("         %0d grants under load; per-input service %0d %0d %0d %0d %0d; worst wait %0d grants (bound 5)",
                     upto, served[0], served[1], served[2], served[3], served[4],
                     max_wait);

            ck(wrong_port == 0, "a flit destined for this router left on a non-LOCAL port");
            ck(corrupt == 0,    "payload corrupted under sustained load");
            ck(upto > 20,       "almost nothing was delivered under load");
            ck(max_wait <= 5,   "an input waited more than 5 grants -- STARVATION");
            for (a = 0; a < 5; a = a + 1)
                ck(served[a] >= upto/10,
                   "an input got far below its fair share -- STARVATION");
        end
    endtask

    //------------------------------------------------------------------
    // The suite
    //------------------------------------------------------------------
    task run_all;
        begin
            do_reset;

            //----------------------------------------------------------
            // T1/T2: XY routing out of DUT A
            //----------------------------------------------------------
            $display("-- [%0s] T1  routing from DUT A", TAG);
            sel = 1'b0;

            clear_log;
            f = mk_flit(A_EAST_X, AY_V, 8'd0, 16'd1);
            inject_one(P_LOCAL, f);
            repeat (6) @(negedge clk);
            expect_single(P_EAST, f, "T1a Local -> EAST");

            clear_log;
            f = mk_flit(AX_V, A_NORTH_Y, 8'd0, 16'd2);
            inject_one(P_LOCAL, f);
            repeat (6) @(negedge clk);
            expect_single(P_NORTH, f, "T1b Local -> NORTH");

            clear_log;
            f = mk_flit(AX_V, AY_V, 8'd0, 16'd3);
            inject_one(P_LOCAL, f);
            repeat (6) @(negedge clk);
            expect_single(P_LOCAL, f, "T1c Local -> LOCAL eject at destination");

            $display("-- [%0s] T2  XY ordering: X resolves before Y", TAG);
            clear_log;
            f = mk_flit(A_EAST_X, A_NORTH_Y, 8'd0, 16'd4);
            inject_one(P_LOCAL, f);
            repeat (6) @(negedge clk);
            // Must leave EAST. Leaving NORTH would be a Y-first route and would
            // permit the Y->X turn that makes the dependency graph cyclic.
            expect_single(P_EAST, f, "T2a dest +X+Y goes EAST, not NORTH");

            //----------------------------------------------------------
            // T3: the other two directions, from DUT B
            //----------------------------------------------------------
            $display("-- [%0s] T3  routing from DUT B", TAG);
            sel = 1'b1;
            @(negedge clk);

            clear_log;
            f = mk_flit(B_WEST_X, BY_V, 8'd0, 16'd5);
            inject_one(P_LOCAL, f);
            repeat (6) @(negedge clk);
            expect_single(P_WEST, f, "T3a Local -> WEST");

            clear_log;
            f = mk_flit(BX_V, B_SOUTH_Y, 8'd0, 16'd6);
            inject_one(P_LOCAL, f);
            repeat (6) @(negedge clk);
            expect_single(P_SOUTH, f, "T3b Local -> SOUTH");

            clear_log;
            f = mk_flit(B_WEST_X, B_SOUTH_Y, 8'd0, 16'd7);
            inject_one(P_LOCAL, f);
            repeat (6) @(negedge clk);
            expect_single(P_WEST, f, "T3c dest -X-Y goes WEST, not SOUTH");

            // A flit arriving on a cardinal input routes by the same rule.
            clear_log;
            f = mk_flit(BX_V, BY_V, 8'd1, 16'd8);
            inject_one(P_WEST, f);
            repeat (6) @(negedge clk);
            expect_single(P_LOCAL, f, "T3d WEST input -> LOCAL eject at destination");

            //----------------------------------------------------------
            // T4: backpressure holds a flit, it does not drop it
            //----------------------------------------------------------
            $display("-- [%0s] T4  backpressure", TAG);
            sel = 1'b0;
            @(negedge clk);
            clear_log;
            tag_s = "T4";
            d_out_ready[P_EAST] = 1'b0;
            f = mk_flit(A_EAST_X, AY_V, 8'd0, 16'd10);
            inject_one(P_LOCAL, f);
            repeat (12) @(negedge clk);
            ck(ej_count == 0, "a flit moved while EAST ready was low");
            if (ej_count == 0)
                $display("  [ok]   [%0s] T4a no ejection while EAST ready low", TAG);
            d_out_ready[P_EAST] = 1'b1;
            repeat (6) @(negedge clk);
            expect_single(P_EAST, f, "T4b flit ejects intact after ready reasserted");

            //----------------------------------------------------------
            // T5: FIFO fills, backpressures upstream, loses nothing
            //----------------------------------------------------------
            $display("-- [%0s] T5  FIFO full / no loss", TAG);
            tag_s = "T5";
            clear_log;
            d_out_ready[P_EAST] = 1'b0;
            accepted = 0;
            @(negedge clk);
            d_valid[P_LOCAL] = 1'b1;
            for (n = 0; n < FIFO_DEPTH + 4; n = n + 1) begin
                d_flit[P_LOCAL] = mk_flit(A_EAST_X, AY_V, 8'd0,
                                          16'd100 + accepted[15:0]);
                if (d_ready[P_LOCAL] === 1'b1) accepted = accepted + 1;
                @(negedge clk);
            end
            d_valid[P_LOCAL] = 1'b0;
            ck(accepted == FIFO_DEPTH,
               "upstream ready did not deassert after exactly FIFO_DEPTH flits");
            if (accepted == FIFO_DEPTH)
                $display("  [ok]   [%0s] T5a in_ready deasserted after exactly %0d flits",
                         TAG, FIFO_DEPTH);
            ck(d_ready[P_LOCAL] === 1'b0, "in_ready should still be low while full");

            d_out_ready[P_EAST] = 1'b1;
            repeat (FIFO_DEPTH + 8) @(negedge clk);
            ck(ej_count == FIFO_DEPTH, "not every buffered flit came out");
            if (ej_count == FIFO_DEPTH)
                $display("  [ok]   [%0s] T5c all %0d buffered flits ejected, none lost",
                         TAG, ej_count);
            for (n = 0; n < ej_count; n = n + 1) begin
                ck(ej_port[n] == P_EAST,                "buffered flit on wrong port");
                ck(flit_magic(ej_flit[n]) == MAGIC,     "payload corrupted in FIFO");
                ck(flit_seq(ej_flit[n]) == 16'd100 + n, "FIFO did not preserve order");
            end
            ck(d_ready[P_LOCAL] === 1'b1, "in_ready did not recover after drain");

            //----------------------------------------------------------
            // T6: output contention -- two inputs, one output, one winner a cycle
            //----------------------------------------------------------
            $display("-- [%0s] T6  output contention", TAG);
            tag_s = "T6";
            clear_log;
            @(negedge clk);
            d_valid[P_NORTH] = 1'b1;
            d_valid[P_WEST]  = 1'b1;
            d_flit[P_NORTH]  = mk_flit(A_EAST_X, AY_V, 8'd1, 16'd200);
            d_flit[P_WEST]   = mk_flit(A_EAST_X, AY_V, 8'd4, 16'd201);
            @(negedge clk);
            d_valid[P_NORTH] = 1'b0;
            d_valid[P_WEST]  = 1'b0;
            repeat (8) @(negedge clk);
            ck(ej_count == 2, "both contending flits should be served exactly once");
            if (ej_count == 2) begin
                ck(ej_cyc[0] != ej_cyc[1],
                   "two flits left the same output in the same cycle");
                ck(ej_port[0] == P_EAST && ej_port[1] == P_EAST,
                   "contending flits left on the wrong port");
                ck(flit_src(ej_flit[0]) != flit_src(ej_flit[1]),
                   "the same input was served twice");
                $display("  [ok]   [%0s] T6 both inputs served, cycles %0d and %0d",
                         TAG, ej_cyc[0], ej_cyc[1]);
            end

            //----------------------------------------------------------
            // T7: sustained load -- the round-robin / starvation test.
            //----------------------------------------------------------
            $display("-- [%0s] T7  sustained load / starvation bound", TAG);
            tag_s = "T7";
            clear_log;
            run_stream(200, 1'b0);
            stream_ej = ej_count;            // freeze the window before the drain
            repeat (40) @(negedge clk);
            analyze_load(stream_ej, "T7 all five inputs -> LOCAL, receiver always ready");
            ck(ej_count == injected,
               "flits ejected != flits injected -- loss or duplication");
            $display("         injected %0d, ejected %0d after drain",
                     injected, ej_count);
            ck(stream_ej > 150, "throughput collapsed under sustained load");

            //----------------------------------------------------------
            // T8: sustained load WITH backpressure. The contended receiver goes
            // not-ready 3 cycles in 7. Requests for it are masked during those
            // cycles, so no grant may be issued and the priority pointer must
            // not move. An arbiter that advanced its pointer on a masked request
            // would still look fine in T7; this is the test that sees it.
            //----------------------------------------------------------
            $display("-- [%0s] T8  sustained load with intermittent backpressure", TAG);
            tag_s = "T8";
            clear_log;
            run_stream(300, 1'b1);
            stream_ej = ej_count;
            repeat (40) @(negedge clk);
            analyze_load(stream_ej, "T8 all five inputs -> LOCAL, receiver ready 4 cycles in 7");
            ck(ej_count == injected,
               "flits ejected != flits injected -- loss or duplication");
            $display("         injected %0d, ejected %0d after drain",
                     injected, ej_count);

            //----------------------------------------------------------
            // T9: all five output arbiters granting in the SAME cycle.
            // Five inputs, each holding a flit for a different output, so every
            // arbiter has exactly one requester and all five must grant at once.
            // This is what proves the five arbiters are behaviourally live
            // together and that the crossbar is non-blocking across outputs.
            // It cannot run at 1-bit coordinates, where a corner router has two
            // unreachable directions.
            //----------------------------------------------------------
            if (ALL_DIRS) begin
                $display("-- [%0s] T9  all five outputs granted in one cycle", TAG);
                tag_s = "T9";
                sel = 1'b0;
                @(negedge clk);
                clear_log;
                d_flit[P_LOCAL] = mk_flit(A_EAST_X, AY_V,      8'd0, 16'd300); // -> EAST
                d_flit[P_NORTH] = mk_flit(AX_V,     A_NORTH_Y, 8'd1, 16'd301); // -> NORTH
                d_flit[P_EAST]  = mk_flit(A_WEST_X, AY_V,      8'd2, 16'd302); // -> WEST
                d_flit[P_SOUTH] = mk_flit(AX_V,     A_SOUTH_Y, 8'd3, 16'd303); // -> SOUTH
                d_flit[P_WEST]  = mk_flit(AX_V,     AY_V,      8'd4, 16'd304); // -> LOCAL
                exp_src[P_EAST]  = 0;
                exp_src[P_NORTH] = 1;
                exp_src[P_WEST]  = 2;
                exp_src[P_SOUTH] = 3;
                exp_src[P_LOCAL] = 4;
                d_valid = 5'b11111;
                @(negedge clk);
                d_valid = 5'b0;
                repeat (8) @(negedge clk);

                ck(ej_count == 5, "expected all five flits to eject");
                if (ej_count == 5) begin
                    seen       = 0;
                    same_cycle = 1;
                    for (n = 0; n < 5; n = n + 1) begin
                        if (ej_cyc[n] != ej_cyc[0]) same_cycle = 0;
                        seen = seen | (1 << ej_port[n]);
                        ck(flit_magic(ej_flit[n]) == MAGIC,
                           "payload corrupted crossing the crossbar");
                        ck(flit_src(ej_flit[n]) == exp_src[ej_port[n]],
                           "a flit ejected on the wrong output port");
                    end
                    ck(same_cycle == 1,
                       "the five outputs did not all fire in the same cycle");
                    ck(seen == 31,
                       "the five flits did not cover all five output ports");
                    $display("  [ok]   [%0s] T9 five outputs granted together in cycle %0d, port coverage %b",
                             TAG, ej_cyc[0], seen[4:0]);
                end
            end

            //----------------------------------------------------------
            // T10: invariant 3, checked white-box across the whole run.
            //----------------------------------------------------------
            $display("-- [%0s] T10 priority_ptr moves only on a completed grant", TAG);
            tag_s = "T10";
            ck(ptr_violations == 0,
               "priority_ptr moved on a cycle with no completed grant -- invariant 3");
            if (ptr_violations == 0)
                $display("  [ok]   [%0s] T10 no pointer movement without a completed grant, all %0d arbiters",
                         TAG, N_ARB);
            else
                $display("         %0d violations across %0d arbiters",
                         ptr_violations, N_ARB);
        end
    endtask

    always @(posedge go) begin
        run_all;
        done = 1'b1;
    end

endmodule


//----------------------------------------------------------------------------
// Top: run the suite once per configuration and combine the results.
//----------------------------------------------------------------------------
module tb_router;

    reg  go1 = 1'b0;
    reg  go2 = 1'b0;
    wire done1;
    wire done2;
    wire [31:0] err1;
    wire [31:0] chk1;
    wire [31:0] err2;
    wire [31:0] chk2;

    // CONFIG 1 -- 1-bit coordinates, 2x2 space. Three live arbiters per DUT.
    tb_router_core #(
        .X_W(1), .Y_W(1), .DATA_W(32), .FIFO_DEPTH(4),
        .AX(0), .AY(0), .BX(1), .BY(1), .TAG("1bit")
    ) cfg1 (
        .go(go1), .done(done1), .errors(err1), .checks(chk1)
    );

    // CONFIG 2 -- 2-bit coordinates, 4x4 space, DUT at (1,1). All five output
    // arbiters are reachable, so all five are live at the same time.
    tb_router_core #(
        .X_W(2), .Y_W(2), .DATA_W(32), .FIFO_DEPTH(4),
        .AX(1), .AY(1), .BX(1), .BY(1), .ALL_DIRS(1), .TAG("2bit")
    ) cfg2 (
        .go(go2), .done(done2), .errors(err2), .checks(chk2)
    );

    initial begin
        $dumpfile("tb_router.vcd");
        $dumpvars(0, tb_router);

        $display("=== tb_router: Phase 1 single-router verification ===");
        $display("");
        $display("### CONFIG 1  X_W=Y_W=1, 2x2 coords, DUT A (0,0), DUT B (1,1)");
        $display("###   Three live output arbiters per DUT; the unreachable two");
        $display("###   constant-fold away, so five are never live at once.");
        #1;
        go1 = 1'b1;
        wait (done1);
        $display("### CONFIG 1 result: %0d checks, %0d errors", chk1, err1);
        $display("");

        $display("### CONFIG 2  X_W=Y_W=2, 4x4 coords, both DUTs at (1,1)");
        $display("###   Every direction reachable: all five output arbiters live");
        $display("###   and exercised in one router.");
        go2 = 1'b1;
        wait (done2);
        $display("### CONFIG 2 result: %0d checks, %0d errors", chk2, err2);
        $display("");

        $display("---------------------------------------------");
        $display("  CONFIG 1 (1-bit coords): %0d checks, %0d errors", chk1, err1);
        $display("  CONFIG 2 (2-bit coords): %0d checks, %0d errors", chk2, err2);
        if ((err1 + err2) == 0)
            $display("tb_router: PASS  (%0d checks, 0 errors)", chk1 + chk2);
        else
            $display("tb_router: FAIL  (%0d checks, %0d errors)",
                     chk1 + chk2, err1 + err2);
        $display("---------------------------------------------");
        $finish;
    end

    // Watchdog
    initial begin
        #1000000;
        $display("tb_router: FAIL -- simulation timeout");
        $finish;
    end

endmodule
`default_nettype wire
