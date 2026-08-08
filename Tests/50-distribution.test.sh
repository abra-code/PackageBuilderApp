#!/bin/sh
# Tests/50-distribution.test.sh - the distribution package, signing, acceptance.
#
# Ported from Private/harness.sh sections 74 to 96. Sections 90 to 96 are the
# regressions from the phase 3 review, kept with the block they belong to.
#
# Two groups need something this machine may not have - the shipped reference
# package, and a Developer ID Installer certificate. Both announce a skip rather
# than failing, and both say which sections went unrun.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.packagebuilder.sh"

section "74. Build Distribution Only needs a component package first"
setup_replay_project
omc_run PackageBuilder.step.distribution
check "refused without one"      ""                          "$(built_dist)"
check "no log was written"       "1"                         "$([ -f "$(state_dir)/run.log" ] && echo 0 || echo 1)"

section "75. the distribution package wraps the component"
omc_run PackageBuilder.step.component
omc_run PackageBuilder.step.distribution
check "a package was written"    "yes"                       "$([ -n "$(built_dist)" ] && [ -f "$(built_dist)" ] && echo yes || echo no)"
check "named -unsigned"          "replay-unsigned.pkg"       "$(/usr/bin/basename "$(built_dist)")"
# Design 8.3: an unsigned artifact never reaches the output folder, so it can
# never sit one word away in the filename from the one that gets uploaded.
check "kept in the scratch dir"  "$(state_dir)"              "$(/usr/bin/dirname "$(built_dist)")"
check "busy flag cleared"        ""                          "$(pb_get busy)"

section "76. the Distribution XML says what the document says"
check "spec version 2"           "1"                         "$(xml_has 'minSpecVersion="2"')"
check "host architectures"       "1"                         "$(xml_has 'hostArchitectures="arm64,x86_64"')"
check "customize"                "1"                         "$(xml_has 'customize="never"')"
check "require-scripts"          "1"                         "$(xml_has 'require-scripts="false"')"
check "allowed-os-versions"      "1"                         "$(xml_has '<os-version min="10.15"/>')"
check "title"                    "1"                         "$(xml_has '<title>replay</title>')"
check "readme by basename"       "1"                         "$(xml_has '<readme file="replay-readme.rtf"/>')"
# auth lives on the pkg-ref and nowhere else: pkgbuild has no flag for it and
# always writes auth="root" into PackageInfo regardless (design section 4).
check "auth on the pkg-ref"      "1"                         "$(xml_has 'auth="Root"')"
check "component referenced"     "1"                         "$(xml_has '#replay.pkg')"
check "one choice, one line"     "1 1"                       "$(/usr/bin/grep -c '<line choice=' "$(state_dir)/Distribution.xml" | /usr/bin/tr -d ' ') $(/usr/bin/grep -c '<choice id=' "$(state_dir)/Distribution.xml" | /usr/bin/tr -d ' ')"

section "77. presentation resources are staged flat under their basename"
check "readme staged"            "yes"                       "$([ -f "$(state_dir)/resources/replay-readme.rtf" ] && echo yes || echo no)"
/bin/rm -rf "$OMCTEST_WORK/dist-expanded"
/usr/sbin/pkgutil --expand "$(built_dist)" "$OMCTEST_WORK/dist-expanded" >/dev/null 2>&1
check "readme in the package"    "yes"                       "$([ -f "$OMCTEST_WORK/dist-expanded/Resources/replay-readme.rtf" ] && echo yes || echo no)"
check "component inside it"      "yes"                       "$([ -d "$OMCTEST_WORK/dist-expanded/replay.pkg" ] && echo yes || echo no)"

section "78. XML-special characters in a title cannot break the document"
# The Distribution XML's version of design 4.4's sed hazard: a title of
# "Rock & Roll" written raw produces a document productbuild rejects outright.
check "ampersand escaped"        "Rock &amp; Roll"           "$(pb_build_call xml_escape 'Rock & Roll')"
check "angle brackets escaped"   "&lt;b&gt;"                 "$(pb_build_call xml_escape '<b>')"
check "quote escaped"            "say &quot;hi&quot;"        "$(pb_build_call xml_escape 'say "hi"')"
check "ampersand done first"     "&amp;lt;"                  "$(pb_build_call xml_escape '&lt;')"
# End to end: productbuild has to accept the document the escaping produced.
pl set string 'Rock & Roll <2>' "$(model_file)" /DISTRIBUTION/TITLE
omc_run PackageBuilder.step.distribution
check "productbuild accepted it" "yes"                       "$([ -n "$(built_dist)" ] && [ -f "$(built_dist)" ] && echo yes || echo no)"
pl set string 'replay' "$(model_file)" /DISTRIBUTION/TITLE

section "79. distribution preconditions"
pl remove "$(model_file)" /DISTRIBUTION/HOST_ARCHITECTURES
pl set array "$(model_file)" /DISTRIBUTION/HOST_ARCHITECTURES
omc_run PackageBuilder.step.distribution
check "no architecture refused"  "1"                         "$(log_says 'No host architecture is selected')"
pl append string arm64 "$(model_file)" /DISTRIBUTION/HOST_ARCHITECTURES
pl append string x86_64 "$(model_file)" /DISTRIBUTION/HOST_ARCHITECTURES
pl set string "gone.rtf" "$(model_file)" /DISTRIBUTION/RESOURCES/LICENSE
omc_run PackageBuilder.step.distribution
check "missing resource refused" "1"                         "$(log_says 'LICENSE resource is not there')"
pl set string "" "$(model_file)" /DISTRIBUTION/RESOURCES/LICENSE

section "80. acceptance: the BOM matches the shipped replay_2.2.pkg"
# Design 13's acceptance criterion for this phase. Skipped rather than failed
# when the reference package is not on this machine, so the suite stays usable
# on a checkout that does not carry replay's distributions.
reference_pkg="${PACKAGEBUILDER_REFERENCE_PKG:-/Users/tkukielk/Development/replay-Distributions/build/replay_2.2.pkg}"
if [ -f "$reference_pkg" ]; then
    omc_run PackageBuilder.step.distribution
    /bin/rm -rf "$OMCTEST_WORK/acc-mine" "$OMCTEST_WORK/acc-ref"
    /usr/sbin/pkgutil --expand "$(built_dist)" "$OMCTEST_WORK/acc-mine" >/dev/null 2>&1
    /usr/sbin/pkgutil --expand "$reference_pkg" "$OMCTEST_WORK/acc-ref" >/dev/null 2>&1
    check "same top-level layout"  "Distribution replay.pkg Resources" "$(/bin/ls "$OMCTEST_WORK/acc-mine" | /usr/bin/sort | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')"
    # Paths, ownership and modes must match exactly. installKBytes legitimately
    # differs - the fixtures are stand-in binaries, not the real tools.
    #
    # Compared through temp files, not "diff <(a) <(b)": process substitution is
    # a bashism, and under /bin/sh it fails at parse time inside the command
    # substitution, yielding empty output that compares equal to an empty
    # expectation. The check then passes without ever having run. That is the
    # same class of silent-vacuous-success this suite exists to catch, and it
    # got past sh -n because the text is only parsed when the substitution runs.
    /usr/bin/lsbom -p fugm "$OMCTEST_WORK/acc-mine/replay.pkg/Bom" | /usr/bin/sort > "$OMCTEST_WORK/bom-mine.txt"
    /usr/bin/lsbom -p fugm "$OMCTEST_WORK/acc-ref/replay.pkg/Bom"  | /usr/bin/sort > "$OMCTEST_WORK/bom-ref.txt"
    check "BOM is non-empty"       "yes" "$([ -s "$OMCTEST_WORK/bom-mine.txt" ] && echo yes || echo no)"
    check "BOM identical"          ""    "$(diff "$OMCTEST_WORK/bom-mine.txt" "$OMCTEST_WORK/bom-ref.txt")"
    /usr/bin/sed -e 's/generator-version="[^"]*"//' -e 's/installKBytes="[0-9]*"//' \
        "$OMCTEST_WORK/acc-mine/replay.pkg/PackageInfo" > "$OMCTEST_WORK/pi-mine.txt"
    /usr/bin/sed -e 's/generator-version="[^"]*"//' -e 's/installKBytes="[0-9]*"//' \
        "$OMCTEST_WORK/acc-ref/replay.pkg/PackageInfo" > "$OMCTEST_WORK/pi-ref.txt"
    check "PackageInfo is non-empty" "yes" "$([ -s "$OMCTEST_WORK/pi-mine.txt" ] && echo yes || echo no)"
    check "PackageInfo attributes"   ""    "$(diff "$OMCTEST_WORK/pi-mine.txt" "$OMCTEST_WORK/pi-ref.txt")"
else
    skip_section "section 80: the reference package is not on this machine ($reference_pkg)"
fi

# --- Signing and the whole pipeline -------------------------------------------

# These need a real Developer ID Installer certificate.
harness_identity="$(signing_identity)"

section "81. the whole pipeline, end to end"
setup_replay_project
/bin/mkdir -p "$OMCTEST_WORK/out"
/bin/rm -f "$OMCTEST_WORK/out"/*.pkg
pl set string "$OMCTEST_WORK/out" "$(model_file)" /PROJECT/OUTPUT_DIR
if [ -n "$harness_identity" ]; then
    pl set string "$harness_identity" "$(model_file)" /SIGNING/INSTALLER_IDENTITY
    omc_run PackageBuilder.build
    check "preconditions passed"   "1"                       "$(log_says 'all clear')"
    check "a signed package"       "yes"                     "$([ -n "$(built_signed)" ] && [ -f "$(built_signed)" ] && echo yes || echo no)"
    # ${NAME}_${VERSION}.pkg is the default pattern.
    check "name from the pattern"  "replay_2.2.pkg"          "$(/usr/bin/basename "$(built_signed)")"
    check "written to the output"  "$OMCTEST_WORK/out"       "$(/usr/bin/dirname "$(built_signed)")"
    check "signature verifies"     "1"                       "$(/usr/sbin/pkgutil --check-signature "$(built_signed)" >/dev/null 2>&1 && echo 1 || echo 0)"
    check "trusted timestamp"      "1"                       "$(log_says 'trusted timestamp')"
    check "notarization mentioned" "1"                       "$(log_says 'NOT notarized')"
    check "busy flag cleared"      ""                        "$(pb_get busy)"

    section "82. only a signed package ever reaches the output folder (8.3)"
    # The old Packages.app flow left replay_1.0.1-unsigned.pkg,
    # replay_1.1-unsigned.pkg and replay_2.0-unsigned.pkg next to the real ones.
    check "no unsigned in output"  "0"                       "$(/bin/ls "$OMCTEST_WORK/out" | /usr/bin/grep -c 'unsigned')"
    check "exactly one package"    "1"                       "$(/bin/ls "$OMCTEST_WORK/out" | /usr/bin/grep -c '\.pkg$')"
    check "unsigned in the scratch" "yes"                    "$([ -f "$(state_dir)/replay-unsigned.pkg" ] && echo yes || echo no)"

    section "83. the package name expands its tokens"
    pl set string 'tool-${VERSION}-${NAME}' "$(model_file)" /PROJECT/PACKAGE_NAME
    omc_run PackageBuilder.build
    # The .pkg is appended when the pattern does not carry one.
    check "tokens expanded"        "tool-2.2-replay.pkg"     "$(/usr/bin/basename "$(built_signed)")"
    pl set string '${NAME}_${VERSION}.pkg' "$(model_file)" /PROJECT/PACKAGE_NAME

    section "84. a failed signature leaves nothing in the output folder"
    /bin/rm -f "$OMCTEST_WORK/out"/*.pkg
    pl set string "Developer ID Installer: Nobody At All (ZZZZZZZZZZ)" "$(model_file)" /SIGNING/INSTALLER_IDENTITY
    omc_run PackageBuilder.build
    check "identity refused"       "1"                       "$(log_says 'is not in this machine')"
    check "nothing was written"    "0"                       "$(/bin/ls "$OMCTEST_WORK/out" | /usr/bin/grep -c '\.pkg$')"
    check "no package recorded"    ""                        "$(built_signed)"
    pl set string "$harness_identity" "$(model_file)" /SIGNING/INSTALLER_IDENTITY
else
    skip_section "sections 81-84: no Developer ID Installer certificate in this keychain"
fi

section "85. signing turned off stops before the output folder"
setup_replay_project
/bin/rm -f "$OMCTEST_WORK/out"/*.pkg
pl set string "$OMCTEST_WORK/out" "$(model_file)" /PROJECT/OUTPUT_DIR
pl set bool false "$(model_file)" /SIGNING/ENABLED
omc_run PackageBuilder.build
check "said so plainly"          "1"                         "$(log_says 'Signing is turned off')"
check "output folder untouched"  "0"                         "$(/bin/ls "$OMCTEST_WORK/out" | /usr/bin/grep -c '\.pkg$')"
check "unsigned kept in scratch" "yes"                       "$([ -f "$(state_dir)/replay-unsigned.pkg" ] && echo yes || echo no)"
pl set bool true "$(model_file)" /SIGNING/ENABLED

section "86. signing preconditions are checked before anything runs"
setup_replay_project
pl set string "" "$(model_file)" /PROJECT/OUTPUT_DIR
omc_run PackageBuilder.build
check "no output folder refused" "1"                         "$(log_says 'No output folder is set')"
# The whole build refuses up front rather than after pkgbuild and productbuild
# have already run, so the user is not made to wait to be told something that
# was knowable at the start.
check "nothing was staged"       "no"                        "$([ -d "$(state_dir)/root" ] && echo yes || echo no)"
pl set string "$OMCTEST_WORK/out" "$(model_file)" /PROJECT/OUTPUT_DIR
pl set string 'sub/dir/name.pkg' "$(model_file)" /PROJECT/PACKAGE_NAME
omc_run PackageBuilder.build
check "path separator refused"   "1"                         "$(log_says 'must not contain a path separator')"
pl set string '${NAME}_${VERSION}.pkg' "$(model_file)" /PROJECT/PACKAGE_NAME

section "87. Sign Only needs a distribution package first"
setup_replay_project
pl set string "$OMCTEST_WORK/out" "$(model_file)" /PROJECT/OUTPUT_DIR
omc_run PackageBuilder.step.sign
check "refused without one"      ""                          "$(built_signed)"

section "88. the identity picker resolves either value channel (5.2)"
# A Picker delivers the 1-based option index when its options are plain strings
# and the tag when they carry one. Which a runtime-populated picker uses is not
# established, so the reader accepts both against the ordered list.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
printf 'First Identity\nSecond Identity\n' > "$(state_dir)/identities.txt"
# Index 1 is the leading "(choose an identity)" row, so a certificate's index is
# one further along than its line in identities.txt.
check "row 1 means none"         ""                          "$(pb_call resolve_identity_value 1)"
check "row 2 is the first"       "First Identity"            "$(pb_call resolve_identity_value 2)"
check "row 3 is the second"      "Second Identity"           "$(pb_call resolve_identity_value 3)"
check "a name passes through"    "First Identity"            "$(pb_call resolve_identity_value 'First Identity')"
check "an unknown index is kept" "9"                         "$(pb_call resolve_identity_value 9)"
check "empty stays empty"        ""                          "$(pb_call resolve_identity_value '')"
# The picker writes the resolved name into the document, not the index.
omc_fire PackageBuilder.field.changed $IDENTITY_PICKER_ID "3"
check "resolved before storing"  "Second Identity"           "$(model /SIGNING/INSTALLER_IDENTITY)"

section "89. a quote in an identity cannot break the picker options"
check "quote escaped"            'a\"b'                      "$(pb_call json_escape 'a"b')"
check "backslash escaped"        'a\\\\b'                    "$(pb_call json_escape 'a\\b')"
check "backslash done first"     '\\\\\"'                    "$(pb_call json_escape '\\"')"

# --- Regressions from the phase 3 review --------------------------------------

section "90. a failed sign must not destroy the previous release"
# The output folder is written into, never cleaned (design 8.4). Removing the
# destination before productsign meant a failed sign - a declined keychain
# prompt, a full disk - left the folder empty where a good package had been,
# and rebuilding the same version is the ordinary retry case.
setup_replay_project
/bin/rm -rf "$OMCTEST_WORK/out"; /bin/mkdir -p "$OMCTEST_WORK/out"
printf 'the previous good release\n' > "$OMCTEST_WORK/out/replay_2.2.pkg"
pl set string "$OMCTEST_WORK/out" "$(model_file)" /PROJECT/OUTPUT_DIR
pl set string "Developer ID Installer: Nobody At All (ZZZZZZZZZZ)" "$(model_file)" /SIGNING/INSTALLER_IDENTITY
omc_run PackageBuilder.step.component
omc_run PackageBuilder.step.distribution
# Bypass the keychain precondition to exercise productsign itself failing.
pb_build_eval 'sign_package "$(built_distribution_path)"' >/dev/null 2>&1
check "previous release intact"  "the previous good release"  "$(/bin/cat "$OMCTEST_WORK/out/replay_2.2.pkg" 2>/dev/null)"
# Debris, not a guard: the ".pbsigning" landing file is only created after
# productsign AND the signature check both succeed, and this scenario forces
# productsign to fail - so no such file can exist here whatever the app does.
# Kept because it is the proof of concept's and costs nothing; it is not what
# proves the previous release survived. The check above is.
check "no half-written sibling"  "0"                          "$(/bin/ls -a "$OMCTEST_WORK/out" | /usr/bin/grep -c 'pbsigning')"

section "91. a precondition count of 256 does not read as zero"
# A shell "return" carries only the low eight bits, so returning the count made
# exactly 256 failures indistinguishable from none - and the pairwise
# destination-clash check is O(n^2), so 23 items sharing a destination reach 253
# on their own. The count now comes from the global, not the return value.
setup_replay_project
/bin/rm -rf "$OMCTEST_WORK/out"; /bin/mkdir -p "$OMCTEST_WORK/out"
pl set string "$OMCTEST_WORK/out" "$(model_file)" /PROJECT/OUTPUT_DIR
# 24 entries sharing one destination is C(24,2) = 276 clashes, past the 255 a
# shell return can carry. 23 would give 253 and prove nothing.
clash_index=0
while [ "$clash_index" -lt 24 ]; do
    pl insert "$clash_index" dict "$(model_file)" /COMPONENTS/0/PAYLOAD 2>/dev/null
    pl set string "/bin/echo"           "$(model_file)" "/COMPONENTS/0/PAYLOAD/$clash_index/SOURCE"
    pl set string "/usr/local/bin/same" "$(model_file)" "/COMPONENTS/0/PAYLOAD/$clash_index/DESTINATION"
    pl set string "0755"                "$(model_file)" "/COMPONENTS/0/PAYLOAD/$clash_index/MODE"
    clash_index=$((clash_index + 1))
done
clashes="$(pb_build_eval 'check_preconditions >/dev/null 2>&1; printf "%s" "$precondition_failures"')"
check "count exceeds 255"        "yes"                        "$([ "${clashes:-0}" -gt 255 ] && echo yes || echo no)"
# The gate must stop the build whatever the count happens to be.
omc_run PackageBuilder.build
check "the build was stopped"    "1"                          "$(log_says 'problem(s) to fix')"
# The count the BUILD reports, not the global the fixture sets. Reading
# $precondition_failures out of the subshell above cannot see this regression at
# all: it is unaffected by how the caller obtains the count, which is the whole
# defect. Nor can "the build was stopped" - 277 truncated to 8 bits is 21, still
# non-zero, so the gate still fires. Only a total that is an exact multiple of
# 256 would flip it, and C(n,2) never lands on one. Found in review.
reported_failures="$(/usr/bin/sed -n 's/.*Stopped: \([0-9]*\) problem.*/\1/p' "$(state_dir)/run.log" | /usr/bin/head -n 1)"
check "and the count survived the gate" "yes"                 "$([ "${reported_failures:-0}" -gt 255 ] && echo yes || echo no)"
check "nothing was staged"       "no"                         "$([ -d "$(state_dir)/root" ] && echo yes || echo no)"
check "output folder untouched"  "0"                          "$(/bin/ls "$OMCTEST_WORK/out" 2>/dev/null | /usr/bin/grep -c '\.pkg$')"

section "92. two resources with the same basename are refused"
# Staged flat under their basenames, the second overwrote the first and both XML
# elements pointed at the survivor - the installer would show the license as the
# readme, from a build that reported success.
setup_replay_project
/bin/mkdir -p "$OMCTEST_WORK/res-a" "$OMCTEST_WORK/res-b"
printf 'THE README\n'  > "$OMCTEST_WORK/res-a/notes.rtf"
printf 'THE LICENSE\n' > "$OMCTEST_WORK/res-b/notes.rtf"
pl set string "$OMCTEST_WORK/res-a/notes.rtf" "$(model_file)" /DISTRIBUTION/RESOURCES/README
pl set string "$OMCTEST_WORK/res-b/notes.rtf" "$(model_file)" /DISTRIBUTION/RESOURCES/LICENSE
omc_run PackageBuilder.step.component
omc_run PackageBuilder.step.distribution
check "the collision is caught"  "1"                          "$(log_says 'both named')"
check "no package was built"     ""                           "$(built_dist)"

section "93. a busy flag left by a dead build does not wedge the app"
setup_replay_project
pb_set busy 1
printf '%s' "$(/bin/sh -c 'echo $$')" > "$(state_dir)/run.pid"
check "dead holder is cleared"   "no"                         "$(pb_build_eval 'build_is_running && echo yes || echo no')"
pb_set busy 1
printf '%s' "$$" > "$(state_dir)/run.pid"
check "live holder respected"    "yes"                        "$(pb_build_eval 'build_is_running && echo yes || echo no')"
pb_set busy ""
/bin/rm -f "$(state_dir)/run.pid"

section "94. a package name edited mid-build cannot escape the output folder"
# Every stage re-reads the live model and the fields stay editable, so the name
# is re-checked where it is used, not only in the preconditions.
setup_replay_project
pl set string "$OMCTEST_WORK/out" "$(model_file)" /PROJECT/OUTPUT_DIR
omc_run PackageBuilder.step.component
omc_run PackageBuilder.step.distribution
pl set string '../escaped.pkg' "$(model_file)" /PROJECT/PACKAGE_NAME
escaped="$(pb_build_eval 'sign_package "$(built_distribution_path)"' 2>/dev/null)"
check "traversal refused"        ""                           "$escaped"
check "nothing outside the dir"  "no"                         "$([ -e "$OMCTEST_WORK/escaped.pkg" ] && echo yes || echo no)"
# Neither check above can see the guard, which a reviewer proved by deleting it:
# with no signing identity productsign dies first, and with one the landing file
# is ".<name>.<pid>.pbsigning", so "../escaped.pkg" fails on a missing directory
# instead. Both are refusals for the wrong reason. The log is what distinguishes
# them - the guard names the package file, productsign names itself.
check "and the name was refused" "1"                          "$(log_says 'is not usable')"
pl set string '${NAME}_${VERSION}.pkg' "$(model_file)" /PROJECT/PACKAGE_NAME

section "95. an unusable minimum macOS is refused, not escaped into the XML"
setup_replay_project
pl set string '10.15 or later' "$(model_file)" /PROJECT/MIN_OS_VERSION
omc_run PackageBuilder.step.component
omc_run PackageBuilder.step.distribution
check "refused by pattern"       "1"                          "$(log_says 'must be a version number')"

section "96. Sign Only re-validates the fields the package name is built from"
setup_replay_project
pl set string "$OMCTEST_WORK/out" "$(model_file)" /PROJECT/OUTPUT_DIR
omc_run PackageBuilder.step.component
omc_run PackageBuilder.step.distribution
pl set string "" "$(model_file)" /PROJECT/NAME
omc_run PackageBuilder.step.sign
check "empty name refused"       "1"                          "$(log_says 'not usable in a filename')"
check "no _.pkg was signed"      ""                           "$(built_signed)"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids"        ""                           "$(ui_unknown_writes)"

omctest_end
