#!/bin/sh
# PackageBuilder.window.close.sh - offer to save unsaved changes, then clean up
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"

dbg_context "PackageBuilder.window.close.sh"

# The model file is the only copy of the user's work, so it is deleted only from
# a path where the work is provably on disk. Everywhere else the scratch
# directory is left behind and its location is reported.
strand_state() {
    "$alert_tool" \
        --level stop \
        --title "Could Not Save" \
        --ok "OK" \
        "$1

The unsaved project was left at:
$(state_dir)/model.json"
}

if ! has_model; then
    cleanup_state
    exit 0
fi

if ! is_dirty; then
    # ICEdit's equivalent returns here without cleaning up, which leaks the
    # window's scratch directory on every clean close. Cleaning up on every
    # path costs one call.
    cleanup_state
    exit 0
fi

# There is no way to veto a close from this handler, so the alert offers only
# the two outcomes that can actually be honored. A Cancel button here would
# close the window regardless of which button was pressed.
"$alert_tool" \
    --level caution \
    --title "Unsaved Changes" \
    --ok "Save" \
    --cancel "Don't Save" \
    "Do you want to save the changes made to \"$(document_name)\"?"
answer=$?

# alert returns 0 OK, 1 Cancel, 2 Other, 3 timeout, 255 error. Only an explicit
# Cancel - the one button that says "discard" - may take the destructive branch;
# a timeout or a failure to display the alert must not throw work away.
if [ "$answer" = "1" ]; then
    dbg "close: user chose Don't Save"
    cleanup_state
    exit 0
fi

if [ "$answer" != "0" ]; then
    dbg "close: alert returned $answer, saving to be safe"
fi

path="$(doc_path)"

if [ -n "$path" ]; then
    if written="$(save_document "$path")"; then
        dbg "close: saved [$written]"
        cleanup_state
    else
        strand_state "\"$(document_name)\" could not be saved."
    fi
    exit 0
fi

# A never-saved document needs the Save As panel, which cannot run inside this
# handler. The flag tells the chained Save As that its job ends in cleanup.
dbg "close: chaining to PackageBuilder.save.as"
pb_set pb_close_after_save 1

if ! "$next_cmd" "$cmd_guid" "PackageBuilder.save.as"; then
    # Nothing will run the Save As panel, so nothing will clean up either.
    # Saying so is the only way the work is recoverable.
    dbg "close: omc_next_command failed"
    pb_set pb_close_after_save ""
    strand_state "The Save panel could not be opened."
fi

exit 0
