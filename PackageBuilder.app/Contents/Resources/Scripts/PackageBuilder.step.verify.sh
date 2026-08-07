#!/bin/sh
# PackageBuilder.step.verify.sh - check the payload against what the document claims
#
# Pipeline stage 1 of design section 7, run on its own from Actions > Verify
# Payload. The three stages after it are marked skipped rather than left gray,
# so the rail says what did and did not run rather than showing three circles
# that could be read as pending.
#
# Nothing is written anywhere by this stage. It reads the artifacts and reports,
# which is what makes it the one stage that is safe to run at any time - before
# a release, after replacing an artifact, or just to find out why the last build
# refused.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.build.sh"

dbg_context "PackageBuilder.step.verify.sh"

has_model || exit 0

if build_is_running; then
    set_status "A build is already running"
    exit 0
fi

build_begin
clear_log
rail_reset
rail_set "$RAIL_COMPONENT_ID" skipped
rail_set "$RAIL_DISTRIBUTION_ID" skipped
rail_set "$RAIL_SIGN_ID" skipped

set_status "Checking the project..."
append_log "Verifying the payload of $(document_name)"
append_log ""
append_log "Preconditions:"

# The payload preconditions run first even though this stage writes nothing:
# resolve_stored_path refuses an unset ${ARTIFACTS_DIR} without saying why, and
# "is not on disk" for every item in turn is a worse answer than one line naming
# the folder that was never set.
check_preconditions
failures="$precondition_failures"
if [ "$failures" != "0" ]; then
    append_log ""
    append_log "Stopped: $failures problem(s) to fix before the payload can be verified."
    rail_set "$RAIL_VERIFY_ID" failed
    set_status "$failures problem(s) in the project"
    build_end
    exit 0
fi
append_log "  all clear"
append_log ""

rail_set "$RAIL_VERIFY_ID" running
set_status "Verifying the payload..."
append_log "Verifying the payload:"

if ! verify_payload; then
    stop_here "$RAIL_VERIFY_ID" && exit 0
    append_log ""
    append_log "Stopped. An artifact is not what the document says it is."
    rail_set "$RAIL_VERIFY_ID" failed
    set_status "The payload did not verify"
    build_end
    exit 0
fi

stop_here "$RAIL_VERIFY_ID" && exit 0
rail_set "$RAIL_VERIFY_ID" done
append_log ""
append_log "Every artifact matches what the document asserts about it."
append_log ""
append_log "This checked the artifacts, not the package: nothing was staged and"
append_log "nothing was built."

set_status "The payload verified"
build_end

exit 0
