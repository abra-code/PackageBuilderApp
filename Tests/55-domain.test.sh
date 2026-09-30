#!/bin/sh
# Tests/55-domain.test.sh - packages that install for the user (DISTRIBUTION/DOMAIN).
#
# A per-user package installs into the home folder of whoever runs the
# installer, with no administrator password. The document writes its paths
# "~/...", and the build turns them into the home-relative form pkgbuild and
# Installer take. Every check here builds or refuses a package; none installs
# one. An install into the real home folder is a manual step, never a test.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.packagebuilder.sh"

# The replay project, moved to the user's home folder: the domain picker moves
# the install location and AUTH, and the four destinations are rewritten by
# hand, the way a user would after the status line told them to.
# Two artifacts for the destination guesses: a bundle and a bare executable.
# Made here rather than with make_artifacts, whose fixture precondition wants
# /bin/echo to carry exactly two slices - nothing these sections read.
make_guess_artifacts() { # <directory>
    /bin/mkdir -p "$1/Widget.app/Contents/MacOS"
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.widget</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleExecutable</key><string>Widget</string></dict></plist>' > "$1/Widget.app/Contents/Info.plist"
    /bin/cp /bin/echo "$1/Widget.app/Contents/MacOS/Widget"
    /bin/cp /bin/echo "$1/mytool"
    printf '%s' "$1"
}

setup_user_project() {
    setup_replay_project
    omc_fire PackageBuilder.field.changed $DOMAIN_ID "user"
    for tool_index in 0 1 2 3; do
        tool_name="$(/usr/bin/basename "$(payload_field "$tool_index" DESTINATION)")"
        pl set string "~/.local/bin/$tool_name" "$(model_file)" "/COMPONENTS/0/PAYLOAD/$tool_index/DESTINATION"
    done
}

section "180. a system document builds the Distribution it always built"
# The default writes nothing new. The XML from a document with no DOMAIN key at
# all - every document written before it existed - and from one that says
# "system" must be the same bytes, and neither may carry a <domains> element.
setup_replay_project
check "a new document says system" "system"                 "$(model /DISTRIBUTION/DOMAIN)"
check "the picker shows it"      "system"                     "$(ui_value $DOMAIN_ID)"
omc_run PackageBuilder.step.component
omc_run PackageBuilder.step.distribution
check "it built"                 "yes"                        "$([ -f "$(built_dist)" ] && echo yes || echo no)"
/bin/cp "$(state_dir)/Distribution.xml" "$OMCTEST_WORK/system-with-key.xml"
check "no domains element"       "0"                          "$(xml_has '<domains')"
check "auth as the component says" "1"                        "$(xml_has 'auth="Root"')"
pl remove "$(model_file)" /DISTRIBUTION/DOMAIN
omc_run PackageBuilder.step.distribution
check "the key was really gone"  ""                           "$(model /DISTRIBUTION/DOMAIN)"
check "and the XML is the same bytes" "yes"                   "$(/usr/bin/cmp -s "$OMCTEST_WORK/system-with-key.xml" "$(state_dir)/Distribution.xml" && echo yes || echo no)"
/usr/sbin/installer -dominfo -pkg "$(built_dist)" > "$OMCTEST_WORK/dominfo-system.txt" 2>&1
# No <domains> element: -dominfo prints nothing at all for such a package,
# which is Installer's way of saying the system volume.
check "Installer offers no home folder" "0"                         "$(/usr/bin/grep -c 'CurrentUserHomeDirectory' "$OMCTEST_WORK/dominfo-system.txt" | /usr/bin/tr -d ' ')"

section "181. choosing the user moves the component's defaults with it"
setup_replay_project
omc_fire PackageBuilder.field.changed $DOMAIN_ID "user"
check "the document says user"   "user"                       "$(model /DISTRIBUTION/DOMAIN)"
check "the install location moved" "~"                        "$(component_field INSTALL_LOCATION)"
check "and so did AUTH"          "User"                       "$(component_field AUTH)"
check "the window was told"      "~"                          "$(ui_value $INSTALL_LOCATION_ID)"
check "the destinations were not guessed at" "/usr/local/bin/replay" "$(payload_field 0 DESTINATION)"
check "the status line counts them" "1"                       "$(printf '%s' "$(ui_value $STATUS_ID)" | /usr/bin/grep -c '^4 destination(s) still name system paths')"
# And back. A location somebody chose is theirs, and is left for the
# preconditions to judge rather than moved.
pl set string "~/Library/Tools" "$(model_file)" /COMPONENTS/0/INSTALL_LOCATION
omc_fire PackageBuilder.field.changed $DOMAIN_ID "system"
check "back to system"           "system"                     "$(model /DISTRIBUTION/DOMAIN)"
check "a chosen location stays"  "~/Library/Tools"            "$(component_field INSTALL_LOCATION)"
check "AUTH went back"           "Root"                       "$(component_field AUTH)"
pl set string "~" "$(model_file)" /COMPONENTS/0/INSTALL_LOCATION
omc_fire PackageBuilder.field.changed $DOMAIN_ID "user"
omc_fire PackageBuilder.field.changed $DOMAIN_ID "system"
check "the home root goes back to /" "/"                      "$(component_field INSTALL_LOCATION)"
# Anything but the two tags is a picker being written to, not a gesture.
omc_fire PackageBuilder.field.changed $DOMAIN_ID "3"
check "a stray value writes nothing" "system"                 "$(model /DISTRIBUTION/DOMAIN)"

section "182. a per-user package installs into the home folder"
setup_user_project
omc_run PackageBuilder.step.component
check "the component built"      "yes"                        "$([ -f "$(built_pkg)" ] && echo yes || echo no)"
user_expanded="$(expand_built)"
check "installs at the home root" 'install-location="/"'      "$(pkginfo_attr "$user_expanded" install-location)"
check "the BOM is home-relative" "1"                          "$(/usr/bin/lsbom -p f "$user_expanded/Bom" | /usr/bin/grep -c '^\./\.local/bin/replay$')"
check "nothing under usr"        "0"                          "$(/usr/bin/lsbom -p f "$user_expanded/Bom" | /usr/bin/grep -c 'usr/local')"
check "no folder named ~ was staged" "no"                     "$([ -e "$(state_dir)/root/~" ] && echo yes || echo no)"
omc_run PackageBuilder.step.distribution
check "the distribution built"   "yes"                        "$([ -f "$(built_dist)" ] && echo yes || echo no)"
check "one domains element"      "1"                          "$(/usr/bin/grep -c '<domains ' "$(state_dir)/Distribution.xml" | /usr/bin/tr -d ' ')"
check "only the home folder"     "1"                          "$(xml_has '<domains enable_anywhere="false" enable_currentUserHome="true" enable_localSystem="false"/>')"
check "auth none on the pkg-ref" "1"                          "$(xml_has 'auth="none"')"
check "and nowhere Root"         "0"                          "$(xml_has 'auth="Root"')"
# Installer's own answer, which is the one that matters. -dominfo reads the
# package and installs nothing.
/usr/sbin/installer -dominfo -pkg "$(built_dist)" > "$OMCTEST_WORK/dominfo-user.txt" 2>&1
check "Installer offers only the home folder" "CurrentUserHomeDirectory" "$(/usr/bin/grep -v '^$' "$OMCTEST_WORK/dominfo-user.txt")"
# Inspect Built Package says it in words.
omc_run PackageBuilder.inspect
check "the inspector names it"   "1"                          "$(log_says 'installs for:          the user who runs it, in their home folder')"

section "183. the build refuses what does not fit the domain"
setup_user_project
pl set string "/usr/local/bin/replay" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/DESTINATION
omc_run PackageBuilder.step.component
check "a system path is refused" "1"                          "$(log_says 'Item 1: Destination "/usr/local/bin/replay" must start with ~/')"
check "and nothing was built"    ""                           "$(built_pkg)"
pl set string "~/.local/bin/replay" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/DESTINATION
pl set string "/" "$(model_file)" /COMPONENTS/0/INSTALL_LOCATION
omc_run PackageBuilder.step.component
check "so is a system location"  "1"                          "$(log_says 'Install location "/" must start with ~/')"
pl set string "~" "$(model_file)" /COMPONENTS/0/INSTALL_LOCATION
pl set string "Root" "$(model_file)" /COMPONENTS/0/AUTH
omc_run PackageBuilder.step.component
omc_run PackageBuilder.step.distribution
check "Root is refused with the reason" "1"                   "$(log_says 'cannot ask for an administrator password')"
pl set string "User" "$(model_file)" /COMPONENTS/0/AUTH
# A misspelled domain is not read as the default: that would quietly build a
# package asking for a password.
pl set string "User" "$(model_file)" /DISTRIBUTION/DOMAIN
omc_run PackageBuilder.step.distribution
check "a misspelled domain is refused" "1"                    "$(log_says 'must be system or user')"
pl set string "user" "$(model_file)" /DISTRIBUTION/DOMAIN
# And the mirror: a home path in a system package would stage a folder
# literally named "~".
setup_replay_project
pl set string "~/.local/bin/replay" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/DESTINATION
omc_run PackageBuilder.step.component
check "a home path in a system package" "1"                   "$(log_says 'which only a package that installs for the user can install into')"
check "nothing built from it"    ""                           "$(built_pkg)"
# Positive control for the four refusals: the same project, set right, builds.
setup_user_project
omc_run PackageBuilder.step.component
check "the corrected project builds" "yes"                    "$([ -f "$(built_pkg)" ] && echo yes || echo no)"

section "184. ~/ paths keep every traversal guard"
# The conversion strips one "~" and nothing else, so each guard the system
# paths have still sees the dots.
setup_user_project
/bin/mkdir -p "$OMCTEST_WORK/canary"
pl set string "~/../canary/replay" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/DESTINATION
omc_run PackageBuilder.step.component
check "~/.. is refused"          "1"                          "$(log_says 'destination "~/../canary/replay" must not contain ".."')"
check "nothing reached the canary" "0"                        "$(/bin/ls -A "$OMCTEST_WORK/canary" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
check "nothing was built"        ""                           "$(built_pkg)"
pl set string "~/.local/./bin//replay" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/DESTINATION
pl set string "~/.local/bin/replay" "$(model_file)" /COMPONENTS/0/PAYLOAD/1/DESTINATION
omc_run PackageBuilder.step.component
check "two spellings of one path collide" "1"                 "$(log_says 'Items 1 and 2 install to the same path: ~/.local/bin/replay')"
pl set string "~/.local/bin/replay" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/DESTINATION
pl set string "~/.local/bin/replay/inner" "$(model_file)" /COMPONENTS/0/PAYLOAD/1/DESTINATION
omc_run PackageBuilder.step.component
check "and nesting is named in ~/ form" "1"                   "$(log_says 'is under ~/.local/bin/replay')"
# Staging's own re-check, reached by calling it with the preconditions skipped.
setup_user_project
pl set string "~/../canary/staged" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/DESTINATION
pb_build_call stage_payload_root 0 >/dev/null 2>&1
check "staging refuses it too"   "1"                          "$(log_says 'must not contain ".."')"
check "and the canary is still empty" "0"                     "$(/bin/ls -A "$OMCTEST_WORK/canary" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
pl set string "/usr/local/bin/replay" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/DESTINATION
pb_build_call stage_payload_root 0 >/dev/null 2>&1
check "staging refuses a system path" "1"                     "$(log_says 'must start with ~/')"

section "185. an install location may carry tokens"
# What a versioned layout needs: ~/.local/share/tool/versions/<v> follows the
# version the way the destinations under it do.
setup_user_project
pl set string '~/.local/share/${NAME}/versions/${VERSION}' "$(model_file)" /COMPONENTS/0/INSTALL_LOCATION
for tool_index in 0 1 2 3; do
    tool_name="$(/usr/bin/basename "$(payload_field "$tool_index" DESTINATION)")"
    pl set string "~/.local/share/\${NAME}/versions/\${VERSION}/$tool_name" "$(model_file)" "/COMPONENTS/0/PAYLOAD/$tool_index/DESTINATION"
done
omc_run PackageBuilder.step.component
check "it built"                 "yes"                        "$([ -f "$(built_pkg)" ] && echo yes || echo no)"
token_expanded="$(expand_built)"
check "the location is expanded" 'install-location="/.local/share/replay/versions/2.2"' "$(pkginfo_attr "$token_expanded" install-location)"
check "and the BOM is relative to it" "1"                     "$(/usr/bin/lsbom -p f "$token_expanded/Bom" | /usr/bin/grep -c '^\./replay$')"
pl set string '~/.local/share/${NAME}/..' "$(model_file)" /COMPONENTS/0/INSTALL_LOCATION
omc_run PackageBuilder.step.component
check "a .. behind a token is refused" "1"                    "$(log_says 'Install location "~/.local/share/replay/.." must not contain ".."')"

section "186. new artifacts get home-folder destinations"
setup_user_project
guess_artifacts="$(make_guess_artifacts "$OMCTEST_WORK/guess")"
omc_drop "$guess_artifacts/Widget.app" "$guess_artifacts/mytool"
omc_run PackageBuilder.payload.drop
check "an app goes to ~/Applications" "~/Applications/Widget.app" "$(payload_field 4 DESTINATION)"
check "a tool goes to ~/.local/bin" "~/.local/bin/mytool"     "$(payload_field 5 DESTINATION)"
# The preset menu does the same, and refuses the one folder with no per-user
# counterpart rather than inventing one.
select_payload_row 4
omc_fire PackageBuilder.payload.destination.preset $PRESET_APP_SUPPORT_ID
check "a preset follows the domain" "~/Library/Application Support/replay/Widget.app" "$(payload_field 4 DESTINATION)"
omc_fire PackageBuilder.payload.destination.preset $PRESET_LAUNCHDAEMONS_ID
check "launch daemons are refused" "~/Library/Application Support/replay/Widget.app" "$(payload_field 4 DESTINATION)"
check "and the status line says why" "1"                      "$(printf '%s' "$(ui_value $STATUS_ID)" | /usr/bin/grep -c 'has no per-user counterpart')"
# A system document still gets the system folders.
setup_replay_project
omc_drop "$guess_artifacts/Widget.app"
omc_run PackageBuilder.payload.drop
check "a system app goes to /Applications" "/Applications/Widget.app" "$(payload_field 4 DESTINATION)"

section "187. the exported script builds the same per-user package"
setup_user_project
pl set bool false "$(model_file)" /SIGNING/ENABLED
user_script="$OMCTEST_WORK/makepkg.user.sh"
/bin/rm -f "$user_script"
omc_dialog_answer save_as "$user_script"
omc_run PackageBuilder.export.script
check "the script was written"   "yes"                        "$([ -f "$user_script" ] && echo yes || echo no)"
check "and sh accepts it"        "0"                          "$(/bin/sh -n "$user_script" 2>/dev/null; echo $?)"
check "it says who it installs for" "1"                       "$(/usr/bin/grep -c 'installs for the user who runs it' "$user_script" | /usr/bin/tr -d ' ')"
check "destinations are home-relative" "1"                    "$(/usr/bin/grep -c "^stage_entry .* '/.local/bin/replay' '0755' " "$user_script" | /usr/bin/tr -d ' ')"
/bin/rm -rf "$OMCTEST_WORK/user-out"
/bin/sh "$user_script" --unsigned --output-dir "$OMCTEST_WORK/user-out" > "$OMCTEST_WORK/user-run.log" 2>&1
check "the script succeeded"     "0"                          "$?"
user_script_pkg="$OMCTEST_WORK/user-out/replay_2.2-unsigned.pkg"
check "the package landed"       "yes"                        "$([ -f "$user_script_pkg" ] && echo yes || echo no)"
omc_run PackageBuilder.step.component
omc_run PackageBuilder.step.distribution
/bin/rm -rf "$OMCTEST_WORK/user-script-expand" "$OMCTEST_WORK/user-app-expand"
/usr/sbin/pkgutil --expand "$user_script_pkg" "$OMCTEST_WORK/user-script-expand" >/dev/null 2>&1
/usr/sbin/pkgutil --expand "$(built_dist)" "$OMCTEST_WORK/user-app-expand" >/dev/null 2>&1
check "XML identical to the app's" "yes"                      "$(/usr/bin/cmp -s "$OMCTEST_WORK/user-script-expand/Distribution" "$OMCTEST_WORK/user-app-expand/Distribution" && echo yes || echo no)"
check "the same BOM"             "yes"                        "$([ "$(/usr/bin/lsbom -p f "$OMCTEST_WORK/user-script-expand/replay.pkg/Bom")" = "$(/usr/bin/lsbom -p f "$OMCTEST_WORK/user-app-expand/replay.pkg/Bom")" ] && echo yes || echo no)"
# The exporter runs no preconditions, so a destination that does not fit is a
# refusal written into the script rather than a build of the wrong thing.
pl set string "/usr/local/bin/replay" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/DESTINATION
bad_script="$OMCTEST_WORK/makepkg.bad.sh"
/bin/rm -f "$bad_script"
omc_dialog_answer save_as "$bad_script"
omc_run PackageBuilder.export.script
/bin/rm -rf "$OMCTEST_WORK/bad-out"
/bin/sh "$bad_script" --unsigned --output-dir "$OMCTEST_WORK/bad-out" > "$OMCTEST_WORK/bad-run.log" 2>&1
check "the script refuses it"    "1"                          "$([ "$?" -ne 0 ] && echo 1 || echo 0)"
check "and says why"             "1"                          "$(/usr/bin/grep -c 'must start with ~/' "$OMCTEST_WORK/bad-run.log" | /usr/bin/tr -d ' ')"
check "no package from it"       "no"                         "$([ -f "$OMCTEST_WORK/bad-out/replay_2.2-unsigned.pkg" ] && echo yes || echo no)"
# A literal ".." in the install location would take pkgbuild out of the home
# folder; the app refuses it at build time, and the script it exports does too.
pl set string "~/.local/bin/replay" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/DESTINATION
pl set string "~/../outside" "$(model_file)" /COMPONENTS/0/INSTALL_LOCATION
dotdot_script="$OMCTEST_WORK/makepkg.dotdot.sh"
/bin/rm -f "$dotdot_script"
omc_dialog_answer save_as "$dotdot_script"
omc_run PackageBuilder.export.script
check "a literal .. location is refused in the script" "1"   "$(/usr/bin/grep -c -F "fail 'Install location \"~/../outside\" must not contain \"..\"'" "$dotdot_script" | /usr/bin/tr -d ' ')"
# The two distribution refusals follow it into the script: a Root component
# under "user" is not quietly given auth="none", and a misspelled domain is
# not exported as a system package.
pl set string "~" "$(model_file)" /COMPONENTS/0/INSTALL_LOCATION
pl set string "Root" "$(model_file)" /COMPONENTS/0/AUTH
root_script="$OMCTEST_WORK/makepkg.root.sh"
/bin/rm -f "$root_script"
omc_dialog_answer save_as "$root_script"
omc_run PackageBuilder.export.script
check "Root under user is refused in the script" "1"          "$(/usr/bin/grep -c "^fail 'Component 1: Authentication is Root" "$root_script" | /usr/bin/tr -d ' ')"
pl set string "User" "$(model_file)" /COMPONENTS/0/AUTH
pl set string "Users" "$(model_file)" /DISTRIBUTION/DOMAIN
misspelled_script="$OMCTEST_WORK/makepkg.misspelled.sh"
/bin/rm -f "$misspelled_script"
omc_dialog_answer save_as "$misspelled_script"
omc_run PackageBuilder.export.script
check "a misspelled domain is refused in the script" "1"      "$(/usr/bin/grep -c "^fail 'Installs for (DISTRIBUTION/DOMAIN) is \"Users\"" "$misspelled_script" | /usr/bin/tr -d ' ')"
check "and the good script has neither" "0"                   "$(/usr/bin/grep -c "^fail 'Installs for\|^fail 'Component 1: Authentication" "$user_script" | /usr/bin/tr -d ' ')"

section "188. a per-user package imports back into a per-user document"
setup_user_project
omc_run PackageBuilder.step.component
omc_run PackageBuilder.step.distribution
user_built="$OMCTEST_WORK/replay-user.pkg"
/bin/cp "$(built_dist)" "$user_built"
setup_replay_project
omc_dialog_answer choose_file "$user_built"
omc_run PackageBuilder.import.pkg
check "the domain came across"   "user"                       "$(model /DISTRIBUTION/DOMAIN)"
check "the location in ~ form"   "~"                          "$(component_field INSTALL_LOCATION)"
check "the destinations too"     "~/.local/bin/dispatch"      "$(payload_field 0 DESTINATION)"
check "and AUTH as User"         "User"                       "$(component_field AUTH)"
check "the picker followed"      "user"                       "$(ui_value $DOMAIN_ID)"
# And a system package imported over it puts the document back.
setup_replay_project
omc_run PackageBuilder.step.component
omc_run PackageBuilder.step.distribution
system_built="$OMCTEST_WORK/replay-system.pkg"
/bin/cp "$(built_dist)" "$system_built"
pl set string "user" "$(model_file)" /DISTRIBUTION/DOMAIN
omc_dialog_answer choose_file "$system_built"
omc_run PackageBuilder.import.pkg
check "back to system"           "system"                     "$(model /DISTRIBUTION/DOMAIN)"
check "with system destinations" "/usr/local/bin/dispatch"    "$(payload_field 0 DESTINATION)"
# A component package states no auth at all. Imported into a document that was
# "user", the User left over from it must not survive into a system document.
setup_user_project
omc_run PackageBuilder.step.component
component_only="$OMCTEST_WORK/replay-component.pkg"
/bin/cp "$(built_pkg)" "$component_only"
check "the document was user, AUTH User" "user User"          "$(model /DISTRIBUTION/DOMAIN) $(component_field AUTH)"
omc_dialog_answer choose_file "$component_only"
omc_run PackageBuilder.import.pkg
check "a component package imports as system" "system"        "$(model /DISTRIBUTION/DOMAIN)"
check "with the system default AUTH" "Root"                   "$(component_field AUTH)"

section "189. the CLI and the verifier know the key"
/bin/mkdir -p "$OMCTEST_WORK/cli/out"
cli_doc="$(pbcli new "$OMCTEST_WORK/cli/user.pkgbld" --name tool --identifier com.example.pkg.tool --version 1.0 --domain user --output-dir "$OMCTEST_WORK/cli/out" --no-signing 2>/dev/null)"
check "new --domain user"        "user"                       "$(field_of "$cli_doc" /DISTRIBUTION/DOMAIN)"
check "with the user defaults"   "~ User"                     "$(field_of "$cli_doc" /COMPONENTS/0/INSTALL_LOCATION) $(field_of "$cli_doc" /COMPONENTS/0/AUTH)"
cli_artifacts="$(make_guess_artifacts "$OMCTEST_WORK/cli-art")"
pbcli add-payload "$cli_doc" "$cli_artifacts/mytool" --no-verify >/dev/null 2>&1
check "add-payload guesses a home path" "~/.local/bin/mytool" "$(field_of "$cli_doc" /COMPONENTS/0/PAYLOAD/0/DESTINATION)"
pbcli validate "$cli_doc" >/dev/null 2>&1
check "validate is clean"        "0"                          "$?"
pbcli set "$cli_doc" /DISTRIBUTION/DOMAIN users >/dev/null 2>&1
check "set refuses a stray value" "1"                         "$?"
pbcli set "$cli_doc" /DISTRIBUTION/DOMAIN system >/dev/null 2>"$OMCTEST_WORK/cli/set.txt"
check "set moves the defaults"   "/ Root"                     "$(field_of "$cli_doc" /COMPONENTS/0/INSTALL_LOCATION) $(field_of "$cli_doc" /COMPONENTS/0/AUTH)"
check "and counts what no longer fits" "1"                    "$(/usr/bin/grep -c '1 destination(s) do not fit DOMAIN system' "$OMCTEST_WORK/cli/set.txt" | /usr/bin/tr -d ' ')"
pbcli validate "$cli_doc" >/dev/null 2>"$OMCTEST_WORK/cli/validate.txt"
check "validate names the home path" "1"                      "$(/usr/bin/grep -c 'DESTINATION "~/.local/bin/mytool" is in a home folder' "$OMCTEST_WORK/cli/validate.txt" | /usr/bin/tr -d ' ')"
check "and exits with errors"    "1"                          "$(pbcli validate "$cli_doc" >/dev/null 2>&1; echo $?)"
# The verifier reads the file as written, so a Root component under DOMAIN
# user is caught before anything normalizes it.
pl set string "user" "$cli_doc" /DISTRIBUTION/DOMAIN
pl set string "~" "$cli_doc" /COMPONENTS/0/INSTALL_LOCATION
pl set string "Root" "$cli_doc" /COMPONENTS/0/AUTH
pbcli validate "$cli_doc" >/dev/null 2>"$OMCTEST_WORK/cli/validate-root.txt"
check "validate refuses Root"    "1"                          "$(/usr/bin/grep -c 'AUTH is Root, but DISTRIBUTION/DOMAIN is user' "$OMCTEST_WORK/cli/validate-root.txt" | /usr/bin/tr -d ' ')"
pl set string "User" "$cli_doc" /COMPONENTS/0/AUTH
pbcli build "$cli_doc" --unsigned >/dev/null 2>&1
check "the CLI builds it"        "0"                          "$?"
pbcli inspect "$OMCTEST_WORK/cli/out/tool_1.0-unsigned.pkg" > "$OMCTEST_WORK/cli/inspect.txt" 2>&1
check "inspect says who it is for" "1"                        "$(/usr/bin/grep -c '^Installs for: user$' "$OMCTEST_WORK/cli/inspect.txt" | /usr/bin/tr -d ' ')"

section "190. a component added to a per-user document starts with its defaults"
setup_user_project
omc_run PackageBuilder.component.add
check "a second component"       "2"                          "$(component_total)"
check "at the home root"         "~"                          "$(component_field INSTALL_LOCATION 1)"
check "asking for no password"   "User"                       "$(component_field AUTH 1)"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids"        ""                           "$(ui_unknown_writes)"

omctest_end
