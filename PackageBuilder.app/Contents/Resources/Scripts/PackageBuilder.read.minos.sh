#!/bin/sh
# PackageBuilder.read.minos.sh - read PROJECT.MIN_OS_VERSION from the selected artifact
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"

dbg_context "PackageBuilder.read.minos.sh"

has_model || exit 0

idx="$(selected_payload_index)"
if [ -z "$idx" ]; then
    set_status "Select a payload item first - the minimum macOS is read from it"
    exit 0
fi

stored_source="$(payload_get "$idx" SOURCE)"

# Same reason as in read.version: an unset ${ARTIFACTS_DIR} collapses a source
# onto a real system path, and reading a deployment target from the installed
# copy would be worse than reading nothing.
if uses_unset_artifacts_dir "$stored_source"; then
    set_status "Set the artifacts folder first - this source uses \${ARTIFACTS_DIR}"
    exit 0
fi

src="$(resolve_stored_path "$stored_source")"
if [ -z "$src" ] || [ ! -e "$src" ]; then
    set_status "The selected item's source is not on disk"
    exit 0
fi

v="$(artifact_minos "$src")"
if [ -z "$v" ]; then
    if is_bundle "$src"; then
        set_status "No LSMinimumSystemVersion in $(/usr/bin/basename "$src")"
    else
        set_status "vtool reported no minos for $(/usr/bin/basename "$src")"
    fi
    exit 0
fi

if ! model_lock; then
    set_status "Busy - the minimum macOS was not changed, please try again"
    exit 0
fi

if [ "$v" = "$(model_get /PROJECT/MIN_OS_VERSION)" ]; then
    model_unlock
    set_status "Minimum macOS is already $v"
    exit 0
fi

if ! model_set /PROJECT/MIN_OS_VERSION "$v"; then
    model_unlock
    set_status "Could not record the minimum macOS version"
    exit 0
fi

mark_dirty
pb_set pb_loading "$(/bin/date '+%s')"
set_value "$MIN_OS_ID" "$v"
pb_set pb_loading ""
model_unlock

set_status "Minimum macOS read from $(/usr/bin/basename "$src"): $v"

exit 0
