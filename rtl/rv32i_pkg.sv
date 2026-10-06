//=============================================================================
// rv32i_pkg.sv - RV32I ISA definitions
//
// Unlike the custom 16-bit ISA of the previous project, this is a STANDARD
// instruction set: RISC-V RV32I base integer, as specified in the RISC-V
// Unprivileged ISA manual. Every encoding here is fixed by the spec, not by
// this project. That is the point - programs assembled by any RV32I toolchain
// run on this core.
//
// KEY DIFFERENCES FROM THE 16-BIT CUSTOM CORE
//   32-bit fixed-width instructions, 32 registers, x0 hardwired zero.
//   BYTE-ADDRESSED memory with sub-word loads and stores (LB/LH/LW/SB/SH/SW),
//   which requires alignment and sign-extension logic the word-addressed
//   custom core never needed.
//   Six instruction formats with deliberately scrambled immediate fields
//   (see imm_gen.sv for why).
//   PC advances by 4, not 1.
//=============================================================================
package rv32i_pkg;

  // ------------------------------------------------------------------
  // Opcodes - instr[6:0]. All RV32I opcodes end in 2'b11.
  // ------------------------------------------------------------------
  localparam logic [6:0] OP_LUI    = 7'b0110111;
  localparam logic [6:0] OP_AUIPC  = 7'b0010111;
  localparam logic [6:0] OP_JAL    = 7'b1101111;
  localparam logic [6:0] OP_JALR   = 7'b1100111;
  localparam logic [6:0] OP_BRANCH = 7'b1100011;
  localparam logic [6:0] OP_LOAD   = 7'b0000011;
  localparam logic [6:0] OP_STORE  = 7'b0100011;
  localparam logic [6:0] OP_IMM    = 7'b0010011;   // ADDI, SLTI, ...
  localparam logic [6:0] OP_REG    = 7'b0110011;   // ADD, SUB, ...
  localparam logic [6:0] OP_FENCE  = 7'b0001111;
  localparam logic [6:0] OP_SYSTEM = 7'b1110011;   // ECALL / EBREAK

  // ------------------------------------------------------------------
  // funct3 encodings, reused across several opcodes
  // ------------------------------------------------------------------
  // OP_REG / OP_IMM
  localparam logic [2:0] F3_ADD_SUB = 3'b000;   // SUB when funct7[5]
  localparam logic [2:0] F3_SLL     = 3'b001;
  localparam logic [2:0] F3_SLT     = 3'b010;
  localparam logic [2:0] F3_SLTU    = 3'b011;
  localparam logic [2:0] F3_XOR     = 3'b100;
  localparam logic [2:0] F3_SRL_SRA = 3'b101;   // SRA when funct7[5]
  localparam logic [2:0] F3_OR      = 3'b110;
  localparam logic [2:0] F3_AND     = 3'b111;

  // OP_BRANCH
  localparam logic [2:0] F3_BEQ  = 3'b000;
  localparam logic [2:0] F3_BNE  = 3'b001;
  localparam logic [2:0] F3_BLT  = 3'b100;
  localparam logic [2:0] F3_BGE  = 3'b101;
  localparam logic [2:0] F3_BLTU = 3'b110;
  localparam logic [2:0] F3_BGEU = 3'b111;

  // OP_LOAD / OP_STORE - width and signedness
  localparam logic [2:0] F3_B  = 3'b000;   // byte, sign-extended
  localparam logic [2:0] F3_H  = 3'b001;   // half, sign-extended
  localparam logic [2:0] F3_W  = 3'b010;   // word
  localparam logic [2:0] F3_BU = 3'b100;   // byte, zero-extended
  localparam logic [2:0] F3_HU = 3'b101;   // half, zero-extended

  // ------------------------------------------------------------------
  // ALU operation select
  // ------------------------------------------------------------------
  typedef enum logic [3:0] {
    ALU_ADD,
    ALU_SUB,
    ALU_SLL,
    ALU_SLT,     // signed set-less-than
    ALU_SLTU,    // unsigned set-less-than
    ALU_XOR,
    ALU_SRL,
    ALU_SRA,     // arithmetic (sign-replicating) right shift
    ALU_OR,
    ALU_AND,
    ALU_PASS_B   // pass operand B through, used by LUI
  } alu_op_e;

  // ------------------------------------------------------------------
  // Immediate format select
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {
    IMM_I, IMM_S, IMM_B, IMM_U, IMM_J, IMM_NONE
  } imm_sel_e;

  // ------------------------------------------------------------------
  // Writeback source select
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {
    WB_ALU,      // ALU result
    WB_MEM,      // data memory (after LSU extraction)
    WB_PC4,      // PC + 4, the link value for JAL / JALR
    WB_NONE      // no register write
  } wb_sel_e;

  // ------------------------------------------------------------------
  // Decoded control bundle. Packing control into one struct keeps the
  // pipeline registers readable: one field carries the whole decode.
  // ------------------------------------------------------------------
  typedef struct packed {
    logic      reg_write;     // writes the register file
    logic      mem_read;      // is a load
    logic      mem_write;     // is a store
    logic      is_branch;     // conditional branch
    logic      is_jal;        // JAL   (PC-relative jump)
    logic      is_jalr;       // JALR  (register-indirect jump)
    logic      alu_src_imm;   // ALU operand B is the immediate, not rs2
    logic      alu_src_pc;    // ALU operand A is the PC (AUIPC)
    logic      is_system;     // ECALL / EBREAK -> halt
    logic      illegal;       // no decode matched
    alu_op_e   alu_op;
    imm_sel_e  imm_sel;
    wb_sel_e   wb_sel;
    logic [2:0] funct3;       // carried for branch condition and LSU width
  } ctrl_t;

  // Icarus does not accept named struct literals in a localparam, so the
  // all-quiet control word is built as a bit pattern and cast. Field order
  // follows the struct declaration above, MSB first.
  //   10 flag bits | alu_op(4) | imm_sel(3) | wb_sel(2) | funct3(3)
  localparam ctrl_t CTRL_NOP = ctrl_t'({
    10'b00_0000_0000,   // all control flags clear
    4'(ALU_ADD),
    3'(IMM_NONE),
    2'(WB_NONE),        // WB_NONE is what actually suppresses the write
    3'b000
  });

endpackage
