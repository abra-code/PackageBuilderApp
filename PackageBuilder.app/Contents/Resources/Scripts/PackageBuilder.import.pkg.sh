#!/bin/sh
# PackageBuilder.import.pkg.sh - import a built .pkg into the current document
#
# The counterpart to Inspect Built Package: inspect reports what is in a package,
# this turns it back into a document. Everything a package records comes across -
# identifier, install location, the two safety flags, the payload with its modes
# and owners, the Distribution options, the installer identity - except the one
# thing it cannot carry, which is where the artifacts came from. Those arrive as
# ${ARTIFACTS_DIR} placeholders and the log says so.
#
# Lands in the current document and marks it dirty rather than saving, exactly as
# the .pkgproj import does: what was imported is a proposal until the user saves.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.build.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.importpkg.sh"

dbg_context "PackageBuilder.import.pkg.sh"

chosen="$OMC_DLG_CHOOSE_FILE_PATH"
if [ -z "$chosen" ]; then
    # Canceled.
    exit 0
fi

has_model || exit 0

# Refused while a build runs for the same reason inspect is: the import expands
# a package into the state directory, and patch_overwrite_permissions is doing
# its own expand/flatten round trip in there at the same time.
if build_is_running; then
    set_status "A build is running - import once it has finished"
    exit 0
fi

if [ ! -r "$chosen" ]; then
    set_status "That package cannot be read"
    exit 0
fi

if ! model_lock; then
    set_status "Busy - nothing was imported, please try again"
    exit 0
fi

clear_log
# Expanding a package is not instant - a framework payload is a hundred
# megabytes - and the whole import holds the model lock, so the window would
# otherwise sit silent with no way to tell that anything is happening.
set_status "Reading $(/usr/bin/basename "$chosen")..."

if ! import_pkg "$chosen"; then
    model_unlock
    set_status "Nothing usable in $(/usr/bin/basename "$chosen") - see the log"
    exit 0
fi

mark_dirty
model_unlock

# The whole window: the import touched the project, the component, the payload,
# the distribution options and the signing settings.
push_model_to_window

set_status "Imported $(/usr/bin/basename "$chosen") - set the artifacts folder, then save"

exit 0
