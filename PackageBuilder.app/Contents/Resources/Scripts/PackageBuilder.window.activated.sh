#!/bin/sh
# PackageBuilder.window.activated.sh - notice that the document changed on disk
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"

dbg_context "PackageBuilder.window.activated.sh"

has_model || exit 0

path="$(doc_path)"
[ -n "$path" ] || exit 0

stored="$(stored_doc_hash)"
[ -n "$stored" ] || exit 0

if [ ! -f "$path" ]; then
    set_status "The project file is no longer at $path"
    exit 0
fi

current="$(file_hash "$path")"
[ -n "$current" ] || exit 0
[ "$current" = "$stored" ] && exit 0

dbg "activated: file changed on disk"

if is_dirty; then
    "$alert_tool" \
        --level caution \
        --title "Changed on Disk" \
        --ok "Keep My Changes" \
        --cancel "Reload from Disk" \
        "\"$(document_name)\" has been changed by another program, and this window has unsaved changes of its own."
    answer=$?
    # alert returns 0 OK, 1 Cancel, 2 Other, 3 timeout, 255 error. Only an
    # explicit Cancel - the button that says "discard my edits" - may reload.
    # A timeout or a failed alert keeps the user's work.
    if [ "$answer" != "1" ]; then
        # Adopt the on-disk hash so the same question is not asked on every
        # activation; the window's changes stay, and saving will overwrite.
        store_doc_hash "$path"
        if [ "$answer" = "0" ]; then
            set_status "Keeping this window's changes"
        else
            dbg "activated: alert returned $answer, keeping changes"
            set_status "\"$(document_name)\" changed on disk - this window's changes were kept"
        fi
        exit 0
    fi
fi

if load_document "$path"; then
    push_model_to_window
    refresh_window_title
    set_status "Reloaded $(document_name) - it changed on disk"
else
    # Record the hash anyway. Without this the same failing reload is attempted
    # on every single activation, forever.
    store_doc_hash "$path"
    set_status "Could not reload $(document_name) - it changed on disk and is no longer a readable project"
fi

exit 0
