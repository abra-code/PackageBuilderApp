#!/bin/sh
# Tests/10-document.test.sh - the document state machine.
#
# Ported from Private/harness.sh sections 1 to 17. What the port changes is the
# scaffolding, not the assertions: omctest supplies the scratch tree, the
# interposition directory, the alert stub and the check vocabulary, and this file
# keeps every expected value the proof of concept had.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.packagebuilder.sh"

sample="$(fixture_copy Sample.pkgbuilderproj)"

section "1. open a document"
reset_state
omc_object "$sample"
omc_run PackageBuilder.main.init
check "identifier loaded"        "com.abracode.pkg.replay"   "$(model /COMPONENTS/0/IDENTIFIER)"
check "version loaded"           "2.2"                       "$(model /PROJECT/VERSION)"
check "payload count"            "2"                         "$(count /COMPONENTS/0/PAYLOAD)"
check "doc_path recorded"        "$sample"                   "$(doc_path)"
check "clean after open"         "0"                         "$(dirty)"
check "hash recorded"            "$(hash_of "$sample")"      "$(/bin/cat "$(state_dir)/doc_hash.txt")"
# New in the port: the proof of concept could not see what init pushed toward the
# window, because its omc_dialog_control calls went nowhere.
check "identifier pushed to the field" "com.abracode.pkg.replay" "$(ui_value $IDENTIFIER_ID)"
check "the payload table was fed"      "2"                       "$(ui_row_count $PAYLOAD_TABLE_ID)"
check "no writes to undeclared ids"    ""                        "$(ui_unknown_writes)"

section "2. edit a text field"
omc_fire PackageBuilder.field.changed $IDENTIFIER_ID "com.example.pkg.new"
check "identifier written"       "com.example.pkg.new"       "$(model /COMPONENTS/0/IDENTIFIER)"
check "document is dirty"        "1"                         "$(dirty)"

section "3. re-sending the same value is not an edit"
printf '0' > "$(state_dir)/dirty.txt"
omc_fire PackageBuilder.field.changed $IDENTIFIER_ID "com.example.pkg.new"
check "still clean"              "0"                         "$(dirty)"

section "4. writes during load are ignored"
# The flag carries the epoch second the push began, so that a flag left behind by
# a handler that died expires instead of swallowing every later edit.
pb_set loading "$(/bin/date '+%s')"
omc_fire PackageBuilder.field.changed $IDENTIFIER_ID "SHOULD.NOT.STICK"
check "loading guard held"       "com.example.pkg.new"       "$(model /COMPONENTS/0/IDENTIFIER)"
pb_set loading ""

section "5. boolean control"
omc_fire PackageBuilder.field.changed $OVERWRITE_ID "1"
check "overwrite-permissions"    "true"                      "$(model /COMPONENTS/0/OVERWRITE_PERMISSIONS)"
check "stored as a bool"         "bool"                      "$(pl get type "$(model_file)" /COMPONENTS/0/OVERWRITE_PERMISSIONS)"

section "6. picker delivers its explicit tag"
omc_fire PackageBuilder.field.changed $AUTH_ID "User"
check "auth written as tag"      "User"                      "$(model /COMPONENTS/0/AUTH)"

section "7. the two architecture toggles write one array"
omc_control $ARCH_ARM64_ID "1"
omc_fire PackageBuilder.field.changed $ARCH_X86_64_ID "0"
check "one architecture left"    "1"                         "$(count /DISTRIBUTION/HOST_ARCHITECTURES)"
check "it is arm64"              "arm64"                     "$(model /DISTRIBUTION/HOST_ARCHITECTURES/0)"
omc_control $ARCH_ARM64_ID "1"
omc_fire PackageBuilder.field.changed $ARCH_X86_64_ID "1"
check "both restored, in order"  "arm64 x86_64"              "$(model /DISTRIBUTION/HOST_ARCHITECTURES/0) $(model /DISTRIBUTION/HOST_ARCHITECTURES/1)"

section "8. save to the document path"
omc_run PackageBuilder.save
check "clean after save"         "0"                         "$(dirty)"
check "the edit reached disk"    "com.example.pkg.new"       "$(field_of "$sample" /COMPONENTS/0/IDENTIFIER)"
check "hash follows the save"    "$(hash_of "$sample")"      "$(/bin/cat "$(state_dir)/doc_hash.txt")"
check "no temp file left behind" ""                          "$(/bin/ls -a "$OMCTEST_WORK" | /usr/bin/grep pbsaving)"

section "9. Save As adopts the new path"
omc_dialog_answer save_as "$OMCTEST_WORK/SavedAs.pkgbuilderproj"
omc_run PackageBuilder.save.as
check "doc_path moved"           "$OMCTEST_WORK/SavedAs.pkgbuilderproj" "$(doc_path)"
check_exists "new file exists"   "$OMCTEST_WORK/SavedAs.pkgbuilderproj"
check "original left alone"      "com.example.pkg.new"       "$(field_of "$sample" /COMPONENTS/0/IDENTIFIER)"

section "10. Save As with no extension gets one"
omc_dialog_answer save_as "$OMCTEST_WORK/NoExtension"
omc_run PackageBuilder.save.as
check "extension appended"       "$OMCTEST_WORK/NoExtension.pkgbuilderproj" "$(doc_path)"

section "11. a canceled Save As changes nothing"
before="$(doc_path)"
omc_dialog_answer save_as ""
omc_run PackageBuilder.save.as
check "doc_path unchanged"       "$before"                   "$(doc_path)"

section "12. a path with spaces and quotes survives"
awkward="$OMCTEST_WORK/a project 'quoted' name.pkgbuilderproj"
omc_dialog_answer save_as "$awkward"
omc_run PackageBuilder.save.as
check_exists "awkward path saved" "$awkward"
check "and adopted"              "$awkward"                  "$(doc_path)"

section "13. a foreign file is refused"
reset_state
printf '{"hello":"world"}\n' > "$OMCTEST_WORK/Foreign.pkgbuilderproj"
omc_object "$OMCTEST_WORK/Foreign.pkgbuilderproj"
omc_run PackageBuilder.main.init
# Both of these were assertions that the model is EMPTY, which is also what
# "no model was built at all" looks like: deleting the fall-back to New left the
# whole section green. They name something the template actually sets now.
check "fell back to New"         "/"                         "$(model /COMPONENTS/0/INSTALL_LOCATION)"
check "model is the template"    "true"                      "$(model /SIGNING/ENABLED)"
check "no path was adopted"      ""                          "$(doc_path)"
check "the foreign key stayed out" ""                        "$(model /hello)"
check_absent "no leftover staging file" "$(state_dir)/incoming.json"

section "14. New document"
reset_state
omc_object ""
omc_run PackageBuilder.main.init
check "install location default" "/"                         "$(model /COMPONENTS/0/INSTALL_LOCATION)"
check "signing on by default"    "true"                      "$(model /SIGNING/ENABLED)"
check "no payload"               "0"                         "$(count /COMPONENTS/0/PAYLOAD)"
check "clean"                    "0"                         "$(dirty)"

section "15. a clean close removes the scratch directory"
omc_run PackageBuilder.window.close
check_absent "state dir gone"    "$(state_dir)"

section "16. external-change detection"
reset_state
watched="$(work_copy Sample.pkgbuilderproj Watched.pkgbuilderproj)"
omc_object "$watched"
omc_run PackageBuilder.main.init
omc_run PackageBuilder.window.activated
check "unchanged file, no reload" "com.abracode.pkg.replay"  "$(model /COMPONENTS/0/IDENTIFIER)"
/bin/rm -f "$OMCTEST_WORK/edit.json"
/bin/cp "$watched" "$OMCTEST_WORK/edit.json"
pl set string "com.changed.externally" "$OMCTEST_WORK/edit.json" /COMPONENTS/0/IDENTIFIER >/dev/null 2>&1
/bin/cp "$OMCTEST_WORK/edit.json" "$watched"
omc_run PackageBuilder.window.activated
check "reloaded from disk"       "com.changed.externally"    "$(model /COMPONENTS/0/IDENTIFIER)"
check "clean after reload"       "0"                         "$(dirty)"
# New in the port: a reload has to reach the window too, not just the model.
check "and the field was refreshed" "com.changed.externally" "$(ui_value $IDENTIFIER_ID)"

section "17. a deleted document does not reload or crash"
/bin/rm -f "$watched"
omc_run PackageBuilder.window.activated
check "model untouched"          "com.changed.externally"    "$(model /COMPONENTS/0/IDENTIFIER)"
check "doc_path kept"            "$watched"                  "$(doc_path)"

section "cumulative: no handler wrote to a view id the window does not declare"
# unknown_ids.log accumulates across the whole file and nothing resets it, so
# one assertion here covers every section above. The per-section copy in the
# document file covers only the section it sits in - a bogus write from any
# later handler was invisible until this was added.
check "no undeclared ids"        ""                          "$(ui_unknown_writes)"

omctest_end
