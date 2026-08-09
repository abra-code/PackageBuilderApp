#!/bin/sh
# Tests/70-export-import.test.sh - the exported packaging script, and importing
# a Packages.app project.
#
# Ported from Private/harness.sh sections 121 to 133, in the proof of concept's
# own order: the export block first, with sections 128 to 131 sitting between it
# and the import block exactly where they are there, because 127, 132 and 133
# all read the document section 126 produced.
#
# Sections 126b and 133c have no counterpart in the proof of concept. They came
# in with the change that made import_pkgproj read the user's .pkgproj in place
# instead of a staged copy, and they are what catches that cleanup deleting the
# user's project.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.packagebuilder.sh"

section "121. Export Packaging Script writes a script sh accepts"
# Design section 11: a first-class feature, because the reason this app exists
# is that a GUI tool stopped being maintained and took a release workflow with
# it. The handler's own contract: never leave a file behind that sh -n refuses.
setup_replay_project
exported="$OMCTEST_WORK/makepkg.replay.sh"
/bin/rm -f "$exported"
omc_dialog_answer save_as ""
omc_run PackageBuilder.export.script
check "canceled panel writes nothing" "no"                    "$([ -f "$exported" ] && echo yes || echo no)"
omc_dialog_answer save_as "$exported"
omc_run PackageBuilder.export.script
check "the script was written"   "yes"                        "$([ -f "$exported" ] && echo yes || echo no)"
check "and is executable"        "yes"                        "$([ -x "$exported" ] && echo yes || echo no)"
check "and sh accepts it"        "0"                          "$(/bin/sh -n "$exported" 2>/dev/null; echo $?)"

section "122. the exported script reproduces the package"
# The acceptance test for the whole feature: the script's package and the app's
# own agree on the parts that matter - identifier, version, the
# overwrite-permissions patch, and the Distribution XML's load-bearing lines.
/bin/rm -rf "$OMCTEST_WORK/exported-out"
export_run_log="$OMCTEST_WORK/export-run.log"
/bin/sh "$exported" --unsigned --output-dir "$OMCTEST_WORK/exported-out" > "$export_run_log" 2>&1
check "the script succeeded"     "0"                          "$?"
exported_pkg="$OMCTEST_WORK/exported-out/replay_2.2-unsigned.pkg"
check "the package landed"       "yes"                        "$([ -f "$exported_pkg" ] && echo yes || echo no)"
/bin/rm -rf "$OMCTEST_WORK/exported-expand"
/usr/sbin/pkgutil --expand "$exported_pkg" "$OMCTEST_WORK/exported-expand" >/dev/null 2>&1
check "overwrite-permissions"    'overwrite-permissions="false"' "$(pkginfo_attr "$OMCTEST_WORK/exported-expand/replay.pkg" overwrite-permissions)"
check "identifier"               "1"                          "$(/usr/bin/grep -c 'identifier="com.abracode.pkg.replay"' "$OMCTEST_WORK/exported-expand/replay.pkg/PackageInfo" | /usr/bin/tr -d ' ')"
check "version"                  "1"                          "$(/usr/bin/grep -c ' version="2.2"' "$OMCTEST_WORK/exported-expand/replay.pkg/PackageInfo" | /usr/bin/tr -d ' ')"
check "readme staged"            "yes"                        "$([ -f "$OMCTEST_WORK/exported-expand/Resources/replay-readme.rtf" ] && echo yes || echo no)"
# The app's own package against the script's, Distribution against
# Distribution. Both went through the same productbuild, so agreement here is
# byte-for-byte: the same options, title, choice, pkg-ref, and the same
# installKBytes because the payloads are the same files.
omc_run PackageBuilder.step.component
omc_run PackageBuilder.step.distribution
/bin/rm -rf "$OMCTEST_WORK/app-expand"
/usr/sbin/pkgutil --expand "$(built_dist)" "$OMCTEST_WORK/app-expand" >/dev/null 2>&1
check "XML identical to the app's" "yes"                      "$(/usr/bin/cmp -s "$OMCTEST_WORK/exported-expand/Distribution" "$OMCTEST_WORK/app-expand/Distribution" && echo yes || echo no)"

section "123. --version reaches the name, the PackageInfo and the XML"
/bin/rm -rf "$OMCTEST_WORK/exported-out"
/bin/sh "$exported" --unsigned --version 9.9 --output-dir "$OMCTEST_WORK/exported-out" >/dev/null 2>&1
check "the script succeeded"     "0"                          "$?"
check "the file name follows"    "yes"                        "$([ -f "$OMCTEST_WORK/exported-out/replay_9.9-unsigned.pkg" ] && echo yes || echo no)"
/bin/rm -rf "$OMCTEST_WORK/exported-expand"
/usr/sbin/pkgutil --expand "$OMCTEST_WORK/exported-out/replay_9.9-unsigned.pkg" "$OMCTEST_WORK/exported-expand" >/dev/null 2>&1
check "PackageInfo follows"      "1"                          "$(/usr/bin/grep -c ' version="9.9"' "$OMCTEST_WORK/exported-expand/replay.pkg/PackageInfo" | /usr/bin/tr -d ' ')"
check "the pkg-ref follows"      "1"                          "$(/usr/bin/grep -c 'version="9.9"' "$OMCTEST_WORK/exported-expand/Distribution" | /usr/bin/tr -d ' ')"

section "124. document values with sh syntax in them stay data"
# The generator single-quotes every value and escapes the XML heredoc, so a
# title written to break the emitted shell is just a title. This is the export
# equivalent of design 4.4: textual substitution corrupts silently, so the one
# test that matters is a value built to exploit it.
setup_replay_project
pl set string 'Rock & Roll'\''s $(touch '"$OMCTEST_WORK"'/pwned) `touch '"$OMCTEST_WORK"'/pwned2`' "$(model_file)" /DISTRIBUTION/TITLE
exported_hostile="$OMCTEST_WORK/makepkg.hostile.sh"
omc_dialog_answer save_as "$exported_hostile"
omc_run PackageBuilder.export.script
check "the script was written"   "yes"                        "$([ -f "$exported_hostile" ] && echo yes || echo no)"
check "and sh accepts it"        "0"                          "$(/bin/sh -n "$exported_hostile" 2>/dev/null; echo $?)"
/bin/rm -rf "$OMCTEST_WORK/exported-out"
/bin/sh "$exported_hostile" --unsigned --output-dir "$OMCTEST_WORK/exported-out" >/dev/null 2>&1
check "the script succeeded"     "0"                          "$?"
check "nothing was executed"     "no"                         "$([ -e "$OMCTEST_WORK/pwned" ] || [ -e "$OMCTEST_WORK/pwned2" ] && echo yes || echo no)"
/bin/rm -rf "$OMCTEST_WORK/exported-expand"
/usr/sbin/pkgutil --expand "$OMCTEST_WORK/exported-out/replay_2.2-unsigned.pkg" "$OMCTEST_WORK/exported-expand" >/dev/null 2>&1
# Twice each: the title element and the choice's title attribute.
check "the title is escaped data" "2"                         "$(/usr/bin/grep -c 'Rock &amp; Roll' "$OMCTEST_WORK/exported-expand/Distribution" | /usr/bin/tr -d ' ')"
check "the command text survives" "2"                         "$(/usr/bin/grep -cF 'touch' "$OMCTEST_WORK/exported-expand/Distribution" | /usr/bin/tr -d ' ')"

section "125. the document's verify assertions travel with the script"
# The exported pipeline starts at stage 1 like the app's: a fixture that lacks
# the hardened runtime is refused by the script the same way the app refuses
# it, and nothing is staged or built past the refusal.
setup_replay_project
pl set bool true "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/HARDENED_RUNTIME
exported_verify="$OMCTEST_WORK/makepkg.verify.sh"
omc_dialog_answer save_as "$exported_verify"
omc_run PackageBuilder.export.script
/bin/rm -rf "$OMCTEST_WORK/exported-out"
verify_out="$OMCTEST_WORK/export-verify.log"
/bin/sh "$exported_verify" --unsigned --output-dir "$OMCTEST_WORK/exported-out" > "$verify_out" 2>&1
check "the script refused"       "1"                          "$?"
check "and named the runtime"    "1"                          "$(/usr/bin/grep -c 'hardened runtime' "$verify_out" | /usr/bin/tr -d ' ')"
check "no package was written"   "no"                         "$([ -e "$OMCTEST_WORK/exported-out/replay_2.2-unsigned.pkg" ] && echo yes || echo no)"

section "128. a newline in a value cannot become code in the exported script"
# The one place a document value is not quoted is a "#" comment line, and a
# comment has no quoting: a newline ends it and every following line is
# top-level code. sh -n cannot catch that - what it produces is valid shell -
# so the generator truncates at the first line break instead. The reachable
# chain was a hostile .pkgproj imported and then exported; mkdir accepts a
# newline in a directory name, so the artifacts folder reaches it directly.
setup_replay_project
/bin/rm -f "$OMCTEST_WORK/PWNED_COMMENT"
newline_name="$(printf 'widget\ntouch %s/PWNED_COMMENT' "$OMCTEST_WORK")"
pl set string "$newline_name" "$(model_file)" /PROJECT/NAME
exported_nl="$OMCTEST_WORK/makepkg.newline.sh"
omc_dialog_answer save_as "$exported_nl"
omc_run PackageBuilder.export.script
check "the script was written"   "yes"                        "$([ -f "$exported_nl" ] && echo yes || echo no)"
# Every line of the header block - everything before "set -u" - is a comment
# or blank. A grep for the smuggled command would not do: it also appears
# inside the single-quoted project_name assignment further down, where it is
# data and harmless, which is exactly the distinction being drawn here.
check "the header is all comment" "0"                         "$(/usr/bin/sed -n '2,/^set -u$/p' "$exported_nl" | /usr/bin/grep -cvE '^(#|set -u)?$|^#' | /usr/bin/tr -d ' ')"
check "the truncation is marked" "1"                          "$(/usr/bin/grep -c 'widget \.\.\.' "$exported_nl" | /usr/bin/tr -d ' ')"
# Running it must refuse on the name rule, not execute the smuggled command.
/bin/sh "$exported_nl" --unsigned --output-dir "$OMCTEST_WORK/exported-out" >/dev/null 2>&1
check "nothing was executed"     "no"                         "$([ -e "$OMCTEST_WORK/PWNED_COMMENT" ] && echo yes || echo no)"
# The same through the artifacts folder, which needs no hostile document at all.
setup_replay_project
/bin/rm -f "$OMCTEST_WORK/PWNED_ARTIFACTS"
pl set string "$(printf 'arti\ntouch %s/PWNED_ARTIFACTS' "$OMCTEST_WORK")" "$(model_file)" /PROJECT/ARTIFACTS_DIR
omc_dialog_answer save_as "$OMCTEST_WORK/makepkg.newline2.sh"
omc_run PackageBuilder.export.script
/bin/sh "$OMCTEST_WORK/makepkg.newline2.sh" --unsigned --output-dir "$OMCTEST_WORK/exported-out" >/dev/null 2>&1
check "nor through the artifacts folder" "no"                 "$([ -e "$OMCTEST_WORK/PWNED_ARTIFACTS" ] && echo yes || echo no)"

section "129. a title cannot break out of the Distribution XML"
# The XML is emitted as quoted printf lines rather than a heredoc: no
# terminator can be chosen that a document value provably cannot contain, and
# a line equal to it would put the rest of the document at top level. A
# percent sign is the other half - it would be read as a format if the value
# were the format rather than an argument.
setup_replay_project
/bin/rm -f "$OMCTEST_WORK/PWNED_XML"
pl set string "$(printf 'X\nPB_DIST_XML\ntouch %s/PWNED_XML\n50%% off' "$OMCTEST_WORK")" "$(model_file)" /DISTRIBUTION/TITLE
exported_xml="$OMCTEST_WORK/makepkg.xmlbreak.sh"
omc_dialog_answer save_as "$exported_xml"
omc_run PackageBuilder.export.script
check "the script was written"   "yes"                        "$([ -f "$exported_xml" ] && echo yes || echo no)"
check "and sh accepts it"        "0"                          "$(/bin/sh -n "$exported_xml" 2>/dev/null; echo $?)"
/bin/rm -rf "$OMCTEST_WORK/exported-out"
/bin/sh "$exported_xml" --unsigned --output-dir "$OMCTEST_WORK/exported-out" >/dev/null 2>&1
check "the script succeeded"     "0"                          "$?"
check "nothing was executed"     "no"                         "$([ -e "$OMCTEST_WORK/PWNED_XML" ] && echo yes || echo no)"
/bin/rm -rf "$OMCTEST_WORK/exported-expand"
/usr/sbin/pkgutil --expand "$OMCTEST_WORK/exported-out/replay_2.2-unsigned.pkg" "$OMCTEST_WORK/exported-expand" >/dev/null 2>&1
check "the percent survived"     "2"                          "$(/usr/bin/grep -c '50% off' "$OMCTEST_WORK/exported-expand/Distribution" | /usr/bin/tr -d ' ')"

section "130. the exported script cannot write outside --output-dir"
# The app refuses a package name holding a path separator in its signing
# preconditions; the exported script has to refuse it too, or "../x.pkg"
# lands one directory above the output folder and reports success.
setup_replay_project
pl set string '../escaped_${VERSION}.pkg' "$(model_file)" /PROJECT/PACKAGE_NAME
exported_esc="$OMCTEST_WORK/makepkg.escape.sh"
omc_dialog_answer save_as "$exported_esc"
omc_run PackageBuilder.export.script
/bin/rm -rf "$OMCTEST_WORK/escape-parent"; /bin/mkdir -p "$OMCTEST_WORK/escape-parent/out"
/bin/sh "$exported_esc" --unsigned --output-dir "$OMCTEST_WORK/escape-parent/out" >/dev/null 2>&1
check "the script refused"       "1"                          "$?"
check "nothing landed above it"  "0"                          "$(/usr/bin/find "$OMCTEST_WORK/escape-parent" -maxdepth 1 -name '*.pkg' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
# The extension case set and the unsigned name have to agree, or Widget.PKG
# becomes Widget.PKG-unsigned.pkg.
setup_replay_project
pl set string 'Widget.PKG' "$(model_file)" /PROJECT/PACKAGE_NAME
omc_dialog_answer save_as "$OMCTEST_WORK/makepkg.case.sh"
omc_run PackageBuilder.export.script
/bin/rm -rf "$OMCTEST_WORK/exported-out"
/bin/sh "$OMCTEST_WORK/makepkg.case.sh" --unsigned --output-dir "$OMCTEST_WORK/exported-out" >/dev/null 2>&1
check "uppercase .PKG stripped"  "yes"                        "$([ -f "$OMCTEST_WORK/exported-out/Widget-unsigned.pkg" ] && echo yes || echo no)"

section "131. a framework is read as a bundle by the exported script too"
# A .framework is a versioned bundle: its Info.plist is under
# Versions/<v>/Resources with no Contents directory, so a Contents-only test
# reports it is not a bundle and every check the entry asserts is skipped.
# The app learned this in phase 2; the transcription has to know it as well.
setup_replay_project
/bin/rm -rf "$OMCTEST_WORK/replay-artifacts/Foo.framework"
/bin/mkdir -p "$OMCTEST_WORK/replay-artifacts/Foo.framework/Versions/A/Resources"
/bin/cp /bin/echo "$OMCTEST_WORK/replay-artifacts/Foo.framework/Versions/A/Foo"
/usr/bin/plutil -create xml1 "$OMCTEST_WORK/replay-artifacts/Foo.framework/Versions/A/Resources/Info.plist" >/dev/null 2>&1
/usr/bin/plutil -insert CFBundleExecutable -string Foo "$OMCTEST_WORK/replay-artifacts/Foo.framework/Versions/A/Resources/Info.plist" >/dev/null 2>&1
/bin/ln -s A "$OMCTEST_WORK/replay-artifacts/Foo.framework/Versions/Current"
omc_dialog_answer choose_object "$OMCTEST_WORK/replay-artifacts/Foo.framework"
omc_run PackageBuilder.payload.add
framework_index="$(( $(count /COMPONENTS/0/PAYLOAD) - 1 ))"
pb_call payload_archs_set "$framework_index" "x86_64"
pl set string "" "$(model_file)" "/COMPONENTS/0/PAYLOAD/$framework_index/VERIFY/SIGNED_BY"
pl set bool false "$(model_file)" "/COMPONENTS/0/PAYLOAD/$framework_index/VERIFY/HARDENED_RUNTIME"
pl set bool false "$(model_file)" "/COMPONENTS/0/PAYLOAD/$framework_index/VERIFY/SECURE_TIMESTAMP"
pl set string "" "$(model_file)" "/COMPONENTS/0/PAYLOAD/$framework_index/VERIFY/VERSION_FLAG"
exported_fw="$OMCTEST_WORK/makepkg.framework.sh"
omc_dialog_answer save_as "$exported_fw"
omc_run PackageBuilder.export.script
/bin/rm -rf "$OMCTEST_WORK/exported-out"
fw_log="$OMCTEST_WORK/export-framework.log"
/bin/sh "$exported_fw" --unsigned --output-dir "$OMCTEST_WORK/exported-out" > "$fw_log" 2>&1
check "the script succeeded"     "0"                          "$?"
check "the framework was read"   "1"                          "$(/usr/bin/grep -c 'Foo.framework: built for' "$fw_log" | /usr/bin/tr -d ' ')"
check "not refused as opaque"    "0"                          "$(/usr/bin/grep -c 'no Mach-O executable' "$fw_log" | /usr/bin/tr -d ' ')"

# --- Importing a Packages.app project -----------------------------------------

section "126. Import Packages.app Project maps the document across"
# Design section 10, against a fixture shaped like replay_2.0.pkgproj: the
# system-tree scaffold with its hidden (-1) nodes, TYPE = 3 payload leaves
# under different archive directories, integer permissions, and a
# project-relative readme and build path. plutil builds the XML plist from
# JSON so the fixture stays readable here.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/Imported.pkgbld"
omc_run PackageBuilder.save.as
/bin/rm -rf "$OMCTEST_WORK/pkgimport"
/bin/mkdir -p "$OMCTEST_WORK/pkgimport/archives/alpha.xcarchive/Products/usr/local/bin" \
             "$OMCTEST_WORK/pkgimport/archives/beta.xcarchive/Products/usr/local/bin"
/bin/cp /bin/echo "$OMCTEST_WORK/pkgimport/archives/alpha.xcarchive/Products/usr/local/bin/alpha"
/bin/cp /bin/echo "$OMCTEST_WORK/pkgimport/archives/beta.xcarchive/Products/usr/local/bin/beta"
printf 'x\n' > "$OMCTEST_WORK/pkgimport/archives/data.plist"
printf '{\\rtf1\\ansi imported}\n' > "$OMCTEST_WORK/pkgimport/readme_import.rtf"
/bin/cat > "$OMCTEST_WORK/pkgimport/fixture.json" <<'PKGPROJ'
{"PACKAGES":[{"PACKAGE_SETTINGS":{"NAME":"imported","VERSION":"3.1",
  "IDENTIFIER":"com.example.pkg.imported","OVERWRITE_PERMISSIONS":false,
  "RELOCATABLE":false,"AUTHENTICATION":1},
 "PACKAGE_FILES":{"DEFAULT_INSTALL_LOCATION":"/",
  "HIERARCHY":{"TYPE":1,"PATH":"/","PATH_TYPE":0,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[
   {"TYPE":-1,"PATH":"usr","PATH_TYPE":0,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[
    {"TYPE":-1,"PATH":"local","PATH_TYPE":0,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[
     {"TYPE":-1,"PATH":"bin","PATH_TYPE":0,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[
      {"TYPE":3,"PATH":"archives/alpha.xcarchive/Products/usr/local/bin/alpha","PATH_TYPE":1,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[]},
      {"TYPE":3,"PATH":"archives/beta.xcarchive/Products/usr/local/bin/beta","PATH_TYPE":1,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[]}]}]}]},
   {"TYPE":1,"PATH":"Library","PATH_TYPE":0,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[
    {"TYPE":3,"PATH":"archives/data.plist","PATH_TYPE":1,"UID":0,"GID":80,"PERMISSIONS":420,"CHILDREN":[]}]}]}}}],
 "PROJECT":{"PROJECT_SETTINGS":{"BUILD_PATH":{"PATH":"build","PATH_TYPE":1},
   "EXCLUDED_FILES":[{"PATTERN":".DS_Store"}]},
  "PROJECT_PRESENTATION":{"INSTALLATION_STEPS":[{"STEP":"license"}],
   "README":{"LOCALIZATIONS":[{"LANGUAGE":"English","VALUE":{"PATH":"readme_import.rtf","PATH_TYPE":1}}]}},
  "PROJECT_REQUIREMENTS":{"LIST":[{"NAME":"os"}]}}}
PKGPROJ
/usr/bin/plutil -convert xml1 -o "$OMCTEST_WORK/pkgimport/Fixture.pkgproj" "$OMCTEST_WORK/pkgimport/fixture.json" >/dev/null 2>&1
fixture_hash="$(hash_of "$OMCTEST_WORK/pkgimport/Fixture.pkgproj")"
omc_dialog_answer choose_file "$OMCTEST_WORK/pkgimport/Fixture.pkgproj"
omc_run PackageBuilder.import.pkgproj
check "name"                     "imported"                   "$(model /PROJECT/NAME)"
check "version"                  "3.1"                        "$(model /PROJECT/VERSION)"
check "identifier"               "com.example.pkg.imported"   "$(model /COMPONENTS/0/IDENTIFIER)"
check "auth 1 becomes Root"      "Root"                       "$(model /COMPONENTS/0/AUTH)"
check "install location"         "/"                          "$(model /COMPONENTS/0/INSTALL_LOCATION)"
# The two safety-relevant bools, which must not invert on the way in: design
# 8.1's overwrite-permissions and 8.2's relocatable.
check "overwrite-permissions"    "false"                      "$(model /COMPONENTS/0/OVERWRITE_PERMISSIONS)"
check "relocatable"              "false"                      "$(model /COMPONENTS/0/RELOCATABLE)"
check "three entries, not the scaffold" "3"                   "$(count /COMPONENTS/0/PAYLOAD)"
check "artifacts folder factored" "pkgimport/archives"        "$(model /PROJECT/ARTIFACTS_DIR)"
check "source tokenized"         '${ARTIFACTS_DIR}/alpha.xcarchive/Products/usr/local/bin/alpha' "$(payload_field 0 SOURCE)"
check "destination accumulated"  "/usr/local/bin/alpha"       "$(payload_field 0 DESTINATION)"
check "permissions rendered octal" "0755"                     "$(payload_field 0 MODE)"
check "a Mach-O asserts hardened" "true"                      "$(model /COMPONENTS/0/PAYLOAD/0/VERIFY/HARDENED_RUNTIME)"
check "the Library leaf came too" "/Library/data.plist"       "$(payload_field 2 DESTINATION)"
check "with its own mode"        "0644"                       "$(payload_field 2 MODE)"
check "and its numeric group"    "80"                         "$(payload_field 2 GROUP)"
check "a plain file asserts nothing" "false"                  "$(model /COMPONENTS/0/PAYLOAD/2/VERIFY/HARDENED_RUNTIME)"
check "output dir from BUILD_PATH" "pkgimport/build"          "$(model /PROJECT/OUTPUT_DIR)"
check "readme came across"       "pkgimport/readme_import.rtf" "$(model /DISTRIBUTION/RESOURCES/README)"
check "the drops are reported"   "1"                          "$(log_says 'Not imported:')"
check "requirements named"       "1"                          "$(log_says 'requirement list')"
check "exclusions named"         "1"                          "$(log_says 'excluded-file patterns')"
check "the document is dirty"    "1"                          "$(dirty)"

section "126b. the project is read where it lies, and survives it"
# Not from the proof of concept. import_file names the USER'S file now, and the
# cleanup at the end of import_pkgproj used to remove import_file by name -
# which against the source deletes the project on every successful import,
# silently, because the import reports success.
#
# No dispatch and no reset here on purpose: 127, 132 and 133 all read the
# document section 126 produced.
check_exists "the source project survives" "$OMCTEST_WORK/pkgimport/Fixture.pkgproj"
check "and its bytes are unchanged" "$fixture_hash"           "$(hash_of "$OMCTEST_WORK/pkgimport/Fixture.pkgproj")"

section "127. an import that cannot be read changes nothing"
# The refusal paths: a canceled panel, and a file that is not a Packages
# project. Both leave the model exactly as it was.
pl set string "keepme" "$(model_file)" /PROJECT/NAME
omc_dialog_answer choose_file ""
omc_run PackageBuilder.import.pkgproj
check "canceled panel is a no-op" "keepme"                    "$(model /PROJECT/NAME)"
printf 'not a plist\n' > "$OMCTEST_WORK/pkgimport/garbage.pkgproj"
omc_dialog_answer choose_file "$OMCTEST_WORK/pkgimport/garbage.pkgproj"
omc_run PackageBuilder.import.pkgproj
check "garbage leaves the name"  "keepme"                     "$(model /PROJECT/NAME)"
check "and the payload"          "3"                          "$(count /COMPONENTS/0/PAYLOAD)"
check "and says why"             "1"                          "$(log_says 'does not look like a Packages.app project')"
# A walk that fails part-way must be a no-op too, which is why the settings
# are read before anything is written rather than applied as they are read. A
# payload path with a line break is the failure that gets there.
/bin/cat > "$OMCTEST_WORK/pkgimport/badwalk.json" <<'PKGPROJ'
{"PACKAGES":[{"PACKAGE_SETTINGS":{"NAME":"clobbered","VERSION":"9.9",
  "IDENTIFIER":"com.example.pkg.clobbered"},
 "PACKAGE_FILES":{"DEFAULT_INSTALL_LOCATION":"/",
  "HIERARCHY":{"TYPE":1,"PATH":"/","PATH_TYPE":0,"CHILDREN":[
   {"TYPE":3,"PATH":"one\nbad/two","PATH_TYPE":1,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[]}]}}}]}
PKGPROJ
/usr/bin/plutil -convert xml1 -o "$OMCTEST_WORK/pkgimport/BadWalk.pkgproj" "$OMCTEST_WORK/pkgimport/badwalk.json" >/dev/null 2>&1
omc_dialog_answer choose_file "$OMCTEST_WORK/pkgimport/BadWalk.pkgproj"
omc_run PackageBuilder.import.pkgproj
check "a failed walk keeps the name" "keepme"                 "$(model /PROJECT/NAME)"
check "and the version"          "3.1"                        "$(model /PROJECT/VERSION)"
check "and the payload"          "3"                          "$(count /COMPONENTS/0/PAYLOAD)"
check "and names the line break" "1"                          "$(log_says 'contains a line break')"

section "132. a scaffold-only project does not empty the payload"
# The removal used to run before the "no entries" guard, so a project that
# describes the system tree and references nothing emptied the payload and
# reported success - the one outcome an import must never produce quietly.
/bin/cat > "$OMCTEST_WORK/pkgimport/scaffold.json" <<'PKGPROJ'
{"PACKAGES":[{"PACKAGE_SETTINGS":{"NAME":"scaffold","VERSION":"1.0",
  "IDENTIFIER":"com.example.pkg.scaffold"},
 "PACKAGE_FILES":{"DEFAULT_INSTALL_LOCATION":"/",
  "HIERARCHY":{"TYPE":1,"PATH":"/","PATH_TYPE":0,"CHILDREN":[
   {"TYPE":-1,"PATH":"usr","PATH_TYPE":0,"CHILDREN":[]}]}}}]}
PKGPROJ
/usr/bin/plutil -convert xml1 -o "$OMCTEST_WORK/pkgimport/Scaffold.pkgproj" "$OMCTEST_WORK/pkgimport/scaffold.json" >/dev/null 2>&1
omc_dialog_answer choose_file "$OMCTEST_WORK/pkgimport/Scaffold.pkgproj"
omc_run PackageBuilder.import.pkgproj
check "the payload survived"     "3"                          "$(count /COMPONENTS/0/PAYLOAD)"
check "and the drop is logged"   "1"                          "$(log_says 'no payload references')"
check "the settings still came"  "scaffold"                   "$(model /PROJECT/NAME)"

section "133. relative payload paths do not hang the import"
# import_common_prefix walked dirname until the prefix was "/", but dirname
# "." is "." forever, so two relative sources spun there with the model lock
# held - and a live holder is never reclaimed, which wedged the window on
# "Busy" for good. Progress, not "/", is what ends the loop now.
/bin/cat > "$OMCTEST_WORK/pkgimport/relative.json" <<'PKGPROJ'
{"PACKAGES":[{"PACKAGE_SETTINGS":{"NAME":"relative","VERSION":"1.0",
  "IDENTIFIER":"com.example.pkg.relative"},
 "PACKAGE_FILES":{"DEFAULT_INSTALL_LOCATION":"/",
  "HIERARCHY":{"TYPE":1,"PATH":"/","PATH_TYPE":0,"CHILDREN":[
   {"TYPE":3,"PATH":"alpha","PATH_TYPE":0,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[]},
   {"TYPE":3,"PATH":"beta","PATH_TYPE":0,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[]}]}}}]}
PKGPROJ
/usr/bin/plutil -convert xml1 -o "$OMCTEST_WORK/pkgimport/Relative.pkgproj" "$OMCTEST_WORK/pkgimport/relative.json" >/dev/null 2>&1
# Its own subshell, so the one-shot dialog variables belong to the background
# dispatch and cannot be cleared out from under it by anything here.
( omc_dialog_answer choose_file "$OMCTEST_WORK/pkgimport/Relative.pkgproj"
  omc_run PackageBuilder.import.pkgproj ) &
relative_import=$!
relative_waited=0
while [ "$relative_waited" -lt 20 ] && /bin/kill -0 "$relative_import" 2>/dev/null; do
    /bin/sleep 1
    relative_waited=$((relative_waited + 1))
done
if /bin/kill -0 "$relative_import" 2>/dev/null; then
    /bin/kill -9 "$relative_import" 2>/dev/null
    check "the import terminated"  "yes"                      "no"
else
    check "the import terminated"  "yes"                      "yes"
fi
wait "$relative_import" 2>/dev/null
check "two entries came in"      "2"                          "$(count /COMPONENTS/0/PAYLOAD)"
# No prefix was factored out, so the sources keep exactly what the project
# said and the artifacts folder is left alone rather than being pointed at a
# relative fragment nobody can resolve. (The value here is the one section 126
# imported; this asserts the relative import did not overwrite it.)
check "the source is untouched"  "alpha"                      "$(payload_field 0 SOURCE)"
check "no relative prefix stored" "pkgimport/archives"        "$(model /PROJECT/ARTIFACTS_DIR)"
check "the lock was released"    "no"                         "$([ -d "$(state_dir)/model.lock" ] && echo yes || echo no)"

section "133b. a binary .pkgproj imports the same as an XML one"
# Binary is the other form Packages.app writes. The staged copy used to get this
# for free from its .plist name; reading in place makes it plister's content
# fallback that has to recognize it, so it is worth one section of its own.
/bin/cp "$OMCTEST_WORK/pkgimport/Fixture.pkgproj" "$OMCTEST_WORK/pkgimport/Binary.pkgproj"
/usr/bin/plutil -convert binary1 "$OMCTEST_WORK/pkgimport/Binary.pkgproj" >/dev/null 2>&1
check "the fixture really is binary" "1"                      "$(/usr/bin/file -b "$OMCTEST_WORK/pkgimport/Binary.pkgproj" | /usr/bin/grep -c 'inary')"
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/ImportedBinary.pkgbld"
omc_run PackageBuilder.save.as
omc_dialog_answer choose_file "$OMCTEST_WORK/pkgimport/Binary.pkgproj"
omc_run PackageBuilder.import.pkgproj
check "a binary .pkgproj imports" "imported"                  "$(model /PROJECT/NAME)"
check "with the same payload"    "3"                          "$(count /COMPONENTS/0/PAYLOAD)"
check "and the same tokenization" '${ARTIFACTS_DIR}/alpha.xcarchive/Products/usr/local/bin/alpha' "$(payload_field 0 SOURCE)"
check_exists "and it survives as well" "$OMCTEST_WORK/pkgimport/Binary.pkgproj"

section "133c. a project that cannot be read is named as unreadable"
# Not from the proof of concept either. Driven through the CLI on purpose: the
# window handler has its own readability check and would refuse this before
# import_pkgproj ever ran, while the CLI's gate is only "is it a file", so this
# is the path that reaches the guard under test. Before that guard existed the
# answer was "this does not look like a Packages.app project", which is
# plausible and names the wrong problem.
/bin/cp "$OMCTEST_WORK/pkgimport/Fixture.pkgproj" "$OMCTEST_WORK/pkgimport/Locked.pkgproj"
/bin/chmod 000 "$OMCTEST_WORK/pkgimport/Locked.pkgproj"
pbcli import-pkgproj "$OMCTEST_WORK/pkgimport/Locked.pkgproj" "$OMCTEST_WORK/Locked.pkgbld" --force \
    > "$OMCTEST_WORK/locked.txt" 2>&1
check "it refused"               "1"                          "$([ -s "$OMCTEST_WORK/locked.txt" ] && echo 1 || echo 0)"
check "and said it cannot read it" "1"                        "$(/usr/bin/grep -c 'cannot be read' "$OMCTEST_WORK/locked.txt" | /usr/bin/tr -d ' ')"
check "not that it is the wrong format" "0"                   "$(/usr/bin/grep -c 'does not look like' "$OMCTEST_WORK/locked.txt" | /usr/bin/tr -d ' ')"
/bin/chmod 644 "$OMCTEST_WORK/pkgimport/Locked.pkgproj"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids"        ""                           "$(ui_unknown_writes)"

omctest_end
