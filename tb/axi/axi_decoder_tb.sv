`timescale 1ns/1ps
module dec_tb;
  logic [31:0] addr;
  logic si,sd,sa,su,st,sg,um;
  axi_decoder d(.addr,.sel_imem(si),.sel_dmem(sd),.sel_accel(sa),.sel_uart(su),.sel_timer(st),.sel_gpio(sg),.unmapped(um));
  int errors=0;
  task chk(input [31:0] a, input [5:0] exp, input [127:0] nm);
    // exp bits: {imem,dmem,accel,uart,timer,gpio}
    addr=a; #1;
    if({si,sd,sa,su,st,sg} !== exp) begin
      $display("  FAIL %0s @%08h: got %b exp %b um=%0b", nm, a, {si,sd,sa,su,st,sg}, exp, um); errors++;
    end else $display("  PASS %0s @%08h -> %b (unmapped=%0b)", nm, a, {si,sd,sa,su,st,sg}, um);
  endtask
  initial begin
    chk(32'h0000_0010, 6'b100000, "IMEM");
    chk(32'h1000_0040, 6'b010000, "DMEM");
    chk(32'h2000_0010, 6'b001000, "ACCEL");
    // the three that share nibble 0x3 - must NOT alias
    chk(32'h3000_0004, 6'b000100, "UART");
    chk(32'h3000_1004, 6'b000010, "TIMER");
    chk(32'h3000_2004, 6'b000001, "GPIO");
    // unmapped
    addr=32'h4000_0000; #1;
    if(!um || {si,sd,sa,su,st,sg}!==6'b000000) begin $display("  FAIL unmapped @40000000: um=%0b sel=%b",um,{si,sd,sa,su,st,sg}); errors++; end
    else $display("  PASS unmapped @40000000 -> DECERR (um=1)");
    addr=32'h3000_3000; #1;  // 0x3 page 3, nothing there
    if(!um) begin $display("  FAIL unmapped @30003000 should be DECERR"); errors++; end
    else $display("  PASS unmapped @30003000 -> DECERR (um=1)");
    $display("");
    if(errors==0) $display("AXI_DECODER TB: ALL TESTS PASSED (aliasing fixed, DECERR works)");
    else $display("AXI_DECODER TB: %0d FAILURES", errors);
    $finish;
  end
endmodule
