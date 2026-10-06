//=============================================================================
// systolic_array.sv - NxN weight-stationary systolic MAC array
//
// A grid of mac_pe cells; each holds one weight. Activations enter the WEST
// edge and march east; partial sums enter as zero at the NORTH edge and
// accumulate south. The SOUTH edge results are captured in an output register.
//
// WEIGHT-STATIONARY: each PE loads its weight once and reuses it across many
// activation vectors - the standard inference dataflow.
//
// Interconnect uses PACKED vectors (act flattened to N*(N+1) 8-bit lanes, psum
// to (N+1)*N 32-bit lanes) rather than unpacked 2-D arrays. Packed buses read
// back reliably across generate/port boundaries and are the conventional way to
// wire a regular array datapath for synthesis. Index helper below.
//=============================================================================
module systolic_array #(
  parameter int N = 4
)(
  input  logic                clk,
  input  logic                rst,
  input  logic                en,
  input  logic                load_w,
  input  logic signed [7:0]   w_load [N*N],
  input  logic signed [7:0]   act_west [N],
  output logic [N*32-1:0]     psum_south      // N results, packed 32b each
);

  // Packed interconnect.
  //   AH: activation stops, N rows x (N+1) columns, 8 bits each
  //   PV: partial-sum stops, (N+1) rows x N columns, 32 bits each
  // Element (row,col) occupies one lane; helper functions index the lanes.
  logic [N*(N+1)*8-1:0]  AH;
  logic [(N+1)*N*32-1:0] PV;

  // lane accessors (bit offset of the LSB of a given stop)
  function automatic int ah_off(input int row, input int col);
    return (row*(N+1) + col) * 8;
  endfunction
  function automatic int pv_off(input int row, input int col);
    return (row*N + col) * 32;
  endfunction

  genvar r, c;
  generate
    // west-edge activations into column 0
    for (r = 0; r < N; r++) begin : g_west
      assign AH[ah_off(r,0) +: 8] = act_west[r];
    end
    // north-edge zeros into row 0
    for (c = 0; c < N; c++) begin : g_north
      assign PV[pv_off(0,c) +: 32] = 32'sd0;
    end

    for (r = 0; r < N; r++) begin : g_row
      for (c = 0; c < N; c++) begin : g_col
        logic signed [7:0]  aout_pe;
        logic signed [31:0] pout_pe;

        mac_pe u_pe (
          .clk     (clk),
          .rst     (rst),
          .en      (en),
          .load_w  (load_w),
          .w_in    (w_load[r*N + c]),
          .act_in  (AH[ah_off(r,c)   +: 8]),
          .psum_in (PV[pv_off(r,c)   +: 32]),
          .act_out (aout_pe),
          .psum_out(pout_pe)
        );

        // drive this cell's east/south stops from the PE outputs
        assign AH[ah_off(r, c+1) +: 8]  = aout_pe;
        assign PV[pv_off(r+1, c) +: 32] = pout_pe;
      end
    end
  endgenerate

  // Output-capture register: latch the south-edge (row N) partial sums.
  // Real accelerators register datapath outputs for clean boundary timing.
  logic signed [31:0] south_q [N];
  genvar oc;
  generate
    for (oc = 0; oc < N; oc++) begin : g_cap
      always_ff @(posedge clk) begin
        if (rst)     south_q[oc] <= 32'sd0;
        else if (en) south_q[oc] <= $signed(PV[pv_off(N,oc) +: 32]);
      end
      assign psum_south[oc*32 +: 32] = south_q[oc];
    end
  endgenerate

endmodule
