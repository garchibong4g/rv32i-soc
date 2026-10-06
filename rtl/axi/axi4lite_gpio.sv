//=============================================================================
// axi4lite_gpio.sv - AXI4-Lite GPIO slave (LEDs out, switches in)
//
// The slave side of the five AXI channels. The simplest real slave, and the
// first one brought up to prove the interconnect works end to end (spec Phase 2).
//
// Registers (word offsets within the slave's 4 KB page):
//   0x00  GPIO_OUT   R/W   drives output pins (LEDs)
//   0x04  GPIO_IN    R     reads input pins (switches)
//
// Slave handshake contract (AXI4-Lite, single beat):
//   write: accept AW and W (assert AWREADY/WREADY), then respond on B (BVALID,
//          BRESP=OKAY) and wait for BREADY.
//   read:  accept AR (ARREADY), then drive R (RVALID, RDATA, RRESP=OKAY) and
//          wait for RREADY.
//=============================================================================
module axi4lite_gpio (
  input  logic        clk,
  input  logic        rst,

  // outputs / inputs to the outside world
  output logic [31:0] gpio_out,
  input  logic [31:0] gpio_in,

  // ---- AXI4-Lite slave interface ----
  input  logic [31:0] S_AWADDR,
  input  logic        S_AWVALID,
  output logic        S_AWREADY,
  input  logic [31:0] S_WDATA,
  input  logic [3:0]  S_WSTRB,
  input  logic        S_WVALID,
  output logic        S_WREADY,
  output logic [1:0]  S_BRESP,
  output logic        S_BVALID,
  input  logic        S_BREADY,
  input  logic [31:0] S_ARADDR,
  input  logic        S_ARVALID,
  output logic        S_ARREADY,
  output logic [31:0] S_RDATA,
  output logic [1:0]  S_RRESP,
  output logic        S_RVALID,
  input  logic        S_RREADY
);

  localparam [3:0] REG_OUT = 4'h0;
  localparam [3:0] REG_IN  = 4'h4;
  localparam [1:0] RESP_OKAY = 2'b00;

  // ---------------- write path ----------------
  logic        aw_hs, w_hs;      // this-access AW / W captured
  logic [31:0] waddr_q;

  // accept AW and W when offered (one outstanding)
  assign S_AWREADY = !aw_hs && !S_BVALID;
  assign S_WREADY  = !w_hs  && !S_BVALID;

  always_ff @(posedge clk) begin
    if (rst) begin
      aw_hs <= 1'b0; w_hs <= 1'b0; waddr_q <= 32'h0;
      gpio_out <= 32'h0; S_BVALID <= 1'b0;
    end else begin
      // capture address / data beats
      if (S_AWVALID && S_AWREADY) begin aw_hs <= 1'b1; waddr_q <= S_AWADDR; end
      if (S_WVALID  && S_WREADY ) begin w_hs  <= 1'b1;
        // perform the write once we have data (address assumed same access)
        if ((S_AWVALID && S_AWREADY ? S_AWADDR[3:0] : waddr_q[3:0]) == REG_OUT) begin
          if (S_WSTRB[0]) gpio_out[7:0]   <= S_WDATA[7:0];
          if (S_WSTRB[1]) gpio_out[15:8]  <= S_WDATA[15:8];
          if (S_WSTRB[2]) gpio_out[23:16] <= S_WDATA[23:16];
          if (S_WSTRB[3]) gpio_out[31:24] <= S_WDATA[31:24];
        end
      end
      // once both AW and W are in, raise the write response
      if (aw_hs && w_hs && !S_BVALID) S_BVALID <= 1'b1;
      // response accepted -> clear for next access
      if (S_BVALID && S_BREADY) begin
        S_BVALID <= 1'b0; aw_hs <= 1'b0; w_hs <= 1'b0;
      end
    end
  end
  assign S_BRESP = RESP_OKAY;

  // ---------------- read path ----------------
  logic [31:0] raddr_q;
  assign S_ARREADY = !S_RVALID;

  always_ff @(posedge clk) begin
    if (rst) begin
      S_RVALID <= 1'b0; S_RDATA <= 32'h0; raddr_q <= 32'h0;
    end else begin
      if (S_ARVALID && S_ARREADY) begin
        raddr_q  <= S_ARADDR;
        S_RVALID <= 1'b1;
        S_RDATA  <= (S_ARADDR[3:0] == REG_IN) ? gpio_in : gpio_out;
      end else if (S_RVALID && S_RREADY) begin
        S_RVALID <= 1'b0;
      end
    end
  end
  assign S_RRESP = RESP_OKAY;

endmodule
