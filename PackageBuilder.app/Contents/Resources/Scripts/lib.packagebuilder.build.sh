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

# How a component is named inside a diagnostic.
#
# Empty when the document holds one component: with nothing to distinguish, a
# prefix would only be noise, and every message below then reads exactly the way
# it read when a document could not hold more than one. With several components
# the same message without this would send the reader to the wrong payload.
#
# It is a prefix rather than part of the item label because the messages refer
# back to an item by a bare lowercase number ("installs inside item 1"), and that
# back-reference has to stay a number.
component_prefix() {
    if [ "$(component_count)" -gt 1 ]; then
        printf 'Component %s: ' "$((PB_COMPONENT_INDEX + 1))"
    fi
}

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

# Print the spelling the FILE SYSTEM will actually use for an absolute install
# path, by making it inside a throwaway tree and asking what came out. Arguments:
# probe root, absolute path.
#
# This exists because the nesting gate is a string comparison and the volume the
# payload stages on folds case and folds NFD to NFC: "/opt/DIR" and "/opt/dir",
# or the NFC and NFD spellings of one accented name, are a single directory there
# while comparing unequal in the shell. Two entries whose destinations differ
# only that way therefore merged into one directory with the document reported
# clean - which design 4.1 forbids, because the second entry's ditto races the
# first.
#
# Every destination is made inside ONE probe tree, so a case-variant sibling
# lands in the directory its predecessor created and canonicalizes to the same
# name. Comparing those canonical forms makes both the equality test and the
# prefix test fold-correct, without resolving anything lexically and without
# Python (design 12). On any failure it returns the path unchanged, so the gate
# degrades to the string comparison it was rather than to no gate at all.
fold_install_path() {
    local probe_root="$1" path="$2"
    local relative folded
    relative="${path#/}"
    if [ -z "$relative" ]; then
        printf '/'
        return 0
    fi
    /bin/mkdir -p "$probe_root/$relative" 2>/dev/null || {
        printf '%s' "$path"
        return 0
    }
    folded="$(canonical_path "$probe_root/$relative")"
    if [ -z "$folded" ] || [ "$folded" = "$probe_root" ]; then
        printf '%s' "$path"
        return 0
    fi
    printf '/%s' "${folded#"$probe_root"/}"
}

check_preconditions() {
    # Set once per iteration of the loops below.
    local source destination mode stored_source item_number
    local other_index other_destination
    local folded_destination folded_other probe_root

    precondition_failures=0

    # One throwaway tree for the whole check; see fold_install_path.
    probe_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pbfold.XXXXXX" 2>/dev/null)" || probe_root=""

    local name="$(model_get /PROJECT/NAME)"
    local version="$(model_get /PROJECT/VERSION)"
    local identifier install_location entry_count index
    local component_index total_components saved_component

    valid_name "$name" || fail_precondition \
        "Project name \"$name\" is not usable in a filename - use letters, digits, dot, underscore or hyphen"
    valid_version "$version" || fail_precondition \
        "Version \"$version\" is not accepted - it must start with a digit and hold only letters, digits, . + _ or -"

    # Every accessor in the body below reads the current component, so the loop
    # moves the whole check from one component to the next by setting one
    # variable rather than by threading an index through thirty calls. The
    # previous value is restored afterwards because this runs inside a handler
    # that may go on to touch the component the window is editing.
    total_components="$(component_count)"
    saved_component="$PB_COMPONENT_INDEX"
    component_index=0
    while [ "$component_index" -lt "$total_components" ]; do
    PB_COMPONENT_INDEX="$component_index"
    identifier="$(component_get IDENTIFIER)"
    install_location="$(component_get INSTALL_LOCATION)"
    [ -n "$install_location" ] || install_location="/"

    valid_identifier "$identifier" || fail_precondition \
        "$(component_prefix)Identifier \"$identifier\" does not look like a reverse-DNS string, for example com.example.pkg.tool"

    case "$install_location" in
        /*) ;;
        *) fail_precondition "$(component_prefix)Install location \"$install_location\" must be an absolute path" ;;
    esac

    entry_count="$(payload_count)"
    if [ "$entry_count" = "0" ]; then
        fail_precondition "$(component_prefix)The payload is empty - add at least one artifact"
    fi

    index=0
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
            fail_precondition "$(component_prefix)Item $item_number uses \${ARTIFACTS_DIR} but no artifacts folder is set"
            source=""
        elif [ -z "$stored_source" ]; then
            fail_precondition "$(component_prefix)Item $item_number has no source"
            source=""
        else
            source="$(resolve_stored_path "$stored_source")"
            if [ -z "$source" ]; then
                fail_precondition "$(component_prefix)Item $item_number: \"$stored_source\" could not be resolved to a path"
            elif [ ! -e "$source" ]; then
                fail_precondition "$(component_prefix)Item $item_number: $source is not there"
            elif [ ! -r "$source" ]; then
                fail_precondition "$(component_prefix)Item $item_number: $source cannot be read"
            fi
        fi

        if [ -z "$destination" ]; then
            fail_precondition "$(component_prefix)Item $item_number has no destination"
        else
            case "$destination" in
                /*) ;;
                *) fail_precondition "$(component_prefix)Item $item_number: destination \"$destination\" must be an absolute path" ;;
            esac
            # A ".." component escapes the staging root, and the install-location
            # test below cannot see it: that test is a literal prefix match, so
            # "/usr/local/../.." passes it while naming the root. Staging is a
            # ditto into "$staging_root/$destination", so what got through wrote
            # wherever the dots led, under the user's own privileges and over
            # anything already there. Refused here, where the message can name
            # the real objection, and again in stage_payload_root.
            if path_has_dotdot "$destination"; then
                fail_precondition "$(component_prefix)Item $item_number: destination \"$destination\" must not contain \"..\""
            else
                # Every test below compares strings, so they are given the one
                # spelling. "/opt/a/./b" and "/opt/a//b" name a path under
                # "/opt/a" while matching no prefix test for it, which let an
                # entry install inside another entry's directory unnoticed - and
                # if that directory arrived carrying a symlink, ditto followed it
                # straight out of the staging root.
                destination="$(normalize_path "$destination")"
                if ! path_is_under "$destination" "$install_location"; then
                    fail_precondition "$(component_prefix)Item $item_number: destination \"$destination\" is not under the install location \"$install_location\""
                fi
            fi
        fi

        valid_mode "$mode" || fail_precondition \
            "$(component_prefix)Item $item_number: mode \"$mode\" is not three or four octal digits"

        # Two destinations in one component may not be equal, and one may not be
        # a strict prefix of another: the second entry's ditto would race the
        # first (design 4.1). Only later entries are compared, so a clash is
        # reported once rather than from both ends.
        other_index=$((index + 1))
        while [ "$other_index" -lt "$entry_count" ]; do
            # Normalized on both sides, for the reason given above: the nesting
            # test is the gate that stops one entry writing into another's
            # directory, and it is a literal prefix comparison.
            other_destination="$(normalize_path "$(expand_tokens "$(payload_get "$other_index" DESTINATION)")")"
            if [ -n "$destination" ] && [ -n "$other_destination" ]; then
                # Compared in the spelling the file system will use, not the one
                # the document holds. The messages still name what the document
                # says, because that is what the reader has to go and change.
                if [ -n "$probe_root" ]; then
                    folded_destination="$(fold_install_path "$probe_root" "$destination")"
                    folded_other="$(fold_install_path "$probe_root" "$other_destination")"
                else
                    folded_destination="$destination"
                    folded_other="$other_destination"
                fi
                if [ "$folded_destination" = "$folded_other" ]; then
                    fail_precondition "$(component_prefix)Items $item_number and $((other_index + 1)) install to the same path: $destination"
                elif path_is_under "$folded_other" "$folded_destination"; then
                    fail_precondition "$(component_prefix)Item $((other_index + 1)) installs inside item $item_number: $other_destination is under $destination"
                elif path_is_under "$folded_destination" "$folded_other"; then
                    fail_precondition "$(component_prefix)Item $item_number installs inside item $((other_index + 1)): $destination is under $other_destination"
                fi
            fi
            other_index=$((other_index + 1))
        done

        index=$((index + 1))
    done

    component_index=$((component_index + 1))
    done
    PB_COMPONENT_INDEX="$saved_component"

    check_cross_component_destinations "$probe_root"

    [ -z "$probe_root" ] || /bin/rm -rf "$probe_root"

    [ "$precondition_failures" -eq 0 ]
}

# Refuse two components that install to the same path, or one inside another.
#
# The loop above compares destinations pairwise within one component, which is
# where a clash could arise when a document held only one. Splitting a payload
# across components is exactly the moment a path gets duplicated by accident -
# the same artifact left behind in the component it was moved out of - and
# nothing in pkgbuild or productbuild objects: the two component packages are
# built independently and the later one silently wins at install time.
#
# Only pairs of DIFFERENT components are compared here; a component against
# itself is the loop above, and repeating it would report every clash twice.
#
# Arguments: the probe root for case folding, which may be empty.
check_cross_component_destinations() {
    local probe_root="$1"
    local total_components="$(component_count)"
    [ "$total_components" -gt 1 ] || return 0

    # Set once per iteration of the four loops below.
    local first second first_index second_index first_count second_count
    local first_destination second_destination folded_first folded_second

    first=0
    while [ "$first" -lt "$total_components" ]; do
        first_count="$(payload_count "$first")"
        second=$((first + 1))
        while [ "$second" -lt "$total_components" ]; do
            second_count="$(payload_count "$second")"
            first_index=0
            while [ "$first_index" -lt "$first_count" ]; do
                # Read from the model rather than from a list collected up front:
                # a destination may hold any character a path may hold, and a
                # list in a file or a variable would have to pick a separator
                # that one of them could be.
                first_destination="$(normalize_path "$(expand_tokens "$(payload_get "$first_index" DESTINATION "$first")")")"
                if [ -z "$first_destination" ]; then
                    first_index=$((first_index + 1))
                    continue
                fi
                if [ -n "$probe_root" ]; then
                    folded_first="$(fold_install_path "$probe_root" "$first_destination")"
                else
                    folded_first="$first_destination"
                fi
                second_index=0
                while [ "$second_index" -lt "$second_count" ]; do
                    second_destination="$(normalize_path "$(expand_tokens "$(payload_get "$second_index" DESTINATION "$second")")")"
                    if [ -z "$second_destination" ]; then
                        second_index=$((second_index + 1))
                        continue
                    fi
                    if [ -n "$probe_root" ]; then
                        folded_second="$(fold_install_path "$probe_root" "$second_destination")"
                    else
                        folded_second="$second_destination"
                    fi
                    if [ "$folded_first" = "$folded_second" ]; then
                        fail_precondition "Component $((first + 1)) item $((first_index + 1)) and component $((second + 1)) item $((second_index + 1)) install to the same path: $first_destination"
                    elif path_is_under "$folded_second" "$folded_first"; then
                        fail_precondition "Component $((second + 1)) item $((second_index + 1)) installs inside component $((first + 1)) item $((first_index + 1)): $second_destination is under $first_destination"
                    elif path_is_under "$folded_first" "$folded_second"; then
                        fail_precondition "Component $((first + 1)) item $((first_index + 1)) installs inside component $((second + 1)) item $((second_index + 1)): $first_destination is under $second_destination"
                    fi
                    second_index=$((second_index + 1))
                done
                first_index=$((first_index + 1))
            done
            second=$((second + 1))
        done
        first=$((first + 1))
    done
    return 0
}

# Preconditions for the distribution stage. Separate from the component stage's
# because the two partial actions can be run independently, and a distribution
# run must not fail on a payload problem that has nothing to do with it.
check_distribution_preconditions() {
    # Set once per iteration below.
    local pair model_key stored source

    precondition_failures=0

    local version="$(model_get /PROJECT/VERSION)"
    local name="$(model_get /PROJECT/NAME)"
    local identifier component_index total_components saved_component

    valid_name "$name" || fail_precondition \
        "Project name \"$name\" is not usable in a filename - use letters, digits, dot, underscore or hyphen"
    valid_version "$version" || fail_precondition \
        "Version \"$version\" is not accepted - it must start with a digit and hold only letters, digits, . + _ or -"

    total_components="$(component_count)"
    saved_component="$PB_COMPONENT_INDEX"
    component_index=0
    while [ "$component_index" -lt "$total_components" ]; do
        PB_COMPONENT_INDEX="$component_index"
        identifier="$(component_get IDENTIFIER "$component_index")"
        valid_identifier "$identifier" || fail_precondition \
            "$(component_prefix)Identifier \"$identifier\" does not look like a reverse-DNS string, for example com.example.pkg.tool"
        component_index=$((component_index + 1))
    done
    PB_COMPONENT_INDEX="$saved_component"

    check_component_identifier_collisions

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
    # The collision is asked of the FILE SYSTEM, not of a string comparison.
    # Resources are staged flat, so the collision that matters is the one the
    # file system will actually make - and the volume this stages on folds case
    # and folds NFD to NFC, so "README.txt" and "readme.txt", or the NFC and NFD
    # spellings of one accented name, are a single file there while comparing
    # unequal in the shell. A string compare therefore called a wrong package
    # clean: the license text shipped as the readme, exactly the outcome the
    # paragraph above says this check exists to prevent. Touching one marker per
    # basename and asking whether it already exists gets case folding, Unicode
    # folding and anything else the volume does, for free and without Python
    # (design 12).
    local seen_dir base
    seen_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pbresnames.XXXXXX" 2>/dev/null)" || seen_dir=""
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
        # A resource is staged under its own file name. "." and ".." are not file
        # names, and basename "/" is "/" rather than the empty string, so the
        # "*/*" arm is what catches a resource of "/" - which would otherwise
        # aim a copy at the staging directory itself.
        case "$base" in
            ''|.|..|*/*)
                fail_precondition "The $model_key resource $stored does not name a file"
                continue
                ;;
        esac
        if [ -n "$seen_dir" ]; then
            if [ -e "$seen_dir/$base" ]; then
                fail_precondition "Two presentation resources are both named \"$base\" - the installer can only show one of them"
            else
                : > "$seen_dir/$base" 2>/dev/null
            fi
        fi
    done
    [ -z "$seen_dir" ] || /bin/rm -rf "$seen_dir"

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
# Refuse a set of components whose identifiers cannot be told apart downstream.
#
# Two distinct failures with one cause. Two components sharing an identifier
# collide in the choices-outline and give productbuild two pkg-refs with the
# same id. And two identifiers that merely sanitize the same - "com.example.a-b"
# and "com.example.a_b" both become "com_example_a_b" - collide in the choice
# id and, because component_package_basename uses the same sanitizer, write over
# each other's file in the directory productbuild scans. The second is the
# nastier of the two: nothing fails, and the product ships with one component
# silently replaced by the other.
check_component_identifier_collisions() {
    local total_components="$(component_count)"
    [ "$total_components" -gt 1 ] || return 0

    local first second first_identifier second_identifier

    first=0
    while [ "$first" -lt "$total_components" ]; do
        first_identifier="$(component_get IDENTIFIER "$first")"
        second=$((first + 1))
        while [ "$second" -lt "$total_components" ]; do
            second_identifier="$(component_get IDENTIFIER "$second")"
            if [ "$first_identifier" = "$second_identifier" ]; then
                fail_precondition "Components $((first + 1)) and $((second + 1)) have the same identifier \"$first_identifier\" - each component needs its own"
            elif [ "$(sanitize_component_token "$first_identifier")" = \
                   "$(sanitize_component_token "$second_identifier")" ]; then
                fail_precondition "Components $((first + 1)) and $((second + 1)) have identifiers that differ only in punctuation (\"$first_identifier\" and \"$second_identifier\") - they would share one choice and overwrite each other's package file"
            fi
            second=$((second + 1))
        done
        first=$((first + 1))
    done
    return 0
}

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
    # With one component the label reads exactly as it always did; with several,
    # "item 2" alone does not say which payload it is in.
    local in_component=""
    [ "$(component_count)" -le 1 ] || in_component="component $((PB_COMPONENT_INDEX + 1)) "
    local label="${in_component}item $item_number"
    [ -z "$source" ] || label="${in_component}item $item_number ($(/usr/bin/basename "$source"))"

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
    # Set by the loops below.
    local index entry_count component_index
    local total_components="$(component_count)"
    local saved_component="$PB_COMPONENT_INDEX"

    component_index=0
    while [ "$component_index" -lt "$total_components" ]; do
        # verify_payload_entry reads the current component, like every other
        # payload reader. Restored on every exit below, including the failing
        # ones, so a refused build leaves the window editing the component it
        # was editing before.
        PB_COMPONENT_INDEX="$component_index"
        entry_count="$(payload_count)"
        if [ "$entry_count" = "0" ]; then
            if [ "$total_components" -le 1 ]; then
                verify_fail "the payload is empty - there is nothing to verify"
            else
                verify_fail "component $((component_index + 1)) has an empty payload - there is nothing to verify"
            fi
            PB_COMPONENT_INDEX="$saved_component"
            return 1
        fi
        index=0
        while [ "$index" -lt "$entry_count" ]; do
            # Between two entries there is no tool running for Stop to signal,
            # so the flag is the only thing that can end the stage. On a large
            # payload the alternative is a click that is ignored for the rest
            # of it.
            if stop_was_requested; then
                PB_COMPONENT_INDEX="$saved_component"
                return 1
            fi
            if ! verify_payload_entry "$index"; then
                PB_COMPONENT_INDEX="$saved_component"
                return 1
            fi
            index=$((index + 1))
        done
        component_index=$((component_index + 1))
    done
    PB_COMPONENT_INDEX="$saved_component"
    return 0
}

# --- Staging (design 7 step 2, 8.5) -------------------------------------------
# A scratch path belonging to one component.
#
# Component 0 keeps the unsuffixed name, so a single component's build lays out
# its scratch directory exactly as it always did. That is not only tidiness:
# three assertions elsewhere prove a stage did NOT run by looking for the
# absence of "root", and renaming it out from under them would make them pass
# whatever the build did.
#
# Arguments: base name, component index, optional extension
component_scratch() {
    local base="$1" component_index="$2" extension="$3"
    if [ "$component_index" = "0" ]; then
        printf '%s/%s%s' "$(state_dir)" "$base" "$extension"
    else
        printf '%s/%s-%s%s' "$(state_dir)" "$base" "$component_index" "$extension"
    fi
}

# Build state_dir/root from the payload list.
#
# The root is removed and recreated every time, so an entry deleted from the
# document cannot survive into the next package as a leftover file. rm -rf is
# confined to the state directory (design 8.4), which state_dir owns.
stage_payload_root() {
    # Set once per iteration of the loop below.
    local source destination relative target owner group
    local target_parent real_parent real_root ancestor ancestor_next

    local component_index="$1"
    [ -n "$component_index" ] || component_index="$PB_COMPONENT_INDEX"
    local root="$(component_scratch root "$component_index")"
    local install_location="$(component_get INSTALL_LOCATION "$component_index")"
    [ -n "$install_location" ] || install_location="/"

    /bin/rm -rf "$root"
    /bin/mkdir -p "$root" || {
        append_log "  ! Could not create the staging root"
        return 1
    }

    local warned_ownership=0
    local entry_count="$(payload_count "$component_index")"
    local index=0
    while [ "$index" -lt "$entry_count" ]; do
        source="$(resolve_stored_path "$(payload_get "$index" SOURCE "$component_index")")"
        if [ -z "$source" ]; then
            append_log "  ! Item $((index + 1)) has no resolvable source"
            return 1
        fi
        destination="$(expand_tokens "$(payload_get "$index" DESTINATION "$component_index")")"
        # Second line of defense. The preconditions already refused this, but
        # they read the model at the start of the run and this re-reads it, so
        # the same reasoning that makes sign_package re-check applies: the one
        # place that turns a destination into a path we write to should not
        # trust that somebody else looked.
        if path_has_dotdot "$destination"; then
            append_log "  ! Item $((index + 1)): destination \"$destination\" must not contain \"..\""
            return 1
        fi
        # The same normalization the preconditions compared against, so that the
        # path actually written to is the path that was checked. Without this the
        # gate and the write could disagree about what the destination even is.
        destination="$(normalize_path "$destination")"
        relative="$(staged_relative_path "$destination" "$install_location")"
        if [ -z "$relative" ]; then
            append_log "  ! Item $((index + 1)) stages to nothing - its destination equals the install location"
            return 1
        fi
        target="$root/$relative"

        target_parent="$(/usr/bin/dirname "$target")"

        # Checked BEFORE mkdir, not only after. "mkdir -p" follows symlink
        # components, so by the time the parent exists the escape has already
        # happened: the refusal below would be accurate and too late, with
        # arbitrary directories already created outside the root and the run's
        # closing line still claiming nothing outside the scratch was touched.
        # Climb to the deepest ancestor that already exists and resolve that
        # one - if it lands outside, so does everything mkdir would create
        # beneath it.
        ancestor="$target_parent"
        while [ ! -d "$ancestor" ]; do
            ancestor_next="$(/usr/bin/dirname "$ancestor")"
            [ "$ancestor_next" != "$ancestor" ] || break
            ancestor="$ancestor_next"
        done
        real_parent="$(canonical_path "$ancestor")"
        real_root="$(canonical_path "$root")"
        if [ -z "$real_parent" ] || [ -z "$real_root" ]; then
            append_log "  ! Item $((index + 1)): could not resolve the staging path for \"$destination\""
            return 1
        fi
        if ! path_is_under "$real_parent" "$real_root"; then
            append_log "  ! Item $((index + 1)): destination \"$destination\" resolves outside the payload root"
            return 1
        fi

        if ! /bin/mkdir -p "$target_parent"; then
            append_log "  ! Could not create $(/usr/bin/dirname "$relative") in the staging root"
            return 1
        fi

        # The last gate, and the only one that can see what the file system
        # sees. Every check above this line compares strings, and a string
        # comparison cannot answer the question that decides whether this write
        # stays inside the root:
        #
        #   - APFS folds case, so "/opt/demo/DIR" and "/opt/demo/dir" are two
        #     spellings of one directory that compare unequal in the shell;
        #   - APFS folds Unicode, so the NFC and NFD spellings of an accented
        #     name are one directory that compares unequal, and prints
        #     identically in the log, so the log is not a witness either;
        #   - and a symlink staged by an EARLIER entry makes an
        #     innocent-looking path name a directory outside the root, which
        #     "mkdir -p" then happily follows.
        #
        # Canonicalizing after the mkdir asks the file system all three at once.
        # No further lexical rewrite can do this, which is why the previous two
        # rounds of spelling refusals were each got past.
        real_parent="$(canonical_path "$target_parent")"
        real_root="$(canonical_path "$root")"
        if [ -z "$real_parent" ] || [ -z "$real_root" ]; then
            append_log "  ! Item $((index + 1)): could not resolve the staging path for \"$destination\""
            return 1
        fi
        if ! path_is_under "$real_parent" "$real_root"; then
            append_log "  ! Item $((index + 1)): destination \"$destination\" resolves outside the payload root"
            return 1
        fi
        # And the leaf itself, which the parent check cannot cover: "ditto" of a
        # DIRECTORY onto an existing symlink writes through it, and "chmod"
        # without -h follows it. The staging root is ours alone, so a symlink
        # already sitting where this entry is about to write was put there by an
        # earlier entry and is never legitimate.
        if [ -L "$target" ]; then
            append_log "  ! Item $((index + 1)): destination \"$destination\" is a symlink staged by an earlier item"
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
        if ! /bin/chmod "$(payload_get "$index" MODE "$component_index")" "$target"; then
            append_log "  ! Could not set the mode of $relative"
            return 1
        fi

        # Ownership is not applied here and does not need to be: pkgbuild runs
        # with --ownership recommended, which records root:wheel in the BOM
        # whoever runs the build, so no sudo is involved anywhere (design 7
        # step 2). An entry asking for something else is saying something the
        # build cannot honor, so it is said out loud rather than ignored.
        owner="$(payload_get "$index" OWNER "$component_index")"
        group="$(payload_get "$index" GROUP "$component_index")"
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
    local component_index="$1"
    [ -n "$component_index" ] || component_index="$PB_COMPONENT_INDEX"
    local preinstall="$(resolve_stored_path "$(component_get PREINSTALL "$component_index")")"
    local postinstall="$(resolve_stored_path "$(component_get POSTINSTALL "$component_index")")"
    [ -n "$preinstall" ] || [ -n "$postinstall" ] || return 0

    local scripts_dir="$(component_scratch scripts "$component_index")"
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
    local root="$1" component_index="$2"
    [ -n "$component_index" ] || component_index="$PB_COMPONENT_INDEX"
    local plist="$(component_scratch component "$component_index" .plist)"
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
    local package_path="$1" wanted="$2" component_index="$3"
    [ -n "$component_index" ] || component_index="$PB_COMPONENT_INDEX"
    local expand_dir="$(component_scratch expand "$component_index")"
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

# Stage and build every component, in document order.
#
# Shared by the whole-pipeline build and by Actions > Build Component Only. The
# two ran the same pair of steps side by side back when there was one component
# to run them for, and would have drifted apart the moment one of them learned
# to loop and the other did not.
#
# Returns 0 when every component was built. On failure it returns 1 and leaves
# the reason in pb_component_stage_failure: the two callers word their own
# epilogues, and both need to know which of the two steps gave up.
pb_component_stage_failure=""
build_all_components() {
    pb_component_stage_failure=""
    # Set once per iteration of the loop below.
    local component_index component
    local total_components="$(component_count)"

    # The directory is cleared once, here, rather than inside the per-component
    # build: productbuild picks up every .pkg in it, so a package left behind by
    # a previous run would ship, and a rm -rf inside the loop would delete the
    # components this run had already built.
    /bin/rm -rf "$(state_dir)/component"
    if ! /bin/mkdir -p "$(state_dir)/component"; then
        append_log "  ! Could not create the component directory"
        pb_component_stage_failure=stage
        return 1
    fi
    : > "$(state_dir)/built_component.txt"

    component_index=0
    while [ "$component_index" -lt "$total_components" ]; do
        # Named only when there is more than one, so a single-component build
        # reads exactly as it always did.
        if [ "$total_components" -gt 1 ]; then
            append_log "Component $((component_index + 1)) of $total_components - $(component_get IDENTIFIER "$component_index"):"
        fi
        set_status "Staging the payload..."
        append_log "Staging the payload root:"
        if ! stage_payload_root "$component_index"; then
            pb_component_stage_failure=stage
            return 1
        fi

        append_log ""
        set_status "Running pkgbuild..."
        append_log "Building the component package:"
        component="$(build_component_package "$component_index")"
        if [ -z "$component" ] || [ ! -f "$component" ]; then
            pb_component_stage_failure=pkgbuild
            return 1
        fi
        # One path per line, in build order.
        printf '%s\n' "$component" >> "$(state_dir)/built_component.txt"

        component_index=$((component_index + 1))
        if [ "$component_index" -lt "$total_components" ]; then
            append_log ""
        fi
    done
    return 0
}

# Build one component package from its staged root and print its path.
#
# The directory it writes into is shared by every component, because
# productbuild --package-path takes a directory and picks up every .pkg in it.
# Clearing that directory is therefore the caller's job, not this function's: a
# rm -rf here would delete the components built before this one.
#
# Arguments: optional component index, defaulting to the current one
build_component_package() {
    # "scripts_dir" is declared apart from its assignment because the
    # "|| return 1" has to test stage_component_scripts and not local.
    local scripts_dir
    # Set only when relocation is being turned off.
    local component_plist=""

    local component_index="$1"
    [ -n "$component_index" ] || component_index="$PB_COMPONENT_INDEX"
    local root="$(component_scratch root "$component_index")"
    local component_dir="$(state_dir)/component"
    local identifier="$(component_get IDENTIFIER "$component_index")"
    local version="$(model_get /PROJECT/VERSION)"
    local install_location="$(component_get INSTALL_LOCATION "$component_index")"
    [ -n "$install_location" ] || install_location="/"

    /bin/mkdir -p "$component_dir" || return 1
    local package_path="$component_dir/$(component_package_basename "$component_index").pkg"

    scripts_dir="$(stage_component_scripts "$component_index")" || return 1

    if [ "$(component_get_bool RELOCATABLE "$component_index")" != "1" ]; then
        component_plist="$(component_plist_no_relocate "$root" "$component_index")" || {
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
        "$(bool_str "$(component_get_bool OVERWRITE_PERMISSIONS "$component_index")")" \
        "$component_index" || return 1

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
# Reduce an identifier to the characters a choice id and a file name may both
# hold. One function rather than two, so that the collision check in
# check_distribution_preconditions covers the choice ids and the component
# package file names at the same time - they cannot disagree about which pairs
# of identifiers collapse together.
sanitize_component_token() {
    printf '%s' "$1" | /usr/bin/tr -c 'A-Za-z0-9' '_'
}

distribution_choice_id() {
    local identifier="$1"
    printf '%s_choice' "$(sanitize_component_token "$identifier")"
}

# The file name, without ".pkg", of one component's package inside the directory
# productbuild scans.
#
# One component keeps the project's own name. That is not a preference: the name
# lands in the Distribution as "#<name>.pkg", the shipped reference package this
# suite compares against carries it, and three assertions look for it - so
# changing it for the case that has always worked would change the contents of
# every package built so far and buy nothing.
#
# With several components the project name cannot name them all, and the
# identifier is the only thing a component is guaranteed to have that is its own.
component_package_basename() {
    local component_index="$1"
    if [ "$(component_count)" -le 1 ]; then
        model_get /PROJECT/NAME
        return 0
    fi
    sanitize_component_token "$(component_get IDENTIFIER "$component_index")"
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
        # A source path ending in "/.." or "/." has a basename of ".." or ".",
        # and resolve_stored_path does not canonicalize, so the dots survive to
        # here - which would aim this copy at the state directory itself and
        # clobber model.json and the staging root mid-run. There is no resource
        # this could legitimately name: a resource is staged under its own file
        # name, and "." and ".." are not file names.
        #
        # The "*/*" arm is what catches "/": basename "/" prints "/", not the
        # empty string, so an enumeration of ''|.|.. misses it and the copy
        # becomes "ditto / $resources_dir//" - the whole boot volume into the
        # state directory. A basename can never legitimately contain a slash, so
        # this arm is total rather than another list of spellings to keep up.
        case "$base" in
            ''|.|..|*/*)
                append_log "  ! $model_key resource $source does not name a file"
                return 1
                ;;
        esac
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
    local version="$(model_get /PROJECT/VERSION)"
    local title="$(model_get /DISTRIBUTION/TITLE)"
    local min_os="$(model_get /PROJECT/MIN_OS_VERSION)"
    local customize="$(model_get /DISTRIBUTION/CUSTOMIZE)"
    local architectures="$(host_architectures_attr)"
    local total_components="$(component_count)"
    # Set once per iteration of the resource and component loops below.
    local pair model_key element source base
    local component_index identifier auth choice_id choice_title

    [ -n "$title" ] || title="$name"
    [ -n "$customize" ] || customize="never"

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

        # One line, one choice and one terminal pkg-ref per component, in
        # document order, which is the order they appear in the installer.
        printf '%s\n' '    <choices-outline>'
        component_index=0
        while [ "$component_index" -lt "$total_components" ]; do
            printf '        <line choice="%s"/>\n' \
                "$(xml_escape "$(distribution_choice_id "$(component_get IDENTIFIER "$component_index")")")"
            component_index=$((component_index + 1))
        done
        printf '%s\n' '    </choices-outline>'

        component_index=0
        while [ "$component_index" -lt "$total_components" ]; do
            identifier="$(component_get IDENTIFIER "$component_index")"
            choice_id="$(distribution_choice_id "$identifier")"
            choice_title="$(component_title "$component_index")"
            printf '    <choice id="%s" title="%s" description="%s"' \
                "$(xml_escape "$choice_id")" "$(xml_escape "$choice_title")" \
                "$(xml_escape "$(component_get DESCRIPTION "$component_index")")"
            # Written only when it is false. productbuild starts a choice
            # selected, so emitting the default would add an attribute to every
            # document that has never asked for one - including every document
            # written before the key existed - and change the bytes of packages
            # that are meant to be unaffected by this.
            if [ "$(component_get_bool SELECTED "$component_index")" = "0" ]; then
                printf ' start_selected="false"'
            fi
            printf '>\n'
            printf '        <pkg-ref id="%s"/>\n' "$(xml_escape "$identifier")"
            printf '%s\n' '    </choice>'
            component_index=$((component_index + 1))
        done

        # auth on the pkg-ref, not in PackageInfo: pkgbuild has no flag for it
        # and always writes auth="root" into the component regardless, so the
        # Distribution XML is the only place the document's value can land
        # (design section 4).
        #
        # The file name has to be the one build_component_package wrote, or
        # productbuild resolves the reference to nothing.
        component_index=0
        while [ "$component_index" -lt "$total_components" ]; do
            identifier="$(component_get IDENTIFIER "$component_index")"
            auth="$(component_get AUTH "$component_index")"
            [ -n "$auth" ] || auth="Root"
            printf '    <pkg-ref id="%s" version="%s" auth="%s">#%s.pkg</pkg-ref>\n' \
                "$(xml_escape "$identifier")" "$(xml_escape "$version")" \
                "$(xml_escape "$auth")" \
                "$(xml_escape "$(component_package_basename "$component_index")")"
            component_index=$((component_index + 1))
        done

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
# The first component package the last component build produced.
#
# The record holds one path per line since a build can produce several. The first
# is printed because that is the whole record for a single-component project and
# because Inspect has to open one package: for a multi-component project the
# thing worth inspecting is the distribution package, which holds them all, and
# built_distribution_path is what the caller reaches for then.
built_component_path() {
    local record="$(state_dir)/built_component.txt"
    [ -f "$record" ] || return 0
    local package_path="$(/usr/bin/head -n 1 "$record")"
    [ -n "$package_path" ] || return 0
    [ -f "$package_path" ] || return 0
    printf '%s' "$package_path"
}

# Every component package the last component build produced, one per line.
built_component_paths() {
    local record="$(state_dir)/built_component.txt"
    [ -f "$record" ] || return 0
    /bin/cat "$record"
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
# (built_component.txt, built_distribution.txt, built_package.txt, and
# kept_package.txt when a console frontend copied an unsigned build out).
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
    # Every record of what a previous run produced, cleared together. The CLI
    # names its state directory after its pid and removes it from a trap, so a
    # run that is killed outright leaves one behind for pid reuse to hand to a
    # later run - and a stale record here is printed on stdout as this run's
    # result, which is the one line a caller is meant to be able to trust.
    /bin/rm -f "$(state_dir)/built_component.txt" \
               "$(state_dir)/built_distribution.txt" \
               "$(state_dir)/built_package.txt" \
               "$(state_dir)/kept_package.txt"
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
    if ! build_all_components; then
        stop_here "$RAIL_COMPONENT_ID" && return 0
        append_log ""
        if [ "$pb_component_stage_failure" = "pkgbuild" ]; then
            append_log "Stopped. pkgbuild did not produce a component package."
            rail_set "$RAIL_COMPONENT_ID" failed
            set_status "The component package was not built"
        else
            append_log "Stopped while staging. Nothing outside the scratch directory was touched."
            rail_set "$RAIL_COMPONENT_ID" failed
            set_status "Could not stage the payload"
        fi
        build_end
        return 1
    fi
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
        # What becomes of an unsigned package is the frontend's business, so it
        # is asked rather than told. Design 8.3 keeps an unsigned artifact out of
        # the window's output folder, but a terminal caller that passed
        # --unsigned asked for the artifact and its scratch directory is about to
        # go away. Stating either outcome here would make the log lie to one of
        # the two frontends, which is exactly what the presentation seam is for.
        rail_set "$RAIL_SIGN_ID" skipped
        report_unsigned_result "$unsigned"
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

# --- Inspecting a built package (design section 6, Actions menu) --------------
# How many BOM lines the report lists before it stops. A payload holding one .app
# is tens of thousands of files, and a log view holding all of them is not a
# report, it is a haystack. The COUNT is always exact; only the listing is
# capped, and the log says when it was.
PB_INSPECT_BOM_LINES=200

# Turn the five XML entities back into the characters they stand for.
#
# The report is read by a person, and generate_distribution_xml's own xml_escape
# uses "Rock & Roll" as its worked example - so without this, inspecting that
# very project reported its title as "Rock &amp; Roll". Reachable through VERSION,
# IDENTIFIER, INSTALL_LOCATION and TITLE, and pkgbuild escapes its own
# attributes the same way. Found in review, 2026-08-23.
#
# &amp; is undone LAST. Any other order decodes it into an ampersand that the
# remaining passes then read as the start of an entity, so a literal "&amp;gt;" in
# a project name would come back as ">".
xml_unescape() {
    local text="$1"
    case "$text" in
        *'&'*) ;;
        *) printf '%s' "$text"; return 0 ;;
    esac
    text="$(str_replace "$text" '&lt;' '<')"
    text="$(str_replace "$text" '&gt;' '>')"
    text="$(str_replace "$text" '&quot;' '"')"
    text="$(str_replace "$text" '&apos;' "'")"
    text="$(str_replace "$text" '&amp;' '&')"
    printf '%s' "$text"
}

# Print the value of an XML attribute, scoped to a named element.
#
# The element name is not optional decoration, and the first version of this
# left it out. A PackageInfo opens with <?xml version="1.0" encoding="utf-8"?>,
# so a file-wide search for "version" answered 1.0 - the XML spec version -
# for every package inspected, and reported it as the package version. Asking
# for the attribute *of <pkg-info>* is the only way to get the right one.
# Found by section 108.
#
# The tag is isolated first, with newlines folded so an element whose attributes
# wrap still reads as one tag. Tags not carrying the attribute at all are then
# dropped, which is what lets auth be read from the Distribution: there are two
# pkg-ref elements and only the second one has it.
#
# "grep -o" rather than a sed substitution, the same idiom the test lib's
# pkginfo_attr uses and for the same reason: pkgbuild writes every attribute of
# <pkg-info> on one line, and "s/.*name=\"\([^\"]*\)\".*/\1/p" has a greedy .*
# in front of it, so it answers for the LAST match on the line - again a
# different attribute. -o prints one match per line instead.
#
# The (^|[[:space:]]) boundary is what keeps "location" off "install-location"
# and "permissions" off "overwrite-permissions". After the fold every line the
# inner grep sees begins at "<", so "^" can never match an attribute and the
# whitespace alternative carries the whole boundary.
#
# Two limits, neither reachable from a package this app or pkgbuild produced,
# both worth knowing before this is pointed at arbitrary XML. "[^>]*" truncates
# a tag at the first ">", so a raw ">" inside a quoted value would blank every
# attribute of that element - both writers escape it as &gt;, which is why this
# holds. And an element commented out with <!-- --> is still matched, so a
# commented-out <pkg-info> ahead of the real one would be believed; neither
# writer emits comments.
xml_element_attribute() {
    local file="$1" element="$2" name="$3"
    [ -f "$file" ] || return 0
    /usr/bin/tr '\n' ' ' < "$file" 2>/dev/null \
        | /usr/bin/grep -o "<$element[[:space:]][^>]*>" \
        | /usr/bin/grep -E "(^|[[:space:]])$name=\"" \
        | /usr/bin/head -n 1 \
        | /usr/bin/grep -o -E "(^|[[:space:]])$name=\"[^\"]*\"" \
        | /usr/bin/head -n 1 \
        | /usr/bin/sed -e 's/^[^"]*"//' -e 's/"$//' \
        | { IFS= read -r raw_value || true; xml_unescape "$raw_value"; }
}

# Print the text of a simple XML element, first occurrence. Only good for an
# element whose content has no markup in it, which is all this reads: <title>.
xml_element_text() {
    local file="$1" name="$2"
    [ -f "$file" ] || return 0
    /usr/bin/grep -o "<$name>[^<]*</$name>" "$file" 2>/dev/null \
        | /usr/bin/head -n 1 \
        | /usr/bin/sed -e "s|^<$name>||" -e "s|</$name>\$||" \
        | { IFS= read -r raw_text || true; xml_unescape "$raw_text"; }
}

# Rewrite a file with every line prefixed. Used to indent a tool's output before
# it goes into the log, so a report reads as one document rather than as a
# transcript with things pasted into it.
indent_file() {
    local file="$1" prefix="$2"
    [ -f "$file" ] || return 0
    /usr/bin/sed -e "s/^/$prefix/" "$file" > "$file.indented" || return 1
    /bin/mv "$file.indented" "$file"
}

# Print when a package was last written, local time.
package_built_when() {
    local package_path="$1"
    [ -f "$package_path" ] || return 0
    /bin/date -r "$package_path" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
}

# Print a package's size the way du reports it, e.g. "1.2M".
package_disk_size() {
    local package_path="$1"
    [ -f "$package_path" ] || return 0
    /usr/bin/du -h "$package_path" 2>/dev/null | /usr/bin/awk '{print $1; exit}'
}

# Describe one expanded component directory: the PackageInfo attributes and the
# BOM. Arguments: the directory holding PackageInfo and Bom, a label for it.
inspect_component_dir() {
    local component_dir="$1" label="$2"
    local package_info="$component_dir/PackageInfo"
    local bom="$component_dir/Bom"
    local scratch="$(state_dir)/inspect-$$.txt"

    append_log ""
    append_log "Component $label:"
    if [ ! -f "$package_info" ]; then
        append_log "  ! no PackageInfo - this is not a component package"
        return 0
    fi

    append_log "  identifier:            $(xml_element_attribute "$package_info" pkg-info identifier)"
    append_log "  version:               $(xml_element_attribute "$package_info" pkg-info version)"
    append_log "  install-location:      $(xml_element_attribute "$package_info" pkg-info install-location)"
    append_log "  overwrite-permissions: $(xml_element_attribute "$package_info" pkg-info overwrite-permissions)"

    # The relocate list, not a "relocatable" attribute: pkgbuild expresses
    # relocatability by listing the bundles it will hunt for, and an empty
    # <relocate/> is what design 8.2 forces for a non-relocatable package. So
    # the honest report is which bundles Installer would go looking for.
    if /usr/bin/grep -q '<relocate/>' "$package_info"; then
        append_log "  relocatable:           no (empty relocate list)"
    else
        local relocated="$(/usr/bin/sed -n '/<relocate>/,/<\/relocate>/p' "$package_info" \
            | /usr/bin/grep -o 'id="[^"]*"' | /usr/bin/sed -e 's/^id="//' -e 's/"$//' \
            | /usr/bin/tr '\n' ' ')"
        if [ -n "$relocated" ]; then
            append_log "  relocatable:           YES, Installer will hunt for: $relocated"
        else
            append_log "  relocatable:           no relocate element at all"
        fi
    fi

    # auth is deliberately NOT read from here. pkgbuild always writes
    # auth="root" into PackageInfo whatever the document says, which is why the
    # Distribution pkg-ref carries the real value (design section 4). Reporting
    # PackageInfo's copy would tell a user who chose "User" that they had chosen
    # "Root", which is precisely the confusion this whole feature is for.

    if [ ! -f "$bom" ]; then
        append_log "  ! no Bom"
        return 0
    fi
    /usr/bin/lsbom -p fugm "$bom" > "$scratch" 2>/dev/null
    local entry_count="$(/usr/bin/grep -c . "$scratch" | /usr/bin/tr -d ' ')"
    # The house guard, which model_count and the test lib both apply and this
    # was the one counter in the app that did not. "grep -c" on a file that
    # always exists cannot currently print anything but a number, so this is
    # consistency rather than a live fix - but "[ "" -gt 200 ]" is a hard error,
    # not a false, and the next person to change how $scratch is produced should
    # not have to notice that.
    case "$entry_count" in
        ''|*[!0-9]*) entry_count=0 ;;
    esac
    append_log ""
    append_log "  Payload, $entry_count item(s):"
    if [ "$entry_count" -gt "$PB_INSPECT_BOM_LINES" ]; then
        /usr/bin/head -n "$PB_INSPECT_BOM_LINES" "$scratch" > "$scratch.cut"
        /bin/mv "$scratch.cut" "$scratch"
    fi
    indent_file "$scratch" "    "
    append_log_file "$scratch"
    if [ "$entry_count" -gt "$PB_INSPECT_BOM_LINES" ]; then
        append_log "    ... and $((entry_count - PB_INSPECT_BOM_LINES)) more, not listed"
    fi
    /bin/rm -f "$scratch"
    return 0
}

# Take a built package apart and describe it in the log. Returns non-zero only
# when the package could not be expanded at all.
# Arguments: package path, a short phrase naming which package this is
inspect_package() {
    local package_path="$1" kind="$2"
    # Both names carry this handler's pid. state_dir is per WINDOW, the Actions
    # menu is never disabled while an inspection runs, and commands are async -
    # so a second click during a slow pkgutil --expand had the two runs sharing
    # one expansion directory and one scratch file. The second run's "rm -rf"
    # deleted the first run's expansion mid-read, which made it report "no
    # PackageInfo - this is not a component package" about a perfectly good
    # package, and each run's tool output landed in the other's report.
    #
    # Exactly the bug the folder scan had, found the same way, fixed the same
    # way. Found in review, 2026-08-23.
    local expand_dir="$(state_dir)/inspect-$$"
    local scratch="$(state_dir)/inspect-$$.txt"

    append_log "Inspecting the $kind:"
    append_log ""
    append_log "  $package_path"
    # The timestamp is not decoration. Only run_pipeline clears all three
    # built_*.txt records; each partial step clears just its own, so a signed
    # package from an earlier build stays on disk and stays recorded, and the
    # chain above will pick it over the component that was just built. The label
    # is always right about WHICH artifact is being read - every built_*_path
    # checks the file is still there - but nothing else in the report would
    # distinguish a fresh package from last week's. Found in review, 2026-08-23.
    append_log "  $(package_disk_size "$package_path") on disk, built $(package_built_when "$package_path")"
    append_log ""

    # Read from the flat package, never from the expansion: an expanded package
    # is a directory and carries no signature at all. That is the same fact that
    # makes patch_overwrite_permissions a re-flatten rather than an edit.
    append_log "Signature:"
    "$pkgutil_tool" --check-signature "$package_path" > "$scratch" 2>&1
    # The status is not tested. An unsigned package makes pkgutil exit non-zero,
    # and an unsigned package is a legitimate thing to be looking at - design 8.3
    # keeps one out of the output folder but the intermediate is still here, and
    # "is this actually signed" is one of the two questions this feature exists
    # to answer.
    indent_file "$scratch" "  "
    append_log_file "$scratch"
    /bin/rm -f "$scratch"

    /bin/rm -rf "$expand_dir"
    if ! "$pkgutil_tool" --expand "$package_path" "$expand_dir" > "$scratch" 2>&1; then
        append_log ""
        append_log "Could not expand the package:"
        indent_file "$scratch" "  "
        append_log_file "$scratch"
        /bin/rm -f "$scratch"
        /bin/rm -rf "$expand_dir"
        return 1
    fi
    /bin/rm -f "$scratch"

    local distribution="$expand_dir/Distribution"
    if [ -f "$distribution" ]; then
        append_log ""
        append_log "Distribution:"
        append_log "  title:                 $(xml_element_text "$distribution" title)"
        local architectures="$(xml_element_attribute "$distribution" options hostArchitectures)"
        append_log "  hostArchitectures:     ${architectures:-(any)}"
        append_log "  customize:             $(xml_element_attribute "$distribution" options customize)"
        append_log "  require-scripts:       $(xml_element_attribute "$distribution" options require-scripts)"
        local min_os="$(xml_element_attribute "$distribution" os-version min)"
        append_log "  minimum macOS:         ${min_os:-(none declared)}"
        # This is where auth really lives, and the label says so because a user
        # who goes looking will find auth="root" in PackageInfo and believe it.
        append_log "  auth (the real one):   $(xml_element_attribute "$distribution" pkg-ref auth)"
        local resource
        for resource in readme license welcome conclusion background; do
            local file_attr="$(/usr/bin/grep -o "<$resource file=\"[^\"]*\"" "$distribution" 2>/dev/null \
                | /usr/bin/head -n 1 | /usr/bin/sed -e 's/^.*file="//' -e 's/"$//')"
            [ -n "$file_attr" ] || continue
            append_log "  $resource: $file_attr"
        done
    fi

    # A distribution package holds its components as <name>.pkg directories; a
    # component package built on its own IS one, with PackageInfo at the top.
    local component_dir found_component=0
    for component_dir in "$expand_dir"/*.pkg; do
        [ -d "$component_dir" ] || continue
        inspect_component_dir "$component_dir" "$(/usr/bin/basename "$component_dir")"
        found_component=1
    done
    if [ "$found_component" = "0" ]; then
        inspect_component_dir "$expand_dir" "$(/usr/bin/basename "$package_path")"
    fi

    /bin/rm -rf "$expand_dir"
    return 0
}
