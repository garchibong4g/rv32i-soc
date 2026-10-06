# AXI4-Lite SoC — integration proven end to end

The RV32I core + systolic NN accelerator, connected over real AMBA AXI4-Lite,
with the integration verified by computing a neural-network layer over the bus
and matching an independent Python reference — including under random bus
backpressure.

## RTL
- `axi4lite_master.sv` — AXI4-Lite master wrapper on the core's data port
  (5 channels, VALID/READY, single outstanding transaction).
- `axi_decoder.sv`     — address decoder + one-hot slave select + DECERR flag.
  Decodes full page tags (addr[31:12]) so the 0x3000_0/1/2 peripheral pages
  (UART/TIMER/GPIO) do NOT alias — corrects the spec's "top nibble only" claim —
  and flags unmapped addresses for a DECERR response.
- `axi4lite_gpio.sv`   — AXI4-Lite GPIO slave (LEDs/switches).
- `axi4lite_accel.sv`  — AXI4-Lite slave wrapper around nn_accel: the headline
  IP integration. Translates AXI reads/writes into the accelerator's register
  port; holds sel through the read-data phase for its combinational read.

## Verification (make <target> from sim/)
- `axi`      — master↔GPIO-slave handshake, both directions.
- `decoder`  — page decode with no aliasing + DECERR on unmapped.
- `layer`    — END TO END: drive the accelerator over AXI (stream weights +
               activations, start, poll STATUS, read results); the computed
               matrix-vector layer matches the Python golden model.
- `stall`    — the same layer compute under RANDOM AXI backpressure (READY/VALID
               throttled ~30% of cycles); still matches golden across seeds.
- `axi-all`  — full AXI regression.

## What this proves (vs. the spec, which was a plan)
A layer is computed by the accelerator driven ENTIRELY over AXI4-Lite and the
result matches an independent reference, even when every channel stalls at
random. That is working integration with meaningful verification — not just an
architecture document.

## Real bugs found and fixed here
- Address aliasing: UART/TIMER/GPIO share top nibble 0x3; full-page decode fixes
  it (reviewer-flagged, now provably separated + DECERR added).
- Read-data clobber: the accel AXI wrapper re-captured S_RDATA on the 2nd R_DATA
  cycle (sel low → 0), zeroing the first read of a sequence. Found by the stall
  test; fixed by capturing only on the first R_DATA cycle.

## Icarus 12 testbench note
No `automatic` task variables (unsupported) — use named per-loop counters, and
never share one counter between a polling loop and the task it calls (that
collision silently zeroed a poll counter here).

## Spec corrections still to fold into the PDF
- 64→16→10 MLP = TWO weight matrices = two layer passes (spec said three).
- RV32I base has no trap/CSR hardware → start with POLLING, not interrupts.
- PPA = report LUT/FF/BRAM/DSP + timing slack + a labeled power ESTIMATE
  separately; CPI/latency alone isn't PPA.
- Drop the TPU/Trainium promotional comparisons; let results carry it.

## Spec phase status
- [x] Phase 1: AXI master wrapper
- [x] Phase 2: GPIO slave + handshake
- [x] Address decoder + DECERR (reviewer fix)
- [x] Phase 5: accelerator AXI4-Lite wrapper (IP integration)
- [x] Phase 6: end-to-end layer compute over AXI vs reference + under stalls
- [ ] Phase 3: UART slave (console)
- [ ] Phase 4: IMEM/DMEM as AXI slaves + run a program from the core
- [ ] Phase 7: FPGA synthesis + timing + PPA numbers
