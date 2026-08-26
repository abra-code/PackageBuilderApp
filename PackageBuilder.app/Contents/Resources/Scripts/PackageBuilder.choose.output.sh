#!/bin/sh
# PackageBuilder.choose.output.sh - pick the folder the signed package goes to
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"

dbg_context "PackageBuilder.choose.output.sh"

store_browsed_path "$OUTPUT_DIR_ID" "$OMC_DLG_CHOOSE_FOLDER_PATH"

# Remembered from the panel and not from the text field: choosing a folder is a
# deliberate act, while typing into the field is an edit in progress and would
# have every intermediate path remembered as it was typed.
#
# The absolute path, not what store_browsed_path recorded - that is relative to
# the document when the folder sits below it (design 4.2), and a preference
# other projects read has nothing to resolve a relative path against.
remember_default_output_dir "$(canonical_or_self "$OMC_DLG_CHOOSE_FOLDER_PATH")"

exit 0
