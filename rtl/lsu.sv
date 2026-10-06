//=============================================================================
// lsu.sv - load/store alignment and extension
//
// RV32I memory is BYTE-ADDRESSED but the data memory here is 32 bits wide, so
// sub-word accesses need shifting on both sides:
//
//   STORE: replicate the source bytes into the right lanes of the 32-bit word
//          and produce a 4-bit byte-enable mask so only those lanes commit.
//   LOAD:  select the addressed lane(s) out of the returned word, then sign-
//          or zero-extend depending on funct3.
//
// This whole module has no counterpart in the word-addressed 16-bit custom
// CPU - it exists purely because the RV32I spec mandates byte addressing.
//=============================================================================
module lsu
  import rv32i_pkg::*;
(
  // store path
  input  logic [2:0]  st_funct3,
  input  logic [1:0]  st_offset,      // address[1:0]
  input  logic [31:0] st_rs2,
  output logic [31:0] st_wdata,
  output logic [3:0]  st_be,

  // load path
  input  logic [2:0]  ld_funct3,
  input  logic [1:0]  ld_offset,
  input  logic [31:0] ld_word,        // raw 32-bit word from memory
  output logic [31:0] ld_result
);

  // ---- store: place bytes and build the enable mask -----------------
  always_comb begin
    st_wdata = 32'h0;
    st_be    = 4'b0000;
    unique case (st_funct3)
      F3_B: begin
        st_wdata = {4{st_rs2[7:0]}};              // same byte in all lanes
        st_be    = 4'b0001 << st_offset;          // enable only the one
      end
      F3_H: begin
        st_wdata = {2{st_rs2[15:0]}};
        st_be    = st_offset[1] ? 4'b1100 : 4'b0011;
      end
      F3_W: begin
        st_wdata = st_rs2;
        st_be    = 4'b1111;
      end
      default: ;
    endcase
  end

  // ---- load: extract the lane, then extend --------------------------
  logic [7:0]  ld_byte;
  logic [15:0] ld_half;

  always_comb begin
    unique case (ld_offset)
      2'd0: ld_byte = ld_word[7:0];
      2'd1: ld_byte = ld_word[15:8];
      2'd2: ld_byte = ld_word[23:16];
      2'd3: ld_byte = ld_word[31:24];
    endcase
    ld_half = ld_offset[1] ? ld_word[31:16] : ld_word[15:0];
  end

  always_comb begin
    unique case (ld_funct3)
      F3_B:    ld_result = {{24{ld_byte[7]}},  ld_byte};    // sign-extend
      F3_H:    ld_result = {{16{ld_half[15]}}, ld_half};
      F3_W:    ld_result = ld_word;
      F3_BU:   ld_result = {24'h0, ld_byte};                // zero-extend
      F3_HU:   ld_result = {16'h0, ld_half};
      default: ld_result = ld_word;
    endcase
  end

endmodule
