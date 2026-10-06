# RISC-V AXI4-Lite SoC with an integrated NN accelerator

A 32-bit RISC-V (RV32I) core and a 4×4 weight-stationary systolic neural-network
accelerator integrated into one system over an AMBA AXI4-Lite interconnect, with
bare-metal C firmware (compiled with riscv-gcc) running on the core that drives
the accelerator. Verified end to end in simulation, including under randomized
bus backpressure.

## What works (all verified in sim — `cd sim && make <target>`)
| Target     | Proves                                                               |
|------------|---------------------------------------------------------------------|
| `axi`      | AXI4-Lite master ↔ slave, full 5-channel VALID/READY handshake      |
| `decoder`  | address decode with no page aliasing + DECERR on unmapped access    |
| `layer`    | accelerator computes a layer over AXI, matches Python reference     |
| `stall`    | same layer correct under random AXI backpressure                    |
| `socprog`  | **CPU runs compiled C that drives the accelerator over AXI**         |

## Architecture
- **Instruction fetch:** tightly-coupled single-cycle IMEM (full speed).
- **Data path:** core data port → light AXI bridge → single-cycle AXI4-Lite
  slaves (DMEM, accelerator), selected by an address decoder. The verified core
  is left untouched (no pipeline surgery); multi-cycle-handshake robustness is
  proven separately in the stall bench.
- **Accelerator:** driven over AXI via a memory-mapped register interface
  (weights, activations, CTRL/STATUS, results).

## Memory map (data side)
| Base         | Device             |
|--------------|--------------------|
| 0x0000_0000  | IMEM (instruction) |
| 0x1000_0000  | DMEM (data)        |
| 0x2000_0000  | NN accelerator     |

## Firmware (bare-metal C)
`sw/fw/` — `start.s` (startup), `link.ld` (linker script), `main.c` (driver),
`build.sh` (riscv-gcc → prog.hex). Builds to RV32I, no stdlib. The program
streams the matrix/vector to the accelerator over AXI, starts it, polls, reads
results, checks them in software, and writes a pass/fail code to a mailbox.

## Build + run
    cd sw/fw && ./build.sh        # needs riscv64-unknown-elf-gcc
    cd ../../sim && make socprog  # loads prog.hex, runs the SoC -> PASS

## Milestone status (against the SoC design spec)
- [x] Phase 1: AXI4-Lite master wrapper on the core
- [x] Phase 2: GPIO slave + end-to-end handshake
- [x] Address decoder + DECERR (fixes page-aliasing)
- [x] Phase 5: accelerator wrapped as an AXI4-Lite IP block
- [x] Phase 6: end-to-end layer compute over AXI vs reference, incl. under stalls
- [x] Phase 4: bare-metal C on the core drives the accelerator over AXI
- [ ] Phase 3: UART console (optional)
- [ ] Phase 7: FPGA synthesis + timing closure + PPA numbers (Vivado)

## Notes
- The legacy custom-bus integration (`rtl/soc_bus.sv`, `make bus`) is the earlier
  milestone that predates the AXI4-Lite version; kept for history.
- Spec corrections folded in: 64→16→10 MLP is TWO layer passes (not three);
  start with polling (RV32I base has no trap/CSR hardware); PPA = LUT/FF/BRAM/DSP
  + timing + a labeled power estimate, reported separately.
