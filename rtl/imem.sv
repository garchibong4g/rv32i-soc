//=============================================================================
// imem.sv - instruction memory, synchronous read (infers block RAM)
// Byte-addressed interface, word-organised storage: addr[AW+1:2] indexes words.
//=============================================================================
module imem #(
  parameter INIT_FILE = "program.hex",
  parameter int    WORDS     = 4096
)(
  input  logic        clk,
  input  logic [31:0] addr,
  output logic [31:0] rdata
);
  localparam int AW = $clog2(WORDS);
  logic [31:0] mem [WORDS];
  initial $readmemh(INIT_FILE, mem);
  always_ff @(posedge clk) rdata <= mem[addr[AW+1:2]];
endmodule
