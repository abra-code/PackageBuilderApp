#!/bin/sh
# PackageBuilder.payload.scan.sh - add every artifact found under a folder
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"

dbg_context "PackageBuilder.payload.scan.sh"

chosen="$OMC_DLG_CHOOSE_FOLDER_PATH"
if [ -z "$chosen" ]; then
    # Canceled.
    exit 0
fi

has_model || exit 0

abs="$(canonical_path "$chosen")"
[ -n "$abs" ] || abs="$chosen"

if [ ! -d "$abs" ]; then
    set_status "That folder is no longer there"
    exit 0
fi

# The walk runs BEFORE the lock is taken, and that ordering is the point rather
# than a tidiness. It is the only piece of work in the app whose size the user
# picks - the panel will happily hand over a home folder - and the model lock is
# held across a whole handler. Walking under it would wedge the window on "Busy"
# for however long the tree takes, and the lock's recovery reclaims a dead
# holder, never a running one. Nothing here writes to the model, so there is
# nothing to protect until the appending starts.
#
# The file name carries this handler's pid, because state_dir is per WINDOW and
# the scan button is never disabled while a scan runs. A second click during a
# long scan truncated the file the first run was still reading - silently, since
# a short read is not an error - and the first run then reported "Added 3" while
# thirty-seven artifacts vanished. The second scan is harmless on its own: the
# model lock serializes the two appends, and whichever comes second either finds
# the first one's entries and dedupes them or gives up with "Busy". Found in
# review, 2026-08-22.
found="$(state_dir)/scan-found-$$.txt"
set_status "Scanning $(/usr/bin/basename "$abs")..."
if ! scan_artifacts "$abs" "$found"; then
    /bin/rm -f "$found"
    set_status "Could not read that folder"
    exit 0
fi

if [ ! -s "$found" ]; then
    /bin/rm -f "$found"
    if [ "$pb_scan_truncated" = "1" ]; then
        set_status "No artifacts in the part of that folder that was searched - try a folder further in"
    else
        set_status "No bundles or executables under $(/usr/bin/basename "$abs")"
    fi
    exit 0
fi

if ! model_lock; then
    /bin/rm -f "$found"
    set_status "Busy - nothing was added, please try again"
    exit 0
fi

# What the payload already installs, resolved to absolute paths, so a second
# scan of the same folder adds nothing rather than doubling every row.
#
# An entry whose source cannot be resolved - a ${ARTIFACTS_DIR} source in a
# document with no artifacts folder - contributes no line, so it will not match
# and its artifact may be added a second time. That is the honest outcome: the
# alternative is to collapse the token and compare against a path that means
# something else entirely, which is the mistake resolve_stored_path exists to
# refuse.
#
# Only the stored side needs canonical_or_self here; the scanned side is already
# canonical by construction, because the root went through canonical_path above
# and the walk never crosses a symlink. Normalizing the stored side is
# load-bearing rather than tidiness, and relative_to carries the same note for
# the same reason: the scan yields /private/var/..., while a source resolved
# against the document's folder yields whatever the document was opened as, and
# on macOS that is /var/... The two name one file and compare unequal, so
# without this a rescan of a folder duplicated every row in it. Found by
# section 53.
existing="$(state_dir)/scan-existing-$$.txt"
: > "$existing"
entry_count="$(payload_count)"
existing_index=0
while [ "$existing_index" -lt "$entry_count" ]; do
    resolved="$(resolve_stored_path "$(payload_get "$existing_index" SOURCE)")" &&
        [ -n "$resolved" ] &&
        printf '%s\n' "$(canonical_or_self "$resolved")" >> "$existing"
    existing_index=$((existing_index + 1))
done

added=0
duplicate=0
unreadable=0
noguess=0
last=""

# Read from a file rather than a pipe, and with IFS cleared: "cmd | while read"
# runs the loop in a subshell and every count it keeps is discarded at the end
# of it, and a leading or trailing space is part of a file's name.
while IFS= read -r artifact; do
    [ -n "$artifact" ] || continue
    # The same guard PackageBuilder.payload.drop.sh puts on a dropped path, and
    # for a sharper reason here: payload_append_from_path succeeds on a path
    # that is not there - guess_destination falls through to the previous
    # entry's directory, and is_bundle and is_macho_image simply say no - so a
    # bad line became a real payload row reported as a success. Three things
    # feed bad lines in. A file name containing a newline arrives as two lines,
    # neither naming a file. The walk and this loop are minutes apart on a large
    # scan, so an artifact can be gone by the time its turn comes. And a build
    # that runs during the scan can replace a file mid-flight. Found in review,
    # 2026-08-22.
    if [ ! -e "$artifact" ]; then
        dbg "payload.scan: [$artifact] is no longer there"
        unreadable=$((unreadable + 1))
        continue
    fi
    if /usr/bin/grep -q -x -F -e "$artifact" "$existing" 2>/dev/null; then
        duplicate=$((duplicate + 1))
        continue
    fi
    entry_index="$(payload_append_from_path "$artifact")"
    if [ -z "$entry_index" ]; then
        dbg "payload.scan: could not add [$artifact]"
        unreadable=$((unreadable + 1))
        continue
    fi
    fill_project_fields_from_artifact "$artifact"
    if [ -z "$(payload_get "$entry_index" DESTINATION)" ]; then
        noguess=$((noguess + 1))
    fi
    added=$((added + 1))
    last="$entry_index"
done < "$found"

/bin/rm -f "$found" "$existing"

if [ "$added" -gt 0 ]; then
    mark_dirty
    repopulate_payload "$last"
    # push_model_to_window is deliberately not used here, for the reason
    # PackageBuilder.payload.drop.sh gives: it would rewrite every control on
    # every tab for the sake of the three project fields that may have been
    # filled in, resetting a field the user happens to be typing in.
    set_value "$NAME_ID" "$(model_get /PROJECT/NAME)"
    set_value "$VERSION_ID" "$(model_get /PROJECT/VERSION)"
    set_value "$MIN_OS_ID" "$(model_get /PROJECT/MIN_OS_VERSION)"
fi

model_unlock

# Every count that is not zero is reported. A scan is a bulk operation and the
# user did not watch it happen, so "added 3" that quietly swallowed "and skipped
# 11 you already had" describes a fraction of the outcome.
if [ "$added" = "0" ]; then
    if [ "$duplicate" -gt 0 ]; then
        summary="Everything found is already in the payload"
    else
        summary="Nothing was added - what was found could not be read"
    fi
else
    summary="Added $added artifact(s)"
    if [ "$noguess" -gt 0 ]; then
        summary="$summary; $noguess still need a destination"
    fi
    if [ "$duplicate" -gt 0 ]; then
        summary="$summary; $duplicate already in the payload"
    fi
    if [ "$unreadable" -gt 0 ]; then
        summary="$summary; $unreadable could not be read"
    fi
fi
if [ "$pb_scan_truncated" = "1" ]; then
    summary="$summary. That folder is too large to search in full - point the scan further in"
fi
set_status "$summary"

exit 0
