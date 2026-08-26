#!/bin/sh
# PackageBuilder.inspect.sh - take the built package apart and report what is in it
#
# Actions > Inspect Built Package. Read-only: it expands a copy into the scratch
# directory, reports, and removes it. Nothing it does can change the package.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.build.sh"

dbg_context "PackageBuilder.inspect.sh"

has_model || exit 0

# Refused while a build runs, even though inspecting cannot damage anything: the
# stage that would be rewriting the package underneath is patch_overwrite_
# permissions, whose expand/flatten round trip deletes and recreates the file.
# A report read off a package mid-rebuild describes neither the old one nor the
# new one.
if build_is_running; then
    set_status "A build is running - inspect it when that finishes"
    exit 0
fi

# The most finished package there is. Design 8.3 keeps an unsigned build out of
# the output folder, so with signing turned off there is no signed package and
# the distribution package is the finished article; after Build Component Only
# there is only the component. Each is worth inspecting, and which one is being
# looked at is the first thing the report says - a user reading a signature
# section for a component package needs to know that is what it is.
kind="signed installer package"
package_path="$(built_package_path)"
if [ -z "$package_path" ]; then
    kind="unsigned distribution package"
    package_path="$(built_distribution_path)"
fi
if [ -z "$package_path" ]; then
    kind="component package"
    package_path="$(built_component_path)"
fi

if [ -z "$package_path" ]; then
    set_status "Build a package first - there is nothing to inspect"
    exit 0
fi

clear_log
# The step rail is deliberately left alone. It records how the package on disk
# was made, which is context for the report rather than something the report
# supersedes; resetting it would throw that away to say nothing.
set_status "Inspecting $(/usr/bin/basename "$package_path")..."

if ! inspect_package "$package_path" "$kind"; then
    set_status "Could not read that package"
    exit 0
fi

set_status "Inspected $(/usr/bin/basename "$package_path")"

exit 0
