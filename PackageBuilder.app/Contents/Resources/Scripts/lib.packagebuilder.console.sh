#!/bin/sh
# lib.packagebuilder.console.sh - the presentation layer, written to a terminal
#
# The other implementation of the interface lib.packagebuilder.window.sh
# documents. The agent CLI sources this one; every handler in the app sources
# the window one. Between them they are the only code in this project that
# knows whether there is a window, which is what keeps the CLI from being a
# second implementation of the app.
#
# Everything goes to stderr, so stdout stays clean for the one result a caller
# wants to capture - a document path, a built package's path. The run log file
# is still written, because the pipeline reads it back in places and because a
# caller redirecting stderr should not lose it.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".

# --- Views: there are none ----------------------------------------------------
# Enabling a button and hiding a progress spinner have no meaning here, and the
# shared pipeline is not going to grow a conditional for it. These are the
# whole reason the interface exists rather than the CLI reaching for
# omc_dialog_control against a window UUID that does not exist.
set_value() { :; }
set_property() { :; }
enable_view() { :; }
show_view() { :; }
show_progress() { :; }

# The status line becomes a progress line, marked so it can be told apart from
# log output when both arrive on the same stream.
set_status() {
    printf '==> %s\n' "$1" >&2
}

# --- Log ----------------------------------------------------------------------
clear_log() {
    : > "$(state_dir)/run.log"
}

append_log() {
    printf '%s\n' "$1" >&2
    printf '%s\n' "$1" >> "$(state_dir)/run.log"
}

append_log_file() {
    local source_file="$1"
    [ -f "$source_file" ] || return 0
    /bin/cat "$source_file" >&2
    /bin/cat "$source_file" >> "$(state_dir)/run.log"
    return 0
}

# --- Step rail ----------------------------------------------------------------
# A terminal has no rail. The stage transitions are already narrated by
# set_status and the log, so drawing them again as text would be noise; what
# the rail carries that the log does not - which stage a stopped run reached -
# the log says in words on that path anyway.
rail_set() { :; }
rail_reset() { :; }

# --- What comes after a signed package ----------------------------------------
# No button to point at, so it prints the commands. The keychain profile is a
# placeholder rather than a name, because a profile only exists on the machine
# it was created on. Arguments: the signed package path.
report_next_step() {
    local package_path="$1"
    append_log ""
    append_log "Signed package: $package_path"
    append_log ""
    append_log "This package is signed but NOT notarized. Notarize and staple it with:"
    append_log "  xcrun notarytool submit \"$package_path\" --keychain-profile <profile> --wait"
    append_log "  xcrun stapler staple \"$package_path\""
    append_log ""
    append_log "The profile is made once with: xcrun notarytool store-credentials"
    return 0
}
