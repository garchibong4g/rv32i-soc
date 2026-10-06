//=============================================================================
// axi4lite_master.sv - AXI4-Lite master wrapper for the RV32I core
//
// Converts the core's simple synchronous data port (addr, wdata, be, we, re,
// one-cycle rdata) into a compliant AMBA AXI4-Lite master that sequences each
// access through AXI's five independent channels:
//
//   AW  write address   (AWADDR, AWVALID / AWREADY)
//   W   write data       (WDATA, WSTRB, WVALID / WREADY)
//   B   write response   (BRESP, BVALID / BREADY)
//   AR  read address     (ARADDR, ARVALID / ARREADY)
//   R   read data        (RDATA, RRESP, RVALID / RREADY)
//
// Each channel is a VALID/READY handshake: the source raises VALID and holds
// the payload stable until the sink raises READY; transfer happens on the cycle
// both are high. AXI4-Lite is single-beat (no bursts), 32-bit, which is exactly
// what a load/store needs.
//
// The core issues at most one outstanding access, so this master is a small FSM:
// idle until the core asserts we/re, run the write (AW+W, then wait B) or the
// read (AR, then wait R), hand the result back, and stall the core until the
// transaction completes (acc_ready).
//=============================================================================
module axi4lite_master (
  input  logic        clk,
  input  logic        rst,

  // ---- core-side request (simple port) ----
  input  logic [31:0] core_addr,
  input  logic [31:0] core_wdata,
  input  logic [3:0]  core_be,
  input  logic        core_we,
  input  logic        core_re,
  output logic [31:0] core_rdata,
  output logic        acc_ready,     // transaction complete this cycle (unstall core)

  // ---- AXI4-Lite master interface ----
  // write address channel
  output logic [31:0] M_AWADDR,
  output logic        M_AWVALID,
  input  logic        M_AWREADY,
  // write data channel
  output logic [31:0] M_WDATA,
  output logic [3:0]  M_WSTRB,
  output logic        M_WVALID,
  input  logic        M_WREADY,
  // write response channel
  input  logic [1:0]  M_BRESP,
  input  logic        M_BVALID,
  output logic        M_BREADY,
  // read address channel
  output logic [31:0] M_ARADDR,
  output logic        M_ARVALID,
  input  logic        M_ARREADY,
  // read data channel
  input  logic [31:0] M_RDATA,
  input  logic [1:0]  M_RRESP,
  input  logic        M_RVALID,
  output logic        M_RREADY
);

  typedef enum logic [2:0] {
    S_IDLE,
    S_WADDR,   // drive AW (and W) until both accepted
    S_WRESP,   // wait for B
    S_RADDR,   // drive AR until accepted
    S_RDATA    // wait for R
  } state_e;

  state_e state;

  // latched request payload
  logic [31:0] addr_q, wdata_q, rdata_q;
  logic [3:0]  be_q;

  // per-channel handshake-complete flags (a channel may finish before another)
  logic aw_done, w_done;

  always_ff @(posedge clk) begin
    if (rst) begin
      state     <= S_IDLE;
      aw_done   <= 1'b0;
      w_done    <= 1'b0;
      addr_q    <= 32'h0;
      wdata_q   <= 32'h0;
      be_q      <= 4'h0;
      rdata_q   <= 32'h0;
    end else begin
      case (state)
        // ----------------------------------------------------------
        S_IDLE: begin
          aw_done <= 1'b0;
          w_done  <= 1'b0;
          if (core_we) begin
            addr_q  <= core_addr;
            wdata_q <= core_wdata;
            be_q    <= core_be;
            state   <= S_WADDR;
          end else if (core_re) begin
            addr_q  <= core_addr;
            state   <= S_RADDR;
          end
        end

        // ----------------------------------------------------------
        // Write: AW and W are independent channels; accept each when its
        // READY comes, in either order, then move on once both are done.
        S_WADDR: begin
          if (M_AWVALID && M_AWREADY) aw_done <= 1'b1;
          if (M_WVALID  && M_WREADY)  w_done  <= 1'b1;
          if ((aw_done || (M_AWVALID && M_AWREADY)) &&
              (w_done  || (M_WVALID  && M_WREADY)))
            state <= S_WRESP;
        end

        S_WRESP: begin
          if (M_BVALID && M_BREADY) begin
            aw_done <= 1'b0;
            w_done  <= 1'b0;
            state   <= S_IDLE;
          end
        end

        // ----------------------------------------------------------
        S_RADDR: begin
          if (M_ARVALID && M_ARREADY) state <= S_RDATA;
        end

        S_RDATA: begin
          if (M_RVALID && M_RREADY) begin
            rdata_q <= M_RDATA;
            state   <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // ---- channel VALID/payload drive (combinational from state) ----
  // AW
  assign M_AWADDR  = addr_q;
  assign M_AWVALID = (state == S_WADDR) && !aw_done;
  // W
  assign M_WDATA   = wdata_q;
  assign M_WSTRB   = be_q;
  assign M_WVALID  = (state == S_WADDR) && !w_done;
  // B
  assign M_BREADY  = (state == S_WRESP);
  // AR
  assign M_ARADDR  = addr_q;
  assign M_ARVALID = (state == S_RADDR);
  // R
  assign M_RREADY  = (state == S_RDATA);

  // ---- core-side response ----
  // Present read data on the SAME cycle the transaction completes: on the
  // completing read cycle the data is live on M_RDATA (not yet in rdata_q), so
  // forward it combinationally. A core samples core_rdata when acc_ready is high.
  assign core_rdata = ((state == S_RDATA) && M_RVALID) ? M_RDATA : rdata_q;
  // transaction completes (unstall the core) on B accept or R accept
  assign acc_ready  = ((state == S_WRESP) && M_BVALID && M_BREADY) ||
                      ((state == S_RDATA) && M_RVALID && M_RREADY);

endmodule
