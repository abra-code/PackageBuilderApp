#!/bin/sh
# PackageBuilder.component.select.sh - a component row was selected in the sidebar
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"

dbg_context "PackageBuilder.component.select.sh"

has_model || exit 0

# The rows carry the component's index in a hidden column past the two visible
# ones - title and item count.
idx="$(table_column_value "$COMPONENT_TABLE_ID" "$COMPONENT_INDEX_COLUMN")"
dbg "component.select: hidden index=[$idx]"

case "$idx" in
    ''|*[!0-9]*)
        # A cleared selection, or a value that is not a row index. Unlike the
        # payload table there is nothing to clear to: a document always has a
        # component, the Component and Payload tabs are always showing one, and
        # emptying them would leave two tabs of disabled fields with no way back
        # except clicking a row. The current component simply stays current.
        dbg "component.select: no usable index, keeping the current component"
        exit 0
        ;;
esac

if [ "$idx" -ge "$(component_count)" ]; then
    # The table can outlive the model for one event when rows were replaced.
    dbg "component.select: index $idx is past the end of the component list"
    exit 0
fi

# Re-selecting the row that is already current has nothing to do, and saying so
# here is what lets refresh_component_list reselect a row after every rebuild
# without that echo resetting the payload selection underneath the user.
if [ "$idx" = "$(stored_component_index)" ]; then
    dbg "component.select: component $idx is already current"
    exit 0
fi

show_component_selection "$idx"

exit 0
