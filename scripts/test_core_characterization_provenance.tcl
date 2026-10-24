# Offline Tcl harness for run_core_characterization.tcl source provenance.
# It extracts only query_source_revision so no Vivado command is required.

set script_root [file normalize [file join [file dirname [info script]] ..]]
set characterization_script [file join $script_root vivado run_core_characterization.tcl]
set fp [open $characterization_script r]
set characterization_source [read $fp]
close $fp

set proc_start [string first "proc query_source_revision" $characterization_source]
if {$proc_start < 0} {
    error "query_source_revision procedure was not found"
}

set proc_source ""
foreach line [split [string range $characterization_source $proc_start end] "\n"] {
    append proc_source $line "\n"
    if {[info complete $proc_source]} {
        break
    }
}
if {![info complete $proc_source]} {
    error "query_source_revision procedure was not complete"
}
eval $proc_source

proc assert_equal {label actual expected} {
    if {$actual ne $expected} {
        error "$label: expected '$expected', got '$actual'"
    }
}

set temp_parent "/tmp"
if {[info exists ::env(TMPDIR)] && $::env(TMPDIR) ne ""} {
    set temp_parent $::env(TMPDIR)
}
set fixture_root [file normalize [file join $temp_parent [format "core-characterization-provenance.%s" [pid]]]]
file delete -force $fixture_root
file mkdir $fixture_root
set clean_repo [file join $fixture_root clean]
set no_git_dir [file join $fixture_root no_git]
file mkdir $clean_repo $no_git_dir

set tracked_file [file join $clean_repo tracked.txt]
set fp [open $tracked_file w]
puts $fp "clean"
close $fp
exec git -C $clean_repo init -q
exec git -C $clean_repo add tracked.txt
exec git -C $clean_repo -c {user.name=NEXUS-32 provenance test} \
    -c {user.email=provenance-test@example.invalid} commit -qm fixture

lassign [query_source_revision $clean_repo] clean_sha clean_dirty
if {![regexp {^[0-9a-fA-F]{40}$} $clean_sha]} {
    error "clean repository did not return a 40-character SHA: $clean_sha"
}
assert_equal "clean repository SHA" $clean_sha [string trim [exec git -C $clean_repo rev-parse HEAD]]
assert_equal "clean repository dirty flag" $clean_dirty "NO"

set fp [open $tracked_file a]
puts $fp "modified"
close $fp
lassign [query_source_revision $clean_repo] dirty_sha dirty_flag
assert_equal "dirty repository SHA" $dirty_sha $clean_sha
assert_equal "dirty repository dirty flag" $dirty_flag "YES"

lassign [query_source_revision $no_git_dir] unknown_sha unknown_dirty
assert_equal "non-Git repository SHA" $unknown_sha "UNKNOWN"
assert_equal "non-Git repository dirty flag" $unknown_dirty "UNKNOWN"

file delete -force $fixture_root
puts "PASS: characterization source provenance helper clean/dirty/unknown cases"
