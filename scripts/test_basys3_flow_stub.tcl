# Offline command stubs for the integrated Basys-3 Vivado flow.
#
# This driver does not model Vivado synthesis. It exercises the Tcl flow's
# stage ordering, required-artifact checks, summary generation, and exit-code
# propagation without requiring Vivado or a license.

set requested_argv $::argv
if {[llength $requested_argv] != 2} {
    puts stderr "usage: tclsh scripts/test_basys3_flow_stub.tcl <output_dir> <LANES>"
    exit 2
}

set stub_fail_stage ""
if {[info exists ::env(STUB_FAIL_STAGE)]} {
    set stub_fail_stage $::env(STUB_FAIL_STAGE)
}

proc version {args} {
    return "Vivado v2024.2-stub"
}

proc create_project {args} {
    set ::stub_project_open 1
}

proc current_project {} {
    if {[info exists ::stub_project_open] && $::stub_project_open} {
        return stub_project
    }
    return ""
}

proc close_project {} {
    set ::stub_project_open 0
}

proc current_fileset {} {
    return sources_1
}

proc current_design {} {
    return top_basys3
}

proc set_property {args} {}
proc read_verilog {args} {}
proc read_xdc {args} {}
proc synth_design {args} {}
proc opt_design {} {}
proc place_design {} {}

proc phys_opt_design {} {
    if {$::stub_fail_stage eq "phys_opt_design"} {
        error "stub phys_opt_design failure"
    }
}

proc route_design {} {
    if {$::stub_fail_stage eq "route_design"} {
        error "stub route_design failure"
    }
}

proc report_path {arglist} {
    set index [lsearch -exact $arglist -file]
    if {$index < 0 || $index + 1 >= [llength $arglist]} {
        error "stub report command did not receive -file: [list $arglist]"
    }
    return [lindex $arglist [expr {$index + 1}]]
}

proc write_stub_artifact {path contents} {
    file mkdir [file dirname $path]
    set fp [open $path w]
    puts $fp $contents
    close $fp
}

proc stub_report {arglist} {
    write_stub_artifact [report_path $arglist] "stub report"
}

proc report_utilization {args} { stub_report $args }
proc report_timing_summary {args} { stub_report $args }
proc report_timing {args} { stub_report $args }
proc report_clocks {args} { stub_report $args }
proc report_drc {args} { stub_report $args }

proc write_checkpoint {args} {
    write_stub_artifact [lindex $args end] "stub checkpoint"
}

proc write_bitstream {args} {
    write_stub_artifact [lindex $args end] "stub bitstream"
}

proc report_property {args} {
    write_stub_artifact [report_path $args] "stub properties"
}

set script_root [file normalize [file join [file dirname [info script]] ..]]
set argv $requested_argv
source [file join $script_root vivado build_basys3.tcl]
