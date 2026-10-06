import random
random.seed(7); N=4
W=[[random.randint(-50,50) for _ in range(N)] for _ in range(N)]
A=[random.randint(-50,50) for _ in range(N)]
with open("layer_data.h","w") as f:
    f.write("#ifndef LAYER_DATA_H\n#define LAYER_DATA_H\n#include <stdint.h>\n#define N %d\n"%N)
    f.write("static const int8_t W[N][N]={\n")
    for r in range(N): f.write("  {"+",".join(str(W[r][c]) for c in range(N))+"},\n")
    f.write("};\nstatic const int8_t A[N]={"+",".join(str(A[r]) for r in range(N))+"};\n#endif\n")
