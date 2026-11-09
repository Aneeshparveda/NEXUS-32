# NEXUS-32 evidence collector.
#
# Gathers every Vivado result produced on this host into results/evidence/:
#   EVIDENCE.md            one-page summary (board builds, core sweep, board
#                          UART verdict, run log, provenance)
#   board/<build>/...      build_summary.md, metrics.txt, vivado.log and the
#                          text reports (no checkpoints, netlists or bitstreams)
#   core/...               characterization_summary.{md,csv} and per-case
#                          utilization/timing reports
# It only copies and tabulates; every number comes from a tool-written file.
#
# Runs under Vivado (vivado -mode batch -source vivado/collect_evidence.tcl
# -tclargs <repo_root>) or any tclsh 8.5+.

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
if {[llength $argv] >= 1 && [lindex $argv 0] ne ""} {
    set root_dir [file normalize [lindex $argv 0]]
}
set results_dir [file join $root_dir results]
set evidence_dir [file join $results_dir evidence]
file mkdir $evidence_dir

proc read_text {path} {
    set fp [open $path r]
    set text [read $fp]
    close $fp
    return $text
}

proc read_key_values {path} {
    set values [dict create]
    if {![file exists $path]} {
        return $values
    }
    foreach line [split [read_text $path] "\n"] {
        set line [string trim $line]
        if {[regexp {^([A-Za-z0-9_]+)=(.*)$} $line -> key value]} {
            dict set values $key $value
        }
    }
    return $values
}

proc kv {values key} {
    if {[dict exists $values $key]} {
        set value [dict get $values $key]
        # Return the text verbatim: expr would reformat numbers (6.100 -> 6.1).
        if {$value eq ""} {
            return "N/A"
        }
        return $value
    }
    return "N/A"
}

proc md {value} {
    return [string map [list "|" "\\|" "\n" " " "\r" " "] $value]
}

# Minimal RFC 4180 CSV line parser (quoted fields, doubled quotes).
proc parse_csv_line {line} {
    set fields [list]
    set field ""
    set in_quotes 0
    set length [string length $line]
    for {set i 0} {$i < $length} {incr i} {
        set ch [string index $line $i]
        if {$in_quotes} {
            if {$ch eq "\""} {
                if {[string index $line [expr {$i + 1}]] eq "\""} {
                    append field "\""
                    incr i
                } else {
                    set in_quotes 0
                }
            } else {
                append field $ch
            }
        } elseif {$ch eq "\""} {
            set in_quotes 1
        } elseif {$ch eq ","} {
            lappend fields $field
            set field ""
        } else {
            append field $ch
        }
    }
    lappend fields $field
    return $fields
}

proc copy_if_exists {source destination_dir} {
    if {[file exists $source]} {
        file mkdir $destination_dir
        file copy -force $source $destination_dir
        return 1
    }
    return 0
}

# ------------------------------------------------------------ board builds
set board_rows [list]
set board_root [file join $results_dir vivado]
set build_dirs [list]
if {[file isdirectory $board_root]} {
    set build_dirs [lsort [glob -nocomplain -type d -directory $board_root *]]
}
foreach build_dir $build_dirs {
    set build [file tail $build_dir]
    set metrics [read_key_values [file join $build_dir metrics.txt]]
    if {[dict size $metrics] == 0 && ![file exists [file join $build_dir build_summary.md]]} {
        continue
    }
    lappend board_rows [list $build $metrics]
    set destination [file join $evidence_dir board $build]
    foreach name {build_summary.md build_summary.tsv metrics.txt vivado.log} {
        copy_if_exists [file join $build_dir $name] $destination
    }
    foreach stage {post_synth post_implementation} {
        foreach report {utilization.rpt utilization_hierarchical.rpt timing_summary.rpt
                        timing_paths.rpt clocks.rpt drc.rpt unconstrained_paths.rpt} {
            copy_if_exists [file join $build_dir reports $stage $report] \
                [file join $destination reports $stage]
        }
    }
    copy_if_exists [file join $build_dir reports top_basys3_bitstream_summary.txt] \
        [file join $destination reports]
}

# ---------------------------------------------------- core characterization
set core_rows [list]
set core_root [file join $results_dir vivado_core]
set core_csv [file join $core_root characterization_summary.csv]
if {[file exists $core_csv]} {
    set lines [split [string trim [read_text $core_csv]] "\n"]
    set header [parse_csv_line [string trim [lindex $lines 0] "\r"]]
    foreach line [lrange $lines 1 end] {
        set fields [parse_csv_line [string trim $line "\r"]]
        set row [dict create]
        foreach name $header value $fields {
            dict set row $name $value
        }
        lappend core_rows $row
    }
    copy_if_exists $core_csv [file join $evidence_dir core]
    copy_if_exists [file join $core_root characterization_summary.md] [file join $evidence_dir core]
    copy_if_exists [file join $core_root vivado.log] [file join $evidence_dir core]
    foreach case_dir [glob -nocomplain -type d -directory $core_root *] {
        set case_id [file tail $case_dir]
        foreach report [glob -nocomplain -directory [file join $case_dir reports] *.rpt] {
            copy_if_exists $report [file join $evidence_dir core $case_id]
        }
    }
}

# ------------------------------------------------------- board UART verdict
set uart_log [file join $evidence_dir uart_log.txt]
set uart_verdict "NOT CAPTURED (run vivado\\READ_UART.bat with the board connected)"
set uart_excerpt ""
if {[file exists $uart_log]} {
    set uart_text [read_text $uart_log]
    if {[string first "NEXUS32 RESULT: PASS" $uart_text] >= 0} {
        set uart_verdict "PASS (\"NEXUS32 RESULT: PASS\" received from the board)"
    } elseif {[string first "NEXUS32 RESULT: FAIL" $uart_text] >= 0} {
        set uart_verdict "FAIL (\"NEXUS32 RESULT: FAIL\" received from the board)"
    } elseif {[string trim $uart_text] eq ""} {
        set uart_verdict "EMPTY (no characters received)"
    } else {
        set uart_verdict "INCOMPLETE (no RESULT line received)"
    }
    # One complete report block: from the last banner that has a RESULT line.
    set start [string last "=== NEXUS-32 board demo" $uart_text]
    set result_index [string last "NEXUS32 RESULT:" $uart_text]
    if {$start >= 0 && $result_index > $start} {
        set uart_excerpt [string range $uart_text $start [expr {$result_index + 19}]]
    } elseif {$result_index >= 0} {
        set previous [string last "=== NEXUS-32 board demo" [string range $uart_text 0 $result_index]]
        if {$previous >= 0} {
            set uart_excerpt [string range $uart_text $previous [expr {$result_index + 19}]]
        }
    }
}
set programmed [read_key_values [file join $evidence_dir programmed_build.txt]]

# ------------------------------------------------------------- provenance
set bundle [read_key_values [file join $root_dir BUNDLE_COMMIT.txt]]
set vivado_version "N/A"
foreach row $board_rows {
    set version [kv [lindex $row 1] VIVADO_VERSION]
    if {$version ne "N/A"} {
        set vivado_version $version
        break
    }
}
if {$vivado_version eq "N/A" && [llength $core_rows] == 0 && [info commands version] ne ""} {
    catch {set vivado_version [version -short]}
}

# ------------------------------------------------------------ EVIDENCE.md
set out [file join $evidence_dir EVIDENCE.md]
set fp [open $out w]
puts $fp "# NEXUS-32 Vivado evidence"
puts $fp ""
puts $fp "Generated by \`vivado/collect_evidence.tcl\` on [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S} -gmt 1] UTC."
puts $fp "Every value below is copied from a file written by Vivado, the build flow, or the board; nothing is estimated."
puts $fp ""
puts $fp "## Provenance"
puts $fp ""
puts $fp "| Item | Value |"
puts $fp "| :--- | :--- |"
puts $fp "| Source commit | [md [kv $bundle commit]] |"
puts $fp "| Bundle dirty | [md [kv $bundle dirty]] |"
puts $fp "| Bundle created (UTC) | [md [kv $bundle created_utc]] |"
puts $fp "| Vivado version | [md $vivado_version] |"
puts $fp "| Host | [md "$::tcl_platform(os) $::tcl_platform(osVersion) $::tcl_platform(machine)"] |"
puts $fp "| PicoRV32 SHA-256 | [md [kv $bundle picorv32_sha256]] |"
puts $fp "| Demo firmware SHA-256 | [md [kv $bundle firmware_demo_sha256]] |"
puts $fp ""
puts $fp "## Board builds (Basys 3, xc7a35tcpg236-1, full SoC)"
puts $fp ""
if {[llength $board_rows] == 0} {
    puts $fp "No board build results found under \`results/vivado/\`."
} else {
    puts $fp "| Build | Status | LANES | Clock (MHz) | Firmware | Timing met | WNS (ns) | TNS (ns) | WHS (ns) | LUT | FF | DSP | BRAM tiles | IMEM check | Bitstream SHA-256 |"
    puts $fp "| :--- | :---: | ---: | ---: | :--- | :---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: | :--- |"
    foreach row $board_rows {
        lassign $row build metrics
        set cells [list $build]
        foreach key {BUILD_STATUS LANES SYS_CLK_MHZ FIRMWARE TIMING_MET WNS_NS TNS_NS WHS_NS LUT FF DSP BRAM_TILES IMEM_INIT_CHECK BITSTREAM_SHA256} {
            lappend cells [md [kv $metrics $key]]
        }
        puts $fp "| [join $cells { | }] |"
    }
    puts $fp ""
    puts $fp "Device capacity for reference: 20,800 LUTs, 41,600 FFs, 90 DSP48E1, 50 BRAM tiles."
}
puts $fp ""
puts $fp "## Board run (UART)"
puts $fp ""
puts $fp "- Programmed build: [md [kv $programmed BUILD]] ([md [kv $programmed BITSTREAM]])"
puts $fp "- Board verdict: [md $uart_verdict]"
if {$uart_excerpt ne ""} {
    puts $fp ""
    puts $fp "Last complete report received from the board:"
    puts $fp ""
    puts $fp "\`\`\`text"
    puts $fp [string map [list "\r" ""] [string trim $uart_excerpt]]
    puts $fp "\`\`\`"
}
puts $fp ""
puts $fp "## Core characterization (out-of-context, each engine alone)"
puts $fp ""
if {[llength $core_rows] == 0} {
    puts $fp "No \`results/vivado_core/characterization_summary.csv\` found (RUN_VIVADO_CORES.bat not run or not finished)."
} else {
    puts $fp "| Case | Top | LANES | Status | LUT | FF | DSP | BRAM | WNS (ns) | Timing met | Failure |"
    puts $fp "| :--- | :--- | ---: | :---: | ---: | ---: | ---: | ---: | ---: | :---: | :--- |"
    foreach row $core_rows {
        set cells [list]
        foreach key {Case Top LANES Status LUTs FFs DSPs BRAMs WNS_ns Timing_Met Failure_Message} {
            set cell "N/A"
            if {[dict exists $row $key]} {
                set cell [dict get $row $key]
            }
            lappend cells [md $cell]
        }
        puts $fp "| [join $cells { | }] |"
    }
}
puts $fp ""
puts $fp "## Run log"
puts $fp ""
set run_log [file join $results_dir run_all_log.txt]
if {[file exists $run_log]} {
    copy_if_exists $run_log $evidence_dir
    puts $fp "\`\`\`text"
    puts $fp [string map [list "\r" ""] [string trim [read_text $run_log]]]
    puts $fp "\`\`\`"
} else {
    puts $fp "No \`results/run_all_log.txt\` (RUN_ALL.bat not used)."
}
puts $fp ""
puts $fp "## Still to capture by hand"
puts $fp ""
puts $fp "- A photo of the board showing LD0 and LD2 on, LD3 off, with the date visible."
puts $fp "- A screenshot of the UART report window (READ_UART.bat output) if a text log is not enough."
puts $fp "- Optional: Vivado Device view of the routed design (\`vivado\\OPEN_IN_VIVADO_GUI.bat\`)."
close $fp

puts "Evidence summary: $out"
puts "Board builds: [llength $board_rows]  Core cases: [llength $core_rows]  UART: $uart_verdict"
