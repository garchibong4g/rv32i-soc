//=============================================================================
// rv32i_soc.sv - RISC-V SoC: core + interconnect + RAM + GPIO + accelerator
//
// This is the "system" that rv32i_top only gestured at. The core's data port
// is a bus master into soc_bus, which decodes to data RAM, a GPIO/LED output
// register, and the memory-mapped systolic NN accelerator. Instruction fetch
// stays on its own dedicated port into imem (Harvard split, as before).
//
// The point of this module: the CPU drives the accelerator with ordinary
// load/store instructions routed through a real interconnect - not a hand-wired
// point-to-point link. Adding a peripheral means adding a region and a slave,
// nothing more.
//
// MEMORY MAP
//   0x0000_0000  instruction memory (fetch port)
//   0x0000_1xxx  data RAM
//   0x0000_2xxx  GPIO out (LEDs / debug register)
//   0x0000_3xxx  NN accelerator  (regs at 0x3000..0x301C)
//=============================================================================
module rv32i_soc #(
  parameter PROGRAM = "program.hex",
  parameter int N   = 4               // accelerator array size
)(
  input  logic        clk,
  input  logic        rst,
  output logic [31:0] gpio_out,
  output logic        halted
);

  // ---- core wires ----
  logic [31:0] imem_addr, imem_rdata;
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_be;
  logic        dmem_we, dmem_re, illegal_instr;
  logic [31:0] perf_cycles, perf_instrs, perf_stalls, perf_flushes;

  rv32i_core u_core (
    .clk           (clk),
    .rst           (rst),
    .imem_addr     (imem_addr),
    .imem_rdata    (imem_rdata),
    .dmem_addr     (dmem_addr),
    .dmem_wdata    (dmem_wdata),
    .dmem_be       (dmem_be),
    .dmem_we       (dmem_we),
    .dmem_re       (dmem_re),
    .dmem_rdata    (dmem_rdata),
    .halted        (halted),
    .illegal_instr (illegal_instr),
    .perf_cycles   (perf_cycles),
    .perf_instrs   (perf_instrs),
    .perf_stalls   (perf_stalls),
    .perf_flushes  (perf_flushes)
  );

  // ---- instruction memory (dedicated fetch port) ----
  imem #(.INIT_FILE(PROGRAM), .WORDS(4096)) u_imem (
    .clk   (clk),
    .addr  (imem_addr),
    .rdata (imem_rdata)
  );

  // ---- interconnect ----
  logic        ram_we;
  logic [3:0]  ram_be;
  logic [31:0] ram_addr, ram_wdata, ram_rdata;

  logic        gpio_we;
  logic [31:0] gpio_wdata, gpio_rdata;

  logic        accel_sel, accel_we;
  logic [4:0]  accel_addr;
  logic [31:0] accel_wdata, accel_rdata;

  soc_bus u_bus (
    .clk         (clk),
    .rst         (rst),
    .m_addr      (dmem_addr),
    .m_wdata     (dmem_wdata),
    .m_be        (dmem_be),
    .m_we        (dmem_we),
    .m_re        (dmem_re),
    .m_rdata     (dmem_rdata),
    .ram_we      (ram_we),
    .ram_be      (ram_be),
    .ram_addr    (ram_addr),
    .ram_wdata   (ram_wdata),
    .ram_rdata   (ram_rdata),
    .gpio_we     (gpio_we),
    .gpio_wdata  (gpio_wdata),
    .gpio_rdata  (gpio_rdata),
    .accel_sel   (accel_sel),
    .accel_we    (accel_we),
    .accel_addr  (accel_addr),
    .accel_wdata (accel_wdata),
    .accel_rdata (accel_rdata)
  );

  // ---- slave 0: data RAM ----
  dmem #(.WORDS(4096)) u_dmem (
    .clk   (clk),
    .we    (ram_we),
    .be    (ram_be),
    .addr  (ram_addr),
    .wdata (ram_wdata),
    .rdata (ram_rdata)
  );

  // ---- slave 1: GPIO output register ----
  always_ff @(posedge clk) begin
    if (rst)          gpio_out <= 32'h0;
    else if (gpio_we) gpio_out <= gpio_wdata;
  end
  assign gpio_rdata = gpio_out;

  // ---- slave 2: NN accelerator ----
  nn_accel #(.N(N)) u_accel (
    .clk   (clk),
    .rst   (rst),
    .sel   (accel_sel),
    .we    (accel_we),
    .addr  (accel_addr),
    .wdata (accel_wdata),
    .rdata (accel_rdata)
  );

endmodule
