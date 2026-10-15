# NEXUS-32 FIR Architecture Core Characterization Script
# Target FPGA: Artix-7 xc7a35tcpg236-1 (Basys 3)
# Clock Target: 100 MHz (10.000 ns) out-of-context
# Flow: Consistent non-project mode batch synthesis
#
# Invocation:
#   vivado -mode batch -source vivado/run_core_characterization.tcl -tclargs [output_dir]

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
if {[llength $argv] > 0} {
    set output_root [file normalize [lindex $argv 0]]
} else {
    set output_root [file join $root_dir results vivado_core]
}
file mkdir $output_root

set part "xc7a35tcpg236-1"
set xdc [file join $script_dir core_clock.xdc]

# Record tool version
set vivado_version [version -short]
puts "================================================================="
puts "NEXUS-32 Vivado Core Characterization Flow (Non-Project Mode)"
puts "Vivado Version : $vivado_version"
puts "Project Root   : $root_dir"
puts "Target Part    : $part (Basys 3 Artix-7 XC7A35T)"
puts "Clock Target   : 10.000 ns (100 MHz)"
puts "Output Root    : $output_root"
puts "================================================================="

# Synthesis targets:
# Each entry: {case_id top_module lanes relative_sources}
set synth_cases [list \
    [list "seq" "fir_seq_engine" "" [list \
        "rtl/fir_q16_mac.sv" "rtl/fir_q16_postprocess.sv" "rtl/fir_seq_engine.sv"]] \
    [list "parallel_l4" "fir_parallel_engine" 4 [list \
        "rtl/fir_q16_postprocess.sv" "rtl/fir_parallel_engine.sv"]] \
    [list "parallel_l8" "fir_parallel_engine" 8 [list \
        "rtl/fir_q16_postprocess.sv" "rtl/fir_parallel_engine.sv"]] \
    [list "parallel_l16" "fir_parallel_engine" 16 [list \
        "rtl/fir_q16_postprocess.sv" "rtl/fir_parallel_engine.sv"]] \
    [list "parallel_l32" "fir_parallel_engine" 32 [list \
        "rtl/fir_q16_postprocess.sv" "rtl/fir_parallel_engine.sv"]] \
    [list "pipelined_l4" "fir_pipelined_engine" 4 [list \
        "rtl/fir_q16_postprocess.sv" "rtl/fir_pipelined_engine.sv"]] \
    [list "pipelined_l8" "fir_pipelined_engine" 8 [list \
        "rtl/fir_q16_postprocess.sv" "rtl/fir_pipelined_engine.sv"]] \
    [list "pipelined_l16" "fir_pipelined_engine" 16 [list \
        "rtl/fir_q16_postprocess.sv" "rtl/fir_pipelined_engine.sv"]] \
    [list "pipelined_l32" "fir_pipelined_engine" 32 [list \
        "rtl/fir_q16_postprocess.sv" "rtl/fir_pipelined_engine.sv"]] \
    [list "arch_selector_l4" "fir_arch_selector" 4 [list \
        "rtl/fir_q16_mac.sv" "rtl/fir_q16_postprocess.sv" "rtl/fir_seq_engine.sv" \
        "rtl/fir_parallel_engine.sv" "rtl/fir_pipelined_engine.sv" "rtl/fir_arch_selector.sv"]] \
    [list "arch_selector_l8" "fir_arch_selector" 8 [list \
        "rtl/fir_q16_mac.sv" "rtl/fir_q16_postprocess.sv" "rtl/fir_seq_engine.sv" \
        "rtl/fir_parallel_engine.sv" "rtl/fir_pipelined_engine.sv" "rtl/fir_arch_selector.sv"]] \
    [list "arch_selector_l16" "fir_arch_selector" 16 [list \
        "rtl/fir_q16_mac.sv" "rtl/fir_q16_postprocess.sv" "rtl/fir_seq_engine.sv" \
        "rtl/fir_parallel_engine.sv" "rtl/fir_pipelined_engine.sv" "rtl/fir_arch_selector.sv"]] \
    [list "arch_selector_l32" "fir_arch_selector" 32 [list \
        "rtl/fir_q16_mac.sv" "rtl/fir_q16_postprocess.sv" "rtl/fir_seq_engine.sv" \
        "rtl/fir_parallel_engine.sv" "rtl/fir_pipelined_engine.sv" "rtl/fir_arch_selector.sv"]] \
]

# Summary data structure
set results_table [list]

# Helper to parse utilization report
proc parse_utilization {rpt_file} {
    set luts "N/A"
    set ffs  "N/A"
    set dsps "N/A"
    set brams "N/A"
    if {![file exists $rpt_file]} {
        return [list $luts $ffs $dsps $brams]
    }
    set fp [open $rpt_file r]
    while {[gets $fp line] >= 0} {
        if {[regexp -nocase {\|\s*Slice LUTs\s*\|\s*(\d+)} $line -> match]} {
            set luts $match
        } elseif {[regexp -nocase {\|\s*Slice Registers\s*\|\s*(\d+)} $line -> match]} {
            set ffs $match
        } elseif {[regexp -nocase {\|\s*DSPs\s*\|\s*(\d+)} $line -> match]} {
            set dsps $match
        } elseif {[regexp -nocase {\|\s*Block RAM Tile\s*\|\s*([0-9.]+)} $line -> match]} {
            set brams $match
        }
    }
    close $fp
    return [list $luts $ffs $dsps $brams]
}

# Helper to parse timing summary report
proc parse_timing {rpt_file} {
    set wns "N/A"
    set met "N/A"
    set data_path "N/A"
    if {![file exists $rpt_file]} {
        return [list $wns $met $data_path]
    }
    set fp [open $rpt_file r]
    set in_summary 0
    while {[gets $fp line] >= 0} {
        if {[regexp -nocase {Design Timing Summary} $line]} {
            set in_summary 1
            continue
        }
        if {$in_summary && [regexp {^\s*WNS\(ns\)} $line]} {
            # Header line found, read next 2 lines
            gets $fp empty_line
            gets $fp data_line
            set fields [regexp -all -inline {\S+} $data_line]
            if {[llength $fields] >= 1} {
                set wns [lindex $fields 0]
                if {[string is double -strict $wns]} {
                    if {$wns >= 0.0} {
                        set met "YES"
                    } else {
                        set met "NO"
                    }
                }
            }
            break
        }
    }
    close $fp

    # Search for data path delay in timing report
    set fp [open $rpt_file r]
    while {[gets $fp line] >= 0} {
        if {[regexp -nocase {Data Path Delay:\s*([0-9.]+)ns} $line -> match]} {
            set data_path $match
            break
        }
    }
    close $fp

    return [list $wns $met $data_path]
}

# -----------------------------------------------------------------------------
# Optional/Guard Test: Verify elaboration rejection of unsupported LANES=12
# -----------------------------------------------------------------------------
puts "\n-----------------------------------------------------------------"
puts "Running elaboration guard test: LANES=12 rejection on fir_parallel_engine"
puts "-----------------------------------------------------------------"
create_project -in_memory -part $part
read_verilog -sv [file join $root_dir "rtl/fir_q16_postprocess.sv"]
read_verilog -sv [file join $root_dir "rtl/fir_parallel_engine.sv"]
read_xdc $xdc
set synth_failed [catch {
    synth_design -top "fir_parallel_engine" -part $part -mode out_of_context -generic "LANES=12"
} err_msg]
close_project

if {$synth_failed} {
    puts "SUCCESS: Elaboration correctly rejected unsupported LANES=12 with error:"
    puts "  [string range $err_msg 0 200]..."
} else {
    puts "WARNING: LANES=12 did not fail elaboration as expected!"
}

# -----------------------------------------------------------------------------
# Main Characterization Sweep
# -----------------------------------------------------------------------------
foreach case_item $synth_cases {
    lassign $case_item case_id top lanes rel_sources
    set run_dir [file join $output_root $case_id]
    set report_dir [file join $run_dir "reports"]
    file mkdir $run_dir
    file mkdir $report_dir

    set log_file [file join $run_dir "${case_id}_synth.log"]

    puts "\n================================================================="
    puts "Synthesizing $case_id (top=$top, LANES=$lanes)"
    puts "Run directory: $run_dir"
    puts "================================================================="

    # Pure non-project in-memory flow
    create_project -in_memory -part $part
    set_property target_language Verilog [current_project]

    set source_paths [list]
    foreach rel $rel_sources {
        set p [file normalize [file join $root_dir $rel]]
        if {![file exists $p]} {
            error "Source file not found: $p"
        }
        lappend source_paths $p
        read_verilog -sv $p
    }

    read_xdc $xdc

    set synth_cmd [list synth_design -top $top -part $part -mode out_of_context]
    if {$lanes ne ""} {
        lappend synth_cmd -generic "LANES=$lanes"
    }

    set start_time [clock seconds]
    set synth_err [catch {eval $synth_cmd} msg]
    set end_time [clock seconds]
    set duration [expr {$end_time - $start_time}]

    if {$synth_err} {
        puts "ERROR: Synthesis failed for $case_id: $msg"
        close_project
        lappend results_table [list $case_id $top $lanes "FAILED" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"]
        continue
    }

    puts "Synthesis completed successfully in ${duration}s. Writing reports..."

    set util_rpt     [file join $report_dir "${case_id}_utilization.rpt"]
    set util_hier    [file join $report_dir "${case_id}_utilization_hier.rpt"]
    set timing_rpt   [file join $report_dir "${case_id}_timing_summary.rpt"]
    set paths_rpt    [file join $report_dir "${case_id}_critical_paths.rpt"]
    set drc_rpt      [file join $report_dir "${case_id}_post_synth_drc.rpt"]
    set dcp_file     [file join $report_dir "${case_id}_post_synth.dcp"]
    set netlist_file [file join $report_dir "${case_id}_post_synth.v"]

    report_utilization -file $util_rpt
    report_utilization -hierarchical -file $util_hier
    report_timing_summary -delay_type max -file $timing_rpt
    report_timing -delay_type max -max_paths 20 -sort_by group -input_pins -file $paths_rpt
    report_drc -file $drc_rpt
    write_checkpoint -force $dcp_file
    write_verilog -force -mode funcsim $netlist_file

    # Parse metrics
    lassign [parse_utilization $util_rpt] luts ffs dsps brams
    lassign [parse_timing $timing_rpt] wns met data_path

    lappend results_table [list $case_id $top [expr {$lanes eq "" ? "N/A" : $lanes}] "PASSED" $luts $ffs $dsps $brams $wns $met $data_path]

    close_project
    puts "Completed $case_id. Reports saved to $report_dir."
}

# -----------------------------------------------------------------------------
# Generate Consolidated Summary Reports
# -----------------------------------------------------------------------------
set csv_file [file join $output_root "characterization_summary.csv"]
set fp [open $csv_file w]
puts $fp "Case,Top,LANES,Status,LUTs,FFs,DSPs,BRAMs,WNS_ns,Timing_Met,Data_Path_Delay_ns"
foreach r $results_table {
    puts $fp [join $r ","]
}
close $fp

set md_file [file join $output_root "characterization_summary.md"]
set fp [open $md_file w]
puts $fp "# NEXUS-32 FIR Core Characterization Summary"
puts $fp ""
puts $fp "- **Vivado Version**: $vivado_version"
puts $fp "- **Target Part**: $part (Artix-7 xc7a35tcpg236-1)"
puts $fp "- **Clock Period Target**: 10.000 ns (100.0 MHz)"
puts $fp "- **Flow**: Out-of-Context Non-Project Mode Synthesis"
puts $fp ""
puts $fp "| Case | Top Module | LANES | Status | LUTs | FFs | DSPs | BRAMs | WNS (ns) | Timing Met | Data Path Delay (ns) |"
puts $fp "| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |"
foreach r $results_table {
    lassign $r case_id top lanes status luts ffs dsps brams wns met data_path
    puts $fp "| $case_id | `$top` | $lanes | $status | $luts | $ffs | $dsps | $brams | $wns | $met | $data_path |"
}
puts $fp ""
puts $fp "### Interpretation Limits"
puts $fp "1. **Out-of-Context Block Synthesis**: These figures characterize core compute logic only, excluding CPU, system bus, BRAM adapters, and arbitration."
puts $fp "2. **Timing Estimation**: Post-synthesis timing estimates logic delay and estimated routing. It is not final post-route timing closure."
puts $fp "3. **Sequential Engine Area**: The sequential engine is unparameterized and retains full 1-32 tap capability across all system configurations."
close $fp

puts "\n================================================================="
puts "All characterization runs finished."
puts "Summary Markdown : $md_file"
puts "Summary CSV      : $csv_file"
puts "================================================================="
exit 0
