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
        [ "$precondition_failures" -eq 0 ]
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
    # installer would then show, say, the licence text as the readme - a wrong
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
# not. Localized resource sets are not modelled at all (design 4.6), so
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
        "$ditto_tool" "$source" "$resources_dir/$base" || return 1
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
        append_log "  ! productsign failed; the output folder was not touched"
        /bin/rm -f "$staged_signed"
        return 1
    fi
    if [ ! -f "$staged_signed" ]; then
        append_log "  ! productsign reported success but wrote no package"
        return 1
    fi
    if ! run_tool /usr/sbin/pkgutil --check-signature "$staged_signed"; then
        append_log "  ! The signed package did not verify; the output folder was not touched"
        /bin/rm -f "$staged_signed"
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
