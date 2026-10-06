//=============================================================================
// soc_bus.sv - memory-mapped interconnect for the RV32I SoC
//
// Sits between the core's data port (a bus master) and the peripherals. It
// decodes the address into one of N regions, routes the write strobe to the
// selected slave, and muxes the correct slave's read data back to the core.
//
// This generalizes the two-way (RAM vs GPIO) decode that lived inline in
// rv32i_top into a proper interconnect: one master, several slaves, a fixed
// address map decoded on bits [31:12] (4 KB regions).
//
// TIMING CONTRACT
//   The core's data port is synchronous-read with one cycle of latency: the
//   address is presented in cycle T and rdata is valid in cycle T+1. Every
//   slave here follows the same contract. So the read-data mux select must be
//   the *registered* region select (which slave was addressed last cycle),
//   exactly the sel_gpio_q trick from the original top - generalized to N.
//
// REGION MAP (decoded on dmem_addr[31:12])
//   0x00001  RAM          (data memory)
//   0x00002  GPIO         (output register: LEDs / debug)
//   0x00003  ACCEL        (nn_accel systolic accelerator)
//   0x00004  UART         (added in a later milestone)
//   0x00005  TIMER        (added later)
// Anything else reads as zero and ignores writes.
//=============================================================================
module soc_bus (
  input  logic        clk,
  input  logic        rst,

  // ---- master side: the core's data port ----
  input  logic [31:0] m_addr,
  input  logic [31:0] m_wdata,
  input  logic [3:0]  m_be,
  input  logic        m_we,
  input  logic        m_re,
  output logic [31:0] m_rdata,

  // ---- slave 0: RAM ----
  output logic        ram_we,
  output logic [3:0]  ram_be,
  output logic [31:0] ram_addr,
  output logic [31:0] ram_wdata,
  input  logic [31:0] ram_rdata,

  // ---- slave 1: GPIO ----
  output logic        gpio_we,
  output logic [31:0] gpio_wdata,
  input  logic [31:0] gpio_rdata,

  // ---- slave 2: accelerator ----
  output logic        accel_sel,
  output logic        accel_we,
  output logic [4:0]  accel_addr,
  output logic [31:0] accel_wdata,
  input  logic [31:0] accel_rdata
);

  // ---- region select (combinational, this cycle) ----
  localparam logic [19:0] REGION_RAM   = 20'h00001;
  localparam logic [19:0] REGION_GPIO  = 20'h00002;
  localparam logic [19:0] REGION_ACCEL = 20'h00003;

  logic [19:0] region;
  assign region = m_addr[31:12];

  logic sel_ram, sel_gpio, sel_accel;
  assign sel_ram   = (region == REGION_RAM);
  assign sel_gpio  = (region == REGION_GPIO);
  assign sel_accel = (region == REGION_ACCEL);

  // ---- write routing: only the addressed slave sees the write strobe ----
  assign ram_we   = m_we && sel_ram;
  assign gpio_we  = m_we && sel_gpio;
  assign accel_sel = (m_we || m_re) && sel_accel;
  assign accel_we  = m_we && sel_accel;

  // ---- fan the shared write bus out to every slave ----
  assign ram_be    = m_be;
  assign ram_addr  = m_addr;
  assign ram_wdata = m_wdata;

  assign gpio_wdata = m_wdata;

  assign accel_addr  = m_addr[4:0];   // slave's local register offset
  assign accel_wdata = m_wdata;

  // ---- read mux: select the slave addressed LAST cycle (1-cycle latency) ----
  // Register which region was selected, then use it to pick the read source,
  // matching the synchronous-read timing of the core and all slaves.
  logic sel_ram_q, sel_gpio_q, sel_accel_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      sel_ram_q   <= 1'b0;
      sel_gpio_q  <= 1'b0;
      sel_accel_q <= 1'b0;
    end else begin
      sel_ram_q   <= sel_ram;
      sel_gpio_q  <= sel_gpio;
      sel_accel_q <= sel_accel;
    end
  end

  always_comb begin
    if      (sel_gpio_q)  m_rdata = gpio_rdata;
    else if (sel_accel_q) m_rdata = accel_rdata;
    else                  m_rdata = ram_rdata;   // RAM is the default
  end

endmodule
