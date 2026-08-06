#!/bin/sh
# PackageBuilder.main.sh - document entry point: a path means Open, none means New
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"

dbg_context "PackageBuilder.main.sh"

# Nothing to do here. The window this command owns is non-blocking, so this
# script runs at a time that is not ordered against the window's appearance.
# All loading happens in PackageBuilder.main.init (the INIT_SUBCOMMAND_ID),
# which runs as the window loads and is given the same OMC_OBJ_PATH - verified
# on 2026-08-05 by logging both handlers: init ran first and received the
# double-clicked document's path.

exit 0
