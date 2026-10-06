# Phase 4 — a program on the core drives the accelerator over AXI

## Architecture decision (kept the verified core untouched)
The RV32I core has single-cycle memory ports and no external stall input.
Rather than cut into the verified pipeline's MEM stage to handle multi-cycle
stalls, this SoC:
  - keeps INSTRUCTION fetch on tightly-coupled single-cycle IMEM (full speed);
  - routes the DATA port through a light AXI bridge to SINGLE-CYCLE AXI slaves
    (DMEM and the accelerator), so the core's 1-cycle data latency is satisfied
    and the pipeline never stalls.
This is a standard real-world pattern (tightly-coupled memory + AXI peripherals)
and avoids re-verifying the core. The accelerator's multi-cycle-backpressure
robustness is proven separately in the stall testbench (make stall).

## RTL
- `rv32i_soc_axi.sv`      — full SoC top: core + IMEM + data AXI bridge + decoder
                            + DMEM + accelerator, with a result mailbox.
- `axi4lite_accel_sc.sv`  — single-cycle-response AXI4-Lite accelerator slave.
- `axi_dmem_sc.sv`        — single-cycle data memory.

## Proof
`make socprog`: loads the riscv-gcc-compiled firmware, runs the SoC, and the
program writes 0x600D600D to the mailbox — the CPU computed the layer over AXI
and verified it in software. ~213 cycles.
