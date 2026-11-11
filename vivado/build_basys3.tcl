# NEXUS-32 Basys-3 integrated Vivado build flow.
#
# This is a deterministic, non-project batch flow.  It deliberately uses
# create_project -in_memory and explicit Vivado commands rather than project
# run APIs, so a failing stage is visible and is propagated to the exit code.
#
# Invocation:
#   vivado -mode batch -source vivado/build_basys3.tcl
#   vivado -mode batch -source vivado/build_basys3.tcl -tclargs <output_dir> <LANES> [<SYS_CLK_MHZ>]
#
# SYS_CLK_MHZ is 100 (default, board oscillator direct), 50 or 25 (MMCM in
# top_basys3); use 50 when the 100 MHz build misses timing.
#
# A relative output directory is resolved from the directory in which Vivado
# was launched.  The default is <repo>/results/vivado/basys3.
#
# Input modes (environment variable NEXUS32_INPUTS):
#   build    - provision PicoRV32 and compile the selected firmware with bash
#              and a RISC-V toolchain before synthesis (default on Linux/macOS).
#   prebuilt - use the already-provisioned vendor/picorv32 and firmware image
#              shipped in a handoff bundle (scripts/make_vivado_bundle.sh).
#              Needs no bash, toolchain, network, or git (default on Windows).
#
# Firmware (environment variable NEXUS32_FIRMWARE):
#   demo  - firmware/nexus32_demo.hex (default): all three engines on a
#           1024-sample block, golden-checksum verdict, UART report.
#   smoke - firmware/nexus32_smoke.hex: the original four-tap LED-only check.

set launch_dir [file normalize [pwd]]
set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set part "xc7a35tcpg236-1"
set top "top_basys3"

if {[llength $argv] > 3} {
    puts stderr "ERROR: expected at most <output_dir>, <LANES> and <SYS_CLK_MHZ> arguments"
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

# LANES=8 is the board default: the selector instantiates all three engines,
# and the 16/32-lane builds are expected to exceed the XC7A35T's 90 DSP48E1
# slices.  This is a pre-Vivado estimate; the utilization report decides.
set lanes 8
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

set sys_clk_mhz 100
if {[llength $argv] >= 3 && [lindex $argv 2] ne ""} {
    set sys_clk_arg [lindex $argv 2]
    if {![string is integer -strict $sys_clk_arg]} {
        puts stderr "ERROR: SYS_CLK_MHZ must be one of 100, 50, or 25; got '$sys_clk_arg'"
        exit 2
    }
    set sys_clk_mhz [expr {int($sys_clk_arg)}]
}
if {[lsearch -exact [list 100 50 25] $sys_clk_mhz] < 0} {
    puts stderr "ERROR: SYS_CLK_MHZ must be one of 100, 50, or 25; got '$sys_clk_mhz'"
    exit 2
}

if {[info exists ::env(NEXUS32_INPUTS)] && [string trim $::env(NEXUS32_INPUTS)] ne ""} {
    set input_mode [string tolower [string trim $::env(NEXUS32_INPUTS)]]
} elseif {$::tcl_platform(platform) eq "windows"} {
    # On Windows "bash" may resolve to WSL, which cannot run these scripts
    # against Windows paths.  Use the bundle's prebuilt inputs instead.
    set input_mode "prebuilt"
} else {
    set input_mode "build"
}
if {[lsearch -exact [list build prebuilt] $input_mode] < 0} {
    puts stderr "ERROR: NEXUS32_INPUTS must be 'build' or 'prebuilt'; got '$input_mode'"
    exit 2
}
set picorv32_pin "ef203c2b0a3fb793280f5114941416c425c5b461"
set picorv32_sha256 "0836050971b3c6cdd28ac3b1e5719a67fb645161912bef1e472e63995ceb0622"

set firmware_name "demo"
if {[info exists ::env(NEXUS32_FIRMWARE)] && [string trim $::env(NEXUS32_FIRMWARE)] ne ""} {
    set firmware_name [string tolower [string trim $::env(NEXUS32_FIRMWARE)]]
}
if {[lsearch -exact [list demo smoke] $firmware_name] < 0} {
    puts stderr "ERROR: NEXUS32_FIRMWARE must be 'demo' or 'smoke'; got '$firmware_name'"
    exit 2
}

set xdc_relpath "constraints/basys3.xdc"
set firmware_relpath "firmware/nexus32_${firmware_name}.hex"
# top_basys3's IMEM_INIT_FILE default, relative to the synthesis directory.
set top_default_firmware_relpath "firmware/nexus32_demo.hex"
set xdc_path [file normalize [file join $root_dir $xdc_relpath]]
set firmware_path [file normalize [file join $root_dir $firmware_relpath]]
set vendor_source [file normalize [file join $root_dir vendor picorv32 picorv32.v]]
set vendor_script [file normalize [file join $root_dir scripts vendor_picorv32.sh]]
set firmware_script [file normalize [file join $root_dir scripts build_${firmware_name}_firmware.sh]]

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
    "rtl/nexus32_uart_tx.sv" \
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
    foreach candidate [list sha256sum shasum certutil] {
        set resolved [auto_execok $candidate]
        if {$resolved ne ""} {
            return [list $candidate $resolved]
        }
    }
    return [list]
}

proc compute_sha256 {kind executable path} {
    if {$kind eq "sha256sum"} {
        set output [exec {*}$executable $path]
    } elseif {$kind eq "certutil"} {
        # Windows: the hash is printed on its own line, possibly with spaces
        # between byte pairs on older releases.
        set output [exec {*}$executable -hashfile [file nativename $path] SHA256]
        foreach line [split $output "\n"] {
            set candidate [string map [list " " ""] [string trim $line]]
            if {[regexp {^[0-9A-Fa-f]{64}$} $candidate]} {
                return [string tolower $candidate]
            }
        }
        error "could not parse SHA-256 output from certutil: $output"
    } else {
        set output [exec {*}$executable -a 256 $path]
    }
    set match [regexp -inline {^([0-9A-Fa-f]{64})} [string trim $output]]
    if {[llength $match] != 2} {
        error "could not parse SHA-256 output from $kind: $output"
    }
    return [lindex $match 1]
}

# Validate a prebuilt input tree without bash, git, or a RISC-V toolchain.
proc verify_prebuilt_inputs {vendor_source firmware_path pin expected_sha256} {
    set revision_path [file join [file dirname $vendor_source] REVISION.txt]
    foreach required [list $vendor_source $revision_path $firmware_path] {
        if {![file exists $required]} {
            error "prebuilt input missing: $required (build the handoff bundle with scripts/make_vivado_bundle.sh)"
        }
    }
    set fp [open $revision_path r]
    set revision_text [read $fp]
    close $fp
    if {[string first "Pinned commit: $pin" $revision_text] < 0} {
        error "different/unpinned PicoRV32 source: $revision_path does not record $pin"
    }
    set hash_note "picorv32.v SHA-256 not checked (Tcl sha256 package unavailable)"
    if {![catch {package require sha256}]} {
        set actual [string tolower [::sha2::sha256 -hex -filename $vendor_source]]
        if {$actual ne $expected_sha256} {
            error "different/unpinned PicoRV32 source: picorv32.v SHA-256 $actual != $expected_sha256"
        }
        set hash_note "picorv32.v SHA-256 verified"
    }
    set fp [open $firmware_path r]
    set firmware_lines [split [string trim [read $fp]] "\n"]
    close $fp
    if {[llength $firmware_lines] != 4096} {
        error "prebuilt firmware $firmware_path has [llength $firmware_lines] words; expected 4096"
    }
    foreach word $firmware_lines {
        if {![regexp {^[0-9A-Fa-f]{8}$} [string trim $word]]} {
            error "prebuilt firmware $firmware_path contains a non-hex word: '$word'"
        }
    }
    if {[string trim [lindex $firmware_lines 0]] eq "00000000"} {
        error "prebuilt firmware $firmware_path starts with an all-zero word; image looks empty"
    }
    return "Pinned commit $pin recorded; $hash_note; firmware has 4096 hex words"
}

# Parse WNS/TNS/WHS/THS from a report_timing_summary file's "Design Timing
# Summary" table. Missing or unparsable values stay N/A.
proc parse_timing_summary {path} {
    set values [dict create WNS_NS N/A TNS_NS N/A WHS_NS N/A THS_NS N/A]
    if {![file exists $path]} {
        return $values
    }
    set fp [open $path r]
    set lines [split [read $fp] "\n"]
    close $fp
    set in_summary 0
    for {set i 0} {$i < [llength $lines]} {incr i} {
        set line [lindex $lines $i]
        if {[regexp {Design Timing Summary} $line]} {
            set in_summary 1
            continue
        }
        if {$in_summary && [regexp {^\s*WNS\(ns\)} $line]} {
            set fields [regexp -all -inline {\S+} [lindex $lines [expr {$i + 2}]]]
            if {[llength $fields] >= 6} {
                foreach key {WNS_NS TNS_NS} index {0 1} {
                    set value [lindex $fields $index]
                    if {[string is double -strict $value]} { dict set values $key $value }
                }
                foreach key {WHS_NS THS_NS} index {4 5} {
                    set value [lindex $fields $index]
                    if {[string is double -strict $value]} { dict set values $key $value }
                }
            }
            break
        }
    }
    return $values
}

# Parse used LUT/FF/DSP/BRAM-tile counts from a report_utilization file.
proc parse_utilization_report {path} {
    set values [dict create LUT N/A FF N/A DSP N/A BRAM_TILES N/A]
    if {![file exists $path]} {
        return $values
    }
    set fp [open $path r]
    while {[gets $fp line] >= 0} {
        if {[regexp {^\|\s*Slice LUTs\*?\s*\|\s*([0-9]+)} $line -> value]} {
            dict set values LUT $value
        } elseif {[regexp {^\|\s*Slice Registers\s*\|\s*([0-9]+)} $line -> value]} {
            dict set values FF $value
        } elseif {[regexp {^\|\s*DSPs\s*\|\s*([0-9]+)} $line -> value]} {
            dict set values DSP $value
        } elseif {[regexp {^\|\s*Block RAM Tile\s*\|\s*([0-9.]+)} $line -> value]} {
            dict set values BRAM_TILES $value
        }
    }
    close $fp
    return $values
}

# Return {matching_block_rams block_rams_with_nonzero_INIT_00} for block RAM
# cells whose hierarchical name matches pattern, or {-1 0} when the Vivado
# query commands are unavailable (for example in the offline stub).
proc count_initialized_brams {pattern} {
    if {[info commands get_cells] eq "" || [info commands get_property] eq ""} {
        return [list -1 0]
    }
    set cells [get_cells -quiet -hierarchical -filter "REF_NAME =~ RAMB* && NAME =~ $pattern"]
    set nonzero 0
    foreach cell $cells {
        set init [get_property -quiet INIT_00 $cell]
        if {[regexp {'h0*[1-9A-Fa-f]} $init]} {
            incr nonzero
        }
    }
    return [list [llength $cells] $nonzero]
}

puts "================================================================="
puts "NEXUS-32 Basys-3 Integrated Vivado Build Flow"
puts "Repository Root : $root_dir"
puts "Output Root     : $output_root"
puts "Target Part     : $part"
puts "Top Module      : $top"
puts "LANES           : $lanes"
puts "Firmware        : $firmware_name ($firmware_relpath)"
puts "SoC Clock       : $sys_clk_mhz MHz"
puts "Input Mode      : $input_mode"
puts "Firmware Path   : $firmware_path"
puts "XDC Path        : $xdc_path"
puts "================================================================="

# The commit is provenance, not a build input: a bundle copied without .git
# (or a host without git) records the bundle's BUNDLE_COMMIT.txt instead.
set metadata_command "git -C $root_dir rev-parse HEAD (or BUNDLE_COMMIT.txt); version -short"
set metadata_status [run_required_stage "metadata" "" $metadata_command {
    if {[catch {exec git -C $root_dir rev-parse HEAD} git_value] == 0} {
        set commit_sha [string trim $git_value]
    } else {
        set bundle_commit_path [file join $root_dir BUNDLE_COMMIT.txt]
        if {[file exists $bundle_commit_path]} {
            set fp [open $bundle_commit_path r]
            set bundle_text [read $fp]
            close $fp
            if {[regexp -line {^commit=(\S+)} $bundle_text -> bundle_commit]} {
                set commit_sha "$bundle_commit (from BUNDLE_COMMIT.txt)"
            } else {
                set commit_sha "unknown (BUNDLE_COMMIT.txt has no commit= line)"
            }
        } else {
            set commit_sha "unknown (git unavailable and no BUNDLE_COMMIT.txt)"
        }
    }
    if {[catch {version -short} version_value]} {
        error "Vivado version query failed: $version_value"
    }
    set vivado_version [string trim $version_value]
}]

puts "Commit SHA      : $commit_sha"
puts "Vivado Version  : $vivado_version"

if {$input_mode eq "prebuilt"} {
    set tools_status "SKIPPED"
    set riscv_cc "N/A (prebuilt inputs)"
    set riscv_objcopy "N/A (prebuilt inputs)"
    record_stage "toolchain_selection" "SKIPPED" "" "NEXUS32_INPUTS=prebuilt" \
        "Prebuilt inputs mode: no RISC-V toolchain is required on this host"

    set prebuilt_message ""
    set vendor_status [run_required_stage "vendor_rtl" $vendor_source \
        "verify prebuilt vendor/picorv32 and $firmware_relpath" {
        set prebuilt_message [verify_prebuilt_inputs $vendor_source $firmware_path \
            $picorv32_pin $picorv32_sha256]
        puts "Prebuilt inputs : $prebuilt_message"
    }]
    record_artifact "vendor RTL" $vendor_source $vendor_status "vendor_rtl"

    set firmware_status $vendor_status
    if {$vendor_status eq "PASS"} {
        record_stage "smoke_firmware" "PASS" $firmware_path "prebuilt" \
            "Using prebuilt firmware image from the handoff bundle"
    } else {
        record_stage "smoke_firmware" "SKIPPED" $firmware_path "prebuilt" \
            "A previous mandatory stage failed"
    }
    record_artifact "smoke firmware" $firmware_path $firmware_status "smoke_firmware"
} else {
    set tools_command "select RISCV_CC/RISCV_OBJCOPY from environment or riscv64 toolchain"
    set tools_status [run_required_stage "toolchain_selection" "" $tools_command {
        set riscv_cc [select_tool "RISCV_CC" [list riscv64-elf-gcc riscv64-unknown-elf-gcc]]
        set riscv_objcopy [select_tool "RISCV_OBJCOPY" [list riscv64-elf-objcopy riscv64-unknown-elf-objcopy]]
        puts "RISCV_CC       : $riscv_cc"
        puts "RISCV_OBJCOPY  : $riscv_objcopy"
    }]

    set vendor_command "bash $vendor_script (verify pinned PicoRV32 revision)"
    set vendor_status [run_required_stage "vendor_rtl" $vendor_source $vendor_command {
        if {![file exists $vendor_script]} {
            error "vendor provisioning script not found: $vendor_script"
        }
        set vendor_output [exec bash $vendor_script 2>@1]
        if {$vendor_output ne ""} {
            puts $vendor_output
        }
        ensure_artifact $vendor_source
    }]
    record_artifact "vendor RTL" $vendor_source $vendor_status "vendor_rtl"

    # Pass the toolchain through the environment rather than the POSIX env
    # utility, so the command does not depend on /usr/bin/env.
    set firmware_command "RISCV_CC=$riscv_cc RISCV_OBJCOPY=$riscv_objcopy bash $firmware_script"
    set firmware_status [run_required_stage "smoke_firmware" $firmware_path $firmware_command {
        if {![file exists $firmware_script]} {
            error "firmware build script not found: $firmware_script"
        }
        set ::env(RISCV_CC) $riscv_cc
        set ::env(RISCV_OBJCOPY) $riscv_objcopy
        set firmware_output [exec bash $firmware_script 2>@1]
        if {$firmware_output ne ""} {
            puts $firmware_output
        }
        ensure_artifact $firmware_path
    }]
    record_artifact "smoke firmware" $firmware_path $firmware_status "smoke_firmware"
}

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

# Fallback for the IMEM image: if synthesis ignores the IMEM_INIT_FILE generic,
# top_basys3's relative default ($top_default_firmware_relpath) resolves
# against the synthesis working directory (output_root), so the selected
# image is copied to that path.  The post-synthesis IMEM guard below still
# rejects an uninitialized instruction memory.
set firmware_fallback_path [file normalize [file join $output_root $top_default_firmware_relpath]]
run_required_stage "firmware_working_copy" $firmware_fallback_path \
    "file copy -force $firmware_path $firmware_fallback_path" {
    file mkdir [file dirname $firmware_fallback_path]
    file copy -force $firmware_path $firmware_fallback_path
    ensure_artifact $firmware_fallback_path
}

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

# Verilog string parameters must be passed with literal double quotes; the
# path itself uses forward slashes on every host (file normalize).
# NEXUS32_IMEM_GENERIC=0 omits the generic and relies on the working copy at
# <output_root>/firmware/nexus32_demo.hex (escape hatch if a Vivado release
# rejects the quoted string generic); the IMEM guard still checks the result.
set synth_generics [list "LANES=$lanes" "SYS_CLK_MHZ=$sys_clk_mhz" \
    "IMEM_INIT_FILE=\"$firmware_path\""]
if {[info exists ::env(NEXUS32_IMEM_GENERIC)] && $::env(NEXUS32_IMEM_GENERIC) eq "0"} {
    set synth_generics [list "LANES=$lanes" "SYS_CLK_MHZ=$sys_clk_mhz"]
}
set synth_command [join [list synth_design -top $top -part $part \
    -generic $synth_generics] " "]
set synth_status [run_required_stage "synthesis" "" $synth_command {
    synth_design -top $top -part $part \
        -generic $synth_generics
}]

# A missing $readmemh file is only a synthesis warning in Vivado and yields an
# all-zero IMEM: the bitstream would build and the board would never boot.
# An all-zero ROM is also optimized away entirely, so "no IMEM block RAM" is
# treated as the same failure. NEXUS32_SKIP_IMEM_CHECK=1 overrides the check
# after a manual review of utilization_hierarchical.rpt.
set skip_imem_check [expr {[info exists ::env(NEXUS32_SKIP_IMEM_CHECK)] && \
    $::env(NEXUS32_SKIP_IMEM_CHECK) eq "1"}]
run_required_stage "post_synth.imem_init_check" "" \
    "get_property INIT_00 on RAMB cells matching *imem*" {
    lassign [count_initialized_brams "*imem*"] imem_brams imem_initialized
    if {$imem_brams < 0} {
        puts "NOTE: IMEM init check skipped: Vivado cell queries unavailable"
    } elseif {$skip_imem_check} {
        puts "WARNING: IMEM init check overridden by NEXUS32_SKIP_IMEM_CHECK=1 ($imem_initialized of $imem_brams IMEM block RAMs initialized)"
    } elseif {$imem_brams == 0} {
        error "no block RAM matches *imem*: the firmware image was probably not loaded and the empty ROM was optimized away ($firmware_path). If utilization_hierarchical.rpt shows IMEM in LUTs instead, set NEXUS32_SKIP_IMEM_CHECK=1"
    } elseif {$imem_initialized == 0} {
        error "IMEM maps to $imem_brams block RAMs but none has a non-zero INIT_00; the firmware image was not loaded ($firmware_path)"
    } else {
        puts "IMEM init check: $imem_initialized of $imem_brams IMEM block RAMs carry firmware data"
    }
}

set post_synth_utilization [file join $post_synth_report_dir utilization.rpt]
set post_synth_utilization_hierarchical [file join $post_synth_report_dir utilization_hierarchical.rpt]
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

run_artifact_stage "post_synth.report_utilization_hierarchical" $post_synth_utilization_hierarchical \
    "report_utilization -hierarchical -file $post_synth_utilization_hierarchical" {
    if {[info commands report_utilization] eq ""} {
        error "Vivado command unavailable: report_utilization"
    }
    report_utilization -hierarchical -file $path
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
    "check_timing -verbose -file $post_synth_unconstrained" {
    if {[info commands check_timing] eq ""} {
        error "Vivado command unavailable: check_timing"
    }
    # report_timing has no -unconstrained option (Common 17-170 in Vivado 2026.1);
    # check_timing lists unclocked and unconstrained endpoints.
    check_timing -verbose -file $path
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
set post_impl_utilization_hierarchical [file join $post_impl_report_dir utilization_hierarchical.rpt]
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

run_artifact_stage "post_impl.report_utilization_hierarchical" $post_impl_utilization_hierarchical \
    "report_utilization -hierarchical -file $post_impl_utilization_hierarchical" {
    if {[info commands report_utilization] eq ""} {
        error "Vivado command unavailable: report_utilization"
    }
    report_utilization -hierarchical -file $path
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
    "check_timing -verbose -file $post_impl_unconstrained" {
    if {[info commands check_timing] eq ""} {
        error "Vivado command unavailable: check_timing"
    }
    # See post_synth.report_unconstrained_paths.
    check_timing -verbose -file $path
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

# Best effort: a vectorless power estimate (total/dynamic/static power,
# junction temperature, supply currents). A failure here must not block the
# bitstream, so it is recorded as SKIPPED instead of failing the flow.
set post_impl_power [file join $post_impl_report_dir power.rpt]
set power_command "report_power -file $post_impl_power"
if {$flow_failed} {
    record_stage "post_impl.report_power" "SKIPPED" $post_impl_power $power_command \
        "A previous mandatory stage failed"
} elseif {[catch {report_power -file $post_impl_power} power_message]} {
    puts "NOTE: post_impl.report_power -- $power_message"
    record_stage "post_impl.report_power" "SKIPPED" $post_impl_power $power_command $power_message
} else {
    record_stage "post_impl.report_power" "PASS" $post_impl_power $power_command \
        "Vectorless estimate, not a measurement"
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
    global stage_records artifact_records commit_sha vivado_version part top lanes sys_clk_mhz firmware_name build_metrics \
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
    puts $fp [tsv_row [list metadata sys_clk_mhz PASS "" $sys_clk_mhz ""]]
    puts $fp [tsv_row [list metadata firmware PASS $firmware_path $firmware_name ""]]
    foreach key {TIMING_MET WNS_NS TNS_NS WHS_NS THS_NS LUT FF DSP BRAM_TILES IMEM_INIT_CHECK METRICS_SOURCE} {
        puts $fp [tsv_row [list metric $key PASS "" [dict get $build_metrics $key] ""]]
    }
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
    global stage_records artifact_records commit_sha vivado_version part top lanes sys_clk_mhz firmware_name build_metrics \
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
    puts $fp "- **SoC clock**: [markdown_field $sys_clk_mhz] MHz"
    puts $fp "- **Firmware program**: [markdown_field $firmware_name]"
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
    puts $fp "## Key metrics"
    puts $fp ""
    puts $fp "Parsed verbatim from the [markdown_field [dict get $build_metrics METRICS_SOURCE]] reports; N/A means the report or value was not available."
    puts $fp ""
    puts $fp "| Metric | Value |"
    puts $fp "| :--- | :--- |"
    foreach key {TIMING_MET WNS_NS TNS_NS WHS_NS THS_NS LUT FF DSP BRAM_TILES IMEM_INIT_CHECK} {
        puts $fp "| $key | [markdown_field [dict get $build_metrics $key]] |"
    }
    puts $fp ""
    puts $fp "Report files and checkpoints are listed only when their producing stage records them.  Key metrics are copied from the named Vivado reports, never estimated; inspect those reports for full detail."
    close $fp
    ensure_artifact $path
}

# Key metrics, parsed verbatim from the generated reports (post-implementation
# when available, otherwise post-synthesis). Nothing is estimated.
set metrics_source "post_implementation"
set metrics_timing_report $post_impl_timing_summary
set metrics_util_report $post_impl_utilization
if {![file exists $metrics_timing_report] || ![file exists $metrics_util_report]} {
    set metrics_source "post_synth"
    set metrics_timing_report $post_synth_timing_summary
    set metrics_util_report $post_synth_utilization
}
if {![file exists $metrics_timing_report] && ![file exists $metrics_util_report]} {
    set metrics_source "none"
}
set build_metrics [dict merge \
    [parse_timing_summary $metrics_timing_report] \
    [parse_utilization_report $metrics_util_report]]
set timing_met "UNKNOWN"
if {$metrics_source eq "post_implementation"} {
    set wns_value [dict get $build_metrics WNS_NS]
    set whs_value [dict get $build_metrics WHS_NS]
    if {[string is double -strict $wns_value] && [string is double -strict $whs_value]} {
        set timing_met [expr {($wns_value >= 0.0 && $whs_value >= 0.0) ? "YES" : "NO"}]
    }
}
set imem_check_status "NOT_RUN"
foreach stage_record $stage_records {
    if {[lindex $stage_record 0] eq "post_synth.imem_init_check"} {
        set imem_check_status [lindex $stage_record 1]
    }
}
dict set build_metrics TIMING_MET $timing_met
dict set build_metrics METRICS_SOURCE $metrics_source
dict set build_metrics IMEM_INIT_CHECK $imem_check_status
puts "Key metrics ($metrics_source): WNS=[dict get $build_metrics WNS_NS] ns WHS=[dict get $build_metrics WHS_NS] ns timing_met=$timing_met LUT=[dict get $build_metrics LUT] FF=[dict get $build_metrics FF] DSP=[dict get $build_metrics DSP] BRAM_tiles=[dict get $build_metrics BRAM_TILES]"

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

# metrics.txt: flat KEY=VALUE record for scripts (RUN_ALL.bat, the evidence
# collector). Written even when the flow failed, so callers can tell why.
set metrics_path [file join $output_root metrics.txt]
if {[catch {
    set fp [open $metrics_path w]
    puts $fp "BUILD_STATUS=$final_status"
    puts $fp "LANES=$lanes"
    puts $fp "SYS_CLK_MHZ=$sys_clk_mhz"
    puts $fp "FIRMWARE=$firmware_name"
    puts $fp "COMMIT=$commit_sha"
    puts $fp "VIVADO_VERSION=$vivado_version"
    foreach key {TIMING_MET WNS_NS TNS_NS WHS_NS THS_NS LUT FF DSP BRAM_TILES IMEM_INIT_CHECK METRICS_SOURCE} {
        puts $fp "$key=[dict get $build_metrics $key]"
    }
    puts $fp "BITSTREAM_SHA256=$bitstream_checksum"
    close $fp
} metrics_message]} {
    puts stderr "WARNING: could not write $metrics_path: $metrics_message"
} else {
    puts "Metrics file     : $metrics_path"
}

set final_exit_code [expr {$flow_failed ? 1 : 0}]
exit $final_exit_code
