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
set output_root_setup_error [catch {file mkdir $output_root} output_root_setup_message]

set part "xc7a35tcpg236-1"
set xdc [file join $script_dir core_clock.xdc]

proc query_source_revision {repo_root} {
    set unknown_result [list UNKNOWN UNKNOWN]
    if {[catch {exec git -C $repo_root rev-parse --verify HEAD} commit_message]} {
        puts stderr "WARNING: source provenance unavailable: Git commit query failed: $commit_message"
        return $unknown_result
    }
    set commit_sha [string trim $commit_message]
    if {![regexp {^[0-9a-fA-F]{40}$} $commit_sha]} {
        puts stderr "WARNING: source provenance unavailable: Git returned an invalid commit SHA: $commit_sha"
        return $unknown_result
    }

    if {[catch {exec git -C $repo_root status --porcelain --untracked-files=all} status_message]} {
        puts stderr "WARNING: source provenance unavailable: Git status query failed: $status_message"
        return $unknown_result
    }
    set dirty [expr {[string trim $status_message] eq "" ? "NO" : "YES"}]
    return [list $commit_sha $dirty]
}

set source_commit "UNKNOWN"
set source_dirty "UNKNOWN"
lassign [query_source_revision $root_dir] source_commit source_dirty

# Record tool version
set vivado_version "N/A"
set version_query_error [catch {set vivado_version [version -short]} version_query_message]
puts "================================================================="
puts "NEXUS-32 Vivado Core Characterization Flow (Non-Project Mode)"
puts "Vivado Version : $vivado_version"
puts "Project Root   : $root_dir"
puts "Target Part    : $part (Basys 3 Artix-7 XC7A35T)"
puts "Clock Target   : 10.000 ns (100 MHz)"
puts "Output Root    : $output_root"
puts "Source Commit  : $source_commit"
puts "Source Dirty   : $source_dirty"
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
set flow_failed 0

proc compact_message {message} {
    set compact [string map [list "\r" " " "\n" " "] $message]
    if {[string length $compact] > 1000} {
        set compact [string range $compact 0 999]
    }
    return $compact
}

proc csv_field {value} {
    set escaped [string map [list "\"" "\"\""] [compact_message $value]]
    return "\"$escaped\""
}

proc csv_row {values} {
    set fields [list]
    foreach value $values {
        lappend fields [csv_field $value]
    }
    return [join $fields ","]
}

proc markdown_field {value} {
    set compact [compact_message $value]
    return [string map [list "|" "\\|" "`" "\\`"] $compact]
}

proc record_result {
    case_id top lanes status report_dir command failure_stage failure_message
    luts ffs dsps brams wns met data_path
} {
    global results_table
    lappend results_table [list \
        $case_id $top $lanes $status $report_dir $command \
        $failure_stage $failure_message $luts $ffs $dsps $brams \
        $wns $met $data_path]
}

proc mark_flow_failure {message} {
    global flow_failed
    set flow_failed 1
    puts "ERROR: [compact_message $message]"
}

proc append_failure {stage message stage_var message_var} {
    upvar 1 $stage_var current_stage
    upvar 1 $message_var current_message

    set compact [compact_message $message]
    if {$compact eq ""} {
        set compact "No diagnostic message returned"
    }
    if {$current_stage eq "N/A"} {
        set current_stage $stage
    } else {
        append current_stage ";" $stage
    }
    if {$current_message eq "N/A"} {
        set current_message $compact
    } else {
        append current_message "; " $compact
    }
}

proc close_project_safely {} {
    if {[catch {current_project} project] != 0 || $project eq ""} {
        return [list 0 ""]
    }
    if {[catch {close_project} close_message]} {
        return [list 1 $close_message]
    }
    return [list 0 ""]
}

proc is_expected_lane_guard_error {message} {
    return [expr {\
        [regexp -nocase {LANES_MUST_BE_4_8_16_OR_32} $message] || \
        [regexp -nocase {(unsupported|invalid|illegal)[^[:cntrl:]]{0,40}LANES} $message] || \
        [regexp -nocase {LANES[^[:cntrl:]]{0,40}(unsupported|invalid|illegal)} $message] || \
        [regexp -nocase {LANES[^[:cntrl:]]*must be[^[:cntrl:]]*4[^[:cntrl:]]*8[^[:cntrl:]]*16[^[:cntrl:]]*32} $message]}]
}

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

# Record initialization failures after the helper procedures are available.
if {$output_root_setup_error} {
    mark_flow_failure "Output directory setup failed: $output_root_setup_message"
}
if {$version_query_error} {
    mark_flow_failure "Vivado version query failed: $version_query_message"
}

# -----------------------------------------------------------------------------
# Optional/Guard Test: Verify elaboration rejection of unsupported LANES=12
# -----------------------------------------------------------------------------
puts "\n-----------------------------------------------------------------"
puts "Running elaboration guard test: LANES=12 rejection on fir_parallel_engine"
puts "-----------------------------------------------------------------"

set guard_case_id "lanes_guard_l12"
set guard_top "fir_parallel_engine"
set guard_lanes 12
set guard_report_dir "N/A"
set guard_synth_cmd [list synth_design -top $guard_top -part $part -mode out_of_context -generic "LANES=$guard_lanes"]
set guard_command [join $guard_synth_cmd " "]
set guard_status "FAIL"
set guard_failed 0
set guard_failure_stage "N/A"
set guard_failure_message "N/A"

set guard_setup_error [catch {
    create_project -in_memory -part $part
    set_property target_language Verilog [current_project]
} guard_setup_message]
if {$guard_setup_error} {
    set guard_failed 1
    append_failure "setup" $guard_setup_message guard_failure_stage guard_failure_message
}

if {!$guard_failed} {
    set guard_source_error [catch {
        read_verilog -sv [file join $root_dir "rtl/fir_q16_postprocess.sv"]
        read_verilog -sv [file join $root_dir "rtl/fir_parallel_engine.sv"]
    } guard_source_message]
    if {$guard_source_error} {
        set guard_failed 1
        append_failure "source_read" $guard_source_message guard_failure_stage guard_failure_message
    }
}

if {!$guard_failed} {
    set guard_xdc_error [catch {read_xdc $xdc} guard_xdc_message]
    if {$guard_xdc_error} {
        set guard_failed 1
        append_failure "xdc" $guard_xdc_message guard_failure_stage guard_failure_message
    }
}

if {!$guard_failed} {
    set guard_synth_error [catch {
        synth_design -top $guard_top -part $part -mode out_of_context -generic "LANES=$guard_lanes"
    } guard_synth_message]
    if {$guard_synth_error} {
        if {[is_expected_lane_guard_error $guard_synth_message]} {
            set guard_status "PASS"
            puts "PASS: Elaboration rejected unsupported LANES=12 with the expected guard error:"
            puts "  [compact_message $guard_synth_message]"
        } else {
            set guard_failed 1
            append_failure "synthesis" $guard_synth_message guard_failure_stage guard_failure_message
        }
    } else {
        set guard_failed 1
        append_failure "synthesis" \
            "LANES=12 was accepted; the unsupported-lanes guard did not reject it" \
            guard_failure_stage guard_failure_message
    }
}

lassign [close_project_safely] guard_close_error guard_close_message
if {$guard_close_error} {
    set guard_failed 1
    append_failure "close_project" $guard_close_message guard_failure_stage guard_failure_message
}
if {$guard_failed} {
    set guard_status "FAIL"
    mark_flow_failure "${guard_case_id} failed at $guard_failure_stage: $guard_failure_message"
} elseif {$guard_status eq "PASS"} {
    puts "LANES=12 guard test passed."
}
record_result $guard_case_id $guard_top $guard_lanes $guard_status $guard_report_dir \
    $guard_command $guard_failure_stage $guard_failure_message \
    "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"

# -----------------------------------------------------------------------------
# Main Characterization Sweep
# -----------------------------------------------------------------------------
foreach case_item $synth_cases {
    lassign $case_item case_id top lanes rel_sources
    set run_dir [file join $output_root $case_id]
    set report_dir [file join $run_dir "reports"]
    set log_file [file join $run_dir "${case_id}_synth.log"]
    set lanes_value [expr {$lanes eq "" ? "N/A" : $lanes}]

    set synth_cmd [list synth_design -top $top -part $part -mode out_of_context]
    if {$lanes ne ""} {
        lappend synth_cmd -generic "LANES=$lanes"
    }
    set command_text [join $synth_cmd " "]

    set case_status "FAIL"
    set case_failed 0
    set failure_stage "N/A"
    set failure_message "N/A"
    set luts "N/A"
    set ffs "N/A"
    set dsps "N/A"
    set brams "N/A"
    set wns "N/A"
    set met "N/A"
    set data_path "N/A"

    set util_rpt     [file join $report_dir "${case_id}_utilization.rpt"]
    set util_hier    [file join $report_dir "${case_id}_utilization_hier.rpt"]
    set timing_rpt   [file join $report_dir "${case_id}_timing_summary.rpt"]
    set paths_rpt    [file join $report_dir "${case_id}_critical_paths.rpt"]
    set drc_rpt      [file join $report_dir "${case_id}_post_synth_drc.rpt"]
    set dcp_file     [file join $report_dir "${case_id}_post_synth.dcp"]
    set netlist_file [file join $report_dir "${case_id}_post_synth.v"]

    puts "\n================================================================="
    puts "Synthesizing $case_id (top=$top, LANES=$lanes_value)"
    puts "Run directory: $run_dir"
    puts "================================================================="

    set directory_error [catch {
        file mkdir $run_dir
        file mkdir $report_dir
    } directory_message]
    if {$directory_error} {
        set case_failed 1
        append_failure "output_directory" $directory_message failure_stage failure_message
    }

    # Pure non-project in-memory flow.
    if {!$case_failed} {
        set setup_error [catch {
            create_project -in_memory -part $part
            set_property target_language Verilog [current_project]
        } setup_message]
        if {$setup_error} {
            set case_failed 1
            append_failure "setup" $setup_message failure_stage failure_message
        }
    }

    set source_paths [list]
    if {!$case_failed} {
        foreach rel $rel_sources {
            set path_error [catch {
                set p [file normalize [file join $root_dir $rel]]
            } path_message]
            if {$path_error} {
                set case_failed 1
                append_failure "source_read" $path_message failure_stage failure_message
                break
            }
            if {![file exists $p]} {
                set case_failed 1
                append_failure "source_read" "Source file not found: $p" failure_stage failure_message
                break
            }
            lappend source_paths $p
            set source_error [catch {read_verilog -sv $p} source_message]
            if {$source_error} {
                set case_failed 1
                append_failure "source_read" $source_message failure_stage failure_message
                break
            }
        }
    }

    if {!$case_failed} {
        set xdc_error [catch {read_xdc $xdc} xdc_message]
        if {$xdc_error} {
            set case_failed 1
            append_failure "xdc" $xdc_message failure_stage failure_message
        }
    }

    if {!$case_failed} {
        set start_time [clock seconds]
        set synth_error [catch {eval $synth_cmd} synth_message]
        set end_time [clock seconds]
        set duration [expr {$end_time - $start_time}]

        if {$synth_error} {
            set case_failed 1
            append_failure "synthesis" $synth_message failure_stage failure_message
        } else {
            puts "Synthesis completed successfully in ${duration}s. Writing reports..."

            set util_error [catch {report_utilization -file $util_rpt} util_message]
            if {$util_error} {
                set case_failed 1
                append_failure "report_generation" $util_message failure_stage failure_message
            } elseif {![file exists $util_rpt]} {
                set case_failed 1
                append_failure "report_generation" "Utilization report was not created: $util_rpt" failure_stage failure_message
            }

            set util_hier_error [catch {report_utilization -hierarchical -file $util_hier} util_hier_message]
            if {$util_hier_error} {
                set case_failed 1
                append_failure "report_generation" $util_hier_message failure_stage failure_message
            } elseif {![file exists $util_hier]} {
                set case_failed 1
                append_failure "report_generation" "Hierarchical utilization report was not created: $util_hier" failure_stage failure_message
            }

            set timing_error [catch {report_timing_summary -delay_type max -file $timing_rpt} timing_message]
            if {$timing_error} {
                set case_failed 1
                append_failure "report_generation" $timing_message failure_stage failure_message
            } elseif {![file exists $timing_rpt]} {
                set case_failed 1
                append_failure "report_generation" "Timing summary report was not created: $timing_rpt" failure_stage failure_message
            }

            set paths_error [catch {
                report_timing -delay_type max -max_paths 20 -sort_by group -input_pins -file $paths_rpt
            } paths_message]
            if {$paths_error} {
                set case_failed 1
                append_failure "report_generation" $paths_message failure_stage failure_message
            } elseif {![file exists $paths_rpt]} {
                set case_failed 1
                append_failure "report_generation" "Critical-path report was not created: $paths_rpt" failure_stage failure_message
            }

            set drc_error [catch {report_drc -file $drc_rpt} drc_message]
            if {$drc_error} {
                set case_failed 1
                append_failure "report_generation" $drc_message failure_stage failure_message
            } elseif {![file exists $drc_rpt]} {
                set case_failed 1
                append_failure "report_generation" "Post-synthesis DRC report was not created: $drc_rpt" failure_stage failure_message
            }

            set checkpoint_error [catch {write_checkpoint -force $dcp_file} checkpoint_message]
            if {$checkpoint_error} {
                set case_failed 1
                append_failure "checkpoint" $checkpoint_message failure_stage failure_message
            } elseif {![file exists $dcp_file]} {
                set case_failed 1
                append_failure "checkpoint" "Checkpoint was not created: $dcp_file" failure_stage failure_message
            }

            set netlist_error [catch {write_verilog -force -mode funcsim $netlist_file} netlist_message]
            if {$netlist_error} {
                set case_failed 1
                append_failure "netlist" $netlist_message failure_stage failure_message
            } elseif {![file exists $netlist_file]} {
                set case_failed 1
                append_failure "netlist" "Netlist was not created: $netlist_file" failure_stage failure_message
            }

            # Parse metrics only from reports whose generation succeeded; unavailable
            # values remain N/A and never become fabricated placeholders.
            if {!$util_error && [file exists $util_rpt]} {
                set util_parse_error [catch {
                    parse_utilization $util_rpt
                } util_values]
                if {$util_parse_error} {
                    set case_failed 1
                    append_failure "metric_parse" $util_values failure_stage failure_message
                } else {
                    lassign $util_values luts ffs dsps brams
                }
            }
            if {!$timing_error && [file exists $timing_rpt]} {
                set timing_parse_error [catch {
                    parse_timing $timing_rpt
                } timing_values]
                if {$timing_parse_error} {
                    set case_failed 1
                    append_failure "metric_parse" $timing_values failure_stage failure_message
                } else {
                    lassign $timing_values wns met data_path
                }
            }
        }
    }

    lassign [close_project_safely] close_error close_message
    if {$close_error} {
        set case_failed 1
        append_failure "close_project" $close_message failure_stage failure_message
    }

    if {$case_failed} {
        set case_status "FAIL"
        mark_flow_failure "$case_id failed at $failure_stage: $failure_message"
    } else {
        set case_status "PASS"
        puts "Completed $case_id. Reports saved to $report_dir."
    }
    record_result $case_id $top $lanes_value $case_status $report_dir \
        $command_text $failure_stage $failure_message \
        $luts $ffs $dsps $brams $wns $met $data_path
}

# -----------------------------------------------------------------------------
# Generate Consolidated Summary Reports
# -----------------------------------------------------------------------------
set csv_file [file join $output_root "characterization_summary.csv"]
set fp ""
set csv_error [catch {
    set fp [open $csv_file w]
    puts $fp [csv_row [list Case Top LANES Status Report_Directory Command Failure_Stage Failure_Message LUTs FFs DSPs BRAMs WNS_ns Timing_Met Data_Path_Delay_ns Source_Commit Source_Dirty]]
    foreach r $results_table {
        puts $fp [csv_row [concat $r [list $source_commit $source_dirty]]]
    }
    close $fp
    set fp ""
} csv_message]
if {$fp ne ""} {
    catch {close $fp}
}
if {$csv_error} {
    mark_flow_failure "CSV summary generation failed: $csv_message"
}

set md_file [file join $output_root "characterization_summary.md"]
set fp ""
set md_error [catch {
    set fp [open $md_file w]
    puts $fp "# NEXUS-32 FIR Core Characterization Summary"
    puts $fp ""
    puts $fp "- **Vivado Version**: [markdown_field $vivado_version]"
    puts $fp "- **Source Commit**: [markdown_field $source_commit]"
    puts $fp "- **Source Dirty**: [markdown_field $source_dirty]"
    puts $fp "- **Target Part**: $part (Artix-7 xc7a35tcpg236-1)"
    puts $fp "- **Clock Period Target**: 10.000 ns (100.0 MHz)"
    puts $fp "- **Flow**: Out-of-Context Non-Project Mode Synthesis"
    puts $fp ""
    puts $fp "| Case | Top Module | LANES | Status | Report Directory | Command | Failure Stage | Failure Message | LUTs | FFs | DSPs | BRAMs | WNS (ns) | Timing Met | Data Path Delay (ns) | Source Commit | Source Dirty |"
    puts $fp "| :--- | :--- | :---: | :---: | :--- | :--- | :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :--- | :---: |"
    foreach r $results_table {
        lassign $r case_id top lanes status report_dir command failure_stage failure_message luts ffs dsps brams wns met data_path
        puts $fp "| [markdown_field $case_id] | `[markdown_field $top]` | [markdown_field $lanes] | [markdown_field $status] | [markdown_field $report_dir] | [markdown_field $command] | [markdown_field $failure_stage] | [markdown_field $failure_message] | [markdown_field $luts] | [markdown_field $ffs] | [markdown_field $dsps] | [markdown_field $brams] | [markdown_field $wns] | [markdown_field $met] | [markdown_field $data_path] | [markdown_field $source_commit] | [markdown_field $source_dirty] |"
    }
    puts $fp ""
    puts $fp "### Interpretation Limits"
    puts $fp "1. **Out-of-Context Block Synthesis**: These figures characterize core compute logic only, excluding CPU, system bus, BRAM adapters, and arbitration."
    puts $fp "2. **Timing Estimation**: Post-synthesis timing estimates logic delay and estimated routing. It is not final post-route timing closure."
    puts $fp "3. **Sequential Engine Area**: The sequential engine is unparameterized and retains full 1-32 tap capability across all system configurations."
    close $fp
    set fp ""
} md_message]
if {$fp ne ""} {
    catch {close $fp}
}
if {$md_error} {
    mark_flow_failure "Markdown summary generation failed: $md_message"
}

set passed_count 0
set failed_count 0
foreach r $results_table {
    if {[lindex $r 3] eq "PASS"} {
        incr passed_count
    } else {
        incr failed_count
    }
}
set total_count [llength $results_table]
set final_status "PASS"
set final_exit_code 0
if {$flow_failed || $failed_count > 0} {
    set final_status "FAIL"
    set final_exit_code 1
}

puts "\n================================================================="
puts "Characterization summary: $final_status"
puts "Cases: $total_count total, $passed_count PASS, $failed_count FAIL"
puts "Flow-level failure flag: $flow_failed"
puts "Summary Markdown : $md_file"
puts "Summary CSV      : $csv_file"
puts "================================================================="
exit $final_exit_code
