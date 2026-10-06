//=============================================================================
// axi_dmem_sc.sv - single-cycle data memory for the AXI data path
//
// Synchronous-read/write RAM with byte enables, one-cycle read latency. Acts as
// the DMEM slave on the single-cycle data bus. (A full AXI4-Lite handshake
// wrapper is unnecessary here because the bridge drives single-beat accesses to
// single-cycle slaves; the accelerator has the full AXI slave interface.)
//=============================================================================
module axi_dmem_sc #(
  parameter int WORDS = 4096
)(
  input  logic        clk,
  input  logic        rst,
  input  logic        sel,
  input  logic        we,
  input  logic [3:0]  be,
  input  logic        re,
  input  logic [31:0] addr,
  input  logic [31:0] wdata,
  output logic [31:0] rdata
);
  localparam int AW = $clog2(WORDS);
  logic [31:0] mem [WORDS];

  initial for (int i=0;i<WORDS;i++) mem[i] = 32'h0;

  always_ff @(posedge clk) begin
    if (we) begin
      if (be[0]) mem[addr[AW+1:2]][7:0]   <= wdata[7:0];
      if (be[1]) mem[addr[AW+1:2]][15:8]  <= wdata[15:8];
      if (be[2]) mem[addr[AW+1:2]][23:16] <= wdata[23:16];
      if (be[3]) mem[addr[AW+1:2]][31:24] <= wdata[31:24];
    end
    rdata <= mem[addr[AW+1:2]];
  end
endmodule
