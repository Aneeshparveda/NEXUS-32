# NEXUS-32 core-only comparison constraint.
# Target: 100 MHz (10.000 ns) clock on clk_i.
# I/O delays are set to 0.000 ns for uniform block-level out-of-context comparison.
# Clock and reset ports are explicitly excluded from data input delays.
create_clock -name core_clk -period 10.000 [get_ports {clk_i}]
set data_inputs [remove_from_collection [all_inputs] [get_ports {clk_i rst_i}]]
set_input_delay -clock [get_clocks core_clk] -max 0.000 $data_inputs
set_input_delay -clock [get_clocks core_clk] -min 0.000 $data_inputs
set_output_delay -clock [get_clocks core_clk] -max 0.000 [all_outputs]
set_output_delay -clock [get_clocks core_clk] -min 0.000 [all_outputs]
set_false_path -from [get_ports {rst_i}]
