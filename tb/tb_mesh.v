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
    localparam DATA_W     = 32;
    localparam FIFO_DEPTH = 4;
    localparam FLIT_W     = X_W + Y_W + DATA_W;

    localparam P_LOCAL = 0;
    localparam P_NORTH = 1;
    localparam P_EAST  = 2;
    localparam P_SOUTH = 3;
    localparam P_WEST  = 4;

    localparam [7:0] MAGIC = 8'h5A;

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
    integer          total_ejected  = 0;

    task sb_push;
        input integer          dst;
        input [FLIT_W-1:0]     f;
        begin
            sb_flit[sb_n] = f;
            sb_dest[sb_n] = dst;
            sb_used[sb_n] = 1'b1;
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

    initial begin
        $dumpfile("tb_mesh.vcd");
        $dumpvars(0, tb_mesh);

        $display("=== tb_mesh: 2x2 mesh, NOC_MESH_PROJECT.md section 6 ===");
        do_reset;
        seq_ctr = 0;

        //--------------------------------------------------------------
        // CASE 1 -- single hop, adjacent routers, all four link directions
        //--------------------------------------------------------------
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
        // End-of-test assertions
        //--------------------------------------------------------------
        $display("-- End of test");
        ck(sb_outstanding == 0, "scoreboard not empty -- flits were LOST");
        ck(sb_miss == 0,        "an ejected flit matched no scoreboard entry -- misdelivery, duplication or corruption");
        ck(total_ejected == sb_n, "total ejected != total injected");
        ck(tie_valid_viol == 0, "a tied-off output asserted valid");
        ck(tie_req_viol   == 0, "an input requested a tied-off output");
        $display("         injected %0d, ejected %0d, outstanding %0d, unmatched %0d",
                 sb_n, total_ejected, sb_outstanding, sb_miss);

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
