//=============================================================================
// regfile32.sv - 32 x 32-bit register file
//   two asynchronous read ports, one synchronous write port
//   x0 is hardwired to zero: writes are dropped, reads return 0
//
// Asynchronous reads are what let ID read registers in the same cycle it
// decodes. The consequence is that a write committing in WB this cycle is not
// visible to a read in ID this cycle - see the write-first bypass in the core.
//=============================================================================
module regfile32 (
  input  logic        clk,
  input  logic        we,
  input  logic [4:0]  waddr,
  input  logic [31:0] wdata,
  input  logic [4:0]  raddr1,
  input  logic [4:0]  raddr2,
  output logic [31:0] rdata1,
  output logic [31:0] rdata2
);

  logic [31:0] regs [32];

  initial begin
    for (int i = 0; i < 32; i++) regs[i] = 32'h0000_0000;
  end

  always_ff @(posedge clk) begin
    if (we && (waddr != 5'd0))
      regs[waddr] <= wdata;
  end

  assign rdata1 = (raddr1 == 5'd0) ? 32'h0 : regs[raddr1];
  assign rdata2 = (raddr2 == 5'd0) ? 32'h0 : regs[raddr2];

endmodule
