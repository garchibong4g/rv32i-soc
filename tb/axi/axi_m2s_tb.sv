`timescale 1ns/1ps
//=============================================================================
// axi_m2s_tb.sv - AXI4-Lite master <-> GPIO slave, end to end
//
// Wires the master wrapper directly to the GPIO slave (point to point, which is
// all a one-slave system needs) and drives the MASTER from its core-side port,
// exactly as the CPU's load/store would. Checks:
//   1. a write to GPIO_OUT appears on gpio_out  (AW+W+B handshake)
//   2. a read of GPIO_OUT returns what was written (AR+R handshake)
//   3. a read of GPIO_IN returns the live input pins
//   4. acc_ready pulses once per transaction (core unstall timing)
//
// If this passes, the five-channel AXI4-Lite handshake works both directions.
//=============================================================================
module axi_m2s_tb;
  logic clk = 0; always #5 clk = ~clk;
  logic rst;

  // core-side request to the master
  logic [31:0] core_addr, core_wdata; logic [3:0] core_be;
  logic core_we, core_re; logic [31:0] core_rdata; logic acc_ready;

  // AXI channels (master <-> slave)
  logic [31:0] AWADDR, WDATA, ARADDR, RDATA;
  logic [3:0]  WSTRB;
  logic [1:0]  BRESP, RRESP;
  logic AWVALID,AWREADY,WVALID,WREADY,BVALID,BREADY,ARVALID,ARREADY,RVALID,RREADY;

  // gpio pins
  logic [31:0] gpio_out, gpio_in;

  axi4lite_master u_m (
    .clk,.rst,
    .core_addr,.core_wdata,.core_be,.core_we,.core_re,.core_rdata,.acc_ready,
    .M_AWADDR(AWADDR),.M_AWVALID(AWVALID),.M_AWREADY(AWREADY),
    .M_WDATA(WDATA),.M_WSTRB(WSTRB),.M_WVALID(WVALID),.M_WREADY(WREADY),
    .M_BRESP(BRESP),.M_BVALID(BVALID),.M_BREADY(BREADY),
    .M_ARADDR(ARADDR),.M_ARVALID(ARVALID),.M_ARREADY(ARREADY),
    .M_RDATA(RDATA),.M_RRESP(RRESP),.M_RVALID(RVALID),.M_RREADY(RREADY)
  );

  axi4lite_gpio u_s (
    .clk,.rst,.gpio_out,.gpio_in,
    .S_AWADDR(AWADDR),.S_AWVALID(AWVALID),.S_AWREADY(AWREADY),
    .S_WDATA(WDATA),.S_WSTRB(WSTRB),.S_WVALID(WVALID),.S_WREADY(WREADY),
    .S_BRESP(BRESP),.S_BVALID(BVALID),.S_BREADY(BREADY),
    .S_ARADDR(ARADDR),.S_ARVALID(ARVALID),.S_ARREADY(ARREADY),
    .S_RDATA(RDATA),.S_RRESP(RRESP),.S_RVALID(RVALID),.S_RREADY(RREADY)
  );

  int errors = 0;
  int acc_pulses;
  int gg;

  // count acc_ready pulses to confirm one completion per transaction
  always_ff @(posedge clk) if (!rst && acc_ready) acc_pulses <= acc_pulses + 1;

  // issue a write: pulse the request one cycle, then wait for the completion
  // pulse. core_re/we are only high for the issue cycle so a stale acc_ready
  // from the prior transaction can't be mistaken for this one's.
  task cpu_write(input [31:0] a, input [31:0] d);
    gg=0;
    @(negedge clk); core_addr=a; core_wdata=d; core_be=4'hF; core_we=1; core_re=0;
    @(negedge clk); core_we=0;                 // request latched; deassert
    while(!acc_ready && gg<50) begin @(negedge clk); gg++; end
    @(negedge clk);                            // settle back to idle
  endtask

  task cpu_read(input [31:0] a, output [31:0] d);
    gg=0;
    // ensure the bus is idle (no lingering acc_ready) before issuing
    while (acc_ready) @(negedge clk);
    @(negedge clk); core_addr=a; core_we=0; core_re=1;
    @(negedge clk); core_re=0;                 // request latched; deassert
    d = 32'hx;
    while(gg<50) begin
      if (acc_ready) begin d = core_rdata; gg=99; end
      else begin @(negedge clk); gg++; end
    end
    @(negedge clk);
  endtask

  logic [31:0] rd;
  initial begin
    rst=1; core_addr=0; core_wdata=0; core_be=0; core_we=0; core_re=0;
    gpio_in=32'hCAFE_0007; acc_pulses=0;
    repeat(3) @(negedge clk); rst=0;

    // 1. write GPIO_OUT
    cpu_write(32'h0000_0000, 32'h0000_00A5);
    if (gpio_out !== 32'h0000_00A5) begin $display("  FAIL write->gpio_out = %08h", gpio_out); errors++; end
    else $display("  PASS AXI write: gpio_out = %08h", gpio_out);

    // 2. read it back
    cpu_read(32'h0000_0000, rd);
    if (rd !== 32'h0000_00A5) begin $display("  FAIL readback = %08h", rd); errors++; end
    else $display("  PASS AXI read:  readback = %08h", rd);

    // 3. read GPIO_IN
    cpu_read(32'h0000_0004, rd);
    if (rd !== 32'hCAFE_0007) begin $display("  FAIL gpio_in read = %08h", rd); errors++; end
    else $display("  PASS AXI read:  gpio_in  = %08h", rd);

    // 4. one acc_ready per transaction (3 transactions)
    if (acc_pulses !== 3) begin $display("  FAIL acc_ready pulses = %0d (expect 3)", acc_pulses); errors++; end
    else $display("  PASS completion: %0d acc_ready pulses for 3 transactions", acc_pulses);

    $display("");
    if (errors==0) $display("AXI4-LITE M2S TB: ALL TESTS PASSED");
    else           $display("AXI4-LITE M2S TB: %0d FAILURES", errors);
    $finish;
  end

  initial begin #20000; $display("TIMEOUT"); $finish; end
endmodule
