# NEXUS-32: program the Basys 3 with the best available board build.
#
# Usage (from the repository root):
#   vivado -mode batch -source vivado/program_board.tcl -tclargs [<build>]
# <build> is a folder name under results/vivado/ (for example basys3_l8).
# Without it, the first build in PREFERENCE that passed the flow, passed the
# IMEM check and met timing is used; if none met timing, the first passing
# build is used with a warning (functional check only, not timing evidence).
#
# NEXUS32_PROGRAM_DRY_RUN=1 selects and records the build without touching
# hardware (used by the offline test).

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set board_root [file join $root_dir results vivado]
set evidence_dir [file join $root_dir results evidence]

set PREFERENCE [list basys3_l8 basys3_l8_50mhz basys3_l8_25mhz \
                     basys3_l4 basys3_l4_50mhz basys3_l4_25mhz \
                     basys3_l16 basys3_l16_50mhz basys3_l16_25mhz]

proc read_metrics {path} {
    set values [dict create]
    if {![file exists $path]} {
        return $values
    }
    set fp [open $path r]
    foreach line [split [read $fp] "\n"] {
        if {[regexp {^([A-Za-z0-9_]+)=(.*)$} [string trim $line] -> key value]} {
            dict set values $key $value
        }
    }
    close $fp
    return $values
}

proc metric {values key} {
    if {[dict exists $values $key]} {
        return [dict get $values $key]
    }
    return ""
}

# Returns {build bitstream timing_met note}.
proc choose_build {board_root preference requested} {
    if {$requested ne ""} {
        set bit [file join $board_root $requested top_basys3.bit]
        if {![file exists $bit]} {
            error "requested build '$requested' has no bitstream at $bit"
        }
        set metrics [read_metrics [file join $board_root $requested metrics.txt]]
        return [list $requested $bit [metric $metrics TIMING_MET] "requested on the command line"]
    }
    set candidates [list]
    foreach build $preference {
        set metrics [read_metrics [file join $board_root $build metrics.txt]]
        set bit [file join $board_root $build top_basys3.bit]
        if {[metric $metrics BUILD_STATUS] eq "PASS" && [metric $metrics IMEM_INIT_CHECK] eq "PASS" &&
            [file exists $bit]} {
            lappend candidates [list $build $bit [metric $metrics TIMING_MET]]
        }
    }
    foreach candidate $candidates {
        if {[lindex $candidate 2] eq "YES"} {
            return [concat $candidate [list "first passing build that met timing"]]
        }
    }
    if {[llength $candidates] > 0} {
        return [concat [lindex $candidates 0] \
            [list "WARNING: no build met timing; functional check only, not timing evidence"]]
    }
    error "no programmable build found under $board_root (need BUILD_STATUS=PASS, IMEM_INIT_CHECK=PASS and top_basys3.bit); run RUN_ALL.bat or RUN_VIVADO_BASYS3.bat first"
}

set requested ""
if {[llength $argv] >= 1} {
    set requested [lindex $argv 0]
}
if {[catch {choose_build $board_root $PREFERENCE $requested} choice]} {
    puts stderr "ERROR: $choice"
    exit 1
}
lassign $choice build bitstream timing_met note
puts "Selected build : $build ($note)"
puts "Bitstream      : $bitstream"
puts "Timing met     : $timing_met"

set dry_run [expr {[info exists ::env(NEXUS32_PROGRAM_DRY_RUN)] && $::env(NEXUS32_PROGRAM_DRY_RUN) eq "1"}]
set status "DRY_RUN"
if {!$dry_run} {
    set rc [catch {
        open_hw_manager
        if {[catch {connect_hw_server -allow_non_jtag}]} {
            connect_hw_server
        }
        if {[catch {open_hw_target} target_message]} {
            error "no board found ($target_message). Check the USB cable, the power switch (ON), and that the Digilent/FTDI cable driver is installed."
        }
        set device [lindex [get_hw_devices -quiet xc7a35t*] 0]
        if {$device eq ""} {
            error "the connected target has no xc7a35t device: [get_hw_devices -quiet]"
        }
        current_hw_device $device
        refresh_hw_device -update_hw_probes false $device
        set_property PROGRAM.FILE $bitstream $device
        program_hw_devices $device
        refresh_hw_device -update_hw_probes false $device
    } program_message]
    catch {close_hw_target}
    catch {disconnect_hw_server}
    catch {close_hw_manager}
    if {$rc != 0} {
        puts stderr "ERROR: programming failed: $program_message"
        exit 1
    }
    set status "PROGRAMMED"
}

file mkdir $evidence_dir
set fp [open [file join $evidence_dir programmed_build.txt] w]
puts $fp "BUILD=$build"
puts $fp "BITSTREAM=$bitstream"
puts $fp "TIMING_MET=$timing_met"
puts $fp "SELECTION=$note"
puts $fp "STATUS=$status"
puts $fp "TIME_UTC=[clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%SZ} -gmt 1]"
close $fp
puts "Board status   : $status. Expect LD0 and LD2 on, LD3 off; then run READ_UART.bat."
exit 0
