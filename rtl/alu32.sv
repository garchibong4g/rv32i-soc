//=============================================================================
// alu32.sv - 32-bit RV32I ALU, purely combinational
//
// Note SRA: SystemVerilog's >>> is only arithmetic when the left operand is
// declared signed, hence the explicit $signed() cast. Getting this wrong is a
// classic silent bug - SRA then behaves like SRL and only shows up on
// negative operands.
//
// Shift amount is the low 5 bits of B, per the RV32I spec (shifts by more
// than 31 are not defined by wrapping the operand, they simply use B[4:0]).
//=============================================================================
module alu32
  import rv32i_pkg::*;
(
  input  alu_op_e     op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] y
);

  logic [4:0] shamt;
  assign shamt = b[4:0];

  always_comb begin
    unique case (op)
      ALU_ADD:    y = a + b;
      ALU_SUB:    y = a - b;
      ALU_SLL:    y = a << shamt;
      ALU_SLT:    y = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
      ALU_SLTU:   y = (a < b)                   ? 32'd1 : 32'd0;
      ALU_XOR:    y = a ^ b;
      ALU_SRL:    y = a >> shamt;
      ALU_SRA:    y = $signed(a) >>> shamt;
      ALU_OR:     y = a | b;
      ALU_AND:    y = a & b;
      ALU_PASS_B: y = b;
      default:    y = 32'd0;
    endcase
  end

endmodule
