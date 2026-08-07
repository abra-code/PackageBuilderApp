#!/bin/sh
# lib.packagebuilder.build.sh - the packaging engine
#
# Sourced after lib.packagebuilder.sh, which it depends on for state_dir, the
# model accessors, the path and token helpers, and the window wrappers.
#
# This is a separate file from lib.packagebuilder.sh on purpose. Everything here
# is a function of the document and the filesystem and touches the window only
# to report - which is what lets design section 11's exported standalone script
# be a transcription of this file rather than a second implementation of it.
#
# POSIX sh only. No [[ ]], no arrays, no process substitution. Validate with
# "sh -n", never "bash -n".

# --- External tools -----------------------------------------------------------
pkgbuild_tool="/usr/bin/pkgbuild"
pkgutil_tool="/usr/sbin/pkgutil"
ditto_tool="/usr/bin/ditto"

# --- Step rail ----------------------------------------------------------------
# Which view id belongs to which stage. The drawing itself - rail_set and
# rail_reset - is presentation and lives in lib.packagebuilder.window.sh and
# lib.packagebuilder.console.sh; what stays here is the part that is about the
# pipeline rather than about how it looks.
RAIL_VERIFY_ID=210
RAIL_COMPONENT_ID=211
RAIL_DISTRIBUTION_ID=212
RAIL_SIGN_ID=213
RAIL_ICON_IDS="$RAIL_VERIFY_ID $RAIL_COMPONENT_ID $RAIL_DISTRIBUTION_ID $RAIL_SIGN_ID"

# Run an external tool with both its streams captured to a named file, and
# return the tool's own exit status.
#
# Separate from run_tool because the verify stage needs the output as evidence
# to match against rather than as something to print: codesign writes its report
# to stderr, and mirroring it into the log on the way past would fill the view
# with the certificate chain of every artifact that passed.
#
# This and run_tool are the two functions here that keep "$@" rather than naming
# their parameters: what follows the output file is the command line to run, so
# naming them would mean fixing their number.
run_capture() {
    local output_file="$1"
    shift
    # Asked for before starting anything. Without this, a stop that lands in the
    # gap between two tools signals a pid that has already been reaped, and the
    # next tool then runs to completion before any boundary notices - a full
    # pkgbuild the user has already asked not to happen. 143 is what a tool
    # killed by SIGTERM returns, so the caller cannot tell the two apart and
    # does not have to.
    if stop_was_requested; then
        /bin/rm -f "$output_file"
        return 143
    fi
    /bin/rm -f "$output_file"
    # Started in the background and waited for, rather than run in the
    # foreground, so that the Stop button has something to signal. A foreground
    # tool is unreachable: this shell is blocked inside it, and the pid that
    # would have to be killed exists nowhere but in the kernel.
    "$@" > "$output_file" 2>&1 &
    local tool_pid=$!
    printf '%s' "$tool_pid" > "$(state_dir)/tool.pid"
    # Reaping a job that died on a signal makes the shell print "Terminated: 15"
    # to the stderr it started with - not to whatever is redirected here, which
    # is why there is no redirection here to try. OMC discards a handler's
    # stderr, so this is invisible in the app; the harness sends it to a file so
    # its own output stays readable.
    wait "$tool_pid"
    # "$?" is expanded before "local" runs, so this is the tool's own status -
    # 128 + the signal number when Stop got to it first.
    local status=$?
    /bin/rm -f "$(state_dir)/tool.pid"
    return $status
}

# Run an external tool, mirror everything it printed into the log, and return
# its exit status. Design 8.4: every external call captures stdout and stderr
# and has its status checked; a failure leaves the raw output in the log view
# rather than a summary of it.
run_tool() {
    local output_file="$(state_dir)/tool.log"
    run_capture "$output_file" "$@"
    # "$?" is expanded before "local" runs, so this does capture the tool's
    # status and not local's own.
    local status=$?
    if [ -s "$output_file" ]; then
        append_log_file "$output_file"
    fi
    /bin/rm -f "$output_file"
    return $status
}

# --- Value validation (design 4.4) --------------------------------------------
# Substitution is textual, so a bad value corrupts output silently rather than
# loudly. These run before any expansion happens and a failure is a hard stop
# before any file is written.
#
# POSIX sh has no regular expressions; each pattern below is the case-glob
# equivalent of the one in the design's table. In a bracket expression "!" first
# negates and "-" last is a literal hyphen.

# ^[0-9][0-9A-Za-z.+_-]*$
valid_version() {
    local version="$1"
    case "$version" in
        ''|[!0-9]*) return 1 ;;
    esac
    case "$version" in
        *[!0-9A-Za-z.+_-]*) return 1 ;;
    esac
    return 0
}

# ^[A-Za-z0-9._-]+$
valid_name() {
    local name="$1"
    case "$name" in
        '') return 1 ;;
        *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

# Reverse-DNS-looking: at least one interior dot, and nothing in it that would
# need quoting on a command line.
valid_identifier() {
    local identifier="$1"
    case "$identifier" in
        '') return 1 ;;
        *[!A-Za-z0-9.-]*) return 1 ;;
        .*|*.) return 1 ;;
        *.*) return 0 ;;
    esac
    return 1
}

# Three or four octal digits.
valid_mode() {
    local mode="$1"
    case "$mode" in
        ''|*[!0-7]*) return 1 ;;
    esac
    case "$mode" in
        ???|????) return 0 ;;
    esac
    return 1
}

# --- Preconditions (design 7) -------------------------------------------------
# Everything checked and reported before anything is written. Each failure is
# appended to the log and counted in the shared precondition_failures global, so
# one run tells the user everything that is wrong rather than one thing per
# attempt.
#
# The count is read from that global, never from the return value. A shell
# "return" carries only the low eight bits, so returning a count makes exactly
# 256 failures indistinguishable from none - and the pairwise destination-clash
# check is O(n^2), so 23 payload items sharing one destination reach 253 on
# their own. The build gate would see zero and wave through a payload whose
# entries silently overwrite each other. Each function therefore returns 0 or 1
# and resets the global on entry. Found in review, 2026-08-06.
#
# The output directory and the installer identity are not checked here: nothing
# in this stage writes to the former or needs the latter. They join this list
# when the distribution and signing stages arrive.
precondition_failures=0

fail_precondition() {
    local message="$1"
    append_log "  ! $message"
    precondition_failures=$((precondition_failures + 1))
}

# Print an entry's path under the staging root: its destination with the
# component's install location removed. Requires the prefix relationship the
# preconditions enforce. Arguments: destination, install location
staged_relative_path() {
    local destination="$1" install_location="$2"
    local base="${install_location%/}"
    # Set on both branches below.
    local relative
    if [ -z "$base" ]; then
        relative="$destination"
    else
        relative="${destination#"$base"}"
    fi
    relative="${relative#/}"
    printf '%s' "$relative"
}

check_preconditions() {
    # Set once per iteration of the loops below.
    local source destination mode stored_source item_number
    local other_index other_destination

    precondition_failures=0

    local name="$(model_get /PROJECT/NAME)"
    local version="$(model_get /PROJECT/VERSION)"
    local identifier="$(model_get /COMPONENTS/0/IDENTIFIER)"
    local install_location="$(model_get /COMPONENTS/0/INSTALL_LOCATION)"
    [ -n "$install_location" ] || install_location="/"

    valid_name "$name" || fail_precondition \
        "Project name \"$name\" is not usable in a filename - use letters, digits, dot, underscore or hyphen"
    valid_version "$version" || fail_precondition \
        "Version \"$version\" is not accepted - it must start with a digit and hold only letters, digits, . + _ or -"
    valid_identifier "$identifier" || fail_precondition \
        "Identifier \"$identifier\" does not look like a reverse-DNS string, for example com.example.pkg.tool"

    case "$install_location" in
        /*) ;;
        *) fail_precondition "Install location \"$install_location\" must be an absolute path" ;;
    esac

    local entry_count="$(payload_count)"
    if [ "$entry_count" = "0" ]; then
        fail_precondition "The payload is empty - add at least one artifact"
    fi

    local index=0
    while [ "$index" -lt "$entry_count" ]; do
        item_number=$((index + 1))
        stored_source="$(payload_get "$index" SOURCE)"
        destination="$(expand_tokens "$(payload_get "$index" DESTINATION)")"
        mode="$(payload_get "$index" MODE)"

        # ${ARTIFACTS_DIR} used without PROJECT.ARTIFACTS_DIR set is a
        # precondition failure rather than a silent empty string (design 4.3).
        # Reported here specifically, because resolve_stored_path refuses it
        # without saying why.
        if uses_unset_artifacts_dir "$stored_source"; then
            fail_precondition "Item $item_number uses \${ARTIFACTS_DIR} but no artifacts folder is set"
            source=""
        elif [ -z "$stored_source" ]; then
            fail_precondition "Item $item_number has no source"
            source=""
        else
            source="$(resolve_stored_path "$stored_source")"
            if [ -z "$source" ]; then
                fail_precondition "Item $item_number: \"$stored_source\" could not be resolved to a path"
            elif [ ! -e "$source" ]; then
                fail_precondition "Item $item_number: $source is not there"
            elif [ ! -r "$source" ]; then
                fail_precondition "Item $item_number: $source cannot be read"
            fi
        fi

        if [ -z "$destination" ]; then
            fail_precondition "Item $item_number has no destination"
        else
            case "$destination" in
                /*) ;;
                *) fail_precondition "Item $item_number: destination \"$destination\" must be an absolute path" ;;
            esac
            if ! path_is_under "$destination" "$install_location"; then
                fail_precondition "Item $item_number: destination \"$destination\" is not under the install location \"$install_location\""
            fi
        fi

        valid_mode "$mode" || fail_precondition \
            "Item $item_number: mode \"$mode\" is not three or four octal digits"

        # Two destinations in one component may not be equal, and one may not be
        # a strict prefix of another: the second entry's ditto would race the
        # first (design 4.1). Only later entries are compared, so a clash is
        # reported once rather than from both ends.
        other_index=$((index + 1))
        while [ "$other_index" -lt "$entry_count" ]; do
            other_destination="$(expand_tokens "$(payload_get "$other_index" DESTINATION)")"
            if [ -n "$destination" ] && [ -n "$other_destination" ]; then
                if [ "$destination" = "$other_destination" ]; then
                    fail_precondition "Items $item_number and $((other_index + 1)) install to the same path: $destination"
                elif path_is_under "$other_destination" "$destination"; then
                    fail_precondition "Item $((other_index + 1)) installs inside item $item_number: $other_destination is under $destination"
                elif path_is_under "$destination" "$other_destination"; then
                    fail_precondition "Item $item_number installs inside item $((other_index + 1)): $destination is under $other_destination"
                fi
            fi
            other_index=$((other_index + 1))
        done

        index=$((index + 1))
    done

    [ "$precondition_failures" -eq 0 ]
}

# Preconditions for the distribution stage. Separate from the component stage's
# because the two partial actions can be run independently, and a distribution
# run must not fail on a payload problem that has nothing to do with it.
check_distribution_preconditions() {
    # Set once per iteration below.
    local pair model_key stored source

    precondition_failures=0

    local identifier="$(model_get /COMPONENTS/0/IDENTIFIER)"
    local version="$(model_get /PROJECT/VERSION)"
    local name="$(model_get /PROJECT/NAME)"

    valid_name "$name" || fail_precondition \
        "Project name \"$name\" is not usable in a filename - use letters, digits, dot, underscore or hyphen"
    valid_version "$version" || fail_precondition \
        "Version \"$version\" is not accepted - it must start with a digit and hold only letters, digits, . + _ or -"
    valid_identifier "$identifier" || fail_precondition \
        "Identifier \"$identifier\" does not look like a reverse-DNS string, for example com.example.pkg.tool"

    # An empty hostArchitectures attribute makes productbuild refuse the
    # document, and both toggles off is the only way to reach it.
    if [ -z "$(host_architectures_attr)" ]; then
        fail_precondition "No host architecture is selected - the installer would refuse to run anywhere"
    fi

    case "$(model_get /DISTRIBUTION/CUSTOMIZE)" in
        never|allow|always) ;;
        *) fail_precondition "Customize must be never, allow or always" ;;
    esac

    # The minimum OS goes straight into an os-version attribute, so it has to
    # look like a version rather than merely be escapable: "10.15 or later"
    # produces well-formed XML that productbuild then rejects.
    local min_os="$(model_get /PROJECT/MIN_OS_VERSION)"
    if [ -n "$min_os" ]; then
        case "$min_os" in
            ''|[!0-9]*|*[!0-9.]*) fail_precondition "Minimum macOS \"$min_os\" must be a version number such as 10.15 or 14.6" ;;
        esac
    fi

    # Resources are staged flat under their basenames, so two slots naming
    # different files with the same basename would collide: the second copy
    # overwrites the first and both XML elements point at the survivor. The
    # installer would then show, say, the license text as the readme - a wrong
    # package that builds cleanly. Refused here rather than resolved by
    # inventing names, so what the document says is what ships.
    local seen_basenames="" base
    for pair in $DISTRIBUTION_RESOURCE_KINDS; do
        model_key="${pair%%:*}"
        stored="$(model_get "/DISTRIBUTION/RESOURCES/$model_key")"
        [ -n "$stored" ] || continue
        if uses_unset_artifacts_dir "$stored"; then
            fail_precondition "The $model_key resource uses \${ARTIFACTS_DIR} but no artifacts folder is set"
            continue
        fi
        source="$(resolve_stored_path "$stored")"
        # -e, not -f: an .rtfd readme is a directory bundle and a perfectly
        # ordinary installer resource format.
        if [ -z "$source" ] || [ ! -e "$source" ]; then
            fail_precondition "The $model_key resource is not there: $stored"
            continue
        fi
        base="$(/usr/bin/basename "$source")"
        case "$seen_basenames" in
            *"|$base|"*)
                fail_precondition "Two presentation resources are both named \"$base\" - the installer can only show one of them"
                ;;
            *) seen_basenames="$seen_basenames|$base|" ;;
        esac
    done

    [ "$precondition_failures" -eq 0 ]
}

# ==============================================================================
# Verify the payload (design section 7 step 1)
# ==============================================================================
# This stage carries the knowledge the removed build step used to embody, which
# is why its messages name the cause rather than the symptom. A binary produced
# by "xcodebuild build" rather than "xcodebuild archive" is signed with
# --timestamp=none and no hardened runtime, and looks entirely plausible
# otherwise; a binary from a machine missing its distribution xcconfig comes out
# ad-hoc signed and equally plausible. The artifacts arrive already signed, by
# whatever machine built them, so this app cannot prevent either any more. All
# it can do is refuse them by name, and say which mistake it is looking at.
#
# Unlike the preconditions, which accumulate so that one run reports everything
# wrong with the document, this stage stops at the first problem (design 7). A
# precondition failure is a typo in a field and the others are worth collecting;
# a verify failure means the artifact on disk is not the artifact the document
# describes, and the rest of the answers are not worth the wait.

# A verify failure. Distinct from fail_precondition, which counts: nothing counts
# here, because the first one ends the stage.
verify_fail() {
    local message="$1"
    append_log "  ! $message"
    return 0
}

# The explanation under a failure, indented past the "!" so the two read as one
# message rather than as two findings.
verify_note() {
    local message="$1"
    append_log "    $message"
    return 0
}

# Check one architecture's signature against the assertions the entry makes.
# An empty architecture means "the one codesign picks", which is right for a
# single-slice binary and for a bundle with no Mach-O in it.
# Arguments: artifact path, architecture (may be empty), label for messages,
#            expected authority prefix, want hardened runtime, want timestamp
verify_signature() {
    local artifact="$1" arch="$2" label="$3"
    local signed_by="$4" want_hardened="$5" want_timestamp="$6"
    # Set only where a failure has to name what was found instead.
    local found_authority
    local codesign_log="$(state_dir)/codesign.txt"
    local where="$label"
    [ -z "$arch" ] || where="$label [$arch]"

    # --verify first: what --display prints about a signature that does not
    # validate is not evidence of anything.
    if [ -z "$arch" ]; then
        run_capture "$codesign_log" /usr/bin/codesign --verify --strict --verbose=2 "$artifact"
    else
        run_capture "$codesign_log" /usr/bin/codesign --verify --strict --verbose=2 --arch "$arch" "$artifact"
    fi
    if [ "$?" != "0" ]; then
        # A tool killed by Stop also returns non-zero, and saying "the code
        # signature does not verify" about an artifact nobody finished checking
        # would leave a false accusation in the log after the run is over.
        stop_was_requested && return 1
        verify_fail "$where: the code signature does not verify"
        append_log_file "$codesign_log"
        return 1
    fi
    # codesign writes its report to stderr, which run_capture keeps along with
    # stdout. It stays in a file rather than a variable because the checks below
    # match against whole lines, and a command substitution would strip the
    # newline off the last of them.
    if [ -z "$arch" ]; then
        run_capture "$codesign_log" /usr/bin/codesign --display --verbose=4 "$artifact"
    else
        run_capture "$codesign_log" /usr/bin/codesign --display --verbose=4 --arch "$arch" "$artifact"
    fi
    if [ "$?" != "0" ]; then
        stop_was_requested && return 1
        verify_fail "$where: codesign could not read the signature"
        append_log_file "$codesign_log"
        return 1
    fi

    if [ -n "$signed_by" ]; then
        # The leaf certificate only, and compared as a prefix of it.
        #
        # A prefix because the value the inspector fills in by default is
        # "Developer ID Application" - the leading part of every Developer ID
        # certificate name rather than any one of them, so a whole-line match
        # would refuse every artifact the app itself set up. Someone who cares
        # which team signed it pastes the whole identity in, and that still
        # matches only that identity.
        #
        # The leaf only because "Authority=" appears once per certificate in the
        # chain, so matching anywhere in the list accepts "Apple Root CA" as
        # though it had signed the binary. And anchored to the start of a line
        # because the report opens with "Executable=<path>": an unanchored
        # search let an ad-hoc binary sitting in a directory named
        # "Authority=Developer ID Application" pass. Both found in review,
        # 2026-08-06, the second one proven with a working artifact.
        #
        # The comparison is a case glob with the pattern quoted, so every
        # character in the expected value stays literal - no regex, and no
        # multi-line pattern to turn a stray newline into "matches anything".
        found_authority="$(/usr/bin/sed -n 's/^Authority=//p' "$codesign_log" | /usr/bin/head -n 1)"
        case "$found_authority" in
            "$signed_by"*) ;;
            *)
                [ -n "$found_authority" ] || found_authority="nothing - the signature is ad-hoc, with no certificate chain at all"
                verify_fail "$where: expected a signature from \"$signed_by\", found $found_authority"
                verify_note "an ad-hoc or wrong-team signature usually means the distribution signing settings were not applied on the machine that built this"
                return 1
                ;;
        esac
    fi

    if [ "$want_timestamp" = "1" ] && ! /usr/bin/grep -q '^Timestamp=' "$codesign_log"; then
        verify_fail "$where: signed without a secure timestamp - notarization will reject it"
        verify_note "a signature made with --timestamp=none prints \"Signed Time=\" where a real one prints \"Timestamp=\", and that is how a binary built with \"xcodebuild build\" is signed. Rebuild with \"xcodebuild archive\"."
        return 1
    fi

    if [ "$want_hardened" = "1" ]; then
        # Matched by flag name, not by the 0x10000 hex, which shifts the moment
        # any unrelated CodeDirectory flag is added. The list renders as
        # "flags=0x10000(runtime)" on its own and "flags=0x10002(adhoc,runtime)"
        # with company, so all four positions a name can occupy in a
        # comma-separated list are spelled out.
        case "$(/usr/bin/grep '^CodeDirectory ' "$codesign_log" | /usr/bin/head -n 1)" in
            *"(runtime)"*|*"(runtime,"*|*",runtime)"*|*",runtime,"*) ;;
            *)
                verify_fail "$where: not signed with the hardened runtime - notarization will reject it"
                verify_note "\"xcodebuild build\" does not turn it on; rebuild with \"xcodebuild archive\", or sign with codesign --options runtime"
                return 1
                ;;
        esac
    fi

    return 0
}

# Verify one payload entry against the assertions the document makes about it.
# Succeeds when every check the entry turned on passes.
# Arguments: entry index (0-based)
verify_payload_entry() {
    local entry_index="$1"
    # Set only on the branches that need them.
    local executable found_archs arch reported_version
    local item_number=$((entry_index + 1))

    local stored_source="$(payload_get "$entry_index" SOURCE)"
    local source="$(resolve_stored_path "$stored_source")"
    local label="item $item_number"
    [ -z "$source" ] || label="item $item_number ($(/usr/bin/basename "$source"))"

    if [ -z "$source" ] || [ ! -e "$source" ]; then
        verify_fail "$label: \"$stored_source\" is not on disk"
        return 1
    fi
    if [ ! -r "$source" ]; then
        verify_fail "$label: $source cannot be read"
        return 1
    fi

    local wanted_archs="$(payload_archs_get "$entry_index")"
    local signed_by="$(payload_get "$entry_index" VERIFY/SIGNED_BY)"
    local want_hardened="$(payload_bool_get "$entry_index" VERIFY/HARDENED_RUNTIME)"
    local want_timestamp="$(payload_bool_get "$entry_index" VERIFY/SECURE_TIMESTAMP)"
    local version_flag="$(payload_get "$entry_index" VERIFY/VERSION_FLAG)"

    # A payload of ordinary resource files - a plist, an icon, a data folder -
    # asserts nothing, and saying so is better than saying nothing, which would
    # be indistinguishable from a stage that failed to run.
    if [ -z "$wanted_archs" ] && [ -z "$signed_by" ] && [ "$want_hardened" != "1" ] &&
       [ "$want_timestamp" != "1" ] && [ -z "$version_flag" ]; then
        append_log "  $label: nothing asserted, nothing checked"
        return 0
    fi

    if [ -n "$wanted_archs" ]; then
        executable="$(artifact_executable "$source")"
        if [ -z "$executable" ]; then
            verify_fail "$label: there is no Mach-O executable here to read architectures from"
            verify_note "a bundle answers through its CFBundleExecutable; anything else has to be Mach-O itself"
            return 1
        fi
        found_archs="$(/usr/bin/lipo -archs "$executable" 2>/dev/null || true)"
        # Architecture names are bare tokens, so splitting on IFS is safe here in
        # a way it would not be for a path. Pathname expansion is turned off
        # around the loop all the same: a glob character in a hand-edited list
        # can only ever produce a refusal, since nothing it expands to is an
        # architecture lipo reports, but with an unlucky working directory it
        # would produce one refusal per matching filename.
        set -f
        for arch in $wanted_archs; do
            case " $found_archs " in
                *" $arch "*) ;;
                *)
                    set +f
                    verify_fail "$label: not built for $arch - lipo reports [$found_archs]"
                    if [ "$arch" = "arm64" ]; then
                        case "$found_archs" in
                            *arm64e*) verify_note "arm64e is a separate architecture, not a superset of arm64" ;;
                        esac
                    fi
                    return 1
                    ;;
            esac
        done
        set +f
        append_log "  $label: built for $found_archs"
    fi

    if [ -n "$signed_by" ] || [ "$want_hardened" = "1" ] || [ "$want_timestamp" = "1" ]; then
        # Every slice, not just the one this Mac happens to run.
        #
        # codesign --verify and --display report the *native* architecture alone
        # unless told otherwise, so a universal artifact whose x86_64 slice was
        # signed without --options runtime passes every check here on an Apple
        # Silicon machine while the notary service, which looks at all of them,
        # rejects it. That is exactly the "half the build used the wrong
        # settings" mistake this stage exists to catch, and it was passing.
        # Found in review, 2026-08-06.
        #
        # The slice list comes from the executable when there is one. A bundle
        # with no Mach-O inside gets a single pass with no --arch, which is what
        # codesign does anyway.
        local slice_list=""
        if [ -z "$executable" ]; then
            executable="$(artifact_executable "$source")"
        fi
        if [ -n "$executable" ]; then
            slice_list="$(/usr/bin/lipo -archs "$executable" 2>/dev/null || true)"
        fi
        # One pass with an empty architecture means "whatever codesign picks",
        # which is right for a single-slice binary and for a non-Mach-O bundle.
        case "$slice_list" in
            *' '*) ;;
            *) slice_list="" ;;
        esac

        if [ -z "$slice_list" ]; then
            verify_signature "$source" "" "$label" "$signed_by" "$want_hardened" "$want_timestamp" || return 1
        else
            # The whole file first, then every slice. An --arch pass validates
            # the slice it was aimed at and nothing else, so data appended after
            # the signed region - which is how a signed binary gets a payload
            # smuggled into it - passes every per-slice check and is refused
            # only by the whole-file strict validation.
            local whole_file_log="$(state_dir)/codesign.txt"
            run_capture "$whole_file_log" /usr/bin/codesign --verify --strict --verbose=2 "$source"
            if [ "$?" != "0" ]; then
                stop_was_requested && return 1
                verify_fail "$label: the code signature does not verify"
                append_log_file "$whole_file_log"
                return 1
            fi
            set -f
            for arch in $slice_list; do
                set +f
                verify_signature "$source" "$arch" "$label" "$signed_by" "$want_hardened" "$want_timestamp" || return 1
                set -f
            done
            set +f
        fi

        append_log "  $label: signature ok"
    fi

    if [ -n "$version_flag" ]; then
        local project_version="$(model_get /PROJECT/VERSION)"
        # A bundle answers from its Info.plist rather than by being launched:
        # running an .app's executable to ask what version it is starts the app.
        # The flag is still what turns the check on, so this stays the per-entry
        # opt-in of design 7 - a payload can carry a 1.0 helper beside a 2.2 app
        # without the helper's version being read as the release's.
        reported_version="$(artifact_version "$source" "$version_flag")"
        if [ -z "$reported_version" ]; then
            # Which of the two was consulted decides what to say. Telling the
            # user that "--version printed no version" when the value was looked
            # for in an Info.plist points them at a flag that never ran.
            if [ -n "$(bundle_info_plist "$source")" ]; then
                verify_fail "$label: no CFBundleShortVersionString to compare against $project_version"
                verify_note "a bundle answers from its Info.plist; the version flag only runs for a bare executable"
            else
                verify_fail "$label: $version_flag printed no version to compare against $project_version"
            fi
            return 1
        fi
        if [ "$reported_version" != "$project_version" ]; then
            verify_fail "$label: reports version $reported_version, but this is being built as $project_version"
            verify_note "the artifacts folder may be stale - a six-month-old binary shipping under a new version number looks exactly like this"
            return 1
        fi
        append_log "  $label: reports version $reported_version"
    fi

    return 0
}

# Verify every payload entry in order, stopping at the first one that fails.
verify_payload() {
    # Set by the loop below.
    local index
    local entry_count="$(payload_count)"
    if [ "$entry_count" = "0" ]; then
        verify_fail "the payload is empty - there is nothing to verify"
        return 1
    fi
    index=0
    while [ "$index" -lt "$entry_count" ]; do
        # Between two entries there is no tool running for Stop to signal, so
        # the flag is the only thing that can end the stage. On a large payload
        # the alternative is a click that is ignored for the rest of it.
        stop_was_requested && return 1
        verify_payload_entry "$index" || return 1
        index=$((index + 1))
    done
    return 0
}

# --- Staging (design 7 step 2, 8.5) -------------------------------------------
# Build state_dir/root from the payload list.
#
# The root is removed and recreated every time, so an entry deleted from the
# document cannot survive into the next package as a leftover file. rm -rf is
# confined to the state directory (design 8.4), which state_dir owns.
stage_payload_root() {
    # Set once per iteration of the loop below.
    local source destination relative target owner group

    local root="$(state_dir)/root"
    local install_location="$(model_get /COMPONENTS/0/INSTALL_LOCATION)"
    [ -n "$install_location" ] || install_location="/"

    /bin/rm -rf "$root"
    /bin/mkdir -p "$root" || {
        append_log "  ! Could not create the staging root"
        return 1
    }

    local warned_ownership=0
    local entry_count="$(payload_count)"
    local index=0
    while [ "$index" -lt "$entry_count" ]; do
        source="$(resolve_stored_path "$(payload_get "$index" SOURCE)")"
        if [ -z "$source" ]; then
            append_log "  ! Item $((index + 1)) has no resolvable source"
            return 1
        fi
        destination="$(expand_tokens "$(payload_get "$index" DESTINATION)")"
        relative="$(staged_relative_path "$destination" "$install_location")"
        if [ -z "$relative" ]; then
            append_log "  ! Item $((index + 1)) stages to nothing - its destination equals the install location"
            return 1
        fi
        target="$root/$relative"

        if ! /bin/mkdir -p "$(/usr/bin/dirname "$target")"; then
            append_log "  ! Could not create $(/usr/bin/dirname "$relative") in the staging root"
            return 1
        fi
        if ! run_tool "$ditto_tool" "$source" "$target"; then
            # A copy killed by Stop also returns non-zero, and "Could not copy"
            # about a copy nobody let finish would be a false accusation in the
            # log after the run is over. The boundary reports the stop.
            stop_was_requested && return 1
            append_log "  ! Could not copy $source"
            return 1
        fi
        if ! /bin/chmod "$(payload_get "$index" MODE)" "$target"; then
            append_log "  ! Could not set the mode of $relative"
            return 1
        fi

        # Ownership is not applied here and does not need to be: pkgbuild runs
        # with --ownership recommended, which records root:wheel in the BOM
        # whoever runs the build, so no sudo is involved anywhere (design 7
        # step 2). An entry asking for something else is saying something the
        # build cannot honor, so it is said out loud rather than ignored.
        owner="$(payload_get "$index" OWNER)"
        group="$(payload_get "$index" GROUP)"
        if [ "$warned_ownership" = "0" ]; then
            if { [ -n "$owner" ] && [ "$owner" != "root" ]; } || \
               { [ -n "$group" ] && [ "$group" != "wheel" ]; }; then
                append_log "  note: --ownership recommended records root:wheel in the BOM; the owner and group fields are not applied"
                warned_ownership=1
            fi
        fi

        append_log "  staged $relative"
        index=$((index + 1))
    done
    return 0
}

# --- The component package ----------------------------------------------------
# Stage the pre- and postinstall scripts into one directory, because pkgbuild
# takes a directory and the document holds two file paths. Prints the directory
# when there is one, nothing when the document has no scripts.
stage_component_scripts() {
    local preinstall="$(resolve_stored_path "$(model_get /COMPONENTS/0/PREINSTALL)")"
    local postinstall="$(resolve_stored_path "$(model_get /COMPONENTS/0/POSTINSTALL)")"
    [ -n "$preinstall" ] || [ -n "$postinstall" ] || return 0

    local scripts_dir="$(state_dir)/scripts"
    /bin/rm -rf "$scripts_dir"
    /bin/mkdir -p "$scripts_dir" || return 1

    if [ -n "$preinstall" ]; then
        [ -f "$preinstall" ] || { append_log "  ! preinstall script $preinstall is not there"; return 1; }
        /bin/cp "$preinstall" "$scripts_dir/preinstall" || return 1
        /bin/chmod 755 "$scripts_dir/preinstall" || return 1
    fi
    if [ -n "$postinstall" ]; then
        [ -f "$postinstall" ] || { append_log "  ! postinstall script $postinstall is not there"; return 1; }
        /bin/cp "$postinstall" "$scripts_dir/postinstall" || return 1
        /bin/chmod 755 "$scripts_dir/postinstall" || return 1
    fi
    printf '%s' "$scripts_dir"
    return 0
}

# Produce a --component-plist that turns relocation off for every bundle in the
# staged root, and print its path. Prints nothing when the root holds no bundle,
# in which case there is nothing to pass and nothing to turn off.
#
# Design 8.2: pkgbuild marks bundles relocatable, which makes Installer look for
# an existing copy of that bundle identifier anywhere on the volume via
# Spotlight and install there instead. A stale copy in ~/Downloads silently
# becomes the install target.
component_plist_no_relocate() {
    local root="$1"
    local plist="$(state_dir)/component.plist"
    /bin/rm -f "$plist"
    "$pkgbuild_tool" --analyze --root "$root" "$plist" >/dev/null 2>&1 || return 1
    [ -f "$plist" ] || return 0
    local bundle_count="$("$plister" get count "$plist" / 2>/dev/null)"
    case "$bundle_count" in
        ''|*[!0-9]*) bundle_count=0 ;;
    esac
    if [ "$bundle_count" = "0" ]; then
        /bin/rm -f "$plist"
        return 0
    fi
    local index=0
    while [ "$index" -lt "$bundle_count" ]; do
        "$plister" set bool false "$plist" "/$index/BundleIsRelocatable" || return 1
        index=$((index + 1))
    done
    printf '%s' "$plist"
    return 0
}

# Force PackageInfo's overwrite-permissions attribute to what the document says.
#
# Design 8.1: pkgbuild always writes "true", which tells Installer to apply the
# BOM's owner and mode to directories that already exist, not only to ones it
# creates. With a payload under /usr/local/bin the BOM carries /usr/local and
# /usr/local/bin as root:wheel; on a Mac with Homebrew those are owned by the
# console user, so installing resets them and leaves brew unable to write.
# pkgbuild has no option for it, so the fix is an expand/patch/flatten round
# trip. --expand rather than --expand-full leaves Payload and Bom opaque, so the
# round trip cannot disturb them.
#
# Arguments: package path, wanted value ("true"/"false")
patch_overwrite_permissions() {
    local package_path="$1" wanted="$2"
    local expand_dir="$(state_dir)/expand"
    /bin/rm -rf "$expand_dir"
    if ! run_tool "$pkgutil_tool" --expand "$package_path" "$expand_dir"; then
        append_log "  ! Could not expand the component package"
        return 1
    fi
    local package_info="$expand_dir/PackageInfo"
    if [ ! -f "$package_info" ]; then
        append_log "  ! The component package has no PackageInfo"
        /bin/rm -rf "$expand_dir"
        return 1
    fi
    if /usr/bin/grep -q "overwrite-permissions=\"$wanted\"" "$package_info"; then
        append_log "  overwrite-permissions is already $wanted"
        /bin/rm -rf "$expand_dir"
        return 0
    fi
    if ! /usr/bin/grep -q 'overwrite-permissions="' "$package_info"; then
        # Nothing to rewrite. Reported rather than worked around: the attribute
        # is what decides whether an install re-owns existing directories, and
        # guessing at a PackageInfo this build did not recognize is how the
        # harmful package ships.
        append_log "  ! PackageInfo carries no overwrite-permissions attribute; refusing to guess"
        /bin/rm -rf "$expand_dir"
        return 1
    fi
    /usr/bin/sed -i '' "s/overwrite-permissions=\"[a-z]*\"/overwrite-permissions=\"$wanted\"/" "$package_info"
    # The grep is not decoration: a silently failed sed would ship the harmful
    # package (design 8.1).
    if ! /usr/bin/grep -q "overwrite-permissions=\"$wanted\"" "$package_info"; then
        append_log "  ! Could not set overwrite-permissions to $wanted"
        /bin/rm -rf "$expand_dir"
        return 1
    fi
    /bin/rm -f "$package_path"
    if ! run_tool "$pkgutil_tool" --flatten "$expand_dir" "$package_path"; then
        append_log "  ! Could not re-flatten the component package"
        return 1
    fi
    /bin/rm -rf "$expand_dir"
    append_log "  overwrite-permissions set to $wanted"
    return 0
}

# Build the component package from the staged root and print its path.
build_component_package() {
    # "scripts_dir" is declared apart from its assignment because the
    # "|| return 1" has to test stage_component_scripts and not local.
    local scripts_dir
    # Set only when relocation is being turned off.
    local component_plist=""

    local root="$(state_dir)/root"
    local component_dir="$(state_dir)/component"
    local identifier="$(model_get /COMPONENTS/0/IDENTIFIER)"
    local version="$(model_get /PROJECT/VERSION)"
    local name="$(model_get /PROJECT/NAME)"
    local install_location="$(model_get /COMPONENTS/0/INSTALL_LOCATION)"
    [ -n "$install_location" ] || install_location="/"

    /bin/rm -rf "$component_dir"
    /bin/mkdir -p "$component_dir" || return 1
    local package_path="$component_dir/$name.pkg"

    scripts_dir="$(stage_component_scripts)" || return 1

    if [ "$(model_get_bool /COMPONENTS/0/RELOCATABLE)" != "1" ]; then
        component_plist="$(component_plist_no_relocate "$root")" || {
            append_log "  ! Could not analyze the staged root for bundles"
            return 1
        }
        if [ -n "$component_plist" ]; then
            append_log "  bundles in the payload marked non-relocatable"
        fi
    else
        append_log "  note: bundles are left relocatable, as the document asks"
    fi

    # --ownership is passed explicitly rather than left to its default, so the
    # BOM this produces does not change if that default ever does.
    #
    # The argument list is assembled by branching rather than by building a
    # string: an unquoted expansion would split a path containing a space, and
    # there are no arrays here to hold one properly.
    if [ -n "$scripts_dir" ] && [ -n "$component_plist" ]; then
        run_tool "$pkgbuild_tool" --root "$root" --identifier "$identifier" --version "$version" \
            --install-location "$install_location" --ownership recommended \
            --scripts "$scripts_dir" --component-plist "$component_plist" "$package_path"
    elif [ -n "$scripts_dir" ]; then
        run_tool "$pkgbuild_tool" --root "$root" --identifier "$identifier" --version "$version" \
            --install-location "$install_location" --ownership recommended \
            --scripts "$scripts_dir" "$package_path"
    elif [ -n "$component_plist" ]; then
        run_tool "$pkgbuild_tool" --root "$root" --identifier "$identifier" --version "$version" \
            --install-location "$install_location" --ownership recommended \
            --component-plist "$component_plist" "$package_path"
    else
        run_tool "$pkgbuild_tool" --root "$root" --identifier "$identifier" --version "$version" \
            --install-location "$install_location" --ownership recommended "$package_path"
    fi
    if [ "$?" != "0" ]; then
        # Killed by Stop is not a pkgbuild failure; the boundary reports it.
        stop_was_requested && return 1
        append_log "  ! pkgbuild failed"
        return 1
    fi
    if [ ! -f "$package_path" ]; then
        append_log "  ! pkgbuild reported success but wrote no package"
        return 1
    fi

    patch_overwrite_permissions "$package_path" \
        "$(bool_str "$(model_get_bool /COMPONENTS/0/OVERWRITE_PERMISSIONS)")" || return 1

    printf '%s' "$package_path"
    return 0
}

# ==============================================================================
# The distribution package (design section 7 step 3)
# ==============================================================================

# Escape a value for XML. "&" first, or the ampersands introduced by the later
# substitutions would be escaped a second time.
#
# This is the Distribution XML's equivalent of design 4.4's sed hazard: a title
# of "Rock & Roll" written raw produces a document productbuild rejects, and a
# title containing "<" produces one it accepts and mis-renders. Built from
# str_replace rather than sed for the same reason as everything else here.
xml_escape() {
    local text="$1"
    text="$(str_replace "$text" '&' '&amp;')"
    text="$(str_replace "$text" '<' '&lt;')"
    text="$(str_replace "$text" '>' '&gt;')"
    text="$(str_replace "$text" '"' '&quot;')"
    printf '%s' "$text"
}

# Print a choice id derived from a component identifier. The identifier is a
# reverse-DNS string and a choice id is referenced by <line choice="...">, so
# the dots become underscores.
distribution_choice_id() {
    local identifier="$1"
    printf '%s_choice' "$(printf '%s' "$identifier" | /usr/bin/tr -c 'A-Za-z0-9' '_')"
}

# Print DISTRIBUTION/HOST_ARCHITECTURES as productbuild wants it: one
# comma-separated attribute value.
host_architectures_attr() {
    local arch_count="$(model_count /DISTRIBUTION/HOST_ARCHITECTURES)"
    local index=0
    local joined="" arch
    while [ "$index" -lt "$arch_count" ]; do
        arch="$(model_get "/DISTRIBUTION/HOST_ARCHITECTURES/$index")"
        if [ -n "$arch" ]; then
            if [ -z "$joined" ]; then joined="$arch"; else joined="$joined,$arch"; fi
        fi
        index=$((index + 1))
    done
    printf '%s' "$joined"
}

# The five presentation resources, as "MODEL_KEY:xml-element" pairs. One list so
# staging and XML generation cannot drift apart.
DISTRIBUTION_RESOURCE_KINDS="README:readme LICENSE:license WELCOME:welcome CONCLUSION:conclusion BACKGROUND:background"

# Copy every declared presentation resource into a staging directory and print
# it. Prints nothing when the document declares none.
#
# Files are staged flat, under their own basename, and the XML refers to them by
# that basename. productbuild resolves a resource reference at the root of the
# --resources directory, so this works whether the source sat in an en.lproj or
# not. Localized resource sets are not modeled at all (design 4.6), so
# flattening loses nothing the document could express.
stage_distribution_resources() {
    local resources_dir="$(state_dir)/resources"
    # Set once per iteration below.
    local pair model_key source base

    /bin/rm -rf "$resources_dir"

    local staged=0
    for pair in $DISTRIBUTION_RESOURCE_KINDS; do
        model_key="${pair%%:*}"
        source="$(resolve_stored_path "$(model_get "/DISTRIBUTION/RESOURCES/$model_key")")"
        [ -n "$source" ] || continue
        if [ ! -e "$source" ]; then
            append_log "  ! $model_key resource $source is not there"
            return 1
        fi
        if [ "$staged" = "0" ]; then
            /bin/mkdir -p "$resources_dir" || return 1
        fi
        base="$(/usr/bin/basename "$source")"
        # ditto rather than cp: an .rtfd resource is a directory bundle, and cp
        # without -R would refuse it.
        # Through run_tool like every other external call (design 8.4), which
        # also makes this copy reachable by Stop rather than the one tool a
        # stop request could not interrupt.
        run_tool "$ditto_tool" "$source" "$resources_dir/$base" || return 1
        staged=$((staged + 1))
    done

    [ "$staged" -gt 0 ] || return 0
    printf '%s' "$resources_dir"
    return 0
}

# Write the Distribution XML for the document and print its path.
#
# The shape follows replay's hand-written Distribution.xml, which is the file
# this generator replaces: spec version 2 declared honestly because
# allowed-os-versions is a spec 2 feature and productbuild rewrites
# minSpecVersion to 2 regardless.
generate_distribution_xml() {
    local xml_path="$(state_dir)/Distribution.xml"
    local name="$(model_get /PROJECT/NAME)"
    local identifier="$(model_get /COMPONENTS/0/IDENTIFIER)"
    local version="$(model_get /PROJECT/VERSION)"
    local title="$(model_get /DISTRIBUTION/TITLE)"
    local min_os="$(model_get /PROJECT/MIN_OS_VERSION)"
    local customize="$(model_get /DISTRIBUTION/CUSTOMIZE)"
    local auth="$(model_get /COMPONENTS/0/AUTH)"
    local architectures="$(host_architectures_attr)"
    local choice_id="$(distribution_choice_id "$identifier")"
    # Set once per iteration of the resource loop below.
    local pair model_key element source base

    [ -n "$title" ] || title="$name"
    [ -n "$customize" ] || customize="never"
    [ -n "$auth" ] || auth="Root"

    local require_scripts=false
    if [ "$(model_get_bool /DISTRIBUTION/REQUIRE_SCRIPTS)" = "1" ]; then
        require_scripts=true
    fi

    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '%s\n' '<installer-gui-script minSpecVersion="2">'

        printf '    <options'
        if [ -n "$architectures" ]; then
            printf ' hostArchitectures="%s"' "$(xml_escape "$architectures")"
        fi
        printf ' customize="%s" require-scripts="%s"/>\n' \
            "$(xml_escape "$customize")" "$require_scripts"

        if [ -n "$min_os" ]; then
            printf '%s\n' '    <volume-check>'
            printf '%s\n' '        <allowed-os-versions>'
            printf '            <os-version min="%s"/>\n' "$(xml_escape "$min_os")"
            printf '%s\n' '        </allowed-os-versions>'
            printf '%s\n' '    </volume-check>'
        fi

        printf '    <title>%s</title>\n' "$(xml_escape "$title")"

        for pair in $DISTRIBUTION_RESOURCE_KINDS; do
            model_key="${pair%%:*}"
            element="${pair#*:}"
            source="$(resolve_stored_path "$(model_get "/DISTRIBUTION/RESOURCES/$model_key")")"
            [ -n "$source" ] || continue
            base="$(/usr/bin/basename "$source")"
            printf '    <%s file="%s"/>\n' "$element" "$(xml_escape "$base")"
        done

        printf '%s\n' '    <choices-outline>'
        printf '        <line choice="%s"/>\n' "$(xml_escape "$choice_id")"
        printf '%s\n' '    </choices-outline>'
        printf '    <choice id="%s" title="%s" description="">\n' \
            "$(xml_escape "$choice_id")" "$(xml_escape "$title")"
        printf '        <pkg-ref id="%s"/>\n' "$(xml_escape "$identifier")"
        printf '%s\n' '    </choice>'

        # auth on the pkg-ref, not in PackageInfo: pkgbuild has no flag for it
        # and always writes auth="root" into the component regardless, so the
        # Distribution XML is the only place the document's value can land
        # (design section 4).
        printf '    <pkg-ref id="%s" version="%s" auth="%s">#%s.pkg</pkg-ref>\n' \
            "$(xml_escape "$identifier")" "$(xml_escape "$version")" \
            "$(xml_escape "$auth")" "$(xml_escape "$name")"

        printf '%s\n' '</installer-gui-script>'
    } > "$xml_path" || return 1

    printf '%s' "$xml_path"
    return 0
}

# Build the unsigned distribution package from the component package and print
# its path.
#
# The output stays inside the state directory. Only a signed package is ever
# copied to the output folder, so an unsigned artifact never sits one word away
# in the filename from the one that gets uploaded (design 8.3) - which is
# exactly what the old Packages.app flow left behind next to every release.
build_distribution_package() {
    local component_dir="$(state_dir)/component"
    local name="$(model_get /PROJECT/NAME)"
    local unsigned_package="$(state_dir)/${name}-unsigned.pkg"

    local xml_path
    xml_path="$(generate_distribution_xml)" || {
        append_log "  ! Could not write the Distribution XML"
        return 1
    }
    append_log "  wrote Distribution.xml"

    local resources_dir
    resources_dir="$(stage_distribution_resources)" || return 1
    if [ -n "$resources_dir" ]; then
        append_log "  staged presentation resources"
    fi

    /bin/rm -f "$unsigned_package"

    if [ -n "$resources_dir" ]; then
        run_tool /usr/bin/productbuild --distribution "$xml_path" \
            --resources "$resources_dir" --package-path "$component_dir" "$unsigned_package"
    else
        run_tool /usr/bin/productbuild --distribution "$xml_path" \
            --package-path "$component_dir" "$unsigned_package"
    fi
    if [ "$?" != "0" ]; then
        # Killed by Stop is not a productbuild failure; the boundary reports it.
        stop_was_requested && return 1
        append_log "  ! productbuild failed"
        return 1
    fi
    if [ ! -f "$unsigned_package" ]; then
        append_log "  ! productbuild reported success but wrote no package"
        return 1
    fi

    printf '%s' "$unsigned_package"
    return 0
}

# ==============================================================================
# Signing and the output folder (design section 7 step 4, 8.3)
# ==============================================================================

# Succeed when an identity is in this machine's keychain. Whole-line, fixed
# string: an identity contains "(" and ")" and must not be read as a pattern,
# and a prefix match would accept a different team's certificate.
identity_is_present() {
    local wanted="$1"
    [ -n "$wanted" ] || return 1
    list_installer_identities | /usr/bin/grep -qxF "$wanted"
}

# Absolute output folder, or nothing when the document does not name one.
output_dir_abs() {
    local stored="$(model_get /PROJECT/OUTPUT_DIR)"
    [ -n "$stored" ] || return 0
    resolve_stored_path "$stored"
}

# The package's file name, with its tokens expanded and a .pkg extension.
package_file_name() {
    local pattern="$(model_get /PROJECT/PACKAGE_NAME)"
    [ -n "$pattern" ] || pattern='${NAME}_${VERSION}.pkg'
    local expanded="$(expand_tokens "$pattern")"
    [ -n "$expanded" ] || return 0
    # Case-insensitive, so a name already ending in .PKG does not become
    # Foo.PKG.pkg.
    case "$expanded" in
        *.pkg|*.PKG|*.Pkg) ;;
        *) expanded="${expanded}.pkg" ;;
    esac
    printf '%s' "$expanded"
}

check_signing_preconditions() {
    precondition_failures=0

    # Sign Only can run long after the fields it depends on were last valid, so
    # the two that feed the package name are checked here as well as in the
    # component stage. Without this, clearing the project name and running Sign
    # Only produces a signed "_.pkg".
    local name="$(model_get /PROJECT/NAME)"
    local version="$(model_get /PROJECT/VERSION)"
    valid_name "$name" || fail_precondition \
        "Project name \"$name\" is not usable in a filename - use letters, digits, dot, underscore or hyphen"
    valid_version "$version" || fail_precondition \
        "Version \"$version\" is not accepted - it must start with a digit and hold only letters, digits, . + _ or -"

    local name_pattern="$(package_file_name)"
    if [ -z "$name_pattern" ]; then
        fail_precondition "The package file name is empty"
    else
        case "$name_pattern" in
            */*) fail_precondition "The package file name \"$name_pattern\" must not contain a path separator" ;;
        esac
    fi

    local output_dir="$(output_dir_abs)"
    if [ -z "$output_dir" ]; then
        fail_precondition "No output folder is set - choose where the signed package should go"
    elif [ -e "$output_dir" ] && [ ! -d "$output_dir" ]; then
        fail_precondition "The output folder \"$output_dir\" is not a folder"
    elif [ -d "$output_dir" ] && [ ! -w "$output_dir" ]; then
        fail_precondition "The output folder \"$output_dir\" is not writable"
    fi

    if [ "$(model_get_bool /SIGNING/ENABLED)" = "1" ]; then
        local identity="$(model_get /SIGNING/INSTALLER_IDENTITY)"
        if [ -z "$identity" ]; then
            fail_precondition "Signing is on but no installer identity is chosen"
        elif ! identity_is_present "$identity"; then
            fail_precondition "The installer identity \"$identity\" is not in this machine's keychain"
        fi
    fi

    [ "$precondition_failures" -eq 0 ]
}

# Sign the unsigned distribution package into the output folder and print the
# path of the result.
#
# This is the only step that writes outside the state directory, and it writes
# only a signed package (design 8.3). The output folder is created if missing
# and never cleaned (design 8.4).
sign_package() {
    local unsigned="$1"
    local output_dir="$(output_dir_abs)"
    local file_name="$(package_file_name)"
    local identity="$(model_get /SIGNING/INSTALLER_IDENTITY)"

    # Re-checked here and not only in the preconditions. Every stage re-reads
    # the live model, and the fields stay editable while a build runs, so a
    # package name edited to "../elsewhere/x.pkg" between the check and this
    # point would put the writes below outside the output folder entirely.
    case "$file_name" in
        ''|*/*)
            append_log "  ! The package file name \"$file_name\" is not usable"
            return 1
            ;;
    esac

    local final_package="$output_dir/$file_name"

    if [ ! -d "$output_dir" ]; then
        if ! /bin/mkdir -p "$output_dir"; then
            append_log "  ! Could not create the output folder $output_dir"
            return 1
        fi
        append_log "  created $output_dir"
    fi

    # Sign into the state directory and verify there, then put the finished file
    # into the output folder as the very last act.
    #
    # The obvious shape - rm the destination, productsign straight onto it - is
    # wrong twice over. It destroys the previous release's package *before*
    # knowing the new signature will succeed, so a productsign that fails (the
    # keychain prompt declined, a full disk) leaves the output folder empty
    # where a good package used to be; rebuilding the same version is the normal
    # retry case, so this is reachable in ordinary use. And it writes into the
    # output folder for the whole duration of productsign, so a build killed
    # mid-run - app quit, which kills the recorded process group - strands a
    # partial, unsigned file named exactly like a real package. That is the one
    # outcome design 8.3 exists to prevent. Found in review, 2026-08-06.
    local staged_signed="$(state_dir)/signed.pkg"
    /bin/rm -f "$staged_signed"

    if ! run_tool /usr/bin/productsign --sign "$identity" "$unsigned" "$staged_signed"; then
        # Killed by Stop is not a productsign failure; the boundary reports it.
        # The partial file still goes: it is in the state dir, but a half-signed
        # package is not something to leave lying around under any name.
        /bin/rm -f "$staged_signed"
        stop_was_requested && return 1
        append_log "  ! productsign failed; the output folder was not touched"
        return 1
    fi
    if [ ! -f "$staged_signed" ]; then
        append_log "  ! productsign reported success but wrote no package"
        return 1
    fi
    if ! run_tool /usr/sbin/pkgutil --check-signature "$staged_signed"; then
        # A check killed by Stop has not found anything wrong with the package,
        # and saying it did not verify would be the worst of the five false
        # verdicts: an accusation against a correctly-signed artifact.
        /bin/rm -f "$staged_signed"
        stop_was_requested && return 1
        append_log "  ! The signed package did not verify; the output folder was not touched"
        return 1
    fi

    # Land it through a temp file in the output folder itself and rename, so the
    # replacement is a rename rather than a window during which the destination
    # is absent or half-written. The temp is a sibling, so the rename stays
    # within one filesystem even when the output folder is on another volume.
    local landing="$output_dir/.${file_name}.$$.pbsigning"
    /bin/rm -f "$landing"
    if ! /bin/cp "$staged_signed" "$landing"; then
        append_log "  ! Could not write into the output folder $output_dir"
        /bin/rm -f "$landing"
        return 1
    fi
    if ! /bin/mv -f "$landing" "$final_package"; then
        append_log "  ! Could not put the signed package in place"
        /bin/rm -f "$landing"
        return 1
    fi
    /bin/rm -f "$staged_signed"

    if [ ! -f "$final_package" ]; then
        append_log "  ! The signed package is not where it should be"
        return 1
    fi

    printf '%s' "$final_package"
    return 0
}

built_package_path() {
    local record="$(state_dir)/built_package.txt"
    [ -f "$record" ] || return 0
    local package_path="$(/bin/cat "$record")"
    [ -n "$package_path" ] || return 0
    [ -f "$package_path" ] || return 0
    printf '%s' "$package_path"
}

# --- Run bookkeeping ----------------------------------------------------------
# A build records its own process group id so app.will.terminate can stop a
# survivor, and holds a busy flag so a second one cannot start on top of it.
# Succeed while a build is actually running.
#
# The flag alone is not enough: a handler killed before it reaches build_end
# leaves pb_busy set, and every later build would answer "A build is already
# running" until the window was closed. So the recorded process group is checked
# for life, the same treatment model_lock got after the Phase 2 review.
#
# This is a guard against a second build, not a lock: two clicks close enough
# together can both pass before either calls build_begin. A real lock belongs
# with the Stop button in Phase 4, which is also what gives a hung productsign
# an escape.
build_is_running() {
    [ "$(pb_get pb_busy)" = "1" ] || return 1
    local pid_file="$(state_dir)/run.pid"
    if [ ! -f "$pid_file" ]; then
        pb_set pb_busy ""
        return 1
    fi
    local holder_pid="$(/bin/cat "$pid_file" 2>/dev/null)"
    case "$holder_pid" in
        ''|*[!0-9]*)
            pb_set pb_busy ""
            /bin/rm -f "$pid_file"
            return 1
            ;;
    esac
    if /bin/kill -0 "$holder_pid" 2>/dev/null; then
        return 0
    fi
    dbg "build_is_running: clearing a busy flag left by dead pid $holder_pid"
    pb_set pb_busy ""
    /bin/rm -f "$pid_file"
    return 1
}

# Print the component package the last component build produced, or nothing when
# there is none on disk any more.
built_component_path() {
    local record="$(state_dir)/built_component.txt"
    [ -f "$record" ] || return 0
    local package_path="$(/bin/cat "$record")"
    [ -n "$package_path" ] || return 0
    [ -f "$package_path" ] || return 0
    printf '%s' "$package_path"
}

# Print the unsigned distribution package the last distribution build produced.
built_distribution_path() {
    local record="$(state_dir)/built_distribution.txt"
    [ -f "$record" ] || return 0
    local package_path="$(/bin/cat "$record")"
    [ -n "$package_path" ] || return 0
    [ -f "$package_path" ] || return 0
    printf '%s' "$package_path"
}

build_begin() {
    clear_stop_request
    /bin/rm -f "$(state_dir)/tool.pid"
    pb_set pb_busy 1
    printf '%s' "$$" > "$(state_dir)/run.pid"
    # The process group as well as the pid. A group kill is the only way to
    # reach a tool's own children, and it is also the way to kill the
    # application by accident: a process group id is the pid of its leader, so
    # "kill -TERM -<pid>" against a handler that inherited the app's group would
    # take the app down with it. Whether OMC starts handlers as group leaders is
    # not something this app has established, so the group is recorded and the
    # one caller that negates it compares the two first.
    /bin/ps -o pgid= -p $$ 2>/dev/null | /usr/bin/tr -d ' ' > "$(state_dir)/run.pgid"
    enable_view "$ACTIONS_MENU_ID" 0
    enable_view "$BUILD_BTN_ID" 0
    enable_view "$STOP_BTN_ID" 1
    show_progress 1
    return 0
}

build_end() {
    show_progress 0
    enable_view "$STOP_BTN_ID" 0
    enable_view "$BUILD_BTN_ID" 1
    enable_view "$ACTIONS_MENU_ID" 1
    pb_set pb_busy ""
    /bin/rm -f "$(state_dir)/run.pid" "$(state_dir)/run.pgid" "$(state_dir)/tool.pid"
    clear_stop_request
    return 0
}

# --- Stopping a run -----------------------------------------------------------
# Stop is a request, not a kill. The handler raises a flag and terminates the
# tool the build is currently inside; the build script's own error handling
# notices, unwinds through the exit path it already has, and leaves the window
# saying what happened.
#
# Killing the build script itself would be simpler and is what the process-group
# kill in app.will.terminate does - but that is a script running while the app
# goes away, with no window left to put back. Here there is: a build script
# killed mid-stage leaves the rail frozen part-way, the Actions menu disabled
# and the busy flag set, which is precisely the wedged window the Phase 3 review
# found and the liveness check in build_is_running had to paper over.

stop_flag_file() {
    printf '%s/stop-requested' "$(state_dir)"
}

# Succeed when the user has asked the running build to stop.
stop_was_requested() {
    [ -f "$(stop_flag_file)" ]
}

clear_stop_request() {
    /bin/rm -f "$(stop_flag_file)"
    return 0
}

# Raise the flag and signal the tool the build is inside. Nothing here touches
# the window: the build script is still alive and owns it, and two writers to
# the same views would race to describe the same event.
request_stop() {
    /usr/bin/touch "$(stop_flag_file)"
    local tool_pid="$(/bin/cat "$(state_dir)/tool.pid" 2>/dev/null)"
    case "$tool_pid" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$tool_pid" -gt 1 ] || return 0
    # Only if it is still the build's own child. run_capture removes this file
    # the moment the tool is reaped, but the gap between those two events is
    # real, and a pid that has been recycled in it belongs to a stranger.
    # Parentage is the check that settles it: the tool's command line is
    # codesign or productsign against a path that need not be ours, but its
    # parent is the build script and nothing else's child is.
    local build_pid="$(/bin/cat "$(state_dir)/run.pid" 2>/dev/null)"
    case "$build_pid" in
        ''|*[!0-9]*) return 0 ;;
    esac
    local tool_parent="$(/bin/ps -o ppid= -p "$tool_pid" 2>/dev/null | /usr/bin/tr -d ' ')"
    if [ "$tool_parent" != "$build_pid" ]; then
        dbg "request_stop: tool pid $tool_pid is no longer the build's child, flag only"
        return 0
    fi
    dbg "request_stop: terminating tool pid $tool_pid"
    /bin/kill -TERM "$tool_pid" 2>/dev/null
    return 0
}

# Wind up a stopped run and put the window back.
# Arguments: the rail icon of the stage that did not finish
#
# Marked skipped rather than failed. Nothing failed - the user asked for this -
# and at a boundary between two stages the icon belongs to a stage that had not
# started, where a red X would read as a defect in the project.
report_stop() {
    local rail_id="$1"
    rail_set "$rail_id" skipped
    append_log ""
    append_log "Stopped at your request."
    append_log ""
    append_log "The output folder was not given a package: one only ever lands there"
    append_log "after it has been signed and its signature checked."
    set_status "Stopped"
    build_end
    return 0
}

# Succeed - having already put the window back - when the run should end here.
# One call per stage boundary, so a stop between two tools is noticed as
# promptly as one that interrupted a tool.
# Arguments: the rail icon of the stage that was interrupted
stop_here() {
    local rail_id="$1"
    stop_was_requested || return 1
    report_stop "$rail_id"
    return 0
}

# ==============================================================================
# The whole pipeline (design section 7)
# ==============================================================================
# All four stages in one run, driven by the toolbar's Build Package and by the
# agent CLI's "build". It lives here rather than in the handler so that the two
# frontends run the same pipeline rather than two copies of it that drift: the
# only thing either of them decides is which presentation layer was sourced,
# and everything below reports through that.
#
# Every stage's preconditions are checked up front, before anything is written.
# Discovering a missing output folder after pkgbuild and productbuild have
# already run would mean waiting through the whole build to be told something
# that was knowable at the start.
#
# Calls build_end on every exit path, including the successful one, so a caller
# does not have to unwind. Returns 0 when the run produced what the document
# asked for - including a stop, which is not a failure - and 1 otherwise. The
# artifacts it produced are on record in the state directory
# (built_component.txt, built_distribution.txt, built_package.txt).
run_pipeline() {
    # Set by the stages below.
    local component unsigned signed

    # Fixed once for the whole run, so a build that crosses midnight cannot
    # name two files two different things (design 4.4).
    PB_BUILD_DATE="$(/bin/date '+%Y-%m-%d')"
    export PB_BUILD_DATE

    local signing_on="$(model_get_bool /SIGNING/ENABLED)"

    build_begin
    clear_log
    rail_reset
    /bin/rm -f "$(state_dir)/built_component.txt" \
               "$(state_dir)/built_distribution.txt" \
               "$(state_dir)/built_package.txt"
    show_view "$REVEAL_BTN_ID" 0
    # Turned off with Reveal: a failed rebuild deletes built_package.txt, and an
    # enabled Notarize button would still be offering the package it just removed.
    enable_view "$NOTARIZE_BTN_ID" 0

    set_status "Checking the project..."
    append_log "Building $(document_name)"
    append_log ""
    append_log "Preconditions:"

    # The count comes from the shared global after each call, not from the
    # return value: a shell return carries only the low eight bits, so a count
    # of exactly 256 would arrive here as zero and wave the build through. Each
    # function resets the global on entry, so it is read immediately after each.
    local total_failures=0
    check_preconditions
    total_failures=$((total_failures + precondition_failures))
    check_distribution_preconditions
    total_failures=$((total_failures + precondition_failures))
    if [ "$signing_on" = "1" ]; then
        check_signing_preconditions
        total_failures=$((total_failures + precondition_failures))
    fi

    if [ "$total_failures" != "0" ]; then
        append_log ""
        append_log "Stopped: $total_failures problem(s) to fix before anything can be built."
        rail_set "$RAIL_COMPONENT_ID" failed
        set_status "$total_failures problem(s) - nothing was written"
        build_end
        return 1
    fi
    append_log "  all clear"
    append_log ""

    # --- Stage 1: verify ------------------------------------------------------
    # Before anything is staged, because this is the stage that decides whether
    # the artifacts on disk are the artifacts the document describes. A package
    # built from a stale or wrongly-signed binary is worse than no package: it
    # is signed, it installs, and nothing about it looks wrong until it reaches
    # a user.
    rail_set "$RAIL_VERIFY_ID" running
    set_status "Verifying the payload..."
    append_log "Verifying the payload:"
    if ! verify_payload; then
        stop_here "$RAIL_VERIFY_ID" && return 0
        append_log ""
        append_log "Stopped. An artifact is not what the document says it is, and nothing"
        append_log "was staged or built."
        rail_set "$RAIL_VERIFY_ID" failed
        set_status "The payload did not verify"
        build_end
        return 1
    fi
    stop_here "$RAIL_VERIFY_ID" && return 0
    rail_set "$RAIL_VERIFY_ID" done
    append_log ""

    # --- Stage 2: component ---------------------------------------------------
    rail_set "$RAIL_COMPONENT_ID" running
    set_status "Staging the payload..."
    append_log "Staging the payload root:"
    if ! stage_payload_root; then
        stop_here "$RAIL_COMPONENT_ID" && return 0
        append_log ""
        append_log "Stopped while staging. Nothing outside the scratch directory was touched."
        rail_set "$RAIL_COMPONENT_ID" failed
        set_status "Could not stage the payload"
        build_end
        return 1
    fi

    append_log ""
    set_status "Running pkgbuild..."
    append_log "Building the component package:"
    component="$(build_component_package)"
    if [ -z "$component" ] || [ ! -f "$component" ]; then
        stop_here "$RAIL_COMPONENT_ID" && return 0
        append_log ""
        append_log "Stopped. pkgbuild did not produce a component package."
        rail_set "$RAIL_COMPONENT_ID" failed
        set_status "The component package was not built"
        build_end
        return 1
    fi
    printf '%s' "$component" > "$(state_dir)/built_component.txt"
    rail_set "$RAIL_COMPONENT_ID" done
    stop_here "$RAIL_DISTRIBUTION_ID" && return 0

    # --- Stage 3: distribution ------------------------------------------------
    append_log ""
    rail_set "$RAIL_DISTRIBUTION_ID" running
    set_status "Running productbuild..."
    append_log "Building the distribution package:"
    unsigned="$(build_distribution_package)"
    if [ -z "$unsigned" ] || [ ! -f "$unsigned" ]; then
        stop_here "$RAIL_DISTRIBUTION_ID" && return 0
        append_log ""
        append_log "Stopped. productbuild did not produce a distribution package."
        rail_set "$RAIL_DISTRIBUTION_ID" failed
        set_status "The distribution package was not built"
        build_end
        return 1
    fi
    printf '%s' "$unsigned" > "$(state_dir)/built_distribution.txt"
    rail_set "$RAIL_DISTRIBUTION_ID" done
    stop_here "$RAIL_SIGN_ID" && return 0

    # --- Stage 4: sign --------------------------------------------------------
    if [ "$signing_on" != "1" ]; then
        # Design 8.3: the output folder only ever receives a signed package, so
        # an unsigned build ends in the scratch directory and says so.
        rail_set "$RAIL_SIGN_ID" skipped
        append_log ""
        append_log "Signing is turned off, so nothing was written to the output folder."
        append_log "The unsigned package is an intermediate and stays here:"
        append_log "  $unsigned"
        set_status "Built $(/usr/bin/basename "$unsigned") (unsigned)"
        build_end
        return 0
    fi

    append_log ""
    rail_set "$RAIL_SIGN_ID" running
    set_status "Running productsign..."
    append_log "Signing the installer package:"
    signed="$(sign_package "$unsigned")"
    if [ -z "$signed" ] || [ ! -f "$signed" ]; then
        stop_here "$RAIL_SIGN_ID" && return 0
        append_log ""
        append_log "Stopped. The package was not signed, and nothing was left in the output folder."
        rail_set "$RAIL_SIGN_ID" failed
        set_status "The package was not signed"
        build_end
        return 1
    fi
    printf '%s' "$signed" > "$(state_dir)/built_package.txt"
    rail_set "$RAIL_SIGN_ID" done

    # The one thing the two frontends say differently, because what comes after
    # a signed package is a button in the app and a command in a terminal.
    report_next_step "$signed"

    set_status "Built $(/usr/bin/basename "$signed")"
    build_end
    return 0
}
