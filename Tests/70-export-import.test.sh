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

# --- 134 to 139: importing a built package ------------------------------------
#
# No counterpart in the proof of concept - this feature came after it. The
# fixtures are built with pkgbuild and productbuild rather than checked in,
# because the thing under test is whether a document can be recovered from a
# real package, and a hand-written fixture would only prove that the reader
# matches the writer of the fixture.

make_import_pkg() { # <dir> - builds <dir>/root, <dir>/comp/tools.pkg
    local base="$1"
    /bin/rm -rf "$base"
    /bin/mkdir -p "$base/root/usr/local/bin" \
                  "$base/root/Applications/Demo.app/Contents/MacOS" \
                  "$base/root/usr/local/share" "$base/comp" "$base/out"
    /bin/cp /bin/echo "$base/root/usr/local/bin/tool"
    /bin/cp /bin/echo "$base/root/Applications/Demo.app/Contents/MacOS/Demo"
    # A REAL Info.plist, not "<plist/>". pkgbuild only records a <bundle path=>
    # element for a directory it recognizes as a bundle, which needs at least a
    # CFBundleIdentifier - with a stub plist the bundle list comes out empty and
    # the collapse below happens entirely through the awk derived-root fallback,
    # leaving importpkg_bundle_roots and its load-bearing path= filter untested.
    # Section 135 asserts the list is populated so the two paths stay distinct.
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.example.demo" \
        -c "Add :CFBundleExecutable string Demo" \
        -c "Add :CFBundleName string Demo" \
        "$base/root/Applications/Demo.app/Contents/Info.plist" >/dev/null 2>&1
    printf 'notes\n' > "$base/root/usr/local/share/notes.txt"
    /bin/chmod 644 "$base/root/usr/local/share/notes.txt"
    # A FLAT bundle: its Info.plist sits at the top of the bundle, not under
    # Contents/ or Versions/<v>/Resources/. pkgbuild records it in PackageInfo,
    # and the awk derived-root fallback - which only knows those two layouts -
    # cannot see it. So this is the one payload item whose collapse proves
    # importpkg_bundle_roots actually read the bundle list.
    /bin/mkdir -p "$base/root/Library/Bees/Flat.bundle"
    printf 'x\n' > "$base/root/Library/Bees/Flat.bundle/thing.dat"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.example.flat" \
        -c "Add :CFBundlePackageType string BNDL" \
        "$base/root/Library/Bees/Flat.bundle/Info.plist" >/dev/null 2>&1
    /usr/bin/pkgbuild --root "$base/root" --identifier com.example.pkg.demo \
        --version 4.2 --install-location / --ownership recommended \
        "$base/comp/tools.pkg" >/dev/null 2>&1
}

section "134. a built package becomes a document"
# The acceptance test for the feature: everything a package records comes back.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/FromPkg.pkgbld"
omc_run PackageBuilder.save.as
make_import_pkg "$OMCTEST_WORK/pkgin"
/bin/cat > "$OMCTEST_WORK/pkgin/Distribution.xml" <<'DISTXML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<installer-gui-script minSpecVersion="2">
    <options hostArchitectures="arm64" customize="allow" require-scripts="true"/>
    <volume-check><allowed-os-versions><os-version min="12.3"/></allowed-os-versions></volume-check>
    <title>Demo Suite</title>
    <choices-outline><line choice="c0"/></choices-outline>
    <choice id="c0" title="Demo"><pkg-ref id="com.example.pkg.demo"/></choice>
    <pkg-ref id="com.example.pkg.demo" version="4.2" auth="Root">#tools.pkg</pkg-ref>
</installer-gui-script>
DISTXML
/usr/bin/productbuild --distribution "$OMCTEST_WORK/pkgin/Distribution.xml" \
    --package-path "$OMCTEST_WORK/pkgin/comp" "$OMCTEST_WORK/pkgin/out/Demo_4.2.pkg" >/dev/null 2>&1
omc_dialog_answer choose_file "$OMCTEST_WORK/pkgin/out/Demo_4.2.pkg"
omc_run PackageBuilder.import.pkg
check "identifier"               "com.example.pkg.demo"       "$(model /COMPONENTS/0/IDENTIFIER)"
check "version"                  "4.2"                        "$(model /PROJECT/VERSION)"
check "install location"         "/"                          "$(model /COMPONENTS/0/INSTALL_LOCATION)"
check "title"                    "Demo Suite"                 "$(model /DISTRIBUTION/TITLE)"
# A title is free text and PROJECT/NAME is a filename component (design 4.4),
# so the space has to be folded rather than carried into a package file name.
check "name folded to the safe set" "Demo_Suite"              "$(model /PROJECT/NAME)"
check "minimum macOS"            "12.3"                       "$(model /PROJECT/MIN_OS_VERSION)"
check "customize"                "allow"                      "$(model /DISTRIBUTION/CUSTOMIZE)"
check "require-scripts"          "true"                       "$(model /DISTRIBUTION/REQUIRE_SCRIPTS)"
check "one host architecture"    "1"                          "$(count /DISTRIBUTION/HOST_ARCHITECTURES)"
check "and it is the declared one" "arm64"                    "$(model /DISTRIBUTION/HOST_ARCHITECTURES/0)"
# auth comes from the Distribution pkg-ref, never PackageInfo, which always
# says root whatever was asked for (design section 4).
check "auth from the pkg-ref"    "Root"                       "$(model /COMPONENTS/0/AUTH)"
# design 8.1: pkgbuild writes overwrite-permissions="true" and the app patches
# it to false. This package was built by pkgbuild alone, so it says true, and
# the import must carry that across rather than substituting the safe default.
check "overwrite-permissions as built" "true"                 "$(model /COMPONENTS/0/OVERWRITE_PERMISSIONS)"
check "the document is dirty"    "1"                          "$(dirty)"

section "135. the payload collapses to artifacts, not to files"
# The whole point of reading PackageInfo's bundle list: a BOM lists every file
# inside Demo.app, and the document wants one entry naming the bundle.
#
# The fixture carries a real CFBundleIdentifier so pkgbuild actually writes the
# <bundle path=> element, which is what importpkg_bundle_roots reads. Asserted
# here rather than assumed: with a stub Info.plist the list is empty and the
# collapse still happens, through the awk derived-root fallback, so a regression
# in the bundle-list reader would leave every other check in this section green.
/bin/rm -rf "$OMCTEST_WORK/pkginexp"
/usr/sbin/pkgutil --expand "$OMCTEST_WORK/pkgin/comp/tools.pkg" "$OMCTEST_WORK/pkginexp" >/dev/null 2>&1
# pkgbuild writes the attributes as id= then path=, so the assertion matches on
# path= alone rather than on a whole element it would have to spell exactly.
check "pkgbuild recorded the bundle" "1"                      "$(/usr/bin/grep -c 'path="./Applications/Demo.app"' "$OMCTEST_WORK/pkginexp/PackageInfo" | /usr/bin/tr -d ' ')"
check "and the flat one"         "1"                          "$(/usr/bin/grep -c 'path="./Library/Bees/Flat.bundle"' "$OMCTEST_WORK/pkginexp/PackageInfo" | /usr/bin/tr -d ' ')"
check "four entries, not the tree" "4"                        "$(count /COMPONENTS/0/PAYLOAD)"
check "the app bundle is one entry" "/Applications/Demo.app"  "$(payload_field 0 DESTINATION)"
# The load-bearing one. Flat.bundle keeps its Info.plist at the bundle root, so
# neither awk fallback pattern matches it - the ONLY way it collapses is through
# importpkg_bundle_roots reading PackageInfo. Neuter that reader and this check
# fails while every other one in the section stays green, which is exactly what
# the previous fixture could not do.
check "nothing from inside the flat bundle" "0"               "$(payload_sources_matching 'Flat.bundle/')"
check "the flat bundle is one entry" "/Library/Bees/Flat.bundle" "$(payload_field 1 DESTINATION)"
check "the binary came across"   "/usr/local/bin/tool"        "$(payload_field 2 DESTINATION)"
check "the plain file too"       "/usr/local/share/notes.txt" "$(payload_field 3 DESTINATION)"
check "and nothing from inside the bundle" "0"                "$(payload_sources_matching 'Contents/MacOS')"
# Modes and owners are read from the BOM, which is the authority even when the
# payload was unpacked.
check "executable mode"          "0755"                       "$(payload_field 2 MODE)"
check "plain file mode"          "0644"                       "$(payload_field 3 MODE)"
check "owner"                    "root"                       "$(payload_field 2 OWNER)"
check "group"                    "wheel"                      "$(payload_field 2 GROUP)"
# A package cannot carry its sources. They arrive as placeholders and the
# artifacts folder is deliberately left empty, so design 4.3 makes the build
# refuse rather than resolving them to previously installed copies.
check "source is a placeholder"  '${ARTIFACTS_DIR}/tool'      "$(payload_field 2 SOURCE)"
check "artifacts folder left empty" ""                        "$(model /PROJECT/ARTIFACTS_DIR)"
check "the log says so"          "1"                          "$(log_says 'placeholder')"
# The verify block describes the next build, so a Mach-O gets the assertions a
# dropped artifact gets - except ARCHITECTURES, which is read for real.
check "a Mach-O asserts hardened" "true"                      "$(model /COMPONENTS/0/PAYLOAD/2/VERIFY/HARDENED_RUNTIME)"
check "a plain file asserts nothing" "false"                  "$(model /COMPONENTS/0/PAYLOAD/3/VERIFY/HARDENED_RUNTIME)"
check "and no version flag is invented" ""                    "$(payload_field 2 VERIFY/VERSION_FLAG)"

section "136. an unsigned package is imported as unsigned"
# Faithful to what was read. Turning signing on with no identity would hand the
# user a document that fails its preconditions for a reason they did not choose.
check "signing off"              "false"                      "$(model /SIGNING/ENABLED)"
check "and no identity invented" ""                           "$(model /SIGNING/INSTALLER_IDENTITY)"

section "137. a component whose payload IS a bundle becomes one entry"
# The framework case. A component installing into
# /Library/Frameworks/Foo.framework has a BOM rooted inside the framework, so
# read literally every file in it becomes a payload entry describing one thing.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/FromFramework.pkgbld"
omc_run PackageBuilder.save.as
/bin/rm -rf "$OMCTEST_WORK/fwin"
/bin/mkdir -p "$OMCTEST_WORK/fwin/root/Versions/A/Resources" "$OMCTEST_WORK/fwin/comp"
/bin/cp /bin/echo "$OMCTEST_WORK/fwin/root/Versions/A/Foo"
printf '<plist/>\n' > "$OMCTEST_WORK/fwin/root/Versions/A/Resources/Info.plist"
printf 'r\n' > "$OMCTEST_WORK/fwin/root/Versions/A/Resources/data.txt"
/usr/bin/pkgbuild --root "$OMCTEST_WORK/fwin/root" --identifier com.example.pkg.foo \
    --version 1.0 --install-location /Library/Frameworks/Foo.framework \
    --ownership recommended "$OMCTEST_WORK/fwin/comp/foo.pkg" >/dev/null 2>&1
omc_dialog_answer choose_file "$OMCTEST_WORK/fwin/comp/foo.pkg"
omc_run PackageBuilder.import.pkg
check "one entry, not the contents" "1"                       "$(count /COMPONENTS/0/PAYLOAD)"
check "naming the bundle"        "/Library/Frameworks/Foo.framework" "$(payload_field 0 DESTINATION)"
# The install location becomes the bundle's parent, which is what makes the
# destination sit under it - the document a user would have written by dropping
# Foo.framework on the payload table.
check "install location is the parent" "/Library/Frameworks" "$(model /COMPONENTS/0/INSTALL_LOCATION)"
check "source names the bundle"  '${ARTIFACTS_DIR}/Foo.framework' "$(payload_field 0 SOURCE)"
# A component package has no Distribution, so there is no recorded auth and the
# default has to stand rather than being read from PackageInfo's always-root.
check "auth left at the default" "Root"                       "$(model /COMPONENTS/0/AUTH)"

section "138. a multi-component package imports the first and names the rest"
# Design section 14 decision 2: the document holds one component. The others are
# reported by identifier and install location rather than dropped quietly, and
# the FIRST is the Distribution's first pkg-ref, not the alphabetically first
# directory - a glob would pick the wrong one for any real installer.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/FromMulti.pkgbld"
omc_run PackageBuilder.save.as
make_import_pkg "$OMCTEST_WORK/multiin"
/bin/mkdir -p "$OMCTEST_WORK/multiin/root2/Library/Extras"
printf 'e\n' > "$OMCTEST_WORK/multiin/root2/Library/Extras/extra.txt"
/usr/bin/pkgbuild --root "$OMCTEST_WORK/multiin/root2" --identifier com.example.pkg.aaaextras \
    --version 4.2 --install-location / --ownership recommended \
    "$OMCTEST_WORK/multiin/comp/aaaextras.pkg" >/dev/null 2>&1
/bin/cat > "$OMCTEST_WORK/multiin/Distribution.xml" <<'DISTXML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<installer-gui-script minSpecVersion="2">
    <options hostArchitectures="arm64,x86_64" customize="never" require-scripts="false"/>
    <title>Multi</title>
    <choices-outline><line choice="c0"/><line choice="c1"/></choices-outline>
    <choice id="c0" title="Tools"><pkg-ref id="com.example.pkg.demo"/></choice>
    <choice id="c1" title="Extras"><pkg-ref id="com.example.pkg.aaaextras"/></choice>
    <pkg-ref id="com.example.pkg.demo" version="4.2" auth="Root">#tools.pkg</pkg-ref>
    <pkg-ref id="com.example.pkg.aaaextras" version="4.2" auth="Root">#aaaextras.pkg</pkg-ref>
</installer-gui-script>
DISTXML
/usr/bin/productbuild --distribution "$OMCTEST_WORK/multiin/Distribution.xml" \
    --package-path "$OMCTEST_WORK/multiin/comp" "$OMCTEST_WORK/multiin/out/Multi_4.2.pkg" >/dev/null 2>&1
omc_dialog_answer choose_file "$OMCTEST_WORK/multiin/out/Multi_4.2.pkg"
omc_run PackageBuilder.import.pkg
check "the Distribution's first, not the glob's" "com.example.pkg.demo" "$(model /COMPONENTS/0/IDENTIFIER)"
check "with its own payload"     "4"                          "$(count /COMPONENTS/0/PAYLOAD)"
check "the dropped one is named" "1"                          "$(log_says 'com.example.pkg.aaaextras')"
check "and counted"              "1"                          "$(log_says '1 further component')"

section "139. what cannot be read is refused, and changes nothing"
# Two refusals: a canceled panel and a file that is not a package at all. The
# second is what an old bundle-format .mpkg reaches, which pkgutil cannot expand.
pl set string "keepme" "$(model_file)" /PROJECT/NAME
omc_dialog_answer choose_file ""
omc_run PackageBuilder.import.pkg
check "a canceled panel changes nothing" "keepme"             "$(model /PROJECT/NAME)"
printf 'not a package\n' > "$OMCTEST_WORK/NotAPackage.pkg"
omc_dialog_answer choose_file "$OMCTEST_WORK/NotAPackage.pkg"
omc_run PackageBuilder.import.pkg
check "an unreadable package changes nothing" "keepme"        "$(model /PROJECT/NAME)"
check "and it is named as unexpandable" "1"                   "$(log_says 'could not be expanded')"
# The source package is the user's own file and is never written to.
check_exists "the package survives" "$OMCTEST_WORK/pkgin/out/Demo_4.2.pkg"

section "140. a payload too large to be a list of artifacts is refused on its own"
# PB_IMPORT_MAX_PAYLOAD. Everything else in the package is still worth having,
# so only the payload is refused and the log says why.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/FromBig.pkgbld"
omc_run PackageBuilder.save.as
/bin/rm -rf "$OMCTEST_WORK/bigin"
/bin/mkdir -p "$OMCTEST_WORK/bigin/root/usr/local/share/many" "$OMCTEST_WORK/bigin/comp"
big_index=0
while [ "$big_index" -lt 520 ]; do
    printf 'x\n' > "$OMCTEST_WORK/bigin/root/usr/local/share/many/f$big_index.txt"
    big_index=$((big_index + 1))
done
/usr/bin/pkgbuild --root "$OMCTEST_WORK/bigin/root" --identifier com.example.pkg.big \
    --version 1.0 --install-location / --ownership recommended \
    "$OMCTEST_WORK/bigin/comp/big.pkg" >/dev/null 2>&1
omc_dialog_answer choose_file "$OMCTEST_WORK/bigin/comp/big.pkg"
omc_run PackageBuilder.import.pkg
check "the payload was refused"  "0"                          "$(count /COMPONENTS/0/PAYLOAD)"
check "but the component was not" "com.example.pkg.big"       "$(model /COMPONENTS/0/IDENTIFIER)"
check "and the log says why"     "1"                          "$(log_says 'not a list of artifacts')"
# With no sources written there is nothing for an artifacts folder to point at,
# so the placeholder advice must not appear and send the user after a field
# that would change nothing.
check "no placeholder advice"    "0"                          "$(log_says 'placeholder')"

section "140b. an over-limit payload does not leave the old one behind"
# Found in review. The refusal branch skips importpkg_apply_payload, which is the
# only place the previous payload is cleared - so a document that had entries
# kept them while identifier, install location and signing all changed to
# describe the new package. That builds the OLD payload under the NEW identifier,
# which is the mirror of the .pkgproj importer's "one outcome an import should
# never produce silently".
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/Stale.pkgbld"
omc_run PackageBuilder.save.as
omc_dialog_answer choose_file "$OMCTEST_WORK/pkgin/out/Demo_4.2.pkg"
omc_run PackageBuilder.import.pkg
check "the first import populated it" "4"                     "$(count /COMPONENTS/0/PAYLOAD)"
omc_dialog_answer choose_file "$OMCTEST_WORK/bigin/comp/big.pkg"
omc_run PackageBuilder.import.pkg
check "the second import took the identifier" "com.example.pkg.big" "$(model /COMPONENTS/0/IDENTIFIER)"
check "and did not keep the old payload" "0"                  "$(count /COMPONENTS/0/PAYLOAD)"
check "and said the payload is now empty" "1"                 "$(log_says 'payload is now empty')"

section "140c. a payload path with a tab or a newline is refused, not invented"
# Found in review, and the sharpest bug in the feature. lsbom writes both
# characters raw and offers no escaping. A newline splits one BOM entry across
# two lines and the tail of that split is itself a well-formed five-field
# record; a tab shifts the numeric columns along. Read literally, two files
# became three payload entries - one of them MODE "", one OWNER "100644", and
# one destined for "/line.txt", a payload item installing at the filesystem
# root - with no warning at all.
#
# Two detectors, because neither covers the other: PackageInfo's numberOfFiles
# against the BOM line count catches the newline, and the awk shape gate catches
# the tab, which does not change the line count.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/Hostile.pkgbld"
omc_run PackageBuilder.save.as
/bin/rm -rf "$OMCTEST_WORK/hostilein"
/bin/mkdir -p "$OMCTEST_WORK/hostilein/root/usr/local/bin" "$OMCTEST_WORK/hostilein/comp"
printf 'x\n' > "$OMCTEST_WORK/hostilein/root/usr/local/bin/ok.txt"
printf 'x\n' > "$OMCTEST_WORK/hostilein/root/usr/local/bin/$(printf 'new\nline').txt"
/usr/bin/pkgbuild --root "$OMCTEST_WORK/hostilein/root" --identifier com.example.pkg.hostile \
    --version 1.0 --install-location / --ownership recommended \
    "$OMCTEST_WORK/hostilein/comp/nl.pkg" >/dev/null 2>&1
omc_dialog_answer choose_file "$OMCTEST_WORK/hostilein/comp/nl.pkg"
omc_run PackageBuilder.import.pkg
check "no entries were invented" "0"                          "$(count /COMPONENTS/0/PAYLOAD)"
check "the line break is named"  "1"                          "$(log_says 'contains a line break')"
# The specific fabrication this guards against: an entry installing at the root.
check "nothing lands at the root" "0"                         "$(payload_sources_matching '/line.txt')"
# The rest of the package is still worth having, and still lands.
check "the component still imported" "com.example.pkg.hostile" "$(model /COMPONENTS/0/IDENTIFIER)"

/bin/rm -rf "$OMCTEST_WORK/tabin"
/bin/mkdir -p "$OMCTEST_WORK/tabin/root/usr/local/bin" "$OMCTEST_WORK/tabin/comp"
printf 'x\n' > "$OMCTEST_WORK/tabin/root/usr/local/bin/fine.txt"
printf 'x\n' > "$OMCTEST_WORK/tabin/root/usr/local/bin/$(printf 'ta\tb').txt"
/usr/bin/pkgbuild --root "$OMCTEST_WORK/tabin/root" --identifier com.example.pkg.tabbed \
    --version 1.0 --install-location / --ownership recommended \
    "$OMCTEST_WORK/tabin/comp/tab.pkg" >/dev/null 2>&1
omc_dialog_answer choose_file "$OMCTEST_WORK/tabin/comp/tab.pkg"
omc_run PackageBuilder.import.pkg
check "a tab is refused too"     "0"                          "$(count /COMPONENTS/0/PAYLOAD)"
check "and named as a tab"       "1"                          "$(log_says 'contains a tab')"

section "140e. a component that installs nothing is not a failure"
# python.org ships two of these - Python_Install_Pip.pkg and
# Python_Shell_Profile_Updater.pkg - each a PackageInfo and a Scripts directory
# with no Bom and no numberOfFiles. Treating a missing Bom as fatal refused the
# whole import of any package whose FIRST component happened to be one, which
# is both a legitimate package and a legitimate thing to want imported.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/ScriptsOnly.pkgbld"
omc_run PackageBuilder.save.as
/bin/rm -rf "$OMCTEST_WORK/sconly"
/bin/mkdir -p "$OMCTEST_WORK/sconly/scripts" "$OMCTEST_WORK/sconly/comp"
printf '#!/bin/sh\nexit 0\n' > "$OMCTEST_WORK/sconly/scripts/postinstall"
/bin/chmod 755 "$OMCTEST_WORK/sconly/scripts/postinstall"
/usr/bin/pkgbuild --nopayload --identifier com.example.pkg.scriptsonly --version 1.0 \
    --scripts "$OMCTEST_WORK/sconly/scripts" "$OMCTEST_WORK/sconly/comp/sc.pkg" >/dev/null 2>&1
omc_dialog_answer choose_file "$OMCTEST_WORK/sconly/comp/sc.pkg"
omc_run PackageBuilder.import.pkg
check "the import succeeded"     "com.example.pkg.scriptsonly" "$(model /COMPONENTS/0/IDENTIFIER)"
check "with an empty payload"    "0"                          "$(count /COMPONENTS/0/PAYLOAD)"
check "and said it installs nothing" "1"                      "$(log_says 'installs no files')"
check "and named the scripts as not extracted" "1"            "$(log_says 'install scripts')"

section "140f. a component that collects no entries clears the old payload too"
# Found in the second review. Fix 2 closed the unreadable and over-limit routes,
# which share one clear loop, and left a third: a component that collects ZERO
# entries returned before the loop, so identifier, install location and signing
# all became the new package's while the PREVIOUS project's payload stayed. That
# is the same chimera document, reached by a third door - an empty root, or a
# payload that is only symlinks and AppleDouble companions.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/EmptyAfter.pkgbld"
omc_run PackageBuilder.save.as
omc_dialog_answer choose_file "$OMCTEST_WORK/pkgin/out/Demo_4.2.pkg"
omc_run PackageBuilder.import.pkg
check "the first import populated it" "4"                     "$(count /COMPONENTS/0/PAYLOAD)"
/bin/rm -rf "$OMCTEST_WORK/emptyin"
/bin/mkdir -p "$OMCTEST_WORK/emptyin/root" "$OMCTEST_WORK/emptyin/comp"
/usr/bin/pkgbuild --root "$OMCTEST_WORK/emptyin/root" --identifier com.example.pkg.empty \
    --version 1.0 --install-location / --ownership recommended \
    "$OMCTEST_WORK/emptyin/comp/empty.pkg" >/dev/null 2>&1
omc_dialog_answer choose_file "$OMCTEST_WORK/emptyin/comp/empty.pkg"
omc_run PackageBuilder.import.pkg
check "the identifier changed"   "com.example.pkg.empty"      "$(model /COMPONENTS/0/IDENTIFIER)"
check "and the payload went with it" "0"                      "$(count /COMPONENTS/0/PAYLOAD)"
check "and it said so"           "1"                          "$(log_says 'installs no files')"

section "140g. a crafted package cannot fabricate an entry at the root"
# Found in the second review. The shape gate alone rejects a stray fragment, but
# a FILENAME that itself looks like a BOM record - "decoy<TAB>100644<TAB>0<TAB>0
# <TAB>pad" followed by a newline - splits into lines that are all well formed,
# so one file yielded two payload rows and the second landed at "/". The count
# check caught it only until numberOfFiles was edited to match, which is a
# one-character change to a file inside the xar. lsbom roots every real path at
# "./" and a fabricated tail cannot, so that is what closes it.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/Crafted.pkgbld"
omc_run PackageBuilder.save.as
/bin/rm -rf "$OMCTEST_WORK/craftin"
/bin/mkdir -p "$OMCTEST_WORK/craftin/root/opt/x" "$OMCTEST_WORK/craftin/comp"
printf 'x\n' > "$OMCTEST_WORK/craftin/root/opt/x/$(printf 'decoy\t100644\t0\t0\tpad\nEVIL').txt"
/usr/bin/pkgbuild --root "$OMCTEST_WORK/craftin/root" --identifier com.example.pkg.craft \
    --version 1.0 --install-location / --ownership recommended \
    "$OMCTEST_WORK/craftin/comp/craft.pkg" >/dev/null 2>&1
# Forge numberOfFiles to match the line count, defeating the count detector, so
# the shape gate is the only thing left standing.
/bin/rm -rf "$OMCTEST_WORK/craftexp"
/usr/sbin/pkgutil --expand "$OMCTEST_WORK/craftin/comp/craft.pkg" "$OMCTEST_WORK/craftexp" >/dev/null 2>&1
craft_lines="$(/usr/bin/lsbom -s "$OMCTEST_WORK/craftexp/Bom" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
/usr/bin/sed -i '' "s/numberOfFiles=\"[0-9]*\"/numberOfFiles=\"$craft_lines\"/" "$OMCTEST_WORK/craftexp/PackageInfo"
/bin/rm -f "$OMCTEST_WORK/craftin/comp/forged.pkg"
/usr/sbin/pkgutil --flatten "$OMCTEST_WORK/craftexp" "$OMCTEST_WORK/craftin/comp/forged.pkg" >/dev/null 2>&1
omc_dialog_answer choose_file "$OMCTEST_WORK/craftin/comp/forged.pkg"
omc_run PackageBuilder.import.pkg
check "no entries were fabricated" "0"                        "$(count /COMPONENTS/0/PAYLOAD)"
check "nothing landed at the root" "0"                        "$(payload_sources_matching 'EVIL')"
check "and the shape gate named it" "1"                       "$(log_says 'contains a tab')"

section "140d. a whole-bundle component still reads its verify assertions"
# Found in review. For the whole-bundle branch the payload directory IS the
# bundle's contents, so joining the basename on gave "Payload/Foo.framework",
# which never exists - and the one artifact class most likely to be a signed,
# hardened, universal binary was the only one importing with nothing asserted.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/FrameworkVerify.pkgbld"
omc_run PackageBuilder.save.as
/bin/rm -rf "$OMCTEST_WORK/fwverify"
/bin/mkdir -p "$OMCTEST_WORK/fwverify/root/Versions/A/Resources" "$OMCTEST_WORK/fwverify/comp"
/bin/cp /bin/echo "$OMCTEST_WORK/fwverify/root/Versions/A/Bar"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.example.bar" \
    -c "Add :CFBundleExecutable string Bar" \
    "$OMCTEST_WORK/fwverify/root/Versions/A/Resources/Info.plist" >/dev/null 2>&1
/bin/ln -s A "$OMCTEST_WORK/fwverify/root/Versions/Current"
/bin/ln -s Versions/Current/Bar "$OMCTEST_WORK/fwverify/root/Bar"
/usr/bin/pkgbuild --root "$OMCTEST_WORK/fwverify/root" --identifier com.example.pkg.bar \
    --version 1.0 --install-location /Library/Frameworks/Bar.framework \
    --ownership recommended "$OMCTEST_WORK/fwverify/comp/bar.pkg" >/dev/null 2>&1
omc_dialog_answer choose_file "$OMCTEST_WORK/fwverify/comp/bar.pkg"
omc_run PackageBuilder.import.pkg
check "one entry for the framework" "1"                       "$(count /COMPONENTS/0/PAYLOAD)"
# /bin/echo is a real universal Mach-O, so the bundle resolves to an executable
# and the entry must assert what a dropped bundle asserts.
check "the bundle is seen as executable" "true"               "$(model /COMPONENTS/0/PAYLOAD/0/VERIFY/HARDENED_RUNTIME)"
check "and its architectures were read" "1"                   "$([ "$(count /COMPONENTS/0/PAYLOAD/0/VERIFY/ARCHITECTURES)" -gt 0 ] && echo 1 || echo 0)"

section "141. the CLI imports a package too"
# Same engine, console presentation. The CLI is the path an agent takes.
pbcli import-pkg "$OMCTEST_WORK/pkgin/out/Demo_4.2.pkg" "$OMCTEST_WORK/CliFromPkg.pkgbld" --force \
    > "$OMCTEST_WORK/cliimport.txt" 2>&1
check "it wrote a document"      "1"                          "$([ -f "$OMCTEST_WORK/CliFromPkg.pkgbld" ] && echo 1 || echo 0)"
check "with the identifier"      "com.example.pkg.demo"       "$(field_of "$OMCTEST_WORK/CliFromPkg.pkgbld" /COMPONENTS/0/IDENTIFIER)"
check "and the payload"          "4"                          "$(pl get count "$OMCTEST_WORK/CliFromPkg.pkgbld" /COMPONENTS/0/PAYLOAD)"
# The document is well-formed even though it cannot be built yet: design 4.3
# makes an unset artifacts folder a precondition failure, not a format error.
pbcli validate "$OMCTEST_WORK/CliFromPkg.pkgbld" > "$OMCTEST_WORK/clivalidate.txt" 2>&1
check "no format errors"         "1"                          "$(/usr/bin/grep -c '0 error(s)' "$OMCTEST_WORK/clivalidate.txt" | /usr/bin/tr -d ' ')"
check "and says the artifacts folder is unset" "1"            "$(/usr/bin/grep -c 'no artifacts folder is set' "$OMCTEST_WORK/clivalidate.txt" | /usr/bin/tr -d ' ' | /usr/bin/awk '{print ($1 > 0) ? 1 : 0}')"
# The one warning is design 8.1's, and it is the right one to get: this fixture
# was built by pkgbuild alone, so it really does say overwrite-permissions="true"
# and the import carried that across rather than substituting the safe default.
# An import that quietly "fixed" it would describe a package that was never
# built, and this check is what would catch that.
check "the safety warning survived the import" "1"            "$(/usr/bin/grep -c 'OVERWRITE_PERMISSIONS is true' "$OMCTEST_WORK/clivalidate.txt" | /usr/bin/tr -d ' ')"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids"        ""                           "$(ui_unknown_writes)"

omctest_end
