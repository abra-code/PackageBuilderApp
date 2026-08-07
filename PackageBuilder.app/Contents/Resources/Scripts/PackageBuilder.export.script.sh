#!/bin/sh
# PackageBuilder.export.script.sh - write the standalone packaging script
#
# Design section 11, and a first-class feature rather than a convenience: the
# reason this app exists is that a GUI tool stopped being maintained and took a
# release workflow with it. A document that can regenerate its own packaging
# script is not exposed to that failure again, and the script runs the same
# packaging step on a CI machine with no GUI session.
#
# The document is exported as it stands, valid or not: the generator quotes
# every value, so nothing in the document can break the emitted shell, and the
# emitted script re-checks the values that matter when it runs. Refusing to
# export an unfinished document would only mean the one copy of the workflow
# cannot be written down until the release is ready.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.build.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.export.sh"

dbg_context "PackageBuilder.export.script.sh"

has_model || exit 0

destination="$OMC_DLG_SAVE_AS_PATH"
if [ -z "$destination" ]; then
    # Canceled.
    dbg "export.script: canceled"
    exit 0
fi

# Read under the lock, like every other handler that reads the model: a field
# edit landing mid-export would otherwise mix old and new values into one
# script. Nothing is written to the model here, so the lock is held only for
# the read.
if ! model_lock; then
    set_status "Busy - nothing was exported, please try again"
    exit 0
fi
write_packaging_script "$destination"
write_status=$?
model_unlock

if [ "$write_status" != "0" ]; then
    /bin/rm -f "$destination"
    set_status "The packaging script could not be written"
    exit 0
fi

# A syntax self-check, and worth knowing what it does and does not prove: it
# answers "would sh parse this", not "is every document value still data".
# The values that land inside a "#" comment are the ones parsing cannot speak
# for, which is why comment_safe exists rather than this check standing alone.
if ! /bin/sh -n "$destination" 2>/dev/null; then
    /bin/rm -f "$destination"
    set_status "The generated script did not validate and was not saved"
    exit 0
fi

/bin/chmod 755 "$destination"
set_status "Exported $(/usr/bin/basename "$destination")"

exit 0
