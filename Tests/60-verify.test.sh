#!/bin/sh
# Tests/60-verify.test.sh - the payload verify, and stopping a run.
#
# Ported from Private/harness.sh sections 97 to 120. Sections 113 to 120 are the
# regressions from the phase 4 review.
#
# The fixtures make this file unusually honest. A copy of /bin/echo is a
# genuinely signed Mach-O that genuinely lacks a secure timestamp and a hardened
# runtime, so the two diagnostics design section 7 cares most about are tested
# against a real binary in exactly the state an "xcodebuild build" artifact
# arrives in, rather than against something constructed to fail.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.packagebuilder.sh"

section "97. Verify Payload reads the artifacts and writes nothing"
setup_replay_project
omc_run PackageBuilder.step.verify
check "the stage ran"            "1"                          "$(log_says 'Verifying the payload')"
check "an empty assertion says so" "1"                        "$(log_says 'nothing asserted, nothing checked')"
check "it verified"              "1"                          "$(log_says 'Every artifact matches')"
check "nothing was staged"       "no"                         "$([ -d "$(state_dir)/root" ] && echo yes || echo no)"
check "nothing was built"        ""                           "$(built_pkg)"
check "busy flag cleared"        ""                           "$(pb_get busy)"

section "98. an architecture that is not there is named, with what is"
setup_replay_project
pb_call payload_archs_set 0 "arm64"
omc_run PackageBuilder.step.verify
check "named the architecture"   "1"                          "$(log_says 'not built for arm64')"
check "reported what is there"   "1"                          "$(log_says 'lipo reports \[x86_64 arm64e\]')"
# arm64e is where this one bites: it reads like a newer arm64 and is a separate
# architecture. Saying so costs a line and saves an afternoon.
check "explained arm64e"         "1"                          "$(log_says 'arm64e is a separate architecture')"
check "did not verify"           "1"                          "$(log_says 'not what the document says')"

section "99. an architecture that is there passes"
setup_replay_project
pb_call payload_archs_set 0 "x86_64
arm64e"
omc_run PackageBuilder.step.verify
check "reported both"            "1"                          "$(log_says 'built for x86_64 arm64e')"
check "verified"                 "1"                          "$(log_says 'Every artifact matches')"

section "100. a missing secure timestamp is named as the mistake it is"
# A binary from "xcodebuild build" is signed with --timestamp=none and prints
# "Signed Time=" where a real one prints "Timestamp=". It looks entirely
# plausible otherwise, and the notary service is the next thing to see it.
setup_replay_project
pl set bool true "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/SECURE_TIMESTAMP
omc_run PackageBuilder.step.verify
check "named the failure"        "1"                          "$(log_says 'without a secure timestamp')"
check "said notarization fails"  "1"                          "$(log_says 'notarization will reject it')"
check "named the cause"          "1"                          "$(log_says 'xcodebuild archive')"

section "101. a missing hardened runtime is named the same way"
setup_replay_project
pl set bool true "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/HARDENED_RUNTIME
omc_run PackageBuilder.step.verify
check "named the failure"        "1"                          "$(log_says 'not signed with the hardened runtime')"
check "named the cause"          "1"                          "$(log_says 'codesign --options runtime')"

section "102. the wrong signing authority reports both names"
setup_replay_project
pl set string "Developer ID Application" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/SIGNED_BY
omc_run PackageBuilder.step.verify
check "named what was expected"  "1"                          "$(log_says 'expected a signature from "Developer ID Application"')"
check "named what was found"     "1"                          "$(log_says 'macOS Software Signing')"
check "named the likely cause"   "1"                          "$(log_says 'distribution signing settings were not applied')"

section "103. SIGNED_BY is a prefix of the Authority line, not the whole of it"
# The value the inspector fills in by default is "Developer ID Application",
# which is the leading part of every Developer ID certificate name rather than
# any one of them - so a whole-line match would refuse every artifact the app
# itself set up.
setup_replay_project
pl set string "macOS Software Signing" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/SIGNED_BY
omc_run PackageBuilder.step.verify
check "the prefix matched"       "1"                          "$(log_says 'signature ok')"
check "verified"                 "1"                          "$(log_says 'Every artifact matches')"
pl set string "macOS Software Sign" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/SIGNED_BY
omc_run PackageBuilder.step.verify
check "a shorter prefix matches too" "1"                      "$(log_says 'signature ok')"

section "104. a signature that does not validate is refused before it is read"
setup_replay_project
printf 'tampered\n' >> "$OMCTEST_WORK/replay-artifacts/replay"
# A value that does NOT match the fixture's leaf. With a matching one the second
# check could not discriminate: an implementation that consulted the authority
# first would find it satisfied and log nothing either, so the test would pass
# against the very ordering it exists to forbid. codesign --display still prints
# the full, correct chain for a tampered binary, so the wrong order is not
# self-defeating. Found in review, 2026-08-06.
pl set string "Developer ID Application" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/SIGNED_BY
omc_run PackageBuilder.step.verify
check "refused"                  "1"                          "$(log_says 'code signature does not verify')"
# What --display prints about a signature that does not validate is not evidence
# of anything, so the Authority check must never be reached.
check "authority not consulted"  "0"                          "$(log_says 'expected a signature from')"

section "105. a stale artifact is caught by the version cross-check"
# The only defense against a six-month-old binary passing every other check
# happily and shipping under a new version number.
setup_replay_project
/bin/cat > "$OMCTEST_WORK/replay-artifacts/versiontool" <<'TOOL'
#!/bin/sh
printf 'versiontool 9.9 (build 1)\n'
TOOL
/bin/chmod +x "$OMCTEST_WORK/replay-artifacts/versiontool"
omc_dialog_answer choose_object "$OMCTEST_WORK/replay-artifacts/versiontool"
omc_run PackageBuilder.payload.add
last="$(( $(count /COMPONENTS/0/PAYLOAD) - 1 ))"
pb_call payload_archs_set "$last" ""
pl set string "" "$(model_file)" "/COMPONENTS/0/PAYLOAD/$last/VERIFY/SIGNED_BY"
pl set bool false "$(model_file)" "/COMPONENTS/0/PAYLOAD/$last/VERIFY/HARDENED_RUNTIME"
pl set bool false "$(model_file)" "/COMPONENTS/0/PAYLOAD/$last/VERIFY/SECURE_TIMESTAMP"
pl set string "--version" "$(model_file)" "/COMPONENTS/0/PAYLOAD/$last/VERIFY/VERSION_FLAG"
omc_run PackageBuilder.step.verify
check "reported both versions"   "1"                          "$(log_says 'reports version 9.9, but this is being built as 2.2')"
check "named the likely cause"   "1"                          "$(log_says 'artifacts folder may be stale')"
# Renamed into place rather than truncated: rewriting a file that was executed
# moments ago can fail with ETXTBSY, and a rename never can.
/bin/cat > "$OMCTEST_WORK/versiontool.next" <<'TOOL'
#!/bin/sh
printf 'versiontool 2.2 (build 1)\n'
TOOL
/bin/chmod +x "$OMCTEST_WORK/versiontool.next"
/bin/mv -f "$OMCTEST_WORK/versiontool.next" "$OMCTEST_WORK/replay-artifacts/versiontool"
omc_run PackageBuilder.step.verify
check "a matching version passes" "1"                         "$(log_says 'reports version 2.2')"
check "verified"                 "1"                          "$(log_says 'Every artifact matches')"

section "106. verify stops at the first problem (design 7)"
# The preconditions accumulate so one run reports everything wrong with the
# document. This stage does not: a verify failure means the artifact on disk is
# not the artifact the document describes, and the rest of the answers are not
# worth the wait.
setup_replay_project
pb_call payload_archs_set 1 "arm64"
pb_call payload_archs_set 2 "arm64"
omc_run PackageBuilder.step.verify
check "the second item failed"   "1"                          "$(log_says 'item 2 (gate): not built for arm64')"
check "the third was not reached" "0"                         "$(log_says 'item 3')"

section "107. Build Package verifies before it stages anything"
# A package built from a stale or wrongly-signed binary is worse than no
# package: it is signed, it installs, and nothing about it looks wrong until it
# reaches a user. So the stage that can tell runs before the first file is
# copied.
setup_replay_project
# Signing off, so the run reaches stage 1 rather than stopping in the signing
# preconditions on a machine with no installer certificate.
pl set bool false "$(model_file)" /SIGNING/ENABLED
pb_call payload_archs_set 0 "arm64"
omc_run PackageBuilder.build
check "preconditions passed"     "1"                          "$(log_says 'all clear')"
check "the build stopped"        "1"                          "$(log_says 'not what the document says')"
check "nothing was staged"       "no"                         "$([ -d "$(state_dir)/root" ] && echo yes || echo no)"
check "no component was built"   ""                           "$(built_pkg)"
check "busy flag cleared"        ""                           "$(pb_get busy)"

# --- Stopping a run -----------------------------------------------------------
#
# The two sections below run a build helper in the background so there is a live
# tool for Stop to reach. The helper sources the app's libraries and asks THEM
# for the state directory rather than being handed a path: omctest exports the
# window uuid and TMPDIR, so the child computes the same directory this file
# does, and a divergence shows up as a missing file rather than as two shells
# quietly working in different places.

section "108. a running tool is reachable: run_capture records its pid"
# A tool run in the foreground cannot be stopped - the shell is blocked inside
# it and the pid that would have to be signaled exists nowhere but the kernel.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
# request_stop signals only a pid it can prove is the recorded build script's
# own child, so the runner records its pid the way build_begin does. A bare
# run_capture with no run.pid on record is exactly the recycled-pid stranger
# the parentage check exists to spare.
/bin/cat > "$OMCTEST_WORK/cap-run.sh" <<'FAKE'
scripts="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts"
. "$scripts/lib.packagebuilder.sh"
. "$scripts/lib.packagebuilder.window.sh"
. "$scripts/lib.packagebuilder.build.sh"
printf '%s' "$$" > "$(state_dir)/run.pid"
run_capture "$(state_dir)/cap.txt" /bin/sleep 10
printf '%s' "$?" > "$(state_dir)/cap-status.txt"
FAKE
# stderr to a file: reaping a signaled job makes the shell announce it, and the
# notice goes to the stderr the shell started with whatever is redirected at the
# wait itself. The engine discards a handler's stderr; this keeps the suite's
# own output readable.
/bin/sh "$OMCTEST_WORK/cap-run.sh" 2>"$OMCTEST_WORK/jobnotice.txt" &
capture_shell=$!
check "the pid was recorded"     "yes"                        "$(omc_wait_for "[ -f \"$(state_dir)/tool.pid\" ]" && echo yes || echo no)"
check "and it is alive"          "0"                          "$(/bin/kill -0 "$(/bin/cat "$(state_dir)/tool.pid")" 2>/dev/null; echo $?)"
pb_build_call request_stop
wait "$capture_shell"
# 128 + SIGTERM, read from the runner's own record: what matters to the caller
# is only that it is not zero, so the stage reports a failure and the flag
# decides what kind.
check "the tool was terminated"  "143"                        "$(/bin/cat "$(state_dir)/cap-status.txt" 2>/dev/null)"
check "the pid file was cleared" "no"                         "$([ -f "$(state_dir)/tool.pid" ] && echo yes || echo no)"
check "the flag was raised"      "yes"                        "$([ -f "$(state_dir)/stop-requested" ] && echo yes || echo no)"

section "109. Stop asks; it does not kill the build script"
# The whole point of the flag. A build script killed mid-stage leaves the rail
# frozen part-way, the Actions menu disabled and the busy flag set - the wedged
# window the phase 3 review found. Left alive, it unwinds through the exit path
# it already has and says which stage it stopped in.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
/bin/cat > "$OMCTEST_WORK/fake-build.sh" <<'FAKE'
scripts="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts"
. "$scripts/lib.packagebuilder.sh"
. "$scripts/lib.packagebuilder.window.sh"
. "$scripts/lib.packagebuilder.build.sh"
build_begin
run_capture "$(state_dir)/fake.txt" /bin/sleep 10
if stop_was_requested; then
    printf 'unwound\n' > "$(state_dir)/fake-result.txt"
else
    printf 'ran to completion\n' > "$(state_dir)/fake-result.txt"
fi
build_end
FAKE
/bin/sh "$OMCTEST_WORK/fake-build.sh" 2>>"$OMCTEST_WORK/jobnotice.txt" &
fake_build=$!
check "the run is live"          "yes"                        "$(omc_wait_for "[ -f \"$(state_dir)/tool.pid\" ]" && echo yes || echo no)"
check "the process group is on record" "1"                    "$(/usr/bin/grep -cE '^[0-9]+$' "$(state_dir)/run.pgid" 2>/dev/null | /usr/bin/tr -d ' ')"
stop_started="$(/bin/date '+%s')"
omc_run PackageBuilder.stop
wait "$fake_build"
# The sleep is 10 seconds. Without this the handler could raise the flag and
# signal nothing at all: the tool would finish on its own, stop_was_requested
# would still be true, and every check below would pass ten seconds later. A
# reviewer replaced request_stop with a bare touch of the flag file and the
# section stayed green - this is the check that catches it.
check "the tool was signaled, not waited out" "yes"           "$([ $(( $(/bin/date '+%s') - stop_started )) -lt 5 ] && echo yes || echo no)"
check "the script survived to unwind" "unwound"               "$(/bin/cat "$(state_dir)/fake-result.txt" 2>/dev/null)"
check "busy flag cleared"        ""                           "$(pb_get busy)"
check "run.pid cleared"          "no"                         "$([ -f "$(state_dir)/run.pid" ] && echo yes || echo no)"
check "the flag was cleared"     "no"                         "$([ -f "$(state_dir)/stop-requested" ] && echo yes || echo no)"

section "110. Stop with nothing running leaves no flag behind"
# A stray click after a run finishes must not arm the next one.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
omc_run PackageBuilder.stop
check "no flag left behind"      "no"                         "$([ -f "$(state_dir)/stop-requested" ] && echo yes || echo no)"

section "111. a stale flag cannot stop the next run"
setup_replay_project
/usr/bin/touch "$(state_dir)/stop-requested"
omc_run PackageBuilder.step.verify
check "the run went through"     "1"                          "$(log_says 'Every artifact matches')"
check "the flag is gone"         "no"                         "$([ -f "$(state_dir)/stop-requested" ] && echo yes || echo no)"

section "112. a stopped stage reports a stop, not a failure"
setup_replay_project
/usr/bin/touch "$(state_dir)/stop-requested"
pb_build_eval 'stop_here "$RAIL_COMPONENT_ID"' >/dev/null 2>&1
check "said who stopped it"      "1"                          "$(log_says 'Stopped at your request')"
check "said what was not written" "1"                         "$(log_says 'output folder was not given a package')"
# stop_here answers "no" when nothing was requested, so a stage that simply
# failed keeps its own message.
/bin/rm -f "$(state_dir)/stop-requested"
check "silent when not asked"    "1"                          "$(pb_build_eval 'stop_here "$RAIL_COMPONENT_ID"' >/dev/null 2>&1; echo $?)"

# --- Regressions from the phase 4 review --------------------------------------

section "113. the authority match is anchored, and to the leaf only (M1)"
# Two ways the old unanchored grep -F over the whole report was wrong, both
# proven by the reviewer with working artifacts.
setup_replay_project

# (a) The report opens with "Executable=<path>", so an unanchored search found
# the expected text inside the artifact's own directory name. An ad-hoc binary
# in a directory called "Authority=Developer ID Application" passed.
/bin/mkdir -p "$OMCTEST_WORK/Authority=Developer ID Application"
/bin/cp /bin/echo "$OMCTEST_WORK/Authority=Developer ID Application/planted"
/usr/bin/codesign --force --sign - "$OMCTEST_WORK/Authority=Developer ID Application/planted" 2>/dev/null
omc_dialog_answer choose_object "$OMCTEST_WORK/Authority=Developer ID Application/planted"
omc_run PackageBuilder.payload.add
planted="$(( $(count /COMPONENTS/0/PAYLOAD) - 1 ))"
pb_call payload_archs_set "$planted" ""
pl set bool false "$(model_file)" "/COMPONENTS/0/PAYLOAD/$planted/VERIFY/HARDENED_RUNTIME"
pl set bool false "$(model_file)" "/COMPONENTS/0/PAYLOAD/$planted/VERIFY/SECURE_TIMESTAMP"
pl set string "" "$(model_file)" "/COMPONENTS/0/PAYLOAD/$planted/VERIFY/VERSION_FLAG"
pl set string "Developer ID Application" "$(model_file)" "/COMPONENTS/0/PAYLOAD/$planted/VERIFY/SIGNED_BY"
omc_run PackageBuilder.step.verify
check "the path cannot satisfy it" "1"                        "$(log_says 'expected a signature from')"
check "and it is named ad-hoc"     "1"                        "$(log_says 'ad-hoc, with no certificate chain')"

# (b) "Authority=" appears once per certificate in the chain, so a match
# anywhere in the list accepted a root CA as though it had signed the binary.
setup_replay_project
pl set string "Apple Root CA" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/SIGNED_BY
omc_run PackageBuilder.step.verify
check "a chain cert is not the signer" "1"                    "$(log_says 'expected a signature from "Apple Root CA"')"
check "the leaf is named instead"  "1"                        "$(log_says 'found macOS Software Signing')"
# The leaf still matches as a prefix, which is the behavior the default value
# depends on.
pl set string "macOS Software" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/SIGNED_BY
omc_run PackageBuilder.step.verify
check "the leaf prefix still passes" "1"                      "$(log_says 'signature ok')"

section "114. every slice of a universal binary is checked (M2)"
# codesign reports the native architecture alone unless told otherwise, so a fat
# artifact whose x86_64 slice was signed without --options runtime passed on an
# Apple Silicon machine while the notary service, which looks at all of them,
# would reject it.
setup_replay_project
# /bin/echo is already universal, and lipo refuses -arch flags on a fat input -
# each slice is thinned out first, re-signed on its own terms, and the fat file
# is put back together from the thin pieces.
/usr/bin/lipo /bin/echo -thin arm64e -output "$OMCTEST_WORK/thin-arm.bin" 2>/dev/null
/usr/bin/lipo /bin/echo -thin x86_64 -output "$OMCTEST_WORK/thin-intel.bin" 2>/dev/null
/usr/bin/codesign --force --sign - --options runtime "$OMCTEST_WORK/thin-arm.bin" 2>/dev/null
/usr/bin/codesign --force --sign - "$OMCTEST_WORK/thin-intel.bin" 2>/dev/null
if /usr/bin/lipo -create "$OMCTEST_WORK/thin-arm.bin" "$OMCTEST_WORK/thin-intel.bin" \
        -output "$OMCTEST_WORK/replay-artifacts/halfhard" 2>/dev/null; then
    omc_dialog_answer choose_object "$OMCTEST_WORK/replay-artifacts/halfhard"
    omc_run PackageBuilder.payload.add
    fat="$(( $(count /COMPONENTS/0/PAYLOAD) - 1 ))"
    pb_call payload_archs_set "$fat" ""
    pl set string "" "$(model_file)" "/COMPONENTS/0/PAYLOAD/$fat/VERIFY/SIGNED_BY"
    pl set string "" "$(model_file)" "/COMPONENTS/0/PAYLOAD/$fat/VERIFY/VERSION_FLAG"
    pl set bool false "$(model_file)" "/COMPONENTS/0/PAYLOAD/$fat/VERIFY/SECURE_TIMESTAMP"
    pl set bool true "$(model_file)" "/COMPONENTS/0/PAYLOAD/$fat/VERIFY/HARDENED_RUNTIME"
    # Sanity: the whole-file check the old code relied on really does pass, so
    # this section is testing the fix and not a broken fixture.
    check "the fat file verifies whole" "0"                   "$(/usr/bin/codesign --verify --strict "$OMCTEST_WORK/replay-artifacts/halfhard" 2>/dev/null; echo $?)"
    omc_run PackageBuilder.step.verify
    check "the bad slice is refused"  "1"                     "$(log_says 'not signed with the hardened runtime')"
    check "and the slice is named"    "1"                     "$(log_says '\[x86_64\]')"
else
    # A failure, not a skip. A silent skip here hid the entire multi-slice
    # branch behind a green run for a full review cycle; if a future macOS
    # makes /bin/echo thin, someone updates the fixture deliberately.
    check "a fat fixture could be built" "yes"                "no"
fi

section "115. a stop is not reported as a verdict on the artifact (m2)"
# A tool killed by Stop returns non-zero like any other failure. Saying "the
# code signature does not verify" about an artifact nobody finished checking
# would leave a false accusation in the log after the run is over.
setup_replay_project
pl set string "macOS Software Signing" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/SIGNED_BY
/usr/bin/touch "$(state_dir)/stop-requested"
# verify_payload_ENTRY, not verify_payload. The loop in verify_payload has its
# own stop guard and returns on the first iteration, so through it the entry
# function never runs and both checks below are trivially true - a reviewer
# deleted the guard being tested here and the section stayed green. Calling the
# entry directly is what reaches the line that decides whether a tool killed by
# Stop gets a verdict pronounced on it. Section 116 covers the loop guard.
pb_build_eval 'verify_payload_entry 0' >/dev/null 2>&1
check "no accusation was logged" "0"                          "$(log_says 'does not verify')"
check "and no tool was started"  "no"                         "$([ -f "$(state_dir)/codesign.txt" ] && echo yes || echo no)"
/bin/rm -f "$(state_dir)/stop-requested"

section "116. a stop between entries ends the stage (m3)"
# Between two entries there is no tool running for Stop to signal, so the flag
# is the only thing that can end the stage.
setup_replay_project
/usr/bin/touch "$(state_dir)/stop-requested"
check "verify_payload gives up"  "1"                          "$(pb_build_eval 'verify_payload' >/dev/null 2>&1; echo $?)"
check "no item was checked"      "0"                          "$(log_says 'nothing asserted')"
/bin/rm -f "$(state_dir)/stop-requested"

section "117. run_capture refuses to start a tool after a stop (m1)"
# Without this, a stop landing in the gap between two tools signals a pid that
# has already been reaped, and the next tool runs to completion.
reset_state
omc_object ""
omc_run PackageBuilder.main.init
/usr/bin/touch "$(state_dir)/stop-requested"
started="$(/bin/date '+%s')"
rc="$(pb_build_call run_capture "$(state_dir)/cap.txt" /bin/sleep 5 >/dev/null 2>&1; echo $?)"
elapsed=$(( $(/bin/date '+%s') - started ))
check "reported as terminated"   "143"                        "$rc"
check "and it did not wait"      "yes"                        "$([ "$elapsed" -lt 3 ] && echo yes || echo no)"
/bin/rm -f "$(state_dir)/stop-requested"

section "118. a stopped stage is marked skipped, not failed (n1)"
# At a boundary the icon belongs to a stage that never started, where a red X
# reads as a defect in the project. Nothing failed - the user asked for this.
#
# The proof of concept grepped the TEXT of report_stop's body for the rail_set
# call. That fails on a rename and passes on a regression: a reviewer wrapped
# the line in "if false" and added a rail_set ... failed underneath, and the
# check stayed green while the rail went red. omctest has a window, so the rail
# can simply be read back.
/usr/bin/touch "$(state_dir)/stop-requested"
pb_build_eval 'stop_here "$RAIL_COMPONENT_ID"' >/dev/null 2>&1
rail_id="$(pb_build_eval 'printf %s "$RAIL_COMPONENT_ID"' 2>/dev/null)"
check "the rail is marked skipped" "minus.circle"             "$(ui_prop "$rail_id" systemName)"
check "and gray, not red"        "gray"                       "$(ui_prop "$rail_id" foregroundStyle)"
/bin/rm -f "$(state_dir)/stop-requested"

section "119. data appended past the signed region is refused"
# The hole the per-slice fix of section 114 reopened: an --arch pass validates
# the slice it is aimed at and nothing else, so a fat binary with a payload
# appended after the signed region passes every per-slice check with a clean
# exit status. Only the whole-file strict validation refuses it, which is why
# verify_payload_entry runs one before the slice loop. The first check is the
# point: it proves per-slice codesign really does accept the tampered file, so
# the stage refusing it below is the whole-file pass and nothing else.
setup_replay_project
/usr/bin/lipo /bin/echo -thin arm64e -output "$OMCTEST_WORK/sm-arm.bin" 2>/dev/null
/usr/bin/lipo /bin/echo -thin x86_64 -output "$OMCTEST_WORK/sm-intel.bin" 2>/dev/null
/usr/bin/codesign --force --sign - --options runtime "$OMCTEST_WORK/sm-arm.bin" 2>/dev/null
/usr/bin/codesign --force --sign - --options runtime "$OMCTEST_WORK/sm-intel.bin" 2>/dev/null
if /usr/bin/lipo -create "$OMCTEST_WORK/sm-arm.bin" "$OMCTEST_WORK/sm-intel.bin" \
        -output "$OMCTEST_WORK/replay-artifacts/smuggled" 2>/dev/null; then
    printf 'SMUGGLED-PAYLOAD' >> "$OMCTEST_WORK/replay-artifacts/smuggled"
    check "per-slice codesign accepts it" "0"                 "$(/usr/bin/codesign --verify --strict --arch x86_64 "$OMCTEST_WORK/replay-artifacts/smuggled" 2>/dev/null; echo $?)"
    omc_dialog_answer choose_object "$OMCTEST_WORK/replay-artifacts/smuggled"
    omc_run PackageBuilder.payload.add
    smuggled="$(( $(count /COMPONENTS/0/PAYLOAD) - 1 ))"
    pb_call payload_archs_set "$smuggled" ""
    pl set string "" "$(model_file)" "/COMPONENTS/0/PAYLOAD/$smuggled/VERIFY/SIGNED_BY"
    pl set string "" "$(model_file)" "/COMPONENTS/0/PAYLOAD/$smuggled/VERIFY/VERSION_FLAG"
    pl set bool false "$(model_file)" "/COMPONENTS/0/PAYLOAD/$smuggled/VERIFY/SECURE_TIMESTAMP"
    pl set bool true "$(model_file)" "/COMPONENTS/0/PAYLOAD/$smuggled/VERIFY/HARDENED_RUNTIME"
    omc_run PackageBuilder.step.verify
    check "the stage refuses it"      "1"                     "$(log_says 'does not verify')"
    check "and strict validation is named" "1"                "$(log_says 'failed strict validation')"
else
    # A failure, not a skip, for the same reason as section 114.
    check "a fat fixture could be built" "yes"                "no"
fi

section "120. a stopped build stage is not reported as a stage failure"
# Section 115's argument, for the build stages: a ditto or pkgbuild killed by
# Stop returns non-zero like any other failure, and "Could not copy" about a
# copy nobody let finish would be a false accusation in the log after the run
# is over. The boundary reports the stop.
setup_replay_project
/usr/bin/touch "$(state_dir)/stop-requested"
pb_build_eval 'stage_payload_root' >/dev/null 2>&1
check "no accusation was logged" "0"                          "$(log_says 'Could not copy')"
/bin/rm -f "$(state_dir)/stop-requested"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids"        ""                           "$(ui_unknown_writes)"

omctest_end
