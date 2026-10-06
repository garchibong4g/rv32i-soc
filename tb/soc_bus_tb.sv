`timescale 1ns/1ps
//=============================================================================
// soc_bus_tb.sv - verify the interconnect and the accelerator-through-bus path
//
// Drives the bus master port exactly as the CPU's load/store would, and checks:
//   1. RAM read/write through the bus (a store then a load at the same address)
//   2. GPIO write is visible on gpio_out and reads back
//   3. the ACCELERATOR driven entirely through the bus: write a weight matrix
//      and activation vector to its registers, poke start, poll STATUS.done,
//      read the four RESULT registers, and compare to a software reference.
//
// If (3) passes, the CPU can offload a matrix-vector product to the accelerator
// over the interconnect using nothing but memory-mapped load/stores - which is
// the whole point of the SoC.
//=============================================================================
module soc_bus_tb;
  localparam int N = 4;

  logic clk = 0; always #5 clk = ~clk;
  logic rst;

  // master port (we drive this as if we were the core)
  logic [31:0] m_addr, m_wdata;
  logic [3:0]  m_be;
  logic        m_we, m_re;
  logic [31:0] m_rdata;

  // bus <-> slaves
  logic        ram_we; logic [3:0] ram_be; logic [31:0] ram_addr, ram_wdata, ram_rdata;
  logic        gpio_we; logic [31:0] gpio_wdata, gpio_rdata, gpio_out;
  logic        accel_sel, accel_we; logic [4:0] accel_addr; logic [31:0] accel_wdata, accel_rdata;

  soc_bus u_bus (
    .clk(clk), .rst(rst),
    .m_addr(m_addr), .m_wdata(m_wdata), .m_be(m_be), .m_we(m_we), .m_re(m_re), .m_rdata(m_rdata),
    .ram_we(ram_we), .ram_be(ram_be), .ram_addr(ram_addr), .ram_wdata(ram_wdata), .ram_rdata(ram_rdata),
    .gpio_we(gpio_we), .gpio_wdata(gpio_wdata), .gpio_rdata(gpio_rdata),
    .accel_sel(accel_sel), .accel_we(accel_we), .accel_addr(accel_addr), .accel_wdata(accel_wdata), .accel_rdata(accel_rdata)
  );

  dmem #(.WORDS(4096)) u_dmem (
    .clk(clk), .we(ram_we), .be(ram_be), .addr(ram_addr), .wdata(ram_wdata), .rdata(ram_rdata)
  );

  always_ff @(posedge clk) begin
    if (rst) gpio_out <= 32'h0; else if (gpio_we) gpio_out <= gpio_wdata;
  end
  assign gpio_rdata = gpio_out;

  nn_accel #(.N(N)) u_accel (
    .clk(clk), .rst(rst), .sel(accel_sel), .we(accel_we),
    .addr(accel_addr), .wdata(accel_wdata), .rdata(accel_rdata)
  );

  int errors = 0;

  // ---- bus transactions, one per call, matching 1-cycle read latency ----
  task bus_write(input [31:0] a, input [31:0] d);
    @(negedge clk); m_addr=a; m_wdata=d; m_be=4'hF; m_we=1; m_re=0;
    @(negedge clk); m_we=0;
  endtask
  // Hold m_re asserted through the capture: registered slaves (RAM/GPIO) present
  // data one cycle after the address, and the combinational slave (accelerator)
  // presents it only while selected - so sample rdata with re still high, then
  // deassert. Capturing after dropping re loses the accelerator's data.
  task bus_read(input [31:0] a, output [31:0] d);
    @(negedge clk); m_addr=a; m_we=0; m_re=1;
    @(negedge clk);                 // one cycle of latency for registered slaves
    #1; d = m_rdata;                // sample while still selected
    m_re=0;
  endtask

  // accelerator register offsets (region base 0x3000)
  localparam [31:0] ACC = 32'h0000_3000;
  localparam [31:0] A_WEIGHT=ACC+0, A_ACT=ACC+4, A_CTRL=ACC+8, A_STATUS=ACC+12, A_RES0=ACC+16;

  logic signed [7:0]  W [N][N];
  logic signed [7:0]  av [N];
  logic signed [31:0] expected [N];
  logic [31:0] rd;
  int r, c, timeout;

  initial begin
    rst=1; m_addr=0; m_wdata=0; m_be=0; m_we=0; m_re=0;
    repeat(3) @(negedge clk); rst=0;

    // ---- test 1: RAM round-trip through the bus ----
    bus_write(32'h0000_1010, 32'hDEAD_BEEF);
    bus_read (32'h0000_1010, rd);
    if (rd !== 32'hDEAD_BEEF) begin $display("  FAIL RAM: got %08h", rd); errors++; end
    else $display("  PASS RAM round-trip: %08h", rd);

    // ---- test 2: GPIO ----
    bus_write(32'h0000_2000, 32'h0000_00A5);
    if (gpio_out !== 32'h0000_00A5) begin $display("  FAIL GPIO out: %08h", gpio_out); errors++; end
    else $display("  PASS GPIO write visible: %08h", gpio_out);
    bus_read(32'h0000_2000, rd);
    if (rd !== 32'h0000_00A5) begin $display("  FAIL GPIO readback: %08h", rd); errors++; end
    else $display("  PASS GPIO readback: %08h", rd);

    // ---- test 3: accelerator through the bus ----
    // identity weights -> result should equal the activation vector
    for (r=0;r<N;r++) for (c=0;c<N;c++) W[r][c] = (r==c) ? 8'sd1 : 8'sd0;
    av[0]=8'sd7; av[1]=8'sd11; av[2]=8'sd13; av[3]=8'sd17;

    bus_write(A_CTRL, 32'h2);                       // reset write counters
    for (r=0;r<N;r++) for (c=0;c<N;c++)
      bus_write(A_WEIGHT, {24'h0, W[r][c]});
    for (r=0;r<N;r++)
      bus_write(A_ACT, {24'h0, av[r]});
    bus_write(A_CTRL, 32'h1);                       // start

    timeout=0; rd=0;
    while(!(rd & 32'h1) && timeout<200) begin bus_read(A_STATUS, rd); timeout++; end
    if (timeout>=200) begin $display("  FAIL accel: never asserted done"); errors++; end

    for (c=0;c<N;c++) expected[c] = av[c];          // identity
    for (c=0;c<N;c++) begin
      bus_read(A_RES0 + c*4, rd);
      if ($signed(rd) !== expected[c]) begin
        $display("  FAIL accel res%0d: got %0d expected %0d", c, $signed(rd), expected[c]);
        errors++;
      end
    end
    if (errors==0) $display("  PASS accelerator through bus: results = [%0d %0d %0d %0d]",
                            av[0], av[1], av[2], av[3]);

    $display("");
    if (errors==0) $display("SOC_BUS TB: ALL TESTS PASSED");
    else           $display("SOC_BUS TB: %0d FAILURES", errors);
    $finish;
  end
endmodule
