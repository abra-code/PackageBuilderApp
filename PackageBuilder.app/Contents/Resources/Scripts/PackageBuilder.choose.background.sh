#!/bin/sh
# PackageBuilder.choose.background.sh - pick the background image through a Choose panel
#
# One command per Browse button, following Notarize.app: the dialog is declared
# per command, so the command already knows which field it serves and no handler
# has to work it out. A single shared handler keyed on
# OMC_ACTIONUI_TRIGGER_VIEW_ID would collapse these into one, but whether that
# id survives the engine's dialog presentation is unverified - every handler
# already logs it through dbg_context, so the next real run answers it.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"

dbg_context "PackageBuilder.choose.background.sh"

store_browsed_path "$BACKGROUND_ID" "$OMC_DLG_CHOOSE_FILE_PATH"

exit 0
