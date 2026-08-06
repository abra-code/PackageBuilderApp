#!/bin/sh
# PackageBuilder.choose.artifacts.sh - pick PROJECT.ARTIFACTS_DIR from a panel
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"

dbg_context "PackageBuilder.choose.artifacts.sh"

chosen="$OMC_DLG_CHOOSE_FOLDER_PATH"
if [ -z "$chosen" ]; then
    exit 0
fi

has_model || exit 0

if ! model_lock; then
    set_status "Busy - the artifacts folder was not changed, please try again"
    exit 0
fi

abs="$(canonical_path "$chosen")"
[ -n "$abs" ] || abs="$chosen"

# The folder itself follows design 4.2: relative to the document when it is
# below it, so a project committed next to its sources stays portable. It is
# never written through store_path, which would try ${ARTIFACTS_DIR} first and
# define the field in terms of itself.
stored="$(relative_to "$abs" "$(document_dir)")" || stored="$abs"

if [ "$stored" = "$(model_get /PROJECT/ARTIFACTS_DIR)" ]; then
    model_unlock
    exit 0
fi

if ! model_set /PROJECT/ARTIFACTS_DIR "$stored"; then
    model_unlock
    set_status "Could not record the artifacts folder"
    exit 0
fi

mark_dirty
pb_set pb_loading "$(/bin/date '+%s')"
set_value "$ARTIFACTS_DIR_ID" "$stored"
pb_set pb_loading ""
model_unlock

# Existing payload sources are left exactly as they are. Rewriting them against
# the new folder would be a silent edit of every row, and a source that was
# absolute on purpose would lose that.
set_status "Artifacts folder set to $stored"

exit 0
