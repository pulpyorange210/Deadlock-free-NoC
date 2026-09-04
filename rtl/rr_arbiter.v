`default_nettype none
//----------------------------------------------------------------------------
// rr_arbiter.v -- round-robin arbiter, N requests -> one-hot grant.
//
// One instance per OUTPUT port. Mechanism is rotate -> leading-one select ->
// rotate back: the request vector is rotated so the current highest-priority
// input lands at bit 0, the lowest set bit is isolated, and the result is
// rotated back. Smaller than an N-way case and it is what the spec assumes.
//
// On granting input i the pointer advances to i+1 (mod N), making the winner
// lowest priority. That bounds worst-case wait at N grants.
//
// CONTRACT: `req` must already be masked by the downstream ready for this
// output. The arbiter never sees a request for an output that cannot accept a
// flit, so every grant it issues is a grant that actually happens -- which is
// what makes advancing the pointer on |grant correct. Do not instantiate this
// with unmasked requests.
//----------------------------------------------------------------------------
module rr_arbiter #(
    parameter N = 5
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [N-1:0] req,
    output wire [N-1:0] grant
);

    localparam PTR_W = (N < 2) ? 1 : $clog2(N);

    localparam [N-1:0]     ONE_N    = 1;
    localparam [PTR_W-1:0] PTR_ZERO = {PTR_W{1'b0}};
    localparam [PTR_W-1:0] PTR_LAST = N - 1;

    reg [PTR_W-1:0] priority_ptr;

    // Rotate right by priority_ptr: rot_req[j] = req[(priority_ptr + j) % N],
    // so rot_req[0] is the currently highest-priority input.
    wire [2*N-1:0] req_dbl  = {req, req};
    wire [N-1:0]   rot_req  = req_dbl[priority_ptr +: N];

    // Leading-one (lowest index wins) on the rotated vector.
    wire [N-1:0]   rot_grant = rot_req & (~rot_req + ONE_N);

    // Rotate back into absolute port order.
    wire [2*N-1:0] grant_dbl = {{N{1'b0}}, rot_grant} << priority_ptr;
    assign grant = grant_dbl[N-1:0] | grant_dbl[2*N-1:N];

    // Index of the granted input, from the one-hot grant.
    integer k;
    reg [PTR_W-1:0] gnt_idx;
    always @* begin
        gnt_idx = PTR_ZERO;                          // default: no latch
        for (k = 0; k < N; k = k + 1)
            if (grant[k]) gnt_idx = k[PTR_W-1:0];
    end

    wire [PTR_W-1:0] next_ptr = (gnt_idx == PTR_LAST) ? PTR_ZERO
                                                      : gnt_idx + 1'b1;

    always @(posedge clk) begin
        if (!rst_n)      priority_ptr <= PTR_ZERO;
        else if (|grant) priority_ptr <= next_ptr;   // ONLY on a real grant
    end

endmodule
`default_nettype wire
