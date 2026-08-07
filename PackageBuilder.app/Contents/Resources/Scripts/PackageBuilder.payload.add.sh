#!/bin/sh
# PackageBuilder.payload.add.sh - [+] picked an artifact through the Choose panel
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"

dbg_context "PackageBuilder.payload.add.sh"

chosen="$OMC_DLG_CHOOSE_OBJECT_PATH"
if [ -z "$chosen" ]; then
    # Canceled.
    exit 0
fi

has_model || exit 0

if [ ! -e "$chosen" ]; then
    set_status "That item is no longer there"
    exit 0
fi

if ! model_lock; then
    set_status "Busy - that item was not added, please try again"
    exit 0
fi

abs="$(canonical_path "$chosen")"
[ -n "$abs" ] || abs="$chosen"

idx="$(payload_append_from_path "$abs")"
if [ -z "$idx" ]; then
    model_unlock
    set_status "Could not add that item to the payload"
    exit 0
fi

fill_project_fields_from_artifact "$abs"
mark_dirty
repopulate_payload "$idx"
set_value "$NAME_ID" "$(model_get /PROJECT/NAME)"
set_value "$VERSION_ID" "$(model_get /PROJECT/VERSION)"
set_value "$MIN_OS_ID" "$(model_get /PROJECT/MIN_OS_VERSION)"
model_unlock

if [ -z "$(payload_get "$idx" DESTINATION)" ]; then
    set_status "Added $(/usr/bin/basename "$abs") - fill in its destination"
else
    set_status "Added $(/usr/bin/basename "$abs")"
fi

exit 0
