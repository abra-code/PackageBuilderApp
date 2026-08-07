#!/bin/sh
# lib.packagebuilder.window.sh - the presentation layer, drawn in the window
#
# One of two implementations of the same small interface. The other is
# lib.packagebuilder.console.sh, which the agent CLI loads instead. Everything
# else in this app - the document model, the preconditions, the verify stage,
# the whole build pipeline - is shared by both, and this file is the seam that
# lets it be: the pipeline says "append_log" and "rail_set", and whether that
# reaches a TextEditor or a terminal is decided by which of these two files was
# sourced.
#
# A frontend must source exactly one of them, after lib.packagebuilder.sh and
# before anything that reports. Nothing here is optional: the shared code calls
# every function below, so a frontend that sources neither gets "command not
# found" on a stderr that OMC discards, which looks exactly like a build that
# quietly did nothing.
#
# The interface:
#   set_value, set_property, enable_view, show_view, show_progress  - views
#   set_status                                                      - one line
#   clear_log, append_log, append_log_file                          - the log
#   rail_set, rail_reset                                            - the rail
#   report_next_step                                                - the one
#       place the two frontends genuinely say different things, because what
#       comes after a signed package is a button here and a command there.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".

# --- Window control (thin wrappers over omc_dialog_control) ------------------
# All target document_uuid so a child sheet updates the parent document window.
set_value() {
    local view_id="$1" new_value="$2"
    "$dialog_tool" "$document_uuid" "$view_id" "$new_value"
}

set_property() {
    local view_id="$1" property_name="$2" property_value="$3"
    "$dialog_tool" "$document_uuid" "$view_id" omc_set_property "$property_name" "$property_value"
}

enable_view() {
    local view_id="$1" enabled="$2"
    if [ "$enabled" = "1" ]; then
        "$dialog_tool" "$document_uuid" "$view_id" omc_enable
    else
        "$dialog_tool" "$document_uuid" "$view_id" omc_disable
    fi
}

show_view() {
    local view_id="$1" visible="$2"
    if [ "$visible" = "1" ]; then
        "$dialog_tool" "$document_uuid" "$view_id" omc_show
    else
        "$dialog_tool" "$document_uuid" "$view_id" omc_hide
    fi
}

set_status() {
    local message="$1"
    set_value "$STATUS_ID" "$message"
}

show_progress() {
    local visible="$1"
    show_view "$PROGRESS_ID" "$visible"
}

# --- Log view -----------------------------------------------------------------
# From lib.notarize.sh: append to the file, then mirror the whole file into the
# view, because the TextEditor has no incremental append.
clear_log() {
    : > "$(state_dir)/run.log"
    set_value "$LOG_ID" ""
}

append_log() {
    local message="$1"
    local log_file="$(state_dir)/run.log"
    printf '%s\n' "$message" >> "$log_file"
    set_value "$LOG_ID" "$(/bin/cat "$log_file")"
}

# Append a whole file to the run log in one go. append_log rewrites the entire
# log view on every call, which is fine for a status line and quadratic for a
# tool that printed two hundred of them.
append_log_file() {
    local source_file="$1"
    local log_file="$(state_dir)/run.log"
    [ -f "$source_file" ] || return 0
    /bin/cat "$source_file" >> "$log_file"
    set_value "$LOG_ID" "$(/bin/cat "$log_file")"
    return 0
}

# --- Step rail ----------------------------------------------------------------
# Icon and color per state, copied from rail_set in lib.notarize.sh. The view
# ids themselves live with the pipeline in lib.packagebuilder.build.sh, since
# that is what decides which stage is which.
# Arguments: rail icon view id, state (pending|running|done|failed|skipped)
rail_set() {
    local view_id="$1" stage_state="$2"
    # Set on every branch of the case below.
    local symbol color
    case "$stage_state" in
        running) symbol="arrow.clockwise.circle.fill"; color="blue" ;;
        done)    symbol="checkmark.circle.fill"; color="green" ;;
        failed)  symbol="xmark.circle.fill"; color="red" ;;
        skipped) symbol="minus.circle"; color="gray" ;;
        *)       symbol="circle"; color="gray" ;;
    esac
    set_property "$view_id" systemName "$symbol"
    set_property "$view_id" foregroundStyle "$color"
}

rail_reset() {
    # Set by the "for" below.
    local view_id
    for view_id in $RAIL_ICON_IDS; do
        rail_set "$view_id" pending
    done
}

# --- What comes after a signed package ----------------------------------------
# Here it is a button, so the message names the button and the one setting that
# matters in the app it opens. Arguments: the signed package path.
report_next_step() {
    local package_path="$1"
    show_view "$REVEAL_BTN_ID" 1
    enable_view "$NOTARIZE_BTN_ID" 1
    append_log ""
    append_log "Signed package: $package_path"
    append_log ""
    append_log "This package is signed but NOT notarized. macOS will refuse to install it"
    append_log "on another Mac until it has been through the Apple notary service."
    append_log ""
    append_log "One step left: hand it to Notarize.app with the Notarize button, and turn"
    append_log "its \"Sign before submitting\" option off - this package is already signed,"
    append_log "so Notarize should verify that signature rather than replace it."
    return 0
}
