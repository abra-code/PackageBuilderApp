#!/bin/sh
# PackageBuilder.notarize.sh - hand the signed package to Notarize.app
#
# Design 11.1: PackageBuilder ends at a signed package. Notarize.app already has
# the credential wizard, the submit/wait loop and the stapling, and takes a flat
# .pkg as a first-class target, so duplicating any of it here would mean two
# credential wizards to keep in step for a step run once per release.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.build.sh"

dbg_context "PackageBuilder.notarize.sh"

has_model || exit 0

package_path="$(built_package_path)"
if [ -z "$package_path" ]; then
    set_status "Build and sign a package first"
    exit 0
fi

# By bundle id first, so whichever copy of Notarize.app Launch Services knows
# about is the one that opens.
if /usr/bin/open -b com.abracode.notarize "$package_path" 2>/dev/null; then
    set_status "Handed $(/usr/bin/basename "$package_path") to Notarize"
    exit 0
fi

# Falling back to a path means Notarize is installed but not registered.
for candidate in /Applications/Notarize.app "$HOME/Applications/Notarize.app"; do
    if [ -d "$candidate" ]; then
        if /usr/bin/open -a "$candidate" "$package_path" 2>/dev/null; then
            set_status "Handed $(/usr/bin/basename "$package_path") to Notarize"
            exit 0
        fi
    fi
done

# Reported plainly rather than failing silently (design 11.1).
set_status "Notarize.app was not found - the signed package is at $package_path"

exit 0
