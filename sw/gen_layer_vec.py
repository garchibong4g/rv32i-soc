#!/usr/bin/env python3
# Generates sw/layer_vec.hex: 16 int8 weights + 4 int8 activations + 4 golden
# int32 results (out[c] = sum_r W[r][c]*a[r]) for the end-to-end AXI layer test.
import random
random.seed(7)
N=4
W=[[random.randint(-50,50) for _ in range(N)] for _ in range(N)]
a=[random.randint(-50,50) for _ in range(N)]
out=[sum(W[r][c]*a[r] for r in range(N)) for c in range(N)]
with open("layer_vec.hex","w") as f:
    for r in range(N):
        for c in range(N): f.write("%08x\n"%(W[r][c]&0xFFFFFFFF))
    for r in range(N): f.write("%08x\n"%(a[r]&0xFFFFFFFF))
    for c in range(N): f.write("%08x\n"%(out[c]&0xFFFFFFFF))
print("golden out =",out)
