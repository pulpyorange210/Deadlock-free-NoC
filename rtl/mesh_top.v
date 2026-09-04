`default_nettype none
//----------------------------------------------------------------------------
// mesh_top.v -- 2x2 mesh of routers.
//
// Complete 2x2 mesh: four routers, four bidirectional links, edges tied off.
//
// Router numbering (fixed for the whole build):
//   r0 = (0,0)   r1 = (1,0)   r2 = (0,1)   r3 = (1,1)
//
//   (0,1) r2 ──────── r3 (1,1)
//           │           │
//           │           │
//   (0,0) r0 ──────── r1 (1,0)
//
// Port encoding on every 5-wide vector and every flattened flit bus:
//   [0] LOCAL   [1] NORTH   [2] EAST   [3] SOUTH   [4] WEST
//
// Endpoint buses are indexed by router number: ep_*[n] belongs to r<n>.
//
//----------------------------------------------------------------------------
// EDGE TIE-OFF RULE
//
// An off-mesh output has its `ready` tied LOW, never high.
//
// Ready low masks every request for that output before the arbiter sees it, so
// no grant is issued, the FIFO is never popped, and the flit stays where it is.
// A routing bug that aims a flit off the mesh therefore shows up as a stalled
// flit and backpressure -- observable, and the flit still exists.
//
// Ready high would do the opposite: the arbiter would grant, the crossbar would
// drive the flit onto a wire that goes nowhere, and the FIFO would pop. The
// flit would be silently destroyed, breaking the lossless invariant in the one
// way that leaves no evidence behind.
//
// An off-mesh input is held invalid (`valid` low, flit zero).
//----------------------------------------------------------------------------
// LINK WIRING TABLE
//
// A link is one direction. Each row is: the source router's output port drives
// the destination router's input port, and the destination's `in_ready` for
// that port drives the source's `out_ready` for its port. Every link therefore
// carries flit+valid forwards and ready backwards.
//
//   src router      src port  ->  dst router      dst port
//   -----------------------------------------------------------
//   r0 (0,0)        EAST      ->  r1 (1,0)        WEST
//   r1 (1,0)        WEST      ->  r0 (0,0)        EAST
//   r0 (0,0)        NORTH     ->  r2 (0,1)        SOUTH
//   r2 (0,1)        SOUTH     ->  r0 (0,0)        NORTH
//   r1 (1,0)        NORTH     ->  r3 (1,1)        SOUTH
//   r3 (1,1)        SOUTH     ->  r1 (1,0)        NORTH
//   r2 (0,1)        EAST      ->  r3 (1,1)        WEST
//   r3 (1,1)        WEST      ->  r2 (0,1)        EAST
//
// Off-mesh ports, tied off per the rule above. In a 2x2 mesh every router uses
// exactly two of its four cardinals plus Local:
//   r0 (0,0): SOUTH, WEST        r1 (1,0): EAST,  SOUTH
//   r2 (0,1): NORTH, WEST        r3 (1,1): NORTH, EAST
//----------------------------------------------------------------------------
module mesh_top #(
    parameter X_W        = 1,
    parameter Y_W        = 1,
    parameter DATA_W     = 32,
    parameter FIFO_DEPTH = 4
) (
    input  wire                          clk,
    input  wire                          rst_n,

    // Endpoint injection, one per router
    input  wire [4*(X_W+Y_W+DATA_W)-1:0] ep_in_flit,
    input  wire [3:0]                    ep_in_valid,
    output wire [3:0]                    ep_in_ready,

    // Endpoint ejection, one per router
    output wire [4*(X_W+Y_W+DATA_W)-1:0] ep_out_flit,
    output wire [3:0]                    ep_out_valid,
    input  wire [3:0]                    ep_out_ready
);

    localparam FLIT_W = X_W + Y_W + DATA_W;

    localparam P_LOCAL = 0;
    localparam P_NORTH = 1;
    localparam P_EAST  = 2;
    localparam P_SOUTH = 3;
    localparam P_WEST  = 4;

    //------------------------------------------------------------------
    // r0 = (0,0)
    //------------------------------------------------------------------
    wire [5*FLIT_W-1:0] r0_in_flit;
    wire [4:0]          r0_in_valid;
    wire [4:0]          r0_in_ready;
    wire [5*FLIT_W-1:0] r0_out_flit;
    wire [4:0]          r0_out_valid;
    wire [4:0]          r0_out_ready;

    router #(
        .X_W(X_W), .Y_W(Y_W), .DATA_W(DATA_W), .FIFO_DEPTH(FIFO_DEPTH),
        .MY_X(0), .MY_Y(0)
    ) u_r0 (
        .clk(clk), .rst_n(rst_n),
        .in_flit(r0_in_flit), .in_valid(r0_in_valid), .in_ready(r0_in_ready),
        .out_flit(r0_out_flit), .out_valid(r0_out_valid), .out_ready(r0_out_ready)
    );

    // r0 Local <-> endpoint 0
    assign r0_in_flit[P_LOCAL*FLIT_W +: FLIT_W] = ep_in_flit[0*FLIT_W +: FLIT_W];
    assign r0_in_valid[P_LOCAL]                 = ep_in_valid[0];
    assign ep_in_ready[0]                       = r0_in_ready[P_LOCAL];
    assign ep_out_flit[0*FLIT_W +: FLIT_W]      = r0_out_flit[P_LOCAL*FLIT_W +: FLIT_W];
    assign ep_out_valid[0]                      = r0_out_valid[P_LOCAL];
    assign r0_out_ready[P_LOCAL]                = ep_out_ready[0];

    // r0 off-mesh cardinals
    assign r0_in_flit[P_SOUTH*FLIT_W +: FLIT_W] = {FLIT_W{1'b0}};
    assign r0_in_valid[P_SOUTH]                 = 1'b0;
    assign r0_out_ready[P_SOUTH]                = 1'b0;

    assign r0_in_flit[P_WEST*FLIT_W +: FLIT_W]  = {FLIT_W{1'b0}};
    assign r0_in_valid[P_WEST]                  = 1'b0;
    assign r0_out_ready[P_WEST]                 = 1'b0;

    //------------------------------------------------------------------
    // r1 = (1,0)
    //------------------------------------------------------------------
    wire [5*FLIT_W-1:0] r1_in_flit;
    wire [4:0]          r1_in_valid;
    wire [4:0]          r1_in_ready;
    wire [5*FLIT_W-1:0] r1_out_flit;
    wire [4:0]          r1_out_valid;
    wire [4:0]          r1_out_ready;

    router #(
        .X_W(X_W), .Y_W(Y_W), .DATA_W(DATA_W), .FIFO_DEPTH(FIFO_DEPTH),
        .MY_X(1), .MY_Y(0)
    ) u_r1 (
        .clk(clk), .rst_n(rst_n),
        .in_flit(r1_in_flit), .in_valid(r1_in_valid), .in_ready(r1_in_ready),
        .out_flit(r1_out_flit), .out_valid(r1_out_valid), .out_ready(r1_out_ready)
    );

    // r1 Local <-> endpoint 1
    assign r1_in_flit[P_LOCAL*FLIT_W +: FLIT_W] = ep_in_flit[1*FLIT_W +: FLIT_W];
    assign r1_in_valid[P_LOCAL]                 = ep_in_valid[1];
    assign ep_in_ready[1]                       = r1_in_ready[P_LOCAL];
    assign ep_out_flit[1*FLIT_W +: FLIT_W]      = r1_out_flit[P_LOCAL*FLIT_W +: FLIT_W];
    assign ep_out_valid[1]                      = r1_out_valid[P_LOCAL];
    assign r1_out_ready[P_LOCAL]                = ep_out_ready[1];

    // r1 off-mesh cardinals
    assign r1_in_flit[P_EAST*FLIT_W +: FLIT_W]  = {FLIT_W{1'b0}};
    assign r1_in_valid[P_EAST]                  = 1'b0;
    assign r1_out_ready[P_EAST]                 = 1'b0;

    assign r1_in_flit[P_SOUTH*FLIT_W +: FLIT_W] = {FLIT_W{1'b0}};
    assign r1_in_valid[P_SOUTH]                 = 1'b0;
    assign r1_out_ready[P_SOUTH]                = 1'b0;

    //------------------------------------------------------------------
    // r2 = (0,1)
    //------------------------------------------------------------------
    wire [5*FLIT_W-1:0] r2_in_flit;
    wire [4:0]          r2_in_valid;
    wire [4:0]          r2_in_ready;
    wire [5*FLIT_W-1:0] r2_out_flit;
    wire [4:0]          r2_out_valid;
    wire [4:0]          r2_out_ready;

    router #(
        .X_W(X_W), .Y_W(Y_W), .DATA_W(DATA_W), .FIFO_DEPTH(FIFO_DEPTH),
        .MY_X(0), .MY_Y(1)
    ) u_r2 (
        .clk(clk), .rst_n(rst_n),
        .in_flit(r2_in_flit), .in_valid(r2_in_valid), .in_ready(r2_in_ready),
        .out_flit(r2_out_flit), .out_valid(r2_out_valid), .out_ready(r2_out_ready)
    );

    // r2 Local <-> endpoint 2
    assign r2_in_flit[P_LOCAL*FLIT_W +: FLIT_W] = ep_in_flit[2*FLIT_W +: FLIT_W];
    assign r2_in_valid[P_LOCAL]                 = ep_in_valid[2];
    assign ep_in_ready[2]                       = r2_in_ready[P_LOCAL];
    assign ep_out_flit[2*FLIT_W +: FLIT_W]      = r2_out_flit[P_LOCAL*FLIT_W +: FLIT_W];
    assign ep_out_valid[2]                      = r2_out_valid[P_LOCAL];
    assign r2_out_ready[P_LOCAL]                = ep_out_ready[2];

    // r2 off-mesh cardinals
    assign r2_in_flit[P_NORTH*FLIT_W +: FLIT_W] = {FLIT_W{1'b0}};
    assign r2_in_valid[P_NORTH]                 = 1'b0;
    assign r2_out_ready[P_NORTH]                = 1'b0;

    assign r2_in_flit[P_WEST*FLIT_W +: FLIT_W]  = {FLIT_W{1'b0}};
    assign r2_in_valid[P_WEST]                  = 1'b0;
    assign r2_out_ready[P_WEST]                 = 1'b0;

    //------------------------------------------------------------------
    // r3 = (1,1)
    //------------------------------------------------------------------
    wire [5*FLIT_W-1:0] r3_in_flit;
    wire [4:0]          r3_in_valid;
    wire [4:0]          r3_in_ready;
    wire [5*FLIT_W-1:0] r3_out_flit;
    wire [4:0]          r3_out_valid;
    wire [4:0]          r3_out_ready;

    router #(
        .X_W(X_W), .Y_W(Y_W), .DATA_W(DATA_W), .FIFO_DEPTH(FIFO_DEPTH),
        .MY_X(1), .MY_Y(1)
    ) u_r3 (
        .clk(clk), .rst_n(rst_n),
        .in_flit(r3_in_flit), .in_valid(r3_in_valid), .in_ready(r3_in_ready),
        .out_flit(r3_out_flit), .out_valid(r3_out_valid), .out_ready(r3_out_ready)
    );

    // r3 Local <-> endpoint 3
    assign r3_in_flit[P_LOCAL*FLIT_W +: FLIT_W] = ep_in_flit[3*FLIT_W +: FLIT_W];
    assign r3_in_valid[P_LOCAL]                 = ep_in_valid[3];
    assign ep_in_ready[3]                       = r3_in_ready[P_LOCAL];
    assign ep_out_flit[3*FLIT_W +: FLIT_W]      = r3_out_flit[P_LOCAL*FLIT_W +: FLIT_W];
    assign ep_out_valid[3]                      = r3_out_valid[P_LOCAL];
    assign r3_out_ready[P_LOCAL]                = ep_out_ready[3];

    // r3 off-mesh cardinals
    assign r3_in_flit[P_NORTH*FLIT_W +: FLIT_W] = {FLIT_W{1'b0}};
    assign r3_in_valid[P_NORTH]                 = 1'b0;
    assign r3_out_ready[P_NORTH]                = 1'b0;

    assign r3_in_flit[P_EAST*FLIT_W +: FLIT_W]  = {FLIT_W{1'b0}};
    assign r3_in_valid[P_EAST]                  = 1'b0;
    assign r3_out_ready[P_EAST]                 = 1'b0;

    //------------------------------------------------------------------
    // LINKS -- one assign trio per row of the wiring table above.
    //------------------------------------------------------------------
    // r0 EAST -> r1 WEST
    assign r1_in_flit[P_WEST*FLIT_W +: FLIT_W]  = r0_out_flit[P_EAST*FLIT_W +: FLIT_W];
    assign r1_in_valid[P_WEST]                  = r0_out_valid[P_EAST];
    assign r0_out_ready[P_EAST]                 = r1_in_ready[P_WEST];

    // r1 WEST -> r0 EAST
    assign r0_in_flit[P_EAST*FLIT_W +: FLIT_W]  = r1_out_flit[P_WEST*FLIT_W +: FLIT_W];
    assign r0_in_valid[P_EAST]                  = r1_out_valid[P_WEST];
    assign r1_out_ready[P_WEST]                 = r0_in_ready[P_EAST];

    // r0 NORTH -> r2 SOUTH
    assign r2_in_flit[P_SOUTH*FLIT_W +: FLIT_W] = r0_out_flit[P_NORTH*FLIT_W +: FLIT_W];
    assign r2_in_valid[P_SOUTH]                 = r0_out_valid[P_NORTH];
    assign r0_out_ready[P_NORTH]                = r2_in_ready[P_SOUTH];

    // r2 SOUTH -> r0 NORTH
    assign r0_in_flit[P_NORTH*FLIT_W +: FLIT_W] = r2_out_flit[P_SOUTH*FLIT_W +: FLIT_W];
    assign r0_in_valid[P_NORTH]                 = r2_out_valid[P_SOUTH];
    assign r2_out_ready[P_SOUTH]                = r0_in_ready[P_NORTH];

    // r1 NORTH -> r3 SOUTH
    assign r3_in_flit[P_SOUTH*FLIT_W +: FLIT_W] = r1_out_flit[P_NORTH*FLIT_W +: FLIT_W];
    assign r3_in_valid[P_SOUTH]                 = r1_out_valid[P_NORTH];
    assign r1_out_ready[P_NORTH]                = r3_in_ready[P_SOUTH];

    // r3 SOUTH -> r1 NORTH
    assign r1_in_flit[P_NORTH*FLIT_W +: FLIT_W] = r3_out_flit[P_SOUTH*FLIT_W +: FLIT_W];
    assign r1_in_valid[P_NORTH]                 = r3_out_valid[P_SOUTH];
    assign r3_out_ready[P_SOUTH]                = r1_in_ready[P_NORTH];

    // r2 EAST -> r3 WEST
    assign r3_in_flit[P_WEST*FLIT_W +: FLIT_W]  = r2_out_flit[P_EAST*FLIT_W +: FLIT_W];
    assign r3_in_valid[P_WEST]                  = r2_out_valid[P_EAST];
    assign r2_out_ready[P_EAST]                 = r3_in_ready[P_WEST];

    // r3 WEST -> r2 EAST
    assign r2_in_flit[P_EAST*FLIT_W +: FLIT_W]  = r3_out_flit[P_WEST*FLIT_W +: FLIT_W];
    assign r2_in_valid[P_EAST]                  = r3_out_valid[P_WEST];
    assign r3_out_ready[P_WEST]                 = r2_in_ready[P_EAST];

endmodule
`default_nettype wire
