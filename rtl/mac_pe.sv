//=============================================================================
// mac_pe.sv - Multiply-Accumulate Processing Element (one cell)
//
// The fundamental unit of the systolic array. In a weight-stationary design,
// each PE holds ONE weight and, every cycle, receives an activation from its
// west neighbour and a partial sum from its north neighbour. It computes
//
//     psum_out = psum_in + (weight * act_in)
//
// and passes the activation east and the new partial sum south. Data marches
// through the array in a wave - that "systolic" flow is what lets an NxN array
// do N-wide dot products every cycle without any global control.
//
// FIXED-POINT FORMAT
//   weight : signed 8-bit   (Q0.7-ish, set by the Python quantizer)
//   act    : signed 8-bit
//   product: signed 16-bit  (8x8)
//   psum   : signed 32-bit  - wide enough that a long dot product (up to 784
//            terms in the MLP's first layer) cannot overflow. 16-bit
//            accumulators WOULD overflow here; picking 32 is a real design
//            decision, not a default.
//
// The register on act_out and psum_out is essential: it is what makes the
// array systolic (one hop per cycle) rather than a giant combinational adder
// tree that would never close timing.
//=============================================================================
module mac_pe (
  input  logic               clk,
  input  logic               rst,
  input  logic               en,          // advance the systolic wave
  input  logic               load_w,      // latch a new stationary weight

  input  logic signed [7:0]  w_in,        // weight to load (when load_w)
  input  logic signed [7:0]  act_in,      // activation from the west
  input  logic signed [31:0] psum_in,     // partial sum from the north

  output logic signed [7:0]  act_out,     // activation to the east
  output logic signed [31:0] psum_out     // partial sum to the south
);

  logic signed [7:0]  weight_q;           // the stationary weight

  // ---- load the stationary weight -----------------------------------
  always_ff @(posedge clk) begin
    if (rst)          weight_q <= 8'sd0;
    else if (load_w)  weight_q <= w_in;
  end

  // ---- multiply-accumulate and march the data through --------------
  logic signed [15:0] product;
  assign product = weight_q * act_in;      // 8 x 8 -> 16, signed

  always_ff @(posedge clk) begin
    if (rst) begin
      act_out  <= 8'sd0;
      psum_out <= 32'sd0;
    end else if (en) begin
      act_out  <= act_in;                            // pass activation east
      psum_out <= psum_in + {{16{product[15]}}, product}; // accumulate, sign-extended
    end
  end

endmodule
