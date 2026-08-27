#!/bin/sh
# PackageBuilder.component.add.sh - [+] adds a component to the project
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"

dbg_context "PackageBuilder.component.add.sh"

has_model || exit 0

if ! model_lock; then
    set_status "Busy - no component was added, please try again"
    exit 0
fi

load_current_component_index

# model_count, not component_count: this is the index the append will land on,
# and component_count answers 1 for an array that is still empty.
identifier="$(default_component_identifier "$(model_count /COMPONENTS)")"

idx="$(component_append "$identifier")"
if [ -z "$idx" ]; then
    model_unlock
    set_status "Could not add a component"
    exit 0
fi

mark_dirty
repopulate_components "$idx"
model_unlock

set_status "Added component $((idx + 1)) - give it an identifier and a payload"

exit 0
