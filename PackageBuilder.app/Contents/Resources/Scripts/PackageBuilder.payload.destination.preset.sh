#!/bin/sh
# PackageBuilder.payload.destination.preset.sh - a destination preset was picked
#
# Every item of the preset menu is a Button with its own view id, so the id of
# the one that fired says which directory was chosen (see destination_preset).
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"

dbg_context "PackageBuilder.payload.destination.preset.sh"

has_model || exit 0

# Which component this handler is working inside. The payload accessors below
# default to it, so it has to be resolved before the first one runs.
load_current_component_index

dir="$(destination_preset "$OMC_ACTIONUI_TRIGGER_VIEW_ID")"
if [ -z "$dir" ]; then
    dbg "destination.preset: unknown trigger view [$OMC_ACTIONUI_TRIGGER_VIEW_ID]"
    exit 0
fi

if ! model_lock; then
    set_status "Busy - the destination was not changed, please try again"
    exit 0
fi

idx="$(selected_payload_index)"
if [ -z "$idx" ]; then
    model_unlock
    exit 0
fi

# The preset supplies the directory; the item keeps its own name. That name
# comes from the source as the document stores it, so the token in a source such
# as ${ARTIFACTS_DIR}/replay is expanded before the basename is taken - a
# destination is a literal path on the target volume and must not carry one.
src="$(payload_get "$idx" SOURCE)"
base="$(/usr/bin/basename "$(expand_tokens "$src")")"
if [ -z "$base" ] || [ "$base" = "." ] || [ "$base" = "/" ]; then
    model_unlock
    set_status "Set a source first - the destination takes its name"
    exit 0
fi

# ${NAME} is the one token a preset itself carries (/Library/Application
# Support/${NAME}). It is expanded here for the same reason.
dest="$(expand_tokens "$dir")/$base"

if ! payload_set "$idx" DESTINATION "$dest"; then
    model_unlock
    set_status "Could not record that destination"
    exit 0
fi

mark_dirty
populate_payload_table
select_payload_row "$idx"
push_payload_item_to_window "$idx"
model_unlock

exit 0
