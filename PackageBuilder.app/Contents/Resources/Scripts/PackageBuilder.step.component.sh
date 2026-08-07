#!/bin/sh
# PackageBuilder.step.component.sh - stage the payload and build the component package
#
# Pipeline stage 2 of design section 7, run on its own from Actions > Build
# Component Only. The verify stage before it and the distribution and signing
# stages after it are not run here; their rail stages are marked skipped so the
# rail says what did and did not run rather than leaving three gray circles that
# could be read as pending.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.build.sh"

dbg_context "PackageBuilder.step.component.sh"

has_model || exit 0

if build_is_running; then
    set_status "A build is already running"
    exit 0
fi

# ${DATE} is computed once per build and held for its whole length (design 4.4),
# so a run that crosses midnight cannot name two files two different things.
PB_BUILD_DATE="$(/bin/date '+%Y-%m-%d')"
export PB_BUILD_DATE

build_begin
clear_log
rail_reset
rail_set "$RAIL_VERIFY_ID" skipped
rail_set "$RAIL_DISTRIBUTION_ID" skipped
rail_set "$RAIL_SIGN_ID" skipped
/bin/rm -f "$(state_dir)/built_component.txt"

set_status "Checking the project..."
append_log "Building the component package for $(document_name)"
append_log ""
append_log "Preconditions:"

check_preconditions
failures="$precondition_failures"
if [ "$failures" != "0" ]; then
    append_log ""
    append_log "Stopped: $failures problem(s) to fix before anything can be built."
    rail_set "$RAIL_COMPONENT_ID" failed
    set_status "$failures problem(s) - nothing was written"
    build_end
    exit 0
fi
append_log "  all clear"
append_log ""

rail_set "$RAIL_COMPONENT_ID" running
set_status "Staging the payload..."
append_log "Staging the payload root:"

if ! stage_payload_root; then
    stop_here "$RAIL_COMPONENT_ID" && exit 0
    append_log ""
    append_log "Stopped while staging. Nothing outside the scratch directory was touched."
    rail_set "$RAIL_COMPONENT_ID" failed
    set_status "Could not stage the payload"
    build_end
    exit 0
fi

append_log ""
set_status "Running pkgbuild..."
append_log "Building the component package:"

pkg="$(build_component_package)"
if [ -z "$pkg" ] || [ ! -f "$pkg" ]; then
    stop_here "$RAIL_COMPONENT_ID" && exit 0
    append_log ""
    append_log "Stopped. pkgbuild did not produce a component package."
    rail_set "$RAIL_COMPONENT_ID" failed
    set_status "The component package was not built"
    build_end
    exit 0
fi

printf '%s' "$pkg" > "$(state_dir)/built_component.txt"

rail_set "$RAIL_COMPONENT_ID" done
append_log ""
append_log "Component package: $pkg"
append_log ""
append_log "This is an intermediate and stays in the scratch directory. It is not"
append_log "a distributable installer: that needs the distribution and signing"
append_log "stages, which Build Package runs for you."
append_log ""
append_log "Inspect it with:  pkgutil --expand \"$pkg\" /tmp/expanded"

set_status "Built $(/usr/bin/basename "$pkg")"
build_end

exit 0
