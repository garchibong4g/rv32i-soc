// accel.h - memory-mapped NN accelerator (AXI slave at 0x2000_0000)
#ifndef ACCEL_H
#define ACCEL_H
#include <stdint.h>
#define ACCEL_BASE 0x20000000u
#define REG(off)   (*(volatile uint32_t*)(ACCEL_BASE + (off)))
#define A_WEIGHT   0x00
#define A_ACT      0x04
#define A_CTRL     0x08
#define A_STATUS   0x0C
#define A_RES0     0x10
#define CTRL_START    0x1
#define CTRL_RSTCNT   0x2
#define STATUS_DONE   0x1
#define RESULT_MBOX (*(volatile uint32_t*)0x10000FFC)  // pass/fail mailbox
#endif
