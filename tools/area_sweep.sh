#!/usr/bin/env bash
# Yosys area sweep: ./tools/area_sweep.sh /path/to/sky130_fd_sc_hd__tt_025C_1v80.lib
LIB=$1
echo "ntaps,arch,area"
for A in 0 1 2 3 4; do for N in 2 4 6 8 10 12 16; do
  yosys -q -p "read_verilog -sv src/fir_core.v src/project.v; chparam -set NTAPS $N -set ARCH $A tt_um_justwillhd_fir; synth -top tt_um_justwillhd_fir -flatten; dfflibmap -liberty $LIB; abc -liberty $LIB; opt_clean; tee -o /tmp/stat.txt stat -liberty $LIB" >/dev/null
  echo "$N,$A,$(grep 'Chip area' /tmp/stat.txt | awk '{print $NF}')"
done; done
