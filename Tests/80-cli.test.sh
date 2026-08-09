#!/bin/sh
# Tests/80-cli.test.sh - the agent CLI, and the traversal guards.
#
# Ported from Private/harness.sh sections 134 to 148. Most of this file is one
# defect driven through seven rounds: a destination that reaches outside the
# staging root. Each of the first five fixes was defeated by the next reviewer,
# and the lesson that finally held is in the comments - stop comparing strings,
# ask the file system.
#
# The canary directory is what makes those sections mean anything. Asserting
# only that a guard SPEAKS passes against unguarded code whenever the escape
# happens to fail for an unrelated reason, which is exactly how two broken
# rounds shipped green.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.packagebuilder.sh"

cli_path="$OMC_APP_BUNDLE_PATH/Contents/Resources/Agents/pkgbuilder"

section "134. the format verifier reads a document as written"
# Distinct from the build preconditions: this asks whether the document is
# well-formed - known keys, right types, in-range enums - which is what an
# agent assembling one by machine needs told. It reads the file before
# model_normalize can fill anything in, which is the whole point of it.
check "the CLI is present"       "yes"                        "$([ -x "$cli_path" ] && echo yes || echo no)"
/bin/mkdir -p "$OMCTEST_WORK/cli"
# The sample is well-formed, and its artifacts are not on this machine. That
# combination is the normal state of a project under construction and is
# exactly what the two halves of validate are separated to express: no format
# findings, unmet preconditions, exit 2 rather than 1.
pbcli validate "$(fixture Sample.pkgbld)" >/dev/null 2>"$OMCTEST_WORK/cli/sample.txt"
check "the sample is not an error" "2"                        "$?"
check "and the format is clean"  "1"                          "$(/usr/bin/grep -c '0 error(s), 0 warning(s)' "$OMCTEST_WORK/cli/sample.txt" | /usr/bin/tr -d ' ')"
/bin/cat > "$OMCTEST_WORK/cli/bad.pkgbld" <<'BAD'
{ "FORMAT_VERSION": 1,
  "PROJECT": { "NAME": "w", "VERSION": "1.0", "ARTIFACT_DIR": "build" },
  "COMPONENTS": [ { "IDENTIFIER": "com.example.w", "RELOCATABLE": "false", "AUTH": "root",
    "PAYLOAD": [ { "SOURCE": "s", "DESTINATION": "/usr/local/bin/w", "MODE": 755 },
                 { "DESTINATION": "/usr/local/bin/x", "MODE": "0755" } ] } ],
  "DISTRIBUTION": { "HOST_ARCHITECTURES": ["arm64","ppc"], "CUSTOMIZE": "sometimes",
    "RESOURCES": { "READ_ME": "x" } },
  "SIGNING": { "ENABLED": true, "INSTALLER_IDENTITY": "" } }
BAD
bad_report="$OMCTEST_WORK/cli/bad.txt"
pbcli validate "$OMCTEST_WORK/cli/bad.pkgbld" > /dev/null 2> "$bad_report"
check "errors mean exit 1"       "1"                          "$?"
check "a misspelled key is named" "1"                         "$(/usr/bin/grep -c 'unknown key "ARTIFACT_DIR"' "$bad_report" | /usr/bin/tr -d ' ')"
check "a string bool is refused" "1"                          "$(/usr/bin/grep -c 'RELOCATABLE is string, expected bool' "$bad_report" | /usr/bin/tr -d ' ')"
check "a numeric MODE is refused" "1"                         "$(/usr/bin/grep -c 'MODE is integer, expected string' "$bad_report" | /usr/bin/tr -d ' ')"
check "a bad enum is refused"    "1"                          "$(/usr/bin/grep -c 'AUTH is "root"' "$bad_report" | /usr/bin/tr -d ' ')"
check "a bad host arch is refused" "1"                        "$(/usr/bin/grep -c 'HOST_ARCHITECTURES lists "ppc"' "$bad_report" | /usr/bin/tr -d ' ')"
check "a missing SOURCE is named" "1"                         "$(/usr/bin/grep -c 'payload entry 2 SOURCE is missing' "$bad_report" | /usr/bin/tr -d ' ')"
# A file that is not a document at all stops at one message rather than
# reporting every key in the format as missing.
printf 'not json\n' > "$OMCTEST_WORK/cli/garbage.pkgbld"
pbcli validate "$OMCTEST_WORK/cli/garbage.pkgbld" >/dev/null 2>"$OMCTEST_WORK/cli/garbage.txt"
check "garbage exits 1"          "1"                          "$?"
check "and says so once"         "1"                          "$(/usr/bin/grep -c 'is not a JSON object' "$OMCTEST_WORK/cli/garbage.txt" | /usr/bin/tr -d ' ')"

section "135. the CLI constructs a document the app would have written"
/bin/rm -rf "$OMCTEST_WORK/cli/build"; /bin/mkdir -p "$OMCTEST_WORK/cli/build" "$OMCTEST_WORK/cli/dist"
/bin/cp /bin/echo "$OMCTEST_WORK/cli/build/widget"
cli_doc="$OMCTEST_WORK/cli/Widget.pkgbld"
pbcli new "$cli_doc" --name widget --identifier com.example.pkg.widget --version 1.0 \
    --min-os 10.15 --artifacts-dir "$OMCTEST_WORK/cli/build" --output-dir "$OMCTEST_WORK/cli/dist" \
    --no-signing >/dev/null 2>&1
check "the document was written" "yes"                        "$([ -f "$cli_doc" ] && echo yes || echo no)"
# A document with no payload yet is well-formed and builds nothing, which the
# verifier says out loud rather than passing in silence.
pbcli validate "$cli_doc" >/dev/null 2>"$OMCTEST_WORK/cli/empty.txt"
check "an empty payload warns"   "2"                          "$?"
check "and says which"           "1"                          "$(/usr/bin/grep -c 'the payload is empty' "$OMCTEST_WORK/cli/empty.txt" | /usr/bin/tr -d ' ')"
# The folders are stored relative to the document, as the window stores them.
check "artifacts stored relative" "build"                     "$(field_of "$cli_doc" /PROJECT/ARTIFACTS_DIR)"
check "output stored relative"   "dist"                       "$(field_of "$cli_doc" /PROJECT/OUTPUT_DIR)"
cli_index="$(pbcli add-payload "$cli_doc" "$OMCTEST_WORK/cli/build/widget" 2>/dev/null)"
check "the entry index is printed" "0"                        "$cli_index"
check "the source is tokenized"  '${ARTIFACTS_DIR}/widget'    "$(field_of "$cli_doc" /COMPONENTS/0/PAYLOAD/0/SOURCE)"
check "the destination is guessed" "/usr/local/bin/widget"    "$(field_of "$cli_doc" /COMPONENTS/0/PAYLOAD/0/DESTINATION)"
# set refuses what the app cannot read, which is the reason it exists.
pbcli set "$cli_doc" /PROJECT/NAEM x >/dev/null 2>&1
check "an unknown key is refused" "1"                         "$?"
pbcli set "$cli_doc" /COMPONENTS/0/AUTH root >/dev/null 2>&1
check "a bad enum is refused"    "1"                          "$?"
pbcli set "$cli_doc" /SIGNING/ENABLED maybe >/dev/null 2>&1
check "a non-boolean is refused" "1"                          "$?"
check "and none of it landed"    "widget"                     "$(field_of "$cli_doc" /PROJECT/NAME)"
pbcli set "$cli_doc" /COMPONENTS/0/PAYLOAD/0/VERIFY/ARCHITECTURES "x86_64,arm64e" >/dev/null 2>&1
check "an arch list is written"  "0"                          "$?"
# Read straight out of the .pkgbld. The proof of concept staged a .json copy
# here, because plister picked its format from the extension alone; it falls
# back to the file's content now (design 12.2).
check "as an array of two"       "2"                          "$(pl get count "$cli_doc" /COMPONENTS/0/PAYLOAD/0/VERIFY/ARCHITECTURES 2>/dev/null | /usr/bin/tr -d ' ')"
check "with the names given"     "arm64e"                     "$(field_of "$cli_doc" /COMPONENTS/0/PAYLOAD/0/VERIFY/ARCHITECTURES/1)"
# And now that it has a payload and its artifacts are on this disk, the whole
# document is clean on both halves.
check "the document validates clean" "0"                      "$(pbcli validate "$cli_doc" >/dev/null 2>&1; echo $?)"

section "136. --dry-run exercises everything and writes nothing"
pbcli set "$cli_doc" /COMPONENTS/0/PAYLOAD/0/VERIFY/HARDENED_RUNTIME false >/dev/null 2>&1
pbcli set "$cli_doc" /COMPONENTS/0/PAYLOAD/0/VERIFY/SECURE_TIMESTAMP false >/dev/null 2>&1
pbcli set "$cli_doc" /COMPONENTS/0/PAYLOAD/0/VERIFY/SIGNED_BY "" >/dev/null 2>&1
dry_report="$OMCTEST_WORK/cli/dry.txt"
pbcli build "$cli_doc" --dry-run >/dev/null 2>"$dry_report"
check "the dry run succeeded"    "0"                          "$?"
check "the payload was verified" "1"                          "$(/usr/bin/grep -c 'built for x86_64 arm64e' "$dry_report" | /usr/bin/tr -d ' ')"
check "the staging plan is shown" "1"                         "$(/usr/bin/grep -c 'usr/local/bin/widget' "$dry_report" | /usr/bin/tr -d ' ')"
check "the real XML is generated" "1"                         "$(/usr/bin/grep -c 'hostArchitectures="arm64,x86_64"' "$dry_report" | /usr/bin/tr -d ' ')"
check "and it says it wrote nothing" "1"                      "$(/usr/bin/grep -c 'this was a dry run' "$dry_report" | /usr/bin/tr -d ' ')"
check "the output folder is empty" "0"                        "$(/usr/bin/find "$OMCTEST_WORK/cli/dist" -name '*.pkg' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
# A document that cannot build says so without building anything.
pbcli set "$cli_doc" /COMPONENTS/0/PAYLOAD/0/VERIFY/ARCHITECTURES "arm64" >/dev/null 2>&1
pbcli build "$cli_doc" --dry-run >/dev/null 2>"$OMCTEST_WORK/cli/dry2.txt"
check "a bad assertion stops it" "1"                          "$?"
check "and names the mistake"    "1"                          "$(/usr/bin/grep -c 'not built for arm64' "$OMCTEST_WORK/cli/dry2.txt" | /usr/bin/tr -d ' ')"
pbcli set "$cli_doc" /COMPONENTS/0/PAYLOAD/0/VERIFY/ARCHITECTURES "x86_64,arm64e" >/dev/null 2>&1

section "137. the CLI builds the same package the app builds"
# Snapshot the state-directory glob before the build. It is keyed by the CLI
# process's own pid, which this file cannot know in advance, and it is shared
# with every other pkgbuilder alive on the machine - so counting the glob
# outright reports a phantom failure whenever one is running. Only a directory
# that appears during this build and then stays is ours to complain about.
/bin/mkdir -p "$OMCTEST_WORK/cli"
/bin/ls -d "${TMPDIR:-/tmp}"/packagebuilder-state-CLI-* 2>/dev/null | /usr/bin/sort > "$OMCTEST_WORK/cli/state_before.txt"
cli_pkg="$(pbcli build "$cli_doc" 2>/dev/null)"
check "a package was built"      "yes"                        "$([ -n "$cli_pkg" ] && [ -f "$cli_pkg" ] && echo yes || echo no)"
/bin/rm -rf "$OMCTEST_WORK/cli/expand"
/usr/sbin/pkgutil --expand "$cli_pkg" "$OMCTEST_WORK/cli/expand" >/dev/null 2>&1
# The two patches design 8.1 and 8.2 exist for, applied by the same library
# code the window drives.
check "overwrite-permissions"    'overwrite-permissions="false"' "$(pkginfo_attr "$OMCTEST_WORK/cli/expand/widget.pkg" overwrite-permissions)"
check "relocatable"              'relocatable="false"'        "$(pkginfo_attr "$OMCTEST_WORK/cli/expand/widget.pkg" relocatable)"
check "the identifier"           "1"                          "$(/usr/bin/grep -c 'identifier="com.example.pkg.widget"' "$OMCTEST_WORK/cli/expand/widget.pkg/PackageInfo" | /usr/bin/tr -d ' ')"
# inspect reads it back.
pbcli inspect "$cli_pkg" > "$OMCTEST_WORK/cli/inspect.txt" 2>/dev/null
check "inspect succeeded"        "0"                          "$?"
check "and reports the payload"  "1"                          "$(/usr/bin/grep -c 'usr/local/bin/widget' "$OMCTEST_WORK/cli/inspect.txt" | /usr/bin/tr -d ' ')"
# No state directory survives a run, including the one the build used.
/bin/ls -d "${TMPDIR:-/tmp}"/packagebuilder-state-CLI-* 2>/dev/null | /usr/bin/sort > "$OMCTEST_WORK/cli/state_after.txt"
check "no scratch left behind"   "0"                          "$(/usr/bin/comm -13 "$OMCTEST_WORK/cli/state_before.txt" "$OMCTEST_WORK/cli/state_after.txt" | /usr/bin/grep -c . | /usr/bin/tr -d ' ')"

section "138. a destination may not climb out of the staging root"
# Staging is a ditto into "$staging_root/$destination", and the install-location
# gate is a literal prefix test, so ".." passed it while naming somewhere else
# entirely: a document could write anywhere the invoking user could, over
# anything already there. Found in review, 2026-08-07.
trav_doc="$OMCTEST_WORK/cli/trav.pkgbld"
pbcli new "$trav_doc" --name Trav --identifier com.example.pkg.trav --version 1.0 \
    --artifacts-dir "$OMCTEST_WORK/cli/build" --output-dir "$OMCTEST_WORK/cli/dist" --no-signing >/dev/null 2>&1
pbcli add-payload "$trav_doc" "$OMCTEST_WORK/cli/build/widget" >/dev/null 2>&1
pbcli set "$trav_doc" /COMPONENTS/0/PAYLOAD/0/VERIFY/ARCHITECTURES "x86_64,arm64e" >/dev/null 2>&1
pbcli set "$trav_doc" /COMPONENTS/0/PAYLOAD/0/VERIFY/HARDENED_RUNTIME false >/dev/null 2>&1
pbcli set "$trav_doc" /COMPONENTS/0/PAYLOAD/0/VERIFY/SECURE_TIMESTAMP false >/dev/null 2>&1
pbcli set "$trav_doc" /COMPONENTS/0/PAYLOAD/0/VERIFY/SIGNED_BY "" >/dev/null 2>&1
# The destination the guard has to stop. It is checked first that this document
# is otherwise buildable, so that a refusal below is the guard talking and not
# some unrelated precondition: without that, "the build failed" and "nothing
# escaped" would both pass against unguarded code, for the wrong reason.
pbcli set "$trav_doc" /COMPONENTS/0/PAYLOAD/0/DESTINATION "/usr/local/bin/widget" >/dev/null 2>&1
check "the document builds before the climb" "0"              "$(pbcli build "$trav_doc" >/dev/null 2>&1; echo $?)"
# Where the climb lands is deliberately not asserted here. The staging root sits
# under TMPDIR, so the number of ".." needed to reach any particular directory
# depends on how deep TMPDIR is on this machine - and an over-long climb stops
# at a root-owned mkdir, which looks like a refusal but is not one. What is
# asserted instead is that the guard itself speaks, in both frontends' gates.
pbcli set "$trav_doc" /COMPONENTS/0/PAYLOAD/0/DESTINATION "/usr/local/bin/../../../../ESCAPED/widget" >/dev/null 2>&1
pbcli validate "$trav_doc" > "$OMCTEST_WORK/cli/trav-validate.txt" 2>&1
check "validate refuses the climb" "1"                        "$(/usr/bin/grep -c 'must not contain' "$OMCTEST_WORK/cli/trav-validate.txt" | /usr/bin/tr -d ' ')"
pbcli build "$trav_doc" > "$OMCTEST_WORK/cli/trav-build.txt" 2>&1
check "and so does a build"      "1"                          "$?"
check "the build named the reason" "1"                        "$(/usr/bin/grep -c 'must not contain' "$OMCTEST_WORK/cli/trav-build.txt" | /usr/bin/tr -d ' ')"
check "it stopped before staging" "0"                         "$(/usr/bin/grep -c 'Staging the payload root' "$OMCTEST_WORK/cli/trav-build.txt" | /usr/bin/tr -d ' ')"
# A name that merely begins with dots is not a climb and must still work.
pbcli set "$trav_doc" /COMPONENTS/0/PAYLOAD/0/DESTINATION "/usr/local/bin/..widget" >/dev/null 2>&1
check "but \"..widget\" is fine" "0"                          "$(pbcli build "$trav_doc" >/dev/null 2>&1; echo $?)"

# The importer is the trust boundary the review actually came through: a
# .pkgproj is someone else's file, and its scaffold node names become
# destinations. Refused there too, so no document is written at all.
trav_proj="$OMCTEST_WORK/cli/hostile.pkgproj"
pl set dict "$trav_proj" /
pl insert PACKAGES array "$trav_proj" /
pl append dict "$trav_proj" /PACKAGES 2>/dev/null || pl insert 0 dict "$trav_proj" /PACKAGES
pl insert PACKAGE_SETTINGS dict "$trav_proj" /PACKAGES/0
pl insert NAME string "Hostile" "$trav_proj" /PACKAGES/0/PACKAGE_SETTINGS
pl insert IDENTIFIER string "com.example.pkg.hostile" "$trav_proj" /PACKAGES/0/PACKAGE_SETTINGS
pl insert VERSION string "1.0" "$trav_proj" /PACKAGES/0/PACKAGE_SETTINGS
pl insert PACKAGE_FILES dict "$trav_proj" /PACKAGES/0
pl insert HIERARCHY dict "$trav_proj" /PACKAGES/0/PACKAGE_FILES
trav_root=/PACKAGES/0/PACKAGE_FILES/HIERARCHY
pl insert TYPE integer 1 "$trav_proj" "$trav_root"
pl insert PATH string "/" "$trav_proj" "$trav_root"
pl insert CHILDREN array "$trav_proj" "$trav_root"
pl append dict "$trav_proj" "$trav_root/CHILDREN" 2>/dev/null || pl insert 0 dict "$trav_proj" "$trav_root/CHILDREN"
pl insert TYPE integer 1 "$trav_proj" "$trav_root/CHILDREN/0"
pl insert PATH string "../../../../ESCAPED" "$trav_proj" "$trav_root/CHILDREN/0"
pl insert CHILDREN array "$trav_proj" "$trav_root/CHILDREN/0"
pl append dict "$trav_proj" "$trav_root/CHILDREN/0/CHILDREN" 2>/dev/null || pl insert 0 dict "$trav_proj" "$trav_root/CHILDREN/0/CHILDREN"
pl insert TYPE integer 3 "$trav_proj" "$trav_root/CHILDREN/0/CHILDREN/0"
pl insert PATH_TYPE integer 0 "$trav_proj" "$trav_root/CHILDREN/0/CHILDREN/0"
pl insert PATH string "$OMCTEST_WORK/cli/build/widget" "$trav_proj" "$trav_root/CHILDREN/0/CHILDREN/0"
/bin/rm -f "$OMCTEST_WORK/cli/imported.pkgbld"
pbcli import-pkgproj "$trav_proj" "$OMCTEST_WORK/cli/imported.pkgbld" --force > "$OMCTEST_WORK/cli/trav-import.txt" 2>&1
check "import refuses the climb" "1"                          "$(/usr/bin/grep -c 'contains "\.\." and was refused' "$OMCTEST_WORK/cli/trav-import.txt" | /usr/bin/tr -d ' ')"
check "and writes no document"   "no"                         "$([ -e "$OMCTEST_WORK/cli/imported.pkgbld" ] && echo yes || echo no)"

# ".." is one spelling of a non-canonical path; "." and "//" are others, and
# they defeat the nesting check the same way, without ever tripping the ".."
# refusal. Combined with a symlink arriving in an EARLIER payload entry, that
# was a live arbitrary write: ditto follows the link out of the staging root.
# The first fix for this section refused ".." by name and left this open - the
# lesson being that the answer is to normalize once, not to enumerate spellings.
# Found in the review of that fix, 2026-08-07.
sym_escape="$OMCTEST_WORK/cli/ESCAPE"
/bin/rm -rf "$sym_escape" "$OMCTEST_WORK/cli/build/d"; /bin/mkdir -p "$sym_escape" "$OMCTEST_WORK/cli/build/d"
/bin/ln -s "$sym_escape" "$OMCTEST_WORK/cli/build/d/sub"
printf 'payload\n' > "$OMCTEST_WORK/cli/build/pwned.txt"
sym_doc="$OMCTEST_WORK/cli/symlink.pkgbld"
pbcli new "$sym_doc" --name Sym --identifier com.example.pkg.sym --version 1.0 \
    --artifacts-dir "$OMCTEST_WORK/cli/build" --output-dir "$OMCTEST_WORK/cli/dist" --no-signing >/dev/null 2>&1
pbcli add-payload "$sym_doc" "$OMCTEST_WORK/cli/build/d" --destination /opt/demo/d --mode 0755 --no-verify >/dev/null 2>&1
pbcli add-payload "$sym_doc" "$OMCTEST_WORK/cli/build/pwned.txt" --destination '/opt/demo//d/sub/pwned.txt' --no-verify >/dev/null 2>&1
pbcli build "$sym_doc" > "$OMCTEST_WORK/cli/sym-build.txt" 2>&1
check "a doubled slash cannot hide nesting" "1"               "$(/usr/bin/grep -c 'installs inside' "$OMCTEST_WORK/cli/sym-build.txt" | /usr/bin/tr -d ' ')"
check "and nothing followed the symlink out" "0"              "$(/bin/ls -A "$sym_escape" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
# The same with a "." component, which hides nesting just as well.
pbcli set "$sym_doc" /COMPONENTS/0/PAYLOAD/1/DESTINATION '/opt/demo/./d/sub/pwned.txt' >/dev/null 2>&1
pbcli build "$sym_doc" > "$OMCTEST_WORK/cli/sym-build2.txt" 2>&1
check "nor can a dot component"  "1"                          "$(/usr/bin/grep -c 'installs inside' "$OMCTEST_WORK/cli/sym-build2.txt" | /usr/bin/tr -d ' ')"
check "still nothing outside"    "0"                          "$(/bin/ls -A "$sym_escape" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
# A genuinely separate destination is not nesting and must still build.
pbcli set "$sym_doc" /COMPONENTS/0/PAYLOAD/1/DESTINATION '/opt/demo/beside.txt' >/dev/null 2>&1
check "but a sibling destination builds" "0"                  "$(pbcli build "$sym_doc" >/dev/null 2>&1; echo $?)"

section "139. an option at the end of the command line"
# "shift 2" with one argument left shifts nothing and returns non-zero under
# /bin/sh, so the option loop spun forever at full CPU with no output. A
# truncated command line is an ordinary thing for an agent to produce.
( pbcli new "$OMCTEST_WORK/cli/never.pkgbld" --name Foo --identifier com.x.y --version ) \
    > "$OMCTEST_WORK/cli/trunc.txt" 2>&1 &
trunc_pid=$!
trunc_waited=0
while [ "$trunc_waited" -lt 10 ] && /bin/kill -0 "$trunc_pid" 2>/dev/null; do
    /bin/sleep 1
    trunc_waited=$((trunc_waited + 1))
done
if /bin/kill -0 "$trunc_pid" 2>/dev/null; then
    /bin/kill -9 "$trunc_pid" 2>/dev/null
    check "a truncated option exits" "yes"                    "no (still running after ${trunc_waited}s)"
else
    wait "$trunc_pid" 2>/dev/null
    check "a truncated option exits" "yes"                    "yes"
fi
check "and says what was missing" "1"                         "$(/usr/bin/grep -c 'requires a value' "$OMCTEST_WORK/cli/trunc.txt" | /usr/bin/tr -d ' ')"
check "no document was written"  "no"                         "$([ -e "$OMCTEST_WORK/cli/never.pkgbld" ] && echo yes || echo no)"
# An option where a value belongs is a mistake, not a value.
pbcli new "$OMCTEST_WORK/cli/never2.pkgbld" --name --force --identifier com.x.y > "$OMCTEST_WORK/cli/trunc2.txt" 2>&1
check "an option is not a value" "1"                          "$(/usr/bin/grep -c 'got the option' "$OMCTEST_WORK/cli/trunc2.txt" | /usr/bin/tr -d ' ')"

section "140. set reports what actually happened"
# plister cannot create a key whose parent container is missing, and the status
# was being discarded: every command returned 0 and the document came out with
# the fields absent - the worst possible outcome for an agent building a
# document one command at a time.
pbcli set "$cli_doc" /COMPONENTS/0/PAYLOAD/7/SOURCE /tmp/nowhere > "$OMCTEST_WORK/cli/setidx.txt" 2>&1
check "a missing entry is refused" "1"                        "$?"
check "and is named"             "1"                          "$(/usr/bin/grep -c 'no payload entry 8' "$OMCTEST_WORK/cli/setidx.txt" | /usr/bin/tr -d ' ')"
check "the entry that exists still takes writes" "0"          "$(pbcli set "$cli_doc" /COMPONENTS/0/PAYLOAD/0/OWNER root >/dev/null 2>&1; echo $?)"
check "and the write is there"   "root"                       "$(field_of "$cli_doc" /COMPONENTS/0/PAYLOAD/0/OWNER)"

section "141. the verifier tells absent from present-and-empty"
# "get value" prints nothing for an empty string, an empty dict and an empty
# array alike, so testing the value reported {} and [] as clean.
/bin/cp "$cli_doc" "$OMCTEST_WORK/cli/empty-enum.pkgbld"
pl set dict "$OMCTEST_WORK/cli/empty-enum.pkgbld" /COMPONENTS/0/AUTH
pbcli validate "$OMCTEST_WORK/cli/empty-enum.pkgbld" > "$OMCTEST_WORK/cli/empty-enum.txt" 2>&1
check "an empty dict where an enum goes" "1"                  "$(/usr/bin/grep -c 'AUTH is dict' "$OMCTEST_WORK/cli/empty-enum.txt" | /usr/bin/tr -d ' ')"
/bin/cp "$cli_doc" "$OMCTEST_WORK/cli/empty-mode.pkgbld"
pl set string "" "$OMCTEST_WORK/cli/empty-mode.pkgbld" /COMPONENTS/0/PAYLOAD/0/MODE
pbcli validate "$OMCTEST_WORK/cli/empty-mode.pkgbld" > "$OMCTEST_WORK/cli/empty-mode.txt" 2>&1
check "an empty MODE"            "1"                          "$(/usr/bin/grep -c 'MODE "" must be three or four octal digits' "$OMCTEST_WORK/cli/empty-mode.txt" | /usr/bin/tr -d ' ')"

section "142. a component script keeps its tokens through export"
# These are paths and may carry ${ARTIFACTS_DIR} like any other path. Frozen as
# literal text, the exported script demanded --artifacts-dir and then ignored
# it, failing on the copy - so every such export was dead on arrival.
printf '#!/bin/sh\nexit 0\n' > "$OMCTEST_WORK/cli/build/pre.sh"; /bin/chmod 755 "$OMCTEST_WORK/cli/build/pre.sh"
pbcli set "$cli_doc" /COMPONENTS/0/PREINSTALL '${ARTIFACTS_DIR}/pre.sh' >/dev/null 2>&1
pbcli export-script "$cli_doc" "$OMCTEST_WORK/cli/tokens.sh" >/dev/null 2>&1
check "the token is not frozen"  "0"                          "$(/usr/bin/grep -c 'cp .\${ARTIFACTS_DIR}/pre.sh' "$OMCTEST_WORK/cli/tokens.sh" | /usr/bin/tr -d ' ')"
check "it resolves at run time"  "1"                          "$(/usr/bin/grep -c 'artifacts_dir"./pre.sh' "$OMCTEST_WORK/cli/tokens.sh" | /usr/bin/tr -d ' ')"
/bin/sh "$OMCTEST_WORK/cli/tokens.sh" --artifacts-dir "$OMCTEST_WORK/cli/build" --output-dir "$OMCTEST_WORK/cli/dist" --unsigned \
    > "$OMCTEST_WORK/cli/tokens-run.txt" 2>&1
check "and the script runs"      "0"                          "$?"
# pkgbuild's own line, not the exporter's "preinstall script is not there",
# which contains the same words and made this pass on a failed run.
check "with the preinstall added" "1"                         "$(/usr/bin/grep -c 'Adding top-level preinstall script' "$OMCTEST_WORK/cli/tokens-run.txt" | /usr/bin/tr -d ' ')"
pbcli set "$cli_doc" /COMPONENTS/0/PREINSTALL "" >/dev/null 2>&1

section "143. a destination may not reach the same directory by another spelling"
# Sections 138 to 142 refused ".." and then the "." and "//" spellings, and both
# rounds were got past, because the escape is not a spelling at all. The staging
# root lives under TMPDIR on APFS, which folds case AND folds NFD to NFC: two
# destinations that compare unequal in the shell can be one directory on disk.
# Add a symlink arriving inside an earlier entry's source tree and "mkdir -p"
# walks straight out. No lexical rewrite can see any of that; only asking the
# file system after the mkdir can.
#
# The canary directory is the point. Section 138 only ever asserted that the
# guard SPEAKS, which passes against unguarded code whenever the climb happens
# to fail for an unrelated reason - that is exactly how two broken rounds
# shipped green. These assert that the tree outside the root is untouched.
trav="$OMCTEST_WORK/traversal"
/bin/rm -rf "$trav"
/bin/mkdir -p "$trav/tree" "$trav/canary" "$trav/out"
printf 'PWNED\n' > "$trav/evil.txt"
printf 'ok\n' > "$trav/tree/real.txt"
/bin/ln -s "$trav/canary" "$trav/tree/escape"
# RECURSIVE, not a top-level count. "ls -A | wc -l" cannot see a write nested
# under an entry that already exists, and cannot see an overwrite of an existing
# file at all - so it would report "clean" for two of the three things an escape
# actually does.
canary_state() { /usr/bin/find "$trav/canary" | /usr/bin/sort; }
canary_before="$(canary_state)"

# (a) Case: "DIR" and "dir" are one directory on APFS.
case_doc="$trav/Case.pkgbld"
pbcli new "$case_doc" --name Case --identifier com.example.case --version 1.0 >/dev/null 2>&1
pbcli add-payload "$case_doc" "$trav/tree"     --destination /opt/demo/DIR --mode 0755 >/dev/null 2>&1
pbcli add-payload "$case_doc" "$trav/evil.txt" --destination /opt/demo/dir/escape/sub/PWNED.txt --mode 0644 >/dev/null 2>&1
pbcli build "$case_doc" --output-dir "$trav/out" --unsigned > "$trav/case.txt" 2>&1
# Refused at the PRECONDITIONS now, not at staging: the nesting gate became
# fold-aware in the same round, and it sees this collision first. Asserting the
# staging guard's message here would be asserting a guard that never runs - the
# trap that killed section 144's usefulness one round earlier. The staging guard
# is still exercised, directly, in 143d.
check "the case variant is refused" "1"                       "$(/usr/bin/grep -c 'installs inside item 1' "$trav/case.txt" | /usr/bin/tr -d ' ')"
check "and nothing was built"     "1"                         "$(/usr/bin/grep -c 'nothing was written' "$trav/case.txt" | /usr/bin/tr -d ' ')"
check "nothing reached the canary" "$canary_before"           "$(canary_state)"

# (b) Unicode: the NFC and NFD spellings of an accented name are one directory,
# and they print identically, so the log is not a witness either.
nfc="$(/usr/bin/python3 -c 'import unicodedata; print(unicodedata.normalize("NFC", "café"))')"
nfd="$(/usr/bin/python3 -c 'import unicodedata; print(unicodedata.normalize("NFD", "café"))')"
uni_doc="$trav/Uni.pkgbld"
pbcli new "$uni_doc" --name Uni --identifier com.example.uni --version 1.0 >/dev/null 2>&1
pbcli add-payload "$uni_doc" "$trav/tree"     --destination "/opt/$nfc" --mode 0755 >/dev/null 2>&1
pbcli add-payload "$uni_doc" "$trav/evil.txt" --destination "/opt/$nfd/escape/sub/PWNED.txt" --mode 0644 >/dev/null 2>&1
pbcli build "$uni_doc" --output-dir "$trav/out" --unsigned > "$trav/uni.txt" 2>&1
check "the NFD variant is refused" "1"                        "$(/usr/bin/grep -c 'installs inside item 1' "$trav/uni.txt" | /usr/bin/tr -d ' ')"
check "nothing reached the canary" "$canary_before"           "$(canary_state)"

# (c) The leaf, which the parent check cannot cover: ditto of a DIRECTORY onto an
# existing symlink writes through it, and chmod without -h follows it. The
# destinations differ only in case on purpose - spelled identically, the sibling
# nesting precondition refuses the document long before staging, and this check
# would pass without ever reaching the guard it names. Spelled this way the
# parent resolves INSIDE the root (to opt/LEAF) and only the leaf is the escape.
leaf_doc="$trav/Leaf.pkgbld"
/bin/mkdir -p "$trav/dir2"; printf 'y\n' > "$trav/dir2/inner.txt"
pbcli new "$leaf_doc" --name Leaf --identifier com.example.leaf --version 1.0 >/dev/null 2>&1
pbcli add-payload "$leaf_doc" "$trav/tree"  --destination /opt/LEAF --mode 0755 >/dev/null 2>&1
pbcli add-payload "$leaf_doc" "$trav/dir2"  --destination /opt/leaf/escape --mode 0755 >/dev/null 2>&1
pbcli build "$leaf_doc" --output-dir "$trav/out" --unsigned > "$trav/leaf.txt" 2>&1
check "the leaf collision is refused" "1"                     "$(/usr/bin/grep -c 'installs inside item 1' "$trav/leaf.txt" | /usr/bin/tr -d ' ')"
check "nothing reached the canary" "$canary_before"           "$(canary_state)"

# Positive control: the same shape without the collision still builds. A guard
# that refuses everything would pass every check above.
good_doc="$trav/Good.pkgbld"
pbcli new "$good_doc" --name Good --identifier com.example.good --version 1.0 >/dev/null 2>&1
pbcli add-payload "$good_doc" "$trav/tree"     --destination /opt/demo/one --mode 0755 >/dev/null 2>&1
pbcli add-payload "$good_doc" "$trav/evil.txt" --destination /opt/demo/two/file.txt --mode 0644 >/dev/null 2>&1
pbcli build "$good_doc" --output-dir "$trav/out" --unsigned > "$trav/good.txt" 2>&1
check "two ordinary entries stage" "2"                        "$(/usr/bin/grep -c '  staged opt/demo/' "$trav/good.txt" | /usr/bin/tr -d ' ')"

section "143d. the staging guard holds even with the preconditions bypassed"
# stage_payload_root re-checks containment on the reasoning that the one function
# turning a destination into a path it writes to should not trust that somebody
# else looked. Now that the nesting precondition is fold-aware it refuses these
# documents first, so the only way to exercise that layer is to call the stage
# directly - which is also exactly the trust boundary it exists for.
reset_state
omc_object "$case_doc"
omc_run PackageBuilder.main.init
stage_rc="$(pb_build_call stage_payload_root >/dev/null 2>&1; echo $?)"
check "the stage refuses it"     "1"                          "$stage_rc"
check "and names the payload root" "1"                        "$(log_says 'resolves outside the payload root')"
check "nothing reached the canary" "$canary_before"           "$(canary_state)"
# Positive control: a document with no collision stages cleanly through the same
# direct call, so the guard is not simply refusing everything.
reset_state
omc_object "$good_doc"
omc_run PackageBuilder.main.init
good_rc="$(pb_build_call stage_payload_root >/dev/null 2>&1; echo $?)"
check "an ordinary document stages" "0"                       "$good_rc"
# A witness, because stage_payload_root also returns 0 for a document with no
# payload at all: if the init above ever stopped loading the document, the
# control would keep passing and stop controlling anything.
check_exists "and the tree is really there" "$(state_dir)/root/opt/demo/one/real.txt"

section "144. the exported script refuses what the app refuses"
# The three earlier rounds all landed in check_preconditions and
# stage_payload_root. The generator was never touched, so the app refused the
# document and then handed you a script that built it anyway - and export
# deliberately does not run the preconditions, so nothing stopped it. The
# emitted stage_entry carries its own copy of the guard, because it runs on a
# build machine where no library exists.
exp_dir="$trav/export"
/bin/mkdir -p "$exp_dir"
dots="/opt/../../../../../../../../../../../../../../../../../../../..$trav/canary/EXPORTED.txt"
dots_doc="$trav/Dots.pkgbld"
pbcli new "$dots_doc" --name Dots --identifier com.example.dots --version 1.0 >/dev/null 2>&1
pbcli add-payload "$dots_doc" "$trav/evil.txt" --destination "$dots" --mode 0644 >/dev/null 2>&1
pbcli export-script "$dots_doc" "$exp_dir/dots.sh" >/dev/null 2>&1
check "the script was exported"  "yes"                        "$([ -f "$exp_dir/dots.sh" ] && echo yes || echo no)"
/bin/sh "$exp_dir/dots.sh" --output-dir "$exp_dir/out" --unsigned > "$trav/dots-run.txt" 2>&1
check "and it refuses \"..\""    "1"                          "$(/usr/bin/grep -c 'must not contain' "$trav/dots-run.txt" | /usr/bin/tr -d ' ')"
check "nothing reached the canary" "$canary_before"           "$(canary_state)"

pbcli export-script "$case_doc" "$exp_dir/case.sh" >/dev/null 2>&1
/bin/sh "$exp_dir/case.sh" --output-dir "$exp_dir/out" --unsigned > "$trav/case-run.txt" 2>&1
check "and the case variant too" "1"                          "$(/usr/bin/grep -c 'resolves outside the payload root' "$trav/case-run.txt" | /usr/bin/tr -d ' ')"
check "nothing reached the canary" "$canary_before"           "$(canary_state)"

# The vector this section is actually named for, and the one it was missing: a
# document the APP refuses at the preconditions, exported anyway (export does not
# run them, by design), and then built by the generated script. The trailing
# slash is the whole trick - "dirname" strips it, so the containment test looks
# at the symlink's parent and passes, and "[ -L x/ ]" is FALSE because the kernel
# resolves the link, while "ditto" still writes straight through it.
/bin/mkdir -p "$trav/tree2"
printf 'PWNED\n' > "$trav/tree2/pwned.txt"
nest_doc="$trav/Nest.pkgbld"
pbcli new "$nest_doc" --name Nest --identifier com.example.nest --version 1.0 >/dev/null 2>&1
pbcli add-payload "$nest_doc" "$trav/tree"  --destination /opt/nest      --mode 0755 >/dev/null 2>&1
pbcli add-payload "$nest_doc" "$trav/tree2" --destination '/opt/nest/escape/' --mode 0755 >/dev/null 2>&1
pbcli build "$nest_doc" --output-dir "$trav/out" --unsigned > "$trav/nest.txt" 2>&1
check "the app refuses the nesting" "1"                       "$(/usr/bin/grep -c 'installs inside item 1' "$trav/nest.txt" | /usr/bin/tr -d ' ')"
pbcli export-script "$nest_doc" "$exp_dir/nest.sh" >/dev/null 2>&1
/bin/sh "$exp_dir/nest.sh" --output-dir "$exp_dir/out" --unsigned > "$trav/nest-run.txt" 2>&1
check "and so does its exported script" "1"                   "$(/usr/bin/grep -c 'installs inside' "$trav/nest-run.txt" | /usr/bin/tr -d ' ')"
# Named for what it asserts. The trailing-slash leaf guard is NOT what refuses
# this document - the sibling-nesting check gets there first, which is why 146b
# exists and spells its destinations to differ only in case. Removing
# pb_normalize_path from the emitted script reddens 146b and leaves this whole
# section green, so claiming the slash here would be claiming coverage twice.
check "and did not reach DONE"   "0"                          "$(/usr/bin/grep -c '== DONE ==' "$trav/nest-run.txt" | /usr/bin/tr -d ' ')"
check "nothing reached the canary" "$canary_before"           "$(canary_state)"

# Positive control again: the exported script must still build a good document.
pbcli export-script "$good_doc" "$exp_dir/good.sh" >/dev/null 2>&1
/bin/sh "$exp_dir/good.sh" --output-dir "$exp_dir/out" --unsigned > "$trav/good-run.txt" 2>&1
check "a good document exports and builds" "1"                "$(/usr/bin/grep -c '== DONE ==' "$trav/good-run.txt" | /usr/bin/tr -d ' ')"

section "145. a presentation resource must name a file"
# basename of a path ending in "/.." is "..", and resolve_stored_path does not
# canonicalize - so the copy aimed at the state directory itself and clobbered
# model.json and the staging root mid-run.
/bin/mkdir -p "$trav/rsrc/inner"
printf 'readme\n' > "$trav/rsrc/README.txt"
res_doc="$trav/Res.pkgbld"
pbcli new "$res_doc" --name Res --identifier com.example.res --version 1.0 >/dev/null 2>&1
pbcli add-payload "$res_doc" "$trav/evil.txt" --destination /opt/res/f.txt --mode 0644 >/dev/null 2>&1
pbcli set "$res_doc" /DISTRIBUTION/RESOURCES/README "$trav/rsrc/inner/.." >/dev/null 2>&1
pbcli build "$res_doc" --output-dir "$trav/out" --unsigned > "$trav/res.txt" 2>&1
check "a \"..\" resource is refused" "1"                      "$(/usr/bin/grep -c 'does not name a file' "$trav/res.txt" | /usr/bin/tr -d ' ')"
# "/" is the one that is not in the list of spellings: basename "/" is "/", not
# the empty string, so an enumeration of ''|.|.. misses it and the copy becomes
# "ditto / <state dir>" - the whole boot volume, filling TMPDIR.
pbcli set "$res_doc" /DISTRIBUTION/RESOURCES/README / >/dev/null 2>&1
pbcli build "$res_doc" --output-dir "$trav/out" --unsigned > "$trav/res-root.txt" 2>&1
check "and so is \"/\""          "1"                          "$(/usr/bin/grep -c 'does not name a file' "$trav/res-root.txt" | /usr/bin/tr -d ' ')"
/bin/rm -f "$exp_dir/res.sh"
pbcli export-script "$res_doc" "$exp_dir/res.sh" > "$trav/res-export.txt" 2>&1
check "the generator refuses it too" "no"                     "$([ -f "$exp_dir/res.sh" ] && echo yes || echo no)"
# The absence of a file passes for an export that failed for any reason at all.
# The reason is captured, so it may as well be asserted.
check "and said why"             "1"                          "$(/usr/bin/grep -c 'does not name a file' "$trav/res-export.txt" | /usr/bin/tr -d ' ')"
# And an ordinary resource still stages - asserted by the build getting all the
# way to a package, not merely by the absence of one message, which would pass
# for a build that failed for some other reason entirely.
pbcli set "$res_doc" /DISTRIBUTION/RESOURCES/README "$trav/rsrc/README.txt" >/dev/null 2>&1
pbcli build "$res_doc" --output-dir "$trav/out" --unsigned > "$trav/res2.txt" 2>&1
check "an ordinary one still does" "0"                        "$(/usr/bin/grep -c 'does not name a file' "$trav/res2.txt" | /usr/bin/tr -d ' ')"
check "and the package was built" "1"                         "$(/usr/bin/grep -c '==> Built ' "$trav/res2.txt" | /usr/bin/tr -d ' ')"

section "146. the dry run plans the build that will actually happen"
# staged_relative_path was called on an un-normalized destination here and on a
# normalized one in the build, so a destination carrying "." or "//" printed one
# path and staged another.
dry_doc="$trav/Dry.pkgbld"
pbcli new "$dry_doc" --name Dry --identifier com.example.dry --version 1.0 >/dev/null 2>&1
pbcli add-payload "$dry_doc" "$trav/evil.txt" --destination '/opt/./dry//f.txt' --mode 0644 >/dev/null 2>&1
# The dry run stops at the preconditions before it ever prints a plan, so the
# document has to be one that could actually build.
pbcli set "$dry_doc" /PROJECT/OUTPUT_DIR "$trav/out" >/dev/null 2>&1
pbcli set "$dry_doc" /SIGNING/ENABLED false >/dev/null 2>&1
pbcli build "$dry_doc" --dry-run > "$trav/dry.txt" 2>&1
pbcli build "$dry_doc" --output-dir "$trav/out" --unsigned > "$trav/dry-build.txt" 2>&1
check "the plan says opt/dry/f.txt" "1"                       "$(/usr/bin/grep -c ' opt/dry/f.txt ' "$trav/dry.txt" | /usr/bin/tr -d ' ')"
check "and that is what is staged" "1"                        "$(/usr/bin/grep -c '  staged opt/dry/f.txt' "$trav/dry-build.txt" | /usr/bin/tr -d ' ')"

section "146b. the trailing-slash leaf guard, on a vector that reaches it"
# Section 144's trailing-slash vector is spelled "/opt/nest" + "/opt/nest/escape/",
# which the sibling-nesting check added later now refuses FIRST - so both of its
# assertions pass even with pb_normalize_path removed from the generator, and the
# round-5 regression it was written for can be reintroduced with the suite green.
# Proved by reverting that one line in a generated script.
#
# Spelling the two destinations so they differ only in CASE is what reaches the
# leaf guard: the nesting check compares strings and cannot see the collision,
# the parent legitimately resolves inside the root, and the trailing slash is
# then the only thing standing between "[ -L ]" and the symlink.
/bin/mkdir -p "$trav/dir3"; printf 'inner\n' > "$trav/dir3/inner.txt"
slash_doc="$trav/Slash.pkgbld"
pbcli new "$slash_doc" --name Slash --identifier com.example.slash --version 1.0 >/dev/null 2>&1
pbcli add-payload "$slash_doc" "$trav/tree" --destination /opt/SLASH --mode 0755 >/dev/null 2>&1
pbcli add-payload "$slash_doc" "$trav/dir3" --destination '/opt/slash/escape/' --mode 0755 >/dev/null 2>&1
pbcli export-script "$slash_doc" "$exp_dir/slash.sh" >/dev/null 2>&1
/bin/sh "$exp_dir/slash.sh" --output-dir "$exp_dir/out" --unsigned > "$trav/slash-run.txt" 2>&1
# The SPECIFIC message, not merely the absence of "== DONE ==": that is what
# makes this fail when the leaf guard is the thing that broke.
check "the leaf guard is what refuses it" "1"                 "$(/usr/bin/grep -c 'is a symlink staged by an earlier item' "$trav/slash-run.txt" | /usr/bin/tr -d ' ')"
check "and it did not finish"     "0"                         "$(/usr/bin/grep -c '== DONE ==' "$trav/slash-run.txt" | /usr/bin/tr -d ' ')"
check "nothing reached the canary" "$canary_before"           "$(canary_state)"

# The APP's copy of the same guard, which nothing else here reaches. Section
# 147's whole thesis is that the two agree and keep agreeing, and until this was
# added only the exported script's half was asserted: a reviewer deleted the
# "[ -L $target ]" branch from stage_payload_root and the file stayed at 120
# passed. The document is 146b's, because its case-variant spelling is what gets
# past the nesting precondition and leaves the leaf as the only escape.
reset_state
omc_object "$slash_doc"
omc_run PackageBuilder.main.init
check "the app refuses it too"   "1"                          "$(pb_build_call stage_payload_root >/dev/null 2>&1; echo $?)"
check "and the leaf guard named it" "1"                       "$(log_says 'is a symlink staged by an earlier item')"
check "nothing reached the canary" "$canary_before"           "$(canary_state)"

section "146c. a line break cannot hide a nesting destination"
# The emitted nesting check records destinations one per line, so a newline made
# it compare a truncated string and let a nesting document build - breaking the
# invariant the generator's own header asserts, one round after it was closed.
nl_dest="/opt/$(printf 'D\nX')"
nl_doc="$trav/Newline.pkgbld"
pbcli new "$nl_doc" --name NL --identifier com.example.nl --version 1.0 >/dev/null 2>&1
pbcli add-payload "$nl_doc" "$trav/tree"     --destination "$nl_dest"           --mode 0755 >/dev/null 2>&1
pbcli add-payload "$nl_doc" "$trav/evil.txt" --destination "$nl_dest/sub/x.txt" --mode 0644 >/dev/null 2>&1
pbcli build "$nl_doc" --output-dir "$trav/out" --unsigned > "$trav/nl.txt" 2>&1
check "the app refuses the nesting" "1"                       "$(/usr/bin/grep -c 'installs inside item 1' "$trav/nl.txt" | /usr/bin/tr -d ' ')"
pbcli export-script "$nl_doc" "$exp_dir/nl.sh" >/dev/null 2>&1
/bin/sh "$exp_dir/nl.sh" --output-dir "$exp_dir/out" --unsigned > "$trav/nl-run.txt" 2>&1
check "and so does its exported script" "1"                   "$(/usr/bin/grep -c 'line break' "$trav/nl-run.txt" | /usr/bin/tr -d ' ')"
check "which never finished"      "0"                         "$(/usr/bin/grep -c '== DONE ==' "$trav/nl-run.txt" | /usr/bin/tr -d ' ')"

section "146d. presentation resources collide the way the file system does"
# The collision check was a string compare on a volume that folds case and folds
# NFD to NFC, so two slots naming README.txt and readme.txt both built, one
# overwrote the other, and the installer showed the license text as the readme -
# verbatim the outcome the check exists to prevent.
/bin/mkdir -p "$trav/ra" "$trav/rb"
printf 'the readme\n' > "$trav/ra/README.txt"
printf 'the license\n' > "$trav/rb/readme.txt"
fold_doc="$trav/Fold.pkgbld"
pbcli new "$fold_doc" --name Fold --identifier com.example.fold --version 1.0 >/dev/null 2>&1
pbcli add-payload "$fold_doc" "$trav/evil.txt" --destination /opt/fold/f.txt --mode 0644 >/dev/null 2>&1
pbcli set "$fold_doc" /DISTRIBUTION/RESOURCES/README  "$trav/ra/README.txt" >/dev/null 2>&1
pbcli set "$fold_doc" /DISTRIBUTION/RESOURCES/LICENSE "$trav/rb/readme.txt" >/dev/null 2>&1
pbcli validate "$fold_doc" > "$trav/fold.txt" 2>&1
check "a case-variant collision is refused" "1"               "$(/usr/bin/grep -c 'both named' "$trav/fold.txt" | /usr/bin/tr -d ' ')"
# Positive control: two genuinely different names are fine.
pbcli set "$fold_doc" /DISTRIBUTION/RESOURCES/LICENSE "$trav/rb/license.txt" >/dev/null 2>&1
printf 'lic\n' > "$trav/rb/license.txt"
pbcli validate "$fold_doc" > "$trav/fold2.txt" 2>&1
check "two different names are not"        "0"                "$(/usr/bin/grep -c 'both named' "$trav/fold2.txt" | /usr/bin/tr -d ' ')"

section "146e. two destinations that name one directory are refused"
# Design 4.1 forbids two entries nesting because the second entry's ditto would
# race the first. The gate was a string comparison on a volume that folds case
# and folds NFD to NFC, so two destinations differing only that way merged into
# one directory with the document reported clean - a wrong package that builds,
# the same class as 146d one rung along. The comparison now asks the file system
# what spelling it will actually use.
/bin/mkdir -p "$trav/cf1"; printf 'one\n' > "$trav/cf1/one.txt"
cf_doc="$trav/Case2.pkgbld"
pbcli new "$cf_doc" --name Case2 --identifier com.example.case2 --version 1.0 >/dev/null 2>&1
pbcli add-payload "$cf_doc" "$trav/cf1"      --destination /opt/CFDIR         --mode 0755 >/dev/null 2>&1
pbcli add-payload "$cf_doc" "$trav/evil.txt" --destination /opt/cfdir/two.txt --mode 0644 >/dev/null 2>&1
pbcli validate "$cf_doc" > "$trav/cf.txt" 2>&1
check "a case-variant nesting is refused" "1"                 "$(/usr/bin/grep -c 'installs inside item 1' "$trav/cf.txt" | /usr/bin/tr -d ' ')"
nfc2="$(/usr/bin/python3 -c 'import unicodedata; print(unicodedata.normalize("NFC", "café"))')"
nfd2="$(/usr/bin/python3 -c 'import unicodedata; print(unicodedata.normalize("NFD", "café"))')"
nfd_doc="$trav/Nfd.pkgbld"
pbcli new "$nfd_doc" --name Nfd --identifier com.example.nfd --version 1.0 >/dev/null 2>&1
pbcli add-payload "$nfd_doc" "$trav/cf1"      --destination "/opt/$nfc2"         --mode 0755 >/dev/null 2>&1
pbcli add-payload "$nfd_doc" "$trav/evil.txt" --destination "/opt/$nfd2/two.txt" --mode 0644 >/dev/null 2>&1
pbcli validate "$nfd_doc" > "$trav/nfd2.txt" 2>&1
check "and an NFC-vs-NFD one"     "1"                         "$(/usr/bin/grep -c 'installs inside item 1' "$trav/nfd2.txt" | /usr/bin/tr -d ' ')"
# Positive control: two destinations that genuinely differ must still build, or a
# gate that refused everything would pass both checks above.
ok_doc="$trav/CaseOK.pkgbld"
pbcli new "$ok_doc" --name CaseOK --identifier com.example.caseok --version 1.0 >/dev/null 2>&1
pbcli add-payload "$ok_doc" "$trav/cf1"      --destination /opt/ok/one     --mode 0755 >/dev/null 2>&1
pbcli add-payload "$ok_doc" "$trav/evil.txt" --destination /opt/ok/two.txt --mode 0644 >/dev/null 2>&1
pbcli build "$ok_doc" --output-dir "$trav/out" --unsigned > "$trav/ok.txt" 2>&1
check "two distinct ones still build" "1"                     "$(/usr/bin/grep -c '==> Built ' "$trav/ok.txt" | /usr/bin/tr -d ' ')"

section "147. the exported script and the app agree, and keep agreeing"
# Round 5 found the emitted copy of the staging guard missing normalize_path, and
# round 6 found it missing the sibling-nesting check. Both were divergences from
# the app rather than fresh mistakes, so these check the AGREEMENT rather than
# any one spelling - that is the property that keeps being broken.
/bin/mkdir -p "$trav/plain"; printf 'a\n' > "$trav/plain/a.txt"
nest2_doc="$trav/Nest2.pkgbld"
pbcli new "$nest2_doc" --name Nest2 --identifier com.example.nest2 --version 1.0 >/dev/null 2>&1
pbcli add-payload "$nest2_doc" "$trav/plain"    --destination /opt/plain --mode 0755 >/dev/null 2>&1
pbcli add-payload "$nest2_doc" "$trav/evil.txt" --destination /opt/plain/sub/x.txt --mode 0644 >/dev/null 2>&1
pbcli build "$nest2_doc" --output-dir "$trav/out" --unsigned > "$trav/nest2.txt" 2>&1
check "the app refuses plain nesting" "1"                     "$(/usr/bin/grep -c 'installs inside item 1' "$trav/nest2.txt" | /usr/bin/tr -d ' ')"
pbcli export-script "$nest2_doc" "$exp_dir/nest2.sh" >/dev/null 2>&1
/bin/sh "$exp_dir/nest2.sh" --output-dir "$exp_dir/out" --unsigned > "$trav/nest2-run.txt" 2>&1
# No symlink anywhere here: the containment and leaf guards cannot catch this
# one, so only a real nesting check in the emitted script can.
check "and so does its exported script" "1"                   "$(/usr/bin/grep -c 'installs inside' "$trav/nest2-run.txt" | /usr/bin/tr -d ' ')"
check "which did not reach DONE"  "0"                         "$(/usr/bin/grep -c '== DONE ==' "$trav/nest2-run.txt" | /usr/bin/tr -d ' ')"
# The same destination twice is refused by both as well.
dup_doc="$trav/Dup.pkgbld"
pbcli new "$dup_doc" --name Dup --identifier com.example.dup --version 1.0 >/dev/null 2>&1
pbcli add-payload "$dup_doc" "$trav/evil.txt" --destination /opt/d/f.txt --mode 0644 >/dev/null 2>&1
pbcli add-payload "$dup_doc" "$trav/tree2/pwned.txt" --destination /opt/d/f.txt --mode 0644 >/dev/null 2>&1
pbcli export-script "$dup_doc" "$exp_dir/dup.sh" >/dev/null 2>&1
/bin/sh "$exp_dir/dup.sh" --output-dir "$exp_dir/out" --unsigned > "$trav/dup-run.txt" 2>&1
check "and a repeated destination" "1"                        "$(/usr/bin/grep -c 'installed to twice' "$trav/dup-run.txt" | /usr/bin/tr -d ' ')"

# The two normalizers must agree, because the app decides what to refuse with one
# and the exported script decides with the other. A divergence here is a
# divergence in what the two will build, which is how rounds 5 and 6 happened.
/usr/bin/sed -n '/^pb_normalize_path() {$/,/^}$/p' "$exp_dir/nest2.sh" > "$trav/pbnorm.sh"
check "the emitted normalizer was found" "1"                  "$(/usr/bin/grep -c '^pb_normalize_path() {' "$trav/pbnorm.sh" | /usr/bin/tr -d ' ')"
/bin/cat > "$trav/normdiff.sh" <<NORMDIFF
. "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.packagebuilder.sh"
. "$trav/pbnorm.sh"
diffs=0
while IFS= read -r vector; do
    [ -n "\$vector" ] || continue
    a="\$(normalize_path "\$vector")"
    b="\$(pb_normalize_path "\$vector")"
    [ "\$a" = "\$b" ] || { diffs=\$((diffs + 1)); printf 'DIFF [%s] app=[%s] script=[%s]\n' "\$vector" "\$a" "\$b"; }
done < "$trav/vectors.txt"
printf '%s' "\$diffs"
NORMDIFF
printf '%s\n' '/opt/a' '/opt/a/' '/opt//a' '/opt/./a' '/opt/a/.' '/opt/a/./' '//opt//a//' \
    '/' '//' '/.' '.' './a' 'a' 'a/' '/opt/a b/c' '/opt/a*b' '/opt/$(id)' '/opt/-n' \
    '/opt/a//./b//' > "$trav/vectors.txt"
check "the two normalizers agree" "0"                         "$(/bin/sh "$trav/normdiff.sh" 2>/dev/null)"

section '148. importing a source that carries ".."'
# path_is_under now refuses a child carrying "..", which is right for a
# destination and wrong for a SOURCE: a source names a file on this machine, not
# a place anything is written to. Left unhandled it made import_common_prefix
# shrink the prefix to nothing, so EVERY entry lost its ${ARTIFACTS_DIR}
# tokenization and the imported document stopped being portable.
/bin/rm -rf "$OMCTEST_WORK/impdots"; /bin/mkdir -p "$OMCTEST_WORK/impdots/art/inner"
/bin/cp /bin/echo "$OMCTEST_WORK/impdots/art/w1"; /bin/cp /bin/echo "$OMCTEST_WORK/impdots/art/w2"
/bin/cat > "$OMCTEST_WORK/impdots/fx.json" <<IMPDOTS
{"PACKAGES":[{"PACKAGE_SETTINGS":{"NAME":"impdots","VERSION":"1.0","IDENTIFIER":"com.example.impdots"},
 "PACKAGE_FILES":{"DEFAULT_INSTALL_LOCATION":"/",
  "HIERARCHY":{"TYPE":1,"PATH":"/","PATH_TYPE":0,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[
   {"TYPE":-1,"PATH":"opt","PATH_TYPE":0,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[
    {"TYPE":-1,"PATH":"x","PATH_TYPE":0,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[
     {"TYPE":3,"PATH":"$OMCTEST_WORK/impdots/art/w1","PATH_TYPE":0,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[]},
     {"TYPE":3,"PATH":"$OMCTEST_WORK/impdots/art/inner/../w2","PATH_TYPE":0,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[]}]}]}]}}}],
 "PROJECT":{"PROJECT_SETTINGS":{"BUILD_PATH":{"PATH":"build","PATH_TYPE":1}}}}
IMPDOTS
/usr/bin/plutil -convert xml1 -o "$OMCTEST_WORK/impdots/Fx.pkgproj" "$OMCTEST_WORK/impdots/fx.json" >/dev/null 2>&1
pbcli import-pkgproj "$OMCTEST_WORK/impdots/Fx.pkgproj" "$OMCTEST_WORK/impdots/Out.pkgbld" --force > "$OMCTEST_WORK/impdots/run.txt" 2>&1
check "the artifacts folder survives" "1"                     "$(/usr/bin/grep -c 'artifacts folder:' "$OMCTEST_WORK/impdots/run.txt" | /usr/bin/tr -d ' ')"
check "the clean source is tokenized" '${ARTIFACTS_DIR}/w1'   "$(pbcli get "$OMCTEST_WORK/impdots/Out.pkgbld" /COMPONENTS/0/PAYLOAD/0/SOURCE 2>/dev/null)"
check "and so is the other one"      '${ARTIFACTS_DIR}/w2'    "$(pbcli get "$OMCTEST_WORK/impdots/Out.pkgbld" /COMPONENTS/0/PAYLOAD/1/SOURCE 2>/dev/null)"

section "149. a created document gets .pkgbld only when none was spelled"
# The window's Save As forces the extension onto whatever was typed; a command
# line is a deliberate path, so an extension the caller spelled is kept. What
# every case has in common is that the printed path is the path written - the
# documented workflow captures it and feeds it to every later command.
ext="$OMCTEST_WORK/ext"; /bin/rm -rf "$ext"; /bin/mkdir -p "$ext/v1.2"
new_ext() { pbcli new "$1" --name E --identifier com.example.ext --no-signing 2>/dev/null; }

check "bare name gets one"       "$ext/bare.pkgbld"           "$(new_ext "$ext/bare")"
check_exists "and that is the file" "$ext/bare.pkgbld"
check "a spelled one is kept"    "$ext/named.pkgbld"          "$(new_ext "$ext/named.pkgbld")"
check "so is a foreign one"      "$ext/thing.json"            "$(new_ext "$ext/thing.json")"
check "and an upper-case one"    "$ext/loud.PKGBLD"           "$(new_ext "$ext/loud.PKGBLD")"
# A dot in a parent directory is not the leaf's extension, and a leading dot
# marks a hidden file rather than one.
check "a dotted parent is not it" "$ext/v1.2/deep.pkgbld"     "$(new_ext "$ext/v1.2/deep")"
check "a hidden name has none"   "$ext/.tucked.pkgbld"        "$(new_ext "$ext/.tucked")"
check "a hidden one can have one" "$ext/.shown.pkgbld"        "$(new_ext "$ext/.shown.pkgbld")"

# The settled name is what the existence check tests, or "new" would overwrite a
# document it just refused to name.
pbcli new "$ext/bare" --name E --identifier com.example.ext --no-signing > "$ext/again.txt" 2>&1
check "the settled name collides" "1"                         "$?"
check "and it said which file"   "1"                          "$(/usr/bin/grep -c 'bare.pkgbld already exists' "$ext/again.txt" | /usr/bin/tr -d ' ')"

# A path that names a directory is refused, not appended to. Appending would
# make "dir/.pkgbld", which LaunchServices does not claim - and it would slip
# past the existence guard above, because the directory exists and that name
# does not.
/bin/mkdir -p "$ext/adir"
pbcli new "$ext/adir/" --name E --identifier com.example.ext --no-signing > "$ext/dir.txt" 2>&1
check "a trailing slash is refused" "1"                       "$?"
check "and said why"             "1"                          "$(/usr/bin/grep -c 'names a directory, not a document' "$ext/dir.txt" | /usr/bin/tr -d ' ')"
check "no hidden file was made"  ""                           "$(/bin/ls -A "$ext/adir")"
( cd "$ext/adir" && pbcli new . --name E --identifier com.example.ext --no-signing ) >/dev/null 2>&1
check "a bare dot is refused"    "1"                          "$?"
( cd "$ext/adir" && pbcli new .. --name E --identifier com.example.ext --no-signing ) >/dev/null 2>&1
check "and so is dot-dot"        "1"                          "$?"
check "neither wrote anything"   ""                           "$(/bin/ls -A "$ext/adir")"
# Usage errors still win over the path complaint, so --help and a missing --name
# answer the way they always did.
pbcli new "$ext/adir/" --name E > "$ext/order.txt" 2>&1
check "a usage error comes first" "1"                         "$(/usr/bin/grep -c 'identifier is required' "$ext/order.txt" | /usr/bin/tr -d ' ')"

# import-pkgproj creates a document too, and follows the same rules.
/bin/cat > "$ext/src.json" <<EXTIMP
{"PACKAGES":[{"PACKAGE_SETTINGS":{"NAME":"ext","VERSION":"1.0","IDENTIFIER":"com.example.ext"}}]}
EXTIMP
/usr/bin/plutil -convert xml1 -o "$ext/Src.pkgproj" "$ext/src.json" >/dev/null 2>&1
check "import settles it too"    "$ext/imported.pkgbld"       "$(pbcli import-pkgproj "$ext/Src.pkgproj" "$ext/imported" 2>/dev/null)"
check_exists "and wrote there"   "$ext/imported.pkgbld"
# The settled name is what import's existence check tests as well.
pbcli import-pkgproj "$ext/Src.pkgproj" "$ext/imported" > "$ext/imp2.txt" 2>&1
check "import collides on it"    "1"                          "$?"
check "and named that file"      "1"                          "$(/usr/bin/grep -c 'imported.pkgbld already exists' "$ext/imp2.txt" | /usr/bin/tr -d ' ')"
# A forgotten destination must not let the option become the document name.
pbcli import-pkgproj "$ext/Src.pkgproj" --force > "$ext/imp3.txt" 2>&1
check "a bare option is refused" "2"                          "$?"
# The whole listing, not the one name that was predicted: without the guard the
# write fails at mv, so "--force.pkgbld" never appears and only the landing file
# "--force.pkgbld.pkgbuilder.<pid>" is left behind.
check "and left nothing behind" ""                            "$(/bin/ls -A "$ext" | /usr/bin/grep '^--')"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids"        ""                           "$(ui_unknown_writes)"

omctest_end
