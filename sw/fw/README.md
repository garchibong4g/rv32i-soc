# Bare-metal firmware — Phase 4

A C program, compiled with riscv-gcc to RV32I, that runs on the core and drives
the NN accelerator over AXI. This is the "working bus-based computer": the CPU
executes real instructions that compute a neural-network layer through the
accelerator — not a testbench poking the bus.

## Files
- `start.s`        — bare-metal startup: set stack pointer, call main(), park.
- `link.ld`        — linker script: code at IMEM 0x0000_0000, data at DMEM 0x1000_0000.
- `main.c`         — driver: stream weights+activations to the accelerator's AXI
                     registers, start, poll STATUS, read results, compare in
                     software, write 0x600D600D (pass) / 0xBAD0BAD0 (fail) to the
                     result mailbox at 0x1000_0FFC.
- `accel.h`        — memory-mapped accelerator register definitions.
- `gen_layer_data.py` / `layer_data.h` — the int8 weights/activations (same seed
                     as the hardware golden vector, so SW and HW agree).
- `build.sh`       — compile + link + objcopy + bin2hex → prog.hex.

## Build + run
    cd sw/fw && ./build.sh          # needs riscv64-unknown-elf-gcc
    cd ../../sim && make socprog    # loads prog.hex into IMEM, runs the SoC

Expected: `SOC PROGRAM TB: PASS` — the CPU ran compiled C, computed the layer
over AXI, verified the result in software. ~213 cycles.

## Toolchain
riscv64-unknown-elf-gcc, -march=rv32i -mabi=ilp32, freestanding/no-stdlib.
