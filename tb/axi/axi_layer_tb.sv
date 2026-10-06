`timescale 1ns/1ps
//=============================================================================
// axi_layer_tb.sv - end-to-end: compute a layer over AXI, check vs Python ref
//
// Wires the AXI4-Lite MASTER to the accelerator's AXI4-Lite SLAVE wrapper and
// drives a full matrix-vector layer entirely through AXI transactions:
//   reset counters, stream 16 weights, stream 4 activations, start, poll STATUS,
//   read 4 results. The results are compared against the Python golden model
//   (sw/layer_vec.hex), so a pass means the accelerator computes correctly when
//   driven over the real bus - the proof the SoC works, not just the plan.
//=============================================================================
module axi_layer_tb;
  localparam int N = 4;

  logic clk = 0; always #5 clk = ~clk;
  logic rst;

  // core-side request into the master
  logic [31:0] core_addr, core_wdata; logic [3:0] core_be;
  logic core_we, core_re; logic [31:0] core_rdata; logic acc_ready;

  // AXI channels master<->slave
  logic [31:0] AWADDR,WDATA,ARADDR,RDATA; logic [3:0] WSTRB; logic [1:0] BRESP,RRESP;
  logic AWVALID,AWREADY,WVALID,WREADY,BVALID,BREADY,ARVALID,ARREADY,RVALID,RREADY;

  axi4lite_master u_m (
    .clk,.rst,.core_addr,.core_wdata,.core_be,.core_we,.core_re,.core_rdata,.acc_ready,
    .M_AWADDR(AWADDR),.M_AWVALID(AWVALID),.M_AWREADY(AWREADY),
    .M_WDATA(WDATA),.M_WSTRB(WSTRB),.M_WVALID(WVALID),.M_WREADY(WREADY),
    .M_BRESP(BRESP),.M_BVALID(BVALID),.M_BREADY(BREADY),
    .M_ARADDR(ARADDR),.M_ARVALID(ARVALID),.M_ARREADY(ARREADY),
    .M_RDATA(RDATA),.M_RRESP(RRESP),.M_RVALID(RVALID),.M_RREADY(RREADY)
  );

  axi4lite_accel #(.N(N)) u_accel (
    .clk,.rst,
    .S_AWADDR(AWADDR),.S_AWVALID(AWVALID),.S_AWREADY(AWREADY),
    .S_WDATA(WDATA),.S_WSTRB(WSTRB),.S_WVALID(WVALID),.S_WREADY(WREADY),
    .S_BRESP(BRESP),.S_BVALID(BVALID),.S_BREADY(BREADY),
    .S_ARADDR(ARADDR),.S_ARVALID(ARVALID),.S_ARREADY(ARREADY),
    .S_RDATA(RDATA),.S_RRESP(RRESP),.S_RVALID(RVALID),.S_RREADY(RREADY)
  );

  // accelerator register offsets
  localparam [31:0] A_WEIGHT=0, A_ACT=4, A_CTRL=8, A_STATUS=12, A_RES0=16;

  int errors=0, gg, tg;
  logic [31:0] vec [24];        // 16 W + 4 a + 4 golden
  logic [31:0] rd;
  int i;

  task cpu_write(input [31:0] a, input [31:0] d);
    tg=0;
    @(negedge clk); core_addr=a; core_wdata=d; core_be=4'hF; core_we=1; core_re=0;
    @(negedge clk); core_we=0;
    while(!acc_ready && tg<100) begin @(negedge clk); tg++; end
    @(negedge clk);
  endtask
  task cpu_read(input [31:0] a, output [31:0] d);
    tg=0;
    while(acc_ready) @(negedge clk);
    @(negedge clk); core_addr=a; core_we=0; core_re=1;
    @(negedge clk); core_re=0;
    d=32'hx;
    while(tg<100) begin if(acc_ready) begin d=core_rdata; tg=999; end else begin @(negedge clk); tg++; end end
    @(negedge clk);
  endtask

  initial begin
    $readmemh("../sw/layer_vec.hex", vec);
    rst=1; core_addr=0; core_wdata=0; core_be=0; core_we=0; core_re=0;
    repeat(3) @(negedge clk); rst=0;

    // reset write counters
    cpu_write(A_CTRL, 32'h2);
    // stream 16 weights (row-major) over AXI
    for(i=0;i<16;i++) cpu_write(A_WEIGHT, vec[i]);
    // stream 4 activations over AXI
    for(i=0;i<4;i++)  cpu_write(A_ACT, vec[16+i]);
    // start
    cpu_write(A_CTRL, 32'h1);
    // poll STATUS.done
    gg=0; rd=0;
    while(!(rd & 32'h1) && gg<300) begin cpu_read(A_STATUS, rd); gg++; end
    if(!(rd&1)) begin $display("  FAIL: accelerator never asserted DONE over AXI"); errors++; end
    else $display("  INFO: DONE asserted, STATUS=%08h after %0d polls", rd, gg);

    // settle the bus fully to idle before the result reads
    repeat(4) @(negedge clk);

    // read 4 results over AXI, compare to golden
    for(i=0;i<4;i++) begin
      cpu_read(A_RES0 + i*4, rd);
      if($signed(rd) !== $signed(vec[20+i])) begin
        $display("  FAIL result[%0d]: AXI=%0d golden=%0d", i, $signed(rd), $signed(vec[20+i]));
        errors++;
      end else
        $display("  PASS result[%0d] = %0d (matches golden)", i, $signed(rd));
    end

    $display("");
    if(errors==0) $display("AXI LAYER TB: PASS - layer computed over AXI matches Python reference");
    else          $display("AXI LAYER TB: %0d FAILURES", errors);
    $finish;
  end

  initial begin #200000; $display("TIMEOUT"); $finish; end
endmodule
