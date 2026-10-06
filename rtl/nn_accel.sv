//=============================================================================
// nn_accel.sv - memory-mapped wrapper around the systolic array
//
// Turns the raw systolic_array datapath into a device the RV32I core drives
// with ordinary load/store instructions. The CPU writes the weight matrix and
// the activation vector into the accelerator, writes a "go" bit, polls a done
// bit, and reads the results back - exactly the memory-mapped pattern used for
// the console's LEDs and seven-segment display, applied to a compute engine.
//
// REGISTER MAP (offsets from the base address decoded by the SoC)
//   0x00  WEIGHT   (W)  write a weight; an internal counter places it into the
//                       next PE, row-major. Write N*N weights to fill the grid.
//   0x04  ACT      (W)  write an activation; fills the N-element input vector.
//   0x08  CTRL     (W)  bit0 = start (self-clearing), bit1 = reset the weight
//                       and activation write counters.
//   0x0C  STATUS   (R)  bit0 = done (result valid), bit1 = busy.
//   0x10  RESULT0  (R)  output[0]
//   0x14  RESULT1  (R)  output[1]
//   0x18  RESULT2  (R)  output[2]
//   0x1C  RESULT3  (R)  output[3]
//
// The FSM reproduces in hardware what a testbench did by hand: pulse load_w to
// latch the stationary weights, then stream the activation vector SKEWED (row r
// enters r cycles after row 0) so the diagonal wave aligns, and capture each
// column's result the cycle it reaches the south edge (column c at cycle c+N
// after streaming begins).
//=============================================================================
module nn_accel #(
  parameter int N = 4
)(
  input  logic        clk,
  input  logic        rst,

  // simple memory-mapped slave interface (already address-decoded by the SoC)
  input  logic        sel,          // this device is selected
  input  logic        we,           // write enable
  input  logic [4:0]  addr,         // register offset (byte address, low 5 bits)
  input  logic [31:0] wdata,
  output logic [31:0] rdata
);

  // ------------------------------------------------------------------
  // Register offsets
  // ------------------------------------------------------------------
  localparam logic [4:0] REG_WEIGHT = 5'h00;
  localparam logic [4:0] REG_ACT    = 5'h04;
  localparam logic [4:0] REG_CTRL   = 5'h08;
  localparam logic [4:0] REG_STATUS = 5'h0C;
  localparam logic [4:0] REG_RES0   = 5'h10;   // RES1..3 are +4 each

  // ------------------------------------------------------------------
  // Input buffers, filled by CPU writes
  // ------------------------------------------------------------------
  logic signed [7:0]  weight_buf [N*N];
  logic signed [7:0]  act_buf    [N];

  logic [$clog2(N*N+1)-1:0] w_count;   // next weight slot
  logic [$clog2(N+1)-1:0]   a_count;   // next activation slot

  // ------------------------------------------------------------------
  // Control / status
  // ------------------------------------------------------------------
  logic start_pulse;
  logic busy, done;

  // ------------------------------------------------------------------
  // Systolic array instance and its drive signals
  // ------------------------------------------------------------------
  logic               arr_en, arr_load_w, arr_rst;
  logic signed [7:0]  arr_w    [N*N];
  logic signed [7:0]  arr_act  [N];
  logic [N*32-1:0]    arr_out;

  // weights are static once loaded; drive straight from the buffer
  genvar gi;
  generate
    for (gi = 0; gi < N*N; gi++) assign arr_w[gi] = weight_buf[gi];
  endgenerate

  systolic_array #(.N(N)) u_arr (
    .clk        (clk),
    .rst        (arr_rst),
    .en         (arr_en),
    .load_w     (arr_load_w),
    .w_load     (arr_w),
    .act_west   (arr_act),
    .psum_south (arr_out)
  );

  // captured results
  logic signed [31:0] result [N];

  // ------------------------------------------------------------------
  // Control FSM
  // ------------------------------------------------------------------
  typedef enum logic [2:0] { S_IDLE, S_CLEAR, S_LOAD, S_STREAM, S_DONE } state_e;
  state_e state;

  // streaming/capture cycle counter
  logic [$clog2(3*N+1)-1:0] cyc;
  int si, sc;

  always_ff @(posedge clk) begin
    if (rst) begin
      state      <= S_IDLE;
      busy       <= 1'b0;
      done       <= 1'b0;
      arr_en     <= 1'b0;
      arr_load_w <= 1'b0;
      arr_rst    <= 1'b1;
      cyc        <= '0;
      for (si = 0; si < N; si++) begin
        arr_act[si] <= 8'sd0;
        result[si]  <= 32'sd0;
      end
    end else begin
      // defaults each cycle
      arr_load_w <= 1'b0;

      case (state)
        // --------------------------------------------------------
        S_IDLE: begin
          arr_rst <= 1'b1;             // hold the array cleared while idle
          arr_en  <= 1'b0;
          if (start_pulse) begin
            busy    <= 1'b1;
            done    <= 1'b0;
            cyc     <= '0;
            state   <= S_CLEAR;
          end
        end

        // --------------------------------------------------------
        // reset the array for one cycle so no partial sums survive from a
        // previous computation, then load the new weights.
        S_CLEAR: begin
          arr_rst <= 1'b1;
          arr_en  <= 1'b0;
          state   <= S_LOAD;
        end

        // --------------------------------------------------------
        // latch the stationary weights (one cycle pulse of load_w)
        S_LOAD: begin
          arr_rst    <= 1'b0;
          arr_load_w <= 1'b1;
          cyc        <= '0;
          state      <= S_STREAM;
        end

        // --------------------------------------------------------
        // stream activations skewed, run the wave, capture results
        S_STREAM: begin
          arr_en <= 1'b1;

          // present activation for each row on its skewed cycle:
          // row r's activation enters at cycle r.
          for (si = 0; si < N; si++)
            arr_act[si] <= (cyc == si[$bits(cyc)-1:0]) ? act_buf[si] : 8'sd0;

          // capture column c the cycle its result reaches the output register.
          // Relative to this counter the activation stream begins at cyc==1 and
          // the array adds an output-register cycle, so column c lands at
          // cyc == c + N + 2 (observed: col0 at cyc 6 for N=4).
          for (sc = 0; sc < N; sc++)
            if (cyc == (sc + N + 2))
              result[sc] <= $signed(arr_out[sc*32 +: 32]);

          // finished once the last column (c = N-1) has been captured
          if (cyc == (N-1) + N + 2) begin
            arr_en <= 1'b0;
            busy   <= 1'b0;
            done   <= 1'b1;
            state  <= S_DONE;
          end
          cyc <= cyc + 1'b1;
        end

        // --------------------------------------------------------
        S_DONE: begin
          // results held; a new start clears the array then reloads
          if (start_pulse) begin
            busy    <= 1'b1;
            done    <= 1'b0;
            cyc     <= '0;
            state   <= S_CLEAR;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // CPU write path: fill buffers, generate the start pulse
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      w_count     <= '0;
      a_count     <= '0;
      start_pulse <= 1'b0;
    end else begin
      start_pulse <= 1'b0;             // one-cycle pulse

      if (sel && we) begin
        case (addr)
          REG_WEIGHT: begin
            weight_buf[w_count] <= $signed(wdata[7:0]);
            if (w_count < N*N-1) w_count <= w_count + 1'b1;
          end
          REG_ACT: begin
            act_buf[a_count] <= $signed(wdata[7:0]);
            if (a_count < N-1) a_count <= a_count + 1'b1;
          end
          REG_CTRL: begin
            if (wdata[0]) start_pulse <= 1'b1;   // start
            if (wdata[1]) begin                  // reset write counters
              w_count <= '0;
              a_count <= '0;
            end
          end
          default: ;
        endcase
      end
    end
  end

  // ------------------------------------------------------------------
  // CPU read path
  // ------------------------------------------------------------------
  always_comb begin
    rdata = 32'h0;
    if (sel && !we) begin
      case (addr)
        REG_STATUS: rdata = {30'h0, busy, done};
        REG_RES0:      rdata = result[0];
        (REG_RES0+5'h4): rdata = result[1];
        (REG_RES0+5'h8): rdata = result[2];
        (REG_RES0+5'hC): rdata = result[3];
        default:      rdata = 32'h0;
      endcase
    end
  end

endmodule
