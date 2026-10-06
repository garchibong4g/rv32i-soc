//=============================================================================
// axi4lite_accel.sv - AXI4-Lite slave wrapper around nn_accel
//
// Presents the NN accelerator as a standard AXI4-Lite slave so the core drives
// it over the real bus. Internally it translates AXI read/write bursts into the
// accelerator's simple register port (sel, we, addr[4:0], wdata, rdata) - the
// headline "IP integration": an existing compute block given a bus interface.
//
// Accelerator register map (offsets within this slave's page, from nn_accel):
//   0x00 WEIGHT (W)   0x04 ACT (W)   0x08 CTRL (W)
//   0x0C STATUS (R)   0x10..1C RESULT0..3 (R)
//
// Timing note carried from the direct-bus integration: nn_accel's read data is
// COMBINATIONAL on sel (valid the cycle sel is high, same cycle as the address).
// So on an AXI read we assert accelerator sel during the address-accept cycle,
// latch its rdata, and present it on R the next cycle. Writes are single-beat:
// accept AW+W, pulse sel&we for one cycle, respond OKAY on B.
//=============================================================================
module axi4lite_accel #(
  parameter int N = 4
)(
  input  logic        clk,
  input  logic        rst,

  // ---- AXI4-Lite slave ----
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

  localparam [1:0] RESP_OKAY = 2'b00;

  // ---- accelerator register port ----
  logic        acc_sel, acc_we;
  logic [4:0]  acc_addr;
  logic [31:0] acc_wdata, acc_rdata;

  nn_accel #(.N(N)) u_accel (
    .clk(clk), .rst(rst),
    .sel(acc_sel), .we(acc_we), .addr(acc_addr),
    .wdata(acc_wdata), .rdata(acc_rdata)
  );

  // =========================================================================
  // WRITE channel FSM: AW + W -> pulse accel write -> B
  // =========================================================================
  typedef enum logic [1:0] { W_IDLE, W_DO, W_RESP } wstate_e;
  wstate_e wst;
  logic [4:0]  waddr_q;
  logic [31:0] wdata_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      wst <= W_IDLE; waddr_q <= 0; wdata_q <= 0; S_BVALID <= 1'b0;
    end else begin
      case (wst)
        W_IDLE: begin
          // accept address and data (AXI4-Lite: both single beat)
          if (S_AWVALID && S_WVALID) begin
            waddr_q <= S_AWADDR[4:0];
            wdata_q <= S_WDATA;
            wst     <= W_DO;
          end
        end
        W_DO: begin
          // accelerator write pulse happens this cycle (driven below)
          wst      <= W_RESP;
          S_BVALID <= 1'b1;
        end
        W_RESP: begin
          if (S_BVALID && S_BREADY) begin
            S_BVALID <= 1'b0;
            wst      <= W_IDLE;
          end
        end
        default: wst <= W_IDLE;
      endcase
    end
  end

  // AW/W accepted together in W_IDLE
  assign S_AWREADY = (wst == W_IDLE) && S_AWVALID && S_WVALID;
  assign S_WREADY  = (wst == W_IDLE) && S_AWVALID && S_WVALID;
  assign S_BRESP   = RESP_OKAY;

  // =========================================================================
  // READ channel FSM: AR -> (sel accel, latch rdata) -> R
  // =========================================================================
  typedef enum logic [1:0] { R_IDLE, R_DATA } rstate_e;
  rstate_e rst_s;
  logic [4:0]  raddr_q;
  logic        do_acc_read;    // assert accel sel for a read this cycle

  always_ff @(posedge clk) begin
    if (rst) begin
      rst_s <= R_IDLE; raddr_q <= 0; S_RVALID <= 1'b0; S_RDATA <= 0;
    end else begin
      case (rst_s)
        R_IDLE: begin
          if (S_ARVALID) begin
            raddr_q <= S_ARADDR[4:0];
            // accel rdata is combinational on sel+addr; capture it next cycle
            rst_s   <= R_DATA;
          end
        end
        R_DATA: begin
          // Capture acc_rdata ONLY on the first R_DATA cycle (while sel is still
          // asserted via do_acc_read). On later cycles sel is low and acc_rdata
          // reads 0, so capturing again would clobber the latched value - that
          // was the bug where the first read of a sequence returned 0.
          if (!S_RVALID) begin
            S_RDATA  <= acc_rdata;
            S_RVALID <= 1'b1;
          end else if (S_RREADY) begin
            S_RVALID <= 1'b0;
            rst_s    <= R_IDLE;
          end
        end
        default: rst_s <= R_IDLE;
      endcase
    end
  end

  assign S_ARREADY   = (rst_s == R_IDLE) && S_ARVALID;
  assign S_RRESP     = RESP_OKAY;
  // drive the accelerator read select during R_DATA (combinational rdata)
  assign do_acc_read = (rst_s == R_DATA) && !S_RVALID;

  // =========================================================================
  // Drive the accelerator register port
  //   write: in W_DO, pulse sel&we with the latched address/data
  //   read:  in R_DATA pre-latch, assert sel (we=0) with the read address
  // =========================================================================
  always_comb begin
    acc_sel   = 1'b0;
    acc_we    = 1'b0;
    acc_addr  = 5'h0;
    acc_wdata = 32'h0;
    if (wst == W_DO) begin
      acc_sel   = 1'b1;
      acc_we    = 1'b1;
      acc_addr  = waddr_q;
      acc_wdata = wdata_q;
    end else if (do_acc_read) begin
      acc_sel   = 1'b1;   // read: sel high, we low -> combinational rdata
      acc_we    = 1'b0;
      acc_addr  = raddr_q;
    end
  end

endmodule
