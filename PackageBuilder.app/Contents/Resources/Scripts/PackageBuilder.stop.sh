#!/bin/sh
# PackageBuilder.stop.sh - ask the running build to stop
#
# Design section 7 ends with cancellation, following Notarize.cancel.sh. This
# differs from it in one deliberate way: Notarize kills the pipeline's process
# group and then resets the window itself, because its stages are network calls
# to the notary service that will not return on their own. Here the run is local
# and every stage already has an exit path that puts the window back, so the
# stop is a request - flag raised, current tool terminated - and the build
# script does its own unwinding. That keeps one writer on the rail instead of
# two racing to describe the same event, and it means a stopped run reports
# which stage it stopped in rather than freezing wherever the kill landed.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.build.sh"

dbg_context "PackageBuilder.stop.sh"

if ! build_is_running; then
    # Nothing to stop. The button is only enabled while a build runs, so this is
    # a click that arrived just after the run finished - it says so rather than
    # leaving a flag behind for the next build to find.
    clear_stop_request
    enable_view "$STOP_BTN_ID" 0
    set_status "Nothing is running"
    exit 0
fi

request_stop

# The only window change this handler makes. The stage that is unwinding owns
# the rail and the log, and will overwrite this line with its own the moment it
# gets there.
set_status "Stopping..."

exit 0
