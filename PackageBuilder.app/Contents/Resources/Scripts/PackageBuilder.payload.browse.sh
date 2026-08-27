#!/bin/sh
# PackageBuilder.payload.browse.sh - repoint the selected payload entry's source
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"

dbg_context "PackageBuilder.payload.browse.sh"

chosen="$OMC_DLG_CHOOSE_OBJECT_PATH"
if [ -z "$chosen" ]; then
    exit 0
fi

has_model || exit 0

# Which component this handler is working inside. The payload accessors below
# default to it, so it has to be resolved before the first one runs.
load_current_component_index

if ! model_lock; then
    set_status "Busy - the source was not changed, please try again"
    exit 0
fi

idx="$(selected_payload_index)"
if [ -z "$idx" ]; then
    model_unlock
    exit 0
fi

abs="$(canonical_path "$chosen")"
[ -n "$abs" ] || abs="$chosen"

if ! payload_set "$idx" SOURCE "$(store_path "$abs")"; then
    model_unlock
    set_status "Could not record that source"
    exit 0
fi

# Only the source changes. The destination is left alone: an entry being
# repointed at a rebuilt artifact must keep installing where it already did,
# and re-guessing would silently move it.
mark_dirty
populate_payload_table
select_payload_row "$idx"
push_payload_item_to_window "$idx"
model_unlock

exit 0
