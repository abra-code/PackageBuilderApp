#!/bin/sh
# PackageBuilder.payload.remove.sh - [-] removes the selected payload entry
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"

dbg_context "PackageBuilder.payload.remove.sh"

has_model || exit 0

if ! model_lock; then
    set_status "Busy - nothing was removed, please try again"
    exit 0
fi

idx="$(selected_payload_index)"
if [ -z "$idx" ]; then
    model_unlock
    exit 0
fi

name="$(payload_get "$idx" SOURCE)"

if ! payload_remove_at "$idx"; then
    model_unlock
    set_status "Could not remove that item"
    exit 0
fi

mark_dirty

# The row below the removed one takes its index, so keeping the same number
# selects the next item and removing the last one falls back to the new last.
n="$(payload_count)"
if [ "$n" = "0" ]; then
    repopulate_payload ""
elif [ "$idx" -ge "$n" ]; then
    repopulate_payload "$((n - 1))"
else
    repopulate_payload "$idx"
fi

model_unlock

set_status "Removed $(/usr/bin/basename "$name")"

exit 0
