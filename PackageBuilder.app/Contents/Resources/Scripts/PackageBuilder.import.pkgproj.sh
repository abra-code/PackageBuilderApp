#!/bin/sh
# PackageBuilder.import.pkgproj.sh - import a Packages.app project
#
# Design section 10: the settings, the install location, the payload hierarchy,
# the readme and the build path come across; the presentation model beyond the
# readme, the excluded-file patterns, the requirement list and the filesystem
# template tree do not, and the log says so. The import lands in the current
# document, which is why it marks the document dirty rather than saving: what
# was imported is a proposal until the user saves it.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.build.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.import.sh"

dbg_context "PackageBuilder.import.pkgproj.sh"

chosen="$OMC_DLG_CHOOSE_FILE_PATH"
if [ -z "$chosen" ]; then
    # Canceled.
    exit 0
fi

has_model || exit 0

if build_is_running; then
    set_status "A build is running - import once it has finished"
    exit 0
fi

if [ ! -r "$chosen" ]; then
    set_status "That project cannot be read"
    exit 0
fi

if ! model_lock; then
    set_status "Busy - nothing was imported, please try again"
    exit 0
fi

clear_log
if ! import_pkgproj "$chosen"; then
    model_unlock
    set_status "Nothing usable in $(/usr/bin/basename "$chosen") - see the log"
    exit 0
fi

mark_dirty
model_unlock

# The whole window, not a field at a time: the import touched the project, the
# component, the payload and the distribution resources.
# The document was replaced wholesale, so the component the window was left on
# has nothing to do with the components it holds now. Only on the way OUT, and
# only here: this persists the selection and discards the payload selection, so
# doing it before the import would move the window's state on a refusal that
# changed nothing, leaving the sidebar showing one component while every handler
# edited another. The import pins its own index in a shell variable instead.
set_current_component_index 0
push_model_to_window

set_status "Imported $(/usr/bin/basename "$chosen") - review, then save"

exit 0
