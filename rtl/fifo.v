`default_nettype none
//----------------------------------------------------------------------------
// fifo.v -- parameterized synchronous FIFO, one per router input port.
//
// Exposes the head flit combinationally on rd_data alongside `empty`, so route
// computation and arbitration can see the flit in the same cycle it becomes
// visible.
//
// `full` is a pure function of the registered occupancy count. It deliberately
// does NOT bypass a simultaneous pop: making `full` depend on rd_en would put
// the upstream `ready` on a combinational path through arbitration and grant,
// which is the combinational loop CLAUDE.md warns about. The cost is one slot
// of throughput at the full mark; the benefit is that no such loop can exist.
//----------------------------------------------------------------------------
module fifo #(
    parameter WIDTH = 34,
    parameter DEPTH = 4
) (
    input  wire             clk,
    input  wire             rst_n,

    // write side (upstream)
    input  wire             wr_en,
    input  wire [WIDTH-1:0] wr_data,
    output wire             full,

    // read side (downstream)
    input  wire             rd_en,
    output wire [WIDTH-1:0] rd_data,
    output wire             empty
);

    localparam PTR_W = (DEPTH < 2) ? 1 : $clog2(DEPTH);
    localparam CNT_W = $clog2(DEPTH + 1);

    localparam [CNT_W-1:0] CNT_DEPTH = DEPTH;
    localparam [CNT_W-1:0] CNT_ZERO  = {CNT_W{1'b0}};
    localparam [PTR_W-1:0] PTR_LAST  = DEPTH - 1;
    localparam [PTR_W-1:0] PTR_ZERO  = {PTR_W{1'b0}};

    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [PTR_W-1:0] wr_ptr;
    reg [PTR_W-1:0] rd_ptr;
    reg [CNT_W-1:0] count;

    wire do_wr = wr_en & ~full;
    wire do_rd = rd_en & ~empty;

    assign full    = (count == CNT_DEPTH);
    assign empty   = (count == CNT_ZERO);
    assign rd_data = mem[rd_ptr];

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= PTR_ZERO;
            rd_ptr <= PTR_ZERO;
            count  <= CNT_ZERO;
        end else begin
            if (do_wr) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr <= (wr_ptr == PTR_LAST) ? PTR_ZERO : wr_ptr + 1'b1;
            end
            if (do_rd) begin
                rd_ptr <= (rd_ptr == PTR_LAST) ? PTR_ZERO : rd_ptr + 1'b1;
            end
            case ({do_wr, do_rd})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

endmodule
`default_nettype wire
