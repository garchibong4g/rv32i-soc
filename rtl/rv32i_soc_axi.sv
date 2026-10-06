//=============================================================================
// rv32i_soc_axi.sv - full SoC: core runs a program, drives accelerator over AXI
//
// Architecture (chosen to keep the verified core untouched):
//   - Instruction fetch: tightly-coupled single-cycle IMEM (no bus, full speed).
//   - Data path: the core's data port goes to a light AXI bridge that issues
//     single-beat AXI4-Lite transactions to one of two slaves selected by the
//     decoder - DMEM (data memory) or the NN accelerator - each of which
//     responds in one cycle, so the core's single-cycle data port is satisfied
//     and the pipeline never stalls.
//
// This is the "working bus-based computer": the CPU executes a compiled program
// from IMEM and reaches the accelerator and data memory over real AXI4-Lite.
//
// Data memory map (byte addr):
//   0x1000_0000  DMEM (data: stack/heap/buffers)
//   0x2000_0000  NN accelerator registers
//=============================================================================
module rv32i_soc_axi #(
  parameter PROGRAM = "prog.hex",
  parameter int N   = 4
)(
  input  logic        clk,
  input  logic        rst,
  output logic        halted,
  output logic [31:0] dbg_result     // visible pass/fail word the program writes
);

  // ---- core ----
  logic [31:0] imem_addr, imem_rdata;
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_be;
  logic        dmem_we, dmem_re, illegal_instr;
  logic [31:0] perf_cycles, perf_instrs, perf_stalls, perf_flushes;

  rv32i_core u_core (
    .clk(clk), .rst(rst),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata),
    .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_be(dmem_be),
    .dmem_we(dmem_we), .dmem_re(dmem_re), .dmem_rdata(dmem_rdata),
    .halted(halted), .illegal_instr(illegal_instr),
    .perf_cycles(perf_cycles), .perf_instrs(perf_instrs),
    .perf_stalls(perf_stalls), .perf_flushes(perf_flushes)
  );

  // ---- tightly-coupled instruction memory (single-cycle) ----
  imem #(.INIT_FILE(PROGRAM), .WORDS(4096)) u_imem (
    .clk(clk), .addr(imem_addr), .rdata(imem_rdata)
  );

  // =========================================================================
  // Data-port AXI bridge (master) - one single-beat transaction per access
  // =========================================================================
  logic [31:0] AWADDR,WDATA,ARADDR; logic [3:0] WSTRB;
  logic AWVALID,AWREADY,WVALID,WREADY,BVALID,BREADY,ARVALID,ARREADY,RVALID,RREADY;
  logic [1:0] BRESP,RRESP; logic [31:0] RDATA;

  // The core presents a load/store for exactly one cycle (dmem_re/we). The
  // single-cycle slaves below ACK immediately, so we drive the AXI channels
  // directly from the core's data port and return rdata the next cycle - which
  // is exactly the core's expected 1-cycle data latency. No stall needed.
  assign AWADDR  = dmem_addr;
  assign WDATA   = dmem_wdata;
  assign WSTRB   = dmem_be;
  assign AWVALID = dmem_we;
  assign WVALID  = dmem_we;
  assign BREADY  = 1'b1;
  assign ARADDR  = dmem_addr;
  assign ARVALID = dmem_re;
  assign RREADY  = 1'b1;

  // ---- decoder: route data access to DMEM (0x1xxx_xxxx) or ACCEL (0x2xxx_xxxx)
  logic sel_dmem, sel_accel;
  assign sel_dmem  = (dmem_addr[31:28] == 4'h1);
  assign sel_accel = (dmem_addr[31:28] == 4'h2);

  // ---- DMEM as a single-cycle AXI slave ----
  logic [31:0] dmem_axi_rdata, accel_axi_rdata;
  logic        dmem_rvalid, accel_rvalid;

  // simple single-cycle DMEM (behaves as a 1-cycle AXI slave for this bridge)
  axi_dmem_sc #(.WORDS(4096)) u_dmem (
    .clk(clk), .rst(rst),
    .sel(sel_dmem),
    .we(dmem_we && sel_dmem), .be(dmem_be),
    .re(dmem_re && sel_dmem),
    .addr(dmem_addr), .wdata(dmem_wdata),
    .rdata(dmem_axi_rdata)
  );

  // ---- accelerator as single-cycle AXI slave ----
  axi4lite_accel_sc #(.N(N)) u_accel (
    .clk(clk), .rst(rst),
    .S_AWADDR(AWADDR), .S_AWVALID(AWVALID && sel_accel), .S_AWREADY(AWREADY),
    .S_WDATA(WDATA), .S_WSTRB(WSTRB), .S_WVALID(WVALID && sel_accel), .S_WREADY(WREADY),
    .S_BRESP(BRESP), .S_BVALID(BVALID), .S_BREADY(BREADY),
    .S_ARADDR(ARADDR), .S_ARVALID(ARVALID && sel_accel), .S_ARREADY(ARREADY),
    .S_RDATA(accel_axi_rdata), .S_RRESP(RRESP), .S_RVALID(accel_rvalid), .S_RREADY(RREADY)
  );

  // ---- read-data return mux: registered select (1-cycle latency) ----
  logic sel_accel_q;
  always_ff @(posedge clk) sel_accel_q <= sel_accel && dmem_re;
  assign dmem_rdata = sel_accel_q ? accel_axi_rdata : dmem_axi_rdata;

  // ---- debug/result port: the program stores its pass/fail word to 0x1000_0FFC
  always_ff @(posedge clk) begin
    if (rst) dbg_result <= 32'h0;
    else if (dmem_we && sel_dmem && dmem_addr[15:0] == 16'h0FFC)
      dbg_result <= dmem_wdata;
  end

endmodule
