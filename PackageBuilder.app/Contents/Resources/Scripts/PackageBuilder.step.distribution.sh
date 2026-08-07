#!/bin/sh
# PackageBuilder.step.distribution.sh - wrap the component package in a distribution
#
# Pipeline stage 3 of design section 7, run on its own from Actions > Build
# Distribution Only. It consumes the component package stage 2 produced rather
# than rebuilding it: "Only" means only, and silently running an earlier stage
# would make the partial actions indistinguishable from the full build.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.build.sh"

dbg_context "PackageBuilder.step.distribution.sh"

has_model || exit 0

if build_is_running; then
    set_status "A build is already running"
    exit 0
fi

component="$(built_component_path)"
if [ -z "$component" ]; then
    set_status "Build the component package first"
    exit 0
fi

PB_BUILD_DATE="$(/bin/date '+%Y-%m-%d')"
export PB_BUILD_DATE

build_begin
clear_log
rail_reset
rail_set "$RAIL_VERIFY_ID" skipped
rail_set "$RAIL_COMPONENT_ID" done
rail_set "$RAIL_SIGN_ID" skipped
/bin/rm -f "$(state_dir)/built_distribution.txt"

set_status "Checking the distribution settings..."
append_log "Building the distribution package for $(document_name)"
append_log ""
append_log "Using component package: $component"
append_log ""
append_log "Preconditions:"

check_distribution_preconditions
failures="$precondition_failures"
if [ "$failures" != "0" ]; then
    append_log ""
    append_log "Stopped: $failures problem(s) to fix before anything can be built."
    rail_set "$RAIL_DISTRIBUTION_ID" failed
    set_status "$failures problem(s) - nothing was written"
    build_end
    exit 0
fi
append_log "  all clear"
append_log ""

rail_set "$RAIL_DISTRIBUTION_ID" running
set_status "Running productbuild..."
append_log "Building the distribution package:"

unsigned="$(build_distribution_package)"
if [ -z "$unsigned" ] || [ ! -f "$unsigned" ]; then
    stop_here "$RAIL_DISTRIBUTION_ID" && exit 0
    append_log ""
    append_log "Stopped. productbuild did not produce a distribution package."
    rail_set "$RAIL_DISTRIBUTION_ID" failed
    set_status "The distribution package was not built"
    build_end
    exit 0
fi

printf '%s' "$unsigned" > "$(state_dir)/built_distribution.txt"

rail_set "$RAIL_DISTRIBUTION_ID" done
append_log ""
append_log "Unsigned distribution package: $unsigned"
append_log ""
append_log "This is an intermediate and stays in the scratch directory. Nothing is"
append_log "written to the output folder until it has been signed, so an unsigned"
append_log "package can never sit one word away from the one you upload."
append_log ""
append_log "Inspect it with:  pkgutil --expand \"$unsigned\" /tmp/expanded"

set_status "Built $(/usr/bin/basename "$unsigned")"
build_end

exit 0
