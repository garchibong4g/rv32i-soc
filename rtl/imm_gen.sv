//=============================================================================
// imm_gen.sv - RV32I immediate generator
//
// RISC-V scrambles immediate bits across the instruction word on purpose:
// every format keeps the SIGN BIT at instr[31] and keeps as many other bits
// as possible in the same positions. That means the sign-extension wiring and
// most immediate bits are shared across formats, so the mux below is mostly
// wires rather than logic. It looks chaotic on paper and is cheap in gates.
//
// B and J immediates encode a multiple of 2, so bit 0 is an implicit zero.
//=============================================================================
module imm_gen
  import rv32i_pkg::*;
(
  input  logic [31:0] instr,
  input  imm_sel_e    sel,
  output logic [31:0] imm
);

  always_comb begin
    unique case (sel)
      IMM_I: imm = {{20{instr[31]}}, instr[31:20]};
      IMM_S: imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
      IMM_B: imm = {{19{instr[31]}}, instr[31], instr[7],
                    instr[30:25], instr[11:8], 1'b0};
      IMM_U: imm = {instr[31:12], 12'h000};
      IMM_J: imm = {{11{instr[31]}}, instr[31], instr[19:12],
                    instr[20], instr[30:21], 1'b0};
      default: imm = 32'h0;
    endcase
  end

endmodule
