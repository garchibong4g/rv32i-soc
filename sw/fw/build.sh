#!/bin/bash
# build.sh - compile the bare-metal firmware to IMEM hex (prog.hex)
set -e
GCC=riscv64-unknown-elf-gcc
OBJCOPY=riscv64-unknown-elf-objcopy
# regenerate layer_data.h (same seed as the hardware golden vector)
python3 gen_layer_data.py
$GCC -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding -O2 \
     -T link.ld start.s main.c -o fw.elf
$OBJCOPY -O binary --only-section=.text --only-section=.rodata fw.elf fw.bin
python3 bin2hex.py fw.bin prog.hex
echo "built prog.hex"
