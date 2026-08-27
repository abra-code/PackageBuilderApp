#!/bin/sh
# PackageBuilder.component.remove.sh - [-] removes the selected component
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"

dbg_context "PackageBuilder.component.remove.sh"

has_model || exit 0

if ! model_lock; then
    set_status "Busy - nothing was removed, please try again"
    exit 0
fi

load_current_component_index

# The button is disabled when there is one component left, so this is only
# reachable through a stale click on a list that shrank underneath it.
if [ "$(component_count)" -le 1 ]; then
    model_unlock
    set_status "A project needs a component - this is the only one"
    exit 0
fi

idx="$PB_COMPONENT_INDEX"
name="$(component_title "$idx")"

if ! component_remove_at "$idx"; then
    model_unlock
    set_status "Could not remove that component"
    exit 0
fi

mark_dirty

# The component below the removed one takes its index, so keeping the same
# number selects the next one and removing the last falls back to the new last.
n="$(component_count)"
if [ "$idx" -ge "$n" ]; then
    repopulate_components "$((n - 1))"
else
    repopulate_components "$idx"
fi

model_unlock

set_status "Removed $name"

exit 0
