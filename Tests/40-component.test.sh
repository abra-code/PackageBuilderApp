#!/bin/sh
# Tests/40-component.test.sh - staging and the component package.
#
# Ported from Private/harness.sh sections 51 to 73. These drive the real
# pkgbuild and then take the result apart with pkgutil --expand, which is the
# only way to check the two corrections of design section 8: both live in
# PackageInfo rather than in anything the build prints.
#
# Sections 68 to 73 are the regressions from the 2026-08-06 review, kept with
# the block they belong to rather than moved in beside the other regressions.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.packagebuilder.sh"

artifacts="$(make_artifacts)"

section "51. a component package is built from the payload"
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/Build.pkgbuilderproj"
omc_run PackageBuilder.save.as
omc_dialog_answer choose_folder "$artifacts"
omc_run PackageBuilder.choose.artifacts
omc_drop "$artifacts/Widget.app" "$artifacts/mytool"
omc_run PackageBuilder.payload.drop
pl set string "com.example.pkg.widget" "$(model_file)" /COMPONENTS/0/IDENTIFIER
omc_run PackageBuilder.step.component
check "preconditions passed"     "1"                         "$(log_says 'all clear')"
check "a package was written"    "yes"                       "$([ -n "$(built_pkg)" ] && [ -f "$(built_pkg)" ] && echo yes || echo no)"
check "named after the project"  "Widget.pkg"                "$(/usr/bin/basename "$(built_pkg)")"
check "it stayed in the scratch" "$(state_dir)"              "$(/usr/bin/dirname "$(/usr/bin/dirname "$(built_pkg)")")"
check "no run.pid left behind"   "no"                        "$([ -f "$(state_dir)/run.pid" ] && echo yes || echo no)"
check "busy flag cleared"        ""                          "$(pb_get busy)"

section "52. the staged root mirrors the destinations, not the sources (7.2)"
check "bundle staged by dest"    "yes"                       "$([ -d "$(state_dir)/root/Applications/Widget.app" ] && echo yes || echo no)"
check "tool staged by dest"      "yes"                       "$([ -f "$(state_dir)/root/usr/local/bin/mytool" ] && echo yes || echo no)"
check "install location removed" "no"                        "$([ -e "$(state_dir)/root/Applications/Applications" ] && echo yes || echo no)"
check "mode applied"             "755"                       "$(/usr/bin/stat -f '%Lp' "$(state_dir)/root/usr/local/bin/mytool")"

section "53. overwrite-permissions is forced to what the document says (8.1)"
expanded="$(expand_built)"
# pkgbuild always writes "true"; the document says false, so the expand/patch/
# flatten round trip has to have happened. This is the check that stands between
# an install and a Homebrew tree re-owned to root:wheel.
check "PackageInfo says false"   'overwrite-permissions="false"' "$(pkginfo_attr "$expanded" overwrite-permissions)"
check "the patch was logged"     "1"                         "$(log_says 'overwrite-permissions set to false')"
# --expand rather than --expand-full, so the payload came through untouched.
check "Payload still opaque"     "yes"                       "$([ -f "$expanded/Payload" ] && echo yes || echo no)"
check "Bom still opaque"         "yes"                       "$([ -f "$expanded/Bom" ] && echo yes || echo no)"

section "54. bundles are not relocatable by default (8.2)"
# The pkg-info "relocatable" attribute is not the one that matters: the element
# that decides whether Installer hunts for an existing copy by bundle id is
# <relocate>, and turning relocation off empties it.
check "relocate list is empty"   "1"                         "$(/usr/bin/grep -c '<relocate/>' "$expanded/PackageInfo" | /usr/bin/tr -d ' ')"
check "the plist was applied"    "1"                         "$(log_says 'marked non-relocatable')"

section "55. the BOM records root:wheel without sudo (7.2)"
check "tool owned by 0 0"        "0 0"                       "$(/usr/bin/lsbom -p fug "$expanded/Bom" | /usr/bin/awk '$1 == "./usr/local/bin/mytool" {print $2, $3}')"
check "created dirs owned 0 0"   "0 0"                       "$(/usr/bin/lsbom -p fug "$expanded/Bom" | /usr/bin/awk '$1 == "./usr/local" {print $2, $3}')"
check "both items in the BOM"    "2"                         "$(/usr/bin/lsbom -p f "$expanded/Bom" | /usr/bin/grep -c -e './usr/local/bin/mytool' -e './Applications/Widget.app/Contents/MacOS/Widget')"

section "56. RELOCATABLE true leaves the bundle relocatable"
pl set bool true "$(model_file)" /COMPONENTS/0/RELOCATABLE
omc_run PackageBuilder.step.component
expanded="$(expand_built)"
check "relocate is populated"    "0"                         "$(/usr/bin/grep -c '<relocate/>' "$expanded/PackageInfo" | /usr/bin/tr -d ' ')"
check "bundle listed for reloc"  "1"                         "$(/usr/bin/sed -n '/<relocate>/,/<\/relocate>/p' "$expanded/PackageInfo" | /usr/bin/grep -c 'com.example.widget' | /usr/bin/tr -d ' ')"
check "the choice was logged"    "1"                         "$(log_says 'left relocatable')"
pl set bool false "$(model_file)" /COMPONENTS/0/RELOCATABLE

section "57. OVERWRITE_PERMISSIONS true is honored too"
# Not the mirror image of 53, though it reads like one. pkgbuild writes "true"
# by itself, so the app short-circuits and patches nothing - removing the whole
# patch reddens 53 and leaves this green. What it guards is narrower and still
# worth having: that the app does not force "false" unconditionally. The
# short-circuit is asserted too, so the section says which path it took.
pl set bool true "$(model_file)" /COMPONENTS/0/OVERWRITE_PERMISSIONS
omc_run PackageBuilder.step.component
expanded="$(expand_built)"
check "PackageInfo says true"    'overwrite-permissions="true"' "$(pkginfo_attr "$expanded" overwrite-permissions)"
check "and no patch was needed"  "1"                         "$(log_says 'already true')"
pl set bool false "$(model_file)" /COMPONENTS/0/OVERWRITE_PERMISSIONS

section "58. a postinstall script is staged into the package"
printf '#!/bin/sh\nexit 0\n' > "$OMCTEST_WORK/postinstall.sh"
pl set string "$OMCTEST_WORK/postinstall.sh" "$(model_file)" /COMPONENTS/0/POSTINSTALL
omc_run PackageBuilder.step.component
expanded="$(expand_built)"
check "script in the package"    "yes"                       "$([ -f "$expanded/Scripts/postinstall" ] && echo yes || echo no)"
check "and it is executable"     "yes"                       "$([ -x "$expanded/Scripts/postinstall" ] && echo yes || echo no)"
pl set string "" "$(model_file)" /COMPONENTS/0/POSTINSTALL

section "59. the staging root is rebuilt from scratch every time (8.5)"
# A file left over from a previous run must not survive into the next package.
/bin/mkdir -p "$(state_dir)/root/usr/local/bin"
printf 'stale\n' > "$(state_dir)/root/usr/local/bin/leftover"
omc_run PackageBuilder.step.component
check "leftover swept"           "no"                        "$([ -e "$(state_dir)/root/usr/local/bin/leftover" ] && echo yes || echo no)"
expanded="$(expand_built)"
check "and not in the BOM"       "0"                         "$(/usr/bin/lsbom -p f "$expanded/Bom" | /usr/bin/grep -c 'leftover')"

section "60. preconditions stop the build before anything is written"
pl set string '2&2' "$(model_file)" /PROJECT/VERSION
/bin/rm -f "$(state_dir)/built_component.txt"
omc_run PackageBuilder.step.component
check "version refused"          "1"                         "$(log_says 'is not accepted')"
check "no package recorded"      ""                          "$(built_pkg)"
check "busy flag cleared"        ""                          "$(pb_get busy)"
pl set string '3.4.1' "$(model_file)" /PROJECT/VERSION

section "61. every precondition is reported, not just the first"
pl set string 'notreversedns' "$(model_file)" /COMPONENTS/0/IDENTIFIER
pl set string 'a/b' "$(model_file)" /PROJECT/NAME
pl set string '9999' "$(model_file)" /COMPONENTS/0/PAYLOAD/0/MODE
omc_run PackageBuilder.step.component
check "name refused"             "1"                         "$(log_says 'is not usable in a filename')"
check "identifier refused"       "1"                         "$(log_says 'reverse-DNS')"
check "mode refused"             "1"                         "$(log_says 'octal digits')"
check "counted together"         "1"                         "$(log_says '3 problem(s)')"
pl set string 'com.example.pkg.widget' "$(model_file)" /COMPONENTS/0/IDENTIFIER
pl set string 'Widget' "$(model_file)" /PROJECT/NAME
pl set string '0755' "$(model_file)" /COMPONENTS/0/PAYLOAD/0/MODE

section "62. overlapping destinations are refused (4.1)"
pl set string '/Applications/Widget.app/Contents/MacOS/mytool' "$(model_file)" /COMPONENTS/0/PAYLOAD/1/DESTINATION
omc_run PackageBuilder.step.component
check "nesting caught"           "1"                         "$(log_says 'installs inside item')"
pl set string '/Applications/Widget.app' "$(model_file)" /COMPONENTS/0/PAYLOAD/1/DESTINATION
omc_run PackageBuilder.step.component
check "duplicate caught"         "1"                         "$(log_says 'install to the same path')"
pl set string '/usr/local/bin/mytool' "$(model_file)" /COMPONENTS/0/PAYLOAD/1/DESTINATION

section "63. a destination outside the install location is refused"
pl set string '/usr/local' "$(model_file)" /COMPONENTS/0/INSTALL_LOCATION
omc_run PackageBuilder.step.component
check "bundle is outside it"     "1"                         "$(log_says 'is not under the install location')"
pl set string '/' "$(model_file)" /COMPONENTS/0/INSTALL_LOCATION

section "64. a non-default install location stages relative to it"
pl set string '/usr/local' "$(model_file)" /COMPONENTS/0/INSTALL_LOCATION
pl set string '/usr/local/bin/widget' "$(model_file)" /COMPONENTS/0/PAYLOAD/0/DESTINATION
omc_run PackageBuilder.step.component
check "staged under bin/"        "yes"                       "$([ -e "$(state_dir)/root/bin/widget" ] && echo yes || echo no)"
check "no usr/local in the root" "no"                        "$([ -e "$(state_dir)/root/usr" ] && echo yes || echo no)"
expanded="$(expand_built)"
check "install-location recorded" 'install-location="/usr/local"' "$(pkginfo_attr "$expanded" install-location)"
pl set string '/' "$(model_file)" /COMPONENTS/0/INSTALL_LOCATION
pl set string '/Applications/Widget.app' "$(model_file)" /COMPONENTS/0/PAYLOAD/0/DESTINATION

section '65. ${ARTIFACTS_DIR} without an artifacts folder is a hard stop (4.3)'
pl set string '' "$(model_file)" /PROJECT/ARTIFACTS_DIR
omc_run PackageBuilder.step.component
check "token without a folder"   "1"                         "$(log_says 'no artifacts folder is set')"
pl set string 'artifacts' "$(model_file)" /PROJECT/ARTIFACTS_DIR

section "66. an owner the build cannot honor is said out loud (7.2)"
pl set string 'daemon' "$(model_file)" /COMPONENTS/0/PAYLOAD/1/OWNER
omc_run PackageBuilder.step.component
check "the note was logged"      "1"                         "$(log_says 'are not applied')"
pl set string 'root' "$(model_file)" /COMPONENTS/0/PAYLOAD/1/OWNER

section "67. value validation matches the design table (4.4)"
check "1.0-beta2 passes"         "yes"                       "$(vcheck valid_version '1.0-beta2')"
check "2.2.1+build7 passes"      "yes"                       "$(vcheck valid_version '2.2.1+build7')"
check "2&2 refused"              "no"                        "$(vcheck valid_version '2&2')"
check "2/2 refused"              "no"                        "$(vcheck valid_version '2/2')"
check "1 0 refused"              "no"                        "$(vcheck valid_version '1 0')"
check "v1 refused"               "no"                        "$(vcheck valid_version 'v1')"
check "empty version refused"    "no"                        "$(vcheck valid_version '')"
check "name with slash refused"  "no"                        "$(vcheck valid_name 'a/b')"
check "name with quote refused"  "no"                        "$(vcheck valid_name "a'b")"
check "plain name passes"        "yes"                       "$(vcheck valid_name 'replay_2.2-1')"
check "0755 passes"              "yes"                       "$(vcheck valid_mode '0755')"
check "755 passes"               "yes"                       "$(vcheck valid_mode '755')"
check "0999 refused"             "no"                        "$(vcheck valid_mode '0999')"
check "rwx refused"              "no"                        "$(vcheck valid_mode 'rwx')"

# --- Regressions from the 2026-08-06 review -----------------------------------

section "68. reordering preserves an architecture list the checkbox cannot express"
# The universal checkbox can only say "both" or "none". Swapping through it read
# a hand-written ["arm64"] as "not both" and wrote back an empty array, so one
# click on an arrow deleted the entry's only architecture check for good.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/Swap.pkgbuilderproj"
omc_run PackageBuilder.save.as
omc_dialog_answer choose_folder "$artifacts"
omc_run PackageBuilder.choose.artifacts
omc_drop "$artifacts/mytool" "$artifacts/Widget.app"
omc_run PackageBuilder.payload.drop
pl remove "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/ARCHITECTURES
pl set array "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/ARCHITECTURES
pl append string arm64 "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/ARCHITECTURES
check "single arch to start"     "arm64"                     "$(model /COMPONENTS/0/PAYLOAD/0/VERIFY/ARCHITECTURES/0)"
select_payload_row 0
omc_fire PackageBuilder.payload.move $PAYLOAD_DOWN_ID
check "list survived the move"   "1"                         "$(count /COMPONENTS/0/PAYLOAD/1/VERIFY/ARCHITECTURES)"
check "and it is still arm64"    "arm64"                     "$(model /COMPONENTS/0/PAYLOAD/1/VERIFY/ARCHITECTURES/0)"
check "the other one came back"  "2"                         "$(count /COMPONENTS/0/PAYLOAD/0/VERIFY/ARCHITECTURES)"

section "69. a framework is a bundle (design 5.3)"
# A framework keeps its Info.plist under Versions/<v>/Resources, with no
# Contents directory, so a Contents-only test reported it was not a bundle -
# costing it mode 0755, all four verify toggles and its version read, while the
# destination guess still worked from the extension and made it look deliberate.
framework="$artifacts/Widget.framework"
/bin/mkdir -p "$framework/Versions/A/Resources"
/bin/cat > "$framework/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.example.widgetkit</string>
    <key>CFBundleExecutable</key><string>Widget</string>
    <key>CFBundleShortVersionString</key><string>5.6.7</string>
    <key>LSMinimumSystemVersion</key><string>12.3</string>
</dict>
</plist>
PLIST
/bin/cp /bin/echo "$framework/Versions/A/Widget"
/bin/ln -s A "$framework/Versions/Current"
/bin/ln -s Versions/Current/Widget "$framework/Widget"
/bin/ln -s Versions/Current/Resources "$framework/Resources"

reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/Fw.pkgbuilderproj"
omc_run PackageBuilder.save.as
omc_dialog_answer choose_folder "$artifacts"
omc_run PackageBuilder.choose.artifacts
omc_drop "$framework"
omc_run PackageBuilder.payload.drop
check "destination guessed"      "/Library/Frameworks/Widget.framework" "$(payload_field 0 DESTINATION)"
check "mode is 0755, not 0644"   "0755"                      "$(payload_field 0 MODE)"
check "verify toggles are on"    "2"                         "$(count /COMPONENTS/0/PAYLOAD/0/VERIFY/ARCHITECTURES)"
check "hardened runtime on"      "true"                      "$(payload_field 0 VERIFY/HARDENED_RUNTIME)"
check "version from the bundle"  "5.6.7"                     "$(model /PROJECT/VERSION)"
check "min OS from the bundle"   "12.3"                      "$(model /PROJECT/MIN_OS_VERSION)"

section "70. a lock left by a dead handler does not wedge the window"
# The stale-lock branch used a fractional -mmin, which BSD find rejects
# outright, so it never ran: any handler killed while holding the lock made
# every later edit in that window fail with "Busy" until it was closed.
reset_state
wedged="$(work_copy Sample.pkgbuilderproj Wedged.pkgbuilderproj)"
omc_object "$wedged"
omc_run PackageBuilder.main.init
dead_pid="$(/bin/sh -c 'echo $$')"
/bin/mkdir -p "$(state_dir)/model.lock"
printf '%s' "$dead_pid" > "$(state_dir)/model.lock/holder.pid"
omc_fire PackageBuilder.field.changed $TITLE_ID "edit past a dead lock"
check "the edit landed"          "edit past a dead lock"     "$(model /DISTRIBUTION/TITLE)"
check_absent "lock released again" "$(state_dir)/model.lock"
# A lock held by a process that is still alive must NOT be broken.
/bin/mkdir -p "$(state_dir)/model.lock"
printf '%s' "$$" > "$(state_dir)/model.lock/holder.pid"
omc_fire PackageBuilder.field.changed $TITLE_ID "must not land"
check "live holder respected"    "edit past a dead lock"     "$(model /DISTRIBUTION/TITLE)"
/bin/rm -rf "$(state_dir)/model.lock"

section '71. an unset ${ARTIFACTS_DIR} never resolves onto a real system path'
# ${ARTIFACTS_DIR}/bin/echo would otherwise collapse to /bin/echo, which exists:
# the read buttons would report the version of the *installed* copy, which is
# exactly the stale-artifact mistake the verify stage exists to catch.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/NoArtifacts.pkgbuilderproj"
omc_run PackageBuilder.save.as
# The collapsed path has to be a bundle that CARRIES a version and a minimum
# OS. The proof of concept used ${ARTIFACTS_DIR}/bin/echo, which collapses to
# /bin/echo - and /bin/echo reports no version at all, so "the read button did
# not invent one" was true whether the guard held or not. A reviewer proved it:
# deleting the guard reddened only "resolve refuses it". Calculator.app is a
# real bundle with both fields, so a collapsed read now produces a value the
# checks below can see.
collapsed_bundle="/System/Applications/Calculator.app"
pl insert 0 dict "$(model_file)" /COMPONENTS/0/PAYLOAD
pl set string "\${ARTIFACTS_DIR}$collapsed_bundle" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/SOURCE
pl set string '/usr/local/bin/echo' "$(model_file)" /COMPONENTS/0/PAYLOAD/0/DESTINATION
check "the collapsed path exists" "yes"                      "$([ -e "$collapsed_bundle" ] && echo yes || echo no)"
# And it really does carry the fields, or the two checks below would be back to
# passing for the wrong reason with no sign of it.
check "and it carries a version" "yes"                       "$([ -n "$(/usr/bin/defaults read "$collapsed_bundle/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)" ] && echo yes || echo no)"
check "and a minimum OS"         "yes"                       "$([ -n "$(/usr/bin/defaults read "$collapsed_bundle/Contents/Info.plist" LSMinimumSystemVersion 2>/dev/null)" ] && echo yes || echo no)"
check "resolve refuses it"       ""                          "$(pb_call resolve_stored_path "\${ARTIFACTS_DIR}$collapsed_bundle")"
pb_set selected_payload_index 2
pb_set selected_payload_index 0
omc_run PackageBuilder.read.version
check "version not invented"     ""                          "$(model /PROJECT/VERSION)"
omc_run PackageBuilder.read.minos
check "min OS not invented"      ""                          "$(model /PROJECT/MIN_OS_VERSION)"
# And the build refuses it by name rather than by accident.
pl set string "com.example.pkg.x" "$(model_file)" /COMPONENTS/0/IDENTIFIER
pl set string "x" "$(model_file)" /PROJECT/NAME
pl set string "1.0" "$(model_file)" /PROJECT/VERSION
omc_run PackageBuilder.step.component
check "build names the reason"   "1"                         "$(log_says 'no artifacts folder is set')"

section "72. url_to_path handles both file:// forms"
check "empty authority"          "/Users/x/My File.app"      "$(pb_call url_to_path 'file:///Users/x/My%20File.app')"
check "localhost authority"      "/Users/x/My File.app"      "$(pb_call url_to_path 'file://localhost/Users/x/My%20File.app')"
check "percent sign survives"    "/tmp/100%"                 "$(pb_call url_to_path 'file:///tmp/100%25')"

section "73. a tab in a path cannot shift the hidden index column"
# Rows are tab-joined with the entry index as a hidden column. A tab in a
# filename (legal on APFS) added a field, so the index column returned MODE -
# numeric, out of range, selection cleared - and the row could never be
# selected, removed or repaired through the UI again.
check "tab becomes a space"      "a b"                       "$(pb_call table_cell "$(printf 'a\tb')")"
check "newline becomes a space"  "a b"                       "$(pb_call table_cell "$(printf 'a\nb')")"
check "ordinary text untouched"  '${ARTIFACTS_DIR}/x'        "$(pb_call table_cell '${ARTIFACTS_DIR}/x')"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids"        ""                          "$(ui_unknown_writes)"

omctest_end
