# NEXUS-32 Basys-3 integrated Vivado build flow.
#
# This is a deterministic, non-project batch flow.  It deliberately uses
# create_project -in_memory and explicit Vivado commands rather than project
# run APIs, so a failing stage is visible and is propagated to the exit code.
#
# Invocation:
#   vivado -mode batch -source vivado/build_basys3.tcl
#   vivado -mode batch -source vivado/build_basys3.tcl -tclargs <output_dir> <LANES>
#
# A relative output directory is resolved from the directory in which Vivado
# was launched.  The default is <repo>/results/vivado/basys3.

set launch_dir [file normalize [pwd]]
set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set part "xc7a35tcpg236-1"
set top "top_basys3"

if {[llength $argv] > 2} {
    puts stderr "ERROR: expected at most <output_dir> and <LANES> arguments"
    exit 2
}

set output_root [file join $root_dir results vivado basys3]
if {[llength $argv] >= 1} {
    set output_arg [lindex $argv 0]
    if {$output_arg eq ""} {
        puts stderr "ERROR: output directory must not be empty"
        exit 2
    }
    set output_root [file normalize [file join $launch_dir $output_arg]]
}

set lanes 16
if {[llength $argv] >= 2} {
    set lanes_arg [lindex $argv 1]
    if {![string is integer -strict $lanes_arg]} {
        puts stderr "ERROR: LANES must be one of 4, 8, 16, or 32; got '$lanes_arg'"
        exit 2
    }
    set lanes [expr {int($lanes_arg)}]
}
if {[lsearch -exact [list 4 8 16 32] $lanes] < 0} {
    puts stderr "ERROR: LANES must be one of 4, 8, 16, or 32; got '$lanes'"
    exit 2
}

set xdc_relpath "constraints/basys3.xdc"
set firmware_relpath "firmware/nexus32_smoke.hex"
set xdc_path [file normalize [file join $root_dir $xdc_relpath]]
set firmware_path [file normalize [file join $root_dir $firmware_relpath]]
set vendor_source [file normalize [file join $root_dir vendor picorv32 picorv32.v]]
set vendor_script [file normalize [file join $root_dir scripts vendor_picorv32.sh]]
set firmware_script [file normalize [file join $root_dir scripts build_smoke_firmware.sh]]

set report_dir [file normalize [file join $output_root reports]]
set post_synth_report_dir [file join $report_dir post_synth]
set post_impl_report_dir [file join $report_dir post_implementation]
set bitstream_path [file normalize [file join $output_root ${top}.bit]]
set bitstream_properties_path [file normalize [file join $report_dir ${top}_bitstream_properties.rpt]]
set bitstream_summary_path [file normalize [file join $report_dir ${top}_bitstream_summary.txt]]
set tsv_summary_path [file normalize [file join $output_root build_summary.tsv]]
set md_summary_path [file normalize [file join $output_root build_summary.md]]

set source_relpaths [list \
    "vendor/picorv32/picorv32.v" \
    "rtl/fir_q16_mac.sv" \
    "rtl/fir_q16_postprocess.sv" \
    "rtl/fir_seq_engine.sv" \
    "rtl/fir_parallel_engine.sv" \
    "rtl/fir_pipelined_engine.sv" \
    "rtl/fir_arch_selector.sv" \
    "rtl/fir_tap_bram.sv" \
    "rtl/fir_seq_accel.sv" \
    "rtl/nexus32_accel_bus.sv" \
    "rtl/nexus32_soc.sv" \
    "rtl/top_basys3.sv" \
]

# All generated files from this flow are rooted below output_root.  The
# firmware and vendored RTL are intentionally produced at their repository
# paths by the existing project scripts before source ingestion.
if {[catch {file mkdir $output_root} output_dir_message]} {
    puts stderr "ERROR: could not create output directory '$output_root': $output_dir_message"
    exit 1
}
if {![file isdirectory $output_root]} {
    puts stderr "ERROR: output path is not a directory: $output_root"
    exit 1
}

set stage_records [list]
set artifact_records [list]
set flow_failed 0
set commit_sha "N/A"
set vivado_version "N/A"
set riscv_cc "N/A"
set riscv_objcopy "N/A"
set bitstream_checksum "N/A"
set bitstream_checksum_message "Not computed"
set checksum_status "SKIPPED"

proc compact_message {message} {
    set compact [string map [list "\r" " " "\n" " "] $message]
    if {[string length $compact] > 1200} {
        set compact [string range $compact 0 1199]
    }
    return $compact
}

proc tsv_field {value} {
    set field [compact_message $value]
    return [string map [list "\\" "\\\\" "\t" "\\t" "\r" " " "\n" " "] $field]
}

proc tsv_row {values} {
    set fields [list]
    foreach value $values {
        lappend fields [tsv_field $value]
    }
    return [join $fields "\t"]
}

proc markdown_field {value} {
    set field [compact_message $value]
    return [string map [list "|" "\\|" "`" "\\`"] $field]
}

proc record_stage {stage status path command message} {
    global stage_records
    set compact [compact_message $message]
    if {$compact eq ""} {
        set compact "Completed"
    }
    lappend stage_records [list $stage $status $path $command $compact]
    if {$status eq "PASS"} {
        puts "PASS: $stage -- $compact"
    } elseif {$status eq "SKIPPED"} {
        puts "NOTE: $stage -- $compact"
    } else {
        puts stderr "FAIL: $stage -- $compact"
    }
}

proc record_artifact {name path status source_stage} {
    global artifact_records
    lappend artifact_records [list $name $path $status $source_stage]
}

proc mark_flow_failure {message} {
    global flow_failed
    set flow_failed 1
    puts stderr "ERROR: [compact_message $message]"
}

proc ensure_artifact {path} {
    if {![file exists $path]} {
        error "required artifact was not created: $path"
    }
}

# Run a mandatory Tcl/Vivado stage.  The body is evaluated one level above
# this helper so callers can use their local flow variables without building
# a shell command string.
proc run_required_stage {stage path command body} {
    global flow_failed
    if {$flow_failed} {
        record_stage $stage "SKIPPED" $path $command "A previous mandatory stage failed"
        return "SKIPPED"
    }
    set rc [catch {uplevel 1 $body} result]
    if {$rc != 0} {
        mark_flow_failure "$stage: $result"
        record_stage $stage "FAIL" $path $command $result
        return "FAIL"
    }
    record_stage $stage "PASS" $path $command "Completed"
    return "PASS"
}

# Run an optional command only when the Vivado command exists.  An available
# optional command that errors is still a build failure; only an unavailable
# command is skippable.
proc run_optional_stage {stage path command command_name body} {
    global flow_failed
    if {$flow_failed} {
        record_stage $stage "SKIPPED" $path $command "A previous mandatory stage failed"
        return "SKIPPED"
    }
    if {[info commands $command_name] eq ""} {
        record_stage $stage "SKIPPED" $path $command \
            "Optional Vivado command unavailable: $command_name"
        return "SKIPPED"
    }
    set rc [catch {uplevel 1 $body} result]
    if {$rc != 0} {
        mark_flow_failure "$stage: $result"
        record_stage $stage "FAIL" $path $command $result
        return "FAIL"
    }
    record_stage $stage "PASS" $path $command "Completed"
    return "PASS"
}

proc run_artifact_stage {stage path command body} {
    global flow_failed
    if {$flow_failed} {
        record_stage $stage "SKIPPED" $path $command "A previous mandatory stage failed"
        record_artifact $stage $path "SKIPPED" $stage
        return "SKIPPED"
    }

    # Substitute the artifact path before evaluating the body.  Evaluating the
    # expanded body in this helper avoids relying on nested uplevel scope for
    # report/checkpoint paths.
    set expanded_body [string map [list {$path} [list $path]] $body]
    set rc [catch {uplevel 1 $expanded_body} result]
    if {$rc != 0} {
        mark_flow_failure "$stage: $result"
        record_stage $stage "FAIL" $path $command $result
        record_artifact $stage $path "FAIL" $stage
        return "FAIL"
    }
    record_stage $stage "PASS" $path $command "Completed"
    set status "PASS"
    record_artifact $stage $path $status $stage
    return $status
}

proc run_optional_artifact_stage {stage path command command_name body} {
    global flow_failed
    if {$flow_failed} {
        record_stage $stage "SKIPPED" $path $command "A previous mandatory stage failed"
        record_artifact $stage $path "SKIPPED" $stage
        return "SKIPPED"
    }
    if {[info commands $command_name] eq ""} {
        record_stage $stage "SKIPPED" $path $command \
            "Optional Vivado command unavailable: $command_name"
        record_artifact $stage $path "SKIPPED" $stage
        return "SKIPPED"
    }

    set expanded_body [string map [list {$path} [list $path]] $body]
    set rc [catch {uplevel 1 $expanded_body} result]
    if {$rc != 0} {
        mark_flow_failure "$stage: $result"
        record_stage $stage "FAIL" $path $command $result
        record_artifact $stage $path "FAIL" $stage
        return "FAIL"
    }
    record_stage $stage "PASS" $path $command "Completed"
    set status "PASS"
    record_artifact $stage $path $status $stage
    return $status
}

proc tool_is_available {tool} {
    if {[string first "/" $tool] >= 0 || [string first "\\" $tool] >= 0} {
        return [expr {[file exists $tool] && [file executable $tool]}]
    }
    return [expr {[auto_execok $tool] ne ""}]
}

proc select_tool {environment_name candidates} {
    if {[info exists ::env($environment_name)]} {
        set requested [string trim $::env($environment_name)]
        if {$requested eq ""} {
            error "$environment_name is set but empty"
        }
        if {![tool_is_available $requested]} {
            error "$environment_name points to an unavailable executable: $requested"
        }
        # Resolve explicit relative paths before the flow changes directory to
        # the output directory for Vivado's own logs.
        if {[string first "/" $requested] >= 0 || [string first "\\" $requested] >= 0} {
            return [file normalize $requested]
        }
        return $requested
    }
    foreach candidate $candidates {
        if {[tool_is_available $candidate]} {
            return $candidate
        }
    }
    error "no usable $environment_name found; tried [join $candidates {, }]. Set $environment_name explicitly"
}

proc checksum_command {} {
    foreach candidate [list sha256sum shasum] {
        set resolved [auto_execok $candidate]
        if {$resolved ne ""} {
            return [list $candidate $resolved]
        }
    }
    return [list]
}

proc compute_sha256 {kind executable path} {
    if {$kind eq "sha256sum"} {
        set output [exec $executable $path]
    } else {
        set output [exec $executable -a 256 $path]
    }
    set match [regexp -inline {^([0-9A-Fa-f]{64})} [string trim $output]]
    if {[llength $match] != 2} {
        error "could not parse SHA-256 output from $kind: $output"
    }
    return [lindex $match 1]
}

puts "================================================================="
puts "NEXUS-32 Basys-3 Integrated Vivado Build Flow"
puts "Repository Root : $root_dir"
puts "Output Root     : $output_root"
puts "Target Part     : $part"
puts "Top Module      : $top"
puts "LANES           : $lanes"
puts "Firmware Path   : $firmware_path"
puts "XDC Path        : $xdc_path"
puts "================================================================="

set metadata_command "git -C $root_dir rev-parse HEAD; version -short"
set metadata_status [run_required_stage "metadata" "" $metadata_command {
    set metadata_errors [list]
    if {[catch {exec git -C $root_dir rev-parse HEAD} git_value]} {
        lappend metadata_errors "commit SHA query failed: $git_value"
    } else {
        set commit_sha [string trim $git_value]
    }
    if {[catch {version -short} version_value]} {
        lappend metadata_errors "Vivado version query failed: $version_value"
    } else {
        set vivado_version [string trim $version_value]
    }
    if {[llength $metadata_errors] > 0} {
        error [join $metadata_errors "; "]
    }
}]

puts "Commit SHA      : $commit_sha"
puts "Vivado Version  : $vivado_version"

set tools_command "select RISCV_CC/RISCV_OBJCOPY from environment or riscv64 toolchain"
set tools_status [run_required_stage "toolchain_selection" "" $tools_command {
    set riscv_cc [select_tool "RISCV_CC" [list riscv64-elf-gcc riscv64-unknown-elf-gcc]]
    set riscv_objcopy [select_tool "RISCV_OBJCOPY" [list riscv64-elf-objcopy riscv64-unknown-elf-objcopy]]
    puts "RISCV_CC       : $riscv_cc"
    puts "RISCV_OBJCOPY  : $riscv_objcopy"
}]

set vendor_command "bash $vendor_script (only when vendor/picorv32/picorv32.v is absent)"
set vendor_status [run_required_stage "vendor_rtl" $vendor_source $vendor_command {
    if {![file exists $vendor_source]} {
        if {![file exists $vendor_script]} {
            error "vendor provisioning script not found: $vendor_script"
        }
        set vendor_output [exec bash $vendor_script 2>@1]
        if {$vendor_output ne ""} {
            puts $vendor_output
        }
    } else {
        puts "PicoRV32 vendor RTL already present: $vendor_source"
    }
    ensure_artifact $vendor_source
}]
record_artifact "vendor RTL" $vendor_source $vendor_status "vendor_rtl"

set firmware_command [join [list env \
    "RISCV_CC=$riscv_cc" \
    "RISCV_OBJCOPY=$riscv_objcopy" \
    bash $firmware_script] " "]
set firmware_status [run_required_stage "smoke_firmware" $firmware_path $firmware_command {
    if {![file exists $firmware_script]} {
        error "firmware build script not found: $firmware_script"
    }
    set firmware_exec [list env \
        "RISCV_CC=$riscv_cc" \
        "RISCV_OBJCOPY=$riscv_objcopy" \
        bash $firmware_script]
    set firmware_output [exec {*}$firmware_exec 2>@1]
    if {$firmware_output ne ""} {
        puts $firmware_output
    }
    ensure_artifact $firmware_path
}]
record_artifact "smoke firmware" $firmware_path $firmware_status "smoke_firmware"

# Keep Vivado's default journal/log files alongside the requested build
# outputs.  All source paths and generated report paths are absolute.
set workdir_status [run_required_stage "output_working_directory" $output_root "cd $output_root" {
    cd $output_root
}]

set directory_status [run_required_stage "report_directories" $report_dir \
    "file mkdir $report_dir; file mkdir $post_synth_report_dir; file mkdir $post_impl_report_dir" {
    file mkdir $report_dir
    file mkdir $post_synth_report_dir
    file mkdir $post_impl_report_dir
    if {![file isdirectory $report_dir] || ![file isdirectory $post_synth_report_dir] || \
        ![file isdirectory $post_impl_report_dir]} {
        error "one or more report directories could not be created"
    }
}]

set project_status [run_required_stage "create_in_memory_project" "" \
    "create_project -in_memory -part $part" {
    create_project -in_memory -part $part
    set_property target_language Verilog [current_project]
}]

set source_command "read_verilog [join $source_relpaths {, }]"
set source_status [run_required_stage "read_sources" "" $source_command {
    foreach source_rel $source_relpaths {
        set source_path [file normalize [file join $root_dir $source_rel]]
        if {![file exists $source_path]} {
            error "required source file not found: $source_path"
        }
        if {[file extension $source_path] eq ".sv"} {
            read_verilog -sv $source_path
        } else {
            read_verilog $source_path
        }
    }
}]

set xdc_status [run_required_stage "read_constraints" $xdc_path "read_xdc $xdc_path" {
    if {![file exists $xdc_path]} {
        error "constraint file not found: $xdc_path"
    }
    read_xdc $xdc_path
}]

set top_status [run_required_stage "set_top" "" "set_property top $top <current_fileset>" {
    set_property top $top [current_fileset]
}]

set synth_generics [list "LANES=$lanes" "IMEM_INIT_FILE=$firmware_path"]
set synth_command [join [list synth_design -top $top -part $part \
    -generic $synth_generics] " "]
set synth_status [run_required_stage "synthesis" "" $synth_command {
    synth_design -top $top -part $part \
        -generic $synth_generics
}]

set post_synth_utilization [file join $post_synth_report_dir utilization.rpt]
set post_synth_timing_summary [file join $post_synth_report_dir timing_summary.rpt]
set post_synth_timing_paths [file join $post_synth_report_dir timing_paths.rpt]
set post_synth_clocks [file join $post_synth_report_dir clocks.rpt]
set post_synth_unconstrained [file join $post_synth_report_dir unconstrained_paths.rpt]
set post_synth_drc [file join $post_synth_report_dir drc.rpt]
set post_synth_checkpoint [file join $post_synth_report_dir ${top}_post_synth.dcp]

run_artifact_stage "post_synth.report_utilization" $post_synth_utilization \
    "report_utilization -file $post_synth_utilization" {
    if {[info commands report_utilization] eq ""} {
        error "Vivado command unavailable: report_utilization"
    }
    report_utilization -file $path
    ensure_artifact $path
}

run_artifact_stage "post_synth.report_timing_summary" $post_synth_timing_summary \
    "report_timing_summary -delay_type max -file $post_synth_timing_summary" {
    if {[info commands report_timing_summary] eq ""} {
        error "Vivado command unavailable: report_timing_summary"
    }
    report_timing_summary -delay_type max -file $path
    ensure_artifact $path
}

run_artifact_stage "post_synth.report_timing_paths" $post_synth_timing_paths \
    "report_timing -delay_type max -max_paths 20 -sort_by group -input_pins -file $post_synth_timing_paths" {
    if {[info commands report_timing] eq ""} {
        error "Vivado command unavailable: report_timing"
    }
    report_timing -delay_type max -max_paths 20 -sort_by group -input_pins -file $path
    ensure_artifact $path
}

run_artifact_stage "post_synth.report_clocks" $post_synth_clocks \
    "report_clocks -file $post_synth_clocks" {
    if {[info commands report_clocks] eq ""} {
        error "Vivado command unavailable: report_clocks"
    }
    report_clocks -file $path
    ensure_artifact $path
}

run_artifact_stage "post_synth.report_unconstrained_paths" $post_synth_unconstrained \
    "report_timing -unconstrained -max_paths 100 -file $post_synth_unconstrained" {
    if {[info commands report_timing] eq ""} {
        error "Vivado command unavailable: report_timing"
    }
    report_timing -unconstrained -max_paths 100 -file $path
    ensure_artifact $path
}

run_artifact_stage "post_synth.report_drc" $post_synth_drc \
    "report_drc -file $post_synth_drc" {
    if {[info commands report_drc] eq ""} {
        error "Vivado command unavailable: report_drc"
    }
    report_drc -file $path
    ensure_artifact $path
}

run_artifact_stage "post_synth.write_checkpoint" $post_synth_checkpoint \
    "write_checkpoint -force $post_synth_checkpoint" {
    write_checkpoint -force $path
    ensure_artifact $path
}

run_required_stage "opt_design" "" "opt_design" {
    opt_design
}

run_required_stage "place_design" "" "place_design" {
    place_design
}

run_optional_stage "phys_opt_design" "" "phys_opt_design" "phys_opt_design" {
    phys_opt_design
}

run_required_stage "route_design" "" "route_design" {
    route_design
}

set post_impl_utilization [file join $post_impl_report_dir utilization.rpt]
set post_impl_timing_summary [file join $post_impl_report_dir timing_summary.rpt]
set post_impl_timing_paths [file join $post_impl_report_dir timing_paths.rpt]
set post_impl_clocks [file join $post_impl_report_dir clocks.rpt]
set post_impl_unconstrained [file join $post_impl_report_dir unconstrained_paths.rpt]
set post_impl_drc [file join $post_impl_report_dir drc.rpt]
set post_impl_checkpoint [file join $post_impl_report_dir ${top}_post_implementation.dcp]

run_artifact_stage "post_impl.report_utilization" $post_impl_utilization \
    "report_utilization -file $post_impl_utilization" {
    if {[info commands report_utilization] eq ""} {
        error "Vivado command unavailable: report_utilization"
    }
    report_utilization -file $path
    ensure_artifact $path
}

run_artifact_stage "post_impl.report_timing_summary" $post_impl_timing_summary \
    "report_timing_summary -delay_type max -file $post_impl_timing_summary" {
    if {[info commands report_timing_summary] eq ""} {
        error "Vivado command unavailable: report_timing_summary"
    }
    report_timing_summary -delay_type max -file $path
    ensure_artifact $path
}

run_artifact_stage "post_impl.report_timing_paths" $post_impl_timing_paths \
    "report_timing -delay_type max -max_paths 20 -sort_by group -input_pins -file $post_impl_timing_paths" {
    if {[info commands report_timing] eq ""} {
        error "Vivado command unavailable: report_timing"
    }
    report_timing -delay_type max -max_paths 20 -sort_by group -input_pins -file $path
    ensure_artifact $path
}

run_artifact_stage "post_impl.report_clocks" $post_impl_clocks \
    "report_clocks -file $post_impl_clocks" {
    if {[info commands report_clocks] eq ""} {
        error "Vivado command unavailable: report_clocks"
    }
    report_clocks -file $path
    ensure_artifact $path
}

run_artifact_stage "post_impl.report_unconstrained_paths" $post_impl_unconstrained \
    "report_timing -unconstrained -max_paths 100 -file $post_impl_unconstrained" {
    if {[info commands report_timing] eq ""} {
        error "Vivado command unavailable: report_timing"
    }
    report_timing -unconstrained -max_paths 100 -file $path
    ensure_artifact $path
}

run_artifact_stage "post_impl.report_drc" $post_impl_drc \
    "report_drc -file $post_impl_drc" {
    if {[info commands report_drc] eq ""} {
        error "Vivado command unavailable: report_drc"
    }
    report_drc -file $path
    ensure_artifact $path
}

run_artifact_stage "post_impl.write_checkpoint" $post_impl_checkpoint \
    "write_checkpoint -force $post_impl_checkpoint" {
    write_checkpoint -force $path
    ensure_artifact $path
}

run_artifact_stage "write_bitstream" $bitstream_path \
    "write_bitstream -force $bitstream_path" {
    write_bitstream -force $path
    ensure_artifact $path
}

set checksum_spec [checksum_command]
if {$flow_failed} {
    set checksum_status "SKIPPED"
    record_stage "bitstream_checksum" "SKIPPED" $bitstream_path "sha256sum/shasum $bitstream_path" \
        "A previous mandatory stage failed"
    record_artifact "bitstream SHA-256" $bitstream_path "SKIPPED" "bitstream_checksum"
} elseif {![file exists $bitstream_path]} {
    set checksum_status "SKIPPED"
    record_stage "bitstream_checksum" "SKIPPED" $bitstream_path "sha256sum/shasum $bitstream_path" \
        "Bitstream was not available"
    record_artifact "bitstream SHA-256" $bitstream_path "SKIPPED" "bitstream_checksum"
} elseif {[llength $checksum_spec] == 0} {
    set checksum_status "SKIPPED"
    set bitstream_checksum_message "No sha256sum or shasum executable is available"
    puts "NOTE: bitstream checksum -- $bitstream_checksum_message"
    record_stage "bitstream_checksum" "SKIPPED" $bitstream_path "sha256sum/shasum $bitstream_path" \
        $bitstream_checksum_message
    record_artifact "bitstream SHA-256" $bitstream_path "SKIPPED" "bitstream_checksum"
} else {
    set checksum_kind [lindex $checksum_spec 0]
    set checksum_executable [lindex $checksum_spec 1]
    set checksum_command_text "$checksum_kind $bitstream_path"
    if {[catch {set bitstream_checksum [compute_sha256 $checksum_kind $checksum_executable $bitstream_path]} checksum_message]} {
        set checksum_status "SKIPPED"
        set bitstream_checksum_message "Checksum command failed: $checksum_message"
        puts "NOTE: bitstream checksum -- $bitstream_checksum_message"
        record_stage "bitstream_checksum" "SKIPPED" $bitstream_path $checksum_command_text $bitstream_checksum_message
        record_artifact "bitstream SHA-256" $bitstream_path "SKIPPED" "bitstream_checksum"
    } else {
        set checksum_status "PASS"
        set bitstream_checksum_message "SHA-256 computed with $checksum_kind"
        record_stage "bitstream_checksum" "PASS" $bitstream_path $checksum_command_text $bitstream_checksum
        record_artifact "bitstream SHA-256" $bitstream_path "PASS" "bitstream_checksum"
    }
}

run_optional_artifact_stage "bitstream.report_properties" $bitstream_properties_path \
    "report_property -all -file $bitstream_properties_path <current_design>" \
    "report_property" {
    set design_object [current_design]
    report_property -all -file $path $design_object
    ensure_artifact $path
}

run_artifact_stage "bitstream.summary" $bitstream_summary_path \
    "write bitstream summary $bitstream_summary_path" {
    global bitstream_checksum bitstream_checksum_message bitstream_path
    set summary_fp [open $path w]
    puts $summary_fp "BITSTREAM_PATH\t$bitstream_path"
    puts $summary_fp "BITSTREAM_SIZE_BYTES\t[file size $bitstream_path]"
    puts $summary_fp "SHA256\t$bitstream_checksum"
    puts $summary_fp "SHA256_STATUS\t$bitstream_checksum_message"
    close $summary_fp
    ensure_artifact $path
}

# Close the in-memory project if it was created.  A close failure is a real
# flow failure, but cleanup is attempted even when an earlier stage failed.
set close_status "SKIPPED"
if {[info commands current_project] ne "" && [info commands close_project] ne ""} {
    if {[catch {current_project} current_project_name] == 0 && $current_project_name ne ""} {
        if {[catch {close_project} close_message]} {
            mark_flow_failure "close_project: $close_message"
            record_stage "close_project" "FAIL" "" "close_project" $close_message
            set close_status "FAIL"
        } else {
            record_stage "close_project" "PASS" "" "close_project" "Completed"
            set close_status "PASS"
        }
    }
}

proc write_tsv_summary {path final_status} {
    global stage_records artifact_records commit_sha vivado_version part top lanes \
        output_root firmware_path xdc_path riscv_cc riscv_objcopy bitstream_checksum \
        source_relpaths root_dir metadata_status tools_status source_status checksum_status
    set fp [open $path w]
    puts $fp [tsv_row [list record_type name status path command_or_value message]]
    puts $fp [tsv_row [list metadata build_status $final_status "" $final_status ""]]
    puts $fp [tsv_row [list metadata commit_sha $metadata_status "" $commit_sha ""]]
    puts $fp [tsv_row [list metadata vivado_version $metadata_status "" $vivado_version ""]]
    puts $fp [tsv_row [list metadata target_part PASS "" $part ""]]
    puts $fp [tsv_row [list metadata top PASS "" $top ""]]
    puts $fp [tsv_row [list metadata lanes PASS "" $lanes ""]]
    puts $fp [tsv_row [list metadata output_root PASS $output_root $output_root ""]]
    puts $fp [tsv_row [list metadata firmware_path PASS $firmware_path $firmware_path ""]]
    puts $fp [tsv_row [list metadata xdc_path PASS $xdc_path $xdc_path ""]]
    puts $fp [tsv_row [list metadata riscv_cc $tools_status "" $riscv_cc ""]]
    puts $fp [tsv_row [list metadata riscv_objcopy $tools_status "" $riscv_objcopy ""]]
    puts $fp [tsv_row [list metadata bitstream_sha256 $checksum_status $bitstream_checksum $bitstream_checksum ""]]
    foreach source_rel $source_relpaths {
        set source_path [file normalize [file join $root_dir $source_rel]]
        puts $fp [tsv_row [list source $source_rel $source_status $source_path $source_path ""]]
    }
    foreach stage $stage_records {
        lassign $stage stage_name stage_status stage_path stage_command stage_message
        puts $fp [tsv_row [list stage $stage_name $stage_status $stage_path $stage_command $stage_message]]
    }
    foreach artifact $artifact_records {
        lassign $artifact artifact_name artifact_path artifact_status artifact_stage
        puts $fp [tsv_row [list artifact $artifact_name $artifact_status $artifact_path $artifact_stage ""]]
    }
    close $fp
    ensure_artifact $path
}

proc write_md_summary {path final_status} {
    global stage_records artifact_records commit_sha vivado_version part top lanes \
        output_root firmware_path xdc_path riscv_cc riscv_objcopy bitstream_checksum \
        source_relpaths root_dir
    set fp [open $path w]
    puts $fp "# NEXUS-32 Basys-3 Vivado Build Summary"
    puts $fp ""
    puts $fp "- **Build status**: [markdown_field $final_status]"
    puts $fp "- **Commit SHA**: [markdown_field $commit_sha]"
    puts $fp "- **Vivado version**: [markdown_field $vivado_version]"
    puts $fp "- **Target part**: [markdown_field $part]"
    puts $fp "- **Top module**: [markdown_field $top]"
    puts $fp "- **LANES**: [markdown_field $lanes]"
    puts $fp "- **Output root**: `[markdown_field $output_root]`"
    puts $fp "- **Firmware**: `[markdown_field $firmware_path]`"
    puts $fp "- **Constraints**: `[markdown_field $xdc_path]`"
    puts $fp "- **RISCV_CC**: `[markdown_field $riscv_cc]`"
    puts $fp "- **RISCV_OBJCOPY**: `[markdown_field $riscv_objcopy]`"
    puts $fp "- **Bitstream SHA-256**: [markdown_field $bitstream_checksum]"
    puts $fp ""
    puts $fp "## Stages"
    puts $fp ""
    puts $fp "| Stage | Status | Path | Command | Result |"
    puts $fp "| :--- | :---: | :--- | :--- | :--- |"
    foreach stage $stage_records {
        lassign $stage stage_name stage_status stage_path stage_command stage_message
        puts $fp "| [markdown_field $stage_name] | [markdown_field $stage_status] | `[markdown_field $stage_path]` | `[markdown_field $stage_command]` | [markdown_field $stage_message] |"
    }
    puts $fp ""
    puts $fp "## Artifacts"
    puts $fp ""
    puts $fp "| Artifact | Status | Path | Producing stage |"
    puts $fp "| :--- | :---: | :--- | :--- |"
    foreach artifact $artifact_records {
        lassign $artifact artifact_name artifact_path artifact_status artifact_stage
        puts $fp "| [markdown_field $artifact_name] | [markdown_field $artifact_status] | `[markdown_field $artifact_path]` | [markdown_field $artifact_stage] |"
    }
    puts $fp ""
    puts $fp "## Source Manifest"
    puts $fp ""
    foreach source_rel $source_relpaths {
        puts $fp "- `[markdown_field [file normalize [file join $root_dir $source_rel]]]`"
    }
    puts $fp ""
    puts $fp "Report files and checkpoints are listed only when their producing stage records them.  No utilization or timing metric is inferred by this summary; inspect the generated Vivado reports for the actual tool results."
    close $fp
    ensure_artifact $path
}

set summary_status_before_write [expr {$flow_failed ? "FAIL" : "PASS"}]
set summary_write_error [catch {
    write_tsv_summary $tsv_summary_path $summary_status_before_write
    write_md_summary $md_summary_path $summary_status_before_write
} summary_write_message]
if {$summary_write_error} {
    mark_flow_failure "summary generation: $summary_write_message"
    record_stage "summary_generation" "FAIL" "$output_root" \
        "write $tsv_summary_path; write $md_summary_path" $summary_write_message
} else {
    record_stage "summary_generation" "PASS" "$output_root" \
        "write $tsv_summary_path; write $md_summary_path" "Completed"
    record_artifact "build summary TSV" $tsv_summary_path "PASS" "summary_generation"
    record_artifact "build summary Markdown" $md_summary_path "PASS" "summary_generation"
}

set final_status [expr {$flow_failed ? "FAIL" : "PASS"}]
puts "================================================================="
puts "NEXUS-32 Basys-3 build status: $final_status"
puts "Build summary TSV: $tsv_summary_path"
puts "Build summary MD : $md_summary_path"
puts "Bitstream path   : $bitstream_path"
puts "================================================================="

set final_exit_code [expr {$flow_failed ? 1 : 0}]
exit $final_exit_code
