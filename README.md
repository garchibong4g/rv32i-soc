# RV32I SoC — bus + accelerator integration

Turns the RV32I core and the systolic NN accelerator into a system-on-chip: the
core's data port is a bus master into `soc_bus`, which decodes the address to
data RAM, a GPIO/LED register, and the memory-mapped accelerator. The CPU drives
the accelerator with ordinary load/store instructions through the interconnect.

## Memory map
| Region (addr[31:12]) | Base        | Device                          |
|----------------------|-------------|---------------------------------|
| 0x00000              | 0x0000_0000 | instruction memory (fetch port) |
| 0x00001              | 0x0000_1000 | data RAM                        |
| 0x00002              | 0x0000_2000 | GPIO out (LEDs / debug)         |
| 0x00003              | 0x0000_3000 | NN accelerator (regs 0x3000..1C)|

## RTL
- `rtl/soc_bus.sv`   — the interconnect: address decode, write routing, registered read mux
- `rtl/rv32i_soc.sv` — top level: core + bus + RAM + GPIO + accelerator
- plus the RV32I core and accelerator RTL (from the rv32i-pipeline and nn-accelerator repos)

## Run
    cd sim && make bus     # interconnect + accelerator-through-bus test

## Milestone status
- [x] M1: peripheral bus, accelerator + GPIO + RAM on it, verified in sim
- [ ] M2: bare-metal bring-up on Basys 3 (core + bus + one peripheral, C via riscv-gcc)
- [ ] M3: UART peripheral + bootloader + Python flash tool

## A design note worth keeping
The RAM and GPIO have **registered** reads (1-cycle latency); the accelerator
has a **combinational** read. The bus serves both — it registers the region
select and the master samples read data while still selected. A fully uniform
bus would register the accelerator's read data too, so every slave shares one
latency contract; noted as a cleanup.
