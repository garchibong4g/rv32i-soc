//=============================================================================
// rv32i_core_bp.sv - 5-stage RV32I core with EARLY BRANCH RESOLUTION
//
// Identical to rv32i_core.sv except that conditional branches and JAL are
// resolved in ID instead of EX. This cuts their misprediction penalty from
// 2 bubbles to 1. JALR still resolves in EX, because its target comes from a
// register that may need an ALU-stage forwarded value.
//
// The cost of moving branch resolution earlier is a NEW hazard: the compare
// happens in ID, so if a branch's source register is still in flight in EX or
// MEM, ID must either forward it or stall. We forward from EX/MEM and MEM/WB
// into the ID comparator, and stall one cycle only when the producer is a LOAD
// still in EX (its value does not exist yet) - the branch equivalent of a
// load-use hazard.
//
// ORIGINAL HEADER FOLLOWS
// rv32i_core.sv - 5-stage in-order pipelined RV32I core
//
// STAGES
//   IF   present PC to instruction memory
//   ID   instruction available, decode, read register file, generate immediate
//   EX   forwarding muxes, ALU, branch/jump resolution
//   MEM  data memory access
//   WB   load extraction and register file write
//
// HAZARD HANDLING
//   Data     - full forwarding from EX/MEM and MEM/WB into EX, plus a
//              write-first bypass in ID (see below). Zero cycle cost.
//   Load-use - 1 bubble. A load's data does not exist until the end of MEM
//              but the next instruction needs it at the start of EX.
//   Control  - 2 bubbles. Branches, JAL and JALR all resolve in EX, by which
//              point two later instructions have been fetched. Both are
//              killed. Resolving in ID would cost 1 instead of 2 but needs a
//              comparator and a forwarding path in decode; that is the
//              documented next optimisation.
//
// THE IF/ID HOLD REGISTER
//   A synchronous instruction memory is NOT a stallable pipeline register: it
//   runs one cycle AHEAD of ID. Simply holding the PC during a stall
//   re-fetches the instruction AFTER the one in ID, so the ID instruction is
//   silently lost. The hold register below latches and replays it. This was a
//   real bug in the predecessor 16-bit core, where a load-use stall in front
//   of a branch deleted the branch and the fall-through path ran instead.
//=============================================================================
module rv32i_core_bp
  import rv32i_pkg::*;
(
  input  logic        clk,
  input  logic        rst,

  // instruction port - synchronous read, one cycle latency
  output logic [31:0] imem_addr,
  input  logic [31:0] imem_rdata,

  // data port - synchronous read, one cycle latency; byte enables for stores
  output logic [31:0] dmem_addr,
  output logic [31:0] dmem_wdata,
  output logic [3:0]  dmem_be,
  output logic        dmem_we,
  output logic        dmem_re,
  input  logic [31:0] dmem_rdata,

  output logic        halted,
  output logic        illegal_instr,

  // ---- retirement interface (RVFI-style)
  // Exposes what each instruction actually committed, so a verification
  // environment can compare against a reference model in lockstep without
  // reaching into the hierarchy. Real cores expose exactly this for formal
  // and for trace-compare regressions.
  output logic        rvfi_valid,
  output logic [31:0] rvfi_pc,
  output logic [31:0] rvfi_insn,
  output logic [4:0]  rvfi_rd,
  output logic [31:0] rvfi_rd_wdata,
  output logic        rvfi_rd_we,
  output logic        rvfi_mem_we,
  output logic [31:0] rvfi_mem_addr,
  output logic [31:0] rvfi_mem_wdata,

  // performance counters, for CPI measurement
  output logic [31:0] perf_cycles,
  output logic [31:0] perf_instrs,
  output logic [31:0] perf_stalls,
  output logic [31:0] perf_flushes
);

  // ==================================================================
  // Hazard control (declared first, driven near the bottom)
  // ==================================================================
  logic        stall;
  logic        redirect;
  logic [31:0] redirect_pc;
  logic        id_kill;
  logic        halting;

  // Forward declarations for early-branch-resolution signals. These are used
  // in the IF/PC logic and the ID branch comparator but their natural
  // declaration point is further down (with the ID/EX register and the ID
  // branch block). Declaring them here keeps strict simulators - which reject
  // any reference before declaration - happy.
  logic        id_redirect;
  logic [31:0] id_redirect_pc;
  logic        id_redirect_kill;

  logic        ex_valid;
  ctrl_t       ex_ctrl;
  logic [31:0] ex_pc, ex_imm;
  logic [31:0] ex_rs1_val, ex_rs2_val;
  logic [4:0]  ex_rs1, ex_rs2, ex_rd;
  logic        ex_uses_rs1, ex_uses_rs2;
  logic [31:0] ex_instr_r;

  // ==================================================================
  // IF - instruction fetch
  // ==================================================================
  logic [31:0] pc;

  // Redirect priority: the EX-stage redirect (JALR) belongs to an OLDER
  // instruction than an ID-stage branch/JAL, so it wins. A load-use stall or
  // a branch stall freezes the PC.
  always_ff @(posedge clk) begin
    if (rst)                       pc <= 32'h0000_0000;
    else if (redirect)             pc <= redirect_pc;      // EX: JALR
    else if (stall || halting)     pc <= pc;
    else if (id_redirect)          pc <= id_redirect_pc;   // ID: branch/JAL
    else                           pc <= pc + 32'd4;
  end

  assign imem_addr = pc;

  // ==================================================================
  // ID - decode and register read
  // ==================================================================
  logic        id_valid_raw;
  logic [31:0] id_pc_raw;

  always_ff @(posedge clk) begin
    if (rst) begin
      id_valid_raw <= 1'b0;
      id_pc_raw    <= 32'h0;
    end else begin
      id_valid_raw <= 1'b1;
      id_pc_raw    <= pc;
    end
  end

  // ---- IF/ID hold register (see the header comment for why this exists)
  logic        id_hold_valid;
  logic [31:0] id_hold_instr;
  logic [31:0] id_hold_pc;

  logic [31:0] id_instr, id_pc;
  logic        id_valid;

  // When a branch/JAL redirects from ID, the instruction fetched right behind
  // it (already in flight) is on the wrong path and must be squashed for one
  // cycle. This is the single-bubble equivalent of the JALR id_kill below.
  // (id_redirect_kill forward-declared near the top.)
  always_ff @(posedge clk) begin
    if (rst) id_redirect_kill <= 1'b0;
    else     id_redirect_kill <= id_redirect;
  end

  assign id_instr = id_hold_valid ? id_hold_instr : imem_rdata;
  assign id_pc    = id_hold_valid ? id_hold_pc    : id_pc_raw;
  assign id_valid = id_redirect_kill ? 1'b0 :
                    (id_hold_valid ? 1'b1 : id_valid_raw);

  always_ff @(posedge clk) begin
    if (rst || redirect || id_redirect) begin
      id_hold_valid <= 1'b0;      // a held instruction in a branch shadow dies
    end else if (stall) begin
      id_hold_valid <= 1'b1;
      id_hold_instr <= id_instr;
      id_hold_pc    <= id_pc;
    end else begin
      id_hold_valid <= 1'b0;
    end
  end

  // ---- decode
  ctrl_t id_ctrl;
  control_unit u_ctrl (.instr(id_instr), .ctrl(id_ctrl));

  logic [31:0] id_imm;
  imm_gen u_imm (.instr(id_instr), .sel(id_ctrl.imm_sel), .imm(id_imm));

  logic [4:0] id_rs1, id_rs2, id_rd;
  assign id_rs1 = id_instr[19:15];
  assign id_rs2 = id_instr[24:20];
  assign id_rd  = id_instr[11:7];

  // Which source registers this instruction actually reads. Being precise
  // matters: marking an unused port as read causes false load-use stalls.
  logic id_uses_rs1, id_uses_rs2;

  always_comb begin
    id_uses_rs1 = 1'b0;
    id_uses_rs2 = 1'b0;
    unique case (id_instr[6:0])
      OP_REG:    begin id_uses_rs1 = 1'b1; id_uses_rs2 = 1'b1; end
      OP_BRANCH: begin id_uses_rs1 = 1'b1; id_uses_rs2 = 1'b1; end
      OP_STORE:  begin id_uses_rs1 = 1'b1; id_uses_rs2 = 1'b1; end
      OP_IMM:    id_uses_rs1 = 1'b1;
      OP_LOAD:   id_uses_rs1 = 1'b1;
      OP_JALR:   id_uses_rs1 = 1'b1;
      default: ;   // LUI, AUIPC, JAL, FENCE, SYSTEM read no registers
    endcase
  end

  // ---- register file
  logic [31:0] rf_rdata1, rf_rdata2;
  logic [31:0] wb_wdata;
  logic [4:0]  wb_rd;
  logic        wb_we;

  regfile32 u_rf (
    .clk    (clk),
    .we     (wb_we),
    .waddr  (wb_rd),
    .wdata  (wb_wdata),
    .raddr1 (id_rs1),
    .raddr2 (id_rs2),
    .rdata1 (rf_rdata1),
    .rdata2 (rf_rdata2)
  );

  // ---- ID write-first bypass
  // The register file writes on the clock edge but reads asynchronously, so
  // an instruction in ID reads the PRE-write value of a register the WB-stage
  // instruction is committing this same cycle. Without this, a dependency
  // exactly three instructions back silently reads stale data - the classic
  // "works at distance 1 and 2, breaks at 3" pipeline bug.
  logic [31:0] id_rs1_val, id_rs2_val;

  always_comb begin
    id_rs1_val = rf_rdata1;
    id_rs2_val = rf_rdata2;
    if (wb_we && (wb_rd != 5'd0)) begin
      if (wb_rd == id_rs1) id_rs1_val = wb_wdata;
      if (wb_rd == id_rs2) id_rs2_val = wb_wdata;
    end
  end

  // ==================================================================
  // EARLY BRANCH RESOLUTION (in ID)
  //
  // Conditional branches and JAL are resolved here, one stage earlier than the
  // baseline core, so a taken branch kills only ONE fetched instruction
  // instead of two. The comparison needs the branch's operands in ID, which
  // may still be in flight downstream - so we forward into the ID comparator
  // from EX/MEM and MEM/WB, and stall when the producer is a load still in EX.
  //
  // Forward sources, newest first:
  //   - a result computed in EX this cycle (ex_alu_y), for a producer now in EX
  //   - a value already in EX/MEM (mem_alu_result)
  //   - a value in MEM/WB (wb_wdata)
  // The load-in-EX case cannot be forwarded (no value yet) and forces a stall.
  // ==================================================================
  // These are driven in later stages; declared here because the ID-stage
  // branch comparator forwards from them. (SystemVerilog needs the names
  // visible before use under strict simulators. wb_wdata/wb_rd/wb_we are
  // already declared above, next to the register file.)
  logic [31:0] alu_y;
  logic        mem_valid, mem_writes_rf, mem_is_load;
  logic [4:0]  mem_rd;
  logic [31:0] mem_alu_result;
  logic        wb_valid;

  logic [31:0] id_br_a, id_br_b;
  logic        id_branch_stall;

  // forward operand A into the ID branch comparator
  always_comb begin
    id_br_a = id_rs1_val;
    if (ex_valid && ex_ctrl.reg_write && (ex_rd != 5'd0) &&
        (ex_rd == id_rs1) && !ex_ctrl.mem_read)
      id_br_a = alu_y;                       // producer in EX, result ready
    else if (mem_writes_rf && (mem_rd != 5'd0) && (mem_rd == id_rs1))
      id_br_a = mem_alu_result;
    else if (wb_we && (wb_rd != 5'd0) && (wb_rd == id_rs1))
      id_br_a = wb_wdata;
  end

  always_comb begin
    id_br_b = id_rs2_val;
    if (ex_valid && ex_ctrl.reg_write && (ex_rd != 5'd0) &&
        (ex_rd == id_rs2) && !ex_ctrl.mem_read)
      id_br_b = alu_y;
    else if (mem_writes_rf && (mem_rd != 5'd0) && (mem_rd == id_rs2))
      id_br_b = mem_alu_result;
    else if (wb_we && (wb_rd != 5'd0) && (wb_rd == id_rs2))
      id_br_b = wb_wdata;
  end

  // branch-on-load: the value the branch needs is a load result. If the load
  // is in EX, its data does not exist until end of MEM (stall). If the load is
  // in MEM, its data is not on a forwarding path into ID until it reaches WB
  // (stall one more). Either way, hold the branch in ID until the load value
  // can be forwarded from MEM/WB.
  always_comb begin
    id_branch_stall = 1'b0;
    if (id_valid && (id_ctrl.is_branch || id_ctrl.is_jalr)) begin
      // load still in EX
      if (ex_valid && ex_ctrl.mem_read && (ex_rd != 5'd0)) begin
        if (id_ctrl.is_branch) begin
          if ((id_rs1 == ex_rd) || (id_rs2 == ex_rd)) id_branch_stall = 1'b1;
        end else begin
          if (id_rs1 == ex_rd)                         id_branch_stall = 1'b1;
        end
      end
      // load in MEM (result not yet on an ID forwarding path)
      if (mem_valid && mem_is_load && (mem_rd != 5'd0)) begin
        if (id_ctrl.is_branch) begin
          if ((id_rs1 == mem_rd) || (id_rs2 == mem_rd)) id_branch_stall = 1'b1;
        end else begin
          if (id_rs1 == mem_rd)                         id_branch_stall = 1'b1;
        end
      end
    end
  end

  // the ID-stage branch decision
  logic id_br_take;
  branch_unit u_br_id (
    .funct3 (id_ctrl.funct3),
    .a      (id_br_a),
    .b      (id_br_b),
    .take   (id_br_take)
  );

  // id_redirect / id_redirect_pc forward-declared near the top.
  // A branch or JAL resolves here. JALR does NOT - its target is rs1-relative
  // and may need the EX-stage ALU value, so it stays in EX.
  assign id_redirect = id_valid && !id_branch_stall &&
                       ((id_ctrl.is_branch && id_br_take) || id_ctrl.is_jal);

  assign id_redirect_pc = id_pc + id_imm;       // both are PC-relative

  // ==================================================================
  // ID/EX pipeline register  (ex_* signals forward-declared near the top)
  // ==================================================================
  logic issue_bubble;
  assign issue_bubble = !id_valid || stall || redirect || id_kill || halting;

  always_ff @(posedge clk) begin
    if (rst || issue_bubble) begin
      ex_valid    <= 1'b0;
      ex_instr_r  <= 32'h0;
      ex_ctrl     <= ctrl_t'(CTRL_NOP);
      ex_pc       <= 32'h0;
      ex_imm      <= 32'h0;
      ex_rs1_val  <= 32'h0;
      ex_rs2_val  <= 32'h0;
      ex_rs1      <= 5'd0;
      ex_rs2      <= 5'd0;
      ex_rd       <= 5'd0;
      ex_uses_rs1 <= 1'b0;
      ex_uses_rs2 <= 1'b0;
    end else begin
      ex_valid    <= 1'b1;
      ex_instr_r  <= id_instr;
      ex_ctrl     <= id_ctrl;
      ex_pc       <= id_pc;
      ex_imm      <= id_imm;
      ex_rs1_val  <= id_rs1_val;
      ex_rs2_val  <= id_rs2_val;
      ex_rs1      <= id_rs1;
      ex_rs2      <= id_rs2;
      ex_rd       <= id_rd;
      ex_uses_rs1 <= id_uses_rs1;
      ex_uses_rs2 <= id_uses_rs2;
    end
  end

  // ==================================================================
  // EX - forwarding, ALU, branch and jump resolution
  // ==================================================================
  // (mem_valid, mem_writes_rf, mem_rd, mem_alu_result, mem_is_load, wb_valid
  //  declared earlier for the ID branch comparator)

  // ---- forwarding: MEM (newer) wins over WB (older)
  logic [31:0] fwd_a, fwd_b;

  always_comb begin
    fwd_a = ex_rs1_val;
    if (mem_writes_rf && (mem_rd != 5'd0) && (mem_rd == ex_rs1))
      fwd_a = mem_alu_result;
    else if (wb_we && (wb_rd != 5'd0) && (wb_rd == ex_rs1))
      fwd_a = wb_wdata;
  end

  always_comb begin
    fwd_b = ex_rs2_val;
    if (mem_writes_rf && (mem_rd != 5'd0) && (mem_rd == ex_rs2))
      fwd_b = mem_alu_result;
    else if (wb_we && (wb_rd != 5'd0) && (wb_rd == ex_rs2))
      fwd_b = wb_wdata;
  end

  // ---- ALU operands
  logic [31:0] alu_a, alu_b;   // alu_y declared earlier

  assign alu_a = ex_ctrl.alu_src_pc  ? ex_pc  : fwd_a;   // AUIPC uses the PC
  assign alu_b = ex_ctrl.alu_src_imm ? ex_imm : fwd_b;

  alu32 u_alu (.op(ex_ctrl.alu_op), .a(alu_a), .b(alu_b), .y(alu_y));

  // ---- branch condition
  logic br_take;
  branch_unit u_br (
    .funct3 (ex_ctrl.funct3),
    .a      (fwd_a),
    .b      (fwd_b),
    .take   (br_take)
  );

  logic branch_taken;
  assign branch_taken = ex_valid && ex_ctrl.is_branch && br_take;

  // In this core, conditional branches and JAL are resolved in ID. Only JALR
  // still redirects from EX, because its target is rs1-relative and needs the
  // forwarded ALU-stage value. branch_taken is retained only for the assertion
  // check below - a branch reaching EX should never still be "taken" here,
  // because ID already redirected it.
  assign redirect = ex_valid && ex_ctrl.is_jalr;

  // Only JALR redirects from EX now, so the target is always rs1 + imm with
  // the low bit cleared, per the spec.
  always_comb begin
    redirect_pc = (fwd_a + ex_imm) & 32'hFFFF_FFFE;
  end

  // ==================================================================
  // EX/MEM pipeline register
  // ==================================================================
  logic [31:0] mem_store_word, mem_pc4, mem_pc_r, mem_instr_r;
  logic [3:0]  mem_be;
  logic        mem_is_store, mem_is_system, mem_illegal;
  logic [2:0]  mem_funct3;
  logic [1:0]  mem_offset;
  wb_sel_e     mem_wb_sel;

  // store alignment happens in EX so MEM only drives wires
  logic [31:0] st_wdata_ex;
  logic [3:0]  st_be_ex;
  logic [31:0] ld_result_wb;

  // Declared here, ahead of the LSU that consumes them, because the WB-stage
  // width/offset feed the load extraction path. (Older Icarus does not allow
  // referencing a signal before its declaration.)
  logic [2:0]  wb_funct3;
  logic [1:0]  wb_offset;

  lsu u_lsu (
    .st_funct3 (ex_ctrl.funct3),
    .st_offset (alu_y[1:0]),
    .st_rs2    (fwd_b),
    .st_wdata  (st_wdata_ex),
    .st_be     (st_be_ex),
    // NOTE: the load path uses the WB-stage width and offset, not MEM's.
    // Load data returns one cycle after MEM, by which time the MEM stage
    // already holds the NEXT instruction - decoding the load with that
    // instruction's funct3 silently turns LB into LW (a real bug found here).
    .ld_funct3 (wb_funct3),
    .ld_offset (wb_offset),
    .ld_word   (dmem_rdata),
    .ld_result (ld_result_wb)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      mem_valid      <= 1'b0;
      mem_alu_result <= 32'h0;
      mem_store_word <= 32'h0;
      mem_be         <= 4'h0;
      mem_pc4        <= 32'h0;
      mem_pc_r       <= 32'h0;
      mem_instr_r    <= 32'h0;
      mem_rd         <= 5'd0;
      mem_is_load    <= 1'b0;
      mem_is_store   <= 1'b0;
      mem_is_system  <= 1'b0;
      mem_illegal    <= 1'b0;
      mem_funct3     <= 3'b000;
      mem_offset     <= 2'b00;
      mem_wb_sel     <= wb_sel_e'(WB_NONE);
    end else begin
      mem_valid      <= ex_valid;
      mem_alu_result <= alu_y;
      mem_store_word <= st_wdata_ex;
      mem_be         <= st_be_ex;
      mem_pc4        <= ex_pc + 32'd4;
      mem_pc_r       <= ex_pc;
      mem_instr_r    <= ex_instr_r;
      mem_rd         <= ex_rd;
      mem_is_load    <= ex_valid && ex_ctrl.mem_read;
      mem_is_store   <= ex_valid && ex_ctrl.mem_write;
      mem_is_system  <= ex_valid && ex_ctrl.is_system;
      mem_illegal    <= ex_valid && ex_ctrl.illegal;
      mem_funct3     <= ex_ctrl.funct3;
      mem_offset     <= alu_y[1:0];
      mem_wb_sel     <= wb_sel_e'(ex_valid ? ex_ctrl.wb_sel : WB_NONE);
    end
  end

  // A MEM-stage instruction can forward only if it writes the register file
  // AND its value is already known. A load's value is not known here, which
  // is precisely what the load-use stall covers.
  assign mem_writes_rf = mem_valid && (mem_wb_sel != WB_NONE) && !mem_is_load;

  // ==================================================================
  // MEM - data memory access
  // ==================================================================
  assign dmem_addr  = mem_alu_result;
  assign dmem_wdata = mem_store_word;
  assign dmem_be    = mem_be;
  assign dmem_we    = mem_is_store;
  assign dmem_re    = mem_is_load;

  // ==================================================================
  // MEM/WB pipeline register
  // ==================================================================
  logic [31:0] wb_alu_result, wb_pc4, wb_pc_r, wb_instr_r;
  logic [31:0] wb_mem_addr, wb_mem_wdata;
  logic        wb_mem_we;
  logic        wb_is_system, wb_illegal;
  wb_sel_e     wb_sel;

  always_ff @(posedge clk) begin
    if (rst) begin
      wb_valid      <= 1'b0;
      wb_alu_result <= 32'h0;
      wb_pc4        <= 32'h0;
      wb_pc_r       <= 32'h0;
      wb_instr_r    <= 32'h0;
      wb_mem_we     <= 1'b0;
      wb_mem_addr   <= 32'h0;
      wb_mem_wdata  <= 32'h0;
      wb_rd         <= 5'd0;
      wb_is_system  <= 1'b0;
      wb_illegal    <= 1'b0;
      wb_funct3     <= 3'b000;
      wb_offset     <= 2'b00;
      wb_sel        <= WB_NONE;
    end else begin
      wb_valid      <= mem_valid;
      wb_alu_result <= mem_alu_result;
      wb_pc4        <= mem_pc4;
      wb_pc_r       <= mem_pc_r;
      wb_instr_r    <= mem_instr_r;
      wb_mem_we     <= mem_is_store;
      wb_mem_addr   <= mem_alu_result;
      wb_mem_wdata  <= mem_store_word;
      wb_rd         <= mem_rd;
      wb_is_system  <= mem_is_system;
      wb_illegal    <= mem_illegal;
      wb_funct3     <= mem_funct3;
      wb_offset     <= mem_offset;
      wb_sel        <= mem_wb_sel;
    end
  end

  // ==================================================================
  // WB - writeback
  // ==================================================================
  always_comb begin
    unique case (wb_sel)
      WB_ALU:  wb_wdata = wb_alu_result;
      WB_MEM:  wb_wdata = ld_result_wb;   // load data arrives exactly now
      WB_PC4:  wb_wdata = wb_pc4;
      default: wb_wdata = 32'h0;
    endcase
  end

  assign wb_we = wb_valid && (wb_sel != WB_NONE);

  // ==================================================================
  // Hazard detection
  // ==================================================================
  logic load_use;

  always_comb begin
    load_use = 1'b0;
    if (ex_valid && ex_ctrl.mem_read && (ex_rd != 5'd0) && id_valid) begin
      if (id_uses_rs1 && (id_rs1 == ex_rd)) load_use = 1'b1;
      if (id_uses_rs2 && (id_rs2 == ex_rd)) load_use = 1'b1;
    end
  end

  assign stall = load_use || id_branch_stall;

  // second branch-shadow bubble
  always_ff @(posedge clk) begin
    if (rst) id_kill <= 1'b0;
    else     id_kill <= redirect;
  end

  // ---- halt on ECALL / EBREAK: stop fetching once issued, report halted
  // when it reaches WB so all earlier instructions have committed.
  always_ff @(posedge clk) begin
    if (rst)                                            halting <= 1'b0;
    else if (id_valid && id_ctrl.is_system && !issue_bubble) halting <= 1'b1;
  end

  always_ff @(posedge clk) begin
    if (rst)                              halted <= 1'b0;
    else if (wb_valid && wb_is_system)    halted <= 1'b1;
  end

  always_ff @(posedge clk) begin
    if (rst)                              illegal_instr <= 1'b0;
    else if (wb_valid && wb_illegal)      illegal_instr <= 1'b1;
  end

  // ==================================================================
  // Retirement interface
  // ==================================================================
  assign rvfi_valid     = wb_valid;
  assign rvfi_pc        = wb_pc_r;
  assign rvfi_insn      = wb_instr_r;
  assign rvfi_rd        = wb_rd;
  assign rvfi_rd_wdata  = wb_wdata;
  assign rvfi_rd_we     = wb_we;
  assign rvfi_mem_we    = wb_mem_we;
  assign rvfi_mem_addr  = wb_mem_addr;
  assign rvfi_mem_wdata = wb_mem_wdata;

  // ==================================================================
  // Performance counters
  // ==================================================================
  always_ff @(posedge clk) begin
    if (rst) begin
      perf_cycles  <= 32'h0;
      perf_instrs  <= 32'h0;
      perf_stalls  <= 32'h0;
      perf_flushes <= 32'h0;
    end else if (!halted) begin
      perf_cycles <= perf_cycles + 32'd1;
      if (ex_valid) perf_instrs  <= perf_instrs  + 32'd1;
      if (stall)    perf_stalls  <= perf_stalls  + 32'd1;
      if (redirect) perf_flushes <= perf_flushes + 32'd1;
    end
  end

endmodule
