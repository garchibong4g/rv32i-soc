# Makefile - RV32I SoC simulation (Icarus Verilog)
#   make bus    - interconnect + accelerator-through-bus test

IV  = iverilog -g2012
VVP = vvp

CORE = ../rtl/rv32i_pkg.sv ../rtl/alu32.sv ../rtl/regfile32.sv ../rtl/imm_gen.sv \
       ../rtl/branch_unit.sv ../rtl/control_unit.sv ../rtl/lsu.sv ../rtl/rv32i_core.sv
ACCEL = ../rtl/mac_pe.sv ../rtl/systolic_array.sv ../rtl/nn_accel.sv
MEM  = ../rtl/dmem.sv ../rtl/imem.sv

.PHONY: bus clean
bus:
	$(IV) -o build_bus.vvp $(ACCEL) ../rtl/dmem.sv ../rtl/soc_bus.sv ../tb/soc_bus_tb.sv
	$(VVP) build_bus.vvp

clean:
	rm -f *.vvp

axi:
	$(IV) -o axi.vvp ../rtl/axi/axi4lite_master.sv ../rtl/axi/axi4lite_gpio.sv ../tb/axi/axi_m2s_tb.sv
	$(VVP) axi.vvp

decoder:
	$(IV) -o dec.vvp ../rtl/axi/axi_decoder.sv ../tb/axi/axi_decoder_tb.sv
	$(VVP) dec.vvp

layer:
	$(IV) -o layer.vvp ../rtl/mac_pe.sv ../rtl/systolic_array.sv ../rtl/nn_accel.sv ../rtl/axi/axi4lite_master.sv ../rtl/axi/axi4lite_accel.sv ../tb/axi/axi_layer_tb.sv
	$(VVP) layer.vvp

stall:
	$(IV) -o stall.vvp ../rtl/mac_pe.sv ../rtl/systolic_array.sv ../rtl/nn_accel.sv ../rtl/axi/axi4lite_master.sv ../rtl/axi/axi4lite_accel.sv ../tb/axi/axi_stall_tb.sv
	$(VVP) stall.vvp

axi-all: axi decoder layer stall

# full SoC: CPU runs compiled C firmware, drives accelerator over AXI
socprog:
	$(IV) -o soc_prog.vvp ../rtl/rv32i_pkg.sv ../rtl/alu32.sv ../rtl/regfile32.sv ../rtl/imm_gen.sv ../rtl/branch_unit.sv ../rtl/control_unit.sv ../rtl/lsu.sv ../rtl/rv32i_core.sv ../rtl/imem.sv ../rtl/axi_dmem_sc.sv ../rtl/mac_pe.sv ../rtl/systolic_array.sv ../rtl/nn_accel.sv ../rtl/axi/axi4lite_accel_sc.sv ../rtl/rv32i_soc_axi.sv ../tb/axi/soc_prog_tb.sv
	$(VVP) soc_prog.vvp
