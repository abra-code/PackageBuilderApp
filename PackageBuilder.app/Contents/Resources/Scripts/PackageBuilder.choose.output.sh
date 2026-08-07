#!/bin/sh
# PackageBuilder.choose.output.sh - pick the folder the signed package goes to
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"

dbg_context "PackageBuilder.choose.output.sh"

store_browsed_path "$OUTPUT_DIR_ID" "$OMC_DLG_CHOOSE_FOLDER_PATH"

exit 0
