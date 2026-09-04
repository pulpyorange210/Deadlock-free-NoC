`default_nettype none
//----------------------------------------------------------------------------
// crossbar.v -- per-output mux driven by the per-output grants.
//
// Arbitration is per-output and one-hot, so two outputs may be driven from two
// different inputs in the same cycle: the crossbar is non-blocking across
// outputs.
//
// Flattened buses keep the ports Verilog-2001 legal.
//   in_flits [i*FLIT_W +: FLIT_W]  head flit of input i
//   grants   [k*N      +: N     ]  one-hot grant vector of output k
//   out_flits[k*FLIT_W +: FLIT_W]  flit driven onto output k
//----------------------------------------------------------------------------
module crossbar #(
    parameter N      = 5,
    parameter FLIT_W = 34
) (
    input  wire [N*FLIT_W-1:0] in_flits,
    input  wire [N*N-1:0]      grants,
    output reg  [N*FLIT_W-1:0] out_flits,
    output reg  [N-1:0]        out_valid
);

    integer k, i;

    always @* begin
        out_flits = {(N*FLIT_W){1'b0}};              // default: assigned on every path
        out_valid = {N{1'b0}};
        for (k = 0; k < N; k = k + 1) begin
            for (i = 0; i < N; i = i + 1) begin
                if (grants[k*N + i]) begin
                    out_flits[k*FLIT_W +: FLIT_W] = in_flits[i*FLIT_W +: FLIT_W];
                    out_valid[k] = 1'b1;
                end
            end
        end
    end

endmodule
`default_nettype wire
