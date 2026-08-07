#!/bin/sh
# PackageBuilder.build.sh - the whole pipeline, from the toolbar's Build Package
#
# Stages 2, 3 and 4 of design section 7 in one run. Stage 1, the payload verify,
# is a later phase; its rail stage is marked skipped rather than left grey so
# the rail says what did and did not run.
#
# Every stage's preconditions are checked up front, before anything is written.
# Discovering a missing output folder after pkgbuild and productbuild have
# already run would mean the user waits through the whole build to be told
# something that was knowable at the start.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.build.sh"

dbg_context "PackageBuilder.build.sh"

has_model || exit 0

if build_is_running; then
    set_status "A build is already running"
    exit 0
fi

# Fixed once for the whole run, so a build that crosses midnight cannot name
# two files two different things (design 4.4).
PB_BUILD_DATE="$(/bin/date '+%Y-%m-%d')"
export PB_BUILD_DATE

signing_on="$(model_get_bool /SIGNING/ENABLED)"

build_begin
clear_log
rail_reset
rail_set "$RAIL_VERIFY_ID" skipped
/bin/rm -f "$(state_dir)/built_component.txt" \
           "$(state_dir)/built_distribution.txt" \
           "$(state_dir)/built_package.txt"
show_view "$REVEAL_BTN_ID" 0
# Turned off with Reveal: a failed rebuild deletes built_package.txt, and an
# enabled Notarize button would still be offering the package it just removed.
enable_view "$NOTARIZE_BTN_ID" 0

set_status "Checking the project..."
append_log "Building $(document_name)"
append_log ""
append_log "Preconditions:"

# The count comes from the shared global after each call, not from the return
# value: a shell return carries only the low eight bits, so a count of exactly
# 256 would arrive here as zero and wave the build through. Each function resets
# the global on entry, so it is read immediately after each one.
total_failures=0
check_preconditions
total_failures=$((total_failures + precondition_failures))
check_distribution_preconditions
total_failures=$((total_failures + precondition_failures))
if [ "$signing_on" = "1" ]; then
    check_signing_preconditions
    total_failures=$((total_failures + precondition_failures))
fi

if [ "$total_failures" != "0" ]; then
    append_log ""
    append_log "Stopped: $total_failures problem(s) to fix before anything can be built."
    rail_set "$RAIL_COMPONENT_ID" failed
    set_status "$total_failures problem(s) - nothing was written"
    build_end
    exit 0
fi
append_log "  all clear"
append_log ""

# --- Stage 2: component -------------------------------------------------------
rail_set "$RAIL_COMPONENT_ID" running
set_status "Staging the payload..."
append_log "Staging the payload root:"
if ! stage_payload_root; then
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
component="$(build_component_package)"
if [ -z "$component" ] || [ ! -f "$component" ]; then
    append_log ""
    append_log "Stopped. pkgbuild did not produce a component package."
    rail_set "$RAIL_COMPONENT_ID" failed
    set_status "The component package was not built"
    build_end
    exit 0
fi
printf '%s' "$component" > "$(state_dir)/built_component.txt"
rail_set "$RAIL_COMPONENT_ID" done

# --- Stage 3: distribution ----------------------------------------------------
append_log ""
rail_set "$RAIL_DISTRIBUTION_ID" running
set_status "Running productbuild..."
append_log "Building the distribution package:"
unsigned="$(build_distribution_package)"
if [ -z "$unsigned" ] || [ ! -f "$unsigned" ]; then
    append_log ""
    append_log "Stopped. productbuild did not produce a distribution package."
    rail_set "$RAIL_DISTRIBUTION_ID" failed
    set_status "The distribution package was not built"
    build_end
    exit 0
fi
printf '%s' "$unsigned" > "$(state_dir)/built_distribution.txt"
rail_set "$RAIL_DISTRIBUTION_ID" done

# --- Stage 4: sign ------------------------------------------------------------
if [ "$signing_on" != "1" ]; then
    # Design 8.3: the output folder only ever receives a signed package, so an
    # unsigned build ends in the scratch directory and says so.
    rail_set "$RAIL_SIGN_ID" skipped
    append_log ""
    append_log "Signing is turned off, so nothing was written to the output folder."
    append_log "The unsigned package is an intermediate and stays here:"
    append_log "  $unsigned"
    set_status "Built $(/usr/bin/basename "$unsigned") (unsigned)"
    build_end
    exit 0
fi

append_log ""
rail_set "$RAIL_SIGN_ID" running
set_status "Running productsign..."
append_log "Signing the installer package:"
signed="$(sign_package "$unsigned")"
if [ -z "$signed" ] || [ ! -f "$signed" ]; then
    append_log ""
    append_log "Stopped. The package was not signed, and nothing was left in the output folder."
    rail_set "$RAIL_SIGN_ID" failed
    set_status "The package was not signed"
    build_end
    exit 0
fi
printf '%s' "$signed" > "$(state_dir)/built_package.txt"
rail_set "$RAIL_SIGN_ID" done

show_view "$REVEAL_BTN_ID" 1
enable_view "$NOTARIZE_BTN_ID" 1
append_log ""
append_log "Signed package: $signed"
append_log ""
append_log "This package is signed but NOT notarized. macOS will refuse to install it"
append_log "on another Mac until it has been through the Apple notary service."
append_log ""
append_log "One step left: hand it to Notarize.app with the Notarize button, and turn"
append_log "its \"Sign before submitting\" option off - this package is already signed,"
append_log "so Notarize should verify that signature rather than replace it."

set_status "Built $(/usr/bin/basename "$signed")"
build_end

exit 0
