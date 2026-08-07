#!/bin/sh
# PackageBuilder.payload.drop.sh - files or folders dropped on the payload table
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"

dbg_context "PackageBuilder.payload.drop.sh"

has_model || exit 0

if ! model_lock; then
    set_status "Busy - the drop was not applied, please try again"
    exit 0
fi

# The dropped paths go to a file and the loop reads from it rather than from a
# pipe: a "cmd | while read" loop runs in a subshell, and every count it kept
# would be discarded at the end of it.
items="$(state_dir)/drop-items.txt"
/bin/rm -f "$items"
dropped_paths "$OMC_ACTIONUI_TRIGGER_CONTEXT" > "$items"

added=0
unreadable=0
noguess=0
last=""

# A path may contain anything except a newline, so lines are read whole and IFS
# is cleared to keep leading and trailing spaces in a name.
while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ ! -e "$p" ]; then
        dbg "payload.drop: [$p] does not exist"
        unreadable=$((unreadable + 1))
        continue
    fi
    abs="$(canonical_path "$p")"
    [ -n "$abs" ] || abs="$p"
    idx="$(payload_append_from_path "$abs")"
    if [ -z "$idx" ]; then
        dbg "payload.drop: could not add [$abs]"
        unreadable=$((unreadable + 1))
        continue
    fi
    fill_project_fields_from_artifact "$abs"
    if [ -z "$(payload_get "$idx" DESTINATION)" ]; then
        noguess=$((noguess + 1))
    fi
    added=$((added + 1))
    last="$idx"
done < "$items"

/bin/rm -f "$items"

if [ "$added" -gt 0 ]; then
    mark_dirty
    repopulate_payload "$last"
    # push_model_to_window is deliberately not used here: it would rewrite every
    # control on every tab for the sake of the three project fields that may
    # have been filled in, resetting a field the user happens to be typing in.
    set_value "$NAME_ID" "$(model_get /PROJECT/NAME)"
    set_value "$VERSION_ID" "$(model_get /PROJECT/VERSION)"
    set_value "$MIN_OS_ID" "$(model_get /PROJECT/MIN_OS_VERSION)"
fi

model_unlock

# Both counts are reported when both are non-zero: an "n need a destination"
# that quietly swallowed "m could not be read" would describe half the outcome.
if [ "$added" = "0" ]; then
    set_status "Nothing was added - the dropped items could not be read"
else
    summary="Added $added item(s)"
    if [ "$noguess" -gt 0 ]; then
        summary="$summary; $noguess still need a destination"
    fi
    if [ "$unreadable" -gt 0 ]; then
        summary="$summary; $unreadable could not be read"
    fi
    set_status "$summary"
fi

exit 0
