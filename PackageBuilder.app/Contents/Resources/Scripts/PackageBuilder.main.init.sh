#!/bin/sh
# PackageBuilder.main.init.sh - load the document into a window that is opening
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"

dbg_context "PackageBuilder.main.init.sh"

# A path here means the window was opened for a document (double-click, drop, or
# the Open panel chaining through PackageBuilder.main); no path means File > New.
doc="$OMC_OBJ_PATH"

dbg "init: doc=[$doc]"

opened=0
if [ -n "$doc" ]; then
    if load_document "$doc"; then
        opened=1
    else
        dbg "init: load_document failed for [$doc]"
    fi
fi

if [ "$opened" != "1" ]; then
    if ! new_document; then
        # Without a model every later handler exits silently at its has_model
        # guard, so the window would accept typing and save nothing.
        dbg "init: new_document failed"
        set_status "Could not start a new project - the document template is missing"
        exit 0
    fi
fi

push_model_to_window
refresh_window_title

if [ "$opened" = "1" ]; then
    set_status "Opened $(document_name)"
elif [ -n "$doc" ]; then
    set_status "Not a PackageBuilder project: $(/usr/bin/basename "$doc")"
else
    set_status "New project"
fi

exit 0
