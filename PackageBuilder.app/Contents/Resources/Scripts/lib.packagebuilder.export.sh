#!/bin/sh
# lib.packagebuilder.export.sh - write the standalone packaging script
#
# Design section 11: the app writes a self-contained /bin/sh script that
# reproduces the current document's package with no dependency on
# PackageBuilder. The reason this project exists is that a GUI tool stopped
# being maintained and took a release workflow with it; a document that can
# regenerate its own packaging script is not exposed to that failure again, and
# it puts the same packaging step on a CI machine with no GUI session.
#
# Sourced after lib.packagebuilder.sh and lib.packagebuilder.build.sh: the
# values come from the model accessors, and the emitted pipeline is a
# transcription of the build library's stages - which is what that file's
# header promises, and why the two must be changed together.
#
# The emitted script targets macOS /bin/sh and uses only tools present on every
# Mac: pkgbuild, productbuild, productsign, pkgutil, codesign, lipo, ditto,
# PlistBuddy. Not plister - that is an OMC tool, and the whole point is having
# no dependency on this app.
#
# POSIX sh only, here and in what is emitted. Validate with "sh -n".

# Print a value single-quoted for sh, safe for any content: quotes are closed
# around every embedded quote. This is what makes the generator immune to a
# document value that contains sh syntax - the title "Rock & Roll's $(rm)" is
# data, and stays data.
sh_quote() {
    printf "'%s'" "$(str_replace "$1" "'" "'\\''")"
}

# Print a value fit to sit inside a "#" comment line: everything from the first
# line break onward is dropped, and an ellipsis says so.
#
# This is the one place a document value is not quoted, because a comment has
# no quoting - and a newline in a value therefore ends the comment and makes
# every following line top-level code in the exported script. "sh -n" cannot
# catch it: what it produces is valid shell, which is exactly the problem. The
# reachable chain was a hostile .pkgproj imported and then exported, and an
# artifacts folder whose directory name contains a newline reaches it with no
# import at all, since mkdir accepts one. Found in review, 2026-08-07.
comment_safe() {
    local text="$1"
    # A real newline to compare against. Command substitution strips trailing
    # newlines, so "$(printf '\n')" is the empty string and a pattern built
    # from it matches everything - the sentinel character is what survives the
    # stripping and is then removed.
    local newline="$(printf '\nx')"
    newline="${newline%x}"
    case "$text" in
        *"$newline"*)
            printf '%s ...' "$(printf '%s' "$text" | /usr/bin/head -n 1)"
            return 0
            ;;
    esac
    # A lone carriage return does not end a comment, but it does overwrite the
    # line on a terminal, which is its own way of lying about what is in a file.
    printf '%s' "$(printf '%s' "$text" | /usr/bin/tr -d '\r')"
}

# Print the sh expression that names a stored value when the exported script
# runs: the value single-quoted, with ${ARTIFACTS_DIR}, ${NAME}, ${VERSION},
# ${DATE} and ${PROJECT_DIR} become splices of the runtime variables, so
# --artifacts-dir and --version reach every value that used a token.
emit_runtime_text() {
    local stored="$1"
    case "$stored" in
        '') printf "''"; return 0 ;;
        *'${'*) ;;
        *) printf '%s' "$(sh_quote "$stored")"; return 0 ;;
    esac
    local expression="$(sh_quote "$stored")"
    expression="$(str_replace "$expression" '${ARTIFACTS_DIR}' "'\"\$artifacts_dir\"'")"
    expression="$(str_replace "$expression" '${NAME}' "'\"\$project_name\"'")"
    expression="$(str_replace "$expression" '${VERSION}' "'\"\$package_version\"'")"
    expression="$(str_replace "$expression" '${DATE}' "'\"\$build_date\"'")"
    expression="$(str_replace "$expression" '${PROJECT_DIR}' "'\"\$project_dir\"'")"
    printf '%s' "$expression"
}

# Emit one line of the Distribution XML as a statement appending to the file.
#
# The line goes through "printf '%s'" rather than being the format itself: a
# document value containing a percent sign - "50% off" in a title - would
# otherwise be read as a format specification and either vanish or consume the
# next argument.
emit_xml_line() {
    printf 'printf %s %s >> "$dist_xml"\n' "'%s'" "$(sh_quote "$1
")"
}

# The same, for values that name paths: a token-free value is additionally
# frozen to the absolute path the document resolves to now, so a
# document-relative source still works when the script runs from anywhere.
emit_runtime_path() {
    local stored="$1"
    case "$stored" in
        '') printf "''"; return 0 ;;
        # ${ARTIFACTS_DIR} and ${PROJECT_DIR} expand to absolute paths at run
        # time, and an absolute value stays itself, so both are emitted as they
        # stand.
        '${ARTIFACTS_DIR}'*|'${PROJECT_DIR}'*|/*)
            emit_runtime_text "$stored"
            return 0
            ;;
        # A relative value that still carries a token cannot be absolutized
        # here - part of it does not exist until the script runs - so the
        # project folder is prepended at run time instead. Without this, a
        # source like "build/${NAME}" would resolve against whatever directory
        # the exported script was run from, silently naming a different file.
        # Found in review, 2026-08-07.
        *'${'*)
            printf '"$project_dir"/%s' "$(emit_runtime_text "$stored")"
            return 0
            ;;
    esac
    printf '%s' "$(sh_quote "$(absolutize "$stored" "$(document_dir)")")"
}

# Write the packaging script for the current document to the named path.
# Returns non-zero when the file could not be written; content problems are the
# caller's to catch with "sh -n" on the result.
write_packaging_script() {
    local script_path="$1"

    local name="$(model_get /PROJECT/NAME)"
    local version="$(model_get /PROJECT/VERSION)"
    local identifier="$(model_get /COMPONENTS/0/IDENTIFIER)"
    local install_location="$(model_get /COMPONENTS/0/INSTALL_LOCATION)"
    [ -n "$install_location" ] || install_location="/"
    local min_os="$(model_get /PROJECT/MIN_OS_VERSION)"
    local title="$(model_get /DISTRIBUTION/TITLE)"
    [ -n "$title" ] || title="$name"
    local customize="$(model_get /DISTRIBUTION/CUSTOMIZE)"
    [ -n "$customize" ] || customize="never"
    local auth="$(model_get /COMPONENTS/0/AUTH)"
    [ -n "$auth" ] || auth="Root"
    local architectures="$(host_architectures_attr)"
    local choice_id="$(distribution_choice_id "$identifier")"
    local require_scripts=false
    [ "$(model_get_bool /DISTRIBUTION/REQUIRE_SCRIPTS)" != "1" ] || require_scripts=true
    local overwrite="$(bool_str "$(model_get_bool /COMPONENTS/0/OVERWRITE_PERMISSIONS)")"
    local relocatable="$(model_get_bool /COMPONENTS/0/RELOCATABLE)"
    local signing_on="$(model_get_bool /SIGNING/ENABLED)"
    local identity="$(model_get /SIGNING/INSTALLER_IDENTITY)"
    local artifacts="$(artifacts_dir_abs)"
    local output_dir="$(output_dir_abs)"
    local name_pattern="$(model_get /PROJECT/PACKAGE_NAME)"
    [ -n "$name_pattern" ] || name_pattern='${NAME}_${VERSION}.pkg'
    # The stored values, not the resolved ones: these go through
    # emit_runtime_path like every other path, so a script kept beside the
    # artifacts follows --artifacts-dir instead of being frozen to this
    # machine. Resolving them here also lost them entirely when the artifacts
    # folder was unset - resolve_stored_path returns empty, and the whole
    # scripts block silently disappeared from the exported build. Found in
    # review, 2026-08-07.
    local preinstall="$(model_get /COMPONENTS/0/PREINSTALL)"
    local postinstall="$(model_get /COMPONENTS/0/POSTINSTALL)"

    # Whether any stored path leans on the artifacts folder, so the emitted
    # script can insist on --artifacts-dir instead of collapsing the token to
    # "/..." - which very likely exists and is the previously installed copy,
    # the exact stale-artifact trap design 4.3 names.
    local needs_artifacts=0
    # Set once per iteration of the loops below.
    local index stored pair model_key
    local entry_count="$(payload_count)"
    index=0
    while [ "$index" -lt "$entry_count" ]; do
        case "$(payload_get "$index" SOURCE)" in
            *'${ARTIFACTS_DIR}'*) needs_artifacts=1 ;;
        esac
        index=$((index + 1))
    done
    for pair in $DISTRIBUTION_RESOURCE_KINDS; do
        model_key="${pair%%:*}"
        case "$(model_get "/DISTRIBUTION/RESOURCES/$model_key")" in
            *'${ARTIFACTS_DIR}'*) needs_artifacts=1 ;;
        esac
    done
    case "$preinstall$postinstall" in
        *'${ARTIFACTS_DIR}'*) needs_artifacts=1 ;;
    esac

    {
        # --- Header and configuration -----------------------------------------
        printf '#!/bin/sh\n'
        printf '# %s - build and sign the %s installer package\n' \
            "$(comment_safe "$(/usr/bin/basename "$script_path")")" "$(comment_safe "$name")"
        printf '#\n'
        printf '# Written by PackageBuilder.app from "%s" on %s.\n' \
            "$(comment_safe "$(document_name)")" "$(/bin/date '+%Y-%m-%d')"
        printf '#\n'
        printf '%s\n' '# Self-contained: Apple'\''s command line tools are the only requirement, so'
        printf '%s\n' '# this same step runs on a CI machine with no GUI session. The pipeline is a'
        printf '%s\n' '# transcription of the app'\''s own: verify the payload, stage it, pkgbuild,'
        printf '%s\n' '# patch PackageInfo, productbuild, productsign, and land the signed package'
        printf '%s\n' '# in the output folder. It ends at a signed package: notarization is a'
        printf '%s\n' '# separate step, and the command to run is printed at the end.'
        printf '#\n'
        printf '%s\n' '# Usage: sh '"$(comment_safe "$(/usr/bin/basename "$script_path")")"' [options]'
        printf '#   --version <v>        Package version. Default: %s\n' "$(comment_safe "$version")"
        printf '#   --artifacts-dir <d>  Where the payload artifacts are. Default: %s\n' "$(comment_safe "${artifacts:-(not set - required)}")"
        printf '#   --output-dir <d>     Where the signed package lands. Default: %s\n' "$(comment_safe "${output_dir:-(not set - required)}")"
        printf '#   --identity <i>       Installer signing identity. Default: %s\n' "$(comment_safe "${identity:-(none)}")"
        printf '%s\n' '#   --unsigned           Skip the identity check and productsign; the result is a'
        printf '%s\n' '#                        test-only package that macOS will not install elsewhere.'
        printf '%s\n' '#   -h, --help           Show this help.'
        printf '\n'
        printf 'set -u\n'
        printf '\n'
        printf '# --- The document, frozen at export time --------------------------------------\n'
        printf 'project_name=%s\n' "$(sh_quote "$name")"
        printf 'package_version=%s\n' "$(sh_quote "$version")"
        printf 'identifier=%s\n' "$(sh_quote "$identifier")"
        printf 'install_location=%s\n' "$(sh_quote "$install_location")"
        printf 'installer_identity=%s\n' "$(sh_quote "$identity")"
        printf 'artifacts_dir=%s\n' "$(sh_quote "$artifacts")"
        printf 'output_dir=%s\n' "$(sh_quote "$output_dir")"
        printf 'project_dir=%s\n' "$(sh_quote "$(document_dir)")"
        printf 'overwrite_permissions=%s\n' "$(sh_quote "$overwrite")"
        printf 'do_codesign=%s\n' "$(sh_quote "$signing_on")"
        printf 'needs_artifacts=%s\n' "$needs_artifacts"
        printf 'build_date="$(/bin/date +%%Y-%%m-%%d)"\n'
        printf '\n'

        # --- Static helpers ----------------------------------------------------
        /bin/cat <<'PB_HELPERS'
fail() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

announce() {
    printf '\n== %s ==\n' "$*"
}

require_option_value() {
    case "$2" in
        ''|-*) fail "$1 requires a value, got: '$2'" ;;
    esac
}

# A relative flag value is resolved against the caller's directory.
invocation_dir="$(pwd)"
absolute_path() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$invocation_dir" "$1" ;;
    esac
}

usage() {
    /usr/bin/sed -n '2,/^$/p' "$0" | /usr/bin/sed 's/^#//; s/^ //'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version)       require_option_value "$1" "${2-}"; package_version="$2"; shift 2 ;;
        --artifacts-dir) require_option_value "$1" "${2-}"; artifacts_dir="$(absolute_path "$2")"; shift 2 ;;
        --output-dir)    require_option_value "$1" "${2-}"; output_dir="$(absolute_path "$2")"; shift 2 ;;
        --identity)      require_option_value "$1" "${2-}"; installer_identity="$2"; do_codesign=1; shift 2 ;;
        --unsigned)      do_codesign=0; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               usage >&2; fail "Unknown option: $1" ;;
    esac
done

# The same value rules the app enforces (its design section 4.4): these are
# spliced into a filename and into XML, so they are constrained before they go
# anywhere.
case "$project_name" in
    ''|*[!A-Za-z0-9._-]*) fail "Project name '$project_name' is not usable in a filename" ;;
esac
case "$package_version" in
    ''|[!0-9]*) fail "Version '$package_version' must start with a digit" ;;
esac
case "$package_version" in
    *[!0-9A-Za-z.+_-]*) fail "Version '$package_version' may hold only letters, digits, . + _ or -" ;;
esac

if [ "$needs_artifacts" = "1" ] && [ -z "$artifacts_dir" ]; then
    fail "The payload references its artifacts folder - pass --artifacts-dir"
fi
[ -n "$output_dir" ] || fail "No output folder - pass --output-dir"

if [ "$do_codesign" = "1" ]; then
    [ -n "$installer_identity" ] || fail "No signing identity - pass --identity, or --unsigned for a test build"
    case "$(/usr/bin/security find-identity -p basic -v 2>/dev/null)" in
        *"$installer_identity"*) ;;
        *) fail "Identity not in this keychain: $installer_identity" ;;
    esac
fi

staging_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/makepkg-XXXXXXXX")" || fail "mktemp failed"
cleanup() { /bin/rm -rf "$staging_dir"; }
trap cleanup EXIT

payload_root="$staging_dir/root"
component_dir="$staging_dir/component"
/bin/mkdir -p "$payload_root" "$component_dir" || fail "Could not create the staging directories"

# --- Verify -------------------------------------------------------------------
# The checks the document asserts about each artifact, transcribed from the
# app's verify stage. The messages name the mistake, not the symptom: a binary
# from "xcodebuild build" is signed with --timestamp=none and no hardened
# runtime, one from a machine missing its distribution xcconfig is ad-hoc
# signed, and a stale artifacts folder has no symptom at all except the
# version cross-check.

# The bundle's Info.plist, or nothing. A .framework is a versioned bundle and
# keeps its Info.plist under Versions/<v>/Resources with no Contents directory
# at all, so a Contents-only test reports that a framework is not a bundle and
# every check the entry asserts is silently skipped.
info_plist_of() {
    [ -d "$1" ] || return 1
    if [ -f "$1/Contents/Info.plist" ]; then printf '%s/Contents/Info.plist' "$1"; return 0; fi
    # Current first, so a framework with several versions answers for the one
    # it publishes.
    for ip_candidate in "$1"/Versions/Current/Resources/Info.plist \
                        "$1"/Versions/*/Resources/Info.plist \
                        "$1"/Resources/Info.plist "$1"/Info.plist; do
        if [ -f "$ip_candidate" ]; then printf '%s' "$ip_candidate"; return 0; fi
    done
    return 1
}

executable_of() {
    if [ -f "$1" ]; then printf '%s' "$1"; return 0; fi
    exe_info="$(info_plist_of "$1")" || return 1
    exe_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$exe_info" 2>/dev/null)" || exe_name=""
    if [ -z "$exe_name" ]; then
        exe_name="$(/usr/bin/basename "$1")"
        exe_name="${exe_name%.*}"
    fi
    # Contents/MacOS for an ordinary bundle; for a framework the executable
    # sits in the version directory beside Resources, which is two levels up
    # from the Info.plist.
    exe_version_dir="$(/usr/bin/dirname "$(/usr/bin/dirname "$exe_info")")"
    for exe_candidate in "$1/Contents/MacOS/$exe_name" \
                         "$exe_version_dir/$exe_name" \
                         "$1/$exe_name"; do
        if [ -f "$exe_candidate" ]; then printf '%s' "$exe_candidate"; return 0; fi
    done
    return 1
}

# codesign report for one slice ("" = whatever codesign picks) into $1.
# verify first: what --display prints about a signature that does not validate
# is not evidence of anything.
check_signature() {
    sig_report="$1"; sig_path="$2"; sig_arch="$3"; sig_label="$4"
    sig_signed_by="$5"; sig_hardened="$6"; sig_timestamp="$7"
    if [ -n "$sig_arch" ]; then
        /usr/bin/codesign --verify --strict --verbose=2 --arch "$sig_arch" "$sig_path" >"$sig_report" 2>&1 \
            || fail "$sig_label: the code signature does not verify: $(/bin/cat "$sig_report")"
        /usr/bin/codesign --display --verbose=4 --arch "$sig_arch" "$sig_path" >"$sig_report" 2>&1 \
            || fail "$sig_label: codesign could not read the signature"
    else
        /usr/bin/codesign --verify --strict --verbose=2 "$sig_path" >"$sig_report" 2>&1 \
            || fail "$sig_label: the code signature does not verify: $(/bin/cat "$sig_report")"
        /usr/bin/codesign --display --verbose=4 "$sig_path" >"$sig_report" 2>&1 \
            || fail "$sig_label: codesign could not read the signature"
    fi
    if [ -n "$sig_signed_by" ]; then
        # The leaf certificate only, as a prefix, exactly as the app matches it.
        found_authority="$(/usr/bin/sed -n 's/^Authority=//p' "$sig_report" | /usr/bin/head -n 1)"
        case "$found_authority" in
            "$sig_signed_by"*) ;;
            *) fail "$sig_label: expected a signature from '$sig_signed_by', found ${found_authority:-nothing - the signature is ad-hoc}" ;;
        esac
    fi
    if [ "$sig_timestamp" = "1" ] && ! /usr/bin/grep -q '^Timestamp=' "$sig_report"; then
        fail "$sig_label: signed without a secure timestamp - notarization will reject it. A binary built with 'xcodebuild build' is signed this way; rebuild with 'xcodebuild archive'."
    fi
    if [ "$sig_hardened" = "1" ]; then
        case "$(/usr/bin/grep '^CodeDirectory ' "$sig_report" | /usr/bin/head -n 1)" in
            *"(runtime)"*|*"(runtime,"*|*",runtime)"*|*",runtime,"*) ;;
            *) fail "$sig_label: not signed with the hardened runtime - notarization will reject it. Rebuild with 'xcodebuild archive', or sign with codesign --options runtime." ;;
        esac
    fi
}

# verify_entry <source> <archs> <signed_by> <hardened> <timestamp> <version_flag>
verify_entry() {
    v_source="$1"; v_archs="$2"; v_signed_by="$3"
    v_hardened="$4"; v_timestamp="$5"; v_version_flag="$6"
    v_label="$(/usr/bin/basename "$v_source")"
    [ -e "$v_source" ] || fail "$v_label is not on disk: $v_source"
    [ -r "$v_source" ] || fail "$v_label cannot be read: $v_source"

    if [ -z "$v_archs" ] && [ -z "$v_signed_by" ] && [ "$v_hardened" != "1" ] \
        && [ "$v_timestamp" != "1" ] && [ -z "$v_version_flag" ]; then
        printf '  %s: nothing asserted, nothing checked\n' "$v_label"
        return 0
    fi

    v_executable="$(executable_of "$v_source")" || v_executable=""

    if [ -n "$v_archs" ]; then
        [ -n "$v_executable" ] || fail "$v_label: no Mach-O executable to read architectures from"
        v_found="$(/usr/bin/lipo -archs "$v_executable" 2>/dev/null)" || v_found=""
        # Globbing off around the loop: architecture names are bare tokens, but
        # a glob character in a hand-edited list would otherwise produce one
        # refusal per matching filename in the working directory.
        set -f
        for v_arch in $v_archs; do
            case " $v_found " in
                *" $v_arch "*) ;;
                *) set +f; fail "$v_label: not built for $v_arch - lipo reports [$v_found]. arm64e is a separate architecture, not a superset of arm64." ;;
            esac
        done
        set +f
        printf '  %s: built for %s\n' "$v_label" "$v_found"
    fi

    if [ -n "$v_signed_by" ] || [ "$v_hardened" = "1" ] || [ "$v_timestamp" = "1" ]; then
        v_report="$staging_dir/codesign.txt"
        v_slices=""
        [ -z "$v_executable" ] || v_slices="$(/usr/bin/lipo -archs "$v_executable" 2>/dev/null)" || v_slices=""
        case "$v_slices" in
            *' '*) ;;
            *) v_slices="" ;;
        esac
        if [ -z "$v_slices" ]; then
            check_signature "$v_report" "$v_source" "" "$v_label" "$v_signed_by" "$v_hardened" "$v_timestamp"
        else
            set -f
            # The whole file first, then every slice: an --arch pass validates
            # the slice it is aimed at and nothing else, so data appended after
            # the signed region passes every per-slice check and is refused
            # only by the whole-file strict validation.
            /usr/bin/codesign --verify --strict --verbose=2 "$v_source" >"$v_report" 2>&1 \
                || fail "$v_label: the code signature does not verify: $(/bin/cat "$v_report")"
            for v_arch in $v_slices; do
                set +f
                check_signature "$v_report" "$v_source" "$v_arch" "$v_label" "$v_signed_by" "$v_hardened" "$v_timestamp"
                set -f
            done
            set +f
        fi
        printf '  %s: signature ok\n' "$v_label"
    fi

    if [ -n "$v_version_flag" ]; then
        v_info="$(info_plist_of "$v_source")" || v_info=""
        if [ -n "$v_info" ]; then
            # A bundle answers from its Info.plist rather than by being run.
            v_reported="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$v_info" 2>/dev/null)" || v_reported=""
        else
            v_line="$("$v_source" "$v_version_flag" </dev/null 2>/dev/null | /usr/bin/head -n 1)" || v_line=""
            v_reported="$(printf '%s' "$v_line" | /usr/bin/grep -oE '[0-9]+(\.[0-9]+)+([0-9A-Za-z.+_-]*)?' 2>/dev/null | /usr/bin/head -n 1)" || v_reported=""
        fi
        [ -n "$v_reported" ] || fail "$v_label: reports no version to compare against $package_version"
        if [ "$v_reported" != "$package_version" ]; then
            fail "$v_label: reports version $v_reported, but this is being built as $package_version. The artifacts folder may be stale."
        fi
        printf '  %s: reports version %s\n' "$v_label" "$v_reported"
    fi
    return 0
}

# stage_entry <source> <destination> <mode>
stage_entry() {
    s_source="$1"; s_destination="$2"; s_mode="$3"
    case "$s_destination" in
        "$install_location"|"${install_location%/}/"*) ;;
        *) fail "Destination $s_destination is not under the install location $install_location" ;;
    esac
    s_relative="${s_destination#"${install_location%/}"}"
    s_relative="${s_relative#/}"
    [ -n "$s_relative" ] || fail "Destination $s_destination stages to nothing"
    /bin/mkdir -p "$(/usr/bin/dirname "$payload_root/$s_relative")" || fail "Could not create the staging path for $s_relative"
    /usr/bin/ditto "$s_source" "$payload_root/$s_relative" || fail "Could not copy $s_source"
    /bin/chmod "$s_mode" "$payload_root/$s_relative" || fail "Could not set mode $s_mode on $s_relative"
    printf '  staged %s\n' "$s_relative"
}
PB_HELPERS
        printf '\n'

        # --- The payload, one call per entry ----------------------------------
        printf 'announce "VERIFY the payload against what the document asserts"\n'
        index=0
        while [ "$index" -lt "$entry_count" ]; do
            printf 'verify_entry %s %s %s %s %s %s\n' \
                "$(emit_runtime_path "$(payload_get "$index" SOURCE)")" \
                "$(sh_quote "$(payload_archs_get "$index" | /usr/bin/tr '\n' ' ')")" \
                "$(sh_quote "$(payload_get "$index" VERIFY/SIGNED_BY)")" \
                "$(sh_quote "$(payload_bool_get "$index" VERIFY/HARDENED_RUNTIME)")" \
                "$(sh_quote "$(payload_bool_get "$index" VERIFY/SECURE_TIMESTAMP)")" \
                "$(sh_quote "$(payload_get "$index" VERIFY/VERSION_FLAG)")"
            index=$((index + 1))
        done
        printf '\n'
        printf 'announce "STAGE the payload"\n'
        index=0
        while [ "$index" -lt "$entry_count" ]; do
            # The destination goes through emit_runtime_text, not
            # emit_runtime_path: it names a place on the *installed* volume,
            # not a file on the machine running the build, so resolving it
            # against the document's folder would be meaningless.
            printf 'stage_entry %s %s %s\n' \
                "$(emit_runtime_path "$(payload_get "$index" SOURCE)")" \
                "$(emit_runtime_text "$(payload_get "$index" DESTINATION)")" \
                "$(sh_quote "$(payload_get "$index" MODE)")"
            index=$((index + 1))
        done
        printf '\n'

        # --- Component scripts, only when the document has any ----------------
        if [ -n "$preinstall" ] || [ -n "$postinstall" ]; then
            printf 'scripts_dir="$staging_dir/scripts"\n'
            printf '/bin/mkdir -p "$scripts_dir" || fail "Could not create the scripts directory"\n'
            if [ -n "$preinstall" ]; then
                printf '/bin/cp %s "$scripts_dir/preinstall" || fail "preinstall script is not there"\n' "$(sh_quote "$preinstall")"
                printf '/bin/chmod 755 "$scripts_dir/preinstall"\n'
            fi
            if [ -n "$postinstall" ]; then
                printf '/bin/cp %s "$scripts_dir/postinstall" || fail "postinstall script is not there"\n' "$(sh_quote "$postinstall")"
                printf '/bin/chmod 755 "$scripts_dir/postinstall"\n'
            fi
            printf '\n'
        fi

        # --- pkgbuild and the PackageInfo patch -------------------------------
        printf 'announce "PKGBUILD component package"\n'
        printf 'component_package="$component_dir/$project_name.pkg"\n'
        if [ "$relocatable" != "1" ]; then
            /bin/cat <<'PB_RELOCATE'
# Bundles must not be relocatable (the app's design 8.2): pkgbuild marks them
# relocatable, which makes Installer follow Spotlight to any existing copy of
# the bundle identifier - a stale copy in ~/Downloads silently becomes the
# install target. pkgbuild --analyze writes a component plist; every entry's
# BundleIsRelocatable is forced false. No entries means no bundles, and the
# plist is not passed at all.
component_plist="$staging_dir/component.plist"
/usr/bin/pkgbuild --analyze --root "$payload_root" "$component_plist" >/dev/null 2>&1 \
    || fail "pkgbuild --analyze failed"
if /usr/libexec/PlistBuddy -c 'Print :0' "$component_plist" >/dev/null 2>&1; then
    reloc_index=0
    while /usr/libexec/PlistBuddy -c "Print :$reloc_index" "$component_plist" >/dev/null 2>&1; do
        /usr/libexec/PlistBuddy -c "Set :$reloc_index:BundleIsRelocatable false" "$component_plist" \
            || fail "Could not mark bundle $reloc_index non-relocatable"
        reloc_index=$((reloc_index + 1))
    done
else
    component_plist=""
fi
PB_RELOCATE
        else
            printf '# The document asks for relocatable bundles, so no component plist is made.\n'
            printf 'component_plist=""\n'
        fi
        # The scripts flag is frozen by whether the document has scripts; the
        # component plist branches at run time on whether --analyze found
        # bundles. No arrays in POSIX sh, so the branches are spelled out.
        if [ -n "$preinstall" ] || [ -n "$postinstall" ]; then
            /bin/cat <<'PB_PKGBUILD_SCRIPTS'
if [ -n "$component_plist" ]; then
    /usr/bin/pkgbuild --root "$payload_root" --identifier "$identifier" --version "$package_version" \
        --install-location "$install_location" --ownership recommended \
        --scripts "$scripts_dir" --component-plist "$component_plist" "$component_package" \
        || fail "pkgbuild failed"
else
    /usr/bin/pkgbuild --root "$payload_root" --identifier "$identifier" --version "$package_version" \
        --install-location "$install_location" --ownership recommended \
        --scripts "$scripts_dir" "$component_package" \
        || fail "pkgbuild failed"
fi
PB_PKGBUILD_SCRIPTS
        else
            /bin/cat <<'PB_PKGBUILD_PLAIN'
if [ -n "$component_plist" ]; then
    /usr/bin/pkgbuild --root "$payload_root" --identifier "$identifier" --version "$package_version" \
        --install-location "$install_location" --ownership recommended \
        --component-plist "$component_plist" "$component_package" \
        || fail "pkgbuild failed"
else
    /usr/bin/pkgbuild --root "$payload_root" --identifier "$identifier" --version "$package_version" \
        --install-location "$install_location" --ownership recommended "$component_package" \
        || fail "pkgbuild failed"
fi
PB_PKGBUILD_PLAIN
        fi
        printf '\n'
        /bin/cat <<'PB_PATCH'
# pkgbuild always writes overwrite-permissions="true", which tells Installer to
# apply the BOM's root:wheel owner and mode to directories that already exist -
# with a payload under /usr/local that resets a Homebrew user's /usr/local.
# pkgbuild has no option for it, so PackageInfo is patched through an
# expand/flatten round trip; --expand keeps Payload and Bom opaque. The grep is
# not decoration: a silently failed sed would ship the harmful package.
expand_dir="$staging_dir/expand"
/usr/sbin/pkgutil --expand "$component_package" "$expand_dir" || fail "pkgutil --expand failed"
[ -f "$expand_dir/PackageInfo" ] || fail "The component package has no PackageInfo"
/usr/bin/sed -i '' "s/overwrite-permissions=\"[a-z]*\"/overwrite-permissions=\"$overwrite_permissions\"/" "$expand_dir/PackageInfo"
/usr/bin/grep -q "overwrite-permissions=\"$overwrite_permissions\"" "$expand_dir/PackageInfo" \
    || fail "Could not set overwrite-permissions to $overwrite_permissions"
/bin/rm -f "$component_package"
/usr/sbin/pkgutil --flatten "$expand_dir" "$component_package" || fail "pkgutil --flatten failed"
printf 'overwrite-permissions set to %s\n' "$overwrite_permissions"
PB_PATCH
        printf '\n'

        # --- Distribution.xml --------------------------------------------------
        # Emitted as quoted printf lines rather than a heredoc. A heredoc is
        # terminated by a line equal to its terminator, and no terminator can
        # be chosen that a document value provably cannot contain - a title of
        # "X\nPB_DIST_XML\n<command>" would end the document early and put the
        # rest at top level. Quoted printf arguments have no such escape: the
        # value is XML-escaped for the file's sake and sh_quoted for the
        # script's, and a newline inside it stays inside the quotes. Found in
        # review, 2026-08-07.
        #
        # The version is the one runtime splice, kept outside the quoting as a
        # %s argument; its character set is constrained above to be XML-safe.
        printf 'announce "PRODUCTBUILD distribution package"\n'
        printf 'dist_xml="$staging_dir/Distribution.xml"\n'
        printf ': > "$dist_xml" || fail "Could not write the Distribution XML"\n'
        emit_xml_line '<?xml version="1.0" encoding="UTF-8"?>'
        emit_xml_line '<installer-gui-script minSpecVersion="2">'
        local options_line='    <options'
        if [ -n "$architectures" ]; then
            options_line="$options_line hostArchitectures=\"$(xml_escape "$architectures")\""
        fi
        emit_xml_line "$options_line customize=\"$(xml_escape "$customize")\" require-scripts=\"$require_scripts\"/>"
        if [ -n "$min_os" ]; then
            emit_xml_line '    <volume-check>'
            emit_xml_line '        <allowed-os-versions>'
            emit_xml_line "            <os-version min=\"$(xml_escape "$min_os")\"/>"
            emit_xml_line '        </allowed-os-versions>'
            emit_xml_line '    </volume-check>'
        fi
        emit_xml_line "    <title>$(xml_escape "$title")</title>"
        local element base
        for pair in $DISTRIBUTION_RESOURCE_KINDS; do
            model_key="${pair%%:*}"
            element="${pair#*:}"
            stored="$(model_get "/DISTRIBUTION/RESOURCES/$model_key")"
            [ -n "$stored" ] || continue
            base="$(/usr/bin/basename "$stored")"
            emit_xml_line "    <$element file=\"$(xml_escape "$base")\"/>"
        done
        emit_xml_line '    <choices-outline>'
        emit_xml_line "        <line choice=\"$(xml_escape "$choice_id")\"/>"
        emit_xml_line '    </choices-outline>'
        emit_xml_line "    <choice id=\"$(xml_escape "$choice_id")\" title=\"$(xml_escape "$title")\" description=\"\">"
        emit_xml_line "        <pkg-ref id=\"$(xml_escape "$identifier")\"/>"
        emit_xml_line '    </choice>'
        # The one line carrying a runtime value. Three %s and three arguments,
        # so neither the quoted text around the version nor the version itself
        # is ever read as a format.
        printf 'printf %s %s "$package_version" %s >> "$dist_xml"\n' \
            "'%s%s%s'" \
            "$(sh_quote "    <pkg-ref id=\"$(xml_escape "$identifier")\" version=\"")" \
            "$(sh_quote "\" auth=\"$(xml_escape "$auth")\">#$(xml_escape "$name").pkg</pkg-ref>
")"
        emit_xml_line '</installer-gui-script>'
        printf '\n'

        # --- Presentation resources, one ditto per declared file --------------
        local have_resources=0
        for pair in $DISTRIBUTION_RESOURCE_KINDS; do
            model_key="${pair%%:*}"
            [ -n "$(model_get "/DISTRIBUTION/RESOURCES/$model_key")" ] || continue
            if [ "$have_resources" = "0" ]; then
                printf 'resources_dir="$staging_dir/Resources"\n'
                printf '/bin/mkdir -p "$resources_dir" || fail "Could not create the resources directory"\n'
                have_resources=1
            fi
            stored="$(model_get "/DISTRIBUTION/RESOURCES/$model_key")"
            base="$(/usr/bin/basename "$stored")"
            printf '/usr/bin/ditto %s "$resources_dir/"%s || fail "%s resource is not there"\n' \
                "$(emit_runtime_path "$stored")" "$(sh_quote "$base")" "$model_key"
        done
        printf '\n'
        printf 'unsigned_package="$staging_dir/$project_name-unsigned.pkg"\n'
        if [ "$have_resources" = "1" ]; then
            /bin/cat <<'PB_PRODUCTBUILD_RES'
/usr/bin/productbuild --distribution "$staging_dir/Distribution.xml" \
    --resources "$resources_dir" --package-path "$component_dir" "$unsigned_package" \
    || fail "productbuild failed"
PB_PRODUCTBUILD_RES
        else
            /bin/cat <<'PB_PRODUCTBUILD'
/usr/bin/productbuild --distribution "$staging_dir/Distribution.xml" \
    --package-path "$component_dir" "$unsigned_package" \
    || fail "productbuild failed"
PB_PRODUCTBUILD
        fi
        printf '\n'

        # --- Sign and land -----------------------------------------------------
        printf 'package_name=%s\n' "$(emit_runtime_text "$name_pattern")"
        /bin/cat <<'PB_SIGN'
# A path separator here would put every write below outside --output-dir
# entirely: "../elsewhere.pkg" lands one directory above it and reports
# success. The app refuses the same value in its signing preconditions, and
# the exported script has to refuse it too, since --version reaches this name.
case "$package_name" in
    ''|*/*) fail "The package file name '$package_name' must not be empty or contain a path separator" ;;
esac
case "$package_name" in
    *.pkg|*.PKG|*.Pkg) unsigned_name="${package_name%.*}-unsigned.pkg" ;;
    *) unsigned_name="$package_name-unsigned.pkg"; package_name="$package_name.pkg" ;;
esac
/bin/mkdir -p "$output_dir" || fail "Could not create the output folder $output_dir"

if [ "$do_codesign" = "1" ]; then
    announce "PRODUCTSIGN installer package"
    # Signed in the staging directory and verified there, then landed through a
    # sibling temp file and a rename, so the output folder never holds an
    # unsigned or half-written package under a real name (the app's design 8.3).
    staged_signed="$staging_dir/signed.pkg"
    /usr/bin/productsign --sign "$installer_identity" "$unsigned_package" "$staged_signed" \
        || fail "productsign failed; the output folder was not touched"
    /usr/sbin/pkgutil --check-signature "$staged_signed" \
        || fail "The signed package did not verify; the output folder was not touched"
    landing="$output_dir/.$package_name.$$.makepkg"
    /bin/cp "$staged_signed" "$landing" || fail "Could not write into $output_dir"
    /bin/mv -f "$landing" "$output_dir/$package_name" || fail "Could not put the signed package in place"
    final_package="$output_dir/$package_name"
else
    announce "UNSIGNED build - skipping productsign"
    final_package="$output_dir/$unsigned_name"
    /usr/bin/ditto "$unsigned_package" "$final_package" || fail "Could not write into $output_dir"
fi

announce "DONE"
printf 'Package:    %s\n' "$final_package"
printf 'Version:    %s\n' "$package_version"
printf 'Identifier: %s\n' "$identifier"
printf '\n'
if [ "$do_codesign" = "1" ]; then
    printf 'This package is signed but NOT notarized. Notarize and staple it with:\n'
    printf '  xcrun notarytool submit "%s" --keychain-profile <profile> --wait\n' "$final_package"
    printf '  xcrun stapler staple "%s"\n' "$final_package"
    printf 'where <profile> was made once with: xcrun notarytool store-credentials\n'
    printf 'Or open it in Notarize.app, with "Sign before submitting" turned off.\n'
else
    printf 'NOT signed and NOT notarized. Do not distribute this package.\n'
fi
PB_SIGN
    } > "$script_path" || return 1
    return 0
}
