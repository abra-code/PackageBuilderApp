#!/bin/sh
# PackageBuilder.save.as.sh - save to the path the Save As panel returned
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"

dbg_context "PackageBuilder.save.as.sh"

# Set when this Save As was chained from the window-close handler: the close has
# already been allowed to proceed, so this run finishes by cleaning up rather
# than by updating a window that is on its way out. The flag is cleared as soon
# as it is read - leaving it set would make the next ordinary Save As in this
# window delete the window's own state out from under it.
closing=0
if [ "$(pb_get pb_close_after_save)" = "1" ]; then
    closing=1
fi
pb_set pb_close_after_save ""

# The model file is the only copy of the work. On the closing path there is no
# window left to report to, so a failure has to be said out loud.
strand_state() {
    "$alert_tool" \
        --level stop \
        --title "Could Not Save" \
        --ok "OK" \
        "$1

The unsaved project was left at:
$(state_dir)/model.json"
}

dest="$OMC_DLG_SAVE_AS_PATH"

if [ -z "$dest" ]; then
    dbg "save.as: cancelled"
    if [ "$closing" = "1" ]; then
        # The window is closing and the user cancelled the panel. Deleting the
        # state here would mean the last thing they did was press Cancel and the
        # whole document vanished.
        strand_state "\"$(document_name)\" was not saved, because the Save panel was cancelled."
    else
        set_status "Save cancelled"
    fi
    exit 0
fi

if ! has_model; then
    dbg "save.as: no model for this window"
    exit 0
fi

if written="$(save_document "$dest")"; then
    if [ "$closing" = "1" ]; then
        cleanup_state
    else
        refresh_window_title
        set_status "Saved $(/usr/bin/basename "$written")"
    fi
    exit 0
fi

dbg "save.as: save_document failed for [$dest]"

if [ "$closing" = "1" ]; then
    strand_state "\"$(document_name)\" could not be saved to $dest."
else
    set_status "Could not save to $dest"
fi

exit 0
