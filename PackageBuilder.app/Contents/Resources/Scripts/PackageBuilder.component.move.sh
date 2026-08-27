#!/bin/sh
# PackageBuilder.component.move.sh - the up and down buttons reorder the components
#
# One handler rather than two, for the reason PackageBuilder.payload.move.sh is
# one: the buttons differ only in the sign of the step, and the trigger view id
# already says which was pressed.
#
# The order is not cosmetic. It is the order the choices appear in the
# installer's customize list, and the order the components are built in.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"

dbg_context "PackageBuilder.component.move.sh"

has_model || exit 0

case "$OMC_ACTIONUI_TRIGGER_VIEW_ID" in
    "$COMPONENT_UP_ID") step=-1 ;;
    "$COMPONENT_DOWN_ID") step=1 ;;
    *)
        dbg "component.move: unexpected trigger view [$OMC_ACTIONUI_TRIGGER_VIEW_ID]"
        exit 0
        ;;
esac

if ! model_lock; then
    set_status "Busy - nothing was moved, please try again"
    exit 0
fi

load_current_component_index

idx="$PB_COMPONENT_INDEX"
target=$((idx + step))
if [ "$target" -lt 0 ] || [ "$target" -ge "$(component_count)" ]; then
    # The buttons are disabled at the ends, so this is only reachable when the
    # list changed under a stale click.
    model_unlock
    exit 0
fi

if ! component_swap "$idx" "$target"; then
    model_unlock
    set_status "Could not reorder the components"
    exit 0
fi

mark_dirty
repopulate_components "$target"
model_unlock

exit 0
