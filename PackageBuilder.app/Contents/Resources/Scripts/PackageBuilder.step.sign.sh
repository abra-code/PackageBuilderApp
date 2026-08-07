#!/bin/sh
# PackageBuilder.step.sign.sh - sign the distribution package into the output folder
#
# Pipeline stage 4 of design section 7, run on its own from Actions > Sign Only.
# It consumes the unsigned distribution package stage 3 produced.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.build.sh"

dbg_context "PackageBuilder.step.sign.sh"

has_model || exit 0

if build_is_running; then
    set_status "A build is already running"
    exit 0
fi

unsigned="$(built_distribution_path)"
if [ -z "$unsigned" ]; then
    set_status "Build the distribution package first"
    exit 0
fi

if [ "$(model_get_bool /SIGNING/ENABLED)" != "1" ]; then
    set_status "Signing is turned off for this project"
    exit 0
fi

PB_BUILD_DATE="$(/bin/date '+%Y-%m-%d')"
export PB_BUILD_DATE

build_begin
clear_log
rail_reset
rail_set "$RAIL_VERIFY_ID" skipped
rail_set "$RAIL_COMPONENT_ID" done
rail_set "$RAIL_DISTRIBUTION_ID" done
/bin/rm -f "$(state_dir)/built_package.txt"
show_view "$REVEAL_BTN_ID" 0
# Turned off with Reveal: a failed rebuild deletes built_package.txt, and an
# enabled Notarize button would still be offering the package it just removed.
enable_view "$NOTARIZE_BTN_ID" 0

set_status "Checking the signing settings..."
append_log "Signing $(document_name)"
append_log ""
append_log "Preconditions:"

check_signing_preconditions
failures="$precondition_failures"
if [ "$failures" != "0" ]; then
    append_log ""
    append_log "Stopped: $failures problem(s) to fix. Nothing was written to the output folder."
    rail_set "$RAIL_SIGN_ID" failed
    set_status "$failures problem(s) - nothing was written"
    build_end
    exit 0
fi
append_log "  all clear"
append_log ""

rail_set "$RAIL_SIGN_ID" running
set_status "Running productsign..."
append_log "Signing the installer package:"

signed="$(sign_package "$unsigned")"
if [ -z "$signed" ] || [ ! -f "$signed" ]; then
    stop_here "$RAIL_SIGN_ID" && exit 0
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

set_status "Signed $(/usr/bin/basename "$signed")"
build_end

exit 0
