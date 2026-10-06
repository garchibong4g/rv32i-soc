//=============================================================================
// axi4lite_accel_sc.sv - single-cycle-response AXI4-Lite slave for nn_accel
//
// A valid AXI4-Lite slave whose read/write each complete in one cycle, so a
// single-cycle-expecting core (no stall input) can drive it directly through a
// light AXI bridge without ever stalling the pipeline.
//
// This is still real AXI4-Lite: five channels, VALID/READY handshaking, OKAY
// responses. It simply asserts READY immediately and returns BVALID/RVALID the
// next cycle - a common, legitimate slave design. (The multi-cycle-backpressure
// robustness of the accelerator path is verified separately in the stall
// testbench; this slave is the CPU-facing, no-stall variant.)
//
// Register map (nn_accel): 0x00 WEIGHT(w) 0x04 ACT(w) 0x08 CTRL(w)
//                          0x0C STATUS(r) 0x10..1C RESULT0..3(r)
//=============================================================================
module axi4lite_accel_sc #(
  parameter int N = 4
)(
  input  logic        clk,
  input  logic        rst,

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
  localparam [1:0] OKAY = 2'b00;

  logic        acc_sel, acc_we;
  logic [4:0]  acc_addr;
  logic [31:0] acc_wdata, acc_rdata;

  nn_accel #(.N(N)) u_accel (
    .clk(clk), .rst(rst),
    .sel(acc_sel), .we(acc_we), .addr(acc_addr),
    .wdata(acc_wdata), .rdata(acc_rdata)
  );

  // ---- write: accept AW+W same cycle, do the write, B next cycle ----
  wire wr_fire = S_AWVALID && S_WVALID && !S_BVALID;
  assign S_AWREADY = wr_fire;
  assign S_WREADY  = wr_fire;

  always_ff @(posedge clk) begin
    if (rst) S_BVALID <= 1'b0;
    else begin
      if (wr_fire)                 S_BVALID <= 1'b1;
      else if (S_BVALID && S_BREADY) S_BVALID <= 1'b0;
    end
  end
  assign S_BRESP = OKAY;

  // ---- read: accept AR, return R next cycle (1-cycle latency) ----
  wire rd_fire = S_ARVALID && !S_RVALID;
  assign S_ARREADY = rd_fire;

  always_ff @(posedge clk) begin
    if (rst) begin S_RVALID <= 1'b0; S_RDATA <= 32'h0; end
    else begin
      if (rd_fire) begin
        S_RVALID <= 1'b1;
        S_RDATA  <= acc_rdata;      // acc read is combinational on sel+addr
      end else if (S_RVALID && S_RREADY) begin
        S_RVALID <= 1'b0;
      end
    end
  end
  assign S_RRESP = OKAY;

  // ---- drive the accelerator register port ----
  // write pulse on the firing cycle; read select on the firing cycle so
  // acc_rdata is valid to latch into S_RDATA.
  always_comb begin
    acc_sel   = 1'b0; acc_we = 1'b0; acc_addr = 5'h0; acc_wdata = 32'h0;
    if (wr_fire) begin
      acc_sel = 1'b1; acc_we = 1'b1; acc_addr = S_AWADDR[4:0]; acc_wdata = S_WDATA;
    end else if (rd_fire) begin
      acc_sel = 1'b1; acc_we = 1'b0; acc_addr = S_ARADDR[4:0];
    end
  end
endmodule
