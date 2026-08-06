#!/bin/sh
# PackageBuilder.save.sh - save to the document's path, or chain to Save As
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"

dbg_context "PackageBuilder.save.sh"

if ! has_model; then
    dbg "save: no model for this window"
    exit 0
fi

path="$(doc_path)"

if [ -n "$path" ]; then
    if written="$(save_document "$path")"; then
        set_status "Saved $(/usr/bin/basename "$written")"
    else
        set_status "Could not save $(/usr/bin/basename "$path") - the document is unchanged on disk"
    fi
    exit 0
fi

# A document with no path yet: the target of the save depends on runtime state,
# so the chain is made here rather than declared as NEXT_COMMAND_ID. Its status
# is checked because a failed chain is otherwise indistinguishable from a menu
# item that did nothing at all.
dbg "save: no path, chaining to PackageBuilder.save.as"
set_status "Choose where to save..."

if ! "$next_cmd" "$cmd_guid" "PackageBuilder.save.as"; then
    dbg "save: omc_next_command failed"
    set_status "Could not open the Save panel"
fi

exit 0
