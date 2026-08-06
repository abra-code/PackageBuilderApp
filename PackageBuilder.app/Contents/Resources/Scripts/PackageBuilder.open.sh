#!/bin/sh
# PackageBuilder.open.sh - File > Open: the dialog is declarative, the work is not here
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"

dbg_context "PackageBuilder.open.sh"

# OPEN_OBJECT_DIALOG on this command presents the panel and NEXT_COMMAND_ID
# hands the chosen path to PackageBuilder.main, which opens it in a new window.
# Opening into a new window rather than replacing this one's contents is what
# every other document app does, and it means no unsaved-changes prompt belongs
# on this path.
exit 0
