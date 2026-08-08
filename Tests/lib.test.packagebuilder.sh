#!/bin/sh
# lib.test.packagebuilder.sh - PackageBuilder's own test vocabulary.
#
# Sourced by every Tests/*.test.sh file, after omctest.sh. omctest provides the
# generic half - the scratch tree, the interposition directory, the alert and
# omc_dialog_control stubs, check/section/omctest_end, the alerts_* helpers - and
# knows nothing about this applet. Everything below encodes PackageBuilder's
# private layout: where its model lives, what it names its state files, which
# pasteboard keys it uses, and how to call into its libraries directly.
#
# That split is deliberate (design 8): the harness has no business knowing an
# applet's state layout, and this file has no business reimplementing a scratch
# directory.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".

# --- Where the applet keeps things --------------------------------------------

# The app computes this as "${TMPDIR:-/tmp}/packagebuilder-state-${document_uuid}"
# (lib.packagebuilder.sh state_dir), and document_uuid is the parent dialog guid
# when there is one, else the window uuid. Reproduced rather than guessed, so a
# change to the app's naming shows up here as a missing file rather than as a
# test that quietly asserts nothing.
#
# The uuid rule is factored out because the pasteboard keys use it too, and the
# two disagreeing is a silent failure: a wrong key reads back empty, and several
# checks here assert that a flag IS empty.
document_uuid() { printf '%s' "${OMC_PARENT_DIALOG_GUID:-$OMC_ACTIONUI_WINDOW_UUID}"; }

state_dir() {
    local tmp="${TMPDIR:-/tmp}"
    printf '%s/packagebuilder-state-%s' "${tmp%/}" "$(document_uuid)"
}

model_file() { printf '%s/model.json' "$(state_dir)"; }

# The real plister, reached through the interposition directory like the handlers
# reach it. Not the framework copy directly: if a test stubs plister, the
# assertions must see the stub too, or they would be reading a different tool
# from the one under test.
pl() { "$OMC_OMC_SUPPORT_PATH/plister" "$@"; }

# --- Reading the model --------------------------------------------------------

model() { pl get value "$(model_file)" "$1" 2>/dev/null; }
count() { pl get count "$(model_file)" "$1" 2>/dev/null; }
payload_field() { model "/COMPONENTS/0/PAYLOAD/$1/$2"; }
dirty() { /bin/cat "$(state_dir)/dirty.txt" 2>/dev/null; }
doc_path() { /bin/cat "$(state_dir)/doc_path.txt" 2>/dev/null; }

# Read a field out of a .pkgbuilderproj on disk, and out of the real file rather
# than a copy of it. plister used to pick the format from the extension alone, so
# this had to stage the document as .json first; it now falls back to the
# content for any extension it does not know (design 12.2).
field_of() { pl get value "$1" "$2" 2>/dev/null; }

hash_of() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

# Copy a fixture into the work area under a chosen name, WRITABLE. Fixtures are
# checked in read-only on purpose, and cp carries the mode across - so a plain
# copy of one is a file the tests cannot then edit or overwrite, which fails
# several handlers later with a permission error that looks like a defect.
work_copy() { # <fixture-name> <destination-name>
    local source_path
    source_path="$(fixture "$1")" || return 1
    /bin/cp "$source_path" "$OMCTEST_WORK/$2" || return 1
    /bin/chmod u+w "$OMCTEST_WORK/$2"
    printf '%s' "$OMCTEST_WORK/$2"
}

# The three artifact shapes design 5.3 names a rule for: a bundle carrying a
# version, a bare Mach-O executable, and a plain data file. Synthesized rather
# than committed - no binaries in the repository, and the block that builds them
# says out loud which properties the tests actually depend on. /bin/echo stands
# in for a signed tool: it is a real universal Mach-O, which is what the drop and
# the verify stage read.
#
# That last part is an environmental precondition, not a fact about this applet.
# The drop reads the file's slices and the checks expect TWO. Apple has shipped
# /bin/echo universal on every arm64 macOS so far; on a machine where it is thin
# the architecture assertions fail and read exactly like an app defect, so the
# precondition is asserted here rather than discovered 200 lines later.
make_artifacts() { # [directory, default $OMCTEST_WORK/artifacts]
    local dir="${1:-$OMCTEST_WORK/artifacts}"
    check "fixture precondition: /bin/echo is universal" "2" \
        "$(/usr/bin/lipo -archs /bin/echo 2>/dev/null | /usr/bin/wc -w | /usr/bin/tr -d ' ')"
    /bin/mkdir -p "$dir/Widget.app/Contents/MacOS"
    /bin/cat > "$dir/Widget.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.example.widget</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Widget</string>
    <key>CFBundleShortVersionString</key><string>3.4.1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
    /bin/cp /bin/echo "$dir/Widget.app/Contents/MacOS/Widget"
    /bin/cp /bin/echo "$dir/mytool"
    printf 'notes\n' > "$dir/readme.txt"
    printf '%s' "$dir"
}

# --- Per-window state the applet keeps in the pasteboard ----------------------

pb_key() { printf 'pb_%s_%s' "$1" "$(document_uuid)"; }
pb_get() { "$OMC_OMC_SUPPORT_PATH/pasteboard" "$(pb_key "$1")" get 2>/dev/null; }
pb_set() { printf '%s' "$2" | "$OMC_OMC_SUPPORT_PATH/pasteboard" "$(pb_key "$1")" set; }

selected_index() { pb_get selected_payload_index; }

# --- The run log and the build's outputs --------------------------------------

log_says() {
    if /usr/bin/grep -q -- "$1" "$(state_dir)/run.log" 2>/dev/null; then echo 1; else echo 0; fi
}
built_pkg() { /bin/cat "$(state_dir)/built_component.txt" 2>/dev/null; }
built_dist() { /bin/cat "$(state_dir)/built_distribution.txt" 2>/dev/null; }
built_signed() { /bin/cat "$(state_dir)/built_package.txt" 2>/dev/null; }
dist_xml() { /bin/cat "$(state_dir)/Distribution.xml" 2>/dev/null; }
xml_has() { if /usr/bin/grep -q -- "$1" "$(state_dir)/Distribution.xml" 2>/dev/null; then echo 1; else echo 0; fi; }

pkginfo_attr() { /usr/bin/grep -o "$2=\"[^\"]*\"" "$1/PackageInfo" | /usr/bin/head -n 1; }

expand_built() {
    /bin/rm -rf "$OMCTEST_WORK/expanded"
    /usr/sbin/pkgutil --expand "$(built_pkg)" "$OMCTEST_WORK/expanded" >/dev/null 2>&1
    printf '%s' "$OMCTEST_WORK/expanded"
}

# --- Calling the applet's libraries directly ----------------------------------
#
# A large part of this suite is unit-level: it calls validators and pipeline
# stages by name rather than dispatching a handler. That is not something omctest
# can offer, because only this applet knows its own function names - but it is
# also not something to give up, since those functions are where the rules live.
#
# Each runs in a subshell so a library's own state cannot leak into the test
# file, and so a function that exits does not take the suite with it.

pb_call() {
    ( . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.packagebuilder.sh" >/dev/null 2>&1
      . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.packagebuilder.window.sh" >/dev/null 2>&1
      "$@" )
}

pb_build_call() {
    ( . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.packagebuilder.sh" >/dev/null 2>&1
      . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.packagebuilder.window.sh" >/dev/null 2>&1
      . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.packagebuilder.build.sh" >/dev/null 2>&1
      "$@" )
}

# The same, for a call that has to name one of the library's own constants.
# pb_build_call cannot: the test file's shell expands its arguments before the
# subshell sources anything, so "$RAIL_COMPONENT_ID" arrives as the empty string
# and the call looks like it honors the named-view-id rule while passing nothing.
pb_build_eval() {
    ( . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.packagebuilder.sh" >/dev/null 2>&1
      . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.packagebuilder.window.sh" >/dev/null 2>&1
      . "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.packagebuilder.build.sh" >/dev/null 2>&1
      eval "$1" )
}

# A validator that answers yes or no. Named for what the caller wants to read.
vcheck() {
    if pb_build_call "$@" >/dev/null 2>&1; then echo yes; else echo no; fi
}

# --- Resetting between scenarios ----------------------------------------------

# Discard the whole document state. The next handler dispatch rebuilds it.
reset_state() { /bin/rm -rf "$(state_dir)"; }

# --- The agent CLI ------------------------------------------------------------

pbcli() { "$OMC_APP_BUNDLE_PATH/Contents/Resources/Agents/pkgbuilder" "$@"; }

# --- Convenience for the OMC surface this applet uses -------------------------

# Selecting a row means handing the handler the hidden index cell plus the
# trigger. The column number comes from the app like the view ids do.
select_payload_row() { # <hidden-index-value>
    omc_table_cell "$PAYLOAD_TABLE_ID" "$PAYLOAD_INDEX_COLUMN" "$1"
    omc_trigger "$PAYLOAD_TABLE_ID"
    omc_run PackageBuilder.payload.select
}

# View ids and column numbers, imported from the app rather than restated here.
#
# The applet already names every one of its views in lib.packagebuilder.sh, and a
# second list in the tests is a list that can disagree with the first. It did:
# the hand-written version had INSTALL_LOCATION_ID=134 and RELOCATABLE_ID=135,
# which are the AUTH picker and the overwrite-permissions toggle. Both tests
# passed - they assert on the model key the handler actually writes - so the
# names were quietly describing the wrong controls, which is the exact failure
# the no-bare-numbers rule exists to prevent.
#
# Only bare "NAME_ID=<digits>" and "NAME_COLUMN=<digits>" lines are taken, so
# nothing else in those libraries can arrive here through the eval.
omctest_import_view_ids() { # <script ...>
    local script
    for script; do
        # Two expressions rather than one alternation: "\|" is a GNU extension
        # and BSD sed matches it literally, which yields nothing and takes the
        # guard below down with it.
        eval "$(/usr/bin/sed -n \
            -e 's/^\([A-Z][A-Z0-9_]*_ID\)=\([0-9][0-9]*\)$/\1=\2/p' \
            -e 's/^\([A-Z][A-Z0-9_]*_COLUMN\)=\([0-9][0-9]*\)$/\1=\2/p' \
            "$script")"
    done
}
omctest_import_view_ids \
    "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.packagebuilder.sh" \
    "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.packagebuilder.build.sh"

# A missing name would make every "$SOME_ID" expand to the empty string, and
# omc_control would then write OMC_ACTIONUI_VIEW__VALUE - a variable no handler
# reads, so the checks would fail one by one with no hint why. Fail once, here,
# and name every id the suite drives rather than a sample of them: an id that
# went missing from the app is exactly the case this guard is for.
for omctest_required_id in PAYLOAD_TABLE_ID PAYLOAD_ADD_ID PAYLOAD_REMOVE_ID \
    PAYLOAD_UP_ID PAYLOAD_DOWN_ID PAYLOAD_INDEX_COLUMN ARTIFACTS_DIR_ID \
    SOURCE_ID DESTINATION_ID OWNER_ID GROUP_ID MODE_ID VERIFY_UNIVERSAL_ID \
    VERIFY_SIGNED_ID VERIFY_HARDENED_ID VERIFY_TIMESTAMP_ID VERSION_FLAG_ID \
    NAME_ID IDENTIFIER_ID VERSION_ID INSTALL_LOCATION_ID AUTH_ID OVERWRITE_ID \
    RELOCATABLE_ID TITLE_ID MIN_OS_ID ARCH_ARM64_ID ARCH_X86_64_ID README_ID \
    PRESET_APPLICATIONS_ID PRESET_APP_SUPPORT_ID; do
    eval "omctest_required_value=\$$omctest_required_id"
    [ -n "$omctest_required_value" ] || {
        printf 'lib.test.packagebuilder: %s did not import from the app\n' \
            "$omctest_required_id" >&2
        exit 1
    }
done
unset omctest_required_id omctest_required_value
