# Digilent Basys-3 rev-B board pins (XC7A35T-1CPG236C).
# Source of truth: https://github.com/Digilent/digilent-xdc/blob/master/Basys-3-Master.xdc
# LED indicators are active high in top_basys3.sv.

set_property PACKAGE_PIN W5 [get_ports {clk_100mhz}]
set_property IOSTANDARD LVCMOS33 [get_ports {clk_100mhz}]
create_clock -name sys_clk_pin -period 10.000 -waveform {0.000 5.000} [get_ports {clk_100mhz}]

set_property PACKAGE_PIN U18 [get_ports {btn_center}]
set_property IOSTANDARD LVCMOS33 [get_ports {btn_center}]

set_property PACKAGE_PIN U16 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]
set_property PACKAGE_PIN E19 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]
set_property PACKAGE_PIN U19 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]
set_property PACKAGE_PIN V19 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]
