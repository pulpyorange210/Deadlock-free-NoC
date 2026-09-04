`default_nettype none
//----------------------------------------------------------------------------
// route_compute.v -- XY dimension-order routing. Combinational.
//
// Takes the head flit of one input FIFO plus this router's own coordinates and
// produces the one-hot request naming the output port the flit wants.
//
// Port encoding (used identically in every module in this design):
//   [0] LOCAL   [1] NORTH   [2] EAST   [3] SOUTH   [4] WEST
//
// Flit layout, MSB first:  { dest_x[X_W], dest_y[Y_W], payload[DATA_W] }
//
// X displacement resolves completely before any Y movement. That ordering is
// what forbids all four Y->X turns and leaves the channel dependency graph
// acyclic, so deadlock is structurally impossible. Do not add a shortcut or
// congestion-aware branch here.
//----------------------------------------------------------------------------
module route_compute #(
    parameter X_W    = 1,
    parameter Y_W    = 1,
    parameter DATA_W = 32,
    parameter MY_X   = 0,
    parameter MY_Y   = 0
) (
    input  wire [X_W+Y_W+DATA_W-1:0] flit,
    input  wire                      valid,   // head flit is real (FIFO not empty)
    output reg  [4:0]                req      // one-hot, 5'b0 when !valid
);

    localparam FLIT_W = X_W + Y_W + DATA_W;

    localparam P_LOCAL = 0;
    localparam P_NORTH = 1;
    localparam P_EAST  = 2;
    localparam P_SOUTH = 3;
    localparam P_WEST  = 4;

    // Sized copies of the coordinate parameters so every comparison is an
    // unsigned compare of two equal-width vectors.
    localparam [X_W-1:0] MY_X_V = MY_X;
    localparam [Y_W-1:0] MY_Y_V = MY_Y;

    wire [X_W-1:0] dest_x = flit[FLIT_W-1 -: X_W];
    wire [Y_W-1:0] dest_y = flit[DATA_W +: Y_W];

    always @* begin
        req = 5'b0;                                  // default: assigned on every path
        if (valid) begin
            if      (dest_x > MY_X_V) req[P_EAST]  = 1'b1;
            else if (dest_x < MY_X_V) req[P_WEST]  = 1'b1;
            else if (dest_y > MY_Y_V) req[P_NORTH] = 1'b1;
            else if (dest_y < MY_Y_V) req[P_SOUTH] = 1'b1;
            else                      req[P_LOCAL] = 1'b1;
        end
    end

endmodule
`default_nettype wire
