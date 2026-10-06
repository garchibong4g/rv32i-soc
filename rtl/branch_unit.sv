//=============================================================================
// branch_unit.sv - evaluates the six RV32I branch conditions
//
// Signed vs unsigned matters: BLT/BGE compare as two's complement, BLTU/BGEU
// as plain magnitudes. Using the wrong one is invisible until an operand goes
// negative, which is exactly the kind of bug directed tests must catch.
//=============================================================================
module branch_unit
  import rv32i_pkg::*;
(
  input  logic [2:0]  funct3,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        take
);

  always_comb begin
    unique case (funct3)
      F3_BEQ:  take = (a == b);
      F3_BNE:  take = (a != b);
      F3_BLT:  take = ($signed(a) <  $signed(b));
      F3_BGE:  take = ($signed(a) >= $signed(b));
      F3_BLTU: take = (a <  b);
      F3_BGEU: take = (a >= b);
      default: take = 1'b0;
    endcase
  end

endmodule
