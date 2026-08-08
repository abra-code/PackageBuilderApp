#!/bin/sh
# lib.packagebuilder.schema.sh - does this file have the shape of a project?
#
# The format verifier. It answers a different question from the build
# preconditions, and the split matters: this file asks "is this document
# well-formed" - are the keys ones the app knows, are the types right, are the
# enumerated values in range - while check_preconditions in
# lib.packagebuilder.build.sh asks "will this document build" - do the sources
# exist on this disk, do the destinations collide, is the identity in this
# keychain. A document can be perfectly well-formed and unbuildable (the
# artifacts are on another machine), and that is a normal state for a project
# file under construction, which is why the two are not merged.
#
# Written for the agent CLI, where a caller is assembling a document by
# machine and needs to be told exactly which key is wrong rather than being
# told the build failed. model_normalize would paper over most of this - it
# fills in absent containers and replaces out-of-range enums - so the verifier
# deliberately reads the file as it is, before any normalization.
#
# Shell only, no Python: design section 12 rules the app out of an interpreter
# dependency, and plister's "get keys" and "get type" make key and type
# enumeration possible without one.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".

# Findings are counted rather than returned: a shell return carries eight bits,
# and a document can hold more than 255 problems. Both are reset by
# schema_check_document.
schema_errors=0
schema_warnings=0

# The file under inspection, staged under a .json name because plister decides
# format by extension alone (design 12.2) and ".pkgbuilderproj" is neither.
schema_file=""

# Overridable by the caller: the CLI sends these to stderr, and a future
# in-app use could send them to the log view instead. Both are given the
# document path in dotted form so a caller can point at the offending key.
schema_error() {
    schema_errors=$((schema_errors + 1))
    printf 'ERROR: %s\n' "$1" >&2
}

schema_warn() {
    schema_warnings=$((schema_warnings + 1))
    printf 'WARNING: %s\n' "$1" >&2
}

schema_note() {
    printf 'INFO: %s\n' "$1" >&2
}

# --- plister readers ----------------------------------------------------------
# Print the type plister reports for a key path, or nothing when it is absent.
schema_type() {
    "$plister" get type "$schema_file" "$1" 2>/dev/null
}

schema_value() {
    "$plister" get value "$schema_file" "$1" 2>/dev/null
}

schema_keys() {
    "$plister" get keys "$schema_file" "$1" 2>/dev/null
}

schema_count() {
    local element_count="$("$plister" get count "$schema_file" "$1" 2>/dev/null)"
    case "$element_count" in
        ''|*[!0-9]*) printf '0' ;;
        *) printf '%s' "$element_count" ;;
    esac
}

# --- Checks -------------------------------------------------------------------
# Every key present at a path must be in the allowed list. An unknown key is a
# warning rather than an error: it is either a typo - in which case the value
# the writer meant to set is silently absent, which is exactly what needs
# saying - or a field from a newer format version, which should not stop an
# older build from reading what it does understand.
# Arguments: key path, human label, space-separated allowed keys
schema_check_keys() {
    local key_path="$1" label="$2" allowed="$3"
    # Set by the read loop below.
    local found_key
    # Through a file rather than a pipe: every branch of the loop counts a
    # finding in a global, and the right-hand side of a pipe runs in a
    # subshell, so the counts - and with them the exit status of the whole
    # verifier - would be discarded.
    local key_list="$(state_dir)/schema-keys.txt"
    "$plister" get keys "$schema_file" "$key_path" > "$key_list" 2>/dev/null
    while IFS= read -r found_key; do
        [ -n "$found_key" ] || continue
        case " $allowed " in
            *" $found_key "*) ;;
            *) schema_warn "$label: unknown key \"$found_key\" - it is ignored, so a value meant for a real key is not being set" ;;
        esac
    done < "$key_list"
    /bin/rm -f "$key_list"
    return 0
}

# Require a key to exist and hold the given plister type.
# Arguments: key path, expected type, label, required(1)/optional(0)
schema_check_type() {
    local key_path="$1" expected="$2" label="$3" required="$4"
    local actual="$(schema_type "$key_path")"
    if [ -z "$actual" ]; then
        if [ "$required" = "1" ]; then
            schema_error "$label is missing"
        fi
        return 0
    fi
    if [ "$actual" != "$expected" ]; then
        schema_error "$label is $actual, expected $expected"
        return 0
    fi
    return 0
}

# Require a scalar to be one of a set of values, when it is present at all.
# Arguments: key path, label, space-separated allowed values
schema_check_enum() {
    local key_path="$1" label="$2" allowed="$3"
    # Presence is decided by the type, not by the value. "get value" prints
    # nothing for an empty string, an empty dict and an empty array alike, so a
    # value test cannot tell "absent" - which is fine, every enum is optional -
    # from "present and wrong", which is not. Testing the value was reporting
    # {} and [] as clean. Found in review, 2026-08-07.
    local actual_type="$(schema_type "$key_path")"
    [ -n "$actual_type" ] || return 0
    if [ "$actual_type" != "string" ]; then
        schema_error "$label is $actual_type, expected a string - one of: $allowed"
        return 0
    fi
    local actual="$(schema_value "$key_path")"
    case " $allowed " in
        *" $actual "*) return 0 ;;
    esac
    schema_error "$label is \"$actual\", expected one of: $allowed"
    return 0
}

# --- The document -------------------------------------------------------------
SCHEMA_ROOT_KEYS="FORMAT_VERSION PROJECT COMPONENTS DISTRIBUTION SIGNING"
SCHEMA_PROJECT_KEYS="NAME VERSION MIN_OS_VERSION ARTIFACTS_DIR OUTPUT_DIR PACKAGE_NAME"
SCHEMA_COMPONENT_KEYS="IDENTIFIER INSTALL_LOCATION OVERWRITE_PERMISSIONS RELOCATABLE AUTH PREINSTALL POSTINSTALL PAYLOAD"
SCHEMA_PAYLOAD_KEYS="SOURCE DESTINATION OWNER GROUP MODE VERIFY"
SCHEMA_VERIFY_KEYS="ARCHITECTURES SIGNED_BY HARDENED_RUNTIME SECURE_TIMESTAMP VERSION_FLAG"
SCHEMA_DISTRIBUTION_KEYS="TITLE HOST_ARCHITECTURES CUSTOMIZE REQUIRE_SCRIPTS RESOURCES"
SCHEMA_RESOURCE_KEYS="README LICENSE WELCOME CONCLUSION BACKGROUND"
SCHEMA_SIGNING_KEYS="ENABLED INSTALLER_IDENTITY"

# The format version this app writes. A document declaring a higher one is
# reported and still checked: refusing outright would leave an agent with no
# way to find out what is actually wrong with it.
SCHEMA_FORMAT_VERSION=1

schema_check_payload_entry() {
    local entry_index="$1"
    local base="/COMPONENTS/0/PAYLOAD/$entry_index"
    local label="payload entry $((entry_index + 1))"

    if [ "$(schema_type "$base")" != "dict" ]; then
        schema_error "$label is $(schema_type "$base"), expected dict"
        return 0
    fi
    schema_check_keys "$base" "$label" "$SCHEMA_PAYLOAD_KEYS"

    # SOURCE and DESTINATION are what the entry is for; an entry without them
    # is not a partial entry, it is a mistake that builds nothing.
    schema_check_type "$base/SOURCE" string "$label SOURCE" 1
    schema_check_type "$base/DESTINATION" string "$label DESTINATION" 1
    schema_check_type "$base/OWNER" string "$label OWNER" 0
    schema_check_type "$base/GROUP" string "$label GROUP" 0
    schema_check_type "$base/MODE" string "$label MODE" 0

    # MODE is three or four octal digits. Checked here as well as in the build
    # preconditions because a document being assembled by machine is exactly
    # where "0755" arrives as the number 755 or as "rwxr-xr-x".
    # Gated on the type rather than on the value being non-empty, for the same
    # reason schema_check_enum is: an empty string reads as absent through
    # "get value" and was slipping past. A non-string MODE has already been
    # reported by the type check above, so this stays quiet about it.
    if [ "$(schema_type "$base/MODE")" = "string" ]; then
        local mode="$(schema_value "$base/MODE")"
        case "$mode" in
            *[!0-7]*) schema_error "$label MODE \"$mode\" is not octal - use \"0755\" or \"0644\"" ;;
            ???|????) ;;
            *) schema_error "$label MODE \"$mode\" must be three or four octal digits, for example \"0755\"" ;;
        esac
    fi

    local verify_type="$(schema_type "$base/VERIFY")"
    if [ -z "$verify_type" ]; then
        return 0
    fi
    if [ "$verify_type" != "dict" ]; then
        schema_error "$label VERIFY is $verify_type, expected dict"
        return 0
    fi
    schema_check_keys "$base/VERIFY" "$label VERIFY" "$SCHEMA_VERIFY_KEYS"
    schema_check_type "$base/VERIFY/ARCHITECTURES" array "$label VERIFY/ARCHITECTURES" 0
    schema_check_type "$base/VERIFY/SIGNED_BY" string "$label VERIFY/SIGNED_BY" 0
    schema_check_type "$base/VERIFY/HARDENED_RUNTIME" bool "$label VERIFY/HARDENED_RUNTIME" 0
    schema_check_type "$base/VERIFY/SECURE_TIMESTAMP" bool "$label VERIFY/SECURE_TIMESTAMP" 0
    schema_check_type "$base/VERIFY/VERSION_FLAG" string "$label VERIFY/VERSION_FLAG" 0

    # Architecture names are the ones lipo prints. A misspelling here is worth
    # naming, because the verify stage would refuse the artifact with "not
    # built for arm46" and the reader would look at the binary, not the
    # document.
    local arch_count="$(schema_count "$base/VERIFY/ARCHITECTURES")"
    local arch_index=0
    # Set by the loop below.
    local arch
    while [ "$arch_index" -lt "$arch_count" ]; do
        arch="$(schema_value "$base/VERIFY/ARCHITECTURES/$arch_index")"
        case "$arch" in
            arm64|arm64e|x86_64|i386|arm64_32|armv7|armv7k) ;;
            '') schema_error "$label VERIFY/ARCHITECTURES has an empty entry" ;;
            *) schema_warn "$label VERIFY/ARCHITECTURES lists \"$arch\", which is not an architecture lipo reports" ;;
        esac
        arch_index=$((arch_index + 1))
    done
    return 0
}

# Check one file. Returns 1 when it found errors, 2 when only warnings, 0 clean.
# Arguments: path to the .pkgbuilderproj
schema_check_document() {
    local document_path="$1"
    schema_errors=0
    schema_warnings=0

    if [ ! -f "$document_path" ]; then
        schema_error "no such file: $document_path"
        return 1
    fi
    if [ ! -r "$document_path" ]; then
        schema_error "cannot read: $document_path"
        return 1
    fi

    # Staged under .json for plister, and in the state directory so nothing is
    # written beside the user's document (design 8.4).
    schema_file="$(state_dir)/schema-check.json"
    /bin/rm -f "$schema_file"
    /bin/cp "$document_path" "$schema_file" || {
        schema_error "could not read $document_path"
        return 1
    }

    # A file plister cannot parse gives no root type at all, which is the one
    # failure worth stopping on: every check below would otherwise report a
    # missing key for every key in the format.
    if [ "$(schema_type /)" != "dict" ]; then
        schema_error "$(/usr/bin/basename "$document_path") is not a JSON object - a project file starts with { and holds FORMAT_VERSION"
        /bin/rm -f "$schema_file"
        return 1
    fi

    schema_check_keys / "the document" "$SCHEMA_ROOT_KEYS"

    local format_version="$(schema_value /FORMAT_VERSION)"
    case "$format_version" in
        '') schema_error "FORMAT_VERSION is missing - the app refuses to open a document without it" ;;
        *[!0-9]*) schema_error "FORMAT_VERSION is \"$format_version\", expected a whole number" ;;
        *)
            if [ "$format_version" -gt "$SCHEMA_FORMAT_VERSION" ]; then
                schema_warn "FORMAT_VERSION is $format_version and this app writes $SCHEMA_FORMAT_VERSION - anything newer in it is ignored"
            fi
            ;;
    esac

    # --- PROJECT ---
    if [ "$(schema_type /PROJECT)" = "dict" ]; then
        schema_check_keys /PROJECT "PROJECT" "$SCHEMA_PROJECT_KEYS"
        schema_check_type /PROJECT/NAME string "PROJECT/NAME" 1
        schema_check_type /PROJECT/VERSION string "PROJECT/VERSION" 1
        schema_check_type /PROJECT/MIN_OS_VERSION string "PROJECT/MIN_OS_VERSION" 0
        schema_check_type /PROJECT/ARTIFACTS_DIR string "PROJECT/ARTIFACTS_DIR" 0
        schema_check_type /PROJECT/OUTPUT_DIR string "PROJECT/OUTPUT_DIR" 0
        schema_check_type /PROJECT/PACKAGE_NAME string "PROJECT/PACKAGE_NAME" 0
    else
        schema_error "PROJECT is missing or is not a dict"
    fi

    # --- COMPONENTS ---
    local component_count=0
    if [ "$(schema_type /COMPONENTS)" = "array" ]; then
        component_count="$(schema_count /COMPONENTS)"
        if [ "$component_count" = "0" ]; then
            schema_error "COMPONENTS is empty - a project needs one component"
        elif [ "$component_count" -gt 1 ]; then
            # Design 14 decision 2: the schema stores an array, the app edits
            # element 0 and the Distribution XML gets one choice.
            schema_warn "COMPONENTS holds $component_count components; this app reads only the first one"
        fi
    else
        schema_error "COMPONENTS is missing or is not an array"
    fi

    if [ "$(schema_type /COMPONENTS/0)" = "dict" ]; then
        schema_check_keys /COMPONENTS/0 "COMPONENTS/0" "$SCHEMA_COMPONENT_KEYS"
        schema_check_type /COMPONENTS/0/IDENTIFIER string "COMPONENTS/0/IDENTIFIER" 1
        schema_check_type /COMPONENTS/0/INSTALL_LOCATION string "COMPONENTS/0/INSTALL_LOCATION" 0
        schema_check_type /COMPONENTS/0/OVERWRITE_PERMISSIONS bool "COMPONENTS/0/OVERWRITE_PERMISSIONS" 0
        schema_check_type /COMPONENTS/0/RELOCATABLE bool "COMPONENTS/0/RELOCATABLE" 0
        schema_check_type /COMPONENTS/0/PREINSTALL string "COMPONENTS/0/PREINSTALL" 0
        schema_check_type /COMPONENTS/0/POSTINSTALL string "COMPONENTS/0/POSTINSTALL" 0
        schema_check_enum /COMPONENTS/0/AUTH "COMPONENTS/0/AUTH" "Root User"

        # Both defaults are safety decisions with a design section behind them,
        # so a document turning either on is told what it is asking for rather
        # than left to find out from an installed machine.
        if [ "$(schema_value /COMPONENTS/0/OVERWRITE_PERMISSIONS)" = "true" ]; then
            schema_warn "COMPONENTS/0/OVERWRITE_PERMISSIONS is true: installing will apply the payload's owner and mode to directories that already exist, which resets a Homebrew user's /usr/local when the payload lives there (design 8.1)"
        fi
        if [ "$(schema_value /COMPONENTS/0/RELOCATABLE)" = "true" ]; then
            schema_warn "COMPONENTS/0/RELOCATABLE is true: Installer will follow Spotlight to any existing copy of a bundle in the payload and install there instead (design 8.2)"
        fi

        if [ "$(schema_type /COMPONENTS/0/PAYLOAD)" = "array" ]; then
            local payload_count="$(schema_count /COMPONENTS/0/PAYLOAD)"
            if [ "$payload_count" = "0" ]; then
                schema_warn "the payload is empty - the document is well-formed but builds nothing"
            fi
            local entry_index=0
            while [ "$entry_index" -lt "$payload_count" ]; do
                schema_check_payload_entry "$entry_index"
                entry_index=$((entry_index + 1))
            done
        else
            schema_error "COMPONENTS/0/PAYLOAD is missing or is not an array"
        fi
    elif [ "$component_count" != "0" ]; then
        schema_error "COMPONENTS/0 is not a dict"
    fi

    # --- DISTRIBUTION ---
    if [ "$(schema_type /DISTRIBUTION)" = "dict" ]; then
        schema_check_keys /DISTRIBUTION "DISTRIBUTION" "$SCHEMA_DISTRIBUTION_KEYS"
        schema_check_type /DISTRIBUTION/TITLE string "DISTRIBUTION/TITLE" 0
        schema_check_type /DISTRIBUTION/REQUIRE_SCRIPTS bool "DISTRIBUTION/REQUIRE_SCRIPTS" 0
        schema_check_enum /DISTRIBUTION/CUSTOMIZE "DISTRIBUTION/CUSTOMIZE" "never allow always"

        if [ "$(schema_type /DISTRIBUTION/HOST_ARCHITECTURES)" = "array" ]; then
            local host_count="$(schema_count /DISTRIBUTION/HOST_ARCHITECTURES)"
            if [ "$host_count" = "0" ]; then
                schema_error "DISTRIBUTION/HOST_ARCHITECTURES is empty - productbuild refuses a document whose hostArchitectures attribute is empty, so the installer would run nowhere"
            fi
            local host_index=0
            # Set by the loop below.
            local host_arch
            while [ "$host_index" -lt "$host_count" ]; do
                host_arch="$(schema_value "/DISTRIBUTION/HOST_ARCHITECTURES/$host_index")"
                case "$host_arch" in
                    arm64|x86_64) ;;
                    *) schema_error "DISTRIBUTION/HOST_ARCHITECTURES lists \"$host_arch\"; Installer understands arm64 and x86_64" ;;
                esac
                host_index=$((host_index + 1))
            done
        else
            schema_error "DISTRIBUTION/HOST_ARCHITECTURES is missing or is not an array"
        fi

        if [ "$(schema_type /DISTRIBUTION/RESOURCES)" = "dict" ]; then
            schema_check_keys /DISTRIBUTION/RESOURCES "DISTRIBUTION/RESOURCES" "$SCHEMA_RESOURCE_KEYS"
            # Set by the loop below.
            local resource_key
            for resource_key in $SCHEMA_RESOURCE_KEYS; do
                schema_check_type "/DISTRIBUTION/RESOURCES/$resource_key" string "DISTRIBUTION/RESOURCES/$resource_key" 0
            done
        elif [ -n "$(schema_type /DISTRIBUTION/RESOURCES)" ]; then
            schema_error "DISTRIBUTION/RESOURCES is $(schema_type /DISTRIBUTION/RESOURCES), expected dict"
        fi
    else
        schema_error "DISTRIBUTION is missing or is not a dict"
    fi

    # --- SIGNING ---
    if [ "$(schema_type /SIGNING)" = "dict" ]; then
        schema_check_keys /SIGNING "SIGNING" "$SCHEMA_SIGNING_KEYS"
        schema_check_type /SIGNING/ENABLED bool "SIGNING/ENABLED" 0
        schema_check_type /SIGNING/INSTALLER_IDENTITY string "SIGNING/INSTALLER_IDENTITY" 0
        if [ "$(schema_value /SIGNING/ENABLED)" = "true" ] && [ -z "$(schema_value /SIGNING/INSTALLER_IDENTITY)" ]; then
            schema_warn "SIGNING/ENABLED is true but INSTALLER_IDENTITY is empty - the build will refuse until one is chosen"
        fi
    elif [ -n "$(schema_type /SIGNING)" ]; then
        schema_error "SIGNING is $(schema_type /SIGNING), expected dict"
    fi

    /bin/rm -f "$schema_file"

    [ "$schema_errors" = "0" ] || return 1
    [ "$schema_warnings" = "0" ] || return 2
    return 0
}
