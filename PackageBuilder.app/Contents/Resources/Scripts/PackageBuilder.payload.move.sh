#!/bin/sh
# PackageBuilder.payload.move.sh - the up and down buttons reorder the payload
#
# One handler rather than two: the two buttons differ only in the sign of the
# step, and the trigger view id already says which was pressed. Same reasoning
# as the single field.changed writer in design section 9.2.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"

dbg_context "PackageBuilder.payload.move.sh"

has_model || exit 0

case "$OMC_ACTIONUI_TRIGGER_VIEW_ID" in
    "$PAYLOAD_UP_ID") step=-1 ;;
    "$PAYLOAD_DOWN_ID") step=1 ;;
    *)
        dbg "payload.move: unexpected trigger view [$OMC_ACTIONUI_TRIGGER_VIEW_ID]"
        exit 0
        ;;
esac

if ! model_lock; then
    set_status "Busy - nothing was moved, please try again"
    exit 0
fi

idx="$(selected_payload_index)"
if [ -z "$idx" ]; then
    model_unlock
    exit 0
fi

target=$((idx + step))
if [ "$target" -lt 0 ] || [ "$target" -ge "$(payload_count)" ]; then
    # The buttons are disabled at the ends, so this is only reachable when the
    # list changed under a stale click.
    model_unlock
    exit 0
fi

if ! payload_swap "$idx" "$target"; then
    model_unlock
    set_status "Could not reorder the payload"
    exit 0
fi

mark_dirty
repopulate_payload "$target"
model_unlock

exit 0
