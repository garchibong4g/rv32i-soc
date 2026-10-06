`timescale 1ns/1ps
//=============================================================================
// axi_stall_tb.sv - the same end-to-end layer compute, but under RANDOM
// AXI backpressure, to prove the handshaking is robust (reviewer's request).
//
// A real interconnect/slave does not accept every beat on the first cycle. Here
// the slave's handshake-accept signals are gated by random stall: AWREADY,
// WREADY, and the master's view of channel readiness are throttled by randomly
// delaying when the slave asserts ready / valid. The master must hold VALID and
// payload stable across the stalls (the core AXI rule) and still complete every
// transaction. If the layer result still matches the Python golden model under
// random stalls, the protocol implementation is correct, not just lucky on a
// zero-latency bus.
//
// Mechanism: we wrap the real axi4lite_accel but intercept its *_READY / *VALID
// toward the master with a random mask, so beats are deferred by 0..3 cycles.
//=============================================================================
module axi_stall_tb;
  localparam int N = 4;

  logic clk = 0; always #5 clk = ~clk;
  logic rst;

  logic [31:0] core_addr, core_wdata; logic [3:0] core_be;
  logic core_we, core_re; logic [31:0] core_rdata; logic acc_ready;

  // master <-> (stall shim) <-> slave
  logic [31:0] AWADDR,WDATA,ARADDR;
  logic [3:0]  WSTRB;
  logic        AWVALID,WVALID,BREADY,ARVALID,RREADY;         // master -> slave
  // slave native handshake outputs
  logic        s_AWREADY,s_WREADY,s_BVALID,s_ARREADY,s_RVALID;
  logic [1:0]  s_BRESP,s_RRESP; logic [31:0] s_RDATA;
  // throttled versions the master sees
  logic        AWREADY,WREADY,BVALID,ARREADY,RVALID;

  // ---- random stall mask: each ready/valid is allowed only when its gate is 1
  logic g_aw,g_w,g_b,g_ar,g_r;
  // simple LFSR-ish random using $random; bias ~70% ready so sim finishes
  always_ff @(posedge clk) begin
    if (rst) begin g_aw<=1;g_w<=1;g_b<=1;g_ar<=1;g_r<=1; end
    else begin
      g_aw <= ($random % 10) < 7;
      g_w  <= ($random % 10) < 7;
      g_b  <= ($random % 10) < 7;
      g_ar <= ($random % 10) < 7;
      g_r  <= ($random % 10) < 7;
    end
  end

  // throttle: slave appears not-ready / not-valid while its gate is low
  assign AWREADY = s_AWREADY & g_aw;
  assign WREADY  = s_WREADY  & g_w;
  assign BVALID  = s_BVALID  & g_b;
  assign ARREADY = s_ARREADY & g_ar;
  assign RVALID  = s_RVALID  & g_r;

  axi4lite_master u_m (
    .clk,.rst,.core_addr,.core_wdata,.core_be,.core_we,.core_re,.core_rdata,.acc_ready,
    .M_AWADDR(AWADDR),.M_AWVALID(AWVALID),.M_AWREADY(AWREADY),
    .M_WDATA(WDATA),.M_WSTRB(WSTRB),.M_WVALID(WVALID),.M_WREADY(WREADY),
    .M_BRESP(2'b00),.M_BVALID(BVALID),.M_BREADY(BREADY),
    .M_ARADDR(ARADDR),.M_ARVALID(ARVALID),.M_ARREADY(ARREADY),
    .M_RDATA(s_RDATA),.M_RRESP(s_RRESP),.M_RVALID(RVALID),.M_RREADY(RREADY)
  );

  // slave sees the master's VALID gated the same way its READY is gated, so a
  // beat only transfers when BOTH ends agree on that throttled cycle.
  axi4lite_accel #(.N(N)) u_accel (
    .clk,.rst,
    .S_AWADDR(AWADDR),.S_AWVALID(AWVALID & g_aw),.S_AWREADY(s_AWREADY),
    .S_WDATA(WDATA),.S_WSTRB(WSTRB),.S_WVALID(WVALID & g_w),.S_WREADY(s_WREADY),
    .S_BRESP(s_BRESP),.S_BVALID(s_BVALID),.S_BREADY(BREADY & g_b),
    .S_ARADDR(ARADDR),.S_ARVALID(ARVALID & g_ar),.S_ARREADY(s_ARREADY),
    .S_RDATA(s_RDATA),.S_RRESP(s_RRESP),.S_RVALID(s_RVALID),.S_RREADY(RREADY & g_r)
  );

  localparam [31:0] A_WEIGHT=0, A_ACT=4, A_CTRL=8, A_STATUS=12, A_RES0=16;
  int errors=0, gg, tg;
  logic [31:0] vec [24];
  logic [31:0] rd;
  int i;

  task cpu_write(input [31:0] a, input [31:0] d);
    tg=0;
    @(negedge clk); core_addr=a; core_wdata=d; core_be=4'hF; core_we=1; core_re=0;
    @(negedge clk); core_we=0;
    while(!acc_ready && tg<200) begin @(negedge clk); tg++; end
    @(negedge clk);
  endtask
  task cpu_read(input [31:0] a, output [31:0] d);
    tg=0;
    while(acc_ready) @(negedge clk);
    @(negedge clk); core_addr=a; core_we=0; core_re=1;
    @(negedge clk); core_re=0;
    d=32'hx;
    while(tg<200) begin if(acc_ready) begin d=core_rdata; tg=999; end else begin @(negedge clk); tg++; end end
    @(negedge clk);
  endtask

  initial begin
    $readmemh("../sw/layer_vec.hex", vec);
    rst=1; core_addr=0; core_wdata=0; core_be=0; core_we=0; core_re=0;
    repeat(3) @(negedge clk); rst=0;

    cpu_write(A_CTRL, 32'h2);
    for(i=0;i<16;i++) cpu_write(A_WEIGHT, vec[i]);
    for(i=0;i<4;i++)  cpu_write(A_ACT, vec[16+i]);
    cpu_write(A_CTRL, 32'h1);

    gg=0; rd=0;
    while(!(rd & 32'h1) && gg<500) begin cpu_read(A_STATUS, rd); gg++; end
    if(!(rd&1)) begin $display("  FAIL: no DONE under stalls"); errors++; end
    else $display("  INFO: DONE under random stalls after %0d polls", gg);

    repeat(6) @(negedge clk);
    for(i=0;i<4;i++) begin
      cpu_read(A_RES0 + i*4, rd);
      if($signed(rd) !== $signed(vec[20+i])) begin
        $display("  FAIL result[%0d]: AXI=%0d golden=%0d", i, $signed(rd), $signed(vec[20+i])); errors++;
      end else $display("  PASS result[%0d] = %0d (matches golden, under stalls)", i, $signed(rd));
    end

    $display("");
    if(errors==0) $display("AXI STALL TB: PASS - layer matches golden under random bus backpressure");
    else          $display("AXI STALL TB: %0d FAILURES", errors);
    $finish;
  end
  initial begin #500000; $display("TIMEOUT"); $finish; end
endmodule
