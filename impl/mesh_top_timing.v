`default_nettype none
//----------------------------------------------------------------------------
// impl/mesh_top_timing.v -- SYNTHESIS-ONLY timing harness. Not part of the
// deliverable design, which is why it lives outside rtl/ and is never pulled
// in by the `rtl/*.v` glob.
//
// mesh_top exposes all four endpoint interfaces as top-level ports. Timed
// against I/O, the worst path is a pad-to-flop or flop-to-pad path whose delay
// is dominated by the package and the I/O buffer, not by the interconnect --
// a number that says nothing about the router logic this project is about.
//
// This wrapper registers every endpoint input and every endpoint output, so
// every constrained path in the design is flop-to-flop inside the mesh. The
// mesh itself is untouched: the registers are added outside mesh_top, so no
// internal path is lengthened, shortened or re-optimized by their presence.
//
// The added registers change handshake timing by a cycle in each direction, so
// this wrapper is NOT functionally equivalent to mesh_top and is never
// simulated. It exists only to give implementation an honest boundary.
//----------------------------------------------------------------------------
module mesh_top_timing #(
    parameter X_W        = 1,
    parameter Y_W        = 1,
    parameter DATA_W     = 32,
    parameter FIFO_DEPTH = 4
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire [4*(X_W+Y_W+DATA_W)-1:0] ep_in_flit,
    input  wire [3:0]                    ep_in_valid,
    output wire [3:0]                    ep_in_ready,
    output wire [4*(X_W+Y_W+DATA_W)-1:0] ep_out_flit,
    output wire [3:0]                    ep_out_valid,
    input  wire [3:0]                    ep_out_ready
);

    localparam FLIT_W = X_W + Y_W + DATA_W;

    // Inputs registered on the way in
    reg [4*FLIT_W-1:0] in_flit_q;
    reg [3:0]          in_valid_q;
    reg [3:0]          out_ready_q;
    reg                rst_n_q;

    // Outputs registered on the way out
    reg [4*FLIT_W-1:0] out_flit_q;
    reg [3:0]          out_valid_q;
    reg [3:0]          in_ready_q;

    wire [4*FLIT_W-1:0] w_out_flit;
    wire [3:0]          w_out_valid;
    wire [3:0]          w_in_ready;

    always @(posedge clk) begin
        in_flit_q   <= ep_in_flit;
        in_valid_q  <= ep_in_valid;
        out_ready_q <= ep_out_ready;
        rst_n_q     <= rst_n;
        out_flit_q  <= w_out_flit;
        out_valid_q <= w_out_valid;
        in_ready_q  <= w_in_ready;
    end

    assign ep_out_flit  = out_flit_q;
    assign ep_out_valid = out_valid_q;
    assign ep_in_ready  = in_ready_q;

    mesh_top #(
        .X_W(X_W), .Y_W(Y_W), .DATA_W(DATA_W), .FIFO_DEPTH(FIFO_DEPTH)
    ) u_mesh (
        .clk          (clk),
        .rst_n        (rst_n_q),
        .ep_in_flit   (in_flit_q),
        .ep_in_valid  (in_valid_q),
        .ep_in_ready  (w_in_ready),
        .ep_out_flit  (w_out_flit),
        .ep_out_valid (w_out_valid),
        .ep_out_ready (out_ready_q)
    );

endmodule
`default_nettype wire
