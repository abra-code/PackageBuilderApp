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

# Character for character what the app builds, INCLUDING the doubled slash it
# gets from a TMPDIR that ends in one - which on macOS it always does. Stripping
# that here reads like tidying and is not: the app stores this path in
# built_component.txt and prints it in the run log, so a test that compares
# against a tidied copy fails on a string while every path-based check passes.
# Found exactly that way, porting section 51. The doubling is the app's, and if
# it is ever worth removing it should be removed there and fail here.
state_dir() {
    printf '%s/packagebuilder-state-%s' "${TMPDIR:-/tmp}" "$(document_uuid)"
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
# How many payload sources contain a substring. Written as a count so a check
# can assert zero: the folder-scan tests are mostly about what did NOT get
# added, and "no entry mentions Contents/MacOS" is the readable way to say it.
payload_sources_matching() { # <substring>
    local wanted="$1" total="$(count /COMPONENTS/0/PAYLOAD)" index=0 hits=0
    [ -n "$total" ] || total=0
    while [ "$index" -lt "$total" ]; do
        case "$(payload_field "$index" SOURCE)" in
            *"$wanted"*) hits=$((hits + 1)) ;;
        esac
        index=$((index + 1))
    done
    printf '%s' "$hits"
}
dirty() { /bin/cat "$(state_dir)/dirty.txt" 2>/dev/null; }
doc_path() { /bin/cat "$(state_dir)/doc_path.txt" 2>/dev/null; }

# Read a field out of a .pkgbld on disk, and out of the real file rather than a
# copy of it. plister used to pick the format from the extension alone, so this
# had to stage the document as .json first; it now falls back to the content for
# any extension it does not know (design 12.2).
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

# A build-folder-shaped tree for the folder scan: two artifacts worth finding
# and one of every kind the walk is supposed to leave behind.
#
# Names are all lower case at the character that decides each comparison, so the
# glob's order - and with it the order the payload comes out in - is the same
# under any collation the suite might run in.
#
# Expected result, in this order: alpha.app, gamma.framework, then
# nested/deep/betatool.
#   alpha.app             a bundle: ONE artifact, and the walk must not descend
#                         into it and offer Contents/MacOS/alpha as a second
#   gamma.framework       a VERSIONED bundle - Info.plist under
#                         Versions/A/Resources and no Contents directory at all,
#                         the layout bundle_info_plist exists to handle
#   nested/deep/betatool  a loose Mach-O, found at depth
#   notes.txt             not Mach-O
#   objs/part.o           a 64-bit Mach-O *object*: build folders are full of
#                         them
#   objs/part32.o         a 32-bit one, which says "Mach-O object i386" with no
#                         "-bit" token at all and slipped through the first
#                         version of is_macho_image
#   symlink               a link to alpha.app: the same artifact twice
#   syms.dSYM             a real bundle by the Info.plist test, and debug
#                         symbols nobody means to install
#   .hidden/ghost         a Mach-O the glob never offers
make_scan_tree() { # [directory, default $OMCTEST_WORK/scan]
    local dir="${1:-$OMCTEST_WORK/scan}"
    /bin/mkdir -p "$dir/alpha.app/Contents/MacOS"
    /bin/cat > "$dir/alpha.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.example.alpha</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>alpha</string>
    <key>CFBundleShortVersionString</key><string>1.2.3</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict>
</plist>
PLIST
    /bin/cp /bin/echo "$dir/alpha.app/Contents/MacOS/alpha"
    /bin/mkdir -p "$dir/gamma.framework/Versions/A/Resources"
    /bin/cat > "$dir/gamma.framework/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.example.gamma</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleExecutable</key><string>gamma</string>
    <key>CFBundleShortVersionString</key><string>4.5</string>
</dict>
</plist>
PLIST
    /bin/cp /bin/echo "$dir/gamma.framework/Versions/A/gamma"
    /bin/ln -sfh A "$dir/gamma.framework/Versions/Current"
    /bin/ln -sfh Versions/Current/gamma "$dir/gamma.framework/gamma"
    /bin/mkdir -p "$dir/nested/deep"
    /bin/cp /bin/echo "$dir/nested/deep/betatool"
    printf 'notes\n' > "$dir/notes.txt"
    /bin/mkdir -p "$dir/objs"
    make_object_file "$dir/objs/part.o"
    make_object_file_32 "$dir/objs/part32.o"
    /bin/ln -sfh "$dir/alpha.app" "$dir/symlink"
    /bin/mkdir -p "$dir/syms.dSYM/Contents"
    /bin/cat > "$dir/syms.dSYM/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.apple.xcode.dsym.com.example.alpha</string>
    <key>CFBundlePackageType</key><string>dSYM</string>
</dict>
</plist>
PLIST
    /bin/mkdir -p "$dir/.hidden"
    /bin/cp /bin/echo "$dir/.hidden/ghost"
    printf '%s' "$dir"
}

# Write a relocatable Mach-O object file, the thing a folder scan must not
# mistake for an artifact. Compiled rather than committed, for the reason
# make_artifacts gives: no binaries in the repo. The compiler is a fixture
# precondition like /bin/echo's two architectures, so a machine without one
# fails here by name instead of silently weakening the check that uses it.
make_object_file() { # <path>
    local path="$1"
    local source_file="${path%.o}.c"
    printf 'int pb_scan_fixture(void) { return 0; }\n' > "$source_file"
    /usr/bin/xcrun cc -c "$source_file" -o "$path" 2>/dev/null
    /bin/rm -f "$source_file"
    check_exists "fixture precondition: an object file was compiled" "$path"
}

# Write a THIRTY-TWO bit Mach-O object file. Handwritten rather than compiled,
# because a current Xcode will not emit i386 at all - and it is exactly the file
# that has to exist for this fixture to be worth anything: "file" prints the
# "64-bit" token only for MH_MAGIC_64, so a 32-bit object is described as
# "Mach-O object i386" and the first version of is_macho_image, which looked for
# "-bit object", classified it as an artifact.
#
# The header is the first seven words of mach_header, little endian: MH_MAGIC
# 0xfeedface, CPU_TYPE_I386 7, subtype 3, MH_OBJECT 1, then ncmds, sizeofcmds
# and flags all zero. "file" needs nothing past that.
make_object_file_32() { # <path>
    local path="$1"
    printf '\316\372\355\376\007\000\000\000\003\000\000\000\001\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' > "$path"
    check "fixture precondition: a 32-bit object" "Mach-O object i386" \
        "$(/usr/bin/file -b "$path" 2>/dev/null | /usr/bin/head -n 1)"
}

# A replay-shaped project: four bare tools into /usr/local/bin, a readme, a
# pinned version and minimum OS. This is the shape the acceptance test compares
# against the shipped replay_2.2.pkg, and the starting point for every build,
# signing and verify scenario.
setup_replay_project() {
    local artifacts_dir="$OMCTEST_WORK/replay-artifacts" tool
    reset_state
    /bin/mkdir -p "$artifacts_dir"
    for tool in replay gate dispatch fingerprint; do
        /bin/cp /bin/echo "$artifacts_dir/$tool"
    done
    printf '{\\rtf1\\ansi readme}\n' > "$OMCTEST_WORK/replay-readme.rtf"
    omc_object ""
    omc_run PackageBuilder.main.init
    omc_dialog_answer save_as "$OMCTEST_WORK/replay.pkgbld"
    omc_run PackageBuilder.save.as
    omc_dialog_answer choose_folder "$artifacts_dir"
    omc_run PackageBuilder.choose.artifacts
    omc_drop "$artifacts_dir/replay" "$artifacts_dir/gate" \
             "$artifacts_dir/dispatch" "$artifacts_dir/fingerprint"
    omc_run PackageBuilder.payload.drop
    pl set string "com.abracode.pkg.replay" "$(model_file)" /COMPONENTS/0/IDENTIFIER
    pl set string "replay" "$(model_file)" /PROJECT/NAME
    pl set string "2.2"    "$(model_file)" /PROJECT/VERSION
    pl set string "10.15"  "$(model_file)" /PROJECT/MIN_OS_VERSION
    pl set string "replay" "$(model_file)" /DISTRIBUTION/TITLE
    omc_dialog_answer choose_file "$OMCTEST_WORK/replay-readme.rtf"
    omc_run PackageBuilder.choose.readme
    clear_payload_assertions
}

# Drop every verify assertion the payload entries picked up on the way in.
#
# The four replay fixtures are copies of /bin/echo standing in for the real
# signed tools, and a dropped Mach-O starts out asserting universal, Developer
# ID signed, hardened and timestamped (design 5.3). /bin/echo is none of those:
# x86_64 + arm64e, "macOS Software Signing", no secure timestamp, no hardened
# runtime. Left in place they would stop every build below at stage 1, so the
# assertions are cleared here and the verify stage gets its own file, where what
# /bin/echo really is turns out to be the exact shape of the two mistakes design
# section 7 wants named.
clear_payload_assertions() {
    local entry_index=0 entry_total
    entry_total="$(count /COMPONENTS/0/PAYLOAD)"
    while [ "$entry_index" -lt "${entry_total:-0}" ]; do
        pb_call payload_archs_set "$entry_index" ""
        pl set string "" "$(model_file)" "/COMPONENTS/0/PAYLOAD/$entry_index/VERIFY/SIGNED_BY"
        pl set bool false "$(model_file)" "/COMPONENTS/0/PAYLOAD/$entry_index/VERIFY/HARDENED_RUNTIME"
        pl set bool false "$(model_file)" "/COMPONENTS/0/PAYLOAD/$entry_index/VERIFY/SECURE_TIMESTAMP"
        pl set string "" "$(model_file)" "/COMPONENTS/0/PAYLOAD/$entry_index/VERIFY/VERSION_FLAG"
        entry_index=$((entry_index + 1))
    done
}

# Say out loud that a group of checks did not run, and why.
#
# A few scenarios need something this machine may not have - a Developer ID
# Installer certificate, a copy of the shipped reference package. Failing there
# would make the suite unusable on an ordinary checkout; skipping silently is
# worse, because a skipped test and a passing one look identical in the output.
# So it is announced, in a word that greps.
skip_section() { # <reason>
    printf 'SKIP %s\n' "$1" >&2
}

# The Developer ID Installer identity to sign with, empty when there is none.
signing_identity() {
    /usr/bin/security find-identity -v -p basic 2>/dev/null \
        | /usr/bin/grep 'Developer ID Installer' \
        | /usr/bin/sed 's/.*"\(.*\)".*/\1/' | /usr/bin/head -n 1
}

# --- The applet's own preferences file ----------------------------------------
# omctest isolates $HOME per test FILE, so everything below reads and writes a
# throwaway profile and cannot touch the preferences of whoever runs the suite.
# That isolation is the harness's guarantee, not this file's, and it is why
# these can be asserted at all. Note that omctest pre-creates ~/Library and
# ~/Library/Application Support but deliberately NOT the applet's own directory,
# which is what makes "opening a window created no settings file" a real check.
prefs_path() { printf '%s/Library/Application Support/PackageBuilder/prefs.plist' "$HOME"; }

# A directory as the app will have spelled it. OMCTEST_WORK is built from
# TMPDIR, which on macOS is /var/folders/... and ends in a slash; every path the
# app records has been through canonical_path first, which resolves /var to
# /private/var and collapses the doubled slash. Comparing a raw OMCTEST_WORK
# path against a stored one therefore fails on the spelling while every
# behavior it was meant to check is correct - the same trap state_dir carries a
# note about above.
real_path() { # <existing directory>
    ( cd -P "$1" 2>/dev/null && /bin/pwd -P )
}
pref() { pl get value "$(prefs_path)" "/$1" 2>/dev/null; }

# The Developer ID Installer identity to seed a preference with, empty when this
# machine has none. Distinct from signing_identity only in intent: this one is
# never used to sign anything, it is a string that has to be in the keychain for
# apply_new_document_defaults to accept it.
# NOTE: this is empty under the suite even on a machine that has such a
# certificate. The keychain search list lives in ~/Library/Preferences, and
# omctest isolates $HOME - so "security find-identity" inside a test sees an
# empty profile and reports no identities. Verified directly: the same command
# with HOME pointed at an empty directory finds 0 valid identities on a machine
# where it otherwise finds two. Anything needing a real identity has to skip,
# and the skip should say this rather than blame the machine.
keychain_identity() { signing_identity; }

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
    PAYLOAD_UP_ID PAYLOAD_DOWN_ID PAYLOAD_SCAN_ID PAYLOAD_INDEX_COLUMN \
    ARTIFACTS_DIR_ID \
    SOURCE_ID DESTINATION_ID OWNER_ID GROUP_ID MODE_ID VERIFY_UNIVERSAL_ID \
    VERIFY_SIGNED_ID VERIFY_HARDENED_ID VERIFY_TIMESTAMP_ID VERSION_FLAG_ID \
    NAME_ID IDENTIFIER_ID VERSION_ID INSTALL_LOCATION_ID AUTH_ID OVERWRITE_ID \
    RELOCATABLE_ID TITLE_ID MIN_OS_ID ARCH_ARM64_ID ARCH_X86_64_ID README_ID \
    IDENTITY_PICKER_ID PRESET_APPLICATIONS_ID PRESET_APP_SUPPORT_ID; do
    eval "omctest_required_value=\$$omctest_required_id"
    [ -n "$omctest_required_value" ] || {
        printf 'lib.test.packagebuilder: %s did not import from the app\n' \
            "$omctest_required_id" >&2
        exit 1
    }
done
unset omctest_required_id omctest_required_value
