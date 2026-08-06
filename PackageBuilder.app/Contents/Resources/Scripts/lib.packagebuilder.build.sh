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
# Icon and colour per state, copied from rail_set in lib.notarize.sh.
RAIL_VERIFY_ID=210
RAIL_COMPONENT_ID=211
RAIL_DISTRIBUTION_ID=212
RAIL_SIGN_ID=213
RAIL_ICON_IDS="210 211 212 213"

# Arguments: rail icon view id, state (pending|running|done|failed|skipped)
rail_set() {
    local view_id="$1" stage_state="$2"
    # Set on every branch of the case below.
    local symbol color
    case "$stage_state" in
        running) symbol="arrow.clockwise.circle.fill"; color="blue" ;;
        done)    symbol="checkmark.circle.fill"; color="green" ;;
        failed)  symbol="xmark.circle.fill"; color="red" ;;
        skipped) symbol="minus.circle"; color="gray" ;;
        *)       symbol="circle"; color="gray" ;;
    esac
    set_property "$view_id" systemName "$symbol"
    set_property "$view_id" foregroundStyle "$color"
}

rail_reset() {
    # Set by the "for" below.
    local view_id
    for view_id in $RAIL_ICON_IDS; do
        rail_set "$view_id" pending
    done
}

# --- Log ----------------------------------------------------------------------
# Append a whole file to the run log in one go. append_log rewrites the entire
# log view on every call, which is fine for a status line and quadratic for a
# tool that printed two hundred of them.
append_log_file() {
    local source_file="$1"
    local log_file="$(state_dir)/run.log"
    [ -f "$source_file" ] || return 0
    /bin/cat "$source_file" >> "$log_file"
    set_value "$LOG_ID" "$(/bin/cat "$log_file")"
    return 0
}

# Run an external tool, mirror everything it printed into the log, and return
# its exit status. Design 8.4: every external call captures stdout and stderr
# and has its status checked; a failure leaves the raw output in the log view
# rather than a summary of it.
# The one function here that keeps "$@": its parameters are the command line to
# run, so naming them would mean fixing their number.
run_tool() {
    local output_file="$(state_dir)/tool.log"
    /bin/rm -f "$output_file"
    "$@" > "$output_file" 2>&1
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
# appended to the log and the count returned, so one run tells the user
# everything that is wrong rather than one thing per attempt.
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
        return "$precondition_failures"
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

    return "$precondition_failures"
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
        # build cannot honour, so it is said out loud rather than ignored.
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
        # guessing at a PackageInfo this build did not recognise is how the
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

# --- Run bookkeeping ----------------------------------------------------------
# A build records its own process group id so app.will.terminate can stop a
# survivor, and holds a busy flag so a second one cannot start on top of it.
build_is_running() {
    [ "$(pb_get pb_busy)" = "1" ]
}

build_begin() {
    pb_set pb_busy 1
    printf '%s' "$$" > "$(state_dir)/run.pid"
    enable_view "$ACTIONS_MENU_ID" 0
    show_progress 1
    return 0
}

build_end() {
    show_progress 0
    enable_view "$ACTIONS_MENU_ID" 1
    pb_set pb_busy ""
    /bin/rm -f "$(state_dir)/run.pid"
    return 0
}
