//=============================================================================
// axi_decoder.sv - AXI4-Lite address decoder + slave select
//
// Maps a 32-bit AXI address to exactly one slave and produces a one-hot select.
// Also flags an UNMAPPED access so the interconnect can return a DECERR response
// instead of hanging or aliasing onto a real slave.
//
// WHY FULL-PAGE DECODE (not "just the top nibble"):
//   The peripheral pages share high nibbles:
//     UART   0x3000_0000
//     TIMER  0x3000_1000
//     GPIO   0x3000_2000
//   All three have top nibble 0x3 - decoding on the nibble alone would alias
//   them onto one another. Each 4 KB page is distinguished by addr[31:12], so
//   the decoder compares the full page tag. (This corrects the spec's
//   "compare only the top nibble" claim, which is wrong for these peripherals.)
//
// Memory map (addr[31:12] page tags):
//   IMEM   0x00000        instruction memory    (64 KB region, pages 0x00000..0F)
//   DMEM   0x10000        data memory           (0x10000..0F)
//   ACCEL  0x20000        NN accelerator        (0x20000)
//   UART   0x30000        UART                  (0x30000)
//   TIMER  0x30001        timer                 (0x30001)
//   GPIO   0x30002        GPIO                  (0x30002)
// Anything else -> unmapped (DECERR).
//=============================================================================
module axi_decoder (
  input  logic [31:0] addr,
  output logic        sel_imem,
  output logic        sel_dmem,
  output logic        sel_accel,
  output logic        sel_uart,
  output logic        sel_timer,
  output logic        sel_gpio,
  output logic        unmapped      // 1 = no slave claims this address
);

  // 64 KB regions for the memories => match addr[31:16]; 4 KB pages for
  // peripherals => match addr[31:12].
  logic [15:0] region16;   // addr[31:16]
  logic [19:0] page20;     // addr[31:12]
  assign region16 = addr[31:16];
  assign page20   = addr[31:12];

  assign sel_imem  = (region16 == 16'h0000);           // 0x0000_xxxx
  assign sel_dmem  = (region16 == 16'h1000);           // 0x1000_xxxx
  assign sel_accel = (page20   == 20'h20000);          // 0x2000_0xxx
  assign sel_uart  = (page20   == 20'h30000);          // 0x3000_0xxx
  assign sel_timer = (page20   == 20'h30001);          // 0x3000_1xxx
  assign sel_gpio  = (page20   == 20'h30002);          // 0x3000_2xxx

  assign unmapped = !(sel_imem | sel_dmem | sel_accel |
                      sel_uart | sel_timer | sel_gpio);

endmodule
