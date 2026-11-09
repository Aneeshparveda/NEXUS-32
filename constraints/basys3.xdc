# Digilent Basys-3 rev-B board pins (XC7A35T-1CPG236C).
# Source of truth: https://github.com/Digilent/digilent-xdc/blob/master/Basys-3-Master.xdc
# LED indicators are active high in top_basys3.sv.

# Configuration bank voltage, as in Digilent's master XDC (avoids CFGBVS DRC).
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

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

# USB-UART bridge: FPGA transmit to the PC (Digilent name RsTx).
set_property PACKAGE_PIN A18 [get_ports {uart_tx}]
set_property IOSTANDARD LVCMOS33 [get_ports {uart_tx}]
