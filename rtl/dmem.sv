//=============================================================================
// dmem.sv - data memory, synchronous read/write with byte enables
// Byte enables are what make SB and SH possible on a 32-bit-wide memory.
//=============================================================================
module dmem #(
  parameter int WORDS = 4096
)(
  input  logic        clk,
  input  logic        we,
  input  logic [3:0]  be,
  input  logic [31:0] addr,
  input  logic [31:0] wdata,
  output logic [31:0] rdata
);
  localparam int AW = $clog2(WORDS);
  logic [31:0] mem [WORDS];

  initial begin
    for (int i = 0; i < WORDS; i++) mem[i] = 32'h0;
  end

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
