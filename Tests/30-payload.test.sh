#!/bin/sh
# Tests/30-payload.test.sh - the payload tab.
#
# Ported from Private/harness.sh sections 32 to 50. Its fixtures are synthesized
# by make_artifacts rather than committed, which is the harness's preferred
# pattern: no binaries in the repo, and the block that builds them documents
# exactly which properties matter.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.packagebuilder.sh"

artifacts="$(make_artifacts)"

section "32. the artifacts folder is stored relative to the document"
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/Payload.pkgbuilderproj"
omc_run PackageBuilder.save.as
omc_dialog_answer choose_folder "$artifacts"
omc_run PackageBuilder.choose.artifacts
# The document lives in the work dir and the folder is work/artifacts, so the
# stored value has to be the bare relative name. This is the check that would
# fail if the /var vs /private/var canonicalization in relative_to were dropped.
check "stored relative"          "artifacts"                 "$(model /PROJECT/ARTIFACTS_DIR)"
check "document is dirty"        "1"                         "$(dirty)"

section "33. a drop adds one entry per item, with guessed destinations"
omc_drop "$artifacts/Widget.app" "$artifacts/mytool" "$artifacts/readme.txt"
omc_run PackageBuilder.payload.drop
check "three entries"            "3"                         "$(count /COMPONENTS/0/PAYLOAD)"
check "bundle source tokenized"  '${ARTIFACTS_DIR}/Widget.app' "$(payload_field 0 SOURCE)"
check "bundle destination"       "/Applications/Widget.app"  "$(payload_field 0 DESTINATION)"
check "bundle mode"              "0755"                      "$(payload_field 0 MODE)"
check "owner and group"          "root wheel"                "$(payload_field 0 OWNER) $(payload_field 0 GROUP)"
check "tool destination"         "/usr/local/bin/mytool"     "$(payload_field 1 DESTINATION)"
check "tool mode"                "0755"                      "$(payload_field 1 MODE)"
# "anything else" takes the directory of the previously added entry (design 5.3).
check "data file follows prev"   "/usr/local/bin/readme.txt" "$(payload_field 2 DESTINATION)"
check "data file mode"           "0644"                      "$(payload_field 2 MODE)"
check "last row selected"        "2"                         "$(selected_index)"
# New in the port: the drop has to reach the table, not just the model.
check "the table shows three rows" "3"                       "$(ui_row_count $PAYLOAD_TABLE_ID)"

section "34. the verify toggles start on for a Mach-O and off otherwise"
check "bundle is universal"      "2"                         "$(count /COMPONENTS/0/PAYLOAD/0/VERIFY/ARCHITECTURES)"
check "bundle signed-by set"     "Developer ID Application"  "$(payload_field 0 VERIFY/SIGNED_BY)"
check "bundle hardened"          "true"                      "$(payload_field 0 VERIFY/HARDENED_RUNTIME)"
check "bundle timestamped"       "true"                      "$(payload_field 0 VERIFY/SECURE_TIMESTAMP)"
check "data file not universal"  "0"                         "$(count /COMPONENTS/0/PAYLOAD/2/VERIFY/ARCHITECTURES)"
check "data file no signed-by"   ""                          "$(payload_field 2 VERIFY/SIGNED_BY)"
check "data file not hardened"   "false"                     "$(payload_field 2 VERIFY/HARDENED_RUNTIME)"

section "35. project fields fill themselves from the first artifact (4.5)"
check "name from basename"       "Widget"                    "$(model /PROJECT/NAME)"
check "version from Info.plist"  "3.4.1"                     "$(model /PROJECT/VERSION)"
check "min OS from Info.plist"   "13.0"                      "$(model /PROJECT/MIN_OS_VERSION)"

section "36. a second drop does not overwrite fields the user already has"
omc_drop "$artifacts/mytool"
omc_run PackageBuilder.payload.drop
check "four entries"             "4"                         "$(count /COMPONENTS/0/PAYLOAD)"
check "name untouched"           "Widget"                    "$(model /PROJECT/NAME)"
check "version untouched"        "3.4.1"                     "$(model /PROJECT/VERSION)"

section "37. selecting a row reads the hidden index column"
select_payload_row 1
check "selection recorded"       "1"                         "$(selected_index)"
# A stale index from a table that outlived its rows must not address an entry.
# Both negative probes run from a VALID selection, never from an already-cleared
# one: with the clear first, "the index is now empty" is the state the section
# started in, and a handler that silently ignores 99 - leaving a real entry
# selected, so the inspector edits the wrong row - passes anyway.
select_payload_row 99
check "out-of-range refused"     ""                          "$(selected_index)"
select_payload_row 1
select_payload_row ""
check "empty column clears it"   ""                          "$(selected_index)"

section "38. inspector edits land on the selected entry"
select_payload_row 1
omc_fire PackageBuilder.field.changed $DESTINATION_ID "/opt/local/bin/mytool"
check "destination written"      "/opt/local/bin/mytool"     "$(payload_field 1 DESTINATION)"
check "entry 0 untouched"        "/Applications/Widget.app"  "$(payload_field 0 DESTINATION)"
omc_fire PackageBuilder.field.changed $MODE_ID "0700"
check "mode written"             "0700"                      "$(payload_field 1 MODE)"
omc_fire PackageBuilder.field.changed $VERSION_FLAG_ID "--version"
check "version flag written"     "--version"                 "$(payload_field 1 VERIFY/VERSION_FLAG)"

section "39. the verify toggles are two views of one field each"
omc_fire PackageBuilder.field.changed $VERIFY_SIGNED_ID "false"
check "signed-by cleared"        ""                          "$(payload_field 1 VERIFY/SIGNED_BY)"
pl set string "Developer ID Application: Someone (ABC123)" "$(model_file)" /COMPONENTS/0/PAYLOAD/1/VERIFY/SIGNED_BY >/dev/null 2>&1
omc_fire PackageBuilder.field.changed $VERIFY_SIGNED_ID "true"
# Turning the checkbox back on must not replace an identity the project pinned.
check "pinned identity kept"     "Developer ID Application: Someone (ABC123)" "$(payload_field 1 VERIFY/SIGNED_BY)"
omc_fire PackageBuilder.field.changed $VERIFY_UNIVERSAL_ID "false"
check "architectures emptied"    "0"                         "$(count /COMPONENTS/0/PAYLOAD/1/VERIFY/ARCHITECTURES)"
omc_fire PackageBuilder.field.changed $VERIFY_UNIVERSAL_ID "true"
check "both restored, in order"  "x86_64 arm64"              "$(model /COMPONENTS/0/PAYLOAD/1/VERIFY/ARCHITECTURES/0) $(model /COMPONENTS/0/PAYLOAD/1/VERIFY/ARCHITECTURES/1)"

section "40. an inspector edit with no selection is discarded"
select_payload_row ""
printf '0' > "$(state_dir)/dirty.txt"
omc_fire PackageBuilder.field.changed $DESTINATION_ID "/nowhere"
check "nothing written"          "/opt/local/bin/mytool"     "$(payload_field 1 DESTINATION)"
check "still clean"              "0"                         "$(dirty)"

section "41. reordering moves the entry and follows it with the selection"
select_payload_row 1
omc_fire PackageBuilder.payload.move $PAYLOAD_UP_ID
check "moved up"                 "/opt/local/bin/mytool"     "$(payload_field 0 DESTINATION)"
check "displaced entry moved"    "/Applications/Widget.app"  "$(payload_field 1 DESTINATION)"
check "verify moved with it"     "Developer ID Application: Someone (ABC123)" "$(payload_field 0 VERIFY/SIGNED_BY)"
check "selection followed"       "0"                         "$(selected_index)"
omc_fire PackageBuilder.payload.move $PAYLOAD_UP_ID
check "already first, no move"   "/opt/local/bin/mytool"     "$(payload_field 0 DESTINATION)"
omc_fire PackageBuilder.payload.move $PAYLOAD_DOWN_ID
check "moved back down"          "/Applications/Widget.app"  "$(payload_field 0 DESTINATION)"
check "selection followed again" "1"                         "$(selected_index)"

section "42. removing an entry keeps the selection on the next one"
select_payload_row 0
omc_run PackageBuilder.payload.remove
check "three left"               "3"                         "$(count /COMPONENTS/0/PAYLOAD)"
check "next entry took the slot" "/opt/local/bin/mytool"     "$(payload_field 0 DESTINATION)"
check "selection stayed at 0"    "0"                         "$(selected_index)"
# Removing the last entry has to fall back to the new last, not off the end.
select_payload_row 2
omc_run PackageBuilder.payload.remove
check "two left"                 "2"                         "$(count /COMPONENTS/0/PAYLOAD)"
check "selection clamped"        "1"                         "$(selected_index)"

section "43. the destination presets keep the item name"
omc_fire PackageBuilder.payload.destination.preset $PRESET_APPLICATIONS_ID
check "preset applied"           "/Applications/readme.txt"  "$(payload_field 1 DESTINATION)"
# The ${NAME} preset expands against PROJECT.NAME, and the source's own token
# must not survive into a destination.
omc_fire PackageBuilder.payload.destination.preset $PRESET_APP_SUPPORT_ID
check "NAME token expanded"      "/Library/Application Support/Widget/readme.txt" "$(payload_field 1 DESTINATION)"

section "44. Browse repoints a source without moving its destination"
omc_dialog_answer choose_object "$artifacts/Widget.app"
omc_run PackageBuilder.payload.browse
check "source repointed"         '${ARTIFACTS_DIR}/Widget.app' "$(payload_field 1 SOURCE)"
check "destination left alone"   "/Library/Application Support/Widget/readme.txt" "$(payload_field 1 DESTINATION)"

section "45. Read from artifact overwrites the version on demand"
pl set string "0.0" "$(model_file)" /PROJECT/VERSION >/dev/null 2>&1
omc_run PackageBuilder.read.version
check "version re-read"          "3.4.1"                     "$(model /PROJECT/VERSION)"
pl set string "1.0" "$(model_file)" /PROJECT/MIN_OS_VERSION >/dev/null 2>&1
omc_run PackageBuilder.read.minos
check "min OS re-read"           "13.0"                      "$(model /PROJECT/MIN_OS_VERSION)"

section "46. a bare tool answers only when it has a version flag"
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer save_as "$OMCTEST_WORK/Tool.pkgbuilderproj"
omc_run PackageBuilder.save.as
omc_drop "$artifacts/mytool"
omc_run PackageBuilder.payload.drop
check "no version guessed"       ""                          "$(model /PROJECT/VERSION)"
# /bin/echo prints its arguments, so "--version" comes straight back and the
# reader has to find no version-looking token in it rather than accept the flag.
omc_run PackageBuilder.read.version
check "still no version"         ""                          "$(model /PROJECT/VERSION)"

section "47. a source outside both folders is stored absolute"
omc_drop "/bin/echo"
omc_run PackageBuilder.payload.drop
check "absolute source kept"     "/bin/echo"                 "$(payload_field 1 SOURCE)"
check "guessed for a tool"       "/usr/local/bin/echo"       "$(payload_field 1 DESTINATION)"

section "48. an unreadable drop changes nothing"
before="$(count /COMPONENTS/0/PAYLOAD)"
omc_drop "$artifacts/does-not-exist"
omc_run PackageBuilder.payload.drop
check "count unchanged"          "$before"                   "$(count /COMPONENTS/0/PAYLOAD)"
omc_trigger $PAYLOAD_TABLE_ID "" "not json at all"
omc_run PackageBuilder.payload.drop
check "garbage context ignored"  "$before"                   "$(count /COMPONENTS/0/PAYLOAD)"
check_absent "no staging file left" "$(state_dir)/drop.json"

section "49. a hand-written entry is normalized on load"
reset_state
printf '{"FORMAT_VERSION":1,"COMPONENTS":[{"PAYLOAD":[{"SOURCE":"a","DESTINATION":"/usr/local/bin/a"}]}]}\n' \
    > "$OMCTEST_WORK/Terse.pkgbuilderproj"
omc_object "$OMCTEST_WORK/Terse.pkgbuilderproj"
omc_run PackageBuilder.main.init
check "owner defaulted"          "root"                      "$(payload_field 0 OWNER)"
check "mode defaulted"           "0755"                      "$(payload_field 0 MODE)"
check "source preserved"         "a"                         "$(payload_field 0 SOURCE)"
check "first row selected"       "0"                         "$(selected_index)"
# The entry had no VERIFY dict, so a toggle write has to create one rather than
# fail the way plister "set" does on a missing parent (design 12.3).
omc_fire PackageBuilder.field.changed $VERIFY_HARDENED_ID "true"
check "VERIFY created on write"  "true"                      "$(payload_field 0 VERIFY/HARDENED_RUNTIME)"
check "and it is dirty"          "1"                         "$(dirty)"

section "50. token expansion is not sed (M: 4.4)"
reset_state
omc_object ""
omc_run PackageBuilder.main.init
pl set string 'v&v' "$(model_file)" /PROJECT/VERSION >/dev/null 2>&1
pl set string 'a/b' "$(model_file)" /PROJECT/NAME >/dev/null 2>&1
check "ampersand survives"       "pre-v&v-post"              "$(pb_call expand_tokens 'pre-${VERSION}-post')"
check "slash survives"           "x/a/b/y"                   "$(pb_call expand_tokens 'x/${NAME}/y')"
check "unset token is empty"     "//"                        "$(pb_call expand_tokens '/${ARTIFACTS_DIR}/')"

section "cumulative: no handler wrote to a view id the window does not declare"
# unknown_ids.log accumulates across the whole file and nothing resets it, so
# one assertion here covers every section above. The per-section copy in the
# document file covers only the section it sits in - a bogus write from any
# later handler was invisible until this was added.
check "no undeclared ids"        ""                          "$(ui_unknown_writes)"

omctest_end
