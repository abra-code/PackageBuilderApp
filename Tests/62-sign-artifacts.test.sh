#!/bin/sh
# Tests/62-sign-artifacts.test.sh - signing the staged copy of an artifact that
# arrives with no signature, or only an ad-hoc one.
#
# The suite runs with an isolated HOME, so no Developer ID Application identity
# is ever visible (keychain_identity says why). What needs one is driven through
# pb_build_eval with the keychain lookup answered yes and "-" as the identity:
# codesign's ad-hoc signing takes the same flags a real identity does, so the
# detection, the entitlements and identifier carried over, the hardened runtime,
# the mode applied afterwards and the untouched artifacts folder are all real.
# What ad-hoc cannot show is a certificate chain or a secure timestamp.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.packagebuilder.sh"

# A copy of /bin/echo with its signature removed: what "swift build" hands over
# before the linker's signature is counted, and what a stripped binary is.
unsigned_copy() { # <path>
    /bin/cp /bin/echo "$1"
    /usr/bin/codesign --remove-signature "$1" 2>/dev/null
}

# A copy signed ad-hoc, the way a build script signs a tool it gives
# entitlements to. Arguments: path, identifier, entitlements plist
adhoc_copy() {
    /bin/cp /bin/echo "$1"
    /usr/bin/codesign --force --sign - --identifier "$2" --entitlements "$3" "$1" 2>/dev/null
}

sign_details() { # <path>
    /usr/bin/codesign --display --verbose=4 "$1" 2>&1
}

# The keychain lookup answered yes, for everything in the build library that
# asks it. The rest of the call is real.
with_identity() { # <shell code>
    pb_build_eval "application_identity_is_present() { return 0; }; $1"
}

entitlements_plist="$OMCTEST_WORK/virtualization.entitlements"
/bin/cat > "$entitlements_plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.virtualization</key>
    <true/>
    <key>com.apple.security.get-task-allow</key>
    <true/>
</dict>
</plist>
PLIST

artifacts="$OMCTEST_WORK/replay-artifacts"

section "206. a new document packages artifacts as they are"
reset_state
omc_object ""
omc_run PackageBuilder.main.init
check "no identity"              ""                           "$(model /SIGNING/APPLICATION_IDENTITY)"
check "the menu offers the decline" "1"                       "$(ui_prop $APPLICATION_IDENTITY_ID options | /usr/bin/grep -c '"tag":"__pb_no_artifact_sign__"')"
check "and sits on it"           "__pb_no_artifact_sign__"    "$(ui_value $APPLICATION_IDENTITY_ID)"
check "still clean"              "0"                          "$(dirty)"

section "207. an unsigned artifact is refused, and the refusal says what would sign it"
setup_replay_project
unsigned_copy "$artifacts/replay"
check "fixture precondition: no signature" "1"                "$(sign_details "$artifacts/replay" | /usr/bin/grep -c 'not signed at all')"
pl set bool true "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/HARDENED_RUNTIME
omc_run PackageBuilder.step.verify
check "refused"                  "1"                          "$(log_says 'code signature does not verify')"
check "said what would sign it"  "1"                          "$(log_says 'choose an Application identity on the Build tab')"
check "did not verify"           "1"                          "$(log_says 'not what the document says')"

section "207b. an artifact signed with a certificate gets no such advice"
# /bin/echo is signed by Apple and lacks the hardened runtime. Signing it again
# would hide the mistake, so the refusal stands on its own.
setup_replay_project
pl set bool true "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/HARDENED_RUNTIME
omc_run PackageBuilder.step.verify
check "refused"                  "1"                          "$(log_says 'not signed with the hardened runtime')"
check "no advice to sign it"     "0"                          "$(log_says 'Application identity')"

section "208. an identity this keychain does not have stops the run before verify"
pl set string "Developer ID Application: Nobody (ZZZZZZZZZZ)" "$(model_file)" /SIGNING/APPLICATION_IDENTITY
omc_run PackageBuilder.step.verify
check "named it"                 "1"                          "$(log_says 'The application identity "Developer ID Application: Nobody (ZZZZZZZZZZ)" is not in this machine')"
check "verified nothing"         "0"                          "$(log_says 'Verifying the payload:')"

section "209. with an identity, verify reports what it will sign instead of refusing"
setup_replay_project
unsigned_copy "$artifacts/replay"
adhoc_copy "$artifacts/gate" com.example.gate "$entitlements_plist"
pl set string "-" "$(model_file)" /SIGNING/APPLICATION_IDENTITY
pl set bool true "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/HARDENED_RUNTIME
pl set bool true "$(model_file)" /COMPONENTS/0/PAYLOAD/1/VERIFY/HARDENED_RUNTIME
with_identity 'clear_log; verify_payload'
check "the stage passed"         "0"                          "$?"
check "the unsigned one"         "1"                          "$(log_says 'item 1 (replay): no signature of its own - the staged copy will be signed with -')"
# An ad-hoc signature has no certificate, so it counts as none.
check "the ad-hoc one"           "1"                          "$(log_says 'item 2 (gate): no signature of its own')"
check "nothing else was said"    "0"                          "$(log_says 'signature ok')"
# Still verify-only: the artifacts folder is read, not written.
check "the artifact is untouched" "1"                         "$(sign_details "$artifacts/replay" | /usr/bin/grep -c 'not signed at all')"

section "209b. an identity the entry does not accept is refused before anything is signed"
pl set string "Developer ID Application" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/SIGNED_BY
with_identity 'clear_log; verify_payload'
check "the stage failed"         "1"                          "$?"
check "named both"               "1"                          "$(log_says 'it would be signed with "-", but it has to be signed by "Developer ID Application"')"
pl set string "" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/SIGNED_BY

section "210. staging signs the copy, and leaves the artifact as it was"
setup_replay_project
unsigned_copy "$artifacts/replay"
adhoc_copy "$artifacts/gate" com.example.gate "$entitlements_plist"
unsigned_copy "$artifacts/dispatch"
replay_hash="$(hash_of "$artifacts/replay")"
gate_hash="$(hash_of "$artifacts/gate")"
pl set string "-" "$(model_file)" /SIGNING/APPLICATION_IDENTITY
pl set bool true "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/HARDENED_RUNTIME
pl set bool true "$(model_file)" /COMPONENTS/0/PAYLOAD/1/VERIFY/HARDENED_RUNTIME
# A mode with no write bit, which codesign could not have rewritten.
pl set string "0555" "$(model_file)" /COMPONENTS/0/PAYLOAD/0/MODE
# dispatch asserts nothing and fingerprint is Apple's /bin/echo; neither is
# touched.
pl set bool true "$(model_file)" /COMPONENTS/0/PAYLOAD/3/VERIFY/HARDENED_RUNTIME
with_identity 'clear_log; stage_payload_root 0'
check "staging succeeded"        "0"                          "$?"
staged="$(state_dir)/root/usr/local/bin"
check "the copy is signed"       "1"                          "$(sign_details "$staged/replay" | /usr/bin/grep -c '^CodeDirectory .*runtime')"
check "named after itself"       "Identifier=replay"          "$(sign_details "$staged/replay" | /usr/bin/grep '^Identifier=')"
check "and said so"              "1"                          "$(log_says 'signed usr/local/bin/replay with -')"
check "its mode came after"      "555"                        "$(/usr/bin/stat -f '%Lp' "$staged/replay")"
check "the artifact is untouched" "$replay_hash"              "$(hash_of "$artifacts/replay")"
check "and still unsigned"       "1"                          "$(sign_details "$artifacts/replay" | /usr/bin/grep -c 'not signed at all')"
check "the ad-hoc one is signed" "1"                          "$(sign_details "$staged/gate" | /usr/bin/grep -c '^CodeDirectory .*runtime')"
check "keeping its identifier"   "Identifier=com.example.gate" "$(sign_details "$staged/gate" | /usr/bin/grep '^Identifier=')"
check "and its entitlements"     "1"                          "$(/usr/bin/codesign --display --entitlements - --xml "$staged/gate" 2>/dev/null | /usr/bin/grep -c 'com.apple.security.virtualization')"
# Except the debugger one, which the notary service refuses.
check "fixture precondition: the artifact has get-task-allow" "1" "$(/usr/bin/codesign --display --entitlements - --xml "$artifacts/gate" 2>/dev/null | /usr/bin/grep -c 'get-task-allow')"
check "but not get-task-allow"   "0"                          "$(/usr/bin/codesign --display --entitlements - --xml "$staged/gate" 2>/dev/null | /usr/bin/grep -c 'get-task-allow')"
check "its artifact is untouched" "$gate_hash"                "$(hash_of "$artifacts/gate")"
check "one asserting nothing is not" "1"                      "$(sign_details "$staged/dispatch" | /usr/bin/grep -c 'not signed at all')"
check "one with a certificate is not" "$(hash_of /bin/echo)"   "$(hash_of "$staged/fingerprint")"

section "210b. a signed copy is held to the entry's assertions"
# Ad-hoc signing cannot produce a secure timestamp, so asserting one proves the
# check runs on the signed copy rather than being assumed.
pl set bool true "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/SECURE_TIMESTAMP
with_identity 'clear_log; stage_payload_root 0'
check "staging failed"           "1"                          "$?"
check "on the signed copy"       "1"                          "$(log_says 'usr/local/bin/replay.*signed without a secure timestamp')"
check "and said which copy"      "1"                          "$(log_says 'this is the copy PackageBuilder signed with -')"

section "211. an app is signed inside out, and other bundles are not signed at all"
app="$OMCTEST_WORK/Fixture.app"
/bin/rm -rf "$app"
/bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers"
unsigned_copy "$app/Contents/MacOS/Fixture"
unsigned_copy "$app/Contents/Helpers/helper"
/usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string com.example.fixture "$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleExecutable -string Fixture "$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundlePackageType -string APPL "$app/Contents/Info.plist"
check "an app can be signed"     "yes"                        "$(vcheck artifact_is_signable "$app")"
check "and has nothing yet"      "yes"                        "$(vcheck artifact_lacks_certificate "$app")"
pb_build_eval "sign_artifact '$app' -"
check "signing succeeded"        "0"                          "$?"
check "the app verifies deep"    "0"                          "$(/usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1; echo $?)"
check "its helper was signed"    "0"                          "$(sign_details "$app/Contents/Helpers/helper" | /usr/bin/grep -c 'not signed at all')"
check "under its bundle id"      "Identifier=com.example.fixture" "$(sign_details "$app" | /usr/bin/grep '^Identifier=')"
framework="$OMCTEST_WORK/Fixture.framework"
/bin/rm -rf "$framework"
/bin/mkdir -p "$framework/Versions/A/Resources"
unsigned_copy "$framework/Versions/A/Fixture"
/usr/bin/plutil -create xml1 "$framework/Versions/A/Resources/Info.plist"
/usr/bin/plutil -replace CFBundleExecutable -string Fixture "$framework/Versions/A/Resources/Info.plist"
check "a framework is left alone" "no"                        "$(vcheck artifact_is_signable "$framework")"
check "a plain file is not code" "no"                         "$(vcheck artifact_is_signable "$OMCTEST_WORK/replay-readme.rtf")"

section "211b. an app staged under a name without .app is still signed and checked"
# The verify stage leaves the signature checks to staging when the SOURCE is an
# unsigned app. Deciding again on the staged copy, whose name no longer ends in
# .app, shipped it with no signature and no check at all.
setup_replay_project
/bin/rm -rf "$artifacts/Fixture.app"
/bin/cp -R "$app" "$artifacts/Fixture.app"
/usr/bin/codesign --remove-signature "$artifacts/Fixture.app/Contents/MacOS/Fixture" 2>/dev/null
/usr/bin/codesign --remove-signature "$artifacts/Fixture.app/Contents/Helpers/helper" 2>/dev/null
/bin/rm -rf "$artifacts/Fixture.app/Contents/_CodeSignature"
omc_drop "$artifacts/Fixture.app"
omc_run PackageBuilder.payload.drop
clear_payload_assertions
pl set string "-" "$(model_file)" /SIGNING/APPLICATION_IDENTITY
pl set bool true "$(model_file)" /COMPONENTS/0/PAYLOAD/4/VERIFY/HARDENED_RUNTIME
pl set string "/Applications/Fixture" "$(model_file)" /COMPONENTS/0/PAYLOAD/4/DESTINATION
with_identity 'clear_log; verify_payload'
check "verify leaves it to staging" "1"                       "$(log_says 'item 5 (Fixture.app): no signature of its own')"
# The bundled signer signs ad-hoc without the hardened runtime, so the check
# on the signed copy is what refuses it - which proves both ran.
with_identity 'clear_log; stage_payload_root 0'
check "staging refused the copy" "1"                          "$?"
check "after signing it"         "1"                          "$(log_says 'this is the copy PackageBuilder signed with -')"
check "the copy is signed"       "0"                          "$(sign_details "$(state_dir)/root/Applications/Fixture" | /usr/bin/grep -c 'not signed at all')"

section "212. the picker resolves either value channel and stores the empty string for the decline"
reset_state
omc_object ""
omc_run PackageBuilder.main.init
printf 'Developer ID Application: First (AAAAAAAAAA)\n' > "$(state_dir)/application_identities.txt"
check "row 1 is the certificate" "Developer ID Application: First (AAAAAAAAAA)" "$(pb_call resolve_application_identity_value 1)"
check "row 2 is the decline"     "__pb_no_artifact_sign__"    "$(pb_call resolve_application_identity_value 2)"
check "an index past every row"  ""                           "$(pb_call resolve_application_identity_value 3)"
check "a tag passes through"     "__pb_no_artifact_sign__"    "$(pb_call resolve_application_identity_value __pb_no_artifact_sign__)"
omc_fire PackageBuilder.field.changed $APPLICATION_IDENTITY_ID "1"
check "resolved before storing"  "Developer ID Application: First (AAAAAAAAAA)" "$(model /SIGNING/APPLICATION_IDENTITY)"
check "marked edited"            "1"                          "$(dirty)"
omc_fire PackageBuilder.field.changed $APPLICATION_IDENTITY_ID "9"
check "a stray value is ignored" "Developer ID Application: First (AAAAAAAAAA)" "$(model /SIGNING/APPLICATION_IDENTITY)"
omc_fire PackageBuilder.field.changed $APPLICATION_IDENTITY_ID ""
check "so is an empty one"       "Developer ID Application: First (AAAAAAAAAA)" "$(model /SIGNING/APPLICATION_IDENTITY)"
omc_fire PackageBuilder.field.changed $APPLICATION_IDENTITY_ID "__pb_no_artifact_sign__"
check "the decline clears it"    ""                           "$(model /SIGNING/APPLICATION_IDENTITY)"

section "212b. an identity the keychain lacks still shows"
pl set string "Developer ID Application: Elsewhere (BBBBBBBBBB)" "$(model_file)" /SIGNING/APPLICATION_IDENTITY
pb_call refresh_application_identity_picker
check "its own row"              "1"                          "$(ui_prop $APPLICATION_IDENTITY_ID options | /usr/bin/grep -c 'Elsewhere (BBBBBBBBBB) - not in this keychain')"
check "selected"                 "Developer ID Application: Elsewhere (BBBBBBBBBB)" "$(ui_value $APPLICATION_IDENTITY_ID)"
check "and resolvable by index"  "Developer ID Application: Elsewhere (BBBBBBBBBB)" "$(pb_call resolve_application_identity_value 1)"

section "213. the exported script carries the identity, and the app signer only when asked"
setup_replay_project
unsigned_copy "$artifacts/replay"
pl set bool true "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/HARDENED_RUNTIME
exported="$OMCTEST_WORK/makepkg.sign.sh"
/bin/rm -f "$exported"
omc_dialog_answer save_as "$exported"
omc_run PackageBuilder.export.script
check "sh accepts it"            "0"                          "$(/bin/sh -n "$exported" 2>/dev/null; echo $?)"
check "no identity frozen in"    "1"                          "$(/usr/bin/grep -c "^application_identity=''$" "$exported" | /usr/bin/tr -d ' ')"
check "and no app signer"        "0"                          "$(/usr/bin/grep -c 'PB_CODESIGN_APPLET' "$exported" | /usr/bin/tr -d ' ')"
/bin/sh "$exported" --unsigned --output-dir "$OMCTEST_WORK/sign-out" > "$OMCTEST_WORK/sign-run.log" 2>&1
check "the unsigned item stops it" "1"                        "$(/usr/bin/grep -c 'ERROR: replay: the code signature does not verify' "$OMCTEST_WORK/sign-run.log" | /usr/bin/tr -d ' ')"
check "with the way out"         "1"                          "$(/usr/bin/grep -c 'pass --application-identity' "$OMCTEST_WORK/sign-run.log" | /usr/bin/tr -d ' ')"
/bin/sh "$exported" --unsigned --output-dir "$OMCTEST_WORK/sign-out" --application-identity "Developer ID Application: Nobody (ZZZZZZZZZZ)" > "$OMCTEST_WORK/sign-run.log" 2>&1
check "an identity it lacks is refused" "1"                   "$(/usr/bin/grep -c 'Application identity not in this keychain' "$OMCTEST_WORK/sign-run.log" | /usr/bin/tr -d ' ')"
pl set string "Developer ID Application: Nobody (ZZZZZZZZZZ)" "$(model_file)" /SIGNING/APPLICATION_IDENTITY
/bin/rm -f "$exported"
omc_dialog_answer save_as "$exported"
omc_run PackageBuilder.export.script
check "sh accepts it with the signer" "0"                     "$(/bin/sh -n "$exported" 2>/dev/null; echo $?)"
check "the identity frozen in"   "1"                          "$(/usr/bin/grep -c "^application_identity='Developer ID Application: Nobody (ZZZZZZZZZZ)'$" "$exported" | /usr/bin/tr -d ' ')"
check "the signer written in whole" "yes"                     "$(/usr/bin/sed -n "/<<'PB_CODESIGN_APPLET'/,/^PB_CODESIGN_APPLET\$/p" "$exported" | /usr/bin/sed '1d;$d' | /usr/bin/cmp -s - "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/codesign_applet.sh" && echo yes || echo no)"
check "each item's assertions reach staging" "1"              "$(/usr/bin/grep -c "^stage_entry .* '0755' '' '1' '0'$" "$exported" | /usr/bin/tr -d ' ')"

section "214. the CLI sets it, overrides it for one build, and says where it is"
setup_replay_project
unsigned_copy "$artifacts/replay"
pl set bool true "$(model_file)" /COMPONENTS/0/PAYLOAD/0/VERIFY/HARDENED_RUNTIME
cli_doc="$OMCTEST_WORK/sign-cli.pkgbld"
/bin/cp "$(model_file)" "$cli_doc"
pbcli verify "$cli_doc" >/dev/null 2>"$OMCTEST_WORK/sign-cli.txt"
check "verify refuses it"        "1"                          "$?"
check "and names the setting"    "1"                          "$(/usr/bin/grep -c 'set SIGNING.APPLICATION_IDENTITY, or pass --application-identity' "$OMCTEST_WORK/sign-cli.txt" | /usr/bin/tr -d ' ')"
pbcli set "$cli_doc" /SIGNING/APPLICATION_IDENTITY "Developer ID Application: Nobody (ZZZZZZZZZZ)" >/dev/null 2>&1
check "set writes it"            "Developer ID Application: Nobody (ZZZZZZZZZZ)" "$(field_of "$cli_doc" /SIGNING/APPLICATION_IDENTITY)"
pbcli validate "$cli_doc" >/dev/null 2>"$OMCTEST_WORK/sign-cli.txt"
check "validate knows the key"   "0"                          "$(/usr/bin/grep -c 'unknown key\|APPLICATION_IDENTITY is' "$OMCTEST_WORK/sign-cli.txt" | /usr/bin/tr -d ' ')"
check "and checks the keychain"  "1"                          "$(/usr/bin/grep -c 'The application identity "Developer ID Application: Nobody (ZZZZZZZZZZ)" is not in this machine' "$OMCTEST_WORK/sign-cli.txt" | /usr/bin/tr -d ' ')"
pbcli set "$cli_doc" /SIGNING/APPLICATION_IDENTITY "" >/dev/null 2>&1
pbcli build "$cli_doc" --dry-run --unsigned --application-identity "Developer ID Application: Other (YYYYYYYYYY)" >/dev/null 2>"$OMCTEST_WORK/sign-cli.txt"
check "build takes it for the run" "1"                        "$(/usr/bin/grep -c 'The application identity "Developer ID Application: Other (YYYYYYYYYY)"' "$OMCTEST_WORK/sign-cli.txt" | /usr/bin/tr -d ' ')"
check "without writing it"       ""                           "$(field_of "$cli_doc" /SIGNING/APPLICATION_IDENTITY)"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids"        ""                           "$(ui_unknown_writes)"

omctest_end
