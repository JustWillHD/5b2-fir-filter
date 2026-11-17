# Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html for more info
#
#   make                          RTL simulation of the default configuration
#   make TB_NTAPS=12 TB_ARCH=1    RTL simulation of another configuration
#   make GATES=yes                gate-level simulation (netlist from the GDS action)

# defaults
SIM ?= icarus
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../src
PROJECT_SOURCES = project.v fir_core.v

ifneq ($(GATES),yes)

# RTL simulation:
SIM_BUILD				= sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
ifdef TB_NTAPS
SIM_BUILD       = sim_build/rtl_n$(TB_NTAPS)_a$(TB_ARCH)
COMPILE_ARGS    += -DTB_NTAPS=$(TB_NTAPS) -DTB_ARCH=$(TB_ARCH)
export FIR_NTAPS = $(TB_NTAPS)
endif

else

# Gate level simulation:
SIM_BUILD				= sim_build/gl
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DUSE_POWER_PINS
COMPILE_ARGS    += -DSIM
COMPILE_ARGS    += -DUNIT_DELAY=\#1
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v

# this gets copied in by the GDS action workflow
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v

endif

# Allow sharing configuration between design and testbench via `include`:
COMPILE_ARGS 		+= -I$(SRC_DIR)

# Include the testbench sources:
VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb
COCOTB_TOPLEVEL = tb

# MODULE is the basename of the Python test file
MODULE = test
COCOTB_TEST_MODULES = test

# include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim
