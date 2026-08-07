#!/bin/sh
# PackageBuilder.reveal.sh - show the signed package in the Finder
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.build.sh"

dbg_context "PackageBuilder.reveal.sh"

has_model || exit 0

package_path="$(built_package_path)"
if [ -z "$package_path" ]; then
    set_status "There is no built package to reveal"
    exit 0
fi

/usr/bin/open -R "$package_path"

exit 0
