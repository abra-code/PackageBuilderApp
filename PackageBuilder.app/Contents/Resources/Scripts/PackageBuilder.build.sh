#!/bin/sh
# PackageBuilder.build.sh - the whole pipeline, from the toolbar's Build Package
#
# The pipeline itself is run_pipeline in lib.packagebuilder.build.sh, shared
# with the agent CLI so the two cannot drift. What is left here is what belongs
# to this button: refusing a second build while one is running, and choosing the
# presentation layer that draws the result in the window.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.build.sh"

dbg_context "PackageBuilder.build.sh"

has_model || exit 0

if build_is_running; then
    set_status "A build is already running"
    exit 0
fi

run_pipeline

exit 0
