// main.c - bare-metal driver: run one NN layer on the accelerator over AXI,
// check the result against values computed in software, report pass/fail.
#include "accel.h"

// 4x4 int8 weight matrix and 4-vector (match sw/layer_vec: regenerated below
// into these constants by the build so hardware and software agree).
#include "layer_data.h"   // defines W[4][4], A[4], N

int main(void) {
    // reset the accelerator's write pointers
    REG(A_CTRL) = CTRL_RSTCNT;

    // stream weights row-major, then activations
    for (int r = 0; r < N; r++)
        for (int c = 0; c < N; c++)
            REG(A_WEIGHT) = (uint32_t)(int32_t)W[r][c];
    for (int r = 0; r < N; r++)
        REG(A_ACT) = (uint32_t)(int32_t)A[r];

    // start the compute
    REG(A_CTRL) = CTRL_START;

    // poll until done
    while ((REG(A_STATUS) & STATUS_DONE) == 0) { }

    // read results and compare to the software reference
    int ok = 1;
    for (int c = 0; c < N; c++) {
        int32_t golden = 0;
        for (int r = 0; r < N; r++) golden += (int32_t)W[r][c] * (int32_t)A[r];
        int32_t hw = (int32_t)REG(A_RES0 + c*4);
        if (hw != golden) ok = 0;
    }

    // write pass/fail to the mailbox the testbench watches
    RESULT_MBOX = ok ? 0x600D600Du : 0xBAD0BAD0u;
    return 0;
}
