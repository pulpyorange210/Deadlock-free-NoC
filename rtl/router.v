`default_nettype none
//----------------------------------------------------------------------------
// router.v -- one 5-port mesh router.
//
//   5x fifo  +  5x route_compute  +  5x rr_arbiter (one per output)  +  crossbar
//
// Port encoding on every 5-wide vector and every flattened bus:
//   [0] LOCAL   [1] NORTH   [2] EAST   [3] SOUTH   [4] WEST
//
// Datapath per input:
//   in link -> [input FIFO] -> [route compute] -> [arbiter request] -> [crossbar] -> out link
//
// Backpressure: out_ready[k] masks every request for output k before the
// arbiter sees it, so a grant is only ever issued for an output that can accept
// the flit this cycle. in_ready is !full, which is a function of the FIFO's
// registered count only -- it does not depend on any grant, so the
// full -> mask -> grant -> crossbar path cannot close a combinational loop.
//----------------------------------------------------------------------------
module router #(
    parameter X_W        = 1,
    parameter Y_W        = 1,
    parameter DATA_W     = 32,
    parameter FIFO_DEPTH = 4,
    parameter MY_X       = 0,
    parameter MY_Y       = 0
) (
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire [5*(X_W+Y_W+DATA_W)-1:0] in_flit,
    input  wire [4:0]                    in_valid,
    output wire [4:0]                    in_ready,

    output wire [5*(X_W+Y_W+DATA_W)-1:0] out_flit,
    output wire [4:0]                    out_valid,
    input  wire [4:0]                    out_ready
);

    localparam FLIT_W  = X_W + Y_W + DATA_W;
    localparam N_PORTS = 5;

    wire [4:0]        fifo_full;
    wire [4:0]        fifo_empty;
    wire [4:0]        pop;
    wire [FLIT_W-1:0] head_flit_arr [0:4];
    wire [5*FLIT_W-1:0] head_flit_flat;

    wire [4:0] req         [0:4];   // req[i][k]        : input i wants output k
    wire [4:0] req_masked  [0:4];   // req_masked[k][i] : input i asks output k, k can accept
    wire [4:0] grant       [0:4];   // grant[k][i]      : output k granted to input i
    wire [N_PORTS*N_PORTS-1:0] grants_flat;

    assign in_ready = ~fifo_full;

    //------------------------------------------------------------------
    // Input side: one FIFO and one route computation per input port.
    //------------------------------------------------------------------
    genvar i, k;
    generate
        for (i = 0; i < N_PORTS; i = i + 1) begin : g_input
            fifo #(
                .WIDTH (FLIT_W),
                .DEPTH (FIFO_DEPTH)
            ) u_fifo (
                .clk     (clk),
                .rst_n   (rst_n),
                .wr_en   (in_valid[i]),
                .wr_data (in_flit[i*FLIT_W +: FLIT_W]),
                .full    (fifo_full[i]),
                .rd_en   (pop[i]),
                .rd_data (head_flit_arr[i]),
                .empty   (fifo_empty[i])
            );

            assign head_flit_flat[i*FLIT_W +: FLIT_W] = head_flit_arr[i];

            route_compute #(
                .X_W    (X_W),
                .Y_W    (Y_W),
                .DATA_W (DATA_W),
                .MY_X   (MY_X),
                .MY_Y   (MY_Y)
            ) u_rc (
                .flit  (head_flit_arr[i]),
                .valid (~fifo_empty[i]),
                .req   (req[i])
            );
        end
    endgenerate

    //------------------------------------------------------------------
    // Arbitration: one round-robin arbiter per output port, seeing requests
    // from all five inputs, already masked by that output's ready.
    //------------------------------------------------------------------
    generate
        for (k = 0; k < N_PORTS; k = k + 1) begin : g_output
            for (i = 0; i < N_PORTS; i = i + 1) begin : g_mask
                assign req_masked[k][i] = req[i][k] & out_ready[k];
            end

            rr_arbiter #(
                .N (N_PORTS)
            ) u_arb (
                .clk   (clk),
                .rst_n (rst_n),
                .req   (req_masked[k]),
                .grant (grant[k])
            );

            assign grants_flat[k*N_PORTS +: N_PORTS] = grant[k];
        end
    endgenerate

    //------------------------------------------------------------------
    // Dequeue: an input pops only when it won arbitration for its output AND
    // that output's receiver asserted ready. The ready term is redundant with
    // the request masking above; it is written out so the invariant is local to
    // this expression and survives refactoring.
    //
    // req[i] is one-hot, so at most one output's arbiter can grant input i.
    //------------------------------------------------------------------
    wire [4:0] pop_terms [0:4];
    generate
        for (i = 0; i < N_PORTS; i = i + 1) begin : g_pop
            for (k = 0; k < N_PORTS; k = k + 1) begin : g_pop_term
                assign pop_terms[i][k] = grant[k][i] & out_ready[k];
            end
            assign pop[i] = |pop_terms[i];
        end
    endgenerate

    //------------------------------------------------------------------
    // Crossbar
    //------------------------------------------------------------------
    crossbar #(
        .N      (N_PORTS),
        .FLIT_W (FLIT_W)
    ) u_xbar (
        .in_flits  (head_flit_flat),
        .grants    (grants_flat),
        .out_flits (out_flit),
        .out_valid (out_valid)
    );

endmodule
`default_nettype wire
