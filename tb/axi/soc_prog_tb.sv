`timescale 1ns/1ps
//=============================================================================
// soc_prog_tb.sv - the full SoC running a compiled C program
//
// Loads the riscv-gcc-compiled firmware (sw/fw/prog.hex) into IMEM and runs it.
// The program (bare-metal C) drives the NN accelerator over AXI: streams the
// weight matrix and activation vector, starts the compute, polls STATUS, reads
// the results, compares them in software to the layer reference, and writes a
// pass/fail code to the result mailbox (0x1000_0FFC):
//     0x600D600D = PASS, 0xBAD0BAD0 = FAIL.
//
// The testbench just watches that mailbox. A PASS means the CPU itself -
// executing compiled instructions - computed a neural-network layer through the
// accelerator over AXI. That is the whole point of Phase 4.
//=============================================================================
module soc_prog_tb;
  logic clk = 0; always #5 clk = ~clk;
  logic rst;
  logic halted;
  logic [31:0] dbg_result;

  rv32i_soc_axi #(.PROGRAM("../sw/fw/prog.hex"), .N(4)) u_soc (
    .clk(clk), .rst(rst), .halted(halted), .dbg_result(dbg_result)
  );

  int cyc = 0;
  always_ff @(posedge clk) cyc <= cyc + 1;

  initial begin
    rst = 1;
    repeat(4) @(negedge clk); rst = 0;

    // run until the program writes the mailbox, or timeout
    wait (dbg_result == 32'h600D600D || dbg_result == 32'hBAD0BAD0 || cyc > 20000);

    repeat(2) @(negedge clk);
    $display("");
    $display("  cycles run        : %0d", cyc);
    $display("  result mailbox    : %08h", dbg_result);
    if (dbg_result == 32'h600D600D)
      $display("\nSOC PROGRAM TB: PASS - CPU ran compiled C, computed the layer over AXI, result verified in software");
    else if (dbg_result == 32'hBAD0BAD0)
      $display("\nSOC PROGRAM TB: FAIL - program ran but result mismatch");
    else
      $display("\nSOC PROGRAM TB: TIMEOUT - program did not finish (mailbox=%08h)", dbg_result);
    $finish;
  end

  initial begin #400000; $display("HARD TIMEOUT"); $finish; end
endmodule
