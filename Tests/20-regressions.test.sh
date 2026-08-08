#!/bin/sh
# Tests/20-regressions.test.sh - the lifecycle regression block.
#
# Ported from Private/harness.sh sections 18 to 31. These are the defects a
# review found in the document state machine; each one shipped once and each
# check is the reproduction. Expected values are the proof of concept's,
# unchanged.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.packagebuilder.sh"

sample="$(fixture_copy Sample.pkgbuilderproj)"

section "18. toggles are pushed as true/false, not 1/0 (C1)"
# ActionUI Bool elements accept only "true"/"false" through
# setElementValueFromString; "1"/"0" are logged and discarded, so a document
# would open with every checkbox showing its JSON default instead of its value.
check "bool_str true"            "true"                      "$(pb_call bool_str 1)"
check "bool_str false"           "false"                     "$(pb_call bool_str 0)"
reset_state
bools="$(work_copy Sample.pkgbuilderproj Bools.pkgbuilderproj)"
pl set bool false "$bools" /SIGNING/ENABLED >/dev/null 2>&1
pl set bool true "$bools" /COMPONENTS/0/RELOCATABLE >/dev/null 2>&1
omc_object "$bools"
omc_run PackageBuilder.main.init
check "signing read as false"    "false"                     "$(pb_call model_get_bool_str /SIGNING/ENABLED)"
check "relocatable read as true" "true"                      "$(pb_call model_get_bool_str /COMPONENTS/0/RELOCATABLE)"

section "19. a document missing whole subtrees is normalized on load (M2)"
# plister "set" cannot create intermediate containers, so without this an edit
# into a missing subtree is silently dropped while the document reports dirty.
reset_state
printf '{"FORMAT_VERSION":1,"PROJECT":{"NAME":"partial"}}\n' > "$OMCTEST_WORK/Partial.pkgbuilderproj"
omc_object "$OMCTEST_WORK/Partial.pkgbuilderproj"
omc_run PackageBuilder.main.init
check "it did open"              "$OMCTEST_WORK/Partial.pkgbuilderproj" "$(doc_path)"
check "name preserved"           "partial"                   "$(model /PROJECT/NAME)"
check "containers created"       "dict"                      "$(pl get type "$(model_file)" /DISTRIBUTION/RESOURCES 2>/dev/null)"
check "install location default" "/"                         "$(model /COMPONENTS/0/INSTALL_LOCATION)"
omc_fire PackageBuilder.field.changed $README_ID "readme.rtf"
check "edit into old gap lands"  "readme.rtf"                "$(model /DISTRIBUTION/RESOURCES/README)"
check "and is dirty"             "1"                         "$(dirty)"

section "20. out-of-range enum values are normalized (m4)"
reset_state
printf '{"FORMAT_VERSION":1,"COMPONENTS":[{"AUTH":1}],"DISTRIBUTION":{"CUSTOMIZE":"bogus"}}\n' > "$OMCTEST_WORK/Enum.pkgbuilderproj"
omc_object "$OMCTEST_WORK/Enum.pkgbuilderproj"
omc_run PackageBuilder.main.init
check "AUTH integer 1 -> Root"   "Root"                      "$(model /COMPONENTS/0/AUTH)"
check "bogus CUSTOMIZE -> never" "never"                     "$(model /DISTRIBUTION/CUSTOMIZE)"

section "21. a failed write does not mark the document dirty (M2)"
# plister "set" fails when a parent container is absent. Deleting DISTRIBUTION
# behind the handler's back reproduces what a truncated document used to do:
# the field accepted the text, the title said edited, and the value went nowhere.
reset_state
omc_object "$sample"
omc_run PackageBuilder.main.init
pl remove "$(model_file)" /DISTRIBUTION >/dev/null 2>&1
omc_fire PackageBuilder.field.changed $README_ID "cannot land"
check "still clean"              "0"                         "$(dirty)"
check "value not written"        ""                          "$(model /DISTRIBUTION/RESOURCES/README)"

section "22. save refuses a destination that is a directory (M1)"
reset_state
omc_object "$sample"
omc_run PackageBuilder.main.init
omc_fire PackageBuilder.field.changed $TITLE_ID "edited"
/bin/mkdir -p "$OMCTEST_WORK/Directory.pkgbuilderproj"
omc_dialog_answer save_as "$OMCTEST_WORK/Directory.pkgbuilderproj"
omc_run PackageBuilder.save.as
check "document still dirty"     "1"                         "$(dirty)"
check "doc_path not moved"       "$sample"                   "$(doc_path)"
check "nothing inside the dir"   ""                          "$(/bin/ls -A "$OMCTEST_WORK/Directory.pkgbuilderproj")"
check "hash still usable"        "yes"                       "$([ -n "$(/bin/cat "$(state_dir)/doc_hash.txt")" ] && echo yes || echo no)"

section "23. a canceled Save As on the close path keeps the work (C3)"
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_fire PackageBuilder.field.changed $NAME_ID "unsaved work"
pb_set close_after_save 1
alerts_reset
omc_dialog_answer save_as ""
omc_run PackageBuilder.save.as
check "model survived cancel"    "unsaved work"              "$(model /PROJECT/NAME)"
check_exists "state dir kept"    "$(state_dir)"
check "the user was told"        "1"                         "$(alerts_mention 'Could Not Save')"
check "closing flag cleared"     ""                          "$(pb_get close_after_save)"

section "24. a stale loading flag does not swallow edits forever (m6)"
reset_state
omc_object "$sample"
omc_run PackageBuilder.main.init
pb_set loading "$(( $(/bin/date '+%s') - 3600 ))"
omc_fire PackageBuilder.field.changed $TITLE_ID "edit after stale flag"
check "edit was applied"         "edit after stale flag"     "$(model /DISTRIBUTION/TITLE)"
pb_set loading ""

section "25. a non-numeric trigger view id is refused (m9)"
reset_state
injection="$(work_copy Sample.pkgbuilderproj Injection.pkgbuilderproj)"
omc_object "$injection"
omc_run PackageBuilder.main.init
# The sink is an eval that interpolates the view id INSIDE double quotes
# (lib.packagebuilder.sh, value_of), so a semicolon is inert there and only
# command substitution reaches the shell. The proof of concept used the
# semicolon vector and grepped the handler's output for the echoed word, which
# is doubly blind: the vector cannot fire, and a substitution that did fire
# would have its output captured into the variable rather than printed. A
# sentinel in the filesystem is visible either way.
/bin/rm -f "$OMCTEST_WORK/PWNED"
omc_trigger "$IDENTIFIER_ID\$(/usr/bin/touch $OMCTEST_WORK/PWNED)"
omc_run PackageBuilder.field.changed
check_absent "no command ran"    "$OMCTEST_WORK/PWNED"
omc_trigger "$IDENTIFIER_ID\`/usr/bin/touch $OMCTEST_WORK/PWNED\`"
omc_run PackageBuilder.field.changed
check_absent "nor through backticks" "$OMCTEST_WORK/PWNED"
# The proof of concept's own vector, kept because a separator is what a reader
# reaches for first and the guard has to refuse it too.
omc_trigger "$IDENTIFIER_ID;/bin/echo pwned"
omc_run PackageBuilder.field.changed
check "no output from a separator" "0"                       "$(/usr/bin/grep -c pwned "$OMCTEST_UI/handlers.log" | /usr/bin/tr -d ' ')"
check "model untouched"          "com.abracode.pkg.replay"   "$(model /COMPONENTS/0/IDENTIFIER)"
check "still clean"              "0"                         "$(dirty)"

section "26. concurrent edits do not lose one another (M7)"
reset_state
omc_object "$sample"
omc_run PackageBuilder.main.init
# Each dispatch goes in its own subshell, so the three get their own copies of
# the exported control values. Setting them in this shell and backgrounding
# three omc_run calls would give all three whichever value was set last, and the
# test would pass while proving nothing about the lock.
( omc_control $TITLE_ID "title A";   omc_trigger $TITLE_ID;   omc_run PackageBuilder.field.changed ) &
( omc_control $NAME_ID "name B";  omc_trigger $NAME_ID; omc_run PackageBuilder.field.changed ) &
( omc_control $IDENTIFIER_ID "com.c";     omc_trigger $IDENTIFIER_ID;   omc_run PackageBuilder.field.changed ) &
wait
check "first edit kept"          "title A"                   "$(model /DISTRIBUTION/TITLE)"
check "second edit kept"         "name B"                    "$(model /PROJECT/NAME)"
check "third edit kept"          "com.c"                     "$(model /COMPONENTS/0/IDENTIFIER)"
check_absent "lock released"     "$(state_dir)/model.lock"

section "27. app.will.terminate refuses a dangerous pid (M4)"
reset_state
/bin/mkdir -p "$(state_dir)"
printf '1' > "$(state_dir)/run.pid"
omc_run app.will.terminate
check_absent "swept without kill -1" "$(state_dir)"

# The sweep on its own cannot see a kill: rm -rf runs on the safe path and the
# dangerous one alike, so with only the check above the whole guard can be
# deleted and this section stays green. A live victim can see it. run.pid
# outlives a crash, which is exactly when this handler did not run to clear it,
# so after pid wrap the number names a stranger - that is the M4 defect, and
# /bin/sleep is a stranger by the same test the handler applies: its command
# line is not a script in this bundle.
reset_state
/bin/mkdir -p "$(state_dir)"
/bin/sleep 30 &
victim=$!
printf '%s' "$victim" > "$(state_dir)/run.pid"
printf '%s' "$victim" > "$(state_dir)/run.pgid"
omc_run app.will.terminate
check "a stranger is left alive" "yes"                       "$(/bin/ps -p "$victim" >/dev/null 2>&1 && echo yes || echo no)"
check_absent "and swept anyway"  "$(state_dir)"
/bin/kill "$victim" 2>/dev/null
wait "$victim" 2>/dev/null

section "28. close + Don't Save discards, close + Save keeps (M5)"
reset_state
close1="$(work_copy Sample.pkgbuilderproj Close1.pkgbuilderproj)"
omc_object "$close1"
omc_run PackageBuilder.main.init
omc_fire PackageBuilder.field.changed $TITLE_ID "discard me"
alerts_reset
alert_answer 1
omc_run PackageBuilder.window.close
check_absent "state discarded"   "$(state_dir)"
check "file not written"         "replay"                    "$(field_of "$close1" /DISTRIBUTION/TITLE)"

reset_state
close2="$(work_copy Sample.pkgbuilderproj Close2.pkgbuilderproj)"
omc_object "$close2"
omc_run PackageBuilder.main.init
omc_fire PackageBuilder.field.changed $TITLE_ID "keep me"
alerts_reset
alert_answer 0
omc_run PackageBuilder.window.close
check "saved on close"           "keep me"                   "$(field_of "$close2" /DISTRIBUTION/TITLE)"
check_absent "state cleaned up"  "$(state_dir)"

section "29. an alert that times out must not discard the work (M5)"
reset_state
close3="$(work_copy Sample.pkgbuilderproj Close3.pkgbuilderproj)"
omc_object "$close3"
omc_run PackageBuilder.main.init
omc_fire PackageBuilder.field.changed $TITLE_ID "survives timeout"
alerts_reset
alert_answer 3
omc_run PackageBuilder.window.close
check "saved rather than lost"   "survives timeout"          "$(field_of "$close3" /DISTRIBUTION/TITLE)"

section "30. a failed save on close strands the model, never deletes it (C3)"
reset_state
/bin/mkdir -p "$OMCTEST_WORK/ro"
/bin/cp "$(fixture Sample.pkgbuilderproj)" "$OMCTEST_WORK/ro/Locked.pkgbuilderproj"
/bin/chmod u+w "$OMCTEST_WORK/ro/Locked.pkgbuilderproj"
omc_object "$OMCTEST_WORK/ro/Locked.pkgbuilderproj"
omc_run PackageBuilder.main.init
omc_fire PackageBuilder.field.changed $TITLE_ID "must not vanish"
/bin/chmod 555 "$OMCTEST_WORK/ro"
alerts_reset
alert_answer 0
omc_run PackageBuilder.window.close
/bin/chmod 755 "$OMCTEST_WORK/ro"
check "model kept"               "must not vanish"           "$(model /DISTRIBUTION/TITLE)"
check_exists "state dir kept"    "$(state_dir)"
check "the user was told"        "1"                         "$(alerts_mention 'Could Not Save')"

section "31. external-change alert failure keeps unsaved edits (M5)"
reset_state
race="$(work_copy Sample.pkgbuilderproj Race.pkgbuilderproj)"
omc_object "$race"
omc_run PackageBuilder.main.init
omc_fire PackageBuilder.field.changed $NAME_ID "my unsaved edit"
pl set string "theirs" "$race" /PROJECT/NAME >/dev/null 2>&1
alerts_reset
alert_answer 255
omc_run PackageBuilder.window.activated
check "edits survived"           "my unsaved edit"           "$(model /PROJECT/NAME)"
# Keeping this window's changes adopts the on-disk hash, so the same question is
# not asked on every activation - a further change on disk asks again.
pl set string "theirs again" "$race" /PROJECT/NAME >/dev/null 2>&1
alert_answer 1
omc_run PackageBuilder.window.activated
check "explicit reload works"    "theirs again"              "$(model /PROJECT/NAME)"

section "cumulative: no handler wrote to a view id the window does not declare"
# unknown_ids.log accumulates across the whole file and nothing resets it, so
# one assertion here covers every section above. The per-section copy in the
# document file covers only the section it sits in - a bogus write from any
# later handler was invisible until this was added.
check "no undeclared ids"        ""                          "$(ui_unknown_writes)"

omctest_end
