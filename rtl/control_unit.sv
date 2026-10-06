//=============================================================================
// control_unit.sv - RV32I instruction decoder
//
// Pure combinational. Produces the whole ctrl_t bundle for one instruction.
// Anything that does not decode sets ctrl.illegal and behaves as a NOP, so an
// unimplemented encoding fails visibly in simulation rather than silently
// corrupting state.
//=============================================================================
module control_unit
  import rv32i_pkg::*;
(
  input  logic [31:0] instr,
  output ctrl_t       ctrl
);

  logic [6:0] opcode, funct7;
  logic [2:0] funct3;

  assign opcode = instr[6:0];
  assign funct3 = instr[14:12];
  assign funct7 = instr[31:25];

  always_comb begin
    ctrl        = ctrl_t'(CTRL_NOP);
    ctrl.funct3 = funct3;

    unique case (opcode)

      // ---- U-type ------------------------------------------------
      OP_LUI: begin
        ctrl.reg_write   = 1'b1;
        ctrl.alu_src_imm = 1'b1;
        ctrl.alu_op      = ALU_PASS_B;   // rd = imm
        ctrl.imm_sel     = IMM_U;
        ctrl.wb_sel      = WB_ALU;
      end

      OP_AUIPC: begin
        ctrl.reg_write   = 1'b1;
        ctrl.alu_src_imm = 1'b1;
        ctrl.alu_src_pc  = 1'b1;         // rd = pc + imm
        ctrl.alu_op      = ALU_ADD;
        ctrl.imm_sel     = IMM_U;
        ctrl.wb_sel      = WB_ALU;
      end

      // ---- jumps -------------------------------------------------
      OP_JAL: begin
        ctrl.reg_write   = 1'b1;
        ctrl.is_jal      = 1'b1;
        ctrl.imm_sel     = IMM_J;
        ctrl.wb_sel      = WB_PC4;       // rd = pc + 4
      end

      OP_JALR: begin
        ctrl.reg_write   = 1'b1;
        ctrl.is_jalr     = 1'b1;
        ctrl.alu_src_imm = 1'b1;
        ctrl.alu_op      = ALU_ADD;      // target = rs1 + imm, lsb cleared
        ctrl.imm_sel     = IMM_I;
        ctrl.wb_sel      = WB_PC4;
      end

      // ---- conditional branches ----------------------------------
      OP_BRANCH: begin
        ctrl.is_branch   = 1'b1;
        ctrl.imm_sel     = IMM_B;
        ctrl.wb_sel      = WB_NONE;
        ctrl.illegal     = (funct3 == 3'b010) || (funct3 == 3'b011);
      end

      // ---- loads -------------------------------------------------
      OP_LOAD: begin
        ctrl.reg_write   = 1'b1;
        ctrl.mem_read    = 1'b1;
        ctrl.alu_src_imm = 1'b1;
        ctrl.alu_op      = ALU_ADD;      // address = rs1 + imm
        ctrl.imm_sel     = IMM_I;
        ctrl.wb_sel      = WB_MEM;
        ctrl.illegal     = (funct3 == 3'b011) || (funct3 == 3'b110)
                        || (funct3 == 3'b111);
      end

      // ---- stores ------------------------------------------------
      OP_STORE: begin
        ctrl.mem_write   = 1'b1;
        ctrl.alu_src_imm = 1'b1;
        ctrl.alu_op      = ALU_ADD;
        ctrl.imm_sel     = IMM_S;
        ctrl.wb_sel      = WB_NONE;
        ctrl.illegal     = (funct3 > 3'b010);
      end

      // ---- register-immediate ------------------------------------
      OP_IMM: begin
        ctrl.reg_write   = 1'b1;
        ctrl.alu_src_imm = 1'b1;
        ctrl.imm_sel     = IMM_I;
        ctrl.wb_sel      = WB_ALU;
        unique case (funct3)
          F3_ADD_SUB: ctrl.alu_op = ALU_ADD;    // ADDI - there is no SUBI
          F3_SLL:     ctrl.alu_op = ALU_SLL;
          F3_SLT:     ctrl.alu_op = ALU_SLT;
          F3_SLTU:    ctrl.alu_op = ALU_SLTU;
          F3_XOR:     ctrl.alu_op = ALU_XOR;
          F3_SRL_SRA: ctrl.alu_op = alu_op_e'(funct7[5] ? ALU_SRA : ALU_SRL);
          F3_OR:      ctrl.alu_op = ALU_OR;
          F3_AND:     ctrl.alu_op = ALU_AND;
        endcase
      end

      // ---- register-register -------------------------------------
      OP_REG: begin
        ctrl.reg_write   = 1'b1;
        ctrl.imm_sel     = IMM_NONE;
        ctrl.wb_sel      = WB_ALU;
        unique case (funct3)
          F3_ADD_SUB: ctrl.alu_op = alu_op_e'(funct7[5] ? ALU_SUB : ALU_ADD);
          F3_SLL:     ctrl.alu_op = ALU_SLL;
          F3_SLT:     ctrl.alu_op = ALU_SLT;
          F3_SLTU:    ctrl.alu_op = ALU_SLTU;
          F3_XOR:     ctrl.alu_op = ALU_XOR;
          F3_SRL_SRA: ctrl.alu_op = alu_op_e'(funct7[5] ? ALU_SRA : ALU_SRL);
          F3_OR:      ctrl.alu_op = ALU_OR;
          F3_AND:     ctrl.alu_op = ALU_AND;
        endcase
      end

      // ---- FENCE is architecturally a NOP on a single-hart in-order core
      OP_FENCE: ;

      // ---- ECALL / EBREAK stop the core; this design has no trap handler
      OP_SYSTEM: ctrl.is_system = 1'b1;

      default: ctrl.illegal = 1'b1;
    endcase
  end

endmodule
