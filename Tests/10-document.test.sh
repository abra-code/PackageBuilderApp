#!/bin/sh
# Tests/10-document.test.sh - the document state machine.
#
# Ported from Private/harness.sh sections 1 to 17. What the port changes is the
# scaffolding, not the assertions: omctest supplies the scratch tree, the
# interposition directory, the alert stub and the check vocabulary, and this file
# keeps every expected value the proof of concept had.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.packagebuilder.sh"

sample="$(fixture_copy Sample.pkgbld)"

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
omc_dialog_answer save_as "$OMCTEST_WORK/SavedAs.pkgbld"
omc_run PackageBuilder.save.as
check "doc_path moved"           "$OMCTEST_WORK/SavedAs.pkgbld" "$(doc_path)"
check_exists "new file exists"   "$OMCTEST_WORK/SavedAs.pkgbld"
check "original left alone"      "com.example.pkg.new"       "$(field_of "$sample" /COMPONENTS/0/IDENTIFIER)"

section "10. Save As with no extension gets one"
omc_dialog_answer save_as "$OMCTEST_WORK/NoExtension"
omc_run PackageBuilder.save.as
check "extension appended"       "$OMCTEST_WORK/NoExtension.pkgbld" "$(doc_path)"

section "10b. an extension the user spelled in caps is left alone"
# LaunchServices matches the extension tag case-insensitively, so Shouty.PKGBLD
# opens as one of these documents. Appending to it would save to a second file
# and leave the one the user opened stale.
omc_dialog_answer save_as "$OMCTEST_WORK/Shouty.PKGBLD"
omc_run PackageBuilder.save.as
check "no second extension"      "$OMCTEST_WORK/Shouty.PKGBLD" "$(doc_path)"
check_exists "and that is the file" "$OMCTEST_WORK/Shouty.PKGBLD"
omc_dialog_answer save_as "$OMCTEST_WORK/Mixed.PkgBld"
omc_run PackageBuilder.save.as
check "mixed case too"           "$OMCTEST_WORK/Mixed.PkgBld" "$(doc_path)"

section "11. a canceled Save As changes nothing"
before="$(doc_path)"
omc_dialog_answer save_as ""
omc_run PackageBuilder.save.as
check "doc_path unchanged"       "$before"                   "$(doc_path)"

section "12. a path with spaces and quotes survives"
awkward="$OMCTEST_WORK/a project 'quoted' name.pkgbld"
omc_dialog_answer save_as "$awkward"
omc_run PackageBuilder.save.as
check_exists "awkward path saved" "$awkward"
check "and adopted"              "$awkward"                  "$(doc_path)"

section "13. a foreign file is refused"
reset_state
printf '{"hello":"world"}\n' > "$OMCTEST_WORK/Foreign.pkgbld"
omc_object "$OMCTEST_WORK/Foreign.pkgbld"
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
watched="$(work_copy Sample.pkgbld Watched.pkgbld)"
omc_object "$watched"
omc_run PackageBuilder.main.init
omc_run PackageBuilder.window.activated
check "unchanged file, no reload" "com.abracode.pkg.replay"  "$(model /COMPONENTS/0/IDENTIFIER)"
pl set string "com.changed.externally" "$watched" /COMPONENTS/0/IDENTIFIER >/dev/null 2>&1
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

section "18. a fresh profile has no preferences file, and a new project does not create one"
# The defaults are READ on every new document, and prefs_get must not bring the
# file into being on the way past - only prefs_set does that, through
# prefs_ensure. A settings file that appears merely because the app was opened
# is how a "clean profile" test stops meaning anything.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
check_absent "no prefs file yet" "$(prefs_path)"
check "and no output folder"     ""                          "$(model /PROJECT/OUTPUT_DIR)"
check "still clean"              "0"                         "$(dirty)"

section "19. choosing an output folder is remembered"
/bin/mkdir -p "$OMCTEST_WORK/dist-out"
omc_dialog_answer choose_folder "$OMCTEST_WORK/dist-out"
omc_run PackageBuilder.choose.output
out_dir="$(real_path "$OMCTEST_WORK/dist-out")"
check "the document has it"      "$out_dir"                  "$(model /PROJECT/OUTPUT_DIR)"
check_exists "the prefs file now exists" "$(prefs_path)"
check "and it was remembered"    "$out_dir"                  "$(pref default_output_dir)"

section "20. the next new project starts in the remembered folder"
reset_state
omc_object ""
omc_run PackageBuilder.main.init
check "seeded from preferences"  "$out_dir"                  "$(model /PROJECT/OUTPUT_DIR)"
# Seeding is not an edit. A window that asks to be saved before the user has
# typed anything is a nuisance, and there is nothing to lose by discarding it:
# the next new document reads the same preference again.
check "and the document is clean" "0"                        "$(dirty)"
check "the field shows it too"   "$out_dir"                  "$(ui_value $OUTPUT_DIR_ID)"

section "21. a remembered folder that has been deleted is not used"
/bin/rm -rf "$OMCTEST_WORK/dist-out"
reset_state
omc_object ""
omc_run PackageBuilder.main.init
# Refused rather than seeded: a path that is not there fails the build's output
# precondition, and doing that to a user over a choice they made weeks ago and
# did not repeat is worse than starting empty.
check "left empty"               ""                          "$(model /PROJECT/OUTPUT_DIR)"
check "the preference is kept"   "$out_dir"                  "$(pref default_output_dir)"

section "22. an opened document is never touched by the defaults"
# The defaults belong to File > New alone. A project carries its own choices,
# and seeding one on open would edit it just by looking at it - and, worse,
# would do so silently on a machine whose habits differ from the author's.
/bin/mkdir -p "$OMCTEST_WORK/dist-out2"
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_dialog_answer choose_folder "$OMCTEST_WORK/dist-out2"
omc_run PackageBuilder.choose.output
check "remembered again"         "$(real_path "$OMCTEST_WORK/dist-out2")" "$(pref default_output_dir)"
reset_state
sample="$(work_copy Sample.pkgbld Untouched.pkgbld)"
omc_object "$sample"
omc_run PackageBuilder.main.init
check "the document's own value" "../replay-Distributions"   "$(model /PROJECT/OUTPUT_DIR)"
check "and it is clean"          "0"                         "$(dirty)"
# The check above cannot fail on its own, and saying so is the point of this
# block. apply_new_document_defaults only writes into a field that is EMPTY, and
# Sample.pkgbld names an output folder - so it would pass even if the defaults
# ran on every open. The document that proves the claim is one with the field
# empty: if seeding leaked into the open path, THIS is where it would show.
# Found in review, 2026-08-23.
reset_state
blank="$(work_copy Sample.pkgbld NoOutput.pkgbld)"
pl set string "" "$blank" /PROJECT/OUTPUT_DIR >/dev/null 2>&1
omc_object "$blank"
omc_run PackageBuilder.main.init
check "an empty field stays empty" ""                        "$(model /PROJECT/OUTPUT_DIR)"
check "still clean"              "0"                         "$(dirty)"
# And the preference really was set at the time, so the check above is not
# passing because there was nothing to seed with.
check "the preference was live"  "$(real_path "$OMCTEST_WORK/dist-out2")" "$(pref default_output_dir)"

section "23. a remembered identity is used only when this keychain has it"
reset_state
omc_object ""
omc_run PackageBuilder.main.init
pb_call prefs_set default_installer_identity "Developer ID Installer: Nobody At All (ZZZZZZZZZZ)"
reset_state
omc_object ""
omc_run PackageBuilder.main.init
# The stale half, which needs no certificate to prove and is the half that
# matters: seeding an identity this machine cannot use produces a project that
# fails its signing precondition for a reason the user never chose here.
check "a stranger is refused"    ""                          "$(model /SIGNING/INSTALLER_IDENTITY)"
# Proof that the check above means something. Under the suite's isolated HOME
# list_installer_identities returns nothing, so "the identity was not seeded"
# would also be true if apply_new_document_defaults had never run - or if its
# grep were broken. The output folder is seeded by the same call from the same
# still-live preference, so this says the function did execute and reached its
# second branch. Found in review, 2026-08-23.
check "but the defaults did run" "$(real_path "$OMCTEST_WORK/dist-out2")" "$(model /PROJECT/OUTPUT_DIR)"
section "24. picking an identity remembers it; the app writing the picker does not"
# Neither half needs a certificate. remember_default_identity never consults the
# keychain - only apply_new_document_defaults does - so both are testable on any
# machine, which the first version of these tests missed by putting them inside
# the certificate skip. Found in review, 2026-08-23.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
pb_call prefs_set default_installer_identity ""
omc_fire PackageBuilder.field.changed $IDENTITY_PICKER_ID "Developer ID Installer: Someone Real (AAAAAAAAAA)"
check "the document has it"      "Developer ID Installer: Someone Real (AAAAAAAAAA)" "$(model /SIGNING/INSTALLER_IDENTITY)"
check "and it was remembered"    "Developer ID Installer: Someone Real (AAAAAAAAAA)" "$(pref default_installer_identity)"

section "25. an echoed programmatic write never touches the preference"
# push_model_to_window writes this picker on EVERY document that opens. If such
# an echo reached the preference, merely opening a project would retarget the
# user's default to whatever that project names, and every later File > New
# would inherit it. Two things stop it: loading_in_progress, simulated here, and
# the value-equality exit that the write now sits behind.
pb_set loading "$(/bin/date '+%s')"
omc_fire PackageBuilder.field.changed $IDENTITY_PICKER_ID "Developer ID Installer: Somebody Else (BBBBBBBBBB)"
pb_set loading ""
check "the document is untouched" "Developer ID Installer: Someone Real (AAAAAAAAAA)" "$(model /SIGNING/INSTALLER_IDENTITY)"
check "and so is the preference"  "Developer ID Installer: Someone Real (AAAAAAAAAA)" "$(pref default_installer_identity)"
# The other half of the defense, with no loading flag set at all: an event
# carrying the value the model already holds is the engine echoing a write back,
# not a person choosing anything.
pb_call prefs_set default_installer_identity "Developer ID Installer: Untouched (CCCCCCCCCC)"
omc_fire PackageBuilder.field.changed $IDENTITY_PICKER_ID "Developer ID Installer: Someone Real (AAAAAAAAAA)"
# The preference deliberately holds a DIFFERENT value here, so "inert" is a real
# claim: if the echo reached the write, this would have been overwritten with
# the picker's value.
check "an unchanged value is inert" "Developer ID Installer: Untouched (CCCCCCCCCC)" "$(pref default_installer_identity)"
check "and the document is too"  "Developer ID Installer: Someone Real (AAAAAAAAAA)" "$(model /SIGNING/INSTALLER_IDENTITY)"

section "26. a remembered identity is seeded only when this keychain has it"
real_identity="$(keychain_identity)"
if [ -n "$real_identity" ]; then
    pb_call prefs_set default_installer_identity "$real_identity"
    reset_state
    omc_object ""
    omc_run PackageBuilder.main.init
    check "a real one is seeded"  "$real_identity"           "$(model /SIGNING/INSTALLER_IDENTITY)"
    check "and it is still clean" "0"                        "$(dirty)"
    # The picker is the only gesture that says "this is the one I want", so it
    # is the only one that writes the preference.
    reset_state
    omc_object ""
    omc_run PackageBuilder.main.init
    pb_call prefs_set default_installer_identity ""
    omc_fire PackageBuilder.field.changed $IDENTITY_PICKER_ID "$real_identity"
    check "picking it remembers"  "$real_identity"           "$(pref default_installer_identity)"
    check "and the document has it" "$real_identity"         "$(model /SIGNING/INSTALLER_IDENTITY)"
else
    # Not a comment on this machine: omctest isolates $HOME, the keychain
    # search list lives in ~/Library/Preferences, and so "security
    # find-identity" reports nothing under the suite however many certificates
    # are really installed. The stale-identity half above is the one that can
    # be proved here, and it is the half that decides whether a bad default
    # reaches a project.
    skip_section "26 (second half): no identity is visible under the suite's isolated HOME"
fi

section "cumulative: no handler wrote to a view id the window does not declare"
# unknown_ids.log accumulates across the whole file and nothing resets it, so
# one assertion here covers every section above. The per-section copy in the
# document file covers only the section it sits in - a bogus write from any
# later handler was invisible until this was added.
check "no undeclared ids"        ""                          "$(ui_unknown_writes)"

omctest_end
