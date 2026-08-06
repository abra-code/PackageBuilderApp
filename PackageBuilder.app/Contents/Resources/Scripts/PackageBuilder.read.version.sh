#!/bin/sh
# PackageBuilder.read.version.sh - read PROJECT.VERSION out of the selected artifact
#
# Design 4.5: this overwrites whatever is in the field, unlike the fill-on-add
# path, because the user asked for it explicitly.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"

dbg_context "PackageBuilder.read.version.sh"

has_model || exit 0

idx="$(selected_payload_index)"
if [ -z "$idx" ]; then
    set_status "Select a payload item first - the version is read from it"
    exit 0
fi

stored_source="$(payload_get "$idx" SOURCE)"

# Refused rather than resolved: with no artifacts folder set, a source of
# ${ARTIFACTS_DIR}/usr/local/bin/replay collapses to /usr/local/bin/replay,
# which is very likely the previously *installed* copy. Reading its version
# would report the last release as the new one - the stale-artifact mistake the
# verify stage exists to catch - and say so in a confident status line.
if uses_unset_artifacts_dir "$stored_source"; then
    set_status "Set the artifacts folder first - this source uses \${ARTIFACTS_DIR}"
    exit 0
fi

src="$(resolve_stored_path "$stored_source")"
if [ -z "$src" ] || [ ! -e "$src" ]; then
    set_status "The selected item's source is not on disk"
    exit 0
fi

flag="$(payload_get "$idx" VERIFY/VERSION_FLAG)"
v="$(artifact_version "$src" "$flag")"

if [ -z "$v" ]; then
    if is_bundle "$src"; then
        set_status "No CFBundleShortVersionString in $(/usr/bin/basename "$src")"
    elif [ -z "$flag" ]; then
        set_status "Set a version flag for $(/usr/bin/basename "$src") to read its version"
    else
        set_status "$(/usr/bin/basename "$src") $flag did not print a version"
    fi
    exit 0
fi

if ! model_lock; then
    set_status "Busy - the version was not changed, please try again"
    exit 0
fi

if [ "$v" = "$(model_get /PROJECT/VERSION)" ]; then
    model_unlock
    set_status "Version is already $v"
    exit 0
fi

if ! model_set /PROJECT/VERSION "$v"; then
    model_unlock
    set_status "Could not record the version"
    exit 0
fi

mark_dirty
pb_set pb_loading "$(/bin/date '+%s')"
set_value "$VERSION_ID" "$v"
pb_set pb_loading ""
model_unlock

set_status "Version read from $(/usr/bin/basename "$src"): $v"

exit 0
