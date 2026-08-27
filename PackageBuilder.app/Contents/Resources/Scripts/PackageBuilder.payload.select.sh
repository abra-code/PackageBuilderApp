#!/bin/sh
# PackageBuilder.payload.select.sh - a payload row was selected in the table
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"

dbg_context "PackageBuilder.payload.select.sh"

has_model || exit 0

# Which component this handler is working inside. The payload accessors below
# default to it, so it has to be resolved before the first one runs.
load_current_component_index

# The rows carry the entry's index in a hidden column past the three visible
# ones - source, destination and mode (design 5.2).
idx="$(table_column_value "$PAYLOAD_TABLE_ID" "$PAYLOAD_INDEX_COLUMN")"
dbg "payload.select: hidden index=[$idx]"

case "$idx" in
    ''|*[!0-9]*)
        # Selection cleared, or a value that is not a row index. Either way
        # there is nothing to inspect.
        show_payload_selection ""
        exit 0
        ;;
esac

if [ "$idx" -ge "$(payload_count)" ]; then
    # The table can outlive the model for one event when rows were replaced.
    dbg "payload.select: index $idx is past the end of the payload"
    show_payload_selection ""
    exit 0
fi

show_payload_selection "$idx"

exit 0
